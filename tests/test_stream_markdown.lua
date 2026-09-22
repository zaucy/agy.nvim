local config_mod = require("agy.config")
local render = require("agy.render")
local markdown = require("agy.markdown")
local utils = require("agy.utils")

print("=== Running Stream Markdown Rendering Tests ===")

-- Reset configuration with classic markdown header for pure markdown stream testing
local cfg = config_mod.setup({ ui = { header_style = "markdown" } })
render.setup_highlights()

-- [Test 1] Table Rendering with Rounded Box Borders and Alignments
print("\n[Test 1] Testing table rendering with rounded box borders and alignments...")

local test_table_md = table.concat({
	"| Name | Score | Status |",
	"| :--- | :---: | ---: |",
	"| Alice | 95 | Active |",
	"| Bob | 80 | Pending |",
}, "\n") .. "\n"

local buf1 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf1, cfg)
render.prepare_turn_submission(buf1, 3, nil, cfg)
render.append_text_delta(buf1, test_table_md, cfg)
render.finalize_turn(buf1, nil, 2, { status = "DONE" }, cfg)

local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
print("Rendered table lines:")
for idx, l in ipairs(lines1) do
	print(string.format("  [%2d] %s", idx, l))
end

-- Verify top border: ╭─┬─┬─╮
local found_top = false
local found_header = false
local found_sep = false
local found_alice = false
local found_bob = false
local found_bottom = false

for _, l in ipairs(lines1) do
	if l:find("╭") and l:find("┬") and l:find("╮") then
		found_top = true
	end
	if l:find("│%s*Name%s*│%s*Score%s*│%s*Status%s*│") then
		found_header = true
	end
	if l:find("├") and l:find("┼") and l:find("┤") then
		found_sep = true
	end
	if l:find("│%s*Alice%s*│") and l:find("│%s*Active%s*│") then
		found_alice = true
	end
	if l:find("│%s*Bob%s*│") and l:find("│%s*Pending%s*│") then
		found_bob = true
	end
	if l:find("╰") and l:find("┴") and l:find("╯") then
		found_bottom = true
	end
end

assert(found_top, "Top rounded table border ╭─┬─╮ must be rendered")
assert(found_header, "Header row with cell padding must be rendered")
assert(found_sep, "Separator row ├─┼─┤ must be rendered")
assert(found_alice, "Alice row must be rendered with proper alignment")
assert(found_bob, "Bob row must be rendered with proper alignment")
assert(found_bottom, "Bottom rounded table border ╰─┴─╯ must be rendered")

-- Verify table extmarks
local t_marks = vim.api.nvim_buf_get_extmarks(buf1, markdown.NS_MARKDOWN, 0, -1, { details = true })
local has_border_hl = false
local has_header_hl = false
for _, em in ipairs(t_marks) do
	if em[4].hl_group == "AgyTableBorder" then
		has_border_hl = true
	elseif em[4].hl_group == "AgyTableHeader" then
		has_header_hl = true
	end
end
assert(has_border_hl, "AgyTableBorder highlight must be applied to table borders")
assert(has_header_hl, "AgyTableHeader highlight must be applied to table header")
print("✓ Table borders, cell padding, alignments, and highlights verified")

-- [Test 2] Live Stream Dynamic Column Width Expansion
print("\n[Test 2] Testing live streaming dynamic column width expansion...")

local buf2 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf2, cfg)
render.prepare_turn_submission(buf2, 3, nil, cfg)

-- Delta 1: Initial narrow table
render.append_text_delta(buf2, "| ColA | ColB |\n|---|---|\n| 1 | 2 |\n", cfg)
local lines_d1 = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
local top_len_1 = nil
for _, l in ipairs(lines_d1) do
	if l:find("╭") and l:find("╮") then
		top_len_1 = vim.fn.strdisplaywidth(l)
	end
end
assert(top_len_1 ~= nil, "Initial table top border must exist")

-- Delta 2: Stream in a row with a much wider cell
render.append_text_delta(buf2, "| VeryLongColumnContent | 2000 |\n", cfg)
local lines_d2 = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
local top_len_2 = nil
local found_expanded_row = false
for _, l in ipairs(lines_d2) do
	if l:find("╭") and l:find("╮") then
		top_len_2 = vim.fn.strdisplaywidth(l)
	end
	if l:find("VeryLongColumnContent") then
		found_expanded_row = true
	end
end

assert(found_expanded_row, "Wider row must be present in buffer")
assert(top_len_2 > top_len_1, string.format("Table width must expand dynamically: %d > %d", top_len_2, top_len_1))

-- Verify all rows expanded to match top border width
for _, l in ipairs(lines_d2) do
	if l:find("╭") or l:find("├") or l:find("╰") then
		assert(vim.fn.strdisplaywidth(l) == top_len_2, "Border widths must match expanded table width")
	elseif l:find("│") then
		assert(vim.fn.strdisplaywidth(l) == top_len_2, "Data row widths must match expanded table width")
	end
end
print("✓ Live stream dynamic column width recalculation and expansion verified")

-- [Test 3] Scaled Headers with Radnvim SCALE_PROTOCOL
print("\n[Test 3] Testing scaled headers with Radnvim SCALE_PROTOCOL...")

local header_md = table.concat({
	"# Top Level Heading",
	"## Secondary Heading",
	"### Third Section",
	"#### Fourth Section",
	"##### Fifth Section",
	"###### Sixth Section",
}, "\n") .. "\n"

local buf3 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf3, cfg)
render.prepare_turn_submission(buf3, 3, nil, cfg)
render.append_text_delta(buf3, header_md, cfg)
render.finalize_turn(buf3, nil, 2, { status = "DONE" }, cfg)

