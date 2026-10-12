local utils = require("agy.utils")
local panel = require("agy.panel")
local transcript_mod = require("agy.transcript")
local subagents_mod = require("agy.subagents")

local M = {}

M.NS_TASKS = vim.api.nvim_create_namespace("agy_tasks")

---Extract a short human-readable task identifier (e.g. task-451)
---@param task_id? string
---@return string
function M.short_id(task_id)
  if not task_id or task_id == "" then return "unknown" end
  return task_id:match("(task%-%d+)") or task_id:match("[^/]+$") or task_id
end

---Parse task metadata from tool call output and parameters
---@param output? string
---@param params? table
---@return table|nil info
function M.parse_task_info(output, params)
  if not output or type(output) ~= "string" or output == "" then
    return nil
  end

  if output:find("finished with result", 1, true) then
    return nil
  end

  local has_cmd_param = params and (params.CommandLine or params.command or params.cmd)
  local is_bg = output:find("Tool is running as a background task", 1, true) ~= nil
    or output:find("Task logs are available", 1, true) ~= nil
    or output:find("task id:%s*[%w%-_/]+") ~= nil
    or (has_cmd_param and output:find("background task", 1, true) ~= nil)

  if not is_bg then
    return nil
  end

  local task_id = output:match("task id:%s*([%w%-_/]+)")
    or output:match("Task:%s*([%w%-_/]+)")
    or output:match("(task%-%d+)")

  if not task_id then
    return nil
  end

  local log_path = output:match("Task logs are available at:%s*file:///([^\r\n]+)")
    or output:match("Task logs are available at:%s*([^\r\n]+)")
    or output:match("Log:%s*([^\r\n]+)")

  if log_path then
    local cleaned_path = log_path:gsub("^[\"']", ""):gsub("[\"']$", "")
    log_path = vim.fs.normalize(cleaned_path)
  end

  local desc = output:match("Task Description:%s*([^\r\n]+)")
  local cmd = (params and (params.CommandLine or params.command or params.cmd)) or desc or ""
  if type(cmd) == "string" then
    cmd = cmd:gsub("^[\"']", ""):gsub("[\"']$", "")
  end

  return {
    task_id = task_id,
    short_id = M.short_id(task_id),
    log_path = log_path,
    command = cmd ~= "" and cmd or (desc or "command"),
    description = desc or cmd or "Background task",
  }
end

---Collect task execution outcomes from transcript steps
---Maps task IDs (both full and short) to { status = "success"|"failed"|"running", exit_code = number }
---@param steps table[]
---@return table<string, table> outcomes
function M.collect_task_outcomes(steps)
  local outcomes = {}
  if not steps or #steps == 0 then return outcomes end

  for _, step in ipairs(steps) do
    local content = step.content or ""
    if content ~= "" then
      local comp = M.parse_task_completion(content)
      if comp then
        outcomes[comp.task_id] = comp
        if comp.short_id and comp.short_id ~= comp.task_id then
          outcomes[comp.short_id] = comp
        end
      end

      -- Check for killed / cancelled tasks via manage_task
      if content:find("manage_task") or content:find("kill") then
        local killed_id = content:match('TaskId:%s*"([^"]+)"') or content:match('TaskId:%s*([%w%-_/]+)')
        if killed_id and not outcomes[killed_id] then
          local outcome = {
            status = "failed",
            exit_code = 130,
            task_id = killed_id,
            short_id = M.short_id(killed_id),
          }
          outcomes[killed_id] = outcome
          local sid = M.short_id(killed_id)
          if sid and sid ~= killed_id then
            outcomes[sid] = outcome
          end
        end
      end
    end
  end

  return outcomes
end

---Parse a task completion message from text
---@param text? string
---@return table|nil completion { task_id = string, short_id = string, status = "success"|"failed", exit_code = number }
function M.parse_task_completion(text)
  if not text or type(text) ~= "string" or text == "" then return nil end

  local tid = text:match('Task id "([^"]+)" finished with result:')
    or text:match('Task id ([%w%-_/]+) finished with result:')

  if tid then
    local code_str = text:match("exited with code%s+(%d+)")
    local code = tonumber(code_str) or 0
    return {
      task_id = tid,
      short_id = M.short_id(tid),
      status = (code == 0) and "success" or "failed",
      exit_code = code,
    }
  end

  return nil
end

