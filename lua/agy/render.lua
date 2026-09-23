local utils = require("agy.utils")

local M = {}

M.NS_UI = vim.api.nvim_create_namespace("agy_ui")
M.NS_HISTORY = vim.api.nvim_create_namespace("agy_history")
M.NS_PROMPT = vim.api.nvim_create_namespace("agy_prompt")
M.NS_SPACER = vim.api.nvim_create_namespace("agy_tool_spacer")
M.NS_QUEUE = vim.api.nvim_create_namespace("agy_queue")
M.NS_LOGO = vim.api.nvim_create_namespace("agy_logo")
M.active_logo_buffers = {}
M.logo_timer = nil
M.logo_animation_angle = 0

---Inverted 10x12 pixel grid colors from native agy CLI logo
local LOGO_PIXELS = {
	[1] = { [1] = "#67B9F4", [2] = "#64B6F6", [11] = "#3883F9", [12] = "#3D85FC" },
	[2] = { [2] = "#6BC7A3", [3] = "#64B6F6", [10] = "#3886FB", [11] = "#4881F4" },
	[3] = { [2] = "#6DC694", [3] = "#62BAD5", [4] = "#47A8DC", [9] = "#3D89FB", [10] = "#4A81F0", [11] = "#6579E1" },
	[4] = { [3] = "#61C37D", [4] = "#43AEAB", [9] = "#4A80EA", [10] = "#6C73D8" },
	[5] = { [3] = "#80C654", [4] = "#54B881", [5] = "#4097DE", [8] = "#4A7EE4", [9] = "#706ECE", [10] = "#8F64B4" },
	[6] = { [3] = "#7CC251", [4] = "#71C25C", [5] = "#5CA98F", [6] = "#5C91B3", [7] = "#8373B0", [8] = "#746FC3", [9] = "#995DA8", [10] = "#9C5B97" },
	[7] = { [4] = "#86C64E", [5] = "#75B45E", [6] = "#CC954D", [7] = "#EF7947", [8] = "#E16652", [9] = "#E14F59" },
	[8] = { [4] = "#9EC345", [5] = "#B5B43E", [6] = "#E2993D", [7] = "#F67A34", [8] = "#F86A35", [9] = "#EF5442" },
	[9] = { [5] = "#DBB131", [6] = "#F6912E", [7] = "#F37337", [8] = "#F0583B" },
	[10] = { [6] = "#F2922E", [7] = "#F07236" },
}

local function rgb_to_hsv(r, g, b)
	local max = math.max(r, g, b)
	local min = math.min(r, g, b)
	local delta = max - min
	local h, s, v = 0, 0, max

	s = (max == 0) and 0 or (delta / max)

	if delta ~= 0 then
		if max == r then
			h = ((g - b) / delta) % 6
		elseif max == g then
			h = (b - r) / delta + 2
		else
			h = (r - g) / delta + 4
		end
		h = h * 60
		if h < 0 then
			h = h + 360
		end
	end
	return h, s, v
end

local function hsv_to_rgb(h, s, v)
	local c = v * s
	local x = c * (1 - math.abs((h / 60) % 2 - 1))
	local m = v - c
	local r, g, b = 0, 0, 0

	if h < 60 then
		r, g, b = c, x, 0
	elseif h < 120 then
		r, g, b = x, c, 0
	elseif h < 180 then
		r, g, b = 0, c, x
	elseif h < 240 then
		r, g, b = 0, x, c
	elseif h < 300 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end

	return math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5)
end

local function hex_to_rgb(hex)
	hex = hex:gsub("#", "")
	local num = tonumber(hex, 16)
	if not num then
		return 0, 0, 0
	end
	return math.floor(num / 65536) / 255, math.floor((num % 65536) / 256) / 255, (num % 256) / 255
end

local function shift_color_hue(hex, deg)
	if not hex then
		return nil
	end
	local r, g, b = hex_to_rgb(hex)
	local h, s, v = rgb_to_hsv(r, g, b)
	local new_h = (h + deg) % 360
	local nr, ng, nb = hsv_to_rgb(new_h, s, v)
	return string.format("#%02x%02x%02x", nr, ng, nb)
end

local function get_config(cfg)
	return cfg or require("agy.config").get()
end

local function get_icons(cfg)
	local c = get_config(cfg)
	assert(c, "agy config: configuration is required")
	assert(type(c.icons) == "table", "agy config: 'icons' table is required")
	return c.icons
end

local function get_icon(name, cfg)
	local icons = get_icons(cfg)
	local icon = icons[name]
	assert(icon, string.format("agy config: icon '%s' is not defined in config.icons", name))
	return icon
end

local function get_tool_icon(tool_name, cfg)
	local icons = get_icons(cfg)
	local icon = icons[tool_name] or icons.tool or icons.default
	assert(icon, string.format("agy config: no icon found for tool '%s'", tool_name))
	return icon
end

local function get_spinner_frames(cfg)
	local icons = get_icons(cfg)
	local spinner = icons.spinner
	assert(
		spinner and type(spinner) == "table" and #spinner > 0,
		"agy config: icon 'spinner' is not defined in config.icons"
	)
	return spinner
end

local function get_block_icons(cfg)
	local icons = get_icons(cfg)
	local upper = icons.upper_block
	local lower = icons.lower_block
	assert(upper, "agy config: 'upper_block' icon is not defined in config.icons")
	assert(lower, "agy config: 'lower_block' icon is not defined in config.icons")
	return upper, lower
end

local function get_logo_row_info(r, cfg)
	local upper, lower = get_block_icons(cfg)
	local top_row = LOGO_PIXELS[r * 2 + 1] or {}
	local bot_row = LOGO_PIXELS[r * 2 + 2] or {}
	local parts = {}
	local cells = {}
	local left_pad = "  "
	table.insert(parts, left_pad)
	local byte_offset = #left_pad

	for c = 1, 12 do
		local top_c = top_row[c]
		local bot_c = bot_row[c]
		local ch, fg, bg
		if not top_c and not bot_c then
			ch = " "
			fg = nil
			bg = nil
		elseif top_c and not bot_c then
			ch = upper
			fg = top_c
			bg = nil
		elseif not top_c and bot_c then
			ch = lower
			fg = bot_c
			bg = nil
		else
			ch = upper
			fg = top_c
			bg = bot_c
		end

		table.insert(parts, ch)
		local ch_len = #ch
		if fg or bg then
			table.insert(cells, {
				row = r,
				col = c,
				char = ch,
				byte_start = byte_offset,
				byte_end = byte_offset + ch_len,
				fg = fg,
				bg = bg,
				hl_group = string.format("AgyLogo_%d_%d", r, c),
			})
		end
		byte_offset = byte_offset + ch_len
	end

	return table.concat(parts), cells
end


---Setup highlight groups for agy buffers
function M.setup_highlights()
	local title_hl = vim.api.nvim_get_hl(0, { name = "Title", link = false })
	local header_fg = (title_hl and title_hl.fg) or ((vim.o.background == "light") and 0x0055aa or 0x89b4fa)

	local defs = {
		AgyUserDivider = { link = "Title", default = true, bold = true },
		AgyAgentDivider = { link = "Special", default = true, bold = true },
		AgyDividerLine = { link = "NonText", default = true },
		AgyPromptArea = { link = "CursorLine", default = true },
		AgyPromptBorder = { link = "AgyPromptArea", default = true },
		AgyPromptSign = { link = "AgyPromptArea", default = true },
		AgyHistory = { default = true },
		AgyToolHeader = { link = "Function", default = true, bold = true },
		AgyToolBadge = { link = "Comment", default = true },
		AgyTaskRunning = { link = "DiagnosticWarn", default = true, bold = true },
		AgyTaskSuccess = { link = "DiagnosticOk", default = true, bold = true },
		AgyTaskFailed = { link = "DiagnosticError", default = true, bold = true },
		AgyTaskBadgeRunning = { link = "DiagnosticWarn", default = true },
		AgyTaskBadgeSuccess = { link = "DiagnosticOk", default = true },
		AgyTaskBadgeFailed = { link = "DiagnosticError", default = true },
		AgyBadgeActive = { link = "DiagnosticWarn", default = true },
		AgyBadgeDone = { link = "DiagnosticOk", default = true },
		AgyBadgeError = { link = "DiagnosticError", default = true },
		AgyPromptFooter = { link = "Comment", default = true },
		AgySlashCommand = { link = "Keyword", default = true, bold = true },
		AgyMention = { link = "Special", default = true, bold = true },
		AgyQuestionHeader = { link = "Title", default = true, bold = true },
		AgyQuestionOption = { link = "Normal", default = true },
		AgyQuestionChecked = { link = "DiagnosticOk", default = true, bold = true },
		AgyThought = { link = "Comment", default = true, italic = true },
		AgyCompletionSel = { link = "PmenuSel", default = true },
		AgyCompletionPointer = { link = "Special", default = true, bold = true },
		AgyCompletionLabel = { link = "Keyword", default = true },
		AgyCompletionKind = { link = "Type", default = true },
		AgyCompletionDetail = { link = "Comment", default = true },
		AgyCompletionMore = { link = "Comment", default = true, italic = true },
		AgyCompletionFooter = { link = "Comment", default = true },
		AgyCompletionKey = { link = "Special", default = true, bold = true },
		AgyQueueHeader = { link = "Title", default = true, bold = true },
		AgyQueueBadge = { link = "DiagnosticInfo", default = true },
		AgyQueueMessage = { link = "Normal", default = true },
		AgyReviewComment = { link = "DiagnosticInfo", default = true, italic = true },
		AgyHeaderTitle = { bold = true, fg = "#7aa2f7", default = true },
		AgyHeaderSub = { fg = "#787c99", default = true },
		AgyH1 = { font = ":scale=2.0:margin_top=0.8:margin_bottom=0.4", bold = true, fg = header_fg, default = true },
		AgyH2 = { font = ":scale=1.6:margin_top=0.6:margin_bottom=0.3", bold = true, fg = header_fg, default = true },
		AgyH3 = { font = ":scale=1.35:margin_top=0.5:margin_bottom=0.25", bold = true, fg = header_fg, default = true },
		AgyH4 = { font = ":scale=1.2:margin_top=0.4:margin_bottom=0.2", bold = true, fg = header_fg, default = true },
		AgyH5 = { font = ":scale=1.1:margin_top=0.3:margin_bottom=0.15", bold = true, fg = header_fg, default = true },
		AgyH6 = { font = ":scale=1.0:margin_top=0.2:margin_bottom=0.1", bold = true, fg = header_fg, default = true },
		AgyTableBorder = { link = "Comment", default = true },
		AgyTableHeader = { link = "Title", bold = true, default = true },
		AgyCodeBorder = { link = "Comment", default = true },
		AgyCodeLang = { link = "Special", bold = true, default = true },
		AgyListBullet = { link = "Special", default = true },
		AgyCheckboxUnchecked = { link = "Comment", default = true },
		AgyCheckboxChecked = { link = "DiagnosticOk", bold = true, default = true },
		AgyImage = { link = "Special", default = true },
		AgyLink = { link = "Underlined", underline = true, default = true },
		AgyBold = { bold = true, default = true },
		AgyItalic = { italic = true, default = true },
		AgyInlineCode = { link = "String", default = true },
		AgyStrike = { strikethrough = true, default = true },

		-- Treesitter syntax highlighting mappings for code blocks
		["@keyword"] = { link = "Keyword", default = true },
		["@keyword.function"] = { link = "Keyword", default = true },
		["@keyword.return"] = { link = "Keyword", default = true },
		["@keyword.operator"] = { link = "Operator", default = true },
		["@keyword.import"] = { link = "Include", default = true },
		["@keyword.conditional"] = { link = "Conditional", default = true },
		["@keyword.repeat"] = { link = "Repeat", default = true },
		["@keyword.exception"] = { link = "Exception", default = true },
		["@keyword.type"] = { link = "Type", default = true },
		["@keyword.modifier"] = { link = "Type", default = true },
		["@keyword.coroutine"] = { link = "Keyword", default = true },
		["@function"] = { link = "Function", default = true },
		["@function.builtin"] = { link = "Special", default = true },
		["@function.call"] = { link = "Function", default = true },
		["@function.macro"] = { link = "Macro", default = true },
		["@function.method"] = { link = "Function", default = true },
		["@function.method.call"] = { link = "Function", default = true },
		["@method"] = { link = "Function", default = true },
		["@method.call"] = { link = "Function", default = true },
		["@variable"] = { link = "Identifier", default = true },
		["@variable.builtin"] = { link = "Special", default = true },
		["@variable.parameter"] = { link = "Identifier", default = true },
		["@variable.member"] = { link = "Identifier", default = true },
		["@property"] = { link = "Identifier", default = true },
		["@field"] = { link = "Identifier", default = true },
		["@type"] = { link = "Type", default = true },
		["@type.builtin"] = { link = "Type", default = true },
		["@type.definition"] = { link = "Typedef", default = true },
		["@type.qualifier"] = { link = "Type", default = true },
		["@string"] = { link = "String", default = true },
		["@string.regex"] = { link = "Special", default = true },
		["@string.escape"] = { link = "Special", default = true },
		["@string.special"] = { link = "Special", default = true },
		["@string.documentation"] = { link = "Comment", default = true },
		["@character"] = { link = "Character", default = true },
		["@character.special"] = { link = "SpecialChar", default = true },
		["@number"] = { link = "Number", default = true },
		["@number.float"] = { link = "Float", default = true },
		["@boolean"] = { link = "Boolean", default = true },
		["@constant"] = { link = "Constant", default = true },
		["@constant.builtin"] = { link = "Special", default = true },
		["@constant.macro"] = { link = "Define", default = true },
		["@comment"] = { link = "Comment", default = true },
		["@comment.documentation"] = { link = "Comment", default = true },
		["@comment.note"] = { link = "SpecialComment", default = true },
		["@comment.warning"] = { link = "DiagnosticWarn", default = true },
		["@comment.error"] = { link = "DiagnosticError", default = true },
		["@operator"] = { link = "Operator", default = true },
		["@punctuation.bracket"] = { link = "Delimiter", default = true },
		["@punctuation.delimiter"] = { link = "Delimiter", default = true },
		["@punctuation.special"] = { link = "Delimiter", default = true },
		["@tag"] = { link = "Tag", default = true },
		["@tag.attribute"] = { link = "Identifier", default = true },
		["@tag.delimiter"] = { link = "Delimiter", default = true },
		["@constructor"] = { link = "Special", default = true },
		["@label"] = { link = "Label", default = true },
		["@module"] = { link = "Structure", default = true },
		["@namespace"] = { link = "Structure", default = true },
		["@keyword.storage"] = { link = "StorageClass", default = true },
	}

	for name, val in pairs(defs) do
		vim.api.nvim_set_hl(0, name, val)
	end

	M.reset_logo_highlights()

	-- Resolve prompt background color
	local prompt_hl = vim.api.nvim_get_hl(0, { name = "AgyPromptArea", link = false })
	if not prompt_hl or not prompt_hl.bg then
		prompt_hl = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
	end
	if not prompt_hl or not prompt_hl.bg then
		prompt_hl = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
	end

	local prompt_bg = prompt_hl and prompt_hl.bg
	if not prompt_bg then
		prompt_bg = (vim.o.background == "light") and 0xeeeeee or 0x2a2b3d
	end

	-- If AgyPromptArea itself has no bg (e.g. CursorLine has no bg), set default bg on AgyPromptArea
	local cur_prompt_area = vim.api.nvim_get_hl(0, { name = "AgyPromptArea", link = false })
	if not cur_prompt_area or not cur_prompt_area.bg then
		vim.api.nvim_set_hl(0, "AgyPromptArea", { bg = prompt_bg, default = true })
	end

	-- Resolve tool inline and code block subtle background color
	local inline_hl = vim.api.nvim_get_hl(0, { name = "AgyToolInline", link = false })
	if not inline_hl or not inline_hl.bg then
		inline_hl = vim.api.nvim_get_hl(0, { name = "ColorColumn", link = false })
	end
	if not inline_hl or not inline_hl.bg then
		inline_hl = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
	end

	local norm_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local norm_bg = norm_hl and norm_hl.bg

	local inline_bg = inline_hl and inline_hl.bg

	-- Ensure inline_bg has visible subtle contrast against Normal background
	local function is_close_color(c1, c2, threshold)
		if not c1 or not c2 then
			return false
		end
		local r1 = math.floor(c1 / 65536) % 256
		local g1 = math.floor(c1 / 256) % 256
		local b1 = c1 % 256
		local r2 = math.floor(c2 / 65536) % 256
		local g2 = math.floor(c2 / 256) % 256
		local b2 = c2 % 256
		return math.abs(r1 - r2) <= threshold and math.abs(g1 - g2) <= threshold and math.abs(b1 - b2) <= threshold
	end

	if not inline_bg or is_close_color(inline_bg, norm_bg, 8) then
		if vim.o.background == "light" then
			if norm_bg then
				local r = math.max(0, math.floor(norm_bg / 65536) % 256 - 16)
				local g = math.max(0, math.floor(norm_bg / 256) % 256 - 16)
				local b = math.max(0, (norm_bg % 256) - 16)
				inline_bg = r * 65536 + g * 256 + b
			else
				inline_bg = 0xebebee
			end
		else
			if norm_bg then
				local r = math.min(255, math.floor(norm_bg / 65536) % 256 + 18)
				local g = math.min(255, math.floor(norm_bg / 256) % 256 + 20)
				local b = math.min(255, (norm_bg % 256) + 24)
				inline_bg = r * 65536 + g * 256 + b
			else
				inline_bg = 0x262b3d
			end
		end
	end

	local cur_tool_inline = vim.api.nvim_get_hl(0, { name = "AgyToolInline", link = false })
	if not cur_tool_inline or not cur_tool_inline.bg then
		vim.api.nvim_set_hl(0, "AgyToolInline", {
			bg = inline_bg,
			ctermbg = (vim.o.background == "light") and 254 or 236,
			default = true,
		})
	end

	local cur_code_block = vim.api.nvim_get_hl(0, { name = "AgyCodeBlock", link = false })
	if vim.tbl_isempty(cur_code_block) or cur_code_block.default or not cur_code_block.bg then
		if cur_code_block and cur_code_block.default then
			vim.api.nvim_set_hl(0, "AgyCodeBlock", {})
		end
		vim.api.nvim_set_hl(0, "AgyCodeBlock", {
			bg = inline_bg,
			ctermbg = (vim.o.background == "light") and 254 or 236,
			default = true,
		})
	end

	local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
	local cur_tool_output = vim.api.nvim_get_hl(0, { name = "AgyToolOutput", link = false })
	if not cur_tool_output or not cur_tool_output.bg then
		local tool_out_def = { bg = inline_bg, default = true }
		if comment_hl and comment_hl.fg then
			tool_out_def.fg = comment_hl.fg
		end
		vim.api.nvim_set_hl(0, "AgyToolOutput", tool_out_def)
	end

	local cur_thought_output = vim.api.nvim_get_hl(0, { name = "AgyThoughtOutput", link = false })
	if not cur_thought_output or not cur_thought_output.bg then
		local thought_out_def = { bg = inline_bg, italic = true, default = true }
		if comment_hl and comment_hl.fg then
			thought_out_def.fg = comment_hl.fg
		end
		vim.api.nvim_set_hl(0, "AgyThoughtOutput", thought_out_def)
	end

	-- Set up AgyUserSign with fg from Special and bg matching the prompt background
	local existing_sign = vim.api.nvim_get_hl(0, { name = "AgyUserSign" })
	if vim.tbl_isempty(existing_sign) or existing_sign.default then
		local special_hl = vim.api.nvim_get_hl(0, { name = "Special", link = false })
		local user_sign_def = {
			bold = true,
			default = true,
			bg = prompt_bg,
		}
		if special_hl and special_hl.fg then
			user_sign_def.fg = special_hl.fg
		else
			user_sign_def.fg = (vim.o.background == "light") and 0x0055aa or 0x89b4fa
		end

		if existing_sign.default then
			vim.api.nvim_set_hl(0, "AgyUserSign", {})
		end
		vim.api.nvim_set_hl(0, "AgyUserSign", user_sign_def)
	end
