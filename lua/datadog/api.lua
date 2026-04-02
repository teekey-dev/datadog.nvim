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

-- Make HTTP request to Datadog API
function M:_request(method, endpoint, data, callback)
	local url = self:_build_url(endpoint)

	print(string.format("[Datadog API] Request: %s %s", method, url))
	if data then
		print("[Datadog API] Request body: " .. vim.json.encode(data))
	end

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

		-- Collect issue IDs
		local issue_ids = {}
		for _, item in ipairs(response.data) do
			local total_count = (item.attributes and item.attributes.total_count) or 0
			if total_count > 0 then
				local relationships = item.relationships or {}
				local issue_data = relationships.issue and relationships.issue.data or {}
				local issue_id = issue_data.id or item.id
				if issue_id then
					table.insert(issue_ids, {
						id = issue_id,
						total_count = total_count,
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

		-- Fetch span details for each issue
		local pending = #issue_ids
		local errors = {}

		local function check_complete()
			pending = pending - 1
			if pending == 0 then
				-- Sort by occurrences descending
				table.sort(errors, function(a, b)
					return (a.occurrences or 0) > (b.occurrences or 0)
				end)
				if callback then
					callback(errors, nil)
				end
			end
		end

		for _, issue in ipairs(issue_ids) do
			self.spans:search_by_issue(issue.id, from_iso, to_iso, function(span, span_err)
				local formatted = {
					id = issue.id,
					occurrences = issue.total_count,
				}
				
				print("[Datadog] Span for issue " .. issue.id .. ": " .. vim.json.encode(span))
				
				if span and not span_err then
				local attrs = span.attributes or {}
				local custom = attrs.custom or {}
				
				formatted.title = custom.error_message or custom.error_title or ""
				formatted.message = custom.error_message or ""
				formatted.service = attrs.service or self.config.service or "unknown"
				formatted.status = custom.error_type or "unknown"
				formatted.timestamp = attrs.start_timestamp or attrs.timestamp
				formatted.last_seen = attrs.end_timestamp or attrs.timestamp
				formatted.error_source = custom.error_type or "unknown"
				formatted.file = custom.error_file or nil
				formatted.line = custom.error_line or nil
				formatted.stack_trace = custom.error_stack or ""
				formatted.host = attrs.host or "unknown"
				formatted.env = attrs.env or self.config.env or "unknown"
			else
					formatted.title = "Unknown error"
					formatted.message = ""
					formatted.service = self.config.service or "unknown"
					formatted.status = "unknown"
					formatted.error_source = "unknown"
				end

				table.insert(errors, formatted)
				check_complete()
			end)
		end
	end)
end

return M
