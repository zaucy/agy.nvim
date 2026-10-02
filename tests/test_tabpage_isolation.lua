local question_mod = require("agy.question")
local protocol = require("agy.protocol")
local panel_mod = require("agy.panel")
local render_mod = require("agy.render")

print("=== Running Antigravity Tabpage Isolation Tests ===")

require("agy").setup()

-- Helper to clean up buffers and tabpages
local function cleanup()
  question_mod.close()
  pcall(panel_mod.close)
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd("tabclose!")
  end
end

local multi_questions = {
  {
    question = "Question 1: Pick option",
    options = { "Option 1A", "Option 1B" },
    is_multi_select = false,
  },
  {
    question = "Question 2: Pick second option",
    options = { "Option 2A", "Option 2B" },
    is_multi_select = false,
  },
  {
    question = "Question 3: Pick third option",
    options = { "Option 3A", "Option 3B" },
    is_multi_select = false,
  },
}

-- =========================================================================
-- TEST 1: question.show() does not switch tabpages when called from another tab
-- =========================================================================
print("\n[Test 1] Testing question.show() does not switch tabpage when invoked on another tab...")
cleanup()

-- Tab 1: code buffer
local code_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(code_buf)
local tab1 = vim.api.nvim_get_current_tabpage()

-- Tab 2: conversation buffer
vim.cmd("tabnew")
local tab2 = vim.api.nvim_get_current_tabpage()
vim.cmd("edit agy://test-tabpage-1")
local agy_buf = vim.api.nvim_get_current_buf()
local agy_win = vim.api.nvim_get_current_win()
local agy_state = protocol.buffers[agy_buf]

assert(tab1 ~= tab2, "Must have two distinct tabpages")
assert(vim.api.nvim_get_current_tabpage() == tab2, "Active tab should be Tab 2")

-- Switch back to Tab 1
vim.api.nvim_set_current_tabpage(tab1)
assert(vim.api.nvim_get_current_tabpage() == tab1, "Active tab must be Tab 1")

-- Question arrives for agy_buf while user is on Tab 1
question_mod.show(agy_win, agy_buf, multi_questions, {
  config = agy_state.config,
})

-- Assert active tabpage is STILL Tab 1
assert(vim.api.nvim_get_current_tabpage() == tab1, "question.show() must NOT switch tabpage!")
print("✓ question.show() preserved active tabpage (stayed on Tab 1)")

-- =========================================================================
-- TEST 2: question.focus() and question.next_question() do not switch tabpages
-- =========================================================================
print("\n[Test 2] Testing question.focus() and question.next_question() while on Tab 1...")

question_mod.focus()
assert(vim.api.nvim_get_current_tabpage() == tab1, "question.focus() must NOT switch tabpage!")

question_mod.next_question()
assert(vim.api.nvim_get_current_tabpage() == tab1, "question.next_question() must NOT switch tabpage!")

question_mod.go_to_question(2)
assert(vim.api.nvim_get_current_tabpage() == tab1, "question.go_to_question() must NOT switch tabpage!")
print("✓ question navigation while on another tab preserved active tabpage")

-- =========================================================================
-- TEST 3: Navigating and answering on Tab 2 stays on Tab 2
-- =========================================================================
print("\n[Test 3] Testing answering questions and navigating on Tab 2 preserves Tab 2...")

vim.api.nvim_set_current_tabpage(tab2)
assert(vim.api.nvim_get_current_tabpage() == tab2, "Active tab must be Tab 2")
vim.api.nvim_set_current_win(agy_win)

-- User selects option 1 by jumping to 1 on Question 2
question_mod.jump_to(1)
-- Question 2 is single-select, so jump_to(1) confirms and advances to Question 3
assert(question_mod.state.current_q_idx == 3, "Should advance to Question 3")
assert(vim.api.nvim_get_current_tabpage() == tab2, "jump_to(1) must NOT switch tabpage!")

-- Pressing jump_to(2) on Question 3 advances to summary review page
question_mod.jump_to(2)
assert(question_mod.is_summary_page(), "Should advance to summary review page")
assert(vim.api.nvim_get_current_tabpage() == tab2, "jump_to(2) must NOT switch tabpage!")

