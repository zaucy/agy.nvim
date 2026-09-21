local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")

print("=== Running Scroll Bottom Virtual Text Tests ===")

require("agy").setup()

-- Helper function to check if footer extmark virt_lines fit in the window viewport
local function footer_virt_lines_fit(win, buf)
  local state = protocol.buffers[buf]
  assert(state, "Buffer state must exist")
  assert(state.footer_extmark_id, "footer_extmark_id must exist")

  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.footer_extmark_id, { details = true })
  assert(mark and mark[3] and mark[3].virt_lines, "Extmark must have virt_lines")
  local virt_count = #mark[3].virt_lines

  local fit = false
  local wl, win_h, last_vrow
  vim.api.nvim_win_call(win, function()
    win_h = vim.api.nvim_win_get_height(win)
    wl = vim.fn.winline()
    last_vrow = wl + virt_count
    fit = (last_vrow <= win_h)
  end)

  return fit, wl, win_h, last_vrow, virt_count
end

-- =========================================================================
-- TEST 1: 'G' to bottom automatically scrolls window so bottom virtual text shows up
-- =========================================================================
print("\n[Test 1] Testing 'G' to bottom scrolls window so virtual text is fully visible...")

vim.cmd("edit agy://new")
local buf1 = vim.api.nvim_get_current_buf()
local win1 = vim.api.nvim_get_current_win()
local state1 = protocol.buffers[buf1]
assert(state1, "State for buf1 must exist")

-- Populate conversation with 40 lines of history + prompt line
local lines1 = { "# Antigravity Session: agy://new", "" }
for i = 1, 40 do
  table.insert(lines1, "Turn " .. i .. ": some conversation message line")
end
table.insert(lines1, "")
table.insert(lines1, "") -- prompt input line at bottom

protocol.with_modifiable(buf1, function()
  vim.api.nvim_buf_set_lines(buf1, 0, -1, false, lines1)
  state1.prompt_start_line = #lines1
  protocol.update_prompt_divider(buf1)
  protocol.update_footer(buf1)
end)

vim.api.nvim_win_set_height(win1, 15)

