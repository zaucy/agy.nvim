local config = require("agy.config")
local render = require("agy.render")
local protocol = require("agy.protocol")
local session_mod = require("agy.session")
local completion = require("agy.completion")
local context_mod = require("agy.context")
local quota_mod = require("agy.quota")
local tasks_mod = require("agy.tasks")
local panel_mod = require("agy.panel")

print("=== Running Code Review Fixes Verification Tests ===")

-- ============================================================================
-- [Test 1] Config Icons & Validation Assertions (AGENTS.md Rules 1, 3, 4)
-- ============================================================================
print("\n[Test 1] Testing config icons and validation assertions...")
config.setup({})
local cfg = config.get()

local required_icons = {
	"default",
	"tool",
	"run_command",
	"view_file",
	"replace_file_content",
	"write_to_file",
	"thought",
	"user",
	"agent",
	"prompt_sign",
	"footer",
	"done",
	"question",
	"error",
	"cancelled",
	"queue",
	"context",
	"quota",
	"tasks",
	"info",
	"status_switch",
	"status_added",
	"bar_fill",
	"bar_empty",
}
for _, k in ipairs(required_icons) do
	assert(cfg.icons[k] ~= nil, "Missing canonical icon key in config.defaults.icons: " .. k)
end

-- Verify config validation fails fast on invalid CLI option types
local ok_agent = pcall(config.setup, { agent = 123 })
assert(not ok_agent, "config.setup must assert when agent is not a string")

local ok_sandbox = pcall(config.setup, { sandbox = "yes" })
assert(not ok_sandbox, "config.setup must assert when sandbox is not a boolean")

local ok_skip = pcall(config.setup, { dangerously_skip_permissions = "true" })
assert(not ok_skip, "config.setup must assert when dangerously_skip_permissions is not a boolean")

-- Verify render fails fast when required icon is nil
local bad_cfg = vim.deepcopy(config.get())
bad_cfg.icons.error = nil
local tmp_buf = vim.api.nvim_create_buf(false, true)
local ok_render_err = pcall(render.render_error, tmp_buf, "boom", bad_cfg)
assert(not ok_render_err, "render.render_error must assert when config.icons.error is nil")
pcall(vim.api.nvim_buf_delete, tmp_buf, { force = true })
print("✓ Config icons and fail-fast assertions verified")

-- ============================================================================
-- [Test 2] Global Scope Hygiene (No Leaked Globals)
-- ============================================================================
print("\n[Test 2] Testing global scope hygiene...")
_G.q_prefix = nil
_G.quota_wrap_text = nil

local q_buf = vim.api.nvim_create_buf(false, true)
render.init_session_buffer(q_buf, "agy://test-globals", cfg)
local sample_questions = {
	{
		question = "Which option?",
		options = { "Option A", "Option B" },
		is_multi_select = false,
	},
}
render.render_question_block(q_buf, sample_questions, cfg)
assert(_G.q_prefix == nil, "render_question_block must not leak q_prefix to _G")

render.render_historical_question(q_buf, { questions = sample_questions }, "A: Option A", cfg)
assert(_G.q_prefix == nil, "render_historical_question must not leak q_prefix to _G")

context_mod.build_content({ buf = q_buf }, cfg, 80)
assert(_G.quota_wrap_text == nil, "context.lua must not leak quota_wrap_text to _G")
pcall(vim.api.nvim_buf_delete, q_buf, { force = true })
print("✓ No global variable leaks (q_prefix, quota_wrap_text)")

-- ============================================================================
-- [Test 3] Panel Keymaps Registration (panel.lua & tasks.lua)
-- ============================================================================
print("\n[Test 3] Testing panel.open keymaps registration...")
local host_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(host_buf)
local host_win = vim.api.nvim_get_current_win()

local cr_triggered = false
local k_triggered = false
local p_win, p_buf = panel_mod.open({
	target_win = host_win,
	target_buf = host_buf,
	lines = { "Line 1", "Line 2" },
	focus = true,
	keymaps = {
		["<CR>"] = function()
			cr_triggered = true
		end,
		["k"] = function()
			k_triggered = true
		end,
	},
})
assert(p_buf and vim.api.nvim_buf_is_valid(p_buf), "Panel buffer must be valid")
vim.api.nvim_set_current_buf(p_buf)
local p_cr_map = vim.fn.maparg("<CR>", "n", false, true)
local p_k_map = vim.fn.maparg("k", "n", false, true)
assert(p_cr_map and p_cr_map.callback ~= nil, "Panel buffer must register <CR> keymap from opts.keymaps")
assert(p_k_map and p_k_map.callback ~= nil, "Panel buffer must register k keymap from opts.keymaps")
p_cr_map.callback()
p_k_map.callback()
assert(cr_triggered == true, "<CR> callback must be invoked")
assert(k_triggered == true, "k callback must be invoked")
panel_mod.close()
pcall(vim.api.nvim_buf_delete, host_buf, { force = true })
print("✓ panel.open keymaps registration verified")

