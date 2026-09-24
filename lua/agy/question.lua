local utils = require("agy.utils")
local config_mod = require("agy.config")

local M = {}

M.NS_HL = vim.api.nvim_create_namespace("agy_question")

---@class AgyQuestionItem
---@field type "option"|"write_in"|"submit"|"submit_all"
---@field opt_idx number
---@field text string

---@class AgyQuestionUIState
---@field win? number
---@field buf? number
---@field target_win? number
---@field target_buf? number
---@field mapped_buf? number
---@field start_line? number
---@field is_hidden boolean
---@field questions table[]
---@field current_q_idx number
---@field selected_idx number
---@field scroll_offset number
---@field selected_answers table<number, any>
---@field write_in_text table<number, string>
---@field items AgyQuestionItem[]
---@field is_editing_write_in boolean
---@field config? table
---@field on_submit? fun(answer_payload: string, answered_questions: table[])
---@field on_cancel? fun()

---@type AgyQuestionUIState
M.state = {
  win = nil,
  buf = nil,
  target_win = nil,
  target_buf = nil,
  mapped_buf = nil,
  start_line = nil,
  is_hidden = false,
  questions = {},
  current_q_idx = 1,
  selected_idx = 1,
  scroll_offset = 1,
  selected_answers = {},
  write_in_text = {},
  items = {},
  is_editing_write_in = false,
  config = nil,
  on_submit = nil,
  on_cancel = nil,
}

local QUESTION_BUF_KEYS = {
  "j", "k", "<Down>", "<Up>", "<C-n>", "<C-p>",
  "h", "l", "<Left>", "<Right>", "<Tab>", "<S-Tab>",
  "[", "]",
  "<Space>", "<CR>", "<C-s>", "w", "i", "a",
  "1", "2", "3", "4", "5", "6", "7", "8", "9",
  "q", "<Esc>", "<C-c>",
}

local function get_icon(name, cfg)
  local c = cfg or config_mod.get()
  assert(c, "agy config: configuration is required")
  assert(type(c.icons) == "table", "agy config: 'icons' table is required")
  local icon = c.icons[name]
  assert(icon, string.format("agy config: icon '%s' is not defined in config.icons", name))
  return icon
end

local function get_horizontal_sep(cfg)
  local c = cfg or config_mod.get()
  assert(c and c.icons and c.icons.table and c.icons.table.horizontal, "agy config: config.icons.table.horizontal is required")
  return c.icons.table.horizontal
end

---Clean redundant "Question N/M:" prefixes from question text to avoid duplication
---@param text string
---@return string
local function clean_question_text(text)
  if not text then return "" end
  local cleaned = utils.trim(text)
  cleaned = cleaned:gsub("^[Qq]uestion%s*%(?%d+[%s/of%-]*%d*%)?%s*[:.-]?%s*", "")
  cleaned = cleaned:gsub("^%d+[%s/of%-]+%d+%s*[:.-]?%s*", "")
  cleaned = utils.trim(cleaned)
  return cleaned
end

