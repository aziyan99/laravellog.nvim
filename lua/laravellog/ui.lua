local config = require("laravellog.config")
local parser = require("laravellog.parser")
local Store = require("laravellog.store")

local M = {}

---@class Session
---@field store Store
---@field wins table<string, integer>
---@field bufs table<string, integer>
---@field help_win integer
---@field prev_win integer
---@field focus string
---@field left_w integer
---@field ah integer
---@field timer? uv_timer_t
local S

local NS = vim.api.nvim_create_namespace("laravellog")
local AUG = "LaravelLogUI"
local ORDER = { "files", "entries", "levels", "detail" }
local TITLES = { files = "1 Files", entries = "2 Entries", levels = "3 Levels", detail = "4 Detail" }
local WINHL_ON = "FloatBorder:LaravelLogBorderActive,FloatTitle:LaravelLogBorderActive,CursorLine:LaravelLogSelected"
local WINHL_OFF = "FloatBorder:LaravelLogBorder,FloatTitle:LaravelLogBorder,CursorLine:LaravelLogSelectedIdle"

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify("laravellog: " .. msg, level or vim.log.levels.INFO)
end

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function new_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
end

local function hl(buf, group, row, s, e)
  vim.api.nvim_buf_set_extmark(buf, NS, row, s, { end_col = e, hl_group = group })
end

local function with_cursor(win, fn)
  local pos = vim.api.nvim_win_get_cursor(win)
  fn()
  pcall(vim.api.nvim_win_set_cursor, win, pos)
end

local function level_hl(level)
  return "LaravelLog" .. level:sub(1, 1) .. level:sub(2):lower()
end

local function human(n)
  if n < 1024 then
    return n .. " B"
  elseif n < 1048576 then
    return string.format("%.1f KB", n / 1024)
  end
  return string.format("%.1f MB", n / 1048576)
end

