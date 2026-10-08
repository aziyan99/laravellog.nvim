---@class LogEntry
---@field id integer
---@field time string        "2026-10-08 10:15:02"
---@field env string         "local" | "production" ...
---@field level string       "ERROR" | "INFO" ...
---@field message string     text after "LEVEL: " on the header line (includes inline context)
---@field title string       message without the trailing {"context"}
---@field lines string[]     raw lines; lines[1] is the header line

local M = {}

M.LEVELS = { "EMERGENCY", "ALERT", "CRITICAL", "ERROR", "WARNING", "NOTICE", "INFO", "DEBUG" }

-- [2026-10-08 10:15:02] production.ERROR: message {"exception":"..."}
local HEADER = "^%[(%d%d%d%d%-%d%d%-%d%d[ T]%d%d:%d%d:%d%d)[^%]]*%]%s+([%w_%-]+)%.(%a+):%s?(.*)$"

--- Read (at most) the last `max_bytes` of a file as lines.
---@return string[]|nil lines, boolean|string truncated_or_err
function M.read_tail(path, max_bytes)
  local fd, err = io.open(path, "rb")
  if not fd then
    return nil, err
  end
  local size = fd:seek("end")
  local truncated = size > max_bytes
  fd:seek("set", truncated and (size - max_bytes) or 0)
  local data = fd:read("*a") or ""
  fd:close()
  local lines = vim.split(data, "\n", { plain = true })
  if truncated then
    table.remove(lines, 1) -- first line is probably cut in half
  end
  return lines, truncated
end

---@param lines string[]
---@return LogEntry[] entries in chronological (file) order
function M.parse(lines)
  local entries, cur = {}, nil
  for _, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    local time, env, level, msg = line:match(HEADER)
    if time then
      cur = {
        id = #entries + 1,
        time = time,
        env = env,
        level = level:upper(),
        message = msg,
        title = msg:match('^(.-)%s+{"') or msg,
        lines = { line },
      }
      entries[#entries + 1] = cur
    elseif cur then
      cur.lines[#cur.lines + 1] = line
    end
  end
  return entries
end

return M