end

---Format tool call parameters compactly for inline preview
---@param params? table
---@param cwd? string|string[]
---@return string
function M.format_tool_params(params, cwd)
	if not params or type(params) ~= "table" then
		return ""
	end

	cwd = cwd or vim.fn.getcwd()

	local primary = params.CommandLine
		or params.query
		or params.TargetFile
		or params.AbsolutePath
		or params.Url
		or params.Message
		or params.path
	if primary then
		local s = utils.shorten_path(tostring(primary), cwd):gsub("\r?\n", " ")
		if #s > 60 then
			return s:sub(1, 57) .. "..."
		end
		return s
	end

	for k, v in pairs(params) do
		if type(v) == "string" then
			local s = utils.shorten_path(v, cwd):gsub("\r?\n", " ")
			if #s > 40 then
				s = s:sub(1, 37) .. "..."
			end
			return string.format("%s: %s", k, s)
		end
	end

	return ""
end

---Detect language for tool output code block to enable Tree-sitter highlighting
---@param tool_name string
---@param params? table
---@param output? string
---@return string lang (empty string if unknown)
function M.detect_codeblock_lang(tool_name, params, output)
	params = params or {}
	output = output or ""

	-- 1. Check file path from parameters using Neovim's builtin filetype detection
	local file_path = params.TargetFile or params.AbsolutePath or params.path or params.file
	if file_path and type(file_path) == "string" and file_path ~= "" then
		local ft = vim.filetype.match({ filename = file_path })
		if ft and ft ~= "" then
			return ft
		end
	end

	-- 2. Check tool-specific patterns
	if tool_name == "read_url_content" then
		return "markdown"
	end

	if tool_name == "run_command" and params.CommandLine then
		local cmd = tostring(params.CommandLine):lower()
		if cmd:match("^git%s+diff") or cmd:match("%|%s*git%s+diff") then
			return "diff"
		end
	end

	-- 3. Check output characteristics
	if output ~= "" then
		if
			output:match("^diff %-%-git")
			or output:match("^%-%-%- %S+[\r\n]%+%+%+ %S+")
			or output:match("@@ %-%d+,%d+ %+%d+,%d+ @@")
		then
			return "diff"
		end
		local trimmed = utils.trim(output)
		if
			(trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}")
			or (trimmed:sub(1, 1) == "[" and trimmed:sub(-1) == "]")
		then
			local ok, _ = utils.json_decode(trimmed)
			if ok then
				return "json"
			end
		end
	end

	return ""
end

---Trim leading and trailing empty lines from an array of strings
---@param lines string[]
---@return string[]
function M.trim_empty_lines(lines)
	if not lines or #lines == 0 then
		return {}
	end
	local first = 1
	while first <= #lines and utils.trim(lines[first]) == "" do
		first = first + 1
	end
	local last = #lines
	while last >= first and utils.trim(lines[last]) == "" do
		last = last - 1
	end
	local trimmed = {}
	for i = first, last do
		table.insert(trimmed, lines[i])
	end
	return trimmed
end