-- ============================================================================
-- [Test 4] Context Turn Counting via Virtual Divider Extmarks & Custom Icons
-- ============================================================================
print("\n[Test 4] Testing context turn counting and custom icons...")
local custom_cfg = config.setup({
	icons = {
		context = "[CTX]",
		quota = "[QTA]",
		tasks = "[TSK]",
		info = "[INF]",
		status_switch = "[SW]",
		status_added = "[ADD]",
		bar_fill = "#",
		bar_empty = "-",
	},
})

local c_buf = vim.api.nvim_create_buf(false, true)
local cp_line, cp_ext = render.render_transcript(c_buf, "test-conv-turns", {
	{ type = "USER_INPUT", content = "Hello from user" },
	{ type = "PLANNER_RESPONSE", content = "Hello from assistant" },
}, custom_cfg)
local c_state = {
	buf = c_buf,
	conversation_id = "new",
	prompt_start_line = cp_line,
	prompt_extmark_id = cp_ext,
}
local ctx_lines, _ = context_mod.build_content(c_state, custom_cfg, 80)
local ctx_text = table.concat(ctx_lines, "\n")
assert(ctx_text:find("%[CTX%] Context Breakdown") ~= nil, "Context header must use config.icons.context: " .. ctx_text)
assert(ctx_text:find("User messages %(1%)") ~= nil, "Context must count virtual user divider turns accurately: " .. ctx_text)
assert(ctx_text:find("Model responses %(1%)") ~= nil, "Context must count virtual agent divider turns accurately: " .. ctx_text)
assert(ctx_text:find("[#%-]+") ~= nil, "Context bar must use config.icons.bar_fill/bar_empty")

local q_lines, _ = quota_mod.build_content({
	groups = {
		{
			name = "Gemini",
			buckets = {
				{ name = "Weekly Limit Remaining", remaining_fraction = 1.0 },
			},
		},
	},
}, "user@example.com", nil, 80, "gemini-4-argon-high", "high", custom_cfg)
local q_text = table.concat(q_lines, "\n")
assert(q_text:find("%[QTA%] Models & Quota") ~= nil, "Quota header must use config.icons.quota: " .. q_text)
assert(q_text:find("##########") ~= nil, "Quota bar must use config.icons.bar_fill: " .. q_text)

local t_lines, _ = tasks_mod.build_content(c_state, custom_cfg, 80)
local t_text = table.concat(t_lines, "\n")
assert(t_text:find("%[TSK%] Background Tasks") ~= nil, "Tasks header must use config.icons.tasks: " .. t_text)

pcall(vim.api.nvim_buf_delete, c_buf, { force = true })
config.setup({}) -- Reset to defaults
print("✓ Context virtual divider turn counting and custom panel icons verified")

-- ============================================================================
-- [Test 5] Tasks Canonical Parameter Parsing (No Synonym Fallbacks)
-- ============================================================================
print("\n[Test 5] Testing tasks.parse_task_info canonical CommandLine parameter...")
local sample_task_out = "Tool is running as a background task with task id: conv-123/task-7\nTask logs are available at: file:///tmp/task-7.log"
local info_canonical = tasks_mod.parse_task_info(sample_task_out, { CommandLine = "cargo test" })
assert(info_canonical ~= nil, "parse_task_info must parse valid background task output")
assert(info_canonical.command == "cargo test", "parse_task_info must extract canonical CommandLine")

local info_alias = tasks_mod.parse_task_info(sample_task_out, { cmd = "cargo test", command = "cargo test" })
assert(info_alias.command == "command", "parse_task_info must not use non-canonical cmd/command aliases")
print("✓ Tasks canonical parameter parsing verified")