-- Move cursor to top of buffer (line 1)
vim.api.nvim_win_set_cursor(win1, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
vim.cmd("redraw")

assert(state1.follow_bottom == false, "follow_bottom must be false at line 1")
assert(vim.api.nvim_win_get_cursor(win1)[1] == 1, "Cursor must be at line 1")

-- Simulate pressing 'G' to go to bottom
local lc1 = vim.api.nvim_buf_line_count(buf1)
vim.api.nvim_win_set_cursor(win1, { lc1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
vim.cmd("redraw")

local cur1 = vim.api.nvim_win_get_cursor(win1)
assert(cur1[1] == lc1, string.format("Cursor must be on bottom line (%d), found %d", lc1, cur1[1]))
assert(state1.follow_bottom == true, "follow_bottom must be true when cursor is at bottom")

local fits1, wl1, win_h1, last_vrow1, virt_count1 = footer_virt_lines_fit(win1, buf1)
assert(fits1, string.format("Virtual lines must fit in window! wl=%d, win_h=%d, last_vrow=%d, virt_count=%d", wl1, win_h1, last_vrow1, virt_count1))
print(string.format("✓ 'G' to bottom scrolls window so all %d virtual lines fit (cursor row %d, last virtual row %d / %d)", virt_count1, wl1, last_vrow1, win_h1))

-- =========================================================================
-- TEST 2: Idempotency: repeated CursorMoved at bottom does not jitter or re-scroll
-- =========================================================================
print("\n[Test 2] Testing repeated CursorMoved at bottom is idempotent and stable...")

local topline_before = vim.fn.winsaveview().topline
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
local topline_after1 = vim.fn.winsaveview().topline
assert(topline_after1 == topline_before, string.format("Topline must not change on duplicate CursorMoved: %d vs %d", topline_before, topline_after1))

-- Move column on bottom line (typing)
vim.api.nvim_win_set_cursor(win1, { lc1, 5 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
local topline_after2 = vim.fn.winsaveview().topline
assert(topline_after2 == topline_before, string.format("Topline must not change when moving col on bottom line: %d vs %d", topline_before, topline_after2))
print("✓ Repeated CursorMoved at bottom line is completely stable with zero jitter")

-- =========================================================================
-- TEST 3: Typing multi-line prompt at bottom maintains virtual text visibility
-- =========================================================================
print("\n[Test 3] Testing multi-line prompt typing at bottom scrolls to maintain footer visibility...")

-- Add 2 more lines to the prompt
protocol.with_modifiable(buf1, function()
  vim.api.nvim_buf_set_lines(buf1, lc1 - 1, -1, false, {
    "Prompt line 1",
    "Prompt line 2",
    "Prompt line 3",
  })
  protocol.update_prompt_divider(buf1)
  protocol.update_footer(buf1)
end)

local lc3 = vim.api.nvim_buf_line_count(buf1)
vim.api.nvim_win_set_cursor(win1, { lc3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
vim.cmd("redraw")

local fits3, wl3, win_h3, last_vrow3, virt_count3 = footer_virt_lines_fit(win1, buf1)
assert(fits3, string.format("Virtual lines must fit after typing multi-line prompt! wl=%d, win_h=%d, last_vrow=%d", wl3, win_h3, last_vrow3))
assert(vim.api.nvim_win_get_cursor(win1)[1] == lc3, "Cursor must remain on bottom line")
print(string.format("✓ Multi-line prompt maintains virtual text visibility (wl=%d, last_vrow=%d / %d)", wl3, last_vrow3, win_h3))

-- =========================================================================
-- TEST 4: Moving cursor up into history does not scroll or jump
-- =========================================================================
print("\n[Test 4] Testing moving cursor into history does not scroll or jump...")

-- Move cursor up into history (line 20)
vim.api.nvim_win_set_cursor(win1, { 20, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
vim.cmd("redraw")

assert(state1.follow_bottom == false, "follow_bottom must be false in history")
assert(vim.bo[buf1].modifiable == false, "Buffer must be non-modifiable in history")
local cur4 = vim.api.nvim_win_get_cursor(win1)
assert(cur4[1] == 20, string.format("Cursor must remain at line 20 in history, found %d", cur4[1]))
local topline_in_history = vim.fn.winsaveview().topline

-- Trigger CursorMoved again in history
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
assert(vim.fn.winsaveview().topline == topline_in_history, "Topline must remain stable in history")
assert(vim.api.nvim_win_get_cursor(win1)[1] == 20, "Cursor must remain at line 20")
print("✓ Navigation in history is smooth with no jumps or unwanted scrolling")

-- =========================================================================
-- TEST 5: Returning to bottom re-scrolls and shows virtual text
-- =========================================================================
print("\n[Test 5] Testing returning to bottom from history restores virtual text visibility...")

local lc5 = vim.api.nvim_buf_line_count(buf1)
vim.api.nvim_win_set_cursor(win1, { lc5, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
vim.cmd("redraw")

assert(state1.follow_bottom == true, "follow_bottom must be re-engaged at bottom")
assert(vim.bo[buf1].modifiable == true, "Buffer must be modifiable in prompt area")
local fits5, wl5, win_h5, last_vrow5, virt_count5 = footer_virt_lines_fit(win1, buf1)
assert(fits5, string.format("Virtual lines must fit after returning to bottom! wl=%d, win_h=%d, last_vrow=%d", wl5, win_h5, last_vrow5))
print("✓ Returning to bottom re-engages footer visibility and prompt modifiability")

-- =========================================================================
-- TEST 6: render.scroll_to_bottom ensures footer virtual text is visible
-- =========================================================================
print("\n[Test 6] Testing render.scroll_to_bottom ensures footer virtual text is visible...")

-- Reset prompt area to single clean line at bottom (standard turn state)
protocol.with_modifiable(buf1, function()
  vim.api.nvim_buf_set_lines(buf1, state1.prompt_start_line - 1, -1, false, { "" })
  state1.prompt_start_line = vim.api.nvim_buf_line_count(buf1)
  protocol.update_prompt_divider(buf1)
  protocol.update_footer(buf1)
end)
local cur_bottom = vim.api.nvim_buf_line_count(buf1)
vim.api.nvim_win_set_cursor(win1, { cur_bottom, 0 })
state1.follow_bottom = true

-- Stream text delta
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "More response streaming delta 1\nMore response streaming delta 2\n", state1.config)
  protocol.ensure_prompt_line(buf1)
  if state1.follow_bottom then
    render.scroll_to_bottom(buf1, true)
  end
  protocol.update_footer(buf1)
end)
vim.cmd("redraw")

local fits6, wl6, win_h6, last_vrow6, virt_count6 = footer_virt_lines_fit(win1, buf1)
assert(fits6, string.format("Virtual lines must fit after render.scroll_to_bottom! wl=%d, win_h=%d, last_vrow=%d", wl6, win_h6, last_vrow6))
assert(vim.api.nvim_win_get_cursor(win1)[1] >= state1.prompt_start_line, "Cursor must remain in prompt area")
print("✓ render.scroll_to_bottom keeps virtual text visible during streaming")

-- =========================================================================
-- TEST 7: Multi-window split isolation
-- =========================================================================
print("\n[Test 7] Testing multi-window split isolation: history window is unaffected...")

vim.cmd("vsplit")
local win1_split = vim.api.nvim_get_current_win()
assert(win1_split ~= win1, "win1_split must be distinct from win1")

-- Set win1_split cursor to line 5 in history
vim.api.nvim_win_set_cursor(win1_split, { 5, 0 })
local split_topline_before = vim.api.nvim_win_call(win1_split, function() return vim.fn.winsaveview().topline end)

-- Set active window back to win1
vim.api.nvim_set_current_win(win1)

-- Trigger ensure_bottom_visible on win1
render.ensure_bottom_visible(win1, buf1)

local split_cur_after = vim.api.nvim_win_get_cursor(win1_split)[1]
local split_topline_after = vim.api.nvim_win_call(win1_split, function() return vim.fn.winsaveview().topline end)
assert(split_cur_after == 5, string.format("Split cursor must stay at line 5, found %d", split_cur_after))
assert(split_topline_after == split_topline_before, "Split topline must be completely unaffected")
print("✓ Multi-window split isolation verified: history window cursor and scroll are undisturbed")

vim.api.nvim_win_close(win1_split, true)

-- =========================================================================
-- TEST 8: Small window constraint: cursor line is never pushed off top
-- =========================================================================
print("\n[Test 8] Testing small window constraint: cursor line is never pushed off screen...")

vim.api.nvim_win_set_height(win1, 2)
vim.cmd("redraw")

render.ensure_bottom_visible(win1, buf1)
local cur8 = vim.api.nvim_win_get_cursor(win1)
local wl8 = vim.api.nvim_win_call(win1, vim.fn.winline)
local view8 = vim.api.nvim_win_call(win1, vim.fn.winsaveview)

assert(view8.topline <= cur8[1], string.format("topline (%d) must not exceed cur_line (%d)", view8.topline, cur8[1]))
assert(wl8 >= 1, string.format("winline must be at least 1, got %d", wl8))
print(string.format("✓ Small window (height=2): cursor row %d, topline %d <= cur_line %d", wl8, view8.topline, cur8[1]))

-- Reset height
vim.api.nvim_win_set_height(win1, 15)

-- =========================================================================
-- TEST 9: normal! G execution from history to bottom
-- =========================================================================
print("\n[Test 9] Testing normal! G execution from history correctly positions and reveals virtual text...")

vim.api.nvim_win_set_cursor(win1, { 1, 0 })
vim.cmd("redraw")
assert(vim.api.nvim_win_get_cursor(win1)[1] == 1, "Must be at line 1")

vim.cmd("normal! G")
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf1 })
vim.cmd("redraw")

local cur9 = vim.api.nvim_win_get_cursor(win1)
local lc9 = vim.api.nvim_buf_line_count(buf1)
assert(cur9[1] == lc9, string.format("Cursor must be on bottom line %d, found %d", lc9, cur9[1]))
local fits9, wl9, win_h9, last_vrow9, virt_count9 = footer_virt_lines_fit(win1, buf1)
assert(fits9, string.format("Virtual lines must fit after normal! G: wl=%d, win_h=%d, last_vrow=%d", wl9, win_h9, last_vrow9))
print(string.format("✓ normal! G reveals all %d virtual lines at rows %d..%d in window height %d", virt_count9, wl9 + 1, last_vrow9, win_h9))

-- Clean up buf1
protocol.cleanup_buffer(buf1)
vim.cmd("bwipeout! " .. buf1)

-- =========================================================================
-- TEST 10: Gutter margins (signcolumn + number) with wrapped prompt line
-- =========================================================================
print("\n[Test 10] Testing gutters (signcolumn + number) with wrapped prompt line...")

vim.cmd("edit agy://new")
local buf10 = vim.api.nvim_get_current_buf()
local win10 = vim.api.nvim_get_current_win()
local state10 = protocol.buffers[buf10]
assert(state10, "State for buf10 must exist")

vim.wo[win10].signcolumn = "yes"
vim.wo[win10].number = true
vim.wo[win10].wrap = true
vim.api.nvim_win_set_width(win10, 80)
vim.api.nvim_win_set_height(win10, 15)

local win_info = vim.fn.getwininfo(win10)[1]
local text_width = win_info.width - win_info.textoff
-- Create prompt line that wraps by 1 char beyond text_width
local wrapped_prompt_text = string.rep("x", text_width + 1)

local lines10 = {}
for i = 1, 30 do
  table.insert(lines10, "Line " .. i)
end
table.insert(lines10, wrapped_prompt_text)

protocol.with_modifiable(buf10, function()
  vim.api.nvim_buf_set_lines(buf10, 0, -1, false, lines10)
  state10.prompt_start_line = #lines10
  protocol.update_prompt_divider(buf10)
  protocol.update_footer(buf10)
end)

local lc10 = vim.api.nvim_buf_line_count(buf10)
vim.api.nvim_win_set_cursor(win10, { lc10, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf10 })
vim.cmd("redraw")

local fits10, wl10, win_h10, last_vrow10, virt_count10 = footer_virt_lines_fit(win10, buf10)
assert(fits10, string.format("Virtual lines must fit with gutter line wrap: wl=%d, win_h=%d, last_vrow=%d", wl10, win_h10, last_vrow10))
print(string.format("✓ Gutter line wrap fits virtual lines cleanly (wl=%d, last_vrow=%d / %d)", wl10, last_vrow10, win_h10))

-- Clean up buf10
protocol.cleanup_buffer(buf10)
vim.cmd("bwipeout! " .. buf10)

-- =========================================================================
-- TEST 11: History wrapped lines at topline do not over-scroll or jump
-- =========================================================================
print("\n[Test 11] Testing wrapped lines in history at topline do not over-scroll...")

vim.cmd("edit agy://new")
local buf11 = vim.api.nvim_get_current_buf()
local win11 = vim.api.nvim_get_current_win()
local state11 = protocol.buffers[buf11]
assert(state11, "State for buf11 must exist")

vim.wo[win11].signcolumn = "no"
vim.wo[win11].number = false
vim.wo[win11].wrap = true
vim.api.nvim_win_set_width(win11, 50)
vim.api.nvim_win_set_height(win11, 15)

-- Line 1 is a long wrapped line (6 wrap rows)
local long_history_line = string.rep("long text line with many words in it ", 10)
local lines11 = { long_history_line }
for i = 2, 8 do
  table.insert(lines11, "Line " .. i)
end
table.insert(lines11, "")

protocol.with_modifiable(buf11, function()
  vim.api.nvim_buf_set_lines(buf11, 0, -1, false, lines11)
  state11.prompt_start_line = #lines11
  protocol.update_prompt_divider(buf11)
  protocol.update_footer(buf11)
end)

local lc11 = vim.api.nvim_buf_line_count(buf11)
vim.api.nvim_win_set_cursor(win11, { lc11, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf11 })
vim.cmd("redraw")

local view11 = vim.fn.winsaveview()
local fits11, wl11, win_h11, last_vrow11, virt_count11 = footer_virt_lines_fit(win11, buf11)
assert(fits11, "Virtual lines must fit")
assert(view11.topline == 2, string.format("Topline must be 2 (stopped immediately after freeing wrapped line 1), got %d", view11.topline))
assert(wl11 >= 9, string.format("Cursor row must not jump excessively; expected >= 9, got %d", wl11))
print(string.format("✓ Wrapped lines at topline handled smoothly: topline=%d, wl=%d, last_vrow=%d / %d", view11.topline, wl11, last_vrow11, win_h11))

-- Clean up buf11
protocol.cleanup_buffer(buf11)
vim.cmd("bwipeout! " .. buf11)

print("\nALL SCROLL BOTTOM VIRTUAL TEXT TESTS PASSED PERFECTLY!")
