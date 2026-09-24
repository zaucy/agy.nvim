-- tests/test_tasks.lua
-- Comprehensive test suite for Antigravity background tasks detection,
-- distinct status icons, highlighting, live updates, and /tasks interactive panel.

local tasks = require("agy.tasks")
local render = require("agy.render")
local protocol = require("agy.protocol")
local config = require("agy.config")
local agy = require("agy")

print("=== Running Antigravity Tasks & Status Tests ===")

-- [Test 1] Testing tasks.parse_task_info
print("\n[Test 1] Testing parse_task_info background task detection...")
local bg_output = [[Created At: 2026-09-20T11:00:00-07:00
Tool is running as a background task with task id: conv-123/task-456
Task logs are available at: file:///C:/Users/test/.gemini/antigravity-cli/brain/conv-123/.system_generated/tasks/task-456.log
YOU MUST TAKE ONE OF THE FOLLOWING TWO ACTIONS: A) either proceed to other relevant work...]]

local info = tasks.parse_task_info(bg_output, { CommandLine = "nu test.nu -t" })
assert(info ~= nil, "Expected parse_task_info to recognize background task output")
assert(info.task_id == "conv-123/task-456", "Expected task_id, got " .. tostring(info.task_id))
assert(info.short_id == "task-456", "Expected short_id task-456, got " .. tostring(info.short_id))
assert(info.command == "nu test.nu -t", "Expected command from params")
assert(info.log_path ~= nil and info.log_path:find("task%-456%.log"), "Expected log_path to be extracted")

-- Non-background output should return nil
local sync_output = "Neovim v0.10.0\nBuild type: Release"
assert(tasks.parse_task_info(sync_output, { CommandLine = "nvim --version" }) == nil, "Expected nil for sync output")

-- File contents mentioning 'background task' without task id must return nil
local doc_content = "This document describes background tasks and status panels."
assert(tasks.parse_task_info(doc_content, { AbsolutePath = "doc/agy.txt" }) == nil, "Expected nil for file contents mentioning background tasks")
print("✓ parse_task_info detection and extraction verified")

-- [Test 2] Testing parse_task_completion
print("\n[Test 2] Testing parse_task_completion notification parsing...")
local done_msg = [[Task id "conv-123/task-456" finished with result:

The command exited with code 0.
Output:
All tests passed!]]

local comp1 = tasks.parse_task_completion(done_msg)
assert(comp1 ~= nil, "Expected parse_task_completion to parse completion message")
assert(comp1.task_id == "conv-123/task-456", "Expected matching task_id")
assert(comp1.short_id == "task-456", "Expected short_id task-456")
assert(comp1.status == "success", "Expected success status for exit 0")
assert(comp1.exit_code == 0, "Expected exit code 0")

local fail_msg = [[Task id "task-789" finished with result:

The command exited with code 1.
Error: Test failed!]]
local comp2 = tasks.parse_task_completion(fail_msg)
assert(comp2 ~= nil, "Expected fail_msg to be parsed")
assert(comp2.status == "failed", "Expected failed status for exit 1")
assert(comp2.exit_code == 1, "Expected exit code 1")

assert(tasks.parse_task_completion("Regular assistant response message") == nil, "Expected nil for normal message")
print("✓ parse_task_completion verified")

-- [Test 3] Testing collect_task_outcomes
print("\n[Test 3] Testing collect_task_outcomes across transcript steps...")
local mock_steps = {
  { type = "USER_INPUT", content = "Run tests" },
  {
    type = "PLANNER_RESPONSE",
    content = "I will run the tests in background",
    tool_calls = {
      {
        name = "run_command",
        args = { CommandLine = "nu test.nu -t" },
        output = bg_output,
      }
    }
  },
  {
    type = "GENERIC",
    content = done_msg,
  },
  {
    type = "GENERIC",
    content = 'Task id "task-999" finished with result:\n\nThe command exited with code 127.',
  }
}

local outcomes = tasks.collect_task_outcomes(mock_steps)
assert(outcomes["conv-123/task-456"] ~= nil, "Expected outcome for full task id")
assert(outcomes["task-456"] ~= nil, "Expected outcome for short task id")
assert(outcomes["task-456"].status == "success", "Expected task-456 to be success")
assert(outcomes["task-456"].exit_code == 0, "Expected task-456 exit code 0")

assert(outcomes["task-999"] ~= nil, "Expected outcome for task-999")
assert(outcomes["task-999"].status == "failed", "Expected task-999 to be failed")
assert(outcomes["task-999"].exit_code == 127, "Expected task-999 exit code 127")
print("✓ collect_task_outcomes across transcript steps verified")

