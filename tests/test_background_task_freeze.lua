local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")
local tasks = require("agy.tasks")
local transcript_mod = require("agy.transcript")
local test_helpers = require("tests.test_helpers")

print("=== Running Background Task Freeze & Status Reconciliation Tests ===")

local tmp_dir, conv_id = test_helpers.create_mock_environment()
local cfg = config.setup({
  app_data_dir = tmp_dir,
  ui = {
    auto_scroll = true,
    collapse_work = false,
  },
})

-- =========================================================================
-- TEST 1: Detect task completion from disk transcript on system_message DONE
-- =========================================================================
print("\n[Test 1] Testing background task status update on empty system_message DONE...")

vim.cmd("edit agy://" .. conv_id)
local buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()
local state = protocol.buffers[buf]
assert(state ~= nil, "Buffer state must exist")
assert(state.session ~= nil, "Session must exist")

-- Simulate tool call starting: run_command
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu test.nu -t" },
  },
})

assert(#state.tool_calls >= 1, "Tool call must be inserted")
local tc1 = state.tool_calls[#state.tool_calls]
assert(tc1.tool_name == "run_command", "Must be run_command")
assert(tc1.status == "running", "Tool call must be running initially")

-- Simulate transition to background task on DONE
local bg_msg = string.format([[Created At: 2026-09-21T12:00:00-07:00
Tool is running as a background task with task id: %s/task-42
Task Description: nu test.nu -t
Task logs are available at: file:///%s/task-42.log]], conv_id, tmp_dir:gsub("\\", "/"))

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  duration_seconds = 5.0,
  tool_info = {
    output = bg_msg,
  },
})

assert(tc1.is_background_task == true, "Must be marked as background task")
assert(tc1.task_status == "running", "Task status must be running")
assert(tc1.task_id == conv_id .. "/task-42", "Task id must match")
assert(tc1.short_id == "task-42", "Short id must be task-42")

-- Check initial extmark highlight is AgyTaskRunning
local em_init = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, tc1.header_extmark_id, { details = true })
assert(em_init and em_init[3], "Extmark must exist")
assert(em_init[3].hl_group == "AgyTaskRunning", "Extmark hl_group must be AgyTaskRunning, got: " .. tostring(em_init[3].hl_group))

-- Write completion to disk transcript (transcript_full.jsonl)
local brain_logs = tmp_dir .. "/brain/" .. conv_id .. "/.system_generated/logs"
vim.fn.mkdir(brain_logs, "p")
local tf = io.open(brain_logs .. "/transcript_full.jsonl", "a")
assert(tf ~= nil, "Must open transcript_full.jsonl")
local comp_step = {
  step_index = 10,
  source = "SYSTEM",
  type = "SYSTEM_MESSAGE",
  status = "DONE",
  content = string.format('Task id "%s/task-42" finished with result:\n\nThe command exited with code 0.\nOutput:\nAll 27 tests passed.', conv_id),
}
tf:write(vim.json.encode(comp_step) .. "\n")
tf:close()

-- Emit system_message DONE event with EMPTY payload (mimicking agy CLI stream-json behavior)
state.session.on_step_update(state.session, {
  step_type = "system_message",
  state = "DONE",
  -- Note: no content or tool_info provided!
})

assert(tc1.task_status == "success", "tc1 task_status must be updated to 'success', got: " .. tostring(tc1.task_status))
assert(tc1.exit_code == 0, "tc1 exit_code must be updated to 0, got: " .. tostring(tc1.exit_code))

-- Verify extmark highlight is now AgyTaskSuccess
local em_done = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, tc1.header_extmark_id, { details = true })
assert(em_done and em_done[3], "Extmark must exist after update")
assert(em_done[3].hl_group == "AgyTaskSuccess", "Extmark hl_group must be AgyTaskSuccess, got: " .. tostring(em_done[3].hl_group))
print("✓ Background task completion detected on empty system_message DONE and updated to AgyTaskSuccess")

-- =========================================================================
-- TEST 2: Failing task completion detection (exit code 1)
-- =========================================================================
print("\n[Test 2] Testing failed task completion detection...")

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu failing_test.nu" },
  },
})
local tc2 = state.tool_calls[#state.tool_calls]

local bg_fail_msg = string.format([[Tool is running as a background task with task id: %s/task-43
Task logs are available at: file:///%s/task-43.log]], conv_id, tmp_dir:gsub("\\", "/"))

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  tool_info = {
    output = bg_fail_msg,
  },
})

assert(tc2.is_background_task == true)
assert(tc2.task_status == "running")

-- Write failure step to disk transcript
local tf2 = io.open(brain_logs .. "/transcript_full.jsonl", "a")
local fail_step = {
  step_index = 11,
  source = "SYSTEM",
  type = "SYSTEM_MESSAGE",
  status = "DONE",
  content = string.format('Task id "%s/task-43" finished with result:\n\nThe command exited with code 1.\nError: Assertion failed.', conv_id),
}
tf2:write(vim.json.encode(fail_step) .. "\n")
tf2:close()

-- Emit system_message DONE
state.session.on_step_update(state.session, {
  step_type = "system_message",
  state = "DONE",
})

assert(tc2.task_status == "failed", "tc2 must update to failed")
assert(tc2.exit_code == 1, "tc2 exit_code must be 1")

local em_fail = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, tc2.header_extmark_id, { details = true })
assert(em_fail[3].hl_group == "AgyTaskFailed", "Extmark hl_group must be AgyTaskFailed, got: " .. tostring(em_fail[3].hl_group))
local vt = em_fail[3].virt_text and em_fail[3].virt_text[1] and em_fail[3].virt_text[1][1] or ""
assert(vt:find("exit 1", 1, true), "Virt text must display exit code 1, got: " .. vt)
print("✓ Failed background task correctly reconciled to AgyTaskFailed with (exit 1)")

-- =========================================================================
-- TEST 3: Reconciliation of remaining running tasks in on_result
-- =========================================================================
print("\n[Test 3] Testing reconciliation of running background tasks on on_result...")

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu test3.nu" },
  },
})
local tc3 = state.tool_calls[#state.tool_calls]

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  tool_info = {
    output = string.format("Tool is running as a background task with task id: %s/task-44\nTask logs are available at: file:///%s/task-44.log", conv_id, tmp_dir:gsub("\\", "/")),
  },
})

