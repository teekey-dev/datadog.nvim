-- Utility functions for datadog.nvim

local M = {}

-- Format timestamp to relative time or readable format
function M.format_timestamp(timestamp_str)
  if not timestamp_str or timestamp_str == "" then
    return "unknown"
  end
  
  -- Parse ISO timestamp
  local year, month, day, hour, min, sec = timestamp_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return timestamp_str -- Return as-is if parsing fails
  end
  
  local log_time = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec)
  })
  
  local now = os.time()
  local diff = difftime(now, log_time)
  
  -- Format based on time difference
  if diff < 60 then
    return string.format("%ds ago", diff)
  elseif diff < 3600 then
    return string.format("%dm ago", math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format("%dh ago", math.floor(diff / 3600))
  else
    return string.format("%dd ago", math.floor(diff / 86400))
  end
end

-- Highlight error levels in the buffer
function M.setup_highlights()
  -- Define highlight groups for different error statuses
  vim.api.nvim_set_hl(0, 'DatadogErrorError', { fg = '#ff0000', bold = true })
  vim.api.nvim_set_hl(0, 'DatadogErrorWarning', { fg = '#ffa500' })
  vim.api.nvim_set_hl(0, 'DatadogErrorInfo', { fg = '#0000ff' })
  vim.api.nvim_set_hl(0, 'DatadogErrorDebug', { fg = '#808080' })
end

-- Apply highlights to error buffer lines
function M.apply_highlights(bufnr, errors)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  
  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
  
  -- Header lines (4 lines: title, separator, empty, headers)
  local header_lines = 4
  
  for i, error in ipairs(errors) do
    local line_num = header_lines + i - 1 -- 0-indexed for buffer
    
    local hl_group
    local status = (error.status or "info"):lower()
    
    if status == "error" then
      hl_group = 'DatadogErrorError'
    elseif status == "warning" then
      hl_group = 'DatadogErrorWarning'
    elseif status == "info" then
      hl_group = 'DatadogErrorInfo'
    elseif status == "debug" then
      hl_group = 'DatadogErrorDebug'
    else
      hl_group = 'DatadogErrorInfo' -- default
    end
    
    -- Apply highlight to the status column (approximately column 70-80)
    -- This is approximate since we're using formatted strings
    vim.api.nvim_buf_add_highlight(bufnr, -1, hl_group, line_num, 70, 80)
  end
end

return M