local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")
local utils = require("agy.utils")

print("=== Running Prompt Queue Tests ===")

-- -----------------------------------------------------------------
-- TEST 1: Config icons, assertions, and header detection
-- -----------------------------------------------------------------
print("\n[Test 1] Testing queue icon registration, assertion, and header detection...")

local cfg = config.get()
assert(cfg.icons.queue == "⏳", "Default queue icon must be '⏳', got: " .. tostring(cfg.icons.queue))

-- Verify fail-fast assertion on missing queue icon
local broken_cfg = { icons = {} }
local ok_assert, err_assert = pcall(function()
  render.is_queue_header_line("⏳ Queued #1: test", broken_cfg)
end)
assert(not ok_assert, "Expected fail-fast assertion when icon 'queue' is missing")
assert(err_assert:find("icon 'queue' is not defined"), "Error message should mention missing queue icon: " .. tostring(err_assert))

-- Verify is_queue_header_line with default and custom icons
assert(render.is_queue_header_line("⏳ Queued #1: Fix the bugs", cfg) == true, "Should identify default queue header")
assert(render.is_queue_header_line("⏳ Queued #2: Add tests", cfg) == true, "Should identify default queue header #2")
assert(render.is_queue_header_line("⏳ Queued: Legacy format", cfg) == true, "Should identify unnumbered queue header")
assert(render.is_queue_header_line("   indented line", cfg) == false, "Indented lines must not be queue headers")
assert(render.is_queue_header_line("Regular message text", cfg) == false, "Regular text must not be queue header")

local custom_cfg = {
  icons = vim.tbl_extend("force", cfg.icons, { queue = "📬" }),
}
assert(render.is_queue_header_line("📬 Queued #1: Custom icon", custom_cfg) == true, "Should identify custom queue icon header")

print("✓ Queue icon registration, assertions, and header line detection verified")

-- -----------------------------------------------------------------
-- TEST 2: Low-level queue rendering and extmarks
-- -----------------------------------------------------------------
print("\n[Test 2] Testing render.render_queue layout and extmarks...")

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# Antigravity Session: agy://new",
  "",
  "User message 1",
  "Agent response 1",
  "",
  "",
})
local prompt_line = 6
local prompt_ext_id = render.set_divider(buf, prompt_line - 1, "user", nil, nil, true, nil, cfg)

local queue_items = {
  { id = 1, text = "First queued message" },
  { id = 2, text = "Second queued message\nwith a second line\nand a third line" },
}

render.render_queue(buf, queue_items, prompt_line, cfg)

local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Buffer lines with rendered queue:")
for idx, l in ipairs(buf_lines) do
  print(string.format("  [%d] %s", idx, l))
end

local found_q1 = false
local found_q2 = false
local found_q2_subline = false
for _, l in ipairs(buf_lines) do
  if l:find("⏳ Queued #1: First queued message") then found_q1 = true end
  if l:find("⏳ Queued #2: Second queued message") then found_q2 = true end
  if l:find("   with a second line") then found_q2_subline = true end
end
assert(found_q1, "Queue item #1 header must be rendered")
assert(found_q2, "Queue item #2 header must be rendered")
assert(found_q2_subline, "Multi-line queue message must have 3-space indentation")

