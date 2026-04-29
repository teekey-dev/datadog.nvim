-- Datadog API client for datadog.nvim
-- Main entry point that integrates all API modules

local M = {}

-- Required dependencies
local Job = require("plenary.job")

-- API configuration
M.base_url = "https://api.datadoghq.com/api/v2"

-- Initialize API client
function M.new(config)
	local self = setmetatable({}, { __index = M })
	self.config = config or {}

	-- Set base URL based on site config
	local site = self.config.site or "us1"
	if site == "us1" then
		self.base_url = "https://api.datadoghq.com/api/v2"
	else
		self.base_url = string.format("https://api.%s.datadoghq.com/api/v2", site)
	end

	-- Initialize API modules
	self.error_tracking = require("datadog.api.error_tracking")(self)
	self.spans = require("datadog.api.spans")(self)
	self.spans_aggregate = require("datadog.api.spans_aggregate")(self)

	return self
end

-- Build headers for API requests
function M:_build_headers()
	return {
		["DD-API-KEY"] = self.config.api_key,
		["DD-APPLICATION-KEY"] = self.config.app_key,
		["Content-Type"] = "application/json",
	}
end

-- Build URL for API endpoint
function M:_build_url(endpoint)
	return string.format("%s/%s", self.base_url, endpoint)
end

-- Parse time range string to milliseconds since epoch
function M:_parse_time_range(time_range)
	local now = os.time() * 1000
	local from_time = now

	local value = tonumber(time_range:match("^%d+")) or 1
	local unit = time_range:match("[%a]+$") or "h"

	local multiplier = {
		["s"] = 1000,
		["m"] = 60 * 1000,
		["h"] = 60 * 60 * 1000,
		["d"] = 24 * 60 * 60 * 1000,
		["w"] = 7 * 24 * 60 * 60 * 1000,
	}

	local ms = multiplier[unit] or multiplier["h"]
	from_time = now - (value * ms)

	return from_time, now
end

-- Convert milliseconds to ISO8601 format
function M:_to_iso(time_ms)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", time_ms / 1000)
end

-- Get git repository ID from current directory
function M:get_git_repository_id()
	local cwd = vim.fn.getcwd()

	local handle = io.popen("cd " .. vim.fn.shellescape(cwd) .. " && git remote get-url origin 2>/dev/null")
	if handle then
		local url = handle:read("*a")
		handle:close()

		if url and url ~= "" then
			url = url:match("^%s*(.-)%s*$")
			url = url:gsub("^git@", ""):gsub(":", "/")
			local repo_id = url:gsub("%.git$", ""):gsub("^https?://", "")
			return "@git.repository.id:" .. repo_id
		end
	end

	return nil
end

-- Format one error from its issue record, exemplar span (or nil), and trend
-- (or nil). The "issue" record is the lightweight shape produced by the
-- collection loop in fetch_errors and persisted onto the formatted error
-- so a later lazy span fetch can re-format without redoing the search.
function M:_format_error(issue, span, trend)
	local formatted = {
		id = issue.id,
		occurrences = issue.total_count,
		first_seen = issue.first_seen,
		last_seen = issue.last_seen,
		first_seen_version = issue.first_seen_version,
		last_seen_version = issue.last_seen_version,
		trend = trend,
		-- Persist issue-level fallback fields so on-demand re-formatting
		-- after a lazy span fetch can reuse them.
		_issue = {
			id = issue.id,
			total_count = issue.total_count,
			first_seen = issue.first_seen,
			last_seen = issue.last_seen,
			first_seen_version = issue.first_seen_version,
			last_seen_version = issue.last_seen_version,
			issue_type = issue.issue_type,
			issue_message = issue.issue_message,
			issue_service = issue.issue_service,
			issue_file_path = issue.issue_file_path,
		},
	}

	if span then
		local attrs = span.attributes or {}
		local custom = attrs.custom or {}
		local custom_error = custom.error or {}

		formatted.title = custom_error.message or custom.error_title or issue.issue_message or issue.issue_type or ""
		formatted.message = custom_error.message or issue.issue_message or ""
		formatted.service = attrs.service or issue.issue_service or self.config.service or "unknown"
		formatted.status = custom_error.type or issue.issue_type or "unknown"
		formatted.timestamp = attrs.start_timestamp or attrs.timestamp
		formatted.span_last_seen = attrs.end_timestamp or attrs.timestamp
		formatted.error_source = custom_error.type or issue.issue_type or "unknown"
		formatted.file = custom_error.file or issue.issue_file_path or nil
		formatted.line = custom_error.line or nil
		formatted.stack_trace = custom_error.stack or custom.error_stack or ""
		formatted.host = attrs.host or "unknown"
		formatted.env = attrs.env or self.config.env or "unknown"
	else
		formatted.title = issue.issue_message or issue.issue_type or "(no exemplar span available)"
		formatted.message = issue.issue_message or ""
		formatted.service = issue.issue_service or self.config.service or "unknown"
		formatted.status = issue.issue_type or "unknown"
		formatted.error_source = issue.issue_type or "unknown"
		formatted.file = issue.issue_file_path or nil
		formatted.line = nil
		formatted.stack_trace = ""
		formatted.host = "unknown"
		formatted.env = self.config.env or "unknown"
	end

	return formatted
