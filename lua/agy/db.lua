local ffi = require("ffi")
local utils = require("agy.utils")

local M = {}

local cdef_loaded = false
local function ensure_cdef()
  if cdef_loaded then return end
  ffi.cdef[[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
    int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_bind_text(sqlite3_stmt *pStmt, int iCol, const char *zData, int nData, void (*xDel)(void *));
    int sqlite3_step(sqlite3_stmt *pStmt);
    const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_finalize(sqlite3_stmt *pStmt);
    int sqlite3_close(sqlite3 *db);
  ]]
  cdef_loaded = true
end

local _sqlite_lib = nil
local _sqlite_checked = false

---Get native SQLite dynamic library using LuaJIT FFI
---@return any|nil lib
function M.get_sqlite_lib()
  if _sqlite_checked then
    return _sqlite_lib
  end
  _sqlite_checked = true
  ensure_cdef()

  local candidates = {}
  if vim.fn.has("win32") == 1 then
    table.insert(candidates, "winsqlite3")
    table.insert(candidates, "sqlite3")
  elseif vim.fn.has("mac") == 1 then
    table.insert(candidates, "sqlite3")
    table.insert(candidates, "/usr/lib/libsqlite3.dylib")
  else
    table.insert(candidates, "sqlite3")
    table.insert(candidates, "libsqlite3.so.0")
    table.insert(candidates, "libsqlite3.so")
  end

  for _, name in ipairs(candidates) do
    local ok, lib = pcall(ffi.load, name)
    if ok and lib then
      _sqlite_lib = lib
      return _sqlite_lib
    end
  end

  return nil
end

---Check if SQLite FFI library is available on the current platform
---@return boolean
function M.is_available()
  return M.get_sqlite_lib() ~= nil
end

---Get path to conversation_summaries.db
---@param app_data_dir? string
---@return string
function M.get_summaries_db_path(app_data_dir)
  return utils.get_conversation_summaries_file(app_data_dir)
end

---Get path to an individual conversation's database file
---@param conversation_id string
---@param app_data_dir? string
---@return string
function M.get_conversation_db_path(conversation_id, app_data_dir)
  assert(conversation_id and conversation_id ~= "", "db.get_conversation_db_path: valid conversation_id required")
  return utils.get_app_data_dir(app_data_dir) .. "/conversations/" .. conversation_id .. ".db"
end

---Safely execute a block with a read-only database connection
---@param db_path string
---@param fn fun(lib: any, db: any): any
---@return boolean success
local function with_db(db_path, fn)
  local lib = M.get_sqlite_lib()
  if not lib then return false end
  if vim.fn.filereadable(db_path) ~= 1 then return false end

  local db = ffi.new("sqlite3*[1]")
  -- SQLITE_OPEN_READONLY = 0x00000001
  local rc = lib.sqlite3_open_v2(db_path, db, 1, nil)
  if rc ~= 0 then return false end

  local ok, err = pcall(fn, lib, db[0])
  lib.sqlite3_close(db[0])
  if not ok then error(err) end
  return true
end

