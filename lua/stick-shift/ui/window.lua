---@brief Panel window management. One window, dockable as a split on any
---editor edge ("left"|"top"|"right"|"bottom") or floating at the right edge
---("float"); the layout is switchable at runtime without losing the buffer.
---All window logic for the panel lives here - stick-shift.ui.panel owns the buffer,
---this module owns where it shows.
local config = require("stick-shift.config")
local util = require("stick-shift.util")

local M = {}

---@type integer|nil the panel window (nil when closed)
M._win = nil
---@type integer|nil the buffer last shown (kept across close/re-open)
M._buf = nil
---@type string|nil layout chosen EXPLICITLY by the user (set_layout / :StickShift
---{layout}); wins over config.ui.layout until changed. nil = follow config.
M._layout = nil
---@type string|nil the layout the currently-open window actually uses
M._shown_layout = nil

local LAYOUTS = { left = true, top = true, right = true, bottom = true, float = true }

---nvim_open_win `split` values for our layout names.
local SPLIT_DIR = { left = "left", right = "right", top = "above", bottom = "below" }

---Ex-command fallback in case nvim_open_win's split= form is unavailable.
local SPLIT_CMD = {
  left = "topleft vertical split",
  right = "botright vertical split",
  top = "topleft split",
  bottom = "botright split",
}

---@param win integer
---@param name string
---@param value any
local function wopt(win, name, value)
  pcall(vim.api.nvim_set_option_value, name, value, { win = win })
end

---Open (or re-open) the panel window showing `bufnr`.
---@param bufnr integer
---@param layout string|nil "left"|"top"|"right"|"bottom"|"float"; defaults to
---the layout last chosen EXPLICITLY (arg here or set_layout()), else
---config.ui.layout - so re-running setup({ui={layout=...}}) keeps working at
---runtime unless the user has deliberately overridden it.
---@return integer|nil winid
function M.open(bufnr, layout)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    util.warn("panel window: invalid buffer")
    return nil
  end
  local ui = config.get().ui
  local explicit = layout ~= nil
  layout = layout or M._layout or ui.layout
  if not LAYOUTS[layout] then
    util.warn(("unknown layout %q - using %q"):format(tostring(layout), tostring(ui.layout)))
    layout = LAYOUTS[ui.layout] and ui.layout or "right"
    explicit = false
  end
  local shown_layout = M._shown_layout
  if M.is_open() and M._buf == bufnr and shown_layout == layout then
    if explicit then
      M._layout = layout
    end
    return M._win
  end
  M.close()

  local win
  if layout == "float" then
    -- Anchored to the right edge, below the tabline row.
    local width = math.min(ui.width, math.max(20, vim.o.columns - 4))
    local height = math.min(ui.height, math.max(3, vim.o.lines - 6))
    win = vim.api.nvim_open_win(bufnr, false, {
      relative = "editor",
      width = width,
      height = height,
      row = 1,
      col = math.max(0, vim.o.columns - width - 2),
      border = "rounded",
      zindex = 40,
    })
  else
    -- 0.11 supports split=/win=-1 in the win config (verified on 0.11.5 by
    -- the headless UI check); pcall keeps an ex-command fallback anyway.
    local wcfg = { split = SPLIT_DIR[layout], win = -1 }
    if layout == "left" or layout == "right" then
      wcfg.width = ui.width
    else
      wcfg.height = ui.height
    end
    local ok, res = pcall(vim.api.nvim_open_win, bufnr, false, wcfg)
    if ok then
      win = res
    else
      local prev = vim.api.nvim_get_current_win()
      vim.cmd(SPLIT_CMD[layout])
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, bufnr)
      if layout == "left" or layout == "right" then
        vim.api.nvim_win_set_width(win, ui.width)
      else
        vim.api.nvim_win_set_height(win, ui.height)
      end
      pcall(vim.api.nvim_set_current_win, prev)
    end
  end

  wopt(win, "number", false)
  wopt(win, "relativenumber", false)
  wopt(win, "wrap", false)
  wopt(win, "signcolumn", "no")
  wopt(win, "foldcolumn", "0")
  wopt(win, "spell", false)
  wopt(win, "list", false)
  if layout == "left" or layout == "right" then
    wopt(win, "winfixwidth", true)
  elseif layout == "top" or layout == "bottom" then
    wopt(win, "winfixheight", true)
  end

  M._win, M._buf, M._shown_layout = win, bufnr, layout
  if explicit then
    M._layout = layout -- remember only deliberate choices
  end
  return win
end

---Close the panel window (buffer survives; bufhidden=hide).
function M.close()
  local win = M._win
  M._win = nil
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if not pcall(vim.api.nvim_win_close, win, true) then
    -- Closing the last window in a tabpage is an error. Keep state truthful:
    -- show an empty scratch buffer in that window instead, so the panel is
    -- gone and the next toggle doesn't open a duplicate split.
    if vim.api.nvim_win_is_valid(win) then
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.bo[scratch].bufhidden = "wipe"
      pcall(vim.api.nvim_win_set_buf, win, scratch)
    end
  end
end

---@return boolean
function M.is_open()
  return M._win ~= nil and vim.api.nvim_win_is_valid(M._win)
end

---@return integer|nil winid
function M.win()
  if M.is_open() then
    return M._win
  end
  return nil
end

---Switch the layout at runtime: re-opens the same buffer in the new position
---when the panel is showing; otherwise just records the preference.
---@param layout string "left"|"top"|"right"|"bottom"|"float"
function M.set_layout(layout)
  if not LAYOUTS[layout] then
    util.warn(("unknown layout %q (use left|top|right|bottom|float)"):format(tostring(layout)))
    return
  end
  if M.is_open() and M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    local buf = M._buf
    M.close()
    M.open(buf, layout)
  else
    M._layout = layout
  end
end

return M
