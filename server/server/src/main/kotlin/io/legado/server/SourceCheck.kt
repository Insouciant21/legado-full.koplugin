package io.legado.server

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.mozilla.javascript.RhinoException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI

/**
 * Android 书源校验（`CheckSourceService.doCheckSource` / `checkBook`）的服务端等价实现。
 *
 * 逐条对齐 Android 的校验链与失败归类：
 * 1. 源地址可达性 → 失败加 `域名失效`；
 * 2. 搜索（关键字优先取 `ruleSearch.checkKeyWord`，非法时回退默认值）→ 无结果加 `搜索失效`，
 *    `searchUrl` 为空加 `搜索链接规则为空`；
 * 3. 发现 → 无可用分类加 `发现规则为空`，分类取不到书加 `发现失效`；
 * 4. 详情 → 目录 → 正文（目录只取前 2 章、跳过卷名条目，正文取第一章）。
 *
 * Android 把校验结果写回书源（失效分组 / `respondTime` / `// Error:` 注释），
 * 服务端同样默认写回（`applyResult = false` 可只取报告）；写回走乐观锁，
 * 校验期间书源被改动就放弃这一次写回。
 *
 * 两处刻意的服务端取舍：
 * - `timeoutMs` 对应 Android 的 `withTimeout(CheckSource.timeout)`，但阻塞式规则执行无法
 *   被真正打断 ⇒ 服务端在**每一步之间**判超时（单次网络请求另受书源 `concurrentRate`/
 *   客户端超时约束）；
 * - `steps` 是服务端追加的可观测信息（每段耗时与失败原因），不参与 Android 的失败归类。
 */
@Serializable
data class SourceCheckOptions(
    /** 显式关键字；为空时按 `ruleSearch.checkKeyWord` → Android 默认值「我的」。 */
    val keyword: String? = null,
    val timeoutMs: Long = 180_000L,
    val checkDomain: Boolean = false,
    val checkSearch: Boolean = true,
    val checkDiscovery: Boolean = true,
    val checkInfo: Boolean = true,
    val checkCategory: Boolean = true,
    val checkContent: Boolean = true,
    val applyResult: Boolean = true,
    val writeErrorComment: Boolean = true,
)

@Serializable
data class SourceCheckStep(
    val step: String,
    val ok: Boolean,
    val elapsedMs: Long,
    val message: String? = null,
)

@Serializable
data class SourceCheckBook(
    val name: String,
    val author: String? = null,
    val bookUrl: String,
    val tocUrl: String? = null,
    val firstChapter: String? = null,
    val chapterCount: Int = 0,
    /** 文件型书源（`bookSourceType=3`）只有下载链接，没有目录。 */
    val downloadUrls: List<String> = emptyList(),
)

@Serializable
data class SourceCheckResult(
    val sourceId: String,
    val sourceName: String? = null,
    val ok: Boolean,
    val keyword: String,
    val steps: List<SourceCheckStep>,
    val invalidGroups: List<String> = emptyList(),
    val respondTimeMs: Long,
    val book: SourceCheckBook? = null,
    val error: String? = null,
    val applied: Boolean = false,
)

@Serializable
data class SourceCheckRequest(
    val ids: List<String>? = null,
    val options: SourceCheckOptions = SourceCheckOptions(),
)

@Serializable
data class SourceCheckResponse(
    val total: Int,
    val passed: Int,
    val failed: Int,
    val durationMs: Long,
    val results: List<SourceCheckResult>,
)

