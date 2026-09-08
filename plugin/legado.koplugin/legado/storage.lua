local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Backup = require("legado/backup")
local Content = require("legado/content")
local LuaSettings = require("luasettings")
local rapidjson = require("rapidjson")

local Storage = {}
Storage.__index = Storage

local function default_state()
    return {
        schema_version = Backup.STATE_SCHEMA_VERSION,
        sources = 0,
        books = 0,
        last_backup = nil,
    }
end

function Storage:new()
    local object = setmetatable({}, self)
    object.root = DataStorage:getDataDir() .. "/legado"
    object.state_root = object.root .. "/state"
    object.library_root = object.root .. "/library"
    object.progress_path = object.root .. "/reading-progress.lua"
    object.progress_settings = nil
    object.history_path = object.root .. "/reading-history.lua"
    object.history_settings = nil
    object.reader_session_path = object.root .. "/reading-session.lua"
    object.reader_session_settings = nil
    object.settings_path = object.root .. "/settings.lua"
    object.settings = nil
    if lfs.attributes(object.root, "mode") ~= "directory" then
        lfs.mkdir(object.root)
    end
    -- The previous implementation used reading-settings.lua for per-book
    -- font/layout/CSS profiles. Those settings compete with KOReader and are
    -- intentionally discarded. Keep only the plugin-owned prefetch count.
    local legacy_preferences = object.root .. "/reading-settings.lua"
    local legacy_prefetch
    if lfs.attributes(legacy_preferences, "mode") == "file" then
        local ok, old_settings = pcall(LuaSettings.open, LuaSettings, legacy_preferences)
        if ok and old_settings then
            legacy_prefetch = tonumber(old_settings:readSetting("prefetch_count"))
        end
        os.remove(legacy_preferences)
    end
    os.remove(legacy_preferences .. ".old")
    if legacy_prefetch then
        object.settings = LuaSettings:open(object.settings_path)
        object.settings:saveSetting("prefetch_count", math.max(5, math.min(10, math.floor(legacy_prefetch))))
        object.settings:flush()
    end
    -- Compact the temporary v1 state once. This removes the old android/
    -- directory, including Android UI settings that must never be reused.
    local compacted, compact_error = Backup.compact_legacy_state(object.state_root)
    if not compacted then
        object.legacy_migration_error = compact_error
    end
    return object
end

function Storage:read_state()
    if self.legacy_migration_error then
        local value = default_state()
        value.error = self.legacy_migration_error
        return value
    end
    local bundle, err = Backup.read_state(self.state_root)
    if not bundle then
        local value = default_state()
        value.error = err
        return value
    end
    local summary = bundle:summary()
    local counts = summary.counts or {}
    return {
        schema_version = Backup.STATE_SCHEMA_VERSION,
        sources = counts.book_sources or 0,
        books = counts.bookshelf_books or 0,
        members = summary.member_count or 0,
        groups = counts.book_groups or 0,
        read_records = counts.read_records or 0,
        read_record_details = counts.read_record_details or 0,
        read_record_sessions = counts.read_record_sessions or 0,
        imported_at = bundle.manifest and bundle.manifest.imported_at or nil,
    }
end

function Storage:get_root()
    return self.root
end

function Storage:get_state_root()
    return self.state_root
end

function Storage:get_default_path()
    return DataStorage:getDataDir()
end

local function truncate_utf8(value, max_bytes)
    -- Lua's string.sub counts bytes. Stop at a complete codepoint so an
    -- emoji or CJK character is never split when a long title becomes a path.
    local position = 1
    local last = 0
    while position <= #value do
        local byte = value:byte(position)
        local width = 1
        if byte >= 0xc2 and byte <= 0xdf then
            width = 2
        elseif byte >= 0xe0 and byte <= 0xef then
            width = 3
        elseif byte >= 0xf0 and byte <= 0xf4 then
            width = 4
        end
        if position + width - 1 > max_bytes then break end
        last = position + width - 1
        position = position + width
    end
    return value:sub(1, last)
end

local function safe_name(value)
    -- Keep Unicode, including emoji, in the cache name.  The filesystem and
    -- KOReader both support UTF-8 paths; the plugin supplies a rendering font
    -- instead of silently changing a book or chapter title.
    local name = tostring(value or "book")
        :gsub("[/\\:*?\"<>|]", "_")
    name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "book" end
    return truncate_utf8(name, 80)
