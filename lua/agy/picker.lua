local transcript = require("agy.transcript")
local config_mod = require("agy.config")

local M = {}

---Open interactive picker to resume an existing Antigravity conversation
function M.resume()
  local cfg = config_mod.get()
  local items = transcript.read_history(cfg.app_data_dir)

  if #items == 0 then
    vim.notify("[agy.nvim] No previous conversations found. Starting new session...", vim.log.levels.INFO)
    vim.cmd("edit agy://new")
    return
  end

  vim.ui.select(items, {
    prompt = "Resume Antigravity Conversation:",
    format_item = function(item)
      local time_str = string.format("%-10s", "[" .. item.relative_time .. "]")
      local ws = item.workspace ~= "" and (" (" .. vim.fs.basename(item.workspace) .. ")") or ""
      local prompt_preview = item.title:gsub("\r?\n", " ")
      if #prompt_preview > 60 then
        prompt_preview = prompt_preview:sub(1, 57) .. "..."
      end
      return string.format("%s %s%s", time_str, prompt_preview, ws)
    end,
  }, function(choice)
    if choice and choice.conversation_id then
      vim.cmd("edit agy://" .. choice.conversation_id)
    end
  end)
end

---Open interactive picker to select and switch active LLM model
---@param buf? number
function M.model(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local completion_mod = require("agy.completion")
  local models = completion_mod.get_available_models()

  vim.ui.select(models, {
    prompt = "Select Antigravity Model:",
    format_item = function(item)
      return string.format("%-30s [%s] %s", item.id, item.provider, item.name)
    end,
  }, function(choice)
    if choice and choice.id then
      local protocol = require("agy.protocol")
      protocol.set_model(buf, choice.id, true)
    end
  end)
end

return M
