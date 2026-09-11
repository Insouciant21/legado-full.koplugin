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
local util = require("util")
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
local BookDetail = require("legado/book_detail")

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

local BOOK_INFO_FIELDS = {
    "intro",
    "kind",
    "lastChapter",
    "updateTime",
    "coverUrl",
    "wordCount",
    "tocUrl",
}

local function has_book_info_rule(source, field)
    local rules = source and source.ruleBookInfo
    if type(rules) ~= "table" then return false end
    local value = rules[field]
    if type(value) == "table" then
        for _, child in pairs(value) do
            if trim_text(child) ~= "" then return true end
        end
        return false
    end
    return trim_text(value) ~= ""
end

local function should_auto_refresh_book_detail(book, source)
    if type(book) ~= "table" or type(source) ~= "table"
            or type(source.ruleBookInfo) ~= "table" then
        return false
    end
    -- A source may have a ruleBookInfo table for only the fields it supports.
    -- Do not refresh forever merely because another optional field is empty.
    local missing_intro = trim_text(book.intro) == ""
        and has_book_info_rule(source, "intro")
    local missing_last_chapter = trim_text(book.lastChapter) == ""
        and has_book_info_rule(source, "lastChapter")
    return missing_intro or missing_last_chapter
end

local function merge_book_info(book, info, source)
    local updated = {}
    for key, value in pairs(book or {}) do updated[key] = value end
    if type(info) == "table" then
        for _, field in ipairs(BOOK_INFO_FIELDS) do
            local value = info[field]
            if value ~= nil and trim_text(value) ~= "" then
                updated[field] = value
            end
        end
        if trim_text(info.author) ~= "" then
            updated.author = info.author
        end
        if trim_text(info.sourceVariable) ~= "" then
            updated.sourceVariable = info.sourceVariable
        end
        if type(info.variable) == "table" then
            updated.variable = info.variable
        end
    end
    -- Keep the bookshelf identity stable even if a source normalizes the title
    -- differently on its detail page. This also keeps existing chapter cache
    -- paths and imported reading records attached to the same book.
    updated.name = book and book.name or updated.name or ""
    if source then
        updated.origin = source.bookSourceUrl or updated.origin
        updated.originName = source.bookSourceName or updated.originName
        updated.bookSourceUrl = source.bookSourceUrl or updated.bookSourceUrl
        updated.sourceUrl = source.bookSourceUrl or updated.sourceUrl
        updated.sourceName = source.bookSourceName or updated.sourceName
    end
    return updated
end

local function replace_book_source(book, candidate, source)
    local updated = {}
    for key, value in pairs(book or {}) do updated[key] = value end
    for _, field in ipairs({
        "bookUrl", "tocUrl", "coverUrl", "intro", "kind",
        "lastChapter", "updateTime", "wordCount",
    }) do
        updated[field] = candidate and candidate[field] or ""
    end
    -- Keep the title and author used by the existing bookshelf record. Source
    -- search results may contain a site-specific spelling, but changing the
    -- local identity would orphan imported progress and chapter cache files.
    updated.name = book and book.name or candidate and candidate.name or ""
    updated.author = book and book.author or candidate and candidate.author or ""
    updated.origin = source and source.bookSourceUrl or updated.origin
    updated.originName = source and source.bookSourceName or updated.originName
    updated.bookSourceUrl = source and source.bookSourceUrl or updated.bookSourceUrl
    updated.sourceUrl = source and source.bookSourceUrl or updated.sourceUrl
    updated.sourceName = source and source.bookSourceName or updated.sourceName
    updated.sourceVariable = candidate and candidate.sourceVariable or nil
    updated.variable = candidate and candidate.variable or nil
    -- These fields belong to the previous source's TOC/progress. Keeping them
    -- would make dynamic bookshelf categories and source-specific JavaScript
    -- see stale chapter state until the next Android import.
    for _, field in ipairs({
        "durChapterIndex", "durChapterTitle", "durChapterPos",
        "durChapterTime", "totalChapterNum",
    }) do
        updated[field] = nil
    end
    return updated
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
    local original_dismiss_callback = trap_widget
        and trap_widget.dismiss_callback
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
        -- page. An existing page can still be supplied as the event boundary:
        -- it remains interactive, while Trapper does not add an invisible
        -- cancel layer above it.
        trap_target = trap_widget
    else
        trap_target = trap_widget ~= nil and trap_widget or message
    end

    local function release_trap()
        if not trap_widget then return end
        if options.keep_trap then
            -- The existing page is also used as the worker's event boundary.
            -- Trapper replaces its dismiss callback while the subprocess runs;
            -- restore the page's original callback before leaving it visible.
            trap_widget.dismiss_callback = original_dismiss_callback
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
            self:showOperationResult(message .. "\n\n" .. tostring(error_message or _("Unknown error.")))
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
                error = tostring(err or result or _("Worker failed.")),
            })
        end, trap_target, true)
        if not completed then
            if options.on_cancel then options.on_cancel() end
            return
        end
        if not payload then
            report_failure(_("Worker returned no data."))
            return
        end
        local rapidjson = require("rapidjson")
        local ok, response = pcall(rapidjson.decode, payload)
        if not ok or type(response) ~= "table" then
            report_failure(_("Operation returned invalid data."))
            return
        end
        if response.ok ~= true then
            report_failure(response.error or _("Unknown error."))
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
    -- The persisted reader session is also the chapter-list cache. Load it
    -- when a bookshelf/detail entry is opened after the UI cache was dropped
    -- (for example after opening a different document or restarting KOReader)
    -- so this path does not immediately repeat the source's network request.
    -- Storage remembers the load attempt and keeps the decoded static TOC, so
    -- repeated entries in the same UI session do not parse it again.
    if type(session) ~= "table" then
        session = self.storage:load_reader_session()
    end
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
    if type(session) ~= "table" then return nil, _("Reading session is missing.") end
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
    return nil, _("Book source for reading session not found.")
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
            if not content then return nil, err or _("Prefetch failed.") end
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
                    waiter(nil, _("Cannot save prefetched chapter."))
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
                        waiter(nil, _("Prefetch cancelled."))
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
    -- loginUi is independently meaningful in Legado: some sources provide a
    -- native form and let the generic login() action submit it without a
    -- loginUrl or mainJs. Do not hide those sources from the source picker.
    local login_ui = source.loginUi
    local has_login_ui
    if type(login_ui) == "table" then
        has_login_ui = next(login_ui) ~= nil
    elseif type(login_ui) == "string" then
        local compact = login_ui:gsub("%s+", "")
        has_login_ui = compact ~= "" and compact ~= "[]"
    end
    if has_login_ui then return true end
    for _, key in ipairs({ "loginCheckJs", "loginJs" }) do
        if type(source[key]) == "string"
                and source[key]:gsub("%s+", "") ~= "" then
            return true
        end
    end
    return false
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
        return nil, _("Source JSON must contain an object.")
    end
    local name = tostring(source.bookSourceName or "")
    local url = tostring(source.bookSourceUrl or "")
    if name == "" then
        return nil, _("Source is missing bookSourceName.")
    end
    if url == "" then
        return nil, _("Source is missing bookSourceUrl.")
    end
    return true
end

local function decode_source_json(raw, allow_array)
    local decoded_ok, decoded = pcall(rapidjson.decode, raw or "")
    if not decoded_ok or type(decoded) ~= "table" then
        return nil, _("Source JSON is invalid: ") .. tostring(decoded)
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
                return nil, T(_("Source %1: "), index) .. validation_err
            end
            sources[#sources + 1] = source
        end
    else
        return nil, _("Source JSON must contain one source object.")
    end
    if #sources == 0 then
        return nil, _("Source JSON contains no sources.")
    end
    for index, source in ipairs(sources) do
        local valid, validation_err = validate_source(source)
        if not valid then
            return nil, T(_("Source %1: "), index) .. validation_err
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
        text = _("Move source to top"),
        callback = function()
            self:runSourceReorder(source_index, "top")
        end,
    }
    items[#items + 1] = {
        text = _("Move source to bottom"),
        callback = function()
            self:runSourceReorder(source_index, "bottom")
        end,
    }
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

