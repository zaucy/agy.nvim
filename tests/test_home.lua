-- tests/test_home.lua
-- Comprehensive test suite for Antigravity agy:// root home buffer,
-- workspace conversation filtering, 3-tier '-' navigation hierarchy,
-- and :Agy / :AgyNew / :AgyHome user commands.

local home = require("agy.home")
local protocol = require("agy.protocol")
local config = require("agy.config")
local agy = require("agy")

print("=== Running Antigravity Home Buffer & Navigation Tests ===")

-- Setup mock test environment
local tmp_root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(tmp_root, "p")
local test_app_dir = vim.fs.joinpath(tmp_root, ".gemini", "antigravity-cli")
vim.fn.mkdir(test_app_dir, "p")

local mock_cwd = vim.fs.joinpath(tmp_root, "projects", "my-app")
vim.fn.mkdir(mock_cwd, "p")

local other_cwd = vim.fs.joinpath(tmp_root, "projects", "other-app")
vim.fn.mkdir(other_cwd, "p")

-- Create mock history.jsonl with conversations across workspaces
local history_file = vim.fs.joinpath(test_app_dir, "history.jsonl")
local conv_id_1 = "11111111-aaaa-bbbb-cccc-111111111111"
local conv_id_2 = "22222222-aaaa-bbbb-cccc-222222222222"
local conv_id_other = "99999999-xxxx-yyyy-zzzz-999999999999"

local history_entries = {
  vim.json.encode({
    conversationId = conv_id_1,
    display = "Feature A: Initial discussion and planning",
    timestamp = 1700000000000,
    workspace = mock_cwd,
  }),
  vim.json.encode({
    conversationId = conv_id_2,
    display = "Feature B: Bug fix in protocol handler",
    timestamp = 1700000500000,
    workspace = (vim.fn.has("win32") == 1 and (mock_cwd:gsub("/", "\\") .. "\\") or (mock_cwd .. "/")),
  }),
  vim.json.encode({
    conversationId = conv_id_other,
    display = "Other Project conversation",
    timestamp = 1700000900000,
    workspace = other_cwd,
  }),
}
vim.fn.writefile(history_entries, history_file)

local cfg = config.setup({
  app_data_dir = test_app_dir,
  ui = {
    header_style = "banner",
    animate_logo = false,
  },
})

-- [Test 1] Testing home.path_equals
print("\n[Test 1] Testing home.path_equals...")
assert(home.path_equals("C:/foo/bar", "C:/foo/bar"), "Identical paths must match")
assert(home.path_equals("C:/foo/bar/", "C:/foo/bar"), "Trailing slash must normalize")
assert(home.path_equals("C:\\foo\\bar", "C:/foo/bar"), "Backslashes and forward slashes must match")
if vim.fn.has("win32") == 1 then
  assert(home.path_equals("c:/foo/bar", "C:/foo/bar"), "Windows casing must match")
end
assert(not home.path_equals("C:/foo/bar", "C:/foo/baz"), "Different paths must not match")
assert(not home.path_equals("", "C:/foo/bar"), "Empty path must return false")
assert(not home.path_equals(nil, "C:/foo/bar"), "Nil path must return false")
print("✓ home.path_equals verified")

-- [Test 2] Testing home.get_workspace_conversations
print("\n[Test 2] Testing home.get_workspace_conversations...")
local convs = home.get_workspace_conversations(mock_cwd, test_app_dir)
assert(#convs == 2, "Expected exactly 2 conversations for mock_cwd, got: " .. #convs)
-- Most recent first: conv_id_2 has timestamp 1700000500000
assert(convs[1].conversation_id == conv_id_2, "Expected most recent conversation first (conv_id_2)")
assert(convs[2].conversation_id == conv_id_1, "Expected older conversation second (conv_id_1)")
print("✓ home.get_workspace_conversations filtering and sorting verified")

-- [Test 3] Testing render_home buffer structure and cursor placement
print("\n[Test 3] Testing render_home buffer structure and cursor placement...")
local buf = vim.api.nvim_create_buf(false, true)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)

home.render_home(buf, cfg, mock_cwd)

