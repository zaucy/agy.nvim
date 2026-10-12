-- tests/test_subagents.lua
-- Comprehensive test suite for Antigravity subagents management,
-- unified bottom panel list, subagent inspection buffer (agy://<conv-id>/subagent/<subagent-id>),
-- live reactive streaming, navigation, and kill actions.

local subagents = require("agy.subagents")
local tasks = require("agy.tasks")
local render = require("agy.render")
local protocol = require("agy.protocol")
local config_mod = require("agy.config")
local panel = require("agy.panel")
local agy = require("agy")
vim.cmd("runtime plugin/agy.lua")

print("=== Running Antigravity Subagents & Inspection Tests ===")

local cfg = config_mod.get()

-- Setup temporary test app_data_dir
local tmp_app_dir = vim.fn.tempname()
local test_conv_id = "test-parent-conv-101"
local test_sub_id_1 = "11112222-3333-4444-5555-666677778888"
local test_sub_id_2 = "aaaabbbb-cccc-dddd-eeee-ffff00001111"

local parent_subagents_dir = tmp_app_dir .. "/brain/" .. test_conv_id .. "/.system_generated/subagents"
vim.fn.mkdir(parent_subagents_dir, "p")

local sub1_logs_dir = tmp_app_dir .. "/brain/" .. test_sub_id_1 .. "/.system_generated/logs"
vim.fn.mkdir(sub1_logs_dir, "p")

local sub2_logs_dir = tmp_app_dir .. "/brain/" .. test_sub_id_2 .. "/.system_generated/logs"
vim.fn.mkdir(sub2_logs_dir, "p")

-- Write subagent 1 disk metadata
local sub1_meta = {
  conversationId = test_sub_id_1,
  subagentDescriptor = {
    typeName = "self",
    role = "Modernization Engineer",
  },
  state = "SUBAGENT_STATE_ALIVE",
  spawnStepIndex = 10,
  workspaceUris = { "file:///test/ws" },
}
vim.fn.writefile({ vim.json.encode(sub1_meta) }, parent_subagents_dir .. "/" .. test_sub_id_1 .. ".json")

-- Write subagent 1 transcript
local sub1_transcript = {
  vim.json.encode({
    step_index = 1,
    source = "MODEL",
    type = "PLANNER_RESPONSE",
    status = "DONE",
    created_at = "2026-10-12T10:00:00Z",
    thinking = "Analyzing codebase dag structure...",
    tool_calls = {
      {
        name = "run_command",
        args = { CommandLine = "cargo check" },
        output = "Finished dev [unoptimized + debuginfo] target(s)",
      }
    }
  }),
  vim.json.encode({
    step_index = 2,
    source = "MODEL",
    type = "PLANNER_RESPONSE",
    status = "DONE",
    created_at = "2026-10-12T10:01:00Z",
    content = "Codebase checks out clean! All modules analyzed.",
  })
}
vim.fn.writefile(sub1_transcript, sub1_logs_dir .. "/transcript.jsonl")

-- Write subagent 2 disk metadata (killed state)
local sub2_meta = {
  conversationId = test_sub_id_2,
  subagentDescriptor = {
    typeName = "research",
    role = "Database Researcher",
  },
  state = "SUBAGENT_STATE_KILLED",
  spawnStepIndex = 25,
  workspaceUris = { "file:///test/ws" },
}
vim.fn.writefile({ vim.json.encode(sub2_meta) }, parent_subagents_dir .. "/" .. test_sub_id_2 .. ".json")

-- [Test 1] Testing subagents.short_id
print("\n[Test 1] Testing subagents.short_id extraction...")
assert(subagents.short_id(test_sub_id_1) == "11112222", "Expected first 8 chars, got: " .. subagents.short_id(test_sub_id_1))
assert(subagents.short_id(test_sub_id_2) == "aaaabbbb", "Expected first 8 chars, got: " .. subagents.short_id(test_sub_id_2))
print("✓ subagents.short_id verified")

-- [Test 2] Testing subagents.collect_subagents from disk metadata and transcript
print("\n[Test 2] Testing subagents.collect_subagents...")
local collected_subs = subagents.collect_subagents(test_conv_id, tmp_app_dir)
assert(#collected_subs == 2, "Expected 2 subagents collected, got: " .. #collected_subs)

local found1 = nil
local found2 = nil
for _, s in ipairs(collected_subs) do
  if s.subagent_id == test_sub_id_1 then found1 = s end
  if s.subagent_id == test_sub_id_2 then found2 = s end
end

assert(found1 ~= nil, "Subagent 1 not found")
assert(found1.role == "Modernization Engineer", "Expected role Modernization Engineer, got: " .. found1.role)
assert(found1.status == "completed", "Expected status completed from transcript, got: " .. found1.status)
assert(found1.short_id == "11112222", "Expected short_id 11112222")

assert(found2 ~= nil, "Subagent 2 not found")
assert(found2.role == "Database Researcher", "Expected role Database Researcher, got: " .. found2.role)
assert(found2.status == "killed", "Expected status killed from disk state, got: " .. found2.status)
print("✓ subagents.collect_subagents verified")

-- [Test 3] Testing subagents.kill_subagent
print("\n[Test 3] Testing subagents.kill_subagent...")
subagents.kill_subagent(test_conv_id, test_sub_id_1, tmp_app_dir)
local updated_meta_lines = vim.fn.readfile(parent_subagents_dir .. "/" .. test_sub_id_1 .. ".json")
local updated_meta = vim.json.decode(table.concat(updated_meta_lines, "\n"))
assert(updated_meta.state == "SUBAGENT_STATE_KILLED", "Expected state SUBAGENT_STATE_KILLED on disk")
print("✓ subagents.kill_subagent verified")

-- [Test 4] Testing tasks.collect_items combining background tasks and subagents with reverse chronological sort
print("\n[Test 4] Testing tasks.collect_items reverse chronological sorting...")
-- Reset sub1 to alive with step 10, sub2 with step 50
sub1_meta.state = "SUBAGENT_STATE_ALIVE"
vim.fn.writefile({ vim.json.encode(sub1_meta) }, parent_subagents_dir .. "/" .. test_sub_id_1 .. ".json")

local mock_tc = {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "cargo build" },
  output = "Tool is running as a background task with task id: test/task-30\nTask logs are available at: " .. tmp_app_dir .. "/task-30.log",
  is_background_task = true,
  task_status = "running",
  order_key = 30, -- In-between step 10 and step 50
}

local mock_pstate = {
  conversation_id = test_conv_id,
  tool_calls = { mock_tc },
}

local all_items = tasks.collect_items(test_conv_id, tmp_app_dir, mock_pstate)
assert(#all_items >= 3, "Expected at least 3 combined items (2 subagents, 1 task), got: " .. #all_items)

-- Verify sorting: most recent first (descending order_key: 50, then 30, then 10)
print("Sorted items order:")
for i, it in ipairs(all_items) do
  print(string.format("  [%d] kind=%s name=%s order_key=%s", i, it.kind, it.name, tostring(it.order_key)))
end

assert(all_items[1].kind == "task" and all_items[1].short_id == "task-30", "Expected most recent (order_key 30) at top")
assert(all_items[2].kind == "subagent" and all_items[2].subagent_id == test_sub_id_2, "Expected step 25 in middle")
assert(all_items[3].kind == "subagent" and all_items[3].subagent_id == test_sub_id_1, "Expected oldest (step 10) at bottom")
print("✓ Reverse chronological sorting across tasks and subagents verified")

-- [Test 5] Testing tasks.build_content formatting clean list without columns
print("\n[Test 5] Testing tasks.build_content clean list format...")
local test_cfg = {
  app_data_dir = tmp_app_dir,
  icons = cfg.icons,
  ui = cfg.ui,
}
mock_pstate.config = test_cfg
local p_lines, p_meta, row_to_item = tasks.build_content(mock_pstate, test_cfg, 80)
print("Generated panel lines:")
for idx, l in ipairs(p_lines) do
  print(string.format("  [%d] %s", idx, l))
end

assert(p_lines[1]:find("Background Tasks & Subagents"), "Title line missing")
-- Verify list row format: ● <name> (<short-id>) · <status>
local found_sub_row = false
local found_task_row = false

for idx, l in ipairs(p_lines) do
  if l:find("Database Researcher") then
    found_sub_row = true
    assert(l:find("●"), "Expected bullet icon in subagent row")
    assert(l:find("%(aaaabbbb%)"), "Expected short ID in subagent row")
    assert(l:find("·"), "Expected dot separator in subagent row")
    assert(l:find("Killed"), "Expected Killed status in subagent row")
  elseif l:find("cargo build") then
    found_task_row = true
    assert(l:find("●"), "Expected bullet icon in task row")
    assert(l:find("%(task%-30%)"), "Expected short ID in task row")
    assert(l:find("·"), "Expected dot separator in task row")
    assert(l:find("Running"), "Expected Running status in task row")
  end
end

assert(found_sub_row, "Subagent row not found in panel")
assert(found_task_row, "Task row not found in panel")
print("✓ tasks.build_content clean list formatting verified")

-- [Test 6] Testing subagent inspection buffer rendering (subagents.render_subagent)
print("\n[Test 6] Testing subagents.render_subagent buffer...")
local sub_buf = vim.api.nvim_create_buf(false, true)
subagents.render_subagent(sub_buf, test_conv_id, test_sub_id_1, {
  app_data_dir = tmp_app_dir,
  icons = cfg.icons,
  ui = cfg.ui,
})

assert(vim.bo[sub_buf].modifiable == false, "Subagent buffer must be non-modifiable (read-only)")
assert(vim.bo[sub_buf].modified == false, "Subagent buffer must not be modified")
assert(vim.bo[sub_buf].filetype == "agy", "Subagent buffer filetype must be agy")

local sub_lines = vim.api.nvim_buf_get_lines(sub_buf, 0, -1, false)
print("Subagent buffer lines:")
for idx, l in ipairs(sub_lines) do
  print(string.format("  [%d] %s", idx, l))
end

-- Check header contains session URI and Role subtext
local found_uri = false
local found_role = false
local found_content = false
for _, l in ipairs(sub_lines) do
  if l:find("agy://" .. test_conv_id .. "/subagent/" .. test_sub_id_1, 1, true) then
    found_uri = true
  end
  if l:find("Role: Modernization Engineer", 1, true) then
    found_role = true
  end
  if l:find("Codebase checks out clean!", 1, true) then
    found_content = true
  end
end

assert(found_uri, "Expected agy://.../subagent/... URI in banner")
assert(found_role, "Expected Role: Modernization Engineer in banner")
assert(found_content, "Expected rendered transcript content in subagent buffer")

-- Check virtual footer on subagent buffer
local footer_marks = vim.api.nvim_buf_get_extmarks(sub_buf, subagents.NS_SUBAGENT_FOOTER, 0, -1, { details = true })
assert(#footer_marks >= 1, "Expected footer extmark on subagent buffer")
local f_details = footer_marks[1][4] or {}
local f_vlines = f_details.virt_lines or {}
assert(#f_vlines >= 1 and f_vlines[1][1][1]:find("Back to parent conversation"), "Expected Back to parent conversation in footer")
print("✓ subagents.render_subagent inspection buffer verified")

-- [Test 7] Testing navigation back to parent conversation via '-'
print("\n[Test 7] Testing navigation back to parent conversation via '-'...")
local navigated_target = nil
local old_cmd = vim.cmd
---@diagnostic disable-next-line: duplicate-set-field
vim.cmd = function(cmd)
  local edit_target = cmd:match("^edit%s+(.*)$")
  if edit_target then
    navigated_target = edit_target
  else
    old_cmd(cmd)
  end
end

subagents.go_up(sub_buf, test_conv_id)
vim.cmd = old_cmd

assert(navigated_target == "agy://" .. test_conv_id, "Expected '-' to navigate to agy://" .. test_conv_id .. ", got: " .. tostring(navigated_target))
print("✓ '-' navigation back to parent conversation verified")

-- [Test 8] Testing protocol.handle_buf_read with agy://<conv-id>/subagent/<subagent-id>
print("\n[Test 8] Testing protocol.handle_buf_read routing to subagent buffer...")
local proto_sub_buf = vim.api.nvim_create_buf(false, true)
protocol.handle_buf_read({
  buf = proto_sub_buf,
  file = "agy://" .. test_conv_id .. "/subagent/" .. test_sub_id_1,
})

local p_state = protocol.buffers[proto_sub_buf]
assert(p_state ~= nil, "Expected protocol state for subagent buffer")
assert(p_state.is_subagent == true, "Expected is_subagent == true")
assert(p_state.conversation_id == test_conv_id, "Expected conversation_id to match parent")
assert(p_state.subagent_id == test_sub_id_1, "Expected subagent_id to match")

-- Test write protection on subagent buffer
local notified_msg = nil
local old_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  notified_msg = msg
  if old_notify then old_notify(msg, level) end
end

protocol.handle_write(proto_sub_buf)
vim.notify = old_notify
assert(notified_msg ~= nil and notified_msg:find("read%-only"), "Expected read-only notification on write attempt")
print("✓ protocol routing and read-only protection verified")

-- [Test 9] Testing slash command /subagent and /subagents opening tasks panel
print("\n[Test 9] Testing slash commands /subagent and /subagents...")
local main_buf = vim.api.nvim_create_buf(false, true)
protocol._setup_buffer(main_buf, test_conv_id)
protocol.buffers[main_buf] = {
  buf = main_buf,
  conversation_id = test_conv_id,
  prompt_start_line = 3,
  prompt_extmark_id = 1,
  config = cfg,
  tool_calls = {},
  stream_info = { model = "default", status = "ready" },
}

protocol.with_modifiable(main_buf, function()
  vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, {
    "# Antigravity Session",
    "",
    "/subagent",
  })
end)

protocol.handle_write(main_buf)
assert(panel.is_open(), "Expected /subagent to open panel")
panel.close()

local main_buf2 = vim.api.nvim_create_buf(false, true)
protocol._setup_buffer(main_buf2, test_conv_id)
protocol.buffers[main_buf2] = {
  buf = main_buf2,
  conversation_id = test_conv_id,
  prompt_start_line = 3,
  prompt_extmark_id = 1,
  config = cfg,
  tool_calls = {},
  stream_info = { model = "default", status = "ready" },
}

protocol.with_modifiable(main_buf2, function()
  vim.api.nvim_buf_set_lines(main_buf2, 0, -1, false, {
    "# Antigravity Session",
    "",
    "/subagents",
  })
end)

protocol.handle_write(main_buf2)
assert(panel.is_open(), "Expected /subagents to open panel")
panel.close()
print("✓ Slash commands /subagent and /subagents verified")

-- [Test 10] Testing public API agy.subagents() and user command :AgySubagents
print("\n[Test 10] Testing public API agy.subagents() and :AgySubagents...")
assert(vim.fn.exists(":AgySubagents") == 2, "Expected :AgySubagents user command")
local ok_sub, pwin, pbuf = pcall(function() return agy.subagents(main_buf) end)
assert(ok_sub and pwin and vim.api.nvim_win_is_valid(pwin), "Expected agy.subagents() to open panel")
panel.close()
print("✓ Public API agy.subagents() and user command verified")

-- [Test 11] Testing live reactive watcher updates on subagent transcript modification
print("\n[Test 11] Testing live reactive watcher updates...")
local live_watch_buf = vim.api.nvim_create_buf(false, true)
local watch_cfg = {
  app_data_dir = tmp_app_dir,
  icons = cfg.icons,
  ui = cfg.ui,
}
subagents.render_subagent(live_watch_buf, test_conv_id, test_sub_id_1, watch_cfg)
assert(subagents.active_watchers[live_watch_buf] ~= nil, "Expected active watcher on buffer")

-- Append new turn to subagent transcript
local step3 = vim.json.encode({
  step_index = 3,
  source = "MODEL",
  type = "PLANNER_RESPONSE",
  status = "DONE",
  created_at = "2026-10-12T10:02:00Z",
  content = "LIVE_STREAMED_SUBAGENT_UPDATE_TEST",
})

local cur_lines = vim.fn.readfile(sub1_logs_dir .. "/transcript.jsonl")
table.insert(cur_lines, step3)
vim.fn.writefile(cur_lines, sub1_logs_dir .. "/transcript.jsonl")

-- Wait for fs_event watcher to refresh buffer
local refreshed = vim.wait(2000, function()
  local bl = vim.api.nvim_buf_get_lines(live_watch_buf, 0, -1, false)
  for _, l in ipairs(bl) do
    if l:find("LIVE_STREAMED_SUBAGENT_UPDATE_TEST", 1, true) then
      return true
    end
  end
  return false
end, 100)

assert(refreshed == true, "Expected live watcher to update subagent buffer with new content")
subagents.stop_watcher(live_watch_buf)
assert(subagents.active_watchers[live_watch_buf] == nil, "Expected watcher to be stopped")
print("✓ Live reactive watcher updates verified")

-- [Test 12] Testing render.render_task_lines renders real buffer lines below prompt
print("\n[Test 12] Testing render.render_task_lines renders buffer lines with highlights...")
local footer_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { "line 1", "line 2", "> active prompt" })

local sample_items = {
  {
    kind = "subagent",
    role = "Input Forwarding Fixer",
    short_id = "cd15cd22",
    status = "running",
  },
  {
    kind = "task",
    name = "cargo test",
    short_id = "task-30",
    status = "completed",
    exit_code = 0,
  }
}

local task_ext_id = render.render_task_lines(footer_buf, sample_items, cfg)
assert(task_ext_id ~= nil, "Expected task_ext_id from render_task_lines")

local line_count = vim.api.nvim_buf_line_count(footer_buf)
assert(line_count == 3, "Expected 3 lines (buffer lines untouched), got " .. line_count)

local ext_info = vim.api.nvim_buf_get_extmark_by_id(footer_buf, render.NS_TASKS, task_ext_id, { details = true })
assert(ext_info and ext_info[3] and ext_info[3].virt_lines, "Expected virt_lines in task extmark")
local vl = ext_info[3].virt_lines
assert(#vl == 2, "Expected 2 virtual lines for 2 task items")

local line1_chunks = vl[1]
local line1_text = ""
for _, ch in ipairs(line1_chunks) do line1_text = line1_text .. ch[1] end
assert(line1_text:find("Input Forwarding Fixer", 1, true), "Expected role in virt_line 1: " .. line1_text)
assert(line1_text:find("cd15cd22", 1, true), "Expected short_id in virt_line 1: " .. line1_text)
assert(line1_text:find("Running", 1, true), "Expected Running in virt_line 1: " .. line1_text)

local line2_chunks = vl[2]
local line2_text = ""
for _, ch in ipairs(line2_chunks) do line2_text = line2_text .. ch[1] end
assert(line2_text:find("cargo test", 1, true), "Expected task name in virt_line 2: " .. line2_text)
assert(line2_text:find("task-30", 1, true), "Expected task-30 in virt_line 2: " .. line2_text)
assert(line2_text:find("Success", 1, true), "Expected Success in virt_line 2: " .. line2_text)

-- Verify clear_task_lines removes the virtual text extmark
render.clear_task_lines(footer_buf, task_ext_id)
local cleared_info = vim.api.nvim_buf_get_extmark_by_id(footer_buf, render.NS_TASKS, task_ext_id, {})
assert(#cleared_info == 0, "Expected task extmark deleted after clear_task_lines")
print("✓ render.render_task_lines and clear_task_lines verified")

-- [Test 13] Testing protocol.update_footer with in_flight_subagents as virtual lines
print("\n[Test 13] Testing protocol.update_footer live subagent tracking as virtual lines...")
local proto_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(proto_buf, 0, -1, false, { "> prompt line" })
protocol.buffers[proto_buf] = {
  buf = proto_buf,
  conversation_id = "test-live-conv",
  config = cfg,
  stream_info = { model = "gemini-3.8-flash", status = "generating" },
  prompt_start_line = 1,
  prompt_extmark_id = render.set_divider(proto_buf, 0, "user", nil, nil, true, nil, cfg),
  tool_calls = {},
  in_flight_subagents = {
    {
      kind = "subagent",
      role = "DeepCoder",
      name = "DeepCoder",
      short_id = "spawning...",
      status = "running",
      order_key = 999999,
    }
  }
}

protocol.update_footer(proto_buf)
local p_state = protocol.buffers[proto_buf]
assert(p_state.footer_items and #p_state.footer_items >= 1, "Expected footer_items in buffer state")
assert(p_state.footer_items[1].role == "DeepCoder", "Expected in-flight subagent in footer_items")
assert(p_state.footer_extmark_id ~= nil, "Expected footer_extmark_id in buffer state")

-- Check that buffer still has 1 line (pure virtual text, no extra buffer lines added)
assert(vim.api.nvim_buf_line_count(proto_buf) == 1, "Expected 1 buffer line (prompt only, zero task lines)")
local foot_info = vim.api.nvim_buf_get_extmark_by_id(proto_buf, render.NS_UI, p_state.footer_extmark_id, { details = true })
assert(foot_info and foot_info[3] and foot_info[3].virt_lines, "Expected virt_lines in footer extmark")
local found_sub = false
for _, fvl in ipairs(foot_info[3].virt_lines) do
  local text = ""
  for _, ch in ipairs(fvl) do text = text .. ch[1] end
  if text:find("DeepCoder", 1, true) then found_sub = true break end
end
assert(found_sub, "Expected DeepCoder in footer virt_lines")
print("✓ protocol.update_footer live subagent tracking as virtual lines verified")

-- [Test 14] Testing prompt isolation and dynamic modifiable
print("\n[Test 14] Testing prompt isolation and dynamic modifiable...")
protocol._setup_buffer(proto_buf, "test-live-conv")

-- Test extract_prompt extracts only the prompt line
local extracted_text, extracted_start = protocol.extract_prompt(proto_buf)
assert(extracted_text == "> prompt line", "Expected extracted prompt, got: " .. extracted_text)
assert(extracted_start == 1, "Expected prompt_start_line = 1")

local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, proto_buf)

-- Cursor on line 1 (prompt): modifiable should be true
vim.api.nvim_win_set_cursor(win, { 1, 0 })
protocol.update_modifiable(proto_buf)
assert(vim.bo[proto_buf].modifiable == true, "Expected modifiable = true on prompt line")
print("✓ prompt isolation and dynamic modifiable verified")

-- [Test 15] Testing task line action keymaps (<CR>, <Down>, <Up>, <C-j>, <C-k>, <Esc>, k, d, x)
print("\n[Test 15] Testing task line keymaps (<CR>, <Down>, <Up>, <C-j>, <C-k>, <Esc>, k, d, x)...")
local keymaps = vim.api.nvim_buf_get_keymap(proto_buf, "n")
local has_cr, has_down, has_up, has_cj, has_ck, has_esc, has_k, has_d, has_x = false, false, false, false, false, false, false, false, false
for _, km in ipairs(keymaps) do
  if km.lhs == "<CR>" or km.lhs == "<cr>" then has_cr = true end
  if km.lhs == "<Down>" or km.lhs == "<down>" then has_down = true end
  if km.lhs == "<Up>" or km.lhs == "<up>" then has_up = true end
  if km.lhs == "<C-J>" or km.lhs == "<C-j>" then has_cj = true end
  if km.lhs == "<C-K>" or km.lhs == "<C-k>" then has_ck = true end
  if km.lhs == "<Esc>" or km.lhs == "<esc>" then has_esc = true end
  if km.lhs == "k" then has_k = true end
  if km.lhs == "d" then has_d = true end
  if km.lhs == "x" then has_x = true end
end
assert(has_cr, "Expected <CR> keymap on buffer")
assert(has_down, "Expected <Down> keymap on buffer")
assert(has_up, "Expected <Up> keymap on buffer")
assert(has_cj, "Expected <C-j> keymap on buffer")
assert(has_ck, "Expected <C-k> keymap on buffer")
assert(has_esc, "Expected <Esc> keymap on buffer")
assert(has_k, "Expected k keymap on buffer")
assert(has_d, "Expected d keymap on buffer")
assert(has_x, "Expected x keymap on buffer")
print("✓ task line keymaps verified")

-- [Test 16] Testing prompt deletion guard bounds and history protection with tasks present
print("\n[Test 16] Testing prompt deletion guard bounds...")
local guard_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(guard_buf, 0, -1, false, {
  "Agent history line 1",
  "",
  "> user prompt line",
})
protocol.buffers[guard_buf] = {
  buf = guard_buf,
  conversation_id = "test-guard-conv",
  config = cfg,
  stream_info = { model = "gemini-3.8-flash", status = "ready" },
  prompt_start_line = 3,
  prompt_extmark_id = render.set_divider(guard_buf, 2, "user", nil, nil, true, nil, cfg),
  tool_calls = {},
}
protocol.update_footer(guard_buf)
protocol._setup_buffer(guard_buf, "test-guard-conv")

-- Buffer lines are unchanged (line 1: history, line 2: spacer, line 3: prompt)
assert(vim.api.nvim_buf_line_count(guard_buf) == 3, "Expected 3 lines in buffer")
local g_state = protocol.buffers[guard_buf]
assert(g_state.prompt_start_line == 3, "Expected prompt_start_line == 3")

-- Test normal mode dd keymap handler logic on single prompt line
local win_g = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win_g, guard_buf)
vim.api.nvim_win_set_cursor(win_g, { 3, 0 })

local keymaps_g = vim.api.nvim_buf_get_keymap(guard_buf, "n")
local dd_km = nil
for _, km in ipairs(keymaps_g) do
  if km.lhs == "dd" then dd_km = km; break end
end
assert(dd_km ~= nil, "Expected dd keymap on guard buffer")
assert(dd_km.callback() == "cc\27", "Expected dd on single prompt line to return cc<Esc>, protecting line from deletion")

-- Test insert mode backspace keymap handler at col 0
local i_keymaps = vim.api.nvim_buf_get_keymap(guard_buf, "i")
local bs_km = nil
for _, km in ipairs(i_keymaps) do
  if km.lhs == "<BS>" then bs_km = km; break end
end
assert(bs_km ~= nil, "Expected insert <BS> keymap on guard buffer")
vim.api.nvim_win_set_cursor(win_g, { 3, 0 })
assert(bs_km.callback() == "", "Expected <BS> at col 0 of prompt line to return empty string to prevent merging with history")

-- Verify history line 1 and spacer line 2 are completely intact
local g_lines = vim.api.nvim_buf_get_lines(guard_buf, 0, 2, false)
assert(g_lines[1] == "Agent history line 1", "History line 1 must not be modified")
assert(g_lines[2] == "", "Spacer line 2 must not be modified")
print("✓ prompt deletion guard bounds and history protection verified")

-- [Test 17] Testing live subagent action extraction and formatted status
print("\n[Test 17] Testing live subagent action extraction and formatted status...")
local mock_sub_steps_tool = {
  { step_index = 0, type = "SYSTEM_MESSAGE" },
  {
    step_index = 1,
    type = "PLANNER_RESPONSE",
    tool_calls = {
      {
        name = "view_file",
        args = { toolAction = "Reading build_script.md", toolSummary = "View build_script.md" },
      }
    }
  }
}
local act1 = subagents.extract_current_action(mock_sub_steps_tool)
assert(act1 == "Reading build_script.md", "Expected Reading build_script.md, got: " .. tostring(act1))

local mock_sub_steps_generic = {
  { step_index = 0, type = "SYSTEM_MESSAGE" },
  { step_index = 1, type = "PLANNER_RESPONSE", tool_calls = { { name = "view_file" } } },
  { step_index = 2, type = "GENERIC", content = "file content" },
}
local act2 = subagents.extract_current_action(mock_sub_steps_generic)
assert(act2 == "Thinking...", "Expected Thinking..., got: " .. tostring(act2))

-- Test format_task_item_line displays Running (<action>)
local live_sub_item = {
  kind = "subagent",
  role = "DevEx & CLI Specialist",
  short_id = "dc4e7792",
  status = "running",
  current_action = "Reading build_script.md",
}
local formatted_live_line, _ = render.format_task_item_line(live_sub_item, cfg)
print("Formatted live subagent line:\n  " .. formatted_live_line)
print("✓ live subagent action extraction and formatted status verified")

-- [Test 18] Testing resumed conversation subagents completion detection
print("\n[Test 18] Testing resumed conversation subagent completion detection...")
local test_sub_id_3 = "33334444-5555-6666-7777-888899990000"
local sub3_logs_dir = tmp_app_dir .. "/brain/" .. test_sub_id_3 .. "/.system_generated/logs"
vim.fn.mkdir(sub3_logs_dir, "p")

local sub3_meta = {
  conversationId = test_sub_id_3,
  subagentDescriptor = {
    typeName = "research",
    role = "Diagnostics & Quality Specialist",
  },
  state = "SUBAGENT_STATE_ALIVE", -- Still ALIVE on disk
  spawnStepIndex = 5,
  workspaceUris = { "file:///test/ws" },
}
vim.fn.writefile({ vim.json.encode(sub3_meta) }, parent_subagents_dir .. "/" .. test_sub_id_3 .. ".json")

-- Transcript ends on GENERIC (output of last tool call)
local sub3_transcript = {
  vim.json.encode({
    step_index = 1,
    source = "MODEL",
    type = "PLANNER_RESPONSE",
    status = "DONE",
    tool_calls = { { name = "run_command", args = { CommandLine = "pytest" } } },
  }),
  vim.json.encode({
    step_index = 2,
    source = "MODEL",
    type = "GENERIC",
    status = "DONE",
    content = "3 passed, 0 failed in 0.45s",
  })
}
vim.fn.writefile(sub3_transcript, sub3_logs_dir .. "/transcript.jsonl")

-- When conversation is resumed or opened with idle session (turn_active == false):
local resumed_pstate = {
  conversation_id = test_conv_id,
  session = { turn_active = false },
  stream_info = { status = "ready" },
}
local resumed_subs = subagents.collect_subagents(test_conv_id, tmp_app_dir, resumed_pstate)
local found3 = nil
for _, s in ipairs(resumed_subs) do
  if s.subagent_id == test_sub_id_3 then found3 = s break end
end

assert(found3 ~= nil, "Expected subagent 3 collected in resumed conversation")
assert(found3.status == "completed", "Expected status 'completed' in resumed/idle conversation, got: " .. tostring(found3.status))
assert(found3.current_action == nil, "Expected current_action nil for completed subagent, got: " .. tostring(found3.current_action))

local formatted_resumed_line, _ = render.format_task_item_line(found3, cfg)
print("Formatted resumed subagent line:\n  " .. formatted_resumed_line)
assert(formatted_resumed_line:find("Completed"), "Expected 'Completed' in formatted line: " .. formatted_resumed_line)
assert(not formatted_resumed_line:find("Running"), "Must NOT contain 'Running' in formatted line: " .. formatted_resumed_line)
print("✓ resumed conversation subagent completion detection verified")

-- [Test 19] Testing multi-turn subagent lifecycle and message reply completion
print("\n[Test 19] Testing multi-turn subagent lifecycle and message reply completion...")
local test_conv_multiturn = "test-conv-multiturn-200"
local multiturn_subagents_dir = tmp_app_dir .. "/brain/" .. test_conv_multiturn .. "/.system_generated/subagents"
local multiturn_logs_dir = tmp_app_dir .. "/brain/" .. test_conv_multiturn .. "/.system_generated/logs"
vim.fn.mkdir(multiturn_subagents_dir, "p")
vim.fn.mkdir(multiturn_logs_dir, "p")

local sub_turn1_id = "aaaa1111-2222-3333-4444-555566667777"
local sub_turn2_id = "bbbb2222-3333-4444-5555-666677778888"

-- Turn 1 subagent metadata
vim.fn.writefile({ vim.json.encode({
  conversationId = sub_turn1_id,
  subagentDescriptor = { typeName = "self", role = "Turn 1 Worker" },
  state = "SUBAGENT_STATE_ALIVE",
  spawnStepIndex = 2,
}) }, multiturn_subagents_dir .. "/" .. sub_turn1_id .. ".json")

-- Turn 2 subagent metadata
vim.fn.writefile({ vim.json.encode({
  conversationId = sub_turn2_id,
  subagentDescriptor = { typeName = "self", role = "Turn 2 Worker" },
  state = "SUBAGENT_STATE_ALIVE",
  spawnStepIndex = 12,
}) }, multiturn_subagents_dir .. "/" .. sub_turn2_id .. ".json")

-- Parent multi-turn transcript:
-- Turn 1: Step 1 (USER_INPUT), Step 2 (invoke subagent 1), Step 3 (SYSTEM_MESSAGE sender=sub1)
-- Turn 2: Step 10 (USER_INPUT), Step 12 (invoke subagent 2)
local parent_multiturn_steps = {
  vim.json.encode({ step_index = 1, source = "USER_EXPLICIT", type = "USER_INPUT", content = "First prompt" }),
  vim.json.encode({
    step_index = 2,
    source = "MODEL",
    type = "PLANNER_RESPONSE",
    tool_calls = { { name = "invoke_subagent", output = '{"conversationId":"' .. sub_turn1_id .. '"}' } },
  }),
  vim.json.encode({
    step_index = 3,
    source = "SYSTEM",
    type = "SYSTEM_MESSAGE",
    content = "[Message] timestamp=2026-10-12T12:00:00Z sender=" .. sub_turn1_id .. " content=Turn 1 done!",
  }),
  vim.json.encode({ step_index = 10, source = "USER_EXPLICIT", type = "USER_INPUT", content = "Second prompt" }),
  vim.json.encode({
    step_index = 12,
    source = "MODEL",
    type = "PLANNER_RESPONSE",
    tool_calls = { { name = "invoke_subagent", output = '{"conversationId":"' .. sub_turn2_id .. '"}' } },
  }),
}
vim.fn.writefile(parent_multiturn_steps, multiturn_logs_dir .. "/transcript.jsonl")

-- Active session during Turn 2:
local active_turn2_pstate = {
  conversation_id = test_conv_multiturn,
  session = { turn_active = true },
  stream_info = { status = "generating" },
}

local multiturn_collected = subagents.collect_subagents(test_conv_multiturn, tmp_app_dir, active_turn2_pstate)
local sub1_item = nil
local sub2_item = nil
for _, s in ipairs(multiturn_collected) do
  if s.subagent_id == sub_turn1_id then sub1_item = s end
  if s.subagent_id == sub_turn2_id then sub2_item = s end
end

assert(sub1_item ~= nil, "Expected Turn 1 subagent collected")
assert(sub2_item ~= nil, "Expected Turn 2 subagent collected")
assert(sub1_item.status == "completed", "Turn 1 subagent must be 'completed' during Turn 2, got: " .. tostring(sub1_item.status))
assert(sub2_item.status == "running", "Turn 2 subagent must be 'running' during active Turn 2, got: " .. tostring(sub2_item.status))

-- Now parent receives completion message from Turn 2 subagent
table.insert(parent_multiturn_steps, vim.json.encode({
  step_index = 14,
  source = "SYSTEM",
  type = "SYSTEM_MESSAGE",
  content = "[Message] timestamp=2026-10-12T12:05:00Z sender=" .. sub_turn2_id .. " content=Turn 2 finished!",
}))
vim.fn.writefile(parent_multiturn_steps, multiturn_logs_dir .. "/transcript.jsonl")

local after_reply_collected = subagents.collect_subagents(test_conv_multiturn, tmp_app_dir, active_turn2_pstate)
local sub2_after = nil
for _, s in ipairs(after_reply_collected) do
  if s.subagent_id == sub_turn2_id then sub2_after = s break end
end

assert(sub2_after ~= nil, "Expected sub2 collected after reply")
assert(sub2_after.status == "completed", "Turn 2 subagent must be 'completed' after replying to parent, got: " .. tostring(sub2_after.status))
print("✓ multi-turn subagent lifecycle and message reply completion verified")

-- [Test 20] Testing Telescope-style navigation, selection, activation, and clear-on-typing
print("\n[Test 20] Testing Telescope-style navigation, selection, and clear-on-typing...")
local tele_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(tele_buf, 0, -1, false, { "> prompt line" })
protocol.buffers[tele_buf] = {
  buf = tele_buf,
  conversation_id = test_conv_id,
  config = cfg,
  stream_info = { model = "gemini-3.8-flash", status = "ready" },
  prompt_start_line = 1,
  prompt_extmark_id = render.set_divider(tele_buf, 0, "user", nil, nil, true, nil, cfg),
  tool_calls = {},
  in_flight_subagents = {
    {
      kind = "subagent",
      role = "Worker Alpha",
      name = "Worker Alpha",
      subagent_id = "alpha-1111-2222",
      short_id = "alpha111",
      status = "running",
      order_key = 999999,
    },
    {
      kind = "subagent",
      role = "Worker Beta",
      name = "Worker Beta",
      subagent_id = "beta-3333-4444",
      short_id = "beta3333",
      status = "running",
      order_key = 999998,
    },
  },
}
protocol.update_footer(tele_buf)
protocol._setup_buffer(tele_buf, test_conv_id)

local tele_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(tele_win, tele_buf)
vim.api.nvim_win_set_cursor(tele_win, { 1, 0 })

-- Initially nothing selected
local t_state = protocol.buffers[tele_buf]
assert(t_state.selected_task_index == nil, "Initially no task selected")

-- Trigger <Down> mapping
local n_maps = vim.api.nvim_buf_get_keymap(tele_buf, "n")
local down_fn, up_fn, esc_fn, k_fn, cr_fn
for _, km in ipairs(n_maps) do
  if km.lhs == "<Down>" or km.lhs == "<down>" then down_fn = km.callback end
  if km.lhs == "<Up>" or km.lhs == "<up>" then up_fn = km.callback end
  if km.lhs == "<Esc>" or km.lhs == "<esc>" then esc_fn = km.callback end
  if km.lhs == "k" then k_fn = km.callback end
  if km.lhs == "<CR>" or km.lhs == "<cr>" then cr_fn = km.callback end
end

assert(down_fn ~= nil, "Expected <Down> callback")
assert(up_fn ~= nil, "Expected <Up> callback")
assert(esc_fn ~= nil, "Expected <Esc> callback")
assert(k_fn ~= nil, "Expected k callback")
assert(cr_fn ~= nil, "Expected <CR> callback")

-- 1. Press <Down> at bottom of prompt: selects item 1
down_fn()
assert(t_state.selected_task_index == 1, "Expected selected_task_index = 1 after <Down>")

-- Check virt_lines has pointer icon on item 1 and hint line
local mark1 = vim.api.nvim_buf_get_extmark_by_id(tele_buf, render.NS_UI, t_state.footer_extmark_id, { details = true })
local virt1 = mark1[3].virt_lines
local item1_text = ""
for _, ch in ipairs(virt1[2]) do item1_text = item1_text .. ch[1] end
assert(item1_text:find(cfg.icons.pointer, 1, true), "Expected pointer icon on item 1: " .. item1_text)

local hint_text = ""
for _, ch in ipairs(virt1[4]) do hint_text = hint_text .. ch[1] end
assert(hint_text:find("⏎ View", 1, true), "Expected hint line below items: " .. hint_text)

-- 2. Press <Down> again: moves to item 2
down_fn()
assert(t_state.selected_task_index == 2, "Expected selected_task_index = 2 after second <Down>")

-- 3. Press <Up>: moves back to item 1
up_fn()
assert(t_state.selected_task_index == 1, "Expected selected_task_index = 1 after <Up>")

-- 4. Press <Up> again: clears selection and returns to prompt focus
up_fn()
assert(t_state.selected_task_index == nil, "Expected selected_task_index = nil after <Up> on item 1")

-- 5. Press <Down> to reselect, then <Esc> to cancel
down_fn()
assert(t_state.selected_task_index == 1, "Expected selected_task_index = 1")
local esc_ret = esc_fn()
assert(esc_ret == "", "Expected <Esc> consumed when clearing selection")
assert(t_state.selected_task_index == nil, "Expected selected_task_index cleared by <Esc>")

-- 6. Press <Down> to select, then typing/insert clears selection
down_fn()
assert(t_state.selected_task_index == 1, "Expected selected_task_index = 1")
vim.api.nvim_exec_autocmds("InsertEnter", { buffer = tele_buf })
assert(t_state.selected_task_index == nil, "Expected selection cleared on typing/InsertEnter")

-- 7. Press <Down> to select, then 'k' kills the selected subagent
down_fn()
assert(t_state.selected_task_index == 1, "Expected selected_task_index = 1")
local killed_ret = k_fn()
assert(killed_ret == "", "Expected 'k' consumed when killing selected item")
assert(t_state.footer_items[1].status == "killed", "Expected Worker Alpha status = killed")

-- 8. Press <Down> twice to select item 2 (task), then <CR> views/opens the task
down_fn()
assert(t_state.selected_task_index == 2, "Expected selected_task_index = 2")
cr_fn()
assert(t_state.selected_task_index == nil, "Expected selection cleared on activation")

pcall(vim.cmd, "bdelete! " .. tele_buf)
print("✓ Telescope-style navigation, selection, activation, and clear-on-typing verified")

-- Cleanup
pcall(vim.fn.delete, tmp_app_dir, "rf")
pcall(vim.cmd, "bdelete! " .. sub_buf)
pcall(vim.cmd, "bdelete! " .. proto_sub_buf)
pcall(vim.cmd, "bdelete! " .. main_buf)
pcall(vim.cmd, "bdelete! " .. live_watch_buf)
pcall(vim.cmd, "bdelete! " .. footer_buf)
pcall(vim.cmd, "bdelete! " .. proto_buf)

print("\nALL SUBAGENTS & INSPECTION TESTS PASSED PERFECTLY!")
vim.cmd("qall!")
