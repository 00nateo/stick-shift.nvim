---@brief Claude Code CLI adapter: drives the locally installed `claude`
---binary headlessly. One-shot ops use `-p --output-format json` and parse the
---JSON envelope (`result`, `session_id`, `is_error`); the session id is handed
---back in meta so the plan store can persist it and later calls can `--resume`
---for free conversation continuity. The `implement` op is a NATIVE override:
---it runs the CLI as a real agent (`stream-json`, `--permission-mode
---acceptEdits`, cwd = project root) and streams events into the transcript.
---
--- Usage terms (SPEC §10): this adapter runs the USER'S OWN authenticated
--- Claude Code CLI, exactly as they could from a shell - nothing more. Calls
--- happen only in direct response to user actions in the editor; there is no
--- background daemon hammering the CLI. Credentials are entirely the CLI's
--- business: we never embed, read, set, or log auth material or environment
--- variables, and error messages only ever contain process output tails.
---
--- Flags verified against CLI 2.1.208 and re-checked on 2.1.209: -p/--print,
--- --output-format text|json|stream-json, --resume <id>, --append-system-prompt,
--- --include-partial-messages (requires --print + stream-json), --permission-mode,
--- --model, --verbose, and `--tools ""` (empty string) which disables all
--- built-in tools. There is NO --max-turns flag in this version; the empty
--- --tools list is what keeps one-shot generation from entering a tool loop.
local config = require("reins.config")
local events = require("reins.events")
local prompts = require("reins.prompts")

local M = { name = "claude_code" }

---@return table backends.claude_code config
local function bcfg()
  return config.get().backends.claude_code
end

---Last `n` characters of process output, flattened for a one-line error.
---@param s string|nil
---@param n integer|nil default 500
---@return string
local function tail(s, n)
  s = vim.trim(s or "")
  n = n or 500
  if #s > n then
    s = "…" .. s:sub(-n)
  end
  return (s:gsub("%s*\n%s*", " | "))
end

---Flatten to a single line and hard-cap the length (for transcript entries).
---@param s string
---@param n integer
---@return string
local function oneline(s, n)
  s = (s:gsub("%s+", " "))
  s = vim.trim(s)
  if #s > n then
    s = s:sub(1, n) .. "…"
  end
  return s
end

---@return boolean ok, string|nil msg
function M.available()
  local bin = bcfg().bin or "claude"
  if vim.fn.executable(bin) == 1 then
    -- Deliberately no `claude --version` spawn here: available() must stay
    -- cheap (health.lua runs the version check).
    return true, ("claude CLI executable found (%s)"):format(bin)
  end
  return false, ("claude CLI not found (backends.claude_code.bin = %q)"):format(bin)
end

---Map role aliases to concrete CLI model names. `frontier` may resolve to nil,
---which means "omit --model and use the CLI's configured default".
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

---Shared argv prefix: model / session resume / user extra_args.
---@param argv string[]
---@param model string|nil
---@param session string|nil
---@return string[]
local function finish_argv(argv, model, session)
  if model then
    vim.list_extend(argv, { "--model", model })
  end
  if session then
    vim.list_extend(argv, { "--resume", session })
  end
  vim.list_extend(argv, bcfg().extra_args or {})
  return argv
end

---One-shot text generation through the JSON envelope.
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
  -- `--tools ""` disables all built-in tools: pure text generation, no tool
  -- loop, no file access. The JSON contract lives in opts.system/opts.prompt;
  -- the CLI has no server-side JSON mode (opts.json needs no extra flag).
  local argv = finish_argv({
    c.bin,
    "-p",
    "--output-format",
    "json",
    "--append-system-prompt",
    opts.system,
    "--tools",
    "",
  }, opts.model, opts.session)

  local cancelled = false
  local spawned, sysobj = pcall(vim.system, argv, {
    stdin = opts.prompt,
    cwd = opts.root,
    text = true,
    timeout = opts.timeout_ms,
  }, function(res)
    -- Runner reschedules onto the main loop; call cb directly.
    if cancelled then
      return cb("cancelled")
    end
    if res.code ~= 0 then
      if res.signal == 15 then
        return cb(("claude was terminated (timeout after %dms?)"):format(opts.timeout_ms or 0))
      end
      local msg = tail(res.stderr)
      if msg == "" then
        msg = tail(res.stdout)
      end
      return cb(("claude exited with code %d: %s"):format(res.code, msg))
    end
    local okj, env = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
    if not okj or type(env) ~= "table" then
      return cb("could not parse claude JSON envelope: " .. tail(res.stdout, 200))
    end
    if env.is_error then
      return cb(
        ("claude reported an error (%s): %s"):format(tostring(env.subtype), tail(tostring(env.result)))
      )
    end
    cb(nil, env.result, { session_id = env.session_id })
  end)
  if not spawned then
    cb("failed to spawn claude: " .. tostring(sysobj))
    return nil
  end
  return {
    cancel = function()
      cancelled = true
      pcall(sysobj.kill, sysobj, 15)
    end,
  }
