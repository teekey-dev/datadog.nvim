-- Buffer management for datadog.nvim
-- Side-by-side issue list (left) + detail pane (right) inside a bottom layout.

local M = {}

local api = require("datadog.api")
local utils = require("datadog.utils")

local Layout = require("nui.layout")
local Popup = require("nui.popup")
local Table = require("nui.table")

-- UI state
M.layout = nil
M.list_popup = nil
M.detail_popup = nil
M.errors = {}
M.last_rendered_index = nil
M._fallback_split = nil -- when terminal is too short for side-by-side
M._autocmd_group = nil

local MIN_LINES = 25
local LAYOUT_HEIGHT = 20
local LIST_HEADER_LINES = 2 -- Nui Table renders a header row + separator

-- Forward declarations
local render_detail
local close_layout

local function set_lines(bufnr, lines)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

local function detail_width()
	if not M.detail_popup or not M.detail_popup.winid then
		return 50
	end
	if not vim.api.nvim_win_is_valid(M.detail_popup.winid) then
		return 50
	end
	return vim.api.nvim_win_get_width(M.detail_popup.winid)
end

-- Build the detail-pane lines for a single error
local function build_detail_lines(err, width)
	if not err then
		return { "", "  Move cursor to a row" }
	end

	local trunc = function(s)
		return utils.truncate(s or "", width)
	end

	local lines = {}
	table.insert(lines, trunc(string.format(" %s  %s", (err.status or "ERR"):upper(), err.title or "Unknown error")))
	if err.message and err.message ~= err.title and err.message ~= "" then
		table.insert(lines, trunc(" " .. err.message))
	end
	table.insert(lines, string.rep("─", math.max(0, width)))

	local svc = err.service or "unknown"
	local env = err.env or "unknown"
	local host = err.host or "unknown"
	table.insert(lines, trunc(string.format(" service  %s · %s · %s", svc, env, host)))

	local first_rel = utils.format_timestamp_ms(err.first_seen)
	local last_rel = utils.format_timestamp_ms(err.last_seen)
	local first_commit = utils.short_commit(err.first_seen_version)
	local last_commit = utils.short_commit(err.last_seen_version)

	table.insert(lines, trunc(string.format(" first    %-12s %s", first_rel, first_commit)))
	table.insert(lines, trunc(string.format(" last     %-12s %s", last_rel, last_commit)))
	table.insert(lines, trunc(string.format(" count    %d", err.occurrences or 0)))

	-- Trend sparkline (Stage 2). Reserve a label + " (peak N)" suffix; the rest is sparkline.
	local trend = err.trend
	if trend and trend.buckets and #trend.buckets > 0 then
		local peak_label = string.format(" (peak %d)", trend.peak or 0)
		local label = " trend    "
		local spark_width = math.max(8, width - vim.fn.strdisplaywidth(label) - vim.fn.strdisplaywidth(peak_label))
		local spark = utils.sparkline(trend.buckets, spark_width)
		table.insert(lines, trunc(label .. spark .. peak_label))
	else
		table.insert(lines, trunc(" trend    (unavailable)"))
	end

	if err.file then
		table.insert(lines, trunc(string.format(" at       %s:%s", err.file, err.line or "?")))
	end

	table.insert(lines, string.rep("─", math.max(0, width)))
	table.insert(lines, " Stack:")

	local stack = err.stack_trace or ""
	if stack == "" then
		table.insert(lines, "   (no stack trace)")
	else
		for line in stack:gmatch("([^\n]*)\n?") do
			if line ~= "" then
				table.insert(lines, "  " .. line)
			end
		end
	end

	return lines
end

-- Render the detail pane for the issue at the given list-row index (1-based)
render_detail = function(idx)
	if not M.detail_popup or not M.detail_popup.bufnr then
		return
	end
	if M.last_rendered_index == idx then
		return
	end
	M.last_rendered_index = idx

	local err = M.errors[idx]
	local width = detail_width() - 2 -- account for border padding
	set_lines(M.detail_popup.bufnr, build_detail_lines(err, width))
	-- Reset cursor to top so user can scroll predictably
	if M.detail_popup.winid and vim.api.nvim_win_is_valid(M.detail_popup.winid) then
		pcall(vim.api.nvim_win_set_cursor, M.detail_popup.winid, { 1, 0 })
	end
end

-- Convert a cursor line in the LIST popup to a 1-based error index
local function list_line_to_index(line_num)
	local idx = line_num - LIST_HEADER_LINES
	if idx < 1 or idx > #M.errors then
		return nil
	end
	return idx
end

local function on_list_cursor_moved()
	if not M.list_popup or not M.list_popup.winid then
		return
	end
	if not vim.api.nvim_win_is_valid(M.list_popup.winid) then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(M.list_popup.winid)
	local idx = list_line_to_index(cursor[1])
	if idx then
		render_detail(idx)
	else
		render_detail(nil) -- header row, etc.
	end
