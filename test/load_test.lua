-- Simple load test for datadog.nvim modules
print("Testing datadog.nvim module loading...")

-- Add the plugin's lua directory to the package.path
local plugin_lua_path = debug.getinfo(1, "S").source:match("@(.*/)") .. "../lua/?.lua"
package.path = plugin_lua_path .. ";" .. package.path

local success, err = pcall(function()
	-- Test init module
	local init = require("datadog.init")
	print("✓ init module loaded")

	-- Test api module
	local api = require("datadog.api")
	print("✓ api module loaded")

	-- Test buffer module
	local buffer = require("datadog.buffer")
	print("✓ buffer module loaded")

	-- Test utils module
	local utils = require("datadog.utils")
	print("✓ utils module loaded")

	print("All modules loaded successfully!")
end)

if not success then
	print("✗ Error loading modules:")
	print(err)
	os.exit(1)
end
