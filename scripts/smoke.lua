-- Headless smoke test of the core loop against the mock backend:
--   nvim --headless -l scripts/smoke.lua [workdir]
-- Exercises: setup -> :ReinsGoal (plan) -> :ReinsVerify -> :ReinsNext,
-- asserts the plan state transitions, prints PASS/FAIL, exits non-zero on failure.
local src = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(src))
vim.opt.runtimepath:prepend(repo)

local workdir = _G.arg and _G.arg[1]
if not workdir then
  workdir = vim.fn.tempname()
end
vim.fn.mkdir(workdir, "p")
vim.uv.chdir(workdir)

local failures = {}
local function check(cond, label)
  if cond then
    print("  ok: " .. label)
  else
    table.insert(failures, label)
    print("  FAIL: " .. label)
  end
end

require("reins").setup({ backend = "mock", autonomy = 2 })

local lifecycle = require("reins.plan.lifecycle")
local store = require("reins.plan.store")

-- 1. goal -> plan
local plan_done = false
lifecycle.start("build a todo CLI in Lua", function(err, plan)
  check(err == nil, "plan created without error: " .. tostring(err))
  check(plan and #plan.steps >= 3, "plan has >= 3 steps")
  check(plan and plan.current == "s1", "step s1 is current")
  check(plan and plan.steps[1].status == "active", "s1 active")
  check(plan and plan.steps[1].detail_rank == 1, "detail gradient: s1 rank 1")
  check(plan and plan.steps[2].detail_rank > 1, "detail gradient: s2 sketchier")
  plan_done = true
end)
vim.wait(5000, function()
  return plan_done
end)
check(plan_done, "plan callback fired")

-- 2. verify current step
local verify_done = false
lifecycle.verify(function(err, result)
  check(err == nil, "verify without error: " .. tostring(err))
  check(result and result.match_score == 0.9, "verify returned match_score")
  check(result and result.tests and result.tests.ran == false, "tests honestly reported as not run")
  verify_done = true
end)
vim.wait(5000, function()
  return verify_done
end)
check(verify_done, "verify callback fired")

local reloaded = store.load(vim.uv.cwd())
check(reloaded and reloaded.steps[1].status == "verified", "s1 marked verified after correct verify")

-- 3. advance
local next_done = false
lifecycle.next(function(err, step)
  check(err == nil, "next without error: " .. tostring(err))
  check(step and step.id == "s2", "advanced to s2")
  check(step and step.status == "active", "s2 active")
  check(step and step.detail_rank == 1, "s2 detail filled in (rank now 1)")
  next_done = true
end)
vim.wait(5000, function()
  return next_done
end)
check(next_done, "next callback fired")

reloaded = store.load(vim.uv.cwd())
check(reloaded and reloaded.current == "s2", "plan.json persisted current=s2")

-- 4. persistence artifacts
local uv = vim.uv
check(uv.fs_stat(workdir .. "/.reins/plan.json") ~= nil, ".reins/plan.json exists")
check(uv.fs_stat(workdir .. "/.reins/plan.md") ~= nil, ".reins/plan.md exists")
check(uv.fs_stat(workdir .. "/.reins/decisions.log") ~= nil, ".reins/decisions.log exists")
check(uv.fs_stat(workdir .. "/.reins/.gitignore") ~= nil, ".reins is git-ignored by default")

-- 5. autonomy gating from the command layer
require("reins").set_autonomy(0)
local blocked = nil
lifecycle.verify(function(err)
  blocked = err
end)
vim.wait(2000, function()
  return blocked ~= nil
end)
check(blocked ~= nil, "verify blocked at autonomy 0 (hint-only)")

if #failures > 0 then
  print(("\nSMOKE: %d FAILURE(S)"):format(#failures))
  os.exit(1)
end
print("\nSMOKE: all checks passed")
os.exit(0)
