local utils = require("agy.utils")

local M = {}

---@class AgyMentionItem
---@field label string Display label in completion menu
---@field kind string Kind tag (e.g. "Diagnostics", "Buffer", "File", "Context")
---@field detail string Subtitle/detail info
---@field insert_text string Text to insert (e.g. "@diagnostics ", "@lua/agy/init.lua ")
---@field priority? number Custom sorting weight

---@class AgyMentionResolution
---@field raw string The matched mention string without '@' (e.g. "diagnostics", "lua/agy/init.lua")
---@field kind string Kind displayed in metadata (e.g. "Diagnostics", "Buffer", "File")
---@field content string Content block following the mention header
---@field alias? string Optional alias for mention resolution (e.g. normalized slash path)

---@class AgyMentionContext
---@field buf? number Current buffer
---@field win? number Current window
---@field workspaces string[] Active workspace roots
---@field last_active_buf? number Previously active buffer before switching to agy
---@field last_active_file? string Previously active file path
---@field last_active_pos? number[] Previously active cursor position [row, col]
---@field last_selection? table { text: string, file: string, line_start: number, line_end: number, ft?: string }

---@class AgyMentionProvider
---@field name string Unique provider identifier
---@field description? string Human-readable description
---@field priority? number Sorting priority (default: 50, higher runs first)
---@field complete fun(query: string, ctx: AgyMentionContext, has_bracket: boolean): AgyMentionItem[]
---@field resolve fun(raw_mention: string, ctx: AgyMentionContext): AgyMentionResolution|nil

---Registry of mention providers
M._providers = {}
---Sorted cache of providers by priority descending
M._sorted_providers = {}

---Last active buffer state outside agy buffers
M._last_active_buf = nil
M._last_active_file = nil
M._last_active_pos = nil
M._last_selection = nil

---Sort providers by priority descending
local function refresh_sorted_providers()
  local list = {}
  for _, p in pairs(M._providers) do
    table.insert(list, p)
  end
  table.sort(list, function(a, b)
    local pa = a.priority or 50
    local pb = b.priority or 50
    if pa ~= pb then
      return pa > pb
    end
    return a.name < b.name
  end)
  M._sorted_providers = list
end

---Register a mention provider (Public API)
---@param provider AgyMentionProvider
function M.register(provider)
  if not provider or not provider.name then
    error("[agy.nvim] register_mention requires a provider table with a 'name' field")
  end
  if type(provider.complete) ~= "function" then
    error(string.format("[agy.nvim] register_mention provider '%s' must have a 'complete' function", provider.name))
  end
  if type(provider.resolve) ~= "function" then
    error(string.format("[agy.nvim] register_mention provider '%s' must have a 'resolve' function", provider.name))
  end

  provider.priority = provider.priority or 50
  M._providers[provider.name] = provider
  refresh_sorted_providers()
end

---Unregister a mention provider by name (Public API)
---@param name string
function M.unregister(name)
  if name and M._providers[name] then
    M._providers[name] = nil
    refresh_sorted_providers()
  end
end

---Get a registered mention provider by name (Public API)
---@param name string
---@return AgyMentionProvider|nil
function M.get(name)
  return M._providers[name]
end

---List all registered mention providers (Public API)
---@return AgyMentionProvider[]
function M.list()
  return M._sorted_providers
end

