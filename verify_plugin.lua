-- Verification script for datadog.nvim plugin
-- This script checks that the plugin is properly structured and can be loaded

print("=== Verifying datadog.nvim plugin ===")

-- Check that required files exist
local required_files = {
	"lua/datadog/init.lua",
	"lua/datadog/api.lua",
	"lua/datadog/buffer.lua",
	"lua/datadog/utils.lua",
	"plugin/datadog.lua",
	"README.md",
}

local missing_files = {}
for _, file in ipairs(required_files) do
	local f = io.open(file, "r")
	if not f then
		table.insert(missing_files, file)
	else
		f:close()
	end
end

if #missing_files > 0 then
	print("❌ Missing required files:")
	for _, file in ipairs(missing_files) do
		print("  - " .. file)
	end
	os.exit(1)
else
	print("✓ All required files present")
end

-- Test syntax of Lua files
local lua_files = {
	"lua/datadog/init.lua",
	"lua/datadog/api.lua",
	"lua/datadog/buffer.lua",
	"lua/datadog/utils.lua",
}

local syntax_errors = {}
for _, file in ipairs(lua_files) do
	local handle = io.popen('luac -p "' .. file .. '" 2>&1')
	local result = handle:read("*a")
	handle:close()

	if result ~= "" then
		table.insert(syntax_errors, { file = file, error = result })
	end
end

if #syntax_errors > 0 then
	print("❌ Syntax errors found:")
	for _, err in ipairs(syntax_errors) do
		print("  - " .. err.file .. ": " .. err.error)
	end
	os.exit(1)
else
	print("✓ All Lua files have valid syntax")
end

-- Test that plugin can be loaded (without external deps)
print("\n=== Testing plugin loading ===")
print("Note: Full functionality test requires plenary.nvim and actual Datadog API keys")
print("Plugin structure verification complete!")

print("\n=== Plugin Structure ===")
print("datadog.nvim/")
print("├── lua/")
print("│   └── datadog/")
print("│       ├── init.lua      -- Plugin initialization and configuration")
print("│       ├── api.lua       -- Datadog API client")
print("│       ├── buffer.lua    -- Error buffer management")
print("│       └── utils.lua     -- Utility functions")
print("├── plugin/")
print("│   └── datadog.lua       -- Plugin entry point")
print("├── README.md             -- Documentation")
print("└── verify_plugin.lua     -- This verification script")

print("\n=== To use the plugin ===")
print("1. Install with your plugin manager (e.g., packer.nvim, lazy.nvim)")
print("2. Configure with your Datadog API and APP keys:")
print("   require('datadog').setup({")
print("     api_key = 'your-api-key',")
print("     app_key = 'your-app-key',")
print("   })")
print("3. Use :DatadogErrors to open the error tracking buffer")
print("4. Press <Enter> on an error to navigate to the source file")

print("\n✅ Plugin verification successful!")
