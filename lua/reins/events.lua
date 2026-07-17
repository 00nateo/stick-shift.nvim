---@brief Tiny pub/sub bus decoupling core logic from UI.
---
---Events used by reins:
---  "autonomy_changed"  (new_level: integer)
---  "backend_changed"   (name: string)
---  "plan_updated"      (plan: table)
---  "status"            (text: string|nil)  -- nil clears the busy line
---  "transcript"        (entry: {kind:"request"|"response"|"event", op:string, text:string})
local M = {}

---@type table<string, table<integer, fun(...)>>
local handlers = {}
local next_id = 0

---Subscribe to an event. Returns an unsubscribe function.
---@param name string
---@param fn fun(...)
---@return fun() unsubscribe
function M.on(name, fn)
  handlers[name] = handlers[name] or {}
  next_id = next_id + 1
  local id = next_id
  handlers[name][id] = fn
  return function()
    if handlers[name] then
      handlers[name][id] = nil
    end
  end
end

---Emit an event. Handler errors are contained and reported once.
---@param name string
function M.emit(name, ...)
  for _, fn in pairs(handlers[name] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.schedule(function()
        vim.notify("[reins] event handler error (" .. name .. "): " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

---Remove all handlers (test helper).
function M.reset()
  handlers = {}
end

return M
