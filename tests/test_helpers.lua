local M = {}

---Create a temporary isolated test app_data_dir with mock history and conversations
---@return string app_data_dir, string test_conv_id
function M.create_mock_environment()
  local tmp = vim.fs.normalize(vim.fn.tempname())
  local conv_id = "test-conv-0000-0000-0000-123456789abc"
  local brain_dir = tmp .. "/brain/" .. conv_id .. "/.system_generated/logs"
  vim.fn.mkdir(brain_dir, "p")

  local cwd = vim.fs.normalize(vim.fn.getcwd())

  -- Mock transcript steps
  local steps = {
    {
      step_index = 1,
      type = "USER_INPUT",
      content = "<USER_SETTINGS_CHANGE>\nModel Selection changed from none to Gemini 3.8 Flash (High). No need to comment.\n</USER_SETTINGS_CHANGE>\n<USER_REQUEST>\nHello from history\n</USER_REQUEST>",
      display_content = "Hello from history",
    },
    {
      step_index = 2,
      type = "PLANNER_RESPONSE",
      content = "Hi there! How can I help you?",
    },
    {
      step_index = 3,
      type = "TOOL_CALL",
      tool_name = "view_file",
      args = { AbsolutePath = cwd .. "/lua/agy/init.lua" },
      output = "Line 1: local config = require('agy.config')\nLine 2: return M",
      duration_seconds = 0.1,
    },
    {
      step_index = 4,
      type = "PLANNER_RESPONSE",
      content = "I have viewed the file.",
    },
  }

  local tf = io.open(brain_dir .. "/transcript.jsonl", "w")
  if tf then
    for _, s in ipairs(steps) do
      tf:write(vim.json.encode(s) .. "\n")
    end
    tf:close()
  end

  -- Mock history.jsonl
  local hf = io.open(tmp .. "/history.jsonl", "w")
  if hf then
    hf:write(vim.json.encode({
      conversationId = conv_id,
      display = "Hello from history",
      timestamp = os.time() * 1000 - 60000,
      workspace = cwd,
    }) .. "\n")
    hf:close()
  end

  return tmp, conv_id
end

return M