---Ensure that trailing virtual lines below the bottom buffer line are visible in the window viewport
---@param win number
---@param buf number
function M.ensure_bottom_visible(win, buf)
	if not win or win == -1 then
		win = vim.api.nvim_get_current_win()
	end
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_win_get_buf(win)
	end
	if vim.api.nvim_win_get_buf(win) ~= buf then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local cur = vim.api.nvim_win_get_cursor(win)
	local cur_line = cur[1]
	if cur_line < line_count then
		return
	end

	local protocol = package.loaded["agy.protocol"]
	local state = protocol and protocol.buffers and protocol.buffers[buf]
	local virt_lines_count = 0

	if state and state.footer_extmark_id then
		local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, state.footer_extmark_id, { details = true })
		if mark and mark[3] and mark[3].virt_lines then
			virt_lines_count = #mark[3].virt_lines
		end
	end

	if virt_lines_count == 0 then
		local marks = vim.api.nvim_buf_get_extmarks(
			buf,
			M.NS_UI,
			{ line_count - 1, 0 },
			{ line_count - 1, -1 },
			{ details = true }
		)
		for _, m in ipairs(marks) do
			if m[4] and m[4].virt_lines and m[4].virt_lines_above == false then
				virt_lines_count = math.max(virt_lines_count, #m[4].virt_lines)
			end
		end
	end

	if virt_lines_count == 0 then
		return
	end

	pcall(vim.api.nvim_win_call, win, function()
		local win_height = vim.api.nvim_win_get_height(win)

		local function get_last_screen_row()
			local wl = vim.fn.winline()
			if not vim.wo[win].wrap then
				return wl
			end
			local last_line_str = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
			if last_line_str == "" then
				return wl
			end
			local win_top_row = vim.fn.win_screenpos(win)[1]
			local pos_end = vim.fn.screenpos(win, line_count, #last_line_str)
			if pos_end and pos_end.row and pos_end.row > 0 then
				return pos_end.row - win_top_row + 1
			else
				return win_height + 1
			end
		end

		local last_virtual_row = get_last_screen_row() + virt_lines_count
		if last_virtual_row > win_height then
			local view = vim.fn.winsaveview()
			while last_virtual_row > win_height and view.topline < cur_line do
				view.topline = view.topline + 1
				vim.fn.winrestview(view)
				last_virtual_row = get_last_screen_row() + virt_lines_count
				view = vim.fn.winsaveview()
			end
		end
	end)
end

---Scroll all windows displaying this buffer to the bottom
---@param buf number
---@param force? boolean If true, force cursor to bottom regardless of distance
function M.scroll_to_bottom(buf, force)
	local protocol = package.loaded["agy.protocol"]
	local state = protocol and protocol.buffers and protocol.buffers[buf]

	if state and state.config and state.config.ui and state.config.ui.auto_scroll == false then
		return
	end

	if state and state.follow_bottom == false then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local prompt_start = nil
	if state and state.prompt_extmark_id then
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, state.prompt_extmark_id, {})
		if pos and #pos >= 1 then
			prompt_start = pos[1] + 1
			state.prompt_start_line = prompt_start
		end
	end

	local wins = vim.fn.win_findbuf(buf)
	if #wins == 0 then
		local win = vim.fn.bufwinid(buf)
		if win ~= -1 then
			wins = { win }
		end
	end

	local cur_win = vim.api.nvim_get_current_win()

	for _, win in ipairs(wins) do
		pcall(function()
			local cur = vim.api.nvim_win_get_cursor(win)
			local cur_line = cur[1]
			local cur_col = cur[2]

			if prompt_start then
				if cur_line >= prompt_start then
					local line_text = vim.api.nvim_buf_get_lines(buf, cur_line - 1, cur_line, false)[1] or ""
					local col = math.min(cur_col, #line_text)
					vim.api.nvim_win_set_cursor(win, { cur_line, col })
				else
					if win == cur_win and state then
						state.follow_bottom = false
					end
				end
			else
				if win == cur_win and cur_line < line_count - 5 and cur_line > 2 then
					if state then
						state.follow_bottom = false
					end
				end
				if force then
					if cur_line >= line_count - 5 or cur_line <= 2 or win == cur_win then
						vim.api.nvim_win_set_cursor(win, { line_count, 0 })
					end
				else
					if cur_line >= line_count - 5 or cur_line <= 2 then
						vim.api.nvim_win_set_cursor(win, { line_count, 0 })
					end
				end
			end
			M.ensure_bottom_visible(win, buf)
		end)
	end
end

---Check if a buffer line is a compact tool, thought, or background task header
---@param line? string
---@param config? table
---@return boolean
function M.is_compact_header_line(line, config)
	if not line or line == "" then
		return false
	end
	if line:find("^%s%s%s") ~= nil then
		return true
	end
	local icons = get_icons(config)
	for k, icon_val in pairs(icons) do
		if
			k ~= "default"
			and k ~= "prompt_sign"
			and k ~= "footer"
			and k ~= "user"
			and k ~= "agent"
			and k ~= "queue"
			and k ~= "checkbox_unchecked"
			and k ~= "checkbox_checked"
			and type(icon_val) == "string"
			and icon_val ~= ""
		then
			local trimmed_icon = utils.trim(icon_val)
			if trimmed_icon ~= "" and (vim.startswith(line, trimmed_icon) or vim.startswith(line, icon_val)) then
				return true
			end
		end
	end
	return false
end

---Check if a buffer line is a queued message header
---@param line? string
---@param config? table
---@return boolean
function M.is_queue_header_line(line, config)
	if not line or line == "" then
		return false
	end
	local icon = get_icon("queue", config)
	assert(icon, "agy config: icon 'queue' is not defined in config.icons")
	local trimmed_icon = utils.trim(icon)
	return (vim.startswith(line, trimmed_icon) or vim.startswith(line, icon))
		and line:find("Queued%s*#?%d*") ~= nil
end

---Get the 0-indexed row of any divider or queue below the active agent divider, if present
---@param buf number
---@param from_agent_row? number 0-indexed line of the agent divider
---@return number? boundary_row
---@return number? agent_row
function M.get_agent_boundary(buf, from_agent_row)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil, nil
	end

	local agent_row = from_agent_row
	if not agent_row then
		local protocol = package.loaded["agy.protocol"]
		local state = protocol and protocol.buffers and protocol.buffers[buf]
		if state and state.agent_extmark_id then
			local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, state.agent_extmark_id, {})
			if pos and #pos >= 1 then
				agent_row = pos[1]
			end
		end
		if not agent_row and state and state.agent_line then
			agent_row = state.agent_line
		end
	end

	local ui_marks = vim.api.nvim_buf_get_extmarks(buf, M.NS_UI, 0, -1, { details = true })
	if not agent_row then
		for _, m in ipairs(ui_marks) do
			local row = m[2]
			local opts = m[4]
			if opts.virt_lines and opts.virt_lines[1] and opts.virt_lines[1][1] then
				local text = opts.virt_lines[1][1][1] or ""
				if text:find("Antigravity") then
					agent_row = row
				end
			end
		end
	end

	if not agent_row then
		return nil, nil
	end

	local boundary_row = nil

	-- Check queue marks in NS_QUEUE
	local q_marks = vim.api.nvim_buf_get_extmarks(buf, M.NS_QUEUE, 0, -1, {})
	for _, qm in ipairs(q_marks) do
		local row = qm[2]
		if row > agent_row then
			if not boundary_row or row < boundary_row then
				boundary_row = row
			end
		end
	end

	-- Check active prompt divider in NS_UI (must have sign_hl_group == "AgyUserSign" or number_hl_group == "AgyPromptArea")
	for _, m in ipairs(ui_marks) do
		local row = m[2]
		local opts = m[4]
		if row > agent_row then
			local is_active_prompt = (opts.sign_hl_group == "AgyUserSign" or opts.number_hl_group == "AgyPromptArea")
			if is_active_prompt then
				if not boundary_row or row < boundary_row then
					boundary_row = row
				end
			end
		end
	end

	return boundary_row, agent_row
end

---Get the maximum width across all windows displaying this buffer
---@param buf number
---@return number width
function M.get_max_window_width(buf)
	local max_w = 0
	if buf and vim.api.nvim_buf_is_valid(buf) then
		local wins = vim.fn.win_findbuf(buf)
		for _, w in ipairs(wins) do
			if vim.api.nvim_win_is_valid(w) then
				local w_width = vim.api.nvim_win_get_width(w)
				if w_width > max_w then
					max_w = w_width
				end
			end
		end
	end
	if max_w <= 0 then
		max_w = (vim.o and vim.o.columns and vim.o.columns > 0) and vim.o.columns or 80
	end
	return max_w
end

---Draw or generate virtual lines for a turn separator (User or Antigravity)
---Can be overridden directly (e.g. `render.draw_separator = my_func`)
---or configured via `config.ui.separator`.
---@param ctx table Context table with role, name, icon, badge_text, badge_hl, title_hl, width, config, buf, line, extmark_id
---@return table | number virt_lines or extmark_id
function M.draw_separator(ctx)
	local cfg = ctx.config or get_config()
	local sep = cfg.ui and cfg.ui.separator
	assert(
		type(sep) == "function",
		"agy config: ui.separator must be a function, e.g. require('agy.ui.separator').box('rounded')"
	)
	return sep(ctx)
end

---Set a virtual divider line spanning across the sign and number columns
---@param buf number
---@param line number 0-indexed line
---@param role "user" | "agent"
---@param badge_text? string
---@param badge_hl? string
---@param sign? boolean
---@param extmark_id? number
---@param config? table
---@return number extmark_id
function M.set_divider(buf, line, role, badge_text, badge_hl, sign, extmark_id, config)
	local is_active_input = (role == "user" and sign == true)

	if is_active_input then
		local width = M.get_max_window_width(buf)
		local chunks = {
			{ string.rep("─", width), "AgyPromptBorder" },
		}
		local opts = {
			virt_lines = { chunks },
			virt_lines_leftcol = true,
			virt_lines_above = true,
			right_gravity = false,
			priority = 200,
		}
		if extmark_id then
			opts.id = extmark_id
		end
		local prompt_sign = get_icon("prompt_sign", config)
		assert(prompt_sign, "agy config: icon 'prompt_sign' is not defined in config.icons")
		opts.sign_text = prompt_sign
		opts.sign_hl_group = "AgyUserSign"
		opts.number_hl_group = "AgyPromptArea"
		return vim.api.nvim_buf_set_extmark(buf, M.NS_UI, line, 0, opts)
	end

	local icon = (role == "user") and get_icon("user", config) or get_icon("agent", config)
	assert(icon, string.format("agy config: icon '%s' is not defined in config.icons", role))
	local name = (role == "user") and "User" or "Antigravity"
	local title_hl = (role == "user") and "AgyUserDivider" or "AgyAgentDivider"
	local width = M.get_max_window_width(buf)

	local ctx = {
		buf = buf,
		line = line,
		role = role,
		name = name,
		icon = icon,
		badge_text = badge_text,
		badge_hl = badge_hl,
		title_hl = title_hl,
		width = width,
		config = get_config(config),
		extmark_id = extmark_id,
	}

	local res = M.draw_separator(ctx)
	if type(res) == "number" then
		return res
	end

	assert(type(res) == "table", "agy separator: renderer must return a table of virtual lines or extmark id")

	-- If returned table is a single line of chunks: { { text, hl }, { text, hl } }
	local virt_lines
	if #res > 0 and type(res[1]) == "table" and type(res[1][1]) == "string" then
		virt_lines = { res }
	else
		virt_lines = res
	end

	local opts = {
		virt_lines = virt_lines,
		virt_lines_leftcol = true,
		virt_lines_above = true,
		right_gravity = false,
		priority = 200,
	}
	if extmark_id then
		opts.id = extmark_id
	end

	return vim.api.nvim_buf_set_extmark(buf, M.NS_UI, line, 0, opts)
end

M.thinking_timers = {}

---Start thinking spinner animation on the agent divider
---@param buf number
---@param agent_line number 0-indexed line of agent divider
---@param extmark_id number Extmark ID of the agent divider
---@param config? table
function M.start_thinking_animation(buf, agent_line, extmark_id, config)
	M.stop_thinking_animation(buf)

	local cfg = get_config(config)
	if not cfg.ui or cfg.ui.animate_thinking == false then
		return
	end

	local frames = get_spinner_frames(cfg)
	local frame_idx = 1
	local timer = (vim.uv and vim.uv.new_timer) and vim.uv.new_timer() or vim.loop.new_timer()
	M.thinking_timers[buf] = timer

	timer:start(
		100,
		100,
		vim.schedule_wrap(function()
			if not vim.api.nvim_buf_is_valid(buf) then
				M.stop_thinking_animation(buf)
				return
			end
			if M.thinking_timers[buf] ~= timer then
				return
			end

			local frame = frames[frame_idx]
			frame_idx = (frame_idx % #frames) + 1
			local badge = string.format(" [%s Thinking...]", frame)

			pcall(function()
				M.set_divider(buf, agent_line, "agent", badge, "AgyBadgeActive", false, extmark_id, cfg)
			end)
		end)
	)
end

---Stop thinking spinner animation on the agent divider
---@param buf number
function M.stop_thinking_animation(buf)
	local timer = M.thinking_timers[buf]
	if timer then
		M.thinking_timers[buf] = nil
		pcall(function()
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
		end)
	end
end


---Set or update the bottom prompt footer virtual text and bottom border
---@param buf number
---@param footer_text? string
---@param extmark_id? number
---@param is_prompt_active? boolean If true, render the bottom border line of the prompt area
---@param config? table
---@return number? extmark_id
function M.set_prompt_footer(buf, footer_text, extmark_id, is_prompt_active, config)
	if not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = line_count - 1

	local virt_lines = {}
	if is_prompt_active then
		local width = M.get_max_window_width(buf)
		table.insert(virt_lines, { { string.rep("─", width), "AgyPromptBorder" } })
	end

	if footer_text and footer_text ~= "" then
		local footer_icon = get_icon("footer", config)
		table.insert(virt_lines, { { string.format("── %s %s", footer_icon, footer_text), "AgyPromptFooter" } })
	end

	if #virt_lines == 0 then
		if extmark_id then
			pcall(vim.api.nvim_buf_del_extmark, buf, M.NS_UI, extmark_id)
		end
		return nil
	end

	local opts = {
		virt_lines = virt_lines,
		virt_lines_leftcol = true,
		virt_lines_above = false,
		right_gravity = true,
		priority = 100,
	}

	if extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, M.NS_UI, extmark_id)
	end

	return vim.api.nvim_buf_set_extmark(buf, M.NS_UI, last_line, 0, opts)
end

---Apply background color to history lines
---@param buf number
---@param prompt_start_line number 1-indexed line where editable prompt starts
---@param config table
function M.apply_history_highlights(buf, prompt_start_line, config)
	vim.api.nvim_buf_clear_namespace(buf, M.NS_HISTORY, 0, -1)
	if not config or not config.ui or not config.ui.color_history then
		return
	end

	local last_history_idx = prompt_start_line - 2 -- 0-indexed, line above prompt

	for l = 0, last_history_idx do
		vim.api.nvim_buf_set_extmark(buf, M.NS_HISTORY, l, 0, {
			line_hl_group = "AgyHistory",
			priority = 10,
		})
	end
end

---Apply background highlight to prompt area lines
---@param buf number
---@param prompt_start_line number 1-indexed line where prompt starts
---@param config? table
function M.apply_prompt_highlights(buf, prompt_start_line, config)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, M.NS_PROMPT, 0, -1)
	if not prompt_start_line then
		return
	end

	local prompt_sign = get_icon("prompt_sign", config)
	local sign_w = vim.fn.strdisplaywidth(prompt_sign)
	local cont_sign = string.rep(" ", sign_w)

	local line_count = vim.api.nvim_buf_line_count(buf)
	local start_idx = math.max(prompt_start_line - 1, 0)
	for l = start_idx, line_count - 1 do
		local opts = {
			line_hl_group = "AgyPromptArea",
			number_hl_group = "AgyPromptArea",
			priority = 10,
		}
		if l > start_idx then
			opts.sign_text = cont_sign
			opts.sign_hl_group = "AgyPromptSign"
		end
		pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_PROMPT, l, 0, opts)
	end
end

---Clear background highlights from prompt area lines
---@param buf number
function M.clear_prompt_highlights(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, M.NS_PROMPT, 0, -1)
end

---Reset logo highlight groups to their static base colors
---@param cfg? table
function M.reset_logo_highlights(cfg)
	cfg = cfg or get_config()
	for r = 0, 4 do
		local _, cells = get_logo_row_info(r, cfg)
		for _, cell in ipairs(cells) do
			local hl = { fg = cell.fg }
			if cell.bg then
				hl.bg = cell.bg
			end
			vim.api.nvim_set_hl(0, cell.hl_group, hl)
		end
	end
end

---Apply an animated color frame to the logo highlight groups
---@param deg number
---@param cfg? table
function M.apply_logo_animation_frame(deg, cfg)
	cfg = cfg or get_config()
	for r = 0, 4 do
		local _, cells = get_logo_row_info(r, cfg)
		for _, cell in ipairs(cells) do
			local spatial_phase = (r * 25 + cell.col * 15) % 360
			local cell_deg = (deg + spatial_phase) % 360
			local new_fg = shift_color_hue(cell.fg, cell_deg)
			local new_bg = shift_color_hue(cell.bg, cell_deg)
			local hl = { fg = new_fg }
			if new_bg then
				hl.bg = new_bg
			end
			vim.api.nvim_set_hl(0, cell.hl_group, hl)
		end
	end
end

---Start dynamic color animation for the inverted V logo
---@param buf number
---@param config? table
function M.start_logo_animation(buf, config)
	local cfg = get_config(config)
	if not cfg.ui or cfg.ui.animate_logo == false then
		return
	end

	M.active_logo_buffers[buf] = true

	if M.logo_timer then
		return
	end

	local timer = (vim.uv and vim.uv.new_timer) and vim.uv.new_timer() or vim.loop.new_timer()
	M.logo_timer = timer

	timer:start(
		120,
		120,
		vim.schedule_wrap(function()
			local has_active = false
			local is_any_visible = false
			for b in pairs(M.active_logo_buffers) do
				if vim.api.nvim_buf_is_valid(b) then
					has_active = true
					local wins = vim.fn.win_findbuf(b)
					if #wins > 0 then
						for _, w in ipairs(wins) do
							if vim.api.nvim_win_is_valid(w) and vim.fn.line("w0", w) <= 6 then
								is_any_visible = true
								break
							end
						end
					elseif vim.fn.bufwinid(b) ~= -1 and vim.fn.line("w0", vim.fn.bufwinid(b)) <= 6 then
						is_any_visible = true
					end
				else
					M.active_logo_buffers[b] = nil
				end
			end

			if not has_active then
				M.stop_logo_animation()
				return
			end

			if is_any_visible then
				M.logo_animation_angle = (M.logo_animation_angle + 6) % 360
				M.apply_logo_animation_frame(M.logo_animation_angle, cfg)
			end
		end)
	)
end

---Stop logo animation for a buffer, or all if no buffers remaining
---@param buf? number
function M.stop_logo_animation(buf)
	if buf then
		M.active_logo_buffers[buf] = nil
	end

	local remaining = 0
	for b in pairs(M.active_logo_buffers) do
		if vim.api.nvim_buf_is_valid(b) then
			remaining = remaining + 1
		else
			M.active_logo_buffers[b] = nil
		end
	end

	if remaining == 0 and M.logo_timer then
		local timer = M.logo_timer
		M.logo_timer = nil
		pcall(function()
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
		end)
		M.reset_logo_highlights()
	end
end

---Build the banner lines with padding around the logo and vertically centered text
---@param session_uri string
---@param config? table
---@param session_uri string
---@param config? table
---@param sub_text? string
---@return string[]
function M.build_banner_lines(session_uri, config, sub_text)
	local cfg = get_config(config)
	local pad = "    "
	local version = utils.get_agy_version(cfg)
	local title_text = "Antigravity CLI" .. (version and (" " .. version) or "")

	local lines = {}
	-- Top padding line
	table.insert(lines, "")

	for r = 0, 4 do
		local logo_str, _ = get_logo_row_info(r, cfg)
		if r == 1 then
			table.insert(lines, logo_str .. pad .. title_text)
		elseif r == 2 then
			table.insert(lines, logo_str .. pad .. session_uri)
		elseif r == 3 and sub_text then
			table.insert(lines, logo_str .. pad .. sub_text)
		else
			table.insert(lines, logo_str)
		end
	end

	-- Bottom padding line
	table.insert(lines, "")
	-- Active prompt line
	table.insert(lines, "")

	return lines
end

