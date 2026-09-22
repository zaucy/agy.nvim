local utils = require("agy.utils")
local transcript = require("agy.transcript")
local render = require("agy.render")
local config_mod = require("agy.config")

local M = {}

M.NS_HOME = vim.api.nvim_create_namespace("agy_home")

---@type table<number, table<number, table>>
M.buffer_actions = {}

---Check if two file paths are equivalent, handling slashes and platform casing
---@param p1? string
---@param p2? string
---@return boolean
function M.path_equals(p1, p2)
  if not p1 or not p2 or p1 == "" or p2 == "" then
    return false
  end
  local norm1 = vim.fs.normalize(p1):gsub("[/\\]+$", "")
  local norm2 = vim.fs.normalize(p2):gsub("[/\\]+$", "")
  if vim.fn.has("win32") == 1 then
    return norm1:lower() == norm2:lower()
  else
    return norm1 == norm2
  end
end

---Get all resumable conversations whose recorded workspace equals the target directory
---@param cwd? string Target workspace directory (defaults to vim.fn.getcwd())
---@param app_data_dir? string
---@return AgyConversationSummary[]
function M.get_workspace_conversations(cwd, app_data_dir)
  local target_cwd = cwd or vim.fn.getcwd()
  local all = transcript.read_history(app_data_dir)
  local matches = {}
  for _, item in ipairs(all) do
    if item.workspace and item.workspace ~= "" and M.path_equals(item.workspace, target_cwd) then
      table.insert(matches, item)
    end
  end
  return matches
end

---Get all resumable conversations asynchronously with cooperative yielding
---@param cwd? string Target workspace directory (defaults to vim.fn.getcwd())
---@param app_data_dir? string
---@return AgyConversationSummary[]
function M.get_workspace_conversations_async(cwd, app_data_dir)
  local async = require("agy.async")
  local target_cwd = cwd or vim.fn.getcwd()
  local all = transcript.read_history(app_data_dir)
  local matches = {}
  for i, item in ipairs(all) do
    if i % 20 == 0 then
      async.checkpoint()
    end
    if item.workspace and item.workspace ~= "" and M.path_equals(item.workspace, target_cwd) then
      table.insert(matches, item)
    end
  end
  return matches
end