-- Navigating between questions with prev_question / next_question
question_mod.prev_question()
assert(question_mod.state.current_q_idx == 3, "Should be on Question 3")
assert(vim.api.nvim_get_current_tabpage() == tab2, "prev_question() must NOT switch tabpage!")

question_mod.next_question()
assert(question_mod.is_summary_page(), "Should be on summary page")
assert(vim.api.nvim_get_current_tabpage() == tab2, "next_question() must NOT switch tabpage!")
print("✓ Answering questions (1, 2) and navigating preserved Tab 2")

-- =========================================================================
-- TEST 4: Accepting via accept() / <CR> does not switch tabpages
-- =========================================================================
print("\n[Test 4] Testing accept() on options and submit...")

question_mod.go_to_question(1)
assert(vim.api.nvim_get_current_tabpage() == tab2, "go_to_question(1) must NOT switch tabpage!")
question_mod.state.selected_idx = 1
question_mod.accept()
assert(question_mod.state.current_q_idx == 2, "accept() should advance to Question 2")
assert(vim.api.nvim_get_current_tabpage() == tab2, "accept() must NOT switch tabpage!")
print("✓ accept() (<CR>) preserved active tabpage")

-- =========================================================================
-- TEST 5: Inline write-in does not switch tabpages
-- =========================================================================
print("\n[Test 5] Testing start_inline_write_in does not switch tabpages...")

-- Switch to Tab 1
vim.api.nvim_set_current_tabpage(tab1)
assert(vim.api.nvim_get_current_tabpage() == tab1, "Must be on Tab 1")

-- Attempt start_inline_write_in while on Tab 1
question_mod.start_inline_write_in()
assert(vim.api.nvim_get_current_tabpage() == tab1, "start_inline_write_in must NOT switch tabpage!")

-- Switch to Tab 2 and start inline write-in
vim.api.nvim_set_current_tabpage(tab2)
assert(vim.api.nvim_get_current_tabpage() == tab2, "Must be on Tab 2")
question_mod.start_inline_write_in()
assert(vim.api.nvim_get_current_tabpage() == tab2, "start_inline_write_in on Tab 2 must stay on Tab 2!")
pcall(vim.cmd, "stopinsert")
question_mod.close()
print("✓ start_inline_write_in preserved active tabpage")

-- =========================================================================
-- TEST 6: panel close_and_focus_prompt does not switch tabpages
-- =========================================================================
print("\n[Test 6] Testing panel closing does not switch tabpages...")

vim.api.nvim_set_current_tabpage(tab1)
local panel_target_win = agy_win -- Window on Tab 2
local panel_res = panel_mod.open({
  title = "Test Panel",
  target_win = panel_target_win,
  render = function() return { "Line 1" }, {} end,
})
assert(panel_res ~= nil, "Panel must open")
-- Panel closes while user is on Tab 1
panel_mod.close()
assert(vim.api.nvim_get_current_tabpage() == tab1, "Panel close must NOT switch tabpage!")
print("✓ panel closing preserved active tabpage")

-- =========================================================================
-- TEST 7: toggle_tool_at_cursor does not switch tabpages
-- =========================================================================
print("\n[Test 7] Testing toggle_tool_at_cursor does not switch tabpages...")

vim.api.nvim_set_current_tabpage(tab1)
local float_buf = vim.api.nvim_create_buf(false, true)
local float_win = vim.api.nvim_open_win(float_buf, true, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 10,
  height = 5,
})
local dummy_state = {
  active_tool_call = {
    win = float_win,
    win_buf = float_buf,
    target_win = agy_win, -- on Tab 2
  },
  tool_calls = {},
}
protocol.buffers[code_buf] = dummy_state
protocol.toggle_tool_at_cursor(code_buf, agy_win)
assert(vim.api.nvim_get_current_tabpage() == tab1, "toggle_tool_at_cursor must NOT switch tabpage!")
protocol.buffers[code_buf] = nil
print("✓ toggle_tool_at_cursor preserved active tabpage")

cleanup()
print("\nALL TABPAGE ISOLATION TESTS PASSED PERFECTLY!")
