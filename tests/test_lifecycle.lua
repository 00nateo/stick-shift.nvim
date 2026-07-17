-- Offline tests for lua/reins/plan/lifecycle.lua: the whole core loop
-- (goal -> plan -> verify -> next -> implement gate) against the mock
-- backend, in throwaway cwds. Mock callbacks are synchronous, so no waits.
local T = {}

local orig_cwd = assert(vim.uv.cwd())

---Fresh modules + a throwaway project cwd per test.
---@return string dir, table lifecycle, table store, table mock, table config
local function fresh()
  for name in pairs(package.loaded) do
    if name:match("^reins") then
      package.loaded[name] = nil
    end
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.uv.chdir(dir)
  local config = require("reins.config")
  config.setup({ backend = "mock", autonomy = 2 })
  local backend = require("reins.backend")
  local mock = require("reins.backend.mock")
  mock.reset()
  backend.register("mock", mock)
  assert(backend.use("mock"))
  return dir, require("reins.plan.lifecycle"), require("reins.plan.store"), mock, config
end

local function teardown()
  vim.uv.chdir(orig_cwd)
end

---Convenience: create the canned 3-step plan and return it.
local function start_plan(lifecycle)
  local plan
  lifecycle.start("build a demo project", function(err, p)
    assert(err == nil, "start failed: " .. tostring(err))
    plan = p
  end)
  assert(plan, "start callback must fire synchronously with the mock")
  return plan
end

