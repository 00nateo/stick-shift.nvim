---@brief Backend interface, adapter registry, per-role model routing, and the
---shared prompt-contract runner (render -> generate -> parse -> validate ->
---retry once -> clean error). Free-form model text is never trusted for
---control flow; everything that reaches callers is schema-validated.
---
---Adapter contract (see also backend/mock.lua as the reference):
---  adapter.name        string
---  adapter.available() -> boolean, string|nil   (health check; no network unless cheap)
---  adapter.resolve_model(alias) -> string|nil   (maps "local"/"frontier"; passes others through)
---  adapter:generate(opts, cb) -> handle|nil
---     opts: { op, system, prompt, model, json:boolean, session:string|nil, timeout_ms }
---     cb(err|nil, raw_text|nil, meta|nil)  -- meta may carry { session_id = "..." }
---     cb MAY be called from a fast event; this runner re-schedules onto the main loop.
---     handle (optional): { cancel = fun() } - after cancel, cb("cancelled") or silence are both fine.
---  adapter.<op>(adapter, ctx, cb)               (optional native override, e.g. mock, acp,
---                                                claude_code's `implement`; result must already
---                                                match the op schema - it is NOT re-validated)
local config = require("stick-shift.config")
local events = require("stick-shift.events")
local prompts = require("stick-shift.prompts")
local schema = require("stick-shift.schema")
local util = require("stick-shift.util")

local M = {}

---@type table<string, table>
M._adapters = {}
---@type string|nil
M._active = nil

---Which config.models role pays for each op.
local ROLE_FOR_OP = {
  complete = "ghost",
  hint = "hint",
  plan = "plan",
  verify = "verify",
  next_step = "next_step",
  implement = "plan",
}

---Default per-op timeouts (ms). Interactive ops are short; agentic ops long.
local TIMEOUTS = {
  complete = 10000,
  hint = 20000,
  plan = 120000,
  verify = 180000,
  next_step = 120000,
  implement = 600000,
}

---Ops worth showing in the transcript pane (completion/hint are noise).
local TRANSCRIPT_OPS = { plan = true, verify = true, next_step = true, implement = true }

---@param name string
---@param adapter table
function M.register(name, adapter)
  adapter.name = adapter.name or name
  M._adapters[name] = adapter
end

---@return string[]
function M.list()
  local names = vim.tbl_keys(M._adapters)
  table.sort(names)
  return names
end

---Select the active adapter.
---@param name string
---@return boolean ok, string|nil err
function M.use(name)
  if not M._adapters[name] then
    return false, ("unknown backend %q (registered: %s)"):format(name, table.concat(M.list(), ", "))
  end
  M._active = name
  config.get().backend = name
  events.emit("backend_changed", name)
  return true
end

---@return table|nil adapter, string|nil name
function M.active()
  if M._active and M._adapters[M._active] then
    return M._adapters[M._active], M._active
  end
  return nil, nil
end

---Resolve which adapter + concrete model serves an op, honoring per-role
---routing (config.models). Roles may pin a different adapter than the active
---one, e.g. ghost -> ollama while plan -> claude_code.
---@param op string
---@return table|nil adapter, string|nil model, string|nil err
function M.resolve(op)
  local role = ROLE_FOR_OP[op]
  if not role then
    return nil, nil, "unknown op " .. tostring(op)
  end
  local spec = config.get().models[role]
  local adapter, name = M.active()
  if type(spec) == "table" then
    if spec.backend then
      adapter = M._adapters[spec.backend]
      name = spec.backend
      if not adapter then
        return nil, nil, ("models.%s pins unregistered backend %q"):format(role, spec.backend)
      end
    end
    if not adapter then
      return nil, nil, "no active backend"
    end
    local model = spec.model or adapter.resolve_model("frontier")
    return adapter, model, nil
  end
  if not adapter then
    return nil, nil, "no active backend"
  end
  return adapter, adapter.resolve_model(spec or "frontier"), nil
end

---Escape hatch used by callers that must call cb exactly once, on the main loop.
local function main_loop(cb)
  return function(...)
    if vim.in_fast_event() then
      local argv = { n = select("#", ...), ... }
      vim.schedule(function()
        cb(unpack(argv, 1, argv.n))
      end)
    else
      cb(...)
    end
  end
end

