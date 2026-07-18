-- Offline tests for lua/stick-shift/lock.lua: per-buffer single-writer try-lock.
-- Buffer numbers are plain integer keys to the lock table; no real buffers needed.
local lock = require("stick-shift.lock")

local T = {}

T["acquire returns a token and records the owner"] = function()
  lock.reset()
  local token, holder = lock.acquire(101, "completion")
  assert(type(token) == "number", "expected numeric token, got " .. type(token))
  assert(holder == nil, "no holder expected on successful acquire")
  assert(lock.holder(101) == "completion", "holder() should report the owner")
end

T["second writer is rejected while the lock is held"] = function()
  lock.reset()
  local token = lock.acquire(101, "completion")
  assert(token, "first acquire must succeed")
  local token2, holder = lock.acquire(101, "agent")
  assert(token2 == nil, "second acquire must be rejected, got token " .. tostring(token2))
  assert(holder == "completion", "rejection must name the current holder, got " .. tostring(holder))
  assert(lock.holder(101) == "completion", "original owner must still hold the lock")
end

T["release with a mismatched token fails and the lock stays held"] = function()
  lock.reset()
  local token = lock.acquire(101, "completion")
  assert(token, "acquire must succeed")
  assert(lock.release(101, token + 999) == false, "foreign token must not release the lock")
  assert(lock.holder(101) == "completion", "lock must remain held after bad release")
  -- and the rightful token still works afterwards
  assert(lock.release(101, token) == true, "correct token must release")
end

T["release with the correct token frees the buffer for reacquisition"] = function()
  lock.reset()
  local token = lock.acquire(101, "completion")
  assert(lock.release(101, token) == true)
  assert(lock.holder(101) == nil, "no holder after release")
  local token2 = lock.acquire(101, "agent")
  assert(token2, "reacquire after release must succeed")
  assert(token2 ~= token, "tokens must not be reused")
  assert(lock.holder(101) == "agent")
end

T["release on an unlocked buffer returns false"] = function()
  lock.reset()
  assert(lock.release(101, 1) == false, "releasing an unheld lock must return false")
end

T["locks on different buffers are independent"] = function()
  lock.reset()
  local t1 = lock.acquire(101, "completion")
  local t2 = lock.acquire(202, "agent")
  assert(t1 and t2, "both buffers must lock independently")
  assert(lock.holder(101) == "completion")
  assert(lock.holder(202) == "agent")
  -- releasing one must not affect the other
  assert(lock.release(101, t1) == true)
  assert(lock.holder(101) == nil)
  assert(lock.holder(202) == "agent", "buffer 202 lock must survive buffer 101 release")
  assert(lock.release(202, t1) == false, "buffer 101's token must not release buffer 202")
  assert(lock.release(202, t2) == true)
end

T["reset clears every held lock"] = function()
  lock.reset()
  assert(lock.acquire(101, "completion"))
  assert(lock.acquire(202, "agent"))
  lock.reset()
  assert(lock.holder(101) == nil, "reset must clear buffer 101")
  assert(lock.holder(202) == nil, "reset must clear buffer 202")
  assert(lock.acquire(101, "agent"), "buffers must be lockable again after reset")
end

T["with runs fn under the lock and releases afterwards"] = function()
  lock.reset()
  local saw_holder
  local ok, err = lock.with(101, "agent", function()
    saw_holder = lock.holder(101)
  end)
  assert(ok == true, "with must succeed: " .. tostring(err))
  assert(err == nil)
  assert(saw_holder == "agent", "fn must observe the lock held by its owner")
  assert(lock.holder(101) == nil, "lock must be released after fn returns")
end

T["with releases the lock even when fn errors"] = function()
  lock.reset()
  local ok, err = lock.with(101, "agent", function()
    error("boom")
  end)
  assert(ok == false, "with must report failure when fn errors")
  assert(type(err) == "string" and err:find("boom", 1, true), "error message must surface: " .. tostring(err))
  assert(lock.holder(101) == nil, "lock must be released after fn errors")
end

T["with is rejected while another owner holds the lock"] = function()
  lock.reset()
  local token = lock.acquire(101, "completion")
  assert(token)
  local ran = false
  local ok, err = lock.with(101, "agent", function()
    ran = true
  end)
  assert(ok == false, "with must fail while the lock is held elsewhere")
  assert(err == "locked by completion", "err must name the holder, got " .. tostring(err))
  assert(ran == false, "fn must not run when the lock is unavailable")
  assert(lock.holder(101) == "completion", "holder unchanged")
  lock.release(101, token)
end

return T
