-- Datadog Spans API module

local M = {}

-- Search spans by multiple issue IDs at once
function M:search_by_issues(issue_ids, from_iso, to_iso, callback)
	if #issue_ids == 0 then
		callback({}, nil)
		return
	end

	-- Build OR query for all issue IDs
	local query_parts = {}
	for _, issue in ipairs(issue_ids) do
		table.insert(query_parts, "@issue.id:" .. issue.id)
	end
	local query = "(" .. table.concat(query_parts, " OR ") .. ")"

	local request_body = {
		data = {
			attributes = {
				filter = {
					from = from_iso,
					to = to_iso,
					query = query,
				},
				options = {
					timezone = "UTC",
				},
				page = {
					limit = #issue_ids,
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

		-- Build a map of issue_id -> span data
		local spans_map = {}
		if response and response.data then
			for _, span in ipairs(response.data) do
				local issue_id = span.attributes
						and span.attributes.custom
						and span.attributes.custom.issue
						and span.attributes.custom.issue.id
					or nil
				if issue_id then
					spans_map[issue_id] = span
				end
			end
		end

		callback(spans_map, nil)
	end)
end

-- Search spans by issue ID (single)
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
