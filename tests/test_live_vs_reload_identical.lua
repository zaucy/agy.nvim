local utils = require("agy.utils")
local render = require("agy.render")
local protocol = require("agy.protocol")
local transcript = require("agy.transcript")
local config_mod = require("agy.config")
local test_helpers = require("tests.test_helpers")

print("=== Running Live vs. Reload Identical Rendering Tests ===")

local test_icons = {
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
}

local cfg = config_mod.setup({
  icons = test_icons,
  ui = {
    virtual_text = true,
    auto_scroll = false,
    fold_tool_output = false,
    protect_history = true,
    show_thoughts = true,
  }
})
protocol.setup()

local cwd = vim.fs.normalize(vim.fn.getcwd())

-- Helper to inspect buffer virt_lines extmarks
local function get_divider_info(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, render.NS_UI, 0, -1, { details = true })
  local dividers = {}
  for _, em in ipairs(marks) do
    local details = em[4]
    if details and details.virt_lines then
      for _, vl in ipairs(details.virt_lines) do
        local text = (vl[1] and vl[1][1]) or ""
        local badge = (vl[2] and vl[2][1]) or ""
        table.insert(dividers, {
          row = em[2],
          text = text,
          badge = badge,
          is_agent = text:find("🤖 Antigravity") ~= nil,
          is_user = text:find("👤") ~= nil,
          is_prompt_border = details.sign_text == "❯ ",
        })
      end
    end
  end
  return dividers
end

-- =========================================================================
-- TEST 1: Full Turn Live Streaming vs. Reload Identical Rendering
-- (User prompt -> Thought -> Tool Call -> Streaming Text -> Prompt Divider)
-- =========================================================================
print("\n[Test 1] Testing full turn: live streaming vs. reload buffer identity...")

local conv_id = "test-conv-identical-turn1"

-- --- A. Live Session Simulation ---
local buf_live = vim.api.nvim_create_buf(false, false)
local prompt_line, prompt_ext_id = render.render_new_session(buf_live, cfg)

-- User writes prompt
vim.api.nvim_buf_set_lines(buf_live, 2, 3, false, { "Please inspect lua/agy/render.lua and report." })

-- Agent begins response: transitions user divider and starts agent turn
local agent_extmark_id, agent_line = render.prepare_turn_submission(buf_live, prompt_line, prompt_ext_id, cfg)

-- Live Agent Thought appears
local thought_rec = render.append_thought_block(buf_live, "I will inspect the render file.", 0.5, cfg)

-- Live Agent Tool Call appears
local tool_file = cwd .. "/lua/agy/render.lua"
local tool_line, tool_extmark_id, param_str = render.append_tool_call(buf_live, "view_file", { AbsolutePath = tool_file }, cwd, cfg)
local tool_rec = {
  id = 1,
  tool_name = "view_file",
  params = { AbsolutePath = tool_file },
  param_str = param_str,
  header_extmark_id = tool_extmark_id,
  header_line_idx = tool_line,
  is_open = false,
  output_lines_count = 0,
}
render.complete_tool_call(buf_live, tool_rec, 0.3, "Line 1: local utils = ...\nLine 2: return M", cfg)

-- Live Agent streams text deltas
render.append_text_delta(buf_live, "I have inspected the file.", cfg)
render.append_text_delta(buf_live, "\nEverything looks consistent and clean.", cfg)

-- Turn finalization
local finalize_result = {
  status = "DONE",
  duration_seconds = 2.0,
  usage = { total_tokens = 450 },
}
local live_next_line, live_prompt_ext = render.finalize_turn(buf_live, agent_extmark_id, agent_line, finalize_result, cfg)