---Apply extmark highlights to the banner in NS_LOGO
---@param buf number
---@param session_uri string
---@param config? table
---@param sub_text? string
function M.render_banner_extmarks(buf, session_uri, config, sub_text)
	local cfg = get_config(config)
	vim.api.nvim_buf_clear_namespace(buf, M.NS_LOGO, 0, -1)

	local pad = "    "
	local version = utils.get_agy_version(cfg)
	local title_text = "Antigravity CLI" .. (version and (" " .. version) or "")

	for r = 0, 4 do
		local logo_str, cells = get_logo_row_info(r, cfg)
		local buf_row = r + 1 -- Top padding line is at buffer line 0
		for _, cell in ipairs(cells) do
			vim.api.nvim_buf_set_extmark(buf, M.NS_LOGO, buf_row, cell.byte_start, {
				end_col = cell.byte_end,
				hl_group = cell.hl_group,
				priority = 150,
			})
		end

		if r == 1 then
			local title_start = #logo_str + #pad
			local title_end = title_start + #title_text
			vim.api.nvim_buf_set_extmark(buf, M.NS_LOGO, buf_row, title_start, {
				end_col = title_end,
				hl_group = "AgyHeaderTitle",
				priority = 150,
			})
		elseif r == 2 then
			local sub_start = #logo_str + #pad
			local sub_end = sub_start + #session_uri
			vim.api.nvim_buf_set_extmark(buf, M.NS_LOGO, buf_row, sub_start, {
				end_col = sub_end,
				hl_group = "AgyHeaderSub",
				priority = 150,
			})
		elseif r == 3 and sub_text then
			local sub2_start = #logo_str + #pad
			local sub2_end = sub2_start + #sub_text
			vim.api.nvim_buf_set_extmark(buf, M.NS_LOGO, buf_row, sub2_start, {
				end_col = sub2_end,
				hl_group = "Comment",
				priority = 150,
			})
		end
	end
end

---Initialize an agy conversation buffer with standard session header and active prompt
---@param buf number
---@param session_uri string e.g. "agy://new" or "agy://<conversation_id>"
---@param config? table
---@return number prompt_start_line
---@return number prompt_extmark_id
function M.init_session_buffer(buf, session_uri, config)
	M.setup_highlights()
	pcall(vim.treesitter.start, buf, "markdown")
	vim.api.nvim_buf_clear_namespace(buf, M.NS_UI, 0, -1)
	vim.api.nvim_buf_clear_namespace(buf, M.NS_HISTORY, 0, -1)
	vim.api.nvim_buf_clear_namespace(buf, M.NS_LOGO, 0, -1)

	local cfg = get_config(config)
	local header_style = (cfg.ui and cfg.ui.header_style) or "banner"

	local lines
	if header_style == "banner" then
		lines = M.build_banner_lines(session_uri, cfg)
	else
		lines = {
			"# Antigravity Session: " .. session_uri,
			"",
			"",
		}
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local prompt_start_line = #lines

	if header_style == "banner" then
		M.render_banner_extmarks(buf, session_uri, cfg)
		M.start_logo_animation(buf, cfg)
	end

	-- Place active prompt divider above line (prompt_start_line - 1)
	local prompt_extmark_id = M.set_divider(buf, prompt_start_line - 1, "user", nil, nil, true, nil, config)

	-- Highlight header lines as history
	M.apply_history_highlights(buf, prompt_start_line, config)

	-- Apply prompt area highlight
	M.apply_prompt_highlights(buf, prompt_start_line, config)

	vim.bo[buf].modified = false

	return prompt_start_line, prompt_extmark_id
end

---Render initial blank conversation buffer for agy://new
---@param buf number
---@param config table
---@return number prompt_start_line
---@return number prompt_extmark_id
function M.render_new_session(buf, config)
	return M.init_session_buffer(buf, "agy://new", config)
end

---Render a historical question block (from ask_question) into the buffer
---@param buf number
---@param params? table
---@param output? string
---@param config table
---@param cwd? string|string[]
function M.render_historical_question(buf, params, output, config, cwd)
	local q_list = M.parse_question_params(params)
	if #q_list == 0 then
		local tool_line, ext_id, param_str = M.append_tool_call(buf, "ask_question", params or {}, cwd, config)
		local tool_rec = {
			tool_name = "ask_question",
			params = params or {},
			param_str = param_str,
			output = output,
			header_extmark_id = ext_id,
			header_line_idx = tool_line,
		}
		M.complete_tool_call(buf, tool_rec, nil, output, config)
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
	local to_append = {}
	if last_line ~= "" then
		table.insert(to_append, "")
	end

	local answer_text = output or ""
	local q_icon = get_icon("question", config)
	local header_indices = {}

	for q_idx, q in ipairs(q_list) do
		local header_text = (#q_list > 1) and string.format("%s Question %d: %s", q_icon, q_idx, q.question)
			or string.format("%s Question: %s", q_icon, q.question)

		table.insert(to_append, header_text)
		table.insert(header_indices, #to_append)
		table.insert(to_append, "")

		for _, opt in ipairs(q.options) do
			local is_checked = (answer_text ~= "" and answer_text:find(opt, 1, true) ~= nil)
			table.insert(to_append, string.format("- [%s] %s", is_checked and "x" or " ", opt))
		end

		if q_idx < #q_list then
			table.insert(to_append, "")
		end
	end

	local notes = answer_text:match("Notes:%s*(.*)$")
	if notes and notes ~= "" then
		table.insert(to_append, "")
		table.insert(to_append, string.format("Notes: %s", notes))
	end

	local start_line
	if last_line == "" then
		start_line = line_count - 1
		vim.api.nvim_buf_set_lines(buf, start_line, line_count, false, to_append)
	else
		start_line = line_count
		vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, to_append)
	end

	for _, h_idx in ipairs(header_indices) do
		local h_row = start_line + h_idx - 1
		local h_text = to_append[h_idx]
		pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_UI, h_row, 0, {
			end_col = #h_text,
			hl_group = "AgyQuestionHeader",
			priority = 100,
		})
	end

	vim.bo[buf].modified = false
end

---Render historical transcript steps into a freshly opened buffer by replaying events through canonical primitives
---@param buf number
---@param conversation_id string
---@param steps? table[]
---@param config? table
---@param cwd? string|string[]
---@return number prompt_start_line
---@return number prompt_extmark_id
---@return table[] tool_calls
function M.render_transcript(buf, conversation_id, steps, config, cwd)
	assert(buf and vim.api.nvim_buf_is_valid(buf), "agy render: valid buffer is required")
	assert(conversation_id, "agy render: conversation_id is required")
	config = get_config(config)
	cwd = cwd or vim.fn.getcwd()

	local prompt_start_line, prompt_extmark_id = M.init_session_buffer(buf, "agy://" .. conversation_id, config)
	if not steps or #steps == 0 then
		return prompt_start_line, prompt_extmark_id, {}
	end

	local tasks_mod = require("agy.tasks")
	local task_outcomes = tasks_mod.collect_task_outcomes(steps)

	local in_agent_turn = false
	local has_user_input_for_current_turn = false
	local agent_extmark_id = nil
	local agent_line = nil
	local current_agent_turn_duration = 0
	local current_agent_turn_has_explicit_duration = false
	local current_agent_turn_start_time = nil
	local current_agent_turn_end_time = nil
	local last_user_input_time = nil
	local tool_calls = {}

	local function finish_agent_turn()
		if not in_agent_turn then
			return
		end
		local turn_duration = nil
		if current_agent_turn_has_explicit_duration and current_agent_turn_duration > 0 then
			turn_duration = current_agent_turn_duration
		elseif current_agent_turn_start_time and current_agent_turn_end_time then
			local elapsed = current_agent_turn_end_time - current_agent_turn_start_time
			if elapsed > 0 then
				turn_duration = elapsed
			end
		end
		local result = {
			status = "DONE",
			duration_seconds = turn_duration,
		}
		local target_agent_row = agent_line
		if agent_extmark_id then
			local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, agent_extmark_id, {})
			if pos and #pos >= 1 then
				target_agent_row = pos[1]
			end
		end
		prompt_start_line, prompt_extmark_id = M.finalize_turn(buf, agent_extmark_id, target_agent_row, result, config)
		in_agent_turn = false
		agent_extmark_id = nil
		agent_line = nil
		current_agent_turn_duration = 0
		current_agent_turn_has_explicit_duration = false
		current_agent_turn_start_time = nil
		current_agent_turn_end_time = nil
	end

	local function update_agent_turn_created_at(step_created_at)
		if in_agent_turn and not current_agent_turn_has_explicit_duration and step_created_at then
			local t = utils.parse_iso_timestamp(step_created_at)
			if t then
				if not current_agent_turn_start_time then
					current_agent_turn_start_time = t
				end
				current_agent_turn_end_time = t
			end
		end
	end

	local function ensure_agent_turn(duration, step_created_at)
		if not in_agent_turn then
			if has_user_input_for_current_turn then
				agent_extmark_id, agent_line = M.prepare_turn_submission(buf, prompt_start_line, prompt_extmark_id, config)
				prompt_extmark_id = nil
				has_user_input_for_current_turn = false
			else
				agent_line = prompt_start_line - 1
				agent_extmark_id = M.set_divider(buf, agent_line, "agent", " [Thinking...]", "AgyBadgeActive", false, prompt_extmark_id, config)
				prompt_extmark_id = nil
			end
			in_agent_turn = true
			current_agent_turn_duration = 0
			current_agent_turn_has_explicit_duration = false
			current_agent_turn_start_time = last_user_input_time
			current_agent_turn_end_time = nil
		end

		if duration and duration > 0 then
			current_agent_turn_has_explicit_duration = true
			current_agent_turn_duration = current_agent_turn_duration + duration
		elseif not current_agent_turn_has_explicit_duration and step_created_at then
			update_agent_turn_created_at(step_created_at)
		end
	end

	local function archive_user_input()
		if not has_user_input_for_current_turn then
			return
		end
		M.set_divider(buf, prompt_start_line - 1, "user", nil, nil, false, prompt_extmark_id, config)
		local line_count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", "" })
		prompt_start_line = vim.api.nvim_buf_line_count(buf)
		prompt_extmark_id = M.set_divider(buf, prompt_start_line - 1, "user", nil, nil, true, nil, config)
		M.apply_history_highlights(buf, prompt_start_line, config)
		M.apply_prompt_highlights(buf, prompt_start_line, config)
		has_user_input_for_current_turn = false
	end

	local function replay_tool_call(name, args, output, duration_seconds)
		local q_list = (name == "ask_question") and M.parse_question_params(args) or {}
		if name == "ask_question" and #q_list > 0 then
			M.render_historical_question(buf, args, output, config, cwd)
		else
			local tool_line, ext_id, param_str = M.append_tool_call(buf, name, args or {}, cwd, config)
			local tool_rec = {
				id = #tool_calls + 1,
				tool_name = name,
				params = args or {},
				param_str = param_str,
				output = output,
				duration_seconds = duration_seconds,
				status = "done",
				is_open = false,
				header_extmark_id = ext_id,
				header_line_idx = tool_line,
				output_lines_count = 0,
				cwd = cwd,
			}
			table.insert(tool_calls, tool_rec)
			M.complete_tool_call(buf, tool_rec, duration_seconds, output, config)
			if name == "run_command" then
				local task_info = tasks_mod.parse_task_info(output, args)
				if task_info then
					local outcome = task_outcomes[task_info.task_id] or task_outcomes[task_info.short_id]
					if outcome then
						M.update_task_status(buf, tool_rec, outcome.status, outcome.exit_code, config)
					end
				end
			end
		end
	end

	for i, step in ipairs(steps) do
		if step.type == "USER_INPUT" then
			if in_agent_turn then
				finish_agent_turn()
			elseif has_user_input_for_current_turn then
				archive_user_input()
			end

			last_user_input_time = utils.parse_iso_timestamp(step.created_at)
			local content = step.display_content or utils.clean_user_content(step.content or "")
			local content_lines = utils.split_lines(content)
			vim.api.nvim_buf_set_lines(buf, prompt_start_line - 1, -1, false, content_lines)
			has_user_input_for_current_turn = true

		elseif step.type == "PLANNER_RESPONSE" then
			ensure_agent_turn(step.duration_seconds, step.created_at)

			if config.ui and config.ui.show_thoughts ~= false and step.thinking and step.thinking ~= "" then
				local tc_rec = M.append_thought_block(buf, step.thinking, step.duration_seconds, config)
				tc_rec.id = #tool_calls + 1
				table.insert(tool_calls, tc_rec)
			end

			local text = step.content or step.text_delta
			if text and text ~= "" then
				M.append_text_delta(buf, text, config, true)
			end

			if step.tool_calls and #step.tool_calls > 0 then
				for tc_idx, tc in ipairs(step.tool_calls) do
					local output = tc.output
					if not output then
						local candidate_step = (#step.tool_calls == 1) and steps[i + 1] or steps[i + tc_idx]
						if candidate_step then
							local ntype = candidate_step.type
							if ntype == "TOOL_OUTPUT" or ntype == "tool_result" or ntype == "GENERIC" then
								local candidate = candidate_step.content or candidate_step.output
								if not (candidate and type(candidate) == "string" and candidate:find("finished with result:", 1, true)) then
									output = candidate
								end
							end
						end
					end
					local dur = tc.duration_seconds or step.duration_seconds
					replay_tool_call(tc.name, tc.args, output, dur)
				end
			end

		elseif step.type == "TOOL_CALL" or step.type == "tool" then
			ensure_agent_turn(step.duration_seconds, step.created_at)

			local name = step.tool_name or (step.tool_info and step.tool_info.name)
			assert(name, "agy render: tool step missing tool name")
			local args = step.args or (step.tool_info and step.tool_info.parameters) or {}
			local output = step.output or (step.tool_info and step.tool_info.output)
			local next_step = steps[i + 1]
			if not output and next_step and (next_step.type == "GENERIC" or next_step.type == "TOOL_OUTPUT" or next_step.type == "tool_result") then
				local candidate = next_step.content or next_step.output
				if not (candidate and type(candidate) == "string" and candidate:find("finished with result:", 1, true)) then
					output = candidate
				end
			end
			replay_tool_call(name, args, output, step.duration_seconds)

		else
			if in_agent_turn then
				update_agent_turn_created_at(step.created_at)
			end
		end
	end

	if in_agent_turn then
		finish_agent_turn()
	elseif has_user_input_for_current_turn then
		archive_user_input()
	end

	M.stop_thinking_animation(buf)
	vim.bo[buf].modified = false

	return prompt_start_line, prompt_extmark_id, tool_calls
end

---Update title of buffer once conversation ID is known
---@param buf number
---@param conversation_id string
---@param config? table
function M.update_session_id(buf, conversation_id, config)
	local cfg = get_config(config)
	local header_style = (cfg.ui and cfg.ui.header_style) or "banner"
	local target_uri = "agy://" .. conversation_id

	pcall(function()
		if header_style == "banner" then
			local pad = "    "
			local logo_str, cells = get_logo_row_info(2, cfg)
			local new_line = logo_str .. pad .. target_uri
			local buf_row = 3 -- Line 0: top pad, Line 1: r=0, Line 2: r=1, Line 3: r=2
			vim.api.nvim_buf_set_lines(buf, buf_row, buf_row + 1, false, { new_line })

			vim.api.nvim_buf_clear_namespace(buf, M.NS_LOGO, buf_row, buf_row + 1)
			for _, cell in ipairs(cells) do
				vim.api.nvim_buf_set_extmark(buf, M.NS_LOGO, buf_row, cell.byte_start, {
					end_col = cell.byte_end,
					hl_group = cell.hl_group,
					priority = 150,
				})
			end

			local sub_start = #logo_str + #pad
			local sub_end = sub_start + #target_uri
			vim.api.nvim_buf_set_extmark(buf, M.NS_LOGO, buf_row, sub_start, {
				end_col = sub_end,
				hl_group = "AgyHeaderSub",
				priority = 150,
			})
		else
			local first_line = "# Antigravity Session: " .. target_uri
			vim.api.nvim_buf_set_lines(buf, 0, 1, false, { first_line })
		end
		vim.bo[buf].modified = false
	end)
end

---Prepare buffer when user submits prompt via :w
---@param buf number
---@param old_prompt_start_line number
---@param prompt_extmark_id? number
---@param config? table
---@return number agent_extmark_id
---@return number agent_line 0-indexed line of agent response
function M.prepare_turn_submission(buf, old_prompt_start_line, prompt_extmark_id, config)
	M.setup_highlights()
	M.clear_prompt_highlights(buf)

	-- Archive the user prompt divider as history (remove sign_text, ensure single extmark)
	if prompt_extmark_id then
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, prompt_extmark_id, {})
		local target_row = (pos and #pos >= 1) and pos[1] or (old_prompt_start_line - 1)
		M.set_divider(buf, target_row, "user", nil, nil, false, prompt_extmark_id, config)
	else
		local existing = vim.api.nvim_buf_get_extmarks(
			buf,
			M.NS_UI,
			{ old_prompt_start_line - 1, 0 },
			{ old_prompt_start_line - 1, -1 },
			{ details = true }
		)
		local existing_id = (existing and #existing > 0) and existing[1][1] or nil
		M.set_divider(buf, old_prompt_start_line - 1, "user", nil, nil, false, existing_id, config)
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""

	local append = {}
	if last_line ~= "" then
		table.insert(append, "")
	end
	table.insert(append, "") -- First line of agent response

	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, append)
	local new_count = vim.api.nvim_buf_line_count(buf)
	local agent_line = new_count - 1

	-- Place active thinking divider above agent response
	local extmark_id = M.set_divider(buf, agent_line, "agent", " [Thinking...]", "AgyBadgeActive", false, nil, config)
	M.start_thinking_animation(buf, agent_line, extmark_id, config)

	return extmark_id, agent_line
end

---Stream text delta into buffer
---@param buf number
---@param delta string
---@param config? table
---@param is_final? boolean
function M.append_text_delta(buf, delta, config, is_final)
	if not delta or (delta == "" and not is_final) then
		return
	end

	local cfg = get_config(config)
	local render_fn = cfg.ui and cfg.ui.render_markdown
	assert(type(render_fn) == "function", "agy config: 'ui.render_markdown' function is required in config")
	render_fn(buf, delta, is_final or false, cfg)
end

---Render an agent thought block as a collapsible item (similar to tool calls)
---@param buf number
---@param thought string
---@param duration_seconds? number
---@param config? table
---@return table tc_rec
function M.append_thought_block(buf, thought, duration_seconds, config)
	pcall(require("agy.markdown").finalize, buf, config)
	local thought_icon = get_icon("thought", config)
	local line_text = string.format("%s Thought", thought_icon)

	local boundary_row, agent_row = M.get_agent_boundary(buf)
	local thought_line
	if boundary_row then
		local sep_row = boundary_row - 1
		local prev_row = sep_row - 1
		if not agent_row or prev_row <= agent_row then
			vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { line_text })
			thought_line = sep_row
		else
			local prev_line = vim.api.nvim_buf_get_lines(buf, prev_row, prev_row + 1, false)[1] or ""
			local is_tight = M.is_compact_header_line(prev_line, config)
			if is_tight then
				vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { line_text })
				thought_line = sep_row
			else
				vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { "", line_text })
				thought_line = sep_row + 1
			end
		end
	else
		local line_count = vim.api.nvim_buf_line_count(buf)
		local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
		local is_tight = M.is_compact_header_line(last_line, config)
		if last_line == "" then
			vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { line_text })
			thought_line = line_count - 1
		elseif is_tight then
			vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { line_text })
			thought_line = line_count
		else
			vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", line_text })
			thought_line = line_count + 1
		end
	end

	vim.bo[buf].modified = false

	local badge = (duration_seconds and duration_seconds > 0)
			and string.format(" %s", utils.format_duration(duration_seconds))
		or ""

	local extmark_opts = {
		hl_group = "AgyThought",
		priority = 150,
	}
	if badge ~= "" then
		extmark_opts.virt_text = { { badge, "AgyToolBadge" } }
		extmark_opts.virt_text_pos = "eol"
	end

	local extmark_id = vim.api.nvim_buf_set_extmark(buf, M.NS_UI, thought_line, 0, extmark_opts)

	local tc_rec = {
		is_thought = true,
		tool_name = "Thought",
		params = {},
		param_str = "",
		output = thought,
		duration_seconds = duration_seconds,
		status = "done",
		is_open = false,
		header_extmark_id = extmark_id,
		header_line_idx = thought_line,
		output_lines_count = 0,
	}

	return tc_rec