-- ============================================================================
-- [Test 6] Session CLI Flags & Workspace Preservation
-- ============================================================================
print("\n[Test 6] Testing session CLI flags and add_workspace preservation...")
local s1 = session_mod.new({
	agy_cmd = "agy",
	cwd = "/workspace/main",
	agent = "coder",
	sandbox = true,
	dangerously_skip_permissions = true,
})
local cmd1 = s1:_build_cmd()
assert(vim.tbl_contains(cmd1, "--agent"), "Expected --agent flag in CLI command")
assert(vim.tbl_contains(cmd1, "coder"), "Expected agent name 'coder' in CLI command")
assert(vim.tbl_contains(cmd1, "--sandbox"), "Expected --sandbox flag in CLI command")
assert(vim.tbl_contains(cmd1, "--dangerously-skip-permissions"), "Expected --dangerously-skip-permissions flag in CLI command")

-- Resumed session starts with empty workspaces {} so CLI uses saved workspaces;
-- when user runs /add-dir, session:add_workspace must preserve cwd and avoid duplicates
local s_resumed = session_mod.new({
	conversation_id = "existing-conv-123",
	cwd = "/workspace/original",
})
assert(#s_resumed.workspaces == 0, "Resumed session starts with empty explicit workspaces")
s_resumed:add_workspace("/workspace/extra")
assert(#s_resumed.workspaces == 2, "add_workspace on resumed session must preserve cwd + new workspace")
assert(vim.fs.normalize(s_resumed.workspaces[1]) == vim.fs.normalize("/workspace/original"), "First workspace must be original cwd")
assert(vim.fs.normalize(s_resumed.workspaces[2]) == vim.fs.normalize("/workspace/extra"), "Second workspace must be added dir")
-- Adding duplicate must be a no-op
s_resumed:add_workspace("/workspace/extra")
assert(#s_resumed.workspaces == 2, "add_workspace must not insert duplicate directories")
print("✓ Session CLI flags and workspace preservation verified")

-- ============================================================================
-- [Test 7] New Slash Commands (/fast, /planning, /effort xhigh|max, /copy, /open, /undo)
-- ============================================================================
print("\n[Test 7] Testing new slash commands (/fast, /planning, /effort, /copy, /open, /undo)...")
config.setup({})
vim.cmd("edit agy://new")
local sbuf = vim.api.nvim_get_current_buf()
local sstate = protocol.buffers[sbuf]
assert(sstate ~= nil, "Session buffer state must exist")

-- Prevent actual CLI spawn during unit test of local control commands
sstate.session.start = function()
	return true
end
sstate.session.send_prompt = function()
	return true
end

-- 1. /fast
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/fast" })
end)
protocol.handle_write(sbuf)
assert(sstate.session.mode == "accept-edits", "/fast must set session mode to accept-edits")
assert(sstate.stream_info.permission_mode == "accept-edits", "/fast must set stream_info.permission_mode to accept-edits")

-- 2. /planning
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/planning" })
end)
protocol.handle_write(sbuf)
assert(sstate.session.mode == "plan", "/planning must set session mode to plan")
assert(sstate.stream_info.permission_mode == "plan", "/planning must set stream_info.permission_mode to plan")

-- 2b. /mode rejects non-canonical synonyms (fast, planning)
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/mode fast" })
end)
protocol.handle_write(sbuf)
assert(sstate.session.mode == "plan", "/mode fast must be rejected and not alias to accept-edits")
local ok_bad_mode = pcall(protocol.set_mode, sbuf, "fast")
assert(not ok_bad_mode, "protocol.set_mode must assert on non-canonical mode 'fast'")

-- 3. /effort xhigh and /effort max
local effort_comp = completion.get_completions("/effort ", 8)
assert(effort_comp and #effort_comp.items == 5, "Expected 5 effort choices (low, medium, high, xhigh, max)")
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/effort xhigh" })
end)
protocol.handle_write(sbuf)
assert(sstate.session.effort == "xhigh", "/effort xhigh must set session effort to xhigh")

protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/effort max" })
end)
protocol.handle_write(sbuf)
assert(sstate.session.effort == "max", "/effort max must set session effort to max")

-- 4. /copy (from last_agent_response and from transcript s.content fallback)
sstate.last_agent_response = "Here is the assistant response to copy."
vim.fn.setreg('"', "")
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/copy" })
end)
protocol.handle_write(sbuf)
assert(vim.fn.getreg('"') == "Here is the assistant response to copy.", "/copy must copy last_agent_response to register")

