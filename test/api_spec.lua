-- Simple test for datadog.nvim API module
describe("datadog.nvim API", function()
	it("should have a new function", function()
		local api = require("datadog.api")
		assert.is_function(api.new)
	end)

	it("should create an API client", function()
		local api = require("datadog.api")
		local client = api.new({ api_key = "test", app_key = "test" })
		assert.is_table(client)
		assert.is_function(client.fetch_errors)
	end)
end)