end

---Backwards compatibility alias
M.append_thought = M.append_thought_block

---Render a tool invocation step
---@param buf number
---@param tool_name string
---@param params table
---@param cwd? string|string[]
---@param config? table
---@return number tool_line 0-indexed line of tool header
---@return number extmark_id
---@return string param_str
function M.append_tool_call(buf, tool_name, params, cwd, config)
	pcall(require("agy.markdown").finalize, buf, config)
	local is_run_cmd = (tool_name == "run_command")
	local icon = is_run_cmd and get_icon("run_command", config) or get_tool_icon(tool_name, config)

	local param_str = M.format_tool_params(params, cwd)
	local line_text = (param_str ~= "") and string.format("%s %s `%s`", icon, tool_name, param_str)
		or string.format("%s %s", icon, tool_name)

	local boundary_row, agent_row = M.get_agent_boundary(buf)
	local tool_line
	if boundary_row then
		local sep_row = boundary_row - 1
		local prev_row = sep_row - 1
		if not agent_row or prev_row <= agent_row then
			vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { line_text })
			tool_line = sep_row
		else
			local prev_line = vim.api.nvim_buf_get_lines(buf, prev_row, prev_row + 1, false)[1] or ""
			local is_tight = M.is_compact_header_line(prev_line, config)
			if is_tight then
				vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { line_text })
				tool_line = sep_row
			else
				vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { "", line_text })
				tool_line = sep_row + 1
			end
		end
	else
		local line_count = vim.api.nvim_buf_line_count(buf)
		local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
		local is_tight = M.is_compact_header_line(last_line, config)
		if last_line == "" then
			vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { line_text })
			tool_line = line_count - 1
		elseif is_tight then
			vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { line_text })
			tool_line = line_count
		else
			vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", line_text })
			tool_line = line_count + 1
		end
	end

	vim.bo[buf].modified = false

	local s_col, e_col = line_text:find(tool_name, 1, true)
	local hl_group = is_run_cmd and "AgyTaskRunning" or "AgyToolHeader"
	local start_col = is_run_cmd and 0 or (s_col and (s_col - 1) or 0)

	local extmark_opts = {
		hl_group = hl_group,
		priority = 150,
	}
	if e_col then
		extmark_opts.end_col = e_col
	end
	local extmark_id = vim.api.nvim_buf_set_extmark(buf, M.NS_UI, tool_line, start_col, extmark_opts)
	return tool_line, extmark_id, param_str
end

