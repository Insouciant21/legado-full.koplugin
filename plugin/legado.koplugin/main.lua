local _ = require("gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
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

-- Legado chapters are separate files, while KOReader normally stores these
-- options in each document's own sidecar.  Propagate only native reading
-- presentation settings when moving between chapters.  Progress, position,
-- annotations and document metadata must remain chapter-specific.
local READER_PRESENTATION_KEYS = {
    font_face = true,
    font_family_fonts = true,
    css = true,
    style_tweaks = true,
    style_tweaks_enabled = true,
    book_style_tweak = true,
    book_style_tweak_enabled = true,
    book_style_tweak_last_edit_pos = true,
    text_lang = true,
    text_lang_embedded_langs = true,
    hyphenation = true,
    hyph_force_algorithmic = true,
    hyph_soft_hyphens_only = true,
    hyph_trust_soft_hyphens = true,
    floating_punctuation = true,
    inverse_reading_order = true,
    page_overlap_style = true,
    hide_nonlinear_flows = true,
}

local function is_reader_presentation_key(key)
    return type(key) == "string"
        and (key:match("^copt_") or key:match("^kopt_")
            or READER_PRESENTATION_KEYS[key])
end

local function copy_setting_value(value, depth)
    local value_type = type(value)
    if value == nil or value_type == "string" or value_type == "number"
            or value_type == "boolean" then
        return value
    end
    if value_type ~= "table" or (depth or 0) >= 6 then
        return nil
    end
    local result = {}
    for key, child in pairs(value) do
        local key_type = type(key)
        if key_type == "string" or key_type == "number" then
            local copied = copy_setting_value(child, (depth or 0) + 1)
            if copied ~= nil then result[key] = copied end
        end
    end
    return result
end

local function settings_equal(left, right, depth)
    if left == right then return true end
    if type(left) ~= type(right) or type(left) ~= "table" then
        return false
    end
    if (depth or 0) >= 6 then return false end
    for key, value in pairs(left) do
        if not settings_equal(value, right[key], (depth or 0) + 1) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

-- Keep plugin modules under a namespaced directory. KOReader temporarily adds
-- the plugin directory to package.path while loading the entry point.
local Storage = require("legado/storage")
local Backup = require("legado/backup")
local Content = require("legado/content")
local EmojiFont = require("legado/font")
local SourceCatalog = require("legado/source")
local BrowserInput = require("legado/browser_input")

-- Every plugin Menu is a screen-sized page.  Menu's default is a popout,
-- which gives a full-screen instance a rounded frame and installs an
-- outside-tap-to-close gesture.  Use KOReader's native full-screen menu
-- presentation consistently for Legado pages.
local LegadoMenu = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
}

local Legado = WidgetContainer:extend{
    name = "legado",
    fullname = _("Legado"),
}

local function display_text(value)
    -- Keep source/book text byte-for-byte intact.  Emoji rendering is handled
    -- by the optional Symbola fallback installed by this plugin.
    return tostring(value or "")
end

