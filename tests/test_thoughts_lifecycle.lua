local utils = require("agy.utils")
local render = require("agy.render")
local protocol = require("agy.protocol")
local transcript = require("agy.transcript")
local config_mod = require("agy.config")
local test_helpers = require("tests.test_helpers")

print("=== Running Thoughts Lifecycle & Stack Prevention Tests ===")

local test_icons = {
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
}

local tmp_env, conv_id = test_helpers.create_mock_environment()
local brain_logs = tmp_env .. "/brain/" .. conv_id .. "/.system_generated/logs"

local cfg = config_mod.setup({
  app_data_dir = tmp_env,
  icons = test_icons,
  ui = {
    virtual_text = true,
    auto_scroll = false,
    fold_tool_output = false,
    protect_history = true,
    show_thoughts = true,
  },
})
protocol.setup()

-- =========================================================================
-- TEST 1: Live Text Response Turn Does NOT Append Stack of Thoughts at Bottom
-- =========================================================================
print("\n[Test 1] Testing live text response turn does NOT append thoughts to bottom on result...")

local buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, "agy://" .. conv_id)
protocol.handle_buf_read({ buf = buf, file = "agy://" .. conv_id })

local state = protocol.buffers[buf]
assert(state ~= nil, "Protocol state must exist for buffer")

-- Prepare turn submission as if user pressed :w
local old_prompt_line = state.prompt_start_line or 8
local agent_extmark_id, agent_line = render.prepare_turn_submission(buf, old_prompt_line, state.prompt_extmark_id, cfg)
state.agent_extmark_id = agent_extmark_id
state.agent_line = agent_line
state.active_agent_started_output = false

-- Model streams text delta
state.session.on_step_update(state.session, {
  step_type = "agent_response",
  text_delta = "Here is the final response to the user query.\nEverything is complete.",
})

assert(state.active_agent_started_output == true, "active_agent_started_output must be true after text delta")

-- Behind the scenes, CLI finishes turn and writes PLANNER_RESPONSE with thinking to disk
local tf = io.open(brain_logs .. "/transcript_full.jsonl", "w")
assert(tf ~= nil, "Failed to open transcript_full.jsonl")
tf:write(vim.json.encode({
  step_index = 0,
  type = "USER_INPUT",
  content = "Explain how thoughts work",
  created_at = "2026-09-20T21:00:00Z",
}) .. "\n")
tf:write(vim.json.encode({
  step_index = 1,
  type = "PLANNER_RESPONSE",
  thinking = "Deep chain-of-thought reasoning that should not end up below the text.",
  content = "Here is the final response to the user query.\nEverything is complete.",
  created_at = "2026-09-20T21:00:02Z",
}) .. "\n")
tf:close()

-- CLI sends result event
state.session.on_result(state.session, {
  conversation_id = conv_id,
  status = "SUCCESS",
  duration_seconds = 2.0,
})

-- Inspect buffer lines after turn completes
local lines_after_turn = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Buffer lines after turn completion:")
for idx, l in ipairs(lines_after_turn) do
  print(string.format("  [%2d] %s", idx, l))
end

-- Find where "Everything is complete." is
local text_line_idx = nil
for idx, l in ipairs(lines_after_turn) do
  if l:find("Everything is complete.") then
    text_line_idx = idx
  end
end
assert(text_line_idx ~= nil, "Text response must be present in buffer")

-- Verify NO "Thought" line exists below the text response line!
for idx = text_line_idx + 1, #lines_after_turn do
  local l = lines_after_turn[idx]
  assert(not l:find("Thought"), string.format("Thought block must NOT be rendered at bottom after text output! Found at line %d: %s", idx, l))
end

-- Verify step 1 thinking was marked as acknowledged in rendered_thinking
local key_step1 = "1:Deep chain-of-thought reasoning that should not end up below the text."
assert(state.rendered_thinking[key_step1] == true, "Step 1 thinking must be marked in state.rendered_thinking")
assert(state.active_agent_started_output == false, "active_agent_started_output must be reset to false for next turn")
print("✓ Live text response turn successfully prevented thoughts at the bottom")

-- =========================================================================
-- TEST 2: Subsequent Turn with Tool Call Does NOT Re-render Previous Turn's Thoughts
-- =========================================================================
print("\n[Test 2] Testing subsequent turn does NOT leak prior turn's thoughts...")

-- Add Turn 2 to transcript on disk: User prompt + PLANNER_RESPONSE with tool call
local tf2 = io.open(brain_logs .. "/transcript_full.jsonl", "a")
assert(tf2 ~= nil)
tf2:write(vim.json.encode({
  step_index = 2,
  type = "USER_INPUT",
  content = "Now check status",
  created_at = "2026-09-20T21:01:00Z",
}) .. "\n")
tf2:write(vim.json.encode({
  step_index = 3,
  type = "PLANNER_RESPONSE",
  thinking = "Turn 2 thinking before tool call.",
  tool_calls = {
    { name = "run_command", args = { CommandLine = "git status" } }
  },
  created_at = "2026-09-20T21:01:02Z",
}) .. "\n")
tf2:close()

-- Simulate starting Turn 2 in the buffer
protocol.with_modifiable(buf, function()
  local agent_extmark_id2, agent_line2 = render.prepare_turn_submission(buf, state.prompt_start_line, state.prompt_extmark_id, cfg)
  state.agent_extmark_id = agent_extmark_id2
  state.agent_line = agent_line2
end)
state.active_agent_started_output = false

-- Tool call arrives ACTIVE in Turn 2
state.session.on_step_update(state.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "git status" },
  },
})

-- Count thought blocks in buffer
local lines_turn2 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local thought_count = 0
for idx, l in ipairs(lines_turn2) do
  if l:find("Thought") then
    thought_count = thought_count + 1
  end
