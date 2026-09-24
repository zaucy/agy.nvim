local utils = require("agy.utils")
local render = require("agy.render")
local protocol = require("agy.protocol")
local config_mod = require("agy.config")

print("=== Running Collapsible Work Groups Tests ===")

-- =========================================================================
-- TEST 1: Configuration, defaults, and assertions
-- =========================================================================
print("\n[Test 1] Testing configuration defaults and assertions...")

local cfg = config_mod.setup()
assert(cfg.icons.work_collapsed == "▶", "Default work_collapsed icon should be '▶'")
assert(cfg.icons.work_expanded == "▼", "Default work_expanded icon should be '▼'")
assert(cfg.ui.collapse_work == true, "Default ui.collapse_work should be true")

-- Test type check assertion on collapse_work
local ok_bad, err_bad = pcall(function()
  config_mod.setup({ ui = { collapse_work = "not-a-bool" } })
end)
assert(not ok_bad, "Expected assertion failure when ui.collapse_work is not a boolean")
assert(err_bad:find("'ui.collapse_work' must be a boolean"), "Error message should mention boolean: " .. tostring(err_bad))

-- Test assertion on missing work icons
local broken_cfg = { icons = {} }
local ok_missing, err_missing = pcall(function()
  render.format_work_summary_header({ items = {} }, false, broken_cfg)
end)
assert(not ok_missing, "Expected assertion failure when work_collapsed icon is missing")
assert(err_missing:find("icon 'work_collapsed' is not defined"), "Error message should mention missing work_collapsed: " .. tostring(err_missing))

print("✓ Configuration defaults, validation, and fail-fast assertions verified")

-- =========================================================================
-- TEST 2: format_work_summary_header formatting
-- =========================================================================
print("\n[Test 2] Testing format_work_summary_header...")

local group_tools = {
  duration_seconds = 4.2,
  items = {
    { tool_name = "view_file" },
    { tool_name = "replace_file_content" },
    { tool_name = "run_command" },
  }
}
local hdr_col = render.format_work_summary_header(group_tools, false, cfg)
assert(hdr_col == "▶ Worked for 4.2s (3 tools)", "Expected '▶ Worked for 4.2s (3 tools)', got: " .. hdr_col)

local hdr_exp = render.format_work_summary_header(group_tools, true, cfg)
assert(hdr_exp == "▼ Worked for 4.2s (3 tools)", "Expected '▼ Worked for 4.2s (3 tools)', got: " .. hdr_exp)

local group_mixed = {
  duration_seconds = 1.8,
  items = {
    { is_thought = true, tool_name = "Thought" },
    { tool_name = "view_file" },
  }
}
local hdr_mixed = render.format_work_summary_header(group_mixed, false, cfg)
assert(hdr_mixed == "▶ Worked for 1.8s (1 thought, 1 tool)", "Expected '▶ Worked for 1.8s (1 thought, 1 tool)', got: " .. hdr_mixed)

local group_single_tool = {
  duration_seconds = 0.5,
  items = {
    { tool_name = "run_command" },
  }
}
local hdr_single = render.format_work_summary_header(group_single_tool, false, cfg)
assert(hdr_single == "▶ Worked for 0.5s (1 tool)", "Expected '▶ Worked for 0.5s (1 tool)', got: " .. hdr_single)

local group_single_thought = {
  duration_seconds = 0.2,
  items = {
    { is_thought = true, tool_name = "Thought" },
  }
}
local hdr_th = render.format_work_summary_header(group_single_thought, false, cfg)
assert(hdr_th == "▶ Worked for 0.2s (1 thought)", "Expected '▶ Worked for 0.2s (1 thought)', got: " .. hdr_th)

print("✓ format_work_summary_header item breakdown and duration formatting verified")

-- =========================================================================
-- TEST 3: In-place buffer collapse and expansion
-- =========================================================================
print("\n[Test 3] Testing in-place buffer collapse and expansion...")

local buf = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf, cfg)

