-- Legado JavaScript compatibility layer.
--
-- LuaJIT cannot execute the ES6 syntax used by modern sources, so
-- the actual evaluator lives in native/legado_js.c and is loaded through the
-- small C ABI below.  Network and persistent-looking host objects stay in Lua
-- so the bridge never gives source JavaScript direct filesystem access.

local rapidjson = require("rapidjson")
local Network = require("legado/network")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local DataStorage = require("datastorage")
local socket = require("socket")
local bit
pcall(function()
    bit = require("bit")
end)

local Javascript = {}
Javascript.__index = Javascript

-- A rule normally returns a small scalar or a single page of JSON.  Keeping
-- the bridge buffer at 2 MiB is enough for those results and, importantly,
-- avoids allocating a fresh 16 MiB FFI object for every chapter in a TOC.
-- Large source responses are still allowed up to the hard ceiling below by
-- sizing the reusable buffer from the input page when that is necessary.
local INITIAL_OUTPUT_SIZE = 2 * 1024 * 1024
local MAX_OUTPUT_SIZE = 16 * 1024 * 1024

local ffi
local ffi_error
do
    local ok, loaded = pcall(require, "ffi")
    if ok then
        ffi = loaded
        local cdef_ok, cdef_message = pcall(ffi.cdef, [[
            typedef unsigned long size_t;
            typedef int (*legado_js_host_callback)(const char *operation,
                                                    const char *arguments_json,
                                                    char *output,
                                                    size_t output_size);
            int legado_js_eval(const char *library,
                               const char *script,
                               const char *context_json,
                               legado_js_host_callback callback,
                               char *output,
                               size_t output_size);
            const char *legado_js_engine_version(void);
        ]])
        if not cdef_ok then
            ffi_error = tostring(cdef_message)
            ffi = nil
        end
    else
        ffi_error = tostring(loaded)
    end
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shallow_copy(value)
    local result = {}
    if type(value) == "table" then
        for key, child in pairs(value) do
            result[key] = child
        end
    end
    return result
end

local function is_expected_fallback_log(operation, message)
    if operation ~= "log" then
        return false
    end
    -- Some sources probe Android's optional encrypted-storage API and then
    -- deliberately fall back to source.putLoginInfo() when it is absent.
    -- Hide only that explicit capability-probe message; real source errors
    -- continue to be returned to the user.
    local lowered = tostring(message or ""):lower()
    return lowered:find(
        "legado javascript capability is unavailable on kindle: createsymmetriccrypto",
        1,
        true
    ) ~= nil or lowered:find(
        "legado javascript capability is unavaible on kindle: createsymmetriccrypto",
        1,
        true
    ) ~= nil
end

local function source_directory()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    return source:match("^(.*)/[^/]+$") or "."
end

local function architecture_names()
    local arch = jit and jit.arch or ""
    if arch == "arm" then
        local hard_float = false
        local loader = io.open("/lib/ld-linux-armhf.so.3", "rb")
        if loader then
            loader:close()
            hard_float = true
        end
        if hard_float then
            return { "armhf", "armv7l", "armel", "arm" }
        end
        return { "armel", "armv7l", "arm", "armhf" }
    elseif arch == "x64" then
        return { "x86_64", "x64" }
    elseif arch == "x86" then
        return { "i686", "x86" }
    elseif arch == "ppc" then
        return { "ppc" }
    end
    return {}
end

local function load_bridge()
    if not ffi then
        return nil, "LuaJIT FFI is unavailable: " .. tostring(ffi_error or "unknown error")
    end
    local lib_root = source_directory() .. "/../lib"
    local candidates = {}
    for _, name in ipairs(architecture_names()) do
        candidates[#candidates + 1] = lib_root .. "/" .. name .. "/liblegado_js.so"
    end
    -- This fallback is useful for development builds and for KOReader ports
    -- whose JIT architecture string is not one of the usual names.
    candidates[#candidates + 1] = lib_root .. "/liblegado_js.so"
    local errors = {}
    for _, path in ipairs(candidates) do
        local ok, library = pcall(ffi.load, path)
        if ok and library then
            return library, path
        end
        errors[#errors + 1] = path .. ": " .. tostring(library)
    end
    return nil, "QuickJS bridge is missing; install liblegado_js.so for the Kindle architecture (" ..
        table.concat(errors, "; ") .. ")"
end

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64_reverse

local crypto_library
local crypto_state = false

local function load_crypto_library()
    if crypto_state then return crypto_library end
    crypto_state = true
    if not ffi then return nil end
    pcall(ffi.cdef, [[
        typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
        typedef struct evp_cipher_st EVP_CIPHER;
        typedef struct evp_md_ctx_st EVP_MD_CTX;
        typedef struct evp_md_st EVP_MD;
        typedef struct rsa_st RSA;
        typedef struct bio_st BIO;
        typedef struct evp_pkey_st EVP_PKEY;
        EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
        void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
        const EVP_CIPHER *EVP_aes_128_cbc(void);
        const EVP_CIPHER *EVP_aes_192_cbc(void);
        const EVP_CIPHER *EVP_aes_256_cbc(void);
        const EVP_CIPHER *EVP_aes_128_ecb(void);
        const EVP_CIPHER *EVP_aes_192_ecb(void);
        const EVP_CIPHER *EVP_aes_256_ecb(void);
        const EVP_CIPHER *EVP_des_cbc(void);
        const EVP_CIPHER *EVP_des_ecb(void);
        const EVP_CIPHER *EVP_des_ede3_cbc(void);
        const EVP_CIPHER *EVP_des_ede3_ecb(void);
        int EVP_EncryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, void *, const unsigned char *, const unsigned char *);
        int EVP_EncryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
        int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
        int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, void *, const unsigned char *, const unsigned char *);
        int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
        int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
        int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *, int);
        EVP_MD_CTX *EVP_MD_CTX_new(void);
        void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
        const EVP_MD *EVP_md5(void);
        const EVP_MD *EVP_sha1(void);
        const EVP_MD *EVP_sha224(void);
        const EVP_MD *EVP_sha256(void);
        const EVP_MD *EVP_sha384(void);
        const EVP_MD *EVP_sha512(void);
        int EVP_DigestInit_ex(EVP_MD_CTX *, const EVP_MD *, void *);
        int EVP_DigestUpdate(EVP_MD_CTX *, const void *, size_t);
        int EVP_DigestFinal_ex(EVP_MD_CTX *, unsigned char *, unsigned int *);
        unsigned char *HMAC(const EVP_MD *, const void *, int, const unsigned char *, size_t, unsigned char *, unsigned int *);
        BIO *BIO_new_mem_buf(const void *, int);
        int BIO_free(BIO *);
        RSA *PEM_read_bio_RSA_PUBKEY(BIO *, RSA **, void *, void *);
        RSA *PEM_read_bio_RSAPublicKey(BIO *, RSA **, void *, void *);
        RSA *PEM_read_bio_RSAPrivateKey(BIO *, RSA **, void *, void *);
        EVP_PKEY *PEM_read_bio_PUBKEY(BIO *, EVP_PKEY **, void *, void *);
        EVP_PKEY *PEM_read_bio_PrivateKey(BIO *, EVP_PKEY **, void *, void *);
        RSA *EVP_PKEY_get1_RSA(EVP_PKEY *);
        void EVP_PKEY_free(EVP_PKEY *);
        int RSA_size(const RSA *);
        void RSA_free(RSA *);
        int RSA_public_encrypt(int, const unsigned char *, unsigned char *, RSA *, int);
        int RSA_private_encrypt(int, const unsigned char *, unsigned char *, RSA *, int);
        int RSA_public_decrypt(int, const unsigned char *, unsigned char *, RSA *, int);
        int RSA_private_decrypt(int, const unsigned char *, unsigned char *, RSA *, int);
        int RSA_sign(int, const unsigned char *, unsigned int, unsigned char *, unsigned int *, RSA *);
    ]])
    local candidates = {
        "crypto", "libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so.1.0.0",
        "/mnt/us/koreader/libs/libcrypto.so.57", "/lib/libcrypto.so.1.0.0",
    }
    for _, name in ipairs(candidates) do
        local ok, library = pcall(ffi.load, name)
        if ok and library then
            crypto_library = library
            return library
        end
    end
    return nil
end

local function make_base64_reverse()
    if base64_reverse then
        return base64_reverse
    end
    base64_reverse = {}
    for index = 1, #base64_alphabet do
        base64_reverse[base64_alphabet:sub(index, index)] = index - 1
    end
    return base64_reverse
end

local function base64_flag(flags, mask)
    if flags == nil then return false end
    local value = tonumber(flags) or 0
    if bit then
        return bit.band(value, mask) ~= 0
    end
    return math.floor(value / mask) % 2 == 1
end

