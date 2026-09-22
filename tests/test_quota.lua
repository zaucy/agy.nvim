-- tests/test_quota.lua
-- Unit and integration tests for Models & Quota (/usage) view

local quota = require("agy.quota")
local utils = require("agy.utils")

print("=== Running Models & Quota (/usage) Tests ===")

-- [Test 1] Testing format_reset_time logic
print("\n[Test 1] Testing format_reset_time logic...")
assert(quota.format_reset_time(1.0, nil) == "Quota available", "100% fraction should report Quota available")
assert(
	quota.format_reset_time(0.99999, "2026-09-21T00:00:00Z") == "Quota available",
	"Near 1.0 should report Quota available"
)

-- Future time test (calculate 2 hours 30 mins in future UTC)
local future_epoch = os.time() + 9000
local future_date_str = os.date("!%Y-%m-%dT%H:%M:%SZ", future_epoch)
local res_str = quota.format_reset_time(0.5, future_date_str)
assert(res_str:find("Refreshes in 2h"), "Expected 'Refreshes in 2h...', got: " .. res_str)

-- Past time test
local past_epoch = os.time() - 3600
local past_date_str = os.date("!%Y-%m-%dT%H:%M:%SZ", past_epoch)
assert(
	quota.format_reset_time(0.5, past_date_str) == "Quota available",
	"Past reset time should report Quota available"
)

-- Zero fraction without timestamp
assert(quota.format_reset_time(0.0, nil) == "Quota exhausted", "0.0 without reset time should report Quota exhausted")
print("✓ format_reset_time logic verified")

-- [Test 2] Testing wrap_text
print("\n[Test 2] Testing wrap_text...")
local sample_text =
	"Within each group, models share a weekly limit and a 5-hour limit. If you reach a limit, you can switch to a model in the other group or wait for the limit to refresh."