end

---Compact one-line transcript summary of a tool_use content block.
---@param block table
---@return string
local function summarize_tool(block)
  local input = type(block.input) == "table" and block.input or {}
  local target = input.file_path or input.path or input.pattern or input.command or input.url
  local s = "→ tool " .. tostring(block.name)
  if target then
    s = s .. ": " .. tostring(target)
  end
  return oneline(s, 120)
end

---NATIVE override for the `implement` op: the CLI runs as a real agent with
---edit permissions inside ctx.root. Stream-json events are summarized into the
---transcript; the final "result" event becomes the op result. Native overrides
---bypass the runner's schema validation, so the `{ text = ... }` result shape
---is produced here.
---@param ctx table lifecycle ctx: root, step, plan, context, session, model, timeout_ms
---@param cb fun(err: string|nil, result: { text: string }|nil, meta: table|nil)
---@return { cancel: fun() }|nil handle
function M.implement(_, ctx, cb)
  local c = bcfg()
  local ok, why = M.available()
  if not ok then
    cb(why)
    return nil
  end
  -- Replicate the runner's template_vars minimally (it is local to
  -- backend/init.lua); the implement templates use exactly these vars.
  local autonomy = require("reins.autonomy")
  local sys, user = prompts.render("implement", {
    root = ctx.root or "",
    context = ctx.context or "",
    step_json = ctx.step and vim.json.encode(ctx.step) or "",
    plan_json = ctx.plan and vim.json.encode(ctx.plan) or "",
    level = autonomy.level(),
    level_name = autonomy.name(),
  })
  local argv = finish_argv({
    c.bin,
    "-p",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--permission-mode",
    "acceptEdits",
    "--append-system-prompt",
    sys,
  }, ctx.model, ctx.session)

  events.emit("transcript", { kind = "request", op = "implement", text = user })

  local cancelled = false
  ---@type { text: string, session_id: string|nil, is_error: boolean, subtype: string|nil }|nil
  local final = nil
  local pending = ""

  ---Emit a transcript entry from a fast-event context safely.
  ---@param kind "event"|"response"
  ---@param text string
  local function say(kind, text)
    vim.schedule(function()
      events.emit("transcript", { kind = kind, op = "implement", text = text })
    end)
  end

  ---@param line string one complete stream-json line
  local function handle_line(line)
    if vim.trim(line) == "" then
      return
    end
    local okj, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not okj or type(ev) ~= "table" then
      return
    end
    if ev.type == "assistant" and type(ev.message) == "table" then
      -- Complete assistant messages; partial "stream_event" deltas are skipped
      -- deliberately (the full message follows and the transcript stays terse).
      for _, block in ipairs(ev.message.content or {}) do
        if block.type == "text" and type(block.text) == "string" and vim.trim(block.text) ~= "" then
          say("event", oneline(block.text, 120))
        elseif block.type == "tool_use" then
          say("event", summarize_tool(block))
        end
      end
    elseif ev.type == "result" then
      final = {
        text = type(ev.result) == "string" and ev.result or vim.json.encode(ev.result or vim.empty_dict()),
        session_id = ev.session_id,
        is_error = ev.is_error and true or false,
        subtype = ev.subtype,
      }
    end
  end

  local spawned, sysobj = pcall(vim.system, argv, {
    stdin = user,
    cwd = ctx.root, -- the agent edits files here
    text = true,
    timeout = ctx.timeout_ms,
    stdout = function(_, data)
      -- Fast event; reassemble partial chunks into complete lines.
      if not data then
        return
      end
      pending = pending .. data
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
        handle_line(line)
      end
    end,
  }, function(res)
    if cancelled then
      return cb("cancelled")
    end
    if pending ~= "" then
      handle_line(pending)
      pending = ""
    end
    if final and not final.is_error then
      say("response", final.text)
      return cb(nil, { text = final.text }, { session_id = final.session_id })
    end
    if final then
      return cb(
        ("claude implement failed (%s): %s"):format(tostring(final.subtype), oneline(final.text, 300))
      )
    end
    if res.signal == 15 then
      return cb(("claude implement was terminated (timeout after %dms?)"):format(ctx.timeout_ms or 0))
    end
    if res.code ~= 0 then
      return cb(("claude exited with code %d: %s"):format(res.code, tail(res.stderr)))
    end
    cb("claude stream ended without a result event")
  end)
  if not spawned then
    cb("failed to spawn claude: " .. tostring(sysobj))
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
