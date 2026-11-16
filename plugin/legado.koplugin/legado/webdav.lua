-- Minimal WebDAV client for downloading an Android backup ZIP.
--
-- The import boundary itself is unchanged: this module only fetches the same
-- Android backup ZIP that Import Android backup reads from local storage, and
-- the download is handed to Backup.import_archive as a file.  Transport rules
-- mirror legado/network.lua (LuaSocket with LuaSec when the build provides
-- it, per-request inactivity timeouts, bounded redirects), but WebDAV lives
-- in its own module on purpose: PROPFIND stays out of the Legado source rule
-- surface, so no book source can list or fetch arbitrary server paths.
--
-- Credentials are stored beside the imported state in webdav.json using the
-- same atomic-write/lock/chmod treatment as legado/session.lua.  The file
-- still holds plaintext credentials; Kindle KOReader has no secret store.

local _ = require("gettext")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local util = require("util")
local rapidjson = require("rapidjson")
local Network = require("legado/network")

local http = require("socket.http")
local https
pcall(function()
    https = require("ssl.https")
end)

local Webdav = {}

local CONFIG_SCHEMA_VERSION = 1
local DEFAULT_TIMEOUT_SECONDS = 30
local REQUEST_REDIRECT_LIMIT = 5
-- Android backups carry book metadata and records, not chapter bodies, so a
-- few megabytes is typical.  The cap only bounds a misconfigured or hostile
-- path; the streaming sink never holds the whole file in memory.
local MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024