assert(tc3.task_status == "running")

-- Write completion to transcript without emitting system_message
local tf3 = io.open(brain_logs .. "/transcript_full.jsonl", "a")
local comp3 = {
  step_index = 12,
  type = "GENERIC",
  content = string.format('Task id "%s/task-44" finished with result:\n\nThe command exited with code 0.', conv_id),
}
tf3:write(vim.json.encode(comp3) .. "\n")
tf3:close()

-- Emit on_result directly
state.session.on_result(state.session, {
  conversation_id = conv_id,
  duration_seconds = 12.0,
})

assert(tc3.task_status == "success", "tc3 must be reconciled to success upon on_result")
assert(tc3.exit_code == 0, "tc3 exit code must be 0")
local em3 = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, tc3.header_extmark_id, { details = true })
assert(em3[3].hl_group == "AgyTaskSuccess", "tc3 extmark must be AgyTaskSuccess")
print("✓ Background task reconciled to success in on_result without lingering AgyTaskRunning")

-- =========================================================================
-- TEST 4: Viewport visibility & follow_bottom re-engagement on agent output
-- =========================================================================
print("\n[Test 4] Testing follow_bottom re-engagement on follow-up agent output...")

-- Create background task 45
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu long_task.nu" },
  },
})
local tc4 = state.tool_calls[#state.tool_calls]
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  tool_info = {
    output = string.format("Tool is running as a background task with task id: %s/task-45\nTask logs are available at: file:///%s/task-45.log", conv_id, tmp_dir:gsub("\\", "/")),
  },
})

