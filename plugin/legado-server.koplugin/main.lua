local DataStorage = require("datastorage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MenuPage = require("legado_server/menu_page")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local Background = require("legado_server/background")
local Store = require("legado_server/store")
local Client = require("legado_server/client")
local Discovery = require("legado_server/discovery")
local Reader = require("legado_server/reader")
local logger = require("logger")
local json = require("rapidjson")
local time = require("ui/time")
local T = require("ffi/util").template
local _ = require("gettext")

local Plugin = InputContainer:extend{ name = "legado_server", is_doc_only = false }
local AUTO_RETRY_INTERVAL = 30
-- KOReader recreates the plugin when switching between the reader and file
-- manager. Keep one schedule and one worker for the entire KOReader process.
local automatic_tasks = {
    sync = { interval = 5 * 60, setting = "auto_sync" },
    inbox = { interval = 15 * 60, setting = "auto_inbox" },
}
local active_plugin
local worker_running = false

local function cancel_automatic(task)
    if task.callback then
        UIManager:unschedule(task.callback)
        task.callback = nil
    end
end

local function finish_automatic(kind, result)
    local task = automatic_tasks[kind]
    local delay = task.interval
    if result.ok then
        task.retry_delay, task.retry_at = nil, nil
    else
        delay = math.min(task.interval, (task.retry_delay or AUTO_RETRY_INTERVAL / 2) * 2)
        task.retry_delay = delay
        task.retry_at = time.now() + time.s(delay)
        logger.warn("Legado server background", kind, "failed:", tostring(result.code or "unknown"),
            tostring(result.message or ""), "retry in", delay, "seconds")
    end
    if active_plugin then active_plugin:scheduleAutomatic(kind, delay) end
end

local function local_device_name()
    local loaded, Device = pcall(require, "device")
    if loaded and Device and type(Device.getModel) == "function" then
        local called, model = pcall(Device.getModel, Device)
        if called and type(model) == "string" and model ~= "" then
            return ("Kindle " .. model):sub(1, 100)
        end
    end
    return "Kindle"
end

local function display_sync_time(value)
    if type(value) ~= "string" or value == "" then return _("Never") end
    return value:gsub("T", " "):gsub("Z$", "")
end

local function display_percent(value)
    return math.max(0, math.min(100, math.floor((tonumber(value) or 0) * 100 + 0.5)))
end

function Plugin:info(text)
    UIManager:show(InfoMessage:new{ text = tostring(text) })
end

function Plugin:error_text(value)
    if type(value) ~= "table" then return tostring(value or _("Unknown server operation error.")) end
    local code = value.code
    if code == "network_error" then return _("Cannot connect to the Legado server.") end
    if code == "not_paired" then return _("Pair this Kindle with the server first.") end
    if code == "server_identity_mismatch" then return _("The discovered server identity does not match this Kindle pairing.") end
    if code == "invalid_pairing" then return _("The server returned invalid pairing data.") end
    if code == "foreign_server" then return _("The server response points to an unpaired address.") end
    if code == "invalid_json" then return _("The server returned invalid data.") end
    if code == "local_write_failed" then return _("Cannot save local Kindle data.") end
    if code == "local_state_invalid" then return _("The local Kindle data is invalid.") end
    if code == "invalid_sync" then return _("The server returned incomplete published-book data.") end
    if code == "bundle_failed" then return _("A published-book package could not be installed.") end
    if code == "epub_failed" then return _("A published-book EPUB could not be installed.") end
    if code == "snapshot_failed" then return _("The published bookshelf could not be updated.") end
    if code == "client_error" then return _("The server operation failed.") end
    if code == "http_error" then return _("The server returned an HTTP error.") end
    return tostring(value.message or _("Unknown server operation error."))
end

function Plugin:init()
    local root = DataStorage:getDataDir() .. "/legado-server"
    if root:sub(1, 1) ~= "/" then
        root = require("libs/libkoreader-lfs").currentdir() .. "/" .. root:gsub("^%./", "")
    end
    local ok, value = pcall(Store.new, { root = root })
    if ok then
        self.store = value
        local settings, err = self.store:settings()
        self.settings, self.storage_error = settings or {}, err
        self.reader = Reader.new{
            store = self.store, ui = self.ui, device_id = self.settings.device_id,
            on_toc = function(book_id) self:showChapters(book_id) end,
            on_error = function(message) self:info(message) end,
            on_progress = function() self:invalidateMainMenuSummary() end,
        }
    else
        self.storage_error = tostring(value)
    end
    active_plugin = self
    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if not automatic_tasks.sync.callback then self:scheduleAutomatic("sync", 5) end
    if not automatic_tasks.inbox.callback then self:scheduleAutomatic("inbox", 5) end
end

function Plugin:addToMainMenu(items)
    items.legado_server = {
        text = _("Legado server"),
        sorting_hint = "tools",
        sub_item_table = self:getMainMenuItems(),
    }
end

-- Keep the top-level menu focused on content and routine actions. Technical
-- diagnostics live in Sync Center, while pairing commands are only shown by
-- the dynamic Server menu.
function Plugin:getMainMenuItems()
    local function action(callback)
        return { callback = callback }
    end
    local library = action(function() self:showBooks() end)
    library.text = _("My Books")
    library.text_func = function()
        return T(_("My Books · %1"), self:libraryMenuSubtitle())
    end
    local pushed = action(function() self:showPushedBooks() end)
    pushed.text = _("Pushed Books")
    pushed.text_func = function()
        return T(_("Pushed Books · %1"), self:pushedMenuSubtitle())
    end
    local sync_now = {
        text = _("Sync Now"),
        callback = function() self:sync(false) end,
        text_func = function() return T(_("Sync Now · %1"), self:syncMenuSubtitle()) end,
    }
    local sync_center = action(function() self:showSyncCenter() end)
    sync_center.text = _("Sync Center")
    sync_center.text_func = function()
        return T(_("Sync Center · %1"), self:syncCenterMenuSubtitle())
    end
    local server = action(function() self:showServer() end)
    server.text = _("Server")
    server.text_func = function() return T(_("Server · %1"), self:serverMenuSubtitle()) end
    return { library, pushed, sync_now, sync_center, server }
end

function Plugin:invalidateMainMenuSummary()
    self.main_menu_summary = nil
end

function Plugin:mainMenuSummary()
    if self.main_menu_summary then return self.main_menu_summary end
    if not self.store then return { unavailable = true } end
    local active = self.reader and self.reader:session()
    local dashboard, err = self.store:dashboard(active and active.book_id or nil)
    if not dashboard then
        logger.warn("Legado server menu summary failed:", tostring(err))
        return { unavailable = true }
    end
    local summary = {
        library = T(_("Count: %1"), dashboard.book_count),
        pushed = T(_("Count: %1"), dashboard.inbox_count),
        server = dashboard.paired and (dashboard.server_name or _("Paired")) or _("Not paired"),
    }
    if active and dashboard.active_book then
        local progress = self.reader:reading_progress(
            dashboard.active_book, active, dashboard.progress_snapshot)
        if progress then
            summary.library = T(_("%1 books · %2%"), dashboard.book_count,
                display_percent(progress.percent))
        end
    end
    local pending = dashboard.pending_progress > 0
        and T(_("%1 pending"), dashboard.pending_progress) or nil
    local conflicts = dashboard.conflict_count > 0
        and T(_("%1 conflicts"), dashboard.conflict_count) or nil
    local retry = dashboard.last_sync_error and _("Retry needed") or nil
    summary.sync = pending or conflicts or retry or display_sync_time(dashboard.last_sync_at)
    summary.sync_center = conflicts or pending or retry or _("Up to date")
    self.main_menu_summary = summary
    return summary
end

function Plugin:libraryMenuSubtitle()
    local summary = self:mainMenuSummary()
    return summary.unavailable and _("Unavailable") or summary.library
end

function Plugin:pushedMenuSubtitle()
    local summary = self:mainMenuSummary()
    return summary.unavailable and _("Unavailable") or summary.pushed
end

function Plugin:syncMenuSubtitle()
    local summary = self:mainMenuSummary()
    return summary.unavailable and _("Unavailable") or summary.sync
end

function Plugin:syncCenterMenuSubtitle()
    local summary = self:mainMenuSummary()
    return summary.unavailable and _("Unavailable") or summary.sync_center
end

function Plugin:serverMenuSubtitle()
    local summary = self:mainMenuSummary()
    return summary.unavailable and _("Unavailable") or summary.server
end

function Plugin:client()
    if not self.store or self.storage_error then return nil, self.storage_error or _("Local storage is unavailable.") end
    local settings, err = self.store:settings()
    if not settings then return nil, err end
    if not settings.server_url or not settings.device_token then return nil, _("Pair this Kindle with the server first.") end
    return Client.new{
        server_url = settings.server_url,
        server_id = settings.server_id,
        server_name = settings.server_name,
        discovery_port = settings.discovery_port,
        device_id = settings.device_id,
        device_token = settings.device_token,
        store = self.store,
    }
end

function Plugin:withServerClient(operation)
    if not self.store or self.storage_error then return nil, self.storage_error or _("Local storage is unavailable.") end
    local settings, settings_err = self.store:settings()
    if not settings then return nil, settings_err end
    if not settings.server_url or not settings.device_token then return nil, _("Pair this Kindle with the server first.") end
    local function client_for(current)
        return Client.new{
            server_url = current.server_url,
            server_id = current.server_id,
            server_name = current.server_name,
            discovery_port = current.discovery_port,
            device_id = current.device_id,
            device_token = current.device_token,
            store = self.store,
        }
    end
    local result, err = operation(client_for(settings))
    if result or type(err) ~= "table" or err.code ~= "network_error" or not settings.server_id then
        return result, err
    end

    local server = Discovery.find_server(settings.server_id, {
        timeout = 1.5,
        port = settings.discovery_port,
    })
    if not server or server.server_url == settings.server_url then return result, err end
    local saved, save_err = self.store:update_settings(function(current)
        current.server_url = server.server_url
        current.server_name = server.server_name
        current.discovery_port = server.discovery_port
    end)
    if not saved then return nil, { code = "local_write_failed", message = save_err, retryable = true } end
    return operation(client_for(saved))
end

function Plugin:run(message, task, finished, automatic_kind)
    local function run_task()
        local called, result, err = pcall(task)
        if called and result then return { ok = true, result = result } end
        return {
            ok = false,
            code = type(err) == "table" and err.code or nil,
            message = type(err) == "table" and err.message or tostring(err or result),
        }
    end
    local function finish(result)
        worker_running = false
        if active_plugin then active_plugin:invalidateMainMenuSummary() end
        for kind, scheduled in pairs(automatic_tasks) do
            if scheduled.waiting then
                scheduled.waiting = nil
                if active_plugin then active_plugin:scheduleAutomatic(kind, 1) end
            end
        end
        if automatic_kind then
            finish_automatic(automatic_kind, result)
        elseif result and active_plugin == self then
            if not result.ok then
                self:info(self:error_text(result))
            elseif finished then
                finished(result.result)
            end
        end
    end
    local function execute()
        if self ~= active_plugin or self.suspended then return end
        if worker_running then
            if not automatic_kind then self:info(_("A server operation is already running.")) end
            return
        end
        worker_running = true
        if self.reader then
            local saved, err = self.reader:close(automatic_kind ~= nil)
            if automatic_kind and saved == nil then
                logger.warn("Legado server could not save local reading progress:", tostring(err))
            end
        end
        if automatic_kind then
            Background.run(run_task, finish)
            return
        end
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local completed, payload = Trapper:dismissableRunInSubprocess(function()
                return json.encode(run_task())
            end, message, true)
            if not completed then
                finish(nil)
                return
            end
            local decoded, result = pcall(json.decode, payload or "")
            if not decoded or type(result) ~= "table" then
                result = { ok = false, message = _("Server operation returned no result.") }
            end
            finish(result)
        end)
    end
    if worker_running then
        if not automatic_kind then self:info(_("A server operation is already running.")) end
        return false
    end
    if automatic_kind then
        execute()
    else
        NetworkMgr:runWhenConnected(execute)
    end
    return true