end

-- Parse a stack-frame line for a file:line reference. Returns file, line or nil.
local function parse_frame(line)
	local file, lineno = line:match("([%w%./_%-]+%.%w+):(%d+)")
	if file then
		return file, tonumber(lineno)
	end
	-- Python: File "path", line N
	file, lineno = line:match('File "([^"]+)", line (%d+)')
	if file then
		return file, tonumber(lineno)
	end
	return nil, nil
end

-- Open file:line, closing the layout first
local function jump_to(file, line)
	close_layout()
	vim.cmd("edit " .. vim.fn.fnameescape(file))
	if line and line > 0 then
		pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
	end
	vim.notify(string.format("Opened %s:%d", file, line or 0), vim.log.levels.INFO)
end

-- <CR> on the detail pane: jump to file:line under cursor, falling back to issue file
local function on_detail_enter()
	if not M.detail_popup or not M.detail_popup.winid then
		return
	end
	if not vim.api.nvim_win_is_valid(M.detail_popup.winid) then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(M.detail_popup.winid)
	local lines = vim.api.nvim_buf_get_lines(M.detail_popup.bufnr, cursor[1] - 1, cursor[1], false)
	local line = lines[1] or ""

	local file, lineno = parse_frame(line)
	if file then
		jump_to(file, lineno or 0)
		return
	end

	-- Fallback: use the issue's primary error.file / error.line
	local idx = M.last_rendered_index
	local err = idx and M.errors[idx] or nil
	if err and err.file then
		jump_to(err.file, err.line or 0)
		return
	end

	vim.notify("No file reference on this line", vim.log.levels.WARN)
end

-- <CR> on the list pane: focus the detail pane (let the user explore the trace)
local function on_list_enter()
	if M.detail_popup and M.detail_popup.winid and vim.api.nvim_win_is_valid(M.detail_popup.winid) then
		vim.api.nvim_set_current_win(M.detail_popup.winid)
	end
end

-- ============================================================================
-- Mount / unmount
-- ============================================================================

local function mount_side_by_side()
	M.list_popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = { top = " Datadog Errors ", top_align = "center" },
		},
		buf_options = { modifiable = false, readonly = false },
		win_options = { wrap = false },
	})

	M.detail_popup = Popup({
		enter = false,
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " Detail ",
				top_align = "center",
				bottom = " <CR> jump · q close ",
				bottom_align = "right",
			},
		},
		buf_options = { modifiable = false, readonly = false },
		win_options = { wrap = false },
	})

	-- Float-mode layout pinned to the bottom of the editor. (Popup-children
	-- imply float mode; the "position=bottom, size=N" shorthand is for
	-- Split-mode layouts only.)
	M.layout = Layout(
		{
			relative = "editor",
			anchor = "SW",
			position = { row = "100%", col = 0 },
			size = { width = "100%", height = LAYOUT_HEIGHT },
		},
		Layout.Box({
			Layout.Box(M.list_popup, { size = "60%" }),
			Layout.Box(M.detail_popup, { size = "40%" }),
		}, { dir = "row" })
	)

	M.layout:mount()
end

local function mount_fallback_list_only()
	local Split = require("nui.split")
	M._fallback_split = Split({
		relative = "editor",
		position = "bottom",
		size = LAYOUT_HEIGHT,
		border = {
			style = "rounded",
			text = { top = " Datadog Errors ", top_align = "center" },
		},
	})
	M._fallback_split:mount()
	-- Reuse list_popup-like accessors
	M.list_popup = {
		bufnr = M._fallback_split.bufnr,
		winid = M._fallback_split.winid,
		map = function(_, mode, key, fn, opts)
			M._fallback_split:map(mode, key, fn, opts)
		end,
	}
	M.detail_popup = nil
end

local function setup_keymaps()
	local function close()
		close_layout()
	end
	local function refresh()
		M.refresh_errors()
	end

	-- List pane keymaps
	if M.list_popup and M.list_popup.map then
		M.list_popup:map("n", "q", close, { noremap = true })
		M.list_popup:map("n", "<ESC>", close, { noremap = true })
		M.list_popup:map("n", "r", refresh, { noremap = true })
		M.list_popup:map("n", "<CR>", on_list_enter, { noremap = true })
	end

	-- Detail pane keymaps (only present when side-by-side mounted)
	if M.detail_popup and M.detail_popup.map then
		M.detail_popup:map("n", "q", close, { noremap = true })
		M.detail_popup:map("n", "<ESC>", close, { noremap = true })
		M.detail_popup:map("n", "r", refresh, { noremap = true })
		M.detail_popup:map("n", "<CR>", on_detail_enter, { noremap = true })
	end
end

