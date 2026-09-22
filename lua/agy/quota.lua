local utils = require("agy.utils")
local panel = require("agy.panel")

local M = {}

M.NS_QUOTA = vim.api.nvim_create_namespace("agy_quota")

---Cache for quota data with TTL
M._cache = nil
M._cache_time = 0
M.CACHE_TTL_SECONDS = 30

---Fetch quota data from agy CLI asynchronously via agy.async
---@param agy_cmd? string
---@return table quota_data
function M.fetch_async(agy_cmd)
  local now = os.time()
  if M._cache and (now - M._cache_time) < M.CACHE_TTL_SECONDS then
    return M._cache
  end

  local async = require("agy.async")
  agy_cmd = agy_cmd or "agy"
  local cmd = { agy_cmd, "-p=/usage", "--output-format", "json" }

  local ok_proc, obj = async.psystem(cmd, { stdin = false, text = true })
  if not ok_proc or not obj then
    error("Command execution failed: " .. tostring(obj))
  end
  if obj.code ~= 0 then
    error("Command failed with exit code " .. tostring(obj.code) .. ": " .. utils.trim(obj.stderr or ""))
  end

  local trimmed = utils.trim(obj.stdout or "")
  local ok, parsed = pcall(vim.json.decode, trimmed)
  if not ok or not parsed then
    error("Failed to parse JSON response: " .. tostring(parsed))
  end

  local quota_data = parsed.command and parsed.command.data
  if not quota_data then
    error("No quota data found in response")
  end

  M._cache = quota_data
  M._cache_time = os.time()
  return quota_data
end

---Fetch quota data from agy CLI in JSON format
---@param agy_cmd string
---@param callback fun(err?: string, data?: table)
function M.fetch(agy_cmd, callback)
  local async = require("agy.async")
  async.run(function()
    local ok, res = async.pawait(M.fetch_async, agy_cmd)
    if ok then
      callback(nil, res)
    else
      callback(tostring(res), nil)
    end
  end)
end

local function is_leap_year(y)
  return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local days_before_month = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }

local function utc_to_epoch(y, m, d, h, min, sec)
  y = tonumber(y)
  m = tonumber(m)
  d = tonumber(d)
  h = tonumber(h)
  min = tonumber(min)
  sec = tonumber(sec)

  local days = (y - 1970) * 365
    + math.floor((y - 1969) / 4)
    - math.floor((y - 1901) / 100)
    + math.floor((y - 1601) / 400)
    + days_before_month[m]
    + (m > 2 and is_leap_year(y) and 1 or 0)
    + (d - 1)
  return days * 86400 + h * 3600 + min * 60 + sec
end

---Format reset time from ISO 8601 UTC timestamp
---@param fraction number
---@param reset_time_str? string
---@return string status_str
function M.format_reset_time(fraction, reset_time_str)
  if fraction >= 0.9999 then
    return "Quota available"
  end

  if not reset_time_str or reset_time_str == "" then
    return (fraction <= 0.0001) and "Quota exhausted" or "Quota available"
  end

  local y, m, d, h, min, sec = reset_time_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return "Quota available"
  end

  local target_epoch = utc_to_epoch(y, m, d, h, min, sec)
  local now_epoch = os.time()
  local diff = target_epoch - now_epoch

  if diff <= 0 then
    return "Quota available"
  end

  local hours = math.floor(diff / 3600)
  local mins = math.floor((diff % 3600) / 60)

  if hours > 0 then
    return string.format("Refreshes in %dh %dm", hours, mins)
  elseif mins > 0 then
    return string.format("Refreshes in %dm", mins)
  else
    return "Refreshes in <1m"
  end
end

