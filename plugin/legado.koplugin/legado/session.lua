-- Persistent per-source authentication state.
--
-- Android's exported Legado backup does not contain the live cookie jar of a
-- logged-in source.  Keep the Kindle-side session beside the imported state,
-- rather than adding a non-Android member to bookSource.json or changing the
-- Android backup shape.  The file is intentionally private to this plugin.

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local rapidjson = require("rapidjson")

local Session = {}

local function source_key(source)
    source = source or {}
    return tostring(source.bookSourceUrl or "") .. "\0" .. tostring(source.bookSourceName or "")
end

local function source_parts(source)
    source = source or {}
    return tostring(source.bookSourceUrl or ""), tostring(source.bookSourceName or "")
end

local function parent_directory(path)
    return tostring(path):match("^(.*)/[^/]+$") or "."
end

local function copy_cookies(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end
    for host, cookies in pairs(value) do
        if type(host) == "string" and type(cookies) == "table" then
            local copied = {}
            for name, cookie_value in pairs(cookies) do
                if type(name) == "string"
                        and (type(cookie_value) == "string" or type(cookie_value) == "number") then
                    copied[name] = tostring(cookie_value)
                end
            end
            if next(copied) ~= nil then
                result[host] = copied
            end
        end
    end
    return result
end

local function copy_json(value, depth, seen)
    depth = depth or 0
    if depth > 12 then
        return nil
    end
    local value_type = type(value)
    if value == nil or value_type == "string" or value_type == "number" or value_type == "boolean" then
        return value
    end
    if value_type ~= "table" then
        return nil
    end
    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do
        if (type(key) == "string" or type(key) == "number")
                and type(child) ~= "function"
                and type(child) ~= "userdata"
                and type(child) ~= "cdata" then
            result[key] = copy_json(child, depth + 1, seen)
        end
    end
    seen[value] = nil
    return result
end

local function copy_record(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end
    if value.sourceUrl ~= nil then result.sourceUrl = tostring(value.sourceUrl) end
    if value.sourceName ~= nil then result.sourceName = tostring(value.sourceName) end
    if value.sourceVariable ~= nil then result.sourceVariable = tostring(value.sourceVariable) end
    if value.loginInfo ~= nil then result.loginInfo = tostring(value.loginInfo) end
    result.cookies = copy_cookies(value.cookies)
    result.arguments = copy_json(value.arguments or {})
    result.store = copy_json(value.store or {})
    if value.updatedAt ~= nil then result.updatedAt = tonumber(value.updatedAt) or value.updatedAt end
    return result
end

local function default_path()
    local ok, directory = pcall(function()
        return DataStorage:getDataDir()
    end)
    if not ok or type(directory) ~= "string" or directory == "" then
        return "./legado/source-sessions.json"
    end
    return directory .. "/legado/source-sessions.json"
end

local function read_records(path)
    local file, open_err = io.open(path, "rb")
    if not file then
        -- A first run has no session file.  Other read errors should remain
        -- visible, because silently discarding a valid login is surprising.
        if tostring(open_err or ""):lower():find("no such file", 1, true) then
            return {}
        end
        return nil, tostring(open_err or "cannot open source session file")
    end
    local content = file:read("*a") or ""
    file:close()
    if content == "" then
        return {}
    end
    local ok, decoded = pcall(rapidjson.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil, "source session file is not valid JSON"
    end
    if type(decoded.sources) ~= "table" then
        return {}
    end
    return decoded.sources
end

local function make_parent_directory(path)
    local directory = parent_directory(path)
    if lfs.attributes(directory, "mode") == "directory" then
        return true
    end
    local ok, result = pcall(util.makePath, directory)
    if not ok or result == false then
        return nil, "cannot create source session directory: " .. tostring(result)
    end
    if lfs.attributes(directory, "mode") ~= "directory" then
        return nil, "source session directory was not created"
    end
    return true
end

local function write_records(path, records)
    local parent_ok, parent_err = make_parent_directory(path)
    if not parent_ok then
        return nil, parent_err
    end
    local encoded_ok, encoded = pcall(rapidjson.encode, {
        schema_version = 1,
        sources = records,
    })
    if not encoded_ok then
        return nil, "cannot encode source session file: " .. tostring(encoded)
    end
    local temporary = path .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local file, open_err = io.open(temporary, "wb")
    if not file then
        return nil, "cannot write source session file: " .. tostring(open_err)
    end
    local wrote, write_err = file:write(encoded)
    file:close()
    if not wrote then
        os.remove(temporary)
        return nil, "cannot write source session file: " .. tostring(write_err or "unknown error")
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, "cannot activate source session file: " .. tostring(rename_err or "unknown error")
    end
    -- chmod is optional across KOReader builds.  The file still lives in the
    -- KOReader data directory, and this tightens permissions where supported.
    pcall(function()
        if type(lfs.chmod) == "function" then
            lfs.chmod(path, "0600")
        end
    end)
    return true
end

function Session.path()
    return default_path()
end

function Session.load(source)
    local path = Session.path()
    local records, err = read_records(path)
    if not records then
        return nil, err
    end
    local key = source_key(source)
    for _, record in ipairs(records) do
        if type(record) == "table" then
            local record_source = {
                bookSourceUrl = record.sourceUrl,
                bookSourceName = record.sourceName,
            }
            if source_key(record_source) == key then
                return copy_record(record)
            end
        end
    end
    return {}
end

function Session.save(source, state)
    local path = Session.path()
    local records, err = read_records(path)
    if not records then
        return nil, err
    end
    local source_url, source_name = source_parts(source)
    local key = source_key(source)
    local record = copy_record(state)
    record.sourceUrl = source_url
    record.sourceName = source_name
    record.updatedAt = os.time()
    local replaced = false
    for index, existing in ipairs(records) do
        if type(existing) == "table" then
            local existing_source = {
                bookSourceUrl = existing.sourceUrl,
                bookSourceName = existing.sourceName,
            }
            if source_key(existing_source) == key then
                records[index] = record
                replaced = true
                break
            end
        end
    end
    if not replaced then
        records[#records + 1] = record
    end
    return write_records(path, records)
end

return Session
