local utils = require("agy.utils")
local render = require("agy.render")
local protocol = require("agy.protocol")
local config_mod = require("agy.config")

print("=== Running Collapsible Named Tool Groups & Verbosity Tests ===")

-- =========================================================================
-- TEST 1: Configuration defaults, validation, and fail-fast assertions
-- =========================================================================
print("\n[Test 1] Testing configuration defaults and assertions...")

local cfg = config_mod.setup()
assert(cfg.ui.verbosity == "medium", "Default ui.verbosity should be 'medium'")
assert(cfg.ui.collapse_work == true, "Default ui.collapse_work should be true")
assert(cfg.icons.group_completed == "●", "Default group_completed icon should be '●'")
assert(cfg.icons.group_running == "●", "Default group_running icon should be '●'")
assert(cfg.icons.middle_dot == "·", "Default middle_dot icon should be '·'")
assert(cfg.icons.multiply == "×", "Default multiply icon should be '×'")

-- Fail-fast assertion on invalid verbosity
local ok_bad, err_bad = pcall(function()
  config_mod.setup({ ui = { verbosity = "super-verbose" } })
end)
assert(not ok_bad, "Expected assertion failure when ui.verbosity is invalid")
assert(err_bad:find("'ui.verbosity' must be 'high', 'medium', or 'low'"), "Error message should mention valid verbosity: " .. tostring(err_bad))

-- Fail-fast assertion on missing group_completed icon
local broken_cfg = { icons = { group_running = "●", middle_dot = "·", multiply = "×" } }
local ok_missing, err_missing = pcall(function()
  render.format_named_group_header({ category = "explore", items = {} }, false, false, broken_cfg)
end)
assert(not ok_missing, "Expected assertion failure when group_completed icon is missing")
assert(err_missing:find("icon 'group_completed' is not defined"), "Error message should mention missing group_completed: " .. tostring(err_missing))

print("✓ Configuration defaults, validation, and fail-fast assertions verified")

-- =========================================================================
-- TEST 2: get_tool_category mapping
-- =========================================================================
print("\n[Test 2] Testing get_tool_category mapping...")

assert(render.get_tool_category("view_file") == "explore")
assert(render.get_tool_category("read_file") == "explore")
assert(render.get_tool_category("list_dir") == "explore")
assert(render.get_tool_category("run_command") == "command")
assert(render.get_tool_category("execute_command") == "command")
assert(render.get_tool_category("replace_file_content") == "edit")
assert(render.get_tool_category("write_to_file") == "edit")
assert(render.get_tool_category("search_web") == "search")
assert(render.get_tool_category("code_search") == "search")
assert(render.get_tool_category("read_url_content") == "browse")
assert(render.get_tool_category("invoke_subagent") == "subagent")
assert(render.get_tool_category("send_message") == "subagent")
assert(render.get_tool_category("schedule") == "task")
assert(render.get_tool_category("manage_task") == "task")
assert(render.get_tool_category("image-generator") == "image")
assert(render.get_tool_category("custom_mcp_tool") == "other")

print("✓ get_tool_category maps tool names to canonical categories verified")

-- =========================================================================
-- TEST 3: format_named_group_header categories & formatting
-- =========================================================================
print("\n[Test 3] Testing format_named_group_header formatting...")

-- 3a. Explore single file
local group_single_file = {
  category = "explore",
  items = {
    { tool_name = "view_file", params = { AbsolutePath = "C:/projects/settings.json" } }
  }
}
local h_single_file = render.format_named_group_header(group_single_file, false, false, cfg)
assert(h_single_file == "● Explored 1 file (settings.json)", "Got: " .. h_single_file)

-- 3b. Explore multiple files
local group_multi_files = {
  category = "explore",
  items = {
    { tool_name = "view_file", params = { AbsolutePath = "SKILL.md" } },
    { tool_name = "view_file", params = { AbsolutePath = "cli.md" } },
    { tool_name = "view_file", params = { AbsolutePath = "SKILL.md" } },
  }
}
local h_multi_files = render.format_named_group_header(group_multi_files, false, false, cfg)
assert(h_multi_files == "● Explored 3 files (SKILL.md, cli.md, SKILL.md)", "Got: " .. h_multi_files)

