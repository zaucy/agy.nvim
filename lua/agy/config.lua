local utils = require("agy.utils")

local M = {}

---@class AgyConfigKeymaps
---@field submit? string Keymap to submit prompt (default: "<C-s>")
---@field stop? string Keymap to stop current in-flight turn (default: "<C-c>")
---@field toggle_tool? string Keymap to toggle tool output block (default: "<CR>")

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
---@field animate_thinking? boolean Animate thinking badge on agent turn (default: true)

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
	},
	keymaps = {
		submit = "<C-s>",
		stop = "<C-c>",
		toggle_tool = "<CR>",
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
