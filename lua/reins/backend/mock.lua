---@brief Mock backend: canned, deterministic structured responses.
---Reference implementation of the adapter contract and the artifact that makes
---the whole core loop (plan -> verify -> next) provable offline with no
---network and no API key. Tests can override any response via set_response().
local M = {
  name = "mock",
  calls = {}, -- recorded { op, ctx } pairs, for assertions
}

---@type table<string, any>
local overrides = {}

---Override the canned result for an op. Pass a function(ctx) -> result|nil,err
---or a plain table. Pass nil to restore the default.
---@param op string
---@param value any
function M.set_response(op, value)
  overrides[op] = value
end

function M.reset()
  overrides = {}
  M.calls = {}
end

function M.available()
  return true, "mock backend is always available"
end

function M.resolve_model(alias)
  return "mock-" .. tostring(alias or "frontier")
end

local function record(op, ctx)
  table.insert(M.calls, { op = op, ctx = ctx })
end

local function respond(op, ctx, cb, default)
  record(op, ctx)
  local o = overrides[op]
  if type(o) == "function" then
    local result, err = o(ctx)
    cb(err, result)
  elseif o ~= nil then
    cb(nil, vim.deepcopy(o))
  else
    cb(nil, default)
  end
  return { cancel = function() end }
end

---Canned plan: three steps with an explicit detail gradient.
function M.plan(_, ctx, cb)
  return respond("plan", ctx, cb, {
    steps = {
      {
        id = "s1",
        title = "Sketch the data model",
        detail = "Define the core types for: "
          .. (ctx.goal or "the project")
          .. ". Decide storage shape (single table vs nested), naming, and what is optional. "
          .. "Write the types and one constructor with validation; add a round-trip test.",
        reasoning = "Everything downstream depends on the data shape; locking it first keeps later steps cheap to re-plan.",
        touched = { "src/model" },
        detail_rank = 1,
      },
      {
        id = "s2",
        title = "Implement core operations",
        detail = "CRUD-style operations over the model. Details depend on step 1's decisions.",
        reasoning = "Operations become obvious once the model exists.",
        touched = { "src/ops" },
        detail_rank = 2,
      },
      {
        id = "s3",
        title = "Wire the interface",
        detail = "Entry point / UI. Intentionally vague until steps 1-2 land.",
        reasoning = "Interface should follow capability, not precede it.",
        touched = {},
        detail_rank = 3,
      },
    },
  })
end

function M.verify(_, ctx, cb)
  return respond("verify", ctx, cb, {
    match_score = 0.9,
    correct = true,
    decisions_changed = {},
    plan_delta = {},
    confidence = { llm = 0.8 },
  })
end

function M.next_step(_, ctx, cb)
  -- Advance to the first pending step in the provided plan.
  local target
  for _, step in ipairs((ctx.plan or {}).steps or {}) do
    if step.status == "pending" then
      target = step.id
      break
    end
  end
  return respond("next_step", ctx, cb, {
    new_current_step_id = target or "s2",
    filled_detail = "Mock-filled detail: implement the operations decided in the previous step. "
      .. "Decisions: error handling strategy (return values vs exceptions).",
    downstream_changes = {},
  })
end

function M.hint(_, ctx, cb)
  return respond("hint", ctx, cb, {
    text = "Consider writing the failing test for this step before the implementation.",
  })
end

function M.complete(_, ctx, cb)
  return respond("complete", ctx, cb, {
    insert_text = "-- mock completion",
    kind = ctx.granularity or "line",
  })
end

---generate() exists so the shared parse/validate/retry path is testable
---against the mock: tests override it via set_response("generate", fn) where
---fn(ctx_opts) returns the RAW STRING the "model" replied with.
function M.generate(_, opts, cb)
  record("generate", opts)
  local o = overrides["generate"]
  if type(o) == "function" then
    local raw, err = o(opts)
    cb(err, raw, { session_id = "mock-session" })
  else
    cb(nil, '{"text": "mock generate output"}', { session_id = "mock-session" })
  end
  return { cancel = function() end }
end

return M