-- User moves cursor to history during the long wait -> disengages follow_bottom
vim.api.nvim_win_set_cursor(win, { 1, 0 })
state.follow_bottom = false
assert(state.follow_bottom == false, "follow_bottom must be false when user scrolled away")

-- Write completion of task-45 to transcript
local tf4 = io.open(brain_logs .. "/transcript_full.jsonl", "a")
tf4:write(vim.json.encode({
  step_index = 13,
  type = "GENERIC",
  content = string.format('Task id "%s/task-45" finished with result:\n\nThe command exited with code 0.', conv_id),
}) .. "\n")
tf4:close()

-- Emit system_message DONE
state.session.on_step_update(state.session, {
  step_type = "system_message",
  state = "DONE",
})
assert(tc4.task_status == "success", "task-45 must be success")
assert(state.reengage_follow_bottom == true, "reengage_follow_bottom must be flagged")

-- Follow-up agent response arrives
state.session.on_step_update(state.session, {
  step_type = "agent_response",
  text_delta = "The background task finished and here is the result.",
})

-- Cursor in history must NOT be yanked away while reading history
assert(vim.api.nvim_win_get_cursor(win)[1] == 1, "Cursor in history must not be yanked away")
assert(state.follow_bottom == false, "follow_bottom remains false while cursor is in history")
assert(state.reengage_follow_bottom == nil, "reengage_follow_bottom flag must be cleared")

-- Moving cursor back to prompt area re-engages follow_bottom
vim.api.nvim_win_set_cursor(win, { state.prompt_start_line, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
assert(state.follow_bottom == true, "follow_bottom must re-engage when user returns to prompt area")
print("✓ follow_bottom re-engaged and bottom visibility handled on follow-up agent output")

-- =========================================================================
-- TEST 5: Follow-up tool call re-engages follow_bottom
-- =========================================================================
print("\n[Test 5] Testing follow_bottom re-engagement on follow-up tool call...")

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu task5.nu" },
  },
})
local tc5 = state.tool_calls[#state.tool_calls]
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  tool_info = {
    output = string.format("Tool is running as a background task with task id: %s/task-46\nTask logs are available at: file:///%s/task-46.log", conv_id, tmp_dir:gsub("\\", "/")),
  },
})

-- User scrolls away
state.follow_bottom = false

-- Write task completion
local tf5 = io.open(brain_logs .. "/transcript_full.jsonl", "a")
tf5:write(vim.json.encode({
  step_index = 14,
  type = "GENERIC",
  content = string.format('Task id "%s/task-46" finished with result:\n\nThe command exited with code 0.', conv_id),
}) .. "\n")
tf5:close()

state.session.on_step_update(state.session, {
  step_type = "system_message",
  state = "DONE",
})
assert(state.reengage_follow_bottom == true)

-- Next tool arrives
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "view_file",
  state = "ACTIVE",
  tool_info = {
    parameters = { AbsolutePath = "/test/file.txt" },
  },
})

assert(state.follow_bottom == true, "follow_bottom must be re-engaged when next tool arrives")
print("✓ follow_bottom re-engaged on follow-up tool call")

-- =========================================================================
-- TEST 6: on_result restores prompt visibility after background task
-- =========================================================================
print("\n[Test 6] Testing on_result restores prompt visibility...")

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu task6.nu" },
  },
})
local tc6 = state.tool_calls[#state.tool_calls]
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  tool_info = {
    output = string.format("Tool is running as a background task with task id: %s/task-47\nTask logs are available at: file:///%s/task-47.log", conv_id, tmp_dir:gsub("\\", "/")),
  },
})

state.follow_bottom = false

local tf6 = io.open(brain_logs .. "/transcript_full.jsonl", "a")
tf6:write(vim.json.encode({
  step_index = 15,
  type = "GENERIC",
  content = string.format('Task id "%s/task-47" finished with result:\n\nThe command exited with code 0.', conv_id),
}) .. "\n")
tf6:close()

state.session.on_step_update(state.session, {
  step_type = "system_message",
  state = "DONE",
})

state.agent_extmark_id = 999
state.agent_line = 5

