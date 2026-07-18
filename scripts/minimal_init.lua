-- Minimal init for manual testing / repro:
--   nvim -u scripts/minimal_init.lua
-- Loads only stick-shift.nvim (from this repo) with the mock backend at level 2.
local repo = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
vim.opt.runtimepath:prepend(repo)

require("stick-shift").setup({
  backend = "mock", -- swap for "claude_code" / "ollama" to go live
  autonomy = 2,
})
