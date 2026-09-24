local utils = require("agy.utils")
local session_mod = require("agy.session")
local render = require("agy.render")
local transcript_mod = require("agy.transcript")
local config_mod = require("agy.config")
local completion = require("agy.completion")

local M = {}

---@class AgyBufferState
---@field buf number
---@field conversation_id? string
---@field session AgySession
---@field config AgyConfig
---@field prompt_start_line number 1-indexed line where active prompt begins
---@field prompt_extmark_id? number
---@field footer_extmark_id? number
---@field tool_calls table[]
---@field active_tool_record? table
---@field follow_bottom? boolean
---@field agent_extmark_id? number
---@field agent_line? number 0-indexed line of active agent response
---@field active_tool_line? number
---@field active_tool_extmark_id? number
---@field prompt_queue? table[]

---@type table<number, AgyBufferState>
M.buffers = {}

M._internal_guard = false

---Execute a function with modifiable temporarily set to true, then restore based on cursor position
---@param buf number
---@param fn fun(): any
---@return any
function M.with_modifiable(buf, fn)
  local old_guard = M._internal_guard
  M._internal_guard = true
  local prev = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, res = pcall(fn)
  M.update_modifiable(buf)
  M._internal_guard = old_guard
  if not ok then
    error(res)
  end
  return res
end

---Ensure that the buffer always has at least one line in the prompt area
---@param buf number
---@return boolean restored Whether deleted prompt lines were restored
function M.ensure_prompt_line(buf)
  local state = M.buffers[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return false end

  -- Don't manage active prompt while active question is present, or prompt uninitialized
  if state.active_question or not state.prompt_extmark_id then
    return false
  end

  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, {})
  if pos and #pos >= 1 then
    state.prompt_start_line = pos[1] + 1
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local prompt_start = state.prompt_start_line or line_count

  local restored = false
  if line_count < prompt_start then
    local old_guard = M._internal_guard
    M._internal_guard = true
    local prev = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    pcall(function()
      local needed = prompt_start - line_count
      local to_add = {}
      for _ = 1, needed do
        table.insert(to_add, "")
      end
      vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, to_add)
    end)
    vim.bo[buf].modifiable = prev
    M._internal_guard = old_guard
    restored = true
  end

  if not pos or #pos < 1 then
    local cur_count = vim.api.nvim_buf_line_count(buf)
    local target_line = math.min(prompt_start, cur_count)
    if target_line >= 1 then
      state.prompt_start_line = target_line
      state.prompt_extmark_id = render.set_divider(buf, target_line - 1, "user", nil, nil, true, state.prompt_extmark_id, state.config)
    end
  end

  return restored
end

---Update buffer modifiable state based on cursor position
---If cursor is in the history area (above prompt_start_line), modifiable is set to false
---If cursor is in the prompt area (at or below prompt_start_line), modifiable is set to true
---@param buf number
function M.update_modifiable(buf)
  local state = M.buffers[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return end

  local restored = M.ensure_prompt_line(buf)

  local win = vim.fn.bufwinid(buf)

  -- If prompt line was deleted and restored, position cursor on the restored prompt line
  if restored and win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, { state.prompt_start_line, 0 })
  end

  -- If prompt is empty and no turn is active, clear modified flag
  if not state.agent_extmark_id and not (state.session and state.session.turn_active) and state.prompt_extmark_id then
    local prompt_text = M.extract_prompt(buf)
    if prompt_text == "" then
      if vim.bo[buf].modified then
        vim.bo[buf].modified = false
      end
    end
  end

  if not state.config.ui.protect_history then return end

  -- If turn is active and not waiting on a question, buffer is locked if prompt area is not restored
  if not state.active_question and ((state.session and state.session.turn_active) or state.agent_extmark_id) then
    if not state.prompt_extmark_id or not state.prompt_start_line then
      if vim.bo[buf].modifiable then
        vim.bo[buf].modifiable = false
      end
      return
    end
  end

  if win == -1 then return end

  local cur_line = vim.api.nvim_win_get_cursor(win)[1]
  local prompt_start = state.prompt_start_line or 1

  local mode = vim.fn.mode()
  local is_visual = (mode:find("^[vV\x16]") ~= nil)

  local should_be_modifiable = (cur_line >= prompt_start)

  if is_visual then
    local v_line = vim.fn.getpos("v")[2]
    local min_sel = math.min(cur_line, v_line)
    if min_sel < prompt_start then
      should_be_modifiable = false
    end
  end

  if vim.bo[buf].modifiable ~= should_be_modifiable then
    vim.bo[buf].modifiable = should_be_modifiable
  end
end

---Update the active user prompt divider line to match the largest window width and apply prompt area highlights
---@param buf number
function M.update_prompt_divider(buf)
  local state = M.buffers[buf]
  if not state or not state.prompt_start_line or not vim.api.nvim_buf_is_valid(buf) then return end

  if not state.prompt_extmark_id then
    render.clear_prompt_highlights(buf)
    return
  end

  local badge = (render.thinking_timers and render.thinking_timers[buf])
    and (render.current_thinking_badge and render.current_thinking_badge[buf] or render.get_thinking_badge(state.config))
    or nil

  state.prompt_extmark_id = render.set_divider(buf, state.prompt_start_line - 1, "user", badge, "AgyBadgeActive", true, state.prompt_extmark_id, state.config)
  render.apply_prompt_highlights(buf, state.prompt_start_line)
end

