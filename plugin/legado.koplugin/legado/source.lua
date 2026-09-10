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

local function book_text(book, ...)
    if type(book) ~= "table" then return "" end
    for _, key in ipairs({...}) do
        local value = book[key]
        if value ~= nil and tostring(value) ~= "" then
            return tostring(value)
        end
    end
    return ""
end

local function same_book_name_author(left, right)
    local left_name = book_text(left, "name", "bookName")
    local right_name = book_text(right, "name", "bookName")
    if left_name == "" or right_name == "" or left_name ~= right_name then
        return false
    end
    local left_author = book_text(left, "author", "bookAuthor")
    local right_author = book_text(right, "author", "bookAuthor")
    return left_author == "" or right_author == ""
        or left_author == right_author
end

function SourceCatalog:find_book_index(book)
    local books, err = self:books()
    if not books then return nil, err end
    if type(book) ~= "table" then return nil, "book must be an object" end

    -- Prefer source-independent IDs and exact URLs. This keeps the detail
    -- page usable when it was opened from a chapter menu whose book table was
    -- freshly enriched by bookInfo.
    local id = book_text(book, "id", "bookId")
    if id ~= "" then
        for index, candidate in ipairs(books) do
            if book_text(candidate, "id", "bookId") == id then
                return index
            end
        end
    end
    local url = book_text(book, "bookUrl")
    if url ~= "" then
        for index, candidate in ipairs(books) do
            if book_text(candidate, "bookUrl") == url then
                return index
            end
        end
    end

    -- A source change gives the book a new bookUrl. Match the stable display
    -- identity next, but keep origin in the first pass so duplicate titles
    -- from different sources do not select the wrong shelf entry.
    local origin = book_text(book, "origin", "bookSourceUrl", "sourceUrl")
    for index, candidate in ipairs(books) do
        if same_book_name_author(book, candidate)
                and (origin == ""
                    or book_text(candidate, "origin", "bookSourceUrl", "sourceUrl") == origin) then
            return index
        end
    end

    -- Finally accept a unique title/author match. This is needed for imported
    -- bookInfo results that omit origin fields, but never guess between two
    -- identical shelf entries.
    local match
    for index, candidate in ipairs(books) do
        if same_book_name_author(book, candidate) then
            if match then return nil, "multiple bookshelf entries match this book" end
            match = index
        end
    end
    return match, match and nil or "book is not in the bookshelf"
end

local CATEGORY_IDS = {
    all = "all",
    reading = "reading",
    read = "read",
    unread = "unread",
}

function SourceCatalog:categories()
    -- Categories are deliberately plugin-owned. Android's bookGroup.json and
    -- the `group` bitmask are not part of the Kindle bookshelf model.
    return {
        { id = CATEGORY_IDS.all },
        { id = CATEGORY_IDS.reading },
        { id = CATEGORY_IDS.unread },
        { id = CATEGORY_IDS.read },
    }
end

function SourceCatalog:books_for_category(books, category_id, reading_status)
    local selected = {}
    if type(books) ~= "table" then return selected end
    for index, book in ipairs(books) do
        local include = category_id == CATEGORY_IDS.all
        if category_id ~= CATEGORY_IDS.all then
            local status = reading_status and reading_status[index]
                or CATEGORY_IDS.unread
            include = status == category_id
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

function SourceCatalog:move_source(index, destination)
    local sources, err = self:list()
    if not sources then
        return nil, err
    end
    if type(index) ~= "number" or index < 1 or index > #sources then
        return nil, "book source index is out of range"
    end
    destination = tostring(destination or "")
    if destination ~= "top" and destination ~= "bottom" then
        return nil, "invalid source destination"
    end
    if #sources < 2 or (destination == "top" and index == 1)
            or (destination == "bottom" and index == #sources) then
        return true
    end

    -- Keep the imported array order authoritative. Android also stores a
    -- customOrder, but older source packs often omit it; moving the actual
    -- array entry makes the result deterministic on Kindle and survives a
    -- later source export/import without requiring another ranking database.
    local updated = {}
    local moved = sources[index]
    local min_order
    local max_order
    for _, source in ipairs(sources) do
        local order = tonumber(source and source.customOrder)
        if order then
            min_order = min_order and math.min(min_order, order) or order
            max_order = max_order and math.max(max_order, order) or order
        end
    end
    if destination == "top" then
        moved.customOrder = (min_order or 0) - 1
    else
        moved.customOrder = (max_order or (#sources - 1)) + 1
    end
    local position = 0
    for current, source in ipairs(sources) do
        if current ~= index then
            position = position + 1
            updated[position] = source
        end
    end
    if destination == "top" then
        table.insert(updated, 1, moved)
    else
        updated[#updated + 1] = moved
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
