-- Datadog Spans API module

local M = {}

-- Search spans by issue ID
function M:search_by_issue(issue_id, from_iso, to_iso, callback)
	local request_body = {
		data = {
			attributes = {
				filter = {
					from = from_iso,
					to = to_iso,
					query = "@issue.id:" .. issue_id,
				},
				options = {
					timezone = "UTC",
				},
				page = {
					limit = 1,
				},
				sort = "-timestamp",
			},
			type = "search_request",
		},
	}

	self._api:_request("POST", "spans/events/search", request_body, function(response, err)
		if err then
			callback(nil, err)
			return
		end
		
		print("[Datadog Spans] Response: " .. vim.json.encode(response))
		
		if response and response.data and #response.data > 0 then
			callback(response.data[1], nil)
		else
			callback(nil, nil)
		end
	end)
end

return function(api)
	M._api = api
	return M
end