---Update the bottom prompt footer virtual text and bottom border based on stream information
---@param buf number
function M.update_footer(buf)
  local state = M.buffers[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return end

  local is_prompt_active = false
  if not state.active_question and state.prompt_extmark_id then
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, {})
    if pos and #pos >= 1 then
      is_prompt_active = true
    end
  end

  local show_footer = state.config and state.config.ui and state.config.ui.prompt_footer
  local footer_text = nil

  if show_footer then
    local info = state.stream_info or {}
    local parts = {}

    if info.status == "connecting" then
      if info.model and info.model ~= "" then
        parts[#parts + 1] = info.model
      end
      parts[#parts + 1] = "Connecting to Antigravity..."
    else
      if info.model and info.model ~= "" then
        parts[#parts + 1] = info.model
      end

      if info.tools_count then
        local tool_str = info.tools_count .. " tools"
        if info.permission_mode and info.permission_mode ~= "" then
          tool_str = tool_str .. " • " .. info.permission_mode
        end
        parts[#parts + 1] = tool_str
      elseif info.permission_mode and info.permission_mode ~= "" then
        parts[#parts + 1] = info.permission_mode
      end

      if info.total_tokens and info.total_tokens > 0 then
        local stat_str = utils.format_tokens(info.total_tokens)
        if info.duration_seconds and info.duration_seconds > 0 then
          stat_str = stat_str .. " • " .. utils.format_duration(info.duration_seconds)
        end
        parts[#parts + 1] = stat_str
      elseif info.duration_seconds and info.duration_seconds > 0 then
        parts[#parts + 1] = utils.format_duration(info.duration_seconds)
      end

      if info.status == "question" then
        parts[#parts + 1] = "❓ [Awaiting answer - press <CR> to select, :w to submit]"
      elseif info.status and info.status:sub(1, 5) == "tool:" then
        parts[#parts + 1] = "[Running " .. info.status:sub(6) .. "...]"
      elseif info.status == "generating" then
        parts[#parts + 1] = "[Generating...]"
      end
    end

    footer_text = (#parts > 0) and table.concat(parts, "  │  ") or "Antigravity Ready"
  end

  state.footer_extmark_id = render.set_prompt_footer(buf, footer_text, state.footer_extmark_id, is_prompt_active, state.config)
  if state.follow_bottom then
    local wins = vim.fn.win_findbuf(buf)
    for _, win in ipairs(wins) do
      render.ensure_bottom_visible(win, buf)
    end
  end
end

---Flush any queued streaming text deltas to the buffer and trigger a live screen redraw
---@param buf number
---@param is_final? boolean
function M.flush_stream_delta(buf, is_final)
  local state = M.buffers[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return end

  if state.stream_flush_timer then
    pcall(function()
      state.stream_flush_timer:stop()
      if not state.stream_flush_timer:is_closing() then
        state.stream_flush_timer:close()
      end
    end)
    state.stream_flush_timer = nil
  end

  local delta = state.pending_text_delta
  state.pending_text_delta = nil

  if (delta and delta ~= "") or is_final then
    state.last_stream_render_time = vim.uv.hrtime() / 1e6
    M.with_modifiable(buf, function()
      render.append_text_delta(buf, delta or "", state.config, is_final)
      M.ensure_prompt_line(buf)
      if state.follow_bottom then
        render.scroll_to_bottom(buf, true)
      end
      M.update_footer(buf)
    end)
    if vim.fn.bufwinid(buf) ~= -1 then
      pcall(vim.cmd, "redraw")
    end
  end
end

---Queue an incoming streaming delta and flush either immediately or via high-frequency throttle
---@param buf number
---@param delta string
function M.queue_stream_delta(buf, delta)
  local state = M.buffers[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return end
  if not delta or delta == "" then return end

  if state.stream_info.status ~= "generating" then
    state.stream_info.status = "generating"
    M.update_footer(buf)
  end

  state.pending_text_delta = (state.pending_text_delta or "") .. delta

  local now = vim.uv.hrtime() / 1e6
  local elapsed = state.last_stream_render_time and (now - state.last_stream_render_time) or 9999

  -- If sufficient time has elapsed since the last render, flush immediately
  -- for zero latency on initial chunks or slow streams
  if elapsed >= 30 and not state.stream_flush_timer then
    M.flush_stream_delta(buf, false)
    return
  end

  -- If rapid deltas are arriving and a timer is not already ticking, schedule a flush
  if not state.stream_flush_timer then
    local timer = (vim.uv and vim.uv.new_timer) and vim.uv.new_timer() or vim.loop.new_timer()
    state.stream_flush_timer = timer
    local wait_ms = math.max(1, math.floor(30 - elapsed))
    timer:start(wait_ms, 0, vim.schedule_wrap(function()
      state.stream_flush_timer = nil
      M.flush_stream_delta(buf, false)
    end))
  end
end

---Extract prompt text from the active user prompt section at the bottom of the buffer
---@param buf number
---@return string prompt_text
---@return number prompt_start_line 1-indexed line where prompt starts
function M.extract_prompt(buf)
  local state = M.buffers[buf]
  if state and state.prompt_extmark_id and vim.api.nvim_buf_is_valid(buf) then
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, {})
    if pos and #pos >= 1 then
      state.prompt_start_line = pos[1] + 1
    end
  end
  local prompt_start = state and state.prompt_start_line or 1
  local line_count = vim.api.nvim_buf_line_count(buf)

  local prompt_lines = vim.api.nvim_buf_get_lines(buf, prompt_start - 1, line_count, false)
  local full_text = table.concat(prompt_lines, "\n")
  return utils.trim(full_text), prompt_start
end

---Scan prompt text for @ mentions, resolve them via mention providers,
---and append <ADDITIONAL_METADATA> block if matches exist.
---@param prompt_text string
---@param workspaces? string[]
---@return string full_prompt
function M.resolve_prompt_mentions(prompt_text, workspaces)
  if not prompt_text or prompt_text == "" or not prompt_text:find("@") then
    return prompt_text
  end

  local mention_mod = require("agy.mention")
  local ctx = mention_mod.build_context(workspaces)
  return mention_mod.resolve(prompt_text, ctx)
end

---Setup buffer-local autocommands and options
---@param buf number
---@param conversation_id string
function M._setup_buffer(buf, conversation_id)
  local cfg = config_mod.get()

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "agy"
  pcall(vim.treesitter.start, buf, "markdown")
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"

  pcall(function()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.wo[win].wrap = cfg.ui.wrap
      vim.wo[win].linebreak = cfg.ui.linebreak
      vim.wo[win].conceallevel = (cfg.ui and cfg.ui.conceallevel ~= nil) and cfg.ui.conceallevel or 0
      vim.wo[win].concealcursor = ""
    else
      vim.wo.wrap = cfg.ui.wrap
      vim.wo.linebreak = cfg.ui.linebreak
      vim.wo.conceallevel = (cfg.ui and cfg.ui.conceallevel ~= nil) and cfg.ui.conceallevel or 0
      vim.wo.concealcursor = ""
    end
  end)

  local buf_group = vim.api.nvim_create_augroup("AgyBuffer_" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = buf_group,
    buffer = buf,
    callback = function()
      local wins = vim.fn.win_findbuf(buf)
      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
          vim.wo[win].wrap = cfg.ui.wrap
          vim.wo[win].linebreak = cfg.ui.linebreak
          vim.wo[win].conceallevel = (cfg.ui and cfg.ui.conceallevel ~= nil) and cfg.ui.conceallevel or 0
          vim.wo[win].concealcursor = ""
        end
      end
    end,
  })

  -- Keymaps
  if cfg.keymaps.submit and cfg.keymaps.submit ~= "" then
    vim.keymap.set({ "n", "i" }, cfg.keymaps.submit, "<cmd>write<CR>", {
      buffer = buf,
      silent = true,
      desc = "Submit prompt to Antigravity",
    })
  end

  if cfg.keymaps.stop and cfg.keymaps.stop ~= "" then
    vim.keymap.set("n", cfg.keymaps.stop, function()
      M.stop_turn(buf)
    end, {
      buffer = buf,
      silent = true,
      desc = "Stop current Antigravity turn",
    })
  end

  -- Inspect markdown link with K (LSP-style floating preview)
  vim.keymap.set("n", "K", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local link = require("agy.markdown").get_link_at(buf, cursor[1], cursor[2])
    if link then
      require("agy.markdown").show_link_hover(buf, link, cfg)
    elseif vim.lsp.get_clients and #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/hover" }) > 0 then
      vim.lsp.buf.hover()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("K", true, false, true), "n", false)
    end
  end, {
    buffer = buf,
    silent = true,
    desc = "Inspect markdown link or LSP hover",
  })

  -- Open link with gd
  vim.keymap.set("n", "gd", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local link = require("agy.markdown").get_link_at(buf, cursor[1], cursor[2])
    if link then
      require("agy.markdown").open_link(link.url)
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gd", true, false, true), "n", false)
    end
  end, {
    buffer = buf,
    silent = true,
    desc = "Open link under cursor or go to definition",
  })

  -- Up navigation to agy:// home
  vim.keymap.set("n", "-", function()
    vim.cmd("edit agy://")
  end, {
    buffer = buf,
    silent = true,
    desc = "Navigate up to agy:// home",
  })

  local toggle_key = cfg.keymaps.toggle_tool or "<CR>"
  vim.keymap.set("n", toggle_key, function()
    local state = M.buffers[buf]
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]

    if state and state.active_question then
      local q_handled = render.toggle_question_option(buf, cur_line, state.active_question)
      if q_handled then return end
    end

    if state and state.prompt_queue and #state.prompt_queue > 0 then
      local queue_handled = M.unqueue_prompt_at_cursor(buf, cur_line)
      if queue_handled then return end
    end

    local handled = M.toggle_tool_at_cursor(buf, vim.api.nvim_get_current_win())
    if not handled then
      local prompt_start = state and state.prompt_start_line or 1
      if cur_line >= prompt_start then
        local line_text = vim.api.nvim_get_current_line()
        local trimmed = utils.trim(line_text)
        local first_token = trimmed:match("^(%S+)")
        if first_token and first_token:match("^/") and completion.is_control(first_token) then
          M.handle_write(buf)
          return
        end
      end

      if toggle_key == "<CR>" then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
      end
    end
  end, {
    buffer = buf,
    silent = true,
    desc = "Toggle question option, tool output, or execute control command at cursor",
  })

  completion.setup_buffer(buf)

  -- Cursor tracking to toggle modifiable dynamically and keep footer anchored
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged", "BufEnter", "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      local state = M.buffers[buf]
      if state then
        M.ensure_prompt_line(buf)

        local win = vim.api.nvim_get_current_win()
        if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
          win = vim.fn.bufwinid(buf)
        end
        if win ~= -1 then
          local cur_line = vim.api.nvim_win_get_cursor(win)[1]
          local line_count = vim.api.nvim_buf_line_count(buf)

          if state.config and state.config.ui and state.config.ui.auto_scroll == false then
            state.follow_bottom = false
          elseif state.prompt_extmark_id and state.prompt_start_line then
            if cur_line < state.prompt_start_line then
              state.follow_bottom = false
            else
              state.follow_bottom = true
            end
          else
            if cur_line < line_count then
              state.follow_bottom = false
            else
              state.follow_bottom = true
            end
          end
        end
      end
      M.update_modifiable(buf)
      M.update_prompt_divider(buf)
      M.update_footer(buf)

      local cur_win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win) == buf then
        render.ensure_bottom_visible(cur_win, buf)
      end
    end,
  })

  -- Protect visual modifications that span into history
  if cfg.ui.protect_history then
    local visual_edit_keys = {
      "d", "D", "x", "X", "c", "C", "s", "S", "p", "P",
      "<Del>", "<BS>", "r", "J", ">", "<", "~",
      "u", "U", "g~", "gu", "gU"
    }
    for _, key in ipairs(visual_edit_keys) do
      vim.keymap.set("x", key, function()
        local v_pos = vim.fn.getpos("v")[2]
        local cur_pos = vim.api.nvim_win_get_cursor(0)[1]
        local state = M.buffers[buf]
        local prompt_start = state and state.prompt_start_line or 1
        local min_sel = math.min(v_pos, cur_pos)
        local max_sel = math.max(v_pos, cur_pos)
        local line_count = vim.api.nvim_buf_line_count(buf)

        if min_sel < prompt_start then
          vim.notify("[agy.nvim] Cannot modify: selection includes protected conversation history.", vim.log.levels.WARN)
          return "\27"
        end

        -- If deleting or changing the entire prompt area, preserve 1 empty prompt line
        if min_sel == prompt_start and max_sel >= line_count then
          if key == "d" or key == "D" or key == "x" or key == "X" or key == "<Del>" or key == "<BS>" then
            return "c\27"
          elseif key == "c" or key == "C" or key == "s" or key == "S" then
            return "c"
          end
        end

        return key
      end, { buffer = buf, expr = true, silent = true, desc = "Protected visual edit" })
    end

    -- Normal mode line-delete / change keys on single remaining prompt line
    local line_edit_keys = { "dd", "cc", "D", "C", "S" }
    for _, lk in ipairs(line_edit_keys) do
      vim.keymap.set("n", lk, function()
        local cur_pos = vim.api.nvim_win_get_cursor(0)
        local cur_line = cur_pos[1]
        local state = M.buffers[buf]
        local prompt_start = state and state.prompt_start_line or 1
        local line_count = vim.api.nvim_buf_line_count(buf)

        if cur_line == prompt_start and line_count == prompt_start then
          if lk == "dd" then
            return "cc\27"
          elseif lk == "cc" or lk == "C" or lk == "S" then
            return "cc"
          elseif lk == "D" then
            return "0D"
          end
        end
        return lk
      end, { buffer = buf, expr = true, silent = true, desc = "Protected prompt line delete" })
    end

    -- Guard against stray operator motions (e.g. dgg) that modify history lines
    vim.api.nvim_buf_attach(buf, false, {
      on_bytes = function(_, _, _, start_row)
        local state = M.buffers[buf]
        if not state or M._internal_guard then return end
        local prompt_start = state.prompt_start_line or 1
        if start_row < (prompt_start - 1) then
          vim.schedule(function()
            if M._internal_guard then return end
            M.with_modifiable(buf, function()
              vim.cmd("silent! undo")
            end)
            M.update_modifiable(buf)
            vim.notify("[agy.nvim] Action cancelled: conversation history is protected.", vim.log.levels.WARN)
          end)
        end
      end,
    })
  end

  -- BufWriteCmd autocommand for this buffer
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = buf_group,
    buffer = buf,
    callback = function()
      M.handle_write(buf)
    end,
  })

  -- Cleanup on buffer wipeout / delete
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = buf_group,
    buffer = buf,
    callback = function()
      M.cleanup_buffer(buf)
    end,
  })
end

---Re-engage bottom scrolling and ensure viewport visibility if disengaged during background task wait
---@param buf number
---@param state table
function M.handle_post_task_bottom_visibility(buf, state)
  if not state then return end
  if state.reengage_follow_bottom then
    state.reengage_follow_bottom = nil
    if state.config and state.config.ui and state.config.ui.auto_scroll == false then
      vim.notify("[agy.nvim] Background task finished: new agent output received", vim.log.levels.INFO)
      return
    end

    local win = vim.fn.bufwinid(buf)
    local wins = vim.fn.win_findbuf(buf)
    if win == -1 and wins and #wins > 0 then
      win = wins[1]
    end

    local prompt_start = state.prompt_start_line or vim.api.nvim_buf_line_count(buf)

    if win ~= -1 then
      local cur_line = vim.api.nvim_win_get_cursor(win)[1]
      if cur_line < prompt_start then
        vim.notify("[agy.nvim] Background task finished: new agent output received at bottom", vim.log.levels.INFO)
      else
        state.follow_bottom = true
        render.scroll_to_bottom(buf, true)
      end
    else
      state.follow_bottom = true
    end

    if wins then
      for _, w in ipairs(wins) do
        render.ensure_bottom_visible(w, buf)
      end
    end
  end
end

---Reconcile running background tasks by reading outcomes from disk transcript and task logs
---@param buf number
---@param state table
---@param conv_id? string
function M.reconcile_background_tasks(buf, state, conv_id)
  assert(buf and vim.api.nvim_buf_is_valid(buf), "reconcile_background_tasks: valid buffer required")
  assert(state, "reconcile_background_tasks: buffer state required")
  assert(type(state.tool_calls) == "table", "reconcile_background_tasks: state.tool_calls table required")

  local cid = conv_id or state.conversation_id
  if not cid or cid == "" or cid == "new" then
    return
  end

  local has_running_tasks = false
  for _, tc in ipairs(state.tool_calls) do
    if tc.is_background_task and tc.task_status == "running" then
      has_running_tasks = true
      break
    end
  end

  if not has_running_tasks then
    return
  end

  local tasks_mod = require("agy.tasks")
  local transcript_mod = require("agy.transcript")
  assert(state.config, "reconcile_background_tasks: state.config required")
  local app_dir = state.config.app_data_dir
  assert(app_dir and app_dir ~= "", "reconcile_background_tasks: config.app_data_dir required")

  local steps = transcript_mod.read_transcript(cid, app_dir)
  local outcomes = tasks_mod.collect_task_outcomes(steps)

  for _, tc in ipairs(state.tool_calls) do
    if tc.is_background_task and tc.task_status == "running" then
      tc.buf = buf
      local outcome = outcomes[tc.task_id]
      if not outcome and tc.short_id then
        outcome = outcomes[tc.short_id]
      end
      if not outcome and tc.log_path and vim.fn.filereadable(tc.log_path) == 1 then
        local ok, lines = pcall(vim.fn.readfile, tc.log_path)
        if ok and lines and #lines > 0 then
          local last_chunk = table.concat(lines, "\n", math.max(1, #lines - 20))
          local code = tasks_mod.parse_log_exit_code(last_chunk)
          if code ~= nil then
            local status = (code == 0) and "success" or "failed"
            outcome = { status = status, exit_code = code, task_id = tc.task_id, short_id = tc.short_id }
          end
        end
      end

      if outcome then
        if outcome.duration_seconds and not tc.duration_seconds then
          tc.duration_seconds = outcome.duration_seconds
        elseif not tc.duration_seconds and tc.start_time then
          tc.duration_seconds = math.max(0, (vim.uv.hrtime() - tc.start_time) / 1e9)
        end
        M.with_modifiable(buf, function()
          render.update_task_status(buf, tc, outcome.status, outcome.exit_code, state.config)
        end)
        state.had_background_task = true
        state.reengage_follow_bottom = true
      end
    end
  end
end

---Check transcript file for newly recorded agent thoughts before tool calls and render them into the buffer
---@param buf number
function M.check_and_render_pending_thoughts(buf)
  local state = M.buffers[buf]
  if not state or not state.conversation_id then return end
  if not state.config or not state.config.ui or state.config.ui.show_thoughts == false then return end

  -- NEVER render thoughts once output text generation has begun!
  if state.active_agent_started_output then return end

  M.handle_post_task_bottom_visibility(buf, state)

  state.rendered_thinking = state.rendered_thinking or {}

  local cid = state.conversation_id
  local app_data = state.config.app_data_dir
  local steps = transcript_mod.read_transcript(cid, app_data)
  if not steps or #steps == 0 then return end

  for idx, step in ipairs(steps) do
    if step.type == "PLANNER_RESPONSE" and step.thinking and step.thinking ~= "" then
      local key = (step.step_index or tostring(idx)) .. ":" .. step.thinking
      if not state.rendered_thinking[key] then
        state.rendered_thinking[key] = true

        local dur = step.duration_seconds
        if not dur and state.last_thought_start_time then
          dur = (vim.uv.hrtime() - state.last_thought_start_time) / 1e9
          if dur < 0.05 then dur = nil end
        end

        M.with_modifiable(buf, function()
          local tc_rec = render.append_thought_block(buf, step.thinking, dur, state.config)
          tc_rec.id = #state.tool_calls + 1
          table.insert(state.tool_calls, tc_rec)
          M.ensure_prompt_line(buf)
          if state.follow_bottom then
            render.scroll_to_bottom(buf, true)
          end
        end)
      end
    end
  end
end

---Mark all thinking steps in current transcript as acknowledged without modifying buffer lines
---@param buf number
---@param state? table
function M.mark_transcript_thoughts_rendered(buf, state)
  local s = state or M.buffers[buf]
  if not s or not s.conversation_id then return end

  s.rendered_thinking = s.rendered_thinking or {}

  local cid = s.conversation_id
  local app_data = s.config and s.config.app_data_dir
  local steps = transcript_mod.read_transcript(cid, app_data)
  if not steps or #steps == 0 then return end

  for idx, step in ipairs(steps) do
    if step.type == "PLANNER_RESPONSE" and step.thinking and step.thinking ~= "" then
      local key = (step.step_index or tostring(idx)) .. ":" .. step.thinking
      s.rendered_thinking[key] = true
    end
  end
end

---Check if tool call parameters indicate an artifact requesting feedback
---@param tool_name? string
---@param params? table
---@return boolean is_feedback, string? filename, string? summary
local function check_artifact_feedback_request(tool_name, params)
  if tool_name ~= "write_to_file" or type(params) ~= "table" then
    return false
  end
  local meta = params.ArtifactMetadata or params.artifact_metadata or params.artifactMetadata
  if type(meta) == "string" then
    meta = utils.json_decode(meta)
  end
  if type(meta) == "table" then
    local req = (meta.RequestFeedback == true or meta.requestFeedback == true)
    if req then
      local target = params.TargetFile or params.target_file or params.targetFile or "artifact"
      local fname = vim.fs.basename(target)
      return true, fname, meta.Summary or meta.summary
    end
  end
  return false
end

---Intercept ask_question tool call by cancelling the in-flight turn and displaying the question UI
---@param buf number
---@param state table
---@param q_list table[]
function M.intercept_ask_question(buf, state, q_list)
  if state.active_question then return end

  -- Stop in-flight turn immediately to prevent print-mode auto-skipping or default continuation
  if state.session and state.session.turn_active then
    state.session:stop()
  end

  -- Discard pending stream deltas from cancelled turn
  state.stream_delta_queue = {}
  if state.stream_flush_timer then
    pcall(function() state.stream_flush_timer:stop() end)
  end

  -- Render thoughts prior to question
  if not state.active_agent_started_output then
    M.check_and_render_pending_thoughts(buf)
  else
    M.mark_transcript_thoughts_rendered(buf, state)
  end

  state.stream_info.status = "question"
  M.update_footer(buf)

  M.with_modifiable(buf, function()
    local q_state = render.render_question_block(buf, q_list, state.config)
    state.active_question = q_state
    state.prompt_start_line = q_state.first_option_line

    local win = vim.fn.bufwinid(buf)
    if win ~= -1 and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { q_state.first_option_line, 2 })
    end
  end)

  vim.bo[buf].modifiable = true
  vim.bo[buf].modified = false
end

---Check if recent transcript contains an ask_question tool call to intercept
---@param buf number
---@param state table
---@return boolean intercepted
function M.check_and_intercept_ask_question(buf, state)
  if state.active_question then return true end
  if not state.session or not state.session.turn_active then return false end
  if not state.conversation_id or state.conversation_id == "" or state.conversation_id == "new" then return false end

  local cid = state.conversation_id
  local app_data = state.config and state.config.app_data_dir
  local steps = transcript_mod.read_transcript(cid, app_data)
  if not steps or #steps == 0 then return false end

  for i = #steps, 1, -1 do
    local step = steps[i]
    if step.type == "PLANNER_RESPONSE" and step.tool_calls then
      for _, tc in ipairs(step.tool_calls) do
        if tc.name == "ask_question" then
          local q_list = render.parse_question_params(tc.args)
          if #q_list > 0 then
            M.intercept_ask_question(buf, state, q_list)
            return true
          end
        end
      end
      break
    elseif step.type == "USER_INPUT" then
      break
    end
  end
  return false
end

---Record a local control command and its result into the buffer conversation history
---@param buf number
---@param command_text string
---@param result_text? string
function M.record_command_history(buf, command_text, result_text)
  local state = M.buffers[buf]
  if not state then return end

  completion.close()

  M.with_modifiable(buf, function()
    local next_line, next_ext_id = render.render_command_entry(
      buf,
      command_text,
      result_text,
      state.config,
      state.prompt_start_line,
      state.prompt_extmark_id
    )
    state.prompt_start_line = next_line
    state.prompt_extmark_id = next_ext_id
  end)

  local win = vim.fn.bufwinid(buf)
  if win ~= -1 and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { state.prompt_start_line, 0 })
  end

  M.update_modifiable(buf)
  M.update_footer(buf)
end

---Set or switch active model for a buffer session
---@param buf number
---@param model_id string
---@param record_in_history? boolean Whether to append a command entry to conversation history
function M.set_model(buf, model_id, record_in_history)
  local state = M.buffers[buf]
  if not state then return end

  model_id = completion.resolve_model(model_id)

  if state.session then
    state.session:set_model(model_id)
  end
  if not state.stream_info then
    state.stream_info = {}
  end
  state.stream_info.model = model_id

  if record_in_history then
    M.record_command_history(buf, "/model " .. model_id, "⚡ Switched model to " .. model_id)
  end

  M.update_footer(buf)
  vim.notify("[agy.nvim] Switched model to " .. model_id, vim.log.levels.INFO)
end

---Set or switch active agent mode for a buffer session
---@param buf number
---@param mode_name? string
function M.set_mode(buf, mode_name)
  local state = M.buffers[buf]
  if not state then return end

  if mode_name == "default" then mode_name = nil end

  if state.session then
    state.session:set_mode(mode_name)
  end
  if not state.stream_info then
    state.stream_info = {}
  end
  state.stream_info.permission_mode = mode_name
  M.update_footer(buf)
  vim.notify("[agy.nvim] Switched mode to " .. (mode_name or "default"), vim.log.levels.INFO)
end

---Set or switch active reasoning effort for a buffer session
---@param buf number
---@param effort_level? string
function M.set_effort(buf, effort_level)
  local state = M.buffers[buf]
  if not state then return end

  if state.session then
    state.session:set_effort(effort_level)
  end
  if not state.stream_info then
    state.stream_info = {}
  end
  state.stream_info.effort = effort_level
  M.update_footer(buf)
  vim.notify("[agy.nvim] Switched reasoning effort to " .. (effort_level or "default"), vim.log.levels.INFO)
end

---Display a formatted informational floating popup window
---@param title string
---Display informational text in the bottom panel below the prompt
---@param title string
---@param lines string[]
---@param caller_buf? number
---@return number win, number buf
function M.show_info_float(title, lines, caller_buf)
  caller_buf = (caller_buf and vim.api.nvim_buf_is_valid(caller_buf)) and caller_buf or vim.api.nvim_get_current_buf()
  local target_win = vim.fn.bufwinid(caller_buf)
  if target_win == -1 or not vim.api.nvim_win_is_valid(target_win) then
    target_win = vim.api.nvim_get_current_win()
  end
  local width = vim.api.nvim_win_get_width(target_win)

  local panel_mod = require("agy.panel")
  local state = M.buffers[caller_buf]
  local info = state and state.stream_info or {}
  local model_str = info.model or (state and state.session and state.session.model) or "default"
  local effort_str = (state and state.session and state.session.effort) or "high"

  -- Add title and footer if not already present
  local content = {}
  if lines[1] and not lines[1]:find(title, 1, true) then
    table.insert(content, "ℹ️ " .. title)
    table.insert(content, "")
  end
  for _, l in ipairs(lines) do
    table.insert(content, l)
  end
  table.insert(content, "")
  local nav_left = (width >= 75)
      and "↑/↓ Scroll · pgup/pgdown Page · ctrl+end Bottom · ctrl+home Top · esc Close"
      or "↑/↓ Scroll · pgup/down Page · esc Close"
  local footer_str = panel_mod.format_footer(nav_left, model_str .. " · " .. effort_str, width)
  table.insert(content, footer_str)

  local win, buf = panel_mod.open({
    target_win = target_win,
    target_buf = caller_buf,
    lines = content,
    syntax = "markdown",
    filetype = "markdown",
    max_height = 24,
    apply_highlights = function(pbuf)
      local ns = vim.api.nvim_create_namespace("agy_info_panel")
      panel_mod.apply_footer_highlights(pbuf, ns, #content - 1, footer_str)
    end,
  })

  return win, buf
end

---Handle BufWriteCmd when user runs :w in agy:// buffer
---@param buf number
function M.handle_write(buf)
  local state = M.buffers[buf]
  if not state then return end

  if state.is_home then
    vim.notify("[agy.nvim] Home buffer is read-only. Press <CR> to open a session.", vim.log.levels.INFO)
    vim.bo[buf].modified = false
    return
  end

  if state.is_artifact then
    local artifacts_mod = require("agy.artifacts")
    artifacts_mod.submit_review(buf, state.conversation_id, state.artifact_filename)
    return
  end

  if state.active_question then
    local payload, has_answer = render.extract_question_answer(buf, state.active_question)
    if not has_answer then
      vim.notify("[agy.nvim] Please select an option with <CR> or enter a write-in response before saving.", vim.log.levels.WARN)
      vim.bo[buf].modified = false
      return
    end

    state.follow_bottom = (state.config and state.config.ui and state.config.ui.auto_scroll ~= false)
    state.active_agent_started_output = false
    state.agent_extmark_id = nil
    state.agent_start_line = nil
    state.last_thought_start_time = vim.uv.hrtime()
    render.finalize_question_block(buf, state.active_question, state.config)
    state.active_question = nil

    state.stream_info.status = "thinking"
    local workspaces = (state.session and state.session.workspaces and #state.session.workspaces > 0)
        and state.session.workspaces
        or { (state.session and state.session.cwd) or vim.fn.getcwd() }
    local resolved_payload = M.resolve_prompt_mentions(payload, workspaces)

    local sent = state.session:send_prompt(resolved_payload)
    if not sent then
      state.stream_info.status = "ready"
      M.with_modifiable(buf, function()
        local next_line, prompt_extmark_id = render.render_error(buf, "Failed to send response: agy session process is not active", state.config)
        state.prompt_start_line = next_line
        state.prompt_extmark_id = prompt_extmark_id
      end)
      M.update_footer(buf)
      return
    end
    M.update_modifiable(buf)
    vim.bo[buf].modified = false
    return
  end

  if state.session and state.session.turn_active then
    local prompt_text = M.extract_prompt(buf)
    if prompt_text == "" then
      vim.notify("[agy.nvim] Prompt is empty. Type your message below the prompt divider and press " .. (state.config.keymaps.submit or "<C-s>") .. " to queue.", vim.log.levels.INFO)
      vim.bo[buf].modified = false
      return
    end

    M.queue_prompt(buf, prompt_text)
    return
  end

  local prompt_text = M.extract_prompt(buf)
  if prompt_text == "" then
    vim.notify("[agy.nvim] Prompt is empty. Type your message below the User divider and run :w", vim.log.levels.INFO)
    vim.bo[buf].modified = false
    return
  end

  local trimmed = prompt_text:match("^%s*(.*)$")
  local first_token = trimmed:match("^(%S+)")

  -- Helper to clear the prompt input area in the buffer and mark clean
  local function clear_prompt_and_clean()
    vim.cmd("stopinsert")
    M.with_modifiable(buf, function()
      vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, { "" })
    end)
    vim.bo[buf].modified = false
    completion.close()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { state.prompt_start_line, 0 })
    end
  end

  -- Intercept and automatically process CONTROL slash commands locally
  -- Control commands must ONLY execute locally and never be sent to stream-json print mode
  if first_token and first_token:match("^/") and completion.is_control(first_token) then
    -- 1. /model: switch model or open interactive picker
    if first_token == "/model" then
      local model_arg = trimmed:match("^/model%s+(%S+)")
      if not model_arg or model_arg == "" then
        clear_prompt_and_clean()
        require("agy.picker").model(buf)
        return
      end

      local resolved_model = completion.resolve_model(model_arg)
      M.set_model(buf, resolved_model, false)
      M.record_command_history(buf, "/model " .. resolved_model, "⚡ Switched model to " .. resolved_model)
      return

    -- 2. /mode: switch agent mode (accept-edits, plan, default)
    elseif first_token == "/mode" then
      local mode_arg = trimmed:match("^/mode%s+(%S+)")
      if not mode_arg or mode_arg == "" then
        local cur = (state.session and state.session.mode) or "default"
        M.record_command_history(buf, "/mode", "Current agent mode: " .. cur)
        vim.notify("[agy.nvim] Current agent mode: " .. cur, vim.log.levels.INFO)
        return
      end
      M.set_mode(buf, mode_arg)
      M.record_command_history(buf, "/mode " .. mode_arg, "⚡ Switched agent mode to " .. mode_arg)
      return

    -- 3. /effort: switch reasoning effort (low, medium, high)
    elseif first_token == "/effort" then
      local effort_arg = trimmed:match("^/effort%s+(%S+)")
      if not effort_arg or effort_arg == "" then
        local cur = (state.session and state.session.effort) or "default"
        M.record_command_history(buf, "/effort", "Current reasoning effort: " .. cur)
        vim.notify("[agy.nvim] Current reasoning effort: " .. cur, vim.log.levels.INFO)
        return
      end
      M.set_effort(buf, effort_arg)
      M.record_command_history(buf, "/effort " .. effort_arg, "⚡ Switched reasoning effort to " .. effort_arg)
      return

    -- 4. /add-dir: add workspace directory
    elseif first_token == "/add-dir" then
      local dir = trimmed:match("^/add%-dir%s+(.+)$")
      if not dir or dir:match("^%s*$") then
        vim.notify("[agy.nvim] Usage: /add-dir <directory>", vim.log.levels.WARN)
        return
      end
      dir = dir:gsub('^["\']', ''):gsub('["\']$', '')
      local full_dir = vim.fs.normalize(vim.fn.expand(dir))
      table.insert(state.session.workspaces, full_dir)
      state.session:start()
      M.record_command_history(buf, "/add-dir " .. dir, "✓ Added workspace: " .. full_dir)
      vim.notify("[agy.nvim] Added workspace: " .. full_dir, vim.log.levels.INFO)
      return

    -- 5. /drop: drop workspace directory
    elseif first_token == "/drop" then
      local dir = trimmed:match("^/drop%s+(.+)$")
      if not dir or dir:match("^%s*$") then
        vim.notify("[agy.nvim] Usage: /drop <directory>", vim.log.levels.WARN)
        return
      end
      dir = dir:gsub('^["\']', ''):gsub('["\']$', '')
      local full_dir = vim.fs.normalize(vim.fn.expand(dir))
      local new_ws = {}
      for _, w in ipairs(state.session.workspaces or {}) do
        if vim.fs.normalize(w) ~= full_dir then
          table.insert(new_ws, w)
        end
      end
      state.session.workspaces = new_ws
      state.session:start()
      M.record_command_history(buf, "/drop " .. dir, "✓ Dropped workspace: " .. full_dir)
      vim.notify("[agy.nvim] Dropped workspace: " .. full_dir, vim.log.levels.INFO)
      return

    -- 6. /workspace: list or add workspace
    elseif first_token == "/workspace" then
      local dir = trimmed:match("^/workspace%s+(.+)$")
      if dir and not dir:match("^%s*$") then
        dir = dir:gsub('^["\']', ''):gsub('["\']$', '')
        local full_dir = vim.fs.normalize(vim.fn.expand(dir))
        table.insert(state.session.workspaces, full_dir)
        state.session:start()
        M.record_command_history(buf, "/workspace " .. dir, "✓ Added workspace: " .. full_dir)
        vim.notify("[agy.nvim] Added workspace: " .. full_dir, vim.log.levels.INFO)
        return
      else
        local ws_list = state.session.workspaces or {}
        local msg = #ws_list > 0 and table.concat(ws_list, ", ") or "None"
        M.record_command_history(buf, "/workspace", "Active workspaces: " .. msg)
        vim.notify("[agy.nvim] Active workspaces: " .. msg, vim.log.levels.INFO)
        return
      end

    -- 7. /clear or /new: fresh conversation session
    elseif first_token == "/clear" or first_token == "/new" then
      clear_prompt_and_clean()
      require("agy").new()
      return

    -- 8. /resume: resume conversation
    elseif first_token == "/resume" then
      local cid = trimmed:match("^/resume%s*(%S*)")
      clear_prompt_and_clean()
      if cid and cid ~= "" then
        require("agy").open(cid)
      else
        require("agy.picker").resume()
      end
      return

    -- 9. /diff: open git diff of workspace changes
    elseif first_token == "/diff" then
      clear_prompt_and_clean()
      require("agy").diff()
      return

    -- 10. /undo: undo changes
    elseif first_token == "/undo" then
      clear_prompt_and_clean()
      vim.cmd("silent! undo")
      vim.notify("[agy.nvim] Undo executed.", vim.log.levels.INFO)
      return

    -- 11. /redo: redo changes
    elseif first_token == "/redo" then
      clear_prompt_and_clean()
      vim.cmd("silent! redo")
      vim.notify("[agy.nvim] Redo executed.", vim.log.levels.INFO)
      return

    -- 12. /exit or /quit: close buffer
    elseif first_token == "/exit" or first_token == "/quit" then
      completion.close()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      return

    -- 13. /context: interactive Context Breakdown matching native agy
    elseif first_token == "/context" then
      clear_prompt_and_clean()
      require("agy.context").open(buf)
      return

    -- 14. /settings: view configuration settings
    elseif first_token == "/settings" then
      local cfg = state.config or config_mod.get()
      local cur_model = (state.stream_info and state.stream_info.model) or completion.get_default_model(cfg.app_data_dir, cfg.default_model)
      local lines = {
        "# Antigravity Configuration",
        "",
        "- **CLI Command**: `" .. (cfg.agy_cmd or "agy") .. "`",
        "- **App Data Directory**: `" .. (cfg.app_data_dir or "") .. "`",
        "- **Active Model**: `" .. cur_model .. "`",
        "",
        "### UI Settings:",
        "- **Wrap**: " .. tostring(cfg.ui and cfg.ui.wrap),
        "- **Linebreak**: " .. tostring(cfg.ui and cfg.ui.linebreak),
        "- **Conceallevel**: " .. tostring(cfg.ui and cfg.ui.conceallevel),
        "- **Show Thoughts**: " .. tostring(cfg.ui and cfg.ui.show_thoughts),
        "- **Prompt Footer**: " .. tostring(cfg.ui and cfg.ui.prompt_footer),
        "",
        "### Keymaps:",
        "- **Submit**: `" .. (cfg.keymaps and cfg.keymaps.submit or "<leader>aa") .. "`",
        "- **Stop**: `" .. (cfg.keymaps and cfg.keymaps.stop or "<C-c>") .. "`",
        "- **Toggle Tool / Option**: `" .. (cfg.keymaps and cfg.keymaps.toggle_tool or "<CR>") .. "`",
      }
      clear_prompt_and_clean()
      M.show_info_float("Antigravity Settings", lines, buf)
      return

    -- 15. /status: view session and connection status
    elseif first_token == "/status" then
      local info = state.stream_info or {}
      local lines = {
        "# Antigravity Session Status",
        "",
        "- **Conversation**: `" .. (state.conversation_id or "new") .. "`",
        "- **Process**: " .. ((state.session and state.session.is_active) and "Running (Active)" or "Idle / Standby"),
        "- **Turn In-Flight**: " .. tostring(state.session and state.session.turn_active),
        "- **Active Model**: `" .. (info.model or "default") .. "`",
        "- **Stream Status**: " .. (info.status or "ready"),
        "- **Active Workspaces**: " .. #(state.session and state.session.workspaces or {}),
      }
      clear_prompt_and_clean()
      M.show_info_float("Antigravity Status", lines, buf)
      return

    -- 16. /usage or /quota or /tokens or /cost: view Models & Quota
    elseif first_token == "/usage" or first_token == "/quota" or first_token == "/tokens" or first_token == "/cost" then
      clear_prompt_and_clean()
      require("agy.quota").open(buf)
      return

    -- 17. /doctor: check system health and CLI installation
    elseif first_token == "/doctor" then
      clear_prompt_and_clean()
      local async = require("agy.async")
      async.run(function()
        local lines = {
          "# Antigravity Doctor Health Check",
          "",
        }
        local cfg = state.config or config_mod.get()
        local cmd_name = cfg.agy_cmd or "agy"
        local agy_exe = vim.fn.exepath(cmd_name)
        if agy_exe ~= "" then
          table.insert(lines, "[✓] `" .. cmd_name .. "` CLI found: `" .. agy_exe .. "`")
          local ok, ver = async.psystem({ cmd_name, "--version" }, { text = true })
          if ok and ver and ver.code == 0 then
            table.insert(lines, "[✓] `" .. cmd_name .. "` CLI version: " .. utils.trim(ver.stdout))
          end
        else
          table.insert(lines, "[✗] `" .. cmd_name .. "` executable NOT found on PATH!")
        end
        local nvim_ver = vim.version()
        table.insert(lines, string.format("[✓] Neovim version: %d.%d.%d", nvim_ver.major, nvim_ver.minor, nvim_ver.patch))
        table.insert(lines, "[✓] Current working directory: `" .. vim.fn.getcwd() .. "`")
        local app_dir = utils.get_app_data_dir(cfg.app_data_dir)
        if vim.fn.isdirectory(app_dir) == 1 then
          table.insert(lines, "[✓] App data directory accessible: `" .. app_dir .. "`")
        else
          table.insert(lines, "[!] App data directory does not exist yet: `" .. app_dir .. "`")
        end
        M.show_info_float("Antigravity Doctor", lines, buf)
      end)
      return

    -- 18. /help: show command reference
    elseif first_token == "/help" then
      local lines = {
        "# Antigravity Commands & Shortcuts",
        "",
        "### Standalone Control Commands (First-only)",
        "- `/model [id]` — Switch or pick active LLM model",
        "- `/mode [accept-edits|plan|default]` — Switch agent mode",
        "- `/effort [low|medium|high]` — Switch reasoning effort",
        "- `/add-dir <path>` — Add directory to workspace",
        "- `/drop <path>` — Drop directory from workspace",
        "- `/workspace [path]` — View or add workspace directories",
        "- `/context` — Inspect session context, memory, and workspaces",
        "- `/settings` — View active configuration and options",
        "- `/status` — View session and connection status",
        "- `/tasks` — View and manage ongoing background tasks",
        "- `/artifacts [filename]` — Review artifacts produced in session",
        "- `/usage` / `/tokens` / `/cost` — View token metrics",
        "- `/doctor` — Verify system health and dependencies",
        "- `/diff` — View git diff of changes",
        "- `/new` / `/clear` — Start a fresh conversation",
        "- `/resume [id]` — Resume past conversation",
        "- `/undo` / `/redo` — Undo or redo changes",
        "- `/exit` / `/quit` — Close session buffer",
        "",
        "### Prompt Modifiers / Directives (Chainable)",
        "- `/plan` — Deep planning, verification steps, and user alignment",
        "- `/boost` — Deep thinking, strategic planning, and verification",
        "- `/grill-me` — Interactive interview to resolve design decisions",
        "- `/goal` — Autonomous goal task",
        "- `/browser` — Web browsing and search automation",
        "- `/schedule` — Schedule timer or recurring cron job",
        "- `/learn` — Persist patterns and corrections",
        "- `/teamwork-preview` — Multi-agent collaboration",
        "",
        "### Keymaps",
        "- `:w` or `<leader>aa` — Submit prompt / answers",
        "- `<C-c>` — Stop in-flight response",
        "- `<CR>` — Toggle thought or tool call details / select options",
      }
      clear_prompt_and_clean()
      M.show_info_float("Antigravity Help", lines, buf)
      return

    -- 19. /tasks: view and manage background tasks
    elseif first_token == "/tasks" then
      clear_prompt_and_clean()
      require("agy.tasks").open(buf)
      return

    -- 20. /artifacts: view and review artifacts produced in conversation
    elseif first_token == "/artifacts" then
      local art_arg = trimmed:match("^/artifacts%s+(%S+)")
      clear_prompt_and_clean()
      local cid = state.conversation_id
      if not cid or cid == "" or cid == "new" then
        vim.notify("[agy.nvim] No active conversation session.", vim.log.levels.WARN)
        return
      end
      local artifacts_mod = require("agy.artifacts")
      local arts = artifacts_mod.get_artifacts(cid, state.config.app_data_dir)
      if #arts == 0 then
        vim.notify("[agy.nvim] No artifacts found for this conversation", vim.log.levels.INFO)
        return
      end
      local target_art = art_arg or arts[1].filename
      vim.cmd("edit agy://" .. cid .. "/artifacts/" .. target_art)
      return

    -- 21. /version: show version info
    elseif first_token == "/version" then
      clear_prompt_and_clean()
      local cfg = state.config or config_mod.get()
      local cmd_name = cfg.agy_cmd or "agy"
      local exe_ok = vim.fn.executable(cmd_name) == 1
      vim.notify("[agy.nvim] agy.nvim 1.0.0 (" .. cmd_name .. " CLI " .. (exe_ok and "ready" or "missing") .. ")", vim.log.levels.INFO)
      return

    -- 20. Generic fallback for any other control command
    else
      clear_prompt_and_clean()
      vim.notify("[agy.nvim] Handled control command " .. first_token, vim.log.levels.INFO)
      return
    end
  end

  M.flush_stream_delta(buf, false)
  state.follow_bottom = (state.config and state.config.ui and state.config.ui.auto_scroll ~= false)
  state.active_agent_started_output = false
  state.last_thought_start_time = vim.uv.hrtime()
  state.had_background_task = false
  state.reengage_follow_bottom = nil

  M.with_modifiable(buf, function()
    -- Prepare buffer: append agent response placeholder and active thinking divider
    local extmark_id, agent_line = render.prepare_turn_submission(buf, state.prompt_start_line, state.prompt_extmark_id)
    state.agent_extmark_id = extmark_id
    state.agent_line = agent_line
    state.prompt_extmark_id = nil
  end)

  -- Move cursor to bottom of the buffer
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    local line_count = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
  end

  completion.close()

  state.stream_info.status = "thinking"
  M.update_footer(buf)
  render.start_thinking_animation(buf, nil, nil, state.config)

  -- Send prompt to agy session with resolved file mentions metadata
  local workspaces = (state.session and state.session.workspaces and #state.session.workspaces > 0)
      and state.session.workspaces
      or { (state.session and state.session.cwd) or vim.fn.getcwd() }
  local payload = M.resolve_prompt_mentions(prompt_text, workspaces)

  local sent = state.session:send_prompt(payload)
  if not sent then
    state.stream_info.status = "ready"
    M.with_modifiable(buf, function()
      if state.agent_extmark_id and state.agent_line then
        pcall(function()
          render.set_divider(buf, state.agent_line, "agent", " [Failed]", "AgyBadgeError", false, state.agent_extmark_id, state.config)
        end)
      end
      local next_line, prompt_extmark_id = render.render_error(buf, "Failed to send prompt: agy session process is not active", state.config)
      state.prompt_start_line = next_line
      state.prompt_extmark_id = prompt_extmark_id
      state.agent_extmark_id = nil
      state.agent_line = nil
    end)
    M.update_modifiable(buf)
    return
  end
  M.update_modifiable(buf)

  -- Mark buffer clean so [+] is cleared immediately after :w
  vim.bo[buf].modified = false

  -- Log conversation prompt to history.jsonl
  local clean_disp = utils.clean_user_content(prompt_text)
  if clean_disp == "" then
    clean_disp = prompt_text:match("^[^\r\n]+") or prompt_text
  end
  local target_ws = (workspaces and workspaces[1]) or vim.fn.getcwd()

  if state.conversation_id and state.conversation_id ~= "" and state.conversation_id ~= "new" then
    transcript_mod.append_history({
      conversation_id = state.conversation_id,
      display = clean_disp,
      workspace = target_ws,
    }, state.config and state.config.app_data_dir)
  else
    state.pending_history_display = clean_disp
  end

  -- Restore prompt area so user can continue typing or queueing while turn is active
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and M.buffers[buf] == state then
      M.restore_prompt_area(buf)
    end
  end)
end

---Restore the prompt input area at the bottom of the buffer while a turn is active
---@param buf number
function M.restore_prompt_area(buf)
  local state = M.buffers[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return end
  if state.active_question then return end
  if state.prompt_extmark_id then
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, {})
    if pos and #pos >= 1 then
      return
    end
  end

  M.with_modifiable(buf, function()
    local line_count = vim.api.nvim_buf_line_count(buf)
    local to_add = { "", "" }

    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, to_add)
    local new_count = vim.api.nvim_buf_line_count(buf)
    local is_thinking = (state.stream_info and state.stream_info.status == "thinking")
      or (state.session and state.session.turn_active)
    local badge = (is_thinking or (render.thinking_timers and render.thinking_timers[buf]))
      and (render.current_thinking_badge and render.current_thinking_badge[buf] or render.get_thinking_badge(state.config))
      or nil
    state.prompt_extmark_id = render.set_divider(buf, new_count - 1, "user", badge, "AgyBadgeActive", true, nil, state.config)

    if state.prompt_queue and #state.prompt_queue > 0 then
      local new_prompt_line = render.render_queue(buf, state.prompt_queue, state.prompt_start_line, state.config)
      state.prompt_start_line = new_prompt_line
      state.prompt_extmark_id = render.set_divider(buf, new_prompt_line - 1, "user", badge, "AgyBadgeActive", true, state.prompt_extmark_id, state.config)
    end

    if is_thinking and not (render.thinking_timers and render.thinking_timers[buf]) then
      render.start_thinking_animation(buf, nil, state.prompt_extmark_id, state.config)
    end

    render.apply_prompt_highlights(buf, state.prompt_start_line)
  end)

  state.follow_bottom = (state.config and state.config.ui and state.config.ui.auto_scroll ~= false)

  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      wins = { win }
    end
  end

  local cur_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(wins) do
    pcall(function()
      local cur = vim.api.nvim_win_get_cursor(win)
      if win == cur_win or cur[1] >= state.prompt_start_line or cur[1] >= (state.prompt_start_line - 3) then
        vim.api.nvim_win_set_cursor(win, { state.prompt_start_line, 0 })
      end
    end)
  end

  M.update_modifiable(buf)
  M.update_footer(buf)
end

---Queue a prompt message to be dispatched when the active turn completes
---@param buf number
---@param prompt_text string
function M.queue_prompt(buf, prompt_text)
  local state = M.buffers[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return end

  state.prompt_queue = state.prompt_queue or {}
  table.insert(state.prompt_queue, {
    id = #state.prompt_queue + 1,
    text = prompt_text,
  })

  M.with_modifiable(buf, function()
    -- Clear current prompt input area
    vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, { "" })
    vim.bo[buf].modified = false

    -- Render queue above the prompt divider
    local new_prompt_line = render.render_queue(buf, state.prompt_queue, state.prompt_start_line, state.config)
    state.prompt_start_line = new_prompt_line
    local badge = (render.thinking_timers and render.thinking_timers[buf])
      and (render.current_thinking_badge and render.current_thinking_badge[buf] or render.get_thinking_badge(state.config))
      or nil
    state.prompt_extmark_id = render.set_divider(buf, new_prompt_line - 1, "user", badge, "AgyBadgeActive", true, state.prompt_extmark_id, state.config)
    render.apply_prompt_highlights(buf, state.prompt_start_line)
  end)

  state.follow_bottom = (state.config and state.config.ui and state.config.ui.auto_scroll ~= false)

  -- Reposition cursor at restored prompt line
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      wins = { win }
    end
  end
  local cur_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(wins) do
    pcall(function()
      local cur = vim.api.nvim_win_get_cursor(win)
      if win == cur_win or cur[1] >= state.prompt_start_line or cur[1] >= (state.prompt_start_line - 3) then
        vim.api.nvim_win_set_cursor(win, { state.prompt_start_line, 0 })
      end
    end)
  end

  completion.close()
  M.update_modifiable(buf)
  M.update_prompt_divider(buf)
  M.update_footer(buf)

  vim.notify(string.format("[agy.nvim] Queued message #%d (press <CR> on queued message to edit)", #state.prompt_queue), vim.log.levels.INFO)
end

---Unqueue prompt message at cursor position and restore it to prompt area
---@param buf number
---@param cur_line number 1-indexed line
---@return boolean handled
function M.unqueue_prompt_at_cursor(buf, cur_line)
  local state = M.buffers[buf]
  if not state or not state.prompt_queue or #state.prompt_queue == 0 then return false end

  local cur_row = cur_line - 1
  local matched_idx = nil

  for i, item in ipairs(state.prompt_queue) do
    if item.extmark_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_QUEUE, item.extmark_id, {})
      if pos and #pos >= 1 then
        local row = pos[1]
        local count = item.line_count or 1
        if cur_row >= row and cur_row < row + count then
          matched_idx = i
          break
        end
      end
    end
  end

  if not matched_idx then
    local line_str = vim.api.nvim_buf_get_lines(buf, cur_row, cur_row + 1, false)[1] or ""
    local q_num = line_str:match("Queued%s*#(%d+)")
    if q_num then
      local num = tonumber(q_num)
      if num and num <= #state.prompt_queue then
        matched_idx = num
      end
    end
  end

  if not matched_idx then return false end

  local unqueued_item = table.remove(state.prompt_queue, matched_idx)
  for i, item in ipairs(state.prompt_queue) do
    item.id = i
  end

  M.with_modifiable(buf, function()
    local new_prompt_line = render.render_queue(buf, state.prompt_queue, state.prompt_start_line, state.config)
    state.prompt_start_line = new_prompt_line
    local badge = (render.thinking_timers and render.thinking_timers[buf])
      and (render.current_thinking_badge and render.current_thinking_badge[buf] or render.get_thinking_badge(state.config))
      or nil
    state.prompt_extmark_id = render.set_divider(buf, new_prompt_line - 1, "user", badge, "AgyBadgeActive", true, state.prompt_extmark_id, state.config)
    render.apply_prompt_highlights(buf, state.prompt_start_line)

    local p_lines = utils.split_lines(unqueued_item.text)
    vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, p_lines)
  end)

  local win = vim.fn.bufwinid(buf)
  if win ~= -1 and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { state.prompt_start_line, 0 })
  end

  vim.bo[buf].modified = true
  M.update_modifiable(buf)
  M.update_prompt_divider(buf)
  M.update_footer(buf)

  vim.notify("[agy.nvim] Restored queued message to prompt input", vim.log.levels.INFO)
  return true
