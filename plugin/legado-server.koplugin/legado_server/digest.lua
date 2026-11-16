-- Streaming SHA-256 for immutable sync bundles. This only needs LuaJIT's bit
-- module, so the light client does not depend on the old JavaScript bridge.
local bit = require("bit")
local band, bxor, bnot = bit.band, bit.bxor, bit.bnot
local ror, rshift, tobit = bit.ror, bit.rshift, bit.tobit

local Digest = {}
local Context = {}
Context.__index = Context

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function word(value, offset)
    local a, b, c, d = value:byte(offset, offset + 3)
    return tobit(a * 16777216 + b * 65536 + c * 256 + d)
end

local function compress(context, value, offset)
    local w = context.words
    for index = 1, 16 do w[index] = word(value, offset + (index - 1) * 4) end
    for index = 17, 64 do
        local previous, earlier = w[index - 2], w[index - 15]
        local s0 = bxor(ror(earlier, 7), ror(earlier, 18), rshift(earlier, 3))
        local s1 = bxor(ror(previous, 17), ror(previous, 19), rshift(previous, 10))
        w[index] = tobit(w[index - 16] + s0 + w[index - 7] + s1)
    end
    local h = context.state
    local a, b, c, d, e, f, g, last = unpack(h)
    for index = 1, 64 do
        local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
        local choice = bxor(band(e, f), band(bnot(e), g))
        local first = tobit(last + s1 + choice + K[index] + w[index])
        local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
        local majority = bxor(band(a, b), band(a, c), band(b, c))
        last, g, f, e, d, c, b, a = g, f, e, tobit(d + first), c, b, a, tobit(first + s0 + majority)
    end
    h[1], h[2], h[3], h[4] = tobit(h[1] + a), tobit(h[2] + b), tobit(h[3] + c), tobit(h[4] + d)
    h[5], h[6], h[7], h[8] = tobit(h[5] + e), tobit(h[6] + f), tobit(h[7] + g), tobit(h[8] + last)
end

function Digest.new()
    return setmetatable({
        state = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
        words = {}, bytes = 0, buffer = "",
    }, Context)
end

function Context:update(value)
    assert(not self.finished, "SHA-256 context is already finished")
    assert(type(value) == "string", "SHA-256 input must be bytes")
    self.bytes = self.bytes + #value
    value = self.buffer .. value
    local complete = #value - (#value % 64)
    for offset = 1, complete, 64 do compress(self, value, offset) end
    self.buffer = value:sub(complete + 1)
    return self
end

local function bytes32(value)
    return string.char(band(rshift(value, 24), 255), band(rshift(value, 16), 255), band(rshift(value, 8), 255), band(value, 255))
end

function Context:finish()
    if self.finished then return self.finished end
    local bits = self.bytes * 8
    self:update("\128" .. string.rep("\0", (55 - self.bytes) % 64)
        .. bytes32(math.floor(bits / 4294967296)) .. bytes32(bits % 4294967296))
    local result = {}
    for index, value in ipairs(self.state) do
        if value < 0 then value = value + 4294967296 end
        result[index] = string.format("%08x", value)
    end
    self.finished = table.concat(result)
    return self.finished
end

function Digest.hex(value)
    return Digest.new():update(value):finish()
end

function Digest.file(path)
    local quoted = "'" .. path:gsub("'", "'\\''") .. "'"
    local pipe = io.popen("sha256sum " .. quoted .. " 2>/dev/null", "r")
    if pipe then
        local line = pipe:read("*l")
        local ok = pipe:close()
        local digest = line and line:match("^([0-9a-fA-F]+)%s")
        if ok and digest and #digest == 64 then return digest:lower() end
    end
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    -- KOReader ships an FFI-optimized streaming SHA-256 implementation. It
    -- keeps memory bounded on large whole-book EPUBs and is substantially
    -- faster than the small portable fallback below.
    local loaded, sha2 = pcall(require, "ffi/sha2")
    if loaded and type(sha2) == "table" and type(sha2.sha256) == "function" then
        local context = sha2.sha256()
        while true do
            local value = file:read(64 * 1024)
            if not value then break end
            context(value)
        end
        file:close()
        return context()
    end
    local context = Digest.new()
    while true do
        local value = file:read(32768)
        if not value then break end
        context:update(value)
    end
    file:close()
    return context:finish()
end

return Digest
