-- Offline tests for lua/reins/autonomy.lua: the full 0-4 gating matrix,
-- allows() config interplay, level()/name(), transcript_mode(), plan_editable().
local config = require("reins.config")
local autonomy = require("reins.autonomy")

local function eq(got, want, label)
  if not vim.deep_equal(got, want) then
    error(
      ("%s: expected %s, got %s"):format(label, vim.inspect(want), vim.inspect(got)),
      2
    )
  end
end

-- Every cell of the ladder, asserted below. plan_editable is derived from the
-- level (<= 2), not stored in caps, so it lives alongside for the loop tests.
local EXPECTED = {
  [0] = {
    name = "hint-only",
    completion = false,
    hint_manual = true,
    hint_auto = false,
    panel = false,
    verify = false,
    next = false,
    implement = false,
    agent_free = false,
    transcript_default = "hidden",
    panel_open_default = false,
    plan_editable = true,
  },
  [1] = {
    name = "navigator",
    completion = false,
    hint_manual = true,
    hint_auto = false,
    panel = true,
    verify = true,
    next = true,
    implement = false,
    agent_free = false,
    transcript_default = "hidden",
    panel_open_default = false,
    plan_editable = true,
  },
  [2] = {
    name = "co-pilot",
    completion = true,
    hint_manual = true,
    hint_auto = true,
    panel = true,
    verify = true,
    next = true,
    implement = false,
    agent_free = false,
    transcript_default = "hidden",
    panel_open_default = false,
    plan_editable = true,
  },
  [3] = {
    name = "driver-assist",
    completion = true,
    hint_manual = true,
    hint_auto = true,
    panel = true,
    verify = true,
    next = true,
    implement = true,
    agent_free = false,
    transcript_default = "summary",
    panel_open_default = true,
    plan_editable = false,
  },
  [4] = {
    name = "autopilot",
    completion = true,
    hint_manual = true,
    hint_auto = true,
    panel = true,
    verify = true,
    next = true,
    implement = true,
    agent_free = true,
    transcript_default = "full",
    panel_open_default = true,
    plan_editable = false,
  },
}

-- Fields that must appear in each caps table (EXPECTED minus plan_editable).
local CAP_FIELDS = {
  "name",
  "completion",
  "hint_manual",
  "hint_auto",
  "panel",
  "verify",
  "next",
  "implement",
  "agent_free",
  "transcript_default",
  "panel_open_default",
}

local T = {}

T["caps: full 0-4 gating matrix, every cell"] = function()
  for level = 0, 4 do
    local caps = autonomy.caps(level)
    assert(type(caps) == "table", "caps(" .. level .. ") is a table")
    for _, field in ipairs(CAP_FIELDS) do
      eq(caps[field], EXPECTED[level][field], ("caps(%d).%s"):format(level, field))
    end
    -- No untested capability may sneak into the ladder.
    local n = 0
    for _ in pairs(caps) do
      n = n + 1
    end
    eq(n, #CAP_FIELDS, ("caps(%d) field count"):format(level))
  end
end

T["caps: nil argument means the active level"] = function()
  for level = 0, 4 do
    config.setup({ autonomy = level })
    assert(autonomy.caps() == autonomy.LEVELS[level], "caps() tracks active level " .. level)
    assert(autonomy.caps(nil) == autonomy.LEVELS[level], "caps(nil) tracks active level " .. level)
  end
end

T["caps: out-of-range level yields nil"] = function()
  eq(autonomy.caps(5), nil, "caps(5)")
  eq(autonomy.caps(-1), nil, "caps(-1)")
end

T["allows: matches the matrix at every level (defaults + auto hint trigger)"] = function()
  for level = 0, 4 do
    -- trigger="auto" so allows("hint_auto") reduces to the caps cell; all other
    -- config stays at defaults (completion.level="line", force=false, hint on).
    config.setup({ autonomy = level, hint = { trigger = "auto" } })
    local exp = EXPECTED[level]
    for _, feature in ipairs({
      "completion",
      "hint_manual",
      "hint_auto",
      "panel",
      "verify",
      "next",
      "implement",
      "agent_free",
    }) do
      eq(autonomy.allows(feature), exp[feature], ("allows(%q) at level %d"):format(feature, level))
    end
  end
end

T["allows: unknown capability is exactly false"] = function()
  config.setup({ autonomy = 4 })
  eq(autonomy.allows("teleport"), false, "allows('teleport') at max autonomy")
  config.setup({ autonomy = 0 })
  eq(autonomy.allows("teleport"), false, "allows('teleport') at min autonomy")
end

T["allows: completion honors level=off and force"] = function()
  config.setup({ autonomy = 0 })
  eq(autonomy.allows("completion"), false, "off the ladder at level 0")
  config.setup({ autonomy = 0, completion = { force = true } })
  eq(autonomy.allows("completion"), true, "force overrides the ladder")
  config.setup({ autonomy = 4, completion = { level = "off" } })
  eq(autonomy.allows("completion"), false, "level=off wins at autonomy 4")
  config.setup({ autonomy = 0, completion = { level = "off", force = true } })
  eq(autonomy.allows("completion"), false, "level=off wins even over force")
end

T["allows: hint gating honors enabled and trigger"] = function()
  config.setup({ autonomy = 2 })
  eq(autonomy.allows("hint_auto"), false, "default trigger=manual blocks hint_auto")
  eq(autonomy.allows("hint_manual"), true, "hint_manual on by default at level 2")
  config.setup({ autonomy = 2, hint = { trigger = "auto" } })
  eq(autonomy.allows("hint_auto"), true, "trigger=auto enables hint_auto at level 2")
  config.setup({ autonomy = 2, hint = { enabled = false, trigger = "auto" } })
  eq(autonomy.allows("hint_auto"), false, "enabled=false blocks hint_auto")
  eq(autonomy.allows("hint_manual"), false, "enabled=false blocks hint_manual")
  config.setup({ autonomy = 1, hint = { trigger = "auto" } })
  eq(autonomy.allows("hint_auto"), false, "caps gate still applies below level 2")
end

T["level and name track the configured autonomy"] = function()
  for level = 0, 4 do
    config.setup({ autonomy = level })
    eq(autonomy.level(), level, "level()")
    eq(autonomy.name(), EXPECTED[level].name, "name() at level " .. level)
  end
  -- Explicit-argument form must not depend on the active level.
  config.setup({ autonomy = 2 })
  for level = 0, 4 do
    eq(autonomy.name(level), EXPECTED[level].name, "name(" .. level .. ")")
  end
end

T["transcript_mode: explicit config wins, else level default"] = function()
  for level = 0, 4 do
    config.setup({ autonomy = level })
    eq(
      autonomy.transcript_mode(),
      EXPECTED[level].transcript_default,
      "level default at " .. level
    )
  end
  config.setup({ autonomy = 0, ui = { transcript = "full" } })
  eq(autonomy.transcript_mode(), "full", "explicit full overrides hidden default")
  config.setup({ autonomy = 4, ui = { transcript = "hidden" } })
  eq(autonomy.transcript_mode(), "hidden", "explicit hidden overrides full default")
end

T["plan_editable: human may rewrite the plan only at levels <= 2"] = function()
  for level = 0, 4 do
    config.setup({ autonomy = level })
    eq(autonomy.plan_editable(), EXPECTED[level].plan_editable, "plan_editable at " .. level)
  end
end

return T
