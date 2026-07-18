-- Offline tests for lua/stick-shift/checkpoint.lua: non-mutating snapshots + revert,
-- exercised against throwaway git repos in temp dirs. All synchronous.
require("stick-shift.config").setup({ backend = "mock", autonomy = 2 })
local checkpoint = require("stick-shift.checkpoint")
local git = require("stick-shift.git")
local util = require("stick-shift.util")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function run_ok(root, args)
  local ok, out, err = git.run(root, args)
  assert(ok, ("git %s failed in %s: %s"):format(table.concat(args, " "), root, err))
  return out
end

local function new_repo()
  local dir = tmpdir()
  run_ok(dir, { "init", "-q" })
  run_ok(dir, { "config", "user.email", "tests@example.invalid" })
  run_ok(dir, { "config", "user.name", "StickShift Tests" })
  run_ok(dir, { "config", "commit.gpgsign", "false" })
  return dir
end

local function write(path, content)
  local ok, err = util.write_file(path, content)
  assert(ok, tostring(err))
end

local function read(path)
  local content = util.read_file(path)
  assert(content ~= nil, "cannot read " .. path)
  return content
end

local function commit_all(dir, msg)
  run_ok(dir, { "add", "-A" })
  run_ok(dir, { "commit", "-q", "-m", msg })
end

local T = {}

