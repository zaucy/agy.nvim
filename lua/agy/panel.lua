local utils = require("agy.utils")

local M = {}

M.NS_PANEL = vim.api.nvim_create_namespace("agy_panel")

---@class AgyPanelState
---@field win? number Window ID of active panel
---@field buf? number Buffer ID of active panel
---@field target_win? number Parent conversation window
---@field target_buf? number Parent conversation buffer
---@field meta? table[] Highlighting metadata
---@field apply_highlights? fun(buf: number, meta: any)
---@field on_close? fun()
---@field filetype? string
M.state = {
  win = nil,
  buf = nil,
  target_win = nil,
  target_buf = nil,
  meta = nil,
  apply_highlights = nil,
  on_close = nil,
  filetype = nil,
}

---Check whether the bottom panel is currently open and valid
---@return boolean
function M.is_open()
  return M.state.win ~= nil and vim.api.nvim_win_is_valid(M.state.win)
end

---Get active panel buffer
---@return number|nil
function M.get_buf()
  return M.state.buf
end

---Get active panel window
---@return number|nil
function M.get_win()
  return M.state.win
end

---Format a standard two-sided Antigravity footer line
---@param left_nav string
---@param right_info string
---@param width number
---@return string
function M.format_footer(left_nav, right_info, width)
  width = width or 80
  local left_len = vim.fn.strdisplaywidth(left_nav)
  local right_len = vim.fn.strdisplaywidth(right_info)
  local pad = math.max(2, width - left_len - right_len)
  return left_nav .. string.rep(" ", pad) .. right_info
end

---Apply highlighting to a standard footer row
---@param buf number
---@param ns number
---@param row number
---@param footer_text string
function M.apply_footer_highlights(buf, ns, row, footer_text)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    hl_group = "AgyCompletionFooter",
    priority = 50,
  })

  local key_tokens = { "↑/↓", "pgup/pgdown", "pgup/down", "ctrl+end", "ctrl+home", "esc", "enter", "tab", "q" }
  for _, k in ipairs(key_tokens) do
    local s, e = footer_text:find(k, 1, true)
    if s and e then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, s - 1, {
        end_col = e,
        hl_group = "AgyCompletionKey",
        priority = 60,
      })
    end
  end
end

