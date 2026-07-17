---@brief Config schema, defaults, and validation for reins.nvim.
local util = require("reins.util")

local M = {}

---@class reins.Config
M.defaults = {
  -- 0..4: hint-only, navigator, co-pilot, driver-assist, autopilot. See :help reins-autonomy.
  autonomy = 2,
  -- Active backend adapter: "claude_code" | "acp" | "ollama" | "local_mac" | "mock"
  backend = "claude_code",
  -- Per-role model routing, decoupled from autonomy. Each value is either an
  -- alias string ("local"/"frontier"/explicit model name) resolved by the
  -- active adapter, or { backend = "<adapter>", model = "<name>" } to pin a
  -- different adapter for that role.
  models = {
    ghost = "local",
    hint = "local",
    plan = "frontier",
    verify = "frontier",
    next_step = "frontier",
  },
  ui = {
    layout = "right", -- "left" | "top" | "right" | "bottom" | "float" (movable live via :Reins {layout})
    transcript = nil, -- nil = derive from autonomy; else "full"|"summary"|"hidden"
    open_on_start = false, -- note: at autonomy 3-4 the panel opens on setup regardless
    width = 48, -- columns for left/right docks and float
    height = 14, -- rows for top/bottom docks and float
  },
  plan = {
    visibility = "current-only", -- "hidden" | "current-only" | "full"
  },
  completion = {
    level = "line", -- "off" | "word" | "line" | "multiline" | "paragraph"
    accept_key = "<Tab>",
    debounce_ms = 180,
    force = false, -- allow completion below autonomy level 2
  },
  hint = {
    enabled = true,
    trigger = "manual", -- "auto" | "manual"
    max_len = 120,
  },
  verify = {
    test_command = nil, -- string; nil = auto-detect when auto_detect_tests
    auto_detect_tests = true,
    timeout_ms = 120000,
  },
  git = {
    tag_commits = false, -- add "Reins-Autonomy: N (name)" trailer to assisted commits
    checkpoint = true, -- snapshot before agent-driven edits (levels 3-4)
  },
  backends = {
    claude_code = {
      bin = "claude",
      model_local = "haiku", -- CLI alias; cheap roles
      model_frontier = nil, -- nil = the CLI's configured default model
      extra_args = {},
    },
    ollama = {
      host = "http://localhost:11434",
      model_local = "qwen3-coder:30b",
      model_frontier = "qwen3-coder:30b",
    },
    acp = {
      command = nil, -- argv table, e.g. { "claude-code-acp" }
    },
    local_mac = {
      url = "http://localhost:8080/v1",
      model = "default",
    },
  },
  keymaps = {
    -- set any to false to disable
    toggle_panel = "<leader>rr",
    verify = "<leader>rv",
    next = "<leader>rn",
    cycle_autonomy = "<leader>ra",
    hint = "<leader>rh",
  },
}

-- Declarative validation: leaf spec = { type, enum?, min?, max?, nilable? }.
-- type "any-model" accepts string or {backend=,model=} table.
local V = {
  autonomy = { type = "number", min = 0, max = 4 },
  backend = { type = "string" },
  models = {
    ghost = { type = "any-model" },
    hint = { type = "any-model" },
    plan = { type = "any-model" },
    verify = { type = "any-model" },
    next_step = { type = "any-model" },
  },
  ui = {
    layout = { type = "string", enum = { "left", "top", "right", "bottom", "float" } },
    transcript = { type = "string", enum = { "full", "summary", "hidden" }, nilable = true },
    open_on_start = { type = "boolean" },
    width = { type = "number", min = 10 },
    height = { type = "number", min = 3 },
  },
  plan = {
    visibility = { type = "string", enum = { "hidden", "current-only", "full" } },
  },
  completion = {
    level = { type = "string", enum = { "off", "word", "line", "multiline", "paragraph" } },
    accept_key = { type = "string" },
    debounce_ms = { type = "number", min = 0 },
    force = { type = "boolean" },
  },
  hint = {
    enabled = { type = "boolean" },
    trigger = { type = "string", enum = { "auto", "manual" } },
    max_len = { type = "number", min = 20 },
  },
  verify = {
    test_command = { type = "string", nilable = true },
    auto_detect_tests = { type = "boolean" },
    timeout_ms = { type = "number", min = 1000 },
  },
  git = {
    tag_commits = { type = "boolean" },
    checkpoint = { type = "boolean" },
  },
  backends = { type = "open-table" }, -- adapter-specific, shallow-checked only
  keymaps = { type = "open-table" }, -- string|false per key
}