T["snapshot in a non-git directory fails cleanly"] = function()
  local dir = tmpdir()
  local ref, err = checkpoint.snapshot(dir, "nope")
  assert(ref == nil, "snapshot must fail outside a repo")
  assert(type(err) == "string" and err:find("not a git repository", 1, true), "err must explain: " .. tostring(err))
  assert(#checkpoint.list(dir) == 0, "no checkpoint may be recorded on failure")
end

T["snapshot returns a sha, records it, and mutates nothing"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "committed\n")
  commit_all(dir, "base")
  write(dir .. "/a.txt", "dirty edit\n")
  write(dir .. "/loose.txt", "untracked\n")
  local head_before = git.head(dir)
  local status_before = run_ok(dir, { "status", "--porcelain" })

  local ref, err = checkpoint.snapshot(dir, "pre-agent")
  assert(ref, "snapshot failed: " .. tostring(err))
  assert(ref:match("^%x+$") and #ref == 40, "expected 40-hex commit sha, got " .. tostring(ref))

  -- recorded in .stick-shift/checkpoints.json
  local entries = checkpoint.list(dir)
  assert(#entries == 1, "exactly one checkpoint recorded, got " .. #entries)
  assert(entries[1].ref == ref and entries[1].label == "pre-agent", "recorded entry must match")
  assert(type(entries[1].at) == "string" and entries[1].at:find("T", 1, true), "entry needs an ISO timestamp")

  -- non-mutating: HEAD, working tree, and status are untouched
  assert(git.head(dir) == head_before, "HEAD must not move")
  assert(read(dir .. "/a.txt") == "dirty edit\n", "working tree file must be untouched")
  assert(run_ok(dir, { "status", "--porcelain" }) == status_before, "git status must be unchanged")

  -- the snapshot commit itself is anchored to the old HEAD
  local parent = vim.trim(run_ok(dir, { "rev-parse", ref .. "^" }))
  assert(parent == head_before, "snapshot must have HEAD as parent")
end

T["snapshot works on an unborn HEAD (no commits yet)"] = function()
  local dir = new_repo()
  write(dir .. "/first.txt", "hello\n")
  local ref, err = checkpoint.snapshot(dir, "genesis")
  assert(ref, "snapshot on unborn HEAD failed: " .. tostring(err))
  assert(git.head(dir) == nil, "HEAD must still be unborn afterwards")
  assert(checkpoint.last(dir).ref == ref)
end

T["last returns the newest of several checkpoints"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "v1\n")
  commit_all(dir, "base")
  local ref1 = assert(checkpoint.snapshot(dir, "first"))
  write(dir .. "/a.txt", "v2\n")
  local ref2 = assert(checkpoint.snapshot(dir, "second"))
  assert(ref1 ~= ref2, "distinct trees must yield distinct snapshot commits")
  local entries = checkpoint.list(dir)
  assert(#entries == 2)
  assert(entries[1].label == "first" and entries[2].label == "second", "entries must be oldest-first")
  assert(checkpoint.last(dir).ref == ref2, "last() must be the newest checkpoint")
end

T["create/revert round trip restores tracked and untracked file content"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "original\n")
  commit_all(dir, "base")

  write(dir .. "/a.txt", "checkpoint state\n")
  write(dir .. "/loose.txt", "untracked at checkpoint\n")
  local ref, err = checkpoint.snapshot(dir, "before edits")
  assert(ref, "snapshot failed: " .. tostring(err))

  -- agent goes wild after the checkpoint
  write(dir .. "/a.txt", "clobbered\n")
  write(dir .. "/loose.txt", "clobbered too\n")

  assert(checkpoint.revert(dir, { force = true }) == true, "revert must succeed")
  assert(read(dir .. "/a.txt") == "checkpoint state\n", "tracked file must be restored")
  assert(read(dir .. "/loose.txt") == "untracked at checkpoint\n", "untracked-at-snapshot file must be restored")
  assert(git.head(dir) ~= nil and read(dir .. "/a.txt") ~= "original\n", "revert targets the checkpoint, not HEAD")
  -- the revert is logged in the decision log
  local log = read(dir .. "/.stick-shift/decisions.log")
  assert(log:find("reverted working tree to checkpoint", 1, true), "decision log entry expected")
end

T["revert with no checkpoint warns and returns false without erroring"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "keep me\n")
  commit_all(dir, "base")
  local captured
  local saved = vim.notify
  vim.notify = function(msg, level)
    captured = { msg = tostring(msg), level = level }
  end
  local ok = checkpoint.revert(dir, { force = true })
  vim.notify = saved
  assert(ok == false, "revert must report failure when nothing is recorded")
  assert(captured, "a notification must be emitted")
  assert(captured.msg:find("no checkpoints", 1, true), "warning must say so: " .. captured.msg)
  assert(captured.level == vim.log.levels.WARN, "must be a WARN, not an error")
  assert(read(dir .. "/a.txt") == "keep me\n", "working tree must be untouched")
end

T["list tolerates a corrupt checkpoints.json"] = function()
  local dir = new_repo()
  vim.fn.mkdir(dir .. "/.stick-shift", "p")
  write(dir .. "/.stick-shift/checkpoints.json", "{ not json !!!")
  local entries = checkpoint.list(dir)
  assert(type(entries) == "table" and #entries == 0, "corrupt json must read as no checkpoints")
end

T["apply_trailer appends the autonomy trailer exactly once"] = function()
  local msg = checkpoint.apply_trailer("fix: something")
  assert(msg:find("StickShift-Autonomy: 2 (co-pilot)", 1, true), "trailer with level+name expected, got: " .. msg)
  local again = checkpoint.apply_trailer(msg)
  local _, count = again:gsub("StickShift%-Autonomy:", "")
  assert(count == 1, "trailer must not be duplicated, found " .. count)
end

T["buf_apply_trailer: inserts above the comment block, idempotently"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fix: subject line", "", "# Please enter the commit message" })
  checkpoint.buf_apply_trailer(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == "fix: subject line", "subject intact")
  assert(lines[2] == "", "separator blank line kept")
  assert(lines[3]:find("^StickShift%-Autonomy: %d"), "trailer inserted, got: " .. tostring(lines[3]))
  assert(lines[4] == "" and lines[5]:find("^#"), "comment block preserved below")
  checkpoint.buf_apply_trailer(buf)
  assert(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) == #lines, "second application must be a no-op")
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["buf_apply_trailer: empty message gets the trailer at the top"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "# comment" })
  checkpoint.buf_apply_trailer(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == "" and lines[2]:find("^StickShift%-Autonomy:"), table.concat(lines, "|"))
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["setup: gitcommit FileType applies the trailer only when tag_commits is on"] = function()
  local config = require("stick-shift.config")
  checkpoint.setup()

  config.get().git.tag_commits = false
  local off = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(off, 0, -1, false, { "msg", "", "# comments" })
  vim.bo[off].filetype = "gitcommit"
  for _, l in ipairs(vim.api.nvim_buf_get_lines(off, 0, -1, false)) do
    assert(not l:find("StickShift%-Autonomy"), "trailer must NOT appear when tag_commits=false")
  end

  config.get().git.tag_commits = true
  local on = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(on, 0, -1, false, { "msg", "", "# comments" })
  vim.bo[on].filetype = "gitcommit"
  local found = false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(on, 0, -1, false)) do
    found = found or l:find("^StickShift%-Autonomy:") ~= nil
  end
  assert(found, "trailer must appear when tag_commits=true")

  config.get().git.tag_commits = false
  vim.api.nvim_buf_delete(off, { force = true })
  vim.api.nvim_buf_delete(on, { force = true })
end

return T
