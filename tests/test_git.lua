-- Offline tests for lua/reins/git.lua against throwaway repos in temp dirs.
-- Everything here is synchronous (git.run uses vim.system():wait()).
local git = require("reins.git")
local util = require("reins.util")

local MAX_DIFF_BYTES = 40 * 1024 -- mirrors git.lua's cap

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

---Fresh git repo in a temp dir with local-only identity (never touches ~/.gitconfig).
local function new_repo()
  local dir = tmpdir()
  run_ok(dir, { "init", "-q" })
  run_ok(dir, { "config", "user.email", "tests@example.invalid" })
  run_ok(dir, { "config", "user.name", "Reins Tests" })
  run_ok(dir, { "config", "commit.gpgsign", "false" })
  return dir
end

local function write(path, content)
  local ok, err = util.write_file(path, content)
  assert(ok, tostring(err))
end

local function commit_all(dir, msg)
  run_ok(dir, { "add", "-A" })
  run_ok(dir, { "commit", "-q", "-m", msg })
end

local T = {}

T["in_repo detects a repo root and its subdirectories"] = function()
  local dir = new_repo()
  assert(git.in_repo(dir) == true, "repo root must be inside a work tree")
  local sub = dir .. "/nested/deeper"
  vim.fn.mkdir(sub, "p")
  assert(git.in_repo(sub) == true, "subdirectory of a repo must be inside the work tree")
end

T["in_repo is false and helpers are safe in a non-git directory"] = function()
  local dir = tmpdir()
  assert(git.in_repo(dir) == false, "plain temp dir must not be a repo")
  assert(git.head(dir) == nil, "head must be nil outside a repo")
  local files = git.changed_files(dir)
  assert(type(files) == "table" and #files == 0, "changed_files must be empty outside a repo")
  local diff = git.diff_since(dir) -- must not error
  assert(diff == "", "diff must be empty outside a repo, got: " .. diff:sub(1, 80))
end

T["project_root finds the nearest ancestor with a .git marker"] = function()
  local dir = new_repo()
  local sub = dir .. "/src/inner"
  vim.fn.mkdir(sub, "p")
  write(sub .. "/mod.lua", "return {}\n")
  local root = util.project_root(sub .. "/mod.lua")
  assert(root == dir, ("expected root %s, got %s"):format(dir, tostring(root)))
end

T["head is nil on an unborn HEAD and a 40-hex sha after a commit"] = function()
  local dir = new_repo()
  assert(git.head(dir) == nil, "fresh repo with no commits must have nil head")
  write(dir .. "/a.txt", "hello\n")
  commit_all(dir, "base")
  local sha = git.head(dir)
  assert(type(sha) == "string" and sha:match("^%x+$") and #sha == 40, "expected 40-hex sha, got " .. tostring(sha))
end

T["untracked lists new files but not ignored ones"] = function()
  local dir = new_repo()
  write(dir .. "/.gitignore", "ignored.txt\n")
  commit_all(dir, "add gitignore")
  write(dir .. "/fresh.txt", "new\n")
  write(dir .. "/ignored.txt", "invisible\n")
  local files = git.untracked(dir)
  assert(vim.tbl_contains(files, "fresh.txt"), "fresh.txt must be listed as untracked")
  assert(not vim.tbl_contains(files, "ignored.txt"), "ignored.txt must be excluded")
end

T["changed_files includes worktree modifications and untracked files"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "one\n")
  write(dir .. "/b.txt", "two\n")
  commit_all(dir, "base")
  write(dir .. "/a.txt", "one changed\n")
  write(dir .. "/new.txt", "brand new\n")
  local files = git.changed_files(dir)
  assert(vim.tbl_contains(files, "a.txt"), "modified tracked file must appear")
  assert(vim.tbl_contains(files, "new.txt"), "untracked file must appear")
  assert(not vim.tbl_contains(files, "b.txt"), "unmodified file must not appear")
end

T["changed_files with a ref reports changes since that ref"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "one\n")
  commit_all(dir, "base")
  local base = git.head(dir)
  write(dir .. "/a.txt", "one v2\n")
  commit_all(dir, "second")
  local files = git.changed_files(dir, base)
  assert(vim.tbl_contains(files, "a.txt"), "a.txt changed since base ref")
end

T["diff_since scopes to the given paths"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "alpha\n")
  write(dir .. "/b.txt", "beta\n")
  commit_all(dir, "base")
  write(dir .. "/a.txt", "alpha CHANGED_A\n")
  write(dir .. "/b.txt", "beta CHANGED_B\n")
  local diff = git.diff_since(dir, nil, { "a.txt" })
  assert(diff:find("CHANGED_A", 1, true), "scoped diff must contain a.txt's change")
  assert(not diff:find("CHANGED_B", 1, true), "scoped diff must not contain b.txt's change")
  local full = git.diff_since(dir)
  assert(full:find("CHANGED_A", 1, true) and full:find("CHANGED_B", 1, true), "unscoped diff must contain both changes")
end

T["diff_since inlines small untracked files and honors path scoping for them"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "alpha\n")
  commit_all(dir, "base")
  write(dir .. "/notes.txt", "UNTRACKED_CONTENT\n")
  local diff = git.diff_since(dir)
  assert(diff:find("+++ b/notes.txt (untracked)", 1, true), "untracked header expected in unscoped diff")
  assert(diff:find("UNTRACKED_CONTENT", 1, true), "untracked file content must be inlined")
  local scoped = git.diff_since(dir, nil, { "a.txt" })
  assert(not scoped:find("notes.txt", 1, true), "untracked file outside the path scope must be excluded")
  local scoped_in = git.diff_since(dir, nil, { "notes.txt" })
  assert(scoped_in:find("UNTRACKED_CONTENT", 1, true), "untracked file inside the path scope must be included")
end

T["diff_since omits large or binary untracked file contents"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "alpha\n")
  commit_all(dir, "base")
  local big = ("x"):rep(20 * 1024) -- >= 16KB inline threshold
  write(dir .. "/big.txt", big)
  write(dir .. "/bin.dat", "abc\0def")
  local diff = git.diff_since(dir)
  assert(
    diff:find(("+++ b/big.txt (untracked, %d bytes, omitted)"):format(#big), 1, true),
    "large untracked file must be summarized, not inlined"
  )
  assert(not diff:find("xxxxxxxxxx", 1, true), "large file content must not be inlined")
  assert(diff:find("bin.dat (untracked, 7 bytes, omitted)", 1, true), "binary untracked file must be summarized")
end

T["diff_since truncates at the byte cap with a marker"] = function()
  local dir = new_repo()
  write(dir .. "/a.txt", "seed\n")
  commit_all(dir, "base")
  -- ~60KB of changed tracked content -> raw diff comfortably exceeds 40KB
  local lines = {}
  for i = 1, 3000 do
    lines[i] = ("line %04d padded-to-make-it-long\n"):format(i)
  end
  write(dir .. "/a.txt", table.concat(lines))
  local diff = git.diff_since(dir)
  local marker = ("[... diff truncated at %d bytes]"):format(MAX_DIFF_BYTES)
  assert(diff:sub(-#marker) == marker, "truncated diff must end with the marker, tail: " .. diff:sub(-60))
  assert(
    #diff == MAX_DIFF_BYTES + #marker + 1, -- cap + "\n" + marker
    ("truncated diff length %d != cap %d + marker"):format(#diff, MAX_DIFF_BYTES)
  )
end

return T
