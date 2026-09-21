local protocol = require("agy.protocol")
local render = require("agy.render")
local utils = require("agy.utils")

print("=== Running Prompt Area Bottom Border & Active Turn Rendering Tests ===")

require("agy").setup()

-- =========================================================================
-- TEST 1: Bottom border present in idle session buffer
-- =========================================================================
print("\n[Test 1] Testing bottom border in idle session buffer...")

vim.cmd("edit agy://new")
local buf1 = vim.api.nvim_get_current_buf()
local state1 = protocol.buffers[buf1]
assert(state1 ~= nil, "State must exist for agy://new")

-- Wait for session initialization
vim.wait(500, function()
  return state1.stream_info and state1.stream_info.status == "ready"
end)

assert(state1.prompt_extmark_id ~= nil, "Prompt divider extmark must be set")
assert(state1.footer_extmark_id ~= nil, "Footer extmark must be set")

local foot_mark_1 = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
assert(foot_mark_1 ~= nil and foot_mark_1[3] ~= nil, "Footer extmark details must exist")
local virt_lines_1 = foot_mark_1[3].virt_lines
assert(#virt_lines_1 >= 2, "Idle footer must contain at least 2 virt_lines (border + footer text)")
assert(virt_lines_1[1][1][2] == "AgyPromptBorder", "First virt_line must be AgyPromptBorder")
assert(virt_lines_1[1][1][1]:find("^───"), "Border line must start with horizontal divider characters")
assert(virt_lines_1[2][1][2] == "AgyPromptFooter", "Second virt_line must be AgyPromptFooter")
assert(virt_lines_1[2][1][1]:find("⚡"), "Footer line must contain ⚡ status icon")

print("✓ Idle buffer renders upper divider, prompt line, bottom border line, and footer")

-- =========================================================================
-- TEST 2: Brief state immediately upon prompt submission before restore
-- =========================================================================
print("\n[Test 2] Testing footer immediately upon submission before prompt area is restored...")

-- Type prompt text
local prompt_line = state1.prompt_start_line
vim.api.nvim_buf_set_lines(buf1, prompt_line - 1, -1, false, { "Explain this repo" })

-- Simulate submit_prompt setup
protocol.with_modifiable(buf1, function()
  local extmark_id, agent_line = render.prepare_turn_submission(buf1, state1.prompt_start_line, state1.prompt_extmark_id)
  state1.agent_extmark_id = extmark_id
  state1.agent_line = agent_line
  state1.prompt_extmark_id = nil
end)
state1.session.turn_active = true
state1.stream_info.status = "thinking"
protocol.update_footer(buf1)

local foot_mark_2 = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
assert(foot_mark_2 ~= nil and foot_mark_2[3] ~= nil, "Footer extmark must exist after submission")
local virt_lines_2 = foot_mark_2[3].virt_lines
assert(#virt_lines_2 == 1, "Before prompt is restored, footer must only have 1 virt_line (footer status only)")
assert(virt_lines_2[1][1][2] == "AgyPromptFooter", "virt_line must be AgyPromptFooter")
assert(virt_lines_2[1][1][1]:find("%[Thinking%.%.%.%]"), "Footer must display [Thinking...]")

print("✓ When prompt area is not present, bottom border is omitted cleanly")

-- =========================================================================
-- TEST 3: Restored prompt area during active turn renders bottom border line
-- =========================================================================
print("\n[Test 3] Testing restored prompt area during active turn has bottom border line...")

-- Restore prompt area while turn is active (as restore_prompt_area does)
protocol.restore_prompt_area(buf1)

assert(state1.prompt_extmark_id ~= nil, "prompt_extmark_id must be restored")
assert(state1.session.turn_active == true, "Turn is still active")
assert(state1.agent_extmark_id ~= nil, "Agent extmark is still active")

local foot_mark_3 = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
assert(foot_mark_3 ~= nil and foot_mark_3[3] ~= nil, "Footer extmark must exist after prompt area restored")
local virt_lines_3 = foot_mark_3[3].virt_lines
assert(#virt_lines_3 >= 2, "Active turn with restored prompt must contain at least 2 virt_lines (bottom border + footer)")
assert(virt_lines_3[1][1][2] == "AgyPromptBorder", "First virt_line must be AgyPromptBorder (bottom border of input)")
assert(virt_lines_3[1][1][1]:find("^───"), "Bottom border must be a horizontal line")
assert(virt_lines_3[2][1][2] == "AgyPromptFooter", "Second virt_line must be AgyPromptFooter")
assert(virt_lines_3[2][1][1]:find("%[Thinking%.%.%.%]"), "Footer must still display active turn status")

-- Verify footer extmark row is on the last line of the buffer (the prompt line)
local line_count_3 = vim.api.nvim_buf_line_count(buf1)
assert(foot_mark_3[1] == line_count_3 - 1, "Footer extmark must be attached to the prompt line (last line)")

print("✓ Restored prompt area during active turn has bottom border separating input from footer")

-- =========================================================================
-- TEST 4: Streaming deltas, thoughts, and tool calls maintain bottom border
-- =========================================================================
print("\n[Test 4] Testing streaming steps maintain bottom border below restored prompt...")

-- 4a. Thought block
protocol.with_modifiable(buf1, function()
  render.append_thought_block(buf1, "Analyzing codebase structure...", 2.0, state1.config)
  protocol.update_footer(buf1)
end)

local foot_mark_thought = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
local vl_thought = foot_mark_thought[3].virt_lines
assert(#vl_thought >= 2, "Must retain bottom border after thought block")
assert(vl_thought[1][1][2] == "AgyPromptBorder", "First virt_line must remain AgyPromptBorder")

-- 4b. Tool call
protocol.with_modifiable(buf1, function()
  render.append_tool_call(buf1, "run_command", { CommandLine = "Get-ChildItem -Force" }, nil, state1.config)
  state1.stream_info.status = "tool:run_command"
  protocol.update_footer(buf1)
end)

local foot_mark_tool = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
local vl_tool = foot_mark_tool[3].virt_lines
assert(#vl_tool >= 2, "Must retain bottom border after tool call")
assert(vl_tool[1][1][2] == "AgyPromptBorder", "First virt_line must remain AgyPromptBorder")
assert(vl_tool[2][1][1]:find("Running run_command"), "Footer must show running tool status")

-- 4c. Text delta
protocol.with_modifiable(buf1, function()
  render.append_text_delta(buf1, "Here is the directory listing.\nAll files found.\n", state1.config)
  state1.stream_info.status = "generating"
  protocol.update_footer(buf1)
end)

local foot_mark_delta = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
local vl_delta = foot_mark_delta[3].virt_lines
assert(#vl_delta >= 2, "Must retain bottom border after text delta")
assert(vl_delta[1][1][2] == "AgyPromptBorder", "First virt_line must remain AgyPromptBorder")
assert(vl_delta[2][1][1]:find("%[Generating%.%.%.%]"), "Footer must show [Generating...]")

local cur_line_count = vim.api.nvim_buf_line_count(buf1)
assert(foot_mark_delta[1] == cur_line_count - 1, "Footer must be attached to the prompt line at buffer bottom")

print("✓ Streaming steps correctly push prompt down and maintain bottom border")

-- =========================================================================
-- TEST 5: Typing in restored prompt area during turn preserves bottom border
-- =========================================================================
print("\n[Test 5] Testing typing in restored prompt area during turn preserves bottom border...")

local win1 = vim.api.nvim_get_current_win()
local prompt_line_cur = state1.prompt_start_line
vim.api.nvim_win_set_cursor(win1, { prompt_line_cur, 0 })
protocol.update_modifiable(buf1)
vim.api.nvim_buf_set_lines(buf1, prompt_line_cur - 1, -1, false, { "Queued question line 1", "Queued question line 2" })
protocol.update_prompt_divider(buf1)
protocol.update_footer(buf1)

local foot_mark_multi = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
local vl_multi = foot_mark_multi[3].virt_lines
assert(#vl_multi >= 2, "Must retain bottom border with multi-line prompt")
assert(vl_multi[1][1][2] == "AgyPromptBorder", "First virt_line must be AgyPromptBorder")

local line_count_multi = vim.api.nvim_buf_line_count(buf1)
assert(foot_mark_multi[1] == line_count_multi - 1, "Footer must be anchored after line 2 of prompt input")

print("✓ Typing multi-line prompt during active turn preserves bottom border")

-- =========================================================================
-- TEST 6: Disabled prompt footer preserves bottom border line
-- =========================================================================
print("\n[Test 6] Testing prompt bottom border when prompt_footer is disabled in config...")

state1.config.ui.prompt_footer = false
protocol.update_footer(buf1)

local foot_mark_nofoot = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
assert(foot_mark_nofoot ~= nil and foot_mark_nofoot[3] ~= nil, "Footer extmark must still exist for border")
local vl_nofoot = foot_mark_nofoot[3].virt_lines
assert(#vl_nofoot == 1, "When prompt_footer is disabled, exactly 1 virt_line must exist (AgyPromptBorder)")
assert(vl_nofoot[1][1][2] == "AgyPromptBorder", "virt_line must be AgyPromptBorder")

-- Restore config
state1.config.ui.prompt_footer = true
protocol.update_footer(buf1)

print("✓ Disabled prompt footer preserves bottom border line")

-- =========================================================================
-- TEST 7: Turn completion (finalize_turn) seamlessly transitions bottom border
-- =========================================================================
print("\n[Test 7] Testing finalize_turn maintains bottom border...")

state1.session.turn_active = false
state1.stream_info.status = "ready"

protocol.with_modifiable(buf1, function()
  local result = {
    status = "SUCCESS",
    duration_seconds = 3.5,
    usage = { total_tokens = 1200 },
  }
  local next_line, prompt_ext_id = render.finalize_turn(buf1, state1.agent_extmark_id, state1.agent_line, result, state1.config)
  state1.prompt_start_line = next_line
  state1.prompt_extmark_id = prompt_ext_id
  state1.agent_extmark_id = nil
  state1.agent_line = nil
end)
protocol.update_footer(buf1)

local foot_mark_done = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
local vl_done = foot_mark_done[3].virt_lines
assert(#vl_done >= 2, "Must retain bottom border after turn completion")
assert(vl_done[1][1][2] == "AgyPromptBorder", "First virt_line must be AgyPromptBorder")
assert(vl_done[2][1][2] == "AgyPromptFooter", "Second virt_line must be AgyPromptFooter")

print("✓ Turn completion seamlessly maintains bottom border line")

-- =========================================================================
-- TEST 8: Active question suppresses prompt bottom border
-- =========================================================================
print("\n[Test 8] Testing active question mode suppresses prompt bottom border...")

state1.active_question = {
  questions = { { question = "Proceed?", options = { "Yes", "No" } } },
  first_option_line = 10,
}
state1.stream_info.status = "question"
protocol.update_footer(buf1)

local foot_mark_q = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
local vl_q = foot_mark_q[3].virt_lines
assert(#vl_q == 1, "Active question must only have 1 virt_line (footer question text)")
assert(vl_q[1][1][2] == "AgyPromptFooter", "virt_line must be AgyPromptFooter")
assert(vl_q[1][1][1]:find("Awaiting answer"), "Footer must prompt for answer")

state1.active_question = nil
protocol.update_footer(buf1)

local foot_mark_q_cleared = vim.api.nvim_buf_get_extmark_by_id(buf1, render.NS_UI, state1.footer_extmark_id, { details = true })
local vl_q_cleared = foot_mark_q_cleared[3].virt_lines
assert(#vl_q_cleared >= 2, "Must restore prompt bottom border once question is cleared")
assert(vl_q_cleared[1][1][2] == "AgyPromptBorder", "First virt_line must be AgyPromptBorder")
protocol.cleanup_buffer(buf1)
vim.cmd("bdelete! " .. buf1)

print("✓ Active question mode suppresses prompt bottom border, and restores it when cleared")

-- =========================================================================
-- TEST 9: Background task notification during active turn with restored prompt
-- =========================================================================
print("\n[Test 9] Testing background task update does not displace prompt border...")

vim.cmd("edit agy://new")
local buf9 = vim.api.nvim_get_current_buf()
local state9 = protocol.buffers[buf9]
vim.wait(500, function() return state9.stream_info and state9.stream_info.status == "ready" end)

-- Type and submit
local p_start9 = state9.prompt_start_line
vim.api.nvim_buf_set_lines(buf9, p_start9 - 1, -1, false, { "Run background build" })
protocol.with_modifiable(buf9, function()
  local extmark_id, agent_line = render.prepare_turn_submission(buf9, state9.prompt_start_line, state9.prompt_extmark_id)
  state9.agent_extmark_id = extmark_id
  state9.agent_line = agent_line
  state9.prompt_extmark_id = nil
end)
state9.session.turn_active = true
protocol.restore_prompt_area(buf9)

-- Agent initiates background task
protocol.with_modifiable(buf9, function()
  local tl, eid, pstr = render.append_tool_call(buf9, "run_command", { CommandLine = "cargo build" }, vim.fn.getcwd(), state9.config)
  local tc_rec = {
    id = 1,
    tool_name = "run_command",
    is_background_task = true,
    task_id = "task-build-1",
    short_id = "task-build-1",
    task_status = "running",
    header_extmark_id = eid,
    header_line_idx = tl,
  }
  table.insert(state9.tool_calls, tc_rec)
  state9.stream_info.status = "tool:run_command"
  protocol.update_footer(buf9)
end)

-- User types multi-line question in prompt area while task is running
local win9 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(win9, { state9.prompt_start_line, 0 })
protocol.update_modifiable(buf9)
vim.api.nvim_buf_set_lines(buf9, state9.prompt_start_line - 1, -1, false, { "While cargo builds,", "explain the architecture." })
protocol.update_prompt_divider(buf9)
protocol.update_footer(buf9)

-- Background task completion notification arrives
protocol.with_modifiable(buf9, function()
  render.update_task_status(buf9, state9.tool_calls[1], "completed", 0, state9.config)
  state9.stream_info.status = "thinking"
  protocol.update_footer(buf9)
end)

local foot_mark_bg = vim.api.nvim_buf_get_extmark_by_id(buf9, render.NS_UI, state9.footer_extmark_id, { details = true })
assert(foot_mark_bg ~= nil and foot_mark_bg[3] ~= nil, "Footer extmark must exist after bg task completion")
local vl_bg = foot_mark_bg[3].virt_lines
assert(#vl_bg >= 2, "Must retain both border and footer after bg task completion")
assert(vl_bg[1][1][2] == "AgyPromptBorder", "First virt_line must remain AgyPromptBorder")
assert(vl_bg[2][1][2] == "AgyPromptFooter", "Second virt_line must remain AgyPromptFooter")

local line_count_9 = vim.api.nvim_buf_line_count(buf9)
assert(foot_mark_bg[1] == line_count_9 - 1, "Footer must be attached to the final line of multi-line prompt")

protocol.cleanup_buffer(buf9)
vim.cmd("bdelete! " .. buf9)
print("✓ Background task notification preserves bottom border beneath multi-line prompt")

-- =========================================================================
-- TEST 10: Custom icons persistence across typing and window resize
-- =========================================================================
print("\n[Test 10] Testing custom icons and border persistence across update_prompt_divider and resize...")

local custom_config = require("agy.config").setup({
  icons = {
    prompt_sign = "➜ ",
    footer = "🚀",
    user = "🧑",
    agent = "👾",
  },
})

local buf10 = vim.api.nvim_create_buf(false, true)
protocol.buffers[buf10] = {
  config = custom_config,
  stream_info = { status = "ready", model = "gemini-3.8" },
  session = { turn_active = false },
  tool_calls = {},
}
local p_line10, p_ext10 = render.render_new_session(buf10, custom_config)
protocol.buffers[buf10].prompt_start_line = p_line10
protocol.buffers[buf10].prompt_extmark_id = p_ext10
protocol.update_footer(buf10)

-- Check initial prompt sign
local sign_em10 = vim.api.nvim_buf_get_extmark_by_id(buf10, render.NS_UI, p_ext10, { details = true })
assert(sign_em10[3].sign_text == "➜ ", "Initial prompt sign must be custom '➜ '")

-- User types in prompt area, triggering update_prompt_divider
vim.api.nvim_buf_set_lines(buf10, p_line10 - 1, -1, false, { "My custom icon prompt" })
protocol.update_prompt_divider(buf10)
protocol.update_footer(buf10)

-- Verify custom prompt sign did not get reset to default '❯ '
local sign_em10_after = vim.api.nvim_buf_get_extmark_by_id(buf10, render.NS_UI, protocol.buffers[buf10].prompt_extmark_id, { details = true })
assert(sign_em10_after[3].sign_text == "➜ ", "Prompt sign must remain custom '➜ ' after update_prompt_divider")

-- Trigger window resize event simulation
protocol.update_prompt_divider(buf10)
protocol.update_footer(buf10)

local foot_mark_10 = vim.api.nvim_buf_get_extmark_by_id(buf10, render.NS_UI, protocol.buffers[buf10].footer_extmark_id, { details = true })
local vl_10 = foot_mark_10[3].virt_lines
assert(#vl_10 >= 2, "Must have bottom border and footer")
assert(vl_10[1][1][2] == "AgyPromptBorder", "First line must be AgyPromptBorder")
assert(vl_10[2][1][1]:find("🚀"), "Footer line must use custom footer icon '🚀'")

protocol.cleanup_buffer(buf10)
vim.cmd("bdelete! " .. buf10)
print("✓ Custom icons and bottom border persist across typing and resize")

print("\nALL PROMPT BORDER & ACTIVE TURN TESTS PASSED PERFECTLY!")