---Word-wrap text into lines
---@param text string
---@param max_len number
---@return string[]
function M.wrap_text(text, max_len)
  max_len = max_len or 72
  local lines = {}
  for paragraph in text:gmatch("[^\r\n]+") do
    local current = ""
    for word in paragraph:gmatch("%S+") do
      if #current == 0 then
        current = word
      elseif #current + 1 + #word <= max_len then
        current = current .. " " .. word
      else
        table.insert(lines, current)
        current = word
      end
    end
    if #current > 0 then
      table.insert(lines, current)
    end
  end
  return lines
end

---Build formatted lines and metadata for the Models & Quota panel
---@param data? table Quota data from agy CLI
---@param email? string
---@param session_info? table
---@param width? number
---@param model_name? string
---@param effort? string
---@return string[] lines
---@return table[] meta Line metadata for highlighting
function M.build_content(data, email, session_info, width, model_name, effort)
  local lines = {}
  local meta = {}
  width = width or 80

  local function add_line(text, line_type, extra)
    table.insert(lines, text)
    table.insert(meta, {
      row = #lines - 1,
      type = line_type,
      extra = extra,
    })
  end

  add_line("🗎 Models & Quota", "title")
  add_line("", "empty")
  add_line("Account: " .. (email or "Active Account"), "account", { email = email })
  add_line("", "empty")

  local nav_left = (width >= 75)
      and "↑/↓ Scroll · pgup/pgdown Page · ctrl+end Bottom · ctrl+home Top · esc Close"
      or "↑/↓ Scroll · pgup/down Page · esc Close"
  local right_model = (model_name and model_name ~= "") and (model_name .. " · " .. (effort or "high")) or "Antigravity"

  if not data or not data.groups or #data.groups == 0 then
    add_line("Loading Models & Quota...", "loading")
    add_line("", "empty")
    local footer_line = panel.format_footer(nav_left, right_model, width)
    add_line(footer_line, "footer", { text = footer_line })
    return lines, meta
  end

  for g_idx, group in ipairs(data.groups) do
    local g_name = group.name or "MODELS"
    add_line(string.upper(g_name), "group_header", { name = g_name })

    local desc = group.description or ""
    if desc ~= "" then
      add_line(" Models within this group: " .. desc:gsub("^Models within this group:%s*", ""), "group_desc")
    end
    add_line("", "empty")

    for _, bucket in ipairs(group.buckets or {}) do
      local b_name = bucket.name or "Limit Remaining"
      add_line(" " .. ("Weekly Limit Remaining" == b_name and "Weekly Limit Remaining" or b_name), "bucket_name")

      local fraction = bucket.remaining_fraction or 1.0
      local pct = fraction * 100
      local bar_width = 46
      local filled = math.min(bar_width, math.max(0, math.floor(fraction * bar_width + 0.5)))
      local empty = bar_width - filled

      local bar_str = string.format("  [%s%s] %.2f%%", string.rep("█", filled), string.rep("░", empty), pct)
      add_line(bar_str, "progress_bar", {
        fraction = fraction,
        filled = filled,
        empty = empty,
        bar_width = bar_width,
      })

      local reset_str = M.format_reset_time(fraction, bucket.reset_time)
      add_line("  " .. reset_str, "reset_status", {
        fraction = fraction,
        status = reset_str,
      })
      add_line("", "empty")
    end
  end

  if data.description and data.description ~= "" then
    local note_lines = M.wrap_text(data.description, math.min(74, width - 4))
    for _, nl in ipairs(note_lines) do
      add_line("│ " .. nl, "quote")
    end
    add_line("", "empty")
  end

  if session_info and session_info.total_tokens and session_info.total_tokens > 0 then
    local stats = {}
    table.insert(stats, "Session: " .. utils.format_tokens(session_info.total_tokens))
    if session_info.duration_seconds and session_info.duration_seconds > 0 then
      table.insert(stats, utils.format_duration(session_info.duration_seconds))
    end
    if session_info.tools_count and session_info.tools_count > 0 then
      table.insert(stats, tostring(session_info.tools_count) .. " tools")
    end
    add_line("  " .. table.concat(stats, "  •  "), "session_stats")
    add_line("", "empty")
  end

  local footer_line = panel.format_footer(nav_left, right_model, width)
  add_line(footer_line, "footer", { text = footer_line })

  return lines, meta
