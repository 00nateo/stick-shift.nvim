---@brief Orchestrates the step lifecycle: goal -> plan, Verify step, Next
---step, Implement step. Verification is scoped (step's `touched` + git diff
---since the step began, never the whole repo) and runs the project's real
---test command; the LLM's judgment and the test result are reported as two
---separate confidence signals.
local autonomy = require("reins.autonomy")
local backend = require("reins.backend")
local config = require("reins.config")
local events = require("reins.events")
local git = require("reins.git")
local store = require("reins.plan.store")
local util = require("reins.util")

local M = {}

M._busy = false
---@type reins.Plan|nil in-memory plan (authoritative while an op runs)
M._plan = nil
M._root = nil

---@return string root
local function root()
  M._root = util.project_root()
  return M._root
end

---Reload from disk so manual :ReinsPlan! edits are respected.
---@return reins.Plan|nil, string|nil err
local function load_plan(r)
  local plan, err = store.load(r)
  M._plan = plan
  return plan, err
end

---@return { root: string, plan: reins.Plan|nil, busy: boolean }
function M.state()
  local r = root()
  if not M._busy then
    load_plan(r)
  end
  return { root = r, plan = M._plan, busy = M._busy }
end

function M.is_busy()
  return M._busy
end

local function begin_op(label)
  if M._busy then
    return false, "another reins operation is in flight"
  end
  M._busy = true
  events.emit("status", label)
  return true
end

local function end_op()
  M._busy = false
  events.emit("status", nil)
end

---Wrap a lifecycle callback: always clears busy state, notifies on error.
local function finish(cb)
  return function(err, ...)
    end_op()
    if err then
      util.error(err)
    end
    if cb then
      cb(err, ...)
    end
  end
end

---Session context is only reusable on the adapter that created it. Ops can be
---routed per role (config.models.*), so gate on the adapter that will actually
---serve THIS op - not on the globally active backend.
---@param plan reins.Plan|nil
---@param op string the op the session is for ("plan"|"verify"|"next_step"|"implement")
---@return string|nil session_id
local function session_for(plan, op)
  local adapter = backend.resolve(op)
  if adapter and plan and plan.session and plan.session.backend == adapter.name then
    return plan.session.id
  end
  return nil
end

---@param plan reins.Plan
---@param meta table|nil
local function remember_session(plan, meta)
  if meta and meta.session_id and meta.backend then
    store.set_session(plan, meta.backend, meta.session_id)
  end
end

-- ---------------------------------------------------------------- start ----

