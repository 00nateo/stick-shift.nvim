-- Load-check modules headlessly:
--   nvim --headless -l scripts/loadcheck.lua reins.ui.panel reins.complete ...
-- Exits with the number of modules that failed to require.
local src = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(src))
vim.opt.runtimepath:prepend(repo)

local mods = _G.arg or {}
if #mods == 0 then
  mods = { "reins" }
end
local failed = 0
for _, m in ipairs(mods) do
  local ok, err = pcall(require, m)
  print((ok and "ok   " or "FAIL ") .. m .. (ok and "" or (": " .. tostring(err))))
  if not ok then
    failed = failed + 1
  end
end
os.exit(failed)
