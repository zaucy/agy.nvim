-- tests/test_artifacts.lua
-- Comprehensive test suite for Antigravity /artifacts slash command,
-- pure document rendering, interactive line commenting, memory preservation,
-- unsaved comments indicator (*), - up navigation, and :AgyArtifacts.

local artifacts = require("agy.artifacts")
local completion = require("agy.completion")
local protocol = require("agy.protocol")
local config = require("agy.config")
local agy = require("agy")

print("=== Running Antigravity Artifacts & Review Tests ===")

-- Setup mock test environment
local tmp_root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(tmp_root, "p")
local test_app_dir = vim.fs.joinpath(tmp_root, ".gemini", "antigravity-cli")
local conv_id = "test-conv-artifacts-42"
local brain_dir = vim.fs.joinpath(test_app_dir, "brain", conv_id)
vim.fn.mkdir(brain_dir, "p")

-- Create sample artifacts with metadata
local art1_path = vim.fs.joinpath(brain_dir, "implementation_plan.md")
local art1_content = {
  "# Implementation Plan: Sample Feature",
  "",
  "## Goals",
  "Build high performance agent tools.",
  "",
  "## Changes",
  "Modify core modules.",
  "",
  "Line 9: Sample statement",
  "Line 10: Another statement",
}
vim.fn.writefile(art1_content, art1_path)

local art1_meta = {
  summary = "Implementation plan for sample feature",
  updatedAt = "2026-09-22T10:00:00Z",
  requestFeedback = true,
  userFacing = true,
}
vim.fn.writefile({ vim.json.encode(art1_meta) }, art1_path .. ".metadata.json")

-- Create second artifact (walkthrough) updated slightly earlier
local art2_path = vim.fs.joinpath(brain_dir, "walkthrough.md")
local art2_content = {
  "# Walkthrough: Sample Accomplishment",
  "",
  "Completed feature with tests.",
}
vim.fn.writefile(art2_content, art2_path)

-- Create non-artifact file and system dirs to test filtering
vim.fn.mkdir(vim.fs.joinpath(brain_dir, ".system_generated"), "p")
vim.fn.writefile({ "log line" }, vim.fs.joinpath(brain_dir, ".system_generated", "steps.log"))
vim.fn.mkdir(vim.fs.joinpath(brain_dir, "scratch"), "p")
vim.fn.writefile({ "scratch" }, vim.fs.joinpath(brain_dir, "scratch", "temp.py"))

-- Configure agy with test app_data_dir
config.setup({
  app_data_dir = test_app_dir,
})

