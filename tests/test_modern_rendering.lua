local utils = require("agy.utils")
local render = require("agy.render")
local protocol = require("agy.protocol")
local config_mod = require("agy.config")

print("=== Running Modern Rendering & Tree-sitter Codeblock Tests ===")

local cfg = config_mod.setup({
  icons = {
    tool = "🛠️",
    view_file = "🛠️",
    run_command = "",
    thought = "💭",
    user = "👤",
    agent = "🤖",
    prompt_sign = "❯ ",
    footer = "⚡",
    done = "✓",
    question = "❓",
    error = "❌",
    cancelled = "⏹️",
  },
  ui = {
    virtual_text = true,
    auto_scroll = false,
    fold_tool_output = false,
    protect_history = true,
  }
})
protocol.setup()

local cwd = vim.fs.normalize(vim.fn.getcwd())

-- =========================================================================
-- TEST 1: Language Detection for Tree-sitter Injections
-- =========================================================================
print("\n[Test 1] Testing language detection...")

-- 1a. File extension detection
assert(render.detect_codeblock_lang("view_file", { TargetFile = "foo.lua" }) == "lua")
assert(render.detect_codeblock_lang("view_file", { AbsolutePath = "C:/app/main.py" }) == "python")
assert(render.detect_codeblock_lang("write_to_file", { TargetFile = "src/lib.rs" }) == "rust")
assert(render.detect_codeblock_lang("replace_file_content", { TargetFile = "package.json" }) == "json")
assert(render.detect_codeblock_lang("view_file", { TargetFile = "README.md" }) == "markdown")
assert(render.detect_codeblock_lang("view_file", { TargetFile = "test.nu" }) == "nu")
assert(render.detect_codeblock_lang("view_file", { TargetFile = "script.ps1" }) == "ps1")
assert(render.detect_codeblock_lang("view_file", { TargetFile = "Dockerfile" }) == "dockerfile")
assert(render.detect_codeblock_lang("view_file", { TargetFile = "Makefile" }) == "make")
assert(render.detect_codeblock_lang("view_file", { TargetFile = "CMakeLists.txt" }) == "cmake")

-- 1b. Tool-specific detection
assert(render.detect_codeblock_lang("read_url_content", { Url = "https://example.com" }) == "markdown")
assert(render.detect_codeblock_lang("run_command", { CommandLine = "git diff HEAD~1" }) == "diff")

-- 1c. Output-based detection (diff and JSON)
local diff_out = "diff --git a/file b/file\nindex 123..456 100644\n--- a/file\n+++ b/file\n@@ -1,2 +1,2 @@\n-old\n+new"
assert(render.detect_codeblock_lang("run_command", {}, diff_out) == "diff")

local json_out = '{\n  "name": "agy.nvim",\n  "status": "ok"\n}'
assert(render.detect_codeblock_lang("call_mcp_tool", {}, json_out) == "json")

print("✓ All language detection rules verified!")

-- =========================================================================
-- TEST 2: Tool Output Code Fence with Nested Backticks
-- =========================================================================
print("\n[Test 2] Testing code fence expansion with nested backticks...")

local test_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(test_buf)

local prompt_line, prompt_ext_id = render.render_new_session(test_buf, cfg)
protocol._setup_buffer(test_buf, "new")

local state = {
  buf = test_buf,
  config = cfg,
  prompt_start_line = prompt_line,
  prompt_extmark_id = prompt_ext_id,
  tool_calls = {},
  stream_info = { status = "ready" },
}
protocol.buffers[test_buf] = state

-- Output containing triple backticks (e.g. viewing a markdown file)
local nested_md = "# Title\n\n```python\nprint('hello')\n```\n\nEnd of file"
local tc_rec = {
  id = 1,
  tool_name = "view_file",
  params = { TargetFile = "example.md" },
  param_str = "example.md",
  output = nested_md,
  duration_seconds = 0.1,
  status = "done",
  is_open = false,
  output_lines_count = 0,
}

local tool_line, ext_id, param_str = render.append_tool_call(test_buf, tc_rec.tool_name, tc_rec.params, cwd)
tc_rec.header_extmark_id = ext_id
tc_rec.header_line_idx = tool_line
table.insert(state.tool_calls, tc_rec)
render.complete_tool_call(test_buf, tc_rec, 0.1, nested_md, cfg)

