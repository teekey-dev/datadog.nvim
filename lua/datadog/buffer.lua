-- Buffer management for datadog.nvim
-- Handles creation and display of the errors buffer

local M = {}

-- Required dependencies
local api = require('datadog.api')
local utils = require('datadog.utils')

-- Buffer state
M.bufnr = nil
M.winid = nil
M.errors = {}

-- Create a new errors buffer
function M.create_buffer()
  -- Create a new scratch buffer
  local bufnr = vim.api.nvim_create_buf(false, true) -- no file, scratch buffer
  
  -- Set buffer options
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  
  -- Set buffer name
  vim.api.nvim_buf_set_name(bufnr, 'Datadog Errors')
  
  return bufnr
end

-- Set up key mappings for the buffer
function M.setup_mappings(bufnr)
  local opts = { noremap = true, silent = true }
  
  -- Navigate to source file on Enter
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<CR>', 
    [[<cmd>lua require('datadog.buffer').navigate_to_error()<CR>]], opts)
  
  -- Refresh errors with 'r'
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'r', 
    [[<cmd>lua require('datadog.buffer').refresh_errors()<CR>]], opts)
  
  -- Close buffer with 'q' or ESC
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', 
    [[<cmd>lua require('datadog.buffer').close_buffer()<CR>]], opts)
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<ESC>', 
    [[<cmd>lua require('datadog.buffer').close_buffer()<CR>]], opts)
end

-- Format errors for display in the buffer
function M.format_errors_for_display(errors)
  local lines = {}
  
  -- Header
  table.insert(lines, " Datadog Error Tracking ")
  table.insert(lines, string.rep("─", vim.fn.strwidth(lines[1])))
  table.insert(lines, "")
  
  if #errors == 0 then
    table.insert(lines, " No errors found ")
    return lines
  end
  
  -- Error entries with detailed information
  for _, error in ipairs(errors) do
    -- ID (truncated)
    local id = error.id or "unknown"
    if #id > 8 then
      id = id:sub(1, 8) .. "..."
    end
    
    -- Timestamp
    local timestamp = ""
    if error.timestamp then
      timestamp = utils.format_timestamp(error.timestamp)
    end
    
    -- Service
    local service = error.service or "unknown"
    if #service > 20 then
      service = service:sub(1, 17) .. "..."
    end
    
    -- Status/Error Type
    local status = error.status or error.error_source or "unknown"
    if #status > 15 then
      status = status:sub(1, 12) .. "..."
    end
    
    -- Occurrences
    local occurrences = error.occurrences or 0
    
    -- Message (title)
    local message = error.title or error.message or ""
    if #message > 50 then
      message = message:sub(1, 47) .. "..."
    end
    
    -- File path
    local file = error.file or ""
    if #file > 40 then
      file = "..." .. file:sub(-37)
    end
    
    -- Line number
    local line = error.line or ""
    
    -- Stack trace (first line only)
    local stack = error.stack_trace or ""
    local stack_preview = ""
    if #stack > 50 then
      stack_preview = stack:sub(1, 47) .. "..."
    else
      stack_preview = stack
    end
    
    -- Error type/source
    local error_type = error.error_source or ""
    
    -- Host and Environment
    local env = error.env or "unknown"
    local host = error.host or "unknown"
    if #host > 15 then
      host = host:sub(1, 12) .. "..."
    end
    
    -- Build formatted lines for this error entry
    -- Line 1: ID | Timestamp | Service | Status | Occurrences
    table.insert(lines, string.format(" %-10s │ %-12s │ %-20s │ %-15s │ %-6d ", 
      id, timestamp, service, status, occurrences))
    
    -- Line 2: Message
    table.insert(lines, string.format(" %-10s │ %s ", "", message))
    
    -- Line 3: File:Line
    if file ~= "" then
      table.insert(lines, string.format(" %-10s │ %s:%s ", "", file, line))
    end
    
    -- Line 4: Error type
    if error_type ~= "" then
      table.insert(lines, string.format(" %-10s │ type: %s ", "", error_type))
    end
    
    -- Line 5: Stack trace preview
    if stack_preview ~= "" then
      table.insert(lines, string.format(" %-10s │ %s ", "", stack_preview))
    end
    
    -- Line 6: Host | Environment
    table.insert(lines, string.format(" %-10s │ host: %-15s │ env: %s ", "", host, env))
    
    -- Separator between errors
    table.insert(lines, string.rep("─", 100))
  end
  
  return lines
