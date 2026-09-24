local transcript = require("agy.transcript")
local home = require("agy.home")
local utils = require("agy.utils")
local protocol = require("agy.protocol")
local config_mod = require("agy.config")

print("=== Running History Logging Tests ===")

local tmp_env = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(tmp_env, "p")
local test_cwd = vim.fs.normalize("C:/Users/tester/projects/my-project")

-- [Test 1] Testing fail-fast assertions on append_history
print("\n[Test 1] Testing fail-fast assertions on append_history...")
local ok1, err1 = pcall(function()
  transcript.append_history(nil, tmp_env)
end)
assert(not ok1 and err1:find("entry table required", 1, true), "Must fail if entry is nil")

local ok2, err2 = pcall(function()
  transcript.append_history({ workspace = test_cwd }, tmp_env)
end)
assert(not ok2 and err2:find("valid conversation_id required", 1, true), "Must fail if conversation_id missing")

local ok3, err3 = pcall(function()
  transcript.append_history({ conversation_id = "new", workspace = test_cwd }, tmp_env)
end)
assert(not ok3 and err3:find("valid conversation_id required", 1, true), "Must fail if conversation_id is 'new'")

local ok4, err4 = pcall(function()
  transcript.append_history({ conversation_id = "cid-123", workspace = "" }, tmp_env)
end)
assert(not ok4 and err4:find("valid workspace required", 1, true), "Must fail if workspace is empty")
print("✓ Fail-fast assertions on append_history verified")

-- [Test 2] Testing append_history creates history.jsonl and writes valid JSON
print("\n[Test 2] Testing append_history creates history.jsonl and writes valid JSON...")
local cid_1 = "11111111-2222-3333-4444-555555555555"
local success1 = transcript.append_history({
  conversation_id = cid_1,
  display = "Fix the login bug",
  workspace = test_cwd,
}, tmp_env)
assert(success1 == true, "append_history must return true on success")

local history_file = utils.get_history_file(tmp_env)
assert(vim.fn.filereadable(history_file) == 1, "history.jsonl must exist after append_history")

local lines = vim.fn.readfile(history_file)
assert(#lines == 1, "Expected 1 line in history.jsonl, got: " .. #lines)
local entry1 = vim.json.decode(lines[1])
assert(entry1.conversationId == cid_1, "Expected conversationId " .. cid_1)
assert(entry1.display == "Fix the login bug", "Expected display 'Fix the login bug'")
assert(entry1.workspace == test_cwd, "Expected workspace " .. test_cwd)
assert(type(entry1.timestamp) == "number" and entry1.timestamp > 0, "Expected valid epoch timestamp")
print("✓ append_history file creation and JSON schema verified")

-- [Test 3] Testing read_history and home.get_workspace_conversations with appended entry
print("\n[Test 3] Testing read_history and home.get_workspace_conversations...")
local summaries = transcript.read_history(tmp_env)
assert(#summaries == 1, "Expected 1 conversation summary, got: " .. #summaries)
assert(summaries[1].conversation_id == cid_1, "Summary ID mismatch")
assert(summaries[1].title == "Fix the login bug", "Summary title mismatch")

local ws_convs = home.get_workspace_conversations(test_cwd, tmp_env)
assert(#ws_convs == 1, "Expected 1 conversation for test_cwd, got: " .. #ws_convs)
assert(ws_convs[1].conversation_id == cid_1, "Workspace conversation ID mismatch")

-- Workspace scoping: other directory must return 0
local other_convs = home.get_workspace_conversations("C:/Users/tester/projects/other-project", tmp_env)
assert(#other_convs == 0, "Other workspace must have 0 conversations")
print("✓ read_history and home.get_workspace_conversations integration verified")

-- [Test 4] Testing protocol prompt submission and on_init history logging for agy://new
print("\n[Test 4] Testing protocol prompt submission and on_init history logging for agy://new...")
local test_app_dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(test_app_dir, "p")

local cfg = config_mod.get()
cfg.app_data_dir = test_app_dir

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, "agy://new")
protocol.handle_buf_read({ buf = buf, file = "agy://new" })

local state = protocol.buffers[buf]
assert(state ~= nil, "State must be initialized for agy://new")
-- Ensure conversation_id is nil to explicitly test delayed on_init arrival
state.conversation_id = nil

-- Type a prompt in the buffer
vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, {
  "Implement history logging feature",
})

-- Intercept session:send_prompt to simulate successful send
state.session.send_prompt = function(self, payload)
  return true
end

-- Trigger :w (handle_write)
protocol.handle_write(buf)

assert(state.pending_history_display == "Implement history logging feature",
  "Pending display must be saved when conversation_id is nil")

-- Simulate agy CLI backend returning 'init' event with conversation UUID
local new_cid = "99999999-8888-7777-6666-555555555555"
state.session.on_init(state.session, new_cid, { model = "Gemini 3.8 Flash" })

assert(state.pending_history_display == nil, "Pending display must be cleared after flush")
assert(state.conversation_id == new_cid, "State conversation_id must be updated")

-- Verify history.jsonl received the new entry
local new_hist_file = utils.get_history_file(test_app_dir)
assert(vim.fn.filereadable(new_hist_file) == 1, "history.jsonl must exist in test_app_dir")

local new_hist_lines = vim.fn.readfile(new_hist_file)
assert(#new_hist_lines == 1, "Expected 1 entry in history.jsonl, got: " .. #new_hist_lines)

local new_entry = vim.json.decode(new_hist_lines[1])
assert(new_entry.conversationId == new_cid, "Expected conversationId " .. new_cid)
assert(new_entry.display == "Implement history logging feature", "Expected display prompt")
assert(new_entry.workspace ~= "", "Expected non-empty workspace")

-- Verify home buffer sees the newly created session
local home_matches = home.get_workspace_conversations(new_entry.workspace, test_app_dir)
assert(#home_matches == 1, "Home buffer must find the newly created conversation")
assert(home_matches[1].conversation_id == new_cid, "Home conversation ID mismatch")
print("✓ Protocol prompt submission and on_init history logging for agy://new verified")

-- [Test 5] Testing subsequent prompt in existing conversation appends to history.jsonl
print("\n[Test 5] Testing subsequent prompt in existing conversation appends to history.jsonl...")
protocol.with_modifiable(buf, function()
  vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, {
    "Now run the tests",
  })
end)
protocol.handle_write(buf)

local updated_lines = vim.fn.readfile(new_hist_file)
assert(#updated_lines == 2, "Expected 2 entries in history.jsonl after second prompt, got: " .. #updated_lines)
local entry2 = vim.json.decode(updated_lines[2])
assert(entry2.conversationId == new_cid, "Second entry must have same conversationId")
assert(entry2.display == "Now run the tests", "Second entry display mismatch")

-- read_history should now have updated title from latest prompt
local updated_summaries = transcript.read_history(test_app_dir)
assert(#updated_summaries == 1, "Still 1 unique conversation")
assert(updated_summaries[1].title == "Now run the tests", "Summary title should update to latest prompt")
print("✓ Subsequent prompt in existing conversation appends to history.jsonl verified")

print("\nALL HISTORY LOGGING TESTS PASSED PERFECTLY!")
