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
---@field start_line? number
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

---@return AgyQuestionUIState
local function new_question_state()
  return {
    win = nil,
    buf = nil,
    start_line = nil,
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
end

---@type table<number, AgyQuestionUIState>
M.states = {}

---@type AgyQuestionUIState
M.state = new_question_state()

---@type number?
M._pinned_buf = nil

---Activate question state for a specific buffer (or current buffer if it has an active question)
---@param buf? number
---@return AgyQuestionUIState
function M.activate_buf(buf)
  local target = (type(buf) == "number" and buf) or M._pinned_buf
  if type(target) == "number" then
    M.state = M.states[target] or new_question_state()
    return M.state
  end
  local cur_buf = vim.api.nvim_get_current_buf()
  if cur_buf and M.states[cur_buf] and #M.states[cur_buf].questions > 0 then
    M.state = M.states[cur_buf]
  end
  return M.state
end

---Return a buffer-bound question UI controller that isolates state per buffer
---@param buf number
---@return table
function M.bind_buffer(buf)
  return setmetatable({}, {
    __index = function(_, k)
      if k == "state" then
        return M.states[buf] or new_question_state()
      end
      local v = M[k]
      if type(v) == "function" then
        return function(...)
          local prev_pinned = M._pinned_buf
          local prev_state = M.state
          local was_active = (M.states[buf] ~= nil)
          M._pinned_buf = buf
          M.activate_buf(buf)
          local ok, res1, res2 = pcall(v, ...)
          M._pinned_buf = prev_pinned
          if not was_active and not M.states[buf] and prev_state and prev_state.buf and M.states[prev_state.buf] then
            M.state = prev_state
          end
          if not ok then
            error(res1, 0)
          end
          return res1, res2
        end
      end
      return v
    end,
  })
end

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
  assert(icon ~= nil, string.format("agy config: icon '%s' is not defined in config.icons", tostring(name)))
  return icon
end

local function get_horizontal_sep(cfg)
  local c = cfg or config_mod.get()
  assert(c and c.icons and c.icons.table and c.icons.table.horizontal, "agy config: config.icons.table.horizontal is required")
  return c.icons.table.horizontal
end

---Find a valid window in the current tabpage displaying buffer `b`
---@param b? number
---@param fallback_win? number
---@return number?
local function find_tab_win(b, fallback_win)
  if not b or not vim.api.nvim_buf_is_valid(b) then return nil end
  local cur_win = vim.api.nvim_get_current_win()
  local cur_tab = vim.api.nvim_get_current_tabpage()
  if cur_win and vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win) == b then
    return cur_win
  end
  local tab_win = vim.fn.bufwinid(b)
  if tab_win ~= -1 and vim.api.nvim_win_is_valid(tab_win) and vim.api.nvim_win_get_tabpage(tab_win) == cur_tab then
    return tab_win
  end
  if
    fallback_win
    and vim.api.nvim_win_is_valid(fallback_win)
    and vim.api.nvim_win_get_tabpage(fallback_win) == cur_tab
    and vim.api.nvim_win_get_buf(fallback_win) == b
  then
    return fallback_win
  end
  return nil
end

---Clean redundant "Question N/M:" prefixes from question text to avoid duplication
---@param text string
---@return string
local function clean_question_text(text)
  if not text then return "" end
  local cleaned = utils.trim(text)
  cleaned = cleaned:gsub("^[Qq]uestion%s*%(?%d+[%s/of%-]*%d*%)?%s*[:.-]?%s*", "")
  cleaned = cleaned:gsub("^%d+[%s/of%-]+%d+%s*[:.-]?%s*", "")
  cleaned = cleaned:gsub("[\r\n]+", " ")
  return utils.trim(cleaned)
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
  elseif M.state.selected_answers[q_idx] ~= nil then
    return true
  end
  return (M.state.write_in_text[q_idx] or "") ~= ""
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
      sym = answered and step_current or step_unanswered
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
  local b = M.state.buf
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
  local b = M.state.buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return {} end
  local start_line = M.get_start_line()
  return vim.api.nvim_buf_get_lines(b, start_line - 1, -1, false)
end

---Check whether the interactive question UI is currently active and visible
---@param target_buf? number
---@return boolean
function M.is_visible(target_buf)
  if type(target_buf) == "number" then
    local st = M.states[target_buf]
    return st ~= nil and vim.api.nvim_buf_is_valid(target_buf) and #st.questions > 0
  end
  M.activate_buf()
  local b = M.state.buf
  return b ~= nil and vim.api.nvim_buf_is_valid(b) and #M.state.questions > 0
