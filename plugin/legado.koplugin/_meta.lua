local GetText = require("gettext")

-- KOReader keeps one gettext instance for the whole application.  Load the
-- plugin catalog into that instance instead of changing KOReader's locale or
-- importing Android UI preferences.  The catalog is loaded before the
-- metadata strings below are evaluated, so the plugin name and description
-- are localized as well.
local function normalize_locale(locale)
    if type(locale) ~= "string" or locale == "" or locale == "C" then
        return nil
    end
    locale = locale:gsub("%..*$", ""):gsub("-", "_")
    if locale == "" then return nil end
    return locale
end

local function plugin_directory()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    return source:match("^(.*)[/\\][^/\\]+$") or "plugins/legado.koplugin"
end

local function load_plugin_catalog()
    local locale = normalize_locale(
        G_reader_settings and G_reader_settings:readSetting("language")
            or GetText.current_lang
    )
    if not locale then return end

    local locales = { locale }
    local base = locale:match("^([^_]+)")
    if base and base ~= locale then
        table.insert(locales, base)
    end

    local directories = {
        plugin_directory(),
        "plugins/legado.koplugin",
        "/mnt/us/koreader/plugins/legado.koplugin",
    }
    local seen = {}
    for _, directory in ipairs(directories) do
        for _, candidate_locale in ipairs(locales) do
            local path = directory .. "/l10n/" .. candidate_locale .. "/legado.mo"
            if not seen[path] and GetText.loadMO(path) then
                return
            end
            seen[path] = true
        end
    end
end

load_plugin_catalog()

local _ = GetText

return {
    name = "legado",
    fullname = _("Legado"),
    description = _("Read Legado text novels in KOReader"),
    version = "0.3.1",
}
