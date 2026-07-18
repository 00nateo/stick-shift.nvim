---@brief Public API for stick-shift.nvim: setup(), commands, keymaps.
---
---stick-shift is a configurable handicap on AI assistance: a single autonomy level
---(0-4) governs how much the AI does, from a one-sentence hint to a full
---agent. See :help stick-shift.
local M = {}

local function cfg()
  return require("stick-shift.config").get()
end

---Register built-in backend adapters. Periphery adapters are pcall-required
---so a partially-installed tree still loads the core.
local function register_backends()
  local backend = require("stick-shift.backend")
  backend.register("mock", require("stick-shift.backend.mock"))
  for _, name in ipairs({ "claude_code", "ollama", "acp", "local_mac" }) do
    local ok, adapter = pcall(require, "stick-shift.backend." .. name)
    if ok then
      backend.register(name, adapter)
    end
  end
end

local function define_commands()
  local api = vim.api

  api.nvim_create_user_command("StickShift", function(o)
    if o.args ~= "" then
      M.set_layout(o.args)
    else
      M.toggle_panel()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "left", "right", "top", "bottom", "float" }
    end,
    desc = "stick-shift: toggle the panel, or move it (:StickShift float / left / right / top / bottom)",
  })

  api.nvim_create_user_command("StickShiftGoal", function(o)
    if o.args ~= "" then
      M.goal(o.args)
    else
      vim.ui.input({ prompt = "stick-shift goal: " }, function(text)
        if text and text ~= "" then
          M.goal(text)
        end
      end)
    end
  end, { nargs = "*", desc = "stick-shift: set the goal and create the living plan" })

  api.nvim_create_user_command("StickShiftPlan", function(o)
    M.open_plan(o.bang)
  end, { bang = true, desc = "stick-shift: inspect the living plan (! = edit, autonomy <= 2)" })

  api.nvim_create_user_command("StickShiftVerify", function()
    M.verify()
  end, { desc = "stick-shift: verify the current step" })

  api.nvim_create_user_command("StickShiftNext", function()
    M.next()
  end, { desc = "stick-shift: advance to the next step" })

  api.nvim_create_user_command("StickShiftImplement", function()
    M.implement()
  end, { desc = "stick-shift: let the agent implement the current step (autonomy >= 3)" })

  api.nvim_create_user_command("StickShiftHint", function()
    M.hint()
  end, { desc = "stick-shift: show a one-sentence hint" })

  api.nvim_create_user_command("StickShiftAutonomy", function(o)
    if o.args == "" then
      local autonomy = require("stick-shift.autonomy")
      require("stick-shift.util").notify(
        ("autonomy %d (%s)"):format(autonomy.level(), autonomy.name())
      )
    else
      M.set_autonomy(tonumber(o.args))
    end
  end, {
    nargs = "?",
    complete = function()
      return { "0", "1", "2", "3", "4" }
    end,
    desc = "stick-shift: show or set the autonomy level (0-4)",
  })

  api.nvim_create_user_command("StickShiftBackend", function(o)
    if o.args == "" then
      local _, name = require("stick-shift.backend").active()
      require("stick-shift.util").notify("backend: " .. tostring(name))
    else
      M.set_backend(o.args)
    end
  end, {
    nargs = "?",
    complete = function()
      return require("stick-shift.backend").list()
    end,
    desc = "stick-shift: show or switch the active backend",
  })

  api.nvim_create_user_command("StickShiftRevert", function()
    M.revert()
  end, { desc = "stick-shift: roll back to the last checkpoint" })
end

local function define_keymaps()
  local maps = cfg().keymaps
  local function map(lhs, fn, desc)
    if lhs and lhs ~= false and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { desc = desc, silent = true })
    end
  end
  map(maps.toggle_panel, M.toggle_panel, "stick-shift: toggle panel")
  map(maps.verify, M.verify, "stick-shift: verify step")
  map(maps.next, M.next, "stick-shift: next step")
  map(maps.cycle_autonomy, M.cycle_autonomy, "stick-shift: cycle autonomy level")
  map(maps.hint, M.hint, "stick-shift: hint")
end