end

local function book_key(book)
    if type(book) ~= "table" then return tostring(book or "") end
    return tostring(book.id or book.bookUrl or book.bookSourceUrl or book.name or "")
end

function Storage:get_book_dir(book)
    return self.library_root .. "/" .. safe_name(book and book.name)
end

function Storage:get_chapter_path(book, chapter)
    local index = tonumber(chapter and chapter.index or 1) or 1
    return self:get_book_dir(book) .. "/"
        -- TXT files are treated as preformatted/monospace by KOReader's CRe
        -- provider.  A standalone HTML chapter keeps the text source-only,
        -- while allowing KOReader's normal selected font to apply to body
        -- paragraphs without any plugin-owned reader setting.
        .. string.format("%04d-%s.html", index, safe_name(chapter and chapter.name))
end

function Storage:get_legacy_chapter_path(book, chapter)
    local index = tonumber(chapter and chapter.index or 1) or 1
    return self:get_book_dir(book) .. "/"
        .. string.format("%04d-%s.txt", index, safe_name(chapter and chapter.name))
end

function Storage:chapter_exists(book, chapter)
    local path = self:get_chapter_path(book, chapter)
    if lfs.attributes(path, "mode") == "file" then
        return true, path
    end
    -- Keep old downloads useful. chapter_is_readable() upgrades them to the
    -- HTML representation before a reader document is opened.
    local legacy_path = self:get_legacy_chapter_path(book, chapter)
    return lfs.attributes(legacy_path, "mode") == "file", legacy_path
end

local function html_body(raw)
    if type(raw) ~= "string" then return "" end
    local body = raw:match("<body[^>]*>(.-)</body%s*>")
    if not body then return raw end
    -- The generated document has a title heading which is already displayed
    -- by the reader header/session UI; don't duplicate it during bulk export.
    body = body:gsub("^%s*<h1[^>]*>.-</h1>%s*", "", 1)
    return body
end

local function legacy_body(raw, chapter)
    if type(raw) ~= "string" then return "" end
    local marker = "\n\n" .. (chapter and chapter.name or "") .. "\n\n"
    local _, marker_end = raw:find(marker, 1, true)
    if marker_end then
        return raw:sub(marker_end + 1)
    end
    return raw
end

function Storage:chapter_is_readable(book, chapter)
    local exists, path = self:chapter_exists(book, chapter)
    if not exists then return false, path end
    local content = util.readFromFile(path)
    if type(content) ~= "string" or content == "" then
        return false, path
    end
    if path:lower():sub(-5) == ".html" then
        return Content.to_text(html_body(content)) ~= "", path
    end

    -- Older plugin versions wrote readable prose to TXT, which makes CRe use
    -- its monospace/preformatted path. Convert that cache locally so opening
    -- an existing chapter also gets the native KOReader font behavior.
    if not Content.has_markup(content) then
        local migrated_path = self:write_chapter(book, chapter, legacy_body(content, chapter))
        if migrated_path then return true, migrated_path end
        -- A read-only or nearly-full filesystem should not make a cached
        -- chapter disappear; retain the old fallback for this one open.
        return true, path
    end
    -- Raw HTML in a legacy TXT cache is stale and must be downloaded again.
    return false, path
end

function Storage:get_progress_settings()
    if not self.progress_settings then
        self.progress_settings = LuaSettings:open(self.progress_path)
        if not self.progress_settings:has("books") then
            self.progress_settings:saveSetting("books", {})
            self.progress_settings:flush()
        end
    end
    return self.progress_settings
end

local function copy_session_value(value, depth)
    local value_type = type(value)
    if value == nil or value_type == "string" or value_type == "number"
            or value_type == "boolean" then
        return value
    end
    if value_type ~= "table" or (depth or 0) >= 5 then
        return nil
    end
    local result = {}
    for key, child in pairs(value) do
        local key_type = type(key)
        if key_type == "string" or key_type == "number" then
            local copied = copy_session_value(child, (depth or 0) + 1)
            if copied ~= nil then result[key] = copied end
        end
    end
    return result
end

local function history_part(value)
    value = tostring(value or "")
    return value:gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

local function history_key(name, author)
    return history_part(name) .. "\t" .. history_part(author)
end

