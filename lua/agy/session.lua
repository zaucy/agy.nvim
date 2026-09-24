local utils = require("agy.utils")

local M = {}
M.__index = M

---@class AgySessionOpts
---@field conversation_id? string Existing conversation ID to resume
---@field agy_cmd? string Command to run agy CLI (default "agy")
---@field mode? string Optional agent mode (e.g. "accept-edits" or "plan")
---@field effort? string Optional reasoning effort (e.g. "low", "medium", "high")
---@field model? string Optional active LLM model ID
---@field cwd? string Working directory for agy CLI
---@field workspaces? string[] Workspace directories to register with agy CLI (defaults to { cwd })
---@field client_instructions? boolean Whether to automatically inject client protocol instructions for planning and questions (default: true)
---@field on_init? fun(session: AgySession, conv_id: string, payload: table)
---@field on_step_update? fun(session: AgySession, step: table)
---@field on_result? fun(session: AgySession, result: table)
---@field on_error? fun(session: AgySession, err: string)
---@field on_exit? fun(session: AgySession, code: number)

---@class AgySession
---@field conversation_id? string
---@field proc? vim.SystemObj
---@field agy_cmd string
---@field mode? string
---@field effort? string
---@field model? string
---@field cwd string
---@field workspaces string[]
---@field client_instructions boolean
---@field is_active boolean
---@field turn_active boolean
---@field line_buffer string
---@field on_init fun(session: AgySession, conv_id: string, payload: table)
---@field on_step_update fun(session: AgySession, step: table)
---@field on_result fun(session: AgySession, result: table)
---@field on_error fun(session: AgySession, err: string)
---@field on_exit fun(session: AgySession, code: number)

---Create and start a new AgySession
---@param opts AgySessionOpts
---@return AgySession
function M.new(opts)
  local self = setmetatable({}, M)
  self.conversation_id = opts.conversation_id
  self.agy_cmd = opts.agy_cmd or "agy"
  self.mode = opts.mode
  self.effort = opts.effort
  self.model = opts.model
  self.cwd = opts.cwd or vim.fn.getcwd()
  local is_new = (not self.conversation_id or self.conversation_id == "" or self.conversation_id == "new")
  if opts.workspaces ~= nil then
    self.workspaces = opts.workspaces
  elseif is_new then
    self.workspaces = { self.cwd }
  else
    -- Resumed conversations already have their workspaces stored and restored by agy
    self.workspaces = {}
  end
  self.client_instructions = (opts.client_instructions ~= false)
  self.is_active = false
  self.is_initialized = false
  self.turn_active = false
  self.line_buffer = ""
  self.pending_prompt = nil
  self._proc_id = 0

  self.on_init = opts.on_init or function() end
  self.on_step_update = opts.on_step_update or function() end
  self.on_result = opts.on_result or function() end
  self.on_error = opts.on_error or function() end
  self.on_exit = opts.on_exit or function() end

  self:start()
  return self
end

---Deprecated / unused instruction injection constant
M.CLIENT_INSTRUCTIONS = ""

---Build the command argument list for spawning agy
---@return string[]
function M:_build_cmd()
  local cmd = {
    self.agy_cmd,
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "-p=",
  }

  if self.workspaces and #self.workspaces > 0 then
    for _, dir in ipairs(self.workspaces) do
      if dir and dir ~= "" then
        table.insert(cmd, "--add-dir")
        table.insert(cmd, dir)
      end
    end
  end

  if self.conversation_id and self.conversation_id ~= "" and self.conversation_id ~= "new" then
    table.insert(cmd, "--conversation")
    table.insert(cmd, self.conversation_id)
  end

  if self.mode and self.mode ~= "" then
    table.insert(cmd, "--mode")
    table.insert(cmd, self.mode)
  end

  if self.effort and self.effort ~= "" then
    table.insert(cmd, "--effort")
    table.insert(cmd, self.effort)
  end

  if self.model and self.model ~= "" then
    table.insert(cmd, "--model")
    table.insert(cmd, self.model)
  end

  return cmd
end

