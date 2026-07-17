---@brief The reins panel: a CONTROL SURFACE, not a chat. Header, current step
---(collapsible), real buttons, a status line, and - only at levels/modes that
---allow it - a transcript section. Every piece of content is level-driven
---through reins.autonomy (caps/allows/transcript_mode) and
---config.plan.visibility. Refresh is event-driven, schedule-wrapped, and
---no-ops when the window is closed, so rapid events / headless mode / a nil
---plan can never error.
local autonomy = require("reins.autonomy")
local backend = require("reins.backend")
local config = require("reins.config")
local events = require("reins.events")
local store = require("reins.plan.store")
local transcript = require("reins.ui.transcript")
local util = require("reins.util")
local window = require("reins.ui.window")

local M = {}

---@type integer|nil the panel scratch buffer (created once, reused)
M._buf = nil
---@type string|nil last "status" event text (busy line)
M._status = nil
---@type boolean current-step detail collapsed (<Tab> toggles)
M._collapsed = false
---@type table<integer, fun(col: integer|nil)> line number -> <CR> action
M._actions = {}

local subscribed = false
local render_warned = false
local ns = vim.api.nvim_create_namespace("reins/panel")

-- Default-linked highlight groups (no hardcoded colors). ReinsGhost/ReinsHint
-- are also declared by complete.lua/hint.lua so those stay independent;
-- default=true makes the duplicate declarations harmless.
local HL = {
  ReinsHeader = "Title",
  ReinsButton = "Special",
  ReinsStepTitle = "Function",
  ReinsDetail = "Normal",
  ReinsDim = "Comment",
  ReinsOk = "DiagnosticOk",
  ReinsFail = "DiagnosticError",
  ReinsStatus = "MoreMsg",
  ReinsGhost = "Comment",
  ReinsHint = "DiagnosticVirtualTextHint",
}
for name, link in pairs(HL) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

local MARKER = { pending = " ", active = ">", verified = "x", skipped = "~" }

-- ------------------------------------------------------------- actions ----

local function do_goal()
  vim.ui.input({ prompt = "reins goal: " }, function(text)
    if text and text ~= "" then
      require("reins").goal(text)
    end
  end)
end

