-- Datadog Spans API module

local M = {}

-- Module-level cache for per-issue exemplar spans.
-- Datadog rate-limits POST /spans/events/search to 300 req/hr — without
-- caching, a 50-issue refresh burns 17% of the hourly budget on data that
-- almost never changes between refreshes.
--
-- Key:   issue_id .. "|" .. from_iso .. "|" .. to_iso (different time
--        windows can return different exemplar spans).
-- Value: { span = <span|nil>, fetched_at = <epoch_seconds> }
--        Negative results are cached too so a missing exemplar doesn't
--        force re-fetching every refresh.
local SPAN_CACHE = {}
local CACHE_TTL_SECONDS = 600 -- 10 minutes

-- Cap how many issues we fan out spans for in one shot. Issues come in
-- sorted by total_count desc (see error_tracking.search order_by), so the
-- top N covers the most-occurring issues; the tail uses the issue-level
-- fallback in the formatter.
local DEFAULT_FANOUT_LIMIT = 20

-- Build the cache key. Time window is bucketed to the minute so two
-- refreshes seconds apart hit the same key — `to_iso` is "now"
-- formatted at second precision and would otherwise drift on every call.
local function bucket_to_minute(iso)
	-- "2026-04-29T22:30:45Z" -> "2026-04-29T22:30Z" (strip seconds component only)
	return (iso or ""):gsub("(T%d%d:%d%d):%d%dZ$", "%1Z")
end

local function cache_key(issue_id, from_iso, to_iso)
	return issue_id .. "|" .. bucket_to_minute(from_iso) .. "|" .. bucket_to_minute(to_iso)
end

local function cache_get(key)
	local entry = SPAN_CACHE[key]
	if not entry then
		return nil, false
	end
	if os.time() - entry.fetched_at > CACHE_TTL_SECONDS then
		SPAN_CACHE[key] = nil
		return nil, false
	end
	return entry.span, true -- second return = "cache hit" (true even when span is nil)
end

local function cache_put(key, span)
	SPAN_CACHE[key] = { span = span, fetched_at = os.time() }
end

-- Clear the cache (exposed for `:DatadogRefresh` hard-reset, etc.)
function M:clear_cache()
	SPAN_CACHE = {}
end

-- Fetch one representative span per issue.
--
-- Caps the fan-out at DEFAULT_FANOUT_LIMIT (top 20 by total_count, since
-- callers pass issue_ids already sorted that way). Tail issues simply don't
-- get a spans_map entry and the formatter uses issue-level attrs.
--
-- Each per-issue fetch consults the cache first; a cache hit short-circuits
-- the HTTP call. The callback fires once all in-flight requests complete.
function M:search_by_issues(issue_ids, from_iso, to_iso, callback)
	if #issue_ids == 0 then
		callback({}, nil)
		return
	end

	-- Slice to top N
	local fanout_count = math.min(#issue_ids, DEFAULT_FANOUT_LIMIT)

	local spans_map = {}
	local pending = fanout_count
	local first_err = nil

	if fanout_count == 0 then
		callback(spans_map, nil)
		return
	end

	for i = 1, fanout_count do
		local issue = issue_ids[i]
		self:search_by_issue(issue.id, from_iso, to_iso, function(span, err)
			if err and not first_err then
				first_err = err
			elseif span then
				spans_map[issue.id] = span
			end

			pending = pending - 1
			if pending == 0 then
				if first_err then
					callback(nil, first_err)
				else
					callback(spans_map, nil)
				end
			end
		end)
	end
end

-- Search spans by issue ID (single). Cache-aware: returns immediately on
-- a cache hit (still via vim.schedule so callers get consistent async
-- semantics).
function M:search_by_issue(issue_id, from_iso, to_iso, callback)
	local key = cache_key(issue_id, from_iso, to_iso)
	local cached_span, hit = cache_get(key)
	if hit then
		vim.schedule(function()
			callback(cached_span, nil)
		end)
		return
	end

	local request_body = {
		data = {
			attributes = {
				filter = {
					from = from_iso,
					to = to_iso,
					query = "@issue.id:" .. issue_id,
				},
				options = {
					timezone = "UTC",
				},
				page = {
					limit = 1,
				},
				sort = "-timestamp",
			},
			type = "search_request",
		},
	}

	self._api:_request("POST", "spans/events/search", request_body, function(response, err)
		if err then
			-- Don't poison the cache with transient errors
			callback(nil, err)
			return
		end

		local span = nil
		if response and response.data and #response.data > 0 then
			span = response.data[1]
		end

		cache_put(key, span) -- cache positive AND negative results
		callback(span, nil)
	end)
end

return function(api)
	M._api = api
	return M
end
