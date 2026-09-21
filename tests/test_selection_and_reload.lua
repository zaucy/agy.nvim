local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")

print("--- Testing Visual Selection Protection & Reload Flow ---")

local test_helpers = require("tests.test_helpers")
local tmp_dir, conv_id = test_helpers.create_mock_environment()
require("agy").setup({ app_data_dir = tmp_dir })

vim.cmd("edit agy://" .. conv_id)
local buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()
local state = protocol.buffers[buf]
assert(state ~= nil, "Buffer state must exist")

local orig_lines_count = vim.api.nvim_buf_line_count(buf)
local p_start = state.prompt_start_line
print("Loaded lines: " .. orig_lines_count .. ", prompt_start: " .. p_start)

-- ==========================================================
-- TEST 1: Visual selection spanning into history
-- ==========================================================
print("\n[Test 1] Testing visual selection spanning into history...")

-- Cursor at prompt line, start visual mode, move up to line 1
vim.api.nvim_win_set_cursor(win, { p_start, 0 })
vim.cmd("normal! V")
vim.api.nvim_win_set_cursor(win, { 1, 0 })

-- Update modifiable check
protocol.update_modifiable(buf)
assert(vim.bo[buf].modifiable == false, "Modifiable must be FALSE when visual selection covers history")
print("✓ modifiable is FALSE for history-spanning selection")

-- Attempt to delete with visual keymap
vim.cmd("normal d")

local lines_after_blocked_del = vim.api.nvim_buf_line_count(buf)
assert(lines_after_blocked_del == orig_lines_count, "Lines count must not change when delete is blocked!")
print("✓ Deletion blocked, buffer intact (" .. lines_after_blocked_del .. " lines)")

-- Exit visual mode
vim.cmd("normal! \27")

-- ==========================================================
-- TEST 2: Visual selection inside prompt area only
-- ==========================================================
print("\n[Test 2] Testing visual selection inside prompt area...")

-- Add 2 prompt lines
protocol.with_modifiable(buf, function()
	vim.api.nvim_buf_set_lines(buf, p_start - 1, -1, false, {
		"Prompt line 1 to delete",
		"Prompt line 2 to keep",
	})
end)

-- Select just the first prompt line
vim.api.nvim_win_set_cursor(win, { p_start, 0 })
vim.cmd("normal! V")
protocol.update_modifiable(buf)
assert(vim.bo[buf].modifiable == true, "Modifiable must be TRUE when selection is within prompt area")

-- Delete selected line
vim.cmd("normal d")
print("✓ Deletion within prompt area succeeded")

-- ==========================================================
-- TEST 3: Reloading on :e! and :e
-- ==========================================================
print("\n[Test 3] Testing :e! reload...")

-- Modify buffer
protocol.with_modifiable(buf, function()
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Garbage unsaved prompt" })
end)
vim.bo[buf].modified = true
print("Modified before reload: " .. tostring(vim.bo[buf].modified))

-- Run :edit!
vim.cmd("edit!")

local reloaded_count = vim.api.nvim_buf_line_count(buf)
print("Lines after :edit!: " .. reloaded_count)
print("Modified after :edit!: " .. tostring(vim.bo[buf].modified))

assert(vim.bo[buf].modified == false, "Modified must be false after reload")
assert(reloaded_count == orig_lines_count, "Reload must restore original transcript line count")
print("✓ :e! cleanly reloaded transcript and reset modified state")

-- Run :edit (without !)
print("\nTesting :e reload...")
vim.cmd("edit")
assert(vim.bo[buf].modified == false, "Modified must remain false after :e")
assert(vim.api.nvim_buf_line_count(buf) == orig_lines_count, "Line count remains consistent")
print("✓ :e successfully refreshed buffer")

-- Clean up
protocol.cleanup_buffer(buf)
vim.cmd("bdelete! " .. buf)

print("\nALL SELECTION & RELOAD TESTS PASSED!")
