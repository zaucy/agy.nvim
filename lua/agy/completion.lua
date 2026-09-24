local transcript_mod = require("agy.transcript")
local utils = require("agy.utils")

local M = {}

M.NS_HL = vim.api.nvim_create_namespace("agy_completion")

---Antigravity built-in and skill slash commands with argument metadata
---Antigravity built-in and skill slash commands with category and argument metadata
M.COMMANDS = {
  { name = "/add-dir", desc = "Add a directory to the workspace", category = "control", arg_type = "dir" },
  { name = "/agents", desc = "List or manage custom agents", category = "control" },
  { name = "/artifacts", desc = "Review artifacts produced in this session", category = "control", arg_type = "artifact" },
  { name = "/architect", desc = "Architecture and design mode", category = "modifier" },
  { name = "/auth", desc = "Manage authentication credentials", category = "control" },
  { name = "/boost", desc = "Deep thinking, strategic planning, and verification", category = "modifier" },
  { name = "/browser", desc = "Web browsing, search, and browser automation", category = "modifier" },
  { name = "/bug", desc = "Report a bug or unexpected behavior", category = "modifier" },
  { name = "/btw", desc = "Ask a side-question without disrupting conversation", category = "modifier" },
  { name = "/clear", desc = "Clear conversation context and restart session", category = "control" },
  { name = "/compress", desc = "Compress conversation history to save tokens", category = "control" },
  { name = "/context", desc = "Inspect active context and memory", category = "control" },
  { name = "/copy", desc = "Copy last response to clipboard", category = "control", arg_type = "choice", choices = { "response", "code", "btw" } },
  { name = "/cost", desc = "Display cost accounting for session", category = "control" },
  { name = "/diff", desc = "Inspect git diff of workspace changes", category = "control" },
  { name = "/doctor", desc = "Verify system health and dependencies", category = "control" },
  { name = "/drop", desc = "Drop a file or directory from workspace", category = "control", arg_type = "dir" },
  { name = "/effort", desc = "Set reasoning effort level", category = "control", arg_type = "choice", choices = { "low", "medium", "high" } },
  { name = "/exit", desc = "Exit the session", category = "control" },
  { name = "/feedback", desc = "Submit product feedback", category = "control" },
  { name = "/flow", desc = "View agent execution graph", category = "modifier" },
  { name = "/forget", desc = "Forget remembered patterns or rules", category = "control" },
  { name = "/git", desc = "Run git status or git operations", category = "control" },
  { name = "/goal", desc = "Long-running autonomous goal task", category = "modifier" },
  { name = "/grill-me", desc = "Interactive interview to resolve design decisions", category = "modifier" },
  { name = "/help", desc = "Show command reference and shortcuts", category = "control" },
  { name = "/hooks", desc = "Inspect active hooks", category = "control" },
  { name = "/init", desc = "Initialize Antigravity in current project", category = "control" },
  { name = "/learn", desc = "Persist patterns and corrections for future tasks", category = "modifier" },
  { name = "/lint", desc = "Run codebase linter and formatters", category = "control" },
  { name = "/log", desc = "View recent logs or session traces", category = "control" },
  { name = "/mcp", desc = "Manage MCP servers and tools", category = "control" },
  { name = "/memory", desc = "Inspect remembered agent knowledge", category = "control" },
  { name = "/mode", desc = "Set agent mode", category = "control", arg_type = "choice", choices = { "accept-edits", "plan", "default" } },
  { name = "/model", desc = "Select or switch active LLM model", category = "control", arg_type = "model" },
  { name = "/mutate", desc = "Apply automated code mutations", category = "modifier" },
  { name = "/new", desc = "Start a fresh conversation", category = "control" },
  { name = "/notify", desc = "Manage notification settings", category = "control" },
  { name = "/pair", desc = "Pair programming collaboration mode", category = "modifier" },
  { name = "/permissions", desc = "Manage tool permissions and approvals", category = "control" },
  { name = "/plan", desc = "Deep planning, verification steps, and user alignment", category = "modifier" },
  { name = "/plugins", desc = "List installed plugins", category = "control" },
  { name = "/profile", desc = "Switch configuration profile", category = "control" },
  { name = "/quit", desc = "Exit the session", category = "control" },
  { name = "/quota", desc = "Check remaining model API quotas", category = "control" },
  { name = "/rag", desc = "Inspect RAG corpus indexing", category = "control" },
  { name = "/redo", desc = "Redo the previously undone changes", category = "control" },
  { name = "/reload", desc = "Reload session and configuration from disk", category = "control" },
  { name = "/remote-control", desc = "Manage remote control companion connection", category = "control" },
  { name = "/replay", desc = "Replay past conversation turns", category = "control" },
  { name = "/restore", desc = "Restore checkpoint or file states", category = "control" },
  { name = "/resume", desc = "Resume a previous conversation", category = "control", arg_type = "history" },
  { name = "/rules", desc = "View workspace and customization rules", category = "control" },
  { name = "/save", desc = "Save conversation transcript", category = "control" },
  { name = "/schedule", desc = "Schedule a one-shot timer or recurring cron job", category = "modifier" },
  { name = "/scratch", desc = "Open scratchpad notes buffer", category = "control" },
  { name = "/search", desc = "Search across conversation transcripts", category = "control" },
  { name = "/settings", desc = "View or modify CLI configuration", category = "control" },
  { name = "/share", desc = "Export or share conversation", category = "control" },
  { name = "/sidecar", desc = "Inspect active sidecar processes", category = "control" },
  { name = "/skills", desc = "List available skills", category = "control" },
  { name = "/stats", desc = "Show conversation metrics", category = "control" },
  { name = "/status", desc = "Show current session and workspace status", category = "control" },
  { name = "/stop", desc = "Cancel active in-flight turn", category = "control" },
  { name = "/subagent", desc = "Manage background subagents", category = "control" },
  { name = "/summary", desc = "View current conversation summary", category = "control" },
  { name = "/tags", desc = "Manage conversation tags", category = "control" },
  { name = "/tasks", desc = "Manage ongoing background tasks", category = "control" },
  { name = "/teamwork-preview", desc = "Multi-agent collaboration preview", category = "modifier" },
  { name = "/telemetry", desc = "Manage telemetry settings", category = "control" },
  { name = "/theme", desc = "Change CLI theme", category = "control" },
  { name = "/timeout", desc = "Configure network request timeout", category = "control" },
  { name = "/tokens", desc = "View token consumption breakdown", category = "control" },
  { name = "/tools", desc = "List available agent tools", category = "control" },
  { name = "/undo", desc = "Undo the previous turn or file changes", category = "control" },
  { name = "/usage", desc = "View token consumption and accounting", category = "control" },
  { name = "/verbose", desc = "Toggle verbose debug logging", category = "control" },
  { name = "/version", desc = "Show Antigravity CLI version", category = "control" },
  { name = "/workspace", desc = "List or add workspace directories", category = "control", arg_type = "dir" },
}

---Known prompt modifiers / directives that can be chained together and accompany prompts
M.MODIFIER_COMMANDS = {
  ["/architect"] = true,
  ["/boost"] = true,
  ["/browser"] = true,
  ["/bug"] = true,
  ["/btw"] = true,
  ["/flow"] = true,
  ["/goal"] = true,
  ["/grill-me"] = true,
  ["/learn"] = true,
  ["/mutate"] = true,
  ["/pair"] = true,
  ["/plan"] = true,
  ["/schedule"] = true,
  ["/teamwork-preview"] = true,
}