end

---Apply syntax highlights to the quota panel
---@param buf number
---@param meta table[]
function M.apply_highlights(buf, meta)
  vim.api.nvim_buf_clear_namespace(buf, M.NS_QUOTA, 0, -1)

  for _, m in ipairs(meta) do
    local row = m.row
    local l_type = m.type
    local line_str = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""

    if l_type == "title" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, 0, {
        end_col = #line_str,
        hl_group = "AgyQuotaTitle",
      })

    elseif l_type == "account" then
      local s_acc, e_acc = line_str:find("Account:", 1, true)
      if s_acc then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, s_acc - 1, {
          end_col = e_acc,
          hl_group = "Comment",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, e_acc, {
          end_col = #line_str,
          hl_group = "Special",
        })
      end

    elseif l_type == "group_header" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, 0, {
        end_col = #line_str,
        hl_group = "AgyQuotaGroupTitle",
      })

    elseif l_type == "group_desc" then
      local s_pref, e_pref = line_str:find("Models within this group:", 1, true)
      if s_pref then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, s_pref - 1, {
          end_col = e_pref,
          hl_group = "Comment",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, e_pref, {
          end_col = #line_str,
          hl_group = "Normal",
        })
      end

    elseif l_type == "bucket_name" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, 0, {
        end_col = #line_str,
        hl_group = "AgyQuotaBucketTitle",
      })

    elseif l_type == "progress_bar" then
      local extra = m.extra or {}
      local fraction = extra.fraction or 1.0
      local filled = extra.filled or 0
      local empty = extra.empty or 0

      local open_pos = line_str:find("[", 1, true)
      local close_pos = line_str:find("]", 1, true)

      if open_pos and close_pos then
        -- Highlight [
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, open_pos - 1, {
          end_col = open_pos,
          hl_group = "AgyQuotaBracket",
        })

        -- Filled bar
        local fill_hl = "AgyQuotaFill"
        if fraction < 0.20 then
          fill_hl = "AgyQuotaFillError"
        elseif fraction < 0.50 then
          fill_hl = "AgyQuotaFillWarn"
        end

        local fill_start = open_pos
        local fill_end = fill_start + (filled * 3) -- UTF-8 3-byte '█'
        if filled > 0 then
          pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, fill_start, {
            end_col = fill_end,
            hl_group = fill_hl,
          })
        end

        -- Empty bar
        local empty_start = fill_end
        local empty_end = close_pos - 1
        if empty > 0 and empty_start < empty_end then
          pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, empty_start, {
            end_col = empty_end,
            hl_group = "AgyQuotaEmpty",
          })
        end

        -- Highlight ]
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, close_pos - 1, {
          end_col = close_pos,
          hl_group = "AgyQuotaBracket",
        })

        -- Highlight percentage
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, close_pos, {
          end_col = #line_str,
          hl_group = "AgyQuotaPercent",
        })
      end

    elseif l_type == "reset_status" then
      local extra = m.extra or {}
      local status = extra.status or ""
      local hl = (status == "Quota available") and "AgyQuotaAvailable" or "Comment"
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, 0, {
        end_col = #line_str,
        hl_group = hl,
      })

    elseif l_type == "quote" then
      local bar_pos = line_str:find("│", 1, true)
      if bar_pos then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, bar_pos - 1, {
          end_col = bar_pos + 2, -- UTF-8 3-byte '│'
          hl_group = "AgyQuotaQuoteBar",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, bar_pos + 2, {
          end_col = #line_str,
          hl_group = "Comment",
        })
      end

    elseif l_type == "session_stats" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_QUOTA, row, 0, {
        end_col = #line_str,
        hl_group = "Comment",
      })

    elseif l_type == "footer" then
      local extra = m.extra or {}
      panel.apply_footer_highlights(buf, M.NS_QUOTA, row, extra.text or line_str)
    end
  end