end

---Update question UI layout upon window resize
function M.update_win_config()
  if M.is_visible() and not M.state.is_editing_write_in then
    M.render_buffer()
  end
end

---Remove question keymaps from the conversation session buffer
function M.clear_keymaps()
  local b = M.state.buf
  if b and vim.api.nvim_buf_is_valid(b) then
    for _, key in ipairs(QUESTION_BUF_KEYS) do
      pcall(vim.keymap.del, "n", key, { buffer = b })
    end
    pcall(vim.api.nvim_del_augroup_by_name, "AgyQuestionCursor_" .. b)
    local protocol = package.loaded["agy.protocol"]
    local state = protocol and protocol.buffers and protocol.buffers[b]
    if state and state.conversation_id then
      pcall(protocol._setup_buffer, b, state.conversation_id)
    end
  end
end

---Close question UI, clear buffer lines, delete keymaps, and reset state
---@param target_buf? number
function M.close(target_buf)
  local explicit_buf = (type(target_buf) == "number" and target_buf) or M._pinned_buf
  if type(explicit_buf) == "number" and not M.states[explicit_buf] then
    return
  end
  M.activate_buf(explicit_buf)
  pcall(vim.cmd, "stopinsert")
  M.state.is_editing_write_in = false
  local b = M.state.buf
  pcall(vim.api.nvim_del_augroup_by_name, "AgyQuestionInlineWriteIn")
  if b then
    pcall(vim.api.nvim_del_augroup_by_name, "AgyQuestionInlineWriteIn_" .. b)
  end
  M.clear_keymaps()

  if b and vim.api.nvim_buf_is_valid(b) then
    local start_row = M.get_start_line() - 1
    local protocol = package.loaded["agy.protocol"]
    local prev_guard = protocol and protocol._internal_guard
    if protocol then protocol._internal_guard = true end

    local prev_mod = vim.bo[b].modifiable
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_clear_namespace(b, M.NS_HL, 0, -1)
    require("agy.markdown").register_links(b, {}, start_row)
    vim.api.nvim_buf_set_lines(b, start_row, -1, false, { "" })
    vim.bo[b].modified = false
    vim.bo[b].modifiable = prev_mod

    if protocol then protocol._internal_guard = prev_guard end
  end

  if b then
    M.states[b] = nil
  end
  M.state = new_question_state()
  local cur_buf = vim.api.nvim_get_current_buf()
  if cur_buf and M.states[cur_buf] and #M.states[cur_buf].questions > 0 then
    M.state = M.states[cur_buf]
  else
    for k_buf, st in pairs(M.states) do
      if vim.api.nvim_buf_is_valid(k_buf) and #st.questions > 0 then
        M.state = st
        break
      end
    end
  end
end