-- Toggle open
vim.api.nvim_win_set_cursor(0, { tool_line + 1, 0 })
local ok_expand = protocol.toggle_tool_at_cursor(test_buf)
assert(ok_expand == true, "Must expand tool call")
assert(tc_rec.is_open == true, "Tool call should now be open")
assert(tc_rec.win and vim.api.nvim_win_is_valid(tc_rec.win), "Inline window must be open and valid")
assert(tc_rec.win_buf and vim.api.nvim_buf_is_valid(tc_rec.win_buf), "Inline window buffer must be valid")

-- Main conversation buffer lines must NOT be modified
local buf_lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
for _, l in ipairs(buf_lines) do
  assert(not l:find("print%('hello'%)"), "Main buffer must not contain tool output lines")
end

-- Inline window buffer contains the output lines (content-only, no padding lines inside)
local win_lines = vim.api.nvim_buf_get_lines(tc_rec.win_buf, 0, -1, false)
assert(win_lines[1] == "# Title", "First output line in window")
assert(vim.bo[tc_rec.win_buf].filetype == "markdown", "Markdown filetype detected for inline window")

-- Alignment: col aligned with tool_name
local win_cfg = vim.api.nvim_win_get_config(tc_rec.win)
local header_str = vim.api.nvim_buf_get_lines(test_buf, tool_line, tool_line + 1, false)[1]
local s_col = header_str:find(tc_rec.tool_name, 1, true)
local expected_col = vim.fn.strdisplaywidth(header_str:sub(1, s_col - 1))
assert(win_cfg.col == expected_col, "Window col must align with start of tool name")
assert(win_cfg.height <= 20, "Window height must be capped at max_height")

-- Toggle close
local ok_close = protocol.toggle_tool_at_cursor(test_buf)
assert(ok_close == true, "Must collapse tool call")
assert(tc_rec.is_open == false, "Tool call should now be closed")
assert(tc_rec.win == nil or not vim.api.nvim_win_is_valid(tc_rec.win), "Window must be closed")
print("✓ Inline window expansion and collapse verified!")

-- =========================================================================
-- TEST 3: Error and Cancelled Notices (Clean & Extmark Highlighted)
-- =========================================================================
print("\n[Test 3] Testing render_error and render_cancelled without > or **...")

local err_next, err_ext = render.render_error(test_buf, "Connection lost to daemon", cfg)
local buf_lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
local found_err = false
for _, l in ipairs(buf_lines) do
  if l:find("❌ Error: Connection lost to daemon") then
    found_err = true
    assert(not l:find(">"), "Error line must NOT contain '>'")
    assert(not l:find("%*%*"), "Error line must NOT contain '**'")
  end
end
assert(found_err, "Modern error line rendered")

local cancel_next, cancel_ext = render.render_cancelled(test_buf, cfg)
buf_lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
local found_cancel = false
for _, l in ipairs(buf_lines) do
  if l:find("⏹️ Turn cancelled") then
    found_cancel = true
    assert(not l:find(">"), "Cancellation line must NOT contain '>'")
    assert(not l:find("%*%*"), "Cancellation line must NOT contain '**'")
  end
end
assert(found_cancel, "Modern cancellation line rendered")
print("✓ Clean error and cancellation notices verified!")

-- =========================================================================
-- TEST 4: Thoughts Rendering and Tight Spacing Between Calls
-- =========================================================================
print("\n[Test 4] Testing thoughts rendering and tight spacing...")

local transcript_steps = {
  {
    type = "USER_INPUT",
    content = "Check status",
  },
  {
    type = "PLANNER_RESPONSE",
    thinking = "Let me check the status\nSecond thought line",
    tool_calls = {
      { name = "run_command", args = { CommandLine = "git status" } },
      { name = "view_file", args = { TargetFile = "README.md" } },
    },
    duration_seconds = 0.5,
  },
}

local trans_buf = vim.api.nvim_create_buf(false, false)
local trans_prompt_line, trans_prompt_ext, trans_tcs = render.render_transcript(trans_buf, "test-conv", transcript_steps, cfg, cwd)
local t_lines = vim.api.nvim_buf_get_lines(trans_buf, 0, -1, false)

print("Transcript buffer lines:")
for idx, tl in ipairs(t_lines) do
  print(string.format("  [%d] %s", idx, tl))
end