state.session.on_result(state.session, {
  conversation_id = conv_id,
  duration_seconds = 8.0,
})

assert(state.prompt_start_line ~= nil, "Prompt start line must be restored")
print("✓ Prompt start line restored and visible after background task on_result")

-- =========================================================================
-- TEST 7: Live task log watcher automatically terminates on completion
-- =========================================================================
print("\n[Test 7] Testing live task log watcher auto-termination without :e...")

local log_file = tmp_dir .. "/live_task.log"
vim.fn.writefile({ "Step 1: starting...", "Step 2: working..." }, log_file)

local live_tl, live_ext
protocol.with_modifiable(buf, function()
  live_tl, live_ext = render.append_tool_call(buf, "run_command", { CommandLine = "nu live.nu" }, nil, cfg)
end)
local live_tc = {
  id = 999,
  buf = buf,
  tool_name = "run_command",
  params = { CommandLine = "nu live.nu" },
  output = "Tool is running as a background task",
  log_path = log_file,
  is_background_task = true,
  task_status = "running",
  header_extmark_id = live_ext,
  header_line_idx = live_tl,
  status = "done",
  is_open = false,
}
table.insert(state.tool_calls, live_tc)

-- Open inline tool window
local opened = render.toggle_tool_output(buf, state, live_tc)
assert(opened == true, "Must open tool window")
assert(live_tc.log_timer ~= nil, "Log watcher timer must be active")

-- Write exit line to log file
vim.fn.writefile({ "Step 1: starting...", "Step 2: working...", "Done!", "Process exited with 0" }, log_file)

-- Wait for watcher timer tick
local stopped = vim.wait(2000, function()
  return live_tc.task_status == "success" and live_tc.log_timer == nil
end, 50)

assert(stopped == true, "Watcher must detect completion and stop timer automatically")
assert(live_tc.task_status == "success", "Live task status must be success")
assert(live_tc.exit_code == 0, "Live task exit code must be 0")

local em_live = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, live_tc.header_extmark_id, { details = true })
assert(em_live and em_live[3], "Live extmark must exist after watcher completion")
assert(em_live[3].hl_group == "AgyTaskSuccess", "Live extmark hl_group must be AgyTaskSuccess, got: " .. tostring(em_live[3].hl_group))

render.close_tool_window(state, live_tc)
print("✓ Live task log watcher detected completion and stopped timer automatically")

-- =========================================================================
-- TEST 8: Agent response begins while background task completed in log file
-- =========================================================================
print("\n[Test 8] Testing agent response begins and reconciles completed log task...")

local log_file8 = tmp_dir .. "/task8.log"
vim.fn.writefile({ "Output line 1", "Output line 2", "Process exited with 0" }, log_file8)

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu task8.nu" },
  },
})
local tc8 = state.tool_calls[#state.tool_calls]
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  tool_info = {
    output = string.format("Tool is running as a background task with task id: %s/task-48\nTask logs are available at: file:///%s/task8.log", conv_id, tmp_dir:gsub("\\", "/")),
  },
})
assert(tc8.task_status == "running")

-- Agent response begins without an intervening system_message
state.session.on_step_update(state.session, {
  step_type = "agent_response",
  text_delta = "Here is the result of task 8.",
})

assert(tc8.task_status == "success", "tc8 must be reconciled immediately on agent_response start")
assert(tc8.exit_code == 0, "tc8 exit code must be 0")
local em8 = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, tc8.header_extmark_id, { details = true })
assert(em8[3].hl_group == "AgyTaskSuccess", "tc8 extmark hl_group must be AgyTaskSuccess")
print("✓ Agent response start automatically reconciles background task from log file")

-- =========================================================================
-- TEST 9: manage_task with Action='kill' marks background task failed
-- =========================================================================
print("\n[Test 9] Testing manage_task kill Action marks background task as failed...")

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "nu infinite.nu" },
  },
})
local tc9 = state.tool_calls[#state.tool_calls]
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  tool_info = {
    output = string.format("Tool is running as a background task with task id: %s/task-49\nTask logs are available at: file:///%s/task49.log", conv_id, tmp_dir:gsub("\\", "/")),
  },
})
assert(tc9.task_status == "running")

