-- Device-owned immutable content, atomic published shelf, and durable progress.
-- This module never reads or modifies the old Legado plugin's state.
local Digest = require("legado_server/digest")
local Store = {}
Store.__index = Store

local function checked(callback)
    local ok, value, other = pcall(callback)
    if not ok then return nil, tostring(value) end
    return value, other
end

local function need(value, message)
    if not value then error(message or "local operation failed", 0) end
    return value
end

local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 512
        and not value:find("[%z\1-\31\127]")
end

local function safe_file_name(value)
    value = type(value) == "string" and value or "book.epub"
    value = value:gsub("[\\/:*?\"<>|%z\1-\31]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then value = "book.epub" end
    if value:lower():sub(-5) ~= ".epub" then value = value .. ".epub" end
    if #value > 160 then
        value = value:sub(1, 155 - #".epub") .. ".epub"
    end
    return value
end

local function integer(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
        and value < 9007199254740992
end

local function checksum(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return setmetatable(result, getmetatable(value))
end

local function increment(value)
    need(type(value) == "string" and value:match("^%d+$") and (#value == 1 or value:sub(1, 1) ~= "0"), "invalid persisted device sequence")
    local result, carry = {}, 1
    for index = #value, 1, -1 do
        local digit = value:byte(index) - 48 + carry
        result[index], carry = tostring(digit % 10), math.floor(digit / 10)
    end
    return (carry == 1 and "1" or "") .. table.concat(result)
end

local function newer(left, right)
    return #left > #right or (#left == #right and left > right)
end

function Store.new(options)
    options = options or {}
    need(type(options.root) == "string" and options.root ~= "", "device storage root is required")
    local object = setmetatable({
        root = options.root:gsub("/+$", ""),
        fs = options.fs or require("legado_server/fs").new(),
        json = options.json or require("rapidjson"),
        digest_file = options.digest_file or Digest.file,
        archive_open = options.archive_open,
        max_bundle_bytes = options.max_bundle_bytes or 16 * 1024 * 1024,
        max_content_bytes = options.max_content_bytes or 8 * 1024 * 1024,
        max_expanded_bytes = options.max_expanded_bytes or 32 * 1024 * 1024,
        max_epub_bytes = options.max_epub_bytes or 128 * 1024 * 1024,
    }, Store)
    need(object.fs:mkdir(object.root))
    need(object.fs:mkdir(object.root .. "/objects"))
    need(object.fs:mkdir(object.root .. "/bundles"))
    need(object.fs:mkdir(object.root .. "/shelf"))
    return object
end

function Store:array(value)
    return self.json.array and self.json.array(value or {}) or (value or {})
end

function Store:is_null(value)
    return value == nil or value == self.json.null
end

function Store:_load(name, default)
    local path = self.root .. "/" .. name .. ".json"
    if not self.fs:exists(path) then return copy(default) end
    local data, err = self.fs:read(path, 16 * 1024 * 1024)
    need(data, err)
    local ok, decoded = pcall(self.json.decode, data)
    need(ok and type(decoded) == "table", "invalid persisted " .. name)
    return decoded
end

function Store:_save(name, value)
    if name == "state" then
        value.state_revision = self:_new_state_revision()
    end
    local ok, data = pcall(self.json.encode, value)
    need(ok and type(data) == "string", "cannot encode device state")
    local written, err = self.fs:atomic_write(self.root .. "/" .. name .. ".json", data)
    need(written, err)
    if name == "state" then
        local metadata = self:_state_metadata()
        need(metadata, "cannot inspect published shelf state")
        need(self:_save("state-revision", {
            revision = value.state_revision,
            size = metadata.size,
            modification = metadata.modification,
        }))
        need(self:_save("sync-meta", self:_sync_meta_from_state(value, metadata)))
        -- The shelf index is derived data. A failure to update it must never
        -- make an otherwise durable protocol-state write fail.
        pcall(self._write_shelf_index, self, value)
    end
    return true
end

function Store:settings()
    return checked(function() return self:_load("settings", {}) end)
end

function Store:save_settings(settings)
    return checked(function() return self:_save("settings", settings) end)
end

-- Clear protocol state that belongs to one server/device pairing. Published
-- content, pushed books and local reading positions intentionally remain.
function Store:forget_server_pairing()
    return checked(function()
        local state = self:state()
        state.cursor = "0"
        state.pending_ack = nil
        state.last_sync_id = nil
        state.publication_id = nil
        state.last_sync_at = nil
        state.last_sync_attempt_at = nil
        state.last_sync_error = nil
        state.conflict_count = 0
        state.conflicts = self:array()
        need(self:_save("state", state))

        local inbox = self:inbox_state()
        inbox.cursor = "0"
        need(self:_save("inbox", inbox))

        self:_progress_transaction(function()
            local progress = self:_progress()
            progress.device_id = nil
            progress.device_seq = "0"
            progress.pending = self:array()
            progress.receipts = {}
            progress.versions = {}
            need(self:_save("progress", progress))
        end)
        return true
    end)
end

function Store:reader_state()
    return checked(function() return self:_load("reader", {}) end)
end

function Store:save_reader_state(state)
    return checked(function() return self:_save("reader", state) end)
end

function Store:inbox_state()
    return checked(function()
        local state = self:_load("inbox", { protocol_version = 1, cursor = "0", books = {} })
        need(state.protocol_version == 1 and type(state.cursor) == "string"
            and state.cursor:match("^%d+$") and type(state.books) == "table", "invalid pushed-book state")
        return state
    end)
end

function Store:inbox_file_path(book_id, delivery_id, file_id, file_name)
    need(identifier(book_id) and identifier(delivery_id) and identifier(file_id),
        "invalid pushed book identity")
    return self.root .. "/pushed/" .. Digest.hex(book_id) .. "/"
        .. Digest.hex(delivery_id) .. "/"
        .. Digest.hex(file_id):sub(1, 16) .. "-" .. safe_file_name(file_name)
end

function Store:inbox_file_valid(path, file)
    return self.fs:exists(path) and self.fs:size(path) == file.size_bytes
        and self.digest_file(path) == file.sha256
end

function Store:record_inbox_delivery(delivery, files)
    return checked(function()
        need(type(delivery) == "table" and identifier(delivery.delivery_id)
            and identifier(delivery.book_id) and type(delivery.title) == "string"
            and delivery.format == "epub" and type(files) == "table" and #files > 0,
            "invalid pushed-book delivery")
        local state = self:inbox_state()
        need(state, "cannot load pushed-book state")
        local previous = state.books[delivery.book_id]
        local keep = {}
        for file_index, file in ipairs(files) do keep[file.path] = true end
        state.books[delivery.book_id] = {
            delivery_id = delivery.delivery_id,
            book_id = delivery.book_id,
            title = delivery.title,
            author = delivery.author,
            created_at = delivery.created_at,
            installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            files = copy(files),
        }
        local saved = self:_save("inbox", state)
        if previous and type(previous.files) == "table" then
            for file_index, file in ipairs(previous.files) do
                if type(file.path) == "string" and not keep[file.path] then self.fs:remove(file.path) end
            end
        end
        return saved
    end)
end

function Store:inbox_books()
    local state, err = self:inbox_state()
    if not state then return nil, err end
    local books = {}
    for book_key, book in pairs(state.books) do books[#books + 1] = book end
    table.sort(books, function(left, right)
        if left.title == right.title then return left.delivery_id < right.delivery_id end
        return tostring(left.title) < tostring(right.title)
    end)
    return books
end

function Store:remove_inbox_book(book_id)
    return checked(function()
        need(identifier(book_id), "invalid pushed-book identity")
        local state = self:inbox_state()
        need(state, "cannot load pushed-book state")
        local book = state.books[book_id]
        need(book, "pushed book is not available locally")
        state.books[book_id] = nil
        need(self:_save("inbox", state))
        for file_index, file in ipairs(book.files or {}) do
            local path = type(file) == "table" and file.path or nil
            need(type(path) == "string" and path:sub(1, #self.root + 8) == self.root .. "/pushed/",
                "invalid pushed-book file path")
            need(self.fs:remove(path), "cannot remove pushed-book file")
        end
        return true
    end)
end

function Store:inbox_cursor()
    local state, err = self:inbox_state()
    if not state then return nil, err end
    return state.cursor
end

function Store:confirm_inbox_ack(cursor)
    return checked(function()
        need(type(cursor) == "string" and cursor:match("^%d+$"), "invalid inbox acknowledgement")
        local state = self:inbox_state()
        need(state, "cannot load pushed-book state")
        state.cursor = cursor
        return self:_save("inbox", state)
    end)
end

function Store:state()
    return checked(function()
        local state = self:_load("state", { protocol_version = 1, books = {} })
        need(state.protocol_version == 1 and type(state.books) == "table", "unsupported local shelf version")
        return state
    end)
end

function Store:books()
    local state, err = self:state()
    if not state then return nil, err end
    local books = {}
    for book_id, book in pairs(state.books) do
        if book.book_id == book_id then books[#books + 1] = book end
    end
    table.sort(books, function(left, right)
        if left.title == right.title then return left.book_id < right.book_id end
        return tostring(left.title) < tostring(right.title)
    end)
    return books
end

local function summarize_book(book_id, book, store)
    if type(book) ~= "table" or book.book_id ~= book_id
            or type(book.title) ~= "string" or type(book.chapters) ~= "table" then
        return nil
    end
    local remote = type(book.progress) == "table" and book.progress or nil
    local remote_chapter_index, remote_chapter_progress, remote_progress_version
    if remote then
        remote_chapter_index = remote.chapter_index
        remote_chapter_progress = remote.chapter_progress
        remote_progress_version = remote.progress_version
        if not integer(remote_chapter_index) and identifier(remote.chapter_id) then
            for chapter_index, chapter in ipairs(book.chapters) do
                if chapter.chapter_id == remote.chapter_id then
                    remote_chapter_index = chapter_index - 1
                    break
                end
            end
        end
    end
    return {
        book_id = book_id,
        title = book.title,
        author = not store:is_null(book.author) and book.author or nil,
        chapter_count = #book.chapters,
        progress = remote and {
            chapter_id = remote.chapter_id,
            chapter_index = remote_chapter_index,
            chapter_progress = remote_chapter_progress,
            progress_version = remote_progress_version,
        } or nil,
    }
end

function Store:_summarize_state(state)
    local books = {}
    for book_id, book in pairs(state.books) do
        local summary = summarize_book(book_id, book, self)
        if summary then books[#books + 1] = summary end
    end
    table.sort(books, function(left, right)
        if left.title == right.title then return left.book_id < right.book_id end
        return tostring(left.title) < tostring(right.title)
    end)
    return {
        books = books,
        conflict_count = state.conflict_count or 0,
        last_sync_at = not self:is_null(state.last_sync_at) and state.last_sync_at or nil,
        last_sync_error = not self:is_null(state.last_sync_error) and state.last_sync_error or nil,
    }
end

function Store:_state_metadata()
    return self.fs:stat(self.root .. "/state.json")
end

function Store:_new_state_revision()
    self._state_revision_counter = (self._state_revision_counter or 0) + 1
    local address = tostring({}):match("0x(%x+)") or "0"
    return table.concat({
        tostring(os.time()),
        tostring(self._state_revision_counter),
        address,
    }, "-")
end

function Store:_sync_meta_from_state(state, metadata)
    metadata = metadata or self:_state_metadata()
    need(metadata, "cannot inspect published shelf state")
    return {
        protocol_version = 1,
        state_revision = state.state_revision,
        state_size = metadata.size,
        state_modification = metadata.modification,
        cursor = state.cursor or "0",
        pending_ack = copy(state.pending_ack),
        last_sync_id = state.last_sync_id,
        publication_id = state.publication_id,
        last_sync_at = state.last_sync_at,
        last_sync_attempt_at = state.last_sync_attempt_at,
        last_sync_error = state.last_sync_error,
        conflict_count = state.conflict_count or 0,
        conflicts = copy(state.conflicts or self:array()),
    }
end

function Store:_valid_sync_meta(meta)
    return type(meta) == "table" and meta.protocol_version == 1
        and type(meta.state_revision) == "string" and meta.state_revision ~= ""
        and type(meta.cursor) == "string" and meta.cursor ~= ""
        and (self:is_null(meta.pending_ack) or type(meta.pending_ack) == "table")
        and type(meta.conflicts) == "table"
        and integer(meta.conflict_count or 0)
end

function Store:_apply_sync_meta(state, meta)
    state.cursor = meta.cursor
    state.pending_ack = copy(meta.pending_ack)
    state.last_sync_id = meta.last_sync_id
    state.publication_id = meta.publication_id
    state.last_sync_at = meta.last_sync_at
    state.last_sync_attempt_at = meta.last_sync_attempt_at
    state.last_sync_error = meta.last_sync_error
    state.conflict_count = meta.conflict_count or 0
    state.conflicts = copy(meta.conflicts or self:array())
    return state
end

function Store:_sync_meta()
    return checked(function()
        local revision = self:_load("state-revision", {})
        local meta = self:_load("sync-meta", {})
        if self:_valid_sync_meta(meta)
                and type(revision.revision) == "string"
                and revision.revision == meta.state_revision then
            return meta
        end

        -- Upgrade path: the first 0.3.x call derives the compact sidecar from
        -- the legacy full state once. Every subsequent no-change sync stays on
        -- the KB-sized sidecar.
        local state = self:state()
        need(state, "cannot migrate synchronization metadata")
        local metadata = self:_state_metadata()
        need(metadata, "cannot inspect published shelf state")
        local revision_value = state.state_revision
            or ("legacy-" .. tostring(metadata.size) .. "-"
                .. tostring(metadata.modification) .. "-" .. Digest.hex(state.cursor or "0"))
        local compact = self:_sync_meta_from_state(state, metadata)
        compact.state_revision = revision_value
        need(self:_save("state-revision", {
            revision = revision_value,
            size = metadata.size,
            modification = metadata.modification,
        }))
        need(self:_save("sync-meta", compact))
        return compact
    end)
end

function Store:sync_meta()
    return self:_sync_meta()
end

function Store:_update_shelf_sync_metadata(meta)
    local cache = self._shelf_index_cache
    if cache then
        cache.conflict_count = meta.conflict_count or 0
        cache.last_sync_at = meta.last_sync_at
        cache.last_sync_error = meta.last_sync_error
    end
    local loaded, index = pcall(self._load, self, "shelf-index")
    if not loaded or type(index) ~= "table" then return end
    index.conflict_count = meta.conflict_count or 0
    index.last_sync_at = meta.last_sync_at
    index.last_sync_error = meta.last_sync_error
    pcall(self._save, self, "shelf-index", index)
end

function Store:_write_shelf_index(state)
    local snapshot = self:_summarize_state(state)
    local metadata = self:_state_metadata()
    need(metadata, "cannot inspect published shelf state")
    local value = {
        protocol_version = 1,
        source_size = metadata.size,
        source_modification = metadata.modification,
        books = snapshot.books,
        conflict_count = snapshot.conflict_count,
        last_sync_at = snapshot.last_sync_at,
        last_sync_error = snapshot.last_sync_error,
    }
    need(self:_save("shelf-index", value))
    self._shelf_index_cache = {
        source_size = metadata.size,
        source_modification = metadata.modification,
        books = snapshot.books,
        conflict_count = snapshot.conflict_count,
        last_sync_at = snapshot.last_sync_at,
        last_sync_error = snapshot.last_sync_error,
    }
    return true
end

function Store:_shelf_snapshot(active_book_id)
    local metadata = self:_state_metadata()
    need(metadata, "published shelf state is unavailable")
    local cache = self._shelf_index_cache
    if not cache or cache.source_size ~= metadata.size
            or cache.source_modification ~= metadata.modification then
        local loaded, index = pcall(self._load, self, "shelf-index")
        if loaded and type(index) == "table" and index.protocol_version == 1
                and index.source_size == metadata.size
                and index.source_modification == metadata.modification
                and type(index.books) == "table" then
            cache = {
                source_size = metadata.size,
                source_modification = metadata.modification,
                books = index.books,
                conflict_count = index.conflict_count or 0,
                last_sync_at = index.last_sync_at,
                last_sync_error = index.last_sync_error,
            }
            self._shelf_index_cache = cache
        else
            local state, state_err = self:state()
            need(state, state_err)
            need(self:_write_shelf_index(state))
            cache = self._shelf_index_cache
            state = nil
            collectgarbage("collect")
        end
    end
    local active_book
    for book_index, book in ipairs(cache.books) do
        if book.book_id == active_book_id then
            active_book = book
            break
        end
    end
    return {
        books = cache.books,
        active_book = active_book,
        conflict_count = cache.conflict_count,
        last_sync_at = cache.last_sync_at,
        last_sync_error = cache.last_sync_error,
    }
end

-- The shelf menu only needs title, author, chapter count and the current
-- progress position. Keep that compact projection instead of retaining the
-- complete chapter graph while KOReader builds and renders the menu.
function Store:book_summaries()
    return checked(function()
        local snapshot = self:_shelf_snapshot()
        return copy(snapshot.books)
    end)
end

-- Menu badges need one shelf parse for several counters. Return only summary
-- scalars and the one currently open book so the full chapter graph can be
-- released immediately after the menu is built.
function Store:dashboard(active_book_id)
    return checked(function()
        local shelf = self:_shelf_snapshot(active_book_id)
        local progress = self:_progress()
        local pending = {}
        for event_index, event in ipairs(progress.pending) do
            pending[event.book_id] = event
        end
        local inbox, inbox_err = self:inbox_state()
        need(inbox, inbox_err)
        local inbox_count = 0
        for book_id, book in pairs(inbox.books) do
            if type(book_id) == "string" and type(book) == "table" then
                inbox_count = inbox_count + 1
            end
        end
        local settings = self:_load("settings", {})
        local dashboard = {
            book_count = #shelf.books,
            active_book = shelf.active_book,
            progress_snapshot = {
                pending = pending,
                positions = progress.positions,
                versions = progress.versions,
            },
            inbox_count = inbox_count,
            pending_progress = #progress.pending,
            conflict_count = shelf.conflict_count,
            last_sync_at = shelf.last_sync_at,
            last_sync_error = shelf.last_sync_error,
            paired = not self:is_null(settings.server_url) and not self:is_null(settings.device_token),
            server_name = not self:is_null(settings.server_name) and settings.server_name or nil,
        }
        collectgarbage("collect")
        return dashboard
    end)
end

function Store:book(book_id)
    local state, err = self:state()
    if not state then return nil, err end
    return state.books[book_id], "published book is not available locally"
end

function Store:content_path(hash)
    need(checksum(hash), "invalid content hash")
    return self.root .. "/objects/" .. hash:sub(1, 2) .. "/" .. hash .. ".xhtml"
end

function Store:epub_path(book_id)
    need(identifier(book_id), "invalid published book identity")
    return self.root .. "/shelf/" .. Digest.hex(book_id) .. "/book.epub"
end

function Store:_epub_verifications()
    if not self._epub_verifications_cache then
        self._epub_verifications_cache = self:_load("epub-verifications", {})
    end
    return self._epub_verifications_cache
end

function Store:epub_verification_matches(book_id, descriptor)
    local verified = self:_epub_verifications()
    local entry = verified[book_id]
    return type(entry) == "table"
        and entry.sha256 == descriptor.sha256
        and entry.size_bytes == descriptor.size_bytes
end

function Store:_record_epub_verification(book_id, descriptor)
    local verified = self:_epub_verifications()
    verified[book_id] = {
        sha256 = descriptor.sha256,
        size_bytes = descriptor.size_bytes,
        verified_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    need(self:_save("epub-verifications", verified))
    self._epub_verifications_cache = verified
    return true
end

function Store:book_epub_valid(book, verify_hash)
    local epub = type(book) == "table" and book.epub or nil
    if not epub or self:is_null(epub) then return false end
    local path = self:epub_path(book.book_id)
    if not self.fs:exists(path) or self.fs:size(path) ~= epub.size_bytes then return false end
    if self:epub_verification_matches(book.book_id, epub) then return true end
    if verify_hash ~= true or self.digest_file(path) ~= epub.sha256 then return false end
    return self:_record_epub_verification(book.book_id, epub)
end

function Store:install_book_epub(book_id, descriptor, fetch)
    return checked(function()
        need(identifier(book_id) and type(descriptor) == "table"
            and checksum(descriptor.sha256) and integer(descriptor.size_bytes)
            and descriptor.size_bytes > 0 and descriptor.size_bytes <= self.max_epub_bytes
            and descriptor.media_type == "application/epub+zip"
            and identifier(descriptor.binding_version) and identifier(descriptor.toc_version),
            "invalid published EPUB descriptor")
        local target = self:epub_path(book_id)
        if self.fs:exists(target) and self.fs:size(target) == descriptor.size_bytes
        then
            if self:epub_verification_matches(book_id, descriptor) then
                return true
            end
            if self.digest_file(target) == descriptor.sha256 then
                need(self:_record_epub_verification(book_id, descriptor))
                return true
            end
            need(self.fs:remove(target))
        end
        local pending = target .. ".part"
        local resume = self.fs:exists(pending) and self.fs:size(pending) or 0
        if resume > descriptor.size_bytes then
            need(self.fs:remove(pending))
            resume = 0
        elseif resume == descriptor.size_bytes then
            if self.digest_file(pending) ~= descriptor.sha256 then
                need(self.fs:remove(pending))
                resume = 0
            else
                need(self.fs:rename(pending, target))
                need(self:_record_epub_verification(book_id, descriptor))
                return true
            end
        end
        local writer, writer_err = self.fs:writer(pending, descriptor.size_bytes, resume)
        need(writer, writer_err)
        local called, fetched, fetch_err = pcall(fetch, function(chunk)
            return writer:write(chunk)
        end, resume)
        local closed, close_err = writer:close()
        if type(fetch_err) == "table" and fetch_err.changed then
            self.fs:remove(pending)
        end
        need(called, fetched)
        -- A transport-level response/header error can happen after the body
        -- has already arrived in full. The descriptor hash is the durable
        -- authority, so activate a complete, verified part instead of making
        -- the next background cycle download it again.
        local complete = closed and writer:size() == descriptor.size_bytes
            and self.fs:exists(pending) and self.digest_file(pending) == descriptor.sha256
        if complete then
            need(self.fs:rename(pending, target))
            need(self:_record_epub_verification(book_id, descriptor))
            return true
        end
        need(fetched, type(fetch_err) == "table" and fetch_err.message or fetch_err)
        need(closed and writer:size() == descriptor.size_bytes, close_err or "incomplete EPUB download")
        if self.digest_file(pending) ~= descriptor.sha256 then
            self.fs:remove(pending)
            error("EPUB checksum mismatch", 0)
        end
        need(self.fs:rename(pending, target))
        need(self:_record_epub_verification(book_id, descriptor))
        return true
    end)
end

function Store:chapter_path(chapter, verify)
    return checked(function()
        need(type(chapter) == "table" and chapter.status == "ready", "chapter has not been downloaded by the server")
        need(checksum(chapter.content_hash) and integer(chapter.size_bytes) and chapter.size_bytes > 0, "invalid published chapter")
        local path = self:content_path(chapter.content_hash)
        need(self.fs:exists(path) and self.fs:size(path) == chapter.size_bytes, "chapter content is not available locally; sync first")
        if verify then need(self.digest_file(path) == chapter.content_hash, "local chapter checksum mismatch") end
        return path
    end)
end

-- Immutable content is shared by hash, but KOReader sidecars belong to a
-- particular book and chapter. Identical titles/content must not share them.
function Store:reading_path(book_id, chapter)
    return checked(function()
        need(identifier(book_id) and identifier(chapter.chapter_id), "invalid reading identity")
        local source, err = self:chapter_path(chapter, true)
        need(source, err)
        local target = self.root .. "/reading/" .. Digest.hex(book_id) .. "/"
            .. Digest.hex(chapter.chapter_id) .. "-" .. chapter.content_hash .. ".xhtml"
        if not self.fs:exists(target) or self.fs:size(target) ~= chapter.size_bytes
                or self.digest_file(target) ~= chapter.content_hash then
            local content, read_err = self.fs:read(source, self.max_content_bytes)
            need(content, read_err)
            local written, write_err = self.fs:atomic_write(target, content)
            need(written, write_err)
        end
        return target
    end)
end

function Store:_open_archive(path)
    if self.archive_open then return self.archive_open(path) end
    local reader = require("ffi/archiver").Reader:new()
    if not reader:open(path) then
        local err = reader.err
        reader:close()
        return nil, err or "cannot open sync ZIP"
    end
    return reader
end

function Store:_unpack(path, descriptor)
    local reader, err = self:_open_archive(path)
    need(reader, err)
    local ok, result = pcall(function()
        local entries, count, total = {}, 0, 0
        for entry in reader:iterate() do
            count = count + 1
            need(count <= 8192, "sync ZIP contains too many entries")
            need(entry.mode == "file", "sync ZIP contains a link or non-file entry")
            local name = entry.path
            local hash = type(name) == "string" and name:match("^chapters/([0-9a-f]+)%.xhtml$")
            need(name == "manifest.json" or checksum(hash), "unsafe or unexpected sync ZIP path")
            need(not entries[name], "duplicate sync ZIP path")
            local size = tonumber(entry.size)
            need(integer(size) and size > 0 and size <= self.max_content_bytes, "sync ZIP entry exceeds size limit")
            total = total + size
            need(total <= self.max_expanded_bytes, "expanded sync ZIP exceeds size limit")
            entries[name] = size
        end
        need(not reader.err, reader.err)
        need(entries["manifest.json"] and entries["manifest.json"] <= 1024 * 1024, "sync ZIP manifest is missing or oversized")
        local raw = need(reader:extractToMemory("manifest.json"), "cannot read sync ZIP manifest")
        need(#raw == entries["manifest.json"], "short sync ZIP manifest")
        local decoded, manifest = pcall(self.json.decode, raw)
        need(decoded and type(manifest) == "table" and manifest.protocol_version == 1
            and manifest.bundle_id == descriptor.bundle_id and type(manifest.files) == "table", "invalid sync ZIP manifest")
        local seen, file_count = {}, 0
        for file_index, file in ipairs(manifest.files) do
            need(type(file) == "table" and checksum(file.sha256), "invalid sync ZIP file descriptor")
            local expected = "chapters/" .. file.sha256 .. ".xhtml"
            need(file.path == expected and not seen[expected], "duplicate or unsafe manifest file path")
            need(integer(file.size_bytes) and file.size_bytes > 0 and entries[expected] == file.size_bytes, "sync ZIP file size mismatch")
            seen[expected], file_count = true, file_count + 1
            local content = need(reader:extractToMemory(expected), "cannot extract sync chapter")
            need(#content == file.size_bytes and Digest.hex(content) == file.sha256, "sync chapter checksum mismatch")
            local target = self:content_path(file.sha256)
            if not self.fs:exists(target) or self.fs:size(target) ~= #content or self.digest_file(target) ~= file.sha256 then
                local written, write_err = self.fs:atomic_write(target, content)
                need(written, write_err)
            end
        end
        need(file_count + 1 == count, "sync ZIP contains files outside its manifest")
        return true
    end)
    reader:close()
    need(ok, result)
    return result
end

function Store:install_bundle(descriptor, fetch)
    return checked(function()
        need(type(descriptor) == "table" and identifier(descriptor.bundle_id) and checksum(descriptor.sha256), "invalid bundle descriptor")
        need(descriptor.media_type == "application/zip" and integer(descriptor.size_bytes)
            and descriptor.size_bytes > 0 and descriptor.size_bytes <= self.max_bundle_bytes, "unsupported or oversized sync bundle")
        local path = self.root .. "/bundles/" .. descriptor.sha256 .. ".zip"
        local valid = self.fs:exists(path) and self.fs:size(path) == descriptor.size_bytes
            and self.digest_file(path) == descriptor.sha256
        if not valid then
            local pending = path .. ".part"
            local resume = self.fs:exists(pending) and self.fs:size(pending)
            if resume and resume > descriptor.size_bytes then self.fs:remove(pending); resume = nil end
            local offset = resume or 0
            if offset == descriptor.size_bytes then
                if self.digest_file(pending) ~= descriptor.sha256 then
                    self.fs:remove(pending)
                    error("sync bundle checksum mismatch", 0)
                end
                local complete, complete_err = self.fs:rename(pending, path)
                need(complete, complete_err)
                self:_unpack(path, descriptor)
                return true
            end
            local writer, writer_err = self.fs:writer(pending, descriptor.size_bytes, offset)
            need(writer, writer_err)
            local changed = false
            local called, fetched, fetch_err = pcall(fetch, function(chunk)
                return writer:write(chunk)
            end, offset)
            local closed, close_err = writer:close()
            if writer:overflow() or (type(fetch_err) == "table" and fetch_err.bundle_changed == true) then changed = true end
            if changed then
                self.fs:remove(pending)
                error("sync bundle changed on the server; restart its download", 0)
            end
            if not called or not fetched or not closed or writer:size() ~= descriptor.size_bytes then
                -- Keep a bounded prefix for the next Range/If-Range request. The
                -- descriptor hash is checked before activation and after rename.
                error((not called and fetched) or fetch_err or close_err or "incomplete sync bundle download", 0)
            end
            if self.digest_file(pending) ~= descriptor.sha256 then
                self.fs:remove(pending)
                error("sync bundle checksum mismatch", 0)
            end
            local renamed, rename_err = self.fs:rename(pending, path)
            need(renamed, rename_err)
        end
        self:_unpack(path, descriptor)
        return true
    end)
end

function Store:_validate_book(book)
    need(type(book) == "table" and identifier(book.book_id) and type(book.title) == "string"
        and identifier(book.binding_version) and identifier(book.toc_version) and type(book.chapters) == "table", "invalid published book")
    local epub = self:is_null(book.epub) and nil or book.epub
    if epub ~= nil then
        need(type(epub) == "table" and checksum(epub.sha256)
            and integer(epub.size_bytes) and epub.size_bytes > 0
            and epub.size_bytes <= self.max_epub_bytes
            and epub.media_type == "application/epub+zip"
            and epub.binding_version == book.binding_version
            and epub.toc_version == book.toc_version,
            "invalid published EPUB identity")
    end
    local ids = {}
    for array_index, chapter in ipairs(book.chapters) do
        need(type(chapter) == "table" and identifier(chapter.chapter_id) and not ids[chapter.chapter_id]
            and integer(chapter.chapter_index) and chapter.chapter_index == array_index - 1
            and type(chapter.title) == "string", "invalid chapter identity or zero-based chapter index")
        ids[chapter.chapter_id] = true
        if epub ~= nil then
            need(chapter.status == "ready"
                and self:is_null(chapter.content_hash)
                and self:is_null(chapter.content_path)
                and self:is_null(chapter.size_bytes),
                "invalid whole-book chapter metadata")
        elseif chapter.status == "ready" then
            need(checksum(chapter.content_hash) and chapter.content_path == "chapters/" .. chapter.content_hash .. ".xhtml"
                and integer(chapter.size_bytes) and chapter.size_bytes > 0, "invalid ready chapter")
        else
            need(chapter.status == "pending" and self:is_null(chapter.content_hash)
                and self:is_null(chapter.content_path) and self:is_null(chapter.size_bytes), "invalid pending chapter")
        end
    end
    -- EPUB bytes were verified atomically during installation. Snapshot
    -- validation only needs to confirm that the immutable artifact is present,
    -- otherwise every reset would re-hash hundreds of megabytes on the Kindle.
    if epub ~= nil then need(self:book_epub_valid(book), "published EPUB is not available locally") end
end

function Store:apply_sync(response)
    return checked(function()
        need(type(response) == "table" and response.protocol_version == 1 and type(response.books) == "table"
            and type(response.deleted_books) == "table" and type(response.bundles) == "table", "invalid sync response")
        if self:is_null(response.sync_id) then
            local meta, meta_err = self:_sync_meta()
            need(meta, meta_err)
            need(#response.books == 0 and #response.deleted_books == 0 and #response.bundles == 0
                and response.reset == false and response.next_cursor == meta.cursor, "invalid unchanged sync response")
            return true, false
        end
        local empty_reset = response.reset == true and self:is_null(response.publication_id)
            and #response.books == 0 and #response.deleted_books == 0 and #response.bundles == 0
        need(identifier(response.sync_id) and identifier(response.next_cursor)
            and (identifier(response.publication_id) or empty_reset)
            and type(response.reset) == "boolean", "invalid sync batch identity")
        local next_state
        local meta, meta_err = self:_sync_meta()
        need(meta, meta_err)
        if response.reset then
            -- A reset is authoritative and must not keep the previous
            -- 15+ MB shelf graph alive in memory while the new snapshot is
            -- already decoded. That peak exceeds available RAM on Kindle.
            next_state = { protocol_version = 1, books = {} }
        else
            local state, state_err = self:state()
            need(state, state_err)
            if meta.pending_ack then
                need(meta.pending_ack.sync_id == response.sync_id and meta.pending_ack.next_cursor == response.next_cursor, "previous sync acknowledgement is pending")
                return true, false
            end
            if meta.last_sync_id == response.sync_id and meta.cursor == response.next_cursor then return true, false end
            need(response.from_cursor == meta.cursor, "sync cursor does not match local confirmed version")
            next_state = state
        end
        local changed = {}
        for book_index, book in ipairs(response.books) do
            self:_validate_book(book)
            need(not changed[book.book_id], "duplicate book in sync batch")
            changed[book.book_id] = true
            if self:is_null(book.epub) then
                for chapter_index, chapter in ipairs(book.chapters) do
                    if chapter.status == "ready" then
                        local ready, content_err = self:chapter_path(chapter, true)
                        need(ready, content_err)
                    end
                end
            end
            next_state.books[book.book_id] = book
        end
        for tombstone_index, tombstone in ipairs(response.deleted_books) do
            need(type(tombstone) == "table" and identifier(tombstone.book_id)
                and not changed[tombstone.book_id], "invalid or conflicting deleted book")
            changed[tombstone.book_id] = true
            next_state.books[tombstone.book_id] = nil
        end
        local applied_ids, bundle_ids = self:array(), {}
        for bundle_index, bundle in ipairs(response.bundles) do
            need(identifier(bundle.bundle_id) and not bundle_ids[bundle.bundle_id], "duplicate applied bundle")
            bundle_ids[bundle.bundle_id] = true
            applied_ids[#applied_ids + 1] = bundle.bundle_id
        end
        self:_apply_sync_meta(next_state, meta)
        next_state.publication_id = response.publication_id
        next_state.pending_ack = { sync_id = response.sync_id, next_cursor = response.next_cursor, applied_bundle_ids = applied_ids }
        self:_save("state", next_state)
        -- The old cursor deliberately remains until the server has accepted
        -- this exact ack. A crash between activation and ack is recoverable.
        return true, true
    end)
end

function Store:pending_ack()
    local meta, err = self:_sync_meta()
    if not meta then return nil, err end
    return meta.pending_ack
end

function Store:confirm_ack(response)
    return checked(function()
        local meta, err = self:_sync_meta()
        need(meta, err)
        need(type(response) == "table" and response.acked == true, "server did not acknowledge sync")
        if not meta.pending_ack then
            need(meta.cursor == response.next_cursor, "unexpected sync acknowledgement cursor")
            return true
        end
        need(response.next_cursor == meta.pending_ack.next_cursor, "sync acknowledgement cursor mismatch")
        meta.cursor = response.next_cursor
        meta.last_sync_id = meta.pending_ack.sync_id
        meta.pending_ack = nil
        need(self:_save("sync-meta", meta))
        self:_update_shelf_sync_metadata(meta)
        return true
    end)
end

function Store:_progress()
    local value = self:_load("progress", { device_seq = "0", pending = self:array(), receipts = {}, positions = {}, versions = {} })
    need(type(value.device_seq) == "string" and value.device_seq:match("^%d+$")
        and type(value.pending) == "table" and type(value.receipts) == "table"
        and type(value.positions) == "table" and type(value.versions) == "table", "invalid persisted progress queue")
    return value
end

function Store:_progress_transaction(callback)
    return self.fs:with_lock(self.root .. "/progress.lock", callback)
end

function Store:queue_progress(device_id, event, local_position)
    return checked(function()
        return self:_progress_transaction(function()
        need(identifier(device_id) and type(event) == "table" and identifier(event.book_id)
            and identifier(event.chapter_id) and identifier(event.binding_version)
            and integer(event.chapter_index) and type(event.chapter_progress) == "number"
            and event.chapter_progress >= 0 and event.chapter_progress <= 1, "invalid reading progress")
        local data = self:_progress()
        need(not data.device_id or data.device_id == device_id, "progress belongs to another paired device")
        data.device_id = device_id
        local queued = copy(event)
        queued.device_seq = increment(data.device_seq)
        queued.event_id = Digest.hex(device_id .. ":" .. queued.device_seq)
        queued.recorded_at = queued.recorded_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
        queued.wire = {
            attempted = false,
            original_base_progress_version = self:is_null(queued.base_progress_version)
                and self.json.null or queued.base_progress_version,
        }
        data.device_seq = queued.device_seq
        data.pending[#data.pending + 1] = queued
        data.positions[queued.book_id] = {
            chapter_id = queued.chapter_id, chapter_index = queued.chapter_index,
            chapter_progress = queued.chapter_progress, device_seq = queued.device_seq,
            local_position = local_position,
        }
        self:_save("progress", data)
        return queued
        end)
    end)
end

function Store:progress_position(book_id)
    return checked(function() return self:_progress().positions[book_id] end)
end

function Store:pending_progress_position(book_id)
    return checked(function()
        local data, latest = self:_progress(), nil
        for event_index, event in ipairs(data.pending) do
            if event.book_id == book_id then latest = event end
        end
        return latest
    end)
end

function Store:progress_snapshot()
    return checked(function()
        local data = self:_progress()
        local pending = {}
        for event_index, event in ipairs(data.pending) do
            pending[event.book_id] = event
        end
        return {
            pending = pending,
            positions = data.positions,
            versions = data.versions,
        }
    end)
end

function Store:progress_position_matches_remote(book_id, remote)
    return checked(function()
        if type(remote) ~= "table" or not identifier(remote.progress_version) then return false end
        local data = self:_progress()
        local version, position = data.versions[book_id], data.positions[book_id]
        return type(version) == "table" and type(position) == "table"
            and version.device_seq == position.device_seq
            and version.progress_version == remote.progress_version
    end)
end

function Store:progress_summary()
    return checked(function()
        local progress = self:_progress()
        local receipt_count = 0
        for receipt_id, receipt in pairs(progress.receipts) do
            if type(receipt_id) == "string" and type(receipt) == "table" then receipt_count = receipt_count + 1 end
        end
        return {
            pending = #progress.pending,
            verified_receipts = receipt_count,
        }
    end)
end

function Store:sync_status()
    return checked(function()
        local meta, meta_err = self:_sync_meta()
        need(meta, meta_err)
        local progress, progress_err = self:progress_summary()
        need(progress, progress_err)
        return {
            last_sync_at = meta.last_sync_at,
            last_sync_attempt_at = meta.last_sync_attempt_at,
            last_sync_error = meta.last_sync_error,
            pending_progress = progress.pending,
            conflict_count = meta.conflict_count or 0,
            conflicts = copy(meta.conflicts or self:array()),
        }
    end)
end

function Store:record_sync_result(error_message, conflicts)
    return checked(function()
        local meta, meta_err = self:_sync_meta()
        need(meta, meta_err)
        local attempted_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        meta.last_sync_attempt_at = attempted_at
        if error_message then
            meta.last_sync_error = tostring(error_message)
        else
            meta.last_sync_at = attempted_at
            meta.last_sync_error = nil
        end
        if type(conflicts) == "table" then
            meta.conflicts = copy(conflicts)
            meta.conflict_count = #conflicts
        end
        need(self:_save("sync-meta", meta))
        self:_update_shelf_sync_metadata(meta)
        return true
    end)
end

function Store:record_conflicts(conflicts)
    return checked(function()
        need(type(conflicts) == "table", "invalid progress conflict list")
        local meta, meta_err = self:_sync_meta()
        need(meta, meta_err)
        meta.conflicts = copy(conflicts)
        meta.conflict_count = #conflicts
        need(self:_save("sync-meta", meta))
        self:_update_shelf_sync_metadata(meta)
        return true
    end)
end

function Store:confirm_resolved_progress(book_id, position, binding_version)
    return checked(function()
        need(identifier(book_id) and type(position) == "table"
            and identifier(position.progress_version) and identifier(position.chapter_id),
            "invalid resolved progress")
        return self:_progress_transaction(function()
            local data = self:_progress()
            local local_position = data.positions[book_id]
            if type(local_position) ~= "table"
                    or local_position.chapter_id ~= position.chapter_id
                    or local_position.chapter_index ~= position.chapter_index
                    or local_position.chapter_progress ~= position.chapter_progress then
                return true
            end
            local previous = type(data.versions[book_id]) == "table" and data.versions[book_id] or {}
            local base_progress_version = previous.base_progress_version
            if base_progress_version == nil then base_progress_version = self.json.null end
            data.versions[book_id] = {
                device_seq = local_position.device_seq,
                progress_version = position.progress_version,
                binding_version = binding_version,
                base_progress_version = base_progress_version,
            }
            need(self:_save("progress", data))
            return true
        end)
    end)
end

function Store:progress_batch(limit)
    return checked(function()
        local data, events = self:_progress(), self:array()
        for index = 1, math.min(limit or 50, #data.pending) do events[index] = copy(data.pending[index]) end
        return events
    end)
end

function Store:prepare_progress_event()
    return self:_progress_transaction(function()
        local data = self:_progress()
        local event = data.pending[1]
        if not event then return nil end

        if type(event.wire) ~= "table" then
            event.wire = {
                attempted = false,
                legacy = true,
                original_base_progress_version = self:is_null(event.base_progress_version)
                    and self.json.null or event.base_progress_version,
            }
        end

        if not event.wire.attempted then
            local original = event.wire.original_base_progress_version
            if self:is_null(original) then original = self.json.null end
            local prepared_base = original
            local version = data.versions[event.book_id]
            local version_binding_matches = version and (version.binding_version == nil
                or version.binding_version == event.binding_version)
            local version_anchor = version and version.base_progress_version
            if self:is_null(version_anchor) then version_anchor = self.json.null end
            if version_binding_matches and version_anchor == original then
                prepared_base = version.progress_version
            end
            event.wire.attempted = true
            event.wire.base_progress_version = prepared_base
            need(self:_save("progress", data))
        end

        local prepared = copy(event)
        prepared.wire = nil
        prepared.base_progress_version = event.wire.base_progress_version
        if self:is_null(prepared.base_progress_version) then prepared.base_progress_version = self.json.null end
        return prepared
    end)
end

function Store:retry_progress_original_payload(event_id, error_code)
    return self:_progress_transaction(function()
        need(error_code == "idempotency_key_reused", "progress wire payload cannot be replaced")
        local data = self:_progress()
        for event_index, event in ipairs(data.pending) do
            if event.event_id == event_id and type(event.wire) == "table"
                    and not event.wire.original_payload_retried then
                local original = event.wire.original_base_progress_version
                if self:is_null(original) then original = self.json.null end
                need(event.wire.base_progress_version ~= original, "original progress payload is already in use")
                event.wire.base_progress_version = original
                event.wire.original_payload_retried = true
                need(self:_save("progress", data))
                return true
            end
        end
        return false
    end)
end

function Store:record_progress_results(response)
    return checked(function()
        return self:_progress_transaction(function()
        need(type(response) == "table" and type(response.results) == "table", "invalid progress acknowledgement")
        local data, pending, acknowledged = self:_progress(), {}, {}
        for event_index, event in ipairs(data.pending) do pending[event.event_id] = event end
        for result_index, result in ipairs(response.results) do
            need(type(result) == "table" and identifier(result.event_id) and not acknowledged[result.event_id]
                and (result.status == "applied" or result.status == "duplicate" or result.status == "conflict" or result.status == "rejected"), "invalid progress result")
            acknowledged[result.event_id] = true
            local event = pending[result.event_id]
            if event then
                -- The complete candidate and server result remain locally
                -- available even after a rejected/conflicting event leaves
                -- the retry queue. Save receipts and removal atomically.
                data.receipts[result.event_id] = { event = event, result = copy(result) }
                if (result.status == "applied" or result.status == "duplicate")
                        and identifier(result.progress_version) and self:is_null(result.conflict_id) then
                    local previous = data.versions[event.book_id]
                    if not previous or newer(event.device_seq, previous.device_seq) then
                        local capture_base = event.base_progress_version
                        if self:is_null(capture_base) then capture_base = self.json.null end
                        data.versions[event.book_id] = {
                            device_seq = event.device_seq,
                            progress_version = result.progress_version,
                            binding_version = event.binding_version,
                            base_progress_version = capture_base,
                        }
                    end
                end
            end
        end
        local remaining = self:array()
        for event_index, event in ipairs(data.pending) do
            if not acknowledged[event.event_id] then remaining[#remaining + 1] = event end
        end
        data.pending = remaining
        return self:_save("progress", data)
        end)
    end)
end

return Store
