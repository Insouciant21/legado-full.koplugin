-- Generic bridge for Legado's java.startBrowserAwait().
--
-- Android Legado uses a WebView and returns the current document after the
-- user finishes a verification/configuration page.  KOReader has no embedded
-- WebView, but a jailbroken Kindle ships the same Chromium content shell used
-- by the Kindle browser.  Run that browser as a short-lived child, attach to
-- its DevTools protocol, and add a small source-independent "done" button.
-- The returned document/cookies then follow the normal Legado source action
-- path.  No source fields or endpoint names are known here.

local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local BrowserInput = require("legado/browser_input")
local _ = require("gettext")

local Browser = {}
local CLOUDFLARE_UNSUPPORTED_ERROR =
    _("Cloudflare verification is not supported on this Kindle browser; operation cancelled.")
Browser.CLOUDFLARE_UNSUPPORTED_ERROR = CLOUDFLARE_UNSUPPORTED_ERROR

local BROWSER_BINARY = "/usr/bin/chromium/bin/kindle_browser"
local BROWSER_LIBRARY_PATH = "/usr/bin/chromium/lib:/usr/bin/chromium/usr/lib:/usr/lib"
local MAX_URL_BYTES = 256 * 1024
local MAX_HTML_BYTES = 12 * 1024 * 1024
local DEFAULT_TIMEOUT = 5 * 60
local HTTP_TIMEOUT = 3
local BROWSER_WINDOW_NAME =
    "L:A_N:application_AKB:true_ASR:true_ID:com.lab126.browser_A:browser_WS:true_WT:true_PC:T"

-- A Kindle's Awesome window manager only puts clients whose WM_NAME follows
-- Amazon's L:... convention into the foreground.  The Chromium content shell
-- does not set that name, so an otherwise healthy browser is left underneath
-- KOReader/KPP.  Keep this bridge optional so the non-Kindle test environment
-- can still load the module.
local x11
local x11_ffi
do
    local ffi_ok, ffi = pcall(require, "ffi")
    if ffi_ok then
        pcall(ffi.cdef, [[
            typedef unsigned long legado_XID;
            typedef legado_XID legado_Window;
            typedef struct _XDisplay legado_Display;
            typedef unsigned long legado_Atom;
            legado_Display *XOpenDisplay(const char *display_name);
            int XCloseDisplay(legado_Display *display);
            int XStoreName(legado_Display *display, legado_Window window,
                const char *window_name);
            legado_Atom XInternAtom(legado_Display *display, const char *atom_name,
                int only_if_exists);
            int XChangeProperty(legado_Display *display, legado_Window window,
                legado_Atom property, legado_Atom type, int format, int mode,
                const unsigned char *data, int nelements);
            int XMapWindow(legado_Display *display, legado_Window window);
            int XUnmapWindow(legado_Display *display, legado_Window window);
            int XMoveWindow(legado_Display *display, legado_Window window,
                int x, int y);
            int XLowerWindow(legado_Display *display, legado_Window window);
            int XMapRaised(legado_Display *display, legado_Window window);
            int XRaiseWindow(legado_Display *display, legado_Window window);
            int XSync(legado_Display *display, int discard);
        ]])
        local library_ok, library = pcall(ffi.load, "X11")
        if library_ok then
            x11 = library
            x11_ffi = ffi
        end
    end
end

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function now()
    if type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

local function browser_process_alive(pid)
    pid = tonumber(pid)
    if not pid then return false end
    local status_file = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
    if not status_file then return false end
    status_file:close()
    return true
end

local function find_browser_window()
    local handle = io.popen(
        "DISPLAY=:0 /usr/bin/xwininfo -root -tree 2>/dev/null", "r"
    )
    if not handle then return nil end
    local window
    for line in handle:lines() do
        if line:find("chromium%-kindle_browser", 1, false) then
            local value = line:match("^%s+(0x[%da-fA-F]+)")
            if value then
                window = tonumber(value:sub(3), 16)
                break
            end
        end
    end
    handle:close()
    return window
end

-- Automatic source requests use Chromium only as a DOM renderer. Ask X11 to
-- keep its client below the reader and move it off the Kindle screen. An old
-- Kindle content-shell build tears down the DevTools session when its window
-- is unmapped, so it must remain mapped while the DOM is being rendered.
local function hide_browser_window()
    if not x11 or not x11_ffi then return false end
    local window = find_browser_window()
    if not window then return false end
    local display = x11.XOpenDisplay(":0")
    if display == nil then return false end
    local moved = x11.XMoveWindow(display, window, -1200, -1500) ~= 0
    local lowered = x11.XLowerWindow(display, window) ~= 0
    x11.XSync(display, 0)
    x11.XCloseDisplay(display)
    return moved or lowered
end

