-- Offline tests for lua/stick-shift/util.lua: deep_merge, json, paths, fs helpers,
-- truncate, debounce, notify wrappers. See tests/run.lua for the contract.
local T = {}

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function git_init(dir)
  vim.system({ "git", "init", dir }):wait()
  vim.system({ "git", "-C", dir, "config", "user.email", "test@example.com" }):wait()
  vim.system({ "git", "-C", dir, "config", "user.name", "StickShift Test" }):wait()
end

-- deep_merge -----------------------------------------------------------------

T["deep_merge: maps merge recursively"] = function()
  local util = require("stick-shift.util")
  local base = { ui = { width = 80, border = "single" }, backend = "mock" }
  local out = util.deep_merge(base, { ui = { width = 120 } })
  assert(out.ui.width == 120, "override wins: " .. tostring(out.ui.width))
  assert(out.ui.border == "single", "untouched sibling key survives")
  assert(out.backend == "mock", "untouched top-level key survives")
end

T["deep_merge: lists replace wholesale, no index merge"] = function()
  local util = require("stick-shift.util")
  local base = { markers = { "a", "b", "c" } }
  local out = util.deep_merge(base, { markers = { "z" } })
  assert(#out.markers == 1, "list replaced, got #" .. #out.markers)
  assert(out.markers[1] == "z")
end

T["deep_merge: scalars replace and new keys are added"] = function()
  local util = require("stick-shift.util")
  local out = util.deep_merge({ n = 1, s = "old" }, { n = 2, extra = true })
  assert(out.n == 2)
  assert(out.s == "old")
  assert(out.extra == true)
end

T["deep_merge: map override replaces a scalar base value"] = function()
  local util = require("stick-shift.util")
  local out = util.deep_merge({ opt = false }, { opt = { level = 3 } })
  assert(type(out.opt) == "table" and out.opt.level == 3)
end

T["deep_merge: nil override returns an independent copy of base"] = function()
  local util = require("stick-shift.util")
  local base = { nested = { x = 1 } }
  local out = util.deep_merge(base, nil)
  assert(out.nested.x == 1)
  out.nested.x = 99
  assert(base.nested.x == 1, "result must not alias base")
end

T["deep_merge: does not mutate base or alias override tables"] = function()
  local util = require("stick-shift.util")
  local base = { m = { a = 1 } }
  local override = { m = { b = 2 }, list = { 1, 2 } }
  local out = util.deep_merge(base, override)
  assert(base.m.b == nil, "base must be untouched")
  out.list[1] = 42
  assert(override.list[1] == 1, "override tables must be deep-copied")
  assert(out.m.a == 1 and out.m.b == 2)
end

-- json -----------------------------------------------------------------------

T["decode_json_loose: round-trips vim.json.encode output"] = function()
  local util = require("stick-shift.util")
  local value = {
    goal = "ship it",
    steps = { { id = "s1", rank = 1 }, { id = "s2", rank = 2 } },
    done = false,
    score = 0.9,
  }
  local ok, decoded = util.decode_json_loose(vim.json.encode(value))
  assert(ok, tostring(decoded))
  assert(vim.deep_equal(decoded, value), vim.inspect(decoded))
end

T["decode_json_loose: strips markdown fences"] = function()
  local util = require("stick-shift.util")
  local ok, val = util.decode_json_loose('```json\n{"a": 1, "b": [2, 3]}\n```')
  assert(ok, tostring(val))
  assert(val.a == 1 and val.b[2] == 3)
end

T["decode_json_loose: extracts object from surrounding prose"] = function()
  local util = require("stick-shift.util")
  local raw = 'Sure! Here is the plan: {"steps": [{"id": "s1"}]} Hope that helps.'
  local ok, val = util.decode_json_loose(raw)
  assert(ok, tostring(val))
  assert(val.steps[1].id == "s1")
end

T["decode_json_loose: json null becomes nil (luanil)"] = function()
  local util = require("stick-shift.util")
  local ok, val = util.decode_json_loose('{"a": null, "b": 1}')
  assert(ok, tostring(val))
  assert(val.a == nil and val.b == 1)
end

T["decode_json_loose: top-level array decodes"] = function()
  local util = require("stick-shift.util")
  local ok, val = util.decode_json_loose('[1, 2, {"k": "v"}]')
  assert(ok, tostring(val))
  assert(val[3].k == "v")
end

T["decode_json_loose: malformed input fails with invalid JSON message"] = function()
  local util = require("stick-shift.util")
  local ok, err = util.decode_json_loose("definitely not json { broken")
  assert(not ok)
  assert(type(err) == "string" and err:find("invalid JSON", 1, true), tostring(err))
end

T["decode_json_loose: empty and nil input rejected"] = function()
  local util = require("stick-shift.util")
  local ok, err = util.decode_json_loose("")
  assert(not ok and err == "empty response", tostring(err))
  ok, err = util.decode_json_loose(nil)
  assert(not ok and err == "empty response", tostring(err))
end

T["decode_json_loose: scalar JSON is rejected (must be a table)"] = function()
  local util = require("stick-shift.util")
  local ok = util.decode_json_loose("5")
  assert(not ok, "bare number is not an acceptable payload")
end

-- fs + path helpers ----------------------------------------------------------

T["write_file/read_file round trip; exists; ensure_dir"] = function()
  local util = require("stick-shift.util")
  local dir = tmpdir()
  local sub = dir .. "/nested/deeper"
  util.ensure_dir(sub)
  assert(util.exists(sub), "ensure_dir creates parents")
  local path = sub .. "/note.txt"
  assert(not util.exists(path))
  local ok, err = util.write_file(path, "line1\nline2")
  assert(ok, tostring(err))
  assert(util.exists(path))
  local content, rerr = util.read_file(path)
  assert(content == "line1\nline2", tostring(rerr))
end

T["read_file: missing file returns nil plus error"] = function()
  local util = require("stick-shift.util")
  local path = tmpdir() .. "/no-such-file"
  local content, err = util.read_file(path)
  assert(content == nil)
  assert(type(err) == "string" and err:find("cannot open", 1, true), tostring(err))
end

T["write_file: unwritable path returns false plus error"] = function()
  local util = require("stick-shift.util")
  local ok, err = util.write_file(tmpdir() .. "/missing-dir/f.txt", "x")
  assert(ok == false)
  assert(err ~= nil)
end

T["plugin_root points at the stick-shift.nvim checkout"] = function()
  local util = require("stick-shift.util")
  local root = util.plugin_root()
  assert(util.exists(root .. "/lua/stick-shift/util.lua"), "root=" .. tostring(root))
  assert(util.exists(root .. "/tests/run.lua"))
end

T["project_root: finds enclosing git repo from nested file"] = function()
  local util = require("stick-shift.util")
  local dir = tmpdir()
  git_init(dir)
  vim.fn.mkdir(dir .. "/a/b", "p")
  util.write_file(dir .. "/a/b/file.lua", "return {}")
  local got = util.project_root(dir .. "/a/b/file.lua")
  assert(got == dir, ("expected %s, got %s"):format(dir, tostring(got)))
end

T["project_root: nearest .stick-shift marker beats outer .git"] = function()
  local util = require("stick-shift.util")
  local dir = tmpdir()
  git_init(dir)
  vim.fn.mkdir(dir .. "/sub/.stick-shift", "p")
  vim.fn.mkdir(dir .. "/sub/x", "p")
  util.write_file(dir .. "/sub/x/f.lua", "return {}")
  local got = util.project_root(dir .. "/sub/x/f.lua")
  assert(got == dir .. "/sub", "got " .. tostring(got))
end

T["project_root: falls back to cwd when no marker found"] = function()
  local util = require("stick-shift.util")
  local dir = tmpdir()
  util.write_file(dir .. "/orphan.lua", "return {}")
  local got = util.project_root(dir .. "/orphan.lua")
  assert(got == vim.uv.cwd(), "got " .. tostring(got))
end

T["context_files: gathers AGENT/AGENTS/CLAUDE md, nearest last"] = function()
  local util = require("stick-shift.util")
  local outer = tmpdir()
  local proj = outer .. "/proj"
  vim.fn.mkdir(proj, "p")
  util.write_file(outer .. "/CLAUDE.md", "OUTER-RULES")
  util.write_file(proj .. "/AGENTS.md", "INNER-RULES")
  local ctx = util.context_files(proj)
  local at_outer = ctx:find("OUTER-RULES", 1, true)
  local at_inner = ctx:find("INNER-RULES", 1, true)
  assert(at_outer, "outer file collected")
  assert(at_inner, "inner file collected")
  assert(at_outer < at_inner, "nearest file must come last so it wins")
end

T["context_files: respects byte cap via truncate"] = function()
  local util = require("stick-shift.util")
  local proj = tmpdir()
  util.write_file(proj .. "/AGENT.md", string.rep("x", 500))
  local ctx = util.context_files(proj, 64)
  assert(#ctx > 0)
  assert(ctx:find("truncated", 1, true), "cap should trigger the truncation marker")
end

T["context_files: empty string when no context files exist"] = function()
  local util = require("stick-shift.util")
  assert(util.context_files(tmpdir()) == "")
end

-- truncate / now_iso ---------------------------------------------------------

T["truncate: at or under limit is unchanged, over gets marker"] = function()
  local util = require("stick-shift.util")
  assert(util.truncate("abc", 3) == "abc")
  assert(util.truncate("abc", 10) == "abc")
  local out = util.truncate("abcdefghij", 4)
  assert(out:sub(1, 4) == "abcd", out)
  assert(out:find("truncated 6 bytes", 1, true), out)
end

T["now_iso: UTC ISO-8601 shape"] = function()
  local util = require("stick-shift.util")
  local ts = util.now_iso()
  assert(ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), tostring(ts))
end

-- notify wrappers ------------------------------------------------------------

T["notify/warn/error: prefix and log levels"] = function()
  local util = require("stick-shift.util")
  local orig = vim.notify
  local captured = {}
  vim.notify = function(msg, level)
    captured[#captured + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(function()
    util.notify("hello")
    util.notify("custom", vim.log.levels.DEBUG)
    util.warn("careful")
    util.error("boom")
  end)
  vim.notify = orig
  assert(ok, tostring(err))
  assert(#captured == 4)
  assert(captured[1].msg == "[stick-shift] hello" and captured[1].level == vim.log.levels.INFO)
  assert(captured[2].level == vim.log.levels.DEBUG)
  assert(captured[3].msg == "[stick-shift] careful" and captured[3].level == vim.log.levels.WARN)
  assert(captured[4].msg == "[stick-shift] boom" and captured[4].level == vim.log.levels.ERROR)
end

-- debounce -------------------------------------------------------------------

T["debounce: trailing edge, fires once with last args"] = function()
  local util = require("stick-shift.util")
  local calls = {}
  local wrapped = util.debounce(20, function(a, b)
    calls[#calls + 1] = { a, b }
  end)
  wrapped(1, "first")
  wrapped(2, "second")
  wrapped(3, "last")
  vim.wait(2000, function()
    return #calls > 0
  end)
  assert(#calls == 1, "expected exactly one call, got " .. #calls)
  assert(calls[1][1] == 3 and calls[1][2] == "last", vim.inspect(calls))
  -- drain a while longer: no late duplicate fire
  vim.wait(80, function()
    return #calls > 1
  end)
  assert(#calls == 1, "debounced fn fired again unexpectedly")
end

T["debounce: cancel prevents the pending call"] = function()
  local util = require("stick-shift.util")
  local fired = false
  local wrapped, cancel = util.debounce(20, function()
    fired = true
  end)
  wrapped()
  cancel()
  vim.wait(120, function()
    return fired
  end)
  assert(not fired, "cancel must stop the pending timer")
  -- the wrapper is reusable after cancel
  wrapped()
  vim.wait(2000, function()
    return fired
  end)
  assert(fired, "wrapper should work again after cancel")
end

T["islist re-export distinguishes lists from maps"] = function()
  local util = require("stick-shift.util")
  assert(util.islist({ 1, 2, 3 }) == true)
  assert(util.islist({ a = 1 }) == false)
end

T["debounce: cancel suppresses a call already past its timer"] = function()
  local util = require("stick-shift.util")
  local ran = 0
  local wrapped, cancel = util.debounce(1, function()
    ran = ran + 1
  end)
  wrapped()
  -- Second 1ms uv timer, started after the debounce timer: with equal due
  -- times libuv runs them in start order, so this cancel() lands right after
  -- the debounce timer has vim.schedule()d its trailing call - exactly the
  -- window where the old implementation could no longer stop it.
  local killer = vim.uv.new_timer()
  killer:start(1, 0, function()
    killer:stop()
    if not killer:is_closing() then
      killer:close()
    end
    cancel()
  end)
  vim.wait(100, function()
    return false
  end, 5)
  assert(ran == 0, "cancel() must stop the trailing call even after the timer fired (ran=" .. ran .. ")")
end

return T
