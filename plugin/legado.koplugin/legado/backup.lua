-- Legado Android backup import for the on-device Kindle runtime.
--
-- This is intentionally an import-only boundary.  The Android archive is
-- allowed to contain many settings, but the Kindle state keeps only the data
-- that this plugin can use: sources, bookshelf, groups and reading history.
-- KOReader owns every reading presentation option.

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local util = require("util")

local Backup = {}

Backup.STATE_SCHEMA_VERSION = 2
Backup.STATE_FORMAT = "legado-imported-data"

Backup.IMPORT_MEMBERS = {
    "bookSource.json",
    "bookshelf.json",
    "bookGroup.json",
    "readRecord.json",
    "readRecordDetail.json",
    "readRecordSession.json",
}

local import_members = {}
local core_members = {}
local record_members = {}
for _, filename in ipairs(Backup.IMPORT_MEMBERS) do
    import_members[filename] = true
end
for _, filename in ipairs({ "bookSource.json", "bookshelf.json", "bookGroup.json" }) do
    core_members[filename] = true
end
for _, filename in ipairs({ "readRecord.json", "readRecordDetail.json", "readRecordSession.json" }) do
    record_members[filename] = true
end

local function fail(message)
    return nil, message
end

local function is_safe_member_name(name)
    -- Android's current format is flat. Rejecting nested names also prevents
    -- ignored future ZIP members from becoming a path traversal vector.
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

local function sanitize_bookshelf(value)
    if type(value) ~= "table" then
        return nil, "bookshelf.json must be a JSON array"
    end
    local result = rapidjson.array()
    for index, book in ipairs(value) do
        if type(book) == "table" then
            local copy = {}
            for key, child in pairs(book) do
                -- Android ReadConfig contains font, colors, spacing, CSS and
                -- other UI state. It must not cross into KOReader.
                if key ~= "readConfig" then
                    copy[key] = child
                end
            end
            result[index] = copy
        else
            result[index] = book
        end
    end
    return result
end

local function parse_json_member(filename, data)
    local ok, value = pcall(rapidjson.decode, data)
    if not ok or type(value) ~= "table" then
        return nil, filename .. " is not a valid JSON collection: " .. tostring(value)
    end
    if filename == "bookshelf.json" then
        return sanitize_bookshelf(value)
    end
    return value
end

local function count_collection(value)
    if type(value) ~= "table" then return 0 end
    if value.bookName ~= nil or value.bookAuthor ~= nil then return 1 end
    return #value
end

