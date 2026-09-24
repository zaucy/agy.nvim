-- tests/test_db.lua
-- Unit and integration tests for Antigravity SQLite database abstraction (lua/agy/db.lua)

local db = require("agy.db")
local transcript = require("agy.transcript")
local ffi = require("ffi")

print("=== Running Antigravity Database Abstraction Tests ===")

-- [Test 1] Testing db.is_available() and library loading
print("\n[Test 1] Testing db.is_available() and get_sqlite_lib()...")
assert(db.is_available(), "SQLite FFI library should be available on standard environments")
local lib = db.get_sqlite_lib()
assert(lib ~= nil, "SQLite library handle should not be nil")
print("✓ SQLite library successfully loaded via LuaJIT FFI")

-- [Test 2] Testing path helpers
print("\n[Test 2] Testing database path helpers...")
local dummy_dir = "C:/tmp/test_gemini"
local s_path = db.get_summaries_db_path(dummy_dir)
assert(s_path:find("conversation_summaries%.db$") ~= nil, "Expected conversation_summaries.db path: " .. s_path)

local c_path = db.get_conversation_db_path("test-1234", dummy_dir)
assert(c_path:find("conversations/test%-1234%.db$") ~= nil, "Expected conversations/test-1234.db path: " .. c_path)
print("✓ Path helpers verified")

-- [Test 3] Testing fail-fast assertions per AGENTS.md
print("\n[Test 3] Testing fail-fast assertions...")
local ok, err

ok, err = pcall(db.get_conversation_title, nil)
assert(not ok and err:find("conversation_id required"), "get_conversation_title should assert non-nil conversation_id")

ok, err = pcall(db.get_conversation_title, "")
assert(not ok and err:find("conversation_id required"), "get_conversation_title should assert non-empty conversation_id")

ok, err = pcall(db.get_conversation_summary, nil)
assert(not ok and err:find("conversation_id required"), "get_conversation_summary should assert non-nil conversation_id")

ok, err = pcall(db.get_conversation_trajectory_meta, nil)
assert(not ok and err:find("conversation_id required"), "get_conversation_trajectory_meta should assert non-nil conversation_id")

ok, err = pcall(db.get_conversation_db_path, "")
assert(not ok and err:find("conversation_id required"), "get_conversation_db_path should assert non-empty conversation_id")
print("✓ AGENTS.md fail-fast assertions verified")

-- [Test 4] Mock database setup and queries
print("\n[Test 4] Testing mock database queries...")
local tmp_root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(tmp_root, "p")
local test_app_dir = vim.fs.joinpath(tmp_root, ".gemini", "antigravity-cli")
vim.fn.mkdir(test_app_dir, "p")
local conv_dir = vim.fs.joinpath(test_app_dir, "conversations")
vim.fn.mkdir(conv_dir, "p")

local mock_db_file = vim.fs.joinpath(test_app_dir, "conversation_summaries.db")

-- Create mock conversation_summaries.db using SQLite C API
ffi.cdef[[
  int sqlite3_open(const char *filename, sqlite3 **ppDb);
  int sqlite3_exec(sqlite3 *db, const char *sql, int (*callback)(void*,int,char**,char**), void *arg, char **errmsg);
]]

local db_h = ffi.new("sqlite3*[1]")
local rc = lib.sqlite3_open(mock_db_file, db_h)
assert(rc == 0, "Failed to create mock conversation_summaries.db: " .. rc)

local schema_sql = [[
CREATE TABLE conversation_summaries (
  conversation_id text PRIMARY KEY,
  title text NOT NULL DEFAULT "",
  preview text NOT NULL DEFAULT "",
  step_count integer NOT NULL DEFAULT 0,
  last_modified_time datetime NOT NULL,
  workspace_uris text NOT NULL,
  status text NOT NULL DEFAULT ""
);
INSERT INTO conversation_summaries VALUES (
  'conv-test-1111',
  'Summary: Tree Haiku Exploration',
  'Write a short haiku about trees',
  3,
  '2026-09-24 04:30:00.0000000+00:00',
  '["file:///C:/Users/test/workspace1"]',
  'CASCADE_RUN_STATUS_RUNNING'
);
INSERT INTO conversation_summaries VALUES (
  'conv-test-2222',
  'Quantum Computing Primer',
  'Explain quantum computing in one sentence',
  5,
  '2026-09-24 04:35:00.0000000+00:00',
  '["file:///C:/Users/test/workspace2"]',
  'CASCADE_RUN_STATUS_DONE'
);
INSERT INTO conversation_summaries VALUES (
  'conv-test-3333',
  '',
  'Empty title turn',
  1,
  '2026-09-24 04:36:00.0000000+00:00',
  '["file:///C:/Users/test/workspace1"]',
  'CASCADE_RUN_STATUS_DONE'
);
]]

rc = lib.sqlite3_exec(db_h[0], schema_sql, nil, nil, nil)
assert(rc == 0, "Failed to populate mock conversation_summaries.db")
lib.sqlite3_close(db_h[0])

-- Test get_conversation_title
local title1 = db.get_conversation_title("conv-test-1111", test_app_dir)
assert(title1 == "Summary: Tree Haiku Exploration", "Expected title1 to match: " .. tostring(title1))

local title2 = db.get_conversation_title("conv-test-2222", test_app_dir)
assert(title2 == "Quantum Computing Primer", "Expected title2 to match: " .. tostring(title2))

local title3 = db.get_conversation_title("conv-test-3333", test_app_dir)
assert(title3 == nil, "Empty title should return nil, got: " .. tostring(title3))