-- 3c. Ran commands with repetitions and failures
local group_cmds = {
  category = "command",
  items = {
    { tool_name = "run_command", params = { CommandLine = "python -c 'import sys'" }, task_status = "failed", exit_code = 1 },
    { tool_name = "run_command", params = { CommandLine = "Get-ChildItem -Path ..." } },
    { tool_name = "run_command", params = { CommandLine = "Get-ChildItem -Path ..." } },
    { tool_name = "run_command", params = { CommandLine = "Get-ChildItem -Path ..." } },
    { tool_name = "run_command", params = { CommandLine = "powershell -Command ..." } },
    { tool_name = "run_command", params = { CommandLine = "powershell -Command ..." } },
  }
}
local h_cmds = render.format_named_group_header(group_cmds, false, false, cfg)
assert(h_cmds:find("^● Ran 6 commands"), "Must start with '● Ran 6 commands': " .. h_cmds)
assert(h_cmds:find(": failed"), "Must flag failed command: " .. h_cmds)
assert(h_cmds:find("×3"), "Must coalesce 3 repetitions with ×3: " .. h_cmds)
assert(h_cmds:find("×2"), "Must coalesce 2 repetitions with ×2: " .. h_cmds)
assert(h_cmds:find(" · "), "Must use middle dot separator: " .. h_cmds)

-- 3d. Running search with hint
local group_search_running = {
  category = "search",
  is_running = true,
  items = {
    { tool_name = "search_web", params = { query = "antigravity memory context" } }
  }
}
local h_search_run = render.format_named_group_header(group_search_running, false, true, cfg)
assert(h_search_run:find("^● Exploring 1 search"), "Must say 'Exploring 1 search': " .. h_search_run)
assert(h_search_run:find('%("antigravity memory context"%)'), "Must format query inside parens: " .. h_search_run)
assert(h_search_run:find("%(<CR> to expand%)"), "Must show expand keymap hint: " .. h_search_run)

-- 3e. Expanded group with collapse hint
local h_expanded = render.format_named_group_header(group_multi_files, true, false, cfg)
assert(h_expanded:find("%(<CR> to collapse%)"), "Must show collapse hint when open: " .. h_expanded)

-- 3f. Browsed pages
local group_browse = {
  category = "browse",
  items = {
    { tool_name = "read_url_content", params = { Url = "https://example.com/api" } },
    { tool_name = "read_url_content", params = { Url = "https://docs.antigravity.google" } },
  }
}
local h_browse = render.format_named_group_header(group_browse, false, false, cfg)
assert(h_browse == "● Browsed 2 pages (https://example.com/api, https://docs.antigravity.google)", "Got: " .. h_browse)

-- 3g. Edited files
local group_edit = {
  category = "edit",
  items = {
    { tool_name = "replace_file_content", params = { TargetFile = "lua/agy/render.lua" } }
  }
}
local h_edit = render.format_named_group_header(group_edit, false, false, cfg)
assert(h_edit == "● Edited 1 file (render.lua)", "Got: " .. h_edit)

print("✓ format_named_group_header formatting across all categories verified")

-- =========================================================================
-- TEST 4: Extmark styling & highlight groups
-- =========================================================================
print("\n[Test 4] Testing extmark styling and highlight groups...")

local buf4 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf4, 0, -1, false, { h_single_file, h_search_run, h_cmds })

local ext1 = render.set_work_group_header_extmark(buf4, 0, h_single_file, cfg, nil, false)
assert(ext1 ~= nil, "Extmark id should be returned for row 0")

