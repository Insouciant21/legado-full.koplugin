-- Text book-source runtime.  This module returns plain Lua tables so callers
-- can safely serialize results from a Trapper subprocess.

local Network = require("legado/network")
local Rules = require("legado/rules")
local Javascript = require("legado/javascript")
local Session = require("legado/session")
local Content = require("legado/content")
local rapidjson = require("rapidjson")
local socket = require("socket")
local util = require("util")

local Runtime = {}
local js_engine = Javascript:new()
local active_session_key
local web_evaluate

local function memory_checkpoint(counter, collect_now)
    -- LuaJIT's allocator can otherwise postpone collecting short-lived HTML,
    -- JSON and FFI objects until a large TOC has already been
    -- materialized.  During item extraction the parsed page is still held by
    -- every selected element, so a full collection would repeatedly rescan
    -- the same large tree.  Only do cheap, infrequent incremental work then;
    -- the caller requests a full collection after releasing that page.
    if collect_now then
        collectgarbage("collect")
    elseif counter and counter > 0 and counter % 256 == 0 then
        -- A TOC entry is already reduced to a few scalar fields. Running a
        -- 4k-step collector every 64 entries makes a 2,500-chapter page
        -- spend more time scanning the still-live DOM than extracting it.
        -- The full collection after releasing the page remains the memory
        -- safety point; this smaller checkpoint only handles allocator
        -- pressure during unusually large pages.
        collectgarbage("step", 1000)
    end
end

local function source_session_key(source)
    source = source or {}
    return tostring(source.bookSourceUrl or "") .. "\0" .. tostring(source.bookSourceName or "")
end

local function restore_session(source)
    local state, err = Session.load(source)
    if not state then
        return nil, err
    end
    Network.reset_cookies()
    Network.import_cookies(state.cookies)
    js_engine:restore_source_state(source, state)
    return state
end

local function save_session(source)
    local state = js_engine:export_source_state(source)
    state.cookies = Network.export_cookies()
    return Session.save(source, state)
end

-- Each UI operation runs in a Trapper subprocess.  Restore a source's
-- authentication before the operation and save it after the operation so a
-- login performed in one worker is available to the next search/TOC/content
-- worker.  Nested calls (chapter_list -> book_info, book_content -> content)
-- share the same in-memory session and are committed only once.
local function with_session(source, callback)
    local key = source_session_key(source)
    if active_session_key == key then
        return callback()
    end
    local _, restore_err = restore_session(source)
    if restore_err then
        return nil, restore_err
    end
    active_session_key = key
    local ok, first, second, third = pcall(callback)
    local saved, save_err = save_session(source)
    active_session_key = nil
    if not ok then
        return nil, tostring(first)
    end
    if not saved then
        return nil, save_err or "cannot persist source login state"
    end
    return first, second, third
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function rule(section, name)
    if type(section) == "table" then
        return section[name] or ""
    end
    return ""
end

local function is_js_rule(value)
    local lowered = trim(value or ""):lower()
    return lowered:match("^<js>") ~= nil
        or lowered:match("^@js:") ~= nil
        or lowered:match("^@webjs:") ~= nil
end

local function contains_dynamic_rule(value)
    local lowered = tostring(value or ""):lower()
    return lowered:find("<js>", 1, true) ~= nil
        or lowered:find("@js:", 1, true) ~= nil
        or lowered:find("@webjs:", 1, true) ~= nil
end

local BOOK_INFO_FIELDS = {
    "name",
    "author",
    "intro",
    "kind",
    "lastChapter",
    "updateTime",
    "coverUrl",
    "wordCount",
    "tocUrl",
}

local function contains_book_info_side_effect(value)
    local lowered = tostring(value or ""):lower()
    return contains_dynamic_rule(lowered)
        or lowered:find("@put:", 1, true) ~= nil
        or lowered:find("@get:", 1, true) ~= nil
end

local function can_use_cached_book_info(source, book)
    if type(book) ~= "table"
            or trim(book.bookUrl or "") == ""
            or trim(book.tocUrl or "") == "" then
        return false
    end
    local info_rule = source and source.ruleBookInfo
    if type(info_rule) ~= "table" then
        return true
    end
    -- An init rule can decode/replace the detail page or populate variables
    -- consumed by the TOC rule. Do not bypass it, even when the exported book
    -- happens to contain a usable tocUrl.
    if trim(info_rule.init or "") ~= ""
            or trim(info_rule.bookInfoInit or "") ~= "" then
        return false
    end
    for _, name in ipairs(BOOK_INFO_FIELDS) do
        if contains_book_info_side_effect(info_rule[name]) then
            return false
        end
    end
    return true
end

local function cached_book_info(source, book)
    if not can_use_cached_book_info(source, book) then
        return nil
    end
    local info = {}
    for key, value in pairs(book) do
        info[key] = value
    end
    info.bookUrl = book.bookUrl
    info.tocUrl = Network.absolute(
        book.bookUrl or (source and source.bookSourceUrl) or "",
        book.tocUrl
    )
    info.sourceName = (source and source.bookSourceName) or book.sourceName or ""
    return info
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

local function apply_js_suffix(value, suffix)
    if suffix == nil or trim(suffix) == "" then
        return value
    end
    local values, err = Rules.json_result(value, trim(suffix))
    if not values then
        return nil, err
    end
    if #values == 1 then
        return values[1]
    end
    return values
end

local function evaluate_script(source, script, context, content, invocation)
    local value, suffix, err = js_engine:evaluate_script(
        source,
        script,
        context,
        content,
        invocation
    )
    if err then
        return nil, err
    end
    if suffix and trim(suffix) ~= "" then
        value, err = apply_js_suffix(value, suffix)
        if err then
            return nil, err
        end
    end
    return value
end

local function context_for(source, extra)
    local context = {
        key = "",
        page = 1,
        baseUrl = source.bookSourceUrl or "",
        result = "",
    }
    if extra then
        for key, value in pairs(extra) do
            context[key] = value
        end
    end
    context.keyRaw = context.keyRaw or context.key or ""
    context.__js_eval = function(expression, content, current)
        local active_context = current or context
        return js_engine:evaluate_rule(source, expression, active_context, content)
    end
    context.__web_eval = function(script, content, current)
        if not web_evaluate then
            return nil, "WebView evaluator is not initialized"
        end
        return web_evaluate(source, current or context, content, script)
    end
    return context
end

local function copy_source_for_request(source, header)
    local result = {}
    for key, value in pairs(source or {}) do
        result[key] = value
    end
    result.header = header
    -- The login header is deliberately kept outside the imported Android
    -- source JSON. It is still part of the active session and must be merged
    -- into requests made by a dynamically evaluated source header.
    result.__legado_login_header = source and source.__legado_login_header
    return result
end

local function source_for_request(source, context)
    local header = source and source.header
    if not is_js_rule(header) then
        return source
    end
    local header_context = {}
    for key, value in pairs(context or context_for(source)) do
        header_context[key] = value
    end
    header_context.__legado_evaluating_header = true
    local value, suffix, header_err = js_engine:evaluate_rule(
        source,
        header,
        header_context,
        header_context.result or ""
    )
    if header_err then
        return nil, "source header: " .. tostring(header_err)
    end
    if suffix and trim(suffix) ~= "" then
        return nil, "source header has an unsupported trailing rule"
    end
    if type(value) == "string" then
        local decoded_ok, decoded = pcall(rapidjson.decode, value)
        if decoded_ok then value = decoded end
    end
    if type(value) ~= "table" then
        return nil, "source header JavaScript did not return an object"
    end
    return copy_source_for_request(source, value)
end

-- All non-JavaScript rule paths use this helper so dynamic source headers,
-- login headers, URL options and the WebView substitute are handled uniformly.
-- JavaScript's java.ajax path performs its own equivalent evaluation because
-- it can be called recursively from inside the header rule itself.
local function request_page(source, url, context, extra_options)
    local request_source, source_err = source_for_request(source, context)
    if not request_source then
        return nil, source_err
    end
    local request_options = {}
    if type(extra_options) == "table" then
        for key, value in pairs(extra_options) do
            request_options[key] = value
        end
    elseif type(extra_options) == "string" then
        request_options = extra_options
    end
    if type(request_options) == "table" then
        -- URL options such as `js`, `bodyJs` and dynamically generated
        -- headers are evaluated by Network.get. Keep the current Legado
        -- context private to that layer; it must never enter an HTTP header or
        -- be serialized into the source result.
        request_options.__legado_context = context
    end
    return Network.get(url, request_source, request_options)
