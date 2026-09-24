local utils = require("agy.utils")
local render = require("agy.render")
local protocol = require("agy.protocol")
local config_mod = require("agy.config")

print("=== Testing Compact Tool Calls & Dividers in Resumed Transcripts ===")

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
    show_thoughts = true,
    collapse_work = false,
  }
})
protocol.setup()

local cwd = vim.fs.normalize(vim.fn.getcwd())

-- =========================================================================
-- TEST 1: Multiple PLANNER_RESPONSE steps in a single turn
-- =========================================================================
print("\n[Test 1] Testing single turn with multiple PLANNER_RESPONSE steps...")

local steps_turn1 = {
  {
    type = "USER_INPUT",
    content = "Please fix the issue and run the tests",
  },
  {
    type = "PLANNER_RESPONSE",
    thinking = "Let me investigate the file first.",
    tool_calls = {
      { name = "view_file", args = { TargetFile = cwd .. "/lua/agy/render.lua" } },
    },
    duration_seconds = 0.2,
  },
  {
    type = "GENERIC",
    content = "Line 1: ...",
  },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "replace_file_content", args = { TargetFile = cwd .. "/lua/agy/render.lua" } },
    },
    duration_seconds = 0.3,
  },
  {
    type = "GENERIC",
    content = "Replaced 1 chunk.",
  },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "run_command", args = { CommandLine = "nu test.nu -t" } },
    },
    duration_seconds = 0.5,
  },
  {
    type = "GENERIC",
    content = "All tests passed!",
  },
  {
    type = "PLANNER_RESPONSE",
    content = "I have fixed the issue and verified all tests pass.",
    duration_seconds = 0.1,
  },
}

local buf1 = vim.api.nvim_create_buf(false, false)
local prompt_line1, prompt_ext1, tcs1 = render.render_transcript(buf1, "conv-turn1", steps_turn1, cfg, cwd)
local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)

print("Rendered buffer lines for Test 1:")
for idx, l in ipairs(lines1) do
  print(string.format("  [%d] %s", idx, l))
end

-- 1. Find line indices for Thought, view_file, replace_file_content, run_command
local thought_line = nil
local view_line = nil
local replace_line = nil
local run_line = nil
local content_line = nil

for idx, l in ipairs(lines1) do
  if l:find("Thought") then
    thought_line = idx
  elseif l:find("view_file") then
    view_line = idx
  elseif l:find("replace_file_content") then
    replace_line = idx
  elseif l:find("run_command") then
    run_line = idx
  elseif l:find("^I have fixed the issue") then
    content_line = idx
  end
end

assert(thought_line ~= nil, "Thought line must exist")
assert(view_line ~= nil, "view_file line must exist")
assert(replace_line ~= nil, "replace_file_content line must exist")
assert(run_line ~= nil, "run_command line must exist")
assert(content_line ~= nil, "content line must exist")

-- 2. Verify all tool calls and thoughts are compacted on consecutive lines
assert(view_line == thought_line + 1, string.format("view_file (%d) must immediately follow thought (%d)", view_line, thought_line))
assert(replace_line == view_line + 1, string.format("replace_file_content (%d) must immediately follow view_file (%d)", replace_line, view_line))
assert(run_line == replace_line + 1, string.format("run_command (%d) must immediately follow replace_file_content (%d)", run_line, replace_line))
print("✓ Consecutive tool calls and thoughts are compacted on adjacent lines without blank lines")

-- 3. Verify divider extmarks in NS_UI
local ui_marks1 = vim.api.nvim_buf_get_extmarks(buf1, render.NS_UI, 0, -1, { details = true })
local agent_dividers = {}
local user_dividers = {}
local prompt_borders = {}

for _, em in ipairs(ui_marks1) do
  local details = em[4]
  if details and details.virt_lines then
    for _, vl in ipairs(details.virt_lines) do
      local text = (vl[1] and vl[1][1]) or ""
      if text:find("🤖 Antigravity") then
        table.insert(agent_dividers, { row = em[2], text = text, mark = em })
      elseif text:find("👤 User") or text:find("👤 You") then
        table.insert(user_dividers, { row = em[2], text = text, mark = em })
      elseif details.sign_text == "❯ " then
        table.insert(prompt_borders, { row = em[2], text = text, mark = em })
      end
    end
  end
end