-- [Test 4] Testing render_transcript with circle icon () and status highlights
print("\n[Test 4] Testing render_transcript distinct task circle icon and extmarks...")
local cfg = config.setup({
  icons = {
    tool = "🛠️",
    view_file = "🛠️",
    run_command = "",
    thought = "💭",
    user = "👤",
    agent = "🤖",
    prompt_sign = "❯ ",
    footer = "⚡",
    done = "✓",
    question = "❓",
    error = "❌",
    cancelled = "⏹️",
  },
  ui = {
    collapse_work = false,
  },
})
local test_buf = vim.api.nvim_create_buf(false, true)

local steps_with_tasks = {
  { type = "USER_INPUT", content = "Run build and tests" },
  {
    type = "PLANNER_RESPONSE",
    content = "Running 3 background tasks",
    tool_calls = {
      -- Task 1: Finished with success (exit 0)
      {
        name = "run_command",
        args = { CommandLine = "cargo build" },
        output = "Tool is running as a background task with task id: task-101\nTask logs are available at: file:///logs/task-101.log",
        duration_seconds = 2.5,
      },
      -- Task 2: Finished with failure (exit 1)
      {
        name = "run_command",
        args = { CommandLine = "cargo test" },
        output = "Tool is running as a background task with task id: task-102\nTask logs are available at: file:///logs/task-102.log",
        duration_seconds = 1.2,
      },
      -- Task 3: Still running (no outcome yet)
      {
        name = "run_command",
        args = { CommandLine = "cargo watch" },
        output = "Tool is running as a background task with task id: task-103\nTask logs are available at: file:///logs/task-103.log",
      },
      -- Tool 4: Regular tool (view_file) reading a file containing "background tasks" text
      {
        name = "view_file",
        args = { AbsolutePath = "/src/main.rs" },
        output = "fn main() { // Describes background tasks and status\n}",
        duration_seconds = 0.1,
      }
    }
  },
  {
    type = "GENERIC",
    content = 'Task id "task-101" finished with result:\n\nThe command exited with code 0.',
  },
  {
    type = "GENERIC",
    content = 'Task id "task-102" finished with result:\n\nThe command exited with code 1.',
  },
}

local prompt_line, prompt_ext_id, tool_calls = render.render_transcript(test_buf, "test-tasks-conv", steps_with_tasks, cfg, vim.fn.getcwd())
local lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)

print("Rendered buffer lines:")
for idx, l in ipairs(lines) do
  print(string.format("  [%d] %s", idx, l))
end

-- Validate icons in buffer text: run_command uses circle icon , other tools use 🛠️
local task1_line = nil
local task2_line = nil
local task3_line = nil
local normal_tool_line = nil

for idx, l in ipairs(lines) do
  if l:find("cargo build", 1, true) then
    task1_line = l
    assert(l:find("^"), "Expected success task to have '' circle icon, got: " .. l)
  elseif l:find("cargo test", 1, true) then
    task2_line = l
    assert(l:find("^"), "Expected failed task to have '' circle icon, got: " .. l)
  elseif l:find("cargo watch", 1, true) then
    task3_line = l
    assert(l:find("^"), "Expected running task to have '' circle icon, got: " .. l)
  elseif l:find("view_file", 1, true) then
    normal_tool_line = l
    assert(l:find("^🛠️"), "Expected normal tool to have '🛠️' icon, got: " .. l)
  end
end

assert(task1_line ~= nil, "Task 1 line not found")
assert(task2_line ~= nil, "Task 2 line not found")
assert(task3_line ~= nil, "Task 3 line not found")
assert(normal_tool_line ~= nil, "Normal tool line not found")

-- Validate extmark badges and highlight groups
local marks = vim.api.nvim_buf_get_extmarks(test_buf, render.NS_UI, 0, -1, { details = true })
local task_marks = {}
for _, m in ipairs(marks) do
  local details = m[4] or {}
  if details.virt_text then
    local vt = details.virt_text[1] or {}
    table.insert(task_marks, {
      row = m[2],
      col = m[3],
      text = vt[1],
      hl = vt[2],
      hl_group = details.hl_group,
    })
  end
end