-- Now agent executes manage_task with Action = "kill"
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "manage_task",
  state = "DONE",
  tool_info = {
    parameters = { Action = "kill", TaskId = conv_id .. "/task-49" },
    output = "Task killed successfully",
  },
})

assert(tc9.task_status == "failed", "tc9 must be marked failed after manage_task kill")
assert(tc9.exit_code == 130, "tc9 exit code must be 130")
local em9 = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, tc9.header_extmark_id, { details = true })
assert(em9[3].hl_group == "AgyTaskFailed", "tc9 extmark hl_group must be AgyTaskFailed")
print("✓ manage_task kill Action marks background task as failed with exit 130")

-- =========================================================================
-- TEST 10: Fail-fast assertion on missing/invalid status in render.update_task_status
-- =========================================================================
print("\n[Test 10] Testing fail-fast assertion on missing/invalid status in update_task_status...")
local bad_tc = {
  id = 100,
  buf = buf,
  tool_name = "run_command",
  params = { CommandLine = "echo test" },
  header_extmark_id = tc9.header_extmark_id,
  header_line_idx = tc9.header_line_idx,
}
local ok_nil, err_nil = pcall(render.update_task_status, buf, bad_tc, nil, nil, cfg)
assert(ok_nil == false, "Must fail fast when new_status is nil")
assert(tostring(err_nil):find("new_status string required", 1, true), "Error message must report new_status required: " .. tostring(err_nil))

local ok_bad, err_bad = pcall(render.update_task_status, buf, bad_tc, 123, nil, cfg)
assert(ok_bad == false, "Must fail fast when new_status is not a string")
assert(tostring(err_bad):find("new_status string required", 1, true), "Error message must report string required: " .. tostring(err_bad))
print("✓ Fail-fast assertion on missing/invalid status verified")

-- =========================================================================
-- TEST 11: Synchronous run_command does not flag had_background_task
-- =========================================================================
print("\n[Test 11] Testing synchronous run_command does not flag had_background_task...")
state.had_background_task = false

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "echo sync" },
  },
})
local tc_sync = state.tool_calls[#state.tool_calls]

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  duration_seconds = 0.05,
  tool_info = {
    output = "The command exited with code 0.\nOutput:\nsync",
  },
})

assert(tc_sync.is_background_task == false, "Synchronous command must have is_background_task == false")
assert(tc_sync.task_status == "success", "Synchronous command must have task_status == 'success'")
assert(state.had_background_task == false, "Synchronous command must not flag state.had_background_task")
print("✓ Synchronous run_command correctly leaves had_background_task as false")

-- =========================================================================
-- TEST 12: manage_task kill does not overwrite already completed tasks
-- =========================================================================
print("\n[Test 12] Testing manage_task kill does not overwrite completed task...")
local tc12 = {
  id = 120,
  buf = buf,
  tool_name = "run_command",
  task_id = conv_id .. "/task-120",
  short_id = "task-120",
  is_background_task = true,
  task_status = "success",
  exit_code = 0,
  duration_seconds = 4.2,
  header_extmark_id = tc9.header_extmark_id,
  header_line_idx = tc9.header_line_idx,
}
table.insert(state.tool_calls, tc12)

state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "manage_task",
  state = "DONE",
  tool_info = {
    parameters = { Action = "kill", TaskId = conv_id .. "/task-120" },
    output = "Task killed",
  },
})

assert(tc12.task_status == "success", "Completed task must remain success after manage_task kill")
assert(tc12.exit_code == 0, "Completed task exit_code must remain 0")
assert(tc12.duration_seconds == 4.2, "Duration must be preserved")
print("✓ manage_task kill ignores already completed tasks and preserves status/duration")

-- Clean up
protocol.cleanup_buffer(buf)

print("\nALL BACKGROUND TASK FREEZE TESTS PASSED PERFECTLY!")