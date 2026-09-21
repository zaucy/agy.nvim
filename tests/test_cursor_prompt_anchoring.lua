local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")

print("=== Running Comprehensive Cursor & Prompt Anchoring Tests ===")

require("agy").setup()

-- =========================================================================
-- TEST 1: Upon prompt submission, cursor is placed in restored prompt input area
-- =========================================================================
print("\n[Test 1] Testing prompt submission places cursor in restored prompt input area...")

vim.cmd("edit agy://new")
local buf1 = vim.api.nvim_get_current_buf()
local win1 = vim.api.nvim_get_current_win()
local state1 = protocol.buffers[buf1]
assert(state1, "State for buf1 must exist")

-- Type initial prompt
vim.api.nvim_buf_set_lines(buf1, state1.prompt_start_line - 1, -1, false, { "Explain architecture" })
vim.api.nvim_win_set_cursor(win1, { state1.prompt_start_line, 5 })

-- Trigger submission via write
vim.cmd("write")
assert(state1.follow_bottom == true, "state.follow_bottom must be true after submission")

-- Allow scheduled restore_prompt_area to execute
vim.wait(100, function()
  return state1.prompt_extmark_id ~= nil
end)

assert(state1.prompt_extmark_id ~= nil, "prompt_extmark_id must be restored after submission")
assert(state1.prompt_start_line > 1, "prompt_start_line must be restored at bottom of buffer")

local cur1 = vim.api.nvim_win_get_cursor(win1)
assert(cur1[1] == state1.prompt_start_line, string.format("Cursor must be at prompt_start_line (%d), found: %d", state1.prompt_start_line, cur1[1]))
assert(cur1[2] == 0, string.format("Cursor column must be 0 in restored prompt line, found: %d", cur1[2]))
assert(state1.follow_bottom == true, "state.follow_bottom must remain true in restored prompt area")
assert(vim.bo[buf1].modifiable == true, "Buffer must be modifiable when cursor is in restored prompt area")
print("✓ Upon prompt submission, cursor is placed in restored prompt input area and modifiable is true")

-- =========================================================================
-- TEST 2: Incoming streaming deltas, thoughts, and tools maintain cursor in prompt area
-- =========================================================================
print("\n[Test 2] Testing incoming streaming output maintains cursor anchored in prompt area...")

