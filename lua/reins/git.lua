---@brief Thin synchronous git helpers (local, fast operations only).
---Used by plan/lifecycle for scoped diffs and by checkpoint for snapshots.
local M = {}

local MAX_DIFF_BYTES = 40 * 1024

---@return boolean
function M.available()
  return vim.fn.executable("git") == 1
end

---Run git in `root`. Synchronous by design: these are local plumbing calls.
---@param root string
---@param args string[]
---@param opts { input?: string, env?: table }|nil
---@return boolean ok, string stdout, string stderr
function M.run(root, args, opts)
  opts = opts or {}
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local res = vim
    .system(cmd, { text = true, stdin = opts.input, env = opts.env, timeout = 15000 })
    :wait()
  return res.code == 0, res.stdout or "", res.stderr or ""
end

---@param root string
---@return boolean
function M.in_repo(root)
  if not M.available() then
    return false
  end
  local ok, out = M.run(root, { "rev-parse", "--is-inside-work-tree" })
  return ok and out:match("true") ~= nil
end

---@param root string
---@return string|nil sha
function M.head(root)
  local ok, out = M.run(root, { "rev-parse", "HEAD" })
  if not ok then
    return nil -- fresh repo with no commits, or not a repo
  end
  return vim.trim(out)
end

---@param root string
---@return string[] paths of untracked (non-ignored) files
function M.untracked(root)
  local ok, out = M.run(root, { "ls-files", "--others", "--exclude-standard" })
  if not ok then
    return {}
  end
  return vim.split(vim.trim(out), "\n", { trimempty = true })
end

---Names of files changed since `ref` (or in the working tree when ref is nil),
---including untracked files.
---@param root string
---@param ref string|nil
---@return string[]
function M.changed_files(root, ref)
  local args = { "diff", "--name-only" }
  if ref then
    table.insert(args, ref)
  end
  local ok, out = M.run(root, args)
  local files = ok and vim.split(vim.trim(out), "\n", { trimempty = true }) or {}
  vim.list_extend(files, M.untracked(root))
  return files
end

---Textual diff since `ref` (or vs HEAD/index when nil), optionally restricted
---to `paths`, with untracked file contents appended, capped at 40KB.
---@param root string
---@param ref string|nil
---@param paths string[]|nil
---@return string diff possibly ""
function M.diff_since(root, ref, paths)
  local args = { "diff" }
  if ref then
    table.insert(args, ref)
  end
  if paths and #paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, paths)
  end
  local ok, out = M.run(root, args)
  local chunks = { ok and out or "" }
  for _, path in ipairs(M.untracked(root)) do
    local keep = not paths or #paths == 0 or vim.tbl_contains(paths, path)
    if keep then
      local fd = io.open(root .. "/" .. path, "r")
      if fd then
        local content = fd:read("*a") or ""
        fd:close()
        if #content < 16 * 1024 and not content:find("\0", 1, true) then
          table.insert(chunks, ("--- /dev/null\n+++ b/%s (untracked)\n%s"):format(path, content))
        else
          table.insert(chunks, ("+++ b/%s (untracked, %d bytes, omitted)"):format(path, #content))
        end
      end
    end
  end
  local joined = vim.trim(table.concat(chunks, "\n"))
  if #joined > MAX_DIFF_BYTES then
    joined = joined:sub(1, MAX_DIFF_BYTES)
      .. ("\n[... diff truncated at %d bytes]"):format(MAX_DIFF_BYTES)
  end
  return joined
end

return M
