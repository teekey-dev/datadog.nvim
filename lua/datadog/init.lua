-- Datadog.nvim - Neovim plugin for Datadog error tracking
-- Main initialization file

local M = {}

-- Default configuration
M.config = {
  api_key = "",
  app_key = "",
  site = "us1", -- us1, us3, us4, us5, eu1, gov
  refresh_interval = 30000, -- 30 seconds in milliseconds
  service = nil, -- auto-detected from project (package.json, go.mod, etc.)
  env = nil, -- optional: specify environment (e.g., "production", "staging")
  query = {
    time_range = "1h",
    limit = 100,
  },
}

-- Plugin state
M.state = {
  is_initialized = false,
  refresh_timer = nil,
  last_errors = {},
}

-- Setup function to be called by users
function M.setup(user_config)
  -- Merge user config with defaults
  if user_config then
    -- Manual table merge since vim.tbl_deep_extend might not be available in test env
    for k, v in pairs(user_config) do
      if type(v) == "table" and M.config[k] then
        -- Recursively merge tables
        for k2, v2 in pairs(v) do
          M.config[k][k2] = v2
        end
      else
        M.config[k] = v
      end
    end
  end
  
  -- Validate required configuration
  if not M.config.api_key or M.config.api_key == "" then
    vim.notify("Datadog.nvim: API key is required", vim.log.levels.ERROR)
    return
  end
  
  if not M.config.app_key or M.config.app_key == "" then
    vim.notify("Datadog.nvim: APP key is required", vim.log.levels.ERROR)
    return
  end
  
  -- Set up user commands
  vim.api.nvim_create_user_command("DatadogErrors", function()
    require('datadog.buffer').show_errors_buffer()
  end, { desc = "Show Datadog errors in a buffer" })
  
  vim.api.nvim_create_user_command("DatadogRefresh", function()
    require('datadog.buffer').refresh_errors()
  end, { desc = "Refresh Datadog errors" })
  
  vim.api.nvim_create_user_command("DatadogConfig", function()
    M.show_config()
  end, { desc = "Show Datadog.nvim configuration" })
  
  M.state.is_initialized = true
  vim.notify("Datadog.nvim: Plugin initialized successfully", vim.log.levels.INFO)
end

-- Show configuration
function M.show_config()
  vim.print("Datadog.nvim Configuration:")
  vim.print(vim.inspect(M.config))
end

-- Initialize plugin when required
return M