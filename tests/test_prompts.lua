-- Offline tests for lua/stick-shift/prompts.lua: template rendering, {{placeholder}}
-- substitution, schema loading, caching, and clean failure on missing templates.
-- Runner contract: return { ["name"] = fn }; a test passes unless it errors.
local T = {}

local ALL_OPS = { "plan", "verify", "next_step", "hint", "complete", "implement" }
local SCHEMA_OPS = { "plan", "verify", "next_step", "hint", "complete" }

---Full variable set mirroring backend.init's template_vars(), every value
---carrying a unique sentinel so substitution is observable in the output.
local function full_vars()
  return {
    root = "SENTINEL_root/tmp/project",
    goal = "SENTINEL_goal build a todo CLI",
    context = "SENTINEL_context project context files",
    existing_plan = "SENTINEL_existing_plan an earlier plan exists",
    step_json = '{"id":"s1","title":"SENTINEL_step_json"}',
    plan_json = '{"steps":[],"note":"SENTINEL_plan_json"}',
    last_verify_json = '{"match_score":0.5,"note":"SENTINEL_last_verify_json"}',
    diff = "SENTINEL_diff +++ b/src/foo.lua",
    test_command = "SENTINEL_test_command make test",
    tests_ran = "true",
    tests_passed = "false",
    test_output = "SENTINEL_test_output 3 passed, 0 failed",
    path = "SENTINEL_path/src/foo.lua",
    filetype = "SENTINEL_filetype_lua",
    before_cursor = "SENTINEL_before_cursor local x =",
    after_cursor = "SENTINEL_after_cursor return x",
    granularity = "SENTINEL_granularity_line",
    max_len = 120,
    level = 2,
    level_name = "SENTINEL_level_name_copilot",
  }
end

