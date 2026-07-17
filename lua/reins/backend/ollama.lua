---@brief Ollama adapter: HTTP to a local ollama server via curl + vim.system
---(portable across macOS/Linux; no netrw, no sockets in Lua). Stateless by
---design - every prompt carries all needed state (SPEC §10), so no session
---plumbing exists and meta never returns a session_id. POSTs to
---{host}/api/generate with stream=false and parses `.response`; when the op
---expects structured output, ollama's `format: "json"` mode constrains the
---model server-side.
local config = require("reins.config")

local M = { name = "ollama" }

---@return table backends.ollama config
local function bcfg()
  return config.get().backends.ollama
end

---Last `n` characters of process output, flattened for a one-line error.
---@param s string|nil
---@param n integer|nil default 400
---@return string
local function tail(s, n)
  s = vim.trim(s or "")
  n = n or 400
  if #s > n then
    s = "…" .. s:sub(-n)
  end
  return (s:gsub("%s*\n%s*", " | "))
end

---Cheap check only: curl present + host configured. Actual server
---reachability ({host}/api/tags) is probed by :checkhealth reins, not here.
---@return boolean ok, string|nil msg
function M.available()
  local c = bcfg()
  if vim.fn.executable("curl") ~= 1 then
    return false, "curl not found on PATH (required by the ollama backend)"
  end
  if type(c.host) ~= "string" or c.host == "" then
    return false, "backends.ollama.host is not configured"
  end
  return true, ("curl found; host %s (reachability is checked by :checkhealth reins)"):format(c.host)
end

---Map role aliases to the configured model names; pass concrete names through.
---@param alias string|nil
---@return string|nil
function M.resolve_model(alias)
  local c = bcfg()
  if alias == "local" then
    return c.model_local
  end
  if alias == "frontier" or alias == nil then
    return c.model_frontier
  end
  return alias
end

---One-shot generation via POST /api/generate.
---@param opts { op: string, system: string, prompt: string, model: string|nil, json: boolean, session: string|nil, timeout_ms: integer|nil, root: string|nil }
---@param cb fun(err: string|nil, raw: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil handle
function M.generate(_, opts, cb)
  local c = bcfg()
  local ok, why = M.available()
  if not ok then
    cb(why)
    return nil
  end
  if type(opts.model) ~= "string" or opts.model == "" then
    cb("no ollama model resolved - set backends.ollama.model_local/model_frontier")
    return nil
  end
  local payload = vim.json.encode({
    model = opts.model,
    system = opts.system,
    prompt = opts.prompt,
    stream = false,
    -- json mode constrains decoding server-side; nil is simply omitted.
    format = opts.json and "json" or nil,
    options = { num_predict = 1024 },
  })
  local timeout_ms = opts.timeout_ms or 60000
  -- curl gets the tighter deadline so its exit code (28) names the timeout;
  -- vim.system's SIGTERM is only the backstop. Cold model loads can take ~1
  -- minute, hence the generous per-op timeouts upstream.
  local max_time = math.max(5, math.ceil(timeout_ms / 1000))
  local argv = {
    "curl",
    "-sS",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "--max-time",
    tostring(max_time),
    "--data-binary",
    "@-",
    c.host .. "/api/generate",
  }
  local cancelled = false
  local spawned, sysobj = pcall(vim.system, argv, {
    stdin = payload,
    text = true,
    timeout = timeout_ms + 2000,
  }, function(res)
    -- Runner reschedules onto the main loop; call cb directly.
    if cancelled then
      return cb("cancelled")
    end
    if res.code ~= 0 then
      if res.code == 7 then
        return cb(("connection refused at %s - is ollama running? (start it with `ollama serve`)"):format(c.host))
      end
      if res.code == 28 then
        return cb(("request timed out after %ds (a cold model load can take a while)"):format(max_time))
      end
      return cb(("curl exited with code %d: %s"):format(res.code, tail(res.stderr)))
    end
    local okj, body = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
    if not okj or type(body) ~= "table" then
      return cb("could not parse ollama response: " .. tail(res.stdout, 200))
    end
    if body.error ~= nil then
      return cb("ollama error: " .. tostring(body.error))
    end
    if type(body.response) ~= "string" then
      return cb("ollama response is missing the `response` field")
    end
    cb(nil, body.response, {})
  end)
  if not spawned then
    cb("failed to spawn curl: " .. tostring(sysobj))
    return nil
  end
  return {
    cancel = function()
      cancelled = true
      pcall(sysobj.kill, sysobj, 15)
    end,
  }
end

return M