-- 4b. /copy transcript fallback when state.last_agent_response is empty
local test_helpers = require("tests.test_helpers")
local tmp_copy_dir, copy_cid = test_helpers.create_mock_environment()
local orig_conv_id = sstate.conversation_id
local orig_app_data = sstate.config.app_data_dir
sstate.last_agent_response = ""
sstate.conversation_id = copy_cid
sstate.config.app_data_dir = tmp_copy_dir
vim.fn.setreg('"', "")
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/copy" })
end)
protocol.handle_write(sbuf)
local copied_from_transcript = vim.fn.getreg('"')
assert(
	copied_from_transcript == "I have viewed the file.",
	"/copy must fall back to reading PLANNER_RESPONSE s.content from transcript when last_agent_response is empty, got: "
		.. tostring(copied_from_transcript)
)
sstate.conversation_id = orig_conv_id
sstate.config.app_data_dir = orig_app_data

-- 5. /undo reverts the last turn in the buffer and state and restores the prompt
local lines_before_turn = vim.api.nvim_buf_get_lines(sbuf, 0, sstate.prompt_start_line - 1, false)
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, {
		"My previously submitted prompt",
		"Line 2 of prompt",
	})
end)
protocol.handle_write(sbuf)
-- Simulate assistant output and tool call in the turn
sstate.session.turn_active = false
table.insert(sstate.tool_calls, { name = "view_file", status = "success" })
table.insert(sstate.work_groups, { title = "Group 1" })
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, -1, -1, false, { "Assistant response line 1", "Assistant response line 2" })
	local new_p_line, new_p_ext = render.finalize_turn(sbuf, nil, nil, {}, sstate.config)
	sstate.prompt_start_line = new_p_line
	sstate.prompt_extmark_id = new_p_ext
