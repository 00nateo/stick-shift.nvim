-- Offline tests for lua/stick-shift/config.lua: defaults, deep-merge semantics,
-- declarative validation, autonomy clamping, and repeated-setup reset.
local config = require("stick-shift.config")

-- Snapshot of M.current as it exists on a fresh require (runner purges stick-shift.*
-- before each file), taken before any test can call setup().
local pristine = vim.deepcopy(config.get())

local function eq(got, want, label)
  if not vim.deep_equal(got, want) then
    error(
      ("%s: expected %s, got %s"):format(label, vim.inspect(want), vim.inspect(got)),
      2
    )
  end
end

---Assert exactly one problem string contains `fragment` (plain match).
local function has_problem(problems, fragment)
  for _, p in ipairs(problems) do
    if p:find(fragment, 1, true) then
      return
    end
  end
  error(
    ("no problem containing %q in %s"):format(fragment, vim.inspect(problems)),
    2
  )
end

local T = {}

T["defaults: fresh module state deep-equals defaults"] = function()
  eq(pristine, config.defaults, "pristine current vs defaults")
  -- Pin a few load-bearing default leaves explicitly.
  eq(config.defaults.autonomy, 2, "defaults.autonomy")
  eq(config.defaults.backend, "claude_code", "defaults.backend")
  eq(config.defaults.ui.layout, "right", "defaults.ui.layout")
  eq(config.defaults.ui.width, 48, "defaults.ui.width")
  eq(config.defaults.ui.height, 14, "defaults.ui.height")
  eq(config.defaults.ui.transcript, nil, "defaults.ui.transcript")
  eq(config.defaults.plan.visibility, "current-only", "defaults.plan.visibility")
  eq(config.defaults.completion.level, "line", "defaults.completion.level")
  eq(config.defaults.completion.force, false, "defaults.completion.force")
  eq(config.defaults.hint.trigger, "manual", "defaults.hint.trigger")
  eq(config.defaults.models.plan, "frontier", "defaults.models.plan")
  eq(config.defaults.models.ghost, "local", "defaults.models.ghost")
end

T["defaults: setup() with no args returns defaults untouched"] = function()
  local got = config.setup()
  eq(got, config.defaults, "setup() result vs defaults")
  assert(got ~= config.defaults, "setup() must return a copy, not the defaults table itself")
  assert(config.get() == got, "get() must return the exact table setup() returned")
  local got2 = config.setup({})
  eq(got2, config.defaults, "setup({}) result vs defaults")
end

T["merge: scalar and nested overrides apply without clobbering siblings"] = function()
  local c = config.setup({
    autonomy = 3,
    ui = { width = 60 },
    completion = { debounce_ms = 0 },
  })
  eq(c.autonomy, 3, "autonomy override")
  eq(c.ui.width, 60, "ui.width override")
  eq(c.ui.height, 14, "ui.height sibling kept")
  eq(c.ui.layout, "right", "ui.layout sibling kept")
  eq(c.completion.debounce_ms, 0, "completion.debounce_ms override")
  eq(c.completion.level, "line", "completion.level sibling kept")
  eq(c.hint.enabled, true, "unrelated section untouched")
end

T["merge: deep backend override keeps other adapters intact"] = function()
  local c = config.setup({
    backends = { claude_code = { extra_args = { "--verbose" } } },
  })
  eq(c.backends.claude_code.extra_args, { "--verbose" }, "extra_args replaced")
  eq(c.backends.claude_code.bin, "claude", "sibling leaf kept")
  eq(c.backends.claude_code.model_local, "haiku", "sibling leaf kept")
  eq(c.backends.ollama.host, "http://localhost:11434", "other adapter untouched")
end

T["merge: false overrides a string default (keymaps)"] = function()
  local c = config.setup({ keymaps = { verify = false } })
  eq(c.keymaps.verify, false, "keymaps.verify disabled")
  eq(c.keymaps.toggle_panel, "<leader>ss", "other keymaps kept")
end

