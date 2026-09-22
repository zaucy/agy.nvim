local M = {}

---Get the Antigravity application data directory
---Defaults to ~/.gemini/antigravity-cli or standard OS locations
---@param override_dir? string
---@return string
function M.get_app_data_dir(override_dir)
  if override_dir and override_dir ~= "" then
    return vim.fs.normalize(override_dir)
  end

  local home = vim.fs.normalize(vim.uv.os_homedir() or "~")
  local default_path = home .. "/.gemini/antigravity-cli"
  return vim.fs.normalize(default_path)
end

---Get the brain directory where conversation logs and artifacts are stored
---@param app_data_dir? string
---@return string
function M.get_brain_dir(app_data_dir)
  return M.get_app_data_dir(app_data_dir) .. "/brain"
end

---Get the active user account email from google_accounts.json or oauth tokens
---@param app_data_dir? string
---@return string? email
function M.get_account_email(app_data_dir)
  local home = vim.fs.normalize(vim.uv.os_homedir() or "~")
  local accounts_path = home .. "/.gemini/google_accounts.json"
  if vim.fn.filereadable(accounts_path) == 1 then
    local content = table.concat(vim.fn.readfile(accounts_path), "\n")
    local ok, data = pcall(vim.json.decode, content)
    if ok and data and data.active and data.active ~= "" then
      return data.active
    end
  end

  local token_path = home .. "/.gemini/jetski-standalone-oauth-token"
  if vim.fn.filereadable(token_path) == 1 then
    local content = table.concat(vim.fn.readfile(token_path), "\n")
    local email = content:match('"email"%s*:%s*"([^"]+)"')
    if email then
      return email
    end
  end

  return nil
end

---Get the history.jsonl file path
---@param app_data_dir? string
---@return string
function M.get_history_file(app_data_dir)
  return M.get_app_data_dir(app_data_dir) .. "/history.jsonl"
end

---Get the transcript file path for a conversation ID, preferring transcript_full.jsonl
---@param conversation_id string
---@param app_data_dir? string
---@return string
function M.get_transcript_file(conversation_id, app_data_dir)
  local base = M.get_brain_dir(app_data_dir) .. "/" .. conversation_id .. "/.system_generated/logs"
  local full_path = base .. "/transcript_full.jsonl"
  if vim.uv.fs_stat(full_path) then
    return full_path
  end
  return base .. "/transcript.jsonl"
end

---Split a string into lines, preserving empty lines
---@param str string
---@return string[]
function M.split_lines(str)
  if not str or str == "" then
    return { "" }
  end

  -- Normalize \r\n to \n
  str = str:gsub("\r\n", "\n"):gsub("\r", "\n")

  local lines = {}
  local start = 1
  while true do
    local pos = str:find("\n", start, true)
    if not pos then
      table.insert(lines, str:sub(start))
      break
    end
    table.insert(lines, str:sub(start, pos - 1))
    start = pos + 1
  end

  return lines
end

---Trim whitespace from start and end of string
---@param s string
---@return string
function M.trim(s)
  return s:match("^%s*(.-)%s*$") or ""
end

---Clean user input content from Antigravity internal metadata tags
---@param raw_content string
---@return string
function M.clean_user_content(raw_content)
  if not raw_content or raw_content == "" then
    return ""
  end

  -- Check if wrapped in <USER_REQUEST>...</USER_REQUEST>
  local user_req = raw_content:match("<USER_REQUEST>%s*(.-)%s*</USER_REQUEST>")
  if user_req then
    user_req = user_req:gsub("%s*<CLIENT_INSTRUCTIONS>.-</CLIENT_INSTRUCTIONS>", "")
    return M.trim(user_req)
  end

  -- If no tag, strip any trailing XML metadata blocks like <ADDITIONAL_METADATA>
  local cleaned = raw_content:gsub("<ADDITIONAL_METADATA>.-</ADDITIONAL_METADATA>", "")
  cleaned = cleaned:gsub("<USER_SETTINGS_CHANGE>.-</USER_SETTINGS_CHANGE>", "")
  cleaned = cleaned:gsub("<SYSTEM_MESSAGE>.-</SYSTEM_MESSAGE>", "")
  cleaned = cleaned:gsub("%s*<CLIENT_INSTRUCTIONS>.-</CLIENT_INSTRUCTIONS>", "")

  return M.trim(cleaned)
end

---Format number of tokens into human readable string (e.g. 12.8k)
---@param tokens number
---@return string
function M.format_tokens(tokens)
  if not tokens or tokens <= 0 then
    return "0 tokens"
  end
  if tokens >= 1000000 then
    return string.format("%.1fM tokens", tokens / 1000000)
  elseif tokens >= 1000 then
    return string.format("%.1fk tokens", tokens / 1000)
  else
    return string.format("%d tokens", tokens)
  end
end

---Format duration in seconds into human-readable string
---@param seconds number
---@return string
function M.format_duration(seconds)
  if not seconds or seconds <= 0 then
    return "0s"
  end
  if seconds >= 60 then
    local mins = math.floor(seconds / 60)
    local secs = math.floor(seconds % 60)
    return string.format("%dm %ds", mins, secs)
  elseif seconds >= 10 then
    return string.format("%.0fs", seconds)
  else
    return string.format("%.1fs", seconds)
  end
end

