local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Backup = require("legado/backup")
local Content = require("legado/content")
local LuaSettings = require("luasettings")

local Storage = {}
Storage.__index = Storage

local function default_state()
    return {
        schema_version = 1,
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
    object.reader_session_path = object.root .. "/reading-session.lua"
    object.reader_session_settings = nil
    object.reader_preferences_path = object.root .. "/reading-settings.lua"
    object.reader_preferences = nil
    if lfs.attributes(object.root, "mode") ~= "directory" then
        lfs.mkdir(object.root)
    end
    return object
end

function Storage:read_state()
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
        .. string.format("%04d-%s.txt", index, safe_name(chapter and chapter.name))
end

function Storage:chapter_exists(book, chapter)
    local path = self:get_chapter_path(book, chapter)
    return lfs.attributes(path, "mode") == "file", path
end

function Storage:chapter_is_readable(book, chapter)
    local exists, path = self:chapter_exists(book, chapter)
    if not exists then return false, path end
    local content = util.readFromFile(path)
    -- Older plugin versions wrote raw HTML into TXT. Treat those files as a
    -- stale cache so tapping a chapter transparently refreshes it once.
    return type(content) == "string" and not Content.has_markup(content), path
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

function Storage:get_reader_session_settings()
    if not self.reader_session_settings then
        self.reader_session_settings = LuaSettings:open(self.reader_session_path)
    end
    return self.reader_session_settings
end

function Storage:get_reader_preferences()
    if not self.reader_preferences then
        self.reader_preferences = LuaSettings:open(self.reader_preferences_path)
    end
    return self.reader_preferences
end

function Storage:get_prefetch_count()
    local value = tonumber(self:get_reader_preferences():readSetting("prefetch_count"))
    if not value then return 5 end
    return math.max(5, math.min(10, math.floor(value)))
end

function Storage:save_prefetch_count(value)
    value = tonumber(value) or 5
    value = math.max(5, math.min(10, math.floor(value)))
    local settings = self:get_reader_preferences()
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
    local header = (book.name or "") .. "\n"
    if book.author and book.author ~= "" then
        header = header .. (book.author or "") .. "\n"
    end
    header = header .. "\n" .. (chapter.name or "") .. "\n\n"
    local ok = util.writeToFile(header .. content, path)
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
    -- Strip the small header written by write_chapter when reusing a cached
    -- chapter for incremental whole-book export. If a legacy file has a
    -- different header, fall back to normal HTML/text cleanup.
    local marker = "\n\n" .. (chapter and chapter.name or "") .. "\n\n"
    local _, marker_end = raw:find(marker, 1, true)
    if marker_end then
        raw = raw:sub(marker_end + 1)
    end
    return Content.to_text(raw)
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
    local style = 'body{margin:0 4%;font-family:serif;line-height:1.65;}h1{text-align:center;font-size:1.35em;margin:0 0 1.5em;}p{text-indent:2em;margin:0 0 0.8em;}'
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
