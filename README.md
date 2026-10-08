# laravel-log.nvim

A lazygit/lazydocker-style TUI for browsing Laravel logs inside Neovim.

Requires Neovim >= 0.10.

```
┌ 1 Files ──────────┐┌ 4 Detail ─────────────────────────┐
│● laravel.log 1 MB ││Level  ERROR                       │
└───────────────────┘│Time   2026-10-08 10:15:02         │
┌ 2 Entries (3/120) ┐│Env    local                       │
│10-08 10:15 ERROR …││────────────────────────────────── │
│10-08 10:14 INFO  …││Undefined variable $user           │
└───────────────────┘│[stacktrace]                       │
┌ 3 Levels ─────────┐│#0 /app/Http/Controllers/Foo.php(12)│
│[x] ERROR  12      ││#1 /vendor/laravel/framework/...   │
└───────────────────┘└───────────────────────────────────┘
```

## Install (lazy.nvim)

```lua
{
  "you/laravel-log.nvim",
  cmd = "LaravelLog",
  keys = { { "<leader>ll", "<cmd>LaravelLog<cr>", desc = "Laravel log" } },
  opts = {},
}
```

## Keymaps

| Key | Where | Action |
| --- | --- | --- |
| `1`-`4`, `<Tab>`, `<S-Tab>` | all | focus panel |
| `/` | all | live search (`<CR>` accept, `<Esc>` cancel) |
| `<Esc>` | entries | clear search, or close |
| `<CR>` | files | open file |
| `<CR>` / `<Space>` | levels | toggle level |
| `o` / `a` | levels | only this level / show all |
| `<CR>` | entries | focus detail |
| `J` / `K` | entries | scroll detail down / up |
| `<CR>` | detail | jump to `file.php:line` under cursor |
| `s` | all | toggle newest/oldest first |
| `y` | all | yank raw entry |
| `r` | all | reload |
| `f` | all | follow mode (auto reload) |
| `q` | all | quit |

## Options

```lua
require("laravel-log").setup({
  log_dir = nil,                 -- default: <root>/storage/logs
  root_markers = { "artisan", "composer.json" },
  max_bytes = 5 * 1024 * 1024,   -- only the tail of big files is parsed
  newest_first = true,
  follow_interval = 1500,
  border = "rounded",
})
```

## Domain model

- `LogEntry`: one logical record (header line + continuation/stack trace lines)
- `Parser`: raw lines -> `LogEntry[]`
- `Store`: files, entries, filter (query + hidden levels), sort -> `view`
- `UI`: renders `Store` into four panels
