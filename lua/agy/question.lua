local utils = require("agy.utils")
local config_mod = require("agy.config")

local M = {}

M.NS_HL = vim.api.nvim_create_namespace("agy_question")

---@class AgyQuestionItem
---@field type "option"|"write_in"|"submit"
---@field opt_idx number
---@field text string

---@class AgyQuestionUIState
---@field win? number
---@field buf? number
---@field target_win? number
---@field target_buf? number
---@field mapped_buf? number
---@field is_hidden boolean
---@field questions table[]
---@field current_q_idx number
---@field selected_idx number
---@field scroll_offset number
---@field selected_answers table<number, any>
---@field write_in_text table<number, string>
---@field items AgyQuestionItem[]
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
  is_hidden = false,
  questions = {},
  current_q_idx = 1,
  selected_idx = 1,
  scroll_offset = 1,
  selected_answers = {},
  write_in_text = {},
  items = {},
  config = nil,
  on_submit = nil,
  on_cancel = nil,
}

local QUESTION_KEYS = {
  "j", "k", "<Down>", "<Up>", "<C-n>", "<C-p>",
  "h", "l", "<Left>", "<Right>", "<Tab>", "<S-Tab>",
  "[", "]",
  "<Space>", "<CR>", "<C-s>", "w", "i",
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

---Check whether the question floating window is currently visible and not hidden
---@return boolean
function M.is_visible()
  return M.state.win ~= nil and vim.api.nvim_win_is_valid(M.state.win) and not M.state.is_hidden
end

---Temporarily hide the question floating window (e.g. when scrolling up into history)
function M.hide()
  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    local target_win = M.state.target_win
    if vim.api.nvim_get_current_win() == M.state.win and target_win and vim.api.nvim_win_is_valid(target_win) then
      pcall(vim.api.nvim_set_current_win, target_win)
    end
    pcall(vim.api.nvim_win_close, M.state.win, true)
  end
  M.state.win = nil
  M.state.is_hidden = true
end

---Remove question keymaps from mapped buffer
function M.clear_keymaps()
  local b = M.state.mapped_buf or M.state.target_buf
  if b and vim.api.nvim_buf_is_valid(b) then
    for _, key in ipairs(QUESTION_KEYS) do
      pcall(vim.keymap.del, "n", key, { buffer = b })
    end
  end
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) then
    for _, key in ipairs(QUESTION_KEYS) do
      pcall(vim.keymap.del, "n", key, { buffer = M.state.buf })
    end
  end
  M.state.mapped_buf = nil
end

---Close question floating window, delete keymaps, and reset state
function M.close()
  M.hide()
  M.clear_keymaps()
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) then
    pcall(vim.api.nvim_buf_delete, M.state.buf, { force = true })
  end

  M.state.win = nil
  M.state.buf = nil
  M.state.target_win = nil
  M.state.target_buf = nil
  M.state.questions = {}
  M.state.current_q_idx = 1
  M.state.selected_idx = 1
  M.state.scroll_offset = 1
  M.state.selected_answers = {}
  M.state.write_in_text = {}
  M.state.items = {}
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
    local items = {}
    table.insert(items, {
      type = "submit_all",
      opt_idx = 1,
      text = "Submit All Answers",
    })
    for q_idx = 1, #M.state.questions do
      table.insert(items, {
        type = "edit_question",
        target_q_idx = q_idx,
        opt_idx = 1 + q_idx,
        text = string.format("Edit Question %d", q_idx),
      })
    end
    M.state.items = items
    if M.state.selected_idx > #items or M.state.selected_idx < 1 then
      M.state.selected_idx = 1
      M.state.scroll_offset = 1
    end
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