local function as_epoch_seconds(value)
    local number = tonumber(value)
    if not number or number <= 0 then return 0 end
    -- Legado stores these timestamps in milliseconds; the local settings
    -- files use the Unix-second convention used by os.time().
    if number > 100000000000 then number = number / 1000 end
    return math.floor(number)
end

local function decode_record_collection(filename, data)
    local ok, value = pcall(rapidjson.decode, data)
    if not ok or type(value) ~= "table" then
        return nil, filename .. " is not a JSON collection"
    end
    return value
end

local function each_record(collection, callback)
    if type(collection) ~= "table" then return end
    -- Accept an object as well as the current Android array shape. This keeps
    -- the importer tolerant of old Legado exports without changing storage.
    if collection.bookName ~= nil or collection.bookAuthor ~= nil then
        callback(collection)
        return
    end
    for _, record in ipairs(collection) do
        if type(record) == "table" then callback(record) end
    end
end

local function merge_history_record(history, record, kind)
    local name = record.bookName or record.name or record.book_name
    local author = record.bookAuthor or record.author or record.book_author
    if not name or tostring(name) == "" then return end
    local key = history_key(name, author)
    local item = history[key]
    if not item then
        item = {
            name = tostring(name),
            author = tostring(author or ""),
            last_read = 0,
            read_time = 0,
            read_words = 0,
            session_count = 0,
            detail_count = 0,
        }
        history[key] = item
    end
    local timestamp = as_epoch_seconds(
        record.lastRead or record.lastReadTime or record.endTime or record.startTime
    )
    if timestamp > (item.last_read or 0) then item.last_read = timestamp end
    local read_time = tonumber(record.readTime) or 0
    local read_words = tonumber(record.readWords or record.words) or 0
    if kind == "readRecord" then
        -- readRecord is the Android aggregate for this book.
        if read_time > (item.read_time or 0) then item.read_time = read_time end
    elseif kind == "readRecordDetail" then
        item.detail_count = (item.detail_count or 0) + 1
        item.read_time_detail = (item.read_time_detail or 0) + read_time
        item.read_words_detail = (item.read_words_detail or 0) + read_words
    else
        item.session_count = (item.session_count or 0) + 1
        item.read_words_session = (item.read_words_session or 0) + read_words
    end
end

function Storage:get_history_settings()
    if not self.history_settings then
        self.history_settings = LuaSettings:open(self.history_path)
    end
    return self.history_settings
end

function Storage:import_reading_records()
    local bundle, err = Backup.read_state(self.state_root)
    if not bundle then return nil, err end
    local history = {}
    local history_books = 0
    local record_counts = {}
    local record_files = {
        { name = "readRecord.json", kind = "readRecord", count = "read_records" },
        { name = "readRecordDetail.json", kind = "readRecordDetail", count = "read_record_details" },
        { name = "readRecordSession.json", kind = "readRecordSession", count = "read_record_sessions" },
    }
    for _, item in ipairs(record_files) do
        local value, decode_err = decode_record_collection(item.name, bundle.members[item.name])
        if not value then return nil, decode_err end
        local count = 0
        each_record(value, function(record)
            count = count + 1
            merge_history_record(history, record, item.kind)
        end)
        record_counts[item.count] = count
        value = nil
        collectgarbage("step")
    end

    local books = bundle.parsed_json["bookshelf.json"] or {}
    local progress = self:get_progress_settings():readSetting("books") or {}
    if type(progress) ~= "table" then progress = {} end
    local progress_books = 0
    for _, book in ipairs(books) do
        if type(book) == "table" then
            local index = tonumber(book.durChapterIndex)
            local book_history = history[history_key(book.name, book.author)]
            local position = math.max(0, math.floor(tonumber(book.durChapterPos) or 0))
            -- A refreshed bookshelf can have durChapterTime without the user
            -- ever opening chapter one. Treat an entry as read when it has a
            -- non-zero chapter/position or a matching Android read record.
            if index and index >= 0
                    and (index > 0 or position > 0 or book_history ~= nil) then
                local key = book_key(book)
                if key ~= "" then
                    -- Android Book.durChapterIndex is zero-based; the plugin
                    -- chapter list and KOReader-facing progress are one-based.
                    local entry = {
                        index = math.floor(index) + 1,
                        title = tostring(book.durChapterTitle or ""),
                        position = position,
                        updated_at = as_epoch_seconds(book.durChapterTime),
                        imported = true,
                    }
                    if book_history and book_history.last_read > entry.updated_at then
                        entry.updated_at = book_history.last_read
                    end
                    local previous = progress[key]
                    local previous_updated = type(previous) == "table"
                        and tonumber(previous.updated_at) or 0
                    -- A second import must not move an already-read Kindle
                    -- chapter backwards when the Android backup is older.
                    -- Imported progress may be refreshed by a newer backup.
                    if previous == nil or previous.imported == true
                            or previous_updated <= (entry.updated_at or 0) then
                        progress[key] = entry
                        progress_books = progress_books + 1
                    end
                end
            end
        end
    end
    local progress_settings = self:get_progress_settings()
    progress_settings:saveSetting("books", progress)
    progress_settings:flush()

    local history_settings = self:get_history_settings()
    history_settings:saveSetting("books", history)
    history_settings:saveSetting("imported_at", os.time())
    history_settings:flush()
    for _ in pairs(history) do history_books = history_books + 1 end
    return {
        records = record_counts,
        history_books = history_books,
        progress_books = progress_books,
    }