local wrapped = quota.wrap_text(sample_text, 40)
assert(#wrapped >= 3, "Expected at least 3 wrapped lines, got " .. tostring(#wrapped))
for _, line in ipairs(wrapped) do
	assert(#line <= 40, "Line exceeds max length: " .. line)
end
print("✓ wrap_text word wrapping verified")

-- [Test 3] Testing build_content with mock quota payload
print("\n[Test 3] Testing build_content formatting & progress bars...")
local mock_data = {
	description = "Within each group, models share a weekly limit and a 5-hour limit.",
	groups = {
		{
			name = "Gemini Models",
			description = "Gemini 2.5 Flash, Gemini 2.5 Pro",
			buckets = {
				{
					name = "Weekly Limit Remaining",
					remaining_fraction = 0.8743,
					reset_time = future_date_str,
				},
				{
					name = "Five Hour Limit Remaining",
					remaining_fraction = 1.0,
					reset_time = nil,
				},
			},
		},
		{
			name = "Claude and GPT Models",
			description = "Claude 3.7 Sonnet, Claude 3.5 Haiku, GPT-4o",
			buckets = {
				{
					name = "Weekly Limit Remaining",
					remaining_fraction = 0.15,
					reset_time = future_date_str,
				},
			},
		},
	},
}

local session_info = {
	total_tokens = 15234,
	duration_seconds = 45,
	tools_count = 3,
}

local lines, meta = quota.build_content(mock_data, "testuser@example.com", session_info)
assert(#lines > 0, "Lines should not be empty")

local text_block = table.concat(lines, "\n")
assert(text_block:find("Account: testuser@example.com"), "Should contain account line")
assert(text_block:find("GEMINI MODELS"), "Should contain uppercase group title")
assert(text_block:find("Models within this group: Gemini 2.5 Flash"), "Should contain group description")
assert(text_block:find("Weekly Limit Remaining"), "Should contain bucket name")
assert(text_block:find("87.43%%"), "Should contain formatted percentage")
assert(text_block:find("Quota available"), "Should contain quota available")
assert(text_block:find("│ Within each group"), "Should contain vertical quote bar for description")
assert(text_block:find("Session: 15.2k tokens"), "Should contain session token metrics")

-- Check progress bar characters
local found_bar = false
for _, line in ipairs(lines) do
	if line:find("█") and line:find("░") then
		found_bar = true
		break
	end
end
assert(found_bar, "Expected progress bar line containing █ and ░ characters")
print("✓ build_content layout and progress bar rendering verified")

-- [Test 4] Testing apply_highlights without errors
print("\n[Test 4] Testing apply_highlights...")
local test_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, lines)
quota.setup_highlights()
quota.apply_highlights(test_buf, meta)

local extmarks = vim.api.nvim_buf_get_extmarks(test_buf, quota.NS_QUOTA, 0, -1, { details = true })
assert(#extmarks >= 5, "Expected extmarks applied to buffer, got " .. tostring(#extmarks))
print("✓ apply_highlights verified with " .. tostring(#extmarks) .. " extmarks")

-- [Test 5] Testing open() floating window creation and interaction
print("\n[Test 5] Testing open() floating window lifecycle...")
-- Pre-populate cache so open() immediately renders content
quota._cache = mock_data
quota._cache_time = os.time()

local win, buf = quota.open(test_buf)
assert(vim.api.nvim_win_is_valid(win), "Floating window should be valid")
assert(vim.api.nvim_buf_is_valid(buf), "Floating buffer should be valid")
assert(vim.bo[buf].modifiable == false, "Floating buffer should be unmodifiable")

local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(#buf_lines > 5, "Floating buffer should contain quota lines")
assert(buf_lines[1]:find("Models & Quota"), "First line should be Models & Quota title")
assert(buf_lines[3]:find("Account:"), "Third line should be Account line")

-- Test close with 'q' keymap
local q_maps = vim.api.nvim_buf_get_keymap(buf, "n")
local found_q = false
for _, m in ipairs(q_maps) do
	if m.lhs == "q" or m.lhs == "<Esc>" then
		found_q = true
		break
	end
end
assert(found_q, "Buffer should have 'q' or '<Esc>' keymap registered")

-- Close window via panel.close()
require("agy.panel").close()
assert(not vim.api.nvim_win_is_valid(win), "Window should be closed")
print("✓ open() floating window lifecycle and keymaps verified")

-- [Test 6] Testing User Commands :AgyUsage and :AgyQuota
print("\n[Test 6] Testing User Commands :AgyUsage and :AgyQuota...")
-- Require plugin entrypoint
require("agy")
dofile(vim.fs.normalize("plugin/agy.lua"))

local commands = vim.api.nvim_get_commands({})
assert(commands["AgyUsage"] ~= nil, ":AgyUsage command should be registered")
assert(commands["AgyQuota"] ~= nil, ":AgyQuota command should be registered")

-- Run command without error
vim.cmd("AgyUsage")
local panel_mod = require("agy.panel")
assert(panel_mod.is_open(), "AgyUsage should open bottom panel")
local cur_buf = panel_mod.get_buf()
assert(vim.bo[cur_buf].buftype == "nofile", "AgyUsage should open nofile buffer")
panel_mod.close()
print("✓ :AgyUsage and :AgyQuota user commands verified")

-- [Test 7] Testing Protocol Intercept of /usage and /quota
print("\n[Test 7] Testing Protocol Intercept of /usage and /quota...")
local protocol = require("agy.protocol")
vim.cmd("edit agy://test-quota-conv")
local conv_buf = vim.api.nvim_get_current_buf()

-- Test :w with /usage
protocol.with_modifiable(conv_buf, function()
	vim.api.nvim_buf_set_lines(conv_buf, protocol.buffers[conv_buf].prompt_start_line - 1, -1, false, { "/usage" })
end)
protocol.handle_write(conv_buf)

assert(panel_mod.is_open(), "Should have opened bottom panel for /usage")
local quota_buf = panel_mod.get_buf()
assert(vim.bo[quota_buf].buftype == "nofile", "Should have opened quota nofile buffer")
panel_mod.close()

-- Test :w with /quota
protocol.with_modifiable(conv_buf, function()
	vim.api.nvim_buf_set_lines(conv_buf, protocol.buffers[conv_buf].prompt_start_line - 1, -1, false, { "/quota" })
end)
protocol.handle_write(conv_buf)

assert(panel_mod.is_open(), "Should have opened bottom panel for /quota")
panel_mod.close()

-- [Test 8] Testing Context Breakdown (/context) module and layout
print("\n[Test 8] Testing Context Breakdown (/context) module and layout...")
local context_mod = require("agy.context")
assert(context_mod.get_model_limit("gemini-3.8-flash") == 1048576, "Gemini Flash limit should be 1M")
assert(context_mod.get_model_limit("gemini-2.5-pro") == 2097152, "Gemini Pro limit should be 2M")
assert(context_mod.get_model_limit("claude-3.7-sonnet") == 200000, "Claude Sonnet limit should be 200k")
assert(context_mod.get_model_limit("gpt-4o") == 128000, "GPT-4o limit should be 128k")

local ctx_lines_raw, ctx_meta = context_mod.build_content(protocol.buffers[conv_buf], {}, 80)
local raw_text = table.concat(ctx_lines_raw, "\n")
assert(raw_text:find("Context Breakdown"), "Should contain Context Breakdown title")
assert(raw_text:find("Active Model:"), "Should contain Active Model")
assert(raw_text:find("Context Window:"), "Should contain Context Window")
assert(raw_text:find("BREAKDOWN"), "Should contain BREAKDOWN group")
assert(raw_text:find("System prompt"), "Should contain System prompt")
assert(raw_text:find("Skills & Rules"), "Should contain Skills & Rules")
assert(raw_text:find("Active Workspaces & Files"), "Should contain Active Workspaces & Files")
assert(raw_text:find("Conversation History"), "Should contain Conversation History")
assert(raw_text:find("Available Context Remaining"), "Should contain Available Context Remaining")
assert(raw_text:find("ACTIVE WORKSPACES"), "Should contain ACTIVE WORKSPACES")
assert(raw_text:find("SESSION METRICS"), "Should contain SESSION METRICS")
assert(raw_text:find("│ Context represents the tokens"), "Should contain quote block")
assert(ctx_lines_raw[#ctx_lines_raw]:find("Scroll"), "Footer should contain Scroll instruction")

-- Test protocol intercept of /context
protocol.with_modifiable(conv_buf, function()
	vim.api.nvim_buf_set_lines(conv_buf, protocol.buffers[conv_buf].prompt_start_line - 1, -1, false, { "/context" })
end)
protocol.handle_write(conv_buf)

assert(panel_mod.is_open(), "Should have opened bottom panel for /context")
local ctx_buf = panel_mod.get_buf()
local ctx_lines = vim.api.nvim_buf_get_lines(ctx_buf, 0, -1, false)
local ctx_text = table.concat(ctx_lines, "\n")
assert(ctx_text:find("Context Breakdown"), "Should contain Context Breakdown title in panel")
assert(ctx_text:find("BREAKDOWN"), "Should contain BREAKDOWN group in panel")
assert(ctx_text:find("ACTIVE WORKSPACES"), "Should contain ACTIVE WORKSPACES in panel")
panel_mod.close()
assert(not panel_mod.is_open(), "Panel should be closed")

pcall(vim.api.nvim_buf_delete, conv_buf, { force = true })
print("✓ Context Breakdown (/context) module and layout verified")

-- [Test 9] Testing normal mode enforcement when opening panels
print("\n[Test 9] Testing normal mode enforcement when opening panels...")
vim.cmd("edit agy://test-quota-mode")
local mode_buf = vim.api.nvim_get_current_buf()

-- Simulate being in insert mode before calling /usage
vim.cmd("startinsert")
protocol.with_modifiable(mode_buf, function()
	vim.api.nvim_buf_set_lines(mode_buf, protocol.buffers[mode_buf].prompt_start_line - 1, -1, false, { "/usage" })
end)
protocol.handle_write(mode_buf)
assert(panel_mod.is_open(), "Panel should be open")
local current_mode = vim.api.nvim_get_mode().mode
assert(current_mode == "n", "Expected normal mode ('n') when panel opens, got: " .. current_mode)
panel_mod.close()

-- Simulate being in insert mode before calling /context
vim.cmd("startinsert")
protocol.with_modifiable(mode_buf, function()
	vim.api.nvim_buf_set_lines(mode_buf, protocol.buffers[mode_buf].prompt_start_line - 1, -1, false, { "/context" })
end)
protocol.handle_write(mode_buf)
assert(panel_mod.is_open(), "Panel should be open for /context")
local current_mode2 = vim.api.nvim_get_mode().mode
assert(current_mode2 == "n", "Expected normal mode ('n') when /context opens, got: " .. current_mode2)
panel_mod.close()

pcall(vim.api.nvim_buf_delete, mode_buf, { force = true })
print("✓ Normal mode enforcement verified when opening panels")

-- [Test 10] Testing User Command :AgyContext
print("\n[Test 10] Testing User Command :AgyContext...")
vim.cmd("AgyContext")
assert(panel_mod.is_open(), ":AgyContext command should open context panel")
local ac_buf = panel_mod.get_buf()
local ac_lines = vim.api.nvim_buf_get_lines(ac_buf, 0, -1, false)
assert(table.concat(ac_lines, "\n"):find("Context Breakdown"), ":AgyContext should display Context Breakdown")
panel_mod.close()
print("✓ :AgyContext user command verified")

-- [Test 11] Testing dynamic height expansion in panel.update (no truncation)
print("\n[Test 11] Testing dynamic height expansion in panel.update...")
vim.cmd("edit agy://test-panel-height")
local h_buf = vim.api.nvim_get_current_buf()
local h_win = vim.api.nvim_get_current_win()

-- Open with small 5-line placeholder
local placeholder = { "Line 1", "Line 2", "Line 3", "Line 4", "Line 5" }
local p_win, p_buf = panel_mod.open({
	target_win = h_win,
	target_buf = h_buf,
	lines = placeholder,
	filetype = "agy_test",
})
local init_cfg = vim.api.nvim_win_get_config(p_win)
assert(init_cfg.height <= 5, "Initial height should be <= 5")

-- Now update with 35 lines (like /usage fresh content)
local big_lines = {}
for i = 1, 35 do
	table.insert(big_lines, "Content line " .. i)
end
panel_mod.update(big_lines)

local updated_cfg = vim.api.nvim_win_get_config(p_win)
assert(updated_cfg.height > 5, "Height should dynamically expand above 5 lines on update")
assert(updated_cfg.height >= math.min(35, vim.api.nvim_win_get_height(h_win) - 2), "Height should not be clamped by artificial limits")
panel_mod.close()
pcall(vim.api.nvim_buf_delete, h_buf, { force = true })
print("✓ Dynamic panel.update height expansion verified")

-- [Test 12] Testing quota.open() asynchronous fetching without async context error
print("\n[Test 12] Testing quota.open() asynchronous fetching...")
local orig_sys = vim.system
quota._cache = nil
quota._cache_time = 0

local mock_json = vim.json.encode({
	status = "SUCCESS",
	command = {
		name = "usage",
		data = {
			description = "Test quota description",
			groups = {
				{
					name = "Test Group",
					description = "Models within group",
					buckets = {
						{
							name = "Weekly Limit Remaining",
							remaining_fraction = 0.85,
							reset_time = "2026-09-23T02:00:00Z",
						}
					}
				}
			}
		}
	}
})

vim.system = function(cmd, opts, on_exit)
	if on_exit then
		on_exit({ code = 0, stdout = mock_json, stderr = "" })
	end
	return {}
end

local q_win, q_buf = quota.open()
vim.wait(300, function() return quota._cache ~= nil end)
vim.system = orig_sys

assert(quota._cache ~= nil, "Quota cache should be populated by async fetch")
local buf_lines = vim.api.nvim_buf_get_lines(q_buf, 0, -1, false)
local found_error = false
for _, line in ipairs(buf_lines) do
	if line:find("Not in async context") then
		found_error = true
		break
	end
end
assert(not found_error, "Panel must NOT contain 'Not in async context' error")
panel_mod.close()
print("✓ quota.open() async fetching verified without 'Not in async context' error")

print("\nALL MODELS & QUOTA TESTS PASSED SUCCESSFULLY!")
