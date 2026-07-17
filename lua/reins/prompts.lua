---@brief Versioned prompt-template and schema loader.
---Templates live in prompts/<VERSION>/<op>.{system,user}.md as data, so they
---can be tuned without touching Lua logic. `{{var}}` placeholders are
---substituted from a vars table; unknown vars become "".
local util = require("reins.util")

local M = {}

M.VERSION = "v1"

---@type table<string, string> template cache, keyed by relative path
local cache = {}
---@type table<string, table|false> schema cache (false = no schema for op)
local schemas = {}

local function template_path(rel)
  return util.plugin_root() .. "/prompts/" .. M.VERSION .. "/" .. rel
end

---@param rel string e.g. "plan.system.md"
---@return string
local function load_template(rel)
  if cache[rel] == nil then
    local content, err = util.read_file(template_path(rel))
    if not content then
      error("reins: missing prompt template " .. rel .. " (" .. tostring(err) .. ")")
    end
    cache[rel] = content
  end
  return cache[rel]
end

---@param text string
---@param vars table<string, any>
---@return string
function M.substitute(text, vars)
  return (text:gsub("{{([%w_]+)}}", function(name)
    local v = vars[name]
    if v == nil then
      return ""
    end
    if type(v) == "table" then
      return vim.json.encode(v)
    end
    return tostring(v)
  end))
end

---Render the system and user prompts for an op.
---@param op "plan"|"verify"|"next_step"|"hint"|"complete"|"implement"
---@param vars table<string, any>
---@return string system, string user
function M.render(op, vars)
  local system = M.substitute(load_template(op .. ".system.md"), vars)
  local user = M.substitute(load_template(op .. ".user.md"), vars)
  return vim.trim(system), vim.trim(user)
end

---Decoded JSON schema for an op's output, or nil for freeform ops (implement).
---@param op string
---@return table|nil
function M.schema(op)
  if schemas[op] == nil then
    local content = util.read_file(template_path("schemas/" .. op .. ".json"))
    if content then
      local ok, decoded = pcall(vim.json.decode, content)
      schemas[op] = ok and decoded or false
      if not ok then
        util.error("prompts: schema " .. op .. ".json is invalid JSON")
      end
    else
      schemas[op] = false
    end
  end
  return schemas[op] or nil
end

return M
