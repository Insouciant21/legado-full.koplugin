-- Small, local-only mailbox used to pass KOReader gestures to the Kindle
-- Chromium worker.  The worker and the UI live in different Trapper
-- processes, so neither Lua state nor callbacks can be shared directly.
--
-- Events are published by writing a complete temporary file and atomically
-- renaming it into the session directory.  This avoids a reader seeing a
-- half-written line when a touch arrives while the browser worker is polling.

local lfs = require("libs/libkoreader-lfs")

local BrowserInput = {}

local QUEUE_DIR = "/var/tmp/legado-browser-input"
local ACTIVE_PATH = QUEUE_DIR .. ".active"
local sequence = 0

local function valid_token(value)
    value = tostring(value or "")
    if value:match("^[%d%-]+$") then
        return value
    end
end

local function ensure_queue_dir()
    if lfs.attributes(QUEUE_DIR, "mode") == "directory" then
        return true
    end
    local ok = pcall(function()
        lfs.mkdir(QUEUE_DIR)
    end)
    return ok and lfs.attributes(QUEUE_DIR, "mode") == "directory"
end

local function active_token()
    local file = io.open(ACTIVE_PATH, "rb")
    if not file then return nil end
    local token = valid_token(file:read("*l") or "")
    file:close()
    return token
end

local function event_prefix(token)
    return "^" .. token:gsub("%-", "%%-") .. "%-"
end

local function for_each_event_file(token, callback)
    if not token or lfs.attributes(QUEUE_DIR, "mode") ~= "directory" then
        return
    end
    local prefix = event_prefix(token)
    for name in lfs.dir(QUEUE_DIR) do
        if name:match(prefix .. "%d+%.event$") then
            callback(QUEUE_DIR .. "/" .. name)
        end
    end
end

local function clear_event_files(token)
    for_each_event_file(token, function(path)
        os.remove(path)
    end)
end

function BrowserInput.begin(token)
    token = valid_token(token)
    if not token or not ensure_queue_dir() then
        return nil, "cannot create browser input queue"
    end
    -- A previous worker can have been killed by the device or by KOReader.
    -- Its mailbox must never receive a later source action's touches.
    for name in lfs.dir(QUEUE_DIR) do
        if name:match("^[%d%-]+%-%d+%.event$") then
            os.remove(QUEUE_DIR .. "/" .. name)
        end
    end
    local temporary = ACTIVE_PATH .. ".tmp-" .. token
    local file, open_err = io.open(temporary, "wb")
    if not file then
        return nil, tostring(open_err or "cannot create browser input session")
    end
    local wrote, write_err = file:write(token, "\n")
    file:close()
    if not wrote then
        os.remove(temporary)
        return nil, tostring(write_err or "cannot write browser input session")
    end
    local renamed, rename_err = os.rename(temporary, ACTIVE_PATH)
    if not renamed then
        os.remove(temporary)
        return nil, tostring(rename_err or "cannot activate browser input session")
    end
    sequence = 0
    return true
end

local function coordinate(value)
    value = tonumber(value)
    if not value then return nil end
    return math.floor(value * 1000 + 0.5) / 1000
end

local function point_from_event(event, primary)
    if type(event) ~= "table" then return nil end
    local point = event[primary]
    if type(point) ~= "table" then
        point = event.pos
    end
    if type(point) ~= "table" then return nil end
    local x = coordinate(point.x)
    local y = coordinate(point.y)
    if not x or not y then return nil end
    return x, y
end

function BrowserInput.send(event_type, event)
    local token = active_token()
    if not token or not ensure_queue_dir() then
        return false
    end
    local start_x, start_y = point_from_event(event, "start_pos")
    local end_x, end_y = point_from_event(event, "end_pos")
    local x, y = point_from_event(event, "pos")
    x = x or start_x or end_x
    y = y or start_y or end_y
    if not x or not y then return false end
    start_x = start_x or x
    start_y = start_y or y
    end_x = end_x or x
    end_y = end_y or y
    local kind = type(event) == "table" and event.ges or nil
    kind = tostring(kind or event_type or "gesture"):lower()

    sequence = sequence + 1
    local stem = token .. "-" .. string.format("%010d", sequence)
    local temporary = QUEUE_DIR .. "/" .. stem .. ".tmp"
    local target = QUEUE_DIR .. "/" .. stem .. ".event"
    local file = io.open(temporary, "wb")
    if not file then return false end
    local wrote = file:write(table.concat({
        kind,
        tostring(x), tostring(y),
        tostring(start_x), tostring(start_y),
        tostring(end_x), tostring(end_y),
        "\n",
    }, "\t"))
    file:close()
    if not wrote then
        os.remove(temporary)
        return false
    end
    local renamed = os.rename(temporary, target)
    if not renamed then
        os.remove(temporary)
        return false
    end
    return true
end

local function decode_event(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local line = file:read("*l") or ""
    file:close()
    os.remove(path)
    local values = {}
    for value in line:gmatch("[^\t]+") do
        values[#values + 1] = value
    end
    if #values < 7 then return nil end
    return {
        kind = values[1],
        x = tonumber(values[2]),
        y = tonumber(values[3]),
        start_x = tonumber(values[4]),
        start_y = tonumber(values[5]),
        end_x = tonumber(values[6]),
        end_y = tonumber(values[7]),
    }
end

function BrowserInput.receive(token)
    token = valid_token(token)
    if not token then return {} end
    local paths = {}
    for_each_event_file(token, function(path)
        paths[#paths + 1] = path
    end)
    table.sort(paths)
    local events = {}
    for _, path in ipairs(paths) do
        local event = decode_event(path)
        if event then events[#events + 1] = event end
    end
    return events
end

function BrowserInput.finish(token)
    token = valid_token(token)
    if not token then return end
    clear_event_files(token)
    if active_token() == token then
        os.remove(ACTIVE_PATH)
    end
end

return BrowserInput