---Track editor buffer changes to capture last active code buffer and visual selections
function M.track_active_editor()
  local cur_buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(cur_buf) then return end

  local ft = vim.bo[cur_buf].filetype
  local bt = vim.bo[cur_buf].buftype
  if ft == "agy" or ft == "agy_completion" or bt == "nofile" or bt == "acwrite" then
    return
  end

  M._last_active_buf = cur_buf
  local name = vim.api.nvim_buf_get_name(cur_buf)
  if name ~= "" then
    M._last_active_file = vim.fs.normalize(name)
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
      pcall(function()
        M._last_active_pos = vim.api.nvim_win_get_cursor(cur_win)
      end)
    end

    -- Capture visual marks if present for this buffer
    local vstart = vim.fn.getpos("'<")
    local vend = vim.fn.getpos("'>")
    if vstart and vend and vstart[2] > 0 and vend[2] >= vstart[2] then
      local start_line = vstart[2]
      local end_line = vend[2]
      local lines = vim.api.nvim_buf_get_lines(cur_buf, start_line - 1, end_line, false)
      if #lines > 0 then
        M._last_selection = {
          file = M._last_active_file,
          buf = cur_buf,
          line_start = start_line,
          line_end = end_line,
          text = table.concat(lines, "\n"),
          ft = ft,
        }
      end
    end
  end
end

---Build context for mention providers
---@param workspaces? string[]
---@param buf? number
---@param win? number
---@return AgyMentionContext
function M.build_context(workspaces, buf, win)
  local ws_list = workspaces
  if not ws_list or #ws_list == 0 then
    local protocol = package.loaded["agy.protocol"]
    if buf and protocol and protocol.buffers and protocol.buffers[buf] then
      local state = protocol.buffers[buf]
      if state.session and state.session.workspaces and #state.session.workspaces > 0 then
        ws_list = state.session.workspaces
      elseif state.session and state.session.cwd then
        ws_list = { state.session.cwd }
      end
    end
  end
  if not ws_list or #ws_list == 0 then
    ws_list = { vim.fn.getcwd() }
  end

  return {
    buf = buf or vim.api.nvim_get_current_buf(),
    win = win or vim.api.nvim_get_current_win(),
    workspaces = ws_list,
    last_active_buf = M._last_active_buf,
    last_active_file = M._last_active_file,
    last_active_pos = M._last_active_pos,
    last_selection = M._last_selection,
  }
end

---Gather completion candidates from all registered providers
---@param query string
---@param ctx AgyMentionContext
---@param has_bracket? boolean
---@return AgyMentionItem[]
function M.complete(query, ctx, has_bracket)
  local all_items = {}
  local seen = {}

  for _, provider in ipairs(M._sorted_providers) do
    local ok, items = pcall(provider.complete, query, ctx, has_bracket)
    if ok and items and type(items) == "table" then
      for _, it in ipairs(items) do
        if it.label and not seen[it.label] then
          seen[it.label] = true
          table.insert(all_items, it)
        end
      end
    end
  end

  return all_items
end

---Scan prompt text for mentions and compile <ADDITIONAL_METADATA> block
---@param prompt_text string
---@param ctx AgyMentionContext
---@return string full_prompt
function M.resolve(prompt_text, ctx)
  if not prompt_text or prompt_text == "" or not prompt_text:find("@") then
    return prompt_text
  end

  local resolved = {}
  local seen = {}

  -- Helper to resolve raw mention using registered providers
  local function resolve_item(raw_mention)
    if not raw_mention or raw_mention == "" or seen[raw_mention] then
      return
    end

    for _, provider in ipairs(M._sorted_providers) do
      local ok, res = pcall(provider.resolve, raw_mention, ctx)
      if ok and res and res.content then
        seen[raw_mention] = true
        table.insert(resolved, res)
        return
      end
    end
  end

  -- 1. Scan bracketed mentions: @[item]
  for mention in prompt_text:gmatch("@%[([^%]]+)%]") do
    resolve_item(mention)
  end

  -- 2. Scan unbracketed mentions: @item
  for mention in prompt_text:gmatch("@([%w_%-./\\:]+)") do
    resolve_item(mention)
  end

  if #resolved == 0 then
    return prompt_text
  end

  local lines = {
    "<ADDITIONAL_METADATA>",
    "The user has mentioned some items in the form @[ITEM]. Here is extra information about the items that were mentioned by the user, in the order that they appear:",
    "",
  }

  for _, r in ipairs(resolved) do
    table.insert(lines, string.format("@[%s] is a [%s]:", r.raw, r.kind or "Context"))
    table.insert(lines, r.content)
    if r.alias and r.alias ~= r.raw then
      table.insert(lines, "")
      table.insert(lines, string.format("@[%s] is a [%s]:", r.alias, r.kind or "Context"))
      table.insert(lines, r.content)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "</ADDITIONAL_METADATA>")

  return prompt_text .. "\n\n" .. table.concat(lines, "\n")
