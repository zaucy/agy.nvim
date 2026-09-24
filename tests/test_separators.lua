local helpers = require("tests.test_helpers")
local render = require("agy.render")
local separator_factories = require("agy.ui.separator")
local config = require("agy.config")

print("=== Running Separator Functions & Factory Tests ===\n")

render.setup_highlights()
local cfg = config.setup()

-- Helper to inspect extmark virt_lines
local function get_mark_virt_lines(buf, extmark_id)
	local mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, extmark_id, { details = true })
	assert(mark and mark[3], "Extmark must exist and have details")
	assert(mark[3].virt_lines, "Extmark must have virt_lines")
	return mark[3].virt_lines
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Turn 1", "Turn 2", "Turn 3", "Turn 4" })

-- [Test 1] Testing default line separator factory
print("[Test 1] Testing default line separator factory...")
local line_fn = separator_factories.line()
assert(type(line_fn) == "function", "separator_factories.line() must return a function")
local ext1 = render.set_divider(buf, 0, "user", nil, nil, false, nil, cfg)
local vl1 = get_mark_virt_lines(buf, ext1)
assert(#vl1 == 1, "Default line separator should be 1 line")
assert(vl1[1][1][1]:find("── 👤 User"), "Line 1 should contain '── 👤 User'")
assert(vl1[1][1][2] == "AgyUserDivider", "Title chunk should use AgyUserDivider")
print("✓ Default line separator verified")

-- [Test 2] Testing agent line separator with duration badge
print("[Test 2] Testing agent line separator with badge...")
local ext2 = render.set_divider(buf, 1, "agent", " [✓ 2.5s]", "AgyBadgeDone", false, nil, cfg)
local vl2 = get_mark_virt_lines(buf, ext2)
assert(#vl2 == 1, "Agent line separator should be 1 line")
assert(vl2[1][1][1]:find("── 🤖 Antigravity"), "Should contain '── 🤖 Antigravity'")
assert(vl2[1][1][2] == "AgyAgentDivider", "Title chunk should use AgyAgentDivider")
assert(vl2[1][2][1] == " [✓ 2.5s]", "Badge chunk should match")
assert(vl2[1][2][2] == "AgyBadgeDone", "Badge chunk should use AgyBadgeDone")
print("✓ Agent line separator with badge verified")

-- [Test 3] Testing require('agy.ui.separator').box('rounded') factory
print("[Test 3] Testing box('rounded') factory function...")
local box_rounded_fn = separator_factories.box("rounded")
assert(type(box_rounded_fn) == "function", "box('rounded') must return a function")

local box_cfg = config.setup({
	ui = {
		separator = box_rounded_fn,
	},
})

local ext3 = render.set_divider(buf, 2, "agent", " [Thinking...]", "AgyBadgeActive", false, nil, box_cfg)
local vl3 = get_mark_virt_lines(buf, ext3)
assert(#vl3 == 3, "Box separator must produce 3 lines (top, content, bottom), got: " .. #vl3)

-- Check Top Border (rounded: starts with ╭, ends with ╮)
assert(vim.startswith(vl3[1][1][1], "╭"), "Top line must start with ╭")
assert(vim.endswith(vl3[1][1][1], "╮"), "Top line must end with ╮")
assert(vl3[1][1][2] == "AgyDividerLine", "Top line must be highlighted with AgyDividerLine")

-- Check Content Line (starts with │, contains 🤖 Antigravity, contains badge, ends with │)
local content_line = vl3[2]
assert(content_line[1][1]:find("^│"), "Content line must start with │")
assert(content_line[1][2] == "AgyDividerLine", "Left border must be AgyDividerLine")
assert(content_line[2][1]:find("🤖 Antigravity"), "Title must be 🤖 Antigravity")
assert(content_line[2][2] == "AgyAgentDivider", "Title must use AgyAgentDivider")

local found_badge = false
for _, chunk in ipairs(content_line) do
	if chunk[1] == " [Thinking...]" and chunk[2] == "AgyBadgeActive" then
		found_badge = true
	end
end
assert(found_badge, "Badge [Thinking...] with AgyBadgeActive must be in content line")
assert(content_line[#content_line][1]:find("│$"), "Content line must end with │")
assert(content_line[#content_line][2] == "AgyDividerLine", "Right border must be AgyDividerLine")

-- Check Bottom Border (starts with ╰, ends with ╯)
assert(vim.startswith(vl3[3][1][1], "╰"), "Bottom line must start with ╰")
assert(vim.endswith(vl3[3][1][1], "╯"), "Bottom line must end with ╯")
assert(vl3[3][1][2] == "AgyDividerLine", "Bottom line must be highlighted with AgyDividerLine")
print("✓ Box separator (rounded) with multiple lines and highlights verified")

-- [Test 4] Testing require('agy.ui.separator').box('square')
print("[Test 4] Testing box('square') factory function...")
local square_fn = separator_factories.box("square")
assert(type(square_fn) == "function", "box('square') must return a function")
local square_cfg = config.setup({
	ui = {
		separator = square_fn,
	},
})

local ext4 = render.set_divider(buf, 0, "user", nil, nil, false, nil, square_cfg)
local vl4 = get_mark_virt_lines(buf, ext4)
assert(#vl4 == 3, "Square box separator must produce 3 lines")
assert(vim.startswith(vl4[1][1][1], "┌"), "Top line must start with ┌")
assert(vim.endswith(vl4[1][1][1], "┐"), "Top line must end with ┐")
assert(vim.startswith(vl4[3][1][1], "└"), "Bottom line must start with └")
assert(vim.endswith(vl4[3][1][1], "┘"), "Bottom line must end with ┘")
print("✓ Box separator (square) verified")

-- [Test 5] Testing require('agy.ui.separator').box('minimal')
print("[Test 5] Testing box('minimal') factory function...")
local min_box_fn = separator_factories.box("minimal")
assert(type(min_box_fn) == "function", "box('minimal') must return a function")
local min_box_cfg = config.setup({
	ui = {
		separator = min_box_fn,
	},
})

local ext5 = render.set_divider(buf, 1, "agent", nil, nil, false, nil, min_box_cfg)
local vl5 = get_mark_virt_lines(buf, ext5)
assert(#vl5 == 3, "Minimal box separator must produce 3 lines")
assert(vim.startswith(vl5[1][1][1], " "), "Minimal top line starts with space")
assert(vim.startswith(vl5[3][1][1], " "), "Minimal bottom line starts with space")
print("✓ Box separator (minimal) verified")

-- [Test 6] Testing require('agy.ui.separator').box({ custom 8 chars })
print("[Test 6] Testing box factory with custom 8-character table...")
local custom_box_fn = separator_factories.box({ "1", "2", "3", "4", "5", "6", "7", "8" })
assert(type(custom_box_fn) == "function", "box({...}) must return a function")
local custom_border_cfg = config.setup({
	ui = {
		separator = custom_box_fn,
	},
})

local ext6 = render.set_divider(buf, 3, "user", nil, nil, false, nil, custom_border_cfg)
local vl6 = get_mark_virt_lines(buf, ext6)
assert(vim.startswith(vl6[1][1][1], "1"), "Top line starts with custom topleft '1'")
assert(vim.endswith(vl6[1][1][1], "3"), "Top line ends with custom topright '3'")
assert(vim.startswith(vl6[3][1][1], "7"), "Bottom line starts with custom botleft '7'")
assert(vim.endswith(vl6[3][1][1], "5"), "Bottom line ends with custom botright '5'")
print("✓ Custom 8-character border table verified")

-- [Test 7] Testing fail-fast assertion on unknown border preset passed to box(...)
print("[Test 7] Testing fail-fast assertion on unknown border preset...")
local ok_box_err, err_box_msg = pcall(function()
	separator_factories.box("nonexistent_style")
end)
assert(not ok_box_err, "Expected assertion failure for unknown border preset in box()")
assert(err_box_msg:find("unknown border preset"), "Error must mention unknown border preset: " .. tostring(err_box_msg))
print("✓ Fail-fast assertion in box('nonexistent_style') verified")

-- [Test 8] Testing fail-fast rejection of text options in setup({ ui = { separator = "box" } })
print("[Test 8] Testing fail-fast rejection of non-function config...")
local ok_str_err, err_str_msg = pcall(function()
	config.setup({
		ui = {
			separator = "box", -- text option must be rejected!
		},
	})
end)
assert(not ok_str_err, "Expected setup to reject string option for ui.separator")
assert(err_str_msg:find("must be a function"), "Error message must indicate that ui.separator must be a function: " .. tostring(err_str_msg))
print("✓ Configuration rejection of non-function verified")

-- [Test 9] Testing minimal separator factory
print("[Test 9] Testing minimal separator factory...")
local min_fn = separator_factories.minimal()
assert(type(min_fn) == "function", "minimal() must return a function")
local min_cfg = config.setup({
	ui = {
		separator = min_fn,
	},
})

local ext8 = render.set_divider(buf, 0, "user", nil, nil, false, nil, min_cfg)
local vl8 = get_mark_virt_lines(buf, ext8)
assert(#vl8 == 2, "Minimal separator must produce 2 lines")
assert(vl8[1][1][1]:find("👤 User"), "Header must have '👤 User'")
assert(vl8[2][1][1]:find("┄"), "Divider line must have '┄'")
assert(vl8[2][1][2] == "AgyDividerLine", "Divider rule must use AgyDividerLine")
print("✓ Minimal separator factory verified")

-- [Test 10] Testing block separator factory
print("[Test 10] Testing block separator factory...")
local block_fn = separator_factories.block()
assert(type(block_fn) == "function", "block() must return a function")
local block_cfg = config.setup({
	ui = {
		separator = block_fn,
	},
})

local ext9 = render.set_divider(buf, 1, "agent", " [✓ 1.0s]", "AgyBadgeDone", false, nil, block_cfg)
local vl9 = get_mark_virt_lines(buf, ext9)
assert(#vl9 == 2, "Block separator must produce 2 lines")
assert(vl9[1][1][1] == "▌ ", "First chunk should be block '▌ '")
assert(vl9[1][1][2] == "AgySlashCommand", "Block chunk should use AgySlashCommand")
assert(vl9[2][1][1]:find("^▀─"), "Second line should start with ▀─")
print("✓ Block separator factory verified")

-- [Test 11] Testing custom user separator function via config.ui.separator
print("[Test 11] Testing custom user separator function via config.ui.separator...")
local custom_fn_cfg = config.setup({
	ui = {
		separator = function(ctx)
			assert(ctx.role == "agent", "Role must be agent")
			return {
				{ { ">>> START " .. ctx.name, "Title" }, { " (" .. ctx.role .. ")", "Comment" } },
				{ { "--- Custom Rule Line ---", "NonText" } },
			}
		end,
	},
})

local ext10 = render.set_divider(buf, 2, "agent", nil, nil, false, nil, custom_fn_cfg)
local vl10 = get_mark_virt_lines(buf, ext10)
assert(#vl10 == 2, "Custom function must produce 2 lines")
assert(vl10[1][1][1] == ">>> START Antigravity", "Custom line 1 chunk 1 verified")
assert(vl10[1][1][2] == "Title", "Custom line 1 highlight verified")
assert(vl10[1][2][1] == " (agent)", "Custom line 1 chunk 2 verified")
assert(vl10[2][1][1] == "--- Custom Rule Line ---", "Custom line 2 verified")
print("✓ Custom user separator function via config verified")

-- [Test 12] Testing overriding render.draw_separator directly
print("[Test 12] Testing direct override of render.draw_separator...")
config.setup() -- reset to defaults
local orig_draw = render.draw_separator
render.draw_separator = function(ctx)
	return {
		{ { "== " .. ctx.name .. " ==", "Keyword" } },
	}
end

local ext11 = render.set_divider(buf, 3, "user", nil, nil, false, nil, cfg)
local vl11 = get_mark_virt_lines(buf, ext11)
assert(#vl11 == 1, "Overridden separator must produce 1 line")
assert(vl11[1][1][1] == "== User ==", "Overridden separator text verified")
assert(vl11[1][1][2] == "Keyword", "Overridden separator highlight verified")

-- Restore original draw function
render.draw_separator = orig_draw
print("✓ Direct override of render.draw_separator verified")

-- [Test 13] Testing multi-window independence and alignment
print("[Test 13] Testing multi-window independence and exact alignment...")
local box_fn = separator_factories.box("rounded")
local ctx_narrow = {
	buf = buf,
	line = 0,
	role = "agent",
	name = "Antigravity",
	icon = "🤖",
	badge_text = " [✓ 1.2s]",
	badge_hl = "AgyBadgeDone",
	title_hl = "AgyAgentDivider",
	width = 50, -- narrow window
	config = cfg,
}
local ctx_wide = vim.deepcopy(ctx_narrow)
ctx_wide.width = 160 -- wide window

local res_narrow = box_fn(ctx_narrow)
local res_wide = box_fn(ctx_wide)

-- Verify that the width of the box is identical in both narrow and wide contexts
local top_w_narrow = vim.api.nvim_strwidth(res_narrow[1][1][1])
local top_w_wide = vim.api.nvim_strwidth(res_wide[1][1][1])
assert(top_w_narrow == top_w_wide, "Box width must be content-based and independent of window width")

-- Verify that top, middle, and bottom lines have identical display column widths
local bot_w = vim.api.nvim_strwidth(res_narrow[3][1][1])
local mid_w = 0
for _, chunk in ipairs(res_narrow[2]) do
	mid_w = mid_w + vim.api.nvim_strwidth(chunk[1])
end
assert(top_w_narrow == mid_w, string.format("Top width (%d) must match middle width (%d)", top_w_narrow, mid_w))
assert(top_w_narrow == bot_w, string.format("Top width (%d) must match bottom width (%d)", top_w_narrow, bot_w))
print("✓ Multi-window width independence and perfect right-border alignment verified")

-- [Test 14] Testing thinking spinner animation lifecycle
print("[Test 14] Testing thinking spinner animation lifecycle...")
local anim_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(anim_buf, 0, -1, false, { "Agent Turn Line" })
local anim_cfg = config.setup({
	ui = {
		separator = separator_factories.line(),
		animate_thinking = true,
	},
})
local ext_anim = render.set_divider(anim_buf, 0, "user", nil, nil, true, nil, anim_cfg)
render.start_thinking_animation(anim_buf, 0, ext_anim, anim_cfg)
assert(render.thinking_timers[anim_buf] ~= nil, "Thinking timer must be running")

-- Wait for at least one animation frame update
local updated = vim.wait(300, function()
	local vl = get_mark_virt_lines(anim_buf, ext_anim)
	local badge = (vl[1] and vl[1][1] and vl[1][1][1]) or ""
	-- Check if badge contains one of the braille spinner frames
	return badge:find("Thinking") ~= nil
end, 20)
assert(updated, "Thinking spinner must update prompt divider with animation frames")

-- Also verify that agent divider does not contain thinking badge
local agent_ext = render.set_divider(anim_buf, 0, "agent", nil, nil, false, nil, anim_cfg)
local agent_vl = get_mark_virt_lines(anim_buf, agent_ext)
assert(not agent_vl[1][1][1]:find("Thinking"), "Agent divider must not contain Thinking badge")

render.stop_thinking_animation(anim_buf)
assert(render.thinking_timers[anim_buf] == nil, "Timer must be cleaned up on stop")
print("✓ Thinking spinner animation lifecycle verified")

-- [Test 15] Testing animate_thinking = false
print("[Test 15] Testing disabled thinking animation...")
local no_anim_cfg = config.setup({
	ui = {
		animate_thinking = false,
	},
})
render.start_thinking_animation(anim_buf, 0, ext_anim, no_anim_cfg)
assert(render.thinking_timers[anim_buf] == nil, "No timer should be started when animate_thinking is false")
print("✓ Disabled thinking animation verified")

print("\nALL SEPARATOR & CUSTOM RENDERER TESTS PASSED SUCCESSFULLY!")


