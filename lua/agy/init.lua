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

---Open an Antigravity conversation buffer or root home buffer
---@param conversation_id? string Optional conversation ID. If nil or "", opens agy://. If "new", opens agy://new.
function M.open(conversation_id)
  local target
  if not conversation_id or conversation_id == "" or conversation_id == "home" then
    target = "agy://"
  elseif conversation_id == "new" then
    target = "agy://new"
  else
    target = "agy://" .. conversation_id
  end
  vim.cmd("edit " .. target)
end

---Open the Antigravity root home buffer (agy://)
function M.home()
  M.open("")
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

  local async = require("agy.async")
  async.run(function()
    local ok, obj = async.pawait(async.system, { "git", "diff" }, { text = true })
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines
    if ok and obj and obj.stdout and obj.stdout ~= "" then
      lines = vim.split(obj.stdout, "\n")
    else
      lines = { "No git changes detected in working tree." }
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
  end)
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

---Review Antigravity artifacts
---@param filename? string
function M.artifacts(filename)
  local cur_buf = vim.api.nvim_get_current_buf()
  local cid = nil
  if protocol.buffers[cur_buf] and protocol.buffers[cur_buf].conversation_id then
    cid = protocol.buffers[cur_buf].conversation_id
  else
    for _, st in pairs(protocol.buffers) do
      if st.conversation_id and st.conversation_id ~= "" and st.conversation_id ~= "new" then
        cid = st.conversation_id
        break
      end
    end
  end

  if not cid or cid == "" or cid == "new" then
    local bname = vim.api.nvim_buf_get_name(cur_buf)
    cid = bname:match("^agy://([^/?#]+)")
  end

  if not cid or cid == "" or cid == "new" or cid == "home" then
    local history = require("agy.transcript").read_history(config.get().app_data_dir)
    if history and #history > 0 then
      cid = history[1].conversation_id
    end
  end

  if not cid or cid == "" or cid == "new" or cid == "home" then
    vim.notify("[agy.nvim] No active conversation session.", vim.log.levels.WARN)
    return
  end

  local artifacts_mod = require("agy.artifacts")
  local arts = artifacts_mod.get_artifacts(cid, config.get().app_data_dir)
  if #arts == 0 then
    vim.notify("[agy.nvim] No artifacts found for this conversation", vim.log.levels.INFO)
    return
  end

  local target_art = filename or arts[1].filename
  vim.cmd("edit agy://" .. cid .. "/artifacts/" .. target_art)
end

---Complete artifact filenames for :AgyArtifacts
---@param arglead string
---@return string[]
function M.complete_artifacts(arglead)
  local matches = require("agy.completion").complete_artifacts(arglead)
  local res = {}
  for _, m in ipairs(matches) do
    local clean = (m.insert_text:gsub("%s+$", ""))
    table.insert(res, clean)
  end
  return res
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