end

-- ============================================================================
-- BUILT-IN PROVIDER 1: Diagnostics (@diagnostics, @problems)
-- ============================================================================
local diagnostics_provider = {
  name = "diagnostics",
  description = "Active LSP diagnostics, errors, and warnings",
  priority = 90,
  complete = function(query, ctx)
    local q = (query or ""):lower()
    local triggers = { "diagnostics", "problems" }
    local items = {}

    -- Summary counts across workspace
    local all_diags = vim.diagnostic.get()
    local err_count = 0
    local warn_count = 0
    for _, d in ipairs(all_diags) do
      if d.severity == vim.diagnostic.severity.ERROR then
        err_count = err_count + 1
      elseif d.severity == vim.diagnostic.severity.WARN then
        warn_count = warn_count + 1
      end
    end
    local detail_summary = string.format("%d error(s), %d warning(s)", err_count, warn_count)

    for _, trig in ipairs(triggers) do
      if q == "" or trig:find(q, 1, true) == 1 or q:find(trig:sub(1, 4), 1, true) then
        table.insert(items, {
          label = trig,
          kind = "Diagnostics",
          detail = detail_summary,
          insert_text = "@" .. trig .. " ",
          priority = 95,
        })
      end
    end

    -- Also check if user typed diagnostics:<file> or problems:<file>
    if q:match("^diag") or q:match("^prob") then
      -- Suggest current buffer diagnostics if active
      if ctx.last_active_file then
        local short_name = utils.shorten_path(ctx.last_active_file, ctx.workspaces)
        table.insert(items, {
          label = "diagnostics:" .. short_name,
          kind = "Diagnostics",
          detail = "Diagnostics for " .. short_name,
          insert_text = "@diagnostics:" .. short_name .. " ",
          priority = 90,
        })
      end
    end

    return items
  end,
  resolve = function(raw, ctx)
    local target_file = nil
    if raw == "diagnostics" or raw == "problems" then
      -- All diagnostics across workspace
    elseif raw:match("^diagnostics:(.+)$") then
      target_file = raw:match("^diagnostics:(.+)$")
    elseif raw:match("^problems:(.+)$") then
      target_file = raw:match("^problems:(.+)$")
    else
      return nil
    end

    local diags = vim.diagnostic.get()
    local lines = {}

    local sev_names = {
      [vim.diagnostic.severity.ERROR] = "Error",
      [vim.diagnostic.severity.WARN] = "Warning",
      [vim.diagnostic.severity.INFO] = "Info",
      [vim.diagnostic.severity.HINT] = "Hint",
    }

    local matched_count = 0
    for _, d in ipairs(diags) do
      local bname = vim.api.nvim_buf_is_valid(d.bufnr) and vim.api.nvim_buf_get_name(d.bufnr) or ""
      local rel_name = (bname ~= "") and utils.shorten_path(bname, ctx.workspaces) or string.format("buf:%d", d.bufnr)

      local should_include = true
      if target_file and target_file ~= "" then
        local norm_target = vim.fs.normalize(target_file):lower()
        local norm_bname = vim.fs.normalize(bname):lower()
        local norm_rel = vim.fs.normalize(rel_name):lower()
        if not norm_bname:find(norm_target, 1, true) and not norm_rel:find(norm_target, 1, true) then
          should_include = false
        end
      end

      if should_include then
        matched_count = matched_count + 1
        local sev = sev_names[d.severity] or "Diagnostic"
        local source = d.source and string.format(" (%s)", d.source) or ""
        local msg = (d.message or ""):gsub("\r\n", " "):gsub("\n", " ")
        table.insert(lines, string.format("- %s:%d:%d: [%s]%s %s", rel_name, d.lnum + 1, d.col + 1, sev, source, msg))
        if matched_count >= 100 then
          table.insert(lines, "... (remaining diagnostics truncated)")
          break
        end
      end
    end

    local content
    if #lines == 0 then
      content = target_file
          and string.format("No active LSP diagnostics or errors found for '%s'.", target_file)
          or "No active LSP diagnostics or errors found in workspace."
    else
      content = table.concat(lines, "\n")
    end

    return {
      raw = raw,
      kind = "Diagnostics",
      content = content,
    }
  end,
}