---Render the question floating buffer contents and highlights
function M.render_buffer()
  if not M.state.buf or not vim.api.nvim_buf_is_valid(M.state.buf) then return end

  local cfg = M.state.config or config_mod.get()
  local q_icon = get_icon("question", cfg)
  local horiz_char = get_horizontal_sep(cfg)

  local win_width = 80
  if M.state.target_win and vim.api.nvim_win_is_valid(M.state.target_win) then
    win_width = vim.api.nvim_win_get_width(M.state.target_win)
  end

  if M.is_summary_page() then
    local lines = {}
    local highlights = {}

    -- Top border divider
    local top_divider = string.rep(horiz_char, win_width)
    table.insert(lines, top_divider)
    table.insert(highlights, {
      row = 0,
      start_col = 0,
      end_col = #top_divider,
      hl_group = "AgyDividerLine",
    })

    -- Header line
    local header_text = string.format("  %s Summary: Review Answers (%d/%d)", q_icon, #M.state.questions, #M.state.questions)
    table.insert(lines, header_text)
    table.insert(highlights, {
      row = #lines - 1,
      start_col = 0,
      end_col = #header_text,
      hl_group = "AgyQuestionHeader",
    })

    -- Spacer
    table.insert(lines, "")

    -- Summary of each question
    for q_idx, quest in ipairs(M.state.questions) do
      local q_title = string.format("  %d. %s", q_idx, quest.question)
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

    -- Summary items (Submit All Answers, Edit Question 1..N)
    for i, it in ipairs(M.state.items) do
      local is_sel = (i == M.state.selected_idx)
      local pointer = is_sel and "> " or "  "
      local line_str = ""
      if it.type == "submit_all" then
        line_str = pointer .. "[ " .. it.text .. " ]"
      elseif it.type == "edit_question" then
        line_str = pointer .. string.format("%d. %s", it.target_q_idx, it.text)
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
    local footer_text = "  ←/h Previous · enter Select · 1-" .. tostring(#M.state.questions) .. " Edit · esc Cancel"
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

    vim.bo[M.state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
    vim.bo[M.state.buf].modifiable = false

    -- Extmarks
    vim.api.nvim_buf_clear_namespace(M.state.buf, M.NS_HL, 0, -1)
    for _, hl in ipairs(highlights) do
      if hl.hl_group then
        vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, hl.start_col or 0, {
          end_col = hl.end_col,
          hl_group = hl.hl_group,
          priority = 100,
        })
      elseif hl.is_sel ~= nil then
        if hl.is_sel then
          vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
            line_hl_group = "AgyCompletionSel",
            priority = 100,
          })
          vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
            end_col = 2,
            hl_group = "AgyCompletionPointer",
            priority = 101,
          })
        end
        if hl.item and hl.item.type == "submit_all" then
          vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
            end_col = #hl.line_str,
            hl_group = "AgyCompletionKey",
            priority = 100,
          })
        end
      end
    end

    local footer_row = #lines - 2
    vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, footer_row, 0, {
      hl_group = "AgyCompletionFooter",
    })
    local key_tokens = { "←/h", "enter", "esc" }
    for _, tok in ipairs(key_tokens) do
      local s, e = footer_text:find(tok, 1, true)
      if s and e then
        vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, footer_row, s - 1, {
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

  local lines = {}
  local highlights = {}

  -- Top border divider
  local top_divider = string.rep(horiz_char, win_width)
  table.insert(lines, top_divider)
  table.insert(highlights, {
    row = 0,
    start_col = 0,
    end_col = #top_divider,
    hl_group = "AgyDividerLine",
  })

  -- Question header line
  local count_str = #M.state.questions > 1 and string.format(" (%d/%d)", M.state.current_q_idx, #M.state.questions) or ""
  local header_text = string.format("  %s Question%s: %s", q_icon, count_str, q.question)
  table.insert(lines, header_text)
  table.insert(highlights, {
    row = #lines - 1,
    start_col = 0,
    end_col = #header_text,
    hl_group = "AgyQuestionHeader",
  })

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
      local custom = M.state.write_in_text[M.state.current_q_idx]
      local mark = (M.state.selected_answers[M.state.current_q_idx] == "write_in") and "(•) " or "( ) "
      if q.is_multi_select then
        mark = (custom and custom ~= "") and "[x] " or "[ ] "
      end
      line_str = pointer .. mark .. string.format("%d. ", #q.options + 1) .. ((custom and custom ~= "") and ('Write-in: "' .. custom .. '"') or "Write-in response...")
    elseif it.type == "submit" then
      line_str = pointer .. "[ " .. it.text .. " ]"
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
  local nav_hint = (#M.state.questions > 1) and "tab/h/l Questions · " or ""
  if q.is_multi_select then
    footer_text = "  " .. nav_hint .. "↑/↓/j/k Navigate · space Toggle · enter Confirm · w Write-in · esc Cancel"
  else
    footer_text = "  " .. nav_hint .. "↑/↓/j/k Navigate · enter Select · 1-" .. tostring(#items) .. " Jump · w Write-in · esc Cancel"
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

  vim.bo[M.state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
  vim.bo[M.state.buf].modifiable = false

  -- Extmark application
  vim.api.nvim_buf_clear_namespace(M.state.buf, M.NS_HL, 0, -1)
  for _, hl in ipairs(highlights) do
    if hl.hl_group then
      vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, hl.start_col or 0, {
        end_col = hl.end_col,
        hl_group = hl.hl_group,
        priority = 100,
      })
    elseif hl.is_sel ~= nil then
      if hl.is_sel then
        vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
          line_hl_group = "AgyCompletionSel",
          priority = 100,
        })
        vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
          end_col = 2,
          hl_group = "AgyCompletionPointer",
          priority = 101,
        })
      end
      if hl.line_str:find("%[x%]") or hl.line_str:find("%(•%)") then
        local s, e = hl.line_str:find("%[x%]")
        if not s then s, e = hl.line_str:find("%(•%)") end
        if s and e then
          vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, s - 1, {
            end_col = e,
            hl_group = "AgyQuestionChecked",
            priority = 101,
          })
        end
      end
      if hl.item and hl.item.type == "submit" then
        vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
          end_col = #hl.line_str,
          hl_group = "AgyCompletionKey",
          priority = 100,
        })
      end
    end
  end

  local footer_row = #lines - 2
  vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, footer_row, 0, {
    hl_group = "AgyCompletionFooter",
  })
  local key_tokens = { "tab/h/l", "↑/↓/j/k", "enter", "space", "w", "esc" }
  for _, tok in ipairs(key_tokens) do
    local s, e = footer_text:find(tok, 1, true)
    if s and e then
      vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, footer_row, s - 1, {
        end_col = e,
        hl_group = "AgyCompletionKey",
      })
    end
  end
