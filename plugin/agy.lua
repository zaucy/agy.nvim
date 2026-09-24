if vim.g.loaded_agy_nvim == 1 then
  return
end
vim.g.loaded_agy_nvim = 1

local agy = require("agy")

-- Initialize protocol handlers
require("agy.protocol").setup()

-- Prefetch models asynchronously in background
pcall(function() require("agy.completion").prefetch_models() end)

vim.api.nvim_create_user_command("Agy", function(opts)
  local arg = opts.args and vim.trim(opts.args) or ""
  if arg == "" then
    agy.home()
  else
    agy.open(arg)
  end
end, {
  nargs = "?",
  desc = "Open Antigravity home buffer or conversation (agy:// or agy://<id>)",
  complete = function(arglead)
    local cfg = require("agy.config").get()
    local history = require("agy.transcript").read_history(cfg.app_data_dir)
    local matches = {}
    if ("new"):find(arglead, 1, true) then
      table.insert(matches, "new")
    end
    for _, item in ipairs(history) do
      if item.conversation_id:find(arglead, 1, true) then
        table.insert(matches, item.conversation_id)
      end
    end
    return matches
  end,
})

vim.api.nvim_create_user_command("AgyNew", function()
  agy.new()
end, {
  desc = "Start a new Antigravity session (agy://new)",
})

vim.api.nvim_create_user_command("AgyHome", function()
  agy.home()
end, {
  desc = "Open the Antigravity root home buffer (agy://)",
})

vim.api.nvim_create_user_command("AgyResume", function(opts)
  local arg = opts.args and vim.trim(opts.args) or ""
  agy.resume(arg ~= "" and arg or nil)
end, {
  nargs = "?",
  desc = "Resume a past Antigravity conversation or open picker",
  complete = function(arglead)
    local cfg = require("agy.config").get()
    local history = require("agy.transcript").read_history(cfg.app_data_dir)
    local matches = {}
    for _, item in ipairs(history) do
      if item.conversation_id:find(arglead, 1, true) then
        table.insert(matches, item.conversation_id)
      end
    end
    return matches
  end,
})

vim.api.nvim_create_user_command("AgyModel", function(opts)
  local arg = opts.args and vim.trim(opts.args) or ""
  agy.model(arg ~= "" and arg or nil)
end, {
  nargs = "?",
  desc = "Select or switch Antigravity active model",
  complete = function(arg_lead)
    local completion_mod = require("agy.completion")
    local matches = completion_mod.complete_models(arg_lead)
    local res = {}
    for _, m in ipairs(matches) do
      table.insert(res, m.label)
    end
    return res
  end,
})

vim.api.nvim_create_user_command("AgyStop", function()
  agy.stop()
end, {
  desc = "Stop active in-flight Antigravity turn",
})

vim.api.nvim_create_user_command("AgyDiff", function()
  agy.diff()
end, {
  desc = "Show git diff of changes made by Antigravity",
})

vim.api.nvim_create_user_command("AgyUsage", function()
  agy.usage()
end, {
  desc = "Show Antigravity quota and usage limits",
})

vim.api.nvim_create_user_command("AgyQuota", function()
  agy.quota()
end, {
  desc = "Show Antigravity quota and usage limits",
})

vim.api.nvim_create_user_command("AgyContext", function()
  agy.context()
end, {
  desc = "Show Antigravity context breakdown and token usage",
})

vim.api.nvim_create_user_command("AgyTasks", function()
  agy.tasks()
end, {
  desc = "Show Antigravity background tasks and status",
})

vim.api.nvim_create_user_command("AgyArtifacts", function(opts)
  local arg = opts.args and vim.trim(opts.args) or ""
  agy.artifacts(arg ~= "" and arg or nil)
end, {
  nargs = "?",
  desc = "Review Antigravity artifacts (agy://<id>/artifacts/<filename>)",
  complete = function(arglead)
    return agy.complete_artifacts(arglead)
  end,
})
