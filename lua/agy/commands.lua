local config_mod = require("agy.config")
local completion = require("agy.completion")
local render = require("agy.render")
local transcript_mod = require("agy.transcript")
local utils = require("agy.utils")

local M = {}

local function cmd_new(ctx)
	ctx.clear_prompt()
	require("agy").new()
end

local function cmd_exit(ctx)
	completion.close()
	pcall(vim.api.nvim_buf_delete, ctx.buf, { force = true })
end

local function cmd_quota(ctx)
	ctx.clear_prompt()
	require("agy.quota").open(ctx.buf)
end

local function add_workspace_dir(ctx, cmd_prefix, dir)
	dir = dir:gsub('^["\']', ""):gsub('["\']$', "")
	local full_dir = vim.fs.normalize(vim.fn.expand(dir))
	ctx.state.session:add_workspace(full_dir)
	ctx.state.workspaces = ctx.state.session.workspaces
	pcall(function()
		completion.refresh_workspace_files_async(full_dir)
	end)
	ctx.state.session:start()
	ctx.protocol.record_command_history(ctx.buf, cmd_prefix .. " " .. dir, ctx.add_prefix .. "Added workspace: " .. full_dir)
	vim.notify("[agy.nvim] Added workspace: " .. full_dir, vim.log.levels.INFO)
end

