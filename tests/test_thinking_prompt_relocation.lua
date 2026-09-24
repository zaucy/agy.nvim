-- Test suite for relocating thinking animation to prompt area
local helpers = require("tests.test_helpers")
local protocol = require("agy.protocol")
local render = require("agy.render")
local config = require("agy.config")

local function run_test(name, fn)
  print("\n[Test] " .. name .. "...")
  local ok, err = pcall(fn)
  if not ok then
    error(string.format("FAILED: %s\n%s", name, tostring(err)))
  end
  print("✓ " .. name .. " passed")
end

print("=== Running Thinking Prompt Relocation Tests ===")

local default_cfg = config.setup({
  ui = {
    animate_thinking = true,
    prompt_footer = true,
  },
})

-- ---------------------------------------------------------------------------
-- TEST 1: Agent divider and footer omit [Thinking...] upon submission
-- ---------------------------------------------------------------------------
run_test("Agent divider and footer omit [Thinking...] on turn submission", function()
  vim.cmd("edit agy://new")
  local buf = vim.api.nvim_get_current_buf()
  local state = protocol.buffers[buf]
  assert(state ~= nil, "State must exist for agy://new")

  vim.wait(500, function() return state.stream_info and state.stream_info.status == "ready" end)

  -- Submit prompt
  local p_line = state.prompt_start_line
  vim.api.nvim_buf_set_lines(buf, p_line - 1, -1, false, { "What is the status?" })

  protocol.with_modifiable(buf, function()
    local ext_id, agent_line = render.prepare_turn_submission(buf, state.prompt_start_line, state.prompt_extmark_id, state.config)
    state.agent_extmark_id = ext_id
    state.agent_line = agent_line
    state.prompt_extmark_id = nil
  end)
  state.session.turn_active = true
  state.stream_info.status = "thinking"
  protocol.update_footer(buf)

  -- Check Agent divider
  local agent_mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.agent_extmark_id, { details = true })
  assert(agent_mark ~= nil and agent_mark[3] ~= nil, "Agent extmark must exist")
  local agent_vl = agent_mark[3].virt_lines
  for _, line_chunks in ipairs(agent_vl or {}) do
    for _, chunk in ipairs(line_chunks) do
      assert(not chunk[1]:find("Thinking"), "Agent divider must NOT contain Thinking text: " .. tostring(chunk[1]))
    end
  end

  -- Check Footer
  local foot_mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.footer_extmark_id, { details = true })
  assert(foot_mark ~= nil and foot_mark[3] ~= nil, "Footer extmark must exist")
  local foot_vl = foot_mark[3].virt_lines
  for _, line_chunks in ipairs(foot_vl or {}) do
    for _, chunk in ipairs(line_chunks) do
      assert(not chunk[1]:find("%[Thinking%.%.%.%]"), "Footer must NOT contain [Thinking...]: " .. tostring(chunk[1]))
    end
  end

  protocol.cleanup_buffer(buf)
  vim.cmd("bdelete! " .. buf)
end)

-- ---------------------------------------------------------------------------
-- TEST 2: Active prompt divider contains animating Thinking... above border
-- ---------------------------------------------------------------------------
run_test("Prompt divider renders animating Thinking... above prompt border", function()
  vim.cmd("edit agy://new")
  local buf = vim.api.nvim_get_current_buf()
  local state = protocol.buffers[buf]

  vim.wait(500, function() return state.stream_info and state.stream_info.status == "ready" end)

  -- Submit prompt
  local p_line = state.prompt_start_line
  vim.api.nvim_buf_set_lines(buf, p_line - 1, -1, false, { "Show thinking spinner" })

  protocol.with_modifiable(buf, function()
    local ext_id, agent_line = render.prepare_turn_submission(buf, state.prompt_start_line, state.prompt_extmark_id, state.config)
    state.agent_extmark_id = ext_id
    state.agent_line = agent_line
    state.prompt_extmark_id = nil
  end)
  state.session.turn_active = true
  state.stream_info.status = "thinking"
  protocol.restore_prompt_area(buf)

  assert(state.prompt_extmark_id ~= nil, "prompt_extmark_id must be restored")
  assert(render.thinking_timers[buf] ~= nil, "Thinking animation timer must be active")

  -- Inspect prompt divider virt_lines
  local p_mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, { details = true })
  assert(p_mark ~= nil and p_mark[3] ~= nil, "Prompt extmark must exist")
  local p_vl = p_mark[3].virt_lines
  assert(#p_vl >= 2, "Prompt divider must have at least 2 virt_lines (thinking line + border line)")
  assert(p_vl[1][1][1]:find("Thinking%.%.%."), "virt_lines[1] must contain Thinking...")
  assert(p_vl[1][1][2] == "AgyBadgeActive", "virt_lines[1] must use AgyBadgeActive highlight")
  assert(p_vl[2][1][2] == "AgyPromptBorder", "virt_lines[2] must be AgyPromptBorder")

  -- Wait for at least one animation frame progression
  local initial_text = p_vl[1][1][1]
  local frame_updated = vim.wait(400, function()
    local cur_mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, { details = true })
    local cur_vl = cur_mark[3].virt_lines
    local cur_text = cur_vl[1][1][1]
    return cur_text ~= initial_text and cur_text:find("Thinking%.%.%.") ~= nil
  end, 20)
  assert(frame_updated, "Thinking spinner animation frames must advance over time")

  protocol.cleanup_buffer(buf)
  vim.cmd("bdelete! " .. buf)
