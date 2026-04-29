-- Datadog Spans API module

local M = {}

-- Fetch one representative span per issue. Fans out one search per issue in
-- parallel rather than a single OR'd query — a single OR'd `limit=N` query
-- can be entirely consumed by spans from one noisy issue, leaving the rest
-- of the issues without any span data.
function M:search_by_issues(issue_ids, from_iso, to_iso, callback)
	if #issue_ids == 0 then
		callback({}, nil)
		return
	end

	local spans_map = {}
	local pending = #issue_ids
	local first_err = nil

	for _, issue in ipairs(issue_ids) do
		self:search_by_issue(issue.id, from_iso, to_iso, function(span, err)
			if err and not first_err then
				first_err = err
			elseif span then
				spans_map[issue.id] = span
			end

			pending = pending - 1
			if pending == 0 then
				if first_err then
					callback(nil, first_err)
				else
					callback(spans_map, nil)
				end
			end
		end)
	end
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
