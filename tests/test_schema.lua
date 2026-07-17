-- Offline tests for lua/reins/schema.lua: every supported keyword (type,
-- properties, required, items, enum, minimum, maximum), tolerance for extra
-- properties, and the shape of error strings including nested paths.
local T = {}

local function validate(value, schema)
  return require("reins.schema").validate(value, schema)
end

-- type: scalars ----------------------------------------------------------------

T["type string: match and mismatch with clear error"] = function()
  assert(validate("hi", { type = "string" }))
  local ok, err = validate(42, { type = "string" })
  assert(not ok)
  assert(err == "$: expected string, got number", tostring(err))
end

T["type number: accepts integers and fractions"] = function()
  assert(validate(3, { type = "number" }))
  assert(validate(1.5, { type = "number" }))
  local ok, err = validate("3", { type = "number" })
  assert(not ok)
  assert(err == "$: expected number, got string", tostring(err))
end

T["type integer: whole numbers only"] = function()
  assert(validate(7, { type = "integer" }))
  assert(validate(0, { type = "integer" }))
  assert(validate(-2, { type = "integer" }))
  local ok, err = validate(1.5, { type = "integer" })
  assert(not ok)
  assert(err == "$: expected integer, got number", tostring(err))
  ok = validate(true, { type = "integer" })
  assert(not ok)
end

T["type boolean: true and false pass, others fail"] = function()
  assert(validate(true, { type = "boolean" }))
  assert(validate(false, { type = "boolean" }))
  local ok, err = validate(0, { type = "boolean" })
  assert(not ok)
  assert(err == "$: expected boolean, got number", tostring(err))
end

T["nil value fails a typed schema with clear error"] = function()
  local ok, err = validate(nil, { type = "string" })
  assert(not ok)
  assert(err == "$: expected string, got nil", tostring(err))
end

-- type: object/array + empty-table ambiguity -----------------------------------

T["type object: map passes, array fails"] = function()
  assert(validate({ a = 1 }, { type = "object" }))
  local ok, err = validate({ 1, 2 }, { type = "object" })
  assert(not ok)
  assert(err == "$: expected object, got array", tostring(err))
end

T["type array: list passes, map fails"] = function()
  assert(validate({ 1, 2, 3 }, { type = "array" }))
  local ok, err = validate({ a = 1 }, { type = "array" })
  assert(not ok)
  assert(err == "$: expected array, got object", tostring(err))
end

T["empty table satisfies both object and array"] = function()
  assert(validate({}, { type = "object" }))
  assert(validate({}, { type = "array" }))
end

-- enum ---------------------------------------------------------------------------

T["enum: member passes, non-member fails naming the value"] = function()
  local schema = { type = "string", enum = { "todo", "active", "done" } }
  assert(validate("active", schema))
  local ok, err = validate("bogus", schema)
  assert(not ok)
  assert(err:find("not in enum", 1, true), tostring(err))
  assert(err:find("bogus", 1, true), tostring(err))
  -- enum also works on numbers, without a type keyword
  assert(validate(2, { enum = { 1, 2, 3 } }))
  ok = validate(9, { enum = { 1, 2, 3 } })
  assert(not ok)
end

-- minimum / maximum ---------------------------------------------------------------

T["minimum: boundary passes, below fails"] = function()
  assert(validate(1, { type = "integer", minimum = 1 }))
  assert(validate(5, { type = "number", minimum = 1 }))
  local ok, err = validate(0, { type = "integer", minimum = 1 })
  assert(not ok)
  assert(err:find("minimum", 1, true), tostring(err))
  -- minimum of 0 is honored (no falsy-zero bug)
  ok = validate(-1, { type = "number", minimum = 0 })
  assert(not ok)
end

T["maximum: boundary passes, above fails"] = function()
  assert(validate(10, { type = "number", maximum = 10 }))
  local ok, err = validate(10.5, { type = "number", maximum = 10 })
  assert(not ok)
  assert(err:find("maximum", 1, true), tostring(err))
end

T["minimum and maximum combine into a range"] = function()
  local schema = { type = "number", minimum = 0, maximum = 1 }
  assert(validate(0.5, schema))
  assert(not validate(-0.1, schema))
  assert(not validate(1.1, schema))
end

-- object: properties / required / extras ------------------------------------------