---Create (or re-create) the living plan from a goal. Entry point (:ReinsGoal).
---@param goal string
---@param cb fun(err: string|nil, plan: reins.Plan|nil)|nil
function M.start(goal, cb)
  if goal == nil or vim.trim(goal) == "" then
    util.error("a goal is required, e.g. :ReinsGoal build a todo CLI")
    if cb then
      cb("empty goal")
    end
    return
  end
  local ok, err = begin_op("planning…")
  if not ok then
    util.warn(err)
    if cb then
      cb(err)
    end
    return
  end
  local r = root()
  local existing = store.load(r)
  local done = finish(cb)
  backend.call("plan", {
    root = r,
    goal = goal,
    context = util.context_files(r),
    existing_plan = existing and { goal = existing.goal, steps = existing.steps } or nil,
    session = session_for(existing, "plan"),
  }, function(cerr, result, meta)
    if cerr then
      return done(cerr)
    end
    local plan = store.new_plan(goal)
    for i, s in ipairs(result.steps or {}) do
      table.insert(plan.steps, {
        id = s.id or ("s" .. i),
        title = s.title,
        detail = s.detail,
        reasoning = s.reasoning or "",
        status = "pending",
        touched = s.touched or {},
        detail_rank = s.detail_rank or i,
      })
    end
    if #plan.steps == 0 then
      return done("backend returned a plan with no steps")
    end
    remember_session(plan, meta)
    store.set_current(plan, plan.steps[1].id, git.head(r))
    local saved, serr = store.save(r, plan)
    if not saved then
      return done("could not save plan: " .. tostring(serr))
    end
    M._plan = plan
    store.append_decision(r, ("plan created (%d steps) for goal: %s"):format(#plan.steps, goal))
    events.emit("plan_updated", plan)
    done(nil, plan)
  end)
end

-- ----------------------------------------------------------- test runner ----

---Detect the project's test command. Explicit config wins; auto-detection
---covers the common ecosystems; nil means "no tests to run" (reported as such,
---never faked).
---@param r string project root
---@return string|nil cmd
function M.detect_test_command(r)
  local cfg = config.get().verify
  if cfg.test_command and cfg.test_command ~= "" then
    return cfg.test_command
  end
  if not cfg.auto_detect_tests then
    return nil
  end
  local function has(name)
    return util.exists(r .. "/" .. name)
  end
  if has("package.json") then
    local content = util.read_file(r .. "/package.json")
    local ok, pkg = pcall(vim.json.decode, content or "")
    local script = ok and pkg.scripts and pkg.scripts.test or nil
    if script and not script:find("no test specified", 1, true) then
      return "npm test"
    end
  end
  if has("Cargo.toml") then
    return "cargo test"
  end
  if has("go.mod") then
    return "go test ./..."
  end
  if (has("pyproject.toml") or has("pytest.ini") or has("tox.ini")) and vim.fn.executable("pytest") == 1 then
    return "pytest -q"
  end
  if has("Makefile") then
    local mk = util.read_file(r .. "/Makefile") or ""
    if mk:match("\n%s*test%s*:") or mk:match("^%s*test%s*:") then
      return "make test"
    end
  end
  if has("mix.exs") then
    return "mix test"
  end
  return nil
end

---Run the test command (async). Ground truth for verify; output tail is kept
---because failures print last.
---@param r string
---@param cb fun(tests: { ran: boolean, command: string|nil, passed: boolean|nil, output: string|nil })
local function run_tests(r, cb)
  local cmd = M.detect_test_command(r)
  if not cmd then
    return cb({ ran = false })
  end
  events.emit("status", "running tests: " .. cmd)
  local spawned, sperr = pcall(
    vim.system,
    { "sh", "-c", cmd },
    { cwd = r, text = true, timeout = config.get().verify.timeout_ms },
    vim.schedule_wrap(function(res)
      local out = (res.stdout or "") .. "\n" .. (res.stderr or "")
      if #out > 10000 then
        out = "[... output truncated, tail follows]\n" .. out:sub(-10000)
      end
      cb({
        ran = true,
        command = cmd,
        passed = res.code == 0,
        output = vim.trim(out),
        code = res.code,
      })
    end)
  )
  if not spawned then
    -- e.g. the project root vanished; report honestly instead of throwing
    -- (an uncaught error here would leak the busy flag forever).
    cb({ ran = false, command = cmd, output = "could not run tests: " .. tostring(sperr) })
  end
end

-- --------------------------------------------------------------- verify ----

---Scope of a verification: diff since the step began, restricted to the
---step's expected surface when that surface is non-empty and real.
---TODO(reins): expand `touched` symbols to files via LSP/Tree-sitter
---references; today only entries that exist as paths narrow the diff.
---@param r string
---@param step reins.Step
---@return string diff
local function scoped_diff(r, step)
  if not git.in_repo(r) then
    return "(project is not a git repository; no diff available)"
  end
  local paths = {}
  for _, t in ipairs(step.touched or {}) do
    if util.exists(r .. "/" .. t) then
      table.insert(paths, t)
    end
  end
  local diff = git.diff_since(r, step.began_ref, paths)
  if diff == "" and #paths > 0 then
    -- The expected surface didn't change; widen so drift is visible.
    diff = git.diff_since(r, step.began_ref, nil)
  end
  if diff == "" then
    return "(no changes since this step began)"
  end
  return diff
end

---Verify the current step. Isolated-subtask pattern: the verification prompt
---carries only the scoped context, and only the structured summary comes back
---into the plan.
---@param cb fun(err: string|nil, result: table|nil)|nil
function M.verify(cb)
  if not autonomy.allows("verify") then
    util.warn("verify is unavailable at autonomy level " .. autonomy.level() .. " (" .. autonomy.name() .. ")")
    if cb then
      cb("verify not allowed at this level")
    end
    return
  end
  local r = root()
  local plan = load_plan(r)
  if not plan then
    util.warn("no plan yet - set a goal with :ReinsGoal")
    if cb then
      cb("no plan")
    end
    return
  end
  local step = store.get_step(plan)
  if not step then
    if cb then
      cb("plan has no current step")
    end
    return
  end
  local ok, err = begin_op("verifying: " .. step.title)
  if not ok then
    util.warn(err)
    if cb then
      cb(err)
    end
    return
  end
  local done = finish(cb)
  run_tests(r, function(tests)
    events.emit("status", "verifying: " .. step.title)
    backend.call("verify", {
      root = r,
      step = step,
      diff = scoped_diff(r, step),
      tests = tests,
      session = session_for(plan, "verify"),
    }, function(cerr, result, meta)
      if cerr then
        return done(cerr)
      end
      -- Ground truth is merged by the PLUGIN: the model never gets to claim
      -- test results, and an eyeball never substitutes for a green run.
      result.tests = tests
      result.confidence = result.confidence or {}
      if tests.ran then
        result.confidence.tests = tests.passed and 1.0 or 0.0
      end
      step.last_verify = result
      step.last_verify.at = util.now_iso()
      if result.correct and (not tests.ran or tests.passed) then
        step.status = "verified"
      end
      for _, d in ipairs(result.decisions_changed or {}) do
        store.append_decision(r, ("[%s] decision changed: %s"):format(step.id, d))
      end
      for _, delta in ipairs(result.plan_delta or {}) do
        local target = store.get_step(plan, delta.step_id)
        if target and target.id ~= step.id then
          target.detail = (target.detail or "")
            .. ("\n\n[adjusted %s] %s"):format(util.now_iso(), delta.change)
          store.append_decision(r, ("[%s] reshaped: %s"):format(delta.step_id, delta.change))
        end
      end
      remember_session(plan, meta)
      local saved, serr = store.save(r, plan)
      if not saved then
        -- The verdict is real but unpersisted; the next state() reload would
        -- silently drop it. Surface the failure instead of reporting success.
        return done("verify succeeded but the plan could not be saved: " .. tostring(serr))
      end
      events.emit("plan_updated", plan)
      local verdict = ("verify %s: match %.2f, correct=%s, tests=%s"):format(
        step.id,
        result.match_score or 0,
        tostring(result.correct),
        tests.ran and (tests.passed and "passed" or "FAILED") or "not run"
      )
      util.notify(verdict)
      done(nil, result)
    end)
  end)
end

-- ----------------------------------------------------------------- next ----

---Advance to the next step: the backend fills in the (intentionally vague)
---detail of the upcoming step and reshapes later ones if decisions changed.
---@param cb fun(err: string|nil, step: reins.Step|nil)|nil
function M.next(cb)
  if not autonomy.allows("next") then
    util.warn("next is unavailable at autonomy level " .. autonomy.level() .. " (" .. autonomy.name() .. ")")
    if cb then
      cb("next not allowed at this level")
    end
    return
  end
  local r = root()
  local plan = load_plan(r)
  if not plan then
    util.warn("no plan yet - set a goal with :ReinsGoal")
    if cb then
      cb("no plan")
    end
    return
  end
  local step = store.get_step(plan)
  if step and step.status == "active" then
    util.warn("advancing past an unverified step (it will be marked 'skipped')")
  end
  local has_pending = false
  for _, s in ipairs(plan.steps) do
    if s.status == "pending" then
      has_pending = true
      break
    end
  end
  if not has_pending then
    util.notify("plan complete - no pending steps left. :ReinsGoal starts a new plan.")
    if cb then
      cb(nil, nil)
    end
    return
  end
  local ok, err = begin_op("advancing plan…")
  if not ok then
    util.warn(err)
    if cb then
      cb(err)
    end
    return
  end
  local done = finish(cb)
  backend.call("next_step", {
    root = r,
    plan = plan,
    last_verify = step and step.last_verify or nil,
    session = session_for(plan, "next_step"),
  }, function(cerr, result, meta)
    if cerr then
      return done(cerr)
    end
    local target = store.get_step(plan, result.new_current_step_id)
    if not target then
      return done(("backend chose unknown step %q"):format(tostring(result.new_current_step_id)))
    end
    if target.status ~= "pending" then
      -- Don't let the model re-open finished work silently; pick first pending.
      for _, s in ipairs(plan.steps) do
        if s.status == "pending" then
          target = s
          break
        end
      end
    end
    target.detail = result.filled_detail
    target.detail_rank = 1
    for _, change in ipairs(result.downstream_changes or {}) do
      local t = store.get_step(plan, change.step_id)
      if t and t.id ~= target.id then
        t.detail = (t.detail or "") .. ("\n\n[adjusted %s] %s"):format(util.now_iso(), change.change)
        store.append_decision(r, ("[%s] reshaped: %s"):format(change.step_id, change.change))
      end
    end
    store.set_current(plan, target.id, git.head(r))
    remember_session(plan, meta)
    local saved, serr = store.save(r, plan)
    if not saved then
      return done("plan advanced but could not be saved: " .. tostring(serr))
    end
    store.append_decision(r, ("advanced to %s: %s"):format(target.id, target.title))
    events.emit("plan_updated", plan)
    util.notify("current step: " .. target.title)
    done(nil, target)
  end)
end

-- ------------------------------------------------------------ implement ----

---Let the agent implement the current step (levels 3-4 only). Checkpoints
---first when git.checkpoint is enabled; buffers are reloaded afterwards.
---While this runs, lifecycle is busy and completion refuses to write.
---@param cb fun(err: string|nil, summary: string|nil)|nil
function M.implement(cb)
  if not autonomy.allows("implement") then
    util.warn(
      ("Implement step needs autonomy >= 3 (driver-assist); current is %d (%s). The human types at this level."):format(
        autonomy.level(),
        autonomy.name()
      )
    )
    if cb then
      cb("implement not allowed at this level")
    end
    return
  end
  local r = root()
  local plan = load_plan(r)
  local step = plan and store.get_step(plan) or nil
  if not step then
    util.warn("no current step - set a goal with :ReinsGoal")
    if cb then
      cb("no current step")
    end
    return
  end
  local ok, err = begin_op("agent implementing: " .. step.title)
  if not ok then
    util.warn(err)
    if cb then
      cb(err)
    end
    return
  end
  local done = finish(cb)
  if config.get().git.checkpoint then
    local has_cp, checkpoint = pcall(require, "reins.checkpoint")
    if has_cp then
      local ref, cerr = checkpoint.snapshot(r, "before implement " .. step.id)
      if ref then
        store.append_decision(r, ("checkpoint %s before implementing %s"):format(ref:sub(1, 12), step.id))
      elseif cerr then
        util.warn("checkpoint failed (continuing): " .. cerr)
      end
    end
  end
  -- Only an adapter with a NATIVE implement override actually edits files
  -- (claude_code runs as a real agent). Anything else goes through the generic
  -- text path and can only produce a textual proposal - never claim otherwise.
  local adapter = backend.resolve("implement")
  local edits_files = adapter ~= nil and type(adapter.implement) == "function"
  backend.call("implement", {
    root = r,
    step = step,
    plan = plan,
    context = util.context_files(r),
    session = session_for(plan, "implement"),
  }, function(cerr, result, meta)
    if cerr then
      return done(cerr)
    end
    remember_session(plan, meta)
    local saved, serr = store.save(r, plan)
    if not saved then
      util.warn("implement finished but the plan could not be saved: " .. tostring(serr))
    end
    if edits_files then
      store.append_decision(r, ("[%s] agent implemented step (level %d)"):format(step.id, autonomy.level()))
      -- Agent edited files on disk; pick the changes up in open buffers.
      vim.cmd("checktime")
      util.notify("implement finished - run :ReinsVerify")
    else
      store.append_decision(
        r,
        ("[%s] backend produced a textual proposal only - no files were changed (level %d)"):format(
          step.id,
          autonomy.level()
        )
      )
      util.notify(
        "this backend cannot edit files; it returned a textual proposal (see the panel transcript). Apply it yourself, then :ReinsVerify"
      )
    end
    events.emit("plan_updated", plan)
    done(nil, result and result.text or nil)
  end)
end

return M
