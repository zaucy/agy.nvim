---@class AgyAsync
---Structured async and concurrency primitives powered by Neovim 0.13+ vim.async.
local M = {}

assert(vim.async, "agy.nvim requires Neovim 0.13+ with built-in vim.async")

---Spawn a new async task.
---@param func fun(...: any): any
---@param ... any
---@return vim.async.Task<any>
function M.run(func, ...)
  return vim.async.run(func, ...)
end

---Wrap a callback-taking function into an awaitable async function.
---@param argc integer Argument position where callback will be placed
---@param func fun(...: any): any
---@return async fun(...: any): any
function M.wrap(argc, func)
  return vim.async.wrap(argc, func)
end

---Await an async task or callback function inside an async task.
---If passed a regular or async function, executes it in the current coroutine context.
---@param ... any
---@return any ...
function M.await(...)
  local arg1 = select(1, ...)
  if type(arg1) == "function" then
    return arg1(select(2, ...))
  end
  return vim.async.await(...)
end

---Protected await. Async equivalent of pcall(), returning ok, result_or_err.
---Accepts a Task, callback-taking function (argc, func, ...), or an async function (func, ...).
---@param ... any
---@return boolean ok, any ...
function M.pawait(...)
  local arg1 = select(1, ...)
  if type(arg1) == "function" then
    return pcall(...)
  end
  return vim.async.pawait(...)
end

---Asynchronously sleep for ms milliseconds without blocking the Neovim event loop.
---@param ms integer
function M.sleep(ms)
  return vim.async.sleep(ms)
end

---Cooperative checkpoint allowing other tasks or event loop iterations to run.
function M.checkpoint()
  return vim.async.checkpoint()
end

---Create a semaphore limiting concurrency.
---@param permits integer
---@return vim.async.Semaphore
function M.semaphore(permits)
  return vim.async.semaphore(permits)
end

---Iterate completed tasks in completion order.
---@param tasks vim.async.Task<any>[]
---@return fun(): vim.async.Task<any>?
function M.iter(tasks)
  return vim.async.iter(tasks)
end

---Execute an external process asynchronously via vim.system without blocking.
---Must be called within an async task context (vim.async.run).
---@param cmd string[] Command and arguments
---@param opts? vim.SystemOpts System options
---@return vim.SystemCompleted
function M.system(cmd, opts)
  return vim.async.await(3, vim.system, cmd, opts)
end

---Execute an external process asynchronously via vim.system in protected mode without blocking.
---Must be called within an async task context (vim.async.run).
---Returns ok, obj_or_err.
---@param cmd string[] Command and arguments
---@param opts? vim.SystemOpts System options
---@return boolean ok, vim.SystemCompleted|string
function M.psystem(cmd, opts)
  return vim.async.pawait(3, vim.system, cmd, opts)
end

return M
