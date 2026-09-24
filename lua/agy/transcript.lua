local utils = require("agy.utils")

local M = {}

M.clean_user_content = utils.clean_user_content

local function sanitize_args(args)
  if not args or type(args) ~= "table" then return args end
  local cleaned = {}
  for k, v in pairs(args) do
    if type(v) == "string" then
      local unquoted = v:match('^"(.*)"$')
      if unquoted then
        cleaned[k] = unquoted
      else
        cleaned[k] = v
      end
    elseif type(v) == "table" then
      cleaned[k] = sanitize_args(v)
    else
      cleaned[k] = v
    end
  end
  return cleaned
end

local function sanitize_step(step)
  if not step then return step end
  if step.args then
    step.args = sanitize_args(step.args)
  end
  if step.tool_info and step.tool_info.parameters then
    step.tool_info.parameters = sanitize_args(step.tool_info.parameters)
  end
  if step.tool_calls then
    for _, tc in ipairs(step.tool_calls) do
      if tc.args then
        tc.args = sanitize_args(tc.args)
      end
    end
  end
  return step
end

---Read and parse the transcript for a given conversation ID
---@param conversation_id string
---@param app_data_dir? string
---@return table[] steps List of parsed transcript steps
function M.read_transcript(conversation_id, app_data_dir)
  local transcript_file = utils.get_transcript_file(conversation_id, app_data_dir)
  local is_legacy = (transcript_file:match("transcript_full%.jsonl$") == nil)
  local f = io.open(transcript_file, "r")
  if not f then
    -- Try reading chunk files if main transcript is not directly present (prefer chunks/transcript_full)
    local brain = utils.get_brain_dir(app_data_dir) .. "/" .. conversation_id .. "/.system_generated/logs/chunks"
    local chunks_dir = brain .. "/transcript_full"
    local is_chunk_legacy = false
    local handle = vim.uv.fs_scandir(chunks_dir)
    if not handle then
      chunks_dir = brain .. "/transcript"
      is_chunk_legacy = true
      handle = vim.uv.fs_scandir(chunks_dir)
    end
    local steps = {}
    if handle then
      local chunk_files = {}
      while true do
        local name, ftype = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if ftype == "file" and name:match("%.jsonl$") then
          table.insert(chunk_files, name)
        end
      end
      table.sort(chunk_files)
      for _, file in ipairs(chunk_files) do
        local chunk_f = io.open(chunks_dir .. "/" .. file, "r")
        if chunk_f then
          for line in chunk_f:lines() do
            if line ~= "" then
              local step = utils.json_decode(line)
              if step then
                if is_chunk_legacy then
                  step = sanitize_step(step)
                end
                if step.type == "USER_INPUT" and step.content then
                  step.display_content = M.clean_user_content(step.content)
                end
                table.insert(steps, step)
              end
            end
          end
          chunk_f:close()
        end
      end
    end
    return steps
  end

  local steps = {}
  for line in f:lines() do
    if line ~= "" then
      local step = utils.json_decode(line)
      if step then
        if is_legacy then
          step = sanitize_step(step)
        end
        if step.type == "USER_INPUT" and step.content then
          step.display_content = M.clean_user_content(step.content)
        end
        table.insert(steps, step)
      end
    end
  end
  f:close()

  return steps
end

---Extract the active model from parsed transcript steps
---Scans through steps in order to find the latest Model Selection setting or /model command
---@param steps table[]
---@return string|nil model_name
function M.extract_model_from_steps(steps)
  if not steps or #steps == 0 then return nil end
  local found_model = nil

  for _, step in ipairs(steps) do
    if step.type == "USER_INPUT" and step.content then
      -- Check for <USER_SETTINGS_CHANGE>
      local setting_change = step.content:match("<USER_SETTINGS_CHANGE>%s*(.-)%s*</USER_SETTINGS_CHANGE>")
      if setting_change then
        local raw_model = setting_change:match("Model Selection.- from .- to%s+(.-)%.%s+No need")
          or setting_change:match("Model Selection.- to%s+([^\r\n]+)")
        if raw_model then
          raw_model = raw_model:gsub("%.%s*$", ""):gsub("%s+", " "):gsub("^%s*", ""):gsub("%s*$", "")
          if raw_model ~= "" and raw_model:lower() ~= "none" then
            found_model = raw_model
          end
        end
      end

      -- Check for explicit /model slash command
      local raw_prompt = step.display_content or step.content
      local model_cmd = raw_prompt:match("^/model%s+(%S+)")
      if model_cmd then
        found_model = model_cmd
      end
    end
  end

  return found_model