---Parse process exit code from log file content or lines
---@param text_or_lines? string|string[]
---@return number|nil exit_code
function M.parse_log_exit_code(text_or_lines)
  if not text_or_lines then return nil end
  local str = (type(text_or_lines) == "table") and table.concat(text_or_lines, "\n") or tostring(text_or_lines)
  local code_str = str:match("exited with code%s+(%d+)")
    or str:match("Process exited with%s+(%d+)")
    or str:match("exited with status%s+(%d+)")
  if code_str then
    return tonumber(code_str)
  end
  return nil
end

---Collect all background tasks for a conversation (from in-memory state, transcript, and disk)
---@param conv_id string
---@param app_data_dir? string
---@param pstate? table
---@return table[] tasks
function M.collect_tasks(conv_id, app_data_dir, pstate)
  local tasks = {}
  local seen = {}

  -- 1. In-memory tool calls from active buffer state
  if pstate and pstate.tool_calls then
    for _, tc in ipairs(pstate.tool_calls) do
      if tc.is_background_task or ((tc.tool_name == "run_command" or tc.name == "run_command") and tc.output and M.parse_task_info(tc.output, tc.params)) then
        local info = M.parse_task_info(tc.output, tc.params)
        local tid = tc.task_id or (info and info.task_id) or ("task-" .. tostring(tc.id))
        local sid = M.short_id(tid)
        if not seen[sid] then
          seen[sid] = true
          table.insert(tasks, {
            task_id = tid,
            short_id = sid,
            status = tc.task_status or "running",
            exit_code = tc.exit_code,
            command = (info and info.command) or (tc.params and (tc.params.CommandLine or tc.params.command)) or tc.param_str or "command",
            log_path = tc.log_path or (info and info.log_path),
            duration_seconds = tc.duration_seconds,
            order_key = tc.order_key or tc.step_index or tc.header_line_idx,
            tool_rec = tc,
          })
        end
      end
    end
  end

  -- 2. Transcript steps on disk
  if conv_id and conv_id ~= "" and conv_id ~= "new" then
    local steps = transcript_mod.read_transcript(conv_id, app_data_dir)
    local outcomes = M.collect_task_outcomes(steps)

    for i, step in ipairs(steps) do
      -- Check step.tool_calls
      if step.tool_calls then
        for _, tc in ipairs(step.tool_calls) do
          if tc.name == "run_command" then
            local next_step = steps[i + 1]
            local output = tc.output or (next_step and next_step.content)
            local info = M.parse_task_info(output, tc.args)
            if info and info.task_id then
              local sid = info.short_id
              local outcome = outcomes[info.task_id] or outcomes[sid] or {}
              local status = outcome.status or "running"
              local exit_code = outcome.exit_code

              if not seen[sid] then
                seen[sid] = true
                table.insert(tasks, {
                  task_id = info.task_id,
                  short_id = sid,
                  status = status,
                  exit_code = exit_code,
                  command = info.command,
                  log_path = info.log_path,
                  duration_seconds = step.duration_seconds or tc.duration_seconds,
                  order_key = step.step_index or i,
                })
              else
                -- Update existing entry with outcome details if missing
                for _, t in ipairs(tasks) do
                  if t.short_id == sid then
                    if status ~= "running" then
                      t.status = status
                      t.exit_code = exit_code
                    end
                    if not t.log_path and info.log_path then
                      t.log_path = info.log_path
                    end
                  end
                end
              end
            end
          end
        end
      end

      -- Check standalone TOOL_CALL steps
      if step.type == "TOOL_CALL" or step.type == "tool" then
        local tname = step.name or (step.tool_info and step.tool_info.name)
        if tname == "run_command" then
          local next_step = steps[i + 1]
          local output = step.output or (next_step and next_step.content)
          local info = M.parse_task_info(output, step.args or (step.tool_info and step.tool_info.parameters))
          if info and info.task_id then
            local sid = info.short_id
            local outcome = outcomes[info.task_id] or outcomes[sid] or {}
            local status = outcome.status or "running"
            local exit_code = outcome.exit_code

            if not seen[sid] then
              seen[sid] = true
              table.insert(tasks, {
                task_id = info.task_id,
                short_id = sid,
                status = status,
                exit_code = exit_code,
                command = info.command,
                log_path = info.log_path,
                duration_seconds = step.duration_seconds,
                order_key = step.step_index or i,
              })
            end
          end
        end
      end
    end

    -- 3. Scan .system_generated/tasks/ directory for task-*.log files
    local tasks_dir = utils.get_brain_dir(app_data_dir) .. "/" .. conv_id .. "/.system_generated/tasks"
    if vim.fn.isdirectory(tasks_dir) == 1 then
      local handle = vim.uv.fs_scandir(tasks_dir)
      if handle then
        while true do
          local name, ftype = vim.uv.fs_scandir_next(handle)
          if not name then break end
          if ftype == "file" and name:match("^task%-%d+%.log$") then
            local sid = name:match("^(task%-%d+)")
            local log_path = vim.fs.normalize(tasks_dir .. "/" .. name)
            if not seen[sid] then
              seen[sid] = true
              local outcome = outcomes[sid] or {}
              table.insert(tasks, {
                task_id = sid,
                short_id = sid,
                status = outcome.status or "running",
                exit_code = outcome.exit_code,
                command = "Background task (" .. sid .. ")",
                log_path = log_path,
              })
            else
              -- Ensure log_path is recorded
              for _, t in ipairs(tasks) do
                if t.short_id == sid and not t.log_path then
                  t.log_path = log_path
                end
              end
            end
          end
        end
      end
    end
  end

  return tasks