-- [Test 1] Testing artifact discovery and metadata loading
print("\n[Test 1] Testing artifact discovery and metadata loading...")
local arts = artifacts.get_artifacts(conv_id, test_app_dir)
assert(#arts == 2, "Expected exactly 2 artifacts, got " .. tostring(#arts))
local art_map = {}
for _, a in ipairs(arts) do
  art_map[a.filename] = a
end

assert(art_map["implementation_plan.md"] ~= nil, "Expected implementation_plan.md to be discovered")
assert(art_map["implementation_plan.md"].summary == "Implementation plan for sample feature", "Expected summary")
assert(art_map["implementation_plan.md"].request_feedback == true, "Expected request_feedback = true")
assert(art_map["walkthrough.md"] ~= nil, "Expected walkthrough.md to be discovered")

local latest = artifacts.get_latest_artifact(conv_id, test_app_dir)
assert(latest ~= nil, "Expected latest artifact")
assert(latest.filename == "implementation_plan.md" or latest.filename == "walkthrough.md", "Expected valid filename")
print("✓ Artifact discovery and metadata parsing verified")

-- [Test 2] Testing completion.complete_artifacts and unsaved comments indicator (*)
print("\n[Test 2] Testing complete_artifacts with clean and unsaved comments...")
local comp_items = completion.complete_artifacts("", conv_id, test_app_dir)
assert(#comp_items == 2, "Expected 2 completion items, got " .. tostring(#comp_items))

-- Currently no unsaved comments
for _, item in ipairs(comp_items) do
  assert(not item.label:find(" %*"), "Clean artifact should not have asterisk in label: " .. item.label)
  assert(not item.detail:find("%[%*"), "Clean artifact should not have [* in detail: " .. item.detail)
end

-- Add pending comment for implementation_plan.md
artifacts.set_comment(conv_id, "implementation_plan.md", 4, 4, "Needs clarification on API design")
assert(artifacts.has_unsaved_comments(conv_id, "implementation_plan.md") == true, "Expected has_unsaved_comments to be true")
assert(artifacts.get_comments_count(conv_id, "implementation_plan.md") == 1, "Expected comments count = 1")

-- Check completion again
local comp_with_star = completion.complete_artifacts("plan", conv_id, test_app_dir)
assert(#comp_with_star == 1, "Expected 1 matching completion item")
local plan_item = comp_with_star[1]
assert(plan_item.label:find(" %*"), "Expected label to have asterisk indicator, got: " .. plan_item.label)
assert(plan_item.detail:find("%[%* 1 unsaved comment%]"), "Expected detail to badge unsaved comment, got: " .. plan_item.detail)
assert(plan_item.insert_text:find("^implementation_plan%.md"), "insert_text must not include trailing asterisk")
print("✓ complete_artifacts and unsaved comments asterisk indicator verified")

-- [Test 3] Testing render_artifact pure document and virtual lines
print("\n[Test 3] Testing render_artifact pure document line matching and comment extmarks...")
local test_buf = vim.api.nvim_create_buf(false, true)
artifacts.render_artifact(test_buf, conv_id, "implementation_plan.md")

-- Pure document line verification
local lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
assert(#lines == #art1_content, string.format("Expected buffer lines (%d) to match document lines (%d)", #lines, #art1_content))
assert(lines[1] == "Implementation Plan: Sample Feature", "Expected line 1 to be clean header text: " .. lines[1])
assert(lines[4] == "Build high performance agent tools.", "Expected line 4 to be document line 4")

-- Verify comment virtual lines
local extmarks = vim.api.nvim_buf_get_extmarks(test_buf, artifacts.NS_COMMENTS, 0, -1, { details = true })
assert(#extmarks == 1, "Expected 1 comment extmark, got " .. tostring(#extmarks))
local ext_details = extmarks[1][4]
assert(ext_details.virt_lines ~= nil, "Expected virt_lines in extmark details")
local virt_text = ext_details.virt_lines[1][1][1]
assert(virt_text:find("L4:"), "Expected virt line text to reference L4, got: " .. virt_text)
assert(virt_text:find("💬"), "Expected virt line text to include review_comment icon (💬)")

-- Multi-line comment range test
artifacts.set_comment(conv_id, "implementation_plan.md", 6, 8, "Refactor this entire block")
artifacts.refresh_comment_extmarks(test_buf, conv_id, "implementation_plan.md")
local updated_extmarks = vim.api.nvim_buf_get_extmarks(test_buf, artifacts.NS_COMMENTS, 0, -1, { details = true })
assert(#updated_extmarks == 2, "Expected 2 comment extmarks, got " .. tostring(#updated_extmarks))

local found_range = false
for _, em in ipairs(updated_extmarks) do
  local vt = em[4].virt_lines[1][1][1]
  if vt:find("L6%-L8:") then
    found_range = true
    break
  end
end
assert(found_range, "Expected range L6-L8 in comment extmark")
print("✓ render_artifact pure document lines and comment virtual lines verified")

-- [Test 4] Testing delete_comment
print("\n[Test 4] Testing delete_comment functionality...")
local deleted = artifacts.delete_comment(conv_id, "implementation_plan.md", 7)
assert(deleted == true, "Expected comment on range 6-8 covering line 7 to be deleted")
assert(artifacts.get_comments_count(conv_id, "implementation_plan.md") == 1, "Expected 1 comment remaining")

local deleted_nonexistent = artifacts.delete_comment(conv_id, "implementation_plan.md", 99)
assert(deleted_nonexistent == false, "Expected false for nonexistent comment line")
print("✓ delete_comment verified")

-- [Test 5] Testing memory preservation across navigations
print("\n[Test 5] Testing comment memory preservation across navigations...")
-- Navigate away (simulate closing buffer or switching)
pcall(vim.api.nvim_buf_delete, test_buf, { force = true })

-- Comments should still exist in memory cache
assert(artifacts.has_unsaved_comments(conv_id, "implementation_plan.md") == true, "Expected comments to remain in memory")
local cached_comments = artifacts.get_comments(conv_id, "implementation_plan.md")
assert(cached_comments[4] ~= nil, "Expected comment on L4 to be preserved in cache")

-- Reopening artifact restores comments and extmarks
local reopened_buf = vim.api.nvim_create_buf(false, true)
artifacts.render_artifact(reopened_buf, conv_id, "implementation_plan.md")
local restored_extmarks = vim.api.nvim_buf_get_extmarks(reopened_buf, artifacts.NS_COMMENTS, 0, -1, { details = true })
assert(#restored_extmarks == 1, "Expected restored comment extmark")
assert(vim.bo[reopened_buf].modified == true, "Buffer with unsaved comments should have modified = true")
pcall(vim.api.nvim_buf_delete, reopened_buf, { force = true })
print("✓ Comment memory preservation across buffer reload verified")

-- [Test 6] Testing submit_review formatting and session dispatch on :w
print("\n[Test 6] Testing submit_review payload formatting and dispatch...")
local sent_payload = nil
local mock_session = {
  is_active = true,
  turn_active = false,
  send_prompt = function(self, payload)
    sent_payload = payload
    return true
  end,
}

local conv_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(conv_buf, "agy://" .. conv_id)
protocol.buffers[conv_buf] = {
  buf = conv_buf,
  conversation_id = conv_id,
  session = mock_session,
  config = config.get(),
  stream_info = {},
}

local art_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(art_buf, "agy://" .. conv_id .. "/artifacts/implementation_plan.md")
protocol.buffers[art_buf] = {
  buf = art_buf,
  conversation_id = conv_id,
  artifact_filename = "implementation_plan.md",
  is_artifact = true,
  config = config.get(),
}

-- Submit review
artifacts.submit_review(art_buf, conv_id, "implementation_plan.md")

assert(sent_payload ~= nil, "Expected payload to be dispatched through session")
assert(sent_payload:find("Review comments on implementation_plan.md:"), "Expected review header in payload")
assert(sent_payload:find("L4: Needs clarification on API design"), "Expected L4: <comment> format in payload")

-- Comments should be cleared from cache
assert(artifacts.has_unsaved_comments(conv_id, "implementation_plan.md") == false, "Comments should be cleared after submit")
assert(artifacts.get_comments_count(conv_id, "implementation_plan.md") == 0, "Comments count should be 0")

-- Saving when no comments exist is a silent no-op
sent_payload = nil
artifacts.submit_review(art_buf, conv_id, "implementation_plan.md")
assert(sent_payload == nil, "Expected silent no-op when saving with 0 comments")
print("✓ submit_review formatting and silent no-op verified")

-- [Test 7] Testing protocol URL routing agy://<conv_id>/artifacts/<filename>
print("\n[Test 7] Testing protocol handle_buf_read with artifact URLs...")
local url_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(url_buf, "agy://" .. conv_id .. "/artifacts/walkthrough.md")
protocol.handle_buf_read({
  buf = url_buf,
  file = "agy://" .. conv_id .. "/artifacts/walkthrough.md",
})

local st = protocol.buffers[url_buf]
assert(st ~= nil, "Expected buffer state to be created for artifact buffer")
assert(st.is_artifact == true, "Expected is_artifact = true")
assert(st.artifact_filename == "walkthrough.md", "Expected artifact_filename = walkthrough.md")

local url_lines = vim.api.nvim_buf_get_lines(url_buf, 0, -1, false)
assert(#url_lines == #art2_content, "Expected lines to match walkthrough.md")
assert(url_lines[1] == "Walkthrough: Sample Accomplishment", "Expected correct line 1")
print("✓ Protocol handle_buf_read artifact URL routing verified")

-- [Test 8] Testing protocol bare /artifacts routing defaults to latest
print("\n[Test 8] Testing protocol bare /artifacts URL defaults to latest artifact...")
local bare_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bare_buf, "agy://" .. conv_id .. "/artifacts")
protocol.handle_buf_read({
  buf = bare_buf,
  file = "agy://" .. conv_id .. "/artifacts",
})

local bare_st = protocol.buffers[bare_buf]
assert(bare_st ~= nil and bare_st.is_artifact == true, "Expected bare /artifacts to load latest artifact")
assert(bare_st.artifact_filename ~= nil and bare_st.artifact_filename ~= "", "Expected resolved artifact filename")
print("✓ Bare /artifacts URL routing to latest artifact verified")

-- [Test 9] Testing AGENTS.md assertions on missing icons and arguments
print("\n[Test 9] Testing AGENTS.md fail-fast assertions...")
local cfg_no_icon = vim.deepcopy(config.get())
cfg_no_icon.icons.review_comment = nil

local assert_ok, err = pcall(function()
  artifacts.refresh_comment_extmarks(url_buf, conv_id, "walkthrough.md", cfg_no_icon)
end)
assert(not assert_ok, "Expected fail-fast error when review_comment icon is missing")
assert(tostring(err):find("review_comment"), "Expected error message to mention review_comment")

local assert_arg_ok, err_arg = pcall(function()
  artifacts.get_artifacts("")
end)
assert(not assert_arg_ok, "Expected fail-fast error on empty conv_id")
print("✓ AGENTS.md fail-fast assertions verified")

-- [Test 10] Testing :AgyArtifacts user command registration
print("\n[Test 10] Testing AgyArtifacts user command and completion...")
local commands = vim.api.nvim_get_commands({})
assert(commands["AgyArtifacts"] ~= nil, "Expected AgyArtifacts command to be registered in Neovim")

local comp_candidates = agy.complete_artifacts("walk")
assert(#comp_candidates >= 1, "Expected complete_artifacts to match walkthrough")
assert(comp_candidates[1]:find("walkthrough%.md"), "Expected walkthrough.md in completion candidates")
print("✓ :AgyArtifacts user command and completion verified")

-- [Test 11] Testing RequestFeedback: true artifact turn stopping
print("\n[Test 11] Testing RequestFeedback: true artifact turn stopping...")
vim.cmd("edit! agy://new")
local art_buf = vim.api.nvim_get_current_buf()
local art_st = protocol.buffers[art_buf]

local stop_called = false
art_st.session.turn_active = true
art_st.session.stop = function()
  stop_called = true
  art_st.session.turn_active = false
end

-- 1. write_to_file tool with RequestFeedback: true
art_st.session.on_step_update(art_st.session, {
  step_type = "tool",
  tool_name = "write_to_file",
  state = "ACTIVE",
  tool_info = {
    name = "write_to_file",
    parameters = {
      TargetFile = "implementation_plan.md",
      ArtifactMetadata = {
        RequestFeedback = true,
        Summary = "Implementation plan for feature",
      },
    },
  },
})

assert(art_st.pending_artifact_feedback ~= nil, "pending_artifact_feedback must be tracked")
assert(art_st.pending_artifact_feedback.filename == "implementation_plan.md", "Filename must match")

-- 2. Agent provides text delta
art_st.session.on_step_update(art_st.session, {
  step_type = "agent_response",
  state = "ACTIVE",
  text_delta = "Here is the implementation plan.",
})

-- 3. If agent attempts to execute another tool before user review, turn is stopped
art_st.session.on_step_update(art_st.session, {
  step_type = "tool",
  tool_name = "run_command",
  state = "ACTIVE",
  tool_info = {
    name = "run_command",
    parameters = { CommandLine = "cargo build" },
  },
})

assert(stop_called == true, "Turn must be stopped before subsequent tool can execute")
assert(art_st.pending_artifact_feedback == nil, "pending_artifact_feedback must be cleared after stop")

protocol.cleanup_buffer(art_buf)
print("✓ RequestFeedback: true prevents subsequent tool execution and stops turn")

-- Cleanup test files
pcall(vim.fn.delete, tmp_root, "rf")

print("\nALL ARTIFACTS & REVIEW TESTS PASSED PERFECTLY!")
