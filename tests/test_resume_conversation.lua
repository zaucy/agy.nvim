local protocol = require("agy.protocol")

print("--- Testing Conversation Resume ---")

require("agy").setup()

-- Step 1: Create a dedicated conversation to test resuming
print("Creating initial conversation via agy://new...")
vim.cmd("edit agy://new")
local buf1 = vim.api.nvim_get_current_buf()
local state1 = protocol.buffers[buf1]
assert(state1 ~= nil, "Buffer 1 state must exist")

vim.wait(5000, function()
  return state1.stream_info and state1.stream_info.status == "ready"
end, 100)

vim.api.nvim_buf_set_lines(buf1, -1, -1, false, {
  "Reply with EXACTLY the single word: TURN_ONE_OK",
})

print("Submitting Turn 1 via :write...")
protocol.handle_write(buf1)

local turn1_completed = vim.wait(20000, function()
  return state1.session and state1.session.turn_active == false
end, 200)
assert(turn1_completed, "Turn 1 did not complete within timeout")

local conv_id = state1.conversation_id
assert(conv_id ~= nil and conv_id ~= "" and conv_id ~= "new", "Expected valid conversation ID from Turn 1")
print("Turn 1 completed. Conversation ID: " .. conv_id)

protocol.cleanup_buffer(buf1)
vim.cmd("bdelete! " .. buf1)

-- Step 2: Resume the conversation and submit Turn 2
print("\nResuming conversation agy://" .. conv_id .. "...")
vim.cmd("edit agy://" .. conv_id)
local buf2 = vim.api.nvim_get_current_buf()
local state2 = protocol.buffers[buf2]
assert(state2 ~= nil, "Buffer 2 state must exist")

local ready2 = vim.wait(5000, function()
  return state2.stream_info and state2.stream_info.status == "ready"
end, 100)
assert(ready2, "Resumed session did not become ready within timeout")

local lines = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
local full_text = table.concat(lines, "\n")
print("Loaded resumed conversation length: " .. #lines .. " lines")
assert(full_text:find("TURN_ONE_OK", 1, true), "Resumed buffer must contain Turn 1 content")
print("✓ Historical transcript loaded successfully")

-- Add Turn 2 prompt
vim.api.nvim_buf_set_lines(buf2, -1, -1, false, {
  "Reply with EXACTLY the single word: RESUMED_OK",
})

print("Submitting second turn via :write...")
protocol.handle_write(buf2)

local turn2_completed = vim.wait(20000, function()
  return state2.session and state2.session.turn_active == false
end, 200)

assert(turn2_completed, "Turn 2 did not complete within timeout")

local updated_lines = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
local updated_text = table.concat(updated_lines, "\n")
print("Buffer after Turn 2:")
for i, l in ipairs(updated_lines) do
  print(string.format("  [%d] %s", i, l))
end

assert(updated_text:find("RESUMED_OK", 1, true), "Must contain Turn 2 agent response")
assert(vim.bo[buf2].modified == false, "Buffer modified must be false")
print("✓ Multi-turn resume test passed!")

-- Clean up
protocol.cleanup_buffer(buf2)
vim.cmd("bdelete! " .. buf2)

print("ALL RESUME TESTS PASSED!")