---Render the root agy:// home buffer
---@param buf number
---@param config? table
---@param cwd? string
function M.render_home(buf, config, cwd)
  assert(buf and vim.api.nvim_buf_is_valid(buf), "agy home: valid buffer required")

  local cfg = config or config_mod.get()
  assert(cfg, "agy home: config required")
  assert(cfg.icons, "agy home: config.icons required")
  local new_icon = cfg.icons.new_session
  assert(new_icon, "agy home: config.icons.new_session required")
  local conv_icon = cfg.icons.conversation
  assert(conv_icon, "agy home: config.icons.conversation required")
  assert(cfg.icons.table and cfg.icons.table.horizontal, "agy home: config.icons.table.horizontal required")
  local horiz = cfg.icons.table.horizontal

  local target_cwd = cwd or vim.fn.getcwd()
  local conversations = M.get_workspace_conversations(target_cwd, cfg.app_data_dir)

  -- Prefetch models asynchronously in background so next session open is instantaneous
  pcall(function() require("agy.completion").prefetch_models(cfg.agy_cmd) end)

  vim.api.nvim_buf_clear_namespace(buf, M.NS_HOME, 0, -1)
  render.setup_highlights()

  local header_style = (cfg.ui and cfg.ui.header_style) or "banner"
  local lines = {}

  if header_style == "banner" then
    local banner = render.build_banner_lines("agy://", cfg, "Workspace: " .. target_cwd)
    for i = 1, 7 do
      table.insert(lines, banner[i])
    end
  else
    table.insert(lines, "# Antigravity Home (agy://)")
    table.insert(lines, "Workspace: " .. target_cwd)
    table.insert(lines, "")
  end

  local line_actions = {}

  -- Entry 1: agy://new
  local new_line_idx = #lines + 1
  local new_tag = "[agy://new]"
  local new_desc = "Start a fresh conversation"
  local new_line_str = string.format("  %s%-13s %s", new_icon, new_tag, new_desc)
  table.insert(lines, new_line_str)
  line_actions[new_line_idx] = { type = "new" }

  table.insert(lines, "")

  -- Section Header: Recent Conversations
  local conv_count = #conversations
  local section_title = string.format("  Recent Conversations (%d)", conv_count)
  table.insert(lines, section_title)
  local section_line_idx = #lines

  local divider = "  " .. string.rep(horiz, 60)
  table.insert(lines, divider)
  local divider_line_idx = #lines

  -- List conversations or empty state
  local conv_rows = {}
  local empty_rows = {}
  if conv_count == 0 then
    local empty1 = "  No past conversations found for this workspace."
    local empty2 = "  Press <CR> on [agy://new] above to start a conversation."
    table.insert(lines, empty1)
    table.insert(empty_rows, #lines)
    table.insert(lines, empty2)
    table.insert(empty_rows, #lines)
  else
    for _, item in ipairs(conversations) do
      local short_id = item.conversation_id:sub(1, 8)
      local id_tag = "[" .. short_id .. "]"
      local first_line = item.title:match("^[^\r\n]+") or item.title
      if #first_line > 65 then
        first_line = first_line:sub(1, 62) .. "..."
      end
      local row_line_idx = #lines + 1
      local conv_str = string.format("  %s%-13s %-10s %s", conv_icon, id_tag, item.relative_time, first_line)
      table.insert(lines, conv_str)
      line_actions[row_line_idx] = { type = "conversation", conversation_id = item.conversation_id }
      table.insert(conv_rows, {
        line = row_line_idx,
        icon_len = #conv_icon,
        id_tag = id_tag,
        rel_time = item.relative_time,
        title = first_line,
      })
    end
  end

  -- Help Footer
  table.insert(lines, "")
  table.insert(lines, divider)
  local footer_div_idx = #lines
  local hint_str = "  <CR>: open / resume  │  q: close  │  r: reload"
  table.insert(lines, hint_str)
  local hint_line_idx = #lines

  -- Set buffer properties and lines
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "agy"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modified = false

  -- Apply banner extmarks and animation
  if header_style == "banner" then
    render.render_banner_extmarks(buf, "agy://", cfg, "Workspace: " .. target_cwd)
    render.start_logo_animation(buf, cfg)
  end

  -- Apply NS_HOME extmarks
  -- agy://new line
  local new_row = new_line_idx - 1
  local new_tag_start = 2 + #new_icon
  local new_tag_end = new_tag_start + #new_tag
  vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, new_row, 2, {
    end_col = 2 + #new_icon,
    hl_group = "AgyReviewComment",
    priority = 100,
  })
  vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, new_row, new_tag_start, {
    end_col = new_tag_end,
    hl_group = "AgyHeaderTitle",
    priority = 100,
  })
  vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, new_row, new_tag_end, {
    end_col = #new_line_str,
    hl_group = "Comment",
    priority = 100,
  })

  -- Section title
  vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, section_line_idx - 1, 2, {
    end_col = #section_title,
    hl_group = "AgyHeaderTitle",
    priority = 100,
  })

  -- Dividers
  vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, divider_line_idx - 1, 2, {
    end_col = #divider,
    hl_group = "AgyTableBorder",
    priority = 100,
  })
  vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, footer_div_idx - 1, 2, {
    end_col = #divider,
    hl_group = "AgyTableBorder",
    priority = 100,
  })

  -- Hints
  vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, hint_line_idx - 1, 2, {
    end_col = #hint_str,
    hl_group = "Comment",
    priority = 100,
  })

  -- Empty state highlights
  for _, er in ipairs(empty_rows) do
    vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, er - 1, 2, {
      end_col = #lines[er],
      hl_group = "Comment",
      priority = 100,
    })
  end

  -- Conversation rows highlights
  for _, cr in ipairs(conv_rows) do
    local r = cr.line - 1
    local col = 2
    -- conv_icon
    vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, r, col, {
      end_col = col + cr.icon_len,
      hl_group = "AgyReviewComment",
      priority = 100,
    })
    col = col + cr.icon_len
    -- id_tag
    vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, r, col, {
      end_col = col + #cr.id_tag,
      hl_group = "Identifier",
      priority = 100,
    })
    -- spaces + rel_time
    local rel_pos = lines[cr.line]:find(cr.rel_time, col, true)
    if rel_pos then
      vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, r, rel_pos - 1, {
        end_col = rel_pos - 1 + #cr.rel_time,
        hl_group = "Comment",
        priority = 100,
      })
      local title_pos = lines[cr.line]:find(cr.title, rel_pos + #cr.rel_time, true)
      if title_pos then
        vim.api.nvim_buf_set_extmark(buf, M.NS_HOME, r, title_pos - 1, {
          end_col = title_pos - 1 + #cr.title,
          hl_group = "Normal",
          priority = 100,
        })
      end
    end
  end

  -- Record actions for keymap dispatch
  M.buffer_actions[buf] = line_actions

  -- Window options and cursor positioning
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    pcall(function()
      vim.wo[win].cursorline = true
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].wrap = false
      vim.api.nvim_win_set_cursor(win, { new_line_idx, 2 })
    end)
  end

  -- Set buffer keymaps
  vim.keymap.set("n", "<CR>", function()
    local cur_win = vim.api.nvim_get_current_win()
    local cur_line = vim.api.nvim_win_get_cursor(cur_win)[1]
    local actions = M.buffer_actions[buf] or {}
    local action = actions[cur_line]
    if action then
      if action.type == "new" then
        vim.cmd("edit agy://new")
      elseif action.type == "conversation" then
        vim.cmd("edit agy://" .. action.conversation_id)
      end
    elseif cur_line <= new_line_idx then
      vim.cmd("edit agy://new")
    end
  end, { buffer = buf, silent = true, desc = "Open selected conversation or start new" })

  vim.keymap.set("n", "-", function()
    vim.notify("[agy.nvim] Already at agy root", vim.log.levels.INFO)
  end, { buffer = buf, silent = true, desc = "Already at agy root" })

  vim.keymap.set("n", "q", function()
    if #vim.api.nvim_list_wins() > 1 then
      vim.cmd("close")
    else
      vim.cmd("bdelete")
    end
  end, { buffer = buf, silent = true, desc = "Close agy home buffer" })

  vim.keymap.set("n", "r", function()
    M.render_home(buf, cfg, target_cwd)
    vim.notify("[agy.nvim] Home refreshed", vim.log.levels.INFO)
  end, { buffer = buf, silent = true, desc = "Refresh agy home buffer" })
end

return M
