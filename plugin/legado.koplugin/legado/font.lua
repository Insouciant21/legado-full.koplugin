-- Emoji font support for old Kindle builds.
--
-- KOReader on Kindle scans ./fonts before third-party plugins are loaded.  A
-- plugin-bundled font therefore gets copied into that directory on first use;
-- it is also registered with CRe when possible so the current reader can use
-- it without waiting for a second launch.

local FFIUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local EmojiFont = {
    family = "Symbola",
    source_path = "./plugins/legado.koplugin/assets/Symbola_hint.ttf",
    installed_path = "./fonts/legado/Symbola_hint.ttf",
    ui_fallback_path = "legado/Symbola_hint.ttf",
}

local function is_file(path)
    return lfs.attributes(path, "mode") == "file"
end

function EmojiFont:ensure_installed()
    if not is_file(self.source_path) then
        return false, false, "bundled emoji font is missing"
    end

    local source_size = lfs.attributes(self.source_path, "size")
    local installed_size = lfs.attributes(self.installed_path, "size")
    if is_file(self.installed_path) and source_size == installed_size then
        return true, false
    end

    if not util.makePath("./fonts/legado") then
        return false, false, "cannot create KOReader font directory"
    end

    local temporary_path = self.installed_path .. ".part"
    local copy_error = FFIUtil.copyFile(self.source_path, temporary_path)
    if copy_error then
        return false, false, "cannot install emoji font: " .. tostring(copy_error)
    end
    if not is_file(temporary_path)
            or lfs.attributes(temporary_path, "size") ~= source_size then
        return false, false, "installed emoji font is incomplete"
    end
    if not os.rename(temporary_path, self.installed_path) then
        return false, false, "cannot activate installed emoji font"
    end
    return true, true
end

function EmojiFont:enable_ui_fallback()
    local ok, Font = pcall(require, "ui/font")
    if not ok or type(Font) ~= "table" or type(Font.fallbacks) ~= "table" then
        return false
    end
    for _, path in ipairs(Font.fallbacks) do
        if path == self.ui_fallback_path then
            return true
        end
    end
    -- Keep KOReader's normal symbol and CJK fallbacks first. Symbola is an
    -- outline font and is used only when those fonts lack the character.
    Font.fallbacks[#Font.fallbacks + 1] = self.ui_fallback_path
    return true
end

function EmojiFont:register_with_cre()
    local ok, CreDocument = pcall(require, "document/credocument")
    if not ok or type(CreDocument) ~= "table"
            or type(CreDocument.engineInit) ~= "function" then
        return false
    end
    local registered = pcall(function()
        local cre = CreDocument:engineInit()
        -- LuaJIT FFI methods may be exposed as cdata rather than a Lua
        -- function.  Call it directly and let pcall report the real error.
        cre.registerFont(self.installed_path)
    end)
    return registered
end

function EmojiFont:add_document_fallback(document)
    if type(document) ~= "table" then return false end
    document.fallback_fonts = document.fallback_fonts or {}
    local present = false
    for _, family in ipairs(document.fallback_fonts or {}) do
        if family == self.family then
            present = true
            break
        end
    end
    if not present then
        -- Keep it first: KOReader users may disable its optional extra
        -- fallback list, in which case CRe intentionally keeps only the
        -- first fallback face.
        table.insert(document.fallback_fonts, 1, self.family)
    end
    if type(document.setupFallbackFontFaces) == "function" then
        document:setupFallbackFontFaces()
    end

    -- Be explicit as well as updating CreDocument's list. This preserves the
    -- emoji fallback even when an older KOReader setting asks CRe to keep only
    -- one fallback face.
    if document._document then
        local names = { self.family }
        local user_fallback = rawget(_G, "G_reader_settings")
            and G_reader_settings:readSetting("fallback_font")
        if user_fallback and user_fallback ~= self.family then
            names[#names + 1] = user_fallback
        end
        for _, family in ipairs(document.fallback_fonts) do
            if family ~= self.family and family ~= user_fallback then
                names[#names + 1] = family
            end
        end
        pcall(function()
            document._document:setStringProperty(
                "crengine.font.fallback.faces", table.concat(names, "|"))
        end)
    end
    return true
end

return EmojiFont