T["full loop: start -> verify -> next with persistence"] = function()
  local dir, lifecycle, store = fresh()
  local plan = start_plan(lifecycle)
  assert(#plan.steps >= 3, "plan needs steps")
  assert(plan.current == "s1" and plan.steps[1].status == "active")
  assert(plan.steps[1].detail_rank == 1, "current step carries the most detail")
  assert(plan.steps[2].detail_rank > 1, "later steps are sketchier by design")

  local vres
  lifecycle.verify(function(err, result)
    assert(err == nil, tostring(err))
    vres = result
  end)
  assert(vres and vres.tests and vres.tests.ran == false, "no test cmd -> honest 'not run'")
  local reloaded = assert(store.load(dir))
  assert(reloaded.steps[1].status == "verified", "correct+no-tests marks verified")
  assert(reloaded.steps[1].last_verify.match_score == 0.9)

  local nstep
  lifecycle.next(function(err, step)
    assert(err == nil, tostring(err))
    nstep = step
  end)
  assert(nstep and nstep.id == "s2" and nstep.status == "active")
  assert(nstep.detail_rank == 1, "advanced step's detail gets filled in")
  reloaded = assert(store.load(dir))
  assert(reloaded.current == "s2", "advancement must persist")
  teardown()
end

T["verify with correct=false leaves the step active"] = function()
  local dir, lifecycle, store, mock = fresh()
  start_plan(lifecycle)
  mock.set_response("verify", {
    match_score = 0.3,
    correct = false,
    decisions_changed = {},
    plan_delta = {},
    confidence = { llm = 0.5 },
  })
  lifecycle.verify(function(err)
    assert(err == nil, tostring(err))
  end)
  local plan = assert(store.load(dir))
  assert(plan.steps[1].status == "active", "incorrect step must NOT be marked verified")
  assert(plan.steps[1].last_verify.correct == false, "the judgment is still recorded")
  teardown()
end

T["failing tests veto verification even when the LLM says correct"] = function()
  local dir, lifecycle, store, mock, config = fresh()
  start_plan(lifecycle)
  -- A real failing test command: ground truth must outrank the LLM eyeball.
  config.get().verify.test_command = "exit 3"
  lifecycle.verify(function(err, result)
    assert(err == nil, tostring(err))
    assert(result.tests.ran == true and result.tests.passed == false)
    assert(result.confidence.tests == 0.0, "test confidence must be 0 on failure")
    assert(result.confidence.llm == 0.8, "llm confidence reported separately")
  end)
  local plan = assert(store.load(dir))
  assert(plan.steps[1].status == "active", "green LLM + red tests = not verified")
  teardown()
end

T["plan_delta reshapes later steps and feeds the decision log"] = function()
  local dir, lifecycle, store, mock = fresh()
  start_plan(lifecycle)
  mock.set_response("verify", {
    match_score = 0.9,
    correct = true,
    decisions_changed = { "chose sqlite over flat files" },
    plan_delta = { { step_id = "s3", change = "persist via sqlite instead of JSON" } },
    confidence = { llm = 0.9 },
  })
  lifecycle.verify(function(err)
    assert(err == nil, tostring(err))
  end)
  local plan = assert(store.load(dir))
  local s3 = store.get_step(plan, "s3")
  assert(s3.detail:find("sqlite", 1, true), "delta must be folded into the later step's detail")
  local log = assert(io.open(store.dir(dir) .. "/decisions.log", "r"))
  local content = log:read("*a")
  log:close()
  assert(content:find("chose sqlite over flat files", 1, true), "decision change logged")
  assert(content:find("persist via sqlite", 1, true), "reshape logged")
  teardown()
end

T["next falls back to the first pending step when the model picks a non-pending id"] = function()
  local dir, lifecycle, store, mock = fresh()
  start_plan(lifecycle)
  lifecycle.verify(function() end)
  mock.set_response("next_step", {
    new_current_step_id = "s1", -- verified, not pending: model misbehaving
    filled_detail = "fallback detail",
    downstream_changes = {},
  })
  local nstep
  lifecycle.next(function(err, step)
    assert(err == nil, tostring(err))
    nstep = step
  end)
  assert(nstep.id == "s2", "must fall back to first pending, got " .. tostring(nstep.id))
  assert(nstep.detail == "fallback detail")
  local plan = assert(store.load(dir))
  assert(plan.steps[1].status == "verified", "finished work must not be silently reopened")
  teardown()
end

T["skipping an unverified step records it honestly as skipped"] = function()
  local dir, lifecycle, store = fresh()
  start_plan(lifecycle)
  -- straight to next without verify
  lifecycle.next(function(err)
    assert(err == nil, tostring(err))
  end)
  local plan = assert(store.load(dir))
  assert(plan.steps[1].status == "skipped", "unverified-but-left step must read 'skipped'")
  assert(plan.current == "s2")
  teardown()
end

T["lifecycle ops are single-flight: reentrant call fails fast"] = function()
  local _, lifecycle, _, mock = fresh()
  start_plan(lifecycle)
  local inner_err
  mock.set_response("verify", function()
    lifecycle.next(function(err)
      inner_err = err
    end)
    return { match_score = 1, correct = true, decisions_changed = {}, plan_delta = {}, confidence = { llm = 1 } }
  end)
  lifecycle.verify(function(err)
    assert(err == nil, tostring(err))
  end)
  assert(inner_err and inner_err:find("in flight"), "second op while busy must fail fast, got " .. tostring(inner_err))
  teardown()
end

T["autonomy 0 blocks verify/next; implement needs level >= 3"] = function()
  local _, lifecycle, _, _, config = fresh()
  start_plan(lifecycle)
  config.get().autonomy = 0
  local verr, nerr
  lifecycle.verify(function(err)
    verr = err
  end)
  lifecycle.next(function(err)
    nerr = err
  end)
  assert(verr and verr:find("not allowed"), "verify gated at 0")
  assert(nerr and nerr:find("not allowed"), "next gated at 0")
  config.get().autonomy = 2
  local ierr
  lifecycle.implement(function(err)
    ierr = err
  end)
  assert(ierr and ierr:find("not allowed"), "implement gated below 3 (the human types)")
  teardown()
end

T["next reports plan completion when nothing is pending"] = function()
  local _, lifecycle = fresh()
  start_plan(lifecycle)
  -- burn through all three steps
  for _ = 1, 2 do
    lifecycle.verify(function() end)
    lifecycle.next(function() end)
  end
  lifecycle.verify(function() end)
  local fired, got_step = false, "sentinel"
  lifecycle.next(function(err, step)
    fired = true
    assert(err == nil, tostring(err))
    got_step = step
  end)
  assert(fired, "completion callback must fire")
  assert(got_step == nil, "no step to advance to")
  teardown()
end

T["start with an empty goal errors without touching the store"] = function()
  local dir, lifecycle, store = fresh()
  local got_err
  lifecycle.start("   ", function(err)
    got_err = err
  end)
  assert(got_err == "empty goal")
  assert(store.load(dir) == nil, "no plan may be created for an empty goal")
  teardown()
end

T["detect_test_command: explicit config wins, ecosystems auto-detect, none -> nil"] = function()
  local dir, lifecycle, _, _, config = fresh()
  assert(lifecycle.detect_test_command(dir) == nil, "empty dir has no test command")

  local f = assert(io.open(dir .. "/Cargo.toml", "w"))
  f:write("[package]\nname = \"x\"\n")
  f:close()
  assert(lifecycle.detect_test_command(dir) == "cargo test")

  f = assert(io.open(dir .. "/Makefile", "w"))
  f:write("test:\n\ttrue\n")
  f:close()
  -- Cargo.toml is checked before Makefile; explicit config overrides both.
  config.get().verify.test_command = "./my-tests.sh"
  assert(lifecycle.detect_test_command(dir) == "./my-tests.sh")

  config.get().verify.test_command = nil
  config.get().verify.auto_detect_tests = false
  assert(lifecycle.detect_test_command(dir) == nil, "auto-detect off -> nil")
  teardown()
end

T["verify: a failed plan save surfaces as an error, not silent success"] = function()
  local dir, lifecycle, store = fresh()
  start_plan(lifecycle)
  -- Make plan.json itself read-only (truncating an existing file needs write
  -- permission on the FILE, not the directory) so store.save fails mid-verify.
  local plan_json = dir .. "/.reins/plan.json"
  assert(vim.uv.fs_chmod(plan_json, 292)) -- 0444
  local err_seen
  lifecycle.verify(function(err)
    err_seen = err
  end)
  vim.uv.fs_chmod(plan_json, 420) -- 0644 back, so the temp dir stays cleanable
  assert(
    err_seen and err_seen:find("could not be saved", 1, true),
    "expected a save-failure error, got: " .. tostring(err_seen)
  )
  assert(not lifecycle.is_busy(), "busy flag must clear after a failed save")
  local reloaded = assert(store.load(dir))
  assert(reloaded.steps[1].status == "active", "disk state must not claim the verify happened")
  teardown()
end

return T
