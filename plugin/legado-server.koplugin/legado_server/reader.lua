-- Offline chapters rendered by KOReader. There is no second layout engine.
local _ = require("gettext")

local Reader = {}
Reader.__index = Reader

local PRESENTATION_KEYS = {
    font_face = true, font_family_fonts = true, css = true, style_tweaks = true,
    style_tweaks_enabled = true, book_style_tweak = true, book_style_tweak_enabled = true,
    book_style_tweak_last_edit_pos = true, text_lang = true, text_lang_embedded_langs = true,
    hyphenation = true, hyph_force_algorithmic = true, hyph_soft_hyphens_only = true,
    hyph_trust_soft_hyphens = true, floating_punctuation = true, inverse_reading_order = true,
    page_overlap_style = true, hide_nonlinear_flows = true,
}
local function presentation(key)
    return type(key) == "string" and (PRESENTATION_KEYS[key] or key:match("^copt_") or key:match("^kopt_"))
end
local function copy(value, depth)
    if type(value) ~= "table" then return value end
    if (depth or 0) > 8 then return nil end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child, (depth or 0) + 1) end
    return result
end
local function fraction(value)
    return type(value) == "number" and value == value and math.max(0, math.min(1, value)) or nil
end
local function xpointer_fragment(value)
    return type(value) == "string" and tonumber(value:match("/DocFragment%[(%d+)%]")) or nil
end
local function chapter_snapshot(book)
    local chapters = {}
    for position, chapter in ipairs(book.chapters or {}) do
        chapters[position] = {
            chapter_id = chapter.chapter_id,
            chapter_index = chapter.chapter_index,
        }
    end
    return chapters
end

function Reader.new(options)
    return setmetatable({
        store = assert(options.store), ui = assert(options.ui), device_id = options.device_id,
        scheduler = options.scheduler or require("ui/uimanager"),
        docsettings = options.docsettings or require("docsettings"),
        event = options.event or require("ui/event"),
        on_toc = options.on_toc, on_error = options.on_error,
        on_progress = options.on_progress,
    }, Reader)
end

function Reader:_file()
    local document = self.ui and self.ui.document
    return document and (document.file or document.filename)
end

function Reader:session()
    local path = self:_file()
    if type(path) ~= "string" then return nil end
    if self.active and self.active.path == path then return self.active end
    local state = self.store:reader_state()
    if state and state.path == path and state.book_id and state.chapter_id then
        self.active = state
        return state
    end
end

function Reader:_is_epub_session(session)
    return type(session) == "table" and type(session.artifact_sha256) == "string"
end

function Reader:_epub_toc_entries()
    local document, reader_toc = self.ui.document, self.ui.toc
    if not document or not reader_toc then return nil end
    if reader_toc.fillToc then pcall(reader_toc.fillToc, reader_toc) end
    local entries = reader_toc.toc
    if type(entries) ~= "table" or #entries == 0 then
        local called, value = pcall(document.getToc, document)
        if called then entries = value end
    end
    if type(entries) ~= "table" or #entries == 0 then return nil end
    return entries, document, reader_toc
end

-- KOReader can map an arbitrary EPUB XPointer back to its native TOC entry.
-- Prefer that mapping because an EPUB spine item may contain several logical
-- chapters; DocFragment alone only identifies the containing package file.
function Reader:_epub_toc_index(anchor)
    local entries, _document, reader_toc = self:_epub_toc_entries()
    if not entries then return nil end
    if reader_toc and type(reader_toc.getTocIndexByPage) == "function" then
        local called, index = pcall(reader_toc.getTocIndexByPage, reader_toc, anchor)
        if called and type(index) == "number" and index >= 1 and index <= #entries then
            return index
        end
    end
    local fragment = xpointer_fragment(anchor)
    return fragment and fragment >= 1 and fragment <= #entries and fragment or nil
end