---Update the visual display, icon, extmark, and status of a background task tool call
---@param buf number
---@param tool_rec table
---@param new_status "running"|"success"|"failed"
---@param exit_code? number
---@param config? table
function M.update_task_status(buf, tool_rec, new_status, exit_code, config)
	assert(buf and vim.api.nvim_buf_is_valid(buf), "render.update_task_status: valid buffer required")
	assert(tool_rec, "render.update_task_status: tool_rec required")
	assert(new_status and type(new_status) == "string", "render.update_task_status: new_status string required")

	local cfg = get_config(config)
	assert(cfg, "render.update_task_status: config required")

	tool_rec.buf = buf
	if tool_rec.is_background_task == nil then
		tool_rec.is_background_task = (new_status == "running")
	end
	tool_rec.task_status = new_status
	if exit_code ~= nil then
		tool_rec.exit_code = exit_code
	end

	local tool_name = tool_rec.tool_name or "run_command"
	local icon = (tool_name == "run_command" or tool_rec.is_background_task) and get_icon("run_command", cfg)
		or get_tool_icon(tool_name, cfg)
	local hl_group = "AgyTaskRunning"
	local badge_hl = "AgyTaskBadgeRunning"
	local badge = ""

	if new_status == "failed" then
		hl_group = "AgyTaskFailed"
		badge_hl = "AgyTaskBadgeFailed"
		local exit_str = (tool_rec.exit_code ~= nil) and (" (exit " .. tool_rec.exit_code .. ")") or ""
		badge = exit_str
	elseif new_status == "success" then
		hl_group = "AgyTaskSuccess"
		badge_hl = "AgyToolBadge"
		local dur_str = (tool_rec.duration_seconds and tool_rec.duration_seconds > 0)
				and (" " .. utils.format_duration(tool_rec.duration_seconds))
			or ""
		badge = dur_str
	end

	local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, tool_rec.header_extmark_id, {})
	local header_line = (pos and #pos >= 1) and pos[1] or tool_rec.header_line_idx
	if not header_line or header_line >= vim.api.nvim_buf_line_count(buf) then
		return
	end

	local param_str = tool_rec.param_str or (tool_rec.params and M.format_tool_params(tool_rec.params, tool_rec.cwd)) or ""
	local line_text = (param_str ~= "") and string.format("%s %s `%s`", icon, tool_name, param_str)
		or string.format("%s %s", icon, tool_name)

	local cur_line = vim.api.nvim_buf_get_lines(buf, header_line, header_line + 1, false)[1]
	if cur_line ~= line_text then
		local proto = package.loaded["agy.protocol"]
		if proto and proto.with_modifiable then
			proto.with_modifiable(buf, function()
				vim.api.nvim_buf_set_lines(buf, header_line, header_line + 1, false, { line_text })
			end)
		else
			local prev_mod = vim.bo[buf].modifiable
			vim.bo[buf].modifiable = true
			pcall(vim.api.nvim_buf_set_lines, buf, header_line, header_line + 1, false, { line_text })
			vim.bo[buf].modifiable = prev_mod
		end
	end

	pcall(function()
		local _, e_col = line_text:find(tool_name, 1, true)
		local opts = {
			id = tool_rec.header_extmark_id,
			virt_text = (badge ~= "") and { { badge, badge_hl } } or {},
			virt_text_pos = "eol",
			hl_group = hl_group,
			priority = 150,
		}
		if e_col then
			opts.end_col = e_col
		end
		vim.api.nvim_buf_set_extmark(buf, M.NS_UI, header_line, 0, opts)
	end)

	if (new_status == "success" or new_status == "failed") and tool_rec.log_path then
		local full_out = M.get_tool_output(tool_rec)
		if full_out and full_out ~= "" and not full_out:find("^Tool is running as a background task") then
			tool_rec.output = full_out
		end
	end

	if tool_rec.is_open then
		if (tool_rec.is_background_task or tool_rec.log_path) and new_status == "running" then
			M.start_task_log_watcher(nil, tool_rec)
		end
		M.refresh_tool_window(nil, tool_rec, true)
		if new_status ~= "running" then
			M.stop_task_log_watcher(tool_rec)
		end
	end
end

---Update tool call upon completion and attach output without inserting folded blocks
---@param buf number
---@param tool_rec table
---@param duration_seconds? number
---@param output? string
---@param config table
function M.complete_tool_call(buf, tool_rec, duration_seconds, output, config)
	tool_rec.status = "done"
	tool_rec.duration_seconds = duration_seconds
	tool_rec.output = output

	if tool_rec.tool_name == "run_command" then
		local tasks_mod = require("agy.tasks")
		local task_info = tasks_mod.parse_task_info(output, tool_rec.params)
		if task_info then
			tool_rec.buf = buf
			tool_rec.is_background_task = true
			tool_rec.task_id = task_info.task_id
			tool_rec.short_id = task_info.short_id
			tool_rec.log_path = task_info.log_path
			tool_rec.task_status = "running"
			M.update_task_status(buf, tool_rec, "running", nil, config)
			if config and config.ui and config.ui.auto_scroll then
				M.scroll_to_bottom(buf)
			end
			return
		else
			local code_str = output and output:match("exited with code%s+(%d+)")
			local exit_code = tonumber(code_str) or 0
			local status = (exit_code == 0) and "success" or "failed"
			tool_rec.is_background_task = false
			M.update_task_status(buf, tool_rec, status, exit_code, config)
			if config and config.ui and config.ui.auto_scroll then
				M.scroll_to_bottom(buf)
			end
			return
		end
	end

	local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, tool_rec.header_extmark_id, {})
	local tool_line = (pos and #pos >= 1) and pos[1] or tool_rec.header_line_idx

	local badge = (duration_seconds and duration_seconds > 0)
			and string.format(" %s", utils.format_duration(duration_seconds))
		or ""

	pcall(function()
		local s_col, e_col = nil, nil
		local line_str = vim.api.nvim_buf_get_lines(buf, tool_line, tool_line + 1, false)[1]
		if line_str and tool_rec.tool_name then
			s_col, e_col = line_str:find(tool_rec.tool_name, 1, true)
		end
		local opts = {
			id = tool_rec.header_extmark_id,
			virt_text = (badge ~= "") and { { badge, "AgyToolBadge" } } or {},
			virt_text_pos = "eol",
		}
		if s_col and e_col then
			opts.end_col = e_col
			opts.hl_group = "AgyToolHeader"
			opts.priority = 150
			vim.api.nvim_buf_set_extmark(buf, M.NS_UI, tool_line, s_col - 1, opts)
		else
			vim.api.nvim_buf_set_extmark(buf, M.NS_UI, tool_line, 0, opts)
		end
	end)

	if config and config.ui and config.ui.auto_scroll then
		M.scroll_to_bottom(buf)
	end

	if tool_rec.is_open then
		M.refresh_tool_window(nil, tool_rec, false)
	end
end

---Get effective output text for a tool call (reading from log_path for background tasks if available)
---@param tc table
---@return string output
function M.get_tool_output(tc)
	if not tc then
		return ""
	end

	local log_path = tc.log_path
	if (tc.tool_name == "run_command" or tc.name == "run_command") and not log_path and tc.output then
		local tasks_mod = require("agy.tasks")
		local info = tasks_mod.parse_task_info(tc.output, tc.params)
		if info and info.log_path then
			log_path = info.log_path
			tc.log_path = log_path
			tc.is_background_task = true
			tc.task_id = info.task_id
			tc.short_id = info.short_id
		end
	end

	if log_path and vim.fn.filereadable(log_path) == 1 then
		local ok, lines = pcall(vim.fn.readfile, log_path)
		if ok and lines and #lines > 0 then
			if #lines > 5000 then
				local sliced = {}
				for i = #lines - 4999, #lines do
					table.insert(sliced, lines[i])
				end
				lines = sliced
			end
			local content = table.concat(lines, "\n")
			if utils.trim(content) ~= "" then
				return content
			end
		end
	end

	return tc.output or ""
end

---Stop live task log polling timer
---@param tc table
function M.stop_task_log_watcher(tc)
	if tc and tc.log_timer then
		local timer = tc.log_timer
		tc.log_timer = nil
		pcall(function()
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
		end)
	end
end

---Resolve the text to display inside the inline details window for a tool call or thought.
---If the tool is running and has no output yet, returns an informative running notice.
---If completed with no output, returns "(No output)" or "(Empty thought)".
---@param tc table
---@return string
local function resolve_display_output(tc)
	local raw_out = M.get_tool_output(tc)
	local is_bg_running = (tc.task_status == "running" or tc.is_background_task)
	if raw_out == "" or (is_bg_running and raw_out:find("^Tool is running as a background task")) then
		if tc.status == "running" or is_bg_running then
			if tc.is_thought then
				return "(Thinking...)"
			elseif tc.is_background_task or tc.log_path then
				return "(Running... waiting for task output)"
			else
				return "(Running...)"
			end
		else
			if tc.is_thought then
				return "(Empty thought)"
			else
				return "(No output)"
			end
		end
	end
	return raw_out
end

---Synchronize floating window position and visibility with target window buffer scrolling
---@param state? table
---@param tc table
function M.sync_tool_window_position(state, tc)
	if not tc or not tc.is_open or not tc.win or not vim.api.nvim_win_is_valid(tc.win) then
		return
	end

	local buf = tc.buf or (state and state.buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local target_win = tc.target_win
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		target_win = vim.fn.bufwinid(buf)
	end
	if not target_win or not vim.api.nvim_win_is_valid(target_win) or vim.api.nvim_win_get_buf(target_win) ~= buf then
		return
	end

	local header_row = tc.header_line_idx
	if tc.header_extmark_id then
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, tc.header_extmark_id, {})
		if pos and #pos >= 1 then
			header_row = pos[1]
			tc.header_line_idx = header_row
		end
	end
	if not header_row then
		return
	end

	local line_str = vim.api.nvim_buf_get_lines(buf, header_row, header_row + 1, false)[1] or ""
	local search_name = tc.is_thought and "Thought" or tc.tool_name
	local s_col = line_str:find(search_name, 1, true) or 1

	local sp_start
	local sp_end
	pcall(function()
		sp_start = vim.fn.screenpos(target_win, header_row + 1, s_col)
		sp_end = vim.fn.screenpos(target_win, header_row + 1, math.max(1, #line_str))
	end)

	local win_info = vim.fn.getwininfo(target_win)[1]
	if not win_info or not sp_start or not sp_end then
		return
	end

	local parent_height = vim.api.nvim_win_get_height(target_win)
	local parent_width = vim.api.nvim_win_get_width(target_win)
	local cur_cfg = vim.api.nvim_win_get_config(tc.win)

	local new_col = sp_start.col - win_info.wincol
	local new_row = sp_end.row - win_info.winrow + 2
	local avail_h = parent_height - new_row

	-- If off-screen, hide the floating window
	if sp_end.row <= 0 or sp_end.col <= 0 or sp_start.row <= 0 or sp_start.col <= 0 or new_row >= parent_height or avail_h <= 0 or new_col < 0 or new_col >= parent_width then
		pcall(vim.api.nvim_win_set_config, tc.win, {
			relative = "win",
			win = target_win,
			row = cur_cfg.row or 0,
			col = cur_cfg.col or 0,
			hide = true,
		})
		return
	end

	local max_w = parent_width - new_col
	local width = (max_w > 1) and (max_w - 1) or math.max(1, max_w)

	local cfg = get_config(state and state.config)
	local max_height = (cfg.ui and cfg.ui.tool_max_height) or 20
	local lines_count = tc.output_lines_count or (tc.win_buf and vim.api.nvim_buf_is_valid(tc.win_buf) and vim.api.nvim_buf_line_count(tc.win_buf)) or 1
	local height = math.min(max_height, math.max(1, lines_count))
	if avail_h > 0 and avail_h < height then
		height = math.max(1, avail_h)
	end

	pcall(vim.api.nvim_win_set_config, tc.win, {
		relative = "win",
		win = target_win,
		row = new_row,
		col = new_col,
		width = width,
		height = height,
		hide = false,
	})
end

---Refresh the contents, virtual lines, and position of an active inline tool window
---@param state? table
---@param tc table
---@param force_scroll_bottom? boolean
function M.refresh_tool_window(state, tc, force_scroll_bottom)
	if not tc or not tc.is_open or not tc.win or not vim.api.nvim_win_is_valid(tc.win) then
		return
	end
	if not tc.win_buf or not vim.api.nvim_buf_is_valid(tc.win_buf) then
		return
	end

	local buf = tc.buf or (state and state.buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local raw_out = resolve_display_output(tc)
	if raw_out == "" then
		return
	end

	local raw_lines = utils.split_lines(raw_out)
	local trimmed_lines = M.trim_empty_lines(raw_lines)
	local win_lines = (#trimmed_lines > 0) and trimmed_lines or { "" }
	tc.output_lines_count = #win_lines

	-- Check if buffer content changed
	local cur_lines = vim.api.nvim_buf_get_lines(tc.win_buf, 0, -1, false)
	local changed = (#cur_lines ~= #win_lines)
	if not changed then
		for i = 1, #win_lines do
			if cur_lines[i] ~= win_lines[i] then
				changed = true
				break
			end
		end
	end

	if not changed then
		M.sync_tool_window_position(state, tc)
		return
	end

	vim.bo[tc.win_buf].modifiable = true
	vim.api.nvim_buf_set_lines(tc.win_buf, 0, -1, false, win_lines)
	vim.bo[tc.win_buf].modifiable = false

	local target_win = tc.target_win
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		target_win = vim.fn.bufwinid(buf)
	end
	local parent_width = (target_win and vim.api.nvim_win_is_valid(target_win)) and vim.api.nvim_win_get_width(target_win) or 80
	local cfg = get_config(state and state.config)
	local max_height = (cfg.ui and cfg.ui.tool_max_height) or 20
	local height = math.min(max_height, math.max(1, #win_lines))

	-- Update virtual text spacer
	local total_width = math.max(M.get_max_window_width(buf), parent_width)
	local text_hl = tc.is_thought and "AgyThoughtOutput" or "AgyToolOutput"

	local header_row = tc.header_line_idx
	if tc.header_extmark_id then
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, tc.header_extmark_id, {})
		if pos and #pos >= 1 then
			header_row = pos[1]
			tc.header_line_idx = header_row
		end
	end

	local line_str = vim.api.nvim_buf_get_lines(buf, header_row, header_row + 1, false)[1] or ""
	local search_name = tc.is_thought and "Thought" or tc.tool_name
	local s_col = line_str:find(search_name, 1, true) or 1
	local prefix = line_str:sub(1, s_col - 1)
	local display_col = vim.fn.strdisplaywidth(prefix)
	local prefix_pad = string.rep(" ", display_col)

	local virt_lines = {}
	table.insert(virt_lines, {
		{ string.rep(" ", total_width), "AgyToolInline" },
	})
	for i = 1, height do
		local line_text = win_lines[i] or ""
		if line_text == "" then
			table.insert(virt_lines, {
				{ string.rep(" ", total_width), "AgyToolInline" },
			})
		else
			local used_w = display_col + vim.fn.strdisplaywidth(line_text)
			local trailing_len = math.max(0, total_width - used_w)
			local chunks = {}
			if #prefix_pad > 0 then
				table.insert(chunks, { prefix_pad, "AgyToolInline" })
			end
			table.insert(chunks, { line_text, text_hl })
			if trailing_len > 0 then
				table.insert(chunks, { string.rep(" ", trailing_len), "AgyToolInline" })
			end
			table.insert(virt_lines, chunks)
		end
	end
	table.insert(virt_lines, {
		{ string.rep(" ", total_width), "AgyToolInline" },
	})

	if state and state.footer_extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, M.NS_UI, state.footer_extmark_id)
		state.footer_extmark_id = nil
	end

	if tc.spacer_extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, M.NS_SPACER, tc.spacer_extmark_id)
	end
	tc.spacer_extmark_id = vim.api.nvim_buf_set_extmark(buf, M.NS_SPACER, header_row, 0, {
		virt_lines = virt_lines,
		virt_lines_above = false,
		right_gravity = false,
	})

	local protocol = package.loaded["agy.protocol"]
	if protocol and protocol.update_footer then
		protocol.update_footer(buf)
	end

	M.sync_tool_window_position(state, tc)

	local should_scroll = force_scroll_bottom or tc.tool_name == "run_command" or tc.is_background_task
	if vim.api.nvim_get_current_win() == tc.win then
		local cur_pos = vim.api.nvim_win_get_cursor(tc.win)
		if cur_pos[1] < #cur_lines - 1 then
			should_scroll = false
		end
	end
	if should_scroll then
		pcall(vim.api.nvim_win_set_cursor, tc.win, { #win_lines, 0 })
	end
end

---Start live task log polling timer for running background task
---@param state? table
---@param tc table
function M.start_task_log_watcher(state, tc)
	M.stop_task_log_watcher(tc)
	if not tc or not tc.log_path then
		return
	end
	if tc.task_status and tc.task_status ~= "running" then
		return
	end

	local proto = package.loaded["agy.protocol"]
	state = state or (tc.buf and proto and proto.buffers and proto.buffers[tc.buf])

	local timer = (vim.uv and vim.uv.new_timer) and vim.uv.new_timer() or vim.loop.new_timer()
	tc.log_timer = timer

	timer:start(
		250,
		250,
		vim.schedule_wrap(function()
			if not tc.is_open or not tc.win or not vim.api.nvim_win_is_valid(tc.win) then
				M.stop_task_log_watcher(tc)
				return
			end
			M.refresh_tool_window(state, tc, false)

			-- Check if task finished in log file or transcript
			if tc.task_status == "running" and tc.log_path and vim.fn.filereadable(tc.log_path) == 1 then
				local ok, lines = pcall(vim.fn.readfile, tc.log_path)
				if ok and lines and #lines > 0 then
					local last_chunk = table.concat(lines, "\n", math.max(1, #lines - 20))
					local tasks_mod = require("agy.tasks")
					local code = tasks_mod.parse_log_exit_code(last_chunk)
					if code ~= nil then
						local status = (code == 0) and "success" or "failed"
						local buf = tc.buf or (state and state.buf)
						if buf and vim.api.nvim_buf_is_valid(buf) then
							M.update_task_status(buf, tc, status, code, state and state.config)
						else
							tc.task_status = status
							tc.exit_code = code
						end
						if state then
							state.reengage_follow_bottom = true
							state.had_background_task = true
						end
					end
				end
			end

			if tc.task_status == "running" and state then
				local conv_id = state.conversation_id
				if conv_id and conv_id ~= "" and conv_id ~= "new" then
					local tasks_mod = require("agy.tasks")
					local transcript_mod = require("agy.transcript")
					local app_dir = state.config and state.config.app_data_dir
					local steps = transcript_mod.read_transcript(conv_id, app_dir)
					local outcomes = tasks_mod.collect_task_outcomes(steps)
					local outcome = nil
					if tc.task_id then
						outcome = outcomes[tc.task_id]
					end
					if not outcome and tc.short_id then
						outcome = outcomes[tc.short_id]
					end
					if outcome then
						local buf = tc.buf or state.buf
						if buf and vim.api.nvim_buf_is_valid(buf) then
							M.update_task_status(buf, tc, outcome.status, outcome.exit_code, state.config)
						else
							tc.task_status = outcome.status
							tc.exit_code = outcome.exit_code
						end
						state.reengage_follow_bottom = true
						state.had_background_task = true
					end
				end
			end

			if tc.task_status and tc.task_status ~= "running" then
				M.stop_task_log_watcher(tc)
			end
		end)
	)
end

---Close inline tool window for a tool call
---@param state? table
---@param tc? table
function M.close_tool_window(state, tc)
	tc = tc or (state and state.active_tool_call)
	if not tc then
		return
	end

	M.stop_task_log_watcher(tc)

	if tc.scroll_autocmd then
		pcall(vim.api.nvim_del_autocmd, tc.scroll_autocmd)
		tc.scroll_autocmd = nil
	end

	if tc.cursor_autocmd then
		pcall(vim.api.nvim_del_autocmd, tc.cursor_autocmd)
		tc.cursor_autocmd = nil
	end

	local buf = tc.buf or (state and state.buf)
	if buf and vim.api.nvim_buf_is_valid(buf) and tc.spacer_extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, M.NS_SPACER, tc.spacer_extmark_id)
		local protocol = package.loaded["agy.protocol"]
		if protocol and protocol.update_footer then
			protocol.update_footer(buf)
		end
	end
	tc.spacer_extmark_id = nil
	tc.buf = nil

	if tc.win and vim.api.nvim_win_is_valid(tc.win) then
		pcall(vim.api.nvim_win_close, tc.win, true)
	end
	if tc.win_buf and vim.api.nvim_buf_is_valid(tc.win_buf) then
		pcall(vim.api.nvim_buf_delete, tc.win_buf, { force = true })
	end

	tc.win = nil
	tc.win_buf = nil
	tc.is_open = false

	if state and state.active_tool_call == tc then
		state.active_tool_call = nil
	end
end

---Toggle display of a tool call's output in an inline window
---@param buf number
---@param state table
---@param tc table
---@param target_win? number Specific window where cursor triggered the action
---@return boolean success
function M.toggle_tool_output(buf, state, tc, target_win)
	-- If this tool's window is already open, close it
	if tc.is_open then
		M.close_tool_window(state, tc)
		return true
	end

	-- If another tool's window is open, close that one first
	if state and state.active_tool_call and state.active_tool_call ~= tc then
		M.close_tool_window(state, state.active_tool_call)
	end

	local raw_out = resolve_display_output(tc)

	local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, tc.header_extmark_id, {})
	if not pos or #pos < 1 then
		return false
	end
	local header_row = pos[1]
	tc.header_line_idx = header_row

	local raw_lines = utils.split_lines(raw_out)
	local trimmed_lines = M.trim_empty_lines(raw_lines)
	local win_lines = (#trimmed_lines > 0) and trimmed_lines or { "" }
	tc.output_lines_count = #win_lines

	local cur_win = vim.api.nvim_get_current_win()
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		if vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win) == buf then
			target_win = cur_win
		else
			target_win = vim.fn.bufwinid(buf)
		end
	end
	if target_win == -1 or not vim.api.nvim_win_is_valid(target_win) then
		target_win = cur_win
	end
	tc.target_win = target_win
	tc.buf = buf

	local line_str = vim.api.nvim_buf_get_lines(buf, header_row, header_row + 1, false)[1] or ""
	local search_name = tc.is_thought and "Thought" or tc.tool_name
	local s_col = line_str:find(search_name, 1, true)
	assert(s_col, "Tool name '" .. tostring(search_name) .. "' not found in header line")

	local prefix = line_str:sub(1, s_col - 1)
	local display_col = vim.fn.strdisplaywidth(prefix)
	local prefix_pad = string.rep(" ", display_col)
	local text_hl = tc.is_thought and "AgyThoughtOutput" or "AgyToolOutput"

	local cfg = get_config(state and state.config)
	local max_height = (cfg.ui and cfg.ui.tool_max_height) or 20
	local height = math.min(max_height, math.max(1, #win_lines))

	local parent_width = vim.api.nvim_win_get_width(target_win)
	local parent_height = vim.api.nvim_win_get_height(target_win)

	local sp_start
	local sp_end
	if target_win and vim.api.nvim_win_is_valid(target_win) and vim.api.nvim_win_get_buf(target_win) == buf then
		pcall(function()
			sp_start = vim.fn.screenpos(target_win, header_row + 1, s_col)
			sp_end = vim.fn.screenpos(target_win, header_row + 1, math.max(1, #line_str))
		end)
	end
	local win_info = (target_win and vim.api.nvim_win_is_valid(target_win)) and vim.fn.getwininfo(target_win)[1]

	-- Scroll target window if needed so the tool details window (+ 1 extra line) is in view
	if sp_end and sp_end.row > 0 and sp_start and sp_start.row > 0 and win_info and vim.api.nvim_win_get_buf(target_win) == buf then
		local header_win_row = sp_end.row - win_info.winrow + 1
		local first_header_win_row = sp_start.row - win_info.winrow + 1
		-- Block requires: header line(s), 1 top padding virt line, height float lines, 1 bottom padding virt line, and 1 extra line
		local required_bottom_row = header_win_row + height + 3
		local overflow = required_bottom_row - parent_height
		if overflow > 0 then
			local max_scroll = math.max(0, first_header_win_row - 1)
			local scroll_lines = math.min(overflow, max_scroll)
			if scroll_lines > 0 then
				local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
				vim.api.nvim_win_call(target_win, function()
					vim.cmd("normal! " .. scroll_lines .. ctrl_e)
				end)
				win_info = vim.fn.getwininfo(target_win)[1]
				pcall(function()
					sp_start = vim.fn.screenpos(target_win, header_row + 1, s_col)
					sp_end = vim.fn.screenpos(target_win, header_row + 1, math.max(1, #line_str))
				end)
			end
		end
	end

	local win_col
	local win_row
	if sp_start and sp_start.col > 0 and sp_end and sp_end.row > 0 and win_info and vim.api.nvim_win_get_buf(target_win) == buf then
		win_col = sp_start.col - win_info.wincol
		win_row = sp_end.row - win_info.winrow + 2
	else
		local textoff = win_info and win_info.textoff or 0
		win_col = display_col + textoff
		local topline = win_info and win_info.topline or 1
		win_row = header_row - (topline - 1) + 2
	end

	local max_w = parent_width - win_col
	local width = (max_w > 1) and (max_w - 1) or math.max(1, max_w)

	if parent_height and parent_height > win_row then
		local avail_h = parent_height - win_row - 1
		if avail_h > 0 and avail_h < height then
			height = math.max(1, avail_h)
		end
	end

	local total_width = math.max(M.get_max_window_width(buf), parent_width)

	-- Place virtual text lines in buffer: top padding line, content lines, bottom padding line
	local virt_lines = {}
	-- 1. Top virtual padding line
	table.insert(virt_lines, {
		{ string.rep(" ", total_width), "AgyToolInline" },
	})
	-- 2. Content lines matching inline window
	for i = 1, height do
		local line_text = win_lines[i] or ""
		if line_text == "" then
			table.insert(virt_lines, {
				{ string.rep(" ", total_width), "AgyToolInline" },
			})
		else
			local used_w = display_col + vim.fn.strdisplaywidth(line_text)
			local trailing_len = math.max(0, total_width - used_w)
			local chunks = {}
			if #prefix_pad > 0 then
				table.insert(chunks, { prefix_pad, "AgyToolInline" })
			end
			table.insert(chunks, { line_text, text_hl })
			if trailing_len > 0 then
				table.insert(chunks, { string.rep(" ", trailing_len), "AgyToolInline" })
			end
			table.insert(virt_lines, chunks)
		end
	end
	-- 3. Bottom virtual padding line
	table.insert(virt_lines, {
		{ string.rep(" ", total_width), "AgyToolInline" },
	})

	if state and state.footer_extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, buf, M.NS_UI, state.footer_extmark_id)
		state.footer_extmark_id = nil
	end

	tc.spacer_extmark_id = vim.api.nvim_buf_set_extmark(buf, M.NS_SPACER, header_row, 0, {
		virt_lines = virt_lines,
		virt_lines_above = false,
		right_gravity = false,
	})

	local protocol = package.loaded["agy.protocol"]
	if protocol and protocol.update_footer then
		protocol.update_footer(buf)
	end

	local win_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[win_buf].buftype = "nofile"
	vim.bo[win_buf].bufhidden = "wipe"
	vim.bo[win_buf].swapfile = false

	vim.api.nvim_buf_set_lines(win_buf, 0, -1, false, win_lines)
	vim.bo[win_buf].modifiable = false

	if tc.is_thought then
		vim.bo[win_buf].filetype = "markdown"
		for i = 0, #win_lines - 1 do
			pcall(vim.api.nvim_buf_set_extmark, win_buf, M.NS_UI, i, 0, {
				end_col = #win_lines[i + 1],
				hl_group = "AgyThoughtOutput",
				priority = 120,
			})
		end
	else
		local lang = M.detect_codeblock_lang(tc.tool_name, tc.params, raw_out)
		if lang and lang ~= "" then
			vim.bo[win_buf].filetype = lang
			pcall(vim.treesitter.start, win_buf, lang)
		else
			vim.bo[win_buf].filetype = "markdown"
		end
	end

	local win_cfg = {
		relative = "win",
		win = target_win,
		row = win_row,
		col = win_col,
		width = width,
		height = height,
		style = "minimal",
		border = "none",
		focusable = true,
		zindex = 150,
	}

	local win = vim.api.nvim_open_win(win_buf, true, win_cfg)
	vim.wo[win].wrap = (cfg.ui and cfg.ui.wrap ~= nil) and cfg.ui.wrap or false
	vim.wo[win].cursorline = false
	vim.wo[win].winhighlight = "Normal:AgyToolInline,NormalFloat:AgyToolInline"

	local initial_cursor_row = (tc.tool_name == "run_command" or tc.is_background_task) and #win_lines or 1
	pcall(vim.api.nvim_win_set_cursor, win, { initial_cursor_row, 0 })

	tc.is_open = true
	tc.win = win
	tc.win_buf = win_buf
	if state then
		state.active_tool_call = tc
	end

	if tc.is_background_task or tc.log_path then
		M.start_task_log_watcher(state, tc)
	end

	local function close_self()
		M.close_tool_window(state, tc)
		if target_win and vim.api.nvim_win_is_valid(target_win) then
			vim.api.nvim_set_current_win(target_win)
			if header_row then
				pcall(vim.api.nvim_win_set_cursor, target_win, { header_row + 1, 0 })
			end
		end
	end

	for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
		vim.keymap.set("n", key, close_self, {
			buffer = win_buf,
			silent = true,
			nowait = true,
			desc = "Close tool details inline window",
		})
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if tc.is_open then
				M.close_tool_window(state, tc)
			end
		end,
	})

	tc.cursor_autocmd = vim.api.nvim_create_autocmd({ "CursorMoved" }, {
		buffer = buf,
		callback = function()
			if tc.is_open and vim.api.nvim_get_current_win() == target_win then
				local crow = vim.api.nvim_win_get_cursor(target_win)[1] - 1
				if crow ~= header_row then
					M.close_tool_window(state, tc)
				end
			end
		end,
	})

	tc.scroll_autocmd = vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
		pattern = "*",
		callback = function()
			if tc.is_open then
				M.sync_tool_window_position(state, tc)
			end
		end,
	})

	return true
end

---Parse questions from ask_question tool parameters
---@param params? table
---@return table[] list of { question: string, options: string[], is_multi_select: boolean }
function M.parse_question_params(params)
	if not params or type(params) ~= "table" then
		return {}
	end

	local raw_q = params.questions
	if type(raw_q) == "string" then
		local decoded, _ = utils.json_decode(raw_q)
		if type(decoded) == "table" then
			raw_q = decoded
		end
	end

	if type(raw_q) ~= "table" then
		return {}
	end

	local questions = {}
	for _, item in ipairs(raw_q) do
		if type(item) == "table" and item.question then
			local opts = {}
			if type(item.options) == "table" then
				for _, opt in ipairs(item.options) do
					table.insert(opts, tostring(opt))
				end
			end
			table.insert(questions, {
				question = tostring(item.question),
				options = opts,
				is_multi_select = (item.is_multi_select == true or item.IsMultiSelect == true),
			})
		end
	end

	return questions
end

---Render an active question block directly into the buffer
---@param buf number
---@param question_list table[] parsed question items
---@param config table
---@return table active_question state table
function M.render_question_block(buf, question_list, config)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""

	local to_append = {}
	if last_line ~= "" then
		table.insert(to_append, "")
	end

	local start_line = line_count + #to_append + 1
	local questions_meta = {}
	local header_lines = {}

	local q_icon = get_icon("question", config)
	for q_idx, q in ipairs(question_list) do
		local header_text = (#question_list > 1) and string.format("%s Question %d: %s", q_icon, q_idx, q.question)
			or string.format("%s Question: %s", q_icon, q.question)

		table.insert(to_append, header_text)
		table.insert(header_lines, line_count + #to_append)
		table.insert(to_append, "")

		local opt_start = line_count + #to_append + 1
		for _, opt in ipairs(q.options) do
			table.insert(to_append, string.format("- [ ] %s", opt))
		end
		local opt_end = line_count + #to_append

		table.insert(questions_meta, {
			question = q.question,
			options = q.options,
			is_multi_select = q.is_multi_select,
			options_start_line = opt_start,
			options_end_line = opt_end,
		})

		if q_idx < #question_list then
			table.insert(to_append, "")
		end
	end

	table.insert(to_append, "")
	table.insert(to_append, "Write-in / Notes:")
	local write_in_header_line = line_count + #to_append
	table.insert(to_append, "")
	local write_in_start_line = line_count + #to_append

	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, to_append)
	vim.bo[buf].modified = false

	-- Add highlights for question headers
	for _, h_line in ipairs(header_lines) do
		local text = vim.api.nvim_buf_get_lines(buf, h_line - 1, h_line, false)[1] or ""
		if text ~= "" then
			pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_UI, h_line - 1, 0, {
				end_col = #text,
				hl_group = "AgyQuestionHeader",
				priority = 100,
			})
		end
	end

	local first_opt_line = (questions_meta[1] and questions_meta[1].options_start_line) or start_line

	local active_question = {
		start_line = start_line,
		first_option_line = first_opt_line,
		questions = questions_meta,
		write_in_header_line = write_in_header_line,
		write_in_start_line = write_in_start_line,
	}

	return active_question
end

---Context-sensitive toggle for question options on <CR>
---@param buf number
---@param cursor_line number 1-indexed line number of cursor
---@param active_question? table
---@return boolean handled
function M.toggle_question_option(buf, cursor_line, active_question)
	if not active_question or not active_question.questions then
		return false
	end

	for _, q in ipairs(active_question.questions) do
		if cursor_line >= q.options_start_line and cursor_line <= q.options_end_line then
			local line_text = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or ""
			local is_checked, opt_text = line_text:match("^>?%s*-?%s*%[([ x])]%s*(.*)$")
			if is_checked then
				local prev_mod = vim.bo[buf].modifiable
				vim.bo[buf].modifiable = true
				if q.is_multi_select then
					-- Multi-select: toggle current option
					local new_mark = (is_checked == "x") and "[ ]" or "[x]"
					vim.api.nvim_buf_set_lines(buf, cursor_line - 1, cursor_line, false, {
						string.format("- %s %s", new_mark, opt_text),
					})
				else
					-- Single-select (radio button behavior):
					if is_checked == "x" then
						vim.api.nvim_buf_set_lines(buf, cursor_line - 1, cursor_line, false, {
							string.format("- [ ] %s", opt_text),
						})
					else
						local start_idx = q.options_start_line - 1
						local end_idx = q.options_end_line
						local lines = vim.api.nvim_buf_get_lines(buf, start_idx, end_idx, false)
						for i, l in ipairs(lines) do
							local cur_l_num = q.options_start_line + i - 1
							local _, text = l:match("^>?%s*-?%s*%[([ x])]%s*(.*)$")
							if text then
								if cur_l_num == cursor_line then
									lines[i] = string.format("- [x] %s", text)
								else
									lines[i] = string.format("- [ ] %s", text)
								end
							end
						end
						vim.api.nvim_buf_set_lines(buf, start_idx, end_idx, false, lines)
					end
				end
				vim.bo[buf].modifiable = prev_mod
				vim.bo[buf].modified = false
				return true
			end
		end
	end

	return false
end

---Extract user answer from active question block
---@param buf number
---@param active_question table
---@return string? answer_payload
---@return boolean has_answer
function M.extract_question_answer(buf, active_question)
	if not active_question or not active_question.questions then
		return nil, false
	end

	local answers = {}
	local total_selected = 0

	for q_idx, q in ipairs(active_question.questions) do
		local selected_for_q = {}
		local lines = vim.api.nvim_buf_get_lines(buf, q.options_start_line - 1, q.options_end_line, false)
		for _, l in ipairs(lines) do
			local check, opt_text = l:match("^>?%s*-?%s*%[([ x])]%s*(.*)$")
			if check == "x" and opt_text and opt_text ~= "" then
				table.insert(selected_for_q, utils.trim(opt_text))
			end
		end

		if #selected_for_q > 0 then
			total_selected = total_selected + #selected_for_q
			local prefix = (#active_question.questions > 1) and string.format("A%d: ", q_idx) or "A: "
			if #selected_for_q == 1 then
				table.insert(answers, prefix .. selected_for_q[1])
			else
				table.insert(answers, prefix .. "\n- " .. table.concat(selected_for_q, "\n- "))
			end
		end
	end

	-- Extract write-in notes
	local line_count = vim.api.nvim_buf_line_count(buf)
	local write_in_text = ""
	if line_count >= active_question.write_in_start_line then
		local note_lines = vim.api.nvim_buf_get_lines(buf, active_question.write_in_start_line - 1, line_count, false)
		write_in_text = utils.trim(table.concat(note_lines, "\n"))
	end

	local has_answer = (total_selected > 0) or (write_in_text ~= "")
	if not has_answer then
		return nil, false
	end

	local parts = {}
	if #answers > 0 then
		table.insert(parts, table.concat(answers, "\n\n"))
	end

	if write_in_text ~= "" then
		if #parts > 0 then
			table.insert(parts, "Notes: " .. write_in_text)
		else
			table.insert(parts, write_in_text)
		end
	end

	return table.concat(parts, "\n\n"), true
end

---Finalize the question block into read-only history
---@param buf number
---@param active_question table
---@param config table
function M.finalize_question_block(buf, active_question, config)
	vim.bo[buf].modified = false
end

---Finalize turn response when result event arrives
---@param buf number
---@param agent_extmark_id number
---@param agent_line number
---@param result table
---@param config table
---@return number next_prompt_line 1-indexed line of new prompt
---@return number next_prompt_extmark_id
function M.finalize_turn(buf, agent_extmark_id, agent_line, result, config)
	M.stop_thinking_animation(buf)
	M.append_text_delta(buf, "", config, true)
	local stats = {}
	if result.duration_seconds and result.duration_seconds > 0 then
		table.insert(stats, utils.format_duration(result.duration_seconds))
	end
	if result.usage and result.usage.total_tokens and result.usage.total_tokens > 0 then
		table.insert(stats, utils.format_tokens(result.usage.total_tokens))
	end

	local done_icon = get_icon("done", config)
	local badge_text = #stats > 0 and string.format(" [%s %s]", done_icon, table.concat(stats, " • "))
		or string.format(" [%s]", done_icon)
	local badge_hl = (result.status == "ERROR") and "AgyBadgeError" or "AgyBadgeDone"

	-- Update agent divider
	local target_agent_row = agent_line
	if agent_extmark_id then
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, agent_extmark_id, {})
		if pos and #pos >= 1 then
			target_agent_row = pos[1]
		end
	end
	pcall(function()
		M.set_divider(buf, target_agent_row, "agent", badge_text, badge_hl, false, agent_extmark_id, config)
	end)

	-- Append blank line for next user prompt if not already present
	local boundary_row = M.get_agent_boundary(buf, target_agent_row)
	if boundary_row then
		local prompt_marks = vim.api.nvim_buf_get_extmarks(buf, M.NS_UI, { boundary_row, 0 }, { -1, -1 }, { details = true })
		local existing_prompt_ext = nil
		local existing_prompt_row = nil
		for _, em in ipairs(prompt_marks) do
			if em[4].sign_hl_group == "AgyUserSign" or em[4].number_hl_group == "AgyPromptArea" then
				existing_prompt_ext = em[1]
				existing_prompt_row = em[2]
				break
			end
		end

		if existing_prompt_ext and existing_prompt_row then
			local next_prompt_line = existing_prompt_row + 1
			M.apply_history_highlights(buf, next_prompt_line, config)
			M.apply_prompt_highlights(buf, next_prompt_line, config)
			vim.bo[buf].modified = false
			pcall(function()
				vim.cmd("let &undolevels = &undolevels")
			end)
			return next_prompt_line, existing_prompt_ext
		end
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
	local to_append = {}
	if last_line ~= "" then
		table.insert(to_append, "")
	end
	table.insert(to_append, "")

	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, to_append)
	local next_prompt_line = vim.api.nvim_buf_line_count(buf)

	-- Place active prompt divider above the new line with sign
	local prompt_extmark_id = M.set_divider(buf, next_prompt_line - 1, "user", nil, nil, true, nil, config)

	-- Apply background tint to history
	M.apply_history_highlights(buf, next_prompt_line, config)

	-- Apply prompt area highlight
	M.apply_prompt_highlights(buf, next_prompt_line, config)

	vim.bo[buf].modified = false
	pcall(function()
		vim.cmd("let &undolevels = &undolevels")
	end)

	return next_prompt_line, prompt_extmark_id
end

---Render an error message
---@param buf number
---@param err_message string
---@param config table
---@return number next_prompt_line
---@return number next_prompt_extmark_id
function M.render_error(buf, err_message, config)
	M.stop_thinking_animation(buf)
	local err_icon = get_icon("error", config)
	local err_text = string.format("%s Error: %s", err_icon, err_message)

	local boundary_row = M.get_agent_boundary(buf)
	if boundary_row then
		local sep_row = boundary_row - 1
		local insert_lines = { "", err_text }
		vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, insert_lines)
		local err_line = sep_row + 1
		pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_UI, err_line, 0, {
			end_col = #err_text,
			hl_group = "AgyBadgeError",
			priority = 100,
		})

		local prompt_marks = vim.api.nvim_buf_get_extmarks(buf, M.NS_UI, { err_line, 0 }, { -1, -1 }, { details = true })
		local existing_prompt_ext = nil
		local existing_prompt_row = nil
		for _, em in ipairs(prompt_marks) do
			if em[4].sign_hl_group == "AgyUserSign" or em[4].number_hl_group == "AgyPromptArea" then
				existing_prompt_ext = em[1]
				existing_prompt_row = em[2]
				break
			end
		end

		if existing_prompt_ext and existing_prompt_row then
			local next_prompt_line = existing_prompt_row + 1
			M.apply_history_highlights(buf, next_prompt_line, config)
			M.apply_prompt_highlights(buf, next_prompt_line, config)
			vim.bo[buf].modified = false
			return next_prompt_line, existing_prompt_ext
		end
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local to_append = {
		"",
		err_text,
		"",
		"",
	}
	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, to_append)
	local err_line = line_count + 1
	pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_UI, err_line, 0, {
		end_col = #err_text,
		hl_group = "AgyBadgeError",
		priority = 100,
	})

	local next_prompt_line = vim.api.nvim_buf_line_count(buf)

	local prompt_extmark_id = M.set_divider(buf, next_prompt_line - 1, "user", nil, nil, true, nil, config)
	M.apply_history_highlights(buf, next_prompt_line, config)
	M.apply_prompt_highlights(buf, next_prompt_line, config)

	vim.bo[buf].modified = false
	return next_prompt_line, prompt_extmark_id
end

---Render a cancellation note
---@param buf number
---@param config table
---@return number next_prompt_line
---@return number next_prompt_extmark_id
function M.render_cancelled(buf, config)
	M.stop_thinking_animation(buf)

	local cancel_icon = get_icon("cancelled", config)
	local cancel_text = string.format("%s Turn cancelled", cancel_icon)

	local boundary_row = M.get_agent_boundary(buf)
	if boundary_row then
		local sep_row = boundary_row - 1
		local insert_lines = { "", cancel_text }
		vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, insert_lines)
		local cancel_line = sep_row + 1
		pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_UI, cancel_line, 0, {
			end_col = #cancel_text,
			hl_group = "Comment",
			priority = 100,
		})

		local prompt_marks = vim.api.nvim_buf_get_extmarks(buf, M.NS_UI, { cancel_line, 0 }, { -1, -1 }, { details = true })
		local existing_prompt_ext = nil
		local existing_prompt_row = nil
		for _, em in ipairs(prompt_marks) do
			if em[4].sign_hl_group == "AgyUserSign" or em[4].number_hl_group == "AgyPromptArea" then
				existing_prompt_ext = em[1]
				existing_prompt_row = em[2]
				break
			end
		end

		if existing_prompt_ext and existing_prompt_row then
			local next_prompt_line = existing_prompt_row + 1
			M.apply_history_highlights(buf, next_prompt_line, config)
			M.apply_prompt_highlights(buf, next_prompt_line, config)
			vim.bo[buf].modified = false
			return next_prompt_line, existing_prompt_ext
		end
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local to_append = {
		"",
		cancel_text,
		"",
		"",
	}
	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, to_append)
	local cancel_line = line_count + 1
	pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_UI, cancel_line, 0, {
		end_col = #cancel_text,
		hl_group = "Comment",
		priority = 100,
	})

	local next_prompt_line = vim.api.nvim_buf_line_count(buf)

	local prompt_extmark_id = M.set_divider(buf, next_prompt_line - 1, "user", nil, nil, true, nil, config)
	M.apply_history_highlights(buf, next_prompt_line, config)
	M.apply_prompt_highlights(buf, next_prompt_line, config)

	vim.bo[buf].modified = false
	return next_prompt_line, prompt_extmark_id
