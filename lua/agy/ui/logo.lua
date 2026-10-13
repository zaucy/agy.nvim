local utils = require("agy.utils")

local M = {}

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
	[6] = {
		[3] = "#7CC251",
		[4] = "#71C25C",
		[5] = "#5CA98F",
		[6] = "#5C91B3",
		[7] = "#8373B0",
		[8] = "#746FC3",
		[9] = "#995DA8",
		[10] = "#9C5B97",
	},
	[7] = { [4] = "#86C64E", [5] = "#75B45E", [6] = "#CC954D", [7] = "#EF7947", [8] = "#E16652", [9] = "#E14F59" },
	[8] = { [4] = "#9EC345", [5] = "#B5B43E", [6] = "#E2993D", [7] = "#F67A34", [8] = "#F86A35", [9] = "#EF5442" },
	[9] = { [5] = "#DBB131", [6] = "#F6912E", [7] = "#F37337", [8] = "#F0583B" },
	[10] = { [6] = "#F2922E", [7] = "#F07236" },
}

local function get_config(cfg)
	return cfg or require("agy.config").get()
end

local function get_block_icons(cfg)
	local c = get_config(cfg)
	assert(c, "agy config: configuration is required")
	assert(type(c.icons) == "table", "agy config: 'icons' table is required")
	local upper = c.icons.upper_block
	local lower = c.icons.lower_block
	assert(upper, "agy config: 'upper_block' icon is not defined in config.icons")
	assert(lower, "agy config: 'lower_block' icon is not defined in config.icons")
	return upper, lower
end

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

function M.get_logo_row_info(r, cfg)
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

---Reset logo highlight groups to their static base colors
---@param cfg? table
function M.reset_logo_highlights(cfg)
	cfg = get_config(cfg)
	for r = 0, 4 do
		local _, cells = M.get_logo_row_info(r, cfg)
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
	cfg = get_config(cfg)
	for r = 0, 4 do
		local _, cells = M.get_logo_row_info(r, cfg)
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
---@param sub_text? string
---@return string[]
function M.build_banner_lines(session_uri, config, sub_text)
	local cfg = get_config(config)
	local pad = "    "
	local version = utils.get_agy_version(cfg)
	local title_text = "Antigravity CLI" .. (version and (" " .. version) or "")

	local lines = {}
	table.insert(lines, "")

	for r = 0, 4 do
		local logo_str, _ = M.get_logo_row_info(r, cfg)
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

	table.insert(lines, "")
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
		local logo_str, cells = M.get_logo_row_info(r, cfg)
		local buf_row = r + 1
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
			local logo_str, cells = M.get_logo_row_info(2, cfg)
			local new_line = logo_str .. pad .. target_uri
			local buf_row = 3
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

return M
