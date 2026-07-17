---@brief Shared helpers for reins.nvim: fs, json, paths, notify, debounce.
local M = {}

local islist = vim.islist or vim.tbl_islist

---Deep-merge `override` into a copy of `base`. Maps merge recursively;
---non-empty lists and scalars in `override` replace the base value wholesale
---(unlike vim.tbl_deep_extend, which merges lists by index). An EMPTY table is
---treated as a map, so `{ ui = {} }` leaves every ui default intact rather
---than wiping the section.
---@param base table
---@param override table|nil
---@return table
function M.deep_merge(base, override)
  local out = vim.deepcopy(base)
  if type(override) ~= "table" then
    return out
  end
  local function mergeable(t)
    return type(t) == "table" and (next(t) == nil or not islist(t))
  end
  for k, v in pairs(override) do
    if mergeable(v) and mergeable(out[k]) then
      out[k] = M.deep_merge(out[k], v)
    else
      out[k] = vim.deepcopy(v)
    end
  end
  return out
end

---@param msg string
---@param level integer|nil vim.log.levels.*, default INFO
function M.notify(msg, level)
  vim.notify("[reins] " .. msg, level or vim.log.levels.INFO)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

---@param path string
---@return string|nil content, string|nil err
function M.read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, "cannot open " .. path
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

---@param path string
---@param content string
---@return boolean ok, string|nil err
function M.write_file(path, content)
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err or ("cannot write " .. path)
  end
  fd:write(content)
  fd:close()
  return true
end

---@param path string directory to create (with parents)
function M.ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

---@param path string
---@return boolean
function M.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

---Root of the reins.nvim plugin itself (for locating prompts/).
---@return string
function M.plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  -- src = <root>/lua/reins/util.lua
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(src)))
end

---Project root for the current buffer: nearest ancestor containing `.reins`
---or `.git`, else the cwd. Works headless (unnamed buffer -> cwd).
---@param bufpath string|nil
---@return string
function M.project_root(bufpath)
  local start = bufpath or vim.api.nvim_buf_get_name(0)
  if start == nil or start == "" then
    start = assert(vim.uv.cwd())
  end
  local found = vim.fs.root(start, { ".reins", ".git" })
  return found or assert(vim.uv.cwd())
end

---Collect context files (AGENT.md / AGENTS.md / CLAUDE.md), 99-style: walk up
---from `root` gathering every match, nearest last so it wins on conflict.
---@param root string
---@param cap integer|nil max total bytes (default 8192)
---@return string concatenated context, possibly ""
function M.context_files(root, cap)
  cap = cap or 8192
  local names = { "AGENT.md", "AGENTS.md", "CLAUDE.md" }
  local chunks = {}
  local dirs = {}
  for dir in vim.fs.parents(root .. "/x") do
    table.insert(dirs, 1, dir) -- outermost first, project root last
    if #dirs > 8 then
      break
    end
  end
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(names) do
      local content = M.read_file(dir .. "/" .. name)
      if content then
        table.insert(chunks, ("<!-- %s/%s -->\n%s"):format(dir, name, content))
      end
    end
  end
  local joined = table.concat(chunks, "\n\n")
  return M.truncate(joined, cap)
end

---@param s string
---@param n integer
---@return string
function M.truncate(s, n)
  if #s <= n then
    return s
  end
  return s:sub(1, n) .. ("\n[... truncated %d bytes]"):format(#s - n)
end

---UTC timestamp for logs and plan metadata.
---@return string
function M.now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

---Lenient JSON decode for LLM output: try as-is, then strip markdown fences,
---then the substring from the first '{' to the last '}'.
---@param raw string|nil
---@return boolean ok, any value_or_err
function M.decode_json_loose(raw)
  if type(raw) ~= "string" or raw == "" then
    return false, "empty response"
  end
  local candidates = { raw }
  local unfenced = raw:gsub("```[%w]*\n?", "")
  if unfenced ~= raw then
    table.insert(candidates, unfenced)
  end
  local first, last = raw:find("^%s*"), nil
  first = raw:find("{", 1, true)
  last = raw:match(".*()}")
  if first and last and last > first then
    table.insert(candidates, raw:sub(first, last))
  end
  local err
  for _, cand in ipairs(candidates) do
    local ok, val = pcall(vim.json.decode, cand, { luanil = { object = true, array = true } })
    if ok and type(val) == "table" then
      return true, val
    end
    err = val
  end
  return false, "invalid JSON: " .. tostring(err)
end

---Debounced wrapper around fn (trailing edge). Returns the wrapped function
---and a cancel function. Callback runs on the main loop (vim.schedule).
---cancel() also suppresses a trailing call whose uv timer has already fired
---but whose scheduled body has not run yet — without the generation check the
---call would escape cancellation in that window (e.g. completion firing after
---InsertLeave cleared it).
---@param ms integer
---@param fn function
---@return function wrapped, function cancel
function M.debounce(ms, fn)
  local timer = nil
  local gen = 0
  local function cancel()
    gen = gen + 1
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end
  local function wrapped(...)
    local argv = { ... }
    cancel()
    local my = gen
    local t = vim.uv.new_timer()
    timer = t
    t:start(ms, 0, function()
      t:stop()
      if not t:is_closing() then
        t:close()
      end
      vim.schedule(function()
        if gen ~= my then
          return -- cancelled (or superseded) after the timer fired
        end
        fn(unpack(argv))
      end)
    end)
  end
  return wrapped, cancel
end

M.islist = islist

return M
