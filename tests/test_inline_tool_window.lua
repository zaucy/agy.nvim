-- Standalone test suite for inline tool output window:
-- 1. Configurable max_height (default 20, custom values)
-- 2. Horizontal alignment with start of tool name
-- 3. Window lifecycle, keymaps (<CR>, q, <Esc>), and cleanup
-- 4. Invariance of parent conversation buffer lines

local render = require("agy.render")
local protocol = require("agy.protocol")
local config = require("agy.config")

print("=== Running Inline Tool Window Tests ===\n")

-- ---------------------------------------------------------------------------
-- TEST 1: Default and Configurable max_height
-- ---------------------------------------------------------------------------
print("[Test 1] Testing configurable max_height (default 20 and custom)...")

local default_cfg = config.setup()
assert(default_cfg.ui.tool_max_height == 20, "Default tool_max_height must be 20")

-- Test custom max_height
local custom_cfg = config.setup({
  ui = {
    tool_max_height = 8,
  },
})
assert(custom_cfg.ui.tool_max_height == 8, "Custom tool_max_height must be 8")

-- Rejection of invalid max_height
local ok, err = pcall(function()
  config.setup({
    ui = {
      tool_max_height = -5,
    },
  })
end)
assert(not ok, "Must reject non-positive tool_max_height")
assert(tostring(err):find("positive number"), "Error message must mention positive number")

-- Reset config
config.setup()
print("✓ Configurable max_height validation verified!")

-- ---------------------------------------------------------------------------
-- TEST 2: Height clamping with default max_height (20)
-- ---------------------------------------------------------------------------
print("\n[Test 2] Testing inline window height clamping...")

local test_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(test_buf)
local prompt_line, prompt_ext_id = render.render_new_session(test_buf, default_cfg)
protocol._setup_buffer(test_buf, "new")

local state = {
  buf = test_buf,
  config = default_cfg,
  prompt_start_line = prompt_line,
  prompt_extmark_id = prompt_ext_id,
  tool_calls = {},
  stream_info = { status = "ready" },
}
protocol.buffers[test_buf] = state

-- Generate 35 lines of output
local long_lines = {}
for i = 1, 35 do
  table.insert(long_lines, "Line output " .. i)
end
local long_output = table.concat(long_lines, "\n")

local tool_line, ext_id, _ = render.append_tool_call(test_buf, "view_file", { TargetFile = "long_file.txt" }, nil, default_cfg)
local tc_long = {
  id = 1,
  tool_name = "view_file",
  params = { TargetFile = "long_file.txt" },
  output = long_output,
  header_extmark_id = ext_id,
  header_line_idx = tool_line,
  status = "done",
  is_open = false,
}
table.insert(state.tool_calls, tc_long)
render.complete_tool_call(test_buf, tc_long, 0.2, long_output, default_cfg)

local buf_line_count_before = vim.api.nvim_buf_line_count(test_buf)

-- Open inline window
vim.api.nvim_win_set_cursor(0, { tool_line + 1, 0 })
local opened = protocol.toggle_tool_at_cursor(test_buf)
assert(opened == true, "Must open inline window")
assert(tc_long.is_open == true, "Tool call must be marked open")
assert(tc_long.win and vim.api.nvim_win_is_valid(tc_long.win), "Window must be valid")

-- Ensure parent buffer lines did NOT change
local buf_line_count_during = vim.api.nvim_buf_line_count(test_buf)
assert(buf_line_count_during == buf_line_count_before, "Parent buffer lines must not be modified by inline window")

-- Check window height clamped to default max_height = 20
local win_cfg = vim.api.nvim_win_get_config(tc_long.win)
assert(win_cfg.height <= 20, "Window height must be <= 20, got " .. win_cfg.height)

-- Now test short output (5 lines) -> height should be 5, not 20
render.close_tool_window(state, tc_long)

-- Test with leading and trailing empty lines to verify trimming
local short_output = "\n\nLine 1\nLine 2\nLine 3\nLine 4\nLine 5\n\n\n"
local tool_line_s, ext_id_s, _ = render.append_tool_call(test_buf, "view_file", { TargetFile = "short.txt" }, nil, default_cfg)
local tc_short = {
  id = 2,
  tool_name = "view_file",
  params = { TargetFile = "short.txt" },
  output = short_output,
  header_extmark_id = ext_id_s,
  header_line_idx = tool_line_s,
  status = "done",
  is_open = false,
}
table.insert(state.tool_calls, tc_short)
render.complete_tool_call(test_buf, tc_short, 0.1, short_output, default_cfg)

vim.api.nvim_win_set_cursor(0, { tool_line_s + 1, 0 })
local opened_s = protocol.toggle_tool_at_cursor(test_buf)
assert(opened_s == true, "Must open short tool inline window")
local win_cfg_s = vim.api.nvim_win_get_config(tc_short.win)
-- 5 trimmed lines in inline window (padding is in virtual text, not in window)
assert(win_cfg_s.height == 5, "Window height for 5 lines must be exactly 5, got " .. win_cfg_s.height)

-- Verify cursor placed at line 1 (first content line)
local win_cursor = vim.api.nvim_win_get_cursor(tc_short.win)
assert(win_cursor[1] == 1, "Window cursor must start at line 1 (first content line), got " .. win_cursor[1])

-- Verify winhighlight has AgyToolInline for subtle background
local win_hl = vim.wo[tc_short.win].winhighlight
assert(win_hl:find("AgyToolInline"), "Window must use AgyToolInline in winhighlight: " .. win_hl)

