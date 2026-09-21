local protocol = require("agy.protocol")
local render = require("agy.render")
local completion = require("agy.completion")
local config = require("agy.config")

print("=== Running Dedicated Verification for User Issues 1-4 ===")

require("agy").setup()

-- =========================================================================
-- ISSUE 1: When prompt is empty, buffer is NOT marked modified
-- =========================================================================
print("\n[Issue 1] Testing empty prompt modified state...")
vim.cmd("edit agy://new")
local buf1 = vim.api.nvim_get_current_buf()
local win1 = vim.api.nvim_get_current_win()
local state1 = protocol.buffers[buf1]
assert(state1, "State for buf1 must exist")

-- 1a. Fresh buffer must have modified == false
assert(vim.bo[buf1].modified == false, "Fresh agy://new buffer must have modified == false")
print("✓ Fresh agy://new buffer is unmodified")

-- 1b. Typing makes it modified
local p_line = state1.prompt_start_line
vim.api.nvim_win_set_cursor(win1, { p_line, 0 })
vim.cmd("normal! iSome prompt text\27")
assert(vim.bo[buf1].modified == true, "Buffer must be modified after typing prompt text")
print("✓ Typing prompt marks buffer as modified")

-- 1c. Deleting text back to empty resets modified to false
protocol.with_modifiable(buf1, function()
  vim.api.nvim_buf_set_lines(buf1, p_line - 1, -1, false, { "" })
end)
protocol.update_modifiable(buf1)
assert(protocol.extract_prompt(buf1) == "", "Prompt must now be empty")
assert(vim.bo[buf1].modified == false, "Buffer modified flag must automatically reset to false when prompt is empty!")
print("✓ Empty prompt automatically resets modified flag to false")

-- 1d. Running :w on empty prompt does not set modified = true
vim.cmd("write")
assert(vim.bo[buf1].modified == false, "Writing empty prompt must leave buffer unmodified")
print("✓ Running :w with empty prompt leaves buffer unmodified")

protocol.cleanup_buffer(buf1)

-- =========================================================================
-- ISSUE 2: Deleting prompt area always preserves 1 line and keeps cursor editable
-- =========================================================================
print("\n[Issue 2] Testing prompt deletion protection (always 1 editable line)...")
vim.cmd("edit agy://new")
local buf2 = vim.api.nvim_get_current_buf()
local win2 = vim.api.nvim_get_current_win()
local state2 = protocol.buffers[buf2]
local orig_p_line = state2.prompt_start_line

-- 2a. Add multi-line prompt text
protocol.with_modifiable(buf2, function()
  vim.api.nvim_buf_set_lines(buf2, orig_p_line - 1, -1, false, {
    "First line of prompt",
    "Second line of prompt",
    "Third line of prompt",
  })
end)
local lines_before_del = vim.api.nvim_buf_line_count(buf2)
assert(lines_before_del == orig_p_line + 2, "Buffer should have 3 prompt lines")

-- 2b. Visual select entire prompt area and delete with 'd'
vim.api.nvim_win_set_cursor(win2, { orig_p_line, 0 })
vim.cmd("normal! V")
vim.api.nvim_win_set_cursor(win2, { lines_before_del, 0 })
vim.cmd("normal d")

local lines_after_del = vim.api.nvim_buf_line_count(buf2)
print("Lines after visual delete of entire prompt: " .. lines_after_del)
assert(lines_after_del >= orig_p_line, "Buffer must still have at least 1 prompt line!")
local remaining_prompt_line = vim.api.nvim_buf_get_lines(buf2, orig_p_line - 1, orig_p_line, false)[1]
assert(remaining_prompt_line == "", "Prompt line must be cleared to empty string")

protocol.update_modifiable(buf2)
local cur_pos = vim.api.nvim_win_get_cursor(win2)
assert(cur_pos[1] == orig_p_line, "Cursor must remain at prompt line, found: " .. cur_pos[1])
assert(vim.bo[buf2].modifiable == true, "Buffer must remain modifiable for user to type!")
print("✓ Visual deletion of entire prompt preserves 1 line and keeps buffer modifiable")

-- 2c. Normal mode 'dd' on the single prompt line
vim.api.nvim_win_set_cursor(win2, { orig_p_line, 0 })
vim.cmd("normal! iSingle line to test dd\27")
assert(vim.api.nvim_buf_get_lines(buf2, orig_p_line - 1, orig_p_line, false)[1] == "Single line to test dd")
vim.cmd("normal dd")

local lines_after_dd = vim.api.nvim_buf_line_count(buf2)
assert(lines_after_dd >= orig_p_line, "Buffer must still have at least 1 prompt line after dd!")
local dd_line = vim.api.nvim_buf_get_lines(buf2, orig_p_line - 1, orig_p_line, false)[1]
assert(dd_line == "", "Prompt line must be cleared to empty string after dd")
protocol.update_modifiable(buf2)
assert(vim.bo[buf2].modifiable == true, "Buffer must remain modifiable after dd!")
print("✓ Normal mode dd on single prompt line clears text and preserves modifiable state")

