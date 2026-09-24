local utils = require("agy.utils")

local M = {}

M.NS_MARKDOWN = vim.api.nvim_create_namespace("agy_markdown")

---Active streaming sessions per buffer
---@type table<number, { raw_text: string, start_line?: number, rendered_count: number }>
M.sessions = {}

---Canonical raw text storage for completed blocks per buffer
---@type table<number, string>
M.last_raw = {}

---Parsed markdown links metadata per buffer
---@type table<number, table[]>
M.links = {}

---Retrieve active configuration
---@param cfg? table
---@return table
local function get_config(cfg)
	return cfg or require("agy.config").get()
end

---Assert and retrieve icons table
---@param cfg? table
---@return table
local function get_icons(cfg)
	local c = get_config(cfg)
	assert(c, "agy config: configuration is required")
	assert(type(c.icons) == "table", "agy config: 'icons' table is required")
	return c.icons
end

---Assert and retrieve link icon
---@param cfg? table
---@return string
local function get_link_icon(cfg)
	local icons = get_icons(cfg)
	local lk = icons.link
	assert(lk, "agy config: 'link' icon is not defined in config.icons")
	return lk
end

---Assert and retrieve table border characters
---@param cfg? table
---@return table
local function get_table_icons(cfg)
	local icons = get_icons(cfg)
	local t = icons.table
	assert(type(t) == "table", "agy config: 'table' border icons table is required in config.icons")
	assert(t.top_left, "agy config: 'table.top_left' is not defined in config.icons")
	assert(t.top_right, "agy config: 'table.top_right' is not defined in config.icons")
	assert(t.bottom_left, "agy config: 'table.bottom_left' is not defined in config.icons")
	assert(t.bottom_right, "agy config: 'table.bottom_right' is not defined in config.icons")
	assert(t.horizontal, "agy config: 'table.horizontal' is not defined in config.icons")
	assert(t.vertical, "agy config: 'table.vertical' is not defined in config.icons")
	assert(t.top_tee, "agy config: 'table.top_tee' is not defined in config.icons")
	assert(t.bottom_tee, "agy config: 'table.bottom_tee' is not defined in config.icons")
	assert(t.left_tee, "agy config: 'table.left_tee' is not defined in config.icons")
	assert(t.right_tee, "agy config: 'table.right_tee' is not defined in config.icons")
	assert(t.cross, "agy config: 'table.cross' is not defined in config.icons")
	return t
end

---Assert and retrieve code block border characters
---@param cfg? table
---@return table
local function get_code_block_icons(cfg)
	local icons = get_icons(cfg)
	local cb = icons.code_block
	assert(type(cb) == "table", "agy config: 'code_block' icons table is required in config.icons")
	assert(cb.top_left, "agy config: 'code_block.top_left' is not defined in config.icons")
	assert(cb.horizontal, "agy config: 'code_block.horizontal' is not defined in config.icons")
	return cb
end