---Ensure button highlight groups are registered
local function ensure_highlights()
  vim.api.nvim_set_hl(0, "AgyQuestionSubmit", { link = "DiagnosticOk", default = true, bold = true })
  vim.api.nvim_set_hl(0, "AgyQuestionSubmitSel", {
    bg = (vim.o.background == "light") and "#2da44e" or "#238636",
    fg = "#ffffff",
    ctermbg = 10,
    ctermfg = 0,
    bold = true,
    default = true,
  })
  vim.api.nvim_set_hl(0, "AgyQuestionStepDone", { link = "DiagnosticOk", default = true, bold = true })
  vim.api.nvim_set_hl(0, "AgyQuestionStepTodo", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AgyQuestionStepCurrent", { link = "Special", default = true, bold = true })
  vim.api.nvim_set_hl(0, "AgyQuestionStepLine", { link = "Comment", default = true })
end

---Check if a question has at least one selected answer or write-in text
---@param q_idx number
---@return boolean
local function has_question_answer(q_idx)
  local q = M.state.questions[q_idx]
  if not q then return false end

  if q.is_multi_select then
    local sel_map = M.state.selected_answers[q_idx]
    if sel_map then
      for _, v in pairs(sel_map) do
        if v then return true end
      end
    end
  else
    if M.state.selected_answers[q_idx] ~= nil then
      return true
    end
  end
  if M.state.write_in_text[q_idx] and M.state.write_in_text[q_idx] ~= "" then
    return true
  end
  return false
end

---Build progression string and extmark highlight descriptors for multi-question workflows
---@param cfg? table
---@param base_col number
---@return string prog_text, table[] highlights
local function build_progression(cfg, base_col)
  local c = cfg or config_mod.get()
  local step_unanswered = get_icon("step_unanswered", c)
  local step_answered = get_icon("step_answered", c)
  local step_current = get_icon("step_current", c)
  local step_line = get_icon("step_line", c)

  local num_q = #M.state.questions
  if num_q <= 1 then return "", {} end

  local is_summary = M.is_summary_page()
  local cur_q = M.state.current_q_idx

  local parts = {}
  local hls = {}
  local cur_col = base_col or 0

  for i = 1, num_q do
    if i > 1 then
      local line_str = " " .. step_line .. step_line .. " "
      table.insert(parts, line_str)
      table.insert(hls, {
        start_col = cur_col,
        end_col = cur_col + #line_str,
        hl_group = "AgyQuestionStepLine",
      })
      cur_col = cur_col + #line_str
    end

    local answered = has_question_answer(i)
    local is_curr = (not is_summary and i == cur_q)
    local sym
    local hl_group
    if is_curr then
      if answered then
        sym = step_current or step_answered
      else
        sym = step_unanswered
      end
      hl_group = "AgyQuestionStepCurrent"
    elseif answered then
      sym = step_answered
      hl_group = "AgyQuestionStepDone"
    else
      sym = step_unanswered
      hl_group = "AgyQuestionStepTodo"
    end

    table.insert(parts, sym)
    table.insert(hls, {
      start_col = cur_col,
      end_col = cur_col + #sym,
      hl_group = hl_group,
    })
    cur_col = cur_col + #sym
  end

  return table.concat(parts, ""), hls
end

---Get the 1-indexed line in the target session buffer where the question block starts
---@return number
function M.get_start_line()
  local b = M.state.buf or M.state.target_buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return 1 end
  local protocol = package.loaded["agy.protocol"]
  local pstate = protocol and protocol.buffers and protocol.buffers[b]
  if pstate and pstate.prompt_extmark_id then
    local render = require("agy.render")
    local pos = vim.api.nvim_buf_get_extmark_by_id(b, render.NS_UI, pstate.prompt_extmark_id, {})
    if pos and #pos >= 1 then
      return pos[1] + 1
    end
  end
  if pstate and pstate.prompt_start_line then
    return pstate.prompt_start_line
  end
  return M.state.start_line or vim.api.nvim_buf_line_count(b)
end

---Get the 1-indexed line in the target session buffer where options begin
---@return number
function M.get_opt_start_line()
  local start_line = M.get_start_line()
  if M.is_summary_page() then
    return start_line + 3 + (#M.state.questions * 2)
  end
  return start_line + 2
end

---Get all buffer lines comprising the interactive question block
---@return string[]
function M.get_question_lines()
  local b = M.state.buf or M.state.target_buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return {} end
  local start_line = M.get_start_line()
  return vim.api.nvim_buf_get_lines(b, start_line - 1, -1, false)
end

---Check whether the interactive question UI is currently active and visible
---@return boolean
function M.is_visible()
  local b = M.state.buf or M.state.target_buf
  return b ~= nil and vim.api.nvim_buf_is_valid(b) and #M.state.questions > 0 and not M.state.is_hidden
end

---Temporarily hide the question UI
function M.hide()
  M.state.is_hidden = true
end

---Legacy compatibility helper for prompt bottom row
---@param target_win number
---@param target_buf number
---@param height number
---@param should_scroll boolean
---@return number row
function M.calc_prompt_bottom_row(target_win, target_buf, height, should_scroll)
  local start_line = M.get_start_line()
  local pos = vim.fn.screenpos(target_win, start_line, 1)
  if pos and pos.row > 0 then
    local win_pos = vim.api.nvim_win_get_position(target_win)
    return math.max(0, pos.row - 1 - win_pos[1])
  end
  return 0
end

---Update question UI layout upon window resize
function M.update_win_config()
  if M.is_visible() then
    M.render_buffer()
  end
end

---Remove question keymaps from the conversation session buffer
function M.clear_keymaps()
  local b = M.state.mapped_buf or M.state.target_buf or M.state.buf
  if b and vim.api.nvim_buf_is_valid(b) then
    for _, key in ipairs(QUESTION_BUF_KEYS) do
      pcall(vim.keymap.del, "n", key, { buffer = b })
    end
    local protocol = package.loaded["agy.protocol"]
    local state = protocol and protocol.buffers and protocol.buffers[b]
    if state and state.conversation_id then
      pcall(protocol._setup_buffer, b, state.conversation_id)
    end
  end
  M.state.mapped_buf = nil
end

---Close question UI, clear buffer lines, delete keymaps, and reset state
function M.close()
  pcall(vim.cmd, "stopinsert")
  M.state.is_editing_write_in = false
  pcall(vim.api.nvim_del_augroup_by_name, "AgyQuestionInlineWriteIn")
  M.clear_keymaps()

  local b = M.state.buf or M.state.target_buf
  if b and vim.api.nvim_buf_is_valid(b) then
    local start_line = M.get_start_line()
    local start_row = start_line - 1
    local protocol = package.loaded["agy.protocol"]
    local prev_guard = protocol and protocol._internal_guard
    if protocol then protocol._internal_guard = true end

    local prev_mod = vim.bo[b].modifiable
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_clear_namespace(b, M.NS_HL, 0, -1)
    vim.api.nvim_buf_set_lines(b, start_row, -1, false, { "" })
    vim.bo[b].modified = false
    vim.bo[b].modifiable = prev_mod

    if protocol then protocol._internal_guard = prev_guard end
  end

  M.state.win = nil
  M.state.buf = nil
  M.state.target_win = nil
  M.state.target_buf = nil
  M.state.mapped_buf = nil
  M.state.start_line = nil
  M.state.questions = {}
  M.state.current_q_idx = 1
  M.state.selected_idx = 1
  M.state.scroll_offset = 1
  M.state.selected_answers = {}
  M.state.write_in_text = {}
  M.state.items = {}
  M.state.is_editing_write_in = false
  M.state.on_submit = nil
  M.state.on_cancel = nil
  M.state.is_hidden = false
end

---Cancel active question and invoke on_cancel callback
function M.cancel()
  local cb = M.state.on_cancel
  M.close()
  if cb then
    cb()
  end
end

---Check if the current page is the summary review page (only exists if > 1 questions)
---@return boolean
function M.is_summary_page()
  return #M.state.questions > 1 and M.state.current_q_idx == (#M.state.questions + 1)
end

---Get total navigable pages (questions + 1 summary page if multiple questions)
---@return number
function M.get_total_pages()
  if #M.state.questions > 1 then
    return #M.state.questions + 1
  end
  return #M.state.questions
end

---Build items list for the current question or summary page
function M.build_items()
  if M.is_summary_page() then
    local items = {
      {
        type = "submit_all",
        opt_idx = 1,
        text = "Submit All Answers",
      }
    }
    M.state.items = items
    M.state.selected_idx = 1
    M.state.scroll_offset = 1
    return
  end

  local q = M.state.questions[M.state.current_q_idx]
  assert(q, "agy question: active question not found")
  local items = {}
  for idx, opt in ipairs(q.options) do
    table.insert(items, {
      type = "option",
      opt_idx = idx,
      text = opt,
    })
  end

  local custom = M.state.write_in_text[M.state.current_q_idx]
  table.insert(items, {
    type = "write_in",
    opt_idx = #q.options + 1,
    text = (custom and custom ~= "") and ('Write-in: "' .. custom .. '"') or "Write-in response...",
  })

  if q.is_multi_select then
    local submit_label = "Submit Answers"
    if #M.state.questions > 1 then
      if M.state.current_q_idx < #M.state.questions then
        submit_label = "Next Question"
      else
        submit_label = "Review Summary"
      end
    end
    table.insert(items, {
      type = "submit",
      opt_idx = #q.options + 2,
      text = submit_label,
    })
  end

  M.state.items = items
  if M.state.selected_idx > #items or M.state.selected_idx < 1 then
    M.state.selected_idx = 1
    M.state.scroll_offset = 1
  end
end

---Render the in-buffer question block directly into target_buf starting at start_line
function M.render_buffer()
  local b = M.state.buf or M.state.target_buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return end

  ensure_highlights()

  local cfg = M.state.config or config_mod.get()
  local q_icon = get_icon("question", cfg)
  local horiz_char = get_horizontal_sep(cfg)

  local win_width = 80
  local target_win = M.state.win or M.state.target_win
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    win_width = vim.api.nvim_win_get_width(target_win)
  end

  local lines = {}
  local highlights = {}

  if M.is_summary_page() then
    -- Header line
    local prog_str, prog_hls = build_progression(cfg, 2)
    local header_text
    if prog_str ~= "" then
      header_text = string.format("  %s   Review Answers", prog_str)
    else
      header_text = "  Review Answers"
    end
    table.insert(lines, header_text)
    table.insert(highlights, {
      row = #lines - 1,
      start_col = 0,
      end_col = #header_text,
      hl_group = "AgyQuestionHeader",
    })
    for _, ph in ipairs(prog_hls) do
      table.insert(highlights, {
        row = #lines - 1,
        start_col = ph.start_col,
        end_col = ph.end_col,
        hl_group = ph.hl_group,
        priority = 101,
      })
    end

    -- Spacer
    table.insert(lines, "")

    -- Summary of each question
    for q_idx, quest in ipairs(M.state.questions) do
      local title = clean_question_text(quest.question)
      local q_title = string.format("  %d. %s", q_idx, title ~= "" and title or quest.question)
      table.insert(lines, q_title)
      table.insert(highlights, {
        row = #lines - 1,
        start_col = 2,
        end_col = #q_title,
        hl_group = "AgyQuestionPrompt",
      })

      local ans_summary = ""
      if quest.is_multi_select then
        local sel_map = M.state.selected_answers[q_idx] or {}
        local opts = {}
        for opt_i, opt_text in ipairs(quest.options) do
          if sel_map[opt_i] then
            table.insert(opts, opt_text)
          end
        end
        ans_summary = table.concat(opts, ", ")
      else
        local choice = M.state.selected_answers[q_idx]
        if type(choice) == "number" and quest.options[choice] then
          ans_summary = quest.options[choice]
        end
      end

      local write_in = M.state.write_in_text[q_idx]
      if write_in and write_in ~= "" then
        if ans_summary ~= "" then
          ans_summary = ans_summary .. ' (Notes: "' .. write_in .. '")'
        else
          ans_summary = 'Write-in: "' .. write_in .. '"'
        end
      end

      if ans_summary == "" then
        ans_summary = "(Unanswered)"
      end

      local ans_line = string.format("     • %s", ans_summary)
      table.insert(lines, ans_line)
      table.insert(highlights, {
        row = #lines - 1,
        start_col = 5,
        end_col = #ans_line,
        hl_group = (ans_summary == "(Unanswered)") and "AgyBadgeError" or "AgyQuestionChecked",
      })
    end

    -- Spacer
    table.insert(lines, "")

    -- Summary items (Submit All Answers)
    for i, it in ipairs(M.state.items) do
      local is_sel = (i == M.state.selected_idx)
      local pointer = is_sel and "> " or "  "
      local line_str = ""
      if it.type == "submit_all" then
        line_str = pointer .. "  Submit All Answers  "
      end
      table.insert(lines, line_str)
      table.insert(highlights, {
        row = #lines - 1,
        is_sel = is_sel,
        line_str = line_str,
        item = it,
      })
    end

    -- Spacer
    table.insert(lines, "")

    -- Footer
    local footer_text = "  ←/h Previous · enter Submit · 1-" .. tostring(#M.state.questions) .. " Jump · esc Cancel"
    table.insert(lines, footer_text)

    -- Bottom border divider
    local bot_divider = string.rep(horiz_char, win_width)
    table.insert(lines, bot_divider)
    table.insert(highlights, {
      row = #lines - 1,
      start_col = 0,
      end_col = #bot_divider,
      hl_group = "AgyDividerLine",
    })

    local start_line = M.get_start_line()
    local start_row = start_line - 1

    local protocol = package.loaded["agy.protocol"]
    local prev_guard = protocol and protocol._internal_guard
    if protocol then protocol._internal_guard = true end

    local prev_mod = vim.bo[b].modifiable
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, start_row, -1, false, lines)
    vim.bo[b].modified = false
    vim.bo[b].modifiable = prev_mod

    if protocol then protocol._internal_guard = prev_guard end

    -- Extmarks
    vim.api.nvim_buf_clear_namespace(b, M.NS_HL, start_row, -1)
    for _, hl in ipairs(highlights) do
      local actual_row = start_row + hl.row
      if hl.hl_group then
        vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, hl.start_col or 0, {
          end_col = hl.end_col,
          hl_group = hl.hl_group,
          priority = hl.priority or 100,
        })
      elseif hl.is_sel ~= nil then
        if hl.item and hl.item.type == "submit_all" then
          if hl.is_sel then
            vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 0, {
              end_col = 2,
              hl_group = "AgyCompletionPointer",
              priority = 101,
            })
            vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 2, {
              end_col = #hl.line_str,
              hl_group = "AgyQuestionSubmitSel",
              priority = 102,
            })
          else
            vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 2, {
              end_col = #hl.line_str,
              hl_group = "AgyQuestionSubmit",
              priority = 100,
            })
          end
        else
          if hl.is_sel then
            vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 0, {
              line_hl_group = "AgyCompletionSel",
              priority = 100,
            })
            vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 0, {
              end_col = 2,
              hl_group = "AgyCompletionPointer",
              priority = 101,
            })
          end
        end
      end
    end

    local footer_row = start_row + #lines - 2
    vim.api.nvim_buf_set_extmark(b, M.NS_HL, footer_row, 0, {
      hl_group = "AgyCompletionFooter",
    })
    local key_tokens = { "←/h", "enter", "esc" }
    for _, tok in ipairs(key_tokens) do
      local s, e = footer_text:find(tok, 1, true)
      if s and e then
        vim.api.nvim_buf_set_extmark(b, M.NS_HL, footer_row, s - 1, {
          end_col = e,
          hl_group = "AgyCompletionKey",
        })
      end
    end
    return
  end

  local q = M.state.questions[M.state.current_q_idx]
  if not q then return end

  local items = M.state.items
  local total_count = #items
  local selected_idx = M.state.selected_idx

  -- Sliding window scroll offset
  local max_visible = 6
  if not M.state.scroll_offset or M.state.scroll_offset < 1 then
    M.state.scroll_offset = 1
  end
  if selected_idx < M.state.scroll_offset then
    M.state.scroll_offset = selected_idx
  elseif selected_idx >= M.state.scroll_offset + max_visible then
    M.state.scroll_offset = selected_idx - max_visible + 1
  end

  local start_idx = M.state.scroll_offset
  local end_idx = math.min(total_count, start_idx + max_visible - 1)

  -- Question header line
  local prog_str, prog_hls = build_progression(cfg, 2)
  local title = clean_question_text(q.question)
  if title == "" and prog_str == "" then
    title = q.question
  end

  local header_text
  if prog_str ~= "" then
    if title ~= "" then
      header_text = string.format("  %s   %s", prog_str, title)
    else
      header_text = string.format("  %s", prog_str)
    end
  else
    header_text = string.format("  %s", title)
  end
  table.insert(lines, header_text)
  table.insert(highlights, {
    row = #lines - 1,
    start_col = 0,
    end_col = #header_text,
    hl_group = "AgyQuestionHeader",
  })
  for _, ph in ipairs(prog_hls) do
    table.insert(highlights, {
      row = #lines - 1,
      start_col = ph.start_col,
      end_col = ph.end_col,
      hl_group = ph.hl_group,
      priority = 101,
    })
  end

  -- Spacer
  table.insert(lines, "")

  -- Options lines
  for i = start_idx, end_idx do
    local it = items[i]
    local is_sel = (i == selected_idx)
    local pointer = is_sel and "> " or "  "
    local line_str = ""

    if it.type == "option" then
      if q.is_multi_select then
        local checked = M.state.selected_answers[M.state.current_q_idx]
            and M.state.selected_answers[M.state.current_q_idx][it.opt_idx]
        local mark = checked and "[x] " or "[ ] "
        line_str = pointer .. mark .. string.format("%d. ", it.opt_idx) .. it.text
      else
        local chosen = (M.state.selected_answers[M.state.current_q_idx] == it.opt_idx)
        local mark = chosen and "(•) " or "( ) "
        line_str = pointer .. mark .. string.format("%d. ", it.opt_idx) .. it.text
      end
    elseif it.type == "write_in" then
      local custom = M.state.write_in_text[M.state.current_q_idx] or ""
      local mark = (M.state.selected_answers[M.state.current_q_idx] == "write_in") and "(•) " or "( ) "
      if q.is_multi_select then
        mark = (custom ~= "") and "[x] " or "[ ] "
      end
      if M.state.is_editing_write_in then
        mark = q.is_multi_select and "[x] " or "(•) "
        line_str = pointer .. mark .. string.format("%d. Write-in: ", #q.options + 1) .. custom
      else
        if custom ~= "" then
          line_str = pointer .. mark .. string.format("%d. Write-in: %s", #q.options + 1, custom)
        else
          line_str = pointer .. mark .. string.format("%d. Write-in response...", #q.options + 1)
        end
      end
    elseif it.type == "submit" then
      line_str = pointer .. "  " .. it.text .. "  "
    end

    table.insert(lines, line_str)
    table.insert(highlights, {
      row = #lines - 1,
      is_sel = is_sel,
      line_str = line_str,
      item = it,
    })
  end

  if total_count > max_visible then
    local remaining = total_count - end_idx
    if remaining > 0 then
      table.insert(lines, string.format("  ↓ %d more", remaining))
      table.insert(highlights, {
        row = #lines - 1,
        hl_group = "AgyCompletionMore",
      })
    else
      table.insert(lines, string.format("  (%d/%d)", selected_idx, total_count))
      table.insert(highlights, {
        row = #lines - 1,
        hl_group = "AgyCompletionMore",
      })
    end
  end

  -- Spacer
  table.insert(lines, "")

  -- Footer
  local footer_text
  if M.state.is_editing_write_in then
    footer_text = "  enter Confirm · esc Finish editing · ↑/↓ Navigate"
  else
    local nav_hint = (#M.state.questions > 1) and "tab/h/l Questions · " or ""
    if q.is_multi_select then
      footer_text = "  " .. nav_hint .. "↑/↓/j/k Navigate · space Toggle · enter Confirm · w Write-in · esc Cancel"
    else
      footer_text = "  " .. nav_hint .. "↑/↓/j/k Navigate · enter Select · 1-" .. tostring(#items) .. " Jump · w Write-in · esc Cancel"
    end
  end
  table.insert(lines, footer_text)

  -- Bottom border divider (full width line under footer)
  local bot_divider = string.rep(horiz_char, win_width)
  table.insert(lines, bot_divider)
  table.insert(highlights, {
    row = #lines - 1,
    start_col = 0,
    end_col = #bot_divider,
    hl_group = "AgyDividerLine",
  })

  local start_line = M.get_start_line()
  local start_row = start_line - 1

  local protocol = package.loaded["agy.protocol"]
  local prev_guard = protocol and protocol._internal_guard
  if protocol then protocol._internal_guard = true end

  local prev_mod = vim.bo[b].modifiable
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, start_row, -1, false, lines)
  vim.bo[b].modified = false
  vim.bo[b].modifiable = prev_mod

  if protocol then protocol._internal_guard = prev_guard end

  -- Extmark application
  vim.api.nvim_buf_clear_namespace(b, M.NS_HL, start_row, -1)
  for _, hl in ipairs(highlights) do
    local actual_row = start_row + hl.row
    if hl.hl_group then
      vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, hl.start_col or 0, {
        end_col = hl.end_col,
        hl_group = hl.hl_group,
        priority = hl.priority or 100,
      })
    elseif hl.is_sel ~= nil then
      if hl.item and hl.item.type == "submit" then
        if hl.is_sel then
          vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 0, {
            end_col = 2,
            hl_group = "AgyCompletionPointer",
            priority = 101,
          })
          vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 2, {
            end_col = #hl.line_str,
            hl_group = "AgyQuestionSubmitSel",
            priority = 102,
          })
        else
          vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 2, {
            end_col = #hl.line_str,
            hl_group = "AgyQuestionSubmit",
            priority = 100,
          })
        end
      else
        if hl.is_sel then
          vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 0, {
            line_hl_group = "AgyCompletionSel",
            priority = 100,
          })
          vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, 0, {
            end_col = 2,
            hl_group = "AgyCompletionPointer",
            priority = 101,
          })
        end
        if hl.line_str:find("%[x%]") or hl.line_str:find("%(•%)") then
          local s, e = hl.line_str:find("%[x%]")
          if not s then s, e = hl.line_str:find("%(•%)") end
          if s and e then
            vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, s - 1, {
              end_col = e,
              hl_group = "AgyQuestionChecked",
              priority = 101,
            })
          end
        end
      end
    end
  end

  local footer_row = start_row + #lines - 2
  vim.api.nvim_buf_set_extmark(b, M.NS_HL, footer_row, 0, {
    hl_group = "AgyCompletionFooter",
  })
  local key_tokens = { "tab/h/l", "↑/↓/j/k", "enter", "space", "w", "esc" }
  if M.state.is_editing_write_in then
    key_tokens = { "enter", "esc", "↑/↓" }
  end
  for _, tok in ipairs(key_tokens) do
    local s, e = footer_text:find(tok, 1, true)
    if s and e then
      vim.api.nvim_buf_set_extmark(b, M.NS_HL, footer_row, s - 1, {
        end_col = e,
        hl_group = "AgyCompletionKey",
      })
    end
  end