end

local function content_page(source, url, context, content_rule)
    local url_options = Network.url_options(url) or {}
    local web_js = trim(rule(content_rule, "webJs"))
    if web_js == "" then web_js = trim(url_options.webJs) end
    local source_regex = trim(rule(content_rule, "sourceRegex"))
    if source_regex == "" then source_regex = trim(url_options.sourceRegex) end
    local use_web_view = url_options.webView == true
        or tostring(url_options.webView):lower() == "true"
    if web_js == "" and source_regex == "" and not use_web_view then
        return request_page(source, url, context)
    end

    local request_source, source_err = source_for_request(source, context)
    if not request_source then
        return nil, source_err
    end
    local raw_html
    if not use_web_view then
        raw_html, source_err = Network.get(url, request_source)
        if not raw_html then return nil, source_err end
    end

    local Browser = require("legado/browser")
    local browser_headers, header_err = Network.browser_headers(request_source, context)
    if not browser_headers then return nil, header_err end
    local browser_result, browser_err = Browser.await(url, {
        source = request_source,
        headers = browser_headers,
        cookies = Network.export_cookies(),
        html = raw_html,
            script = web_js,
            source_regex = source_regex ~= "" and source_regex or nil,
            timeout = tonumber(url_options.timeout) and tonumber(url_options.timeout) / 1000 or nil,
            delay = tonumber(url_options.webViewDelayTime),
            auto = true,
            refetch_after_success = false,
    })
    if not browser_result then
        return nil, browser_err or "WebView content request failed"
    end
    if browser_result.cookies then
        Network.merge_cookies(browser_result.cookies)
    end
    return browser_result.body or "", nil, browser_result
end

web_evaluate = function(source, context, content, script)
    local request_source, source_err = source_for_request(source, context)
    if not request_source then return nil, source_err end
    local Browser = require("legado/browser")
    local browser_headers, header_err = Network.browser_headers(request_source, context)
    if not browser_headers then return nil, header_err end
    local html = content
    if type(html) ~= "string" then
        html = stringify(html)
    end
    local browser_result, browser_err = Browser.await(
        context and context.baseUrl or source.bookSourceUrl or "",
        {
            source = request_source,
            headers = browser_headers,
            cookies = Network.export_cookies(),
            html = html ~= "" and html or nil,
            script = tostring(script or ""),
            auto = true,
            refetch_after_success = false,
        }
    )
    if not browser_result then
        return nil, browser_err or "WebView rule failed"
    end
    if browser_result.cookies then Network.merge_cookies(browser_result.cookies) end
    return browser_result.body or ""
end