local th_rec = render.append_thought_block(buf, "Thinking about code...", 0.5, cfg)
local tl_line, tl_ext, p_str = render.append_tool_call(buf, "view_file", { AbsolutePath = "main.lua" }, nil, cfg)
local tl_rec = {
  id = 1,
  tool_name = "view_file",
  params = { AbsolutePath = "main.lua" },
  param_str = p_str,
  duration_seconds = 0.8,
  output = "local x = 1",
  header_extmark_id = tl_ext,
  header_line_idx = tl_line,
}
render.complete_tool_call(buf, tl_rec, 0.8, "local x = 1", cfg)

local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Buffer lines before collapse:")
for i, l in ipairs(lines_before) do
  print(string.format("  [%d] %s", i, l))
end

local work_group = {
  id = 1,
  is_open = true,
  duration_seconds = 1.3,
  items = { th_rec, tl_rec },
}

-- 3a. Collapse in-place
render.collapse_work_group_in_place(buf, work_group, cfg)
local lines_collapsed = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Buffer lines after collapse:")
for i, l in ipairs(lines_collapsed) do
  print(string.format("  [%d] %s", i, l))
end

assert(work_group.is_open == false, "Group should be marked closed")
local found_col_header = false
for _, l in ipairs(lines_collapsed) do
  if l:find("^▶ Worked for 1%.3s %(1 thought, 1 tool%)") then
    found_col_header = true
  end
  assert(not l:find("Thinking about code"), "Thought line should be collapsed")
  assert(not l:find("view_file"), "Tool line should be collapsed")
end
assert(found_col_header, "Collapsed header line must exist in buffer")

-- 3b. Expand in-place
render.expand_work_group_in_place(buf, work_group, cfg)
local lines_expanded = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Buffer lines after expand:")
for i, l in ipairs(lines_expanded) do
  print(string.format("  [%d] %s", i, l))
end

assert(work_group.is_open == true, "Group should be marked open")
local found_exp_header = false
local found_th = false
local found_tl = false
for _, l in ipairs(lines_expanded) do
  if l:find("^▼ Worked for 1%.3s %(1 thought, 1 tool%)") then
    found_exp_header = true
  elseif l:find("Thought") then
    found_th = true
  elseif l:find("view_file") then
    found_tl = true
  end
end
assert(found_exp_header, "Expanded header line must exist in buffer")
assert(found_th, "Thought line must be restored")
assert(found_tl, "Tool line must be restored")

-- 3c. Toggle back to collapsed using toggle_work_group
render.toggle_work_group(buf, { config = cfg }, work_group)
assert(work_group.is_open == false, "Group should be collapsed again after toggle")
local lines_retoggled = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local found_retoggled_hdr = false
for _, l in ipairs(lines_retoggled) do
  if l:find("^▶ Worked for 1%.3s") then
    found_retoggled_hdr = true
  end
end
assert(found_retoggled_hdr, "Collapsed header should be restored after toggle")

print("✓ In-place collapse, expand, and toggle verified")

-- =========================================================================
-- TEST 4: toggle_work_group_at_cursor integration
-- =========================================================================
print("\n[Test 4] Testing protocol.toggle_work_group_at_cursor...")

local buf4 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(buf4)
render.render_new_session(buf4, cfg)

local th4 = render.append_thought_block(buf4, "Investigating...", 0.3, cfg)
local t4_line, t4_ext, t4_p = render.append_tool_call(buf4, "run_command", { CommandLine = "ls" }, nil, cfg)
local tl4 = {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "ls" },
  param_str = t4_p,
  duration_seconds = 0.4,
  output = "file1\nfile2",
  header_extmark_id = t4_ext,
  header_line_idx = t4_line,
}
render.complete_tool_call(buf4, tl4, 0.4, "file1\nfile2", cfg)

local wg4 = {
  id = 1,
  is_open = true,
  duration_seconds = 0.7,
  items = { th4, tl4 },
}
render.collapse_work_group_in_place(buf4, wg4, cfg)

local state4 = {
  buf = buf4,
  config = cfg,
  prompt_start_line = vim.api.nvim_buf_line_count(buf4),
  tool_calls = { th4, tl4 },
  work_groups = { wg4 },
}
protocol.buffers[buf4] = state4

