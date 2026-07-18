---@brief :checkhealth stick-shift - environment and backend diagnostics.
---Every probe is wrapped so a broken backend or missing setup() can never
---crash the health report itself.
local M = {}

---Run one probe; report an internal failure as a warning instead of erroring.
---@param health table vim.health
---@param fn function
local function probe(health, fn)
  local ok, err = pcall(fn)
  if not ok then
    health.warn("health probe failed internally: " .. tostring(err))
  end
end

---Short synchronous command run for version/reachability probes.
---@param cmd string[]
---@param timeout_ms integer|nil
---@return boolean ok, string output (stdout, trimmed)
local function run(cmd, timeout_ms)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, timeout = timeout_ms or 5000 }):wait()
  end)
  if not ok then
    return false, tostring(res)
  end
  return res.code == 0, vim.trim(res.stdout or "")
end

function M.check()
  local health = vim.health
  local util = require("stick-shift.util")

  -- ------------------------------------------------------------ neovim ----
  health.start("stick-shift: environment")
  probe(health, function()
    if vim.fn.has("nvim-0.11") == 1 then
      health.ok("Neovim " .. tostring(vim.version()) .. " (>= 0.11)")
      if vim.fn.has("nvim-0.12") == 1 then
        health.info("Neovim 0.12+ detected: native vim.lsp.inline_completion may be available (stick-shift currently uses the 0.11 extmark path)")
      end
    else
      health.error("Neovim >= 0.11 is required; found " .. tostring(vim.version()))
    end
  end)

  probe(health, function()
    local git = require("stick-shift.git")
    if git.available() then
      local ok, out = run({ "git", "--version" })
      health.ok(ok and out or "git found (version query failed)")
    else
      health.warn("git not found: checkpoints, scoped verify diffs, and :StickShiftRevert are unavailable")
    end
  end)

  probe(health, function()
    local prompts = require("stick-shift.prompts")
    local dir = util.plugin_root() .. "/prompts/" .. prompts.VERSION
    if util.exists(dir) then
      health.ok("prompt templates present: " .. dir)
    else
      health.error("prompt templates missing: " .. dir .. " (broken install?)")
    end
  end)

  -- ----------------------------------------------------------- backends ----
  health.start("stick-shift: backends")
  probe(health, function()
    local backend = require("stick-shift.backend")
    local names = backend.list()
    if #names == 0 then
      health.warn("no backends registered - has require('stick-shift').setup() been called?")
      return
    end
    local _, active_name = backend.active()
    if not active_name then
      health.warn("no active backend selected - has require('stick-shift').setup() been called?")
    end
    for _, name in ipairs(names) do
      -- backend exposes no public per-name getter; read the registry directly
      -- (health is diagnostic code and may look under the hood).
      local adapter = backend._adapters and backend._adapters[name] or nil
      local tag = (name == active_name) and (name .. " (active)") or name
      if adapter and type(adapter.available) == "function" then
        local av_ok, avail, msg = pcall(adapter.available)
        if not av_ok then
          health.warn(tag .. ": available() errored: " .. tostring(avail))
        elseif avail then
          health.ok(tag .. (msg and (": " .. msg) or ": available"))
        else
          local report = (name == active_name) and health.warn or health.info
          report(tag .. ": unavailable" .. (msg and (" - " .. msg) or ""))
        end
      else
        health.warn(tag .. ": adapter has no available() check")
      end
    end

    -- Deeper probes only for backends that are actually registered.
    if vim.tbl_contains(names, "ollama") then
      local host = require("stick-shift.config").get().backends.ollama.host
      if vim.fn.executable("curl") ~= 1 then
        health.warn("ollama: curl not found; cannot reach " .. tostring(host))
      else
        local ok = run({ "curl", "-sf", "--max-time", "2", host .. "/api/tags" }, 4000)
        if ok then
          health.ok("ollama reachable at " .. host)
        else
          health.warn("ollama not reachable at " .. host .. "/api/tags (is `ollama serve` running?)")
        end
      end
    end
    if vim.tbl_contains(names, "local_mac") then
      local url = require("stick-shift.config").get().backends.local_mac.url
      if type(url) == "string" and url ~= "" and vim.fn.executable("curl") == 1 then
        local ok = run({ "curl", "-sf", "-o", "/dev/null", "--max-time", "2", url .. "/models" }, 4000)
        if ok then
          health.ok("local_mac: OpenAI-compatible server reachable at " .. url)
        else
          health.info(
            "local_mac: no server reachable at " .. url .. "/models (start MLX/llama.cpp/LM Studio to use it)"
          )
        end
      end
    end
    if vim.tbl_contains(names, "claude_code") then
      local bin = require("stick-shift.config").get().backends.claude_code.bin or "claude"
      if vim.fn.executable(bin) == 1 then
        local ok, out = run({ bin, "--version" })
        health.ok(("claude_code: %s (%s)"):format(bin, ok and out or "version query failed"))
      else
        health.warn("claude_code: `" .. bin .. "` not on PATH")
      end
    end
  end)

  -- ------------------------------------------------------------ project ----
  health.start("stick-shift: project")
  probe(health, function()
    local root = util.project_root()
    health.info("project root: " .. root)

    local lifecycle = require("stick-shift.plan.lifecycle")
    local cmd = lifecycle.detect_test_command(root)
    if cmd then
      health.ok("verify test command: " .. cmd)
    else
      health.info("no test command detected (verify will report tests as not run; set verify.test_command)")
    end

    local store = require("stick-shift.plan.store")
    local plan = store.load(root)
    if plan then
      health.ok(("living plan present: %d step(s), goal: %s"):format(
        #(plan.steps or {}),
        util.truncate(plan.goal or "", 60)
      ))
    else
      health.info("no living plan yet - start one with :StickShiftGoal")
    end
  end)
end

return M