-- Verify extmarks in NS_QUEUE
local q_extmarks = vim.api.nvim_buf_get_extmarks(buf, render.NS_QUEUE, 0, -1, { details = true })
print(string.format("Found %d queue extmarks in NS_QUEUE", #q_extmarks))
assert(#q_extmarks == 2, "Must have exactly 2 extmarks in NS_QUEUE (one per queued message)")

for _, qm in ipairs(q_extmarks) do
  local details = qm[4]
  assert(details.virt_text ~= nil, "Queue extmark must have virt_text badge")
  assert(details.virt_text[1][1] == " [press <CR> to edit]", "Virtual badge text must be ' [press <CR> to edit]'")
  assert(details.virt_text[1][2] == "AgyQueueBadge", "Virtual badge highlight must be AgyQueueBadge")
  assert(details.line_hl_group == "AgyQueueHeader", "Queue header line highlight must be AgyQueueHeader")
end

-- Clear queue by passing empty array
render.render_queue(buf, {}, prompt_line, cfg)
local cleared_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_QUEUE, 0, -1, {})
assert(#cleared_marks == 0, "All queue extmarks must be cleared when queue is empty")

local lines_after_clear = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for _, l in ipairs(lines_after_clear) do
  assert(not l:find("Queued #"), "Queue lines must be removed when queue is empty")
end

print("✓ Low-level render_queue formatting, badges, and clearing verified")

-- -----------------------------------------------------------------
-- TEST 3: High-level queue_prompt on :w while turn is active
-- -----------------------------------------------------------------
print("\n[Test 3] Testing protocol.queue_prompt while turn is active...")

require("agy").setup()
vim.cmd("edit agy://new")
local agy_buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()
local state = protocol.buffers[agy_buf]
assert(state, "Buffer state must exist")

-- Wait for session initialization
vim.wait(100, function() return state.stream_info.status == "ready" end)

-- Mock active turn
state.session.turn_active = true
state.stream_info.status = "thinking"

-- 3a. Verify empty prompt does not queue
vim.api.nvim_buf_set_lines(agy_buf, state.prompt_start_line - 1, -1, false, { "" })
protocol.handle_write(agy_buf)
assert(state.prompt_queue == nil or #state.prompt_queue == 0, "Empty prompt should not be queued")

-- 3b. Queue first message
local msg1 = "Run integration tests"
vim.api.nvim_buf_set_lines(agy_buf, state.prompt_start_line - 1, -1, false, { msg1 })
protocol.handle_write(agy_buf)

assert(state.prompt_queue ~= nil and #state.prompt_queue == 1, "prompt_queue must have 1 item")
assert(state.prompt_queue[1].text == msg1, "Queued text must match msg1")
assert(state.prompt_queue[1].id == 1, "Queued id must be 1")

-- Check that prompt area was cleared for the user to continue typing
local prompt_after_q1 = protocol.extract_prompt(agy_buf)
assert(prompt_after_q1 == "", "Prompt input area must be cleared after queueing: '" .. prompt_after_q1 .. "'")

-- 3c. Queue second message (multi-line)
local msg2 = "Check git status\nand report modified files"
vim.api.nvim_buf_set_lines(agy_buf, state.prompt_start_line - 1, -1, false, utils.split_lines(msg2))
protocol.handle_write(agy_buf)

assert(#state.prompt_queue == 2, "prompt_queue must have 2 items")
assert(state.prompt_queue[2].text == msg2, "Queued text must match msg2")
assert(state.prompt_queue[2].id == 2, "Queued id must be 2")

-- Verify visual representation in the buffer
local active_lines = vim.api.nvim_buf_get_lines(agy_buf, 0, -1, false)
local has_vis_q1 = false
local has_vis_q2 = false
for _, l in ipairs(active_lines) do
  if l:find("⏳ Queued #1: Run integration tests") then has_vis_q1 = true end
  if l:find("⏳ Queued #2: Check git status") then has_vis_q2 = true end
end
assert(has_vis_q1, "Buffer must visually display Queued #1")
assert(has_vis_q2, "Buffer must visually display Queued #2")

print("✓ Queueing prompts on :w while turn is active verified")

-- -----------------------------------------------------------------
-- TEST 4: Unqueueing via <CR> at cursor
-- -----------------------------------------------------------------
print("\n[Test 4] Testing unqueue_prompt_at_cursor on <CR>...")

-- Locate the line number of Queued #1
local q1_line = nil
for idx, l in ipairs(vim.api.nvim_buf_get_lines(agy_buf, 0, -1, false)) do
  if l:find("⏳ Queued #1:") then
    q1_line = idx
    break
  end
end
assert(q1_line ~= nil, "Must locate Queued #1 line in buffer")

-- Position cursor on Queued #1
vim.api.nvim_win_set_cursor(win, { q1_line, 2 })

-- Unqueue via unqueue_prompt_at_cursor (called on <CR>)
local handled = protocol.unqueue_prompt_at_cursor(agy_buf, q1_line)
assert(handled == true, "unqueue_prompt_at_cursor must return true")

-- Check that prompt_queue now only has 1 item, re-indexed to #1
assert(#state.prompt_queue == 1, "prompt_queue must have 1 remaining item")
assert(state.prompt_queue[1].id == 1, "Remaining item must be re-indexed to id 1")
assert(state.prompt_queue[1].text == msg2, "Remaining item must be msg2")

-- Check that msg1 was restored to the prompt input area
local restored_prompt = protocol.extract_prompt(agy_buf)
assert(restored_prompt == msg1, "Unqueued text must be restored to prompt input area, got: '" .. restored_prompt .. "'")
assert(vim.bo[agy_buf].modified == true, "Buffer must be marked modified after unqueueing")

-- Cursor must be positioned on the prompt input line
local cur_pos = vim.api.nvim_win_get_cursor(win)
assert(cur_pos[1] == state.prompt_start_line, string.format("Cursor must be at prompt_start_line %d, got %d", state.prompt_start_line, cur_pos[1]))

print("✓ Unqueueing via <CR> restoring prompt text and re-indexing queue verified")

-- -----------------------------------------------------------------
-- TEST 5: Automatic dispatch of next queued message on turn end
-- -----------------------------------------------------------------
print("\n[Test 5] Testing auto-dispatch of queued message on on_result...")

local dispatched_prompt = nil
state.session.send_prompt = function(self, payload)
  dispatched_prompt = payload
  return true
end

-- Currently msg2 is still in state.prompt_queue
assert(#state.prompt_queue == 1, "Expected 1 item in queue before turn completion")

-- Trigger on_result to simulate active turn completion
state.session.turn_active = false
local mock_result = {
  status = "DONE",
  duration_seconds = 1.2,
  usage = { total_tokens = 250 },
}

-- Call on_result registered on session
state.session.on_result(state.session, mock_result)

-- Wait for scheduled dispatch
vim.wait(200, function()
  return dispatched_prompt ~= nil
end)

assert(dispatched_prompt ~= nil, "Next queued prompt should be automatically dispatched on turn completion")
assert(dispatched_prompt == msg2, "Dispatched payload must match msg2, got: " .. tostring(dispatched_prompt))
assert(#state.prompt_queue == 0, "Queue must be empty after auto-dispatch")

print("✓ Automatic popping and dispatch on turn completion verified")

protocol.cleanup_buffer(agy_buf)

print("\nALL PROMPT QUEUE TESTS PASSED PERFECTLY!")