end

---Calculate the target window row for the question popup so it renders directly over top of the prompt area
---@param target_win number
---@param target_buf number
---@param height number
---@param should_scroll boolean
---@return number row
function M.calc_prompt_bottom_row(target_win, target_buf, height, should_scroll)
  local win_height = vim.api.nvim_win_get_height(target_win)
  local protocol = package.loaded["agy.protocol"]
  local state = protocol and protocol.buffers[target_buf]
  local prompt_line = (state and state.prompt_start_line) or vim.api.nvim_buf_line_count(target_buf)

  local win_pos = vim.api.nvim_win_get_position(target_win)
  local pos = vim.fn.screenpos(target_win, prompt_line, 1)

  if (not pos or pos.row == 0) and vim.api.nvim_get_current_win() == target_win then
    pcall(vim.cmd, "redraw")
    pos = vim.fn.screenpos(target_win, prompt_line, 1)
  end

  local top_offset = 0
  if state and state.prompt_extmark_id then
    local ok, ext = pcall(vim.api.nvim_buf_get_extmark_by_id, target_buf, require("agy.render").NS_UI, state.prompt_extmark_id, { details = true })
    if ok and ext and ext[3] and ext[3].virt_lines and ext[3].virt_lines_above then
      top_offset = #ext[3].virt_lines
    end
  end

  if pos and pos.row > 0 then
    local prompt_win_row = pos.row - 1 - win_pos[1]
    local target_row = math.max(0, prompt_win_row - top_offset)

    if should_scroll and (target_row + height > win_height) then
      local cur_win = vim.api.nvim_get_current_win()
      if cur_win == target_win then
        local cur_line = vim.api.nvim_win_get_cursor(target_win)[1]
        if cur_line >= prompt_line then
          local needed = (target_row + height) - win_height
          local view = vim.fn.winsaveview()
          view.topline = view.topline + needed
          vim.fn.winrestview(view)
          pcall(vim.cmd, "redraw")
          pos = vim.fn.screenpos(target_win, prompt_line, 1)
          if pos and pos.row > 0 then
            prompt_win_row = pos.row - 1 - win_pos[1]
            target_row = math.max(0, prompt_win_row - top_offset)
          end
        end
      end
    end

    return math.max(0, math.min(target_row, win_height - height))
  end

  return math.max(0, win_height - height)