M.handlers = {
	["/model"] = function(ctx)
		local model_arg = ctx.trimmed:match("^/model%s+(%S+)")
		if not model_arg or model_arg == "" then
			ctx.clear_prompt()
			require("agy.picker").model(ctx.buf)
			return
		end
		local resolved_model = completion.resolve_model(model_arg)
		ctx.protocol.set_model(ctx.buf, resolved_model, false)
		ctx.protocol.record_command_history(
			ctx.buf,
			"/model " .. resolved_model,
			ctx.sw_prefix .. "Switched model to " .. resolved_model
		)
	end,

	["/mode"] = function(ctx)
		local mode_arg = ctx.trimmed:match("^/mode%s+(%S+)")
		if not mode_arg or mode_arg == "" then
			local cur = (ctx.state.session and ctx.state.session.mode) or "default"
			ctx.protocol.record_command_history(ctx.buf, "/mode", "Current agent mode: " .. cur)
			vim.notify("[agy.nvim] Current agent mode: " .. cur, vim.log.levels.INFO)
			return
		end
		if mode_arg ~= "accept-edits" and mode_arg ~= "plan" and mode_arg ~= "default" then
			ctx.clear_prompt()
			vim.notify(
				"[agy.nvim] Invalid agent mode '" .. mode_arg .. "'. Valid modes: accept-edits, plan, default",
				vim.log.levels.WARN
			)
			return
		end
		ctx.protocol.set_mode(ctx.buf, mode_arg)
		ctx.protocol.record_command_history(ctx.buf, "/mode " .. mode_arg, ctx.sw_prefix .. "Switched agent mode to " .. mode_arg)
	end,

	["/fast"] = function(ctx)
		ctx.protocol.set_mode(ctx.buf, "accept-edits")
		ctx.protocol.record_command_history(ctx.buf, "/fast", ctx.sw_prefix .. "Switched agent mode to accept-edits")
	end,

	["/planning"] = function(ctx)
		ctx.protocol.set_mode(ctx.buf, "plan")
		ctx.protocol.record_command_history(ctx.buf, "/planning", ctx.sw_prefix .. "Switched agent mode to plan")
	end,

	["/effort"] = function(ctx)
		local effort_arg = ctx.trimmed:match("^/effort%s+(%S+)")
		if not effort_arg or effort_arg == "" then
			local cur = (ctx.state.session and ctx.state.session.effort) or "default"
			ctx.protocol.record_command_history(ctx.buf, "/effort", "Current reasoning effort: " .. cur)
			vim.notify("[agy.nvim] Current reasoning effort: " .. cur, vim.log.levels.INFO)
			return
		end
		ctx.protocol.set_effort(ctx.buf, effort_arg)
		ctx.protocol.record_command_history(
			ctx.buf,
			"/effort " .. effort_arg,
			ctx.sw_prefix .. "Switched reasoning effort to " .. effort_arg
		)
	end,

	["/add-dir"] = function(ctx)
		local dir = ctx.trimmed:match("^/add%-dir%s+(.+)$")
		if not dir or dir:match("^%s*$") then
			vim.notify("[agy.nvim] Usage: /add-dir <directory>", vim.log.levels.WARN)
			return
		end
		add_workspace_dir(ctx, "/add-dir", dir)
	end,

	["/drop"] = function(ctx)
		local dir = ctx.trimmed:match("^/drop%s+(.+)$")
		if not dir or dir:match("^%s*$") then
			vim.notify("[agy.nvim] Usage: /drop <directory>", vim.log.levels.WARN)
			return
		end
		dir = dir:gsub('^["\']', ""):gsub('["\']$', "")
		local full_dir = vim.fs.normalize(vim.fn.expand(dir))
		local new_ws = {}
		for _, w in ipairs(ctx.state.session.workspaces or {}) do
			if vim.fs.normalize(w) ~= full_dir then
				table.insert(new_ws, w)
			end
		end
		ctx.state.session.workspaces = new_ws
		ctx.state.workspaces = new_ws
		ctx.state.session:start()
		ctx.protocol.record_command_history(ctx.buf, "/drop " .. dir, ctx.add_prefix .. "Dropped workspace: " .. full_dir)
		vim.notify("[agy.nvim] Dropped workspace: " .. full_dir, vim.log.levels.INFO)
	end,

	["/workspace"] = function(ctx)
		local dir = ctx.trimmed:match("^/workspace%s+(.+)$")
		if dir and not dir:match("^%s*$") then
			add_workspace_dir(ctx, "/workspace", dir)
		else
			local ws_list = ctx.state.session.workspaces or {}
			local msg = #ws_list > 0 and table.concat(ws_list, ", ") or "None"
			ctx.protocol.record_command_history(ctx.buf, "/workspace", "Active workspaces: " .. msg)
			vim.notify("[agy.nvim] Active workspaces: " .. msg, vim.log.levels.INFO)
		end
	end,

	["/copy"] = function(ctx)
		local copy_arg = ctx.trimmed:match("^/copy%s+(%S+)")
		ctx.clear_prompt()
		if copy_arg and copy_arg ~= "response" and copy_arg ~= "code" and copy_arg ~= "btw" then
			vim.notify(
				"[agy.nvim] Invalid /copy argument '" .. copy_arg .. "'. Valid choices: response, code, btw",
				vim.log.levels.WARN
			)
			return
		end
		local last_resp = ctx.state.last_agent_response
		if (not last_resp or last_resp == "") and ctx.state.conversation_id and ctx.state.conversation_id ~= "new" then
			local steps = transcript_mod.read_transcript(ctx.state.conversation_id, ctx.cfg.app_data_dir)
			for i = #steps, 1, -1 do
				local s = steps[i]
				if s.type == "PLANNER_RESPONSE" and s.content and s.content ~= "" then
					last_resp = s.content
					break
				end
			end
		end
		if not last_resp or last_resp == "" then
			vim.notify("[agy.nvim] No assistant response available to copy.", vim.log.levels.WARN)
			return
		end
		local text_to_copy = last_resp
		if copy_arg == "code" then
			local blocks = {}
			for block in last_resp:gmatch("```[^\r\n]*\r?\n(.-)\r?\n```") do
				table.insert(blocks, block)
			end
			if #blocks == 0 then
				vim.notify("[agy.nvim] No code blocks found in last assistant response.", vim.log.levels.WARN)
				return
			end
			text_to_copy = table.concat(blocks, "\n\n")
		end
		pcall(vim.fn.setreg, '"', text_to_copy)
		pcall(vim.fn.setreg, "+", text_to_copy)
		pcall(vim.fn.setreg, "*", text_to_copy)
		vim.notify("[agy.nvim] Copied last assistant response to clipboard.", vim.log.levels.INFO)
	end,

	["/open"] = function(ctx)
		local file_arg = ctx.trimmed:match("^/open%s+(.+)$")
		if not file_arg or file_arg:match("^%s*$") then
			vim.notify("[agy.nvim] Usage: /open <path>", vim.log.levels.WARN)
			return
		end
		file_arg = utils.trim(file_arg):gsub('^["\']', ""):gsub('["\']$', "")
		ctx.clear_prompt()
		local resolved = vim.fn.expand(file_arg)
		if vim.fn.filereadable(resolved) == 0 then
			local ws_list = (ctx.state.session and ctx.state.session.workspaces and #ctx.state.session.workspaces > 0)
					and ctx.state.session.workspaces
				or (ctx.state.workspaces or { (ctx.state.session and ctx.state.session.cwd) or vim.fn.getcwd() })
			for _, ws in ipairs(ws_list) do
				local candidate = vim.fs.normalize(ws .. "/" .. file_arg)
				if vim.fn.filereadable(candidate) == 1 then
					resolved = candidate
					break
				end
			end
		end
		vim.cmd("edit " .. vim.fn.fnameescape(resolved))
	end,

	["/clear"] = cmd_new,
	["/new"] = cmd_new,

	["/resume"] = function(ctx)
		local cid = ctx.trimmed:match("^/resume%s*(%S*)")
		ctx.clear_prompt()
		if cid and cid ~= "" then
			require("agy").open(cid)
		else
			require("agy.picker").resume()
		end
	end,

	["/diff"] = function(ctx)
		ctx.clear_prompt()
		require("agy").diff()
	end,

	["/undo"] = function(ctx)
		local state = ctx.state
		local buf = ctx.buf
		local snap = (state.turn_snapshots and #state.turn_snapshots > 0) and table.remove(state.turn_snapshots) or nil
		local restored = (snap and snap.prompt_text) or state.last_sent_prompt
		if restored and restored ~= "" then
			if state.session and state.session.turn_active then
				pcall(function()
					state.session:stop()
				end)
			end
			render.stop_thinking_animation(buf)
			local target_prompt_line = (snap and snap.prompt_start_line) or state.prompt_start_line or 1
			if snap then
				if state.tool_calls and snap.tool_calls_count then
					for i = #state.tool_calls, snap.tool_calls_count + 1, -1 do
						local tc = state.tool_calls[i]
						if tc and tc.is_open then
							pcall(render.close_tool_window, state, tc)
						end
						state.tool_calls[i] = nil
					end
				end
				if state.work_groups and snap.work_groups_count then
					for i = #state.work_groups, snap.work_groups_count + 1, -1 do
						state.work_groups[i] = nil
					end
				end
				state.last_agent_response = snap.last_agent_response or ""
			end
			state.last_sent_prompt = (state.turn_snapshots and #state.turn_snapshots > 0)
					and state.turn_snapshots[#state.turn_snapshots].prompt_text
				or nil
			state.agent_extmark_id = nil
			state.agent_line = nil
			if state.stream_info then
				state.stream_info.status = "ready"
			end
			ctx.protocol.reset_turn_work_state(state)

			local p_lines = utils.split_lines(restored)
			pcall(vim.cmd, "stopinsert")
			ctx.protocol.with_modifiable(buf, function()
				local start_row = math.max(0, target_prompt_line - 1)
				vim.api.nvim_buf_clear_namespace(buf, render.NS_UI, start_row, -1)
				vim.api.nvim_buf_clear_namespace(buf, render.NS_HISTORY, start_row, -1)
				vim.api.nvim_buf_clear_namespace(buf, render.NS_PROMPT, 0, -1)
				pcall(function()
					local md = require("agy.markdown")
					vim.api.nvim_buf_clear_namespace(buf, md.NS_MARKDOWN, start_row, -1)
				end)
				vim.api.nvim_buf_set_lines(buf, start_row, -1, false, p_lines)
				state.prompt_start_line = target_prompt_line
				state.prompt_extmark_id = render.set_divider(buf, start_row, "user", nil, nil, true, nil, state.config)
				render.apply_history_highlights(buf, target_prompt_line, state.config)
				render.apply_prompt_highlights(buf, target_prompt_line, state.config)
			end)
			vim.bo[buf].modified = false
			completion.close()
			local win = vim.fn.bufwinid(buf)
			if win ~= -1 and vim.api.nvim_win_is_valid(win) then
				pcall(vim.api.nvim_win_set_cursor, win, { state.prompt_start_line, 0 })
			end
			ctx.protocol.update_modifiable(buf)
			ctx.protocol.update_footer(buf)
			vim.notify("[agy.nvim] Reverted last turn and restored prompt to input.", vim.log.levels.INFO)
		else
			ctx.clear_prompt()
			vim.cmd("silent! undo")
			vim.notify("[agy.nvim] Undo executed.", vim.log.levels.INFO)
		end
	end,

	["/redo"] = function(ctx)
		ctx.clear_prompt()
		vim.cmd("silent! redo")
		vim.notify("[agy.nvim] Redo executed.", vim.log.levels.INFO)
	end,

	["/exit"] = cmd_exit,
	["/quit"] = cmd_exit,

	["/context"] = function(ctx)
		ctx.clear_prompt()
		require("agy.context").open(ctx.buf)
	end,

	["/settings"] = function(ctx)
		local cfg = ctx.cfg
		local cur_model = (ctx.state.stream_info and ctx.state.stream_info.model)
			or completion.get_default_model(cfg.app_data_dir, cfg.default_model)
		local lines = {
			"# Antigravity Configuration",
			"",
			"- **CLI Command**: `" .. (cfg.agy_cmd or "agy") .. "`",
			"- **App Data Directory**: `" .. (cfg.app_data_dir or "") .. "`",
			"- **Active Model**: `" .. cur_model .. "`",
			"",
			"### UI Settings:",
			"- **Wrap**: " .. tostring(cfg.ui and cfg.ui.wrap),
			"- **Linebreak**: " .. tostring(cfg.ui and cfg.ui.linebreak),
			"- **Conceallevel**: " .. tostring(cfg.ui and cfg.ui.conceallevel),
			"- **Show Thoughts**: " .. tostring(cfg.ui and cfg.ui.show_thoughts),
			"- **Prompt Footer**: " .. tostring(cfg.ui and cfg.ui.prompt_footer),
			"",
			"### Keymaps:",
			"- **Submit**: `" .. (cfg.keymaps and cfg.keymaps.submit or "<C-s>") .. "`",
			"- **Stop**: `" .. (cfg.keymaps and cfg.keymaps.stop or "<C-c>") .. "`",
			"- **Toggle Tool / Option**: `" .. (cfg.keymaps and cfg.keymaps.toggle_tool or "<CR>") .. "`",
		}
		ctx.clear_prompt()
		ctx.protocol.show_info_float("Antigravity Settings", lines, ctx.buf)
	end,

	["/status"] = function(ctx)
		local state = ctx.state
		local info = state.stream_info or {}
		local lines = {
			"# Antigravity Session Status",
			"",
			"- **Conversation**: `" .. (state.conversation_id or "new") .. "`",
			"- **Process**: " .. ((state.session and state.session.is_active) and "Running (Active)" or "Idle / Standby"),
			"- **Turn In-Flight**: " .. tostring(state.session and state.session.turn_active),
			"- **Active Model**: `" .. (info.model or "default") .. "`",
			"- **Stream Status**: " .. (info.status or "ready"),
			"- **Active Workspaces**: " .. #(state.session and state.session.workspaces or {}),
		}
		ctx.clear_prompt()
		ctx.protocol.show_info_float("Antigravity Status", lines, ctx.buf)
	end,

	["/usage"] = cmd_quota,
	["/quota"] = cmd_quota,
	["/tokens"] = cmd_quota,
	["/cost"] = cmd_quota,

	["/doctor"] = function(ctx)
		ctx.clear_prompt()
		local async = require("agy.async")
		local cfg = ctx.cfg
		local buf = ctx.buf
		local protocol = ctx.protocol
		async.run(function()
			local lines = {
				"# Antigravity Doctor Health Check",
				"",
			}
			local cmd_name = cfg.agy_cmd or "agy"
			local agy_exe = vim.fn.exepath(cmd_name)
			if agy_exe ~= "" then
				table.insert(lines, "[✓] `" .. cmd_name .. "` CLI found: `" .. agy_exe .. "`")
				local ok, ver = async.psystem({ cmd_name, "--version" }, { text = true })
				if ok and ver and ver.code == 0 then
					table.insert(lines, "[✓] `" .. cmd_name .. "` CLI version: " .. utils.trim(ver.stdout))
				end
			else
				table.insert(lines, "[✗] `" .. cmd_name .. "` executable NOT found on PATH!")
			end
			local nvim_ver = vim.version()
			table.insert(lines, string.format("[✓] Neovim version: %d.%d.%d", nvim_ver.major, nvim_ver.minor, nvim_ver.patch))
			table.insert(lines, "[✓] Current working directory: `" .. vim.fn.getcwd() .. "`")
			local app_dir = utils.get_app_data_dir(cfg.app_data_dir)
			if vim.fn.isdirectory(app_dir) == 1 then
				table.insert(lines, "[✓] App data directory accessible: `" .. app_dir .. "`")
			else
				table.insert(lines, "[!] App data directory does not exist yet: `" .. app_dir .. "`")
			end
			protocol.show_info_float("Antigravity Doctor", lines, buf)
		end)
	end,

	["/help"] = function(ctx)
		local lines = {
			"# Antigravity Commands & Shortcuts",
			"",
			"### Standalone Control Commands (First-only)",
			"- `/model [id]` — Switch or pick active LLM model",
			"- `/mode [accept-edits|plan|default]` — Switch agent mode",
			"- `/fast` — Switch agent mode to Fast (`accept-edits`)",
			"- `/planning` — Switch agent mode to Planning (`plan`)",
			"- `/effort [low|medium|high|xhigh|max]` — Switch reasoning effort",
			"- `/add-dir <path>` — Add directory to workspace",
			"- `/drop <path>` — Drop directory from workspace",
			"- `/workspace [path]` — View or add workspace directories",
			"- `/copy` — Copy the last assistant response to clipboard",
			"- `/open <path>` — Open a file in Neovim",
			"- `/context` — Inspect session context, memory, and workspaces",
			"- `/settings` — View active configuration and options",
			"- `/status` — View session and connection status",
			"- `/tasks` — View and manage ongoing background tasks",
			"- `/artifacts [filename]` — Review artifacts produced in session",
			"- `/usage` / `/tokens` / `/cost` — View token metrics",
			"- `/doctor` — Verify system health and dependencies",
			"- `/diff` — View git diff of changes",
			"- `/new` / `/clear` — Start a fresh conversation",
			"- `/resume [id]` — Resume past conversation",
			"- `/undo` / `/redo` — Restore previous prompt or undo/redo edits",
			"- `/exit` / `/quit` — Close session buffer",
			"",
			"### Prompt Modifiers / Directives (Chainable)",
			"- `/plan` — Deep planning, verification steps, and user alignment",
			"- `/boost` — Deep thinking, strategic planning, and verification",
			"- `/btw` — Ask a side-question without disrupting conversation",
			"- `/compact` — Compact conversation context to free up the context window",
			"- `/grill-me` — Interactive interview to resolve design decisions",
			"- `/goal` — Autonomous goal task",
			"- `/browser` — Web browsing and search automation",
			"- `/schedule` — Schedule timer or recurring cron job",
			"- `/learn` — Persist patterns and corrections",
			"- `/teamwork-preview` — Multi-agent collaboration",
			"",
			"### Keymaps",
			"- `:w` or `<C-s>` — Submit prompt / answers",
			"- `<C-c>` — Stop in-flight response",
			"- `<CR>` — Toggle thought or tool call details / select options",
		}
		ctx.clear_prompt()
		ctx.protocol.show_info_float("Antigravity Help", lines, ctx.buf)
	end,

	["/tasks"] = function(ctx)
		ctx.clear_prompt()
		require("agy.tasks").open(ctx.buf)
	end,

	["/artifacts"] = function(ctx)
		local art_arg = ctx.trimmed:match("^/artifacts%s+(%S+)")
		ctx.clear_prompt()
		local cid = ctx.state.conversation_id
		if not cid or cid == "" or cid == "new" then
			vim.notify("[agy.nvim] No active conversation session.", vim.log.levels.WARN)
			return
		end
		local artifacts_mod = require("agy.artifacts")
		local arts = artifacts_mod.get_artifacts(cid, ctx.state.config.app_data_dir)
		if #arts == 0 then
			vim.notify("[agy.nvim] No artifacts found for this conversation", vim.log.levels.INFO)
			return
		end
		local target_art = art_arg or arts[1].filename
		vim.cmd("edit agy://" .. cid .. "/artifacts/" .. target_art)
	end,

	["/version"] = function(ctx)
		ctx.clear_prompt()
		local cmd_name = ctx.cfg.agy_cmd or "agy"
		local exe_ok = vim.fn.executable(cmd_name) == 1
		vim.notify(
			"[agy.nvim] agy.nvim 1.0.0 (" .. cmd_name .. " CLI " .. (exe_ok and "ready" or "missing") .. ")",
			vim.log.levels.INFO
		)
	end,
}

---Dispatch a control slash command locally
---@param buf number
---@param state table
---@param first_token string
---@param trimmed string
---@param protocol table
function M.dispatch(buf, state, first_token, trimmed, protocol)
	local cfg = state.config or config_mod.get()
	assert(cfg.icons and cfg.icons.status_switch ~= nil, "agy protocol: config.icons.status_switch is required")
	assert(cfg.icons and cfg.icons.status_added ~= nil, "agy protocol: config.icons.status_added is required")
	local sw_icon = cfg.icons.status_switch
	local sw_prefix = sw_icon ~= "" and (sw_icon .. " ") or ""
	local add_icon = cfg.icons.status_added
	local add_prefix = add_icon ~= "" and (add_icon .. " ") or ""

	local function clear_prompt()
		vim.cmd("stopinsert")
		protocol.with_modifiable(buf, function()
			vim.api.nvim_buf_set_lines(buf, state.prompt_start_line - 1, -1, false, { "" })
		end)
		vim.bo[buf].modified = false
		completion.close()
		local win = vim.fn.bufwinid(buf)
		if win ~= -1 and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_set_cursor, win, { state.prompt_start_line, 0 })
		end
	end

	local handler = M.handlers[first_token]
	assert(handler, "agy protocol: unhandled control command: " .. tostring(first_token))
	handler({
		buf = buf,
		state = state,
		first_token = first_token,
		trimmed = trimmed,
		protocol = protocol,
		cfg = cfg,
		sw_prefix = sw_prefix,
		add_prefix = add_prefix,
		clear_prompt = clear_prompt,
	})
end

return M
