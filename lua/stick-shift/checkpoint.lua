---@brief Per-step checkpointing: non-mutating git snapshots (including
---untracked files) taken before agent-driven edits, plus :StickShiftRevert.
---
---The snapshot is built with plumbing against a TEMPORARY index file
---(GIT_INDEX_FILE), so the working tree and the user's real index are never
---touched. The resulting commit is anchored to HEAD (when one exists) but is
---not referenced by any branch; it is reachable only via
---.stick-shift/checkpoints.json. `git gc` may prune unreferenced snapshots after
---its expiry window (~2 weeks by default) - checkpoints are a session safety
---net, not long-term backups.
---
---KNOWN LIMITATION: `git restore --source=<ref>` overwrites files that exist
---in the snapshot but does NOT delete files created after the snapshot was
---taken. After a revert, newly-created files remain on disk (visible via
---`git status`) and must be removed by hand if unwanted.
local autonomy = require("stick-shift.autonomy")
local git = require("stick-shift.git")
local store = require("stick-shift.plan.store")
local util = require("stick-shift.util")

local M = {}

local MAX_ENTRIES = 50

---@class stick-shift.Checkpoint
---@field ref string commit (or stash) sha
---@field label string human-readable reason for the snapshot
---@field at string ISO-8601 timestamp

---@param root string
---@return string
local function json_path(root)
  return store.dir(root) .. "/checkpoints.json"
end

---Checkpoints recorded for this project, oldest first / newest last.
---@param root string
---@return stick-shift.Checkpoint[]
function M.list(root)
  local content = util.read_file(json_path(root))
  if not content then
    return {}
  end
  local ok, entries = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(entries) ~= "table" or not util.islist(entries) then
    return {}
  end
  return entries
end