-- 2a. Thought block arrives
local p_start_before_thought = state1.prompt_start_line
protocol.with_modifiable(buf1, function()
  local tc_rec = render.append_thought_block(buf1, "Thinking about system architecture...", 1.5, state1.config)
  tc_rec.id = #state1.tool_calls + 1
  table.insert(state1.tool_calls, tc_rec)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_after_thought = vim.api.nvim_win_get_cursor(win1)
assert(state1.prompt_start_line > p_start_before_thought, "prompt_start_line must shift down when thought is inserted above")
assert(cur_after_thought[1] == state1.prompt_start_line, string.format("Cursor must track prompt_start_line (%d), found: %d", state1.prompt_start_line, cur_after_thought[1]))
print("✓ Thought block pushes prompt down and cursor tracks prompt_start_line")

-- 2b. Tool call arrives
local p_start_before_tool = state1.prompt_start_line
protocol.with_modifiable(buf1, function()
  local tl, eid, pstr = render.append_tool_call(buf1, "run_command", { CommandLine = "ls" }, vim.fn.getcwd(), state1.config)
  local tool_rec = {
    id = #state1.tool_calls + 1,
    tool_name = "run_command",
    header_extmark_id = eid,
    header_line_idx = tl,
  }
  table.insert(state1.tool_calls, tool_rec)
  state1.active_tool_record = tool_rec
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_after_tool = vim.api.nvim_win_get_cursor(win1)
assert(state1.prompt_start_line > p_start_before_tool, "prompt_start_line must shift down when tool call is inserted")
assert(cur_after_tool[1] == state1.prompt_start_line, string.format("Cursor must track prompt_start_line (%d), found: %d", state1.prompt_start_line, cur_after_tool[1]))
print("✓ Tool call pushes prompt down and cursor tracks prompt_start_line")

-- 2c. Tool completes
protocol.with_modifiable(buf1, function()
  render.complete_tool_call(buf1, state1.active_tool_record, 0.4, "file1.txt\nfile2.txt", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)
state1.active_tool_record = nil

local cur_after_comp = vim.api.nvim_win_get_cursor(win1)
assert(cur_after_comp[1] == state1.prompt_start_line, "Cursor must remain at prompt_start_line after tool completion")
print("✓ Tool completion preserves cursor at prompt_start_line")

-- 2d. Multi-line text deltas arrive
local p_start_before_delta = state1.prompt_start_line
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "Here is the response.\nLine 2 of response.\nLine 3 of response.\n", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_after_delta = vim.api.nvim_win_get_cursor(win1)
assert(state1.prompt_start_line > p_start_before_delta, "prompt_start_line must shift down when text delta arrives")
assert(cur_after_delta[1] == state1.prompt_start_line, string.format("Cursor must track prompt_start_line (%d), found: %d", state1.prompt_start_line, cur_after_delta[1]))
assert(state1.follow_bottom == true, "state.follow_bottom must remain true during streaming")
print("✓ Multi-line text delta correctly pushes prompt down and cursor tracks prompt_start_line")

-- =========================================================================
-- TEST 3: Cursor column and multi-line prompt position are preserved
-- =========================================================================
print("\n[Test 3] Testing cursor column and position within prompt area are preserved during streaming...")

-- User types 2 lines into prompt area while turn is active
local p_start3 = state1.prompt_start_line
vim.api.nvim_buf_set_lines(buf1, p_start3 - 1, -1, false, { "User question first line", "User question second line" })
protocol.update_prompt_divider(buf1)
protocol.update_footer(buf1)

-- Place cursor on line 1 of prompt at column 10
vim.api.nvim_win_set_cursor(win1, { p_start3, 10 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
assert(state1.follow_bottom == true, "follow_bottom must be true when cursor is on first line of prompt area")

-- Stream incoming text delta (inserts lines in agent area above prompt)
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "Another streaming line 1\nAnother streaming line 2\n", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_after_p1 = vim.api.nvim_win_get_cursor(win1)
assert(cur_after_p1[1] == state1.prompt_start_line, string.format("Cursor must remain on line 1 of prompt area (%d), found: %d", state1.prompt_start_line, cur_after_p1[1]))
assert(cur_after_p1[2] == 10, string.format("Cursor column 10 must be preserved, found: %d", cur_after_p1[2]))
print("✓ Cursor on line 1 of prompt area preserves column 10 during streaming (not wiped to 0)")

-- Now place cursor on line 2 of prompt at column 7
vim.api.nvim_win_set_cursor(win1, { state1.prompt_start_line + 1, 7 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
assert(state1.follow_bottom == true, "follow_bottom must be true when cursor is on second line of prompt area")

-- Stream more text
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "More streaming text\n", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_after_p2 = vim.api.nvim_win_get_cursor(win1)
assert(cur_after_p2[1] == state1.prompt_start_line + 1, string.format("Cursor must remain on line 2 of prompt area (%d), found: %d", state1.prompt_start_line + 1, cur_after_p2[1]))
assert(cur_after_p2[2] == 7, string.format("Cursor column 7 must be preserved, found: %d", cur_after_p2[2]))
print("✓ Cursor on line 2 of prompt area preserves column 7 during streaming")

-- =========================================================================
-- TEST 4: Moving cursor out of prompt area disengages follow_bottom
-- =========================================================================
print("\n[Test 4] Testing moving cursor into history disengages follow_bottom and keeps cursor in history...")

-- User intentionally moves cursor up to line 1 to read history
vim.api.nvim_win_set_cursor(win1, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })

assert(state1.follow_bottom == false, "state.follow_bottom must become FALSE when user moves cursor above prompt_start_line")
assert(vim.bo[buf1].modifiable == false, "Buffer must be nomodifiable when cursor is in history")

-- Stream more text delta while user is browsing history
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "History browsing delta 1\nHistory browsing delta 2\n", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_in_history = vim.api.nvim_win_get_cursor(win1)
assert(cur_in_history[1] == 1, string.format("Cursor must NOT be yanked to bottom when follow_bottom is false; found line %d", cur_in_history[1]))
print("✓ Cursor remains in history at line 1 during streaming while follow_bottom is false")

-- =========================================================================
-- TEST 5: Moving cursor back into prompt area re-engages follow_bottom
-- =========================================================================
print("\n[Test 5] Testing moving cursor back into prompt area re-engages follow_bottom...")

-- User returns to prompt area
local current_prompt_line = state1.prompt_start_line
vim.api.nvim_win_set_cursor(win1, { current_prompt_line, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })

assert(state1.follow_bottom == true, "state.follow_bottom must become TRUE when cursor re-enters prompt area")
assert(vim.bo[buf1].modifiable == true, "Buffer must become modifiable when cursor re-enters prompt area")

-- Stream text delta now that follow_bottom is re-engaged
local p_start_before_reengage = state1.prompt_start_line
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "Delta after re-engage\n", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_after_reengage = vim.api.nvim_win_get_cursor(win1)
assert(cur_after_reengage[1] == state1.prompt_start_line, "Cursor must track prompt_start_line once follow_bottom is re-engaged")
print("✓ Returning to prompt area re-engages follow_bottom and anchors cursor to prompt line")

-- =========================================================================
-- TEST 6: Queueing prompt while turn is active maintains cursor in prompt area
-- =========================================================================
print("\n[Test 6] Testing queueing prompt while turn is active maintains cursor in prompt area...")

state1.session.turn_active = true
vim.api.nvim_buf_set_lines(buf1, state1.prompt_start_line - 1, -1, false, { "Queued question to be executed next" })
protocol.update_prompt_divider(buf1)

-- Trigger queueing via write (<C-s> or :w)
vim.cmd("write")

assert(state1.prompt_queue and #state1.prompt_queue == 1, "Prompt must be queued in prompt_queue")
local cur_after_queue = vim.api.nvim_win_get_cursor(win1)
assert(cur_after_queue[1] == state1.prompt_start_line, string.format("Cursor must be placed on new prompt input line (%d), found: %d", state1.prompt_start_line, cur_after_queue[1]))
assert(cur_after_queue[2] == 0, "Cursor col must be 0 on clean prompt line")
assert(state1.follow_bottom == true, "follow_bottom must be true after queueing")
assert(vim.bo[buf1].modifiable == true, "Buffer must be modifiable for typing next queued message")
print("✓ Queueing prompt maintains cursor in restored prompt input line with follow_bottom true")

-- =========================================================================
-- TEST 7: Turn completion (on_result) preserves cursor in prompt area
-- =========================================================================
print("\n[Test 7] Testing turn completion preserves cursor in prompt area...")

-- User types something into prompt area while waiting for turn to finish
vim.api.nvim_buf_set_lines(buf1, state1.prompt_start_line - 1, -1, false, { "Thinking of next prompt" })
vim.api.nvim_win_set_cursor(win1, { state1.prompt_start_line, 8 })
state1.session.turn_active = false
state1.prompt_queue = nil

-- Call real session.on_result callback
state1.session.on_result(state1.session, { status = "DONE", duration_seconds = 2.0 })

local cur_after_res = vim.api.nvim_win_get_cursor(win1)
assert(cur_after_res[1] == state1.prompt_start_line, "Cursor must remain at prompt_start_line on turn completion")
assert(cur_after_res[2] == 8, string.format("Cursor column 8 must be preserved on turn completion, found: %d", cur_after_res[2]))
print("✓ Turn completion preserves user cursor line and column in prompt area")

-- =========================================================================
-- TEST 8: Multi-window split cursor isolation during streaming
-- =========================================================================
print("\n[Test 8] Testing multi-window split cursor isolation during streaming...")

vim.cmd("vsplit")
local win1_split = vim.api.nvim_get_current_win()
assert(win1_split ~= win1, "win1_split and win1 must be separate windows")

-- Move win1_split cursor up to line 1 to browse history
vim.api.nvim_win_set_cursor(win1_split, { 1, 0 })

-- win1 remains focused on prompt area
vim.api.nvim_set_current_win(win1)
assert(vim.api.nvim_win_get_cursor(win1)[1] == state1.prompt_start_line, "win1 must be in prompt area")
assert(vim.api.nvim_win_get_cursor(win1_split)[1] == 1, "win1_split must be at line 1 in history")

-- Set turn active and follow_bottom true for win1
state1.follow_bottom = true
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "More streaming text delta\n", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)

local cur_split_after = vim.api.nvim_win_get_cursor(win1_split)[1]
assert(cur_split_after == 1, string.format("win1_split cursor must NOT be yanked from line 1; found line %d", cur_split_after))
local cur_win1_after = vim.api.nvim_win_get_cursor(win1)[1]
assert(cur_win1_after == state1.prompt_start_line, "win1 cursor must remain anchored to prompt_start_line")
print("✓ Multi-window split isolation verified: history window cursor is never yanked")

-- Close split window
vim.api.nvim_win_close(win1_split, true)

protocol.cleanup_buffer(buf1)
vim.cmd("bwipeout! " .. buf1)

-- =========================================================================
-- TEST 9: config.ui.auto_scroll = false contract
-- =========================================================================
print("\n[Test 9] Testing config.ui.auto_scroll = false contract...")

require("agy").setup({ ui = { auto_scroll = false } })

vim.cmd("edit agy://new")
local buf_no_scroll = vim.api.nvim_get_current_buf()
local win_no_scroll = vim.api.nvim_get_current_win()
local state_no_scroll = protocol.buffers[buf_no_scroll]
assert(state_no_scroll, "State for buf_no_scroll must exist")

-- Type initial prompt and submit
state_no_scroll.session.turn_active = false
vim.api.nvim_buf_set_lines(buf_no_scroll, state_no_scroll.prompt_start_line - 1, -1, false, { "Test query no scroll" })
vim.cmd("write")
vim.wait(100, function() return state_no_scroll.prompt_extmark_id ~= nil end)

-- With auto_scroll = false, follow_bottom must be false
assert(state_no_scroll.follow_bottom == false, "follow_bottom must be false when auto_scroll = false")

-- Move cursor to line 1
vim.api.nvim_win_set_cursor(win_no_scroll, { 1, 0 })

-- Stream deltas
protocol.with_modifiable(buf_no_scroll, function()
  render.append_text_delta(buf_no_scroll, "Streaming delta with auto_scroll=false\n", state_no_scroll.config)
  protocol.ensure_prompt_line(buf_no_scroll)
  if state_no_scroll.follow_bottom then
    render.scroll_to_bottom(buf_no_scroll, true)
  end
  protocol.update_footer(buf_no_scroll)
end)

local cur_no_scroll = vim.api.nvim_win_get_cursor(win_no_scroll)[1]
assert(cur_no_scroll == 1, string.format("Cursor must stay at line 1 when auto_scroll is false, got line %d", cur_no_scroll))
print("✓ auto_scroll = false never moves cursor or forces follow_bottom")

protocol.cleanup_buffer(buf_no_scroll)
vim.cmd("bwipeout! " .. buf_no_scroll)

-- =========================================================================
-- TEST 10: Rapid cursor movement out of prompt during active streaming
-- =========================================================================
print("\n[Test 10] Testing rapid cursor movement out of prompt during active streaming...")

require("agy").setup({ ui = { auto_scroll = true } })

vim.cmd("edit agy://new")
local buf_rapid = vim.api.nvim_get_current_buf()
local win_rapid = vim.api.nvim_get_current_win()
local state_rapid = protocol.buffers[buf_rapid]
assert(state_rapid, "State for buf_rapid must exist")

vim.api.nvim_buf_set_lines(buf_rapid, state_rapid.prompt_start_line - 1, -1, false, { "Rapid navigation test" })
vim.cmd("write")
vim.wait(100, function() return state_rapid.prompt_extmark_id ~= nil end)
assert(state_rapid.follow_bottom == true, "follow_bottom should initially be true")

-- User rapidly navigates to line 2 (in history)
vim.api.nvim_win_set_cursor(win_rapid, { 2, 0 })

-- Streaming delta arrives immediately (before CursorMoved callback can run)
protocol.with_modifiable(buf_rapid, function()
  render.append_text_delta(buf_rapid, "Rapid streaming delta 1\n", state_rapid.config)
  protocol.ensure_prompt_line(buf_rapid)
  if state_rapid.follow_bottom then
    render.scroll_to_bottom(buf_rapid, true)
  end
  protocol.update_footer(buf_rapid)
end)

local cur_rapid = vim.api.nvim_win_get_cursor(win_rapid)[1]
assert(cur_rapid == 2, string.format("Cursor must remain at line 2 in history, got line %d", cur_rapid))
assert(state_rapid.follow_bottom == false, "follow_bottom must immediately disengage when active window leaves prompt area")
print("✓ Rapid movement out of prompt immediately disengages follow_bottom without yanking cursor")

protocol.cleanup_buffer(buf_rapid)
vim.cmd("bwipeout! " .. buf_rapid)

print("\nALL CURSOR & PROMPT ANCHORING TESTS PASSED PERFECTLY!")
