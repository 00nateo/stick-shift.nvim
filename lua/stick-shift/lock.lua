---@brief Per-buffer single-writer lock.
---
---Two programmatic writers exist: "completion" (accepting ghost text) and
---"agent" (backend-driven edits). Both MUST hold the buffer's lock across any
---nvim_buf_set_* call. Ghost-text DISPLAY is lock-free (extmarks don't mutate
---text); acceptance is not. Try-acquire semantics: the second writer is
---rejected, never queued behind an edit it can't see.
local M = {}

---@type table<integer, { owner: string, token: integer }>
local locks = {}
local next_token = 0

---Attempt to acquire the write lock for a buffer.
---@param bufnr integer
---@param owner string e.g. "completion" | "agent"
---@return integer|nil token nil when already held by someone else
---@return string|nil holder current owner when rejected
function M.acquire(bufnr, owner)
  local held = locks[bufnr]
  if held then
    return nil, held.owner
  end
  next_token = next_token + 1
  locks[bufnr] = { owner = owner, token = next_token }
  return next_token
end

---Release a lock. Only the token returned by acquire() can release it, so a
---stale/foreign release can never unlock someone else's critical section.
---@param bufnr integer
---@param token integer
---@return boolean released
function M.release(bufnr, token)
  local held = locks[bufnr]
  if held and held.token == token then
    locks[bufnr] = nil
    return true
  end
  return false
end

---@param bufnr integer
---@return string|nil owner
function M.holder(bufnr)
  local held = locks[bufnr]
  return held and held.owner or nil
end

---Run fn while holding the lock; always releases, even on error.
---@param bufnr integer
---@param owner string
---@param fn fun()
---@return boolean ok false when the lock was held or fn errored
---@return string|nil err "locked by <owner>" or the fn error
function M.with(bufnr, owner, fn)
  local token, holder = M.acquire(bufnr, owner)
  if not token then
    return false, "locked by " .. tostring(holder)
  end
  local ok, err = pcall(fn)
  M.release(bufnr, token)
  if not ok then
    return false, tostring(err)
  end
  return true
end

---Test helper.
function M.reset()
  locks = {}
end

return M