-- ============================================================================
-- BUILT-IN PROVIDER 2: Selection / Cursor (@selection)
-- ============================================================================
local selection_provider = {
  name = "selection",
  description = "Active or previous code selection",
  priority = 80,
  complete = function(query, ctx)
    local q = (query or ""):lower()
    if q == "" or ("selection"):find(q, 1, true) == 1 or q:find("sel", 1, true) then
      local detail = "Last active visual code selection"
      if ctx.last_selection then
        local short_f = utils.shorten_path(ctx.last_selection.file, ctx.workspaces)
        detail = string.format("%s (lines %d-%d)", short_f, ctx.last_selection.line_start, ctx.last_selection.line_end)
      end
      return {
        {
          label = "selection",
          kind = "Selection",
          detail = detail,
          insert_text = "@selection ",
          priority = 85,
        }
      }
    end
    return {}
  end,
  resolve = function(raw, ctx)
    if raw ~= "selection" then
      return nil
    end

    local sel = ctx.last_selection
    if not sel or not sel.text or sel.text == "" then
      -- Fallback: inspect last active buffer and cursor pos
      if ctx.last_active_file and ctx.last_active_pos then
        local short_f = utils.shorten_path(ctx.last_active_file, ctx.workspaces)
        return {
          raw = "selection",
          kind = "Cursor",
          content = string.format("Cursor located at %s:%d:%d (no visual selection active).", short_f, ctx.last_active_pos[1], ctx.last_active_pos[2]),
        }
      end
      return {
        raw = "selection",
        kind = "Selection",
        content = "No active code selection captured.",
      }
    end

    local short_f = utils.shorten_path(sel.file, ctx.workspaces)
    local content = string.format(
      "File: %s (lines %d-%d):\n```%s\n%s\n```",
      short_f,
      sel.line_start,
      sel.line_end,
      sel.ft or "",
      sel.text
    )

    return {
      raw = "selection",
      kind = "Selection",
      content = content,
    }
  end,
}

