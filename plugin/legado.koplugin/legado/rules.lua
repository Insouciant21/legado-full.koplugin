-- Common Legado rule support for the Kindle runtime.
--
-- The parser and selector library are part of KOReader's base runtime.  HTML,
-- JSON, XPath and the Legado selector dialect stay in Lua; JavaScript rules
-- are delegated through the evaluator callback supplied by runtime.lua.

local htmlparser = require("htmlparser")
local rapidjson = require("rapidjson")

local Rules = {}
local regex_values
local regex_elements
local lua_pattern_variants
local evaluate_js_rule
local evaluate_composite_rule

local function trim(value)
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function stringify(value)
    if value == nil then
        return ""
    elseif type(value) == "table" then
        local ok, encoded = pcall(rapidjson.encode, value)
        return ok and encoded or ""
    elseif type(value) == "boolean" then
        return value and "true" or "false"
    end
    return tostring(value)
end

local function is_js_rule(value)
    local lowered = trim(value or ""):lower()
    return lowered:match("^<js>") ~= nil
        or lowered:match("^@js:") ~= nil
        or lowered:match("^@webjs:") ~= nil
end

-- A leading `+` is Legado's AllInOne marker for list rules.  It changes how
-- the Android analyzer prepares a list item, but it is not part of the
-- selector itself.  Strip it at the generic entry points so it works for
-- search, discovery and TOC rules alike (including a `+<js>...</js>` rule).
local function strip_all_in_one_prefix(value)
    local text = trim(value or "")
    if text:sub(1, 1) == "+" then
        return trim(text:sub(2))
    end
    return text
end

local function js_evaluator(context)
    if type(context) ~= "table" then
        return nil
    end
    return context.__js_eval or context._js_eval
end

local function unwrap_element_array(values)
    if type(values) ~= "table" or #values ~= 1 or type(values[1]) ~= "table" then
        return values
    end
    local child = values[1]
    for key in pairs(child) do
        if type(key) ~= "number" then
            return values
        end
    end
    return child
end

local function clean_part(value)
    local left_trimmed = tostring(value):gsub("^%s+", "")
    if left_trimmed:lower():sub(1, 6) == "@text:" then
        -- Whitespace after @text: is part of the output.  This matters for
        -- rules such as "@text: - && @css:.author@text".
        return left_trimmed
    end
    return trim(value)
end

