-- datadog.nvim plugin file
-- This file is sourced by Neovim to set up the plugin

-- Load the main module and expose it
local datadog = require('datadog.init')

-- Return the module so it can be required if needed
return datadog