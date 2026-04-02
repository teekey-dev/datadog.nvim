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
M.error_line_map = {}

-- Format errors for display in the buffer
function M.format_errors_for_split(errors)
  local lines = {}
  M.error_line_map = {}
  
  -- Header
  table.insert(lines, " Datadog Error Tracking ")
  table.insert(lines, string.rep("─", 60))
  
  if #errors == 0 then
    table.insert(lines, " No errors found ")
    return lines
  end
  
  -- Column headers
  table.insert(lines, "")
  table.insert(lines, string.format("%-8s │ %-6s │ %-18s │ %-20s", 
    "COUNT", "TYPE", "SERVICE", "MESSAGE"))
  table.insert(lines, string.rep("─", 76))
  
  -- Error entries
  for i, error in ipairs(errors) do
    local line_index = #lines + 1
    
    -- Occurrences
    local occurrences = error.occurrences or 0
    
    -- Error Type
    local error_type = error.status or error.error_source or "unknown"
    if #error_type > 6 then
      error_type = error_type:sub(1, 6)
    end
    
    -- Service
    local service = error.service or "unknown"
    if #service > 18 then
      service = service:sub(1, 15) .. "..."
    end
    
    -- Message (title)
    local message = error.title or error.message or "Unknown error"
    if #message > 20 then
      message = message:sub(1, 17) .. "..."
    end
    
    -- Timestamp
    local timestamp = ""
    if error.timestamp then
      timestamp = utils.format_timestamp(error.timestamp)
    end
    
    -- File info
    local file_info = ""
    if error.file then
      local file = error.file
      if #file > 30 then
        file = "..." .. file:sub(-27)
      end
      file_info = string.format("%s:%s", file, error.line or "")
    end
    
    -- Line with error data
    table.insert(lines, string.format("%-8d │ %-6s │ %-18s │ %-20s", 
      occurrences, error_type, service, message))
    M.error_line_map[#lines] = { error_index = i }
    
    -- Detail line (file and timestamp)
    if file_info ~= "" or timestamp ~= "" then
      local detail = ""
      if file_info ~= "" and timestamp ~= "" then
        detail = file_info .. "  |  " .. timestamp
      elseif file_info ~= "" then
        detail = file_info
      else
        detail = timestamp
      end
      table.insert(lines, "  └─ " .. detail)
      M.error_line_map[#lines] = { error_index = i }
    end
    
    -- Separator
    if i < #errors then
      table.insert(lines, "")
    end
  end
  
  return lines
end

-- Create and show the errors split at the bottom
function M.show_errors_buffer()
  -- Create a new scratch buffer
  M.bufnr = vim.api.nvim_create_buf(false, true)
  
  -- Set buffer options
  vim.api.nvim_buf_set_option(M.bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(M.bufnr, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(M.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_name(M.bufnr, 'Datadog Errors')
  
  -- Open horizontal split at the bottom
  vim.cmd('botright new')
  
  -- Set the buffer to the current window
  vim.api.nvim_win_set_buf(0, M.bufnr)
  M.winid = vim.api.nvim_get_current_win()
  
  -- Set window options
  vim.api.nvim_win_set_option(M.winid, 'wrap', false)
  vim.api.nvim_win_set_option(M.winid, 'number', false)
  vim.api.nvim_win_set_option(M.winid, 'cursorline', true)
  
  -- Set split height to 15 lines
  vim.cmd('resize 15')
  
  -- Set up key mappings
  local opts = { noremap = true, silent = true, buffer = M.bufnr }
  
  vim.api.nvim_buf_set_keymap(M.bufnr, 'n', 'q', '<cmd>lua require("datadog.buffer").close_buffer()<CR>', opts)
  vim.api.nvim_buf_set_keymap(M.bufnr, 'n', '<ESC>', '<cmd>lua require("datadog.buffer").close_buffer()<CR>', opts)
  vim.api.nvim_buf_set_keymap(M.bufnr, 'n', 'r', '<cmd>lua require("datadog.buffer").refresh_errors()<CR>', opts)
  vim.api.nvim_buf_set_keymap(M.bufnr, 'n', '<CR>', '<cmd>lua require("datadog.buffer").navigate_to_error()<CR>', opts)
  vim.api.nvim_buf_set_keymap(M.bufnr, 'n', 'j', '<cmd>lua require("datadog.buffer").move_cursor(1)<CR>', opts)
  vim.api.nvim_buf_set_keymap(M.bufnr, 'n', 'k', '<cmd>lua require("datadog.buffer").move_cursor(-1)<CR>', opts)
  
  -- Load and display errors
  M.refresh_errors()
end

-- Move cursor to next/previous error
function M.move_cursor(direction)
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return
  end
  
  if #M.errors == 0 then
    return
  end
  
  local cursor = vim.api.nvim_win_get_cursor(0)
  local new_line = cursor[1] + direction
  
  local buf_line_count = vim.api.nvim_buf_line_count(M.bufnr)
  
  if new_line < 1 then
    new_line = 1
  elseif new_line > buf_line_count then
    new_line = buf_line_count
  end
  
  vim.api.nvim_win_set_cursor(0, { new_line, 0 })
end

-- Refresh errors from Datadog API
function M.refresh_errors()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return
  end
  
  -- Show loading message
  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, {
    " Loading errors from Datadog...",
  })
  
  -- Fetch errors from API
  local api_client = api.new(require('datadog').config)
  api_client:fetch_errors(function(errors, err)
    -- Schedule all UI operations to run on the main event loop
    vim.schedule(function()
      if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
        return
      end
      
      if err then
        vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, {
          string.format(" Error: %s", err.error or "Unknown error"),
          "",
          " Press 'r' to retry or 'q' to close",
        })
        return
      end
      
      -- Store errors for navigation
      M.errors = errors or {}
      
      -- Format and display errors
      local lines = M.format_errors_for_split(M.errors)
      
      vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)
      
      -- Make buffer read-only
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
  
  -- Get error index from line map
  local line_data = M.error_line_map[line_num]
  local error_index = line_data and line_data.error_index
  
  if not error_index then
    vim.notify("No error at this line", vim.log.levels.WARN)
    return
  end
  
  local error = M.errors[error_index]
  
  if not error.file then
    vim.notify("No file information available for this error", vim.log.levels.WARN)
    return
  end
  
  -- Close the buffer
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
  M.bufnr = nil
end

return M