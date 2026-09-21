local M = {}

---Create a minimal separator renderer function
---Produces a clean 2-line virtual divider with header line and subtle divider rule
---@return fun(ctx: table): table virt_lines
local function create_minimal_renderer()
	return function(ctx)
		assert(ctx, "agy separator: context table is required")
		assert(ctx.icon, "agy separator: context.icon is required")
		assert(ctx.name, "agy separator: context.name is required")
		assert(ctx.title_hl, "agy separator: context.title_hl is required")

		local title_text = string.format("%s %s", ctx.icon, ctx.name)
		local header_chunks = {
			{ title_text, ctx.title_hl },
		}
		if ctx.badge_text and ctx.badge_text ~= "" then
			table.insert(header_chunks, { ctx.badge_text, ctx.badge_hl or "AgyBadgeDone" })
		end

		local title_w = vim.api.nvim_strwidth(title_text)
		local badge_w = (ctx.badge_text and ctx.badge_text ~= "") and vim.api.nvim_strwidth(ctx.badge_text) or 0
		local rule_len = math.max(24, title_w + badge_w)
		local rule_chunks = {
			{ string.rep("┄", rule_len), "AgyDividerLine" },
		}

		return {
			header_chunks,
			rule_chunks,
		}
	end
end

return setmetatable(M, {
	__call = function(_, ctx_or_opts)
		if type(ctx_or_opts) == "table" and ctx_or_opts.role ~= nil then
			return create_minimal_renderer()(ctx_or_opts)
		end
		return create_minimal_renderer()
	end,
})
