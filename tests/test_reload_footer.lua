local protocol = require("agy.protocol")
local render = require("agy.render")

print("=== Testing Reload (:e and :e!) Footer State ===")

require("agy").setup()

-- 1. Test in agy://new
print("\n[Test 1] Testing :edit! in agy://new...")
vim.cmd("edit agy://new")
local buf1 = vim.api.nvim_get_current_buf()
local state1 = protocol.buffers[buf1]

print("Waiting for init event...")
vim.wait(10000, function()
	return state1.stream_info and state1.stream_info.status == "ready"
end, 100)

assert(state1.stream_info.status == "ready", "Status should be 'ready'")
print("Initial footer verified. Triggering :edit!...")

vim.cmd("edit!")
print("After :edit!: stream_info.status = " .. tostring(state1.stream_info.status))
assert(state1.stream_info.status == "ready", "Status MUST remain 'ready' after :e!")

local marks1 = vim.api.nvim_buf_get_extmarks(buf1, render.NS_UI, 0, -1, { details = true })
local footer1 = nil
for _, em in ipairs(marks1) do
	if em[4].virt_lines then
		for _, line in ipairs(em[4].virt_lines) do
			local text = line[1] and line[1][1] or ""
			if text:find("⚡") then
				footer1 = text
				print("Footer after reload: " .. text)
			end
		end
	end
end
assert(footer1 ~= nil, "Footer must exist after reload")
assert(not footer1:find("Connecting"), "Footer must NOT say 'Connecting to Antigravity...'!")
local created_cid = state1.conversation_id
protocol.cleanup_buffer(buf1)
vim.cmd("bdelete! " .. buf1)

-- 2. Test in an existing conversation from history
print("\n[Test 2] Testing :edit! in existing conversation...")
local conv_id = created_cid
assert(conv_id ~= nil and conv_id ~= "" and conv_id ~= "new", "Expected valid conversation ID from Test 1")
vim.cmd("edit agy://" .. conv_id)
local buf2 = vim.api.nvim_get_current_buf()
local state2 = protocol.buffers[buf2]

print("Waiting for init event on existing conversation...")
vim.wait(10000, function()
	return state2.stream_info and state2.stream_info.status == "ready"
end, 100)

assert(state2.stream_info.status == "ready", "Status should be 'ready'")

print("Running :edit! on existing conversation...")
vim.cmd("edit!")

print("After :edit!: stream_info.status = " .. tostring(state2.stream_info.status))
assert(state2.stream_info.status == "ready", "Status MUST remain 'ready' after :e!")

local marks2 = vim.api.nvim_buf_get_extmarks(buf2, render.NS_UI, 0, -1, { details = true })
local footer2 = nil
for _, em in ipairs(marks2) do
	if em[4].virt_lines then
		for _, line in ipairs(em[4].virt_lines) do
			local text = line[1] and line[1][1] or ""
			if text:find("⚡") then
				footer2 = text
				print("Footer after reload: " .. text)
			end
		end
	end
end
assert(footer2 ~= nil, "Footer must exist after reload")
assert(not footer2:find("Connecting"), "Footer must NOT say 'Connecting to Antigravity...'!")
print("✓ Existing conversation :edit! test passed")

protocol.cleanup_buffer(buf2)
vim.cmd("bdelete! " .. buf2)

print("\nALL RELOAD FOOTER TESTS PASSED!")
