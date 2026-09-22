local config_mod = require("agy.config")
local render = require("agy.render")
local protocol = require("agy.protocol")
local utils = require("agy.utils")

print("=== Running Inverted V Logo Header & Dynamic Animation Tests ===")

-- [Test 1] Testing banner lines generation and inverted V logo geometry
print("\n[Test 1] Testing banner lines generation and inverted V logo geometry...")

local cfg = config_mod.setup({
	ui = {
		header_style = "banner",
		animate_logo = true,
	},
})
render.setup_highlights()

local buf = vim.api.nvim_create_buf(false, true)
local p_line, p_ext = render.init_session_buffer(buf, "agy://new", cfg)

assert(p_line == 8, "Expected prompt_start_line == 8, got: " .. tostring(p_line))
assert(p_ext ~= nil, "Expected valid prompt extmark ID")

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Rendered banner lines count: " .. #lines)
for idx, l in ipairs(lines) do
	print(string.format("  [%d] %s", idx, l))
end

assert(#lines == 8, "Expected 8 lines total, got: " .. #lines)
assert(lines[1] == "", "Line 1 must be top padding empty line")
assert(lines[3]:find("Antigravity CLI", 1, true), "Line 3 must contain 'Antigravity CLI'")
assert(lines[4]:find("agy://new", 1, true), "Line 4 must contain 'agy://new'")
assert(lines[7] == "", "Line 7 must be bottom padding empty line")
assert(lines[8] == "", "Line 8 must be prompt empty line")

-- Verify inverted V logo characters on lines 2..6 with left padding
-- Row 1:   ▀▀▄      ▄▀▀
assert(lines[2]:find("^  "), "Line 2 must have left padding")
assert(lines[2]:find("▀▀▄"), "Line 2 must contain left wing ▀▀▄")
assert(lines[2]:find("▄▀▀"), "Line 2 must contain right wing ▄▀▀")

-- Row 2:    ▀▀▀    ▀▀▀ 
assert(lines[3]:find("▀▀▀"), "Line 3 must contain sloping wings ▀▀▀")

-- Row 3:     ▀▀▀▄▄▀▀▀  
assert(lines[4]:find("▄▄"), "Line 4 must contain inner apex dip ▄▄")

-- Row 4:      ▀▀▀▀▀▀   
assert(lines[5]:find("▀▀▀▀▀▀"), "Line 5 must contain joining body ▀▀▀▀▀▀")

-- Row 5:       ▀▀▀▀    
assert(lines[6]:find("▀▀▀▀"), "Line 6 must contain bottom apex tip ▀▀▀▀")

print("✓ Inverted V logo geometry and header text verified")

-- [Test 2] Testing NS_LOGO extmarks and two-tone foreground/background highlights
print("\n[Test 2] Testing NS_LOGO extmarks and cell highlights...")

local logo_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_LOGO, 0, -1, { details = true })
print("NS_LOGO extmarks count: " .. #logo_marks)
assert(#logo_marks >= 30, "Expected at least 30 logo cell extmarks, got: " .. #logo_marks)

local found_title_hl = false
local found_sub_hl = false
local found_two_tone = false

for _, m in ipairs(logo_marks) do
	local details = m[4]
	if details.hl_group == "AgyHeaderTitle" then
		found_title_hl = true
	elseif details.hl_group == "AgyHeaderSub" then
		found_sub_hl = true
	elseif details.hl_group:find("^AgyLogo_") then
		local hl = vim.api.nvim_get_hl(0, { name = details.hl_group, link = false })
		if hl and hl.fg and hl.bg then
			found_two_tone = true
		end
	end
end

assert(found_title_hl, "AgyHeaderTitle extmark must exist on line 3")
assert(found_sub_hl, "AgyHeaderSub extmark must exist on line 4")
assert(found_two_tone, "At least one cell must have both fg and bg set for two-tone half-block rendering")
print("✓ NS_LOGO extmarks and two-tone highlight rendering verified")

-- [Test 3] Testing update_session_id updating line 4 to agy://<conv_id>
print("\n[Test 3] Testing update_session_id with banner header_style...")

local test_conv_id = "test-conv-12345"
render.update_session_id(buf, test_conv_id, cfg)

local updated_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(updated_lines[4]:find("agy://" .. test_conv_id, 1, true), "Line 4 must be updated with new conversation ID")
assert(updated_lines[4]:find("▄▄"), "Line 4 must retain logo block characters")

-- Verify AgyHeaderSub extmark still exists on line 4
local line4_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_LOGO, { 3, 0 }, { 3, -1 }, { details = true })
local has_updated_sub = false
for _, m in ipairs(line4_marks) do
	if m[4].hl_group == "AgyHeaderSub" then
		has_updated_sub = true
	end
end
assert(has_updated_sub, "AgyHeaderSub must be preserved after update_session_id")
print("✓ update_session_id dynamic line 4 updating verified")

-- [Test 4] Testing dynamic color animation lifecycle and hue shifting
print("\n[Test 4] Testing dynamic color animation lifecycle and hue shifting...")

-- Verify timer is running when animate_logo = true
assert(render.logo_timer ~= nil, "Logo animation timer must be running")
assert(render.active_logo_buffers[buf] == true, "Buffer must be registered in active_logo_buffers")

-- Test manual frame application with hue rotation
local hl_before = vim.api.nvim_get_hl(0, { name = "AgyLogo_0_1", link = false })
render.apply_logo_animation_frame(90, cfg)
local hl_after = vim.api.nvim_get_hl(0, { name = "AgyLogo_0_1", link = false })

assert(hl_before.fg ~= hl_after.fg, "Hue shift must alter cell fg color")

-- Test stopping animation
render.stop_logo_animation(buf)
assert(render.logo_timer == nil, "Logo timer must be stopped and cleared")
assert(render.active_logo_buffers[buf] == nil, "Buffer must be removed from active_logo_buffers")

-- Verify highlight reset to base static colors
local hl_reset = vim.api.nvim_get_hl(0, { name = "AgyLogo_0_1", link = false })
assert(hl_reset.fg == hl_before.fg, "reset_logo_highlights must restore original static colors")
print("✓ Dynamic color animation frame updates and cleanup verified")

-- [Test 5] Testing animate_logo = false disables timer
print("\n[Test 5] Testing animate_logo = false...")

local static_cfg = config_mod.setup({
	ui = {
		header_style = "banner",
		animate_logo = false,
	},
})

local buf_static = vim.api.nvim_create_buf(false, true)
render.init_session_buffer(buf_static, "agy://static", static_cfg)
assert(render.logo_timer == nil, "Timer must NOT be created when animate_logo = false")
print("✓ animate_logo = false option verified")

-- [Test 6] Testing header_style = 'markdown' classic fallback
print("\n[Test 6] Testing header_style = 'markdown' classic fallback...")

local md_cfg = config_mod.setup({
	ui = {
		header_style = "markdown",
	},
})

local buf_md = vim.api.nvim_create_buf(false, true)
local md_p_line = render.init_session_buffer(buf_md, "agy://classic", md_cfg)
assert(md_p_line == 3, "Expected prompt_start_line == 3 for markdown header, got: " .. tostring(md_p_line))

local md_lines = vim.api.nvim_buf_get_lines(buf_md, 0, -1, false)
assert(md_lines[1] == "# Antigravity Session: agy://classic", "Line 1 must contain classic markdown header")
assert(#vim.api.nvim_buf_get_extmarks(buf_md, render.NS_LOGO, 0, -1, {}) == 0, "NS_LOGO marks must be empty for markdown style")

render.update_session_id(buf_md, "new-id", md_cfg)
local md_updated = vim.api.nvim_buf_get_lines(buf_md, 0, -1, false)
assert(md_updated[1] == "# Antigravity Session: agy://new-id", "Line 1 must be updated in markdown style")
print("✓ header_style = 'markdown' classic mode verified")

-- [Test 7] Testing AGENTS.md assertions on missing block icons
print("\n[Test 7] Testing fail-fast assertions on missing block icons...")

local broken_cfg = {
	icons = {
		-- missing upper_block and lower_block
	},
	ui = {
		header_style = "banner",
	},
}

local ok, err = pcall(function()
	local test_b = vim.api.nvim_create_buf(false, true)
	render.init_session_buffer(test_b, "agy://broken", broken_cfg)
end)

assert(not ok, "Expected assertion failure for missing block icons")
assert(err:find("icon is not defined in config.icons"), "Error message should mention missing block icon: " .. tostring(err))
print("✓ Fail-fast assertions on missing block icons verified")

-- [Test 8] Testing version formatting with cached and custom CLI version
print("\n[Test 8] Testing version detection and display...")

utils._set_agy_version("1.2.8")
local v_lines = render.build_banner_lines("agy://version-test", cfg)
assert(v_lines[3]:find("Antigravity CLI 1.2.8", 1, true), "Line 3 must contain 'Antigravity CLI 1.2.8'")

utils._set_agy_version(nil)
print("✓ Antigravity CLI version formatting verified")

-- Cleanup
render.stop_logo_animation()
config_mod.setup()

print("\nALL INVERTED V LOGO HEADER TESTS PASSED PERFECTLY!")
vim.cmd("qall!")