local function setup_autocmds()
	M._autocmd_group = vim.api.nvim_create_augroup("DatadogNvimBuffer", { clear = true })

	if M.list_popup and M.list_popup.bufnr and M.detail_popup then
		vim.api.nvim_create_autocmd("CursorMoved", {
			group = M._autocmd_group,
			buffer = M.list_popup.bufnr,
			callback = on_list_cursor_moved,
		})
	end

	-- Close on resize if terminal becomes too short for side-by-side
	vim.api.nvim_create_autocmd("VimResized", {
		group = M._autocmd_group,
		callback = function()
			if vim.o.lines < MIN_LINES then
				return -- live with it; the layout already shrinks
			end
		end,
	})
end

-- Show the errors UI
function M.show_errors_buffer()
	-- If already mounted, just refocus
	if M.layout or M._fallback_split then
		return
	end

	if vim.o.lines < MIN_LINES then
		vim.notify(
			string.format(
				"Datadog: terminal has %d lines (need %d) — showing list only",
				vim.o.lines,
				MIN_LINES
			),
			vim.log.levels.WARN
		)
		mount_fallback_list_only()
	else
		mount_side_by_side()
	end

	-- Buffer options on the list buffer
	if M.list_popup and M.list_popup.bufnr then
		pcall(vim.api.nvim_buf_set_option, M.list_popup.bufnr, "buftype", "nofile")
		pcall(vim.api.nvim_buf_set_option, M.list_popup.bufnr, "swapfile", false)
		pcall(vim.api.nvim_buf_set_option, M.list_popup.bufnr, "bufhidden", "hide")
	end

	setup_keymaps()
	setup_autocmds()

	M.refresh_errors()
end

-- Refresh errors from Datadog API
function M.refresh_errors()
	if not M.list_popup or not M.list_popup.bufnr then
		return
	end

	local bufnr = M.list_popup.bufnr

	set_lines(bufnr, { " Loading errors from Datadog..." })
	if M.detail_popup and M.detail_popup.bufnr then
		set_lines(M.detail_popup.bufnr, { " Loading…" })
	end
	M.last_rendered_index = nil

	local api_client = api.new(require("datadog").config)
	api_client:fetch_errors(function(errors, err)
		vim.schedule(function()
			if not M.list_popup or not M.list_popup.bufnr then
				return
			end

			if err then
				set_lines(M.list_popup.bufnr, {
					string.format(" Error: %s", err.error or "Unknown error"),
					"",
					" Press 'r' to retry or 'q' to close",
				})
				if M.detail_popup and M.detail_popup.bufnr then
					set_lines(M.detail_popup.bufnr, { "" })
				end
				return
			end

			M.errors = errors or {}
			M.render_table(M.list_popup.bufnr, M.errors)

			-- Trigger initial detail render for the first row
			if #M.errors > 0 and M.detail_popup then
				if M.list_popup.winid and vim.api.nvim_win_is_valid(M.list_popup.winid) then
					pcall(vim.api.nvim_win_set_cursor, M.list_popup.winid, { LIST_HEADER_LINES + 1, 0 })
				end
				render_detail(1)
			end
		end)
	end)
end

-- Render the issue list table (Nui Table)
function M.render_table(bufnr, errors)
	if #errors == 0 then
		set_lines(bufnr, { " No errors found " })
		return
	end

	local columns = {
		{ accessor_key = "count", header = "COUNT", width = 8, align = "right" },
		{ accessor_key = "type", header = "TYPE", width = 14 },
		{ accessor_key = "service", header = "SERVICE", width = 16 },
		{ accessor_key = "message", header = "MESSAGE", width = 30 },
		{ accessor_key = "file", header = "FILE", width = 28 },
	}

	local data = {}
	for i, err in ipairs(errors) do
		local file_info = ""
		if err.file then
			file_info = err.file .. ":" .. (err.line or "")
		end
		table.insert(data, {
			index = i,
			count = tostring(err.occurrences or 0),
			type = err.status or err.error_source or "unknown",
			service = err.service or "unknown",
			message = err.title or err.message or "Unknown error",
			file = file_info,
		})
	end

	-- Nui Table renders directly into bufnr; the buf needs to be modifiable for it
	pcall(vim.api.nvim_buf_set_option, bufnr, "modifiable", true)
	local table_instance = Table({
		bufnr = bufnr,
		columns = columns,
		data = data,
	})
	table_instance:render()
	pcall(vim.api.nvim_buf_set_option, bufnr, "modifiable", false)
end

-- Close the entire UI
close_layout = function()
	if M._autocmd_group then
		pcall(vim.api.nvim_del_augroup_by_id, M._autocmd_group)
		M._autocmd_group = nil
	end
	if M.layout then
		pcall(function()
			M.layout:unmount()
		end)
		M.layout = nil
	end
	if M._fallback_split then
		pcall(function()
			M._fallback_split:unmount()
		end)
		M._fallback_split = nil
	end
	M.list_popup = nil
	M.detail_popup = nil
	M.errors = {}
	M.last_rendered_index = nil
end

function M.close_buffer()
	close_layout()
end

return M