local function sorted_member_names(members)
    local names = {}
    for _, filename in ipairs(Backup.IMPORT_MEMBERS) do
        if members[filename] ~= nil then
            names[#names + 1] = filename
        end
    end
    return names
end

local function summary_for(bundle)
    local parsed = bundle.parsed_json or {}
    local sources = type(parsed["bookSource.json"]) == "table"
        and parsed["bookSource.json"] or {}
    local books = type(parsed["bookshelf.json"]) == "table"
        and parsed["bookshelf.json"] or {}
    local groups = type(parsed["bookGroup.json"]) == "table"
        and parsed["bookGroup.json"] or {}
    local counts = bundle.record_counts or {}
    if bundle.manifest and bundle.manifest.summary
            and type(bundle.manifest.summary.counts) == "table" then
        local stored = bundle.manifest.summary.counts
        for _, key in ipairs({
            "read_records", "read_record_details", "read_record_sessions",
        }) do
            if counts[key] == nil then counts[key] = tonumber(stored[key]) or 0 end
        end
    end
    return {
        member_count = #sorted_member_names(bundle.members),
        counts = {
            book_sources = #sources,
            bookshelf_books = #books,
            book_groups = #groups,
            read_records = counts.read_records or 0,
            read_record_details = counts.read_record_details or 0,
            read_record_sessions = counts.read_record_sessions or 0,
            ignored_members = tonumber(bundle.ignored_members) or 0,
        },
    }
end

local function bind_bundle(bundle)
    bundle.summary = function(self)
        return summary_for(self)
    end
    return bundle
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
    local record_counts = {}
    local ignored_members = 0
    for entry in reader:iterate() do
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            reader:close()
            return fail("backup contains an invalid member: " .. tostring(entry.path))
        end
        if not is_safe_member_name(entry.path) then
            reader:close()
            return fail("unsafe backup member name: " .. tostring(entry.path))
        end
        if entry.mode == "directory" then
            -- Directories are not data members and are harmless to ignore.
        elseif not import_members[entry.path] then
            -- Do not extract or parse Android-only settings. This is important
            -- for the large read/UI files and for malformed future members.
            ignored_members = ignored_members + 1
        elseif members[entry.path] ~= nil then
            reader:close()
            return fail("duplicate backup member: " .. tostring(entry.path))
        else
            local data = reader:extractToMemory(entry.path)
            if data == nil then
                local message = reader.err or "cannot read backup member: " .. tostring(entry.path)
                reader:close()
                return fail(message)
            end
            local value, parse_err = parse_json_member(entry.path, data)
            if parse_err then
                reader:close()
                return fail(parse_err)
            end
            members[entry.path] = data
            if core_members[entry.path] then
                -- Keep the sanitized bookshelf bytes as the state source of
                -- truth; source and group bytes retain their complete schema.
                if entry.path == "bookshelf.json" then
                    local encoded_ok, encoded = pcall(rapidjson.encode, value)
                    if not encoded_ok or type(encoded) ~= "string" then
                        reader:close()
                        return fail("cannot normalize bookshelf.json")
                    end
                    members[entry.path] = encoded
                end
                parsed_json[entry.path] = value
            elseif record_members[entry.path] then
                record_counts[entry.path == "readRecord.json" and "read_records"
                    or entry.path == "readRecordDetail.json" and "read_record_details"
                    or "read_record_sessions"] = count_collection(value)
                -- Do not retain the largest record collection in the bundle;
                -- it is stored as bytes and imported later by a worker.
                value = nil
                collectgarbage("step")
            end
        end
    end
    reader:close()

    for _, name in ipairs(Backup.IMPORT_MEMBERS) do
        if members[name] == nil then
            return fail("backup is missing required member: " .. name)
        end
    end
    return bind_bundle{
        members = members,
        parsed_json = parsed_json,
        record_counts = record_counts,
        ignored_members = ignored_members,
        source = filename,
    }
end

local function make_manifest(bundle)
    local members = {}
    for _, filename in ipairs(Backup.IMPORT_MEMBERS) do
        members[#members + 1] = {
            name = filename,
            size = #bundle.members[filename],
            kind = "json",
        }
    end
    return {
        state_schema_version = Backup.STATE_SCHEMA_VERSION,
        format = Backup.STATE_FORMAT,
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
    util.makePath(staging)

    local ok, message = true, nil
    for _, filename in ipairs(Backup.IMPORT_MEMBERS) do
        if not is_safe_member_name(filename) or not import_members[filename] then
            ok = false
            message = "unsafe state member name: " .. tostring(filename)
            break
        end
        local written, err = write_file(staging .. "/" .. filename, bundle.members[filename])
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
        if previous then os.rename(previous, state_root) end
        remove_tree(staging)
        return fail("cannot activate imported state directory")
    end

    -- The old state can contain Android reader settings. Remove it after the
    -- new state is active so those settings cannot be accidentally reused.
    if previous then remove_tree(previous) end
    return {
        state_root = state_root,
        summary = summary_for(bundle),
    }
end

local function read_manifest(state_root)
    local data, err = read_file(state_root .. "/manifest.json")
    if not data then return fail(err) end
    local ok, manifest = pcall(rapidjson.decode, data)
    if not ok or type(manifest) ~= "table" then
        return fail("invalid Legado state manifest")
    end
    return manifest
end

local function read_legacy_state(state_root, manifest)
    local android_root = state_root .. "/android"
    if lfs.attributes(android_root, "mode") ~= "directory" then
        return fail("legacy state has no android member directory")
    end
    local members = {}
    local parsed_json = {}
    local record_counts = {}
    local expected_sizes = {}
    if type(manifest.members) == "table" then
        for _, info in ipairs(manifest.members) do
            if type(info) == "table" and is_safe_member_name(info.name) then
                expected_sizes[info.name] = tonumber(info.size)
            end
        end
    end
    for _, filename in ipairs(Backup.IMPORT_MEMBERS) do
        local path = android_root .. "/" .. filename
        local data, err = read_file(path)
        if not data then return fail(err) end
        if expected_sizes[filename] and expected_sizes[filename] ~= #data then
            return fail("legacy state member size does not match manifest: " .. filename)
        end
        local value, parse_err = parse_json_member(filename, data)
        if parse_err then return fail(parse_err) end
        if filename == "bookshelf.json" then
            local encoded_ok, encoded = pcall(rapidjson.encode, value)
            if not encoded_ok or type(encoded) ~= "string" then
                return fail("cannot normalize legacy bookshelf.json")
            end
            data = encoded
            parsed_json[filename] = value
        elseif core_members[filename] then
            parsed_json[filename] = value
        else
            record_counts[filename == "readRecord.json" and "read_records"
                or filename == "readRecordDetail.json" and "read_record_details"
                or "read_record_sessions"] = count_collection(value)
            value = nil
            collectgarbage("step")
        end
        members[filename] = data
    end
    return bind_bundle{
        members = members,
        parsed_json = parsed_json,
        record_counts = record_counts,
        manifest = manifest,
        legacy = true,
    }
end

function Backup.read_state(state_root)
    local manifest, err = read_manifest(state_root)
    if not manifest then return fail(err) end

    -- v1 was the temporary migration format. Read its six useful members once
    -- so Storage can compact it immediately; no old Android setting is kept.
    if manifest.state_schema_version == 1
            and manifest.format == "legado-android-backup" then
        return read_legacy_state(state_root, manifest)
    end
    if manifest.state_schema_version ~= Backup.STATE_SCHEMA_VERSION then
        return fail("unsupported Legado state schema")
    end
    if manifest.format ~= Backup.STATE_FORMAT then
        return fail("unsupported Legado state format")
    end

    local expected = {}
    if type(manifest.members) ~= "table" then
        return fail("state manifest has no member list")
    end
    for _, info in ipairs(manifest.members) do
        if type(info) ~= "table" or not is_safe_member_name(info.name)
                or not import_members[info.name] then
            return fail("state manifest has an unsupported member")
        end
        if expected[info.name] ~= nil then
            return fail("duplicate state member in manifest: " .. tostring(info.name))
        end
        local size = tonumber(info.size)
        if size == nil or size < 0 or size % 1 ~= 0 or info.kind ~= "json" then
            return fail("invalid state member metadata: " .. tostring(info.name))
        end
        expected[info.name] = size
    end
    for _, filename in ipairs(Backup.IMPORT_MEMBERS) do
        if expected[filename] == nil then
            return fail("state manifest is missing member: " .. filename)
        end
    end

    local allowed = { ["manifest.json"] = true }
    for filename in pairs(import_members) do allowed[filename] = true end
    for filename in lfs.dir(state_root) do
        if filename ~= "." and filename ~= ".." and not allowed[filename] then
            return fail("state contains an unsupported member: " .. tostring(filename))
        end
    end

    local members = {}
    local parsed_json = {}
    for _, filename in ipairs(Backup.IMPORT_MEMBERS) do
        local path = state_root .. "/" .. filename
        local data, read_err = read_file(path)
        if not data then return fail(read_err) end
        if #data ~= expected[filename] then
            return fail("state member size does not match manifest: " .. filename)
        end
        members[filename] = data
        if core_members[filename] then
            local value, parse_err = parse_json_member(filename, data)
            if parse_err then return fail(parse_err) end
            parsed_json[filename] = value
        end
    end
    return bind_bundle{
        members = members,
        parsed_json = parsed_json,
        record_counts = {},
        manifest = manifest,
    }
end

function Backup.compact_legacy_state(state_root)
    local manifest = read_manifest(state_root)
    if not manifest then
        -- No state yet is normal on a fresh installation.
        return true
    end
    if manifest.state_schema_version ~= 1
            or manifest.format ~= "legado-android-backup" then
        return true
    end
    local bundle, err = Backup.read_state(state_root)
    if not bundle then return nil, err end
    local result, materialize_err = Backup.materialize(bundle, state_root)
    if not result then return nil, materialize_err end
    return true
end

function Backup.update_json_member(state_root, filename, value)
    if not import_members[filename] then
        return fail("member is not an imported JSON file: " .. tostring(filename))
    end
    if type(value) ~= "table" then
        return fail("JSON member must be a collection: " .. tostring(filename))
    end
    if filename == "bookshelf.json" then
        local sanitized, sanitize_err = sanitize_bookshelf(value)
        if not sanitized then return fail(sanitize_err) end
        value = sanitized
    end
    local bundle, err = Backup.read_state(state_root)
    if not bundle then return fail(err) end
    local encoded_ok, encoded = pcall(rapidjson.encode, value)
    if not encoded_ok or type(encoded) ~= "string" then
        return fail("cannot encode JSON member: " .. tostring(filename))
    end
    bundle.members[filename] = encoded
    bundle.parsed_json[filename] = value
    local result, materialize_err = Backup.materialize(bundle, state_root)
    if not result then return fail(materialize_err) end
    result.member = filename
    return result
end

function Backup.import_archive(filename, state_root)
    local bundle, err = Backup.read_archive(filename)
    if not bundle then return fail(err) end
    local result, import_err = Backup.materialize(bundle, state_root)
    if not result then return fail(import_err) end
    result.source = filename
    return result
end

function Backup.default_state_root()
    return DataStorage:getDataDir() .. "/legado/state"
end

return Backup
