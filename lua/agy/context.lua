local utils = require("agy.utils")
local panel = require("agy.panel")
local transcript_mod = require("agy.transcript")

local M = {}

M.NS_CONTEXT = vim.api.nvim_create_namespace("agy_context")

---Model context window token limits
M.MODEL_LIMITS = {
  ["gemini-3.8-flash"] = 1048576,
  ["gemini-2.5-flash"] = 1048576,
  ["gemini-flash"] = 1048576,
  ["gemini-3.8-pro"] = 2097152,
  ["gemini-2.5-pro"] = 2097152,
  ["gemini-pro"] = 2097152,
  ["claude-3.7-sonnet"] = 200000,
  ["claude-3.5-sonnet"] = 200000,
  ["claude-opus"] = 200000,
  ["gpt-4o"] = 128000,
  ["gpt-oss"] = 128000,
  ["gpt-4.5"] = 128000,
}

---Resolve model maximum context window token capacity
---@param model_name? string
---@return number max_tokens
function M.get_model_limit(model_name)
  if not model_name or model_name == "" then
    return 1048576
  end
  local lower = model_name:lower()
  for pat, limit in pairs(M.MODEL_LIMITS) do
    if lower:find(pat, 1, true) then
      return limit
    end
  end
  if lower:find("flash") then
    return 1048576
  elseif lower:find("pro") then
    return 2097152
  elseif lower:find("claude") or lower:find("sonnet") or lower:find("opus") then
    return 200000
  elseif lower:find("gpt") then
    return 128000
  end
  return 1048576
end

---Count active skills and rules
---@param app_data_dir string
---@param workspace_dir string
---@return number skills_count, number rules_count
function M.detect_customizations(app_data_dir, workspace_dir)
  local skills_count = 0
  local rules_count = 0

  -- Builtin & user skills
  local skills_dirs = {
    app_data_dir .. "/builtin/skills",
    app_data_dir .. "/skills",
    workspace_dir .. "/.gemini/skills",
  }
  for _, d in ipairs(skills_dirs) do
    if vim.fn.isdirectory(d) == 1 then
      local entries = vim.fn.readdir(d)
      skills_count = skills_count + #entries
    end
  end

  -- Rules
  local rules_dirs = {
    app_data_dir .. "/rules",
    workspace_dir .. "/.gemini/rules",
  }
  for _, d in ipairs(rules_dirs) do
    if vim.fn.isdirectory(d) == 1 then
      local entries = vim.fn.readdir(d)
      rules_count = rules_count + #entries
    end
  end

  return math.max(2, skills_count), rules_count
end

