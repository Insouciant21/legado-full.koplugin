-- Android backup import/export for the on-device Kindle runtime.
--
-- The Android backup is a ZIP with mostly JSON members.  We deliberately keep
-- every member as bytes, including Android-specific files we do not interpret,
-- so an export remains restorable by Legado on Android.

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local util = require("util")

local Backup = {}

Backup.STATE_SCHEMA_VERSION = 1

Backup.ANDROID_BACKUP_FILES = {
    "bookshelf.json",
    "bookGroup.json",
    "bookSource.json",
    "rssSources.json",
    "readRecord.json",
    "readRecordDetail.json",
    "readRecordSession.json",
    "searchHistory.json",
    "txtTocRule.json",
    "httpTTS.json",
    "keyboardAssists.json",
    "dictRule.json",
    "servers.json",
    "readConfig.json",
    "shareReadConfig.json",
    "themeConfig.json",
    "config.xml",
}

local json_files = {}
for _, filename in ipairs(Backup.ANDROID_BACKUP_FILES) do
    if filename ~= "servers.json" and filename ~= "config.xml" then
        json_files[filename] = true
    end
end

local function fail(message)
    return nil, message
end

local function is_safe_member_name(name)
    -- Android's current format is flat.  Rejecting nested names also prevents
    -- accidental writes outside the state directory when future ZIP members
    -- are encountered.
    return type(name) == "string"
        and name ~= ""
        and not name:match("^/")
        and not name:match("[/\\]")
        and name ~= "."
        and name ~= ".."
end

local function read_file(filename)
    local file = io.open(filename, "rb")
    if not file then
        return nil, "cannot open file: " .. tostring(filename)
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(filename, data)
    local file = io.open(filename, "wb")
    if not file then
        return nil, "cannot write file: " .. tostring(filename)
    end
    local ok, err = file:write(data)
    file:close()
    if not ok then
        return nil, "cannot write file: " .. tostring(filename) .. ": " .. tostring(err)
    end
    return true
end

local function ensure_parent(filename)
    local parent = filename:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        util.makePath(parent)
    end
end

local function unique_path(base)
    local candidate = base
    local suffix = 0
    while lfs.attributes(candidate, "mode") do
        suffix = suffix + 1
        candidate = base .. "." .. tostring(suffix)
    end
    return candidate
end

local function parse_json_member(filename, data)
    if not json_files[filename] then
        return nil
    end
    local ok, value = pcall(rapidjson.decode, data)
    if not ok then
        return nil, filename .. " is not valid JSON: " .. tostring(value)
    end
    return value
end

local function member_kind(filename)
    if json_files[filename] then
        return "json"
    elseif filename == "config.xml" then
        return "xml"
    end
    return "opaque"
end