end

---Update floating window geometry to stay docked at target window bottom of prompt
function M.update_win_config()
  if not M.is_visible() or not M.state.target_win or not vim.api.nvim_win_is_valid(M.state.target_win) then
    return
  end
  local target_win = M.state.target_win
  local target_buf = M.state.target_buf or vim.api.nvim_win_get_buf(target_win)
  local win_width = vim.api.nvim_win_get_width(target_win)
  local win_height = vim.api.nvim_win_get_height(target_win)
  local line_count = vim.api.nvim_buf_line_count(M.state.buf)
  local height = math.min(line_count, win_height)
  local row = M.calc_prompt_bottom_row(target_win, target_buf, height, false)

  local win_cfg = {
    relative = "win",
    win = target_win,
    row = row,
    col = 0,
    width = win_width,
    height = height,
    style = "minimal",
    border = "none",
    focusable = true,
    zindex = 200,
  }
  vim.api.nvim_win_set_config(M.state.win, win_cfg)
end

---Synchronize cursor position in the question window to the selected option
function M.sync_cursor()
  if not M.state.win or not vim.api.nvim_win_is_valid(M.state.win) then return end
  if not M.state.buf or not vim.api.nvim_buf_is_valid(M.state.buf) then return end
  local opt_start = 4
  if M.is_summary_page() then
    opt_start = 4 + (#M.state.questions * 2) + 1
  end
  local cursor_line = opt_start + (M.state.selected_idx - (M.state.scroll_offset or 1))
  local line_count = vim.api.nvim_buf_line_count(M.state.buf)
  cursor_line = math.max(1, math.min(cursor_line, line_count))
  pcall(vim.api.nvim_win_set_cursor, M.state.win, { cursor_line, 0 })
end

---Focus the question floating window and position cursor on active option
function M.focus()
  if not M.state.win or not vim.api.nvim_win_is_valid(M.state.win) then return end
  if vim.api.nvim_get_current_win() ~= M.state.win then
    vim.api.nvim_set_current_win(M.state.win)
  end
  M.sync_cursor()
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
  M.update_win_config()
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
    elseif it.type == "edit_question" then
      M.go_to_question(it.target_q_idx)
      return
    end
    local q = M.state.questions[M.state.current_q_idx]
    if q and not q.is_multi_select and it.type == "option" then
      M.state.selected_answers[M.state.current_q_idx] = it.opt_idx
      M.confirm_current_question()
      return
    elseif q and not q.is_multi_select and it.type == "write_in" then
      M.prompt_write_in()
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
  elseif it.type == "edit_question" then
    M.go_to_question(it.target_q_idx)
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
  elseif it.type == "write_in" then
    M.prompt_write_in()
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
  elseif it.type == "edit_question" then
    M.go_to_question(it.target_q_idx)
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
  elseif it.type == "write_in" then
    M.prompt_write_in()
  elseif it.type == "submit" then
    M.confirm_current_question()
  end
end

---Prompt user for write-in response
function M.prompt_write_in()
  if M.is_summary_page() then return end
  local target_win = M.state.target_win
  local target_buf = M.state.target_buf
  -- Temporarily hide the question window so the floating input modal / cmdline
  -- is not obscured behind zindex 200
  M.hide()

  vim.ui.input({
    prompt = "Custom response: ",
    default = M.state.write_in_text[M.state.current_q_idx] or "",
  }, function(input)
    if input and utils.trim(input) ~= "" then
      local trimmed = utils.trim(input)
      M.state.write_in_text[M.state.current_q_idx] = trimmed
      local q = M.state.questions[M.state.current_q_idx]
      if q and not q.is_multi_select then
        M.state.selected_answers[M.state.current_q_idx] = "write_in"
        M.show_over_prompt(target_win, target_buf)
        M.confirm_current_question()
        return
      end
    end
    M.show_over_prompt(target_win, target_buf)
  end)
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

---Setup buffer-local keymaps on the target session buffer and question buffer
---@param target_buf number
function M.setup_keymaps(target_buf)
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then return end
  M.state.mapped_buf = target_buf

  local function is_at_prompt()
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win == M.state.win then
      return true
    end
    cur_win = vim.fn.bufwinid(target_buf)
    if cur_win == -1 or not vim.api.nvim_win_is_valid(cur_win) then
      cur_win = 0
    end
    local cur_line = vim.api.nvim_win_get_cursor(cur_win)[1]
    local protocol = package.loaded["agy.protocol"]
    local state = protocol and protocol.buffers[target_buf]
    local prompt_start = (state and state.prompt_start_line) or 1
    return cur_line >= prompt_start
  end

  -- Down navigation: j, <Down>, <C-n>
  local function handle_down()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win then
      M.select_next()
      return
    end

    if is_at_prompt() and M.is_visible() then
      M.focus()
    else
      local cur = vim.api.nvim_win_get_cursor(win)
      local line_count = vim.api.nvim_buf_line_count(target_buf)
      local protocol = package.loaded["agy.protocol"]
      local state = protocol and protocol.buffers[target_buf]
      local prompt_start = (state and state.prompt_start_line) or line_count
      if cur[1] + 1 >= prompt_start and M.is_visible() then
        M.focus()
      elseif cur[1] < line_count then
        local next_l = vim.api.nvim_buf_get_lines(target_buf, cur[1], cur[1] + 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { cur[1] + 1, math.min(cur[2], #next_l) })
      end
    end
  end

  -- Up navigation: k, <Up>, <C-p>
  local function handle_up()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win then
      if M.state.selected_idx > 1 then
        M.select_prev()
      else
        local target_win = M.state.target_win
        if target_win and vim.api.nvim_win_is_valid(target_win) then
          vim.api.nvim_set_current_win(target_win)
          local protocol = package.loaded["agy.protocol"]
          local state = protocol and protocol.buffers[target_buf]
          local prompt_start = (state and state.prompt_start_line) or vim.api.nvim_buf_line_count(target_buf)
          local target_line = math.max(1, prompt_start - 1)
          local line_text = vim.api.nvim_buf_get_lines(target_buf, target_line - 1, target_line, false)[1] or ""
          vim.api.nvim_win_set_cursor(target_win, { target_line, math.min(0, #line_text) })
        end
      end
      return
    end

    local cur = vim.api.nvim_win_get_cursor(win)
    local protocol = package.loaded["agy.protocol"]
    local state = protocol and protocol.buffers[target_buf]
    local prompt_start = (state and state.prompt_start_line) or 1

    if cur[1] >= prompt_start and M.is_visible() then
      M.focus()
    else
      if cur[1] > 1 then
        local prev_l = vim.api.nvim_buf_get_lines(target_buf, cur[1] - 2, cur[1] - 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { cur[1] - 1, math.min(cur[2], #prev_l) })
      end
    end
  end

  -- Next question navigation: l, <Right>
  local function handle_next_q()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win or is_at_prompt() then
      if #M.state.questions > 1 then
        M.next_question()
      end
    else
      local cur = vim.api.nvim_win_get_cursor(win)
      local line = vim.api.nvim_buf_get_lines(target_buf, cur[1] - 1, cur[1], false)[1] or ""
      if cur[2] < #line - 1 then
        vim.api.nvim_win_set_cursor(win, { cur[1], cur[2] + 1 })
      end
    end
  end

  -- Previous question navigation: h, <Left>
  local function handle_prev_q()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win or is_at_prompt() then
      if #M.state.questions > 1 then
        M.prev_question()
      end
    else
      local cur = vim.api.nvim_win_get_cursor(win)
      if cur[2] > 0 then
        vim.api.nvim_win_set_cursor(win, { cur[1], cur[2] - 1 })
      end
    end
  end

  local function handle_tab()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win or is_at_prompt() then
      if #M.state.questions > 1 then
        M.next_question()
      end
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
    end
  end

  local function handle_s_tab()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win or is_at_prompt() then
      if #M.state.questions > 1 then
        M.prev_question()
      end
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "n", false)
    end
  end

  local function handle_bracket_prev()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win or is_at_prompt() then
      if #M.state.questions > 1 then
        M.prev_question()
      end
    else
      vim.api.nvim_feedkeys("[", "n", false)
    end
  end

  local function handle_bracket_next()
    local win = vim.api.nvim_get_current_win()
    if win == M.state.win or is_at_prompt() then
      if #M.state.questions > 1 then
        M.next_question()
      end
    else
      vim.api.nvim_feedkeys("]", "n", false)
    end
  end

  local buffers_to_map = { target_buf }
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) and M.state.buf ~= target_buf then
    table.insert(buffers_to_map, M.state.buf)
  end

  for _, b in ipairs(buffers_to_map) do
    local opts = { buffer = b, silent = true, nowait = true }

    for _, k in ipairs({ "j", "<Down>", "<C-n>" }) do
      vim.keymap.set("n", k, handle_down, opts)
    end
    for _, k in ipairs({ "k", "<Up>", "<C-p>" }) do
      vim.keymap.set("n", k, handle_up, opts)
    end
    for _, k in ipairs({ "h", "<Left>" }) do
      vim.keymap.set("n", k, handle_prev_q, opts)
    end
    for _, k in ipairs({ "l", "<Right>" }) do
      vim.keymap.set("n", k, handle_next_q, opts)
    end
    vim.keymap.set("n", "<Tab>", handle_tab, opts)
    vim.keymap.set("n", "<S-Tab>", handle_s_tab, opts)
    vim.keymap.set("n", "[", handle_bracket_prev, opts)
    vim.keymap.set("n", "]", handle_bracket_next, opts)

    -- Space toggle
    vim.keymap.set("n", "<Space>", function()
      if is_at_prompt() and M.is_visible() then
        M.toggle()
      else
        local win = vim.api.nvim_get_current_win()
        local cur = vim.api.nvim_win_get_cursor(win)
        local line = vim.api.nvim_buf_get_lines(target_buf, cur[1] - 1, cur[1], false)[1] or ""
        if cur[2] < #line - 1 then
          vim.api.nvim_win_set_cursor(win, { cur[1], cur[2] + 1 })
        end
      end
    end, opts)

    -- Enter accept
    vim.keymap.set("n", "<CR>", function()
      if is_at_prompt() and M.is_visible() then
        M.accept()
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
      end
    end, opts)

    -- Submit with <C-s>
    vim.keymap.set("n", "<C-s>", function()
      if is_at_prompt() and M.is_visible() then
        M.submit_all()
      end
    end, opts)

    -- Write-in response: w, i
    for _, k in ipairs({ "w", "i" }) do
      vim.keymap.set("n", k, function()
        if is_at_prompt() and M.is_visible() then
          M.prompt_write_in()
        else
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "n", false)
        end
      end, opts)
    end

    -- Number jumps: 1 through 9
    for num = 1, 9 do
      vim.keymap.set("n", tostring(num), function()
        if is_at_prompt() and M.is_visible() then
          M.jump_to(num)
        else
          vim.api.nvim_feedkeys(tostring(num), "n", false)
        end
      end, opts)
    end

    -- Cancel: q, <Esc>, <C-c>
    for _, k in ipairs({ "q", "<Esc>", "<C-c>" }) do
      vim.keymap.set("n", k, function()
        if is_at_prompt() and M.is_visible() then
          M.cancel()
        else
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "n", false)
        end
      end, opts)
    end
  end

  -- Cursor tracking in question buffer: sync selected_idx if cursor moves via mouse or motion
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) then
    local q_group = vim.api.nvim_create_augroup("AgyQuestionCursor_" .. M.state.buf, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = q_group,
      buffer = M.state.buf,
      callback = function()
        if not M.is_visible() or not M.state.win or not vim.api.nvim_win_is_valid(M.state.win) then return end
        if vim.api.nvim_get_current_win() ~= M.state.win then return end
        local cur = vim.api.nvim_win_get_cursor(M.state.win)
        local cur_line = cur[1]
        local opt_start = 4
        if M.is_summary_page() then
          opt_start = 4 + (#M.state.questions * 2) + 1
        end
        local max_visible = 6
        local start_idx = M.state.scroll_offset or 1
        local total_count = #M.state.items
        local end_idx = math.min(total_count, start_idx + max_visible - 1)
        local opt_end = opt_start + (end_idx - start_idx)

        if cur_line >= opt_start and cur_line <= opt_end then
          local item_idx = start_idx + (cur_line - opt_start)
          if item_idx ~= M.state.selected_idx then
            M.state.selected_idx = item_idx
            M.render_buffer()
            pcall(vim.api.nvim_win_set_cursor, M.state.win, { cur_line, 0 })
          end
        elseif cur_line < opt_start then
          pcall(vim.api.nvim_win_set_cursor, M.state.win, { opt_start, 0 })
        elseif cur_line > opt_end then
          pcall(vim.api.nvim_win_set_cursor, M.state.win, { opt_end, 0 })
        end
      end,
    })
  end
end

---Display or update the interactive question popup window over top of the prompt
---@param target_win number
---@param target_buf number
function M.show_over_prompt(target_win, target_buf)
  if not M.state.questions or #M.state.questions == 0 then return end
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    target_win = M.state.target_win or vim.api.nvim_get_current_win()
  end
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    target_buf = M.state.target_buf or vim.api.nvim_get_current_buf()
  end

  M.state.target_win = target_win
  M.state.target_buf = target_buf
  M.state.is_hidden = false

  if not M.state.buf or not vim.api.nvim_buf_is_valid(M.state.buf) then
    M.state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.state.buf].buftype = "nofile"
    vim.bo[M.state.buf].bufhidden = "wipe"
    vim.bo[M.state.buf].swapfile = false
    vim.bo[M.state.buf].filetype = "agy_question"
  end

  M.render_buffer()

  local win_width = vim.api.nvim_win_get_width(target_win)
  local win_height = vim.api.nvim_win_get_height(target_win)
  local line_count = vim.api.nvim_buf_line_count(M.state.buf)
  local height = math.min(line_count, win_height)
  local row = M.calc_prompt_bottom_row(target_win, target_buf, height, true)

  local win_cfg = {
    relative = "win",
    win = target_win,
    row = row,
    col = 0,
    width = win_width,
    height = height,
    style = "minimal",
    border = "none",
    focusable = true,
    zindex = 200,
  }

  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    vim.api.nvim_win_set_config(M.state.win, win_cfg)
  else
    M.state.win = vim.api.nvim_open_win(M.state.buf, false, win_cfg)
    vim.wo[M.state.win].wrap = false
    vim.wo[M.state.win].cursorline = true
    vim.wo[M.state.win].winhighlight = "Normal:Normal,NormalFloat:Normal"
  end

  M.setup_keymaps(target_buf)
  M.focus()
end

---Display or update the interactive question popup window
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

  M.build_items()
  M.show_over_prompt(target_win, target_buf)
end

-- Resize and scroll listener to keep question menu docked cleanly at bottom of prompt
local resize_group = vim.api.nvim_create_augroup("AgyQuestionResize", { clear = true })
vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "WinScrolled" }, {
  group = resize_group,
  callback = function()
    if M.is_visible() then
      M.update_win_config()
    end
  end,
})

return M
