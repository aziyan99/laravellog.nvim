local parser = require("laravellog.parser")

---@class LogFile
---@field name string
---@field path string
---@field size integer
---@field mtime integer

---@class Store
local Store = {}
Store.__index = Store

function Store.new(opts)
  return setmetatable({
    opts = opts,
    files = {}, ---@type LogFile[]
    file_idx = 0,
    entries = {}, ---@type LogEntry[] chronological
    view = {}, ---@type LogEntry[] filtered + sorted
    counts = {}, ---@type table<string, integer>
    hidden = {}, ---@type table<string, boolean>
    query = "",
    newest_first = opts.newest_first,
    truncated = false,
    sig = nil,
  }, Store)
end

---@return boolean ok, string? err
function Store:init()
  local start = vim.api.nvim_buf_get_name(0)
  if start == "" then
    start = vim.fn.getcwd()
  end
  self.root = vim.fs.root(start, self.opts.root_markers) or vim.fn.getcwd()
  self.log_dir = self.opts.log_dir or (self.root .. "/storage/logs")

  if vim.fn.isdirectory(self.log_dir) == 0 then
    return false, "Log directory not found: " .. self.log_dir
  end
  self:scan()
  if #self.files == 0 then
    return false, "No .log files in " .. self.log_dir
  end
  self:select_file(1)
  return true
end

function Store:scan()
  self.files = {}
  for name, kind in vim.fs.dir(self.log_dir) do
    if kind == "file" and name:match("%.log$") then
      local path = self.log_dir .. "/" .. name
      local st = vim.uv.fs_stat(path)
      self.files[#self.files + 1] = {
        name = name,
        path = path,
        size = st and st.size or 0,
        mtime = st and st.mtime.sec or 0,
      }
    end
  end
  table.sort(self.files, function(a, b)
    return a.mtime > b.mtime
  end)
end

function Store:select_file(i)
  if not self.files[i] then
    return
  end
  self.file_idx = i
  self:load()
end

function Store:load()
  local f = self.files[self.file_idx]
  local lines, truncated = parser.read_tail(f.path, self.opts.max_bytes)
  if not lines then
    vim.notify("laravellog: cannot read " .. f.path .. " (" .. tostring(truncated) .. ")", vim.log.levels.ERROR)
    lines, truncated = {}, false
  end
  self.entries = parser.parse(lines)
  self.truncated = truncated
  self.sig = self:signature()

  self.counts = {}
  for _, e in ipairs(self.entries) do
    self.counts[e.level] = (self.counts[e.level] or 0) + 1
  end
  self:refilter()
end

--- Rescan the directory and reload, keeping the selected file when possible.
function Store:reload()
  local current = self.files[self.file_idx]
  self:scan()
  local idx = 1
  for i, f in ipairs(self.files) do
    if current and f.path == current.path then
      idx = i
      break
    end
  end
  self:select_file(idx)
end

function Store:signature()
  local f = self.files[self.file_idx]
  local st = f and vim.uv.fs_stat(f.path)
  return st and (st.size .. ":" .. st.mtime.sec .. "." .. st.mtime.nsec) or nil
end

--- Has the current file changed on disk since it was loaded?
function Store:changed()
  return self:signature() ~= self.sig
end

function Store:refilter()
  local q = self.query:lower()
  local view, n = {}, #self.entries
  for k = 1, n do
    local e = self.entries[self.newest_first and (n - k + 1) or k]
    if not self.hidden[e.level] then
      local match = true
      if q ~= "" then
        e.lower = e.lower or table.concat(e.lines, "\n"):lower()
        match = e.lower:find(q, 1, true) ~= nil
      end
      if match then
        view[#view + 1] = e
      end
    end
  end
  self.view = view
end

function Store:set_query(q)
  self.query = q
  self:refilter()
end

function Store:toggle_level(level)
  self.hidden[level] = not self.hidden[level] or nil
  self:refilter()
end

function Store:only_level(level)
  self.hidden = {}
  for _, lv in ipairs(parser.LEVELS) do
    if lv ~= level then
      self.hidden[lv] = true
    end
  end
  self:refilter()
end

function Store:show_all_levels()
  self.hidden = {}
  self:refilter()
end

function Store:toggle_sort()
  self.newest_first = not self.newest_first
  self:refilter()
end

---@return boolean ok, string? err
function Store:clear_file()
    local f = self.files[self.file_idx]
    if not f then
        return false, "no file selected"
    end

    local fd, err = io.open(f.path, "w")
    if not fd then
        return false, err
    end

    fd:close()
    return true
end

return Store
