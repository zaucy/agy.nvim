local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")

print("--- Running End-to-End Live Turn Test with Virtual Dividers ---")

require("agy").setup()

-- 1. Open agy://new
vim.cmd("edit agy://new")
local buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()
local state = protocol.buffers[buf]
assert(state ~= nil, "Buffer state must exist")

print("Waiting for init event...")
vim.wait(5000, function()
  return state.conversation_id ~= nil and state.conversation_id ~= "" and state.conversation_id ~= "new"
end, 100)

print("Conversation ID assigned: " .. tostring(state.conversation_id))
local current_name = vim.api.nvim_buf_get_name(buf)
print("Buffer name: " .. current_name)
assert(current_name:find("agy://", 1, true), "Buffer name must start with agy://")

-- 2. Add prompt at active prompt line
local p_start = state.prompt_start_line
vim.api.nvim_buf_set_lines(buf, p_start - 1, -1, false, {
  "Reply with EXACTLY the single word: HELLO_FROM_AGY_NVIM",
})

-- 3. Trigger write (simulate :w)
print("Triggering :write...")
protocol.handle_write(buf)

assert(state.session.turn_active == true, "Turn should be active after handle_write")
print("Turn active. Waiting for streaming response and result...")

-- 4. Wait for turn completion
local completed = vim.wait(20000, function()
  return state.session.turn_active == false
end, 200)

assert(completed, "Turn did not complete within timeout")
print("Turn completed!")

-- 5. Verify buffer content
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local full_text = table.concat(lines, "\n")
print("Buffer contents after turn:")
for i, l in ipairs(lines) do
  print(string.format("  [%d] %s", i, l))
end

assert(full_text:find("HELLO_FROM_AGY_NVIM", 1, true), "Must contain agent response text")

-- 6. Verify virtual dividers
local ui_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_UI, 0, -1, { details = true })
print("UI extmarks count: " .. #ui_marks)
local has_leftcol = false
for _, m in ipairs(ui_marks) do
  if m[4].virt_lines_leftcol == true then
    has_leftcol = true
    break
  end
end
assert(has_leftcol, "Must have virt_lines_leftcol divider mark")
print("✓ Virtual dividers with virt_lines_leftcol verified")

-- 7. Verify history background highlighting (false by default)
local hist_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_HISTORY, 0, -1, { details = true })
print("History background extmarks count (default): " .. #hist_marks)
assert(#hist_marks == 0, "Default must not add history background marks")
render.apply_history_highlights(buf, state.prompt_start_line, { ui = { color_history = true } })
local enabled_hist = vim.api.nvim_buf_get_extmarks(buf, render.NS_HISTORY, 0, -1, { details = true })
assert(#enabled_hist > 0, "Must have history background highlight marks when enabled")
render.apply_history_highlights(buf, state.prompt_start_line, { ui = { color_history = false } })
print("✓ History background highlighting verified")

-- 8. Verify cursor modifiable protection
local next_prompt = state.prompt_start_line
print("Next prompt line: " .. next_prompt)
vim.api.nvim_win_set_cursor(win, { next_prompt, 0 })
protocol.update_modifiable(buf)
assert(vim.bo[buf].modifiable == true, "Cursor at next prompt must be modifiable")

vim.api.nvim_win_set_cursor(win, { 2, 0 })
protocol.update_modifiable(buf)
assert(vim.bo[buf].modifiable == false, "Cursor in past history must not be modifiable")
print("✓ Dynamic cursor modifiable protection verified")

-- Clean up
protocol.cleanup_buffer(buf)
vim.cmd("bdelete! " .. buf)

print("ALL E2E TESTS PASSED!")
