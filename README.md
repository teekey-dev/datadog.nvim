# datadog.nvim

A Neovim plugin for browsing Datadog Error Tracking issues for the current git
repository — list issues on the left, inspect each one (stack trace, first/last
seen, commit hashes) in a side detail pane, and jump straight to the offending
line in your code.

## Features

- Bottom split with **issue list (left) and detail pane (right)** — cursor on
  the list updates the detail view as you move
- Per-issue detail shows: error type & message, service/env/host, **first seen**
  and **last seen** times with the **commit hashes** (`first_seen_version` /
  `last_seen_version`) where the issue was first and most recently observed,
  total occurrences, and the full stack trace
- `<CR>` on any stack-frame line jumps to that `file:line` (works for Java, Go,
  JS, Ruby, Rust, Kotlin, Python frames out of the box)
- Issues are scoped to the current git repository (`@git.repository.id` filter),
  with optional service/env filters

## Installation

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'teekey-dev/datadog.nvim',
  requires = {
    'nvim-lua/plenary.nvim', -- For HTTP requests
    'MunifTanjim/nui.nvim',    -- For popup UI
    'nvim-web-devicons',     -- Optional: for file icons
  },
  config = function()
    require('datadog').setup({
      api_key = 'your-datadog-api-key',
      app_key = 'your-datadog-app-key',
      -- Optional configuration
      site = 'us1', -- Datadog site (us1, us3, us4, us5, eu1, gov)
      refresh_interval = 30000, -- 30 seconds in milliseconds
      query = {
        time_range = '1h', -- Time range for queries (e.g., '30m', '1h', '24h')
        filter = {
          query = '@status:error', -- Datadog log query
        },
        limit = 100, -- Maximum number of errors to fetch
      },
    })
  end
}
```

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'teekey-dev/datadog.nvim',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'MunifTanjim/nui.nvim',    -- For popup UI
    'nvim-web-devicons', -- Optional
  },
  opts = {
    api_key = 'your-datadog-api-key',
    app_key = 'your-datadog-app-key',
    -- Add other configuration options as needed
  }
}
```

## Usage

Once installed and configured, use the following commands:

- `:DatadogErrors` - Open the Datadog errors buffer
- `:DatadogRefresh` - Manually refresh the error data
- `:DatadogConfig` - Show the current plugin configuration

In the errors buffer:
- On the **list** pane (left):
  - Move with `j` / `k` (or any motion) — the detail pane updates as the cursor moves
  - `<Enter>` - Focus the detail pane so you can browse the stack trace
  - `r` - Refresh the error list
  - `q` or `<ESC>` - Close the errors buffer
- On the **detail** pane (right):
  - `j` / `k` - Scroll the detail / stack trace
  - `<Enter>` - Jump to `file:line` under the cursor (works on stack-frame
    lines); falls back to the issue's primary file if the line has no frame
  - `q` or `<ESC>` - Close the errors buffer

If the terminal is shorter than 25 lines, the plugin falls back to a list-only
view automatically.

## Configuration

The plugin can be configured with the following options:

| Option | Description | Default |
|--------|-------------|---------|
| `api_key` | Your Datadog API key | `""` (required) |
| `app_key` | Your Datadog application key | `""` (required) |
| `site` | Datadog site (`us1`, `us3`, `us4`, `us5`, `eu1`, `gov`) | `"us1"` |
| `refresh_interval` | Automatic refresh interval in milliseconds | `30000` (30 seconds) |
| `query.time_range` | Time range for log queries (e.g., `'1h'`, `'24h'`) | `"1h"` |
| `query.filter.query` | Datadog log query string | `"@status:error"` |
| `query.limit` | Maximum number of logs to fetch | `100` |

## How It Works

1. On open, the plugin runs `git remote get-url origin` to find the current
   repository URL and converts it to a Datadog
   `@git.repository.id:github.com/owner/repo` filter.
2. It calls `POST /api/v2/error-tracking/issues/search` with that filter (plus
   any optional `service` / `env` filters and the configured time range) to get
   the issues for this repo, including `first_seen` / `last_seen` timestamps and
   `first_seen_version` / `last_seen_version` commit hashes.
3. For each issue, it calls `POST /api/v2/spans/events/search` (in one batched
   request, OR'd over all issue IDs) to fetch a representative span carrying
   the file/line, error message, and full stack trace.
4. The two responses are merged and rendered: the left pane shows the issue
   table; the right pane shows the detail of the selected issue.
5. `<Enter>` on a stack-frame line in the detail pane parses `file:line` from
   that line and opens the file at the matching line.

## Requirements

- Neovim >= 0.5.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (for HTTP requests)
- Datadog API and Application keys

## Development

This plugin follows Neovim Lua plugin best practices:
- Modular architecture with separate concerns (API, buffer management, utilities)
- Functional programming principles where appropriate
- Proper error handling and validation
- Clear separation of plugin state and configuration

## License

MIT