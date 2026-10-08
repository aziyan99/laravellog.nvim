if vim.g.loaded_laravel_log then
  return
end
vim.g.loaded_laravel_log = 1

vim.api.nvim_create_user_command("LaravelLog", function()
  require("laravellog").open()
end, { desc = "Open the Laravel log viewer" })

vim.api.nvim_create_user_command("LaravelLogClear", function()
  require("laravel-log").clear()
end, { desc = "Truncate the latest Laravel log" })
