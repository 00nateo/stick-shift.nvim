---@brief local_mac backend: OpenAI-compatible chat-completions server on
---localhost (MLX server, llama.cpp server, LM Studio, etc.). Transport is
---curl via vim.system, mirroring the ollama adapter, POSTing to
---{url}/chat/completions with stream=false.
---
---HONESTY NOTE: this adapter's request construction and response parsing are
---exercised by headless tests against canned/scripted responses, but it has
---NOT been run against a real MLX/llama.cpp server on this machine (none is
---installed). available() is cheap (curl + config only); server reachability
---is probed by :checkhealth reins.
---TODO(reins): validate against a real local server (MLX `mlx_lm.server`,
---llama.cpp `llama-server`) and confirm response_format json_object handling.
local config = require("reins.config")
local util = require("reins.util")

local M = { name = "local_mac" }

---@return table
local function bcfg()
  return (config.get().backends or {}).local_mac or {}
end

---Cheap check only: curl present + url configured. available() runs on the
---main loop (e.g. :ReinsBackend), so it must never block on the network -
---actual server reachability ({url}/models) is probed by :checkhealth reins.
---@return boolean ok, string|nil msg
function M.available()
  if vim.fn.executable("curl") ~= 1 then
    return false, "curl not found on PATH"
  end
  local url = bcfg().url
  if type(url) ~= "string" or url == "" then
    return false, "backends.local_mac.url is not configured"
  end
  return true,
    ("curl found; %s configured (reachability is checked by :checkhealth reins; adapter tested against canned responses only)"):format(
      url
    )
end

---Map role aliases to the configured model name; pass explicit names through.
---@param alias string|nil
---@return string|nil
function M.resolve_model(alias)
  if alias == "local" or alias == "frontier" then
    return bcfg().model
  end
  return alias
end

---Parse an OpenAI-compatible /chat/completions response body.
---Pure function, exposed for headless tests.
---@param raw string|nil stdout from curl
---@return string|nil err, string|nil text, table|nil meta
function M._parse_response(raw)
  if type(raw) ~= "string" or raw == "" then
    return "empty response from server"
  end
  local ok, body = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok or type(body) ~= "table" then
    return "invalid JSON from server: " .. util.truncate(raw, 200)
  end
  if body.error ~= nil then
    local e = body.error
    local msg = type(e) == "table" and (e.message or vim.json.encode(e)) or tostring(e)
    return "server error: " .. msg
  end
  local choice = type(body.choices) == "table" and body.choices[1] or nil
  local content = type(choice) == "table"
      and type(choice.message) == "table"
      and choice.message.content
    or nil
  if type(content) ~= "string" then
    return "response missing choices[1].message.content"
  end
  return nil, content, {}
end

---Build the request payload. Pure function, exposed for headless tests.
---@param opts table generate() opts
---@return table payload
function M._payload(opts)
  local payload = {
    model = opts.model or bcfg().model or "default",
    messages = {
      { role = "system", content = opts.system or "" },
      { role = "user", content = opts.prompt or "" },
    },
    stream = false,
  }
  if opts.json then
    -- Many local servers ignore response_format; the prompt contract's
    -- "JSON only" discipline plus the shared retry path is the real guard.
    payload.response_format = { type = "json_object" }
  end
  return payload
end

---@param opts { op:string, system:string, prompt:string, model:string|nil, json:boolean, session:string|nil, timeout_ms:integer|nil, root:string|nil }
---@param cb fun(err: string|nil, raw_text: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil handle
function M.generate(_, opts, cb)
  local ok, why = M.available()
  if not ok then
    cb(why)
    return nil
  end
  local url = bcfg().url
  local timeout_ms = opts.timeout_ms or 60000
  local body = vim.json.encode(M._payload(opts))
  local spawned, sysobj = pcall(vim.system, {
    "curl",
    "-sS",
    "-X",
    "POST",
    url .. "/chat/completions",
    "-H",
    "Content-Type: application/json",
    "--max-time",
    tostring(math.max(1, math.ceil(timeout_ms / 1000))),
    "--data-binary",
    "@-",
  }, {
    stdin = body,
    timeout = timeout_ms + 2000, -- curl --max-time is the primary timeout
  }, function(res)
    if res.code ~= 0 then
      local why = (res.stderr or ""):match("[^\n]+") or ("curl exited " .. res.code)
      if why:find("refused") or why:find("Failed to connect") then
        why = why
          .. (" - is a local OpenAI-compatible server running at %s?"):format(url)
      end
      return cb(why)
    end
    cb(M._parse_response(res.stdout))
  end)
  if not spawned then
    cb("failed to spawn curl: " .. tostring(sysobj))
    return nil
  end
  return {
    cancel = function()
      pcall(sysobj.kill, sysobj, 15)
    end,
  }
end

return M