local function base64_encode(value, flags)
    value = tostring(value or "")
    local output = {}
    for index = 1, #value, 3 do
        local first = value:byte(index) or 0
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local number = first * 65536 + (second or 0) * 256 + (third or 0)
        output[#output + 1] = base64_alphabet:sub(math.floor(number / 262144) + 1, math.floor(number / 262144) + 1)
        output[#output + 1] = base64_alphabet:sub(math.floor(number / 4096) % 64 + 1, math.floor(number / 4096) % 64 + 1)
        output[#output + 1] = second and base64_alphabet:sub(math.floor(number / 64) % 64 + 1, math.floor(number / 64) % 64 + 1) or "="
        output[#output + 1] = third and base64_alphabet:sub(number % 64 + 1, number % 64 + 1) or "="
    end
    local result = table.concat(output)
    if flags ~= nil then
        if base64_flag(flags, 8) then
            result = result:gsub("%+", "-"):gsub("/", "_")
        end
        if base64_flag(flags, 1) then
            result = result:gsub("=+$", "")
        end
        if not base64_flag(flags, 2) then
            local line_ending = base64_flag(flags, 4) and "\r\n" or "\n"
            local lines = {}
            for index = 1, #result, 76 do
                lines[#lines + 1] = result:sub(index, index + 75)
            end
            result = table.concat(lines, line_ending)
        end
    end
    return result
end

local function base64_decode(value, flags)
    local reverse = make_base64_reverse()
    local input = tostring(value or ""):gsub("%s+", "")
    if base64_flag(flags, 8) or input:find("[-_]", 1) then
        input = input:gsub("-", "+"):gsub("_", "/")
    end
    local remainder = #input % 4
    if remainder == 1 then
        return nil, "invalid Base64 data"
    elseif remainder > 0 then
        input = input .. string.rep("=", 4 - remainder)
    end
    local output = {}
    local index = 1
    while index <= #input do
        local a = reverse[input:sub(index, index)]
        local b = reverse[input:sub(index + 1, index + 1)]
        local c_char = input:sub(index + 2, index + 2)
        local d_char = input:sub(index + 3, index + 3)
        local c = c_char == "=" and nil or reverse[c_char]
        local d = d_char == "=" and nil or reverse[d_char]
        if a == nil or b == nil
                or (c_char ~= "" and c_char ~= "=" and c == nil)
                or (d_char ~= "" and d_char ~= "=" and d == nil) then
            return nil, "invalid Base64 data"
        end
        local number = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        output[#output + 1] = string.char(math.floor(number / 65536) % 256)
        if c ~= nil then
            output[#output + 1] = string.char(math.floor(number / 256) % 256)
        end
        if d ~= nil then
            output[#output + 1] = string.char(number % 256)
        end
        index = index + 4
    end
    return table.concat(output)
end

local function hex_decode(value)
    local input = tostring(value or ""):gsub("%s+", "")
    if #input % 2 ~= 0 or not input:match("^[%x]*$") then
        return nil, "invalid hexadecimal data"
    end
    local output = {}
    for index = 1, #input, 2 do
        output[#output + 1] = string.char(tonumber(input:sub(index, index + 1), 16))
    end
    return table.concat(output)
end

local function binary_string(value)
    if type(value) == "table" and type(value.__legado_bytes) == "string" then
        local decoded = base64_decode(value.__legado_bytes)
        return decoded or ""
    end
    return tostring(value or "")
end

local function binary_marker(value)
    return { __legado_bytes = base64_encode(value or "") }
end

local function decode_cipher_string(value)
    local text = tostring(value or "")
    if #text % 2 == 0 and text:match("^[%x]*$") then
        return hex_decode(text)
    end
    return base64_decode(text)
end

local function binary_array(value)
    local bytes = binary_string(value)
    local result = {}
    for index = 1, #bytes do
        result[index] = bytes:byte(index)
    end
    return result
end

local function crypto_cipher(library, algorithm, mode, key_length)
    algorithm = tostring(algorithm or ""):lower():gsub("[^%w]", "")
    mode = tostring(mode or "cbc"):lower()
    local suffix = mode == "ecb" and "ecb" or "cbc"
    if algorithm == "aes" then
        if key_length == 16 then return library["EVP_aes_128_" .. suffix]() end
        if key_length == 24 then return library["EVP_aes_192_" .. suffix]() end
        if key_length == 32 then return library["EVP_aes_256_" .. suffix]() end
        return nil, "AES key must be 16, 24 or 32 bytes"
    elseif algorithm == "desede" or algorithm == "tripledes" or algorithm == "3des" then
        if key_length ~= 24 then return nil, "DESede key must be 24 bytes" end
        return library["EVP_des_ede3_" .. suffix]()
    elseif algorithm == "des" then
        if key_length ~= 8 then return nil, "DES key must be 8 bytes" end
        return library["EVP_des_" .. suffix]()
    end
    return nil, "unsupported symmetric cipher: " .. tostring(algorithm)
end

local function crypto_transform(transformation, key, iv, data, decrypt)
    local library = load_crypto_library()
    if not library then return nil, "OpenSSL libcrypto is unavailable" end
    local transformation_text = tostring(transformation or "")
    local has_explicit_mode = transformation_text:find("/", 1, true) ~= nil
    local algorithm, mode, padding = transformation_text:match("^%s*([^/]+)/?([^/]*)/?(.*)$")
    algorithm = algorithm or transformation
    -- SymmetricCryptoAndroid expands a bare algorithm to
    -- `algorithm/ECB/PKCS5Padding`, not CBC. This is used by older source
    -- activation/login scripts (for example createSymmetricCrypto("AES", …)).
    mode = mode == "" and (has_explicit_mode and "CBC" or "ECB") or mode
    padding = padding == "" and "PKCS5Padding" or padding
    local key_bytes = binary_string(key)
    local iv_bytes = binary_string(iv)
    local data_bytes = binary_string(data)
    local normalized_algorithm = tostring(algorithm):lower():gsub("[^%w]", "")
    if normalized_algorithm == "des" and #key_bytes > 8 then
        key_bytes = key_bytes:sub(1, 8)
    elseif (normalized_algorithm == "desede"
            or normalized_algorithm == "tripledes"
            or normalized_algorithm == "3des") and #key_bytes > 24 then
        key_bytes = key_bytes:sub(1, 24)
    end
    local cipher, cipher_err = crypto_cipher(library, algorithm, mode, #key_bytes)
    if not cipher then return nil, cipher_err end
    local block_size = (tostring(algorithm):lower():find("aes", 1, true) and 16) or 8
    if tostring(mode):lower() ~= "ecb" then
        if #iv_bytes == 0 then iv_bytes = string.rep("\0", block_size) end
        if #iv_bytes ~= block_size then return nil, "cipher IV has an invalid length" end
    else
        iv_bytes = string.rep("\0", block_size)
    end
    local lower_padding = tostring(padding):lower()
    local no_padding = lower_padding:find("nopadding", 1, true) ~= nil
    local zero_padding = lower_padding:find("zeropadding", 1, true) ~= nil
    if not decrypt and zero_padding then
        local remainder = #data_bytes % block_size
        if remainder ~= 0 then data_bytes = data_bytes .. string.rep("\0", block_size - remainder) end
    end
    if #data_bytes % block_size ~= 0 and (no_padding or decrypt) then
        return nil, "cipher input is not aligned to its block size"
    end
    local context = library.EVP_CIPHER_CTX_new()
    if context == nil then return nil, "cannot allocate cipher context" end
    -- LuaJIT rejects a zero-length variable-sized cdata array. Empty input is
    -- valid for padded ciphers, so allocate one byte while retaining the
    -- actual length passed to OpenSSL.
    local key_buffer = ffi.new("unsigned char[?]", math.max(1, #key_bytes), key_bytes)
    local iv_buffer = ffi.new("unsigned char[?]", math.max(1, #iv_bytes), iv_bytes)
    local input_buffer = ffi.new("unsigned char[?]", math.max(1, #data_bytes), data_bytes)
    local output_buffer = ffi.new("unsigned char[?]", #data_bytes + block_size + 32)
    local written = ffi.new("int[1]")
    local final_written = ffi.new("int[1]")
    local ok
    if decrypt then
        ok = library.EVP_DecryptInit_ex(context, cipher, nil, key_buffer, iv_buffer)
    else
        ok = library.EVP_EncryptInit_ex(context, cipher, nil, key_buffer, iv_buffer)
    end
    if ok ~= 1 then library.EVP_CIPHER_CTX_free(context); return nil, "cipher initialization failed" end
    if no_padding or zero_padding then library.EVP_CIPHER_CTX_set_padding(context, 0) end
    if decrypt then
        ok = library.EVP_DecryptUpdate(context, output_buffer, written, input_buffer, #data_bytes)
    else
        ok = library.EVP_EncryptUpdate(context, output_buffer, written, input_buffer, #data_bytes)
    end
    if ok ~= 1 then library.EVP_CIPHER_CTX_free(context); return nil, "cipher update failed" end
    if decrypt then
        ok = library.EVP_DecryptFinal_ex(context, output_buffer + written[0], final_written)
    else
        ok = library.EVP_EncryptFinal_ex(context, output_buffer + written[0], final_written)
    end
    if ok ~= 1 then library.EVP_CIPHER_CTX_free(context); return nil, "cipher finalization failed" end
    local result = ffi.string(output_buffer, written[0] + final_written[0])
    library.EVP_CIPHER_CTX_free(context)
    if decrypt and zero_padding then result = result:gsub("\0+$", "") end
    return result
end

local function crypto_digest(data, algorithm)
    local library = load_crypto_library()
    if not library then return nil, "OpenSSL libcrypto is unavailable" end
    local name = tostring(algorithm or "SHA-256"):lower():gsub("[^%w]", "")
    local getter = ({
        md5 = "EVP_md5", sha1 = "EVP_sha1", sha224 = "EVP_sha224",
        sha256 = "EVP_sha256", sha384 = "EVP_sha384", sha512 = "EVP_sha512",
    })[name:gsub("^h", "")]
    if not getter then return nil, "unsupported digest algorithm: " .. tostring(algorithm) end
    local context = library.EVP_MD_CTX_new()
    if context == nil then return nil, "cannot allocate digest context" end
    local md = library[getter]()
    local input = binary_string(data)
    local buffer = ffi.new("unsigned char[?]", 128)
    local length = ffi.new("unsigned int[1]")
    local ok = library.EVP_DigestInit_ex(context, md, nil) == 1
    ok = ok and library.EVP_DigestUpdate(context, input, #input) == 1
    ok = ok and library.EVP_DigestFinal_ex(context, buffer, length) == 1
    local result = ok and ffi.string(buffer, length[0]) or nil
    library.EVP_MD_CTX_free(context)
    return result, ok and nil or "digest failed"
end

local function crypto_hmac(data, algorithm, key)
    local library = load_crypto_library()
    if not library then return nil, "OpenSSL libcrypto is unavailable" end
    local name = tostring(algorithm or "SHA-256"):lower():gsub("[^%w]", "")
        :gsub("^hmac", "")
    local getter = ({
        md5 = "EVP_md5", sha1 = "EVP_sha1", sha224 = "EVP_sha224",
        sha256 = "EVP_sha256", sha384 = "EVP_sha384", sha512 = "EVP_sha512",
    })[name]
    if not getter then return nil, "unsupported HMAC algorithm: " .. tostring(algorithm) end
    local input, key_bytes = binary_string(data), binary_string(key)
    local output = ffi.new("unsigned char[?]", 128)
    local length = ffi.new("unsigned int[1]")
    local result = library.HMAC(library[getter](), key_bytes, #key_bytes, input, #input, output, length)
    if result == nil then return nil, "HMAC failed" end
    return ffi.string(output, length[0])
end

-- RSA helpers used by source signatures and encrypted API parameters. Android
-- accepts both PKCS#1 and SubjectPublicKeyInfo PEM encodings; OpenSSL exposes
-- parsers for both, so keep key handling in this host layer instead of
-- teaching individual source rules about Kindle-specific crypto.
local function load_rsa_key(library, pem, private)
    if not ffi or not library or type(pem) ~= "string" or pem == "" then
        return nil, nil, "RSA key is empty"
    end
    local buffer = ffi.new("char[?]", math.max(1, #pem), pem)
    local bio = library.BIO_new_mem_buf(buffer, #pem)
    if bio == nil then return nil, nil, "cannot allocate RSA key buffer" end
    local rsa
    local pkey
    if private then
        local ok, reader = pcall(function() return library.PEM_read_bio_RSAPrivateKey end)
        if ok and reader then rsa = reader(bio, nil, nil, nil) end
        if rsa == nil then
            library.BIO_free(bio)
            bio = library.BIO_new_mem_buf(buffer, #pem)
            local pkey_ok, pkey_reader = pcall(function() return library.PEM_read_bio_PrivateKey end)
            if pkey_ok and pkey_reader and bio ~= nil then
                pkey = pkey_reader(bio, nil, nil, nil)
                if pkey ~= nil then
                    local rsa_ok, rsa_getter = pcall(function() return library.EVP_PKEY_get1_RSA end)
                    if rsa_ok and rsa_getter then rsa = rsa_getter(pkey) end
                end
            end
        end
    else
        local ok, reader = pcall(function() return library.PEM_read_bio_RSA_PUBKEY end)
        if ok and reader then rsa = reader(bio, nil, nil, nil) end
        if rsa == nil then
            library.BIO_free(bio)
            bio = library.BIO_new_mem_buf(buffer, #pem)
            local pkcs1_ok, pkcs1_reader = pcall(function() return library.PEM_read_bio_RSAPublicKey end)
            if pkcs1_ok and pkcs1_reader and bio ~= nil then
                rsa = pkcs1_reader(bio, nil, nil, nil)
            end
        end
        if rsa == nil then
            library.BIO_free(bio)
            bio = library.BIO_new_mem_buf(buffer, #pem)
            local pkey_ok, pkey_reader = pcall(function() return library.PEM_read_bio_PUBKEY end)
            if pkey_ok and pkey_reader and bio ~= nil then
                pkey = pkey_reader(bio, nil, nil, nil)
                if pkey ~= nil then
                    local rsa_ok, rsa_getter = pcall(function() return library.EVP_PKEY_get1_RSA end)
                    if rsa_ok and rsa_getter then rsa = rsa_getter(pkey) end
                end
            end
        end
    end
    if bio ~= nil then library.BIO_free(bio) end
    if pkey ~= nil then library.EVP_PKEY_free(pkey) end
    if rsa == nil then return nil, nil, "cannot parse RSA key" end
    return rsa
end

local function rsa_padding(transformation)
    local value = tostring(transformation or ""):lower()
    if value:find("oaep", 1, true) then return 4, 42 end
    if value:find("nopadding", 1, true) then return 3, 0 end
    return 1, 11
end

local function crypto_asymmetric_transform(transformation, public_key, private_key,
        data, decrypt, use_public)
    local library = load_crypto_library()
    if not library then return nil, "OpenSSL libcrypto is unavailable" end
    local pem = use_public and public_key or private_key
    local private = not use_public
    if decrypt then
        pem = use_public and public_key or private_key
        private = not use_public
    end
    local rsa, _, key_err = load_rsa_key(library, tostring(pem or ""), private)
    if not rsa then return nil, key_err end
    local input = binary_string(data)
    local size = tonumber(library.RSA_size(rsa)) or 0
    if size <= 0 then library.RSA_free(rsa); return nil, "invalid RSA key size" end
    local padding, overhead = rsa_padding(transformation)
    local chunk_size = decrypt and size or size - overhead
    if chunk_size <= 0 then library.RSA_free(rsa); return nil, "invalid RSA padding" end
    local output = {}
    local position = 1
    while position <= #input or (#input == 0 and position == 1) do
        local length = decrypt and math.min(size, #input - position + 1)
            or math.min(chunk_size, #input - position + 1)
        if length < 0 then length = 0 end
        local chunk = input:sub(position, position + length - 1)
        local input_buffer = ffi.new("unsigned char[?]", math.max(1, #chunk), chunk)
        local output_buffer = ffi.new("unsigned char[?]", math.max(1, size))
        local written
        if decrypt then
            if #chunk ~= size then
                library.RSA_free(rsa)
                return nil, "RSA ciphertext is not a full key block"
            end
            if use_public then
                written = library.RSA_public_decrypt(#chunk, input_buffer, output_buffer, rsa, padding)
            else
                written = library.RSA_private_decrypt(#chunk, input_buffer, output_buffer, rsa, padding)
            end
        elseif use_public then
            written = library.RSA_public_encrypt(#chunk, input_buffer, output_buffer, rsa, padding)
        else
            written = library.RSA_private_encrypt(#chunk, input_buffer, output_buffer, rsa, padding)
        end
        if tonumber(written or -1) < 0 then
            library.RSA_free(rsa)
            return nil, "RSA operation failed"
        end
        output[#output + 1] = ffi.string(output_buffer, tonumber(written))
        if #input == 0 then break end
        position = position + length
    end
    library.RSA_free(rsa)
    return table.concat(output)
end

local function crypto_sign(data, algorithm, private_key)
    local library = load_crypto_library()
    if not library then return nil, "OpenSSL libcrypto is unavailable" end
    local name = tostring(algorithm or "SHA256withRSA"):lower():gsub("[^%w]", "")
    local nids = {
        md5withrsa = 4, md5 = 4,
        sha1withrsa = 64, sha1 = 64,
        sha224withrsa = 675, sha224 = 675,
        sha256withrsa = 672, sha256 = 672,
        sha384withrsa = 673, sha384 = 673,
        sha512withrsa = 674, sha512 = 674,
    }
    local nid = nids[name]
    if not nid then return nil, "unsupported RSA signature algorithm: " .. tostring(algorithm) end
    local rsa, _, key_err = load_rsa_key(library, tostring(private_key or ""), true)
    if not rsa then return nil, key_err end
    local digest, digest_err = crypto_digest(data, name:gsub("withrsa", ""))
    if not digest then library.RSA_free(rsa); return nil, digest_err end
    local output = ffi.new("unsigned char[?]", math.max(1, tonumber(library.RSA_size(rsa)) or 1))
    local written = ffi.new("unsigned int[1]")
    local input = ffi.new("unsigned char[?]", math.max(1, #digest), digest)
    local ok = library.RSA_sign(nid, input, #digest, output, written, rsa)
    library.RSA_free(rsa)
    if ok ~= 1 then return nil, "RSA signature failed" end
    return ffi.string(output, written[0])
end

local function md5_hex(value)
    if not bit then
        return nil, "LuaJIT bit operations are unavailable"
    end
    value = tostring(value or "")
    local uint32 = 4294967296
    local function unsigned(number)
        number = tonumber(number) or 0
        return number < 0 and number + uint32 or number
    end
    local function add32(...)
        local total = 0
        for index = 1, select("#", ...) do
            total = total + unsigned(select(index, ...))
        end
        return bit.tobit(total % uint32)
    end
    local function rotate_left(number, amount)
        return bit.bor(bit.lshift(number, amount), bit.rshift(number, 32 - amount))
    end
    local function word_at(data, offset)
        local b1 = data:byte(offset) or 0
        local b2 = data:byte(offset + 1) or 0
        local b3 = data:byte(offset + 2) or 0
        local b4 = data:byte(offset + 3) or 0
        return bit.tobit(b1 + b2 * 256 + b3 * 65536 + b4 * 16777216)
    end
    local function word_bytes(number)
        local value_number = unsigned(number)
        return string.char(
            value_number % 256,
            math.floor(value_number / 256) % 256,
            math.floor(value_number / 65536) % 256,
            math.floor(value_number / 16777216) % 256
        )
    end

    local shifts = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    }
    local constants = {}
    for index = 1, 64 do
        constants[index] = bit.tobit(math.floor(math.abs(math.sin(index)) * uint32))
    end

    local bit_length = #value * 8
    local data = value .. string.char(128)
    while #data % 64 ~= 56 do
        data = data .. string.char(0)
    end
    local length_number = bit_length
    for _ = 1, 4 do
        data = data .. string.char(length_number % 256)
        length_number = math.floor(length_number / 256)
    end
    data = data .. string.rep(string.char(0), 4)

    local a0 = bit.tobit(0x67452301)
    local b0 = bit.tobit(0xefcdab89)
    local c0 = bit.tobit(0x98badcfe)
    local d0 = bit.tobit(0x10325476)
    for offset = 1, #data, 64 do
        local words = {}
        for index = 0, 15 do
            words[index] = word_at(data, offset + index * 4)
        end
        local a, b, c, d = a0, b0, c0, d0
        for index = 0, 63 do
            local f, word_index
            if index < 16 then
                f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
                word_index = index
            elseif index < 32 then
                f = bit.bor(bit.band(d, b), bit.band(bit.bnot(d), c))
                word_index = (5 * index + 1) % 16
            elseif index < 48 then
                f = bit.bxor(b, c, d)
                word_index = (3 * index + 5) % 16
            else
                f = bit.bxor(c, bit.bor(b, bit.bnot(d)))
                word_index = (7 * index) % 16
            end
            local next_a = d
            local rotated = rotate_left(add32(a, f, constants[index + 1], words[word_index]), shifts[index + 1])
            d = c
            c = b
            b = add32(b, rotated)
            a = next_a
        end
        a0 = add32(a0, a)
        b0 = add32(b0, b)
        c0 = add32(c0, c)
        d0 = add32(d0, d)
    end
    local digest = word_bytes(a0) .. word_bytes(b0) .. word_bytes(c0) .. word_bytes(d0)
    return (digest:gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

-- Android exposes a small, source-private cache directory to JavaScript.
-- Keep the same boundary on Kindle: a source can read/write only below this
-- directory, never an arbitrary path on the device.  Returning paths relative
-- to the directory also matches JsExtensions.downloadFile().
local js_cache_root

local function get_js_cache_root()
    if not js_cache_root then
        js_cache_root = DataStorage:getDataDir() .. "/legado/js-cache"
        util.makePath(js_cache_root)
    end
    return js_cache_root
end

local function normalized_relative_path(value)
    local path = tostring(value or ""):gsub("\\", "/")
    if path == "" then return nil, "empty JavaScript file path" end
    -- A path returned by this module may start with '/', while Android also
    -- accepts a relative path.  Both are interpreted below the cache root.
    path = path:gsub("^/+", "")
    local pieces = {}
    for piece in path:gmatch("[^/]+") do
        if piece == ".." then
            return nil, "JavaScript file path escapes the cache directory"
        elseif piece ~= "." and piece ~= "" then
            pieces[#pieces + 1] = piece
        end
    end
    if #pieces == 0 then return nil, "empty JavaScript file path" end
    return table.concat(pieces, "/")
end

local function js_file_path(value, create_parent)
    local relative, relative_err = normalized_relative_path(value)
    if not relative then return nil, relative_err end
    local root = get_js_cache_root()
    local path = root .. "/" .. relative
    if create_parent then
        local parent = path:match("^(.*)/[^/]+$")
        if parent then util.makePath(parent) end
    end
    return path, relative
end

local function read_binary_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_binary_file(path, data)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then util.makePath(parent) end
    local file, open_err = io.open(path, "wb")
    if not file then return nil, tostring(open_err or "cannot open file") end
    local ok, write_err = file:write(data or "")
    file:close()
    if not ok then return nil, tostring(write_err or "cannot write file") end
    return true
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then
        return os.remove(path) ~= nil
    elseif mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        return lfs.rmdir(path)
    end
    return true
end

local function file_extension(url)
    local clean = tostring(url or ""):match("^[^,]+") or ""
    local extension = clean:match("%.([%w]+)[?#]")
        or clean:match("%.([%w]+)$")
    extension = extension and extension:lower() or "bin"
    if #extension > 10 then extension = "bin" end
    return extension
end

local function download_js_file(source, content, url)
    url = tostring(url or "")
    if url == "" then return nil, "empty download URL" end
    local extension = file_extension(url)
    local relative = "files/" .. md5_hex(url):sub(1, 16) .. "." .. extension
    local path, path_err = js_file_path(relative, true)
    if not path then return nil, path_err end
    local bytes
    if content ~= nil and tostring(content) ~= "" then
        bytes, path_err = hex_decode(content)
        if not bytes then return nil, path_err end
    else
        local hex, response_headers, response_code = Network.get(url, source, { type = extension })
        if not hex then return nil, response_headers or "file download failed" end
        bytes, path_err = hex_decode(hex)
        if not bytes then return nil, path_err end
        if response_code and tonumber(response_code) >= 400 then
            return nil, "file download returned HTTP " .. tostring(response_code)
        end
    end
    local written, write_err = write_binary_file(path, bytes)
    if not written then return nil, write_err end
    return "/" .. relative
end

local function cache_js_file(source, url, save_time)
    url = tostring(url or "")
    local key = md5_hex(url):sub(9, 24)
    local relative = "cache/" .. key .. ".txt"
    local path = js_file_path(relative, true)
    local age
    local modified = lfs.attributes(path, "modification")
    if modified then age = os.time() - tonumber(modified) end
    local ttl = tonumber(save_time) or 0
    local can_reuse = modified ~= nil and (ttl <= 0 or (age and age < ttl))
    if not can_reuse then
        local body, headers_or_error = Network.get(url, source)
        if not body then return nil, headers_or_error or "JavaScript cache download failed" end
        local written, write_err = write_binary_file(path, body)
        if not written then return nil, write_err end
    end
    return read_binary_file(path) or ""
end

local function get_txt_in_folder(value)
    local path, path_err = js_file_path(value)
    if not path then return nil, path_err end
    local files = {}
    local function collect(folder, prefix)
        if lfs.attributes(folder, "mode") ~= "directory" then return end
        for name in lfs.dir(folder) do
            if name ~= "." and name ~= ".." then
                local child = folder .. "/" .. name
                local mode = lfs.attributes(child, "mode")
                if mode == "file" then
                    files[#files + 1] = { path = child, name = prefix .. name }
                elseif mode == "directory" then
                    collect(child, prefix .. name .. "/")
                end
            end
        end
    end
    collect(path, "")
    table.sort(files, function(left, right) return left.name < right.name end)
    local output = {}
    for _, file in ipairs(files) do
        output[#output + 1] = read_binary_file(file.path) or ""
    end
    remove_tree(path)
    return table.concat(output, "\n")
end

local function archive_extract(value)
    local path, path_err = js_file_path(value)
    if not path then return nil, path_err end
    if lfs.attributes(path, "mode") ~= "file" then
        return nil, "archive does not exist: " .. tostring(value)
    end
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or type(Archiver) ~= "table" or type(Archiver.Reader) ~= "table" then
        return nil, "KOReader archive reader is unavailable"
    end
    local reader = Archiver.Reader:new()
    if not reader:open(path) then
        local message = reader.err or "cannot open archive"
        reader:close()
        return nil, message
    end
    local relative = "unpack/" .. md5_hex(path .. tostring(os.time()) .. tostring(math.random())):sub(1, 16)
    local output_root = js_file_path(relative, true)
    local extracted = false
    for entry in reader:iterate() do
        local entry_name = tostring(entry.path or ""):gsub("\\", "/")
        local safe_name, safe_err = normalized_relative_path(entry_name)
        if safe_name and (entry.mode == "file" or entry.mode == "directory") then
            if entry.mode == "directory" then
                util.makePath(output_root .. "/" .. safe_name)
            else
                local data = reader:extractToMemory(entry.path)
                if data == nil then
                    local message = reader.err or "cannot extract archive member"
                    reader:close()
                    remove_tree(output_root)
                    return nil, message
                end
                local written, write_err = write_binary_file(output_root .. "/" .. safe_name, data)
                if not written then
                    reader:close()
                    remove_tree(output_root)
                    return nil, write_err
                end
                extracted = true
            end
        elseif entry_name ~= "" then
            reader:close()
            remove_tree(output_root)
            return nil, safe_err or "archive contains an unsafe member"
        end
    end
    reader:close()
    if not extracted then
        remove_tree(output_root)
        return nil, "archive contains no files"
    end
    return "/" .. relative
end

local chinese_digits = {
    ["零"] = 0, ["〇"] = 0, ["一"] = 1, ["壹"] = 1,
    ["二"] = 2, ["两"] = 2, ["贰"] = 2, ["三"] = 3, ["叁"] = 3,
    ["四"] = 4, ["肆"] = 4, ["五"] = 5, ["伍"] = 5,
    ["六"] = 6, ["陆"] = 6, ["七"] = 7, ["柒"] = 7,
    ["八"] = 8, ["捌"] = 8, ["九"] = 9, ["玖"] = 9,
}
local chinese_small_units = { ["十"] = 10, ["拾"] = 10, ["百"] = 100, ["佰"] = 100,
    ["千"] = 1000, ["仟"] = 1000 }
local chinese_large_units = { ["万"] = 10000, ["萬"] = 10000, ["亿"] = 100000000, ["億"] = 100000000 }

local function utf8_characters(value)
    local result = {}
    local index = 1
    while index <= #value do
        local byte = value:byte(index)
        local width = byte < 0x80 and 1 or byte < 0xe0 and 2 or byte < 0xf0 and 3 or 4
        result[#result + 1] = value:sub(index, index + width - 1)
        index = index + width
    end
    return result
end

local function chinese_number(value)
    value = trim(value)
    if value:match("^%d+$") then return tonumber(value) end
    if value == "" then return nil end
    local total, section, number = 0, 0, nil
    local recognized = false
    for _, character in ipairs(utf8_characters(value)) do
        local digit = chinese_digits[character]
        if digit ~= nil then
            number = digit
            recognized = true
        elseif chinese_small_units[character] then
            local unit = chinese_small_units[character]
            section = section + (number or 1) * unit
            number = nil
            recognized = true
        elseif chinese_large_units[character] then
            local unit = chinese_large_units[character]
            section = section + (number or 0)
            if section == 0 then section = 1 end
            total = total + section * unit
            section, number = 0, nil
            recognized = true
        else
            return nil
        end
    end
    if not recognized then return nil end
    return total + section + (number or 0)
end

local function to_num_chapter(value)
    if value == nil then return nil end
    value = tostring(value)
    local start = value:find("第", 1, true)
    if not start then return value end
    local finish = value:find("章", start + 3, true)
    if not finish then return value end
    local number = chinese_number(value:sub(start + #"第", finish - 1))
    if not number then return value end
    return value:sub(1, start + #"第" - 1) .. tostring(number) .. value:sub(finish)
end

local function html_format(value)
    -- HtmlFormatter.formatKeepImg mainly normalizes line-breaking tags. Keep
    -- markup here because JavaScript sources may pass the result to another
    -- selector; final novel rendering still goes through legado/content.lua.
    local text = tostring(value or ""):gsub("\r\n?", "\n")
    text = text:gsub("<%s*br%s*/?%s*>", "<br/>")
    text = text:gsub("<%s*/%s*p%s*>", "</p>\n")
    return text
end

local function safe_json(value)
    if value == nil then
        return "null"
    end
    local ok, encoded = pcall(rapidjson.encode, value)
    if not ok then
        return nil, tostring(encoded)
    end
    return encoded
end

local function value_for_json(value, depth, seen)
    depth = depth or 0
    if depth > 12 then
        return nil
    end
    local value_type = type(value)
    if value == nil or value_type == "string" or value_type == "number" or value_type == "boolean" then
        return value
    elseif value_type == "table" then
        if type(value.__legado_element) == "string" then
            return value.__legado_element
        elseif type(value.__legado_html) == "string" then
            return value.__legado_html
        elseif type(value.__legado_bytes) == "string" then
            return value
        end
        seen = seen or {}
        if seen[value] then
            return nil
        end
        seen[value] = true
        local output = {}
        for key, child in pairs(value) do
            if type(key) == "string" and key:sub(1, 2) ~= "__" and type(child) ~= "function"
                    and type(child) ~= "userdata" and type(child) ~= "cdata" then
                output[key] = value_for_json(child, depth + 1, seen)
            elseif type(key) == "number" and type(child) ~= "function"
                    and type(child) ~= "userdata" and type(child) ~= "cdata" then
                output[key] = value_for_json(child, depth + 1, seen)
            end
        end
        seen[value] = nil
        return output
    elseif value_type == "userdata" then
        local ok, content = pcall(function()
            return value:getcontent()
        end)
        return ok and tostring(content or "") or tostring(value)
    end
    return tostring(value)
end

local function element_content(value)
    if type(value) == "table" then
        if type(value.__legado_element) == "string" then
            return value.__legado_element
        elseif type(value.__legado_html) == "string" then
            return value.__legado_html
        end
    end
    if type(value) == "userdata" then
        local ok, content = pcall(function()
            return value:getcontent()
        end)
        if ok then
            return content or ""
        end
    end
    return value
end

local function host_content(context, value)
    if value == nil then
        value = context and context.result or ""
    end
    return element_content(value)
end

local function source_key(source)
    source = source or {}
    return tostring(source.bookSourceUrl or "") .. "\0" .. tostring(source.bookSourceName or "")
end

local function book_key(context)
    return tostring(context.bookKey or (context.book and (context.book.bookUrl or context.book.name)) or "")
end

local function map_for(root, key)
    local value = root[key]
    if type(value) ~= "table" then
        value = {}
        root[key] = value
    end
    return value
end

local function request_options_with_context(options, context)
    if type(options) == "string" then
        local decoded_ok, decoded = pcall(rapidjson.decode, options)
        options = decoded_ok and type(decoded) == "table" and decoded or {}
    elseif type(options) ~= "table" then
        options = {}
    else
        options = shallow_copy(options)
    end
    options.__legado_context = context
    return options
end

local function cache_entry_value(cache, key)
    local entry = cache[tostring(key or "")]
    if type(entry) ~= "table" or entry.__legado_cache_entry ~= true then
        return entry
    end
    local expires = tonumber(entry.expires) or 0
    if expires > 0 and expires <= os.time() then
        cache[tostring(key or "")] = nil
        return nil
    end
    return entry.value
end

local function cache_entry_put(cache, key, value, save_time)
    local seconds = tonumber(save_time) or 0
    cache[tostring(key or "")] = {
        __legado_cache_entry = true,
        value = value,
        expires = seconds > 0 and (os.time() + math.floor(seconds)) or 0,
    }
    return value
end

local function invalidate_file_cache(key)
    local normalized = tostring(key or "")
    local path = js_file_path("cache/" .. normalized .. ".txt")
    if path then os.remove(path) end
end

local function read_js_text_file(value, charset)
    local path, path_err = js_file_path(value)
    if not path then return nil, path_err end
    local content = read_binary_file(path)
    if not content then return "" end
    if charset and trim(charset) ~= "" then
        return Network.convert_charset(content, charset, "UTF-8")
    end
    return content
end

local function archive_string_content(source, archive, member, charset)
    archive = tostring(archive or "")
    member = tostring(member or "")
    if archive == "" or member == "" then return "" end
    local bytes
    if archive:match("^https?://") or archive:match("^data:") then
        local hex, err = Network.get(archive, source, { type = "bin" })
        if not hex then return nil, err or "archive download failed" end
        bytes, err = hex_decode(hex)
        if not bytes then return nil, err end
    elseif archive:sub(1, 1) == "/" then
        bytes = read_js_text_file(archive)
    else
        bytes = hex_decode(archive)
    end
    if not bytes then return nil, "archive content is unavailable" end

    local relative = "archives/" .. md5_hex(archive .. "\0" .. member):sub(1, 16) .. ".bin"
    local path, path_err = js_file_path(relative, true)
    if not path then return nil, path_err end
    local written, write_err = write_binary_file(path, bytes)
    if not written then return nil, write_err end
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or type(Archiver) ~= "table" or type(Archiver.Reader) ~= "table" then
        os.remove(path)
        return nil, "KOReader archive reader is unavailable"
    end
    local reader = Archiver.Reader:new()
    if not reader:open(path) then
        local message = reader.err or "cannot open archive"
        reader:close()
        os.remove(path)
        return nil, message
    end
    local result
    for entry in reader:iterate() do
        if tostring(entry.path or "") == member then
            result = reader:extractToMemory(entry.path)
            break
        end
    end
    reader:close()
    os.remove(path)
    if result == nil then return "" end
    if charset and trim(charset) ~= "" then
        result = Network.convert_charset(result, charset, "UTF-8")
    end
    return result
end

local traditional_to_simplified = {
    ["國"] = "国", ["學"] = "学", ["說"] = "说", ["書"] = "书",
    ["體"] = "体", ["門"] = "门", ["開"] = "开", ["關"] = "关",
    ["時"] = "时", ["間"] = "间", ["長"] = "长", ["點"] = "点",
    ["現"] = "现", ["發"] = "发", ["後"] = "后", ["裡"] = "里",
    ["這"] = "这", ["個"] = "个", ["們"] = "们", ["為"] = "为",
    ["與"] = "与", ["從"] = "从", ["無"] = "无", ["過"] = "过",
    ["來"] = "来", ["見"] = "见", ["萬"] = "万", ["與"] = "与",
    ["應"] = "应", ["實"] = "实", ["當"] = "当", ["動"] = "动",
    ["華"] = "华", ["語"] = "语", ["讀"] = "读", ["寫"] = "写",
}

local function convert_common_chinese(value, reverse)
    value = tostring(value or "")
    local mapping = traditional_to_simplified
    if reverse then
        local reverse_map = {}
        for traditional, simplified in pairs(traditional_to_simplified) do
            reverse_map[simplified] = traditional
        end
        mapping = reverse_map
    end
    local output = {}
    for _, character in ipairs(utf8_characters(value)) do
        output[#output + 1] = mapping[character] or character
    end
    return table.concat(output)
end

local function javascript_header(source)
    local header = source and source.header
    if type(header) ~= "string" then
        return false
    end
    local lowered = trim(header):lower()
    return lowered:match("^@js:") ~= nil or lowered:match("^<js>") ~= nil
end

local function decode_object(value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" or trim(value) == "" then return nil end
    local ok, decoded = pcall(rapidjson.decode, value)
    return ok and type(decoded) == "table" and decoded or nil
end

local function context_variable_map(context, field)
    local object = type(context) == "table" and context[field]
    if type(object) ~= "table" then return {} end
    if type(object.variable) == "table" then
        return object.variable
    end
    local decoded = decode_object(object.variable)
    if decoded then
        object.variable = decoded
        return decoded
    end
    local result = {}
    object.variable = result
    return result
end

local function set_context_variable_map(context, field, value)
    local object = type(context) == "table" and context[field]
    if type(object) == "table" then
        object.variable = value
    end
end

local function chapter_key(context)
    context = type(context) == "table" and context or {}
    local chapter = type(context.chapter) == "table" and context.chapter or {}
    local value = context.chapterKey or chapter.url or chapter.index or context.baseUrl or ""
    local book = book_key(context)
    value = tostring(value)
    return book ~= "" and book .. "\0" .. value or value
end

local function source_header_map(source, include_login)
    local result = {}
    local raw = source and source.header
    if type(raw) == "table" then
        for key, value in pairs(raw) do
            if type(value) == "string" or type(value) == "number" then
                result[tostring(key)] = tostring(value)
            end
        end
    elseif type(raw) == "string" and not javascript_header(source) then
        local decoded = decode_object(raw)
        if decoded then
            for key, value in pairs(decoded) do
                if type(value) == "string" or type(value) == "number" then
                    result[tostring(key)] = tostring(value)
                end
            end
        else
            for line in raw:gmatch("[^\r\n]+") do
                local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
                if key and value then result[key] = value end
            end
        end
    end
    if include_login then
        local login = decode_object(source and source.__legado_login_header)
        for key, value in pairs(login or {}) do
            if type(value) == "string" or type(value) == "number" then
                result[tostring(key)] = tostring(value)
            end
        end
    end
    return result
end

local function formatted_time(value, format, utc)
    local number = tonumber(value)
    if not number then return tostring(value or "") end
    if math.abs(number) > 100000000000 then number = number / 1000 end
    local pattern = tostring(format or "yyyy-MM-dd HH:mm:ss")
    pattern = pattern:gsub("yyyy", "%%Y"):gsub("MM", "%%m"):gsub("dd", "%%d")
        :gsub("HH", "%%H"):gsub("mm", "%%M"):gsub("ss", "%%S")
    local date_pattern = utc and ("!" .. pattern) or pattern
    local ok, result = pcall(os.date, date_pattern, math.floor(number))
    return ok and result or tostring(value or "")
end

local function initial_login_info(source)
    local raw = source and source.loginUi
    if type(raw) == "string" then
        local decoded_ok, decoded = pcall(rapidjson.decode, raw)
        raw = decoded_ok and decoded or nil
    end
    if type(raw) ~= "table" then return {} end
    local result = {}
    for index, control in ipairs(raw) do
        if type(control) == "table" then
            local control_type = tostring(control.type or control.inputType or "text"):lower()
            if control_type ~= "button" and control_type ~= "submit"
                    and control_type ~= "label" and control_type ~= "divider" then
                local name = tostring(control.name or control.key or control.id or control.label or "")
                if name == "" then name = "field_" .. tostring(index) end
                local value = control.value
                if value == nil then value = control.default end
                if value == nil and control.checked ~= nil then value = control.checked end
                result[name] = value == nil and "" or value
            end
        end
    end
    return result
end

local function decode_login_info(source, raw)
    if raw == nil or raw == "" then
        raw = source and source.loginInfo
    end
    if raw == nil or raw == "" then
        raw = initial_login_info(source)
    end
    if type(raw) == "table" then return raw end
    local decoded_ok, decoded = pcall(rapidjson.decode, tostring(raw or ""))
    return decoded_ok and type(decoded) == "table" and decoded or {}
end

local function random_uuid()
    local pieces = {}
    for _, length in ipairs({ 8, 4, 4, 4, 12 }) do
        local chars = {}
        for _ = 1, length do chars[#chars + 1] = string.format("%x", math.random(0, 15)) end
        pieces[#pieces + 1] = table.concat(chars)
    end
    pieces[3] = "4" .. pieces[3]:sub(2)
    pieces[4] = string.format("%x", math.random(8, 11)) .. pieces[4]:sub(2)
    return table.concat(pieces, "-")
end

function Javascript:new()
    local object = setmetatable({}, self)
    object.bridge, object.bridge_path = load_bridge()
    object.source_variables = {}
    object.login_infos = {}
    object.login_headers = {}
    object.store = {}
    object.cache = {}
    object.memory = {}
    object.arguments = {}
    object.book_variables = {}
    object.chapter_variables = {}
    -- Legado's discovery screen stores only source-specific filter values in
    -- InfoMap.  Keep it outside imported source JSON and outside Android
    -- reading/UI settings.
    object.explore_infos = {}
    object.concurrent_rates = {}
    object.library_cache = {}
    object.callback = nil
    object.output_buffer = nil
    object.output_size = 0
    object.notifications = {}
    object.fatal_error = nil
    return object
end

-- Android sources commonly report the outcome of a login action through
-- java.toast()/java.log() instead of returning a value.  Keep those messages
-- in the worker until Runtime.login_source can pass them back to the UI.
function Javascript:clear_notifications()
    self.notifications = {}
    self.fatal_error = nil
end

function Javascript:take_notifications()
    local messages = self.notifications or {}
    self.notifications = {}
    return messages
end

local function is_cloudflare_unsupported_error(message)
    return tostring(message or ""):lower():find(
        "cloudflare verification is not supported on this kindle browser",
        1,
        true
    ) ~= nil
end

function Javascript:mark_fatal_error(message)
    if is_cloudflare_unsupported_error(message) and not self.fatal_error then
        self.fatal_error = tostring(message)
    end
end

function Javascript:take_fatal_error()
    local message = self.fatal_error
    self.fatal_error = nil
    return message
end

function Javascript:ensure_output_buffer(size)
    size = tonumber(size) or INITIAL_OUTPUT_SIZE
    size = math.max(INITIAL_OUTPUT_SIZE, math.min(MAX_OUTPUT_SIZE, math.floor(size)))
    if self.output_buffer and self.output_size >= size then
        return true
    end

    -- Drop the previous FFI allocation before growing.  This matters on the
    -- 32-bit Kindle libc, where retaining both buffers can briefly double the
    -- resident allocation during a large result.
    self.output_buffer = nil
    self.output_size = 0
    collectgarbage("collect")
    local ok, buffer = pcall(ffi.new, "char[?]", size)
    if not ok then
        return nil, "cannot allocate JavaScript result buffer: " .. tostring(buffer)
    end
    self.output_buffer = buffer
    self.output_size = size
    return true
end

function Javascript:is_available()
    return self.bridge ~= nil
end

function Javascript:status()
    if self.bridge then
        local ok, version = pcall(function()
            return ffi.string(self.bridge.legado_js_engine_version())
        end)
        return ok and version or "QuickJS"
    end
    return nil, self.bridge_path
end

function Javascript:source_variable(source, context)
    local key = source_key(source)
    if self.source_variables[key] == nil then
        local initial = (context or {}).sourceVariable
        if initial == nil or initial == "" then
            initial = source and source.variable
        end
        if type(initial) == "table" then
            local encoded_ok, encoded = pcall(rapidjson.encode, initial)
            initial = encoded_ok and encoded or ""
        end
        self.source_variables[key] = tostring(initial or "")
    end
    return self.source_variables[key], key
end

local function encode_login_value(value)
    if type(value) == "table" then
        local encoded_ok, encoded = pcall(rapidjson.encode, value)
        return encoded_ok and encoded or "{}"
    end
    if value == nil or value == "" then
        return "{}"
    end
    return tostring(value)
end

function Javascript:restore_source_state(source, state)
    local key = source_key(source)
    state = type(state) == "table" and state or {}
    local initial_variable = state.sourceVariable
    if initial_variable == nil then
        initial_variable = source and source.variable
    end
    if type(initial_variable) == "table" then
        local encoded_ok, encoded = pcall(rapidjson.encode, initial_variable)
        initial_variable = encoded_ok and encoded or ""
    end
    self.source_variables[key] = tostring(initial_variable or "")
    local initial_login = state.loginInfo
    if initial_login == nil then
        initial_login = source and source.loginInfo
    end
    self.login_infos[key] = encode_login_value(decode_login_info(source, initial_login))
    self.login_headers[key] = state.loginHeader
    if source then
        source.__legado_login_header = state.loginHeader
    end
    self.arguments[key] = type(state.arguments) == "table" and state.arguments or {}
    self.store[key] = type(state.store) == "table" and state.store or {}
    self.cache[key] = type(state.cache) == "table" and state.cache or {}
    local explore_info = decode_object(state.exploreInfo) or {}
    self.explore_infos[key] = value_for_json(explore_info, 0, {}) or {}
end

function Javascript:explore_info(source)
    local key = source_key(source)
    if type(self.explore_infos[key]) ~= "table" then
        self.explore_infos[key] = {}
    end
    return self.explore_infos[key]
end

function Javascript:set_explore_info(source, value)
    local key = source_key(source)
    local decoded = decode_object(value) or {}
    self.explore_infos[key] = value_for_json(decoded, 0, {}) or {}
    return self.explore_infos[key]
end

function Javascript:export_source_state(source)
    local key = source_key(source)
    local variable = self.source_variables[key]
    if variable == nil then
        variable = self:source_variable(source, {})
    end
    local login_info = self.login_infos[key]
    if login_info == nil then
        login_info = encode_login_value(decode_login_info(source, source and source.loginInfo))
    end
    local login_header = self.login_headers[key]
    if login_header == nil then
        login_header = source and source.__legado_login_header
    end
    return {
        sourceVariable = tostring(variable or ""),
        loginInfo = tostring(login_info or "{}"),
        loginHeader = login_header,
        exploreInfo = value_for_json(self.explore_infos[key] or {}, 0, {}),
        arguments = value_for_json(self.arguments[key] or {}, 0, {}),
        store = value_for_json(self.store[key] or {}, 0, {}),
        cache = value_for_json(self.cache[key] or {}, 0, {}),
    }
end

function Javascript:set_login_info(source, value)
    self.login_infos[source_key(source)] = encode_login_value(value)
end

function Javascript:set_login_header(source, value)
    local key = source_key(source)
    self.login_headers[key] = value
    if source then source.__legado_login_header = value end
end

function Javascript:source_library(source)
    local raw = tostring(source and source.jsLib or "")
    if raw == "" then
        return ""
    end
    local source_id = source_key(source)
    local cached = self.library_cache[source_id]
    if cached and cached.raw == raw then
        return cached.value, cached.error
    end

    local library = raw
    local decoded_ok, decoded = pcall(rapidjson.decode, raw)
    local is_library_map = decoded_ok and type(decoded) == "table"
    if is_library_map then
        for name in pairs(decoded) do
            if type(name) ~= "string" then
                is_library_map = false
                break
            end
        end
    end
    if is_library_map then
        local names = {}
        for name in pairs(decoded) do
            names[#names + 1] = tostring(name)
        end
        table.sort(names)
        local pieces = {}
        for _, name in ipairs(names) do
            local item = decoded[name]
            if type(item) ~= "string" then
                item = tostring(item or "")
            end
            if item:match("^https?://") or item:match("^data:") then
                -- A mapped library is loaded before the rule itself, so a
                -- dynamic source header cannot be evaluated recursively yet.
                -- Use the normal KOReader defaults for this bootstrap fetch;
                -- subsequent java.ajax calls resolve the source header.
                local library_source = source
                if javascript_header(source) then
                    library_source = {}
                    for key, value in pairs(source or {}) do
                        library_source[key] = value
                    end
                    library_source.header = {}
                end
                local body, err = Network.get(item, library_source)
                if not body then
                    local message = "cannot load JavaScript library " .. name .. ": " .. tostring(err)
                    self.library_cache[source_id] = { raw = raw, error = message }
                    return nil, message
                end
                pieces[#pieces + 1] = body
            else
                pieces[#pieces + 1] = item
            end
        end
        library = table.concat(pieces, "\n")
    end
    self.library_cache[source_id] = { raw = raw, value = library }
    return library
end

function Javascript:host_call(operation, args, source, context)
    args = type(args) == "table" and args or {}
    local first = args[1]
    local second = args[2]
    local variable, source_id = self:source_variable(source, context)
    local stores = map_for(self.store, source_id)
    local caches = map_for(self.cache, source_id)
    local memory = map_for(self.memory, source_id)
    local arguments = map_for(self.arguments, source_id)
    local chapter_variables = map_for(self.chapter_variables, source_id)

    if operation == "ajax" then
        -- Network.get evaluates a dynamic source header with the current
        -- Legado context. Keeping that logic in one request path also makes
        -- post/get/connect and ajax behave identically and prevents a header
        -- script which performs an inner request from recursing forever.
        local request_options = request_options_with_context(second, context)
        local body, err = Network.get(tostring(first or ""), source, request_options)
        if body == nil then
            self:mark_fatal_error(err)
            return nil, err or "HTTP request failed"
        end
        return body
    elseif operation == "base64Encode" then
        return base64_encode(binary_string(first), args[2])
    elseif operation == "base64Decode" then
        local flags = type(args[2]) == "number" and args[2] or nil
        local decoded, decode_err = base64_decode(first or "", flags)
        if not decoded then return nil, decode_err end
        local charset = type(args[2]) == "string" and trim(args[2]) or ""
        if charset ~= "" then
            decoded = Network.convert_charset(decoded, charset, "UTF-8")
        end
        return decoded
    elseif operation == "base64DecodeBytes" then
        local decoded, decode_err = base64_decode(first or "", args[2])
        if not decoded then return nil, decode_err end
        return binary_marker(decoded)
    elseif operation == "hexDecodeToString" then
        return hex_decode(first or "")
    elseif operation == "hexDecode" or operation == "hexDecodeBytes" then
        local decoded, decode_err = hex_decode(first or "")
        if not decoded then return nil, decode_err end
        return operation == "hexDecode" and decoded or binary_marker(decoded)
    elseif operation == "hexEncode" then
        return (binary_string(first):gsub(".", function(char)
            return string.format("%02x", char:byte())
        end))
    elseif operation == "md5Encode" then
        return md5_hex(first or "")
    elseif operation == "md5Encode16" then
        local digest, err = md5_hex(first or "")
        if not digest then
            return nil, err
        end
        return digest:sub(9, 24)
    elseif operation == "strToBytes" then
        local value = tostring(first or "")
        local charset = trim(args[2] or "")
        if charset ~= "" then
            value = Network.convert_charset(value, "UTF-8", charset)
        end
        return binary_marker(value)
    elseif operation == "bytesLength" then
        return #binary_string(first)
    elseif operation == "bytesAt" then
        local bytes = binary_string(first)
        local index = (tonumber(second) or 0) + 1
        if index < 1 or index > #bytes then return -1 end
        return bytes:byte(index)
    elseif operation == "bytesToArray" then
        return binary_array(first)
    elseif operation == "bytesFromArray" then
        local values = type(first) == "table" and first or {}
        local output = {}
        for _, value in ipairs(values) do
            output[#output + 1] = string.char((tonumber(value) or 0) % 256)
        end
        return binary_marker(table.concat(output))
    elseif operation == "bytesSlice" then
        local bytes = binary_string(first)
        local start = math.max(0, tonumber(second) or 0)
        local finish = args[3] == nil and #bytes or math.max(0, tonumber(args[3]) or 0)
        if finish < start then return binary_marker("") end
        return binary_marker(bytes:sub(start + 1, finish))
    elseif operation == "bytesToStr" then
        local value = binary_string(first)
        local charset = trim(args[2] or "")
        if charset ~= "" then
            value = Network.convert_charset(value, charset, "UTF-8")
        end
        return value
    elseif operation == "crypto.decrypt" or operation == "crypto.encrypt" then
        local decrypt = operation == "crypto.decrypt"
        local input = args[4]
        if decrypt and type(input) ~= "table" then
            local decoded, decode_err = decode_cipher_string(input)
            if not decoded then return nil, decode_err end
            input = binary_marker(decoded)
        end
        local output, crypto_err = crypto_transform(
            first, second, args[3], input, decrypt
        )
        if not output then return nil, crypto_err end
        return decrypt and binary_marker(output) or binary_marker(output)
    elseif operation == "crypto.decryptStr" then
        local input = args[4]
        if type(input) ~= "table" then
            local decoded, decode_err = decode_cipher_string(input)
            if not decoded then return nil, decode_err end
            input = binary_marker(decoded)
        end
        local output, crypto_err = crypto_transform(first, second, args[3], input, true)
        if not output then return nil, crypto_err end
        return output
    elseif operation == "crypto.encryptBase64" then
        local output, crypto_err = crypto_transform(first, second, args[3], args[4], false)
        if not output then return nil, crypto_err end
        return base64_encode(output)
    elseif operation == "crypto.encryptHex" then
        local output, crypto_err = crypto_transform(first, second, args[3], args[4], false)
        if not output then return nil, crypto_err end
        return (output:gsub(".", function(char) return string.format("%02x", char:byte()) end))
    elseif operation == "crypto.asym.encrypt" or operation == "crypto.asym.decrypt" then
        local decrypt = operation == "crypto.asym.decrypt"
        local input = args[4]
        if decrypt and type(input) ~= "table" then
            local decoded, decode_err = decode_cipher_string(input)
            if not decoded then return nil, decode_err end
            input = binary_marker(decoded)
        end
        local output, asym_err = crypto_asymmetric_transform(
            first, second, args[3], input, decrypt, args[5] ~= false
        )
        if not output then return nil, asym_err end
        return binary_marker(output)
    elseif operation == "crypto.asym.decryptStr" then
        local input = args[4]
        if type(input) ~= "table" then
            local decoded, decode_err = decode_cipher_string(input)
            if not decoded then return nil, decode_err end
            input = binary_marker(decoded)
        end
        local output, asym_err = crypto_asymmetric_transform(
            first, second, args[3], input, true, args[5] ~= false
        )
        if not output then return nil, asym_err end
        return output
    elseif operation == "crypto.asym.encryptBase64"
            or operation == "crypto.asym.encryptHex" then
        local output, asym_err = crypto_asymmetric_transform(
            first, second, args[3], args[4], false, args[5] ~= false
        )
        if not output then return nil, asym_err end
        if operation == "crypto.asym.encryptBase64" then
            return base64_encode(output)
        end
        return (output:gsub(".", function(char) return string.format("%02x", char:byte()) end))
    elseif operation == "crypto.sign" or operation == "crypto.signHex" then
        local output, sign_err = crypto_sign(args[4], first, args[3])
        if not output then return nil, sign_err end
        if operation == "crypto.sign" then return binary_marker(output) end
        return (output:gsub(".", function(char) return string.format("%02x", char:byte()) end))
    elseif operation == "digest" then
        local output, digest_err = crypto_digest(first, second)
        if not output then return nil, digest_err end
        return binary_marker(output)
    elseif operation == "digestHex" or operation == "digestBase64" then
        local output, digest_err = crypto_digest(first, second)
        if not output then return nil, digest_err end
        return operation == "digestHex"
            and output:gsub(".", function(char) return string.format("%02x", char:byte()) end)
            or base64_encode(output)
    elseif operation == "hmac" or operation == "hmacHex" or operation == "hmacBase64" then
        local output, hmac_err = crypto_hmac(first, second, args[3])
        if not output then return nil, hmac_err end
        if operation == "hmac" then return binary_marker(output) end
        return operation == "hmacHex"
            and output:gsub(".", function(char) return string.format("%02x", char:byte()) end)
            or base64_encode(output)
    elseif operation == "source.getVariable" then
        return variable
    elseif operation == "source.setVariable" then
        self.source_variables[source_id] = tostring(first or "")
        if source then source.variable = self.source_variables[source_id] end
        return self.source_variables[source_id]
    elseif operation == "source.getLoginInfo" then
        if self.login_infos[source_id] == nil then
            self.login_infos[source_id] = encode_login_value(
                decode_login_info(source, source and source.loginInfo)
            )
        end
        return self.login_infos[source_id]
    elseif operation == "source.getLoginInfoMap" then
        if self.login_infos[source_id] == nil then
            self.login_infos[source_id] = encode_login_value(
                decode_login_info(source, source and source.loginInfo)
            )
        end
        local decoded_ok, decoded = pcall(rapidjson.decode, self.login_infos[source_id])
        return decoded_ok and type(decoded) == "table" and decoded or {}
    elseif operation == "source.getKey" then
        return tostring(source and source.bookSourceUrl or "")
    elseif operation == "source.getTag" then
        return tostring(source and (source.bookSourceName or source.bookSourceUrl) or "")
    elseif operation == "source.getLoginHeader" then
        local login_header = self.login_headers[source_id]
        if login_header == nil then login_header = source and source.__legado_login_header end
        return login_header == nil and "" or login_header
    elseif operation == "source.getLoginHeaderMap" then
        local login_header = self.login_headers[source_id]
        if login_header == nil then login_header = source and source.__legado_login_header end
        return decode_object(login_header) or {}
    elseif operation == "source.getHeaderMap" then
        if first ~= false then
            local headers, headers_err = Network.headers(source, context)
            if not headers then return nil, headers_err end
            return headers
        end
        return source_header_map(source, first ~= false)
    elseif operation == "source.putLoginInfo" then
        local value = second ~= nil and second or first
        self.login_infos[source_id] = encode_login_value(value)
        if source then source.loginInfo = self.login_infos[source_id] end
        return self.login_infos[source_id]
    elseif operation == "source.removeLoginInfo" then
        self.login_infos[source_id] = "{}"
        if source then source.loginInfo = "{}" end
        return ""
    elseif operation == "source.putLoginHeader" then
        local value = second ~= nil and second or first
        if type(value) == "table" then
            local encoded_ok, encoded = pcall(rapidjson.encode, value)
            value = encoded_ok and encoded or "{}"
        end
        self:set_login_header(source, value == nil and "" or tostring(value))
        local login_map = decode_object(value)
        local cookie = login_map and (login_map.Cookie or login_map.cookie)
        if cookie and source then
            Network.cookie_set(source.bookSourceUrl or "", tostring(cookie))
        end
        return self.login_headers[source_id]
    elseif operation == "source.removeLoginHeader" then
        self:set_login_header(source, nil)
        if source then Network.cookie_remove(source.bookSourceUrl or "") end
        return ""
    elseif operation == "source.get" then
        local key = tostring(first or "")
        if stores[key] ~= nil then return stores[key] end
        return source and source[key]
    elseif operation == "source.put" then
        local key = tostring(first or "")
        stores[key] = second
        if source then source[key] = second end
        return second
    elseif operation == "source.refreshJSLib" or operation == "refreshJSLib" then
        self.library_cache[source_id] = nil
        return ""
    elseif operation == "source.refreshExplore" or operation == "refreshExplore" then
        return ""
    elseif operation == "infoMap.save" then
        -- Legado's InfoMap is a source-local mutable map.  JavaScript runs in
        -- a separate QuickJS context, so a direct `infoMap[key] = value`
        -- cannot update the Lua table by reference.  The map shim sends an
        -- explicit snapshot when a source calls save()/saveNow(); keeping it
        -- source-scoped prevents discovery filters from leaking between
        -- imported sources.
        self:set_explore_info(source, first)
        return ""
    elseif operation == "source.putConcurrent" then
        self.concurrent_rates[source_id] = tostring(first or "")
        if source then source.concurrentRate = self.concurrent_rates[source_id] end
        return self.concurrent_rates[source_id]
    elseif operation == "source.login" then
        -- Avoid recursively entering a login() implementation that itself
        -- calls source.login(). The ordinary Runtime.login_source path remains
        -- the owner of the action result and persisted session.
        if context and context.__legado_in_source_login then return "" end
        local login_url = trim(source and source.loginUrl or "")
        if login_url == "" then return "" end
        local login_context = shallow_copy(context or {})
        login_context.__legado_in_source_login = true
        local result, _, login_err = self:evaluate_script(
            source,
            login_url,
            login_context,
            context and context.result or "",
            "login()"
        )
        if login_err then return nil, login_err end
        return result
    elseif operation == "getString" or operation == "getStringList"
            or operation == "getElement" or operation == "getElements" then
        local Rules = require("legado/rules")
        local content = host_content(context, second)
        local is_url = args[3] == true
        local values, parse_err
        if operation == "getElements" then
            values, parse_err = Rules.elements(content, tostring(first or ""), context)
            if not values then
                return nil, parse_err
            end
            local result = {}
            for _, value in ipairs(values) do
                local marker = Rules.element_to_marker(value)
                result[#result + 1] = marker or value
            end
            return result
        end
        if operation == "getElement" then
            -- AnalyzeRule.getElement returns an Element, whereas
            -- getString/getStringList return scalar text. Calling
            -- parse_list here loses the Jsoup object and breaks sources that
            -- subsequently call element.select()/attr()/parent().
            local elements, elements_err = Rules.elements(
                content, tostring(first or ""), context
            )
            if not elements then
                return nil, elements_err
            end
            local marker = Rules.element_to_marker(elements[1])
            return marker or elements[1] or ""
        end
        values, parse_err = Rules.parse_list(content, tostring(first or ""), context)
        if not values then
            return nil, parse_err
        end
        if operation == "getElement" then
            local marker = Rules.element_to_marker(values[1])
            return marker or values[1] or ""
        end
        if operation == "getStringList" then
            local result = {}
            for _, value in ipairs(values) do
                if type(value) == "table" and (value.__legado_element or value.__legado_html) then
                    result[#result + 1] = Rules.element_property(value, "text")
                else
                    result[#result + 1] = tostring(value or "")
                end
            end
            if is_url then
                local absolute = {}
                for _, value in ipairs(result) do
                    absolute[#absolute + 1] = Network.absolute(
                        context and context.baseUrl or source and source.bookSourceUrl or "",
                        value
                    )
                end
                return absolute
            end
            return result
        end
        if is_url then
            local absolute = {}
            for _, value in ipairs(values) do
                absolute[#absolute + 1] = Network.absolute(
                    context and context.baseUrl or source and source.bookSourceUrl or "",
                    tostring(value or "")
                )
            end
            return table.concat(absolute, "\n")
        end
        return table.concat(values, "\n")
    elseif operation == "setContent" then
        if context then
            context.result = first or ""
            if args[2] ~= nil and tostring(args[2]) ~= "" then
                context.baseUrl = tostring(args[2])
            end
        end
        return ""
    elseif operation == "post" then
        local header_argument = args[3]
        local options = type(header_argument) == "table" and header_argument or {}
        if type(header_argument) == "string" then
            options = decode_object(header_argument) or {}
        end
        local has_request_options = options.method ~= nil or options.headers ~= nil
            or options.header ~= nil or options.body ~= nil
        if not has_request_options then
            options = {
                method = "POST",
                body = second,
                headers = next(options) ~= nil and options or nil,
            }
        else
            local copied = {}
            for key, value in pairs(options) do copied[key] = value end
            copied.method = copied.method or "POST"
            copied.body = copied.body == nil and second or copied.body
            options = copied
        end
        options.timeout = options.timeout or args[4]
        options = request_options_with_context(options, context)
        local response, err = Network.get_response(tostring(first or ""), source, options)
        if not response then
            self:mark_fatal_error(err)
            return nil, err or "HTTP request failed"
        end
        return response
    elseif operation == "getStrResponse" then
        local request_url = tostring(args[3] or context and context.baseUrl or "")
        local request_headers = type(args[4]) == "table" and args[4] or decode_object(args[4])
        local request_source = source
        if request_headers then
            request_source = {}
            for key, value in pairs(source or {}) do request_source[key] = value end
            request_source.header = request_headers
        end
        local script = type(first) == "string" and first or ""
        local source_regex = type(second) == "string" and second or ""
        if script ~= "" or source_regex ~= "" then
            local Browser = require("legado/browser")
            local browser_headers, headers_err = Network.browser_headers(request_source, context)
            if not browser_headers then return nil, headers_err end
            local browser_result, browser_err = Browser.await(request_url, {
                source = request_source,
                headers = browser_headers,
                cookies = Network.export_cookies(),
                script = script,
                source_regex = source_regex ~= "" and source_regex or nil,
                auto = true,
            })
            if not browser_result then
                self:mark_fatal_error(browser_err)
                return nil, browser_err
            end
            if browser_result.cookies then Network.merge_cookies(browser_result.cookies) end
            return browser_result
        end
        local response, err = Network.get_response(
            request_url, request_source,
            request_options_with_context({}, context)
        )
        if not response then
            self:mark_fatal_error(err)
            return nil, err or "HTTP request failed"
        end
        return response
    elseif operation == "getResponse" or operation == "connect" then
        local request_url = tostring(first or (context and context.baseUrl or ""))
        local request_options
        if type(second) == "table" then
            if second.headers or second.header or second.method or second.body then
                request_options = second
            else
                request_options = { headers = second }
            end
        elseif type(second) == "string" then
            local decoded = decode_object(second)
            request_options = decoded and { headers = decoded } or nil
        end
        request_options = request_options_with_context(request_options, context)
        request_options.timeout = request_options.timeout or args[3]
        local response, err = Network.get_response(request_url, source, request_options)
        if not response then
            self:mark_fatal_error(err)
            return nil, err or "HTTP request failed"
        end
        return response
    elseif operation == "get" or operation == "head" then
        local request_options = {
            method = operation == "head" and "HEAD" or "GET",
            headers = type(second) == "table" and second or decode_object(second),
            timeout = args[3],
        }
        request_options = request_options_with_context(request_options, context)
        local response, err = Network.get_response(
            tostring(first or ""), source, request_options
        )
        if not response then
            self:mark_fatal_error(err)
            return nil, err or "HTTP request failed"
        end
        return response
    elseif operation == "initUrl" then
        if context and first and tostring(first) ~= "" then
            context.baseUrl = tostring(first)
        end
        return tostring(context and (context.baseUrl or context.result) or "")
    elseif operation == "url.absolute" then
        local url = require("socket.url")
        local ok, value = pcall(url.absolute, tostring(first or ""), tostring(second or ""))
        return ok and value or tostring(second or "")
    elseif operation == "ajaxAll" or operation == "ajaxTestAll" then
        local result = {}
        local list = type(first) == "table" and first or {}
        local timeout = operation == "ajaxTestAll" and tonumber(second) or nil
        for _, url in ipairs(list) do
            local options = {}
            if timeout and timeout > 0 then options.timeout = timeout end
            options = request_options_with_context(options, context)
            local response, response_err = Network.get_response(
                tostring(url or ""), source, options
            )
            if not response then
                self:mark_fatal_error(response_err)
                return nil, response_err or "HTTP request failed"
            end
            result[#result + 1] = response
        end
        return result
    elseif operation == "element.property" or operation == "element.children"
            or operation == "element.parent" or operation == "element.attributes" then
        local Rules = require("legado/rules")
        if operation == "element.property" then
            return Rules.element_property(first, tostring(second or ""))
        elseif operation == "element.children" then
            return Rules.element_children(first)
        elseif operation == "element.parent" then
            return Rules.element_parent(first)
        end
        return Rules.element_attributes(first)
    elseif operation == "importScript" then
        local path = tostring(first or "")
        local body
        local err
        if path:match("^https?://") or path:match("^data:") then
            body, err = Network.get(path, source, request_options_with_context({}, context))
        else
            body, err = read_js_text_file(path)
        end
        if not body or body == "" then
            self:mark_fatal_error(err)
            return nil, err or "JavaScript library import failed"
        end
        return body
    elseif operation == "readFile" then
        local path, path_err = js_file_path(first)
        if not path then return nil, path_err end
        local content = read_binary_file(path)
        if content == nil then return nil end
        return binary_marker(content)
    elseif operation == "file.exists" or operation == "file.isFile"
            or operation == "file.isDirectory" or operation == "file.list" then
        local path, path_err = js_file_path(first)
        if not path then return nil, path_err end
        local mode = lfs.attributes(path, "mode")
        if operation == "file.exists" then
            return mode ~= nil
        elseif operation == "file.isFile" then
            return mode == "file"
        elseif operation == "file.isDirectory" then
            return mode == "directory"
        end
        local result = {}
        if mode == "directory" then
            local relative = normalized_relative_path(first)
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then
                    result[#result + 1] = "/" .. relative .. "/" .. name
                end
            end
            table.sort(result)
        end
        return result
    elseif operation == "cacheFile" then
        local body, cache_err = cache_js_file(source, first, second)
        if not body then return nil, cache_err end
        return body
    elseif operation == "downloadFile" then
        local content, url
        if second == nil or tostring(second) == "" then
            url = tostring(first or "")
        else
            content = tostring(first or "")
            url = tostring(second)
        end
        local path, download_err = download_js_file(source, content, url)
        if not path then return nil, download_err end
        return path
    elseif operation == "readTxtFile" then
        local content, read_err = read_js_text_file(first, second)
        if content == nil then return nil, read_err end
        return content
    elseif operation == "deleteFile" then
        local path, path_err = js_file_path(first)
        if not path then return nil, path_err end
        remove_tree(path)
        return true
    elseif operation == "getTxtInFolder" then
        local content, folder_err = get_txt_in_folder(first)
        if content == nil then return nil, folder_err end
        return content
    elseif operation == "unArchiveFile" or operation == "unzipFile"
            or operation == "unrarFile" or operation == "un7zFile" then
        local path, archive_err = archive_extract(first)
        if not path then return nil, archive_err end
        return path
    elseif operation == "archiveString" then
        local content, archive_err = archive_string_content(
            source, first, second, args[3]
        )
        if content == nil then return nil, archive_err end
        return content
    elseif operation == "archiveBytes" then
        local content, archive_err = archive_string_content(
            source, first, second, nil
        )
        if content == nil then return nil, archive_err end
        return binary_marker(content)
    elseif operation == "htmlFormat" then
        return html_format(first)
    elseif operation == "toNumChapter" then
        return to_num_chapter(first)
    elseif operation == "encodeURI" then
        return Network.url_encode(first or "", second)
    elseif operation == "queryTTF" or operation == "queryBase64TTF" then
        -- Font substitution belongs to KOReader's reader pipeline. Expose a
        -- stable, inspectable placeholder to source scripts so a source that
        -- merely probes the Android helper can continue without changing its
        -- text/content rules; replaceFont remains an identity operation.
        return { __legado_ttf = true }
    elseif operation == "replaceFont" then
        return tostring(first or "")
    elseif operation == "cache.get" then
        return cache_entry_value(caches, first)
    elseif operation == "cache.put" then
        return cache_entry_put(caches, first, second, args[3])
    elseif operation == "cache.delete" or operation == "cache.remove"
            or operation == "cache.deleteFile" then
        local key = tostring(first or "")
        caches[key] = nil
        invalidate_file_cache(key)
        return ""
    elseif operation == "cache.getFile" then
        return cache_entry_value(caches, first)
    elseif operation == "cache.putFile" then
        return cache_entry_put(caches, first, second, args[3])
    elseif operation == "store.get" or operation == "variable.get" then
        local key = first == nil and "" or tostring(first)
        if operation == "variable.get" and first == nil then
            return variable
        end
        return stores[key]
    elseif operation == "store.put" or operation == "variable.set" then
        local key = tostring(first or "")
        stores[key] = second
        return second
    elseif operation == "store.delete" or operation == "store.remove" then
        stores[tostring(first or "")] = nil
        return ""
    elseif operation == "memory.get" then
        return memory[tostring(first or "")]
    elseif operation == "memory.put" then
        memory[tostring(first or "")] = second
        return second
    elseif operation == "memory.delete" then
        memory[tostring(first or "")] = nil
        return ""
    elseif operation == "book.getVariableMap" then
        local books = map_for(self.book_variables, source_id)
        local key = book_key(context)
        local current = books[key]
        if type(current) ~= "table" then
            current = context_variable_map(context, "book")
            books[key] = current
        end
        return current
    elseif operation == "book.getBigVariable" or operation == "book.getVariable" then
        local books = map_for(self.book_variables, source_id)
        local key = book_key(context)
        local current = books[key]
        if type(current) ~= "table" then
            current = context_variable_map(context, "book")
            books[key] = current
        end
        return type(current) == "table" and current[tostring(first or "")] or nil
    elseif operation == "book.setBigVariable" or operation == "book.setVariable" then
        local books = map_for(self.book_variables, source_id)
        local key = book_key(context)
        local current = books[key]
        if type(current) ~= "table" then
            current = context_variable_map(context, "book")
            books[key] = current
        end
        current[tostring(first or "")] = second
        set_context_variable_map(context, "book", current)
        return second
    elseif operation == "chapter.getVariableMap" then
        local key = chapter_key(context)
        local current = chapter_variables[key]
        if type(current) ~= "table" then
            current = context_variable_map(context, "chapter")
            chapter_variables[key] = current
        end
        return current
    elseif operation == "chapter.getBigVariable" or operation == "chapter.getVariable" then
        local key = chapter_key(context)
        local current = chapter_variables[key]
        if type(current) ~= "table" then
            current = context_variable_map(context, "chapter")
            chapter_variables[key] = current
        end
        return type(current) == "table" and current[tostring(first or "")] or nil
    elseif operation == "chapter.setBigVariable" or operation == "chapter.setVariable" then
        local key = chapter_key(context)
        local current = chapter_variables[key]
        if type(current) ~= "table" then
            current = context_variable_map(context, "chapter")
            chapter_variables[key] = current
        end
        current[tostring(first or "")] = second
        set_context_variable_map(context, "chapter", current)
        return second
    elseif operation == "cookie.get" then
        return Network.cookie_get(tostring(first or ""))
    elseif operation == "cookie.set" then
        return Network.cookie_set(tostring(first or ""), tostring(second or ""))
    elseif operation == "cookie.replace" then
        Network.cookie_remove(tostring(first or ""))
        return Network.cookie_set(tostring(first or ""), tostring(second or ""))
    elseif operation == "cookie.remove" then
        return Network.cookie_remove(tostring(first or ""))
    elseif operation == "cookie.key" then
        return Network.cookie_key(tostring(first or ""), tostring(second or ""))
    elseif operation == "sleep" then
        local milliseconds = tonumber(first) or 0
        if milliseconds > 0 then socket.sleep(math.min(30, milliseconds / 1000)) end
        return ""
    elseif operation == "userAgent" then
        return Network.user_agent()
    elseif operation == "timeFormat" then
        return formatted_time(first, second, false)
    elseif operation == "timeFormatUTC" then
        return formatted_time(first, second, true)
    elseif operation == "randomUUID" then
        return random_uuid()
    elseif operation == "t2s" then
        return convert_common_chinese(first, false)
    elseif operation == "s2t" then
        return convert_common_chinese(first, true)
    elseif operation == "logType" then
        return tostring(type(first))
    elseif operation == "deviceId" or operation == "androidId" then
        return "kindle"
    elseif operation == "openUrl" then
        local url = trim(first or "")
        if url ~= "" then
            self.notifications = self.notifications or {}
            if #self.notifications < 32 then
                self.notifications[#self.notifications + 1] = {
                    operation = "openUrl",
                    message = url,
                }
            end
        end
        return ""
    elseif operation == "getVerificationCode" then
        return nil, "interactive image verification is not available from a background Kindle source action"
    elseif operation == "argument.get" then
        return arguments[tostring(first or "")]
    elseif operation == "argument.set" then
        arguments[tostring(first or "")] = second
        return second
    elseif operation == "arguments.get" then
        if second == nil or tostring(second) == "" then
            return arguments
        end
        local key = tostring(second)
        local candidate = first
        if type(candidate) == "string" then
            local decoded_ok, decoded = pcall(rapidjson.decode, candidate)
            if decoded_ok then
                candidate = decoded
            end
        end
        if type(candidate) == "table" then
            return candidate[key]
        end
        return nil
    elseif operation == "arguments.set" then
        arguments[tostring(first or "")] = second
        return second
    elseif operation == "webView" or operation == "webViewSource"
            or operation == "webViewOverride" then
        local Browser = require("legado/browser")
        local html = type(first) == "string" and first or nil
        local url = tostring(second or context and context.baseUrl or "")
        local script = type(args[3]) == "string" and args[3] or ""
        local source_regex = operation == "webViewSource" and tostring(args[4] or "") or nil
        local override_url_regex = operation == "webViewOverride"
            and tostring(args[4] or "") or nil
        local browser_headers, headers_err = Network.browser_headers(source, context)
        if not browser_headers then return nil, headers_err end
        local browser_result, browser_err = Browser.await(url, {
            source = source,
            headers = browser_headers,
            cookies = Network.export_cookies(),
            html = html,
            script = script,
            source_regex = source_regex,
            override_url_regex = override_url_regex,
            auto = true,
        })
        if not browser_result then
            self:mark_fatal_error(browser_err)
            return nil, browser_err or "WebView evaluation failed"
        end
        if browser_result.cookies then Network.merge_cookies(browser_result.cookies) end
        return browser_result.body or ""
    elseif operation == "startBrowserAwait"
            or operation == "startBrowser"
            or operation == "startBrowserDp"
            or operation == "showBrowser"
            or operation == "showReadingBrowser" then
        -- Legado's Android implementation opens a WebView, waits for the
        -- user to finish the page, then returns the resulting document and
        -- cookies.  Keep this host operation source-independent: the Kindle
        -- browser bridge supplies the UI while the source's own JavaScript
        -- remains responsible for interpreting the returned page.
        local Browser = require("legado/browser")
        local browser_headers, headers_err = Network.browser_headers(source, context)
        if not browser_headers then
            return nil, headers_err or "cannot prepare browser request headers"
        end
        local waits_for_result = operation == "startBrowserAwait"
        local browser_result, browser_err = Browser.await(tostring(first or ""), {
            title = second,
            refetch_after_success = waits_for_result and args[3] ~= false or false,
            html = waits_for_result and args[4] or args[3],
            context = context,
            source = source,
            headers = browser_headers,
            cookies = Network.export_cookies(),
        })
        if not browser_result then
            self:mark_fatal_error(browser_err)
            return nil, browser_err or "browser interaction failed"
        end
        if browser_result.cookies then
            Network.merge_cookies(browser_result.cookies)
        end
        if not waits_for_result then
            return ""
        end
        return browser_result
    elseif operation == "log" or operation == "toast" then
        -- Source-side status is often communicated only through a toast or a
        -- log call.  Returning it to the UI is more useful than silently
        -- discarding it, and the bounded list prevents a noisy source from
        -- consuming the Kindle's limited memory.
        local message = trim(first == nil and "" or first)
        if message ~= "" and not is_expected_fallback_log(operation, message) then
            self.notifications = self.notifications or {}
            if #self.notifications < 32 then
                self.notifications[#self.notifications + 1] = {
                    operation = operation,
                    message = message,
                }
            end
        end
        return ""
    elseif operation == "unsupported" then
        return nil, "Legado JavaScript capability is unavailable on Kindle: " .. tostring(first or "unknown")
    end
    return nil, "unknown Legado JavaScript host operation: " .. tostring(operation)
end

local function split_rule(value)
    local rule = trim(value)
    local lowered = rule:lower()
    if lowered:match("^@webjs:") then
        return nil, nil, "WebView JavaScript is not available on Kindle"
    end
    if lowered:match("^@js:") then
        return rule:sub(5), ""
    end
    if lowered:match("^<js>") then
        local close_start, close_end = lowered:find("</js>", 5, true)
        if not close_start then
            return nil, nil, "unterminated <js> rule"
        end
        return rule:sub(5, close_start - 1), rule:sub(close_end + 1)
    end
    return nil
end

local function expand_script_templates(engine, source, script, context, content)
    if not script:find("{{", 1, true) then
        return script
    end
    local Rules = require("legado/rules")
    local template_context = shallow_copy(context)
    template_context.result = content
    template_context.src = content
    template_context.__legado_template_content = content
    -- Inline templates inside JavaScript use `$.field` for the current JSON
    -- item.  When the item came from a JSONPath list it is already a plain Lua
    -- table; expose the same root that context_with_content() exposes for
    -- ordinary rules.  Without this, Jk-style rules reach QuickJS with a
    -- literal `$.field` and fail before their request can be built.
    if type(content) == "table" and type(content.select) ~= "function"
            and content.__legado_element == nil and content.__legado_html == nil then
        template_context["$"] = content
    elseif type(content) == "string" then
        local first = content:match("^%s*(.)")
        if first == "{" or first == "[" then
            local ok, decoded = pcall(rapidjson.decode, content)
            if ok then template_context["$"] = decoded end
        end
    end
    -- `Runtime.context_for` normally supplies this closure. Keep a direct
    -- Javascript caller useful too (login/source-library actions can reach
    -- the evaluator without going through a Runtime stage).
    if type(template_context.__js_eval) ~= "function" then
        template_context.__js_eval = function(expression, current_content, current_context)
            return engine:evaluate_rule(
                source,
                expression,
                current_context or template_context,
                current_content
            )
        end
    end
    local expanded, expand_err = Rules.expand_templates(script, template_context)
    if not expanded then
        return nil, "JavaScript inline rule: " .. tostring(expand_err)
    end
    return expanded
end

function Javascript:evaluate_rule(source, rule, context, content)
    local lowered_rule = trim(rule or ""):lower()
    if lowered_rule:match("^@webjs:") then
        local web_evaluator = context and context.__web_eval
        if type(web_evaluator) ~= "function" then
            return nil, nil, "WebView JavaScript requires a browser evaluator"
        end
        local value, web_err = web_evaluator(
            tostring(rule):sub(8),
            content,
            context
        )
        if web_err then return nil, nil, web_err end
        return value, ""
    end
    local script, suffix, split_err = split_rule(rule)
    if not script then
        return nil, nil, split_err or "not a JavaScript rule"
    end
    if not self.bridge then
        return nil, nil, self.bridge_path
    end

    context = context or {}
    -- Legado expands the same inline-rule syntax inside a JavaScript source
    -- rule that it expands in an URL or selector.  This is easy to miss when
    -- moving the evaluator to a separate QuickJS process: a script such as
    -- `book_id={{$.book_id}}` otherwise reaches QuickJS with literal `{{` and
    -- fails to compile.  Expand only the executable body; the trailing rule
    -- after `</js>` must remain available to the generic rule parser.
    local expanded_script, template_err = expand_script_templates(
        self, source, script, context, content
    )
    if not expanded_script then
        return nil, nil, template_err
    end
    script = expanded_script
    local js_context = {}
    for key, value in pairs(context) do
        if key ~= "_js_eval" and (type(key) ~= "string" or key:sub(1, 2) ~= "__") then
            js_context[key] = value_for_json(value)
        end
    end
    content = element_content(content)
    local estimated_output_size = INITIAL_OUTPUT_SIZE
    if type(content) == "string" then
        -- JSON.stringify can escape a string, so leave room for expansion.
        -- This is only a sizing hint; the native bridge still enforces the
        -- hard maximum and reports a useful error for pathological sources.
        estimated_output_size = math.max(
            estimated_output_size,
            math.min(MAX_OUTPUT_SIZE, #content * 2 + 64 * 1024)
        )
    end
    js_context.result = value_for_json(content)
    js_context.key = tostring(context.key or "")
    js_context.page = tonumber(context.page or 1) or 1
    js_context.baseUrl = tostring(context.baseUrl or "")
    js_context.sourceUrl = tostring(source and source.bookSourceUrl or "")
    js_context.sourceName = tostring(source and source.bookSourceName or "")
    js_context.sourceComment = tostring(source and source.bookSourceComment or "")
    js_context.sourceHeader = source and source.header or ""
    js_context.sourceData = value_for_json(source or {})
    js_context.sourceVariable = self:source_variable(source, context)
    js_context.infoMap = value_for_json(
        context.infoMap or self:explore_info(source), 0, {}
    )
    js_context.rssArticle = value_for_json(context.rssArticle)
    js_context.src = value_for_json(content)
    js_context.nextChapterUrl = tostring(context.nextChapterUrl or "")
    js_context.isFromBookInfo = context.isFromBookInfo == true
    js_context.hasLoginUi = true
    js_context.deviceMode = "kindle"
    js_context.bookKey = book_key(context)

    local context_json, context_err = safe_json(js_context)
    if not context_json then
        return nil, nil, "cannot encode JavaScript context: " .. tostring(context_err)
    end
    local library, library_err = self:source_library(source)
    if not library then
        return nil, nil, library_err
    end
    if source and source.mainJs and source.mainJs ~= "" then
        library = library .. "\n" .. tostring(source.mainJs)
    end
    local output_ok, output_err = self:ensure_output_buffer(estimated_output_size)
    if not output_ok then
        return nil, nil, output_err
    end
    local output = self.output_buffer
    local output_size = self.output_size
    local batch_contexts = context.__legado_batch_contexts
    local active_context = context
    local callback
    callback = ffi.cast("legado_js_host_callback", function(operation_ptr, arguments_ptr, output_ptr, output_capacity)
        local ok, response, response_err = pcall(function()
            local operation = ffi.string(operation_ptr)
            local raw_args = ffi.string(arguments_ptr)
            local args_ok, args = pcall(rapidjson.decode, raw_args)
            if not args_ok then
                return nil, "invalid JavaScript host arguments: " .. tostring(args)
            end
            if operation == "__legado_batch_context" then
                local index = tonumber(type(args) == "table" and args[1])
                if type(batch_contexts) ~= "table"
                        or not index or type(batch_contexts[index]) ~= "table" then
                    return nil, "invalid JavaScript batch context index"
                end
                active_context = batch_contexts[index]
                return ""
            end
            return self:host_call(operation, args, source, active_context)
        end)
        if not ok then
            local callback_error = response
            response = nil
            response_err = tostring(callback_error)
        end
        local encoded
        if response_err then
            encoded = rapidjson.encode({ __legado_error = tostring(response_err) })
        else
            local encoded_ok, encoded_value = pcall(rapidjson.encode, response)
            if not encoded_ok then
                encoded = rapidjson.encode({ __legado_error = tostring(encoded_value) })
            else
                encoded = encoded_value
            end
        end
        local capacity = tonumber(output_capacity) or 0
        if capacity <= #encoded then
            return 1
        end
        ffi.copy(output_ptr, encoded .. "\0")
        return 0
    end)
    self.callback = callback
    local ok, result_code = pcall(function()
        return self.bridge.legado_js_eval(
            library,
            script,
            context_json,
            callback,
            output,
            output_size
        )
    end)
    self.callback = nil
    callback:free()
    if not ok then
        return nil, nil, "QuickJS bridge call failed: " .. tostring(result_code)
    end
    if tonumber(result_code) ~= 0 then
        local message = ffi.string(output)
        return nil, nil, "JavaScript rule failed: " .. (message ~= "" and message or "unknown error")
    end
    local output_text = ffi.string(output)
    local decoded_ok, value = pcall(rapidjson.decode, output_text)
    if not decoded_ok then
        return nil, nil, "JavaScript result is not JSON: " .. tostring(value)
    end
    return value, suffix or ""
end

-- A TOC rule is often a small JavaScript expression evaluated once for every
-- chapter.  Starting a new QuickJS runtime for each item is particularly
-- expensive on the 32-bit Kindle.  Pure/read-only item rules can be evaluated
-- in one bridge call while keeping the source rule itself unchanged.
local BATCH_UNSAFE_TOKENS = {
    "ajax", "post", "importscript", "startbrowser", "showbrowser", "webview",
    "setvariable", "setcontent", "setcookie", "removecookie", "putlogininfo",
    "setargument", "setmemory", "putmemory", "cache.put", "cache.delete",
    "memory.put", "memory.delete", "java.put", "source.set", "book.set",
    "settimeout", "eval(", "globalthis.",
}

function Javascript:is_batch_safe_rule(rule)
    local script, suffix = split_rule(rule)
    if not script or (suffix and trim(suffix) ~= "") then
        return false
    end
    local lowered = script:lower()
    for _, token in ipairs(BATCH_UNSAFE_TOKENS) do
        if lowered:find(token, 1, true) then
            return false
        end
    end
    return true
end

function Javascript:evaluate_rule_batch(source, rule, contexts, contents)
    local script, suffix, split_err = split_rule(rule)
    if not script then
        return nil, nil, split_err or "not a JavaScript rule"
    end
    if suffix and trim(suffix) ~= "" then
        return nil, nil, "batch JavaScript rules require an empty trailing rule"
    end
    if type(contexts) ~= "table" or type(contents) ~= "table"
            or #contexts ~= #contents or #contents == 0 then
        return nil, nil, "invalid JavaScript batch arguments"
    end

    local first_context = contexts[1] or {}
    local batch_items = {}
    for index, content in ipairs(contents) do
        local item_context = contexts[index] or first_context
        local item_script, template_err = expand_script_templates(
            self, source, script, item_context, content
        )
        if not item_script then
            return nil, nil, template_err
        end
        local item = {
            result = content,
            script = item_script,
            key = item_context.key,
            page = item_context.page,
            baseUrl = item_context.baseUrl,
            index = item_context.index,
            title = item_context.title,
            host = item_context.host,
        }
        -- The book/chapter values are normally shared across a TOC page. Do
        -- not duplicate a potentially large book object into every item, but
        -- retain an explicitly different value for generic source rules.
        if item_context.book ~= first_context.book then
            item.book = item_context.book
        end
        if item_context.chapter ~= first_context.chapter then
            item.chapter = item_context.chapter
        end
        batch_items[index] = item
    end

    local batch_context = {}
    for key, value in pairs(first_context) do
        if key ~= "result" and key ~= "__js_eval" and key ~= "_js_eval" then
            batch_context[key] = value
        end
    end
    -- Keys beginning with __ are excluded by value_for_json(), but remain
    -- available to the Lua callback so host calls can use the active item
    -- context (book/chapter variables, setContent and nested rules).
    batch_context.__legado_batch_contexts = contexts
    batch_context.batch_script = script

    -- Function() gives every item its own lexical scope, so source rules that
    -- declare `let`/`const` do not collide on the second chapter. The final
    -- expression is intentionally the array itself: evaluate_rule executes
    -- the wrapper as a JavaScript script, not as a function body.
    local batch_wrapper = [=[
const __legado_items = Array.isArray(result) ? result : [];
const __legado_output = [];
const __legado_default_key = globalThis.key;
const __legado_default_page = globalThis.page;
const __legado_default_base_url = globalThis.baseUrl;
const __legado_default_index = globalThis.index;
const __legado_default_title = globalThis.title;
const __legado_default_book = globalThis.book;
const __legado_default_chapter = globalThis.chapter;
const __legado_default_host = globalThis.host;
for (let __legado_i = 0; __legado_i < __legado_items.length; __legado_i++) {
    const __legado_item = __legado_items[__legado_i] || {};
    __legado_host("__legado_batch_context", [__legado_i + 1]);
    globalThis.result = __legado_item.result;
    globalThis.key = __legado_item.key === undefined ? __legado_default_key : __legado_item.key;
    globalThis.page = __legado_item.page === undefined ? __legado_default_page : __legado_item.page;
    globalThis.baseUrl = __legado_item.baseUrl === undefined ? __legado_default_base_url : __legado_item.baseUrl;
    globalThis.index = __legado_item.index === undefined ? __legado_default_index : __legado_item.index;
    globalThis.title = __legado_item.title === undefined ? __legado_default_title : __legado_item.title;
    globalThis.book = __legado_bind_rule_object(
        __legado_item.book === undefined ? __legado_default_book : (__legado_item.book || {}),
        "book"
    );
    globalThis.chapter = __legado_bind_rule_object(
        __legado_item.chapter === undefined ? __legado_default_chapter : (__legado_item.chapter || {}),
        "chapter"
    );
    globalThis.host = __legado_item.host === undefined ? __legado_default_host : (__legado_item.host || []);
    const __legado_code = String(__legado_item.script === undefined ? (__ctx.batch_script || "") : __legado_item.script);
    const __legado_function = Function("__legado_code", "return eval(__legado_code);");
    const __legado_value = __legado_function.call(globalThis, __legado_code);
    __legado_output.push(__legado_value === undefined ? null : __legado_value);
}
__legado_output
]=]

    local value, result_suffix, eval_err = self:evaluate_rule(
        source,
        "<js>" .. batch_wrapper .. "</js>",
        batch_context,
        batch_items
    )
    if eval_err then
        return nil, nil, eval_err
    end
    if type(value) ~= "table" or #value ~= #contents then
        return nil, nil, "JavaScript batch result length does not match TOC items"
    end
    return value, result_suffix or ""
end

-- Legado stores a few lifecycle hooks (for example ruleToc.formatJs) as raw
-- JavaScript rather than as a <js> rule.  Evaluate those hooks through the
-- same sandbox so all source-side state and host calls behave consistently.
function Javascript:evaluate_script(source, script, context, content, invocation)
    local value = trim(script or "")
    if value == "" then
        return "", ""
    end
    if invocation and invocation ~= "" then
        local lowered = value:lower()
        if lowered:match("^<js>") then
            local close_start, close_end = lowered:find("</js>", 5, true)
            if not close_start then
                return nil, nil, "unterminated <js> rule"
            end
            value = value:sub(1, close_start - 1) .. "\n" .. invocation .. value:sub(close_start)
        else
            value = value .. "\n" .. invocation
        end
    end
    if value:lower():match("^<js>") or value:lower():match("^@js:") then
        return self:evaluate_rule(source, value, context, content)
    end
    return self:evaluate_rule(source, "<js>" .. value .. "</js>", context, content)
end

return Javascript