end

---Synchronize cursor position in the conversation window to the selected option line
function M.sync_cursor()
  local win = M.state.win or M.state.target_win
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  if M.state.is_editing_write_in then return end

  local opt_start_line = M.get_opt_start_line()
  local cursor_line = opt_start_line + (M.state.selected_idx - (M.state.scroll_offset or 1))
  local b = M.state.buf or M.state.target_buf
  if b and vim.api.nvim_buf_is_valid(b) then
    local line_count = vim.api.nvim_buf_line_count(b)
    cursor_line = math.max(1, math.min(cursor_line, line_count))
  end
  pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
end

---Focus the target window and position cursor on the active option
function M.focus()
  local win = M.state.win or M.state.target_win
  if win and vim.api.nvim_win_is_valid(win) then
    if vim.api.nvim_get_current_win() ~= win then
      vim.api.nvim_set_current_win(win)
    end
    M.sync_cursor()
  end
end

---Select next item
function M.select_next()
  if #M.state.items == 0 then return end
  M.state.selected_idx = (M.state.selected_idx % #M.state.items) + 1
  M.render_buffer()
  M.sync_cursor()
end

---Select previous item
function M.select_prev()
  if #M.state.items == 0 then return end
  M.state.selected_idx = (M.state.selected_idx - 2 + #M.state.items) % #M.state.items + 1
  M.render_buffer()
  M.sync_cursor()
end

---Navigate to a specific question by index (1-based)
---@param idx number
function M.go_to_question(idx)
  local total_pages = M.get_total_pages()
  assert(type(idx) == "number", "agy question: idx must be a number")
  assert(idx >= 1 and idx <= total_pages, "agy question: question index out of range: " .. tostring(idx))

  M.state.current_q_idx = idx
  M.state.scroll_offset = 1
  M.state.selected_idx = 1

  if not M.is_summary_page() then
    local q = M.state.questions[idx]
    if q and not q.is_multi_select then
      local prev_ans = M.state.selected_answers[idx]
      if type(prev_ans) == "number" and prev_ans >= 1 and prev_ans <= #q.options then
        M.state.selected_idx = prev_ans
      elseif prev_ans == "write_in" then
        M.state.selected_idx = #q.options + 1
      end
    end
  end

  M.build_items()
  M.render_buffer()
  M.sync_cursor()
  M.focus()
end

---Navigate to next question or summary page (clamped, no wrap)
function M.next_question()
  local total = M.get_total_pages()
  if total <= 1 then return end
  if M.state.current_q_idx < total then
    M.go_to_question(M.state.current_q_idx + 1)
  end
end

---Navigate to previous question (clamped, no wrap)
function M.prev_question()
  local total = M.get_total_pages()
  if total <= 1 then return end
  if M.state.current_q_idx > 1 then
    M.go_to_question(M.state.current_q_idx - 1)
  end
end

---Jump directly to a numbered option (1-9)
---@param idx number
function M.jump_to(idx)
  if #M.state.items == 0 then return end
  if M.is_summary_page() then
    if idx >= 1 and idx <= #M.state.questions then
      M.go_to_question(idx)
      return
    end
  end
  if idx >= 1 and idx <= #M.state.items then
    M.state.selected_idx = idx
    local it = M.state.items[idx]
    if it.type == "submit_all" then
      M.submit_all()
      return
    elseif it.type == "write_in" then
      M.prompt_write_in()
      return
    end
    local q = M.state.questions[M.state.current_q_idx]
    if q and not q.is_multi_select and it.type == "option" then
      M.state.selected_answers[M.state.current_q_idx] = it.opt_idx
      M.confirm_current_question()
      return
    end
    M.render_buffer()
    M.sync_cursor()
  end
end

---Toggle selection for current item (primarily for multi-select)
function M.toggle()
  if #M.state.items == 0 then return end
  local it = M.state.items[M.state.selected_idx]
  if not it then return end

  if it.type == "submit_all" then
    M.submit_all()
    return
  elseif it.type == "write_in" then
    M.prompt_write_in()
    return
  end

  local q = M.state.questions[M.state.current_q_idx]
  if not q then return end

  if it.type == "option" then
    if q.is_multi_select then
      M.state.selected_answers[M.state.current_q_idx] = M.state.selected_answers[M.state.current_q_idx] or {}
      local cur = M.state.selected_answers[M.state.current_q_idx][it.opt_idx]
      M.state.selected_answers[M.state.current_q_idx][it.opt_idx] = not cur
      M.render_buffer()
    else
      M.state.selected_answers[M.state.current_q_idx] = it.opt_idx
      M.render_buffer()
    end
  elseif it.type == "submit" then
    M.confirm_current_question()
  end
end

---Accept current item
function M.accept()
  if #M.state.items == 0 then return end
  local it = M.state.items[M.state.selected_idx]
  if not it then return end

  if it.type == "submit_all" then
    M.submit_all()
    return
  elseif it.type == "write_in" then
    M.prompt_write_in()
    return
  end

  local q = M.state.questions[M.state.current_q_idx]
  if not q then return end

  if it.type == "option" then
    if q.is_multi_select then
      M.state.selected_answers[M.state.current_q_idx] = M.state.selected_answers[M.state.current_q_idx] or {}
      local cur = M.state.selected_answers[M.state.current_q_idx][it.opt_idx]
      M.state.selected_answers[M.state.current_q_idx][it.opt_idx] = not cur
      M.render_buffer()
    else
      M.state.selected_answers[M.state.current_q_idx] = it.opt_idx
      M.confirm_current_question()
    end
  elseif it.type == "submit" then
    M.confirm_current_question()
  end
end

local function clear_inline_insert_keymaps()
  local b = M.state.buf or M.state.target_buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return end
  local keys = { "<CR>", "<Esc>", "<C-c>", "<BS>", "<C-h>", "<C-w>", "<C-u>", "<Left>", "<Home>", "<Up>", "<Down>" }
  for _, k in ipairs(keys) do
    pcall(vim.keymap.del, "i", k, { buffer = b })
  end
end

---Finish inline editing mode for write-in response
---@param confirmed boolean Whether user pressed enter to confirm
---@param text string Typed write-in text
function M.finish_inline_write_in(confirmed, text)
  pcall(vim.cmd, "stopinsert")
  M.state.is_editing_write_in = false
  clear_inline_insert_keymaps()
  pcall(vim.api.nvim_del_augroup_by_name, "AgyQuestionInlineWriteIn")

  local b = M.state.buf or M.state.target_buf
  if b and vim.api.nvim_buf_is_valid(b) then
    vim.bo[b].modifiable = false
  end

  local trimmed = utils.trim(text or "")
  M.state.write_in_text[M.state.current_q_idx] = trimmed

  local q = M.state.questions[M.state.current_q_idx]
  if not q then return end

  if confirmed then
    if trimmed ~= "" then
      if not q.is_multi_select then
        M.state.selected_answers[M.state.current_q_idx] = "write_in"
        M.confirm_current_question()
        return
      else
        M.build_items()
        M.render_buffer()
        M.sync_cursor()
      end
    else
      if not q.is_multi_select and M.state.selected_answers[M.state.current_q_idx] == "write_in" then
        M.state.selected_answers[M.state.current_q_idx] = nil
      end
      M.build_items()
      M.render_buffer()
      M.sync_cursor()
    end
  else
    if trimmed ~= "" and not q.is_multi_select then
      M.state.selected_answers[M.state.current_q_idx] = "write_in"
    end
    M.build_items()
    M.render_buffer()
    M.sync_cursor()
  end
end

---Setup buffer-local insert mode keymaps during inline write-in editing
---@param write_line number
---@param prefix_end number
function M.setup_inline_insert_keymaps(write_line, prefix_end)
  local b = M.state.buf or M.state.target_buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return end
  local win = M.state.win or M.state.target_win or vim.api.nvim_get_current_win()

  local function get_input_text()
    if not b or not vim.api.nvim_buf_is_valid(b) then return "" end
    local line = vim.api.nvim_buf_get_lines(b, write_line - 1, write_line, false)[1] or ""
    if #line >= prefix_end then
      return line:sub(prefix_end + 1)
    end
    return ""
  end

  local function handle_esc()
    local text = get_input_text()
    M.finish_inline_write_in(false, text)
  end

  vim.keymap.set("i", "<CR>", function()
    local text = get_input_text()
    M.finish_inline_write_in(true, text)
  end, { buffer = b, silent = true, nowait = true })

  vim.keymap.set("i", "<Esc>", handle_esc, { buffer = b, silent = true, nowait = true })
  vim.keymap.set("i", "<C-c>", handle_esc, { buffer = b, silent = true, nowait = true })

  vim.keymap.set("i", "<Up>", function()
    handle_esc()
    M.select_prev()
  end, { buffer = b, silent = true, nowait = true })

  vim.keymap.set("i", "<Down>", function()
    handle_esc()
    M.select_next()
  end, { buffer = b, silent = true, nowait = true })

  vim.keymap.set("i", "<BS>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] == write_line and cur[2] > prefix_end then
      return "<BS>"
    end
    return ""
  end, { buffer = b, expr = true, silent = true })

  vim.keymap.set("i", "<C-h>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] == write_line and cur[2] > prefix_end then
      return "<BS>"
    end
    return ""
  end, { buffer = b, expr = true, silent = true })

  vim.keymap.set("i", "<C-w>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] == write_line and cur[2] > prefix_end then
      return "<C-w>"
    end
    return ""
  end, { buffer = b, expr = true, silent = true })

  vim.keymap.set("i", "<C-u>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] == write_line then
      local line = vim.api.nvim_buf_get_lines(b, write_line - 1, write_line, false)[1] or ""
      local prefix = line:sub(1, prefix_end)
      vim.api.nvim_buf_set_lines(b, write_line - 1, write_line, false, { prefix })
      pcall(vim.api.nvim_win_set_cursor, win, { write_line, prefix_end })
    end
    return ""
  end, { buffer = b, silent = true })

  vim.keymap.set("i", "<Left>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] == write_line and cur[2] > prefix_end then
      return "<Left>"
    end
    return ""
  end, { buffer = b, expr = true, silent = true })

  vim.keymap.set("i", "<Home>", function()
    pcall(vim.api.nvim_win_set_cursor, win, { write_line, prefix_end })
    return ""
  end, { buffer = b, silent = true })

  local group = vim.api.nvim_create_augroup("AgyQuestionInlineWriteIn", { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = b,
    once = true,
    callback = function()
      if M.state.is_editing_write_in then
        handle_esc()
      end
    end,
  })
end

---Start inline editing for the write-in response on the current question
function M.start_inline_write_in()
  if M.is_summary_page() then return end
  local q = M.state.questions[M.state.current_q_idx]
  if not q then return end

  local write_in_idx = nil
  for i, it in ipairs(M.state.items) do
    if it.type == "write_in" then
      write_in_idx = i
      break
    end
  end
  if not write_in_idx then return end

  M.state.selected_idx = write_in_idx
  M.state.is_editing_write_in = true

  M.render_buffer()

  local b = M.state.buf or M.state.target_buf
  local win = M.state.win or M.state.target_win
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  if not b or not vim.api.nvim_buf_is_valid(b) then return end

  local opt_start_line = M.get_opt_start_line()
  local write_line = opt_start_line + (write_in_idx - (M.state.scroll_offset or 1))

  vim.bo[b].modifiable = true

  if vim.api.nvim_get_current_win() ~= win then
    pcall(vim.api.nvim_set_current_win, win)
  end

  local line = vim.api.nvim_buf_get_lines(b, write_line - 1, write_line, false)[1] or ""
  local prefix_end = #line
  local s, e = line:find("Write%-in:%s*")
  if e then
    prefix_end = e
  end

  pcall(vim.api.nvim_win_set_cursor, win, { write_line, #line })

  M.setup_inline_insert_keymaps(write_line, prefix_end)

  pcall(vim.cmd, "startinsert!")
end

---Programmatically set write-in response text or start inline editing
---@param text? string If provided, sets write-in text directly; otherwise starts inline editing
function M.prompt_write_in(text)
  if text ~= nil then
    M.set_write_in(text)
  else
    M.start_inline_write_in()
  end
end

---Programmatically set write-in response text for the current question
---@param text string
function M.set_write_in(text)
  if M.is_summary_page() then return end
  local trimmed = utils.trim(text or "")
  M.state.write_in_text[M.state.current_q_idx] = trimmed
  local q = M.state.questions[M.state.current_q_idx]
  if q and not q.is_multi_select then
    if trimmed ~= "" then
      M.state.selected_answers[M.state.current_q_idx] = "write_in"
      M.confirm_current_question()
      return
    else
      if M.state.selected_answers[M.state.current_q_idx] == "write_in" then
        M.state.selected_answers[M.state.current_q_idx] = nil
      end
    end
  end
  M.build_items()
  M.render_buffer()
  M.sync_cursor()
end

---Format answers across all questions
---@return string payload
---@return table[] answered_questions
function M.format_answers()
  local answered_questions = {}
  local answers = {}
  local is_multi_q = (#M.state.questions > 1)

  for q_idx, q in ipairs(M.state.questions) do
    local selected_opts = {}
    if q.is_multi_select then
      local sel_map = M.state.selected_answers[q_idx] or {}
      for i, opt in ipairs(q.options) do
        if sel_map[i] then
          table.insert(selected_opts, opt)
        end
      end
    else
      local choice = M.state.selected_answers[q_idx]
      if type(choice) == "number" and q.options[choice] then
        table.insert(selected_opts, q.options[choice])
      end
    end

    local write_in = M.state.write_in_text[q_idx]
    table.insert(answered_questions, {
      question = q.question,
      options = q.options,
      is_multi_select = q.is_multi_select,
      selected = selected_opts,
      write_in = write_in,
    })

    local prefix = is_multi_q and string.format("A%d: ", q_idx) or "A: "
    local ans_str = ""
    if #selected_opts == 1 then
      ans_str = prefix .. selected_opts[1]
    elseif #selected_opts > 1 then
      ans_str = prefix .. "\n- " .. table.concat(selected_opts, "\n- ")
    elseif write_in and write_in ~= "" then
      ans_str = prefix .. write_in
    end

    if write_in and write_in ~= "" and #selected_opts > 0 then
      ans_str = ans_str .. "\n\nNotes: " .. write_in
    end

    if ans_str ~= "" then
      table.insert(answers, ans_str)
    end
  end

  local payload = table.concat(answers, "\n\n")
  return payload, answered_questions
end

---Check if a question has at least one selected answer or write-in text
---@param q_idx number
---@return boolean
function M.has_question_answer(q_idx)
  return has_question_answer(q_idx)
end

---Validate and submit all answers across questions
function M.submit_all()
  for q_idx = 1, #M.state.questions do
    if not M.has_question_answer(q_idx) then
      M.go_to_question(q_idx)
      vim.notify(string.format("[agy.nvim] Please answer question %d of %d.", q_idx, #M.state.questions), vim.log.levels.WARN)
      return
    end
  end

  local answer_payload, answered_questions = M.format_answers()
  local on_sub = M.state.on_submit
  M.close()
  if on_sub then
    on_sub(answer_payload, answered_questions)
  end
end

---Confirm current question answer and advance or complete
function M.confirm_current_question()
  local q = M.state.questions[M.state.current_q_idx]
  if not q then return end

  if not M.has_question_answer(M.state.current_q_idx) then
    vim.notify("[agy.nvim] Please select an option or provide a write-in response.", vim.log.levels.WARN)
    return
  end

  if M.state.current_q_idx < M.get_total_pages() then
    M.next_question()
  else
    M.submit_all()
  end
end

---Setup buffer-local keymaps on the conversation session buffer
---@param target_buf number
function M.setup_keymaps(target_buf)
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then return end
  M.state.mapped_buf = target_buf

  local function is_in_question()
    local start_line = M.get_start_line()
    local win = vim.api.nvim_get_current_win()
    if not win or not vim.api.nvim_win_is_valid(win) then return false end
    local cur = vim.api.nvim_win_get_cursor(win)
    return cur[1] >= start_line
  end

  local function handle_down()
    if is_in_question() then
      M.select_next()
    else
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      local start_line = M.get_start_line()
      if cur[1] + 1 >= start_line then
        M.sync_cursor()
      else
        local line_count = vim.api.nvim_buf_line_count(target_buf)
        if cur[1] < line_count then
          local next_l = vim.api.nvim_buf_get_lines(target_buf, cur[1], cur[1] + 1, false)[1] or ""
          vim.api.nvim_win_set_cursor(win, { cur[1] + 1, math.min(cur[2], #next_l) })
        end
      end
    end
  end

  local function handle_up()
    if is_in_question() then
      if M.state.selected_idx > 1 then
        M.select_prev()
      else
        local start_line = M.get_start_line()
        local target_line = math.max(1, start_line - 1)
        local win = M.state.win or M.state.target_win or vim.api.nvim_get_current_win()
        local line_text = vim.api.nvim_buf_get_lines(target_buf, target_line - 1, target_line, false)[1] or ""
        pcall(vim.api.nvim_win_set_cursor, win, { target_line, math.min(0, #line_text) })
      end
    else
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      if cur[1] > 1 then
        local prev_l = vim.api.nvim_buf_get_lines(target_buf, cur[1] - 2, cur[1] - 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { cur[1] - 1, math.min(cur[2], #prev_l) })
      end
    end
  end

  local function pass_or(fn, fallback_key)
    return function()
      if is_in_question() then
        fn()
      else
        if fallback_key then
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(fallback_key, true, false, true), "n", false)
        end
      end
    end
  end

  local q_opts = { buffer = target_buf, silent = true, nowait = true }

  for _, k in ipairs({ "j", "<Down>", "<C-n>" }) do
    vim.keymap.set("n", k, handle_down, q_opts)
  end
  for _, k in ipairs({ "k", "<Up>", "<C-p>" }) do
    vim.keymap.set("n", k, handle_up, q_opts)
  end
  for _, k in ipairs({ "h", "<Left>" }) do
    vim.keymap.set("n", k, pass_or(function()
      if #M.state.questions > 1 then M.prev_question() end
    end, "h"), q_opts)
  end
  for _, k in ipairs({ "l", "<Right>" }) do
    vim.keymap.set("n", k, pass_or(function()
      if #M.state.questions > 1 then M.next_question() end
    end, "l"), q_opts)
  end

  vim.keymap.set("n", "<Tab>", pass_or(function()
    if #M.state.questions > 1 then M.next_question() else M.select_next() end
  end, "<Tab>"), q_opts)
  vim.keymap.set("n", "<S-Tab>", pass_or(function()
    if #M.state.questions > 1 then M.prev_question() else M.select_prev() end
  end, "<S-Tab>"), q_opts)
  vim.keymap.set("n", "[", pass_or(function()
    if #M.state.questions > 1 then M.prev_question() end
  end, "["), q_opts)
  vim.keymap.set("n", "]", pass_or(function()
    if #M.state.questions > 1 then M.next_question() end
  end, "]"), q_opts)

  vim.keymap.set("n", "<Space>", pass_or(function() M.toggle() end, "<Space>"), q_opts)

  -- <CR>: if in question, accept; if in history, toggle tool output
  local function handle_cr()
    if is_in_question() then
      M.accept()
    else
      local protocol = package.loaded["agy.protocol"]
      if protocol and protocol.buffers and protocol.buffers[target_buf] then
        local handled = protocol.toggle_tool_at_cursor(target_buf, vim.api.nvim_get_current_win())
        if not handled then
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
        end
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
      end
    end
  end
  vim.keymap.set("n", "<CR>", handle_cr, q_opts)

  vim.keymap.set("n", "<C-s>", function() M.submit_all() end, q_opts)

  for _, k in ipairs({ "w", "i", "a" }) do
    vim.keymap.set("n", k, pass_or(function() M.prompt_write_in() end, k), q_opts)
  end

  for num = 1, 9 do
    vim.keymap.set("n", tostring(num), pass_or(function() M.jump_to(num) end, tostring(num)), q_opts)
  end

  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, pass_or(function() M.cancel() end, k), q_opts)
  end

  vim.keymap.set("n", "<C-c>", function() M.cancel() end, q_opts)

  -- Cursor tracking in target_buf: sync selected_idx if cursor moves via motion
  local q_group = vim.api.nvim_create_augroup("AgyQuestionCursor_" .. target_buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = q_group,
    buffer = target_buf,
    callback = function()
      if not M.is_visible() then return end
      if M.state.is_editing_write_in then return end
      local win = M.state.win or M.state.target_win
      if not win or not vim.api.nvim_win_is_valid(win) then return end
      if vim.api.nvim_get_current_win() ~= win then return end

      local start_line = M.get_start_line()
      local cur = vim.api.nvim_win_get_cursor(win)
      local cur_line = cur[1]
      if cur_line < start_line then
        return
      end

      local opt_start_line = M.get_opt_start_line()
      local max_visible = 6
      local start_idx = M.state.scroll_offset or 1
      local total_count = #M.state.items
      local end_idx = math.min(total_count, start_idx + max_visible - 1)
      local opt_end_line = opt_start_line + (end_idx - start_idx)

      if cur_line >= opt_start_line and cur_line <= opt_end_line then
        local item_idx = start_idx + (cur_line - opt_start_line)
        if item_idx ~= M.state.selected_idx then
          M.state.selected_idx = item_idx
          M.render_buffer()
          pcall(vim.api.nvim_win_set_cursor, win, { cur_line, 0 })
        end
      end
    end,
  })
end

---Display or update the interactive question UI in the conversation buffer
---@param target_win number
---@param target_buf number
function M.show_over_prompt(target_win, target_buf)
  if not M.state.questions or #M.state.questions == 0 then return end
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    M.state.target_win = target_win
    M.state.win = target_win
  end
  if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
    M.state.target_buf = target_buf
    M.state.buf = target_buf
  end
  M.state.is_hidden = false
  M.render_buffer()
  M.setup_keymaps(M.state.buf)
  M.sync_cursor()
end

---Display or update the interactive question UI directly inside the conversation session buffer
---@param target_win number
---@param target_buf number
---@param questions table[]
---@param opts? { config?: table, on_submit?: fun(payload: string, answered: table[]), on_cancel?: fun() }
function M.show(target_win, target_buf, questions, opts)
  assert(questions and type(questions) == "table" and #questions > 0, "agy question: questions array is required")
  opts = opts or {}

  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    target_win = vim.api.nvim_get_current_win()
  end
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    target_buf = vim.api.nvim_get_current_buf()
  end

  M.state.target_win = target_win
  M.state.target_buf = target_buf
  M.state.win = target_win
  M.state.buf = target_buf
  M.state.questions = questions
  M.state.current_q_idx = 1
  M.state.selected_idx = 1
  M.state.scroll_offset = 1
  M.state.selected_answers = {}
  M.state.write_in_text = {}
  M.state.config = opts.config or config_mod.get()
  M.state.on_submit = opts.on_submit
  M.state.on_cancel = opts.on_cancel
  M.state.is_hidden = false

  local protocol = package.loaded["agy.protocol"]
  local pstate = protocol and protocol.buffers and protocol.buffers[target_buf]
  M.state.start_line = (pstate and pstate.prompt_start_line) or vim.api.nvim_buf_line_count(target_buf)

  M.build_items()
  M.render_buffer()
  M.setup_keymaps(target_buf)
  M.sync_cursor()
  M.focus()
end

-- Resize listener to re-render question divider lines when window geometry changes
local resize_group = vim.api.nvim_create_augroup("AgyQuestionResize", { clear = true })
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = resize_group,
  callback = function()
    if M.is_visible() then
      M.update_win_config()
    end
  end,
})

return M
