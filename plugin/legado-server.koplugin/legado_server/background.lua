local ffi_util = require("ffi/util")
local UIManager = require("ui/uimanager")
local json = require("rapidjson")

local Background = {}

-- Trapper's invisible widget dismisses a subprocess on a tap. Background
-- transfers need to survive normal input and return only a small status.
function Background.run(task, finished)
    local pid, fd = ffi_util.runInSubProcess(function(child_pid, output)
        local result = task()
        local status = { ok = result.ok }
        if not result.ok then
            status.code = tostring(result.code or "unknown"):sub(1, 64)
            status.message = tostring(result.message or ""):sub(1, 384)
        end
        ffi_util.writeToFD(output, json.encode(status), true)
    end, true)
    if not pid then
        finished({ ok = false, code = "worker_start_failed", message = fd })
        return
    end

    local delay = 0.25
    local function poll()
        if not ffi_util.isSubProcessDone(pid) then
            delay = math.min(delay * 2, 1)
            UIManager:scheduleIn(delay, poll)
            return
        end
        -- The bounded result fits in the pipe. Read only after the child exits.
        local decoded, result = pcall(json.decode, ffi_util.readAllFromFD(fd))
        if not decoded or type(result) ~= "table" or type(result.ok) ~= "boolean" then
            result = { ok = false, code = "worker_result_missing" }
        end
        finished(result)
    end
    UIManager:scheduleIn(delay, poll)
end

return Background
