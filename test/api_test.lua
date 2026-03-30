-- Simple test for datadog.nvim API module without external dependencies
print("Testing datadog.nvim API module...")

-- Add the plugin's lua directory to the package.path
local plugin_lua_path = debug.getinfo(1, "S").source:match("@(.*/)") .. "../lua/?.lua"
package.path = plugin_lua_path .. ";" .. package.path

-- Mock the plenary.job module for testing
_G.vim = {
  notify = function(msg, level) print(string.format("VIM NOTIFY [%s]: %s", level, msg)) end,
  json = {
    encode = function(t) return vim.inspect(t) end,
    decode = function(s) return s end
  }
}

local success, err = pcall(function()
  -- Test api module
  local api = require('datadog.api')
  print("✓ api module loaded")
  
  -- Check that it has a new function
  assert(type(api.new) == "function", "new function is missing")
  print("✓ new function exists")
  
  -- Check that it has a base_url
  assert(type(api.base_url) == "string", "base_url is missing")
  print("✓ base_url exists")
  
  print("API module test passed!")
end)

if not success then
  print("✗ Error testing API module:")
  print(err)
  os.exit(1)
end