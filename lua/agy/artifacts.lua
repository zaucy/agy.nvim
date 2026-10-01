local utils = require("agy.utils")
local config_mod = require("agy.config")

local M = {}

M.NS_COMMENTS = vim.api.nvim_create_namespace("agy_artifact_comments")
M.NS_FOOTER = vim.api.nvim_create_namespace("agy_artifact_footer")

---In-memory cache for pending review comments
---Key: `conv_id .. ":" .. filename`
---Value: table<number, { text: string, start_line: number, end_line: number }>
M.comments = {}

---Get comments key
---@param conv_id string
---@param filename string
---@return string
local function get_key(conv_id, filename)
  assert(conv_id and conv_id ~= "", "agy artifacts: conv_id is required")
  assert(filename and filename ~= "", "agy artifacts: filename is required")
  return conv_id .. ":" .. filename
end

---Retrieve all cached comments for an artifact
---@param conv_id string
---@param filename string
---@return table<number, { text: string, start_line: number, end_line: number }>
function M.get_comments(conv_id, filename)
  local key = get_key(conv_id, filename)
  return M.comments[key] or {}
end

---Check whether an artifact has unsubmitted comments
---@param conv_id string
---@param filename string
---@return boolean
function M.has_unsaved_comments(conv_id, filename)
  local c = M.get_comments(conv_id, filename)
  return next(c) ~= nil
end

---Get total count of unsubmitted comments for an artifact
---@param conv_id string
---@param filename string
---@return number
function M.get_comments_count(conv_id, filename)
  local c = M.get_comments(conv_id, filename)
  local count = 0
  for _ in pairs(c) do
    count = count + 1
  end
  return count
end

---Clear cached comments for an artifact
---@param conv_id string
---@param filename string
function M.clear_comments(conv_id, filename)
  local key = get_key(conv_id, filename)
  M.comments[key] = nil
end

---Set or update a comment for an artifact
---@param conv_id string
---@param filename string
---@param start_line number
---@param end_line number
---@param text string
function M.set_comment(conv_id, filename, start_line, end_line, text)
  assert(start_line and start_line >= 1, "agy artifacts: start_line must be >= 1")
  end_line = end_line or start_line
  assert(end_line >= start_line, "agy artifacts: end_line must be >= start_line")
  local key = get_key(conv_id, filename)
  if not M.comments[key] then
    M.comments[key] = {}
  end
  M.comments[key][start_line] = {
    text = text,
    start_line = start_line,
    end_line = end_line,
  }
end

---Delete comment covering line
---@param conv_id string
---@param filename string
---@param line number
---@return boolean deleted
function M.delete_comment(conv_id, filename, line)
  local key = get_key(conv_id, filename)
  local c = M.comments[key]
  if not c then return false end

  local deleted = false
  for start_line, item in pairs(c) do
    if (line >= item.start_line and line <= item.end_line) or line == start_line then
      c[start_line] = nil
      deleted = true
      break
    end
  end
  if next(c) == nil then
    M.comments[key] = nil
  end
  return deleted
end

---Discover all artifacts for a given conversation from disk
---@param conv_id string
---@param app_data_dir? string
---@return table[] artifacts
function M.get_artifacts(conv_id, app_data_dir)
  assert(conv_id and conv_id ~= "", "agy artifacts: conv_id is required")
  if conv_id == "new" then
    return {}
  end

  local cfg = config_mod.get()
  local dir = app_data_dir or cfg.app_data_dir or utils.get_app_data_dir()
  assert(dir and dir ~= "", "agy artifacts: app_data_dir is required")

  local brain_dir = vim.fs.joinpath(dir, "brain", conv_id)
  if vim.fn.isdirectory(brain_dir) ~= 1 then
    return {}
  end

  local artifacts = {}
  local excluded_dirs = {
    [".system_generated"] = true,
    [".user_uploaded"] = true,
    ["scratch"] = true,
  }

  local ok, entries = pcall(function()
    local res = {}
    for name, type in vim.fs.dir(brain_dir) do
      if type == "file" and not name:match("%.metadata%.json$") and not name:match("^%.") then
        table.insert(res, name)
      end
    end
    return res
  end)

  if not ok or not entries then
    return {}
  end

  for _, name in ipairs(entries) do
    local full_path = vim.fs.joinpath(brain_dir, name)
    local stat = vim.uv.fs_stat(full_path)
    local meta_path = full_path .. ".metadata.json"
    local meta = nil

    if vim.fn.filereadable(meta_path) == 1 then
      local meta_content = vim.fn.readfile(meta_path)
      if meta_content and #meta_content > 0 then
        local raw_json = table.concat(meta_content, "\n")
        local dec_ok, parsed = pcall(vim.json.decode, raw_json)
        if dec_ok and type(parsed) == "table" then
          meta = parsed
        end
      end
    end

    local mtime = stat and stat.mtime and stat.mtime.sec or 0
    table.insert(artifacts, {
      filename = name,
      full_path = full_path,
      mtime = mtime,
      summary = meta and meta.summary,
      updated_at = meta and meta.updatedAt,
      request_feedback = meta and meta.requestFeedback or false,
      user_facing = meta and (meta.userFacing ~= false) or true,
    })
  end

  table.sort(artifacts, function(a, b)
    return a.mtime > b.mtime
  end)

  return artifacts
