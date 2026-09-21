local utils = require("agy.utils")
local render = require("agy.render")
local protocol = require("agy.protocol")
local config_mod = require("agy.config")

print("=== Running Tool Toggle (<CR>) and Path Shortening Tests ===")

local cfg = config_mod.setup({
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
		virtual_text = true,
		auto_scroll = false,
		fold_tool_output = false,
		protect_history = true,
	},
})
protocol.setup()

local cwd = vim.fs.normalize(vim.fn.getcwd())
local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

-- ==========================================
-- Test 1: Path shortening in format_tool_params
-- ==========================================
print("\n[Test 1] Testing path shortening in format_tool_params...")

-- 1a. AbsolutePath
local p1 = { AbsolutePath = cwd .. "/lua/agy/session.lua" }
local s1 = render.format_tool_params(p1, cwd)
print("1a. AbsolutePath: " .. s1)
assert(s1 == "lua/agy/session.lua", "Expected lua/agy/session.lua, got " .. s1)

-- 1b. TargetFile with forward slashes
local p2 = { TargetFile = cwd .. "/plugin/agy.lua" }
local s2 = render.format_tool_params(p2, cwd)
print("1b. TargetFile: " .. s2)
assert(s2 == "plugin/agy.lua", "Expected plugin/agy.lua, got " .. s2)

-- 1c. CommandLine with embedded cwd
local p3 = { CommandLine = 'nu "' .. cwd .. '/tests"' }
local s3 = render.format_tool_params(p3, cwd)
print("1c. CommandLine: " .. s3)
assert(s3 == 'nu "tests"', "Expected shortened CommandLine, got " .. s3)

-- 1d. Unrelated path
local unrelated_path = is_win and "C:\\Windows\\System32\\notepad.exe" or "/usr/bin/grep"
local p4 = { AbsolutePath = unrelated_path }
local s4 = render.format_tool_params(p4, cwd)
print("1d. Unrelated: " .. s4)
assert(s4 == unrelated_path, "Expected unchanged path, got " .. s4)

print("✓ All format_tool_params shortening tests passed!")

-- ==========================================
-- Test 2: Decoupled tool rendering & <CR> toggle
-- ==========================================
print("\n[Test 2] Testing decoupled tool rendering & <CR> toggle...")

local mock_steps = {
	{
		type = "USER_INPUT",
		content = "Please view the session file",
	},
	{
		type = "TOOL_CALL",
		tool_name = "view_file",
		args = { AbsolutePath = cwd .. "/lua/agy/session.lua" },
		duration_seconds = 0.05,
		output = "Line 1: local M = {}\nLine 2: return M",
	},
	{
		type = "PLANNER_RESPONSE",
		content = "I have viewed the file.",
		duration_seconds = 0.5,
	},
}

local test_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(test_buf)

local prompt_line, prompt_ext_id, tool_calls =
	render.render_transcript(test_buf, "test-toggle-123", mock_steps, cfg, cwd)
protocol._setup_buffer(test_buf, "test-toggle-123")

local state = {
	buf = test_buf,
	conversation_id = "test-toggle-123",
	config = cfg,
	prompt_start_line = prompt_line,
	prompt_extmark_id = prompt_ext_id,
	footer_extmark_id = nil,
	tool_calls = tool_calls,
	stream_info = { status = "ready" },
}
protocol.buffers[test_buf] = state

local lines_initial = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
print("Initial buffer lines:")
for i, l in ipairs(lines_initial) do
	print(string.format("  [%d] %s", i, l))
end

-- Verify tool header is shortened and modern (no > or **)
local tool_header_line = nil
for i, l in ipairs(lines_initial) do
	if l:find("🛠️") then
		tool_header_line = i
		print("Found tool header at line " .. i .. ": " .. l)
		assert(l:find("lua/agy/session.lua"), "Header should contain shortened path")
		assert(not l:find(cwd, 1, true), "Header should NOT contain full workspace path")
		assert(not l:find(">"), "Header should NOT contain blockquote prefix '>'")
		assert(not l:find("%*%*"), "Header should NOT contain markdown bold '**'")
	end
end
assert(tool_header_line ~= nil, "Tool header line not found")

-- Verify NO output lines are in the buffer when collapsed
for _, l in ipairs(lines_initial) do
	assert(not l:find("Line 1: local M"), "Output lines should NOT be in buffer when collapsed")
	assert(not l:find("```"), "Code fence should NOT be in buffer when collapsed")
