---@brief Persistence for the living plan: .stick-shift/plan.json (source of truth),
---.stick-shift/plan.md (human-readable render), .stick-shift/decisions.log (append-only).
---The .stick-shift directory is git-ignored by default via its own .gitignore.
local util = require("stick-shift.util")

local M = {}

---@class stick-shift.Step
---@field id string
---@field title string
---@field detail string
---@field reasoning string
---@field status "pending"|"active"|"verified"|"skipped"
---@field touched string[]
---@field detail_rank integer
---@field began_ref string|nil git HEAD when the step became active
---@field last_verify table|nil most recent VerifyResult (+ tests ground truth)

---@class stick-shift.Plan
---@field version integer
---@field goal string
---@field created string ISO-8601
---@field updated string ISO-8601
---@field session { backend: string, id: string }|nil backend conversation id
---@field current string|nil id of the active step
---@field steps stick-shift.Step[]

---@param root string
---@return string
function M.dir(root)
  return root .. "/.stick-shift"
end

---Create .stick-shift/ (with a self-ignoring .gitignore) on first use.
---@param root string
function M.ensure(root)
  local dir = M.dir(root)
  if not util.exists(dir) then
    util.ensure_dir(dir)
    -- Ignore everything inside .stick-shift by default; delete this file to track the plan.
    util.write_file(dir .. "/.gitignore", "*\n")
  end
end

---@param goal string
---@return stick-shift.Plan
function M.new_plan(goal)
  local now = util.now_iso()
  return {
    version = 1,
    goal = goal,
    created = now,
    updated = now,
    session = nil,
    current = nil,
    steps = {},
  }
end

---@param root string
---@return stick-shift.Plan|nil plan, string|nil err
function M.load(root)
  local content = util.read_file(M.dir(root) .. "/plan.json")
  if not content then
    return nil, "no plan at " .. M.dir(root) .. "/plan.json"
  end
  local ok, plan = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(plan) ~= "table" then
    return nil, "plan.json is corrupt: " .. tostring(plan)
  end
  return plan
end

---Persist plan.json and re-render plan.md.
---@param root string
---@param plan stick-shift.Plan
---@return boolean ok, string|nil err
function M.save(root, plan)
  M.ensure(root)
  plan.updated = util.now_iso()
  local ok, err = util.write_file(M.dir(root) .. "/plan.json", vim.json.encode(plan))
  if not ok then
    return false, err
  end
  util.write_file(M.dir(root) .. "/plan.md", M.render_md(plan))
  return true
end

---@param plan stick-shift.Plan
---@param id string|nil defaults to plan.current
---@return stick-shift.Step|nil
function M.get_step(plan, id)
  id = id or plan.current
  for _, step in ipairs(plan.steps or {}) do
    if step.id == id then
      return step
    end
  end
  return nil
end

---Make `id` the active step (demoting whichever step was active).
---@param plan stick-shift.Plan
---@param id string
---@param began_ref string|nil git HEAD at activation
---@return boolean ok
function M.set_current(plan, id, began_ref)
  local target = M.get_step(plan, id)
  if not target then
    return false
  end
  local previous = M.get_step(plan, plan.current)
  if previous and previous ~= target and previous.status == "active" then
    -- Advancing past an unverified step is allowed but recorded honestly.
    previous.status = "skipped"
  end
  target.status = "active"
  target.began_ref = began_ref
  plan.current = id
  return true
end

---Render the human-readable plan.md (also used by :StickShiftPlan).
---@param plan stick-shift.Plan
---@return string
function M.render_md(plan)
  local lines = {
    "# Living plan",
    "",
    "Goal: " .. (plan.goal or ""),
    "Updated: " .. (plan.updated or ""),
    "",
  }
  local marker = { pending = " ", active = ">", verified = "x", skipped = "~" }
  for i, step in ipairs(plan.steps or {}) do
    table.insert(
      lines,
      ("## [%s] step %d: %s (%s)"):format(marker[step.status] or "?", i, step.title, step.id)
    )
    table.insert(lines, "")
    table.insert(lines, step.detail or "")
    if step.reasoning and step.reasoning ~= "" then
      table.insert(lines, "")
      table.insert(lines, "*Why:* " .. step.reasoning)
    end
    if step.touched and #step.touched > 0 then
      table.insert(lines, "")
      table.insert(lines, "*Touches:* " .. table.concat(step.touched, ", "))
    end
    if step.last_verify then
      table.insert(lines, "")
      table.insert(
        lines,
        ("*Last verify:* match %.2f, correct=%s, tests=%s"):format(
          step.last_verify.match_score or 0,
          tostring(step.last_verify.correct),
          step.last_verify.tests and (step.last_verify.tests.ran and (step.last_verify.tests.passed and "passed" or "FAILED") or "not run") or "not run"
        )
      )
    end
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

---Record the backend conversation id so plan reasoning context survives restarts.
---@param plan stick-shift.Plan
---@param backend_name string
---@param session_id string
function M.set_session(plan, backend_name, session_id)
  plan.session = { backend = backend_name, id = session_id }
end

---Append one line to the append-only decision log.
---@param root string
---@param line string single line, no newline
function M.append_decision(root, line)
  M.ensure(root)
  local fd, ferr = io.open(M.dir(root) .. "/decisions.log", "a")
  if not fd then
    util.warn("could not append to decisions.log: " .. tostring(ferr))
    return
  end
  fd:write(("%s %s\n"):format(util.now_iso(), line:gsub("\n", " ")))
  fd:close()
end

return M
