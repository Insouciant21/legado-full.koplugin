package io.legado.server

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Parses URL option data only. In particular, no source JavaScript runs here. */
internal object SourceUrlOptions {
    private val optionKeys = setOf(
        "method", "body", "headers", "charset", "type", "retry", "webView", "webJs",
        "bodyJs", "js", "serverID", "webViewDelayTime", "proxy", "timeout", "followRedirects", "dnsIp",
        // `sourceRegex` 是 ruleContent 的字段，不是 URL 选项；这里允许它出现在选项里，
        // 是为了让「规则字段 → 请求选项」的贯通使用同一套解析（见 RuleRunner.fetchResponse）。
        "sourceRegex",
    )

    /**
     * 拆分「URL + `,{...}` 选项」。
     *
     * ⚠️ 调用方必须**先把 `{{...}}` 模板渲染掉再调用**（Android `AnalyzeUrl.initUrl()` 同序）：
     * 模板里的 JS 参数自带 `,{}`（虫虫书屋 `java.post(url, body, {})`），先拆会把 JS 拦腰截断，
     * 半截模板既求不了值也拼不出合法 URL（实测整条搜索地址被截到 205 字符）。
     */
    fun split(value: String): Pair<String, JsonObject?> {
        // 1) 优先把**整个**尾缀当作选项 JSON（从右往左找逗号，避免把 URL/body 里的逗号误切）。
        for (index in value.indices.reversed()) {
            if (value[index] != ',') continue
            val suffix = value.substring(index + 1).trim()
            if (!suffix.startsWith('{')) continue
            val options = parse(suffix) ?: continue
            return value.substring(0, index).trimEnd() to recognize(options)
        }
        // 2) 兜底（Android `AnalyzeUrl.analyzeUrl`）：严格解析失败后会用宽松 GSON，
        //    **选项对象之后的多余字符被直接忽略**。书源里这种写法不少，典型是规则
        //    里多写一个引号：`...@href##$##,{"webView":true}"`（小说[自写]特殊写法）。
        //    Android 仍能把 URL 切干净并启用 webView；只认真解析会让整条目录/正文失效。
        return splitLenient(value)
    }

    /**
     * Stable identity used by caches and progress accounting.
     *
     * Android treats the URL-option object as request metadata, not part of the
     * chapter identity. Keeping it in a primary key creates duplicate rows when
     * the same chapter is later parsed without options.
     */
    fun cacheKey(value: String): String = split(value).first

    /**
     * 取第一个 `,` + 空白 + `{` 之后的**平衡对象**作为选项，忽略对象之后的垃圾字符。
     * 与 Android DTO 反序列化一致，只保留 [optionKeys] 中认识的键。
     */
    private fun splitLenient(value: String): Pair<String, JsonObject?> {
        var searchFrom = 0
        while (true) {
            val comma = value.indexOf(',', searchFrom)
            if (comma < 0) return value to null
            searchFrom = comma + 1
            var start = comma + 1
            while (start < value.length && value[start].isWhitespace()) start++
            if (start >= value.length || value[start] != '{') continue
            val end = balancedObjectEnd(value, start) ?: continue
            val options = parse(value.substring(start, end)) ?: continue
            return value.substring(0, comma).trimEnd() to recognize(options)
        }
    }

    /**
     * Android 把 URL 选项反序列化成固定 [AnalyzeUrl.UrlOption] 数据类，JSON 里的未知键
     * 会被 Gson 静默丢弃；即使全部键都未知，逗号后的对象仍从 URL 中剥离，请求按默认
     * UTF-8/GET 执行。
     *
     * 现实书源里出现过 `{“charset”: “gbk”}` 这种弯引号。Gson LENIENT 会把
     * `“charset”` 当成含弯引号的普通未加引号键，因此它是未知键而不是 `charset`。
     * 旧解析器把弯引号当引号，错误启用 GBK，最终把中文关键词编成乱码并返回无关结果。
     */
    private fun recognize(options: JsonObject): JsonObject =
        JsonObject(options.filterKeys { it in optionKeys })

