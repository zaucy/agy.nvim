local M = {}

local BORDER_PRESETS = {
	rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
	square = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
	single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
	double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
	minimal = { " ", "─", " ", " ", " ", "─", " ", " " },
}

---Resolve and validate border characters
---@param border? string|string[]
---@return string[] chars
local function resolve_border(border)
	border = border or "rounded"
	if type(border) == "table" then
		assert(#border == 8, "agy separator: border table must contain exactly 8 characters")
		return border
	end

	assert(type(border) == "string", "agy separator: border must be a string preset or table of 8 characters")
	local chars = BORDER_PRESETS[border]
	assert(chars, string.format("agy separator: unknown border preset '%s'", border))
	return chars
end

---Parse and normalize box arguments
---@param border_or_opts? string|table
---@return table opts
local function parse_box_opts(border_or_opts)
	local opts = {}
	if type(border_or_opts) == "string" then
		opts.border = border_or_opts
	elseif type(border_or_opts) == "table" then
		if #border_or_opts == 8 then
			opts.border = border_or_opts
		else
			opts.border = border_or_opts.border or "rounded"
		end
	elseif border_or_opts == nil then
		opts.border = "rounded"
	else
		error("agy separator: box expects a border string, options table, or 8-character table")
	end
	return opts
end

---Create a box separator renderer function
---@param border_or_opts? string|table Border style ("rounded", "square", "minimal", etc.) or options table { border }
---@return fun(ctx: table): table virt_lines
local function create_box_renderer(border_or_opts)
	local opts = parse_box_opts(border_or_opts)
	local chars = resolve_border(opts.border)
	local tl, t, tr, r, br, b, bl, l = chars[1], chars[2], chars[3], chars[4], chars[5], chars[6], chars[7], chars[8]

	local tl_w = vim.api.nvim_strwidth(tl)
	local tr_w = vim.api.nvim_strwidth(tr)
	local t_w = math.max(1, vim.api.nvim_strwidth(t))

	local bl_w = vim.api.nvim_strwidth(bl)
	local br_w = vim.api.nvim_strwidth(br)
	local b_w = math.max(1, vim.api.nvim_strwidth(b))

	local l_w = vim.api.nvim_strwidth(l)
	local r_w = vim.api.nvim_strwidth(r)

	return function(ctx)
		assert(ctx, "agy separator: context table is required")
		assert(ctx.icon, "agy separator: context.icon is required")
		assert(ctx.name, "agy separator: context.name is required")
		assert(ctx.title_hl, "agy separator: context.title_hl is required")

		local title_text = string.format("%s %s", ctx.icon, ctx.name)
		local badge_text = (ctx.badge_text and ctx.badge_text ~= "") and ctx.badge_text or ""
		local badge_hl = ctx.badge_hl or "AgyBadgeDone"

		local left_chunk = { l .. " ", "AgyDividerLine" }
		local right_chunk = { " " .. r, "AgyDividerLine" }

		local left_display_w = l_w + 1
		local right_display_w = 1 + r_w
		local title_display_w = vim.api.nvim_strwidth(title_text)
		local badge_display_w = (badge_text ~= "") and vim.api.nvim_strwidth(badge_text) or 0
		local inner_spacing = (badge_display_w > 0) and 2 or 0

		local needed_w = left_display_w + title_display_w + inner_spacing + badge_display_w + right_display_w
		local width = needed_w

		-- Top line
		local top_count = math.max(0, math.floor((width - tl_w - tr_w) / t_w))
		local top_str = tl .. string.rep(t, top_count) .. tr

		-- Bottom line
		local bot_count = math.max(0, math.floor((width - bl_w - br_w) / b_w))
		local bot_str = bl .. string.rep(b, bot_count) .. br

		local pad_w = math.max(inner_spacing, width - (left_display_w + title_display_w + badge_display_w + right_display_w))
		local pad_str = string.rep(" ", pad_w)

		local mid_chunks = {
			left_chunk,
			{ title_text, ctx.title_hl },
		}

		if badge_text ~= "" then
			table.insert(mid_chunks, { pad_str, "Normal" })
			table.insert(mid_chunks, { badge_text, badge_hl })
		else
			table.insert(mid_chunks, { pad_str, "Normal" })
		end
		table.insert(mid_chunks, right_chunk)

		return {
			{ { top_str, "AgyDividerLine" } },
			mid_chunks,
			{ { bot_str, "AgyDividerLine" } },
		}
	end
end

M.presets = BORDER_PRESETS

return setmetatable(M, {
	__call = function(_, border_or_ctx)
		if type(border_or_ctx) == "table" and border_or_ctx.role ~= nil then
			return create_box_renderer("rounded")(border_or_ctx)
		end
		return create_box_renderer(border_or_ctx)
	end,
})