local lines3 = vim.api.nvim_buf_get_lines(buf3, 0, -1, false)
print("Rendered header lines:")
for idx, l in ipairs(lines3) do
	print(string.format("  [%2d] %s", idx, l))
end

-- Check that header lines have # prefixes stripped and clean heading text rendered
assert(lines3[4] == "Top Level Heading", "H1 line: " .. tostring(lines3[4]))
assert(lines3[5] == "Secondary Heading", "H2 line: " .. tostring(lines3[5]))
assert(lines3[6] == "Third Section", "H3 line: " .. tostring(lines3[6]))
assert(lines3[7] == "Fourth Section", "H4 line: " .. tostring(lines3[7]))
assert(lines3[8] == "Fifth Section", "H5 line: " .. tostring(lines3[8]))
assert(lines3[9] == "Sixth Section", "H6 line: " .. tostring(lines3[9]))

-- Verify line_hl_group extmarks
local h_marks = vim.api.nvim_buf_get_extmarks(buf3, markdown.NS_MARKDOWN, 0, -1, { details = true })
local found_h_hl = {}
for _, em in ipairs(h_marks) do
	if em[4].line_hl_group then
		found_h_hl[em[4].line_hl_group] = true
	end
end
assert(found_h_hl["AgyH1"], "Extmark with line_hl_group = AgyH1 must be set")
assert(found_h_hl["AgyH2"], "Extmark with line_hl_group = AgyH2 must be set")
assert(found_h_hl["AgyH3"], "Extmark with line_hl_group = AgyH3 must be set")
assert(found_h_hl["AgyH4"], "Extmark with line_hl_group = AgyH4 must be set")
assert(found_h_hl["AgyH5"], "Extmark with line_hl_group = AgyH5 must be set")
assert(found_h_hl["AgyH6"], "Extmark with line_hl_group = AgyH6 must be set")

-- Verify highlight definitions contain :scale= protocol font attribute
local hl_h1 = vim.api.nvim_get_hl(0, { name = "AgyH1" })
assert(hl_h1.font and hl_h1.font:find(":scale=2.0"), "AgyH1 must define scale=2.0 in font attribute: " .. tostring(hl_h1.font))
assert(hl_h1.bold == true, "AgyH1 must be bold")
print("✓ Scaled headers (gui extmarks only) and Radnvim SCALE_PROTOCOL attributes verified")

-- [Test 4] Code Blocks with Language Header, Full-Width Background, No Borders, and Treesitter Highlighting
print("\n[Test 4] Testing code blocks with language header, full-width background, no borders, and treesitter highlighting...")

local code_md = table.concat({
	"```lua",
	"local msg = 'Hello world'",
	"print(msg)",
	"```",
}, "\n") .. "\n"

local buf4 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf4, cfg)
render.prepare_turn_submission(buf4, 3, nil, cfg)
render.append_text_delta(buf4, code_md, cfg)
render.finalize_turn(buf4, nil, 2, { status = "DONE" }, cfg)

local lines4 = vim.api.nvim_buf_get_lines(buf4, 0, -1, false)
print("Rendered code block lines:")
for idx, l in ipairs(lines4) do
	print(string.format("  [%2d] %s", idx, l))
end

local found_code_top = false
local found_code_body = false
local found_border_chars = false
for _, l in ipairs(lines4) do
	if l:find("lua") and not l:find("local msg") then
		found_code_top = true
	end
	if l:find("local msg = 'Hello world'") then
		found_code_body = true
	end
	if l:find("╭") or l:find("╰") or l:find("─") or l:find("│") then
		found_border_chars = true
	end
end
assert(found_code_top, "Code block top line with language 'lua' must be rendered")
assert(found_code_body, "Code body line must be preserved")
assert(not found_border_chars, "Code block must NOT render any border lines/characters")

local cb_marks = vim.api.nvim_buf_get_extmarks(buf4, markdown.NS_MARKDOWN, 0, -1, { details = true })
local found_treesitter_hl = false
local found_code_block_hl = false
local found_code_lang_hl = false
for _, em in ipairs(cb_marks) do
	if em[4].hl_group and em[4].hl_group:find("^@") then
		found_treesitter_hl = true
	end
	if em[4].hl_group == "AgyCodeLang" then
		found_code_lang_hl = true
	end
	if em[4].line_hl_group == "AgyCodeBlock" then
		found_code_block_hl = true
	end
end
assert(found_code_lang_hl, "AgyCodeLang highlight must be applied to language label")
assert(found_treesitter_hl, "Treesitter syntax highlight extmarks (@...) must be applied to body")
assert(found_code_block_hl, "AgyCodeBlock line_hl_group must be applied across code block lines")
print("✓ Code block language header, full-width AgyCodeBlock background, no borders, and syntax highlighting verified")

-- [Test 5] Lists and Checkboxes
print("\n[Test 5] Testing lists and checkboxes...")

local list_md = table.concat({
	"- [ ] Uncompleted task",
	"- [x] Completed task",
	"- Bullet item level 1",
	"  - Bullet item level 2",
	"    - Bullet item level 3",
}, "\n") .. "\n"

local buf5 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf5, cfg)
render.prepare_turn_submission(buf5, 3, nil, cfg)
render.append_text_delta(buf5, list_md, cfg)
render.finalize_turn(buf5, nil, 2, { status = "DONE" }, cfg)

local lines5 = vim.api.nvim_buf_get_lines(buf5, 0, -1, false)
print("Rendered list lines:")
for idx, l in ipairs(lines5) do
	print(string.format("  [%2d] %s", idx, l))
end

local found_uncheck = false
local found_check = false
local found_b1 = false
local found_b2 = false
local found_b3 = false