end)

-- ---------------------------------------------------------------------------
-- TEST 3: Streaming text maintains thinking indicator above prompt border
-- ---------------------------------------------------------------------------
run_test("Streaming text maintains thinking indicator above prompt border", function()
  vim.cmd("edit agy://new")
  local buf = vim.api.nvim_get_current_buf()
  local state = protocol.buffers[buf]

  vim.wait(500, function() return state.stream_info and state.stream_info.status == "ready" end)

  -- Submit prompt
  local p_line = state.prompt_start_line
  vim.api.nvim_buf_set_lines(buf, p_line - 1, -1, false, { "Stream something" })

  protocol.with_modifiable(buf, function()
    local ext_id, agent_line = render.prepare_turn_submission(buf, state.prompt_start_line, state.prompt_extmark_id, state.config)
    state.agent_extmark_id = ext_id
    state.agent_line = agent_line
    state.prompt_extmark_id = nil
  end)
  state.session.turn_active = true
  state.stream_info.status = "thinking"
  protocol.restore_prompt_area(buf)

  -- Stream markdown chunks
  protocol.with_modifiable(buf, function()
    render.append_text_delta(buf, "Here is line 1 of response.\nHere is line 2 of response.\n", state.config, false)
    protocol.update_prompt_divider(buf)
    protocol.update_footer(buf)
  end)

  local p_mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, { details = true })
  assert(p_mark ~= nil and p_mark[3] ~= nil, "Prompt extmark must exist after streaming")
  local p_vl = p_mark[3].virt_lines
  assert(#p_vl >= 2, "Prompt divider must preserve thinking line and border line after stream delta")
  assert(p_vl[1][1][1]:find("Thinking%.%.%."), "virt_lines[1] must continue displaying Thinking...")
  assert(p_vl[2][1][2] == "AgyPromptBorder", "virt_lines[2] must be AgyPromptBorder")

  protocol.cleanup_buffer(buf)
  vim.cmd("bdelete! " .. buf)
end)

-- ---------------------------------------------------------------------------
-- TEST 4: Turn finalization cleans up thinking indicator and stops timer
-- ---------------------------------------------------------------------------
run_test("Turn finalization cleans up thinking indicator and stops timer", function()
  vim.cmd("edit agy://new")
  local buf = vim.api.nvim_get_current_buf()
  local state = protocol.buffers[buf]

  vim.wait(500, function() return state.stream_info and state.stream_info.status == "ready" end)

  -- Submit prompt
  local p_line = state.prompt_start_line
  vim.api.nvim_buf_set_lines(buf, p_line - 1, -1, false, { "Finish turn" })

  protocol.with_modifiable(buf, function()
    local ext_id, agent_line = render.prepare_turn_submission(buf, state.prompt_start_line, state.prompt_extmark_id, state.config)
    state.agent_extmark_id = ext_id
    state.agent_line = agent_line
    state.prompt_extmark_id = nil
  end)
  state.session.turn_active = true
  state.stream_info.status = "thinking"
  protocol.restore_prompt_area(buf)

  assert(render.thinking_timers[buf] ~= nil, "Timer must be active before turn finish")

  -- Finalize turn
  protocol.with_modifiable(buf, function()
    local next_line, next_p_ext = render.finalize_turn(buf, state.agent_extmark_id, state.agent_line, {
      duration_seconds = 1.5,
      usage = { total_tokens = 100 },
      status = "SUCCESS",
    }, state.config)
    state.prompt_start_line = next_line
    state.prompt_extmark_id = next_p_ext
    state.agent_extmark_id = nil
    state.agent_line = nil
  end)

  assert(render.thinking_timers[buf] == nil, "Thinking animation timer must be stopped after finalize_turn")

  local p_mark = vim.api.nvim_buf_get_extmark_by_id(buf, render.NS_UI, state.prompt_extmark_id, { details = true })
  assert(p_mark ~= nil and p_mark[3] ~= nil, "Prompt extmark must exist after finish")
  local p_vl = p_mark[3].virt_lines
  assert(#p_vl == 1, "Prompt divider must have only 1 virt_line (prompt border only) after turn completion")
  assert(p_vl[1][1][2] == "AgyPromptBorder", "Single virt_line must be AgyPromptBorder")
  assert(not p_vl[1][1][1]:find("Thinking"), "Prompt divider must not contain Thinking after completion")

  protocol.cleanup_buffer(buf)
  vim.cmd("bdelete! " .. buf)
end)

-- ---------------------------------------------------------------------------
-- TEST 5: animate_thinking = false does not start timer
-- ---------------------------------------------------------------------------
run_test("animate_thinking = false does not start timer", function()
  local no_anim_cfg = config.setup({
    ui = {
      animate_thinking = false,
    },
  })
  local test_buf = vim.api.nvim_create_buf(false, true)
  local test_ext = render.set_divider(test_buf, 0, "user", nil, nil, true, nil, no_anim_cfg)
  render.start_thinking_animation(test_buf, 0, test_ext, no_anim_cfg)
  assert(render.thinking_timers[test_buf] == nil, "Timer must not be started when animate_thinking = false")
  vim.cmd("bdelete! " .. test_buf)
end)

print("\nALL THINKING PROMPT RELOCATION TESTS PASSED SUCCESSFULLY!")
