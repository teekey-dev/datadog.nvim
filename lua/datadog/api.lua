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

-- Make HTTP request to Datadog API
function M:_request(method, endpoint, data, callback)
  local url = self:_build_url(endpoint)
  local headers = self:_build_headers()
  
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
  
  Job:new({
    command = "curl",
    args = args,
    on_exit = function(j, return_val)
      if return_val ~= 0 then
        local stderr = table.concat(j:stderr_result(), "\n")
        vim.notify(string.format("Datadog API error: %s", stderr), vim.log.levels.ERROR)
        if callback then
          callback(nil, { error = stderr })
        end
        return
      end
      
      local result = table.concat(j:result(), "")
      local parsed
      pcall(function() parsed = vim.json.decode(result) end)
      
      if callback then
        callback(parsed, nil)
      end
    end
  }):start()
end

-- Fetch error logs from Datadog
function M:fetch_errors(callback)
  local query = {
    filter = {
      query = self.config.query.filter.query or "@status:error",
    },
    page = {
      limit = self.config.query.limit or 100,
    },
    sort = self.config.query.sort or "-timestamp",
  }
  
  -- Add time range if specified
  if self.config.query.time_range then
    query.filter["from"] = "now-" .. self.config.query.time_range
    query.filter["to"] = "now"
  end
  
  self:_request("POST", "logs/query", query, function(response, err)
    if err then
      if callback then
        callback(nil, err)
      end
      return
    end
    
    -- Process and format the response
    local errors = {}
    if response and response.data then
      for _, item in ipairs(response.data) do
        table.insert(errors, self:_format_error(item))
      end
    end
    
    if callback then
      callback(errors, nil)
    end
  end)
end

-- Format raw Datadog log entry into our error format
function M:_format_error(raw)
  local attributes = raw.attributes or {}
  
  return {
    id = raw.id,
    timestamp = attributes.timestamp,
    service = attributes.service or "unknown",
    message = attributes.message or "",
    status = attributes.status or "info",
    source = attributes.source or "unknown",
    host = attributes.host or "unknown",
    tags = attributes.tags or {},
    -- Extract file and line information if available
    file = self:_extract_file_info(attributes),
    line = self:_extract_line_info(attributes),
  }
end

-- Extract file information from log attributes
function M:_extract_file_info(attributes)
  -- Try common fields where file info might be stored
  if attributes.file then
    return attributes.file
  end
  
  if attributes.source and attributes.source.file then
    return attributes.source.file
  end
  
  -- Check in tags
  for _, tag in ipairs(attributes.tags or {}) do
    if tag:match("^file:") then
      return tag:sub(6) -- Remove "file:" prefix
    end
    if tag:match("^source:") then
      return tag:sub(8) -- Remove "source:" prefix
    end
  end
  
  return nil
end

-- Extract line information from log attributes
function M:_extract_line_info(attributes)
  -- Try common fields where line info might be stored
  if attributes.line then
    return tonumber(attributes.line)
  end
  
  if attributes.source and attributes.source.line then
    return tonumber(attributes.source.line)
  end
  
  -- Check in tags
  for _, tag in ipairs(attributes.tags or {}) do
    if tag:match("^line:%d+$") then
      return tonumber(tag:sub(6)) -- Remove "line:" prefix
    end
  end
  
  return nil
end

return M