function Legado:runSourceReorder(source_index, destination)
    self:runWorker(_("Reordering source…"), function()
        local catalog = SourceCatalog:new(self.storage:get_state_root())
        local _, err = catalog:move_source(source_index, destination)
        if err then return nil, err end
        return true
    end, function()
        self:invalidateReaderSourceCache()
        self:showOperationResult(_("Source order updated."), function()
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

-- KOReader keeps virtual-keyboard layouts in global reader settings.  A fresh
-- installation can legitimately have an empty `keyboard_layouts` list while
-- the current layout is English; in that state the globe key has nowhere to
-- switch and a source login form appears to support no Chinese input.
--
-- Login forms are the only plugin-owned text-entry surface that needs this
-- convenience.  Temporarily activate the standard KOReader Pinyin layout and
-- restore the user's keyboard settings when the dialog is closed.  The source
-- is not involved in this choice, and no Android/Legado settings are imported.
local function prepare_login_keyboard(dialog)
    if not G_reader_settings or type(dialog) ~= "table" then return end

    local previous_layout = G_reader_settings:readSetting("keyboard_layout")
    local previous_layouts = G_reader_settings:readSetting("keyboard_layouts")
    local layouts = {}
    local seen = {}
    if type(previous_layouts) == "table" then
        for _, layout in ipairs(previous_layouts) do
            layout = tostring(layout or "")
            if layout ~= "" and not seen[layout] then
                layouts[#layouts + 1] = layout
                seen[layout] = true
            end
        end
    end
    -- Keep an English fallback in the globe popup, then make the Chinese
    -- Pinyin layout available.  Existing user-selected layouts are preserved.
    if #layouts == 0 then
        layouts[1] = "en"
        seen.en = true
    end
    if not seen.zh_CN then
        -- KOReader's globe popup supports at most four active layouts.  This
        -- list is temporary, so replace the last slot rather than creating a
        -- fifth entry that would make the stock keyboard popup invalid.
        if #layouts >= 4 then
            layouts[4] = "zh_CN"
        else
            layouts[#layouts + 1] = "zh_CN"
        end
    end
    G_reader_settings:saveSetting("keyboard_layouts", layouts)
    G_reader_settings:saveSetting("keyboard_layout", "zh_CN")
    -- The dialog may already have constructed its VirtualKeyboard before this
    -- helper is called.  Reinitialize that instance as well as the setting;
    -- changing the setting alone would only affect the next dialog.
    local keyboard = dialog._input_widget and dialog._input_widget.keyboard
    if keyboard and type(keyboard.setKeyboardLayout) == "function" then
        pcall(keyboard.setKeyboardLayout, keyboard, "zh_CN")
    end

    local restored = false
    local function restore()
        if restored then return end
        restored = true
        if previous_layout == nil then
            G_reader_settings:delSetting("keyboard_layout")
        else
            G_reader_settings:saveSetting("keyboard_layout", previous_layout)
        end
        if previous_layouts == nil then
            G_reader_settings:delSetting("keyboard_layouts")
        else
            G_reader_settings:saveSetting("keyboard_layouts", previous_layouts)
        end
    end

    -- UIManager closes dialogs through onCloseWidget even when a caller uses a
    -- custom button callback.  Wrapping that lifecycle hook also covers the
    -- hardware Back key and the title-bar close action.
    local original_on_close_widget = dialog.onCloseWidget
    dialog.onCloseWidget = function(self, ...)
        restore()
        return original_on_close_widget(self, ...)
    end
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
    prepare_login_keyboard(dialog)
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
    prepare_login_keyboard(dialog)
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
            if not value then error(err or _("Cannot build login form.")) end
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
            local prefix = operation == "toast" and _("Toast") or _("Log")
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
        if not kinds then return nil, err or _("Cannot load discovery entries.") end
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
        if not result then return nil, err or _("Discovery action failed.") end
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
            if not result then return nil, err or _("Discovery request failed.") end
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
        if not result then error(err or _("Source login failed.")) end
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
                tostring(error_message or _("Unknown error."))
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
    if category_id == "reading" then return _("Reading") end
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
                catalog, books, item.category, reading_status
            )
        end,
    }
    UIManager:show(category_menu)
end

function Legado:showBookshelfBooks(catalog, books, category, reading_status)
    local category_id = category and category.id or "all"
    local entries = catalog:books_for_category(books, category_id, reading_status)
    local items = {}
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
        -- The category selector is the bookshelf root.  Keep it as the
        -- previous page when the user closes a category, instead of sending
        -- the user back to KOReader and requiring the whole flow again.
        close_callback = function()
            self:showBookshelfCategories(catalog, books, reading_status)
        end,
        onMenuSelect = function(menu, item)
            if item.empty_category then
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
        onMenuHold = function(menu, item)
            if item.empty_category or item.choose_category or not item.book then
                return true
            end
            -- Keep the bookshelf underneath the detail page so Back/Close
            -- returns to the exact category and scroll position.
            self:showBookDetail(item.book, item.book_index, nil, menu)
            return true
        end,
    }
    UIManager:show(book_menu)
end

local function canonical_chapter_title(value)
    local text = trim_text(value):lower():gsub("%s+", "")
    -- Chapter names from different sources often differ only in spacing or
    -- punctuation. Remove ASCII punctuation and the common CJK marks without
    -- making assumptions about a source's naming convention.
    text = text:gsub("[%p%c]+", "")
    for _, mark in ipairs({
        "，", "。", "！", "？", "：", "；", "、", "“", "”", "‘", "’",
        "（", "）", "【", "】", "《", "》", "〈", "〉", "「", "」", "『", "』",
        "〔", "〕", "—", "–", "…", "·",
    }) do
        text = text:gsub(mark, "")
    end
    return text
end

local function progress_from_book(storage, book)
    local entry = storage:get_progress_entry(book)
    if entry then return entry end
    -- Older installs may only have the Android position on bookshelf.json.
    -- Treat chapter one at position zero as unread, matching the dynamic
    -- bookshelf category rules.
    local index = tonumber(book and book.durChapterIndex)
    local position = tonumber(book and book.durChapterPos) or 0
    if index and (index > 0 or position > 0) then
        return {
            index = math.floor(index) + 1,
            title = tostring(book.durChapterTitle or ""),
            position = position,
        }
    end
    return nil
end

local function match_replacement_chapter(chapters, progress)
    if type(chapters) ~= "table" or #chapters == 0
            or type(progress) ~= "table" then
        return nil
    end
    local wanted = canonical_chapter_title(progress.title)
    if wanted ~= "" then
        for _, chapter in ipairs(chapters) do
            if canonical_chapter_title(chapter.name) == wanted then
                return chapter
            end
        end
    end
    local index = tonumber(progress.index)
    if index and index >= 1 then
        index = math.max(1, math.min(#chapters, math.floor(index)))
        return chapters[index]
    end
    return nil
end

local function apply_replacement_progress(book, chapters, progress)
    if type(book) ~= "table" or type(chapters) ~= "table"
            or #chapters == 0 then
        return nil
    end
    book.totalChapterNum = #chapters
    local chapter = match_replacement_chapter(chapters, progress)
    if not chapter then
        return nil
    end
    book.durChapterIndex = math.max(0, tonumber(chapter.index) - 1)
    book.durChapterTitle = chapter.name or ""
    book.durChapterPos = progress and tonumber(progress.position) or 0
    return {
        index = tonumber(chapter.index),
        name = chapter.name or "",
    }
end

local function update_book_reference(target, replacement)
    -- Bookshelf/category menus keep the array that was loaded before the
    -- detail page opened. Updating the persisted JSON alone would leave that
    -- captured table stale until the whole bookshelf was reopened. Preserve
    -- the existing table identity so every open menu sees the new source too.
    if type(target) ~= "table" or type(replacement) ~= "table" then
        return
    end
    for key in pairs(target) do
        target[key] = nil
    end
    for key, value in pairs(replacement) do
        target[key] = value
    end
end

local function refresh_parent_book_menu(parent_widget, old_book, new_book, index, storage)
    if type(parent_widget) ~= "table"
            or type(parent_widget.item_table) ~= "table" then
        return
    end
    local changed = false
    for _, item in ipairs(parent_widget.item_table) do
        if type(item) == "table"
                and (item.book == old_book or item.book_index == index) then
            item.book = new_book
            local author = trim_text(new_book.author)
            item.text = display_text(new_book.name)
                .. (author ~= "" and ("\n" .. display_text(author)) or "")
            local last = storage:get_last_chapter(new_book)
            local progress = last and T(_("Chapter %1"), last) or nil
            local source_label = display_text(new_book.originName or new_book.origin)
            item.mandatory = progress and source_label ~= ""
                and (progress .. " · " .. source_label)
                or progress or source_label
            changed = true
            break
        end
    end
    if changed and type(parent_widget.updateItems) == "function" then
        -- Keep the current category and page; updateItems rebuilds only the
        -- visible rows and forces the source label to change immediately.
        pcall(parent_widget.updateItems, parent_widget, nil, true)
    end
end

function Legado:showBookDetail(
        book, book_index, source_override, parent_widget,
        suppress_auto_refresh, suppress_cover_download)
    if type(book) ~= "table" then return end
    local source = source_override
    if not source then
        local catalog = SourceCatalog:new(self.storage:get_state_root())
        source = catalog:find_for_book(book)
    end

    -- Details can be opened from the bookshelf or from the reader's chapter
    -- list. Resolve the shelf index for the latter so Change source is not
    -- incorrectly disabled just because the caller had no index handy.
    local resolved_book_index = tonumber(book_index)
    if not resolved_book_index then
        local catalog = SourceCatalog:new(self.storage:get_state_root())
        resolved_book_index = catalog:find_book_index(book)
    end

    local last_chapter = self.storage:get_last_chapter(book)
    local progress = last_chapter and T(_("Chapter %1"), last_chapter)
        or _("Not started")
    local detail
    detail = BookDetail:new{
        book = book,
        source = source,
        cover_path = self.storage:find_cover_path(book),
        progress_text = progress,
        on_close = function(widget)
            if self._book_detail_widget == widget then
                self._book_detail_widget = nil
            end
        end,
        on_read = function()
            if not source then
                self:showOperationResult(_("Cannot match book source."))
                return
            end
            self:showChapters(source, book)
        end,
        on_chapters = function()
            if not source then
                self:showOperationResult(_("Cannot match book source."))
                return
            end
            self:showChapters(source, book)
        end,
        on_change_source = resolved_book_index and function()
            self:showBookSourcePicker(book, resolved_book_index, parent_widget)
        end or nil,
        on_refresh = source and function()
            self:refreshBookDetail(book, resolved_book_index, source, nil, parent_widget)
        end or nil,
    }
    self._book_detail_widget = detail
    UIManager:show(detail)

    local needs_info = not suppress_auto_refresh
        and should_auto_refresh_book_detail(book, source)
    if needs_info then
        UIManager:nextTick(function()
            if self._book_detail_widget == detail then
                self:refreshBookDetail(
                    book, resolved_book_index, source, detail, parent_widget
                )
            end
        end)
    elseif not suppress_cover_download
            and trim_text(book.coverUrl) ~= ""
            and not self.storage:find_cover_path(book) then
        UIManager:nextTick(function()
            if self._book_detail_widget == detail then
                self:downloadBookCover(book, resolved_book_index, source, detail, parent_widget)
            end
        end)
    end
end

function Legado:refreshBookDetail(book, book_index, source, detail_widget, parent_widget)
    if not source then
        self:showOperationResult(_("Cannot match book source."))
        return
    end
    local cover_base = self.storage:get_cover_base_path(book)
    self:runWorker(_("Loading book information…"), function()
        local Runtime = require("legado/runtime")
        local info, info_err = Runtime.book_info(source, book)
        if not info then return nil, info_err or _("Book information request failed.") end
        local updated = merge_book_info(book, info, source)
        local cover_path, cover_error
        if trim_text(updated.coverUrl) ~= "" then
            cover_path, cover_error = Runtime.download_cover(
                source, updated, cover_base
            )
        end
        if book_index then
            local catalog = SourceCatalog:new(self.storage:get_state_root())
            local saved, save_err = catalog:update_book(book_index, updated)
            if not saved then return nil, save_err end
        end
        return {
            book = updated,
            cover_path = cover_path,
            cover_error = cover_error,
        }
    end, function(result)
        if result.cover_path then
            self.storage:remove_cover_variants(result.book, result.cover_path)
        end
        self.storage:set_cache_identity(result.book)
        self:invalidateReaderSourceCache()
        local still_open = detail_widget
            and self._book_detail_widget == detail_widget
        if detail_widget and not still_open then
            -- The user left the page while its automatic refresh was running.
            -- Keep the refreshed metadata, but do not unexpectedly reopen it.
            return
        end
        if still_open then
            self._book_detail_widget = nil
            UIManager:close(detail_widget)
        end
        -- A source can legally return an empty optional field.  This refresh
        -- was already attempted, so never let the detail page immediately
        -- schedule the same request again.  A later explicit refresh remains
        -- available from the detail actions.
        self:showBookDetail(
            result.book, book_index, source, parent_widget,
            true, result.cover_error ~= nil
        )
    end)
end

function Legado:downloadBookCover(book, book_index, source, detail_widget, parent_widget)
    if trim_text(book and book.coverUrl) == "" then return end
    local cover_base = self.storage:get_cover_base_path(book)
    self:runWorker(_("Downloading cover…"), function()
        local Runtime = require("legado/runtime")
        local path, err = Runtime.download_cover(source, book, cover_base)
        if not path then return nil, err or _("Cover download failed.") end
        return path
    end, function(path)
        self.storage:remove_cover_variants(book, path)
        if detail_widget and self._book_detail_widget == detail_widget then
            self._book_detail_widget = nil
            UIManager:close(detail_widget)
            self:showBookDetail(book, book_index, source, parent_widget)
        end
    end, {
        invisible = true,
        on_failure = function() end,
    })
end

-- Android Legado's change-source page searches all enabled sources and then
-- presents one live candidate list.  Keep the same data model on Kindle,
-- while deliberately keeping the worker result small: source rules and HTML
-- stay in the subprocess, and a preloaded TOC contributes only its count.
local SOURCE_CHANGE_MAX_CANDIDATES_PER_SOURCE = 5
local SOURCE_CHANGE_MAX_RESULTS = 240
local SOURCE_CHANGE_TOC_PROBE_LIMIT = 24
-- A source search may call several endpoints through JavaScript. Keep the
-- source-switch page responsive on a Kindle while still allowing ordinary
-- pages time to load. Runtime propagates this budget to nested ajax calls.
local SOURCE_CHANGE_SEARCH_TIMEOUT_MS = 20000
local SINGLE_SOURCE_SEARCH_TIMEOUT_MS = 30000

local function source_change_group_tokens(source)
    local groups = {}
    local function append(value)
        value = trim_text(value)
        if value == "" then return end
        local found = false
        for token in value:gmatch("[^,，|]+") do
            token = trim_text(token)
            if token ~= "" then
                found = true
                local duplicate = false
                for _, existing in ipairs(groups) do
                    if existing == token then duplicate = true break end
                end
                if not duplicate then groups[#groups + 1] = token end
            end
        end
        if not found then groups[#groups + 1] = value end
    end
    local value = source and source.bookSourceGroup
    if type(value) == "table" then
        for key, item in pairs(value) do
            if item == true and type(key) == "string" then
                append(key)
            else
                append(item)
            end
        end
    else
        append(value)
    end
    if #groups == 0 then groups[1] = "" end
    return groups
end

local function source_change_group_label(group)
    return group == "" and _("Ungrouped") or display_text(group)
end

local function source_change_groups(sources)
    local values = {}
    for _, source in ipairs(sources or {}) do
        if type(source) == "table" and source.enabled ~= false
                and tonumber(source.bookSourceType or 0) == 0 then
            for _, group in ipairs(source_change_group_tokens(source)) do
                values[group] = true
            end
        end
    end
    local result = {}
    for group in pairs(values) do result[#result + 1] = group end
    table.sort(result, function(left, right)
        return source_change_group_label(left):lower()
            < source_change_group_label(right):lower()
    end)
    return result
end

local function source_change_group_set(value)
    local result = {}
    if type(value) == "table" then
        for key, group in pairs(value) do
            if type(key) == "string" and group == true then
                result[key] = true
            elseif type(group) == "string" then
                result[group] = true
            end
        end
    elseif type(value) == "string" and trim_text(value) ~= "" then
        for group in value:gmatch("[^,，|]+") do
            group = trim_text(group)
            if group ~= "" then result[group] = true end
        end
    end
    return result
end

local function source_change_group_array(groups)
    local result = {}
    for group in pairs(groups or {}) do result[#result + 1] = group end
    table.sort(result)
    return result
end

local function source_change_group_summary(groups)
    local values = source_change_group_array(groups)
    if #values == 0 then return _("All groups") end
    local labels = {}
    for _, group in ipairs(values) do
        labels[#labels + 1] = source_change_group_label(group)
    end
    return table.concat(labels, ", ")
end

local function source_change_in_groups(source, selected)
    if next(selected or {}) == nil then return true end
    for _, group in ipairs(source_change_group_tokens(source)) do
        if selected[group] then return true end
    end
    return false
end

local function source_change_read_bool(storage, key, default)
    local value = storage:get_settings():readSetting(key)
    if type(value) == "boolean" then return value end
    if value ~= nil then
        local text = tostring(value):lower()
        if text == "true" or text == "1" then return true end
        if text == "false" or text == "0" then return false end
    end
    return default
end

local function source_change_options(storage)
    return {
        check_author = source_change_read_bool(
            storage, "change_source_check_author", true
        ),
        load_info = source_change_read_bool(
            storage, "change_source_load_info", false
        ),
        load_toc = source_change_read_bool(
            storage, "change_source_load_toc", false
        ),
        load_word_count = source_change_read_bool(
            storage, "change_source_load_word_count", false
        ),
    }
end

local function source_change_save_options(storage, options)
    local settings = storage:get_settings()
    settings:saveSetting("change_source_check_author", options.check_author == true)
    settings:saveSetting("change_source_load_info", options.load_info == true)
    settings:saveSetting("change_source_load_toc", options.load_toc == true)
    settings:saveSetting(
        "change_source_load_word_count", options.load_word_count == true
    )
    settings:flush()
end

local function source_change_load_groups(storage)
    return source_change_group_set(
        storage:get_settings():readSetting("change_source_groups")
    )
end

local function source_change_save_groups(storage, groups)
    local settings = storage:get_settings()
    settings:saveSetting("change_source_groups", source_change_group_array(groups))
    settings:flush()
end

local function source_change_options_summary(options)
    local values = {}
    if options.check_author then values[#values + 1] = _("Author") end
    if options.load_info then values[#values + 1] = _("Info") end
    if options.load_toc then values[#values + 1] = _("TOC count") end
    if options.load_word_count then values[#values + 1] = _("Extra info") end
    if #values == 0 then return _("None") end
    return table.concat(values, " · ")
end

local function source_change_truncate_utf8(value, max_bytes)
    value = tostring(value or "")
    max_bytes = tonumber(max_bytes) or #value
    if #value <= max_bytes then return value end
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
    return value:sub(1, last) .. "…"
end

local function source_change_normalize(value)
    value = trim_text(value):lower():gsub("%s+", "")
    value = value:gsub("[，。！？：；、“”‘’（）【】《》〈〉—…·]", "")
    return value:gsub("%p", "")
end

local function source_change_match(candidate, book, check_author)
    if type(candidate) ~= "table" or trim_text(candidate.bookUrl) == "" then
        return nil
    end
    local wanted_name = source_change_normalize(book and book.name)
    local candidate_name = source_change_normalize(candidate.name)
    if wanted_name == "" or candidate_name ~= wanted_name then return nil end
    local score = 2
    local wanted_author = source_change_normalize(book and book.author)
    if check_author and wanted_author ~= "" then
        local candidate_author = source_change_normalize(candidate.author)
        if candidate_author == ""
                or not candidate_author:find(wanted_author, 1, true) then
            return nil
        end
        score = score + 1
    elseif wanted_author ~= "" then
        local candidate_author = source_change_normalize(candidate.author)
        if candidate_author ~= ""
                and candidate_author:find(wanted_author, 1, true) then
            score = score + 1
        end
    end
    return score
end

local function source_change_copy_candidate(candidate)
    local result = {}
    for key, value in pairs(candidate or {}) do
        if type(value) == "string" or type(value) == "number"
                or type(value) == "boolean" then
            result[key] = value
        elseif key == "variable" and type(value) == "table" then
            result[key] = value
        end
    end
    -- An unusually verbose intro should not make the change-source result
    -- payload compete with the actual candidate list. The full introduction
    -- is fetched again after the user selects this source.
    if type(result.intro) == "string" and #result.intro > 4096 then
        result.intro = source_change_truncate_utf8(result.intro, 4096)
    end
    return result
end

local function source_change_merge_info(book, info)
    if type(info) ~= "table" then return end
    for _, field in ipairs(BOOK_INFO_FIELDS) do
        if info[field] ~= nil and trim_text(info[field]) ~= "" then
            book[field] = info[field]
        end
    end
    if trim_text(info.sourceVariable) ~= "" then
        book.sourceVariable = info.sourceVariable
    end
    if type(info.variable) == "table" then book.variable = info.variable end
end

local function source_change_order(source, index)
    local custom = tonumber(source and source.customOrder)
    return custom or tonumber(index) or 0
end

local function source_change_is_current(state, source)
    local source_url = trim_text(source and source.bookSourceUrl)
    local source_name = trim_text(source and source.bookSourceName)
    if state.current_url ~= "" and source_url ~= "" then
        return source_url == state.current_url
    end
    return state.current_name ~= "" and source_name ~= ""
        and source_name == state.current_name
end

local function source_change_visible(state, record)
    local source = state.sources[record.source_index]
    if not source or not source_change_in_groups(source, state.selected_groups) then
        return false
    end
    local filter = source_change_normalize(state.source_filter)
    if filter == "" then return true end
    local source_name = source_change_normalize(source_display_name(source))
    local book_name = source_change_normalize(record.book and record.book.name)
    return source_name:find(filter, 1, true) ~= nil
        or book_name:find(filter, 1, true) ~= nil
end

local function source_change_current_chapter(chapters, target_book, progress)
    if type(chapters) ~= "table" or #chapters == 0 then return nil, nil end

    -- Match Android's BookHelp.getDurChapter(): a title is more stable than a
    -- numeric position after a source inserts or removes chapters.  Fall back
    -- to the stored one-based Kindle position (or Android's zero-based field)
    -- when the title is unavailable or the source changed its spelling.
    local wanted_title = trim_text(progress and progress.title)
    if wanted_title == "" then
        wanted_title = trim_text(target_book and target_book.durChapterTitle)
    end
    local wanted = source_change_normalize(wanted_title)
    if wanted ~= "" then
        for index, chapter in ipairs(chapters) do
            if source_change_normalize(chapter and chapter.name) == wanted then
                return chapter, index
            end
        end
    end

    local index = tonumber(progress and progress.index)
    if not index then
        local android_index = tonumber(target_book and target_book.durChapterIndex)
        if android_index then index = android_index + 1 end
    end
    if index and index >= 1 and index <= #chapters then
        index = math.floor(index)
        return chapters[index], index
    end

    -- Android displays the latest chapter when the change-source page was
    -- opened outside the reader.  This is also the useful fallback for an
    -- unread bookshelf entry with no saved progress.
    return chapters[#chapters], #chapters
end

local function source_change_extra_text(state, candidate)
    if not (state.options and state.options.load_word_count) then return nil end
    local chapter_index = tonumber(candidate and candidate.chapter_word_count_index)
    local chapter_title = trim_text(candidate and candidate.chapter_word_count_title)
    local word_count = tonumber(candidate and candidate.chapter_word_count)
    if not chapter_index or chapter_title == "" then return nil end
    chapter_index = math.floor(chapter_index)
    if word_count and word_count >= 0 then
        local response_time = tonumber(candidate.respond_time)
        if response_time and response_time >= 0 then
            return T(
                _("[%1] %2 · %3 words · %4 ms"),
                chapter_index, display_text(chapter_title),
                math.floor(word_count), math.floor(response_time)
            )
        end
        return T(
            _("[%1] %2 · %3 words"),
            chapter_index, display_text(chapter_title), math.floor(word_count)
        )
    end
    return T(
        _("[%1] %2 · %3"),
        chapter_index, display_text(chapter_title),
        display_text(
            candidate and candidate.chapter_word_count_error
                or _("Word count unavailable")
        )
    )
end

-- Android's change-source adapter uses the source name as the card title and
-- shows author/latest-chapter as supporting content.  KOReader's Menu renders
-- one text stream, so use the same fields in a wrapped, delimiter-separated
-- block.  The book title, source URL and source actions do not belong in this
-- candidate summary: the title is already in the page header and actions are
-- available from the row's long-press menu.
local function source_change_result_text(state, source, candidate)
    local values = {}
    local function append(value)
        value = trim_text(value)
        if value ~= "" then values[#values + 1] = display_text(value) end
    end

    append(source_display_name(source))
    append(candidate and candidate.author)
    local latest_chapter = trim_text(candidate and candidate.lastChapter)
    append(latest_chapter ~= "" and latest_chapter or _("No latest chapter"))
    append(source_change_extra_text(state, candidate))
    return table.concat(values, " · ")
end

local function source_change_status(state)
    if state.searching then
        local progress = state.progress or {}
        local current = display_text(progress.source_name or _("starting"))
        local status = T(
            _("Searching sources: %1/%2 · %3"),
            tonumber(progress.done) or 0,
            tonumber(progress.total) or state.source_count or 0,
            current
        )
        if state.restart_after_search then
            status = status .. " · " .. _("options pending")
        end
        return status
    end
    if state.search_error then
        return _("Source search failed; tap Refresh to try again.")
    end
    return T(
        _("%1 matches from %2 sources"),
        #state.results,
        tonumber(state.source_count) or 0
    )
end

function Legado:showBookSourcePicker(book, book_index, parent_widget)
    local catalog = SourceCatalog:new(self.storage:get_state_root())
    local sources, err = catalog:list()
    if not sources then
        self:showOperationResult(_("Cannot load sources:\n") .. tostring(err))
        return
    end
    local searchable = 0
    for _, source in ipairs(sources) do
        if type(source) == "table" and source.enabled ~= false
                and tonumber(source.bookSourceType or 0) == 0
                and type(source.searchUrl) == "string"
                and trim_text(source.searchUrl) ~= "" then
            searchable = searchable + 1
        end
    end
    if searchable == 0 then
        self:showOperationResult(_("No enabled text source with a search URL."))
        return
    end

    local state = {
        book = book,
        book_index = book_index,
        parent_widget = parent_widget,
        sources = sources,
        current_url = trim_text(book and (book.origin
            or book.bookSourceUrl or book.sourceUrl)),
        current_name = trim_text(book and (book.originName or book.sourceName)),
        selected_groups = source_change_load_groups(self.storage),
        source_filter = "",
        options = source_change_options(self.storage),
        results = {},
        errors = {},
        progress = { done = 0, total = searchable, source_name = "" },
        source_count = searchable,
        searching = false,
        done = false,
        auto_scroll_current = true,
    }
    self._book_source_change_state = state
    self:showBookSourceChangeMenu(state)
    self:startBookSourceSearch(state)
end

function Legado:showBookSourceChangeMenu(state)
    local function safe_mandatory(value)
        value = trim_text(value)
        if value == "" then return nil end
        -- KOReader's MenuItem subtracts the measured right-hand status width
        -- from the text width without clamping it.  A long source/group name
        -- can therefore make TextBoxWidget receive a zero/negative width.
        -- Keep the useful prefix while leaving the wrapped candidate text
        -- untouched.
        -- 32 bytes leaves ample room even with KOReader's 16 px mandatory
        -- font. The menu implementation does not otherwise protect against
        -- a long right-hand widget consuming the entire row.
        return source_change_truncate_utf8(value, 32)
    end
    local items = {
        {
            text = state.searching and _("Searching all sources…")
                or _("Refresh source results"),
            mandatory = safe_mandatory(source_change_status(state)),
            action = "refresh",
            separator = true,
        },
        {
            text = state.source_filter == "" and _("Filter source results")
                or T(_("Filter: %1"), display_text(state.source_filter)),
            mandatory = safe_mandatory(_("Source name or title filter")),
            action = "filter",
        },
        {
            text = _("Source groups"),
            mandatory = safe_mandatory(
                source_change_group_summary(state.selected_groups)
            ),
            action = "groups",
        },
        {
            text = _("Change-source options"),
            mandatory = safe_mandatory(
                source_change_options_summary(state.options)
            ),
            action = "options",
        },
    }

    local visible_count = 0
    local current_item
    local visible_results = {}
    for record_index, record in ipairs(state.results or {}) do
        if source_change_visible(state, record) then
            visible_results[#visible_results + 1] = record
        end
    end
    table.sort(visible_results, function(left, right)
        if (left.match_score or 0) ~= (right.match_score or 0) then
            return (left.match_score or 0) > (right.match_score or 0)
        end
        local left_source = state.sources[left.source_index] or {}
        local right_source = state.sources[right.source_index] or {}
        local left_order = source_change_order(left_source, left.source_index)
        local right_order = source_change_order(right_source, right.source_index)
        if left_order ~= right_order then return left_order < right_order end
        if left.source_index ~= right.source_index then
            return left.source_index < right.source_index
        end
        return source_display_name(left_source):lower()
            < source_display_name(right_source):lower()
    end)

    for result_index, record in ipairs(visible_results) do
        local source = state.sources[record.source_index]
        local candidate = record.book or {}
        local status = {}
        if source_change_is_current(state, source) then
            status[#status + 1] = _("Current")
        end
        if tonumber(candidate.chapter_count) then
            status[#status + 1] = T(_("%1 chapters"), candidate.chapter_count)
        elseif candidate.toc_probe_skipped then
            status[#status + 1] = _("TOC count skipped for memory safety")
        end
        if candidate.enrichment_error then
            status[#status + 1] = _("Info unavailable")
        end
        local item = {
            text = source_change_result_text(state, source, candidate),
            mandatory = #status > 0 and safe_mandatory(
                table.concat(status, " · ")
            ) or nil,
            source = source,
            source_index = record.source_index,
            book = candidate,
            record = record,
        }
        items[#items + 1] = item
        visible_count = visible_count + 1
        if not current_item and source_change_is_current(state, source) then
            current_item = #items
        end
    end

    if state.done and visible_count == 0 then
        if tonumber(state.source_count) == 0 then
            items[#items + 1] = {
                text = _("No enabled source in selected groups"),
                mandatory = safe_mandatory(
                    _("Choose All groups or select another group.")
                ),
                dim = true,
                action = "empty",
            }
        else
            items[#items + 1] = {
                text = _("No matching source results"),
                mandatory = safe_mandatory(state.source_filter ~= ""
                    and _("Clear the filter or choose another group.")
                    or _("Try Refresh or change the author check.")),
                dim = true,
                action = "empty",
            }
        end
    end
    if #state.errors > 0 then
        table.insert(items, 5, {
            text = T(_("Source errors (%1)"), #state.errors),
            mandatory = safe_mandatory(_("Tap to inspect; other sources continue.")),
            action = "errors",
        })
        if current_item then current_item = current_item + 1 end
    end
    if current_item then items.current = current_item end

    if state.menu then
        state.menu.item_table = items
        -- Dynamic-height rows cache both page_items and page_num. Rebuild that
        -- cache before asking for a page: the initial menu has only its header
        -- rows, while search results arrive incrementally from the worker.
        state.menu:_recalculateDimen(false)
        local page_count = math.max(1, state.menu:getPageNumber(#items))
        if current_item and state.auto_scroll_current then
            state.menu.page = state.menu:getPageNumber(current_item)
            state.auto_scroll_current = false
        else
            state.menu.page = math.min(state.menu.page or 1, page_count)
        end
        state.menu.page_num = page_count
        state.menu:updateItems(nil, true)
        return state.menu
    end

    local source_menu
    source_menu = LegadoMenu:new{
        title = T(_("Change source for %1"), display_text(state.book.name)),
        item_table = items,
        items_per_page = 12,
        -- Android uses a source title plus supporting metadata in each card.
        -- MenuItem removes literal newlines, so let KOReader wrap the compact
        -- field stream and calculate a separate height for every result.
        items_max_lines = 4,
        onMenuSelect = function(menu, item)
            if item.action == "refresh" then
                if not state.searching then self:startBookSourceSearch(state) end
                return
            end
            if item.action == "filter" then
                self:showBookSourceFilterDialog(state)
                return
            end
            if item.action == "groups" then
                self:showBookSourceGroups(state)
                return
            end
            if item.action == "options" then
                self:showBookSourceOptions(state)
                return
            end
            if item.action == "errors" then
                self:showBookSourceErrors(state)
                return
            end
            if not item.record or not item.source or not item.book then return end
            -- A result is actionable as soon as its source worker has emitted
            -- it. Do not make the user wait for the remaining sources: the
            -- source replacement worker fetches and validates the candidate's
            -- TOC independently, while the search page may continue receiving
            -- results in the background.
            if source_change_is_current(state, item.source) then
                self:showOperationResult(_("This is already the current source."))
                return
            end
            self:replaceBookSource(
                state.book, state.book_index, item.source, item.book,
                state.parent_widget, menu
            )
        end,
        onMenuHold = function(menu, item)
            if item and item.record and item.source then
                -- The Android adapter exposes source management from a result
                -- row. Reuse the same generic source-actions implementation so
                -- login, edit, enable/disable and delete stay source-agnostic.
                self:showSourceActions(item.source, item.source_index, menu)
            end
            return true
        end,
    }
    state.menu = source_menu
    UIManager:show(source_menu)
    return source_menu
end

function Legado:showBookSourceFilterDialog(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Filter source results"),
        description = _("Filter the Android-style result list by source name or book title."),
        input = state.source_filter,
        input_hint = _("Source name"),
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
                        state.source_filter = trim_text(dialog:getInputValue())
                        UIManager:close(dialog)
                        self:showBookSourceChangeMenu(state)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Legado:showBookSourceGroups(state)
    local groups = source_change_groups(state.sources)
    local working = source_change_group_set(state.selected_groups)
    local group_menu
    local function render()
        local items = {
            {
                text = _("Apply source-group filter"),
                mandatory = source_change_group_summary(working),
                action = "apply",
                separator = true,
            },
            {
                text = _("All groups"),
                mandatory = next(working) == nil and _("Selected") or nil,
                group_value = "__all__",
            },
        }
        for group_index, group in ipairs(groups) do
            items[#items + 1] = {
                text = source_change_group_label(group),
                mandatory = working[group] and _("Selected") or _("Not selected"),
                group_value = group,
            }
        end
        if group_menu then
            group_menu.item_table = items
            group_menu:updateItems(nil, true)
        else
            group_menu = LegadoMenu:new{
                title = _("Source groups"),
                item_table = items,
                items_per_page = 12,
                onMenuSelect = function(menu, item)
                    if item.action == "apply" then
                        local previous = table.concat(
                            source_change_group_array(state.selected_groups), "\0"
                        )
                        state.selected_groups = source_change_group_set(working)
                        local next_groups = table.concat(
                            source_change_group_array(state.selected_groups), "\0"
                        )
                        source_change_save_groups(self.storage, state.selected_groups)
                        UIManager:close(menu)
                        self:showBookSourceChangeMenu(state)
                        if previous ~= next_groups then
                            if state.searching then
                                state.restart_after_search = true
                            else
                                self:startBookSourceSearch(state)
                            end
                        end
                        return
                    end
                    if item.group_value == "__all__" then
                        working = {}
                    elseif item.group_value then
                        if next(working) == nil then
                            working[item.group_value] = true
                        elseif working[item.group_value] then
                            working[item.group_value] = nil
                        else
                            working[item.group_value] = true
                        end
                    end
                    render()
                end,
            }
            UIManager:show(group_menu)
        end
    end
    render()
end

function Legado:showBookSourceOptions(state)
    local working = {
        check_author = state.options.check_author == true,
        load_info = state.options.load_info == true,
        load_toc = state.options.load_toc == true,
        load_word_count = state.options.load_word_count == true,
    }
    local options_menu
    local function render()
        local function option_item(text, key, mandatory)
            local status = working[key] and _("Enabled") or _("Disabled")
            if mandatory then status = status .. " · " .. mandatory end
            return {
                text = text,
                mandatory = status,
                option_key = key,
            }
        end
        local items = {
            {
                text = _("Apply change-source options"),
                mandatory = source_change_options_summary(working),
                action = "apply",
                separator = true,
            },
            option_item(_("Check author"), "check_author"),
            option_item(_("Load book information"), "load_info"),
            option_item(
                _("Probe TOC chapter count"),
                "load_toc",
                _("slow; count only, no TOC kept")
            ),
            option_item(
                _("Show extra information"),
                "load_word_count",
                _("slow; loads the current chapter")
            ),
        }
        if options_menu then
            options_menu.item_table = items
            options_menu:updateItems(nil, true)
        else
            options_menu = LegadoMenu:new{
                title = _("Change-source options"),
                item_table = items,
                items_per_page = 12,
                onMenuSelect = function(menu, item)
                    if item.action == "apply" then
                        local changed = working.check_author ~= state.options.check_author
                            or working.load_info ~= state.options.load_info
                            or working.load_toc ~= state.options.load_toc
                            or working.load_word_count ~= state.options.load_word_count
                        state.options = working
                        source_change_save_options(self.storage, state.options)
                        UIManager:close(menu)
                        self:showBookSourceChangeMenu(state)
                        if changed then
                            if state.searching then
                                state.restart_after_search = true
                            else
                                self:startBookSourceSearch(state)
                            end
                        end
                        return
                    end
                    if item.option_key then
                        working[item.option_key] = not working[item.option_key]
                        render()
                    end
                end,
            }
            UIManager:show(options_menu)
        end
    end
    render()
end

function Legado:showBookSourceErrors(state)
    local lines = { T(_("%1 source requests failed."), #state.errors) }
    for index, error in ipairs(state.errors) do
        if index > 12 then
            lines[#lines + 1] = T(_("… and %1 more"), #state.errors - 12)
            break
        end
        lines[#lines + 1] = display_text(error.source_name)
            .. ": " .. display_text(error.message)
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function Legado:pollBookSourceChangeProgress(state, generation)
    if not state.searching or state.generation ~= generation then return end
    local raw = util.readFromFile(state.progress_path)
    if raw and raw ~= "" then
        local ok, progress = pcall(rapidjson.decode, raw)
        if ok and type(progress) == "table"
                and tostring(progress.generation) == tostring(generation) then
            state.progress = progress
            if type(progress.records) == "table" then
                state.results = progress.records
            end
            if type(progress.errors) == "table" then
                state.errors = progress.errors
            end
            self:showBookSourceChangeMenu(state)
        end
    end
    UIManager:scheduleIn(0.5, function()
        self:pollBookSourceChangeProgress(state, generation)
    end)
end

function Legado:startBookSourceSearch(state)
    if state.searching then return end
    local search_sources = {}
    local selected_groups = source_change_group_set(state.selected_groups)
    for source_index, source in ipairs(state.sources or {}) do
        if type(source) == "table" and source.enabled ~= false
                and tonumber(source.bookSourceType or 0) == 0
                and type(source.searchUrl) == "string"
                and trim_text(source.searchUrl) ~= ""
                and source_change_in_groups(source, selected_groups) then
            search_sources[#search_sources + 1] = {
                source = source,
                source_index = source_index,
            }
        end
    end
    if #search_sources == 0 then
        state.searching = false
        state.done = true
        state.search_error = nil
        state.results = {}
        state.errors = {}
        state.progress = { done = 0, total = 0, source_name = "" }
        state.source_count = 0
        self:showBookSourceChangeMenu(state)
        return
    end

    state.searching = true
    state.done = false
    state.search_error = nil
    state.results = {}
    state.errors = {}
    state.progress = { done = 0, total = #search_sources, source_name = "" }
    state.source_count = #search_sources
    state.auto_scroll_current = true
    state.generation = (state.generation or 0) + 1
    local generation = state.generation
    state.progress_path = self.storage:get_root()
        .. "/source-change-progress-" .. tostring(generation) .. ".json"
    os.remove(state.progress_path)
    self:showBookSourceChangeMenu(state)

    local keyword = trim_text(state.book and state.book.name)
    local target_book = state.book
    local target_progress = progress_from_book(self.storage, target_book)
    local options = {
        check_author = state.options.check_author == true,
        load_info = state.options.load_info == true,
        load_toc = state.options.load_toc == true,
        load_word_count = state.options.load_word_count == true,
    }
    local progress_path = state.progress_path
    self:runWorker(_("Searching all sources…"), function()
        local Runtime = require("legado/runtime")
        local worker_util = require("util")
        local worker_json = require("rapidjson")
        local socket = require("socket")
        local output = {
            records = {},
            errors = {},
            source_count = #search_sources,
            no_match_count = 0,
            toc_probe_count = 0,
            toc_probe_skipped = 0,
        }
        local function write_progress(done, source_name)
            pcall(function()
                local encoded = worker_json.encode({
                    generation = generation,
                    done = done,
                    total = #search_sources,
                    source_name = source_name or "",
                    found = #output.records,
                    records = output.records,
                    errors = output.errors,
                    no_match_count = output.no_match_count,
                })
                worker_util.writeToFile(encoded, progress_path)
            end)
        end
        local function add_record(source_entry, candidate, match_score)
            if #output.records >= SOURCE_CHANGE_MAX_RESULTS then return false end
            output.records[#output.records + 1] = {
                source_index = source_entry.source_index,
                book = candidate,
                match_score = match_score,
            }
            return true
        end
        local function now_milliseconds()
            if type(socket.gettime) == "function" then
                return socket.gettime() * 1000
            end
            return os.clock() * 1000
        end
        local function load_word_count(source, candidate)
            local toc_result, toc_error = Runtime.chapter_list(
                source, candidate, { use_cached_info = true }
            )
            output.toc_probe_count = output.toc_probe_count + 1
            if type(toc_result) ~= "table"
                    or type(toc_result.chapters) ~= "table"
                    or #toc_result.chapters == 0 then
                candidate.enrichment_error = tostring(
                    toc_error or _("Chapter list is empty.")
                )
                return
            end

            source_change_merge_info(candidate, toc_result.info)
            local chapters = toc_result.chapters
            candidate.chapter_count = #chapters
            candidate.totalChapterNum = #chapters
            local chapter, chapter_index = source_change_current_chapter(
                chapters, target_book, target_progress
            )
            if not chapter then return end

            local title = source_change_truncate_utf8(chapter.name or "", 96)
            local started = now_milliseconds()
            local content, content_error = Runtime.chapter_content(
                source, chapter, candidate
            )
            local elapsed = math.max(0, math.floor(now_milliseconds() - started))
            candidate.chapter_word_count_index = chapter_index
            candidate.chapter_word_count_title = title
            candidate.respond_time = elapsed
            if content then
                candidate.chapter_word_count = #content
            else
                candidate.chapter_word_count = -1
                candidate.chapter_word_count_error = source_change_truncate_utf8(
                    content_error or _("Word count unavailable"), 512
                )
            end
            content = nil
            chapters = nil
            toc_result = nil
            collectgarbage("collect")
        end
        write_progress(0, "")
        for position, source_entry in ipairs(search_sources) do
            local source = source_entry.source
            local source_name = source_display_name(source)
            write_progress(position - 1, source_name)
            local ok, books, search_error = pcall(
                Runtime.search_source, source, keyword, 1, {
                    timeout = SOURCE_CHANGE_SEARCH_TIMEOUT_MS,
                    total_timeout = SOURCE_CHANGE_SEARCH_TIMEOUT_MS,
                    lightweight = true,
                }
            )
            if not ok then
                search_error = books
                books = nil
            end
            if type(books) ~= "table" then
                output.errors[#output.errors + 1] = {
                    source_name = source_name,
                    message = tostring(search_error or _("Search failed.")),
                }
            else
                local matches = {}
                local seen = {}
                for _, candidate in ipairs(books) do
                    local score = source_change_match(
                        candidate, target_book, options.check_author
                    )
                    local url = trim_text(candidate and candidate.bookUrl)
                    if score and url ~= "" and not seen[url] then
                        seen[url] = true
                        matches[#matches + 1] = {
                            book = source_change_copy_candidate(candidate),
                            score = score,
                        }
                    end
                end
                table.sort(matches, function(left, right)
                    return left.score > right.score
                end)
                if #matches == 0 then
                    output.no_match_count = output.no_match_count + 1
                else
                    local limit = math.min(
                        #matches, SOURCE_CHANGE_MAX_CANDIDATES_PER_SOURCE
                    )
                    for match_index = 1, limit do
                        local candidate = matches[match_index].book
                        if (options.load_toc or options.load_word_count)
                                and output.toc_probe_count < SOURCE_CHANGE_TOC_PROBE_LIMIT then
                            if options.load_word_count then
                                load_word_count(source, candidate)
                            else
                                local toc_result, toc_error = Runtime.chapter_list(
                                    source, candidate, { use_cached_info = true }
                                )
                                output.toc_probe_count = output.toc_probe_count + 1
                                if type(toc_result) == "table" then
                                    source_change_merge_info(candidate, toc_result.info)
                                    if type(toc_result.chapters) == "table" then
                                        candidate.chapter_count = #toc_result.chapters
                                        candidate.totalChapterNum = #toc_result.chapters
                                    end
                                elseif toc_error then
                                    candidate.enrichment_error = tostring(toc_error)
                                end
                                toc_result = nil
                                collectgarbage("collect")
                            end
                        elseif options.load_toc or options.load_word_count then
                            candidate.toc_probe_skipped = true
                            output.toc_probe_skipped = output.toc_probe_skipped + 1
                        elseif options.load_info then
                            local info, info_error = Runtime.book_info(source, candidate)
                            if type(info) == "table" then
                                source_change_merge_info(candidate, info)
                            elseif info_error then
                                candidate.enrichment_error = tostring(info_error)
                            end
                        end
                        if type(candidate.intro) == "string" and #candidate.intro > 4096 then
                            candidate.intro = source_change_truncate_utf8(
                                candidate.intro, 4096
                            )
                        end
                        if not add_record(
                                source_entry, candidate, matches[match_index].score) then
                            break
                        end
                    end
                end
            end
            books = nil
            collectgarbage("collect")
            write_progress(position, source_name)
        end
        write_progress(#search_sources, _("completed"))
        return output
    end, function(result)
        if state.generation ~= generation then return end
        state.searching = false
        state.done = true
        state.results = type(result) == "table" and result.records or {}
        state.errors = type(result) == "table" and result.errors or {}
        state.source_count = type(result) == "table" and result.source_count
            or #search_sources
        state.progress = {
            done = state.source_count,
            total = state.source_count,
            source_name = _("completed"),
        }
        os.remove(progress_path)
        self:showBookSourceChangeMenu(state)
        if state.restart_after_search then
            state.restart_after_search = false
            self:startBookSourceSearch(state)
        end
    end, {
        invisible = true,
        -- Keep the change-source page usable while the source workers run.
        -- Passing nil here creates Trapper's invisible TrapWidget, whose first
        -- tap is interpreted as cancellation. The already displayed menu is
        -- a safe event boundary: its page buttons, filters and result rows
        -- remain usable, while the search subprocess continues in parallel.
        trap_widget = state.menu,
        keep_trap = true,
        on_failure = function(error_message)
            if state.generation ~= generation then return end
            state.searching = false
            state.done = true
            state.search_error = tostring(error_message)
            os.remove(progress_path)
            self:showBookSourceChangeMenu(state)
        end,
        on_cancel = function()
            if state.generation ~= generation then return end
            state.searching = false
            state.done = true
            state.search_error = _("Source search was cancelled.")
            os.remove(progress_path)
            self:showBookSourceChangeMenu(state)
        end,
    })
    self:pollBookSourceChangeProgress(state, generation)
end

function Legado:replaceBookSource(
        book, book_index, source, candidate, parent_widget, source_picker)
    if type(source) ~= "table" or type(candidate) ~= "table"
            or trim_text(candidate.bookUrl) == "" then
        self:showOperationResult(_("Selected source result is incomplete."))
        return
    end
    local old_progress = progress_from_book(self.storage, book)
    local updated = replace_book_source(book, candidate, source)
    local chapter_parent = type(parent_widget) == "table"
        and parent_widget._legado_chapter_menu == true
    self:runWorker(_("Changing book source…"), function()
        local Runtime = require("legado/runtime")
        local catalog = SourceCatalog:new(self.storage:get_state_root())
        local source_index = catalog:find_book_index(book)
            or tonumber(book_index)
        if not source_index then
            return nil, _("Book is no longer in the bookshelf.")
        end

        -- Fetch the new TOC before saving the final shelf record. Android's
        -- change-source callback receives the candidate and its TOC together;
        -- requiring the same proof here prevents a source with a broken TOC
        -- from replacing a readable shelf entry.
        local toc_result, toc_error = Runtime.chapter_list(source, updated, {
            use_cached_info = true,
        })
        if type(toc_result) ~= "table"
                or type(toc_result.chapters) ~= "table"
                or #toc_result.chapters == 0 then
            return nil, toc_error or _("Chapter list is empty.")
        end
        updated = merge_book_info(updated, toc_result.info, source)
        apply_replacement_progress(updated, toc_result.chapters, old_progress)

        local saved, save_err = catalog:update_book(source_index, updated)
        if not saved then return nil, save_err end

        -- All following writes use a fresh Storage instance because this task
        -- runs in a subprocess. Migrate the stable reading record before
        -- clearing source-specific cache and invalidate any old TOC session.
        local storage = Storage:new()
        storage:migrate_progress(book, updated, old_progress)
        storage:clear_reader_session_for_book(book)
        local cache_removed = storage:clear_book_cache(book)
        -- Book names are normally stable, but a source can normalize a title
        -- differently. Clear a pre-existing directory under the new display
        -- name too, without deleting the new identity marker when both names
        -- resolve to the same directory.
        if storage:get_book_dir(book) ~= storage:get_book_dir(updated) then
            cache_removed = cache_removed + storage:clear_book_cache(updated)
        end
        storage:set_cache_identity(updated)

        local mapped_progress
        local reader_session_saved = false
        mapped_progress = match_replacement_chapter(
            toc_result.chapters, old_progress
        )
        if mapped_progress then
            storage:save_last_chapter(updated, {
                index = mapped_progress.index,
                name = mapped_progress.name,
                position = old_progress and old_progress.position,
            })
        end
        if #toc_result.chapters > 0 then
            reader_session_saved = storage:save_reader_session(
                updated,
                source,
                toc_result.chapters,
                mapped_progress and mapped_progress.index or 1,
                true
            )
        end
        return {
            book = updated,
            source_index = source_index,
            chapter_count = #toc_result.chapters,
            progress = mapped_progress,
            cache_removed = cache_removed,
            reader_session_saved = reader_session_saved,
        }
    end, function(result)
        if source_picker then
            UIManager:close(source_picker)
        end
        update_book_reference(book, result.book)
        self._book_source_change_state = nil
        self.storage:invalidate_reading_record_cache()
        self.storage:set_cache_identity(result.book)
        self.storage:remove_cover_variants(result.book)
        self._reader_session_cache = nil
        self._reader_session_cache_file = nil
        local detail_parent = parent_widget
        local chapter_parent_refreshed = false
        if chapter_parent and result.reader_session_saved
                and result.chapter_count > 0 then
            -- The old chapter menu contains the old source's callbacks and
            -- TOC. Re-open it from the session written by the worker rather
            -- than returning a large TOC through the worker result payload.
            self.storage:invalidate_reader_session_cache()
            local refreshed = self.storage:load_reader_session()
            if refreshed and type(refreshed.chapters) == "table"
                    and #refreshed.chapters > 0 then
                UIManager:close(parent_widget)
                self._reader_session_cache = refreshed
                self._reader_session_cache_file = nil
                detail_parent = self:showChapterMenu(
                    source,
                    refreshed.book or result.book,
                    refreshed.chapters,
                    {
                        current_index = result.progress
                            and result.progress.index or refreshed.current_index,
                        reader_session = refreshed,
                    }
                )
                chapter_parent_refreshed = detail_parent ~= nil
            end
        end
        if not chapter_parent_refreshed then
            refresh_parent_book_menu(
                parent_widget, book, result.book, result.source_index, self.storage
            )
        end
        self:invalidateReaderSourceCache()
        self:showBookDetail(
            result.book,
            result.source_index,
            source,
            detail_parent
        )
    end, {
        on_failure = function(error_message)
            self:showOperationResult(
                _("Cannot change source:\n") .. tostring(error_message)
            )
        end,
    })
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
        local books, err = Runtime.search_source(source, keyword, 1, {
            timeout = SINGLE_SOURCE_SEARCH_TIMEOUT_MS,
            total_timeout = SINGLE_SOURCE_SEARCH_TIMEOUT_MS,
            lightweight = true,
        })
        if not books then return nil, err or _("Search failed.") end
        return books
    end, function(books)
        if type(books) ~= "table" or #books == 0 then
            self:showOperationResult(_("No books found."))
            return
        end
        self:showSearchResults(source, books)
    end)
end

function Legado:showSearchResults(source, books, on_select)
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
            if on_select then
                on_select(item.book)
            else
                self:showChapters(source, item.book)
            end
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
    items[#items + 1] = {
        text = _("Book details"),
        mandatory = _("Cover · introduction · source"),
        detail = true,
        separator = true,
    }
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
            if item.detail then
                local action_source = get_source()
                self:showBookDetail(display_book, nil, action_source, menu)
                return
            end
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
    chapter_menu._legado_chapter_menu = true
    UIManager:show(chapter_menu)
    return chapter_menu
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
        if not result then return nil, err or _("Chapter list failed.") end
        return result
    end, function(result)
        if type(result) ~= "table" or type(result.chapters) ~= "table"
                or #result.chapters == 0 then
            self:showOperationResult(_("Chapter list is empty."))
            return
        end
        local display_book = result.info or book
        -- Cache the TOC as soon as it has been fetched, rather than waiting
        -- until the user opens a chapter. This makes a later bookshelf entry
        -- local-first and gives the chapter menu the same explicit refresh
        -- action as the in-reader directory.
        local current_index = self.storage:get_last_chapter(display_book)
        local cache_index = current_index or 1
        local saved = self.storage:save_reader_session(
            display_book, source, result.chapters, cache_index, true
        )
        local reader_session
        if saved then
            reader_session = self.storage:load_reader_session()
        end
        if type(reader_session) ~= "table" then
            -- Keep the current menu usable even if the local settings file is
            -- temporarily read-only or the device is nearly full. Selecting
            -- a chapter will retry the normal persistent session write.
            reader_session = {
                book = display_book,
                chapters = result.chapters,
                current_index = cache_index,
                source_url = source.bookSourceUrl or "",
                source_name = source.bookSourceName or "",
            }
        end
        self._reader_session_cache = reader_session
        self._reader_session_cache_file = nil
        self:showChapterMenu(source, display_book, result.chapters, {
            current_index = current_index,
            reader_session = reader_session,
        })
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
        if not content then return nil, err or _("Chapter download failed.") end
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
            tostring(index), tostring(total), tostring(error_message or _("Unknown error."))
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
                    title = chapter.name or T(_("Chapter %1"), index),
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
            if not content then return nil, err or _("Chapter download failed.") end
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
                title = chapter.name or T(_("Chapter %1"), index),
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
                if not result then return nil, err or _("Backup import failed.") end
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
            _("Schema: %s\nSources: %s\nBooks: %s\nDynamic categories: All, Reading, Unread, Read\nRead records: %s\nMembers: %s%s"),
            tostring(state.schema_version or _("Unknown")),
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