local marks0 = vim.api.nvim_buf_get_extmarks(buf4, render.NS_UI, { 0, 0 }, { 0, -1 }, { details = true })
assert(#marks0 >= 3, "Row 0 should have extmarks for bullet, verb, count, details")

local found_comp = false
local found_verb = false
local found_count = false
local found_details = false
for _, m in ipairs(marks0) do
  local hl = m[4].hl_group
  if hl == "AgyGroupCompleted" then found_comp = true end
  if hl == "AgyGroupVerb" then found_verb = true end
  if hl == "AgyGroupCount" then found_count = true end
  if hl == "AgyGroupDetails" then found_details = true end
end
assert(found_comp, "AgyGroupCompleted highlight must be present")
assert(found_verb, "AgyGroupVerb highlight must be present")
assert(found_count, "AgyGroupCount highlight must be present")
assert(found_details, "AgyGroupDetails highlight must be present")

-- Check running search row (row 1)
render.set_work_group_header_extmark(buf4, 1, h_search_run, cfg, nil, true)
local marks1 = vim.api.nvim_buf_get_extmarks(buf4, render.NS_UI, { 1, 0 }, { 1, -1 }, { details = true })
local found_run_hl = false
local found_hint_hl = false
for _, m in ipairs(marks1) do
  local hl = m[4].hl_group
  if hl == "AgyGroupRunning" then found_run_hl = true end
  if hl == "AgyGroupHint" then found_hint_hl = true end
end
assert(found_run_hl, "AgyGroupRunning highlight must be present on running group")
assert(found_hint_hl, "AgyGroupHint highlight must be present for expand hint")

-- Check command row with failure (row 2)
render.set_work_group_header_extmark(buf4, 2, h_cmds, cfg, nil, false)
local marks2 = vim.api.nvim_buf_get_extmarks(buf4, render.NS_UI, { 2, 0 }, { 2, -1 }, { details = true })
local found_failed_hl = false
for _, m in ipairs(marks2) do
  if m[4].hl_group == "AgyGroupFailed" then found_failed_hl = true end
end
assert(found_failed_hl, "AgyGroupFailed highlight must be present on failed command")

print("✓ Extmark highlights (Completed, Running, Verb, Count, Details, Failed, Hint) verified")

-- =========================================================================
-- TEST 5: In-place collapse and expansion of named groups
-- =========================================================================
print("\n[Test 5] Testing in-place collapse and expansion of named groups...")

local buf5 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf5, cfg)

local t5_1_line, t5_1_ext, p5_1 = render.append_tool_call(buf5, "view_file", { AbsolutePath = "file1.lua" }, nil, cfg)
local tl5_1 = {
  id = 1,
  tool_name = "view_file",
  params = { AbsolutePath = "file1.lua" },
  param_str = p5_1,
  duration_seconds = 0.2,
  output = "content1",
  header_extmark_id = t5_1_ext,
  header_line_idx = t5_1_line,
}
render.complete_tool_call(buf5, tl5_1, 0.2, "content1", cfg)

local t5_2_line, t5_2_ext, p5_2 = render.append_tool_call(buf5, "view_file", { AbsolutePath = "file2.lua" }, nil, cfg)
local tl5_2 = {
  id = 2,
  tool_name = "view_file",
  params = { AbsolutePath = "file2.lua" },
  param_str = p5_2,
  duration_seconds = 0.3,
  output = "content2",
  header_extmark_id = t5_2_ext,
  header_line_idx = t5_2_line,
}
render.complete_tool_call(buf5, tl5_2, 0.3, "content2", cfg)

local named_group5 = {
  id = 1,
  category = "explore",
  is_open = true,
  duration_seconds = 0.5,
  items = { tl5_1, tl5_2 },
}

-- Collapse
render.collapse_work_group_in_place(buf5, named_group5, cfg)
assert(named_group5.is_open == false, "Group should be collapsed")

local lines5_col = vim.api.nvim_buf_get_lines(buf5, 0, -1, false)
local found_named_header = false
for _, l in ipairs(lines5_col) do
  if l:find("^● Explored 2 files %(file1%.lua, file2%.lua%)") then
    found_named_header = true
  end
  assert(not l:find("`file1%.lua`"), "Individual file line 1 should be collapsed")
  assert(not l:find("`file2%.lua`"), "Individual file line 2 should be collapsed")
end
assert(found_named_header, "Named collapsed header must exist in buffer")

-- Expand
render.expand_work_group_in_place(buf5, named_group5, cfg)
assert(named_group5.is_open == true, "Group should be open")

local lines5_exp = vim.api.nvim_buf_get_lines(buf5, 0, -1, false)
local found_exp_header = false
local found_f1 = false
local found_f2 = false
for _, l in ipairs(lines5_exp) do
  if l:find("^● Explored 2 files") and l:find("%(<CR> to collapse%)") then
    found_exp_header = true
  elseif l:find("file1%.lua") then
    found_f1 = true
  elseif l:find("file2%.lua") then
    found_f2 = true
  end
end
assert(found_exp_header, "Expanded header with collapse hint must exist")
assert(found_f1, "Child tool 1 must be restored")
assert(found_f2, "Child tool 2 must be restored")

-- Toggle back via toggle_work_group
render.toggle_work_group(buf5, { config = cfg }, named_group5)
assert(named_group5.is_open == false, "Group should be closed again")

print("✓ In-place collapse, expand, and toggle of named group verified")

-- =========================================================================
-- TEST 6: Child tool output preview inside expanded named group
-- =========================================================================
print("\n[Test 6] Testing child tool preview inside expanded named group...")

local cur_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(cur_win, buf5)
render.expand_work_group_in_place(buf5, named_group5, cfg)
assert(named_group5.is_open == true)