end

---Setup highlight groups for Quota view
function M.setup_highlights()
  local set_hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  set_hl("AgyQuotaTitle", { bold = true, fg = "#7aa2f7" })
  set_hl("AgyQuotaGroupTitle", { bold = true, fg = "#7aa2f7" })
  set_hl("AgyQuotaBucketTitle", { bold = true, fg = "#c0caf5" })
  set_hl("AgyQuotaBracket", { fg = "#565f89" })
  set_hl("AgyQuotaFill", { fg = "#9ece6a", bold = true })
  set_hl("AgyQuotaFillWarn", { fg = "#e0af68", bold = true })
  set_hl("AgyQuotaFillError", { fg = "#f7768e", bold = true })
  set_hl("AgyQuotaEmpty", { fg = "#3b4261" })
  set_hl("AgyQuotaPercent", { fg = "#c0caf5", bold = true })
  set_hl("AgyQuotaAvailable", { fg = "#9ece6a" })
  set_hl("AgyQuotaQuoteBar", { fg = "#565f89" })
end

---Open interactive Models & Quota panel in the lower autocomplete area
---@param caller_buf? number
---@return number win, number buf
function M.open(caller_buf)
  M.setup_highlights()

  caller_buf = (caller_buf and vim.api.nvim_buf_is_valid(caller_buf)) and caller_buf or vim.api.nvim_get_current_buf()
  local target_win = vim.fn.bufwinid(caller_buf)
  if target_win == -1 or not vim.api.nvim_win_is_valid(target_win) then
    target_win = vim.api.nvim_get_current_win()
  end

  local protocol = package.loaded["agy.protocol"]
  local pstate = protocol and protocol.buffers and protocol.buffers[caller_buf]
  local session_info = pstate and pstate.stream_info or {}
  local cfg = pstate and pstate.config or require("agy.config").get()
  local agy_cmd = cfg.agy_cmd or "agy"

  local email = utils.get_account_email(cfg.app_data_dir) or "Active Account"
  local model_name = session_info.model or (pstate and pstate.session and pstate.session.model) or "Gemini 3.8 Flash"
  local effort = (pstate and pstate.session and pstate.session.effort) or "high"

  local width = vim.api.nvim_win_get_width(target_win)

  -- Initial content (cached or loading)
  local initial_data = M._cache
  local initial_lines, initial_meta = M.build_content(initial_data, email, session_info, width, model_name, effort)

  local win, buf = panel.open({
    target_win = target_win,
    target_buf = caller_buf,
    lines = initial_lines,
    meta = initial_meta,
    apply_highlights = M.apply_highlights,
    filetype = "agy_quota",
  })

  -- Fetch fresh quota asynchronously using agy.async
  local async = require("agy.async")
  async.run(function()
    local ok, quota_data = async.pawait(M.fetch_async, agy_cmd)
    if not panel.is_open() or panel.get_buf() ~= buf then
      return
    end

    local fresh_lines, fresh_meta
    if not ok then
      fresh_lines = {
        "🗎 Models & Quota",
        "",
        "Account: " .. email,
        "",
        "Failed to load Models & Quota from agy CLI:",
        "  " .. tostring(quota_data),
        "",
      }
      local footer = panel.format_footer("esc Close", model_name .. " · " .. effort, width)
      table.insert(fresh_lines, footer)
      fresh_meta = {
        { row = 0, type = "title" },
        { row = 2, type = "account" },
        { row = #fresh_lines - 1, type = "footer", extra = { text = footer } },
      }
    else
      fresh_lines, fresh_meta = M.build_content(quota_data, email, session_info, width, model_name, effort)
    end

    panel.update(fresh_lines, fresh_meta)
  end)

  return win, buf
end

return M
