-- Simple test for datadog.nvim initialization without external dependencies
print("Testing datadog.nvim init module...")

-- Add the plugin's lua directory to the package.path
local plugin_lua_path = debug.getinfo(1, "S").source:match("@(.*/)") .. "../lua/?.lua"
package.path = plugin_lua_path .. ";" .. package.path

local success, err = pcall(function()
  -- Test init module
  local init = require('datadog.init')
  print("✓ init module loaded")
  
  -- Check that it has a setup function
  assert(type(init.setup) == "function", "setup function is missing")
  print("✓ setup function exists")
  
  -- Check that it has a config table
  assert(type(init.config) == "table", "config table is missing")
  print("✓ config table exists")
  
  print("Init module test passed!")
end)

if not success then
  print("✗ Error testing init module:")
  print(err)
  os.exit(1)
end