---@param root string
---@return stick-shift.Checkpoint|nil
function M.last(root)
  local entries = M.list(root)
  return entries[#entries]
end

---Append a checkpoint entry (read-modify-write, capped at the newest 50).
---@param root string
---@param ref string
---@param label string
local function record(root, ref, label)
  store.ensure(root)
  local entries = M.list(root)
  table.insert(entries, { ref = ref, label = label, at = util.now_iso() })
  while #entries > MAX_ENTRIES do
    table.remove(entries, 1)
  end
  util.write_file(json_path(root), vim.json.encode(entries))
end

---Build the snapshot commit via plumbing against a temp index:
---read-tree HEAD (skipped on an unborn HEAD) + add -A (picks up untracked)
---+ write-tree + commit-tree [-p HEAD]. Nothing here mutates the working
---tree or the real index.
---@param root string
---@param label string
---@return string|nil ref, string|nil err
local function plumbing_snapshot(root, label)
  local tmpindex = vim.fn.tempname()
  local env = { GIT_INDEX_FILE = tmpindex }
  local head = git.head(root)

  local function build()
    if head then
      local ok, _, err = git.run(root, { "read-tree", "HEAD" }, { env = env })
      if not ok then
        return nil, "read-tree HEAD failed: " .. vim.trim(err)
      end
    end
    local ok, _, err = git.run(root, { "add", "-A" }, { env = env })
    if not ok then
      return nil, "add -A (temp index) failed: " .. vim.trim(err)
    end
    local tree
    ok, tree, err = git.run(root, { "write-tree" }, { env = env })
    if not ok then
      return nil, "write-tree failed: " .. vim.trim(err)
    end
    local args = { "commit-tree", vim.trim(tree), "-m", label }
    if head then
      vim.list_extend(args, { "-p", head })
    end
    local sha
    ok, sha, err = git.run(root, args, { env = env })
    if not ok then
      -- Typical cause: no committer identity configured.
      return nil, "commit-tree failed: " .. vim.trim(err)
    end
    return vim.trim(sha)
  end

  local ref, err = build()
  os.remove(tmpindex)
  return ref, err
end

---Take a non-mutating snapshot of the working tree (tracked + untracked).
---The working tree, the real index, and HEAD are untouched afterwards.
---Falls back to `git stash create` - which captures TRACKED files only -
---when the plumbing path fails; the limitation is surfaced in the recorded
---label and a warning.
---@param root string project root
---@param label string why this snapshot was taken
---@return string|nil ref commit sha, nil on failure
---@return string|nil err
function M.snapshot(root, label)
  label = (label and label ~= "") and label or "stick-shift checkpoint"
  if not git.available() then
    return nil, "git is not installed"
  end
  if not git.in_repo(root) then
    return nil, "not a git repository: " .. root
  end

  local ref, perr = plumbing_snapshot(root, label)
  if ref then
    record(root, ref, label)
    return ref
  end

  -- Fallback: `git stash create` builds an unreferenced stash commit without
  -- touching the working tree, but it snapshots tracked files only.
  local ok, out = git.run(root, { "stash", "create", label })
  local sha = ok and vim.trim(out) or ""
  if sha ~= "" then
    local note = label .. " [stash fallback: tracked files only]"
    record(root, sha, note)
    util.warn(
      ("checkpoint used `git stash create` fallback (%s); untracked files are NOT in this snapshot"):format(
        perr or "plumbing snapshot failed"
      )
    )
    return sha
  end
  return nil,
    ("snapshot failed: %s; `git stash create` fallback (tracked files only) also produced nothing"):format(
      perr or "unknown error"
    )
end

---Restore the working tree (and index) to the most recent checkpoint.
---NOTE: files created AFTER the snapshot are not deleted by `git restore`;
---they stay on disk and show up as untracked/modified in `git status`.
---@param root string|nil defaults to the current project root
---@param opts { force?: boolean }|nil force skips the confirmation prompt
---@return boolean ok
function M.revert(root, opts)
  opts = opts or {}
  root = root or util.project_root()
  local entry = M.last(root)
  if not entry then
    util.warn("no checkpoints recorded for " .. root)
    return false
  end
  if not opts.force then
    local choice = vim.fn.confirm(
      ("Restore working tree to checkpoint %q (%s)? This overwrites uncommitted changes."):format(
        entry.label,
        entry.ref:sub(1, 12)
      ),
      "&Restore\n&Cancel",
      2
    )
    if choice ~= 1 then
      return false
    end
  end
  local ok, _, err = git.run(root, {
    "restore",
    "--source=" .. entry.ref,
    "--worktree",
    "--staged",
    ":/",
  })
  if not ok then
    util.error("revert failed: " .. vim.trim(err))
    return false
  end
  -- The restore rewrote files on disk; pick the changes up in open buffers.
  vim.cmd("checktime")
  store.append_decision(
    root,
    ("reverted working tree to checkpoint %s (%s)"):format(entry.ref:sub(1, 12), entry.label)
  )
  util.notify(
    ("restored to checkpoint %s (%s); files created after it were not deleted"):format(
      entry.ref:sub(1, 12),
      entry.label
    )
  )
  return true
end

---Commit trailer advertising how much AI autonomy was active (opt-in via
---config.git.tag_commits).
---@return string e.g. "StickShift-Autonomy: 2 (co-pilot)"
function M.trailer()
  return ("StickShift-Autonomy: %d (%s)"):format(autonomy.level(), autonomy.name())
end

---Append the autonomy trailer to a commit message string (idempotent).
---@param msg string commit message
---@return string msg with trailer appended
function M.apply_trailer(msg)
  msg = msg or ""
  if msg:find("StickShift%-Autonomy:") then
    return msg
  end
  local trimmed = msg:gsub("%s+$", "")
  return trimmed .. "\n\n" .. M.trailer() .. "\n"
end

---Insert the autonomy trailer into a gitcommit BUFFER: right under the last
---message line, above git's `#` comment block. Idempotent - a buffer that
---already carries a StickShift-Autonomy trailer is left alone.
---@param buf integer
function M.buf_apply_trailer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, l in ipairs(lines) do
    if l:find("^StickShift%-Autonomy:") then
      return
    end
  end
  local first_comment = #lines + 1
  for i, l in ipairs(lines) do
    if l:find("^#") then
      first_comment = i
      break
    end
  end
  -- Back off over blank separator lines so the trailer hugs the message body
  -- (or lands at the very top when the message is still empty).
  local at = first_comment - 1
  while at > 0 and vim.trim(lines[at] or "") == "" do
    at = at - 1
  end
  vim.api.nvim_buf_set_lines(buf, at, at, false, { "", M.trailer() })
end

---Wire the opt-in commit tagging (config.git.tag_commits): every gitcommit
---buffer gets the autonomy trailer inserted on open. The config flag is read
---at fire time, so toggling it mid-session works.
function M.setup()
  local group = vim.api.nvim_create_augroup("stick-shift.checkpoint", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "gitcommit",
    desc = "stick-shift: tag commit messages with the autonomy trailer (git.tag_commits)",
    callback = function(a)
      local ok, cfg = pcall(require, "stick-shift.config")
      if ok and cfg.get().git.tag_commits then
        M.buf_apply_trailer(a.buf)
      end
    end,
  })
end

return M
