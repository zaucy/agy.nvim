local M = {}

---Create a line separator renderer function
---Produces a single-line virtual divider: `── <icon> <name> [badge]`
---@return fun(ctx: table): table virt_lines
local function create_line_renderer()
	return function(ctx)
		assert(ctx, "agy separator: context table is required")
		assert(ctx.icon, "agy separator: context.icon is required")
		assert(ctx.name, "agy separator: context.name is required")
		assert(ctx.title_hl, "agy separator: context.title_hl is required")

		local title = string.format("── %s %s ", ctx.icon, ctx.name)
		local chunks = {
			{ title, ctx.title_hl },
		}
		if ctx.badge_text and ctx.badge_text ~= "" then
			table.insert(chunks, { ctx.badge_text, ctx.badge_hl or "AgyBadgeDone" })
		end
		table.insert(chunks, { "", "AgyDividerLine" })
		return { chunks }
	end
end

return setmetatable(M, {
	__call = function(_, ctx_or_opts)
		if type(ctx_or_opts) == "table" and ctx_or_opts.role ~= nil then
			return create_line_renderer()(ctx_or_opts)
		end
		return create_line_renderer()
	end,
})