end

---Get the latest artifact for a conversation
---@param conv_id string
---@param app_data_dir? string
---@return table|nil
function M.get_latest_artifact(conv_id, app_data_dir)
  local arts = M.get_artifacts(conv_id, app_data_dir)
  return arts[1]
end

---Refresh virtual lines rendering of pending comments in buffer
---@param buf number
---@param conv_id string
---@param filename string
---@param config? table
function M.refresh_comment_extmarks(buf, conv_id, filename, config)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, M.NS_COMMENTS, 0, -1)

  local cfg = config or config_mod.get()
  assert(cfg, "agy artifacts: config required")
  assert(cfg.icons, "agy artifacts: config.icons required")
  local icon = cfg.icons.review_comment
  assert(icon, "agy artifacts: config.icons.review_comment is required")

  local comments = M.get_comments(conv_id, filename)
  local line_count = vim.api.nvim_buf_line_count(buf)

  -- Sort keys to maintain consistent extmark ordering
  local sorted_keys = {}
  for start_line, _ in pairs(comments) do
    table.insert(sorted_keys, start_line)
  end
  table.sort(sorted_keys)

  for _, start_line in ipairs(sorted_keys) do
    local item = comments[start_line]
    local target_line = math.min(item.end_line or start_line, line_count)
    local row = math.max(0, target_line - 1)

    local line_label
    if item.start_line == item.end_line or not item.end_line then
      line_label = "L" .. tostring(item.start_line)
    else
      line_label = "L" .. tostring(item.start_line) .. "-L" .. tostring(item.end_line)
    end

    local comment_chunks = {
      { "  " .. icon .. " " .. line_label .. ": ", "AgyReviewComment" },
      { item.text, "AgyReviewComment" },
    }

    vim.api.nvim_buf_set_extmark(buf, M.NS_COMMENTS, row, 0, {
      virt_lines = { comment_chunks },
      virt_lines_above = false,
      priority = 200,
    })
  end
end

---Render bottom virtual text footer with keymap hints and pending comment counter
---@param buf number
---@param conv_id string
---@param filename string
---@param config? table
function M.render_footer(buf, conv_id, filename, config)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, M.NS_FOOTER, 0, -1)

  local cfg = config or config_mod.get()
  assert(cfg, "agy artifacts: config required")
  assert(cfg.icons, "agy artifacts: config.icons required")
  local comment_icon = cfg.icons.review_comment
  assert(comment_icon, "agy artifacts: config.icons.review_comment required")

  local count = M.get_comments_count(conv_id, filename)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local last_row = math.max(0, line_count - 1)

  local chunks = {}
  if count > 0 then
    local count_str = string.format(" %s %d pending comment%s  │  ", comment_icon, count, count > 1 and "s" or "")
    table.insert(chunks, { count_str, "AgyBadgeTool" })
    table.insert(chunks, { "c Comment · dc Delete comment · :w Submit review · - Back", "AgyPromptFooter" })
  else
    table.insert(chunks, { "c Comment · :w Approve · - Back", "AgyPromptFooter" })
  end

  vim.api.nvim_buf_set_extmark(buf, M.NS_FOOTER, last_row, 0, {
    virt_lines = { chunks },
    virt_lines_above = false,
    priority = 100,
  })
end

