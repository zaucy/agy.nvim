local utils = require("agy.utils")

print("--- Testing shorten_path ---")

local cwd = vim.fs.normalize(vim.fn.getcwd())
local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

-- 1. Dynamic current workspace relative path
local res1 = utils.shorten_path(cwd .. "/lua/agy/session.lua", cwd)
print("res1: " .. res1)
assert(res1 == "lua/agy/session.lua", "Expected lua/agy/session.lua, got " .. res1)

-- 2. Exact cwd
local res2 = utils.shorten_path(cwd, cwd)
print("res2: " .. res2)
assert(res2 == ".", "Expected ., got " .. res2)

-- 3. Embedded in CommandLine
local res3 = utils.shorten_path('git status ' .. cwd .. '/tests', cwd)
print("res3: " .. res3)
assert(res3 == "git status tests", 'Expected git status tests, got ' .. res3)

-- 4. POSIX paths
local posix_cwd = "/home/developer/projects/agy.nvim"
local p_res1 = utils.shorten_path("/home/developer/projects/agy.nvim/lua/agy/session.lua", posix_cwd)
print("posix res1: " .. p_res1)
assert(p_res1 == "lua/agy/session.lua", "Expected lua/agy/session.lua, got " .. p_res1)

local p_res2 = utils.shorten_path("/home/developer/projects/agy.nvim", posix_cwd)
print("posix res2: " .. p_res2)
assert(p_res2 == ".", "Expected ., got " .. p_res2)

local p_res3 = utils.shorten_path("/home/developer/projects/agy.nvim/plugin/agy.lua", posix_cwd)
print("posix res3: " .. p_res3)
assert(p_res3 == "plugin/agy.lua", "Expected plugin/agy.lua, got " .. p_res3)

local p_res4 = utils.shorten_path("nu /home/developer/projects/agy.nvim/test.nu", posix_cwd)
print("posix res4: " .. p_res4)
assert(p_res4 == "nu test.nu", "Expected nu test.nu, got " .. p_res4)

local p_res5 = utils.shorten_path("/etc/hosts", posix_cwd)
print("posix res5: " .. p_res5)
assert(p_res5 == "/etc/hosts", "Expected unchanged path, got " .. p_res5)

-- 5. Windows paths (case-insensitivity and backslashes)
if is_win then
  local win_cwd = "C:\\projects\\agy.nvim"
  local w_res1 = utils.shorten_path("C:\\projects\\agy.nvim\\lua\\agy\\session.lua", win_cwd)
  print("win res1: " .. w_res1)
  assert(w_res1 == "lua/agy/session.lua", "Expected lua/agy/session.lua, got " .. w_res1)

  local w_res2 = utils.shorten_path("c:\\projects\\agy.nvim\\tests\\test_e2e_turn.lua", win_cwd)
  print("win res2: " .. w_res2)
  assert(w_res2 == "tests/test_e2e_turn.lua", "Expected tests/test_e2e_turn.lua, got " .. w_res2)

  local w_res3 = utils.shorten_path("C:\\projects\\agy.nvim", win_cwd)
  print("win res3: " .. w_res3)
  assert(w_res3 == ".", "Expected ., got " .. w_res3)

  local w_res4 = utils.shorten_path("C:/projects/agy.nvim/plugin/agy.lua", win_cwd)
  print("win res4: " .. w_res4)
  assert(w_res4 == "plugin/agy.lua", "Expected plugin/agy.lua, got " .. w_res4)

  local w_res5 = utils.shorten_path('cmd /c "dir C:\\projects\\agy.nvim\\tests"', win_cwd)
  print("win res5: " .. w_res5)
  assert(w_res5 == 'cmd /c "dir tests"', 'Expected cmd /c "dir tests", got ' .. w_res5)

  local w_res6 = utils.shorten_path("C:\\Windows\\System32\\notepad.exe", win_cwd)
  print("win res6: " .. w_res6)
  assert(w_res6 == "C:\\Windows\\System32\\notepad.exe", "Expected unchanged path, got " .. w_res6)
end

print("ALL SHORTEN_PATH TESTS PASSED!")
