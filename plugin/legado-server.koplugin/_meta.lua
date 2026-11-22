local GetText = require("gettext")

local function normalize_locale(locale)
    if type(locale) ~= "string" or locale == "" or locale == "C" then
        return nil
    end
    locale = locale:gsub("%..*$", ""):gsub("-", "_")
    return locale ~= "" and locale or nil
end

local function plugin_directory()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    return source:match("^(.*)[/\\][^/\\]+$") or "plugins/legado-server.koplugin"
end

local function load_catalog()
    local locale = normalize_locale(
        G_reader_settings and G_reader_settings:readSetting("language")
            or GetText.current_lang
    )
    if not locale then return end

    local locales = { locale }
    local base = locale:match("^([^_]+)")
    if base and base ~= locale then table.insert(locales, base) end

    local directories = {
        plugin_directory(),
        "plugins/legado-server.koplugin",
        "/mnt/us/koreader/plugins/legado-server.koplugin",
    }
    local seen = {}
    for directory_index, directory in ipairs(directories) do
        for locale_index, candidate_locale in ipairs(locales) do
            local path = directory .. "/l10n/" .. candidate_locale .. "/legado-server.mo"
            if not seen[path] and GetText.loadMO(path) then return end
            seen[path] = true
        end
    end
end

load_catalog()

local _ = GetText

return {
    fullname = _("Legado server"),
    description = _("Sync published books and read offline with KOReader"),
    version = "0.3.10",
}
