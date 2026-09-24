-- tests/test_async.lua
-- Comprehensive test suite for agy.async and vim.async integration

local async = require("agy.async")

print("=== Running Antigravity Async Module Tests ===")

-- [Test 1] Module API Surface
print("\n[Test 1] Testing async module API surface...")
assert(type(async.run) == "function", "async.run must be a function")
assert(type(async.wrap) == "function", "async.wrap must be a function")
assert(type(async.await) == "function", "async.await must be a function")
assert(type(async.pawait) == "function", "async.pawait must be a function")
assert(type(async.sleep) == "function", "async.sleep must be a function")
assert(type(async.checkpoint) == "function", "async.checkpoint must be a function")
assert(type(async.semaphore) == "function", "async.semaphore must be a function")
assert(type(async.iter) == "function", "async.iter must be a function")
assert(type(async.system) == "function", "async.system must be a function")
print("✓ API surface verified")

-- [Test 2] async.run and async.sleep execution
print("\n[Test 2] Testing async.run and async.sleep...")
local executed = false
local task1 = async.run(function()
  async.sleep(20)
  executed = true
  return 42
end)

local res = task1:wait()
assert(res == 42, "task1 should return 42, got " .. tostring(res))
assert(executed == true, "task1 should have executed body")
print("✓ async.run and async.sleep verified")

-- [Test 3] async.system process execution
print("\n[Test 3] Testing async.system process execution...")
local task2 = async.run(function()
  local obj = async.system({ "git", "--version" }, { text = true })
  assert(obj ~= nil, "Expected system result")
  assert(obj.code == 0, "git --version should exit with code 0")
  assert(obj.stdout:find("git version"), "Output should contain 'git version'")
  return obj.stdout
end)

local res2 = task2:wait()
assert(type(res2) == "string", "task2 should return string")
print("✓ async.system verified: " .. vim.trim(res2))

-- [Test 4] async.pawait error handling
print("\n[Test 4] Testing async.pawait error protection...")
local task3 = async.run(function()
  local p_ok, p_err = async.pawait(function()
    error("intentional failure inside pawait")
  end)
  assert(p_ok == false, "pawait should return false on error")
  assert(tostring(p_err):find("intentional failure"), "pawait should catch error message")
  return "recovered"
end)

local res3 = task3:wait()
assert(res3 == "recovered", "task3 should return recovered")
print("✓ async.pawait error protection verified")

-- [Test 5] Cooperative cancellation with task:close()
print("\n[Test 5] Testing task cancellation...")
local loops = 0
local cancel_task = async.run(function()
  while true do
    loops = loops + 1
    async.sleep(10)
  end
end)

async.run(function()
  async.sleep(35)
  cancel_task:close()
end):wait()

local ok_close, err_close = cancel_task:pwait()
assert(ok_close == false, "closed task should report failure on pwait")
assert(tostring(err_close):find("closed"), "error should indicate task closed")
assert(cancel_task:completed(), "task should be marked completed after closing")
assert(loops >= 1, "task should have looped at least once before cancel")
print("✓ Cooperative cancellation verified (looped " .. loops .. " times)")

-- [Test 6] Dynamic vim.system mocking with async.system
print("\n[Test 6] Testing dynamic vim.system mocking with async.system...")
local orig_system = vim.system
local mock_called = false

vim.system = function(cmd, opts, on_exit)
  mock_called = true
  if on_exit then
    on_exit({ code = 0, stdout = "MOCKED_ASYNC_OUTPUT\n", stderr = "" })
  end
  return {}
end

local task_mock = async.run(function()
  return async.system({ "mocked", "cmd" }, { text = true })
end)

local res_mock = task_mock:wait()
vim.system = orig_system

assert(mock_called, "mocked vim.system should have been invoked")
assert(res_mock.stdout == "MOCKED_ASYNC_OUTPUT\n", "mocked stdout returned correctly")
print("✓ Dynamic mocking with async.system verified")

-- [Test 7] async.psystem protected process execution
print("\n[Test 7] Testing async.psystem protected process execution...")
local task_psys = async.run(function()
  local ok, obj = async.psystem({ "git", "--version" }, { text = true })
  assert(ok == true, "psystem should return ok=true for valid command")
  assert(obj.code == 0, "psystem should exit with code 0")
  assert(obj.stdout:find("git version"), "Output should contain 'git version'")
  return obj
end)
local res_psys = task_psys:wait()
assert(res_psys ~= nil, "task_psys should return result")
print("✓ async.psystem verified")

-- [Test 8] async.pawait with async function (no 'Not in async context' regression)
print("\n[Test 8] Testing async.pawait with async coroutine function...")
local task_pawait_fn = async.run(function()
  local function inner_async(arg)
    local obj = async.system({ "git", "--version" }, { text = true })
    return arg .. ": " .. vim.trim(obj.stdout)
  end
  local ok, res = async.pawait(inner_async, "TEST")
  assert(ok == true, "pawait should succeed on async coroutine function")
  assert(res:find("TEST: git version"), "pawait should receive returned result from async function, got: " .. tostring(res))
  return res
end)
local res_pawait_fn = task_pawait_fn:wait()
assert(type(res_pawait_fn) == "string", "task_pawait_fn should return string")
print("✓ async.pawait with async function verified without 'Not in async context' error")

-- [Test 9] async.await with async function
print("\n[Test 9] Testing async.await with async function...")
local task_await_fn = async.run(function()
  local function add_one(n)
    return n + 1
  end
  local val = async.await(add_one, 41)
  assert(val == 42, "await should call function and return 42, got: " .. tostring(val))
  return val
end)
local res_await_fn = task_await_fn:wait()
assert(res_await_fn == 42, "task_await_fn should return 42")
print("✓ async.await with async function verified")

print("\n=== All Antigravity Async Module Tests Passed! ===")
