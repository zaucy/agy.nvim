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

-- Cleanup
pcall(vim.fn.delete, tmp_app_dir, "rf")
pcall(vim.cmd, "bdelete! " .. sub_buf)
pcall(vim.cmd, "bdelete! " .. proto_sub_buf)
pcall(vim.cmd, "bdelete! " .. main_buf)
pcall(vim.cmd, "bdelete! " .. live_watch_buf)

print("\nALL SUBAGENTS & INSPECTION TESTS PASSED PERFECTLY!")
vim.cmd("qall!")
