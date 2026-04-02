-- Datadog Error Tracking API module

local M = {}

-- Search error tracking issues
function M:search(query, from_time, to_time, callback)
	local request_body = {
		data = {
			type = "search_request",
			attributes = {
				query = query,
				from = from_time,
				to = to_time,
				track = "trace",
				order_by = "TOTAL_COUNT",
			},
		},
	}

	self._api:_request("POST", "error-tracking/issues/search", request_body, callback)
end

return function(api)
	M._api = api
	return M
end