end

---Setup highlight groups for tasks
function M.setup_highlights()
  local set_hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  set_hl("AgyTaskTitle", { bold = true, fg = "#7aa2f7" })
  set_hl("AgyTaskHeader", { bold = true, fg = "#565f89" })
  set_hl("AgyTaskId", { bold = true, fg = "#7dcfff" })
  set_hl("AgyTaskCommand", { fg = "#c0caf5" })

  set_hl("AgyTaskRunning", { bold = true, fg = "#e0af68" })
  set_hl("AgyTaskSuccess", { bold = true, fg = "#9ece6a" })
  set_hl("AgyTaskFailed", { bold = true, fg = "#f7768e" })

  set_hl("AgyTaskBadgeRunning", { fg = "#e0af68" })
  set_hl("AgyTaskBadgeSuccess", { fg = "#9ece6a" })
  set_hl("AgyTaskBadgeFailed", { fg = "#f7768e" })
end

---Collect all background tasks and subagents for a conversation (sorted reverse chronologically)
---@param conv_id string
---@param app_data_dir? string
---@param pstate? table
---@return table[] items
function M.collect_items(conv_id, app_data_dir, pstate)
  local tasks = M.collect_tasks(conv_id, app_data_dir, pstate)
  for _, t in ipairs(tasks) do
    t.kind = "task"
    t.name = t.command or "command"
    t.order_key = t.order_key or t.duration_seconds or 0
  end

  local subagents = subagents_mod.collect_subagents(conv_id, app_data_dir, pstate)
  for _, s in ipairs(subagents) do
    s.kind = "subagent"
    s.name = s.role or "Subagent"
    s.order_key = s.order_key or s.spawn_step_index or 0
  end

  local all_items = {}
  for _, t in ipairs(tasks) do
    table.insert(all_items, t)
  end
  for _, s in ipairs(subagents) do
    table.insert(all_items, s)
  end

  if pstate and pstate.in_flight_subagents then
    for _, if_sub in ipairs(pstate.in_flight_subagents) do
      local found = false
      for _, existing in ipairs(all_items) do
        if (if_sub.subagent_id and existing.subagent_id == if_sub.subagent_id)
            or (if_sub.short_id and if_sub.short_id ~= "spawning..." and existing.short_id == if_sub.short_id) then
          found = true
          if if_sub.status == "killed" or existing.status == "killed" then
            existing.status = "killed"
            existing.current_action = nil
          elseif if_sub.status == "completed" then
            existing.status = "completed"
            existing.current_action = nil
          elseif if_sub.current_action and not existing.current_action then
            existing.current_action = if_sub.current_action
          end
          break
        end
      end
      if not found then
        table.insert(all_items, if_sub)
      end
    end
  end

  -- Sort reverse chronologically: most recent tasks/subagents at the top
  table.sort(all_items, function(a, b)
    return (a.order_key or 0) > (b.order_key or 0)
  end)

  return all_items
end

