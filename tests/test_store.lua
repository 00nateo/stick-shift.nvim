-- Offline tests for lua/reins/plan/store.lua: persistence of plan.json,
-- plan.md rendering, the append-only decisions.log and the .reins self-ignore.
-- Everything here is synchronous filesystem work in throwaway temp dirs.
local store = require("reins.plan.store")
local util = require("reins.util")

---Fresh temp directory outside the repo tree.
---@return string
local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

---A plan exercising every documented reins.Step / reins.Plan field with
---non-nil, JSON-representable values (nil fields vanish in JSON, so the
---round-trip test pins down the fields that must survive).
---@return reins.Plan
local function make_full_plan()
  local plan = store.new_plan("ship the widget")
  plan.session = { backend = "mock", id = "sess-42" }
  plan.current = "s2"
  plan.steps = {
    {
      id = "s1",
      title = "Scaffold the module",
      detail = "Create widget.lua with the public API surface.",
      reasoning = "Everything else hangs off this file.",
      status = "verified",
      touched = { "lua/widget.lua", "lua/widget/init.lua" },
      detail_rank = 1,
      began_ref = "abc1234",
      last_verify = {
        match_score = 0.9,
        correct = true,
        summary = "matches the step intent",
        tests = { ran = true, passed = false },
      },
    },
    {
      id = "s2",
      title = "Wire the event loop",
      detail = "Subscribe widget to reins.events.",
      reasoning = "Steps must react to plan changes.",
      status = "active",
      touched = { "lua/widget/events.lua" },
      detail_rank = 1,
      began_ref = "def5678",
      last_verify = {
        match_score = 0.4,
        correct = false,
        summary = "handler missing",
        tests = { ran = false, passed = false },
      },
    },
    {
      id = "s3",
      title = "Polish and document",
      detail = "Sketchy for now.",
      reasoning = "Detail gradient: later steps stay coarse.",
      status = "pending",
      touched = { "doc/widget.txt" },
      detail_rank = 3,
      began_ref = "0000000",
      last_verify = { match_score = 0, correct = false, tests = { ran = false, passed = false } },
    },
  }
  return plan
end

---@param path string
---@return string
local function slurp(path)
  local content = assert(util.read_file(path), "expected file to exist: " .. path)
  return content
end

local T = {}

T["save/load round trip preserves every step and plan field"] = function()
  local root = tmpdir()
  local plan = make_full_plan()
  local ok, err = store.save(root, plan)
  assert(ok, "save failed: " .. tostring(err))

  local loaded, lerr = store.load(root)
  assert(loaded, "load failed: " .. tostring(lerr))
  -- save() stamps plan.updated before encoding, so the in-memory table is
  -- exactly what went to disk; the round trip must reproduce it verbatim.
  assert(
    vim.deep_equal(plan, loaded),
    "round trip mismatch:\nsaved:  " .. vim.inspect(plan) .. "\nloaded: " .. vim.inspect(loaded)
  )
  -- Belt and braces on the fields the class annotations promise per step.
  for i, step in ipairs(plan.steps) do
    local got = loaded.steps[i]
    for _, field in ipairs({
      "id",
      "title",
      "detail",
      "reasoning",
      "status",
      "touched",
      "detail_rank",
      "began_ref",
      "last_verify",
    }) do
      assert(
        vim.deep_equal(step[field], got[field]),
        ("step %d field %q not preserved: %s vs %s"):format(
          i,
          field,
          vim.inspect(step[field]),
          vim.inspect(got[field])
        )
      )
    end
  end
  assert(loaded.goal == "ship the widget", "goal not preserved")
  assert(loaded.current == "s2", "current not preserved")
  assert(vim.deep_equal(loaded.session, { backend = "mock", id = "sess-42" }), "session not preserved")
  assert(loaded.version == 1, "version not preserved")
  assert(type(loaded.created) == "string" and loaded.created ~= "", "created not preserved")
end

T["plan.md render contains every title and marks the current step"] = function()
  local root = tmpdir()
  local plan = make_full_plan()
  assert(store.save(root, plan))

  local md = slurp(store.dir(root) .. "/plan.md")
  assert(md == store.render_md(plan), "plan.md on disk differs from render_md output")

  for _, step in ipairs(plan.steps) do
    assert(md:find(step.title, 1, true), "plan.md missing title: " .. step.title)
  end
  -- The active (current) step is marked '>'; verified 'x'; pending ' '.
  assert(
    md:find("## [>] step 2: Wire the event loop (s2)", 1, true),
    "current step s2 not marked with '>' in plan.md:\n" .. md
  )
  assert(
    md:find("## [x] step 1: Scaffold the module (s1)", 1, true),
    "verified step s1 not marked with 'x' in plan.md"
  )
  assert(
    md:find("## [ ] step 3: Polish and document (s3)", 1, true),
    "pending step s3 not marked with ' ' in plan.md"
  )
  assert(md:find("Goal: ship the widget", 1, true), "goal line missing from plan.md")
end

