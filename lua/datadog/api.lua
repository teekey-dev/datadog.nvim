-- Datadog API client for datadog.nvim
-- Handles authentication and API requests to Datadog

local M = {}

-- Required dependencies
local Job = require('plenary.job')
local utils = require('datadog.utils')

-- API configuration
M.base_url = "https://api.datadoghq.com/api/v2"

-- Initialize API client
function M.new(config)
  local self = setmetatable({}, { __index = M })
  self.config = config or {}
  -- Set base URL based on site config
  local site = self.config.site or "us1"
  if site == "us1" then
    -- us1 uses a different API domain
    self.base_url = "https://api.datadoghq.com/api/v2"
  else
    self.base_url = string.format("https://api.%s.datadoghq.com/api/v2", site)
  end
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
  local now = os.time() * 1000 -- current time in milliseconds
  local from_time = now
  
  -- Parse time range (e.g., "1h", "1w", "1d")
  local value = tonumber(time_range:match("^%d+")) or 1
  local unit = time_range:match("[%a]+$") or "h"
  
  local multiplier = {
    ["s"] = 1000,           -- seconds
    ["m"] = 60 * 1000,     -- minutes
    ["h"] = 60 * 60 * 1000, -- hours
    ["d"] = 24 * 60 * 60 * 1000, -- days
    ["w"] = 7 * 24 * 60 * 60 * 1000, -- weeks
  }
  
  local ms = multiplier[unit] or multiplier["h"]
  from_time = now - (value * ms)
  
  return from_time, now
end

