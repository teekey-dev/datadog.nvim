-- Datadog.nvim - Neovim plugin for Datadog error tracking
-- Main initialization file

local M = {}

-- Default configuration
M.config = {
  api_key = "",
  app_key = "",
  site = "us1", -- us1, us3, us4, us5, eu1, gov
  refresh_interval = 30000, -- 30 seconds in milliseconds
  query = {
    time_range = "1h",
    filter = {
      query = "@status:error",
    },
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
    M.config = vim.tbl_deep_extend("force", M.config, user_config)
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
    M.show_errors_buffer()
  end, { desc = "Show Datadog errors in a buffer" })
  
  vim.api.nvim_create_user_command("DatadogRefresh", function()
    M.refresh_errors()
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