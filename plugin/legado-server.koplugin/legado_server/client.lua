-- V1 device protocol only. There are no management cookies, CSRF tokens,
-- source rules, or direct upstream requests in this adapter.
local TLS = require("legado_server/tls")
local Digest = require("legado_server/digest")

local Client = {}
Client.__index = Client

local function need(value, message)
    if not value then error(message or "client operation failed", 0) end
    return value
end

local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 512
        and not value:find("[%z\1-\31\127]")
end

local function integer(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
        and value < 9007199254740992
end

local function encode_query(value)
    return (value:gsub("[^%w%-._~]", function(character) return string.format("%%%02X", character:byte()) end))
end

local function checked(callback)
    local ok, value, other = pcall(callback)
    if not ok then return nil, { code = "client_error", message = tostring(value), retryable = false } end
    return value, other
end

local function origin(value)
    if type(value) ~= "string" or value:find("[%z\1-\32\127\\#]") then return nil end
    local scheme, authority = value:match("^(https?)://([^/%?#]+)")
    if not scheme or authority:find("@", 1, true) then return nil end
    return scheme:lower() .. "://" .. authority:lower()
end

local function header(headers, name)
    for key, value in pairs(headers or {}) do
        if tostring(key):lower() == name:lower() then return tostring(value) end
    end
end

local function trusted_ca()
    local paths = { os.getenv("SSL_CERT_FILE") or "", "data/ca-bundle.crt", "common/ca-bundle.crt", "common/cacert.pem" }
    for path_index, path in ipairs(paths) do
        if path ~= "" then
            local file = io.open(path, "rb")
            if file then file:close(); return path end
        end
    end
end

local function http_transport(request, sink)
    local ltn12 = require("ltn12")
    local requester = require("socket.http")
    local socket = require("socket")
    local timeout = request.timeout or 30
    local deadline = socket.gettime() + timeout
    local chunks, length = {}, 0
    local parameters = {
        url = request.url, method = request.method, headers = request.headers,
        redirect = false,
        sink = function(chunk)
            if socket.gettime() > deadline then return nil, "sync request timed out" end
            if chunk then
                length = length + #chunk
                if length > request.max_bytes then return nil, "sync response exceeds size limit" end
                if sink then return sink(chunk) end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
    }
    if request.body then parameters.source = ltn12.source.string(request.body) end
    if request.url:match("^https://") then
        local cafile = trusted_ca()
        if not cafile then return nil, "trusted CA bundle is unavailable" end
        -- socket.http handles framing while this create callback performs the
        -- local LuaSec chain and RFC 2818 hostname checks in tls.lua.
        parameters.create = function()
            return TLS.lazy_connect(request.url, { cafile = cafile, timeout = timeout })
        end
    end
    local previous_timeout = requester.TIMEOUT
    requester.TIMEOUT = timeout
    local called, ok, status, headers = pcall(requester.request, parameters)
    requester.TIMEOUT = previous_timeout
    if not called then return nil, "server connection failed: " .. tostring(ok) end
    if not ok then return nil, "server connection failed: " .. tostring(status) end
    return { status = tonumber(status), headers = headers or {}, body = sink and nil or table.concat(chunks) }
end

function Client.new(options)
    options = options or {}
    local base = tostring(options.server_url or ""):gsub("/+$", "")
    assert(origin(base) and not base:find("?", 1, true), "a valid server URL is required")
    return setmetatable({
        server_url = base, server_origin = origin(base),
        device_id = options.device_id, device_token = options.device_token,
        server_id = options.server_id, server_name = options.server_name,
        discovery_port = options.discovery_port,
        store = options.store, json = options.json or require("rapidjson"),
        transport = options.transport or http_transport, timeout = options.timeout or 30,
    }, Client)
end

function Client:_request(method, path, payload, unauthenticated, sink, max_bytes, extra_headers)
    local url = path:match("^https?://") and path or self.server_url .. path
    if origin(url) ~= self.server_origin or url:sub(1, #self.server_url + 1) ~= self.server_url .. "/" then
        return nil, { code = "foreign_server", message = "sync URL does not belong to the paired server", retryable = false }
    end
    local headers = { Accept = sink and "application/zip" or "application/json", ["Accept-Encoding"] = "identity" }
    for key, value in pairs(extra_headers or {}) do headers[key] = value end
    if not unauthenticated then
        if type(self.device_token) ~= "string" or self.device_token == "" then
            return nil, { code = "not_paired", message = "pair this Kindle with the server first", retryable = false }
        end
        headers.Authorization = "Bearer " .. self.device_token
    end
    local body
    if payload then
        body = self.json.encode(payload)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    local response, err = self.transport({
        method = method, url = url, headers = headers, body = body,
        timeout = self.timeout, redirect = false, max_bytes = max_bytes or 16 * 1024 * 1024,
    }, sink)
    if not response then return nil, { code = "network_error", message = type(err) == "string" and err or "server connection failed", retryable = true } end
    local status = tonumber(response.status)
    if not status or status < 200 or status >= 300 then
        local decoded, value = pcall(self.json.decode, response.body or "")
        local failure = decoded and type(value) == "table" and value.error
        if type(failure) ~= "table" then failure = { code = "http_error", message = "server returned HTTP " .. tostring(status), retryable = status and status >= 500 or false } end
        failure.status = status
        return nil, failure
    end
    if sink then return response end
    if status == 204 then return {} end
    local decoded, value = pcall(self.json.decode, response.body or "")
    if not decoded or type(value) ~= "table" then
        return nil, { code = "invalid_json", message = "server returned invalid JSON", retryable = false }
    end
    response.body = nil
    collectgarbage("collect")
    return value
end

function Client:pair(pairing_code, device_name)
    return checked(function()
        local result, err = self:_request("POST", "/api/v1/devices/pair", {
            protocol_version = 1, pairing_code = pairing_code, device_name = device_name or "Kindle",
        }, true)
        if not result then return nil, err end
        if result.protocol_version ~= 1 or not identifier(result.server_id)
                or not identifier(result.device_id)
                or type(result.device_token) ~= "string" or result.device_token == "" or result.token_type ~= "Bearer" then
            return nil, { code = "invalid_pairing", message = "server returned invalid pairing data", retryable = false }
        end
        if self.server_id and result.server_id ~= self.server_id then
            return nil, { code = "server_identity_mismatch", message = "paired server identity does not match discovery", retryable = false }
        end
        if self.store then
            local cleared, clear_err = self.store:forget_server_pairing()
            if not cleared then return nil, { code = "local_write_failed", message = clear_err, retryable = true } end
            local settings, settings_err = self.store:settings()
            if not settings then return nil, { code = "local_state_invalid", message = settings_err, retryable = false } end
            settings.server_url = self.server_url
            settings.server_id = result.server_id
            settings.server_name = self.server_name or settings.server_name
            settings.discovery_port = self.discovery_port or settings.discovery_port or 47832
            settings.device_id = result.device_id
            settings.device_token = result.device_token
            local saved, save_err = self.store:save_settings(settings)
            if not saved then return nil, { code = "local_write_failed", message = save_err, retryable = true } end
        end
        self.server_id, self.device_id, self.device_token = result.server_id, result.device_id, result.device_token
        return { server_id = result.server_id, device_id = result.device_id, paired = true }
    end)
end

function Client:download_bundle(descriptor, sink, resume_offset)
    local url = type(descriptor.url) == "string" and descriptor.url
    if not url or url:sub(1, 2) == "//" or url:find("?", 1, true) then
        return nil, "invalid bundle URL"
    end
    local absolute = url:match("^https?://") and url or self.server_url .. url
    if absolute:sub(1, #self.server_url + #"/api/v1/bundles/") ~= self.server_url .. "/api/v1/bundles/"
            or origin(absolute) ~= self.server_origin then return nil, "bundle URL does not belong to the paired server" end
    resume_offset = resume_offset or 0
    if resume_offset < 0 or resume_offset > descriptor.size_bytes then return nil, "invalid bundle resume offset" end
    local range_headers = {}
    if resume_offset > 0 then
        range_headers.Range = "bytes=" .. resume_offset .. "-"
        range_headers["If-Range"] = '"' .. descriptor.sha256 .. '"'
    end
    local result, err = self:_request("GET", absolute, nil, false, sink, descriptor.size_bytes, range_headers)
    if not result then return nil, err.message end
    if resume_offset > 0 and result.status == 200 then
        -- If-Range says the server resource no longer matches the descriptor.
        -- The caller must discard the old prefix and download a complete bundle.
        return nil, { bundle_changed = true, message = "sync bundle changed on the server" }
    end
    if result.status ~= (resume_offset > 0 and 206 or 200) then return nil, "unexpected bundle response status" end
    if resume_offset > 0 then
        local expected_range = "bytes " .. resume_offset .. "-" .. (descriptor.size_bytes - 1) .. "/" .. descriptor.size_bytes
        if header(result.headers, "Content-Range") ~= expected_range then
            return nil, "bundle Content-Range does not match its descriptor"
        end
    end
    if header(result.headers, "ETag") ~= '"' .. descriptor.sha256 .. '"' then return nil, "bundle ETag does not match its immutable hash" end
    return true
end

function Client:download_book_epub(book_id, descriptor, sink, resume_offset)
    need(identifier(book_id), "invalid published book identity")
    local url = type(descriptor) == "table" and descriptor.url
    if not url or url:sub(1, 2) == "//" or url:find("?", 1, true) then
        return nil, "invalid published EPUB URL"
    end
    local absolute = url:match("^https?://") and url or self.server_url .. url
    local expected = self.server_url .. "/api/v1/books/" .. book_id .. "/epub"
    if absolute ~= expected or origin(absolute) ~= self.server_origin then
        return nil, "published EPUB URL does not belong to the paired server"
    end
    resume_offset = resume_offset or 0
    if resume_offset < 0 or resume_offset > descriptor.size_bytes then
        return nil, "invalid published EPUB resume offset"
    end
    local headers = {}
    if resume_offset > 0 then
        headers.Range = "bytes=" .. resume_offset .. "-"
        headers["If-Range"] = '"' .. descriptor.sha256 .. '"'
    end
    local result, err = self:_request("GET", absolute, nil, false, sink, descriptor.size_bytes, headers)
    if not result then return nil, { status = err.status, changed = err.status == 416, message = err.message } end
    if resume_offset > 0 and result.status == 200 then
        return nil, { changed = true, message = "published EPUB changed on the server" }
    end
    if result.status ~= (resume_offset > 0 and 206 or 200) then
        return nil, "unexpected published EPUB response status"
    end
    if resume_offset > 0 then
        local expected_range = "bytes " .. resume_offset .. "-" .. (descriptor.size_bytes - 1) .. "/" .. descriptor.size_bytes
        if header(result.headers, "Content-Range") ~= expected_range then
            return nil, "published EPUB Content-Range does not match its descriptor"
        end
    end
    if header(result.headers, "ETag") ~= '"' .. descriptor.sha256 .. '"' then
        return nil, "published EPUB ETag does not match its immutable hash"
    end
    return true
end

function Client:download_inbox_file(descriptor, sink, resume_offset)
    local url = type(descriptor.url) == "string" and descriptor.url
    if not url or url:sub(1, 2) == "//" or url:find("?", 1, true) then
        return nil, "invalid pushed-book file URL"
    end
    local absolute = url:match("^https?://") and url or self.server_url .. url
    local prefix = self.server_url .. "/api/v1/inbox/files/"
    if absolute:sub(1, #prefix) ~= prefix or origin(absolute) ~= self.server_origin then
        return nil, "pushed-book file URL does not belong to the paired server"
    end
    resume_offset = resume_offset or 0
    if resume_offset < 0 or resume_offset > descriptor.size_bytes then
        return nil, "invalid pushed-book resume offset"
    end
    local headers = {}
    if resume_offset > 0 then
        headers.Range = "bytes=" .. resume_offset .. "-"
        headers["If-Range"] = '"' .. descriptor.sha256 .. '"'
    end
    local result, err = self:_request("GET", absolute, nil, false, sink, descriptor.size_bytes, headers)
    if not result then return nil, { status = err.status, changed = err.status == 416, message = err.message } end
    if resume_offset > 0 and result.status == 200 then
        return nil, { changed = true, message = "pushed-book file changed on the server" }
    end
    if result.status ~= (resume_offset > 0 and 206 or 200) then
        return nil, "unexpected pushed-book response status"
    end
    if resume_offset > 0 then
        local expected_range = "bytes " .. resume_offset .. "-" .. (descriptor.size_bytes - 1) .. "/" .. descriptor.size_bytes
        if header(result.headers, "Content-Range") ~= expected_range then
            return nil, "pushed-book Content-Range does not match its descriptor"
        end
    end
    if header(result.headers, "ETag") ~= '"' .. descriptor.sha256 .. '"' then
        return nil, "pushed-book ETag does not match its immutable hash"
    end
    return true
end

function Client:pull_inbox()
    return checked(function()
        assert(self.store, "inbox storage is required")
        local cursor, cursor_err = self.store:inbox_cursor()
        need(cursor, cursor_err)
        local path = "/api/v1/inbox?cursor=" .. encode_query(cursor)
        local response, err = self:_request("GET", path)
        if not response then return nil, err end
        need(response.protocol_version == 1 and type(response.next_cursor) == "string"
            and response.next_cursor:match("^%d+$") and type(response.deliveries) == "table",
            "invalid pushed-book inbox response")
        local results, downloaded_titles, failed_count = self.json.array(), {}, 0
        for delivery_index, delivery in ipairs(response.deliveries) do
            local ok, failure = pcall(function()
                need(type(delivery) == "table" and identifier(delivery.delivery_id)
                    and identifier(delivery.book_id) and type(delivery.title) == "string"
                    and delivery.format == "epub" and type(delivery.files) == "table"
                    and #delivery.files > 0, "invalid pushed-book delivery")
                local installed = {}
                for file_index, file in ipairs(delivery.files) do
                    need(type(file) == "table" and identifier(file.file_id)
                        and type(file.file_name) == "string" and file.content_type == "application/epub+zip"
                        and type(file.sha256) == "string" and file.sha256:match("^[0-9a-f]+$") and #file.sha256 == 64
                        and integer(file.size_bytes) and file.size_bytes > 0, "invalid pushed-book file")
                    local target = self.store:inbox_file_path(
                        delivery.book_id, delivery.delivery_id, file.file_id, file.file_name)
                    if not self.store:inbox_file_valid(target, file) then
                        if self.store.fs:exists(target) then need(self.store.fs:remove(target)) end
                        local pending = target .. ".part"
                        local resume = self.store.fs:exists(pending) and self.store.fs:size(pending) or 0
                        if resume > file.size_bytes then self.store.fs:remove(pending); resume = 0 end
                        local writer, writer_err = self.store.fs:writer(pending, file.size_bytes, resume)
                        need(writer, writer_err)
                        local fetched, fetch_err = self:download_inbox_file(file, function(chunk)
                            return writer:write(chunk)
                        end, resume)
                        local closed, close_err = writer:close()
                        if type(fetch_err) == "table" and fetch_err.changed then
                            self.store.fs:remove(pending)
                        end
                        need(fetched, type(fetch_err) == "table" and fetch_err.message or fetch_err)
                        need(closed and writer:size() == file.size_bytes, close_err or "incomplete pushed-book download")
                        local digest = Digest.file(pending)
                        if digest ~= file.sha256 then
                            self.store.fs:remove(pending)
                            error("pushed-book checksum mismatch", 0)
                        end
                        need(self.store.fs:rename(pending, target))
                    end
                    installed[#installed + 1] = {
                        file_id = file.file_id, file_name = file.file_name, path = target,
                        sha256 = file.sha256, size_bytes = file.size_bytes,
                    }
                end
                need(self.store:record_inbox_delivery(delivery, installed))
                downloaded_titles[#downloaded_titles + 1] = delivery.title
            end)
            if ok then
                results[#results + 1] = { delivery_id = delivery.delivery_id, status = "applied" }
            else
                failed_count = failed_count + 1
                local delivery_id = type(delivery) == "table" and delivery.delivery_id or ""
                if identifier(delivery_id) then
                    results[#results + 1] = {
                        delivery_id = delivery_id, status = "failed", error = tostring(failure),
                    }
                end
            end
        end
        local acknowledged, ack_err = self:_request("POST", "/api/v1/inbox/ack", {
            cursor = response.next_cursor, results = results,
        })
        if not acknowledged then return nil, ack_err end
        need(acknowledged.acked == true and type(acknowledged.cursor) == "string",
            "invalid pushed-book acknowledgement")
        need(self.store:confirm_inbox_ack(acknowledged.cursor))
        return { downloaded = #downloaded_titles, failed = failed_count, titles = downloaded_titles }
    end)
end

function Client:ack_pending()
    local pending, err = self.store:pending_ack()
    if not pending then
        if err then return nil, { code = "local_state_invalid", message = err, retryable = false } end
        return true
    end
    local response, failure = self:_request("POST", "/api/v1/sync/ack", pending)
    if not response then return nil, failure end
    local saved, save_err = self.store:confirm_ack(response)
    if not saved then return nil, { code = "local_write_failed", message = save_err, retryable = true } end
    return true
end

function Client:sync()
    return checked(function()
        assert(self.store, "sync storage is required")
        local acked, ack_err = self:ack_pending()
        if not acked then return nil, ack_err end
        local sync_meta, state_err = self.store:sync_meta()
        if not sync_meta then return nil, { code = "local_state_invalid", message = state_err, retryable = false } end
        local cursor = sync_meta.cursor
        sync_meta = nil
        collectgarbage("collect")
        local path = "/api/v1/sync" .. (cursor and ("?cursor=" .. encode_query(cursor)) or "")
        local response, err = self:_request("GET", path)
        if not response and err.status == 410 and err.code == "cursor_expired" then
            response, err = self:_request("GET", "/api/v1/sync")
            if response and response.reset ~= true then return nil, { code = "invalid_reset", message = "server did not return a complete reset snapshot", retryable = false } end
        end
        if not response then return nil, err end
        if type(response.books) ~= "table" then return nil, { code = "invalid_sync", message = "sync book list is missing", retryable = false } end
        if type(response.bundles) ~= "table" then return nil, { code = "invalid_sync", message = "sync bundle list is missing", retryable = false } end
        local epub_count = 0
        for book_index, book in ipairs(response.books) do
            need(type(book) == "table" and identifier(book.book_id), "invalid published book")
            local descriptor = book.epub
            if not self.store:is_null(descriptor) then
                need(type(descriptor) == "table", "invalid published EPUB descriptor")
                local installed, install_err = self.store:install_book_epub(
                    book.book_id,
                    descriptor,
                    function(sink, offset)
                        return self:download_book_epub(book.book_id, descriptor, sink, offset)
                    end
                )
                if not installed then
                    return nil, { code = "epub_failed", message = install_err, retryable = true }
                end
                epub_count = epub_count + 1
                collectgarbage("collect")
            end
        end
        for bundle_index, descriptor in ipairs(response.bundles) do
            local installed, install_err = self.store:install_bundle(descriptor, function(sink, offset) return self:download_bundle(descriptor, sink, offset) end)
            if not installed then return nil, { code = "bundle_failed", message = install_err, retryable = true } end
        end
        collectgarbage("collect")
        local applied, changed = self.store:apply_sync(response)
        if not applied then return nil, { code = "snapshot_failed", message = changed, retryable = true } end
        local confirmed, confirm_err = self:ack_pending()
        if not confirmed then return nil, confirm_err end
        return { synced = true, changed = changed, bundles = #response.bundles, epubs = epub_count }
    end)
end

function Client:conflicts()
    return checked(function()
        local response, err = self:_request("GET", "/api/v1/progress/conflicts")
        if not response then return nil, err end
        need(type(response.conflicts) == "table", "invalid progress conflict response")
        local conflicts = self.json.array and self.json.array() or {}
        for conflict_index, conflict in ipairs(response.conflicts) do
            need(type(conflict) == "table" and identifier(conflict.conflict_id)
                and identifier(conflict.book_id) and type(conflict.title) == "string"
                and type(conflict.candidate) == "table" and identifier(conflict.candidate.chapter_id),
                "invalid progress conflict")
            conflicts[#conflicts + 1] = conflict
        end
        return conflicts
    end)
end

function Client:resolve_conflict(conflict_id, resolution)
    return checked(function()
        need(identifier(conflict_id), "invalid progress conflict identity")
        need(resolution == "server" or resolution == "kindle", "invalid conflict resolution")
        local path = "/api/v1/progress/conflicts/" .. encode_query(conflict_id) .. "/resolve"
        local response, err = self:_request("POST", path, { resolution = resolution })
        if not response then return nil, err end
        need(response.conflict_id == conflict_id and response.resolution == resolution
            and type(response.resolved_at) == "string", "invalid conflict resolution response")
        return response
    end)
end

function Client:sync_all()
    return checked(function()
        local progress, progress_err = self:flush_progress()
        if not progress then return nil, progress_err end
        local synced, sync_err = self:sync()
        if not synced then return nil, sync_err end
        local conflicts, conflict_err = self:conflicts()
        if not conflicts then return nil, conflict_err end
        return {
            synced = synced.synced,
            changed = synced.changed,
            bundles = synced.bundles,
            epubs = synced.epubs,
            progress_sent = progress.sent,
            conflict_count = #conflicts,
            conflicts = conflicts,
        }
    end)
end

function Client:flush_progress()
    return checked(function()
        local sent = 0
        for event_index = 1, 50 do
            local event, queue_err = self.store:prepare_progress_event()
            if not event then
                if queue_err then return nil, { code = "local_state_invalid", message = queue_err, retryable = false } end
                break
            end
            local payload = self.json.array and self.json.array() or {}
            event.base_progress_version = event.base_progress_version or self.json.null
            payload[1] = event
            local response, err = self:_request("POST", "/api/v1/progress", { events = payload })
            if not response and err and err.code == "idempotency_key_reused" then
                local retry_original, retry_err = self.store:retry_progress_original_payload(event.event_id, err.code)
                if retry_original then
                    event, queue_err = self.store:prepare_progress_event()
                    if not event then
                        return nil, { code = "local_state_invalid", message = queue_err, retryable = false }
                    end
                    payload = self.json.array and self.json.array() or {}
                    event.base_progress_version = event.base_progress_version or self.json.null
                    payload[1] = event
                    response, err = self:_request("POST", "/api/v1/progress", { events = payload })
                elseif retry_err then
                    return nil, { code = "local_state_invalid", message = retry_err, retryable = false }
                end
            end
            if not response then return nil, err end
            local saved, save_err = self.store:record_progress_results(response)
            if not saved then return nil, { code = "local_write_failed", message = save_err, retryable = true } end
            sent = sent + #(response.results or {})
        end
        return { sent = sent }
    end)
end

return Client
