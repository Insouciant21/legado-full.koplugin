-- Content normalization for network novels.
--
-- Android Legado normally hands the reader an HTML fragment.  Normalize it
-- before caching so tags and sometimes very large inline SVG attributes never
-- reach the reader. Keep this conversion small and dependency-free: it runs
-- after source rules/replacements have completed.

local Content = {}

local named_entities = {
    amp = "&",
    apos = "'",
    gt = ">",
    lt = "<",
    quot = '"',
    nbsp = " ",
    ensp = " ",
    emsp = "  ",
    thinsp = " ",
    hairsp = " ",
    hellip = "…",
    mdash = "—",
    ndash = "–",
    laquo = "«",
    raquo = "»",
    ldquo = "“",
    rdquo = "”",
    lsquo = "‘",
    rsquo = "’",
    middot = "·",
    bull = "•",
    copy = "©",
    reg = "®",
    trade = "™",
    times = "×",
    divide = "÷",
    minus = "−",
}

local function utf8_char(code)
    code = tonumber(code)
    if not code or code < 0 or code > 0x10ffff
            or (code >= 0xd800 and code <= 0xdfff) then
        return nil
    end
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xc0 + math.floor(code / 0x40),
            0x80 + (code % 0x40)
        )
    elseif code < 0x10000 then
        return string.char(
            0xe0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
        )
    end
    return string.char(
        0xf0 + math.floor(code / 0x40000),
        0x80 + (math.floor(code / 0x1000) % 0x40),
        0x80 + (math.floor(code / 0x40) % 0x40),
        0x80 + (code % 0x40)
    )
end

local function decode_entity(entity)
    local value = entity:sub(2, -2)
    local code
    if value:sub(1, 2):lower() == "#x" then
        code = tonumber(value:sub(3), 16)
    elseif value:sub(1, 1) == "#" then
        code = tonumber(value:sub(2), 10)
    else
        return named_entities[value:lower()]
    end
    return utf8_char(code)
end

local function decode_entities(text)
    return (text:gsub("&[#%a][#%w]*;", function(entity)
        return decode_entity(entity) or entity
    end))
end

local function add_line_breaks(text, tag)
    text = text:gsub("<%s*" .. tag .. "[^>]*>", "\n")
    text = text:gsub("<%s*/%s*" .. tag .. "%s*>", "\n")
    return text
end

local function trim_line(line)
    -- Only collapse horizontal ASCII whitespace.  `%s` also matches newlines
    -- in Lua patterns and would accidentally merge paragraph boundaries.
    line = line:gsub("[\t ]+", " ")
    -- Many Chinese web sources already prefix every paragraph with two
    -- ideographic spaces. The generated HTML supplies the conventional 2em
    -- paragraph indent, so keeping both would produce a visibly oversized
    -- blank area at the start of each paragraph.
    line = line:gsub("^[　]+", "")
    return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Content.has_markup(value)
    if type(value) ~= "string" or value == "" then return false end
    return value:find("<%s*/?%a", 1) ~= nil
end

function Content.to_text(value)
    local text = tostring(value or "")
    if text == "" then return "" end

    text = text:gsub("\r\n?", "\n")

    -- Match source output consistently even when a site emits uppercase HTML
    -- tag names.  Attribute values are left untouched.
    text = text:gsub("(<%s*/?%s*)([%a][%w:-]*)", function(prefix, tag)
        return prefix .. tag:lower()
    end)

    -- Remove non-content containers before stripping tags.  In particular,
    -- this prevents script/style text and malformed SVG bodies becoming prose.
    for _, tag in ipairs({ "script", "style", "noscript", "iframe", "svg", "head" }) do
        text = text:gsub("<%s*" .. tag .. "[^>]*>.-<%s*/%s*" .. tag .. "%s*>", "")
    end
    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<!%[CDATA%[.-%]%]>", "")

    -- Block boundaries must survive tag removal.  HTML-backed text sources
    -- commonly use <p>...</p>, with occasional <br> and <div>.
    for _, tag in ipairs({ "br", "hr", "p", "div", "section", "article",
        "blockquote", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6" }) do
        text = add_line_breaks(text, tag)
    end

    -- Images are intentionally omitted for this text-novel target.  Removing
    -- the complete element also removes data:image/svg+xml;base64 payloads.
    text = text:gsub("<%s*img%s+[^>]*>", "")
    text = text:gsub("<%s*image%s+[^>]*>", "")
    text = text:gsub("<[^>]*>", "")
    text = decode_entities(text)

    -- Common invisible/space characters found in copied web text.
    text = text:gsub("\239\187\191", "")
    text = text:gsub("\194\160", " ")
    text = text:gsub("\226\128\139", "")
    text = text:gsub("\226\128\175", "")
    local lines = {}
    for line in text:gmatch("[^\n]*") do
        lines[#lines + 1] = trim_line(line)
    end
    text = table.concat(lines, "\n")
    text = text:gsub("\n[ \t]+\n", "\n\n")
    text = text:gsub("\n\n\n+", "\n\n")
    text = text:gsub("^\n+", ""):gsub("\n+$", "")
    return text
end

local function xml_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
        :gsub("'", "&apos;")
    -- XML 1.0 does not permit these control characters.
    return value:gsub("[%z\1-\8\11\12\14-\31]", "")
end

function Content.xml_escape(value)
    return xml_escape(value)
end

function Content.to_xhtml(value)
    local text = Content.to_text(value)
    if text == "" then return "" end
    local paragraphs = {}
    for paragraph in (text .. "\n\n"):gmatch("(.-)\n\n") do
        paragraph = trim_line(paragraph)
        if paragraph ~= "" then
            paragraph = xml_escape(paragraph):gsub("\n", "<br/>\n")
            paragraphs[#paragraphs + 1] = "<p>" .. paragraph .. "</p>"
        end
    end
    return table.concat(paragraphs, "\n")
end

return Content
