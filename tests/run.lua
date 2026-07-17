-- Self-contained offline test runner for reins.nvim:
--   nvim --headless -l tests/run.lua
-- No plenary/busted. Each tests/test_*.lua returns { ["test name"] = fn };
-- every test runs in a pcall. Exit code = number of failures.
local src = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local tests_dir = vim.fs.dirname(src)
local repo = vim.fs.dirname(tests_dir)
vim.opt.runtimepath:prepend(repo)
package.path = tests_dir .. "/?.lua;" .. package.path

-- Tests exercise warn/error paths on purpose; swallow notifications so the
-- report stays readable (assertion failures still print below).
vim.notify = function() end

---Reset reins state between test FILES so nothing can leak: explicit registry
---resets first (event handlers, buffer locks, mock overrides), then a hard
---purge so the next file require()s everything fresh.
local function purge_reins()
  for _, name in ipairs({ "reins.events", "reins.lock", "reins.backend.mock" }) do
    local mod = package.loaded[name]
    if type(mod) == "table" and type(mod.reset) == "function" then
      pcall(mod.reset)
    end
  end
  for name in pairs(package.loaded) do
    if name:match("^reins") then
      package.loaded[name] = nil
    end
  end
end

-- With file arguments, run only those files (used by CI-ish targeted runs):
--   nvim --headless -l tests/run.lua tests/test_util.lua
local files = {}
if _G.arg and _G.arg[1] then
  for _, a in ipairs(_G.arg) do
    files[#files + 1] = vim.fn.fnamemodify(a, ":p")
  end
else
  files = vim.fn.glob(tests_dir .. "/test_*.lua", true, true)
end
table.sort(files)

local passed, failed = 0, 0
for _, file in ipairs(files) do
  purge_reins()
  local label = vim.fn.fnamemodify(file, ":t:r")
  local chunk, load_err = loadfile(file)
  local ok, suite
  if chunk then
    ok, suite = pcall(chunk)
  else
    ok, suite = false, load_err
  end
  if not ok or type(suite) ~= "table" then
    failed = failed + 1
    print(("FAIL %s (could not load): %s"):format(label, tostring(suite)))
  else
    local names = vim.tbl_keys(suite)
    table.sort(names)
    for _, name in ipairs(names) do
      local tok, terr = pcall(suite[name])
      if tok then
        passed = passed + 1
        print(("ok   %s :: %s"):format(label, name))
      else
        failed = failed + 1
        print(("FAIL %s :: %s\n     %s"):format(label, name, tostring(terr)))
      end
    end
  end
end
purge_reins()

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed)
