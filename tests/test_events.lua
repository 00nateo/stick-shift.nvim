-- Offline tests for lua/reins/events.lua: on/emit/unsubscribe, multiple
-- handlers, error containment, reset. Emit is synchronous; only the error
-- report goes through vim.schedule, so those tests drain with vim.wait.
local T = {}

local function fresh()
  local events = require("reins.events")
  events.reset()
  return events
end

T["on + emit delivers all arguments synchronously"] = function()
  local events = fresh()
  local got
  events.on("plan_updated", function(a, b, c)
    got = { a, b, c }
  end)
  events.emit("plan_updated", 1, "two", { three = 3 })
  assert(got, "handler ran synchronously during emit")
  assert(got[1] == 1 and got[2] == "two" and got[3].three == 3, vim.inspect(got))
end

T["multiple handlers on one event all fire"] = function()
  local events = fresh()
  local a, b = 0, 0
  events.on("status", function()
    a = a + 1
  end)
  events.on("status", function()
    b = b + 1
  end)
  events.emit("status", "busy")
  events.emit("status", nil)
  assert(a == 2, "first handler saw both emits, got " .. a)
  assert(b == 2, "second handler saw both emits, got " .. b)
end

T["handlers only fire for their own event name"] = function()
  local events = fresh()
  local fired = {}
  events.on("autonomy_changed", function()
    fired.autonomy = true
  end)
  events.on("backend_changed", function()
    fired.backend = true
  end)
  events.emit("autonomy_changed", 2)
  assert(fired.autonomy == true)
  assert(fired.backend == nil, "unrelated event must not fire")
end

T["unsubscribe stops delivery and leaves other handlers intact"] = function()
  local events = fresh()
  local a, b = 0, 0
  local off_a = events.on("transcript", function()
    a = a + 1
  end)
  events.on("transcript", function()
    b = b + 1
  end)
  events.emit("transcript", { kind = "event", op = "x", text = "t" })
  assert(a == 1 and b == 1)
  off_a()
  events.emit("transcript", { kind = "event", op = "y", text = "t" })
  assert(a == 1, "unsubscribed handler must not fire again")
  assert(b == 2, "remaining handler still fires")
  off_a() -- double-unsubscribe is a safe no-op
  events.emit("transcript", { kind = "event", op = "z", text = "t" })
  assert(a == 1 and b == 3)
end

T["handler error does not break the other handlers"] = function()
  local events = fresh()
  local survivor_calls = 0
  events.on("boom", function()
    error("intentional handler failure")
  end)
  events.on("boom", function()
    survivor_calls = survivor_calls + 1
  end)
  events.on("boom", function()
    error("second intentional failure")
  end)
  events.emit("boom", 42)
  assert(survivor_calls == 1, "healthy handler must still run, got " .. survivor_calls)
  events.emit("boom", 43)
  assert(survivor_calls == 2, "bus keeps working after handler errors")
end

T["handler error is reported once via vim.notify at ERROR level"] = function()
  local events = fresh()
  -- Error reports from earlier tests may still sit in the schedule queue;
  -- vim.schedule is FIFO, so once a sentinel runs, everything older has run
  -- under the runner's silenced vim.notify and cannot leak into our stub.
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  vim.wait(2000, function()
    return drained
  end)
  events.on("explode", function()
    error("kaboom")
  end)
  local orig = vim.notify
  local msgs = {}
  vim.notify = function(msg, level)
    local text = tostring(msg)
    if text:find("explode", 1, true) then
      msgs[#msgs + 1] = { msg = text, level = level }
    end
  end
  local ok, err = pcall(function()
    events.emit("explode")
    -- the report is vim.schedule()d; drain the main loop
    vim.wait(2000, function()
      return #msgs > 0
    end)
  end)
  vim.notify = orig
  assert(ok, tostring(err))
  assert(#msgs == 1, "expected exactly one report, got " .. #msgs)
  assert(msgs[1].msg:find("event handler error (explode)", 1, true), msgs[1].msg)
  assert(msgs[1].msg:find("kaboom", 1, true), msgs[1].msg)
  assert(msgs[1].level == vim.log.levels.ERROR)
end

T["emit with no handlers is a no-op"] = function()
  local events = fresh()
  events.emit("nobody_listens", 1, 2, 3) -- must not error
end

T["reset removes every handler"] = function()
  local events = fresh()
  local calls = 0
  local off = events.on("a", function()
    calls = calls + 1
  end)
  events.on("b", function()
    calls = calls + 1
  end)
  events.reset()
  events.emit("a")
  events.emit("b")
  assert(calls == 0, "no handler may survive reset, got " .. calls)
  off() -- stale unsubscribe after reset must not error
  -- bus is still usable after reset
  events.on("a", function()
    calls = calls + 1
  end)
  events.emit("a")
  assert(calls == 1)
end

return T