end

---Stop an in-flight turn for a buffer
---@param buf number
function M.stop_turn(buf)
  local state = M.buffers[buf]
  if not state or not state.session then return end

  if state.active_question then
    render.finalize_question_block(buf, state.active_question, state.config)
    state.active_question = nil
    state.stream_info.status = "ready"
    M.with_modifiable(buf, function()
      local next_line, prompt_extmark_id = render.render_cancelled(buf, state.config)
      state.prompt_start_line = next_line
      state.prompt_extmark_id = prompt_extmark_id
    end)
    M.update_footer(buf)
    vim.notify("[agy.nvim] Question cancelled.", vim.log.levels.INFO)
    return
  end

  if state.session.turn_active then
    state.session:stop()
    state.stream_info.status = "ready"
    M.with_modifiable(buf, function()
      local next_line, prompt_extmark_id = render.render_cancelled(buf, state.config)
      state.prompt_start_line = next_line
      state.prompt_extmark_id = prompt_extmark_id
    end)
    M.update_footer(buf)
    vim.notify("[agy.nvim] Turn cancelled.", vim.log.levels.INFO)
  else
    vim.notify("[agy.nvim] No active turn running.", vim.log.levels.INFO)
  end
end

---Toggle tool output block at current cursor position
---@param buf number
---@param target_win? number Specific window where cursor triggered the action
---@return boolean handled
function M.toggle_tool_at_cursor(buf, target_win)
  local state = M.buffers[buf]
  if not state or not state.tool_calls then return false end

  local cur_win = vim.api.nvim_get_current_win()
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    if vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win) == buf then
      target_win = cur_win
    elseif state.active_tool_call and state.active_tool_call.target_win and vim.api.nvim_win_is_valid(state.active_tool_call.target_win) then
      target_win = state.active_tool_call.target_win
    else
      target_win = vim.fn.bufwinid(buf)
    end
  end

  if target_win == -1 or not vim.api.nvim_win_is_valid(target_win) then return false end

  if state.active_tool_call and cur_win == state.active_tool_call.win then
    local target_tc = state.active_tool_call
    render.close_tool_window(state, target_tc)
    if vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
      if target_tc.header_line_idx then
        pcall(vim.api.nvim_win_set_cursor, target_win, { target_tc.header_line_idx + 1, 0 })
      end
    end
    return true
  end

  local cur_row = vim.api.nvim_win_get_cursor(target_win)[1] - 1 -- 0-indexed

  for _, tc in ipairs(state.tool_calls) do
    if tc.header_extmark_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, tc.header_extmark_id, {})
      if pos and #pos >= 1 then
        local h_row = pos[1]
        local is_target = false
        if cur_row == h_row then
          is_target = true
        end

        if is_target then
          local ok = render.toggle_tool_output(buf, state, tc, target_win)
          M.update_footer(buf)
          return ok
        end
      end
    end
  end

  return false