print("Found " .. #task_marks .. " UI extmarks with virt_text:")
for _, tm in ipairs(task_marks) do
  print(string.format("  Row %d: text='%s' virt_hl='%s' main_hl='%s'", tm.row, tm.text, tm.hl, tostring(tm.hl_group)))
end

-- Check that tasks have distinct status colors and no redundant [Done]/[Running] text
local found_success_mark = false
local found_failed_mark = false
local found_running_mark = false

for _, m in ipairs(marks) do
  local details = m[4] or {}
  local vt_text = details.virt_text and details.virt_text[1] and details.virt_text[1][1] or ""
  if details.hl_group == "AgyTaskSuccess" then
    found_success_mark = true
    assert(not vt_text:find("Done"), "Success task should not have redundant [Done] text, got: " .. vt_text)
    assert(vt_text:find("2.5s"), "Success task should display duration")
  elseif details.hl_group == "AgyTaskFailed" then
    found_failed_mark = true
    assert(vt_text:find("exit 1"), "Failed task should display exit code")
  elseif details.hl_group == "AgyTaskRunning" then
    found_running_mark = true
    assert(not vt_text:find("Running"), "Running task should not have redundant [Running] text, got: " .. vt_text)
  end
end

assert(found_success_mark, "Success task extmark not found")
assert(found_failed_mark, "Failed task extmark not found")
assert(found_running_mark, "Running task extmark not found")
print("✓ render_transcript distinct task icons and extmark styling verified")

-- [Test 5] Testing live update of task status (render.update_task_status)
print("\n[Test 5] Testing live update of running task to success and failure...")
local running_tc = nil
for _, tc in ipairs(tool_calls) do
  if tc.task_id == "task-103" then
    running_tc = tc
    break
  end
end
assert(running_tc ~= nil, "Expected to find running task-103 tool record")
assert(running_tc.task_status == "running", "Expected task-103 to be running initially")

-- Dynamically complete task-103 with success
render.update_task_status(test_buf, running_tc, "success", 0)
assert(running_tc.task_status == "success", "Expected task_status to update to success")
assert(running_tc.exit_code == 0, "Expected exit_code to update to 0")

local updated_lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
local updated_task3_line = updated_lines[running_tc.header_line_idx + 1]
assert(updated_task3_line:find("^"), "Expected updated line to retain '' icon, got: " .. updated_task3_line)

-- Also verify that the extmark hl_group updated to AgyTaskSuccess
local mark_pos = vim.api.nvim_buf_get_extmark_by_id(test_buf, render.NS_UI, running_tc.header_extmark_id, { details = true })
assert(mark_pos and #mark_pos >= 3, "Expected extmark to exist for updated task")
local mark_details = mark_pos[3] or {}
assert(mark_details.hl_group == "AgyTaskSuccess", "Expected extmark hl_group to be AgyTaskSuccess, got: " .. tostring(mark_details.hl_group))
print("✓ Live update from running to success verified")

-- [Test 6] Testing build_content for /tasks interactive panel
print("\n[Test 6] Testing tasks.build_content panel layout and table...")
local pstate = {
  conversation_id = "test-tasks-conv",
  tool_calls = tool_calls,
}
local p_lines, p_meta, row_to_task = tasks.build_content(pstate, cfg, 80)
print("Generated tasks panel content:")
for idx, l in ipairs(p_lines) do
  print(string.format("  [%d] %s", idx, l))
end

assert(#p_lines > 5, "Expected tasks panel to have table rows")
assert(p_lines[1]:find("Background Tasks"), "Expected title line")
assert(p_lines[3]:find("TASK ID"), "Expected table header line")

-- Check that row_to_task maps rows to task items
local mapped_count = 0
for row, task in pairs(row_to_task) do
  mapped_count = mapped_count + 1
  assert(task.short_id ~= nil, "Expected task to have short_id")
  assert(task.status ~= nil, "Expected task to have status")
end
assert(mapped_count >= 3, "Expected at least 3 mapped tasks, got " .. mapped_count)
print("✓ tasks.build_content table formatting verified")

-- [Test 7] Testing tasks.open() panel creation and keymaps
print("\n[Test 7] Testing tasks.open() interactive panel...")
local win, buf = tasks.open(test_buf)
assert(win ~= nil and vim.api.nvim_win_is_valid(win), "Expected valid panel window")
assert(buf ~= nil and vim.api.nvim_buf_is_valid(buf), "Expected valid panel buffer")
assert(vim.bo[buf].filetype == "agy_tasks", "Expected filetype agy_tasks")

-- Close panel
require("agy.panel").close()
print("✓ tasks.open() window lifecycle verified")

-- [Test 8] Testing user command :AgyTasks and public API agy.tasks()
print("\n[Test 8] Testing :AgyTasks user command and agy.tasks()...")
local has_cmd = vim.fn.exists(":AgyTasks") == 2
assert(has_cmd, "Expected :AgyTasks user command to be registered")

local ok, p_win, p_buf = pcall(function()
  return agy.tasks(test_buf)
end)
assert(ok and p_win and vim.api.nvim_win_is_valid(p_win), "Expected agy.tasks() to succeed")
require("agy.panel").close()
print("✓ :AgyTasks user command and public API verified")

-- [Test 9] Testing protocol /tasks slash command intercept
print("\n[Test 9] Testing protocol /tasks slash command intercept...")
local proto_buf = vim.api.nvim_create_buf(false, true)
protocol._setup_buffer(proto_buf, "test-proto-conv")
protocol.buffers[proto_buf] = {
  buf = proto_buf,
  conversation_id = "test-proto-conv",
  prompt_start_line = 3,
  prompt_extmark_id = 1,
  config = cfg,
  tool_calls = tool_calls,
  stream_info = { model = "default", status = "ready" },
}

protocol.with_modifiable(proto_buf, function()
  vim.api.nvim_buf_set_lines(proto_buf, 0, -1, false, {
    "# Antigravity Session",
    "",
    "/tasks",
  })
end)

protocol.handle_write(proto_buf)
-- After handling /tasks, panel should be opened
assert(require("agy.panel").is_open(), "Expected /tasks to open panel")
require("agy.panel").close()
print("✓ Protocol /tasks command intercept verified")

-- [Test 10] Testing live background task log reading and watcher
print("\n[Test 10] Testing live background task log reading and watcher...")
local tmp_log = vim.fn.tempname() .. ".log"
vim.fn.writefile({ "Compiling core v0.1.0", "Compiling utils v0.1.0" }, tmp_log)

local tc_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_win_set_buf(0, tc_buf)
render.render_new_session(tc_buf, cfg)
local tl_live, ext_live, _ = render.append_tool_call(tc_buf, "run_command", { CommandLine = "cargo build" }, nil, cfg)
local tc_live = {
  id = 99,
  tool_name = "run_command",
  params = { CommandLine = "cargo build" },
  output = "Tool is running as a background task with task id: test/task-99\nTask logs are available at: " .. tmp_log,
  log_path = tmp_log,
  is_background_task = true,
  task_status = "running",
  header_extmark_id = ext_live,
  header_line_idx = tl_live,
  status = "done",
  is_open = false,
}
local tc_state = {
  buf = tc_buf,
  config = cfg,
  tool_calls = { tc_live },
}

-- 10a. Verify get_tool_output reads from log file
local live_out = render.get_tool_output(tc_live)
assert(live_out:find("Compiling core v0.1.0"), "get_tool_output must read from log file: " .. live_out)

-- 10b. Open inline window and verify live watcher starts
local opened = render.toggle_tool_output(tc_buf, tc_state, tc_live)
assert(opened == true, "Must open inline window for background task")
assert(tc_live.is_open == true, "Task tool call must be marked open")
assert(tc_live.log_timer ~= nil, "Live task log timer watcher must be running")

local initial_lines = vim.api.nvim_buf_get_lines(tc_live.win_buf, 0, -1, false)
assert(#initial_lines == 2, "Window must contain initial 2 log lines, got " .. #initial_lines)
assert(initial_lines[1] == "Compiling core v0.1.0", "Line 1 in window")

-- 10c. Append to log file and verify live window update and bottom cursor
vim.fn.writefile({ "Compiling core v0.1.0", "Compiling utils v0.1.0", "Finished release target(s)", "Process exited with 0" }, tmp_log)
local updated = vim.wait(1000, function()
  return vim.api.nvim_buf_line_count(tc_live.win_buf) == 4
end, 50)
assert(updated == true, "Inline window must automatically refresh with new log lines")
local cur_win_cursor = vim.api.nvim_win_get_cursor(tc_live.win)
assert(cur_win_cursor[1] == 4, "run_command cursor must follow to bottom line 4")

-- 10d. Task completion terminates watcher
render.update_task_status(tc_buf, tc_live, "success", 0, cfg)
assert(tc_live.log_timer == nil, "Task watcher timer must stop when task completes")

-- 10e. Close window
render.close_tool_window(tc_state, tc_live)
assert(tc_live.is_open == false, "Window closed")
vim.fn.delete(tmp_log)
vim.cmd("bdelete! " .. tc_buf)
print("✓ Live background task log reading, auto-refresh, and watcher verified")

print("\nALL TASKS & STATUS TESTS PASSED SUCCESSFULLY!")
vim.cmd("qall!")