end

-- Show the errors buffer in a split at the bottom
function M.show_errors_buffer()
  -- Create buffer if it doesn't exist
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    M.bufnr = M.create_buffer()
  end
  
  -- Set up mappings
  M.setup_mappings(M.bufnr)
  
  -- Open a horizontal split at the bottom
  vim.cmd('split')
  
  -- Move the split to the bottom
  vim.cmd('wincmd J')
  
  -- Set split height (default 15 lines)
  vim.cmd('resize 15')
  
  -- Set the buffer to the window
  vim.api.nvim_win_set_buf(0, M.bufnr)
  M.winid = vim.api.nvim_get_current_win()
  
  -- Set window options
  vim.api.nvim_win_set_option(M.winid, 'wrap', true)
  vim.api.nvim_win_set_option(M.winid, 'number', false)
  vim.api.nvim_win_set_option(M.winid, 'relativenumber', false)
  vim.api.nvim_win_set_option(M.winid, 'cursorline', true)
  
  -- Load and display errors
  M.refresh_errors()
end

-- Refresh errors from Datadog API
function M.refresh_errors()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return
  end
  
  -- Make buffer modifiable temporarily
  vim.api.nvim_buf_set_option(M.bufnr, 'modifiable', true)
  
  -- Show loading message
  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, {
    " Datadog Error Tracking ",
    string.rep("─", vim.fn.strwidth(" Datadog Error Tracking ")),
    "",
    " Loading errors from Datadog... ",
  })
  
  -- Fetch errors from API
  local api_client = api.new(require('datadog').config)
  api_client:fetch_errors(function(errors, err)
    -- Schedule all UI operations to run on the main event loop
    vim.schedule(function()
      if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
        return
      end
      
      -- Make buffer modifiable temporarily
      vim.api.nvim_buf_set_option(M.bufnr, 'modifiable', true)
      
      if err then
        vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, {
          " Datadog Error Tracking ",
          string.rep("─", vim.fn.strwidth(" Datadog Error Tracking ")),
          "",
          string.format(" Error fetching data: %s ", err.error or "Unknown error"),
          "",
          " Press 'r' to retry ",
        })
        return
      end
      
      -- Store errors for navigation
      M.errors = errors or {}
      
      -- Format and display errors
      local lines = M.format_errors_for_display(M.errors)
      vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
      
      -- Make buffer read-only again
      vim.api.nvim_buf_set_option(M.bufnr, 'modifiable', false)
    end)
  end)
end

-- Navigate to the source file of the error under cursor
function M.navigate_to_error()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return
  end
  
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  
  -- New format: 2 header lines, then 7 lines per error (6 info lines + 1 separator)
  local header_lines = 2
  local lines_per_error = 7
  
  -- Find which error we're on by counting back through separators
  local current_line = line_num
  local error_index = 0
  
  -- Go back through the buffer to find which error we're on
  while current_line > header_lines do
    -- Check if this is a separator line (all dashes)
    local line_content = vim.api.nvim_buf_get_lines(M.bufnr, current_line - 1, current_line, false)[1]
    if line_content and line_content:match("^%-+$") then
      -- This is a separator, the error is before it
      error_index = error_index + 1
    end
    current_line = current_line - 1
  end
  
  if error_index < 1 or error_index > #M.errors then
    vim.notify("No error at this line", vim.log.levels.WARN)
    return
  end
  
  local error = M.errors[error_index]
  
  if not error.file then
    vim.notify("No file information available for this error", vim.log.levels.WARN)
    return
  end
  
  -- Close the errors buffer
  M.close_buffer()
  
  -- Open the file
  vim.cmd('edit ' .. vim.fn.fnameescape(error.file))
  
  -- Navigate to line if available
  if error.line and error.line > 0 then
    vim.api.nvim_win_set_cursor(0, {error.line, 0})
    vim.notify(string.format("Navigated to %s:%d", error.file, error.line), vim.log.levels.INFO)
  else
    vim.notify(string.format("Opened %s", error.file), vim.log.levels.INFO)
  end
end

-- Close the errors buffer
function M.close_buffer()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_close(M.winid, true)
    M.winid = nil
  end
  
  -- Note: We don't delete the buffer as it's a scratch buffer that will be wiped when hidden
end

return M