---Execute a read-only prepared query and iterate over rows
---@param db_path string
---@param sql string
---@param params? string[]
---@param row_fn fun(lib: any, stmt: any): boolean? Return false to break early
---@return boolean success
local function query_rows(db_path, sql, params, row_fn)
  return with_db(db_path, function(lib, db)
    local stmt = ffi.new("sqlite3_stmt*[1]")
    local rc = lib.sqlite3_prepare_v2(db, sql, -1, stmt, nil)
    if rc ~= 0 then return end
    if params then
      for i, p in ipairs(params) do
        local str = tostring(p)
        lib.sqlite3_bind_text(stmt[0], i, str, #str, nil)
      end
    end
    while lib.sqlite3_step(stmt[0]) == 100 do -- SQLITE_ROW = 100
      local cont = row_fn(lib, stmt[0])
      if cont == false then break end
    end
    lib.sqlite3_finalize(stmt[0])
  end)
end

---Get the generated title for a specific conversation ID
---@param conversation_id string
---@param app_data_dir? string
---@return string|nil title
function M.get_conversation_title(conversation_id, app_data_dir)
  assert(conversation_id and conversation_id ~= "", "db.get_conversation_title: valid conversation_id required")
  local db_path = M.get_summaries_db_path(app_data_dir)
  local found_title = nil
  query_rows(db_path, "SELECT title FROM conversation_summaries WHERE conversation_id = ?;", { conversation_id }, function(lib, stmt)
    local ptr = lib.sqlite3_column_text(stmt, 0)
    if ptr ~= nil then
      local s = ffi.string(ptr)
      if s ~= "" then
        found_title = s
      end
    end
    return false
  end)
  return found_title
end

---Get a mapping of conversation_id -> title for all conversations that have a non-empty title
---@param app_data_dir? string
---@return table<string, string>
function M.get_all_titles(app_data_dir)
  local db_path = M.get_summaries_db_path(app_data_dir)
  local titles = {}
  query_rows(db_path, "SELECT conversation_id, title FROM conversation_summaries WHERE title != '';", nil, function(lib, stmt)
    local id_ptr = lib.sqlite3_column_text(stmt, 0)
    local title_ptr = lib.sqlite3_column_text(stmt, 1)
    if id_ptr ~= nil and title_ptr ~= nil then
      local cid = ffi.string(id_ptr)
      local t = ffi.string(title_ptr)
      if cid ~= "" and t ~= "" then
        titles[cid] = t
      end
    end
  end)
  return titles
end

---@class AgyDbConversationSummary
---@field conversation_id string
---@field title string
---@field preview string
---@field step_count number
---@field last_modified_time string
---@field workspace_uris string[]
---@field status string

---Get full conversation summary from conversation_summaries.db
---@param conversation_id string
---@param app_data_dir? string
---@return AgyDbConversationSummary|nil
function M.get_conversation_summary(conversation_id, app_data_dir)
  assert(conversation_id and conversation_id ~= "", "db.get_conversation_summary: valid conversation_id required")
  local db_path = M.get_summaries_db_path(app_data_dir)
  local summary = nil
  local sql = "SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status FROM conversation_summaries WHERE conversation_id = ?;"
  query_rows(db_path, sql, { conversation_id }, function(lib, stmt)
    local id_ptr = lib.sqlite3_column_text(stmt, 0)
    local title_ptr = lib.sqlite3_column_text(stmt, 1)
    local prev_ptr = lib.sqlite3_column_text(stmt, 2)
    local step_count = lib.sqlite3_column_int(stmt, 3)
    local lmt_ptr = lib.sqlite3_column_text(stmt, 4)
    local ws_ptr = lib.sqlite3_column_text(stmt, 5)
    local status_ptr = lib.sqlite3_column_text(stmt, 6)

    local ws_raw = ws_ptr ~= nil and ffi.string(ws_ptr) or ""
    local ws_uris = {}
    if ws_raw ~= "" then
      local ok, parsed = pcall(vim.json.decode, ws_raw)
      if ok and type(parsed) == "table" then
        ws_uris = parsed
      end
    end

    summary = {
      conversation_id = id_ptr ~= nil and ffi.string(id_ptr) or conversation_id,
      title = title_ptr ~= nil and ffi.string(title_ptr) or "",
      preview = prev_ptr ~= nil and ffi.string(prev_ptr) or "",
      step_count = step_count,
      last_modified_time = lmt_ptr ~= nil and ffi.string(lmt_ptr) or "",
      workspace_uris = ws_uris,
      status = status_ptr ~= nil and ffi.string(status_ptr) or "",
    }
    return false
  end)
  return summary
end

---@class AgyDbTrajectoryMeta
---@field trajectory_id string
---@field cascade_id string
---@field trajectory_type number
---@field source number

---Get metadata from an individual conversation's database (conversations/<id>.db)
---@param conversation_id string
---@param app_data_dir? string
---@return AgyDbTrajectoryMeta|nil
function M.get_conversation_trajectory_meta(conversation_id, app_data_dir)
  assert(conversation_id and conversation_id ~= "", "db.get_conversation_trajectory_meta: valid conversation_id required")
  local db_path = M.get_conversation_db_path(conversation_id, app_data_dir)
  local meta = nil
  query_rows(db_path, "SELECT trajectory_id, cascade_id, trajectory_type, source FROM trajectory_meta;", nil, function(lib, stmt)
    local traj_ptr = lib.sqlite3_column_text(stmt, 0)
    local casc_ptr = lib.sqlite3_column_text(stmt, 1)
    meta = {
      trajectory_id = traj_ptr ~= nil and ffi.string(traj_ptr) or "",
      cascade_id = casc_ptr ~= nil and ffi.string(casc_ptr) or "",
      trajectory_type = lib.sqlite3_column_int(stmt, 2),
      source = lib.sqlite3_column_int(stmt, 3),
    }
    return false
  end)
  return meta
end

return M
