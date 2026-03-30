# Datadog Neovim Plugin Plan

## Overview
This plugin will display Datadog error tracking information in a Neovim buffer and allow navigation to source files.

## Plugin Structure
```
datadog.nvim/
├── lua/
│   └── datadog/
│       ├── init.lua
│       ├── api.lua
│       ├── buffer.lua
│       └── utils.lua
├── README.md
└── plugin/datadog.lua (for Lua plugin loading)
```

## Implementation Plan

### Phase 1: Basic Setup and API Connection
1. Create plugin directory structure with root named datadog.nvim
2. Implement Datadog API client in `lua/datadog/api.lua`
   - Handle authentication (API key and APP key)
   - Implement functions to fetch error logs
   - Support filtering by service, time range, etc.
3. Create initialization in `lua/datadog/init.lua`
   - Set up plugin commands
   - Define configuration options

### Phase 2: Error Buffer Display
1. Create buffer management in `lua/datadog/buffer.lua`
   - Create a new scratch buffer for error display
   - Format error data into readable table
   - Include columns: Timestamp, Service, Message, Status
   - Implement highlighting for different error levels
2. Add key mappings for buffer interactions
   - `<Enter>` to navigate to source file
   - `r` to refresh error list
   - `q` to close buffer

### Phase 3: Source File Navigation
1. Extract file and line information from error logs
   - Parse stack traces or source attributes in Datadog logs
   - Handle cases where file/line info is not available
2. Implement navigation function
   - Open file at specific line number
   - Focus on the relevant code section
   - Return to error buffer with navigation history

### Phase 4: Configuration and Enhancements
1. Make API endpoint and filters configurable
2. Add automatic refresh option (polling-based)
3. Implement error details view (expandable rows)
4. Add support for error severity filtering
5. Include documentation in README.md

## Dependencies
- Neovim >= 0.5.0 (for Lua support)
- Plenary.nvim (for HTTP requests and async operations)
- nvim-web-devicons (optional, for file icons)

## API Endpoints to Use
- Logs API: `https://api.datadoghq.com/api/v2/logs/query`
- Authentication: API key and Application key in headers

## Data Format
Expected error log format from Datadog:
```json
{
  "data": [
    {
      "attributes": {
        "timestamp": "2023-01-01T12:00:00.000Z",
        "service": "my-service",
        "message": "Error message here",
        "status": "error",
        "source": "python",
        "host": "host123",
        "tags": ["env:prod", "version:1.0"],
        // May contain stacktrace or source attributes
      }
    }
  ]
}
```

## User Commands
- `:DatadogErrors` - Open error tracking buffer
- `:DatadogRefresh` - Refresh error list
- `:DatadogConfig` - Show configuration

## Future Enhancements
- Periodic automatic refresh (polling-based)
- Integration with other Datadog features (APM, RUM)
- Customizable error queries
- Integration with telescope.nvim for better navigation