---Cancel active question and invoke on_cancel callback
---@param target_buf? number
function M.cancel(target_buf)
  local explicit_buf = (type(target_buf) == "number" and target_buf) or M._pinned_buf
  if type(explicit_buf) == "number" and not M.states[explicit_buf] then
    return
  end
  M.activate_buf(explicit_buf)
  local cb = M.state.on_cancel
  M.close(explicit_buf)
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
  return (#M.state.questions > 1) and (#M.state.questions + 1) or #M.state.questions
end

---Build items list for the current question or summary page
function M.build_items()
  if M.is_summary_page() then
    M.state.items = {
      {
        type = "submit_all",
        opt_idx = 1,
        text = "Submit All Answers",
      },
    }
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
      submit_label = (M.state.current_q_idx < #M.state.questions) and "Next Question" or "Review Summary"
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

---Render the in-buffer question block directly into buf starting at start_line
function M.render_buffer()
  local b = M.state.buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return end

  local render = require("agy.render")
  render.setup_highlights()

  local cfg = M.state.config or config_mod.get()
  local horiz_char = get_horizontal_sep(cfg)
  local win_width = (M.state.win and vim.api.nvim_win_is_valid(M.state.win))
      and vim.api.nvim_win_get_width(M.state.win)
      or 80

  local lines = {}
  local highlights = {}
  local links_to_register = {}
  local markdown_mod = require("agy.markdown")
  local footer_text
  local key_tokens

  if M.is_summary_page() then
    local prog_str, prog_hls = build_progression(cfg, 2)
    local header_text = (prog_str ~= "") and string.format("  %s   Review Answers", prog_str) or "  Review Answers"
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

    table.insert(lines, "")

    for q_idx, quest in ipairs(M.state.questions) do
      local raw_title = clean_question_text(quest.question)
      local clean_title, t_inlines, t_links = markdown_mod.parse_inline_formatting(raw_title ~= "" and raw_title or quest.question)
      local pfx = string.format("  %d. ", q_idx)
      local q_title = pfx .. clean_title
      table.insert(lines, q_title)
      local cur_row = #lines - 1
      table.insert(highlights, {
        row = cur_row,
        start_col = 2,
        end_col = #q_title,
        hl_group = "AgyQuestionPrompt",
      })
      for _, im in ipairs(t_inlines) do
        table.insert(highlights, {
          row = cur_row,
          start_col = #pfx + im.col,
          end_col = #pfx + im.end_col,
          hl_group = im.hl_group,
          hl_mode = "combine",
          priority = 115,
        })
      end
      for _, tl in ipairs(t_links) do
        table.insert(links_to_register, {
          rel_row = cur_row,
          start_col = #pfx + tl.start_col,
          end_col = #pfx + tl.end_col,
          url = tl.url,
        })
      end

      local ans_summary = ""
      if quest.is_multi_select then
        local sel_map = M.state.selected_answers[q_idx] or {}
        local opts = {}
        for opt_i, opt_text in ipairs(quest.options) do
          if sel_map[opt_i] then
            table.insert(opts, (markdown_mod.parse_inline_formatting(opt_text)))
          end
        end
        ans_summary = table.concat(opts, ", ")
      else
        local choice = M.state.selected_answers[q_idx]
        if type(choice) == "number" and quest.options[choice] then
          ans_summary = markdown_mod.parse_inline_formatting(quest.options[choice])
        end
      end

      local write_in = M.state.write_in_text[q_idx]
      if write_in and write_in ~= "" then
        local clean_w = markdown_mod.parse_inline_formatting(write_in)
        ans_summary = (ans_summary ~= "") and (ans_summary .. ' (Notes: "' .. clean_w .. '")') or ('Write-in: "' .. clean_w .. '"')
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

    table.insert(lines, "")

    for i, it in ipairs(M.state.items) do
      local is_sel = (i == M.state.selected_idx)
      local pointer = is_sel and "> " or "  "
      local line_str = (it.type == "submit_all") and (pointer .. "  Submit All Answers  ") or ""
      table.insert(lines, line_str)
      table.insert(highlights, {
        row = #lines - 1,
        is_sel = is_sel,
        line_str = line_str,
        item = it,
      })
    end

    table.insert(lines, "")
    footer_text = "  ←/h Previous · enter Submit · 1-" .. tostring(#M.state.questions) .. " Jump · esc Cancel"
    key_tokens = { "←/h", "enter", "esc" }
    table.insert(lines, footer_text)
  else
    local q = M.state.questions[M.state.current_q_idx]
    if not q then return end

    local items = M.state.items
    local total_count = #items
    local selected_idx = M.state.selected_idx

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

    local prog_str, prog_hls = build_progression(cfg, 2)
    local raw_title = clean_question_text(q.question)
    if raw_title == "" and prog_str == "" then
      raw_title = q.question
    end

    local clean_title, title_inlines, title_links = markdown_mod.parse_inline_formatting(raw_title)

    local header_text
    local title_prefix_len = 0
    if prog_str ~= "" then
      if clean_title ~= "" then
        local pfx = string.format("  %s   ", prog_str)
        title_prefix_len = #pfx
        header_text = pfx .. clean_title
      else
        header_text = string.format("  %s", prog_str)
      end
    else
      local pfx = "  "
      title_prefix_len = #pfx
      header_text = pfx .. clean_title
    end
    table.insert(lines, header_text)
    local header_rel_row = #lines - 1
    table.insert(highlights, {
      row = header_rel_row,
      start_col = 0,
      end_col = #header_text,
      hl_group = "AgyQuestionHeader",
    })
    for _, ph in ipairs(prog_hls) do
      table.insert(highlights, {
        row = header_rel_row,
        start_col = ph.start_col,
        end_col = ph.end_col,
        hl_group = ph.hl_group,
        priority = 101,
      })
    end
    for _, im in ipairs(title_inlines) do
      table.insert(highlights, {
        row = header_rel_row,
        start_col = title_prefix_len + im.col,
        end_col = title_prefix_len + im.end_col,
        hl_group = im.hl_group,
        hl_mode = "combine",
        priority = 115,
      })
    end
    for _, tl in ipairs(title_links) do
      table.insert(links_to_register, {
        rel_row = header_rel_row,
        start_col = title_prefix_len + tl.start_col,
        end_col = title_prefix_len + tl.end_col,
        url = tl.url,
      })
    end

    table.insert(lines, "")

    for i = start_idx, end_idx do
      local it = items[i]
      local is_sel = (i == selected_idx)
      local pointer = is_sel and "> " or "  "
      local line_str = ""
      local opt_prefix_len = 0
      local opt_inlines = {}
      local opt_links = {}

      if it.type == "option" then
        local opt_single = tostring(it.text):gsub("[\r\n]+", " ")
        local clean_text, o_inlines, o_links = markdown_mod.parse_inline_formatting(opt_single)
        opt_inlines = o_inlines
        opt_links = o_links
        if q.is_multi_select then
          local checked = M.state.selected_answers[M.state.current_q_idx]
              and M.state.selected_answers[M.state.current_q_idx][it.opt_idx]
          local mark = checked and "[x] " or "[ ] "
          local pfx = pointer .. mark .. string.format("%d. ", it.opt_idx)
          opt_prefix_len = #pfx
          line_str = pfx .. clean_text
        else
          local chosen = (M.state.selected_answers[M.state.current_q_idx] == it.opt_idx)
          local mark = chosen and "(•) " or "( ) "
          local pfx = pointer .. mark .. string.format("%d. ", it.opt_idx)
          opt_prefix_len = #pfx
          line_str = pfx .. clean_text
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
        elseif custom ~= "" then
          local custom_single = tostring(custom):gsub("[\r\n]+", " ")
          local clean_custom, c_inlines, c_links = markdown_mod.parse_inline_formatting(custom_single)
          opt_inlines = c_inlines
          opt_links = c_links
          local pfx = pointer .. mark .. string.format("%d. Write-in: ", #q.options + 1)
          opt_prefix_len = #pfx
          line_str = pfx .. clean_custom
        else
          line_str = pointer .. mark .. string.format("%d. Write-in response...", #q.options + 1)
        end
      elseif it.type == "submit" then
        line_str = pointer .. "  " .. it.text .. "  "
      end

      table.insert(lines, line_str)
      local cur_row = #lines - 1
      table.insert(highlights, {
        row = cur_row,
        is_sel = is_sel,
        line_str = line_str,
        item = it,
      })
      for _, im in ipairs(opt_inlines) do
        table.insert(highlights, {
          row = cur_row,
          start_col = opt_prefix_len + im.col,
          end_col = opt_prefix_len + im.end_col,
          hl_group = im.hl_group,
          hl_mode = "combine",
          priority = 115,
        })
      end
      for _, ol in ipairs(opt_links) do
        table.insert(links_to_register, {
          rel_row = cur_row,
          start_col = opt_prefix_len + ol.start_col,
          end_col = opt_prefix_len + ol.end_col,
          url = ol.url,
        })
      end
    end

    if total_count > max_visible then
      local remaining = total_count - end_idx
      local more_str = (remaining > 0) and string.format("  ↓ %d more", remaining) or string.format("  (%d/%d)", selected_idx, total_count)
      table.insert(lines, more_str)
      table.insert(highlights, {
        row = #lines - 1,
        hl_group = "AgyCompletionMore",
      })
    end

    table.insert(lines, "")

    if M.state.is_editing_write_in then
      footer_text = "  enter Confirm · esc Finish editing · ↑/↓ Navigate"
      key_tokens = { "enter", "esc", "↑/↓" }
    else
      local nav_hint = (#M.state.questions > 1) and "tab/h/l Questions · " or ""
      if q.is_multi_select then
        footer_text = "  " .. nav_hint .. "↑/↓/j/k Navigate · space Toggle · enter Confirm · w Write-in · esc Cancel"
      else
        footer_text = "  " .. nav_hint .. "↑/↓/j/k Navigate · enter Select · 1-" .. tostring(#items) .. " Jump · w Write-in · esc Cancel"
      end
      key_tokens = { "tab/h/l", "↑/↓/j/k", "enter", "space", "w", "esc" }
    end
    table.insert(lines, footer_text)
  end

  local start_row = M.get_start_line() - 1
  local protocol = package.loaded["agy.protocol"]
  local prev_guard = protocol and protocol._internal_guard
  if protocol then protocol._internal_guard = true end

  local safe_lines = {}
  for _, l in ipairs(lines) do
    for _, sl in ipairs(utils.split_lines(tostring(l))) do
      table.insert(safe_lines, sl)
    end
  end
  local prev_mod = vim.bo[b].modifiable
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, start_row, -1, false, safe_lines)
  vim.bo[b].modified = false
  vim.bo[b].modifiable = prev_mod

  if protocol then protocol._internal_guard = prev_guard end

  vim.api.nvim_buf_clear_namespace(b, M.NS_HL, start_row, -1)
  for _, hl in ipairs(highlights) do
    local actual_row = start_row + hl.row
    if hl.hl_group then
      vim.api.nvim_buf_set_extmark(b, M.NS_HL, actual_row, hl.start_col or 0, {
        end_col = hl.end_col,
        hl_group = hl.hl_group,
        hl_mode = hl.hl_mode,
        priority = hl.priority or 100,
      })
    elseif hl.is_sel ~= nil then
      local is_btn = hl.item and (hl.item.type == "submit" or hl.item.type == "submit_all")
      if is_btn then
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

  local footer_row = start_row + #lines - 1
  vim.api.nvim_buf_set_extmark(b, M.NS_HL, footer_row, 0, {
    hl_group = "AgyCompletionFooter",
  })
  for _, tok in ipairs(key_tokens) do
    local s, e = footer_text:find(tok, 1, true)
    if s and e then
      vim.api.nvim_buf_set_extmark(b, M.NS_HL, footer_row, s - 1, {
        end_col = e,
        hl_group = "AgyCompletionKey",
      })
    end
  end

  local border_width = render.get_max_window_width(b)
  if border_width == 0 then
    border_width = win_width
  end
  vim.api.nvim_buf_set_extmark(b, M.NS_HL, footer_row, 0, {
    virt_lines = { { { string.rep(horiz_char, border_width), "AgyPromptBorder" } } },
    virt_lines_leftcol = true,
    virt_lines_above = false,
    right_gravity = true,
    priority = 200,
  })

  markdown_mod.register_links(b, links_to_register, start_row)
end

---Synchronize cursor position in the conversation window to the selected option line
function M.sync_cursor()
  local b = M.state.buf
  if not b or not vim.api.nvim_buf_is_valid(b) or M.state.is_editing_write_in then return end

  local win = find_tab_win(b, M.state.win)
  if not win then return end

  local opt_start_line = M.get_opt_start_line()
  local cursor_line = opt_start_line + (M.state.selected_idx - (M.state.scroll_offset or 1))
  local line_count = vim.api.nvim_buf_line_count(b)
  cursor_line = math.max(1, math.min(cursor_line, line_count))
  pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
end

---Focus the target window and position cursor on the active option
function M.focus()
  local b = M.state.buf
  local win = find_tab_win(b)
  if not win then return end

  M.state.win = win
  if vim.api.nvim_get_current_win() ~= win then
    vim.api.nvim_set_current_win(win)
  end
  M.sync_cursor()
end

---Select next item
function M.select_next()
  M.activate_buf()
  if #M.state.items == 0 then return end
  M.state.selected_idx = (M.state.selected_idx % #M.state.items) + 1
  M.render_buffer()
  M.sync_cursor()
end

---Select previous item
function M.select_prev()
  M.activate_buf()
  if #M.state.items == 0 then return end
  M.state.selected_idx = (M.state.selected_idx - 2 + #M.state.items) % #M.state.items + 1
  M.render_buffer()
  M.sync_cursor()
end

---Navigate to a specific question by index (1-based)
---@param idx number
function M.go_to_question(idx)
  M.activate_buf()
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
  M.activate_buf()
  local total = M.get_total_pages()
  if total > 1 and M.state.current_q_idx < total then
    M.go_to_question(M.state.current_q_idx + 1)
  end
end

---Navigate to previous question (clamped, no wrap)
function M.prev_question()
  M.activate_buf()
  local total = M.get_total_pages()
  if total > 1 and M.state.current_q_idx > 1 then
    M.go_to_question(M.state.current_q_idx - 1)
  end
end

---Jump directly to a numbered option (1-9)
---@param idx number
function M.jump_to(idx)
  M.activate_buf()
  if #M.state.items == 0 then return end
  if M.is_summary_page() and idx >= 1 and idx <= #M.state.questions then
    M.go_to_question(idx)
    return
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
  M.activate_buf()
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
      M.state.selected_answers[M.state.current_q_idx][it.opt_idx] = not M.state.selected_answers[M.state.current_q_idx][it.opt_idx]
    else
      M.state.selected_answers[M.state.current_q_idx] = it.opt_idx
    end
    M.render_buffer()
  elseif it.type == "submit" then
    M.confirm_current_question()
  end
end

---Accept current item
function M.accept()
  M.activate_buf()
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
      M.state.selected_answers[M.state.current_q_idx][it.opt_idx] = not M.state.selected_answers[M.state.current_q_idx][it.opt_idx]
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
  local b = M.state.buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return end
  local keys = { "<CR>", "<Esc>", "<C-c>", "<BS>", "<C-h>", "<C-w>", "<C-u>", "<Left>", "<Home>", "<Up>", "<Down>" }
  for _, k in ipairs(keys) do
    pcall(vim.keymap.del, "i", k, { buffer = b })
  end
  local protocol = package.loaded["agy.protocol"]
  if protocol and protocol.buffers and protocol.buffers[b] then
    pcall(require("agy.completion").setup_buffer, b)
  end
end

---Finish inline editing mode for write-in response
---@param confirmed boolean Whether user pressed enter to confirm
---@param text string Typed write-in text
function M.finish_inline_write_in(confirmed, text)
  pcall(vim.cmd, "stopinsert")
  M.state.is_editing_write_in = false
  clear_inline_insert_keymaps()
  local b = M.state.buf
  pcall(vim.api.nvim_del_augroup_by_name, "AgyQuestionInlineWriteIn")
  if b then
    pcall(vim.api.nvim_del_augroup_by_name, "AgyQuestionInlineWriteIn_" .. b)
    if vim.api.nvim_buf_is_valid(b) then
      vim.bo[b].modifiable = false
    end
  end

  local trimmed = utils.trim(text or "")
  M.state.write_in_text[M.state.current_q_idx] = trimmed

  local q = M.state.questions[M.state.current_q_idx]
  if not q then return end

  if confirmed and trimmed ~= "" and not q.is_multi_select then
    M.state.selected_answers[M.state.current_q_idx] = "write_in"
    M.confirm_current_question()
    return
  elseif not q.is_multi_select then
    if trimmed ~= "" then
      M.state.selected_answers[M.state.current_q_idx] = "write_in"
    elseif M.state.selected_answers[M.state.current_q_idx] == "write_in" then
      M.state.selected_answers[M.state.current_q_idx] = nil
    end
  end
  M.build_items()
  M.render_buffer()
  M.sync_cursor()
end

---Setup buffer-local insert mode keymaps during inline write-in editing
---@param write_line number
---@param prefix_end number
function M.setup_inline_insert_keymaps(write_line, prefix_end)
  local b = M.state.buf
  if not b or not vim.api.nvim_buf_is_valid(b) then return end
  local win = M.state.win or vim.api.nvim_get_current_win()

  local function get_input_text()
    M.activate_buf(b)
    if not b or not vim.api.nvim_buf_is_valid(b) then return "" end
    local line = vim.api.nvim_buf_get_lines(b, write_line - 1, write_line, false)[1] or ""
    return (#line >= prefix_end) and line:sub(prefix_end + 1) or ""
  end

  local function handle_esc()
    M.activate_buf(b)
    M.finish_inline_write_in(false, get_input_text())
  end

  vim.keymap.set("i", "<CR>", function()
    M.activate_buf(b)
    M.finish_inline_write_in(true, get_input_text())
  end, { buffer = b, silent = true, nowait = true })

  vim.keymap.set("i", "<Esc>", handle_esc, { buffer = b, silent = true, nowait = true })
  vim.keymap.set("i", "<C-c>", handle_esc, { buffer = b, silent = true, nowait = true })

  vim.keymap.set("i", "<Up>", function()
    M.activate_buf(b)
    handle_esc()
    M.select_prev()
  end, { buffer = b, silent = true, nowait = true })

  vim.keymap.set("i", "<Down>", function()
    M.activate_buf(b)
    handle_esc()
    M.select_next()
  end, { buffer = b, silent = true, nowait = true })

  local function guard_backspace()
    local cur = vim.api.nvim_win_get_cursor(win)
    return (cur[1] == write_line and cur[2] > prefix_end) and "<BS>" or ""
  end
  vim.keymap.set("i", "<BS>", guard_backspace, { buffer = b, expr = true, silent = true })
  vim.keymap.set("i", "<C-h>", guard_backspace, { buffer = b, expr = true, silent = true })

  vim.keymap.set("i", "<C-w>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] == write_line and cur[2] > prefix_end then
      local line = vim.api.nvim_buf_get_lines(b, write_line - 1, write_line, false)[1] or ""
      local before_cur = line:sub(1, cur[2])
      local after_cur = line:sub(cur[2] + 1)
      local new_input = before_cur:sub(prefix_end + 1):gsub("%s*[%w_]+%s*$", "")
      vim.api.nvim_buf_set_lines(b, write_line - 1, write_line, false, { line:sub(1, prefix_end) .. new_input .. after_cur })
      pcall(vim.api.nvim_win_set_cursor, win, { write_line, prefix_end + #new_input })
    end
    return ""
  end, { buffer = b, silent = true })

  vim.keymap.set("i", "<C-u>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] == write_line then
      local line = vim.api.nvim_buf_get_lines(b, write_line - 1, write_line, false)[1] or ""
      vim.api.nvim_buf_set_lines(b, write_line - 1, write_line, false, { line:sub(1, prefix_end) })
      pcall(vim.api.nvim_win_set_cursor, win, { write_line, prefix_end })
    end
    return ""
  end, { buffer = b, silent = true })

  vim.keymap.set("i", "<Left>", function()
    local cur = vim.api.nvim_win_get_cursor(win)
    return (cur[1] == write_line and cur[2] > prefix_end) and "<Left>" or ""
  end, { buffer = b, expr = true, silent = true })

  vim.keymap.set("i", "<Home>", function()
    pcall(vim.api.nvim_win_set_cursor, win, { write_line, prefix_end })
    return ""
  end, { buffer = b, silent = true })

  local group = vim.api.nvim_create_augroup("AgyQuestionInlineWriteIn_" .. b, { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = b,
    once = true,
    callback = function()
      M.activate_buf(b)
      if M.state.is_editing_write_in then
        handle_esc()
      end
    end,
  })
end

---Start inline editing for the write-in response on the current question
function M.start_inline_write_in()
  M.activate_buf()
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

  local b = M.state.buf
  local win = find_tab_win(b, M.state.win)
  if not win then return end

  M.state.win = win
  local write_line = M.get_opt_start_line() + (write_in_idx - (M.state.scroll_offset or 1))
  vim.bo[b].modifiable = true

  if vim.api.nvim_get_current_win() ~= win then
    pcall(vim.api.nvim_set_current_win, win)
  end

  local line = vim.api.nvim_buf_get_lines(b, write_line - 1, write_line, false)[1] or ""
  local _, e = line:find("Write%-in:%s*")
  local prefix_end = e or #line

  pcall(vim.api.nvim_win_set_cursor, win, { write_line, #line })
  M.setup_inline_insert_keymaps(write_line, prefix_end)
  pcall(vim.cmd, "startinsert!")
end

---Programmatically set write-in response text or start inline editing
---@param text? string If provided, sets write-in text directly; otherwise starts inline editing
function M.prompt_write_in(text)
  M.activate_buf()
  if text ~= nil then
    M.set_write_in(text)
  else
    M.start_inline_write_in()
  end
end

---Programmatically set write-in response text for the current question
---@param text string
function M.set_write_in(text)
  M.activate_buf()
  if M.is_summary_page() then return end
  local trimmed = utils.trim(text or "")
  M.state.write_in_text[M.state.current_q_idx] = trimmed
  local q = M.state.questions[M.state.current_q_idx]
  if q and not q.is_multi_select then
    if trimmed ~= "" then
      M.state.selected_answers[M.state.current_q_idx] = "write_in"
      M.confirm_current_question()
      return
    elseif M.state.selected_answers[M.state.current_q_idx] == "write_in" then
      M.state.selected_answers[M.state.current_q_idx] = nil
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

  return table.concat(answers, "\n\n"), answered_questions
end

---Check if a question has at least one selected answer or write-in text
---@param q_idx number
---@return boolean
function M.has_question_answer(q_idx)
  return has_question_answer(q_idx)
end

---Validate and submit all answers across questions
function M.submit_all()
  M.activate_buf()
  local active_buf = M.state.buf
  for q_idx = 1, #M.state.questions do
    if not M.has_question_answer(q_idx) then
      M.go_to_question(q_idx)
      vim.notify(string.format("[agy.nvim] Please answer question %d of %d.", q_idx, #M.state.questions), vim.log.levels.WARN)
      return
    end
  end

  local answer_payload, answered_questions = M.format_answers()
  local on_sub = M.state.on_submit
  M.close(active_buf)
  if on_sub then
    on_sub(answer_payload, answered_questions)
  end
end

---Confirm current question answer and advance or complete
function M.confirm_current_question()
  M.activate_buf()
  if not M.state.questions[M.state.current_q_idx] then return end

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
  M.activate_buf(target_buf)

  local function is_in_question()
    M.activate_buf(target_buf)
    local win = vim.api.nvim_get_current_win()
    if not win or not vim.api.nvim_win_is_valid(win) then return false end
    return vim.api.nvim_win_get_cursor(win)[1] >= M.get_start_line()
  end

  local function handle_down()
    M.activate_buf(target_buf)
    if is_in_question() then
      M.select_next()
    else
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      if cur[1] + 1 >= M.get_start_line() then
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
    M.activate_buf(target_buf)
    if is_in_question() then
      if M.state.selected_idx > 1 then
        M.select_prev()
      else
        local target_line = math.max(1, M.get_start_line() - 1)
        local win = find_tab_win(target_buf, M.state.win) or vim.api.nvim_get_current_win()
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
      M.activate_buf(target_buf)
      if is_in_question() then
        fn()
      elseif fallback_key then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(fallback_key, true, false, true), "n", false)
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

  vim.keymap.set("n", "<CR>", function()
    M.activate_buf(target_buf)
    if is_in_question() then
      M.accept()
    else
      local protocol = package.loaded["agy.protocol"]
      local handled = protocol and protocol.buffers and protocol.buffers[target_buf]
          and protocol.toggle_tool_at_cursor(target_buf, vim.api.nvim_get_current_win())
      if not handled then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
      end
    end
  end, q_opts)

  vim.keymap.set("n", "<C-s>", function()
    M.activate_buf(target_buf)
    M.submit_all()
  end, q_opts)

  for _, k in ipairs({ "w", "i", "a" }) do
    vim.keymap.set("n", k, pass_or(function() M.prompt_write_in() end, k), q_opts)
  end

  for num = 1, 9 do
    vim.keymap.set("n", tostring(num), pass_or(function() M.jump_to(num) end, tostring(num)), q_opts)
  end

  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, pass_or(function() M.cancel(target_buf) end, k), q_opts)
  end

  vim.keymap.set("n", "<C-c>", function()
    M.activate_buf(target_buf)
    M.cancel(target_buf)
  end, q_opts)

  local q_group = vim.api.nvim_create_augroup("AgyQuestionCursor_" .. target_buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = q_group,
    buffer = target_buf,
    callback = function()
      M.activate_buf(target_buf)
      if not M.is_visible(target_buf) or M.state.is_editing_write_in then return end
      local cur_win = vim.api.nvim_get_current_win()
      local win = find_tab_win(target_buf, M.state.win)
      if not win then return end
      M.state.win = win
      if cur_win ~= win then return end

      local cur_line = vim.api.nvim_win_get_cursor(win)[1]
      if cur_line < M.get_start_line() then return end

      local opt_start_line = M.get_opt_start_line()
      local start_idx = M.state.scroll_offset or 1
      local end_idx = math.min(#M.state.items, start_idx + 5)
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

---Display or update the interactive question UI directly inside the conversation session buffer
---@param target_win number
---@param target_buf number
---@param questions table[]
---@param opts? { config?: table, on_submit?: fun(payload: string, answered: table[]), on_cancel?: fun() }
function M.show(target_win, target_buf, questions, opts)
  assert(questions and type(questions) == "table" and #questions > 0, "agy question: questions array is required")
  opts = opts or {}

  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    target_buf = vim.api.nvim_get_current_buf()
  end
  target_win = find_tab_win(target_buf, target_win) or vim.api.nvim_get_current_win()

  if M.states[target_buf] then
    M.activate_buf(target_buf)
    M.clear_keymaps()
  end

  local protocol = package.loaded["agy.protocol"]
  local pstate = protocol and protocol.buffers and protocol.buffers[target_buf]

  local st = new_question_state()
  st.win = target_win
  st.buf = target_buf
  st.questions = questions
  st.config = opts.config or config_mod.get()
  st.on_submit = opts.on_submit
  st.on_cancel = opts.on_cancel
  st.start_line = (pstate and pstate.prompt_start_line) or vim.api.nvim_buf_line_count(target_buf)

  M.states[target_buf] = st
  M.state = st

  M.build_items()
  M.render_buffer()
  M.setup_keymaps(target_buf)
  M.sync_cursor()
  M.focus()
end

local resize_group = vim.api.nvim_create_augroup("AgyQuestionResize", { clear = true })
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = resize_group,
  callback = function()
    local prev_state = M.state
    for buf, st in pairs(M.states) do
      if vim.api.nvim_buf_is_valid(buf) and #st.questions > 0 then
        M.state = st
        M.update_win_config()
      end
    end
    if prev_state and prev_state.buf and M.states[prev_state.buf] then
      M.state = prev_state
    end
  end,
})

return M
