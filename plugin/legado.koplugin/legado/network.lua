-- Small synchronous HTTP adapter.  Callers should run it through Trapper's
-- subprocess helper so a slow site never blocks the KOReader UI.

local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local https
pcall(function()
    https = require("ssl.https")
end)

local Network = {}

local function trim(value)
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Keep a per-process session jar. Runtime snapshots it into the per-source
-- login store when a Trapper worker exits.
local cookie_jar = {}

local function request_host(url)
    local value = tostring(url or "")
    local host = value:match("^https?://([^/%?#]+)")
    if host then
        return host
    end
    -- Legado sources sometimes pass a bare domain to cookie.removeCookie or
    -- cookie.setCookie (notably for third-party login state).
    return value:match("^([^/%?#:]+%.[^/%?#:]+)$")
end

local function cookies_for(url)
    local host = request_host(url)
    local values = host and cookie_jar[host:lower()]
    if not values then
        return nil
    end
    local result = {}
    for name, value in pairs(values) do
        result[#result + 1] = name .. "=" .. value
    end
    table.sort(result)
    return #result > 0 and table.concat(result, "; ") or nil
end

local function cookie_host(url)
    local host = request_host(url)
    return host and host:lower() or nil
end

local function set_cookie_header(url, cookie_header)
    local host = cookie_host(url)
    if not host then
        return ""
    end
    local values = cookie_jar[host] or {}
    for piece in tostring(cookie_header or ""):gmatch("[^;]+") do
        local name, value = piece:match("^%s*([^=;]+)=(.-)%s*$")
        local lowered_name = name and trim(name):lower() or ""
        local is_attribute = lowered_name == "path" or lowered_name == "domain"
            or lowered_name == "expires" or lowered_name == "max-age"
            or lowered_name == "secure" or lowered_name == "httponly"
            or lowered_name == "samesite"
        if name and value and not is_attribute then
            name = trim(name)
            if value == "" then
                values[name] = nil
            else
                values[name] = value
            end
        end
    end
    cookie_jar[host] = values
    return cookies_for(url) or ""
end

local function update_cookies(url, response_headers)
    local host = cookie_host(url)
    if not host or type(response_headers) ~= "table" then
        return
    end
    local raw = response_headers["set-cookie"] or response_headers["Set-Cookie"]
    if not raw then
        return
    end
    if type(raw) == "string" then
        raw = { raw }
    end
    if type(raw) ~= "table" then
        return
    end
    local values = cookie_jar[host:lower()] or {}
    for _, cookie in pairs(raw) do
        local pair = tostring(cookie):match("^%s*([^;]+)")
        -- Do not put the matcher behind `and` in a multiple assignment:
        -- Lua collapses the matcher result there and drops the cookie value.
        local name, value
        if pair then
            name, value = pair:match("^([^=;]+)=(.*)$")
        end
        if name and value then
            name = trim(name)
            if value == "" then
                values[name] = nil
            else
                values[name] = trim(value)
            end
        end
    end
    cookie_jar[host:lower()] = values
end

local function percent_decode(value)
    return tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64_reverse

local function decode_base64(value)
    if not base64_reverse then
        base64_reverse = {}
        for index = 1, #base64_alphabet do
            base64_reverse[base64_alphabet:sub(index, index)] = index - 1
        end
    end
    local input = tostring(value or ""):gsub("%s+", "")
    local output = {}
    for index = 1, #input, 4 do
        local a = base64_reverse[input:sub(index, index)]
        local b = base64_reverse[input:sub(index + 1, index + 1)]
        local c_char = input:sub(index + 2, index + 2)
        local d_char = input:sub(index + 3, index + 3)
        local c = c_char == "=" and nil or base64_reverse[c_char]
        local d = d_char == "=" and nil or base64_reverse[d_char]
        if a == nil or b == nil then
            return nil, "invalid data URI Base64 payload"
        end
        local number = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        output[#output + 1] = string.char(math.floor(number / 65536) % 256)
        if c ~= nil then
            output[#output + 1] = string.char(math.floor(number / 256) % 256)
        end
        if d ~= nil then
            output[#output + 1] = string.char(number % 256)
        end
    end
    return table.concat(output)
end

local function hex_encode(value)
    local output = {}
    for index = 1, #value do
        output[#output + 1] = string.format("%02x", value:byte(index))
    end
    return table.concat(output)
end

local function data_uri_value(url)
    local metadata, payload = tostring(url or ""):match("^data:([^,]*),(.*)$")
    if not metadata then
        return nil, "invalid data URI"
    end
    if metadata:lower():match(";base64") then
        return decode_base64(payload)
    end
    return percent_decode(payload)
end

local iconv_state = false
local iconv_library

local function get_iconv()
    if iconv_state then
        return iconv_library
    end
    iconv_state = true
    local ok, ffi = pcall(require, "ffi")
    if not ok then
        return nil
    end
    pcall(ffi.cdef, [[
        typedef long intptr_t;
        typedef void *iconv_t;
        iconv_t iconv_open(const char *tocode, const char *fromcode);
        size_t iconv(iconv_t cd, char **inbuf, size_t *inbytesleft,
                     char **outbuf, size_t *outbytesleft);
        int iconv_close(iconv_t cd);
    ]])
    if type(ffi.loadlib) ~= "function" then
        return nil
    end
    for _, name in ipairs({ "iconv", "miniconv", "c" }) do
        local loaded = false
        local library
        loaded, library = pcall(function()
            return ffi.loadlib(name, "1")
        end)
        if not loaded or not library then
            loaded, library = pcall(function()
                return ffi.loadlib(name)
            end)
        end
        if loaded and library then
            local available = pcall(function()
                return library.iconv_open
            end)
            if available then
                iconv_library = library
                return iconv_library
            end
        end
    end
    return nil
end

local function convert_charset(value, from_charset, to_charset)
    value = tostring(value or "")
    from_charset = trim(from_charset or "UTF-8")
    to_charset = trim(to_charset or "UTF-8")
    local from_lower = from_charset:lower()
    local to_lower = to_charset:lower()
    local from_utf8 = from_lower == "utf8" or from_lower == "utf-8"
    local to_utf8 = to_lower == "utf8" or to_lower == "utf-8"
    if value == "" or from_lower == to_lower or (from_utf8 and to_utf8) then
        return value
    end
    local library = get_iconv()
    local ffi = package.loaded.ffi
    if not library or not ffi then
        return value
    end
    local ok, converted = pcall(function()
        local handle = library.iconv_open(to_charset, from_charset)
        if handle == nil or tonumber(ffi.cast("intptr_t", handle)) == -1 then
            return value
        end
        local input = ffi.new("char[?]", #value + 1, value)
        local output_size = #value * 4 + 64
        local output = ffi.new("char[?]", output_size)
        local input_ptr = ffi.new("char *[1]", ffi.cast("char *", input))
        local input_left = ffi.new("size_t[1]", #value)
        local output_ptr = ffi.new("char *[1]", ffi.cast("char *", output))
        local output_left = ffi.new("size_t[1]", output_size)
        library.iconv(handle, input_ptr, input_left, output_ptr, output_left)
        library.iconv_close(handle)
        if input_left[0] ~= 0 then
            return value
        end
        return ffi.string(output, output_size - output_left[0])
    end)
    return ok and converted or value
end

local function url_encode(value, charset)
    value = convert_charset(value, "UTF-8", charset or "UTF-8")
    return tostring(value):gsub("([^%w%-%._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function headers_from_source(source)
    local headers = {
        ["User-Agent"] = socketutil.USER_AGENT,
        ["Accept"] = "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
    }
    local raw = source and source.header
    if type(raw) == "table" then
        for key, value in pairs(raw) do
            if type(value) == "string" or type(value) == "number" then
                headers[tostring(key)] = tostring(value)
            end
        end
        return headers
    end
    if type(raw) ~= "string" or raw == "" then
        return headers
    end
    if raw:lower():match("^@js:") or raw:lower():match("^<js>") then
        return nil, "source header uses JavaScript"
    end
    local ok, decoded = pcall(rapidjson.decode, raw)
    if ok and type(decoded) == "table" then
        for key, value in pairs(decoded) do
            if type(value) == "string" or type(value) == "number" then
                headers[tostring(key)] = tostring(value)
            end
        end
        return headers
    end
    -- Some older sources store one HTTP header per line instead of JSON.
    for line in raw:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
        if key and value then
            headers[key] = value
        end
    end
    return headers
end

local function decode_options(value)
    if type(value) == "table" then
        return value
    end
    if type(value) ~= "string" or trim(value) == "" then
        return nil
    end
    local ok, decoded = pcall(rapidjson.decode, value)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

local function merge_options(primary, secondary)
    local result = {}
    if type(primary) == "table" then
        for key, value in pairs(primary) do
            result[key] = value
        end
    end
    if type(secondary) == "table" then
        for key, value in pairs(secondary) do
            result[key] = value
        end
    end
    return next(result) and result or nil
end

local function apply_option_headers(headers, options)
    if type(options) ~= "table" then
        return
    end
    local raw = options.headers or options.header
    raw = decode_options(raw) or raw
    if type(raw) == "table" then
        for key, value in pairs(raw) do
            if value ~= nil and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
                headers[tostring(key)] = tostring(value)
            end
        end
    end
    if options.cookie ~= nil then
        headers.Cookie = tostring(options.cookie)
    end
end

local function split_url_options(value)
    value = tostring(value or "")
    local comma = value:find(",", 1, true)
    local found_url
    local found_options
    while comma do
        local tail = value:sub(comma + 1):match("^%s*(.*)$")
        local ok, options = pcall(rapidjson.decode, tail)
        if ok and type(options) == "table" then
            found_url = trim(value:sub(1, comma - 1))
            found_options = options
        end
        comma = value:find(",", comma + 1, true)
    end
    return found_url or trim(value), found_options
end

local function decode_response(value, charset)
    charset = trim(charset or "")
    if charset == "" or charset:lower() == "utf8" or charset:lower() == "utf-8" then
        return value
    end
    return convert_charset(value, charset, "UTF-8")
end

function Network.url_encode(value, charset)
    return url_encode(value, charset)
end

function Network.url_encode_charset(value, charset)
    return url_encode(value, charset)
end

function Network.url_options(value)
    local _, options = split_url_options(value)
    return options
end

function Network.user_agent()
    return socketutil.USER_AGENT
end

function Network.cookie_get(url)
    return cookies_for(url) or ""
end

function Network.cookie_set(url, value)
    return set_cookie_header(url, value)
end

function Network.cookie_remove(url)
    local host = cookie_host(url)
    if host then
        cookie_jar[host] = nil
    end
    return ""
end

function Network.cookie_key(url, key)
    local cookies = Network.cookie_get(url)
    for piece in cookies:gmatch("[^;]+") do
        local name, value = piece:match("^%s*([^=;]+)=(.-)%s*$")
        if name == tostring(key) then
            return value
        end
    end
    return ""
end

-- A worker is short-lived in KOReader, so the runtime takes a snapshot of
-- this jar before the worker exits and restores it for the next request.
function Network.reset_cookies()
    cookie_jar = {}
end

function Network.export_cookies()
    local result = {}
    for host, cookies in pairs(cookie_jar) do
        if type(host) == "string" and type(cookies) == "table" then
            local copied = {}
            for name, value in pairs(cookies) do
                if type(name) == "string"
                        and (type(value) == "string" or type(value) == "number") then
                    copied[name] = tostring(value)
                end
            end
            if next(copied) ~= nil then
                result[host] = copied
            end
        end
    end
    return result
end

function Network.import_cookies(snapshot)
    Network.reset_cookies()
    if type(snapshot) ~= "table" then
        return
    end
    for host, cookies in pairs(snapshot) do
        if type(host) == "string" and type(cookies) == "table" then
            local copied = {}
            for name, value in pairs(cookies) do
                if type(name) == "string"
                        and (type(value) == "string" or type(value) == "number") then
                    copied[name] = tostring(value)
                end
            end
            if next(copied) ~= nil then
                cookie_jar[host:lower()] = copied
            end
        end
    end
end

function Network.absolute(base_url, value)
    local clean_base = split_url_options(base_url or "")
    local clean_value, options = split_url_options(value)
    if clean_value == "" then
        return ""
    end
    if clean_value:lower():match("^data:") then
        if options then
            return clean_value .. "," .. rapidjson.encode(options)
        end
        return clean_value
    end
    local ok, absolute = pcall(socket_url.absolute, clean_base or "", clean_value)
    if ok and absolute then
        if options then
            local encoded_options = rapidjson.encode(options)
            return absolute .. "," .. encoded_options
        end
        return absolute
    end
    return value
end

function Network.get(url, source, extra_options)
    local headers, header_err = headers_from_source(source)
    if not headers then
        return nil, header_err
    end
    local clean_url, url_options_value = split_url_options(url)
    local options = merge_options(url_options_value, decode_options(extra_options) or extra_options)
    local method = "GET"
    local body
    if options then
        method = tostring(options.method or "GET"):upper()
        if method ~= "GET" and method ~= "POST" and method ~= "HEAD"
                and method ~= "PUT" and method ~= "PATCH" and method ~= "DELETE" then
            return nil, "unsupported HTTP method in URL options: " .. method
        end
        if options.body ~= nil then
            if type(options.body) == "table" then
                local encoded_ok, encoded = pcall(rapidjson.encode, options.body)
                if not encoded_ok then
                    return nil, "cannot encode HTTP JSON body: " .. tostring(encoded)
                end
                body = encoded
            else
                body = tostring(options.body)
            end
        end
        apply_option_headers(headers, options)
    end
    if method ~= "GET" and method ~= "HEAD" then
        body = body or ""
        if options and options.charset and tostring(options.charset):lower() ~= "utf-8"
                and tostring(options.charset):lower() ~= "utf8" then
            body = convert_charset(body, "UTF-8", options.charset)
        end
        if headers["Content-Type"] == nil and headers["content-type"] == nil then
            headers["Content-Type"] = (body:match("^%s*%[") or body:match("^%s*{"))
                and "application/json" or "application/x-www-form-urlencoded"
        end
        headers["Content-Length"] = tostring(#body)
    end
    if clean_url:lower():match("^data:") then
        local data, data_err = data_uri_value(clean_url)
        if not data then
            return nil, data_err
        end
        if options and options.type ~= nil then
            return hex_encode(data), nil, 200
        end
        return decode_response(data, options and options.charset), nil, 200
    end

    local redirect_count = 0
    while true do
        local chunks = {}
        local request_headers = {}
        for key, value in pairs(headers) do
            request_headers[key] = value
        end
        local session_cookie = cookies_for(clean_url)
        if session_cookie then
            local explicit_cookie = request_headers.Cookie or request_headers.cookie
            request_headers.Cookie = explicit_cookie
                and (explicit_cookie .. "; " .. session_cookie)
                or session_cookie
        end
        local request = {
            url = clean_url,
            method = method,
            headers = request_headers,
            sink = ltn12.sink.table(chunks),
        }
        if method ~= "GET" and method ~= "HEAD" then
            request.source = ltn12.source.string(body or "")
        end
        local requester = http
        if clean_url:lower():match("^https://") then
            if not https then
                return nil, "HTTPS support is unavailable in this KOReader build"
            end
            requester = https
        end
        local ok, code, response_headers, status = requester.request(request)
        local numeric_code = tonumber(code)
        if not ok then
            return nil, "HTTP request failed: " .. tostring(code or status or "unknown error")
        end
        update_cookies(clean_url, response_headers)
        if numeric_code and numeric_code >= 300 and numeric_code < 400 then
            local location = response_headers and (response_headers.location or response_headers.Location)
            if location and redirect_count < 5 then
                redirect_count = redirect_count + 1
                clean_url = Network.absolute(clean_url, location)
                if numeric_code ~= 307 and numeric_code ~= 308 then
                    method = "GET"
                    body = nil
                    headers["Content-Length"] = nil
                end
            else
                return nil, "HTTP redirect limit exceeded"
            end
        else
            if numeric_code and (numeric_code < 200 or numeric_code >= 400) then
                return nil, "HTTP status " .. tostring(numeric_code)
            end
            local response = table.concat(chunks)
            if options and options.type ~= nil then
                return hex_encode(response), response_headers, numeric_code
            end
            return decode_response(response, options and options.charset), response_headers, numeric_code
        end
    end
end

return Network