-- ---------------------------------------------------------------------------
-- Text helpers
-- ---------------------------------------------------------------------------

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(value)
    value = tostring(value or "")
    local output = {}
    for index = 1, #value, 3 do
        local first = value:byte(index) or 0
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local number = first * 65536 + (second or 0) * 256 + (third or 0)
        output[#output + 1] = base64_alphabet:sub(math.floor(number / 262144) + 1, math.floor(number / 262144) + 1)
        output[#output + 1] = base64_alphabet:sub(math.floor(number / 4096) % 64 + 1, math.floor(number / 4096) % 64 + 1)
        output[#output + 1] = second and base64_alphabet:sub(math.floor(number / 64) % 64 + 1, math.floor(number / 64) % 64 + 1) or "="
        output[#output + 1] = third and base64_alphabet:sub(number % 64 + 1, number % 64 + 1) or "="
    end
    return table.concat(output)
end

local function authorization_header(config)
    config = config or {}
    local username = tostring(config.username or "")
    local password = tostring(config.password or "")
    if username == "" and password == "" then return nil end
    return "Basic " .. base64_encode(username .. ":" .. password)
end

local function percent_decode(value)
    return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function utf8_from_codepoint(codepoint)
    codepoint = math.floor(tonumber(codepoint) or 0)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40)
    elseif codepoint <= 0x10FFFF then
        return string.char(
            0xF0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40)
    end
    return ""
end

local function decode_xml_entities(value)
    value = tostring(value or "")
    value = value:gsub("&#x(%x+);", function(hex)
        return utf8_from_codepoint(tonumber(hex, 16))
    end)
    value = value:gsub("&#(%d+);", function(decimal)
        return utf8_from_codepoint(tonumber(decimal))
    end)
    -- Decode &amp; last so an encoded ampersand round-trips exactly once.
    value = value:gsub("&lt;", "<"):gsub("&gt;", ">")
    value = value:gsub("&quot;", '"'):gsub("&apos;", "'")
    value = value:gsub("&amp;", "&")
    return value
end

local function trim_text(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Propfind parsing
-- ---------------------------------------------------------------------------

-- Split a 207 Multi-Status body into per-response fragments.  WebDAV element
-- names carry server-specific namespace prefixes (d:, D:, lp1:, none).  Tags
-- are ASCII, so scanning a lowercased copy keeps byte offsets aligned with
-- the original string while matching any prefix case-insensitively; entry
-- text is sliced from the untouched original to preserve name casing.
-- Match the complete local name, so response-like extension elements are
-- not confused with response blocks. Prefixes may contain dots and dashes.
local function find_open_tag(lower, name, position)
    local start, finish, qualified_name = lower:find(
        "<([%w_%.%-]+:" .. name .. ")%f[%s/>]", position
    )
    local bare_start, bare_finish, bare_name = lower:find(
        "<(" .. name .. ")%f[%s/>]", position
    )
    if bare_start and (not start or bare_start < start) then
        return bare_start, bare_finish, bare_name
    end
    return start, finish, qualified_name
end

local function closing_tag_pattern(qualified_name)
    return "</" .. qualified_name:gsub("([^%w])", "%%%1") .. "%s*>"
end

-- DAV response elements cannot nest. Match each closing tag against the
-- opening tag's full name, while retaining the original text and casing.
local function multistatus_blocks(xml)
    local blocks = {}
    local lower = xml:lower()
    local position = 1
    while true do
        local open_start, open_end, qualified_name = find_open_tag(lower, "response", position)
        if not open_start then break end
        local close_start, close_end = lower:find(closing_tag_pattern(qualified_name), open_end + 1)
        if not close_start then break end
        blocks[#blocks + 1] = xml:sub(open_end + 1, close_start - 1)
        position = close_end + 1
    end
    return blocks
end

local function first_tag_text(block, name)
    local lower = block:lower()
    local open_start, open_end, qualified_name = find_open_tag(lower, name:lower())
    if not open_start then return nil end
    local open_tag_end = lower:find(">", open_end + 1, true)
    if not open_tag_end then return nil end
    if lower:sub(open_tag_end - 1, open_tag_end) == "/>" then return "" end
    local close_start = lower:find(closing_tag_pattern(qualified_name), open_tag_end + 1)
    if close_start then
        return block:sub(open_tag_end + 1, close_start - 1)
    end
    return nil
end

local function has_collection_tag(block)
    return find_open_tag(block:lower(), "collection") ~= nil
end

-- Pure function so the parser is testable on a host Lua interpreter.  Returns
-- raw entries; list_directory turns them into display items.
function Webdav.parse_propfind(xml)
    local entries = {}
    if type(xml) ~= "string" or xml == "" then return entries end
    for block_index, block in ipairs(multistatus_blocks(xml)) do
        local href = decode_xml_entities(first_tag_text(block, "href") or "")
        if href ~= "" then
            entries[#entries + 1] = {
                href = href,
                displayname = decode_xml_entities(first_tag_text(block, "displayname") or ""),
                collection = has_collection_tag(block),
                content_length = tonumber(trim_text(first_tag_text(block, "getcontentlength") or "")),
            }
        end
    end
    return entries
end

local function entry_name(entry)
    if entry.displayname ~= nil and entry.displayname ~= "" then
        return entry.displayname
    end
    local path = tostring(entry.href):gsub("%?.*$", ""):gsub("/+$", "")
    return percent_decode(path:match("[^/]+$") or "")
end

-- ---------------------------------------------------------------------------
-- Config persistence
-- ---------------------------------------------------------------------------

local function config_path()
    return DataStorage:getDataDir() .. "/legado/webdav.json"
end

local function parent_directory(path)
    return tostring(path):match("^(.*)/[^/]+$") or "."
end

local function make_parent_directory(path)
    local directory = parent_directory(path)
    if lfs.attributes(directory, "mode") == "directory" then
        return true
    end
    local ok, result = pcall(util.makePath, directory)
    if not ok or result == false then
        return nil, "cannot create WebDAV settings directory: " .. tostring(result)
    end
    if lfs.attributes(directory, "mode") ~= "directory" then
        return nil, "WebDAV settings directory was not created"
    end
    return true
end

local function acquire_save_lock(path)
    local lock = path .. ".lock"
    local started = type(socket.gettime) == "function" and socket.gettime() or os.clock()
    while true do
        if lfs.mkdir(lock) then return lock end
        -- A SIGKILL can leave the lock directory behind.  It contains no user
        -- data, so an old lock is safe to reap; active saves finish in
        -- milliseconds and are never mistaken for it.
        local modified = lfs.attributes(lock, "modification")
        local now = type(socket.gettime) == "function" and socket.gettime() or os.clock()
        if modified and now - modified > 60 then
            pcall(lfs.rmdir, lock)
        elseif now - started > 15 then
            return nil, "timed out waiting for the WebDAV settings lock"
        else
            socket.sleep(0.02)
        end
    end
end

local function release_save_lock(lock)
    if lock then pcall(lfs.rmdir, lock) end
end

local function empty_config()
    return { url = "", username = "", password = "" }
end

function Webdav.load_config()
    local file = io.open(config_path(), "rb")
    if not file then return empty_config() end
    local data = file:read("*a")
    file:close()
    local ok, value = pcall(rapidjson.decode, data)
    if not ok or type(value) ~= "table" then
        return empty_config()
    end
    return {
        url = tostring(value.url or ""),
        username = tostring(value.username or ""),
        password = tostring(value.password or ""),
    }
end

function Webdav.save_config(config)
    config = config or {}
    local path = config_path()
    local parent_ok, parent_err = make_parent_directory(path)
    if not parent_ok then return nil, parent_err end
    local lock, lock_err = acquire_save_lock(path)
    if not lock then return nil, lock_err end
    local encoded_ok, encoded = pcall(rapidjson.encode, {
        schema_version = CONFIG_SCHEMA_VERSION,
        url = tostring(config.url or ""),
        username = tostring(config.username or ""),
        password = tostring(config.password or ""),
    })
    if not encoded_ok then
        release_save_lock(lock)
        return nil, "cannot encode the WebDAV settings file: " .. tostring(encoded)
    end
    local temporary = path .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local file, open_err = io.open(temporary, "wb")
    if not file then
        release_save_lock(lock)
        return nil, "cannot write the WebDAV settings file: " .. tostring(open_err)
    end
    local wrote, write_err = file:write(encoded)
    file:close()
    if not wrote then
        os.remove(temporary)
        release_save_lock(lock)
        return nil, "cannot write the WebDAV settings file: " .. tostring(write_err or "unknown error")
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        release_save_lock(lock)
        return nil, "cannot activate the WebDAV settings file: " .. tostring(rename_err or "unknown error")
    end
    release_save_lock(lock)
    -- chmod is optional across KOReader builds.  The file still lives in the
    -- KOReader data directory, and this tightens permissions where supported.
    pcall(function()
        if type(lfs.chmod) == "function" then
            lfs.chmod(path, "0600")
        end
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- URL helpers
-- ---------------------------------------------------------------------------

-- Directory URLs are canonicalized with a trailing slash on the path part so
-- PROPFIND scopes the collection itself and server hrefs join cleanly.  A
-- query string (token-authenticated bridges) is preserved verbatim.
function Webdav.normalize_directory_url(url)
    url = trim_text(url)
    if url == "" then
        return nil, _("No WebDAV server is configured.")
    end
    if url:lower():match("^https?://") == nil then
        return nil, _("The WebDAV URL must start with http:// or https://")
    end
    local query = url:match("%?.*$")
    local base = query and url:sub(1, #url - #query) or url
    if base:sub(-1) ~= "/" then
        base = base .. "/"
    end
    return base .. (query or "")
end

-- Parent collection of a normalized directory URL, or nil at the server root.
function Webdav.parent_url(url)
    local origin, path = tostring(url or ""):match("^(%w[%w+.-]*://[^/]+)(/.+)$")
    if not origin or not path then return nil end
    path = path:gsub("%?.*$", "")
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end
    if path == "/" then return nil end
    local parent_path = path:match("^(.+/)[^/]+/$")
    if not parent_path then return nil end
    return origin .. parent_path
end

-- ---------------------------------------------------------------------------
-- HTTP transport
-- ---------------------------------------------------------------------------

-- Compare scheme, host and effective port, rather than a URL prefix. Reject
-- embedded credentials so LuaSocket cannot synthesize an Authorization header
-- for a redirected URL behind our back.
local function url_origin(url)
    local parsed = socket_url.parse(tostring(url or ""))
    local scheme = parsed and tostring(parsed.scheme or ""):lower()
    if not parsed or (scheme ~= "http" and scheme ~= "https")
            or not parsed.host or parsed.host == "" then
        return nil, "invalid WebDAV HTTP URL"
    end
    if parsed.userinfo or parsed.user or parsed.password then
        return nil, "WebDAV URLs must not contain credentials"
    end
    local port = tonumber(parsed.port or (scheme == "https" and 443 or 80))
    if not port or port < 1 or port > 65535 or port ~= math.floor(port) then
        return nil, "invalid WebDAV port"
    end
    return scheme .. "://" .. parsed.host:lower() .. ":" .. tostring(port), scheme
end

-- One logical request against the configured server.  Returns
-- status_code, response_headers, response_body (buffered only when the caller
-- passed no sink_factory) or nil, error_message on transport failures. Redirects
-- keep the method and body: WebDAV verbs are idempotent here, and downgrading
-- a redirected PROPFIND to GET would return an HTML page instead of 207.
-- A sink_factory creates a fresh output for each response, so redirect bodies
-- and end-of-stream events cannot corrupt the final download. Credentials are
-- attached only to the configured origin, and HTTPS downgrades are refused.
function Webdav.request(config, options)
    config = config or {}
    options = options or {}
    local method = tostring(options.method or "GET"):upper()
    local headers = {}
    local auth = authorization_header(config)
    for key, value in pairs(options.headers or {}) do
        if tostring(key):lower() == "authorization" then
            auth = tostring(value)
        else
            headers[tostring(key)] = tostring(value)
        end
    end
    headers["User-Agent"] = headers["User-Agent"] or Network.user_agent()
    local body = options.body
    if body ~= nil then
        headers["Content-Length"] = tostring(#body)
    end
    local configured_origin, configured_scheme = url_origin(config.url)
    if auth and not configured_origin then return nil, configured_scheme end
    local credential_origin = auth and configured_origin
    local timeout_seconds = tonumber(options.timeout) or DEFAULT_TIMEOUT_SECONDS
    local url = tostring(options.url or "")
    local require_https = configured_origin and configured_scheme == "https"
    local redirect_count = 0
    while true do
        local origin, scheme = url_origin(url)
        if not origin then return nil, scheme end
        if require_https and scheme ~= "https" then
            return nil, "WebDAV HTTPS downgrade is not allowed"
        end
        require_https = require_https or scheme == "https"
        local requester = http
        if scheme == "https" then
            if not https then
                return nil, "HTTPS support is unavailable in this KOReader build"
            end
            requester = https
        end
        local chunks, sink
        if options.sink_factory then
            local sink_err
            sink, sink_err = options.sink_factory()
            if not sink then return nil, sink_err end
        else
            chunks = {}
            sink = ltn12.sink.table(chunks)
        end
        local request_headers = {}
        for key, value in pairs(headers) do
            request_headers[key] = value
        end
        if origin == credential_origin then
            request_headers.Authorization = auth
        end
        local request = {
            url = url,
            method = method,
            headers = request_headers,
            sink = sink,
            -- All hops must pass the origin and downgrade checks above.
            redirect = false,
        }
        if body ~= nil and method ~= "GET" and method ~= "HEAD" then
            request.source = ltn12.source.string(body)
        end
        local previous_timeout = requester.TIMEOUT
        requester.TIMEOUT = timeout_seconds
        local called, ok, code, response_headers, status = pcall(requester.request, request)
        requester.TIMEOUT = previous_timeout
        if not called then
            return nil, "WebDAV request failed: " .. tostring(ok)
        end
        local numeric_code = tonumber(code)
        if not ok then
            return nil, "WebDAV request failed: " .. tostring(code or status or "unknown error")
        end
        if numeric_code and numeric_code >= 300 and numeric_code < 400 then
            local location = response_headers
                and (response_headers.location or response_headers.Location)
            if location and redirect_count < REQUEST_REDIRECT_LIMIT then
                redirect_count = redirect_count + 1
                url = Network.absolute(url, location)
            else
                return nil, "WebDAV redirect limit exceeded"
            end
        else
            return numeric_code or 0, response_headers, chunks and table.concat(chunks) or nil
        end
    end
end

function Webdav.list_directory(config, url)
    local directory_url, normalize_err = Webdav.normalize_directory_url(url)
    if not directory_url then return nil, normalize_err end
    local code, headers_or_err, body_text = Webdav.request(config, {
        url = directory_url,
        method = "PROPFIND",
        headers = {
            Depth = "1",
            ["Content-Type"] = "application/xml",
        },
        body = '<?xml version="1.0" encoding="utf-8"?>\n'
            .. '<d:propfind xmlns:d="DAV:"><d:prop>'
            .. '<d:displayname/><d:resourcetype/><d:getcontentlength/>'
            .. '</d:prop></d:propfind>',
    })
    if not code then return nil, headers_or_err end
    if code == 401 then
        return nil, _("WebDAV authentication failed. Check the username and password.")
    end
    if code ~= 207 and code ~= 200 then
        return nil, "WebDAV directory listing failed: HTTP status " .. tostring(code)
    end
    local strip_trailing = function(value)
        return tostring(value):gsub("/+$", "")
    end
    local items = {}
    for entry_index, entry in ipairs(Webdav.parse_propfind(body_text or "")) do
        local entry_url = Network.absolute(directory_url, entry.href)
        -- Servers echo the requested collection itself with Depth: 1.
        if strip_trailing(entry_url) ~= strip_trailing(directory_url) then
            local is_dir = entry.collection or tostring(entry.href):match("/$") ~= nil
            items[#items + 1] = {
                name = entry_name(entry),
                url = entry_url,
                is_dir = is_dir,
                size = entry.content_length,
            }
        end
    end
    table.sort(items, function(left, right)
        if left.is_dir ~= right.is_dir then return left.is_dir end
        return left.name:lower() < right.name:lower()
    end)
    return items
end

-- Stream a file to destination.  Returns { path, bytes } or nil, error.
-- The download never buffers the whole archive: bytes flow straight into the
-- output file, with the size cap enforced inside the sink.
function Webdav.download_file(config, url, destination)
    local file
    local bytes_written = 0
    local overflow = false
    local close_err
    local close_file = function()
        if file then
            local closed, err = file:close()
            if not closed then close_err = err or "cannot close the download file" end
            file = nil
        end
    end
    local guarded_sink = function(chunk, sink_err)
        if chunk == nil then
            close_file()
            if sink_err or close_err then return nil, sink_err or close_err end
            return true
        end
        bytes_written = bytes_written + #chunk
        if bytes_written > MAX_DOWNLOAD_BYTES then
            overflow = true
            return nil, "download exceeded the size limit"
        end
        return file:write(chunk)
    end
    local code, headers_or_err = Webdav.request(config, {
        url = url,
        method = "GET",
        sink_factory = function()
            close_file()
            if close_err then return nil, close_err end
            local open_err
            file, open_err = io.open(destination, "wb")
            if not file then
                return nil, "cannot create the download file: " .. tostring(open_err)
            end
            bytes_written = 0
            return guarded_sink
        end,
    })
    -- The sink only closes the file on a clean end-of-stream; a transport or
    -- size failure aborts the pump without one.
    close_file()
    local cleanup = function()
        os.remove(destination)
    end
    if overflow then
        cleanup()
        return nil, _("The WebDAV file is too large to import.")
    end
    if not code then
        cleanup()
        return nil, headers_or_err or _("Backup download failed.")
    end
    if close_err then
        cleanup()
        return nil, close_err
    end
    if code ~= 200 then
        cleanup()
        return nil, "WebDAV download failed: HTTP status " .. tostring(code)
    end
    return {
        path = destination,
        bytes = bytes_written,
    }
end

return Webdav
