---@brief Transcript ring buffer for the panel. Stores backend
---request/response/event entries (cap 200) and renders them according to the
---EFFECTIVE transcript mode (stick-shift.autonomy.transcript_mode()): "full" shows
---headers + raw text, "summary" one truncated line per entry, "hidden"
---renders nothing anywhere. Subscribes itself to the "transcript" event on
---first require.
local autonomy = require("stick-shift.autonomy")
local events = require("stick-shift.events")

local M = {}

local CAP = 200

---@type { kind: string, op: string, text: string }[]
local entries = {}

---Append an entry, evicting the oldest past the cap.
---@param entry { kind: "request"|"response"|"event", op: string, text: string }
function M.push(entry)
  if type(entry) ~= "table" then
    return
  end
  table.insert(entries, {
    kind = tostring(entry.kind or "event"),
    op = tostring(entry.op or "?"),
    text = tostring(entry.text or ""),
  })
  while #entries > CAP do
    table.remove(entries, 1)
  end
end

---Drop everything (e.g. when a new plan starts).
function M.clear()
  entries = {}
end

local ARROW = { request = "→", response = "←", event = "·" }

---One display line, "verify ← looks correct…" style, capped at 80 columns.
---@param e { kind: string, op: string, text: string }
---@return string
local function summary_line(e)
  local text = vim.trim((e.text or ""):gsub("%s+", " "))
  local line = ("%s %s %s"):format(e.op, ARROW[e.kind] or "·", text)
  if vim.fn.strdisplaywidth(line) > 80 then
    line = vim.fn.strcharpart(line, 0, 79) .. "…"
  end
  return line
end

---Rendered transcript lines, most recent last, per the effective mode.
---@param max integer|nil cap on the number of RETURNED lines (tail wins)
---@return string[]
function M.lines(max)
  local mode = autonomy.transcript_mode()
  if mode == "hidden" then
    return {}
  end
  local out = {}
  for _, e in ipairs(entries) do
    if mode == "summary" then
      table.insert(out, summary_line(e))
    else -- "full"
      table.insert(out, ("── %s (%s)"):format(e.op, e.kind))
      for _, l in ipairs(vim.split(e.text or "", "\n", { plain = true })) do
        table.insert(out, l)
      end
    end
  end
  if max and max > 0 and #out > max then
    local tail = {}
    for i = #out - max + 1, #out do
      table.insert(tail, out[i])
    end
    out = tail
  end
  return out
end

-- Subscribe on first require. Test runners that events.reset() also purge
-- package.loaded["stick-shift..."], so the subscription comes back with the module.
events.on("transcript", function(entry)
  M.push(entry)
end)

return M