---Buttons for the current level. Returns the rendered line plus a <CR>
---dispatcher that picks the button under (or nearest after) the cursor.
---@return string line, fun(col: integer|nil) on_cr
local function build_buttons()
  local defs = {}
  local function b(label, fn)
    defs[#defs + 1] = { label, fn }
  end
  if autonomy.allows("verify") then
    b("[v]erify", function()
      require("reins").verify()
    end)
  end
  if autonomy.allows("next") then
    b("[n]ext", function()
      require("reins").next()
    end)
  end
  if autonomy.allows("implement") then
    b("[i]mplement", function()
      require("reins").implement()
    end)
  end
  b("[g]oal", do_goal)
  b("[p]lan", function()
    require("reins").open_plan(false)
  end)
  b("[a]utonomy", function()
    require("reins").cycle_autonomy()
  end)
  b("[q]uit", function()
    M.close()
  end)

  local parts, spans, col = {}, {}, 0
  for _, d in ipairs(defs) do
    if #parts > 0 then
      col = col + 2 -- "  " separator
    end
    local s = col + 1
    col = col + #d[1]
    parts[#parts + 1] = d[1]
    spans[#spans + 1] = { s = s, e = col, fn = d[2] }
  end
  local function on_cr(cursor_col)
    local c = cursor_col or 1
    local chosen = spans[#spans]
    for _, sp in ipairs(spans) do
      if c <= sp.e then
        chosen = sp
        break
      end
    end
    if chosen then
      chosen.fn()
    end
  end
  return table.concat(parts, "  "), on_cr
end

-- -------------------------------------------------------------- render ----

---@param st { root: string, plan: reins.Plan|nil, busy: boolean }
---@return string
local function header_line(st)
  local caps = autonomy.caps()
  local project = vim.fs.basename(st.root or "") or "?"
  local backend_str
  local adapter, model = backend.resolve("plan")
  if adapter then
    backend_str = adapter.name .. (model and (":" .. model) or "")
  else
    local _, name = backend.active()
    backend_str = name or "no backend"
  end
  return ("reins  %s  L%d %s  %s"):format(project, autonomy.level(), caps.name, backend_str)
end

---@param plan reins.Plan
---@param step reins.Step|nil
---@return integer|nil idx, integer total
local function step_index(plan, step)
  local total = #(plan.steps or {})
  if step then
    for i, s in ipairs(plan.steps or {}) do
      if s.id == step.id then
        return i, total
      end
    end
  end
  return nil, total
end

---@param step reins.Step
---@param add fun(text: string, hl: string|nil, action: fun(col: integer|nil)|nil)
local function add_detail(step, add)
  for _, l in ipairs(vim.split(step.detail or "", "\n", { plain = true })) do
    add("  " .. l, "ReinsDetail")
  end
end

---@param step reins.Step|nil
---@param add fun(text: string, hl: string|nil, action: fun(col: integer|nil)|nil)
local function add_last_verify(step, add)
  local lv = step and step.last_verify
  if not lv then
    return
  end
  -- Two confidence signals, both shown: the LLM's eyeball and the test run.
  local t = lv.tests
  local tests_str = (t and t.ran) and ("tests " .. (t.passed and "passed" or "FAILED")) or "tests not run"
  local good = lv.correct and (not t or not t.ran or t.passed)
  add("")
  add(
    ("verify: match %.2f · llm %s · %s"):format(lv.match_score or 0, lv.correct and "ok" or "NO", tests_str),
    good and "ReinsOk" or "ReinsFail"
  )
end

---Build and write the whole panel buffer. Called only via M.refresh().
---@param buf integer
local function render(buf)
  local lifecycle = require("reins.plan.lifecycle")
  local st = lifecycle.state()
  local caps = autonomy.caps()
  local vis = config.get().plan.visibility

  local lines, hls, actions = {}, {}, {}
  local function add(text, hl, action)
    lines[#lines + 1] = text
    if hl then
      hls[#lines] = hl
    end
    if action then
      actions[#lines] = action
    end
  end

  add(header_line(st), "ReinsHeader")
  add("")

  if not caps.panel then
    -- Level 0: the plan is deliberately not surfaced; keep the panel honest.
    add(("autonomy %d (%s): the plan is not surfaced at this level."):format(autonomy.level(), caps.name), "ReinsDim")
    add("only :ReinsHint is active here; [a]utonomy raises the level.", "ReinsDim")
  elseif not st.plan then
    add("no plan - [g]oal to start", "ReinsButton", do_goal)
  else
    local plan = st.plan
    local step = store.get_step(plan)
    if vis == "full" then
      for i, s in ipairs(plan.steps or {}) do
        local cur = step ~= nil and s.id == step.id
        add(("[%s] step %d: %s"):format(MARKER[s.status] or "?", i, s.title or "?"), cur and "ReinsStepTitle" or "ReinsDim")
        if cur then
          if M._collapsed then
            add("  … (<Tab> expands the step detail)", "ReinsDim")
          else
            add_detail(s, add)
          end
        end
      end
    elseif step then
      -- "hidden": title only + controls. "current-only": + status + detail.
      local idx, total = step_index(plan, step)
      add(("step %s/%d: %s"):format(idx and tostring(idx) or "?", total, step.title or "?"), "ReinsStepTitle")
      if vis ~= "hidden" then
        add("status: " .. (step.status or "?"), "ReinsDim")
        if M._collapsed then
          add("  … (<Tab> expands the step detail)", "ReinsDim")
        else
          add_detail(step, add)
        end
      end
    else
      add("plan has no current step - [n]ext to pick one", "ReinsDim")
    end
    add_last_verify(step, add)
  end

  add("")
  local btn_line, btn_action = build_buttons()
  add(btn_line, "ReinsButton", btn_action)

  if M._status then
    add("")
    add("⋯ " .. M._status, "ReinsStatus")
  end

  -- Transcript section: only when the panel has content at this level AND the
  -- effective mode shows anything ("hidden" = no raw AI text renders anywhere).
  if caps.panel and autonomy.transcript_mode() ~= "hidden" then
    local win = window.win()
    local height = win and vim.api.nvim_win_get_height(win) or config.get().ui.height
    local room = math.max(2, height - #lines - 2)
    local tlines = transcript.lines(room)
    if #tlines > 0 then
      add("")
      add("── transcript " .. ("─"):rep(24), "ReinsDim")
      for _, l in ipairs(tlines) do
        add(l, "ReinsDim")
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for lnum, hl in pairs(hls) do
    if #lines[lnum] > 0 then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, 0, {
        end_row = lnum - 1,
        end_col = #lines[lnum],
        hl_group = hl,
      })
    end
  end
  M._actions = actions
end

-- -------------------------------------------------------------- buffer ----

---@return integer bufnr
local function ensure_buf()
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    return M._buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "reins-panel"
  pcall(vim.api.nvim_buf_set_name, buf, "reins://panel")

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "reins: " .. desc })
  end
  map("g", do_goal, "set goal")
  map("v", function()
    require("reins").verify()
  end, "verify step")
  map("n", function()
    require("reins").next()
  end, "next step")
  map("i", function()
    -- Gated inside require("reins").implement(); warns below level 3.
    require("reins").implement()
  end, "implement step")
  map("p", function()
    require("reins").open_plan(false)
  end, "open plan")
  map("a", function()
    require("reins").cycle_autonomy()
  end, "cycle autonomy")
  map("q", function()
    M.close()
  end, "close panel")
  map("<Tab>", function()
    M.toggle_collapse()
  end, "toggle step detail")
  map("<CR>", function()
    local pos = vim.api.nvim_win_get_cursor(0)
    local action = M._actions[pos[1]]
    if action then
      action(pos[2] + 1)
    end
  end, "activate line")

  M._buf = buf
  return buf
end

-- -------------------------------------------------------------- events ----

local pending = false
local function schedule_refresh()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    M.refresh()
  end)
end

local function subscribe()
  if subscribed then
    return
  end
  subscribed = true
  events.on("plan_updated", schedule_refresh)
  events.on("autonomy_changed", schedule_refresh)
  events.on("backend_changed", schedule_refresh)
  events.on("transcript", schedule_refresh)
  events.on("status", function(text)
    M._status = text
    schedule_refresh()
  end)
end

-- ---------------------------------------------------------- public API ----

---Re-render the panel. Safe to call at any time: no-ops when the window is
---closed or the buffer is gone; render errors are contained (warned once).
function M.refresh()
  if not window.is_open() then
    return
  end
  local buf = M._buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local ok, err = pcall(render, buf)
  if not ok and not render_warned then
    render_warned = true
    util.warn("panel render failed: " .. tostring(err))
  end
end

function M.open()
  local buf = ensure_buf()
  subscribe()
  if not window.is_open() then
    window.open(buf)
  end
  M.refresh()
end

function M.close()
  window.close()
end

function M.toggle()
  if window.is_open() then
    M.close()
  else
    M.open()
  end
end

---Collapse/expand the current step's detail (<Tab> in the panel).
function M.toggle_collapse()
  M._collapsed = not M._collapsed
  M.refresh()
end

return M