local state5 = {
  buf = buf5,
  config = cfg,
  tool_calls = { tl5_1, tl5_2 },
  work_groups = { named_group5 },
}
protocol.buffers[buf5] = state5

-- Cursor on child tool 1
vim.api.nvim_win_set_cursor(cur_win, { tl5_1.header_line_idx + 1, 0 })
local tool_handled = protocol.toggle_tool_at_cursor(buf5, cur_win)
assert(tool_handled == true, "toggle_tool_at_cursor should open preview")
assert(tl5_1.is_open == true, "Tool 1 should be open")
assert(tl5_1.win ~= nil and vim.api.nvim_win_is_valid(tl5_1.win), "Window should be valid")

-- Cursor on group header, collapse group
vim.api.nvim_win_set_cursor(cur_win, { named_group5.header_line_idx + 1, 0 })
local collapse_handled = protocol.toggle_work_group_at_cursor(buf5)
assert(collapse_handled == true, "Group toggle should handle header")
assert(named_group5.is_open == false, "Group should be closed")
assert(tl5_1.is_open == false, "Child tool should be closed")
assert(tl5_1.win == nil, "Child window should be destroyed")

print("✓ Child tool output preview and automatic cleanup on group collapse verified")

-- =========================================================================
-- TEST 7: Transcript replay with medium verbosity (default)
-- =========================================================================
print("\n[Test 7] Testing transcript replay with medium verbosity (default)...")

local trans_steps = {
  { type = "USER_INPUT", content = "Examine files and test" },
  {
    type = "PLANNER_RESPONSE",
    thinking = "Let me look at the code first.",
    duration_seconds = 0.3,
    tool_calls = {
      { name = "view_file", args = { TargetFile = "SKILL.md" }, output = "skill code", duration_seconds = 0.2 },
      { name = "view_file", args = { TargetFile = "cli.md" }, output = "cli code", duration_seconds = 0.2 },
    }
  },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "run_command", args = { CommandLine = "git status" }, output = "clean", duration_seconds = 0.4 },
    }
  },
  {
    type = "PLANNER_RESPONSE",
    content = "Everything is examined and clean.",
    duration_seconds = 0.1,
  }
}

local trans_buf7 = vim.api.nvim_create_buf(false, true)
local _, _, tcs7, wgs7 = render.render_transcript(trans_buf7, "test-conv-named", trans_steps, cfg, vim.fn.getcwd())

