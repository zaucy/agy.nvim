local session_mod = require("agy.session")
local protocol = require("agy.protocol")
local config = require("agy.config")
local utils = require("agy.utils")

print("=== Running Workspaces Configuration & Integration Tests ===")

local cwd = vim.fn.getcwd()
local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
local root = is_win and "C:/mock_project" or "/tmp/mock_project"

-- [Test 1] Session default workspace is current working directory
print("\n[Test 1] Testing session default workspace...")
local s_default = session_mod.new({
	cwd = cwd,
})
-- Terminate proc immediately since we only test command building
if s_default.proc then
	s_default.proc:kill(9)
end

local cmd_default = s_default:_build_cmd()
local has_add_dir = false
local added_dir = nil
for i = 1, #cmd_default do
	if cmd_default[i] == "--add-dir" then
		has_add_dir = true
		added_dir = cmd_default[i + 1]
		break
	end
end
assert(has_add_dir, "Expected --add-dir in default session command")
assert(added_dir == cwd, string.format("Expected added dir to match cwd (%s), got %s", cwd, tostring(added_dir)))
print("✓ Default session correctly includes --add-dir <cwd>")

-- [Test 2] Session with multiple custom workspaces
print("\n[Test 2] Testing custom workspaces array...")
local ws_dirs = { root .. "/alpha", root .. "/beta" }
local s_custom = session_mod.new({
	cwd = cwd,
	workspaces = ws_dirs,
})
if s_custom.proc then
	s_custom.proc:kill(9)
end

local cmd_custom = s_custom:_build_cmd()
local custom_added = {}
for i = 1, #cmd_custom do
	if cmd_custom[i] == "--add-dir" then
		table.insert(custom_added, cmd_custom[i + 1])
	end
end
assert(#custom_added == 2, string.format("Expected 2 --add-dir flags, got %d", #custom_added))
assert(
	custom_added[1] == root .. "/alpha" and custom_added[2] == root .. "/beta",
	"Workspaces not in expected order"
)
print("✓ Custom workspaces properly translated to repeatable --add-dir flags")

-- [Test 3] Session with explicit empty workspaces
print("\n[Test 3] Testing explicit empty workspaces...")
local s_empty = session_mod.new({
	cwd = cwd,
	workspaces = {},
})
if s_empty.proc then
	s_empty.proc:kill(9)
end

local cmd_empty = s_empty:_build_cmd()
local empty_has_add_dir = false
for _, v in ipairs(cmd_empty) do
	if v == "--add-dir" then
		empty_has_add_dir = true
		break
	end
end
assert(not empty_has_add_dir, "Explicit empty workspaces should not pass --add-dir")
print("✓ Explicit empty workspaces skips --add-dir")

-- [Test 4] utils.shorten_path with multiple workspaces
print("\n[Test 4] Testing shorten_path with multiple workspaces...")
local multi_ws = { root .. "/workspace1", root .. "/workspace2" }
local path1 = root .. "/workspace1/src/main.rs"
local path2 = root .. "/workspace2/lib/util.py"
local path3 = is_win and "C:/Other/file.txt" or "/etc/other_file.txt"

local s1 = utils.shorten_path(path1, multi_ws)
local s2 = utils.shorten_path(path2, multi_ws)
local s3 = utils.shorten_path(path3, multi_ws)

assert(s1 == "src/main.rs", "Failed to shorten path in workspace 1: " .. s1)
assert(s2 == "lib/util.py", "Failed to shorten path in workspace 2: " .. s2)
assert(s3:find("file.txt") ~= nil or s3:find("other_file.txt") ~= nil, "Path outside workspaces altered: " .. s3)
print("✓ shorten_path correctly shortens paths across multiple active workspaces")

-- [Test 5] Protocol buffer creation with config.workspaces function
print("\n[Test 5] Testing protocol buffer creation with dynamic workspaces...")
config.setup({
	workspaces = function()
		return { root .. "/custom/dynamic/ws" }
	end,
})

local test_buf = vim.api.nvim_create_buf(false, false)
protocol.handle_buf_read({ buf = test_buf, file = "agy://new" })

local state = protocol.buffers[test_buf]
assert(state ~= nil, "Buffer state not created")
assert(state.session ~= nil, "Session not created on buffer state")
assert(state.session.workspaces[1] == root .. "/custom/dynamic/ws", "Expected dynamic workspace on session")

if state.session.proc then
	state.session.proc:kill(9)
end
vim.api.nvim_buf_delete(test_buf, { force = true })
print("✓ Dynamic function-based config.workspaces verified")

-- Reset config
config.setup({ workspaces = nil })

-- [Test 6] Resumed session does not inject --add-dir by default
print("\n[Test 6] Testing resumed session workspace behavior...")
local s_resumed = session_mod.new({
	conversation_id = "00000000-0000-0000-0000-000000000000",
	cwd = cwd,
})
if s_resumed.proc then
	s_resumed.proc:kill(9)
end

local cmd_resumed = s_resumed:_build_cmd()
local resumed_has_add_dir = false
for _, v in ipairs(cmd_resumed) do
	if v == "--add-dir" then
		resumed_has_add_dir = true
		break
	end
end
assert(not resumed_has_add_dir, "Resumed session should not inject --add-dir by default")
print("✓ Resumed session does not inject --add-dir by default (preserves agy saved workspaces)")

-- [Test 7] Resumed session with explicit workspaces passes --add-dir
print("\n[Test 7] Testing resumed session with explicit workspaces...")
local s_resumed_override = session_mod.new({
	conversation_id = "00000000-0000-0000-0000-000000000000",
	cwd = cwd,
	workspaces = { root .. "/explicit/workspace" },
})
if s_resumed_override.proc then
	s_resumed_override.proc:kill(9)
end

local cmd_resumed_override = s_resumed_override:_build_cmd()
local override_has_add_dir = false
for i, v in ipairs(cmd_resumed_override) do
	if v == "--add-dir" and cmd_resumed_override[i + 1] == root .. "/explicit/workspace" then
		override_has_add_dir = true
		break
	end
end
assert(override_has_add_dir, "Resumed session with explicit workspaces must pass --add-dir")
print("✓ Resumed session with explicit workspaces passes --add-dir")

print("\nALL WORKSPACE TESTS PASSED SUCCESSFULLY!")