T["required: present passes, missing names the field"] = function()
  local schema = { type = "object", required = { "id", "goal" } }
  assert(validate({ id = "s1", goal = "ship" }, schema))
  local ok, err = validate({ id = "s1" }, schema)
  assert(not ok)
  assert(err == "$.goal: required field missing", tostring(err))
end

T["required: false is a present value, not missing"] = function()
  assert(validate({ flag = false }, { type = "object", required = { "flag" } }))
end

T["properties: typed field mismatch reports the property path"] = function()
  local schema = {
    type = "object",
    properties = { count = { type = "integer" }, name = { type = "string" } },
  }
  assert(validate({ count = 3, name = "x" }, schema))
  local ok, err = validate({ count = "three" }, schema)
  assert(not ok)
  assert(err == "$.count: expected integer, got string", tostring(err))
end

T["properties: absent optional fields are fine"] = function()
  local schema = { type = "object", properties = { note = { type = "string" } } }
  assert(validate({}, schema))
  assert(validate({ other = 1 }, schema))
end

T["extra properties are tolerated"] = function()
  local schema = {
    type = "object",
    required = { "id" },
    properties = { id = { type = "string" } },
  }
  assert(validate({ id = "s1", surprise = { "llms", "add", "fields" }, n = 5 }, schema))
end

-- array items ----------------------------------------------------------------------

T["items: every element checked, failure carries the index"] = function()
  local schema = { type = "array", items = { type = "number" } }
  assert(validate({ 1, 2, 3 }, schema))
  local ok, err = validate({ 1, 2, "three" }, schema)
  assert(not ok)
  assert(err == "$[3]: expected number, got string", tostring(err))
end

T["items: empty array passes trivially"] = function()
  assert(validate({}, { type = "array", items = { type = "object", required = { "id" } } }))
end

-- nested schemas --------------------------------------------------------------------

local plan_schema = {
  type = "object",
  required = { "goal", "steps" },
  properties = {
    goal = { type = "string" },
    autonomy = { type = "integer", minimum = 0, maximum = 3 },
    steps = {
      type = "array",
      items = {
        type = "object",
        required = { "id", "status" },
        properties = {
          id = { type = "string" },
          status = { type = "string", enum = { "todo", "active", "verified" } },
          detail_rank = { type = "integer", minimum = 1 },
          done = { type = "boolean" },
        },
      },
    },
  },
}

T["nested: realistic plan payload validates"] = function()
  local plan = {
    goal = "build a todo CLI",
    autonomy = 2,
    steps = {
      { id = "s1", status = "active", detail_rank = 1, done = false },
      { id = "s2", status = "todo", detail_rank = 3, extra = "tolerated" },
    },
  }
  local ok, err = validate(plan, plan_schema)
  assert(ok, tostring(err))
end

T["nested: type failure deep in an array reports the full path"] = function()
  local plan = {
    goal = "g",
    steps = { { id = "s1", status = "todo" }, { id = 2, status = "todo" } },
  }
  local ok, err = validate(plan, plan_schema)
  assert(not ok)
  assert(err == "$.steps[2].id: expected string, got number", tostring(err))
end

T["nested: enum failure reports the full path"] = function()
  local plan = { goal = "g", steps = { { id = "s1", status = "bogus" } } }
  local ok, err = validate(plan, plan_schema)
  assert(not ok)
  assert(err:find("$.steps[1].status", 1, true), tostring(err))
  assert(err:find("not in enum", 1, true), tostring(err))
end

T["nested: required failure inside items reports the full path"] = function()
  local plan = { goal = "g", steps = { { id = "s1" } } }
  local ok, err = validate(plan, plan_schema)
  assert(not ok)
  assert(err == "$.steps[1].status: required field missing", tostring(err))
end

T["nested: minimum failure inside items reports the full path"] = function()
  local plan = { goal = "g", steps = { { id = "s1", status = "todo", detail_rank = 0 } } }
  local ok, err = validate(plan, plan_schema)
  assert(not ok)
  assert(err:find("$.steps[1].detail_rank", 1, true), tostring(err))
  assert(err:find("minimum", 1, true), tostring(err))
end

T["schema without type constrains nothing but enum/range still apply"] = function()
  assert(validate("anything", {}))
  assert(validate({ nested = true }, {}))
  local ok = validate(99, { maximum = 10 })
  assert(not ok)
end

return T
