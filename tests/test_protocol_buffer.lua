local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")

print("--- Testing Protocol & Buffer Setup with Virtual Dividers ---")

require("agy").setup()

-- 1. Test opening agy://new
vim.cmd("edit agy://new")
local buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()

assert(vim.bo[buf].buftype == "acwrite", "Expected buftype == acwrite, got: " .. vim.bo[buf].buftype)
assert(vim.bo[buf].filetype == "agy", "Expected filetype == agy, got: " .. vim.bo[buf].filetype)
assert(vim.bo[buf].swapfile == false, "Expected swapfile == false")

local state = protocol.buffers[buf]
assert(state ~= nil, "State must exist")
assert(state.prompt_start_line == 8, "Prompt start line must be 8, got: " .. tostring(state.prompt_start_line))

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Buffer lines count: " .. #lines)
assert(lines[3]:find("Antigravity CLI", 1, true), "Line 3 must contain Antigravity CLI title")
assert(lines[4]:find("agy://new", 1, true), "Line 4 must contain session URI")

-- Check virtual text divider with virt_lines_leftcol
local ui_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_UI, 0, -1, { details = true })
print("UI extmarks count: " .. #ui_marks)
assert(#ui_marks >= 1, "Must have active prompt divider extmark")
local divider_mark = ui_marks[1]
assert(divider_mark[4].virt_lines ~= nil, "Divider mark must have virt_lines")
assert(divider_mark[4].virt_lines_leftcol == true, "Divider mark must have virt_lines_leftcol = true")
assert(divider_mark[4].sign_text == "❯ ", "Divider mark must have sign_text = '❯ '")
print("✓ Virtual divider with virt_lines_leftcol verified")

-- Check conceallevel (0 by default: no conceal jumping)
assert(vim.wo.conceallevel == 0, "Expected conceallevel == 0, got: " .. vim.wo.conceallevel)
print("✓ Filetype agy and conceallevel == 0 verified")

-- Check history background highlight (disabled by default)
local hist_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_HISTORY, 0, -1, { details = true })
print("History background extmarks count (default): " .. #hist_marks)
assert(#hist_marks == 0, "Default must NOT apply history background marks when color_history is false")

-- Verify enabling color_history applies AgyHistory marks
render.apply_history_highlights(buf, state.prompt_start_line, { ui = { color_history = true } })
local enabled_hist_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_HISTORY, 0, -1, { details = true })
assert(#enabled_hist_marks >= 2, "Lines 0 and 1 must have history background marks when color_history is true")
assert(enabled_hist_marks[1][4].line_hl_group == "AgyHistory", "Mark must have line_hl_group == AgyHistory")

-- Verify clearing color_history removes marks
render.apply_history_highlights(buf, state.prompt_start_line, { ui = { color_history = false } })
assert(#vim.api.nvim_buf_get_extmarks(buf, render.NS_HISTORY, 0, -1, {}) == 0, "Marks must be cleared")
print("✓ History background highlighting option verified")

-- 2. Test cursor-based modifiable toggling
-- At prompt line: modifiable should be true
vim.api.nvim_win_set_cursor(win, { state.prompt_start_line, 0 })
protocol.update_modifiable(buf)
assert(vim.bo[buf].modifiable == true, "Must be modifiable when cursor is at prompt line")
print("✓ Cursor at prompt line is modifiable")

-- Move cursor up to header line 1: modifiable should automatically become false!
vim.api.nvim_win_set_cursor(win, { 1, 0 })
protocol.update_modifiable(buf)
assert(vim.bo[buf].modifiable == false, "Must NOT be modifiable when cursor is in history line 1")
print("✓ Cursor in history area is protected (modifiable = false)")

-- Move cursor back to prompt line: modifiable restores to true!
vim.api.nvim_win_set_cursor(win, { state.prompt_start_line, 0 })
protocol.update_modifiable(buf)
assert(vim.bo[buf].modifiable == true, "Must be modifiable again when returning to prompt line")
print("✓ Cursor returned to prompt line is modifiable again")

-- 3. Test prompt extraction
vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, {
	"Can you explain the difference between processes and threads?",
	"Please keep it concise.",
})

local prompt, p_line = protocol.extract_prompt(buf)
print("Extracted prompt: " .. prompt)
assert(
	prompt == "Can you explain the difference between processes and threads?\nPlease keep it concise.",
	"Prompt extraction mismatch"
)
assert(p_line == state.prompt_start_line, "Expected p_line == " .. state.prompt_start_line .. ", got: " .. tostring(p_line))
print("✓ Prompt extraction verified")

-- Clean up
protocol.cleanup_buffer(buf)
vim.cmd("bdelete! " .. buf)

print("ALL PROTOCOL BUFFER TESTS PASSED!")
