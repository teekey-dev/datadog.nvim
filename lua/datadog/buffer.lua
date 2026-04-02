-- Buffer management for datadog.nvim
-- Handles creation and display of the errors buffer using Nui Table

local M = {}

-- Required dependencies
local api = require('datadog.api')
local utils = require('datadog.utils')

-- Nui components
local Popup = require('nui.popup')
local Table = require('nui.table')

-- Buffer state
M.popup = nil
M.errors = {}

-- Show the errors popup using Nui Table
function M.show_errors_buffer()
  -- Create a popup
  M.popup = Popup({
    position = { row = '100%', col = '100%' },
    size = { width = 100, height = 25 },
    relative = { type = 'editor', anchor = 'NW' },
    anchor = 'NW',
    border = {
      style = 'rounded',
      text = {
        top = ' Datadog Errors ',
        top_align = 'center',
      },
    },
    zindex = 100,
  })
  
  -- Set up key mappings
  M.popup:map('n', 'q', function()
    M.close_buffer()
  end, { noremap = true })
  
  M.popup:map('n', '<ESC>', function()
    M.close_buffer()
  end, { noremap = true })
  
  M.popup:map('n', 'r', function()
    M.refresh_errors()
  end, { noremap = true })
  
  M.popup:map('n', '<CR>', function()
    M.navigate_to_error()
  end, { noremap = true })
  
  M.popup:map('n', 'j', function()
    M.move_cursor(1)
  end, { noremap = true })
  
  M.popup:map('n', 'k', function()
    M.move_cursor(-1)
  end, { noremap = true })
  
  -- Show the popup
  M.popup:mount()
  
  -- Load and display errors
  M.refresh_errors()
end

-- Move cursor to next/previous error
function M.move_cursor(direction)
  if not M.popup or not M.popup:is_mounted() then
    return
  end
  
  if #M.errors == 0 then
    return
  end
  
  local cursor = M.popup:win().cursor
  local new_line = cursor[1] + direction
  
  local buf_line_count = vim.api.nvim_buf_line_count(M.popup.bufnr)
  
  if new_line < 1 then
    new_line = 1
  elseif new_line > buf_line_count then
    new_line = buf_line_count
  end
  
  M.popup:win().cursor = { new_line, 0 }
end

-- Refresh errors from Datadog API
function M.refresh_errors()
  if not M.popup or not M.popup:is_mounted() then
    return
  end
  
  -- Show loading message
  vim.api.nvim_buf_set_lines(M.popup.bufnr, 0, -1, false, {
    ' Loading errors from Datadog...',
  })
  
  -- Fetch errors from API
  local api_client = api.new(require('datadog').config)
  api_client:fetch_errors(function(errors, err)
    -- Schedule all UI operations to run on the main event loop
    vim.schedule(function()
      if not M.popup or not M.popup:is_mounted() then
        return
      end
      
      if err then
        vim.api.nvim_buf_set_lines(M.popup.bufnr, 0, -1, false, {
          string.format(' Error: %s', err.error or 'Unknown error'),
          '',
          " Press 'r' to retry or 'q' to close",
        })
        return
      end
      
      -- Store errors for navigation
      M.errors = errors or {}
      
      -- Build and render table
      M.render_table(M.errors)
    end)
  end)
end

-- Render table with Nui Table
function M.render_table(errors)
  if #errors == 0 then
    vim.api.nvim_buf_set_lines(M.popup.bufnr, 0, -1, false, { ' No errors found ' })
    return
  end
  
  -- Define columns
  local columns = {
    {
      id = 'count',
      header = 'COUNT',
      width = 10,
      align = 'right',
    },
    {
      id = 'type',
      header = 'TYPE',
      width = 12,
    },
    {
      id = 'service',
      header = 'SERVICE',
      width = 20,
    },
    {
      id = 'message',
      header = 'MESSAGE',
      width = 40,
    },
    {
      id = 'file',
      header = 'FILE',
      width = 30,
    },
  }
  
  -- Prepare data with accessor functions
  local data = {}
  for i, error in ipairs(errors) do
    local timestamp = ''
    if error.timestamp then
      timestamp = utils.format_timestamp(error.timestamp)
    end
    
    local file_info = ''
    if error.file then
      file_info = error.file .. ':' .. (error.line or '')
    end
    
    table.insert(data, {
      index = i,
      count = tostring(error.occurrences or 0),
      type = error.status or error.error_source or 'unknown',
      service = error.service or 'unknown',
      message = error.title or error.message or 'Unknown error',
      file = file_info .. ' ' .. timestamp,
    })
  end
  
  -- Create and mount table
  local table_instance = Table({
    bufnr = M.popup.bufnr,
    columns = columns,
    data = data,
  })
  
  table_instance:render()
end

-- Navigate to the source file of the error under cursor
function M.navigate_to_error()
  if not M.popup or not M.popup:is_mounted() then
    return
  end
  
  local cursor = M.popup:win().cursor
  local line_num = cursor[1]
  
  -- Get line count before header (header is 2 lines: header + separator)
  local header_lines = 2
  
  if line_num <= header_lines then
    vim.notify('No error at this line', vim.log.levels.WARN)
    return
  end
  
  local error_index = line_num - header_lines
  
  if error_index < 1 or error_index > #M.errors then
    vim.notify('No error at this line', vim.log.levels.WARN)
    return
  end
  
  local error = M.errors[error_index]
  
  if not error.file then
    vim.notify('No file information available for this error', vim.log.levels.WARN)
    return
  end
  
  -- Close the popup
  M.close_buffer()
  
  -- Open the file
  vim.cmd('edit ' .. vim.fn.fnameescape(error.file))
  
  -- Navigate to line if available
  if error.line and error.line > 0 then
    vim.api.nvim_win_set_cursor(0, {error.line, 0})
    vim.notify(string.format('Navigated to %s:%d', error.file, error.line), vim.log.levels.INFO)
  else
    vim.notify(string.format('Opened %s', error.file), vim.log.levels.INFO)
  end
end

-- Close the errors popup
function M.close_buffer()
  if M.popup and M.popup:is_mounted() then
    M.popup:unmount()
    M.popup = nil
  end
end

return M