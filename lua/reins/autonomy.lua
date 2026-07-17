---@brief The autonomy ladder (0-4). Single source of truth for feature gating.
---Every module asks this table what it may do; nothing else encodes level logic.
local config = require("reins.config")

local M = {}

---@class reins.Caps
---@field name string
---@field completion boolean ghost-text completion may run
---@field hint_manual boolean :ReinsHint / keymap works
---@field hint_auto boolean hint may fire on its own (still needs hint.trigger="auto")
---@field panel boolean the step panel has content (plan surfaced)
---@field verify boolean Verify step available
---@field next boolean Next step available
---@field implement boolean Implement step available (agent writes on request)
---@field agent_free boolean agent may write without step-boundary confirmation
---@field transcript_default "full"|"summary"|"hidden"
---@field panel_open_default boolean open panel on setup

---Ordered gating table. Keep in sync with :help reins-autonomy and the tests,
---which assert every cell.
---@type table<integer, reins.Caps>
M.LEVELS = {
  [0] = {
    name = "hint-only",
    completion = false,
    hint_manual = true,
    hint_auto = false,
    panel = false,
    verify = false,
    next = false,
    implement = false,
    agent_free = false,
    transcript_default = "hidden",
    panel_open_default = false,
  },
  [1] = {
    name = "navigator",
    completion = false,
    hint_manual = true,
    hint_auto = false,
    panel = true,
    verify = true,
    next = true,
    implement = false,
    agent_free = false,
    transcript_default = "hidden",
    panel_open_default = false,
  },
  [2] = {
    name = "co-pilot",
    completion = true,
    hint_manual = true,
    hint_auto = true,
    panel = true,
    verify = true,
    next = true,
    implement = false,
    agent_free = false,
    transcript_default = "hidden",
    panel_open_default = false,
  },
  [3] = {
    name = "driver-assist",
    completion = true,
    hint_manual = true,
    hint_auto = true,
    panel = true,
    verify = true,
    next = true,
    implement = true,
    agent_free = false,
    transcript_default = "summary",
    panel_open_default = true,
  },
  [4] = {
    name = "autopilot",
    completion = true,
    hint_manual = true,
    hint_auto = true,
    panel = true,
    verify = true,
    next = true,
    implement = true,
    agent_free = true,
    transcript_default = "full",
    panel_open_default = true,
  },
}

---@return integer
function M.level()
  return config.get().autonomy
end

---@param level integer|nil defaults to the active level
---@return reins.Caps
function M.caps(level)
  return M.LEVELS[level or M.level()]
end

---@param level integer|nil
---@return string
function M.name(level)
  return M.caps(level).name
end

---Feature check against the ACTIVE level, with config overrides applied
---(completion.force, hint.trigger). Use this, not caps(), from feature code.
---@param feature "completion"|"hint_manual"|"hint_auto"|"panel"|"verify"|"next"|"implement"|"agent_free"
---@return boolean
function M.allows(feature)
  local cfg = config.get()
  local caps = M.caps()
  if feature == "completion" then
    if cfg.completion.level == "off" then
      return false
    end
    return caps.completion or cfg.completion.force
  end
  if feature == "hint_auto" then
    return caps.hint_auto and cfg.hint.enabled and cfg.hint.trigger == "auto"
  end
  if feature == "hint_manual" then
    return caps.hint_manual and cfg.hint.enabled
  end
  return caps[feature] == true
end

---Effective transcript mode: explicit config wins, else level default.
---@return "full"|"summary"|"hidden"
function M.transcript_mode()
  return config.get().ui.transcript or M.caps().transcript_default
end

---Plan editing (:ReinsPlan!) is a low-autonomy affordance: the human may
---rewrite the AI's working memory at levels <= 2.
---@return boolean
function M.plan_editable()
  return M.level() <= 2
end

return M