T["decisions.log is append-only across saves"] = function()
  local root = tmpdir()
  local plan = make_full_plan()

  store.append_decision(root, "chose mock backend")
  assert(store.save(root, plan))
  store.append_decision(root, "advanced past s1\nwith embedded newline")
  plan.current = "s3"
  assert(store.save(root, plan))
  store.append_decision(root, "third entry")

  local log = slurp(store.dir(root) .. "/decisions.log")
  local lines = vim.split(log, "\n", { trimempty = true })
  assert(#lines == 3, "expected 3 log lines, got " .. #lines .. ":\n" .. log)
  assert(lines[1]:find("chose mock backend", 1, true), "first entry lost after later saves")
  assert(
    lines[2]:find("advanced past s1 with embedded newline", 1, true),
    "embedded newline should be flattened into one log line"
  )
  assert(lines[3]:find("third entry", 1, true), "third entry missing")
  for i, line in ipairs(lines) do
    assert(
      line:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ "),
      ("log line %d not timestamped: %s"):format(i, line)
    )
  end
end

T[".reins/.gitignore self-ignore is created and git honors it"] = function()
  local root = tmpdir()
  vim.fn.system({ "git", "init", root })
  assert(vim.v.shell_error == 0, "git init failed")
  vim.fn.system({ "git", "-C", root, "config", "user.email", "test@example.invalid" })
  vim.fn.system({ "git", "-C", root, "config", "user.name", "Test Runner" })

  assert(store.save(root, make_full_plan()))

  local gitignore = store.dir(root) .. "/.gitignore"
  assert(util.exists(gitignore), ".reins/.gitignore was not created")
  assert(slurp(gitignore) == "*\n", ".gitignore should ignore everything inside .reins")

  vim.fn.system({ "git", "-C", root, "check-ignore", ".reins/plan.json" })
  assert(vim.v.shell_error == 0, "git does not ignore .reins/plan.json")
  local status = vim.fn.system({ "git", "-C", root, "status", "--porcelain" })
  assert(not status:find(".reins", 1, true), ".reins leaked into git status:\n" .. status)

  -- ensure() must not clobber a user-edited .gitignore on later saves.
  assert(util.write_file(gitignore, "plan.md\n"))
  assert(store.save(root, make_full_plan()))
  assert(slurp(gitignore) == "plan.md\n", "save() overwrote a user-edited .reins/.gitignore")
end

T["load() on a directory without .reins returns nil, not an error"] = function()
  local root = tmpdir()
  local plan, err = store.load(root)
  assert(plan == nil, "expected nil plan for missing .reins, got " .. vim.inspect(plan))
  assert(type(err) == "string" and err ~= "", "expected a descriptive error string")
end

T["load() on corrupt plan.json fails cleanly, never crashes"] = function()
  local root = tmpdir()
  local dir = store.dir(root)
  vim.fn.mkdir(dir, "p")

  for _, garbage in ipairs({
    "\0\255\1 not json at all {{{",
    '{"goal": "truncated mid-str',
    "42", -- valid JSON but not a table
    "", -- empty file
  }) do
    assert(util.write_file(dir .. "/plan.json", garbage))
    local ok, plan, err = pcall(store.load, root)
    assert(ok, "load() crashed on garbage " .. vim.inspect(garbage) .. ": " .. tostring(plan))
    assert(
      plan == nil,
      "expected nil plan for garbage " .. vim.inspect(garbage) .. ", got " .. vim.inspect(plan)
    )
    assert(type(err) == "string" and err ~= "", "expected an error message for garbage input")
  end
end

T["double save keeps plan.json valid and loses no decision entries"] = function()
  local root = tmpdir()
  local base = make_full_plan()
  assert(store.save(root, base))

  -- Two writers derived from the same snapshot save back-to-back: the last
  -- writer wins wholesale, the file stays valid JSON, and the append-only
  -- log keeps every entry from both.
  local writer_a = vim.deepcopy(base)
  writer_a.steps[#writer_a.steps + 1] = {
    id = "s4",
    title = "Writer A extra step",
    detail = "added by A",
    reasoning = "",
    status = "pending",
    touched = {},
    detail_rank = 4,
  }
  local writer_b = vim.deepcopy(base)
  writer_b.current = "s3"
  writer_b.steps[3].status = "active"

  store.append_decision(root, "writer A saving")
  assert(store.save(root, writer_a))
  store.append_decision(root, "writer B saving")
  assert(store.save(root, writer_b))

  local loaded, lerr = store.load(root)
  assert(loaded, "load after double save failed: " .. tostring(lerr))
  assert(vim.deep_equal(loaded, writer_b), "last save must win wholesale")
  assert(loaded.current == "s3", "writer B's current pointer lost")
  assert(#loaded.steps == 3, "writer B snapshot had 3 steps, got " .. #loaded.steps)
  assert(store.get_step(loaded, "s4") == nil, "stale writer A step resurrected")

  local log = slurp(store.dir(root) .. "/decisions.log")
  assert(log:find("writer A saving", 1, true), "writer A decision lost")
  assert(log:find("writer B saving", 1, true), "writer B decision lost")
  local _, count = log:gsub("\n", "")
  assert(count == 2, "expected exactly 2 decision lines, got " .. count)
end

return T