---Flatten a lifecycle ctx into template vars. Structured fields are JSON-encoded.
---@param ctx table
---@return table<string, any>
local function template_vars(ctx)
  local autonomy = require("stick-shift.autonomy")
  local buffer = ctx.buffer or {}
  local tests = ctx.tests or {}
  return {
    root = ctx.root or "",
    goal = ctx.goal or "",
    context = ctx.context or "",
    existing_plan = ctx.existing_plan
        and ("An earlier plan exists; revise rather than restart where sensible:\n" .. vim.json.encode(
          ctx.existing_plan
        ))
      or "",
    step_json = ctx.step and vim.json.encode(ctx.step) or "",
    plan_json = ctx.plan and vim.json.encode(ctx.plan) or "",
    last_verify_json = ctx.last_verify and vim.json.encode(ctx.last_verify) or "null",
    diff = ctx.diff or "(no diff available)",
    test_command = tests.command or "(none)",
    tests_ran = tostring(tests.ran or false),
    tests_passed = tostring(tests.passed),
    test_output = tests.output or "(tests were not run)",
    path = buffer.path or "",
    filetype = buffer.filetype or "",
    before_cursor = buffer.before_cursor or "",
    after_cursor = buffer.after_cursor or "",
    granularity = ctx.granularity or config.get().completion.level,
    max_len = ctx.max_len or config.get().hint.max_len,
    level = autonomy.level(),
    level_name = autonomy.name(),
  }
end

---Invoke an op on the routed backend.
---@param op "plan"|"verify"|"next_step"|"hint"|"complete"|"implement"
---@param ctx table op-specific context (see lifecycle/complete/hint callers)
---@param cb fun(err: string|nil, result: table|nil, meta: table|nil)
---@return { cancel: fun() }|nil handle
function M.call(op, ctx, cb)
  cb = main_loop(cb)
  local adapter, model, err = M.resolve(op)
  if not adapter then
    cb(err)
    return nil
  end
  ctx.model = model
  ctx.timeout_ms = ctx.timeout_ms or TIMEOUTS[op]

  do
    -- Tag results with the serving adapter so callers can bookkeep sessions
    -- correctly under per-role routing.
    local inner = cb
    cb = function(cerr, result, meta)
      if not cerr then
        meta = meta or {}
        meta.backend = meta.backend or adapter.name
      end
      inner(cerr, result, meta)
    end
  end

  -- Native override: the adapter implements the whole op itself.
  if type(adapter[op]) == "function" then
    return adapter[op](adapter, ctx, cb)
  end
  if type(adapter.generate) ~= "function" then
    cb(("backend %q supports neither %q nor generate()"):format(adapter.name, op))
    return nil
  end

  -- The synchronous prep must not throw: callers (lifecycle) have already set
  -- their busy flag and only clear it via cb. An uncaught error here (e.g. a
  -- missing template in a broken install) would freeze the plugin for the
  -- whole session - convert it to a normal cb error instead.
  local okp, sys, user = pcall(function()
    return prompts.render(op, template_vars(ctx))
  end)
  if not okp then
    cb(("%s: %s"):format(op, tostring(sys)))
    return nil
  end
  local oks, opschema = pcall(prompts.schema, op)
  if not oks then
    cb(("%s: %s"):format(op, tostring(opschema)))
    return nil
  end
  if TRANSCRIPT_OPS[op] then
    events.emit("transcript", { kind = "request", op = op, text = user })
  end

  local cancelled = false
  local handle = { cancel = function() end }

  local function run(prompt_text, is_retry)
    local h = adapter:generate({
      op = op,
      system = sys,
      prompt = prompt_text,
      model = model,
      json = opschema ~= nil,
      session = ctx.session,
      timeout_ms = ctx.timeout_ms,
      root = ctx.root,
    }, function(gen_err, raw, meta)
      if cancelled then
        return
      end
      if gen_err then
        return cb(("%s (%s): %s"):format(op, adapter.name, gen_err))
      end
      if TRANSCRIPT_OPS[op] then
        events.emit("transcript", { kind = "response", op = op, text = raw or "" })
      end
      if not opschema then
        -- Freeform op (implement): raw text is the result.
        return cb(nil, { text = raw }, meta)
      end
      local ok, value = util.decode_json_loose(raw)
      local verr
      if ok then
        local valid
        valid, verr = schema.validate(value, opschema)
        if valid then
          return cb(nil, value, meta)
        end
      else
        verr = value
      end
      if not is_retry then
        -- One structured retry, then a clean error. Never guess.
        local reminder = prompt_text
          .. "\n\nREMINDER: your previous reply was rejected ("
          .. tostring(verr)
          .. "). Return ONLY the JSON object matching the required shape. No prose, no fences."
        return run(reminder, true)
      end
      cb(("%s (%s): backend returned invalid output after retry: %s"):format(
        op,
        adapter.name,
        tostring(verr)
      ))
    end)
    if h and h.cancel then
      handle.cancel = function()
        cancelled = true
        h.cancel()
      end
    else
      handle.cancel = function()
        cancelled = true
      end
    end
  end

  run(user, false)
  return handle
end

return M