-- Place cursor on the work group header line
local cur_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(cur_win, { wg4.header_line_idx + 1, 0 })

-- 4a. Pressing toggle on header expands it
local handled = protocol.toggle_work_group_at_cursor(buf4)
assert(handled == true, "toggle_work_group_at_cursor should handle header row")
assert(wg4.is_open == true, "Work group should now be open")

-- 4b. Pressing toggle again on header collapses it
local handled2 = protocol.toggle_work_group_at_cursor(buf4)
assert(handled2 == true, "toggle_work_group_at_cursor should handle header row again")
assert(wg4.is_open == false, "Work group should now be collapsed")

print("✓ toggle_work_group_at_cursor expands and collapses on cursor line")

-- =========================================================================
-- TEST 5: Child tool output preview inside expanded work group
-- =========================================================================
print("\n[Test 5] Testing child tool output preview and closing on collapse...")

-- Expand group again
render.expand_work_group_in_place(buf4, wg4, cfg)
assert(wg4.is_open == true)

-- Position cursor on child tool line
local tool_row = tl4.header_line_idx + 1
vim.api.nvim_win_set_cursor(cur_win, { tool_row, 0 })

-- toggle_work_group_at_cursor should return false on child tool line
local wg_handled_on_child = protocol.toggle_work_group_at_cursor(buf4)
assert(wg_handled_on_child == false, "toggle_work_group_at_cursor should ignore child tool lines")

-- toggle_tool_at_cursor opens the inline preview window
local tool_handled = protocol.toggle_tool_at_cursor(buf4, cur_win)
assert(tool_handled == true, "toggle_tool_at_cursor should open child tool output")
assert(tl4.is_open == true, "Child tool should be marked open")
assert(tl4.win ~= nil and vim.api.nvim_win_is_valid(tl4.win), "Child tool inline window should be open")

-- Now position cursor on group header and collapse group
vim.api.nvim_win_set_cursor(cur_win, { wg4.header_line_idx + 1, 0 })
local collapsed_handled = protocol.toggle_work_group_at_cursor(buf4)
assert(collapsed_handled == true, "Should collapse group from header")
assert(wg4.is_open == false, "Group should be closed")
assert(tl4.is_open == false, "Child tool should be closed when group is collapsed")
assert(tl4.win == nil, "Child tool inline window should be destroyed")

print("✓ Child tool output preview and automatic cleanup on group collapse verified")

-- =========================================================================
-- TEST 6: render_transcript with default collapse_work = true
-- =========================================================================
print("\n[Test 6] Testing render_transcript default collapse_work = true...")

local steps = {
  { type = "USER_INPUT", content = "Run tests please" },
  {
    type = "PLANNER_RESPONSE",
    thinking = "Let me check the files first.",
    duration_seconds = 0.5,
    tool_calls = {
      { name = "view_file", args = { TargetFile = "render.lua" }, output = "code", duration_seconds = 0.2 },
      { name = "run_command", args = { CommandLine = "nu test.nu" }, output = "ok", duration_seconds = 1.5 },
    }
  },
  {
    type = "PLANNER_RESPONSE",
    content = "All tests passed successfully!",
    duration_seconds = 0.1,
  }
}

local trans_buf = vim.api.nvim_create_buf(false, true)
local p_line, p_ext, tcs, wgs = render.render_transcript(trans_buf, "test-conv-wgs", steps, cfg, vim.fn.getcwd())

