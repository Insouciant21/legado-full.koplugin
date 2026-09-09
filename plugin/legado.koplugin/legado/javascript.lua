-- Legado JavaScript compatibility layer.
--
-- LuaJIT cannot execute the ES6 syntax used by modern sources, so
-- the actual evaluator lives in native/legado_js.c and is loaded through the
-- small C ABI below.  Network and persistent-looking host objects stay in Lua
-- so the bridge never gives source JavaScript direct filesystem access.

local rapidjson = require("rapidjson")
local Network = require("legado/network")
local bit
pcall(function()
    bit = require("bit")
end)

local Javascript = {}
Javascript.__index = Javascript

-- A rule normally returns a small scalar or a single page of JSON.  Keeping
-- the bridge buffer at 2 MiB is enough for those results and, importantly,
-- avoids allocating a fresh 16 MiB FFI object for every chapter in a TOC.
-- Large source responses are still allowed up to the hard ceiling below by
-- sizing the reusable buffer from the input page when that is necessary.
local INITIAL_OUTPUT_SIZE = 2 * 1024 * 1024
local MAX_OUTPUT_SIZE = 16 * 1024 * 1024

local ffi
local ffi_error
do
    local ok, loaded = pcall(require, "ffi")
    if ok then
        ffi = loaded
        local cdef_ok, cdef_message = pcall(ffi.cdef, [[
            typedef unsigned long size_t;
            typedef int (*legado_js_host_callback)(const char *operation,
                                                    const char *arguments_json,
                                                    char *output,
                                                    size_t output_size);
            int legado_js_eval(const char *library,
                               const char *script,
                               const char *context_json,
                               legado_js_host_callback callback,
                               char *output,
                               size_t output_size);
            const char *legado_js_engine_version(void);
        ]])
        if not cdef_ok then
            ffi_error = tostring(cdef_message)
            ffi = nil
        end
    else
        ffi_error = tostring(loaded)
    end
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_expected_fallback_log(operation, message)
    if operation ~= "log" then
        return false
    end
    -- Some sources probe Android's optional encrypted-storage API and then
    -- deliberately fall back to source.putLoginInfo() when it is absent.
    -- Hide only that explicit capability-probe message; real source errors
    -- continue to be returned to the user.
    local lowered = tostring(message or ""):lower()
    return lowered:find(
        "legado javascript capability is unavailable on kindle: createsymmetriccrypto",
        1,
        true
    ) ~= nil or lowered:find(
        "legado javascript capability is unavaible on kindle: createsymmetriccrypto",
        1,
        true
    ) ~= nil
end

local function source_directory()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    return source:match("^(.*)/[^/]+$") or "."
end

local function architecture_names()
    local arch = jit and jit.arch or ""
    if arch == "arm" then
        local hard_float = false
        local loader = io.open("/lib/ld-linux-armhf.so.3", "rb")
        if loader then
            loader:close()
            hard_float = true
        end
        if hard_float then
            return { "armhf", "armv7l", "armel", "arm" }
        end
        return { "armel", "armv7l", "arm", "armhf" }
    elseif arch == "x64" then
        return { "x86_64", "x64" }
    elseif arch == "x86" then
        return { "i686", "x86" }
    elseif arch == "ppc" then
        return { "ppc" }
    end
    return {}
end