end

---Render a completed local command into the conversation history and prepare the next prompt line
---@param buf number
---@param command_text string The command text typed by user
---@param result_text? string Optional result / feedback message
---@param config table
---@param prompt_start_line number 1-indexed line where current prompt starts
---@param prompt_extmark_id? number
---@return number next_prompt_line 1-indexed line of new active prompt
---@return number next_prompt_extmark_id
function M.render_command_entry(buf, command_text, result_text, config, prompt_start_line, prompt_extmark_id)
	M.setup_highlights()

	-- 1. Archive the current user prompt divider as history (remove active sign)
	if prompt_extmark_id then
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, prompt_extmark_id, {})
		local target_row = (pos and #pos >= 1) and pos[1] or (prompt_start_line - 1)
		M.set_divider(buf, target_row, "user", nil, nil, false, prompt_extmark_id, config)
	else
		M.set_divider(buf, prompt_start_line - 1, "user", nil, nil, false, nil, config)
	end

	-- 2. Place command_text at prompt_start_line
	local cmd_lines = utils.split_lines(command_text)
	if #cmd_lines == 0 then
		cmd_lines = { command_text }
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	local end_line = math.max(prompt_start_line, line_count)
	vim.api.nvim_buf_set_lines(buf, prompt_start_line - 1, end_line, false, cmd_lines)

	-- 3. If result_text is provided, append it below the command
	if result_text and result_text ~= "" then
		local cur_count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, cur_count, cur_count, false, { "", result_text })
		local res_line = cur_count + 1
		pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_UI, res_line, 0, {
			end_col = #result_text,
			hl_group = "AgyBadgeDone",
			priority = 100,
		})
	end

	-- 4. Append blank line for the next user prompt
	local cur_count2 = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, cur_count2, cur_count2, false, { "", "" })

	local next_prompt_line = vim.api.nvim_buf_line_count(buf)

	-- 5. Place active prompt divider above the new prompt line with sign
	local next_prompt_extmark_id = M.set_divider(buf, next_prompt_line - 1, "user", nil, nil, true, nil, config)

	-- 6. Apply history background tint
	M.apply_history_highlights(buf, next_prompt_line, config)

	-- 7. Apply prompt area highlight
	M.apply_prompt_highlights(buf, next_prompt_line, config)

	vim.bo[buf].modified = false
	pcall(function()
		vim.cmd("let &undolevels = &undolevels")
	end)

	return next_prompt_line, next_prompt_extmark_id