end

---Clean up session when buffer is closed
---@param buf number
function M.cleanup_buffer(buf)
  completion.close()
  pcall(vim.api.nvim_del_augroup_by_name, "AgyBuffer_" .. buf)
  local state = M.buffers[buf]
  if state then
    if state.stream_flush_timer then
      pcall(function()
        state.stream_flush_timer:stop()
        if not state.stream_flush_timer:is_closing() then
          state.stream_flush_timer:close()
        end
      end)
      state.stream_flush_timer = nil
    end
    state.pending_text_delta = nil
    if state.is_artifact then
      pcall(vim.api.nvim_buf_clear_namespace, buf, require("agy.artifacts").NS_COMMENTS, 0, -1)
      pcall(vim.api.nvim_buf_clear_namespace, buf, require("agy.artifacts").NS_FOOTER, 0, -1)
      M.buffers[buf] = nil
      return
    end
    if state.active_tool_call then
      render.close_tool_window(state, state.active_tool_call)
    end
    pcall(vim.api.nvim_buf_clear_namespace, buf, render.NS_SPACER, 0, -1)
    render.stop_logo_animation(buf)
    pcall(vim.api.nvim_buf_clear_namespace, buf, render.NS_LOGO, 0, -1)
    if state.session and state.session.destroy then
      state.session:destroy()
    end
    M.buffers[buf] = nil
  end