local title_missing = db.get_conversation_title("conv-test-nonexistent", test_app_dir)
assert(title_missing == nil, "Nonexistent conversation should return nil")
print("✓ db.get_conversation_title verified")

-- Test get_all_titles
local all_titles = db.get_all_titles(test_app_dir)
assert(all_titles["conv-test-1111"] == "Summary: Tree Haiku Exploration", "Expected conv-test-1111 in all_titles")
assert(all_titles["conv-test-2222"] == "Quantum Computing Primer", "Expected conv-test-2222 in all_titles")
assert(all_titles["conv-test-3333"] == nil, "Empty title should not be in all_titles")
print("✓ db.get_all_titles verified")

-- Test get_conversation_summary
local summ = db.get_conversation_summary("conv-test-1111", test_app_dir)
assert(summ ~= nil, "Expected summary table")
assert(summ.conversation_id == "conv-test-1111", "Summary conversation_id")
assert(summ.title == "Summary: Tree Haiku Exploration", "Summary title")
assert(summ.preview == "Write a short haiku about trees", "Summary preview")
assert(summ.step_count == 3, "Summary step_count")
assert(summ.status == "CASCADE_RUN_STATUS_RUNNING", "Summary status")
assert(#summ.workspace_uris == 1, "Expected 1 workspace URI")
assert(summ.workspace_uris[1] == "file:///C:/Users/test/workspace1", "Workspace URI")
print("✓ db.get_conversation_summary verified")

-- [Test 5] Individual conversation database (conversations/<id>.db)
print("\n[Test 5] Testing individual conversation database queries...")
local mock_indiv_file = vim.fs.joinpath(conv_dir, "conv-test-1111.db")
local indiv_h = ffi.new("sqlite3*[1]")
rc = lib.sqlite3_open(mock_indiv_file, indiv_h)
assert(rc == 0, "Failed to create mock indiv db")

local indiv_schema = [[
CREATE TABLE trajectory_meta (
  trajectory_id text PRIMARY KEY,
  cascade_id text,
  trajectory_type integer,
  source integer
);
INSERT INTO trajectory_meta VALUES ('traj-abc-123', 'conv-test-1111', 1, 2);
]]
rc = lib.sqlite3_exec(indiv_h[0], indiv_schema, nil, nil, nil)
assert(rc == 0, "Failed to populate indiv db")
lib.sqlite3_close(indiv_h[0])

local meta = db.get_conversation_trajectory_meta("conv-test-1111", test_app_dir)
assert(meta ~= nil, "Expected trajectory meta")
assert(meta.trajectory_id == "traj-abc-123", "Meta trajectory_id")
assert(meta.cascade_id == "conv-test-1111", "Meta cascade_id")
assert(meta.trajectory_type == 1, "Meta trajectory_type")
assert(meta.source == 2, "Meta source")
print("✓ db.get_conversation_trajectory_meta verified")

-- [Test 6] Integration with transcript.read_history
print("\n[Test 6] Testing integration with transcript.read_history...")
local history_file = vim.fs.joinpath(test_app_dir, "history.jsonl")
local lines = {
  vim.json.encode({
    conversationId = "conv-test-1111",
    display = "Raw prompt: Write a haiku",
    timestamp = 1700000000000,
    workspace = "C:/Users/test/workspace1",
  }),
  vim.json.encode({
    conversationId = "conv-test-3333",
    display = "Raw prompt: Third prompt without generated title",
    timestamp = 1700000100000,
    workspace = "C:/Users/test/workspace1",
  }),
}
vim.fn.writefile(lines, history_file)

local history = transcript.read_history(test_app_dir)
assert(#history == 2, "Expected 2 history items")

-- The first conversation should be conv-test-3333 (newer timestamp)
local c3333 = history[1].conversation_id == "conv-test-3333" and history[1] or history[2]
local c1111 = history[1].conversation_id == "conv-test-1111" and history[1] or history[2]

-- c1111 has a database title: "Summary: Tree Haiku Exploration"
assert(c1111.title == "Summary: Tree Haiku Exploration", "Title should be enriched from DB: " .. c1111.title)
assert(c1111.last_prompt == "Raw prompt: Write a haiku", "last_prompt should retain raw prompt")

-- c3333 has an empty DB title: should use entry.display
assert(c3333.title == "Raw prompt: Third prompt without generated title", "Title should fall back to display: " .. c3333.title)

print("✓ transcript.read_history database title enrichment verified")

-- [Test 7] Safety with non-existent database file
print("\n[Test 7] Testing safety when database file does not exist...")
local empty_dir = vim.fs.joinpath(tmp_root, "empty_dir")
vim.fn.mkdir(empty_dir, "p")

local safe_title = db.get_conversation_title("nonexistent", empty_dir)
assert(safe_title == nil, "Safe title should be nil")

local safe_titles = db.get_all_titles(empty_dir)
assert(vim.tbl_isempty(safe_titles), "Safe titles should be empty table")

local safe_summary = db.get_conversation_summary("nonexistent", empty_dir)
assert(safe_summary == nil, "Safe summary should be nil")

local safe_meta = db.get_conversation_trajectory_meta("nonexistent", empty_dir)
assert(safe_meta == nil, "Safe meta should be nil")
print("✓ Non-existent database safety verified")

-- Cleanup temporary directory
pcall(vim.fn.delete, tmp_root, "rf")

print("\nALL ANTIGRAVITY DATABASE ABSTRACTION TESTS PASSED PERFECTLY!")