---Prompt user to add or edit a review comment on cursor or selection line
---@param buf number
---@param conv_id string
---@param filename string
function M.prompt_add_comment(buf, conv_id, filename)
  assert(buf and vim.api.nvim_buf_is_valid(buf), "agy artifacts: valid buffer required")
  local mode = vim.fn.mode()
  local is_visual = (mode:find("^[vV\x16]") ~= nil)

  local start_line, end_line
  if is_visual then
    local v_pos = vim.fn.getpos("v")[2]
    local cur_pos = vim.api.nvim_win_get_cursor(0)[1]
    start_line = math.min(v_pos, cur_pos)
    end_line = math.max(v_pos, cur_pos)
    -- Exit visual mode
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  else
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
  end

  local comments = M.get_comments(conv_id, filename)
  local existing = comments[start_line]
  local default_text = existing and existing.text or ""

  local prompt_label = (start_line == end_line)
      and string.format("Review Comment (L%d): ", start_line)
      or string.format("Review Comment (L%d-L%d): ", start_line, end_line)

  vim.ui.input({
    prompt = prompt_label,
    default = default_text,
  }, function(input)
    if input == nil then
      return
    end

    local trimmed = vim.trim(input)
    if trimmed == "" then
      if existing then
        M.delete_comment(conv_id, filename, start_line)
      end
    else
      M.set_comment(conv_id, filename, start_line, end_line, trimmed)
    end

    if vim.api.nvim_buf_is_valid(buf) then
      M.refresh_comment_extmarks(buf, conv_id, filename)
      M.render_footer(buf, conv_id, filename)
      local has_any = M.has_unsaved_comments(conv_id, filename)
      vim.bo[buf].modified = has_any
    end
  end)
end

---Delete comment on cursor line
---@param buf number
---@param conv_id string
---@param filename string
function M.delete_comment_at_cursor(buf, conv_id, filename)
  assert(buf and vim.api.nvim_buf_is_valid(buf), "agy artifacts: valid buffer required")
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local deleted = M.delete_comment(conv_id, filename, cur_line)
  if deleted then
    M.refresh_comment_extmarks(buf, conv_id, filename)
    M.render_footer(buf, conv_id, filename)
    local has_any = M.has_unsaved_comments(conv_id, filename)
    vim.bo[buf].modified = has_any
    vim.notify(string.format("[agy.nvim] Deleted review comment on line %d", cur_line), vim.log.levels.INFO)
  else
    vim.notify("[agy.nvim] No review comment found on this line.", vim.log.levels.WARN)
  end
end

---Navigate up one level from artifact review buffer back to conversation buffer
---@param buf number
---@param conv_id string
function M.go_up(buf, conv_id)
  assert(conv_id and conv_id ~= "", "agy artifacts: conv_id is required")
  vim.cmd("edit agy://" .. conv_id)
end

---Submit review comments to agent and switch back to conversation
---@param buf number
---@param conv_id string
---@param filename string
---Submit review comments or approval to agent and switch back to conversation
---@param buf number
---@param conv_id string
---@param filename string
function M.submit_review(buf, conv_id, filename)
  assert(conv_id and conv_id ~= "", "agy artifacts: conv_id is required")
  assert(filename and filename ~= "", "agy artifacts: filename is required")

  local comments = M.get_comments(conv_id, filename)
  local payload
  if next(comments) == nil then
    payload = "Approved " .. filename
    vim.notify(string.format("[agy.nvim] Approved %s", filename), vim.log.levels.INFO)
  else
    -- Sort comments by line number
    local sorted_lines = {}
    for line, _ in pairs(comments) do
      table.insert(sorted_lines, line)
    end
    table.sort(sorted_lines)

    local payload_lines = {
      "Review comments on " .. filename .. ":",
    }

    for _, line in ipairs(sorted_lines) do
      local item = comments[line]
      local line_ref
      if item.start_line == item.end_line or not item.end_line then
        line_ref = "L" .. tostring(item.start_line)
      else
        line_ref = "L" .. tostring(item.start_line) .. "-L" .. tostring(item.end_line)
      end
      table.insert(payload_lines, string.format("%s: %s", line_ref, item.text))
    end

    payload = table.concat(payload_lines, "\n")
  end

  -- Clear in-memory comments for this artifact
  M.clear_comments(conv_id, filename)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modified = false
  end

  -- Find conversation session in protocol.buffers
  local protocol = require("agy.protocol")
  local target_session = nil
  local target_buf = nil

  for b, state in pairs(protocol.buffers) do
    if state.conversation_id == conv_id and not state.is_artifact and not state.is_home then
      target_session = state.session
      target_buf = b
      break
    end
  end

  -- Switch current window to agy://<conv_id>
  vim.cmd("edit agy://" .. conv_id)

  local cur_buf = vim.api.nvim_get_current_buf()
  local conv_buf = (protocol.buffers[cur_buf] and not protocol.buffers[cur_buf].is_artifact and not protocol.buffers[cur_buf].is_home and cur_buf) or target_buf

  if conv_buf and protocol.buffers[conv_buf] then
    local state = protocol.buffers[conv_buf]
    state.pending_artifact_feedback = nil

    if state.active_question and state.active_question.ui then
      state.active_question.ui.close()
      state.active_question = nil
    end

    if not state.prompt_extmark_id or not state.prompt_start_line then
      local cur_count = vim.api.nvim_buf_line_count(conv_buf)
      state.prompt_start_line = cur_count
      state.prompt_extmark_id = require("agy.render").set_divider(conv_buf, cur_count - 1, "user", nil, nil, true, nil, state.config)
    end

    protocol.ensure_prompt_line(conv_buf)

    local utils_mod = require("agy.utils")
    local payload_lines = utils_mod.split_lines(payload)
    protocol.with_modifiable(conv_buf, function()
      local start = state.prompt_start_line or vim.api.nvim_buf_line_count(conv_buf)
      vim.api.nvim_buf_set_lines(conv_buf, start - 1, -1, false, payload_lines)
    end)

    protocol.submit_prompt(conv_buf)
  elseif target_session and target_session.send_prompt then
    target_session:send_prompt(payload)
  else
    vim.notify("[agy.nvim] Review submitted. Start conversation to dispatch.", vim.log.levels.INFO)
  end