---Build context breakdown lines and metadata
---@param pstate table
---@param cfg table
---@param width number
---@return string[] lines, table[] meta
function M.build_content(pstate, cfg, width)
  pstate = pstate or {}
  cfg = cfg or {}
  local session_info = pstate.stream_info or {}
  local session = pstate.session or {}

  local conv_id = pstate.conversation_id or session.conversation_id or "new"
  local model_name = session_info.model or session.model or "Gemini 3.8 Flash"
  local effort = session_info.effort or session.effort or "high"

  local max_limit = M.get_model_limit(model_name)

  -- Gather transcript steps if possible
  local user_turns = 0
  local agent_turns = 0
  local tool_count = session_info.tools_count or 0
  local user_chars = 0
  local model_chars = 0
  local tool_chars = 0

  if conv_id ~= "" and conv_id ~= "new" then
    local steps = transcript_mod.read_transcript(conv_id, cfg.app_data_dir)
    for _, s in ipairs(steps) do
      if s.type == "USER_INPUT" then
        user_turns = user_turns + 1
        user_chars = user_chars + #(s.content or "")
      elseif s.type == "PLANNER_RESPONSE" then
        agent_turns = agent_turns + 1
        model_chars = model_chars + #(s.content or "") + #(s.thinking or "")
      elseif s.type == "TOOL_CALL" or s.type == "TOOL_RESULT" then
        tool_count = tool_count + 1
        tool_chars = tool_chars + #(s.content or "")
      end
    end
  end

  if user_turns == 0 and pstate.prompt_start_line and pstate.buf and vim.api.nvim_buf_is_valid(pstate.buf) then
    local prompt_lines = vim.api.nvim_buf_get_lines(pstate.buf, 0, pstate.prompt_start_line - 1, false)
    for _, l in ipairs(prompt_lines) do
      if l:find("── 👤 User") then
        user_turns = user_turns + 1
      elseif l:find("── 🤖 Antigravity") then
        agent_turns = agent_turns + 1
      end
    end
  end

  -- Workspaces
  local raw_ws = session.workspaces or {}
  local workspaces = {}
  if #raw_ws > 0 then
    for _, w in ipairs(raw_ws) do
      table.insert(workspaces, w)
    end
  else
    table.insert(workspaces, vim.fn.getcwd())
  end

  local skills_count, rules_count = M.detect_customizations(cfg.app_data_dir or "", workspaces[1] or "")

  -- Token estimation
  local sys_tokens = 12500
  local skills_tokens = 2500 + (skills_count * 800) + (rules_count * 400)
  local ws_tokens = 6800

  local user_tokens = math.max(120, math.floor(user_chars / 3.8))
  local model_tokens = math.max(250, math.floor(model_chars / 3.8))
  local tool_tokens = math.max(tool_count * 180, math.floor(tool_chars / 3.8))

  local history_tokens = user_tokens + model_tokens + tool_tokens

  -- If session_info has reported total tokens, scale history accordingly
  if session_info.total_tokens and session_info.total_tokens > 0 then
    local diff = session_info.total_tokens - (sys_tokens + skills_tokens + ws_tokens)
    if diff > 0 then
      history_tokens = diff
      user_tokens = math.floor(diff * 0.15)
      model_tokens = math.floor(diff * 0.45)
      tool_tokens = diff - user_tokens - model_tokens
    end
  end

  local total_used = sys_tokens + skills_tokens + ws_tokens + history_tokens
  local pct = math.min(100, (total_used / max_limit) * 100)
  local remaining_tokens = math.max(0, max_limit - total_used)

  local bar_width = 46
  local filled = math.min(bar_width, math.max(0, math.floor((total_used / max_limit) * bar_width + 0.5)))
  local empty = bar_width - filled

  local lines = {}
  local meta = {}

  local function add_line(str, l_type, extra)
    table.insert(lines, str)
    table.insert(meta, {
      row = #lines - 1,
      type = l_type,
      extra = extra,
    })
  end

  -- Header
  add_line("🗎 Context Breakdown", "title")
  add_line("", "empty")

  add_line("Active Model:    " .. model_name, "model_info", { label = "Active Model:", val = model_name })
  local ctx_line = string.format("Context Window:  %s / %s tokens (%.2f%%)", utils.format_tokens(total_used), utils.format_tokens(max_limit), pct)
  add_line(ctx_line, "window_info", { label = "Context Window:", val = string.format("%s / %s tokens (%.2f%%)", utils.format_tokens(total_used), utils.format_tokens(max_limit), pct) })

  local bar_str = string.format("  [%s%s] %.2f%% used", string.rep("█", filled), string.rep("░", empty), pct)
  add_line(bar_str, "progress_bar", {
    fraction = total_used / max_limit,
    filled = filled,
    empty = empty,
    bar_width = bar_width,
  })
  add_line("", "empty")

  -- Breakdown section
  add_line("BREAKDOWN", "group_header")

  local function fmt_breakdown(label, tokens)
    local p = (tokens / max_limit) * 100
    local tok_str = string.format("%s tokens (%.2f%%)", utils.format_tokens(tokens), p)
    local pad = string.rep(" ", math.max(2, 38 - #label))
    return "  " .. label .. pad .. tok_str
  end

  add_line(fmt_breakdown("System prompt", sys_tokens), "breakdown_item")
  add_line(fmt_breakdown("Skills & Rules", skills_tokens), "breakdown_item")
  add_line(string.format("    • Global skills: %d active", skills_count), "sub_item")
  add_line(string.format("    • Workspace rules: %d active", rules_count), "sub_item")

  add_line(fmt_breakdown("Active Workspaces & Files", ws_tokens), "breakdown_item")
  add_line(fmt_breakdown("Conversation History", history_tokens), "breakdown_item")

  local function fmt_sub_history(label, count, tokens)
    local lbl = string.format("    • %s (%d)", label, count)
    local pad = string.rep(" ", math.max(2, 38 - #lbl))
    return lbl .. pad .. utils.format_tokens(tokens) .. " tokens"
  end

  add_line(fmt_sub_history("User messages", user_turns, user_tokens), "sub_item")
  add_line(fmt_sub_history("Model responses", agent_turns, model_tokens), "sub_item")
  add_line(fmt_sub_history("Tool calls & output", tool_count, tool_tokens), "sub_item")

  add_line(fmt_breakdown("Available Context Remaining", remaining_tokens), "breakdown_item", { is_remaining = true })
  add_line("", "empty")

  -- Workspaces section
  add_line("ACTIVE WORKSPACES", "group_header")
  for _, ws in ipairs(workspaces) do
    add_line("  • " .. ws .. " (workspace)", "workspace_item")
  end
  add_line("", "empty")

  -- Session Metrics
  add_line("SESSION METRICS", "group_header")
  local duration_val = session_info.duration_seconds and session_info.duration_seconds > 0 and utils.format_duration(session_info.duration_seconds) or "< 1s"
  add_line("  Total Turns:      " .. tostring(user_turns + agent_turns), "metric_item")
  add_line("  Session Duration: " .. duration_val, "metric_item")
  add_line("  Tool Executions:  " .. tostring(tool_count), "metric_item")
  add_line("  Estimated Tokens: " .. utils.format_tokens(total_used), "metric_item")
  add_line("", "empty")

  -- Explanatory Quote block
  local desc_text = "Context represents the tokens loaded into the model's active attention window. When the context approaches capacity, conversation history is automatically compacted to preserve essential instructions, system prompt, and active workspace files."
  local quote_lines = quota_wrap_text(desc_text, math.min(74, width - 4))
  for _, ql in ipairs(quote_lines) do
    add_line("│ " .. ql, "quote")
  end
  add_line("", "empty")

  -- Footer
  local nav_left = (width >= 75)
      and "↑/↓ Scroll · pgup/pgdown Page · ctrl+end Bottom · ctrl+home Top · esc Close"
      or "↑/↓ Scroll · pgup/down Page · esc Close"
  local right_info = model_name .. " · " .. effort
  local footer_str = panel.format_footer(nav_left, right_info, width)
  add_line(footer_str, "footer", { text = footer_str })

  return lines, meta
end

---Helper to wrap text for quote block
---@param text string
---@param max_len number
---@return string[]
function quota_wrap_text(text, max_len)
  local words = vim.split(text, "%s+", { trimempty = true })
  local res = {}
  local cur = ""

  for _, w in ipairs(words) do
    if #cur == 0 then
      cur = w
    elseif #cur + 1 + #w <= max_len then
      cur = cur .. " " .. w
    else
      table.insert(res, cur)
      cur = w
    end
  end
  if #cur > 0 then
    table.insert(res, cur)
  end
  return res
end

---Apply syntax highlights to the context breakdown panel
---@param buf number
---@param meta table[]
function M.apply_highlights(buf, meta)
  vim.api.nvim_buf_clear_namespace(buf, M.NS_CONTEXT, 0, -1)

  for _, m in ipairs(meta or {}) do
    local row = m.row
    local l_type = m.type
    local line_str = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""

    if l_type == "title" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, 0, {
        end_col = #line_str,
        hl_group = "AgyContextTitle",
      })

    elseif l_type == "model_info" or l_type == "window_info" then
      local colon = line_str:find(":", 1, true)
      if colon then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, 0, {
          end_col = colon,
          hl_group = "Comment",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, colon, {
          end_col = #line_str,
          hl_group = "AgyContextValue",
        })
      end

    elseif l_type == "group_header" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, 0, {
        end_col = #line_str,
        hl_group = "AgyContextGroupTitle",
      })

    elseif l_type == "progress_bar" then
      local extra = m.extra or {}
      local fraction = extra.fraction or 0.0
      local filled = extra.filled or 0

      local open_pos = line_str:find("[", 1, true)
      local close_pos = line_str:find("]", 1, true)

      if open_pos and close_pos then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, open_pos - 1, {
          end_col = open_pos,
          hl_group = "AgyContextBracket",
        })

        local fill_hl = "AgyContextFill"
        if fraction > 0.85 then
          fill_hl = "AgyContextFillError"
        elseif fraction > 0.60 then
          fill_hl = "AgyContextFillWarn"
        end

        local fill_start = open_pos
        local fill_end = fill_start + (filled * 3) -- UTF-8 3-byte '█'
        if filled > 0 then
          pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, fill_start, {
            end_col = fill_end,
            hl_group = fill_hl,
          })
        end

        local empty_start = fill_end
        local empty_end = close_pos - 1
        if empty_start < empty_end then
          pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, empty_start, {
            end_col = empty_end,
            hl_group = "AgyContextEmpty",
          })
        end

        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, close_pos - 1, {
          end_col = close_pos,
          hl_group = "AgyContextBracket",
        })

        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, close_pos, {
          end_col = #line_str,
          hl_group = "AgyContextPercent",
        })
      end

    elseif l_type == "breakdown_item" then
      local extra = m.extra or {}
      local tok_pos = line_str:find("%d+[%d%.k]*%s+tokens")
      if tok_pos then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, 2, {
          end_col = tok_pos - 1,
          hl_group = "AgyContextLabel",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, tok_pos - 1, {
          end_col = #line_str,
          hl_group = extra.is_remaining and "AgyContextRemaining" or "AgyContextValue",
        })
      end

    elseif l_type == "sub_item" then
      local bullet_pos = line_str:find("•", 1, true)
      if bullet_pos then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, bullet_pos - 1, {
          end_col = bullet_pos + 2,
          hl_group = "Comment",
        })
      end
      local tok_pos = line_str:find("%d+[%d%.k]*%s+tokens")
      if tok_pos then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, tok_pos - 1, {
          end_col = #line_str,
          hl_group = "AgyContextValue",
        })
      end

    elseif l_type == "workspace_item" then
      local ws_tag = line_str:find("%(workspace%)")
      if ws_tag then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, 4, {
          end_col = ws_tag - 1,
          hl_group = "Directory",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, ws_tag - 1, {
          end_col = #line_str,
          hl_group = "Comment",
        })
      end

    elseif l_type == "metric_item" then
      local colon = line_str:find(":", 1, true)
      if colon then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, 2, {
          end_col = colon,
          hl_group = "Comment",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, colon, {
          end_col = #line_str,
          hl_group = "Special",
        })
      end

    elseif l_type == "quote" then
      local bar_pos = line_str:find("│", 1, true)
      if bar_pos then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, bar_pos - 1, {
          end_col = bar_pos + 2, -- UTF-8 3-byte '│'
          hl_group = "AgyContextQuoteBar",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_CONTEXT, row, bar_pos + 2, {
          end_col = #line_str,
          hl_group = "Comment",
        })
      end

    elseif l_type == "footer" then
      local extra = m.extra or {}
      panel.apply_footer_highlights(buf, M.NS_CONTEXT, row, extra.text or line_str)
    end
  end
