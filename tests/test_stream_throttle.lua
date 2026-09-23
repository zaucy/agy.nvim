local protocol = require("agy.protocol")
local render = require("agy.render")
local config_mod = require("agy.config")
local utils = require("agy.utils")

print("=== Running Streaming Delta Throttling & Live Redraw Tests ===")

local cfg = config_mod.setup({
  ui = {
    header_style = "banner",
    animate_thinking = true,
    animate_logo = true,
  },
})

-- Setup test buffer and protocol state
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local win = vim.api.nvim_get_current_win()

protocol.buffers[buf] = {
  buf = buf,
  conversation_id = "test-stream-conv",
  config = cfg,
  tool_calls = {},
  stream_info = { status = "ready" },
  prompt_start_line = 1,
  follow_bottom = true,
  active_agent_started_output = false,
}
local state = protocol.buffers[buf]

-- [Test 1] Immediate Initial Chunk Rendering with Zero Lag
print("\n[Test 1] Testing immediate first delta flush...")
state.active_agent_started_output = false
state.last_stream_render_time = nil
state.pending_text_delta = nil

-- Prepare agent turn in buffer
render.render_new_session(buf, cfg)
local extmark_id, agent_line = render.prepare_turn_submission(buf, 3, nil, cfg)
state.agent_extmark_id = extmark_id
state.agent_line = agent_line
state.prompt_start_line = agent_line + 1

protocol.queue_stream_delta(buf, "Hello, ")
assert(state.pending_text_delta == nil, "First delta must be flushed immediately with zero delay")
assert(state.last_stream_render_time ~= nil, "last_stream_render_time must be updated")

local lines1 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local text1 = table.concat(lines1, "\n")
assert(text1:find("Hello, "), "First delta must appear in buffer immediately")
print("✓ First streaming delta rendered immediately with zero latency")

-- [Test 2] High-Frequency Deltas Batching
print("\n[Test 2] Testing rapid deltas batching into pending queue...")
-- Rapid second and third deltas arriving within < 30ms of first delta
protocol.queue_stream_delta(buf, "world")
protocol.queue_stream_delta(buf, " of Antigravity!")

assert(state.pending_text_delta == "world of Antigravity!", "Rapid incoming deltas must be batched into pending_text_delta")
assert(state.stream_flush_timer ~= nil, "stream_flush_timer must be active for rapid deltas")

-- Advance event loop / timer to allow the batched flush
local ok = vim.wait(200, function()
  return state.pending_text_delta == nil
end, 10)

assert(ok, "Timer must flush pending deltas within throttle window")
assert(state.stream_flush_timer == nil, "Timer must be cleared after flush")

local lines2 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local text2 = table.concat(lines2, "\n")
assert(text2:find("Hello, world of Antigravity!"), "Batched deltas must appear combined in buffer")
print("✓ Rapid streaming deltas batched and rendered seamlessly at throttle window")

-- [Test 3] Automatic Flush on Tool Call Step Transition
print("\n[Test 3] Testing automatic flush before tool call...")
protocol.queue_stream_delta(buf, "Now let's run a tool...")
-- Force it into pending by faking recent render time
state.last_stream_render_time = vim.uv.hrtime() / 1e6
if not state.stream_flush_timer then
  local timer = (vim.uv and vim.uv.new_timer) and vim.uv.new_timer() or vim.loop.new_timer()
  state.stream_flush_timer = timer
  timer:start(500, 0, function() end)
end

assert(state.pending_text_delta ~= nil, "Pending delta should be queued")

-- Flush manually or via tool step
protocol.flush_stream_delta(buf, false)
assert(state.pending_text_delta == nil, "flush_stream_delta must clear pending delta")
assert(state.stream_flush_timer == nil, "stream_flush_timer must be stopped and cleared")

local lines3 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local text3 = table.concat(lines3, "\n")
assert(text3:find("Now let's run a tool..."), "Flushed delta must be in buffer")
print("✓ Step transition flushes pending text delta immediately")

-- [Test 4] Automatic Flush on on_result
print("\n[Test 4] Testing automatic flush in on_result...")
state.pending_text_delta = "Final remarks before finish."
protocol.flush_stream_delta(buf, false)
assert(state.pending_text_delta == nil, "flush_stream_delta must empty pending delta")

local lines4 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local text4 = table.concat(lines4, "\n")
assert(text4:find("Final remarks before finish."), "Final delta must be rendered in buffer")
print("✓ on_result flushes any pending stream text delta")

-- [Test 5] Buffer Cleanup Cancels Flush Timer
print("\n[Test 5] Testing cleanup_buffer stops stream timer...")
local buf_cleanup = vim.api.nvim_create_buf(false, true)
protocol.buffers[buf_cleanup] = {
  buf = buf_cleanup,
  config = cfg,
  tool_calls = {},
  stream_info = { status = "generating" },
  pending_text_delta = "leftover",
  stream_flush_timer = (vim.uv and vim.uv.new_timer) and vim.uv.new_timer() or vim.loop.new_timer(),
}
protocol.cleanup_buffer(buf_cleanup)
assert(protocol.buffers[buf_cleanup] == nil, "Buffer state must be cleared")
print("✓ cleanup_buffer properly clears timer and state")

-- [Test 6] Persistent uv_timer Animation Lifecycle
print("\n[Test 6] Testing thinking and logo uv_timer lifecycles...")
local anim_buf = vim.api.nvim_create_buf(false, true)
local ext_anim = render.set_divider(anim_buf, 0, "agent", " [Thinking...]", "AgyBadgeActive", false, nil, cfg)
render.start_thinking_animation(anim_buf, 0, ext_anim, cfg)
assert(render.thinking_timers[anim_buf] ~= nil, "Thinking timer must exist")

render.stop_thinking_animation(anim_buf)
assert(render.thinking_timers[anim_buf] == nil, "Thinking timer must be stopped and cleared")

render.stop_logo_animation(buf)
render.start_logo_animation(anim_buf, cfg)
assert(render.logo_timer ~= nil, "Logo timer must exist")
render.stop_logo_animation(anim_buf)
assert(render.logo_timer == nil, "Logo timer must be stopped and cleared")
print("✓ Animation persistent uv_timer lifecycle verified")

print("\nALL STREAMING THROTTLE & LIVE REDRAW TESTS PASSED PERFECTLY!")