local function split_top_level(value, operators)
    local parts = {}
    local start = 1
    local bracket = 0
    local paren = 0
    local brace = 0
    local quote = nil
    local escaped = false
    local selected = nil
    local index = 1

    while index <= #value do
        local char = value:sub(index, index)
        local consumed = false
        if escaped then
            escaped = false
        elseif char == "\\" then
            escaped = true
        elseif quote then
            if char == quote then
                quote = nil
            end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == "[" then
            bracket = bracket + 1
        elseif char == "]" then
            bracket = math.max(0, bracket - 1)
        elseif char == "(" then
            paren = paren + 1
        elseif char == ")" then
            paren = math.max(0, paren - 1)
        elseif char == "{" then
            brace = brace + 1
        elseif char == "}" then
            brace = math.max(0, brace - 1)
        elseif bracket == 0 and paren == 0 and brace == 0 then
            for _, operator in ipairs(operators) do
                if value:sub(index, index + #operator - 1) == operator then
                    if selected == nil then
                        selected = operator
                    end
                    if selected == operator then
                        parts[#parts + 1] = value:sub(start, index - 1)
                        start = index + #operator
                        index = start
                        consumed = true
                    end
                    break
                end
            end
        end
        if not consumed then
            index = index + 1
        end
    end

    if selected == nil then
        return { clean_part(value) }, nil
    end
    parts[#parts + 1] = value:sub(start)
    for i, part in ipairs(parts) do
        parts[i] = clean_part(part)
    end
    return parts, selected
end

local function template_value(expression, context)
    local name = trim(expression)
    local value = context[name]
    if value ~= nil then
        return stringify(value)
    end

    local function lookup_path(root, path)
        local current = root
        for part in path:gmatch("[^%.%[%]]+") do
            local index = tonumber(part)
            if type(current) ~= "table" then
                return nil
            end
            if index then
                current = current[index + 1]
            else
                current = current[part]
            end
            if current == nil then
                return nil
            end
        end
        return current
    end

    local root_name, path = name:match("^([%w_]+)%.(.+)$")
    if root_name and context[root_name] ~= nil then
        value = lookup_path(context[root_name], path)
        if value ~= nil then
            return stringify(value)
        end
    elseif name:sub(1, 2) == "$." and context["$"] ~= nil then
        value = lookup_path(context["$"], name:sub(3))
        if value ~= nil then
            return stringify(value)
        end
    end

    local field, sign, amount = name:match("^(page)%s*([+-])%s*(%d+)$")
    if field then
        local page = tonumber(context.page or 1) or 1
        local number = tonumber(amount) or 0
        if sign == "-" then
            number = -number
        end
        return tostring(page + number)
    end

    local quote, literal = name:match("^(['\"])(.-)%1$")
    if quote then
        return literal
    end

    local template_content = context.__legado_template_content
    local evaluator = js_evaluator(context)
    local explicit_rule = name:sub(1, 1) == "@"
        or name:match("^//") ~= nil
        or name:match("^/") ~= nil
        or name:sub(1, 1) == ":"
    local function evaluate_template_js()
        if type(evaluator) ~= "function" then return false end
        local value, suffix, eval_err = evaluator(
            "<js>" .. name .. "</js>",
            template_content ~= nil and template_content or context.result or "",
            context
        )
        if eval_err then return false, eval_err end
        if suffix and trim(suffix) ~= "" then
            local values, suffix_err = Rules.json_result(value, trim(suffix))
            if not values then return false, suffix_err end
            return true, stringify(values)
        end
        return true, stringify(value)
    end

    -- In URL fields Legado treats {{...}} as JavaScript by default.  The
    -- same form is also used inside ordinary rules for expressions such as
    -- `{{java.base64Encode(key)}}` or `{{page - 1 == 0 ? '' : page}}`.
    -- Explicit selector forms (for example {{//meta/@content}} or
    -- {{@@.title@text}}) are parsed against the current document first;
    -- everything else gets the JavaScript interpretation first and can fall
    -- back to a selector when the expression is not valid JavaScript.
    if template_content == nil or not explicit_rule then
        local evaluated, eval_err = evaluate_template_js()
        if evaluated then return eval_err end
    end

    -- Legado also uses {{...}} for an inline rule evaluated against the
    -- current element, not only for a context variable.  Older source
    -- formats commonly write values such as
    -- <br>{{@[property="og:description"]@content}}.  Keep variable/path
    -- interpolation above, then fall back to the same generic rule parser so
    -- CSS, legacy selectors, JSON and regex expressions all work here.
    if template_content ~= nil then
        local parsed, parse_err = Rules.parse_text(template_content, name, context)
        if parsed ~= nil then
            return parsed
        end
        local evaluated, eval_err = evaluate_template_js()
        if evaluated then return eval_err end
        return nil, parse_err
    end
    return nil, "template requires JavaScript: " .. name
end

function Rules.expand_templates(value, context)
    context = context or {}
    local output = {}
    local cursor = 1
    while true do
        local start, finish, expression = tostring(value):find("{{(.-)}}", cursor)
        if not start then
            output[#output + 1] = tostring(value):sub(cursor)
            break
        end
        output[#output + 1] = tostring(value):sub(cursor, start - 1)
        local replacement, err = template_value(expression, context)
        if not replacement then
            return nil, err
        end
        output[#output + 1] = replacement
        cursor = finish + 1
    end
    return table.concat(output)
end

local function context_with_content(context, content)
    local result = {}
    for key, value in pairs(context or {}) do
        result[key] = value
    end
    result.__legado_template_content = content
    if type(content) == "table" and type(content.select) ~= "function" then
        result["$"] = content
    elseif type(content) == "string" then
        local first = content:match("^%s*(.)")
        if first == "{" or first == "[" then
            local ok, decoded = pcall(rapidjson.decode, content)
            if ok then
                result["$"] = decoded
            end
        end
    end
    return result
end

local function normalize_text(value)
    return trim(tostring(value):gsub("%s+", " "))
end

-- JavaScript executed by a source cannot receive KOReader's userdata
-- ElementNode directly.  javascript.lua therefore serializes an element as
-- an outer-HTML marker.  Keep the marker private to the bridge, but make it a
-- first-class input here so JavaScript can pass an element to
-- java.getString/getElements just like Android Legado does.
local function marker_html(value)
    if type(value) ~= "table" then
        return nil
    end
    local html = value.__legado_element or value.__legado_html
    return type(html) == "string" and html or nil
end

local function own_text(element)
    -- htmlparser does not expose text nodes separately.  Remove each direct
    -- child element by its source span instead of merely removing its tags;
    -- the latter promotes all descendant text to the parent and makes a rule
    -- such as `text.字数` match nearly the entire document.
    local root = element.root
    local source = root and root._text
    local inner_start = element._openend and element._openend + 1
    local inner_end = element._closestart and element._closestart - 1
    if not source or not inner_start or not inner_end or inner_end < inner_start then
        return normalize_text((element:getcontent() or ""):gsub("<[^>]*>", ""))
    end
    local parts = {}
    local cursor = inner_start
    for _, child in ipairs(element.nodes or {}) do
        local child_start = child._openstart
        local child_end = child._closeend or child._openend
        if child_start and child_end and child_start >= cursor and child_start <= inner_end + 1 then
            parts[#parts + 1] = source:sub(cursor, child_start - 1)
            cursor = math.max(cursor, child_end + 1)
        end
    end
    parts[#parts + 1] = source:sub(cursor, inner_end)
    return normalize_text(table.concat(parts))
end

local function outer_text(element)
    -- htmlparser keeps source offsets on every ElementNode.  `gettext()` is
    -- the node's text content, not Jsoup's outerHtml(), which matters when a
    -- JavaScript source passes an Element to java.getString(..., "outerHtml")
    -- or serializes it for a later rule.
    local root = element and element.root
    local source = root and root._text
    local start = element and element._openstart
    local finish = element and (element._closeend or element._openend)
    if source and start and finish and finish >= start then
        return source:sub(start, finish)
    end
    local ok, value = pcall(function() return element:gettext() end)
    return ok and tostring(value or "") or ""
end

local function element_value(element, mode)
    if mode == "text" then
        return normalize_text(element:textonly())
    elseif mode == "ownText" then
        return own_text(element)
    elseif mode == "textNodes" then
        return own_text(element)
    elseif mode == "html" then
        return element:getcontent() or ""
    elseif mode == "all" then
        return outer_text(element)
    end
    return element.attributes[mode] or ""
end

local parse_html

local function marker_element(value)
    local html = marker_html(value)
    if not html then
        return nil
    end
    local root, err = parse_html(html)
    if not root then
        return nil, err
    end
    for _, child in ipairs(root.nodes or {}) do
        if child.name then
            return child
        end
    end
    return root
end

local function is_element_node(value)
    local value_type = type(value)
    if value_type ~= "table" and value_type ~= "userdata" then
        return false
    end
    if marker_html(value) then
        return true
    end
    local ok, select = pcall(function()
        return value.select
    end)
    return ok and type(select) == "function"
end

local function simple_element_value(element, rule)
    if marker_html(element) then
        element = marker_element(element)
        if not element then
            return nil
        end
    end
    local mode = trim(rule)
    if mode == "text" or mode == "ownText" or mode == "textNodes"
            or mode == "html" or mode == "all" then
        return element_value(element, mode)
    end
    local attributes = element.attributes or {}
    if attributes[mode] ~= nil then
        return element_value(element, mode)
    end
    return nil
end

parse_html = function(content)
    local text = tostring(content)
    -- KOReader's htmlparser defaults to 1000 opening tags.  That is enough
    -- for a normal article but silently truncates large full-book TOCs before
    -- the requested selector is reached.
    -- Count only opening tags so the limit follows the actual document while
    -- retaining the parser's small default for short pages.
    local tag_count = 0
    for _ in text:gmatch("<%s*[%a]") do
        tag_count = tag_count + 1
    end
    local parse_limit = math.max(1000, tag_count + 64)
    local ok, root = pcall(htmlparser.parse, text, parse_limit)
    if not ok then
        return nil, "HTML parse failed: " .. tostring(root)
    end
    return root
end

local function split_at_signs(value)
    local pieces = {}
    for piece in tostring(value):gmatch("[^@]+") do
        pieces[#pieces + 1] = trim(piece)
    end
    return pieces
end

local function root_for(content)
    if type(content) == "table" and type(content.select) == "function" then
        return content
    end
    if marker_html(content) then
        return parse_html(marker_html(content))
    end
    return parse_html(content)
end

local function matching_parenthesis(value, opening)
    local depth = 1
    local quote
    for index = opening + 1, #value do
        local char = value:sub(index, index)
        if quote then
            if char == quote and value:sub(index - 1, index - 1) ~= "\\" then
                quote = nil
            end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == "(" then
            depth = depth + 1
        elseif char == ")" then
            depth = depth - 1
            if depth == 0 then
                return index
            end
        end
    end
    return nil
end

local function strip_runtime_pseudos(selector)
    local supported = {
        ["eq"] = true,
        ["lt"] = true,
        ["gt"] = true,
        ["first"] = true,
        ["last"] = true,
        ["even"] = true,
        ["odd"] = true,
        ["contains"] = true,
        ["has"] = true,
    }
    local output = {}
    local filters = {}
    local index = 1
    local bracket = 0
    local quote
    while index <= #selector do
        local char = selector:sub(index, index)
        if quote then
            output[#output + 1] = char
            if char == quote and selector:sub(index - 1, index - 1) ~= "\\" then
                quote = nil
            end
            index = index + 1
        elseif char == "'" or char == '"' then
            quote = char
            output[#output + 1] = char
            index = index + 1
        elseif char == "[" then
            bracket = bracket + 1
            output[#output + 1] = char
            index = index + 1
        elseif char == "]" then
            bracket = math.max(0, bracket - 1)
            output[#output + 1] = char
            index = index + 1
        elseif char == ":" and bracket == 0 then
            local name = selector:sub(index):match("^:([%w%-]+)")
            local lowered = name and name:lower() or nil
            if lowered and supported[lowered] then
                local opening = index + #name + 1
                local argument
                local finish = opening - 1
                if selector:sub(opening, opening) == "(" then
                    finish = matching_parenthesis(selector, opening)
                    if not finish then
                        return nil, nil, "unclosed CSS pseudo selector: " .. tostring(selector)
                    end
                    argument = selector:sub(opening + 1, finish - 1)
                end
                filters[#filters + 1] = { name = lowered, argument = argument }
                index = finish + 1
            else
                output[#output + 1] = char
                index = index + 1
            end
        else
            output[#output + 1] = char
            index = index + 1
        end
    end
    local base = trim(table.concat(output))
    if base == "" then
        base = "*"
    end
    return base, filters
end

local function element_position(element, same_tag)
    local parent = element.parent
    if not parent then
        return 0
    end
    local position = 0
    for _, sibling in ipairs(parent.nodes or {}) do
        if not same_tag or sibling.name == element.name then
            position = position + 1
        end
        if sibling == element then
            return position
        end
    end
    return 0
end

local function nth_matches(position, expression)
    expression = trim(tostring(expression or "")):lower()
    if expression == "odd" then
        return position % 2 == 1
    elseif expression == "even" then
        return position % 2 == 0
    end
    local number = tonumber(expression)
    if number then
        return position == number
    end
    local coefficient, offset = expression:match("^([%+%-]?%d*)n([%+%-]?%d*)$")
    if not coefficient then
        return false
    end
    if coefficient == "" or coefficient == "+" then
        coefficient = 1
    elseif coefficient == "-" then
        coefficient = -1
    else
        coefficient = tonumber(coefficient)
    end
    if offset == "" or offset == "+" then
        offset = 0
    else
        offset = tonumber(offset)
    end
    if not coefficient or not offset then
        return false
    end
    if coefficient == 0 then
        return position == offset
    end
    local count = (position - offset) / coefficient
    return count >= 0 and count % 1 == 0
end

local function pseudo_matches(element, filter)
    local name = filter.name
    if name == "first-child" then
        return element_position(element, false) == 1
    elseif name == "last-child" then
        local parent = element.parent
        return parent ~= nil and element_position(element, false) == #(parent.nodes or {})
    elseif name == "nth-child" then
        return nth_matches(element_position(element, false), filter.argument)
    elseif name == "first-of-type" then
        return element_position(element, true) == 1
    elseif name == "last-of-type" then
        local parent = element.parent
        local position = element_position(element, true)
        local total = 0
        if parent then
            for _, sibling in ipairs(parent.nodes or {}) do
                if sibling.name == element.name then total = total + 1 end
            end
        end
        return position > 0 and position == total
    elseif name == "nth-of-type" then
        return nth_matches(element_position(element, true), filter.argument)
    elseif name == "contains" then
        local value = trim(tostring(filter.argument or ""))
        value = value:gsub("^(['\"])(.-)%1$", "%2")
        return element:textonly():find(value, 1, true) ~= nil
    elseif name == "has" then
        local ok, children = pcall(function()
            return element:select(trim(tostring(filter.argument or "*")))
        end)
        return ok and children and #children > 0
    end
    return true
end

local function rewrite_css_regex_attributes(selector)
    local conditions = {}
    local rewritten = tostring(selector):gsub("%[([^%]]-)%]", function(segment)
        local attribute, expression = segment:match("^%s*([%w:_-]+)%s*~=%s*(.-)%s*$")
        if not attribute then
            return "[" .. segment .. "]"
        end
        expression = trim(expression):gsub("^(['\"])(.-)%1$", "%2")
        conditions[#conditions + 1] = {
            attribute = attribute,
            expression = expression,
        }
        return "[" .. attribute .. "]"
    end)
    if #conditions == 0 then
        return selector, nil
    end
    return rewritten, conditions
end

local function css_regex_matches(value, expression)
    local alternatives, operator = split_top_level(expression, { "|" })
    if operator == nil then
        alternatives = { expression }
    end
    for _, alternative in ipairs(alternatives) do
        local simple_word = trim(alternative):match("^[%w_%-]+$")
        if simple_word then
            for word in tostring(value or ""):gmatch("[^%s]+") do
                if word == simple_word then
                    return true
                end
            end
        end
        local patterns, pattern_err = lua_pattern_variants(alternative)
        if not patterns then
            return nil, pattern_err
        end
        for _, pattern in ipairs(patterns) do
            local ok, found = pcall(string.find, tostring(value or ""), pattern)
            if not ok then
                return nil, found
            end
            if found then
                return true
            end
        end
    end
    return false
end

-- htmlparser's selector implementation intentionally stays small.  Legado
-- sources, however, use the parts of CSS supported by Jsoup, including
-- sibling combinators and structural pseudo selectors.  Implement the
-- missing selector layer over ElementNode instead of teaching individual
-- sources about Kindle's parser.
local css_select_query
local css_matches_selector

local function css_unquote(value)
    value = trim(value or "")
    local quote = value:sub(1, 1)
    if (quote == "'" or quote == '"') and value:sub(-1) == quote then
        return value:sub(2, -2)
    end
    return value
end

local function css_unescape(value)
    return tostring(value or ""):gsub("\\(.)", "%1")
end

local function css_split_steps(selector)
    local steps = {}
    local buffer = {}
    local bracket = 0
    local paren = 0
    local quote
    local escaped = false
    local pending_space = false
    local pending_combinator

    local function flush()
        local value = trim(table.concat(buffer))
        if value ~= "" then
            steps[#steps + 1] = {
                selector = value,
                combinator = pending_combinator,
            }
            buffer = {}
            pending_combinator = nil
            pending_space = false
        end
    end

    local index = 1
    while index <= #selector do
        local char = selector:sub(index, index)
        if escaped then
            buffer[#buffer + 1] = char
            escaped = false
        elseif char == "\\" then
            buffer[#buffer + 1] = char
            escaped = true
        elseif quote then
            buffer[#buffer + 1] = char
            if char == quote then quote = nil end
        elseif char == "'" or char == '"' then
            buffer[#buffer + 1] = char
            quote = char
        elseif char == "[" then
            bracket = bracket + 1
            buffer[#buffer + 1] = char
        elseif char == "]" then
            bracket = math.max(0, bracket - 1)
            buffer[#buffer + 1] = char
        elseif char == "(" and bracket == 0 then
            paren = paren + 1
            buffer[#buffer + 1] = char
        elseif char == ")" and bracket == 0 then
            paren = math.max(0, paren - 1)
            buffer[#buffer + 1] = char
        elseif bracket == 0 and paren == 0 and char:match("%s") then
            if #buffer > 0 then
                flush()
            end
            pending_space = true
        elseif bracket == 0 and paren == 0
                and (char == ">" or char == "+" or char == "~") then
            flush()
            pending_combinator = char
            pending_space = false
        else
            if pending_space and #steps > 0 and pending_combinator == nil
                    and #buffer == 0 then
                -- The whitespace between two compounds is a descendant
                -- combinator.  Whitespace around >/+ /~ is ignored.
                pending_combinator = " "
            end
            buffer[#buffer + 1] = char
            pending_space = false
        end
        index = index + 1
    end
    flush()
    return steps
end

local function css_attribute_matches(actual, operator, wanted)
    wanted = css_unescape(css_unquote(wanted))
    actual = actual == nil and nil or tostring(actual)
    if operator == "" then return actual ~= nil end
    if actual == nil then return operator == "!=" end
    if operator == "=" then return actual == wanted end
    if operator == "!=" then return actual ~= wanted end
    if operator == "^=" then return actual:sub(1, #wanted) == wanted end
    if operator == "$=" then return wanted == "" or actual:sub(-#wanted) == wanted end
    if operator == "*=" then return actual:find(wanted, 1, true) ~= nil end
    if operator == "|=" then
        return actual == wanted or actual:sub(1, #wanted + 1) == wanted .. "-"
    end
    if operator == "~=" then
        if wanted:find("|", 1, true) then
            local matched = css_regex_matches(actual, wanted)
            return matched == true
        end
        for word in actual:gmatch("[^%s]+") do
            if word == wanted then return true end
        end
        return false
    end
    return false
end

local function css_next_siblings(element, include_all)
    local result = {}
    local parent = element and element.parent
    if not parent then return result end
    local found = false
    for _, sibling in ipairs(parent.nodes or {}) do
        if sibling == element then
            found = true
            if not include_all then break end
        elseif found then
            result[#result + 1] = sibling
            if not include_all then break end
        end
    end
    return result
end

local function css_element_children(element)
    local result = {}
    for _, child in ipairs(element and element.nodes or {}) do
        if child.name then result[#result + 1] = child end
    end
    return result
end

local function css_all_descendants(element, result)
    result = result or {}
    for _, child in ipairs(css_element_children(element)) do
        result[#result + 1] = child
        css_all_descendants(child, result)
    end
    return result
end

local function css_node_text(element)
    return tostring(element and element:textonly() or "")
end

local function css_parse_simple(selector)
    local result = { tag = "*", classes = {}, ids = {}, attributes = {}, pseudos = {} }
    local index = 1
    -- Lua patterns do not implement alternation. Parse the named-tag and
    -- wildcard forms separately; the old `...|%*` expression silently made
    -- every named tag fail and returned an empty selector result.
    local tag = selector:match("^([%a_][%w_:%-]*)")
    if tag then
        result.tag = css_unescape(tag)
        index = #tag + 1
    elseif selector:sub(1, 1) == "*" then
        index = 2
        if selector:sub(index, index) == "|" then
            index = index + 1
            local namespace = selector:match("^([%w_%-]+)%*", index)
            if namespace then
                index = index + #namespace + 1
                result.tag = "*"
            end
        end
    end
    while index <= #selector do
        local char = selector:sub(index, index)
        if char == "#" or char == "." then
            local name = selector:sub(index + 1):match("^([%w_:%-]+)")
            if not name or name == "" then
                return nil, "invalid CSS selector: " .. selector
            end
            name = css_unescape(name)
            if char == "#" then
                result.ids[#result.ids + 1] = name
            else
                result.classes[#result.classes + 1] = name
            end
            index = index + #name + 1
        elseif char == "[" then
            local depth = 1
            local cursor = index + 1
            local quote
            while cursor <= #selector and depth > 0 do
                local current = selector:sub(cursor, cursor)
                if quote then
                    if current == quote and selector:sub(cursor - 1, cursor - 1) ~= "\\" then
                        quote = nil
                    end
                elseif current == "'" or current == '"' then
                    quote = current
                elseif current == "[" then
                    depth = depth + 1
                elseif current == "]" then
                    depth = depth - 1
                end
                cursor = cursor + 1
            end
            if depth ~= 0 then return nil, "unclosed CSS attribute selector: " .. selector end
            local body = trim(selector:sub(index + 1, cursor - 2))
            local name, operator, value = body:match(
                "^([%w_:%*-]+)%s*([!~|%^%$*]?=?)%s*(.-)%s*$"
            )
            if not name then return nil, "invalid CSS attribute selector: " .. body end
            result.attributes[#result.attributes + 1] = {
                name = css_unescape(name), operator = operator or "", value = value or "",
            }
            index = cursor
        elseif char == ":" then
            local name = selector:sub(index + 1):match("^([%w%-]+)")
            if not name then return nil, "invalid CSS pseudo selector: " .. selector end
            local lowered = name:lower()
            local cursor = index + #name + 1
            local argument
            if selector:sub(cursor, cursor) == "(" then
                local finish = matching_parenthesis(selector, cursor)
                if not finish then return nil, "unclosed CSS pseudo selector: " .. selector end
                argument = selector:sub(cursor + 1, finish - 1)
                cursor = finish + 1
            end
            result.pseudos[#result.pseudos + 1] = { name = lowered, argument = argument }
            index = cursor
        elseif char:match("%s") then
            index = index + 1
        else
            return nil, "unsupported CSS selector token: " .. char
        end
    end
    return result
end

local function css_sibling_position(element, same_tag, from_end)
    local parent = element and element.parent
    if not parent then return 0, 0 end
    local siblings = {}
    for _, sibling in ipairs(parent.nodes or {}) do
        if not same_tag or sibling.name == element.name then
            siblings[#siblings + 1] = sibling
        end
    end
    local position
    for index, sibling in ipairs(siblings) do
        if sibling == element then position = index break end
    end
    if not position then return 0, #siblings end
    if from_end then position = #siblings - position + 1 end
    return position, #siblings
end

local function css_pseudo_matches(element, pseudo)
    local name = pseudo.name
    local parent = element and element.parent
    local position, total = css_sibling_position(element, false, false)
    if name == "root" then
        return parent ~= nil and parent.name == "root"
    elseif name == "first-child" then
        return position == 1
    elseif name == "last-child" then
        return position > 0 and position == total
    elseif name == "only-child" then
        return total == 1
    elseif name == "nth-child" then
        return nth_matches(position, pseudo.argument)
    elseif name == "nth-last-child" then
        local reverse = css_sibling_position(element, false, true)
        return nth_matches(reverse, pseudo.argument)
    elseif name == "first-of-type" then
        return css_sibling_position(element, true, false) == 1
    elseif name == "last-of-type" then
        local type_position, type_total = css_sibling_position(element, true, false)
        return type_position > 0 and type_position == type_total
    elseif name == "only-of-type" then
        local _, type_total = css_sibling_position(element, true, false)
        return type_total == 1
    elseif name == "nth-of-type" then
        local type_position = css_sibling_position(element, true, false)
        return nth_matches(type_position, pseudo.argument)
    elseif name == "nth-last-of-type" then
        local type_position = css_sibling_position(element, true, true)
        return nth_matches(type_position, pseudo.argument)
    elseif name == "empty" then
        return #css_element_children(element) == 0
            and trim((element:getcontent() or ""):gsub("<[^>]*>", "")) == ""
    elseif name == "contains" then
        local wanted = css_unquote(pseudo.argument or "")
        return css_node_text(element):find(wanted, 1, true) ~= nil
    elseif name == "has" then
        local found = css_select_query(element, trim(pseudo.argument or "*"))
        return found ~= nil and #found > 0
    elseif name == "not" then
        local nested = trim(pseudo.argument or "")
        local groups = split_top_level(nested, { "," })
        for _, group in ipairs(groups) do
            local parsed = css_parse_simple(trim(group))
            if parsed then
                local matches = true
                if parsed.tag ~= "*" and tostring(element.name):lower() ~= parsed.tag:lower() then
                    matches = false
                end
                for _, id in ipairs(parsed.ids) do
                    if tostring(element.id or "") ~= id then matches = false end
                end
                local classes = element.classes or {}
                for _, class in ipairs(parsed.classes) do
                    local found = false
                    for _, own in ipairs(classes) do if own == class then found = true break end end
                    if not found then matches = false end
                end
                for _, attribute in ipairs(parsed.attributes) do
                    if not css_attribute_matches(
                        element.attributes and element.attributes[attribute.name],
                        attribute.operator, attribute.value
                    ) then matches = false end
                end
                for _, child_pseudo in ipairs(parsed.pseudos) do
                    if not css_pseudo_matches(element, child_pseudo) then matches = false end
                end
                if matches then return false end
            end
        end
        return true
    end
    -- jQuery-style positional pseudo selectors are removed by
    -- strip_runtime_pseudos and applied to the result list afterwards.
    return true
end

local function css_simple_matches(element, selector)
    local parsed, err = css_parse_simple(selector)
    if not parsed then return nil, err end
    local tag = tostring(element and element.name or "")
    if parsed.tag ~= "*" and tag:lower() ~= tostring(parsed.tag):lower()
            and not tag:lower():match("[^:]+:" .. tostring(parsed.tag):lower() .. "$") then
        return false
    end
    for _, id in ipairs(parsed.ids) do
        if tostring(element.id or element.attributes and element.attributes.id or "") ~= id then
            return false
        end
    end
    local classes = element.classes or {}
    for _, wanted in ipairs(parsed.classes) do
        local found = false
        for _, own in ipairs(classes) do if own == wanted then found = true break end end
        if not found then return false end
    end
    for _, attribute in ipairs(parsed.attributes) do
        local actual = element.attributes and element.attributes[attribute.name]
        if not css_attribute_matches(actual, attribute.operator, attribute.value) then
            return false
        end
    end
    for _, pseudo in ipairs(parsed.pseudos) do
        if not css_pseudo_matches(element, pseudo) then return false end
    end
    return true
end

css_matches_selector = function(element, selector)
    local steps = css_split_steps(selector)
    if #steps == 0 then return false end
    -- This helper is primarily used by :not(:has(...)) with a simple subject;
    -- a full query is used for compound selectors.
    local last = steps[#steps]
    if #steps == 1 then
        return css_simple_matches(element, last.selector)
    end
    local found = css_select_query(element.root or element, selector)
    for _, candidate in ipairs(found or {}) do
        if candidate == element then return true end
    end
    return false
end

css_select_query = function(root, selector)
    local steps = css_split_steps(trim(selector or ""))
    if #steps == 0 then return {} end
    local current = { root }
    for _, step in ipairs(steps) do
        local candidates = {}
        local seen = {}
        for _, subject in ipairs(current) do
            local combinator = step.combinator
            local related
            if combinator == ">" then
                related = css_element_children(subject)
            elseif combinator == "+" then
                related = css_next_siblings(subject, false)
            elseif combinator == "~" then
                related = css_next_siblings(subject, true)
            elseif combinator == " " then
                related = css_all_descendants(subject)
            else
                related = css_all_descendants(subject)
            end
            for _, candidate in ipairs(related) do
                if not seen[candidate] then
                    seen[candidate] = true
                    local matches, match_err = css_simple_matches(candidate, step.selector)
                    if match_err then return nil, match_err end
                    if matches then candidates[#candidates + 1] = candidate end
                end
            end
        end
        current = candidates
    end
    table.sort(current, function(left, right)
        return (left.index or 0) < (right.index or 0)
    end)
    return current
end

local function select_css_group(root, selector)
    local base, filters, strip_err = strip_runtime_pseudos(selector)
    if not base then
        return nil, strip_err
    end
    local query, regex_conditions = rewrite_css_regex_attributes(base)
    local ok, elements = pcall(function()
        return css_select_query(root, query)
    end)
    if not ok then
        return nil, "CSS selector failed: " .. tostring(elements)
    end
    local filtered = {}
    for _, element in ipairs(elements or {}) do
        local matches = true
        if regex_conditions then
            for _, condition in ipairs(regex_conditions) do
                local value = element.attributes and element.attributes[condition.attribute]
                local condition_matches, condition_err = css_regex_matches(
                    value,
                    condition.expression
                )
                if condition_err then
                    return nil, "CSS attribute regex failed: " .. tostring(condition_err)
                end
                if not condition_matches then
                    matches = false
                    break
                end
            end
        end
        for _, filter in ipairs(filters) do
            if not ({
                eq = true, lt = true, gt = true, first = true, last = true,
                even = true, odd = true,
            })[filter.name] and not pseudo_matches(element, filter) then
                matches = false
                break
            end
        end
        if matches then
            filtered[#filtered + 1] = element
        end
    end
    for _, filter in ipairs(filters) do
        local target
        if filter.name == "eq" or filter.name == "lt" or filter.name == "gt" then
            target = tonumber(trim(tostring(filter.argument or "")))
            if target and target < 0 then target = #filtered + target end
        elseif filter.name == "first" then
            target = 0
        elseif filter.name == "last" then
            target = #filtered - 1
        end
        if filter.name == "eq" and target then
            local element = filtered[target + 1]
            filtered = element and { element } or {}
        elseif filter.name == "lt" and target then
            local result = {}
            for index, element in ipairs(filtered) do
                if index - 1 < target then result[#result + 1] = element end
            end
            filtered = result
        elseif filter.name == "gt" and target then
            local result = {}
            for index, element in ipairs(filtered) do
                if index - 1 > target then result[#result + 1] = element end
            end
            filtered = result
        elseif filter.name == "first" or filter.name == "last" then
            local element = filtered[(target or 0) + 1]
            filtered = element and { element } or {}
        elseif filter.name == "even" or filter.name == "odd" then
            local result = {}
            local wanted = filter.name == "even" and 0 or 1
            for index, element in ipairs(filtered) do
                if (index - 1) % 2 == wanted then result[#result + 1] = element end
            end
            filtered = result
        end
    end
    return filtered
end

local function select_css(root, selector)
    local groups, operator = split_top_level(selector, { "," })
    local all = {}
    local seen = {}
    for _, group in ipairs(groups) do
        local elements, err = select_css_group(root, group)
        if not elements then
            return nil, err
        end
        for _, element in ipairs(elements) do
            if not seen[element] then
                seen[element] = true
                all[#all + 1] = element
            end
        end
    end
    table.sort(all, function(left, right)
        return (left.index or 0) < (right.index or 0)
    end)
    return all
end

local function children_of(root)
    local result = {}
    for _, element in ipairs(root.nodes or {}) do
        result[#result + 1] = element
    end
    return result
end

local function parse_integer(value)
    value = trim(value)
    if value == "" then
        return nil
    end
    if not value:match("^-?%d+$") then
        return nil, "not an integer"
    end
    return tonumber(value)
end

local function parse_index_item(value)
    value = trim(value)
    local integer = parse_integer(value)
    if integer ~= nil then
        return integer
    end

    local pieces = {}
    for piece in value:gmatch("[^:]+") do
        pieces[#pieces + 1] = piece
    end
    local colon_count = 0
    for _ in value:gmatch(":") do
        colon_count = colon_count + 1
    end
    if #pieces == 0 or colon_count < 1 or colon_count > 2 then
        return nil
    end

    -- Keep omitted endpoints while parsing the range.  Splitting manually
    -- avoids treating CSS attribute selectors as numeric index syntax.
    local numbers = {}
    local number_count = 0
    local start = 1
    for index = 1, #value + 1 do
        if index > #value or value:sub(index, index) == ":" then
            local number, err = parse_integer(value:sub(start, index - 1))
            if err then
                return nil
            end
            number_count = number_count + 1
            numbers[number_count] = number
            start = index + 1
        end
    end
    if number_count ~= colon_count + 1 or number_count < 2 or number_count > 3 then
        return nil
    end
    return {
        kind = "range",
        start = numbers[1],
        finish = numbers[2],
        step = numbers[3] or 1,
    }
end

local function last_char_index(value, wanted)
    local found
    local cursor = 1
    while true do
        local index = value:find(wanted, cursor, true)
        if not index then
            return found
        end
        found = index
        cursor = index + 1
    end
end

local function parse_legacy_selector(expression)
    local value = trim(expression)

    if value:sub(-1) == "]" then
        local open = last_char_index(value, "[")
        if open then
            local body = trim(value:sub(open + 1, -2))
            local mode = "."
            if body:sub(1, 1) == "!" then
                mode = "!"
                body = trim(body:sub(2))
            end
            if body ~= "" then
                local items = {}
                local valid = true
                for item in body:gmatch("[^,]+") do
                    local parsed = parse_index_item(item)
                    if parsed == nil then
                        valid = false
                        break
                    end
                    items[#items + 1] = parsed
                end
                if valid and #items > 0 then
                    return trim(value:sub(1, open - 1)), mode, items
                end
            end
        end
    end

    local base, mode, suffix = value:match("^(.-)([.!])(-?%d[%d:%-]*)$")
    if not base then
        return nil
    end
    local items = {}
    for item in suffix:gmatch("[^:]+") do
        local parsed = parse_integer(item)
        if parsed == nil then
            return nil
        end
        items[#items + 1] = parsed
    end
    if #items == 0 then
        return nil
    end
    return trim(base), mode, items
end

local function normalize_index(index, length)
    if index >= 0 and index < length then
        return index + 1
    elseif index < 0 and length >= -index then
        return index + length + 1
    end
    return nil
end

local function add_index(selected, seen, index)
    if index and not seen[index] then
        seen[index] = true
        selected[#selected + 1] = index
    end
end

local function add_range(selected, seen, range, length)
    if length == 0 then
        return
    end
    local start = range.start or 0
    if start < 0 then
        start = start + length
    end
    local finish = range.finish
    if finish == nil then
        finish = length - 1
    elseif finish < 0 then
        finish = finish + length
    end
    if (start < 0 and finish < 0) or (start >= length and finish >= length) then
        return
    end
    if start >= length then
        start = length - 1
    elseif start < 0 then
        start = 0
    end
    if finish >= length then
        finish = length - 1
    elseif finish < 0 then
        finish = 0
    end
    if start == finish or range.step >= length then
        add_index(selected, seen, start + 1)
        return
    end
    local step = range.step
    if step <= 0 then
        if -step < length then
            step = step + length
        else
            step = 1
        end
    end
    if step <= 0 then
        step = 1
    end
    if finish >= start then
        local index = start
        while index <= finish do
            add_index(selected, seen, index + 1)
            index = index + step
        end
    else
        local index = start
        while index >= finish do
            add_index(selected, seen, index + 1)
            index = index - step
        end
    end
end

local function apply_legacy_indexes(elements, mode, items)
    if not items or #items == 0 then
        return elements
    end
    local selected = {}
    local seen = {}
    for _, item in ipairs(items) do
        if type(item) == "table" then
            add_range(selected, seen, item, #elements)
        else
            add_index(selected, seen, normalize_index(item, #elements))
        end
    end
    if mode == "!" then
        local excluded = {}
        for _, index in ipairs(selected) do
            excluded[index] = true
        end
        local result = {}
        for index, element in ipairs(elements) do
            if not excluded[index] then
                result[#result + 1] = element
            end
        end
        return result
    end
    local result = {}
    for _, index in ipairs(selected) do
        result[#result + 1] = elements[index]
    end
    return result
end

local function select_legacy(root, expression)
    local reverse = trim(expression):sub(1, 1) == "-"
    local source_expression = reverse and trim(expression):sub(2) or expression
    local parsed_base, parsed_mode, parsed_items = parse_legacy_selector(source_expression)
    local base = parsed_base or trim(source_expression)
    local mode = parsed_mode or " "
    local elements
    local err

    if base == "" or base == "children" then
        elements, err = children_of(root)
    else
        local prefix, value = base:match("^([^%.]+)%.(.+)$")
        if prefix == "class" then
            elements, err = select_css(root, "." .. value)
        elseif prefix == "tag" then
            elements, err = select_css(root, value)
        elseif prefix == "id" then
            elements, err = select_css(root, "#" .. value)
        elseif prefix == "text" then
            local all
            all, err = select_css(root, "*")
            if all then
                elements = {}
                for _, element in ipairs(all) do
                    if own_text(element):find(value, 1, true) then
                        elements[#elements + 1] = element
                    end
                end
            end
        else
            elements, err = select_css(root, base)
        end
    end
    if not elements then
        return nil, err
    end
    elements = apply_legacy_indexes(elements, mode, parsed_items)
    if reverse then
        local result = {}
        for index = #elements, 1, -1 do result[#result + 1] = elements[index] end
        return result
    end
    return elements
end

local function selector_and_mode(expression)
    local selector, mode = expression:match("^(.*)@([^@]+)$")
    if not selector then
        selector, mode = expression, "text"
    end
    return trim(selector), trim(mode)
end

local function elements_from_default(root, expression, include_last)
    local pieces = split_at_signs(expression)
    if #pieces == 0 then
        return {}
    end
    if #pieces == 1 then
        return select_legacy(root, pieces[1])
    end
    local current = { root }
    local last = include_last and #pieces or #pieces - 1
    for i = 1, last do
        local next_elements = {}
        for _, parent in ipairs(current) do
            local selected, err = select_legacy(parent, pieces[i])
            if not selected then
                return nil, err
            end
            for _, element in ipairs(selected) do
                next_elements[#next_elements + 1] = element
            end
        end
        current = next_elements
    end
    return current
end

local function css_values(content, expression)
    local selector, mode = selector_and_mode(expression)
    local root, err = root_for(content)
    if not root then
        return nil, err
    end
    local elements, select_err = select_css(root, selector)
    if not elements then
        return nil, select_err
    end
    local values = {}
    for _, element in ipairs(elements) do
        local value = element_value(element, mode)
        if value ~= "" then
            values[#values + 1] = value
        end
    end
    return values
end

local function default_values(content, expression)
    local pieces = split_at_signs(expression)
    local root, err = root_for(content)
    if not root then
        return nil, err
    end
    local last = #pieces > 1 and pieces[#pieces] or "text"
    local current
    if #pieces == 1 then
        current, err = select_legacy(root, pieces[1])
    else
        current, err = elements_from_default(root, expression)
    end
    if not current then
        return nil, err
    end

    local values = {}
    for _, element in ipairs(current) do
        local value = element_value(element, last)
        if value ~= "" then
            values[#values + 1] = value
        end
    end
    return values
end

local json_items

local function xpath_expression(value)
    local expression = trim(value or "")
    if expression:lower():match("^@xpath:") then
        expression = trim(expression:sub(8))
    end
    return expression
end

local function xpath_split_steps(expression)
    local steps = {}
    local index = 1
    local axis = "child"
    expression = trim(expression)
    if expression:sub(1, 2) == "//" then
        axis = "descendant"
        index = 3
    elseif expression:sub(1, 2) == "./" then
        index = 3
    elseif expression:sub(1, 1) == "/" then
        index = 2
    end
    local start = index
    local bracket = 0
    local quote
    while index <= #expression + 1 do
        local char = expression:sub(index, index)
        if quote then
            if char == quote and expression:sub(index - 1, index - 1) ~= "\\" then
                quote = nil
            end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == "[" then
            bracket = bracket + 1
        elseif char == "]" then
            bracket = math.max(0, bracket - 1)
        elseif (char == "/" or index > #expression) and bracket == 0 then
            local segment = trim(expression:sub(start, index - 1))
            if segment ~= "" then
                steps[#steps + 1] = { segment = segment, axis = axis }
            end
            if char == "/" then
                if expression:sub(index + 1, index + 1) == "/" then
                    axis = "descendant"
                    index = index + 1
                else
                    axis = "child"
                end
            end
            start = index + 1
        end
        index = index + 1
    end
    return steps
end

local function xpath_segment(segment)
    local name = trim(segment):match("^([^%[]+)") or trim(segment)
    local predicates = {}
    local index = #name + 1
    while index <= #segment do
        local opening = segment:find("[", index, true)
        if not opening then
            break
        end
        local depth = 1
        local quote
        local cursor = opening + 1
        while cursor <= #segment and depth > 0 do
            local char = segment:sub(cursor, cursor)
            if quote then
                if char == quote and segment:sub(cursor - 1, cursor - 1) ~= "\\" then
                    quote = nil
                end
            elseif char == "'" or char == '"' then
                quote = char
            elseif char == "[" then
                depth = depth + 1
            elseif char == "]" then
                depth = depth - 1
            end
            cursor = cursor + 1
        end
        if depth ~= 0 then
            return nil, "unclosed XPath predicate: " .. tostring(segment)
        end
        predicates[#predicates + 1] = trim(segment:sub(opening + 1, cursor - 2))
        index = cursor
    end
    return trim(name), predicates
end

local function xpath_children(element)
    local result = {}
    for _, child in ipairs(element.nodes or {}) do
        if type(child) == "table" or type(child) == "userdata" then
            if child.name then
                result[#result + 1] = child
            end
        end
    end
    return result
end

local function xpath_descendants(element, result)
    result = result or {}
    for _, child in ipairs(xpath_children(element)) do
        result[#result + 1] = child
        xpath_descendants(child, result)
    end
    return result
end

local function xpath_attribute(element, name)
    local attributes = element.attributes or {}
    return attributes[name] or attributes[name:gsub("^.-:", "")]
end

local function xpath_text(element)
    local ok, value = pcall(function()
        return element:textonly()
    end)
    return ok and tostring(value or "") or ""
end

local function xpath_unquote(value)
    value = trim(value)
    local quote = value:sub(1, 1)
    if (quote == "'" or quote == '"') and value:sub(-1) == quote then
        return value:sub(2, -2)
    end
    return value
end

local function xpath_predicate_matches(element, predicate, position, total)
    predicate = trim(predicate)
    local negated = false
    if predicate:lower():match("^not%s*%(") and predicate:sub(-1) == ")" then
        negated = true
        predicate = trim(predicate:match("^not%s*%((.*)%)$") or "")
    end
    local function result(value)
        return negated and not value or value
    end
    local direct_attribute, direct_value = predicate:match("^@([%w:_-]+)%s*=%s*(.+)$")
    if direct_attribute then
        return result(tostring(xpath_attribute(element, direct_attribute) or "") == xpath_unquote(direct_value))
    end
    local direct_text = predicate:match("^text%(%s*%)%s*=%s*(.+)$")
    if direct_text then
        return result(xpath_text(element) == xpath_unquote(direct_text))
    end
    local left, operator, right = predicate:match("^(.+)%s*([!<>=]+)%s*(.+)$")
    if left and operator and right then
        right = xpath_unquote(right)
        left = trim(left):lower()
        local actual
        if left == "text()" or left == "." or left == "normalize-space(.)" then
            actual = xpath_text(element)
            if left == "normalize-space(.)" then
                actual = trim(actual:gsub("%s+", " "))
            end
        else
            local attribute = left:match("^@([%w:_-]+)$")
            actual = attribute and xpath_attribute(element, attribute) or nil
        end
        actual = actual == nil and "" or tostring(actual)
        if right:match("^%-?%d+%.?%d*$") and actual:match("^%-?%d+%.?%d*$") then
            actual = tonumber(actual)
            right = tonumber(right)
        end
        local matched
        if operator == "!=" then
            matched = actual ~= right
        elseif operator == "<=" then
            matched = actual <= right
        elseif operator == ">=" then
            matched = actual >= right
        elseif operator == "<" then
            matched = actual < right
        elseif operator == ">" then
            matched = actual > right
        else
            matched = actual == right
        end
        return result(matched)
    end
    local attr, needle = predicate:match("^contains%s*%(%s*@([%w:_-]+)%s*,%s*(.-)%s*%)$")
    if attr then
        return result(tostring(xpath_attribute(element, attr) or ""):find(xpath_unquote(needle), 1, true) ~= nil)
    end
    local text_needle = predicate:match("^contains%s*%(%s*text%(%s*%)%s*,%s*(.-)%s*%)$")
    if text_needle then
        return result(xpath_text(element):find(xpath_unquote(text_needle), 1, true) ~= nil)
    end
    local starts_attr, starts_needle = predicate:match("^starts%-with%s*%(%s*@([%w:_-]+)%s*,%s*(.-)%s*%)$")
    if starts_attr then
        local actual = tostring(xpath_attribute(element, starts_attr) or "")
        return result(actual:sub(1, #xpath_unquote(starts_needle)) == xpath_unquote(starts_needle))
    end
    if predicate:lower() == "last()" then
        return result(position == total)
    elseif predicate:lower() == "position()" then
        return result(position > 0)
    elseif predicate:match("^%-?%d+$") then
        return result(position == tonumber(predicate))
    end
    local position_value = predicate:match("^position%(%s*%)%s*=%s*(%d+)$")
    if position_value then
        return result(position == tonumber(position_value))
    end
    local attribute = predicate:match("^@([%w:_-]+)$")
    if attribute then
        return result(xpath_attribute(element, attribute) ~= nil)
    end
    if predicate == "." or predicate == "text()" then
        return result(xpath_text(element) ~= "")
    end
    local and_left, and_right = predicate:match("^(.+)%s+and%s+(.+)$")
    if and_left then
        return result(
            xpath_predicate_matches(element, and_left, position, total)
                and xpath_predicate_matches(element, and_right, position, total)
        )
    end
    local or_left, or_right = predicate:match("^(.+)%s+or%s+(.+)$")
    if or_left then
        return result(
            xpath_predicate_matches(element, or_left, position, total)
                or xpath_predicate_matches(element, or_right, position, total)
        )
    end
    return nil, "unsupported XPath predicate: " .. tostring(predicate)
end

local function xpath_select_group(root, expression)
    local steps = xpath_split_steps(xpath_expression(expression))
    local current = { root }
    for _, step in ipairs(steps) do
        local name, predicates = xpath_segment(step.segment)
        if not name then
            return nil, predicates
        end
        if name == "." then
            -- Keep the current context node.
        elseif name == ".." then
            local parents = {}
            local seen = {}
            for _, element in ipairs(current) do
                if element.parent and not seen[element.parent] then
                    seen[element.parent] = true
                    parents[#parents + 1] = element.parent
                end
            end
            current = parents
        else
            local candidates = {}
            for _, element in ipairs(current) do
                local children = step.axis == "descendant"
                    and xpath_descendants(element) or xpath_children(element)
                for _, child in ipairs(children) do
                    local child_name = tostring(child.name or ""):lower()
                    local wanted = name:lower()
                    if wanted == "*" or child_name == wanted
                            or child_name:match("[^:]+:" .. wanted .. "$") then
                        candidates[#candidates + 1] = child
                    end
                end
            end
            for _, predicate in ipairs(predicates) do
                local filtered = {}
                for position, element in ipairs(candidates) do
                    local matches, predicate_err = xpath_predicate_matches(
                        element, predicate, position, #candidates
                    )
                    if predicate_err then
                        return nil, predicate_err
                    end
                    if matches then
                        filtered[#filtered + 1] = element
                    end
                end
                candidates = filtered
            end
            current = candidates
        end
    end
    return current
end

local function xpath_union(root, expression)
    local groups = split_top_level(xpath_expression(expression), { "|" })
    local result = {}
    local seen = {}
    for _, group in ipairs(groups) do
        local values, err = xpath_select_group(root, group)
        if not values then
            return nil, err
        end
        for _, element in ipairs(values) do
            if not seen[element] then
                seen[element] = true
                result[#result + 1] = element
            end
        end
    end
    table.sort(result, function(left, right)
        return (left.index or 0) < (right.index or 0)
    end)
    return result
end

local function xpath_values(content, expression)
    local root, err = root_for(content)
    if not root then
        return nil, err
    end
    local value = xpath_expression(expression)
    local terminal
    if value:match("/[@][%w:_-]+$") then
        terminal = value:match("/(@[%w:_-]+)$")
        value = value:sub(1, -(#terminal + 2))
    elseif value:match("/text%(%s*%)$") then
        terminal = "text()"
        value = value:sub(1, -(#terminal + 2))
    elseif value:match("/string%(%s*%)$") then
        terminal = "string()"
        value = value:sub(1, -(#terminal + 2))
    end
    local elements, select_err = xpath_union(root, value)
    if not elements then
        return nil, select_err
    end
    local values = {}
    for _, element in ipairs(elements) do
        local item
        if terminal and terminal:sub(1, 1) == "@" then
            item = xpath_attribute(element, terminal:sub(2))
        elseif terminal == "text()" then
            item = xpath_text(element)
        elseif terminal == "string()" then
            item = xpath_text(element)
        else
            item = xpath_text(element)
        end
        if item and item ~= "" then
            values[#values + 1] = item
        end
    end
    return values
end

local function xpath_elements(content, expression)
    local root, err = root_for(content)
    if not root then
        return nil, err
    end
    return xpath_union(root, expression)
end

-- Legado's non-JavaScript rules can write values into a short-lived rule
-- variable map and read them later with @get:{name}.  This is especially
-- common for sources which first extract a book id in bookInfo.init and then
-- reuse it in the TOC or content URL.
local function split_put_rule(value)
    local rule = tostring(value or "")
    local marker_start, marker_end = rule:find("@put:%s*{")
    if not marker_start then
        return rule, nil
    end
    local depth = 1
    local quote
    local escaped = false
    local index = marker_end + 1
    while index <= #rule do
        local char = rule:sub(index, index)
        if escaped then
            escaped = false
        elseif char == "\\" and quote then
            escaped = true
        elseif quote then
            if char == quote then
                quote = nil
            end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == "{" then
            depth = depth + 1
        elseif char == "}" then
            depth = depth - 1
            if depth == 0 then
                local body = rule:sub(marker_end + 1, index - 1)
                return rule:sub(1, marker_start - 1) .. rule:sub(index + 1), body
            end
        end
        index = index + 1
    end
    return nil, "unterminated @put rule"
end

local function split_first_top_level(value, delimiter)
    local parts, selected = split_top_level(value, { delimiter })
    if not selected then
        return trim(value), nil
    end
    local right = {}
    for index = 2, #parts do
        right[#right + 1] = parts[index]
    end
    return parts[1], table.concat(right, delimiter)
end

local function parse_put_map(body)
    local entries = {}
    for _, part in ipairs(split_top_level(tostring(body or ""), { "," })) do
        if trim(part) ~= "" then
            local key, expression = split_first_top_level(part, ":")
            if not expression then
                return nil, "invalid @put entry: " .. tostring(part)
            end
            key = trim(key)
            local _, quoted_key = key:match("^(['\"])(.-)%1$")
            if quoted_key then
                key = quoted_key
            end
            if key == "" then
                return nil, "empty @put key"
            end
            entries[#entries + 1] = { key = key, expression = trim(expression) }
        end
    end
    return entries
end

local function rule_variables(context)
    context = context or {}
    if type(context.rule_variables) ~= "table" then
        context.rule_variables = {}
    end
    return context.rule_variables
end

local function rule_variable(context, key)
    local variables = rule_variables(context)
    local value = variables[trim(key)]
    return value == nil and "" or tostring(value)
end

local function apply_put_map(content, body, context)
    local entries, parse_err = parse_put_map(body)
    if not entries then
        return nil, parse_err
    end
    local variables = rule_variables(context)
    for _, entry in ipairs(entries) do
        local value, value_err = Rules.parse_text(content, entry.expression, context)
        if value_err then
            return nil, "@put " .. entry.key .. ": " .. tostring(value_err)
        end
        variables[entry.key] = value or ""
    end
    return true
end

local function get_rule_prefix(value)
    local key, tail = tostring(value or ""):match("^@get:%s*{%s*([^{}]-)%s*}(.*)$")
    if not key then
        return nil
    end
    return trim(key), tail or ""
end

local function expand_get_rules(value, context)
    return tostring(value or ""):gsub("@get:%s*{([^{}]-)}", function(key)
        return rule_variable(context, key)
    end)
end

function Rules.elements(content, rule, context)
    if rule == nil or trim(rule) == "" then
        return {}
    end
    local stripped_rule, put_body = split_put_rule(rule)
    if put_body then
        local put_ok, put_err = apply_put_map(content, put_body, context or {})
        if not put_ok then
            return nil, put_err
        end
        rule = stripped_rule
    elseif stripped_rule == nil then
        return nil, put_body
    end
    rule = strip_all_in_one_prefix(rule)
    if trim(rule) == "" then
        return {}
    end
    rule = expand_get_rules(rule, context or {})
    local composite, composite_used, composite_err = evaluate_composite_rule(
        content, rule, context or {}, true
    )
    if composite_used then
        if not composite then return nil, composite_err end
        if type(composite) ~= "table" then return {} end
        return unwrap_element_array(composite)
    end
    if is_js_rule(rule) then
        local value, suffix_or_error, eval_error = evaluate_js_rule(content, tostring(rule), context or {})
        if eval_error then
            return nil, eval_error
        end
        if type(suffix_or_error) == "string" and trim(suffix_or_error) ~= "" then
            local suffix_value = trim(suffix_or_error)
            if suffix_value:lower():match("^@json:") or suffix_value:match("^%$[%._%[]") then
                local values, json_err = json_items(value, suffix_value)
                if not values then
                    return nil, json_err
                end
                return unwrap_element_array(values)
            end
            return Rules.elements(value, suffix_value, context)
        end
        if type(value) ~= "table" then
            return {}
        end
        return value
    end
    local replacement_parts = split_top_level(tostring(rule), { "##" })
    local base_rule, err = Rules.expand_templates(
        replacement_parts[1],
        context_with_content(context or {}, content)
    )
    if not base_rule then
        return nil, err
    end
    local reverse = trim(base_rule):sub(1, 1) == "-"
    if reverse then base_rule = trim(base_rule):sub(2) end
    local lowered = base_rule:lower()
    if lowered:match("^@xpath:") or base_rule:match("^//") or base_rule:match("^/") then
        local values, parse_err = xpath_elements(content, base_rule)
        if reverse and values then
            local reversed = {}
            for index = #values, 1, -1 do reversed[#reversed + 1] = values[index] end
            values = reversed
        end
        return values, parse_err
    elseif lowered:match("^@json:") or base_rule:match("^%$[%._%[]") then
        local values, json_err = json_items(content, base_rule)
        if not values then
            return nil, json_err
        end
        if reverse then
            local reversed = {}
            for index = #values, 1, -1 do
                reversed[#reversed + 1] = values[index]
            end
            values = reversed
        end
        return unwrap_element_array(values)
    elseif lowered:match("^@regex:") then
        local values, parse_err = regex_elements(content, base_rule:sub(8), context)
        if reverse and values then
            local reversed = {}
            for index = #values, 1, -1 do reversed[#reversed + 1] = values[index] end
            values = reversed
        end
        return values, parse_err
    elseif base_rule:sub(1, 1) == ":" then
        local values, parse_err = regex_elements(content, base_rule:sub(2), context)
        if reverse and values then
            local reversed = {}
            for index = #values, 1, -1 do reversed[#reversed + 1] = values[index] end
            values = reversed
        end
        return values, parse_err
    end

    local root, parse_err = root_for(content)
    if not root then
        return nil, parse_err
    end
    if lowered:match("^@css:") then
        local selector = selector_and_mode(base_rule:sub(6))
        local values, select_err = select_css(root, selector)
        if reverse and values then
            local reversed = {}
            for index = #values, 1, -1 do reversed[#reversed + 1] = values[index] end
            values = reversed
        end
        return values, select_err
    elseif base_rule:sub(1, 2) == "@@" then
        return select_legacy(root, (reverse and "-" or "") .. base_rule:sub(3))
    end
    return elements_from_default(root, (reverse and "-" or "") .. base_rule, true)
end

-- JsonPath in Legado is backed by Jayway JsonPath on Android.  This small
-- evaluator intentionally works on decoded Lua values, but mirrors the
-- useful JsonPath surface: properties, wildcards, array indexes/slices,
-- unions, filters and recursive descent (`$..name`).
local function json_key_parts(value)
    local result = {}
    if type(value) ~= "table" then return result end
    local numeric = true
    local highest = 0
    for key in pairs(value) do
        if type(key) ~= "number" then numeric = false break end
        highest = math.max(highest, key)
    end
    if numeric then
        for index = 1, highest do
            if value[index] ~= nil then result[#result + 1] = index end
        end
        return result
    end
    for key in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            result[#result + 1] = key
        end
    end
    table.sort(result, function(left, right) return tostring(left) < tostring(right) end)
    return result
end

local function json_bracket_end(value, opening)
    local depth = 1
    local quote
    local escaped = false
    for index = opening + 1, #value do
        local char = value:sub(index, index)
        if escaped then
            escaped = false
        elseif char == "\\" and quote then
            escaped = true
        elseif quote then
            if char == quote then quote = nil end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == "[" then
            depth = depth + 1
        elseif char == "]" then
            depth = depth - 1
            if depth == 0 then return index end
        end
    end
    return nil
end

local function json_token_from_bracket(token, path)
    token = trim(token)
    if token == "" then return nil, "empty JSON path selector: " .. tostring(path) end
    if token == "*" then return { kind = "wildcard" } end
    if token:sub(1, 2) == "?(" and token:sub(-1) == ")" then
        return { kind = "filter", expression = token:sub(3, -2) }
    end
    local pieces, operator = split_top_level(token, { "," })
    if operator and #pieces > 1 then
        local union = {}
        for _, piece in ipairs(pieces) do
            local child, child_err = json_token_from_bracket(piece, path)
            if not child then return nil, child_err end
            if child.kind ~= "index" and child.kind ~= "property" then
                return nil, "unsupported JSON path union: " .. token
            end
            union[#union + 1] = child
        end
        return { kind = "union", values = union }
    end
    local start, finish, step = token:match("^%s*(-?%d*)%s*:%s*(-?%d*)%s*:?%s*(-?%d*)%s*$")
    if start ~= nil and token:find(":", 1, true) then
        return {
            kind = "slice",
            start = start ~= "" and tonumber(start) or nil,
            finish = finish ~= "" and tonumber(finish) or nil,
            step = step ~= "" and tonumber(step) or 1,
        }
    end
    local number = tonumber(token)
    if number and token:match("^-?%d+$") then
        return { kind = "index", index = number }
    end
    return { kind = "property", name = token:gsub("^(['\"])(.-)%1$", "%2") }
end

local function json_tokens(path)
    local tokens = {}
    local value = trim(tostring(path)):gsub("^@json:%s*", "")
    local index = value:sub(1, 1) == "$" and 2 or 1
    while index <= #value do
        local char = value:sub(index, index)
        if char == "." then
            if value:sub(index + 1, index + 1) == "." then
                index = index + 2
                local start = index
                while index <= #value and not value:sub(index, index):match("[.%[]") do
                    index = index + 1
                end
                local name = value:sub(start, index - 1)
                if name == "" then return nil, "invalid recursive JSON path: " .. value end
                tokens[#tokens + 1] = { kind = "recursive", name = name }
            else
                index = index + 1
                local start = index
                while index <= #value and not value:sub(index, index):match("[.%[]") do
                    index = index + 1
                end
                local name = value:sub(start, index - 1)
                if name ~= "" then tokens[#tokens + 1] = { kind = "property", name = name } end
            end
        elseif char == "[" then
            local finish = json_bracket_end(value, index)
            if not finish then return nil, "invalid JSON path: " .. tostring(path) end
            local token, token_err = json_token_from_bracket(value:sub(index + 1, finish - 1), path)
            if not token then return nil, token_err end
            tokens[#tokens + 1] = token
            index = finish + 1
        elseif char == "$" then
            return nil, "invalid JSON path token: " .. value:sub(index)
        else
            local start = index
            while index <= #value and not value:sub(index, index):match("[.%[]") do
                index = index + 1
            end
            local name = value:sub(start, index - 1)
            if name ~= "" then tokens[#tokens + 1] = { kind = "property", name = name } end
        end
    end
    return tokens
end

local function json_lookup(value, path)
    local current = value
    for part in tostring(path or ""):gmatch("[^%.%[%]]+") do
        if type(current) ~= "table" then return nil end
        local number = tonumber(part)
        current = number and current[number + 1] or current[part]
        if current == nil then return nil end
    end
    return current
end

-- Legado's JSONPath implementation also accepts an embedded JSON rule in a
-- literal value, for example `/book/detail?id={$._id}`. This is distinct from
-- `{{...}}`: the inner expression is evaluated against the current JSON
-- object, while the surrounding text remains literal. Keep the scanner
-- balanced so a JSON value containing `}` cannot terminate the wrong rule.
local function json_embedded_end(value, opening)
    local depth = 1
    local quote
    local escaped = false
    for index = opening + 1, #value do
        local char = value:sub(index, index)
        if escaped then
            escaped = false
        elseif char == "\\" and quote then
            escaped = true
        elseif quote then
            if char == quote then quote = nil end
        elseif char == "'" or char == '"' then
            quote = char
        elseif char == "{" then
            depth = depth + 1
        elseif char == "}" then
            depth = depth - 1
            if depth == 0 then return index end
        end
    end
    return nil
end

local function json_embedded_scalar(value)
    if type(value) ~= "table" then return tostring(value or "") end
    if #value > 0 then
        local parts = {}
        for _, item in ipairs(value) do
            if type(item) == "table" then
                local ok, encoded = pcall(rapidjson.encode, item)
                parts[#parts + 1] = ok and encoded or tostring(item)
            elseif item ~= nil then
                parts[#parts + 1] = tostring(item)
            end
        end
        return table.concat(parts, "\n")
    end
    local ok, encoded = pcall(rapidjson.encode, value)
    return ok and encoded or tostring(value)
end

local function json_embedded_text(content, expression)
    expression = tostring(expression or "")
    if not expression:find("{$", 1, true) then
        return expression
    end
    local root = content
    if type(root) == "string" then
        local decoded_ok, decoded = pcall(rapidjson.decode, root)
        if not decoded_ok then return nil, "embedded JSON rule requires JSON content" end
        root = decoded
    end
    if type(root) ~= "table" then
        return nil, "embedded JSON rule requires an object or array" end
    local output = {}
    local cursor = 1
    local replaced = false
    while true do
        local start = expression:find("{$", cursor, true)
        if not start then
            output[#output + 1] = expression:sub(cursor)
            break
        end
        output[#output + 1] = expression:sub(cursor, start - 1)
        local finish = json_embedded_end(expression, start)
        if not finish then
            return nil, "unterminated embedded JSON rule: " .. expression
        end
        local inner = trim(expression:sub(start + 1, finish - 1))
        local values, value_err = json_items(root, inner)
        if not values then return nil, value_err end
        if #values == 0 then
            return nil, "embedded JSON rule did not match: " .. inner
        end
        output[#output + 1] = json_embedded_scalar(values)
        replaced = true
        cursor = finish + 1
    end
    return table.concat(output), replaced
end

local function json_filter_matches(value, expression)
    expression = trim(expression or "")
    local parts, operator = split_top_level(expression, { "||", "&&" })
    if operator and #parts > 1 then
        if operator == "||" then
            for _, part in ipairs(parts) do
                if json_filter_matches(value, part) then return true end
            end
            return false
        end
        for _, part in ipairs(parts) do
            if not json_filter_matches(value, part) then return false end
        end
        return true
    end
    local function operand(text)
        text = trim(text)
        local quoted = text:match("^(['\"])(.-)%1$")
        if quoted then return quoted end
        local number = tonumber(text)
        if number then return number end
        if text == "true" then return true end
        if text == "false" then return false end
        local path = text:match("^@(.+)$")
        return path and json_lookup(value, path) or text
    end
    local left, op, right
    -- Lua patterns do not implement alternation (`|`), so the equivalent
    -- pattern that used to live here never matched JSONPath comparisons.
    -- Search the comparison operators explicitly, preferring the two-byte
    -- forms before `<`/`>`.
    for _, candidate in ipairs({ "==", "!=", "<=", ">=", "<", ">" }) do
        local position = expression:find(candidate, 1, true)
        if position then
            left = trim(expression:sub(1, position - 1))
            op = candidate
            right = trim(expression:sub(position + #candidate))
            break
        end
    end
    if left then
        local a, b = operand(left), operand(right)
        if op == "==" then return a == b end
        if op == "!=" then return a ~= b end
        a, b = tonumber(a) or 0, tonumber(b) or 0
        if op == "<" then return a < b end
        if op == ">" then return a > b end
        if op == "<=" then return a <= b end
        return a >= b
    end
    local path, wanted = expression:match("^contains%s*%(%s*@([^,]+),%s*(.-)%s*%)$")
    if path then
        return tostring(json_lookup(value, path) or ""):find(css_unquote(wanted), 1, true) ~= nil
    end
    local exists = expression:match("^@(.+)$")
    return exists ~= nil and json_lookup(value, exists) ~= nil
end

local function json_recursive(value, name, output)
    output = output or {}
    if type(value) ~= "table" then return output end
    for _, key in ipairs(json_key_parts(value)) do
        local child = value[key]
        if name == "*" or tostring(key) == tostring(name) then output[#output + 1] = child end
        json_recursive(child, name, output)
    end
    return output
end

local function json_index(item, index)
    if type(item) ~= "table" then return nil end
    local length = #item
    if index < 0 then index = length + index end
    return item[index + 1]
end

local function json_slice(item, start, finish, step)
    if type(item) ~= "table" or #item == 0 then return {} end
    local length = #item
    step = tonumber(step) or 1
    if step == 0 then return {} end
    start = start == nil and (step > 0 and 0 or length - 1) or start
    finish = finish == nil and (step > 0 and length - 1 or 0) or finish
    if start < 0 then start = start + length end
    if finish < 0 then finish = finish + length end
    start = math.max(0, math.min(length - 1, start))
    finish = math.max(0, math.min(length - 1, finish))
    local result = {}
    for index = start, finish, step do result[#result + 1] = item[index + 1] end
    return result
end

json_items = function(content, expression)
    local value = content
    if type(value) == "string" then
        local ok, decoded = pcall(rapidjson.decode, value)
        if not ok then return nil, "JSON parse failed: " .. tostring(decoded) end
        value = decoded
    end
    local expanded, expanded_or_error = json_embedded_text(value, expression)
    if expanded == nil then return nil, expanded_or_error end
    expression = expanded
    local tokens, err = json_tokens(expression)
    if not tokens then return nil, err end
    local current = { value }
    for _, token in ipairs(tokens) do
        local next_values = {}
        for _, item in ipairs(current) do
            if token.kind == "recursive" then
                json_recursive(item, token.name, next_values)
            elseif token.kind == "property" then
                if type(item) == "table" and item[token.name] ~= nil then
                    next_values[#next_values + 1] = item[token.name]
                end
            elseif token.kind == "wildcard" then
                for _, key in ipairs(json_key_parts(item)) do next_values[#next_values + 1] = item[key] end
            elseif token.kind == "index" then
                local child = json_index(item, token.index)
                if child ~= nil then next_values[#next_values + 1] = child end
            elseif token.kind == "slice" then
                for _, child in ipairs(json_slice(item, token.start, token.finish, token.step)) do
                    next_values[#next_values + 1] = child
                end
            elseif token.kind == "union" then
                for _, child_token in ipairs(token.values) do
                    if child_token.kind == "property" and type(item) == "table"
                            and item[child_token.name] ~= nil then
                        next_values[#next_values + 1] = item[child_token.name]
                    elseif child_token.kind == "index" then
                        local child = json_index(item, child_token.index)
                        if child ~= nil then next_values[#next_values + 1] = child end
                    end
                end
            elseif token.kind == "filter" and type(item) == "table" then
                for _, key in ipairs(json_key_parts(item)) do
                    local candidate = item[key]
                    if json_filter_matches(candidate, token.expression) then
                        next_values[#next_values + 1] = candidate
                    end
                end
            end
        end
        current = next_values
    end
    return current
end

-- Used by runtime stages where a JS rule returns an object and its trailing
-- rule (for example `</js>$.data`) must remain structured for the next stage.
function Rules.json_result(content, expression)
    return json_items(content, expression)
end

local function js_values(value, suffix, context)
    if suffix and trim(suffix) ~= "" then
        local suffix_value = trim(suffix)
        if suffix_value:lower():match("^@json:") or suffix_value:match("^%$[%._%[]") then
            return json_items(value, suffix_value)
        end
        return Rules.parse_list(value, suffix_value, context)
    end
    if value == nil then
        return {}
    end
    if type(value) ~= "table" then
        return { stringify(value) }
    end
    local values = {}
    local is_array = true
    for key in pairs(value) do
        if type(key) ~= "number" then
            is_array = false
            break
        end
    end
    if is_array then
        for _, item in ipairs(value) do
            values[#values + 1] = stringify(item)
        end
    else
        values[1] = stringify(value)
    end
    return values
end

evaluate_js_rule = function(content, rule, context)
    local evaluator = js_evaluator(context)
    if not evaluator then
        return nil, "source uses JavaScript but no JavaScript evaluator is configured"
    end
    local value, suffix, err = evaluator(rule, content, context)
    if err then
        return nil, nil, err
    end
    return value, suffix, nil
end

-- Legado's AnalyzeRule does not require a JS expression to occupy the whole
-- rule. These are all valid and common forms:
--
--   $.id@js: ...
--   <js> ... </js>$.data
--   <js> ... </js><js> ... </js>$.items[*]
--
-- Split and execute them in order, carrying the previous result into the next
-- segment. Keeping this at the generic rule layer is important: aggregation
-- sources use the same composition syntax as ordinary HTML sources.
local function split_source_rule(value)
    value = tostring(value or "")
    local lowered = value:lower()
    local parts = {}
    local cursor = 1
    local has_dynamic = false
    while cursor <= #value do
        local js_start = lowered:find("<js>", cursor, true)
        local inline_start = lowered:find("@js:", cursor, true)
        local web_start = lowered:find("@webjs:", cursor, true)
        local start, kind
        if js_start and (not start or js_start < start) then start, kind = js_start, "js" end
        if inline_start and (not start or inline_start < start) then start, kind = inline_start, "js-inline" end
        if web_start and (not start or web_start < start) then start, kind = web_start, "web" end
        if not start then
            local tail = trim(value:sub(cursor))
            if tail ~= "" then parts[#parts + 1] = { kind = "text", value = tail } end
            break
        end
        local prefix = trim(value:sub(cursor, start - 1))
        if prefix ~= "" then parts[#parts + 1] = { kind = "text", value = prefix } end
        has_dynamic = true
        if kind == "js" then
            local open_end = start + 4
            local close_start, close_end = lowered:find("</js>", open_end + 1, true)
            if not close_start then
                return nil, true, "unterminated <js> rule"
            end
            parts[#parts + 1] = {
                kind = "js", value = value:sub(open_end + 1, close_start - 1),
            }
            cursor = close_end + 1
        else
            -- Legado's @js:/@webjs: patterns consume the remainder of the
            -- rule. This also prevents a URL/query string in the script from
            -- being mistaken for another source-rule segment.
            local marker_length = kind == "web" and 7 or 4
            parts[#parts + 1] = { kind = kind, value = value:sub(start + marker_length) }
            cursor = #value + 1
        end
    end
    if not has_dynamic then return parts, false end
    return parts, true
end

local function composite_context(context, current)
    local result = {}
    for key, value in pairs(context or {}) do result[key] = value end
    result.result = current
    result.src = current
    return result
end

local function composite_to_values(value)
    if value == nil then return {} end
    if type(value) ~= "table" then return { stringify(value) } end
    if marker_html(value) then
        local element = marker_element(value)
        return { element and element_value(element, "text") or "" }
    end
    if is_element_node(value) then return { element_value(value, "text") } end
    local array = true
    for key in pairs(value) do
        if type(key) ~= "number" then array = false break end
    end
    if not array then return { stringify(value) } end
    local result = {}
    for _, item in ipairs(value) do
        if marker_html(item) then
            local element = marker_element(item)
            result[#result + 1] = element and element_value(element, "text") or ""
        elseif is_element_node(item) then
            result[#result + 1] = element_value(item, "text")
        else
            result[#result + 1] = stringify(item)
        end
    end
    return result
end

evaluate_composite_rule = function(content, rule, context, want_elements)
    local parts, used, split_err = split_source_rule(rule)
    if not parts then return nil, used, split_err end
    if not used then return nil, false end
    local current = content
    for _, part in ipairs(parts) do
        if part.kind == "text" then
            local values, parse_err
            if want_elements then
                values, parse_err = Rules.elements(current, part.value, context)
            else
                values, parse_err = Rules.parse_list(current, part.value, context)
            end
            if not values then return nil, true, parse_err end
            if want_elements then
                current = values
            elseif #values == 1 then
                current = values[1]
            else
                current = values
            end
        elseif part.kind == "js" or part.kind == "js-inline" then
            local dynamic_context = composite_context(context, current)
            local value, suffix, eval_err = evaluate_js_rule(
                current, "<js>" .. part.value .. "</js>", dynamic_context
            )
            if eval_err then return nil, true, eval_err end
            if suffix and trim(suffix) ~= "" then
                value, eval_err = Rules.json_result(value, suffix)
                if eval_err then return nil, true, eval_err end
            end
            current = value
        elseif part.kind == "web" then
            local web_evaluator = context and context.__web_eval
            if type(web_evaluator) ~= "function" then
                return nil, true, "WebView JavaScript requires a browser evaluator"
            end
            local value, web_err = web_evaluator(
                part.value, current, composite_context(context, current)
            )
            if web_err then return nil, true, web_err end
            current = value
        end
    end
    return want_elements and current or composite_to_values(current), true
end

local function json_values(content, expression)
    local current, err = json_items(content, expression)
    if not current then
        return nil, err
    end
    local values = {}
    for _, item in ipairs(current) do
        local text = stringify(item)
        if text ~= "" then
            values[#values + 1] = text
        end
    end
    return values
end

local function lua_literal(char)
    if char == "^" or char == "$" or char == "(" or char == ")"
            or char == "." or char == "[" or char == "]" or char == "%"
            or char == "+" or char == "-" or char == "*" or char == "?" then
        return "%" .. char
    end
    return char
end

-- Legado uses Java regular expressions for ## replacements.  KOReader's
-- small Lua runtime does not bundle a PCRE engine, so translate the useful
-- common subset to Lua patterns and reject constructs that would otherwise
-- silently produce a different book.
local function utf8_char_width(byte)
    if byte >= 0xc2 and byte <= 0xdf then
        return 2
    elseif byte >= 0xe0 and byte <= 0xef then
        return 3
    elseif byte >= 0xf0 and byte <= 0xf4 then
        return 4
    end
    return 1
end

local function copy_regex_state(state)
    local result = {}
    for index, token in ipairs(state) do
        result[index] = { raw = token.raw, kind = token.kind }
    end
    return result
end

local expand_optional_patterns

local function group_end(pattern, opening)
    local depth = 1
    local index = opening + 1
    local in_class = false
    while index <= #pattern do
        local char = pattern:sub(index, index)
        if char == "\\" then
            index = index + 2
        elseif in_class then
            if char == "]" then in_class = false end
            index = index + 1
        elseif char == "[" then
            in_class = true
            index = index + 1
        elseif char == "(" then
            depth = depth + 1
            index = index + 1
        elseif char == ")" then
            depth = depth - 1
            if depth == 0 then return index end
            index = index + 1
        else
            index = index + 1
        end
    end
    return nil
end

-- Lua patterns have no one-character `?` quantifier. Expand the useful Java
-- regex form into ordered alternatives before translating to Lua. Keeping the
-- expansion here makes it apply equally to source selectors and ##
-- replacements, without changing any particular source definition.
expand_optional_patterns = function(pattern)
    local states = { {} }
    local index = 1
    while index <= #pattern do
        local char = pattern:sub(index, index)
        if char == "\\" then
            local escaped = pattern:sub(index + 1, index + 1)
            if escaped == "" then
                return nil, "trailing escape"
            end
            for _, state in ipairs(states) do
                state[#state + 1] = { raw = pattern:sub(index, index + 1), kind = "atom" }
            end
            index = index + 2
        elseif char == "[" then
            local finish = index + 1
            local escaped = false
            while finish <= #pattern do
                local current = pattern:sub(finish, finish)
                if escaped then
                    escaped = false
                elseif current == "\\" then
                    escaped = true
                elseif current == "]" then
                    break
                end
                finish = finish + 1
            end
            if finish > #pattern then
                return nil, "unclosed character class"
            end
            local raw = pattern:sub(index, finish)
            for _, state in ipairs(states) do
                state[#state + 1] = { raw = raw, kind = "atom" }
            end
            index = finish + 1
        elseif char == "(" then
            local finish = group_end(pattern, index)
            if not finish then
                return nil, "unclosed group"
            end
            local prefix = pattern:sub(index + 1, index + 1) == "?"
                and pattern:sub(index + 1, index + 2) or ""
            local inner_start = index + 1 + #prefix
            local inner = pattern:sub(inner_start, finish - 1)
            local inner_variants, inner_err = expand_optional_patterns(inner)
            if not inner_variants then
                return nil, inner_err
            end
            local expanded_states = {}
            for _, state in ipairs(states) do
                for _, variant in ipairs(inner_variants) do
                    local expanded = copy_regex_state(state)
                    expanded[#expanded + 1] = {
                        raw = "(" .. prefix .. variant .. ")",
                        kind = "atom",
                    }
                    expanded_states[#expanded_states + 1] = expanded
                end
            end
            states = expanded_states
            index = finish + 1
        elseif char == "?" then
            local expanded_states = {}
            for _, state in ipairs(states) do
                local last = state[#state]
                if last and last.kind == "quantifier"
                        and (last.raw == "*" or last.raw == "+") then
                    local lazy = copy_regex_state(state)
                    lazy[#lazy].raw = lazy[#lazy].raw .. "?"
                    expanded_states[#expanded_states + 1] = lazy
                elseif last and last.kind == "atom" then
                    -- Preserve the ordered, consuming alternative first. A
                    -- replacement rule with a prefix therefore behaves like
                    -- Java's optional quantifier without empty gsub loops.
                    expanded_states[#expanded_states + 1] = copy_regex_state(state)
                    local without = copy_regex_state(state)
                    table.remove(without)
                    expanded_states[#expanded_states + 1] = without
                else
                    return nil, "optional quantifier has no preceding atom"
                end
            end
            states = expanded_states
            index = index + 1
        elseif char == "*" or char == "+" then
            for _, state in ipairs(states) do
                state[#state + 1] = { raw = char, kind = "quantifier" }
            end
            index = index + 1
        else
            local width = utf8_char_width(pattern:byte(index) or 0)
            local kind = (char == "^" or char == "$" or char == "|"
                or char == "{" or char == "}") and "operator" or "atom"
            local raw = pattern:sub(index, index + width - 1)
            for _, state in ipairs(states) do
                state[#state + 1] = { raw = raw, kind = kind }
            end
            index = index + width
        end
        if #states > 64 then
            return nil, "too many optional regex alternatives"
        end
    end

    local variants = {}
    for _, state in ipairs(states) do
        local pieces = {}
        for _, token in ipairs(state) do pieces[#pieces + 1] = token.raw end
        variants[#variants + 1] = table.concat(pieces)
    end
    return variants
end

local function lua_pattern(pattern)
    pattern = tostring(pattern or "")
    if pattern == "" then
        return nil, "empty regular expression"
    end
    local output = {}
    local index = 1
    while index <= #pattern do
        local char = pattern:sub(index, index)
        if char == "\\" then
            local escaped = pattern:sub(index + 1, index + 1)
            if escaped == "" then
                return nil, "trailing escape"
            elseif escaped == "d" then
                output[#output + 1] = "%d"
            elseif escaped == "D" then
                output[#output + 1] = "%D"
            elseif escaped == "s" then
                output[#output + 1] = "%s"
            elseif escaped == "S" then
                output[#output + 1] = "%S"
            elseif escaped == "w" then
                output[#output + 1] = "%w"
            elseif escaped == "W" then
                output[#output + 1] = "%W"
            elseif escaped == "n" then
                output[#output + 1] = "\n"
            elseif escaped == "r" then
                output[#output + 1] = "\r"
            elseif escaped == "t" then
                output[#output + 1] = "\t"
            elseif escaped == "f" then
                output[#output + 1] = "\f"
            elseif escaped == "b" or escaped == "B" or escaped == "A"
                    or escaped == "Z" or escaped == "z" then
                return nil, "regex boundary is not supported: \\" .. escaped
            elseif escaped == "p" or escaped == "P" then
                return nil, "Unicode regex classes are not supported"
            else
                -- An escaped Java punctuation character means a literal.
                output[#output + 1] = lua_literal(escaped)
            end
            index = index + 2
        elseif char == "(" and pattern:sub(index, index + 2) == "(?:" then
            -- Preserve grouping while dropping Java's non-capturing marker.
            output[#output + 1] = "("
            index = index + 3
        elseif char == "(" and pattern:sub(index + 1, index + 1) == "?" then
            return nil, "lookaround or inline regex flag is not supported"
        elseif char == "*" and pattern:sub(index + 1, index + 1) == "?" then
            -- Java's lazy .*? has a direct Lua-pattern analogue.
            output[#output + 1] = "-"
            index = index + 2
        elseif char == "+" and pattern:sub(index + 1, index + 1) == "?" then
            return nil, "lazy + quantifier is not supported"
        elseif char == "?" then
            return nil, "optional quantifier is not supported"
        elseif char == "{" then
            return nil, "counted quantifier is not supported"
        elseif char == "|" then
            return nil, "nested alternation is not supported"
        elseif char == "-" then
            -- Outside a character class Java treats this as literal; in a
            -- Lua pattern it starts the non-greedy quantifier.
            output[#output + 1] = "%-"
            index = index + 1
        elseif char == "%" then
            -- A percent is literal in Java regex but starts a Lua class.
            output[#output + 1] = "%%"
            index = index + 1
        else
            output[#output + 1] = char
            index = index + 1
        end
    end
    return table.concat(output)
end

lua_pattern_variants = function(pattern)
    local expanded, expansion_err = expand_optional_patterns(tostring(pattern or ""))
    if not expanded then
        return nil, expansion_err
    end
    local patterns = {}
    for _, variant in ipairs(expanded) do
        local converted, pattern_err = lua_pattern(variant)
        if not converted then
            return nil, pattern_err
        end
        patterns[#patterns + 1] = converted
    end
    return patterns
end

local function javascript_regex_parts(expression)
    local pattern = tostring(expression or "")
    local flags = "g"
    local inline
    repeat
        local match_flags, rest = pattern:match("^%s*%(%?([imsU%-]+)%)(.*)$")
        inline = match_flags
        if match_flags then
            if match_flags:find("i", 1, true) then flags = flags .. "i" end
            if match_flags:find("m", 1, true) then flags = flags .. "m" end
            if match_flags:find("s", 1, true) then flags = flags .. "s" end
            pattern = rest
        end
    until not inline
    -- Java's line-break class and absolute anchors have no spelling in the
    -- ECMAScript dialect used by QuickJS. These translations cover the
    -- forms used by Legado's replacement/content rules.
    pattern = pattern:gsub("\\R", "(?:\\r\\n|[\\r\\n])")
        :gsub("\\A", "^")
        :gsub("\\z", "$")
        :gsub("\\Z", "$")
        :gsub("\\Q(.-)\\E", function(value)
            return value:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "\\%1")
        end)
    return pattern, flags
end

local function json_literal(value)
    local ok, encoded = pcall(rapidjson.encode, value)
    return ok and encoded or nil
end

local function javascript_regex_values(content, expression, context, with_groups)
    local evaluator = js_evaluator(context)
    if not evaluator then return nil end
    local pattern, flags = javascript_regex_parts(expression)
    local pattern_json = json_literal(pattern)
    if not pattern_json then return nil end
    local script
    if with_groups then
        script = "(function(){var r=new RegExp(" .. pattern_json .. "," ..
            json_literal(flags) .. ");var a=[],m;while((m=r.exec(String(result)))!==null){var g={};g[0]=m[0];for(var i=1;i<m.length;i++)g[i]=m[i]===undefined?'':m[i];a.push({__regex_groups:g});if(m[0]==='')r.lastIndex++;}return a;})()"
    else
        script = "(function(){var r=new RegExp(" .. pattern_json .. "," ..
            json_literal(flags) .. ");var a=[],m;while((m=r.exec(String(result)))!==null){if(m[0]!=='')a.push(m[0]);if(m[0]==='')r.lastIndex++;}return a;})()"
    end
    local value, _, err = evaluator("<js>" .. script .. "</js>", content, context or {})
    if err or type(value) ~= "table" then return nil end
    return value
end

regex_values = function(content, expression, context)
    local javascript_values = javascript_regex_values(content, expression, context, false)
    if javascript_values then
        return javascript_values
    end
    local patterns, pattern_err = lua_pattern_variants(expression)
    if not patterns then
        return nil, "regex requires an unsupported Java pattern: " .. tostring(pattern_err)
    end
    local values = {}
    local ok, message = pcall(function()
        for _, pattern in ipairs(patterns) do
            for match in tostring(content):gmatch(pattern) do
                if match ~= "" then
                    values[#values + 1] = match
                end
            end
        end
    end)
    if not ok then
        return nil, "regex requires an unsupported Java pattern: " .. tostring(message)
    end
    return values
end

local function collect_find_results(...)
    local count = select("#", ...)
    local values = {}
    for index = 1, count do
        values[index] = select(index, ...)
    end
    return values, count
end

regex_elements = function(content, expression, context)
    local javascript_elements = javascript_regex_values(content, expression, context, true)
    if javascript_elements then
        return javascript_elements
    end
    local patterns, pattern_err = lua_pattern_variants(expression)
    if not patterns then
        return nil, "regex requires an unsupported Java pattern: " .. tostring(pattern_err)
    end
    local text = tostring(content or "")
    local elements = {}
    local position = 1
    local ok, message = pcall(function()
        for _, pattern in ipairs(patterns) do
            position = 1
            while position <= #text do
                local found, count = collect_find_results(string.find(text, pattern, position))
                if count == 0 or found[1] == nil then
                    break
                end
                local groups = {}
                if count > 2 then
                    groups[0] = text:sub(found[1], found[2])
                    for index = 3, count do
                        groups[index - 2] = found[index] or ""
                    end
                else
                    groups[1] = text:sub(found[1], found[2])
                    groups[0] = groups[1]
                end
                elements[#elements + 1] = {
                    __regex_groups = groups,
                }
                if found[2] >= #text then
                    break
                end
                position = math.max(found[2] + 1, position + 1)
            end
        end
    end)
    if not ok then
        return nil, "regex requires an unsupported Java pattern: " .. tostring(message)
    end
    return elements
end

local function replacement_value(value, replacement)
    local raw = tostring(replacement or "")
    local output = {}
    local index = 1
    while index <= #raw do
        local char = raw:sub(index, index)
        if char == "\\" then
            local escaped = raw:sub(index + 1, index + 1)
            if escaped == "n" then
                output[#output + 1] = "\n"
            elseif escaped == "r" then
                output[#output + 1] = "\r"
            elseif escaped == "t" then
                output[#output + 1] = "\t"
            elseif escaped == "f" then
                output[#output + 1] = "\f"
            elseif escaped ~= "" then
                -- Java replacement strings use a backslash to quote the
                -- following character (including a literal quote or slash).
                output[#output + 1] = escaped
            else
                output[#output + 1] = "\\"
            end
            index = index + 2
        elseif char == "$" then
            local escaped = raw:sub(index + 1, index + 1)
            if escaped == "$" then
                output[#output + 1] = "$"
                index = index + 2
            elseif escaped == "&" or escaped == "0" then
                output[#output + 1] = "%0"
                index = index + 2
            else
                local finish = index + 1
                while raw:sub(finish, finish):match("%d") do
                    finish = finish + 1
                end
                if finish > index + 1 then
                    output[#output + 1] = "%" .. raw:sub(index + 1, finish - 1)
                    index = finish
                else
                    output[#output + 1] = "$"
                    index = index + 1
                end
            end
        elseif char == "%" then
            -- A percent is literal in Java but starts a Lua replacement
            -- capture, so escape it for string.gsub.
            output[#output + 1] = "%%"
            index = index + 1
        else
            output[#output + 1] = char
            index = index + 1
        end
    end
    return table.concat(output)
end

local function javascript_replace(value, pattern, replacement, first, empty_on_miss, context)
    local evaluator = js_evaluator(context)
    if not evaluator then return nil end
    local converted_pattern, flags = javascript_regex_parts(pattern)
    if first then flags = flags:gsub("g", "") end
    local pattern_json = json_literal(converted_pattern)
    local replacement_json = json_literal(tostring(replacement or ""))
    if not pattern_json or not replacement_json then return nil end
    local script = "(function(){var r=new RegExp(" .. pattern_json .. "," ..
        json_literal(flags) .. ");var s=String(result);var m=r.test(s);r.lastIndex=0;if(!m)return " ..
        (first and empty_on_miss and "''" or "s") .. ";return s.replace(r," .. replacement_json .. ");})()"
    local result, _, err = evaluator("<js>" .. script .. "</js>", value, context or {})
    if err or result == nil then return nil end
    return tostring(result)
end

local function replace_string(value, pattern, replacement, first, empty_on_miss, context)
    local javascript_result = javascript_replace(
        value, pattern, replacement, first, empty_on_miss, context
    )
    if javascript_result ~= nil then
        return javascript_result
    end
    local alternatives, operator = split_top_level(tostring(pattern or ""), { "|" })
    if operator == nil then
        alternatives = { tostring(pattern or "") }
    end
    local target = tostring(value or "")
    local converted_replacement = replacement_value(target, replacement)
    local matched = false
    for _, alternative in ipairs(alternatives) do
        local patterns, pattern_err = lua_pattern_variants(alternative)
        if not patterns then
            return nil, pattern_err
        end
        for _, converted in ipairs(patterns) do
            local ok, replaced, count = pcall(function()
                if first then
                    return target:gsub(converted, converted_replacement, 1)
                end
                return target:gsub(converted, converted_replacement)
            end)
            if not ok then
                return nil, replaced
            end
            if count and count > 0 then
                matched = true
            end
            target = replaced
            if first and matched then
                return target
            end
        end
    end
    if first and empty_on_miss and not matched then
        return ""
    end
    return target
end

local function apply_replacement(values, rule, context)
    local pieces = split_top_level(rule, { "##" })
    if #pieces == 1 then
        return values, nil
    end
    local pattern = pieces[2]
    local first = #pieces >= 4
    local result = {}
    for _, value in ipairs(values) do
        local replaced, replace_err = replace_string(
            value, pattern, pieces[3] or "", first, false, context
        )
        if not replaced then
            return nil, "replacement pattern failed: " .. tostring(replace_err)
        end
        result[#result + 1] = replaced
    end
    return result
end

local function normalize_lines(value)
    local lines = {}
    local text = tostring(value or "")
    local cursor = 1
    while true do
        local start, finish, line = text:find("(.-)\r?\n", cursor)
        if not start then
            lines[#lines + 1] = trim(text:sub(cursor))
            break
        end
        lines[#lines + 1] = trim(line)
        cursor = finish + 1
    end
    return table.concat(lines, "\n")
end

function Rules.apply_text_rule(content, rule, context)
    local raw_rule = tostring(rule or "")
    local text = tostring(content or "")
    if trim(raw_rule) == "" then
        return text
    end
    local lowered = raw_rule:lower()
    if is_js_rule(raw_rule) then
        local value, suffix, eval_error = evaluate_js_rule(text, raw_rule, context or {})
        if eval_error then
            return nil, eval_error
        end
        if suffix and trim(suffix) ~= "" and trim(suffix):sub(1, 2) ~= "##" then
            local values, suffix_error = js_values(value, suffix, context or {})
            if not values then
                return nil, suffix_error
            end
            return table.concat(values, "\n")
        end
        return stringify(value)
    end

    local expanded, expand_err = Rules.expand_templates(
        raw_rule,
        context_with_content(context or {}, text)
    )
    if not expanded then
        return nil, expand_err
    end
    local parts = split_top_level(expanded, { "##" })
    local target = normalize_lines(text)
    if parts[1] ~= "" then
        local values, values_err = Rules.parse_list(target, parts[1], context)
        if not values then
            return nil, values_err
        end
        target = table.concat(values, "\n")
    end
    if #parts == 1 then
        return target
    end
    local replaced, replace_err = replace_string(
        target,
        parts[2],
        parts[3] or "",
        #parts >= 4,
        true,
        context
    )
    if not replaced then
        return nil, "replacement pattern failed: " .. tostring(replace_err)
    end
    return replaced
end

local function single(content, rule, context)
    rule = tostring(rule or "")
    local reverse = trim(rule):sub(1, 1) == "-"
    if reverse then rule = trim(rule):sub(2) end
    local lowered = rule:lower()
    local function maybe_reverse(values)
        if not reverse or type(values) ~= "table" then return values end
        local result = {}
        for index = #values, 1, -1 do result[#result + 1] = values[index] end
        return result
    end
    if rule:find("{$", 1, true)
            and not lowered:match("^@json:")
            and not rule:match("^%$[%._%[]") then
        local embedded, embedded_err = json_embedded_text(content, rule)
        if embedded then
            return { embedded }
        end
        -- A JSON object/array has no meaningful CSS/XPath fallback for a
        -- failed embedded rule. Return the diagnostic instead of silently
        -- treating the literal as a tag selector.
        if type(content) == "table" and not is_element_node(content) then
            return nil, embedded_err
        end
    end
    if is_js_rule(rule) then
        local value, suffix, eval_error = evaluate_js_rule(content, rule, context or {})
        if eval_error then
            return nil, eval_error
        end
        return js_values(value, suffix, context or {})
    elseif lowered:match("^@xpath:") or rule:match("^//") or rule:match("^/") then
        return xpath_values(content, rule)
    elseif lowered:match("^@text:") then
        local start = rule:find(":", 1, true)
        return { rule:sub(start + 1) }
    elseif lowered:match("^@regex:") then
        return maybe_reverse(regex_values(content, rule:sub(8), context))
    elseif rule:sub(1, 1) == ":" then
        return maybe_reverse(regex_values(content, rule:sub(2), context))
    elseif lowered:match("^@json:") or rule:match("^%$[%._%[]") then
        local values, json_err = json_values(content, rule)
        if not values then return nil, json_err end
        return maybe_reverse(values)
    elseif lowered:match("^@css:") then
        return maybe_reverse(css_values(content, rule:sub(6)))
    elseif rule:sub(1, 2) == "@@" then
        return maybe_reverse(default_values(content, rule:sub(3)))
    end
    if type(content) == "table" and type(content.__regex_groups) == "table" then
        local group = rule:match("^%$(%d+)$")
        if group then
            local index = tonumber(group)
            return { tostring(content.__regex_groups[index]
                or content.__regex_groups[tostring(index)] or "") }
        end
    end
    -- In a Legado list rule, the selected element becomes the current
    -- context.  Rules such as `text` and `href` therefore read that element
    -- directly; treating them as descendant tag selectors makes ordinary
    -- chapterName/chapterUrl rules silently return empty values.
    if is_element_node(content) then
        local value = simple_element_value(content, rule)
        if value ~= nil then
            return { value }
        end
    end
    if type(content) == "table" and type(content.select) ~= "function" then
        return json_values(content, rule)
    end
    local expanded, err = Rules.expand_templates(rule, context_with_content(context, content))
    if not expanded then
        return nil, err
    end
    return maybe_reverse(default_values(content, expanded))
end

function Rules.parse_list(content, rule, context)
    if rule == nil or trim(rule) == "" then
        return {}
    end
    context = context or {}
    local stripped_rule, put_body = split_put_rule(rule)
    if put_body then
        local put_ok, put_err = apply_put_map(content, put_body, context)
        if not put_ok then
            return nil, put_err
        end
        rule = stripped_rule
    elseif stripped_rule == nil then
        return nil, put_body
    else
        rule = stripped_rule
    end
    rule = strip_all_in_one_prefix(rule)
    if trim(rule) == "" then
        return { stringify(content) }
    end
    local get_key, get_tail = get_rule_prefix(rule)
    if get_key then
        local values = { rule_variable(context, get_key) }
        if trim(get_tail) ~= "" then
            return apply_replacement(values, get_tail, context)
        end
        return values
    end
    rule = expand_get_rules(rule, context)
    local composite, composite_used, composite_err = evaluate_composite_rule(
        content, rule, context, false
    )
    if composite_used then
        if not composite then return nil, composite_err end
        return composite
    end
    if is_js_rule(rule) then
        local replacement_parts = split_top_level(tostring(rule), { "##" })
        local values, err = single(content, replacement_parts[1], context)
        if not values then
            return nil, err
        end
        return apply_replacement(values, tostring(rule), context)
    end
    local parts, operator = split_top_level(tostring(rule), { "||", "&&", "%%" })
    if operator and #parts > 1 then
        local results = {}
        for _, part in ipairs(parts) do
            local values, err = Rules.parse_list(content, part, context)
            if err then
                return nil, err
            end
            results[#results + 1] = values
            if operator == "||" and #values > 0 then
                return values
            end
        end
        if operator == "&&" then
            local joined = {}
            for _, values in ipairs(results) do
                for _, value in ipairs(values) do
                    joined[#joined + 1] = value
                end
            end
            return { table.concat(joined) }
        elseif operator == "%%" then
            local interleaved = {}
            local width = 0
            for _, values in ipairs(results) do
                width = math.max(width, #values)
            end
            for index = 1, width do
                for _, values in ipairs(results) do
                    if values[index] then
                        interleaved[#interleaved + 1] = values[index]
                    end
                end
            end
            return interleaved
        end
        return {}
    end

    local replacement_parts = split_top_level(tostring(rule), { "##" })
    local base_rule = replacement_parts[1]
    -- `{{...}}` is a value template.  Its result is text (possibly mixed
    -- with literal markup), not a new selector.  Re-parsing a result such as
    -- `<br>description` as a CSS/default rule loses the value entirely.
    -- Evaluate the inline rules against the current content and preserve the
    -- resulting string before applying any trailing ## replacement.
    if base_rule:find("{{", 1, true) then
        local expanded, expand_err = Rules.expand_templates(
            base_rule,
            context_with_content(context, content)
        )
        if not expanded then
            return nil, expand_err
        end
        return apply_replacement({ expanded }, tostring(rule), context)
    end
    local values, err = single(content, base_rule, context)
    if not values then
        return nil, err
    end
    return apply_replacement(values, tostring(rule), context)
end

function Rules.parse_text(content, rule, context)
    local values, err = Rules.parse_list(content, rule, context)
    if not values then
        return nil, err
    end
    return table.concat(values, "\n")
end

-- Runtime stages often read a scalar directly from an already selected
-- ElementNode (`text`, `href`, `src`, ...). The general parser is deliberately
-- feature-rich, but routing these unambiguous rules through it for every
-- chapter needlessly re-enters the selector/JSON dispatcher. Keep this
-- helper conservative: anything with templates, boolean operators, a JS
-- prefix, or a non-scalar selector falls back to the complete implementation.
local function simple_element_rule_base(rule)
    local raw = strip_all_in_one_prefix(rule)
    local parts, operator = split_top_level(raw, { "||", "&&", "%%" })
    if operator ~= nil or #parts ~= 1 then return nil end
    parts, operator = split_top_level(raw, { "##" })
    if operator ~= nil and #parts < 2 then return nil end
    local base = trim(parts[1] or "")
    if base == "" or base:find("{{", 1, true) or base:find("@", 1, true)
            or is_js_rule(base) then
        return nil
    end
    -- Attribute names in HTML/Jsoup may contain ':' and '-'. A bare selector
    -- such as `div` is intentionally accepted too; if it is not an attribute
    -- on the selected element the caller falls back to parse_text.
    if not base:match("^[%w_:%-]+$") then return nil end
    return base
end

function Rules.simple_element_base(rule)
    return simple_element_rule_base(rule)
end

function Rules.parse_element_text(element, rule, context, known_base)
    local base = known_base or simple_element_rule_base(rule)
    if base and is_element_node(element) then
        local value = simple_element_value(element, base)
        if value ~= nil then
            local values, err = apply_replacement({ value }, tostring(rule), context or {})
            if not values then return nil, err end
            return table.concat(values, "\n")
        end
    end
    return Rules.parse_text(element, rule, context)
end

-- Parse one HTML document once and let callers reuse its DOM for several
-- fields. This is especially important for bookInfo pages: eight independent
-- field rules should not each rebuild a 40–300 KiB document.
function Rules.parse_document(content)
    return root_for(content)
end

-- DOM operations used by the JavaScript compatibility surface.  They are
-- exported separately from parse_list so a JavaScript source can keep an
-- Element object alive across several `java.getString(..., element)` calls.
local function clone_parent_marker(value, depth)
    if type(value) ~= "table" or (depth or 0) > 6 then
        return nil
    end
    local html = marker_html(value)
    if not html then return nil end
    local marker = { __legado_element = html }
    local parent = value.__legado_parent
    if type(parent) == "table" then
        local cloned = clone_parent_marker(parent, (depth or 0) + 1)
        if cloned then marker.__legado_parent = cloned end
    elseif type(parent) == "string" and parent ~= "" then
        marker.__legado_parent = { __legado_element = parent }
    end
    return marker
end

function Rules.element_to_marker(value)
    local html = marker_html(value)
    if html then return clone_parent_marker(value, 0) end
    if not is_element_node(value) then return nil end
    local marker = { __legado_element = outer_text(value) }
    -- A serialized Element normally contains only its outer HTML.  Preserve
    -- one parent snapshot as well, otherwise a source that calls
    -- `item.parent()` after `select()` cannot recover the Jsoup tree across
    -- the Lua/QuickJS boundary.  The parent marker itself carries the next
    -- parent, so parent().parent() continues to work without retaining the
    -- entire document in every element.
    local parent = value.parent
    local parent_marker
    if parent and parent.name and parent.name ~= "root" then
        parent_marker = Rules.element_to_marker(parent)
    end
    if parent_marker then
        marker.__legado_parent = parent_marker
    end
    return marker
end

local function element_from_value(value)
    if marker_html(value) then return marker_element(value) end
    -- The native bridge historically passed an element's outer HTML for
    -- property/children calls.  Accept that representation too; keeping the
    -- conversion here makes the host API tolerant of both old and new bridge
    -- callers and still gives every operation a real ElementNode.
    if type(value) == "string" and value:find("<", 1, true) then
        return marker_element({ __legado_element = value })
    end
    return is_element_node(value) and value or nil
end

function Rules.element_property(value, property)
    local element = element_from_value(value)
    if not element then return "" end
    property = trim(property or "")
    if property == "text" then return element_value(element, "text") end
    if property == "ownText" then return element_value(element, "ownText") end
    if property == "textNodes" then return element_value(element, "textNodes") end
    if property == "html" then return element_value(element, "html") end
    if property == "all" or property == "outerHtml" then return element_value(element, "all") end
    if property == "tagName" or property == "name" then return tostring(element.name or "") end
    if property == "className" then return tostring(element.attributes and element.attributes.class or "") end
    if property == "id" then return tostring(element.attributes and element.attributes.id or "") end
    return tostring(element.attributes and element.attributes[property] or "")
end

function Rules.element_children(value)
    local element = element_from_value(value)
    if not element then return {} end
    local result = {}
    for _, child in ipairs(element.nodes or {}) do
        if child.name then result[#result + 1] = Rules.element_to_marker(child) end
    end
    return result
end

function Rules.element_parent(value)
    if type(value) == "table" then
        if type(value.__legado_parent) == "table" then
            return clone_parent_marker(value.__legado_parent, 0)
        elseif type(value.__legado_parent) == "string"
                and value.__legado_parent ~= "" then
            return { __legado_element = value.__legado_parent }
        end
    end
    local element = element_from_value(value)
    if not element or not element.parent or element.parent.name == "root" then return nil end
    return Rules.element_to_marker(element.parent)
end

function Rules.element_attributes(value)
    local element = element_from_value(value)
    if not element then return {} end
    local result = {}
    local names = {}
    for name in pairs(element.attributes or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        result[#result + 1] = {
            __legado_attribute = true,
            key = name,
            value = tostring(element.attributes[name] or ""),
        }
    end
    return result
end

return Rules
