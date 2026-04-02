-- Demo script showing how datadog.nvim would work
-- This is for demonstration purposes only

print("=== Datadog.nvim Demo ===")
print("This demonstrates the structure and intended functionality of the plugin.")
print()

-- Show the plugin structure
print("Plugin Structure:")
print("datadog.nvim/")
print("├── lua/")
print("│   └── datadog/")
print("│       ├── init.lua      -- Main plugin setup and configuration")
print("│       ├── api.lua       -- Datadog API client")
print("│       ├── buffer.lua    -- Error buffer management and display")
print("│       └── utils.lua     -- Utility functions")
print("├── plugin/")
print("│   └── datadog.lua       -- Plugin entry point")
print("├── README.md             -- Documentation")
print("└── PLAN.md               -- This planning document")
print()

-- Show intended usage
print("Intended Usage:")
print("1. Install the plugin with your plugin manager (packer.nvim, lazy.nvim, etc.)")
print("2. Configure with your Datadog API and APP keys:")
print("   require('datadog').setup({")
print("     api_key = 'your-api-key',")
print("     app_key = 'your-app-key',")
print("     site = 'us1',")
print("     refresh_interval = 30000,")
print("   })")
print()
print("3. Use the commands:")
print("   :DatadogErrors  -- Open error tracking buffer")
print("   :DatadogRefresh -- Manually refresh errors")
print("   :DatadogConfig  -- Show current configuration")
print()
print("4. In the errors buffer:")
print("   <Enter>  -- Navigate to source file of error under cursor")
print("   r        -- Refresh error list")
print("   q or <ESC> -- Close buffer")
print()

-- Show what the error buffer would look like
print("Example Error Buffer Display:")
print(
	"═════════════════════════════════════════════════════════════════════════════"
)
print(" Datadog Error Tracking ")
print(
	"═════════════════════════════════════════════════════════════════════════════"
)
print("")
print(" Timestamp              Service         Message                                 Status")
print(
	"═════════════════════════════════════════════════════════════════════════════"
)
print(" 5m ago                 web-api         Connection timeout to database          error")
print(" 12m ago                payment-service Invalid card number format              warning")
print(" 1h ago                 user-service    Null pointer exception in login handler error")
print("")
print(
	"═════════════════════════════════════════════════════════════════════════════"
)
print("Press <Enter> to navigate to source file, 'r' to refresh, 'q' to close")
print()

print("=== Demo Complete ===")
print("To use the plugin, install it in your Neovim configuration and set up your Datadog credentials.")