assert(wgs7 and #wgs7 == 2, "Expected 2 named groups (1 explore + 1 command), got: " .. tostring(wgs7 and #wgs7))
assert(wgs7[1].category == "explore", "First group should be category 'explore'")
assert(wgs7[2].category == "command", "Second group should be category 'command'")
assert(wgs7[1].is_open == false, "Group 1 should be collapsed")
assert(wgs7[2].is_open == false, "Group 2 should be collapsed")

local t7_lines = vim.api.nvim_buf_get_lines(trans_buf7, 0, -1, false)
print("Transcript buffer lines:")
for i, l in ipairs(t7_lines) do
  print(string.format("  [%d] %s", i, l))
end

local found_explored_line = false
local found_ran_line = false
local found_final_text7 = false
for _, l in ipairs(t7_lines) do
  if l:find("^● Explored 2 files %(SKILL%.md, cli%.md%)") then
    found_explored_line = true
  elseif l:find("^● Ran 1 command %(git status%)") then
    found_ran_line = true
  elseif l:find("Everything is examined and clean") then
    found_final_text7 = true
  end
  assert(not l:find("`SKILL%.md`"), "view_file should be collapsed")
  assert(not l:find("`git status`"), "run_command should be collapsed")
end
assert(found_explored_line, "Explored files header must exist")
assert(found_ran_line, "Ran commands header must exist")
assert(found_final_text7, "Final assistant text response must exist")

print("✓ Transcript replay partitions consecutive categories into distinct named groups")

-- =========================================================================
-- TEST 8: Transcript replay with high verbosity (uncollapsed)
-- =========================================================================
print("\n[Test 8] Testing transcript replay with high verbosity...")

local high_cfg = config_mod.setup({ ui = { verbosity = "high" } })
local high_buf = vim.api.nvim_create_buf(false, true)
local _, _, _, high_wgs = render.render_transcript(high_buf, "test-conv-high", trans_steps, high_cfg, vim.fn.getcwd())

local high_lines = vim.api.nvim_buf_get_lines(high_buf, 0, -1, false)
local found_raw_skill = false
local found_raw_cmd = false
for _, l in ipairs(high_lines) do
  if l:find("view_file") and l:find("SKILL%.md") then found_raw_skill = true end
  if l:find("run_command") and l:find("git status") then found_raw_cmd = true end
  assert(not l:find("^● Explored"), "No collapsed group header should exist in high verbosity")
  assert(not l:find("^● Ran"), "No collapsed command header should exist in high verbosity")
end
assert(found_raw_skill, "view_file should be rendered uncollapsed in high verbosity")
assert(found_raw_cmd, "run_command should be rendered uncollapsed in high verbosity")

print("✓ High verbosity renders all tools and thoughts directly without collapsing")

-- =========================================================================
-- TEST 9: Live streaming category transitions and auto-collapse
-- =========================================================================
print("\n[Test 9] Testing live streaming category transition auto-collapse...")

cfg = config_mod.setup() -- medium verbosity
local live_buf9 = vim.api.nvim_create_buf(false, false)
render.render_new_session(live_buf9, cfg)

local state9 = {
  buf = live_buf9,
  config = cfg,
  tool_calls = {},
  work_groups = {},
  current_work_group = nil,
  active_agent_started_output = false,
  follow_bottom = false,
  stream_info = { status = "ready" },
}
protocol.buffers[live_buf9] = state9

-- 1. Tool 1: view_file (explore)
local t9_1_line, t9_1_ext, p9_1 = render.append_tool_call(live_buf9, "view_file", { AbsolutePath = "foo.lua" }, nil, cfg)
local tc9_1 = {
  id = 1,
  tool_name = "view_file",
  params = { AbsolutePath = "foo.lua" },
  param_str = p9_1,
  duration_seconds = 0.2,
  header_extmark_id = t9_1_ext,
  header_line_idx = t9_1_line,
}
protocol.add_item_to_current_work_group(live_buf9, tc9_1)
render.complete_tool_call(live_buf9, tc9_1, 0.2, "foo", cfg)

-- 2. Tool 2: run_command (command) -> category transition!
local t9_2_line, t9_2_ext, p9_2 = render.append_tool_call(live_buf9, "run_command", { CommandLine = "make build" }, nil, cfg)
local tc9_2 = {
  id = 2,
  tool_name = "run_command",
  params = { CommandLine = "make build" },
  param_str = p9_2,
  duration_seconds = 0.5,
  header_extmark_id = t9_2_ext,
  header_line_idx = t9_2_line,
}
-- Adding Tool 2 should auto-collapse Tool 1's explore group!
protocol.add_item_to_current_work_group(live_buf9, tc9_2)
render.complete_tool_call(live_buf9, tc9_2, 0.5, "ok", cfg)

assert(#state9.work_groups == 1, "Explore group should have auto-collapsed upon category change")
assert(state9.work_groups[1].category == "explore", "First group should be category 'explore'")
assert(state9.current_work_group ~= nil, "Current group should be active for command")
assert(state9.current_work_group.category == "command", "Current group should be category 'command'")

-- 3. Agent text response delta arrives -> collapses command group
protocol.collapse_active_work_group(live_buf9)
render.append_text_delta(live_buf9, "Done with build.", cfg)

assert(#state9.work_groups == 2, "Command group should have collapsed upon text response")
assert(state9.work_groups[2].category == "command", "Second group should be category 'command'")

local lines9 = vim.api.nvim_buf_get_lines(live_buf9, 0, -1, false)
print("Live buffer lines after run:")
for i, l in ipairs(lines9) do
  print(string.format("  [%d] %s", i, l))
end

local found_live_exp = false
local found_live_cmd = false
local found_live_txt = false
for _, l in ipairs(lines9) do
  if l:find("^● Explored 1 file %(foo%.lua%)") then found_live_exp = true end
  if l:find("^● Ran 1 command %(make build%)") then found_live_cmd = true end
  if l:find("Done with build") then found_live_txt = true end
end
assert(found_live_exp, "Live buffer must contain collapsed '● Explored 1 file (foo.lua)'")
assert(found_live_cmd, "Live buffer must contain collapsed '● Ran 1 command (make build)'")
assert(found_live_txt, "Live buffer must contain streamed assistant text")

print("✓ Live streaming category transitions and auto-collapse verified")

-- Reset config back to clean defaults
config_mod.setup()

print("\nALL COLLAPSIBLE NAMED TOOL GROUPS TESTS PASSED PERFECTLY!")