---Open a bottom panel in the autocomplete / lower area below the active prompt
---@param opts {
---  target_win?: number,
---  target_buf?: number,
---  lines: string[],
---  meta?: table[],
---  apply_highlights?: fun(buf: number, meta: any),
---  filetype?: string,
---  syntax?: string,
---  max_height?: number,
---  on_close?: fun(),
---  keymaps?: table<string, fun()|string>,
---}
---@return number win, number buf
function M.open(opts)
  opts = opts or {}

  -- Ensure normal mode before creating/opening the panel
  vim.cmd("stopinsert")

  -- Close any active autocomplete popup
  local comp = package.loaded["agy.completion"]
  if comp and comp.close then
    comp.close()
  end

  -- If panel already open, close old one
  M.close()

  local target_win = (opts.target_win and vim.api.nvim_win_is_valid(opts.target_win))
      and opts.target_win
      or vim.api.nvim_get_current_win()
  local target_buf = (opts.target_buf and vim.api.nvim_buf_is_valid(opts.target_buf))
      and opts.target_buf
      or vim.api.nvim_win_get_buf(target_win)

  M.state.target_win = target_win
  M.state.target_buf = target_buf
  M.state.on_close = opts.on_close
  M.state.apply_highlights = opts.apply_highlights
  M.state.filetype = opts.filetype or "agy_panel"

  -- Ensure prompt position in target window
  local protocol = package.loaded["agy.protocol"]
  local pstate = protocol and protocol.buffers and protocol.buffers[target_buf]
  if pstate and pstate.prompt_start_line and vim.api.nvim_win_is_valid(target_win) then
    pcall(vim.api.nvim_win_set_cursor, target_win, { pstate.prompt_start_line, 0 })
  end

  local lines = opts.lines or {}
  local lines_count = #lines

  -- Calculate geometry matching autocomplete area below prompt
  local win_width = vim.api.nvim_win_get_width(target_win)
  local win_height = vim.api.nvim_win_get_height(target_win)
  local width = win_width

  M.state.max_height = opts.max_height

  local border_offset = 1 -- account for prompt bottom border virtual line
  local max_desired = opts.max_height or (win_height - 2)
  local height = math.min(lines_count, max_desired)
  local winline = 1
  local space_below = win_height - 2

  vim.api.nvim_win_call(target_win, function()
    winline = vim.fn.winline()
    space_below = win_height - (winline + border_offset)
    if space_below < height then
      local needed = height - space_below
      local view = vim.fn.winsaveview()
      view.topline = math.max(1, view.topline + needed)
      vim.fn.winrestview(view)
      pcall(vim.cmd, "redraw")
      winline = vim.fn.winline()
      space_below = win_height - (winline + border_offset)
    end
  end)

  height = math.max(3, math.min(height, space_below))
  local row = winline + border_offset

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = M.state.filetype

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  if opts.syntax then
    pcall(vim.treesitter.start, buf, opts.syntax)
  end

  if opts.apply_highlights then
    M.state.meta = opts.meta
    pcall(opts.apply_highlights, buf, opts.meta)
  end

  local win_cfg = {
    relative = "win",
    win = target_win,
    row = row,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "none",
    focusable = true,
    zindex = 150,
  }

  local win = vim.api.nvim_open_win(buf, true, win_cfg)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"

  -- Force normal mode and cursor at top
  vim.cmd("stopinsert")
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  M.state.win = win
  M.state.buf = buf

  -- Keybindings for navigation and closing
  local function close_and_focus_prompt(enter_insert)
    M.close()
    if vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
      if pstate and pstate.prompt_start_line then
        pcall(vim.api.nvim_win_set_cursor, target_win, { pstate.prompt_start_line, 0 })
      end
      if enter_insert then
        vim.cmd("startinsert")
      end
    end
  end

  for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", key, function()
      close_and_focus_prompt(false)
    end, { buffer = buf, silent = true, nowait = true })
  end

  for _, key in ipairs({ "<Esc>", "<CR>" }) do
    vim.keymap.set("i", key, function()
      close_and_focus_prompt(false)
    end, { buffer = buf, silent = true, nowait = true })
  end

  for _, key in ipairs({ "i", "a", "I", "A", "o", "O" }) do
    vim.keymap.set("n", key, function()
      close_and_focus_prompt(true)
    end, { buffer = buf, silent = true, nowait = true })
  end

  vim.keymap.set("n", "<C-Home>", "gg", { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<C-End>", "G", { buffer = buf, silent = true, nowait = true })

  -- Autocommands for panel cleanup and insert mode transitions
  local augroup = vim.api.nvim_create_augroup("AgyPanel_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if M.state.buf == buf then
          close_and_focus_prompt(true)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = augroup,
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if M.state.buf == buf then
          M.close()
        end
      end)
    end,
  })

  return win, buf
end

---Update the content and highlights of the currently open panel
---@param lines string[]
---@param meta? table[]
function M.update(lines, meta)
  if not M.is_open() then return end
  local buf = M.state.buf
  local win = M.state.win
  if not buf or not win or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return
  end

  M.state.meta = meta

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  if M.state.apply_highlights then
    pcall(M.state.apply_highlights, buf, meta)
  end

  -- Recalculate height dynamically, scrolling target_win if needed
  local target_win = M.state.target_win
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    local win_height = vim.api.nvim_win_get_height(target_win)
    local max_desired = M.state.max_height or (win_height - 2)
    local desired_height = math.min(#lines, max_desired)

    vim.api.nvim_win_call(target_win, function()
      local winline = vim.fn.winline()
      local border_offset = 1
      local space_below = win_height - (winline + border_offset)
      if space_below < desired_height then
        local needed = desired_height - space_below
        local view = vim.fn.winsaveview()
        view.topline = math.max(1, view.topline + needed)
        vim.fn.winrestview(view)
        pcall(vim.cmd, "redraw")
        winline = vim.fn.winline()
        space_below = win_height - (winline + border_offset)
      end

      local new_height = math.max(3, math.min(desired_height, space_below))
      local new_row = winline + border_offset
      local win_cfg = vim.api.nvim_win_get_config(win)
      local cur_row = win_cfg.row
      if type(cur_row) == "table" then cur_row = cur_row[false] or 0 end
      if cur_row ~= new_row or win_cfg.height ~= new_height then
        win_cfg.row = new_row
        win_cfg.height = new_height
        pcall(vim.api.nvim_win_set_config, win, win_cfg)
      end
    end)
  end
end

---Close the panel if currently open
function M.close()
  local win = M.state.win
  local on_close = M.state.on_close

  M.state.win = nil
  M.state.buf = nil
  M.state.on_close = nil
  M.state.apply_highlights = nil
  M.state.meta = nil

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end

  if on_close then
    pcall(on_close)
  end
end

return M