---Standalone control commands that can only appear at the start of a prompt and cannot be chained
M.ONE_OFF_COMMANDS = {}
for _, cmd in ipairs(M.COMMANDS) do
  if cmd.category == "control" then
    M.ONE_OFF_COMMANDS[cmd.name] = true
  end
end

---Find command definition in M.COMMANDS by name
---@param name string
---@return table|nil
function M.find_command(name)
  if not name then return nil end
  for _, cmd in ipairs(M.COMMANDS) do
    if cmd.name == name then
      return cmd
    end
  end
  return nil
end

---Check whether a command is a chainable prompt modifier
---@param cmd_name string
---@return boolean
function M.is_modifier(cmd_name)
  if not cmd_name then return false end
  return M.MODIFIER_COMMANDS[cmd_name] == true
end

---Check whether a command is a standalone control command
---@param cmd_name string
---@return boolean
function M.is_control(cmd_name)
  if not cmd_name or not cmd_name:match("^/") then return false end
  return not M.is_modifier(cmd_name)
end

---Check whether a command is a one-off/control command
---@param cmd_name string
---@return boolean
function M.is_one_off(cmd_name)
  return M.is_control(cmd_name)
end

---Check whether a command is chainable (modifier)
---@param cmd_name string
---@return boolean
function M.is_chainable(cmd_name)
  return M.is_modifier(cmd_name)
end

---Parse raw TSV output from `agy models`
---@param stdout string
---@return table[] models
local function parse_models(stdout)
  if not stdout or stdout == "" then
    return {}
  end
  local models = {}
  for line in stdout:gmatch("[^\r\n]+") do
    local id, name = line:match("^([^\t]+)\t(.*)$")
    if id and name then
      id = id:gsub("^%s*", ""):gsub("%s*$", "")
      name = name:gsub("^%s*", ""):gsub("%s*$", "")
      local provider = "Model"
      if id:match("^gemini") then
        provider = "Google"
      elseif id:match("^claude") then
        provider = "Anthropic"
      elseif id:match("^gpt") or id:match("^o1") or id:match("^o3") or id:match("^chatgpt") then
        provider = "OpenAI"
      elseif id:match("^deepseek") then
        provider = "DeepSeek"
      elseif id:match("^llama") or id:match("^meta") then
        provider = "Meta"
      elseif id:match("^qwen") then
        provider = "Qwen"
      end
      table.insert(models, { id = id, name = name, provider = provider })
    end
  end
  return models
end

---Helper to get configured agy CLI command
local function get_agy_cmd(override_cmd)
  if override_cmd and override_cmd ~= "" then
    return override_cmd
  end
  local cfg_mod = package.loaded["agy.config"]
  if cfg_mod and cfg_mod.get then
    local cmd = cfg_mod.get().agy_cmd
    if cmd and cmd ~= "" then
      return cmd
    end
  end
  return "agy"
end

---Cached models list from dynamic CLI queries
M._cached_models = nil
M._prefetching = false

---Prefetch models dynamically in background using agy.async
---@param cmd? string
function M.prefetch_models(cmd)
  if M._cached_models and #M._cached_models > 0 then
    return
  end
  if M._prefetching then
    return
  end
  M._prefetching = true
  local async = require("agy.async")
  async.run(function()
    local agy_cmd = get_agy_cmd(cmd)
    local ok, obj = async.psystem({ agy_cmd, "models" }, { text = true })
    M._prefetching = false
    if ok and obj and obj.code == 0 and obj.stdout and obj.stdout ~= "" then
      local models = parse_models(obj.stdout)
      if #models > 0 then
        M._cached_models = models
      end
    end
  end):detach()
end

---Fetch models dynamically from agy CLI asynchronously.
---@param cmd? string
---@return table[] models
function M.fetch_models_async(cmd)
  local async = require("agy.async")
  local agy_cmd = get_agy_cmd(cmd)
  local obj = async.system({ agy_cmd, "models" }, { text = true })
  if not obj or obj.code ~= 0 then
    local err_msg = (obj and obj.stderr and obj.stderr ~= "") and obj.stderr or ("exit code " .. tostring(obj and obj.code))
    error("[agy.nvim] '" .. agy_cmd .. " models' failed (" .. err_msg .. ")")
  end
  local models = parse_models(obj.stdout)
  if #models == 0 then
    error("[agy.nvim] '" .. agy_cmd .. " models' returned no available models")
  end
  M._cached_models = models
  return models
end

---Fetch models dynamically from agy CLI synchronously.
---Raises an error if the CLI fails or returns no models.
---@param cmd? string
---@return table[] models
function M.fetch_models(cmd)
  local agy_cmd = get_agy_cmd(cmd)
  local ok, obj = pcall(function()
    return vim.system({ agy_cmd, "models" }, { text = true }):wait()
  end)
  if not ok then
    error("[agy.nvim] Failed to execute '" .. agy_cmd .. " models': " .. tostring(obj))
  end
  if not obj or obj.code ~= 0 then
    local err_msg = (obj and obj.stderr and obj.stderr ~= "") and obj.stderr or ("exit code " .. tostring(obj and obj.code))
    error("[agy.nvim] '" .. agy_cmd .. " models' failed (" .. err_msg .. ")")
  end
  local models = parse_models(obj.stdout)
  if #models == 0 then
    error("[agy.nvim] '" .. agy_cmd .. " models' returned no available models")
  end
  M._cached_models = models
  return models
end

---Get list of available models (cached or fetched synchronously from agy CLI).
---Raises an error if models cannot be retrieved.
---@param cmd? string
---@return table[] models
function M.get_available_models(cmd)
  if M._cached_models and #M._cached_models > 0 then
    return M._cached_models
  end
  return M.fetch_models(cmd)
end

---Fuzzy / rich matching for available models
---@param query string
---@param cmd? string
---@return table[] matches
function M.complete_models(query, cmd)
  local models = M.get_available_models(cmd)
  local q = (query or ""):lower():gsub("^%s*", ""):gsub("%s*$", "")

  if q == "" then
    local items = {}
    for _, m in ipairs(models) do
      table.insert(items, {
        label = m.id,
        kind = m.provider,
        detail = m.name,
        insert_text = m.id .. " ",
      })
    end
    return items
  end

  local scored = {}
  for idx, m in ipairs(models) do
    local id_lower = m.id:lower()
    local name_lower = m.name:lower()
    local prov_lower = m.provider:lower()

    local score = 0
    if id_lower == q or name_lower == q then
      score = 100
    elseif id_lower:find(q, 1, true) == 1 then
      score = 80
    elseif name_lower:find(q, 1, true) == 1 then
      score = 70
    elseif id_lower:find(q, 1, true) then
      score = 60
    elseif name_lower:find(q, 1, true) then
      score = 50
    elseif prov_lower:find(q, 1, true) == 1 then
      score = 45
    else
      -- Fuzzy match: check if all chars of q appear in order in id or name
      local function fuzzy_match(str, pattern)
        local p_idx = 1
        local p_len = #pattern
        for i = 1, #str do
          if str:byte(i) == pattern:byte(p_idx) then
            p_idx = p_idx + 1
            if p_idx > p_len then return true end
          end
        end
        return false
      end

      if fuzzy_match(id_lower, q) then
        score = 30
      elseif fuzzy_match(name_lower, q) then
        score = 20
      end
    end

    if score > 0 then
      table.insert(scored, {
        model = m,
        score = score,
        orig_idx = idx,
      })
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.orig_idx < b.orig_idx
  end)

  local results = {}
  for _, s in ipairs(scored) do
    table.insert(results, {
      label = s.model.id,
      kind = s.model.provider,
      detail = s.model.name,
      insert_text = s.model.id .. " ",
    })
  end
  return results