end

---Render an artifact file in pure document mode using stream markdown renderer
---@param buf number
---@param conv_id string
---@param filename string
---@param config? table
function M.render_artifact(buf, conv_id, filename, config)
  assert(buf and vim.api.nvim_buf_is_valid(buf), "agy artifacts: valid buffer required")
  assert(conv_id and conv_id ~= "", "agy artifacts: conv_id is required")
  assert(filename and filename ~= "", "agy artifacts: filename is required")

  local cfg = config or config_mod.get()
  assert(cfg, "agy artifacts: config required")
  assert(cfg.icons, "agy artifacts: config.icons required")
  assert(cfg.icons.review_comment, "agy artifacts: config.icons.review_comment required")

  local dir = cfg.app_data_dir or utils.get_app_data_dir()
  local file_path = vim.fs.joinpath(dir, "brain", conv_id, filename)

  if vim.fn.filereadable(file_path) ~= 1 then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# Error: Artifact not found",
      "",
      "File does not exist: `" .. file_path .. "`",
      "",
      "Press `-` to return to conversation.",
    })
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = false
    vim.keymap.set("n", "-", function()
      M.go_up(buf, conv_id)
    end, { buffer = buf, silent = true, desc = "Return to conversation" })
    return
  end

  local ok, file_lines = pcall(vim.fn.readfile, file_path)
  if not ok or not file_lines then
    file_lines = { "# Error reading artifact: " .. filename }
  end

  local full_text = table.concat(file_lines, "\n")

  -- Set buffer properties
  vim.bo[buf].modifiable = true
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  pcall(vim.treesitter.start, buf, "markdown")
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"

  -- Window options
  pcall(function()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.wo[win].wrap = cfg.ui.wrap
      vim.wo[win].linebreak = cfg.ui.linebreak
      vim.wo[win].conceallevel = (cfg.ui and cfg.ui.conceallevel ~= nil) and cfg.ui.conceallevel or 0
      vim.wo[win].concealcursor = ""
    end
  end)

  -- Render document starting at line 1 using stream markdown renderer
  local markdown_mod = require("agy.markdown")
  markdown_mod.render_document(buf, full_text, cfg)

  -- Display pending comments
  M.refresh_comment_extmarks(buf, conv_id, filename, cfg)

  -- Bottom virtual text footer
  M.render_footer(buf, conv_id, filename, cfg)

  -- Check if comments already exist in cache to set modified flag
  local has_unsaved = M.has_unsaved_comments(conv_id, filename)
  vim.bo[buf].modified = has_unsaved
  vim.bo[buf].modifiable = false

  -- Keymaps
  local comment_key = (cfg.keymaps and cfg.keymaps.comment) or "c"
  local del_key = (cfg.keymaps and cfg.keymaps.delete_comment) or "dc"
  local submit_key = (cfg.keymaps and cfg.keymaps.submit) or "<C-s>"

  vim.keymap.set({ "n", "x" }, comment_key, function()
    M.prompt_add_comment(buf, conv_id, filename)
  end, { buffer = buf, silent = true, desc = "Add/edit review comment on line" })

  vim.keymap.set("n", del_key, function()
    M.delete_comment_at_cursor(buf, conv_id, filename)
  end, { buffer = buf, silent = true, desc = "Delete review comment on line" })

  vim.keymap.set("n", "-", function()
    M.go_up(buf, conv_id)
  end, { buffer = buf, silent = true, desc = "Up one level to conversation" })

  if submit_key and submit_key ~= "" then
    vim.keymap.set({ "n", "i" }, submit_key, "<cmd>write<CR>", {
      buffer = buf,
      silent = true,
      desc = "Submit review comments",
    })
  end

  -- BufWriteCmd to submit comments
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.submit_review(buf, conv_id, filename)
    end,
  })
end

return M
