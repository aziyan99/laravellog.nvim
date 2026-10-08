local M = {}

---@param opts? table see laravellog.config
function M.setup(opts)
  require("laravellog.config").setup(opts)
end

function M.open()
  require("laravellog.ui").open()
end

function M.close()
  require("laravellog.ui").close()
end

function M.clear()
  require("laravel-log.ui").clear()
end

return M