for _, l in ipairs(lines5) do
	if l:find("󰄱") and l:find("Uncompleted task") then
		found_uncheck = true
	end
	if l:find("󰄵") and l:find("Completed task") then
		found_check = true
	end
	if l:find("●") and l:find("Bullet item level 1") then
		found_b1 = true
	end
	if l:find("○") and l:find("Bullet item level 2") then
		found_b2 = true
	end
	if l:find("◆") and l:find("Bullet item level 3") then
		found_b3 = true
	end
end

assert(found_uncheck, "Unchecked task item must render checkbox_unchecked icon '󰄱'")
assert(found_check, "Checked task item must render checkbox_checked icon '󰄵'")
assert(found_b1, "Level 1 bullet must render '●'")
assert(found_b2, "Level 2 bullet must render '○'")
assert(found_b3, "Level 3 bullet must render '◆'")
print("✓ List bullets and task checkboxes rendering verified")

-- [Test 6] Images Rendering with Spacer Allocation and Protocol
print("\n[Test 6] Testing image spacer allocation and Kitty graphics protocol...")

local buf6 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf6, cfg)
render.prepare_turn_submission(buf6, 3, nil, cfg)
render.append_text_delta(buf6, "![Architecture Diagram](nonexistent_diagram.png)\n", cfg)
render.finalize_turn(buf6, nil, 2, { status = "DONE" }, cfg)

local lines6 = vim.api.nvim_buf_get_lines(buf6, 0, -1, false)
local found_img_placeholder = false
for _, l in ipairs(lines6) do
	if l:find("") and l:find("Architecture Diagram") then
		found_img_placeholder = true
	end
end
assert(found_img_placeholder, "Image placeholder with image icon must be rendered")
print("✓ Image placeholder and protocol integration verified")

-- [Test 7] Canonical Raw Markdown Preservation
print("\n[Test 7] Testing canonical raw markdown preservation in memory...")

local raw_test_md = "# Title\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
local buf7 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf7, cfg)
render.prepare_turn_submission(buf7, 3, nil, cfg)
render.append_text_delta(buf7, raw_test_md, cfg)

-- Check that markdown.get_raw_text returns the exact canonical raw markdown
local stored_raw = markdown.get_raw_text(buf7)
assert(stored_raw == raw_test_md, "Canonical raw markdown must be preserved in memory while buffer is transformed")

-- Check that buffer lines are transformed (e.g. # stripped, table boxed)
local b7_lines = vim.api.nvim_buf_get_lines(buf7, 0, -1, false)
local has_transformed_table = false
for _, l in ipairs(b7_lines) do
	if l:find("╭") and l:find("╮") then
		has_transformed_table = true
	end
end
assert(has_transformed_table, "Buffer lines must contain transformed table")
print("✓ Clean separation: canonical raw markdown preserved in memory while buffer lines transformed")

-- [Test 8] Custom ui.render_markdown Function Override
print("\n[Test 8] Testing custom config.ui.render_markdown override...")

local custom_called = false
local custom_cfg = config_mod.setup({
	ui = {
		render_markdown = function(buf, delta, is_final, c)
			custom_called = true
			return markdown.render(buf, delta, is_final, c)
		end,
	},
})

local buf8 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf8, custom_cfg)
render.prepare_turn_submission(buf8, 3, nil, custom_cfg)
render.append_text_delta(buf8, "Test custom render\n", custom_cfg)

assert(custom_called == true, "Custom config.ui.render_markdown function must be invoked")
print("✓ Custom config.ui.render_markdown configuration override verified")

-- [Test 9] Strict AGENTS.md Assertions on Missing Icons
print("\n[Test 9] Testing AGENTS.md assertions on missing icons...")

local broken_cfg = {
	icons = {},
}

local ok_t, err_t = pcall(function()
	markdown.transform_markdown("| A | B |\n|---|---|\n| 1 | 2 |\n", true, broken_cfg)
end)
assert(not ok_t, "Expected assertion failure for missing table icons")
assert(err_t:find("table.*icons table is required"), "Error message should mention missing table icons: " .. tostring(err_t))

local broken_bullets_cfg = {
	icons = {
		table = cfg.icons.table,
		code_block = cfg.icons.code_block,
		bullets = {},
	},
}
local ok_b, err_b = pcall(function()
	markdown.transform_markdown("- item\n", true, broken_bullets_cfg)
end)
assert(not ok_b, "Expected assertion failure for missing bullets list")
assert(err_b:find("bullets.*list is required"), "Error message should mention missing bullets: " .. tostring(err_b))

print("✓ Strict AGENTS.md assertions on missing icons verified")

-- [Test 10] Non-Table Pipe Handling (Sentences and List Items with Pipes)
print("\n[Test 10] Testing non-table pipe handling in text and lists...")

local piped_text = "Here is a command: `git log --oneline | grep foo | head -n 5`\n"
local buf10 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf10, cfg)
render.prepare_turn_submission(buf10, 3, nil, cfg)
render.append_text_delta(buf10, piped_text, cfg)
render.finalize_turn(buf10, nil, 2, { status = "DONE" }, cfg)

local lines10 = vim.api.nvim_buf_get_lines(buf10, 0, -1, false)
local found_fake_table = false
for _, l in ipairs(lines10) do
	if l:find("╭") or l:find("╰") or l:find("├") then
		found_fake_table = true
	end
end
assert(not found_fake_table, "Sentences with pipe characters must NOT be converted into tables")

local list_with_pipes = "- Option A | Detail A | Notes A\n- Option B | Detail B | Notes B\n"
local buf10b = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf10b, cfg)
render.prepare_turn_submission(buf10b, 3, nil, cfg)
render.append_text_delta(buf10b, list_with_pipes, cfg)
render.finalize_turn(buf10b, nil, 2, { status = "DONE" }, cfg)

local lines10b = vim.api.nvim_buf_get_lines(buf10b, 0, -1, false)
local found_b_pipe = false
for _, l in ipairs(lines10b) do
	if l:find("●") and l:find("Option A | Detail A | Notes A") then
		found_b_pipe = true
	end