end

function Plugin:autoInboxEnabled()
    return self.settings ~= nil and self.settings.auto_inbox ~= false
end

function Plugin:setAutoInbox(enabled)
    if not self.store then self:info(self.storage_error); return end
    local saved, err = self.store:update_settings(function(settings)
        settings.auto_inbox = enabled == true
    end)
    if not saved then self:info(err); return end
    self.settings = saved
    self:invalidateMainMenuSummary()
    if enabled then
        self:scheduleAutomatic("inbox", 1)
    else
        cancel_automatic(automatic_tasks.inbox)
    end
end

function Plugin:autoSyncEnabled()
    return self.settings ~= nil and self.settings.auto_sync ~= false
end

function Plugin:setAutoSync(enabled)
    if not self.store then self:info(self.storage_error); return end
    local saved, err = self.store:update_settings(function(settings)
        settings.auto_sync = enabled == true
    end)
    if not saved then self:info(err); return end
    self.settings = saved
    self:invalidateMainMenuSummary()
    if enabled then
        self:scheduleAutomatic("sync", 1)
    else
        cancel_automatic(automatic_tasks.sync)
    end
end

function Plugin:isNetworkReady()
    local called, value = pcall(NetworkMgr.isConnected, NetworkMgr)
    if called and value == true then return true end

    -- KOReader can miss the initial connectivity event when Wi-Fi was already
    -- connected before KOReader launched. Fall back to the kernel's live
    -- interface and routing state without asking NetworkMgr to enable Wi-Fi.
    local interface = "wlan0"
    local name_called, value_name = pcall(NetworkMgr.getNetworkInterfaceName, NetworkMgr)
    if name_called and type(value_name) == "string" and value_name ~= "" then
        interface = value_name
    end
    local state_file = io.open("/sys/class/net/" .. interface .. "/operstate", "r")
    if not state_file then return false end
    local state = (state_file:read("*l") or ""):gsub("%s+$", "")
    state_file:close()
    if state ~= "up" then return false end
    local routes = io.open("/proc/net/route", "r")
    if not routes then return false end
    for line in routes:lines() do
        local route_interface, destination, gateway, flags = line:match(
            "^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if route_interface == interface and destination == "00000000"
                and tonumber(flags, 16) and bit.band(tonumber(flags, 16), 1) ~= 0 then
            routes:close()
            return true
        end
    end
    routes:close()
    return false
end

function Plugin:canScheduleAutomatic(kind)
    return self == active_plugin and not self.suspended and not self.storage_error
        and self.settings and self.settings.server_url and self.settings.device_token
        and self.settings[automatic_tasks[kind].setting] ~= false
        and (kind ~= "inbox" or not self.ui.document)
end

function Plugin:scheduleAutomatic(kind, delay)
    if not self:canScheduleAutomatic(kind) then return end
    local task = automatic_tasks[kind]
    local when = time.now() + time.s(delay)
    if task.retry_at and when < task.retry_at then when = task.retry_at end
    if task.callback and task.when <= when then return end
    cancel_automatic(task)
    -- unschedule() takes the original callback, not schedule()'s return value.
    task.when = when
    task.callback = function()
        task.callback = nil
        if active_plugin then active_plugin:runAutomatic(kind) end
    end
    UIManager:schedule(when, task.callback)
end

function Plugin:runAutomatic(kind)
    if not self:canScheduleAutomatic(kind) then return end
    local retry_at = automatic_tasks[kind].retry_at
    if retry_at and time.now() < retry_at then
        self:scheduleAutomatic(kind, 0)
        return
    end
    if worker_running then
        automatic_tasks[kind].waiting = true
        return
    end
    if not self:isNetworkReady() then
        self:scheduleAutomatic(kind, AUTO_RETRY_INTERVAL)
        return
    end
    if kind == "sync" then self:sync(true) else self:pullInbox(true) end
end

function Plugin:pullInbox(automatic)
    self:run(
        automatic and _("Checking Kindle inbox…") or _("Pulling pushed books…"),
        function()
            return self:withServerClient(function(client) return client:pull_inbox() end)
        end,
        function(result)
            if result.failed > 0 then
                self:info(T(_("Pushed books: %1 downloaded, %2 will retry."), result.downloaded, result.failed))
            else
                self:info(T(_("Pushed books received: %1"), result.downloaded))
            end
        end,
        automatic and "inbox" or nil
    )
end

function Plugin:sync(automatic)
    self:run(_("Syncing bookshelf and reading progress…"), function()
        local synced, sync_err = self:withServerClient(function(client) return client:sync_all() end)
        if not synced then
            if self.store then
                self.store:record_sync_result(type(sync_err) == "table" and sync_err.message or tostring(sync_err), nil)
            end
            return nil, sync_err
        end
        local saved, save_err = self.store:record_sync_result(nil, synced.conflicts)
        if not saved then
            return nil, { code = "local_write_failed", message = save_err, retryable = true }
        end
        return synced
    end, function(result)
        if result.conflict_count > 0 then
            self:info(T(_("Sync complete. %1 progress events sent; %2 conflicts need attention."),
                result.progress_sent, result.conflict_count))
        else
            self:info(T(_("Sync complete. %1 progress events sent."), result.progress_sent))
        end
    end, automatic and "sync" or nil)
end

function Plugin:sendProgress()
    self:run(_("Sending reading progress…"), function()
        return self:withServerClient(function(client)
            local result, err = client:flush_progress()
            if not result then return nil, err end
            local conflicts, conflict_err = client:conflicts()
            if not conflicts then return nil, conflict_err end
            local saved, save_err = self.store:record_conflicts(conflicts)
            if not saved then return nil, { code = "local_write_failed", message = save_err, retryable = true } end
            result.conflict_count = #conflicts
            return result
        end)
    end,
        function(result)
            self:invalidateMainMenuSummary()
            if result.conflict_count > 0 then
                self:info(T(_("Reading progress acknowledged: %1; %2 conflicts need attention."),
                    result.sent, result.conflict_count))
            else
                self:info(T(_("Reading progress acknowledged: %1"), result.sent))
            end
        end)
end

function Plugin:showSyncStatus()
    if not self.store then self:info(self.storage_error); return end
    local status, err = self.store:sync_status()
    if not status then self:info(err); return end
    local text = T(_("Last sync: %1\nPending progress: %2\nUnresolved conflicts: %3"),
        display_sync_time(status.last_sync_at), status.pending_progress, status.conflict_count)
    if status.last_sync_error then
        text = text .. "\n" .. T(_("Last error: %1"), status.last_sync_error)
    end
    self:info(text)
end

function Plugin:showSyncCenter()
    if not self.store then self:info(self.storage_error); return end
    local status = self.store:sync_status()
    if not status then self:info(_("Cannot load synchronization status.")); return end
    local menu
    local items = {
        {
            text = _("Sync status"),
            mandatory = display_sync_time(status.last_sync_at),
            callback = function() self:showSyncStatus() end,
        },
        {
            text = _("Send reading progress"),
            mandatory = status.pending_progress > 0
                and T(_("%1 pending"), status.pending_progress) or _("Up to date"),
            callback = function()
                UIManager:close(menu)
                self:sendProgress()
            end,
        },
        {
            text = _("Reading progress conflicts"),
            mandatory = status.conflict_count > 0
                and T(_("%1 conflicts"), status.conflict_count) or _("None"),
            callback = function()
                UIManager:close(menu)
                self:showConflicts()
            end,
        },
        {
            text = T(_("Automatic synchronization: %1"),
                self:autoSyncEnabled() and _("On") or _("Off")),
            callback = function()
                UIManager:close(menu)
                self:setAutoSync(not self:autoSyncEnabled())
                self:showSyncCenter()
            end,
        },
        {
            text = T(_("Receive pushed books automatically: %1"),
                self:autoInboxEnabled() and _("On") or _("Off")),
            callback = function()
                UIManager:close(menu)
                self:setAutoInbox(not self:autoInboxEnabled())
                self:showSyncCenter()
            end,
        },
    }
    menu = MenuPage:new{
        title = _("Sync Center"),
        item_table = items,
        items_per_page = 8,
    }
    UIManager:show(menu)
    return menu
end

function Plugin:showServerDetails()
    if not self.store then self:info(self.storage_error); return end
    local settings = self.store:settings()
    if not settings then self:info(_("Cannot load server pairing information.")); return end
    if not settings.server_url or not settings.device_token then
        self:info(_("This Kindle is not paired with a server."))
        return
    end
    self:info(T(_("Server: %1\nAddress: %2\nAutomatic synchronization: %3\nAutomatic push delivery: %4"),
        settings.server_name or _("Legado server"),
        settings.server_url,
        self:autoSyncEnabled() and _("On") or _("Off"),
        self:autoInboxEnabled() and _("On") or _("Off")))
end

function Plugin:showServer()
    if not self.store then self:info(self.storage_error); return end
    local settings = self.store:settings()
    if not settings then self:info(_("Cannot load server pairing information.")); return end
    local paired = settings.server_url ~= nil and settings.device_token ~= nil
    local menu
    local items
    if paired then
        items = {
            {
                text = (settings.server_name or _("Paired server")) .. "\n" .. settings.server_url,
                mandatory = _("Paired"),
                callback = function() self:showServerDetails() end,
            },
            {
                text = _("Forget server pairing"),
                callback = function() self:forgetServer(menu) end,
            },
        }
    else
        items = {
            {
                text = _("Not paired"),
                mandatory = _("Pairing required"),
            },
            {
                text = _("Find server on LAN"),
                callback = function()
                    UIManager:close(menu)
                    self:findServer()
                end,
            },
            {
                text = _("Pair manually"),
                callback = function()
                    UIManager:close(menu)
                    self:showPairing()
                end,
            },
        }
    end
    menu = MenuPage:new{
        title = _("Server"),
        item_table = items,
        items_per_page = 8,
        items_max_lines = 3,
    }
    UIManager:show(menu)
    return menu
end

local function conflict_position_text(position)
    if type(position) ~= "table" then return _("no saved position") end
    local percent = math.max(0, math.min(100, math.floor((tonumber(position.chapter_progress) or 0) * 100 + 0.5)))
    return T(_("chapter %1, %2%"), (tonumber(position.chapter_index) or 0) + 1, percent)
end

function Plugin:renderConflicts(conflicts)
    if type(conflicts) ~= "table" or #conflicts == 0 then
        self:info(_("There are no unresolved reading progress conflicts."))
        return
    end
    local items = {}
    for conflict_index, conflict in ipairs(conflicts) do
        items[#items + 1] = {
            text = tostring(conflict.title or conflict.book_id) .. " · " .. T(_("Server: %1 · Kindle: %2"),
                conflict_position_text(conflict.current), conflict_position_text(conflict.candidate)),
            conflict = conflict,
        }
    end
    local menu = MenuPage:new{
        title = _("Reading progress conflicts"),
        item_table = items,
        items_max_lines = 3,
        onMenuSelect = function(instance, item)
            UIManager:close(instance)
            local conflict = item.conflict
            UIManager:show(ConfirmBox:new{
                text = T(_("Choose the reading position to keep.\n\nServer: %1\nKindle: %2"),
                    conflict_position_text(conflict.current), conflict_position_text(conflict.candidate)),
                cancel_text = _("Keep server"),
                ok_text = _("Use Kindle"),
                cancel_callback = function() self:resolveConflict(conflict, "server") end,
                ok_callback = function() self:resolveConflict(conflict, "kindle") end,
            })
        end,
    }
    UIManager:show(menu)
    return menu
end

function Plugin:showConflicts()
    if not self.store then self:info(self.storage_error); return end
    self:run(_("Refreshing reading progress conflicts…"), function()
        return self:withServerClient(function(client)
            local conflicts, err = client:conflicts()
            if not conflicts then return nil, err end
            local saved, save_err = self.store:record_conflicts(conflicts)
            if not saved then return nil, { code = "local_write_failed", message = save_err, retryable = true } end
            return conflicts
        end)
    end, function(conflicts)
        self:invalidateMainMenuSummary()
        self:renderConflicts(conflicts)
    end)
end

function Plugin:resolveConflict(conflict, resolution)
    self:run(_("Resolving reading progress conflict…"), function()
        return self:withServerClient(function(client)
            local resolved, resolve_err = client:resolve_conflict(conflict.conflict_id, resolution)
            if not resolved then return nil, resolve_err end
            if resolution == "kindle" and type(resolved.progress) == "table" then
                local confirmed, confirm_err = self.store:confirm_resolved_progress(
                    conflict.book_id, resolved.progress, conflict.binding_version)
                if not confirmed then
                    return nil, { code = "local_write_failed", message = confirm_err, retryable = true }
                end
            end
            local synced, sync_err = client:sync()
            if not synced then return nil, sync_err end
            local conflicts, conflict_err = client:conflicts()
            if not conflicts then return nil, conflict_err end
            local saved, save_err = self.store:record_conflicts(conflicts)
            if not saved then return nil, { code = "local_write_failed", message = save_err, retryable = true } end
            return { conflicts = conflicts, resolution = resolution }
        end)
    end, function(result)
        self:invalidateMainMenuSummary()
        self:info(_("Reading progress conflict resolved."))
        if #result.conflicts > 0 then self:renderConflicts(result.conflicts) end
    end)
end

function Plugin:showBooks()
    if not self.store then self:info(self.storage_error); return end
    local books, err = self.store:book_summaries()
    if not books then self:info(err); return end
    if #books == 0 then self:info(_("No published books are stored. Publish from the WebUI and sync this Kindle.")); return end
    local active = self.reader and self.reader:session()
    local active_book_id = active and active.book_id or nil
    local progress_snapshot = self.store:progress_snapshot() or false
    local synced_groups = self.store:shelf_reading_groups()
    local items_by_group = { all = {}, read = {}, unread = {}, reading = {} }
    for book_index, book in ipairs(books) do
        local progress = self.reader and self.reader:reading_progress(
            book, active_book_id == book.book_id and active or false, progress_snapshot)
        local progress_text = progress
            and T(_("%1/%2 · %3%"), progress.lua_position, progress.total_chapters,
                display_percent(progress.percent)) or _("No chapters")
        local author = type(book.author) == "string" and book.author ~= "" and book.author or nil
        local item = {
            text = author and (book.title .. "\n" .. author) or book.title,
            mandatory = progress_text,
            book_id = book.book_id,
            bold = active_book_id == book.book_id,
        }
        items_by_group.all[#items_by_group.all + 1] = item
        local groups = synced_groups and synced_groups[book.book_id]
        if not synced_groups then
            -- Offline shelves and older servers only provide the published TOC and position.
            local index = progress and progress.chapter_index or 0
            local total = book.chapter_count
            groups = {
                unread = index == 0 and (not progress or progress.chapter_progress == 0),
                reading = total > 0 and index > 0 and index < total - 1,
                read = total > 0 and index >= total - 1,
            }
        end
        if type(groups) == "table" then
            if groups.read then items_by_group.read[#items_by_group.read + 1] = item end
            if groups.unread then items_by_group.unread[#items_by_group.unread + 1] = item end
            if groups.reading then items_by_group.reading[#items_by_group.reading + 1] = item end
        end
    end
    local Bookshelf = require("legado_server/bookshelf")
    local menu = Bookshelf:new{
        items_by_group = items_by_group,
        onMenuSelect = function(instance, item)
            UIManager:close(instance)
            self:openBook(item.book_id)
        end,
        onMenuHold = function(instance, item)
            self:showChapters(item.book_id, instance)
            return true
        end,
    }
    UIManager:show(menu)
    return menu
end

function Plugin:openBook(book_id)
    local opened, open_err = self.reader:open(book_id, nil, { resume = true })
    if not opened then self:info(open_err) end
end

function Plugin:openPushed(path)
    if not self.store or not path or not self.store.fs:exists(path) then
        self:info(_("The pushed EPUB is not available locally."))
        return
    end
    if self.reader then self.reader:close() end
    if self.ui.document and type(self.ui.switchDocument) == "function" then
        self.ui:switchDocument(path, true)
    elseif type(self.ui.showReader) == "function" then
        self.ui:showReader(path, nil, true)
    elseif type(self.ui.openFile) == "function" then
        self.ui:openFile(path)
    else
        self:info(_("Cannot open the pushed EPUB."))
    end
end

function Plugin:showPushedBooks()
    if not self.store then self:info(self.storage_error); return end
    local books, err = self.store:inbox_books()
    if not books then self:info(err); return end
    local items = {
        {
            text = _("Check for new pushes"),
            mandatory = T(_("Count: %1"), #books),
            action = "pull",
        },
    }
    for book_index, book in ipairs(books) do
        local files = book.files or {}
        local multiple_files = #files > 1
        local author = type(book.author) == "string" and book.author ~= "" and book.author or nil
        for file_index, file in ipairs(files) do
            -- KOReader subtracts the full width of the right-hand label from the title column.
            local label = multiple_files and type(file.file_name) == "string" and file.file_name or book.title
            items[#items + 1] = {
                text = author and (label .. " · " .. author) or label,
                mandatory = multiple_files and T("%1/%2", file_index, #files) or nil,
                path = file.path,
            }
        end
    end
    if #books == 0 then
        items[#items + 1] = {
            text = _("No pushed books have been received."),
            dim = true,
        }
    end
    local menu = MenuPage:new{
        title = T(_("Pushed Books · %1"), #books),
        item_table = items,
        items_per_page = 12,
        items_max_lines = 3,
        onMenuSelect = function(instance, item)
            if item.action == "pull" then
                UIManager:close(instance)
                self:pullInbox(false)
            elseif item.path then
                UIManager:close(instance)
                self:openPushed(item.path)
            end
        end,
    }
    UIManager:show(menu)
    return menu
end

function Plugin:showChapters(book_id, parent_menu)
    local book, err = self.store:book(book_id)
    if not book then self:info(err); return end
    if #book.chapters == 0 then self:info(_("No chapters have been published yet.")); return end
    local current = self.reader:current_position(book)
    local items = {}
    for lua_position, chapter in ipairs(book.chapters) do
        local availability = chapter.status == "ready" and _("Offline") or _("Pending download")
        items[#items + 1] = {
            text = chapter.title,
            mandatory = current == lua_position
                and T(_("Current · %1"), availability) or availability,
            lua_position = lua_position, bold = current == lua_position,
        }
    end
    items.current = current
    local menu = MenuPage:new{
        title = book.title .. "\n" .. _("Table of Contents"),
        item_table = items,
        items_per_page = 12,
        onMenuSelect = function(instance, item)
            UIManager:close(instance)
            if parent_menu then UIManager:close(parent_menu) end
            local opened, open_err = self.reader:open(book_id, item.lua_position, { resume = item.lua_position == current })
            if not opened then self:info(open_err) end
        end,
    }
    UIManager:show(menu)
    return menu
end

function Plugin:prompt(title, input, hint, submitted, password)
    local dialog
    dialog = InputDialog:new{
        title = title, input = input or "", input_hint = hint, text_type = password and "password" or nil,
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local value = dialog:getInputText(); UIManager:close(dialog); submitted(value)
            end },
        } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:pairDiscovered(server)
    self:prompt(_("Pairing code from WebUI"), "", nil, function(code)
        local valid, candidate = pcall(Client.new, {
            server_url = server.server_url,
            server_id = server.server_id,
            server_name = server.server_name,
            discovery_port = server.discovery_port,
            store = self.store,
        })
        if not valid then self:info(_("The discovered server address is invalid.")); return end
        self:run(_("Pairing Kindle…"), function()
            return candidate:pair(code, local_device_name())
        end, function()
            self.settings = self.store:settings() or {}
            self.reader.device_id = self.settings.device_id
            self:invalidateMainMenuSummary()
            self:info(T(_("Kindle paired with %1."), server.server_name))
            self:scheduleAutomatic("sync", 1)
            self:scheduleAutomatic("inbox", 1)
        end)
    end, true)
end

function Plugin:showDiscoveredServers(servers)
    if type(servers) ~= "table" or #servers == 0 then
        self:info(_("No Legado server was found on this LAN. Check that both devices are on the same Wi-Fi and that discovery is enabled."))
        return
    end
    local items = {}
    for server_index, server in ipairs(servers) do
        items[#items + 1] = {
            text = server.server_name .. " · " .. server.server_url,
            server = server,
        }
    end
    local menu = MenuPage:new{
        title = _("Legado servers on this LAN"),
        item_table = items,
        items_max_lines = 3,
        onMenuSelect = function(instance, item)
            UIManager:close(instance)
            self:pairDiscovered(item.server)
        end,
    }
    UIManager:show(menu)
    return menu
end

function Plugin:findServer()
    if not self.store then self:info(self.storage_error); return end
    local settings = self.store:settings() or {}
    if settings.device_id then
        self:info(_("This Kindle is already paired. The plugin will rediscover the same server automatically when its LAN address changes."))
        return
    end
    self:run(_("Looking for Legado server…"), function()
        return Discovery.scan{ timeout = 2.5 }
    end, function(servers)
        self:showDiscoveredServers(servers)
    end)
end

function Plugin:forgetServer(parent_menu)
    if worker_running then self:info(_("Wait for the current server operation to finish.")); return end
    if not self.store then self:info(self.storage_error); return end
    local settings = self.store:settings() or {}
    if not settings.device_token and not settings.device_id and not settings.server_id then
        self:info(_("This Kindle is not paired with a server."))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Forget the server pairing? Downloaded books and reading state will be kept on this Kindle."),
        ok_text = _("Forget"),
        ok_callback = function()
            if worker_running then self:info(_("Wait for the current server operation to finish.")); return end
            local cleared, clear_err = self.store:forget_server_pairing()
            if not cleared then self:info(clear_err); return end
            settings.server_url = nil
            settings.server_id = nil
            settings.server_name = nil
            settings.device_id = nil
            settings.device_token = nil
            local saved, save_err = self.store:save_settings(settings)
            if not saved then self:info(save_err); return end
            self.settings = settings
            for kind, task in pairs(automatic_tasks) do
                cancel_automatic(task)
                task.retry_at, task.retry_delay = nil, nil
            end
            if self.reader then self.reader.device_id = nil end
            self:invalidateMainMenuSummary()
            if parent_menu then UIManager:close(parent_menu) end
            self:info(_("Server pairing removed from this Kindle."))
            if parent_menu then self:showServer() end
        end,
    })
end

function Plugin:showPairing()
    if not self.store then self:info(self.storage_error); return end
    local settings = self.store:settings() or {}
    if settings.device_id then
        self:info(_("This local library is already paired. Reuse its existing server device token; a new pairing requires a separate local library."))
        return
    end
    self:prompt(_("Server URL"), settings.server_url, "https://reader.example.com", function(url)
        local valid, candidate = pcall(Client.new, {
            server_url = url,
            server_name = "Legado server",
            discovery_port = settings.discovery_port or 47832,
            store = self.store,
        })
        if not valid then self:info(_("Enter a complete HTTP or HTTPS server URL.")); return end
        self:prompt(_("Pairing code from WebUI"), "", nil, function(code)
            self:run(_("Pairing Kindle…"), function() return candidate:pair(code, local_device_name()) end, function()
                self.settings = self.store:settings() or {}
                self.reader.device_id = self.settings.device_id
                self:invalidateMainMenuSummary()
                self:info(_("Kindle paired. Sync published books to begin."))
                self:scheduleAutomatic("sync", 1)
                self:scheduleAutomatic("inbox", 1)
            end)
        end, true)
    end)
end

function Plugin:onReaderReady() if self.reader then self.reader:ready() end end
function Plugin:onPageUpdate()
    if self.reader then self.reader:page_changed() end
end
function Plugin:onPosUpdate()
    if self.reader then self.reader:page_changed() end
end
function Plugin:onSaveSettings() if self.reader and not worker_running then self.reader:capture() end end
function Plugin:onCloseDocument()
    if self.reader and self.reader:session() then
        self.reader:close()
        self:scheduleAutomatic("sync", 1)
    end
end
function Plugin:onCloseWidget()
    if self.reader then self.reader:cancel_capture() end
    if self == active_plugin then active_plugin = nil end
end
function Plugin:onSuspend()
    self.suspended = true
    if self == active_plugin then
        cancel_automatic(automatic_tasks.sync)
        cancel_automatic(automatic_tasks.inbox)
    end
    if self.reader then self.reader:close() end
end
function Plugin:onResume()
    self.suspended = false
    self:scheduleAutomatic("sync", 2)
    self:scheduleAutomatic("inbox", 2)
end
function Plugin:onNetworkConnected()
    if self ~= active_plugin then return end
    for kind, task in pairs(automatic_tasks) do
        task.retry_at, task.retry_delay = nil, nil
        self:scheduleAutomatic(kind, 2)
    end
end

return Plugin
