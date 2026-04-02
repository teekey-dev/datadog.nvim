-- Simple test for datadog.nvim initialization
describe("datadog.nvim", function()
	it("should have a setup function", function()
		local datadog = require("datadog.init")
		assert.is_function(datadog.setup)
	end)

	it("should have default configuration", function()
		local datadog = require("datadog.init")
		assert.is_table(datadog.config)
		assert.is_string(datadog.config.api_key)
		assert.is_string(datadog.config.app_key)
	end)
end)
