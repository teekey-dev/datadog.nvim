# datadog.nvim

A Neovim plugin for displaying Datadog error tracking information in a buffer with navigation to source files.

## Features

- Display Datadog error logs in a dedicated Neovim buffer
- Navigate to source files from error entries with `<Enter>`
- Automatic refresh of error data (configurable interval)
- Syntax highlighting for different error levels
- Easy configuration of API keys and query parameters

## Installation

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'your-username/datadog.nvim',
  requires = {
    'nvim-lua/plenary.nvim', -- For HTTP requests
    'nvim-tree/nui.nvim',    -- For popup UI
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
  'your-username/datadog.nvim',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nui.nvim',    -- For popup UI
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
- `<Enter>` - Navigate to the source file of the error under cursor
- `r` - Refresh the error list
- `q` or `<ESC>` - Close the errors buffer

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

1. The plugin uses the Datadog Logs API to fetch error logs based on your query configuration
2. Error logs are displayed in a formatted table with timestamp, service, message, and status
3. When available, the plugin extracts file and line information from the log attributes
4. Pressing `<Enter>` on an error entry opens the corresponding file at the relevant line
5. The plugin can automatically refresh error data at a configurable interval

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