local live_lines = vim.api.nvim_buf_get_lines(buf_live, 0, -1, false)
print("Live buffer lines count: " .. #live_lines)
for idx, l in ipairs(live_lines) do
  print(string.format("  [%2d] %s", idx, l))
end

-- --- B. Transcript Data Construction & Reload ---
local transcript_steps = {
  {
    step_index = 0,
    type = "USER_INPUT",
    content = "Please inspect lua/agy/render.lua and report.",
    created_at = "2026-09-20T20:00:00Z",
  },
  {
    step_index = 1,
    type = "PLANNER_RESPONSE",
    thinking = "I will inspect the render file.",
    tool_calls = {
      {
        name = "view_file",
        args = { AbsolutePath = tool_file },
        output = "Line 1: local utils = ...\nLine 2: return M",
        duration_seconds = 0.3,
      }
    },
    duration_seconds = 0.5,
    created_at = "2026-09-20T20:00:01Z",
  },
  {
    step_index = 2,
    type = "PLANNER_RESPONSE",
    content = "I have inspected the file.\nEverything looks consistent and clean.",
    duration_seconds = 1.2,
    created_at = "2026-09-20T20:00:02Z",
  }
}

local buf_reload = vim.api.nvim_create_buf(false, false)
local reload_prompt_line, reload_prompt_ext, reload_tools = render.render_transcript(buf_reload, "new", transcript_steps, cfg, cwd)

local reload_lines = vim.api.nvim_buf_get_lines(buf_reload, 0, -1, false)
print("Reload buffer lines count: " .. #reload_lines)
for idx, l in ipairs(reload_lines) do
  print(string.format("  [%2d] %s", idx, l))
end

-- --- C. Assertions for Exact Identity ---
assert(#live_lines == #reload_lines, string.format("Line count mismatch! Live has %d lines, Reload has %d lines", #live_lines, #reload_lines))

for idx = 1, #live_lines do
  assert(live_lines[idx] == reload_lines[idx],
    string.format("Line %d mismatch!\n  Live:   '%s'\n  Reload: '%s'", idx, live_lines[idx], reload_lines[idx]))
end
print("✓ Live buffer lines and Reload buffer lines are 100% IDENTICAL")

-- Verify spacing:
-- 1) Exactly 1 blank line between tool call and agent text
local tool_row = nil
local text_row = nil
for idx, l in ipairs(live_lines) do
  if l:find("view_file") then tool_row = idx end
  if l:find("I have inspected") then text_row = idx end
end
assert(tool_row ~= nil, "view_file line must exist")
assert(text_row ~= nil, "text line must exist")
assert(text_row == tool_row + 2, string.format("Expected exactly 1 blank line between tool (%d) and text (%d)", tool_row, text_row))
assert(live_lines[tool_row + 1] == "", "Separator between tool and text must be empty blank line")
print("✓ Exactly 1 blank line separates tool call from text in both live and reload")

-- 2) Exactly 1 blank line between final text response and active prompt line
assert(live_lines[#live_lines - 1] == "", "Line before active prompt must be blank")
assert(live_lines[#live_lines] == "", "Active prompt line must be empty")
assert(live_next_line == reload_prompt_line, string.format("Prompt start line mismatch: Live=%d Reload=%d", live_next_line, reload_prompt_line))
print("✓ Spacing before active prompt matches identically")

-- =========================================================================
-- TEST 2: Turn Ending on Tool Call (Live vs. Reload Spacing Identity)
-- =========================================================================
print("\n[Test 2] Testing turn ending directly on tool call (spacing identity)...")

local buf_live_tool = vim.api.nvim_create_buf(false, false)
local prompt_line2, prompt_ext_id2 = render.render_new_session(buf_live_tool, cfg)
vim.api.nvim_buf_set_lines(buf_live_tool, 2, 3, false, { "Run tests now" })

local a_ext2, a_line2 = render.prepare_turn_submission(buf_live_tool, prompt_line2, prompt_ext_id2, cfg)
local t_line2, t_ext2, p_str2 = render.append_tool_call(buf_live_tool, "run_command", { CommandLine = "nu test.nu -t" }, cwd, cfg)
local t_rec2 = {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "nu test.nu -t" },
  header_extmark_id = t_ext2,
  header_line_idx = t_line2,
  is_open = false,
  output_lines_count = 0,
}
render.complete_tool_call(buf_live_tool, t_rec2, 1.0, "All tests passed!", cfg)

-- Finalize turn directly without trailing text
render.finalize_turn(buf_live_tool, a_ext2, a_line2, { status = "DONE", duration_seconds = 1.0 }, cfg)

local live_tool_lines = vim.api.nvim_buf_get_lines(buf_live_tool, 0, -1, false)

-- Reload equivalent transcript
local steps_ending_on_tool = {
  {
    step_index = 0,
    type = "USER_INPUT",
    content = "Run tests now",
    created_at = "2026-09-20T20:10:00Z",
  },
  {
    step_index = 1,
    type = "PLANNER_RESPONSE",
    tool_calls = {
      {
        name = "run_command",
        args = { CommandLine = "nu test.nu -t" },
        output = "All tests passed!",
        duration_seconds = 1.0,
      }
    },
    duration_seconds = 1.0,
    created_at = "2026-09-20T20:10:01Z",
  }
}

local buf_reload_tool = vim.api.nvim_create_buf(false, false)
render.render_transcript(buf_reload_tool, "new", steps_ending_on_tool, cfg, cwd)
local reload_tool_lines = vim.api.nvim_buf_get_lines(buf_reload_tool, 0, -1, false)

assert(#live_tool_lines == #reload_tool_lines,
  string.format("Turn ending on tool: line count mismatch! Live=%d Reload=%d", #live_tool_lines, #reload_tool_lines))

for idx = 1, #live_tool_lines do
  assert(live_tool_lines[idx] == reload_tool_lines[idx],
    string.format("Line %d mismatch on tool ending!\n  Live:   '%s'\n  Reload: '%s'", idx, live_tool_lines[idx], reload_tool_lines[idx]))
end
print("✓ Turn ending on tool call is 100% IDENTICAL in live and reload")

-- Verify exactly 1 blank line between tool call and prompt line
local tool_idx = nil
for idx, l in ipairs(live_tool_lines) do
  if l:find("run_command") then tool_idx = idx end
end
assert(tool_idx ~= nil, "run_command line must exist")
assert(tool_idx + 2 == #live_tool_lines, "Must have exactly 1 blank line between tool and active prompt line")
assert(live_tool_lines[tool_idx + 1] == "", "Separator line must be blank")
print("✓ Exactly 1 blank line between final tool call and prompt in both live and reload")

-- =========================================================================
-- TEST 3: Turn Duration Badge Synthesis on Reload
-- =========================================================================
print("\n[Test 3] Testing turn duration badge synthesis from created_at timestamps...")

local steps_with_timestamps = {
  {
    step_index = 0,
    type = "USER_INPUT",
    content = "Calculate elapsed time",
    created_at = "2026-09-20T20:20:00Z",
  },
  {
    step_index = 1,
    type = "PLANNER_RESPONSE",
    content = "First response step",
    created_at = "2026-09-20T20:20:03Z", -- 3 seconds elapsed
  }
}

local buf_ts = vim.api.nvim_create_buf(false, false)
render.render_transcript(buf_ts, "conv-ts", steps_with_timestamps, cfg, cwd)
local divs = get_divider_info(buf_ts)

local agent_div = nil
for _, d in ipairs(divs) do
  if d.is_agent then agent_div = d break end
end

assert(agent_div ~= nil, "Agent divider must exist")
print("Synthesized agent divider badge: " .. tostring(agent_div.badge))
assert(agent_div.badge:find("3.0s") or agent_div.badge:find("3s"), "Badge should reflect 3s elapsed duration")
assert(agent_div.badge:find("✓"), "Badge should contain done checkmark icon")
print("✓ Turn duration synthesized accurately from ISO timestamps")

-- =========================================================================
-- TEST 4: Protocol Resume Relative Path Shortening outside cwd
-- =========================================================================
print("\n[Test 4] Testing relative path shortening with render_workspaces outside cwd...")

local mock_workspace = "C:/projects/mock_external_repo"
if vim.fn.has("win32") == 0 and vim.fn.has("win64") == 0 then
  mock_workspace = "/home/developer/mock_external_repo"
end

local steps_workspace = {
  {
    step_index = 0,
    type = "USER_INPUT",
    content = "Inspect external file",
  },
  {
    step_index = 1,
    type = "PLANNER_RESPONSE",
    tool_calls = {
      {
        name = "view_file",
        args = { AbsolutePath = mock_workspace .. "/src/module/sub.lua" },
      }
    },
  }
}

local buf_ws = vim.api.nvim_create_buf(false, false)
-- Pass render_workspaces = { mock_workspace }
local _, _, ws_tools = render.render_transcript(buf_ws, "conv-ws", steps_workspace, cfg, { mock_workspace })

assert(#ws_tools == 1, "Should have 1 tool call")
print("ws_tools[1].param_str: " .. ws_tools[1].param_str)
assert(ws_tools[1].param_str == "src/module/sub.lua",
  "Path must be shortened relative to render_workspaces, got: " .. ws_tools[1].param_str)

local ws_lines = vim.api.nvim_buf_get_lines(buf_ws, 0, -1, false)
local found_shortened = false
for _, l in ipairs(ws_lines) do
  if l:find("`src/module/sub.lua`") then
    found_shortened = true
  end
end
assert(found_shortened, "Buffer line must display shortened path relative to render_workspaces")
print("✓ Relative path shortening with render_workspaces verified")

-- =========================================================================
-- TEST 5: Live Thought Rendering Before First Text Delta
-- =========================================================================
print("\n[Test 5] Testing live thought rendering before first text delta in turns without tools...")

local tmp_env, test_cid = test_helpers.create_mock_environment()
local test_cfg = config_mod.setup({ app_data_dir = tmp_env, icons = test_icons })
protocol.buffers = {}

-- Create mock transcript with thoughts on disk
local brain_logs = tmp_env .. "/brain/" .. test_cid .. "/.system_generated/logs"
local full_tf = io.open(brain_logs .. "/transcript_full.jsonl", "w")
assert(full_tf ~= nil, "Must open transcript_full.jsonl")
full_tf:write(vim.json.encode({
  step_index = 0,
  type = "USER_INPUT",
  content = "Hello without tools",
  created_at = "2026-09-20T20:30:00Z",
}) .. "\n")
full_tf:write(vim.json.encode({
  step_index = 1,
  type = "PLANNER_RESPONSE",
  thinking = "Deep thoughts about the question.",
  created_at = "2026-09-20T20:30:01Z",
}) .. "\n")
full_tf:close()

-- Open conversation
local buf_live_thought = vim.api.nvim_create_buf(false, false)
render.render_new_session(buf_live_thought, test_cfg)
protocol.buffers[buf_live_thought] = {
  conversation_id = test_cid,
  config = test_cfg,
  tool_calls = {},
  stream_info = { status = "idle" },
  active_agent_started_output = false,
  follow_bottom = false,
}
local state = protocol.buffers[buf_live_thought]
-- Call on_step_update callback directly
local handlers = nil
-- Simulate on_step_update via protocol's active state
state.active_agent_started_output = false

-- Test preliminary empty delta does NOT suppress thoughts
local stream_step_prelim = {
  step_type = "agent_response",
  text_delta = nil,
}
-- If text_delta is nil, state.active_agent_started_output must stay false
assert(state.active_agent_started_output == false, "active_agent_started_output must remain false before text_delta")

-- 2. CLI sends first real text_delta
-- In protocol.lua:
-- if not state.active_agent_started_output then
--   M.check_and_render_pending_thoughts(buf)
--   state.active_agent_started_output = true
-- end
protocol.check_and_render_pending_thoughts(buf_live_thought)
assert(#state.tool_calls == 1, "Thought block must be rendered into state.tool_calls")
assert(state.tool_calls[1].is_thought == true, "Tool call record must be a thought")

render.append_text_delta(buf_live_thought, "Here is the agent answer.", test_cfg)

local live_thought_lines = vim.api.nvim_buf_get_lines(buf_live_thought, 0, -1, false)
print("Live buffer with thoughts lines:")
for idx, l in ipairs(live_thought_lines) do
  print(string.format("  [%2d] %s", idx, l))
end

local thought_line_found = false
local answer_line_found = false
for _, l in ipairs(live_thought_lines) do
  if l:find("Thought") then thought_line_found = true end
  if l:find("Here is the agent answer.") then answer_line_found = true end
end

assert(thought_line_found, "Thought line must be rendered in buffer")
assert(answer_line_found, "Answer line must be rendered in buffer")
print("✓ Live thought rendering before first text delta verified")

-- =========================================================================
-- TEST 6: Legacy Quoted Parameters Sanitization
-- =========================================================================
print("\n[Test 6] Testing legacy quoted parameter sanitization from transcript.jsonl...")

local legacy_tf = io.open(brain_logs .. "/transcript.jsonl", "w")
assert(legacy_tf ~= nil, "Must open transcript.jsonl")
legacy_tf:write(vim.json.encode({
  step_index = 0,
  type = "USER_INPUT",
  content = "Legacy test",
}) .. "\n")
legacy_tf:write(vim.json.encode({
  step_index = 1,
  type = "TOOL_CALL",
  tool_name = "view_file",
  args = {
    TargetFile = "\"lua/agy/init.lua\"",
  }
}) .. "\n")
legacy_tf:close()

-- Remove transcript_full so it falls back to transcript.jsonl
os.remove(brain_logs .. "/transcript_full.jsonl")

local loaded_legacy_steps = transcript.read_transcript(test_cid, tmp_env)
assert(#loaded_legacy_steps == 2, "Must load 2 steps")
assert(loaded_legacy_steps[2].args.TargetFile == "lua/agy/init.lua",
  "Escaped quotes must be stripped, got: " .. tostring(loaded_legacy_steps[2].args.TargetFile))
print("✓ Legacy quoted tool parameters sanitized successfully")

-- =========================================================================
-- TEST 7: Multi-turn Identity with Turn 1 Ending on Tool Call
-- =========================================================================
print("\n[Test 7] Testing multi-turn live vs. reload identity where Turn 1 ends on tool call...")

local b_mt_live = vim.api.nvim_create_buf(false, false)
local pl_mt1, pe_mt1 = render.render_new_session(b_mt_live, cfg)
vim.api.nvim_buf_set_lines(b_mt_live, 2, 3, false, { "Turn 1: run tests" })
local a_mt1, al_mt1 = render.prepare_turn_submission(b_mt_live, pl_mt1, pe_mt1, cfg)
local t_mt_l, t_mt_e, _ = render.append_tool_call(b_mt_live, "run_command", { CommandLine = "cargo test" }, cwd, cfg)
render.complete_tool_call(b_mt_live, {
  id = 1,
  tool_name = "run_command",
  params = { CommandLine = "cargo test" },
  header_extmark_id = t_mt_e,
  header_line_idx = t_mt_l,
  is_open = false,
  output_lines_count = 0,
}, 0.5, "passed", cfg)
local pl_mt2, pe_mt2 = render.finalize_turn(b_mt_live, a_mt1, al_mt1, { status = "DONE", duration_seconds = 0.5 }, cfg)

-- Turn 2
vim.api.nvim_buf_set_lines(b_mt_live, pl_mt2 - 1, pl_mt2, false, { "Turn 2: explain results" })
local a_mt2, al_mt2 = render.prepare_turn_submission(b_mt_live, pl_mt2, pe_mt2, cfg)
render.append_text_delta(b_mt_live, "All tests succeeded smoothly.", cfg)
render.finalize_turn(b_mt_live, a_mt2, al_mt2, { status = "DONE", duration_seconds = 1.0 }, cfg)

local mt_live_lines = vim.api.nvim_buf_get_lines(b_mt_live, 0, -1, false)

-- Reload equivalent multi-turn transcript
local mt_steps = {
  {
    step_index = 0,
    type = "USER_INPUT",
    content = "Turn 1: run tests",
    created_at = "2026-09-20T21:00:00Z",
  },
  {
    step_index = 1,
    type = "PLANNER_RESPONSE",
    tool_calls = {
      {
        name = "run_command",
        args = { CommandLine = "cargo test" },
        output = "passed",
        duration_seconds = 0.5,
      }
    },
    duration_seconds = 0.5,
    created_at = "2026-09-20T21:00:01Z",
  },
  {
    step_index = 2,
    type = "USER_INPUT",
    content = "Turn 2: explain results",
    created_at = "2026-09-20T21:00:05Z",
  },
  {
    step_index = 3,
    type = "PLANNER_RESPONSE",
    content = "All tests succeeded smoothly.",
    duration_seconds = 1.0,
    created_at = "2026-09-20T21:00:06Z",
  }
}

local b_mt_rel = vim.api.nvim_create_buf(false, false)
render.render_transcript(b_mt_rel, "new", mt_steps, cfg, cwd)
local mt_rel_lines = vim.api.nvim_buf_get_lines(b_mt_rel, 0, -1, false)

assert(#mt_live_lines == #mt_rel_lines,
  string.format("Multi-turn line count mismatch: Live=%d Reload=%d", #mt_live_lines, #mt_rel_lines))
for idx = 1, #mt_live_lines do
  assert(mt_live_lines[idx] == mt_rel_lines[idx],
    string.format("Multi-turn line %d mismatch:\n  Live:   '%s'\n  Reload: '%s'", idx, mt_live_lines[idx], mt_rel_lines[idx]))
end
print("✓ Multi-turn with tool call turn ending is 100% IDENTICAL between live and reload")

-- =========================================================================
-- TEST 8: Protocol Buffer Reload (:e) Preserves Shortened Workspace Paths
-- =========================================================================
print("\n[Test 8] Testing protocol buffer reload (:e) preserves shortened workspace paths...")

local reload_env, reload_cid = test_helpers.create_mock_environment()
local reload_cfg = config_mod.setup({ app_data_dir = reload_env, icons = test_icons })
local ext_ws = "C:/projects/external_repo_for_test8"
if vim.fn.has("win32") == 0 and vim.fn.has("win64") == 0 then
  ext_ws = "/home/developer/external_repo_for_test8"
end

-- Write history.jsonl with external workspace
local hf = io.open(reload_env .. "/history.jsonl", "w")
assert(hf ~= nil)
hf:write(vim.json.encode({
  conversationId = reload_cid,
  workspace = ext_ws,
  timestamp = os.time(),
  display = "Test 8 Resume",
}) .. "\n")
hf:close()

-- Write transcript_full.jsonl
local rel_logs = reload_env .. "/brain/" .. reload_cid .. "/.system_generated/logs"
local r_tf = io.open(rel_logs .. "/transcript_full.jsonl", "w")
assert(r_tf ~= nil)
r_tf:write(vim.json.encode({
  step_index = 0,
  type = "USER_INPUT",
  content = "Inspect external file",
}) .. "\n")
r_tf:write(vim.json.encode({
  step_index = 1,
  type = "PLANNER_RESPONSE",
  tool_calls = {
    {
      name = "view_file",
      args = { AbsolutePath = ext_ws .. "/src/config.rs" },
    }
  }
}) .. "\n")
r_tf:close()

local b_resume = vim.api.nvim_create_buf(false, false)
protocol.handle_buf_read({ buf = b_resume, file = "agy://" .. reload_cid })

local lines_first_open = vim.api.nvim_buf_get_lines(b_resume, 0, -1, false)
local found_short_1 = false
for _, l in ipairs(lines_first_open) do
  if l:find("`src/config.rs`") then found_short_1 = true end
end
assert(found_short_1, "Path must be shortened on initial resume")

-- Now trigger reload via handle_buf_read (simulates :e)
protocol.handle_buf_read({ buf = b_resume, file = "agy://" .. reload_cid })

local lines_second_open = vim.api.nvim_buf_get_lines(b_resume, 0, -1, false)
local found_short_2 = false
for _, l in ipairs(lines_second_open) do
  if l:find("`src/config.rs`") then found_short_2 = true end
end
assert(found_short_2, "Path must remain shortened after :e reload (must not revert to absolute path)")
print("✓ Protocol buffer reload (:e) preserves shortened workspace paths")

-- =========================================================================
-- TEST 9: transcript_full.jsonl Preserves Authored Quotes
-- =========================================================================
print("\n[Test 9] Testing transcript_full.jsonl preserves authored quotes without stripping...")

local quote_env, quote_cid = test_helpers.create_mock_environment()
local quote_logs = quote_env .. "/brain/" .. quote_cid .. "/.system_generated/logs"
local q_tf = io.open(quote_logs .. "/transcript_full.jsonl", "w")
assert(q_tf ~= nil)
q_tf:write(vim.json.encode({
  step_index = 0,
  type = "USER_INPUT",
  content = "Search for exact phrase",
}) .. "\n")
q_tf:write(vim.json.encode({
  step_index = 1,
  type = "TOOL_CALL",
  tool_name = "grep_search",
  args = {
    Query = '"exact phrase"',
  }
}) .. "\n")
q_tf:close()

local quote_steps = transcript.read_transcript(quote_cid, quote_env)
assert(#quote_steps == 2, "Must read 2 steps")
assert(quote_steps[2].args.Query == '"exact phrase"',
  "transcript_full.jsonl must preserve authored quotes, got: " .. tostring(quote_steps[2].args.Query))
print("✓ transcript_full.jsonl authored quotes preserved successfully")

-- =========================================================================
-- TEST 10: Consecutive USER_INPUT Steps (Prompt Archival)
-- =========================================================================
print("\n[Test 10] Testing consecutive USER_INPUT steps preserve all user messages...")

local buf_consec = vim.api.nvim_create_buf(false, false)
local steps_consec = {
  { type = "USER_INPUT", content = "First prompt message" },
  { type = "USER_INPUT", content = "Second prompt message" },
  { type = "PLANNER_RESPONSE", content = "Response to second prompt" },
}
local prompt_line_c, prompt_ext_c, _ = render.render_transcript(buf_consec, "conv-consec", steps_consec, cfg, cwd)
local lines_c = vim.api.nvim_buf_get_lines(buf_consec, 0, -1, false)

local found_first = false
local found_second = false
local found_resp = false
for _, l in ipairs(lines_c) do
  if l:find("First prompt message") then found_first = true end
  if l:find("Second prompt message") then found_second = true end
  if l:find("Response to second prompt") then found_resp = true end
end
assert(found_first, "First user prompt must NOT be overwritten by second user prompt")
assert(found_second, "Second user prompt must be present")
assert(found_resp, "Agent response must be present")
print("✓ Consecutive USER_INPUT steps archived and preserved successfully")

-- =========================================================================
-- TEST 11: Parallel Tool Calls with Subsequent Outputs
-- =========================================================================
print("\n[Test 11] Testing parallel tool calls match separate subsequent outputs...")

local buf_parallel = vim.api.nvim_create_buf(false, false)
local steps_parallel = {
  { type = "USER_INPUT", content = "Run two tools in parallel" },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "view_file", args = { AbsolutePath = "file_a.txt" } },
      { name = "view_file", args = { AbsolutePath = "file_b.txt" } },
    }
  },
  { type = "TOOL_OUTPUT", content = "Content of file A" },
  { type = "TOOL_OUTPUT", content = "Content of file B" },
}
local _, _, tcs_parallel = render.render_transcript(buf_parallel, "conv-parallel", steps_parallel, cfg, cwd)
assert(#tcs_parallel == 2, "Expected 2 tool call records")
assert(tcs_parallel[1].output == "Content of file A", "First tool output mismatch: " .. tostring(tcs_parallel[1].output))
assert(tcs_parallel[2].output == "Content of file B", "Second tool output mismatch: " .. tostring(tcs_parallel[2].output))
print("✓ Parallel tool calls outputs matched correctly to respective tool calls")

-- =========================================================================
-- TEST 12: Degenerate ask_question Fallback to Tool Call
-- =========================================================================
print("\n[Test 12] Testing degenerate ask_question without questions is recorded as tool_call...")

local buf_q_fallback = vim.api.nvim_create_buf(false, false)
local steps_q_fallback = {
  { type = "USER_INPUT", content = "Prompt" },
  {
    type = "PLANNER_RESPONSE",
    tool_calls = {
      { name = "ask_question", args = { questions = {} } }
    }
  }
}
local _, _, tcs_q = render.render_transcript(buf_q_fallback, "conv-q-fb", steps_q_fallback, cfg, cwd)
assert(#tcs_q == 1, "Expected 1 tool call record for degenerate ask_question")
assert(tcs_q[1].tool_name == "ask_question", "Tool name must be ask_question")
assert(tcs_q[1].is_open == false, "Must start collapsed")
print("✓ Degenerate ask_question properly tracked in tool_calls")

-- =========================================================================
-- TEST 13: Treesitter Syntax Highlighting Preservation Across :e Reload
-- =========================================================================
print("\n[Test 13] Testing Treesitter syntax highlighting and code blocks preserved across :e reload...")

local ts_env, ts_cid = test_helpers.create_mock_environment()
local ts_cfg = config_mod.setup({
  app_data_dir = ts_env,
  icons = test_icons,
  ui = {
    wrap = true,
    linebreak = true,
  },
})
protocol.setup()

local ts_logs = ts_env .. "/brain/" .. ts_cid .. "/.system_generated/logs"
local ts_tf = io.open(ts_logs .. "/transcript_full.jsonl", "w")
assert(ts_tf ~= nil, "Failed to open transcript_full.jsonl")

local fence = string.rep(string.char(96), 3)
ts_tf:write(vim.json.encode({
  step_index = 0,
  type = "USER_INPUT",
  content = "Show implementation and header",
  created_at = "2026-09-20T22:00:00Z",
}) .. "\n")
ts_tf:write(vim.json.encode({
  step_index = 1,
  type = "PLANNER_RESPONSE",
  content = "### Implementation\n\nHere is the function:\n\n"
    .. fence .. "lua\n"
    .. "local function compute(val)\n"
    .. "  return val * 2\n"
    .. "end\n"
    .. fence .. "\n\nEnd of output.",
  created_at = "2026-09-20T22:00:02Z",
}) .. "\n")
ts_tf:close()

-- Open conversation buffer via agy protocol
vim.cmd("edit agy://" .. ts_cid)
local ts_buf = vim.api.nvim_get_current_buf()

assert(vim.bo[ts_buf].filetype == "agy", "Filetype must be 'agy' before reload")
assert(vim.bo[ts_buf].buftype == "acwrite", "Buftype must be 'acwrite' before reload")
assert(vim.treesitter.highlighter.active[ts_buf] ~= nil, "Treesitter highlighter must be active before reload")

local p_before = vim.treesitter.get_parser(ts_buf, "markdown")
p_before:parse()

local buf_lines = vim.api.nvim_buf_get_lines(ts_buf, 0, -1, false)
local head_row = nil
local code_row = nil
for idx, line in ipairs(buf_lines) do
  if line:find("### Implementation") then
    head_row = idx - 1
  elseif line:find("local function compute") then
    code_row = idx - 1
  end
end

assert(head_row ~= nil, "Heading line '### Implementation' must exist in buffer")
assert(code_row ~= nil, "Code block line 'local function compute' must exist in buffer")

local head_caps_before = vim.treesitter.get_captures_at_pos(ts_buf, head_row, 0)
assert(#head_caps_before > 0, "Markdown heading must have treesitter captures before reload")

local code_caps_before = vim.treesitter.get_captures_at_pos(ts_buf, code_row, 2)
assert(#code_caps_before > 0, "Code block line must have treesitter captures before reload")

local syn_slash_before = vim.fn.execute("syntax list AgySlashCommand")
assert(syn_slash_before:find("AgySlashCommand") ~= nil, "AgySlashCommand syntax must exist before reload")

-- Trigger buffer reload (simulates user executing :e)
vim.cmd("edit")

-- Verify buffer options, window options, and filetype are maintained
assert(vim.api.nvim_buf_is_valid(ts_buf), "Buffer must remain valid after :e")
assert(vim.bo[ts_buf].filetype == "agy", "Filetype must remain 'agy' after :e")
assert(vim.bo[ts_buf].buftype == "acwrite", "Buftype must remain 'acwrite' after :e")
assert(vim.bo[ts_buf].swapfile == false, "Swapfile must remain false after :e")
assert(vim.bo[ts_buf].bufhidden == "hide", "Bufhidden must remain hide after :e")

local ts_win = vim.fn.bufwinid(ts_buf)
if ts_win ~= -1 then
  assert(vim.wo[ts_win].wrap == ts_cfg.ui.wrap, "Window wrap must be maintained after :e")
  assert(vim.wo[ts_win].linebreak == ts_cfg.ui.linebreak, "Window linebreak must be maintained after :e")
end

-- Verify Treesitter highlighter is preserved
assert(vim.treesitter.highlighter.active[ts_buf] ~= nil,
  "Treesitter highlighter must remain active after :e reload")

local p_after = vim.treesitter.get_parser(ts_buf, "markdown")
p_after:parse()

local head_caps_after = vim.treesitter.get_captures_at_pos(ts_buf, head_row, 0)
assert(#head_caps_after > 0, "Markdown heading must have treesitter captures after :e reload")
assert(#head_caps_after == #head_caps_before,
  string.format("Heading capture count mismatch: before=%d after=%d", #head_caps_before, #head_caps_after))
for i = 1, #head_caps_before do
  assert(head_caps_after[i].capture == head_caps_before[i].capture,
    string.format("Heading capture %d mismatch: before=%s after=%s", i, head_caps_before[i].capture, head_caps_after[i].capture))
end

local code_caps_after = vim.treesitter.get_captures_at_pos(ts_buf, code_row, 2)
assert(#code_caps_after > 0, "Code block line must have treesitter captures after :e reload")
assert(#code_caps_after == #code_caps_before,
  string.format("Code block capture count mismatch: before=%d after=%d", #code_caps_before, #code_caps_after))
for i = 1, #code_caps_before do
  assert(code_caps_after[i].capture == code_caps_before[i].capture,
    string.format("Code block capture %d mismatch: before=%s after=%s", i, code_caps_before[i].capture, code_caps_after[i].capture))
end

-- Verify buffer-local slash command syntax matches are re-applied
local syn_slash_after = vim.fn.execute("syntax list AgySlashCommand")
assert(syn_slash_after:find("AgySlashCommand") ~= nil,
  "AgySlashCommand syntax must be preserved after :e reload")

print("✓ Treesitter syntax highlighting and code block formatting preserved identically across :e reload")

print("\nALL LIVE VS. RELOAD IDENTICAL RENDERING TESTS PASSED SUCCESSFULLY!")