---Assert and retrieve bullet icons list
---@param cfg? table
---@return string[]
local function get_bullets(cfg)
	local icons = get_icons(cfg)
	local bullets = icons.bullets
	assert(type(bullets) == "table" and #bullets > 0, "agy config: 'bullets' list is required in config.icons")
	return bullets
end

---Assert and retrieve checkbox icons
---@param cfg? table
---@return string uncheck
---@return string check
local function get_checkbox_icons(cfg)
	local icons = get_icons(cfg)
	local uncheck = icons.checkbox_unchecked
	local check = icons.checkbox_checked
	assert(uncheck, "agy config: 'checkbox_unchecked' icon is not defined in config.icons")
	assert(check, "agy config: 'checkbox_checked' icon is not defined in config.icons")
	return uncheck, check
end

---Assert and retrieve image icon
---@param cfg? table
---@return string
local function get_image_icon(cfg)
	local icons = get_icons(cfg)
	local img = icons.image
	assert(img, "agy config: 'image' icon is not defined in config.icons")
	return img
end

---Split markdown table row into individual cells
---@param line string
---@return string[]
function M.split_table_row(line)
	local trimmed = line:match("^%s*(.-)%s*$") or ""
	if trimmed:sub(1, 1) == "|" then
		trimmed = trimmed:sub(2)
	end
	if trimmed:sub(-1) == "|" and trimmed:sub(-2, -1) ~= "\\|" then
		trimmed = trimmed:sub(1, -2)
	end

	local cells = {}
	local current = {}
	local i = 1
	local len = #trimmed
	while i <= len do
		local c = trimmed:sub(i, i)
		if c == "\\" and i < len and trimmed:sub(i + 1, i + 1) == "|" then
			table.insert(current, "|")
			i = i + 2
		elseif c == "|" then
			local cell = table.concat(current)
			cell = cell:match("^%s*(.-)%s*$") or ""
			cell = cell:gsub("%s+", " ")
			table.insert(cells, cell)
			current = {}
			i = i + 1
		else
			table.insert(current, c)
			i = i + 1
		end
	end
	local last_cell = table.concat(current)
	last_cell = last_cell:match("^%s*(.-)%s*$") or ""
	last_cell = last_cell:gsub("%s+", " ")
	table.insert(cells, last_cell)
	return cells
end

---Parse column alignments from a separator row
---@param cells string[]
---@return string[]?
function M.parse_separator_row(cells)
	if not cells or #cells == 0 then
		return nil
	end
	local aligns = {}
	for _, c in ipairs(cells) do
		local stripped = c:gsub("%s+", "")
		if not stripped:match("^:?%-+:?$") or not stripped:find("-", 1, true) then
			return nil
		end
		local left_colon = stripped:sub(1, 1) == ":"
		local right_colon = stripped:sub(-1) == ":"
		if left_colon and right_colon then
			table.insert(aligns, "center")
		elseif right_colon then
			table.insert(aligns, "right")
		else
			table.insert(aligns, "left")
		end
	end
	return aligns
end

---Pad cell text to target display width according to column alignment
---@param content string
---@param target_width number
---@param align string "left" | "right" | "center"
---@return string
function M.pad_cell(content, target_width, align)
	local disp_w = vim.fn.strdisplaywidth(content)
	local diff = target_width - disp_w
	if diff <= 0 then
		return content
	end

	if align == "right" then
		return string.rep(" ", diff) .. content
	elseif align == "center" then
		local left_pad = math.floor(diff / 2)
		local right_pad = diff - left_pad
		return string.rep(" ", left_pad) .. content .. string.rep(" ", right_pad)
	else
		return content .. string.rep(" ", diff)
	end
end

---Allocate column widths within budget clamped to window width
---@param desired number[]
---@param minimum number[]
---@param budget number
---@return number[]
function M.allocate_col_widths(desired, minimum, budget)
	local natural = 0
	local floor = 0
	for i, width in ipairs(desired) do
		natural = natural + width
		floor = floor + minimum[i]
	end
	if natural <= budget then
		return desired
	end
	if budget < floor then
		return minimum
	end

	local locked = {}
	local free = #desired
	local share = math.floor(budget / free)
	local changed = true
	while changed do
		changed = false
		for i = 1, #desired do
			if not locked[i] and desired[i] <= share then
				locked[i] = true
				budget = budget - desired[i]
				free = free - 1
				changed = true
			end
		end
		if free > 0 then
			share = math.floor(budget / free)
		end
	end

	local widths = {}
	for i, width in ipairs(desired) do
		widths[i] = locked[i] and width or share
	end

	budget = budget - (free * share)
	for i = 1, #desired do
		if budget <= 0 then
			break
		end
		if not locked[i] and widths[i] < desired[i] then
			widths[i] = widths[i] + 1
			budget = budget - 1
		end
	end

	return widths
end

---Wrap cell text to target column width
---@param text string
---@param width number
---@return string[]
function M.wrap_cell_text(text, width)
	if width <= 0 then
		return { text }
	end
	local trimmed = text:match("^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return { "" }
	end
	if vim.fn.strdisplaywidth(trimmed) <= width then
		return { trimmed }
	end

	local words = {}
	for word in trimmed:gmatch("%S+") do
		table.insert(words, word)
	end
	if #words == 0 then
		return { "" }
	end

	local lines = {}
	local current_line = ""
	local current_w = 0

	for _, word in ipairs(words) do
		local word_w = vim.fn.strdisplaywidth(word)
		if word_w > width then
			if current_line ~= "" then
				table.insert(lines, current_line)
				current_line = ""
				current_w = 0
			end
			local chars = vim.fn.split(word, [[\zs]])
			local chunk = ""
			local chunk_w = 0
			for _, ch in ipairs(chars) do
				local ch_w = vim.fn.strdisplaywidth(ch)
				if chunk_w + ch_w > width and chunk ~= "" then
					table.insert(lines, chunk)
					chunk = ch
					chunk_w = ch_w
				else
					chunk = chunk .. ch
					chunk_w = chunk_w + ch_w
				end
			end
			if chunk ~= "" then
				current_line = chunk
				current_w = chunk_w
			end
		elseif current_w == 0 then
			current_line = word
			current_w = word_w
		elseif current_w + 1 + word_w <= width then
			current_line = current_line .. " " .. word
			current_w = current_w + 1 + word_w
		else
			table.insert(lines, current_line)
			current_line = word
			current_w = word_w
		end
	end

	if current_line ~= "" then
		table.insert(lines, current_line)
	end

	return #lines > 0 and lines or { "" }
end

local function is_space(c)
	return c == " " or c == "\t" or c == "\n" or c == "\r"
end

local function is_alnum(c)
	if not c or c == "" then
		return false
	end
	return c:match("[%w]") ~= nil
end

---Parse markdown inline formatting (bold, italic, strike, code, link)
---Strips syntax delimiters and returns transformed text with extmark directives
---@param line string
---@return string formatted_text
---@return table[] extmarks
---@return table[] links
function M.parse_inline_formatting(line)
	if not line or line == "" then
		return line, {}, {}
	end
	if not line:find("[*_`~%[]") then
		return line, {}, {}
	end

	local out = {}
	local extmarks = {}
	local links = {}
	local cur_col = 0

	local i = 1
	local len = #line

	while i <= len do
		local c = line:sub(i, i)
		local prev_c = i > 1 and line:sub(i - 1, i - 1) or nil
		local next_c = i < len and line:sub(i + 1, i + 1) or nil

		-- 1. Inline code: `...` (or multiple backticks ``...``)
		if c == "`" then
			local bt_start = i
			while i <= len and line:sub(i, i) == "`" do
				i = i + 1
			end
			local bt_len = i - bt_start
			local delim = string.rep("`", bt_len)
			local close_idx = line:find(delim, i, true)
			if close_idx then
				local code_text = line:sub(i, close_idx - 1)
				if #code_text >= 2 and code_text:sub(1, 1) == " " and code_text:sub(-1, -1) == " " and code_text:match("%S") then
					code_text = code_text:sub(2, -2)
				end
				local start_col = cur_col
				table.insert(out, code_text)
				cur_col = cur_col + #code_text
				table.insert(extmarks, {
					col = start_col,
					end_col = cur_col,
					hl_group = "AgyInlineCode",
					hl_mode = "combine",
				})
				i = close_idx + bt_len
			else
				table.insert(out, delim)
				cur_col = cur_col + #delim
			end

		-- 2. Links: [label](url)
		elseif c == "[" and prev_c ~= "!" then
			local sq_depth = 1
			local close_sq = nil
			local p = i + 1
			while p <= len do
				local ch = line:sub(p, p)
				if ch == "\\" then
					p = p + 1
				elseif ch == "[" then
					sq_depth = sq_depth + 1
				elseif ch == "]" then
					sq_depth = sq_depth - 1
					if sq_depth == 0 then
						close_sq = p
						break
					end
				end
				p = p + 1
			end
			if close_sq and close_sq < len and line:sub(close_sq + 1, close_sq + 1) == "(" then
				local paren_depth = 1
				local p2 = close_sq + 2
				local close_paren = nil
				while p2 <= len do
					local ch = line:sub(p2, p2)
					if ch == "\\" then
						p2 = p2 + 1
					elseif ch == "(" then
						paren_depth = paren_depth + 1
					elseif ch == ")" then
						paren_depth = paren_depth - 1
						if paren_depth == 0 then
							close_paren = p2
							break
						end
					end
					p2 = p2 + 1
				end
				if close_paren then
					local label = line:sub(i + 1, close_sq - 1)
					local raw_url = line:sub(close_sq + 2, close_paren - 1)
					local clean_url = utils.trim(raw_url)
					local angle_url = clean_url:match("^<([^>]+)>")
					if angle_url then
						clean_url = angle_url
					else
						local title_url = clean_url:match('^(.-)%s+["\']')
						if title_url and title_url ~= "" then
							clean_url = title_url
						end
					end
					local sub_text, sub_marks, sub_links = M.parse_inline_formatting(label)
					local start_col = cur_col
					table.insert(out, sub_text)
					cur_col = cur_col + #sub_text
					table.insert(extmarks, {
						col = start_col,
						end_col = cur_col,
						hl_group = "AgyLink",
						hl_mode = "combine",
						url = clean_url,
					})
					for _, m in ipairs(sub_marks) do
						table.insert(extmarks, {
							col = start_col + m.col,
							end_col = start_col + m.end_col,
							hl_group = m.hl_group,
							hl_mode = "combine",
							url = m.url,
						})
					end
					table.insert(links, {
						start_col = start_col,
						end_col = cur_col,
						url = clean_url,
					})
					for _, sl in ipairs(sub_links or {}) do
						table.insert(links, {
							start_col = start_col + sl.start_col,
							end_col = start_col + sl.end_col,
							url = sl.url,
						})
					end
					i = close_paren + 1
				else
					table.insert(out, "[")
					cur_col = cur_col + 1
					i = i + 1
				end
			else
				table.insert(out, "[")
				cur_col = cur_col + 1
				i = i + 1
			end

		-- 3. Bold + Italic: ***text***
		elseif c == "*" and line:sub(i, i + 2) == "***" then
			local close_idx = line:find("***", i + 3, true)
			if close_idx and close_idx > i + 3 then
				local inner = line:sub(i + 3, close_idx - 1)
				if not is_space(inner:sub(1, 1)) and not is_space(inner:sub(-1, -1)) then
					local sub_text, sub_marks, sub_links = M.parse_inline_formatting(inner)
					local start_col = cur_col
					table.insert(out, sub_text)
					cur_col = cur_col + #sub_text
					table.insert(extmarks, {
						col = start_col,
						end_col = cur_col,
						hl_group = "AgyBold",
						hl_mode = "combine",
					})
					table.insert(extmarks, {
						col = start_col,
						end_col = cur_col,
						hl_group = "AgyItalic",
						hl_mode = "combine",
					})
					for _, m in ipairs(sub_marks) do
						table.insert(extmarks, {
							col = start_col + m.col,
							end_col = start_col + m.end_col,
							hl_group = m.hl_group,
							hl_mode = "combine",
							url = m.url,
						})
					end
					for _, sl in ipairs(sub_links or {}) do
						table.insert(links, {
							start_col = start_col + sl.start_col,
							end_col = start_col + sl.end_col,
							url = sl.url,
						})
					end
					i = close_idx + 3
				else
					table.insert(out, "***")
					cur_col = cur_col + 3
					i = i + 3
				end
			else
				table.insert(out, "*")
				cur_col = cur_col + 1
				i = i + 1
			end

		-- 4. Bold: **text**
		elseif c == "*" and line:sub(i, i + 1) == "**" then
			local close_idx = line:find("**", i + 2, true)
			if close_idx and close_idx > i + 2 then
				local inner = line:sub(i + 2, close_idx - 1)
				if not is_space(inner:sub(1, 1)) and not is_space(inner:sub(-1, -1)) then
					local sub_text, sub_marks, sub_links = M.parse_inline_formatting(inner)
					local start_col = cur_col
					table.insert(out, sub_text)
					cur_col = cur_col + #sub_text
					table.insert(extmarks, {
						col = start_col,
						end_col = cur_col,
						hl_group = "AgyBold",
						hl_mode = "combine",
					})
					for _, m in ipairs(sub_marks) do
						table.insert(extmarks, {
							col = start_col + m.col,
							end_col = start_col + m.end_col,
							hl_group = m.hl_group,
							hl_mode = "combine",
							url = m.url,
						})
					end
					for _, sl in ipairs(sub_links or {}) do
						table.insert(links, {
							start_col = start_col + sl.start_col,
							end_col = start_col + sl.end_col,
							url = sl.url,
						})
					end
					i = close_idx + 2
				else
					table.insert(out, "**")
					cur_col = cur_col + 2
					i = i + 2
				end
			else
				table.insert(out, "*")
				cur_col = cur_col + 1
				i = i + 1
			end

		-- 5. Bold with __: __text__
		elseif c == "_" and line:sub(i, i + 1) == "__" and not is_alnum(prev_c) then
			local close_idx = line:find("__", i + 2, true)
			if close_idx and close_idx > i + 2 then
				local after_close = close_idx + 2 <= len and line:sub(close_idx + 2, close_idx + 2) or nil
				if not is_alnum(after_close) then
					local inner = line:sub(i + 2, close_idx - 1)
					if not is_space(inner:sub(1, 1)) and not is_space(inner:sub(-1, -1)) then
						local sub_text, sub_marks, sub_links = M.parse_inline_formatting(inner)
						local start_col = cur_col
						table.insert(out, sub_text)
						cur_col = cur_col + #sub_text
						table.insert(extmarks, {
							col = start_col,
							end_col = cur_col,
							hl_group = "AgyBold",
							hl_mode = "combine",
						})
						for _, m in ipairs(sub_marks) do
							table.insert(extmarks, {
								col = start_col + m.col,
								end_col = start_col + m.end_col,
								hl_group = m.hl_group,
								hl_mode = "combine",
								url = m.url,
							})
						end
						for _, sl in ipairs(sub_links or {}) do
							table.insert(links, {
								start_col = start_col + sl.start_col,
								end_col = start_col + sl.end_col,
								url = sl.url,
							})
						end
						i = close_idx + 2
					else
						table.insert(out, "__")
						cur_col = cur_col + 2
						i = i + 2
					end
				else
					table.insert(out, "_")
					cur_col = cur_col + 1
					i = i + 1
				end
			else
				table.insert(out, "_")
				cur_col = cur_col + 1
				i = i + 1
			end

		-- 6. Strike: ~~text~~
		elseif c == "~" and line:sub(i, i + 1) == "~~" then
			local close_idx = line:find("~~", i + 2, true)
			if close_idx and close_idx > i + 2 then
				local inner = line:sub(i + 2, close_idx - 1)
				if not is_space(inner:sub(1, 1)) and not is_space(inner:sub(-1, -1)) then
					local sub_text, sub_marks, sub_links = M.parse_inline_formatting(inner)
					local start_col = cur_col
					table.insert(out, sub_text)
					cur_col = cur_col + #sub_text
					table.insert(extmarks, {
						col = start_col,
						end_col = cur_col,
						hl_group = "AgyStrike",
						hl_mode = "combine",
					})
					for _, m in ipairs(sub_marks) do
						table.insert(extmarks, {
							col = start_col + m.col,
							end_col = start_col + m.end_col,
							hl_group = m.hl_group,
							hl_mode = "combine",
							url = m.url,
						})
					end
					for _, sl in ipairs(sub_links or {}) do
						table.insert(links, {
							start_col = start_col + sl.start_col,
							end_col = start_col + sl.end_col,
							url = sl.url,
						})
					end
					i = close_idx + 2
				else
					table.insert(out, "~~")
					cur_col = cur_col + 2
					i = i + 2
				end
			else
				table.insert(out, "~")
				cur_col = cur_col + 1
				i = i + 1
			end

		-- 7. Italic: *text*
		elseif c == "*" and next_c ~= "*" and prev_c ~= "*" and not is_space(next_c) then
			local close_idx = nil
			local j = i + 1
			while j <= len do
				if line:sub(j, j) == "*" and line:sub(j - 1, j - 1) ~= "*" and (j == len or line:sub(j + 1, j + 1) ~= "*") then
					if not is_space(line:sub(j - 1, j - 1)) then
						close_idx = j
						break
					end
				end
				j = j + 1
			end
			if close_idx and close_idx > i + 1 then
				local inner = line:sub(i + 1, close_idx - 1)
				local sub_text, sub_marks, sub_links = M.parse_inline_formatting(inner)
				local start_col = cur_col
				table.insert(out, sub_text)
				cur_col = cur_col + #sub_text
				table.insert(extmarks, {
					col = start_col,
					end_col = cur_col,
					hl_group = "AgyItalic",
					hl_mode = "combine",
				})
				for _, m in ipairs(sub_marks) do
					table.insert(extmarks, {
						col = start_col + m.col,
						end_col = start_col + m.end_col,
						hl_group = m.hl_group,
						hl_mode = "combine",
						url = m.url,
					})
				end
				for _, sl in ipairs(sub_links or {}) do
					table.insert(links, {
						start_col = start_col + sl.start_col,
						end_col = start_col + sl.end_col,
						url = sl.url,
					})
				end
				i = close_idx + 1
			else
				table.insert(out, "*")
				cur_col = cur_col + 1
				i = i + 1
			end

		-- 8. Italic with _: _text_
		elseif c == "_" and next_c ~= "_" and prev_c ~= "_" and not is_alnum(prev_c) and not is_space(next_c) then
			local close_idx = nil
			local j = i + 1
			while j <= len do
				if line:sub(j, j) == "_" and line:sub(j - 1, j - 1) ~= "_" and (j == len or (line:sub(j + 1, j + 1) ~= "_" and not is_alnum(line:sub(j + 1, j + 1)))) then
					if not is_space(line:sub(j - 1, j - 1)) then
						close_idx = j
						break
					end
				end
				j = j + 1
			end
			if close_idx and close_idx > i + 1 then
				local inner = line:sub(i + 1, close_idx - 1)
				local sub_text, sub_marks, sub_links = M.parse_inline_formatting(inner)
				local start_col = cur_col
				table.insert(out, sub_text)
				cur_col = cur_col + #sub_text
				table.insert(extmarks, {
					col = start_col,
					end_col = cur_col,
					hl_group = "AgyItalic",
					hl_mode = "combine",
				})
				for _, m in ipairs(sub_marks) do
					table.insert(extmarks, {
						col = start_col + m.col,
						end_col = start_col + m.end_col,
						hl_group = m.hl_group,
						hl_mode = "combine",
						url = m.url,
					})
				end
				for _, sl in ipairs(sub_links or {}) do
					table.insert(links, {
						start_col = start_col + sl.start_col,
						end_col = start_col + sl.end_col,
						url = sl.url,
					})
				end
				i = close_idx + 1
			else
				table.insert(out, "_")
				cur_col = cur_col + 1
				i = i + 1
			end

		else
			table.insert(out, c)
			cur_col = cur_col + 1
			i = i + 1
		end
	end

	return table.concat(out), extmarks, links
end

---Format markdown table rows into rounded box borders with wordwrap and column clamping
---@param raw_rows string[]
---@param t_icons table
---@param max_width? number
---@return string[] lines
---@return table[] extmarks
function M.format_table(raw_rows, t_icons, max_width)
	if #raw_rows < 2 then
		return nil, nil
	end

	local parsed_rows = {}
	for _, r in ipairs(raw_rows) do
		table.insert(parsed_rows, M.split_table_row(r))
	end

	local sep_idx = nil
	local aligns = nil
	for idx, r in ipairs(parsed_rows) do
		local a = M.parse_separator_row(r)
		if a then
			sep_idx = idx
			aligns = a
			break
		end
	end

	-- A valid Markdown table MUST have a separator row at row 2
	if not sep_idx or sep_idx ~= 2 then
		return nil, nil
	end

	local header_row = parsed_rows[1]
	local data_rows = {}
	for idx = 3, #parsed_rows do
		table.insert(data_rows, parsed_rows[idx])
	end

	local num_cols = #header_row
	for _, r in ipairs(data_rows) do
		if #r > num_cols then
			num_cols = #r
		end
	end
	if #aligns > num_cols then
		num_cols = #aligns
	end

	for c = 1, num_cols do
		if not header_row[c] then header_row[c] = "" end
		if not aligns[c] then aligns[c] = "left" end
	end
	for _, r in ipairs(data_rows) do
		for c = 1, num_cols do
			if not r[c] then r[c] = "" end
		end
	end

	-- Format inline formatting in cell text and preserve extmark directives
	local header_cells = {}
	for c = 1, num_cols do
		local clean_text, inlines = M.parse_inline_formatting(header_row[c])
		header_cells[c] = { text = clean_text, inlines = inlines }
	end

	local data_cells = {}
	for _, r in ipairs(data_rows) do
		local row_cells = {}
		for c = 1, num_cols do
			local clean_text, inlines = M.parse_inline_formatting(r[c])
			row_cells[c] = { text = clean_text, inlines = inlines }
		end
		table.insert(data_cells, row_cells)
	end

	local desired = {}
	local minimum = {}
	for c = 1, num_cols do
		local max_w = math.max(3, vim.fn.strdisplaywidth(header_cells[c].text))
		for _, r in ipairs(data_cells) do
			local cell_w = vim.fn.strdisplaywidth(r[c].text)
			if cell_w > max_w then
				max_w = cell_w
			end
		end
		desired[c] = max_w
		minimum[c] = 3
	end

	local col_widths = desired
	if max_width and max_width > 0 then
		local overhead = 3 * num_cols + 1
		local budget = max_width - overhead
		col_widths = M.allocate_col_widths(desired, minimum, budget)
	end

	local lines = {}
	local extmarks = {}

	-- Top border: ╭─┬─╮
	local top_parts = {}
	for c = 1, num_cols do
		table.insert(top_parts, string.rep(t_icons.horizontal, col_widths[c] + 2))
	end
	local top_line = t_icons.top_left .. table.concat(top_parts, t_icons.top_tee) .. t_icons.top_right
	table.insert(lines, top_line)
	table.insert(extmarks, {
		rel_row = #lines - 1,
		col = 0,
		opts = { hl_group = "AgyTableBorder", end_col = #top_line },
	})

	-- Header row: │ col1 │ col2 │ (with wrapping support)
	local h_cell_lines = {}
	local h_height = 1
	for c = 1, num_cols do
		h_cell_lines[c] = M.wrap_cell_text(header_cells[c].text, col_widths[c])
		if #h_cell_lines[c] > h_height then
			h_height = #h_cell_lines[c]
		end
	end
	local h_pos = {}
	for c = 1, num_cols do
		h_pos[c] = 1
	end
	for sub_i = 1, h_height do
		local h_parts = {}
		for c = 1, num_cols do
			local text = h_cell_lines[c][sub_i] or ""
			local cell_str = M.pad_cell(text, col_widths[c], aligns[c])
			table.insert(h_parts, " " .. cell_str .. " ")
		end
		local header_line = t_icons.vertical .. table.concat(h_parts, t_icons.vertical) .. t_icons.vertical
		table.insert(lines, header_line)
		local current_rel_row = #lines - 1
		table.insert(extmarks, {
			rel_row = current_rel_row,
			col = 0,
			opts = { hl_group = "AgyTableHeader", end_col = #header_line },
		})

		local col_offset = #t_icons.vertical
		for c = 1, num_cols do
			local sub_text = h_cell_lines[c][sub_i] or ""
			if sub_text ~= "" and #header_cells[c].inlines > 0 then
				local full_clean = header_cells[c].text
				local s_idx, e_idx = full_clean:find(sub_text, h_pos[c], true)
				if s_idx then
					h_pos[c] = e_idx + 1
					local diff = col_widths[c] - vim.fn.strdisplaywidth(sub_text)
					local left_pad = 0
					if diff > 0 then
						if aligns[c] == "right" then
							left_pad = diff
						elseif aligns[c] == "center" then
							left_pad = math.floor(diff / 2)
						end
					end
					local text_start = col_offset + 1 + left_pad
					for _, im in ipairs(header_cells[c].inlines) do
						local o_start = math.max(im.col + 1, s_idx)
						local o_end = math.min(im.end_col, e_idx)
						if o_start <= o_end then
							local sub_start = o_start - s_idx
							local sub_end = o_end - s_idx + 1
							table.insert(extmarks, {
								rel_row = current_rel_row,
								col = text_start + sub_start,
								opts = {
									end_col = text_start + sub_end,
									hl_group = im.hl_group,
									priority = 115,
									hl_mode = "combine",
								},
								url = im.url,
							})
						end
					end
				end
			end
			col_offset = col_offset + #h_parts[c] + #t_icons.vertical
		end
	end

	-- Separator row: ├─┼─┤ (if separator was present)
	if sep_idx then
		local sep_parts = {}
		for c = 1, num_cols do
			table.insert(sep_parts, string.rep(t_icons.horizontal, col_widths[c] + 2))
		end
		local sep_line = t_icons.left_tee .. table.concat(sep_parts, t_icons.cross) .. t_icons.right_tee
		table.insert(lines, sep_line)
		table.insert(extmarks, {
			rel_row = #lines - 1,
			col = 0,
			opts = { hl_group = "AgyTableBorder", end_col = #sep_line },
		})
	end

	-- Data rows (with wrapping support)
	for _, r_cells in ipairs(data_cells) do
		local d_cell_lines = {}
		local d_height = 1
		for c = 1, num_cols do
			d_cell_lines[c] = M.wrap_cell_text(r_cells[c].text, col_widths[c])
			if #d_cell_lines[c] > d_height then
				d_height = #d_cell_lines[c]
			end
		end
		local d_pos = {}
		for c = 1, num_cols do
			d_pos[c] = 1
		end
		for sub_i = 1, d_height do
			local d_parts = {}
			for c = 1, num_cols do
				local text = d_cell_lines[c][sub_i] or ""
				local cell_str = M.pad_cell(text, col_widths[c], aligns[c])
				table.insert(d_parts, " " .. cell_str .. " ")
			end
			local data_line = t_icons.vertical .. table.concat(d_parts, t_icons.vertical) .. t_icons.vertical
			table.insert(lines, data_line)
			local current_rel_row = #lines - 1

			local col_offset = #t_icons.vertical
			for c = 1, num_cols do
				local sub_text = d_cell_lines[c][sub_i] or ""
				if sub_text ~= "" and #r_cells[c].inlines > 0 then
					local full_clean = r_cells[c].text
					local s_idx, e_idx = full_clean:find(sub_text, d_pos[c], true)
					if s_idx then
						d_pos[c] = e_idx + 1
						local diff = col_widths[c] - vim.fn.strdisplaywidth(sub_text)
						local left_pad = 0
						if diff > 0 then
							if aligns[c] == "right" then
								left_pad = diff
							elseif aligns[c] == "center" then
								left_pad = math.floor(diff / 2)
							end
						end
						local text_start = col_offset + 1 + left_pad
						for _, im in ipairs(r_cells[c].inlines) do
							local o_start = math.max(im.col + 1, s_idx)
							local o_end = math.min(im.end_col, e_idx)
							if o_start <= o_end then
								local sub_start = o_start - s_idx
								local sub_end = o_end - s_idx + 1
								table.insert(extmarks, {
									rel_row = current_rel_row,
									col = text_start + sub_start,
									opts = {
										end_col = text_start + sub_end,
										hl_group = im.hl_group,
										priority = 115,
										hl_mode = "combine",
									},
									url = im.url,
								})
							end
						end
					end
				end
				col_offset = col_offset + #d_parts[c] + #t_icons.vertical
			end
		end
	end

	-- Bottom border: ╰─┴─╯
	local bot_parts = {}
	for c = 1, num_cols do
		table.insert(bot_parts, string.rep(t_icons.horizontal, col_widths[c] + 2))
	end
	local bot_line = t_icons.bottom_left .. table.concat(bot_parts, t_icons.bottom_tee) .. t_icons.bottom_right
	table.insert(lines, bot_line)
	table.insert(extmarks, {
		rel_row = #lines - 1,
		col = 0,
		opts = { hl_group = "AgyTableBorder", end_col = #bot_line },
	})

	return lines, extmarks
end

---Retrieve canonical treesitter language name from filetype/fence identifier
---@param lang string
---@return string?
local function get_treesitter_lang(lang)
	if not lang or lang == "" then
		return nil
	end
	local lower = lang:lower()
	if vim.treesitter and vim.treesitter.language and vim.treesitter.language.get_lang then
		local mapped = vim.treesitter.language.get_lang(lower)
		if mapped then
			return mapped
		end
	end
	local alias_map = {
		js = "javascript",
		ts = "typescript",
		py = "python",
		rb = "ruby",
		rs = "rust",
		sh = "bash",
		bash = "bash",
		zsh = "bash",
		shell = "bash",
		yml = "yaml",
		md = "markdown",
	}
	return alias_map[lower] or lower
end

---Apply treesitter highlight captures to code block lines
---@param code_text string
---@param lang string
---@param start_rel_line number
---@param extmarks table[]
local function apply_treesitter_highlights(code_text, lang, start_rel_line, extmarks)
	local ts_lang = get_treesitter_lang(lang)
	if not ts_lang then
		return
	end
	local ok_parser, parser = pcall(vim.treesitter.get_string_parser, code_text, ts_lang)
	if not ok_parser or not parser then
		return
	end
	local ok_parse, trees = pcall(function()
		return parser:parse()
	end)
	if not ok_parse or not trees or #trees == 0 then
		return
	end

	local handled = false
	if parser.for_each_tree then
		local ok_each = pcall(function()
			parser:for_each_tree(function(t, ltree)
				local l_lang = ltree:lang()
				local ok_query, query = pcall(vim.treesitter.query.get, l_lang, "highlights")
				if not ok_query or not query then
					return
				end
				for id, node in query:iter_captures(t:root(), code_text) do
					local srow, scol, erow, ecol = node:range()
					local cap = query.captures[id]
					if cap then
						table.insert(extmarks, {
							rel_row = start_rel_line + srow,
							col = scol,
							opts = {
								end_row_rel = start_rel_line + erow,
								end_col = ecol,
								hl_group = "@" .. cap,
								priority = 110,
								hl_mode = "combine",
							},
						})
					end
				end
			end)
		end)
		if ok_each then
			handled = true
		end
	end

	if not handled then
		local root = trees[1] and trees[1]:root()
		if not root then
			return
		end
		local ok_query, query = pcall(vim.treesitter.query.get, ts_lang, "highlights")
		if not ok_query or not query then
			return
		end
		pcall(function()
			for id, node in query:iter_captures(root, code_text) do
				local srow, scol, erow, ecol = node:range()
				local cap = query.captures[id]
				if cap then
					table.insert(extmarks, {
						rel_row = start_rel_line + srow,
						col = scol,
						opts = {
							end_row_rel = start_rel_line + erow,
							end_col = ecol,
							hl_group = "@" .. cap,
							priority = 110,
							hl_mode = "combine",
						},
					})
				end
			end
		end)
	end
end

---Format code fence block with borders and language label
---@param body_lines string[]
---@param lang string
---@param _cb_icons? table
---@return string[] lines
---@return table[] extmarks
function M.format_code_block(body_lines, lang, _cb_icons)
	local lines = {}
	local extmarks = {}

	local lang_icon = nil
	local icon_hl = nil
	if lang and lang ~= "" then
		local ok_dev, devicons = pcall(require, "nvim-web-devicons")
		if ok_dev and devicons then
			if devicons.get_icon_by_filetype then
				lang_icon, icon_hl = devicons.get_icon_by_filetype(lang, { default = false })
			end
			if not lang_icon and devicons.get_icon then
				lang_icon, icon_hl = devicons.get_icon(nil, lang, { default = false })
			end
		end
	end

	local display_label = ""
	if lang and lang ~= "" then
		if lang_icon and lang_icon ~= "" then
			display_label = lang_icon .. " " .. lang
		else
			display_label = lang
		end
	end

	-- Top line with icon + language if language is specified (no borders)
	if display_label ~= "" then
		table.insert(lines, display_label)
		table.insert(extmarks, {
			rel_row = #lines - 1,
			col = 0,
			opts = {
				line_hl_group = "AgyCodeBlock",
				hl_group = "AgyCodeBlock",
				hl_eol = true,
				priority = 105,
			},
		})
		if lang_icon and icon_hl then
			local icon_len = #lang_icon
			table.insert(extmarks, {
				rel_row = #lines - 1,
				col = 0,
				opts = {
					hl_group = icon_hl,
					end_col = icon_len,
					priority = 125,
					hl_mode = "combine",
				},
			})
			table.insert(extmarks, {
				rel_row = #lines - 1,
				col = icon_len + 1,
				opts = {
					hl_group = "AgyCodeLang",
					end_col = #display_label,
					priority = 120,
					hl_mode = "combine",
				},
			})
		else
			table.insert(extmarks, {
				rel_row = #lines - 1,
				col = 0,
				opts = {
					hl_group = "AgyCodeLang",
					end_col = #display_label,
					priority = 120,
					hl_mode = "combine",
				},
			})
		end
	end

	local body_start_idx = #lines
	for idx, l in ipairs(body_lines) do
		table.insert(lines, l)
		table.insert(extmarks, {
			rel_row = body_start_idx + idx - 1,
			col = 0,
			opts = {
				line_hl_group = "AgyCodeBlock",
				hl_group = "AgyCodeBlock",
				hl_eol = true,
				priority = 105,
			},
		})
	end

	if #body_lines > 0 and lang and lang ~= "" then
		local full_code = table.concat(body_lines, "\n")
		apply_treesitter_highlights(full_code, lang, body_start_idx, extmarks)
	end

	return lines, extmarks
end

---Parse dimensions from PNG byte buffer
---@param data string
---@return number? width
---@return number? height
local function get_png_dimensions(data)
	if not data or #data < 24 then
		return nil, nil
	end
	if data:sub(1, 8) ~= "\137PNG\r\n\026\n" then
		return nil, nil
	end
	local b1, b2, b3, b4 = data:byte(17, 20)
	local b5, b6, b7, b8 = data:byte(21, 24)
	local w = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
	local h = b5 * 16777216 + b6 * 65536 + b7 * 256 + b8
	return w, h
end

---Parse dimensions from JPEG byte buffer
---@param data string
---@return number? width
---@return number? height
local function get_jpeg_dimensions(data)
	if not data or #data < 4 then
		return nil, nil
	end
	if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then
		return nil, nil
	end
	local pos = 3
	local len = #data
	while pos < len do
		if data:byte(pos) ~= 0xFF then
			pos = pos + 1
		else
			local marker = data:byte(pos + 1)
			pos = pos + 2
			if marker == 0xC0 or marker == 0xC1 or marker == 0xC2 then
				if pos + 7 <= len then
					local h = data:byte(pos + 3) * 256 + data:byte(pos + 4)
					local w = data:byte(pos + 5) * 256 + data:byte(pos + 6)
					return w, h
				end
				break
			elseif marker == 0xD9 or marker == 0xDA then
				break
			elseif pos + 2 <= len then
				local segment_len = data:byte(pos) * 256 + data:byte(pos + 1)
				pos = pos + segment_len
			else
				break
			end
		end
	end
	return nil, nil
end

---Emit Kitty graphics protocol escape sequence or register with vim.ui.img
---@param data string
---@param row number
---@param col number
---@param width number
---@param height number
---@return number? placement_id
function M.emit_kitty_image(data, row, col, width, height)
	if vim.ui and vim.ui.img and vim.ui.img.set then
		local ok, id = pcall(vim.ui.img.set, data, {
			row = row,
			col = col,
			width = width,
			height = height,
		})
		if ok then
			return id
		end
	end

	local base64_data = vim.base64.encode(data)
	local max_chunk = 4096
	local len = #base64_data

	if len <= max_chunk then
		local escape_seq = string.format(
			"\027_Ga=T,f=100,t=d,c=%d,r=%d,q=2;%s\027\\",
			width,
			height,
			base64_data
		)
		pcall(vim.api.nvim_ui_send, escape_seq)
	else
		local pos = 1
		while pos <= len do
			local chunk = base64_data:sub(pos, pos + max_chunk - 1)
			pos = pos + max_chunk
			local has_more = (pos <= len) and 1 or 0
			local escape_seq
			if pos - max_chunk == 1 then
				escape_seq = string.format(
					"\027_Ga=T,f=100,t=d,c=%d,r=%d,q=2,m=%d;%s\027\\",
					width,
					height,
					has_more,
					chunk
				)
			else
				escape_seq = string.format(
					"\027_Gm=%d;%s\027\\",
					has_more,
					chunk
				)
			end
			pcall(vim.api.nvim_ui_send, escape_seq)
		end
	end
	return nil
end

---Format an image tag into spacer lines and emit Kitty graphic command
---@param alt string
---@param src string
---@param img_icon string
---@param cwd? string
---@param is_final? boolean
---@return string[] lines
---@return table[] extmarks
function M.format_image(alt, src, img_icon, cwd, is_final)
	local lines = {}
	local extmarks = {}

	local path = src
	if vim.fn.isabsolutepath(path) == 0 and cwd then
		path = vim.fs.normalize(cwd .. "/" .. src)
	end

	local icon_str = img_icon .. (img_icon:sub(-1) == " " and "" or " ")
	local label = (alt and alt ~= "") and alt or vim.fs.basename(src)
	local title_line = "  " .. icon_str .. label

	if vim.fn.filereadable(path) == 1 then
		local f = io.open(path, "rb")
		local data = f and f:read("*a")
		if f then f:close() end

		if data and #data > 0 then
			local w, h = get_png_dimensions(data)
			if not w then
				w, h = get_jpeg_dimensions(data)
			end
			local cols = 40
			local rows = 10
			if w and h and w > 0 and h > 0 then
				rows = math.max(4, math.min(25, math.floor(cols * (h / w) * 0.5)))
			end

			table.insert(lines, title_line)
			table.insert(extmarks, {
				rel_row = #lines - 1,
				col = 0,
				opts = { hl_group = "AgyImage", end_col = #title_line },
			})

			for _ = 2, rows do
				table.insert(lines, "")
			end

			if is_final ~= false then
				M.emit_kitty_image(data, 1, 3, cols, rows)
			end
			return lines, extmarks
		end
	end

	local placeholder = "  " .. icon_str .. "[" .. label .. ": " .. src .. "]"
	table.insert(lines, placeholder)
	table.insert(extmarks, {
		rel_row = #lines - 1,
		col = 0,
		opts = { hl_group = "AgyImage", end_col = #placeholder },
	})
	return lines, extmarks
end

---Format list item or task checkbox
---@param line string
---@param bullets string[]
---@param uncheck_icon string
---@param check_icon string
---@return string? formatted_line
---@return table? extmark
function M.format_list_or_checkbox(line, bullets, uncheck_icon, check_icon)
	-- Check for unchecked checkbox: - [ ]
	local ind1, marker1, box1, rest1 = line:match("^(%s*)([-*+])%s+%[([%s])%]%s*(.*)$")
	if ind1 then
		local icon_str = uncheck_icon .. (uncheck_icon:sub(-1) == " " and "" or " ")
		local res = ind1 .. icon_str .. rest1
		local em = {
			col = #ind1,
			opts = { hl_group = "AgyCheckboxUnchecked", end_col = #ind1 + #icon_str },
		}
		return res, em
	end

	-- Check for checked checkbox: - [x]
	local ind2, marker2, box2, rest2 = line:match("^(%s*)([-*+])%s+%[([xX])%]%s*(.*)$")
	if ind2 then
		local icon_str = check_icon .. (check_icon:sub(-1) == " " and "" or " ")
		local res = ind2 .. icon_str .. rest2
		local em = {
			col = #ind2,
			opts = { hl_group = "AgyCheckboxChecked", end_col = #ind2 + #icon_str },
		}
		return res, em
	end

	-- Check for bullet list item: - item
	local ind3, marker3, rest3 = line:match("^(%s*)([-*+])%s+(.*)$")
	if ind3 then
		local level = math.floor(#ind3 / 2) + 1
		local bullet = bullets[((level - 1) % #bullets) + 1]
		local icon_str = bullet .. (bullet:sub(-1) == " " and "" or " ")
		local res = ind3 .. icon_str .. rest3
		local em = {
			col = #ind3,
			opts = { hl_group = "AgyListBullet", end_col = #ind3 + #icon_str },
		}
		return res, em
	end

	return nil, nil
end

---Format scaled header line (strips '#' prefix, returns clean text and line_hl_group extmark)
---@param line string
---@return string? formatted_line
---@return table? extmark
function M.format_header(line)
	local indent, hashes, spaces, rest = line:match("^(%s*)(#+)(%s+)(.*)$")
	if not indent and line:match("^(%s*)(#+)$") then
		indent, hashes = line:match("^(%s*)(#+)$")
		spaces = ""
		rest = ""
	end
	if indent and #indent <= 3 and hashes and #hashes >= 1 and #hashes <= 6 then
		local level = #hashes
		local clean_text = indent .. (rest or "")
		clean_text = clean_text:gsub("%s+#+%s*$", "")
		clean_text = clean_text:gsub("%s+$", "")
		local em = {
			col = 0,
			opts = {
				line_hl_group = "AgyH" .. level,
			},
		}
		return clean_text, em
	end
	return nil, nil
end

---Transform raw markdown text into presentation lines and extmark directives
---@param raw_text string
---@param is_final boolean
---@param config? table
---@param max_width? number
---@return string[] lines
---@return table[] extmarks
function M.transform_markdown(raw_text, is_final, config, max_width)
	local cfg = get_config(config)
	local t_icons = get_table_icons(cfg)
	local cb_icons = get_code_block_icons(cfg)
	local bullets = get_bullets(cfg)
	local uncheck_icon, check_icon = get_checkbox_icons(cfg)
	local img_icon = get_image_icon(cfg)

	if not max_width then
		max_width = (vim.o and vim.o.columns and vim.o.columns > 0) and vim.o.columns or 80
	end

	local raw_lines = utils.split_lines(raw_text)

	local output_lines = {}
	local extmarks = {}
	local all_links = {}

	local in_code_block = false
	local code_body = {}
	local code_lang = ""
	local code_fence_char = ""
	local code_fence_len = 0

	local table_lines = {}

	local function format_single_line(line)
		local alt, src = line:match("^%s*!%[(.-)%]%((.-)%)%s*$")
		if alt and src then
			local cwd = (cfg.workspaces and #cfg.workspaces > 0) and cfg.workspaces[1] or vim.fn.getcwd()
			local img_lines, img_exts = M.format_image(alt, src, img_icon, cwd, is_final)
			local base_row = #output_lines
			for _, il in ipairs(img_lines) do
				table.insert(output_lines, il)
			end
			for _, ie in ipairs(img_exts) do
				table.insert(extmarks, {
					rel_row = base_row + ie.rel_row,
					col = ie.col,
					opts = ie.opts,
				})
			end
		else
			local h_text, h_em = M.format_header(line)
			if h_text then
				local fmt_h, h_inlines, h_links = M.parse_inline_formatting(h_text)
				table.insert(output_lines, fmt_h)
				local cur_row = #output_lines - 1
				if h_em then
					table.insert(extmarks, {
						rel_row = cur_row,
						col = h_em.col,
						opts = h_em.opts,
					})
				end
				for _, im in ipairs(h_inlines) do
					table.insert(extmarks, {
						rel_row = cur_row,
						col = im.col,
						opts = {
							end_col = im.end_col,
							hl_group = im.hl_group,
							priority = 115,
							hl_mode = "combine",
						},
					})
				end
				for _, hl in ipairs(h_links or {}) do
					table.insert(all_links, {
						rel_row = cur_row,
						start_col = hl.start_col,
						end_col = hl.end_col,
						url = hl.url,
					})
				end
			else
				local l_text, l_em = M.format_list_or_checkbox(line, bullets, uncheck_icon, check_icon)
				if l_text then
					local prefix = l_text:sub(1, l_em.opts.end_col)
					local rest = l_text:sub(l_em.opts.end_col + 1)
					local fmt_rest, l_inlines, l_links = M.parse_inline_formatting(rest)
					local final_line = prefix .. fmt_rest
					table.insert(output_lines, final_line)
					local cur_row = #output_lines - 1
					table.insert(extmarks, {
						rel_row = cur_row,
						col = l_em.col,
						opts = l_em.opts,
					})
					for _, im in ipairs(l_inlines) do
						table.insert(extmarks, {
							rel_row = cur_row,
							col = #prefix + im.col,
							opts = {
								end_col = #prefix + im.end_col,
								hl_group = im.hl_group,
								priority = 115,
								hl_mode = "combine",
							},
						})
					end
					for _, ll in ipairs(l_links or {}) do
						table.insert(all_links, {
							rel_row = cur_row,
							start_col = #prefix + ll.start_col,
							end_col = #prefix + ll.end_col,
							url = ll.url,
						})
					end
				else
					local fmt_line, inlines, line_links = M.parse_inline_formatting(line)
					table.insert(output_lines, fmt_line)
					local cur_row = #output_lines - 1
					for _, im in ipairs(inlines) do
						table.insert(extmarks, {
							rel_row = cur_row,
							col = im.col,
							opts = {
								end_col = im.end_col,
								hl_group = im.hl_group,
								priority = 115,
								hl_mode = "combine",
							},
						})
					end
					for _, ll in ipairs(line_links or {}) do
						table.insert(all_links, {
							rel_row = cur_row,
							start_col = ll.start_col,
							end_col = ll.end_col,
							url = ll.url,
						})
					end
				end
			end
		end
	end

	local function flush_table()
		if #table_lines == 0 then
			return
		end
		local t_lines, t_exts = M.format_table(table_lines, t_icons, max_width)
		if t_lines then
			local base_row = #output_lines
			for _, tl in ipairs(t_lines) do
				table.insert(output_lines, tl)
			end
			for _, te in ipairs(t_exts) do
				table.insert(extmarks, {
					rel_row = base_row + te.rel_row,
					col = te.col,
					opts = te.opts,
				})
				if te.url then
					table.insert(all_links, {
						rel_row = base_row + te.rel_row,
						start_col = te.col,
						end_col = te.opts.end_col,
						url = te.url,
					})
				end
			end
		else
			for _, tl in ipairs(table_lines) do
				format_single_line(tl)
			end
		end
		table_lines = {}
	end

	for _, line in ipairs(raw_lines) do
		if in_code_block then
			local fence_match = line:match("^%s*(```+)%s*$") or line:match("^%s*(~~~+)%s*$")
			if fence_match and fence_match:sub(1, 1) == code_fence_char and #fence_match >= code_fence_len then
				local c_lines, c_exts = M.format_code_block(code_body, code_lang, cb_icons)
				local base_row = #output_lines
				for _, cl in ipairs(c_lines) do
					table.insert(output_lines, cl)
				end
				for _, ce in ipairs(c_exts) do
					local opts = vim.deepcopy(ce.opts)
					if opts.end_row_rel then
						opts.end_row_rel = base_row + opts.end_row_rel
					end
					table.insert(extmarks, {
						rel_row = base_row + ce.rel_row,
						col = ce.col,
						opts = opts,
					})
				end
				in_code_block = false
				code_body = {}
			else
				table.insert(code_body, line)
			end
		else
			local fence, lang = line:match("^%s*(```+)%s*(%S*)$")
			if not fence then
				fence, lang = line:match("^%s*(~~~+)%s*(%S*)$")
			end
			if fence then
				flush_table()
				in_code_block = true
				code_lang = lang or ""
				code_fence_char = fence:sub(1, 1)
				code_fence_len = #fence
				code_body = {}
			else
				local is_table_candidate = line:find("|", 1, true) ~= nil
					and not line:match("^%s*[-*+]%s+")
					and not line:match("^%s*#+%s+")
					and not line:match("^%s*```")
					and not line:match("^%s*~~~")

				if is_table_candidate then
					table.insert(table_lines, line)
				else
					flush_table()
					format_single_line(line)
				end
			end
		end
	end

	flush_table()

	if in_code_block then
		local c_lines, c_exts = M.format_code_block(code_body, code_lang, cb_icons)
		local base_row = #output_lines
		for _, cl in ipairs(c_lines) do
			table.insert(output_lines, cl)
		end
		for _, ce in ipairs(c_exts) do
			local opts = vim.deepcopy(ce.opts)
			if opts.end_row_rel then
				opts.end_row_rel = base_row + opts.end_row_rel
			end
			table.insert(extmarks, {
				rel_row = base_row + ce.rel_row,
				col = ce.col,
				opts = opts,
			})
		end
	end

	return output_lines, extmarks, all_links
end

---Stream-friendly markdown renderer function
---@param buf number
---@param delta string
---@param is_final boolean
---@param config? table
function M.render(buf, delta, is_final, config)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local cfg = get_config(config)

	local session = M.sessions[buf]
	if not session or (session.start_line and session.start_line >= vim.api.nvim_buf_line_count(buf)) then
		session = {
			raw_text = "",
			start_line = nil,
			rendered_count = 0,
		}
		M.sessions[buf] = session
	end

	if delta and delta ~= "" then
		session.raw_text = session.raw_text .. delta
	end

	if session.raw_text == "" then
		if is_final then
			M.sessions[buf] = nil
		end
		return
	end

	local prev_mod = vim.bo[buf].modifiable
	vim.bo[buf].modifiable = true

	if session.start_line == nil then
		local render_mod = require("agy.render")
		local boundary_row, agent_row = render_mod.get_agent_boundary(buf)
		local target_line
		if boundary_row then
			local sep_row = boundary_row - 1
			local prev_row = sep_row - 1
			if not agent_row or prev_row <= agent_row then
				vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { "" })
				target_line = sep_row
			else
				local prev_line = vim.api.nvim_buf_get_lines(buf, prev_row, prev_row + 1, false)[1] or ""
				if render_mod.is_compact_header_line(prev_line, cfg) then
					vim.api.nvim_buf_set_lines(buf, sep_row, sep_row, false, { "", "" })
					target_line = sep_row + 1
				else
					target_line = prev_row
				end
			end
		else
			target_line = vim.api.nvim_buf_line_count(buf) - 1
			local last_line = vim.api.nvim_buf_get_lines(buf, target_line, target_line + 1, false)[1] or ""
			if render_mod.is_compact_header_line(last_line, cfg) then
				local line_count = vim.api.nvim_buf_line_count(buf)
				vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", "" })
				target_line = vim.api.nvim_buf_line_count(buf) - 1
			end
		end

		local current_text = vim.api.nvim_buf_get_lines(buf, target_line, target_line + 1, false)[1] or ""
		if current_text ~= "" and session.raw_text == delta then
			session.raw_text = current_text .. session.raw_text
		end

		session.start_line = target_line
		session.rendered_count = 1
	end

	local win_w = 80
	if buf and vim.api.nvim_buf_is_valid(buf) then
		local render_mod = require("agy.render")
		if render_mod.get_max_window_width then
			win_w = render_mod.get_max_window_width(buf)
		end
	end

	local lines, extmark_directives, links = M.transform_markdown(session.raw_text, is_final, cfg, win_w)

	local start_row = session.start_line
	local end_row = start_row + session.rendered_count

	vim.api.nvim_buf_clear_namespace(buf, M.NS_MARKDOWN, start_row, end_row)
	vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, lines)
	session.rendered_count = #lines

	local buf_links = {}
	for _, l in ipairs(links or {}) do
		local r0 = start_row + l.rel_row
		table.insert(buf_links, {
			row = r0 + 1,
			row_0 = r0,
			start_col = l.start_col,
			end_col = l.end_col,
			url = l.url,
		})
	end

	local preserved = {}
	for _, existing in ipairs(M.links[buf] or {}) do
		if existing.row_0 < start_row then
			table.insert(preserved, existing)
		end
	end
	for _, bl in ipairs(buf_links) do
		table.insert(preserved, bl)
	end
	M.links[buf] = preserved

	for _, em in ipairs(extmark_directives) do
		local em_row = start_row + em.rel_row
		if em_row < vim.api.nvim_buf_line_count(buf) then
			local opts = vim.deepcopy(em.opts)
			if opts.end_row_rel then
				opts.end_row = start_row + opts.end_row_rel
				opts.end_row_rel = nil
			end
			pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_MARKDOWN, em_row, em.col or 0, opts)
		end
	end

	if is_final then
		if M.last_raw[buf] and M.last_raw[buf] ~= "" and M.last_raw[buf] ~= session.raw_text then
			M.last_raw[buf] = M.last_raw[buf] .. "\n\n" .. session.raw_text
		else
			M.last_raw[buf] = session.raw_text
		end
		M.sessions[buf] = nil
	end

	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = prev_mod
end

---Render a complete markdown document into buffer starting at line 1 (0-indexed row 0)
---@param buf number
---@param text string
---@param config? table
function M.render_document(buf, text, config)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local cfg = get_config(config)
	local prev_mod = vim.bo[buf].modifiable
	vim.bo[buf].modifiable = true

	local win_w = 80
	local render_mod = require("agy.render")
	if render_mod.get_max_window_width then
		win_w = render_mod.get_max_window_width(buf)
	end

	local lines, extmark_directives, links = M.transform_markdown(text, true, cfg, win_w)

	vim.api.nvim_buf_clear_namespace(buf, M.NS_MARKDOWN, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local buf_links = {}
	for _, l in ipairs(links or {}) do
		table.insert(buf_links, {
			row = l.rel_row + 1,
			row_0 = l.rel_row,
			start_col = l.start_col,
			end_col = l.end_col,
			url = l.url,
		})
	end
	M.links[buf] = buf_links

	for _, em in ipairs(extmark_directives) do
		local em_row = em.rel_row
		if em_row < vim.api.nvim_buf_line_count(buf) then
			local opts = vim.deepcopy(em.opts)
			if opts.end_row_rel then
				opts.end_row = opts.end_row_rel
				opts.end_row_rel = nil
			end
			pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_MARKDOWN, em_row, em.col or 0, opts)
		end
	end

	M.last_raw[buf] = text
	M.sessions[buf] = nil

	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = prev_mod
end

---Finalize active markdown stream block for buffer
---@param buf number
---@param config? table
function M.finalize(buf, config)
	if M.sessions[buf] then
		M.render(buf, "", true, config)
	end
end

---Reset markdown stream state for buffer
---@param buf number
function M.reset(buf)
	M.sessions[buf] = nil
	M.last_raw[buf] = nil
	M.links[buf] = nil
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_clear_namespace, buf, M.NS_MARKDOWN, 0, -1)
	end
end

---Get canonical raw markdown text for buffer
---@param buf number
---@return string
function M.get_raw_text(buf)
	local cur = M.sessions[buf] and M.sessions[buf].raw_text
	local prev = M.last_raw[buf]
	if prev and prev ~= "" and cur and cur ~= "" and prev ~= cur then
		return prev .. "\n\n" .. cur
	elseif cur and cur ~= "" then
		return cur
	end
	return prev or ""
end

---Get link under cursor or position in buffer
---@param buf number
---@param row number 1-indexed buffer line number (e.g. from nvim_win_get_cursor)
---@param col number 0-indexed column
---@return table? link { row = number, start_col = number, end_col = number, url = string }
function M.get_link_at(buf, row, col)
	buf = (buf and vim.api.nvim_buf_is_valid(buf)) and buf or vim.api.nvim_get_current_buf()
	local links = M.links[buf]
	if not links or #links == 0 then
		return nil
	end
	for _, link in ipairs(links) do
		local row_match = (link.row == row) or (row == 0 and link.row == 1)
		if row_match and col >= link.start_col and (col < link.end_col or (link.start_col == link.end_col and col == link.start_col)) then
			return link
		end
	end
	return nil
end

---Parse a file:// URL into file path, line, and column
---@param url string
---@return string? file_path
---@return number? line
---@return number? col
function M.parse_file_url(url)
	if not url or not url:match("^file://") then
		return nil, nil, nil
	end

	local rest = url:sub(8) -- strip "file://"

	local line = nil
	local col = nil

	-- Suffix Pattern 1: #L42-L50, #L42:10, #L42C10, #L42
	local r_l1 = rest:match("#[Ll](%d+)%-[Ll]?(%d+)")
	if r_l1 then
		line = tonumber(r_l1)
		rest = rest:gsub("#[Ll]%d+%-[Ll]?%d+", "")
	else
		local lc_l, lc_c = rest:match("#[Ll](%d+)[:Cc](%d+)")
		if lc_l then
			line = tonumber(lc_l)
			col = tonumber(lc_c)
			rest = rest:gsub("#[Ll]%d+[:Cc]%d+", "")
		else
			local single_l = rest:match("#[Ll](%d+)")
			if single_l then
				line = tonumber(single_l)
				rest = rest:gsub("#[Ll]%d+", "")
			end
		end
	end

	-- Suffix Pattern 1b: #42:10 or #42 (pure numeric fragment without 'L')
	if not line then
		local num_l, num_c = rest:match("#(%d+)[:Cc](%d+)")
		if num_l then
			line = tonumber(num_l)
			col = tonumber(num_c)
			rest = rest:gsub("#%d+[:Cc]%d+", "")
		else
			local num_single = rest:match("#(%d+)")
			if num_single then
				line = tonumber(num_single)
				rest = rest:gsub("#%d+", "")
			end
		end
	end

	-- Suffix Pattern 2: :42:10 or :42 at end of path (guard against Windows drive letter colon e.g. C:)
	if not line and not rest:match("^[a-zA-Z]:%d") then
		local lp1, cp1 = rest:match(":(%d+):(%d+)$")
		if lp1 then
			line = tonumber(lp1)
			col = tonumber(cp1)
			rest = rest:gsub(":%d+:%d+$", "")
		else
			local lp2 = rest:match(":(%d+)$")
			if lp2 then
				line = tonumber(lp2)
				rest = rest:gsub(":%d+$", "")
			end
		end
	end

	-- Strip any remaining fragment or query
	rest = rest:gsub("#.*$", "")
	rest = rest:gsub("%?.*$", "")

	-- Percent-decode URL characters (e.g. %20 -> space)
	rest = rest:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)

	-- Windows drive letter: file:///C:/... or file://C:/... or file://localhost/C:/...
	if rest:match("^localhost/[a-zA-Z]:") then
		rest = rest:gsub("^localhost/", "")
	elseif rest:match("^localhost/+") then
		rest = rest:gsub("^localhost/+", "/")
	end

	if rest:match("^/+[a-zA-Z]:") then
		rest = rest:gsub("^/+", "")
	elseif rest:match("^/+") then
		-- Unix absolute path: file:///path/to/file -> /path/to/file
		rest = rest:gsub("^/+", "/")
	end

	rest = vim.fs.normalize(rest)
	return rest, line, col
end

---Open a URL: either file:// in Neovim buffer, or external system URL
---@param url string
---@return boolean handled
function M.open_link(url)
	if not url or url == "" then
		return false
	end

	if url:match("^file://") then
		local path, line, col = M.parse_file_url(url)
		if path and path ~= "" then
			local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
			if not ok then
				vim.notify("[agy.nvim] Failed to open file: " .. tostring(err), vim.log.levels.ERROR)
				return false
			end
			if line then
				local max_line = vim.api.nvim_buf_line_count(0)
				local target_line = math.min(math.max(1, line), max_line)
				local line_str = vim.api.nvim_buf_get_lines(0, target_line - 1, target_line, false)[1] or ""
				local target_col = col and math.min(math.max(0, col - 1), #line_str) or 0
				pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col })
			end
			return true
		end
		return false
	end

	-- Web or other system protocol: http://, https://, mailto:, etc.
	if vim.ui and vim.ui.open then
		local ok, res = pcall(vim.ui.open, url)
		if ok and res then
			return true
		end
	end

	local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
	local is_mac = vim.fn.has("mac") == 1
	if is_win then
		pcall(vim.fn.jobstart, { "cmd.exe", "/c", "start", "", url }, { detach = true })
	elseif is_mac then
		pcall(vim.fn.jobstart, { "open", url }, { detach = true })
	else
		pcall(vim.fn.jobstart, { "xdg-open", url }, { detach = true })
	end
	return true
end

---Display a clean floating hover window showing the link destination URL via Neovim's standard LSP preview API
---@param buf number
---@param link table { row = number, start_col = number, end_col = number, url = string }
---@param cfg? table
---@return number win
---@return number float_buf
function M.show_link_hover(buf, link, cfg)
	local icon = get_link_icon(cfg)
	local line = icon .. " " .. link.url
	local float_buf, win = vim.lsp.util.open_floating_preview({ line }, "markdown", {
		border = "rounded",
		focus_id = "agy_link_hover",
	})
	return win, float_buf
end

return M