print(string.format("Found %d agent divider(s), %d user divider(s), %d active prompt border(s)", #agent_dividers, #user_dividers, #prompt_borders))
for _, d in ipairs(agent_dividers) do
  print(string.format("  Agent divider at row %d: %s", d.row, d.text))
end

-- MUST have EXACTLY 1 agent divider for this turn!
assert(#agent_dividers == 1, string.format("Expected EXACTLY 1 agent divider, got %d", #agent_dividers))
-- The single agent divider must be placed above the thought line (row = thought_line - 1)
assert(agent_dividers[1].row == thought_line - 1, string.format("Agent divider row (%d) must be right above thought line (%d)", agent_dividers[1].row, thought_line - 1))

-- Must have 1 historical user divider + 1 active prompt border
assert(#user_dividers == 1, string.format("Expected 1 historical user divider, got %d", #user_dividers))
assert(#prompt_borders == 1, string.format("Expected 1 active prompt border, got %d", #prompt_borders))

-- Verify duration badge accumulated across steps (0.2 + 0.3 + 0.5 + 0.1 = 1.1s)
local agent_badge = agent_dividers[1].mark[4].virt_lines[1][2] and agent_dividers[1].mark[4].virt_lines[1][2][1] or ""
print("Agent badge on divider: " .. tostring(agent_badge))
assert(agent_badge:find("1.1s"), "Agent badge should reflect accumulated duration ~1.1s, got: " .. tostring(agent_badge))

print("✓ Single turn divider compaction verified!")

-- =========================================================================
-- TEST 2: Multi-turn conversation with tool calls in each turn
-- =========================================================================
print("\n[Test 2] Testing multi-turn conversation with multiple tool calls per turn...")

local steps_multi_turn = {
  -- Turn 1
  {
    type = "USER_INPUT",
    content = "Turn 1 request",
  },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "view_file", args = { TargetFile = "file1.txt" } },
    },
  },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "run_command", args = { CommandLine = "git status" } },
    },
  },
  {
    type = "PLANNER_RESPONSE",
    content = "Turn 1 finished.",
  },
  -- Turn 2
  {
    type = "USER_INPUT",
    content = "Turn 2 request",
  },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "replace_file_content", args = { TargetFile = "file2.txt" } },
    },
  },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "view_file", args = { TargetFile = "file2.txt" } },
    },
  },
  {
    type = "PLANNER_RESPONSE",
    content = "Turn 2 finished.",
  },
}

local buf2 = vim.api.nvim_create_buf(false, false)
render.render_transcript(buf2, "conv-multi", steps_multi_turn, cfg, cwd)

local ui_marks2 = vim.api.nvim_buf_get_extmarks(buf2, render.NS_UI, 0, -1, { details = true })
local multi_agent_dividers = {}
local multi_user_dividers = {}
local multi_prompt_borders = {}

for _, em in ipairs(ui_marks2) do
  local details = em[4]
  if details and details.virt_lines then
    for _, vl in ipairs(details.virt_lines) do
      local text = (vl[1] and vl[1][1]) or ""
      if text:find("🤖 Antigravity") then
        table.insert(multi_agent_dividers, { row = em[2], text = text })
      elseif text:find("👤 You") or text:find("👤 User") then
        table.insert(multi_user_dividers, { row = em[2], text = text })
      elseif details.sign_text == "❯ " then
        table.insert(multi_prompt_borders, { row = em[2], text = text })
      end
    end
  end
end

print(string.format("Multi-turn: %d agent dividers, %d historical user dividers, %d active prompt border", #multi_agent_dividers, #multi_user_dividers, #multi_prompt_borders))
-- MUST have EXACTLY 2 agent dividers (1 for Turn 1, 1 for Turn 2)
assert(#multi_agent_dividers == 2, string.format("Expected EXACTLY 2 agent dividers across 2 turns, got %d", #multi_agent_dividers))
-- MUST have 2 historical user dividers + 1 active prompt border
assert(#multi_user_dividers == 2, string.format("Expected 2 historical user dividers, got %d", #multi_user_dividers))
assert(#multi_prompt_borders == 1, string.format("Expected 1 active prompt border, got %d", #multi_prompt_borders))

print("✓ Multi-turn divider compaction verified!")

-- =========================================================================
-- TEST 3: Standalone TOOL_CALL steps (without PLANNER_RESPONSE wrapper)
-- =========================================================================
print("\n[Test 3] Testing standalone TOOL_CALL steps...")

local steps_standalone = {
  {
    type = "USER_INPUT",
    content = "Run tools directly",
  },
  {
    type = "TOOL_CALL",
    tool_name = "view_file",
    args = { TargetFile = "standalone1.txt" },
  },
  {
    type = "TOOL_CALL",
    tool_name = "run_command",
    args = { CommandLine = "echo test" },
  },
  {
    type = "PLANNER_RESPONSE",
    content = "All tools executed.",
  },
}

local buf3 = vim.api.nvim_create_buf(false, false)
render.render_transcript(buf3, "conv-standalone", steps_standalone, cfg, cwd)

local ui_marks3 = vim.api.nvim_buf_get_extmarks(buf3, render.NS_UI, 0, -1, { details = true })
local standalone_agent_dividers = {}

for _, em in ipairs(ui_marks3) do
  local details = em[4]
  if details and details.virt_lines then
    for _, vl in ipairs(details.virt_lines) do
      local text = (vl[1] and vl[1][1]) or ""
      if text:find("🤖 Antigravity") then
        table.insert(standalone_agent_dividers, { row = em[2], text = text })
      end
    end
  end
end

assert(#standalone_agent_dividers == 1, string.format("Expected EXACTLY 1 agent divider for standalone TOOL_CALL turn, got %d", #standalone_agent_dividers))
print("✓ Standalone TOOL_CALL divider compaction verified!")

pcall(vim.api.nvim_buf_delete, buf1, { force = true })
pcall(vim.api.nvim_buf_delete, buf2, { force = true })
pcall(vim.api.nvim_buf_delete, buf3, { force = true })

print("\nALL COMPACT TOOLS & TRANSCRIPT TESTS PASSED SUCCESSFULLY!")