end

---Resolve a model name or ID into its canonical model ID
---@param model_or_name? string
---@return string model_id
function M.resolve_model(model_or_name)
  if not model_or_name or model_or_name == "" then
    return M.get_default_model()
  end

  local trimmed = model_or_name:gsub("^%s*", ""):gsub("%s*$", "")
  local q = trimmed:lower()

  -- If models are already cached, perform rich/exact matching
  if M._cached_models and #M._cached_models > 0 then
    -- 1. Exact match on id or name
    for _, m in ipairs(M._cached_models) do
      if m.id == trimmed or m.name == trimmed or m.id:lower() == q or m.name:lower() == q then
        return m.id
      end
    end

    -- 2. Partial prefix / substring match using complete_models scoring
    local matches = M.complete_models(trimmed)
    if matches and #matches > 0 then
      return matches[1].label
    end
  else
    -- Trigger background prefetch so future queries are instant
    M.prefetch_models()
  end

  -- If trimmed is already in canonical ID format (lowercase alphanumeric with hyphens), return it directly
  if trimmed:match("^[a-z0-9%-%.]+$") then
    return trimmed
  end

  -- Fast slugification for display names (e.g. "Gemini 3.8 Flash (High)" -> "gemini-3.8-flash-high")
  local slug = trimmed:lower():gsub("[()%s]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if slug ~= "" then
    return slug
  end

  return trimmed
end

---Discover the default model ID
---Priority:
---1. config_default if provided and non-empty
---2. Antigravity settings.json "model" field in app_data_dir
---3. First available model from agy models (or background prefetch)
---@param app_data_dir? string
---@param config_default? string
---@param cmd? string
---@return string model_id
function M.get_default_model(app_data_dir, config_default, cmd)
  if config_default and config_default ~= "" then
    return M.resolve_model(config_default)
  end

  local settings_path = utils.get_app_data_dir(app_data_dir) .. "/settings.json"
  local f = io.open(settings_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
      local settings = utils.json_decode(content)
      if settings and settings.model and type(settings.model) == "string" and settings.model ~= "" then
        return M.resolve_model(settings.model)
      end
    end
  end

  local models = M.get_available_models(cmd)
  if models and #models > 0 and models[1].id then
    return models[1].id
  end

  local agy_cmd = get_agy_cmd(cmd)
  error("[agy.nvim] Failed to determine default model: no models available from '" .. agy_cmd .. " models' or settings.json")
end

---Current floating completion UI state
M.state = {
  win = nil,
  buf = nil,
  target_win = nil,
  target_buf = nil,
  items = {},
  selected_idx = 1,
  data = nil,
}

---Check whether the floating completion window is visible
---@return boolean
function M.is_visible()
  return M.state.win ~= nil and vim.api.nvim_win_is_valid(M.state.win)
end

---Close the completion popup and clean up its resources
function M.close()
  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    pcall(vim.api.nvim_win_close, M.state.win, true)
  end
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) then
    pcall(vim.api.nvim_buf_delete, M.state.buf, { force = true })
  end
  M.state.win = nil
  M.state.buf = nil
  M.state.items = {}
  M.state.selected_idx = 1
  M.state.scroll_offset = 1
  M.state.data = nil
end

---Scan directories matching the input path
---@param input_path string
---@return table[] matches
function M.complete_directories(input_path)
  local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local default_sep = is_win and "\\" or "/"

  local raw = input_path or ""
  local has_tilde = raw:sub(1, 1) == "~"
  local home = vim.fs.normalize(vim.fn.expand("~"))

  local expanded
  if has_tilde then
    expanded = home .. raw:sub(2)
  else
    expanded = raw
  end
  expanded = vim.fs.normalize(expanded)

  local search_dir, filter_prefix, display_prefix
  local user_sep = raw:find("\\") and "\\" or default_sep

  if raw == "" then
    search_dir = vim.fn.getcwd()
    filter_prefix = ""
    display_prefix = ""
  elseif vim.fn.isdirectory(expanded) == 1 then
    search_dir = expanded
    filter_prefix = ""
    display_prefix = raw .. (raw:sub(-1):match("[/\\]") and "" or user_sep)
  else
    search_dir = vim.fs.dirname(expanded)
    filter_prefix = vim.fs.basename(expanded) or ""
    local last_slash = raw:match(".*()[/\\]")
    display_prefix = last_slash and raw:sub(1, last_slash) or ""
  end

  local results = {}
  local h = vim.uv.fs_scandir(search_dir)
  if h then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(h)
      if not name then break end
      if ftype == "directory" then
        if filter_prefix == "" or name:lower():find(filter_prefix:lower(), 1, true) == 1 then
          local full_path = vim.fs.normalize(search_dir .. "/" .. name)
          local display_name = display_prefix .. name .. user_sep
          table.insert(results, {
            label = display_name,
            kind = "Directory",
            detail = full_path,
            insert_text = display_name,
          })
        end
      end
    end
  end

  table.sort(results, function(a, b) return a.label:lower() < b.label:lower() end)
  return results
end

---Complete choices for commands like /mode, /model, /effort
---@param choices string[]
---@param query string
---@param kind string
---@return table[] matches
function M.complete_choices(choices, query, kind)
  local q = (query or ""):lower()
  local results = {}
  for _, c in ipairs(choices) do
    if q == "" or c:lower():find(q, 1, true) == 1 then
      table.insert(results, {
        label = c,
        kind = kind or "Choice",
        detail = "",
        insert_text = c,
      })
    end
  end
  return results
end

---Complete conversation history for /resume
---@param query string
---@param app_data_dir? string
---@return table[] matches
function M.complete_history(query, app_data_dir)
  local q = (query or ""):lower()
  local history = transcript_mod.read_history(app_data_dir)
  local results = {}
  for _, h in ipairs(history) do
    if q == "" or h.conversation_id:lower():find(q, 1, true) or h.title:lower():find(q, 1, true) then
      table.insert(results, {
        label = h.conversation_id:sub(1, 8),
        kind = "History",
        detail = h.title,
        insert_text = h.conversation_id,
      })
    end
  end
  return results
end

---Complete artifacts for /artifacts
---@param query string
---@param conv_id? string
---@param app_data_dir? string
---@return table[] matches
function M.complete_artifacts(query, conv_id, app_data_dir)
  local q = (query or ""):lower()
  local artifacts_mod = require("agy.artifacts")

  if not conv_id or conv_id == "" or conv_id == "new" then
    local protocol = package.loaded["agy.protocol"]
    if protocol and protocol.buffers then
      local cur_buf = vim.api.nvim_get_current_buf()
      if protocol.buffers[cur_buf] and protocol.buffers[cur_buf].conversation_id then
        conv_id = protocol.buffers[cur_buf].conversation_id
      else
        for _, st in pairs(protocol.buffers) do
          if st.conversation_id and st.conversation_id ~= "" and st.conversation_id ~= "new" then
            conv_id = st.conversation_id
            break
          end
        end
      end
    end
    if not conv_id or conv_id == "" or conv_id == "new" then
      local bname = vim.api.nvim_buf_get_name(0)
      conv_id = bname:match("^agy://([^/?#]+)")
    end
    if not conv_id or conv_id == "" or conv_id == "new" then
      local history = transcript_mod.read_history(app_data_dir)
      if history and #history > 0 then
        conv_id = history[1].conversation_id
      end
    end
  end

  if not conv_id or conv_id == "" or conv_id == "new" then
    return {}
  end

  local arts = artifacts_mod.get_artifacts(conv_id, app_data_dir)
  local results = {}
  for _, art in ipairs(arts) do
    local fname = art.filename
    if q == "" or fname:lower():find(q, 1, true) or (art.summary and art.summary:lower():find(q, 1, true)) then
      local has_unsaved = artifacts_mod.has_unsaved_comments(conv_id, fname)
      local count = artifacts_mod.get_comments_count(conv_id, fname)
      local label = fname .. (has_unsaved and " *" or "")
      local detail = art.summary or ""
      if has_unsaved then
        local badge = string.format("[* %d unsaved comment%s] ", count, count > 1 and "s" or "")
        detail = badge .. detail
      end
      table.insert(results, {
        label = label,
        kind = "Artifact",
        detail = detail,
        insert_text = fname .. " ",
      })
    end
  end
  return results
end

---Cache of workspace files
M._workspace_files_cache = {}

---Scan workspace files using git ls-files with fallback to recursive fs_scandir
---@param ws string Workspace root directory
---@return string[] relative_paths
function M.get_workspace_files(ws)
  local norm_ws = vim.fs.normalize(ws or vim.fn.getcwd())
  local cached = M._workspace_files_cache[norm_ws]
  local now = vim.uv.now()
  if cached and (now - cached.timestamp < 3000) then
    return cached.files
  end

  local files = {}
  -- 1. Try git ls-files if available
  local ok, obj = pcall(function()
    return vim.system(
      { "git", "-C", norm_ws, "ls-files", "--cached", "--others", "--exclude-standard" },
      { text = true }
    ):wait()
  end)

  if ok and obj and obj.code == 0 and obj.stdout and obj.stdout ~= "" then
    for line in obj.stdout:gmatch("[^\r\n]+") do
      local trimmed = utils.trim(line)
      if trimmed ~= "" then
        table.insert(files, trimmed)
      end
    end
  else
    -- 2. Fallback: recursive filesystem scan with ignore filters
    local ignore_dirs = {
      [".git"] = true,
      [".gemini"] = true,
      ["node_modules"] = true,
      ["target"] = true,
      ["build"] = true,
      [".vs"] = true,
      [".idea"] = true,
      [".vscode"] = true,
      ["dist"] = true,
      ["__pycache__"] = true,
    }
    local ignore_exts = {
      [".exe"] = true,
      [".dll"] = true,
      [".so"] = true,
      [".dylib"] = true,
      [".png"] = true,
      [".jpg"] = true,
      [".jpeg"] = true,
      [".gif"] = true,
      [".ico"] = true,
      [".zip"] = true,
      [".tar"] = true,
      [".gz"] = true,
      [".7z"] = true,
      [".pdf"] = true,
      [".mp4"] = true,
      [".mp3"] = true,
      [".wav"] = true,
      [".o"] = true,
      [".a"] = true,
      [".obj"] = true,
      [".pdb"] = true,
    }

    local function scan(dir, rel_prefix)
      if #files >= 3000 then return end
      local h = vim.uv.fs_scandir(dir)
      if not h then return end
      while true do
        local name, ftype = vim.uv.fs_scandir_next(h)
        if not name then break end
        if ftype == "directory" then
          if not ignore_dirs[name] and not name:match("^%.") then
            scan(dir .. "/" .. name, rel_prefix .. name .. "/")
          end
        elseif ftype == "file" then
          local ext = name:match("(%.[^.]+)$")
          if not (ext and ignore_exts[ext:lower()]) then
            table.insert(files, rel_prefix .. name)
            if #files >= 3000 then break end
          end
        end
      end
    end

    scan(norm_ws, "")
  end

  M._workspace_files_cache[norm_ws] = {
    timestamp = now,
    files = files,
  }
  return files
end

---Fuzzy match workspace files for @ mentions
---@param query string Search prefix after '@' or '@['
---@param workspaces? string[] Active workspace roots
---@param has_bracket? boolean True if user started with '@['
---@return table[] matches
function M.complete_files(query, workspaces, has_bracket)
  local ws_list = workspaces
  if not ws_list or #ws_list == 0 then
    ws_list = { vim.fn.getcwd() }
  end

  local raw_q = query or ""
  raw_q = raw_q:gsub("^@", ""):gsub("^%[", ""):gsub("%]$", "")

  local prefers_backslash = raw_q:find("\\") ~= nil
  local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local user_sep = prefers_backslash and "\\" or (raw_q:find("/") and "/" or (is_win and "\\" or "/"))

  local q = raw_q:lower():gsub("\\", "/")

  local candidates = {}
  local seen = {}
  for _, ws in ipairs(ws_list) do
    local norm_ws = vim.fs.normalize(ws)
    local w_files = M.get_workspace_files(norm_ws)
    for _, rel in ipairs(w_files) do
      if not seen[rel] then
        seen[rel] = true
        table.insert(candidates, {
          rel = rel,
          full_path = norm_ws .. "/" .. rel,
        })
      end
    end
  end

  if q == "" then
    local items = {}
    local max_items = 50
    for i, c in ipairs(candidates) do
      if i > max_items then break end
      local disp = (user_sep == "\\") and c.rel:gsub("/", "\\") or c.rel:gsub("\\", "/")
      local full_disp = (user_sep == "\\") and c.full_path:gsub("/", "\\") or c.full_path
      local insert_str
      if has_bracket or disp:find("%s") then
        insert_str = "@[" .. disp .. "] "
      else
        insert_str = "@" .. disp .. " "
      end
      table.insert(items, {
        label = disp,
        kind = "File",
        detail = full_disp,
        insert_text = insert_str,
      })
    end
    return items
  end

  local scored = {}
  for idx, c in ipairs(candidates) do
    local path_lower = c.rel:lower():gsub("\\", "/")
    local base_name = vim.fs.basename(c.rel) or ""
    local base_lower = base_name:lower()

    local score = 0
    if base_lower == q then
      score = 1000
    elseif path_lower == q then
      score = 950
    elseif base_lower:find(q, 1, true) == 1 then
      score = 850 - #base_lower
    elseif path_lower:find(q, 1, true) == 1 then
      score = 800 - #path_lower
    elseif base_lower:find(q, 1, true) then
      score = 700 - #base_lower
    elseif path_lower:find(q, 1, true) then
      score = 600 - #path_lower
    else
      -- Fuzzy subsequence match
      local p_idx = 1
      local p_len = #q
      local consecutive = 0
      local fscore = 0
      for i = 1, #path_lower do
        if path_lower:byte(i) == q:byte(p_idx) then
          p_idx = p_idx + 1
          consecutive = consecutive + 1
          fscore = fscore + 10 + (consecutive * 5)
          if i == 1 or path_lower:byte(i - 1) == 47 or path_lower:byte(i - 1) == 95 or path_lower:byte(i - 1) == 46 then
            fscore = fscore + 15
          end
          if p_idx > p_len then
            score = math.max(10, math.min(500, fscore + 100 - #path_lower))
            break
          end
        else
          consecutive = 0
        end
      end
    end

    if score > 0 then
      table.insert(scored, {
        cand = c,
        score = score,
        orig_idx = idx,
      })
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.orig_idx < b.orig_idx
  end)

  local results = {}
  local max_results = 50
  for i, s in ipairs(scored) do
    if i > max_results then break end
    local disp = (user_sep == "\\") and s.cand.rel:gsub("/", "\\") or s.cand.rel:gsub("\\", "/")
    local full_disp = (user_sep == "\\") and s.cand.full_path:gsub("/", "\\") or s.cand.full_path
    local insert_str
    if has_bracket or disp:find("%s") then
      insert_str = "@[" .. disp .. "] "
    else
      insert_str = "@" .. disp .. " "
    end
    table.insert(results, {
      label = disp,
      kind = "File",
      detail = full_disp,
      insert_text = insert_str,
    })
  end

  return results
end

---Get completion candidates for current line content and cursor column
---@param line_text string
---@param col number 0-indexed cursor column
---@param app_data_dir? string
---@param workspaces? string[]
---@param conv_id? string
---@return table|nil completion_data
function M.get_completions(line_text, col, app_data_dir, workspaces, conv_id)
  local before = line_text:sub(1, col)
  if before:match("^%s*$") then
    return nil
  end

  if not conv_id or conv_id == "" or conv_id == "new" then
    local cur_buf = vim.api.nvim_get_current_buf()
    local protocol = package.loaded["agy.protocol"]
    if protocol and protocol.buffers and protocol.buffers[cur_buf] then
      conv_id = protocol.buffers[cur_buf].conversation_id
    end
    if not conv_id or conv_id == "" or conv_id == "new" then
      local bname = vim.api.nvim_buf_get_name(cur_buf)
      conv_id = bname:match("^agy://([^/?#]+)")
    end
  end

  -- Check for @ mention triggers:
  -- 1. Bracketed mention: @[...]
  local b_start, b_prefix = before:match(".*()@%[([^%]]*)$")
  if b_start then
    b_start = tonumber(b_start)
    local char_before = (b_start > 1) and before:sub(b_start - 1, b_start - 1) or " "
    if b_start == 1 or char_before:match("[%s%p]") then
      local prefix = b_prefix or ""
      local after = line_text:sub(col + 1)
      local b_rem, b_close = after:match("^([^%]]*)(%]?)")
      local replace_start_col = b_start - 1
      local replace_end_col = col + #(b_rem or "") + #(b_close or "")
      local mention_mod = require("agy.mention")
      local ctx = mention_mod.build_context(workspaces)
      local items = mention_mod.complete(prefix, ctx, true)
      if items and #items > 0 then
        return {
          type = "mention",
          prefix = prefix,
          has_bracket = true,
          workspaces = workspaces,
          replace_start_col = replace_start_col,
          replace_end_col = replace_end_col,
          items = items,
        }
      end
    end
  end

  -- 2. Unbracketed mention: @...
  local at_start, at_prefix = before:match(".*()@([%w_%-./\\]*)$")
  if at_start then
    at_start = tonumber(at_start)
    local char_before = (at_start > 1) and before:sub(at_start - 1, at_start - 1) or " "
    if at_start == 1 or char_before:match("[%s%p]") then
      local prefix = at_prefix or ""
      local after = line_text:sub(col + 1)
      local remainder = after:match("^([%w_%-./\\]*)") or ""
      local replace_start_col = at_start - 1
      local replace_end_col = col + #remainder
      local mention_mod = require("agy.mention")
      local ctx = mention_mod.build_context(workspaces)
      local items = mention_mod.complete(prefix, ctx, false)
      if items and #items > 0 then
        return {
          type = "mention",
          prefix = prefix,
          has_bracket = false,
          workspaces = workspaces,
          replace_start_col = replace_start_col,
          replace_end_col = replace_end_col,
          items = items,
        }
      end
    end
  end

  -- Parse tokens from before with column boundaries
  local tokens = {}
  for start_idx, tok, end_idx in before:gmatch("()(%S+)()") do
    table.insert(tokens, {
      text = tok,
      start_col = start_idx - 1, -- 0-indexed
      end_col = end_idx - 1,     -- 0-indexed (exclusive)
    })
  end

  if #tokens == 0 then
    return nil
  end

  local has_trailing_space = before:match("%s+$") ~= nil

  -- The first token must start with "/" for slash command interactions
  if not tokens[1].text:match("^/") then
    return nil
  end

  -- Case 1: User is still typing the first token
  if #tokens == 1 and not has_trailing_space then
    local q = tokens[1].text:lower()
    local matches = {}
    for _, cmd in ipairs(M.COMMANDS) do
      if cmd.name:lower():find(q, 1, true) == 1 or cmd.name:lower():find(q:sub(2), 1, true) == 1 then
        table.insert(matches, {
          label = cmd.name,
          kind = "Command",
          detail = cmd.desc,
          insert_text = cmd.name .. " ",
          arg_type = cmd.arg_type,
          is_one_off = M.is_one_off(cmd.name),
        })
      end
    end
    return {
      type = "command",
      prefix = tokens[1].text,
      replace_start_col = tokens[1].start_col,
      replace_end_col = tokens[1].end_col,
      items = matches,
    }
  end

  -- Helper to get argument items for any command with arg_type
  local function get_arg_items(cmd_def, arg_query)
    local items = {}
    if cmd_def.arg_type == "model" then
      items = M.complete_models(arg_query)
    elseif cmd_def.arg_type == "choice" then
      local kind = cmd_def.name:sub(2, 2):upper() .. cmd_def.name:sub(3)
      items = M.complete_choices(cmd_def.choices or {}, arg_query, kind)
    elseif cmd_def.arg_type == "dir" then
      items = M.complete_directories(arg_query)
    elseif cmd_def.arg_type == "history" then
      items = M.complete_history(arg_query, app_data_dir)
    elseif cmd_def.arg_type == "artifact" then
      items = M.complete_artifacts(arg_query, conv_id, app_data_dir)
    end
    return items
  end

  -- Helper to get chainable modifier command items
  local function get_chainable_commands(query)
    local q = (query or ""):lower()
    if q:sub(1, 1) == "/" then
      q = q:sub(2)
    end
    local matches = {}
    for _, cmd in ipairs(M.COMMANDS) do
      -- ONLY prompt modifiers allowed in chained positions!
      if M.is_modifier(cmd.name) then
        local cname = cmd.name:lower():sub(2) -- strip leading '/'
        if q == "" or cname:find(q, 1, true) == 1 then
          table.insert(matches, {
            label = cmd.name,
            kind = "Command",
            detail = cmd.desc,
            insert_text = cmd.name .. " ",
            arg_type = cmd.arg_type,
            category = "modifier",
          })
        end
      end
    end
    return matches
  end

  -- Case 2: Line starts with a CONTROL command (never chainable, first-only)
  local first_cmd_name = tokens[1].text
  if M.is_control(first_cmd_name) then
    local first_cmd = M.find_command(first_cmd_name)
    if not first_cmd or not first_cmd.arg_type then
      -- Control command with no arguments (e.g. /context, /settings, /doctor, /clear):
      -- NO chaining or further completion allowed!
      return nil
    end

    -- Control command takes an argument (e.g. /model, /add-dir, /drop, /workspace, /mode, /effort, /resume)
    if #tokens == 1 and has_trailing_space then
      -- Argument is empty string
      local items = get_arg_items(first_cmd, "")
      return {
        type = "arg",
        cmd = first_cmd_name,
        prefix = "",
        replace_start_col = #before,
        replace_end_col = #before,
        items = items,
      }
    elseif #tokens == 2 and not has_trailing_space then
      -- User is typing the argument
      local arg_text = tokens[2].text
      local items = get_arg_items(first_cmd, arg_text)
      return {
        type = "arg",
        cmd = first_cmd_name,
        prefix = arg_text,
        replace_start_col = tokens[2].start_col,
        replace_end_col = tokens[2].end_col,
        items = items,
      }
    else
      -- Argument already completed and user pressed space: no chaining allowed after control command!
      return nil
    end
  end

  -- Case 3: Line has chainable commands
  -- Walk tokens to check if we are in a valid chainable command sequence
  local idx = 1
  local expecting_arg_for = nil
  local chain_ended = false

  while idx <= #tokens do
    local tok = tokens[idx]
    if idx == #tokens and not has_trailing_space then
      -- The last token is currently being typed by the user
      break
    end

    if tok.text:match("^/") then
      local cmd_def = M.find_command(tok.text)
      -- One-off commands cannot appear in chained position
      if not cmd_def or M.is_one_off(tok.text) then
        chain_ended = true
        break
      end

      if cmd_def.arg_type then
        -- This command expects an argument
        if idx < #tokens then
          -- Next token was consumed as argument
          idx = idx + 1
          expecting_arg_for = nil
        else
          -- idx == #tokens and has_trailing_space
          expecting_arg_for = cmd_def
        end
      else
        expecting_arg_for = nil
      end
    else
      -- Non-slash token encountered when not expected as a command argument
      chain_ended = true
      break
    end

    idx = idx + 1
  end

  -- If the slash command chain has ended (user started typing free-form prompt text):
  -- Only provide completion if user is currently typing a new slash command starting with "/"
  if chain_ended then
    if not has_trailing_space and tokens[#tokens].text:match("^/") then
      local last_tok = tokens[#tokens]
      local matches = get_chainable_commands(last_tok.text)
      if #matches > 0 then
        return {
          type = "command",
          prefix = last_tok.text,
          replace_start_col = last_tok.start_col,
          replace_end_col = last_tok.end_col,
          items = matches,
        }
      end
    end
    return nil
  end

  -- If waiting for argument after space
  if expecting_arg_for then
    local items = get_arg_items(expecting_arg_for, "")
    return {
      type = "arg",
      cmd = expecting_arg_for.name,
      prefix = "",
      replace_start_col = #before,
      replace_end_col = #before,
      items = items,
    }
  end

  -- If trailing space in an active chain: suggest next chainable commands
  if has_trailing_space then
    local matches = get_chainable_commands("")
    if #matches > 0 then
      return {
        type = "command",
        prefix = "",
        replace_start_col = #before,
        replace_end_col = #before,
        items = matches,
      }
    end
    return nil
  end

  -- Typing the last token in the chain
  local last_tok = tokens[#tokens]

  -- Check if previous token was expecting an argument
  if #tokens >= 2 then
    local prev_tok = tokens[#tokens - 1]
    local prev_cmd = M.find_command(prev_tok.text)
    if prev_cmd and prev_cmd.arg_type and not last_tok.text:match("^/") then
      local items = get_arg_items(prev_cmd, last_tok.text)
      return {
        type = "arg",
        cmd = prev_cmd.name,
        prefix = last_tok.text,
        replace_start_col = last_tok.start_col,
        replace_end_col = last_tok.end_col,
        items = items,
      }
    end
  end

  -- Typing a chainable command (starting with "/")
  if last_tok.text:match("^/") then
    local matches = get_chainable_commands(last_tok.text)
    if #matches > 0 then
      return {
        type = "command",
        prefix = last_tok.text,
        replace_start_col = last_tok.start_col,
        replace_end_col = last_tok.end_col,
        items = matches,
      }
    end
  end

  return nil
end

---Render the contents of the floating completion popup buffer
function M.render_buffer()
  if not M.state.buf or not vim.api.nvim_buf_is_valid(M.state.buf) then return end

  local items = M.state.items
  local total_count = #items
  local selected_idx = M.state.selected_idx
  local max_visible = 5

  if total_count == 0 then return end
  if selected_idx < 1 then selected_idx = 1 end
  if selected_idx > total_count then selected_idx = total_count end
  M.state.selected_idx = selected_idx

  -- Sliding window scroll offset
  if not M.state.scroll_offset or M.state.scroll_offset < 1 then
    M.state.scroll_offset = 1
  end

  if selected_idx < M.state.scroll_offset then
    M.state.scroll_offset = selected_idx
  elseif selected_idx >= M.state.scroll_offset + max_visible then
    M.state.scroll_offset = selected_idx - max_visible + 1
  end

  local start_idx = M.state.scroll_offset
  local end_idx = math.min(total_count, start_idx + max_visible - 1)

  local lines = {}
  local highlights = {}

  local max_label = 0
  for i = start_idx, end_idx do
    if #items[i].label > max_label then
      max_label = #items[i].label
    end
  end
  local label_width = math.min(38, math.max(max_label, 12))

  local row_idx = 0
  for i = start_idx, end_idx do
    local it = items[i]
    local is_sel = (i == selected_idx)
    local pointer = is_sel and "> " or "  "
    local pad1 = string.rep(" ", math.max(1, label_width - #it.label + 2))
    local pad2 = "  "
    local line_str = pointer .. it.label .. pad1 .. it.kind .. pad2 .. it.detail
    table.insert(lines, line_str)

    table.insert(highlights, {
      row = row_idx,
      is_sel = is_sel,
      label_start = 2,
      label_end = 2 + #it.label,
      kind_start = 2 + #it.label + #pad1,
      kind_end = 2 + #it.label + #pad1 + #it.kind,
      detail_start = 2 + #it.label + #pad1 + #it.kind + #pad2,
      detail_end = #line_str,
    })
    row_idx = row_idx + 1
  end

  if total_count > max_visible then
    local remaining = total_count - end_idx
    if remaining > 0 then
      table.insert(lines, string.format("  ↓ %d more", remaining))
    else
      table.insert(lines, string.format("  (%d/%d)", selected_idx, total_count))
    end
  end

  table.insert(lines, "")
  local footer_text = "↑/↓ Navigate · enter Select · tab Complete"
  table.insert(lines, footer_text)

  vim.bo[M.state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
  vim.bo[M.state.buf].modifiable = false

  -- Apply extmarks / highlights
  vim.api.nvim_buf_clear_namespace(M.state.buf, M.NS_HL, 0, -1)
  for _, hl in ipairs(highlights) do
    if hl.is_sel then
      vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
        line_hl_group = "AgyCompletionSel",
        priority = 100,
      })
      vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, 0, {
        end_col = 1,
        hl_group = "AgyCompletionPointer",
      })
    end
    vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, hl.label_start, {
      end_col = hl.label_end,
      hl_group = "AgyCompletionLabel",
    })
    vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, hl.kind_start, {
      end_col = hl.kind_end,
      hl_group = "AgyCompletionKind",
    })
    vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, hl.row, hl.detail_start, {
      end_col = hl.detail_end,
      hl_group = "AgyCompletionDetail",
    })
  end

  local overflow_line_idx = end_idx - start_idx + 1
  if total_count > max_visible then
    vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, overflow_line_idx, 0, {
      hl_group = "AgyCompletionMore",
      line_hl_group = "AgyCompletionMore",
    })
  end

  local footer_row = #lines - 1
  vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, footer_row, 0, {
    hl_group = "AgyCompletionFooter",
  })

  -- Highlight key tokens in footer
  local keys = { { "↑/↓", 0 }, { "enter", 15 }, { "tab", 30 } }
  for _, k in ipairs(keys) do
    local s, e = footer_text:find(k[1], 1, true)
    if s and e then
      vim.api.nvim_buf_set_extmark(M.state.buf, M.NS_HL, footer_row, s - 1, {
        end_col = e,
        hl_group = "AgyCompletionKey",
      })
    end
  end
end

---Display or update the completion popup window
---@param target_win number
---@param target_buf number
---@param data table
function M.show(target_win, target_buf, data)
  if not data or not data.items or #data.items == 0 then
    M.close()
    return
  end

  M.state.target_win = target_win
  M.state.target_buf = target_buf
  M.state.data = data
  M.state.items = data.items

  if M.state.selected_idx > #data.items or M.state.selected_idx < 1 then
    M.state.selected_idx = 1
    M.state.scroll_offset = 1
  end

  local max_visible = 5
  local count = math.min(#data.items, max_visible)
  local height = count + (#data.items > max_visible and 1 or 0) + 2

  local win_width = vim.api.nvim_win_get_width(target_win)
  local win_height = vim.api.nvim_win_get_height(target_win)
  local width = win_width

  local winline = vim.fn.winline()
  local border_offset = 1 -- account for prompt bottom border virtual line
  local space_below = win_height - (winline + border_offset)

  -- Ensure room below cursor line and bottom border for options display
  if space_below < height then
    local needed = height - space_below
    local view = vim.fn.winsaveview()
    view.topline = view.topline + needed
    vim.fn.winrestview(view)
    pcall(vim.cmd, "redraw")
    winline = vim.fn.winline()
  end
  local row = winline + border_offset

  if not M.state.buf or not vim.api.nvim_buf_is_valid(M.state.buf) then
    M.state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.state.buf].buftype = "nofile"
    vim.bo[M.state.buf].bufhidden = "wipe"
    vim.bo[M.state.buf].swapfile = false
    vim.bo[M.state.buf].filetype = "agy_completion"
  end

  local win_cfg = {
    relative = "win",
    win = target_win,
    row = row,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 200,
  }

  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    vim.api.nvim_win_set_config(M.state.win, win_cfg)
  else
    M.state.win = vim.api.nvim_open_win(M.state.buf, false, win_cfg)
    vim.wo[M.state.win].wrap = false
    vim.wo[M.state.win].cursorline = false
    vim.wo[M.state.win].winhighlight = "Normal:Normal,NormalFloat:Normal"
  end

  M.render_buffer()
end

---Select next item in the completion list
function M.select_next()
  if not M.is_visible() or #M.state.items == 0 then return end
  M.state.selected_idx = (M.state.selected_idx % #M.state.items) + 1
  M.render_buffer()
end

---Select previous item in the completion list
function M.select_prev()
  if not M.is_visible() or #M.state.items == 0 then return end
  M.state.selected_idx = (M.state.selected_idx - 2 + #M.state.items) % #M.state.items + 1
  M.render_buffer()
end

---Accept current selection
---@param is_enter boolean True if triggered by Enter (commits selection), false if Tab (completes prefix)
---@return boolean handled
function M.accept(is_enter)
  if not M.is_visible() or #M.state.items == 0 then return false end
  local it = M.state.items[M.state.selected_idx]
  if not it then return false end

  local data = M.state.data
  local target_buf = M.state.target_buf or vim.api.nvim_get_current_buf()
  local target_win = M.state.target_win or vim.api.nvim_get_current_win()
  local cur_pos = (target_win and vim.api.nvim_win_is_valid(target_win))
      and vim.api.nvim_win_get_cursor(target_win)
      or vim.api.nvim_win_get_cursor(0)
  local cur_row = cur_pos[1]

  local cur_lines = vim.api.nvim_buf_get_lines(target_buf, cur_row - 1, cur_row, false)
  local cur_line = cur_lines[1] or ""
  local start_col = data.replace_start_col or 0
  local end_col = data.replace_end_col or #cur_line

  local prefix = cur_line:sub(1, start_col)
  local suffix = cur_line:sub(end_col + 1)
  local new_line = prefix .. it.insert_text .. suffix

  local protocol = package.loaded["agy.protocol"]
  if protocol and protocol.with_modifiable then
    protocol.with_modifiable(target_buf, function()
      vim.api.nvim_buf_set_lines(target_buf, cur_row - 1, cur_row, false, { new_line })
    end)
  else
    local old_mod = vim.bo[target_buf].modifiable
    vim.bo[target_buf].modifiable = true
    vim.api.nvim_buf_set_lines(target_buf, cur_row - 1, cur_row, false, { new_line })
    vim.bo[target_buf].modifiable = old_mod
  end

  local new_col = #prefix + #it.insert_text
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    pcall(vim.api.nvim_win_set_cursor, target_win, { cur_row, new_col })
  end

  local should_process = false
  if is_enter then
    if data.type == "command" then
      if M.is_control(it.label) then
        if it.label ~= "/add-dir" and it.label ~= "/drop" and it.label ~= "/artifacts" then
          should_process = true
        end
      end
    elseif data.type == "arg" then
      if data.cmd and M.is_control(data.cmd) then
        should_process = true
      end
    end
  end

  if should_process then
    M.close()
    vim.cmd("stopinsert")
    if protocol and protocol.handle_write then
      protocol.handle_write(target_buf)
    end
    return true
  end

  if (is_enter and (data.type == "arg" or not it.arg_type)) or data.type == "file" or data.type == "mention" then
    M.close()
  else
    -- Refresh completions for newly accepted input
    local next_data = M.get_completions(new_line, new_col, nil, data.workspaces)
    if next_data and #next_data.items > 0 then
      M.show(target_win, target_buf, next_data)
    else
      M.close()
    end
  end
  return true
end

---Handler for TextChangedI in an agy buffer
---@param buf number
function M.on_text_changed(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then return end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(win)[2]

  local workspaces = nil
  local protocol = package.loaded["agy.protocol"]
  if protocol and protocol.buffers and protocol.buffers[buf] then
    local state = protocol.buffers[buf]
    if state.session and state.session.workspaces and #state.session.workspaces > 0 then
      workspaces = state.session.workspaces
    elseif state.session and state.session.cwd then
      workspaces = { state.session.cwd }
    end
  end

  local data = M.get_completions(line, col, nil, workspaces)
  if data and #data.items > 0 then
    M.show(win, buf, data)
  else
    M.close()
  end
end

---Handler for CursorMovedI in an agy buffer
---@param buf number
---@param prompt_start_line number
function M.on_cursor_moved(buf, prompt_start_line)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then return end

  local cur_pos = vim.api.nvim_win_get_cursor(win)
  local cur_line = cur_pos[1]
  if cur_line < prompt_start_line then
    M.close()
    return
  end

  local line = vim.api.nvim_get_current_line()
  local col = cur_pos[2]

  local workspaces = nil
  local protocol = package.loaded["agy.protocol"]
  if protocol and protocol.buffers and protocol.buffers[buf] then
    local state = protocol.buffers[buf]
    if state.session and state.session.workspaces and #state.session.workspaces > 0 then
      workspaces = state.session.workspaces
    elseif state.session and state.session.cwd then
      workspaces = { state.session.cwd }
    end
  end

  local data = M.get_completions(line, col, nil, workspaces)
  if data and #data.items > 0 then
    M.show(win, buf, data)
  else
    M.close()
  end
end

---Native completefunc / omnifunc fallback for Antigravity slash commands
---@param findstart number 1 to find start column, 0 to return matching candidates
---@param base string Text to complete
---@return number|table
function M.completefunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)

    local slash_pos = before:match(".*()/[%w_-]*$")
    if not slash_pos then
      return -3
    end

    if slash_pos > 1 then
      local prev = before:sub(slash_pos - 1, slash_pos - 1)
      if not prev:match("%s") then
        return -3
      end
      -- Check if line starts with a one-off command (no chaining allowed)
      local first_cmd = before:match("^%s*(/[%w_-]+)")
      if first_cmd and M.is_one_off(first_cmd) then
        return -3
      end
    end

    return slash_pos - 1
  else
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local slash_pos = before:match(".*()/[%w_-]*$") or 1
    local is_chained = (slash_pos > 1)

    local query = base:lower()
    local matches = {}
    for _, cmd in ipairs(M.COMMANDS) do
      if (not is_chained or not M.is_one_off(cmd.name)) and cmd.name:lower():find(query, 1, true) then
        table.insert(matches, {
          word = cmd.name,
          abbr = cmd.name,
          menu = "[agy] " .. cmd.desc,
          info = cmd.name .. "\n\n" .. cmd.desc,
          icase = 1,
          dup = 0,
        })
      end
    end
    return matches
  end
end

---Setup slash command autocompletion and syntax highlight in an agy buffer
---@param buf number
function M.setup_buffer(buf)
  vim.bo[buf].completefunc = "v:lua.require'agy.completion'.completefunc"
  vim.bo[buf].omnifunc = "v:lua.require'agy.completion'.completefunc"

  -- Define buffer syntax match for slash commands and @ file mentions
  pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd([=[
        syntax match AgySlashCommand "\v(^|\s)\zs\/[a-zA-Z0-9_-]+" containedin=ALL
        syntax match AgyMention "\v(^|\s|[-.,:;!?()[\]{}'"`])\zs\@[a-zA-Z0-9_./\\-]+" containedin=ALL
        syntax match AgyMention "\v(^|\s|[-.,:;!?()[\]{}'"`])\zs\@\[[^\]]+\]" containedin=ALL
      ]=])
    end)
  end)

  -- Autocommands to trigger completion as user types
  local group = vim.api.nvim_create_augroup("AgyCompletion_" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = buf,
    callback = function()
      M.on_text_changed(buf)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    buffer = buf,
    callback = function()
      local protocol = require("agy.protocol")
      local state = protocol.buffers[buf]
      local prompt_start = (state and state.prompt_start_line) or 1
      M.on_cursor_moved(buf, prompt_start)
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.close()
    end,
  })

  -- Keybindings in insert mode: navigate or fallback natively
  vim.keymap.set("i", "<Down>", function()
    if M.is_visible() then
      M.select_next()
    else
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      local line_count = vim.api.nvim_buf_line_count(buf)
      if cur[1] < line_count then
        local next_line = vim.api.nvim_buf_get_lines(buf, cur[1], cur[1] + 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { cur[1] + 1, math.min(cur[2], #next_line) })
      end
    end
  end, { buffer = buf, silent = true, desc = "Navigate completion down" })

  vim.keymap.set("i", "<Up>", function()
    if M.is_visible() then
      M.select_prev()
    else
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      local prompt_start = 1
      local protocol = package.loaded["agy.protocol"]
      if protocol and protocol.buffers and protocol.buffers[buf] then
        prompt_start = protocol.buffers[buf].prompt_start_line or 1
      end
      if cur[1] > prompt_start then
        local prev_line = vim.api.nvim_buf_get_lines(buf, cur[1] - 2, cur[1] - 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { cur[1] - 1, math.min(cur[2], #prev_line) })
      end
    end
  end, { buffer = buf, silent = true, desc = "Navigate completion up" })

  vim.keymap.set("i", "<C-n>", function()
    if M.is_visible() then
      M.select_next()
    else
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      local line_count = vim.api.nvim_buf_line_count(buf)
      if cur[1] < line_count then
        local next_line = vim.api.nvim_buf_get_lines(buf, cur[1], cur[1] + 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { cur[1] + 1, math.min(cur[2], #next_line) })
      end
    end
  end, { buffer = buf, silent = true, desc = "Navigate completion down" })

  vim.keymap.set("i", "<C-p>", function()
    if M.is_visible() then
      M.select_prev()
    else
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      local prompt_start = 1
      local protocol = package.loaded["agy.protocol"]
      if protocol and protocol.buffers and protocol.buffers[buf] then
        prompt_start = protocol.buffers[buf].prompt_start_line or 1
      end
      if cur[1] > prompt_start then
        local prev_line = vim.api.nvim_buf_get_lines(buf, cur[1] - 2, cur[1] - 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { cur[1] - 1, math.min(cur[2], #prev_line) })
      end
    end
  end, { buffer = buf, silent = true, desc = "Navigate completion up" })

  vim.keymap.set("i", "<Tab>", function()
    if M.is_visible() then
      M.accept(false)
      return
    end
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.keycode("<C-n>"), "n", false)
      return
    end
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    if before:match("^/[%w_-]*$") or before:match("%s/[%w_-]*$") then
      vim.api.nvim_feedkeys(vim.keycode("<C-x><C-u>"), "n", false)
      return
    end
    vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "n", false)
  end, { buffer = buf, silent = true, desc = "Autocomplete or Tab" })

  vim.keymap.set("i", "<S-Tab>", function()
    if M.is_visible() then
      M.select_prev()
      return
    end
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.keycode("<C-p>"), "n", false)
      return
    end
    vim.api.nvim_feedkeys(vim.keycode("<S-Tab>"), "n", false)
  end, { buffer = buf, silent = true, desc = "Previous completion item or S-Tab" })

  vim.keymap.set("i", "<CR>", function()
    if M.is_visible() then
      M.accept(true)
      return
    end

    local line = vim.api.nvim_get_current_line()
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    local first_token = trimmed:match("^(%S+)")
    if first_token and first_token:match("^/") and M.is_control(first_token) then
      local protocol = package.loaded["agy.protocol"]
      if protocol and protocol.handle_write then
        protocol.handle_write(buf)
        return
      end
    end

    local win = vim.api.nvim_get_current_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    local left = line:sub(1, cur[2])
    local right = line:sub(cur[2] + 1)
    vim.api.nvim_buf_set_lines(buf, cur[1] - 1, cur[1], false, { left, right })
    vim.api.nvim_win_set_cursor(win, { cur[1] + 1, 0 })
  end, { buffer = buf, silent = true, desc = "Select completion item, execute control command, or Enter" })

  vim.keymap.set("i", "<Esc>", function()
    if M.is_visible() then
      M.close()
      return
    end
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
  end, { buffer = buf, silent = true, desc = "Close completion or Esc" })

  vim.keymap.set("i", "<C-c>", function()
    if M.is_visible() then
      M.close()
      return
    end
    local protocol = package.loaded["agy.protocol"]
    local state = protocol and protocol.buffers and protocol.buffers[buf]
    local is_turn_running = state and ((state.session and state.session.turn_active) or state.active_question or state.agent_extmark_id or (state.stream_info and state.stream_info.status ~= "ready"))
    if is_turn_running then
      pcall(vim.cmd, "stopinsert")
      protocol.stop_turn(buf)
      return
    end
    vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "n", false)
  end, { buffer = buf, silent = true, desc = "Close completion or C-c" })
end

-- Kick off background model prefetching on load
M.prefetch_models()

return M