---Build the content lines and metadata for the tasks & subagents bottom panel
---@param pstate table
---@param cfg table
---@param width number
---@return string[] lines, table[] meta, table<number, table> row_to_task
function M.build_content(pstate, cfg, width)
  pstate = pstate or {}
  cfg = cfg or {}
  width = math.max(80, width or 80)

  local session = pstate.session or {}
  local conv_id = pstate.conversation_id or session.conversation_id or "new"

  local items = M.collect_items(conv_id, cfg.app_data_dir, pstate)

  local lines = {}
  local meta = {}
  local row_to_task = {}

  local function add_line(str, l_type, extra)
    table.insert(lines, str)
    table.insert(meta, {
      row = #lines - 1,
      type = l_type,
      extra = extra,
    })
  end

  add_line("📋 Background Tasks & Subagents", "title")
  add_line("", "empty")

  if #items == 0 then
    add_line("  No background tasks or subagents found in this session.", "empty_notice")
    add_line("  Commands running via `run_command` and subagents will appear here.", "comment")
    add_line("", "empty")
  else
    assert(cfg, "agy tasks: config required")
    assert(cfg.icons, "agy tasks: config.icons required")
    assert(cfg.icons.bullets and cfg.icons.bullets[1], "agy tasks: config.icons.bullets[1] required")
    assert(cfg.icons.middle_dot, "agy tasks: config.icons.middle_dot required")
    local bullet = cfg.icons.bullets[1]
    local dot = cfg.icons.middle_dot

    local subagent_count = 0
    local task_count = 0

    for _, it in ipairs(items) do
      local status_str = "Running"
      if it.kind == "subagent" then
        subagent_count = subagent_count + 1
        if it.status == "running" or it.status == "alive" then
          if it.current_action and it.current_action ~= "" and it.current_action ~= "Running" then
            status_str = "Running (" .. it.current_action .. ")"
          else
            status_str = "Running"
          end
        elseif it.status == "killed" then
          status_str = "Killed"
        elseif it.status == "idle" then
          status_str = "Idle"
        else
          status_str = "Completed"
        end
      else
        task_count = task_count + 1
        if it.status == "success" or it.status == "done" then
          status_str = (it.exit_code ~= nil) and ("Success (" .. it.exit_code .. ")") or "Success"
        elseif it.status == "failed" or it.status == "error" then
          status_str = (it.exit_code ~= nil) and ("Failed (" .. it.exit_code .. ")") or "Failed"
        else
          status_str = "Running"
        end
      end

      local prefix = "  " .. bullet .. " "
      local suffix = string.format(" (%s) %s %s", it.short_id, dot, status_str)
      local max_name_w = math.max(15, width - #prefix - #suffix - 2)
      local display_name = it.name or ""
      if #display_name > max_name_w then
        display_name = display_name:sub(1, max_name_w - 3) .. "..."
      end

      local row_str = prefix .. display_name .. suffix
      add_line(row_str, "item_row", {
        item = it,
        name = display_name,
        short_id = it.short_id,
        status_str = status_str,
        kind = it.kind,
        status = it.status,
      })
      row_to_task[#lines - 1] = it
    end

    add_line("", "empty")
    local summary_str = string.format("  Total: %d (%d subagents, %d tasks)", #items, subagent_count, task_count)
    add_line(summary_str, "summary")
    add_line("", "empty")
  end

  local nav_text = "enter View · k Kill · r Refresh · q Close"
  add_line(panel.format_footer(nav_text, "", width), "footer", { text = nav_text })

  return lines, meta, row_to_task
end

---Apply syntax and semantic highlighting to the tasks & subagents bottom panel
---@param buf number
---@param meta table[]
function M.apply_highlights(buf, meta)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not meta then return end
  vim.api.nvim_buf_clear_namespace(buf, M.NS_TASKS, 0, -1)

  for _, m in ipairs(meta) do
    local row = m.row
    local l_type = m.type
    local line_str = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""

    if l_type == "title" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_TASKS, row, 0, {
        end_col = #line_str,
        hl_group = "AgyTaskTitle",
      })

    elseif l_type == "border" or l_type == "comment" or l_type == "empty_notice" or l_type == "summary" then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_TASKS, row, 0, {
        end_col = #line_str,
        hl_group = "Comment",
      })

    elseif l_type == "item_row" then
      local extra = m.extra or {}
      local it = extra.item or {}
      local status = extra.status or it.status

      local status_hl = "AgyTaskRunning"
      if status == "success" or status == "done" or status == "completed" then
        status_hl = "AgyTaskSuccess"
      elseif status == "failed" or status == "error" or status == "killed" then
        status_hl = "AgyTaskFailed"
      end

      -- Highlight bullet
      local bullet_pos = line_str:find("%S")
      if bullet_pos then
        pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_TASKS, row, bullet_pos - 1, {
          end_col = bullet_pos + 2,
          hl_group = status_hl,
        })
      end

      -- Highlight ID in parentheses: e.g. (short_id)
      if it.short_id then
        local id_start, id_end = line_str:find("%(" .. vim.pesc(it.short_id) .. "%)")
        if id_start and id_end then
          pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_TASKS, row, id_start, {
            end_col = id_end - 1,
            hl_group = "AgyTaskId",
          })
        end
      end

      -- Highlight status string at end of line
      if extra.status_str then
        local s_stat, e_stat = line_str:find(vim.pesc(extra.status_str) .. "$")
        if s_stat and e_stat then
          pcall(vim.api.nvim_buf_set_extmark, buf, M.NS_TASKS, row, s_stat - 1, {
            end_col = e_stat,
            hl_group = status_hl,
          })
        end
      end

    elseif l_type == "footer" then
      local extra = m.extra or {}
      panel.apply_footer_highlights(buf, M.NS_TASKS, row, extra.text or line_str)
    end
  end