function M.setup_highlights()
  local links = {
    LaravelLogBorder = "FloatBorder",
    LaravelLogBorderActive = "DiagnosticOk",
    LaravelLogSelected = "Visual",
    LaravelLogSelectedIdle = "CursorLine",
    LaravelLogLabel = "Identifier",
    LaravelLogTitle = "Title",
    LaravelLogSection = "Special",
    LaravelLogFrame = "String",
    LaravelLogVendor = "Comment",
    LaravelLogHint = "Comment",
    LaravelLogEmergency = "DiagnosticError",
    LaravelLogAlert = "DiagnosticError",
    LaravelLogCritical = "DiagnosticError",
    LaravelLogError = "DiagnosticError",
    LaravelLogWarning = "DiagnosticWarn",
    LaravelLogNotice = "DiagnosticInfo",
    LaravelLogInfo = "DiagnosticInfo",
    LaravelLogDebug = "Comment",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

---------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------

local function title_for(name)
  if name == "entries" then
    local st = S.store
    return string.format(
      " 2 Entries (%d/%d)%s%s ",
      #st.view,
      #st.entries,
      st.truncated and " [tail]" or "",
      st.query ~= "" and ("  /" .. st.query) or ""
    )
  end
  return " " .. TITLES[name] .. " "
end

local function compute_layout()
  local cols = vim.o.columns
  local ah = vim.o.lines - vim.o.cmdheight - 1 -- last row is the help bar
  local lw = math.max(34, math.floor(cols * 0.4))
  if lw > cols - 20 then
    lw = math.floor(cols / 2)
  end
  local files_h = math.min(math.max(#S.store.files, 1), 4) + 2
  local levels_h = math.min(#parser.LEVELS + 2, math.max(3, ah - files_h - 6))
  local entries_h = ah - files_h - levels_h

  local function box(name, row, col, w, h)
    return {
      relative = "editor",
      row = row,
      col = col,
      width = math.max(w - 2, 1),
      height = math.max(h - 2, 1),
      style = "minimal",
      border = config.options.border,
      title = title_for(name),
      title_pos = "left",
      zindex = 50,
    }
  end

  S.left_w, S.ah = lw, ah
  return {
    files = box("files", 0, 0, lw, files_h),
    entries = box("entries", files_h, 0, lw, entries_h),
    levels = box("levels", files_h + entries_h, 0, lw, levels_h),
    detail = box("detail", 0, lw, cols - lw, ah),
    help = {
      relative = "editor",
      row = ah,
      col = 0,
      width = cols,
      height = 1,
      style = "minimal",
      focusable = false,
      zindex = 50,
    },
  }
end

local function apply_layout()
  local layout = compute_layout()
  for name, win in pairs(S.wins) do
    if valid(win) then
      layout[name].style = nil -- re-applying "minimal" would reset window options
      vim.api.nvim_win_set_config(win, layout[name])
    end
  end
  if valid(S.help_win) then
    layout.help.style = nil
    vim.api.nvim_win_set_config(S.help_win, layout.help)
  end
end

local function focus(name)
  if not S then
    return
  end
  S.focus = name
  for n, win in pairs(S.wins) do
    if valid(win) then
      vim.api.nvim_set_option_value("winhl", n == name and WINHL_ON or WINHL_OFF, { win = win })
    end
  end
  vim.api.nvim_set_current_win(S.wins[name])
end

---------------------------------------------------------------------------
-- rendering
---------------------------------------------------------------------------

local function render_help()
  local text = (" j/k move · <CR> select · / search · 1-4 panel · <Tab> next · r reload · f follow[%s] · s sort · y yank · X clear · q quit"):format(
    S.timer and "on" or "off"
  )
  set_lines(S.bufs.help, { text })
  hl(S.bufs.help, "LaravelLogHint", 0, 0, #text)
end

local function render_files()
  local st, buf = S.store, S.bufs.files
  with_cursor(S.wins.files, function()
    local lines = {}
    for i, f in ipairs(st.files) do
      lines[i] = string.format("%s %s  %s", i == st.file_idx and "●" or " ", f.name, human(f.size))
    end
    set_lines(buf, lines)
    if st.files[st.file_idx] then
      hl(buf, "LaravelLogBorderActive", st.file_idx - 1, 0, 3)
    end
  end)
end

local function render_levels()
  local st, buf = S.store, S.bufs.levels
  with_cursor(S.wins.levels, function()
    local lines = {}
    for i, lv in ipairs(parser.LEVELS) do
      lines[i] = string.format("[%s] %-9s %d", st.hidden[lv] and " " or "x", lv, st.counts[lv] or 0)
    end
    set_lines(buf, lines)
    for i, lv in ipairs(parser.LEVELS) do
      hl(buf, level_hl(lv), i - 1, 4, 4 + #lv)
    end
  end)
end

local function render_entries()
  local st, buf = S.store, S.bufs.entries
  local lines = {}
  for i, e in ipairs(st.view) do
    lines[i] = string.format("%s  %-9s %s", e.time:sub(6), e.level, e.title)
  end
  if #lines == 0 then
    lines = { " no matching entries" }
  end
  set_lines(buf, lines)
  for i, e in ipairs(st.view) do
    hl(buf, "LaravelLogHint", i - 1, 0, 14)
    hl(buf, level_hl(e.level), i - 1, 16, 16 + #e.level)
  end
end

local function current_entry()
  local row = vim.api.nvim_win_get_cursor(S.wins.entries)[1]
  return S.store.view[row]
end

local function render_detail()
  local buf = S.bufs.detail
  local e = current_entry()
  if not e then
    set_lines(buf, { " nothing selected" })
    return
  end

  local lines, marks = {}, {}
  local function add(line, group)
    lines[#lines + 1] = line
    if group and #line > 0 then
      marks[#marks + 1] = { #lines - 1, group, 0, #line }
    end
  end
  local function meta(label, value, group)
    local line = string.format("%-7s%s", label, value)
    lines[#lines + 1] = line
    marks[#marks + 1] = { #lines - 1, "LaravelLogLabel", 0, #label }
    if group then
      marks[#marks + 1] = { #lines - 1, group, 7, #line }
    end
  end

  meta("Level", e.level, level_hl(e.level))
  meta("Time", e.time)
  meta("Env", e.env)
  meta("Lines", tostring(#e.lines))
  add(string.rep("─", math.max(vim.api.nvim_win_get_width(S.wins.detail) - 1, 10)), "LaravelLogBorder")
  add(e.title, "LaravelLogTitle")

  local rest = vim.trim(e.message:sub(#e.title + 1))
  if rest ~= "" then
    add(rest)
  end
  for i = 2, #e.lines do
    local l = e.lines[i]
    local group
    if l:match("^#%d+") then
      group = l:find("/vendor/", 1, true) and "LaravelLogVendor" or "LaravelLogFrame"
    elseif l:match("^%[stacktrace%]") or l:match("^%[previous exception%]") then
      group = "LaravelLogSection"
    end
    add(l, group)
  end

  set_lines(buf, lines)
  for _, m in ipairs(marks) do
    hl(buf, m[2], m[1], m[3], m[4])
  end
  pcall(vim.api.nvim_win_set_cursor, S.wins.detail, { 1, 0 })
end

--- Re-render the entries list (+ titles + detail). `keep_key` = lines[1] of the
--- entry that should stay selected.
local function refresh_entries(keep_key)
  render_entries()
  apply_layout()
  local row = 1
  if keep_key then
    for i, e in ipairs(S.store.view) do
      if e.lines[1] == keep_key then
        row = i
        break
      end
    end
  end
  pcall(vim.api.nvim_win_set_cursor, S.wins.entries, { row, 0 })
  render_detail()
end

local function render_all(keep_key)
  render_files()
  render_levels()
  refresh_entries(keep_key)
  render_help()
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------

local function selected_key()
  local e = current_entry()
  return e and e.lines[1] or nil
end

local function reload()
  local key = selected_key()
  local row = vim.api.nvim_win_get_cursor(S.wins.entries)[1]
  if S.store.newest_first and row == 1 then
    key = nil -- sitting on the newest entry: keep following it
  end
  S.store:reload()
  render_all(key)
  local f = S.wins.files
  pcall(vim.api.nvim_win_set_cursor, f, { math.max(S.store.file_idx, 1), 0 })
end

local function clear_log()
    local f = S.store.files[S.store.file_idx]
    if not f then
        return
    end
    if vim.fn.confirm("Clear " .. f.name .. "?", "&Yes\n&No", 2) ~= 1 then
        return
    end
    local ok, err = S.store:clear_file()
    if not ok then
        return notify("cannot clear: " .. tostring(err), vim.log.levels.ERROR)
    end
    reload()
    notify(f.name .. " cleared")
end

local function toggle_follow()
  if S.timer then
    S.timer:stop()
    S.timer:close()
    S.timer = nil
  else
    local ms = config.options.follow_interval
    S.timer = vim.uv.new_timer()
    S.timer:start(
      ms,
      ms,
      vim.schedule_wrap(function()
        if S and S.store:changed() then
          reload()
        end
      end)
    )
  end
  render_help()
end

local function resolve(path)
  if vim.uv.fs_stat(path) then
    return path
  end
  -- Docker/CI paths (/var/www/html/app/Foo.php): try the project root + each path suffix
  local i = 1
  while true do
    i = path:find("/", i, true)
    if not i then
      return nil
    end
    local candidate = S.store.root .. path:sub(i)
    if vim.uv.fs_stat(candidate) then
      return candidate
    end
    i = i + 1
  end
end

local function open_frame()
  local line = vim.api.nvim_get_current_line()
  local path, lnum = line:match("([^%s%(%)\"'%[%]]+%.php)[:%(](%d+)")
  if not path then
    return notify("no file:line on this line", vim.log.levels.WARN)
  end
  local file = resolve(path)
  if not file then
    return notify("cannot locate " .. path, vim.log.levels.WARN)
  end
  local target = S.prev_win
  M.close()
  if valid(target) then
    vim.api.nvim_set_current_win(target)
  end
  vim.cmd.edit(vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), 0 })
end

local function yank_entry()
  local e = current_entry()
  if not e then
    return
  end
  local text = table.concat(e.lines, "\n")
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  notify("entry yanked")
end

local function cycle(dir)
  local idx = 1
  for i, name in ipairs(ORDER) do
    if name == S.focus then
      idx = i
    end
  end
  focus(ORDER[(idx - 1 + dir) % #ORDER + 1])
end

local function open_search()
  local st = S.store
  local prev = st.query
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prev })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = S.ah - 3,
    col = 0,
    width = S.left_w - 2,
    height = 1,
    style = "minimal",
    border = config.options.border,
    title = " Search (<CR> accept, <Esc> cancel) ",
    title_pos = "left",
    zindex = 60,
  })
  vim.api.nvim_set_option_value("winhl", "FloatBorder:LaravelLogBorderActive,FloatTitle:LaravelLogBorderActive", { win = win })

  local accepted = false
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function()
      if S then
        st:set_query(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
        refresh_entries()
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if S and not accepted then
          st:set_query(prev)
          refresh_entries()
        end
        if valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        focus("entries")
      end)
    end,
  })
  vim.keymap.set("i", "<CR>", function()
    accepted = true
    vim.cmd.stopinsert()
  end, { buffer = buf })
  vim.keymap.set("i", "<Esc>", function()
    vim.cmd.stopinsert()
  end, { buffer = buf })

  vim.cmd.startinsert({ bang = true })
end

---------------------------------------------------------------------------
-- keymaps
---------------------------------------------------------------------------

local function setup_keymaps()
  local function map(name, lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = S.bufs[name], nowait = true, silent = true })
  end
  local st = S.store

  for _, name in ipairs(ORDER) do
    map(name, "q", M.close)
    map(name, "/", open_search)
    map(name, "r", reload)
    map(name, "f", toggle_follow)
    map(name, "y", yank_entry)
    map(name, "X", clear_log)
    map(name, "<Tab>", function()
      cycle(1)
    end)
    map(name, "<S-Tab>", function()
      cycle(-1)
    end)
    map(name, "s", function()
      local key = selected_key()
      st:toggle_sort()
      refresh_entries(key)
    end)
    for i, target in ipairs(ORDER) do
      map(name, tostring(i), function()
        focus(target)
      end)
    end
  end

  -- files
  map("files", "<Esc>", M.close)
  map("files", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(S.wins.files)[1]
    if st.files[row] then
      st:select_file(row)
      render_all()
      focus("entries")
    end
  end)

  -- entries
  map("entries", "<Esc>", function()
    if st.query ~= "" then
      st:set_query("")
      refresh_entries()
    else
      M.close()
    end
  end)
  map("entries", "<CR>", function()
    focus("detail")
  end)
  for lhs, key in pairs({ J = "\x04", K = "\x15" }) do -- scroll detail panel
    map("entries", lhs, function()
      vim.api.nvim_win_call(S.wins.detail, function()
        vim.cmd("normal! " .. key)
      end)
    end)
  end

  -- levels
  local function level_at_cursor()
    return parser.LEVELS[vim.api.nvim_win_get_cursor(S.wins.levels)[1]]
  end
  local function toggle_level()
    local lv = level_at_cursor()
    if lv then
      st:toggle_level(lv)
      render_levels()
      refresh_entries()
    end
  end
  map("levels", "<Esc>", M.close)
  map("levels", "<CR>", toggle_level)
  map("levels", "<Space>", toggle_level)
  map("levels", "o", function()
    local lv = level_at_cursor()
    if lv then
      st:only_level(lv)
      render_levels()
      refresh_entries()
    end
  end)
  map("levels", "a", function()
    st:show_all_levels()
    render_levels()
    refresh_entries()
  end)

  -- detail
  map("detail", "<CR>", open_frame)
  map("detail", "<Esc>", function()
    focus("entries")
  end)
end

---------------------------------------------------------------------------
-- open / close
---------------------------------------------------------------------------

function M.open()
  if S then
    return focus("entries")
  end
  M.setup_highlights()

  local store = Store.new(config.options)
  local ok, err = store:init()
  if not ok then
    return notify(err, vim.log.levels.WARN)
  end

  S = { store = store, wins = {}, bufs = {}, prev_win = vim.api.nvim_get_current_win(), focus = "entries" }
  local layout = compute_layout()

  for _, name in ipairs(ORDER) do
    local buf = new_buf()
    local win = vim.api.nvim_open_win(buf, false, layout[name])
    S.bufs[name], S.wins[name] = buf, win
    local wo = {
      wrap = name == "detail",
      linebreak = name == "detail",
      cursorline = name ~= "detail",
      number = false,
      relativenumber = false,
      signcolumn = "no",
    }
    for k, v in pairs(wo) do
      vim.api.nvim_set_option_value(k, v, { win = win })
    end
  end
  S.bufs.help = new_buf()
  S.help_win = vim.api.nvim_open_win(S.bufs.help, false, layout.help)

  vim.api.nvim_create_augroup(AUG, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = AUG,
    buffer = S.bufs.entries,
    callback = function()
      if S then
        render_detail()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = AUG,
    callback = function()
      if S then
        apply_layout()
        render_detail()
      end
    end,
  })
  for _, win in pairs(S.wins) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = AUG,
      pattern = tostring(win),
      callback = function()
        vim.schedule(M.close) -- user closed one panel (:q) -> close the whole UI
      end,
    })
  end

  setup_keymaps()
  render_all()
  pcall(vim.api.nvim_win_set_cursor, S.wins.files, { math.max(store.file_idx, 1), 0 })
  focus("entries")
end

function M.close()
  local s = S
  if not s then
    return
  end
  S = nil
  pcall(vim.api.nvim_clear_autocmds, { group = AUG })
  if s.timer then
    s.timer:stop()
    s.timer:close()
  end
  for _, win in pairs(s.wins) do
    if valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if valid(s.help_win) then
    pcall(vim.api.nvim_win_close, s.help_win, true)
  end
  if valid(s.prev_win) then
    pcall(vim.api.nvim_set_current_win, s.prev_win)
  end
end

function M.clear()
  if S then
    return clear_log()
  end
  local store = Store.new(config.options)
  local ok, err = store:init()
  if not ok then
    return notify(err, vim.log.levels.WARN)
  end
  local f = store.files[store.file_idx]
  if vim.fn.confirm("Clear " .. f.name .. "?", "&Yes\n&No", 2) == 1 then
    local cleared, cerr = store:clear_file()
    notify(cleared and (f.name .. " cleared") or ("cannot clear: " .. tostring(cerr)))
  end
end

return M