local function expand_url(source, rule_value, context)
    local expanded
    if is_js_rule(rule_value) then
        local value, suffix, js_err = js_engine:evaluate_rule(
            source,
            rule_value,
            context,
            context.result or ""
        )
        if js_err then
            return nil, js_err
        end
        if suffix and trim(suffix) ~= "" then
            value, js_err = apply_js_suffix(value, suffix)
            if js_err then
                return nil, js_err
            end
        end
        expanded = stringify(value)
    elseif contains_dynamic_rule(rule_value) then
        -- `<js>...</js>` may be used between ordinary rule segments (for
        -- example a selected href followed by a signing expression). Route
        -- those mixed URL rules through the same generic rule parser instead
        -- of sending the static prefix to QuickJS as invalid JavaScript.
        local value, parse_err = Rules.parse_text(
            context and context.result or "", rule_value, context
        )
        if value == nil then
            return nil, parse_err or "URL rule evaluation failed"
        end
        expanded = value
    else
        local template_error
        expanded, template_error = Rules.expand_templates(rule_value or "", context)
        if not expanded then
            return nil, template_error or "URL template expansion failed"
        end
    end
    expanded = expanded:gsub("<([^<>]*)>", function(page_list)
        local pages = {}
        for page in page_list:gmatch("[^,]+") do
            pages[#pages + 1] = page
        end
        if #pages == 0 then
            return ""
        end
        local index = tonumber(context.page or 1) or 1
        index = math.max(1, math.floor(index))
        return trim(pages[index] or pages[#pages])
    end)
    return Network.absolute(context.baseUrl or source.bookSourceUrl or "", expanded)
end

local function text_value(element, expression, context)
    if expression == nil or expression == "" then
        return ""
    end
    local value, err = Rules.parse_text(element, expression, context)
    if not value then
        return nil, err
    end
    return value
end

local function element_text_value(element, expression, context)
    if expression == nil or expression == "" then
        return ""
    end
    local value, err = Rules.parse_element_text(element, expression, context)
    if not value then
        return nil, err
    end
    return value
end

local function rule_value_text(value)
    if type(value) == "table" and value.__legado_element then
        return Rules.element_property(value, "text")
    end
    return stringify(value)
end

local function rule_values(element, expression, context)
    if expression == nil or trim(expression) == "" then
        return {}
    end
    local values, err = Rules.parse_list(element, expression, context)
    if not values then
        return nil, err
    end
    local result = {}
    for _, value in ipairs(values) do
        local text = rule_value_text(value)
        if trim(text) ~= "" then
            result[#result + 1] = text
        end
    end
    return result
end

local function first_rule_value(element, expression, context)
    local values, err = rule_values(element, expression, context)
    if not values then
        return nil, err
    end
    return values[1] or ""
end

local function javascript_value_text(value)
    if value == nil then return "" end
    if type(value) ~= "table" then return stringify(value) end

    -- Match Rules.parse_text()'s handling of a JavaScript rule without
    -- sending each batch item back through the Lua rule parser.
    for key in pairs(value) do
        if type(key) ~= "number" then
            return stringify(value)
        end
    end
    local values = {}
    for _, item in ipairs(value) do
        values[#values + 1] = stringify(item)
    end
    return table.concat(values, "\n")
end

local function bool_value(value)
    value = tostring(value or ""):lower()
    return value == "true" or value == "1" or value == "yes" or value == "vip" or value == "付费"
end

local function copy_variables(value)
    local result = {}
    if type(value) == "table" then
        for key, child in pairs(value) do
            result[key] = child
        end
    end
    return result
end

local function variables_from(value)
    if type(value) == "table" then
        return copy_variables(value)
    end
    if type(value) == "string" and trim(value) ~= "" then
        local ok, decoded = pcall(rapidjson.decode, value)
        if ok and type(decoded) == "table" then
            return copy_variables(decoded)
        end
    end
    return {}
end

local function save_variables(target, variables)
    if type(target) ~= "table" or type(variables) ~= "table" then
        return
    end
    if next(variables) ~= nil then
        target.variable = copy_variables(variables)
    end
end

local function variables_equal(left, right, depth)
    if left == right then return true end
    if type(left) ~= type(right) or type(left) ~= "table" then
        return false
    end
    if (depth or 0) >= 6 then return false end
    for key, value in pairs(left) do
        if not variables_equal(value, right[key], (depth or 0) + 1) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function compact_chapter_variables(chapters, base_variables)
    if type(chapters) ~= "table" or type(base_variables) ~= "table" then
        return
    end
    for _, chapter in ipairs(chapters) do
        local variables = chapter and chapter.variable
        if type(variables) == "table" then
            local delta = {}
            for key, value in pairs(variables) do
                if not variables_equal(value, base_variables[key], 0) then
                    delta[key] = value
                end
            end
            if next(delta) == nil then
                chapter.variable = nil
            else
                chapter.variable = delta
            end
        end
    end
end

local function extract_books(source, html, stage, context, options)
    local section = source[stage]
    -- Android Legado uses the search rule as the discovery rule when a source
    -- only defines an explore URL.  This is common for older source packs and
    -- is a semantic fallback, not a source-specific adaptation.
    if stage == "ruleExplore"
            and (type(section) ~= "table" or trim(rule(section, "bookList")) == "") then
        section = source.ruleSearch
    end
    if type(section) ~= "table" then
        return nil, stage .. " is missing"
    end
    local list_rule = rule(section, "bookList")
    if list_rule == "" then
        return nil, stage .. ".bookList is empty"
    end
    local elements, err = Rules.elements(html, list_rule, context)
    if not elements then
        return nil, err
    end
    local books = {}
    local lightweight = type(options) == "table"
        and options.lightweight == true
    -- Metadata fields are optional in Android Legado. A broken `kind`,
    -- `wordCount` or cover rule must not discard an otherwise valid search
    -- result, especially for aggregate sources whose JavaScript rules vary
    -- between result items. Once one optional rule fails, skip that field for
    -- the rest of this response instead of repeating the same expensive or
    -- memory-hungry evaluation for every item.
    local disabled_optional_fields = {}
    local book_url_rule = rule(section, "bookUrl")
    local batched_book_urls
    local batched_names = {}
    local batched_contexts = {}
    -- Pure per-item JavaScript URL rules are safe to evaluate in one QuickJS
    -- bridge call. This is important for aggregate JSON sources: a base64
    -- signing expression otherwise starts a full native evaluation for every
    -- result item.
    if is_js_rule(book_url_rule)
            and js_engine:is_batch_safe_rule(book_url_rule) then
        local batch_contexts = {}
        local batch_contents = {}
        local batch_items = {}
        for _, element in ipairs(elements) do
            local item_context = {}
            for key, value in pairs(context) do
                item_context[key] = value
            end
            item_context.rule_variables = {}
            local name = element_text_value(
                element, rule(section, "name"), item_context
            )
            if name and trim(name) ~= "" then
                item_context.book = { name = name }
                batch_items[#batch_items + 1] = element
                batch_contexts[#batch_contexts + 1] = item_context
                batch_contents[#batch_contents + 1] = element
                batched_names[element] = name
                batched_contexts[element] = item_context
            end
        end
        if #batch_items > 0 then
            local values, _, batch_err = js_engine:evaluate_rule_batch(
                source, book_url_rule, batch_contexts, batch_contents
            )
            if values then
                batched_book_urls = {}
                for index, element in ipairs(batch_items) do
                    batched_book_urls[element] = javascript_value_text(values[index])
                end
            else
                -- A source may use a rule that passes the conservative static
                -- check but still exceeds the bridge's batch limits. Fall
                -- back to the normal per-item path for compatibility.
                batched_book_urls = nil
                batched_names = {}
                batched_contexts = {}
            end
        end
    end
    local function optional_field(element, field_name, item_context)
        local expression = rule(section, field_name)
        if expression == "" or disabled_optional_fields[field_name] then
            return ""
        end
        local value, field_err = element_text_value(
            element, expression, item_context
        )
        if field_err then
            disabled_optional_fields[field_name] = true
            return ""
        end
        return value or ""
    end
    for _, element in ipairs(elements) do
        local item_context = batched_contexts[element]
        if not item_context then
            item_context = {}
            for key, value in pairs(context) do
                item_context[key] = value
            end
            item_context.rule_variables = {}
        end
        -- Parse fields relative to the selected result element. This keeps
        -- Jsoup-compatible rules such as `h5@text` working when bookList has
        -- already selected the h5 node itself, while complex rules still use
        -- the complete parser as a fallback.
        local name = batched_names[element]
        if not name then
            local name_err
            name, name_err = element_text_value(
                element, rule(section, "name"), item_context
            )
            if name_err then name = "" end
        end
        local book_url = batched_book_urls and batched_book_urls[element]
        if book_url == nil then
            local url_err
            book_url, url_err = element_text_value(
                element, book_url_rule, item_context
            )
            if url_err then book_url = "" end
        end
        if name and name ~= "" and book_url and book_url ~= "" then
            item_context.book = { name = name }
            local author = optional_field(element, "author", item_context)
            item_context.book.author = author
            local cover_url = ""
            local intro = ""
            local kind = ""
            local last_chapter = ""
            local update_time = ""
            local word_count = ""
            local toc_url = ""
            if lightweight then
                -- Search and source switching only need identity fields plus
                -- the small display metadata below. Details and chapter_list
                -- fetch the remaining fields after a candidate is selected.
                last_chapter = optional_field(
                    element, "lastChapter", item_context
                )
                toc_url = optional_field(element, "tocUrl", item_context)
            else
                cover_url = optional_field(element, "coverUrl", item_context)
                intro = optional_field(element, "intro", item_context)
                kind = optional_field(element, "kind", item_context)
                last_chapter = optional_field(element, "lastChapter", item_context)
                update_time = optional_field(element, "updateTime", item_context)
                word_count = optional_field(element, "wordCount", item_context)
                toc_url = optional_field(element, "tocUrl", item_context)
            end
            local base_url = context.baseUrl or source.bookSourceUrl
            local book = {
                name = name,
                author = author or "",
                bookUrl = Network.absolute(base_url, book_url),
                tocUrl = Network.absolute(base_url, toc_url ~= "" and toc_url or book_url),
                coverUrl = Network.absolute(base_url, cover_url),
                intro = intro or "",
                kind = kind or "",
                lastChapter = last_chapter or "",
                updateTime = update_time or "",
                wordCount = word_count or "",
                sourceName = source.bookSourceName or "",
                sourceUrl = source.bookSourceUrl or "",
            }
            save_variables(book, item_context.rule_variables)
            local source_variable = js_engine:source_variable(source, context)
            if source_variable and source_variable ~= "" then
                book.sourceVariable = source_variable
            end
            books[#books + 1] = book
        end
    end
    return books
end

local function decoded_table(value)
    if type(value) == "table" then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    local text = trim(value)
    if text == "" then return nil end
    local first = text:sub(1, 1)
    if first ~= "[" and first ~= "{" then
        return nil
    end
    local ok, decoded = pcall(rapidjson.decode, text)
    return ok and type(decoded) == "table" and decoded or nil
end

local function copy_explore_style(value)
    if type(value) ~= "table" then return nil end
    local result = {}
    for key, child in pairs(value) do
        if (type(key) == "string" or type(key) == "number")
                and (type(child) == "string" or type(child) == "number"
                    or type(child) == "boolean") then
            result[key] = child
        end
    end
    return result
end

local function explore_chars(value)
    if type(value) == "table" then
        local result = {}
        for _, child in ipairs(value) do
            local text = trim(child)
            if text ~= "" then result[#result + 1] = text end
        end
        return result
    end
    if value == nil then return {} end
    local result = {}
    for child in tostring(value):gmatch("[^,|\n]+") do
        child = trim(child)
        if child ~= "" then result[#result + 1] = child end
    end
    return result
end

local function normalized_explore_kind(value, index, map_title)
    local kind = {}
    if type(value) == "string" or type(value) == "number" then
        local text = trim(value)
        if text == "" then return nil end
        local separator = text:find("::", 1, true)
        if separator then
            kind.title = trim(text:sub(1, separator - 1))
            kind.url = trim(text:sub(separator + 2))
        else
            kind.title = text
            -- A bare URL is useful as a one-line discovery entry. Ordinary
            -- labels remain non-clickable headers, matching Legado's parser.
            local is_url = text:match("^https?://") ~= nil
                or text:match("^/") ~= nil
                or text:match("^data:") ~= nil
                or text:match("^@js:") ~= nil
                or text:match("^<js>") ~= nil
            kind.url = is_url and text or ""
        end
    elseif type(value) == "table" then
        local title = value.title or value.name or value.text or value.label
            or map_title or value.viewName
        local url = value.url or value.exploreUrl or ""
        kind.title = trim(title or "")
        kind.url = trim(url or "")
        kind.type = trim(value.type or value.inputType or "")
        kind.action = value.action or value.onClick or value.callback or ""
        kind.key = value.key or value.paramKey or value.infoKey
        kind.chars = explore_chars(value.chars or value.options or value.values)
        if value.default ~= nil then kind.default = tostring(value.default) end
        if value.value ~= nil then kind.value = tostring(value.value) end
        kind.viewName = value.viewName
        kind.style = copy_explore_style(value.style)
    else
        return nil
    end
    if kind.title == "" and kind.url == "" then return nil end
    if kind.key == nil or trim(kind.key) == "" then
        kind.key = kind.title
    else
        kind.key = tostring(kind.key)
    end
    kind.type = trim(kind.type or ""):lower()
    if kind.type == "" then
        kind.type = trim(kind.action or "") ~= "" and kind.url == ""
            and "button" or "url"
    end
    kind.action = tostring(kind.action or "")
    kind.index = index
    return kind
end

local function normalize_explore_kinds(value)
    local decoded = decoded_table(value)
    if decoded then value = decoded end

    if type(value) == "string" then
        local text = value:gsub("\r\n?", "\n")
        -- Android accepts both newline-separated and &&-separated discovery
        -- entries. This applies only after a whole-script result has been
        -- decoded, so JavaScript logical operators are never split here.
        text = text:gsub("%s*&&%s*", "\n")
        local result = {}
        for line in text:gmatch("[^\n]+") do
            local kind = normalized_explore_kind(line, #result + 1)
            if kind then result[#result + 1] = kind end
        end
        return result
    end
    if type(value) ~= "table" then
        return nil, "exploreUrl did not produce an array or entry list"
    end

    local result = {}
    local array_like = #value > 0
    if array_like then
        for key in pairs(value) do
            if type(key) ~= "number" then array_like = false break end
        end
    end
    if array_like then
        for _, child in ipairs(value) do
            local kind = normalized_explore_kind(child, #result + 1)
            if kind then result[#result + 1] = kind end
        end
    else
        -- Some older source scripts return `{ "分类": "/sort/1" }` instead
        -- of the documented array of ExploreKind objects. Accept that shape
        -- generically while retaining object fields such as `title`/`url`.
        local recognized = value.title ~= nil or value.name ~= nil
            or value.url ~= nil or value.action ~= nil or value.type ~= nil
        if recognized then
            local kind = normalized_explore_kind(value, 1)
            if kind then result[1] = kind end
        else
            local keys = {}
            for key in pairs(value) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local kind = normalized_explore_kind(value[key], #result + 1, key)
                if kind then result[#result + 1] = kind end
            end
        end
    end
    return result
end

local function explore_context(source, kind, page)
    local info = js_engine:explore_info(source)
    local value = kind and kind.value or ""
    return context_for(source, {
        result = "",
        baseUrl = source.bookSourceUrl or "",
        page = page or 1,
        explore = kind,
        exploreKind = kind,
        exploreValue = value or "",
        infoMap = info,
        sourceVariable = js_engine:source_variable(source, {}),
    })
end

local function apply_explore_defaults(kinds, info)
    info = type(info) == "table" and info or {}
    for _, kind in ipairs(kinds or {}) do
        local saved = info[kind.key] or info[kind.title]
        if saved ~= nil then
            kind.value = tostring(saved)
        elseif kind.value == nil then
            kind.value = kind.default
        end
        if kind.value == nil and (kind.type == "select" or kind.type == "toggle") then
            kind.value = kind.chars[1]
        end
    end
end

function Runtime.explore_kinds(source)
    if tonumber(source and source.bookSourceType or 0) ~= 0 then
        return nil, "only text book sources are supported"
    end
    local raw = source and source.exploreUrl
    if raw == nil or trim(raw) == "" then
        return nil, "source has no exploreUrl"
    end
    js_engine:clear_notifications()
    local context = explore_context(source, nil, 1)
    local value = raw
    if is_js_rule(raw) then
        local eval_err
        value, eval_err = evaluate_script(source, raw, context, "")
        if eval_err then return nil, eval_err end
    end
    local kinds, normalize_err = normalize_explore_kinds(value)
    if not kinds then return nil, normalize_err end
    apply_explore_defaults(kinds, js_engine:explore_info(source))
    kinds.notifications = js_engine:take_notifications()
    return kinds
end

function Runtime.explore_source(source, kind, page)
    if tonumber(source and source.bookSourceType or 0) ~= 0 then
        return nil, "only text book sources are supported"
    end
    if type(kind) ~= "table" then
        return nil, "discovery entry is invalid"
    end
    local entry_url = trim(kind.url or "")
    if entry_url == "" then
        return nil, "this discovery entry has no URL"
    end
    js_engine:clear_notifications()
    page = tonumber(page) or 1
    page = math.max(1, math.floor(page))
    local context = explore_context(source, kind, page)
    local url, url_err = expand_url(source, entry_url, context)
    if not url or trim(url) == "" then
        return nil, url_err or "discovery URL is empty"
    end
    local html, request_err = request_page(source, url, context)
    if not html then return nil, request_err end
    local books, books_err = extract_books(source, html, "ruleExplore", context)
    if not books then return nil, books_err end
    return {
        books = books,
        page = page,
        url = url,
        notifications = js_engine:take_notifications(),
    }
end

function Runtime.explore_action(source, kind, value)
    if tonumber(source and source.bookSourceType or 0) ~= 0 then
        return nil, "only text book sources are supported"
    end
    if type(kind) ~= "table" then
        return nil, "discovery entry is invalid"
    end
    js_engine:clear_notifications()
    local info = js_engine:explore_info(source)
    local selected = value
    if selected ~= nil then selected = tostring(selected) end
    if selected ~= nil and trim(kind.key or kind.title or "") ~= "" then
        info[tostring(kind.key or kind.title)] = selected
        -- Keep title-addressed scripts working when a source supplies a
        -- separate parameter key. The source remains the authority for how
        -- it consumes these values.
        if kind.key ~= kind.title then info[tostring(kind.title or "")] = selected end
        js_engine:set_explore_info(source, info)
    end
    local action = trim(kind.action or "")
    local action_result = selected or ""
    if action ~= "" then
        local context = explore_context(source, kind, 1)
        local action_err
        action_result, action_err = evaluate_script(
            source, action, context, selected or ""
        )
        if action_err then return nil, action_err end
        action_result = action_result == nil and "" or action_result
    end
    return {
        actionResult = stringify(action_result),
        infoMap = js_engine:explore_info(source),
        notifications = js_engine:take_notifications(),
    }
end

function Runtime.search_source(source, keyword, page, options)
    if tonumber(source.bookSourceType or 0) ~= 0 then
        return nil, "only text book sources are supported"
    end
    options = type(options) == "table" and options or {}
    local url_options = Network.url_options(source.searchUrl or "")
    local charset = url_options and url_options.charset or "UTF-8"
    local context = context_for(source, {
        key = Network.url_encode(keyword or "", charset),
        keyRaw = keyword or "",
        page = page or 1,
    })
    -- `timeout` historically limited one HTTP request. Search rules may make
    -- several nested java.ajax calls, so expose an optional wall-clock budget
    -- that Network.get can apply to every nested request as well.
    local total_timeout = tonumber(
        options.total_timeout or options.search_timeout
    )
    if total_timeout and total_timeout > 0
            and type(socket.gettime) == "function" then
        context.__legado_deadline = socket.gettime() + total_timeout / 1000
    end
    local url, err = expand_url(source, source.searchUrl, context)
    if not url or url == "" then
        return nil, err or "source has no searchUrl"
    end
    local request_options = {}
    if type(url_options) == "table" then
        for key, value in pairs(url_options) do
            request_options[key] = value
        end
    end
    if type(options) == "table" then
        for key, value in pairs(options) do
            request_options[key] = value
        end
    end
    local html, request_err = request_page(
        source, url, context, request_options
    )
    if not html then
        return nil, request_err
    end
    return extract_books(source, html, "ruleSearch", context, options)
end

function Runtime.book_info(source, book)
    local info_rule = source.ruleBookInfo
    if type(info_rule) ~= "table" then
        return book
    end
    local request_context = context_for(source, {
        result = book.bookUrl or "",
        baseUrl = book.bookUrl or source.bookSourceUrl or "",
        book = book,
        sourceVariable = book.sourceVariable,
        rule_variables = variables_from(book.variable),
    })
    local raw_result, request_err = request_page(source, book.bookUrl, request_context)
    if not raw_result then
        return nil, request_err
    end
    local context = context_for(source, {
        result = raw_result,
        baseUrl = book.bookUrl or source.bookSourceUrl or "",
        book = book,
        sourceVariable = book.sourceVariable,
        rule_variables = variables_from(book.variable),
    })
    local html = raw_result
    local info_init_rule = info_rule.init or info_rule.bookInfoInit or ""
    if info_init_rule ~= "" then
        local value
        if is_js_rule(info_init_rule) then
            local suffix
            local js_err
            value, suffix, js_err = js_engine:evaluate_rule(source, info_init_rule, context, raw_result)
            if js_err then
                return nil, js_err
            end
            if suffix and trim(suffix) ~= "" then
                value, js_err = apply_js_suffix(value, suffix)
                if js_err then
                    return nil, js_err
                end
            end
        else
            local init_err
            value, init_err = Rules.parse_text(raw_result, info_init_rule, context)
            if init_err then
                return nil, "bookInfo.init: " .. tostring(init_err)
            end
        end
        html = value
        context.result = html
    end
    -- Reuse one parsed DOM for the ordinary bookInfo field set. JavaScript or
    -- `init` rules may replace `html` with another value; in that case the
    -- generic parser below still accepts the replacement unchanged.
    if html == raw_result and not is_js_rule(info_rule.name)
            and not is_js_rule(info_rule.author)
            and not is_js_rule(info_rule.intro)
            and not is_js_rule(info_rule.kind)
            and not is_js_rule(info_rule.lastChapter)
            and not is_js_rule(info_rule.updateTime)
            and not is_js_rule(info_rule.coverUrl)
            and not is_js_rule(info_rule.wordCount)
            and not is_js_rule(info_rule.tocUrl) then
        local document, document_err = Rules.parse_document(raw_result)
        if not document then return nil, document_err end
        html = document
    end
    local info = {}
    for _, name in ipairs({ "name", "author", "intro", "kind", "lastChapter", "updateTime", "coverUrl", "wordCount" }) do
        local value, err = text_value(html, rule(info_rule, name), context)
        if err then return nil, err end
        info[name] = value or ""
    end
    info.name = info.name ~= "" and info.name or book.name
    info.author = info.author ~= "" and info.author or book.author
    info.bookUrl = book.bookUrl
    local toc_url, toc_err = text_value(html, rule(info_rule, "tocUrl"), context)
    if toc_err then return nil, toc_err end
    info.tocUrl = Network.absolute(book.bookUrl, toc_url ~= "" and toc_url or book.tocUrl or book.bookUrl)
    info.coverUrl = Network.absolute(book.bookUrl, info.coverUrl)
    info.sourceName = source.bookSourceName or book.sourceName or ""
    save_variables(info, context.rule_variables)
    local source_variable = js_engine:source_variable(source, context)
    if source_variable and source_variable ~= "" then
        info.sourceVariable = source_variable
    end
    return info
end

local function decode_hex(value)
    local input = tostring(value or ""):gsub("%s+", "")
    if #input == 0 or #input % 2 ~= 0 or not input:match("^[%x]+$") then
        return nil, "cover response is not binary data"
    end
    local output = {}
    for index = 1, #input, 2 do
        output[#output + 1] = string.char(
            tonumber(input:sub(index, index + 1), 16)
        )
    end
    return table.concat(output)
end

local function cover_extension(bytes, url, headers)
    if bytes:sub(1, 3) == "\255\216\255" then return "jpg" end
    if bytes:sub(1, 8) == "\137PNG\r\n\026\n" then return "png" end
    if bytes:sub(1, 6) == "GIF87a" or bytes:sub(1, 6) == "GIF89a" then
        return "gif"
    end
    if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
        return "webp"
    end
    local sample = bytes:sub(1, 512):gsub("^\239\187\191", "")
    if sample:lower():find("<svg", 1, true) then return "svg" end

    local content_type = headers and (
        headers["content-type"] or headers["Content-Type"]
    )
    content_type = tostring(content_type or ""):lower()
    if content_type:find("png", 1, true) then return "png" end
    if content_type:find("gif", 1, true) then return "gif" end
    if content_type:find("webp", 1, true) then return "webp" end
    if content_type:find("jpeg", 1, true) or content_type:find("jpg", 1, true) then
        return "jpg"
    end
    if content_type:find("svg", 1, true) then return "svg" end
    if content_type:find("text/html", 1, true) then return nil end

    local extension = tostring(url or ""):match("%.([%a%d]+)[?#]?$")
    extension = extension and extension:lower() or "jpg"
    if extension ~= "jpg" and extension ~= "jpeg" and extension ~= "png"
            and extension ~= "webp" and extension ~= "gif" and extension ~= "svg" then
        extension = "jpg"
    end
    return extension
end

-- Download a cover in the worker process and write it directly to the plugin
-- cache. Network.get intentionally represents binary responses as hex so
-- they can cross the JavaScript boundary; decode them here before writing the
-- image file. The UI thread therefore never carries a full-size cover string.
function Runtime.download_cover(source, book, target_base_path)
    local url = tostring(book and book.coverUrl or "")
    if url == "" then return nil, "book has no cover URL" end
    local hex, headers, code = Network.get(url, source, { type = "bin" })
    if not hex then
        return nil, headers or "cover download failed"
    end
    if code and tonumber(code) >= 400 then
        return nil, "cover download returned HTTP " .. tostring(code)
    end
    local bytes, decode_err = decode_hex(hex)
    if not bytes then return nil, decode_err end
    local extension = cover_extension(bytes, url, headers)
    if not extension then return nil, "cover response is not an image" end

    target_base_path = tostring(target_base_path or "")
    if target_base_path == "" then return nil, "cover cache path is empty" end
    local parent = target_base_path:match("^(.*)/[^/]+$")
    if parent then util.makePath(parent) end
    local path = target_base_path .. "." .. extension
    local temporary = path .. ".tmp"
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, tostring(open_err or "cannot open cover cache") end
    local written, write_err = file:write(bytes)
    file:close()
    if not written then
        os.remove(temporary)
        return nil, tostring(write_err or "cannot write cover cache")
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, tostring(rename_err or "cannot finalize cover cache")
    end
    return path
end

function Runtime.chapter_list(source, book, options)
    local info
    if type(options) == "table" and options.use_cached_info then
        info = cached_book_info(source, book)
    end
    local info_err
    if not info then
        info, info_err = Runtime.book_info(source, book)
    end
    if not info then
        return nil, info_err
    end
    local toc_rule = source.ruleToc
    if type(toc_rule) ~= "table" then
        return nil, "ruleToc is missing"
    end
    local next_url = info.tocUrl or book.tocUrl or book.bookUrl
    local rule_variable_state = variables_from(info.variable or book.variable)
    if toc_rule.preUpdateJs and toc_rule.preUpdateJs ~= "" then
        local pre_context = context_for(source, {
            result = next_url,
            baseUrl = next_url,
            page = 1,
            book = info,
            sourceVariable = info.sourceVariable or book.sourceVariable,
            rule_variables = rule_variable_state,
        })
        local _, pre_err = evaluate_script(source, toc_rule.preUpdateJs, pre_context, next_url)
        if pre_err then
            return nil, "toc preUpdateJs: " .. tostring(pre_err)
        end
    end
    local chapters = {}
    local visited = {}
    local page_count = 0
    local pending_urls = { { url = next_url, follow_next = true } }
    local pending_index = 1
    local chapter_url_rule = rule(toc_rule, "chapterUrl")
    local chapter_name_rule = rule(toc_rule, "chapterName")
    local chapter_vip_rule = rule(toc_rule, "isVip")
    local chapter_pay_rule = rule(toc_rule, "isPay")
    local chapter_volume_rule = rule(toc_rule, "isVolume")
    local chapter_update_rule = rule(toc_rule, "updateTime")
    local simple_name_base = Rules.simple_element_base(chapter_name_rule)
    local simple_url_base = Rules.simple_element_base(chapter_url_rule)
    local simple_vip_base = chapter_vip_rule ~= ""
        and Rules.simple_element_base(chapter_vip_rule) or ""
    local simple_pay_base = chapter_pay_rule ~= ""
        and Rules.simple_element_base(chapter_pay_rule) or ""
    local simple_volume_base = chapter_volume_rule ~= ""
        and Rules.simple_element_base(chapter_volume_rule) or ""
    local simple_update_base = chapter_update_rule ~= ""
        and Rules.simple_element_base(chapter_update_rule) or ""

    local function make_chapter(name, chapter_url, vip, pay, volume, update, variables)
        local volume_value = bool_value(volume)
        local resolved_url = tostring(chapter_url or "")
        if trim(resolved_url) == "" then
            -- This mirrors Legado's BookChapterList behavior: volume rows use
            -- a stable synthetic URL, while ordinary rows fall back to the
            -- current TOC page.  Empty chapterUrl is therefore not a reason
            -- to discard an otherwise valid chapter entry.
            resolved_url = volume_value
                and (tostring(name or "") .. tostring(#chapters + 1))
                or next_url
        end
        local chapter = {
            index = #chapters + 1,
            name = name,
            url = Network.absolute(next_url, resolved_url),
            vip = bool_value(vip),
            isPay = bool_value(pay),
            isVolume = volume_value,
        }
        if update and trim(update) ~= "" then
            chapter.updateTime = tostring(update)
            chapter.tag = tostring(update)
        end
        save_variables(chapter, variables)
        return chapter
    end
    -- A pure JavaScript URL rule can be evaluated for the whole page in one
    -- QuickJS bridge call. Keep the old per-item order when another per-item
    -- JavaScript rule may mutate source state, so generic source semantics are
    -- not changed by this optimization.
    local batch_chapter_url = is_js_rule(chapter_url_rule)
        and js_engine:is_batch_safe_rule(chapter_url_rule)
        -- Name/VIP rules are still evaluated one item at a time below. If
        -- either is JavaScript, keep the original name -> URL -> VIP order;
        -- a source may mutate variables even when its text happens to avoid
        -- the known write-operation tokens.
        and not is_js_rule(chapter_name_rule)
        and not is_js_rule(chapter_vip_rule)
        and not is_js_rule(chapter_pay_rule)
        and not is_js_rule(chapter_volume_rule)
        and not is_js_rule(chapter_update_rule)
    while pending_index <= #pending_urls and page_count < 50 do
        local pending = pending_urls[pending_index]
        next_url = type(pending) == "table" and pending.url or pending
        local follow_next = type(pending) ~= "table" or pending.follow_next ~= false
        pending_index = pending_index + 1
        if next_url ~= "" and not visited[next_url] then
            visited[next_url] = true
            page_count = page_count + 1
            local context = context_for(source, {
            result = next_url,
            baseUrl = next_url,
            page = page_count,
            book = info,
            sourceVariable = info.sourceVariable or book.sourceVariable,
            rule_variables = rule_variable_state,
            })
            local html, request_err = request_page(source, next_url, context)
            if not html then return nil, request_err end
            local list_rule = rule(toc_rule, "chapterList")
            local elements, elements_err = Rules.elements(html, list_rule, context)
            if not elements then return nil, elements_err end
            if batch_chapter_url then
            local item_contexts = {}
            local item_names = {}
            local item_elements = {}
            for _, element in ipairs(elements) do
                local item_context = {}
                for key, value in pairs(context) do
                    item_context[key] = value
                end
                item_context.rule_variables = copy_variables(rule_variable_state)
                local name, name_err = element_text_value(element, chapter_name_rule, item_context)
                if name_err then return nil, name_err end
                item_contexts[#item_contexts + 1] = item_context
                item_names[#item_names + 1] = name
                item_elements[#item_elements + 1] = element
            end

            local batch_urls, _, batch_err = js_engine:evaluate_rule_batch(
                source, chapter_url_rule, item_contexts, item_elements
            )
            if not batch_urls then return nil, batch_err end
            for item_index, element in ipairs(item_elements) do
                local item_context = item_contexts[item_index]
                local name = item_names[item_index]
                local chapter_url = javascript_value_text(batch_urls[item_index])
                if name and name ~= "" then
                    local vip, vip_err = element_text_value(element, chapter_vip_rule, item_context)
                    if vip_err then return nil, vip_err end
                    local pay, pay_err = element_text_value(element, chapter_pay_rule, item_context)
                    if pay_err then return nil, pay_err end
                    local volume, volume_err = element_text_value(element, chapter_volume_rule, item_context)
                    if volume_err then return nil, volume_err end
                    local update, update_err = element_text_value(element, chapter_update_rule, item_context)
                    if update_err then return nil, update_err end
                    local chapter = make_chapter(
                        name, chapter_url, vip, pay, volume, update,
                        item_context.rule_variables
                    )
                    chapters[#chapters + 1] = chapter
                    memory_checkpoint(#chapters)
                end
            end
            elseif simple_name_base and simple_url_base
                and (chapter_vip_rule == "" or simple_vip_base)
                and (chapter_pay_rule == "" or simple_pay_base)
                and (chapter_volume_rule == "" or simple_volume_base)
                and (chapter_update_rule == "" or simple_update_base) then
            -- The overwhelmingly common TOC shape is a list of already
            -- selected anchors with scalar `text`/`href` rules. Avoid making
            -- a fresh context table for each item in that case; any rule
            -- containing templates, operators, JS or @put was rejected by
            -- simple_element_base and remains on the full semantic path.
            for _, element in ipairs(elements) do
                local name, name_err = Rules.parse_element_text(
                    element, chapter_name_rule, context, simple_name_base
                )
                if name_err then return nil, name_err end
                local chapter_url, url_err = Rules.parse_element_text(
                    element, chapter_url_rule, context, simple_url_base
                )
                if url_err then return nil, url_err end
                if name and name ~= "" then
                    local vip = ""
                    if chapter_vip_rule ~= "" then
                        local vip_err
                        vip, vip_err = Rules.parse_element_text(
                            element, chapter_vip_rule, context, simple_vip_base
                        )
                        if vip_err then return nil, vip_err end
                    end
                    local pay = ""
                    if chapter_pay_rule ~= "" then
                        local pay_err
                        pay, pay_err = Rules.parse_element_text(
                            element, chapter_pay_rule, context, simple_pay_base
                        )
                        if pay_err then return nil, pay_err end
                    end
                    local volume = ""
                    if chapter_volume_rule ~= "" then
                        local volume_err
                        volume, volume_err = Rules.parse_element_text(
                            element, chapter_volume_rule, context, simple_volume_base
                        )
                        if volume_err then return nil, volume_err end
                    end
                    local update = ""
                    if chapter_update_rule ~= "" then
                        local update_err
                        update, update_err = Rules.parse_element_text(
                            element, chapter_update_rule, context, simple_update_base
                        )
                        if update_err then return nil, update_err end
                    end
                    local chapter = make_chapter(
                        name, chapter_url, vip, pay, volume, update,
                        rule_variable_state
                    )
                    chapters[#chapters + 1] = chapter
                    memory_checkpoint(#chapters)
                end
            end
            else
            for _, element in ipairs(elements) do
                local item_context = {}
                for key, value in pairs(context) do
                    item_context[key] = value
                end
                item_context.rule_variables = copy_variables(rule_variable_state)
                local name, name_err = element_text_value(element, chapter_name_rule, item_context)
                if name_err then return nil, name_err end
                -- Always let the source's own chapterUrl rule produce the URL.
                -- URL options, data URIs and JavaScript host calls are handled
                -- by the generic rule/network layers; no source family gets a
                -- special URL reconstruction path here.
                local chapter_url, url_err = element_text_value(element, chapter_url_rule, item_context)
                if url_err then return nil, url_err end
                if name and name ~= "" then
                    local vip, vip_err = element_text_value(element, chapter_vip_rule, item_context)
                    if vip_err then return nil, vip_err end
                    local pay, pay_err = element_text_value(element, chapter_pay_rule, item_context)
                    if pay_err then return nil, pay_err end
                    local volume, volume_err = element_text_value(element, chapter_volume_rule, item_context)
                    if volume_err then return nil, volume_err end
                    local update, update_err = element_text_value(element, chapter_update_rule, item_context)
                    if update_err then return nil, update_err end
                    local chapter = make_chapter(
                        name, chapter_url, vip, pay, volume, update,
                        item_context.rule_variables
                    )
                    chapters[#chapters + 1] = chapter
                    memory_checkpoint(#chapters)
                end
            end
            end
            if follow_next then
                local page_nexts, next_err = rule_values(
                    html, rule(toc_rule, "nextTocUrl"), context
                )
                if not page_nexts then return nil, next_err end
                local follow_children = #page_nexts == 1
                for _, page_next in ipairs(page_nexts) do
                    local page_url = Network.absolute(next_url, page_next)
                    if page_url ~= "" then
                        pending_urls[#pending_urls + 1] = {
                            url = page_url,
                            -- Legado follows a single next URL as a chain;
                            -- multiple URLs represent independent TOC pages.
                            follow_next = follow_children,
                        }
                    end
                end
            end
            -- The chapter entries retain only scalar values.  Release the
            -- parsed page tree before requesting/parsing the next page.
            elements = nil
            html = nil
            context = nil
            -- A worker returns immediately after the final page, so there is
            -- no benefit in scanning the just-released large TOC once more.
            memory_checkpoint(#chapters, pending_index <= #pending_urls)
        end
    end
    if page_count >= 50 and pending_index <= #pending_urls then
        return nil, "chapter pagination exceeded safety limit"
    end
    if #chapters == 0 then
        return nil, "chapter list is empty"
    end
    if toc_rule.formatJs and toc_rule.formatJs ~= "" then
        local format_script = tostring(toc_rule.formatJs)
        local format_invocation
        if format_script:match("function%s+formatChapter%s*%(")
                or format_script:match("formatChapter%s*=") then
            format_invocation = "typeof formatChapter === 'function' ? formatChapter(index, title) : undefined"
        end
        for chapter_index, chapter in ipairs(chapters) do
            local format_context = context_for(source, {
                result = chapter.name or "",
                baseUrl = chapter.url or next_url,
                page = 1,
                index = chapter_index,
                title = chapter.name or "",
                chapter = chapter,
                book = info,
                sourceVariable = info.sourceVariable or book.sourceVariable,
                rule_variables = variables_from(chapter.variable or info.variable or book.variable),
            })
            local formatted, format_err = evaluate_script(
                source,
                toc_rule.formatJs,
                format_context,
                chapter.name or "",
                format_invocation
            )
            if format_err then
                return nil, "toc formatJs: " .. tostring(format_err)
            end
            if formatted ~= nil then
                local formatted_text = stringify(formatted)
                if formatted_text ~= "" then
                    chapter.name = formatted_text
                end
            end
            memory_checkpoint(chapter_index)
        end
    end
    local source_variable = js_engine:source_variable(source, {
        sourceVariable = info.sourceVariable or book.sourceVariable,
    })
    if source_variable and source_variable ~= "" then
        info.sourceVariable = source_variable
    end
    save_variables(info, rule_variable_state)
    -- Chapter extraction starts each item with the same rule-variable state as
    -- the book. Keep that common state on info/book only and return per-chapter
    -- deltas. Runtime.chapter_content merges both values, so this preserves
    -- source semantics while avoiding a large repeated book detail in every
    -- chapter entry sent back to the UI and written to the session.
    compact_chapter_variables(chapters, variables_from(info.variable or book.variable))
    return {
        info = info,
        chapters = chapters,
    }
end

function Runtime.chapter_content(source, chapter, book)
    local content_rule = source.ruleContent
    if type(content_rule) ~= "table" then
        return nil, "ruleContent is missing"
    end
    local result = {}
    local next_url = chapter.url
    local pending_urls = { { url = next_url, follow_next = true } }
    local pending_index = 1
    local visited = {}
    local page_count = 0
    local last_html
    local derived_title
    local rule_variable_state = variables_from(book.variable)
    for key, value in pairs(variables_from(chapter.variable)) do
        rule_variable_state[key] = value
    end
    while pending_index <= #pending_urls and page_count < 20 do
        local pending = pending_urls[pending_index]
        next_url = type(pending) == "table" and pending.url or pending
        local follow_next = type(pending) ~= "table" or pending.follow_next ~= false
        pending_index = pending_index + 1
        if next_url ~= "" and not visited[next_url] then
            visited[next_url] = true
            page_count = page_count + 1
            local context = context_for(source, {
            result = next_url,
            baseUrl = next_url,
            page = page_count,
            chapter = chapter,
            book = book,
            sourceVariable = book.sourceVariable,
            rule_variables = rule_variable_state,
            })
            local html, request_err = content_page(source, next_url, context, content_rule)
            if not html then return nil, request_err end
            last_html = html
            local text, text_err = text_value(html, rule(content_rule, "content"), context)
            if text_err then return nil, text_err end
            if page_count == 1 and rule(content_rule, "title") ~= "" then
                local title, title_err = text_value(html, rule(content_rule, "title"), context)
                if title_err then return nil, title_err end
                if title and trim(title) ~= "" then
                    derived_title = trim(title)
                end
            end
            if text and text ~= "" then
                result[#result + 1] = text
            end
            if follow_next then
                local page_nexts, next_err = rule_values(
                    html, rule(content_rule, "nextContentUrl"), context
                )
                if not page_nexts then return nil, next_err end
                local follow_children = #page_nexts == 1
                for _, page_next in ipairs(page_nexts) do
                    local page_url = Network.absolute(next_url, page_next)
                    if page_url ~= "" then
                        pending_urls[#pending_urls + 1] = {
                            url = page_url,
                            follow_next = follow_children,
                        }
                    end
                end
            end
        end
    end
    if page_count >= 20 and pending_index <= #pending_urls then
        return nil, "content pagination exceeded safety limit"
    end

    -- Legado evaluates subContent against the last fetched page and appends
    -- an HTTP result directly when the rule returns a URL. This is useful for
    -- text sources whose main body and a short appendix live separately.
    local sub_rule = rule(content_rule, "subContent")
    if sub_rule ~= "" and last_html then
        local sub_context = context_for(source, {
            result = last_html,
            baseUrl = next_url,
            page = page_count,
            chapter = chapter,
            book = book,
            sourceVariable = book.sourceVariable,
            rule_variables = rule_variable_state,
        })
        local raw_sub_content, sub_err = text_value(last_html, sub_rule, sub_context)
        if sub_err then return nil, sub_err end
        local sub_content = raw_sub_content or ""
        if sub_content:lower():match("^https?://") then
            local sub_page, sub_request_err = request_page(source, sub_content, sub_context)
            if not sub_page then return nil, sub_request_err end
            sub_content = sub_page
        end
        if trim(sub_content) ~= "" then
            result[#result + 1] = sub_content
        end
    end
    if #result == 0 then
        return nil, "chapter content is empty"
    end
    if derived_title then
        chapter.name = derived_title
    end
    local content = table.concat(result, "\n\n")
    if content_rule.replaceRegex and content_rule.replaceRegex ~= "" then
        local replaced, replace_err = Rules.apply_text_rule(
            content,
            content_rule.replaceRegex,
            context_for(source, {
                result = chapter.url or "",
                page = 1,
                chapter = chapter,
                book = book,
                sourceVariable = book.sourceVariable,
                rule_variables = rule_variable_state,
            })
        )
        if not replaced then
            return nil, replace_err
        end
        content = replaced
    end
    -- Mirror Android ContentProcessor after source extraction.  Source-level
    -- `ruleContent.replaceRegex` has already run above, because it may need
    -- to match the source fragment before HTML is flattened.  The common
    -- processor now removes duplicate titles, parses block boundaries,
    -- removes non-content HTML/media, decodes entities and discards empty
    -- paragraphs for every source (including WebView-backed sources).
    content = Content.process(content, {
        title = chapter.name,
        book_name = book and book.name or nil,
        remove_same_title = true,
    })
    if trim(content) == "" then
        return nil, "chapter content is empty after HTML cleanup"
    end
    return content
end

function Runtime.book_sections(source, book, chapters)
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil, "chapter list is empty"
    end
    -- A large return value is later encoded once by the Trapper worker.  Keep
    -- an explicit ceiling so a malformed source cannot exhaust the Kindle's
    -- memory while building one TXT book.
    if #chapters > 5000 then
        return nil, "book has more than 5000 chapters"
    end
    local result = {}
    local total_bytes = 0

    for index, chapter in ipairs(chapters) do
        local content, err = Runtime.chapter_content(source, chapter, book)
        if not content then
            return nil, "chapter " .. tostring(index) .. " failed: " .. tostring(err)
        end
        total_bytes = total_bytes + #content + #(chapter.name or "") + 8
        if total_bytes > 25 * 1024 * 1024 then
            return nil, "book exceeds the 25 MiB TXT safety limit"
        end
        result[#result + 1] = {
            index = index,
            title = chapter.name or ("Chapter " .. tostring(index)),
            content = content,
        }
    end
    return result
end

function Runtime.book_content(source, book, chapters)
    local sections, err = Runtime.book_sections(source, book, chapters)
    if not sections then return nil, err end
    local result = {}
    local title = book.name or ""
    local author = book.author or ""
    local header = title
    if author ~= "" then
        header = header .. "\n" .. author
    end
    result[#result + 1] = header .. "\n\n"
    for _, section in ipairs(sections) do
        result[#result + 1] = string.format(
            "\n\n%s\n\n%s",
            section.title,
            section.content
        )
    end
    return table.concat(result)
end

local function login_invocation(action)
    local value = trim(action or "")
    if value == "" then
        return "login()"
    end
    -- loginUi button definitions normally contain `login()`/`logout()`;
    -- accepting a bare function name also makes hand-authored UIs usable.
    if value:match("^[%a_$][%w_$]*$") then
        return value .. "()"
    end
    return value
end

local function cookie_count(cookies)
    local count = 0
    if type(cookies) ~= "table" then
        return count
    end
    for _, values in pairs(cookies) do
        if type(values) == "table" then
            for _ in pairs(values) do
                count = count + 1
            end
        end
    end
    return count
end

local function javascript_rule_body(value)
    local rule_value = trim(value or "")
    local lowered = rule_value:lower()
    if lowered:match("^@js:") then
        return rule_value:sub(5)
    end
    if lowered:match("^<js>") then
        local close_start = lowered:find("</js>", 5, true)
        if not close_start then return nil, "unterminated <js> rule" end
        return rule_value:sub(5, close_start - 1)
    end
    return rule_value
end

-- loginUi may be a literal JSON array or a JavaScript rule. Android Legado
-- evaluates the latter together with loginUrl/mainJs, so expose the same
-- source-independent path to the Kindle UI instead of showing the raw script
-- as a generic JSON form.
function Runtime.login_ui(source)
    local raw = source and source.loginUi
    if type(raw) == "table" then
        return raw
    end
    if type(raw) ~= "string" or trim(raw) == "" then
        return nil, "source has no loginUi"
    end
    local decoded_ok, decoded = pcall(rapidjson.decode, raw)
    if decoded_ok and type(decoded) == "table" then
        return decoded
    end
    if not is_js_rule(raw) then
        return nil, "loginUi is neither a JSON array nor a JavaScript rule"
    end
    return with_session(source, function()
        local login_body, login_body_err = javascript_rule_body(raw)
        if not login_body then return nil, login_body_err end
        local login_url = trim(source.loginUrl or "")
        local prefix = ""
        -- A normal loginUrl is often a function declaration used by a
        -- dynamic loginUi. Do not treat a literal endpoint URL as JavaScript.
        if login_url ~= "" and not login_url:match("^https?://")
                and not login_url:match("^data:") then
            prefix = javascript_rule_body(login_url) or ""
        end
        local script = "<js>" .. prefix
        if prefix ~= "" then script = script .. "\n" end
        script = script .. login_body .. "</js>"
        local context = context_for(source, {
            result = "",
            baseUrl = source.bookSourceUrl or "",
            sourceVariable = js_engine:source_variable(source, {}),
            book = {},
            chapter = {},
        })
        local value, eval_err = evaluate_script(source, script, context, "")
        if eval_err then return nil, eval_err end
        if type(value) == "string" then
            local value_ok, value_decoded = pcall(rapidjson.decode, value)
            if value_ok then value = value_decoded end
        end
        if type(value) ~= "table" then
            return nil, "dynamic loginUi did not return a JSON array"
        end
        return value
    end)
end

function Runtime.login_info(source)
    local state, err = Session.load(source)
    if not state then
        return nil, err
    end
    local raw = state.loginInfo or "{}"
    local decoded_ok, decoded = pcall(rapidjson.decode, raw)
    if decoded_ok and type(decoded) == "table" then
        return decoded
    end
    return {}
end

function Runtime.login_source(source, values, action)
    if tonumber(source and source.bookSourceType or 0) ~= 0 then
        return nil, "only text book sources are supported"
    end
    local login_url = trim(source and source.loginUrl or "")
    local main_js = trim(source and source.mainJs or "")
    if login_url == "" and main_js == "" then
        return nil, "this source has no loginUrl or mainJs login implementation"
    end
    if type(values) ~= "table" then
        values = {}
    end
    return with_session(source, function()
        js_engine:clear_notifications()
        -- A source with an empty loginUi uses a browser page rather than a
        -- JSON form. Do not replace an already saved login-info object with
        -- an empty table merely because the browser action has no fields.
        if next(values) ~= nil then
            js_engine:set_login_info(source, values)
        end
        local source_variable = js_engine:source_variable(source, {})
        local context = context_for(source, {
            result = values,
            baseUrl = source.bookSourceUrl or "",
            sourceVariable = source_variable,
            loginInfo = values,
        })
        local login_result
        local login_err
        local login_action = login_invocation(action)
        local raw_login_ui = source and source.loginUi
        local has_login_ui = type(raw_login_ui) == "table"
            or (type(raw_login_ui) == "string" and trim(raw_login_ui) ~= "")
        local browser_login = not has_login_ui
            and login_url:match("^https?://") ~= nil
        if browser_login then
            -- Android Legado treats a blank loginUi plus an absolute
            -- loginUrl as a WebView login page. Keep that distinction generic
            -- so sources with captcha/OAuth/QR pages do not get sent through
            -- the JavaScript evaluator as if the URL were source code.
            local Browser = require("legado/browser")
            local browser_headers, headers_err = Network.browser_headers(source, context)
            if not browser_headers then
                return nil, headers_err
            end
            local browser_result, browser_err = Browser.await(login_url, {
                title = source.bookSourceName or "Login",
                source = source,
                headers = browser_headers,
                cookies = Network.export_cookies(),
                context = context,
                auto = false,
                refetch_after_success = true,
            })
            if not browser_result then
                return nil, browser_err or "browser login failed"
            end
            if browser_result.cookies then
                Network.merge_cookies(browser_result.cookies)
            end
            context.result = browser_result.body or ""
            context.src = context.result
            context.baseUrl = browser_result.url or context.baseUrl
            -- Browser completion is itself the action result. Keep the HTML
            -- in the context for loginCheckJs, but do not put a whole page in
            -- the small action-result dialog.
            login_result = ""
        else
            local login_script = source.loginUrl
            if login_url == "" then
                -- Pure JavaScript sources put login()/logout()/settings
                -- actions in mainJs. evaluate_rule loads that library
                -- automatically, so evaluate only the requested invocation
                -- here and avoid running the source implementation twice.
                login_script = "<js>" .. login_action .. "</js>"
                login_action = nil
            end
            login_result, login_err = evaluate_script(
                source,
                login_script,
                context,
                values,
                login_action
            )
        end
        if login_err then
            return nil, "source login failed: " .. tostring(login_err)
        end
        if login_result == false then
            return nil, "source login action returned false"
        end

        local verified = false
        local check_result
        local check_err
        if trim(source.loginCheckJs or "") ~= "" then
            check_result, check_err = evaluate_script(
                source,
                source.loginCheckJs,
                context,
                values
            )
            if check_err then
                return nil, "source login check failed: " .. tostring(check_err)
            end
            local checked_text = tostring(check_result or ""):lower()
            if check_result == false or checked_text == "false" or checked_text == "0" then
                return nil, "source login check returned false"
            end
            verified = check_result ~= nil
        end
        local state = js_engine:export_source_state(source)
        local login_info = {}
        local login_info_ok, decoded_login_info = pcall(
            rapidjson.decode,
            tostring(state.loginInfo or "{}")
        )
        if login_info_ok and type(decoded_login_info) == "table" then
            login_info = decoded_login_info
        end
        local notifications = js_engine:take_notifications()
        return {
            action = login_invocation(action),
            -- A source action can return a useful status string/object (for
            -- example checkStatus()).  Preserve it instead of reducing every
            -- successful action to a generic boolean.
            actionResult = stringify(login_result),
            loginCheckResult = stringify(check_result),
            notifications = notifications,
            verified = verified,
            cookieCount = cookie_count(Network.export_cookies()),
            loginInfoSaved = state.loginInfo ~= nil and state.loginInfo ~= "",
            sourceVariableSaved = state.sourceVariable ~= nil,
            -- Feed values changed by login()/logout() into the next action
            -- instead of overwriting them with the previous form contents.
            loginInfo = login_info,
        }
    end)
end

-- Public runtime methods are wrapped after their definitions so existing
-- callers retain their API while every operation receives the same session
-- restore/save behavior.
local raw_search_source = Runtime.search_source
local raw_explore_kinds = Runtime.explore_kinds
local raw_explore_source = Runtime.explore_source
local raw_explore_action = Runtime.explore_action
local raw_book_info = Runtime.book_info
local raw_chapter_list = Runtime.chapter_list
local raw_chapter_content = Runtime.chapter_content
local raw_book_sections = Runtime.book_sections
local raw_book_content = Runtime.book_content

Runtime.search_source = function(source, keyword, page, options)
    return with_session(source, function()
        return raw_search_source(source, keyword, page, options)
    end)
end

Runtime.explore_kinds = function(source)
    return with_session(source, function()
        return raw_explore_kinds(source)
    end)
end

Runtime.explore_source = function(source, kind, page)
    return with_session(source, function()
        return raw_explore_source(source, kind, page)
    end)
end

Runtime.explore_action = function(source, kind, value)
    return with_session(source, function()
        return raw_explore_action(source, kind, value)
    end)
end

Runtime.book_info = function(source, book)
    return with_session(source, function()
        return raw_book_info(source, book)
    end)
end

Runtime.chapter_list = function(source, book, options)
    return with_session(source, function()
        return raw_chapter_list(source, book, options)
    end)
end

Runtime.chapter_content = function(source, chapter, book)
    return with_session(source, function()
        return raw_chapter_content(source, chapter, book)
    end)
end

Runtime.book_content = function(source, book, chapters)
    return with_session(source, function()
        return raw_book_content(source, book, chapters)
    end)
end

Runtime.book_sections = function(source, book, chapters)
    return with_session(source, function()
        return raw_book_sections(source, book, chapters)
    end)
end

return Runtime
