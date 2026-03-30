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
    table.insert(args, "--data")
    table.insert(args, vim.json.encode(data))
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
    local url = handle:read("*a"):gsub("%s+$", "")
    handle:close()
    
    if url and url ~= "" then
      -- Convert to @git.repository:id format
      local repo_id = url:gsub("%.git$", ""):gsub("^https?://", ""):gsub("^git@", "")
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
  
  local query_string = table.concat(filters, " ")
  
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
  
  -- Build request body in correct format
  local request_body = {
    data = {
      type = "search_request",
      attributes = {
        query = query_string,
        from = from_time,
        to = to_time,
        track = "logs", -- Use "logs" track for error tracking from logs
        order_by = "FIRST_SEEN",
      }
    }
  }
  
  print("[Datadog API] Full Query: " .. vim.json.encode(request_body))
  
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
    if response and response.data then
      print("[Datadog API] Processing " .. #response.data .. " error tracking items")
      for _, item in ipairs(response.data) do
        local formatted = self:_format_error_tracking(item)
        table.insert(errors, formatted)
        print("[Datadog API] Formatted error: " .. vim.json.encode(formatted))
      end
    else
      print("[Datadog API] No data in response or empty response")
    end
    
    print("[Datadog API] Returning " .. #errors .. " errors")
    if callback then
      callback(errors, nil)
    end
  end)
end

-- Format raw Datadog Error Tracking entry into our error format
function M:_format_error_tracking(raw)
  local attributes = raw.attributes or {}
  local details = attributes.details or {}
  
  return {
    id = raw.id,
    title = details.title or attributes.title or "",
    message = details.message or attributes.message or "",
    service = details.service or attributes.service or self.config.service or "unknown",
    status = details.status or attributes.status or "unknown",
    environment = details.environment or attributes.environment or self.config.env or "unknown",
    timestamp = details.first_seen or attributes.first_seen or raw.attributes.timestamp,
    last_seen = details.last_seen or attributes.last_seen,
    severity = details.severity or attributes.severity or "unknown",
    error_source = details.source or attributes.source or "unknown",
    host = details.host or attributes.host or "unknown",
    -- Extract file and line information
    file = details.file or self:_extract_from_stack_trace(details.stack_trace),
    line = details.line or self:_extract_line_from_stack(details.stack_trace),
    stack_trace = details.stack_trace or "",
    -- Number of occurrences
    occurrences = details.occurrence_count or attributes.occurrence_count or 1,
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