---@brief Leveled inline ghost-text completion (SPEC §8).
---
---Ghost text DISPLAY is extmark-only and lock-free (extmarks never mutate
---buffer text). ACCEPTING a suggestion is a programmatic write and therefore
---goes through the single-writer buffer lock; when the agent holds the lock
---(or a lifecycle op is running) accept refuses with a quiet warning.
---
---Manual smoke test (interactive):
---  1. nvim -u scripts/minimal_init.lua        (mock backend, autonomy 2)
---  2. :e /tmp/scratch.lua, enter insert mode, type a few characters
---  3. after ~180ms of idle, dim ghost text ("-- mock completion") appears
---     inline after the cursor
---  4. press <Tab>: the ghost text is inserted into the buffer and the ghost
---     clears; with no ghost visible, <Tab> still indents as normal
---  5. move the cursor / leave insert mode: ghost clears
---  6. :StickShiftAutonomy 1 - typing no longer produces ghost text (completion
---     is gated to autonomy >= 2 unless completion.force)
local autonomy = require("stick-shift.autonomy")
local backend = require("stick-shift.backend")
local config = require("stick-shift.config")
local events = require("stick-shift.events")
local lock = require("stick-shift.lock")
local util = require("stick-shift.util")

local M = {}

local ns = vim.api.nvim_create_namespace("stick-shift/ghost")

---@class stick-shift.Suggestion
---@field bufnr integer
---@field row integer 0-indexed row the suggestion anchors to
---@field col integer 0-indexed byte column
---@field text string trimmed insert text (may be multi-line)
---@field id integer extmark id

---@type stick-shift.Suggestion|nil current on-screen suggestion
M._suggestion = nil

---Monotonic request generation: any response whose generation no longer
---matches is stale and MUST NOT render. Bumped on every new request and every
---dismissal, so a cancelled handle that fires late is harmless.
local generation = 0
---@type { cancel: fun() }|nil in-flight backend handle
local inflight = nil
local debounced_request, cancel_debounce

---How many lines each granularity may insert (word/line handled specially).
local LINE_CAPS = { multiline = 5, paragraph = 15 }

---Completion availability = the autonomy ladder's ruling (which already folds
---in completion.force and completion.level == "off").
---@return boolean
function M.enabled()
  return autonomy.allows("completion")
end

