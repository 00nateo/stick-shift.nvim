-- Offline tests for lua/reins/complete.lua: granularity trimming through the
-- real request path (mock backend, synchronous callbacks) and accept()'s
-- position defensiveness (regression: stale suggestions after <C-c> must never
-- teleport text to an old position).
local T = {}

---Fresh modules per test; mock backend at autonomy 2 with word completion.
---@return table complete, table mock
local function fresh(completion)
  for name in pairs(package.loaded) do
    if name:match("^reins") then
      package.loaded[name] = nil
    end
  end
  require("reins.config").setup({
    backend = "mock",
    autonomy = 2,
    completion = completion or { level = "word" },
  })
  local backend = require("reins.backend")
  local mock = require("reins.backend.mock")
  mock.reset()
  backend.register("mock", mock)
  assert(backend.use("mock"))
  return require("reins.complete"), mock
end

---A normal listed file-buffer (buftype "", modifiable) made current.
local function scratch_current_buf(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

T["word granularity: newline-prefixed reply cannot become a multi-line insert"] = function()
  local complete, mock = fresh({ level = "word" })
  mock.set_response("complete", { insert_text = "\n\nfoo bar baz", kind = "word" })
  local buf = scratch_current_buf({ "local x =" })
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  complete._request(buf)
  local s = complete._suggestion
  assert(s ~= nil, "suggestion should render (mock responds synchronously)")
  assert(s.text == "foo", "expected the bare first token, got: " .. vim.inspect(s.text))
  complete.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["word granularity: plain leading spaces are kept as glue"] = function()
  local complete, mock = fresh({ level = "word" })
  mock.set_response("complete", { insert_text = "  glued rest", kind = "word" })
  local buf = scratch_current_buf({ "x" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  complete._request(buf)
  local s = complete._suggestion
  assert(s ~= nil, "suggestion should render")
  assert(s.text == "  glued", "leading spaces (no newline) survive, got: " .. vim.inspect(s.text))
  complete.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["accept: suggestion at a stale position refuses, clears, leaves buffer alone"] = function()
  local complete = fresh()
  local buf = scratch_current_buf({ "hello", "world" })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  complete._suggestion = { bufnr = buf, row = 0, col = 5, text = "XYZ", id = 1 }
  assert(complete.accept() == false, "stale accept must refuse")
  assert(complete._suggestion == nil, "stale suggestion must be dropped, not kept")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == "hello" and lines[2] == "world", "buffer must be untouched")
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["accept: suggestion for a non-current buffer refuses and clears"] = function()
  local complete = fresh()
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "elsewhere" })
  local buf = scratch_current_buf({ "current" })
  complete._suggestion = { bufnr = other, row = 0, col = 0, text = "XYZ", id = 1 }
  assert(complete.accept() == false, "accept must refuse for a non-current buffer")
  assert(complete._suggestion == nil)
  assert(vim.api.nvim_buf_get_lines(other, 0, -1, false)[1] == "elsewhere")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(other, { force = true })
end

T["accept: exact position inserts and advances the cursor"] = function()
  local complete = fresh()
  local buf = scratch_current_buf({ "hello" })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  complete._suggestion = { bufnr = buf, row = 0, col = 4, text = "XYZ", id = 1 }
  assert(complete.accept() == true, "exact-position accept must succeed")
  assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "hellXYZo")
  local cur = vim.api.nvim_win_get_cursor(0)
  assert(cur[1] == 1 and cur[2] == 7, "cursor lands after the inserted text, got " .. vim.inspect(cur))
  assert(complete._suggestion == nil, "accepted suggestion is cleared")
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["request: gated off at autonomy 1 without force"] = function()
  local complete, mock = fresh()
  require("reins.config").get().autonomy = 1
  local buf = scratch_current_buf({ "text" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  complete._request(buf)
  assert(complete._suggestion == nil, "no ghost at autonomy 1")
  assert(#mock.calls == 0, "no backend call may be made when gated off")
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