end

---Get the active model for a conversation ID from its transcript
---@param conversation_id string
---@param app_data_dir? string
---@return string|nil model_name
function M.get_conversation_model(conversation_id, app_data_dir)
  local steps = M.read_transcript(conversation_id, app_data_dir)
  return M.extract_model_from_steps(steps)
end

---@class AgyConversationSummary
---@field conversation_id string
---@field title string
---@field last_prompt string
---@field timestamp number
---@field workspace string
---@field relative_time string

---Read recent conversation history from history.jsonl
---@param app_data_dir? string
---@return AgyConversationSummary[]
function M.read_history(app_data_dir)
  local history_file = utils.get_history_file(app_data_dir)
  local f = io.open(history_file, "r")
  if not f then
    return {}
  end

  local map = {}
  for line in f:lines() do
    if line ~= "" then
      local entry = utils.json_decode(line)
      if entry and entry.conversationId and entry.conversationId ~= "" then
        local id = entry.conversationId
        local prev = map[id]
        local ts = entry.timestamp or 0
        if not prev or (ts > prev.timestamp) then
          map[id] = {
            conversation_id = id,
            title = entry.display or "Conversation " .. id:sub(1, 8),
            last_prompt = entry.display or "",
            timestamp = ts,
            workspace = entry.workspace or "",
            relative_time = utils.format_relative_time(ts),
          }
        end
      end
    end
  end
  f:close()

  local list = {}
  for _, item in pairs(map) do
    table.insert(list, item)
  end

  -- Sort descending by timestamp
  table.sort(list, function(a, b)
    return a.timestamp > b.timestamp
  end)

  return list
end

---Get the workspace directory recorded for a conversation from history.jsonl
---@param conversation_id string
---@param app_data_dir? string
---@return string?
function M.get_conversation_workspace(conversation_id, app_data_dir)
  if not conversation_id or conversation_id == "" or conversation_id == "new" then
    return nil
  end
  local history_file = utils.get_history_file(app_data_dir)
  local f = io.open(history_file, "r")
  if not f then return nil end

  local ws = nil
  for line in f:lines() do
    if line ~= "" and line:find(conversation_id, 1, true) then
      local entry = utils.json_decode(line)
      if entry and entry.conversationId == conversation_id and entry.workspace and entry.workspace ~= "" then
        ws = entry.workspace
      end
    end
  end
  f:close()
  return ws
end

---Append a conversation entry to history.jsonl
---@param entry { conversation_id: string, workspace: string, display?: string, timestamp?: number }
---@param app_data_dir? string
---@return boolean success
function M.append_history(entry, app_data_dir)
  assert(entry, "append_history: entry table required")
  assert(entry.conversation_id and entry.conversation_id ~= "" and entry.conversation_id ~= "new", "append_history: valid conversation_id required")
  assert(entry.workspace and entry.workspace ~= "", "append_history: valid workspace required")

  local history_file = utils.get_history_file(app_data_dir)
  pcall(vim.fn.mkdir, vim.fs.dirname(history_file), "p")

  local f = io.open(history_file, "a")
  if not f then
    return false
  end

  local ts = entry.timestamp
  if not ts then
    local sec, usec = vim.uv.gettimeofday()
    ts = math.floor(sec * 1000 + (usec or 0) / 1000)
  end

  local item = {
    conversationId = entry.conversation_id,
    display = entry.display or "",
    timestamp = ts,
    workspace = entry.workspace,
  }

  f:write(utils.json_encode(item) .. "\n")
  f:close()
  return true
end

return M