T["merge: any-model table replaces string alias wholesale"] = function()
  local pin = { backend = "ollama", model = "qwen3-coder:30b" }
  local c = config.setup({ models = { plan = pin } })
  eq(c.models.plan, pin, "models.plan pinned table")
  assert(c.models.plan ~= pin, "merged value must be a deep copy of user input")
  eq(c.models.ghost, "local", "models.ghost kept")
  eq(c.models.verify, "frontier", "models.verify kept")
end

T["merge: defaults table is never mutated by setup"] = function()
  config.setup({
    autonomy = 4,
    ui = { width = 99 },
    keymaps = { verify = false },
    models = { plan = { backend = "mock", model = "m" } },
  })
  eq(config.defaults.autonomy, 2, "defaults.autonomy intact")
  eq(config.defaults.ui.width, 48, "defaults.ui.width intact")
  eq(config.defaults.keymaps.verify, "<leader>sv", "defaults.keymaps.verify intact")
  eq(config.defaults.models.plan, "frontier", "defaults.models.plan intact")
end

T["validate: clean config yields no problems"] = function()
  eq(config.validate({}), {}, "empty user table")
  local problems = config.validate({
    autonomy = 0,
    backend = "mock",
    ui = { layout = "float", transcript = "summary", width = 10, height = 3 },
    plan = { visibility = "full" },
    completion = { level = "off", accept_key = "<C-y>", debounce_ms = 0, force = true },
    hint = { enabled = false, trigger = "auto", max_len = 20 },
    verify = { test_command = "make test", auto_detect_tests = false, timeout_ms = 1000 },
    git = { tag_commits = true, checkpoint = false },
    backends = { anything = { goes = true } },
    keymaps = { verify = false },
  })
  eq(problems, {}, "fully-specified valid config")
end

