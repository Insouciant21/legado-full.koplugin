-- Local, plugin-owned files. No archive member or remote URL is a local path.
local FS = {}
FS.__index = FS

local function parent(path)
    return path:match("^(.*)/[^/]+$")
end

function FS.new()
    local object = setmetatable({
        lfs = require("libs/libkoreader-lfs"),
        util = require("util"),
    }, FS)
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, "int chmod(const char *path, unsigned int mode);")
        pcall(ffi.cdef, "int open(const char *path, int flags, ...);")
        pcall(ffi.cdef, "int fsync(int fd);")
        pcall(ffi.cdef, "int close(int fd);")
        pcall(ffi.cdef, "int flock(int fd, int operation);")
        object.chmod = function(path, mode) pcall(function() ffi.C.chmod(path, mode) end) end
        object.sync = function(path)
            local called, result = pcall(function()
                local fd = ffi.C.open(path, 0)
                if fd < 0 then return false end
                local synced = ffi.C.fsync(fd) == 0
                ffi.C.close(fd)
                return synced
            end)
            if not called or not result then return nil, "cannot flush local file" end
            return true
        end
        object.lock = function(path, callback)
            local fd = ffi.C.open(path, 66, ffi.cast("unsigned int", 384)) -- O_RDWR|O_CREAT, 0600
            if fd < 0 then error("cannot open local transaction lock", 0) end
            if ffi.C.flock(fd, 2) ~= 0 then ffi.C.close(fd); error("cannot lock local transaction", 0) end
            local called, value, other = pcall(callback)
            ffi.C.flock(fd, 8)
            ffi.C.close(fd)
            if not called then error(value, 0) end
            return value, other
        end
    end
    return object
end

function FS:with_lock(path, callback)
    if not self.lock then error("local transaction locking is unavailable", 0) end
    return self.lock(path, callback)
end

function FS:mkdir(path)
    if self.lfs.attributes(path, "mode") == "directory" then return true end
    self.util.makePath(path)
    if self.lfs.attributes(path, "mode") ~= "directory" then return nil, "cannot create local directory" end
    if self.chmod then self.chmod(path, 448) end -- 0700
    return true
end

function FS:exists(path)
    return self.lfs.attributes(path, "mode") == "file"
end

function FS:size(path)
    return self.lfs.attributes(path, "size")
end

function FS:stat(path)
    local attributes = self.lfs.attributes(path)
    if not attributes or attributes.mode ~= "file" then return nil end
    return {
        size = attributes.size,
        modification = attributes.modification,
    }
end

function FS:read(path, limit)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local value = limit and file:read(limit + 1) or file:read("*a")
    file:close()
    if limit and value and #value > limit then return nil, "local file exceeds size limit" end
    return value or ""
end

function FS:write(path, value)
    local directory = parent(path)
    if directory then
        local ok, err = self:mkdir(directory)
        if not ok then return nil, err end
    end
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    if self.chmod then self.chmod(path, 384) end -- 0600, including pairing tokens
    local ok, write_err = file:write(value)
    local closed, close_err = file:close()
    if not ok or not closed then return nil, write_err or close_err or "cannot save local file" end
    if self.sync then return self.sync(path) end
    return true
end

function FS:rename(from, to)
    local ok, err = os.rename(from, to)
    if not ok then return nil, err end
    local directory = parent(to)
    if self.sync and directory then return self.sync(directory) end
    return true
end

function FS:remove(path)
    if not self:exists(path) then return true end
    return os.remove(path)
end

function FS:_atomic_write_unlocked(path, value)
    local pending = path .. ".part"
    local ok, err = self:write(pending, value)
    if not ok then return nil, err end
    ok, err = self:rename(pending, path)
    if not ok then return nil, err end
    return true
end

function FS:atomic_write(path, value)
    local operation = function()
        return self:_atomic_write_unlocked(path, value)
    end
    if self.lock then
        return self:with_lock(path .. ".lock", operation)
    end
    return operation()
end

function FS:writer(path, limit, offset)
    offset = offset or 0
    if offset < 0 or (limit and offset > limit) then return nil, "invalid download resume offset" end
    local directory = parent(path)
    if directory then
        local ok, err = self:mkdir(directory)
        if not ok then return nil, err end
    end
    local existing = self.lfs.attributes(path, "size")
    if offset > 0 and not existing then return nil, "download resume file is missing" end
    if offset > 0 and existing ~= offset then return nil, "download resume file changed" end
    local file, err = io.open(path, offset > 0 and "ab" or "wb")
    if not file then return nil, err end
    if self.chmod then self.chmod(path, 384) end -- 0600, including pairing tokens
    local length, failed, closed, overflow = offset, false, false, false
    local sync = self.sync
    local writer = {}
    function writer:write(chunk)
        if closed or failed then return nil, "download file is closed" end
        if type(chunk) ~= "string" then return nil, "invalid download chunk" end
        length = length + #chunk
        if limit and length > limit then failed = true; overflow = true; return nil, "download exceeds declared size" end
        local ok, write_err = file:write(chunk)
        if not ok then failed = true; return nil, write_err end
        return true
    end
    function writer:close()
        if closed then return not failed end
        closed = true
        local ok, close_err = file:close()
        if not ok then failed = true end
        if not failed and sync then
            local synced, sync_err = sync(path)
            if not synced then failed, close_err = true, sync_err end
        end
        return not failed, close_err
    end
    function writer:size() return length end
    function writer:overflow() return overflow end
    return writer
end

return FS
