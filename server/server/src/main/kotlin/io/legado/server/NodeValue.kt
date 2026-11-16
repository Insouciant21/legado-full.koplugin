package io.legado.server

import com.jayway.jsonpath.JsonPath
import com.jayway.jsonpath.PathNotFoundException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import org.jsoup.select.Elements
import org.mozilla.javascript.NativeArray
import org.mozilla.javascript.NativeObject
import org.seimicrawler.xpath.JXDocument
import org.seimicrawler.xpath.JXNode

/**
 * Server-side value node shared by list and field extraction.
 *
 * The execution order intentionally follows Android Legado: JS chains are evaluated first,
 * then selector mode is chosen, and `##regex##replacement` is applied to the extracted value.
 */
internal class NodeValue private constructor(
    private val html: Element?,
    private val json: Any?,
    private val jsValue: Any?,
    private val sourceValue: Any? = jsValue,
) {
    internal enum class UrlExtractionMode {
        JOINED,
        FIRST_HTML,
    }

    /**
     * 规则求值用的变量表。
     *
     * Android `AnalyzeRule` 在一次「字段/步骤」求值里共用同一张变量表：`@put` 写进去的值
     * 后续字段、后续行都能用 `@get` 读到（`put()` 还会落到 Book/Chapter 变量里跨步骤可见）。
     * 因此调用方传入可变表时**必须原地使用**，不能拷贝，否则 `@put` 白写。
     */
    private fun sharedVariablesOf(variables: Map<String, String>?): MutableMap<String, String> =
        (variables as? MutableMap<String, String>) ?: variables?.toMutableMap() ?: mutableMapOf()

    fun value(
        rule: String?,
        jsSandbox: JsSandbox? = null,
        rawBody: String? = null,
        baseUrl: String? = null,
        variables: Map<String, String>? = null,
        urlExtractionMode: UrlExtractionMode = UrlExtractionMode.JOINED,
        /**
         * Android `AnalyzeRule.getString(..., unescape = true)` 的默认语义：结果里出现 `&`
         * 时按 HTML 实体解码（`&amp;` → `&`、`&nbsp;` → 空格）。
         *
         * **中间步骤必须传 false**：Android 的 `getElement`/`getElements`（详情 `init`、
         * 列表节点）不做解码，解码只发生在最终取字符串的边界上；否则 `&amp;amp;`
         * 这类双重转义会被解两次，比手机少一层。
         */
        unescape: Boolean = true,
    ): String? {
        val sharedVariables = sharedVariablesOf(variables)
        val raw = evaluate(rule, jsSandbox, rawBody, baseUrl, sharedVariables, urlExtractionMode) ?: return null
        return if (unescape) unescapeEntitiesIfNeeded(raw) else raw
    }

    /**
     * Android `AnalyzeRule.getString` 里的 `StringEscapeUtils.unescapeHtml4`：
     * 只在结果含 `&` 时解码。用 Jsoup 的实体表（项目内 `cleanContent` 同一个实现），
     * 覆盖 HTML4 具名实体与数字实体。
     */
    private fun unescapeEntitiesIfNeeded(text: String): String =
        if (text.indexOf('&') >= 0) org.jsoup.parser.Parser.unescapeEntities(text, false) else text

    /**
     * Android `AnalyzeRule.getStringList` boundary: JS `NativeArray` and Kotlin lists stay
     * raw until final element conversion; ordinary strings split on newline. Only the
     * next-TOC caller currently uses this list semantics.
     */
    fun valueList(
        rule: String?,
        jsSandbox: JsSandbox? = null,
        rawBody: String? = null,
        baseUrl: String? = null,
        variables: Map<String, String>? = null,
    ): List<String>? {
        val sharedVariables = sharedVariablesOf(variables)
        return evaluateList(rule, jsSandbox, rawBody, baseUrl, sharedVariables)
    }

    fun select(
        rule: String,
        jsSandbox: JsSandbox? = null,
        rawBody: String? = null,
        baseUrl: String? = null,
        variables: Map<String, String>? = null,
    ): List<NodeValue> {
        if (rule.isBlank()) return emptyList()
        val sharedVariables = sharedVariablesOf(variables)
        val cleanRule = executePutRules(rule, jsSandbox, rawBody, baseUrl, sharedVariables)
        val jsChain = splitJavaScriptChain(cleanRule)
        if (jsChain != null) {
            val evaluated = evaluateJavaScriptChain(jsChain, jsSandbox, rawBody, baseUrl, sharedVariables, nodesAsResult = true)
                ?: return emptyList()
            if (jsChain.postRule.isNullOrBlank()) return javaNodes(evaluated)
            val document = document(evaluated, sourceValue)
            return document.select(jsChain.postRule, jsSandbox, evaluated, baseUrl, sharedVariables)
        }

        val split = splitCombination(cleanRule)
        if (split.rules.size == 1) return selectSingle(split.rules[0], jsSandbox, rawBody, baseUrl, sharedVariables)

        val separator = split.separator
        if (split.separator == "||") {
            split.rules.forEach { part ->
                val result = selectSingle(part, jsSandbox, rawBody, baseUrl, sharedVariables)
                if (result.isNotEmpty()) return result
            }
            return emptyList()
        }

        val results = split.rules.mapNotNull { part ->
            selectSingle(part, jsSandbox, rawBody, baseUrl, sharedVariables).ifEmpty { null }
        }
        if (separator == "||") return results.firstOrNull() ?: emptyList()
        if (separator == "%%") return buildList {
            val max = results.maxOfOrNull { it.size } ?: return@buildList
            for (index in 0 until max) results.forEach { if (index < it.size) add(it[index]) }
        }
        return results.flatten()
    }

    /**
     * JS bridge（`java.getElement`/`java.getElements`）专用的**原始节点**选择结果。
     *
     * 与 [value] 的字符串化路径不同，这里不做字符串化：
     * - [nodes] 是完整命中集合的原始载体（HTML→`Element`，JSON/正则→plain 值，其余→节点自值），
     *   对应 Android `AnalyzeRule.getElements`；
     * - [singleValue] 是 getElement 的单值结果，仅 [singleValueMode] 为 true 时有效：JSON 模式走真实
     *   `readJson`（等价 `AnalyzeByJSonPath.getObject`），路径本身返回数组时保留整个数组；
     *   仅在 `forElement` 请求单值时求值，缺失路径与 Android 一样抛出，getElements 不受影响；
     * - HTML/XPath/Regex 规则仍是集合语义（Android `getElement` 对它们返回集合）；
     * - JS 链沿用既有 [select] 求值路径（桥内嵌套求值受 Rhino 限制时会显式失败，不静默清空）。
     */
    internal fun selectRawNodes(
        rule: String?,
        forElement: Boolean = false,
        jsSandbox: JsSandbox? = null,
        rawBody: String? = null,
        baseUrl: String? = null,
        variables: Map<String, String>? = null,
    ): RawNodeSelection {
        if (rule.isNullOrBlank()) return RawNodeSelection(emptyList(), singleValue = null, singleValueMode = true)
        val sharedVariables = sharedVariablesOf(variables)
        // 先做一次 @put 预处理：避免 select() 内部再执行一遍 @put 产生重复副作用。
        val cleanRule = executePutRules(rule, jsSandbox, rawBody, baseUrl, sharedVariables)
        val nodes = select(cleanRule, jsSandbox, rawBody, baseUrl, sharedVariables).map { it.rawNodeValue() }
        if (splitJavaScriptChain(cleanRule) != null) {
            // JS 链沿用 select() 的既有求值路径；嵌套受限时由该路径显式报错，不伪造空结果。
            return RawNodeSelection(nodes, singleValue = null, singleValueMode = false)
        }
        val (mode, selector) = selectorMode(cleanRule.substringBefore("##").trim(), json != null)
        return when (mode) {
            SelectorMode.JSON -> RawNodeSelection(
                nodes,
                singleValue = if (forElement) readJson(selector) else null,
                singleValueMode = true,
            )
            SelectorMode.REGEX -> RawNodeSelection(
                nodes,
                // Android AnalyzeByRegex.getElement 只返回首个 match 的 group 列表；getElements 才返回全部。
                singleValue = if (forElement) nodes.firstOrNull() else null,
                singleValueMode = true,
            )
            else -> RawNodeSelection(nodes, singleValue = null, singleValueMode = false)
        }
    }

    /** 节点的原始载体；不做字符串化（HTML→Element，JSON→plain 值，其余→节点自值）。 */
    internal fun rawNodeValue(): Any? = html ?: json ?: jsValue

    /**
     * [selectRawNodes] 结果：`nodes` 为完整原始命中（getElements），
     * `singleValue`/`singleValueMode` 对应 Android `AnalyzeRule.getElement` 的单值边界。
     */
    internal class RawNodeSelection(
        val nodes: List<Any?>,
        val singleValue: Any?,
        val singleValueMode: Boolean,
    )

    fun at(rule: String?): NodeValue {
        if (json == null || rule.isNullOrBlank() || !rule.trimStart().startsWith("$")) return this
        return runCatching { NodeValue.json(readJson(rule)) }.getOrDefault(this)
    }

    fun fieldVariables(
        rule: String?,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: Map<String, String> = emptyMap(),
    ): Map<String, String> {
        if (rule.isNullOrBlank()) return variables
        val sharedVariables = variables.toMutableMap()
        evaluate(rule, jsSandbox, rawBody, baseUrl, sharedVariables)
        return sharedVariables
    }

    private fun evaluate(
        rule: String?,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
        urlExtractionMode: UrlExtractionMode = UrlExtractionMode.JOINED,
    ): String? {
        if (rule.isNullOrBlank()) return null
        var trimmedRule = rule.trim()
        trimmedRule = executePutRules(trimmedRule, jsSandbox, rawBody, baseUrl, variables)
        // Android `RuleAnalyzer.makeUpRule`：`@get:{k}` 片段是**替换进规则文本**后再执行的。
        // 只有整条规则就是变量取值（可跟 `##正则替换`）时才直接把变量当结果，
        // 否则 `@js:...book_id=@get:{id}...` 这类「变量嵌在长脚本里」的规则会被整条短路成
        // 变量本身（实测 Jk小说 的 chapterUrl 因此每章都只剩 book_id，目录被 URL 去重成 1 章）。
        val getOnlyRule = Regex(
            "^@get:(?:\\{([^{}]+)\\}|([^{}@\\s]+))\\s*(##.*)?$",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        ).find(trimmedRule.trim())
        if (getOnlyRule != null) {
            val key = (getOnlyRule.groupValues[1].takeIf { it.isNotBlank() } ?: getOnlyRule.groupValues[2]).trim()
            val value = variables[key].orEmpty()
            val regexSuffix = getOnlyRule.groupValues[3]
            return if (regexSuffix.isBlank()) value else applyRegexReplace(value, regexSuffix)
        }
        trimmedRule = applyGetVariables(trimmedRule, variables)

        if (trimmedRule.contains("{{") && trimmedRule.contains("}}")) {
            val rendered = renderTemplate(trimmedRule, jsSandbox, rawBody, baseUrl, variables)
            if (json != null && !isRuleExpression(rendered.trim())) {
                val base = rendered.substringBefore("##")
                if (!isRuleExpression(base.trim())) return applyRegexReplace(base, rendered).takeIf { it.isNotBlank() }
            }
            trimmedRule = rendered
        }

        // Android RuleAnalyzer first splits top-level `||`/`&&`/`%%`, then dispatches each
        // candidate (including any `<js>` post-processing on that candidate). If a `<js>`
        // appears only later in the rule, treating the whole composite as one JS chain is wrong:
        // `selector||fallback<js>...</js>` would skip the valid first selector.
        val jsProcessorIndex = listOf(
            trimmedRule.indexOf("<js>", ignoreCase = true),
            findJsPostProcessor(trimmedRule),
        ).filter { it > 0 }.minOrNull()
        if (jsProcessorIndex != null && firstCombinationSeparator(
                trimmedRule.substring(0, jsProcessorIndex),
                setOf("&&", "||", "%%"),
            ) != null
        ) {
            return evaluateTopLevelCombination(trimmedRule, jsSandbox, rawBody, baseUrl, variables, urlExtractionMode)
        }

        val jsChain = splitJavaScriptChain(trimmedRule)
        if (jsChain != null) {
            val evaluated = evaluateJavaScriptChain(
                jsChain,
                jsSandbox,
                rawBody,
                baseUrl,
                variables,
                nodesAsResult = false,
                urlExtractionMode = urlExtractionMode,
            )
                ?: if (jsSandbox?.lastError != null) {
                    throw JsExecutionException("JS 规则执行失败：${jsSandbox.lastError}")
                } else {
                    return null
                }
            if (jsChain.postRule.isNullOrBlank()) return evaluated.takeIf { it.isNotBlank() }
            return document(evaluated, sourceValue).evaluate(
                jsChain.postRule,
                jsSandbox,
                evaluated,
                baseUrl,
                variables,
                urlExtractionMode,
            )
        }

        return evaluatePlainCombination(trimmedRule, rawBody, variables, urlExtractionMode)
    }

    private fun evaluateTopLevelCombination(
        rule: String,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
        urlExtractionMode: UrlExtractionMode,
    ): String? {
        val split = splitCombination(rule)
        if (split.separator == "||") {
            split.rules.forEach { part ->
                evaluate(part, jsSandbox, rawBody, baseUrl, variables, urlExtractionMode)
                    ?.takeIf { it.isNotBlank() }
                    ?.let { return it }
            }
            return null
        }
        return split.rules.mapNotNull { part ->
            evaluate(part, jsSandbox, rawBody, baseUrl, variables, urlExtractionMode)
        }.joinToString("\n").takeIf { it.isNotBlank() }
    }

    private fun evaluateList(
        rule: String?,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
    ): List<String>? {
        if (rule.isNullOrBlank()) return null
        var trimmedRule = rule.trim()
        trimmedRule = executePutRules(trimmedRule, jsSandbox, rawBody, baseUrl, variables)
        if (trimmedRule.contains("@get:", true)) {
            val joined = evaluate(rule, jsSandbox, rawBody, baseUrl, variables)
            return joined?.split("\n")
        }
        if (trimmedRule.contains("{{") && trimmedRule.contains("}}")) {
            val rendered = evaluate(trimmedRule, jsSandbox, rawBody, baseUrl, variables)
            return rendered?.split("\n")
        }

        val jsChain = splitJavaScriptChain(trimmedRule)
        if (jsChain != null) {
            val evaluated = evaluateJavaScriptChainRaw(
                jsChain,
                jsSandbox,
                rawBody,
                baseUrl,
                variables,
                nodesAsResult = false,
                strictNullResult = true,
                listInput = true,
            )
                ?: if (jsSandbox?.lastError != null) {
                    throw JsExecutionException("JS 规则执行失败：${jsSandbox.lastError}")
                } else {
                    return null
                }
            if (jsChain.postRule.isNullOrBlank()) {
                return jsStringList(evaluated, jsChain.regexRule)
            }
            val evaluatedText = jsSandbox?.stringifyJsValue(evaluated).orEmpty()
            return document(evaluated, sourceValue).evaluateList(
                jsChain.postRule,
                jsSandbox,
                evaluatedText,
                baseUrl,
                variables,
            )
        }

        return evaluate(trimmedRule, jsSandbox, rawBody, baseUrl, variables)?.split("\n")
    }

    private fun jsStringList(value: Any?, regexRule: String?): List<String> {
        val values = when (value) {
            is NativeArray -> List(value.length.toInt()) { index -> value.get(index, value) }
            is List<*> -> value
            null -> return emptyList()
            is String -> value.split("\n")
            else -> emptyList()
        }
        return values.map { item ->
            val text = item.toString()
            regexRule?.let { applyRegexReplace(text, it) } ?: text
        }
    }

    private fun selectSingle(
        rule: String,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
    ): List<NodeValue> {
        val cleanRule = rule.trim()
        val jsChain = splitJavaScriptChain(cleanRule)
        if (jsChain != null) {
            val evaluated = evaluateJavaScriptChain(jsChain, jsSandbox, rawBody, baseUrl, variables, nodesAsResult = true) ?: return emptyList()
            val document = document(evaluated, sourceValue)
            return if (jsChain.postRule.isNullOrBlank()) listOf(document)
            else document.select(jsChain.postRule, jsSandbox, evaluated, baseUrl, variables)
        }

        val selectorRule = cleanRule.substringBefore("##").trim()
        val (mode, selector) = selectorMode(selectorRule, json != null)
        return when (mode) {
            SelectorMode.JSON -> selectJson(selector)
            SelectorMode.XPATH -> selectXPath(selector)
            SelectorMode.REGEX -> selectRegex(selector, rawBody)
            SelectorMode.DEFAULT -> selectHtml(selector)
        }
    }

    private fun selectorMode(rule: String, jsonNode: Boolean = false): Pair<SelectorMode, String> = when {
        rule.startsWith("@css:", true) -> SelectorMode.DEFAULT to rule.substring(5).trim()
        rule.startsWith("@@") -> SelectorMode.DEFAULT to rule.substring(2).trim()
        rule.startsWith("@json:", true) -> SelectorMode.JSON to rule.substring(6).trim()
        rule.startsWith("@xpath:", true) -> SelectorMode.XPATH to rule.substring(7).trim()
        rule.startsWith("@regex:", true) -> SelectorMode.REGEX to rule.substring(7).trim()
        rule.startsWith("$.") || rule.startsWith("$[") || rule == "$" -> SelectorMode.JSON to rule
        rule.startsWith("/") -> if (jsonNode && !rule.startsWith("//")) {
            SelectorMode.DEFAULT to rule
        } else {
            SelectorMode.XPATH to rule
        }
        rule.startsWith(":") -> SelectorMode.REGEX to rule.substring(1).trim()
        else -> if (jsonNode && (rule.matches(Regex("[A-Za-z_$][A-Za-z0-9_$.\\-]*")) || rule.isShorthandJsonArraySelector())) {
            SelectorMode.JSON to rule
        } else {
            SelectorMode.DEFAULT to rule
        }
    }

    private fun String.isShorthandJsonArraySelector(): Boolean =
        matches(Regex("[A-Za-z_$][A-Za-z0-9_$.\\-]*(?:\\[(?:\\*|-?\\d+)\\](?:\\.[A-Za-z_$][A-Za-z0-9_$.\\-]*)*)"))

    private fun splitJavaScriptChain(rule: String): JavaScriptChain? {
        var trimmed = rule.trim()
        if (trimmed.startsWith("@js:") || trimmed.startsWith("js:")) {
            val (jsCode, regexRule) = splitRegexSuffix(
                trimmed.removePrefix("@js:").removePrefix("js:"),
            )
            if (jsCode.isBlank()) return null
            return JavaScriptChain("", jsCode, "", regexRule)
        }
        if (trimmed.contains("<js>") && trimmed.contains("</js>")) {
            val preRule = trimmed.substringBefore("<js>").trim()
            val (jsCode, inlineRegexRule) = splitRegexSuffix(
                trimmed.substringAfter("<js>").substringBefore("</js>"),
            )
            var postRule = trimmed.substringAfter("</js>").trim()
            var regexRule = inlineRegexRule
            if (postRule.startsWith("##")) {
                regexRule = postRule
                postRule = ""
            }
            return JavaScriptChain(preRule, jsCode, postRule, regexRule)
        }

        val index = findJsPostProcessor(trimmed)
        if (index <= 0) return null
        val preRule = trimmed.substring(0, index).trim()
        val (jsCode, regexRule) = splitRegexSuffix(
            trimmed.substring(index).removePrefix("@js:").removePrefix("js:"),
        )
        if (jsCode.isBlank()) return null
        return JavaScriptChain(preRule, jsCode, "", regexRule)
    }

    /**
     * Android's SourceRule separates `##regex##replacement` before dispatching a JS
     * segment, then applies the replacement to the JS result. Keep the suffix out of
     * Rhino and carry it alongside the script.
     */
    private fun splitRegexSuffix(rule: String): Pair<String, String?> {
        val index = rule.indexOf("##")
        return if (index >= 0) {
            rule.substring(0, index).trim() to rule.substring(index)
        } else {
            rule.trim() to null
        }
    }

    private fun evaluateJavaScriptChain(
        chain: JavaScriptChain,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
        nodesAsResult: Boolean,
        urlExtractionMode: UrlExtractionMode = UrlExtractionMode.JOINED,
    ): String? {
        if (jsSandbox == null) return rawBody
        val evaluated = evaluateJavaScriptChainRaw(
            chain,
            jsSandbox,
            rawBody,
            baseUrl,
            variables,
            nodesAsResult,
            urlExtractionMode,
        ) ?: return null
        val evaluatedText = jsSandbox.stringifyJsValue(evaluated).orEmpty()
        val replaced = chain.regexRule?.let { applyRegexReplace(evaluatedText, it) } ?: evaluatedText
        return replaced.takeIf { it.isNotBlank() }
    }

    private fun evaluateJavaScriptChainRaw(
        chain: JavaScriptChain,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
        nodesAsResult: Boolean,
        urlExtractionMode: UrlExtractionMode = UrlExtractionMode.JOINED,
        strictNullResult: Boolean = false,
        listInput: Boolean = false,
    ): Any? {
        if (jsSandbox == null) return rawBody
        val selected = when {
            chain.rule.isBlank() -> null
            nodesAsResult -> {
                val nodes = select(chain.rule, jsSandbox, rawBody, baseUrl, variables)
                when (nodes.size) {
                    0 -> ""
                    1 -> nodes[0].jsValue ?: ""
                    else -> nodes.map { it.jsValue }
                }
            }
            listInput -> preRuleStringList(chain.rule, rawBody, variables)
            else -> valuePlain(chain.rule, rawBody, variables, urlExtractionMode)
        }
        val result = if (chain.rule.isBlank()) jsValue else selected
        val listScript = if (strictNullResult && JsSandbox.hasTopLevelReturn(chain.jsCode)) {
            val sentinel = NULL_LIST_SENTINEL
            """
                var nextListValue = (function() {
                    ${chain.jsCode}
                })();
                if (nextListValue === null || typeof nextListValue === 'undefined') return '$sentinel';
                return nextListValue;
            """.trimIndent()
        } else {
            chain.jsCode
        }
        val evaluated = evalJsObject(jsSandbox, listScript, result, sourceValue, baseUrl)
        return when {
            strictNullResult && evaluated == NULL_LIST_SENTINEL -> null
            evaluated != null -> evaluated
            jsSandbox.lastError != null -> {
                throw JsExecutionException("JS 规则执行失败：${jsSandbox.lastError}")
            }
            else -> null
        }
    }

    private fun evalJs(
        jsSandbox: JsSandbox,
        jsCode: String,
        result: Any?,
        source: Any?,
        baseUrl: String?,
    ): String? = jsSandbox.eval(
        jsCode,
        mapOf("result" to (result ?: ""), "src" to (source ?: ""), "baseUrl" to (baseUrl ?: "")),
    )

    /**
     * 规则是否是「单一 JS 段」（纯 `<js>…</js>` / `js:` 前缀，且没有尾段或 `##正则`）。
     *
     * 对应 Android `AnalyzeRule.getElement` 里 `Mode.Js -> evalJS(rule, result)` 那种一步到位的分支：
     * 脚本的返回值会**原样**成为下一个 `setContent` 的内容（对象/数组不字符串化）。
     */
    internal fun isRawJsRule(rule: String?): Boolean {
        val chain = splitJavaScriptChain(rule?.trim().orEmpty()) ?: return false
        return chain.postRule.isBlank() && chain.regexRule == null
    }

    /**
     * 求值「单一 JS 段」并返回**未字符串化**的结果（Android `evalJS` 的返回对象）。
     *
     * 与 [evaluate] 的文本链不同：JSON 对象保持对象，后续 JS 规则才能写 `result.book_id`
     * 这类取值；字符串仍是字符串（`JSON.parse(result)` 这类写法才成立）。
     * 规则不是单一 JS 段、没有沙箱或脚本无返回值时返回 null，调用方回退到文本链。
     */
    internal fun evalRawJsRule(
        rule: String,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
    ): Any? {
        val sandbox = jsSandbox ?: return null
        val chain = splitJavaScriptChain(rule.trim()) ?: return null
        if (chain.postRule.isNotBlank() || chain.regexRule != null) return null
        val selected = if (chain.rule.isBlank()) jsValue else valuePlain(chain.rule, rawBody, variables)
        return evalJsObject(sandbox, chain.jsCode, selected, sourceValue, baseUrl)
    }

    private fun evalJsObject(
        jsSandbox: JsSandbox,
        jsCode: String,
        result: Any?,
        source: Any?,
        baseUrl: String?,
    ): Any? = jsSandbox.evalObject(
        jsCode,
        mapOf("result" to (result ?: ""), "src" to (source ?: ""), "baseUrl" to (baseUrl ?: "")),
    )

    private fun executePutRules(
        rule: String,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
    ): String {
        val matches = Regex("@put:(\\{[^{}]+\\})", RegexOption.IGNORE_CASE).findAll(rule).toList()
        if (matches.isEmpty()) return rule
        var result = rule
        matches.forEach { match ->
            result = result.replace(match.value, "")
            val parsed = parsePutObject(match.groupValues[1])
            parsed.forEach { (key, value) ->
                val valueRule = (value as? JsonPrimitive)?.contentOrNull ?: return@forEach
                val evaluated = evaluate(valueRule, jsSandbox, rawBody, baseUrl, variables)
                if (!evaluated.isNullOrBlank()) variables[key] = evaluated
            }
        }
        return result.trim()
    }

    /**
     * 解析 `@put:{...}`。
     *
     * Android `AnalyzeRule.splitPutRule` 先用 GSONStrict 严格解析成 `Map<String,String>`，
     * 失败后退回宽松 GSON：键可以不带引号，值可以是裸 token（`$.book_id` / 数字 / 布尔），
     * 数字与布尔按字面量转字符串。两次解析都失败时**只记日志**，绝不抛错 ——
     * 匹配到的 `@put:...` 文本照旧从规则里移除。服务端保持同一语义，
     * 否则像 `author@put:{id:$.book_id}` 这种不规范但常见的写法会让整条规则失败。
     */
    private fun parsePutObject(raw: String): JsonObject {
        val empty = buildJsonObject { }
        val text = raw.trim()
        if (text.length < 2 || text.first() != '{' || text.last() != '}') return empty
        val body = text.substring(1, text.length - 1)
        val entries = mutableListOf<Pair<String, String>>()
        var index = 0
        while (index < body.length) {
            while (index < body.length && (body[index].isWhitespace() || body[index] == ',')) index++
            if (index >= body.length) break
            val keyToken = readPutToken(body, index, ':') ?: return empty
            if (keyToken.first.isBlank() || body.getOrNull(keyToken.second) != ':') return empty
            index = keyToken.second + 1
            while (index < body.length && body[index].isWhitespace()) index++
            val valueToken = readPutToken(body, index, ',') ?: return empty
            if (valueToken.first.isBlank() && !isQuotedValue(body, index)) return empty
            entries += keyToken.first to valueToken.first
            // 值后面允许空白（多行 `@put:{...}` 的最后一个键值对后面就是换行）：
            // Gson 宽松解析同样接受尾随空白，旧实现把它当结构错误，整块 @put 直接作废。
            var next = valueToken.second
            while (next < body.length && body[next].isWhitespace()) next++
            if (next < body.length && body[next] != ',') return empty
            index = next
        }
        return buildJsonObject {
            entries.forEach { (key, value) -> put(key, JsonPrimitive(value)) }
        }
    }

    /** 引号（或裸 token）在原文里的起始位置是否带引号。 */
    private fun isQuotedValue(text: String, start: Int): Boolean {
        val ch = text.getOrNull(start) ?: return false
        return ch == '"' || ch == '\''
    }

    /**
     * 读取一个键/值 token，返回「解码后的字符串」与「token 结束后的下标」。
     *
     * - 引号字符串：解码转义序列（`"` 走 JSON 转义，`'` 走手工转义）；
     * - 裸 token：读到处在括号深度 0 的 [terminator] 或文本末尾，允许 `$.a.b`、数字、布尔；
     * - 结构明显不合法（引号未闭合、括号不配对）时返回 null，交由调用方整体忽略。
     */
    private fun readPutToken(text: String, start: Int, terminator: Char): Pair<String, Int>? {
        val first = text.getOrNull(start) ?: return null
        if (first == '"' || first == '\'') {
            val end = skipQuoted(text, start)
            if (end < 0) return null
            return unquoted(text.substring(start, end)) to end
        }
        var index = start
        var depth = 0
        while (index < text.length) {
            val ch = text[index]
            when {
                ch == '{' || ch == '[' -> depth++
                ch == '}' || ch == ']' -> {
                    if (depth == 0) return null
                    depth--
                }
                ch == terminator && depth == 0 -> return text.substring(start, index).trim() to index
            }
            index++
        }
        if (depth != 0) return null
        return text.substring(start).trim() to text.length
    }

    /** 返回引号字符串结束后的下标；引号未闭合返回 -1（Android 在宽松解析下同样整体忽略）。 */
    private fun skipQuoted(text: String, start: Int): Int {
        val quote = text[start]
        var index = start + 1
        while (index < text.length) {
            if (text[index] == '\\') index += 2
            else if (text[index] == quote) return index + 1
            else index++
        }
        return -1
    }

    private fun unquoted(value: String): String {
        val trimmed = value.trim()
        val quote = trimmed.firstOrNull()?.takeIf { it == '"' || it == '\'' } ?: return trimmed
        val body = trimmed.substring(1, trimmed.length - 1)
        if (quote == '"') return runCatching {
            (Json.parseToJsonElement(trimmed) as JsonPrimitive).contentOrNull ?: body
        }.getOrElse { body }
        return buildString {
            var index = 0
            while (index < body.length) {
                if (body[index] == '\\' && index + 1 < body.length) {
                    val next = body[index + 1]
                    if (next == quote || next == '\\') append(next)
                    else append(body[index]).append(next)
                    index += 2
                } else {
                    append(body[index]); index++
                }
            }
        }
    }

    private fun applyGetVariables(rule: String, variables: Map<String, String>): String {
        // Android `RuleAnalyzer.makeUpRule` 的语义是**原地替换**：`@get:{k}` 只是规则文本里的
        // 一段占位符，替换后剩下的规则（JS 脚本、CSS/JSONPath 选择器、`##` 替换）继续生效。
        // 旧实现把整条规则直接换成"所有取值拼接"，任何内嵌 @get 的长规则都会被整段丢弃
        // （实测 Jk小说 的 chapterUrl 整条 JS 脚本被替换成 book_id，目录正文全废）。
        return Regex("@get:(?:\\{([^{}]+)\\}|([^{}@\\s]+))", RegexOption.IGNORE_CASE).replace(rule) { match ->
            val key = (match.groupValues[1].takeIf { it.isNotBlank() } ?: match.groupValues[2]).trim()
            variables[key].orEmpty()
        }
    }

    private fun renderTemplate(
        rule: String,
        jsSandbox: JsSandbox?,
        rawBody: String?,
        baseUrl: String?,
        variables: MutableMap<String, String>,
    ): String = Regex("\\{\\{(.*?)}}", RegexOption.DOT_MATCHES_ALL).replace(rule) { match ->
        val inner = match.groupValues[1].trim()
        if (inner.isBlank()) return@replace ""
        when {
            isRuleExpression(inner) -> evaluate(inner, jsSandbox, rawBody, baseUrl, variables)
            // Android `RuleAnalyzer.makeUpRule` 的 `{{}}` 段就是 evalJS + `?: ""`：
            // 无返回值替换成空串、整数值去掉 `.0`。走模板专用入口（不做全局 result 兜底，
            // 否则 `{{cookie.removeCookie(url)}}` 这类裸表达式会把绑定干净的 result 兜进 URL）。
            jsSandbox != null -> jsSandbox.evalTemplateExpression(
                inner,
                mapOf(
                    "result" to (valuePlain("$.$inner", rawBody, variables) ?: ""),
                    "src" to (sourceValue ?: ""),
                    "baseUrl" to (baseUrl ?: ""),
                ),
                null,
            )
            json != null -> unwrapJsonValue(readJson(if (inner.startsWith("$") || inner.startsWith("..")) inner else "$.$inner"))
            else -> ""
        } ?: ""
    }

    private fun isRuleExpression(rule: String): Boolean = rule.startsWith("@") ||
        rule.startsWith("$.") || rule.startsWith("$[") || rule.startsWith("//") ||
        rule.contains("<js>") || rule.startsWith("js:", ignoreCase = true)

    private fun evaluatePlainCombination(
        rule: String,
        rawBody: String?,
        variables: MutableMap<String, String>,
        urlExtractionMode: UrlExtractionMode = UrlExtractionMode.JOINED,
    ): String? {
        val split = splitCombination(rule)
        if (split.rules.size == 1) return valuePlain(split.rules[0], rawBody, variables, urlExtractionMode)
        if (split.separator == "||") {
            split.rules.forEach { part ->
                evaluatePlainCombination(part, rawBody, variables, urlExtractionMode)
                    ?.takeIf { it.isNotBlank() }
                    ?.let { return it }
            }
            return null
        }
        // 候选自身还可能带**另一种**分隔符（`a@text||b@text&&c@text`）：Android 在内层
        // mode handler（`AnalyzeByJSoup.getStringList` 等）里再切一次，所以这里要对候选递归，
        // 而不是直接当普通选择器求值 —— 否则内层分隔符会被当成属性名，整段静默变成空。
        val values = split.rules.mapNotNull { part -> evaluatePlainCombination(part, rawBody, variables, urlExtractionMode) }
        return when (split.separator) {
            else -> values.joinToString("\n")
        }.takeIf { it?.isNotBlank() == true }
    }

    private fun valuePlain(
        rule: String,
        rawBody: String?,
        variables: Map<String, String>,
        urlExtractionMode: UrlExtractionMode = UrlExtractionMode.JOINED,
    ): String? {
        if (rule.isBlank()) return null
        val clean = applyGetVariables(rule, variables).trim()
        val base = clean.substringBefore("##")
        val (mode, selector) = selectorMode(base, json != null)
        val value = when (mode) {
            SelectorMode.JSON -> extractJson(selector)
            SelectorMode.XPATH -> extractXPath(selector)
            SelectorMode.REGEX -> extractRegexFirst(selector, rawValue(rawBody))
            SelectorMode.DEFAULT -> when {
                json != null && !isExplicitSelectorMode(base) &&
                    (selector.startsWith("http://", ignoreCase = true) ||
                        selector.startsWith("https://", ignoreCase = true) ||
                        selector.contains("{$.")) -> extractJson(selector)
                html != null && isHtmlField(selector) -> htmlFieldValue(html, selector)
                else -> extractHtml(selector, urlExtractionMode)
            }
        }
        return applyRegexReplace(value.orEmpty(), clean).takeIf { it.isNotBlank() }
    }

    /**
     * Android `AnalyzeRule.getStringList` 的模式分发：`@js:` 前段选择器的结果以
     * `List<String>` 原样传给 evalJS（`Mode.Default -> AnalyzeByJSoup.getStringList` 等）。
     * 与标量 [valuePlain] 的差异仅在提取步骤：不把命中合并为单一字符串。
     */
    private fun preRuleStringList(rule: String, rawBody: String?, variables: Map<String, String>): List<String> {
        if (rule.isBlank()) return emptyList()
        val clean = applyGetVariables(rule, variables).trim()
        val base = clean.substringBefore("##")
        val (mode, selector) = selectorMode(base, json != null)
        val combined = combinationList(selector) { part ->
            when (mode) {
                SelectorMode.JSON -> jsonStringList(part)
                SelectorMode.XPATH -> xpathNodes(part).map { it.asString() }
                SelectorMode.REGEX -> listOf(part)
                SelectorMode.DEFAULT -> htmlStringList(part)
            }
        }
        return combined.map { applyRegexReplace(it, clean) }
    }

    /** Android `AnalyzeByJSoup.getStringList`：逐元素取值；属性字段跳过空值并按首见去重。 */
    private fun htmlStringList(rule: String): List<String> {
        val element = html ?: return emptyList()
        val clean = rule.removePrefix("@css:").trim()
        val segments = splitAtOutsideSyntax(clean)
        val field = segments.last()
        val selected = if (segments.size == 1) {
            listOf(element)
        } else {
            segments.dropLast(1).fold(listOf(element)) { nodes, segment ->
                nodes.flatMap { selectHtmlSegment(it, segment) }
            }
        }
        return when (field) {
            "html" -> {
                val collection = Elements().also { nodes -> nodes.addAll(selected) }
                collection.select("script").remove()
                collection.select("style").remove()
                listOfNotNull(collection.outerHtml().takeIf { it.isNotBlank() })
            }
            "all" -> listOf(Elements().also { nodes -> nodes.addAll(selected) }.outerHtml())
            "textNode" -> selected.mapNotNull { node ->
                node.attr(field).takeIf { it.isNotBlank() }
            }.distinct()
            else -> selected.mapNotNull { htmlFieldValue(it, field) }.let { values ->
                if (field in TEXT_FIELD_NAMES) values else values.distinct()
            }
        }
    }

    /** Android `AnalyzeByJSonPath.getStringList`：List 逐项字符串化、标量单条；读失败返回空。 */
    private fun jsonStringList(selector: String): List<String> {
        if (selector.contains("{$.")) {
            return extractJson(selector)?.let { listOf(it) } ?: emptyList()
        }
        val value = runCatching { readJson(selector) }.getOrNull() ?: return emptyList()
        return when (value) {
            is List<*> -> value.map { item -> unwrapJsonValue(item) ?: item.toString() }
            else -> listOf(unwrapJsonValue(value) ?: value.toString())
        }
    }

    private fun isExplicitSelectorMode(rule: String): Boolean =
        rule.startsWith("@css:", ignoreCase = true) ||
            rule.startsWith("@@") ||
            rule.startsWith("@json:", ignoreCase = true) ||
            rule.startsWith("@xpath:", ignoreCase = true) ||
            rule.startsWith("@regex:", ignoreCase = true) ||
            rule.startsWith(":") ||
            rule.startsWith("//")

    private fun selectJson(rule: String): List<NodeValue> {
        val value = runCatching { readJson(rule) }.getOrNull() ?: return emptyList()
        return when (value) {
            is List<*> -> value.map { NodeValue.json(it) }
            else -> listOf(NodeValue.json(value))
        }
    }

    private fun extractJson(rule: String): String? {
        var template = Regex("\\{\\{(.*?)}}", RegexOption.DOT_MATCHES_ALL).replace(rule.substringBefore("##")) { match ->
            val inner = match.groupValues[1].trim()
            unwrapJsonValue(readJsonOrNull(if (inner.startsWith("$") || inner.startsWith("..")) inner else "$.$inner")) ?: ""
        }
        val rendered = renderSingleBraceJsonPaths(template)
        if (rendered != null) return rendered
        val noTokenUrl = template.startsWith("http://", ignoreCase = true) ||
            template.startsWith("https://", ignoreCase = true)
        if (!template.contains("{$.") && !noTokenUrl) {
            return unwrapJsonValue(readJsonOrNull(template))
        }
        return runCatching { unwrapJsonValue(readJson(template)) }.getOrNull()
    }

    private fun renderSingleBraceJsonPaths(template: String): String? {
        if (!template.contains("{$.")) return null
        val result = StringBuilder()
        var successful = false
        var index = 0
        while (index < template.length) {
            if (!template.startsWith("{$.", index)) {
                result.append(template[index])
                index++
                continue
            }
            var depth = 1
            var quote: Char? = null
            var end = index + 1
            while (end < template.length && depth > 0) {
                val character = template[end]
                if (quote != null) {
                    if (character == '\\') {
                        end++
                    } else if (character == quote) {
                        quote = null
                    }
                } else {
                    if (character == '"' || character == '\'') {
                        quote = character
                    } else when (character) {
                        '{' -> depth++
                        '}' -> depth--
                    }
                }
                end++
            }
            if (depth != 0) {
                result.append("{$.")
                index += 3
                continue
            }
            val path = template.substring(index + 1, end - 1).trim()
            val value = runCatching {
                when (val raw = readJsonOrNull(path)) {
                    null -> null
                    is Map<*, *> -> unwrapJsonValue(raw)
                    is List<*> -> unwrapJsonValue(raw)
                    else -> raw.toString()
                }
            }.getOrNull()
            if (value.isNullOrEmpty()) {
                result.append("{$.")
                index += 3
                continue
            } else {
                result.append(value)
                successful = true
                index = end
            }
        }
        return result.toString().takeIf { successful }
    }

    private fun selectXPath(rule: String): List<NodeValue> = xpathNodes(rule).map { node ->
        if (node.isElement) NodeValue.html(node.asElement()) else NodeValue.json(node.asString())
    }

    private fun extractXPath(rule: String): String? = xpathNodes(rule)
        .asSequence()
        .map { it.asString() }
        .filter { it.isNotBlank() }
        .joinToString("\n")
        .takeIf { it.isNotBlank() }

    private fun javaNodes(value: Any?): List<NodeValue> = when (value) {
        is NativeArray -> listOf(NodeValue.json(toPlainJava(value)))
        is NativeObject -> listOf(NodeValue.json(toPlainJava(value)))
        is List<*> -> value.map { NodeValue.json(toPlainJava(it)) }
        is Map<*, *> -> listOf(NodeValue.json(toPlainJava(value)))
        else -> runCatching {
            val element = Json.parseToJsonElement(value?.toString().orEmpty())
            when (element) {
                is JsonArray -> element.map { NodeValue.json(it.toPlainJava()) }
                else -> listOf(NodeValue.json(element.toPlainJava()))
            }
        }.getOrElse { listOf(document(value?.toString().orEmpty())) }
    }

    private fun toPlainJava(value: Any?): Any? = when (value) {
        null -> null
        is NativeArray -> List(value.length.toInt()) { index -> toPlainJava(value.get(index, value)) }
        is NativeObject -> value.ids.filterIsInstance<String>().associateWith { key ->
            toPlainJava((value as Map<*, *>)[key])
        }
        is Map<*, *> -> value.entries.associate { (key, item) -> key.toString() to toPlainJava(item) }
        is List<*> -> value.map { toPlainJava(it) }
        else -> value
    }

    private fun JsonElement.toPlainJava(): Any? = when (this) {
        is JsonNull -> null
        is JsonPrimitive -> contentOrNull ?: toString()
        is JsonArray -> map { it.toPlainJava() }
        is JsonObject -> LinkedHashMap<String, Any?>().also { map ->
            entries.forEach { (key, value) -> map[key] = value.toPlainJava() }
        }
        else -> null
    }

    private fun xpathNodes(rule: String): List<JXNode> {
        val document = html?.let { element ->
            val text = element.outerHtml()
            if (text.trimStart().startsWith("<?xml", true)) {
                JXDocument.create(Jsoup.parse(text, Parser.xmlParser()))
            } else {
                JXDocument.create(Elements(element))
            }
        } ?: JXDocument.create(rawValue(null))
        return runCatching { document.selN(rule) }.getOrDefault(emptyList())
    }

    private fun selectRegex(rule: String, rawBody: String?): List<NodeValue> =
        regexGroups(rule, rawValue(rawBody)).map { NodeValue.json(it) }

    private fun extractRegexFirst(rule: String, input: String): String? =
        regexGroups(rule, input).firstOrNull()?.firstOrNull()

    private fun regexGroups(rule: String, input: String): List<List<String>> {
        val patterns = splitCombination(rule, separators = setOf("&&")).rules
        if (patterns.isEmpty()) return emptyList()
        var current = input
        patterns.forEach { pattern ->
            val regex = runCatching { Regex(pattern) }.getOrElse { return emptyList() }
            val matches = regex.findAll(current).toList()
            if (matches.isEmpty()) return emptyList()
            if (patterns.size == 1) {
                return matches.map { match -> (0 until match.groupValues.size).map(match.groupValues::get) }
            }
            current = matches.joinToString("") { it.value }
        }
        return emptyList()
    }

    private fun selectHtml(rule: String): List<NodeValue> {
        val element = html ?: return emptyList()
        if (rule.startsWith("@css:", true) || rule.startsWith("@@")) {
            val clean = if (rule.startsWith("@css:", true)) rule.substring(5) else rule.substring(2)
            val lastIndex = clean.lastIndexOf('@')
            val css = if (lastIndex > 0) clean.substring(0, lastIndex) else clean
            return runCatching { element.select(css.trim()) }.getOrDefault(Elements()).map { NodeValue.html(it) }
        }

        val segments = splitAtOutsideSyntax(rule)
        if (segments.size == 1) return selectHtmlSegment(element, segments[0]).map { NodeValue.html(it) }
        val field = segments.last()
        if (isHtmlField(field)) {
            val selected = segments.dropLast(1).fold(listOf(element)) { nodes, segment ->
                nodes.flatMap { selectHtmlSegment(it, segment) }
            }
            return selected.map { NodeValue.html(it) }
        }
        return segments.fold(listOf(element)) { nodes, segment ->
            nodes.flatMap { selectHtmlSegment(it, segment) }
        }.map { NodeValue.html(it) }
    }

    private fun extractHtml(rule: String, urlExtractionMode: UrlExtractionMode): String? {
        val element = html ?: return null
        val clean = rule.removePrefix("@css:").trim()
        val segments = splitAtOutsideSyntax(clean)
        if (segments.size == 1) return htmlFieldValue(element, segments[0])
        val field = segments.last()
        if (!isHtmlField(field) && segments.size == 1) return null
        val selected = segments.dropLast(1).fold(listOf(element)) { nodes, segment ->
            nodes.flatMap { selectHtmlSegment(it, segment) }
        }
        val values = selected.mapNotNull { htmlFieldValue(it, field) }
        if (urlExtractionMode == UrlExtractionMode.FIRST_HTML) return values.firstOrNull()?.takeIf { it.isNotBlank() }
        return values.distinct().joinToString("\n").takeIf { it.isNotBlank() }
    }

    private fun selectHtmlSegment(element: Element, rawSegment: String): List<Element> = runCatching {
        val (before, selector) = splitIndexSelector(rawSegment.trim())
        val selected = when {
            before.isBlank() -> element.children().toList()
            before.startsWith("children.") -> element.children().toList()
            // Android `AnalyzeByJSoup.ElementsSingle.getElementsSingle` 对这四个前缀取
            // `beforeRule.split(".")` 的**第二段**（`rules[1]`），后面再多的点分段一律忽略。
            // 例如 `class.bookmore.bookmore-34e68100` 在手机上等价于"取 class=bookmore"，
            // 若把整段当类名查询，会一个元素都匹配不到（实测 小说[自写]特殊写法 目录 URL 为空）。
            // `id` 必须走 `Evaluator.Id` 的全量收集：HTML 常有重复 id（实测 #78 搜索页 30 个
            // `<dl id="nr">`），`getElementById` 只会静默返回第一个，导致 30 条结果变 1 条。
            before.startsWith("id.") -> element.select(translateSelector(before))
            before.startsWith("tag.") -> element.getElementsByTag(legacySelectorArgument(before, "tag.")).toList()
            before.startsWith("class.") -> element.getElementsByClass(legacySelectorArgument(before, "class.")).toList()
            before.startsWith("text.") -> element.getElementsContainingOwnText(legacySelectorArgument(before, "text.")).toList()
            else -> element.select(translateSelector(before)).toList()
        }
        selector?.let { applyElementIndexes(selected, it) } ?: selected
    }.getOrDefault(emptyList())

    /** Android `getElementsSingle`：`class.a.b.c` 只认 `a`（`split(".")[1]`）。 */
    private fun legacySelectorArgument(rule: String, prefix: String): String =
        rule.removePrefix(prefix).substringBefore('.')

    private fun splitIndexSelector(rule: String): Pair<String, List<IndexPart>?> {
        val bracket = Regex("^(.*?)\\[(!)?([^\\[\\]]+)]$").find(rule.trim())
        if (bracket != null) {
            val parts = parseIndexes(bracket.groupValues[3])
            if (parts.isNotEmpty()) {
                return bracket.groupValues[1].trim() to if (bracket.groupValues[2] == "!") parts + IndexPart.Exclusion else parts
            }
            return rule.trim() to null
        }
        val legacy = Regex("^(.*?)([!.])(-?\\d+(?::-?\\d+)*|-?\\d+)$").find(rule.trim())
        if (legacy != null) {
            val parts = parseIndexes(legacy.groupValues[3].replace(':', ','))
            return legacy.groupValues[1].trim() to if (legacy.groupValues[2] == "!") parts + IndexPart.Exclusion else parts
        }
        return rule.trim() to null
    }

    private fun parseIndexes(text: String): List<IndexPart> = buildList {
        text.split(',').forEach { part ->
            val components = part.split(':')
            val numbers = components.map { it.trim().toIntOrNull() }
            if (components.size >= 2 && numbers.all { it != null }) {
                add(IndexPart.Range(numbers[0], numbers.getOrNull(1), numbers.getOrNull(2) ?: 1))
            } else {
                numbers.singleOrNull()?.let { add(IndexPart.Single(it)) }
            }
        }
    }

    private fun applyElementIndexes(elements: List<Element>, parts: List<IndexPart>): List<Element> {
        val size = elements.size
        val selected = LinkedHashSet<Int>()
        parts.forEach { part ->
            when (part) {
                is IndexPart.Single -> normalizeIndex(part.index, size)?.let(selected::add)
                is IndexPart.Range -> {
                    val rawStart = part.start ?: 0
                    val rawEnd = part.end ?: -1
                    var start = rawStart.let { if (it < 0) it + size else it }.coerceIn(0, size - 1)
                    var end = rawEnd.let { if (it < 0) it + size else it }.coerceIn(0, size - 1)
                    val rawStep = part.step
                    if (start == end || (rawStep != null && rawStep >= size)) {
                        selected.add(start)
                        return@forEach
                    }
                    val step = when {
                        rawStep == null -> 1
                        rawStep > 0 -> rawStep
                        -rawStep < size -> rawStep + size
                        else -> 1
                    }
                    if (end > start) {
                        var index = start
                        while (index <= end) { selected.add(index); index += step }
                    } else {
                        var index = start
                        while (index >= end) { selected.add(index); index -= step }
                    }
                }
                IndexPart.Exclusion -> Unit
            }
        }
        val exclusion = parts.filterIsInstance<IndexPart.Exclusion>().isNotEmpty()
        val indexes = if (exclusion) elements.indices.filterNot(selected::contains) else selected.toList()
        return indexes.mapNotNull(elements::getOrNull)
    }

    private fun normalizeIndex(index: Int, size: Int): Int? = when {
        index in 0 until size -> index
        index < 0 && size >= -index -> index + size
        else -> null
    }

    private fun splitAtOutsideSyntax(rule: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var bracket = 0
        var paren = 0
        var quote: Char? = null
        var index = 0
        while (index < rule.length) {
            val char = rule[index]
            if (quote != null) {
                if (char == '\\') { current.append(char); index++; if (index < rule.length) current.append(rule[index]) }
                else { if (char == quote) quote = null; current.append(char) }
            } else when {
                char == '\'' || char == '"' -> { quote = char; current.append(char) }
                char == '[' -> { bracket++; current.append(char) }
                char == ']' -> { bracket--; current.append(char) }
                char == '(' -> { paren++; current.append(char) }
                char == ')' -> { paren--; current.append(char) }
                char == '@' && bracket == 0 && paren == 0 -> { result += current.toString(); current.clear() }
                else -> current.append(char)
            }
            index++
        }
        result += current.toString()
        return result.map { it.trim() }.filter { it.isNotBlank() }.ifEmpty { listOf(rule) }
    }

    private data class RuleSplit(val rules: List<String>, val separator: String)

    /**
     * 组合规则的列表语义，**逐层递归**：`&&` 拼接、`||` 取首个非空候选、`%%` 交错。
     *
     * Android 的切分发生在每个 mode handler 内部（`AnalyzeByJSoup.getStringList` /
     * `AnalyzeByJSonPath` …），因此 `a||b&&c` 先按 `||` 切，候选中残留的 `&&`
     * 由下一层再切。旧实现只切一层，内层分隔符会被当成属性名，整段静默变成空。
     */
    private fun combinationList(selector: String, leaf: (String) -> List<String>): List<String> {
        val split = splitCombination(selector)
        if (split.rules.size == 1) return leaf(selector)
        if (split.separator == "||") {
            split.rules.forEach { part ->
                combinationList(part, leaf).takeIf { it.isNotEmpty() }?.let { return it }
            }
            return emptyList()
        }
        val results = split.rules
            .map { part -> combinationList(part, leaf) }
            .filter { it.isNotEmpty() }
        return when (split.separator) {
            "%%" -> buildList {
                val max = results.maxOfOrNull { it.size } ?: return@buildList
                for (index in 0 until max) {
                    results.forEach { if (index < it.size) add(it[index]) }
                }
            }
            else -> results.flatten()
        }
    }

    /**
     * Android `RuleAnalyzer.splitRule("&&", "||", "%%")` 的等价切分。
     *
     * **必须只按「最先出现」的那一个分隔符切分**：Android 用 `consumeToAny` 从左到右扫描，
     * 第一个命中的分隔符决定 `elementsType`，之后只按它切；`a||b&&c` 切成
     * `["a", "b&&c"]`（内层 `&&` 由后续求值自行处理），而不是 `["a", "b", "c"]`。
     * 旧实现每遇到一个分隔符就覆盖类型、且按所有类型一起切，混合用法会被拼错。
     *
     * 方括号/圆括号/花括号与引号内的分隔符不算（避免切坏选择器与正则）。
     */
    private fun splitCombination(rule: String, separators: Set<String> = setOf("&&", "||", "%%")): RuleSplit {
        val separator = firstCombinationSeparator(rule, separators) ?: "&&"
        val parts = splitOnSeparator(rule, separator)
        val rules = parts.map { it.trim() }.filter { it.isNotBlank() }
        return RuleSplit(rules.ifEmpty { listOf(rule) }, separator)
    }

    /** 从左到右找第一个顶层分隔符；没找到返回 null（Android `elementsType` 为空的情形）。 */
    private fun firstCombinationSeparator(rule: String, separators: Collection<String>): String? =
        scanTopLevel(rule) { index -> separators.firstOrNull { rule.regionMatches(index, it, 0, it.length) } }

    /** 只按 [separator] 切分顶层位置，返回原始片段（保留空白，交给调用方 trim）。 */
    private fun splitOnSeparator(rule: String, separator: String): List<String> {
        if (firstCombinationSeparator(rule, listOf(separator)) == null) return listOf(rule)
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var bracket = 0
        var paren = 0
        var brace = 0
        var quote: Char? = null
        var index = 0
        while (index < rule.length) {
            val char = rule[index]
            if (quote != null) {
                current.append(char)
                if (char == '\\') { index++; if (index < rule.length) current.append(rule[index]) }
                else if (char == quote) quote = null
            } else when {
                char == '\'' || char == '"' -> { quote = char; current.append(char) }
                char == '[' -> { bracket++; current.append(char) }
                char == ']' -> { bracket--; current.append(char) }
                char == '(' -> { paren++; current.append(char) }
                char == ')' -> { paren--; current.append(char) }
                char == '{' -> { brace++; current.append(char) }
                char == '}' -> { brace--; current.append(char) }
                bracket == 0 && paren == 0 && brace == 0 && rule.regionMatches(index, separator, 0, separator.length) -> {
                    result += current.toString(); current.clear(); index += separator.length - 1
                }
                else -> current.append(char)
            }
            index++
        }
        result += current.toString()
        return result
    }

    /**
     * 扫描顶层（不在 `[]`/`()`/`{}`/引号内）位置，返回 [matcher] 的第一个非 null 结果。
     */
    private fun <T> scanTopLevel(rule: String, matcher: (Int) -> T?): T? {
        var bracket = 0
        var paren = 0
        var brace = 0
        var quote: Char? = null
        var index = 0
        while (index < rule.length) {
            val char = rule[index]
            if (quote != null) {
                if (char == '\\') index++ else if (char == quote) quote = null
            } else when {
                char == '\'' || char == '"' -> quote = char
                char == '[' -> bracket++
                char == ']' -> bracket--
                char == '(' -> paren++
                char == ')' -> paren--
                char == '{' -> brace++
                char == '}' -> brace--
                bracket == 0 && paren == 0 && brace == 0 -> matcher(index)?.let { return it }
            }
            index++
        }
        return null
    }

    private fun findJsPostProcessor(rule: String): Int {
        var index = 0
        var quote: Char? = null
        var escaped = false
        while (index < rule.length) {
            val char = rule[index]
            if (quote != null) {
                when {
                    escaped -> escaped = false
                    char == '\\' -> escaped = true
                    char == quote -> quote = null
                }
                index++
                continue
            }
            when {
                char == '\'' || char == '"' -> quote = char
                char == '@' && rule.startsWith("@js:", index) -> return index
                char == 'j' && rule.startsWith("js:", index) && index > 0 && rule[index - 1] == '@' -> return index - 1
            }
            index++
        }
        return -1
    }

    private fun isHtmlField(field: String): Boolean = field in setOf(
        "text", "textNodes", "textNode", "ownText", "html", "all", "href", "src", "content", "alt", "title",
    ) || field.startsWith("attr(") && field.endsWith(")")

    private fun htmlFieldValue(element: Element, field: String): String? = when (field) {
        "text" -> element.text().takeIf { it.isNotBlank() }
        // Android `getResultLast("textNodes")`：逐节点 trim 后**跳过空节点**再以 "\n" 连接。
        "textNodes", "textNode" -> element.textNodes()
            .map { it.text().trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n")
            .takeIf { it.isNotEmpty() }
        "ownText" -> element.ownText().takeIf { it.isNotBlank() }
        "html" -> element.clone().apply { select("script").remove(); select("style").remove() }.outerHtml().takeIf { it.isNotBlank() }
        "all" -> element.outerHtml().takeIf { it.isNotBlank() }
        else -> {
            val attribute = Regex("^attr\\(([^)]+)\\)$").find(field)?.groupValues?.get(1) ?: field
            element.attr(attribute).takeIf { it.isNotBlank() }
        }
    }

    /**
     * Android `AnalyzeRule.replaceRegex(result, rule)`。
     *
     * Android 把规则按 `##` 切成 `[基础规则, 正则, 替换文本, ...]`，**只取前三段**：
     * - 第 4 段存在（规则以 `###` 结尾）⇒ `replaceFirst` 语义：取**第一个命中**的 `group(0)`，
     *   只在它上面做一次替换，其余内容丢弃；没有命中返回**空串**；
     * - 否则对整段结果做全局替换；
     * - 正则非法时退化成**字面量**替换（Android `result.replace(replaceRegex, replacement)`），
     *   旧实现遇到非法正则直接放过原文，且 `###` 形式被当成普通全局替换，都与手机表现不一致。
     *
     * 传入的 [rule] 必须**包含**前导 `##`（如 `selector##p##r`），与 Android 的分段方式一致。
     */
    private fun applyRegexReplace(value: String, rule: String): String {
        val marker = rule.indexOf("##")
        if (marker < 0) return value
        val parts = rule.substring(marker).split("##")
        val pattern = parts.getOrNull(1).orEmpty()
        // Android `if (rule.replaceRegex.isEmpty()) return result`
        if (pattern.isEmpty()) return value
        val replacement = parts.getOrNull(2).orEmpty()
        val regex = runCatching { Regex(pattern) }.getOrNull()
        if (parts.size > 3) {
            if (regex == null) return replacement
            val match = regex.find(value) ?: return ""
            return match.value.replaceFirst(regex, replacement)
        }
        return if (regex != null) value.replace(regex, replacement) else value.replace(pattern, replacement)
    }

    private fun rawValue(rawBody: String?): String = when {
        json != null -> unwrapJsonValue(json) ?: json.toString()
        html != null -> rawBody ?: html.outerHtml()
        else -> rawBody ?: ""
    }

    private fun unwrapJsonValue(value: Any?): String? = when (value) {
        null -> null
        is Map<*, *> -> toJsonText(value)
        is List<*> -> {
            val nonNull = value.filterNotNull()
            when {
                nonNull.any { it is Map<*, *> || it is List<*> } -> toJsonText(nonNull)
                nonNull.size == 1 -> unwrapJsonValue(nonNull[0])
                else -> nonNull.joinToString("\n") { unwrapJsonValue(it) ?: "" }.ifBlank { null }
            }
        }
        else -> value.toString().takeIf { it.isNotBlank() }
    }

    private fun toJsonText(value: Any?): String = runCatching {
        Json.encodeToString(JsonElement.serializer(), toJsonElement(value))
    }.getOrElse { value?.toString() ?: "" }

    private fun toJsonElement(value: Any?): JsonElement = when (value) {
        null -> JsonNull
        is JsonElement -> value
        is String -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Map<*, *> -> JsonObject(value.entries.associate { (key, item) -> key.toString() to toJsonElement(item) })
        is Iterable<*> -> JsonArray(value.map(::toJsonElement))
        else -> JsonPrimitive(value.toString())
    }

    private fun readJson(path: String): Any? {
        val clean = path.trim()
        val normalized = if (clean.startsWith("$")) clean else if (clean.startsWith("..")) "$.$clean" else "$.$clean"
        if (json == null) {
            JsonPath.compile(normalized)
            return null
        }
        return JsonPath.read<Any>(json, normalized)
    }

    /**
     * Android 的 AnalyzeByJSonPath.getString/getStringList 把 `ctx.read` 的异常吞掉后返回空值：
     * 缺少可选字段（如 D012/D055 的 `$.last_update_chapter_name||$..intro`）不能中止整条搜索。
     *
     * 只吞 PathNotFoundException（字段/路径不存在）。语法错误是 InvalidPathException 的另一个分支，
     * 仍要向上抛出，避免把写错的规则静默当成“无值”；JS、网络与解析错误也不在这里处理。
     */
    private fun readJsonOrNull(path: String): Any? = try {
        readJson(path)
    } catch (_: PathNotFoundException) {
        null
    }

    private data class JavaScriptChain(
        val rule: String,
        val jsCode: String,
        val postRule: String,
        val regexRule: String? = null,
    )

    private sealed interface IndexPart {
        data class Single(val index: Int) : IndexPart
        data class Range(val start: Int?, val end: Int?, val step: Int) : IndexPart
        data object Exclusion : IndexPart
    }

    private enum class SelectorMode { DEFAULT, JSON, XPATH, REGEX }

    companion object {
        private const val NULL_LIST_SENTINEL = "__legado-next-list-null__"
        private val TEXT_FIELD_NAMES = setOf("text", "textNodes", "textNode", "ownText", "html", "all")

        fun html(element: Element) = NodeValue(element, null, element)
        fun document(body: String, source: Any? = body): NodeValue {
            val trimmed = body.trimStart()
            return if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
                NodeValue(null, JsonPath.parse(body).json<Any>(), body, source)
            } else {
                NodeValue(Jsoup.parse(body), null, body, source)
            }
        }
        fun json(value: Any?) = NodeValue(null, value, value)
        fun document(value: Any, source: Any? = value): NodeValue = when (value) {
            is NativeArray -> NodeValue(null, toPlainJava(value), value, source)
            is NativeObject -> NodeValue(null, toPlainJava(value), value, source)
            is List<*> -> NodeValue(null, value.map { toPlainJava(it) }, value, source)
            is Map<*, *> -> NodeValue(null, toPlainJava(value), value, source)
            else -> document(value.toString(), source)
        }

        private fun toPlainJava(value: Any?): Any? = when (value) {
            null -> null
            is NativeArray -> List(value.length.toInt()) { index -> toPlainJava(value.get(index, value)) }
            is NativeObject -> value.ids.filterIsInstance<String>().associateWith { key ->
                toPlainJava((value as Map<*, *>)[key])
            }
            is Map<*, *> -> value.entries.associate { (key, item) -> key.toString() to toPlainJava(item) }
            is List<*> -> value.map { toPlainJava(it) }
            else -> value
        }
    }
}

internal fun translateSelector(selector: String): String {
    val value = selector.trim()
    if (value.isEmpty()) return value
    Regex("^id\\.([A-Za-z0-9_\\-]+)$").find(value)?.let { return "#${it.groupValues[1]}" }
    Regex("^tag\\.([A-Za-z0-9_\\-]+)$").find(value)?.let { return it.groupValues[1] }
    return value
}

open class RuleExecutionException(message: String) : RuntimeException(message)

/**
 * 书源 JS 规则执行失败。
 *
 * Android 侧 `JsExtensions` 的脚本错误以 Rhino `ScriptException`/`WrappedException` 抛出，
 * `CheckSourceService` 据此把书源归到 `js失效`。服务端 JS 失败统一收敛在 [JsSandbox.lastError]，
 * 由取值层包装成本异常 —— 它继承 [RuleExecutionException]，因此所有既有
 * 「书源执行失败」处理路径（HTTP 502 / 失败计数 / 消息透出）行为不变，
 * 只有书源校验需要区分时才会捕获它。
 */
class JsExecutionException(message: String) : RuleExecutionException(message)
