local completion = require("agy.completion")
local render = require("agy.render")
local transcript = require("agy.transcript")

print("=== Running Native agy Autocomplete & Floating Menu Tests ===")

render.setup_highlights()

-- [Test 1] Testing slash command candidate filtering
print("\n[Test 1] Testing slash command completion...")
local comp_slash = completion.get_completions("/", 1)
assert(comp_slash ~= nil, "Expected slash command completions")
assert(#comp_slash.items >= 30, "Expected at least 30 slash commands, got " .. #comp_slash.items)

local comp_ad = completion.get_completions("/ad", 3)
assert(comp_ad ~= nil and #comp_ad.items >= 1, "Expected match for /ad")
local has_add_dir = false
for _, it in ipairs(comp_ad.items) do
	if it.label == "/add-dir" then
		has_add_dir = true
		assert(it.kind == "Command", "Expected kind == Command")
		assert(it.arg_type == "dir", "Expected arg_type == dir")
		break
	end
end
assert(has_add_dir, "Expected /add-dir in /ad completions")
print("✓ Slash command filtering and metadata verified")

-- [Test 2] Testing directory argument completion
print("\n[Test 2] Testing directory argument completion...")
local comp_dir = completion.get_completions("/add-dir test", 13)
assert(comp_dir ~= nil and comp_dir.type == "arg", "Expected arg type completion")
assert(#comp_dir.items >= 1, "Expected at least 1 directory match for 'test'")
local first_dir = comp_dir.items[1]
assert(first_dir.kind == "Directory", "Expected kind == Directory")
assert(first_dir.label:find("tests[/\\]") ~= nil, "Expected label to contain 'tests': " .. first_dir.label)
print("✓ Directory completion verified: " .. first_dir.label .. " -> " .. first_dir.detail)

-- [Test 3] Testing choice argument completion (e.g. /model, /mode)
print("\n[Test 3] Testing choice argument and rich /model completion...")
local comp_mode = completion.get_completions("/mode ", 6)
assert(comp_mode ~= nil and #comp_mode.items == 3, "Expected 3 mode choices")
local mode_labels = {}
for _, m in ipairs(comp_mode.items) do
	table.insert(mode_labels, m.label)
end
assert(vim.tbl_contains(mode_labels, "accept-edits"), "Missing accept-edits")
assert(vim.tbl_contains(mode_labels, "plan"), "Missing plan")

local comp_model = completion.get_completions("/model fl", 9)
assert(comp_model ~= nil and #comp_model.items >= 2, "Expected at least 2 flash models")
local found_flash = false
for _, m in ipairs(comp_model.items) do
	if m.label:find("flash") then
		found_flash = true
		assert(m.kind ~= nil, "Expected model provider kind")
		break
	end
end
assert(found_flash, "Expected flash model in completions")

-- Fuzzy matching for /model
local comp_pro = completion.get_completions("/model pro", 10)
assert(comp_pro ~= nil and #comp_pro.items >= 1, "Expected match for pro")
assert(comp_pro.items[1].label:find("pro") ~= nil, "Expected pro model: " .. comp_pro.items[1].label)

local comp_sonnet = completion.get_completions("/model sonnet", 13)
assert(comp_sonnet ~= nil and #comp_sonnet.items >= 1, "Expected match for sonnet")
assert(comp_sonnet.items[1].label:find("sonnet") ~= nil, "Expected sonnet model: " .. comp_sonnet.items[1].label)
assert(comp_sonnet.items[1].kind == "Anthropic", "Expected Anthropic provider")
print("✓ Choice completions for /mode and rich fuzzy /model verified")

-- [Test 4] Testing interactive floating window rendering & lifecycle
print("\n[Test 4] Testing interactive floating window rendering & styling...")
local test_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(test_buf)
vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, {
	"# Antigravity Session: agy://new",
	"",
	"/add-dir test",
})
local test_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(test_win, { 3, 14 })

-- Show completion
completion.show(test_win, test_buf, comp_dir)
assert(completion.is_visible(), "Floating window must be visible")

local float_buf = completion.state.buf
assert(float_buf ~= nil and vim.api.nvim_buf_is_valid(float_buf), "Float buffer must be valid")
local float_lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)

print("Float lines rendered:")
for idx, l in ipairs(float_lines) do
	print(string.format("  [%d] %s", idx, l))
end

-- Verify active row pointer '>'
assert(float_lines[1]:sub(1, 2) == "> ", "First line must have active pointer '> '")
-- Verify footer
assert(float_lines[#float_lines] == "↑/↓ Navigate · enter Select · tab Complete", "Footer mismatch")
print("✓ Floating window rendered with pointer, columns, and footer")

-- [Test 5] Testing navigation (select_next, select_prev)
print("\n[Test 5] Testing navigation cycling...")
-- Set up mock items to test cycling
completion.state.items = {
	{ label = "alpha", kind = "Command", detail = "First", insert_text = "alpha " },
	{ label = "beta", kind = "Command", detail = "Second", insert_text = "beta " },
	{ label = "gamma", kind = "Command", detail = "Third", insert_text = "gamma " },
}
completion.state.selected_idx = 1
completion.render_buffer()

completion.select_next()
assert(completion.state.selected_idx == 2, "Expected selected_idx 2")
completion.select_next()
assert(completion.state.selected_idx == 3, "Expected selected_idx 3")
completion.select_next()
assert(completion.state.selected_idx == 1, "Expected wrap to 1")

completion.select_prev()
assert(completion.state.selected_idx == 3, "Expected wrap backwards to 3")
print("✓ select_next and select_prev cycle smoothly")

-- [Test 6] Testing accept with Tab vs Enter
print("\n[Test 6] Testing accept logic...")
vim.api.nvim_set_current_line("/ad")
vim.api.nvim_win_set_cursor(test_win, { 3, 3 })

local comp_accept = completion.get_completions("/ad", 3)
completion.show(test_win, test_buf, comp_accept)

-- Tab completes the command with space
completion.accept(false)
local line_after_tab = vim.api.nvim_get_current_line()
assert(line_after_tab == "/add-dir ", "Expected '/add-dir ', got '" .. line_after_tab .. "'")
print("✓ Tab accepted command and added trailing space: " .. line_after_tab)

-- Enter on argument commits and closes
vim.api.nvim_set_current_line("/mode plan")
local comp_plan = completion.get_completions("/mode plan", 10)
completion.show(test_win, test_buf, comp_plan)
assert(completion.is_visible(), "Float should be visible for /mode plan")

completion.accept(true)
assert(not completion.is_visible(), "Float should be closed after Enter")
print("✓ Enter committed selection and closed completion float")

-- [Test 7] Testing buffer setup & keymap fallbacks
print("\n[Test 7] Testing buffer setup & keymap fallbacks...")
completion.setup_buffer(test_buf)
assert(not completion.is_visible(), "Float should not be open")

completion.close()
vim.api.nvim_buf_delete(test_buf, { force = true })

-- [Test 8] Testing slash command chaining
print("\n[Test 8] Testing slash command chaining...")
local comp_chain_space = completion.get_completions("/plan ", 6)
assert(comp_chain_space ~= nil and #comp_chain_space.items >= 10, "Expected chainable commands after space")
-- Verify control commands are strictly EXCLUDED from chained completions
for _, it in ipairs(comp_chain_space.items) do
	assert(it.label ~= "/add-dir", "Control /add-dir must NOT appear in chained completion")
	assert(it.label ~= "/model", "Control /model must NOT appear in chained completion")
	assert(it.label ~= "/context", "Control /context must NOT appear in chained completion")
	assert(it.label ~= "/settings", "Control /settings must NOT appear in chained completion")
	assert(it.label ~= "/clear", "Control /clear must NOT appear in chained completion")
	assert(it.label ~= "/diff", "Control /diff must NOT appear in chained completion")
	assert(it.label ~= "/resume", "Control /resume must NOT appear in chained completion")
	assert(completion.is_modifier(it.label), "Only modifiers allowed in chained completion: " .. it.label)
end

local comp_chain_filter = completion.get_completions("/plan /b", 8)
assert(comp_chain_filter ~= nil and #comp_chain_filter.items >= 1, "Expected matches for /plan /b")
local has_boost = false
for _, it in ipairs(comp_chain_filter.items) do
	if it.label == "/boost" then
		has_boost = true
	end
end
assert(has_boost, "Expected /boost in /plan /b matches")

-- Test chaining multiple: /plan /boost /grill-me
local comp_triple = completion.get_completions("/plan /boost /grill-me ", 23)
assert(comp_triple ~= nil and #comp_triple.items >= 10, "Expected chainable commands after multiple chained commands")

-- Verify free-form text after chainable command does NOT trigger autocomplete on spaces
local comp_prompt_text = completion.get_completions("/plan Here is my question ", 26)
assert(comp_prompt_text == nil, "Trailing space in free-form prompt text must NOT trigger slash command completion")

local comp_prompt_multi = completion.get_completions("/plan /boost /grill-me My prompt text ", 38)
assert(comp_prompt_multi == nil, "Trailing space after free-form words must NOT trigger slash command completion")

-- Slash command typed in prompt DOES trigger
local comp_prompt_slash = completion.get_completions("/plan Here is my question /b", 28)
assert(comp_prompt_slash ~= nil and #comp_prompt_slash.items >= 1, "Expected matches for /b inside prompt")
print("✓ Slash command chaining verified")

-- [Test 9] Testing control commands restriction
print("\n[Test 9] Testing control command restrictions...")
-- /clear is a control command with no args: should not allow chaining after it
local comp_clear_space = completion.get_completions("/clear ", 7)
assert(comp_clear_space == nil, "Expected nil completion after control /clear")

-- /context and /settings are control commands with no args: should not allow chaining
local comp_ctx_space = completion.get_completions("/context ", 9)
assert(comp_ctx_space == nil, "Expected nil completion after control /context")

local comp_set_space = completion.get_completions("/settings ", 10)
assert(comp_set_space == nil, "Expected nil completion after control /settings")

-- /add-dir with argument completed should not allow chaining
local comp_add_dir_space = completion.get_completions("/add-dir tests/ ", 16)
assert(comp_add_dir_space == nil, "Expected nil completion after control /add-dir with arg")

-- /model with argument completed should not allow chaining
local comp_model_space = completion.get_completions("/model claude-sonnet-4-6 ", 25)
assert(comp_model_space == nil, "Expected nil completion after /model with arg")

-- Control commands cannot be chained after /plan
local comp_chain_add_dir = completion.get_completions("/plan /add-dir", 14)
assert(comp_chain_add_dir == nil, "Control /add-dir cannot appear in chained position")

local comp_chain_model = completion.get_completions("/plan /model", 12)
assert(comp_chain_model == nil, "Control /model cannot appear in chained position")

local comp_chain_ctx = completion.get_completions("/plan /context", 14)
assert(comp_chain_ctx == nil, "Control /context cannot appear in chained position")

local comp_chain_set = completion.get_completions("/plan /settings", 15)
assert(comp_chain_set == nil, "Control /settings cannot appear in chained position")

-- No commands after /clear
local comp_clear_chained = completion.get_completions("/clear /plan", 12)
assert(comp_clear_chained == nil, "No chaining allowed after /clear")
print("✓ Control command restrictions verified")

-- [Test 10] Testing insert mode keybindings without E565 errors
print("\n[Test 10] Testing insert mode keybindings (arrow keys, CR)...")
local key_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(key_buf)
vim.api.nvim_buf_set_lines(key_buf, 0, -1, false, { "/p" })
local key_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(key_win, { 1, 2 })
completion.setup_buffer(key_buf)

local comp_key = completion.get_completions("/p", 2)
completion.show(key_win, key_buf, comp_key)
assert(completion.is_visible(), "Float must be visible")

local next_called_idx = nil
local orig_next = completion.select_next
completion.select_next = function()
	orig_next()
	next_called_idx = completion.state.selected_idx
end

local prev_called_idx = nil
local orig_prev = completion.select_prev
completion.select_prev = function()
	orig_prev()
	prev_called_idx = completion.state.selected_idx
end

-- Test Down arrow key in insert mode
vim.api.nvim_feedkeys(vim.keycode("a<Down>"), "tx", false)
vim.wait(100, function()
	return next_called_idx ~= nil
end)
assert(next_called_idx == 2, "Expected select_next to reach selected_idx 2, got " .. tostring(next_called_idx))

-- Show completion again to test Up arrow key
completion.show(key_win, key_buf, comp_key)
completion.state.selected_idx = 2
vim.api.nvim_feedkeys(vim.keycode("a<Up>"), "tx", false)
vim.wait(100, function()
	return prev_called_idx ~= nil
end)
assert(prev_called_idx == 1, "Expected select_prev to reach selected_idx 1, got " .. tostring(prev_called_idx))

-- Test Enter in insert mode commits selection and closes float
completion.show(key_win, key_buf, comp_key)
vim.api.nvim_feedkeys(vim.keycode("a<CR>"), "tx", false)
vim.wait(100, function()
	return not completion.is_visible()
end)
assert(not completion.is_visible(), "Expected completion float closed after <CR>")

completion.close()
vim.api.nvim_buf_delete(key_buf, { force = true })

-- Test fallback arrow keys and <CR> when completion is NOT visible
local fb_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(fb_buf)
vim.api.nvim_buf_set_lines(fb_buf, 0, -1, false, { "first line", "second line" })
completion.setup_buffer(fb_buf)
vim.cmd("normal! gg")
-- In insert mode, press <Down>, then insert 'x'
vim.api.nvim_feedkeys(vim.keycode("i<Down>x<Esc>"), "tx", false)
local fb_lines = vim.api.nvim_buf_get_lines(fb_buf, 0, -1, false)
assert(fb_lines[2]:sub(1, 1) == "x", "Expected Down arrow fallback to move to second line: " .. vim.inspect(fb_lines))

-- Press <Up>, then insert 'y'
vim.api.nvim_feedkeys(vim.keycode("i<Up>y<Esc>"), "tx", false)
fb_lines = vim.api.nvim_buf_get_lines(fb_buf, 0, -1, false)
assert(fb_lines[1]:sub(1, 1) == "y", "Expected Up arrow fallback to move to first line: " .. vim.inspect(fb_lines))

-- Test Enter fallback
vim.api.nvim_buf_set_lines(fb_buf, 0, -1, false, { "hello" })
vim.cmd("normal! $")
vim.api.nvim_feedkeys(vim.keycode("a<CR>world<Esc>"), "tx", false)
fb_lines = vim.api.nvim_buf_get_lines(fb_buf, 0, -1, false)
assert(
	#fb_lines == 2 and fb_lines[1] == "hello" and fb_lines[2] == "world",
	"Expected CR fallback: " .. vim.inspect(fb_lines)
)
vim.api.nvim_buf_delete(fb_buf, { force = true })
print("✓ Arrow keys and Enter insert mode keybindings verified without errors")

-- [Test 11] Testing protocol /model and one-off handling
print("\n[Test 11] Testing protocol /model extraction & safety...")
require("agy").setup()
vim.cmd("edit agy://new")
local pbuf = vim.api.nvim_get_current_buf()
local protocol = require("agy.protocol")

-- 1. Model switching
protocol.set_model(pbuf, "claude-sonnet-4-6")
assert(protocol.buffers[pbuf].stream_info.model == "claude-sonnet-4-6", "Expected model claude-sonnet-4-6")
assert(protocol.buffers[pbuf].session.model == "claude-sonnet-4-6", "Expected session model claude-sonnet-4-6")

-- 2. Non-blocking model catalogue
local avail = completion.get_available_models()
assert(#avail >= 10, "Expected at least 10 available models")
assert(avail[1].id ~= nil and avail[1].provider ~= nil, "Expected model metadata")

-- 3. Verify handle_write model resolution on :w
protocol.with_modifiable(pbuf, function()
	vim.api.nvim_buf_set_lines(pbuf, protocol.buffers[pbuf].prompt_start_line - 1, -1, false, { "/model sonnet" })
end)
protocol.handle_write(pbuf)
assert(
	protocol.buffers[pbuf].stream_info.model == "claude-sonnet-4-6",
	"Fuzzy /model sonnet should resolve to claude-sonnet-4-6"
)

-- 4. Verify regular text containing /model is NOT intercepted as a command
local test_prompt = "Can you explain how /model works in agy?"
protocol.with_modifiable(pbuf, function()
	vim.api.nvim_buf_set_lines(pbuf, protocol.buffers[pbuf].prompt_start_line - 1, -1, false, { test_prompt })
end)
local extracted = protocol.extract_prompt(pbuf)
assert(extracted == test_prompt, "Regular prompt with /model must be preserved as-is")

pcall(vim.api.nvim_buf_delete, pbuf, { force = true })
print("✓ Protocol model handling and safety verified")

-- [Test 12] Testing command classification taxonomy (Control vs Modifier)
print("\n[Test 12] Testing command classification taxonomy...")
-- Standalone control commands
assert(completion.is_control("/add-dir"), "Expected /add-dir to be control")
assert(completion.is_control("/model"), "Expected /model to be control")
assert(completion.is_control("/context"), "Expected /context to be control")
assert(completion.is_control("/settings"), "Expected /settings to be control")
assert(completion.is_control("/mode"), "Expected /mode to be control")
assert(completion.is_control("/effort"), "Expected /effort to be control")
assert(completion.is_control("/status"), "Expected /status to be control")
assert(completion.is_control("/doctor"), "Expected /doctor to be control")
assert(completion.is_control("/help"), "Expected /help to be control")
assert(completion.is_control("/clear"), "Expected /clear to be control")
assert(completion.is_control("/new"), "Expected /new to be control")
assert(completion.is_control("/diff"), "Expected /diff to be control")

-- Prompt modifiers / directives
assert(completion.is_modifier("/plan"), "Expected /plan to be modifier")
assert(completion.is_modifier("/boost"), "Expected /boost to be modifier")
assert(completion.is_modifier("/grill-me"), "Expected /grill-me to be modifier")
assert(completion.is_modifier("/goal"), "Expected /goal to be modifier")
assert(completion.is_modifier("/browser"), "Expected /browser to be modifier")
assert(completion.is_modifier("/schedule"), "Expected /schedule to be modifier")
assert(completion.is_modifier("/learn"), "Expected /learn to be modifier")
assert(completion.is_modifier("/teamwork-preview"), "Expected /teamwork-preview to be modifier")

-- Verify token 1 completion includes both control commands and modifiers
local token1_comps = completion.get_completions("/", 1)
assert(token1_comps ~= nil, "Expected token 1 completions")
local token1_map = {}
for _, item in ipairs(token1_comps.items) do
	token1_map[item.label] = item
end
assert(token1_map["/add-dir"] ~= nil, "Expected /add-dir at token 1")
assert(token1_map["/model"] ~= nil, "Expected /model at token 1")
assert(token1_map["/context"] ~= nil, "Expected /context at token 1")
assert(token1_map["/settings"] ~= nil, "Expected /settings at token 1")
assert(token1_map["/plan"] ~= nil, "Expected /plan at token 1")
assert(token1_map["/boost"] ~= nil, "Expected /boost at token 1")
print("✓ Command taxonomy and token 1 suggestion verified")

-- [Test 13] Testing local execution of control commands on submit
print("\n[Test 13] Testing local execution of control commands (/mode, /effort, /context, /settings, /doctor)...")
vim.cmd("edit agy://new")
local cbuf = vim.api.nvim_get_current_buf()

-- Test /mode plan
protocol.with_modifiable(cbuf, function()
	vim.api.nvim_buf_set_lines(cbuf, protocol.buffers[cbuf].prompt_start_line - 1, -1, false, { "/mode plan" })
end)
protocol.handle_write(cbuf)
assert(protocol.buffers[cbuf].stream_info.permission_mode == "plan", "Expected mode plan in stream_info")
assert(protocol.buffers[cbuf].session.mode == "plan", "Expected session mode plan")
assert(not vim.bo[cbuf].modified, "Buffer must be unmodified after :w /mode")
assert(protocol.extract_prompt(cbuf) == "", "Prompt must be cleared after executing /mode")

-- Test /effort high
protocol.with_modifiable(cbuf, function()
	vim.api.nvim_buf_set_lines(cbuf, protocol.buffers[cbuf].prompt_start_line - 1, -1, false, { "/effort high" })
end)
protocol.handle_write(cbuf)
assert(protocol.buffers[cbuf].stream_info.effort == "high", "Expected effort high in stream_info")
assert(protocol.buffers[cbuf].session.effort == "high", "Expected session effort high")
assert(not vim.bo[cbuf].modified, "Buffer must be unmodified after :w /effort")
assert(protocol.extract_prompt(cbuf) == "", "Prompt must be cleared after executing /effort")

-- Test /context (should open float and clear prompt without calling stream-json)
protocol.with_modifiable(cbuf, function()
	vim.api.nvim_buf_set_lines(cbuf, protocol.buffers[cbuf].prompt_start_line - 1, -1, false, { "/context" })
end)
protocol.handle_write(cbuf)
assert(not vim.bo[cbuf].modified, "Buffer must be unmodified after :w /context")
assert(protocol.extract_prompt(cbuf) == "", "Prompt must be cleared after executing /context")

-- Test /settings
protocol.with_modifiable(cbuf, function()
	vim.api.nvim_buf_set_lines(cbuf, protocol.buffers[cbuf].prompt_start_line - 1, -1, false, { "/settings" })
end)
protocol.handle_write(cbuf)
assert(not vim.bo[cbuf].modified, "Buffer must be unmodified after :w /settings")
assert(protocol.extract_prompt(cbuf) == "", "Prompt must be cleared after executing /settings")

-- Test /status
protocol.with_modifiable(cbuf, function()
	vim.api.nvim_buf_set_lines(cbuf, protocol.buffers[cbuf].prompt_start_line - 1, -1, false, { "/status" })
end)
protocol.handle_write(cbuf)
assert(not vim.bo[cbuf].modified, "Buffer must be unmodified after :w /status")
assert(protocol.extract_prompt(cbuf) == "", "Prompt must be cleared after executing /status")

-- Test /doctor
protocol.with_modifiable(cbuf, function()
	vim.api.nvim_buf_set_lines(cbuf, protocol.buffers[cbuf].prompt_start_line - 1, -1, false, { "/doctor" })
end)
protocol.handle_write(cbuf)
assert(not vim.bo[cbuf].modified, "Buffer must be unmodified after :w /doctor")
-- Close any floating windows from Test 13
for _, win in ipairs(vim.api.nvim_list_wins()) do
	if vim.api.nvim_win_get_config(win).relative ~= "" then
		pcall(vim.api.nvim_win_close, win, true)
	end
end
pcall(vim.api.nvim_buf_delete, cbuf, { force = true })
print("✓ Local execution of control commands verified without stream-json errors")

-- [Test 14] Testing Enter (<CR>) autocompletes AND processes standalone control commands without :w
print("\n[Test 14] Testing Enter (<CR>) autocompletes AND processes control commands without :w...")
vim.cmd("edit agy://new")
local ebuf = vim.api.nvim_get_current_buf()
local ewin = vim.fn.bufwinid(ebuf)
if ewin == -1 then
	ewin = vim.api.nvim_get_current_win()
end

-- 1. Enter on zero-arg control command from autocomplete popup (e.g. /context)
local comp_ctx = completion.get_completions("/con", 4)
assert(comp_ctx ~= nil, "Expected completions for /con")
completion.show(ewin, ebuf, comp_ctx)
assert(completion.is_visible(), "Float must be visible")

-- Press Enter on /context
completion.accept(true)
assert(not completion.is_visible(), "Completion popup must be closed")
assert(protocol.extract_prompt(ebuf) == "", "Prompt must be cleared after Enter on /context")
assert(not vim.bo[ebuf].modified, "Buffer must not be modified after Enter on /context")

-- Close any floating windows and refocus ewin
for _, win in ipairs(vim.api.nvim_list_wins()) do
	if vim.api.nvim_win_get_config(win).relative ~= "" then
		pcall(vim.api.nvim_win_close, win, true)
	end
end
ewin = vim.fn.bufwinid(ebuf)
if ewin == -1 then
	ewin = vim.api.nvim_get_current_win()
end
vim.api.nvim_set_current_win(ewin)

-- 2. Enter on argument of control command from autocomplete popup (e.g. /mode plan)
protocol.with_modifiable(ebuf, function()
	vim.api.nvim_buf_set_lines(ebuf, protocol.buffers[ebuf].prompt_start_line - 1, -1, false, { "/mode " })
end)
vim.api.nvim_win_set_cursor(ewin, { protocol.buffers[ebuf].prompt_start_line, 6 })
local comp_mode_arg = completion.get_completions("/mode ", 6)
completion.show(ewin, ebuf, comp_mode_arg)
-- Select "plan"
local plan_idx = 1
for idx, it in ipairs(completion.state.items) do
	if it.label == "plan" then
		plan_idx = idx
		break
	end
end
completion.state.selected_idx = plan_idx

-- Press Enter on "plan"
completion.accept(true)
assert(not completion.is_visible(), "Completion popup must be closed")
assert(protocol.buffers[ebuf].stream_info.permission_mode == "plan", "Expected mode 'plan' after Enter")
assert(protocol.buffers[ebuf].session.mode == "plan", "Expected session mode 'plan' after Enter")
assert(protocol.extract_prompt(ebuf) == "", "Prompt must be cleared after Enter on /mode plan")
assert(not vim.bo[ebuf].modified, "Buffer must not be modified")

-- 3. Enter on model argument from autocomplete popup (e.g. /model sonnet)
protocol.with_modifiable(ebuf, function()
	vim.api.nvim_buf_set_lines(ebuf, protocol.buffers[ebuf].prompt_start_line - 1, -1, false, { "/model son" })
end)
vim.api.nvim_win_set_cursor(ewin, { protocol.buffers[ebuf].prompt_start_line, 10 })
local comp_model_arg = completion.get_completions("/model son", 10)
completion.show(ewin, ebuf, comp_model_arg)
assert(completion.state.items[1].label:find("sonnet") ~= nil, "Expected sonnet match")

-- Press Enter on sonnet model
completion.accept(true)
assert(not completion.is_visible(), "Completion popup must be closed")
assert(protocol.buffers[ebuf].stream_info.model == "claude-sonnet-4-6", "Expected claude-sonnet-4-6 model after Enter")
assert(protocol.extract_prompt(ebuf) == "", "Prompt must be cleared after Enter on /model sonnet")
assert(not vim.bo[ebuf].modified, "Buffer must not be modified")

-- 4. Direct <CR> in insert mode on a line containing a standalone control command
protocol.with_modifiable(ebuf, function()
	vim.api.nvim_buf_set_lines(ebuf, protocol.buffers[ebuf].prompt_start_line - 1, -1, false, { "/effort medium" })
end)
vim.api.nvim_set_current_win(ewin)
vim.api.nvim_win_set_cursor(ewin, { protocol.buffers[ebuf].prompt_start_line, 14 })
-- Simulate insert-mode <CR>
vim.api.nvim_feedkeys(vim.keycode("a<CR>"), "tx", false)
vim.wait(100, function()
	return protocol.extract_prompt(ebuf) == ""
end)
assert(protocol.buffers[ebuf].stream_info.effort == "medium", "Expected effort medium after direct Enter")
assert(protocol.extract_prompt(ebuf) == "", "Prompt must be cleared after direct Enter on /effort medium")
assert(not vim.bo[ebuf].modified, "Buffer must not be modified")

-- 5. Multi-line prompt text does NOT process on Enter (splits line normally)
protocol.with_modifiable(ebuf, function()
	vim.api.nvim_buf_set_lines(ebuf, protocol.buffers[ebuf].prompt_start_line - 1, -1, false, { "Hello world" })
end)
vim.api.nvim_set_current_win(ewin)
vim.api.nvim_win_set_cursor(ewin, { protocol.buffers[ebuf].prompt_start_line, 5 })
vim.api.nvim_feedkeys(vim.keycode("a<CR>"), "tx", false)
local prompt_lines = vim.api.nvim_buf_get_lines(ebuf, protocol.buffers[ebuf].prompt_start_line - 1, -1, false)
assert(#prompt_lines == 2, "Multi-line prompt must split line on Enter, got: " .. vim.inspect(prompt_lines))

pcall(vim.api.nvim_buf_delete, ebuf, { force = true })
print("✓ Autocomplete and immediate execution on Enter for control commands verified without :w")

print("\n[Test 15] Testing model switching preserves session liveliness and allows subsequent prompt turns...")
vim.cmd("edit agy://new")
local mbuf = vim.api.nvim_get_current_buf()
local mstate = protocol.buffers[mbuf]
assert(mstate ~= nil, "Buffer state must exist")

vim.wait(10000, function()
	return mstate.session.is_initialized
end, 100)
assert(mstate.session.is_initialized, "Session must be initialized")
local pid_before = mstate.session.proc and mstate.session.proc.pid

-- Switch model
protocol.set_model(mbuf, "gemini-3.8-flash-high")
assert(mstate.stream_info.model == "gemini-3.8-flash-high", "Stream info model must match")
assert(mstate.session.model == "gemini-3.8-flash-high", "Session model must match")

-- Wait for new process init
vim.wait(10000, function()
	return mstate.session.is_initialized
end, 100)
assert(mstate.session.is_active, "Session must remain active after model switch")
assert(mstate.session.is_initialized, "Session must be initialized after model switch")

-- Send prompt and verify turn completes cleanly
protocol.with_modifiable(mbuf, function()
	vim.api.nvim_buf_set_lines(mbuf, mstate.prompt_start_line - 1, -1, false, { "Reply with: MODEL_SWITCH_TEST_OK" })
end)
protocol.handle_write(mbuf)
assert(mstate.session.turn_active, "Turn should be active")

local turn_done = vim.wait(25000, function()
	return not mstate.session.turn_active
end, 200)
assert(turn_done, "Turn should complete without freezing")

local mlines = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
local mtext = table.concat(mlines, "\n")
assert(mtext:find("MODEL_SWITCH_TEST_OK") ~= nil, "Response must contain MODEL_SWITCH_TEST_OK")
protocol.cleanup_buffer(mbuf)
pcall(vim.api.nvim_buf_delete, mbuf, { force = true })
print("✓ Model switching liveliness and prompt execution verified")

print("\n[Test 16] Testing control commands (/model, /add-dir) appear in conversation history...")
vim.cmd("edit agy://new")
local hbuf = vim.api.nvim_get_current_buf()
local hstate = protocol.buffers[hbuf]
assert(hstate ~= nil, "Buffer state must exist")
vim.wait(5000, function()
	return hstate.session.is_initialized
end, 100)

-- Run /model
protocol.with_modifiable(hbuf, function()
	vim.api.nvim_buf_set_lines(hbuf, hstate.prompt_start_line - 1, -1, false, { "/model gemini-3.8-flash-high" })
end)
protocol.handle_write(hbuf)
local lines_after_model = vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)
local text_after_model = table.concat(lines_after_model, "\n")
assert(
	text_after_model:find("/model gemini-3.8-flash-high", 1, true) ~= nil,
	"Buffer history must contain /model command"
)
assert(
	text_after_model:find("⚡ Switched model to gemini-3.8-flash-high", 1, true) ~= nil,
	"Buffer history must contain model switch result"
)
assert(protocol.extract_prompt(hbuf) == "", "Active prompt must be clean and positioned after command history")

-- Run /add-dir
protocol.with_modifiable(hbuf, function()
	vim.api.nvim_buf_set_lines(hbuf, hstate.prompt_start_line - 1, -1, false, { "/add-dir tests" })
end)
protocol.handle_write(hbuf)
local lines_after_dir = vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)
local text_after_dir = table.concat(lines_after_dir, "\n")
assert(text_after_dir:find("/add-dir tests", 1, true) ~= nil, "Buffer history must contain /add-dir command")
assert(text_after_dir:find("✓ Added workspace:", 1, true) ~= nil, "Buffer history must contain add-dir result")
assert(protocol.extract_prompt(hbuf) == "", "Active prompt must be clean after second command")

protocol.cleanup_buffer(hbuf)
pcall(vim.api.nvim_buf_delete, hbuf, { force = true })
print("✓ Control commands in conversation history verified")

-- ============================================================================
-- Test 17: Default Model Discovery & Footer Bar Display
-- ============================================================================
print("\n[Test 17] Testing default model discovery and footer bar display...")

-- 1. Helper resolution tests
assert(completion.resolve_model("gemini-3.8-flash-high") == "gemini-3.8-flash-high", "ID should resolve to itself")
assert(
	completion.resolve_model("Gemini 3.8 Flash (High)") == "gemini-3.8-flash-high",
	"Human name should resolve to ID"
)
assert(
	completion.resolve_model("Claude Sonnet 4.6 (Thinking)") == "claude-sonnet-4-6",
	"Claude human name should resolve to ID"
)

-- 2. User config default override
local cfg_override = completion.get_default_model(nil, "claude-sonnet-4-6")
assert(cfg_override == "claude-sonnet-4-6", "Explicit config default should take precedence")

-- 3. Settings.json discovery
local default_model = completion.get_default_model()
assert(default_model ~= nil and default_model ~= "", "Default model must be discovered from settings.json or fallback")
print("Discovered default model: " .. default_model)

-- 4. New session immediately shows model in footer
vim.cmd("edit agy://new")
local def_buf = vim.api.nvim_get_current_buf()
local def_state = protocol.buffers[def_buf]
assert(def_state ~= nil, "Buffer state must exist")
assert(def_state.stream_info ~= nil, "stream_info must exist")
assert(
	def_state.stream_info.model == default_model,
	"stream_info.model must immediately equal discovered default model"
)
assert(def_state.footer_extmark_id ~= nil, "Footer extmark must be created")

-- Verify footer extmark text contains the model
local extmark_info = vim.api.nvim_buf_get_extmark_by_id(
	def_buf,
	require("agy.render").NS_UI,
	def_state.footer_extmark_id,
	{ details = true }
)
assert(extmark_info and extmark_info[3] and extmark_info[3].virt_lines, "Footer virt_lines must exist")
local footer_str = ""
for _, line in ipairs(extmark_info[3].virt_lines) do
	for _, chunk in ipairs(line) do
		footer_str = footer_str .. chunk[1]
	end
end
assert(footer_str:find(default_model, 1, true) ~= nil, "Footer string must contain default model: " .. footer_str)
print("Footer display: " .. footer_str)

protocol.cleanup_buffer(def_buf)
pcall(vim.api.nvim_buf_delete, def_buf, { force = true })

-- 5. Resumed session extracts model from conversation transcript
local test_helpers = require("tests.test_helpers")
local tmp_dir, test_cid = test_helpers.create_mock_environment()
local conv_model = transcript.get_conversation_model(test_cid, tmp_dir)
assert(conv_model ~= nil, "Transcript model must be extractable from historical steps")
assert(
	completion.resolve_model(conv_model) == "gemini-3.8-flash-high",
	"Extracted model must resolve to gemini-3.8-flash-high"
)

require("agy").setup({ app_data_dir = tmp_dir })
vim.cmd("edit agy://" .. test_cid)
local resume_buf = vim.api.nvim_get_current_buf()
local resume_state = protocol.buffers[resume_buf]
assert(resume_state ~= nil, "Resumed buffer state must exist")
assert(resume_state.stream_info ~= nil, "Resumed stream_info must exist")
assert(
	resume_state.stream_info.model == "gemini-3.8-flash-high",
	"Resumed buffer stream_info.model must match transcript model"
)

local resume_extmark = vim.api.nvim_buf_get_extmark_by_id(
	resume_buf,
	require("agy.render").NS_UI,
	resume_state.footer_extmark_id,
	{ details = true }
)
local resume_footer_str = ""
for _, line in ipairs(resume_extmark[3].virt_lines) do
	for _, chunk in ipairs(line) do
		resume_footer_str = resume_footer_str .. chunk[1]
	end
end
assert(
	resume_footer_str:find("gemini-3.8-flash-high", 1, true) ~= nil,
	"Resumed footer string must contain model: " .. resume_footer_str
)
print("Resumed footer display: " .. resume_footer_str)

protocol.cleanup_buffer(resume_buf)
pcall(vim.api.nvim_buf_delete, resume_buf, { force = true })

print("✓ Default model discovery and immediate footer display verified")

-- ============================================================================
-- Test 18: Autocomplete Window Placement & Full Description Rendering
-- ============================================================================
print("\n[Test 18] Testing autocomplete window placement and full description rendering...")
vim.cmd("edit agy://new")
local vbuf = vim.api.nvim_get_current_buf()
local vwin = vim.api.nvim_get_current_win()
local vstate = protocol.buffers[vbuf]
assert(vstate ~= nil, "Buffer state must exist")

vim.o.columns = 120
local win_w = vim.api.nvim_win_get_width(vwin)

-- Type /boost on prompt line
local p_line = vstate.prompt_start_line
vim.api.nvim_win_set_cursor(vwin, { p_line, 0 })
protocol.with_modifiable(vbuf, function()
	vim.api.nvim_buf_set_lines(vbuf, p_line - 1, p_line, false, { "/boost" })
end)
vim.api.nvim_win_set_cursor(vwin, { p_line, 6 })

local comp_boost = completion.get_completions("/boost", 6)
assert(comp_boost ~= nil and #comp_boost.items > 0, "Completions for /boost must exist")

completion.show(vwin, vbuf, comp_boost)
assert(completion.is_visible(), "Completion popup must be visible")

local cwin = completion.state.win
local ccfg = vim.api.nvim_win_get_config(cwin)
local winline = vim.fn.winline()

-- Verify row is placed below prompt bottom border (winline + 1), not overlapping
assert(
	ccfg.row >= winline + 1,
	"Floating window row ("
		.. ccfg.row
		.. ") must be below prompt bottom border (winline + 1 = "
		.. (winline + 1)
		.. ")"
)

-- Verify width matches window width (120) rather than being capped at 85
assert(ccfg.width == win_w, "Floating window width (" .. ccfg.width .. ") must match window width (" .. win_w .. ")")

-- Verify rendered line in completion buffer contains full description without truncation
local cbuf = completion.state.buf
local clines = vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)
assert(#clines >= 1, "Completion buffer must have lines")
local boost_line = clines[1]
print("Rendered /boost completion line: '" .. boost_line .. "'")
assert(
	boost_line:find("Deep thinking, strategic planning, and verification", 1, true) ~= nil,
	"Description must NOT be cut off! Found: " .. boost_line
)

completion.close()
assert(not completion.is_visible(), "Completion popup should be closed")
protocol.cleanup_buffer(vbuf)
pcall(vim.api.nvim_buf_delete, vbuf, { force = true })
print("✓ Window placement below bottom border and full description rendering verified")

-- ============================================================================
-- Test 19: KNOWN_MODELS Removal & Failure Error Raising
-- ============================================================================
print("\n[Test 19] Testing KNOWN_MODELS removal and failure error raising...")
-- 1. Ensure KNOWN_MODELS table no longer exists on module
assert(completion.KNOWN_MODELS == nil, "M.KNOWN_MODELS must be nil and completely removed")

-- 2. Ensure fetching fails with error when CLI fails and cache is empty
local saved_cached = completion._cached_models
local orig_system = vim.system
local function cleanup_mocks()
	vim.system = orig_system
	completion._cached_models = saved_cached
end

local ok, test_err = pcall(function()
	completion._cached_models = nil
	vim.system = function(cmd, opts, on_exit)
		if on_exit then
			on_exit({ code = 1, stdout = "", stderr = "CLI error: failed to fetch models" })
			return {}
		else
			return {
				wait = function()
					return { code = 1, stdout = "", stderr = "CLI error: failed to fetch models" }
				end,
			}
		end
	end

	local fetch_ok, fetch_res = pcall(completion.fetch_models)
	assert(not fetch_ok, "fetch_models must raise an error when CLI fails")
	assert(tostring(fetch_res):find("failed"), "Error message should report CLI failure")

	local avail_ok, avail_res = pcall(completion.get_available_models)
	assert(not avail_ok, "get_available_models must raise an error when CLI fails and cache is empty")

	-- Dummy non-existent directory so settings.json doesn't provide a model
	local dummy_dir = vim.fn.tempname()
	local def_ok, def_res = pcall(completion.get_default_model, dummy_dir)
	assert(not def_ok, "get_default_model must raise an error instead of falling back when no models are available")
end)

cleanup_mocks()
if not ok then
	error(test_err)
end
print("✓ KNOWN_MODELS removal and error raising verified")

-- ============================================================================
-- Test 20: @ File Mentions Candidate Filtering & Fuzzy Search
-- ============================================================================
print("\n[Test 20] Testing @ file mentions candidate filtering & fuzzy search...")
local cwd = vim.fn.getcwd()
local comp_at_empty = completion.complete_files("", { cwd })
assert(#comp_at_empty > 0, "Expected workspace files on empty query")
assert(comp_at_empty[1].kind == "File", "Expected kind == File")

local comp_at_init = completion.complete_files("init", { cwd })
assert(#comp_at_init > 0, "Expected matches for 'init'")
assert(comp_at_init[1].label:find("init%.lua$") ~= nil, "Top result must be init.lua: " .. comp_at_init[1].label)

local comp_at_fuzzy = completion.complete_files("cpl", { cwd })
assert(#comp_at_fuzzy > 0, "Expected fuzzy matches for 'cpl'")
local found_cpl = false
for _, it in ipairs(comp_at_fuzzy) do
	if it.label:find("completion%.lua$") then
		found_cpl = true
		break
	end
end
assert(found_cpl, "Expected completion.lua in fuzzy matches for 'cpl'")

-- Test Windows backslash query
local comp_at_bs = completion.complete_files("lua\\agy\\in", { cwd })
assert(#comp_at_bs > 0, "Expected matches for backslash query")
assert(comp_at_bs[1].label:find("lua\\agy\\init%.lua") ~= nil, "Expected backslash formatted label: " .. comp_at_bs[1].label)
assert(comp_at_bs[1].insert_text:find("^@lua\\agy\\init%.lua") ~= nil, "Expected backslash insert_text: " .. comp_at_bs[1].insert_text)

-- Test bracketed query
local comp_at_brk = completion.complete_files("init", { cwd }, true)
assert(#comp_at_brk > 0, "Expected bracketed matches")
assert(comp_at_brk[1].insert_text:find("^@%[") ~= nil, "Expected @[ format for bracketed mode: " .. comp_at_brk[1].insert_text)
print("✓ @ file mentions candidate filtering & fuzzy search verified")

-- ============================================================================
-- Test 21: get_completions @ Trigger Detection Anywhere on Line
-- ============================================================================
print("\n[Test 21] Testing get_completions @ trigger detection anywhere on line...")
-- Start of line
local c_start = completion.get_completions("@", 1, nil, { cwd })
assert(c_start ~= nil and (c_start.type == "mention" or c_start.type == "file"), "Expected mention completions for @ at start")
assert(#c_start.items > 0, "Expected mention items")

local c_start_init = completion.get_completions("@init", 5, nil, { cwd })
assert(c_start_init ~= nil and (c_start_init.type == "mention" or c_start_init.type == "file"), "Expected completions for @init")
local has_init = false
for _, it in ipairs(c_start_init.items) do
	if it.label:find("init%.lua$") then
		has_init = true
		break
	end
end
assert(has_init, "Expected init.lua in completions")

-- Inside prompt text
local c_inside = completion.get_completions("Please inspect @lua/agy/init", 28, nil, { cwd })
assert(c_inside ~= nil and (c_inside.type == "mention" or c_inside.type == "file"), "Expected mention completions inside text")
assert(c_inside.replace_start_col == 15, "Expected replace_start_col == 15, got " .. tostring(c_inside.replace_start_col))

-- Bracketed inside prompt
local c_bracket = completion.get_completions("Check @[lua/agy/in", 18, nil, { cwd })
assert(c_bracket ~= nil and (c_bracket.type == "mention" or c_bracket.type == "file") and c_bracket.has_bracket == true, "Expected bracketed file completion")

-- After modifier slash command
local c_mod = completion.get_completions("/plan check @init", 17, nil, { cwd })
assert(c_mod ~= nil and (c_mod.type == "mention" or c_mod.type == "file"), "Expected completions after slash command")

-- False positive check: email addresses must NOT trigger file completion
local c_email = completion.get_completions("contact me at user@example.com", 30, nil, { cwd })
assert(c_email == nil, "Email address must NOT trigger file completion")

print("✓ @ trigger detection anywhere on line verified")

-- ============================================================================
-- Test 22: Accepting @ File Completions with Tab and Enter
-- ============================================================================
print("\n[Test 22] Testing accepting @ file completions...")
local file_test_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_set_current_buf(file_test_buf)
vim.api.nvim_buf_set_lines(file_test_buf, 0, -1, false, {
	"Inspect @init and fix it",
})
local file_test_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(file_test_win, { 1, 13 })

local comp_to_accept = completion.get_completions("Inspect @init and fix it", 13, nil, { cwd })
assert(comp_to_accept ~= nil and (comp_to_accept.type == "mention" or comp_to_accept.type == "file"), "Expected completions")

completion.show(file_test_win, file_test_buf, comp_to_accept)
assert(completion.is_visible(), "Popup must be visible")

-- Tab completes
completion.accept(false)
assert(not completion.is_visible(), "Popup should close after accepting file completion")
local accepted_line = vim.api.nvim_get_current_line()
print("Line after accepting file completion: '" .. accepted_line .. "'")
assert(accepted_line:find("Inspect @.-init%.lua  and fix it") or accepted_line:find("Inspect @.-init%.lua and fix it"), "Expected @<path> inserted: " .. accepted_line)

-- Test Enter on @ completion does NOT submit prompt
vim.api.nvim_buf_set_lines(file_test_buf, 0, -1, false, {
	"Check @lua",
})
vim.api.nvim_win_set_cursor(file_test_win, { 1, 10 })
local comp_enter = completion.get_completions("Check @lua", 10, nil, { cwd })
completion.show(file_test_win, file_test_buf, comp_enter)
assert(completion.is_visible(), "Popup must be visible")
local handled = completion.accept(true)
assert(handled, "Accept should be handled")
assert(not completion.is_visible(), "Popup must be closed")
local enter_line = vim.api.nvim_get_current_line()
print("Line after Enter on file completion: '" .. enter_line .. "'")
assert(enter_line:find("Check @lua"), "Line must contain completed @ file mention")

completion.close()
pcall(vim.api.nvim_buf_delete, file_test_buf, { force = true })
print("✓ Accepting @ file completions verified")

-- ============================================================================
-- Test 23: Protocol resolve_prompt_mentions Resolves Files to Metadata
-- ============================================================================
print("\n[Test 23] Testing protocol.resolve_prompt_mentions...")
local raw_prompt = "Can you look at @lua/agy/init.lua and describe what it does?"
local resolved = protocol.resolve_prompt_mentions(raw_prompt, { cwd })
assert(resolved ~= raw_prompt, "Resolved prompt must contain metadata")
assert(resolved:find("<ADDITIONAL_METADATA>", 1, true) ~= nil, "Expected <ADDITIONAL_METADATA> tag")
assert(resolved:find("@[lua/agy/init.lua] is a [File]:", 1, true) ~= nil, "Expected @[lua/agy/init.lua] is a [File]:")
assert(resolved:find("init%.lua") ~= nil, "Expected absolute path to init.lua in metadata")
assert(resolved:find("</ADDITIONAL_METADATA>", 1, true) ~= nil, "Expected closing </ADDITIONAL_METADATA>")

-- Test backslash mention: @lua\agy\init.lua
local raw_bs = "Check @lua\\agy\\init.lua please"
local resolved_bs = protocol.resolve_prompt_mentions(raw_bs, { cwd })
assert(resolved_bs:find("<ADDITIONAL_METADATA>", 1, true) ~= nil, "Expected metadata for backslash mention")
assert(resolved_bs:find("@%[lua\\agy\\init%.lua%] is a %[File%]:") ~= nil, "Expected @[lua\\agy\\init.lua] in metadata")
assert(resolved_bs:find("@%[lua/agy/init%.lua%] is a %[File%]:") ~= nil, "Expected normalized forward-slash alias in metadata")

-- Test bracketed mention: @[lua/agy/init.lua]
local raw_bracket = "Refactor @[lua/agy/init.lua]"
local resolved_bracket = protocol.resolve_prompt_mentions(raw_bracket, { cwd })
assert(resolved_bracket:find("@[lua/agy/init.lua] is a [File]:", 1, true) ~= nil, "Expected bracketed mention resolution")

-- Test non-existent mention does NOT add metadata
local raw_none = "Send message to @user_not_a_file"
local resolved_none = protocol.resolve_prompt_mentions(raw_none, { cwd })
assert(resolved_none == raw_none, "Non-file mention must not add file metadata")
print("✓ protocol.resolve_prompt_mentions metadata resolution verified")

-- ============================================================================
-- Test 24: AgyMention Syntax Highlighting in Setup Buffer
-- ============================================================================
print("\n[Test 24] Testing AgyMention syntax highlighting in setup_buffer...")
local syn_buf = vim.api.nvim_create_buf(false, false)
completion.setup_buffer(syn_buf)
local hl_mention = vim.api.nvim_get_hl(0, { name = "AgyMention" })
assert(not vim.tbl_isempty(hl_mention), "AgyMention highlight group must exist")
pcall(vim.api.nvim_buf_delete, syn_buf, { force = true })
print("✓ AgyMention syntax highlighting verified")

-- ============================================================================
-- Test 25: Built-in @diagnostics Mention Provider
-- ============================================================================
print("\n[Test 25] Testing @diagnostics mention provider...")
local mention_mod = require("agy.mention")
local diag_ns = vim.api.nvim_create_namespace("agy_test_diags")
local diag_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(diag_buf, cwd .. "/lua/agy/test_dummy.lua")
vim.api.nvim_buf_set_lines(diag_buf, 0, -1, false, { "local x = 1" })

vim.diagnostic.set(diag_ns, diag_buf, {
	{
		lnum = 0,
		col = 6,
		severity = vim.diagnostic.severity.ERROR,
		message = "Variable x is unused",
		source = "lua_ls",
	},
	{
		lnum = 0,
		col = 0,
		severity = vim.diagnostic.severity.WARN,
		message = "Missing type annotation",
		source = "luacheck",
	},
})

local comp_diag = completion.get_completions("@diag", 5, nil, { cwd })
assert(comp_diag ~= nil and #comp_diag.items > 0, "Expected matches for @diag")
local found_diag = false
for _, it in ipairs(comp_diag.items) do
	if it.label == "diagnostics" then
		found_diag = true
		assert(it.kind == "Diagnostics", "Expected kind == Diagnostics")
		assert(it.detail:find("1 error"), "Expected error count in detail: " .. it.detail)
		break
	end
end
assert(found_diag, "Expected 'diagnostics' in completions for @diag")

-- Test resolution of @diagnostics in prompt
local diag_prompt = "Can you fix the @diagnostics in this file?"
local resolved_diag = protocol.resolve_prompt_mentions(diag_prompt, { cwd })
assert(resolved_diag:find("<ADDITIONAL_METADATA>", 1, true) ~= nil, "Expected metadata tag for diagnostics")
assert(resolved_diag:find("@[diagnostics] is a [Diagnostics]:", 1, true) ~= nil, "Expected @[diagnostics] header")
assert(resolved_diag:find("Variable x is unused", 1, true) ~= nil, "Expected diagnostic error message in metadata")
assert(resolved_diag:find("Missing type annotation", 1, true) ~= nil, "Expected diagnostic warning message in metadata")

vim.diagnostic.reset(diag_ns, diag_buf)
pcall(vim.api.nvim_buf_delete, diag_buf, { force = true })
print("✓ Built-in @diagnostics completion and metadata resolution verified")

-- ============================================================================
-- Test 26: Built-in @buffers and Modified In-Memory Lines Resolution
-- ============================================================================
print("\n[Test 26] Testing @buffers and in-memory lines resolution...")
local mod_buf = vim.api.nvim_create_buf(false, false)
local mod_file_name = cwd .. "/lua/agy/test_in_memory.lua"
vim.api.nvim_buf_set_name(mod_buf, mod_file_name)
vim.bo[mod_buf].buftype = ""
vim.bo[mod_buf].filetype = "lua"
vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, {
	"-- LIVE IN-MEMORY CONTENT NOT SAVED TO DISK",
	"function test_unsaved_live()",
	"  return 42",
	"end",
})
vim.bo[mod_buf].modified = true

-- Verify completion lists open buffer with [+] tag
local comp_buf = completion.get_completions("@test_in_memory", 15, nil, { cwd })
assert(comp_buf ~= nil and #comp_buf.items > 0, "Expected completion for open buffer")
local found_buf_item = false
for _, it in ipairs(comp_buf.items) do
	if it.label:find("test_in_memory.lua", 1, true) and it.label:find("[+]", 1, true) then
		found_buf_item = true
		assert(it.kind == "Buffer", "Expected kind == Buffer for open buffer")
		break
	end
end
assert(found_buf_item, "Expected open modified buffer with [+] tag in completions")

-- Verify resolution includes live in-memory lines
local mod_prompt = "Look at @lua/agy/test_in_memory.lua please"
local resolved_mod = protocol.resolve_prompt_mentions(mod_prompt, { cwd })
assert(resolved_mod:find("<ADDITIONAL_METADATA>", 1, true) ~= nil, "Expected metadata for modified buffer")
assert(resolved_mod:find("Modified in-memory (unsaved)", 1, true) ~= nil, "Expected modified in-memory status in metadata")
assert(resolved_mod:find("test_unsaved_live", 1, true) ~= nil, "Expected live unsaved code content in metadata")

pcall(vim.api.nvim_buf_delete, mod_buf, { force = true })
print("✓ Built-in @buffers completion and in-memory live lines resolution verified")

-- ============================================================================
-- Test 27: Public API for Custom Mention Providers (register_mention)
-- ============================================================================
print("\n[Test 27] Testing public API for custom mention providers...")
local agy = require("agy")
assert(type(agy.register_mention) == "function", "agy.register_mention must be a function")
assert(type(agy.unregister_mention) == "function", "agy.unregister_mention must be a function")
assert(type(agy.get_mentions) == "function", "agy.get_mentions must be a function")

-- Register custom provider
local custom_provider = {
	name = "custom-git",
	description = "Custom git diff provider",
	priority = 99,
	complete = function(query, ctx)
		if query == "" or ("git-diff"):find(query:lower(), 1, true) then
			return {
				{
					label = "git-diff",
					kind = "Git",
					detail = "Current working tree diff",
					insert_text = "@git-diff ",
				},
			}
		end
		return {}
	end,
	resolve = function(raw, ctx)
		if raw == "git-diff" then
			return {
				raw = "git-diff",
				kind = "Git Diff",
				content = "+ Added feature X\n- Removed bug Y",
			}
		end
	end,
}

agy.register_mention(custom_provider)

-- Verify completion includes custom provider item
local comp_custom = completion.get_completions("@git", 4, nil, { cwd })
assert(comp_custom ~= nil and #comp_custom.items > 0, "Expected completions for @git")
local found_custom = false
for _, it in ipairs(comp_custom.items) do
	if it.label == "git-diff" then
		found_custom = true
		assert(it.kind == "Git", "Expected kind == Git")
		break
	end
end
assert(found_custom, "Expected custom provider 'git-diff' in completions")

-- Verify prompt resolution with custom provider
local custom_prompt = "Explain this diff: @git-diff"
local resolved_custom = protocol.resolve_prompt_mentions(custom_prompt, { cwd })
assert(resolved_custom:find("<ADDITIONAL_METADATA>", 1, true) ~= nil, "Expected metadata for custom provider")
assert(resolved_custom:find("@[git-diff] is a [Git Diff]:", 1, true) ~= nil, "Expected @[git-diff] in metadata")
assert(resolved_custom:find("+ Added feature X", 1, true) ~= nil, "Expected custom content in metadata")

-- Unregister custom provider
agy.unregister_mention("custom-git")
local comp_after_unreg = completion.get_completions("@git-diff", 9, nil, { cwd })
local still_has = false
if comp_after_unreg and comp_after_unreg.items then
	for _, it in ipairs(comp_after_unreg.items) do
		if it.label == "git-diff" then
			still_has = true
			break
		end
	end
end
assert(not still_has, "Custom provider must no longer appear after unregister")
print("✓ Public API for custom mention providers verified")

print("\nALL NATIVE AUTOCOMPLETE TESTS PASSED SUCCESSFULLY!")