end

---Render the queued messages block above the prompt divider
---@param buf number
---@param queue table[] Array of { id: number, text: string }
---@param prompt_start_line number 1-indexed line where active prompt begins
---@param config? table
---@return number next_prompt_start_line
function M.render_queue(buf, queue, prompt_start_line, config)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return prompt_start_line
	end

	local queue_icon = get_icon("queue", config)
	assert(queue_icon, "agy config: icon 'queue' is not defined in config.icons")

	-- Resolve actual prompt start line dynamically from prompt extmark if available
	local protocol = package.loaded["agy.protocol"]
	local state = protocol and protocol.buffers and protocol.buffers[buf]
	local actual_prompt_line = prompt_start_line
	if state and state.prompt_extmark_id then
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_UI, state.prompt_extmark_id, {})
		if pos and #pos >= 1 then
			actual_prompt_line = pos[1] + 1
		end
	else
		local ui_marks = vim.api.nvim_buf_get_extmarks(buf, M.NS_UI, 0, -1, { details = true })
		for _, m in ipairs(ui_marks) do
			if m[4].sign_hl_group == "AgyUserSign" or m[4].number_hl_group == "AgyPromptArea" then
				actual_prompt_line = m[2] + 1
				break
			end
		end
	end

	-- Find any existing queue lines in the buffer and delete them
	local line_count = vim.api.nvim_buf_line_count(buf)
	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, line_count, false)
	local q_start_idx = nil
	local last_queue_content_idx = nil
	for i = 1, #all_lines do
		local l = all_lines[i]
		if M.is_queue_header_line(l, config) then
			if not q_start_idx then
				q_start_idx = i - 1
			end
			last_queue_content_idx = i
		elseif q_start_idx and l:find("^%s%s%s") then
			last_queue_content_idx = i
		elseif q_start_idx and not l:find("^%s%s%s") then
			break
		end
	end

	local q_end_idx = nil
	if last_queue_content_idx then
		q_end_idx = last_queue_content_idx
		if q_end_idx < #all_lines and all_lines[q_end_idx + 1] == "" then
			q_end_idx = q_end_idx + 1
		end
	end

	-- Clear previous queue extmarks
	vim.api.nvim_buf_clear_namespace(buf, M.NS_QUEUE, 0, -1)

	local target_prompt_line = actual_prompt_line
	if q_start_idx and q_end_idx and q_end_idx > q_start_idx then
		vim.api.nvim_buf_set_lines(buf, q_start_idx, q_end_idx, false, {})
		target_prompt_line = q_start_idx + 1
	end
	target_prompt_line = math.max(1, target_prompt_line)

	if not queue or #queue == 0 then
		if prompt_ext_id then
			M.set_divider(buf, target_prompt_line - 1, "user", nil, nil, true, prompt_ext_id, config)
		end
		return target_prompt_line
	end

	local insert_row = target_prompt_line - 1

	local lines_to_insert = {}
	local extmark_info = {}

	for i, item in ipairs(queue) do
		local item_lines = utils.split_lines(item.text)
		local header_offset = #lines_to_insert
		local header = string.format("%s Queued #%d: %s", queue_icon, item.id or i, item_lines[1] or "")
		table.insert(lines_to_insert, header)
		for j = 2, #item_lines do
			table.insert(lines_to_insert, string.format("   %s", item_lines[j]))
		end
		table.insert(extmark_info, {
			offset = header_offset,
			line_count = #item_lines,
			item = item,
		})
	end
	table.insert(lines_to_insert, "")

	vim.api.nvim_buf_set_lines(buf, insert_row, insert_row, false, lines_to_insert)

	for _, info in ipairs(extmark_info) do
		local row = insert_row + info.offset
		local ext_id = vim.api.nvim_buf_set_extmark(buf, M.NS_QUEUE, row, 0, {
			virt_text = { { " [press <CR> to edit]", "AgyQueueBadge" } },
			virt_text_pos = "eol",
			line_hl_group = "AgyQueueHeader",
			priority = 180,
		})
		info.item.extmark_id = ext_id
		info.item.line_count = info.line_count
		info.item.header_row = row
	end

	local next_prompt_line = target_prompt_line + #lines_to_insert
	if prompt_ext_id then
		M.set_divider(buf, next_prompt_line - 1, "user", nil, nil, true, prompt_ext_id, config)
	end

	return next_prompt_line
end

return M