    /** 从 `{` 开始找配对的 `}`（跳过字符串字面量与转义），找不到返回 null。 */
    private fun balancedObjectEnd(text: String, start: Int): Int? {
        var depth = 0
        var index = start
        var quote: Char? = null
        var escaped = false
        while (index < text.length) {
            val character = text[index]
            if (quote != null) {
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == quote -> quote = null
                }
            } else {
                when (character) {
                    '"', '\'' -> quote = character
                    '{' -> depth++
                    '}' -> {
                        depth--
                        if (depth == 0) return index + 1
                    }
                }
            }
            index++
        }
        return null
    }

    private fun parse(text: String): JsonObject? {
        if (text.length > 256 * 1024) return null
        (runCatching { Json.parseToJsonElement(text) }.getOrNull() as? JsonObject)?.let { return it }
        return runCatching { LiteralReader(text).read() }.getOrNull()
    }

    /** Common lenient JSON syntax: single quotes, bare keys/values and trailing commas. */
    private class LiteralReader(private val text: String) {
        private var position = 0

        fun read(): JsonObject {
            val result = value(0) as? JsonObject ?: error("Options must be an object")
            whitespace()
            require(position == text.length) { "Unexpected content after options" }
            return result
        }

        private fun value(depth: Int): JsonElement {
            require(depth < 64) { "Options nesting is too deep" }
            whitespace()
            return when {
                peek() == '{' -> objectValue(depth + 1)
                peek() == '[' -> arrayValue(depth + 1)
                peek().quoteTerminator() != null -> JsonPrimitive(string())
                else -> {
                    val start = position
                    while (position < text.length && !text[position].isWhitespace() && text[position] !in ",]}:") position++
                    require(position > start) { "Missing options value" }
                    val token = text.substring(start, position)
                    when (token) {
                        "null" -> JsonNull
                        "true" -> JsonPrimitive(true)
                        "false" -> JsonPrimitive(false)
                        // Gson LENIENT accepts arbitrary unquoted values. Their exact shape is
                        // irrelevant when the corresponding key is unknown, but preserving it
                        // avoids turning `{“charset”: “gbk”}` into a known `charset` option.
                        else -> JsonPrimitive(token)
                    }
                }
            }
        }

        private fun objectValue(depth: Int): JsonObject {
            expect('{')
            val values = linkedMapOf<String, JsonElement>()
            whitespace()
            if (take('}')) return JsonObject(values)
            while (true) {
                whitespace()
                val key = if (peek() != null && peek().quoteTerminator() != null) string() else {
                    val start = position
                    while (position < text.length && !text[position].isWhitespace() && text[position] != ':') position++
                    require(position > start) { "Missing options key" }
                    text.substring(start, position)
                }
                whitespace()
                expect(':')
                require(key !in values) { "Duplicate options key" }
                values[key] = value(depth)
                whitespace()
                if (take('}')) return JsonObject(values)
                expect(',')
                whitespace()
                if (take('}')) return JsonObject(values)
            }
        }

        private fun arrayValue(depth: Int): JsonArray {
            expect('[')
            val values = mutableListOf<JsonElement>()
            whitespace()
            if (take(']')) return JsonArray(values)
            while (true) {
                values += value(depth)
                whitespace()
                if (take(']')) return JsonArray(values)
                expect(',')
                whitespace()
                if (take(']')) return JsonArray(values)
            }
        }

        private fun string(): String {
            val quote = text[position++].quoteTerminator()
                ?: error("Unsupported options quote")
            val result = StringBuilder()
            while (position < text.length) {
                val character = text[position++]
                if (character == quote) return result.toString()
                if (character != '\\') {
                    require(character.code >= 0x20) { "Unescaped control character" }
                    result.append(character)
                    continue
                }
                require(position < text.length) { "Incomplete options escape" }
                when (val escaped = text[position++]) {
                    '\'', '"', '\\', '/' -> result.append(escaped)
                    'b' -> result.append('\b')
                    'f' -> result.append('\u000C')
                    'n' -> result.append('\n')
                    'r' -> result.append('\r')
                    't' -> result.append('\t')
                    'u' -> {
                        require(position + 4 <= text.length) { "Incomplete Unicode escape" }
                        result.append(text.substring(position, position + 4).toInt(16).toChar())
                        position += 4
                    }
                    else -> error("Unsupported options escape: $escaped")
                }
            }
            error("Unterminated options string")
        }

        private fun whitespace() {
            while (position < text.length && text[position].isWhitespace()) position++
        }

        private fun peek(): Char? = text.getOrNull(position)
        private fun take(character: Char): Boolean = if (peek() == character) { position++; true } else false
        private fun expect(character: Char) = require(take(character)) { "Expected $character in options" }

        private fun Char?.quoteTerminator(): Char? = when (this) {
            '\'' -> '\''
            '"' -> '"'
            else -> null
        }
    }
}