end
assert(found_b_pipe, "List items with pipe characters must remain list items with bullets")
print("✓ Non-table pipe sentences and lists preserved without corruption")

-- [Test 11] Non-ATX Headings Edge Cases (#123, #include)
print("\n[Test 11] Testing non-ATX headings (#123, #include) are not falsely styled...")

local non_headings = "#123 is closed\n#include <stdio.h>\n# Genuine Heading\n"
local buf11 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf11, cfg)
render.prepare_turn_submission(buf11, 3, nil, cfg)
render.append_text_delta(buf11, non_headings, cfg)
render.finalize_turn(buf11, nil, 2, { status = "DONE" }, cfg)

local marks11 = vim.api.nvim_buf_get_extmarks(buf11, markdown.NS_MARKDOWN, 0, -1, { details = true })
local h_marks11 = {}
for _, em in ipairs(marks11) do
	if em[4].line_hl_group then
		table.insert(h_marks11, em)
	end
end
assert(#h_marks11 == 1, string.format("Expected exactly 1 heading extmark for '# Genuine Heading', got %d", #h_marks11))
assert(h_marks11[1][4].line_hl_group == "AgyH1", "Genuine heading must have AgyH1 highlight")
print("✓ Non-ATX headings correctly distinguished from genuine headings")

-- [Test 12] Scaled Header Highlight Definitions (font, bold, and fg)
print("\n[Test 12] Testing AgyH1..AgyH6 highlight definitions have font scale and fg...")

for i = 1, 6 do
	local hl = vim.api.nvim_get_hl(0, { name = "AgyH" .. i, link = false })
	assert(hl.font and hl.font:find(":scale="), string.format("AgyH%d must have font with :scale=", i))
	assert(hl.bold == true, string.format("AgyH%d must have bold = true", i))
	assert(hl.fg ~= nil, string.format("AgyH%d must define fg foreground color", i))
end
print("✓ AgyH1..AgyH6 font attributes and bold fg verified")

-- [Test 13] Kitty Graphics Protocol Chunking for Large Payloads
print("\n[Test 13] Testing Kitty graphics protocol chunking...")

local captured_seqs = {}
local orig_send = vim.api.nvim_ui_send
vim.api.nvim_ui_send = function(seq)
	table.insert(captured_seqs, seq)
end

-- Force raw Kitty path by disabling vim.ui.img.set temporarily
local orig_set = vim.ui and vim.ui.img and vim.ui.img.set
if vim.ui and vim.ui.img then vim.ui.img.set = nil end

local big_image_data = string.rep("X", 8000)
markdown.emit_kitty_image(big_image_data, 1, 1, 40, 10)

if vim.ui and vim.ui.img then vim.ui.img.set = orig_set end
vim.api.nvim_ui_send = orig_send

assert(#captured_seqs >= 2, "Images with payload > 4096 bytes must be chunked")
for idx, s in ipairs(captured_seqs) do
	assert(#s <= 4200, string.format("Chunk %d escape sequence length %d exceeds safe protocol limit", idx, #s))
	if idx < #captured_seqs then
		assert(s:find("m=1"), string.format("Intermediate chunk %d must have m=1", idx))
	else
		assert(s:find("m=0"), string.format("Final chunk %d must have m=0", idx))
	end
end
print("✓ Kitty graphics protocol 4096-byte chunking and m flag semantics verified")

-- [Test 14] Markdown Links & Inline Formatting Rendering
print("\n[Test 14] Testing markdown links & inline formatting...")

local inline_md = table.concat({
	"Here is **bold text** and __also bold__.",
	"Here is *italic text* and _also italic_.",
	"Here is `local x = 42` inline code.",
	"Here is ~~strikethrough text~~.",
	"Visit [Neovim](https://neovim.io) for modern editing.",
	"Preserve my_snake_case_var and 3 * 4 math expressions.",
	"- **Bold bullet**: with `code` and [link](https://example.com)",
}, "\n") .. "\n"

local buf14 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf14, cfg)
render.prepare_turn_submission(buf14, 3, nil, cfg)
render.append_text_delta(buf14, inline_md, cfg)
render.finalize_turn(buf14, nil, 2, { status = "DONE" }, cfg)

local lines14 = vim.api.nvim_buf_get_lines(buf14, 0, -1, false)
print("Rendered inline lines:")
for idx, l in ipairs(lines14) do
	print(string.format("  [%2d] %s", idx, l))
end

-- Verify stripped delimiters
assert(lines14[4]:find("bold text") and not lines14[4]:find("%*%*"), "Bold ** markers must be stripped: " .. lines14[4])
assert(lines14[4]:find("also bold") and not lines14[4]:find("__"), "Bold __ markers must be stripped: " .. lines14[4])
assert(lines14[5]:find("italic text") and not lines14[5]:find("%*italic"), "Italic * markers must be stripped: " .. lines14[5])
assert(lines14[6]:find("local x = 42") and not lines14[6]:find("`"), "Inline code backticks must be stripped: " .. lines14[6])
assert(lines14[7]:find("strikethrough text") and not lines14[7]:find("~~"), "Strikethrough ~~ markers must be stripped: " .. lines14[7])
assert(lines14[8]:find("Visit Neovim for modern editing.") and not lines14[8]:find("%(https://"), "Link url and brackets must be stripped: " .. lines14[8])
assert(lines14[9]:find("my_snake_case_var") and lines14[9]:find("3 %* 4"), "Snake case and math must be preserved: " .. lines14[9])
assert(lines14[10]:find("● Bold bullet: with code and link"), "List item inline formatting must be stripped: " .. lines14[10])

-- Verify inline extmarks
local marks14 = vim.api.nvim_buf_get_extmarks(buf14, markdown.NS_MARKDOWN, 0, -1, { details = true })
local found_bold = false
local found_italic = false
local found_code = false
local found_strike = false
local found_link = false
for _, em in ipairs(marks14) do
	local hl = em[4].hl_group
	if hl == "AgyBold" then found_bold = true end
	if hl == "AgyItalic" then found_italic = true end
	if hl == "AgyInlineCode" then found_code = true end
	if hl == "AgyStrike" then found_strike = true end
	if hl == "AgyLink" then found_link = true end
end
assert(found_bold, "AgyBold extmark must be applied")
assert(found_italic, "AgyItalic extmark must be applied")
assert(found_code, "AgyInlineCode extmark must be applied")
assert(found_strike, "AgyStrike extmark must be applied")
assert(found_link, "AgyLink extmark must be applied")
print("✓ Markdown links & inline formatting with stripped delimiters and highlights verified")

-- [Test 15] Table Wrapping & Column Allocation with Clamped Width
print("\n[Test 15] Testing table wrapping & column allocation with clamped width...")

local wide_table_md = table.concat({
	"| Option | Description | Default |",
	"| :--- | :--- | :---: |",
	"| enable_markdown | Controls whether rich markdown formatting and treesitter syntax highlighting are active in conversation buffers | true |",
	"| timeout_ms | Maximum time in milliseconds before timing out active background command | 5000 |",
}, "\n") .. "\n"

-- Test format_table with clamped width = 60
local t_icons_def = cfg.icons.table
local t_lines, t_exts = markdown.format_table(utils.split_lines(wide_table_md), t_icons_def, 60)
assert(t_lines ~= nil, "Table must format successfully with width budget")
print("Wrapped table lines (max_width = 60):")
local expected_len = vim.fn.strdisplaywidth(t_lines[1])
for idx, tl in ipairs(t_lines) do
	local w = vim.fn.strdisplaywidth(tl)
	print(string.format("  [%2d] (w=%2d) %s", idx, w, tl))
	assert(w <= 60, string.format("Line %d width %d exceeds max_width 60: %s", idx, w, tl))
	assert(w == expected_len, string.format("Line %d width %d must equal top border width %d", idx, w, expected_len))
end
assert(#t_lines > 6, "Wide cells must wrap into multiple rows")
print("✓ Table wrapping and vertical border alignment clamped to window width verified")

-- [Test 16] Treesitter Syntax Highlighting Highlight Group Links
print("\n[Test 16] Testing Treesitter syntax highlighting group links...")

local test_groups = {
	{ name = "@keyword.function", link = "Keyword" },
	{ name = "@keyword.return", link = "Keyword" },
	{ name = "@function.call", link = "Function" },
	{ name = "@punctuation.bracket", link = "Delimiter" },
	{ name = "@punctuation.delimiter", link = "Delimiter" },
	{ name = "AgyLink", link = "Underlined" },
	{ name = "AgyInlineCode", link = "String" },
}

for _, tg in ipairs(test_groups) do
	local hl = vim.api.nvim_get_hl(0, { name = tg.name })
	assert(hl and (hl.link == tg.link or hl.fg ~= nil or hl.underline or hl.bold),
		string.format("Highlight group '%s' must be defined and linked to '%s'", tg.name, tg.link))
end
print("✓ Treesitter syntax highlight links and markdown highlight definitions verified")

-- [Test 17] Table Cell Inline Formatting with Extmarks
print("\n[Test 17] Testing table cell inline formatting with extmarks...")

local table_with_inlines = table.concat({
	"| Command | Description | Link |",
	"| :--- | :--- | :--- |",
	"| `vim.cmd` | Run **Ex** commands | [API Docs](https://neovim.io/doc/user/api.html) |",
	"| `nvim_buf_set_lines` | Set buffer lines directly in memory | [Buffer API](https://neovim.io/doc/user/api.html#nvim_buf_set_lines) |",
}, "\n") .. "\n"

local t_lines17, t_exts17 = markdown.format_table(utils.split_lines(table_with_inlines), t_icons_def, 60)
assert(t_lines17 ~= nil, "Table with inlines must format successfully")

local found_code_em = false
local found_bold_em = false
local found_link_em = false
for _, em in ipairs(t_exts17) do
	local hl = em.opts and em.opts.hl_group
	local row_str = t_lines17[em.rel_row + 1] or ""
	local slice = row_str:sub(em.col + 1, em.opts.end_col)
	if hl == "AgyInlineCode" and slice == "vim.cmd" then
		found_code_em = true
		assert(em.opts.hl_mode == "combine", "AgyInlineCode must have hl_mode = combine")
	elseif hl == "AgyBold" and slice == "Ex" then
		found_bold_em = true
		assert(em.opts.hl_mode == "combine", "AgyBold must have hl_mode = combine")
	elseif hl == "AgyLink" and slice == "API Docs" then
		found_link_em = true
		assert(em.opts.hl_mode == "combine", "AgyLink must have hl_mode = combine")
	end
end

assert(found_code_em, "Table cell inline code extmark must be applied to slice 'vim.cmd'")
assert(found_bold_em, "Table cell bold extmark must be applied to slice 'Ex'")
assert(found_link_em, "Table cell link extmark must be applied to slice 'API Docs'")
print("✓ Table cell inline extmarks (code, bold, link) accurately applied and positioned")

-- [Test 18] Closed ATX Heading Stripping
print("\n[Test 18] Testing closed ATX heading stripping...")

local h_clean1, h_em1 = markdown.format_header("# Main Section #")
assert(h_clean1 == "Main Section", "Trailing # must be stripped: got '" .. tostring(h_clean1) .. "'")
assert(h_em1.opts.line_hl_group == "AgyH1", "Header level 1 line_hl_group verified")

local h_clean2, h_em2 = markdown.format_header("### Implementation Details ###")
assert(h_clean2 == "Implementation Details", "Trailing ### must be stripped: got '" .. tostring(h_clean2) .. "'")
assert(h_em2.opts.line_hl_group == "AgyH3", "Header level 3 line_hl_group verified")

local h_clean3, h_em3 = markdown.format_header("## C# Programming Language ##")
assert(h_clean3 == "C# Programming Language", "Internal C# hash must be preserved while trailing hashes stripped: got '" .. tostring(h_clean3) .. "'")
assert(h_em3.opts.line_hl_group == "AgyH2", "Header level 2 line_hl_group verified")
print("✓ Closed ATX heading stripping verified for trailing # sequences")

-- [Test 19] Balanced Bracket Links and Overlapping Inline Formats
print("\n[Test 19] Testing balanced bracket links and overlapping inline formats...")

local balanced_link = "Check [Documentation for [RFC 1234]](https://rfc-editor.org) for details."
local b_clean, b_inlines = markdown.parse_inline_formatting(balanced_link)
assert(b_clean == "Check Documentation for [RFC 1234] for details.", "Balanced brackets in link label must be supported: " .. b_clean)
assert(#b_inlines == 1 and b_inlines[1].hl_group == "AgyLink", "Link extmark must cover full label with balanced brackets")

local overlap_md = "Here is [**bold link**](https://example.com) test."
local o_clean, o_inlines = markdown.parse_inline_formatting(overlap_md)
assert(o_clean == "Here is bold link test.", "Delimiters stripped: " .. o_clean)
local has_link = false
local has_bold = false
for _, m in ipairs(o_inlines) do
	if m.hl_group == "AgyLink" then has_link = true end
	if m.hl_group == "AgyBold" then has_bold = true end
	assert(m.hl_mode == "combine", "Extmark must have hl_mode = combine for overlapping styles")
end
assert(has_link and has_bold, "Both AgyLink and AgyBold extmarks must be present on overlapping format")
print("✓ Balanced bracket links and overlapping inline formatting verified")

-- [Test 20] Narrow Window Width Clamping in Live Buffer Rendering
print("\n[Test 20] Testing narrow window width clamping in live buffer rendering...")

local buf20 = vim.api.nvim_create_buf(false, true)
local orig_cols = vim.o.columns
vim.o.columns = 50

local max_w50 = render.get_max_window_width(buf20)
assert(max_w50 <= 50, "get_max_window_width must not force 80-column floor: got " .. tostring(max_w50))

render.render_new_session(buf20, cfg)
render.prepare_turn_submission(buf20, 3, nil, cfg)
render.append_text_delta(buf20, wide_table_md, cfg)
render.finalize_turn(buf20, nil, 2, { status = "DONE" }, cfg)

local lines20 = vim.api.nvim_buf_get_lines(buf20, 0, -1, false)
for _, l in ipairs(lines20) do
	if l:find("╭") or l:find("│") or l:find("╰") then
		local w = vim.fn.strdisplaywidth(l)
		assert(w <= 50, string.format("Table line width %d exceeds window width 50: %s", w, l))
	end
end

vim.o.columns = orig_cols
print("✓ Narrow window width clamping in live buffer rendering verified")

-- [Test 21] Code Block Language + Icon Header, Full-Width Background, and No Border Lines
print("\n[Test 21] Testing code block language + icon header, full-width background, and no border lines...")

package.loaded["nvim-web-devicons"] = {
	get_icon_by_filetype = function(ft, opts)
		if ft == "lua" then return "", "DevIconLua" end
		if ft == "python" then return "", "DevIconPy" end
		return nil, nil
	end,
	get_icon = function(name, ext, opts)
		if ext == "lua" then return "", "DevIconLua" end
		return nil, nil
	end,
}

local cb_test_lines = { "local a = 10", "print(a)" }
local cb_lines, cb_exts = markdown.format_code_block(cb_test_lines, "lua")
assert(#cb_lines == 3, "Code block should have 3 lines: top language line and 2 body lines, got " .. #cb_lines)
assert(cb_lines[1] == " lua", "Line 1 must be ' lua' without borders: " .. cb_lines[1])
assert(cb_lines[2] == "local a = 10", "Line 2 must match body line 1 directly")
assert(cb_lines[3] == "print(a)", "Line 3 must match body line 2 directly")

for idx, l in ipairs(cb_lines) do
	assert(not l:find("╭") and not l:find("╰") and not l:find("─") and not l:find("│"),
		string.format("Line %d must not contain border characters: %s", idx, l))
end

local line_hl_count = 0
local found_dev_icon_hl = false
local found_code_lang_hl = false
local found_ts_token = false
for _, em in ipairs(cb_exts) do
	if em.opts and em.opts.line_hl_group == "AgyCodeBlock" then
		line_hl_count = line_hl_count + 1
		assert(em.opts.priority == 105, "AgyCodeBlock must have priority 105")
		assert(em.opts.hl_eol == true, "AgyCodeBlock must have hl_eol = true for full width")
	end
	if em.opts and em.opts.hl_group == "DevIconLua" then
		found_dev_icon_hl = true
		assert(em.opts.priority == 125, "DevIconLua must have priority 125")
	end
	if em.opts and em.opts.hl_group == "AgyCodeLang" then
		found_code_lang_hl = true
		assert(em.opts.priority == 120, "AgyCodeLang must have priority 120")
	end
	if em.opts and em.opts.hl_group and em.opts.hl_group:find("^@") then
		found_ts_token = true
		assert(em.opts.priority == 110, "Treesitter tokens must have priority 110")
	end
end
assert(line_hl_count == 3, "All 3 lines (top header + 2 code lines) must have full-width AgyCodeBlock highlight")
assert(found_dev_icon_hl, "DevIconLua highlight must be applied to icon on top line")
assert(found_code_lang_hl, "AgyCodeLang highlight must be applied to language name on top line")
assert(found_ts_token, "Treesitter token highlights must be applied to body lines")

package.loaded["nvim-web-devicons"] = nil
local no_dev_lines, _ = markdown.format_code_block(cb_test_lines, "lua")
assert(#no_dev_lines == 3, "Without devicons, should still have 3 lines (header + 2 body lines)")
assert(no_dev_lines[1] == "lua", "Line 1 without devicons must be 'lua': " .. no_dev_lines[1])

local no_lang_lines, no_lang_exts = markdown.format_code_block(cb_test_lines, "")
assert(#no_lang_lines == 2, "Without language, should only have the 2 body lines")
assert(no_lang_lines[1] == "local a = 10", "Line 1 should be code line directly")

print("✓ Code block language + icon header, full-width background, and no border lines verified")

-- [Test 22] markdown.get_link_at(buf, row, col)
print("\n[Test 22] Testing markdown.get_link_at(buf, row, col)...")

local link_test_md = "Visit [Neovim](https://neovim.io) or [GitHub](https://github.com) today."
local buf22 = vim.api.nvim_create_buf(false, true)
render.render_new_session(buf22, cfg)
render.prepare_turn_submission(buf22, 3, nil, cfg)
render.append_text_delta(buf22, link_test_md .. "\n", cfg)
render.finalize_turn(buf22, nil, 2, { status = "DONE" }, cfg)

local b22_lines = vim.api.nvim_buf_get_lines(buf22, 0, -1, false)
print("Buffer 22 rendered lines:")
local target_line_idx = nil
for idx, l in ipairs(b22_lines) do
	print(string.format("  [%d] %s", idx, l))
	if l:find("Visit Neovim or GitHub today.") then
		target_line_idx = idx
	end
end
assert(target_line_idx ~= nil, "Rendered link line must exist in buffer")

local rendered_line = b22_lines[target_line_idx]
local neo_start = rendered_line:find("Neovim") - 1
local neo_end = neo_start + #"Neovim"
local git_start = rendered_line:find("GitHub") - 1

local l_start = markdown.get_link_at(buf22, target_line_idx, neo_start)
assert(l_start ~= nil, "Should find link at start of 'Neovim'")
assert(l_start.url == "https://neovim.io", "Expected https://neovim.io, got " .. tostring(l_start.url))

local l_mid = markdown.get_link_at(buf22, target_line_idx, neo_start + 2)
assert(l_mid ~= nil and l_mid.url == "https://neovim.io", "Should find link in middle of 'Neovim'")

local l_last_char = markdown.get_link_at(buf22, target_line_idx, neo_end - 1)
assert(l_last_char ~= nil and l_last_char.url == "https://neovim.io", "Should find link at last char of 'Neovim'")

local l_before = markdown.get_link_at(buf22, target_line_idx, neo_start - 1)
assert(l_before == nil, "Should return nil before link")

local l_after = markdown.get_link_at(buf22, target_line_idx, neo_end)
assert(l_after == nil, "Should return nil on space after link")

local l_git = markdown.get_link_at(buf22, target_line_idx, git_start)
assert(l_git ~= nil and l_git.url == "https://github.com", "Should find GitHub link")

-- Ensure cursor on adjacent rows does NOT match link (prevent off-by-one / 0-indexed ambiguity)
local l_prev_row = markdown.get_link_at(buf22, target_line_idx - 1, neo_start)
assert(l_prev_row == nil, "Cursor on previous line must NOT match link on target line")

local l_next_row = markdown.get_link_at(buf22, target_line_idx + 1, neo_start)
assert(l_next_row == nil, "Cursor on next line must NOT match link on target line")

-- Test angle brackets and unescaped spaces in links
local space_md = "Check [spaced](<file:///C:/path/with spaces/file.lua>) and [quoted](https://example.com \"Title\")."
local _, _, parsed_space_links = markdown.transform_markdown(space_md, true, cfg)
assert(#parsed_space_links == 2, "Expected 2 links parsed")
assert(parsed_space_links[1].url == "file:///C:/path/with spaces/file.lua", "Angle bracket url: " .. tostring(parsed_space_links[1].url))
assert(parsed_space_links[2].url == "https://example.com", "Quoted title stripped: " .. tostring(parsed_space_links[2].url))

print("✓ markdown.get_link_at accurately detects link boundaries and returns URL")

-- [Test 23] K Link Hover / Inspection (LSP Floating Preview)
print("\n[Test 23] Testing K link hover / inspection (LSP floating preview)...")

local protocol = require("agy.protocol")
protocol._setup_buffer(buf22, "test-conv-23")

local win23 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win23, buf22)
vim.api.nvim_win_set_cursor(win23, { target_line_idx, neo_start })

local hover_win, hover_buf = markdown.show_link_hover(buf22, l_start, cfg)
assert(vim.api.nvim_win_is_valid(hover_win), "Hover float window must be valid")
local hover_lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)
assert(#hover_lines == 1, "Hover buffer must contain 1 line")
assert(hover_lines[1]:find("https://neovim.io"), "Hover line must contain link URL: " .. hover_lines[1])
assert(hover_lines[1]:find("🔗"), "Hover line must contain link icon 🔗: " .. hover_lines[1])

-- Verify second press of K focuses into the LSP preview window (standard LSP behavior)
local hover_win2, hover_buf2 = markdown.show_link_hover(buf22, l_start, cfg)
assert(hover_win2 == hover_win, "Second hover call should target the active hover window")
assert(vim.api.nvim_get_current_win() == hover_win, "Second hover call should focus the floating window")

-- Verify 'q' closes the focused hover window (standard LSP behavior)
vim.cmd("normal q")
vim.wait(100, function() return not vim.api.nvim_win_is_valid(hover_win) end)
assert(not vim.api.nvim_win_is_valid(hover_win), "Pressing 'q' inside hover window must close it")

-- Return to parent window and open hover again to test cursor move auto-dismiss
vim.api.nvim_set_current_win(win23)
local hover_win3, hover_buf3 = markdown.show_link_hover(buf22, l_start, cfg)
assert(vim.api.nvim_win_is_valid(hover_win3), "Third hover window must be valid")
assert(vim.wo[hover_win3].wrap == true, "Hover window must have wrap enabled")

-- Moving cursor in parent window auto-closes the LSP preview window
vim.api.nvim_win_set_cursor(win23, { target_line_idx, neo_start + 1 })
vim.cmd("doautocmd CursorMoved")
vim.wait(100, function() return not vim.api.nvim_win_is_valid(hover_win3) end)
assert(not vim.api.nvim_win_is_valid(hover_win3), "Hover window must close on CursorMoved")
print("✓ K link hover operates via vim.lsp.util.open_floating_preview with focus, q-dismiss, and auto-close")

-- [Test 24] gd Link Open (file:// and Web Links)
print("\n[Test 24] Testing gd link open (file:// and web links)...")

local p1, l1, c1 = markdown.parse_file_url("file:///path/to/script.lua#L42")
assert(p1:match("path/to/script.lua$"), "Parsed path: " .. tostring(p1))
assert(l1 == 42, "Parsed line: " .. tostring(l1))
assert(c1 == nil, "Parsed col: " .. tostring(c1))

local p2, l2, c2 = markdown.parse_file_url("file:///path/to/script.lua#L42-L50")
assert(l2 == 42 and c2 == nil, "Range line: " .. tostring(l2))

local p3, l3, c3 = markdown.parse_file_url("file:///path/to/script.lua#L42:15")
assert(l3 == 42 and c3 == 15, "Line and col: " .. tostring(l3) .. ":" .. tostring(c3))

local p4, l4, c4 = markdown.parse_file_url("file:///path/to/script.lua:100:25")
assert(l4 == 100 and c4 == 25, "Colon line and col: " .. tostring(l4) .. ":" .. tostring(c4))

-- Test percent-encoded file URL decoding
local p_enc, l_enc, c_enc = markdown.parse_file_url("file:///C:/Users/test/My%20Documents/script.lua#L15:4")
assert(p_enc:find("My Documents/script.lua$"), "Decoded path with space: " .. tostring(p_enc))
assert(l_enc == 15 and c_enc == 4, "Line and col from percent-encoded URL: " .. tostring(l_enc) .. ":" .. tostring(c_enc))

-- Test numeric fragment without 'L'
local p_num, l_num, c_num = markdown.parse_file_url("file:///path/to/script.lua#42:10")
assert(l_num == 42 and c_num == 10, "Numeric fragment without 'L': " .. tostring(l_num) .. ":" .. tostring(c_num))

-- Test Windows drive letter not confused with line number
local p_win, l_win, c_win = markdown.parse_file_url("file:///C:/path/script.lua:42:10")
assert(p_win:find("^C:/path/script.lua"), "Windows path parsed: " .. tostring(p_win))
assert(l_win == 42 and c_win == 10, "Windows line and col: " .. tostring(l_win) .. ":" .. tostring(c_win))

local temp_test_file = vim.fs.normalize(vim.fn.tempname() .. ".lua")
local f = io.open(temp_test_file, "w")
assert(f, "Failed to create temp test file")
for line_i = 1, 50 do
	f:write(string.format("local line_%d = %d\n", line_i, line_i))
end
f:close()

local file_url = "file:///" .. temp_test_file:gsub("^/+", "") .. "#L30:8"
local opened = markdown.open_link(file_url)
assert(opened == true, "open_link must return true for file:// URL")

local cur_file_buf = vim.api.nvim_get_current_buf()
local cur_buf_name = vim.fs.normalize(vim.api.nvim_buf_get_name(cur_file_buf))
assert(cur_buf_name == temp_test_file, "Active buffer must be the opened file: " .. cur_buf_name .. " vs " .. temp_test_file)

local cur_pos = vim.api.nvim_win_get_cursor(0)
assert(cur_pos[1] == 30, "Cursor must be positioned at line 30, got " .. cur_pos[1])
assert(cur_pos[2] == 7, "Cursor must be positioned at col 7 (0-indexed 8), got " .. cur_pos[2])

os.remove(temp_test_file)

local captured_web_url = nil
local orig_ui_open = vim.ui and vim.ui.open
vim.ui.open = function(url)
	captured_web_url = url
	return true
end

local web_opened = markdown.open_link("https://neovim.io")
assert(web_opened == true, "open_link must return true for web URL")
assert(captured_web_url == "https://neovim.io", "vim.ui.open must be invoked with web URL")

if vim.ui then vim.ui.open = orig_ui_open end
print("✓ gd link open handles file:// paths (with line/col) and external web URLs")

-- [Test 25] wrap = true Default Option
print("\n[Test 25] Testing wrap = true default option...")

local default_cfg = config_mod.get()
assert(default_cfg.ui.wrap == true, "config.defaults.ui.wrap must be true by default")

local buf25 = vim.api.nvim_create_buf(false, true)
local win25 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win25, buf25)
protocol._setup_buffer(buf25, "wrap-test-conv")

assert(vim.wo[win25].wrap == true, "Window displaying agy buffer must have wrap = true")
assert(vim.wo[win25].linebreak == true, "Window displaying agy buffer must have linebreak = true")

print("✓ wrap = true default and buffer/window configuration verified")

-- Reset config back to clean defaults
config_mod.setup()

print("\nALL STREAM MARKDOWN RENDERING TESTS PASSED PERFECTLY!")