end

-- Lazy-fetch the exemplar span for an error that didn't get one in the
-- initial fan-out (tail issues outside the top-N cap). Re-formats the
-- error with the new span and returns it via callback. Cache-aware via
-- spans:search_by_issue.
function M:fetch_span_for_error(error_record, callback)
	if not error_record or not error_record._issue then
		callback(nil, { error = "missing issue record on error" })
		return
	end

	local time_range = self.config.query and self.config.query.time_range or "1w"
	local from_time, to_time = self:_parse_time_range(time_range)
	local from_iso = self:_to_iso(from_time)
	local to_iso = self:_to_iso(to_time)

	self.spans:search_by_issue(error_record._issue.id, from_iso, to_iso, function(span, err)
		if err then
			callback(nil, err)
			return
		end
		-- Preserve the original trend (we don't refetch it here).
		callback(self:_format_error(error_record._issue, span, error_record.trend), nil)
	end)
end

-- Make HTTP request to Datadog API
function M:_request(method, endpoint, data, callback)
	local url = self:_build_url(endpoint)

	local args = {
		"-X",
		method,
		"-H",
		"DD-API-KEY:" .. self.config.api_key,
		"-H",
		"DD-APPLICATION-KEY:" .. self.config.app_key,
		"-H",
		"Content-Type: application/json",
		"-s",
		url,
	}

	if method == "POST" or method == "PUT" then
		local json_body = vim.json.encode(data)
		table.insert(args, "--data")
		table.insert(args, json_body)
	end

	Job:new({
		command = "curl",
		args = args,
		on_exit = function(j, return_val)
			if return_val ~= 0 then
				local err_msg = table.concat(j:stderr_result(), "\n")
				print("[Datadog API] Error: " .. err_msg)
				if callback then
					callback(nil, { error = err_msg })
				end
				return
			end

			local output = table.concat(j:result(), "")

			if output == "" then
				if callback then
					callback(nil, { error = "Empty response" })
				end
				return
			end

			local ok, decoded = pcall(vim.json.decode, output)
			if not ok then
				print("[Datadog API] JSON parse error: " .. tostring(decoded))
				if callback then
					callback(nil, { error = decoded })
				end
				return
			end

			if callback then
				callback(decoded, nil)
			end
		end,
	}):start()
end

-- Fetch all errors (combines error tracking and span data)
function M:fetch_errors(callback)
	local git_filter = self:get_git_repository_id()

	local service_filter = ""
	if self.config.service and self.config.service ~= "" then
		service_filter = "service:" .. self.config.service
	end

	local env_filter = ""
	if self.config.env and self.config.env ~= "" then
		env_filter = "env:" .. self.config.env
	end

	local filters = {}
	if git_filter then
		table.insert(filters, git_filter)
	end
	if service_filter then
		table.insert(filters, service_filter)
	end
	if env_filter then
		table.insert(filters, env_filter)
	end

	local query_string = table.concat(filters, " "):match("^%s*(.-)%s*$")

	if query_string == "" then
		vim.notify("Datadog: No git repository detected.", vim.log.levels.WARN)
		if callback then
			callback({}, nil)
		end
		return
	end

	local time_range = self.config.query and self.config.query.time_range or "1w"
	local from_time, to_time = self:_parse_time_range(time_range)
	local from_iso = self:_to_iso(from_time)
	local to_iso = self:_to_iso(to_time)

	-- First, get error tracking issues to get issue IDs
	self.error_tracking:search(query_string, from_time, to_time, function(response, err)
		if err then
			if callback then
				callback(nil, err)
			end
			return
		end

		if not response or not response.data or #response.data == 0 then
			if callback then
				callback({}, nil)
			end
			return
		end

		-- Collect issue IDs and the issue-level attributes we'll use as a
		-- fallback when the per-issue spans search returns no representative
		-- span. The error metadata (first_seen, last_seen, error_type,
		-- service, file_path, …) lives in response.included[], not on
		-- data[].attributes — data[] only carries the relationship pointer
		-- and aggregate counts. Build an id→attrs lookup over included[]
		-- so we can merge each row's issue object back in.
		if vim.g.datadog_debug then
			vim.notify(
				"[Datadog Error Tracking] data[1]: " .. vim.inspect(response.data and response.data[1])
				.. "\nincluded[1]: " .. vim.inspect(response.included and response.included[1]),
				vim.log.levels.INFO
			)
		end

		local included_by_id = {}
		for _, inc in ipairs(response.included or {}) do
			if inc.id and inc.attributes then
				included_by_id[inc.id] = inc.attributes
			end
		end

		local issue_ids = {}
		for _, item in ipairs(response.data) do
			local attrs = item.attributes or {}
			local total_count = attrs.total_count or 0
			if total_count > 0 then
				local relationships = item.relationships or {}
				local issue_data = relationships.issue and relationships.issue.data or {}
				local issue_id = issue_data.id or item.id
				if issue_id then
					-- Pull the real issue metadata from the included resource
					-- referenced by relationships.issue.data.id.
					local issue_attrs = included_by_id[issue_id] or {}
					table.insert(issue_ids, {
						id = issue_id,
						total_count = total_count,
						first_seen = issue_attrs.first_seen,
						last_seen = issue_attrs.last_seen,
						first_seen_version = issue_attrs.first_seen_version,
						last_seen_version = issue_attrs.last_seen_version,
						-- Issue-level metadata (used as fallback in formatter)
						issue_type = issue_attrs.error_type,
						issue_message = issue_attrs.error_message,
						issue_service = issue_attrs.service,
						issue_file_path = issue_attrs.file_path,
					})
				end
			end
		end

		if #issue_ids == 0 then
			if callback then
				callback({}, nil)
			end
			return
		end

		-- Run spans search and trend aggregate in parallel; merge once both complete.
		-- Aggregate failure is non-fatal — the trend line just shows "(unavailable)".
		local spans_map = nil
		local trends_map = nil
		local spans_err = nil
		local pending = 2

		local function maybe_finish()
			pending = pending - 1
			if pending > 0 then
				return
			end

			if spans_err then
				if callback then
					callback(nil, spans_err)
				end
				return
			end

			spans_map = spans_map or {}
			trends_map = trends_map or {}

			local errors = {}
			for _, issue in ipairs(issue_ids) do
				local span = spans_map[issue.id]
				local trend = trends_map[issue.id]
				table.insert(errors, self:_format_error(issue, span, trend))
			end

			table.sort(errors, function(a, b)
				return (a.occurrences or 0) > (b.occurrences or 0)
			end)

			if callback then
				callback(errors, nil)
			end
		end

		self.spans:search_by_issues(issue_ids, from_iso, to_iso, function(map, sp_err)
			if sp_err then
				spans_err = sp_err
			else
				spans_map = map
			end
			maybe_finish()
		end)

		self.spans_aggregate:aggregate_by_issues(issue_ids, from_iso, to_iso, function(map, ag_err)
			if not ag_err then
				trends_map = map
			end
			-- Aggregate errors are intentionally swallowed (rate limit, etc.)
			maybe_finish()
		end)
	end)

	return M
end

return M
