local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")

print("=== Running Verification for Typing, Divider Duplication, and Modified State ===")

require("agy").setup()

-- -----------------------------------------------------------------
-- TEST 1: Typing and writing in agy://new
-- -----------------------------------------------------------------
print("\n[Test 1] Testing agy://new typing and submission...")
vim.cmd("edit agy://new")
local buf1 = vim.api.nvim_get_current_buf()
local win1 = vim.api.nvim_get_current_win()
local state1 = protocol.buffers[buf1]
assert(state1, "State for buf1 must exist")

print("Initial prompt line: " .. state1.prompt_start_line)

-- Check initial extmarks: should have User divider and bottom footer divider
local initial_extmarks = vim.api.nvim_buf_get_extmarks(buf1, render.NS_UI, 0, -1, { details = true })
assert(
	#initial_extmarks == 2,
	"Must have exactly 2 initial UI extmarks (User divider and footer), found: " .. #initial_extmarks
)

local user_mark = nil
local footer_mark = nil
for _, em in ipairs(initial_extmarks) do
	if em[4].virt_lines_above == true then
		user_mark = em
	elseif em[4].virt_lines_above == false then
		footer_mark = em
	end
end

assert(user_mark ~= nil, "Must have user divider extmark")
local prompt_line_text = user_mark[4].virt_lines[1][1][1]
assert(not prompt_line_text:find("User"), "Active prompt divider must NOT say 'User': " .. prompt_line_text)
assert(prompt_line_text:find("^───"), "Active prompt divider must be a horizontal line: " .. prompt_line_text)
assert(user_mark[4].sign_text == "❯ ", "Active prompt must have sign_text '❯ '")
assert(user_mark[4].sign_hl_group == "AgyUserSign", "Active prompt must have sign_hl_group 'AgyUserSign'")

