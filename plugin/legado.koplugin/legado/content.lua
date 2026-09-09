-- Content processing for network novels.
--
-- Android Legado does not send the result of a source rule straight to the
-- reader. It first runs the result through ContentProcessor: duplicate
-- chapter titles are removed, source HTML is converted to reader paragraphs,
-- replacements are applied by the source/runtime, and empty/whitespace-only
-- paragraphs are discarded. KOReader owns the final typography; this module
-- only produces safe, predictable text/XHTML structure.

local Content = {}
local IDEOGRAPHIC_SPACE = "　"

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
    numsp = " ",
    puncsp = " ",
    nnbsp = " ",
    zerowidthjoiner = "",
    zwj = "",
    zwnj = "",
    shy = "",
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

-- HTML containers which are never prose. The source rule should normally
-- select the chapter body, but a number of aggregate sources return a whole
-- document or an outerHTML fragment. Skipping these containers prevents
-- JavaScript, CSS, SVG paths and hidden templates from becoming novel text.
local ignored_containers = {
    audio = true,
    canvas = true,
    head = true,
    object = true,
    script = true,
    style = true,
    noscript = true,
    iframe = true,
    frame = true,
    frameset = true,
    svg = true,
    template = true,
    video = true,
}

-- Block tags are converted to line boundaries before tags are removed. The
-- later paragraph pass collapses repeated boundaries, matching Android's
-- `split("\\n").trim().filter { it.isNotEmpty() }` behavior.
local block_tags = {
    address = true,
    article = true,
    aside = true,
    blockquote = true,
    dd = true,
    div = true,
    dl = true,
    dt = true,
    fieldset = true,
    figcaption = true,
    figure = true,
    footer = true,
    form = true,
    h1 = true,
    h2 = true,
    h3 = true,
    h4 = true,
    h5 = true,
    h6 = true,
    header = true,
    hr = true,
    li = true,
    main = true,
    nav = true,
    ol = true,
    p = true,
    pre = true,
    section = true,
    table = true,
    tbody = true,
    td = true,
    tfoot = true,
    th = true,
    thead = true,
    tr = true,
    ul = true,
}