local function sorted_member_names(members)
    local names = {}
    local included = {}
    for _, filename in ipairs(Backup.ANDROID_BACKUP_FILES) do
        if members[filename] then
            names[#names + 1] = filename
            included[filename] = true
        end
    end
    local extras = {}
    for filename in pairs(members) do
        if not included[filename] then
            extras[#extras + 1] = filename
        end
    end
    table.sort(extras)
    for _, filename in ipairs(extras) do
        names[#names + 1] = filename
    end
    return names
end

local function summary_for(bundle)
    local parsed = bundle.parsed_json
    local sources = type(parsed["bookSource.json"]) == "table" and parsed["bookSource.json"] or {}
    local books = type(parsed["bookshelf.json"]) == "table" and parsed["bookshelf.json"] or {}
    local groups = type(parsed["bookGroup.json"]) == "table" and parsed["bookGroup.json"] or {}
    local count = function(filename)
        local value = parsed[filename]
        return type(value) == "table" and #value or 0
    end
    return {
        member_count = #sorted_member_names(bundle.members),
        counts = {
            book_sources = #sources,
            bookshelf_books = #books,
            book_groups = #groups,
            read_records = count("readRecord.json"),
            read_record_details = count("readRecordDetail.json"),
            read_record_sessions = count("readRecordSession.json"),
        },
    }
end

function Backup.read_archive(filename)
    local reader = Archiver.Reader:new()
    if not reader:open(filename) then
        local message = reader.err or "cannot open backup archive"
        reader:close()
        return fail(message)
    end

    local members = {}
    local parsed_json = {}
    for entry in reader:iterate() do
        if entry.mode ~= "file" then
            reader:close()
            return fail("backup contains a non-file member: " .. tostring(entry.path))
        end
        if not is_safe_member_name(entry.path) then
            reader:close()
            return fail("unsafe backup member name: " .. tostring(entry.path))
        end
        if members[entry.path] ~= nil then
            reader:close()
            return fail("duplicate backup member: " .. tostring(entry.path))
        end
        local data = reader:extractToMemory(entry.path)
        if data == nil then
            local message = reader.err or "cannot read backup member: " .. tostring(entry.path)
            reader:close()
            return fail(message)
        end
        members[entry.path] = data
        local value, err = parse_json_member(entry.path, data)
        if err then
            reader:close()
            return fail(err)
        end
        if json_files[entry.path] then
            parsed_json[entry.path] = value
        end
    end
    reader:close()

    local bundle = {
        members = members,
        parsed_json = parsed_json,
        source = filename,
    }
    bundle.summary = function(self)
        return summary_for(self)
    end
    return bundle
end

function Backup.write_archive(bundle, filename)
    ensure_parent(filename)
    local temporary = unique_path(filename .. ".tmp." .. tostring(os.time()))
    local writer = Archiver.Writer:new()
    if not writer:open(temporary, "zip") then
        os.remove(temporary)
        return fail(writer.err or "cannot create backup archive")
    end
    if not writer:setZipCompression("deflate") then
        writer:close()
        os.remove(temporary)
        return fail(writer.err or "cannot enable ZIP compression")
    end

    local ok = true
    local message
    for _, member_name in ipairs(sorted_member_names(bundle.members)) do
        if not is_safe_member_name(member_name) then
            ok = false
            message = "unsafe backup member name: " .. tostring(member_name)
            break
        end
        if not writer:addFileFromMemory(member_name, bundle.members[member_name]) then
            ok = false
            message = writer.err or "cannot write backup member: " .. tostring(member_name)
            break
        end
    end
    writer:close()
    if not ok then
        os.remove(temporary)
        return fail(message)
    end
    if not os.rename(temporary, filename) then
        os.remove(temporary)
        return fail("cannot replace output archive: " .. tostring(filename))
    end
    return true
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then
        os.remove(path)
    elseif mode == "directory" then
        for child in lfs.dir(path) do
            if child ~= "." and child ~= ".." then
                remove_tree(path .. "/" .. child)
            end
        end
        lfs.rmdir(path)
    end
end

local function make_manifest(bundle)
    local members = {}
    for _, filename in ipairs(sorted_member_names(bundle.members)) do
        members[#members + 1] = {
            name = filename,
            size = #bundle.members[filename],
            kind = member_kind(filename),
        }
    end
    return {
        state_schema_version = Backup.STATE_SCHEMA_VERSION,
        format = "legado-android-backup",
        imported_at = os.time(),
        members = members,
        summary = summary_for(bundle),
    }
end

function Backup.materialize(bundle, state_root)
    local parent = state_root:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        util.makePath(parent)
    end
    local staging = unique_path(state_root .. ".importing")
    util.makePath(staging .. "/android")

    local ok, message = true, nil
    for _, filename in ipairs(sorted_member_names(bundle.members)) do
        if not is_safe_member_name(filename) then
            ok = false
            message = "unsafe backup member name: " .. tostring(filename)
            break
        end
        local written, err = write_file(staging .. "/android/" .. filename, bundle.members[filename])
        if not written then
            ok = false
            message = err
            break
        end
    end
    if ok then
        local manifest = rapidjson.encode(make_manifest(bundle))
        ok, message = write_file(staging .. "/manifest.json", manifest .. "\n")
    end
    if not ok then
        remove_tree(staging)
        return fail(message)
    end

    local previous
    if lfs.attributes(state_root, "mode") then
        previous = unique_path(state_root .. ".previous")
        if not os.rename(state_root, previous) then
            remove_tree(staging)
            return fail("cannot preserve existing state directory")
        end
    end
    if not os.rename(staging, state_root) then
        if previous then
            os.rename(previous, state_root)
        end
        remove_tree(staging)
        return fail("cannot activate imported state directory")
    end
    return {
        state_root = state_root,
        previous_root = previous,
        summary = summary_for(bundle),
    }
end

local function read_manifest(state_root)
    local data, err = read_file(state_root .. "/manifest.json")
    if not data then
        return fail(err)
    end
    local ok, manifest = pcall(rapidjson.decode, data)
    if not ok or type(manifest) ~= "table" then
        return fail("invalid Legado state manifest")
    end
    if manifest.state_schema_version ~= Backup.STATE_SCHEMA_VERSION then
        return fail("unsupported Legado state schema")
    end
    return manifest
end

function Backup.read_state(state_root)
    local manifest, err = read_manifest(state_root)
    if not manifest then
        return fail(err)
    end
    if manifest.format ~= "legado-android-backup" then
        return fail("unsupported Legado state format")
    end
    if lfs.attributes(state_root .. "/android", "mode") ~= "directory" then
        return fail("state has no android member directory")
    end
    local members = {}
    local parsed_json = {}
    local expected_sizes = {}
    if type(manifest.members) ~= "table" then
        return fail("state manifest has no member list")
    end
    for _, info in ipairs(manifest.members) do
        if type(info) ~= "table" or not is_safe_member_name(info.name) then
            return fail("state manifest has an invalid member")
        end
        if expected_sizes[info.name] ~= nil then
            return fail("duplicate state member in manifest: " .. tostring(info.name))
        end
        local size = tonumber(info.size)
        if size == nil or size < 0 or size % 1 ~= 0 then
            return fail("invalid state member size: " .. tostring(info.name))
        end
        if info.kind ~= member_kind(info.name) then
            return fail("state member kind does not match name: " .. tostring(info.name))
        end
        expected_sizes[info.name] = size
    end
    for filename in lfs.dir(state_root .. "/android") do
        if filename ~= "." and filename ~= ".." then
            local member_path = state_root .. "/android/" .. filename
            local mode = lfs.attributes(member_path, "mode")
            -- KOReader creates a sidecar directory next to an opened
            -- document (for example config.sdr).  It is not an Android
            -- backup member and must not make an otherwise valid imported
            -- state unreadable.
            local is_koreader_sidecar = mode == "directory" and filename:match("%.sdr$")
            if is_koreader_sidecar then
                -- Ignore the sidecar; only manifest-listed Android members
                -- participate in the bundle returned below.
            elseif mode ~= "file" then
                return fail("state contains a non-file member: " .. tostring(filename))
            elseif not is_safe_member_name(filename) then
                return fail("unsafe state member name: " .. tostring(filename))
            else
                local data, read_err = read_file(member_path)
                if not data then
                    return fail(read_err)
                end
                if expected_sizes[filename] and #data ~= expected_sizes[filename] then
                    return fail("state member size does not match manifest: " .. tostring(filename))
                end
                members[filename] = data
                local value, parse_err = parse_json_member(filename, data)
                if parse_err then
                    return fail(parse_err)
                end
                if json_files[filename] then
                    parsed_json[filename] = value
                end
            end
        end
    end
    for filename in pairs(expected_sizes) do
        if members[filename] == nil then
            return fail("state member listed in manifest is missing: " .. tostring(filename))
        end
    end
    for filename in pairs(members) do
        if expected_sizes[filename] == nil then
            return fail("state member is not listed in manifest: " .. tostring(filename))
        end
    end
    local bundle = {
        members = members,
        parsed_json = parsed_json,
        manifest = manifest,
    }
    bundle.summary = function(self)
        return summary_for(self)
    end
    return bundle
end

function Backup.import_archive(filename, state_root)
    local bundle, err = Backup.read_archive(filename)
    if not bundle then
        return fail(err)
    end
    local result, import_err = Backup.materialize(bundle, state_root)
    if not result then
        return fail(import_err)
    end
    result.source = filename
    return result
end

function Backup.export_state(state_root, filename)
    local bundle, err = Backup.read_state(state_root)
    if not bundle then
        return fail(err)
    end
    local ok, write_err = Backup.write_archive(bundle, filename)
    if not ok then
        return fail(write_err)
    end
    return {
        destination = filename,
        summary = summary_for(bundle),
    }
end

function Backup.default_state_root()
    return DataStorage:getDataDir() .. "/legado/state"
end

return Backup