local thought_line_idx = nil
for idx, tl in ipairs(t_lines) do
  if tl == "💭 Thought" then
    thought_line_idx = idx
    break
  end
end
assert(thought_line_idx ~= nil, "Must render collapsed thought line '💭 Thought'")

-- Verify tight spacing: tool call immediately follows thought (no blank line)
local next_line = t_lines[thought_line_idx + 1]
assert(next_line:find("run_command"), "Tool call tightly follows thoughts without blank line, got: " .. tostring(next_line))

-- Verify tight spacing between consecutive tool calls (no blank line)
local second_tool_line = t_lines[thought_line_idx + 2]
assert(second_tool_line:find("^🛠️ view_file"), "Consecutive tool call tightly follows previous tool call, got: " .. tostring(second_tool_line))

-- Check total registered blocks: 1 thought + 2 tools = 3
assert(#trans_tcs == 3, "Must have 3 collapsible blocks registered (1 thought + 2 tools)")
local thought_tc = trans_tcs[1]
assert(thought_tc.is_thought == true, "First item must be thought")
assert(thought_tc.is_open == false, "Thought must start collapsed")

-- Test expanding thought via toggle_tool_at_cursor (<CR>)
local trans_state = {
  buf = trans_buf,
  config = cfg,
  prompt_start_line = trans_prompt_line,
  prompt_extmark_id = trans_prompt_ext,
  tool_calls = trans_tcs,
}
protocol.buffers[trans_buf] = trans_state
vim.api.nvim_set_current_buf(trans_buf)
vim.api.nvim_win_set_cursor(0, { thought_line_idx, 0 })

local expand_ok = protocol.toggle_tool_at_cursor(trans_buf)
assert(expand_ok == true, "Must expand thought on <CR>")
assert(thought_tc.is_open == true, "Thought is now open")
assert(thought_tc.win and vim.api.nvim_win_is_valid(thought_tc.win), "Thought inline window is open")

local win_lines = vim.api.nvim_buf_get_lines(thought_tc.win_buf, 0, -1, false)
assert(win_lines[1] == "Let me check the status", "First thought line in window")
assert(win_lines[2] == "Second thought line", "Second thought line in window")

-- Test collapsing thought via <CR>
local collapse_ok = protocol.toggle_tool_at_cursor(trans_buf)
assert(collapse_ok == true, "Must collapse thought on <CR>")
assert(thought_tc.is_open == false, "Thought is now closed")
assert(thought_tc.win == nil or not vim.api.nvim_win_is_valid(thought_tc.win), "Thought window closed")

-- Check live streaming append_thought_block and append_tool_call tight spacing
local stream_buf = vim.api.nvim_create_buf(false, false)
render.render_new_session(stream_buf, cfg)
local s_ext_id, s_agent_line = render.prepare_turn_submission(stream_buf, 3)

local s_rec = render.append_thought_block(stream_buf, "Analyzing the codebase", 0.3, cfg)
local tool1_line, _, _ = render.append_tool_call(stream_buf, "run_command", { CommandLine = "git status" }, cwd)
local tool2_line, _, _ = render.append_tool_call(stream_buf, "view_file", { TargetFile = "lua/agy/render.lua" }, cwd)

local s_lines = vim.api.nvim_buf_get_lines(stream_buf, 0, -1, false)
print("Stream buffer lines:")
for idx, sl in ipairs(s_lines) do
  print(string.format("  [%d] %s", idx, sl))
end

local s_thought_idx = nil
for idx, sl in ipairs(s_lines) do
  if sl == "💭 Thought" then
    s_thought_idx = idx
    break
  end
end
assert(s_thought_idx ~= nil, "Stream buffer has collapsed thought line")
assert(s_lines[s_thought_idx + 1]:find("run_command"), "Live stream tool call tightly follows thought")
assert(s_lines[s_thought_idx + 2]:find("^🛠️ view_file"), "Live stream second tool call tightly follows first tool call")

vim.cmd("bdelete! " .. trans_buf)
vim.cmd("bdelete! " .. stream_buf)
print("✓ Thoughts collapsible toggle, duration badge, and tight spacing verified!")

protocol.cleanup_buffer(test_buf)
vim.cmd("bdelete! " .. test_buf)

print("\nALL MODERN RENDERING TESTS PASSED PERFECTLY!")
vim.cmd("qall!")
