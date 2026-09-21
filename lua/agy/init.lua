local config = require("agy.config")
local protocol = require("agy.protocol")
local picker = require("agy.picker")

local M = {}

---Setup agy.nvim plugin
---@param opts? AgyConfig
function M.setup(opts)
  config.setup(opts)
  protocol.setup()

  vim.api.nvim_create_user_command("AgyModel", function(args)
    M.model(args.args ~= "" and args.args or nil)
  end, {
    nargs = "?",
    complete = function(arg_lead)
      local completion_mod = require("agy.completion")
      local matches = completion_mod.complete_models(arg_lead)
      local res = {}
      for _, m in ipairs(matches) do
        table.insert(res, m.label)
      end
      return res
    end,
    desc = "Select or switch Antigravity active model",
  })
end

---Open an Antigravity conversation buffer
---@param conversation_id? string Optional conversation ID. If nil or "new", opens agy://new
function M.open(conversation_id)
  local target
  if not conversation_id or conversation_id == "" or conversation_id == "new" then
    target = "agy://new"
  else
    target = "agy://" .. conversation_id
  end
  vim.cmd("edit " .. target)
end

---Start a brand new Antigravity session
function M.new()
  M.open("new")
end

---Resume a past Antigravity conversation
---@param conversation_id? string If nil, opens the interactive picker
function M.resume(conversation_id)
  if conversation_id and conversation_id ~= "" then
    M.open(conversation_id)
  else
    picker.resume()
  end
end

---Stop active turn in current buffer
function M.stop()
  local buf = vim.api.nvim_get_current_buf()
  protocol.stop_turn(buf)
end

---Select or switch active LLM model
---@param model_name? string
function M.model(model_name)
  local buf = vim.api.nvim_get_current_buf()
  if model_name and model_name ~= "" then
    protocol.set_model(buf, model_name)
  else
    picker.model(buf)
  end
end

---Show diff of workspace changes
function M.diff()
  -- Try Neovim built-in diff or terminal git diff
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].buftype = "nofile"

  vim.cmd("botright vnew")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  local obj = vim.system({ "git", "diff" }, { text = true }):wait()
  local lines = vim.split(obj.stdout or "", "\n")
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    lines = { "No git changes detected in working tree." }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

---Show quota and usage limits
function M.usage()
  require("agy.quota").open()
end

---Show quota and usage limits
function M.quota()
  M.usage()
end

---Show context breakdown and token usage
function M.context(caller_buf)
  return require("agy.context").open(caller_buf)
end

---Show background tasks panel
---@param caller_buf? number
function M.tasks(caller_buf)
  return require("agy.tasks").open(caller_buf)
end

---Register a custom @ mention context provider (Public API)
---@param provider table
function M.register_mention(provider)
  return require("agy.mention").register(provider)
end

---Unregister an @ mention context provider (Public API)
---@param name string
function M.unregister_mention(name)
  return require("agy.mention").unregister(name)
end

---Get all registered @ mention providers (Public API)
---@return table[]
function M.get_mentions()
  return require("agy.mention").list()
end

return M
