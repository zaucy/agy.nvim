local utils = require("agy.utils")
local transcript_mod = require("agy.transcript")
local render = require("agy.render")
local config_mod = require("agy.config")

local M = {}

M.NS_SUBAGENTS = vim.api.nvim_create_namespace("agy_subagents")
M.NS_SUBAGENT_FOOTER = vim.api.nvim_create_namespace("agy_subagent_footer")

---@type table<number, any>
M.active_watchers = {}

---Extract a short human-readable identifier for a subagent (first 8 chars of UUID)
---@param subagent_id? string
---@return string
function M.short_id(subagent_id)
  assert(subagent_id and subagent_id ~= "", "agy subagents: subagent_id required")
  return subagent_id:sub(1, 8)
end

---Extract a concise human-readable description of what a subagent is currently doing
---@param steps table[]
---@return string? action
function M.extract_current_action(steps)
  if not steps or #steps == 0 then return nil end

  local last_step = steps[#steps]

  if last_step.type == "PLANNER_RESPONSE" and last_step.tool_calls and #last_step.tool_calls > 0 then
    local tc = last_step.tool_calls[#last_step.tool_calls]
    local act = nil
    if tc.args and type(tc.args) == "table" then
      act = tc.args.toolAction or tc.args.toolSummary or tc.args.Description
      if not act and tc.args.CommandLine then
        local cmd = tostring(tc.args.CommandLine):gsub('^["\']', ''):gsub('["\']$', '')
        act = cmd:match("^%s*([^%s\r\n]+)")
      end
    end
    if not act or act == "" then
      act = tc.name
    end
    if act and act ~= "" then
      act = act:gsub('^["\']', ''):gsub('["\']$', '')
      if #act > 32 then
        act = act:sub(1, 29) .. "..."
      end
      return act
    end
  end

  if last_step.type == "GENERIC" or last_step.type == "tool" then
    if last_step.content and tostring(last_step.content):find("Message sent to") then
      return nil
    end
    return "Thinking..."
  end

  if last_step.thinking and type(last_step.thinking) == "string" and last_step.thinking ~= "" then
    return "Thinking..."
  end

  if last_step.type == "USER_INPUT" or last_step.type == "SYSTEM_MESSAGE" then
    return "Starting..."
  end

  return nil
end

---Parse subagents from parent conversation transcript steps
---@param steps table[]
---@return table<string, table> subagents_map
---@return number last_user_turn_idx
---@return table<string, number> last_sent_step
---@return table<string, number> last_replied_step
---@return table<string, boolean> killed_subs
function M.parse_subagents_from_steps(steps)
  local subagents_map = {}
  local last_user_turn_idx = 0
  local last_sent_step = {}
  local last_replied_step = {}
  local killed_subs = {}

  if not steps or #steps == 0 then
    return subagents_map, last_user_turn_idx, last_sent_step, last_replied_step, killed_subs
  end

  for i, step in ipairs(steps) do
    local step_idx = step.step_index or i
    if step.type == "USER_INPUT" or step.source == "USER_EXPLICIT" then
      last_user_turn_idx = step_idx
    end

    -- Check if parent received a message from a subagent
    local content = step.content or ""
    if content ~= "" then
      local sender_id = content:match("sender=([%w%-_]+)")
      if sender_id then
        last_replied_step[sender_id] = step_idx
        if #sender_id >= 8 then
          last_replied_step[sender_id:sub(1, 8)] = step_idx
        end
      end
    end

    if step.sender and type(step.sender) == "string" and step.sender ~= "" then
      last_replied_step[step.sender] = step_idx
      if #step.sender >= 8 then
        last_replied_step[step.sender:sub(1, 8)] = step_idx
      end
    end

    -- Check step.tool_calls
    if step.tool_calls then
      for _, tc in ipairs(step.tool_calls) do
        if tc.name == "invoke_subagent" then
          local next_step = steps[i + 1]
          local output = tc.output or (next_step and next_step.content) or ""
          local sid = output:match('"conversationId":%s*"([^"]+)"')
            or output:match('conversationId:%s*([%w%-_]+)')

          local args = tc.args or {}
          local sub_args_list = {}
          if type(args.Subagents) == "string" then
            local ok, parsed = pcall(vim.json.decode, args.Subagents)
            if ok and type(parsed) == "table" then
              sub_args_list = parsed
            end
          elseif type(args.Subagents) == "table" then
            sub_args_list = args.Subagents
          end

          local first_sub = sub_args_list[1] or {}
          local role = first_sub.Role or first_sub.role or first_sub.TypeName or first_sub.typeName or "Subagent"
          local type_name = first_sub.TypeName or first_sub.typeName or "self"
          local prompt = first_sub.Prompt or first_sub.prompt

          if sid then
            subagents_map[sid] = {
              subagent_id = sid,
              short_id = M.short_id(sid),
              role = role,
              name = role,
              type_name = type_name,
              status = "running",
              spawn_step_index = step_idx,
              order_key = step_idx,
              prompt = prompt,
            }
            last_sent_step[sid] = step_idx
            last_sent_step[M.short_id(sid)] = step_idx
          end
        end

        if tc.name == "send_message" then
          local args = tc.args or {}
          local rcpt = args.Recipient
          if rcpt and type(rcpt) == "string" then
            rcpt = rcpt:gsub('^["\']', ''):gsub('["\']$', '')
            last_sent_step[rcpt] = step_idx
            if #rcpt >= 8 then
              last_sent_step[rcpt:sub(1, 8)] = step_idx
            end
          end
        end

        if tc.name == "manage_subagents" then
          local args = tc.args or {}
          if args.Action == "kill" and type(args.ConversationIds) == "table" then
            for _, kid in ipairs(args.ConversationIds) do
              killed_subs[kid] = true
              if subagents_map[kid] then
                subagents_map[kid].status = "killed"
              end
            end
          end
        end
      end
    end

    -- Check direct tool call steps
    if step.type == "TOOL_CALL" or step.type == "tool" then
      local tname = step.name or (step.tool_info and step.tool_info.name)
      if tname == "invoke_subagent" then
        local next_step = steps[i + 1]
        local output = step.output or (next_step and next_step.content) or ""
        local sid = output:match('"conversationId":%s*"([^"]+)"')
          or output:match('conversationId:%s*([%w%-_]+)')

        local args = step.args or (step.tool_info and step.tool_info.parameters) or {}
        local sub_args_list = {}
        if type(args.Subagents) == "string" then
          local ok, parsed = pcall(vim.json.decode, args.Subagents)
          if ok and type(parsed) == "table" then
            sub_args_list = parsed
          end
        elseif type(args.Subagents) == "table" then
          sub_args_list = args.Subagents
        end

        local first_sub = sub_args_list[1] or {}
        local role = first_sub.Role or first_sub.role or first_sub.TypeName or first_sub.typeName or "Subagent"
        local type_name = first_sub.TypeName or first_sub.typeName or "self"
        local prompt = first_sub.Prompt or first_sub.prompt

        if sid then
          subagents_map[sid] = {
            subagent_id = sid,
            short_id = M.short_id(sid),
            role = role,
            name = role,
            type_name = type_name,
            status = "running",
            spawn_step_index = step_idx,
            order_key = step_idx,
            prompt = prompt,
          }
          last_sent_step[sid] = step_idx
          last_sent_step[M.short_id(sid)] = step_idx
        end
      end

      if tname == "send_message" then
        local args = step.args or (step.tool_info and step.tool_info.parameters) or {}
        local rcpt = args.Recipient
        if rcpt and type(rcpt) == "string" then
          rcpt = rcpt:gsub('^["\']', ''):gsub('["\']$', '')
          last_sent_step[rcpt] = step_idx
          if #rcpt >= 8 then
            last_sent_step[rcpt:sub(1, 8)] = step_idx
          end
        end
      end
    end
  end

  for sid, entry in pairs(subagents_map) do
    if killed_subs[sid] then
      entry.status = "killed"
    elseif last_replied_step[sid] and last_replied_step[sid] >= (last_sent_step[sid] or 0) then
      entry.status = "completed"
      entry.current_action = nil
    end
  end

  return subagents_map, last_user_turn_idx, last_sent_step, last_replied_step, killed_subs
end

---Collect all subagents for a conversation (from disk metadata, transcript, and in-memory state)
---@param conv_id string
---@param app_data_dir? string
---@param pstate? table
---@return table[] subagents
function M.collect_subagents(conv_id, app_data_dir, pstate)
  assert(conv_id and conv_id ~= "", "agy subagents: conv_id is required")
  local subagents = {}
  local seen = {}

  local is_turn_active = false
  if pstate then
    if pstate.session and pstate.session.turn_active then
      is_turn_active = true
    elseif pstate.stream_info and (pstate.stream_info.status == "generating" or pstate.stream_info.status == "thinking" or (type(pstate.stream_info.status) == "string" and pstate.stream_info.status:find("^tool:"))) then
      is_turn_active = true
    end
  end

  local parent_steps = (conv_id ~= "new") and transcript_mod.read_transcript(conv_id, app_data_dir) or {}
  local from_steps, last_user_turn_idx, last_sent_step, last_replied_step, killed_subs = M.parse_subagents_from_steps(parent_steps)

  local subagents_map = {}

  -- 1. Scan .system_generated/subagents/*.json on disk
  local subagents_dir = utils.get_brain_dir(app_data_dir) .. "/" .. conv_id .. "/.system_generated/subagents"
  if vim.fn.isdirectory(subagents_dir) == 1 then
    local handle = vim.uv.fs_scandir(subagents_dir)
    if handle then
      while true do
        local name, ftype = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if ftype == "file" and name:match("%.json$") then
          local full_path = vim.fs.normalize(subagents_dir .. "/" .. name)
          local content = vim.fn.readfile(full_path)
          if content and #content > 0 then
            local raw = table.concat(content, "\n")
            local ok, parsed = pcall(vim.json.decode, raw)
            if ok and parsed and parsed.conversationId then
              local sid = parsed.conversationId
              local desc = parsed.subagentDescriptor or {}
              local role = desc.role or desc.typeName or "Subagent"
              local type_name = desc.typeName or "self"
              local state_str = parsed.state or "SUBAGENT_STATE_ALIVE"
              local step_idx = parsed.spawnStepIndex or 0
              local is_killed = (state_str == "SUBAGENT_STATE_KILLED" or killed_subs[sid] == true)

              local status = "completed"
              local current_action = nil

              if is_killed then
                status = "killed"
              elseif not is_turn_active then
                -- When no turn is actively running, all living subagents are completed
                status = "completed"
              else
                -- Turn IS active: check if subagent belongs to previous turn or already replied
                local was_contacted = (last_sent_step[sid] and last_sent_step[sid] >= last_user_turn_idx)
                if step_idx < last_user_turn_idx and not was_contacted then
                  status = "completed"
                elseif last_replied_step[sid] and last_replied_step[sid] >= (last_sent_step[sid] or 0) then
                  status = "completed"
                else
                  -- Active in current turn: inspect subagent transcript
                  local sub_log = utils.get_brain_dir(app_data_dir) .. "/" .. sid .. "/.system_generated/logs/transcript.jsonl"
                  if vim.fn.filereadable(sub_log) == 1 then
                    local sub_steps = transcript_mod.read_transcript(sid, app_data_dir)
                    if #sub_steps > 0 then
                      local last_step = sub_steps[#sub_steps]
                      if last_step.type == "PLANNER_RESPONSE" then
                        if not last_step.tool_calls or #last_step.tool_calls == 0 then
                          status = "completed"
                        else
                          local is_send_msg_to_parent = false
                          for _, tc in ipairs(last_step.tool_calls) do
                            if tc.name == "send_message" then
                              local rcpt = tc.args and tc.args.Recipient
                              if rcpt and (rcpt:find(conv_id, 1, true) or conv_id:find(rcpt, 1, true)) then
                                is_send_msg_to_parent = true
                                break
                              end
                            end
                          end
                          if is_send_msg_to_parent then
                            status = "completed"
                          else
                            status = "running"
                            current_action = M.extract_current_action(sub_steps)
                          end
                        end
                      elseif last_step.type == "GENERIC" then
                        if last_step.content and tostring(last_step.content):find("Message sent to") then
                          status = "completed"
                        else
                          status = "running"
                          current_action = M.extract_current_action(sub_steps)
                        end
                      elseif last_step.status == "ERROR" then
                        status = "failed"
                      else
                        status = "running"
                        current_action = M.extract_current_action(sub_steps)
                      end
                    else
                      status = "running"
                      current_action = "Starting..."
                    end
                  else
                    status = "running"
                    current_action = "Starting..."
                  end
                end
              end

              local transcript_path = vim.fs.normalize(utils.get_brain_dir(app_data_dir) .. "/" .. sid .. "/.system_generated/logs/transcript.jsonl")

              subagents_map[sid] = {
                kind = "subagent",
                subagent_id = sid,
                short_id = M.short_id(sid),
                role = role,
                name = role,
                type_name = type_name,
                status = status,
                state = state_str,
                current_action = current_action,
                spawn_step_index = step_idx,
                order_key = step_idx,
                parent_conv_id = conv_id,
                transcript_path = transcript_path,
                workspace_uris = parsed.workspaceUris or {},
              }
            end
          end
        end
      end
    end
  end

  -- 2. Scan parent conversation transcript on disk for subagents not in .json files
  for sid, entry in pairs(from_steps) do
    if not subagents_map[sid] then
      entry.kind = "subagent"
      entry.parent_conv_id = conv_id
      entry.transcript_path = vim.fs.normalize(utils.get_brain_dir(app_data_dir) .. "/" .. sid .. "/.system_generated/logs/transcript.jsonl")
      if entry.status ~= "killed" then
        if not is_turn_active then
          entry.status = "completed"
          entry.current_action = nil
        else
          local was_contacted = (last_sent_step[sid] and last_sent_step[sid] >= last_user_turn_idx)
          if (entry.spawn_step_index or 0) < last_user_turn_idx and not was_contacted then
            entry.status = "completed"
            entry.current_action = nil
          elseif last_replied_step[sid] and last_replied_step[sid] >= (last_sent_step[sid] or 0) then
            entry.status = "completed"
            entry.current_action = nil
          elseif entry.status == "running" and vim.fn.filereadable(entry.transcript_path) == 1 then
            local sub_steps = transcript_mod.read_transcript(sid, app_data_dir)
            if #sub_steps > 0 then
              local last_step = sub_steps[#sub_steps]
              if last_step.type == "PLANNER_RESPONSE" and (not last_step.tool_calls or #last_step.tool_calls == 0) then
                entry.status = "completed"
                entry.current_action = nil
              elseif last_step.type == "GENERIC" and last_step.content and tostring(last_step.content):find("Message sent to") then
                entry.status = "completed"
                entry.current_action = nil
              elseif last_step.status == "ERROR" then
                entry.status = "failed"
                entry.current_action = nil
              else
                entry.current_action = M.extract_current_action(sub_steps)
              end
            end
          end
        end
      end
      subagents_map[sid] = entry
    else
      -- Merge prompt or role if missing
      if not subagents_map[sid].prompt and entry.prompt then
        subagents_map[sid].prompt = entry.prompt
      end
      if subagents_map[sid].role == "Subagent" and entry.role ~= "Subagent" then
        subagents_map[sid].role = entry.role
        subagents_map[sid].name = entry.role
      end
    end
  end

  -- 3. Check in-memory tool calls from active buffer state (only during active turn)
  if is_turn_active and pstate and pstate.tool_calls then
    for _, tc in ipairs(pstate.tool_calls) do
      if (tc.tool_name == "invoke_subagent" or tc.name == "invoke_subagent") and tc.output then
        local sid = tostring(tc.output):match('"conversationId":%s*"([^"]+)"')
          or tostring(tc.output):match('conversationId:%s*([%w%-_]+)')
        if sid and not subagents_map[sid] then
          local p = tc.params or tc.args or {}
          local sub_list = {}
          if type(p.Subagents) == "string" then
            local ok, parsed = pcall(vim.json.decode, p.Subagents)
            if ok and type(parsed) == "table" then sub_list = parsed end
          elseif type(p.Subagents) == "table" then
            sub_list = p.Subagents
          end
          local first_sub = sub_list[1] or {}
          local role = first_sub.Role or first_sub.role or first_sub.TypeName or first_sub.typeName or "Subagent"
          subagents_map[sid] = {
            kind = "subagent",
            subagent_id = sid,
            short_id = M.short_id(sid),
            role = role,
            name = role,
            type_name = first_sub.TypeName or first_sub.typeName or "self",
            status = "running",
            current_action = "Starting...",
            spawn_step_index = 999999,
            order_key = 999999,
            parent_conv_id = conv_id,
            transcript_path = vim.fs.normalize(utils.get_brain_dir(app_data_dir) .. "/" .. sid .. "/.system_generated/logs/transcript.jsonl"),
            prompt = first_sub.Prompt or first_sub.prompt,
          }
        end
      end
    end
  end

  for _, item in pairs(subagents_map) do
    if not seen[item.subagent_id] then
      seen[item.subagent_id] = true
      table.insert(subagents, item)
    end
  end

  return subagents
end

---Kill/terminate an active subagent
---@param conv_id string
---@param subagent_id string
---@param app_data_dir? string
---@param pstate? table
function M.kill_subagent(conv_id, subagent_id, app_data_dir, pstate)
  assert(conv_id and conv_id ~= "", "agy subagents: conv_id required")
  assert(subagent_id and subagent_id ~= "", "agy subagents: subagent_id required")
  local meta_path = utils.get_brain_dir(app_data_dir) .. "/" .. conv_id .. "/.system_generated/subagents/" .. subagent_id .. ".json"
  if vim.fn.filereadable(meta_path) == 1 then
    local content = vim.fn.readfile(meta_path)
    if content and #content > 0 then
      local raw = table.concat(content, "\n")
      local ok, parsed = pcall(vim.json.decode, raw)
      if ok and parsed then
        parsed.state = "SUBAGENT_STATE_KILLED"
        local encoded = vim.json.encode(parsed)
        vim.fn.writefile({ encoded }, meta_path)
      end
    end
  end

  if pstate then
    if pstate.subagents then
      for _, s in ipairs(pstate.subagents) do
        if s.subagent_id == subagent_id or (s.short_id and s.short_id == subagent_id:sub(1, 8)) then
          s.status = "killed"
          s.state = "SUBAGENT_STATE_KILLED"
          s.current_action = nil
        end
      end
    end
    if pstate.in_flight_subagents then
      for _, s in ipairs(pstate.in_flight_subagents) do
        if s.subagent_id == subagent_id or (s.short_id and s.short_id == subagent_id:sub(1, 8)) then
          s.status = "killed"
          s.state = "SUBAGENT_STATE_KILLED"
          s.current_action = nil
        end
      end
    end
  end
end

---Render virtual footer line on subagent inspection buffer
---@param buf number
---@param config? table
function M.render_footer(buf, config)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, M.NS_SUBAGENT_FOOTER, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(buf)
  local last_row = math.max(0, line_count - 1)
  local chunks = {
    { "r Refresh · - Back to parent conversation", "AgyPromptFooter" },
  }
  vim.api.nvim_buf_set_extmark(buf, M.NS_SUBAGENT_FOOTER, last_row, 0, {
    virt_lines = { chunks },
    virt_lines_above = false,
    priority = 100,
  })
end

---Start live file watcher on subagent transcript.jsonl
---@param buf number
---@param parent_conv_id string
---@param subagent_id string
---@param cfg table
function M.start_watcher(buf, parent_conv_id, subagent_id, cfg)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  M.stop_watcher(buf)

  local logs_dir = utils.get_brain_dir(cfg.app_data_dir) .. "/" .. subagent_id .. "/.system_generated/logs"
  if vim.fn.isdirectory(logs_dir) ~= 1 then
    return
  end

  local fs_event = vim.uv.new_fs_event()
  if not fs_event then return end

  local debounce_timer = nil
  fs_event:start(logs_dir, {}, function(err, filename, events)
    if err then return end
    if filename == "transcript.jsonl" or filename == "transcript_full.jsonl" then
      if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
      end
      debounce_timer = vim.uv.new_timer()
      debounce_timer:start(50, 0, function()
        if debounce_timer then
          debounce_timer:stop()
          debounce_timer:close()
          debounce_timer = nil
        end
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            M.render_subagent(buf, parent_conv_id, subagent_id, cfg)
          end
        end)
      end)
    end
  end)

  M.active_watchers[buf] = fs_event

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = buf,
    once = true,
    callback = function()
      M.stop_watcher(buf)
    end,
  })
end

---Stop live file watcher on buffer
---@param buf number
function M.stop_watcher(buf)
  if M.active_watchers[buf] then
    pcall(function()
      M.active_watchers[buf]:stop()
      M.active_watchers[buf]:close()
    end)
    M.active_watchers[buf] = nil
  end
end

---Navigate up one level from subagent buffer back to parent conversation
---@param buf number
---@param parent_conv_id string
function M.go_up(buf, parent_conv_id)
  assert(parent_conv_id and parent_conv_id ~= "", "agy subagents: parent_conv_id is required")
  M.stop_watcher(buf)
  vim.cmd("edit " .. vim.fn.fnameescape("agy://" .. parent_conv_id))
end

---Render subagent inspection buffer (agy://<parent_conv_id>/subagent/<subagent_id>)
---@param buf number
---@param parent_conv_id string
---@param subagent_id string
---@param config? table
function M.render_subagent(buf, parent_conv_id, subagent_id, config)
  assert(buf and vim.api.nvim_buf_is_valid(buf), "agy subagents: valid buffer required")
  assert(parent_conv_id and parent_conv_id ~= "", "agy subagents: parent_conv_id required")
  assert(subagent_id and subagent_id ~= "", "agy subagents: subagent_id required")

  local cfg = config or config_mod.get()
  assert(cfg, "agy subagents: config required")
  assert(cfg.icons, "agy subagents: config.icons required")
  assert(cfg.icons.subagent, "agy subagents: config.icons.subagent required")

  local sub_dir = utils.get_brain_dir(cfg.app_data_dir) .. "/" .. parent_conv_id .. "/.system_generated/subagents"
  local meta_path = sub_dir .. "/" .. subagent_id .. ".json"
  local role = "Subagent"
  local type_name = "self"
  local state_str = "SUBAGENT_STATE_ALIVE"
  if vim.fn.filereadable(meta_path) == 1 then
    local content = vim.fn.readfile(meta_path)
    if content and #content > 0 then
      local ok, parsed = pcall(vim.json.decode, table.concat(content, "\n"))
      if ok and parsed then
        local desc = parsed.subagentDescriptor or {}
        role = desc.role or desc.typeName or role
        type_name = desc.typeName or type_name
        state_str = parsed.state or state_str
      end
    end
  end

  local session_uri = "agy://" .. parent_conv_id .. "/subagent/" .. subagent_id
  local sub_text = "Role: " .. role

  local steps = transcript_mod.read_transcript(subagent_id, cfg.app_data_dir)

  vim.bo[buf].modifiable = true
  if #steps > 0 then
    local _, p_extmark_id = render.render_transcript(buf, subagent_id, steps, cfg, nil, {
      session_uri = session_uri,
      sub_text = sub_text,
      is_subagent = true,
    })
    -- For read-only subagent buffer, clear the active prompt divider extmark
    if p_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, buf, render.NS_UI, p_extmark_id)
    end
  else
    render.init_session_buffer(buf, session_uri, cfg, sub_text)
    local lc = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, lc - 1, lc, false, {
      "  Waiting for subagent output...",
      "",
    })
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "agy"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modified = false

  -- Keymaps: '-' to return, 'r' to refresh
  vim.keymap.set("n", "-", function()
    M.go_up(buf, parent_conv_id)
  end, { buffer = buf, silent = true, desc = "Return to parent conversation" })

  vim.keymap.set("n", "r", function()
    M.render_subagent(buf, parent_conv_id, subagent_id, cfg)
    vim.notify("[agy.nvim] Subagent transcript refreshed", vim.log.levels.INFO)
  end, { buffer = buf, silent = true, desc = "Refresh subagent transcript" })

  M.render_footer(buf, cfg)
  M.start_watcher(buf, parent_conv_id, subagent_id, cfg)
end

return M