end)
local full_before_undo = table.concat(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), "\n")
assert(full_before_undo:find("Assistant response line 1", 1, true) ~= nil, "Turn output must exist before /undo")
assert(#sstate.tool_calls == 1, "Tool call must exist before /undo")

protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/undo" })
end)
protocol.handle_write(sbuf)
local restored_prompt = protocol.extract_prompt(sbuf)
assert(
	restored_prompt == "My previously submitted prompt\nLine 2 of prompt",
	"/undo must restore last_sent_prompt into prompt input, got: " .. tostring(restored_prompt)
)
local full_after_undo = table.concat(vim.api.nvim_buf_get_lines(sbuf, 0, sstate.prompt_start_line - 1, false), "\n")
assert(
	full_after_undo:find("Assistant response line 1", 1, true) == nil,
	"/undo must remove the reverted turn's assistant output from buffer"
)
assert(
	#vim.api.nvim_buf_get_lines(sbuf, 0, sstate.prompt_start_line - 1, false) == #lines_before_turn,
	"/undo must restore buffer history above prompt to pre-turn state"
)
assert(#sstate.tool_calls == 0, "/undo must revert tool_calls added during the undone turn")
assert(#sstate.work_groups == 0, "/undo must revert work_groups added during the undone turn")

-- 6. /open completion and execution
local open_comp = completion.get_completions("/open init", 10, nil, { vim.fn.getcwd() })
assert(open_comp and open_comp.type == "arg" and #open_comp.items > 0, "/open must provide file completions")
protocol.with_modifiable(sbuf, function()
	vim.api.nvim_buf_set_lines(sbuf, sstate.prompt_start_line - 1, -1, false, { "/open README.md" })
end)
protocol.handle_write(sbuf)
local opened_name = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
assert(opened_name:find("README%.md$") ~= nil, "/open README.md must open README.md in current window, got: " .. opened_name)

protocol.cleanup_buffer(sbuf)
pcall(vim.api.nvim_buf_delete, sbuf, { force = true })
print("✓ New slash commands (/fast, /planning, /effort, /copy, /open, /undo) verified")

-- ============================================================================
-- [Test 8] Prompt Queue Top Border Extmark Update on Clear
-- ============================================================================
print("\n[Test 8] Testing render.render_queue updates prompt extmark when queue clears...")
local qbuf2 = vim.api.nvim_create_buf(false, true)
local p_line, p_ext = render.init_session_buffer(qbuf2, "agy://test-queue-ext", config.get())
protocol.buffers[qbuf2] = {
	buf = qbuf2,
	config = config.get(),
	prompt_start_line = p_line,
	prompt_extmark_id = p_ext,
}
local queue_items = {
	{ id = 1, text = "First queued message" },
}
local new_p_line = render.render_queue(qbuf2, queue_items, p_line, config.get())
protocol.buffers[qbuf2].prompt_start_line = new_p_line
local cleared_p_line = render.render_queue(qbuf2, {}, new_p_line, config.get())
local ext_pos = vim.api.nvim_buf_get_extmark_by_id(qbuf2, render.NS_UI, p_ext, {})
assert(ext_pos and ext_pos[1] == cleared_p_line - 1, "Prompt divider extmark row must match cleared prompt line - 1")
protocol.buffers[qbuf2] = nil
pcall(vim.api.nvim_buf_delete, qbuf2, { force = true })
print("✓ render.render_queue prompt extmark update verified")

-- ============================================================================
-- [Test 9] Context Nil Config & Tasks Canonical Status Highlights
-- ============================================================================
print("\n[Test 9] Testing context.build_content with nil cfg and tasks canonical highlights...")
local ctx_nil_lines = context_mod.build_content({}, nil, 80)
assert(type(ctx_nil_lines) == "table" and #ctx_nil_lines > 0, "context.build_content must work when cfg is nil")

local th_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(th_buf, 0, -1, false, {
	"header",
	"  task-1    ✓ Success   0   echo 1",
	"  task-2    ✓ Success   0   echo 2",
})
tasks_mod.apply_highlights(th_buf, {
	{ type = "task_row", row = 1, extra = { task = { status = "done" } } },
	{ type = "task_row", row = 2, extra = { task = { status = "success" } } },
})
local th_marks = vim.api.nvim_buf_get_extmarks(th_buf, tasks_mod.NS_TASKS, 0, -1, { details = true })
local row1_hl, row2_hl
for _, m in ipairs(th_marks) do
	if m[2] == 1 and m[4].hl_group ~= "AgyTaskId" and m[4].hl_group ~= "AgyTaskCommand" then
		row1_hl = m[4].hl_group
	elseif m[2] == 2 and m[4].hl_group ~= "AgyTaskId" and m[4].hl_group ~= "AgyTaskCommand" then
		row2_hl = m[4].hl_group
	end
end
assert(row1_hl == "AgyTaskRunning", "Non-canonical 'done' status must not alias to 'success', got: " .. tostring(row1_hl))
assert(row2_hl == "AgyTaskSuccess", "Canonical 'success' status must highlight with AgyTaskSuccess, got: " .. tostring(row2_hl))
pcall(vim.api.nvim_buf_delete, th_buf, { force = true })
print("✓ context.build_content nil cfg and tasks canonical status highlights verified")

-- ============================================================================
-- [Test 10] Pruned Hallucinated No-Op Control & Modifier Commands + /compact
-- ============================================================================
print("\n[Test 10] Testing hallucinated control & modifier commands are pruned and /compact exists...")
local pruned_commands = {
	"/agents", "/auth", "/compress", "/feedback", "/forget", "/git", "/hooks",
	"/init", "/lint", "/log", "/mcp", "/memory", "/notify", "/permissions",
	"/plugins", "/profile", "/rag", "/reload", "/remote-control", "/replay",
	"/restore", "/rules", "/save", "/scratch", "/search", "/share", "/sidecar",
	"/skills", "/stats", "/subagent", "/summary", "/tags", "/telemetry",
	"/theme", "/timeout", "/tools", "/verbose",
	"/architect", "/bug", "/flow", "/mutate", "/pair",
}
for _, cmd_name in ipairs(pruned_commands) do
	assert(not completion.is_control(cmd_name), "Hallucinated command must not be in control commands: " .. cmd_name)
	assert(not completion.is_modifier(cmd_name), "Hallucinated command must not be in modifier commands: " .. cmd_name)
	assert(completion.find_command(cmd_name) == nil, "Hallucinated command must be pruned from M.COMMANDS: " .. cmd_name)
end
assert(completion.is_modifier("/compact"), "/compact must be registered as a modifier command")
local compact_cmd = completion.find_command("/compact")
assert(compact_cmd and compact_cmd.category == "modifier", "/compact must exist in M.COMMANDS with category 'modifier'")
print("✓ All 42 hallucinated control & modifier slash commands pruned and /compact verified")

-- ============================================================================
-- [Test 11] expr = true Insert-Mode Completion Keymaps
-- ============================================================================
print("\n[Test 11] Testing completion insert-mode keymaps use expr = true...")
local expr_buf = vim.api.nvim_create_buf(false, true)
completion.setup_buffer(expr_buf)
vim.api.nvim_set_current_buf(expr_buf)
for _, lhs in ipairs({ "<CR>", "<Up>", "<Down>", "<Tab>", "<S-Tab>", "<C-n>", "<C-p>", "<Esc>" }) do
	local m = vim.fn.maparg(lhs, "i", false, true)
	assert(m and m.expr == 1, "Completion insert keymap " .. lhs .. " must use expr = true")
end
pcall(vim.api.nvim_buf_delete, expr_buf, { force = true })
print("✓ Completion insert-mode keymaps verified with expr = true")

-- ============================================================================
-- [Test 12] Multi-Buffer Question State Isolation (question.lua)
-- ============================================================================
print("\n[Test 12] Testing multi-buffer question state isolation...")
local question_mod = require("agy.question")
local q_buf_a = vim.api.nvim_create_buf(false, true)
local q_buf_b = vim.api.nvim_create_buf(false, true)
local q_win = vim.api.nvim_get_current_win()

local submitted_a = nil
local submitted_b = nil
vim.api.nvim_win_set_buf(q_win, q_buf_a)
question_mod.show(q_win, q_buf_a, {
	{ question = "Question in Buffer A?", options = { "Alpha 1", "Alpha 2" }, is_multi_select = false },
}, {
	on_submit = function(payload)
		submitted_a = payload
	end,
})
assert(question_mod.is_visible(q_buf_a), "Question in Buffer A must be visible")

vim.api.nvim_win_set_buf(q_win, q_buf_b)
question_mod.show(q_win, q_buf_b, {
	{ question = "Question in Buffer B?", options = { "Beta 1", "Beta 2" }, is_multi_select = false },
}, {
	on_submit = function(payload)
		submitted_b = payload
	end,
})
assert(question_mod.is_visible(q_buf_a), "Question in Buffer A must remain visible when Buffer B opens a question")
assert(question_mod.is_visible(q_buf_b), "Question in Buffer B must be visible")

-- Submit Buffer B's question via bound controller
local ui_b = question_mod.bind_buffer(q_buf_b)
ui_b.select_next()
ui_b.accept()
assert(submitted_b == "A: Beta 2", "Buffer B must submit Beta 2, got: " .. tostring(submitted_b))
assert(not question_mod.is_visible(q_buf_b), "Buffer B question must close after submit")
assert(question_mod.is_visible(q_buf_a), "Buffer A question must still be active after Buffer B closes")

-- Submit Buffer A's question via bound controller
local ui_a = question_mod.bind_buffer(q_buf_a)
ui_a.accept()
assert(submitted_a == "A: Alpha 1", "Buffer A must submit Alpha 1, got: " .. tostring(submitted_a))
assert(not question_mod.is_visible(q_buf_a), "Buffer A question must close after submit")

pcall(vim.api.nvim_buf_delete, q_buf_a, { force = true })
pcall(vim.api.nvim_buf_delete, q_buf_b, { force = true })
print("✓ Multi-buffer question state isolation verified")

-- ============================================================================
-- [Test 13] Empty Icon Support in is_compact_header_line & Highlight Preservation
-- ============================================================================
print("\n[Test 13] Testing is_compact_header_line with empty string icons & highlight preservation...")
local empty_icon_cfg = vim.deepcopy(config.get())
empty_icon_cfg.icons.view_file = ""
empty_icon_cfg.icons.thought = ""
assert(
	render.is_compact_header_line(" view_file `lua/agy/init.lua`", empty_icon_cfg) == true,
	"is_compact_header_line must recognize tool header when tool icon is empty string"
)
assert(
	render.is_compact_header_line("Thought (1.2s)", empty_icon_cfg) == true,
	"is_compact_header_line must recognize thought header when thought icon is empty string"
)

vim.api.nvim_set_hl(0, "@keyword", { fg = 0x123456 })
render.setup_highlights()
local kw_hl = vim.api.nvim_get_hl(0, { name = "@keyword", link = false })
assert(kw_hl and kw_hl.fg == 0x123456, "setup_highlights must not overwrite user @keyword highlight group")
print("✓ Empty icon compact header detection and Tree-sitter highlight preservation verified")

print("\nALL CODE REVIEW FIXES VERIFICATION TESTS PASSED!")