assert(footer_mark ~= nil, "Must have footer virtual text extmark")
assert(footer_mark[4].virt_lines_leftcol == true, "Footer must have virt_lines_leftcol = true")
assert(footer_mark[4].virt_lines_above == false, "Footer must have virt_lines_above = false")
assert(#footer_mark[4].virt_lines >= 2, "Footer extmark must have bottom border line and status line")
local bottom_border_text = footer_mark[4].virt_lines[1][1][1]
assert(bottom_border_text:find("^───"), "Bottom prompt border must be a horizontal line: " .. bottom_border_text)
local footer_text = footer_mark[4].virt_lines[2][1][1]
assert(footer_text:find("⚡"), "Footer status line must contain ⚡: " .. footer_text)

-- Check prompt area background highlight and sign column background matching
local prompt_bg_marks = vim.api.nvim_buf_get_extmarks(buf1, render.NS_PROMPT, 0, -1, { details = true })
assert(#prompt_bg_marks >= 1, "Must have prompt area background extmark in NS_PROMPT")
assert(prompt_bg_marks[1][4].line_hl_group == "AgyPromptArea", "Prompt line must have line_hl_group = AgyPromptArea")

local user_sign_hl = vim.api.nvim_get_hl(0, { name = "AgyUserSign", link = false })
local prompt_area_hl = vim.api.nvim_get_hl(0, { name = "AgyPromptArea", link = false })
if not prompt_area_hl or not prompt_area_hl.bg then
	prompt_area_hl = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
end
assert(user_sign_hl.bg == prompt_area_hl.bg, "AgyUserSign bg must match prompt area bg!")

-- Verify AgyPromptSign links to AgyPromptArea
local prompt_sign_hl = vim.api.nvim_get_hl(0, { name = "AgyPromptSign", link = false })
assert(prompt_sign_hl.bg == prompt_area_hl.bg, "AgyPromptSign bg must match prompt area bg!")

-- Verify ColorScheme / dynamic prompt bg synchronization
vim.api.nvim_set_hl(0, "AgyPromptArea", { bg = 0x223344 })
vim.api.nvim_exec_autocmds("ColorScheme", {})
local updated_sign_hl = vim.api.nvim_get_hl(0, { name = "AgyUserSign", link = false })
assert(updated_sign_hl.bg == 0x223344, "AgyUserSign bg must synchronize on ColorScheme / highlight change")
local updated_prompt_sign_hl = vim.api.nvim_get_hl(0, { name = "AgyPromptSign", link = false })
assert(updated_prompt_sign_hl.bg == 0x223344, "AgyPromptSign bg must synchronize on ColorScheme / highlight change")

-- Reset back to default
vim.api.nvim_set_hl(0, "AgyPromptArea", { link = "CursorLine", default = true })
render.setup_highlights()
print("✓ Prompt sign column (AgyUserSign and AgyPromptSign) background matches prompt area background")
print("✓ Initial extmarks verified: top & bottom horizontal lines, prompt background, and footer below prompt")

-- Type multi-line prompt into the prompt line
vim.api.nvim_win_set_cursor(win1, { state1.prompt_start_line, 0 })
vim.api.nvim_buf_set_lines(buf1, state1.prompt_start_line - 1, -1, false, { "Line 1", "Line 2!" })
protocol.update_prompt_divider(buf1)

-- Allow any scheduled events to process
vim.wait(50, function()
	return false
end)

-- Verify multi-line prompt gutter highlights across all lines
local multi_prompt_marks = vim.api.nvim_buf_get_extmarks(buf1, render.NS_PROMPT, 0, -1, { details = true })
assert(#multi_prompt_marks >= 2, "Must have extmarks on both prompt lines in NS_PROMPT, found: " .. #multi_prompt_marks)
assert(multi_prompt_marks[1][4].line_hl_group == "AgyPromptArea", "Line 1 must have line_hl_group = AgyPromptArea")
assert(multi_prompt_marks[1][4].number_hl_group == "AgyPromptArea", "Line 1 must have number_hl_group = AgyPromptArea")
assert(multi_prompt_marks[2][4].line_hl_group == "AgyPromptArea", "Line 2 must have line_hl_group = AgyPromptArea")
assert(multi_prompt_marks[2][4].number_hl_group == "AgyPromptArea", "Line 2 must have number_hl_group = AgyPromptArea")
assert(multi_prompt_marks[2][4].sign_text == "  ", "Line 2 must have sign_text = '  '")
assert(multi_prompt_marks[2][4].sign_hl_group == "AgyPromptSign", "Line 2 must have sign_hl_group = AgyPromptSign")
print("✓ Multi-line prompt gutter highlights verified: matching sign column and number column background")

-- Set single line text for submission test
vim.api.nvim_buf_set_lines(buf1, state1.prompt_start_line - 1, -1, false, { "Hello Antigravity from agy.nvim!" })
protocol.update_prompt_divider(buf1)

local typed_text = vim.api.nvim_buf_get_lines(buf1, state1.prompt_start_line - 1, state1.prompt_start_line, false)[1]
print("Line text after typing: '" .. typed_text .. "'")
assert(typed_text == "Hello Antigravity from agy.nvim!", "Typed text must NOT be undone!")
assert(vim.bo[buf1].modified == true, "Buffer must be marked modified after typing")
print("✓ Typing works smoothly, text was not undone or stuck")

-- Trigger :w (BufWriteCmd)
print("Triggering :write...")
vim.cmd("write")

-- Check modified state after :w
local is_modified = vim.bo[buf1].modified
print("Buffer modified state immediately after :w: " .. tostring(is_modified))
assert(is_modified == false, "Buffer modified flag must be FALSE after :w (no [+]!)")
print("✓ Buffer modified flag is FALSE immediately after :w")

-- Prompt area background must be cleared from submitted lines
local prompt_bg_after = vim.api.nvim_buf_get_extmarks(buf1, render.NS_PROMPT, 0, -1, { details = true })
assert(#prompt_bg_after == 0, "Prompt background extmarks must be cleared after :w submission")
print("✓ Prompt background cleared after submission")

-- Inspect extmarks after :w
local extmarks_after_w = vim.api.nvim_buf_get_extmarks(buf1, render.NS_UI, 0, -1, { details = true })
print("UI extmarks count after :w: " .. #extmarks_after_w)
for i, em in ipairs(extmarks_after_w) do
	local virt_text = em[4].virt_lines and em[4].virt_lines[1] and em[4].virt_lines[1][1] and em[4].virt_lines[1][1][1]
		or "none"
	print(
		string.format(
			"  [%d] row=%d, col=%d, virt='%s', sign=%s",
			i,
			em[2],
			em[3],
			virt_text,
			tostring(em[4].sign_text)
		)
	)
end

-- Should have exactly 3 extmarks:
-- 1 for the submitted user divider (sign=nil)
-- 1 for the agent thinking divider
-- 1 for the bottom footer divider
assert(
	#extmarks_after_w == 3,
	"Must have exactly 3 UI extmarks after submission (1 user, 1 agent, 1 footer), found: " .. #extmarks_after_w
)

local user_count = 0
local agent_count = 0
local footer_count = 0
for _, em in ipairs(extmarks_after_w) do
	if em[4].virt_lines then
		for _, line in ipairs(em[4].virt_lines) do
			local virt_text = line[1] and line[1][1] or ""
			if virt_text:find("User") then
				user_count = user_count + 1
				assert(em[4].sign_text == nil, "Submitted user divider must NOT have sign_text!")
			elseif virt_text:find("Antigravity") then
				agent_count = agent_count + 1
			elseif virt_text:find("⚡") then
				footer_count = footer_count + 1
			end
		end
	end
end
assert(user_count == 1, "Must have exactly 1 User divider, found: " .. user_count)
assert(agent_count == 1, "Must have exactly 1 Agent divider, found: " .. agent_count)
assert(footer_count == 1, "Must have exactly 1 Footer divider, found: " .. footer_count)
print("✓ Exactly 1 User divider, 1 Agent divider, and 1 Footer divider verified!")
print("✓ Exactly 1 User divider and 1 Agent divider verified (no duplicate User divider!)")

protocol.cleanup_buffer(buf1)

-- -----------------------------------------------------------------
-- TEST 2: Typing in conversation with existing history
-- -----------------------------------------------------------------
print("\n[Test 2] Testing typing in conversation with history...")
local test_helpers = require("tests.test_helpers")
local tmp_dir, conv_id = test_helpers.create_mock_environment()
require("agy").setup({ app_data_dir = tmp_dir })
vim.cmd("edit agy://" .. conv_id)
local buf2 = vim.api.nvim_get_current_buf()
local win2 = vim.api.nvim_get_current_win()
local state2 = protocol.buffers[buf2]

print("Loaded conversation " .. conv_id .. ", prompt_start: " .. state2.prompt_start_line)
assert(state2.prompt_start_line > 1, "Conversation with history must have prompt_start_line > 1")

-- Position cursor at prompt line and type
vim.api.nvim_win_set_cursor(win2, { state2.prompt_start_line, 0 })
vim.cmd("normal! iTesting history typing\27")

-- Allow any scheduled events to process
vim.wait(50, function()
	return false
end)

local typed_history_text =
	vim.api.nvim_buf_get_lines(buf2, state2.prompt_start_line - 1, state2.prompt_start_line, false)[1]
print("Line text in history conversation after typing: '" .. typed_history_text .. "'")
assert(typed_history_text == "Testing history typing", "Typed text in history conversation must NOT be undone!")
print("✓ Typing in conversation with history does not trigger undo or freeze")

protocol.cleanup_buffer(buf2)

print("\nALL VERIFICATION TESTS PASSED SUCCESSFULLY!")
