local config_mod = require("agy.config")
local render = require("agy.render")
local utils = require("agy.utils")

print("=== Running Config Icons & Assertion Tests ===")

-- [Test 1] Testing custom icons configuration across all render functions
print("\n[Test 1] Testing custom icons across render functions...")

local custom_cfg = config_mod.setup({
	icons = {
		default = "  ",
		tool = "🔧",
		run_command = "⚙️",
		thought = "🧠",
		user = "🧑",
		agent = "👾",
		prompt_sign = "➜ ",
		footer = "🚀",
		done = "✔",
		question = "❔",
		error = "⛔",
		cancelled = "🛑",
		view_file = "📄", -- custom tool-specific icon override
	},
})

local test_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, { "Line 1", "Line 2", "Line 3", "Line 4" })

-- 1a. Verify set_divider uses custom user and agent icons
local ext1 = render.set_divider(test_buf, 0, "user", nil, nil, false, nil, custom_cfg)
local user_div = vim.api.nvim_buf_get_extmark_by_id(test_buf, render.NS_UI, ext1, { details = true })
assert(user_div[3].virt_lines[1][1][1]:find("🧑 User"), "Divider should use custom user icon '🧑'")

local ext2 = render.set_divider(test_buf, 1, "agent", " [✔ Done]", "AgyBadgeDone", false, nil, custom_cfg)
local agent_div = vim.api.nvim_buf_get_extmark_by_id(test_buf, render.NS_UI, ext2, { details = true })
assert(agent_div[3].virt_lines[1][1][1]:find("👾 Antigravity"), "Divider should use custom agent icon '👾'")

-- 1b. Verify set_divider with sign uses custom prompt_sign
local ext_sign = render.set_divider(test_buf, 2, "user", nil, nil, true, nil, custom_cfg)
local sign_mark = vim.api.nvim_buf_get_extmark_by_id(test_buf, render.NS_UI, ext_sign, { details = true })
assert(sign_mark[3].sign_text == "➜ ", "Prompt sign should use custom prompt_sign '➜ '")

-- 1c. Verify set_prompt_footer uses custom footer icon
local ext_foot = render.set_prompt_footer(test_buf, "gemini-3.8-flash", nil, true, custom_cfg)
local foot_marks = vim.api.nvim_buf_get_extmarks(test_buf, render.NS_UI, 0, -1, { details = true })
local found_foot = false
for _, em in ipairs(foot_marks) do
	if em[4].virt_lines then
		for _, vl in ipairs(em[4].virt_lines) do
			if vl[1] and vl[1][1] and vl[1][1]:find("🚀 gemini%-3%.8%-flash") then
				found_foot = true
			end
		end
	end
end
assert(found_foot, "Prompt footer should use custom footer icon '🚀'")

print("✓ Custom divider, prompt_sign, and footer icons verified")

-- [Test 2] Testing render_transcript with custom icons
print("\n[Test 2] Testing render_transcript with custom icons...")

local trans_buf = vim.api.nvim_create_buf(false, true)
local steps = {
	{ type = "USER_INPUT", content = "Test prompt" },
	{
		type = "PLANNER_RESPONSE",
		thinking = "Thinking about the task",
		duration_seconds = 0.5,
		tool_calls = {
			{
				name = "view_file",
				args = { TargetFile = "init.lua" },
				output = "content",
				duration_seconds = 0.1,
			},
			{
				name = "grep",
				args = { query = "search" },
				output = "found",
				duration_seconds = 0.2,
			},
			{
				name = "run_command",
				args = { CommandLine = "cargo build" },
				output = "ok",
				duration_seconds = 1.0,
			},
			{
				name = "ask_question",
				args = { questions = { { question = "Proceed?", options = { "Yes", "No" } } } },
				output = "Yes",
			},
		},
	},
}

local p_line, p_ext, tcs = render.render_transcript(trans_buf, "custom-icon-conv", steps, custom_cfg)
local t_lines = vim.api.nvim_buf_get_lines(trans_buf, 0, -1, false)

