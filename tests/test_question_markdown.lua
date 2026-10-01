local protocol = require("agy.protocol")
local render = require("agy.render")
local question_mod = require("agy.question")
local markdown_mod = require("agy.markdown")
local utils = require("agy.utils")

print("=== Running Antigravity Question Markdown Rendering Tests ===")

require("agy").setup()

-- =========================================================================
-- TEST 1: Interactive Question UI renders markdown in question title & options
-- =========================================================================
do
  print("\n[Test 1] Testing interactive question UI renders markdown in title and options...")

  vim.cmd("edit! agy://new")
  local buf = vim.api.nvim_get_current_buf()
  local pstate = protocol.buffers[buf]

  local session_prompt = nil
  pstate.session.turn_active = true
  pstate.session.stop = function() pstate.session.turn_active = false end
  pstate.session.send_prompt = function(_, prompt)
    session_prompt = prompt
    return true
  end

  local test_q = {
    {
      question = "Which subsystem in [config.lua](file:///C:/projects/agy/lua/agy/config.lua) needs **bold** and `code`?",
      options = {
        "(Recommended) The [protocol.lua](file:///C:/projects/agy/lua/agy/protocol.lua) engine",
        "The `render.lua` display module with **speed**",
      },
      is_multi_select = false,
    }
  }

  pstate.session.on_step_update(pstate.session, {
    step_type = "tool",
    tool_name = "ask_question",
    state = "ACTIVE",
    tool_info = {
      name = "ask_question",
      parameters = { questions = test_q }
    }
  })

  assert(pstate.active_question ~= nil, "active_question must be set")
  assert(question_mod.is_visible(), "Question UI must be visible")

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found_title = false
  local found_raw_link = false
  local found_clean_opt1 = false
  local found_clean_opt2 = false

  local title_row_1idx = nil
  local opt1_row_1idx = nil

  for idx, l in ipairs(lines) do
    if l:find("file:///C:/projects/agy/lua/agy/config%.lua") or l:find("%*%*bold%*%*") or l:find("`code`") then
      found_raw_link = true
    end
    if l:find("Which subsystem in config%.lua needs bold and code%?") then
      found_title = true
      title_row_1idx = idx
    end
    if l:find("%(Recommended%) The protocol%.lua engine") then
      found_clean_opt1 = true
      opt1_row_1idx = idx
    end
    if l:find("The render%.lua display module with speed") then
      found_clean_opt2 = true
    end
  end

  assert(found_title, "Question title must render clean text without markdown delimiters: " .. table.concat(lines, "\n"))
  assert(not found_raw_link, "Question buffer must NOT contain raw markdown syntax [config.lua](url)")
  assert(found_clean_opt1, "Option 1 must render clean text without markdown delimiters")
  assert(found_clean_opt2, "Option 2 must render clean text without markdown delimiters")

  -- Verify link registration in markdown_mod.links[buf]
  assert(title_row_1idx ~= nil, "Title row must be identified")
  assert(opt1_row_1idx ~= nil, "Option 1 row must be identified")

  local title_line = lines[title_row_1idx]
  local s_col, e_col = title_line:find("config%.lua")
  assert(s_col ~= nil, "config.lua substring must exist in title line")

  local link_at_title = markdown_mod.get_link_at(buf, title_row_1idx, s_col)
  assert(link_at_title ~= nil, "get_link_at must locate link in question title")
  assert(link_at_title.url == "file:///C:/projects/agy/lua/agy/config.lua", "Link url must match config.lua")

  local opt1_line = lines[opt1_row_1idx]
  local o_col, _ = opt1_line:find("protocol%.lua")
  assert(o_col ~= nil, "protocol.lua substring must exist in option line")

  local link_at_opt1 = markdown_mod.get_link_at(buf, opt1_row_1idx, o_col)
  assert(link_at_opt1 ~= nil, "get_link_at must locate link in option line")
  assert(link_at_opt1.url == "file:///C:/projects/agy/lua/agy/protocol.lua", "Link url must match protocol.lua")

  print("✓ Interactive question UI parsed markdown in title and options and registered clickable links")

  -- Test selecting option 1 and verifying canonical payload transmission
  question_mod.accept()
  assert(session_prompt ~= nil, "send_prompt must be called on accept")
  assert(session_prompt:find("The %[protocol%.lua%]%(file:///C:/projects/agy/lua/agy/protocol%.lua%) engine"),
    "Submitted prompt payload must retain canonical markdown option: " .. tostring(session_prompt))

  protocol.cleanup_buffer(buf)