-- Verify buffer lines in window contain ONLY content lines (no empty padding lines)
local float_lines = vim.api.nvim_buf_get_lines(tc_short.win_buf, 0, -1, false)
assert(#float_lines == 5, "Window buffer must have 5 lines, got " .. #float_lines)
assert(float_lines[1] == "Line 1", "Line 1 in window buffer must be first content line")
assert(float_lines[5] == "Line 5", "Line 5 in window buffer must be last content line")

render.close_tool_window(state, tc_short)

-- Test run_command positions cursor at the bottom (#win_lines)
local cmd_out = "Command line 1\nCommand line 2\nCommand line 3\nCommand line 4\nCommand line 5\nCommand line 6\nCommand line 7\nCommand line 8"
local tl_cmd, ext_cmd, _ = render.append_tool_call(test_buf, "run_command", { CommandLine = "cargo build" }, nil, default_cfg)
local tc_cmd = {
  id = 3,
  tool_name = "run_command",
  params = { CommandLine = "cargo build" },
  output = cmd_out,
  header_extmark_id = ext_cmd,
  header_line_idx = tl_cmd,
  status = "done",
  is_open = false,
}
table.insert(state.tool_calls, tc_cmd)
render.complete_tool_call(test_buf, tc_cmd, 1.5, cmd_out, default_cfg)

vim.api.nvim_win_set_cursor(0, { tl_cmd + 1, 0 })
local cmd_opened = protocol.toggle_tool_at_cursor(test_buf)
assert(cmd_opened == true, "Must open run_command inline window")
local cmd_cursor = vim.api.nvim_win_get_cursor(tc_cmd.win)
assert(cmd_cursor[1] == 8, "run_command cursor must be positioned at bottom line 8, got " .. cmd_cursor[1])

render.close_tool_window(state, tc_cmd)
print("✓ Window height clamping, trimming, and run_command bottom cursor verified!")

-- ---------------------------------------------------------------------------
-- TEST 3: Left Alignment with Start of Tool Name
-- ---------------------------------------------------------------------------
print("\n[Test 3] Testing left alignment with start of tool name...")

-- Tool call line in buffer: "🛠️ view_file `short.txt`"
local header_str = vim.api.nvim_buf_get_lines(test_buf, tool_line_s, tool_line_s + 1, false)[1]
local s_col = header_str:find("view_file", 1, true)
assert(s_col ~= nil, "view_file must be found in header")
local prefix = header_str:sub(1, s_col - 1)
local expected_col = vim.fn.strdisplaywidth(prefix)

vim.api.nvim_win_set_cursor(0, { tool_line_s + 1, 0 })
protocol.toggle_tool_at_cursor(test_buf)
local align_cfg = vim.api.nvim_win_get_config(tc_short.win)

assert(align_cfg.col == expected_col, string.format("Window col (%d) must align with tool name start col (%d)", align_cfg.col, expected_col))
print("✓ Tool name start column alignment verified (col = " .. align_cfg.col .. ")!")

-- Also verify Thought alignment
local thought_rec = render.append_thought_block(test_buf, "First thought line\nSecond thought line", 0.5, default_cfg)
table.insert(state.tool_calls, thought_rec)

local th_pos = vim.api.nvim_buf_get_extmark_by_id(test_buf, render.NS_UI, thought_rec.header_extmark_id, {})
local th_row = th_pos[1]
local th_header = vim.api.nvim_buf_get_lines(test_buf, th_row, th_row + 1, false)[1]
local th_s_col = th_header:find("Thought", 1, true)
local th_expected_col = vim.fn.strdisplaywidth(th_header:sub(1, th_s_col - 1))

-- Switch back to parent window and position cursor on thought line
local parent_win = vim.fn.bufwinid(test_buf)
vim.api.nvim_set_current_win(parent_win)
vim.api.nvim_win_set_cursor(parent_win, { th_row + 1, 0 })
local th_opened = protocol.toggle_tool_at_cursor(test_buf)
assert(th_opened == true, "Must open thought inline window")
-- Previous tool window should have closed automatically
assert(tc_short.is_open == false, "Previous tool window must close when new tool opens")

local th_win_cfg = vim.api.nvim_win_get_config(thought_rec.win)
assert(th_win_cfg.col == th_expected_col, string.format("Thought window col (%d) must align with 'Thought' (%d)", th_win_cfg.col, th_expected_col))
print("✓ Thought start column alignment verified (col = " .. th_win_cfg.col .. ")!")

render.close_tool_window(state, thought_rec)

-- ---------------------------------------------------------------------------
-- TEST 4: Keymaps and Close Behaviors
-- ---------------------------------------------------------------------------
print("\n[Test 4] Testing window keymaps (<CR>, q, <Esc>) and autoclose...")

-- Open tool window again
vim.api.nvim_win_set_cursor(0, { tool_line_s + 1, 0 })
protocol.toggle_tool_at_cursor(test_buf)
assert(tc_short.is_open == true, "Tool window is open")
local float_win = tc_short.win
assert(vim.api.nvim_get_current_win() == float_win, "Focus should enter inline window")

-- Pressing <CR> while inside the window closes it and returns focus to parent
protocol.toggle_tool_at_cursor(test_buf)
assert(tc_short.is_open == false, "Tool call should be closed after <CR>")
assert(not vim.api.nvim_win_is_valid(float_win), "Float window must be destroyed")
assert(vim.api.nvim_get_current_win() == vim.fn.bufwinid(test_buf), "Focus must return to parent window")

-- Test 'q' keymap inside window
vim.api.nvim_win_set_cursor(0, { tool_line_s + 1, 0 })
protocol.toggle_tool_at_cursor(test_buf)
assert(tc_short.is_open == true, "Tool window open again")
local float_win2 = tc_short.win
local win_buf = tc_short.win_buf
-- Trigger 'q' keymap callback
local keymaps = vim.api.nvim_buf_get_keymap(win_buf, "n")
local q_km = nil
for _, km in ipairs(keymaps) do
  if km.lhs == "q" then q_km = km end
end
assert(q_km ~= nil, "'q' keymap must be registered on inline window buffer")
q_km.callback()
assert(tc_short.is_open == false, "Window must be closed after 'q'")
assert(not vim.api.nvim_win_is_valid(float_win2), "Float window destroyed after 'q'")

-- Test cursor move in parent buffer closes window
vim.api.nvim_win_set_cursor(0, { tool_line_s + 1, 0 })
protocol.toggle_tool_at_cursor(test_buf)
assert(tc_short.is_open == true, "Tool window open")
-- Switch focus to parent and move cursor to prompt line
vim.api.nvim_set_current_win(vim.fn.bufwinid(test_buf))
vim.api.nvim_win_set_cursor(0, { prompt_line, 0 })
vim.cmd("doautocmd CursorMoved")
assert(tc_short.is_open == false, "Moving cursor to different line in parent must auto-close inline window")

protocol.cleanup_buffer(test_buf)
vim.cmd("bdelete! " .. test_buf)

print("✓ All keymaps, autofocus, and close behaviors verified!")

-- ---------------------------------------------------------------------------
-- TEST 5: Virtual Text Spacer Lines in Parent Buffer
-- ---------------------------------------------------------------------------
print("\n[Test 5] Testing empty virtual spacer lines in parent buffer...")

local test_buf_v = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(test_buf_v)
local pl_v, pe_v = render.render_new_session(test_buf_v, default_cfg)
protocol._setup_buffer(test_buf_v, "new")

local state_v = {
  buf = test_buf_v,
  config = default_cfg,
  prompt_start_line = pl_v,
  prompt_extmark_id = pe_v,
  tool_calls = {},
  stream_info = { status = "ready" },
}
protocol.buffers[test_buf_v] = state_v

local five_line_out = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
local tl_v, ext_v, _ = render.append_tool_call(test_buf_v, "view_file", { TargetFile = "spacer.txt" }, nil, default_cfg)
local tc_v = {
  id = 1,
  tool_name = "view_file",
  params = { TargetFile = "spacer.txt" },
  output = five_line_out,
  header_extmark_id = ext_v,
  header_line_idx = tl_v,
  status = "done",
  is_open = false,
}
table.insert(state_v.tool_calls, tc_v)
render.complete_tool_call(test_buf_v, tc_v, 0.1, five_line_out, default_cfg)

-- Add a subsequent line below the tool call to test push-down
vim.api.nvim_buf_set_lines(test_buf_v, -1, -1, false, { "Line below tool" })
local sub_line = vim.api.nvim_buf_line_count(test_buf_v)

-- Record screen position of the line below before opening
local parent_win_v = vim.fn.bufwinid(test_buf_v)
vim.cmd("redraw")
local sp_before = vim.fn.screenpos(parent_win_v, sub_line, 1)

-- Open inline window (height = 7 with padding)
vim.api.nvim_win_set_cursor(parent_win_v, { tl_v + 1, 0 })
protocol.toggle_tool_at_cursor(test_buf_v, parent_win_v)

assert(tc_v.is_open == true, "Tool must be open")
assert(tc_v.spacer_extmark_id ~= nil, "Spacer extmark must be created in buffer")
local float_cfg_v = vim.api.nvim_win_get_config(tc_v.win)
assert(float_cfg_v.height == 5, "Inline window must have height 5 (content-only, no padding lines inside)")

-- Verify spacer extmark has virt_lines containing actual output text and full-width background
local extmark_info = vim.api.nvim_buf_get_extmark_by_id(test_buf_v, render.NS_SPACER, tc_v.spacer_extmark_id, { details = true })
assert(extmark_info and extmark_info[3] and extmark_info[3].virt_lines, "Spacer extmark must contain virt_lines")
local v_lines = extmark_info[3].virt_lines
-- 5 content lines + 1 top empty line + 1 bottom empty line = 7 lines total
assert(#v_lines == 7, "Spacer must contain 7 virtual lines for 7-line window, got " .. #v_lines)

-- Line 1 is the virtual empty line on top (spans full width with AgyToolInline)
assert(v_lines[1][1][2] == "AgyToolInline", "Top virtual line must be highlighted with AgyToolInline")
assert(#v_lines[1][1][1] >= 80, "Top virtual line must extend full width with spaces")

-- Line 2 is the first content line (contains prefix pad, text with AgyToolOutput, and trailing pad)
local line2_chunks = v_lines[2]
assert(#line2_chunks >= 2, "Content virtual line must contain padding and text chunks")
local found_text = false
for _, chunk in ipairs(line2_chunks) do
  if chunk[1]:find("Line 1") then
    found_text = true
    assert(chunk[2] == "AgyToolOutput", "Tool text chunk must use AgyToolOutput highlight")
  else
    assert(chunk[2] == "AgyToolInline", "Padding chunk must use AgyToolInline highlight")
  end
end
assert(found_text, "Line 2 must contain 'Line 1' content text")

-- Line 7 is the virtual empty line on bottom (spans full width with AgyToolInline)
assert(v_lines[7][1][2] == "AgyToolInline", "Bottom virtual line must be highlighted with AgyToolInline")
assert(#v_lines[7][1][1] >= 80, "Bottom virtual line must extend full width with spaces")

-- Check that buffer lines below header were pushed down on screen by exactly 7 rows
vim.cmd("redraw")
local sp_during = vim.fn.screenpos(parent_win_v, sub_line, 1)
assert(sp_during.row == sp_before.row + 7, string.format("Lines below must be pushed down by 7 rows (before: %d, during: %d)", sp_before.row, sp_during.row))

-- Close inline window and verify spacer virtual lines are removed
render.close_tool_window(state_v, tc_v)
assert(tc_v.spacer_extmark_id == nil, "Spacer extmark ID must be reset to nil")

vim.cmd("redraw")
local sp_after = vim.fn.screenpos(parent_win_v, sub_line, 1)
assert(sp_after.row == sp_before.row, string.format("Lines below must snap back to original screen row (%d == %d)", sp_after.row, sp_before.row))

protocol.cleanup_buffer(test_buf_v)
vim.cmd("bdelete! " .. test_buf_v)
print("✓ Virtual spacer lines and screen push-down verified!")

-- ---------------------------------------------------------------------------
-- TEST 6: Multi-Window Split Opens Under Active Cursor Window
-- ---------------------------------------------------------------------------
print("\n[Test 6] Testing multi-window split: opens under active cursor window...")

local test_buf_m = vim.api.nvim_create_buf(false, false)
local win_left = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win_left, test_buf_m)
local pl_m, pe_m = render.render_new_session(test_buf_m, default_cfg)
protocol._setup_buffer(test_buf_m, "new")

local state_m = {
  buf = test_buf_m,
  config = default_cfg,
  prompt_start_line = pl_m,
  prompt_extmark_id = pe_m,
  tool_calls = {},
  stream_info = { status = "ready" },
}
protocol.buffers[test_buf_m] = state_m

local tl_m, ext_m, _ = render.append_tool_call(test_buf_m, "view_file", { TargetFile = "split.txt" }, nil, default_cfg)
local tc_m = {
  id = 1,
  tool_name = "view_file",
  params = { TargetFile = "split.txt" },
  output = "Split test output",
  header_extmark_id = ext_m,
  header_line_idx = tl_m,
  status = "done",
  is_open = false,
}
table.insert(state_m.tool_calls, tc_m)
render.complete_tool_call(test_buf_m, tc_m, 0.1, "Split test output", default_cfg)

-- Create a right vertical split displaying the same buffer
vim.cmd("vsplit")
local win_right = vim.api.nvim_get_current_win()
assert(win_left ~= win_right, "Must have two distinct windows for split test")
assert(vim.api.nvim_win_get_buf(win_left) == test_buf_m, "Left window displays test_buf_m")
assert(vim.api.nvim_win_get_buf(win_right) == test_buf_m, "Right window displays test_buf_m")

-- Position cursor in the right split on the tool header
vim.api.nvim_set_current_win(win_right)
vim.api.nvim_win_set_cursor(win_right, { tl_m + 1, 0 })

-- Trigger toggle without passing explicit target_win; must auto-detect win_right from active cursor
local m_opened = protocol.toggle_tool_at_cursor(test_buf_m)
assert(m_opened == true, "Must open tool inline window from right split")
assert(tc_m.is_open == true, "Tool must be open")
assert(tc_m.target_win == win_right, "Target window must be win_right, NOT win_left")

local m_win_cfg = vim.api.nvim_win_get_config(tc_m.win)
assert(m_win_cfg.win == win_right, "Floating window config must anchor to win_right (where cursor was)")

-- Close and ensure focus returns to win_right
protocol.toggle_tool_at_cursor(test_buf_m)
assert(tc_m.is_open == false, "Tool closed")
assert(vim.api.nvim_get_current_win() == win_right, "Focus must return to win_right")

-- Close the right split window
vim.api.nvim_win_close(win_right, true)
protocol.cleanup_buffer(test_buf_m)
vim.cmd("bdelete! " .. test_buf_m)

print("✓ Multi-window cursor detection verified (anchors to active window)!")

-- ---------------------------------------------------------------------------
-- TEST 7: trim_empty_lines helper and subtle background highlights
-- ---------------------------------------------------------------------------
print("\n[Test 7] Testing trim_empty_lines helper and subtle background highlights...")

-- Test trim_empty_lines
assert(vim.deep_equal(render.trim_empty_lines({}), {}), "Empty list should return empty")
assert(vim.deep_equal(render.trim_empty_lines({ "", "   ", "\t" }), {}), "Whitespace list should return empty")
assert(vim.deep_equal(render.trim_empty_lines({ "", "  \n", "foo", "  ", "bar", "\n", "" }), { "foo", "  ", "bar" }), "Leading and trailing empty lines trimmed, internal preserved")

-- Test highlights
render.setup_highlights()
local hl_inline = vim.api.nvim_get_hl(0, { name = "AgyToolInline", link = false })
assert(hl_inline and hl_inline.bg ~= nil, "AgyToolInline must have subtle bg color defined")

local hl_tool_out = vim.api.nvim_get_hl(0, { name = "AgyToolOutput", link = false })
assert(hl_tool_out and hl_tool_out.bg ~= nil, "AgyToolOutput must have subtle bg color defined")
assert(hl_tool_out.bg == hl_inline.bg, "AgyToolOutput bg must match AgyToolInline bg")

local hl_thought_out = vim.api.nvim_get_hl(0, { name = "AgyThoughtOutput", link = false })
assert(hl_thought_out and hl_thought_out.bg ~= nil, "AgyThoughtOutput must have subtle bg color defined")
assert(hl_thought_out.bg == hl_inline.bg, "AgyThoughtOutput bg must match AgyToolInline bg")
assert(hl_thought_out.italic == true, "AgyThoughtOutput must have italic = true")

print("✓ trim_empty_lines and subtle background highlights verified!")

-- ---------------------------------------------------------------------------
-- TEST 8: Always open details on running tools and empty output, live transition
-- ---------------------------------------------------------------------------
print("\n[Test 8] Testing always open details on running tools and live transition...")

local test_buf_8 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_win_set_buf(0, test_buf_8)
local p_line_8, p_ext_8 = render.render_new_session(test_buf_8, default_cfg)
protocol._setup_buffer(test_buf_8, "new")

local state_8 = {
  buf = test_buf_8,
  config = default_cfg,
  prompt_start_line = p_line_8,
  prompt_extmark_id = p_ext_8,
  tool_calls = {},
  stream_info = { status = "ready" },
}
protocol.buffers[test_buf_8] = state_8

-- 8a. Running tool with no output: opening details must succeed and show (Running...)
local tl_8, ext_8, _ = render.append_tool_call(test_buf_8, "run_command", { CommandLine = "sleep 2" }, nil, default_cfg)
local tc_run = {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "sleep 2" },
  output = nil,
  header_extmark_id = ext_8,
  header_line_idx = tl_8,
  status = "running",
  is_open = false,
}
table.insert(state_8.tool_calls, tc_run)

vim.api.nvim_win_set_cursor(0, { tl_8 + 1, 0 })
local opened_running = protocol.toggle_tool_at_cursor(test_buf_8)
assert(opened_running == true, "Must always open inline window for running tool call")
assert(tc_run.is_open == true, "Running tool must be marked open")
assert(tc_run.win and vim.api.nvim_win_is_valid(tc_run.win), "Window must be open")
local run_lines = vim.api.nvim_buf_get_lines(tc_run.win_buf, 0, -1, false)
assert(#run_lines == 1 and run_lines[1] == "(Running...)", "Window must show (Running...), got: " .. vim.inspect(run_lines))

-- 8b. Transition while open to synchronous completion: window refreshes immediately
render.complete_tool_call(test_buf_8, tc_run, 1.2, "Line 1\nLine 2\nLine 3\nexited with code 0", default_cfg)
assert(tc_run.is_open == true, "Window should remain open after completion")
local completed_lines = vim.api.nvim_buf_get_lines(tc_run.win_buf, 0, -1, false)
assert(#completed_lines >= 3, "Window must update with completed tool output, got " .. #completed_lines .. " lines")
assert(completed_lines[1] == "Line 1", "Line 1 updated")
local win_cur = vim.api.nvim_win_get_cursor(tc_run.win)
assert(win_cur[1] == #completed_lines, "run_command cursor must be positioned at bottom line")

-- Close window
protocol.toggle_tool_at_cursor(test_buf_8)
assert(tc_run.is_open == false, "Window closed")

-- 8c. Tool call completed with no output: opening details must show (No output) without error
local tl_empty, ext_empty, _ = render.append_tool_call(test_buf_8, "run_command", { CommandLine = "true" }, nil, default_cfg)
local tc_empty = {
  id = 2,
  tool_name = "run_command",
  params = { CommandLine = "true" },
  output = "",
  header_extmark_id = ext_empty,
  header_line_idx = tl_empty,
  status = "done",
  is_open = false,
}
table.insert(state_8.tool_calls, tc_empty)

vim.api.nvim_win_set_cursor(0, { tl_empty + 1, 0 })
local opened_empty = protocol.toggle_tool_at_cursor(test_buf_8)
assert(opened_empty == true, "Must open inline window for empty output tool call")
local empty_lines = vim.api.nvim_buf_get_lines(tc_empty.win_buf, 0, -1, false)
assert(#empty_lines == 1 and empty_lines[1] == "(No output)", "Window must show (No output), got: " .. vim.inspect(empty_lines))
protocol.toggle_tool_at_cursor(test_buf_8)

-- 8d. Running tool opened and then promoted to background task with live log streaming
local tmp_bg_log = vim.fn.tempname() .. ".log"
vim.fn.writefile({ "Starting compile..." }, tmp_bg_log)

local tl_bg, ext_bg, _ = render.append_tool_call(test_buf_8, "run_command", { CommandLine = "make" }, nil, default_cfg)
local tc_bg = {
  id = 3,
  tool_name = "run_command",
  params = { CommandLine = "make" },
  output = nil,
  header_extmark_id = ext_bg,
  header_line_idx = tl_bg,
  status = "running",
  is_open = false,
}
table.insert(state_8.tool_calls, tc_bg)

-- User opens details while still running (shows Running...)
vim.api.nvim_win_set_cursor(0, { tl_bg + 1, 0 })
protocol.toggle_tool_at_cursor(test_buf_8)
assert(tc_bg.is_open == true, "Open while running")

-- Now background promotion arrives
local bg_msg = "Tool is running as a background task with task id: test/task-bg\nTask logs are available at: " .. tmp_bg_log
render.complete_tool_call(test_buf_8, tc_bg, 0.5, bg_msg, default_cfg)

assert(tc_bg.is_background_task == true, "Promoted to background task")
assert(tc_bg.log_timer ~= nil, "Log watcher timer started immediately for open window")

-- Verify initial log line appeared in window
local bg_win_lines = vim.api.nvim_buf_get_lines(tc_bg.win_buf, 0, -1, false)
assert(bg_win_lines[1] == "Starting compile...", "Live log output appeared in open window: " .. vim.inspect(bg_win_lines))

-- Append another log line and verify live update
vim.fn.writefile({ "Starting compile...", "Compiled module 1", "Compile complete!" }, tmp_bg_log)
local stream_updated = vim.wait(1000, function()
  return vim.api.nvim_buf_line_count(tc_bg.win_buf) == 3
end, 50)
assert(stream_updated == true, "Window must update with streamed log lines in real time")

-- Cleanup
protocol.toggle_tool_at_cursor(test_buf_8)
protocol.cleanup_buffer(test_buf_8)
vim.fn.delete(tmp_bg_log)
vim.cmd("bdelete! " .. test_buf_8)
print("✓ Always open details on running tools and real-time background streaming verified!")

-- ---------------------------------------------------------------------------
-- TEST 9: Active tool call with stream footer: no double Running... and footer below
-- ---------------------------------------------------------------------------
print("\n[Test 9] Testing active tool with stream footer: single Running... and footer below...")

local test_buf_9 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_win_set_buf(0, test_buf_9)
local p_line_9, p_ext_9 = render.render_new_session(test_buf_9, default_cfg)
protocol._setup_buffer(test_buf_9, "new")

local state_9 = {
  buf = test_buf_9,
  config = default_cfg,
  prompt_start_line = p_line_9,
  prompt_extmark_id = p_ext_9,
  tool_calls = {},
  stream_info = {
    status = "tool:run_command",
    model = "gemini-3.8-flash-high",
    tool_count = 57,
    permission_mode = "always-proceed",
  },
}
protocol.buffers[test_buf_9] = state_9

-- Append thought block and running run_command
render.append_thought_block(test_buf_9, "Thinking about command", 3.1, default_cfg)
local tl_9, ext_9, _ = render.append_tool_call(test_buf_9, "run_command", { CommandLine = "1..5 | ForEach-Object { Write-Output 'Tick' }" }, nil, default_cfg)
local tc_active = {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "1..5 | ForEach-Object { Write-Output 'Tick' }" },
  output = nil,
  header_extmark_id = ext_9,
  header_line_idx = tl_9,
  status = "running",
  is_open = false,
}
table.insert(state_9.tool_calls, tc_active)

-- Display live footer on last_line (run_command)
protocol.update_footer(test_buf_9)
assert(state_9.footer_extmark_id ~= nil, "Footer extmark must be set")

-- User opens details while tool is running
vim.api.nvim_win_set_cursor(0, { tl_9 + 1, 0 })
local opened_9 = protocol.toggle_tool_at_cursor(test_buf_9)
assert(opened_9 == true, "Must open inline window for running command")
assert(tc_active.is_open == true, "Tool must be marked open")
assert(tc_active.win and vim.api.nvim_win_is_valid(tc_active.win), "Window must be valid")

vim.cmd("redraw")

-- Check floating window row: it must be on content line
local win_info_9 = vim.fn.getwininfo(vim.fn.bufwinid(test_buf_9))[1]
local f_sp = vim.fn.screenpos(tc_active.win, 1, 1)
local p_sp = vim.fn.screenpos(vim.fn.bufwinid(test_buf_9), tl_9 + 1, 1)

assert(p_sp and p_sp.row > 0, "Tool header must be visible")
assert(f_sp and f_sp.row > 0, "Floating window must be visible")

-- Floating window must be placed 2 rows below tool header (header row + 1 is top padding, header row + 2 is content)
assert(f_sp.row == p_sp.row + 2, string.format("Floating window row (%d) must be header row + 2 (%d)", f_sp.row, p_sp.row + 2))

-- Verify footer extmark is placed AFTER spacer virt_lines (footer row > float row)
local all_marks = vim.api.nvim_buf_get_extmarks(test_buf_9, render.NS_UI, 0, -1, { details = true })
local found_footer = false
for _, em in ipairs(all_marks) do
  if em[1] == state_9.footer_extmark_id then
    found_footer = true
  end
end
assert(found_footer == true, "Footer must be present")

-- Close window and verify clean collapse
protocol.toggle_tool_at_cursor(test_buf_9)
assert(tc_active.is_open == false, "Window closed")
protocol.cleanup_buffer(test_buf_9)
vim.cmd("bdelete! " .. test_buf_9)

print("✓ Active tool with stream footer alignment and single Running... verified!")

-- ---------------------------------------------------------------------------
-- TEST 10: Single (Running...) Display, Gravity Alignment & Wrapped Lines
-- ---------------------------------------------------------------------------
print("\n[Test 10] Testing single (Running...) display, extmark gravity alignment & wrapped lines...")

local test_buf_10 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_win_set_buf(0, test_buf_10)
local p_line_10, p_ext_10 = render.render_new_session(test_buf_10, default_cfg)
protocol._setup_buffer(test_buf_10, "new")

local state_10 = {
  buf = test_buf_10,
  config = default_cfg,
  prompt_start_line = p_line_10,
  prompt_extmark_id = p_ext_10,
  tool_calls = {},
  stream_info = {
    status = "tool:run_command",
    model = "gemini-3.8-flash-high",
    tool_count = 57,
    permission_mode = "always-proceed",
  },
}
protocol.buffers[test_buf_10] = state_10

local tl_10, ext_10, _ = render.append_tool_call(test_buf_10, "run_command", { CommandLine = "powershell -Command Start-Sleep -Seconds 10" }, nil, default_cfg)
local tc_10 = {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "powershell -Command Start-Sleep -Seconds 10" },
  output = nil,
  header_extmark_id = ext_10,
  header_line_idx = tl_10,
  status = "running",
  is_open = false,
}
table.insert(state_10.tool_calls, tc_10)

-- Update footer
protocol.update_footer(test_buf_10)
assert(state_10.footer_extmark_id ~= nil, "Footer extmark must be set")

-- Open inline tool window
vim.api.nvim_win_set_cursor(0, { tl_10 + 1, 0 })
local opened_10 = protocol.toggle_tool_at_cursor(test_buf_10)
assert(opened_10 == true, "Must open inline window for running command")
assert(tc_10.is_open == true, "Tool must be marked open")

-- Verify gravity ordering: spacer must have right_gravity = false, footer must have right_gravity = true
local spacer_marks_10 = vim.api.nvim_buf_get_extmarks(test_buf_10, render.NS_SPACER, 0, -1, { details = true })
assert(#spacer_marks_10 >= 1, "Spacer extmark must exist")
assert(spacer_marks_10[1][4].right_gravity == false, "Spacer extmark must have right_gravity = false so it renders before footer")

local ui_marks_10 = vim.api.nvim_buf_get_extmarks(test_buf_10, render.NS_UI, 0, -1, { details = true })
local footer_mark_10 = nil
for _, em in ipairs(ui_marks_10) do
  if em[1] == state_10.footer_extmark_id then
    footer_mark_10 = em
    break
  end
end
assert(footer_mark_10 ~= nil, "Footer extmark must exist")
assert(footer_mark_10[4].right_gravity == true, "Footer extmark must have right_gravity = true so it renders after spacer")

-- Verify floating window row aligns with top padding + 1
local cur_win_10 = vim.fn.bufwinid(test_buf_10)
local p_sp_10 = vim.fn.screenpos(cur_win_10, tl_10 + 1, 1)
local f_sp_10 = vim.fn.screenpos(tc_10.win, 1, 1)
assert(p_sp_10 and p_sp_10.row > 0, "Tool header must be visible on screen")
assert(f_sp_10 and f_sp_10.row > 0, "Floating window must be visible on screen")
assert(f_sp_10.row == p_sp_10.row + 2, string.format("Floating window row (%d) must be header row + 2 (%d)", f_sp_10.row, p_sp_10.row + 2))

-- Verify floating buffer text has (Running...)
local f_lines_10 = vim.api.nvim_buf_get_lines(tc_10.win_buf, 0, -1, false)
assert(#f_lines_10 == 1 and f_lines_10[1] == "(Running...)", "Floating window must display (Running...), got: " .. vim.inspect(f_lines_10))

-- Close tc_10 window
protocol.toggle_tool_at_cursor(test_buf_10)
assert(tc_10.is_open == false, "tc_10 window must be closed")

-- Test wrapped command line positioning:
-- Enable wrap and shrink window width to force wrapping of a long command
vim.wo[cur_win_10].wrap = true
local long_cmd = "run_command " .. string.rep("very_long_argument_to_force_line_wrapping_in_test ", 4)
local tl_wrap, ext_wrap, _ = render.append_tool_call(test_buf_10, "run_command", { CommandLine = long_cmd }, nil, default_cfg)
local tc_wrap = {
  id = 2,
  tool_name = "run_command",
  params = { CommandLine = long_cmd },
  output = "Wrapped output 1\nWrapped output 2",
  header_extmark_id = ext_wrap,
  header_line_idx = tl_wrap,
  status = "done",
  is_open = false,
}
table.insert(state_10.tool_calls, tc_wrap)
render.complete_tool_call(test_buf_10, tc_wrap, 0.5, "Wrapped output 1\nWrapped output 2", default_cfg)

-- Open wrapped tool window
vim.api.nvim_win_set_cursor(cur_win_10, { tl_wrap + 1, 0 })
local opened_wrap = protocol.toggle_tool_at_cursor(test_buf_10)
assert(opened_wrap == true, "Must open wrapped tool call inline window")
assert(tc_wrap.is_open == true, "Wrapped tool window must be open")

render.sync_tool_window_position(state_10, tc_wrap)

local wrap_line_str = vim.api.nvim_buf_get_lines(test_buf_10, tl_wrap, tl_wrap + 1, false)[1]
local sp_end_wrap = vim.fn.screenpos(cur_win_10, tl_wrap + 1, math.max(1, #wrap_line_str))
local f_sp_wrap = vim.fn.screenpos(tc_wrap.win, 1, 1)

assert(f_sp_wrap.row == sp_end_wrap.row + 2, string.format("Wrapped window row (%d) must align with sp_end.row + 2 (%d)", f_sp_wrap.row, sp_end_wrap.row + 2))


protocol.toggle_tool_at_cursor(test_buf_10)
protocol.cleanup_buffer(test_buf_10)
vim.cmd("bdelete! " .. test_buf_10)
print("✓ Single (Running...) display, extmark gravity alignment & wrapped lines verified!")

-- ---------------------------------------------------------------------------
-- TEST 11: Scroll Synchronization (WinScrolled) & Off-Screen Hiding
-- ---------------------------------------------------------------------------
print("\n[Test 11] Testing scroll synchronization (WinScrolled) and off-screen hiding...")

local test_buf_11 = vim.api.nvim_create_buf(false, false)
local test_win_11 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(test_win_11, test_buf_11)
vim.api.nvim_win_set_height(test_win_11, 20)

local p_line_11, p_ext_11 = render.render_new_session(test_buf_11, default_cfg)
protocol._setup_buffer(test_buf_11, "new")

local state_11 = {
  buf = test_buf_11,
  config = default_cfg,
  prompt_start_line = p_line_11,
  prompt_extmark_id = p_ext_11,
  tool_calls = {},
  stream_info = { status = "ready" },
}
protocol.buffers[test_buf_11] = state_11

-- Prepend lines before tool call so we can scroll upwards and downwards
local filler_lines = {}
for i = 1, 25 do
  table.insert(filler_lines, "Filler line before tool " .. i)
end
vim.api.nvim_buf_set_lines(test_buf_11, 0, 0, false, filler_lines)

-- Append tool call
local tl_11, ext_11, _ = render.append_tool_call(test_buf_11, "view_file", { TargetFile = "scroll_test.lua" }, nil, default_cfg)
local tc_scroll = {
  id = 1,
  tool_name = "view_file",
  params = { TargetFile = "scroll_test.lua" },
  output = "Scroll output line 1\nScroll output line 2\nScroll output line 3\nScroll output line 4",
  header_extmark_id = ext_11,
  header_line_idx = tl_11,
  status = "done",
  is_open = false,
}
table.insert(state_11.tool_calls, tc_scroll)
render.complete_tool_call(test_buf_11, tc_scroll, 0.2, tc_scroll.output, default_cfg)

-- Prepend more filler lines after tool call so buffer is long enough to scroll past it
local after_lines = {}
for i = 1, 30 do
  table.insert(after_lines, "Filler line after tool " .. i)
end
local cur_count_11 = vim.api.nvim_buf_line_count(test_buf_11)
vim.api.nvim_buf_set_lines(test_buf_11, cur_count_11, cur_count_11, false, after_lines)

-- Position view so tool call is in the middle of the 20-row window
local pos_info = vim.api.nvim_buf_get_extmark_by_id(test_buf_11, render.NS_UI, ext_11, {})
local actual_tool_row = pos_info[1]
local initial_topline = math.max(1, actual_tool_row + 1 - 8)
vim.fn.winrestview({ topline = initial_topline })

vim.api.nvim_win_set_cursor(test_win_11, { actual_tool_row + 1, 0 })
local opened_11 = protocol.toggle_tool_at_cursor(test_buf_11)
assert(opened_11 == true, "Must open tool inline window")
assert(tc_scroll.is_open == true, "Tool window must be marked open")
assert(tc_scroll.scroll_autocmd ~= nil, "tc.scroll_autocmd must be registered")

local init_cfg = vim.api.nvim_win_get_config(tc_scroll.win)
assert(init_cfg.hide == false or init_cfg.hide == nil, "Window must initially be visible")
local init_row = init_cfg.row

-- 11a. Scroll buffer down by 3 lines
vim.api.nvim_win_call(test_win_11, function()
  vim.fn.winrestview({ topline = initial_topline + 3 })
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = "*" })

local scrolled_cfg = vim.api.nvim_win_get_config(tc_scroll.win)
assert(scrolled_cfg.hide == false or scrolled_cfg.hide == nil, "Window must remain visible after small scroll")
assert(scrolled_cfg.row == init_row - 3, string.format("Floating window row (%d) must move up by 3 lines to match scroll (%d)", scrolled_cfg.row, init_row - 3))

-- 11b. Scroll buffer so tool header moves completely off-screen above the viewport
vim.api.nvim_win_call(test_win_11, function()
  vim.fn.winrestview({ topline = actual_tool_row + 1 + 10 })
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = "*" })

local hidden_cfg = vim.api.nvim_win_get_config(tc_scroll.win)
assert(hidden_cfg.hide == true, "Floating window must be hidden (hide = true) when tool header scrolls above viewport")

-- 11c. Scroll back into view
vim.api.nvim_win_call(test_win_11, function()
  vim.fn.winrestview({ topline = initial_topline })
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = "*" })

local restored_cfg = vim.api.nvim_win_get_config(tc_scroll.win)
assert(restored_cfg.hide == false or restored_cfg.hide == nil, "Floating window must unhide (hide = false) when scrolled back into view")
assert(restored_cfg.row == init_row, string.format("Floating window row (%d) must be restored to initial row (%d)", restored_cfg.row, init_row))

-- 11d. Scroll so tool moves off-screen below the viewport (topline 1, height 20 while tool is around line 27+)
vim.api.nvim_win_call(test_win_11, function()
  vim.fn.winrestview({ topline = 1 })
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = "*" })

local hidden_bottom_cfg = vim.api.nvim_win_get_config(tc_scroll.win)
assert(hidden_bottom_cfg.hide == true, "Floating window must be hidden when tool header is below viewport")

-- 11e. Restore view and close window cleanly
vim.api.nvim_win_call(test_win_11, function()
  vim.fn.winrestview({ topline = initial_topline })
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = "*" })
vim.api.nvim_win_set_cursor(test_win_11, { actual_tool_row + 1, 0 })
protocol.toggle_tool_at_cursor(test_buf_11)

assert(tc_scroll.is_open == false, "Window must be closed")
assert(tc_scroll.scroll_autocmd == nil, "Scroll autocmd must be deleted on close")

protocol.cleanup_buffer(test_buf_11)
vim.cmd("bdelete! " .. test_buf_11)
print("✓ Scroll synchronization (WinScrolled) and off-screen hiding verified!")

-- ---------------------------------------------------------------------------
-- TEST 12: Auto-scroll on <CR> to ensure details window + 1 extra line in view
-- ---------------------------------------------------------------------------
print("\n[Test 12] Testing auto-scroll on <CR> to keep details window and 1 extra line in view...")

local test_buf_12 = vim.api.nvim_create_buf(false, false)
local test_win_12 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(test_win_12, test_buf_12)
vim.api.nvim_win_set_height(test_win_12, 20)

local p_line_12, p_ext_12 = render.render_new_session(test_buf_12, default_cfg)
protocol._setup_buffer(test_buf_12, "new")

local state_12 = {
  buf = test_buf_12,
  config = default_cfg,
  prompt_start_line = p_line_12,
  prompt_extmark_id = p_ext_12,
  tool_calls = {},
  stream_info = { status = "ready" },
}
protocol.buffers[test_buf_12] = state_12

-- Add filler lines so tool call is on line 18, near bottom of 20-row window
local cur_lines_12 = vim.api.nvim_buf_line_count(test_buf_12)
local needed_fillers = math.max(0, 18 - cur_lines_12)
local filler_12 = {}
for i = 1, needed_fillers do
  table.insert(filler_12, "Filler line " .. i)
end
vim.api.nvim_buf_set_lines(test_buf_12, 0, 0, false, filler_12)

local tl_12, ext_12, _ = render.append_tool_call(test_buf_12, "run_command", { CommandLine = "echo scroll_test" }, nil, default_cfg)
local tool_out_12 = "out 1\nout 2\nout 3\nout 4\nout 5"
local tc_12 = {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "echo scroll_test" },
  output = tool_out_12,
  header_extmark_id = ext_12,
  header_line_idx = tl_12,
  status = "done",
  is_open = false,
}
table.insert(state_12.tool_calls, tc_12)
render.complete_tool_call(test_buf_12, tc_12, 0.3, tool_out_12, default_cfg)

-- Prepend lines below as well so buffer has content below
local below_lines = {}
for i = 1, 20 do
  table.insert(below_lines, "Below line " .. i)
end
local cur_c_12 = vim.api.nvim_buf_line_count(test_buf_12)
vim.api.nvim_buf_set_lines(test_buf_12, cur_c_12, cur_c_12, false, below_lines)

-- Position view at topline = 1
vim.fn.winrestview({ topline = 1 })
local pos_info_12 = vim.api.nvim_buf_get_extmark_by_id(test_buf_12, render.NS_UI, ext_12, {})
local actual_row_12 = pos_info_12[1]
local sp_before_12 = vim.fn.screenpos(test_win_12, actual_row_12 + 1, 1)
assert(sp_before_12.row >= 18, "Tool header must be near bottom before opening (row >= 18)")

-- Place cursor on tool call and toggle details
vim.api.nvim_win_set_cursor(test_win_12, { actual_row_12 + 1, 0 })
local opened_12 = protocol.toggle_tool_at_cursor(test_buf_12)
assert(opened_12 == true, "Must open tool inline window")
assert(tc_12.is_open == true, "Tool window must be marked open")

-- Verify auto-scroll occurred to fit the 5 content lines + pads + 1 extra line
local sp_after_12 = vim.fn.screenpos(test_win_12, actual_row_12 + 1, 1)
assert(sp_after_12.row < sp_before_12.row, string.format("Tool header screen row (%d) must have scrolled up from (%d)", sp_after_12.row, sp_before_12.row))

local win_cfg_12 = vim.api.nvim_win_get_config(tc_12.win)
local parent_h_12 = vim.api.nvim_win_get_height(test_win_12)
assert(win_cfg_12.height == 5, "Window height must be 5 lines, got " .. win_cfg_12.height)
-- Float occupies win_cfg_12.row .. win_cfg_12.row + 4 (5 lines)
-- Bottom padding is at win_cfg_12.row + 5
-- 1 extra line is at win_cfg_12.row + 6
-- In a parent window of height 20 (rows 0..19), win_cfg_12.row + 6 <= 19
assert(win_cfg_12.row + win_cfg_12.height + 1 < parent_h_12, string.format("Extra line at row %d must be strictly inside viewport height %d", win_cfg_12.row + win_cfg_12.height + 1, parent_h_12))

-- Close window cleanly
protocol.toggle_tool_at_cursor(test_buf_12)
assert(tc_12.is_open == false, "Window must be closed cleanly")

protocol.cleanup_buffer(test_buf_12)
vim.cmd("bdelete! " .. test_buf_12)
print("✓ Auto-scroll on <CR> to keep details window and 1 extra line in view verified!")

print("\nALL INLINE TOOL WINDOW TESTS PASSED PERFECTLY!")