assert(vim.bo[buf].buftype == "nofile", "Buffer buftype must be nofile")
assert(vim.bo[buf].filetype == "agy", "Buffer filetype must be agy")
assert(not vim.bo[buf].modifiable, "Buffer modifiable must be false")
assert(not vim.bo[buf].modified, "Buffer modified must be false")

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print("Rendered home lines count: " .. #lines)
for idx, l in ipairs(lines) do
  print(string.format("  [%2d] %s", idx, l))
end

-- Line 4 should contain agy://
assert(lines[4]:find("agy://", 1, true), "Line 4 must contain agy://")
-- Line 5 should contain Workspace: <mock_cwd>
assert(lines[5]:find(mock_cwd, 1, true), "Line 5 must contain mock_cwd")
-- Line 8 should contain [agy://new]
assert(lines[8]:find("[agy://new]", 1, true), "Line 8 must contain [agy://new]")
assert(lines[8]:find("Start a fresh conversation", 1, true), "Line 8 must contain 'Start a fresh conversation'")
-- Line 10 should contain Recent Conversations (2)
assert(lines[10]:find("Recent Conversations %(2%)"), "Line 10 must contain 'Recent Conversations (2)'")
-- Line 12 should contain conv_id_2 short tag
assert(lines[12]:find(conv_id_2:sub(1, 8), 1, true), "Line 12 must contain short ID for conv_id_2")
-- Line 13 should contain conv_id_1 short tag
assert(lines[13]:find(conv_id_1:sub(1, 8), 1, true), "Line 13 must contain short ID for conv_id_1")

-- Check cursor placement on line 8 ([agy://new])
local cursor = vim.api.nvim_win_get_cursor(win)
assert(cursor[1] == 8, "Expected cursor on line 8 ([agy://new]), got line: " .. cursor[1])
print("✓ render_home buffer structure and cursor placement verified")

-- [Test 4] Testing <CR> keymap dispatch in home buffer
print("\n[Test 4] Testing <CR> keymap dispatch in home buffer...")
local edited_target = nil
local orig_cmd = vim.cmd
---@diagnostic disable-next-line: duplicate-set-field
vim.cmd = function(cmd_str)
  local target = cmd_str:match("^edit%s+(.*)$")
  if target then
    edited_target = target
  else
    orig_cmd(cmd_str)
  end
end

-- Put cursor on line 8 ([agy://new]) and press <CR>
vim.api.nvim_win_set_cursor(win, { 8, 2 })
local cr_keys = vim.api.nvim_buf_get_keymap(buf, "n")
local cr_fn = nil
for _, k in ipairs(cr_keys) do
  if k.lhs == "<CR>" then
    cr_fn = k.callback
  end
end
assert(cr_fn ~= nil, "Expected <CR> buffer keymap")
cr_fn()
assert(edited_target == "agy://new", "Expected edit agy://new, got: " .. tostring(edited_target))

-- Put cursor on line 12 (conv_id_2) and press <CR>
edited_target = nil
vim.api.nvim_win_set_cursor(win, { 12, 2 })
cr_fn()
assert(edited_target == "agy://" .. conv_id_2, "Expected edit agy://" .. conv_id_2 .. ", got: " .. tostring(edited_target))

-- Put cursor on banner line 2 and press <CR> -> should open agy://new
edited_target = nil
vim.api.nvim_win_set_cursor(win, { 2, 2 })
cr_fn()
assert(edited_target == "agy://new", "Expected edit agy://new when clicking header, got: " .. tostring(edited_target))

vim.cmd = orig_cmd
print("✓ <CR> keymap dispatch verified")

-- [Test 5] Testing empty state when no conversations match workspace
print("\n[Test 5] Testing empty state when no conversations match workspace...")
local empty_buf = vim.api.nvim_create_buf(false, true)
home.render_home(empty_buf, cfg, vim.fs.joinpath(tmp_root, "empty-dir"))
local empty_lines = vim.api.nvim_buf_get_lines(empty_buf, 0, -1, false)
local found_empty_notice = false
for _, l in ipairs(empty_lines) do
  if l:find("No past conversations found for this workspace", 1, true) then
    found_empty_notice = true
  end
end
assert(found_empty_notice, "Expected empty state notice in empty workspace")
print("✓ Empty state notice verified")

-- [Test 6] Testing 3-tier '-' navigation hierarchy
print("\n[Test 6] Testing 3-tier '-' navigation hierarchy...")
-- Tier 1: In agy://, pressing '-' notifies already at root
local notified_msg = nil
local orig_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  notified_msg = msg
end

local root_dash_fn = nil
for _, k in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  if k.lhs == "-" then
    root_dash_fn = k.callback
  end
end
assert(root_dash_fn ~= nil, "Expected '-' keymap on agy:// home buffer")
root_dash_fn()
assert(notified_msg and notified_msg:find("Already at agy root", 1, true), "Expected Already at agy root notice, got: " .. tostring(notified_msg))

-- Tier 2: In agy://<id> or agy://new, pressing '-' navigates to agy://
local conv_buf = vim.api.nvim_create_buf(false, true)
protocol._setup_buffer(conv_buf, conv_id_1)
local conv_dash_fn = nil
for _, k in ipairs(vim.api.nvim_buf_get_keymap(conv_buf, "n")) do
  if k.lhs == "-" then
    conv_dash_fn = k.callback
  end
end
assert(conv_dash_fn ~= nil, "Expected '-' keymap in conversation buffer")

local nav_target = nil
---@diagnostic disable-next-line: duplicate-set-field
vim.cmd = function(cmd_str)
  local target = cmd_str:match("^edit%s+(.*)$")
  if target then
    nav_target = target
  else
    orig_cmd(cmd_str)
  end
end

conv_dash_fn()
assert(nav_target == "agy://", "Expected conversation '-' to navigate to agy://, got: " .. tostring(nav_target))

-- Tier 3: In agy://<id>/artifacts/<filename>, pressing '-' navigates to agy://<id>
local artifacts_mod = require("agy.artifacts")
local art_buf = vim.api.nvim_create_buf(false, true)
-- Create a mock artifact file
local art_file = vim.fs.joinpath(test_app_dir, "brain", conv_id_1, "test.md")
vim.fn.mkdir(vim.fs.joinpath(test_app_dir, "brain", conv_id_1), "p")
vim.fn.writefile({ "# Sample Artifact" }, art_file)
artifacts_mod.render_artifact(art_buf, conv_id_1, "test.md", cfg)

local art_dash_fn = nil
for _, k in ipairs(vim.api.nvim_buf_get_keymap(art_buf, "n")) do
  if k.lhs == "-" then
    art_dash_fn = k.callback
  end
end
assert(art_dash_fn ~= nil, "Expected '-' keymap in artifact buffer")

nav_target = nil
art_dash_fn()
assert(nav_target == "agy://" .. conv_id_1, "Expected artifact '-' to navigate to agy://" .. conv_id_1 .. ", got: " .. tostring(nav_target))

vim.cmd = orig_cmd
vim.notify = orig_notify
print("✓ 3-tier '-' navigation hierarchy verified across all buffers")

-- [Test 7] Testing protocol handle_buf_read for agy://, agy:///, and agy://home
print("\n[Test 7] Testing protocol handle_buf_read for agy://, agy:///, and agy://home...")
local test_urls = { "agy://", "agy:///", "agy://home" }
for _, url in ipairs(test_urls) do
  local b = vim.api.nvim_create_buf(false, true)
  protocol.handle_buf_read({ buf = b, file = url })
  assert(protocol.buffers[b] ~= nil, "Expected buffer state recorded for " .. url)
  assert(protocol.buffers[b].is_home == true, "Expected is_home == true for " .. url)
  local b_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(#b_lines >= 8, "Expected rendered home lines for " .. url)
end
print("✓ protocol handle_buf_read for agy:// URLs verified")

-- [Test 8] Testing user commands :Agy, :AgyNew, :AgyHome
print("\n[Test 8] Testing user commands :Agy, :AgyNew, :AgyHome...")
local opened_cmd = nil
---@diagnostic disable-next-line: duplicate-set-field
vim.cmd = function(cmd_str)
  local target = cmd_str:match("^edit%s+(.*)$")
  if target then
    opened_cmd = target
  else
    orig_cmd(cmd_str)
  end
end

-- Test agy.home() and agy.open("")
opened_cmd = nil
agy.home()
assert(opened_cmd == "agy://", "Expected agy.home() to open agy://, got: " .. tostring(opened_cmd))

opened_cmd = nil
agy.open("")
assert(opened_cmd == "agy://", "Expected agy.open('') to open agy://, got: " .. tostring(opened_cmd))

opened_cmd = nil
agy.new()
assert(opened_cmd == "agy://new", "Expected agy.new() to open agy://new, got: " .. tostring(opened_cmd))

opened_cmd = nil
agy.open("new")
assert(opened_cmd == "agy://new", "Expected agy.open('new') to open agy://new, got: " .. tostring(opened_cmd))

opened_cmd = nil
agy.open(conv_id_1)
assert(opened_cmd == "agy://" .. conv_id_1, "Expected agy.open(id) to open agy://<id>, got: " .. tostring(opened_cmd))

vim.cmd = orig_cmd
print("✓ user commands and agy.open / agy.home / agy.new dispatch verified")

-- [Test 9] Testing AGENTS.md fail-fast assertions
print("\n[Test 9] Testing AGENTS.md fail-fast assertions...")
local test_b = vim.api.nvim_create_buf(false, true)

-- Missing new_session icon
local bad_cfg1 = vim.deepcopy(cfg)
bad_cfg1.icons.new_session = nil
local ok1, err1 = pcall(home.render_home, test_b, bad_cfg1, mock_cwd)
assert(not ok1 and err1:find("config.icons.new_session required"), "Expected fail-fast on missing new_session icon")

-- Missing conversation icon
local bad_cfg2 = vim.deepcopy(cfg)
bad_cfg2.icons.conversation = nil
local ok2, err2 = pcall(home.render_home, test_b, bad_cfg2, mock_cwd)
assert(not ok2 and err2:find("config.icons.conversation required"), "Expected fail-fast on missing conversation icon")

-- Missing table.horizontal
local bad_cfg3 = vim.deepcopy(cfg)
bad_cfg3.icons.table.horizontal = nil
local ok3, err3 = pcall(home.render_home, test_b, bad_cfg3, mock_cwd)
assert(not ok3 and err3:find("config.icons.table.horizontal required"), "Expected fail-fast on missing table.horizontal")

print("✓ AGENTS.md fail-fast assertions verified")

print("\nALL HOME BUFFER & NAVIGATION TESTS PASSED PERFECTLY!")
