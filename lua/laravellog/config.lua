local M = {}

M.defaults = {
  -- Absolute path to the log directory. nil = <laravel root>/storage/logs
  log_dir = nil,
  -- Files used to detect the Laravel project root (searched upward from current buffer)
  root_markers = { "artisan", "composer.json" },
  -- Only the last N bytes of a log file are parsed (huge logs stay fast)
  max_bytes = 5 * 1024 * 1024,
  -- Newest entries first
  newest_first = true,
  -- Poll interval (ms) used by follow mode
  follow_interval = 1500,
  border = "rounded",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