end

---Open interactive background tasks and subagents panel in the lower area below active prompt
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
  local cfg = (pstate and pstate.config) or require("agy.config").get()

  local win_w = vim.api.nvim_win_get_width(target_win)
  local width = math.max(80, win_w - 4)

  local session = (pstate and pstate.session) or {}
  local conv_id = (pstate and pstate.conversation_id) or session.conversation_id or "new"

  local lines, meta, row_to_task = M.build_content(pstate, cfg, width)

  local keymaps = {
    ["<CR>"] = function()
      local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local item = row_to_task[cur_row]
      if not item then return end

      if item.kind == "subagent" then
        panel.close()
        pcall(vim.api.nvim_set_current_win, target_win)
        vim.cmd("edit " .. vim.fn.fnameescape("agy://" .. conv_id .. "/subagent/" .. item.subagent_id))
      elseif item.kind == "task" then
        if item.log_path and vim.fn.filereadable(item.log_path) == 1 then
          panel.close()
          pcall(vim.api.nvim_set_current_win, target_win)
          vim.cmd("split " .. vim.fn.fnameescape(item.log_path))
        elseif item.tool_rec and item.tool_rec.output then
          vim.notify("[agy.nvim] " .. item.short_id .. ":\n" .. tostring(item.tool_rec.output):sub(1, 400), vim.log.levels.INFO)
        else
          vim.notify("[agy.nvim] No log file available for " .. item.short_id, vim.log.levels.INFO)
        end
      end
    end,
    ["k"] = function()
      local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local item = row_to_task[cur_row]
      if not item then return end

      if item.kind == "subagent" then
        if item.status == "running" or item.status == "alive" then
          subagents_mod.kill_subagent(conv_id, item.subagent_id, cfg.app_data_dir, pstate)
          item.status = "killed"
          vim.notify("[agy.nvim] Terminated subagent: " .. (item.role or item.short_id), vim.log.levels.INFO)
          local new_lines, new_meta, new_rtt = M.build_content(pstate, cfg, width)
          row_to_task = new_rtt
          panel.update(new_lines, new_meta)
        else
          vim.notify("[agy.nvim] Selected subagent is not running", vim.log.levels.INFO)
        end
      elseif item.kind == "task" then
        if item.status == "running" then
          item.status = "failed"
          item.exit_code = 130
          if item.tool_rec then
            item.tool_rec.task_status = "failed"
            item.tool_rec.exit_code = 130
            pcall(function()
              local render_mod = require("agy.render")
              render_mod.update_task_status(caller_buf, item.tool_rec, "failed", 130)
            end)
          end
          vim.notify("[agy.nvim] Terminated background task: " .. item.short_id, vim.log.levels.INFO)
          local new_lines, new_meta, new_rtt = M.build_content(pstate, cfg, width)
          row_to_task = new_rtt
          panel.update(new_lines, new_meta)
        else
          vim.notify("[agy.nvim] Selected task is not running", vim.log.levels.INFO)
        end
      end
    end,
    ["r"] = function()
      local new_lines, new_meta, new_rtt = M.build_content(pstate, cfg, width)
      row_to_task = new_rtt
      panel.update(new_lines, new_meta)
      vim.notify("[agy.nvim] Tasks & subagents refreshed", vim.log.levels.INFO)
    end,
  }

  local p_win, p_buf = panel.open({
    target_win = target_win,
    target_buf = caller_buf,
    lines = lines,
    meta = meta,
    apply_highlights = M.apply_highlights,
    filetype = "agy_tasks",
    max_height = 14,
    keymaps = keymaps,
  })

  return p_win, p_buf
end

return M