print("Rendered transcript lines:")
for idx, l in ipairs(t_lines) do
	print(string.format("  [%d] %s", idx, l))
end

-- Verify custom tool, custom specific tool (view_file = 📄), thought (🧠), run_command (⚙️), question (❔)
local found_thought = false
local found_view_file = false
local found_grep = false
local found_run_cmd = false
local found_question = false

for _, l in ipairs(t_lines) do
	if l:find("^🧠 Thought") then
		found_thought = true
	elseif l:find("^📄 view_file") then
		found_view_file = true
	elseif l:find("^🔧 grep") then
		found_grep = true
	elseif l:find("^⚙️ run_command") then
		found_run_cmd = true
	elseif l:find("^❔ Question") then
		found_question = true
	end
end

assert(found_thought, "Expected thought to use '🧠', found in buffer")
assert(found_view_file, "Expected view_file to use custom override '📄'")
assert(found_grep, "Expected grep to use generic tool icon '🔧'")
assert(found_run_cmd, "Expected run_command to use custom '⚙️'")
assert(found_question, "Expected question to use custom '❔'")

-- Check done badge on agent divider
local ui_exts = vim.api.nvim_buf_get_extmarks(trans_buf, render.NS_UI, 0, -1, { details = true })
local found_done_badge = false
for _, em in ipairs(ui_exts) do
	if em[4].virt_lines then
		for _, vl in ipairs(em[4].virt_lines) do
			for _, chunk in ipairs(vl) do
				if chunk[1] and chunk[1]:find("✔") then
					found_done_badge = true
				end
			end
		end
	end
end
assert(found_done_badge, "Expected agent divider to have badge with custom '✔'")

-- Verify tool calls display duration without [Done] or [Running] badges
for _, em in ipairs(ui_exts) do
	if em[4].virt_text and em[4].virt_text[1] then
		local text = em[4].virt_text[1][1]
		assert(not text:find("Done"), "Tool call badge should not contain 'Done'")
		assert(not text:find("Running"), "Tool call badge should not contain 'Running'")
	end
end

print("✓ render_transcript custom icons and badges verified")

-- [Test 3] Testing render_error and render_cancelled with custom icons
print("\n[Test 3] Testing render_error and render_cancelled with custom icons...")

local err_buf = vim.api.nvim_create_buf(false, true)
render.render_error(err_buf, "Something went wrong", custom_cfg)
local err_lines = vim.api.nvim_buf_get_lines(err_buf, 0, -1, false)
local found_err = false
for _, l in ipairs(err_lines) do
	if l:find("^⛔ Error:") then
		found_err = true
	end
end
assert(found_err, "render_error should use custom error icon '⛔'")

local cancel_buf = vim.api.nvim_create_buf(false, true)
render.render_cancelled(cancel_buf, custom_cfg)
local cancel_lines = vim.api.nvim_buf_get_lines(cancel_buf, 0, -1, false)
local found_cancel = false
for _, l in ipairs(cancel_lines) do
	if l:find("^🛑 Turn cancelled") then
		found_cancel = true
	end
end
assert(found_cancel, "render_cancelled should use custom cancelled icon '🛑'")

print("✓ render_error and render_cancelled custom icons verified")

-- [Test 4] Testing live streaming append functions with custom icons
print("\n[Test 4] Testing append_thought_block and append_tool_call with custom icons...")

local live_buf = vim.api.nvim_create_buf(false, true)
render.render_new_session(live_buf, custom_cfg)
render.append_thought_block(live_buf, "Analyzing...", 0.2, custom_cfg)
render.append_tool_call(live_buf, "run_command", { CommandLine = "ls" }, nil, custom_cfg)
render.append_tool_call(live_buf, "view_file", { AbsolutePath = "main.lua" }, nil, custom_cfg)
render.append_tool_call(live_buf, "grep", { query = "search" }, nil, custom_cfg)

local live_lines = vim.api.nvim_buf_get_lines(live_buf, 0, -1, false)
print("Live buffer lines:")
for idx, l in ipairs(live_lines) do
	print(string.format("  [%d] %s", idx, l))
