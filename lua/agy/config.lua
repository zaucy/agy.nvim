local utils = require("agy.utils")

local M = {}

---@class AgyConfigKeymaps
---@field submit? string Keymap to submit prompt (default: "<C-s>")
---@field stop? string Keymap to stop current in-flight turn (default: "<C-c>")
---@field toggle_tool? string Keymap to toggle tool output block (default: "<CR>")
---@field comment? string Keymap to comment on artifact line (default: "c")
---@field delete_comment? string Keymap to delete comment on artifact line (default: "dc")

---@class AgyConfigUI
---@field virtual_text? boolean Show virtual text badges for turn status & tools (default: true)
---@field auto_scroll? boolean Automatically scroll to bottom as streaming responses arrive (default: true)
---@field fold_tool_output? boolean Automatically fold verbose tool output blocks (deprecated, default: false)
---@field wrap? boolean Enable line wrapping in agy buffers (default: true)
---@field linebreak? boolean Enable linebreak in agy buffers (default: true)
---@field conceallevel? number Markdown conceallevel in agy buffers (default: 2)
---@field color_history? boolean Highlight history lines with a distinct background (default: false)
---@field protect_history? boolean Make past conversation history unmodifiable (default: true)
---@field prompt_footer? boolean Show stream info / status footer below prompt (default: true)
---@field show_thoughts? boolean Show agent thoughts between calls (default: true)
---@field tool_max_height? number Maximum height of inline window for tool details (default: 20)
---@field separator? fun(ctx: table): table Separator function returning virt_lines (default: require("agy.ui.separator").line())
---@field animate_thinking? boolean Animate thinking indicator above prompt area on agent turn (default: true)
---@field header_style? "banner" | "markdown" Header style at top of session buffer (default: "banner")
---@field animate_logo? boolean Animate inverted V logo colors dynamically (default: true)
---@field render_markdown? fun(buf: number, delta: string, is_final: boolean, config?: table) Custom streaming markdown renderer (default: require("agy.markdown").render)

---@class AgyConfigIconsTable
---@field top_left string Top-left corner (default: "╭")
---@field top_right string Top-right corner (default: "╮")
---@field bottom_left string Bottom-left corner (default: "╰")
---@field bottom_right string Bottom-right corner (default: "╯")
---@field horizontal string Horizontal border (default: "─")
---@field vertical string Vertical border (default: "│")
---@field top_tee string Top header tee (default: "┬")
---@field bottom_tee string Bottom footer tee (default: "┴")
---@field left_tee string Left divider tee (default: "├")
---@field right_tee string Right divider tee (default: "┤")
---@field cross string Center cross tee (default: "┼")

---@class AgyConfigIconsCodeBlock
---@field top_left string Top left corner for code fence (default: "╭")
---@field horizontal string Horizontal border for code fence (default: "─")
---@field bottom_left string Bottom left corner for code fence (default: "╰")