assert(wgs and #wgs == 1, "Expected 1 work group from transcript, got: " .. tostring(wgs and #wgs))
assert(wgs[1].is_open == false, "Work group should be collapsed by default in transcript")

local t_lines = vim.api.nvim_buf_get_lines(trans_buf, 0, -1, false)
print("Transcript buffer lines:")
for i, l in ipairs(t_lines) do
  print(string.format("  [%d] %s", i, l))
end

local found_wg_header = false
local found_final_text = false
for _, l in ipairs(t_lines) do
  if l:find("^▶ Worked for") and l:find("%(1 thought, 2 tools%)") then
    found_wg_header = true
  elseif l:find("All tests passed successfully!") then
    found_final_text = true
  end
  assert(not l:find("^💭 Thought"), "Thought should be collapsed in default transcript render")
  assert(not l:find("view_file"), "view_file should be collapsed in default transcript render")
  assert(not l:find("run_command"), "run_command should be collapsed in default transcript render")
end
assert(found_wg_header, "Transcript must contain collapsed work group header")
assert(found_final_text, "Transcript must contain final agent text response")

print("✓ render_transcript with default collapse_work = true verified")

-- =========================================================================
-- TEST 7: Multiple output blocks produce multiple distinct work groups
-- =========================================================================
print("\n[Test 7] Testing multiple output blocks produce multiple work groups...")

local multi_steps = {
  { type = "USER_INPUT", content = "Multi step task" },
  {
    type = "PLANNER_RESPONSE",
    thinking = "Investigating step 1",
    duration_seconds = 0.3,
    tool_calls = {
      { name = "view_file", args = { TargetFile = "file1.lua" }, output = "content1", duration_seconds = 0.2 },
    }
  },
  {
    type = "PLANNER_RESPONSE",
    content = "I have checked file 1. Now proceeding to run tests.",
    duration_seconds = 0.1,
  },
  {
    type = "PLANNER_RESPONSE",
    thinking = "Running step 2",
    duration_seconds = 0.4,
    tool_calls = {
      { name = "run_command", args = { CommandLine = "test" }, output = "pass", duration_seconds = 1.0 },
    }
  },
  {
    type = "PLANNER_RESPONSE",
    content = "Tests are complete and verified.",
    duration_seconds = 0.1,
  }
}

local multi_buf = vim.api.nvim_create_buf(false, true)
local _, _, _, multi_wgs = render.render_transcript(multi_buf, "test-conv-multi", multi_steps, cfg, vim.fn.getcwd())

assert(multi_wgs and #multi_wgs == 2, "Expected 2 work groups for 2 distinct output blocks, got: " .. tostring(multi_wgs and #multi_wgs))
assert(multi_wgs[1].is_open == false, "First work group should be collapsed")
assert(multi_wgs[2].is_open == false, "Second work group should be collapsed")

local m_lines = vim.api.nvim_buf_get_lines(multi_buf, 0, -1, false)
print("Multi-block buffer lines:")
for i, l in ipairs(m_lines) do
  print(string.format("  [%d] %s", i, l))
end

local wg1_found = false
local out1_found = false
local wg2_found = false
local out2_found = false

for _, l in ipairs(m_lines) do
  if l:find("^▶ Worked for") and l:find("file 1") == nil and not wg1_found then
    wg1_found = true
  elseif l:find("I have checked file 1") then
    out1_found = true
  elseif l:find("^▶ Worked for") and out1_found and not wg2_found then
    wg2_found = true
  elseif l:find("Tests are complete and verified") then
    out2_found = true
  end
end

assert(wg1_found, "First work group header must exist")
assert(out1_found, "First text output block must exist")
assert(wg2_found, "Second work group header must exist")
assert(out2_found, "Second text output block must exist")

print("✓ Multiple output blocks cleanly separated into distinct work groups verified")

-- =========================================================================
-- TEST 8: Live streaming auto-collapse simulation
-- =========================================================================
print("\n[Test 8] Testing live streaming auto-collapse on agent text response...")

local live_buf8 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(live_buf8)
protocol._setup_buffer(live_buf8, "test-conv-live")
local p_start8, p_ext8 = render.render_new_session(live_buf8, cfg)

local state8 = {
  buf = live_buf8,
  config = cfg,
  prompt_start_line = p_start8,
  prompt_extmark_id = p_ext8,
  tool_calls = {},
  work_groups = {},
  current_work_group = nil,
  active_agent_started_output = false,
  follow_bottom = false,
  stream_info = { status = "ready" },
}
protocol.buffers[live_buf8] = state8

-- 1. Simulate agent turn start
local agent_ext8, agent_line8 = render.prepare_turn_submission(live_buf8, p_start8, p_ext8, cfg)
state8.agent_extmark_id = agent_ext8
state8.agent_line = agent_line8

-- 2. Simulate thought and tool arrival while running
local tc_th8 = render.append_thought_block(live_buf8, "Thinking live...", 0.2, cfg)
table.insert(state8.tool_calls, tc_th8)
protocol.add_item_to_current_work_group(live_buf8, tc_th8)

local t_line8, t_ext8, t_param8 = render.append_tool_call(live_buf8, "run_command", { CommandLine = "echo 1" }, nil, cfg)
local tc_cmd8 = {
  id = 2,
  tool_name = "run_command",
  params = { CommandLine = "echo 1" },
  param_str = t_param8,
  start_time = vim.uv.hrtime(),
  status = "running",
  header_extmark_id = t_ext8,
  header_line_idx = t_line8,
}
table.insert(state8.tool_calls, tc_cmd8)
state8.active_tool_record = tc_cmd8
protocol.add_item_to_current_work_group(live_buf8, tc_cmd8)

-- Verify that while running, the individual tool line is visible in the buffer
local lines_mid_run = vim.api.nvim_buf_get_lines(live_buf8, 0, -1, false)
local found_live_tool = false
for _, l in ipairs(lines_mid_run) do
  if l:find("run_command") then
    found_live_tool = true
  end
end
assert(found_live_tool, "Tool line should be visible in buffer while actively running")

-- Complete the tool
render.complete_tool_call(live_buf8, tc_cmd8, 0.4, "1", cfg)
state8.active_tool_record = nil

-- 3. Simulate first text delta arrival: triggers auto-collapse
protocol.collapse_active_work_group(live_buf8)
render.append_text_delta(live_buf8, "Here is the response to your prompt.", cfg)

local lines_after_delta = vim.api.nvim_buf_get_lines(live_buf8, 0, -1, false)
print("Buffer lines after text response delta:")
for i, l in ipairs(lines_after_delta) do
  print(string.format("  [%d] %s", i, l))
end

assert(#state8.work_groups == 1, "Work group should have been finalized and added to state.work_groups")
assert(state8.work_groups[1].is_open == false, "Live work group should be collapsed")
local found_live_col_header = false
local found_live_text = false
for _, l in ipairs(lines_after_delta) do
  if l:find("^▶ Worked for") then
    found_live_col_header = true
  elseif l:find("Here is the response to your prompt") then
    found_live_text = true
  end
  assert(not l:find("run_command"), "run_command should now be collapsed")
end
assert(found_live_col_header, "Collapsed header must exist in buffer")
assert(found_live_text, "Streamed text response must exist in buffer")

print("✓ Live streaming auto-collapse on agent response verified")

-- =========================================================================
-- TEST 9: ui.collapse_work = false disables collapsing
-- =========================================================================
print("\n[Test 9] Testing ui.collapse_work = false disables collapsing...")

local no_collapse_cfg = config_mod.setup({
  ui = { collapse_work = false }
})

local no_col_buf = vim.api.nvim_create_buf(false, true)
local _, _, no_col_tcs, no_col_wgs = render.render_transcript(no_col_buf, "test-conv-no-col", steps, no_collapse_cfg, vim.fn.getcwd())

local no_col_lines = vim.api.nvim_buf_get_lines(no_col_buf, 0, -1, false)
print("No-collapse buffer lines:")
for i, l in ipairs(no_col_lines) do
  print(string.format("  [%d] %s", i, l))
end

local has_raw_view = false
local has_raw_run = false
for _, l in ipairs(no_col_lines) do
  if l:find("view_file") then has_raw_view = true end
  if l:find("run_command") then has_raw_run = true end
  assert(not l:find("^▶ Worked for"), "No collapsed work group header should exist when collapse_work = false")
end
assert(has_raw_view, "view_file should be rendered directly when collapse_work = false")
assert(has_raw_run, "run_command should be rendered directly when collapse_work = false")

print("✓ ui.collapse_work = false successfully leaves all tools and thoughts expanded")

-- Reset config back to clean defaults
config_mod.setup()

print("\nALL COLLAPSIBLE WORK GROUPS TESTS PASSED PERFECTLY!")