end

local live_thought = false
local live_run = false
local live_view = false
local live_grep = false

for _, l in ipairs(live_lines) do
	if l:find("^🧠 Thought") then live_thought = true end
	if l:find("^⚙️ run_command") then live_run = true end
	if l:find("^📄 view_file") then live_view = true end
	if l:find("^🔧 grep") then live_grep = true end
end

assert(live_thought, "append_thought_block should use custom '🧠'")
assert(live_run, "append_tool_call run_command should use custom '⚙️'")
assert(live_view, "append_tool_call view_file should use custom '📄'")
assert(live_grep, "append_tool_call generic tool should use custom '🔧'")

print("✓ append_thought_block and append_tool_call custom icons verified")

-- [Test 5] Testing is_compact_header_line with custom icons
print("\n[Test 5] Testing is_compact_header_line with custom icons...")

assert(render.is_compact_header_line("🧠 Thought", custom_cfg) == true, "Should recognize custom thought header")
assert(render.is_compact_header_line("⚙️ run_command `ls`", custom_cfg) == true, "Should recognize custom run_command header")
assert(render.is_compact_header_line("📄 view_file `main.lua`", custom_cfg) == true, "Should recognize custom view_file header")
assert(render.is_compact_header_line("🔧 grep `search`", custom_cfg) == true, "Should recognize custom tool header")
assert(render.is_compact_header_line("   indented line", custom_cfg) == true, "Should recognize 3-space indentation")
assert(render.is_compact_header_line("Regular prose text", custom_cfg) == false, "Should not match regular text")

print("✓ is_compact_header_line dynamic config matching verified")

-- [Test 6] Testing assertions when required icons are missing
print("\n[Test 6] Testing assertions on missing icons...")

local broken_cfg = {
	icons = {},
}

-- 6a. set_divider missing user icon asserts
local ok_div, err_div = pcall(function()
	render.set_divider(test_buf, 0, "user", nil, nil, false, nil, broken_cfg)
end)
assert(not ok_div, "Expected assertion failure for missing 'user' icon")
assert(err_div:find("icon 'user' is not defined"), "Error message should mention missing 'user' icon: " .. tostring(err_div))

-- 6b. append_tool_call missing tool icon asserts
local ok_tool, err_tool = pcall(function()
	render.append_tool_call(test_buf, "some_tool", {}, nil, broken_cfg)
end)
assert(not ok_tool, "Expected assertion failure for missing tool icon")
assert(err_tool:find("no icon found for tool 'some_tool'"), "Error message should mention missing tool icon: " .. tostring(err_tool))

-- 6c. append_thought_block missing thought icon asserts
local ok_th, err_th = pcall(function()
	render.append_thought_block(test_buf, "thought", 0.1, broken_cfg)
end)
assert(not ok_th, "Expected assertion failure for missing thought icon")
assert(err_th:find("icon 'thought' is not defined"), "Error message should mention missing 'thought' icon: " .. tostring(err_th))

-- 6d. render_error missing error icon asserts
local ok_err, err_msg = pcall(function()
	render.render_error(test_buf, "fail", broken_cfg)
end)
assert(not ok_err, "Expected assertion failure for missing error icon")
assert(err_msg:find("icon 'error' is not defined"), "Error message should mention missing 'error' icon: " .. tostring(err_msg))

-- 6e. render_cancelled missing cancelled icon asserts
local ok_can, err_can = pcall(function()
	render.render_cancelled(test_buf, broken_cfg)
end)
assert(not ok_can, "Expected assertion failure for missing cancelled icon")
assert(err_can:find("icon 'cancelled' is not defined"), "Error message should mention missing 'cancelled' icon: " .. tostring(err_can))

print("✓ Strict icon assertions verified")

-- Reset config back to defaults for clean state
config_mod.setup()

print("\nALL CONFIG ICONS & ASSERTION TESTS PASSED SUCCESSFULLY!")
