-- Text book-source runtime.  This module returns plain Lua tables so callers
-- can safely serialize results from a Trapper subprocess.

local Network = require("legado/network")
local Rules = require("legado/rules")
local Javascript = require("legado/javascript")
local Session = require("legado/session")
local Content = require("legado/content")
local rapidjson = require("rapidjson")

local Runtime = {}
local js_engine = Javascript:new()
local active_session_key

local function memory_checkpoint(counter)
    -- LuaJIT's allocator can otherwise postpone collecting short-lived HTML,
    -- JSON and FFI objects until a large TOC has already been
    -- materialized.  A full collection every 64 records keeps KPW4's peak
    -- resident memory bounded without turning every chapter into a GC pause.
    if counter and counter % 64 == 0 then
        collectgarbage("collect")
    else
        collectgarbage("step", 2000)
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
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
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
    return context
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

local function extract_books(source, html, stage, context)
    local section = source[stage]
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
    for _, element in ipairs(elements) do
        local item_context = {}
        for key, value in pairs(context) do
            item_context[key] = value
        end
        item_context.rule_variables = {}
        local name, name_err = text_value(element, rule(section, "name"), item_context)
        if name_err then
            return nil, name_err
        end
        local book_url, url_err = text_value(element, rule(section, "bookUrl"), item_context)
        if url_err then
            return nil, url_err
        end
        if name and name ~= "" and book_url and book_url ~= "" then
            item_context.book = { name = name }
            local author, author_err = text_value(element, rule(section, "author"), item_context)
            if author_err then return nil, author_err end
            item_context.book.author = author or ""
            local cover_url, cover_err = text_value(element, rule(section, "coverUrl"), item_context)
            if cover_err then return nil, cover_err end
            local intro, intro_err = text_value(element, rule(section, "intro"), item_context)
            if intro_err then return nil, intro_err end
            local kind, kind_err = text_value(element, rule(section, "kind"), item_context)
            if kind_err then return nil, kind_err end
            local last_chapter, last_err = text_value(element, rule(section, "lastChapter"), item_context)
            if last_err then return nil, last_err end
            local book = {
                name = name,
                author = author or "",
                bookUrl = Network.absolute(context.baseUrl or source.bookSourceUrl, book_url),
                tocUrl = Network.absolute(context.baseUrl or source.bookSourceUrl, book_url),
                coverUrl = Network.absolute(context.baseUrl or source.bookSourceUrl, cover_url),
                intro = intro or "",
                kind = kind or "",
                lastChapter = last_chapter or "",
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

function Runtime.search_source(source, keyword, page)
    if tonumber(source.bookSourceType or 0) ~= 0 then
        return nil, "only text book sources are supported"
    end
    local options = Network.url_options(source.searchUrl or "")
    local charset = options and options.charset or "UTF-8"
    local context = context_for(source, {
        key = Network.url_encode(keyword or "", charset),
        keyRaw = keyword or "",
        page = page or 1,
    })
    local url, err = expand_url(source, source.searchUrl, context)
    if not url or url == "" then
        return nil, err or "source has no searchUrl"
    end
    local html, request_err = Network.get(url, source)
    if not html then
        return nil, request_err
    end
    return extract_books(source, html, "ruleSearch", context)
end

function Runtime.book_info(source, book)
    local info_rule = source.ruleBookInfo
    if type(info_rule) ~= "table" then
        return book
    end
    local raw_result, request_err = Network.get(book.bookUrl, source)
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
    if info_rule.init and info_rule.init ~= "" then
        local value
        if is_js_rule(info_rule.init) then
            local suffix
            local js_err
            value, suffix, js_err = js_engine:evaluate_rule(source, info_rule.init, context, raw_result)
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
            value, init_err = Rules.parse_text(raw_result, info_rule.init, context)
            if init_err then
                return nil, "bookInfo.init: " .. tostring(init_err)
            end
        end
        html = value
        context.result = html
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

function Runtime.chapter_list(source, book)
    local info, info_err = Runtime.book_info(source, book)
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
    local chapter_url_rule = rule(toc_rule, "chapterUrl")
    while next_url ~= "" and not visited[next_url] and page_count < 50 do
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
        local html, request_err = Network.get(next_url, source)
        if not html then return nil, request_err end
        local list_rule = rule(toc_rule, "chapterList")
        local elements, elements_err = Rules.elements(html, list_rule, context)
        if not elements then return nil, elements_err end
        for _, element in ipairs(elements) do
            local item_context = {}
            for key, value in pairs(context) do
                item_context[key] = value
            end
            item_context.rule_variables = copy_variables(rule_variable_state)
            local name, name_err = text_value(element, rule(toc_rule, "chapterName"), item_context)
            if name_err then return nil, name_err end
            -- Always let the source's own chapterUrl rule produce the URL.
            -- URL options, data URIs and JavaScript host calls are handled by
            -- the generic rule/network layers; no source family gets a
            -- special URL reconstruction path here.
            local chapter_url, url_err = text_value(element, chapter_url_rule, item_context)
            if url_err then return nil, url_err end
            if name and name ~= "" and chapter_url and chapter_url ~= "" then
                local vip, vip_err = text_value(element, rule(toc_rule, "isVip"), item_context)
                if vip_err then return nil, vip_err end
                local chapter = {
                    index = #chapters + 1,
                    name = name,
                    url = Network.absolute(next_url, chapter_url),
                    vip = bool_value(vip),
                }
                save_variables(chapter, item_context.rule_variables)
                chapters[#chapters + 1] = chapter
                memory_checkpoint(#chapters)
            end
        end
        local page_next, next_err = text_value(html, rule(toc_rule, "nextTocUrl"), context)
        if next_err then return nil, next_err end
        next_url = Network.absolute(next_url, page_next)
        -- The chapter entries retain only scalar values.  Release the parsed
        -- page tree before requesting/parsing the next page.
        elements = nil
        html = nil
        context = nil
        memory_checkpoint(#chapters)
    end
    if page_count >= 50 then
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
    if content_rule.webJs and content_rule.webJs ~= "" then
        return nil, "content webJs uses JavaScript"
    end
    if content_rule.sourceRegex and content_rule.sourceRegex ~= "" then
        return nil, "content sourceRegex is not supported yet"
    end
    local result = {}
    local next_url = chapter.url
    local visited = {}
    local page_count = 0
    local derived_title
    local rule_variable_state = variables_from(book.variable)
    for key, value in pairs(variables_from(chapter.variable)) do
        rule_variable_state[key] = value
    end
    while next_url ~= "" and not visited[next_url] and page_count < 20 do
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
        local html, request_err = Network.get(next_url, source)
        if not html then return nil, request_err end
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
        local page_next, next_err = text_value(html, rule(content_rule, "nextContentUrl"), context)
        if next_err then return nil, next_err end
        next_url = Network.absolute(next_url, page_next)
    end
    if page_count >= 20 then
        return nil, "content pagination exceeded safety limit"
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
    -- Legado's Android reader renders the selected fragment as HTML.  A
    -- downloaded KOReader TXT does not, so normalize only after all source
    -- rules/replacements have run while keeping the source's extracted text
    -- intact.
    content = Content.to_text(content)
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
        js_engine:set_login_info(source, values)
        local source_variable = js_engine:source_variable(source, {})
        local context = context_for(source, {
            result = values,
            baseUrl = source.bookSourceUrl or "",
            sourceVariable = source_variable,
            loginInfo = values,
        })
        local login_script = source.loginUrl
        local login_action = login_invocation(action)
        if login_url == "" then
            -- Pure JavaScript sources put login()/logout()/settings actions
            -- in mainJs. evaluate_rule loads that library automatically, so
            -- evaluate only the requested invocation here and avoid running
            -- the source implementation twice.
            login_script = "<js>" .. login_action .. "</js>"
            login_action = nil
        end
        local login_result, login_err = evaluate_script(
            source,
            login_script,
            context,
            values,
            login_action
        )
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
local raw_book_info = Runtime.book_info
local raw_chapter_list = Runtime.chapter_list
local raw_chapter_content = Runtime.chapter_content
local raw_book_sections = Runtime.book_sections
local raw_book_content = Runtime.book_content

Runtime.search_source = function(source, keyword, page)
    return with_session(source, function()
        return raw_search_source(source, keyword, page)
    end)
end

Runtime.book_info = function(source, book)
    return with_session(source, function()
        return raw_book_info(source, book)
    end)
end

Runtime.chapter_list = function(source, book)
    return with_session(source, function()
        return raw_chapter_list(source, book)
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