local function load_bridge()
    if not ffi then
        return nil, "LuaJIT FFI is unavailable: " .. tostring(ffi_error or "unknown error")
    end
    local lib_root = source_directory() .. "/../lib"
    local candidates = {}
    for _, name in ipairs(architecture_names()) do
        candidates[#candidates + 1] = lib_root .. "/" .. name .. "/liblegado_js.so"
    end
    -- This fallback is useful for development builds and for KOReader ports
    -- whose JIT architecture string is not one of the usual names.
    candidates[#candidates + 1] = lib_root .. "/liblegado_js.so"
    local errors = {}
    for _, path in ipairs(candidates) do
        local ok, library = pcall(ffi.load, path)
        if ok and library then
            return library, path
        end
        errors[#errors + 1] = path .. ": " .. tostring(library)
    end
    return nil, "QuickJS bridge is missing; install liblegado_js.so for the Kindle architecture (" ..
        table.concat(errors, "; ") .. ")"
end

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64_reverse

local function make_base64_reverse()
    if base64_reverse then
        return base64_reverse
    end
    base64_reverse = {}
    for index = 1, #base64_alphabet do
        base64_reverse[base64_alphabet:sub(index, index)] = index - 1
    end
    return base64_reverse
end

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

local function base64_decode(value)
    local reverse = make_base64_reverse()
    local input = tostring(value or ""):gsub("%s+", "")
    local output = {}
    local index = 1
    while index <= #input do
        local a = reverse[input:sub(index, index)]
        local b = reverse[input:sub(index + 1, index + 1)]
        local c_char = input:sub(index + 2, index + 2)
        local d_char = input:sub(index + 3, index + 3)
        local c = c_char == "=" and nil or reverse[c_char]
        local d = d_char == "=" and nil or reverse[d_char]
        if a == nil or b == nil then
            return nil, "invalid Base64 data"
        end
        local number = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        output[#output + 1] = string.char(math.floor(number / 65536) % 256)
        if c ~= nil then
            output[#output + 1] = string.char(math.floor(number / 256) % 256)
        end
        if d ~= nil then
            output[#output + 1] = string.char(number % 256)
        end
        index = index + 4
    end
    return table.concat(output)
end

local function hex_decode(value)
    local input = tostring(value or ""):gsub("%s+", "")
    if #input % 2 ~= 0 or not input:match("^[%x]*$") then
        return nil, "invalid hexadecimal data"
    end
    local output = {}
    for index = 1, #input, 2 do
        output[#output + 1] = string.char(tonumber(input:sub(index, index + 1), 16))
    end
    return table.concat(output)
end

local function md5_hex(value)
    if not bit then
        return nil, "LuaJIT bit operations are unavailable"
    end
    value = tostring(value or "")
    local uint32 = 4294967296
    local function unsigned(number)
        number = tonumber(number) or 0
        return number < 0 and number + uint32 or number
    end
    local function add32(...)
        local total = 0
        for index = 1, select("#", ...) do
            total = total + unsigned(select(index, ...))
        end
        return bit.tobit(total % uint32)
    end
    local function rotate_left(number, amount)
        return bit.bor(bit.lshift(number, amount), bit.rshift(number, 32 - amount))
    end
    local function word_at(data, offset)
        local b1 = data:byte(offset) or 0
        local b2 = data:byte(offset + 1) or 0
        local b3 = data:byte(offset + 2) or 0
        local b4 = data:byte(offset + 3) or 0
        return bit.tobit(b1 + b2 * 256 + b3 * 65536 + b4 * 16777216)
    end
    local function word_bytes(number)
        local value_number = unsigned(number)
        return string.char(
            value_number % 256,
            math.floor(value_number / 256) % 256,
            math.floor(value_number / 65536) % 256,
            math.floor(value_number / 16777216) % 256
        )
    end

    local shifts = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    }
    local constants = {}
    for index = 1, 64 do
        constants[index] = bit.tobit(math.floor(math.abs(math.sin(index)) * uint32))
    end

    local bit_length = #value * 8
    local data = value .. string.char(128)
    while #data % 64 ~= 56 do
        data = data .. string.char(0)
    end
    local length_number = bit_length
    for _ = 1, 4 do
        data = data .. string.char(length_number % 256)
        length_number = math.floor(length_number / 256)
    end
    data = data .. string.rep(string.char(0), 4)

    local a0 = bit.tobit(0x67452301)
    local b0 = bit.tobit(0xefcdab89)
    local c0 = bit.tobit(0x98badcfe)
    local d0 = bit.tobit(0x10325476)
    for offset = 1, #data, 64 do
        local words = {}
        for index = 0, 15 do
            words[index] = word_at(data, offset + index * 4)
        end
        local a, b, c, d = a0, b0, c0, d0
        for index = 0, 63 do
            local f, word_index
            if index < 16 then
                f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
                word_index = index
            elseif index < 32 then
                f = bit.bor(bit.band(d, b), bit.band(bit.bnot(d), c))
                word_index = (5 * index + 1) % 16
            elseif index < 48 then
                f = bit.bxor(b, c, d)
                word_index = (3 * index + 5) % 16
            else
                f = bit.bxor(c, bit.bor(b, bit.bnot(d)))
                word_index = (7 * index) % 16
            end
            local next_a = d
            local rotated = rotate_left(add32(a, f, constants[index + 1], words[word_index]), shifts[index + 1])
            d = c
            c = b
            b = add32(b, rotated)
            a = next_a
        end
        a0 = add32(a0, a)
        b0 = add32(b0, b)
        c0 = add32(c0, c)
        d0 = add32(d0, d)
    end
    local digest = word_bytes(a0) .. word_bytes(b0) .. word_bytes(c0) .. word_bytes(d0)
    return (digest:gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

local function safe_json(value)
    if value == nil then
        return "null"
    end
    local ok, encoded = pcall(rapidjson.encode, value)
    if not ok then
        return nil, tostring(encoded)
    end
    return encoded
end

local function value_for_json(value, depth, seen)
    depth = depth or 0
    if depth > 12 then
        return nil
    end
    local value_type = type(value)
    if value == nil or value_type == "string" or value_type == "number" or value_type == "boolean" then
        return value
    elseif value_type == "table" then
        seen = seen or {}
        if seen[value] then
            return nil
        end
        seen[value] = true
        local output = {}
        for key, child in pairs(value) do
            if type(key) == "string" and key:sub(1, 2) ~= "__" and type(child) ~= "function"
                    and type(child) ~= "userdata" and type(child) ~= "cdata" then
                output[key] = value_for_json(child, depth + 1, seen)
            elseif type(key) == "number" and type(child) ~= "function"
                    and type(child) ~= "userdata" and type(child) ~= "cdata" then
                output[key] = value_for_json(child, depth + 1, seen)
            end
        end
        seen[value] = nil
        return output
    elseif value_type == "userdata" then
        local ok, content = pcall(function()
            return value:getcontent()
        end)
        return ok and tostring(content or "") or tostring(value)
    end
    return tostring(value)
end

local function element_content(value)
    if type(value) == "userdata" then
        local ok, content = pcall(function()
            return value:getcontent()
        end)
        if ok then
            return content or ""
        end
    end
    return value
end

local function host_content(context, value)
    if value == nil then
        value = context and context.result or ""
    end
    return element_content(value)
end

local function source_key(source)
    source = source or {}
    return tostring(source.bookSourceUrl or "") .. "\0" .. tostring(source.bookSourceName or "")
end

local function book_key(context)
    return tostring(context.bookKey or (context.book and (context.book.bookUrl or context.book.name)) or "")
end

local function map_for(root, key)
    local value = root[key]
    if type(value) ~= "table" then
        value = {}
        root[key] = value
    end
    return value
end

local function javascript_header(source)
    local header = source and source.header
    if type(header) ~= "string" then
        return false
    end
    local lowered = trim(header):lower()
    return lowered:match("^@js:") ~= nil or lowered:match("^<js>") ~= nil
end

function Javascript:new()
    local object = setmetatable({}, self)
    object.bridge, object.bridge_path = load_bridge()
    object.source_variables = {}
    object.login_infos = {}
    object.store = {}
    object.memory = {}
    object.arguments = {}
    object.book_variables = {}
    object.library_cache = {}
    object.callback = nil
    object.output_buffer = nil
    object.output_size = 0
    object.notifications = {}
    return object
end

-- Android sources commonly report the outcome of a login action through
-- java.toast()/java.log() instead of returning a value.  Keep those messages
-- in the worker until Runtime.login_source can pass them back to the UI.
function Javascript:clear_notifications()
    self.notifications = {}
end

function Javascript:take_notifications()
    local messages = self.notifications or {}
    self.notifications = {}
    return messages
end

function Javascript:ensure_output_buffer(size)
    size = tonumber(size) or INITIAL_OUTPUT_SIZE
    size = math.max(INITIAL_OUTPUT_SIZE, math.min(MAX_OUTPUT_SIZE, math.floor(size)))
    if self.output_buffer and self.output_size >= size then
        return true
    end

    -- Drop the previous FFI allocation before growing.  This matters on the
    -- 32-bit Kindle libc, where retaining both buffers can briefly double the
    -- resident allocation during a large result.
    self.output_buffer = nil
    self.output_size = 0
    collectgarbage("collect")
    local ok, buffer = pcall(ffi.new, "char[?]", size)
    if not ok then
        return nil, "cannot allocate JavaScript result buffer: " .. tostring(buffer)
    end
    self.output_buffer = buffer
    self.output_size = size
    return true
end

function Javascript:is_available()
    return self.bridge ~= nil
end

function Javascript:status()
    if self.bridge then
        local ok, version = pcall(function()
            return ffi.string(self.bridge.legado_js_engine_version())
        end)
        return ok and version or "QuickJS"
    end
    return nil, self.bridge_path
end

function Javascript:source_variable(source, context)
    local key = source_key(source)
    if self.source_variables[key] == nil then
        local initial = (context or {}).sourceVariable
        if initial == nil or initial == "" then
            initial = source and source.variable
        end
        if type(initial) == "table" then
            local encoded_ok, encoded = pcall(rapidjson.encode, initial)
            initial = encoded_ok and encoded or ""
        end
        self.source_variables[key] = tostring(initial or "")
    end
    return self.source_variables[key], key
end

local function encode_login_value(value)
    if type(value) == "table" then
        local encoded_ok, encoded = pcall(rapidjson.encode, value)
        return encoded_ok and encoded or "{}"
    end
    if value == nil or value == "" then
        return "{}"
    end
    return tostring(value)
end

function Javascript:restore_source_state(source, state)
    local key = source_key(source)
    state = type(state) == "table" and state or {}
    local initial_variable = state.sourceVariable
    if initial_variable == nil then
        initial_variable = source and source.variable
    end
    if type(initial_variable) == "table" then
        local encoded_ok, encoded = pcall(rapidjson.encode, initial_variable)
        initial_variable = encoded_ok and encoded or ""
    end
    self.source_variables[key] = tostring(initial_variable or "")
    local initial_login = state.loginInfo
    if initial_login == nil then
        initial_login = source and source.loginInfo
    end
    self.login_infos[key] = encode_login_value(initial_login)
    self.arguments[key] = type(state.arguments) == "table" and state.arguments or {}
    self.store[key] = type(state.store) == "table" and state.store or {}
end

function Javascript:export_source_state(source)
    local key = source_key(source)
    local variable = self.source_variables[key]
    if variable == nil then
        variable = self:source_variable(source, {})
    end
    local login_info = self.login_infos[key]
    if login_info == nil then
        login_info = encode_login_value(source and source.loginInfo)
    end
    return {
        sourceVariable = tostring(variable or ""),
        loginInfo = tostring(login_info or "{}"),
        arguments = value_for_json(self.arguments[key] or {}, 0, {}),
        store = value_for_json(self.store[key] or {}, 0, {}),
    }
end

function Javascript:set_login_info(source, value)
    self.login_infos[source_key(source)] = encode_login_value(value)
end

function Javascript:source_library(source)
    local raw = tostring(source and source.jsLib or "")
    if raw == "" then
        return ""
    end
    local source_id = source_key(source)
    local cached = self.library_cache[source_id]
    if cached and cached.raw == raw then
        return cached.value, cached.error
    end

    local library = raw
    local decoded_ok, decoded = pcall(rapidjson.decode, raw)
    local is_library_map = decoded_ok and type(decoded) == "table"
    if is_library_map then
        for name in pairs(decoded) do
            if type(name) ~= "string" then
                is_library_map = false
                break
            end
        end
    end
    if is_library_map then
        local names = {}
        for name in pairs(decoded) do
            names[#names + 1] = tostring(name)
        end
        table.sort(names)
        local pieces = {}
        for _, name in ipairs(names) do
            local item = decoded[name]
            if type(item) ~= "string" then
                item = tostring(item or "")
            end
            if item:match("^https?://") or item:match("^data:") then
                -- A mapped library is loaded before the rule itself, so a
                -- dynamic source header cannot be evaluated recursively yet.
                -- Use the normal KOReader defaults for this bootstrap fetch;
                -- subsequent java.ajax calls resolve the source header.
                local library_source = source
                if javascript_header(source) then
                    library_source = {}
                    for key, value in pairs(source or {}) do
                        library_source[key] = value
                    end
                    library_source.header = {}
                end
                local body, err = Network.get(item, library_source)
                if not body then
                    local message = "cannot load JavaScript library " .. name .. ": " .. tostring(err)
                    self.library_cache[source_id] = { raw = raw, error = message }
                    return nil, message
                end
                pieces[#pieces + 1] = body
            else
                pieces[#pieces + 1] = item
            end
        end
        library = table.concat(pieces, "\n")
    end
    self.library_cache[source_id] = { raw = raw, value = library }
    return library
end

function Javascript:host_call(operation, args, source, context)
    args = type(args) == "table" and args or {}
    local first = args[1]
    local second = args[2]
    local variable, source_id = self:source_variable(source, context)
    local stores = map_for(self.store, source_id)
    local memory = map_for(self.memory, source_id)
    local arguments = map_for(self.arguments, source_id)

    if operation == "ajax" then
        local request_source = source
        local request_options = second
        if javascript_header(source) then
            local header_value, header_suffix, header_err = self:evaluate_rule(
                source,
                source.header,
                context,
                context and context.result or ""
            )
            if header_err then
                return nil, "source header: " .. tostring(header_err)
            end
            if header_suffix and trim(header_suffix) ~= "" then
                return nil, "source header has an unsupported trailing rule"
            end
            if type(header_value) == "string" then
                local decoded_ok, decoded = pcall(rapidjson.decode, header_value)
                if decoded_ok then
                    header_value = decoded
                end
            end
            if type(header_value) ~= "table" then
                return nil, "source header JavaScript did not return an object"
            end
            local copied_options = {}
            if type(request_options) == "table" then
                for key, value in pairs(request_options) do
                    copied_options[key] = value
                end
            elseif type(request_options) == "string" then
                local decoded_ok, decoded = pcall(rapidjson.decode, request_options)
                if decoded_ok and type(decoded) == "table" then
                    copied_options = decoded
                end
            end
            copied_options.headers = header_value
            request_options = copied_options
            request_source = {}
            for key, value in pairs(source or {}) do
                request_source[key] = value
            end
            request_source.header = header_value
        end
        local body, err = Network.get(tostring(first or ""), request_source, request_options)
        if not body then
            return nil, err or "HTTP request failed"
        end
        return body
    elseif operation == "base64Encode" then
        return base64_encode(first or "")
    elseif operation == "base64Decode" then
        return base64_decode(first or "")
    elseif operation == "hexDecodeToString" or operation == "hexDecode" then
        return hex_decode(first or "")
    elseif operation == "md5Encode" then
        return md5_hex(first or "")
    elseif operation == "md5Encode16" then
        local digest, err = md5_hex(first or "")
        if not digest then
            return nil, err
        end
        return digest:sub(9, 24)
    elseif operation == "source.getVariable" then
        return variable
    elseif operation == "source.setVariable" then
        self.source_variables[source_id] = tostring(first or "")
        return self.source_variables[source_id]
    elseif operation == "source.getLoginInfo" then
        if self.login_infos[source_id] == nil then
            self.login_infos[source_id] = encode_login_value(source and source.loginInfo)
        end
        return self.login_infos[source_id]
    elseif operation == "source.getLoginInfoMap" then
        if self.login_infos[source_id] == nil then
            self.login_infos[source_id] = encode_login_value(source and source.loginInfo)
        end
        local decoded_ok, decoded = pcall(rapidjson.decode, self.login_infos[source_id])
        return decoded_ok and type(decoded) == "table" and decoded or {}
    elseif operation == "source.getKey" then
        return tostring(source and source.bookSourceUrl or "")
    elseif operation == "source.getLoginHeader" then
        return tostring(source and source.header or "")
    elseif operation == "source.putLoginInfo" then
        local value = second ~= nil and second or first
        self.login_infos[source_id] = encode_login_value(value)
        return self.login_infos[source_id]
    elseif operation == "getString" or operation == "getElement" or operation == "getElements" then
        local Rules = require("legado/rules")
        local content = host_content(context, second)
        local values, parse_err
        if operation == "getElements" then
            values, parse_err = Rules.elements(content, tostring(first or ""), context)
            if not values then
                return nil, parse_err
            end
            local result = {}
            for _, value in ipairs(values) do
                result[#result + 1] = element_content(value)
            end
            return result
        end
        values, parse_err = Rules.parse_list(content, tostring(first or ""), context)
        if not values then
            return nil, parse_err
        end
        if operation == "getElement" then
            return values[1] or ""
        end
        return table.concat(values, "\n")
    elseif operation == "setContent" then
        if context then
            context.result = first or ""
        end
        return ""
    elseif operation == "post" then
        local body, err = Network.get(tostring(first or ""), source, {
            method = "POST",
            body = second,
            headers = type(args[3]) == "table" and args[3] or nil,
        })
        if not body then
            return nil, err or "HTTP POST failed"
        end
        return body
    elseif operation == "importScript" then
        local body, err = Network.get(tostring(first or ""), source)
        if not body then
            return nil, err or "JavaScript library import failed"
        end
        return body
    elseif operation == "store.get" or operation == "variable.get" then
        local key = first == nil and "" or tostring(first)
        if operation == "variable.get" and first == nil then
            return variable
        end
        return stores[key]
    elseif operation == "store.put" or operation == "variable.set" then
        local key = tostring(first or "")
        stores[key] = second
        return second
    elseif operation == "memory.get" then
        return memory[tostring(first or "")]
    elseif operation == "memory.put" then
        memory[tostring(first or "")] = second
        return second
    elseif operation == "memory.delete" then
        memory[tostring(first or "")] = nil
        return ""
    elseif operation == "cookie.get" then
        return Network.cookie_get(tostring(first or ""))
    elseif operation == "cookie.set" then
        return Network.cookie_set(tostring(first or ""), tostring(second or ""))
    elseif operation == "cookie.remove" then
        return Network.cookie_remove(tostring(first or ""))
    elseif operation == "cookie.key" then
        return Network.cookie_key(tostring(first or ""), tostring(second or ""))
    elseif operation == "userAgent" then
        return Network.user_agent()
    elseif operation == "deviceId" or operation == "androidId" then
        return "kindle"
    elseif operation == "argument.get" then
        return arguments[tostring(first or "")]
    elseif operation == "argument.set" then
        arguments[tostring(first or "")] = second
        return second
    elseif operation == "arguments.get" then
        if second == nil or tostring(second) == "" then
            return arguments
        end
        local key = tostring(second)
        local candidate = first
        if type(candidate) == "string" then
            local decoded_ok, decoded = pcall(rapidjson.decode, candidate)
            if decoded_ok then
                candidate = decoded
            end
        end
        if type(candidate) == "table" then
            return candidate[key]
        end
        return nil
    elseif operation == "arguments.set" then
        arguments[tostring(first or "")] = second
        return second
    elseif operation == "book.getVariable" then
        local books = map_for(self.book_variables, source_id)
        local current = books[book_key(context)]
        return type(current) == "table" and current[tostring(first or "")] or nil
    elseif operation == "book.setVariable" then
        local books = map_for(self.book_variables, source_id)
        local current = books[book_key(context)]
        if type(current) ~= "table" then
            current = {}
            books[book_key(context)] = current
        end
        current[tostring(first or "")] = second
        return second
    elseif operation == "startBrowserAwait"
            or operation == "startBrowser"
            or operation == "startBrowserDp"
            or operation == "showBrowser"
            or operation == "showReadingBrowser" then
        -- Legado's Android implementation opens a WebView, waits for the
        -- user to finish the page, then returns the resulting document and
        -- cookies.  Keep this host operation source-independent: the Kindle
        -- browser bridge supplies the UI while the source's own JavaScript
        -- remains responsible for interpreting the returned page.
        local Browser = require("legado/browser")
        local browser_headers, headers_err = Network.browser_headers(source)
        if not browser_headers then
            return nil, headers_err or "cannot prepare browser request headers"
        end
        local waits_for_result = operation == "startBrowserAwait"
        local browser_result, browser_err = Browser.await(tostring(first or ""), {
            title = second,
            refetch_after_success = waits_for_result and args[3] ~= false or false,
            html = waits_for_result and args[4] or args[3],
            source = source,
            headers = browser_headers,
            cookies = Network.export_cookies(),
        })
        if not browser_result then
            return nil, browser_err or "browser interaction failed"
        end
        if browser_result.cookies then
            Network.merge_cookies(browser_result.cookies)
        end
        if not waits_for_result then
            return ""
        end
        return browser_result
    elseif operation == "log" or operation == "toast" then
        -- Source-side status is often communicated only through a toast or a
        -- log call.  Returning it to the UI is more useful than silently
        -- discarding it, and the bounded list prevents a noisy source from
        -- consuming the Kindle's limited memory.
        local message = trim(first == nil and "" or first)
        if message ~= "" and not is_expected_fallback_log(operation, message) then
            self.notifications = self.notifications or {}
            if #self.notifications < 32 then
                self.notifications[#self.notifications + 1] = {
                    operation = operation,
                    message = message,
                }
            end
        end
        return ""
    elseif operation == "unsupported" then
        return nil, "Legado JavaScript capability is unavailable on Kindle: " .. tostring(first or "unknown")
    end
    return nil, "unknown Legado JavaScript host operation: " .. tostring(operation)
end

local function split_rule(value)
    local rule = trim(value)
    local lowered = rule:lower()
    if lowered:match("^@webjs:") then
        return nil, nil, "WebView JavaScript is not available on Kindle"
    end
    if lowered:match("^@js:") then
        return rule:sub(5), ""
    end
    if lowered:match("^<js>") then
        local close_start, close_end = lowered:find("</js>", 5, true)
        if not close_start then
            return nil, nil, "unterminated <js> rule"
        end
        return rule:sub(5, close_start - 1), rule:sub(close_end + 1)
    end
    return nil
end

function Javascript:evaluate_rule(source, rule, context, content)
    local script, suffix, split_err = split_rule(rule)
    if not script then
        return nil, nil, split_err or "not a JavaScript rule"
    end
    if not self.bridge then
        return nil, nil, self.bridge_path
    end

    context = context or {}
    local js_context = {}
    for key, value in pairs(context) do
        if key ~= "__js_eval" and key ~= "_js_eval" then
            js_context[key] = value_for_json(value)
        end
    end
    content = element_content(content)
    local estimated_output_size = INITIAL_OUTPUT_SIZE
    if type(content) == "string" then
        -- JSON.stringify can escape a string, so leave room for expansion.
        -- This is only a sizing hint; the native bridge still enforces the
        -- hard maximum and reports a useful error for pathological sources.
        estimated_output_size = math.max(
            estimated_output_size,
            math.min(MAX_OUTPUT_SIZE, #content * 2 + 64 * 1024)
        )
    end
    js_context.result = value_for_json(content)
    js_context.key = tostring(context.key or "")
    js_context.page = tonumber(context.page or 1) or 1
    js_context.baseUrl = tostring(context.baseUrl or "")
    js_context.sourceUrl = tostring(source and source.bookSourceUrl or "")
    js_context.sourceName = tostring(source and source.bookSourceName or "")
    js_context.sourceComment = tostring(source and source.bookSourceComment or "")
    js_context.sourceHeader = source and source.header or ""
    js_context.sourceVariable = self:source_variable(source, context)
    js_context.hasLoginUi = true
    js_context.deviceMode = "android"
    js_context.bookKey = book_key(context)

    local context_json, context_err = safe_json(js_context)
    if not context_json then
        return nil, nil, "cannot encode JavaScript context: " .. tostring(context_err)
    end
    local library, library_err = self:source_library(source)
    if not library then
        return nil, nil, library_err
    end
    if source and source.mainJs and source.mainJs ~= "" then
        library = library .. "\n" .. tostring(source.mainJs)
    end
    local output_ok, output_err = self:ensure_output_buffer(estimated_output_size)
    if not output_ok then
        return nil, nil, output_err
    end
    local output = self.output_buffer
    local output_size = self.output_size
    local batch_contexts = context.__legado_batch_contexts
    local active_context = context
    local callback
    callback = ffi.cast("legado_js_host_callback", function(operation_ptr, arguments_ptr, output_ptr, output_capacity)
        local ok, response, response_err = pcall(function()
            local operation = ffi.string(operation_ptr)
            local raw_args = ffi.string(arguments_ptr)
            local args_ok, args = pcall(rapidjson.decode, raw_args)
            if not args_ok then
                return nil, "invalid JavaScript host arguments: " .. tostring(args)
            end
            if operation == "__legado_batch_context" then
                local index = tonumber(type(args) == "table" and args[1])
                if type(batch_contexts) ~= "table"
                        or not index or type(batch_contexts[index]) ~= "table" then
                    return nil, "invalid JavaScript batch context index"
                end
                active_context = batch_contexts[index]
                return ""
            end
            return self:host_call(operation, args, source, active_context)
        end)
        if not ok then
            local callback_error = response
            response = nil
            response_err = tostring(callback_error)
        end
        local encoded
        if response_err then
            encoded = rapidjson.encode({ __legado_error = tostring(response_err) })
        else
            local encoded_ok, encoded_value = pcall(rapidjson.encode, response)
            if not encoded_ok then
                encoded = rapidjson.encode({ __legado_error = tostring(encoded_value) })
            else
                encoded = encoded_value
            end
        end
        local capacity = tonumber(output_capacity) or 0
        if capacity <= #encoded then
            return 1
        end
        ffi.copy(output_ptr, encoded .. "\0")
        return 0
    end)
    self.callback = callback
    local ok, result_code = pcall(function()
        return self.bridge.legado_js_eval(
            library,
            script,
            context_json,
            callback,
            output,
            output_size
        )
    end)
    self.callback = nil
    callback:free()
    if not ok then
        return nil, nil, "QuickJS bridge call failed: " .. tostring(result_code)
    end
    if tonumber(result_code) ~= 0 then
        local message = ffi.string(output)
        return nil, nil, "JavaScript rule failed: " .. (message ~= "" and message or "unknown error")
    end
    local output_text = ffi.string(output)
    local decoded_ok, value = pcall(rapidjson.decode, output_text)
    if not decoded_ok then
        return nil, nil, "JavaScript result is not JSON: " .. tostring(value)
    end
    return value, suffix or ""
end

-- A TOC rule is often a small JavaScript expression evaluated once for every
-- chapter.  Starting a new QuickJS runtime for each item is particularly
-- expensive on the 32-bit Kindle.  Pure/read-only item rules can be evaluated
-- in one bridge call while keeping the source rule itself unchanged.
local BATCH_UNSAFE_TOKENS = {
    "ajax", "post", "importscript", "startbrowser", "showbrowser", "webview",
    "setvariable", "setcontent", "setcookie", "removecookie", "putlogininfo",
    "setargument", "setmemory", "putmemory", "cache.put", "cache.delete",
    "memory.put", "memory.delete", "java.put", "source.set", "book.set",
    "settimeout", "eval(", "globalthis.",
}

function Javascript:is_batch_safe_rule(rule)
    local script, suffix = split_rule(rule)
    if not script or (suffix and trim(suffix) ~= "") then
        return false
    end
    local lowered = script:lower()
    for _, token in ipairs(BATCH_UNSAFE_TOKENS) do
        if lowered:find(token, 1, true) then
            return false
        end
    end
    return true
end

function Javascript:evaluate_rule_batch(source, rule, contexts, contents)
    local script, suffix, split_err = split_rule(rule)
    if not script then
        return nil, nil, split_err or "not a JavaScript rule"
    end
    if suffix and trim(suffix) ~= "" then
        return nil, nil, "batch JavaScript rules require an empty trailing rule"
    end
    if type(contexts) ~= "table" or type(contents) ~= "table"
            or #contexts ~= #contents or #contents == 0 then
        return nil, nil, "invalid JavaScript batch arguments"
    end

    local first_context = contexts[1] or {}
    local batch_items = {}
    for index, content in ipairs(contents) do
        local item_context = contexts[index] or first_context
        local item = {
            result = content,
            key = item_context.key,
            page = item_context.page,
            baseUrl = item_context.baseUrl,
            index = item_context.index,
            title = item_context.title,
            host = item_context.host,
        }
        -- The book/chapter values are normally shared across a TOC page. Do
        -- not duplicate a potentially large book object into every item, but
        -- retain an explicitly different value for generic source rules.
        if item_context.book ~= first_context.book then
            item.book = item_context.book
        end
        if item_context.chapter ~= first_context.chapter then
            item.chapter = item_context.chapter
        end
        batch_items[index] = item
    end

    local batch_context = {}
    for key, value in pairs(first_context) do
        if key ~= "result" and key ~= "__js_eval" and key ~= "_js_eval" then
            batch_context[key] = value
        end
    end
    -- Keys beginning with __ are excluded by value_for_json(), but remain
    -- available to the Lua callback so host calls can use the active item
    -- context (book/chapter variables, setContent and nested rules).
    batch_context.__legado_batch_contexts = contexts
    batch_context.batch_script = script

    -- Function() gives every item its own lexical scope, so source rules that
    -- declare `let`/`const` do not collide on the second chapter. The final
    -- expression is intentionally the array itself: evaluate_rule executes
    -- the wrapper as a JavaScript script, not as a function body.
    local batch_wrapper = [=[
const __legado_items = Array.isArray(result) ? result : [];
const __legado_code = String(__ctx.batch_script || "");
const __legado_function = Function("__legado_code", "return eval(__legado_code);");
const __legado_output = [];
const __legado_default_key = globalThis.key;
const __legado_default_page = globalThis.page;
const __legado_default_base_url = globalThis.baseUrl;
const __legado_default_index = globalThis.index;
const __legado_default_title = globalThis.title;
const __legado_default_book = globalThis.book;
const __legado_default_chapter = globalThis.chapter;
const __legado_default_host = globalThis.host;
for (let __legado_i = 0; __legado_i < __legado_items.length; __legado_i++) {
    const __legado_item = __legado_items[__legado_i] || {};
    __legado_host("__legado_batch_context", [__legado_i + 1]);
    globalThis.result = __legado_item.result;
    globalThis.key = __legado_item.key === undefined ? __legado_default_key : __legado_item.key;
    globalThis.page = __legado_item.page === undefined ? __legado_default_page : __legado_item.page;
    globalThis.baseUrl = __legado_item.baseUrl === undefined ? __legado_default_base_url : __legado_item.baseUrl;
    globalThis.index = __legado_item.index === undefined ? __legado_default_index : __legado_item.index;
    globalThis.title = __legado_item.title === undefined ? __legado_default_title : __legado_item.title;
    globalThis.book = __legado_item.book === undefined ? __legado_default_book : (__legado_item.book || {});
    globalThis.chapter = __legado_item.chapter === undefined ? __legado_default_chapter : (__legado_item.chapter || {});
    globalThis.host = __legado_item.host === undefined ? __legado_default_host : (__legado_item.host || []);
    globalThis.book.getVariable = function(k) {
        return __legado_host("book.getVariable", [String(k === undefined ? "" : k)]);
    };
    globalThis.book.setVariable = function(k, v) {
        return __legado_host("book.setVariable", [String(k === undefined ? "" : k), v]);
    };
    globalThis.book.setUseReplaceRule = function() { return ""; };
    const __legado_value = __legado_function.call(globalThis, __legado_code);
    __legado_output.push(__legado_value === undefined ? null : __legado_value);
}
__legado_output
]=]

    local value, result_suffix, eval_err = self:evaluate_rule(
        source,
        "<js>" .. batch_wrapper .. "</js>",
        batch_context,
        batch_items
    )
    if eval_err then
        return nil, nil, eval_err
    end
    if type(value) ~= "table" or #value ~= #contents then
        return nil, nil, "JavaScript batch result length does not match TOC items"
    end
    return value, result_suffix or ""
end

-- Legado stores a few lifecycle hooks (for example ruleToc.formatJs) as raw
-- JavaScript rather than as a <js> rule.  Evaluate those hooks through the
-- same sandbox so all source-side state and host calls behave consistently.
function Javascript:evaluate_script(source, script, context, content, invocation)
    local value = trim(script or "")
    if value == "" then
        return "", ""
    end
    if value:lower():match("^@webjs:") then
        return nil, nil, "WebView JavaScript is not available on Kindle"
    end
    if invocation and invocation ~= "" then
        local lowered = value:lower()
        if lowered:match("^<js>") then
            local close_start, close_end = lowered:find("</js>", 5, true)
            if not close_start then
                return nil, nil, "unterminated <js> rule"
            end
            value = value:sub(1, close_start - 1) .. "\n" .. invocation .. value:sub(close_start)
        else
            value = value .. "\n" .. invocation
        end
    end
    if value:lower():match("^<js>") or value:lower():match("^@js:") then
        return self:evaluate_rule(source, value, context, content)
    end
    return self:evaluate_rule(source, "<js>" .. value .. "</js>", context, content)
end

return Javascript
