local _ = require("gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local PathChooser = require("ui/widget/pathchooser")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local Trapper = require("ui/trapper")
local TrapWidget = require("ui/widget/trapwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local rapidjson = require("rapidjson")

-- Keep plugin modules under a namespaced directory. KOReader temporarily adds
-- the plugin directory to package.path while loading the entry point.
local Storage = require("legado/storage")
local Backup = require("legado/backup")
local Content = require("legado/content")
local EmojiFont = require("legado/font")
local SourceCatalog = require("legado/source")
local BrowserInput = require("legado/browser_input")

local Legado = WidgetContainer:extend{
    name = "legado",
    fullname = _("Legado"),
}

local function display_text(value)
    -- Keep source/book text byte-for-byte intact.  Emoji rendering is handled
    -- by the optional Symbola fallback installed by this plugin.
    return tostring(value or "")
end

-- These are the settings that affect how a text chapter is rendered.  The
-- copt_/kopt_ prefixes cover current and future KOReader configurable options
-- without copying document state such as last_xpointer or page_positions.
local READER_PREFERENCE_KEYS = {
    font_face = true,
    font_family_fonts = true,
    css = true,
    style_tweaks = true,
    style_tweaks_enabled = true,
    book_style_tweak = true,
    book_style_tweak_enabled = true,
    book_style_tweak_last_edit_pos = true,
    txt_preformatted = true,
}

local function is_reader_preference_key(key)
    return type(key) == "string"
        and (key:match("^copt_") or key:match("^kopt_")
            or READER_PREFERENCE_KEYS[key])
end

local function get_global_reader_font_face()
    -- ReaderFont gives a document's font_face precedence over KOReader's
    -- global cre_font default.  Do not let a profile that was created from
    -- that default permanently hide later changes made in KOReader.
    local settings = rawget(_G, "G_reader_settings")
    if not settings or type(settings.readSetting) ~= "function" then
        return nil
    end
    local ok, face = pcall(function()
        return settings:readSetting("cre_font")
    end)
    if ok and type(face) == "string" and face ~= "" then
        return face
    end
    return nil
end

function Legado:init()
    self.storage = Storage:new()
    -- ReaderUI has already opened doc_settings before plugin instances are
    -- created, but its DocSettingsLoad event is not guaranteed to reach
    -- third-party modules on every KOReader release.  Seed the current
    -- chapter's settings here, before ReaderUI emits ReadSettings, so the
    -- native reader modules initialize from the book-wide Legado profile.
    self:loadActiveReaderPreferences()
    self.emoji_font_ready, self.emoji_font_copied, self.emoji_font_error =
        EmojiFont:ensure_installed()
    if self.emoji_font_ready then
        EmojiFont:enable_ui_fallback()
    end
    self.ui.menu:registerToMainMenu(self)
    Dispatcher:registerAction("legado_show_status", {
        category = "none",
        event = "LegadoShowStatus",
        title = _("Legado: show status"),
        general = true,
    })
    Dispatcher:registerAction("legado_show_bookshelf", {
        category = "none",
        event = "LegadoShowBookshelf",
        title = _("Legado: open bookshelf"),
        general = true,
    })
    Dispatcher:registerAction("legado_reader_toc", {
        category = "none",
        event = "LegadoReaderToc",
        title = _("Legado: open chapter list"),
        reader = true,
    })
    Dispatcher:registerAction("legado_next_chapter", {
        category = "none",
        event = "LegadoNextChapter",
        title = _("Legado: next chapter"),
        reader = true,
    })
    Dispatcher:registerAction("legado_previous_chapter", {
        category = "none",
        event = "LegadoPreviousChapter",
        title = _("Legado: previous chapter"),
        reader = true,
    })
    if self.ui and self.ui.document then
        self:installReaderHooks()
    elseif self.emoji_font_copied then
        -- In the file manager there is no document yet, so CRe cannot be
        -- updated in-process. The next KOReader launch will scan ./fonts.
        UIManager:nextTick(function()
            UIManager:askForRestart()
        end)
    end
end

function Legado:addToMainMenu(menu_items)
    -- The bookshelf is the reader-facing home screen. Keep it as a first
    -- level entry so users do not have to remember that it lives under the
    -- source/backup tools submenu. The nested Legado entry groups reading,
    -- source settings, backup/restore and diagnostics.
    menu_items.legado_bookshelf = {
        text = _("Legado bookshelf"),
        sorting_hint = "main",
        callback = function()
            self:showBookshelf()
        end,
    }
    if self:getActiveReaderSession() then
        menu_items.legado_reader_toc = {
            text = _("Legado chapter list"),
            sorting_hint = "navi",
            callback = function()
                self:showReaderChapterList()
            end,
        }
        menu_items.legado_next_chapter = {
            text = _("Legado next chapter"),
            sorting_hint = "navi",
            callback = function()
                self:advanceReaderChapter(1)
            end,
        }
        menu_items.legado_previous_chapter = {
            text = _("Legado previous chapter"),
            sorting_hint = "navi",
            callback = function()
                self:advanceReaderChapter(-1)
            end,
        }
    end
    menu_items.legado = {
        text = self.fullname,
        sorting_hint = "main",
        -- Menu:onMenuSelect only traverses a concrete sub_item_table. A
        -- sub_item_table_func merely makes an item look expandable.
        sub_item_table = self:getSubMenuItems(),
    }
end

function Legado:getSubMenuItems()
    local items = {
        {
            text = _("Open bookshelf"),
            callback = function()
                self:showBookshelf()
            end,
        },
        {
            text = _("Source settings"),
            sub_item_table = self:getSourceSettingsMenuItems(),
        },
        {
            text = _("Backup & restore"),
            sub_item_table = self:getBackupMenuItems(),
        },
        {
            text = _("Diagnostics"),
            sub_item_table = self:getDiagnosticsMenuItems(),
        },
    }
    local session = self:getActiveReaderSession()
    if session then
        table.insert(items, 2, {
            text = _("Reading"),
            sub_item_table = self:getReadingMenuItems(),
        })
    end
    return items
end

function Legado:getReadingMenuItems()
    return {
        {
            text = _("Open current chapter list"),
            callback = function()
                self:showReaderChapterList()
            end,
        },
        {
            text = _("Next chapter"),
            callback = function()
                self:advanceReaderChapter(1)
            end,
        },
        {
            text = _("Previous chapter"),
            callback = function()
                self:advanceReaderChapter(-1)
            end,
        },
        {
            text = T(_("Prefetch next %1 chapters"), self.storage:get_prefetch_count()),
            callback = function()
                self:choosePrefetchCount()
            end,
        },
    }
end

function Legado:getSourceSettingsMenuItems()
    return {
        {
            text = _("Source list"),
            callback = function()
                self:showSourceList()
            end,
        },
        {
            text = _("Add source"),
            sub_item_table = self:getAddSourceMenuItems(),
        },
        {
            text = _("Search text sources"),
            callback = function()
                self:chooseSearchSource()
            end,
        },
    }
end

function Legado:getAddSourceMenuItems()
    return {
        {
            text = _("Enter source JSON"),
            callback = function()
                self:showAddSourceDialog()
            end,
        },
        {
            text = _("Import source JSON file"),
            callback = function()
                self:chooseSourceJsonFile()
            end,
        },
    }
end

function Legado:getBackupMenuItems()
    return {
        {
            text = _("Import Android backup"),
            callback = function()
                self:chooseBackupFile()
            end,
        },
        {
            text = _("Export Android backup"),
            callback = function()
                self:chooseExportDirectory()
            end,
        },
    }
end

function Legado:getDiagnosticsMenuItems()
    return {
        {
            text = _("Show local status"),
            callback = function()
                self:onLegadoShowStatus()
            end,
        },
        {
            text = _("Source compatibility status"),
            callback = function()
                self:onSourceCompatibility()
            end,
        },
        {
            text = _("Data directory"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = self.storage:get_root(),
                })
            end,
        },
    }
end

function Legado:showOperationResult(message, on_dismiss)
    UIManager:show(InfoMessage:new{
        text = display_text(message),
        dismiss_callback = on_dismiss,
    })
end

function Legado:openDownloadedFile(filename, seamless)
    if self.ui and self.ui.document and type(self.ui.switchDocument) == "function" then
        self.ui:switchDocument(filename, seamless == true)
    elseif self.ui and type(self.ui.showReader) == "function" then
        self.ui:showReader(filename, nil, seamless == true)
    elseif self.ui and type(self.ui.openFile) == "function" then
        self.ui:openFile(filename)
    else
        self:showOperationResult(_("Cannot open downloaded file:\n") .. display_text(filename))
    end
end

function Legado:runWorker(message, task, on_success, options)
    options = options or {}
    local trap_widget = options.trap_widget
    if options.interactive and not trap_widget then
        -- A source action may open the Kindle Chromium bridge and wait for
        -- real user input.  Trapper's normal TrapWidget interprets the first
        -- touch as "dismiss/cancel the worker", even when Chromium is the
        -- visible foreground client.  Keep a full-screen guard so the
        -- underlying KOReader UI cannot also consume the touch, but make the
        -- guard non-dismissable for this kind of task.  The browser's own
        -- completion control remains the explicit end of the action.
        trap_widget = TrapWidget:new{
            text = message,
        }
        trap_widget._dismissAndResend = function(_, event_type, event)
            -- The Kindle browser is a separate X client.  KOReader's input
            -- trap still receives the raw touch while the browser is raised,
            -- so pass the completed gesture to the browser worker instead of
            -- dismissing the worker as a normal background task would do.
            BrowserInput.send(event_type, event)
            return true
        end
        -- A slow drag is reported by KOReader as a stream of `pan` events,
        -- followed by `pan_release`, rather than as one `swipe`. TrapWidget
        -- normally does not register `pan`, so a browser page would receive
        -- neither the movement nor enough information to reconstruct it.
        -- Capture that stream as well; browser.lua keeps one CDP touch active
        -- until the matching release arrives.
        trap_widget.ges_events.BrowserPanDismiss = {
            GestureRange:new{
                ges = "pan",
                range = Geom:new{
                    x = 0,
                    y = 0,
                    w = Device.screen:getWidth(),
                    h = Device.screen:getHeight(),
                },
            },
        }
        trap_widget.onBrowserPanDismiss = function(_, _, event)
            BrowserInput.send("Gesture", event)
            return true
        end
        UIManager:show(trap_widget)
        UIManager:forceRePaint()
    end
    local trap_target
    if options.invisible then
        -- Background work should not put a modal progress surface over the
        -- page. nil asks Trapper to use its invisible event-resending trap.
        trap_target = nil
    else
        trap_target = trap_widget ~= nil and trap_widget or message
    end

    local function release_trap()
        if not trap_widget then return end
        if options.keep_trap then
            if options.reset_trap_callback then
                options.reset_trap_callback()
            end
            return
        end
        -- A dismiss callback installed by Trapper would otherwise try to
        -- resume the worker coroutine while it is already unwinding.
        trap_widget.dismiss_callback = nil
        UIManager:close(trap_widget)
    end

    local function report_failure(error_message)
        release_trap()
        if options.on_failure then
            options.on_failure(error_message)
        else
            self:showOperationResult(message .. "\n\n" .. tostring(error_message or "unknown error"))
        end
    end

    -- The subprocess returns one JSON string.  This keeps network and HTML
    -- parsing away from the e-ink UI thread while allowing structured results.
    Trapper:wrap(function()
        local completed, payload = Trapper:dismissableRunInSubprocess(function()
            local rapidjson = require("rapidjson")
            local ok, result, err = pcall(task)
            if ok and result ~= nil then
                return rapidjson.encode({ ok = true, result = result })
            end
            return rapidjson.encode({
                ok = false,
                error = tostring(err or result or "worker failed"),
            })
        end, trap_target, true)
        if not completed then
            if options.on_cancel then options.on_cancel() end
            return
        end
        if not payload then
            report_failure("worker returned no data")
            return
        end
        local rapidjson = require("rapidjson")
        local ok, response = pcall(rapidjson.decode, payload)
        if not ok or type(response) ~= "table" then
            report_failure(_("Operation returned invalid data."))
            return
        end
        if response.ok ~= true then
            report_failure(response.error or "unknown error")
            return
        end
        release_trap()
        on_success(response.result)
    end)
end

local function chapter_key(chapter)
    if type(chapter) ~= "table" then return "" end
    return tostring(chapter.url or chapter.id or chapter.name or "")
end

local function same_path(left, right)
    local function normalize(path)
        path = tostring(path or "")
        -- DataStorage deliberately returns "." on Kindle.  The resulting
        -- chapter paths are relative, while ReaderUI may expose an absolute
        -- path (and the reverse can happen after a restart).  realpath()
        -- makes both forms comparable and also handles test/book symlinks.
        return FFIUtil.realpath(path) or path:gsub("^%./", "")
    end
    return normalize(left) == normalize(right)
end

function Legado:getActiveReaderSession()
    if not self.ui or not self.ui.document then return nil end
    local current_file = self.ui.document.file or self.ui.document.filename
    if type(current_file) ~= "string" or current_file == "" then return nil end
    local session = self.storage:load_reader_session()
    if not session or type(session.chapters) ~= "table" then return nil end

    -- Use the actual document path rather than only current_index.  This also
    -- recovers gracefully if KOReader was closed after the user selected a
    -- different cached chapter.
    for index, chapter in ipairs(session.chapters) do
        if same_path(current_file, self.storage:get_chapter_path(session.book, chapter)) then
            session.current_index = index
            return session
        end
    end
    return nil
end

function Legado:getReaderPreferenceSnapshot()
    if not self.ui or not self.ui.doc_settings then return nil end
    local preferences = {}
    local data = self.ui.doc_settings.data
    if type(data) == "table" then
        for key, value in pairs(data) do
            if is_reader_preference_key(key) then
                preferences[key] = value
            end
        end
    end

    -- The live configurable object is ahead of doc_settings until KOReader's
    -- SaveSettings event.  This matters when the user taps Next Chapter
    -- immediately after changing font size, spacing or margins.
    local document = self.ui.document
    local configurable = document and document.configurable
    if type(configurable) == "table" then
        for key, value in pairs(configurable) do
            local value_type = type(value)
            if (value_type == "number" or value_type == "string"
                    or value_type == "table") and type(key) == "string" then
                preferences["copt_" .. key] = value
            end
        end
    end

    -- Capture the live module values as well: these are not all held in the
    -- document's configurable object, and can change before SaveSettings.
    local font = self.ui.font
    if font then
        preferences.font_face = font.font_face
        preferences.font_family_fonts = font.font_family_fonts
    end
    local typeset = self.ui.typeset
    if typeset then
        preferences.css = typeset.css
        preferences.txt_preformatted = typeset.txt_preformatted
    end
    local style_tweak = self.ui.styletweak
    if style_tweak then
        preferences.style_tweaks = style_tweak.doc_tweaks
        if style_tweak.enabled == false then
            preferences.style_tweaks_enabled = false
        else
            preferences.style_tweaks_enabled = nil
        end
        preferences.book_style_tweak = style_tweak.book_style_tweak
        preferences.book_style_tweak_enabled = style_tweak.book_style_tweak_enabled
        preferences.book_style_tweak_last_edit_pos = style_tweak.book_style_tweak_last_edit_pos
    end
    return preferences
end

function Legado:syncReaderFontPreference(book, preferences)
    if type(book) ~= "table" or type(preferences) ~= "table" then
        return false
    end

    local global_face = get_global_reader_font_face()
    if not global_face then return false end

    local previous = self.storage:load_reader_preferences(book)
    local previous_face = previous and previous.font_face
    local previous_global = previous and previous._legado_global_font_face
    local previous_explicit = previous
        and previous._legado_font_face_explicit == true
    local changed = false

    -- Profiles written before this metadata existed were seeded from the
    -- current chapter. Treat them as following KOReader's default, so an
    -- already changed global font can take effect immediately. New profiles
    -- use the same rule unless the user selects a different face for this
    -- book in the reader.
    local follows_global = previous and not previous_explicit
    local old_profile = previous and previous._legado_font_face_explicit == nil
    if previous and (follows_global or old_profile)
            and previous_face and preferences.font_face == previous_face
            and previous_face ~= global_face
            and (previous_global == nil or previous_global ~= global_face) then
        preferences.font_face = global_face
        changed = true
    end

    local current_face = preferences.font_face
    local explicit = previous_explicit or false
    if not previous or not previous._legado_font_face_explicit
            or current_face ~= previous_face then
        -- A face different from the global default is a deliberate
        -- book-level choice. A face equal to it continues to follow global
        -- KOReader changes on future chapter transitions.
        explicit = current_face ~= global_face
    end

    if preferences._legado_font_face_explicit ~= explicit then
        preferences._legado_font_face_explicit = explicit
        changed = true
    end
    if preferences._legado_global_font_face ~= global_face then
        preferences._legado_global_font_face = global_face
        changed = true
    end
    return changed
end

function Legado:saveActiveReaderPreferences()
    local session = self:getActiveReaderSession()
    local preferences = self:getReaderPreferenceSnapshot()
    if not session or not preferences then return false end
    self:syncReaderFontPreference(session.book, preferences)
    return self.storage:save_reader_preferences(session.book, preferences)
end

function Legado:flushActiveReaderSettings()
    -- ReaderConfig keeps font/layout changes in memory until KOReader's
    -- SaveSettings event.  Chapter navigation can happen before the normal
    -- document-close path, so explicitly flush the current document first.
    if not self.ui or type(self.ui.saveSettings) ~= "function" then return false end
    self.ui:saveSettings()
    return true
end

function Legado:applyReaderPreferences(config, preferences)
    if type(config) ~= "table" or type(preferences) ~= "table" then
        return false
    end
    for key, value in pairs(preferences) do
        if is_reader_preference_key(key) then
            config:saveSetting(key, value)
        end
    end
    return true
end

function Legado:loadActiveReaderPreferences(config)
    local session = self:getActiveReaderSession()
    config = config or (self.ui and self.ui.doc_settings)
    if not session or not config then return false end
    local preferences = self.storage:load_reader_preferences(session.book)
    if not preferences then return false end
    self:syncReaderFontPreference(session.book, preferences)
    return self:applyReaderPreferences(config, preferences)
end

function Legado:resolveReaderSource(session)
    if type(session) ~= "table" then return nil, "reading session is missing" end
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    if session.source_url and session.source_url ~= "" then
        local source = catalog:find_by_url(session.source_url)
        if source then return source end
    end
    local sources, err = catalog:list()
    if not sources then return nil, err end
    for _, source in ipairs(sources) do
        if source.bookSourceName == session.source_name
                and tonumber(source.bookSourceType or 0) == 0 then
            return source
        end
    end
    return nil, "book source for reading session not found"
end

function Legado:installReaderHooks()
    local status = self.ui and self.ui.status
    local plugin = self
    if status and type(status.onEndOfBook) == "function"
            and not status._legado_end_of_book_hook then
        local original_on_end = status.onEndOfBook
        status._legado_end_of_book_hook = true
        status.onEndOfBook = function(status_instance, ...)
            if plugin:onLegadoEndOfBook() then
                return true
            end
            return original_on_end(status_instance, ...)
        end
    end

    -- A cached Legado chapter is a standalone TXT, so CRe quite correctly
    -- reports no native ToC. Redirect the standard KOReader ToC action to the
    -- source chapter list only while a Legado reading session is active.
    local toc = self.ui and self.ui.toc
    if toc and type(toc.onShowToc) == "function"
            and not toc._legado_show_toc_hook then
        local original_on_show_toc = toc.onShowToc
        toc._legado_show_toc_hook = true
        toc.onShowToc = function(toc_instance, ...)
            if plugin:getActiveReaderSession() then
                return plugin:showReaderChapterList()
            end
            return original_on_show_toc(toc_instance, ...)
        end
    end
end

function Legado:onDocSettingsLoad(_doc_settings, document)
    self:loadActiveReaderPreferences(_doc_settings)
    if not self.emoji_font_ready or type(document) ~= "table" then return end
    local registered = EmojiFont:register_with_cre()
    EmojiFont:add_document_fallback(document)
    if self.emoji_font_copied and not registered then
        UIManager:nextTick(function()
            UIManager:askForRestart()
        end)
    end
end

function Legado:onReaderReady()
    self:installReaderHooks()
    -- Seed a profile for existing sessions and keep it current after a normal
    -- KOReader settings flush.  Subsequent Legado chapters will inherit it.
    self:saveActiveReaderPreferences()
    if self.emoji_font_ready and self.ui and self.ui.document then
        -- This is also useful when CRe was initialized before the plugin and
        -- the fallback list was rebuilt by a document reload.
        EmojiFont:add_document_fallback(self.ui.document)
    end
    UIManager:nextTick(function()
        self:startReaderPrefetch()
    end)
end

function Legado:onSaveSettings()
    self:saveActiveReaderPreferences()
end

function Legado:cancelReaderPrefetch()
    self._prefetch_generation = (self._prefetch_generation or 0) + 1
    self._prefetch_running = false
end

function Legado:onCloseDocument()
    self:cancelReaderPrefetch()
    self._reader_transition_busy = false
end

function Legado:startReaderPrefetch()
    local session = self:getActiveReaderSession()
    if not session or self._prefetch_running then return false end
    local source = self:resolveReaderSource(session)
    if not source then return false end

    local count = self.storage:get_prefetch_count()
    local first = session.current_index + 1
    local last = math.min(#session.chapters, session.current_index + count)
    local pending = {}
    for index = first, last do
        local chapter = session.chapters[index]
        if not self.storage:chapter_is_readable(session.book, chapter) then
            pending[#pending + 1] = index
        end
    end
    if #pending == 0 then return false end

    self._prefetch_generation = (self._prefetch_generation or 0) + 1
    local generation = self._prefetch_generation
    self._prefetch_running = true

    local function finish()
        if self._prefetch_generation == generation then
            self._prefetch_running = false
        end
    end

    local function fetch_next(position)
        if self._prefetch_generation ~= generation
                or not self.ui or not self.ui.document then
            finish()
            return
        end
        local chapter_index = pending[position]
        if not chapter_index then
            finish()
            return
        end
        local chapter = session.chapters[chapter_index]
        self:runWorker(false, function()
            local Runtime = require("legado/runtime")
            local content, err = Runtime.chapter_content(source, chapter, session.book)
            if not content then return nil, err or "prefetch failed" end
            return content
        end, function(content)
            if self._prefetch_generation ~= generation then
                finish()
                return
            end
            local path = self.storage:write_chapter(session.book, chapter, content)
            if not path then
                finish()
                return
            end
            UIManager:nextTick(function()
                fetch_next(position + 1)
            end)
        end, {
            invisible = true,
            -- Prefetch must never interrupt an otherwise usable reading
            -- session with an error dialog. The chapter remains uncached and
            -- normal foreground navigation can retry it later.
            on_failure = finish,
            on_cancel = finish,
        })
    end

    fetch_next(1)
    return true
end

function Legado:choosePrefetchCount()
    local current = self.storage:get_prefetch_count()
    local items = {}
    for _, count in ipairs({ 5, 6, 7, 8, 9, 10 }) do
        items[#items + 1] = {
            text = T(_("Prefetch next %1 chapters"), count),
            mandatory = count == current and _("Current") or nil,
            count = count,
        }
    end
    local menu
    menu = Menu:new{
        title = _("Prefetch chapter count"),
        item_table = items,
        items_per_page = 6,
        onMenuSelect = function(menu_instance, item)
            UIManager:close(menu_instance)
            local saved = self.storage:save_prefetch_count(item.count)
            self:cancelReaderPrefetch()
            self:showOperationResult(T(_("Prefetch count set to %1 chapters."), saved))
            UIManager:nextTick(function()
                self:startReaderPrefetch()
            end)
        end,
    }
    UIManager:show(menu)
end

function Legado:onLegadoEndOfBook()
    local session = self:getActiveReaderSession()
    if not session then return false end
    if self._reader_transition_busy then return true end

    -- Switch documents on the next UI turn.  ReaderStatus is currently
    -- handling EndOfBook, and changing its document from inside that event
    -- can otherwise race with the normal page-turn cleanup.
    self._reader_transition_busy = true
    UIManager:nextTick(function()
        if self.ui and self.ui.document then
            self:advanceReaderChapter(1, session, true, true)
        else
            self._reader_transition_busy = false
        end
    end)
    return true
end

function Legado:showReaderChapterList()
    local session = self:getActiveReaderSession()
    if not session then
        self:showOperationResult(_("The current document is not a Legado chapter."))
        return false
    end
    -- The current reading session already contains the complete TOC that was
    -- used to open this chapter. Rendering it locally avoids repeating the
    -- source's book-info and chapter-list requests just to open the
    -- reader's directory. Resolve the source only when an action needs it.
    self:showChapterMenu(nil, session.book, session.chapters, {
        current_index = session.current_index,
        reader_session = session,
    })
    return true
end

function Legado:openReaderChapter(session, target_index, seamless)
    self:cancelReaderPrefetch()
    -- Save before the session index changes.  Otherwise selecting a chapter
    -- from the local chapter list would make the old document look unrelated
    -- to the session before ReaderUI emits SaveSettings.
    self:flushActiveReaderSettings()
    self:saveActiveReaderPreferences()
    local chapter = session.chapters[target_index]
    if not chapter then
        self._reader_transition_busy = false
        return false
    end
    local source, source_err = self:resolveReaderSource(session)
    if not source then
        self._reader_transition_busy = false
        self:showOperationResult(_("Cannot match the reading session source:\n") .. tostring(source_err))
        return false
    end
    local readable, path = self.storage:chapter_is_readable(session.book, chapter)
    if readable then
        self.storage:save_reader_session(
            session.book, source, session.chapters, target_index
        )
        self.storage:save_last_chapter(session.book, chapter)
        self._reader_transition_busy = false
        UIManager:nextTick(function()
            self:openDownloadedFile(path, seamless)
        end)
        return true
    end

    self:downloadChapter(source, session.book, chapter, session.chapters, {
        seamless = seamless,
        reader_transition = true,
    })
    return true
end

function Legado:refreshReaderSession(session, advance_after_refresh)
    if not self._reader_transition_busy then
        self._reader_transition_busy = true
    end
    self:cancelReaderPrefetch()
    local source, source_err = self:resolveReaderSource(session)
    if not source then
        self._reader_transition_busy = false
        self:showOperationResult(_("Cannot refresh the chapter list:\n") .. tostring(source_err))
        return false
    end
    local current = session.chapters[session.current_index]
    local current_key = chapter_key(current)
    self:runWorker(_("Refreshing chapter list…"), function()
        local Runtime = require("legado/runtime")
        local result, err = Runtime.chapter_list(source, session.book)
        if not result then return nil, err or "chapter list refresh failed" end
        return result
    end, function(result)
        if type(result) ~= "table" or type(result.chapters) ~= "table"
                or #result.chapters == 0 then
            self._reader_transition_busy = false
            self:showOperationResult(_("Refreshed chapter list is empty."))
            return
        end
        local display_book = result.info or session.book
        local current_index
        for index, chapter in ipairs(result.chapters) do
            if chapter_key(chapter) == current_key then
                current_index = index
                break
            end
        end
        current_index = current_index or math.min(session.current_index, #result.chapters)
        self.storage:save_reader_session(
            display_book, source, result.chapters, current_index
        )
        local refreshed_session = {
            book = display_book,
            chapters = result.chapters,
            current_index = current_index,
            source_url = source.bookSourceUrl or "",
            source_name = source.bookSourceName or "",
        }
        if advance_after_refresh and current_index < #result.chapters then
            self:openReaderChapter(refreshed_session, current_index + 1, true)
        elseif not advance_after_refresh then
            self._reader_transition_busy = false
            self:showChapterMenu(source, display_book, result.chapters, {
                current_index = current_index,
                reader_session = refreshed_session,
            })
        else
            self._reader_transition_busy = false
            self:showOperationResult(_("Chapter list refreshed; you are at the latest chapter."))
        end
    end, {
        on_failure = function(error_message)
            self._reader_transition_busy = false
            self:showOperationResult(_("Cannot refresh the chapter list:\n") .. tostring(error_message))
        end,
        on_cancel = function()
            self._reader_transition_busy = false
        end,
    })
    return true
end

function Legado:advanceReaderChapter(delta, supplied_session, seamless, already_busy)
    local session = supplied_session or self:getActiveReaderSession()
    if not session then
        if not already_busy then
            self:showOperationResult(_("The current document is not a Legado chapter."))
        end
        return false
    end
    if not already_busy then
        if self._reader_transition_busy then return false end
        self._reader_transition_busy = true
    end
    local step = tonumber(delta) or 1
    local target_index = session.current_index + (step >= 0 and math.floor(step) or math.ceil(step))
    if target_index < 1 then
        self._reader_transition_busy = false
        self:showOperationResult(_("This is the first chapter."))
        return false
    end
    if target_index > #session.chapters then
        if step > 0 then
            return self:refreshReaderSession(session, true)
        end
        self._reader_transition_busy = false
        self:showOperationResult(_("This is the latest chapter."))
        return false
    end
    -- Chapter navigation is part of one reading session, so avoid the normal
    -- file-open overlay and use KOReader's seamless document switch by
    -- default.  Callers can explicitly pass false when needed.
    return self:openReaderChapter(session, target_index, seamless ~= false)
end

local function source_display_name(source)
    if type(source) ~= "table" then
        return _("Unnamed source")
    end
    return source.bookSourceName or source.bookSourceUrl or _("Unnamed source")
end

local function source_type_label(source)
    local source_type = tonumber(source and source.bookSourceType or 0) or 0
    if source_type == 0 then
        return _("Text")
    end
    return T(_("Type %1"), tostring(source_type))
end

local function source_has_login(source)
    if type(source) ~= "table" then
        return false
    end
    if type(source.loginUrl) == "string" and source.loginUrl:gsub("%s+", "") ~= "" then
        return true
    end
    -- Legado also treats a pure JavaScript source with mainJs + loginUi as
    -- exposing login/actions, even when loginUrl is absent.
    local has_main_js = type(source.mainJs) == "string"
        and source.mainJs:gsub("%s+", "") ~= ""
    local login_ui = source.loginUi
    local has_login_ui
    if type(login_ui) == "table" then
        has_login_ui = next(login_ui) ~= nil
    elseif type(login_ui) == "string" then
        local compact = login_ui:gsub("%s+", "")
        has_login_ui = compact ~= "" and compact ~= "[]"
    end
    return has_main_js and has_login_ui
end

local function copy_source(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function validate_source(source)
    if type(source) ~= "table" then
        return nil, "source JSON must contain an object"
    end
    local name = tostring(source.bookSourceName or "")
    local url = tostring(source.bookSourceUrl or "")
    if name == "" then
        return nil, "source is missing bookSourceName"
    end
    if url == "" then
        return nil, "source is missing bookSourceUrl"
    end
    return true
end

local function decode_source_json(raw, allow_array)
    local decoded_ok, decoded = pcall(rapidjson.decode, raw or "")
    if not decoded_ok or type(decoded) ~= "table" then
        return nil, "source JSON is invalid: " .. tostring(decoded)
    end

    local sources = {}
    local looks_like_source = decoded.bookSourceName ~= nil
        or decoded.bookSourceUrl ~= nil
        or decoded.searchUrl ~= nil
        or decoded.ruleSearch ~= nil
    if looks_like_source then
        sources[1] = decoded
    elseif allow_array then
        for index, source in ipairs(decoded) do
            local valid, validation_err = validate_source(source)
            if not valid then
                return nil, "source " .. tostring(index) .. ": " .. validation_err
            end
            sources[#sources + 1] = source
        end
    else
        return nil, "source JSON must contain one source object"
    end
    if #sources == 0 then
        return nil, "source JSON contains no sources"
    end
    for index, source in ipairs(sources) do
        local valid, validation_err = validate_source(source)
        if not valid then
            return nil, "source " .. tostring(index) .. ": " .. validation_err
        end
        if source.bookSourceType == nil then
            source.bookSourceType = 0
        end
    end
    return sources
end

function Legado:mergeSourceJson(raw)
    local incoming, decode_err = decode_source_json(raw, true)
    if not incoming then
        return nil, decode_err
    end
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    local sources, source_err = catalog:list()
    if not sources then
        return nil, source_err
    end

    local added = 0
    local replaced = 0
    for _, source in ipairs(incoming) do
        local source_url = tostring(source.bookSourceUrl or "")
        local existing_index
        for index, existing in ipairs(sources) do
            if type(existing) == "table"
                    and tostring(existing.bookSourceUrl or "") == source_url then
                existing_index = index
                break
            end
        end
        if existing_index then
            sources[existing_index] = source
            replaced = replaced + 1
        else
            sources[#sources + 1] = source
            added = added + 1
        end
    end

    local _, save_err = catalog:replace_sources(sources)
    if save_err then
        return nil, save_err
    end
    return {
        added = added,
        replaced = replaced,
        total = #sources,
    }
end

function Legado:importSourceJson(raw, retry_input)
    self:runWorker(_("Saving source list…"), function()
        return self:mergeSourceJson(raw)
    end, function(result)
        self:showOperationResult(string.format(
            _("Source list saved.\nAdded: %s\nReplaced: %s\nTotal: %s"),
            tostring(result and result.added or 0),
            tostring(result and result.replaced or 0),
            tostring(result and result.total or 0)
        ), function()
            self:showSourceList()
        end)
    end, {
        on_failure = function(error_message)
            self:showOperationResult(
                _("Cannot save source list:\n") .. tostring(error_message),
                function()
                    if retry_input then
                        self:showAddSourceDialog(retry_input)
                    else
                        self:showSourceList()
                    end
                end
            )
        end,
    })
end

function Legado:showAddSourceDialog(initial_input)
    local dialog
    dialog = InputDialog:new{
        title = _("Add source"),
        description = _("Paste one source object or an array of source objects in JSON."),
        input = initial_input or '{\n  "bookSourceName": "Example",\n  "bookSourceUrl": "https://example.invalid",\n  "bookSourceType": 0\n}',
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local raw = dialog:getInputValue() or ""
                        UIManager:close(dialog)
                        self:importSourceJson(raw, raw)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:chooseSourceJsonFile()
    local chooser = PathChooser:new{
        title = _("Choose a source JSON file"),
        select_directory = false,
        select_file = true,
        path = self.storage:get_default_path(),
        file_filter = function(filename)
            return tostring(filename or ""):lower():match("%.json$") ~= nil
        end,
        onConfirm = function(filename)
            local file, open_err = io.open(filename, "rb")
            if not file then
                self:showOperationResult(_("Cannot open source file:\n") .. tostring(open_err))
                return
            end
            local raw = file:read("*a") or ""
            file:close()
            self:importSourceJson(raw)
        end,
    }
    UIManager:show(chooser)
end

function Legado:showSourceList()
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    local sources, err = catalog:list()
    if not sources then
        self:showOperationResult(_("Cannot load source list:\n") .. tostring(err))
        return
    end
    local items = {}
    for index, source in ipairs(sources) do
        if type(source) == "table" then
            local enabled = source.enabled == false and _("Disabled") or _("Enabled")
            items[#items + 1] = {
                text = display_text(source_display_name(source)),
                mandatory = enabled .. " | " .. source_type_label(source),
                source = source,
                source_index = index,
            }
        end
    end
    if #items == 0 then
        self:showOperationResult(_("The source list is empty. Add a source or import an Android backup."))
        return
    end
    local source_menu
    source_menu = Menu:new{
        title = _("Source list"),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            -- Keep the list as the parent menu. The selected source's action
            -- menu is shown above it, so the hardware Back gesture returns to
            -- this list instead of the KOReader home screen.
            self:showSourceActions(item.source, item.source_index, menu)
        end,
    }
    self._source_list_menu = source_menu
    UIManager:show(source_menu)
end

function Legado:showSourceActions(source, source_index, source_list_menu)
    local items = {}
    if source_has_login(source) then
        items[#items + 1] = {
            text = _("Login / actions"),
            keep_menu = true,
            callback = function()
                self:showSourceLogin(source)
            end,
        }
    end
    if type(source.searchUrl) == "string" and source.searchUrl ~= "" then
        items[#items + 1] = {
            text = _("Search with this source"),
            keep_menu = true,
            callback = function()
                self:showSearchDialog(source)
            end,
        }
    end
    items[#items + 1] = {
        text = _("Edit source"),
        callback = function()
            self:showEditSourceDialog(source, source_index)
        end,
    }
    items[#items + 1] = {
        text = source.enabled == false and _("Enable source") or _("Disable source"),
        callback = function()
            local updated = copy_source(source)
            updated.enabled = source.enabled == false
            self:runSourceMutation(source_index, updated, _("Updating source…"), function()
                return updated.enabled and _("Source enabled.") or _("Source disabled.")
            end)
        end,
    }
    items[#items + 1] = {
        text = _("Delete source"),
        callback = function()
            self:confirmDeleteSource(source_index, source)
        end,
    }

    local action_menu
    action_menu = Menu:new{
        title = T(_("Source actions: %1"), display_text(source_display_name(source))),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            -- Keep the source actions menu underneath login/search dialogs so
            -- backing out of those flows returns to the selected source.
            if not item.keep_menu then
                UIManager:close(menu)
                if source_list_menu then
                    UIManager:close(source_list_menu)
                end
            end
            if item.callback then
                item.callback()
            end
        end,
    }
    UIManager:show(action_menu)
end

function Legado:runSourceMutation(source_index, updated_source, message, success_message)
    self:runWorker(message, function()
        local catalog = SourceCatalog:new(self.storage:get_state_root())
        local _, err = catalog:update_source(source_index, updated_source)
        if err then return nil, err end
        return true
    end, function()
        self:showOperationResult(success_message(), function()
            self:showSourceList()
        end)
    end, {
        on_failure = function(error_message)
            self:showOperationResult(
                _("Source operation failed:\n") .. tostring(error_message),
                function()
                    self:showSourceList()
                end
            )
        end,
    })
end

function Legado:confirmDeleteSource(source_index, source)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete source %1?"), display_text(source_display_name(source))),
        ok_text = _("Delete"),
        ok_callback = function()
            self:runWorker(_("Deleting source…"), function()
                local catalog = SourceCatalog:new(self.storage:get_state_root())
                local _, err = catalog:remove_source(source_index)
                if err then return nil, err end
                return true
            end, function()
                self:showOperationResult(_("Source deleted."), function()
                    self:showSourceList()
                end)
            end, {
                on_failure = function(error_message)
                    self:showOperationResult(
                        _("Cannot delete source:\n") .. tostring(error_message),
                        function()
                            self:showSourceList()
                        end
                    )
                end,
            })
        end,
    })
end

function Legado:showEditSourceDialog(source, source_index)
    local encoded_ok, encoded = pcall(rapidjson.encode, source)
    if not encoded_ok then
        self:showOperationResult(_("Cannot encode source JSON:\n") .. tostring(encoded))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = T(_("Edit source: %1"), display_text(source_display_name(source))),
        description = _("Edit the complete source object as JSON."),
        input = encoded,
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local raw = dialog:getInputValue() or ""
                        local _, validation_err = decode_source_json(raw, false)
                        if validation_err then
                            self:showOperationResult(_("Invalid source JSON:\n") .. validation_err)
                            return
                        end
                        UIManager:close(dialog)
                        self:runWorker(_("Updating source…"), function()
                            local updated, decode_err = decode_source_json(raw, false)
                            if not updated then return nil, decode_err end
                            local catalog = SourceCatalog:new(self.storage:get_state_root())
                            local _, update_err = catalog:update_source(source_index, updated[1])
                            if update_err then return nil, update_err end
                            return true
                        end, function()
                            self:showOperationResult(_("Source updated."), function()
                                self:showSourceList()
                            end)
                        end, {
                            on_failure = function(error_message)
                                self:showOperationResult(
                                    _("Cannot update source:\n") .. tostring(error_message),
                                    function()
                                        self:showSourceList()
                                    end
                                )
                            end,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:chooseLoginSource()
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    local sources, err = catalog:list()
    if not sources then
        self:showOperationResult(_("Cannot load sources:\n") .. tostring(err))
        return
    end
    local items = {}
    for _, source in ipairs(sources) do
        if source.enabled ~= false
                and tonumber(source.bookSourceType or 0) == 0
                and source_has_login(source) then
            items[#items + 1] = {
                text = display_text(source.bookSourceName or _("Unnamed source")),
                mandatory = display_text(source.bookSourceGroup),
                source = source,
            }
        end
    end
    if #items == 0 then
        self:showOperationResult(_("No enabled text source with login or source actions."))
        return
    end
    local source_menu
    source_menu = Menu:new{
        title = _("Choose a source to log in"),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            self:showSourceLogin(item.source)
        end,
    }
    UIManager:show(source_menu)
end

local function login_control_type(control)
    return tostring(control and (control.type or control.inputType) or "text"):lower()
end

local function login_control_name(control, index)
    local name = control and (control.name or control.key or control.id or control.label)
    name = tostring(name or "")
    return name ~= "" and name or ("field_" .. tostring(index))
end

local function login_control_value(control, saved, name)
    local value = type(saved) == "table" and saved[name] or nil
    if value == nil and type(control) == "table" then
        value = control.value
        if value == nil then value = control.default end
        if value == nil and control.checked ~= nil then value = control.checked end
    end
    if value == nil then
        return ""
    elseif type(value) == "boolean" then
        return value and "true" or "false"
    end
    return tostring(value)
end

function Legado:showGenericLoginDialog(source)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Login data for %1"), display_text(source.bookSourceName or _("text source"))),
        description = _("Enter the login fields as a JSON object."),
        input = "",
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Continue"),
                    is_enter_default = true,
                    callback = function()
                        local raw = dialog:getInputValue()
                        local decoded_ok, values = pcall(require("rapidjson").decode, raw or "")
                        if not decoded_ok or type(values) ~= "table" then
                            self:showOperationResult(_("Enter a valid JSON object, for example {\"user\":\"name\"}."))
                            return
                        end
                        UIManager:close(dialog)
                        self:showSourceLoginActions(source, {}, values)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:showSourceLogin(source)
    local controls
    local raw_ui = source.loginUi
    if type(raw_ui) == "table" then
        controls = raw_ui
    elseif type(raw_ui) == "string" and raw_ui ~= "" then
        local decoded_ok, decoded = pcall(require("rapidjson").decode, raw_ui)
        if decoded_ok and type(decoded) == "table" then
            controls = decoded
        end
    end
    if type(controls) ~= "table" then
        self:showGenericLoginDialog(source)
        return
    end

    local saved, saved_err = require("legado/runtime").login_info(source)
    if not saved then
        self:showOperationResult(_("Cannot load saved login data:\n") .. tostring(saved_err))
        return
    end
    local fields = {}
    local field_names = {}
    local buttons = {}
    local unsupported = {}
    for index, control in ipairs(controls) do
        if type(control) == "table" then
            local control_type = login_control_type(control)
            if control_type == "button" or control_type == "submit" then
                buttons[#buttons + 1] = control
            elseif control_type == "text" or control_type == "password"
                    or control_type == "number" or control_type == "textarea"
                    or control_type == "email" or control_type == "url"
                    or control_type == "tel" then
                local name = login_control_name(control, index)
                local field = {
                    description = tostring(control.description or name),
                    text = login_control_value(control, saved, name),
                    hint = tostring(control.hint or control.placeholder or name),
                }
                if control_type == "password" then
                    field.text_type = "password"
                elseif control_type == "number" then
                    field.input_type = "number"
                elseif control_type == "textarea" then
                    field.allow_newline = true
                end
                fields[#fields + 1] = field
                field_names[#field_names + 1] = name
            elseif control_type == "checkbox" or control_type == "switch" then
                -- These controls are represented as text because loginUrl
                -- receives strings in most Android sources as well.
                local name = login_control_name(control, index)
                fields[#fields + 1] = {
                    description = tostring(control.description or name),
                    text = login_control_value(control, saved, name),
                    hint = tostring(control.hint or control.placeholder or name)
                        .. " (true/false)",
                }
                field_names[#field_names + 1] = name
            elseif control_type ~= "label" and control_type ~= "divider" then
                unsupported[#unsupported + 1] = control_type
            end
        end
    end
    if #unsupported > 0 then
        self:showOperationResult(
            _("This source login form contains unsupported controls:") .. " " .. table.concat(unsupported, ", ")
        )
        return
    end
    if #fields == 0 then
        self:showSourceLoginActions(source, buttons, saved)
        return
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = T(_("Login to %1"), display_text(source.bookSourceName or _("text source"))),
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Actions"),
                    is_enter_default = true,
                    callback = function()
                        local entered = dialog:getFields()
                        local values = {}
                        -- Preserve saved fields which are intentionally not
                        -- displayed by loginUi (for example an existing API
                        -- key or source-specific optional setting).
                        for key, value in pairs(saved) do
                            values[key] = value
                        end
                        for index, name in ipairs(field_names) do
                            values[name] = entered[index] or ""
                        end
                        UIManager:close(dialog)
                        self:showSourceLoginActions(source, buttons, values)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:showSourceLoginActions(source, buttons, values)
    if type(buttons) ~= "table" or #buttons == 0 then
        self:runSourceLogin(source, values, "login()", _("login"))
        return
    end
    local items = {}
    for _, control in ipairs(buttons) do
        local action = control.action or control.onClick or control.callback
        if action and tostring(action) ~= "" then
            items[#items + 1] = {
                text = display_text(control.name or control.label or action),
                action = tostring(action),
            }
        end
    end
    if #items == 0 then
        self:runSourceLogin(source, values, "login()", _("login"))
        return
    end
    local action_menu
    action_menu = Menu:new{
        title = T(_("Actions for %1"), display_text(source.bookSourceName or _("text source"))),
        item_table = items,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            -- This is not a special source-family API. It is an ordinary
            -- Legado loginUi action; the source decides
            -- whether it opens a browser, updates source variables, or
            -- returns a status value. Keep every action on that same generic
            -- path so imported sources remain interchangeable.
            self:runSourceLogin(source, values, item.action, item.text, {
                keep_actions = true,
                buttons = buttons,
            })
        end,
    }
    UIManager:show(action_menu)
end

function Legado:showSourceActionResult(source, buttons, values, message)
    self:showOperationResult(message, function()
        -- Keep the login form's action loop alive. Dismissing the result must
        -- not send the user back to KOReader's home screen after every click.
        self:showSourceLoginActions(source, buttons, values)
    end)
end

local function login_values_from_result(result, fallback)
    local value = result and result.loginInfo
    if type(value) == "table" then
        return value
    end
    if type(value) == "string" and value ~= "" then
        local decoded_ok, decoded = pcall(rapidjson.decode, value)
        if decoded_ok and type(decoded) == "table" then
            return decoded
        end
    end
    return fallback
end

local function append_source_result(lines, title, value)
    if value == nil then
        return
    end
    local text = tostring(value)
    if text == "" then
        return
    end
    -- A malformed source should not be able to fill an InfoMessage with a
    -- complete HTTP response.  Normal status messages are much shorter.
    local maximum = 4096
    if #text > maximum then
        text = text:sub(1, maximum) .. "\n[...]"
    end
    lines[#lines + 1] = title .. "\n" .. text
end

local function append_source_notifications(lines, notifications)
    if type(notifications) ~= "table" or #notifications == 0 then
        return
    end
    local messages = {}
    for _, notification in ipairs(notifications) do
        local operation = ""
        local message = notification
        if type(notification) == "table" then
            operation = tostring(notification.operation or "")
            message = notification.message
        end
        message = tostring(message or "")
        if message ~= "" then
            local prefix = operation == "toast" and "Toast" or "Log"
            messages[#messages + 1] = prefix .. ": " .. message
        end
    end
    if #messages > 0 then
        append_source_result(lines, _("Source messages:"), table.concat(messages, "\n"))
    end
end

function Legado:runSourceLogin(source, values, action, label, context)
    context = context or {}
    local function show_result(message, next_values)
        if context.keep_actions then
            self:showSourceActionResult(
                source,
                context.buttons,
                next_values or values,
                message
            )
        else
            self:showOperationResult(message)
        end
    end

    self:runWorker(T(_("Running source action: %1"), label or action or _("login")), function()
        local Runtime = require("legado/runtime")
        local result, err = Runtime.login_source(source, values, action)
        if not result then error(err or "source login failed") end
        return result
    end, function(result)
        local lines = {
            string.format(
                _("Source action completed: %s"),
                display_text(label or (result and result.action) or action or _("login"))
            ),
            string.format(
                _("Cookies saved: %s"),
                tostring(result and result.cookieCount or 0)
            ),
        }
        append_source_result(lines, _("Action return value:"), result and result.actionResult)
        append_source_result(lines, _("Login check return value:"), result and result.loginCheckResult)
        append_source_notifications(lines, result and result.notifications)
        if result and result.verified then
            lines[#lines + 1] = _("Login check passed.")
        end
        if result and result.loginInfoSaved then
            lines[#lines + 1] = _("Login data saved.")
        end
        if result and result.sourceVariableSaved then
            lines[#lines + 1] = _("Source variables saved.")
        end
        if context.keep_actions then
            lines[#lines + 1] = _("Tap to continue with Actions.")
        end
        show_result(table.concat(lines, "\n"), login_values_from_result(result, values))
    end, {
        on_failure = function(error_message)
            show_result(string.format(
                _("Source action failed: %s\n\n%s"),
                display_text(label or action or _("login")),
                tostring(error_message or "unknown error")
            ))
        end,
        on_cancel = function()
            if context.keep_actions then
                self:showSourceLoginActions(source, context.buttons, values)
            end
        end,
        interactive = true,
    })
end

function Legado:chooseSearchSource()
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    local sources, err = catalog:list()
    if not sources then
        self:showOperationResult(_("Cannot load sources:\n") .. tostring(err))
        return
    end
    local items = {}
    for _, source in ipairs(sources) do
        if source.enabled ~= false
                and tonumber(source.bookSourceType or 0) == 0
                and type(source.searchUrl) == "string"
                and source.searchUrl ~= "" then
            items[#items + 1] = {
                text = display_text(source.bookSourceName or _("Unnamed source")),
                mandatory = display_text(source.bookSourceGroup),
                source = source,
            }
        end
    end
    if #items == 0 then
        self:showOperationResult(_("No enabled text source with a search URL."))
        return
    end
    local source_menu
    source_menu = Menu:new{
        title = _("Choose a text source"),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            self:showSearchDialog(item.source)
        end,
    }
    UIManager:show(source_menu)
end

function Legado:showBookshelf()
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    local books, err = catalog:books()
    if not books then
        self:showOperationResult(_("Cannot load bookshelf:\n") .. tostring(err))
        return
    end
    local items = {}
    for index, book in ipairs(books) do
        if index > 100 then break end
        if type(book) == "table" and book.name and book.name ~= "" then
            local author = book.author and book.author ~= ""
                and ("\n" .. display_text(book.author)) or ""
            items[#items + 1] = {
                text = display_text(book.name) .. author,
                mandatory = display_text(book.originName or book.origin),
                book = book,
            }
        end
    end
    if #items == 0 then
        self:showOperationResult(_("Bookshelf is empty. Import an Android backup or search and download a book."))
        return
    end
    local book_menu
    book_menu = Menu:new{
        title = _("Legado bookshelf"),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            local source, source_err = catalog:find_for_book(item.book)
            if not source then
                self:showOperationResult(_("Cannot match book source:\n") .. tostring(source_err))
                return
            end
            self:showChapters(source, item.book)
        end,
    }
    UIManager:show(book_menu)
end

function Legado:showSearchDialog(source)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Search in %1"), display_text(source.bookSourceName or _("text source"))),
        input = "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local keyword = dialog:getInputValue()
                        UIManager:close(dialog)
                        if not keyword or keyword == "" then
                            self:showOperationResult(_("Search keyword cannot be empty."))
                            return
                        end
                        self:searchSource(source, keyword)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:searchSource(source, keyword)
    self:runWorker(_("Searching…"), function()
        local Runtime = require("legado/runtime")
        local books, err = Runtime.search_source(source, keyword, 1)
        if not books then return nil, err or "search failed" end
        return books
    end, function(books)
        if type(books) ~= "table" or #books == 0 then
            self:showOperationResult(_("No books found."))
            return
        end
        self:showSearchResults(source, books)
    end)
end

function Legado:showSearchResults(source, books)
    local items = {}
    for index, book in ipairs(books) do
        if index > 100 then break end
        local author = book.author and book.author ~= ""
            and ("\n" .. display_text(book.author)) or ""
        items[#items + 1] = {
            text = display_text(book.name or _("Unnamed book")) .. author,
            mandatory = display_text(book.lastChapter),
            book = book,
        }
    end
    local result_menu
    result_menu = Menu:new{
        title = _("Search results"),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            self:showChapters(source, item.book)
        end,
    }
    UIManager:show(result_menu)
end

function Legado:showChapterMenu(source, display_book, chapters, options)
    options = options or {}
    if type(chapters) ~= "table" or #chapters == 0 then
        self:showOperationResult(_("Chapter list is empty."))
        return false
    end

    local last_chapter = tonumber(options.current_index)
        or self.storage:get_last_chapter(display_book)
    if last_chapter and not chapters[last_chapter] then
        last_chapter = nil
    end
    local result = {
        info = display_book,
        chapters = chapters,
    }
    local resolved_source = source
    local function get_source()
        if resolved_source then return resolved_source end
        if not options.reader_session then return nil end
        local source_err
        resolved_source, source_err = self:resolveReaderSource(options.reader_session)
        if not resolved_source then
            self:showOperationResult(
                _("Cannot match the reading session source:\n") .. tostring(source_err)
            )
        end
        return resolved_source
    end
    local items = {}
    if last_chapter then
        items[#items + 1] = {
            text = T(_("Continue reading chapter %1"), last_chapter),
            mandatory = display_text(chapters[last_chapter].name),
            continue = true,
            chapter = chapters[last_chapter],
            separator = true,
        }
    end
    items[#items + 1] = {
        text = T(_("Download entire book (%1 chapters)"), #chapters),
        mandatory = _("EPUB + TXT"),
        bulk = true,
    }
    items[#items + 1] = {
        text = _("Jump to chapter number"),
        mandatory = last_chapter and (tostring(last_chapter) .. "/" .. tostring(#chapters))
            or ("1/" .. tostring(#chapters)),
        jump = true,
    }
    if options.reader_session then
        items[#items + 1] = {
            text = _("Refresh chapter list"),
            mandatory = _("Network request"),
            refresh = true,
        }
    end
    for index, chapter in ipairs(chapters) do
        local downloaded = self.storage:chapter_exists(display_book, chapter)
        local flags = {}
        if downloaded then flags[#flags + 1] = _("Downloaded") end
        if chapter.vip then flags[#flags + 1] = _("VIP") end
        items[#items + 1] = {
            text = display_text(chapter.name or _("Unnamed chapter")),
            mandatory = #flags > 0 and table.concat(flags, " · ") or nil,
            chapter = chapter,
            bold = last_chapter == index,
        }
    end
    local chapter_menu
    chapter_menu = Menu:new{
        title = display_text(display_book.name or _("Chapters")) .. " · "
            .. tostring(#chapters) .. " chapters",
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            local action_source = get_source()
            if not action_source then return end
            if item.refresh then
                UIManager:close(menu)
                self:refreshReaderSession(options.reader_session, false)
                return
            end
            if item.jump then
                UIManager:close(menu)
                self:showChapterJump(action_source, display_book, result)
                return
            end
            UIManager:close(menu)
            if item.bulk then
                self:downloadBook(action_source, display_book, chapters)
            else
                self:openOrDownloadChapter(action_source, display_book, item.chapter, chapters)
            end
        end,
    }
    UIManager:show(chapter_menu)
    return true
end

function Legado:showChapters(source, book)
    self:runWorker(_("Loading chapter list…"), function()
        local Runtime = require("legado/runtime")
        local result, err = Runtime.chapter_list(source, book)
        if not result then return nil, err or "chapter list failed" end
        return result
    end, function(result)
        if type(result) ~= "table" then
            self:showOperationResult(_("Chapter list is empty."))
            return
        end
        local display_book = result.info or book
        self:showChapterMenu(source, display_book, result.chapters)
    end)
end

function Legado:showChapterJump(source, book, result)
    local chapters = result and result.chapters or {}
    local total = #chapters
    if total == 0 then return end
    local current = self.storage:get_last_chapter(book) or 1
    current = math.max(1, math.min(total, current))
    local dialog
    dialog = InputDialog:new{
        title = T(_("Jump to a chapter in %1"), display_text(book.name or _("book"))),
        input = tostring(current),
        input_hint = T(_("Enter 1-%1"), total),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Open"),
                    is_enter_default = true,
                    callback = function()
                        local index = tonumber(dialog:getInputValue())
                        if not index or index < 1 or index > total or index % 1 ~= 0 then
                            self:showOperationResult(T(_("Enter a whole number from 1 to %1."), total))
                            return
                        end
                        UIManager:close(dialog)
                        self:openOrDownloadChapter(source, book, chapters[index], chapters)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:openOrDownloadChapter(source, book, chapter, chapters)
    -- Preserve the current chapter's live font/layout choices before replacing
    -- the session with the selected target chapter.
    self:flushActiveReaderSettings()
    self:saveActiveReaderPreferences()
    if chapters then
        self.storage:save_reader_session(book, source, chapters, chapter.index)
    end
    local readable, path = self.storage:chapter_is_readable(book, chapter)
    self.storage:save_last_chapter(book, chapter)
    if readable then
        self:openDownloadedFile(path)
    else
        self:downloadChapter(source, book, chapter, chapters)
    end
end

function Legado:downloadChapter(source, book, chapter, chapters, options)
    options = options or {}
    local function failure(error_message)
        if options.reader_transition then
            self._reader_transition_busy = false
        end
        if options.on_failure then
            options.on_failure(error_message)
        else
            self:showOperationResult(_("Cannot download chapter:\n") .. tostring(error_message))
        end
    end
    self:runWorker(_("Downloading chapter…"), function()
        local Runtime = require("legado/runtime")
        local content, err = Runtime.chapter_content(source, chapter, book)
        if not content then return nil, err or "chapter download failed" end
        return content
    end, function(content)
        local filename, err = self.storage:write_chapter(book, chapter, content)
        if not filename then
            failure(err)
            return
        end
        if chapters then
            self.storage:save_reader_session(book, source, chapters, chapter.index)
        end
        self.storage:save_last_chapter(book, chapter)
        if options.reader_transition then
            self._reader_transition_busy = false
        end
        self:openDownloadedFile(filename, options.seamless == true)
    end, {
        on_failure = failure,
        on_cancel = function()
            if options.reader_transition then
                self._reader_transition_busy = false
            end
        end,
    })
end

function Legado:downloadBook(source, book, chapters)
    local total = type(chapters) == "table" and #chapters or 0
    if total == 0 then
        self:showOperationResult(_("Chapter list is empty."))
        return
    end
    if total > 5000 then
        self:showOperationResult(_("This book has more than 5000 chapters; download it in smaller ranges."))
        return
    end

    -- Download one chapter per subprocess.  This keeps the maximum network
    -- response/JSON payload small, lets the progress bar repaint between
    -- chapters, and makes a cancelled download resumable from chapter cache.
    local state = {
        done = 0,
        cancelled = false,
        sections = {},
    }
    local dialog = ProgressbarDialog:new{
        title = T(_("Downloading book (%1 chapters)"), total),
        subtitle = _("Cached chapters are skipped. Tap to stop; completed chapters are kept."),
        progress_max = total,
        refresh_time_seconds = 0.5,
        dismiss_text = _("Stop downloading? Completed chapters will be kept."),
    }

    local function reset_cancel_callback()
        dialog.dismiss_callback = function()
            state.cancelled = true
        end
    end

    local function close_dialog(message)
        dialog.dismiss_callback = nil
        UIManager:close(dialog)
        if message then self:showOperationResult(message) end
    end

    local function fail(index, error_message)
        close_dialog(string.format(
            _("Download stopped at chapter %s/%s.\n%s\n\nCompleted chapters were kept and can be resumed."),
            tostring(index), tostring(total), tostring(error_message or "unknown error")
        ))
    end

    local function finish()
        if state.cancelled then
            close_dialog(_("Download cancelled. Completed chapters were kept."))
            return
        end
        local filename, err = self.storage:write_book(book, state.sections)
        if not filename then
            close_dialog(_("Cannot save downloaded book:\n") .. tostring(err))
            return
        end
        local epub_filename = self.storage:write_epub(book, state.sections)
        -- Opening the result is the completion affordance.  Do not leave an
        -- InfoMessage above the newly opened reader document.
        close_dialog(nil)
        self:openDownloadedFile(epub_filename or filename)
    end

    local function next_chapter()
        if state.cancelled then
            close_dialog(_("Download cancelled. Completed chapters were kept."))
            return
        end
        local index = state.done + 1
        if index > total then
            finish()
            return
        end
        local chapter = chapters[index]
        local readable = self.storage:chapter_is_readable(book, chapter)
        if readable then
            local cached_content = self.storage:read_chapter_content(book, chapter)
            if cached_content ~= nil then
                state.sections[index] = {
                    index = index,
                    title = chapter.name or ("Chapter " .. tostring(index)),
                    content = cached_content,
                }
                state.done = index
                dialog:reportProgress(index)
                reset_cancel_callback()
                UIManager:nextTick(next_chapter)
                return
            end
        end

        self:runWorker(T(_("Downloading chapter %1/%2…"), index, total), function()
            local Runtime = require("legado/runtime")
            local content, err = Runtime.chapter_content(source, chapter, book)
            if not content then return nil, err or "chapter download failed" end
            return content
        end, function(content)
            if state.cancelled then
                close_dialog(_("Download cancelled. Completed chapters were kept."))
                return
            end
            local _, write_err = self.storage:write_chapter(book, chapter, content)
            if write_err then
                fail(index, write_err)
                return
            end
            state.sections[index] = {
                index = index,
                title = chapter.name or ("Chapter " .. tostring(index)),
                content = content,
            }
            state.done = index
            dialog:reportProgress(index)
            reset_cancel_callback()
            UIManager:nextTick(next_chapter)
        end, {
            trap_widget = dialog,
            keep_trap = true,
            reset_trap_callback = reset_cancel_callback,
            on_failure = function(error_message)
                fail(index, error_message)
            end,
            on_cancel = function()
                state.cancelled = true
                close_dialog(_("Download cancelled. Completed chapters were kept."))
            end,
        })
    end

    reset_cancel_callback()
    dialog:show()
    UIManager:nextTick(next_chapter)
end

function Legado:chooseBackupFile()
    local chooser = PathChooser:new{
        title = _("Long-press an Android backup ZIP"),
        select_directory = false,
        select_file = true,
        path = self.storage:get_default_path(),
        file_filter = function(filename)
            return filename:lower():match("%.zip$") ~= nil
        end,
        onConfirm = function(filename)
            self:runWorker(_("Importing backup…"), function()
                local result, err = Backup.import_archive(filename, self.storage:get_state_root())
                if not result then return nil, err or "backup import failed" end
                return result
            end, function(result)
                local counts = result.summary.counts or {}
                local previous = result.previous_root and ("\n" .. _("Previous state kept at:") .. "\n" .. result.previous_root) or ""
                self:showOperationResult(string.format(
                    _("Imported backup.\nSources: %s\nBooks: %s%s"),
                    tostring(counts.book_sources or 0),
                    tostring(counts.bookshelf_books or 0),
                    previous
                ))
            end)
        end,
    }
    UIManager:show(chooser)
end

function Legado:chooseExportDirectory()
    local chooser = PathChooser:new{
        title = _("Long-press a folder for the exported ZIP"),
        select_directory = true,
        select_file = false,
        path = self.storage:get_default_path(),
        onConfirm = function(directory)
            local filename = directory .. "/legado-kindle-" .. os.date("%Y%m%d-%H%M%S") .. ".zip"
            self:runWorker(_("Exporting backup…"), function()
                local result, err = Backup.export_state(self.storage:get_state_root(), filename)
                if not result then return nil, err or "backup export failed" end
                return result
            end, function(result)
                local counts = result.summary.counts or {}
                self:showOperationResult(string.format(
                    _("Exported backup.\nSources: %s\nBooks: %s\n\n%s"),
                    tostring(counts.book_sources or 0),
                    tostring(counts.bookshelf_books or 0),
                    filename
                ))
            end)
        end,
    }
    UIManager:show(chooser)
end

function Legado:onLegadoShowStatus()
    local state = self.storage:read_state()
    local error_line = state.error and ("\n" .. _("State:") .. " " .. tostring(state.error)) or ""
    UIManager:show(InfoMessage:new{
        text = string.format(
            _("Schema: %s\nSources: %s\nBooks: %s\nMembers: %s%s"),
            tostring(state.schema_version or "unknown"),
            tostring(state.sources or 0),
            tostring(state.books or 0),
            tostring(state.members or 0),
            error_line
        ),
    })
end

function Legado:onLegadoShowBookshelf()
    self:showBookshelf()
    return true
end

function Legado:onLegadoReaderToc()
    return self:showReaderChapterList()
end

function Legado:onLegadoNextChapter()
    return self:advanceReaderChapter(1)
end

function Legado:onLegadoPreviousChapter()
    return self:advanceReaderChapter(-1)
end

function Legado:onSourceCompatibility()
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    local report, err = catalog:compatibility()
    if not report then
        self:showOperationResult(_("Source report failed:\n") .. tostring(err))
        return
    end
    self:showOperationResult(string.format(
        _("Text sources: %s/%s\nSources with JavaScript: %s\nSources with XPath: %s\nCSS rules: %s\nJSON rules: %s\nRegex rules: %s\nReplacements: %s\nTemplates: %s"),
        tostring(report.text_source_count or 0),
        tostring(report.source_count or 0),
        tostring(report.sources_with_javascript or 0),
        tostring(report.sources_with_xpath or 0),
        tostring(report.css or 0),
        tostring(report.json or 0),
        tostring(report.regex or 0),
        tostring(report.replacements or 0),
        tostring(report.templates or 0)
    ))
end

return Legado