end

---Setup default highlight groups for Context breakdown
function M.setup_highlights()
  local set_hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  set_hl("AgyContextTitle", { bold = true, fg = "#7aa2f7" })
  set_hl("AgyContextGroupTitle", { bold = true, fg = "#7aa2f7" })
  set_hl("AgyContextLabel", { fg = "#c0caf5" })
  set_hl("AgyContextValue", { fg = "#7aa2f7", bold = true })
  set_hl("AgyContextRemaining", { fg = "#9ece6a", bold = true })
  set_hl("AgyContextBracket", { fg = "#565f89" })
  set_hl("AgyContextFill", { fg = "#9ece6a", bold = true })
  set_hl("AgyContextFillWarn", { fg = "#e0af68", bold = true })
  set_hl("AgyContextFillError", { fg = "#f7768e", bold = true })
  set_hl("AgyContextEmpty", { fg = "#3b4261" })
  set_hl("AgyContextPercent", { fg = "#c0caf5", bold = true })
  set_hl("AgyContextQuoteBar", { fg = "#565f89" })
end

---Open interactive Context Breakdown panel in the lower autocomplete area
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
  local cfg = pstate and pstate.config or require("agy.config").get()
  local width = vim.api.nvim_win_get_width(target_win)

  local lines, meta = M.build_content(pstate, cfg, width)

  local win, buf = panel.open({
    target_win = target_win,
    target_buf = caller_buf,
    lines = lines,
    meta = meta,
    apply_highlights = M.apply_highlights,
    filetype = "agy_context",
  })

  return win, buf
end

return M