end

-- =========================================================================
-- TEST 2: Historical question block renders markdown and registers links
-- =========================================================================
do
  print("\n[Test 2] Testing historical question block renders markdown and registers links...")

  vim.cmd("edit! agy://new")
  local buf_hist = vim.api.nvim_get_current_buf()

  local mock_steps = {
    {
      type = "PLANNER_RESPONSE",
      content = "Please choose an implementation:",
      tool_calls = {
        {
          name = "ask_question",
          args = {
            questions = {
              {
                question = "Check [documentation](https://github.com/zaucy/agy.nvim) or select `option`:",
                options = {
                  "Use [feature_a.lua](file:///workspace/feature_a.lua)",
                  "Use [feature_b.lua](file:///workspace/feature_b.lua)",
                },
                is_multi_select = false,
              }
            }
          }
        }
      }
    },
    {
      type = "GENERIC",
      content = "A: Use [feature_a.lua](file:///workspace/feature_a.lua)\n\nNotes: Checked [specs](https://example.com/specs)",
    },
  }

  local state = protocol.buffers[buf_hist]
  render.render_transcript(buf_hist, "mock-conv-md", mock_steps, state.config)
  local hist_lines = vim.api.nvim_buf_get_lines(buf_hist, 0, -1, false)

  local found_q = false
  local found_checked = false
  local found_unchecked = false
  local found_notes = false

  local q_line_idx = nil
  local opt_line_idx = nil
  local notes_line_idx = nil

  for idx, l in ipairs(hist_lines) do
    if l:find("Check documentation or select option:") then
      found_q = true
      q_line_idx = idx
      assert(not l:find("https://github%.com"), "Question header line must not contain raw link url")
    end
    if l:find("%- %[x%] Use feature_a%.lua") then
      found_checked = true
      opt_line_idx = idx
      assert(not l:find("file:///workspace"), "Option line must not contain raw link url")
    end
    if l:find("%- %[ %] Use feature_b%.lua") then
      found_unchecked = true
      assert(not l:find("file:///workspace"), "Unchecked option line must not contain raw link url")
    end
    if l:find("Notes: Checked specs") then
      found_notes = true
      notes_line_idx = idx
      assert(not l:find("https://example%.com"), "Notes line must not contain raw link url")
    end
  end

  assert(found_q, "Question header must render clean text")
  assert(found_checked, "Selected option must render clean text with [x]")
  assert(found_unchecked, "Unselected option must render clean text with [ ]")
  assert(found_notes, "Notes line must render clean text")

  -- Verify link lookup on historical lines
  assert(q_line_idx ~= nil)
  local q_col = hist_lines[q_line_idx]:find("documentation")
  local l_q = markdown_mod.get_link_at(buf_hist, q_line_idx, q_col)
  assert(l_q ~= nil, "Link must be found on question line")
  assert(l_q.url == "https://github.com/zaucy/agy.nvim")

  assert(opt_line_idx ~= nil)
  local opt_col = hist_lines[opt_line_idx]:find("feature_a%.lua")
  local l_opt = markdown_mod.get_link_at(buf_hist, opt_line_idx, opt_col)
  assert(l_opt ~= nil, "Link must be found on option line")
  assert(l_opt.url == "file:///workspace/feature_a.lua")

  assert(notes_line_idx ~= nil)
  local notes_col = hist_lines[notes_line_idx]:find("specs")
  local l_notes = markdown_mod.get_link_at(buf_hist, notes_line_idx, notes_col)
  assert(l_notes ~= nil, "Link must be found on notes line")
  assert(l_notes.url == "https://example.com/specs")

  print("✓ Historical question block cleanly rendered markdown and registered interactive links")
  protocol.cleanup_buffer(buf_hist)
end

