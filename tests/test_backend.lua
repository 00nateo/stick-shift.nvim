-- Offline tests for lua/stick-shift/backend/init.lua: adapter registry, per-role
-- model routing, and the shared protocol runner (prompt render -> generate ->
-- parse -> schema-validate -> retry once -> clean error). The retry path is
-- the load-bearing honesty mechanism: model text is never trusted raw.
local T = {}

---Fresh modules per test: this file mutates config.models and the adapter
---registry, so per-FILE purging (the runner's) is not fine-grained enough.
local function fresh()
  for name in pairs(package.loaded) do
    if name:match("^stick%-shift") then
      package.loaded[name] = nil
    end
  end
  require("stick-shift.config").setup({ backend = "mock" })
  local backend = require("stick-shift.backend")
  local mock = require("stick-shift.backend.mock")
  mock.reset()
  backend.register("mock", mock)
  assert(backend.use("mock"))
  return backend, mock, require("stick-shift.config")
end

---Minimal generate-only adapter; `replies` is consumed one string per call.
---Records every prompt it was given in `adapter.prompts`.
local function scripted_adapter(replies)
  local adapter = {
    name = "scripted",
    prompts = {},
    calls = 0,
    available = function()
      return true
    end,
    resolve_model = function(alias)
      return "scripted-" .. tostring(alias)
    end,
  }
  function adapter.generate(_, opts, cb)
    adapter.calls = adapter.calls + 1
    table.insert(adapter.prompts, opts.prompt)
    local reply = table.remove(replies, 1)
    cb(nil, reply, { session_id = "scripted-session" })
    return { cancel = function() end }
  end
  return adapter
end

T["use() rejects unknown backends and lists what is registered"] = function()
  local backend = fresh()
  local ok, err = backend.use("nope")
  assert(ok == false, "unknown backend must be rejected")
  assert(err:find("mock", 1, true), "error should list registered adapters: " .. err)
  assert(vim.tbl_contains(backend.list(), "mock"))
end

T["native override path returns mock data with meta.backend tagged"] = function()
  local backend = fresh()
  local got_err, got_result, got_meta
  backend.call("plan", { goal = "test goal" }, function(err, result, meta)
    got_err, got_result, got_meta = err, result, meta
  end)
  assert(got_err == nil, "plan must succeed: " .. tostring(got_err))
  assert(#got_result.steps >= 3, "mock plan has steps")
  assert(got_meta.backend == "mock", "meta.backend must name the serving adapter")
end

T["per-role pinning routes one op to a different adapter"] = function()
  local backend, _, config = fresh()
  backend.register("pinned", {
    name = "pinned",
    available = function()
      return true
    end,
    resolve_model = function()
      return "pinned-model"
    end,
    hint = function(_, _, cb)
      cb(nil, { text = "from the pinned adapter" })
    end,
  })
  config.get().models.hint = { backend = "pinned" }
  local got_result, got_meta
  backend.call("hint", {}, function(_, result, meta)
    got_result, got_meta = result, meta
  end)
  assert(got_result.text == "from the pinned adapter")
  assert(got_meta.backend == "pinned", "meta must name the pinned adapter")
  -- other roles still route to the active adapter
  local plan_meta
  backend.call("plan", { goal = "g" }, function(_, _, meta)
    plan_meta = meta
  end)
  assert(plan_meta.backend == "mock")
end

T["resolve(): alias goes through resolve_model, table spec pins the model"] = function()
  local backend, _, config = fresh()
  local adapter, model = backend.resolve("plan")
  assert(adapter.name == "mock")
  assert(model == "mock-frontier", "frontier alias resolved by adapter, got " .. tostring(model))
  config.get().models.ghost = { backend = "mock", model = "explicit-model" }
  local _, ghost_model = backend.resolve("complete")
  assert(ghost_model == "explicit-model", "explicit model must pass through untouched")
end

T["unknown op yields a clean error"] = function()
  local backend = fresh()
  local got_err
  backend.call("bogus_op", {}, function(err)
    got_err = err
  end)
  assert(got_err and got_err:find("unknown op"), "expected unknown-op error, got " .. tostring(got_err))
end

T["malformed JSON retries once with a reminder, then succeeds"] = function()
  local backend, _, config = fresh()
  local adapter = scripted_adapter({
    "this is not json at all",
    '{"text": "ok after retry"}',
  })
  backend.register("scripted", adapter)
  config.get().models.hint = { backend = "scripted" }
  local got_err, got_result
  backend.call("hint", {}, function(err, result)
    got_err, got_result = err, result
  end)
  assert(got_err == nil, "retry should have rescued the call: " .. tostring(got_err))
  assert(got_result.text == "ok after retry")
  assert(adapter.calls == 2, "generate must run exactly twice, ran " .. adapter.calls)
  assert(adapter.prompts[2]:find("REMINDER"), "retry prompt must carry the JSON-only reminder")
end

T["schema violations (valid JSON, wrong shape) also trigger the retry"] = function()
  local backend, _, config = fresh()
  local adapter = scripted_adapter({
    '{"wrong_field": true}', -- decodes fine, misses required `text`
    '{"text": "shape fixed"}',
  })
  backend.register("scripted", adapter)
  config.get().models.hint = { backend = "scripted" }
  local got_result
  backend.call("hint", {}, function(_, result)
    got_result = result
  end)
  assert(got_result and got_result.text == "shape fixed")
  assert(adapter.calls == 2)
end

T["persistently malformed output becomes a clean error, never a guess"] = function()
  local backend, _, config = fresh()
  local adapter = scripted_adapter({ "garbage one", "garbage two", "never reached" })
  backend.register("scripted", adapter)
  config.get().models.hint = { backend = "scripted" }
  local got_err, got_result
  backend.call("hint", {}, function(err, result)
    got_err, got_result = err, result
  end)
  assert(got_result == nil, "no result may be fabricated from garbage")
  assert(got_err and got_err:find("after retry"), "error must mention the retry: " .. tostring(got_err))
  assert(adapter.calls == 2, "exactly one retry, no more; ran " .. adapter.calls)
end

T["generic path forwards the session and reports meta.session_id"] = function()
  local backend, _, config = fresh()
  local seen_session
  local adapter = {
    name = "sess",
    available = function()
      return true
    end,
    resolve_model = function()
      return "m"
    end,
    generate = function(_, opts, cb)
      seen_session = opts.session
      cb(nil, '{"text": "hi"}', { session_id = "sess-123" })
    end,
  }
  backend.register("sess", adapter)
  config.get().models.hint = { backend = "sess" }
  local got_meta
  backend.call("hint", { session = "resume-me" }, function(_, _, meta)
    got_meta = meta
  end)
  assert(seen_session == "resume-me", "ctx.session must reach generate()")
  assert(got_meta.session_id == "sess-123")
  assert(got_meta.backend == "sess")
end

T["cancel() suppresses a late generate callback"] = function()
  local backend, _, config = fresh()
  local adapter = {
    name = "slow",
    available = function()
      return true
    end,
    resolve_model = function()
      return "m"
    end,
    generate = function(_, _, cb)
      vim.schedule(function()
        cb(nil, '{"text": "too late"}', {})
      end)
      return { cancel = function() end }
    end,
  }
  backend.register("slow", adapter)
  config.get().models.hint = { backend = "slow" }
  local fired = false
  local handle = backend.call("hint", {}, function()
    fired = true
  end)
  handle.cancel()
  vim.wait(100, function()
    return fired
  end)
  assert(fired == false, "cancelled call must never invoke the callback")
end

T["freeform ops (implement) skip JSON validation and return raw text"] = function()
  local backend, _, config = fresh()
  local adapter = scripted_adapter({ "I edited three files and ran the tests." })
  backend.register("scripted", adapter)
  config.get().models.plan = { backend = "scripted" } -- implement bills the plan role
  local got_result
  backend.call("implement", { root = vim.uv.cwd(), step = { id = "s1" } }, function(_, result)
    got_result = result
  end)
  assert(got_result and got_result.text:find("three files"), "freeform text must pass through")
  assert(adapter.calls == 1, "no retry for freeform ops")
end

T["call: a throwing prompt render arrives as a cb error, never an exception"] = function()
  local backend = fresh()
  local adapter = scripted_adapter({ '{"steps": []}' })
  backend.register("scripted", adapter)
  assert(backend.use("scripted"))
  local prompts = require("stick-shift.prompts")
  local orig = prompts.render
  prompts.render = function()
    error("boom: template missing")
  end
  local err_seen
  local ok, thrown = pcall(function()
    backend.call("plan", { root = "/nowhere" }, function(err)
      err_seen = err
    end)
  end)
  prompts.render = orig
  assert(ok, "backend.call must not throw when render fails: " .. tostring(thrown))
  assert(
    err_seen and err_seen:find("boom", 1, true),
    "render failure must arrive through cb (callers' busy flags depend on it), got: " .. tostring(err_seen)
  )
end

return T
