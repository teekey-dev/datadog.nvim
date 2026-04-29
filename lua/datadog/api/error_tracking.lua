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

	-- include=issue pulls the issue object into response.included[], where
	-- the actual error metadata (first_seen, last_seen, error_type,
	-- service, file_path, …) lives. Without it, response.data[].attributes
	-- only carries impacted_sessions/impacted_users/total_count and every
	-- detail field is missing.
	self._api:_request("POST", "error-tracking/issues/search?include=issue", request_body, callback)
end

return function(api)
	M._api = api
	return M
end
