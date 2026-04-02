-- Buffer management for datadog.nvim
-- Handles creation and display of the errors buffer using Nui Table

local M = {}

-- Required dependencies
local api = require('datadog.api')
local utils = require('datadog.utils')

-- Nui components
local Table = require('nui.table')

-- Buffer state
M.popup = nil
M.errors = {}

-- Show the errors popup using Nui Table
function M.show_errors_buffer()
  -- Create a popup
  local Popup = require('nui.popup')
  M.popup = Popup({
    position = { row = '100%', col = '100%' },
    size = { width = 90, height = 25 },
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
      
      -- Build table
      local lines = M.build_table_lines(M.errors)
      
      vim.api.nvim_buf_set_lines(M.popup.bufnr, 0, -1, false, lines)
    end)
  end)
end

-- Build table lines from errors
function M.build_table_lines(errors)
  local lines = {}
  
  if #errors == 0 then
    table.insert(lines, ' No errors found ')
    return lines
  end
  
  -- Header
  table.insert(lines, '┌─────────┬────────┬────────────────────┬────────────────────────────────────────────────────────────┐')
  table.insert(lines, '│  COUNT  │  TYPE  │ SERVICE             │ MESSAGE                                                        │')
  table.insert(lines, '├─────────┼────────┼────────────────────┼────────────────────────────────────────────────────────────┤')
  
  -- Error rows
  for i, error in ipairs(errors) do
    -- Count
    local count = string.format('%9d', error.occurrences or 0)
    
    -- Type (truncate to 8 chars)
    local error_type = error.status or error.error_source or 'unknown'
    if #error_type > 8 then
      error_type = error_type:sub(1, 8)
    end
    local type_str = string.format('%-8s', error_type)
    
    -- Service (truncate to 18 chars)
    local service = error.service or 'unknown'
    if #service > 18 then
      service = service:sub(1, 18)
    end
    local service_str = string.format('%-18s', service)
    
    -- Message (truncate to 60 chars)
    local message = error.title or error.message or 'Unknown error'
    if #message > 60 then
      message = message:sub(1, 57) .. '...'
    end
    local message_str = string.format('%-60s', message)
    
    table.insert(lines, string.format('│ %s │ %s │ %s │ %s │', count, type_str, service_str, message_str))
    
    -- File detail row
    if error.file then
      local file = error.file
      if #file > 58 then
        file = '...' .. file:sub(-55)
      end
      local timestamp = ''
      if error.timestamp then
        timestamp = utils.format_timestamp(error.timestamp)
      end
      local detail = string.format('%s:%s  (%s)', file, error.line or '', timestamp)
      if #detail > 60 then
        detail = detail:sub(1, 57) .. '...'
      end
      table.insert(lines, string.format('│           │        │                    │ └─ %-58s │', detail))
    end
  end
  
  -- Footer
  table.insert(lines, '└─────────┴────────┴────────────────────┴────────────────────────────────────────────────────────────┘')
  
  return lines
end

-- Navigate to the source file of the error under cursor
function M.navigate_to_error()
  if not M.popup or not M.popup:is_mounted() then
    return
  end
  
  local cursor = M.popup:win().cursor
  local line_num = cursor[1]
  
  -- Each error takes 1-2 rows (header + possible detail row)
  -- Skip header rows (3 rows: top border, header, middle border)
  local header_rows = 3
  local current_line = line_num - header_rows
  
  if current_line < 1 then
    vim.notify('No error at this line', vim.log.levels.WARN)
    return
  end
  
  -- Each error takes 1 or 2 lines (1 if no file, 2 if has file)
  -- We need to find which error index this is
  local error_index = 0
  local line_count = header_rows
  
  for i, error in ipairs(M.errors) do
    line_count = line_count + 1  -- main row
    if error.file then
      line_count = line_count + 1  -- detail row
    end
    
    if line_num <= line_count then
      error_index = i
      break
    end
  end
  
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