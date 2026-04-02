-- Buffer management for datadog.nvim
-- Handles creation and display of the errors buffer using Nui Split

local M = {}

-- Required dependencies
local api = require('datadog.api')
local utils = require('datadog.utils')

-- Nui components
local Split = require('nui.split')

-- Buffer state
M.split = nil
M.errors = {}
M.error_line_map = {}

-- Format errors for display in the split
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
  -- Create split at the bottom
  M.split = Split({
    position = "50%",
    size = 15,
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = " Datadog Errors ",
        top_align = "center",
      },
    },
  })
  
  -- Set up key mappings
  M.split:map("n", "q", function()
    M.close_buffer()
  end, { noremap = true })
  
  M.split:map("n", "<ESC>", function()
    M.close_buffer()
  end, { noremap = true })
  
  M.split:map("n", "r", function()
    M.refresh_errors()
  end, { noremap = true })
  
  M.split:map("n", "<CR>", function()
    M.navigate_to_error()
  end, { noremap = true })
  
  M.split:map("n", "j", function()
    M.move_cursor(1)
  end, { noremap = true })
  
  M.split:map("n", "k", function()
    M.move_cursor(-1)
  end, { noremap = true })
  
  -- Show the split
  M.split:mount()
  
  -- Set buffer options
  local bufnr = M.split.bufnr
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'hide')
  
  -- Load and display errors
  M.refresh_errors()
end

-- Move cursor to next/previous error
function M.move_cursor(direction)
  if not M.split or not M.split:is_mounted() then
    return
  end
  
  if #M.errors == 0 then
    return
  end
  
  local cursor = M.split:win().cursor
  local new_line = cursor[1] + direction
  
  local buf_line_count = vim.api.nvim_buf_line_count(M.split.bufnr)
  
  if new_line < 1 then
    new_line = 1
  elseif new_line > buf_line_count then
    new_line = buf_line_count
  end
  
  M.split:win().cursor = { new_line, 0 }
end

-- Refresh errors from Datadog API
function M.refresh_errors()
  if not M.split or not M.split:is_mounted() then
    return
  end
  
  local bufnr = M.split.bufnr
  
  -- Show loading message
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    " Loading errors from Datadog...",
  })
  
  -- Fetch errors from API
  local api_client = api.new(require('datadog').config)
  api_client:fetch_errors(function(errors, err)
    -- Schedule all UI operations to run on the main event loop
    vim.schedule(function()
      if not M.split or not M.split:is_mounted() then
        return
      end
      
      local bufnr = M.split.bufnr
      
      if err then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
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
      
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      
      -- Make buffer read-only
      vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
    end)
  end)
end

-- Navigate to the source file of the error under cursor
function M.navigate_to_error()
  if not M.split or not M.split:is_mounted() then
    return
  end
  
  local cursor = M.split:win().cursor
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
  
  -- Close the split
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

-- Close the errors split
function M.close_buffer()
  if M.split and M.split:is_mounted() then
    M.split:unmount()
    M.split = nil
  end
end

return M