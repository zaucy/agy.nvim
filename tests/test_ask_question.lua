local protocol = require("agy.protocol")
local render = require("agy.render")
local utils = require("agy.utils")

print("=== Running Comprehensive Antigravity ask_question Tests ===")

require("agy").setup()

-- =========================================================================
-- TEST 1: Parameter parsing (JSON string vs table, single vs multi select)
-- =========================================================================
print("\n[Test 1] Testing parse_question_params...")

-- 1a. Table format
local params_table = {
  questions = {
    {
      question = "Where should self-hosted tools live?",
      options = {
        "Reorganize tools/ into tools/bootstrap/",
        "Create dedicated self_hosted/ directory",
        "Keep all tools in root tools/ as peers",
      },
      is_multi_select = false,
    }
  }
}
local parsed1 = render.parse_question_params(params_table)
assert(#parsed1 == 1, "Should parse 1 question")
assert(parsed1[1].question == "Where should self-hosted tools live?")
assert(#parsed1[1].options == 3)
assert(parsed1[1].is_multi_select == false)
print("✓ Table-based questions parsed successfully")

-- 1b. JSON string format (as received in raw tool call args)
local json_str = vim.json.encode({
  {
    question = "Select testing frameworks to enable:",
    options = { "Neovim headless lua", "Busted", "Plenary" },
    is_multi_select = true,
  }
})
local params_str = { questions = json_str }
local parsed2 = render.parse_question_params(params_str)
assert(#parsed2 == 1)
assert(parsed2[1].question == "Select testing frameworks to enable:")
assert(#parsed2[1].options == 3)
assert(parsed2[1].is_multi_select == true)
print("✓ JSON string-encoded questions parsed successfully")

-- =========================================================================
-- TEST 2: In-Buffer Question Block Rendering
-- =========================================================================
print("\n[Test 2] Testing render_question_block in buffer...")

vim.cmd("edit agy://new")
local buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()
local state = protocol.buffers[buf]

local q_state = render.render_question_block(buf, parsed1, state.config)
assert(q_state ~= nil, "q_state must be returned")
assert(q_state.first_option_line > 1, "first_option_line must be > 1")
assert(#q_state.questions == 1)
assert(q_state.questions[1].options_end_line >= q_state.questions[1].options_start_line + 2)

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local found_header = false
local found_opts = 0
local found_write_in = false

for _, l in ipairs(lines) do
  if l:find("❓ Question: Where should self%-hosted tools live%?") then
    found_header = true
    assert(not l:find(">"), "Question header should not contain '>'")
    assert(not l:find("%*%*"), "Question header should not contain '**'")
  elseif l:find("%- %[ %] ") then
    found_opts = found_opts + 1
    assert(not l:find(">"), "Option should not contain '>'")
  elseif l:find("Write%-in / Notes:") then
    found_write_in = true
    assert(not l:find(">"), "Write-in header should not contain '>'")
    assert(not l:find("%*%*"), "Write-in header should not contain '**'")
  end
end

assert(found_header, "Question header must be rendered in buffer")
assert(found_opts == 3, "All 3 options must be rendered with [ ] checkboxes")
assert(found_write_in, "Write-in / Notes header must be rendered in buffer")
print("✓ In-buffer question block rendered with question, [ ] options, and write-in section")

-- =========================================================================
-- TEST 3: Context-Sensitive <CR> Toggling (Single-Select Radio Behavior)
-- =========================================================================
print("\n[Test 3] Testing context-sensitive <CR> toggle for single-select question...")

local opt1_line = q_state.questions[1].options_start_line
local opt2_line = opt1_line + 1
local opt3_line = opt1_line + 2

-- Toggle option 1
vim.api.nvim_win_set_cursor(win, { opt1_line, 0 })
local handled1 = render.toggle_question_option(buf, opt1_line, q_state)
assert(handled1 == true, "toggle_question_option should return true for option line")

local l1 = vim.api.nvim_buf_get_lines(buf, opt1_line - 1, opt1_line, false)[1]
assert(l1:find("%- %[x%] Reorganize"), "Option 1 must be checked [x], found: " .. l1)
print("✓ Option 1 toggled to [x]")

-- Toggle option 2: Radio behavior must uncheck option 1 and check option 2
vim.api.nvim_win_set_cursor(win, { opt2_line, 0 })
local handled2 = render.toggle_question_option(buf, opt2_line, q_state)
assert(handled2 == true)

l1 = vim.api.nvim_buf_get_lines(buf, opt1_line - 1, opt1_line, false)[1]
local l2 = vim.api.nvim_buf_get_lines(buf, opt2_line - 1, opt2_line, false)[1]
assert(l1:find("%- %[ %] Reorganize"), "Option 1 must be unchecked [ ] after picking Option 2, found: " .. l1)
assert(l2:find("%- %[x%] Create dedicated"), "Option 2 must now be checked [x], found: " .. l2)
print("✓ Radio button behavior verified: picking Option 2 unchecks Option 1")

-- Toggling option 2 again unchecks it
local handled2_uncheck = render.toggle_question_option(buf, opt2_line, q_state)
assert(handled2_uncheck == true)
l2 = vim.api.nvim_buf_get_lines(buf, opt2_line - 1, opt2_line, false)[1]
assert(l2:find("%- %[ %] Create dedicated"), "Option 2 should be unchecked [ ] after second toggle")
print("✓ Toggling checked option unchecks it")

-- Non-option line returns false (allowing fallback to tool toggle or normal CR)
local non_opt_handled = render.toggle_question_option(buf, 1, q_state)
assert(non_opt_handled == false, "Lines outside option range must return false")
print("✓ Lines outside option range return false for fallback")

-- =========================================================================
-- TEST 4: Multi-Select Checkbox Toggling
-- =========================================================================
print("\n[Test 4] Testing multi-select checkbox toggling...")

local buf_multi = vim.api.nvim_create_buf(false, true)

local q_multi_state = render.render_question_block(buf_multi, parsed2, state.config)
local m_opt1 = q_multi_state.questions[1].options_start_line
local m_opt2 = m_opt1 + 1

render.toggle_question_option(buf_multi, m_opt1, q_multi_state)
render.toggle_question_option(buf_multi, m_opt2, q_multi_state)

local ml1 = vim.api.nvim_buf_get_lines(buf_multi, m_opt1 - 1, m_opt1, false)[1]
local ml2 = vim.api.nvim_buf_get_lines(buf_multi, m_opt2 - 1, m_opt2, false)[1]
assert(ml1:find("%- %[x%] Neovim headless lua"), "Multi-select option 1 must be checked [x]")
assert(ml2:find("%- %[x%] Busted"), "Multi-select option 2 must be checked [x]")
print("✓ Multi-select allows checking multiple options simultaneously")

vim.api.nvim_buf_delete(buf_multi, { force = true })

-- =========================================================================
-- TEST 5: Answer Extraction and Notes Formatting
-- =========================================================================
print("\n[Test 5] Testing answer extraction and notes formatting...")

-- 5a. Check empty state (nothing checked, no notes)
local ans_empty, has_empty = render.extract_question_answer(buf, q_state)
assert(has_empty == false, "extract_question_answer must return has_answer = false when nothing selected")
print("✓ Empty question block correctly returns has_answer = false")

-- 5b. Check option 1 and extract
render.toggle_question_option(buf, opt1_line, q_state)
local ans_opt1, has_opt1 = render.extract_question_answer(buf, q_state)
assert(has_opt1 == true, "Must have answer when option 1 is checked")
assert(ans_opt1:find("A: Reorganize tools/ into tools/bootstrap/"), "Payload must contain option text, found: " .. ans_opt1)
print("✓ Single selected option extracted cleanly: '" .. ans_opt1 .. "'")

-- 5c. Add write-in notes
local write_line = q_state.write_in_start_line
vim.api.nvim_buf_set_lines(buf, write_line - 1, write_line, false, { "Make sure to update docs and CI scripts as well." })

local ans_with_notes, has_with_notes = render.extract_question_answer(buf, q_state)
assert(has_with_notes == true)
assert(ans_with_notes:find("A: Reorganize tools/"), "Must contain selected option")
assert(ans_with_notes:find("Notes: Make sure to update docs and CI scripts as well."), "Must contain write-in notes")
print("✓ Answer with write-in notes formatted properly:\n" .. ans_with_notes)

-- 5d. Write-in only (no option checked)
render.toggle_question_option(buf, opt1_line, q_state) -- uncheck option 1
local ans_notes_only, has_notes_only = render.extract_question_answer(buf, q_state)
assert(has_notes_only == true, "Write-in alone is a valid answer")
assert(ans_notes_only == "Make sure to update docs and CI scripts as well.", "Write-in text returned directly when no options checked")
print("✓ Write-in alone is valid and extracted properly")

-- =========================================================================
-- TEST 6: Submission via :w with Active Question
-- =========================================================================
print("\n[Test 6] Testing :w submission handling with active question...")

state.active_question = q_state
-- Check option 2
render.toggle_question_option(buf, opt2_line, q_state)

-- Mock session send_prompt
local sent_prompt = nil
state.session = {
  turn_active = true,
  send_prompt = function(_, text)
    sent_prompt = text
    return true
  end,
  destroy = function() end,
  stop = function() end,
}

-- Run write
vim.cmd("write")

assert(sent_prompt ~= nil, "Session send_prompt must be called on write")
assert(sent_prompt:find("Create dedicated self_hosted/ directory"), "Prompt must contain chosen option, found: " .. tostring(sent_prompt))
assert(state.active_question == nil, "state.active_question must be cleared after submission")
assert(vim.bo[buf].modified == false, "Buffer modified must be false after submission")
print("✓ :w successfully extracts answer, calls send_prompt, and clears active question")

protocol.cleanup_buffer(buf)

-- =========================================================================
-- TEST 7: Historical Transcript Rendering of ask_question
-- =========================================================================
print("\n[Test 7] Testing transcript rendering of historical ask_question...")

vim.cmd("edit agy://new")
local buf_hist = vim.api.nvim_get_current_buf()

local mock_steps = {
  {
    type = "PLANNER_RESPONSE",
    content = "I need some clarification on how to proceed.",
    tool_calls = {
      {
        name = "ask_question",
        args = {
          questions = {
            {
              question = "Which database backend should we use?",
              options = { "SQLite", "PostgreSQL", "In-memory" },
              is_multi_select = false,
            }
          }
        }
      }
    }
  },
  {
    type = "GENERIC",
    content = "A: SQLite\n\nNotes: Lightweight for local dev",
  },
  {
    type = "PLANNER_RESPONSE",
    content = "Understood! Proceeding with SQLite implementation.",
    tool_calls = {},
  }
}

render.render_transcript(buf_hist, "mock-conv-123", mock_steps, state.config)
local hist_lines = vim.api.nvim_buf_get_lines(buf_hist, 0, -1, false)

local found_q_header = false
local found_sqlite_checked = false
local found_postgres_unchecked = false
local found_notes = false

for _, l in ipairs(hist_lines) do
  if l:find("❓ Question: Which database backend should we use%?") then
    found_q_header = true
    assert(not l:find(">"), "Question header should not contain '>'")
    assert(not l:find("%*%*"), "Question header should not contain '**'")
  elseif l:find("%- %[x%] SQLite") then
    found_sqlite_checked = true
    assert(not l:find(">"), "Option should not contain '>'")
  elseif l:find("%- %[ %] PostgreSQL") then
    found_postgres_unchecked = true
    assert(not l:find(">"), "Option should not contain '>'")
  elseif l:find("Notes: Lightweight for local dev") then
    found_notes = true
    assert(not l:find(">"), "Notes should not contain '>'")
    assert(not l:find("%*%*"), "Notes should not contain '**'")
  end
end

assert(found_q_header, "Transcript must render question header")
assert(found_sqlite_checked, "Answered option SQLite must be rendered checked [x]")
assert(found_postgres_unchecked, "Unanswered option PostgreSQL must be rendered unchecked [ ]")
assert(found_notes, "User notes must be rendered cleanly without > or **")
print("✓ Historical ask_question rendered cleanly with [x] answered option and notes")

protocol.cleanup_buffer(buf_hist)

-- =========================================================================
-- TEST 8: No CLIENT_INSTRUCTIONS Injection in Session
-- =========================================================================
print("\n[Test 8] Testing session sends prompt directly without CLIENT_INSTRUCTIONS...")

local session_mod = require("agy.session")
local written_to_proc = nil

local mock_session = setmetatable({
  is_active = true,
  is_initialized = true,
  turn_active = false,
  proc = {
    write = function(_, str)
      written_to_proc = str
    end
  }
}, { __index = session_mod })

mock_session:send_prompt("/plan create a rust CLI tool")
assert(written_to_proc ~= nil, "Session must write payload to proc")
local decoded_payload = vim.json.decode(written_to_proc)
assert(decoded_payload.event == "user")
assert(decoded_payload.message.content == "/plan create a rust CLI tool", "Payload must contain exact user prompt without injection")
assert(not decoded_payload.message.content:find("<CLIENT_INSTRUCTIONS>", 1, true), "Payload must not include CLIENT_INSTRUCTIONS")
print("✓ Session cleanly transmits user prompt without prompt injection")

-- =========================================================================
-- TEST 9: utils.clean_user_content Stripping of CLIENT_INSTRUCTIONS
-- =========================================================================
print("\n[Test 9] Testing utils.clean_user_content strips CLIENT_INSTRUCTIONS...")

local sample_raw = [[
<USER_REQUEST>
/plan implement user authentication

<CLIENT_INSTRUCTIONS>
1. Interactive Questions: Do NOT invoke the `ask_question` tool.
2. Planning & Artifacts: Set RequestFeedback: false.
</CLIENT_INSTRUCTIONS>
</USER_REQUEST>
<ADDITIONAL_METADATA>
The current local time is: 2026-09-19T18:00:00.
</ADDITIONAL_METADATA>
]]

local cleaned = utils.clean_user_content(sample_raw)
assert(cleaned == "/plan implement user authentication", "Cleaned user content must only contain prompt without CLIENT_INSTRUCTIONS, got: " .. cleaned)
print("✓ utils.clean_user_content cleanly strips CLIENT_INSTRUCTIONS from conversation history")

-- =========================================================================
-- TEST 10: Turn Cancellation & Question UI on ask_question
-- =========================================================================
print("\n[Test 10] Testing turn cancellation and interactive question on ask_question...")

vim.cmd("edit! agy://new")
local buf_cancel = vim.api.nvim_get_current_buf()
local pstate = protocol.buffers[buf_cancel]

local session_stopped = false
local session_next_prompt = nil

pstate.session.turn_active = true
pstate.session.stop = function()
  session_stopped = true
  pstate.session.turn_active = false
end
pstate.session.send_prompt = function(_, prompt)
  session_next_prompt = prompt
  return true
end

-- Simulate step_update arriving with ask_question
pstate.session.on_step_update(pstate.session, {
  step_type = "tool",
  tool_name = "ask_question",
  state = "ACTIVE",
  tool_info = {
    name = "ask_question",
    parameters = {
      questions = {
        {
          question = "Choose deployment strategy:",
          options = { "Blue/Green", "Canary", "Rolling" },
          is_multi_select = false,
        }
      }
    }
  }
})

assert(session_stopped == true, "Turn must be cancelled immediately when ask_question arrives")
assert(pstate.active_question ~= nil, "active_question state must be set")
assert(pstate.stream_info.status == "question", "Stream status must be set to 'question'")

-- Active question floating UI is visible
local q_ui = pstate.active_question.ui
assert(q_ui ~= nil, "question UI must be initialized")
assert(q_ui.is_visible() == true, "question floating window must be visible")

local float_buf = q_ui.state.buf
local float_lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
local found_float_q_title = false
for _, l in ipairs(float_lines) do
  if l:find("Choose deployment strategy:") then
    found_float_q_title = true
  end
end
assert(found_float_q_title == true, "Question title must be displayed in floating UI")

-- Buffer prompt area must NOT be polluted with question input text while floating UI is active
local buf_lines = vim.api.nvim_buf_get_lines(buf_cancel, 0, -1, false)
local found_cancelled_banner = false
for _, l in ipairs(buf_lines) do
  if l:find("Turn cancelled") then
    found_cancelled_banner = true
  end
end
assert(found_cancelled_banner == false, "Turn cancelled banner must NOT be rendered for ask_question")

-- Navigate options in floating UI
assert(q_ui.state.selected_idx == 1, "Default selection is item 1")
q_ui.select_next()
assert(q_ui.state.selected_idx == 2, "Selection moved to item 2 (Canary)")

-- Accept option 2
q_ui.accept()

assert(session_next_prompt ~= nil, "Answer must be sent to session as next turn")
assert(session_next_prompt:find("A: Canary"), "Payload must contain selected option Canary, got: " .. tostring(session_next_prompt))
assert(pstate.active_question == nil, "active_question must be cleared after submission")
assert(q_ui.is_visible() == false, "Floating window must be closed after submission")

-- Verify historical question is recorded in conversation history buffer
local post_lines = vim.api.nvim_buf_get_lines(buf_cancel, 0, -1, false)
local found_history_q = false
local found_canary_checked = false
for _, l in ipairs(post_lines) do
  if l:find("Choose deployment strategy:") then
    found_history_q = true
  end
  if l:find("%[x%] Canary") then
    found_canary_checked = true
  end
end
assert(found_history_q == true, "Historical question must be recorded in buffer after submission")
assert(found_canary_checked == true, "Chosen option Canary must be recorded with [x] in buffer")

protocol.cleanup_buffer(buf_cancel)
print("✓ ask_question cleanly cancels turn, displays floating selectable UI, and submits response as next turn")

-- =========================================================================
-- TEST 11: Multi-select Question in Floating UI
-- =========================================================================
print("\n[Test 11] Testing multi-select in question floating UI...")

vim.cmd("edit! agy://new")
local buf_multi = vim.api.nvim_get_current_buf()
local state_multi = protocol.buffers[buf_multi]
local multi_submitted_prompt = nil

state_multi.session.turn_active = true
state_multi.session.stop = function() state_multi.session.turn_active = false end
state_multi.session.send_prompt = function(_, prompt)
  multi_submitted_prompt = prompt
  return true
end

state_multi.session.on_step_update(state_multi.session, {
  step_type = "tool",
  tool_name = "ask_question",
  state = "ACTIVE",
  tool_info = {
    name = "ask_question",
    parameters = {
      questions = {
        {
          question = "Select target platforms:",
          options = { "Linux", "macOS", "Windows" },
          is_multi_select = true,
        }
      }
    }
  }
})

local multi_ui = state_multi.active_question.ui
assert(multi_ui.is_visible() == true)

-- Toggle item 1 (Linux)
assert(multi_ui.state.selected_idx == 1)
multi_ui.toggle()

-- Toggle item 2 (macOS)
multi_ui.select_next()
assert(multi_ui.state.selected_idx == 2)
multi_ui.toggle()

-- Confirm multi-select answers
multi_ui.confirm_current_question()

assert(multi_submitted_prompt ~= nil, "Multi-select answers must be submitted")
assert(multi_submitted_prompt:find("Linux"), "Payload must contain Linux")
assert(multi_submitted_prompt:find("macOS"), "Payload must contain macOS")
assert(not multi_submitted_prompt:find("Windows"), "Payload must not contain Windows")
assert(state_multi.active_question == nil)
assert(multi_ui.is_visible() == false)

protocol.cleanup_buffer(buf_multi)
print("✓ Multi-select question UI successfully toggles and submits multiple choices")

-- =========================================================================
-- TEST 12: Direct Number Jump in Floating UI
-- =========================================================================
print("\n[Test 12] Testing direct number jump in question floating UI...")

vim.cmd("edit! agy://new")
local buf_jump = vim.api.nvim_get_current_buf()
local state_jump = protocol.buffers[buf_jump]
local jump_prompt = nil

state_jump.session.turn_active = true
state_jump.session.stop = function() state_jump.session.turn_active = false end
state_jump.session.send_prompt = function(_, prompt)
  jump_prompt = prompt
  return true
end

state_jump.session.on_step_update(state_jump.session, {
  step_type = "tool",
  tool_name = "ask_question",
  state = "ACTIVE",
  tool_info = {
    name = "ask_question",
    parameters = {
      questions = {
        {
          question = "Pick an environment:",
          options = { "Development", "Staging", "Production" },
          is_multi_select = false,
        }
      }
    }
  }
})

local jump_ui = state_jump.active_question.ui
assert(jump_ui.is_visible() == true)

-- Press '3' to immediately select Production
jump_ui.jump_to(3)

assert(jump_prompt ~= nil, "Direct number jump must immediately select and submit in single-select mode")
assert(jump_prompt:find("Production"), "Payload must contain Production: " .. tostring(jump_prompt))
assert(state_jump.active_question == nil)

protocol.cleanup_buffer(buf_jump)
print("✓ Direct number jump (1-9) selects and submits single-select option immediately")

-- =========================================================================
-- TEST 13: Write-in Response in Floating UI
-- =========================================================================
print("\n[Test 13] Testing write-in response in question floating UI...")

vim.cmd("edit! agy://new")
local buf_write = vim.api.nvim_get_current_buf()
local state_write = protocol.buffers[buf_write]
local write_in_prompt = nil

state_write.session.turn_active = true
state_write.session.stop = function() state_write.session.turn_active = false end
state_write.session.send_prompt = function(_, prompt)
  write_in_prompt = prompt
  return true
end

state_write.session.on_step_update(state_write.session, {
  step_type = "tool",
  tool_name = "ask_question",
  state = "ACTIVE",
  tool_info = {
    name = "ask_question",
    parameters = {
      questions = {
        {
          question = "Any special instructions?",
          options = { "Default build", "Debug build" },
          is_multi_select = false,
        }
      }
    }
  }
})

local write_ui = state_write.active_question.ui
-- Prompt write-in with mocked vim.ui.input, verifying temporary hide to avoid obscuring input
local orig_input = vim.ui.input
local was_hidden_during_input = false
vim.ui.input = function(opts, on_confirm)
  was_hidden_during_input = write_ui.state.is_hidden
  on_confirm("Build with ASAN enabled")
end

write_ui.prompt_write_in()
vim.ui.input = orig_input

assert(was_hidden_during_input == true, "Question UI must hide during write-in to prevent covering vim.ui.input")
assert(write_in_prompt ~= nil)
assert(write_in_prompt:find("Build with ASAN enabled"), "Prompt must contain write-in notes")

protocol.cleanup_buffer(buf_write)
print("✓ Write-in custom response in floating UI properly formatted and submitted")

-- =========================================================================
-- TEST 14: Cancel Active Question with stop_turn
-- =========================================================================
print("\n[Test 14] Testing manual cancellation of active question with stop_turn...")

vim.cmd("edit! agy://new")
local buf_stop = vim.api.nvim_get_current_buf()
local stop_state = protocol.buffers[buf_stop]

stop_state.session = {
  turn_active = false,
  stop = function() end,
  send_prompt = function() return true end,
  destroy = function() end,
}

local dummy_q = { { question = "Proceed?", options = { "Yes", "No" }, is_multi_select = false } }
protocol.intercept_ask_question(buf_stop, stop_state, dummy_q)
assert(stop_state.active_question ~= nil)
assert(stop_state.active_question.ui.is_visible() == true)

protocol.stop_turn(buf_stop)

assert(stop_state.active_question == nil, "active_question must be cleared when user cancels with stop_turn")
assert(stop_state.stream_info.status == "ready", "Status must return to ready")

protocol.cleanup_buffer(buf_stop)
print("✓ stop_turn cleanly clears active_question and restores prompt divider")

-- =========================================================================
-- TEST 15: Question UI Overlay Geometry & Prompt Modifiable Lock
-- =========================================================================
print("\n[Test 15] Testing question UI overlay geometry and unmodifiable prompt lock...")

vim.cmd("edit! agy://new")
local buf_lock = vim.api.nvim_get_current_buf()
local win_lock = vim.api.nvim_get_current_win()
local state_lock = protocol.buffers[buf_lock]

state_lock.session = {
  turn_active = false,
  stop = function() end,
  send_prompt = function() return true end,
  destroy = function() end,
}

local q_sample = {
  {
    question = "Which cache strategy should we adopt?",
    options = { "LRU in-memory", "Redis distributed", "Disk-backed mmap" },
    is_multi_select = false,
  }
}

protocol.intercept_ask_question(buf_lock, state_lock, q_sample)
assert(state_lock.active_question ~= nil)
local ui_lock = state_lock.active_question.ui
assert(ui_lock.is_visible() == true)

-- Float window config: focusable must be true so the cursor is used directly for selecting
local win_cfg = vim.api.nvim_win_get_config(ui_lock.state.win)
assert(win_cfg.focusable == true, "Floating window must be focusable so cursor is used directly for selecting")
assert(win_cfg.relative == "win", "Floating window must be relative to target window")

-- Overlay sits directly over top of prompt area (starting at top border), not below prompt
local prompt_line_lock = state_lock.prompt_start_line or vim.api.nvim_buf_line_count(buf_lock)
local prompt_screenpos = vim.fn.screenpos(win_lock, prompt_line_lock, 1)
local win_pos_lock = vim.api.nvim_win_get_position(win_lock)
local prompt_win_row_lock = prompt_screenpos.row - 1 - win_pos_lock[1]
assert(win_cfg.row <= prompt_win_row_lock, string.format("Question UI row (%d) must sit directly over top of prompt area (prompt row: %d)", win_cfg.row, prompt_win_row_lock))

-- Cursor is positioned directly on first option line for selection
local cur_win = vim.api.nvim_get_current_win()
assert(cur_win == ui_lock.state.win, "Question window must be focused for direct cursor selection")
local cur_pos = vim.api.nvim_win_get_cursor(ui_lock.state.win)
assert(cur_pos[1] == 4, string.format("Cursor must be on option 1 line (expected 4, got %d)", cur_pos[1]))

-- Verify bottom border full width line exists under footer
local q_buf_lines = vim.api.nvim_buf_get_lines(ui_lock.state.buf, 0, -1, false)
local last_line = q_buf_lines[#q_buf_lines]
assert(#last_line >= 10 and last_line:find("^[─%-]+$"), "Bottom line under footer must be a full width divider line")

-- Target buffer modifiable must be false everywhere while question is active
protocol.update_modifiable(buf_lock)
assert(vim.bo[buf_lock].modifiable == false, "Target buffer modifiable must be false while active_question is active")

-- =========================================================================
-- TEST 16: History Navigation & Question UI Persistence
-- =========================================================================
print("\n[Test 16] Testing history navigation keeps question float visible...")

local prompt_line = state_lock.prompt_start_line or vim.api.nvim_buf_line_count(buf_lock)
assert(prompt_line > 1, "prompt_line must be > 1 so history lines exist above it")

-- Cursor at prompt line: question UI is visible
vim.api.nvim_win_set_cursor(win_lock, { prompt_line, 0 })
vim.cmd("doautocmd CursorMoved")
assert(ui_lock.is_visible() == true, "Question UI must be visible when cursor is at prompt line")

-- Move cursor up into history (e.g. line 1, well above prompt_start_line)
vim.api.nvim_win_set_cursor(win_lock, { 1, 0 })
vim.cmd("doautocmd CursorMoved")
assert(ui_lock.is_visible() == true, "Question UI must NOT disappear when cursor is scrolled into history")

-- Move cursor back down to prompt line: question UI remains visible
vim.api.nvim_win_set_cursor(win_lock, { prompt_line, 0 })
vim.cmd("doautocmd CursorMoved")
assert(ui_lock.is_visible() == true, "Question UI must remain visible when cursor returns to prompt line")

-- Navigate options and accept via <CR> at prompt
local submitted_answer = nil
state_lock.session.send_prompt = function(_, prompt)
  submitted_answer = prompt
  return true
end

-- Keymap <CR> at prompt should accept current option (option 1: LRU in-memory)
pcall(function()
  ui_lock.accept()
end)

assert(submitted_answer ~= nil, "Submitting via accept must send prompt to session")
assert(submitted_answer:find("LRU in-memory", 1, true) ~= nil, "Answer must contain option 1, got: " .. tostring(submitted_answer))
assert(state_lock.active_question == nil, "active_question must be nil after submission")
assert(ui_lock.is_visible() == false, "Question UI must be closed after submission")

protocol.cleanup_buffer(buf_lock)
print("✓ Question UI stays visible on history scroll, persists on prompt return, and accepts answer cleanly")

-- =========================================================================
-- TEST 17: Multi-Question Navigation (prev/next/go_to_question)
-- =========================================================================
print("\n[Test 17] Testing navigation between multiple questions...")

vim.cmd("edit! agy://new")
local buf_multi_q = vim.api.nvim_get_current_buf()
local state_multi_q = protocol.buffers[buf_multi_q]
local multi_q_submitted_prompt = nil

state_multi_q.session.turn_active = true
state_multi_q.session.stop = function() state_multi_q.session.turn_active = false end
state_multi_q.session.send_prompt = function(_, prompt)
  multi_q_submitted_prompt = prompt
  return true
end

state_multi_q.session.on_step_update(state_multi_q.session, {
  step_type = "tool",
  tool_name = "ask_question",
  state = "ACTIVE",
  tool_info = {
    name = "ask_question",
    parameters = {
      questions = {
        {
          question = "Choose primary database:",
          options = { "PostgreSQL", "SQLite", "MongoDB" },
          is_multi_select = false,
        },
        {
          question = "Select required addons:",
          options = { "Auth", "Logging", "Metrics" },
          is_multi_select = true,
        },
        {
          question = "Target deployment:",
          options = { "Kubernetes", "Bare metal", "Docker Compose" },
          is_multi_select = false,
        },
      }
    }
  }
})

local mq_ui = state_multi_q.active_question.ui
assert(mq_ui.is_visible() == true)
assert(#mq_ui.state.questions == 3, "Must have 3 questions loaded")
assert(mq_ui.state.current_q_idx == 1, "Starts on question 1")

-- Verify header shows (1/3) and footer mentions question navigation
local q_buf = mq_ui.state.buf
local lines_q1 = vim.api.nvim_buf_get_lines(q_buf, 0, -1, false)
local found_count_1 = false
local found_footer_q_nav = false
for _, l in ipairs(lines_q1) do
  if l:find("%(1/3%)") then found_count_1 = true end
  if l:find("tab/h/l Questions") then found_footer_q_nav = true end
end
assert(found_count_1 == true, "Header must show (1/3) for question 1")
assert(found_footer_q_nav == true, "Footer must display tab/h/l question navigation hint")

-- Navigate to Question 2 via next_question()
mq_ui.next_question()
assert(mq_ui.state.current_q_idx == 2, "Must advance to question 2")
local lines_q2 = vim.api.nvim_buf_get_lines(q_buf, 0, -1, false)
local found_next_q_button = false
for _, l in ipairs(lines_q2) do
  if l:find("Next Question") then found_next_q_button = true end
end
assert(found_next_q_button == true, "Multi-select question prior to last question must display Next Question button")

-- Starts on question 1: prev_question() must stay at question 1 (no wrap-around)
mq_ui.prev_question()
assert(mq_ui.state.current_q_idx == 1, "Prev from question 1 must stay at question 1 (no wrap)")

-- Navigate to Question 2 via next_question()
mq_ui.next_question()
assert(mq_ui.state.current_q_idx == 2, "Must advance to question 2")
local lines_q2 = vim.api.nvim_buf_get_lines(q_buf, 0, -1, false)
local found_next_q_button = false
for _, l in ipairs(lines_q2) do
  if l:find("Next Question") then found_next_q_button = true end
end
assert(found_next_q_button == true, "Multi-select question prior to last question must display Next Question button")

-- Navigate to Question 3 via next_question()
mq_ui.next_question()
assert(mq_ui.state.current_q_idx == 3, "Must advance to question 3")

-- Advancing past Question 3 lands on Page 4 (Summary Review Page)
mq_ui.next_question()
assert(mq_ui.state.current_q_idx == 4, "Next from question 3 must advance to summary page")
assert(mq_ui.is_summary_page() == true, "Page 4 must be summary page")

-- Clamped navigation at last page: next_question() on summary page stays at Page 4
mq_ui.next_question()
assert(mq_ui.state.current_q_idx == 4, "Next from summary page must stay on summary page (no wrap)")

-- Navigate backwards step by step
mq_ui.prev_question()
assert(mq_ui.state.current_q_idx == 3, "Prev from summary page must go to question 3")

mq_ui.prev_question()
assert(mq_ui.state.current_q_idx == 2, "Prev from question 3 must go to question 2")

-- Answer Question 2 (multi-select): toggle Auth (opt 1) and Metrics (opt 3)
mq_ui.jump_to(1)
mq_ui.toggle()
mq_ui.jump_to(3)
mq_ui.toggle()
assert(mq_ui.state.selected_answers[2][1] == true, "Option 1 (Auth) must be selected")
assert(mq_ui.state.selected_answers[2][3] == true, "Option 3 (Metrics) must be selected")

-- Navigate to Question 1 and answer with option 2 (SQLite)
mq_ui.go_to_question(1)
assert(mq_ui.state.current_q_idx == 1)
mq_ui.jump_to(2)
-- Since Question 1 is single-select, selecting an option advances to Question 2
assert(mq_ui.state.current_q_idx == 2, "Answering single-select question 1 must advance to question 2")
-- Question 2's previous selections are still intact
assert(mq_ui.state.selected_answers[2][1] == true, "Question 2 selections must be preserved")

-- Advance Question 2 via confirm_current_question() to go to Question 3
mq_ui.confirm_current_question()
assert(mq_ui.state.current_q_idx == 3, "Confirming question 2 advances to question 3")

-- Answer Question 3 with option 1 (Kubernetes)
mq_ui.jump_to(1)
-- Since Question 3 is single-select, selecting an option advances to summary page (Page 4)
assert(mq_ui.state.current_q_idx == 4, "Answering last question must advance to summary page")
assert(mq_ui.is_summary_page() == true, "Must be on summary review page")
assert(multi_q_submitted_prompt == nil, "Submission must wait for confirmation on summary page")

-- Verify summary buffer content displays all answers
local summary_lines = vim.api.nvim_buf_get_lines(mq_ui.state.buf, 0, -1, false)
local summary_text = table.concat(summary_lines, "\n")
assert(summary_text:find("Summary: Review Answers"), "Summary header must be present")
assert(summary_text:find("SQLite"), "Summary must list Q1 answer SQLite")
assert(summary_text:find("Auth, Metrics"), "Summary must list Q2 answers Auth, Metrics")
assert(summary_text:find("Kubernetes"), "Summary must list Q3 answer Kubernetes")
assert(summary_text:find("Submit All Answers"), "Summary must have Submit All Answers item")

-- Verify jump_to on summary page to edit a question
mq_ui.jump_to(2)
assert(mq_ui.state.current_q_idx == 2, "Direct jump 2 on summary page must edit question 2")

-- Return to summary page
mq_ui.go_to_question(4)
assert(mq_ui.is_summary_page() == true)

-- Accept on item 1 [ Submit All Answers ]
mq_ui.accept()

-- Now all 3 questions have been submitted!
assert(multi_q_submitted_prompt ~= nil, "Submitting from summary page must trigger prompt submission")
assert(multi_q_submitted_prompt:find("A1: SQLite"), "Must contain A1 answer SQLite: " .. tostring(multi_q_submitted_prompt))
assert(multi_q_submitted_prompt:find("A2:"), "Must contain A2 prefix: " .. tostring(multi_q_submitted_prompt))
assert(multi_q_submitted_prompt:find("Auth"), "Must contain A2 option Auth: " .. tostring(multi_q_submitted_prompt))
assert(multi_q_submitted_prompt:find("Metrics"), "Must contain A2 option Metrics: " .. tostring(multi_q_submitted_prompt))
assert(multi_q_submitted_prompt:find("A3: Kubernetes"), "Must contain A3 answer Kubernetes: " .. tostring(multi_q_submitted_prompt))

assert(state_multi_q.active_question == nil, "active_question must be cleared after all questions submitted")
assert(mq_ui.is_visible() == false, "Question UI must close after all questions submitted")

protocol.cleanup_buffer(buf_multi_q)
print("✓ Navigation and answering across multiple questions verified")

print("\nALL ASK_QUESTION & PLANNING SAFETY TESTS PASSED PERFECTLY!")
