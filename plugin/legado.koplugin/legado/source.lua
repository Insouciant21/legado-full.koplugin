-- Source catalog and capability reporting for Android bookSource.json data.

local Backup = require("legado/backup")
local rapidjson = require("rapidjson")

local SourceCatalog = {}
SourceCatalog.__index = SourceCatalog

local function walk_strings(value, callback)
    if type(value) == "string" then
        callback(value)
    elseif type(value) == "table" then
        for _, child in pairs(value) do
            walk_strings(child, callback)
        end
    end
end

local function has_prefix(value, prefix)
    return value:sub(1, #prefix):lower() == prefix:lower()
end

function SourceCatalog:new(state_root)
    return setmetatable({
        state_root = state_root,
        bundle = nil,
    }, self)
end

function SourceCatalog:load()
    local bundle, err = Backup.read_state(self.state_root)
    if not bundle then
        return nil, err
    end
    self.bundle = bundle
    local sources = bundle.parsed_json["bookSource.json"]
    if type(sources) ~= "table" then
        return nil, "bookSource.json is not an array"
    end
    return sources
end

function SourceCatalog:list()
    if self.bundle == nil then
        local sources, err = self:load()
        if not sources then
            return nil, err
        end
    end
    return self.bundle.parsed_json["bookSource.json"]
end

function SourceCatalog:books()
    if self.bundle == nil then
        local sources, err = self:load()
        if not sources then
            return nil, err
        end
    end
    local books = self.bundle.parsed_json["bookshelf.json"]
    if type(books) ~= "table" then
        return nil, "bookshelf.json is not an array"
    end
    return books
end

function SourceCatalog:groups()
    if self.bundle == nil then
        local sources, err = self:load()
        if not sources then return nil, err end
    end
    local groups = self.bundle.parsed_json["bookGroup.json"]
    if type(groups) ~= "table" then
        return nil, "bookGroup.json is not an array"
    end
    return groups
end

local function group_id(group)
    if type(group) ~= "table" then return nil end
    return tonumber(group.groupId or group.id or group.groupID)
end

local function value_has_id(value, wanted)
    if value == nil or wanted == nil then return false end
    if type(value) == "table" then
        for _, child in pairs(value) do
            if value_has_id(child, wanted) then return true end
        end
        return false
    end
    local numeric_value = tonumber(value)
    local numeric_wanted = tonumber(wanted)
    if numeric_value and numeric_wanted then
        -- Legado stores custom group membership as a sum of power-of-two
        -- group IDs (the same representation used by its SQLite `group &
        -- groupId` query).  Arithmetic keeps this working for IDs above the
        -- 32-bit range, where LuaJIT's bit library would truncate the value.
        if numeric_wanted > 0 and numeric_value >= 0 then
            return math.floor(numeric_value / numeric_wanted) % 2 == 1
        end
        return numeric_value == numeric_wanted
    end
    local text = tostring(value)
    if text == tostring(wanted) then return true end
    for token in text:gmatch("[^,%s;]+") do
        if token == tostring(wanted) then return true end
    end
    return false
end

local function book_type(book)
    return tonumber(book and book.type or 0) or 0
end

-- BookType values are flags, not an enum.  Current Legado uses text=8,
-- updateError=16, audio=32, image=64 and local=256; older exports used a few
-- smaller enum-like values, so the individual group cases below retain those
-- fallbacks too.
local TYPE_VIDEO = 4
local TYPE_TEXT = 8
local TYPE_UPDATE_ERROR = 16
local TYPE_AUDIO = 32
local TYPE_IMAGE = 64
local TYPE_LOCAL = 256

local function has_book_type(book, flag)
    local kind = book_type(book)
    if kind < 0 or flag <= 0 then return false end
    return math.floor(kind / flag) % 2 == 1
end

local function is_local_book(book)
    local origin = tostring(book and book.origin or ""):lower()
    return has_book_type(book, TYPE_LOCAL)
        or origin == "local"
        or origin == "localbook"
        or origin == "file"
        or origin:sub(1, 8) == "loc_book"
end

local function is_text_book(book)
    -- A missing/zero type is the old text representation.  Current Legado
    -- uses the text flag, which also makes type 24 (text + update error) a
    -- text book.
    return book_type(book) == 0 or has_book_type(book, TYPE_TEXT)
end

local function has_started_reading(book)
    return (tonumber(book and book.durChapterIndex) or 0) > 0
        or (tonumber(book and book.durChapterPos) or 0) > 0
end

local function is_complete_book(book)
    if book and book.canUpdate == false then return true end
    local total = tonumber(book and book.totalChapterNum) or 0
    local current = tonumber(book and book.durChapterIndex)
    return total > 0 and current ~= nil and current + 1 >= total
end

local function has_custom_group(book)
    local value = book and (book.group or book.groupId or book.bookGroupId)
    if value == nil then return false end
    if type(value) == "table" then
        for _, child in pairs(value) do
            if tonumber(child) and tonumber(child) > 0 then return true end
        end
        return false
    end
    local number = tonumber(value)
    if number then return number > 0 end
    for token in tostring(value):gmatch("[^,%s;]+") do
        if tonumber(token) and tonumber(token) > 0 then return true end
    end
    return false
end

function SourceCatalog:book_matches_group(book, group)
    if type(book) ~= "table" or type(group) ~= "table" then return false end
    local wanted = group_id(group)
    if wanted == nil then return false end

    -- Legado's negative IDs are built-in dynamic groups. Positive IDs are
    -- user groups and are matched against the book's stored group field.
    if wanted >= 0 then
        return value_has_id(book.group or book.groupId or book.bookGroupId, wanted)
    elseif wanted == -1 then
        return true
    elseif wanted == -2 then
        return is_local_book(book)
    elseif wanted == -3 then
        return has_book_type(book, TYPE_AUDIO) or book_type(book) == 1
    elseif wanted == -4 then
        return not is_local_book(book)
            and not has_book_type(book, TYPE_AUDIO)
            and not has_book_type(book, TYPE_VIDEO)
            and not has_custom_group(book)
    elseif wanted == -5 then
        return is_local_book(book) and not has_custom_group(book)
    elseif wanted == -6 then
        return has_book_type(book, TYPE_VIDEO)
    elseif wanted == -7 then
        return has_book_type(book, TYPE_IMAGE) or book_type(book) == 2
    elseif wanted == -8 then
        return is_text_book(book)
    elseif wanted == -11 then
        return has_book_type(book, TYPE_UPDATE_ERROR)
            or (tonumber(book.lastCheckCount) or 0) < 0
    elseif wanted == -20 then
        return has_started_reading(book) and not is_complete_book(book)
    elseif wanted == -21 then
        return not has_started_reading(book)
    elseif wanted == -22 then
        return has_started_reading(book)
    elseif wanted == -23 then
        return has_started_reading(book) and not is_complete_book(book)
    elseif wanted == -24 then
        return has_started_reading(book) and is_complete_book(book)
    end
    return false
end

function SourceCatalog:books_for_group(books, group)
    local selected = {}
    if type(books) ~= "table" then return selected end
    for index, book in ipairs(books) do
        if self:book_matches_group(book, group) then
            selected[#selected + 1] = { book = book, index = index }
        end
    end
    return selected
end

function SourceCatalog:find_by_url(source_url)
    local sources, err = self:list()
    if not sources then
        return nil, err
    end
    for _, source in ipairs(sources) do
        if source.bookSourceUrl == source_url then
            return source
        end
    end
    return nil, "book source not found"
end

function SourceCatalog:find_for_book(book)
    local sources, err = self:list()
    if not sources then
        return nil, err
    end
    local origin = type(book) == "table" and (book.origin or book.bookSourceUrl) or nil
    local origin_name = type(book) == "table" and book.originName or nil
    for _, source in ipairs(sources) do
        if tonumber(source.bookSourceType or 0) == 0
                and origin and source.bookSourceUrl == origin then
            return source
        end
    end
    if origin_name and origin_name ~= "" then
        for _, source in ipairs(sources) do
            if tonumber(source.bookSourceType or 0) == 0 and source.bookSourceName == origin_name then
                return source
            end
        end
    end
    return nil, "book source for bookshelf entry not found"
end

function SourceCatalog:replace_sources(sources)
    if type(sources) ~= "table" then
        return nil, "book sources must be an array"
    end
    -- rapidjson treats a plain empty Lua table as an object. Preserve the
    -- Android bookSource.json array shape when the last source is removed.
    local encoded_sources = sources
    if #sources == 0 then
        encoded_sources = rapidjson.array()
    end
    local result, err = Backup.update_json_member(
        self.state_root,
        "bookSource.json",
        encoded_sources
    )
    if not result then
        return nil, err
    end
    -- The old bundle contains the old member bytes and manifest. Force a
    -- reload so a source action immediately sees the edited list.
    self.bundle = nil
    return true
end

function SourceCatalog:replace_books(books)
    if type(books) ~= "table" then
        return nil, "bookshelf must be an array"
    end
    local encoded_books = books
    if #books == 0 then encoded_books = rapidjson.array() end
    local result, err = Backup.update_json_member(
        self.state_root,
        "bookshelf.json",
        encoded_books
    )
    if not result then return nil, err end
    self.bundle = nil
    return true
end

function SourceCatalog:update_book(index, book)
    local books, err = self:books()
    if not books then return nil, err end
    if type(index) ~= "number" or index < 1 or index > #books then
        return nil, "book index is out of range"
    end
    if type(book) ~= "table" then return nil, "book must be an object" end
    local updated = {}
    for position, value in ipairs(books) do updated[position] = value end
    updated[index] = book
    return self:replace_books(updated)
end

function SourceCatalog:update_source(index, source)
    local sources, err = self:list()
    if not sources then
        return nil, err
    end
    if type(index) ~= "number" or index < 1 or index > #sources then
        return nil, "book source index is out of range"
    end
    if type(source) ~= "table" then
        return nil, "book source must be an object"
    end
    local updated = {}
    for position, value in ipairs(sources) do
        updated[position] = value
    end
    updated[index] = source
    return self:replace_sources(updated)
end

function SourceCatalog:remove_source(index)
    local sources, err = self:list()
    if not sources then
        return nil, err
    end
    if type(index) ~= "number" or index < 1 or index > #sources then
        return nil, "book source index is out of range"
    end
    local updated = {}
    for position, value in ipairs(sources) do
        if position ~= index then
            updated[#updated + 1] = value
        end
    end
    return self:replace_sources(updated)
end

function SourceCatalog:compatibility()
    local sources, err = self:list()
    if not sources then
        return nil, err
    end

    local report = {
        source_count = #sources,
        text_source_count = 0,
        css = 0,
        json = 0,
        regex = 0,
        replacements = 0,
        templates = 0,
        javascript = 0,
        xpath = 0,
        sources_with_javascript = 0,
        sources_with_xpath = 0,
    }
    for _, source in ipairs(sources) do
        if tonumber(source.bookSourceType or 0) == 0 then
            report.text_source_count = report.text_source_count + 1
        end
        local source_has_js = false
        local source_has_xpath = false
        if type(source.ruleContent) == "table"
                and type(source.ruleContent.replaceRegex) == "string"
                and source.ruleContent.replaceRegex ~= "" then
            report.replacements = report.replacements + 1
        end
        walk_strings(source, function(value)
            local lowered = value:lower()
            if lowered:find("@css:", 1, true) or has_prefix(value, "@@") then
                report.css = report.css + 1
            end
            if lowered:find("@json:", 1, true) or has_prefix(value, "$.") or has_prefix(value, "$[") then
                report.json = report.json + 1
            end
            if lowered:find("@regex:", 1, true) or has_prefix(value, ":") then
                report.regex = report.regex + 1
            end
            if value:find("{{", 1, true) and value:find("}}", 1, true) then
                report.templates = report.templates + 1
            end
            if has_prefix(value, "@js:") or has_prefix(value, "@webjs:") or has_prefix(value, "<js>") or lowered:find("java.", 1, true) then
                report.javascript = report.javascript + 1
                source_has_js = true
            end
            -- Do not classify protocol-relative URLs (also beginning with
            -- //) as XPath in the summary.  The evaluator still rejects
            -- unmarked XPath when it is actually used as a rule.
            if has_prefix(value, "@xpath:") then
                report.xpath = report.xpath + 1
                source_has_xpath = true
            end
        end)
        if source_has_js then
            report.sources_with_javascript = report.sources_with_javascript + 1
        end
        if source_has_xpath then
            report.sources_with_xpath = report.sources_with_xpath + 1
        end
    end
    return report
end

return SourceCatalog
