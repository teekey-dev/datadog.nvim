-- Buffer management for datadog.nvim
-- Side-by-side issue list (left) + detail pane (right) in a bottom split.

local M = {}

local api = require("datadog.api")
local utils = require("datadog.utils")

local Table = require("nui.table")

-- UI state. list_popup / detail_popup keep the historical names (they used to
-- be Nui Popups) but are now plain { bufnr, winid } records over native windows.
M.list_popup = nil
M.detail_popup = nil
M.errors = {}
M.last_rendered_index = nil
M._prev_winid = nil -- window the user was in before opening the panel
M._autocmd_group = nil

local MIN_LINES = 12
local PANEL_HEIGHT = 20 -- fixed bottom panel height in rows
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

local function setup_pane_buffer(bufnr, name)
	pcall(vim.api.nvim_buf_set_option, bufnr, "buftype", "nofile")
	pcall(vim.api.nvim_buf_set_option, bufnr, "swapfile", false)
	pcall(vim.api.nvim_buf_set_option, bufnr, "bufhidden", "wipe")
	pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", "datadog-" .. name)
	pcall(vim.api.nvim_buf_set_name, bufnr, "datadog://" .. name)
end

local function setup_pane_window(winid, opts)
	pcall(vim.api.nvim_win_set_option, winid, "wrap", false)
	pcall(vim.api.nvim_win_set_option, winid, "number", false)
	pcall(vim.api.nvim_win_set_option, winid, "relativenumber", false)
	pcall(vim.api.nvim_win_set_option, winid, "signcolumn", "no")
	pcall(vim.api.nvim_win_set_option, winid, "foldcolumn", "0")
	pcall(vim.api.nvim_win_set_option, winid, "list", false)
	pcall(vim.api.nvim_win_set_option, winid, "spell", false)
	pcall(vim.api.nvim_win_set_option, winid, "cursorline", opts.cursorline or false)
	pcall(vim.api.nvim_win_set_option, winid, "winfixheight", true)
	pcall(vim.api.nvim_win_set_option, winid, "winfixwidth", true)
end

-- Open a fixed-height bottom split, then vsplit it for the detail pane.
local function mount_side_by_side()
	M._prev_winid = vim.api.nvim_get_current_win()

	-- 1. Bottom horizontal split with a fresh scratch buffer for the list.
	local list_bufnr = vim.api.nvim_create_buf(false, true)
	vim.cmd("botright " .. PANEL_HEIGHT .. "split")
	local list_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(list_winid, list_bufnr)

	setup_pane_buffer(list_bufnr, "errors")
	setup_pane_window(list_winid, { cursorline = true })

	-- 2. Vertical split inside the list window for the detail pane (right side).
	local detail_bufnr = vim.api.nvim_create_buf(false, true)
	-- "vertical rightbelow split" inherits height from the current (list) window
	-- and creates the new window to its right. We control width with vert resize.
	vim.cmd("vertical rightbelow split")
	local detail_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(detail_winid, detail_bufnr)

	setup_pane_buffer(detail_bufnr, "detail")
	setup_pane_window(detail_winid, { cursorline = false })

	-- 3. Size the detail pane to ~40% of the editor width. After a vsplit each
	--    half is half the original width; fix proportions explicitly.
	local total_width = vim.o.columns
	local detail_width = math.max(30, math.floor(total_width * 0.4))
	pcall(vim.api.nvim_win_set_width, detail_winid, detail_width)

	-- Focus the list pane on entry so the cursor/CursorMoved autocmd takes
	-- effect immediately and the user can navigate without an extra <C-w>h.
	vim.api.nvim_set_current_win(list_winid)

	M.list_popup = { bufnr = list_bufnr, winid = list_winid }
	M.detail_popup = { bufnr = detail_bufnr, winid = detail_winid }
end

-- Single-pane fallback for very short terminals.
local function mount_fallback_list_only()
	M._prev_winid = vim.api.nvim_get_current_win()

	local list_bufnr = vim.api.nvim_create_buf(false, true)
	vim.cmd("botright " .. PANEL_HEIGHT .. "split")
	local list_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(list_winid, list_bufnr)

	setup_pane_buffer(list_bufnr, "errors")
	setup_pane_window(list_winid, { cursorline = true })

	M.list_popup = { bufnr = list_bufnr, winid = list_winid }
	M.detail_popup = nil
end

local function buf_keymap(bufnr, key, fn)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.keymap.set("n", key, fn, { buffer = bufnr, noremap = true, silent = true })
end

local function setup_keymaps()
	local function close()
		close_layout()
	end
	local function refresh()
		M.refresh_errors()
	end

	if M.list_popup and M.list_popup.bufnr then
		buf_keymap(M.list_popup.bufnr, "q", close)
		buf_keymap(M.list_popup.bufnr, "<ESC>", close)
		buf_keymap(M.list_popup.bufnr, "r", refresh)
		buf_keymap(M.list_popup.bufnr, "<CR>", on_list_enter)
	end

	if M.detail_popup and M.detail_popup.bufnr then
		buf_keymap(M.detail_popup.bufnr, "q", close)
		buf_keymap(M.detail_popup.bufnr, "<ESC>", close)
		buf_keymap(M.detail_popup.bufnr, "r", refresh)
		buf_keymap(M.detail_popup.bufnr, "<CR>", on_detail_enter)
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

	-- If either pane's window is closed externally (:q, :close), tear the
	-- whole panel down so we don't leak the other window.
	local watched_bufnrs = {}
	if M.list_popup then
		table.insert(watched_bufnrs, M.list_popup.bufnr)
	end
	if M.detail_popup then
		table.insert(watched_bufnrs, M.detail_popup.bufnr)
	end
	for _, bufnr in ipairs(watched_bufnrs) do
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = M._autocmd_group,
			buffer = bufnr,
			callback = function()
				vim.schedule(close_layout)
			end,
		})
	end
end

-- Show the errors UI
function M.show_errors_buffer()
	-- If already mounted, refocus the list pane and bail.
	if M.list_popup and M.list_popup.winid and vim.api.nvim_win_is_valid(M.list_popup.winid) then
		vim.api.nvim_set_current_win(M.list_popup.winid)
		return
	end

	-- Use single-pane fallback only when the terminal is genuinely too short
	-- to make a side-by-side comfortable.
	if vim.o.lines < MIN_LINES or vim.o.columns < 80 then
		vim.notify(
			string.format(
				"Datadog: terminal is %dx%d — showing list only",
				vim.o.columns,
				vim.o.lines
			),
			vim.log.levels.WARN
		)
		mount_fallback_list_only()
	else
		mount_side_by_side()
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

	for _, pane in ipairs({ M.list_popup, M.detail_popup }) do
		if pane and pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
			pcall(vim.api.nvim_win_close, pane.winid, true)
		end
		if pane and pane.bufnr and vim.api.nvim_buf_is_valid(pane.bufnr) then
			pcall(vim.api.nvim_buf_delete, pane.bufnr, { force = true })
		end
	end

	-- Restore focus to the window the user was in before opening the panel.
	if M._prev_winid and vim.api.nvim_win_is_valid(M._prev_winid) then
		pcall(vim.api.nvim_set_current_win, M._prev_winid)
	end

	M.list_popup = nil
	M.detail_popup = nil
	M.errors = {}
	M.last_rendered_index = nil
	M._prev_winid = nil
end

function M.close_buffer()
	close_layout()
end

return M