local function find_kpp_cover_windows()
    local handle = io.popen(
        "DISPLAY=:0 /usr/bin/xwininfo -root -tree 2>/dev/null", "r"
    )
    if not handle then return {} end
    local windows = {}
    for line in handle:lines() do
        -- When Awesome is resumed on a jailbroken Kindle, KPPMainApp can
        -- remap a full-screen client above the Chromium content shell.  The
        -- top/bottom chrome also belongs to KPPMainApp, so only consider a
        -- large, currently viewable application window here.
        if line:find("ID:com.lab126.KPPMainApp", 1, true)
                and line:find("MapState=IsViewable", 1, true) then
            local width, height = line:match(
                "%s(%d+)x(%d+)%+%-?%d+%+%-?%d+"
            )
            local value = line:match("^%s+(0x[%da-fA-F]+)")
            if value and tonumber(width) and tonumber(height)
                    and tonumber(width) >= 800 and tonumber(height) >= 800 then
                windows[#windows + 1] = tonumber(value:sub(3), 16)
            end
        end
    end
    handle:close()
    return windows
end

local function hide_kpp_cover_windows(hidden_windows)
    if not x11 or not x11_ffi or type(hidden_windows) ~= "table" then
        return
    end
    local already_hidden = {}
    for _, window in ipairs(hidden_windows) do
        already_hidden[window] = true
    end
    local candidates = find_kpp_cover_windows()
    if #candidates == 0 then return end
    local display = x11.XOpenDisplay(":0")
    if display == nil then return end
    for _, window in ipairs(candidates) do
        if not already_hidden[window] then
            if x11.XUnmapWindow(display, window) ~= 0 then
                hidden_windows[#hidden_windows + 1] = window
                already_hidden[window] = true
            end
        end
    end
    x11.XSync(display, 0)
    x11.XCloseDisplay(display)
end

local function restore_kpp_cover_windows(hidden_windows)
    if not x11 or not x11_ffi or type(hidden_windows) ~= "table"
            or #hidden_windows == 0 then
        return
    end
    local display = x11.XOpenDisplay(":0")
    if display == nil then return end
    for _, window in ipairs(hidden_windows) do
        x11.XMapWindow(display, window)
    end
    x11.XSync(display, 0)
    x11.XCloseDisplay(display)
end

local function promote_browser_window(deadline, hidden_windows)
    if not x11 or not x11_ffi then return false end
    while now() < deadline do
        hide_kpp_cover_windows(hidden_windows)
        local window = find_browser_window()
        if window then
            local display = x11.XOpenDisplay(":0")
            if display == nil then return false end
            local name = BROWSER_WINDOW_NAME
            local utf8 = x11.XInternAtom(display, "UTF8_STRING", 0)
            local net_name = x11.XInternAtom(display, "_NET_WM_NAME", 0)
            local buffer = x11_ffi.new("unsigned char[?]", #name)
            x11_ffi.copy(buffer, name, #name)
            -- Set both legacy WM_NAME and EWMH _NET_WM_NAME: Kindle builds
            -- differ in which one Awesome exposes as client.name.
            x11.XStoreName(display, window, name)
            if utf8 ~= 0 and net_name ~= 0 then
                x11.XChangeProperty(display, window, net_name, utf8, 8, 0,
                    buffer, #name)
            end
            x11.XMapRaised(display, window)
            x11.XRaiseWindow(display, window)
            x11.XSync(display, 0)
            x11.XCloseDisplay(display)
            return true
        end
        socket.sleep(0.1)
    end
    return false
end

local function browser_window_geometry()
    local window = find_browser_window()
    if not window then return nil end
    local handle = io.popen(
        "DISPLAY=:0 /usr/bin/xwininfo -id " .. string.format("0x%x", window)
            .. " 2>/dev/null", "r"
    )
    if not handle then return nil end
    local geometry = {}
    for line in handle:lines() do
        local x = line:match("Absolute upper%-left X:%s*(-?%d+)")
        local y = line:match("Absolute upper%-left Y:%s*(-?%d+)")
        if x then geometry.x = tonumber(x) end
        if y then geometry.y = tonumber(y) end
    end
    handle:close()
    if geometry.x == nil or geometry.y == nil then return nil end
    return geometry
end

local function awesome_was_stopped()
    local handle = io.popen("pidof awesome 2>/dev/null", "r")
    if not handle then return false end
    local pids = handle:read("*a") or ""
    handle:close()
    for pid in pids:gmatch("%d+") do
        local status_file = io.open("/proc/" .. pid .. "/status", "r")
        if status_file then
            local status = status_file:read("*a") or ""
            status_file:close()
            local state = status:match("\nState:%s+([A-Z])")
            if state == "T" then return true end
        end
    end
    return false
end

local function continue_awesome()
    os.execute("killall -CONT awesome >/dev/null 2>&1")
end

local function stop_awesome()
    os.execute("killall -STOP awesome >/dev/null 2>&1")
end

local function random_bytes(count)
    local output = {}
    for index = 1, count do
        output[index] = string.char(math.random(0, 255))
    end
    return table.concat(output)
end

local function encode_base64(value)
    local output = {}
    for index = 1, #value, 3 do
        local first = value:byte(index) or 0
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local number = first * 65536 + (second or 0) * 256 + (third or 0)
        output[#output + 1] = base64_alphabet:sub(math.floor(number / 262144) % 64 + 1,
            math.floor(number / 262144) % 64 + 1)
        output[#output + 1] = base64_alphabet:sub(math.floor(number / 4096) % 64 + 1,
            math.floor(number / 4096) % 64 + 1)
        output[#output + 1] = second
            and base64_alphabet:sub(math.floor(number / 64) % 64 + 1,
                math.floor(number / 64) % 64 + 1) or "="
        output[#output + 1] = third
            and base64_alphabet:sub(number % 64 + 1, number % 64 + 1) or "="
    end
    return table.concat(output)
end

-- A WebView caller must not receive Cloudflare's interstitial as if it were
-- the requested page. The challenge is asynchronous: document.readyState can
-- become `complete` before Turnstile has finished and before the clearance
-- cookie is issued. Keep the test deliberately structural and ES5-only so it
-- also runs in the old Kindle content shell. It is not tied to a source,
-- domain, challenge token or endpoint.
local CLOUDFLARE_CHALLENGE_PAGE = [=[
(function() {
  try {
    var title = String(document.title || '').toLowerCase();
    var text = String(document.body && document.body.innerText || '').toLowerCase().slice(0, 4096);
    var cookie = String(document.cookie || '').toLowerCase();
    var successful = text.indexOf('verification successful') >= 0;
    if (successful || cookie.indexOf('cf_clearance=') >= 0) return false;
    if (title.indexOf('just a moment') >= 0) return true;
    if (text.indexOf('performing security verification') >= 0 ||
        text.indexOf('checking your browser') >= 0 ||
        text.indexOf('ddos protection') >= 0 ||
        text.indexOf('enable javascript and cookies') >= 0) return true;
    if (document.querySelector) {
      if (document.querySelector('script[src*="/cdn-cgi/challenge-platform/"]') ||
          document.querySelector('iframe[src*="challenges.cloudflare.com"]') ||
          document.querySelector('input[name="cf-turnstile-response"]') ||
          document.querySelector('[id^="cf-chl-"]')) return true;
    }
  } catch (error) {}
  return false;
})()
]=]

local function cloudflare_challenge_page(client)
    local value, err = client:evaluate(CLOUDFLARE_CHALLENGE_PAGE)
    if err then return nil, err end
    return value == true
end

local function is_cloudflare_challenge_html(body)
    if type(body) ~= "string" or body == "" then return false end
    -- The challenge markers are in the document head. Limit the copy before
    -- lower-casing so a large ordinary article does not create another large
    -- transient Lua string.
    local sample = body:sub(1, 512 * 1024):lower()
    if not sample:find("<title>just a moment", 1, true) then
        return false
    end
    return sample:find("/cdn%-cgi/challenge%-platform/", 1, false) ~= nil
        or sample:find("cf%-turnstile", 1, false) ~= nil
end

local function pack_u16(value)
    local high = math.floor(value / 256) % 256
    local low = value % 256
    return string.char(high, low)
end

local function pack_u64(value)
    local bytes = {}
    for index = 8, 1, -1 do
        bytes[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(bytes)
end

local function receive_exact(client, length)
    local chunks = {}
    local received = 0
    while received < length do
        local chunk, receive_err, partial = client:receive(length - received)
        chunk = chunk or partial
        if not chunk or #chunk == 0 then
            return nil, receive_err or "browser connection closed"
        end
        chunks[#chunks + 1] = chunk
        received = received + #chunk
    end
    return table.concat(chunks)
end

local function websocket_send(client, opcode, payload)
    payload = tostring(payload or "")
    local length = #payload
    local header
    if length < 126 then
        header = string.char(0x80 + opcode, 0x80 + length)
    elseif length < 65536 then
        header = string.char(0x80 + opcode, 0x80 + 126) .. pack_u16(length)
    else
        header = string.char(0x80 + opcode, 0x80 + 127) .. pack_u64(length)
    end
    local mask = random_bytes(4)
    local masked = {}
    for index = 1, length do
        local mask_byte = mask:byte((index - 1) % 4 + 1)
        -- XOR without depending on LuaJIT bit libraries.
        local left = payload:byte(index)
        local right = mask_byte
        local xor_value = 0
        local bit_value = 1
        for _ = 1, 8 do
            if (left % 2) ~= (right % 2) then xor_value = xor_value + bit_value end
            left = math.floor(left / 2)
            right = math.floor(right / 2)
            bit_value = bit_value * 2
        end
        masked[index] = string.char(xor_value)
    end
    local sent, send_err = client:send(header .. mask .. table.concat(masked))
    if not sent then
        return nil, send_err or "cannot send browser command"
    end
    return true
end

local function websocket_receive(client)
    local header, header_err = receive_exact(client, 2)
    if not header then return nil, header_err end
    local first = header:byte(1)
    local second = header:byte(2)
    local opcode = first % 16
    local length = second % 128
    if length == 126 then
        local extended, extended_err = receive_exact(client, 2)
        if not extended then return nil, extended_err end
        length = extended:byte(1) * 256 + extended:byte(2)
    elseif length == 127 then
        local extended, extended_err = receive_exact(client, 8)
        if not extended then return nil, extended_err end
        length = 0
        for index = 1, 8 do
            length = length * 256 + extended:byte(index)
            if length > MAX_HTML_BYTES * 2 then
                return nil, "browser message is too large"
            end
        end
    end
    local mask
    if second >= 128 then
        mask, header_err = receive_exact(client, 4)
        if not mask then return nil, header_err end
    end
    local payload, payload_err = receive_exact(client, length)
    if not payload then return nil, payload_err end
    if mask then
        local unmasked = {}
        for index = 1, #payload do
            local left = payload:byte(index)
            local right = mask:byte((index - 1) % 4 + 1)
            local xor_value = 0
            local bit_value = 1
            for _ = 1, 8 do
                if (left % 2) ~= (right % 2) then xor_value = xor_value + bit_value end
                left = math.floor(left / 2)
                right = math.floor(right / 2)
                bit_value = bit_value * 2
            end
            unmasked[index] = string.char(xor_value)
        end
        payload = table.concat(unmasked)
    end
    return opcode, payload, first >= 128
end

local Client = {}
Client.__index = Client

function Client:new(client)
    return setmetatable({
        socket = client,
        next_id = 0,
        fragments = nil,
        events = {},
        resources = {},
        resource_seen = {},
        cloudflare_challenge_seen = false,
        responses = {},
    }, self)
end

function Client:close()
    if not self.socket then return end
    pcall(websocket_send, self.socket, 8, "")
    pcall(self.socket.close, self.socket)
    self.socket = nil
end

function Client:receive_message()
    while true do
        local opcode, payload, final = websocket_receive(self.socket)
        if not opcode then return nil, payload end
        if opcode == 8 then return nil, "browser websocket closed" end
        if opcode == 9 then
            local ok, err = websocket_send(self.socket, 10, payload)
            if not ok then return nil, err end
        elseif opcode == 1 and final then
            return payload
        elseif opcode == 1 then
            self.fragments = { payload }
        elseif opcode == 0 and self.fragments then
            self.fragments[#self.fragments + 1] = payload
            if final then
                local result = table.concat(self.fragments)
                self.fragments = nil
                return result
            end
        elseif opcode == 10 then
            -- Pong frames do not carry a CDP message.
        elseif opcode == 2 then
            return payload
        end
    end
end

function Client:call(method, params)
    self.next_id = self.next_id + 1
    local id = self.next_id
    local encoded_ok, encoded = pcall(rapidjson.encode, {
        id = id,
        method = method,
        params = params or {},
    })
    if not encoded_ok then
        return nil, "cannot encode browser command: " .. tostring(encoded)
    end
    local sent, send_err = websocket_send(self.socket, 1, encoded)
    if not sent then return nil, send_err end
    local queued = self.responses[id]
    if queued then
        self.responses[id] = nil
    end
    while true do
        local decoded = queued
        local decoded_ok = true
        queued = nil
        if not decoded then
            decoded = self.responses[id]
            if decoded then self.responses[id] = nil end
        end
        if not decoded then
            local message, receive_err = self:receive_message()
            if not message then return nil, receive_err end
            decoded_ok, decoded = pcall(rapidjson.decode, message)
            if not decoded_ok then decoded = nil end
        end
        if decoded_ok and type(decoded) == "table" and tonumber(decoded.id) == id then
            if decoded.error then
                local detail = type(decoded.error) == "table"
                    and (decoded.error.message or decoded.error.code) or decoded.error
                local error_message = "browser command " .. tostring(method) .. ": " .. tostring(detail)
                return nil, error_message
            end
            return decoded.result or {}
        elseif type(decoded) == "table" and tonumber(decoded.id) then
            -- CDP responses can arrive out of order while a command is
            -- waiting for its own result. Retain unrelated responses instead
            -- of losing them and hanging the next command forever.
            self.responses[tonumber(decoded.id)] = decoded
        elseif type(decoded) == "table" and decoded.method then
            -- DevTools events arrive while a synchronous command is waiting
            -- for its response. Keep them: sourceRegex is implemented using
            -- the same Network.* resource notifications as Legado's Android
            -- WebView, rather than guessing from the final document HTML.
            self:record_event(decoded)
        end
    end
end

function Client:record_event(event)
    if type(event) ~= "table" then return end
    self.events[#self.events + 1] = event
    local method = tostring(event.method or "")
    local params = event.params or {}
    local url
    if method == "Network.requestWillBeSent" then
        url = params.request and params.request.url
    elseif method == "Network.responseReceived" then
        url = params.response and params.response.url
    elseif method == "Page.frameNavigated" then
        url = params.frame and params.frame.url
    end
    if type(url) == "string" then
        local lowered_url = url:lower()
        if lowered_url:find(
                "/cdn%-cgi/challenge%-platform/", 1, false
            ) ~= nil or lowered_url:find("/turnstile/v0/", 1, true) ~= nil then
            self.cloudflare_challenge_seen = true
        end
    end
    if method == "Network.responseReceived" then
        local response = type(params.response) == "table"
            and params.response or {}
        local headers = response.headers
        if type(headers) == "table" then
            for name, value in pairs(headers) do
                if tostring(name):lower() == "cf-mitigated"
                        and tostring(value):lower() == "challenge" then
                    self.cloudflare_challenge_seen = true
                    break
                end
            end
        end
    end
    if type(url) == "string" and url ~= "" and not self.resource_seen[url] then
        self.resource_seen[url] = true
        self.resources[#self.resources + 1] = url
    end
end

function Client:evaluate(expression)
    local result, err = self:call("Runtime.evaluate", {
        expression = expression,
        returnByValue = true,
        awaitPromise = false,
    })
    if not result then return nil, err end
    local remote = result.result
    if type(remote) ~= "table" then return nil, "browser evaluation returned no value" end
    if remote.exceptionDetails then
        return nil, "browser page evaluation failed"
    end
    return remote.value
end

function Client:matches_regex(value, pattern)
    pattern = tostring(pattern or "")
    if pattern == "" then return nil end
    local pattern_json = rapidjson.encode(pattern)
    local value_json = rapidjson.encode(tostring(value or ""))
    return self:evaluate(
        "(new RegExp(" .. pattern_json .. ")).test(" .. value_json .. ")"
    )
end

function Client:matching_resource(pattern)
    for _, url in ipairs(self.resources) do
        local matched, err = self:matches_regex(url, pattern)
        if err then return nil, err end
        if matched == true then return url end
    end
    return nil
end

local function browser_http_get(port, path, timeout)
    local chunks = {}
    local previous_timeout = http.TIMEOUT
    http.TIMEOUT = tonumber(timeout) or HTTP_TIMEOUT
    local request_ok, code, _, request_err = http.request{
        url = "http://127.0.0.1:" .. tostring(port) .. tostring(path),
        method = "GET",
        sink = ltn12.sink.table(chunks),
    }
    http.TIMEOUT = previous_timeout
    if not request_ok then
        return nil, tostring(request_err or code or "browser DevTools request failed")
    end
    if tonumber(code) ~= 200 then
        return nil, "browser DevTools returned HTTP " .. tostring(code)
    end
    return table.concat(chunks)
end

local function choose_port()
    for _ = 1, 24 do
        local candidate = math.random(19000, 29000)
        local listener = socket.bind("127.0.0.1", candidate)
        if listener then
            listener:close()
            return candidate
        end
    end
    return nil, "no free local browser port"
end

local function wait_for_page(port, deadline, on_wait, poll_timeout)
    while now() < deadline do
        if type(on_wait) == "function" then
            pcall(on_wait)
        end
        local body = browser_http_get(port, "/json", poll_timeout)
        if body then
            local decoded_ok, pages = pcall(rapidjson.decode, body)
            if decoded_ok and type(pages) == "table" then
                for _, page in ipairs(pages) do
                    if type(page) == "table"
                            and page.type == "page"
                            and type(page.webSocketDebuggerUrl) == "string" then
                        return page
                    end
                end
            end
        end
        socket.sleep(0.25)
    end
    return nil, "Kindle browser did not expose a page"
end

local function connect_devtools(page, port)
    local path = tostring(page.webSocketDebuggerUrl):match("^ws://[^/]+(/.*)$")
    if not path then return nil, "invalid Kindle browser DevTools URL" end
    local client, connect_err = socket.tcp()
    if not client then return nil, connect_err end
    client:settimeout(8)
    local connected, err = client:connect("127.0.0.1", port)
    if not connected then
        client:close()
        return nil, err or "cannot connect to Kindle browser DevTools"
    end
    local key = encode_base64(random_bytes(16))
    local request = table.concat({
        "GET ", path, " HTTP/1.1\r\n",
        "Host: 127.0.0.1:", tostring(port), "\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: ", key, "\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "\r\n",
    })
    local sent, send_err = client:send(request)
    if not sent then
        client:close()
        return nil, send_err or "cannot start browser DevTools session"
    end
    local response = ""
    while not response:find("\r\n\r\n", 1, true) do
        local line, line_err, partial = client:receive("*l")
        line = line or partial
        if not line then
            client:close()
            return nil, line_err or "browser DevTools handshake failed"
        end
        response = response .. line .. "\r\n"
        if #response > 8192 then
            client:close()
            return nil, "browser DevTools handshake is too large"
        end
    end
    if not response:find(" 101 ", 1, true) then
        client:close()
        return nil, "browser DevTools rejected the WebSocket connection"
    end
    client:settimeout(8)
    return Client:new(client)
end

local function launch(url, port, user_dir, log_path, background)
    local arguments = {
        "DISPLAY=:0",
        "LD_LIBRARY_PATH=" .. shell_quote(BROWSER_LIBRARY_PATH),
        shell_quote(BROWSER_BINARY),
        "--no-zygote",
        "--no-sandbox",
        "--single-process",
        "--disable-gpu",
        "--in-process-gpu",
        "--disable-gpu-sandbox",
        "--disable-gpu-compositing",
        "--no-first-run",
        "--disable-background-networking",
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=" .. tostring(port),
        "--user-data-dir=" .. shell_quote(user_dir),
        "--content-shell-hide-toolbar",
        "--content-shell-host-window-cord="
            .. (background and "-1200,-1500" or "0,215"),
        "--force-device-scale-factor=2",
        "--force-gpu-mem-available-mb=40",
        "--enable-low-end-device-mode",
        "--enable-low-res-tiling",
        "--enable-grayscale-mode",
        "--enable-features=NetworkService",
        "--js-flags=jitless",
        "--user-agent=" .. shell_quote(
            -- This is the UA embedded in the KPW4 content shell.  Keeping it
            -- consistent with navigator.userAgent and the engine's actual
            -- feature set gives Cloudflare/Turnstile a coherent browser
            -- fingerprint; the previous Safari 5 override was rejected as
            -- an unsupported legacy client.
            "Mozilla/5.0 (Linux; Android 9; Nexus 5 Build/MRA58N) "
            .. "AppleWebKit/537.36 (KHTML, like Gecko) "
            .. "Chrome/80.0.3987.149 Mobile Safari/537.36"
        ),
    }
    if background then
        -- Some Kindle Chromium builds ignore the minimized hint. The X11
        -- lowering pass below is still required after a navigation.
        arguments[#arguments + 1] = "--start-minimized"
    end
    arguments[#arguments + 1] = shell_quote(url)
    arguments[#arguments + 1] = ">"
    arguments[#arguments + 1] = shell_quote(log_path)
    arguments[#arguments + 1] =
        "2>&1 & echo $!"
    local command = table.concat(arguments, " ")
    local handle, open_err = io.popen(command, "r")
    if not handle then return nil, open_err or "cannot launch Kindle browser" end
    local pid = tonumber(trim(handle:read("*l") or ""))
    handle:close()
    if not pid then return nil, "Kindle browser did not start" end
    return pid
end

local function kill_process(pid)
    if not tonumber(pid) then return end
    os.execute("kill -TERM " .. tostring(tonumber(pid)) .. " >/dev/null 2>&1")
    socket.sleep(0.35)
    os.execute("kill -KILL " .. tostring(tonumber(pid)) .. " >/dev/null 2>&1")
end

local function remove_profile(path)
    -- The path is generated by this module under /var/tmp and is never
    -- accepted from a source or user. Keep the Kindle's browser storage
    -- bounded after a settings/verification session.
    if tostring(path):match("^/var/tmp/legado%-browser%-%d+%-%d+$") then
        os.execute("rm -rf " .. shell_quote(path) .. " >/dev/null 2>&1")
    end
end

local function set_browser_cookies(client, snapshot, url)
    if type(snapshot) ~= "table" then return end
    local scheme = tostring(url or ""):match("^(https?)://")
    local schemes = scheme and { scheme } or { "https", "http" }
    for host, cookies in pairs(snapshot) do
        if type(host) == "string" and type(cookies) == "table" then
            local clean_host = host:gsub("^%.", "")
            if clean_host ~= "" then
                for name, value in pairs(cookies) do
                    if type(name) == "string"
                            and (type(value) == "string" or type(value) == "number") then
                        for _, cookie_scheme in ipairs(schemes) do
                            client:call("Network.setCookie", {
                                name = name,
                                value = tostring(value),
                                url = cookie_scheme .. "://" .. clean_host .. "/",
                            })
                        end
                    end
                end
            end
        end
    end
end

local function browser_cookie_snapshot(client)
    local result, err = client:call("Network.getAllCookies", {})
    if not result then return nil, err end
    local snapshot = {}
    for _, cookie in ipairs(result.cookies or {}) do
        if type(cookie) == "table" then
            local host = tostring(cookie.domain or ""):gsub("^%.", "")
            local name = tostring(cookie.name or "")
            if host ~= "" and name ~= "" then
                snapshot[host] = snapshot[host] or {}
                snapshot[host][name] = tostring(cookie.value or "")
            end
        end
    end
    return snapshot
end

local function browser_input_scale(client)
    local scale = client:evaluate("Number(window.devicePixelRatio || 1)")
    scale = tonumber(scale)
    if not scale or scale <= 0 then
        return 1
    end
    return scale
end

local function browser_input_point(client, x, y)
    x = tonumber(x)
    y = tonumber(y)
    if not x or not y then return nil end
    local geometry = browser_window_geometry()
    if not geometry then
        -- KPW4's browser content shell is positioned below the 101-pixel
        -- native browser chrome.  This fallback is only used while X11 is
        -- between mapping and reporting the window geometry.
        geometry = { x = 0, y = 101 }
    end
    local scale = browser_input_scale(client)
    return (x - geometry.x) / scale, (y - geometry.y) / scale
end

local function dispatch_touch_point(client, event_type, x, y)
    client:call("Input.dispatchTouchEvent", {
        type = event_type,
        touchPoints = event_type == "touchEnd" and {} or {
            {
                id = 1,
                x = x,
                y = y,
                radiusX = 1,
                radiusY = 1,
                force = 1,
            },
        },
    })
end

local function dispatch_mouse_click(client, event)
    local x, y = browser_input_point(client, event.x, event.y)
    if not x or not y then return end
    local common = {
        x = x,
        y = y,
        button = "left",
        clickCount = 1,
    }
    client:call("Input.dispatchMouseEvent", {
        type = "mouseMoved",
        x = x,
        y = y,
    })
    client:call("Input.dispatchMouseEvent", {
        type = "mousePressed",
        x = common.x,
        y = common.y,
        button = common.button,
        clickCount = common.clickCount,
    })
    socket.sleep(0.03)
    client:call("Input.dispatchMouseEvent", {
        type = "mouseReleased",
        x = common.x,
        y = common.y,
        button = common.button,
        clickCount = common.clickCount,
    })
end

local function dispatch_mouse_wheel(client, x, y, delta_x, delta_y)
    if not x or not y then return end
    if math.abs(delta_x or 0) < 0.01 and math.abs(delta_y or 0) < 0.01 then
        return
    end
    -- A wheel event is an incremental scroll operation.  Unlike a synthetic
    -- touch sequence it has no pointer-down state that Chromium can carry
    -- into the next Kindle gesture, which is important on the KPW4 content
    -- shell where repeated touch drags may be interpreted from scroll origin.
    client:call("Input.dispatchMouseEvent", {
        type = "mouseMoved",
        x = x,
        y = y,
    })
    client:call("Input.dispatchMouseEvent", {
        type = "mouseWheel",
        x = x,
        y = y,
        deltaX = delta_x or 0,
        deltaY = delta_y or 0,
    })
    socket.sleep(0.01)
end

local function dispatch_touch_swipe(client, event)
    local start_x, start_y = browser_input_point(
        client, event.start_x or event.x, event.start_y or event.y
    )
    local end_x, end_y = browser_input_point(
        client, event.end_x or event.x, event.end_y or event.y
    )
    if not start_x or not start_y or not end_x or not end_y then return end
    dispatch_touch_point(client, "touchStart", start_x, start_y)
    for index = 1, 4 do
        local fraction = index / 4
        dispatch_touch_point(
            client,
            "touchMove",
            start_x + (end_x - start_x) * fraction,
            start_y + (end_y - start_y) * fraction
        )
        socket.sleep(0.03)
    end
    dispatch_touch_point(client, "touchEnd")
end

local function dispatch_scroll_swipe(client, event)
    local start_x, start_y = browser_input_point(
        client, event.start_x or event.x, event.start_y or event.y
    )
    local end_x, end_y = browser_input_point(
        client, event.end_x or event.x, event.end_y or event.y
    )
    if not start_x or not start_y or not end_x or not end_y then return end
    local delta_x = start_x - end_x
    local delta_y = start_y - end_y
    -- Keep horizontal swipes as real touch gestures for carousels and other
    -- source pages that intentionally listen for touch events. Vertical
    -- swipes, which are the normal reading-page scroll operation, use an
    -- incremental wheel event so every gesture starts at the current offset.
    if math.abs(delta_y) >= math.abs(delta_x) then
        dispatch_mouse_wheel(client, start_x, start_y, delta_x, delta_y)
    else
        dispatch_touch_swipe(client, event)
    end
end

local function dispatch_scroll_pan(client, event, pan_position)
    local x, y = browser_input_point(client, event.x, event.y)
    if not x or not y then return pan_position end
    if not pan_position then
        local start_x, start_y = browser_input_point(
            client, event.start_x or event.x, event.start_y or event.y
        )
        if not start_x or not start_y then return pan_position end
        pan_position = { x = start_x, y = start_y }
    end
    dispatch_mouse_wheel(
        client,
        x,
        y,
        pan_position.x - x,
        pan_position.y - y
    )
    pan_position.x = x
    pan_position.y = y
    return pan_position
end

local function dispatch_scroll_pan_release(client, event, pan_position)
    if not pan_position then return nil end
    local x, y = browser_input_point(client, event.x, event.y)
    if x and y then
        dispatch_mouse_wheel(
            client,
            x,
            y,
            pan_position.x - x,
            pan_position.y - y
        )
    end
    return nil
end

local function forward_browser_inputs(client, token, pan_position)
    for _, event in ipairs(BrowserInput.receive(token)) do
        local kind = tostring(event.kind or "")
        if kind == "pan" then
            pan_position = dispatch_scroll_pan(client, event, pan_position)
        elseif kind == "pan_release" then
            pan_position = dispatch_scroll_pan_release(client, event, pan_position)
        elseif kind == "swipe" then
            pan_position = nil
            dispatch_scroll_swipe(client, event)
        elseif kind == "tap" or kind == "hold" or kind == "hold_release"
                or kind == "gesture" then
            pan_position = nil
            dispatch_mouse_click(client, event)
        end
    end
    return pan_position
end

local function add_done_button(client)
    return client:evaluate([[
(function() {
  try {
    if (!document || !document.documentElement) return false;
    window.__legado_browser_done = false;
    if (document.getElementById("__legado_kindle_done")) return true;
    var button = document.createElement("button");
    button.id = "__legado_kindle_done";
    button.type = "button";
    button.textContent = "完成并返回 Kindle";
    button.setAttribute("aria-label", "完成并返回 Kindle");
    button.style.cssText =
      "position:fixed;z-index:2147483647;top:8px;right:8px;" +
      "min-width:170px;height:48px;padding:4px 10px;" +
      "background:#fff;color:#000;border:2px solid #000;border-radius:4px;" +
      "font: bold 16px sans-serif;opacity:.94;";
    button.addEventListener("click", function(event) {
      event.preventDefault();
      event.stopPropagation();
      window.__legado_browser_done = true;
    }, true);
    // A number of source-provided settings pages use window.close() as their
    // own completion signal. Chromium may refuse to close a top-level page
    // that it did not open, so translate that ordinary browser action into
    // the same result signal used by the generic Kindle button.
    window.close = function() {
      window.__legado_browser_done = true;
    };
    (document.body || document.documentElement).appendChild(button);
    return true;
  } catch (error) {
    return false;
  }
})()
]])
end

local function document_result(client)
    -- The completion affordance is host UI, not source content. Remove it
    -- before returning outerHTML so source JavaScript sees the same document
    -- shape it would receive from Legado's WebView.
    client:evaluate([[
(function() {
  var button = document.getElementById("__legado_kindle_done");
  if (button && button.parentNode) button.parentNode.removeChild(button);
  return true;
})()
]])
    local body, body_err = client:evaluate(
        "document.documentElement ? document.documentElement.outerHTML : ''"
    )
    if type(body) ~= "string" then
        return nil, body_err or "browser returned no document"
    end
    if #body == 0 then return nil, "browser returned an empty document" end
    if #body > MAX_HTML_BYTES then return nil, "browser document is too large" end
    local url = client:evaluate("String(location.href || '')") or ""
    local cookies, cookie_err = browser_cookie_snapshot(client)
    if not cookies then return nil, cookie_err end
    return {
        body = body,
        url = tostring(url),
        cookies = cookies,
        code = 200,
        headers = {},
    }
end

function Browser.await(url, options)
    options = options or {}
    url = tostring(url or "")
    if url == "" then return nil, "browser URL is empty" end
    if #url > MAX_URL_BYTES then return nil, "browser URL is too large" end
    local binary_file = io.open(BROWSER_BINARY, "rb")
    if not binary_file then
        return nil, "Kindle browser is unavailable at " .. BROWSER_BINARY
    end
    binary_file:close()

    local automatic = options.auto == true
        or tostring(options.auto):lower() == "true"
    local background = options.background == true
        or (options.background == nil and automatic)

    math.randomseed(os.time() + math.floor(now() * 1000) % 100000 + #url)
    local port, port_err = choose_port()
    if not port then return nil, port_err end
    local token = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local user_dir = "/var/tmp/legado-browser-" .. token
    local log_path = user_dir .. ".log"
    local input_started = false
    if not background then
        local input_err
        input_started, input_err = BrowserInput.begin(token)
        if not input_started then
            return nil, input_err or "cannot start browser input bridge"
        end
    end
    -- KOReader's Kindle launcher pauses Awesome while it owns the framebuffer.
    -- Interactive browser actions need the window manager and input bridge;
    -- automatic DOM requests do not, and must not take the reader out of the
    -- foreground.
    local restore_awesome = not background and awesome_was_stopped()
    if restore_awesome then
        continue_awesome()
        -- Give Awesome one scheduling turn before Chromium creates its X
        -- client; this avoids a race on KPW4 after a source action starts.
        socket.sleep(0.25)
    end
    -- Start on a blank document so the source's existing cookies are installed
    -- before the first request to its page. This matters for login/settings
    -- pages that redirect based on an existing session.
    local pid, launch_err = launch("about:blank", port, user_dir, log_path, background)
    if not pid then
        if input_started then BrowserInput.finish(token) end
        if restore_awesome then stop_awesome() end
        return nil, launch_err
    end

    local client
    local hidden_kpp_windows = {}
    local awesome_restored = false
    local function restore_window_manager()
        if restore_awesome and not awesome_restored then
            stop_awesome()
            awesome_restored = true
        end
    end
    local function finish(result, err)
        if client then client:close() end
        kill_process(pid)
        if input_started then BrowserInput.finish(token) end
        remove_profile(user_dir)
        os.remove(log_path)
        restore_kpp_cover_windows(hidden_kpp_windows)
        restore_window_manager()
        return result, err
    end

    -- Promote interactive pages before attaching DevTools. Without a valid
    -- Kindle window name, Awesome can leave them underneath KOReader/KPP.
    -- Automatic source requests stay below the reader and never take it out
    -- of the foreground.
    if background then
        hide_browser_window()
    else
        promote_browser_window(now() + 5, hidden_kpp_windows)
    end

    local page, page_err = wait_for_page(
        port,
        now() + 20,
        background and hide_browser_window or nil,
        background and 0.35 or nil
    )
    if not page then return finish(nil, page_err) end
    client, page_err = connect_devtools(page, port)
    if not client then return finish(nil, page_err) end
    client:call("Runtime.enable", {})
    client:call("Network.enable", {})
    client:call("Page.enable", {})

    local browser_headers = options.headers
    if browser_headers ~= nil and type(browser_headers) ~= "table" then
        return finish(nil, "browser headers must be an object")
    end
    if type(browser_headers) == "table" and next(browser_headers) ~= nil then
        local _, browser_headers_err = client:call("Network.setExtraHTTPHeaders", {
            headers = browser_headers,
        })
        if browser_headers_err then
            return finish(nil, browser_headers_err)
        end
    end
    set_browser_cookies(client, options.cookies, url)
    local navigation_url = url
    if url:find(",", 1, true) then
        -- Legado URL options append a JSON object after a comma. Chromium
        -- must receive only the actual URL; the HTTP runtime still handles
        -- those options when it performs a post-browser refetch.
        local comma = url:find(",", 1, true)
        while comma do
            local tail = url:sub(comma + 1)
            local decoded_ok, decoded = pcall(rapidjson.decode, tail)
            if decoded_ok and type(decoded) == "table" then
                navigation_url = trim(url:sub(1, comma - 1))
                break
            end
            comma = url:find(",", comma + 1, true)
        end
    end
    local supplied_html = options.html
    if is_cloudflare_challenge_html(supplied_html) then
        return finish(nil, CLOUDFLARE_UNSUPPORTED_ERROR)
    end
    local _, navigation_err = client:call("Page.navigate", { url = navigation_url })
    if navigation_err then return finish(nil, navigation_err) end
    if background then
        hide_browser_window()
    else
        promote_browser_window(now() + 2, hidden_kpp_windows)
    end
    if type(supplied_html) == "string" and supplied_html ~= "" then
        if #supplied_html > MAX_HTML_BYTES then
            return finish(nil, "browser HTML is too large")
        end
        local frame_tree = client:call("Page.getFrameTree", {})
        local frame = frame_tree and frame_tree.frameTree and frame_tree.frameTree.frame
        if not frame or not frame.id then
            return finish(nil, "browser did not expose a document frame")
        end
        local _, content_err = client:call("Page.setDocumentContent", {
            frameId = frame.id,
            html = supplied_html,
        })
        if content_err then return finish(nil, content_err) end
    end

    local deadline = now() + (tonumber(options.timeout) or DEFAULT_TIMEOUT)
    local last_url = ""
    local injected = false
    local ready_at
    local pan_position
    local cloudflare_seen = false
    local function finish_browser_error(message)
        if cloudflare_seen then
            return finish(nil, CLOUDFLARE_UNSUPPORTED_ERROR)
        end
        return finish(nil, message)
    end
    while now() < deadline do
        if not browser_process_alive(pid) then
            return finish(nil, "Kindle browser exited before the action completed")
        end
        if client.cloudflare_challenge_seen then
            cloudflare_seen = true
            return finish(nil, CLOUDFLARE_UNSUPPORTED_ERROR)
        end
        local current_url_value, current_url_err = client:evaluate(
            "String(location.href || '')"
        )
        if current_url_err then return finish_browser_error(current_url_err) end
        local current_url = tostring(current_url_value or "")
        if current_url ~= last_url then
            last_url = current_url
            injected = false
            if background then
                hide_browser_window()
            else
                promote_browser_window(now() + 1, hidden_kpp_windows)
            end
        end
        if not automatic and not injected then
            injected = add_done_button(client) == true
        end
        -- KOReader owns the input device while its worker is active.  Keep
        -- the Chromium client raised as Awesome/KPP may reassert its own
        -- stacking order after a navigation or a virtual-keyboard event.
        if background then
            hide_browser_window()
        else
            promote_browser_window(now() + 0.15, hidden_kpp_windows)
            pan_position = forward_browser_inputs(client, token, pan_position)
        end
        local challenge_value, challenge_err = cloudflare_challenge_page(client)
        if challenge_err then return finish_browser_error(challenge_err) end
        if challenge_value == true then
            cloudflare_seen = true
            return finish(nil, CLOUDFLARE_UNSUPPORTED_ERROR)
        end
        if options.override_url_regex and tostring(options.override_url_regex) ~= "" then
            local matched, match_err = client:matches_regex(
                current_url,
                options.override_url_regex
            )
            if match_err then return finish(nil, match_err) end
            if matched == true then
                local result, result_err = document_result(client)
                if not result then return finish(nil, result_err) end
                result.body = current_url
                result.url = current_url
                return finish(result)
            end
        end
        if options.source_regex and tostring(options.source_regex) ~= "" then
            local resource, resource_err = client:matching_resource(options.source_regex)
            if resource_err then return finish(nil, resource_err) end
            if resource then
                local result, result_err = document_result(client)
                if not result then return finish(nil, result_err) end
                -- BackstageWebView returns the sniffed URL as the body when
                -- sourceRegex matches an onLoadResource event. Preserve that
                -- contract so a normal `<js>result</js>` content rule can use
                -- it without a site-specific branch.
                result.body = resource
                return finish(result)
            end
        end
        if automatic then
            local ready, ready_err = client:evaluate(
                "String(document.readyState || '')"
            )
            if ready_err then return finish_browser_error(ready_err) end
            if ready ~= "loading" then
                if not ready_at then
                    local delay_ms = tonumber(options.delay) or 0
                    ready_at = now() + 1 + math.max(0, delay_ms) / 1000
                end
                if ready_at and now() >= ready_at then
                    local script = tostring(options.script or "")
                    local script_value
                    if script ~= "" then
                        local script_err
                        -- Runtime.evaluate already returns the value of the last
                        -- expression. Wrapping the source in a function loses
                        -- that value for common WebView rules such as
                        -- `getDecode(); $('#content').html();` and changes the
                        -- scope of `var` declarations used by legacy sources.
                        script_value, script_err = client:evaluate(script)
                        if script_err then return finish(nil, script_err) end
                    end
                    local result, result_err = document_result(client)
                    if not result then return finish(nil, result_err) end
                    if script_value ~= nil and tostring(script_value) ~= "" then
                        if type(script_value) == "table" then
                            local encoded_ok, encoded = pcall(rapidjson.encode, script_value)
                            result.body = encoded_ok and encoded or tostring(script_value)
                        else
                            result.body = tostring(script_value)
                        end
                    end
                    return finish(result)
                end
            end
        end
        if not automatic then
            local done, done_err = client:evaluate(
                "window.__legado_browser_done === true"
            )
            if done_err then return finish_browser_error(done_err) end
            if done == true then
                local pending_challenge, pending_err = cloudflare_challenge_page(client)
                if pending_err then return finish_browser_error(pending_err) end
                if pending_challenge then
                    cloudflare_seen = true
                    return finish(nil, CLOUDFLARE_UNSUPPORTED_ERROR)
                else
                    local result, result_err = document_result(client)
                    if not result then return finish(nil, result_err) end
                    if options.refetch_after_success == true
                            and not url:lower():match("^data:") then
                        local Network = require("legado/network")
                        -- document_result carries cookies from Chromium's
                        -- cookie store. Merge them before refetching through
                        -- the normal HTTP client; otherwise a freshly issued
                        -- cf_clearance cookie is only visible after this
                        -- function has already returned.
                        if result.cookies then Network.merge_cookies(result.cookies) end
                        local refresh_options
                        if type(options.context) == "table" then
                            refresh_options = { __legado_context = options.context }
                        end
                        local refreshed, refresh_err = Network.get(
                            url, options.source, refresh_options
                        )
                        if refreshed then
                            result.body = refreshed
                            result.url = url
                        elseif refresh_err then
                            result.refresh_error = refresh_err
                        end
                    end
                    return finish(result)
                end
            end
        end
        socket.sleep(0.5)
    end
    if cloudflare_seen then
        return finish(nil, CLOUDFLARE_UNSUPPORTED_ERROR)
    end
    return finish(nil, "browser interaction timed out; tap 完成并返回 Kindle")
end

return Browser
