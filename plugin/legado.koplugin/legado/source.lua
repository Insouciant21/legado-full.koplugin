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

local CATEGORY_IDS = {
    all = "all",
    read = "read",
    unread = "unread",
}

function SourceCatalog:categories()
    -- Categories are deliberately plugin-owned. Android's bookGroup.json and
    -- the `group` bitmask are not part of the Kindle bookshelf model.
    return {
        { id = CATEGORY_IDS.all },
        { id = CATEGORY_IDS.read },
        { id = CATEGORY_IDS.unread },
    }
end

function SourceCatalog:books_for_category(books, category_id, reading_status)
    local selected = {}
    if type(books) ~= "table" then return selected end
    for index, book in ipairs(books) do
        local include = category_id == CATEGORY_IDS.all
        if category_id == CATEGORY_IDS.read then
            include = reading_status and reading_status[index] == true
        elseif category_id == CATEGORY_IDS.unread then
            include = not (reading_status and reading_status[index] == true)
        end
        if include then
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
            if lowered:find("@js:", 1, true)
                    or lowered:find("@webjs:", 1, true)
                    or lowered:find("<js>", 1, true)
                    or lowered:find("java.", 1, true) then
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
