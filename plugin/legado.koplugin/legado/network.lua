-- Small synchronous HTTP adapter.  Callers should run it through Trapper's
-- subprocess helper so a slow site never blocks the KOReader UI.

local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local socket = require("socket")
local https
pcall(function()
    https = require("ssl.https")
end)

local Network = {}
local DEFAULT_HTTP_TIMEOUT_SECONDS = 20

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

-- LuaSocket may fold repeated Set-Cookie headers into one comma-separated
-- value. Commas inside Expires attributes are not cookie separators, so only
-- split when the following text starts another `name=value` pair.
local function split_set_cookie_header(value)
    local input = tostring(value or "")
    local result = {}
    local start = 1
    local in_quotes = false
    for index = 1, #input do
        local character = input:sub(index, index)
        if character == '"' then
            in_quotes = not in_quotes
        elseif character == "," and not in_quotes then
            local tail = input:sub(index + 1)
            if tail:match("^%s*[^=;,%s]+%s*=") then
                result[#result + 1] = input:sub(start, index - 1)
                start = index + 1
            end
        end
    end
    result[#result + 1] = input:sub(start)
    return result
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
    local cookies = {}
    if type(raw) == "string" then
        cookies = split_set_cookie_header(raw)
    elseif type(raw) == "table" then
        for _, value in pairs(raw) do
            if type(value) == "string" then
                local parts = split_set_cookie_header(value)
                for _, part in ipairs(parts) do
                    cookies[#cookies + 1] = part
                end
            end
        end
    else
        return
    end
    local values = cookie_jar[host:lower()] or {}
    for _, cookie in ipairs(cookies) do
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

local function apply_login_header(headers, source)
    local raw = source and source.__legado_login_header
    if type(raw) == "string" then
        local decoded_ok, decoded = pcall(rapidjson.decode, raw)
        raw = decoded_ok and decoded or nil
    end
    if type(raw) ~= "table" then return end
    for key, value in pairs(raw) do
        if type(value) == "string" or type(value) == "number" then
            headers[tostring(key)] = tostring(value)
        end
    end
end

local function url_encode(value, charset)
    value = convert_charset(value, "UTF-8", charset or "UTF-8")
    return tostring(value):gsub("([^%w%-%._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function headers_from_source(source, context)
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
        apply_login_header(headers, source)
        return headers
    end
    if type(raw) ~= "string" or raw == "" then
        apply_login_header(headers, source)
        return headers
    end
    if raw:lower():match("^@js:") or raw:lower():match("^<js>") then
        local evaluator = context and context.__js_eval
        if type(evaluator) ~= "function" then
            return nil, "source header uses JavaScript"
        end
        if context.__legado_evaluating_header then
            -- A header rule may itself make a request. Avoid recursively
            -- evaluating the same header; the nested request receives the
            -- default headers and can still use cookies/source variables.
            raw = ""
        else
            local header_context = {}
            for key, value in pairs(context) do header_context[key] = value end
            header_context.__legado_evaluating_header = true
            local value, suffix, eval_err = evaluator(
                raw,
                context.result or "",
                header_context
            )
            if eval_err then return nil, "source header: " .. tostring(eval_err) end
            if suffix and trim(suffix) ~= "" then
                return nil, "source header has an unsupported trailing rule"
            end
            if type(value) == "string" then
                local decoded_ok, decoded = pcall(rapidjson.decode, value)
                if decoded_ok then value = decoded end
            end
            if type(value) ~= "table" then
                return nil, "source header JavaScript did not return an object"
            end
            for key, item in pairs(value) do
                if type(item) == "string" or type(item) == "number" then
                    headers[tostring(key)] = tostring(item)
                end
            end
            apply_login_header(headers, source)
            return headers
        end
    end
    local ok, decoded = pcall(rapidjson.decode, raw)
    if ok and type(decoded) == "table" then
        for key, value in pairs(decoded) do
            if type(value) == "string" or type(value) == "number" then
                headers[tostring(key)] = tostring(value)
            end
        end
        apply_login_header(headers, source)
        return headers
    end
    -- Some older sources store one HTTP header per line instead of JSON.
    for line in raw:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
        if key and value then
            headers[key] = value
        end
    end
    apply_login_header(headers, source)
    return headers
end

-- Return the static portion of a source header for an interactive Chromium
-- page. Dynamic `@js` headers still belong to the source's JS/HTTP path and
-- cannot be evaluated recursively while that same JS call is waiting for the
-- browser. Cookie state is installed through the browser cookie store.
function Network.browser_headers(source, context)
    local raw = source and source.header
    if type(raw) == "string"
            and (raw:lower():match("^@js:") or raw:lower():match("^<js>")) then
        local headers, err = headers_from_source(source, context)
        if not headers then
            -- startBrowser may be called without a rule context. Dynamic
            -- headers are then intentionally omitted; ordinary requests
            -- still evaluate them through the context above.
            if not context then return {} end
            return nil, err
        end
        return headers
    end
    local headers, err = headers_from_source(source)
    if not headers then
        return nil, err
    end
    local result = {}
    for key, value in pairs(headers) do
        local lowered = tostring(key):lower()
        if lowered ~= "host" and lowered ~= "content-length"
                and lowered ~= "connection" then
            result[tostring(key)] = tostring(value)
        end
    end
    return result
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

-- Chapter URL rules commonly append the same JSON option object to every
-- href (for example `{ "webView": true }`). Decoding and re-encoding that
-- suffix thousands of times is wasteful on the Kindle's 32-bit CPU. Keep a
-- bounded cache keyed by the exact JSON tail; callers still receive a fresh
-- merged table when they need to mutate options.
local url_option_cache = {}
local url_option_cache_size = 0

local function cached_url_options(tail)
    local cached = url_option_cache[tail]
    if cached then
        return cached.options, cached.encoded
    end
    local ok, options = pcall(rapidjson.decode, tail)
    if not ok or type(options) ~= "table" then
        return nil
    end
    local encoded_ok, encoded = pcall(rapidjson.encode, options)
    if not encoded_ok then
        return options
    end
    -- A source can have many distinct signed URLs. Bound this optimization so
    -- URL parsing never becomes an unbounded state store.
    if url_option_cache_size >= 256 then
        url_option_cache = {}
        url_option_cache_size = 0
    end
    url_option_cache[tail] = { options = options, encoded = encoded }
    url_option_cache_size = url_option_cache_size + 1
    return options, encoded
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
    local found_encoded
    while comma do
        local tail = value:sub(comma + 1):match("^%s*(.*)$")
        local options, encoded = cached_url_options(tail)
        if options then
            found_url = trim(value:sub(1, comma - 1))
            found_options = options
            found_encoded = encoded
        end
        comma = value:find(",", comma + 1, true)
    end
    return found_url or trim(value), found_options, found_encoded
end

local function decode_response(value, charset)
    charset = trim(charset or "")
    if charset == "" or charset:lower() == "utf8" or charset:lower() == "utf-8" then
        return value
    end
    return convert_charset(value, charset, "UTF-8")
end

local function shallow_copy(value)
    local result = {}
    if type(value) == "table" then
        for key, item in pairs(value) do result[key] = item end
    end
    return result
end

local function evaluate_url_option_js(clean_url, options)
    local script = type(options) == "table" and options.js
    local context = type(options) == "table" and options.__legado_context
    if type(script) ~= "string" or trim(script) == "" then
        return clean_url, options
    end
    if type(context) ~= "table" or type(context.__js_eval) ~= "function" then
        return nil, "URL option js requires a JavaScript evaluator"
    end

    -- AnalyzeUrl runs this code after it has populated java.url and
    -- java.headerMap. Returning both values lets the Lua request layer apply
    -- mutations made by source code such as
    -- `java.headerMap.put('X-Token', token)` without exposing Lua tables to JS.
    local js_context = shallow_copy(context)
    js_context.baseUrl = clean_url
    js_context.result = ""
    local wrapped = "<js>(function(){\n" .. script
        .. "\n;return {url:String(java.url||''),headers:java.headerMap||{}};})()</js>"
    local value, _, err = context.__js_eval(wrapped, "", js_context)
    if err then return nil, "URL option js: " .. tostring(err) end
    if type(value) ~= "table" then
        return nil, "URL option js did not return a request object"
    end
    local next_url = trim(value.url or "")
    if next_url == "" then next_url = clean_url end
    local next_options = shallow_copy(options)
    next_options.js = nil
    if type(value.headers) == "table" then
        next_options.headers = value.headers
    end
    return next_url, next_options
end

local function apply_body_js(body, options)
    local script = type(options) == "table" and options.bodyJs
    local context = type(options) == "table" and options.__legado_context
    if type(script) ~= "string" or trim(script) == "" then
        return body
    end
    if type(context) ~= "table" or type(context.__js_eval) ~= "function" then
        return nil, "URL option bodyJs requires a JavaScript evaluator"
    end
    local js_context = shallow_copy(context)
    js_context.result = body or ""
    js_context.src = body or ""
    local value, _, err = context.__js_eval("<js>" .. script .. "</js>", body or "", js_context)
    if err then return nil, "URL option bodyJs: " .. tostring(err) end
    if value == nil then return "" end
    if type(value) == "table" then
        local ok, encoded = pcall(rapidjson.encode, value)
        return ok and encoded or tostring(value)
    end
    return tostring(value)
end

local function response_body(body_chunks, response_headers, code, options)
    local response = table.concat(body_chunks or {})
    if options and options.type ~= nil then
        return hex_encode(response), response_headers, code
    end
    local decoded = decode_response(response, options and options.charset)
    local body, body_err = apply_body_js(decoded, options)
    if body == nil then
        return nil, body_err
    end
    return body, response_headers, code
end

local function response_cookies(url)
    local host = cookie_host(url)
    local cookies = host and cookie_jar[host] or nil
    local result = {}
    for name, value in pairs(cookies or {}) do
        result[tostring(name)] = tostring(value)
    end
    return result
end

function Network.url_encode(value, charset)
    return url_encode(value, charset)
end

function Network.url_encode_charset(value, charset)
    return url_encode(value, charset)
end

function Network.convert_charset(value, from_charset, to_charset)
    return convert_charset(value, from_charset, to_charset)
end

function Network.url_options(value)
    local _, options = split_url_options(value)
    return options
end

function Network.user_agent()
    return socketutil.USER_AGENT
end

-- Source JavaScript exposes getHeaderMap() as the same resolved request
-- header map used by the HTTP client. Keep this small public wrapper so the
-- Lua host can honor dynamic source headers without duplicating their
-- evaluation rules.
function Network.headers(source, context)
    return headers_from_source(source, context)
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

-- Merge cookies produced by an interactive browser into the current source
-- session without discarding cookies that were already set by the source's
-- HTTP requests. The browser helper intentionally reduces cookies to the same
-- host -> name -> value shape used by the lightweight HTTP jar.
function Network.merge_cookies(snapshot)
    if type(snapshot) ~= "table" then
        return
    end
    for host, cookies in pairs(snapshot) do
        if type(host) == "string" and type(cookies) == "table" then
            local lowered_host = host:lower():gsub("^%.", "")
            local current = cookie_jar[lowered_host] or {}
            for name, value in pairs(cookies) do
                if type(name) == "string"
                        and (type(value) == "string" or type(value) == "number") then
                    current[name] = tostring(value)
                end
            end
            if next(current) ~= nil then
                cookie_jar[lowered_host] = current
            end
        end
    end
end

local function append_url_options(value, options, encoded_options)
    if options then
        return value .. "," .. (encoded_options or rapidjson.encode(options))
    end
    return value
end

-- Resolve the common absolute/root-relative forms before splitting both URLs.
-- This avoids even the small amount of URL-option scanning needed by the
-- general path for every item in a large TOC.  If the suffix is not a single
-- JSON options object, return nil and let the full resolver handle it.
local fast_base_cache = {}
local fast_base_cache_size = 0

local function fast_base_parts(base_url)
    local cached = fast_base_cache[base_url]
    if cached then return cached.scheme, cached.origin end
    local parts = {
        scheme = base_url:match("^([%w][%w+.-]*):"),
        origin = base_url:match("^([%w][%w+.-]*://[^/%?#]+)"),
    }
    if fast_base_cache_size >= 32 then
        fast_base_cache = {}
        fast_base_cache_size = 0
    end
    fast_base_cache[base_url] = parts
    fast_base_cache_size = fast_base_cache_size + 1
    return parts.scheme, parts.origin
end

local function fast_absolute(base_url, value)
    -- Rules normally return already-trimmed href values. Avoid gsub-based
    -- trimming on every chapter; malformed/whitespace-heavy values simply
    -- fall through to split_url_options(), which retains the old behavior.
    local raw_base = tostring(base_url or "")
    local raw_value = tostring(value or "")
    if raw_value == "" then return "" end

    local clean_value = raw_value
    local options
    local encoded_options
    local comma = raw_value:find(",", 1, true)
    if comma then
        local tail = raw_value:sub(comma + 1)
        if tail:sub(1, 1) ~= "{" then
            tail = tail:match("^%s*(.*)$")
        end
        options, encoded_options = cached_url_options(tail)
        if not options then return nil end
        clean_value = raw_value:sub(1, comma - 1)
    end
    -- The general resolver trims both sides of a URL. Keep that behavior for
    -- unusual whitespace-heavy hrefs; the fast path deliberately avoids a
    -- gsub on every ordinary TOC item.
    if clean_value:sub(1, 1):match("%s")
            or clean_value:sub(-1):match("%s") then
        return nil
    end

    local lowered_value_prefix = clean_value:sub(1, 8):lower()
    if lowered_value_prefix:match("^https?://")
            or clean_value:sub(1, 5):lower() == "data:" then
        return append_url_options(clean_value, options, encoded_options)
    end

    local scheme, origin = fast_base_parts(raw_base)
    local absolute
    if scheme and clean_value:sub(1, 2) == "//" then
        absolute = scheme .. ":" .. clean_value
    elseif origin and clean_value:sub(1, 1) == "/" then
        absolute = origin .. clean_value
    end
    if absolute then
        return append_url_options(absolute, options, encoded_options)
    end
    return nil
end

function Network.absolute(base_url, value)
    local fast = fast_absolute(base_url, value)
    if fast ~= nil then
        return fast
    end
    local clean_base = split_url_options(base_url or "")
    local clean_value, options, encoded_options = split_url_options(value)
    if clean_value == "" then
        return ""
    end

    -- TOC pages very commonly expose root-relative chapter links.  LuaSocket's
    -- RFC URL resolver is correct, but on the KPW4 it is expensive enough to
    -- dominate a 2,500-item TOC (several milliseconds per link).  Handle the
    -- unambiguous HTTP(S) cases directly and leave query/fragment/relative
    -- path resolution to the standard resolver below.
    local absolute
    local scheme = clean_base:match("^([%w][%w+.-]*):")
    local origin = clean_base:match("^([%w][%w+.-]*://[^/%?#]+)")
    if clean_value:lower():match("^https?://") then
        absolute = clean_value
    elseif scheme and clean_value:sub(1, 2) == "//" then
        absolute = scheme .. ":" .. clean_value
    elseif origin and clean_value:sub(1, 1) == "/" then
        absolute = origin .. clean_value
    end
    if absolute then
        return append_url_options(absolute, options, encoded_options)
    end
    if clean_value:lower():match("^data:") then
        return append_url_options(clean_value, options, encoded_options)
    end
    local ok, resolved = pcall(socket_url.absolute, clean_base or "", clean_value)
    if ok and resolved then
        return append_url_options(resolved, options, encoded_options)
    end
    return value
end

function Network.get(url, source, extra_options)
    local clean_url, url_options_value = split_url_options(url)
    local options = merge_options(url_options_value, decode_options(extra_options) or extra_options)
    local headers, header_err = headers_from_source(
        source,
        options and options.__legado_context
    )
    if not headers then
        return nil, header_err
    end
    local option_url, option_url_err = evaluate_url_option_js(clean_url, options)
    if not option_url then return nil, option_url_err end
    clean_url = option_url
    -- Keep the private evaluator reference until bodyJs has run. It is never
    -- copied into request headers or sent to the browser below.
    local follow_redirects = not (options and options.followRedirects == false)
    local retry_count = tonumber(options and options.retry) or 0
    retry_count = math.max(0, math.min(5, math.floor(retry_count)))
    local timeout = tonumber(options and options.timeout)
    -- Legado's timeout is milliseconds; LuaSocket expects seconds.
    local timeout_seconds = timeout and math.max(0.1, timeout / 1000)
        or DEFAULT_HTTP_TIMEOUT_SECONDS
    local browser_timeout = timeout and math.max(0.1, timeout / 1000) or nil
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

    -- Android Legado routes URLs marked with {"webView":true} through its
    -- background WebView.  On Kindle the browser bridge is the equivalent
    -- renderer; return its final DOM as the response body so the ordinary
    -- source rule pipeline remains unchanged.
    if options and (options.webView == true or tostring(options.webView):lower() == "true") then
        local Browser = require("legado/browser")
        local browser_headers, browser_header_err = Network.browser_headers(
            source,
            options and options.__legado_context
        )
        if not browser_headers then return nil, browser_header_err end
        local browser_result, browser_err = Browser.await(clean_url, {
            source = source,
            headers = browser_headers,
            cookies = Network.export_cookies(),
            html = options.html,
            script = options.webJs,
            -- URL options use milliseconds; Browser.await uses seconds.
            timeout = browser_timeout,
            delay = options.webViewDelayTime,
            auto = true,
            refetch_after_success = false,
        })
        if not browser_result then return nil, browser_err end
        if browser_result.cookies then Network.merge_cookies(browser_result.cookies) end
        local browser_body, browser_body_err = apply_body_js(browser_result.body, options)
        if browser_body == nil then return nil, browser_body_err end
        return browser_body, browser_result.headers, browser_result.code
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
        local decoded = decode_response(data, options and options.charset)
        local body, body_err = apply_body_js(decoded, options)
        if body == nil then return nil, body_err end
        return body, nil, 200
    end

    local redirect_count = 0
    local attempt = 0
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
        if options and options.proxy then
            local proxy = tostring(options.proxy)
            if proxy:lower():match("^socks[45]://") then
                return nil, "SOCKS proxy is not available in this KOReader build"
            end
            request.proxy = proxy
        end
        if options and options.origin and request_headers.Origin == nil
                and request_headers.origin == nil then
            request_headers.Origin = tostring(options.origin)
        end
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
        local previous_timeout = requester.TIMEOUT
        requester.TIMEOUT = timeout_seconds
        local ok, code, response_headers, status = requester.request(request)
        requester.TIMEOUT = previous_timeout
        local numeric_code = tonumber(code)
        if not ok then
            if attempt < retry_count then
                attempt = attempt + 1
            else
                return nil, "HTTP request failed: " .. tostring(code or status or "unknown error")
            end
        elseif numeric_code and numeric_code >= 500 and attempt < retry_count then
            attempt = attempt + 1
        elseif numeric_code and numeric_code >= 300 and numeric_code < 400
                and not follow_redirects then
            update_cookies(clean_url, response_headers)
            return response_body(chunks, response_headers, numeric_code, options)
        elseif numeric_code and numeric_code >= 300 and numeric_code < 400 then
            update_cookies(clean_url, response_headers)
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
            if not ok then
                -- A retryable transport error reaches the top of the loop.
            elseif numeric_code and (numeric_code < 200 or numeric_code >= 400) then
                update_cookies(clean_url, response_headers)
                if options and options.allowHttpError then
                    return response_body(chunks, response_headers, numeric_code, options)
                end
                return nil, "HTTP status " .. tostring(numeric_code)
            else
                update_cookies(clean_url, response_headers)
                return response_body(chunks, response_headers, numeric_code, options)
            end
        end
    end
end

-- Java's java.connect()/java.getStrResponse() expose a response object rather
-- than only its body. Keep the same request implementation and add the
-- object-shaped fields expected by login-check scripts.
function Network.get_response(url, source, extra_options)
    local options = shallow_copy(decode_options(extra_options) or extra_options)
    if options.followRedirects == nil then options.followRedirects = false end
    -- Jsoup's Connection.Response and Legado's StrResponse are inspectable
    -- even for HTTP 4xx/5xx responses. Keep the body and status available to
    -- login checks and redirect/signature scripts instead of turning them
    -- into an opaque Lua error.
    options.allowHttpError = true
    local started = os.clock()
    local body, headers, code = Network.get(url, source, options)
    local clean_url = split_url_options(url)
    if body == nil then
        local message = tostring(headers or "HTTP request failed")
        return {
            body = "",
            url = clean_url,
            code = tonumber(code) or -1,
            message = message,
            headers = headers or {},
            cookies = response_cookies(clean_url),
            callTime = math.floor((os.clock() - started) * 1000),
            errorBody = message,
        }
    end
    return {
        body = body,
        url = clean_url,
        code = tonumber(code) or 200,
        message = (tonumber(code) and tonumber(code) >= 400) and "HTTP error" or "OK",
        headers = headers or {},
        cookies = response_cookies(clean_url),
        callTime = math.floor((os.clock() - started) * 1000),
    }
end

return Network