-- Make HTTP request to Datadog API
function M:_request(method, endpoint, data, callback)
  local url = self:_build_url(endpoint)
  local headers = self:_build_headers()
  
  -- DEBUG: Print request details
  print(string.format("[Datadog API] Request: %s %s", method, url))
  if data then
    print("[Datadog API] Request body: " .. vim.json.encode(data))
  end
  
  local args = {
    "-X", method,
    "-H", "DD-API-KEY:" .. self.config.api_key,
    "-H", "DD-APPLICATION-KEY:" .. self.config.app_key,
    "-H", "Content-Type: application/json",
    "-s", -- silent mode
    url,
  }
  
  -- Add data for POST/PUT requests
  if method == "POST" or method == "PUT" then
    local json_body = vim.json.encode(data)
    table.insert(args, "--data")
    table.insert(args, json_body)
    print("[Datadog API] JSON body: " .. json_body)
  end
  
  -- DEBUG: Print curl command
  print("[Datadog API] curl " .. table.concat(args, " "))
  
  Job:new({
    command = "curl",
    args = args,
    on_exit = function(j, return_val)
      if return_val ~= 0 then
        local stderr = table.concat(j:stderr_result(), "\n")
        vim.notify(string.format("Datadog API error: %s", stderr), vim.log.levels.ERROR)
        print("[Datadog API] Error: " .. stderr)
        if callback then
          callback(nil, { error = stderr })
        end
        return
      end
      
      local result = table.concat(j:result(), "")
      
      -- DEBUG: Print raw response
      print("[Datadog API] Raw response length: " .. #result)
      print("[Datadog API] Raw response: " .. result)
      
      local parsed
      pcall(function() parsed = vim.json.decode(result) end)
      
      -- DEBUG: Print parsed response structure
      if parsed then
        if parsed.data then
          print("[Datadog API] Response has " .. #parsed.data .. " items in data")
        elseif parsed.errors then
          print("[Datadog API] Response errors: " .. vim.json.encode(parsed.errors))
        elseif parsed.message then
          print("[Datadog API] Response message: " .. parsed.message)
        end
      else
        print("[Datadog API] Failed to parse JSON response")
      end
      
      if callback then
        callback(parsed, nil)
      end
    end
  }):start()
end

-- Fetch git repository ID from git remote
function M:get_git_repository_id()
  local cwd = vim.fn.getcwd()
  
  -- Try to get remote origin URL
  local handle = io.popen("cd " .. vim.fn.shellescape(cwd) .. " && git remote get-url origin 2>/dev/null")
  if handle then
    local url = handle:read("*a")
    handle:close()
    
    if url and url ~= "" then
      -- Trim whitespace from both ends
      url = url:match("^%s*(.-)%s*$")
      
      -- Convert SSH format (git@host:repo) to standard format (host/repo)
      url = url:gsub("^git@", ""):gsub(":", "/")
      
      -- Convert to @git.repository:id format
      local repo_id = url:gsub("%.git$", ""):gsub("^https?://", "")
      return "@git.repository.id:" .. repo_id
    end
  end
  
  return nil
end

-- Fetch error tracking issues from Datadog
function M:fetch_errors(callback)
  -- Build filter query with git repository ID (required)
  local git_filter = M.get_git_repository_id()
  
  local service_filter = ""
  if self.config.service and self.config.service ~= "" then
    service_filter = "service:" .. self.config.service
  end
  
  local env_filter = ""
  if self.config.env and self.config.env ~= "" then
    env_filter = "env:" .. self.config.env
  end
  
  -- Combine filters
  local filters = {}
  if git_filter then table.insert(filters, git_filter) end
  if service_filter then table.insert(filters, service_filter) end
  if env_filter then table.insert(filters, env_filter) end
  
  local query_string = table.concat(filters, " "):match("^%s*(.-)%s*$")
  
  -- query is required - if empty, show warning
  if query_string == "" then
    vim.notify("Datadog: No git repository detected. Please configure service or query.", vim.log.levels.WARN)
    if callback then
      callback({}, nil)
    end
    return
  end
  
  print("[Datadog API] Git repository filter: " .. (git_filter or "none"))
  print("[Datadog API] Error Tracking query: " .. query_string)
  
  -- Calculate time range in milliseconds
  local time_range = self.config.query and self.config.query.time_range or "1w"
  local from_time, to_time = self:_parse_time_range(time_range)
  
  -- Convert to ISO8601 format for span search API
  local from_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", from_time / 1000)
  local to_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", to_time / 1000)
  
  -- Build request body for error tracking search (to get issue IDs)
  local request_body = {
    data = {
      type = "search_request",
      attributes = {
        query = query_string,
        from = from_time,
        to = to_time,
        track = "trace", -- Use "trace" track for error tracking
        order_by = "TOTAL_COUNT",
      }
    }
  }
  
  print("[Datadog API] Full Query: " .. vim.json.encode(request_body))
  
  -- First, get issue IDs from error tracking API
  self:_request("POST", "error-tracking/issues/search", request_body, function(response, err)
    if err then
      print("[Datadog API] fetch_errors error: " .. vim.json.encode(err))
      if callback then
        callback(nil, err)
      end
      return
    end
    
    -- Process and format the response from Error Tracking API
    local errors = {}
    if response and response.data and #response.data > 0 then
      print("[Datadog API] Found " .. #response.data .. " error tracking issues")
      
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
      
      print("[Datadog API] Collected " .. #issue_ids .. " issue IDs")
      
      -- If no issues, return early
      if #issue_ids == 0 then
        print("[Datadog API] No error tracking issues found")
        if callback then
          callback({}, nil)
        end
        return
      end
      
      -- Now fetch span details for each issue
      local pending = #issue_ids
      local function check_complete()
        pending = pending - 1
        if pending == 0 then
          print("[Datadog API] Returning " .. #errors .. " errors")
          if callback then
            callback(errors, nil)
          end
        end
      end
      
      for _, issue in ipairs(issue_ids) do
        -- Build span search request for this issue
        local span_request = {
          data = {
            attributes = {
              filter = {
                from = from_iso,
                to = to_iso,
                query = "@issue.id:" .. issue.id,
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
          }
        }
        
        self:_request("POST", "spans/events/search", span_request, function(span_response, span_err)
          if span_err then
            print("[Datadog API] Span search error for issue " .. issue.id .. ": " .. vim.json.encode(span_err))
            check_complete()
            return
          end
          
          local formatted = {
            id = issue.id,
            occurrences = issue.total_count,
          }
          
          -- Extract details from first span if available
          if span_response and span_response.data and #span_response.data > 0 then
            local span = span_response.data[1]
            local attrs = span.attributes or {}
            local span_attrs = attrs.attributes or {}
            
            formatted.title = span_attrs["error.message"] or span_attrs["error.title"] or ""
            formatted.message = span_attrs["error.message"] or ""
            formatted.service = attrs.service or self.config.service or "unknown"
            formatted.status = span_attrs["error.type"] or "unknown"
            formatted.timestamp = attrs.start_timestamp or attrs.timestamp
            formatted.last_seen = attrs.end_timestamp or attrs.timestamp
            formatted.error_source = span_attrs["error.type"] or "unknown"
            formatted.file = span_attrs["file.path"] or nil
            formatted.line = span_attrs["file.line"] or nil
            formatted.stack_trace = span_attrs["error.stack"] or ""
            formatted.host = attrs.host or "unknown"
            formatted.env = attrs.env or self.config.env or "unknown"
          else
            -- Use defaults if no span found
            formatted.title = "Unknown error"
            formatted.message = ""
            formatted.service = self.config.service or "unknown"
            formatted.status = "unknown"
            formatted.timestamp = nil
            formatted.last_seen = nil
            formatted.error_source = "unknown"
            formatted.file = nil
            formatted.line = nil
            formatted.stack_trace = ""
            formatted.host = "unknown"
            formatted.env = self.config.env or "unknown"
          end
          
          table.insert(errors, formatted)
          print("[Datadog API] Formatted error: " .. vim.json.encode(formatted))
          check_complete()
        end)
      end
    else
      print("[Datadog API] No data in response or empty response")
      if callback then
        callback({}, nil)
      end
    end
  end)
end

-- Format raw Datadog Error Tracking entry into our error format
function M:_format_error_tracking(raw, included_map)
  local attributes = raw.attributes or {}
  local relationships = raw.relationships or {}
  local issue_data = relationships.issue and relationships.issue.data or {}
  
  -- Get issue ID from relationships
  local issue_id = issue_data.id or raw.id
  
  -- Look up the issue details from included array
  local issue_attrs = {}
  if included_map and included_map[issue_id] then
    issue_attrs = included_map[issue_id].attributes or {}
  end
  
  -- Extract file_path and function_name from issue attributes
  local file_path = issue_attrs.file_path
  local function_name = issue_attrs.function_name
  
  return {
    id = issue_id,
    title = issue_attrs.error_message or attributes.title or "",
    message = issue_attrs.error_message or attributes.message or "",
    service = issue_attrs.service or attributes.service or self.config.service or "unknown",
    status = issue_attrs.state or attributes.status or "unknown",
    environment = attributes.environment or self.config.env or "unknown",
    timestamp = issue_attrs.first_seen or attributes.first_seen or attributes.timestamp,
    last_seen = issue_attrs.last_seen or attributes.last_seen,
    severity = attributes.severity or "unknown",
    error_source = issue_attrs.error_type or attributes.source or "unknown",
    host = attributes.host or "unknown",
    -- Count of occurrences
    occurrences = attributes.total_count or 1,
    -- Extract file and line from stack trace
    file = file_path,
    line = nil,
    stack_trace = attributes.stack_trace or "",
  }
end

-- Extract file path from stack trace
function M:_extract_from_stack_trace(stack_trace)
  if not stack_trace or stack_trace == "" then
    return nil
  end
  
  -- Try common patterns in stack traces
  local patterns = {
    "([^%s]+%.lua):(%d+)",           -- Lua: filename:line
    "at%s+([^%s]+):(%d+)",            -- Java/JS: at filename:line
    "File%s+`([^`]+)`,%s+line%s+(%d+)", -- Python: File `file`, line X
    "([^%s]+):(%d+):%d+:%d+",         -- Rust: file:line:col
  }
  
  for _, pattern in ipairs(patterns) do
    local match = stack_trace:match(pattern)
    if match and not match:match("^[%d:]+$") then
      return match
    end
  end
  
  return nil
end

-- Extract line number from stack trace
function M:_extract_line_from_stack(stack_trace)
  if not stack_trace or stack_trace == "" then
    return nil
  end
  
  local patterns = {
    "([^%s]+%.lua):(%d+)",
    "at%s+([^%s]+):(%d+)",
    "File%s+`[^`]+`,%s+line%s+(%d+)",
    "([^%s]+):(%d+):%d+:%d+",
  }
  
  for _, pattern in ipairs(patterns) do
    local file, line = stack_trace:match(pattern)
    if file and line and not file:match("^[%d:]+$") then
      return tonumber(line)
    end
  end
  
  return nil
end

return M