end

function Storage:get_reader_session_settings()
    if not self.reader_session_settings then
        self.reader_session_settings = LuaSettings:open(self.reader_session_path)
    end
    return self.reader_session_settings
end

function Storage:get_settings()
    if not self.settings then
        self.settings = LuaSettings:open(self.settings_path)
    end
    return self.settings
end

function Storage:get_prefetch_count()
    local value = tonumber(self:get_settings():readSetting("prefetch_count"))
    if not value then return 5 end
    return math.max(5, math.min(10, math.floor(value)))
end

function Storage:save_prefetch_count(value)
    value = tonumber(value) or 5
    value = math.max(5, math.min(10, math.floor(value)))
    local settings = self:get_settings()
    settings:saveSetting("prefetch_count", value)
    settings:flush()
    return value
end

function Storage:load_reader_session()
    local session = self:get_reader_session_settings():readSetting("session")
    if type(session) ~= "table" or type(session.book) ~= "table"
            or type(session.chapters) ~= "table" then
        return nil
    end
    session.current_index = tonumber(session.current_index) or 1
    return session
end

function Storage:save_reader_session(book, source, chapters, current_index)
    if type(book) ~= "table" or type(source) ~= "table"
            or type(chapters) ~= "table" or #chapters == 0 then
        return false
    end
    local index = tonumber(current_index) or 1
    index = math.max(1, math.min(#chapters, math.floor(index)))
    local saved_book = copy_session_value(book, 0)
    local saved_chapters = {}
    for chapter_index, chapter in ipairs(chapters) do
        if type(chapter) == "table" then
            saved_chapters[chapter_index] = copy_session_value(chapter, 0)
        end
    end
    local session = {
        schema_version = 1,
        book = saved_book,
        source_url = tostring(source.bookSourceUrl or source.sourceUrl or ""),
        source_name = tostring(source.bookSourceName or source.sourceName or ""),
        chapters = saved_chapters,
        current_index = index,
        updated_at = os.time(),
    }
    local settings = self:get_reader_session_settings()
    settings:saveSetting("session", session)
    settings:flush()
    return true
end

function Storage:update_reader_session_index(current_index)
    local session = self:load_reader_session()
    if not session then return false end
    local index = tonumber(current_index)
    if not index then return false end
    session.current_index = math.max(1, math.min(#session.chapters, math.floor(index)))
    session.updated_at = os.time()
    local settings = self:get_reader_session_settings()
    settings:saveSetting("session", session)
    settings:flush()
    return true
end

function Storage:get_last_chapter(book)
    local books = self:get_progress_settings():readSetting("books") or {}
    local value = books[book_key(book)]
    if type(value) == "table" then value = value.index end
    local index = tonumber(value)
    if index and index >= 1 then return math.floor(index) end
    return nil
end

function Storage:save_last_chapter(book, chapter)
    local index = tonumber(chapter and chapter.index)
    if not index or index < 1 then return false end
    local settings = self:get_progress_settings()
    local books = settings:readSetting("books") or {}
    books[book_key(book)] = {
        index = math.floor(index),
        title = chapter.name or "",
        updated_at = os.time(),
    }
    settings:saveSetting("books", books)
    settings:flush()
    return true
end

function Storage:write_chapter(book, chapter, content)
    util.makePath(self.library_root)
    local book_dir = self:get_book_dir(book)
    util.makePath(book_dir)
    local path = self:get_chapter_path(book, chapter)
    content = Content.to_text(content)
    local title = Content.xml_escape(chapter and chapter.name or book and book.name or "")
    local html = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        .. "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head>"
        .. "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"/>"
        .. "<title>" .. title .. "</title>"
        -- Deliberately omit font-family: KOReader owns the document's font.
        .. "<style>body{margin:0 4%;line-height:1.65;}h1{text-align:center;font-size:1.35em;margin:0 0 1.5em;}p{text-indent:2em;margin:0 0 0.8em;}</style>"
        .. "</head><body><h1>" .. title .. "</h1>"
        .. Content.to_xhtml(content) .. "</body></html>"
    local ok = util.writeToFile(html, path)
    if not ok then
        return nil, "cannot save downloaded chapter"
    end
    return path
end

function Storage:read_chapter_content(book, chapter)
    local exists, path = self:chapter_exists(book, chapter)
    if not exists then return nil, path end
    local raw = util.readFromFile(path)
    if type(raw) ~= "string" then return nil, "cannot read cached chapter" end
    if path:lower():sub(-5) == ".html" then
        return Content.to_text(html_body(raw))
    end
    return Content.to_text(legacy_body(raw, chapter))
end

function Storage:write_book(book, content)
    util.makePath(self.library_root)
    local book_dir = self:get_book_dir(book)
    util.makePath(book_dir)
    local path = book_dir .. "/" .. safe_name(book.name) .. ".txt"
    if type(content) == "table" then
        local parts = { book.name or "" }
        if book.author and book.author ~= "" then
            parts[#parts + 1] = book.author
        end
        parts[#parts + 1] = ""
        for _, section in ipairs(content) do
            if type(section) == "table" then
                parts[#parts + 1] = section.title or ""
                parts[#parts + 1] = ""
                parts[#parts + 1] = Content.to_text(section.content)
                parts[#parts + 1] = ""
            end
        end
        content = table.concat(parts, "\n")
    else
        content = Content.to_text(content)
    end
    local ok = util.writeToFile(content, path)
    if not ok then
        return nil, "cannot save downloaded book"
    end
    return path
end

local function epub_chapter(title, body)
    local safe_title = Content.xml_escape(title)
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        .. "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>"
        .. safe_title
        .. "</title><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head><body>"
        .. "<h1>" .. safe_title .. "</h1>" .. Content.to_xhtml(body)
        .. "</body></html>"
end

function Storage:write_epub(book, sections)
    if type(sections) ~= "table" or #sections == 0 then
        return nil, "book sections are empty"
    end
    -- Some KOReader builds provide the versioned `ffi.loadlib` helper while
    -- others expose only LuaJIT's ordinary `ffi.load`.  The bundled archiver
    -- API needs the former name, so provide a local compatibility shim.
    local ffi = require("ffi")
    if type(ffi.loadlib) ~= "function" then
        ffi.loadlib = function(name, version)
            local candidates = {}
            if version then
                candidates[#candidates + 1] = "/mnt/us/koreader/libs/lib"
                    .. tostring(name) .. ".so." .. tostring(version)
                candidates[#candidates + 1] = "lib" .. tostring(name) .. ".so." .. tostring(version)
            end
            candidates[#candidates + 1] = tostring(name)
            local last_error
            for _, candidate in ipairs(candidates) do
                local loaded, library = pcall(ffi.load, candidate)
                if loaded then return library end
                last_error = library
            end
            error(last_error or ("cannot load " .. tostring(name)))
        end
    end
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or type(Archiver) ~= "table" or type(Archiver.Writer) ~= "table" then
        return nil, "KOReader EPUB writer is unavailable"
    end

    util.makePath(self.library_root)
    local book_dir = self:get_book_dir(book)
    util.makePath(book_dir)
    local path = book_dir .. "/" .. safe_name(book.name) .. ".epub"
    local temp_path = path .. ".part"
    os.remove(temp_path)

    local writer = Archiver.Writer:new()
    local opened, open_result = pcall(writer.open, writer, temp_path, "epub")
    if not opened or open_result ~= true then
        return nil, "cannot create EPUB archive: " .. tostring(writer.err or open_result or "unknown error")
    end

    local title = tostring(book.name or "book")
    local author = tostring(book.author or "")
    local identifier = "legado-" .. tostring(os.time())
    local manifest = {
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
        '<item id="style" href="style.css" media-type="text/css"/>',
    }
    local spine = {}
    local nav = {}
    local ncx = {}

    for index, section in ipairs(sections) do
        if type(section) == "table" then
            local id = "chapter-" .. string.format("%05d", index)
            local href = id .. ".xhtml"
            local chapter_title = tostring(section.title or ("Chapter " .. tostring(index)))
            manifest[#manifest + 1] = string.format(
                '<item id="%s" href="%s" media-type="application/xhtml+xml"/>',
                id, href
            )
            spine[#spine + 1] = string.format('<itemref idref="%s"/>', id)
            nav[#nav + 1] = string.format(
                '<li><a href="%s">%s</a></li>', href, Content.xml_escape(chapter_title)
            )
            ncx[#ncx + 1] = string.format(
                '<navPoint id="navPoint-%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/></navPoint>',
                index, index, Content.xml_escape(chapter_title), href
            )
            section._epub_id = id
            section._epub_href = href
        end
    end

    local opf = '<?xml version="1.0" encoding="UTF-8"?>'
        .. '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"'
        .. ' unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        .. '<dc:identifier id="book-id">' .. Content.xml_escape(identifier) .. '</dc:identifier>'
        .. '<dc:title>' .. Content.xml_escape(title) .. '</dc:title>'
        .. (author ~= "" and '<dc:creator>' .. Content.xml_escape(author) .. '</dc:creator>' or "")
        .. '<dc:language>zh-CN</dc:language></metadata><manifest>'
        .. table.concat(manifest)
        .. '</manifest><spine toc="ncx">' .. table.concat(spine) .. '</spine></package>'
    local nav_xhtml = '<?xml version="1.0" encoding="UTF-8"?>'
        .. '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>'
        .. Content.xml_escape(title) .. '</title></head><body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>'
        .. table.concat(nav) .. '</ol></nav></body></html>'
    local toc_ncx = '<?xml version="1.0" encoding="UTF-8"?>'
        .. '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="'
        .. Content.xml_escape(identifier) .. '"/></head><docTitle><text>' .. Content.xml_escape(title)
        .. '</text></docTitle><navMap>' .. table.concat(ncx) .. '</navMap></ncx>'
    -- Do not set a font-family here.  KOReader's selected face must remain
    -- authoritative; a generic CSS family would otherwise make a generated
    -- EPUB appear stuck on the book's own serif choice.
    local style = 'body{margin:0 4%;line-height:1.65;}h1{text-align:center;font-size:1.35em;margin:0 0 1.5em;}p{text-indent:2em;margin:0 0 0.8em;}'
    local container = '<?xml version="1.0" encoding="UTF-8"?>'
        .. '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        .. '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
        .. '</rootfiles></container>'

    local write_ok, write_err = pcall(function()
        if writer:setZipCompression("store") ~= true then
            error(writer.err or "cannot configure EPUB archive")
        end
        local function add(name, data)
            if writer:addFileFromMemory(name, data) ~= true then
                error(writer.err or ("cannot add " .. name))
            end
        end
        -- EPUB requires mimetype to be the first, uncompressed member.  The
        -- whole small text archive is stored to preserve that invariant on the
        -- old libarchive shipped with some KPW4 KOReader builds.
        add("mimetype", "application/epub+zip")
        add("META-INF/container.xml", container)
        add("OEBPS/content.opf", opf)
        add("OEBPS/nav.xhtml", nav_xhtml)
        add("OEBPS/toc.ncx", toc_ncx)
        add("OEBPS/style.css", style)
        for index, section in ipairs(sections) do
            if type(section) == "table" then
                local id = section._epub_id or ("chapter-" .. string.format("%05d", index))
                add("OEBPS/" .. id .. ".xhtml", epub_chapter(
                    section.title or ("Chapter " .. tostring(index)),
                    section.content
                ))
            end
        end
    end)
    pcall(writer.close, writer)
    if not write_ok then
        os.remove(temp_path)
        return nil, "cannot write EPUB: " .. tostring(write_err)
    end
    if not os.rename(temp_path, path) then
        os.remove(temp_path)
        return nil, "cannot activate EPUB file"
    end
    return path
end

return Storage