local function trim_text(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Legado:init()
    self.storage = Storage:new()
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
            text = _("Import sources, bookshelf and reading history"),
            callback = function()
                self:chooseBackupFile()
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

function Legado:preserveReaderSettings(filename, reader_session)
    if type(filename) ~= "string" or filename == ""
            or not self.ui or not self.ui.document
            or not self.ui.doc_settings then
        return false
    end
    -- Only carry settings while replacing a chapter in a known Legado
    -- session. This keeps opening an unrelated file from inheriting a novel's
    -- document settings by accident.
    if not reader_session and not self:getActiveReaderSession() then return false end

    -- ReaderConfig and ReaderFont keep the newest values in their live
    -- modules until KOReader's SaveSettings event. Update doc_settings before
    -- taking the snapshot, so a font/size change made immediately before a
    -- chapter turn is included. The actual flush is already performed by
    -- ReaderUI:switchDocument():onClose(); calling saveSettings() here too
    -- would write the current chapter's metadata twice on every turn.
    if type(self.ui.handleEvent) == "function" then
        pcall(self.ui.handleEvent, self.ui, Event:new("SaveSettings"))
    end

    local source_data = self.ui.doc_settings.data
    if type(source_data) ~= "table" then return false end
    local target_settings = DocSettings:open(filename)
    local target_data = target_settings.data
    if type(target_data) ~= "table" then return false end

    -- Include settings present only in the target as well, so an option that
    -- is absent in the current document falls back to KOReader's normal
    -- default instead of retaining a stale chapter-specific value.
    local keys = {}
    for key in pairs(source_data) do
        if is_reader_presentation_key(key) then keys[key] = true end
    end
    for key in pairs(target_data) do
        if is_reader_presentation_key(key) then keys[key] = true end
    end

    local changed = false
    for key in pairs(keys) do
        local value = source_data[key]
        if value == nil then
            if target_data[key] ~= nil then
                target_data[key] = nil
                changed = true
            end
        elseif not settings_equal(target_data[key], value, 0) then
            local copied = copy_setting_value(value, 0)
            if copied ~= nil then
                target_data[key] = copied
                changed = true
            end
        end
    end

    -- This flag belongs to KOReader's legacy TXT provider. It must not leak
    -- into the HTML chapter representation, or the target can become
    -- preformatted again and make font/indent changes appear ineffective.
    if filename:lower():match("%.html$") and target_data.txt_preformatted ~= nil then
        target_data.txt_preformatted = nil
        changed = true
    end

    if changed then
        target_settings:flush()
    end
    return changed
end

function Legado:openDownloadedFile(filename, seamless, reader_session)
    -- KOReader gives every standalone chapter its own document settings
    -- sidecar. Seed the target sidecar before switchDocument() closes the
    -- current document, preserving KOReader's native reading presentation
    -- without introducing a second plugin-owned settings system.
    self:preserveReaderSettings(filename, reader_session)
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

local function same_reader_book(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local left_url = trim_text(left.bookUrl or left.origin)
    local right_url = trim_text(right.bookUrl or right.origin)
    if left_url ~= "" and right_url ~= "" then
        return left_url == right_url
    end
    local left_name = trim_text(left.name or left.bookName)
    local right_name = trim_text(right.name or right.bookName)
    if left_name == "" or right_name == "" or left_name ~= right_name then
        return false
    end
    local left_author = trim_text(left.author or left.bookAuthor)
    local right_author = trim_text(right.author or right.bookAuthor)
    return left_author == "" or right_author == "" or left_author == right_author
end

function Legado:getCachedReaderSession(source, book)
    local session = self._reader_session_cache
    -- Do not parse the potentially megabyte-sized persistent TOC on the UI
    -- thread just to decide whether this shortcut applies. A session already
    -- used in this KOReader process is cheap to reuse; after a restart the
    -- normal worker path loads the fresh list without an extra foreground
    -- pause.
    if type(session) ~= "table" or type(session.chapters) ~= "table"
            or #session.chapters == 0 or not same_reader_book(session.book, book) then
        return nil
    end

    local session_url = trim_text(session.source_url)
    local source_url = trim_text(source and source.bookSourceUrl)
    if session_url ~= "" and source_url ~= "" then
        if session_url ~= source_url then return nil end
    elseif trim_text(session.source_name) ~= ""
            and trim_text(source and source.bookSourceName) ~= ""
            and session.source_name ~= source.bookSourceName then
        return nil
    end
    self._reader_session_cache = session
    return session
end

local function normalize_path(path)
    path = tostring(path or "")
    -- DataStorage deliberately returns "." on Kindle.  The resulting
    -- chapter paths are relative, while ReaderUI may expose an absolute
    -- path (and the reverse can happen after a restart).  realpath()
    -- makes both forms comparable and also handles test/book symlinks.
    return FFIUtil.realpath(path) or path:gsub("^%./", "")
end

local function same_path(left, right)
    if tostring(left or "") == tostring(right or "") then return true end
    return normalize_path(left) == normalize_path(right)
end

function Legado:getActiveReaderSession()
    if not self.ui or not self.ui.document then return nil end
    local current_file = self.ui.document.file or self.ui.document.filename
    if type(current_file) ~= "string" or current_file == "" then return nil end
    local session = self._reader_session_cache
    if not session then
        session = self.storage:load_reader_session()
        if not session then return nil end
        self._reader_session_cache = session
    end
    if not session or type(session.chapters) ~= "table" then return nil end
    if self._reader_session_cache_file == current_file then
        return session
    end

    -- The position file is updated before a seamless switch. On the normal
    -- path this lets us verify the candidate in O(1), without scanning every
    -- chapter and calling realpath() hundreds of times.
    local current_is_txt = current_file:lower():match("%.txt$") ~= nil
    local function expected_path(chapter)
        if current_is_txt then
            return self.storage:get_legacy_chapter_path(session.book, chapter)
        end
        return self.storage:get_chapter_path(session.book, chapter)
    end
    local normalized_current
    local function matches(chapter)
        if type(chapter) ~= "table" then return false end
        local expected = expected_path(chapter)
        if expected == current_file then return true end
        normalized_current = normalized_current or normalize_path(current_file)
        return normalize_path(expected) == normalized_current
    end

    local candidate = session.chapters[session.current_index]
    if candidate and matches(candidate) then
        self._reader_session_cache_file = current_file
        return session
    end

    -- Use the actual document path rather than only current_index. This also
    -- recovers gracefully if KOReader was closed after the user selected a
    -- different cached chapter. This fallback is only needed after restart or
    -- when another document was opened; normal chapter turns take the branch
    -- above.
    for index, chapter in ipairs(session.chapters) do
        if matches(chapter) then
            session.current_index = index
            self._reader_session_cache_file = current_file
            return session
        end
    end
    self._reader_session_cache_file = nil
    return nil
end

function Legado:invalidateReaderSourceCache()
    self._reader_source_catalog = nil
    self._reader_source_cache_key = nil
    self._reader_source_cache = nil
end

function Legado:resolveReaderSource(session)
    if type(session) ~= "table" then return nil, "reading session is missing" end
    local source_url = tostring(session.source_url or "")
    local source_name = tostring(session.source_name or "")
    local cache_key = source_url .. "\0" .. source_name
    if self._reader_source_cache_key == cache_key and self._reader_source_cache then
        return self._reader_source_cache
    end
    local catalog = self._reader_source_catalog
    if not catalog then
        catalog = SourceCatalog:new(self.storage:get_state_root())
        self._reader_source_catalog = catalog
    end
    if session.source_url and session.source_url ~= "" then
        local source = catalog:find_by_url(session.source_url)
        if source then
            self._reader_source_cache_key = cache_key
            self._reader_source_cache = source
            return source
        end
    end
    local sources, err = catalog:list()
    if not sources then return nil, err end
    for source_index, source in ipairs(sources) do
        if source.bookSourceName == session.source_name
                and tonumber(source.bookSourceType or 0) == 0 then
            self._reader_source_cache_key = cache_key
            self._reader_source_cache = source
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

    -- A cached Legado chapter is a standalone document, so CRe quite
    -- correctly reports no native ToC. Redirect the standard KOReader ToC
    -- action to the source chapter list only while a Legado reading session is
    -- active.
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
    self:upgradeLegacyReaderDocument()
    if self.emoji_font_ready and self.ui and self.ui.document then
        -- This is also useful when CRe was initialized before the plugin and
        -- the fallback list was rebuilt by a document reload.
        EmojiFont:add_document_fallback(self.ui.document)
    end
    UIManager:nextTick(function()
        self:startReaderPrefetch()
    end)
end

function Legado:upgradeLegacyReaderDocument()
    local session = self:getActiveReaderSession()
    if not session or self._legacy_upgrade_pending then return false end
    local current_file = self.ui and self.ui.document
        and (self.ui.document.file or self.ui.document.filename)
    local chapter = session.chapters[session.current_index]
    if type(current_file) ~= "string" or type(chapter) ~= "table"
            or (not current_file:lower():match("%.txt$")
                and not current_file:lower():match("%.html$")) then
        return false
    end

    -- chapter_is_readable() converts old cached TXT files and canonicalizes
    -- older generated HTML locally. No Android reader settings are copied;
    -- the document gets its presentation from KOReader's normal settings
    -- flow.
    local readable, modern_path = self.storage:chapter_is_readable(
        session.book, chapter
    )
    if not readable or type(modern_path) ~= "string"
            or modern_path:lower():match("%.txt$")
            or same_path(modern_path, current_file) then
        return false
    end

    self._legacy_upgrade_pending = true
    UIManager:nextTick(function()
        self._legacy_upgrade_pending = false
        local document = self.ui and self.ui.document
        local active_file = document and (document.file or document.filename)
        if type(active_file) == "string" and same_path(active_file, current_file) then
            self:openDownloadedFile(modern_path, true)
        end
    end)
    return true
end

function Legado:cancelReaderPrefetch()
    self._prefetch_generation = (self._prefetch_generation or 0) + 1
    self._prefetch_running = false
    self._prefetch_stop_after = nil
    -- A running Trapper job will unwind on its own. Dropping its entry makes
    -- its eventual callback harmless, while the next foreground request can
    -- start immediately without waiting for that subprocess.
    self._prefetch_jobs = {}
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
    self._prefetch_stop_after = nil
    self._prefetch_jobs = {}

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
        local job = {
            generation = generation,
            session = session,
            waiters = {},
        }
        self._prefetch_jobs[chapter_index] = job
        self:runWorker(false, function()
            local Runtime = require("legado/runtime")
            local content, err = Runtime.chapter_content(source, chapter, session.book)
            if not content then return nil, err or "prefetch failed" end
            return content
        end, function(content)
            if self._prefetch_generation ~= generation
                    or self._prefetch_jobs[chapter_index] ~= job then
                finish()
                return
            end
            local path = self.storage:write_chapter(session.book, chapter, content)
            if not path then
                self._prefetch_jobs[chapter_index] = nil
                for _, waiter in ipairs(job.waiters) do
                    waiter(nil, "cannot save prefetched chapter")
                end
                finish()
                return
            end
            self._prefetch_jobs[chapter_index] = nil
            if #job.waiters > 0 then
                -- The foreground transition owns this chapter now. Do not
                -- continue filling later chapters while the old document is
                -- being replaced; those jobs would only be invalidated by
                -- onCloseDocument a moment later.
                self._prefetch_generation = self._prefetch_generation + 1
                self._prefetch_running = false
                self._prefetch_stop_after = nil
                self._prefetch_jobs = {}
                for _, waiter in ipairs(job.waiters) do
                    UIManager:nextTick(function()
                        waiter(path)
                    end)
                end
                return
            end
            if self._prefetch_stop_after == chapter_index then
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
            on_failure = function(error_message)
                if self._prefetch_jobs[chapter_index] == job then
                    self._prefetch_jobs[chapter_index] = nil
                    for _, waiter in ipairs(job.waiters) do
                        waiter(nil, error_message)
                    end
                end
                finish()
            end,
            on_cancel = function()
                if self._prefetch_jobs[chapter_index] == job then
                    self._prefetch_jobs[chapter_index] = nil
                    for _, waiter in ipairs(job.waiters) do
                        waiter(nil, "prefetch cancelled")
                    end
                end
                finish()
            end,
        })
    end

    fetch_next(1)
    return true
end

function Legado:choosePrefetchCount()
    local current = self.storage:get_prefetch_count()
    local items = {}
    for count_index, count in ipairs({ 5, 6, 7, 8, 9, 10 }) do
        items[#items + 1] = {
            text = T(_("Prefetch next %1 chapters"), count),
            mandatory = count == current and _("Current") or nil,
            count = count,
        }
    end
    local menu
    menu = LegadoMenu:new{
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

function Legado:openReaderChapter(session, target_index, seamless, already_deferred)
    local chapter = session.chapters[target_index]
    if not chapter then
        self._reader_transition_busy = false
        return false
    end
    -- Chapter-list selections call this method directly, while dispatcher
    -- navigation marks the transition before calling it. Normalize both
    -- paths so a prefetch hand-off cannot leave a menu-triggered transition
    -- waiting forever.
    self._reader_transition_busy = true
    -- The position is known before a foreground download starts. Keeping it
    -- in the in-memory session lets ReaderReady identify the target in O(1)
    -- once the document is opened, including the uncached-chapter path.
    session.current_index = target_index
    self._reader_transition_session = session
    self._reader_transition_index = target_index

    -- If the next chapter is already being prefetched, let that worker finish
    -- and hand its cache file to the normal reader path. Cancelling it here
    -- used to make a fast prefetch indistinguishable from a cache miss and
    -- caused the same chapter to be downloaded a second time in the
    -- foreground.
    local prefetch_job = self._prefetch_jobs
        and self._prefetch_jobs[target_index]
    if prefetch_job and prefetch_job.session == session
            and prefetch_job.generation == self._prefetch_generation then
        if prefetch_job.waiting then return true end
        prefetch_job.waiting = true
        self._prefetch_stop_after = target_index
        prefetch_job.waiters[#prefetch_job.waiters + 1] = function()
            if self._reader_transition_busy
                    and self._reader_transition_session == session
                    and self._reader_transition_index == target_index then
                self:openReaderChapter(session, target_index, seamless, true)
            end
        end
        return true
    end

    self:cancelReaderPrefetch()
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
        local open = function()
            self:openDownloadedFile(path, seamless, session)
        end
        -- EndOfBook is itself delivered from a UI event. Its handler already
        -- schedules one safe UI turn before reaching here; avoid adding a
        -- second idle turn to every automatic cached chapter transition.
        if already_deferred then
            open()
        else
            UIManager:nextTick(open)
        end
        return true
    end

    self:downloadChapter(source, session.book, chapter, session.chapters, {
        seamless = seamless,
        reader_transition = true,
        reader_session = session,
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
            display_book, source, result.chapters, current_index, true
        )
        local refreshed_session = {
            book = display_book,
            chapters = result.chapters,
            current_index = current_index,
            source_url = source.bookSourceUrl or "",
            source_name = source.bookSourceName or "",
        }
        self._reader_session_cache = refreshed_session
        self._reader_session_cache_file = nil
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
    return self:openReaderChapter(
        session, target_index, seamless ~= false, already_busy == true
    )
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
    for incoming_index, source in ipairs(incoming) do
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
        self:invalidateReaderSourceCache()
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
    source_menu = LegadoMenu:new{
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
    if (type(source.exploreUrl) == "string" and trim_text(source.exploreUrl) ~= "")
            or type(source.exploreUrl) == "table" then
        items[#items + 1] = {
            text = _("Browse discovery"),
            keep_menu = true,
            callback = function()
                self:showExploreKinds(source)
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
    action_menu = LegadoMenu:new{
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
        self:invalidateReaderSourceCache()
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
                self:invalidateReaderSourceCache()
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
                            self:invalidateReaderSourceCache()
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
    for source_index, source in ipairs(sources) do
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
    source_menu = LegadoMenu:new{
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

function Legado:showSourceLoginControls(source, controls)
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

function Legado:showSourceLogin(source)
    local raw_ui = source.loginUi
    local controls
    if type(raw_ui) == "table" then
        controls = raw_ui
    elseif type(raw_ui) == "string" and raw_ui ~= "" then
        local decoded_ok, decoded = pcall(require("rapidjson").decode, raw_ui)
        if decoded_ok and type(decoded) == "table" then
            controls = decoded
        end
    end
    if type(controls) == "table" then
        self:showSourceLoginControls(source, controls)
        return
    end

    -- Android Legado permits loginUi to be generated by a source script. It
    -- is common for aggregate sources to build controls from source variables
    -- or a remote login page, so showing the raw @js rule as a JSON input is
    -- not a useful fallback. Evaluate it in the same generic JS session used
    -- by loginUrl, then feed the returned control array through the ordinary
    -- Kindle form/action loop.
    local raw_text = type(raw_ui) == "string" and raw_ui:match("^%s*(.-)%s*$") or ""
    local is_dynamic = raw_text:lower():match("^@js:") ~= nil
        or raw_text:lower():match("^<js>") ~= nil
    if is_dynamic then
        self:runWorker(_("Loading login form…"), function()
            local Runtime = require("legado/runtime")
            local value, err = Runtime.login_ui(source)
            if not value then error(err or "cannot build login form") end
            return value
        end, function(value)
            self:showSourceLoginControls(source, value)
        end, {
            interactive = true,
            on_failure = function(error_message)
                self:showOperationResult(
                    _("Cannot build source login form:\n") .. tostring(error_message)
                )
            end,
        })
        return
    end

    -- In Legado an empty loginUi means browser login mode. An absolute
    -- loginUrl is a page to display (OAuth, QR, captcha, etc.), not a
    -- JavaScript expression and not a JSON form definition.
    if raw_text == "" and type(source.loginUrl) == "string"
            and source.loginUrl:match("^%s*https?://") then
        self:runSourceLogin(source, {}, nil, _("login"))
        return
    end

    self:showGenericLoginDialog(source)
end

function Legado:showSourceLoginActions(source, buttons, values)
    if type(buttons) ~= "table" or #buttons == 0 then
        self:runSourceLogin(source, values, "login()", _("login"))
        return
    end
    local items = {}
    for control_index, control in ipairs(buttons) do
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
    action_menu = LegadoMenu:new{
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
    for notification_index, notification in ipairs(notifications) do
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

local function explore_kind_type_label(kind)
    local kind_type = tostring(kind and kind.type or "url"):lower()
    if kind_type == "select" then return _("Select") end
    if kind_type == "toggle" then return _("Toggle") end
    if kind_type == "text" then return _("Enter text") end
    if kind_type == "button" then return _("Action") end
    if trim_text(kind and kind.url) == "" then return _("Header") end
    return _("Open")
end

local function explore_kind_title(kind)
    local title = kind and (kind.displayName or kind.title)
    title = display_text(title)
    return title ~= "" and title or _("Unnamed discovery entry")
end

function Legado:showExploreKinds(source)
    self:runWorker(_("Loading discovery entries…"), function()
        local Runtime = require("legado/runtime")
        local kinds, err = Runtime.explore_kinds(source)
        if not kinds then return nil, err or "cannot load discovery entries" end
        return kinds
    end, function(kinds)
        if type(kinds) ~= "table" or #kinds == 0 then
            self:showOperationResult(
                _("This source did not provide any discovery entries.")
            )
            return
        end
        local items = {}
        local notifications = kinds.notifications
        if type(notifications) == "table" and #notifications > 0 then
            local messages = {}
            for _, notification in ipairs(notifications) do
                local message = type(notification) == "table"
                    and notification.message or notification
                if trim_text(message) ~= "" then
                    messages[#messages + 1] = tostring(message)
                end
            end
            if #messages > 0 then
                items[#items + 1] = {
                    text = _("Source messages"),
                    mandatory = table.concat(messages, " | "),
                    source_message = table.concat(messages, "\n"),
                    separator = true,
                }
            end
        end
        for _, kind in ipairs(kinds) do
            local value = kind.value
            local mandatory = explore_kind_type_label(kind)
            if (kind.type == "select" or kind.type == "toggle"
                    or kind.type == "text") and trim_text(value) ~= "" then
                mandatory = mandatory .. " · " .. display_text(value)
            end
            items[#items + 1] = {
                text = explore_kind_title(kind),
                mandatory = mandatory,
                kind = kind,
            }
        end
        local discovery_menu
        discovery_menu = LegadoMenu:new{
            title = T(_("Discovery: %1"), display_text(source.bookSourceName or "")),
            item_table = items,
            items_per_page = 12,
            onMenuSelect = function(menu, item)
                UIManager:close(menu)
                if item.source_message then
                    self:showOperationResult(item.source_message, function()
                        self:showExploreKinds(source)
                    end)
                    return
                end
                local kind = item.kind
                if type(kind) ~= "table" then return end
                local kind_type = tostring(kind.type or "url"):lower()
                if kind_type == "text" then
                    self:showExploreTextInput(source, kind)
                elseif kind_type == "select" or kind_type == "toggle" then
                    self:showExploreValue(source, kind)
                elseif kind_type == "button" then
                    self:runExploreAction(source, kind, nil)
                elseif trim_text(kind.url) ~= "" then
                    self:exploreSource(source, kind, 1)
                else
                    self:showOperationResult(
                        _("This discovery entry is a header and has no action."),
                        function() self:showExploreKinds(source) end
                    )
                end
            end,
        }
        UIManager:show(discovery_menu)
    end, {
        interactive = true,
        on_failure = function(error_message)
            self:showOperationResult(
                _("Cannot load discovery entries:\n") .. tostring(error_message)
            )
        end,
    })
end

function Legado:showExploreTextInput(source, kind)
    local dialog
    dialog = InputDialog:new{
        title = explore_kind_title(kind),
        input = tostring(kind.value or kind.default or ""),
        input_hint = _("Enter a value"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputValue() or ""
                        UIManager:close(dialog)
                        self:runExploreAction(source, kind, value)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:showExploreValue(source, kind)
    local values = {}
    for _, value in ipairs(kind.chars or {}) do
        values[#values + 1] = tostring(value)
    end
    if #values == 0 and tostring(kind.type or ""):lower() == "toggle" then
        values = { "true", "false" }
    end
    if #values == 0 then
        self:showOperationResult(
            _("This discovery entry has no selectable values."),
            function() self:showExploreKinds(source) end
        )
        return
    end
    if tostring(kind.type or ""):lower() == "toggle" then
        local current = tostring(kind.value or "")
        local next_value = values[1]
        for index, value in ipairs(values) do
            if value == current then
                next_value = values[index + 1] or values[1]
                break
            end
        end
        self:runExploreAction(source, kind, next_value)
        return
    end
    local items = {}
    for value_index, value in ipairs(values) do
        items[#items + 1] = {
            text = display_text(value),
            mandatory = value == tostring(kind.value or "") and _("Current") or nil,
            value = value,
        }
    end
    local value_menu
    value_menu = LegadoMenu:new{
        title = explore_kind_title(kind),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            self:runExploreAction(source, kind, item.value)
        end,
    }
    UIManager:show(value_menu)
end

function Legado:runExploreAction(source, kind, value)
    self:runWorker(T(_("Applying discovery setting: %1"), explore_kind_title(kind)), function()
        local Runtime = require("legado/runtime")
        local result, err = Runtime.explore_action(source, kind, value)
        if not result then return nil, err or "discovery action failed" end
        return result
    end, function(result)
        local lines = { _("Discovery setting saved.") }
        append_source_result(lines, _("Action return value:"), result and result.actionResult)
        append_source_notifications(lines, result and result.notifications)
        if #lines > 1 then
            self:showOperationResult(table.concat(lines, "\n"), function()
                self:showExploreKinds(source)
            end)
        else
            self:showExploreKinds(source)
        end
    end, {
        interactive = true,
        on_failure = function(error_message)
            self:showOperationResult(
                _("Discovery action failed:\n") .. tostring(error_message),
                function() self:showExploreKinds(source) end
            )
        end,
    })
end

function Legado:exploreSource(source, kind, page)
    self:runWorker(
        T(_("Loading discovery page %1…"), tostring(page or 1)),
        function()
            local Runtime = require("legado/runtime")
            local result, err = Runtime.explore_source(source, kind, page)
            if not result then return nil, err or "discovery request failed" end
            return result
        end,
        function(result)
            local books = result and result.books
            if type(books) ~= "table" or #books == 0 then
                self:showOperationResult(
                    _("No books found in this discovery page."),
                    function() self:showExploreKinds(source) end
                )
                return
            end
            self:showExploreResults(source, kind, result)
        end,
        {
            interactive = true,
            on_failure = function(error_message)
                self:showOperationResult(
                    _("Cannot load discovery page:\n") .. tostring(error_message),
                    function() self:showExploreKinds(source) end
                )
            end,
        }
    )
end

function Legado:showExploreResults(source, kind, result)
    local books = result and result.books or {}
    local page = tonumber(result and result.page) or 1
    local items = {
        {
            text = _("Change discovery setting"),
            mandatory = _("Back to discovery"),
            choose = true,
            separator = true,
        },
        {
            text = T(_("Next discovery page (%1)"), page + 1),
            mandatory = _("Load more"),
            next_page = true,
        },
    }
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
    result_menu = LegadoMenu:new{
        title = T(_("Discovery results: %1 · page %2"),
            explore_kind_title(kind), page),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            if item.choose then
                self:showExploreKinds(source)
            elseif item.next_page then
                self:exploreSource(source, kind, page + 1)
            elseif item.book then
                self:showChapters(source, item.book)
            end
        end,
    }
    UIManager:show(result_menu)
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
    for source_index, source in ipairs(sources) do
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
    source_menu = LegadoMenu:new{
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
    if #books == 0 then
        self:showOperationResult(_("Bookshelf is empty. Import an Android backup or search and download a book."))
        return
    end
    local reading_status = self.storage:get_reading_status(books)
    self:showBookshelfCategories(catalog, books, reading_status)
end

local function bookshelf_category_label(category_id)
    if category_id == "read" then return _("Read") end
    if category_id == "unread" then return _("Unread") end
    return _("All books")
end

function Legado:showBookshelfCategories(catalog, books, reading_status)
    local categories = catalog:categories()
    local items = {}
    for category_index, category in ipairs(categories) do
        local selected = catalog:books_for_category(
            books, category.id, reading_status
        )
        items[#items + 1] = {
            text = bookshelf_category_label(category.id),
            mandatory = T(_("%1 books"), #selected),
            category = category,
        }
    end

    local category_menu
    category_menu = LegadoMenu:new{
        title = _("Legado bookshelf categories"),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            UIManager:close(menu)
            self:showBookshelfBooks(
                catalog, books, item.category, reading_status, categories
            )
        end,
    }
    UIManager:show(category_menu)
end

function Legado:showBookshelfBooks(catalog, books, category, reading_status, categories)
    local category_id = category and category.id or "all"
    local entries = catalog:books_for_category(books, category_id, reading_status)
    local items = {}
    if categories and #categories > 0 then
        items[#items + 1] = {
            text = _("Change bookshelf category"),
            mandatory = _("Categories"),
            choose_category = true,
            separator = true,
        }
    end
    for entry_index, entry in ipairs(entries) do
        local book = entry.book
        if type(book) == "table" and book.name and book.name ~= "" then
            local author = book.author and book.author ~= ""
                and ("\n" .. display_text(book.author)) or ""
            local last = self.storage:get_last_chapter(book)
            local progress = last and T(_("Chapter %1"), last) or nil
            local source_label = display_text(book.originName or book.origin)
            local mandatory = progress and source_label ~= ""
                and (progress .. " · " .. source_label) or progress or source_label
            items[#items + 1] = {
                text = display_text(book.name) .. author,
                mandatory = mandatory,
                book = book,
                book_index = entry.index,
            }
        end
    end
    if #entries == 0 then
        items[#items + 1] = {
            text = _("No books in this category"),
            mandatory = _("Empty"),
            empty_category = true,
            separator = true,
        }
    end
    local title = _("Legado bookshelf")
    title = title .. " · " .. bookshelf_category_label(category_id)
    local book_menu
    book_menu = LegadoMenu:new{
        title = title,
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            if item.empty_category then
                return
            end
            if item.choose_category then
                UIManager:close(menu)
                self:showBookshelfCategories(catalog, books, reading_status)
                return
            end
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
    result_menu = LegadoMenu:new{
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
    local current_item_number
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
        if last_chapter == index then
            -- Menu uses item_table.current during init to choose the page
            -- containing the current item.  The chapter list has a few
            -- action rows before the actual chapters, so the menu item number
            -- is not the same as the chapter index.
            current_item_number = #items
        end
    end
    if current_item_number then
        -- This is a non-array field and does not affect ipairs/#items.  It
        -- also makes KOReader render the current chapter in its normal bold
        -- current-item style.
        items.current = current_item_number
    end
    local chapter_menu
    chapter_menu = LegadoMenu:new{
        title = display_text(display_book.name or _("Chapters")) .. " · "
            .. tostring(#chapters) .. " chapters",
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(menu, item)
            if item.refresh then
                UIManager:close(menu)
                self:refreshReaderSession(options.reader_session, false)
                return
            end
            if item.jump then
                local action_source = get_source()
                if not action_source then return end
                UIManager:close(menu)
                self:showChapterJump(
                    action_source, display_book, result, options.reader_session
                )
                return
            end
            UIManager:close(menu)
            if item.bulk then
                local action_source = get_source()
                if not action_source then return end
                self:downloadBook(action_source, display_book, chapters)
            elseif options.reader_session then
                -- Keep chapter navigation inside the existing reader session.
                -- This avoids rebuilding the session from the menu path and
                -- gives the target document the same settings hand-off as an
                -- automatic end-of-chapter transition.
                self:openReaderChapter(
                    options.reader_session, item.chapter.index, true
                )
            else
                local action_source = get_source()
                if not action_source then return end
                self:openOrDownloadChapter(
                    action_source, display_book, item.chapter, chapters, true
                )
            end
        end,
    }
    UIManager:show(chapter_menu)
    return true
end

function Legado:showChapters(source, book)
    local cached_session = self:getCachedReaderSession(source, book)
    if cached_session then
        self:showChapterMenu(
            source,
            cached_session.book or book,
            cached_session.chapters,
            {
                current_index = cached_session.current_index,
                reader_session = cached_session,
            }
        )
        return
    end
    self:runWorker(_("Loading chapter list…"), function()
        local Runtime = require("legado/runtime")
        -- Imported bookshelf entries already carry the resolved book/toc URLs.
        -- Runtime only uses this shortcut for static bookInfo rules; dynamic
        -- sources continue through the complete Legado bookInfo pipeline.
        local result, err = Runtime.chapter_list(source, book, {
            use_cached_info = true,
        })
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

function Legado:showChapterJump(source, book, result, reader_session)
    local chapters = result and result.chapters or {}
    local total = #chapters
    if total == 0 then return end
    local current = reader_session and reader_session.current_index
        or self.storage:get_last_chapter(book) or 1
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
                        if reader_session then
                            self:openReaderChapter(reader_session, index, true)
                        else
                            self:openOrDownloadChapter(
                                source, book, chapters[index], chapters, true
                            )
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:openOrDownloadChapter(source, book, chapter, chapters, force_static)
    if chapters then
        local _, static_changed = self.storage:save_reader_session(
            book, source, chapters, chapter.index, force_static == true
        )
        if static_changed then
            -- The current document can still belong to the previous book until
            -- switchDocument completes. Do not let the active-session cache
            -- identify that old document as the newly selected session.
            self._reader_session_cache = nil
            self._reader_session_cache_file = nil
        end
    end
    local readable, path = self.storage:chapter_is_readable(book, chapter)
    self.storage:save_last_chapter(book, chapter)
    if readable then
        self:openDownloadedFile(path, false, true)
    else
        self:downloadChapter(source, book, chapter, chapters, {
            preserve_settings = true,
        })
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
            local _, static_changed = self.storage:save_reader_session(
                book, source, chapters, chapter.index
            )
            if static_changed then
                self._reader_session_cache = nil
                self._reader_session_cache_file = nil
            end
        end
        self.storage:save_last_chapter(book, chapter)
        if options.reader_transition then
            self._reader_transition_busy = false
        end
        self:openDownloadedFile(
            filename,
            options.seamless == true,
            options.reader_session or options.preserve_settings
        )
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
                -- Android's three read-record tables are kept as supported
                -- state members, then converted to the Kindle-native progress
                -- and history files without importing Android reader options.
                local imported_storage = Storage:new()
                local reading, reading_err = imported_storage:import_reading_records()
                result.reading_import = reading
                result.reading_import_error = reading_err
                return result
            end, function(result)
                self.storage:invalidate_reading_record_cache()
                self:invalidateReaderSourceCache()
                self._reader_session_cache = nil
                self._reader_session_cache_file = nil
                local counts = result.summary.counts or {}
                local reading = result.reading_import or {}
                local records = reading.records or {}
                local reading_error = result.reading_import_error
                    and ("\n" .. _("Reading history conversion:") .. " " .. tostring(result.reading_import_error))
                    or ""
                self:showOperationResult(string.format(
                    _("Imported Android data.\nSources: %s\nBooks: %s\nRead records: %s\nRead details: %s\nRead sessions: %s\nResumed books: %s\nIgnored Android members: %s%s"),
                    tostring(counts.book_sources or 0),
                    tostring(counts.bookshelf_books or 0),
                    tostring(counts.read_records or records.read_records or 0),
                    tostring(counts.read_record_details or records.read_record_details or 0),
                    tostring(counts.read_record_sessions or records.read_record_sessions or 0),
                    tostring(reading.progress_books or 0),
                    tostring(counts.ignored_members or 0),
                    reading_error
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
            _("Schema: %s\nSources: %s\nBooks: %s\nDynamic categories: All, Read, Unread\nRead records: %s\nMembers: %s%s"),
            tostring(state.schema_version or "unknown"),
            tostring(state.sources or 0),
            tostring(state.books or 0),
            tostring(state.read_records or 0),
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