protocol.cleanup_buffer(buf2)

-- =========================================================================
-- ISSUE 3: Follow-bottom on :w and disengage on cursor up
-- =========================================================================
print("\n[Issue 3] Testing follow-bottom behavior...")
vim.cmd("edit agy://new")
local buf3 = vim.api.nvim_get_current_buf()
local win3 = vim.api.nvim_get_current_win()
local state3 = protocol.buffers[buf3]

-- Type prompt text
vim.api.nvim_win_set_cursor(win3, { state3.prompt_start_line, 0 })
vim.cmd("normal! iTest prompt for follow-bottom\27")

-- Submit via :w
vim.cmd("write")
assert(state3.follow_bottom == true, "state.follow_bottom must be TRUE immediately after :w")
print("✓ state.follow_bottom is TRUE after :w")

-- Simulate incoming streaming text deltas while following bottom
protocol.with_modifiable(buf3, function()
  render.append_text_delta(buf3, "Streaming delta line 1\nStreaming delta line 2\n", state3.config)
  if state3.follow_bottom then
    render.scroll_to_bottom(buf3, true)
  end
end)

local count_after_stream = vim.api.nvim_buf_line_count(buf3)
local cur_after_stream = vim.api.nvim_win_get_cursor(win3)[1]
assert(cur_after_stream == count_after_stream, "Cursor must be at the bottom line during follow_bottom")
print("✓ Cursor automatically pinned to bottom line during streaming (" .. cur_after_stream .. ")")

-- Simulate user moving cursor up to line 1 to read history
vim.api.nvim_win_set_cursor(win3, { 1, 0 })
-- Trigger CursorMoved autocmd
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf3 })

assert(state3.follow_bottom == false, "state.follow_bottom must become FALSE when user moves cursor up!")
print("✓ state.follow_bottom disengaged when cursor moved up")

-- Simulate more incoming streaming deltas
protocol.with_modifiable(buf3, function()
  render.append_text_delta(buf3, "Another streaming delta\n", state3.config)
  if state3.follow_bottom then
    render.scroll_to_bottom(buf3, true)
  end
end)

local cur_after_disengage = vim.api.nvim_win_get_cursor(win3)[1]
assert(cur_after_disengage == 1, "Cursor must NOT be yanked to bottom when follow_bottom is false!")
print("✓ Cursor remains at user-selected line 1, not yanked to bottom")

protocol.cleanup_buffer(buf3)

-- =========================================================================
-- ISSUE 4: Slash commands autocompletion and syntax coloring
-- =========================================================================
print("\n[Issue 4] Testing slash commands autocompletion and syntax coloring...")

-- 4a. Verify completion function findstart
local find_start = completion.completefunc(1, "")
assert(find_start == -3, "completefunc with no slash should return -3")

-- Test finding slash at start of line
vim.cmd("edit agy://new")
local buf4 = vim.api.nvim_get_current_buf()
local win4 = vim.api.nvim_get_current_win()
local state4 = protocol.buffers[buf4]

vim.api.nvim_win_set_cursor(win4, { state4.prompt_start_line, 0 })
vim.api.nvim_set_current_line("/pl")
vim.api.nvim_win_set_cursor(win4, { state4.prompt_start_line, 3 })

local col_start = completion.completefunc(1, "")
assert(col_start == 0, "completefunc findstart should find column 0 for /pl, found: " .. tostring(col_start))
print("✓ completefunc findstart correctly locates slash column")

-- 4b. Verify candidate matching
local matches = completion.completefunc(0, "/pl")
assert(type(matches) == "table" and #matches > 0, "completefunc should return candidates for /pl")
local found_plan = false
for _, item in ipairs(matches) do
  if item.word == "/plan" then
    found_plan = true
    assert(item.menu:find("%[agy%]"), "Candidate menu should include [agy]")
    assert(item.info:find("Deep planning"), "Candidate info should include description")
  end
end
assert(found_plan, "Matches must contain /plan")
print("✓ Matches for '/pl' contain '/plan' with menu and description")

-- 4c. Verify other commands exist
local all_matches = completion.completefunc(0, "/")
assert(#all_matches >= 20, "Should have at least 20 slash commands registered, found: " .. #all_matches)
print("✓ Found " .. #all_matches .. " Antigravity slash commands in registry")

-- 4d. Verify URL does NOT trigger slash command completion
vim.api.nvim_set_current_line("https://github.com")
vim.api.nvim_win_set_cursor(win4, { state4.prompt_start_line, 18 })
local url_col = completion.completefunc(1, "")
assert(url_col == -3, "completefunc must NOT trigger on URLs!")
print("✓ completefunc safely ignores slashes inside URLs")

-- 4e. Verify syntax match definition
local hl = vim.api.nvim_get_hl(0, { name = "AgySlashCommand" })
assert(hl ~= nil, "AgySlashCommand highlight group must exist")
print("✓ AgySlashCommand highlight group verified")

protocol.cleanup_buffer(buf4)

print("\nALL ISSUES 1-4 TESTS PASSED PERFECTLY!")