---Start or restart the persistent agy process
function M:start()
  self._proc_id = (self._proc_id or 0) + 1
  local my_proc_id = self._proc_id

  if self.proc then
    local old_proc = self.proc
    self.proc = nil
    pcall(function() old_proc:kill(9) end)
  end

  self.line_buffer = ""
  self.is_active = true
  self.is_initialized = false
  self.turn_active = false

  local cmd = self:_build_cmd()

  local ok, proc = pcall(
    vim.system,
    cmd,
    {
      cwd = self.cwd,
      stdin = true,
      stdout = function(err, data)
        if self._proc_id ~= my_proc_id then return end
        if err then
          vim.schedule(function()
            if self._proc_id ~= my_proc_id then return end
            self.on_error(self, tostring(err))
          end)
          return
        end

        if data then
          self.line_buffer = self.line_buffer .. data
          while true do
            local pos = self.line_buffer:find("\n", 1, true)
            if not pos then break end
            local line = self.line_buffer:sub(1, pos - 1)
            self.line_buffer = self.line_buffer:sub(pos + 1)
            line = utils.trim(line)
            if line ~= "" then
              self:_handle_event_line(line, my_proc_id)
            end
          end
        end
      end,
      stderr = function(_, data)
        if self._proc_id ~= my_proc_id then return end
        if data and data ~= "" then
          vim.schedule(function()
            if self._proc_id ~= my_proc_id then return end
            -- Stderr may contain AGY_ERROR or diagnostic info
            local trimmed = utils.trim(data)
            if trimmed ~= "" and not trimmed:match("^%s*$") then
              self.on_error(self, trimmed)
            end
          end)
        end
      end,
    },
    function(out)
      vim.schedule(function()
        if self._proc_id ~= my_proc_id then
          -- Process was superseded or killed; ignore its exit callback
          return
        end
        local was_turn_active = self.turn_active
        self.is_active = false
        self.turn_active = false
        self.proc = nil
        self.on_exit(self, out.code, was_turn_active)
      end)
    end
  )

  if not ok then
    self.is_active = false
    self.turn_active = false
    self.proc = nil
    vim.schedule(function()
      if self._proc_id ~= my_proc_id then return end
      self.on_error(self, string.format("Failed to start '%s': %s", self.agy_cmd, tostring(proc)))
      self.on_exit(self, -1, false)
    end)
    return
  end
  self.proc = proc
end

---Handle a single complete NDJSON line from stdout
---@param line string
---@param proc_id? number
function M:_handle_event_line(line, proc_id)
  if proc_id and self._proc_id ~= proc_id then return end

  local data, err = utils.json_decode(line)
  if not data then
    -- Non-JSON line or prefix message
    if line:find('"event":') then
      -- Could be malformed JSON
      vim.schedule(function()
        if proc_id and self._proc_id ~= proc_id then return end
        self.on_error(self, "JSON parse error: " .. tostring(err))
      end)
    end
    return
  end

  local event = data.event

  if event == "init" then
    self.is_initialized = true
    if data.conversation_id and data.conversation_id ~= "" then
      self.conversation_id = data.conversation_id
    end
    vim.schedule(function()
      if proc_id and self._proc_id ~= proc_id then return end
      self.on_init(self, self.conversation_id, data.init or {})
      if self.pending_prompt then
        local p = self.pending_prompt
        self.pending_prompt = nil
        self:send_prompt(p)
      end
    end)

  elseif event == "step_update" then
    vim.schedule(function()
      if proc_id and self._proc_id ~= proc_id then return end
      self.on_step_update(self, data.step_update or {})
    end)

  elseif event == "result" then
    if data.result and data.result.conversation_id and data.result.conversation_id ~= "" then
      self.conversation_id = data.result.conversation_id
    end
    vim.schedule(function()
      if proc_id and self._proc_id ~= proc_id then return end
      self.on_result(self, data.result or {})
      self.turn_active = false
    end)

  elseif event == "command_result" then
    vim.schedule(function()
      if proc_id and self._proc_id ~= proc_id then return end
      -- If a slash command like /model was processed
      self.on_step_update(self, {
        step_type = "command_result",
        command = data.command,
      })
    end)

  elseif event == "error" then
    vim.schedule(function()
      if proc_id and self._proc_id ~= proc_id then return end
      self.on_error(self, data.error or "Unknown error")
      self.turn_active = false
    end)
  end
end

---Send a user prompt to agy
---@param prompt string
---@return boolean success
function M:send_prompt(prompt)
  if not self.is_active or not self.proc then
    self:start()
  end

  local full_prompt = prompt

  if not self.is_initialized then
    self.pending_prompt = full_prompt
    self.turn_active = true
    return true
  end

  local payload = {
    event = "user",
    message = {
      content = full_prompt,
    },
  }

  local json_str, enc_err = utils.json_encode(payload)
  if not json_str then
    self.on_error(self, "JSON encode error: " .. tostring(enc_err))
    return false
  end

  self.turn_active = true

  local ok, err = pcall(function()
    self.proc:write(json_str .. "\n")
  end)

  if not ok then
    self.turn_active = false
    self.on_error(self, "Failed to write to agy stdin: " .. tostring(err))
    return false
  end

  return true
end

---Stop the current in-flight turn
---Kills the process and immediately respawns it with the conversation ID to maintain readiness
function M:stop()
  if not self.proc then return end

  self.turn_active = false
  local old_proc = self.proc
  self.proc = nil
  self._proc_id = (self._proc_id or 0) + 1
  pcall(function() old_proc:kill(9) end)

  -- Restart the session so it is ready for the next prompt
  vim.defer_fn(function()
    self:start()
  end, 100)
end

---Switch active model for the session and restart process
---@param model string
function M:set_model(model)
  self.model = model
  self:start()
end

---Switch agent mode for the session and restart process
---@param mode? string
function M:set_mode(mode)
  self.mode = mode
  self:start()
end

---Switch reasoning effort for the session and restart process
---@param effort? string
function M:set_effort(effort)
  self.effort = effort
  self:start()
end

---Completely close and destroy the session (e.g. when buffer is deleted)
function M:destroy()
  self._proc_id = (self._proc_id or 0) + 1
  self.is_active = false
  self.turn_active = false
  if self.proc then
    local old_proc = self.proc
    self.proc = nil
    pcall(function() old_proc:kill(9) end)
  end
end

return M