local function is_leaf_spec(spec)
  return type(spec) == "table" and type(spec.type) == "string"
end

---@param user table
---@param spec table
---@param path string
---@param problems string[]
---@param strip boolean when true, offending keys are removed from `user` so
---the later merge falls back to the defaults for them
local function check(user, spec, path, problems, strip)
  for key, val in pairs(user) do
    local sub = spec[key]
    local where = path == "" and tostring(key) or (path .. "." .. key)
    local function bad(msg)
      table.insert(problems, msg)
      if strip then
        user[key] = nil
      end
    end
    if sub == nil then
      bad("unknown option `" .. where .. "` (ignored)")
    elseif is_leaf_spec(sub) then
      if sub.type == "open-table" then
        if type(val) ~= "table" then
          bad("`" .. where .. "` must be a table")
        end
      elseif sub.type == "any-model" then
        local ok = type(val) == "string"
          or (type(val) == "table" and (type(val.model) == "string" or type(val.backend) == "string"))
        if not ok then
          bad("`" .. where .. "` must be a string or {backend=, model=}")
        end
      elseif type(val) ~= sub.type then
        bad(("`%s` must be a %s, got %s"):format(where, sub.type, type(val)))
      else
        if sub.enum and not vim.tbl_contains(sub.enum, val) then
          bad(("`%s` must be one of: %s"):format(where, table.concat(sub.enum, ", ")))
        end
        if type(val) == "number" then
          if sub.min and val < sub.min then
            bad(("`%s` must be >= %d"):format(where, sub.min))
          end
          if sub.max and val > sub.max then
            bad(("`%s` must be <= %d"):format(where, sub.max))
          end
        end
      end
    elseif type(sub) == "table" then
      if type(val) ~= "table" then
        bad("`" .. where .. "` must be a table")
      else
        check(val, sub, where, problems, strip)
      end
    end
  end
end

---Validate a user opts table against the schema.
---@param user table
---@return string[] problems (empty when clean)
function M.validate(user)
  local problems = {}
  if type(user) ~= "table" then
    return { "setup() expects a table" }
  end
  check(user, V, "", problems, false)
  return problems
end

---@type reins.Config
M.current = vim.deepcopy(M.defaults)

---Merge and validate user options. Invalid leaves are reported (vim.notify)
---and the offending values fall back to defaults; unknown keys warn.
---@param user table|nil
---@return reins.Config
function M.setup(user)
  user = user or {}
  if type(user) ~= "table" then
    util.warn("config: setup() expects a table")
    user = {}
  end
  -- Validate against a copy with strip=true: flagged leaves are removed so the
  -- merge below genuinely falls back to defaults for them.
  local cleaned = vim.deepcopy(user)
  local problems = {}
  check(cleaned, V, "", problems, true)
  for _, p in ipairs(problems) do
    util.warn("config: " .. p)
  end
  M.current = util.deep_merge(M.defaults, cleaned)
  -- Autonomy is special-cased: a numeric out-of-range value is clamped rather
  -- than reverted ("autonomy = 99" clearly means "as much as possible"), and a
  -- broken value would poison all gating, so never trust it blindly.
  if type(user.autonomy) == "number" then
    M.current.autonomy = user.autonomy
  elseif type(M.current.autonomy) ~= "number" then
    M.current.autonomy = M.defaults.autonomy
  end
  M.current.autonomy = math.max(0, math.min(4, math.floor(M.current.autonomy)))
  return M.current
end

---@return reins.Config
function M.get()
  return M.current
end

return M