local omitted_elements = {
    embed = true,
    image = true,
    img = true,
    input = true,
    source = true,
    track = true,
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
    return (text:gsub("&[#%a][#%w%s-]*;", function(entity)
        return decode_entity(entity) or entity
    end))
end

local function strip_ideographic_edge_spaces(value)
    while value:sub(1, #IDEOGRAPHIC_SPACE) == IDEOGRAPHIC_SPACE do
        value = value:sub(#IDEOGRAPHIC_SPACE + 1)
    end
    while #value >= #IDEOGRAPHIC_SPACE
            and value:sub(-#IDEOGRAPHIC_SPACE) == IDEOGRAPHIC_SPACE do
        value = value:sub(1, #value - #IDEOGRAPHIC_SPACE)
    end
    return value
end

local function trim_line(line)
    -- Android trims characters <= U+0020 and ideographic spaces at both ends.
    -- Lua patterns cannot express a UTF-8 codepoint class, so handle the
    -- ideographic space explicitly and only collapse horizontal ASCII space.
    line = line:gsub("[\t ]+", " ")
    line = strip_ideographic_edge_spaces(line)
    return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_tag_end(text, start)
    local quote
    for index = start + 1, #text do
        local char = text:sub(index, index)
        if quote then
            if char == quote then quote = nil end
        elseif char == '"' or char == "'" then
            quote = char
        elseif char == ">" then
            return index
        end
    end
    return nil
end

local function tag_name(raw)
    local name = raw:match("^<%s*/?%s*([%a][%w:_%-]*)")
    return name and name:lower() or nil
end

local function is_closing_tag(raw)
    return raw:match("^<%s*/") ~= nil
end

local function is_self_closing_tag(raw)
    return raw:match("/%s*>%s*$") ~= nil
end

local function find_closing_tag(text, start, wanted)
    local cursor = start
    while true do
        local close_start = text:find("</", cursor, true)
        if not close_start then return nil end
        local close_end = find_tag_end(text, close_start)
        if not close_end then return nil end
        local raw = text:sub(close_start, close_end)
        if tag_name(raw) == wanted then
            return close_start, close_end
        end
        cursor = close_end + 1
    end
end

local function html_to_text(value)
    local source = tostring(value or "")
    if source == "" then return "" end

    local output = {}
    local cursor = 1
    while cursor <= #source do
        local tag_start = source:find("<", cursor, true)
        if not tag_start then
            output[#output + 1] = source:sub(cursor)
            break
        end

        if tag_start > cursor then
            output[#output + 1] = source:sub(cursor, tag_start - 1)
        end

        if source:sub(tag_start, tag_start + 3) == "<!--" then
            local comment_end = source:find("-->", tag_start + 4, true)
            cursor = comment_end and comment_end + 3 or #source + 1
        elseif source:sub(tag_start, tag_start + 8):lower() == "<![cdata[" then
            local cdata_end = source:find("]]>", tag_start + 9, true)
            if cdata_end then
                output[#output + 1] = source:sub(tag_start + 9, cdata_end - 1)
                cursor = cdata_end + 3
            else
                output[#output + 1] = source:sub(tag_start + 9)
                cursor = #source + 1
            end
        elseif source:sub(tag_start, tag_start + 1) == "<!"
                or source:sub(tag_start, tag_start + 1) == "<?" then
            local declaration_end = find_tag_end(source, tag_start)
            cursor = declaration_end and declaration_end + 1 or #source + 1
        else
            local tag_end = find_tag_end(source, tag_start)
            if not tag_end then
                -- A less-than sign in prose is not necessarily a tag. Keep
                -- malformed trailing input visible instead of dropping it.
                output[#output + 1] = source:sub(tag_start)
                break
            end
            local raw = source:sub(tag_start, tag_end)
            local name = tag_name(raw)
            if not name then
                output[#output + 1] = "<"
                cursor = tag_start + 1
            else
                local closing = is_closing_tag(raw)
                if not closing and ignored_containers[name]
                        and not is_self_closing_tag(raw) then
                    local _, close_end = find_closing_tag(
                        source, tag_end + 1, name
                    )
                    -- An unclosed script/style/etc. is treated as running to
                    -- EOF. This is safer than leaking its contents as prose.
                    cursor = close_end and close_end + 1 or #source + 1
                elseif not closing and omitted_elements[name] then
                    -- Text-novel mode intentionally omits image/media
                    -- elements, including data URI SVG payloads and alt text.
                    cursor = tag_end + 1
                elseif block_tags[name] or name == "br" then
                    output[#output + 1] = "\n"
                    cursor = tag_end + 1
                else
                    -- Inline markup is removed, but its text children remain.
                    cursor = tag_end + 1
                end
            end
        end
    end
    return decode_entities(table.concat(output))
end

local function normalize_lines(value)
    local text = tostring(value or "")
    text = text:gsub("\r\n?", "\n")

    -- Do this before line splitting so a BOM or zero-width character cannot
    -- make a visually empty paragraph look non-empty.
    text = text:gsub("\239\187\191", "") -- UTF-8 BOM
    text = text:gsub("\194\160", " ") -- NBSP
    text = text:gsub("\226\128\139", "") -- zero-width space
    text = text:gsub("\226\128\175", "") -- narrow no-break space
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")

    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = trim_line(line)
        -- Android's final content list discards empty paragraphs. Keeping
        -- them here would create artificial blank pages and extra indent.
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

local function edge_punctuation(value)
    local punctuation = {
        "《", "》", "【", "】", "「", "」", "『", "』", "“", "”",
        "‘", "’", "（", "）", "：", "；", "，", "。", "！", "？",
        "、", "…", "—", "-", "_", ":", ";", ",", ".", "!", "?",
        "(", ")", "[", "]", "{", "}", '"', "'",
    }
    local changed = true
    while changed and value ~= "" do
        changed = false
        value = value:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
        value = strip_ideographic_edge_spaces(value)
        for _, mark in ipairs(punctuation) do
            if value:sub(1, #mark) == mark then
                value = value:sub(#mark + 1)
                changed = true
            end
            if value:sub(-#mark) == mark then
                value = value:sub(1, #value - #mark)
                changed = true
            end
        end
    end
    return value
end

local function title_key(value)
    value = trim_line(tostring(value or ""))
    value = value:gsub("[ \t]+", ""):gsub(IDEOGRAPHIC_SPACE, "")
    return edge_punctuation(value)
end

local function remove_duplicate_title(text, title, book_name)
    if tostring(title or "") == "" then return text, false end
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then lines[#lines + 1] = line end
    end
    if #lines == 0 then return text, false end

    local wanted = title_key(title)
    if wanted == "" then return text, false end
    local first = title_key(lines[1])
    if first == wanted or (book_name and first == title_key(book_name) .. wanted)
            or (first:sub(-#wanted) == wanted and #first <= #wanted + 12) then
        table.remove(lines, 1)
        return table.concat(lines, "\n"), true
    end

    -- Android's title regex also accepts a book-name prefix followed by
    -- whitespace/punctuation and the chapter title.
    if book_name and #lines >= 2
            and title_key(lines[1]) == title_key(book_name)
            and title_key(lines[2]) == wanted then
        table.remove(lines, 1)
        table.remove(lines, 1)
        return table.concat(lines, "\n"), true
    end
    return text, false
end

function Content.has_markup(value)
    if type(value) ~= "string" or value == "" then return false end
    return value:find("<%s*/?%s*[%a]", 1) ~= nil
end

-- The plugin-side equivalent of Android ContentProcessor.getContent().
-- `replaceRegex` remains in the generic source runtime because it must run
-- before HTML extraction for source-defined rules. This function handles the
-- post-extraction stages common to every source and cache path.
function Content.process(value, options)
    options = options or {}
    local text = normalize_lines(html_to_text(value))
    local same_title_removed = false
    if options.remove_same_title ~= false then
        text, same_title_removed = remove_duplicate_title(
            text, options.title, options.book_name
        )
    end
    return text, {
        same_title_removed = same_title_removed,
    }
end

function Content.to_text(value)
    return (Content.process(value, { remove_same_title = false }))
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
    -- ContentProcessor exposes one non-empty line as one reader paragraph.
    -- Representing that explicitly also lets KOReader's normal CSS control
    -- indent, paragraph spacing and font without an embedded reader profile.
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        paragraph = trim_line(paragraph)
        if paragraph ~= "" then
            paragraphs[#paragraphs + 1] = "<p>" .. xml_escape(paragraph) .. "</p>"
        end
    end
    return table.concat(paragraphs, "\n")
end

return Content