-- ============================================================================
-- BUILT-IN PROVIDER 3: Open / Modified Buffers (@buffer, in-memory live text)
-- ============================================================================
local buffers_provider = {
  name = "buffers",
  description = "Open and modified in-memory editor buffers",
  priority = 70,
  complete = function(query, ctx)
    local raw_q = query or ""
    raw_q = raw_q:gsub("^@", ""):gsub("^%[", ""):gsub("%]$", "")
    local q = raw_q:lower():gsub("\\", "/")
    local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
    local user_sep = raw_q:find("\\") and "\\" or (is_win and "\\" or "/")

    local items = {}
    local bufs = vim.api.nvim_list_bufs()

    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
        local bt = vim.bo[b].buftype
        local ft = vim.bo[b].filetype
        if bt == "" and ft ~= "agy" and ft ~= "agy_completion" then
          local full_name = vim.api.nvim_buf_get_name(b)
          if full_name ~= "" then
            local is_mod = vim.bo[b].modified
            local rel_name = utils.shorten_path(full_name, ctx.workspaces)
            local norm_rel = vim.fs.normalize(rel_name)
            local norm_rel_lower = norm_rel:lower()

            local matches = false
            if q == "" or norm_rel_lower:find(q, 1, true) or q:find("buf", 1, true) then
              matches = true
            end

            if matches then
              local disp = (user_sep == "\\") and norm_rel:gsub("/", "\\") or norm_rel
              local mod_tag = is_mod and " [+]" or ""
              local detail = is_mod and "[+] Modified in-memory (unsaved)" or full_name
              table.insert(items, {
                label = disp .. mod_tag,
                kind = "Buffer",
                detail = detail,
                insert_text = (disp:find("%s") and ("@[" .. disp .. "] ") or ("@" .. disp .. " ")),
                priority = is_mod and 75 or 65,
              })
            end
          end
        end
      end
    end

    return items
  end,
  resolve = function(raw, ctx)
    local clean = raw:gsub('^["\']', ''):gsub('["\']$', '')
    clean = clean:gsub("^%./", ""):gsub("^%.\\", "")
    local norm = vim.fs.normalize(clean)
    local norm_lower = norm:lower()

    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
        local full_name = vim.api.nvim_buf_get_name(b)
        if full_name ~= "" then
          local b_norm = vim.fs.normalize(full_name)
          local b_rel = utils.shorten_path(b_norm, ctx.workspaces)

          if b_norm:lower() == norm_lower or b_rel:lower() == norm_lower or vim.fs.basename(b_norm):lower() == norm_lower then
            local is_mod = vim.bo[b].modified
            if is_mod then
              -- Include in-memory lines!
              local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
              local content = string.format(
                "%s\nStatus: Modified in-memory (unsaved)\nTotal lines: %d\n```%s\n%s\n```",
                b_norm,
                #lines,
                vim.bo[b].filetype or "",
                table.concat(lines, "\n")
              )
              return {
                raw = raw,
                kind = "Buffer",
                content = content,
                alias = (raw:find("\\") and raw:gsub("\\", "/") or nil),
              }
            else
              return {
                raw = raw,
                kind = "File",
                content = b_norm,
                alias = (raw:find("\\") and raw:gsub("\\", "/") or nil),
              }
            end
          end
        end
      end
    end

    return nil
  end,
}

-- ============================================================================
-- BUILT-IN PROVIDER 4: Workspace Files
-- ============================================================================
local files_provider = {
  name = "files",
  description = "Workspace files fuzzy matching",
  priority = 50,
  complete = function(query, ctx, has_bracket)
    local completion_mod = require("agy.completion")
    return completion_mod.complete_files(query, ctx.workspaces, has_bracket)
  end,
  resolve = function(raw, ctx)
    local clean = raw:gsub('^["\']', ''):gsub('["\']$', '')
    clean = clean:gsub("^%./", ""):gsub("^%.\\", "")
    local norm = vim.fs.normalize(clean)

    -- Check active workspaces
    for _, ws in ipairs(ctx.workspaces or {}) do
      local norm_ws = vim.fs.normalize(ws)
      local full = vim.fs.normalize(norm_ws .. "/" .. norm)
      local stat = vim.uv.fs_stat(full)
      if stat then
        return {
          raw = raw,
          kind = (stat.type == "directory") and "Directory" or "File",
          content = full,
          alias = (raw:find("\\") and raw:gsub("\\", "/") or nil),
        }
      end
    end

    -- Check if absolute path
    local stat = vim.uv.fs_stat(norm)
    if stat then
      return {
        raw = raw,
        kind = (stat.type == "directory") and "Directory" or "File",
        content = norm,
        alias = (raw:find("\\") and raw:gsub("\\", "/") or nil),
      }
    end

    return nil
  end,
}

-- Register built-ins
M.register(diagnostics_provider)
M.register(selection_provider)
M.register(buffers_provider)
M.register(files_provider)

-- Set up autocommands to track editor buffer state outside agy
local track_group = vim.api.nvim_create_augroup("AgyMentionTrack", { clear = true })
vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "ModeChanged" }, {
  group = track_group,
  callback = function()
    M.track_active_editor()
  end,
})

return M