---@class AgyConfigIcons
---@field default? string Default fallback icon (default: "  ")
---@field tool? string Generic tool call icon (default: "🛠️")
---@field run_command? string Icon for run_command / background tasks (default: "")
---@field view_file? string Icon for view_file tool call (default: "  ")
---@field thought? string Icon for agent thoughts (default: "💭")
---@field user? string Icon for user divider (default: "👤")
---@field agent? string Icon for agent divider (default: "🤖")
---@field prompt_sign? string Sign column icon for active prompt (default: "❯ ")
---@field footer? string Icon for status footer line (default: "⚡")
---@field done? string Icon for completed turns / tasks (default: "✓")
---@field question? string Icon for ask_question headers (default: "❓")
---@field error? string Icon for error notices (default: "❌")
---@field cancelled? string Icon for turn cancelled notices (default: "⏹️")
---@field queue? string Icon for prompt queue (default: "⏳")
---@field spinner? string[] Frames for thinking animation (default: { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" })
---@field table? AgyConfigIconsTable Table border characters
---@field code_block? AgyConfigIconsCodeBlock Code block border characters
---@field bullets? string[] List bullet icons (default: { "●", "○", "◆" })
---@field checkbox_unchecked? string Checkbox unchecked icon (default: "󰄱 ")
---@field checkbox_checked? string Checkbox checked icon (default: "󰄵 ")
---@field image? string Icon for rendered image placeholder (default: " ")
---@field link? string Icon for link hover/inspection (default: "🔗")
---@field upper_block? string Upper half block for logo (default: "▀")
---@field lower_block? string Lower half block for logo (default: "▄")
---@field review_comment? string Icon for review comments (default: "💬")
---@field new_session? string Icon for new session entry in home buffer (default: "󰐕 ")
---@field conversation? string Icon for conversation entries in home buffer (default: "󰭹 ")
---@field step_unanswered? string Icon for unanswered question step in progression (default: "○")
---@field step_answered? string Icon for answered question step in progression (default: "●")
---@field step_current? string Icon for current active question step in progression (default: "◉")
---@field step_line? string Icon for connecting line in question progression (default: "─")

---@class AgyConfig
---@field agy_cmd? string Executable path or name for Antigravity CLI (default: "agy")
---@field app_data_dir? string Path to ~/.gemini/antigravity-cli (default: auto-detected)
---@field default_mode? string Agent mode: "accept-edits" | "plan" (default: nil)
---@field default_model? string Default model for sessions (default: nil)
---@field client_instructions? boolean Automatically inject client instructions for planning and questions (default: true)
---@field workspaces? string[] | fun(): string[] Workspace directories to register with agy CLI (default: nil, falls back to vim.fn.getcwd())
---@field icons? AgyConfigIcons
---@field keymaps? AgyConfigKeymaps
---@field ui? AgyConfigUI

---@type AgyConfig
M.defaults = {
	agy_cmd = "agy",
	app_data_dir = utils.get_app_data_dir(),
	default_mode = nil,
	default_model = nil,
	client_instructions = true,
	workspaces = nil,
	icons = {
		default = "  ",
		tool = "  ",
		run_command = " ",
		view_file = "  ",
		thought = "💭",
		user = "👤",
		agent = "🤖",
		prompt_sign = "❯ ",
		footer = "⚡",
		done = " ",
		question = "❓",
		error = " ",
		cancelled = "⏹️",
		queue = "⏳",
		replace_file_content = " ",
		write_to_file = " ",
		spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
		table = {
			top_left = "╭",
			top_right = "╮",
			bottom_left = "╰",
			bottom_right = "╯",
			horizontal = "─",
			vertical = "│",
			top_tee = "┬",
			bottom_tee = "┴",
			left_tee = "├",
			right_tee = "┤",
			cross = "┼",
		},
		code_block = {
			top_left = "╭",
			horizontal = "─",
			bottom_left = "╰",
		},
		bullets = { "●", "○", "◆" },
		checkbox_unchecked = "󰄱 ",
		checkbox_checked = "󰄵 ",
		image = " ",
		link = "🔗",
		upper_block = "▀",
		lower_block = "▄",
		review_comment = "💬",
		new_session = "󰐕 ",
		conversation = "󰭹 ",
		step_unanswered = "○",
		step_answered = "●",
		step_current = "◉",
		step_line = "─",
	},
	keymaps = {
		submit = "<C-s>",
		stop = "<C-c>",
		toggle_tool = "<CR>",
		comment = "c",
		delete_comment = "dc",
	},
	ui = {
		virtual_text = true,
		auto_scroll = true,
		fold_tool_output = false,
		wrap = true,
		linebreak = true,
		conceallevel = 0,
		color_history = false,
		protect_history = true,
		prompt_footer = true,
		show_thoughts = true,
		tool_max_height = 20,
		separator = require("agy.ui.separator").line(),
		animate_thinking = true,
		header_style = "banner",
		animate_logo = true,
		render_markdown = function(buf, delta, is_final, cfg)
			return require("agy.markdown").render(buf, delta, is_final, cfg)
		end,
	},
}

---@type AgyConfig
M.values = vim.deepcopy(M.defaults)

---Merge user options into configuration
---@param opts? AgyConfig
---@return AgyConfig
function M.setup(opts)
	if opts then
		if opts.ui and opts.ui.separator ~= nil then
			assert(
				type(opts.ui.separator) == "function",
				"agy config: 'ui.separator' must be a function (e.g. require('agy.ui.separator').box('rounded'))"
			)
		end
		if opts.ui and opts.ui.tool_max_height ~= nil then
			assert(
				type(opts.ui.tool_max_height) == "number" and opts.ui.tool_max_height > 0,
				"agy config: 'ui.tool_max_height' must be a positive number"
			)
		end
		if opts.ui and opts.ui.render_markdown ~= nil then
			assert(
				type(opts.ui.render_markdown) == "function",
				"agy config: 'ui.render_markdown' must be a function"
			)
		end
		M.values = vim.tbl_deep_extend("force", M.defaults, opts)
	else
		M.values = vim.deepcopy(M.defaults)
	end
	return M.values
end

---Get current active configuration
---@return AgyConfig
function M.get()
	return M.values
end

return M