---Client-side granularity guard: the model is ASKED for the configured
---granularity, but we never trust it to obey. Trim to the cap; drop empties.
---@param text string|nil
---@param granularity string "word"|"line"|"multiline"|"paragraph"
---@return string|nil trimmed nil when nothing worth showing remains
local function trim_to_granularity(text, granularity)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("\r\n", "\n")
  if granularity == "word" then
    -- Keep simple leading spaces (they glue the token to what's typed), but a
    -- newline prefix would turn a "word" into a multi-line edit — drop it.
    local ws, tok = text:match("^(%s*)(%S+)")
    if not tok then
      text = ""
    else
      text = (ws:find("\n") and "" or ws) .. tok
    end
  elseif granularity == "line" then
    text = vim.split(text, "\n", { plain = true })[1] or ""
  else
    local cap = LINE_CAPS[granularity] or LINE_CAPS.multiline
    local lines = vim.split(text, "\n", { plain = true })
    if #lines > cap then
      lines = vim.list_slice(lines, 1, cap)
    end
    text = table.concat(lines, "\n")
  end
  if vim.trim(text) == "" then
    return nil
  end
  return text
end

---Collect prompt context around the cursor.
---@param bufnr integer
---@param row integer 1-indexed cursor row
---@param col integer 0-indexed cursor byte column
---@param before_n integer lines of context before (incl. cursor line up to col)
---@param after_n integer lines of context after
---@return { path: string, filetype: string, before_cursor: string, after_cursor: string }
local function buffer_ctx(bufnr, row, col, before_n, after_n)
  local start = math.max(0, row - before_n)
  local before = vim.api.nvim_buf_get_lines(bufnr, start, row, false)
  if #before > 0 then
    before[#before] = before[#before]:sub(1, col)
  end
  local cursor_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local after = vim.api.nvim_buf_get_lines(bufnr, row, row + after_n, false)
  table.insert(after, 1, cursor_line:sub(col + 1))
  return {
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    before_cursor = table.concat(before, "\n"),
    after_cursor = table.concat(after, "\n"),
  }
end
M._buffer_ctx = buffer_ctx -- shared with stick-shift.hint (smaller window there)

---Current step, slimmed to title + detail so the ghost prompt stays cheap.
---@return { title: string, detail: string }|nil
local function current_step()
  local st = require("stick-shift.plan.lifecycle").state()
  if not st.plan then
    return nil
  end
  local step = require("stick-shift.plan.store").get_step(st.plan)
  if not step then
    return nil
  end
  return { title = step.title, detail = step.detail }
end

---Remove the ghost extmark and invalidate any in-flight response. Does NOT
---cancel a pending debounce timer (CursorMovedI fires right after TextChangedI
---while typing; killing the timer there would starve completion entirely).
local function dismiss()
  generation = generation + 1
  if inflight then
    inflight.cancel()
    inflight = nil
  end
  local s = M._suggestion
  if s and vim.api.nvim_buf_is_valid(s.bufnr) then
    vim.api.nvim_buf_clear_namespace(s.bufnr, ns, 0, -1)
  end
  M._suggestion = nil
end

---Clear everything: ghost, in-flight request, and the pending debounce timer.
function M.clear()
  if cancel_debounce then
    cancel_debounce()
  end
  dismiss()
end

---Render ghost text at (row0, col): first line inline after the cursor,
---remaining lines as virt_lines below. Display only - no lock needed.
---@param bufnr integer
---@param row0 integer 0-indexed
---@param col integer
---@param text string
local function render(bufnr, row0, col, text)
  local lines = vim.split(text, "\n", { plain = true })
  local virt_lines = {}
  for i = 2, #lines do
    table.insert(virt_lines, { { lines[i], "StickShiftGhost" } })
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, col, {
    virt_text = { { lines[1], "StickShiftGhost" } },
    -- virt_text_pos = "inline" is available since 0.10; fine on 0.11.
    virt_text_pos = "inline",
    virt_lines = #virt_lines > 0 and virt_lines or nil,
  })
  if not ok then
    return
  end
  M._suggestion = { bufnr = bufnr, row = row0, col = col, text = text, id = id }
end

---Fire a completion request for the buffer's current cursor position.
---Internal, but exposed (underscored) so headless tests can drive the request
---path without synthesizing InsertMode keystrokes.
---@param bufnr integer|nil defaults to the current buffer
function M._request(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.enabled() then
    return
  end
  if require("stick-shift.plan.lifecycle").is_busy() then
    return -- an agent op is running; don't race it
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  dismiss()
  local gen = generation
  local granularity = config.get().completion.level
  inflight = backend.call("complete", {
    root = util.project_root(vim.api.nvim_buf_get_name(bufnr)),
    buffer = buffer_ctx(bufnr, row, col, 200, 50),
    step = current_step(),
    granularity = granularity,
  }, function(err, result)
    if gen ~= generation then
      return -- stale: a newer keystroke/dismissal superseded this response
    end
    inflight = nil
    if err then
      return -- completion errors are noise; never notify per keystroke
    end
    -- Position guard: only render if the cursor is still exactly where the
    -- request was made.
    if
      not vim.api.nvim_buf_is_valid(bufnr)
      or bufnr ~= vim.api.nvim_get_current_buf()
    then
      return
    end
    local crow, ccol = unpack(vim.api.nvim_win_get_cursor(0))
    if crow ~= row or ccol ~= col then
      return
    end
    local text = trim_to_granularity(result.insert_text, granularity)
    if text then
      render(bufnr, row - 1, col, text)
    end
  end)
end

---Dismiss any ghost and request a fresh suggestion immediately (no debounce).
function M.refresh()
  M.clear()
  M._request(vim.api.nvim_get_current_buf())
end

---Accept the on-screen suggestion. This is the write path: it takes the
---per-buffer single-writer lock and refuses - quietly, with a warn - when the
---agent holds it or a lifecycle op is in flight. Returns false when there was
---nothing to accept (so the accept key can fall through to its normal role).
---@return boolean accepted
function M.accept()
  local s = M._suggestion
  if not s or not vim.api.nvim_buf_is_valid(s.bufnr) then
    return false
  end
  -- A suggestion is only valid in the buffer AND at the exact position it was
  -- rendered for. A stale one (e.g. insert mode left via <C-c>, which fires no
  -- InsertLeave) must never teleport text to an old position - drop it instead.
  if vim.api.nvim_get_current_buf() ~= s.bufnr then
    M.clear()
    return false
  end
  local crow, ccol = unpack(vim.api.nvim_win_get_cursor(0))
  if crow - 1 ~= s.row or ccol ~= s.col then
    M.clear()
    return false
  end
  if require("stick-shift.plan.lifecycle").is_busy() then
    util.warn("completion: not accepting while a stick-shift operation is running")
    return false
  end
  local new_row, new_col
  local ok, err = lock.with(s.bufnr, "completion", function()
    local lines = vim.split(s.text, "\n", { plain = true })
    vim.api.nvim_buf_set_text(s.bufnr, s.row, s.col, s.row, s.col, lines)
    if #lines == 1 then
      new_row, new_col = s.row, s.col + #lines[1]
    else
      new_row, new_col = s.row + #lines - 1, #lines[#lines]
    end
  end)
  if not ok then
    util.warn("completion: cannot accept (" .. tostring(err) .. ")")
    return false
  end
  M.clear()
  if vim.api.nvim_get_current_buf() == s.bufnr then
    pcall(vim.api.nvim_win_set_cursor, 0, { new_row + 1, new_col })
  end
  return true
end

---Insert-mode accept keymap: accept the ghost if present, otherwise feed the
---original key through untouched so e.g. <Tab> keeps indenting.
local function map_accept_key()
  local key = config.get().completion.accept_key
  if not key or key == false or key == "" then
    return
  end
  vim.keymap.set("i", key, function()
    if not M.accept() then
      local termcodes = vim.api.nvim_replace_termcodes(key, true, false, true)
      -- "i": insert at the FRONT of typeahead. Without it the key is appended
      -- behind keys already typed, reordering input during fast typing/macros.
      vim.api.nvim_feedkeys(termcodes, "in", false)
    end
  end, { desc = "stick-shift: accept inline completion (falls through when no ghost)", silent = true })
end

---Wire autocmds, the accept keymap, and the StickShiftGhost highlight.
function M.setup()
  vim.api.nvim_set_hl(0, "StickShiftGhost", { link = "Comment", default = true })

  -- TODO(stick-shift): Neovim 0.12 ships vim.lsp.inline_completion - a native
  -- ghost-text pipeline we could feed via an in-process LSP server instead of
  -- managing extmarks by hand. Untestable on this machine (0.11.5), so the
  -- extmark path below is the deliverable; this branch only records the fact.
  if vim.lsp.inline_completion ~= nil then
    vim.notify(
      "[stick-shift] Neovim 0.12 native inline completion detected but not yet used (TODO(stick-shift)); using extmark ghost text",
      vim.log.levels.DEBUG
    )
  end

  debounced_request, cancel_debounce = util.debounce(
    config.get().completion.debounce_ms,
    function(bufnr)
      -- Belt-and-braces with debounce's cancel guard: never fire a request
      -- outside insert mode (ghosts rendered in normal mode have no clearer).
      if not vim.api.nvim_get_mode().mode:find("^i") then
        return
      end
      M._request(bufnr)
    end
  )

  local group = vim.api.nvim_create_augroup("stick-shift.complete", { clear = true })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    desc = "stick-shift: request completion (debounced)",
    callback = function(a)
      if not M.enabled() then
        return
      end
      dismiss() -- new keystroke: old ghost and in-flight response are stale
      debounced_request(a.buf)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    desc = "stick-shift: dismiss ghost on cursor move",
    callback = dismiss,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    desc = "stick-shift: clear ghost and pending requests",
    callback = M.clear,
  })
  -- <C-c> leaves insert mode WITHOUT firing InsertLeave; ModeChanged i*:*
  -- catches it (and any other insert-mode exit) so no ghost survives into
  -- normal mode.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "i*:*",
    desc = "stick-shift: clear ghost on any insert-mode exit (incl. <C-c>)",
    callback = M.clear,
  })

  events.on("autonomy_changed", function()
    if not M.enabled() then
      M.clear()
    end
  end)

  map_accept_key()
end

return M