-- =========================================================================
-- TEST 3: Multi-question Summary Page renders markdown cleanly
-- =========================================================================
do
  print("\n[Test 3] Testing multi-question summary page renders markdown cleanly...")

  vim.cmd("edit! agy://new")
  local buf_sum = vim.api.nvim_get_current_buf()
  local pstate = protocol.buffers[buf_sum]

  pstate.session.turn_active = true
  pstate.session.stop = function() pstate.session.turn_active = false end
  pstate.session.send_prompt = function() return true end

  local multi_q = {
    {
      question = "Target for [Backend](file:///backend):",
      options = { "Option [One](file:///one)", "Option `Two`" },
      is_multi_select = false,
    },
    {
      question = "Target for **Frontend**:",
      options = { "React", "Vue" },
      is_multi_select = false,
    }
  }

  pstate.session.on_step_update(pstate.session, {
    step_type = "tool",
    tool_name = "ask_question",
    state = "ACTIVE",
    tool_info = {
      name = "ask_question",
      parameters = { questions = multi_q }
    }
  })

  -- Select option 1 for Q1
  question_mod.state.selected_answers[1] = 1
  -- Select option 2 for Q2
  question_mod.state.selected_answers[2] = 2

  -- Navigate to summary page (Q3 in a 2-question questionnaire)
  question_mod.go_to_question(3)
  assert(question_mod.is_summary_page(), "Must be on summary review page")

  local sum_lines = vim.api.nvim_buf_get_lines(buf_sum, 0, -1, false)
  local found_q1_title = false
  local found_q2_title = false
  local found_q1_opt = false

  local sum_q1_row = nil

  for idx, l in ipairs(sum_lines) do
    if l:find("1%. Target for Backend:") then
      found_q1_title = true
      sum_q1_row = idx
      assert(not l:find("file:///backend"), "Summary line 1 must not contain raw link url")
    end
    if l:find("2%. Target for Frontend:") then
      found_q2_title = true
      assert(not l:find("%*%*Frontend%*%*"), "Summary line 2 must not contain **")
    end
    if l:find("Option One") then
      found_q1_opt = true
      assert(not l:find("file:///one"), "Summary answer must not contain raw link url")
    end
  end

  assert(found_q1_title, "Summary page must render clean question 1 title")
  assert(found_q2_title, "Summary page must render clean question 2 title")
  assert(found_q1_opt, "Summary page must render clean selected option 1")

  -- Check link registration on summary page
  assert(sum_q1_row ~= nil)
  local s_col = sum_lines[sum_q1_row]:find("Backend")
  local l_sum = markdown_mod.get_link_at(buf_sum, sum_q1_row, s_col)
  assert(l_sum ~= nil, "Link must be registered on summary page")
  assert(l_sum.url == "file:///backend")

  print("✓ Summary review page renders markdown cleanly and registers links")
  protocol.cleanup_buffer(buf_sum)
end

-- =========================================================================
-- TEST 4: In-buffer question block (render_question_block) with markdown
-- =========================================================================
do
  print("\n[Test 4] Testing render_question_block with markdown...")

  local buf_block = vim.api.nvim_create_buf(false, true)
  local cfg = require("agy.config").get()

  local q_spec = {
    {
      question = "Select target [SDK](https://sdk.example.com):",
      options = { "SDK [v1](https://sdk.example.com/v1)", "SDK `v2`" },
      is_multi_select = false,
    }
  }

  local q_block_state = render.render_question_block(buf_block, q_spec, cfg)
  assert(q_block_state ~= nil)

  local block_lines = vim.api.nvim_buf_get_lines(buf_block, 0, -1, false)
  local found_q_clean = false
  local found_opt1_clean = false
  local q_row = nil
  local opt1_row = nil

  for idx, l in ipairs(block_lines) do
    if l:find("Select target SDK:") then
      found_q_clean = true
      q_row = idx
      assert(not l:find("https://sdk%.example%.com"), "Header line must not contain raw URL")
    end
    if l:find("%- %[ %] SDK v1") then
      found_opt1_clean = true
      opt1_row = idx
      assert(not l:find("https://sdk%.example%.com/v1"), "Option line must not contain raw URL")
    end
  end

  assert(found_q_clean, "Question header must render clean text")
  assert(found_opt1_clean, "Option 1 must render clean text")

  -- Verify link lookup
  assert(q_row ~= nil)
  local col_sdk = block_lines[q_row]:find("SDK")
  local l_sdk = markdown_mod.get_link_at(buf_block, q_row, col_sdk)
  assert(l_sdk ~= nil, "SDK link must be found")
  assert(l_sdk.url == "https://sdk.example.com")

  assert(opt1_row ~= nil)
  local col_v1 = block_lines[opt1_row]:find("v1")
  local l_v1 = markdown_mod.get_link_at(buf_block, opt1_row, col_v1)
  assert(l_v1 ~= nil, "v1 link must be found")
  assert(l_v1.url == "https://sdk.example.com/v1")

  print("✓ render_question_block renders markdown and registers links properly")
end

print("\n=== ALL QUESTION MARKDOWN TESTS PASSED PERFECTLY! ===")