---Parse ISO 8601 timestamp string (e.g. "2026-09-20T18:54:06Z") to epoch seconds (UTC)
---@param str? string
---@return number? epoch_seconds
function M.parse_iso_timestamp(str)
  if not str or type(str) ~= "string" then
    return nil
  end

  local year, month, day, hour, min, sec = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if not year then
    return nil
  end

  local frac = str:match("%.(%d+)")
  local frac_sec = frac and (tonumber("0." .. frac) or 0) or 0

  local t = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false,
  })
  if not t then
    return nil
  end

  -- Determine local UTC offset so t represents UTC epoch
  local now = os.time()
  local utc_t = os.date("!*t", now)
  utc_t.isdst = false
  local local_utc_offset = os.difftime(now, os.time(utc_t))
  local utc_epoch = t + local_utc_offset

  local offset_sign, offset_h, offset_m = str:match("([+-])(%d%d):?(%d%d)%s*$")
  if offset_sign then
    local tz_offset = (tonumber(offset_h) * 3600 + tonumber(offset_m) * 60) * (offset_sign == "+" and 1 or -1)
    utc_epoch = utc_epoch - tz_offset
  end

  return utc_epoch + frac_sec
end

---Format relative time from Unix epoch timestamp (ms or s)
---@param timestamp number
---@return string
function M.format_relative_time(timestamp)
  if not timestamp or timestamp <= 0 then
    return "unknown"
  end

  -- Detect ms vs seconds
  local now_s = os.time()
  local ts_s = timestamp > 1e11 and math.floor(timestamp / 1000) or timestamp
  local diff = now_s - ts_s

  if diff < 0 then
    return "just now"
  elseif diff < 60 then
    return string.format("%ds ago", diff)
  elseif diff < 3600 then
    return string.format("%dm ago", math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format("%dh ago", math.floor(diff / 3600))
  else
    local days = math.floor(diff / 86400)
    return string.format("%dd ago", days)
  end
end

---Safely parse JSON
---@param str string
---@return table|nil, string|nil
function M.json_decode(str)
  local ok, res = pcall(vim.json.decode, str)
  if ok then
    return res, nil
  else
    return nil, tostring(res)
  end
end

---Safely encode JSON
---@param val any
---@return string
function M.json_encode(val)
  return vim.json.encode(val)
end

---Replace occurrences of target literal in str (case-insensitive if is_win)
---@param str string
---@param target string
---@param repl string
---@param is_win boolean
---@return string
local function replace_literal(str, target, repl, is_win)
  if not str or not target or target == "" then
    return str
  end
  local target_cmp = is_win and target:lower() or target
  local str_cmp = is_win and str:lower() or str
  local len = #target
  local parts = {}
  local start = 1
  local found = false

  while true do
    local idx = str_cmp:find(target_cmp, start, true)
    if not idx then
      parts[#parts + 1] = str:sub(start)
      break
    end
    found = true
    parts[#parts + 1] = str:sub(start, idx - 1)
    parts[#parts + 1] = repl
    start = idx + len
  end

  return found and table.concat(parts) or str
end

---Shorten a path or string containing workspace paths relative to cwd or workspaces
---@param text string
---@param cwd_or_workspaces? string|string[] Defaults to vim.fn.getcwd()
---@return string
function M.shorten_path(text, cwd_or_workspaces)
  if not text or type(text) ~= "string" or text == "" then
    return ""
  end

  local dirs = {}
  if type(cwd_or_workspaces) == "table" then
    for _, d in ipairs(cwd_or_workspaces) do
      if type(d) == "string" and d ~= "" then
        table.insert(dirs, d)
      end
    end
  elseif type(cwd_or_workspaces) == "string" and cwd_or_workspaces ~= "" then
    table.insert(dirs, cwd_or_workspaces)
  end

  if #dirs == 0 then
    local cur = vim.fn.getcwd()
    if cur and cur ~= "" then
      table.insert(dirs, cur)
    end
  end

  if #dirs == 0 then
    return text
  end

  local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local res = text

  for _, cwd in ipairs(dirs) do
    -- Normalize cwd: forward slashes, no trailing slash
    local norm_cwd = vim.fs.normalize(cwd):gsub("/+$", "")
    local win_cwd = norm_cwd:gsub("/", "\\")

    -- Case 1: res is a single file/directory path
    local norm_text = vim.fs.normalize(res)
    local cmp_text = is_win and norm_text:lower() or norm_text
    local cmp_cwd = is_win and norm_cwd:lower() or norm_cwd

    if cmp_text == cmp_cwd then
      return "."
    end

    if cmp_text:sub(1, #cmp_cwd + 1) == (cmp_cwd .. "/") then
      res = norm_text:sub(#cmp_cwd + 2)
    else
      -- Case 2: res contains embedded paths (e.g. in CommandLine or multi-arg strings)
      res = replace_literal(res, win_cwd .. "\\", "", is_win)
      res = replace_literal(res, norm_cwd .. "/", "", is_win)
      res = replace_literal(res, win_cwd, ".", is_win)
      res = replace_literal(res, norm_cwd, ".", is_win)
    end
  end

  return res
end

local _agy_version_cache = nil

---Get the Antigravity CLI version
---@param config? table
---@return string? version
function M.get_agy_version(config)
  if _agy_version_cache ~= nil then
    return _agy_version_cache ~= "" and _agy_version_cache or nil
  end

  local cfg = config or (package.loaded["agy.config"] and package.loaded["agy.config"].get())
  local cmd = (cfg and cfg.agy_cmd) or "agy"
  local ok, res = pcall(vim.fn.system, { cmd, "--version" })
  if ok and vim.v.shell_error == 0 and res and res ~= "" then
    local trimmed = vim.trim(res)
    _agy_version_cache = trimmed
    return trimmed
  end
  _agy_version_cache = ""
  return nil
end

---Clear or set cached agy CLI version (useful for tests)
---@param version? string
function M._set_agy_version(version)
  _agy_version_cache = version
end

return M

