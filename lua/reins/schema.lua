---@brief Minimal JSON-Schema-subset validator for backend output contracts.
---Supports: type (object/array/string/number/integer/boolean), properties,
---required, items, enum, minimum, maximum. Extra properties are allowed
---(LLMs love adding fields; we only care that what we read is well-typed).
local M = {}

local islist = vim.islist or vim.tbl_islist

local function typename(v)
  local t = type(v)
  if t == "table" then
    if next(v) == nil then
      return "empty" -- decodable as either object or array
    end
    return islist(v) and "array" or "object"
  end
  return t
end

---@param value any
---@param schema table
---@param path string|nil
---@return boolean ok, string|nil err
function M.validate(value, schema, path)
  path = path or "$"
  local want = schema.type
  if want then
    local got = typename(value)
    local matches
    if want == "integer" then
      matches = got == "number" and value % 1 == 0
    elseif want == "number" then
      matches = got == "number"
    elseif want == "object" or want == "array" then
      matches = got == want or got == "empty"
    else
      matches = got == want
    end
    if not matches then
      return false, ("%s: expected %s, got %s"):format(path, want, got)
    end
  end
  if schema.enum then
    local found = false
    for _, e in ipairs(schema.enum) do
      if value == e then
        found = true
        break
      end
    end
    if not found then
      return false, ("%s: %s not in enum"):format(path, vim.inspect(value))
    end
  end
  if type(value) == "number" then
    if schema.minimum and value < schema.minimum then
      return false, ("%s: %s < minimum %s"):format(path, value, schema.minimum)
    end
    if schema.maximum and value > schema.maximum then
      return false, ("%s: %s > maximum %s"):format(path, value, schema.maximum)
    end
  end
  if want == "object" and type(value) == "table" then
    for _, req in ipairs(schema.required or {}) do
      if value[req] == nil then
        return false, ("%s.%s: required field missing"):format(path, req)
      end
    end
    for key, sub in pairs(schema.properties or {}) do
      if value[key] ~= nil then
        local ok, err = M.validate(value[key], sub, path .. "." .. key)
        if not ok then
          return false, err
        end
      end
    end
  end
  if want == "array" and type(value) == "table" and schema.items then
    for i, item in ipairs(value) do
      local ok, err = M.validate(item, schema.items, ("%s[%d]"):format(path, i))
      if not ok then
        return false, err
      end
    end
  end
  return true
end

return M
