---@brief One-sentence hint (SPEC §9): a single sentence of DIRECTION, not
---code, rendered as unobtrusive eol virtual text at the cursor line
---(tiny-inline-diagnostic style). Dedicated namespace; never touches the
---diagnostics namespace. Available at every autonomy level - it is the only
---feature alive at level 0.
local autonomy = require("stick-shift.autonomy")
local backend = require("stick-shift.backend")
local config = require("stick-shift.config")
local events = require("stick-shift.events")
local util = require("stick-shift.util")

local M = {}

local ns = vim.api.nvim_create_namespace("stick-shift/hint")

---@type { bufnr: integer, row: integer, id: integer }|nil on-screen hint
M._hint = nil

---Staleness guard: responses from a superseded request never render.
local generation = 0
---@type { cancel: fun() }|nil
local inflight = nil

---Auto-trigger rate limiting (>= 30s between auto hints, never the same line twice in a row).
local AUTO_INTERVAL_MS = 30000
local last_auto_ms = 0
---@type { bufnr: integer, row: integer }|nil
local last_auto_line = nil

---Remove the hint extmark and invalidate any in-flight request.
function M.clear()
  generation = generation + 1
  if inflight then
    inflight.cancel()
    inflight = nil
  end
  local h = M._hint
  if h and vim.api.nvim_buf_is_valid(h.bufnr) then
    vim.api.nvim_buf_clear_namespace(h.bufnr, ns, 0, -1)
  end
  M._hint = nil
end

---Current step slimmed to title + detail (direction source; prompt stays small).
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

---Cursor context, smaller than completion's (a hint needs the gist, not the file).
---@param bufnr integer
---@param row integer 1-indexed
---@param col integer 0-indexed byte column
local function buffer_ctx(bufnr, row, col)
  local ok, complete = pcall(require, "stick-shift.complete")
  if ok then
    return complete._buffer_ctx(bufnr, row, col, 60, 20)
  end
  -- Degrade: stick-shift.complete missing from a partial tree; cursor line only.
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  return {
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    before_cursor = line:sub(1, col),
    after_cursor = line:sub(col + 1),
  }
end

---Render the hint at the current cursor line as eol virtual text.
---@param text string
local function render(text)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    virt_text = { { "≫ " .. text, "StickShiftHint" } },
    virt_text_pos = "eol",
  })
  if ok then
    M._hint = { bufnr = bufnr, row = row, id = id }
  end
end

---Ask the backend for one sentence of direction and show it at the cursor.
---Gated on autonomy.allows("hint_manual") (auto-trigger has its own gate).
function M.show()
  if not autonomy.allows("hint_manual") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  M.clear()
  local gen = generation
  local max_len = config.get().hint.max_len
  inflight = backend.call("hint", {
    root = util.project_root(vim.api.nvim_buf_get_name(bufnr)),
    buffer = buffer_ctx(bufnr, row, col),
    step = current_step(),
    max_len = max_len,
  }, function(err, result)
    if gen ~= generation then
      return -- stale
    end
    inflight = nil
    if err then
      util.warn("hint: " .. err)
      return
    end
    -- Drop if the user switched buffers since the request was made.
    if vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end
    local text = vim.trim(tostring(result.text or ""))
    if text == "" then
      return
    end
    if vim.fn.strchars(text) > max_len then
      text = vim.fn.strcharpart(text, 0, max_len - 1) .. "…"
    end
    render(text)
  end)
end

---Auto-trigger path (CursorHold): rate-limited and line-deduplicated so the
---hint stays unobtrusive instead of chattering.
local function maybe_auto_hint()
  if not autonomy.allows("hint_auto") then
    return -- re-evaluated on every fire, so autonomy changes apply instantly
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local now = vim.uv.now()
  if now - last_auto_ms < AUTO_INTERVAL_MS then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if last_auto_line and last_auto_line.bufnr == bufnr and last_auto_line.row == row then
    return -- don't re-hint the line the user is still sitting on
  end
  last_auto_ms = now
  last_auto_line = { bufnr = bufnr, row = row }
  M.show()
end

---Wire autocmds and the StickShiftHint highlight.
function M.setup()
  vim.api.nvim_set_hl(0, "StickShiftHint", { link = "DiagnosticVirtualTextHint", default = true })

  local group = vim.api.nvim_create_augroup("stick-shift.hint", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
    group = group,
    desc = "stick-shift: clear hint",
    callback = function()
      -- Only clear when a hint is actually up (or a request is pending), so
      -- plain cursor movement stays free.
      if M._hint or inflight then
        M.clear()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    desc = "stick-shift: auto hint (autonomy-gated, rate-limited)",
    callback = maybe_auto_hint,
  })

  events.on("autonomy_changed", function()
    if not autonomy.allows("hint_manual") then
      M.clear()
    end
  end)
end

return M
