local protocol = require("agy.protocol")
local transcript = require("agy.transcript")

print("--- Testing Real Conversation Tool Calls & Path Shortening ---")

local test_helpers = require("tests.test_helpers")
local tmp_dir, conv_id = test_helpers.create_mock_environment()
require("agy").setup({ app_data_dir = tmp_dir })

print("Loading test conversation with tool calls: " .. conv_id)

vim.cmd("edit agy://" .. conv_id)
local buf = vim.api.nvim_get_current_buf()
local state = protocol.buffers[buf]
assert(state ~= nil, "Buffer state must exist")
print("Total tool calls loaded in state: " .. #state.tool_calls)

local shortened_count = 0
for i, tc in ipairs(state.tool_calls) do
	if i <= 5 then
		print(string.format("  Tool %d: %s | param_str: %s", i, tc.tool_name, tc.param_str))
	end
	if tc.param_str and (tc.param_str:find("lua/") or tc.param_str:find("tests/") or tc.param_str:find("plugin/")) then
		shortened_count = shortened_count + 1
	end
end
print(string.format("Found %d tool calls with shortened paths in parameters", shortened_count))

-- Verify that all tool calls start collapsed
for _, tc in ipairs(state.tool_calls) do
	assert(tc.is_open == false, "All tool calls must start collapsed")
	assert(tc.output_lines_count == 0, "output_lines_count must be 0")
end
print("✓ All tool calls initially collapsed without folds")

-- Test expanding the first tool call with output
local first_with_output = nil
for _, tc in ipairs(state.tool_calls) do
	if tc.output and tc.output ~= "" then
		first_with_output = tc
		break
	end
end

if first_with_output then
	print("\nFound tool with output: " .. first_with_output.tool_name)
	local pos =
		vim.api.nvim_buf_get_extmark_by_id(buf, require("agy.render").NS_UI, first_with_output.header_extmark_id, {})
	local h_row = pos[1]
	vim.api.nvim_win_set_cursor(0, { h_row + 1, 0 })

	local initial_prompt_start = state.prompt_start_line
	local ok = protocol.toggle_tool_at_cursor(buf)
	assert(ok == true, "Must successfully toggle tool")
	assert(first_with_output.is_open == true, "Must be open")
	assert(first_with_output.win and vim.api.nvim_win_is_valid(first_with_output.win), "Inline window must be open")
	assert(state.prompt_start_line == initial_prompt_start, "prompt_start_line must not shift with inline window")
	print("✓ Expanded tool call via <CR> into inline window!")

	local ok_close = protocol.toggle_tool_at_cursor(buf)
	assert(ok_close == true, "Must successfully toggle tool close")
	assert(first_with_output.is_open == false, "Must be closed")
	assert(first_with_output.win == nil or not vim.api.nvim_win_is_valid(first_with_output.win), "Inline window must be closed")
	assert(state.prompt_start_line == initial_prompt_start, "prompt_start_line must stay consistent")
	print("✓ Collapsed tool call via <CR>!")
end

protocol.cleanup_buffer(buf)
vim.cmd("bdelete! " .. buf)

print("\nREAL CONVERSATION TEST PASSED!")
