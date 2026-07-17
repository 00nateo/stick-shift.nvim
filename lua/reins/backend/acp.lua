---@brief ACP backend: minimal Agent Client Protocol client
---(https://agentclientprotocol.com). JSON-RPC 2.0 over stdio with
---newline-delimited JSON frames, against an agent spawned from
---config.backends.acp.command (argv table).
---
---Per generate() call the flow is:
---  spawn agent -> initialize -> session/new -> session/prompt
---  -> collect session/update agent_message_chunk text
---  -> session/prompt result arrives -> cb(collected text) -> kill agent.
---
---Agent-to-client requests: session/request_permission is answered by
---selecting a reject option unless autonomy.allows("agent_free") (level 4);
---everything else (fs/*, terminal/*) gets a -32601 error because we advertise
---no such capabilities in initialize.
---
---HONESTY NOTE: framing, handshake, chunk collection, and permission handling
---are verified headlessly against a scripted fake agent speaking canned
---JSON-RPC lines, NOT against a production ACP agent (none is installed
---here). available() says so.
---TODO(reins): verify against a real agent (e.g. claude-code-acp, gemini-cli).
---TODO(reins): session reuse via session/load when the agent advertises the
---loadSession capability; currently every call opens a fresh session (prompts
---embed all needed state, so this is an optimization, not a correctness gap).
local config = require("reins.config")

local M = { name = "acp" }

---ACP protocol major version we speak.
local PROTOCOL_VERSION = 1

---@return table
local function bcfg()
  return (config.get().backends or {}).acp or {}
end

---@return boolean ok, string|nil msg
function M.available()
  local cmd = bcfg().command
  if type(cmd) ~= "table" or #cmd == 0 or type(cmd[1]) ~= "string" then
    return false, 'backends.acp.command is not set (argv table, e.g. { "claude-code-acp" })'
  end
  if vim.fn.executable(cmd[1]) ~= 1 then
    return false, ("acp agent binary %q not found on PATH"):format(cmd[1])
  end
  return true,
    ("agent: %s (minimal client, verified against a scripted fake agent only)"):format(
      table.concat(cmd, " ")
    )
end

---ACP's core protocol has no model selection; the agent decides. Aliases
---resolve to nil (omitted), explicit names pass through untouched.
---@param alias string|nil
---@return string|nil
function M.resolve_model(alias)
  if alias == "local" or alias == "frontier" then
    return nil
  end
  return alias
end

-- --------------------------------------------------------------------------
-- Pure framing / dispatch helpers (exposed with _ prefix for headless tests).
-- --------------------------------------------------------------------------

---Encode one newline-delimited JSON-RPC frame.
---@param msg table
---@return string
function M._frame(msg)
  return vim.json.encode(msg) .. "\n"
end

---Line reassembler for a chunked stdout stream. Returns a feed function;
---feed(nil) flushes a trailing unterminated line (EOF).
---@param on_line fun(line: string)
---@return fun(chunk: string|nil)
function M._line_reader(on_line)
  local buf = ""
  return function(chunk)
    if chunk == nil then
      if buf ~= "" then
        on_line(buf)
        buf = ""
      end
      return
    end
    buf = buf .. chunk
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1):gsub("\r$", "")
      buf = buf:sub(nl + 1)
      if line ~= "" then
        on_line(line)
      end
    end
  end
end

---Decode one frame; nil on garbage (a broken line is logged by the caller,
---never trusted).
---@param line string
---@return table|nil
function M._decode(line)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(msg) == "table" then
    return msg
  end
  return nil
end

---Pick the RequestPermissionOutcome for a session/request_permission.
---Deny-by-default: only autonomy level 4 (agent_free) selects an allow
---option. Prefers the *_once variant so a single grant never becomes standing
---permission.
---@param options table[]|nil [{ optionId, kind }]
---@param allow boolean
---@return table outcome
function M._permission_outcome(options, allow)
  local rank = allow and { allow_once = 1, allow_always = 2 }
    or { reject_once = 1, reject_always = 2 }
  local best_id, best_rank
  for _, o in ipairs(options or {}) do
    local r = type(o) == "table" and rank[o.kind] or nil
    if r and (not best_rank or r < best_rank) then
      best_id, best_rank = o.optionId, r
    end
  end
  if best_id ~= nil then
    return { outcome = "selected", optionId = best_id }
  end
  return { outcome = "cancelled" }
end

---Handle one decoded message from the agent. Pure with respect to I/O: all
---effects go through st.send / st.finish / st.fail, so tests can drive it
---with canned messages and captured sends.
---
---st = { ids = {initialize, new_session, prompt}, next_id = fun():integer,
---       chunks = string[], session_id = string|nil, cwd = string,
---       allow = boolean, send = fun(msg), finish = fun(text, meta),
---       fail = fun(err) }
---@param st table
---@param msg table
function M._handle(st, msg)
  if msg.method ~= nil then
    -- Agent -> client request or notification.
    if msg.method == "session/update" then
      local update = type(msg.params) == "table" and msg.params.update or nil
      if type(update) == "table" and update.sessionUpdate == "agent_message_chunk" then
        local content = update.content
        if type(content) == "table" and content.type == "text" and type(content.text) == "string" then
          table.insert(st.chunks, content.text)
        end
      end
      return
    end
    if msg.id ~= nil and msg.method == "session/request_permission" then
      local options = type(msg.params) == "table" and msg.params.options or nil
      st.send({
        jsonrpc = "2.0",
        id = msg.id,
        result = { outcome = M._permission_outcome(options, st.allow) },
      })
      return
    end
    if msg.id ~= nil then
      -- fs/*, terminal/*, anything else: we advertised no such capability.
      st.send({
        jsonrpc = "2.0",
        id = msg.id,
        error = {
          code = -32601,
          message = "method not supported by reins client: " .. tostring(msg.method),
        },
      })
    end
    return
  end

  -- Response to one of our requests.
  if msg.id == st.ids.initialize then
    if msg.error then
      return st.fail("initialize failed: " .. tostring(msg.error.message or vim.inspect(msg.error)))
    end
    st.ids.new_session = st.next_id()
    st.send({
      jsonrpc = "2.0",
      id = st.ids.new_session,
      method = "session/new",
      params = { cwd = st.cwd, mcpServers = {} },
    })
    return
  end
  if msg.id == st.ids.new_session then
    if msg.error then
      return st.fail("session/new failed: " .. tostring(msg.error.message or vim.inspect(msg.error)))
    end
    st.session_id = type(msg.result) == "table" and msg.result.sessionId or nil
    if type(st.session_id) ~= "string" then
      return st.fail("session/new returned no sessionId")
    end
    st.ids.prompt = st.next_id()
    st.send({
      jsonrpc = "2.0",
      id = st.ids.prompt,
      method = "session/prompt",
      params = {
        sessionId = st.session_id,
        prompt = { { type = "text", text = st.prompt_text } },
      },
    })
    return
  end
  if msg.id == st.ids.prompt then
    if msg.error then
      return st.fail("session/prompt failed: " .. tostring(msg.error.message or vim.inspect(msg.error)))
    end
    return st.finish(table.concat(st.chunks), { session_id = st.session_id })
  end
end

---Build the initial client state + the initialize frame for a generate call.
---Exposed for tests.
---@param opts table generate() opts
---@param allow boolean autonomy.allows("agent_free")
---@return table st, table initialize_msg
function M._new_state(opts, allow)
  local id = 0
  local st = {
    ids = {},
    chunks = {},
    session_id = nil,
    cwd = opts.root or assert(vim.uv.cwd()),
    allow = allow,
    -- ACP session/prompt has no separate system slot; prepend it.
    prompt_text = (opts.system and opts.system ~= "" and (opts.system .. "\n\n") or "")
      .. (opts.prompt or ""),
    next_id = function()
      id = id + 1
      return id
    end,
  }
  st.ids.initialize = st.next_id()
  local init = {
    jsonrpc = "2.0",
    id = st.ids.initialize,
    method = "initialize",
    params = {
      protocolVersion = PROTOCOL_VERSION,
      clientCapabilities = {
        fs = { readTextFile = false, writeTextFile = false },
      },
      clientInfo = { name = "reins.nvim", version = "0.1" },
    },
  }
  return st, init
end

-- --------------------------------------------------------------------------
-- Transport
-- --------------------------------------------------------------------------

---@param opts { op:string, system:string, prompt:string, model:string|nil, json:boolean, session:string|nil, timeout_ms:integer|nil, root:string|nil }
---@param cb fun(err: string|nil, raw_text: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil handle
function M.generate(_, opts, cb)
  local cmd = bcfg().command
  if type(cmd) ~= "table" or #cmd == 0 then
    cb('backends.acp.command is not configured (argv table, e.g. { "claude-code-acp" })')
    return nil
  end
  local autonomy = require("reins.autonomy")

  local done = false
  local proc = nil
  local stderr_tail = ""

  local st, init = M._new_state(opts, autonomy.allows("agent_free"))

  local function conclude(err, text, meta)
    if done then
      return
    end
    done = true
    if proc then
      proc:kill(15)
    end
    cb(err, text, meta)
  end

  st.send = function(msg)
    if proc and not done then
      proc:write(M._frame(msg))
    end
  end
  st.finish = function(text, meta)
    conclude(nil, text, meta)
  end
  st.fail = function(err)
    conclude(err)
  end

  local reader = M._line_reader(function(line)
    local msg = M._decode(line)
    if msg then
      M._handle(st, msg)
    end
  end)

  local ok, err_or_proc = pcall(vim.system, cmd, {
    stdin = true,
    stdout = function(err, chunk)
      if not err then
        reader(chunk)
      end
    end,
    stderr = function(_, chunk)
      if chunk then
        stderr_tail = (stderr_tail .. chunk):sub(-512)
      end
    end,
    timeout = opts.timeout_ms,
  }, function(res)
    if done then
      return
    end
    local tail = stderr_tail ~= "" and (": " .. vim.trim(stderr_tail)) or ""
    local why = res.signal == 15 and "timed out or was killed"
      or ("exited with code " .. tostring(res.code))
    conclude(("acp agent %s before completing the prompt%s"):format(why, tail))
  end)
  if not ok then
    cb("failed to spawn acp agent: " .. tostring(err_or_proc))
    return nil
  end
  proc = err_or_proc

  proc:write(M._frame(init))

  return {
    cancel = function()
      if done then
        return
      end
      -- Best-effort polite cancel, then kill. The runner treats post-cancel
      -- silence as acceptable, so we conclude without calling cb.
      if st.session_id then
        st.send({
          jsonrpc = "2.0",
          method = "session/cancel",
          params = { sessionId = st.session_id },
        })
      end
      done = true
      if proc then
        proc:kill(15)
      end
    end,
  }
end

return M
