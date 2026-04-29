-- Datadog Spans Analytics Aggregate API module.
-- Used to fetch occurrence-over-time buckets per issue for the trend sparkline.

local M = {}

-- Aggregate spans grouped by issue.id, returning a timeseries of counts per issue.
-- callback receives (trends_map, err) where trends_map[issue_id] = { buckets = {n,...}, peak = n }
function M:aggregate_by_issues(issue_ids, from_iso, to_iso, callback)
	if #issue_ids == 0 then
		callback({}, nil)
		return
	end

	local query_parts = {}
	for _, issue in ipairs(issue_ids) do
		table.insert(query_parts, "@issue.id:" .. issue.id)
	end
	local query = "(" .. table.concat(query_parts, " OR ") .. ")"

	local request_body = {
		data = {
			type = "aggregate_request",
			attributes = {
				compute = {
					{
						aggregation = "count",
						type = "timeseries",
					},
				},
				filter = {
					from = from_iso,
					to = to_iso,
					query = query,
				},
				group_by = {
					{
						facet = "@issue.id",
						limit = #issue_ids,
					},
				},
				options = {
					timezone = "UTC",
				},
			},
		},
	}

	self._api:_request("POST", "spans/analytics/aggregate", request_body, function(response, err)
		if err then
			if vim.g.datadog_debug then
				vim.notify("[Datadog Aggregate] error: " .. vim.inspect(err), vim.log.levels.WARN)
			end
			callback(nil, err)
			return
		end

		if vim.g.datadog_debug then
			-- Dump the first bucket so we can verify the shape we're parsing
			local first = response and response.data and response.data[1]
			vim.notify(
				"[Datadog Aggregate] first bucket: " .. vim.inspect(first),
				vim.log.levels.INFO
			)
		end

		local trends_map = {}
		if response and response.data then
			for _, bucket in ipairs(response.data) do
				local attrs = bucket.attributes or {}
				local by = attrs.by or {}
				local issue_id = by["@issue.id"]
				local computes = attrs.computes or {}

				if issue_id then
					-- Datadog returns the compute under a synthetic key like "c0"
					-- (one per entry in the compute array). Take whichever single
					-- key is present rather than hardcoding the name.
					local series
					for _, v in pairs(computes) do
						series = v
						break
					end

					if type(series) == "table" then
						local buckets = {}
						local peak = 0
						for _, point in ipairs(series) do
							local val = tonumber(point.value) or 0
							table.insert(buckets, val)
							if val > peak then
								peak = val
							end
						end
						trends_map[issue_id] = { buckets = buckets, peak = peak }
					end
				end
			end
		end

		callback(trends_map, nil)
	end)
end

return function(api)
	M._api = api
	return M
end