---@param opts table|nil see :help stick-shift-config
function M.setup(opts)
  require("stick-shift.config").setup(opts)
  register_backends()

  local backend = require("stick-shift.backend")
  local util = require("stick-shift.util")
  local ok = backend.use(cfg().backend)
  if not ok then
    util.warn(("backend %q is not available; falling back to mock"):format(cfg().backend))
    backend.use("mock")
  end

  define_commands()
  define_keymaps()

  -- Periphery features degrade gracefully while the tree is partial.
  local has_complete, complete = pcall(require, "stick-shift.complete")
  if has_complete then
    complete.setup()
  end
  local has_hint, hint = pcall(require, "stick-shift.hint")
  if has_hint then
    hint.setup()
  end
  local has_cp, checkpoint = pcall(require, "stick-shift.checkpoint")
  if has_cp then
    checkpoint.setup()
  end

  local autonomy = require("stick-shift.autonomy")
  if cfg().ui.open_on_start or autonomy.caps().panel_open_default then
    vim.schedule(function()
      local has_panel, panel = pcall(require, "stick-shift.ui.panel")
      if has_panel then
        panel.open()
      end
    end)
  end
end

-- ------------------------------------------------------------ public API ----

function M.toggle_panel()
  local ok, panel = pcall(require, "stick-shift.ui.panel")
  if not ok then
    require("stick-shift.util").warn("panel module not available")
    return
  end
  panel.toggle()
end

---Move the panel to a new position (opens it if closed).
---@param layout string "left"|"top"|"right"|"bottom"|"float"
function M.set_layout(layout)
  local ok, window = pcall(require, "stick-shift.ui.window")
  if not ok then
    require("stick-shift.util").warn("panel module not available")
    return
  end
  window.set_layout(layout)
  if not window.is_open() then
    local has_panel, panel = pcall(require, "stick-shift.ui.panel")
    if has_panel then
      panel.open()
    end
  end
end

---@param text string
function M.goal(text)
  require("stick-shift.plan.lifecycle").start(text)
end

function M.verify()
  require("stick-shift.plan.lifecycle").verify()
end

function M.next()
  require("stick-shift.plan.lifecycle").next()
end

function M.implement()
  require("stick-shift.plan.lifecycle").implement()
end

function M.hint()
  local autonomy = require("stick-shift.autonomy")
  if not autonomy.allows("hint_manual") then
    require("stick-shift.util").warn("hints are disabled (hint.enabled = false)")
    return
  end
  local ok, hint = pcall(require, "stick-shift.hint")
  if not ok then
    require("stick-shift.util").warn("hint module not available")
    return
  end
  hint.show()
end

---Open the living plan: read-only rendered markdown, or the editable
---plan.json with <bang> (allowed at autonomy <= 2 - the human may rewrite the
---AI's working memory at low levels).
---@param bang boolean
function M.open_plan(bang)
  local lifecycle = require("stick-shift.plan.lifecycle")
  local store = require("stick-shift.plan.store")
  local util = require("stick-shift.util")
  local st = lifecycle.state()
  if not st.plan then
    util.warn("no plan yet - set a goal with :StickShiftGoal")
    return
  end
  local dir = store.dir(st.root)
  if bang then
    if not require("stick-shift.autonomy").plan_editable() then
      util.warn("plan editing is a low-autonomy affordance (level <= 2); use :StickShiftAutonomy 2")
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/plan.json"))
  else
    store.save(st.root, st.plan) -- refresh the rendered markdown first
    vim.cmd("view " .. vim.fn.fnameescape(dir .. "/plan.md"))
  end
end

---@param level integer 0..4
function M.set_autonomy(level)
  local util = require("stick-shift.util")
  if type(level) ~= "number" or level < 0 or level > 4 or level % 1 ~= 0 then
    util.warn("autonomy must be an integer 0..4")
    return
  end
  local config = require("stick-shift.config")
  config.get().autonomy = level
  local autonomy = require("stick-shift.autonomy")
  require("stick-shift.events").emit("autonomy_changed", level)
  util.notify(("autonomy %d (%s)"):format(level, autonomy.name()))
end

function M.cycle_autonomy()
  M.set_autonomy((require("stick-shift.autonomy").level() + 1) % 5)
end

---@param name string
function M.set_backend(name)
  local backend = require("stick-shift.backend")
  local util = require("stick-shift.util")
  local ok, err = backend.use(name)
  if not ok then
    util.warn(err)
    return
  end
  local adapter = backend.active()
  local avail, msg = adapter.available()
  if not avail then
    util.warn(("backend %q selected but not ready: %s"):format(name, msg or "unavailable"))
  else
    util.notify("backend: " .. name)
  end
end

function M.revert()
  local ok, checkpoint = pcall(require, "stick-shift.checkpoint")
  if not ok then
    require("stick-shift.util").warn("checkpoint module not available")
    return
  end
  checkpoint.revert()
end

return M