end

assert(thought_count == 1, "Only Turn 2's thought must be rendered before tool call, expected 1 thought block, got: " .. tostring(thought_count))

-- Verify the rendered thought block contains Turn 2's thinking, not Turn 1's
local last_tc = state.tool_calls[#state.tool_calls - 1] -- Thought is right before run_command
assert(last_tc ~= nil and last_tc.is_thought == true, "Must have thought record before tool call")
assert(last_tc.output == "Turn 2 thinking before tool call.", "Rendered thought must match Turn 2 thinking")
print("✓ Subsequent turn did not leak or stack prior turn's thoughts")

-- =========================================================================
-- TEST 3: Buffer Reload (:e) Places Thoughts Chronologically Above Output
-- =========================================================================
print("\n[Test 3] Testing buffer reload (:e) positions thoughts above output without bottom stack...")

-- Complete Turn 2 in transcript on disk
local tf3 = io.open(brain_logs .. "/transcript_full.jsonl", "a")
assert(tf3 ~= nil)
tf3:write(vim.json.encode({
  step_index = 4,
  type = "TOOL_OUTPUT",
  content = "On branch main\nnothing to commit",
  created_at = "2026-09-20T21:01:03Z",
}) .. "\n")
tf3:write(vim.json.encode({
  step_index = 5,
  type = "PLANNER_RESPONSE",
  thinking = "Turn 2 final thinking.",
  content = "Branch is clean.",
  created_at = "2026-09-20T21:01:04Z",
}) .. "\n")
tf3:close()

-- Reload buffer (simulating user executing :e)
vim.cmd("edit")

local reload_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Reload buffer lines:")
for idx, l in ipairs(reload_lines) do
  print(string.format("  [%2d] %s", idx, l))
end

-- Verify no thought block appears at the very bottom
local last_non_empty = nil
for idx = #reload_lines, 1, -1 do
  if reload_lines[idx] ~= "" then
    last_non_empty = reload_lines[idx]
    break
  end
end
assert(last_non_empty ~= nil and not last_non_empty:find("Thought"), "Bottom of conversation must not be a thought block: " .. tostring(last_non_empty))

-- Verify thoughts appear before their respective content
local t1_thought_idx, t1_content_idx = nil, nil
local t2_thought_idx, t2_tool_idx = nil, nil
for idx, l in ipairs(reload_lines) do
  if l:find("Thought") and not t1_thought_idx then
    t1_thought_idx = idx
  elseif l:find("Here is the final response") then
    t1_content_idx = idx
  elseif l:find("run_command") then
    t2_tool_idx = idx
  end
end

assert(t1_thought_idx ~= nil and t1_content_idx ~= nil, "Turn 1 thought and content must exist in reloaded buffer")
assert(t1_thought_idx < t1_content_idx, "Turn 1 thought must precede its content")
print("✓ Reload (:e) positions thoughts above output without bottom stack")

-- =========================================================================
-- TEST 4: Tool-Only Turn Still Flushes Pending Thoughts on Result
-- =========================================================================
print("\n[Test 4] Testing tool-only turn still flushes pending thoughts on result...")

local buf4 = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(buf4)
local conv4 = "test-conv-tool-only-0000-1111-2222"
local brain_logs4 = tmp_env .. "/brain/" .. conv4 .. "/.system_generated/logs"
vim.fn.mkdir(brain_logs4, "p")

local tf4 = io.open(brain_logs4 .. "/transcript_full.jsonl", "w")
assert(tf4 ~= nil)
tf4:write(vim.json.encode({
  step_index = 0,
  type = "USER_INPUT",
  content = "Run tool only",
  created_at = "2026-09-20T22:00:00Z",
}) .. "\n")
tf4:write(vim.json.encode({
  step_index = 1,
  type = "PLANNER_RESPONSE",
  thinking = "Thinking before tool in tool-only turn.",
  tool_calls = {
    { name = "run_command", args = { CommandLine = "echo hello" } }
  },
  created_at = "2026-09-20T22:00:01Z",
}) .. "\n")
tf4:close()

vim.api.nvim_buf_set_name(buf4, "agy://" .. conv4)
protocol.handle_buf_read({ buf = buf4, file = "agy://" .. conv4 })
local state4 = protocol.buffers[buf4]
assert(state4 ~= nil)

protocol.with_modifiable(buf4, function()
  local em_id, a_line = render.prepare_turn_submission(buf4, state4.prompt_start_line, state4.prompt_extmark_id, cfg)
  state4.agent_extmark_id = em_id
  state4.agent_line = a_line
end)
state4.active_agent_started_output = false

-- Step 1 tool arrives ACTIVE and completes DONE
state4.session.on_step_update(state4.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    parameters = { CommandLine = "echo hello" },
  },
})
state4.session.on_step_update(state4.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "DONE",
  duration_seconds = 0.05,
  tool_info = {
    output = "hello",
  },
})

-- Turn completes with result event and active_agent_started_output was never set to true
state4.session.on_result(state4.session, {
  conversation_id = conv4,
  status = "SUCCESS",
  duration_seconds = 0.5,
})

local lines4 = vim.api.nvim_buf_get_lines(buf4, 0, -1, false)
local found_thought4 = false
for _, l in ipairs(lines4) do
  if l:find("Thought") then
    found_thought4 = true
  end
end
assert(found_thought4 == true, "Tool-only turn must have rendered the thought block")
assert(state4.active_agent_started_output == false, "active_agent_started_output must be false after turn")
print("✓ Tool-only turn successfully flushes thoughts")

-- Clean up
protocol.cleanup_buffer(buf)
protocol.cleanup_buffer(buf4)

print("\nALL THOUGHTS LIFECYCLE TESTS PASSED SUCCESSFULLY!")