end

---Main handler for BufReadCmd agy://*
---@param args table
function M.handle_buf_read(args)
  local buf = args.buf
  local uri = args.file
  local raw_id = uri:match("^agy://(.*)$") or ""
  local clean_raw = raw_id:match("^([^?#]+)") or ""

  local cfg = config_mod.get()

  -- Check if this is an artifact URL: agy://<conv_id>/artifacts[/<filename>]
  local art_conv_id, art_subpath = clean_raw:match("^([^/]+)/artifacts/?(.*)$")
  if art_conv_id then
    local artifacts_mod = require("agy.artifacts")
    local target_filename = art_subpath
    if not target_filename or target_filename == "" then
      local latest = artifacts_mod.get_latest_artifact(art_conv_id, cfg.app_data_dir)
      if latest then
        target_filename = latest.filename
        local target_name = "agy://" .. art_conv_id .. "/artifacts/" .. target_filename
        pcall(vim.api.nvim_buf_set_name, buf, target_name)
      else
        vim.notify("[agy.nvim] No artifacts found for this conversation", vim.log.levels.INFO)
        vim.cmd("edit agy://" .. art_conv_id)
        return
      end
    end

    artifacts_mod.render_artifact(buf, art_conv_id, target_filename, cfg)
    M.buffers[buf] = {
      buf = buf,
      conversation_id = art_conv_id,
      artifact_filename = target_filename,
      is_artifact = true,
      config = cfg,
    }
    return
  end

  -- Check if this is the home buffer: agy:// or agy:/// or agy://home
  if clean_raw == "" or clean_raw == "/" or clean_raw == "home" then
    local existing_state = M.buffers[buf]
    if existing_state and existing_state.session and existing_state.session.turn_active then
      existing_state.session:stop()
    end

    local home_mod = require("agy.home")
    home_mod.render_home(buf, cfg)
    M.buffers[buf] = {
      buf = buf,
      is_home = true,
      config = cfg,
    }
    return
  end

  local conv_id = clean_raw

  -- If previous buffer state was an artifact buffer or home buffer, clear it
  local existing_state = M.buffers[buf]
  if existing_state and (existing_state.is_artifact or existing_state.is_home) then
    M.buffers[buf] = nil
    existing_state = nil
  end

  -- Check if this is a reload (:e or :e!) on an already initialized agy buffer
  if existing_state then
    local target_id = conv_id
    if (target_id == "" or target_id == "new") and existing_state.conversation_id then
      target_id = existing_state.conversation_id
    end

    if existing_state.session and existing_state.session.turn_active then
      existing_state.session:stop()
      if existing_state.stream_info then
        existing_state.stream_info.status = "connecting"
      end
    elseif existing_state.session and existing_state.session.is_initialized then
      if existing_state.stream_info then
        existing_state.stream_info.status = "ready"
      end
    else
      if existing_state.stream_info then
        existing_state.stream_info.status = "connecting"
      end
    end

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].filetype = "agy"
    pcall(vim.treesitter.start, buf, "markdown")
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "hide"

    local prompt_line, prompt_ext_id, tool_calls
    M.with_modifiable(buf, function()
      if target_id == "" or target_id == "new" then
        prompt_line, prompt_ext_id = render.render_new_session(buf, cfg)
        tool_calls = {}
      else
        local steps = transcript_mod.read_transcript(target_id, cfg.app_data_dir)
        local ws = existing_state.workspaces
          or (existing_state.session and (existing_state.session.workspaces or existing_state.session.cwd))
          or vim.fn.getcwd()
        prompt_line, prompt_ext_id, tool_calls = render.render_transcript(buf, target_id, steps, cfg, ws)
      end
    end)

    existing_state.prompt_start_line = prompt_line
    existing_state.prompt_extmark_id = prompt_ext_id
    existing_state.tool_calls = tool_calls or {}
    existing_state.active_tool_record = nil
    existing_state.footer_extmark_id = nil
    existing_state.agent_extmark_id = nil
    existing_state.agent_line = nil
    existing_state.active_tool_line = nil
    existing_state.active_tool_extmark_id = nil
    existing_state.rendered_thinking = {}
    if target_id ~= "" and target_id ~= "new" then
      local loaded_steps = transcript_mod.read_transcript(target_id, cfg.app_data_dir)
      for idx, s in ipairs(loaded_steps) do
        if s.type == "PLANNER_RESPONSE" and s.thinking and s.thinking ~= "" then
          local key = (s.step_index or tostring(idx)) .. ":" .. s.thinking
          existing_state.rendered_thinking[key] = true
        end
      end
    end

    if not existing_state.stream_info then
      existing_state.stream_info = {}
    end
    if not existing_state.stream_info.model or existing_state.stream_info.model == "" then
      if target_id ~= "" and target_id ~= "new" then
        local loaded_steps = transcript_mod.read_transcript(target_id, cfg.app_data_dir)
        local conv_model = transcript_mod.extract_model_from_steps(loaded_steps)
        existing_state.stream_info.model = conv_model and completion.resolve_model(conv_model) or completion.get_default_model(cfg.app_data_dir, cfg.default_model, cfg.agy_cmd)
      else
        existing_state.stream_info.model = completion.get_default_model(cfg.app_data_dir, cfg.default_model, cfg.agy_cmd)
      end
    end

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].filetype = "agy"
    pcall(vim.treesitter.start, buf, "markdown")
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "hide"

    pcall(function()
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        vim.wo[win].wrap = cfg.ui.wrap
        vim.wo[win].linebreak = cfg.ui.linebreak
        vim.wo[win].conceallevel = (cfg.ui and cfg.ui.conceallevel ~= nil) and cfg.ui.conceallevel or 0
        vim.wo[win].concealcursor = ""
      else
        vim.wo.wrap = cfg.ui.wrap
        vim.wo.linebreak = cfg.ui.linebreak
        vim.wo.conceallevel = (cfg.ui and cfg.ui.conceallevel ~= nil) and cfg.ui.conceallevel or 0
        vim.wo.concealcursor = ""
      end
    end)

    completion.setup_buffer(buf)

    -- Up navigation to agy:// home
    vim.keymap.set("n", "-", function()
      vim.cmd("edit agy://")
    end, {
      buffer = buf,
      silent = true,
      desc = "Navigate up to agy:// home",
    })

    vim.bo[buf].modified = false
    pcall(function() vim.cmd("let &undolevels = &undolevels") end)

    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      pcall(vim.api.nvim_win_set_cursor, win, { prompt_line, 0 })
    end

    M.update_modifiable(buf)
    M.update_footer(buf)
    vim.notify("[agy.nvim] Reloaded conversation " .. (target_id ~= "" and target_id or "new"), vim.log.levels.INFO)
    return
  end

  M._setup_buffer(buf, conv_id)

  local is_new = (conv_id == "new")
  local prompt_line, prompt_ext_id, initial_tool_calls
  local rendered_thinking = {}

  local workspaces = nil
  if cfg.workspaces then
    if type(cfg.workspaces) == "function" then
      local ok, res = pcall(cfg.workspaces)
      if ok and type(res) == "table" then
        workspaces = res
      end
    elseif type(cfg.workspaces) == "table" then
      workspaces = cfg.workspaces
    end
  end

  local render_workspaces = workspaces
  if not render_workspaces or #render_workspaces == 0 then
    if not is_new then
      local ws = transcript_mod.get_conversation_workspace(conv_id, cfg.app_data_dir)
      if ws and ws ~= "" then
        render_workspaces = { ws }
      end
    end
  end
  if not render_workspaces or #render_workspaces == 0 then
    render_workspaces = { vim.fn.getcwd() }
  end

  if is_new and (not workspaces or #workspaces == 0) then
    workspaces = { vim.fn.getcwd() }
  end

  local steps = nil
  if not is_new then
    steps = transcript_mod.read_transcript(conv_id, cfg.app_data_dir)
  end

  M.with_modifiable(buf, function()
    if is_new then
      prompt_line, prompt_ext_id = render.render_new_session(buf, cfg)
      initial_tool_calls = {}
    else
      for idx, s in ipairs(steps) do
        if s.type == "PLANNER_RESPONSE" and s.thinking and s.thinking ~= "" then
          local key = (s.step_index or tostring(idx)) .. ":" .. s.thinking
          rendered_thinking[key] = true
        end
      end
      prompt_line, prompt_ext_id, initial_tool_calls = render.render_transcript(buf, conv_id, steps, cfg, render_workspaces)
    end
  end)

  vim.bo[buf].modified = false

  -- Position cursor at the prompt line
  pcall(function()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_win_set_cursor(win, { prompt_line, 0 })
    end
  end)

  -- Resolve active model for buffer session:
  -- 1. If resuming existing conversation, check transcript for latest model change
  -- 2. Otherwise default model from user config, settings.json, or agy models
  local active_model = nil
  if not is_new and steps then
    local conv_model = transcript_mod.extract_model_from_steps(steps)
    if conv_model then
      active_model = completion.resolve_model(conv_model)
    end
  end
  if not active_model or active_model == "" then
    active_model = completion.get_default_model(cfg.app_data_dir, cfg.default_model, cfg.agy_cmd)
  end

  -- Initialize session state
  local state = {
    buf = buf,
    conversation_id = is_new and nil or conv_id,
    config = cfg,
    prompt_start_line = prompt_line,
    prompt_extmark_id = prompt_ext_id,
    footer_extmark_id = nil,
    workspaces = render_workspaces,
    tool_calls = initial_tool_calls or {},
    active_tool_record = nil,
    rendered_thinking = rendered_thinking,
    stream_info = {
      model = active_model,
      permission_mode = nil,
      tools_count = nil,
      total_tokens = nil,
      duration_seconds = nil,
      status = "connecting",
    },
    agent_extmark_id = nil,
    agent_line = nil,
    active_tool_line = nil,
    active_tool_extmark_id = nil,
  }

  state.session = session_mod.new({
    conversation_id = is_new and nil or conv_id,
    agy_cmd = cfg.agy_cmd,
    mode = cfg.default_mode,
    model = active_model,
    cwd = vim.fn.getcwd(),
    workspaces = workspaces,
    client_instructions = (cfg.client_instructions ~= false),

    on_init = function(s, cid, payload)
      if cid and cid ~= "" then
        state.conversation_id = cid
        local target_name = "agy://" .. cid
        if vim.api.nvim_buf_get_name(buf) ~= target_name then
          pcall(function()
            vim.api.nvim_buf_set_name(buf, target_name)
          end)
        end
        M.with_modifiable(buf, function()
          render.update_session_id(buf, cid, state.config)
        end)

        if state.pending_history_display then
          local ws = (state.workspaces and state.workspaces[1])
            or (state.session and state.session.cwd)
            or vim.fn.getcwd()
          transcript_mod.append_history({
            conversation_id = cid,
            display = state.pending_history_display,
            workspace = ws,
          }, state.config and state.config.app_data_dir)
          state.pending_history_display = nil
        end
      end

      state.stream_info.status = "ready"
      if payload then
        if payload.permission_mode then
          state.stream_info.permission_mode = payload.permission_mode
        end
        if payload.tools then
          state.stream_info.tools_count = #payload.tools
        end
        if payload.model and payload.model ~= "" then
          state.stream_info.model = completion.resolve_model(payload.model)
        end
      end
      if s.model and s.model ~= "" then
        state.stream_info.model = completion.resolve_model(s.model)
      end
      M.update_footer(buf)
    end,

    on_step_update = function(s, step)
      local stype = step.step_type

      -- If active question is waiting for user response, ignore subsequent steps from cancelled turn
      if state.active_question then
        return
      end

      -- Check direct ask_question tool step
      if stype == "tool" and (step.tool_name == "ask_question" or (step.tool_info and step.tool_info.name == "ask_question")) then
        local params = step.tool_info and step.tool_info.parameters
        local q_list = render.parse_question_params(params)
        if #q_list > 0 then
          M.intercept_ask_question(buf, state, q_list)
          return
        end
      end

      -- Check transcript for ask_question
      if M.check_and_intercept_ask_question(buf, state) then
        return
      end

      if stype == "agent_response" then
        if not state.active_agent_started_output then
          M.reconcile_background_tasks(buf, state, state.conversation_id)
          M.check_and_render_pending_thoughts(buf)
          state.active_agent_started_output = true
        end
        M.handle_post_task_bottom_visibility(buf, state)
        if step.text_delta and step.text_delta ~= "" then
          M.queue_stream_delta(buf, step.text_delta)
        end

      elseif stype == "tool" then
        M.flush_stream_delta(buf, false)

        -- If an artifact feedback request was pending and the agent tries to run another tool:
        if state.pending_artifact_feedback and step.state == "ACTIVE" then
          local fname = state.pending_artifact_feedback.filename or "artifact"
          state.pending_artifact_feedback = nil
          if state.session and state.session.turn_active then
            state.session:stop()
          end
          state.stream_info.status = "ready"
          M.update_footer(buf)
          vim.notify(string.format("[agy.nvim] Artifact review requested for '%s'. Review with :AgyArtifacts or reply below.", fname), vim.log.levels.INFO)
          return
        end

        if step.state == "ACTIVE" then
          local is_feedback, fname, summary = check_artifact_feedback_request(step.tool_name, step.tool_info and step.tool_info.parameters)
          if is_feedback then
            state.pending_artifact_feedback = {
              filename = fname,
              summary = summary,
            }
          end

          M.reconcile_background_tasks(buf, state, state.conversation_id)
          M.handle_post_task_bottom_visibility(buf, state)
          M.check_and_render_pending_thoughts(buf)
          state.stream_info.status = "tool:" .. (step.tool_name or "tool")
          M.update_footer(buf)
          M.with_modifiable(buf, function()
            local ws = (state.workspaces and #state.workspaces > 0) and state.workspaces or ((s.workspaces and #s.workspaces > 0) and s.workspaces or s.cwd)
            local tool_line, ext_id, param_str = render.append_tool_call(buf, step.tool_name or "tool", step.tool_info and step.tool_info.parameters, ws, state.config)
            local tool_rec = {
              id = #state.tool_calls + 1,
              buf = buf,
              tool_name = step.tool_name or "tool",
              params = step.tool_info and step.tool_info.parameters,
              param_str = param_str,
              output = nil,
              duration_seconds = nil,
              start_time = vim.uv.hrtime(),
              status = "running",
              is_open = false,
              header_extmark_id = ext_id,
              header_line_idx = tool_line,
              output_lines_count = 0,
            }
            table.insert(state.tool_calls, tool_rec)
            state.active_tool_record = tool_rec
            M.ensure_prompt_line(buf)
            if state.follow_bottom then
              render.scroll_to_bottom(buf, true)
            end
            M.update_footer(buf)
          end)
        elseif step.state == "DONE" then
          state.stream_info.status = "thinking"
          state.last_thought_start_time = vim.uv.hrtime()
          M.update_footer(buf)
          if state.active_tool_record then
            M.with_modifiable(buf, function()
              render.complete_tool_call(buf, state.active_tool_record, step.duration_seconds, step.tool_info and step.tool_info.output, state.config)
              if state.active_tool_record and state.active_tool_record.is_background_task then
                state.had_background_task = true
              end
              M.ensure_prompt_line(buf)
              if state.follow_bottom then
                render.scroll_to_bottom(buf, true)
              end
              M.update_footer(buf)
            end)
            state.active_tool_record = nil
          end

          -- Handle manage_task with Action == "kill"
          if step.tool_name == "manage_task" and step.tool_info and step.tool_info.parameters then
            local p = step.tool_info.parameters
            if p.Action == "kill" and p.TaskId then
              local tasks_mod = require("agy.tasks")
              local sid = tasks_mod.short_id(p.TaskId)
              for _, tc in ipairs(state.tool_calls) do
                if tc.is_background_task and tc.task_status == "running" and (tc.task_id == p.TaskId or tc.short_id == sid) then
                  if not tc.duration_seconds and tc.start_time then
                    tc.duration_seconds = math.max(0, (vim.uv.hrtime() - tc.start_time) / 1e9)
                  end
                  M.with_modifiable(buf, function()
                    render.update_task_status(buf, tc, "failed", 130, state.config)
                  end)
                  state.had_background_task = true
                  state.reengage_follow_bottom = true
                end
              end
            end
          end
        end

      elseif stype == "system_message" and step.state == "DONE" then
        M.flush_stream_delta(buf, false)
        M.reconcile_background_tasks(buf, state, state.conversation_id)
      else
        M.flush_stream_delta(buf, false)
      end
    end,

    on_result = function(s, result)
      M.flush_stream_delta(buf, false)
      state.stream_info.status = "ready"
      if result.conversation_id and result.conversation_id ~= "" then
        state.conversation_id = result.conversation_id
      end
      if state.pending_history_display and state.conversation_id and state.conversation_id ~= "" and state.conversation_id ~= "new" then
        local ws = (state.workspaces and state.workspaces[1])
          or (state.session and state.session.cwd)
          or vim.fn.getcwd()
        transcript_mod.append_history({
          conversation_id = state.conversation_id,
          display = state.pending_history_display,
          workspace = ws,
        }, state.config and state.config.app_data_dir)
        state.pending_history_display = nil
      end
      if state.active_question then
        -- Interactive question is waiting for user response; do not finalize or clear it
        return
      end

      if state.pending_artifact_feedback then
        local fname = state.pending_artifact_feedback.filename or "artifact"
        state.pending_artifact_feedback = nil
        vim.notify(string.format("[agy.nvim] Artifact review requested for '%s'. Review with :AgyArtifacts or reply below.", fname), vim.log.levels.INFO)
      end
      if not state.active_agent_started_output then
        M.check_and_render_pending_thoughts(buf)
      else
        M.mark_transcript_thoughts_rendered(buf, state)
      end
      state.active_agent_started_output = false
      if result.usage and result.usage.total_tokens then
        state.stream_info.total_tokens = result.usage.total_tokens
      end
      if result.duration_seconds then
        state.stream_info.duration_seconds = result.duration_seconds
      end
      if result.model then
        state.stream_info.model = result.model
      end

      -- Reconcile any remaining running background tasks from disk transcript outcomes
      M.reconcile_background_tasks(buf, state, state.conversation_id)
      M.handle_post_task_bottom_visibility(buf, state)

      if state.agent_extmark_id and state.agent_line then
        M.with_modifiable(buf, function()
          local next_line, prompt_extmark_id = render.finalize_turn(buf, state.agent_extmark_id, state.agent_line, result, state.config)
          state.prompt_start_line = next_line
          state.prompt_extmark_id = prompt_extmark_id
          state.agent_extmark_id = nil
          state.agent_line = nil

          -- Position cursor at the new prompt input line if user stayed at bottom
          if state.follow_bottom then
            local wins = vim.fn.win_findbuf(buf)
            if #wins == 0 then
              local win = vim.fn.bufwinid(buf)
              if win ~= -1 then
                wins = { win }
              end
            end
            local cur_win = vim.api.nvim_get_current_win()
            for _, win in ipairs(wins) do
              pcall(function()
                local cur = vim.api.nvim_win_get_cursor(win)
                if cur[1] >= next_line then
                  local line_text = vim.api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1] or ""
                  vim.api.nvim_win_set_cursor(win, { cur[1], math.min(cur[2], #line_text) })
                elseif win == cur_win then
                  vim.api.nvim_win_set_cursor(win, { next_line, 0 })
                end
                render.ensure_bottom_visible(win, buf)
              end)
            end
            state.follow_bottom = false
          end
        end)
      end
      M.update_modifiable(buf)
      M.update_footer(buf)

      if state.prompt_queue and #state.prompt_queue > 0 then
        local next_item = table.remove(state.prompt_queue, 1)
        for i, item in ipairs(state.prompt_queue) do
          item.id = i
        end
        M.with_modifiable(buf, function()
          local clean_prompt_line = render.render_queue(buf, {}, state.prompt_start_line, state.config)
          state.prompt_start_line = clean_prompt_line
          state.prompt_extmark_id = render.set_divider(buf, clean_prompt_line - 1, "user", nil, nil, true, state.prompt_extmark_id, state.config)
          render.apply_prompt_highlights(buf, state.prompt_start_line)

          local p_lines = utils.split_lines(next_item.text)
          vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, p_lines)
        end)

        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) and M.buffers[buf] == state then
            M.handle_write(buf)
          end
        end)
      end
    end,

    on_error = function(s, err_msg)
      if state.active_question then
        return
      end
      M.flush_stream_delta(buf, false)
      state.stream_info.status = "ready"
      state.active_agent_started_output = false
      M.with_modifiable(buf, function()
        if state.agent_extmark_id and state.agent_line then
          pcall(function()
            render.set_divider(buf, state.agent_line, "agent", " [Error]", "AgyBadgeError", false, state.agent_extmark_id, state.config)
          end)
        end
        local next_line, prompt_extmark_id = render.render_error(buf, err_msg, state.config)
        state.prompt_start_line = next_line
        state.prompt_extmark_id = prompt_extmark_id
        state.agent_extmark_id = nil
        state.agent_line = nil

        if state.follow_bottom then
          local wins = vim.fn.win_findbuf(buf)
          if #wins == 0 then
            local win = vim.fn.bufwinid(buf)
            if win ~= -1 then
              wins = { win }
            end
          end
          local cur_win = vim.api.nvim_get_current_win()
          for _, win in ipairs(wins) do
            pcall(function()
              local cur = vim.api.nvim_win_get_cursor(win)
              if cur[1] >= next_line then
                local line_text = vim.api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1] or ""
                vim.api.nvim_win_set_cursor(win, { cur[1], math.min(cur[2], #line_text) })
              elseif win == cur_win then
                vim.api.nvim_win_set_cursor(win, { next_line, 0 })
              end
            end)
          end
          state.follow_bottom = false
        end
      end)
      M.update_modifiable(buf)
      M.update_footer(buf)
    end,

    on_exit = function(s, code, was_turn_active)
      if state.active_question then
        return
      end
      state.stream_info.status = "ready"
      state.active_agent_started_output = false
      if was_turn_active or s.turn_active or state.agent_extmark_id ~= nil then
        M.with_modifiable(buf, function()
          if state.agent_extmark_id and state.agent_line then
            pcall(function()
              render.set_divider(buf, state.agent_line, "agent", " [Failed]", "AgyBadgeError", false, state.agent_extmark_id, state.config)
            end)
          end
          local next_line, prompt_extmark_id = render.render_error(buf, "agy process exited unexpectedly with code " .. tostring(code), state.config)
          state.prompt_start_line = next_line
          state.prompt_extmark_id = prompt_extmark_id
          state.agent_extmark_id = nil
          state.agent_line = nil
        end)
      end
      M.update_modifiable(buf)
      M.update_footer(buf)
    end,
  })

  M.buffers[buf] = state
  M.update_modifiable(buf)
  M.update_footer(buf)
end

---Setup global autocommands for agy:// protocol
function M.setup()
  if vim.treesitter and vim.treesitter.language and vim.treesitter.language.register then
    pcall(vim.treesitter.language.register, "markdown", "agy")
  end

  render.setup_highlights()

  local group = vim.api.nvim_create_augroup("AgyProtocol", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "agy://*",
    callback = function(args)
      M.handle_buf_read(args)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      for b, _ in pairs(M.buffers) do
        if vim.api.nvim_buf_is_valid(b) then
          M.update_prompt_divider(b)
          M.update_footer(b)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      render.setup_highlights()
      for b, _ in pairs(M.buffers) do
        if vim.api.nvim_buf_is_valid(b) then
          M.update_prompt_divider(b)
          M.update_footer(b)
        end
      end
    end,
  })
end

return M