T["validate: unknown keys are flagged with their path"] = function()
  local problems = config.validate({ bogus = 1, ui = { mystery = true } })
  eq(#problems, 2, "problem count")
  has_problem(problems, "unknown option `bogus`")
  has_problem(problems, "unknown option `ui.mystery`")
end

T["validate: type, enum, and range violations are all reported"] = function()
  local problems = config.validate({
    autonomy = 9,
    ui = { width = "wide", layout = "diagonal", height = 2 },
    hint = { max_len = 5 },
    completion = { debounce_ms = -1 },
    git = { tag_commits = "yes" },
  })
  eq(#problems, 7, "problem count: " .. vim.inspect(problems))
  has_problem(problems, "`autonomy` must be <= 4")
  has_problem(problems, "`ui.width` must be a number, got string")
  has_problem(problems, "`ui.layout` must be one of: left, top, right, bottom, float")
  has_problem(problems, "`ui.height` must be >= 3")
  has_problem(problems, "`hint.max_len` must be >= 20")
  has_problem(problems, "`completion.debounce_ms` must be >= 0")
  has_problem(problems, "`git.tag_commits` must be a boolean, got string")
end

T["validate: any-model accepts string or backend/model table only"] = function()
  eq(config.validate({ models = { plan = "sonnet" } }), {}, "string alias ok")
  eq(config.validate({ models = { plan = { backend = "ollama" } } }), {}, "backend-only table ok")
  eq(config.validate({ models = { plan = { model = "m" } } }), {}, "model-only table ok")
  local problems = config.validate({ models = { plan = 42, hint = {} } })
  eq(#problems, 2, "both invalid models flagged")
  has_problem(problems, "`models.plan` must be a string or {backend=, model=}")
  has_problem(problems, "`models.hint` must be a string or {backend=, model=}")
end

T["validate: open-tables and nested sections must be tables"] = function()
  has_problem(config.validate({ keymaps = "x" }), "`keymaps` must be a table")
  has_problem(config.validate({ backends = 5 }), "`backends` must be a table")
  has_problem(config.validate({ ui = "compact" }), "`ui` must be a table")
  eq(config.validate({ keymaps = { anything = 123 } }), {}, "open-table contents unchecked")
end

T["validate: nilable leaf still type-checked when present"] = function()
  eq(config.validate({ verify = { test_command = "make test" } }), {}, "string ok")
  has_problem(
    config.validate({ verify = { test_command = 5 } }),
    "`verify.test_command` must be a string, got number"
  )
  has_problem(
    config.validate({ ui = { transcript = "bogus" } }),
    "`ui.transcript` must be one of: full, summary, hidden"
  )
end

T["validate: non-table argument rejected"] = function()
  eq(config.validate("nope"), { "setup() expects a table" }, "string arg")
  eq(config.validate(42), { "setup() expects a table" }, "number arg")
end

T["setup: autonomy is clamped to 0..4 and floored"] = function()
  eq(config.setup({ autonomy = 99 }).autonomy, 4, "clamp high")
  eq(config.setup({ autonomy = -3 }).autonomy, 0, "clamp low")
  eq(config.setup({ autonomy = 2.9 }).autonomy, 2, "floored, not rounded")
  eq(config.setup({ autonomy = "wild" }).autonomy, 2, "non-number falls back to default")
end

T["setup: validation problems are surfaced via vim.notify warnings"] = function()
  local saved = vim.notify
  local seen = {}
  vim.notify = function(msg, level)
    seen[#seen + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(function()
    config.setup({ ui = { layout = "diagonal" }, bogus = 1 })
  end)
  vim.notify = saved
  assert(ok, tostring(err))
  eq(#seen, 2, "one warning per problem: " .. vim.inspect(seen))
  for _, n in ipairs(seen) do
    assert(n.msg:find("[stick-shift] config:", 1, true), "prefixed message, got: " .. n.msg)
    eq(n.level, vim.log.levels.WARN, "warn level")
  end
  local found_enum, found_unknown = false, false
  for _, n in ipairs(seen) do
    found_enum = found_enum or n.msg:find("`ui.layout` must be one of", 1, true) ~= nil
    found_unknown = found_unknown or n.msg:find("unknown option `bogus`", 1, true) ~= nil
  end
  assert(found_enum, "enum problem notified")
  assert(found_unknown, "unknown-key problem notified")
  -- NOTE: apart from autonomy (clamped above), invalid leaves are only warned
  -- about; whether they merge through or fall back is intentionally not pinned
  -- here (the setup() docstring and the code currently disagree).
end

T["setup: non-table user yields plain defaults"] = function()
  local c = config.setup(42)
  eq(c, config.defaults, "defaults returned for non-table setup arg")
end

T["setup: repeated setup resets cleanly to defaults"] = function()
  config.setup({ autonomy = 4, ui = { width = 90, transcript = "full" }, keymaps = { verify = false } })
  eq(config.get().ui.transcript, "full", "override active before reset")
  local c = config.setup({})
  eq(c, config.defaults, "second setup({}) restores defaults exactly")
  eq(c.ui.transcript, nil, "previously-set nilable leaf cleared")
  eq(c.keymaps.verify, "<leader>sv", "previously-disabled keymap restored")
end

T["setup: direct mutation of current is discarded on next setup"] = function()
  config.setup({})
  config.get().ui.width = 999
  config.get().models.plan = "hacked"
  local c = config.setup({})
  eq(c.ui.width, 48, "mutated leaf reset")
  eq(c.models.plan, "frontier", "mutated model reset")
end

T["setup: invalid leaves fall back to defaults instead of persisting"] = function()
  local c = config.setup({
    ui = { layout = "diagonal", width = 5, height = 20 }, -- bad enum, below min, valid
    completion = { level = "sentence" }, -- bad enum
    hint = { max_len = "long" }, -- wrong type
    unknown_top = { whatever = true }, -- unknown key
  })
  eq(c.ui.layout, "right", "bad enum reverts to default")
  eq(c.ui.width, 48, "below-min number reverts to default")
  eq(c.ui.height, 20, "valid sibling in the same table survives")
  eq(c.completion.level, "line", "bad completion level reverts")
  eq(c.hint.max_len, 120, "wrong-typed leaf reverts")
  eq(c.unknown_top, nil, "unknown keys are genuinely ignored, not merged")
end

return T