function Reader:_epub_chapter_range(chapters, position)
    local entries, document = self:_epub_toc_entries()
    if not entries or type(chapters[position]) ~= "table" then return nil end
    local entry = entries[position]
    if type(entry) ~= "table" then return nil end
    local function entry_page(candidate)
        if type(candidate) ~= "table" then return nil end
        local page = candidate.page
        if type(page) == "number" then return page end
        if type(candidate.xpointer) == "string"
                and type(document.getPageFromXPointer) == "function" then
            local called, value = pcall(document.getPageFromXPointer, document, candidate.xpointer)
            if called and type(value) == "number" then return value end
        end
    end
    local start_page = entry_page(entry)
    if type(start_page) ~= "number" then return nil end
    local end_page = entry_page(entries[position + 1])
    if type(end_page) ~= "number" then
        local called, page_count = pcall(document.getPageCount, document)
        if not called or type(page_count) ~= "number" then return nil end
        end_page = page_count + 1
    end
    return { start_page = start_page, end_page = end_page }
end

function Reader:_epub_measure(session)
    local document = self.ui.document
    if not document or not document.getXPointer then return nil end
    local called, anchor = pcall(document.getXPointer, document)
    if not called or type(anchor) ~= "string" then return nil end
    local toc_position = self:_epub_toc_index(anchor)
    if not toc_position then return nil end
    local chapters = session.chapters
    if type(chapters) ~= "table" then return nil end
    local chapter = chapters[toc_position]
    if not chapter then return nil end
    local range = self:_epub_chapter_range(chapters, toc_position)
    if not range or type(document.getPageFromXPointer) ~= "function" then return nil end
    local page_called, page = pcall(document.getPageFromXPointer, document, anchor)
    if not page_called or type(page) ~= "number" then return nil end
    local ratio = 0
    if range.end_page > range.start_page then
        ratio = (page - range.start_page) / (range.end_page - range.start_page)
    end
    ratio = fraction(ratio) or 0
    session.chapter_id = chapter.chapter_id
    session.chapter_index = chapter.chapter_index
    return {
        session = session,
        ratio = ratio,
        local_position = {
            artifact_sha256 = session.artifact_sha256,
            xpointer = anchor,
        },
    }
end