end

-- Verify tool_calls record
assert(#tool_calls == 1, "Expected 1 tool call record")
local tc = tool_calls[1]
assert(tc.is_open == false, "Tool call should initially be closed")
assert(tc.output == "Line 1: local M = {}\nLine 2: return M", "Tool output should be preserved in data store")

-- 2a. Trigger <CR> on the tool header line (open)
print("\n[Test 2a] Pressing <CR> on tool header line...")
vim.api.nvim_win_set_cursor(0, { tool_header_line, 0 })
local handled = protocol.toggle_tool_at_cursor(test_buf)
assert(handled == true, "toggle_tool_at_cursor should return true")
assert(tc.is_open == true, "Tool call should now be open")
assert(tc.win and vim.api.nvim_win_is_valid(tc.win), "Inline window should be open and valid")
assert(tc.win_buf and vim.api.nvim_buf_is_valid(tc.win_buf), "Window buffer should be valid")

-- Buffer lines should NOT have changed (inline window instead of buffer mutation)
local lines_buf = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
for _, l in ipairs(lines_buf) do
	assert(not l:find("Line 1: local M"), "Main buffer should not contain expanded output lines")
	assert(not l:find("```"), "Main buffer should not contain code fence")
end
assert(state.prompt_start_line == prompt_line, "Prompt start line should NOT shift with inline window")
assert(vim.bo[test_buf].modified == false, "Buffer modified state should be false")

-- Window buffer should contain the output lines (content-only, no padding lines inside)
local win_lines = vim.api.nvim_buf_get_lines(tc.win_buf, 0, -1, false)
assert(#win_lines == 2, "Window buffer should contain 2 lines")
assert(win_lines[1] == "Line 1: local M = {}", "Window buffer should contain line 1")
assert(win_lines[2] == "Line 2: return M", "Window buffer should contain line 2")
assert(vim.bo[tc.win_buf].filetype == "lua", "Window buffer should detect filetype 'lua'")

-- Window alignment: left edge lined up with start of tool name
local win_cfg = vim.api.nvim_win_get_config(tc.win)
local header_str = vim.api.nvim_buf_get_lines(test_buf, tool_header_line - 1, tool_header_line, false)[1]
local s_col = header_str:find(tc.tool_name, 1, true)
local prefix = header_str:sub(1, s_col - 1)
local expected_col = vim.fn.strdisplaywidth(prefix)
assert(win_cfg.col == expected_col, "Window col should align with start of tool name (expected " .. expected_col .. ", got " .. win_cfg.col .. ")")
assert(win_cfg.height <= 20, "Window height should respect max_height (default 20)")

-- 2b. Trigger <CR> to close (either via toggle_tool_at_cursor or pressing <CR> in window)
print("\n[Test 2b] Pressing <CR> to close inline window...")
local handled_close = protocol.toggle_tool_at_cursor(test_buf)
assert(handled_close == true, "toggle_tool_at_cursor should return true on close")
assert(tc.is_open == false, "Tool call should now be closed")
assert(tc.win == nil or not vim.api.nvim_win_is_valid(tc.win), "Window should be closed")

-- Check cursor was repositioned to header line
local final_cur = vim.api.nvim_win_get_cursor(0)
assert(final_cur[1] == tool_header_line, "Cursor should be moved back to tool header line")
print("✓ Tool toggle inline window open & close verified!")

-- ==========================================
-- Test 3: Fallback on non-tool line
-- ==========================================
print("\n[Test 3] Testing fallback on non-tool line...")
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- Line 1 is title
local fallback_handled = protocol.toggle_tool_at_cursor(test_buf)
assert(fallback_handled == false, "toggle_tool_at_cursor should return false on non-tool line")
print("✓ Fallback on non-tool line returns false as expected!")

-- ==========================================
-- Test 4: Live streaming tool call lifecycle
-- ==========================================
print("\n[Test 4] Testing live streaming tool call lifecycle...")
local stream_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(stream_buf)

local s_prompt_line, s_prompt_ext = render.render_new_session(stream_buf, cfg)
protocol._setup_buffer(stream_buf, "new")

local stream_state = {
	buf = stream_buf,
	config = cfg,
	prompt_start_line = s_prompt_line,
	prompt_extmark_id = s_prompt_ext,
	tool_calls = {},
	stream_info = { status = "ready" },
}
protocol.buffers[stream_buf] = stream_state

-- Simulate ACTIVE tool event
local tool_line, ext_id, param_str = render.append_tool_call(
	stream_buf,
	"run_command",
	{ CommandLine = "nu " .. cwd .. "/test.nu" },
	cwd
)
local stream_tc = {
	id = 1,
	tool_name = "run_command",
	params = { CommandLine = "nu " .. cwd .. "/test.nu" },
	param_str = param_str,
	output = nil,
	duration_seconds = nil,
	status = "running",
	is_open = false,
	header_extmark_id = ext_id,
	header_line_idx = tool_line,
	output_lines_count = 0,
}
table.insert(stream_state.tool_calls, stream_tc)

assert(param_str == "nu test.nu", "Expected shortened CommandLine in live stream")

-- Simulate DONE tool event
render.complete_tool_call(stream_buf, stream_tc, 0.42, "Output line A\nOutput line B", cfg)
assert(stream_tc.status == "done", "Tool call status should be done")
assert(stream_tc.output == "Output line A\nOutput line B", "Tool output attached")

-- Check that buffer still only has header, NOT output
local stream_lines = vim.api.nvim_buf_get_lines(stream_buf, 0, -1, false)
for _, l in ipairs(stream_lines) do
	assert(not l:find("Output line A"), "Output should NOT be in buffer on completion")
end

-- Toggle it open
vim.api.nvim_win_set_cursor(0, { tool_line + 1, 0 })
local s_handled = protocol.toggle_tool_at_cursor(stream_buf)
assert(s_handled == true, "Should toggle streaming tool output")
assert(stream_tc.is_open == true, "Tool should now be open")
assert(stream_tc.win and vim.api.nvim_win_is_valid(stream_tc.win), "Inline window should be open")

local s_win_lines = vim.api.nvim_buf_get_lines(stream_tc.win_buf, 0, -1, false)
assert(#s_win_lines == 2, "Inline window buffer should have 2 lines (content-only)")
assert(s_win_lines[1] == "Output line A", "Inline window contains tool output line 1")
assert(s_win_lines[2] == "Output line B", "Inline window contains tool output line 2")

-- Toggle it closed
local s_handled_close = protocol.toggle_tool_at_cursor(stream_buf)
assert(s_handled_close == true, "Should toggle closed")
assert(stream_tc.is_open == false, "Tool should now be closed")
assert(stream_tc.win == nil or not vim.api.nvim_win_is_valid(stream_tc.win), "Window should be closed")

print("✓ Live streaming tool call lifecycle and toggle verified!")

-- ==========================================
-- Test 5: Codeblock language detection using vim.filetype
-- ==========================================
print("\n[Test 5] Testing detect_codeblock_lang using vim.filetype API...")

local cases = {
	{ params = { TargetFile = "lua/agy/init.lua" }, expected = "lua" },
	{ params = { AbsolutePath = "C:/repo/src/main.rs" }, expected = "rust" },
	{ params = { path = "src/script.py" }, expected = "python" },
	{ params = { file = "app/page.tsx" }, expected = "typescriptreact" },
	{ params = { TargetFile = "Dockerfile" }, expected = "dockerfile" },
	{ params = { TargetFile = "Makefile" }, expected = "make" },
	{ params = { TargetFile = "CMakeLists.txt" }, expected = "cmake" },
	{ params = { TargetFile = "config.toml" }, expected = "toml" },
	{ params = { TargetFile = "test.nu" }, expected = "nu" },
}

for _, c in ipairs(cases) do
	local detected = render.detect_codeblock_lang("view_file", c.params, "")
	assert(
		detected == c.expected,
		string.format("Expected filetype '%s' for %s, got '%s'", c.expected, vim.inspect(c.params), detected)
	)
end

-- Test tool-specific and output-specific detection
assert(render.detect_codeblock_lang("read_url_content", {}, "") == "markdown")
assert(render.detect_codeblock_lang("run_command", { CommandLine = "git diff HEAD~1" }, "") == "diff")
assert(render.detect_codeblock_lang("run_command", {}, "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo") == "diff")
assert(render.detect_codeblock_lang("run_command", {}, '{"key": "value"}') == "json")

print("✓ Codeblock language detection with vim.filetype verified!")

print("\nALL TOOL TOGGLE & PATH SHORTENING TESTS PASSED SUCCESSFULLY!")
vim.cmd("qall!")