/** 与 RuleRunner 中的私有同名扩展互不冲突：这里是本文件作用域。 */
private fun JsonObject.checkString(key: String): String? =
    (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

private fun JsonObject.checkInt(key: String): Int? =
    (get(key) as? JsonPrimitive)?.contentOrNull?.trim()?.toIntOrNull()

internal class SourceChecker(
    private val runner: RuleRunner,
    private val database: Database? = null,
) {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Android `NoStackTraceException`：只表示「校验结论」，不是网络/脚本故障，
     * 因此不会再额外加 `网站失效` 分组。
     */
    private class CheckFailure(message: String) : RuntimeException(message)

    /** Android `TocEmptyException`。 */
    private class TocEmpty(message: String) : RuntimeException(message)

    /** Android `ContentEmptyException`。 */
    private class ContentEmpty(message: String) : RuntimeException(message)

    /** Android `TimeoutCancellationException`（`withTimeout(CheckSource.timeout)`）。 */
    private class CheckTimeout(message: String) : RuntimeException(message)

    private class CheckBookOutcome(
        var book: SourceCheckBook? = null,
    )

    fun check(sourceJson: String, options: SourceCheckOptions = SourceCheckOptions()): SourceCheckResult {
        val source = runCatching { json.parseToJsonElement(sourceJson).jsonObject }
            .getOrElse { throw RuleExecutionException("书源定义不是 JSON 对象：${it.message}") }
        val sourceKey = source.checkString("bookSourceUrl").orEmpty()
        val sourceName = source.checkString("bookSourceName")
        val keyword = resolveCheckKeyword(source, options.keyword)
        val timeoutMs = options.timeoutMs.coerceIn(5_000L, 600_000L)
        val startedAt = System.currentTimeMillis()
        val deadline = startedAt + timeoutMs
        // Android 在书源对象上原地 addGroup/removeGroup，最后 getInvalidGroupNames() 作为结论。
        val addedGroups = linkedSetOf<String>()
        val steps = mutableListOf<SourceCheckStep>()
        val outcome = CheckBookOutcome()

        fun ensureNotTimedOut() {
            if (System.currentTimeMillis() > deadline) throw CheckTimeout("校验超时")
        }

        fun step(name: String, block: () -> Unit) {
            val stepStarted = System.currentTimeMillis()
            val result = runCatching(block)
            val elapsed = System.currentTimeMillis() - stepStarted
            steps += SourceCheckStep(name, result.isSuccess, elapsed, result.exceptionOrNull()?.message)
            result.getOrThrow()
        }

        val failure = runCatching {
            ensureNotTimedOut()
            // 1) 源地址可访问性（Android 默认关闭）
            if (options.checkDomain) {
                step("domain") {
                    val domain = sourceKey
                    if (!domain.startsWith("http", ignoreCase = true)) throw CheckFailure("源地址不是http链接")
                    if (domainReachable(domain)) {
                        addedGroups.remove(DOMAIN_INVALID)
                    } else {
                        addedGroups += DOMAIN_INVALID
                        throw CheckFailure("源地址不可访问")
                    }
                }
            }
            // 2) 校验搜索书籍
            if (options.checkSearch) {
                ensureNotTimedOut()
                val searchWord = keyword
                val searchUrl = source.checkString("searchUrl")
                if (!searchUrl.isNullOrBlank()) {
                    addedGroups.remove(SEARCH_RULE_EMPTY)
                    step("search") {
                        val books = runner.search(sourceJson, searchWord)
                        if (books.isEmpty()) {
                            addedGroups += SEARCH_INVALID
                        } else {
                            addedGroups.remove(SEARCH_INVALID)
                            checkBook(source, sourceJson, books.first(), isSearchBook = true, options = options, outcome = outcome, addedGroups = addedGroups)
                        }
                    }
                } else {
                    addedGroups += SEARCH_RULE_EMPTY
                }
            }
            // 3) 校验发现书籍。Android：exploreUrl 为空时**不做任何事**（不加分组）。
            if (options.checkDiscovery && !source.checkString("exploreUrl").isNullOrBlank()) {
                ensureNotTimedOut()
                step("discovery") {
                    val url = runner.exploreCategories(sourceJson).firstOrNull { !it.url.isNullOrBlank() }?.url
                    if (url.isNullOrBlank()) {
                        addedGroups += DISCOVERY_RULE_EMPTY
                    } else {
                        addedGroups.remove(DISCOVERY_RULE_EMPTY)
                        val books = runner.exploreBooks(sourceJson, url, 1)
                        if (books.isEmpty()) {
                            addedGroups += DISCOVERY_INVALID
                        } else {
                            addedGroups.remove(DISCOVERY_INVALID)
                            checkBook(source, sourceJson, books.first(), isSearchBook = false, options = options, outcome = outcome, addedGroups = addedGroups)
                        }
                    }
                }
            }
            val finalCheckMessage = invalidGroupNames(addedGroups)
            if (finalCheckMessage.isNotBlank()) throw CheckFailure(finalCheckMessage)
        }.exceptionOrNull()

        val ok = failure == null
        if (!ok) {
            when (failure) {
                is CheckTimeout -> addedGroups += TIMEOUT_INVALID
                // Android：`ScriptException`/`WrappedException` ⇒ `js失效`。
                is JsExecutionException, is RhinoException -> addedGroups += JS_INVALID
                is CheckFailure, is TocEmpty, is ContentEmpty -> Unit
                else -> addedGroups += SITE_INVALID
            }
        }
        val elapsed = System.currentTimeMillis() - startedAt
        val result = SourceCheckResult(
            sourceId = sourceKey,
            sourceName = sourceName,
            ok = ok,
            keyword = keyword,
            steps = steps,
            invalidGroups = addedGroups.toList(),
            // Android Debug.updateFinalMessage：成功记耗时，失败记 timeout + 耗时。
            respondTimeMs = if (ok) elapsed else timeoutMs + elapsed,
            book = outcome.book,
            error = failure?.message,
        )
        if (options.applyResult) {
            return result.copy(applied = applyResult(sourceJson, sourceKey, result, options))
        }
        return result
    }

    /**
     * Android `CheckSourceService.checkBook`：校验详情 → 目录 → 正文。
     *
     * 失败只归类为 `${搜索|发现}目录失效` / `${搜索|发现}正文失效`，
     * 其他异常原样上抛（由外层归为 `js失效` / `网站失效`）。
     */
    private fun checkBook(
        source: JsonObject,
        sourceJson: String,
        book: SearchResult,
        isSearchBook: Boolean,
        options: SourceCheckOptions,
        outcome: CheckBookOutcome,
        addedGroups: MutableSet<String>,
    ) {
        if (!options.checkInfo) return
        val bookType = if (isSearchBook) "搜索" else "发现"
        // Android `checkBook(book = searchBook.toBook(), ...)`：详情/目录/正文都跑在**同一本书**上，
        // 搜索结果的书名/作者/类型、以及搜索响应里 `@put` 写下的变量（`book.getVariable('x')`、
        // `java.get('x')`）必须一路带着，否则规则拿不到参数，会把好源误判成「目录/正文失效」。
        val bookContext = BookContext(
            sourceId = source.checkString("bookSourceUrl").orEmpty(),
            bookUrl = book.bookUrl,
            name = book.name,
            author = book.author,
            tocUrl = book.tocUrl,
            kind = book.bookKind,
            variables = book.variables.toMutableMap(),
        )
        var tocUrl = book.tocUrl.orEmpty()
        var bookName = book.name
        var chapterCount = 0
        var firstChapter: Chapter? = null
        try {
            if (tocUrl.isBlank()) {
                // Android BookInfo 对文件型书源取不到下载链接时抛 `NoStackTraceException("下载链接为空")`：
                // 这是「书源结论」，校验层面不追加 `网站失效`。
                val details = try {
                    runner.details(sourceJson, book.bookUrl, bookContext)
                } catch (error: DownloadUrlsEmptyException) {
                    throw CheckFailure(error.message ?: "下载链接为空")
                }
                tocUrl = details.tocUrl
                bookContext.tocUrl = tocUrl
                bookName = details.name.ifBlank { bookName }
                // Android BookInfo 的文件型书源分支：只取下载链接，没有目录、没有章节。
                if (source.checkInt("bookSourceType") == FILE_SOURCE_TYPE) {
                    if (details.downloadUrls.isEmpty()) throw CheckFailure("下载链接为空")
                    outcome.book = SourceCheckBook(
                        name = bookName,
                        author = details.author ?: book.author,
                        bookUrl = book.bookUrl,
                        tocUrl = null,
                        firstChapter = null,
                        chapterCount = 0,
                        downloadUrls = details.downloadUrls,
                    )
                    return
                }
            }
            // Android：文件型书源不做目录/正文校验。
            if (!options.checkCategory || source.checkInt("bookSourceType") == FILE_SOURCE_TYPE) return
            val chapters = runner.chapters(sourceJson, tocUrl, bookContext)
                .filter { !(it.isVolume && it.url.startsWith(it.title)) }
                .take(2)
            val first = chapters.firstOrNull() ?: throw TocEmpty("目录为空")
            chapterCount = chapters.size
            firstChapter = first
            if (!options.checkContent) return
            val content = runner.content(sourceJson, first.url, bookName, bookContext)
            if (content.content.isBlank()) throw ContentEmpty("正文为空")
        } catch (error: Throwable) {
            when (error) {
                is TocEmpty -> addedGroups += "${bookType}目录失效"
                is ContentEmpty -> addedGroups += "${bookType}正文失效"
                else -> throw error
            }
            return
        }
        addedGroups.remove("${bookType}目录失效")
        addedGroups.remove("${bookType}正文失效")
        outcome.book = SourceCheckBook(
            name = bookName,
            author = book.author,
            bookUrl = book.bookUrl,
            tocUrl = tocUrl.takeIf { it.isNotBlank() },
            firstChapter = firstChapter?.title,
            chapterCount = chapterCount,
        )
    }

    /**
     * Android `BookSource.getCheckKeyword(default)`：`ruleSearch.checkKeyWord` 非空、
     * 且不含 `http`/`::`/`++`/`--` 时才采用，否则回退默认关键字（Android 默认「我的」）。
     */
    private fun resolveCheckKeyword(source: JsonObject, override: String?): String {
        override?.takeIf { it.isNotBlank() }?.let { return it }
        val declared = source["ruleSearch"]?.jsonObject?.get("checkKeyWord")?.jsonPrimitive?.content
        if (!declared.isNullOrBlank() &&
            !declared.contains("http") && !declared.contains("::") &&
            !declared.contains("++") && !declared.contains("--")
        ) {
            return declared
        }
        return DEFAULT_CHECK_KEYWORD
    }

    /** Android `BookSource.getInvalidGroupNames()`：只收集名字里带「失效」或等于「校验超时」的分组。 */
    private fun invalidGroupNames(groups: Set<String>): String =
        groups.filter { "失效" in it || it == TIMEOUT_INVALID }.joinToString()

    /** Android `isDomainReachable(domain)`：直连 host:port，1600ms 超时；服务端额外拒绝内网目标。 */
    private fun domainReachable(url: String): Boolean = runCatching {
        val uri = URI(url.substringBefore("#"))
        val host = uri.host ?: return@runCatching false
        NetworkSecurity.resolveAndValidateSafeHttpTarget(uri, "书源")
        val port = if (uri.port > 0) uri.port else 80
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), DOMAIN_PROBE_TIMEOUT_MS)
        }
        true
    }.getOrDefault(false)

    /**
     * 把校验结果写回书源，逐条对齐 Android `BookSource` 的分组与注释方法：
     * 1. `removeInvalidGroups()`：删掉所有名字带「失效」或等于「校验超时」的分组；
     * 2. `removeErrorComment()`：删掉以 `// Error: ` 开头的段落（Android 用 `\n` 重新拼接）；
     * 3. `addGroup(...)`：写入本次校验新产生的失效分组；
     * 4. 失败时 `addErrorComment`：`// Error: <消息>` 置顶。
     * `respondTime` 同样回填（成功=耗时，失败=timeout+耗时）。写回走乐观锁。
     */
    private fun applyResult(
        sourceJson: String,
        sourceKey: String,
        result: SourceCheckResult,
        options: SourceCheckOptions,
    ): Boolean {
        val database = database ?: return false
        if (sourceKey.isBlank()) return false
        val record = database.getSource(sourceKey) ?: return false
        if (record.json != sourceJson) {
            // 校验期间书源被改动：结果已过期，放弃写回（Android 单线程写库不存在该窗口）。
            return false
        }
        val payload = runCatching { json.parseToJsonElement(record.json).jsonObject }.getOrNull() ?: return false
        val mutable = payload.toMutableMap()
        mutable["respondTime"] = JsonPrimitive(result.respondTimeMs)
        val groups = payload.checkString("bookSourceGroup")
            ?.split(GROUP_SPLIT_REGEX)
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.toMutableList()
            ?: mutableListOf()
        groups.removeAll { "失效" in it || it == TIMEOUT_INVALID }
        result.invalidGroups.forEach { group -> if (group !in groups) groups += group }
        mutable["bookSourceGroup"] = JsonPrimitive(groups.joinToString(","))
        if (options.writeErrorComment) {
            val cleaned = payload.checkString("bookSourceComment")
                ?.split("\n\n")
                ?.filterNot { it.startsWith(ERROR_COMMENT_PREFIX) }
                ?.joinToString("\n")
                .orEmpty()
            mutable["bookSourceComment"] = JsonPrimitive(
                result.error?.let { message ->
                    "$ERROR_COMMENT_PREFIX$message" + if (cleaned.isBlank()) "" else "\n\n$cleaned"
                } ?: cleaned
            )
        }
        val updatedJson = JsonObject(mutable).toString()
        val parsed = runCatching { SourceCodec.parse(updatedJson, keepGroup = true) }.getOrNull() ?: return false
        return runCatching {
            database.saveSource(parsed, record.version)
            true
        }.getOrDefault(false)
    }

    companion object {
        const val DEFAULT_CHECK_KEYWORD = "我的"
        const val FILE_SOURCE_TYPE = 3

        /** 校验根本没跑起来（书源记录丢失 / 定义无法解析）时的报告条目。 */
        fun failureResult(
            sourceId: String,
            sourceName: String?,
            keyword: String?,
            message: String,
        ): SourceCheckResult = SourceCheckResult(
            sourceId = sourceId,
            sourceName = sourceName,
            ok = false,
            keyword = keyword?.takeIf { it.isNotBlank() } ?: DEFAULT_CHECK_KEYWORD,
            steps = emptyList(),
            invalidGroups = emptyList(),
            respondTimeMs = 0L,
            error = message,
        )

        private const val DOMAIN_PROBE_TIMEOUT_MS = 1600
        private const val ERROR_COMMENT_PREFIX = "// Error: "
        private val GROUP_SPLIT_REGEX = Regex("[,;，；]")
        const val DOMAIN_INVALID = "域名失效"
        const val SEARCH_RULE_EMPTY = "搜索链接规则为空"
        const val SEARCH_INVALID = "搜索失效"
        const val DISCOVERY_RULE_EMPTY = "发现规则为空"
        const val DISCOVERY_INVALID = "发现失效"
        const val TIMEOUT_INVALID = "校验超时"
        const val JS_INVALID = "js失效"
        const val SITE_INVALID = "网站失效"
    }
}