function Reader:_restore_epub(session, restore)
    local local_position = type(restore.local_position) == "table" and restore.local_position or nil
    local document = self.ui.document
    if local_position and local_position.artifact_sha256 == session.artifact_sha256
            and type(local_position.xpointer) == "string" and document then
        local valid = true
        if type(document.isXPointerInDocument) == "function" then
            local called, result = pcall(document.isXPointerInDocument, document, local_position.xpointer)
            valid = called and result == true
        end
        if valid then
            -- The artifact hash identifies the immutable EPUB, and progress
            -- is only stored together with the chapter it belongs to. Trust
            -- that pair and avoid building the full TOC merely to revalidate
            -- our own bookmark.
            self.ui:handleEvent(self.event:new("GotoXPointer", local_position.xpointer))
            return true
        end
    end
    local chapters = session.chapters or {}
    local position
    for lua_position, chapter in ipairs(chapters) do
        if chapter.chapter_id == restore.chapter_id then
            position = lua_position
            break
        end
    end
    if not position then
        local requested = tonumber(restore.chapter_index)
        position = requested and math.max(1, math.min(#chapters, requested + 1)) or 1
    end
    local range = self:_epub_chapter_range(chapters, position)
    if not range then return nil, _("Cannot map the saved chapter to this EPUB.") end
    local ratio = fraction(restore.chapter_progress) or 0
    local span = math.max(1, range.end_page - range.start_page)
    local target = range.start_page + math.floor(ratio * span + 0.5)
    if target >= range.end_page then target = math.max(range.start_page, range.end_page - 1) end
    self.ui:handleEvent(self.event:new("GotoPage", target))
    return true
end

-- Lua positions are one-based only at this adapter boundary. Protocol
-- chapter_index stays zero-based everywhere in stored books and events.
function Reader:chapter_position(book, chapter_id)
    for lua_position, chapter in ipairs(book.chapters or {}) do
        if chapter.chapter_id == chapter_id then return lua_position end
    end
end

function Reader:reading_progress(book, session, progress_snapshot)
    if type(book) ~= "table" then
        return nil
    end
    local full_book = type(book.chapters) == "table"
    local total = full_book and #book.chapters or tonumber(book.chapter_count)
    if not total or total < 1 or total ~= math.floor(total) then return nil end
    local function progress_position(value)
        if type(value) ~= "table" then return nil end
        local position = self:chapter_position(book, value.chapter_id)
        if not position and not full_book and type(value.chapter_index) == "number"
                and value.chapter_index == math.floor(value.chapter_index)
                and value.chapter_index >= 0 and value.chapter_index < total then
            position = value.chapter_index + 1
        end
        return position
    end
    local position, ratio
    if session == false then
        session = nil
    elseif session == nil then
        session = self:session()
    end
    -- Compact shelf rows intentionally do not retain all chapters. Their
    -- progress comes from the durable pending/synced snapshots instead of
    -- forcing the full book graph back into memory.
    if full_book and session and session.book_id == book.book_id then
        local measured = self:_measure_book(book, session)
        local measured_session = measured and measured.session
        if type(measured_session) == "table" and measured_session.book_id == book.book_id then
            position = self:chapter_position(book, measured_session.chapter_id)
            ratio = fraction(measured.ratio)
        end
        if not position then position = self:chapter_position(book, session.chapter_id) end
    end
    if not position then
        local pending = progress_snapshot
            and progress_snapshot.pending[book.book_id]
            or (not progress_snapshot and self.store:pending_progress_position(book.book_id))
        if pending then
            position = progress_position(pending)
            ratio = pending.chapter_progress
        end
    end
    if not position then
        local local_progress = progress_snapshot
            and progress_snapshot.positions[book.book_id]
            or (not progress_snapshot and self.store:progress_position(book.book_id))
        local remote_progress = type(book.progress) == "table" and book.progress or nil
        local local_position = local_progress
            and progress_position(local_progress) or nil
        local remote_position = remote_progress
            and progress_position(remote_progress) or nil
        local matches_remote = false
        if local_position and remote_position then
            if progress_snapshot then
                local version = progress_snapshot.versions[book.book_id]
                matches_remote = type(version) == "table"
                    and type(remote_progress.progress_version) == "string"
                    and version.device_seq == local_progress.device_seq
                    and version.progress_version == remote_progress.progress_version
            else
                matches_remote = self.store:progress_position_matches_remote(
                    book.book_id, remote_progress) == true
            end
        end
        if local_position and remote_position and matches_remote then
            position, ratio = local_position, local_progress.chapter_progress
        elseif remote_position then
            position, ratio = remote_position, remote_progress.chapter_progress
        elseif local_position then
            position, ratio = local_position, local_progress.chapter_progress
        end
    end
    position = position or 1
    ratio = fraction(ratio) or 0
    local chapter = full_book and book.chapters[position] or nil
    return {
        lua_position = position,
        chapter_index = chapter and chapter.chapter_index or position - 1,
        chapter_progress = ratio,
        total_chapters = total,
        percent = math.max(0, math.min(1, (position - 1 + ratio) / total)),
    }
end

function Reader:current_position(book)
    local progress = self:reading_progress(book)
    return progress and progress.lua_position
end

function Reader:preserve_settings(path, book_id)
    local session, ui = self:session(), self.ui
    if not session or session.book_id ~= book_id or not ui.doc_settings then return false end
    if ui.handleEvent then ui:handleEvent(self.event:new("SaveSettings")) end
    local source = ui.doc_settings.data
    if type(source) ~= "table" then return false end
    local target = self.docsettings:open(path)
    if type(target.data) ~= "table" then return false end
    local keys = {}
    for key in pairs(source) do if presentation(key) then keys[key] = true end end
    for key in pairs(target.data) do if presentation(key) then keys[key] = true end end
    for key in pairs(keys) do target.data[key] = copy(source[key]) end
    target.data.txt_preformatted = nil
    target:flush()
    return true
end

function Reader:_open_epub(book, chapter, options)
    local path = self.store:epub_path(book.book_id)
    if not self.store:book_epub_valid(book, true) then
        return nil, _("The whole-book EPUB is not available locally.")
    end
    local captured, capture_err = self:capture()
    if captured == nil then return nil, capture_err end
    local restore = {
        chapter_id = chapter.chapter_id,
        chapter_index = chapter.chapter_index,
        chapter_progress = 0,
    }
    if not options.from_start then
        local pending = self.store:pending_progress_position(book.book_id)
        local local_progress = self.store:progress_position(book.book_id)
        local remote_progress = type(book.progress) == "table" and book.progress or nil
        if pending and pending.chapter_id == chapter.chapter_id then
            restore.chapter_progress = pending.chapter_progress
            if type(local_progress) == "table" and local_progress.chapter_id == chapter.chapter_id then
                restore.local_position = local_progress.local_position
            end
        elseif options.resume and local_progress and local_progress.chapter_id == chapter.chapter_id
                and remote_progress and remote_progress.chapter_id == chapter.chapter_id
                and self.store:progress_position_matches_remote(book.book_id, remote_progress) then
            restore.chapter_progress = local_progress.chapter_progress
            restore.local_position = local_progress.local_position
        elseif options.resume and remote_progress and remote_progress.chapter_id == chapter.chapter_id then
            restore.chapter_progress = fraction(remote_progress.chapter_progress) or 0
        elseif options.resume and local_progress and local_progress.chapter_id == chapter.chapter_id then
            restore.chapter_progress = local_progress.chapter_progress
            restore.local_position = local_progress.local_position
        end
    end
    local session = {
        book_id = book.book_id,
        artifact_sha256 = book.epub.sha256,
        binding_version = book.binding_version,
        toc_version = book.toc_version,
        chapter_id = chapter.chapter_id,
        chapter_index = chapter.chapter_index,
        chapters = chapter_snapshot(book),
        base_progress_version = type(book.progress) == "table" and book.progress.progress_version or nil,
        path = path,
        restore = restore,
    }
    local saved, save_err = self.store:save_reader_state(session)
    if not saved then return nil, save_err end
    self.active = session
    self.last_saved = nil
    self:preserve_settings(path, book.book_id)
    if self:_file() == path and self.ui.document then
        self.scheduler:nextTick(function()
            if self:_file() ~= path then return end
            local restored, restore_err = self:_restore_epub(session, restore)
            if restored == nil and self.on_error then self.on_error(restore_err) end
            self:page_changed()
        end)
    elseif self.ui.document and type(self.ui.switchDocument) == "function" then
        self.ui:switchDocument(path, true)
    elseif type(self.ui.showReader) == "function" then
        self.ui:showReader(path, nil, true)
    elseif type(self.ui.openFile) == "function" then
        self.ui:openFile(path)
    else
        return nil, _("KOReader cannot open this document.")
    end
    return true, path
end

function Reader:open(book_id, lua_position, options)
    options = options or {}
    local book, err = self.store:book(book_id)
    if not book then return nil, err end
    if type(lua_position) ~= "number" or lua_position ~= math.floor(lua_position)
            or lua_position < 1 or lua_position > #book.chapters then
        return nil, _("Chapter selection is outside the local table of contents.")
    end
    local chapter = book.chapters[lua_position]
    if chapter.chapter_index ~= lua_position - 1 then return nil, _("Invalid chapter index in the local table of contents.") end
    if book.epub and not self.store:is_null(book.epub) then
        return self:_open_epub(book, chapter, options)
    end
    local path, path_err = self.store:reading_path(book_id, chapter)
    if not path then return nil, path_err end
    local captured, capture_err = self:capture()
    if captured == nil then return nil, capture_err end
    self:preserve_settings(path, book_id)
    local restore
    if options.from_start then
        restore = { chapter_progress = 0 }
    else
        local pending = self.store:pending_progress_position(book_id)
        local local_progress = self.store:progress_position(book_id)
        local remote_progress = type(book.progress) == "table" and book.progress or nil
        if pending and pending.chapter_id == chapter.chapter_id then
            restore = { chapter_progress = pending.chapter_progress }
        elseif local_progress and local_progress.chapter_id == chapter.chapter_id
                and remote_progress and remote_progress.chapter_id == chapter.chapter_id
                and self.store:progress_position_matches_remote(book_id, remote_progress) then
            restore = { chapter_progress = local_progress.chapter_progress, local_position = local_progress.local_position }
        elseif options.resume and remote_progress and remote_progress.chapter_id == chapter.chapter_id then
            restore = { chapter_progress = fraction(remote_progress.chapter_progress) }
        elseif options.resume and not remote_progress and local_progress
                and local_progress.chapter_id == chapter.chapter_id then
            restore = { chapter_progress = local_progress.chapter_progress, local_position = local_progress.local_position }
        end
    end
    local saved, save_err = self.store:save_reader_state{
        book_id = book_id, chapter_id = chapter.chapter_id, chapter_index = chapter.chapter_index,
        binding_version = book.binding_version, base_progress_version = type(book.progress) == "table" and book.progress.progress_version or nil,
        content_hash = chapter.content_hash, path = path, restore = restore,
    }
    if not saved then return nil, save_err end
    if self.ui.document and type(self.ui.switchDocument) == "function" then
        self.ui:switchDocument(path, true)
    elseif type(self.ui.showReader) == "function" then
        self.ui:showReader(path, nil, true)
    elseif type(self.ui.openFile) == "function" then
        self.ui:openFile(path)
    else
        return nil, _("KOReader cannot open this document.")
    end
    return true, path
end

function Reader:_measure_rolling(session)
    if not self.ui.rolling then return nil end
    local ok, ratio = pcall(self.ui.rolling.getLastPercent, self.ui.rolling)
    ratio = ok and fraction(ratio)
    if not ratio then return nil end
    local anchor = self.ui.rolling.xpointer
    if type(anchor) ~= "string" and self.ui.document.getXPointer then
        local got, value = pcall(self.ui.document.getXPointer, self.ui.document)
        if got then anchor = value end
    end
    return {
        session = copy(session), ratio = ratio,
        local_position = { content_hash = session.content_hash, xpointer = type(anchor) == "string" and anchor or nil },
    }
end

function Reader:_measure_book(book, session)
    if not session then return nil end
    if self:_is_epub_session(session) then
        return self:_epub_measure(session)
    end
    return self:_measure_rolling(session)
end

function Reader:measure()
    local session = self:session()
    if not session then return nil end
    if self:_is_epub_session(session) then
        return self:_epub_measure(session)
    end
    return self:_measure_book(nil, session)
end

function Reader:capture()
    local measured = self:measure()
    if not measured or not self.device_id then return false end
    local previous = self.last_saved
    if previous and previous.session.path == measured.session.path and previous.ratio == measured.ratio
            and previous.local_position.xpointer == measured.local_position.xpointer then return false end
    local session = measured.session
    local event, err = self.store:queue_progress(self.device_id, {
        book_id = session.book_id, chapter_id = session.chapter_id, chapter_index = session.chapter_index,
        chapter_progress = measured.ratio, binding_version = session.binding_version,
        base_progress_version = session.base_progress_version,
    }, measured.local_position)
    if not event then return nil, err end
    self.last_saved = measured
    if self.on_progress then self.on_progress(measured) end
    return true
end

function Reader:cancel_capture()
    if self.capture_job then self.scheduler:unschedule(self.capture_job); self.capture_job = nil end
end

function Reader:page_changed()
    if not self:session() or self.capture_job then return end
    self.capture_job = function()
        self.capture_job = nil
        local saved, err = self:capture()
        if saved == nil and self.on_error then self.on_error(err) end
    end
    self.scheduler:scheduleIn(10, self.capture_job)
end

function Reader:close()
    self:cancel_capture()
    local saved, err = self:capture()
    if saved == nil and self.on_error then self.on_error(err) end
end

function Reader:advance(offset)
    local session = self:session()
    if not session then return false end
    if self:_is_epub_session(session) then return false end
    local book, err = self.store:book(session.book_id)
    if not book then return nil, err end
    local current = self:chapter_position(book, session.chapter_id)
    if not current then return nil, _("The current chapter is no longer in the published table of contents.") end
    local next_position = current + offset
    if next_position < 1 or next_position > #book.chapters then return false end
    return self:open(book.book_id, next_position, { from_start = true })
end

function Reader:install_hooks()
    local controller, status, toc = self, self.ui.status, self.ui.toc
    if status and type(status.onEndOfBook) == "function" and not status._legado_server_end then
        local original = status.onEndOfBook
        status._legado_server_end = true
        status.onEndOfBook = function(instance, ...)
            local session = controller:session()
            if session and controller:_is_epub_session(session) then
                return original(instance, ...)
            end
            local book = session and controller.store:book(session.book_id)
            local position = book and controller:chapter_position(book, session.chapter_id)
            if position and position < #book.chapters then
                if not controller.transition_pending then
                    controller.transition_pending = true
                    controller.scheduler:nextTick(function()
                        controller.transition_pending = false
                        local opened, err = controller:advance(1)
                        if opened == nil and controller.on_error then controller.on_error(err) end
                    end)
                end
                return true
            end
            return original(instance, ...)
        end
    end
    if toc and type(toc.onShowToc) == "function" and not toc._legado_server_toc then
        local original = toc.onShowToc
        toc._legado_server_toc = true
        toc.onShowToc = function(instance, ...)
            local session = controller:session()
            if session and controller:_is_epub_session(session) then
                return original(instance, ...)
            end
            if session and controller.on_toc then controller.on_toc(session.book_id); return true end
            return original(instance, ...)
        end
    end
end

function Reader:ready()
    self:install_hooks()
    local session = self:session()
    if not session then return end
    if self:_is_epub_session(session) then
        if type(session.chapters) ~= "table" then
            local book, book_err = self.store:book(session.book_id)
            if not book then if self.on_error then self.on_error(book_err) end; return end
            session.chapters = chapter_snapshot(book)
            local saved, save_err = self.store:save_reader_state(session)
            if not saved then if self.on_error then self.on_error(save_err) end; return end
        end
        local restore = type(session.restore) == "table" and session.restore or nil
        if restore then
            session.restore = nil
            local saved, save_err = self.store:save_reader_state(session)
            if not saved then if self.on_error then self.on_error(save_err) end; return end
        end
        self.scheduler:nextTick(function()
            if self:_file() ~= session.path then return end
            if restore then
                local restored, restore_err = self:_restore_epub(session, restore)
                if restored == nil and self.on_error then self.on_error(restore_err) end
            end
            self:page_changed()
        end)
        return
    end
    if type(session.restore) == "table" then
        local restore = session.restore
        session.restore = nil
        local saved, err = self.store:save_reader_state(session)
        if not saved then if self.on_error then self.on_error(err) end; return end
        self.scheduler:nextTick(function()
            if self:_file() ~= session.path then return end
            local local_position = restore.local_position
            if type(local_position) == "table" and local_position.content_hash == session.content_hash
                    and type(local_position.xpointer) == "string" then
                self.ui:handleEvent(self.event:new("GotoXPointer", local_position.xpointer))
            elseif fraction(restore.chapter_progress) then
                self.ui:handleEvent(self.event:new("GotoPercent", fraction(restore.chapter_progress) * 100))
            end
            self:page_changed()
        end)
    else
        self:page_changed()
    end
end

return Reader