T["01 every op renders system+user with all placeholders substituted"] = function()
  local prompts = require("stick-shift.prompts")
  for _, op in ipairs(ALL_OPS) do
    local system, user = prompts.render(op, full_vars())
    assert(type(system) == "string" and #system > 0, op .. ": empty system prompt")
    assert(type(user) == "string" and #user > 0, op .. ": empty user prompt")
    assert(
      not system:find("{{", 1, true),
      op .. ": unsubstituted placeholder in system prompt:\n" .. system
    )
    assert(
      not user:find("{{", 1, true),
      op .. ": unsubstituted placeholder in user prompt:\n" .. user
    )
  end
end

T["02 substituted values appear in rendered output"] = function()
  local prompts = require("stick-shift.prompts")
  local vars = full_vars()

  local _, plan_user = prompts.render("plan", vars)
  assert(plan_user:find("SENTINEL_goal", 1, true), "plan user lost {{goal}}")
  assert(plan_user:find("SENTINEL_root", 1, true), "plan user lost {{root}}")
  assert(plan_user:find("SENTINEL_context", 1, true), "plan user lost {{context}}")
  assert(plan_user:find("SENTINEL_existing_plan", 1, true), "plan user lost {{existing_plan}}")

  local _, verify_user = prompts.render("verify", vars)
  assert(verify_user:find("SENTINEL_step_json", 1, true), "verify user lost {{step_json}}")
  assert(verify_user:find("SENTINEL_diff", 1, true), "verify user lost {{diff}}")
  assert(verify_user:find("SENTINEL_test_command", 1, true), "verify user lost {{test_command}}")
  assert(verify_user:find("SENTINEL_test_output", 1, true), "verify user lost {{test_output}}")

  local _, next_user = prompts.render("next_step", vars)
  assert(next_user:find("SENTINEL_plan_json", 1, true), "next_step user lost {{plan_json}}")
  assert(
    next_user:find("SENTINEL_last_verify_json", 1, true),
    "next_step user lost {{last_verify_json}}"
  )

  local hint_system, hint_user = prompts.render("hint", vars)
  assert(hint_system:find("120", 1, true), "hint system lost {{max_len}}")
  assert(hint_user:find("SENTINEL_before_cursor", 1, true), "hint user lost {{before_cursor}}")
  assert(hint_user:find("SENTINEL_after_cursor", 1, true), "hint user lost {{after_cursor}}")

  local comp_system, comp_user = prompts.render("complete", vars)
  assert(comp_system:find("SENTINEL_granularity_line", 1, true), "complete system lost {{granularity}}")
  assert(comp_user:find("SENTINEL_path", 1, true), "complete user lost {{path}}")
  assert(comp_user:find("SENTINEL_filetype_lua", 1, true), "complete user lost {{filetype}}")
  assert(comp_user:find("SENTINEL_before_cursor", 1, true), "complete user lost {{before_cursor}}")

  local impl_system, impl_user = prompts.render("implement", vars)
  assert(impl_system:find("SENTINEL_level_name_copilot", 1, true), "implement system lost {{level_name}}")
  assert(impl_user:find("SENTINEL_step_json", 1, true), "implement user lost {{step_json}}")
  assert(impl_user:find("SENTINEL_plan_json", 1, true), "implement user lost {{plan_json}}")
end

T["03 missing vars render empty, never literal braces"] = function()
  local prompts = require("stick-shift.prompts")
  for _, op in ipairs(ALL_OPS) do
    local system, user = prompts.render(op, {})
    assert(
      not system:find("{{", 1, true),
      op .. ": empty vars leaked braces into system prompt"
    )
    assert(not user:find("{{", 1, true), op .. ": empty vars leaked braces into user prompt")
  end
end

T["04 substitute: tables JSON-encode, scalars stringify, nil empties"] = function()
  local prompts = require("stick-shift.prompts")
  local out = prompts.substitute("a={{a}} b={{b}} c={{c}} d={{d}}", {
    a = { k = "v" },
    b = 7,
    c = false,
  })
  assert(out:find('"k"', 1, true) and out:find('"v"', 1, true), "table var not JSON-encoded: " .. out)
  assert(out:find("b=7", 1, true), "number var not stringified: " .. out)
  assert(out:find("c=false", 1, true), "boolean var not stringified: " .. out)
  assert(out:match("d=$"), "nil var should render as empty string: " .. out)
  -- gsub's match count must not leak out of substitute()
  assert(
    select("#", prompts.substitute("{{a}}{{b}}", {})) == 1,
    "substitute must return exactly one value"
  )
end

T["05 schema loads for every structured op"] = function()
  local prompts = require("stick-shift.prompts")
  for _, op in ipairs(SCHEMA_OPS) do
    local s = prompts.schema(op)
    assert(type(s) == "table", op .. ": schema did not load")
    assert(s.type == "object", op .. ": schema root must be an object")
    assert(
      type(s.required) == "table" and #s.required > 0,
      op .. ": schema declares no required fields"
    )
    assert(type(s.properties) == "table", op .. ": schema has no properties")
    for _, req in ipairs(s.required) do
      assert(
        s.properties[req] ~= nil,
        op .. ": required field " .. req .. " missing from properties"
      )
    end
  end
end

T["06 freeform and unknown ops have no schema"] = function()
  local prompts = require("stick-shift.prompts")
  assert(prompts.schema("implement") == nil, "implement is freeform; schema must be nil")
  assert(prompts.schema("no_such_op") == nil, "unknown op must have nil schema, not an error")
end

T["07 schema is cached across calls"] = function()
  local prompts = require("stick-shift.prompts")
  local first = prompts.schema("plan")
  local second = prompts.schema("plan")
  assert(first ~= nil and first == second, "repeat schema() calls must return the cached table")
end

T["08 missing template is a clean error"] = function()
  local prompts = require("stick-shift.prompts")
  local ok, err = pcall(prompts.render, "no_such_op", {})
  assert(not ok, "render of a missing op must error")
  err = tostring(err)
  assert(err:find("missing prompt template", 1, true), "unhelpful error: " .. err)
  assert(err:find("no_such_op.system.md", 1, true), "error should name the missing file: " .. err)
end

T["09 template cache holds the raw template, not rendered output"] = function()
  local prompts = require("stick-shift.prompts")
  local vars1 = full_vars()
  vars1.goal = "GOAL_ONE unique"
  local vars2 = full_vars()
  vars2.goal = "GOAL_TWO unique"
  local _, u1 = prompts.render("plan", vars1)
  local _, u2 = prompts.render("plan", vars2)
  assert(u1:find("GOAL_ONE", 1, true) and not u1:find("GOAL_TWO", 1, true), "first render polluted")
  assert(u2:find("GOAL_TWO", 1, true) and not u2:find("GOAL_ONE", 1, true), "cache served a rendered prompt")
end

return T
