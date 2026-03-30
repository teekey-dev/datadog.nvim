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
  
  -- Column headers
  table.insert(lines, string.format("%-20s %-15s %-40s %-10s", 
    "Timestamp", "Service", "Message", "Status"))
  table.insert(lines, string.rep("─", 85))
  
  -- Error entries
  for _, error in ipairs(errors) do
    local timestamp = error.timestamp or ""
    if timestamp ~= "" then
      -- Format timestamp to show relative time or just time part
      timestamp = utils.format_timestamp(timestamp)
    end
    
    local service = error.service or "unknown"
    local message = error.message or ""
    -- Truncate message if too long
    if #message > 40 then
      message = message:sub(1, 37) .. "..."
    end
    local status = error.status or "unknown"
    
    table.insert(lines, string.format("%-20s %-15s %-40s %-10s", 
      timestamp, service, message, status))
  end
  
  return lines
end

-- Show the errors buffer
function M.show_errors_buffer()
  -- Create buffer if it doesn't exist
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    M.bufnr = M.create_buffer()
  end
  
  -- Set up mappings
  M.setup_mappings(M.bufnr)
  
  -- Get current tabpage and open buffer in a split
  vim.cmd('tabnew')
  vim.api.nvim_win_set_buf(0, M.bufnr)
  M.winid = vim.api.nvim_get_current_win()
  
  -- Set window options
  vim.api.nvim_win_set_option(M.winid, 'wrap', false)
  vim.api.nvim_win_set_option(M.winid, 'number', true)
  vim.api.nvim_win_set_option(M.winid, 'relativenumber', true)
  
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
end

-- Navigate to the source file of the error under cursor
function M.navigate_to_error()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return
  end
  
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  
  -- Account for header lines (timestamp, service, message, status headers + separator)
  local header_lines = 4 -- Header, separator, empty line, column headers, separator
  local error_index = line_num - header_lines
  
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