package io.legado.server

import com.jayway.jsonpath.JsonPath
import kotlinx.serialization.json.Json
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.mozilla.javascript.BaseFunction
import org.mozilla.javascript.ClassShutter
import org.mozilla.javascript.Context
import org.mozilla.javascript.Function
import org.mozilla.javascript.NativeArray
import org.mozilla.javascript.NativeJSON
import org.mozilla.javascript.NativeObject
import org.mozilla.javascript.ScriptRuntime
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import okhttp3.ConnectionSpec
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.URI
import java.nio.file.Path
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream
import java.util.zip.InflaterInputStream
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * 书源网络 TLS 主机名策略 —— 对齐 Android 实际两条路径：
 * - [ANDROID_OKHTTP]：主请求与 JS `java.ajax`/`connect`/`ajaxAll`/`ajaxTestAll`/jsLib 走 OkHttp，
 *   `unsafeTrustManager` + `unsafeHostnameVerifier` ⇒ 链信任与主机名校验都放行；
 * - [ANDROID_JSOUP]：JS `java.get`/`post`（Android `head` 同族）走 Jsoup + `unsafeSSLSocketFactory`
 *   ⇒ 只放行链信任，`HttpsURLConnection` 默认主机名校验保留。
 */
internal enum class SourceHostnamePolicy { ANDROID_OKHTTP, ANDROID_JSOUP }

/**
 * 仅供 [RuleRunner] 自身 client 使用的 scoped trust manager；不改默认 SSLContext、
 * 不设 JVM 全局属性、不影响其它网络组件。
 */
private fun sourceTrustManager(): X509TrustManager =
    object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

private fun sourceScopedSslContext(): SSLContext {
    val trustManager: TrustManager = sourceTrustManager()
    return SSLContext.getInstance("TLS").apply {
        init(null, arrayOf(trustManager), SecureRandom())
    }
}

private data class SourceCallTimeout(val timeout: Duration?)

private fun sourceHttpClient(policy: SourceHostnamePolicy): OkHttpClient {
    val trustManager = sourceTrustManager()
    val sslContext = sourceScopedSslContext()
    return OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .sslSocketFactory(sslContext.socketFactory, trustManager)
        .apply {
            if (policy == SourceHostnamePolicy.ANDROID_OKHTTP) {
                hostnameVerifier { _, _ -> true }
            }
        }
        .connectionSpecs(
            listOf(
                ConnectionSpec.MODERN_TLS,
                ConnectionSpec.COMPATIBLE_TLS,
                ConnectionSpec.CLEARTEXT,
            ),
        )
        // JVM 默认优先协商 HTTP/2；部分书源站点的 h2 TLS 握手会挂到
        // readTimeout，而强制 HTTP/1.1 时可立即返回。Android 通过 Cronet
        // 不暴露该差异，但 HTTP/1.1 对现有书源规则和响应体完全等价。
        .protocols(listOf(Protocol.HTTP_1_1))
        .followRedirects(false)
        .followSslRedirects(false)
        .build()
}

/**
 * 一本书在**规则执行期**的上下文 —— 即开源阅读里 JS 能看到的那个 `book` 对象。
 *
 * 为什么必须显式传：`sourceContext()` 原本只装书源信息（sourceId/jsLib），于是书源 JS 里
 * `book.name` / `book.author` / `book.bookUrl` / `book.getVariable('custom')` 全是**空值**。
 * 实测代价最大的一处就是听书音色：`🍅大灰狼聚合` 源用 `book.getVariable('custom')` 取音色编号，
 * 空值 ⇒ 永远只能用默认音色，而用户在书籍变量里填什么都没用。
 *
 * [variables] 刻意是**可变**的：规则里可能 `book.putVariable(...)`（Legado 里这会随
 * `saveBook` 落库），调用方在规则跑完后比对并写回。
 */
data class BookContext(
    val sourceId: String,
    /** Android `Book.bookUrl`：`reGetBook` 精确搜索命中后会就地替换。 */
    var bookUrl: String,
    val name: String? = null,
    val author: String? = null,
    /** Android `Book.tocUrl`：`refreshTocUrl`/`reGetBook` 重解析详情后就地更新。 */
    var tocUrl: String? = null,
    /** `novel` / `comic` / `audio` / `local`（[BookKind] 的 wire 值）。 */
    val kind: String? = null,
    /** 书籍变量表（Legado `Book.variableMap`）。 */
    val variables: MutableMap<String, String> = mutableMapOf(),
    /** Legado `Book.useReplaceRule`：全局替换净化开关（默认 true=应用全局规则）。JS `setUseReplaceRule` 在执行时写它。 */
    var useReplaceRule: Boolean = true,
) {
    /** Legado 的 `Book.type`：0=文本 1=音频 2=图像（书源里 `book.type` 会按它分派）。 */
    val numericType: Int
        get() = when (kind?.lowercase()) {
            "audio" -> 1
            "comic" -> 2
            else -> 0
        }
}

/** 目录解析中间态：去重/反转/formatJs 期间完整保留 Android 章节元数据。 */
private data class ChapterDraft(
    val title: String,
    /** Android `BookChapter.url`：用于 URL-only 去重和 formatJs 身份的原始值。 */
    val rawUrl: String,
    /** 服务端 API 的既有绝对 URL；Android 的绝对化延迟到 `BookChapter.getAbsoluteURL`。 */
    val url: String,
    val isVolume: Boolean,
    val isVip: Boolean,
    val isPay: Boolean,
    val tag: String?,
    val wordCount: String?,
    val updateTime: String?,
)

/**
 * 从库里装配一本书的规则执行上下文（含书籍变量）。
 *
 * 书架里没有这本书（例如从搜索页直接进详情）时**依然返回上下文**：书名/作者取不到，
 * 但变量表可以（`getBookVariables` 会返回空表），这样行为与 Legado 一致而不会抛错。
 */
internal fun Database.bookContext(sourceId: String, bookUrl: String): BookContext {
    val shelf = getShelfBookByUrl(bookUrl)?.takeIf { it.sourceId == sourceId }
    return BookContext(
        sourceId = sourceId,
        bookUrl = bookUrl,
        name = shelf?.name,
        author = shelf?.author,
        tocUrl = shelf?.tocUrl,
        kind = shelf?.bookKind,
        variables = getBookVariables(sourceId, bookUrl).toMutableMap(),
        useReplaceRule = getUseReplaceRule(sourceId, bookUrl),
    )
}

/** [Database.bookContext] 的 overlay 变体：搜索后未入架的书用请求字段补齐上下文，书架已有值优先保留。 */
internal fun Database.bookContext(sourceId: String, bookUrl: String, overlay: BookContext?): BookContext {
    val shelf = getShelfBookByUrl(bookUrl)?.takeIf { it.sourceId == sourceId }
    val variables = getBookVariables(sourceId, bookUrl).toMutableMap()
    overlay?.variables?.forEach { (key, value) -> if (!variables.containsKey(key)) variables[key] = value }
    return BookContext(
        sourceId = sourceId,
        bookUrl = bookUrl,
        name = overlay?.name?.takeIf { it.isNotBlank() } ?: shelf?.name,
        author = overlay?.author?.takeIf { it.isNotBlank() } ?: shelf?.author,
        tocUrl = overlay?.tocUrl?.takeIf { it.isNotBlank() } ?: shelf?.tocUrl,
        kind = overlay?.kind?.takeIf { it.isNotBlank() } ?: shelf?.bookKind,
        variables = variables,
    )
}

/** 书籍加载请求 → 未入架书的上下文 overlay（仅当请求携带身份字段时非空）。 */
internal fun BookRequest.toBookContextOverlay(): BookContext? {
    val hasOverlay = !tocUrl.isNullOrBlank() || !name.isNullOrBlank() || !author.isNullOrBlank() || !bookKind.isNullOrBlank() || variables.isNotEmpty()
    if (!hasOverlay) return null
    return BookContext(
        sourceId = sourceId,
        bookUrl = bookUrl,
        name = name,
        author = author,
        tocUrl = tocUrl,
        kind = bookKind,
        variables = variables.toMutableMap(),
    )
}

/** 正文请求 → 未入架书的上下文 overlay（仅当请求携带身份字段时非空）。 */
internal fun ContentRequest.toBookContextOverlay(bookUrl: String): BookContext? {
    val hasOverlay = !bookName.isNullOrBlank() || !bookAuthor.isNullOrBlank() || !bookKind.isNullOrBlank() || variables.isNotEmpty()
    if (!hasOverlay) return null
    return BookContext(
        sourceId = sourceId,
        bookUrl = bookUrl,
        name = bookName,
        author = bookAuthor,
        kind = bookKind,
        variables = variables.toMutableMap(),
    )
}

/**
 * 把规则执行期间对书籍变量的修改落库（Legado 里 `book.putVariable(...)` 会随 `saveBook` 落库）。
 *
 * **只在真的变了才写**：正文/目录每次都要跑规则，无脑写库会让高频路径多出无谓的写事务。
 */
internal fun Database.persistBookVariables(book: BookContext) {
    if (getBookVariables(book.sourceId, book.bookUrl) != book.variables) {
        saveBookVariables(book.sourceId, book.bookUrl, book.variables)
    }
}

private val androidOptionSeparator = Regex("\\s*,\\s*(?=\\{)")

/**
 * 解析搜索/详情响应需要暴露给前端的书籍类型。
 *
 * 已在书架上的记录优先复用数据库里的类型；未入架的书则按书自身 URL 载荷，
 * 最后回退到书源声明。这样搜索页直接开书与书架开书使用同一套判定语义。
 */
internal fun resolveBookKind(source: JsonObject, bookUrl: String, book: BookContext? = null): String? {
    val explicit = book?.kind?.trim()?.lowercase()?.takeIf { it == "novel" || it == "comic" || it == "audio" }
    return BookKind.resolveOrNull(explicit, bookUrl, source.toString())
}

/**
 * 书源的 `bookSourceType`（Legado `BookSourceType`：0 文本 / 1 音频 / 2 图片 / 3 文件 / 4 视频）。
 *
 * 只在**书源自己声明**时才有意义；未声明一律按 0（文本）处理，
 * 与 Android 实体默认值一致。
 */
/**
 * Android `NoStackTraceException("下载链接为空")`：文件型书源的 `ruleBookInfo.downloadUrls`
 * 取不到任何链接。属于「书源结论」而不是网络/脚本故障，因此校验时不再追加 `网站失效`。
 */
internal class DownloadUrlsEmptyException : RuntimeException("下载链接为空")

internal fun JsonObject.sourceType(): Int =
    (get("bookSourceType") as? JsonPrimitive)?.contentOrNull?.trim()?.toIntOrNull() ?: 0

/**
 * 图片字节解密器（Android `ImageUtils`）：`isCover = true` 用书源 `coverDecodeJs`，
 * 否则用 `ruleContent.imageDecode`。
 *
 * 规则为空 ⇒ 构造方返回 null，调用方**跳过整段解密**（Android `ImageUtils.skipDecode`）；
 * 规则非空但脚本失败 ⇒ [decode] 返回 null，调用方必须判失败（Android 同样是「解密失败返回 null」
 * 并让图片加载失败，绝不把加密字节当图片直出）。
 */
class ImageByteDecoder internal constructor(
    private val runner: RuleRunner,
    private val sourceJson: String,
    private val isCover: Boolean,
    private val book: BookContext? = null,
) {
    fun decode(src: String, bytes: ByteArray): ByteArray? =
        runner.decodeImageBytes(sourceJson, src, bytes, isCover, book)
}

/** 一次已完成的源响应：最终 URL、解码后的 body、状态码与响应头（登录检查/后续 Chromium 通道复用）。 */
data class FetchedResponse(
    val url: String,
    val body: String,
    val status: Int,
    val headers: Map<String, List<String>>,
    val raw: Any? = null,
)

data class SourceHttpResponse(
    val status: Int,
    val headers: Map<String, List<String>>,
    val bytes: ByteArray,
    val finalUrl: URI,
)

/**
 * A deliberately small, server-safe subset of Legado's declarative source protocol.
 * It keeps execution away from Android APIs and rejects private-network targets.
 */
class RuleRunner(
    internal var database: Database? = null,
    internal val browserRuntime: BrowserRuntime? = null,
    /**
     * 书源脚本的文件区（Android `appCtx.externalCache` 的等价物）。
     * null 表示未启用文件/压缩包能力，相关 `java.*` 函数会返回空值而不是抛错。
     */
    val sourceFileRoot: Path? = null,
) {
    internal val sourceFiles: SourceFileStore? = sourceFileRoot?.let(::SourceFileStore)
    private val client = sourceHttpClient(SourceHostnamePolicy.ANDROID_OKHTTP)
    private val jsoupClient = sourceHttpClient(SourceHostnamePolicy.ANDROID_JSOUP)
    private val json = Json { ignoreUnknownKeys = true }
    internal val jsSandbox = JsSandbox(this)
    private val responseLogin = SourceResponseLogin(jsSandbox)
    /** `jsLib` 原文 → 展开结果（Android `SharedJsScope.scopeMap` 的 LruCache 等价物）。 */
    private val expandedJsLibCache = ConcurrentHashMap<String, ResolvedJsLibrary>()
    /** `jsLib` JSON 里引用的 JS 文件下载缓存（Android `ACache` 的等价物）。 */
    private val jsLibFileCache = ConcurrentHashMap<String, CachedJsLibFile>()
private val SOURCE_GBK_RESPONSE_CHARSET = Charset.forName("x-mswin-936")

/** Android `EncodingDetect.getHtmlEncode` 只看 `<head>`；服务端为了省内存仍在窗口内扫描。 */
private val HTML_CHARSET_SCAN_BYTES = 256 * 1024

/** 服务端替代 icu4j `CharsetDetector` 的探测回退：非 UTF-8 一律按 GBK 处理。 */
private val GBK_RESPONSE_CHARSET = Charset.forName("x-mswin-936")

    private fun sourceId(source: JsonObject): String = source.string("bookSourceUrl") ?: throw RuleExecutionException("书源缺少 bookSourceUrl")
    private fun sourceBaseUrl(source: JsonObject): String = sourceId(source).substringBefore("##").substringBefore("#")

    fun search(
        sourceJson: String,
        keyword: String,
        page: Int = 1,
        callTimeoutMillis: Long? = null,
    ): List<SearchResult> {
        val source = sourceJson.objectValue()
        source.string("mainJs")?.takeIf { it.isNotBlank() }?.let { return JsSourceRunner(this, source).search(keyword) }
        // Android WebBook.searchBookAwait：searchUrl 为空或全空白都直接抛「搜索url不能为空」。
        val rawSearchUrl = source.string("searchUrl")?.takeIf { it.isNotBlank() }
            ?: throw RuleExecutionException("搜索url不能为空")
        val sourceKey = sourceId(source)
        val sourceUrl = sourceBaseUrl(source)
        // 网络请求使用去掉变体注解的站点地址，JS/登录态仍使用带变体的稳定 sourceId。
        val execContext = sourceContext(source, sourceKey)
        try {
            return jsSandbox.withSourceContext(execContext) {
                val searchUrl = if (rawSearchUrl.trimStart().startsWith("@js:") || rawSearchUrl.trimStart().startsWith("js:") || rawSearchUrl.contains("<js>")) {
                    val jsCode = if (rawSearchUrl.contains("<js>")) rawSearchUrl.substringAfter("<js>").substringBefore("</js>") else rawSearchUrl.removePrefix("@js:").removePrefix("js:")
                    jsSandbox.eval(jsCode, mapOf("key" to keyword, "keyword" to keyword, "page" to page, "baseUrl" to sourceUrl, "sourceId" to sourceKey), execContext)
                        ?: throw RuleExecutionException("searchUrl JS 计算未返回有效地址：${execContext.lastError ?: "脚本无返回值"}")
                } else {
                    rawSearchUrl
                }
                // Android `AnalyzeUrl.initUrl`：先求值内嵌 `{{...}}`/`<js>`，**再**拆 URL 选项
                // （`,{...}`）。反过来会把模板里 JS 自己的逗号当成分隔符 —— 虫虫书屋的
                // `java.post(url, body, {})` 因此被拦腰截断，报「URL 解析失败: …q={{JSON.parse…」。
                val evaluatedSearchUrl = renderTemplateExpressions(searchUrl, keyword, page, sourceUrl, execContext)
                val (searchUrlTemplate, searchOptions) = splitUrlOptions(evaluatedSearchUrl)
                val rendered = renderTemplatePlaceholders(
                    searchUrlTemplate,
                    keyword = keyword,
                    page = page,
                    baseUrl = sourceUrl,
                    keywordCharset = searchOptions?.charset ?: Charsets.UTF_8,
                ).absolute(sourceUrl)
                val response = fetchResponse(
                    rendered,
                    keyword = keyword,
                    page = page,
                    sourceId = sourceKey,
                    source = source,
                    options = searchOptions,
                    callTimeoutMillis = callTimeoutMillis,
                )
                val rule = source.objectValue("ruleSearch") ?: throw RuleExecutionException("该书源未配置 ruleSearch")
                // Android BookList.kt:62 —— 详情页直出型书源：搜索地址命中 bookUrlPattern 时，
                // 这一份响应就是详情页，直接按 ruleBookInfo 解析成单本，不再走列表规则。
                val bookUrlPattern = source.string("bookUrlPattern")?.trim()?.takeIf { it.isNotBlank() }
                if (matchesBookUrlPattern(bookUrlPattern, response.url)) {
                    return@withSourceContext listOfNotNull(
                        detailPageSearchResult(source, response.body, response.url, book = null),
                    )
                }
                // Android BookList.analyzeBookList：列表规则为空时 `getElements("")` 得到空集合，
                // 再走「列表为空按详情页解析」的兜底，而不是报错。
                val listRule = rule.string("bookList").orEmpty()
                val items = if (listRule.isBlank()) emptyList()
                else if (isJsRule(listRule)) jsListNodes(response.body, listRule, response.body, response.url)
                else nodes(response.body, listRule, response.url)
                // 相对链接一律按**真实响应**的最终 URL（重定向后）补全，而不是书源 ID。
                val responseBase = resolutionBase(source, response.url)
                // Android `BookList.analyzeBookList`：整份响应共用同一个 AnalyzeRule 变量表。
                val resultVariables = mutableMapOf<String, String>()
                val results = items.mapNotNull { item ->
                    searchItemFromNode(
                        source = source,
                        sourceKey = sourceKey,
                        rule = rule,
                        item = item,
                        body = response.body,
                        responseBase = responseBase,
                        // Android `if (searchBook.bookUrl.isEmpty()) baseUrl`：兜底用**原始响应地址**。
                        fallbackBookUrl = response.url,
                        variables = resultVariables,
                    )
                }
                // Android BookList.kt:100 —— 列表为空且**没有** bookUrlPattern 时同样按详情页解析：
                // 部分书源的搜索地址直接返回一本书的详情页（没有列表节点）。
                if (results.isEmpty() && bookUrlPattern == null) {
                    listOfNotNull(detailPageSearchResult(source, response.body, response.url, book = null))
                } else {
                    results
                }
            }
        } catch (error: Throwable) {
            throw error
        }
    }

    /**
     * Android `BookList.getInfoItem`：把「响应其实是详情页」的搜索结果解析成单本。
     *
     * 字段全部取自 `ruleBookInfo`（而不是 `ruleSearch`），与 Android 调用
     * `BookInfo.analyzeBookInfo` 后 `toSearchBook()` 的行为一致：
     * - 书名/作者/简介/分类/字数/最新章节/封面 来自详情规则；
     * - `bookUrl` 取真实响应地址（Android 在重定向场景用 `baseUrl`），相对链接也以它为基准；
     * - `tocUrl` 取详情规则的 `tocUrl`，为空时回退到 `bookUrl`（Android `BookInfo` 同样回退 `baseUrl`）；
     * - 书名为空视为没有结果（Android `if (book.name.isNotBlank())`）。
     */
    internal fun detailPageSearchResult(
        source: JsonObject,
        body: String,
        responseUrl: String,
        book: BookContext?,
    ): SearchResult? {
        val details = detailsFromBody(
            source = source,
            bookUrl = responseUrl,
            responseBase = responseUrl,
            body = body,
            book = book,
            canReName = true,
            nameFallback = "",
        )
        if (details.name.isBlank()) return null
        return SearchResult(
            sourceId = details.sourceId,
            name = details.name,
            author = details.author,
            bookUrl = responseUrl,
            coverUrl = details.coverUrl,
            intro = details.intro,
            kind = details.kind,
            wordCount = details.wordCount,
            lastChapter = details.lastChapter,
            tocUrl = details.tocUrl,
            bookKind = details.bookKind,
            variables = book?.variables?.toMap().orEmpty(),
        )
    }

    /**
     * Android `BookList.kt:62` 的判定：响应地址**整串**匹配 `bookUrlPattern` 时，
     * 该响应按详情页解析。`String.matches` 是整串匹配，`Regex.matches` 语义一致；
     * 规则非法时 Android 直接抛 `PatternSyntaxException`，这里同样不吞错。
     */
    internal fun matchesBookUrlPattern(bookUrlPattern: String?, responseUrl: String): Boolean {
        if (bookUrlPattern.isNullOrBlank()) return false
        return bookUrlPattern.toRegex().matches(responseUrl)
    }

    /**
     * Android `BookList.getSearchItem`：把一条列表节点映射成搜索结果。
     *
     * **搜索与发现共用这一条路径**（Android 两个入口都调 `getSearchItem`），字段处理必须一致：
     * - 书名/作者过 `BookHelp.formatBookName` / `formatBookAuthor`；书名格式化后为空 ⇒ 整条丢弃；
     * - 简介过 `HtmlFormatter.format`（不是详情页那套 `<usehtml>` 前缀透传）；
     * - 字数过 `wordCountFormat`；分类是 `getStringList` 的逗号拼接结果；
     * - 书链：非空结果按 [responseBase] 补全，取不到时回退 [fallbackBookUrl]。
     *
     * @param body 该页原始响应体（规则求值的 content 上下文）
     * @param responseBase 相对链接与 JS `baseUrl` 的基准（`data:` 载荷退回书源地址）
     * @param fallbackBookUrl 规则取不到书链时的兜底地址（Android `if (isEmpty) baseUrl`）
     */
    private fun searchItemFromNode(
        source: JsonObject,
        sourceKey: String,
        rule: JsonObject,
        item: NodeValue,
        body: String,
        responseBase: String,
        fallbackBookUrl: String,
        /**
         * 该响应内所有条目/字段共享的变量表（Android `BookList.analyzeBookList` 里
         * 同一个 AnalyzeRule 实例贯穿所有行与字段，`@put` 写进去的值后面都能 `@get`）。
         */
        variables: MutableMap<String, String> = mutableMapOf(),
    ): SearchResult? {
        // 单字段失败只丢该字段：JS 中断/取消必须继续向上抛，其余异常吞掉（Android 同语义）。
        fun optionalField(extract: () -> String?): String? = try {
            extract()
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            if (Thread.currentThread().isInterrupted) {
                Thread.currentThread().interrupt()
                throw InterruptedException()
            }
            null
        }
        val extractedBookUrl = item.value(
            rule.string("bookUrl"),
            jsSandbox,
            body,
            responseBase,
            variables,
            urlExtractionMode = NodeValue.UrlExtractionMode.FIRST_HTML,
        )?.absolute(responseBase)
        val url = extractedBookUrl?.takeIf { it.isNotBlank() } ?: fallbackBookUrl
        val name = formatBookName(item.value(rule.string("name"), jsSandbox, body, responseBase, variables))
        if (name.isEmpty()) return null
        return SearchResult(
            sourceId = sourceKey,
            name = name,
            author = formatBookAuthor(item.value(rule.string("author"), jsSandbox, body, responseBase, variables))
                .takeIf { it.isNotBlank() },
            bookUrl = url,
            coverUrl = optionalField {
                item.value(rule.string("coverUrl"), jsSandbox, body, responseBase, variables)?.absolute(responseBase)
            },
            intro = optionalField {
                formatSearchIntro(item.value(rule.string("intro"), jsSandbox, body, responseBase, variables))
            },
            // Android `searchBook.kind = getStringList(ruleKind)?.joinToString(",")`。
            kind = optionalField {
                item.valueList(rule.string("kind"), jsSandbox, body, responseBase, variables)?.joinToString(",")
            },
            wordCount = optionalField {
                formatWordCount(item.value(rule.string("wordCount"), jsSandbox, body, responseBase, variables))
            },
            lastChapter = optionalField {
                item.value(rule.string("lastChapter"), jsSandbox, body, responseBase, variables)
            },
            // 服务端附加字段（Android `SearchBook.tocUrl` 由详情页回填，聚合源需要搜索结果直接带上）。
            tocUrl = item.value(
                rule.string("tocUrl"),
                jsSandbox,
                body,
                responseBase,
                variables,
                urlExtractionMode = NodeValue.UrlExtractionMode.FIRST_HTML,
            )?.absolute(responseBase),
            bookKind = resolveBookKind(source, url),
            // Android `SearchBook.variable`：同一响应内 `@put` 的变量随结果带出，
            // `reGetBook` 精确搜索后据此回填书籍变量。
            variables = variables.toMap(),
        )
    }

    /**
     * 解析书源的发现分类树结构。
     *
     * 支持三种生态形式：
     * 1. 包含 <js> 或 @js: 的沙箱脚本求值；
     * 2. JSON 数组/树形结构；
     * 3. 经典多行纯文本（以 :: 或 && 分隔标题与 URL，支持层级缩进或平铺）。
     */
    fun exploreCategories(sourceJson: String): List<ExploreCategory> {
        val source = sourceJson.objectValue()
        val rawExploreUrl = source.string("exploreUrl")?.trim() ?: return emptyList()
        if (rawExploreUrl.isBlank()) return emptyList()
        val sourceUrl = source.string("bookSourceUrl") ?: ""
        val execContext = sourceContext(source, sourceUrl)

        val evaluated = jsSandbox.withSourceContext(execContext) {
            if (rawExploreUrl.trimStart().startsWith("@js:") || rawExploreUrl.trimStart().startsWith("js:") || rawExploreUrl.contains("<js>")) {
                val jsCode = if (rawExploreUrl.contains("<js>")) {
                    rawExploreUrl.substringAfter("<js>").substringBefore("</js>")
                } else {
                    rawExploreUrl.trimStart().removePrefix("@js:").removePrefix("js:")
                }
                jsSandbox.eval(jsCode, mapOf("baseUrl" to sourceUrl, "sourceId" to sourceUrl), execContext) ?: ""
            } else {
                rawExploreUrl
            }
        }.trim()

        if (evaluated.isBlank()) return emptyList()
        return parseExploreCategoriesText(evaluated, sourceUrl)
    }

    private fun parseExploreCategoriesText(text: String, baseUrl: String): List<ExploreCategory> {
        val trimmed = text.trim()
        if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
            val jsonCategories = runCatching {
                val element = json.parseToJsonElement(trimmed)
                if (element is JsonArray) {
                    parseJsonCategories(element, baseUrl)
                } else null
            }.getOrNull()
            if (!jsonCategories.isNullOrEmpty()) {
                return jsonCategories
            }
        }
        return parseLineBasedCategories(text, baseUrl)
    }

    private fun parseJsonCategories(array: JsonArray, baseUrl: String): List<ExploreCategory> {
        return array.mapNotNull { elem ->
            if (elem !is JsonObject) return@mapNotNull null
            val title = elem.string("title") ?: elem.string("name") ?: return@mapNotNull null
            val urlElem = elem["url"]
            if (urlElem is JsonArray) {
                val sub = parseJsonCategories(urlElem, baseUrl)
                ExploreCategory(title = title, url = null, subCategories = sub)
            } else {
                val rawUrl = (urlElem as? JsonPrimitive)?.contentOrNull
                val subArray = (elem["subCategories"] ?: elem["children"] ?: elem["list"] ?: elem["items"]) as? JsonArray
                val sub = if (subArray != null) parseJsonCategories(subArray, baseUrl) else emptyList()
                ExploreCategory(
                    title = title,
                    url = rawUrl?.takeIf { it.isNotBlank() },
                    subCategories = sub,
                )
            }
        }
    }

    private fun parseLineBasedCategories(text: String, baseUrl: String): List<ExploreCategory> {
        val lines = text.lines()
        val result = mutableListOf<ExploreCategory>()
        var currentGroup: String? = null
        val currentGroupItems = mutableListOf<ExploreCategory>()

        fun flushGroup() {
            if (currentGroup != null) {
                if (currentGroupItems.isNotEmpty()) {
                    result.add(ExploreCategory(title = currentGroup!!, url = null, subCategories = currentGroupItems.toList()))
                    currentGroupItems.clear()
                } else {
                    result.add(ExploreCategory(title = currentGroup!!, url = null))
                }
                currentGroup = null
            }
        }

        for (line in lines) {
            val trimmedLine = line.trim()
            if (trimmedLine.isBlank()) continue

            val separator = when {
                line.contains("::") -> "::"
                line.contains("&&") -> "&&"
                else -> null
            }

            if (separator != null) {
                val parts = line.split(separator)
                val title = parts[0].trim()
                val url = if (parts.size > 1) {
                    val rawUrlPart = parts[1].trim()
                    rawUrlPart.takeIf { it.isNotBlank() }
                } else null

                val hasIndent = line.startsWith(" ") || line.startsWith("\t") || line.startsWith("　")
                val item = ExploreCategory(title = title, url = url)

                if (hasIndent && currentGroup != null) {
                    currentGroupItems.add(item)
                } else if (currentGroup != null) {
                    currentGroupItems.add(item)
                } else {
                    result.add(item)
                }
            } else {
                flushGroup()
                currentGroup = trimmedLine
            }
        }
        flushGroup()
        return result
    }

    /**
     * 根据分类 URL 获取发现书籍列表。
     *
     * 遵循 Legado 生态规范：优先使用 ruleExplore，若为空自动回退至 ruleSearch。
     */
    fun exploreBooks(sourceJson: String, exploreUrl: String, page: Int = 1): List<SearchResult> {
        val source = sourceJson.objectValue()
        val sourceKey = sourceId(source)
        val sourceUrl = sourceBaseUrl(source)
        val execContext = sourceContext(source, sourceKey)

        return jsSandbox.withSourceContext(execContext) {
            val evaluatedUrl = if (exploreUrl.trimStart().startsWith("@js:") || exploreUrl.trimStart().startsWith("js:") || exploreUrl.contains("<js>")) {
                val jsCode = if (exploreUrl.contains("<js>")) {
                    exploreUrl.substringAfter("<js>").substringBefore("</js>")
                } else {
                    exploreUrl.trimStart().removePrefix("@js:").removePrefix("js:")
                }
                jsSandbox.eval(jsCode, mapOf("page" to page, "baseUrl" to sourceUrl, "sourceId" to sourceKey), execContext)
                    ?: throw RuleExecutionException("exploreUrl JS 计算未返回有效地址：${execContext.lastError ?: "脚本无返回值"}")
            } else {
                exploreUrl
            }

            // Android `AnalyzeUrl.replaceKeyPageJs`：发现地址与搜索/目录/正文一样，先按 JS
            // 求值所有 `{{...}}`（绑定 page/baseUrl/source…），再做 `<1,2,3>` 页数候选替换。
            // 旧实现只认 `{{page}}/{{page+1}}/{{page-1}}` 三个字面量，像
            // `index{{page - 1 == 0 ? '': '_'+page}}.html`（八叉书库）会整条残留下来，
            // 请求前直接报「URL 格式无效或包含未解析变量」。
            val renderedUrl = renderTemplate(
                evaluatedUrl,
                keyword = null,
                page = page,
                baseUrl = sourceUrl,
                execContext = execContext,
                encodeKeyword = false,
            )

            val (urlTemplate, options) = splitUrlOptions(renderedUrl)
            val mergedOptions = mergeOptions(parseSourceHeaders(source, sourceUrl), options)
            val rendered = urlTemplate.absolute(sourceUrl)
            // Android `BookList.analyzeBookList(baseUrl = res.url, ...)`：相对链接一律按**响应**
            // 的最终地址补全，重定向过的发现页才能取到正确的书链。
            val response = fetchResponse(rendered, sourceId = sourceKey, source = source, options = mergedOptions)
            val body = response.body

            val ruleExplore = source.objectValue("ruleExplore")
            val ruleSearch = source.objectValue("ruleSearch")
            // Android `BookList.analyzeBookList` 的规则选择：
            // ruleExplore.bookList 非空 → ruleExplore；否则一律落回 ruleSearch（即使它也为空）。
            val rule = ruleExplore?.takeIf { !it.string("bookList").isNullOrBlank() }
                ?: ruleSearch
                ?: JsonObject(emptyMap())
            val bookUrlPattern = source.string("bookUrlPattern")?.trim()?.takeIf { it.isNotBlank() }
            val listRule = rule.string("bookList").orEmpty()
            val responseBase = resolutionBase(source, response.url)
            val items = if (listRule.isBlank()) emptyList()
            else if (isJsRule(listRule)) jsListNodes(NodeValue.document(body), listRule, body, responseBase)
            else nodes(body, listRule)
            val resultVariables = mutableMapOf<String, String>()
            val results = items.mapNotNull { item ->
                searchItemFromNode(
                    source = source,
                    sourceKey = sourceKey,
                    rule = rule,
                    item = item,
                    body = body,
                    responseBase = responseBase,
                    // Android `BookList.getSearchItem`：书链为空时兜底用响应地址。
                    fallbackBookUrl = response.url,
                    variables = resultVariables,
                )
            }
            // Android 对搜索与发现一视同仁：列表为空且没有 bookUrlPattern 时按详情页解析单本。
            if (results.isEmpty() && bookUrlPattern == null) {
                listOfNotNull(detailPageSearchResult(source, body, response.url, book = null))
            } else {
                results
            }
        }
    }

    /**
     * 构造当前书源的 JS 执行上下文。与 Android getShareScope 一致，共享脚本库只来自
     * 书源 `jsLib`；`loginUrl` 是登录专用脚本，只在显式登录 UI/action 路径注入。
     */
    private fun sourceContext(source: JsonObject, sourceUrl: String?, book: BookContext? = null): JsExecutionContext {
        val library = source.string("jsLib")?.takeIf { it.isNotBlank() }?.let(::resolveJsLibrary)
        // 书籍上下文一并注入：书源 JS 里的 `book.getVariable('custom')`（听书音色）就靠它。
        // 传 null 时保持原行为（各字段为空串），搜索等"还没有具体书"的场景走这条。
        return JsExecutionContext(
            sourceId = sourceUrl,
            // Android `java.getTag()` / `source.bookSourceName` 都取书源名；桥接层文件族还要用整份书源取 header。
            sourceName = source.string("bookSourceName"),
            sourceComment = source.string("bookSourceComment"),
            sourceJson = source,
            database = database,
            jsLib = library?.text,
            jsLibError = library?.error,
            bookUrl = book?.bookUrl,
            bookName = book?.name,
            bookAuthor = book?.author,
            bookTocUrl = book?.tocUrl,
            bookType = book?.numericType,
            bookKind = book?.kind,
            bookVariables = book?.variables ?: mutableMapOf(),
            useReplaceRule = book?.useReplaceRule ?: true,
        )
    }

    /** jsLib 展开结果：要么是可执行脚本文本，要么是失败原因（不会两者都为空）。 */
    private data class ResolvedJsLibrary(val text: String?, val error: String? = null)

    private class CachedJsLibFile(val text: String?, val expiresAt: Long)

    /**
     * 展开书源 `jsLib`。
     *
     * Android `SharedJsScope.getScope`：`jsLib` 是 JSON 对象时，**按值逐个下载**
     * 绝对地址里的 JS 文件并在同一作用域内求值（例：`{"utils":"https://host/utils.js"}`，
     * 规则里就能直接调用 utils.js 定义的函数）；非 URL 的值直接忽略。
     * 下载失败时 Android 抛 `下载jsLib-URL失败`，这里同样把整段 jsLib 判失败。
     *
     * 展开结果与文件内容都做进程内缓存：Android 用 `LruCache`（作用域）+ `ACache`（文件），
     * 否则每条规则都要重新下载一次工具库。
     */
    private fun resolveJsLibrary(jsLib: String): ResolvedJsLibrary {
        expandedJsLibCache[jsLib]?.let { return it }
        val trimmed = jsLib.trim()
        val parsed = if (trimmed.startsWith("{")) {
            runCatching { Json.parseToJsonElement(trimmed).jsonObject }.getOrNull()
        } else {
            null
        }
        // 非 JSON 对象：Android 直接把整段 jsLib 当脚本求值（含空对象 `{}` 之外的一切写法）。
        if (parsed == null) return ResolvedJsLibrary(jsLib).also { expandedJsLibCache[jsLib] = it }

        val parts = mutableListOf<String>()
        for ((_, value) in parsed) {
            val url = (value as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim().orEmpty()
            // Android `value.isAbsUrl()`：只下载绝对地址，其他值忽略。
            if (!url.startsWith("http://", true) && !url.startsWith("https://", true)) continue
            val text = downloadJsLibFile(url)
                ?: return ResolvedJsLibrary(null, "下载jsLib-${url}失败").also {
                    expandedJsLibCache[jsLib] = it
                }
            parts += text
        }
        return ResolvedJsLibrary(parts.joinToString("\n")).also { expandedJsLibCache[jsLib] = it }
    }

    /** 下载 jsLib 里引用的 JS 文件（Android `okHttpClient.newCallStrResponse`），带 TTL 缓存。 */
    private fun downloadJsLibFile(url: String): String? {
        val now = System.currentTimeMillis()
        jsLibFileCache[url]?.let { cached -> if (cached.expiresAt > now) return cached.text }
        val text = runCatching {
            val uri = parseUri(url)
            val response = sendOnce(buildRequest(uri, "GET", emptyMap(), null, UrlOptions()))
            if (response.status !in 200..299) return@runCatching null
            val contentType = response.headers.entries
                .firstOrNull { it.key.equals("content-type", true) }?.value?.joinToString(", ").orEmpty()
            val contentEncoding = response.headers.entries
                .firstOrNull { it.key.equals("content-encoding", true) }?.value?.joinToString(", ").orEmpty()
            val bytes = decompressBody(response.bytes, contentEncoding)
            bytes.toString(sourceResponseCharset(resolveCharset(bytes, contentType)))
        }.getOrNull()
        val ttl = if (text == null) JS_LIB_FAILURE_TTL_MS else JS_LIB_CACHE_TTL_MS
        if (jsLibFileCache.size > JS_LIB_CACHE_MAX_ENTRIES) jsLibFileCache.clear()
        jsLibFileCache[url] = CachedJsLibFile(text, now + ttl)
        return text
    }

    /** Android BaseSource.getLoginJs：对原始非空文本做精确前缀剥离；不做网址/JS 形态猜测。 */
    private fun getLoginJs(source: JsonObject): String? {
        val loginUrl = source.string("loginUrl")?.takeIf { it.isNotBlank() } ?: return null
        return when {
            loginUrl.startsWith("@js:") -> loginUrl.substring(4)
            loginUrl.startsWith("<js>") -> loginUrl.substring(4, loginUrl.lastIndexOf('<'))
            else -> loginUrl
        }
    }

    fun details(
        sourceJson: String,
        bookUrl: String,
        book: BookContext? = null,
        canReName: Boolean = true,
    ): BookDetails {
        val source = sourceJson.objectValue()
        source.string("mainJs")?.takeIf { it.isNotBlank() }?.let { return JsSourceRunner(this, source).details(bookUrl, book) }
        val sourceKey = sourceId(source)
        val sourceUrl = sourceBaseUrl(source)
        return jsSandbox.withSourceContext(sourceContext(source, sourceKey, book)) {
            declarativeDetails(source, bookUrl, book, canReName)
        }
    }

    /**
     * Android `AnalyzeRule.reGetBook()` / `refreshTocUrl()` 的落地实现：在同一个书源上下文里
     * 重新解析详情页，把新的 `tocUrl` 交回目录解析继续使用（`preUpdateJs` 本身不动地址）。
     *
     * - `reGetBook`：先按 `WebBook.preciseSearchAwait` 精确搜索（书名 + 作者全等）换书链，
     *   并把命中结果的变量并回书籍变量，再解析详情；
     * - `refreshTocUrl`：直接用当前书链重解析详情（`getBookInfoAwait(..., canReName = false)`）；
     * - 搜不到书 / 详情规则失败按 Android 语义中断本次刷新；没有书籍上下文时等同 Android 的
     *   `book == null` 分支，静默返回原地址。
     */
    private fun resolvePreUpdateTocUrl(
        sourceJson: String,
        book: BookContext?,
        currentTocUrl: String,
        reGetBook: Boolean,
    ): String {
        val context = book ?: return currentTocUrl
        if (reGetBook) {
            val name = context.name.orEmpty()
            val author = context.author.orEmpty()
            val match = search(sourceJson, name)
                .firstOrNull { it.name == name && it.author.orEmpty() == author }
                ?: throw RuleExecutionException("未搜索到 $name($author) 书籍")
            context.bookUrl = match.bookUrl
            match.variables.forEach { (key, value) -> context.variables[key] = value }
        }
        val details = details(sourceJson, context.bookUrl.ifBlank { currentTocUrl }, context, canReName = false)
        val toc = details.tocUrl.takeIf { it.isNotBlank() } ?: currentTocUrl
        context.tocUrl = toc
        return toc
    }

    /**
     * 解析相对链接、以及交给规则的 `baseUrl` 时该用的**基准地址**。
     *
     * Android 用真实响应的最终 URL（重定向后）。`data:` 载荷是聚合源的服务端扩展：
     * 它本身是**参数载体**、不是可请求的地址，没有"最终 URL" ⇒ 退回书源地址
     * （等价于 Android `AnalyzeRule.setBaseUrl(书源地址)`）。否则载荷里的相对链接
     * 会原样留在结果里，下游（详情/目录/正文请求）必然失败。
     */
    private fun resolutionBase(source: JsonObject, responseUrl: String): String =
        if (responseUrl.startsWith("data:", ignoreCase = true)) sourceBaseUrl(source) else responseUrl

    /**
     * 解析 `data:;base64,<载荷>,<类型标记>` 形式的数据地址，返回解码后的载荷；非数据地址返回 null。
     *
     * 聚合类书源用它把 book_id/来源/分栏等参数从搜索结果一路带到详情、目录和正文。
     */
    private fun dataUrlPayload(url: String): String? {
        val value = url.trim()
        if (!value.startsWith("data:", ignoreCase = true)) return null
        val comma = value.indexOf(',')
        if (comma < 0) return null
        val meta = value.substring(5, comma)
        var payload = value.substring(comma + 1)
        // 末尾可能跟一个类型标记（如 ,{"type":"qingtian2"}），取最后一个逗号之前的部分
        val typeIndex = payload.lastIndexOf(',')
        if (typeIndex > 0 && payload.substring(typeIndex + 1).trimStart().startsWith("{")) {
            payload = payload.substring(0, typeIndex)
        }
        return if (meta.contains("base64", ignoreCase = true)) {
            runCatching { String(java.util.Base64.getDecoder().decode(payload.trim()), Charsets.UTF_8) }
                .getOrElse { payload }
        } else {
            runCatching { java.net.URLDecoder.decode(payload, Charsets.UTF_8) }.getOrDefault(payload)
        }
    }

    /**
     * Android `AnalyzeRule.getElement(initRule)` 的分段语义。
     *
     * init 形如 `<js>…</js>$.data` 时 `getElement` 逐段求值，末段的 JSON 路径走
     * `AnalyzeByJSonPath.getObject`：取到的是**原始值**（对象/数组保持结构化），
     * `setContent` 后后续规则的 `result` 就是那个对象，因此源里可以直接写
     * `result.book_id` / `result.source`。🍅大灰狼聚合的目录链接规则正是这样取参：
     * 若 `result` 退化成 JSON 文本，`book_id` 变 undefined、`JSON.stringify` 直接丢掉字段，
     * 生成的 `data:` 目录地址缺参数，目录必然为空（服务端「搜索目录失效」，而书源本身可用）。
     *
     * 纯 JS 的 init 走 `evalRawJsRule`：脚本返回对象/数组时同样**不字符串化**
     * （Android `getElement` 的 `Mode.Js` 分支返回什么就是什么）；只有末段是 HTML/XPath/正则
     * 或带 `##正则` 的 init 才回到整条规则的文本求值。
     */
    private fun initRuleRoot(
        initRule: String,
        baseDoc: NodeValue,
        jsSandbox: JsSandbox?,
        body: String,
        bookUrl: String,
        variables: MutableMap<String, String>,
    ): NodeValue? {
        val jsEnd = initRule.lastIndexOf("</js>")
        val initTail = if (jsEnd < 0) "" else initRule.substring(jsEnd + "</js>".length).trim()
        if (initTail.isBlank() && baseDoc.isRawJsRule(initRule)) {
            // Android `setContent(getElement(init))`：纯 JS 的 init 直接吃脚本返回值，
            // 对象/数组**不字符串化**（`JSON.parse(result)` 的 init 正是这种写法）。
            // 脚本无返回值/求值失败时沿用原有宽松回退（初始内容原样），不再重复求值脚本。
            val raw = runCatching { baseDoc.evalRawJsRule(initRule, jsSandbox, body, bookUrl, variables) }
                .getOrNull()
            return raw?.let { NodeValue.document(it) } ?: baseDoc
        }
        if (jsEnd < 0) {
            // 兜底：`@js:` / `js:` 之类前缀形式但带尾处理段，仍按文本链求值。
            return runCatching { baseDoc.value(initRule, jsSandbox, body, bookUrl, unescape = false) }
                .getOrNull()?.takeIf { it.isNotBlank() }?.let { NodeValue.document(it) }
        }
        val jsSegment = initRule.substring(0, jsEnd + "</js>".length)
        val tail = initTail
        val jsText = runCatching { baseDoc.value(jsSegment, jsSandbox, body, bookUrl, unescape = false) }
            .getOrNull()?.takeIf { it.isNotBlank() } ?: return null
        if (!tail.startsWith("$")) {
            return if (tail.isBlank()) {
                NodeValue.document(jsText)
            } else {
                runCatching { baseDoc.value(initRule, jsSandbox, body, bookUrl, unescape = false) }
                    .getOrNull()?.takeIf { it.isNotBlank() }?.let { NodeValue.document(it) }
            }
        }
        // JSON 路径段的原始值：字符串保持字符串（等同 setContent(String)），
        // 对象/数组保持结构（等同 setContent(Map/List)），后续 JS 规则才能按键取值。
        val raw = runCatching {
            NodeValue.json(NodeValue.document(jsText).rawNodeValue())
                .selectRawNodes(
                    rule = tail,
                    forElement = true,
                    jsSandbox = jsSandbox,
                    rawBody = jsText,
                    baseUrl = bookUrl,
                    variables = variables,
                ).singleValue
        }.getOrNull()
        return if (raw != null) NodeValue.document(raw) else NodeValue.document(jsText)
    }

    private fun declarativeDetails(
        source: JsonObject,
        bookUrl: String,
        book: BookContext? = null,
        canReName: Boolean = true,
    ): BookDetails {
        val sourceKey = sourceId(source)
        // 聚合源把 bookUrl 当作参数载体（data:;base64,<载荷>,{"type":"qingtian"}），
        // 这类地址无法直接 HTTP 请求，需要先取出解码后的载荷交给规则。
        val dataPayload = dataUrlPayload(bookUrl)
        if (dataPayload != null) {
            return detailsFromBody(source, bookUrl, bookUrl, dataPayload, book, canReName)
        }
        val response = fetchResponse(bookUrl, sourceId = sourceKey, source = source, book = book)
        return detailsFromBody(source, bookUrl, response.url, response.body, book, canReName)
    }

    /**
     * 用「已经拿到的响应体」解析详情。
     *
     * 抽出来是因为搜索的详情页直出分支（Android `BookList.getInfoItem`）拿到的就是搜索响应本身，
     * 不能为了解析详情再请求一次；两条路径必须共用同一份字段语义。
     *
     * @param responseBase 相对链接基准：真实响应的最终 URL（重定向后）；data: 载荷没有网络响应，退回 bookUrl。
     * @param nameFallback 书名缺失时的占位；搜索的详情页直出分支要求「书名为空即无结果」，
     *   因此传空串（Android `BookList.getInfoItem` 用 `book.name.isNotBlank()` 判定）。
     */
    private fun detailsFromBody(
        source: JsonObject,
        bookUrl: String,
        responseBase: String,
        body: String,
        book: BookContext?,
        canReName: Boolean,
        nameFallback: String = "未命名书籍",
    ): BookDetails {
        val sourceKey = sourceId(source)
        val rule = source.objectValue("ruleBookInfo") ?: throw RuleExecutionException("该书源未配置 ruleBookInfo")
        val initRule = rule.string("init")
        // **必须**用 document(String)：它按首字符自动识别 JSON/HTML；
        // `NodeValue.json(String)` 会把字符串当作已解析值，JSONPath 规则一律取不到值
        // （聚合源的 data: 载荷因此整条正文/目录/详情链失效）。
        val baseDoc = NodeValue.document(body)
        // 相对链接与 JS `baseUrl` 的基准：真实响应的最终 URL；`data:` 载荷退回书源地址。
        val linkBase = resolutionBase(source, responseBase)
        // init 常写成「JS + 后置取值路径」的规则链（如 <js>…</js>$.data）：必须求值，不能当路径用。
        // 纯路径（如 $.data）仍走原有 at() 语义，避免把 JSON 对象退化成字符串。
        // Android `AnalyzeRule` 的变量表挂在 Book/Chapter/RuleData 上：`@put` 写在详情步骤里的
        // 变量（如 `author@put:{id:$.book_id}`）既是同一份详情各字段共享的，也要落进 Book 变量，
        // 后续目录/正文步骤才能用 `@get:{id}` 读到。这里直接用书籍变量表本身当求值变量表。
        val sharedVariables = book?.variables ?: mutableMapOf()
        val root = when {
            initRule.isNullOrBlank() -> baseDoc
            initRule.contains("<js>") || initRule.trimStart().startsWith("@js:") || initRule.trimStart().startsWith("js:") ->
                initRuleRoot(initRule, baseDoc, jsSandbox, body, bookUrl, sharedVariables) ?: baseDoc
            initRule.contains("@put:", ignoreCase = true) -> baseDoc.also {
                sharedVariables.putAll(baseDoc.fieldVariables(initRule, jsSandbox, body, linkBase))
            }
            else -> baseDoc.at(initRule)
        }
        fun optionalValue(key: String): String? =
            runCatching { root.value(rule.string(key), jsSandbox, body, linkBase, sharedVariables) }.getOrNull()
        fun criticalValue(key: String): String? = root.value(rule.string(key), jsSandbox, body, linkBase, sharedVariables)
        // Android BookInfo：书名/作者走 BookHelp 的格式化，简介走 HtmlFormatter（或前缀透传）。
        val extractedName = formatBookName(criticalValue("name"))
        val extractedAuthor = formatBookAuthor(criticalValue("author")).takeIf { it.isNotBlank() }
        val contextName = book?.name?.trim().orEmpty()
        val contextAuthor = book?.author?.trim().orEmpty()
        val allowRename = canReName && !rule.string("canReName").isNullOrBlank()
        val name = when {
            extractedName.isNotBlank() && (contextName.isBlank() || allowRename) -> extractedName
            contextName.isNotBlank() -> contextName
            else -> extractedName
        }
        val author = when {
            extractedAuthor != null && (contextAuthor.isBlank() || allowRename) -> extractedAuthor
            contextAuthor.isNotBlank() -> contextAuthor
            else -> extractedAuthor
        }
        // Android `Book.isWebFile`（bookSourceType = file）：详情只取下载链接，
        // 没有目录链接；取不到链接时整条详情失败（BookInfo 抛「下载链接为空」）。
        val isWebFile = source.sourceType() == WEB_FILE_SOURCE_TYPE
        val downloadUrls = if (isWebFile) {
            root.valueList(rule.string("downloadUrls"), jsSandbox, body, linkBase, sharedVariables)
                .orEmpty()
                .map { it.absolute(linkBase).trim() }
                .filter { it.isNotEmpty() }
                .distinct()
                .also { if (it.isEmpty()) throw DownloadUrlsEmptyException() }
        } else {
            emptyList()
        }
        val bookKind = resolveBookKind(source, bookUrl, book)
        // Android `ReadBook.upWebBook`：`ruleContent.imageStyle` 优先；
        // 没声明且是图片书（漫画）时默认 `FULL`（整页）。
        val imageStyle = source.objectValue("ruleContent")?.string("imageStyle")?.trim()?.takeIf { it.isNotBlank() }
            ?: IMAGE_BOOK_DEFAULT_IMAGE_STYLE.takeIf { bookKind == "comic" }
        return BookDetails(
            sourceId = sourceKey,
            name = name.ifBlank { nameFallback },
            author = author, intro = formatBookIntro(optionalValue("intro")),
                kind = optionalValue("kind"),
                wordCount = optionalValue("wordCount"),
                lastChapter = optionalValue("lastChapter"),
            coverUrl = optionalValue("coverUrl")?.absolute(linkBase),
            tocUrl = if (isWebFile) "" else criticalValue("tocUrl")?.absolute(linkBase) ?: bookUrl,
            downloadUrls = downloadUrls,
            bookKind = bookKind,
            imageStyle = imageStyle,
        )
    }

    fun chapters(
        sourceJson: String,
        tocUrl: String,
        book: BookContext? = null,
        cancellationCheck: (() -> Unit)? = null,
        runPreUpdateJs: Boolean = false,
        /**
         * Android `getChapterListAwait(isFromBookInfo=...)`：详情页规则刚解析完就顺势取目录时，
         * `preUpdateJs` 里的 `refreshTocUrl()` 只记日志跳过重解析，`reGetBook()` 也只记日志。
         */
        fromBookInfo: Boolean = false,
    ): List<Chapter> {
        val source = sourceJson.objectValue()
        source.string("mainJs")?.takeIf { it.isNotBlank() }?.let { return JsSourceRunner(this, source).chapters(tocUrl, book) }
        val sourceKey = sourceId(source)
        val execContext = sourceContext(source, sourceKey, book)
        return jsSandbox.withSourceContext(execContext) {
            val rule = source.objectValue("ruleToc") ?: throw RuleExecutionException("该书源未配置 ruleToc")
            // Android WebBook.runPreUpdateJs：刷新目录前先执行 ruleToc.preUpdateJs，
            // 脚本失败会中断本次刷新（Android 记日志后仍把失败往上抛），因此这里同样抛错。
            var effectiveTocUrl = tocUrl
            if (runPreUpdateJs) {
                rule.string("preUpdateJs")?.takeIf { it.isNotBlank() }?.let { preUpdateScript ->
                    execContext.fromBookInfo = fromBookInfo
                    execContext.inPreUpdateJs = true
                    try {
                        jsSandbox.eval(preUpdateScript, execContext = execContext)
                    } finally {
                        execContext.inPreUpdateJs = false
                    }
                    execContext.lastError?.let { message ->
                        throw RuleExecutionException("执行 preUpdateJs 失败: $message")
                    }
                    // Android `AnalyzeRule.reGetBook()` / `refreshTocUrl()` 本身不动地址，只置标记：
                    // 真正的「换书链 + 重解析详情」在这里（同一个书源上下文内）完成。
                    if (execContext.reGetBookRequested || execContext.refreshTocRequested) {
                        effectiveTocUrl = resolvePreUpdateTocUrl(
                            sourceJson = sourceJson,
                            book = book,
                            currentTocUrl = effectiveTocUrl,
                            reGetBook = execContext.reGetBookRequested,
                        )
                    }
                }
            }
            val listRuleRaw = rule.string("chapterList") ?: throw RuleExecutionException("缺少 ruleToc.chapterList")
            // Android BookChapterList.kt:124-132 在 URL-only 去重（BookChapter.kt:111-118）前
            // 对整个已收集列表按 `-` 语义反转，随后按书架 reverseToc=false 再反转输出。
            val reverseOutput = listRuleRaw.trimStart().startsWith("-")
            val listRule = listRuleRaw.trimStart().removePrefix("-").removePrefix("+").trim()
            val formatJs = rule.string("formatJs")?.trim().takeUnless { it.isNullOrBlank() }
            val nextTocRule = rule.string("nextTocUrl")?.trim().takeUnless { it.isNullOrBlank() }
            val collected = mutableListOf<ChapterDraft>()
            // Android `BookChapterList`：**逐页**解析并跟随 `nextTocUrl`，直到没有下一页。
            // 目录首页与后续页共用同一条队列循环 —— 包括聚合源的 `data:` 载荷
            // （`fetchResponse` 会直接解码它），这样 data: 目录也能翻页；旧实现对
            // data: 载荷只解析第一页，`nextTocUrl` 被完全忽略。
            // 首个目录地址必须是可抓取地址（http(s) 或聚合源的 `data:` 载荷）。
            require(effectiveTocUrl.isFetchableSourceUrl()) {
                "URL 格式无效或包含未解析变量: $effectiveTocUrl"
            }
            val queue = ArrayDeque<String>()
            queue.add(effectiveTocUrl)
            val visited = LinkedHashSet<String>()
            // Android `BookChapterList.analyzeChapterList` 每个目录页建一个 AnalyzeRule，
            // 该页所有规则（列表/章节字段/nextTocUrl）共享变量表，并落在 Book 变量上。
            val stepVariables = book?.variables ?: mutableMapOf()
            while (queue.isNotEmpty() && collected.size < MAX_LIST_ITEMS) {
                val currentUrl = queue.removeFirst()
                checkTocCancelled(cancellationCheck)
                if (!visited.add(currentUrl)) continue
                val response = fetchResponse(currentUrl, sourceId = sourceKey, source = source, book = book)
                checkTocCancelled(cancellationCheck)
                // 链接基准：http(s) 用**最终响应地址**（重定向后）；`data:` 载荷没有网络响应，
                // 退回书源地址（与详情/正文路径同一套 resolutionBase 约定）。
                val pageBase = resolutionBase(source, response.url)
                val pageNodes = if (isJsRule(listRule)) {
                    jsListNodes(NodeValue.document(response.body), listRule, response.body, pageBase, stepVariables)
                } else {
                    nodes(response.body, listRule, pageBase, stepVariables)
                }
                collectChapters(
                    rule = rule,
                    nodes = pageNodes,
                    body = response.body,
                    baseUrl = pageBase,
                    // Android BookChapterList 的 `baseUrl` 参数是**请求地址**，不是重定向后的地址。
                    fallbackUrl = currentUrl,
                    collected = collected,
                    variables = stepVariables,
                    cancellationCheck = cancellationCheck,
                )
                checkTocCancelled(cancellationCheck)
                val nextRule = nextTocRule ?: break
                val nextRaw = NodeValue.document(response.body)
                    .valueList(nextRule, jsSandbox, response.body, pageBase, stepVariables).orEmpty()
                for (nextValue in nextRaw) {
                    val trimmed = nextValue.trim()
                    if (trimmed.isBlank()) continue
                    val absolute = trimmed.absolute(pageBase).trim()
                    // 只跟随**可抓取**的地址：JS 规则取不到值时沙箱会把全局 `result` 兜回来
                    // （返回整段响应体），那种值不是 URL，绝不能当成下一页去请求。
                    if (!absolute.isFetchableSourceUrl()) continue
                    if (absolute == currentUrl || absolute == response.url ||
                        absolute in visited || queue.contains(absolute)
                    ) {
                        continue
                    }
                    queue.add(absolute)
                }
            }
            if (collected.isEmpty()) return emptyList()
            finalizeChapters(collected, reverseOutput, formatJs, execContext)
        }
    }

    /** 从一页目录节点收集章节：按页最终 URL 补全并保留全部行，去重延迟到 Android 收尾路径。 */
    private fun collectChapters(
        rule: JsonObject,
        nodes: List<NodeValue>,
        body: String,
        /** 相对链接基准：Android `AnalyzeRule.setRedirectUrl` 的对应物（目录页最终 URL）。 */
        baseUrl: String,
        /** 规则取不到 chapterUrl 时的兜底地址：Android 用请求时的 baseUrl，而非重定向后的 URL。 */
        fallbackUrl: String = baseUrl,
        collected: MutableList<ChapterDraft>,
        /** 该目录页的共享变量表（`@put`/`@get`）；与 Android 的 AnalyzeRule 变量表同语义。 */
        variables: MutableMap<String, String> = mutableMapOf(),
        cancellationCheck: (() -> Unit)? = null,
    ) {
        for ((rowIndex, node) in nodes.withIndex()) {
            if (collected.size >= MAX_LIST_ITEMS) return
            checkTocCancelled(cancellationCheck)
            val title = runCatching { node.value(rule.string("chapterName"), jsSandbox, body, baseUrl, variables) }.getOrNull()
                ?.trim().orEmpty()
            if (title.isBlank()) continue
            val isVolume = runCatching { node.value(rule.string("isVolume"), jsSandbox, body, baseUrl, variables) }.getOrNull().isTrue()
            val updateTime = runCatching { node.value(rule.string("updateTime"), jsSandbox, body, baseUrl, variables) }.getOrNull()?.trim()?.takeIf { it.isNotBlank() }
            var tag = updateTime
            var wordCount: String? = null
            if (!isVolume && tag != null) {
                Regex("(?:^|字数[：:、]?|\\s+)([0-9万千百\\.]{1,6}字)").find(tag)?.let { match ->
                    wordCount = match.groupValues[1].trim()
                    tag = tag?.replaceFirst(match.value, "")
                }
            }
            val rawChapterUrl = node.value(rule.string("chapterUrl"), jsSandbox, body, baseUrl, variables).orEmpty()
            // Android BookChapterList：先按「一级目录用标题 + index」/「正文用 baseUrl」兜底 url，
            // 兜底值是**原始值**（不是补全后的地址）；去重键也是它。
            val emptyUrlFallback = if (isVolume) title + rowIndex else fallbackUrl
            val rawUrl = rawChapterUrl.ifEmpty { emptyUrlFallback }
            val chapterUrl = rawChapterUrl.takeIf { it.isNotEmpty() }
                ?.trim()?.absolute(baseUrl, normalizeAndroidOptionSeparator = true).orEmpty().ifBlank {
                    rawUrl
                }
            val isVip = runCatching { node.value(rule.string("isVip"), jsSandbox, body, baseUrl, variables) }.getOrNull().isTrue()
            val isPay = runCatching { node.value(rule.string("isPay"), jsSandbox, body, baseUrl, variables) }.getOrNull().isTrue()
            val entry = ChapterDraft(
                title = title,
                rawUrl = rawUrl,
                url = chapterUrl,
                isVolume = isVolume,
                isVip = isVip,
                isPay = isPay,
                tag = tag,
                wordCount = wordCount,
                updateTime = updateTime,
            )
            collected.add(entry)
            checkTocCancelled(cancellationCheck)
        }
    }

    /**
     * 目录取消检查：显式回调来自共用 suspend seam；否则仍响应调用线程的中断标志。
     * 回调必须在规则字段失败兜底外触发，避免被 runCatching 吞掉。
     */
    private fun checkTocCancelled(cancellationCheck: (() -> Unit)?) {
        if (Thread.currentThread().isInterrupted) throw CancellationException("TOC pagination interrupted")
        cancellationCheck?.invoke()
    }

    /** Android BookChapterList 收尾：reverse 输出、formatJs 逐章求值（失败保持原标题，不吞整次执行）。 */
    private fun finalizeChapters(
        collected: List<ChapterDraft>,
        reverseOutput: Boolean,
        formatJs: String?,
        execContext: JsExecutionContext,
    ): List<Chapter> {
        // Android `BookChapter.url`（而非延迟解析后的绝对 URL）是唯一相等键。默认先将整个列表反转后取首见项，
        // 再随书架 reverseToc=false 反转输出；`-` 跳过前置反转，两者最后都反转收尾。
        val deduped = LinkedHashMap<String, ChapterDraft>()
        if (reverseOutput) {
            for (draft in collected) deduped.putIfAbsent(draft.rawUrl, draft)
        } else {
            for (draft in collected.asReversed()) deduped.putIfAbsent(draft.rawUrl, draft)
        }
        val ordered = deduped.values.reversed()
            .mapIndexed { index, draft -> Chapter(index, draft.title, draft.url, draft.isVolume, draft.isVip, draft.isPay, draft.tag, draft.wordCount, draft.updateTime) }
        if (formatJs.isNullOrBlank()) return ordered
        val sharedBindings = NativeObject().also { ScriptableObject.putProperty(it, "gInt", 0) }
        return ordered.mapIndexed { index, chapter ->
            val chapterBridge = NativeObject().also { bridge ->
                ScriptableObject.putProperty(bridge, "title", chapter.title)
                ScriptableObject.putProperty(bridge, "url", chapter.url)
                ScriptableObject.putProperty(bridge, "bookUrl", chapter.url)
                ScriptableObject.putProperty(bridge, "isVolume", chapter.isVolume)
                ScriptableObject.putProperty(bridge, "isVip", chapter.isVip)
                ScriptableObject.putProperty(bridge, "isPay", chapter.isPay)
                ScriptableObject.putProperty(bridge, "tag", chapter.tag)
                ScriptableObject.putProperty(bridge, "wordCount", chapter.wordCount)
                ScriptableObject.putProperty(bridge, "updateTime", chapter.updateTime)
            }
            val evaluated = runCatching {
                jsSandbox.eval(
                    formatJs,
                    mapOf(
                        "gInt" to sharedBindings,
                        "index" to index + 1,
                        "chapter" to chapterBridge,
                        "title" to chapter.title,
                    ),
                    execContext,
                )
            }.getOrNull()?.trim()
                .also { if (it.isNullOrBlank()) throw RuleExecutionException("formatJs 计算失败：${execContext.lastError ?: "脚本无返回值"}") }
            if (evaluated.isNullOrBlank()) chapter else chapter.copy(title = evaluated)
        }
    }

    private fun isJsRule(rule: String): Boolean {
        val trimmed = rule.trimStart()
        return trimmed.startsWith("@js:") || trimmed.startsWith("js:") || (rule.contains("<js>") && rule.contains("</js>"))
    }

    private fun String?.isTrue(): Boolean {
        if (isNullOrBlank() || this == "null") return false
        return !trim().matches(Regex("(?i)^(?:false|no|not|0|0\\.0)$"))
    }

    /** `<js>` 形式的列表规则：求值得到 JSON 数组后逐项包装成可继续取值的节点。 */
    private fun jsListNodes(
        base: NodeValue,
        listRule: String,
        body: String,
        baseUrl: String,
        variables: MutableMap<String, String> = mutableMapOf(),
    ): List<NodeValue> {
        val pureJsRule = pureJsListScript(listRule)
        if (pureJsRule != null) {
            val jsResult = body.trimStart().takeIf { it.startsWith("{") || it.startsWith("[") }
                ?.let { runCatching { JsonPath.parse(body).json<Any>() }.getOrNull() }
                ?: body
            val evaluated = jsSandbox.evalObject(
                pureJsRule,
                mapOf("result" to jsResult, "src" to body, "baseUrl" to baseUrl),
            )
            JsoupBridge.unwrapElements(evaluated)?.let { elements ->
                return elements.take(MAX_LIST_ITEMS).map { NodeValue.html(it) }
            }
            val items = nativeListItems(evaluated)
            if (items != null) return items.map { NodeValue.json(toPlainJsValue(it)) }
        }

        // Android 这条路径是 `getElements`（列表节点），与 `getElement` 一样**不做**实体解码。
        // Android `getElements` 对单元素结果同样是一个 1 项列表（多元素才拼成 JSON 数组），
        // 因此 JSON 对象/标量结果也必须包成一项，不能当成"没有列表"丢掉。
        val json = base.value(listRule, jsSandbox, body, baseUrl, variables, unescape = false) ?: return emptyList()
        return when (val parsed = runCatching { Json.parseToJsonElement(json) }.getOrNull()) {
            null -> emptyList()
            is JsonArray -> parsed.map { NodeValue.json(it.toPlainJava()) }
            else -> listOf(NodeValue.json(parsed.toPlainJava()))
        }
    }

    private fun jsListNodes(
        body: String,
        listRule: String,
        rawBody: String?,
        baseUrl: String,
        variables: MutableMap<String, String> = mutableMapOf(),
    ): List<NodeValue> =
        jsListNodes(NodeValue.document(body), listRule, rawBody ?: body, baseUrl, variables)

    /** 把 kotlinx JsonElement 转成普通 Java 结构，使 JsonPath 取值与 JS 属性访问都能正常工作。 */
    private fun JsonElement.toPlainJava(): Any? = when (this) {
        is JsonObject -> LinkedHashMap<String, Any?>().also { map -> entries.forEach { (key, value) -> map[key] = value.toPlainJava() } }
        is JsonArray -> map { it.toPlainJava() }
        is JsonPrimitive -> if (isString) content
        else content.toBooleanStrictOrNull() ?: content.toLongOrNull() ?: content.toDoubleOrNull() ?: content
        JsonNull -> null
    }

    private fun pureJsListScript(rule: String): String? {
        val trimmed = rule.trim()
        if (trimmed.contains("##")) return null
        return when {
            trimmed.startsWith("@js:", ignoreCase = true) -> trimmed.substring(4).trim()
            trimmed.startsWith("js:") -> trimmed.substring(3).trim()
            trimmed.startsWith("<js>") && trimmed.endsWith("</js>") ->
                trimmed.removePrefix("<js>").removeSuffix("</js>").trim()
            else -> null
        }
    }

    private fun nativeListItems(value: Any?): List<Any?>? = when (value) {
        null, is String, is Number, is Boolean -> null
        is NativeArray -> List(value.length.toInt()) { index -> value.get(index, value) }
        is List<*> -> value
        is Array<*> -> value.toList()
        else -> null
    }

    private fun toPlainJsValue(value: Any?): Any? = when (value) {
        null, is String, is Number, is Boolean -> value
        is NativeArray -> List(value.length.toInt()) { index -> toPlainJsValue(value.get(index, value)) }
        is NativeObject -> value.ids.filterIsInstance<String>().associateWith { key ->
            toPlainJsValue((value as Map<*, *>)[key])
        }
        is Map<*, *> -> value.entries.associate { (key, item) -> key.toString() to toPlainJsValue(item) }
        is Collection<*> -> value.map { toPlainJsValue(it) }
        else -> value
    }

    fun content(sourceJson: String, chapterUrl: String, bookName: String? = null, book: BookContext? = null): ChapterContent {
        val source = sourceJson.objectValue()
        val sourceUrl = source.string("bookSourceUrl")
        val sourceKey = sourceId(source)
        val sourceName = source.string("bookSourceName")
        val replaceRules = database?.getEnabledReplaceRulesForScope(bookName, sourceUrl, sourceName).orEmpty()

        if (source.string("mainJs")?.isNotBlank() == true) {
            val result = JsSourceRunner(this, source).content(chapterUrl, book)
            val rawTitle = result.title
            val rawContent = result.content
            // mainJs 路径没有 book 桥接对象；开关取 BookContext 里已从库读出的值。
            if (replaceRules.isEmpty() || book?.useReplaceRule == false) return ChapterContent(rawTitle, rawContent, rawTitle, rawContent)
            val cleanedTitle = rawTitle?.let { ContentProcessor.processTitle(it, replaceRules, jsSandbox, bookName) }
            val cleanedText = ContentProcessor.processContent(rawContent, replaceRules, jsSandbox, bookName, rawTitle)
            return ChapterContent(cleanedTitle, cleanedText, rawTitle, rawContent)
        }

        val baseUrl = book?.tocUrl?.takeIf { it.isNotBlank() }
            ?: book?.bookUrl?.takeIf { it.isNotBlank() }
            ?: sourceBaseUrl(source)
        val normalizedChapterUrl = chapterUrl.absolute(baseUrl, normalizeAndroidOptionSeparator = true)
        val cachedChapters = book?.let { context ->
            database?.getTocCache(sourceKey, context.bookUrl)
                ?.takeIf { it.isNotEmpty() }
                ?: context.tocUrl?.takeIf { it.isNotBlank() }?.let {
                    database?.getTocCache(sourceKey, it)
                }
        }
        val cachedChapter = cachedChapters?.firstOrNull { it.url == normalizedChapterUrl }
        val nextChapterUrl = cachedChapter?.let { current ->
            val nextChapter = cachedChapters.getOrNull(current.index + 1)
                ?: cachedChapters.firstOrNull()
            nextChapter?.url
        }
        val execContext = sourceContext(source, sourceKey, book).let {
            it.copy(
                chapterUrl = normalizedChapterUrl,
                chapterIndex = cachedChapter?.index,
                chapterTitle = cachedChapter?.title,
            )
        }
        return jsSandbox.withSourceContext(execContext) {
            val rule = source.objectValue("ruleContent") ?: throw RuleExecutionException("该书源未配置 ruleContent")
            val contentRule = rule.string("content")
            val nextRule = rule.string("nextContentUrl")?.trim().takeUnless { it.isNullOrBlank() }
            // Android WebBook.getContent：正文请求带着 ruleContent 的 webJs/sourceRegex
            // （`analyzeUrl.getStrResponseAwait(jsStr = contentRule.webJs, sourceRegex = contentRule.sourceRegex)`）。
            // 只有 URL 选项里带 webView 时才真正走浏览器通道，与 AnalyzeUrl.useWebView 的判定一致。
            val contentWebJs = rule.string("webJs")?.trim().takeUnless { it.isNullOrBlank() }
            val contentSourceRegex = rule.string("sourceRegex")?.trim().takeUnless { it.isNullOrBlank() }
            val dataPayload = dataUrlPayload(normalizedChapterUrl)
            val pages = mutableListOf<String>()
            // Android `BookContent.analyzeContent` 的 AnalyzeRule 变量表同样挂在 Book 上：
            // `@put`/`java.put` 写在正文规则里的变量要能被后续分页规则 `@get` 读到。
            val stepVariables = book?.variables ?: mutableMapOf()
            var titleBase: NodeValue? = null
            var titleBody = ""
            var titleBaseUrl = normalizedChapterUrl
            if (dataPayload != null) {
                // 聚合源的章节地址同样是 data: 参数载体，正文由内容规则自行取回；
                // 相对链接的基准退回书源地址（它没有可请求的最终 URL）。
                val dataBase = resolutionBase(source, normalizedChapterUrl)
                pages += NodeValue.document(dataPayload)
                    .value(contentRule, jsSandbox, dataPayload, dataBase, stepVariables)?.cleanContent(dataBase).orEmpty()
                titleBase = NodeValue.document(dataPayload)
                titleBody = dataPayload
                // Android BookContent.analyzeContent 的 nextContentUrl 分页对**所有**地址一视同仁：
                // 在 data: 载荷上同样取下一页、按页求值。上一版只在 http(s) 分支里翻页，
                // 导致「正文分页」类书源的聚合实现只能拿到第一页。
                if (nextRule != null) {
                    val firstPayload: String = dataPayload
                    val visited = LinkedHashSet<String>()
                    visited.add(normalizedChapterUrl.orEmpty())
                    var currentPayload = firstPayload
                    var currentBase = dataBase
                    var currentUrl = normalizedChapterUrl.orEmpty()
                    while (visited.size < MAX_PAGED_URLS) {
                        val pageRoot = NodeValue.document(currentPayload)
                        val nextRaw = pageRoot.value(nextRule, jsSandbox, currentPayload, currentBase, stepVariables).orEmpty()
                        val nextCandidates = nextRaw.lines().mapNotNull { line ->
                            val trimmed = line.trim()
                            if (trimmed.isBlank()) null else trimmed.absolute(currentBase, normalizeAndroidOptionSeparator = true).trim()
                        }
                        // Android BookContent：分页链回到下一章地址时停止（避免把下一章正文并入本章）。
                        if (nextChapterUrl != null && nextCandidates.size == 1 &&
                            nextCandidates.single() == nextChapterUrl
                        ) {
                            break
                        }
                        val nextValue = nextCandidates.firstOrNull { candidate ->
                            candidate.isFetchableSourceUrl() && candidate != currentUrl && candidate !in visited
                        } ?: break
                        val nextPayload = dataUrlPayload(nextValue)
                            ?: throw RuleExecutionException("正文分页地址不是 data: 载荷: ${nextValue.take(200)}")
                        visited.add(nextValue)
                        val nextBase = resolutionBase(source, nextValue)
                        val pageText = NodeValue.document(nextPayload)
                            .value(contentRule, jsSandbox, nextPayload, nextBase, stepVariables)
                            ?.cleanContent(nextBase).orEmpty()
                        if (pageText.isNotBlank()) pages += pageText
                        currentPayload = nextPayload
                        currentBase = nextBase
                        currentUrl = nextValue
                    }
                    // 命中兜底上限时保留已解析的页，不把整章正文判失败（Android 没有页数上限）。
                }
            } else {
                // Android AnalyzeUrl splits even unrecognized option-shaped suffixes before the
                // actual request; SourceUrlOptions remains authoritative for recognized options.
                val requestUrl = if (SourceUrlOptions.split(normalizedChapterUrl).second == null) {
                    androidOptionSeparator.find(normalizedChapterUrl)?.let {
                        normalizedChapterUrl.substring(0, it.range.first).trim()
                    } ?: normalizedChapterUrl
                } else {
                    normalizedChapterUrl
                }
                require(requestUrl.startsWith("http://", true) || requestUrl.startsWith("https://", true)) {
                    "URL 格式无效或包含未解析变量: $requestUrl"
                }
                val visited = LinkedHashSet<String>()
                val queue = ArrayDeque<String>()
                queue.add(requestUrl)
                while (queue.isNotEmpty() && visited.size < MAX_PAGED_URLS) {
                    val currentUrl = queue.removeFirst()
                    if (!visited.add(currentUrl)) continue
                    val response = fetchResponse(
                        currentUrl,
                        sourceId = sourceKey,
                        source = source,
                        book = book,
                        webJsOverride = contentWebJs,
                        sourceRegexOverride = contentSourceRegex,
                    )
                    if (titleBase == null) {
                        titleBase = NodeValue.document(response.body)
                        titleBody = response.body
                        titleBaseUrl = response.url
                    }
                    val pageRoot = NodeValue.document(response.body)
                    val pageText = pageRoot.value(contentRule, jsSandbox, response.body, response.url, stepVariables)
                        ?.cleanContent(response.url).orEmpty()
                    if (pageText.isNotBlank()) pages += pageText
                    if (nextRule == null) break
                    val nextRaw = pageRoot.value(nextRule, jsSandbox, response.body, response.url, stepVariables).orEmpty()
                    val nextCandidates = nextRaw.lines().mapNotNull { line ->
                        val trimmed = line.trim()
                        if (trimmed.isBlank()) null else trimmed.absolute(response.url).trim()
                    }
                    val stopsAtNextChapter = nextCandidates.size == 1 && nextCandidates.single() == nextChapterUrl
                    for (absolute in nextCandidates) {
                        if (stopsAtNextChapter && absolute == nextChapterUrl) continue
                        if (!absolute.isFetchableSourceUrl()) continue
                        if (absolute == currentUrl || absolute == response.url || absolute in visited || queue.contains(absolute)) continue
                        queue.add(absolute)
                    }
                }
                // 命中兜底上限时保留已抓取的页（Android 无页数上限，只有防环终止）。
            }
            // Android BookContent：各页 content join "\n" → 逐行 trim → replaceRegex 清洗。
            // <500 段落大兜底已移除：抓全站 <p> 不是规则成功，正文空必须如实失败。
            // 副文（ruleContent.subContent）在**首页文档**上求值，且先于 join/replaceRegex 追加，
            // 因此源自身的替换规则同样作用于副文 —— 与 Android BookContent 的顺序一致。
            // 说明：Android 在音频/视频书上把副文当歌词/弹幕存字段（服务端音频走 AudioFetcher，
            // 不经过这里），视频弹幕服务端不支持，故此处只覆盖在线文本的追加语义。
            rule.string("subContent")?.takeIf { it.isNotBlank() }?.let { subContentRule ->
                val firstPageDoc = titleBase
                if (firstPageDoc != null) {
                    // Android 用 runCatching 包住副文求值：失败只记日志，不影响正文。
                    val subContent = runCatching {
                        firstPageDoc.value(subContentRule, jsSandbox, titleBody, titleBaseUrl, stepVariables)
                    }.getOrNull().orEmpty()
                    if (subContent.isNotEmpty()) pages += subContent
                }
            }
            var text = pages.joinToString("\n").split('\n').joinToString("\n") { it.trim() }
            text = applyContentReplaceRegex(text, rule.string("replaceRegex"))
            if (text.isBlank()) {
                val detail = jsSandbox.lastError?.let { "，脚本异常：$it" } ?: ""
                throw RuleExecutionException("正文规则未提取到内容$detail")
            }

            val rawTitle = titleBase?.value(rule.string("title"), jsSandbox, titleBody, titleBaseUrl, stepVariables)
            val rawText = text
            var cleanedTitle = rawTitle
            var cleanedText = rawText
            // Legado ContentProcessor：`useReplace && book.getUseReplaceRule()` 双闸门。
            // 关掉时只跳过**全局**替换净化；源自身 `replaceRegex` 已在上面处理过，不受影响。
            if (execContext.useReplaceRule && replaceRules.isNotEmpty()) {
                cleanedText = ContentProcessor.processContent(rawText, replaceRules, jsSandbox, bookName, rawTitle)
                if (rawTitle != null) {
                    cleanedTitle = ContentProcessor.processTitle(rawTitle, replaceRules, jsSandbox, bookName)
                }
            }
            if (book != null && book.useReplaceRule != execContext.useReplaceRule) {
                book.useReplaceRule = execContext.useReplaceRule
                book.sourceId.takeIf { it.isNotBlank() }?.let { sourceId ->
                    database?.saveUseReplaceRule(sourceId, book.bookUrl, execContext.useReplaceRule)
                }
            }
            ChapterContent(cleanedTitle, cleanedText, rawTitle, rawText)
        }
    }

    /** Android BookContent.replaceRegex：`##regex##replacement##1`（replaceFirst）；无 `##` 时整条当删除正则（历史行为）。 */
    private fun applyContentReplaceRegex(text: String, replaceRegex: String?): String {
        if (replaceRegex.isNullOrBlank()) return text
        var result = text
        for (pattern in replaceRegex.split(Regex("[\r\n]+|&&")).map { it.trim() }.filter { it.isNotBlank() }) {
            result = if (pattern.contains("##")) {
                val parts = pattern.split("##")
                val regex = parts.getOrNull(1)?.takeIf { it.isNotBlank() } ?: continue
                val replacement = parts.getOrNull(2) ?: ""
                val firstOnly = parts.getOrNull(3)?.trim() == "1"
                runCatching {
                    if (firstOnly) result.replaceFirst(Regex(regex), replacement) else result.replace(Regex(regex), replacement)
                }.getOrDefault(result)
            } else {
                runCatching { result.replace(Regex(pattern), "") }.getOrDefault(result)
            }
        }
        return result
    }

    /**
     * 解析一章漫画的**有序图片 URL 清单**——方案 E · 方案 A 的解析层复用。
     *
     * 与 [content] 共享 fetch / 规则链 / JS 沙箱，**唯一差异是最后一步**：
     * `content()` 做文本净化 → 单行文本；
     * `mangaImages()` 做 URL 拆分 → 有序 URL 列表。
     *
     * @return 有序去重后的全量上游图片 URL（空列表意味着规则未提取到图片）。
     */
    fun mangaImages(sourceJson: String, chapterUrl: String, bookName: String? = null, book: BookContext? = null): List<String> {
        val source = sourceJson.objectValue()
        val sourceUrl = source.string("bookSourceUrl")

        // JS 书源（mainJs）：走 JsSourceRunner 取回文本，再尝试从文本中提取图片 URL
        if (source.string("mainJs")?.isNotBlank() == true) {
            val result = JsSourceRunner(this, source).content(chapterUrl)
            return splitImageUrls(result.content)
        }

        return jsSandbox.withSourceContext(
            sourceContext(source, sourceUrl, book).let { it.copy(chapterUrl = chapterUrl) },
        ) {
            val rule = source.objectValue("ruleContent") ?: throw RuleExecutionException("该书源未配置 ruleContent")
            val dataPayload = dataUrlPayload(chapterUrl)
            val body: String
            val root: NodeValue
            val chapterBase = resolutionBase(source, chapterUrl)
            if (dataPayload != null) {
                body = dataPayload
                root = NodeValue.document(dataPayload)
            } else {
                val (url, options) = splitUrlOptions(chapterUrl)
                val mergedOptions = mergeOptions(parseSourceHeaders(source, sourceUrl), options)
                body = fetchUrl(url, mergedOptions, null, sourceUrl, database)
                root = NodeValue.document(body)
            }
            val raw = root.value(rule.string("content"), jsSandbox, body, chapterBase)?.trim() ?: ""
            val urls = splitImageUrls(raw).map { it.absolute(chapterBase) }
            // 保序去重（同一张图重现时保留首次位置）
            val seen = mutableSetOf<String>()
            urls.filter { it.isNotBlank() && seen.add(it) }
        }
    }

    /**
     * 从规则求值所得的字符串中提取有序图片 URL。
     *
     * 三种来源（按优先级）：
     * 1. HTML 片段里的 `<img>` 标签：优先用 `data-src` / `data-original`（懒加载兼容），否则用 `src`；
     * 2. JSON 数组字符串：`["url1","url2"]`；
     * 3. 换行分隔的纯文本 URL 列表（Legado 多值选择器默认 `\n` 连接）。
     */
    internal fun splitImageUrls(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()

        fun cleanImageUrl(url: String): String =
            url.substringBefore(",{").substringBefore(",%7B").trim().trimEnd(',', ' ')

        // 1. 按 <img> 标签提取 src / data-src / data-original
        val doc = Jsoup.parse(raw)
        val imgs = doc.select("img")
        if (imgs.isNotEmpty()) {
            return imgs.mapNotNull { el ->
                (el.attr("data-src").takeIf { it.isNotBlank() }
                    ?: el.attr("data-original").takeIf { it.isNotBlank() }
                    ?: el.attr("src").takeIf { it.isNotBlank() })
                    ?.let(::cleanImageUrl)
            }.filter { it.isNotBlank() }
        }

        // 2. JSON 数组字符串
        val trimmed = raw.trim()
        if (trimmed.startsWith("[")) {
            val parsed = runCatching { Json.parseToJsonElement(trimmed) }.getOrNull() as? JsonArray
            if (parsed != null) {
                return parsed.mapNotNull { element -> (element as? JsonPrimitive)?.contentOrNull?.let(::cleanImageUrl) }.filter { it.isNotBlank() }
            }
        }

        // 3. 换行分隔（Legado 多元素 CSS / JSON 多值连接默认 "\n"）
        return raw.lines().map(::cleanImageUrl).filter { it.isNotBlank() }
    }

    /**
     * 抓取**媒体资源**（漫画图片 / 有声书音频）时该用的请求头：书源 `header` + 登录头 + Cookie。
     *
     * 为什么要开这个 public 口子：媒体抓取发生在 `RuleRunner` 之外（`MangaImageFetcher`），
     * 但它**必须与书源取数用同一份请求头**——漫画站/音频站的防盗链判的就是这套头，
     * 少一个 `Referer` 或 Cookie 就是整章裂图，而且不会有任何报错。
     *
     * 解析失败一律返回空表（静默降级），绝不让头解析把抓取流程打断。
     */
    fun mediaHeaders(sourceJson: String, sourceId: String? = null): Map<String, String> =
        runCatching { parseSourceHeaders(sourceJson.objectValue(), sourceId) }.getOrDefault(emptyMap())

    /**
     * 书源的图片解密规则（Android `ImageUtils.getRuleJs`）：封面取 `coverDecodeJs`，
     * 正文图片取 `ruleContent.imageDecode`。规则为空返回 null（= 不做任何处理）。
     */
    internal fun imageDecodeRule(sourceJson: String, isCover: Boolean): String? = runCatching {
        val source = sourceJson.objectValue()
        val rule = if (isCover) {
            source.string("coverDecodeJs")
        } else {
            source.objectValue("ruleContent")?.string("imageDecode")
        }
        rule?.trim()?.takeIf { it.isNotBlank() }
    }.getOrNull()

    /** Android `NetworkUtils.getAbsoluteURL(base, url)`：给 WebJs 的 `getStringList(..., isUrl = true)` 用。 */
    internal fun absoluteUrl(base: String?, url: String): String =
        if (base.isNullOrBlank()) url else url.absolute(base)

    /**
     * Android `SourceCallBack`：书源开了 `eventListener` 且写了 `ruleContent.callBackJs` 时，
     * 由**书架动作**触发脚本。
     *
     * 与 Android 逐条对齐：
     * - 未开 `eventListener` 或 `callBackJs` 为空 ⇒ 直接跳过（返回 false，调用方按"没拦"处理）；
     * - 绑定 `event` / `result` / `book` / `chapter`，`baseUrl` = 书源地址；
     * - 返回值按 Android `String.isTrue()` 判定（`"true"` / `"1"` 为真），供"拦截型"事件使用；
     * - 脚本抛错只当失败，**绝不把异常抛给书架动作**（Android 也只是记日志）。
     *
     * 边界：Android 里还有点击类事件（`clickCustomButton`/`clickAuthor`…）与阅读会话事件
     * （`startRead`/`saveRead`/`endRead`）——前者属于阅读界面交互，后者由阅读端（前端/插件）
     * 产生，服务端没有对应交互，因此不在服务端触发。
     */
    internal fun runSourceCallback(
        sourceJson: String,
        event: String,
        book: BookContext? = null,
        chapter: Chapter? = null,
        result: String? = null,
    ): Boolean {
        val source = runCatching { sourceJson.objectValue() }.getOrNull() ?: return false
        val listenerEnabled = (source["eventListener"] as? JsonPrimitive)?.let { value ->
            if (value.isString) value.content.equals("true", ignoreCase = true) else value.content == "true"
        } == true
        if (!listenerEnabled) return false
        val rule = source.objectValue("ruleContent")?.string("callBackJs")?.takeIf { it.isNotBlank() } ?: return false
        return runCatching {
            val execContext = sourceContext(source, sourceId(source), book).let { context ->
                if (chapter == null) {
                    context
                } else {
                    context.copy(
                        chapterUrl = chapter.url,
                        chapterIndex = chapter.index,
                        chapterTitle = chapter.title,
                    )
                }
            }
            jsSandbox.withSourceContext(execContext) {
                jsSandbox.eval(
                    rule,
                    bindings = mapOf("event" to event, "result" to result),
                    execContext = execContext,
                )?.isTrue() == true
            }
        }.getOrDefault(false)
    }

    /** 需要解密时返回解密器，规则为空返回 null（调用方据此走「不解密」的短路路径）。 */
    internal fun imageDecoder(sourceJson: String, isCover: Boolean, book: BookContext? = null): ImageByteDecoder? =
        imageDecodeRule(sourceJson, isCover)?.let { ImageByteDecoder(this, sourceJson, isCover, book) }

    /**
     * 跑一次图片解密脚本（Android `ImageUtils.decode`）。
     *
     * 规则为空 ⇒ 原样返回入参；脚本失败或返回值不是字节 ⇒ 返回 null（判失败，不直出原始字节）。
     * 绑定与 Android 一致：`result`（字节）、`src`（图片地址）、`book`（正文图片会带书）。
     */
    internal fun decodeImageBytes(
        sourceJson: String,
        src: String,
        bytes: ByteArray,
        isCover: Boolean,
        book: BookContext? = null,
    ): ByteArray? {
        val rule = imageDecodeRule(sourceJson, isCover) ?: return bytes
        val source = sourceJson.objectValue()
        val execContext = sourceContext(source, sourceId(source), book)
        return jsSandbox.withSourceContext(execContext) {
            jsSandbox.evalImageBytes(rule, src, bytes, execContext)
        }
    }

    // ------------------------------------------------------------------
    // 有声书（方案 G2）：章节音频地址解析
    // ------------------------------------------------------------------

    /**
     * 解析一章的**有序音频分段清单**——与 [mangaImages] 完全同构，只换最后一步的取值语义。
     *
     * 三种形态（G1）：
     * ① **纯文本 URL**（一行一个，Legado 多值规则默认 `\n` 连接）；
     * ② **JSON 数组**（多分段，**保序**；元素可以是字符串，也可以是 `{url, headers}` 对象）；
     * ③ **`url,{"headers":{...}}` 扩展头**（每段可带独立请求头，必须随分段一起交给 Fetcher，否则重拉 403）。
     *
     * 另额外兼容 HTML 片段里的 `<audio src>` / `<source src>`（部分源的音频规则直接给标签）。
     *
     * @return 有序分段规格；**不含上游 URL 的下发**，URL 只留在服务端（见 `AudioCache` 的 key 语义）。
     */
    fun audioTracks(sourceJson: String, chapterUrl: String, bookName: String? = null, book: BookContext? = null): List<AudioTrackSpec> {
        val source = sourceJson.objectValue()
        val sourceUrl = source.string("bookSourceUrl")

        // JS 书源（mainJs）：走 JsSourceRunner 取回文本，再从中提取音频地址
        if (source.string("mainJs")?.isNotBlank() == true) {
            val result = JsSourceRunner(this, source).content(chapterUrl, book)
            return normalizeTracks(splitAudioTracks(result.content), chapterUrl)
        }

        return jsSandbox.withSourceContext(
            // ⚠️ 必须带上书籍上下文：听书音色就靠源里 `book.getVariable('custom')` 读出来拼进音频地址。
            // 漏了它 ⇒ 变量永远读成空串 ⇒ 用户改了音色也**毫无变化且不报错**（实测踩过）。
            sourceContext(source, sourceUrl, book).let { it.copy(chapterUrl = chapterUrl) },
        ) {
            val rule = source.objectValue("ruleContent") ?: throw RuleExecutionException("该书源未配置 ruleContent")
            val dataPayload = dataUrlPayload(chapterUrl)
            val body: String
            val root: NodeValue
            val chapterBase = resolutionBase(source, chapterUrl)
            if (dataPayload != null) {
                body = dataPayload
                root = NodeValue.document(dataPayload)
            } else {
                val (url, options) = splitUrlOptions(chapterUrl)
                val mergedOptions = mergeOptions(parseSourceHeaders(source, sourceUrl), options)
                body = fetchUrl(url, mergedOptions, null, sourceUrl, database)
                root = NodeValue.document(body)
            }
            val raw = root.value(rule.string("content"), jsSandbox, body, chapterBase)?.trim() ?: ""
            normalizeTracks(splitAudioTracks(raw), chapterBase)
        }
    }

    /**
     * 把相对地址补全到章节页，并**保序去重**。
     *
     * 为什么去重：对外 key = `sha256(sourceId + '\n' + url)` 是 `audio_cache` 的主键，
     * 同一章里出现两条完全相同的地址只会互相覆盖（`segment_index` 丢失），
     * 因此与漫画清单保持同一口径（同一地址只保留首次出现的位置）。
     */
    private fun normalizeTracks(tracks: List<AudioTrackSpec>, chapterUrl: String): List<AudioTrackSpec> {
        val seen = mutableSetOf<String>()
        return tracks.mapNotNull { spec ->
            val url = spec.url.absolute(chapterUrl).trim()
            if (url.isBlank()) return@mapNotNull null
            if (!seen.add("$url\u0000${spec.headersJson.orEmpty()}")) return@mapNotNull null
            spec.copy(url = url)
        }
    }

    /**
     * 从规则求值所得的字符串里提取有序音频分段。
     *
     * 拆分顺序：JSON 数组 → HTML `<audio>/<source>` → 换行纯文本。
     * 元素级的 `url,{"headers":…}` / `{"url":…,"headers":…}` 拆解见 [parseAudioTrackItem]。
     */
    internal fun splitAudioTracks(raw: String?): List<AudioTrackSpec> {
        if (raw.isNullOrBlank()) return emptyList()
        val items = mutableListOf<String>()

        // ① JSON 数组：既可能是 ["url1","url2"]，也可能是 [{"url":…,"headers":…}]
        val trimmed = raw.trim()
        if (trimmed.startsWith("[")) {
            val parsed = runCatching { Json.parseToJsonElement(trimmed) }.getOrNull() as? JsonArray
            if (parsed != null) {
                parsed.forEach { element ->
                    when (element) {
                        is JsonPrimitive -> element.contentOrNull?.let { items += it }
                        // 对象形态：**整条对象**交给 parseAudioTrackItem
                        //（它才知道怎么取 `headers`；只取 url 会把每段专属头静默丢掉 ⇒ 重拉 403）
                        is JsonObject -> items += element.toString()
                        else -> Unit
                    }
                }
            }
        }

        // ② HTML 片段：<audio src> / <source src>（含 <audio><source src=…></audio> 的嵌套形态）
        if (items.isEmpty()) {
            val doc = Jsoup.parse(raw)
            val selected = doc.select("audio[src], source[src]")
            if (selected.isNotEmpty()) selected.forEach { items += it.attr("src") }
        }

        // ③ 换行分隔的纯文本（Legado 多元素规则的默认连接符）
        if (items.isEmpty()) items += raw.lines()

        return items.mapNotNull(::parseAudioTrackItem)
    }

    /**
     * 拆解单条音频项，**同时支持两种扩展头写法**：
     * - `https://a/b.mp3,{"headers":{"Referer":"…"}}`（Legado 的 `url,{options}` 形态）
     * - `{"url":"https://a/b.mp3","headers":{"Referer":"…"}}`（对象形态）
     *
     * 认不出来就当作**裸 URL**（绝不因为"选项解析失败"而丢掉整条音频——
     * 静默丢数据比报错危险得多，而裸 URL 至少还能播）。
     */
    internal fun parseAudioTrackItem(rawItem: String): AudioTrackSpec? {
        val item = rawItem.trim().trim(',', ' ').removeSurrounding("\"").trim()
        if (item.isEmpty()) return null

        if (item.startsWith("{")) {
            val obj = runCatching { Json.parseToJsonElement(item).jsonObject }.getOrNull()
                ?: return AudioTrackSpec(item, null)
            val url = obj.string("url") ?: obj.string("src") ?: return null
            return AudioTrackSpec(cleanAudioUrl(url), obj["headers"]?.toString())
        }

        // `,{` 与 URL 编码后的 `,%7B` 都出现过（上游/书源会自行编码）
        val plainIndex = item.indexOf(",{").takeIf { it >= 0 } ?: Int.MAX_VALUE
        val encodedIndex = item.indexOf(",%7B", ignoreCase = true).takeIf { it >= 0 } ?: Int.MAX_VALUE
        val index = minOf(plainIndex, encodedIndex)
        if (index == Int.MAX_VALUE) return AudioTrackSpec(cleanAudioUrl(item), null)

        val url = cleanAudioUrl(item.substring(0, index))
        val optionsText = item.substring(index + 1).trim()
        val headers = runCatching {
            Json.parseToJsonElement(optionsText).jsonObject["headers"]?.toString()
        }.getOrNull()
        return AudioTrackSpec(url, headers)
    }

    private fun cleanAudioUrl(url: String): String = url.trim().trimEnd(',', ' ')

    fun parseLoginUi(sourceJson: String): List<SourceLoginUiItem> {
        val source = sourceJson.objectValue()
        val sourceUrl = source.string("bookSourceUrl") ?: ""
        val loginUi = source.string("loginUi")
        val loginUiStr = loginUi?.trim()
        val loginUrl = source.string("loginUrl")?.trim()
        val jsLib = source.string("jsLib")?.trim()

        if (loginUiStr.isNullOrBlank()) {
            if (!loginUrl.isNullOrBlank() && (loginUrl.startsWith("http://") || loginUrl.startsWith("https://"))) {
                return listOf(
                    SourceLoginUiItem(
                        name = "打开登录网页",
                        type = "button",
                        action = loginUrl,
                        style = FlexChildStyle(layout_flexBasisPercent = 1.0f),
                    ),
                )
            }
            return emptyList()
        }

        val codeStr = when {
            loginUi.startsWith("@js:") -> loginUi.substring(4)
            loginUi.startsWith("<js>") -> loginUi.substring(4, loginUi.lastIndexOf('<'))
            else -> null
        }

        val rawJson = if (codeStr != null) {
            // Android evalUiJs 将 getLoginJs() 与动态 loginUi 放进同一次 evalJS。
            // 服务端沙箱会额外剥离整段脚本前缀；注释行保持 Android 的原始脚本边界。
            val mainScript = listOf("//", getLoginJs(source), codeStr).joinToString("\n")
            val execContext = sourceContext(source, sourceUrl)
                .copy(sourceName = source.string("bookSourceName") ?: sourceUrl)
            jsSandbox.eval(mainScript, mapOf("sourceId" to sourceUrl, "baseUrl" to sourceUrl), execContext) ?: "[]"
        } else {
            loginUi.orEmpty()
        }

        return runCatching {
            json.decodeFromString<List<SourceLoginUiItem>>(rawJson)
        }.getOrDefault(emptyList())
    }

    fun executeLoginAction(
        sourceJson: String,
        actionCode: String,
        loginData: Map<String, String>,
        isLongClick: Boolean = false,
        browserHook: BrowserHook? = null,
    ): SourceLoginActionResult {
        val source = sourceJson.objectValue()
        val sourceUrl = source.string("bookSourceUrl") ?: ""
        val sourceName = source.string("bookSourceName") ?: sourceUrl

        // Android 只在显式登录动作前拼 getLoginJs；普通规则始终只共享 jsLib。
        val execContext = sourceContext(source, sourceUrl).copy(
            sourceName = sourceName,
            initialLoginInfo = loginData.toMutableMap(),
            isLongClick = isLongClick,
            browserHook = browserHook,
        )
        execContext.loginUiDefaults.putAll(parseLoginUi(sourceJson).filter { it.type != "button" }.associate { it.name to (it.default ?: "") })

        val trimmedAction = actionCode.trim()
        if (trimmedAction.startsWith("http://") || trimmedAction.startsWith("https://")) {
            return SourceLoginActionResult(
                success = true,
                openUrl = trimmedAction,
            )
        }

        val fullScript = if (trimmedAction.equals("login", ignoreCase = true) || trimmedAction.startsWith("login(")) {
            val actionArguments = if (trimmedAction.startsWith("login(", true)) {
                trimmedAction.substringAfter('(', "").substringBeforeLast(')', "").trim()
            } else {
                ""
            }
            "function __executeLoginAction() { if (typeof login === 'function') { login.apply(this, arguments); } else { throw('Function login not implements!!!'); } } __executeLoginAction($actionArguments);"
        } else {
            trimmedAction
        }
        // Android 将 getLoginJs() 与 action 按一次 evalJS 求值，登录脚本抛错会阻断动作。
        // 服务端沙箱会额外剥离整段脚本前缀；注释行保持 Android 的原始脚本边界。
        val mainScript = listOf("//", getLoginJs(source), fullScript).joinToString("\n")

        val bindings = mapOf(
            "result" to loginData,
            "baseUrl" to sourceUrl,
            "sourceId" to sourceUrl,
            "bookSourceUrl" to sourceUrl,
            "isLongClick" to isLongClick,
        )

        jsSandbox.eval(mainScript, bindings, execContext)
        // 内联页会把用户带回前端完成设置；历史脚本在此刻弹出的「未读取到设置结果」
        // 是无头端必然触发的误报，只有在本次确实打开了 data 内联页时才替换。
        if (execContext.openUrl?.startsWith("data:", ignoreCase = true) == true) {
            execContext.toastMessages.replaceAll { message ->
                if (message.contains(NO_SETTINGS_RESULT_MARKER)) {
                    INLINE_BROWSER_SAVE_HINT
                } else {
                    message
                }
            }
        }
        val state = database?.getSourceLoginState(sourceUrl)
        val failure = execContext.lastError
        val openUrl = execContext.openUrl

        return SourceLoginActionResult(
            success = failure == null,
            error = failure,
            toastMessages = execContext.toastMessages,
            openUrl = execContext.openUrl,
            copyText = execContext.copyText,
            updatedLoginInfo = buildMap {
                putAll(execContext.loginUiDefaults)
                putAll(state?.loginInfo.orEmpty())
                putAll(execContext.initialLoginInfo)
            },
            updatedLoginHeader = state?.loginHeader,
            updatedVariable = state?.sourceVariable,
            reRenderUi = execContext.reRenderUi,
        )
    }

    fun checkLoginStatus(sourceJson: String): SourceLoginCheckResult {
        val source = sourceJson.objectValue()
        val sourceUrl = source.string("bookSourceUrl") ?: ""
        // Android 的 loginCheckJs 只在 WebBook 每条真实响应上执行（见 SourceResponseLogin），
        // 没有“无响应独立执行”的语义；脱离响应跑脚本会把任意非空结果当登录成功。
        // 独立 /login-check 只如实报告凭据配置状态，不执行 loginCheckJs。
        val jar = database?.getSourceCookieJar(sourceUrl)
        val state = database?.getSourceLoginState(sourceUrl)
        val hasCookie = jar?.isNotEmpty() == true
        val hasInfo = state?.loginInfo?.isNotEmpty() == true
        return SourceLoginCheckResult(
            loggedIn = false,
            message = when {
                hasCookie && hasInfo -> "已配置 Cookie 与登录信息/未验证"
                hasCookie -> "已配置 Cookie/未验证"
                hasInfo -> "已配置登录信息/未验证"
                else -> "未配置登录凭据"
            },
        )
    }

    internal fun fetch(
        url: String,
        sourceId: String? = null,
        database: Database? = null,
        callTimeoutMillis: Long? = null,
    ): String {
        val (cleanUrl, options) = splitUrlOptions(url)
        val db = database ?: this.database
        val mergedOptions = if (db != null && !sourceId.isNullOrBlank()) {
            val headers = mutableMapOf<String, String>()
            val state = db.getSourceLoginState(sourceId)
            state?.loginHeader?.takeIf { it.isNotBlank() }?.let { h ->
                runCatching {
                    val elem = Json.parseToJsonElement(h)
                    if (elem is JsonObject) {
                        elem.entries.filter { it.value is JsonPrimitive }.forEach {
                            headers[it.key] = (it.value as JsonPrimitive).contentOrNull ?: ""
                        }
                    }
                }
            }
            val cookie = db.getSourceCookie(sourceId, cleanUrl)
            if (!cookie.isNullOrBlank()) {
                headers["Cookie"] = cookie
            }
            mergeOptions(headers, options)
        } else {
            options
        }
        return fetchUrl(cleanUrl, mergedOptions, null, sourceId, db, callTimeoutMillis)
    }

    private fun parseSourceHeaders(source: JsonObject, sourceUrl: String? = null): Map<String, String> {
        val headers = mutableMapOf<String, String>()
        when (val rawHeader = source["header"]) {
            is JsonObject -> rawHeader.entries.filter { it.value is JsonPrimitive }
                .associateTo(headers) { it.key to ((it.value as JsonPrimitive).contentOrNull ?: "") }
            is JsonPrimitive -> rawHeader.contentOrNull?.trim()?.takeIf { it.isNotBlank() }?.let { headers.putAll(parseHeaderMap(it)) }
            else -> Unit
        }
        val sUrl = sourceUrl ?: source.string("bookSourceUrl")
        val db = database
        if (db != null && !sUrl.isNullOrBlank()) {
            val state = db.getSourceLoginState(sUrl)
            state?.loginHeader?.takeIf { it.isNotBlank() }?.let { h ->
                headers.putAll(parseHeaderMap(h))
            }
            val cookie = db.getSourceCookie(sUrl, sUrl)
            if (!cookie.isNullOrBlank()) {
                headers["Cookie"] = cookie
            }
        }
        return headers
    }

    /**
     * 宽容解析书源 `header` / 登录头。
     *
     * 先按标准 JSON 解析；失败则回退到**宽容模式**。
     *
     * 为什么必须宽容：Legado 生态里大量书源的 `header`
     * 用的是**单引号**的伪 JSON，例如：
     * ```
     * { 'User-Agent': 'okhttp/4.9.2', 'client-device': '0cde...', 'Authorization': 'bearer...' }
     * ```
     * 这**不是合法 JSON**，`Json.parseToJsonElement` 会抛异常。旧实现把异常
     * `runCatching` 吞掉 ⇒ **所有请求头被静默丢弃** ⇒ 需要鉴权的上游一律返回
     * 403 / `code:4004 device 不能为空`，表现为「搜索能出结果，但打开书正文全空」。
     *
     * 这类静默丢失极难排查，因此宽容模式是必需的，而不是「顺手兼容一下」。
     */
    internal fun parseHeaderMap(raw: String): Map<String, String> {
        val text = raw.trim()
        if (text.isEmpty()) return emptyMap()
        // 1) 标准 JSON
        runCatching {
            val elem = Json.parseToJsonElement(text)
            if (elem is JsonObject) {
                return elem.entries.filter { it.value is JsonPrimitive }
                    .associate { it.key to ((it.value as JsonPrimitive).contentOrNull ?: "") }
            }
        }
        // 2) 宽容模式：单引号 / 无引号键 / Python dict 风格
        return parseLooseHeaderMap(text)
    }

    /**
     * 宽容模式的键值扫描器。
     *
     * 不用正则硬拆（值里可能含逗号、冒号、引号），而是**逐字符扫描**：
     * 先读键（可带单/双引号或裸标识符），再读冒号后的值（带引号则读到配对引号，
     * 否则读到下一个逗号或结尾），从而正确处理 `Authorization: 'bearer eyJ...'` 这类长值。
     */
    private fun parseLooseHeaderMap(text: String): Map<String, String> {
        val result = linkedMapOf<String, String>()
        var i = text.indexOfFirst { it == '{' }
        i = if (i < 0) 0 else i + 1
        val end = text.lastIndexOf('}').let { if (it < 0) text.length else it }
        while (i < end) {
            // 跳过分隔与空行
            while (i < end && (text[i].isWhitespace() || text[i] == ',' || text[i] == ';')) i++
            if (i >= end) break

            // --- 读键 ---
            val key: String
            val afterKey: Int
            when (text[i]) {
                '\'', '"' -> {
                    val quote = text[i]
                    val close = text.indexOf(quote, i + 1)
                    if (close < 0 || close > end) break
                    key = text.substring(i + 1, close)
                    afterKey = close + 1
                }
                else -> {
                    var j = i
                    while (j < end && text[j] != ':' && text[j] != ',' && text[j] != '\n') j++
                    key = text.substring(i, j).trim()
                    afterKey = j
                }
            }
            i = afterKey
            while (i < end && text[i].isWhitespace()) i++
            if (i >= end || text[i] != ':') {
                // 不是 k:v（例如残留的 `}`），跳到下一个逗号
                while (i < end && text[i] != ',') i++
                continue
            }
            i++ // 跳过 ':'
            while (i < end && text[i].isWhitespace()) i++

            // --- 读值 ---
            val value: String
            if (i < end && (text[i] == '\'' || text[i] == '"')) {
                val quote = text[i]
                val sb = StringBuilder()
                var j = i + 1
                while (j < end) {
                    val ch = text[j]
                    if (ch == '\\' && j + 1 < end) { sb.append(text[j + 1]); j += 2; continue }
                    if (ch == quote) break
                    sb.append(ch); j++
                }
                value = sb.toString()
                i = if (j < end) j + 1 else end
            } else {
                var j = i
                while (j < end && text[j] != ',' && text[j] != '\n') j++
                value = text.substring(i, j).trim()
                i = j
            }
            val cleanKey = key.trim().trim('\'', '"')
            if (cleanKey.isNotEmpty()) result[cleanKey] = value
        }
        return result
    }

    private fun mergeOptions(sourceHeaders: Map<String, String>, options: UrlOptions?): UrlOptions {
        if (sourceHeaders.isEmpty()) return options ?: UrlOptions()
        val combined = sourceHeaders.toMutableMap()
        options?.headers?.let { combined.putAll(it) }
        return (options ?: UrlOptions()).copy(headers = combined)
    }

    internal data class UrlOptions(
        val method: String = "GET",
        val body: String? = null,
        val headers: Map<String, String> = emptyMap(),
        val charset: Charset = Charsets.UTF_8,
        val charsetName: String? = null,
        val retry: Int? = null,
        val timeoutMillis: Long? = null,
        val useWebView: Boolean = false,
        val webJs: String = "",
        /** Android `ContentRule.sourceRegex`：WebView 嗅探资源地址用的正则。 */
        val sourceRegex: String = "",
        val bodyJs: String = "",
        val js: String = "",
        /**
         * Android `UrlOption.type`：非空时响应体是**原始字节的十六进制**
         * （`AnalyzeUrl.getStrResponseAwait` 的 `if (type != null)` 分支），聚合源靠它
         * 把 `data:` 载荷 / 上游响应转成 hex，再在规则里 `java.hexDecodeToString(result)` 解回文本。
         */
        val type: String? = null,
    )

    private fun splitUrlOptions(value: String): Pair<String, UrlOptions?> {
        val (url, optionsObject) = SourceUrlOptions.split(value)
        if (optionsObject == null) return url to null
        return url to UrlOptions(
            method = optionsObject.string("method")?.uppercase() ?: "GET",
            body = optionsObject.string("body"),
            headers = optionsObject.objectValue("headers")?.entries?.filter { it.value is JsonPrimitive }?.associate { it.key to ((it.value as JsonPrimitive).contentOrNull ?: "") } ?: emptyMap(),
            charset = optionsObject.string("charset")
                ?.takeUnless { it.equals("escape", ignoreCase = true) }
                ?.let { runCatching { Charset.forName(it) }.getOrDefault(Charsets.UTF_8) }
                ?: Charsets.UTF_8,
            charsetName = optionsObject.string("charset")?.takeIf { it.isNotBlank() },
            retry = optionsObject.string("retry")?.toIntOrNull(),
            useWebView = optionsObject.flag("webView") == true,
            webJs = optionsObject.string("webJs") ?: "",
            sourceRegex = optionsObject.string("sourceRegex") ?: "",
            bodyJs = optionsObject.string("bodyJs") ?: "",
            js = optionsObject.string("js") ?: "",
            type = optionsObject.string("type")?.takeIf { it.isNotBlank() },
        )
    }

    /** Android `HexUtil.encodeHexStr`：小写十六进制、无分隔符。 */
    private fun hexEncodeBytes(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    private fun JsonObject.flag(key: String): Boolean? = (get(key) as? JsonPrimitive)?.let {
        if (it.isString) it.content.lowercase() != "false" else it.content == "true"
    }

    private fun parseUri(url: String): URI {
        val trimmed = url.trim()
        if (!trimmed.startsWith("http://", ignoreCase = true) && !trimmed.startsWith("https://", ignoreCase = true)) {
            throw RuleExecutionException("URL 格式无效或包含未解析变量: $url")
        }
        // Legado 书源普遍把未转义的 JSON（含 { } " 等）直接拼进 query，Android 端 OkHttp 会自动编码，
        // 而 java.net.URI 严格按 RFC 3986 拒绝。这里先按原样解析，失败再对非法字符做百分号编码。
        runCatching { URI(trimmed) }.getOrNull()?.let { return it }
        val encoded = encodeIllegalUrlChars(trimmed)
        return runCatching { URI(encoded) }.getOrElse {
            throw RuleExecutionException("URL 解析失败: $url (${it.message})")
        }
    }

    private fun fetchUrl(
        url: String,
        options: UrlOptions?,
        keyword: String?,
        sourceId: String? = null,
        database: Database? = null,
        callTimeoutMillis: Long? = null,
    ): String = fetchResponse(
        url,
        keyword = keyword,
        sourceId = sourceId,
        options = options,
        database = database,
        callTimeoutMillis = callTimeoutMillis,
    ).body

    /**
     * Android AnalyzeUrl/WebBook 兼容抓取：模板渲染、选项对象、每跳 Cookie 合并、
     * 301/302/303 转 GET、307/308 保留方法与请求体、有界解码（BOM/声明字符集/HTML meta 嗅探）。
     * 返回 [FetchedResponse]，保留 status/headers/最终 URL 供登录检查与后续 Chromium 通道复用。
     */
    internal fun fetchResponse(
        url: String,
        keyword: String? = null,
        page: Int? = null,
        sourceId: String? = null,
        source: JsonObject? = null,
        book: BookContext? = null,
        options: UrlOptions? = null,
        database: Database? = null,
        callTimeoutMillis: Long? = null,
        firstResponseOnly: Boolean = false,
        hostnamePolicy: SourceHostnamePolicy = SourceHostnamePolicy.ANDROID_OKHTTP,
        /**
         * Android `AnalyzeUrl.getStrResponseAwait(jsStr, sourceRegex)` 的两个规则级参数：
         * URL 选项里没有对应值时用它们兜底（Android 是 `webJs ?: jsStr`）。
         */
        webJsOverride: String? = null,
        sourceRegexOverride: String? = null,
        /**
         * Android `AnalyzeUrl.getStrResponseAwait` 走的是表单编码 POST；`java.post`
         * （`JsExtensions.post`）改用 OkHttp 的 `postJson`，不做表单编码。false 时按
         * Android `postJson` 语义处理 body 与 Content-Type。
         */
        formEncodeBody: Boolean = true,
    ): FetchedResponse {
        val (cleanUrl, parsedOptions) = if (options != null) url to options else splitUrlOptions(url)
        val jsOptions = if (callTimeoutMillis != null) {
            (parsedOptions ?: UrlOptions()).copy(timeoutMillis = callTimeoutMillis)
        } else {
            parsedOptions
        }
        val db = database ?: this.database
        val effectiveOptions = if (source != null) mergeOptions(parseSourceHeaders(source, sourceId), jsOptions) else jsOptions ?: UrlOptions()
        // Android AnalyzeUrl：`javaScript = webJs ?: jsStr`（URL 选项优先，规则字段兜底），
        // 但**是否走 WebView 只由 URL 选项 useWebView 决定**——规则里的 webJs 不能自己开启浏览器通道，
        // 否则「规则带 webJs、但请求并不需要浏览器」的书源会被迫走 Chromium。
        val browserWebJs = effectiveOptions.webJs.ifBlank { webJsOverride.orEmpty() }
        val browserSourceRegex = effectiveOptions.sourceRegex.ifBlank { sourceRegexOverride.orEmpty() }
        val requestTimeout = effectiveCallTimeout(effectiveOptions)
        val sourceCookieJarEnabled = source?.let { parsedSource ->
            (parsedSource["enabledCookieJar"] as? JsonPrimitive)?.let { value ->
                if (value.isString) value.content.lowercase() != "false" else value.content == "true"
            }
        }
        val saveAutomaticCookies = source == null || sourceCookieJarEnabled == true
        val hexTypedRequest = effectiveOptions.type != null
        dataUrlPayload(cleanUrl)?.let { payload ->
            // Android `getStrResponseAwait` 的 `type != null` 分支：`StrResponse(url, HexUtil.encodeHexStr(bytes))`。
            val body = if (hexTypedRequest) hexEncodeBytes(payload.toByteArray(Charsets.UTF_8)) else payload
            return FetchedResponse(cleanUrl, body, 200, emptyMap())
        }
        val execContext = source?.let { sourceContext(it, sourceId, book) }
        var requestUrl = renderTemplate(cleanUrl, keyword, page, cleanUrl, execContext)
        val bodyJsBaseUrl = if (
            requestUrl.startsWith("http://", ignoreCase = true) ||
            requestUrl.startsWith("https://", ignoreCase = true)
        ) {
            requestUrl.indexOf('/', 9).takeIf { it >= 0 }?.let { requestUrl.substring(0, it) } ?: requestUrl
        } else {
            requestUrl
        }
        if (effectiveOptions.js.isNotBlank()) {
            requestUrl = jsSandbox.eval(effectiveOptions.js, mapOf("baseUrl" to cleanUrl, "key" to keyword, "page" to page, "result" to requestUrl), execContext)
                ?.trim()?.takeUnless { it.isBlank() }
                ?: throw RuleExecutionException("URL 选项 js 计算失败：${execContext?.lastError ?: "脚本无返回值"}")
        }
        var method = effectiveOptions.method.ifBlank { "GET" }.uppercase()
        if (method !in listOf("GET", "POST", "HEAD")) throw RuleExecutionException("不支持的请求方法: $method")
        var requestBody: String? = effectiveOptions.body?.let {
            renderTemplate(
                it,
                keyword,
                page,
                requestUrl,
                execContext,
                requestUrl,
                encodeKeyword = false,
                replacePageAlternatives = false,
            )
        }
        val formContentTypeSupplied = effectiveOptions.headers.entries.any {
            it.key.equals("Content-Type", ignoreCase = true) && it.value.isNotEmpty()
        }
        val postPlan = planPostBody(
            method = method,
            body = requestBody,
            charset = effectiveOptions.charset,
            charsetName = effectiveOptions.charsetName,
            contentTypeSupplied = formContentTypeSupplied,
            formEncodeBody = formEncodeBody,
        )
        requestBody = postPlan.body
        val defaultPostContentType = postPlan.defaultContentType
        if (!hexTypedRequest && effectiveOptions.useWebView) {
            val runtime = browserRuntime ?: throw RuleExecutionException("该书源需要浏览器环境，但服务端浏览器运行时未启用")
            val browserResult = runtime.webViewSnapshot(
                sourceId = sourceId ?: requestUrl,
                url = requestUrl,
                js = browserWebJs.ifBlank { null },
                headers = effectiveOptions.headers,
                sourceRegex = browserSourceRegex.takeIf { it.isNotBlank() },
            )
            return FetchedResponse(browserResult.url, browserResult.body, browserResult.status, browserResult.headers)
        }
        applyConcurrentRateLimit(source, sourceId)
        var current = parseUri(requestUrl)
        var redirects = 0
        val retryCount = effectiveOptions.retry ?: 0
        if (retryCount < 0) throw RuleExecutionException("retry 不能为负数")
        while (true) {
            validateTarget(current)
            val headers = LinkedHashMap<String, List<String>>()
            effectiveOptions.headers.forEach { (name, value) -> if (value.isNotBlank()) headers[name] = listOf(value) }
            val jarCookie = db?.getSourceCookie(sourceId.orEmpty(), current.toString())
            val explicitCookie = effectiveOptions.headers.entries.firstOrNull { it.key.equals("Cookie", true) }?.value
            val cookies = listOfNotNull(explicitCookie, jarCookie).filter { it.isNotBlank() }.distinct()
            if (cookies.isNotEmpty()) headers["Cookie"] = cookies
            defaultPostContentType?.let { contentType ->
                headers["Content-Type"] = listOf(contentType)
            }
            lateinit var response: SourceHttpResponse
            var statusAttempt = 0
            while (true) {
                response = try {
                    sendOnce(
                        buildRequest(current, method, headers, requestBody, effectiveOptions),
                        retainRedirectBody = firstResponseOnly,
                        hostnamePolicy = hostnamePolicy,
                    )
                } catch (error: java.io.IOException) {
                    val hasLoginCheckJs =
                        (source?.get("loginCheckJs") as? JsonPrimitive)?.contentOrNull?.trim()?.isNotEmpty() == true
                    if (hasLoginCheckJs) {
                        checkSourceLogin(
                            source,
                            FetchedResponse(
                                url = current.toString(),
                                body = error.message.orEmpty(),
                                status = 500,
                                headers = emptyMap(),
                            ),
                            execContext,
                            error.message ?: "请求失败",
                        )?.let { return it }
                    }
                    throw error
                }
                val isRetryableStatus = response.status !in 200..299 && response.status !in 300..399
                if (isRetryableStatus && statusAttempt < retryCount) {
                    statusAttempt++
                    continue
                }
                break
            }
            val contentType = response.headers.entries.firstOrNull { it.key.equals("content-type", true) }?.value?.joinToString(", ").orEmpty()
            val contentEncoding = response.headers.entries.firstOrNull { it.key.equals("content-encoding", true) }?.value?.joinToString(", ").orEmpty()
            val decompressedBytes = decompressBody(response.bytes, contentEncoding)
            val charset = resolveCharset(decompressedBytes, contentType)
            // Android 的 `type != null` 分支先返回：body 是**未解码字节的小写十六进制**
            // （`HexUtil.encodeHexStr`），不套 charset、XML 前缀与 bodyJs。
            val body = if (hexTypedRequest) {
                hexEncodeBytes(decompressedBytes)
            } else {
                decompressedBytes.toString(sourceResponseCharset(charset))
            }
            if (firstResponseOnly) {
                val setCookies = response.headers.filterKeys { it.equals("set-cookie", true) }.values.flatten()
                if (setCookies.isNotEmpty() && db != null && !sourceId.isNullOrBlank() && saveAutomaticCookies) {
                    setCookies.forEach { db.setSourceCookieFromSetCookie(sourceId, current.toString(), it) }
                }
                return FetchedResponse(response.finalUrl.toString(), body, response.status, response.headers)
            }
            val responseContentTypeRegex = Regex("""(application|text)/\w*\+?xml.*""")
            val responseString = when {
                hexTypedRequest -> body
                response.status in 300..399 -> body
                contentType.matches(responseContentTypeRegex) && !body.trim().startsWith("<?xml", true) -> {
                    """<?xml version="1.0"?>""" + body
                }
                effectiveOptions.bodyJs.isNotBlank() -> {
                    val transformed = jsSandbox.evalBodyJsCompletion(
                        effectiveOptions.bodyJs,
                        mapOf("baseUrl" to bodyJsBaseUrl, "key" to keyword, "page" to page, "result" to body),
                        execContext,
                    )
                    if (execContext?.lastError != null || (execContext == null && jsSandbox.lastError != null)) {
                        throw RuleExecutionException("bodyJs 计算失败：${execContext?.lastError ?: jsSandbox.lastError ?: "脚本无返回值"}")
                    }
                    if (transformed == null || transformed == Context.getUndefinedValue()) "null" else transformed.toString()
                }
                else -> body
            }
            val fetched = checkSourceLogin(
                source,
                FetchedResponse(
                    response.finalUrl.toString(),
                    responseString,
                    response.status,
                    response.headers,
                ),
                execContext,
                "上游返回 HTTP ${response.status}",
            ) ?: continue
            if (fetched.raw != null) return fetched
            val setCookies = response.headers.filterKeys { it.equals("set-cookie", true) }.values.flatten()
            if (setCookies.isNotEmpty() && db != null && !sourceId.isNullOrBlank() && saveAutomaticCookies) {
                setCookies.forEach { db.setSourceCookieFromSetCookie(sourceId, current.toString(), it) }
            }
            if (response.status in 300..399) {
                val location = response.headers.entries.firstOrNull { it.key.equals("location", true) }?.value?.firstOrNull()
                    ?: throw RuleExecutionException("重定向缺少 Location")
                redirects++
                if (redirects > MAX_REDIRECTS) throw RuleExecutionException("重定向次数超过限制")
                if (response.status == 301 || response.status == 302 || response.status == 303) {
                    method = "GET"
                    requestBody = null
                }
                current = current.resolve(location)
                continue
            }
            return fetched
        }
    }

    /**
     * 二进制抓取：Android `AnalyzeUrl.getByteArray()` / `JsExtensions.downloadFile` 的等价物。
     *
     * 与 [fetchResponse] 共用 URL 选项、模板渲染、Cookie jar、重定向与重试语义，
     * 唯一区别是**不做字符集解码**（压缩包、字体、图片必须拿到原始字节）。
     */
    internal fun fetchBytes(
        url: String,
        keyword: String? = null,
        page: Int? = null,
        sourceId: String? = null,
        source: JsonObject? = null,
        book: BookContext? = null,
        options: UrlOptions? = null,
        database: Database? = null,
        callTimeoutMillis: Long? = null,
        hostnamePolicy: SourceHostnamePolicy = SourceHostnamePolicy.ANDROID_OKHTTP,
    ): ByteArray {
        val (cleanUrl, parsedOptions) = if (options != null) url to options else splitUrlOptions(url)
        val jsOptions = if (callTimeoutMillis != null) {
            (parsedOptions ?: UrlOptions()).copy(timeoutMillis = callTimeoutMillis)
        } else {
            parsedOptions
        }
        val db = database ?: this.database
        val effectiveOptions = if (source != null) mergeOptions(parseSourceHeaders(source, sourceId), jsOptions) else jsOptions ?: UrlOptions()
        val execContext = source?.let { sourceContext(it, sourceId, book) }
        dataUrlPayload(cleanUrl)?.let { payload -> return payload.toByteArray(Charsets.UTF_8) }
        var requestUrl = renderTemplate(cleanUrl, keyword, page, cleanUrl, execContext)
        if (effectiveOptions.js.isNotBlank()) {
            requestUrl = jsSandbox.eval(
                effectiveOptions.js,
                mapOf("baseUrl" to cleanUrl, "key" to keyword, "page" to page, "result" to requestUrl),
                execContext,
            )?.trim()?.takeUnless { it.isBlank() }
                ?: throw RuleExecutionException("URL 选项 js 计算失败：${execContext?.lastError ?: "脚本无返回值"}")
        }
        var method = effectiveOptions.method.ifBlank { "GET" }.uppercase()
        if (method !in listOf("GET", "POST", "HEAD")) throw RuleExecutionException("不支持的请求方法: $method")
        var requestBody: String? = effectiveOptions.body?.let {
            renderTemplate(it, keyword, page, cleanUrl, execContext, keywordCharset = effectiveOptions.charset)
        }
        val formContentTypeSupplied = effectiveOptions.headers.entries.any {
            it.key.equals("Content-Type", ignoreCase = true) && it.value.isNotEmpty()
        }
        // 与 [fetchResponse] 同一套 Android POST 语义（表单编码 + Content-Type 兜底）。
        val postPlan = planPostBody(
            method = method,
            body = requestBody,
            charset = effectiveOptions.charset,
            charsetName = effectiveOptions.charsetName,
            contentTypeSupplied = formContentTypeSupplied,
            formEncodeBody = true,
        )
        requestBody = postPlan.body
        val defaultPostContentType = postPlan.defaultContentType
        applyConcurrentRateLimit(source, sourceId)
        var current = parseUri(requestUrl)
        var redirects = 0
        val retryCount = effectiveOptions.retry ?: 0
        if (retryCount < 0) throw RuleExecutionException("retry 不能为负数")
        while (true) {
            validateTarget(current)
            val headers = LinkedHashMap<String, List<String>>()
            effectiveOptions.headers.forEach { (name, value) -> if (value.isNotBlank()) headers[name] = listOf(value) }
            val jarCookie = db?.getSourceCookie(sourceId.orEmpty(), current.toString())
            val explicitCookie = effectiveOptions.headers.entries.firstOrNull { it.key.equals("Cookie", true) }?.value
            val cookies = listOfNotNull(explicitCookie, jarCookie).filter { it.isNotBlank() }.distinct()
            if (cookies.isNotEmpty()) headers["Cookie"] = cookies
            defaultPostContentType?.let { contentType ->
                headers["Content-Type"] = listOf(contentType)
            }
            var response: SourceHttpResponse
            var statusAttempt = 0
            while (true) {
                response = sendOnce(buildRequest(current, method, headers, requestBody, effectiveOptions), hostnamePolicy = hostnamePolicy)
                if (response.status !in 200..299 && response.status !in 300..399 && statusAttempt < retryCount) {
                    statusAttempt++
                    continue
                }
                break
            }
            val contentEncoding = response.headers.entries
                .firstOrNull { it.key.equals("content-encoding", true) }?.value?.joinToString(", ").orEmpty()
            val bytes = decompressBody(response.bytes, contentEncoding)
            require(bytes.size <= MAX_BINARY_BYTES) { "上游响应超过二进制抓取上限 32 MiB" }
            val setCookies = response.headers.filterKeys { it.equals("set-cookie", true) }.values.flatten()
            if (setCookies.isNotEmpty() && db != null && !sourceId.isNullOrBlank()) {
                setCookies.forEach { db.setSourceCookieFromSetCookie(sourceId, current.toString(), it) }
            }
            if (response.status in 300..399) {
                val location = response.headers.entries.firstOrNull { it.key.equals("location", true) }?.value?.firstOrNull()
                    ?: throw RuleExecutionException("重定向缺少 Location")
                redirects++
                if (redirects > MAX_REDIRECTS) throw RuleExecutionException("重定向次数超过限制")
                if (response.status == 301 || response.status == 302 || response.status == 303) {
                    method = "GET"
                    requestBody = null
                }
                current = current.resolve(location)
                continue
            }
            return bytes
        }
    }

    /**
     * Android `AnalyzeUrl.getStrResponseAwait` 的并发率闸门：按书源 `concurrentRate`
     * 在发请求前排队。key 用书源地址（Android 用 `source.getKey()`），拿不到书源定义时不过闸。
     */
    private fun applyConcurrentRateLimit(source: JsonObject?, sourceId: String?) {
        val key = source?.string("bookSourceUrl")?.takeIf { it.isNotBlank() } ?: sourceId?.takeIf { it.isNotBlank() } ?: return
        SourceRateLimiter.acquire(key, source?.string("concurrentRate"))
    }

    internal fun sendOnce(
        request: Request,
        retainRedirectBody: Boolean = false,
        hostnamePolicy: SourceHostnamePolicy = SourceHostnamePolicy.ANDROID_OKHTTP,
    ): SourceHttpResponse {
        val baseClient = when (hostnamePolicy) {
            SourceHostnamePolicy.ANDROID_OKHTTP -> client
            SourceHostnamePolicy.ANDROID_JSOUP -> jsoupClient
        }
        val callTimeout = request.tag(SourceCallTimeout::class.java)?.timeout
        val sourceClient = baseClient.newBuilder()
            .callTimeout(callTimeout?.toMillis() ?: 0L, TimeUnit.MILLISECONDS)
            .build()
        sourceClient.newCall(request).execute().use { response ->
            val status = response.code
            val allHeaders = response.headers.toMultimap()
            val finalUrl = response.request.url.toUri()
            if (status in 300..399 && !retainRedirectBody) {
                return SourceHttpResponse(status, allHeaders, ByteArray(0), finalUrl)
            }
            val bytes = response.body.byteStream().use(::readLimited)
            return SourceHttpResponse(status, allHeaders, bytes, finalUrl)
        }
    }

    private fun checkSourceLogin(
        source: JsonObject?,
        response: FetchedResponse,
        context: JsExecutionContext?,
        fallbackError: String,
    ): FetchedResponse? {
        if (source == null) {
            return response
        }
        val result = responseLogin.prepare(
            source.toString(),
            JsHttpResponse(response.url, response.body, response.status, fallbackError, response.headers, response.raw),
            context,
        )
        val checked = result.response ?: throw RuleExecutionException(result.error ?: fallbackError)
        return FetchedResponse(checked.url, checked.body ?: "", checked.code, checked.headers)
    }

    internal fun buildRequest(
        target: URI,
        method: String,
        headers: Map<String, List<String>>,
        body: String?,
        options: UrlOptions,
    ): Request {
        validateTarget(target)
        val requestTimeout = effectiveCallTimeout(options)
        val builder = Request.Builder()
            .url(target.toURL())
            .tag(SourceCallTimeout::class.java, SourceCallTimeout(requestTimeout))
        var hasUserAgent = false
        var hasAcceptEncoding = false
        var hasKeepAlive = false
        var hasConnection = false
        var hasCacheControl = false
        var contentType: MediaType? = null
        headers.forEach { (name, values) ->
            val value = values.lastOrNull()?.takeIf { it.isNotBlank() } ?: return@forEach
            builder.header(name, value)
            when (name.lowercase()) {
                "user-agent" -> hasUserAgent = true
                "accept-encoding" -> hasAcceptEncoding = true
                "keep-alive" -> hasKeepAlive = true
                "connection" -> hasConnection = true
                "cache-control" -> hasCacheControl = true
                "content-type" -> contentType = value.toMediaTypeOrNull()
            }
        }
        // Android BaseSource.getHeaderMap 默认 UA；HTTP 头仅 set 一项，绝不追加 LegadoServer/0.1。
        if (!hasUserAgent) builder.header("User-Agent", DEFAULT_USER_AGENT)
        if (!hasAcceptEncoding) builder.header("Accept-Encoding", "gzip, deflate")
        // Android okHttpClient 拦截器固定补上的连接头。
        if (!hasKeepAlive) builder.header("Keep-Alive", "300")
        if (!hasConnection) builder.header("Connection", "Keep-Alive")
        if (!hasCacheControl) builder.header("Cache-Control", "no-cache")
        val normalizedMethod = method.ifBlank { "GET" }.uppercase()
        if (normalizedMethod == "POST") {
            val bytes = (body ?: "").toByteArray(options.charset)
            builder.method(normalizedMethod, bytes.toRequestBody(contentType, 0, bytes.size))
        } else {
            builder.method(normalizedMethod, null)
        }
        return builder.build()
    }

    private fun effectiveCallTimeout(options: UrlOptions): Duration? {
        val timeoutMillis = options.timeoutMillis
        require(timeoutMillis == null || timeoutMillis >= 0) { "callTimeout 不能为负数" }
        return when {
            timeoutMillis == null -> Duration.ofSeconds(60)
            timeoutMillis == 0L -> null
            else -> Duration.ofMillis(timeoutMillis)
        }
    }

    private fun decompressBody(bytes: ByteArray, contentEncoding: String): ByteArray {
        val encoding = contentEncoding.lowercase()
        return when {
            encoding.contains("gzip") -> GZIPInputStream(bytes.inputStream()).use(::readBounded)
            encoding.contains("deflate") -> InflaterInputStream(bytes.inputStream()).use(::readBounded)
            else -> bytes
        }
    }

    /** 解压后的 body 同样受本地资源护栏限制，防止解压炸弹绕过 wire 边界。 */
    private fun readBounded(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return output.toByteArray()
            require(output.size() + count <= MAX_BODY_BYTES) { "上游响应超过本地资源上限 4 MiB" }
            output.write(buffer, 0, count)
        }
    }

    /** 字符集顺序：BOM → 源声明 charset → Content-Type → HTML meta 嗅探 → UTF-8。 */
    /**
     * Android `ResponseBody.text()`（`help/http/OkHttpUtils.kt:79`）的响应解码顺序：
     *
     * 1. `encode` 参数**始终为 null** —— URL 选项里的 `charset` 只参与请求的
     *    query/form 编码（`AnalyzeUrl.kt:295/299` 的 `analyzeFields`/`analyzeQuery`），
     *    不参与响应解码。此前服务端让选项 charset 优先，遇到「声明 `charset: gbk`
     *    但站点实际是 UTF-8」的书源会整页乱码 ⇒ 列表规则取不到任何条目；
     * 2. `Content-Type` 里的 charset；
     * 3. `EncodingDetect.getHtmlEncode(bytes)`：先看 `<head>` 里的
     *    `<meta charset>` / `http-equiv=Content-Type` 的 `content`；
     * 4. 都没有时 Android 走 icu4j 统计探测（`CharsetDetector`）。服务端没有该依赖，
     *    退化为「UTF-8 合法性判定，不合法按 GBK 处理」，覆盖中文站点主流情形。
     */
    private fun resolveCharset(bytes: ByteArray, contentType: String): Charset {
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) return Charsets.UTF_8
        if (bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()) return Charsets.UTF_16BE
        if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) return Charsets.UTF_16LE
        Regex("charset=[\"']?([\\w-]+)", RegexOption.IGNORE_CASE).find(contentType)
            ?.groupValues?.get(1)
            ?.let { declared -> runCatching { Charset.forName(declared) }.getOrNull() }
            ?.let { return it }
        detectHtmlCharset(bytes)?.let { return it }
        return if (isValidUtf8(bytes)) Charsets.UTF_8 else GBK_RESPONSE_CHARSET
    }

    /** Android `EncodingDetect.getHtmlEncode` 的 `<head>` meta 扫描（统计探测前的一步）。 */
    private fun detectHtmlCharset(bytes: ByteArray): Charset? = runCatching {
        val window = String(bytes, 0, minOf(bytes.size, HTML_CHARSET_SCAN_BYTES), Charsets.ISO_8859_1)
        val headStart = window.indexOf("<head", ignoreCase = true)
        val headEnd = if (headStart >= 0) window.indexOf("</head", headStart, ignoreCase = true) else -1
        val head = if (headStart >= 0 && headEnd > headStart) {
            window.substring(headStart, minOf(window.length, headEnd + "</head".length))
        } else {
            window
        }
        Jsoup.parseBodyFragment(head).select("meta").firstNotNullOfOrNull { metaTag ->
            metaTag.attr("charset").trim().takeIf { it.isNotEmpty() }
                ?: metaTag.attr("content").takeIf { metaTag.attr("http-equiv").equals("content-type", true) }
                    ?.let { content ->
                        val index = content.indexOf("charset=", ignoreCase = true)
                        (if (index >= 0) content.substring(index + "charset=".length) else content.substringAfter(';'))
                            .trim()
                            .trim('"', '\'')
                            .takeIf { it.isNotEmpty() }
                    }
        }?.let { name -> runCatching { Charset.forName(name) }.getOrNull() }
    }.getOrNull()

    /** 统计探测的退化实现：合法 UTF-8 才算 UTF-8，否则交给 GBK（Android 用 icu4j 探测）。 */
    private fun isValidUtf8(bytes: ByteArray): Boolean = runCatching {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
        true
    }.getOrDefault(false)

    private fun sourceResponseCharset(charset: Charset): Charset =
        if (charset.name() == "GBK") SOURCE_GBK_RESPONSE_CHARSET else charset

    private fun readLimited(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return output.toByteArray()
            require(output.size() + count <= MAX_BODY_BYTES) { "上游响应超过本地资源上限 4 MiB" }
            output.write(buffer, 0, count)
        }
    }

    private fun validateTarget(uri: URI) {
        try {
            NetworkSecurity.resolveAndValidateSafeHttpTarget(uri, "书源")
        } catch (e: IllegalArgumentException) {
            throw RuleExecutionException(e.message ?: "拒绝访问内网或本机地址")
        }
    }

    /**
     * Android AnalyzeUrl 兼容模板渲染：内嵌 JS（{{js}}/<js>）→ 关键字占位 →
     * 页码备选 `<a,b,c>` → {{page}}/{{source.*}}/cookie 变量。
     */
    internal fun renderTemplate(
        template: String,
        keyword: String? = null,
        page: Int? = null,
        baseUrl: String,
        execContext: JsExecutionContext? = null,
        result: Any? = null,
        keywordCharset: Charset = Charsets.UTF_8,
        encodeKeyword: Boolean = true,
        replacePageAlternatives: Boolean = true,
    ): String = renderTemplatePlaceholders(
        renderTemplateExpressions(template, keyword, page, baseUrl, execContext, result),
        keyword = keyword,
        page = page,
        baseUrl = baseUrl,
        keywordCharset = keywordCharset,
        encodeKeyword = encodeKeyword,
        replacePageAlternatives = replacePageAlternatives,
    )

    /**
     * 模板的第一段：`{{...}}` 与 `<js></js>` 的 JS 求值。
     *
     * 单独拆出来是**顺序问题**，不是代码洁癖：Android `AnalyzeUrl.initUrl()` 的顺序是
     * `analyzeJs()` → `replaceKeyPageJs()`（先替换内嵌 `{{...}}`）→ `analyzeUrl()`（再用
     * `,{` 拆 URL 与 URL 选项）。二者必须同序 —— 模板里的 JS 参数自己就带逗号
     * （虫虫书屋 `java.post(url, body, {})`），先按逗号拆会把 JS 拦腰截断，剩下的半截既
     * 求不了值也解析不成 URL（旧实现报「URL 解析失败: …q={{JSON.parse…」）。
     */
    private fun renderTemplateExpressions(
        template: String,
        keyword: String?,
        page: Int?,
        baseUrl: String,
        execContext: JsExecutionContext?,
        result: Any? = null,
    ): String {
        var rendered = template
        val bindings = templateBindings(keyword, page, baseUrl, result)
        rendered = Regex("\\{\\{(.*?)\\}\\}", RegexOption.DOT_MATCHES_ALL).replace(rendered) { match ->
            val code = match.groupValues[1].trim()
            // Android `AnalyzeUrl.replaceKeyPageJs`：`{{...}}` 一律当 JS 求值，`key`/`page`/
            // `baseUrl`/`source`/`cookie` 都是 evalJS 的绑定。只有后面会被**逐字替换**（关键字
            // 需要按 charset 编码）的那几个占位符必须保持原样：
            // `{{key}}`/`{{keyword}}`/`{{source.key}}` 交给 encodeKeywordValue，
            // `{{page}}` 交给下面的跳页替换，`{{source.bookSourceUrl}}` 交给末尾的 baseUrl 替换。
            val literalPlaceholder = code == "key" || code == "keyword" || code == "page" ||
                code == "source.key" || code == "source.bookSourceUrl"
            if (literalPlaceholder || execContext == null) match.value
            else jsSandbox.evalTemplateExpression(code, bindings, execContext) ?: match.value
        }
        rendered = Regex("<js>([\\s\\S]*?)</js>").replace(rendered) { match ->
            if (execContext == null) match.value
            else jsSandbox.eval(match.groupValues[1], bindings, execContext) ?: match.value
        }
        return rendered
    }

    /**
     * 模板的第二段：关键字占位 → 页码备选 `<a,b,c>` → `{{page}}`/`{{source.*}}`/cookie 变量。
     */
    private fun renderTemplatePlaceholders(
        renderedTemplate: String,
        keyword: String?,
        page: Int?,
        baseUrl: String,
        keywordCharset: Charset = Charsets.UTF_8,
        encodeKeyword: Boolean = true,
        replacePageAlternatives: Boolean = true,
    ): String {
        var rendered = renderedTemplate
        val encodedKeyword = encodeKeywordValue(keyword, keywordCharset, encodeKeyword)
        rendered = rendered
            .replace("{{key}}", encodedKeyword)
            .replace("{{keyword}}", encodedKeyword)
            .replace("<key>", encodedKeyword)
            .replace("{{source.key}}", encodedKeyword)
        if (page != null && replacePageAlternatives) {
            rendered = Regex("<(.*?)>").replace(rendered) { match ->
                val choices = match.groupValues[1].split(",").map { it.trim() }
                if (choices.isEmpty()) match.value
                else choices.getOrElse(page - 1) { choices.last() }
            }
            rendered = Regex("\\{\\{\\s*page\\s*\\}\\}").replace(rendered, page.toString())
        }
        return rendered
            .replace("{{source.bookSourceUrl}}", baseUrl)
            .replace("{{cookie.removeCookie(source.key)}}", "")
    }

    private fun templateBindings(keyword: String?, page: Int?, baseUrl: String, result: Any?): Map<String, Any?> = buildMap {
        put("key", keyword ?: "")
        put("keyword", keyword ?: "")
        page?.let { put("page", it) }
        put("baseUrl", baseUrl)
        put("sourceId", baseUrl)
        result?.let { put("result", it) }
    }

    /**
     * 搜索关键字在 URL 模板里的编码。
     *
     * Android：`AnalyzeUrl.evalJS` 把 `key` 原样交给模板，真正的编码发生在
     * `analyzeQuery` 里 —— 若渲染后的 query **整体已符合 URL 编码规范**（字符都属于
     * `notNeedEncodingQuery` 或 `%xx`），`NetworkUtils.encodedQuery` 返回 true，
     * 整段 query 原样送出；否则用 RFC3986 编码器把它编码成 `%xx`。
     *
     * 服务端只替换关键字这一个占位符，因此等价判定为：
     * - 模板里关键字占位符本身已被百分号编码（源作者预先编码过）⇒ 原样保留，不做二次编码；
     * - 否则按 RFC3986 编码（空格必须是 `%20`，绝不能是 `URLEncoder` 的 `+`，
     *   否则编码后的关键字到上游会变成字面量 `+`）。
     */
    private fun encodeKeywordValue(
        keyword: String?,
        charset: Charset,
        encodeKeyword: Boolean,
    ): String {
        if (keyword.isNullOrBlank()) return ""
        if (!encodeKeyword) return keyword
        return percentEncodeQueryValue(keyword, charset)
    }

    /**
     * Android `AnalyzeUrl.queryEncoder`（`RFC3986.UNRESERVED.orNew(PercentCodec.of(...))`）
     * 的等价实现：不在安全集里的字节一律 `%xx`，**空格编成 `%20`**（绝不是 `URLEncoder`
     * 的 `+`）。安全集本身包含 `%`，因此源作者预先写好的 `%E6%96%97` 不会被二次编码
     * —— 这正是 Android「已编码 query 原样透传」的实际效果。
     */
    private fun percentEncodeQueryValue(value: String, charset: Charset): String {
        val output = StringBuilder()
        for (byte in value.toByteArray(charset)) {
            val code = byte.toInt() and 0xFF
            if (code < 128 && QUERY_ENCODE_SAFE_CHARS.get(code)) {
                output.append(code.toChar())
            } else {
                output.append('%')
                output.append(HEX_DIGITS[code ushr 4])
                output.append(HEX_DIGITS[code and 0x0F])
            }
        }
        return output.toString()
    }

    private fun nodes(
        body: String,
        rule: String,
        baseUrl: String? = null,
        variables: MutableMap<String, String> = mutableMapOf(),
    ): List<NodeValue> =
        NodeValue.document(body).select(rule, jsSandbox, body, baseUrl, variables)

    /**
     * 把 Legado 的 `@` 链式选择器翻译成 CSS 选择器。
     *
     * 必须翻译的三类语法（缺一类就会**静默匹配 0 个元素**，表现为「目录 0 章」）：
     * 1. `id.xxx`   → `#xxx`      （旧实现直接透传，而 `id.list` 不是合法 CSS ⇒ 0 匹配）
     * 2. `tag.xxx`  → `xxx`       （旧实现只处理了后接 `.数字` 的形式，`tag.p` 会残留前缀）
     * 3. `xxx!0:1:2` → 排除多个下标（旧实现只认单个数字，多下标直接丢失排除语义）
     *
     * 兼容性示例：`id.list@dd!0:1:2:3:4:5:6:7:8` 若错误处理会产出 `id.list dd`，
     * Jsoup 匹配 **0** 个；正确应为 `#list dd`，匹配 **89** 个。
     */
    private fun String.css(): String {
        val clean = removePrefix("@css:").trim()
        val parts = clean.split("@")
        val cssParts = mutableListOf<String>()
        for (part in parts) {
            val trimmed = part.trim()
            if (trimmed.isEmpty()) continue
            if (trimmed in setOf("text", "href", "src", "content", "html", "textNodes", "textNode")) break
            if (trimmed.startsWith("attr(") || trimmed.startsWith("text(") || trimmed.startsWith("all")) break
            if ("!" in trimmed) {
                val (rawTag, notIndex) = trimmed.split("!", limit = 2)
                val tag = translateLegadoSelector(rawTag.trim())
                // `!0:1:2` —— 排除多个下标（Legado 用冒号分隔）；单个 `!0` 也要支持
                val excluded = notIndex.split(":").mapNotNull { it.trim().toIntOrNull() }.distinct()
                cssParts.add(
                    if (excluded.isEmpty()) tag
                    else excluded.joinToString("") { "$tag:not(:nth-child(${it + 1}))" }
                )
            } else if (trimmed.startsWith("class.")) {
                val cls = trimmed.removePrefix("class.")
                if ("." in cls) {
                    val (cName, idxStr) = cls.split(".", limit = 2)
                    val idx = idxStr.toIntOrNull()
                    if (idx != null) cssParts.add(".$cName:nth-of-type(${idx + 1})") else cssParts.add(".$cls")
                } else {
                    cssParts.add(".$cls")
                }
            } else if (trimmed.matches(Regex("^[a-zA-Z0-9-]+\\.\\d+$"))) {
                val (tag, idxStr) = trimmed.split(".", limit = 2)
                val idx = idxStr.toIntOrNull()
                if (idx != null) cssParts.add("$tag:nth-of-type(${idx + 1})") else cssParts.add(trimmed)
            } else {
                cssParts.add(translateLegadoSelector(trimmed))
            }
        }
        return if (cssParts.isEmpty()) clean else cssParts.joinToString(" ")
    }

    private fun translateLegadoSelector(selector: String): String = translateSelector(selector)
    /**
     * 正文清洗：先删除 script/style，再把 Android 的块级包装标签边界转成换行，
     * 保留其中的正文文本；随后剥离其余标签语法。不存在二次 fallback 路径。
     *
     * ## 正文插图（`<img>`）为什么必须先"摘走"再放回
     * 旧实现把所有标签一并剥掉 ⇒ **正文里的插图彻底消失**（用户报「添加书籍正文插图功能」）。
     * 但直接把 `<img …>` 留在待清洗文本里也不行：块级边界转换、`<[^>]+>` 剥离、
     * 实体反转义都会把它撕坏（属性里的 `onerror=…` 甚至会变成可见正文）。
     * 所以：先按 [IllustrationMarkup] 的判据把**安全的插图**换成独占一行的占位标记，
     * 文本清洗照旧跑，最后按行把占位标记换回**我们自己重建**的 `<img src="…" alt="…">`。
     *
     * 安全性由「重建」保证：只保留 `src`/`alt`（自转义），上游的 `on*`/`style`/`srcset`
     * 一个都进不来；`data:`/`javascript:` 之类非 http(s) 地址整条丢弃。
     *
     * @param baseUrl 章节页地址（相对/协议相对插图地址的补全基准）；聚合源 `data:` 载荷传 null
     */
    private fun String.cleanContent(baseUrl: String? = null): String {
        val illustrations = mutableListOf<String>()
        val masked = IllustrationMarkup.IMG_TAG.replace(this) { match ->
            val safe = IllustrationMarkup.safeTag(match.value, baseUrl)
            if (safe == null) {
                ""
            } else {
                illustrations += safe
                "\n${IllustrationMarkup.slotMarker(illustrations.size - 1)}\n"
            }
        }
        // 占位行独占一行 ⇒ 清洗完成后按行换回插图标签（占位标记里没有任何标签字符，不会被清洗吃掉）
        fun String.restoreIllustrations(): String {
            if (illustrations.isEmpty()) return this
            return this.lines()
                .map { line -> IllustrationMarkup.slotIndex(line)?.let { illustrations.getOrNull(it) } ?: line.trim() }
                .filter { it.isNotBlank() }
                .joinToString("\n\n")
        }
        val structuralTagsRemoved = masked
            .replace(Regex("(?i)<script[\\s\\S]*?</script>"), "")
            .replace(Regex("(?i)<style[\\s\\S]*?</style>"), "")
            .replace(Regex("(&nbsp;)+"), " ")
            .replace(Regex("(&ensp;|&emsp;)"), " ")
            .replace(Regex("(&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D)"), "")
            .replace(Regex("</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>"), "\n")
            .replace(Regex("<!--[^>]*-->"), "")
            .replace(Regex("</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>"), "")
            .replace(Regex("\\s*\\n+\\s*"), "\n　　")
            .replace(Regex("^[\\n\\s]+"), "　　")
            .replace(Regex("[\\n\\s]+$"), "")
            .let { org.jsoup.parser.Parser.unescapeEntities(it, false) }
            .lines().map { it.trim() }.filter { it.isNotBlank() }.joinToString("\n\n")
        return structuralTagsRemoved.restoreIllustrations()
    }
    private fun String.absolute(base: String, normalizeAndroidOptionSeparator: Boolean = false): String = try {
        val cleanBase = base.substringBefore(",").substringBefore("##").substringBefore("#").trim()
        if (startsWith("data:", true)) {
            this
        } else if (startsWith("javascript")) {
            // Android `NetworkUtils.getAbsoluteURL`：`javascript:void(0)` 这类**伪链接返回空串**，
            // 让调用方走「链接缺失」的兜底（否则会把伪协议当成真实地址去请求/落库）。
            ""
        } else if (cleanBase.startsWith("http://", ignoreCase = true) || cleanBase.startsWith("https://", ignoreCase = true)) {
            val separator = androidOptionSeparator.find(this)
            if (normalizeAndroidOptionSeparator && separator != null) {
                URI(cleanBase).resolve(substring(0, separator.range.first).trim()).toString() + "," + substring(separator.range.last + 1)
            } else {
                val (url, options) = SourceUrlOptions.split(this)
                val resolved = URI(cleanBase).resolve(url).toString()
                if (options != null) "$resolved${substring(url.length)}" else resolved
            }
        } else {
            this
        }
    } catch (_: Exception) { this }
    private fun String.objectValue(): JsonObject = json.parseToJsonElement(this).jsonObject
    private fun JsonObject.objectValue(key: String): JsonObject? = get(key)?.jsonObject
    private fun JsonObject.string(key: String): String? = (get(key) as? JsonPrimitive)?.contentOrNull

    /**
     * Android `AnalyzeUrl` 的 POST body / Content-Type 决议。
     *
     * Android `getStrResponse()` 的 POST 分支是：
     * ```
     * if (!encodedForm.isNullOrEmpty() || body.isNullOrBlank()) postForm(encodedForm ?: "")
     * else if (!contentType.isNullOrBlank()) post(body.toRequestBody(contentType.toMediaType()))
     * else postJson(body)
     * ```
     * 也就是：**没有显式 Content-Type 时，表单编码的 body 用 form-urlencoded，
     * 其余 body（JSON / XML / 纯文本）一律 `application/json`**。
     * 旧实现把「非 JSON/XML 的 body」也当作表单发出去，`encoding == "json"` 形式
     * 的 URL 选项请求因此被上游拒掉。
     *
     * @param contentTypeSupplied 源 header / URL 选项里已显式给出 Content-Type
     * @param formEncodeBody `AnalyzeUrl.getStrResponseAwait` 为 true；
     *   `java.post`（Jsoup `requestBody(body)`）为 false，不做表单编码
     */
    internal fun planPostBody(
        method: String,
        body: String?,
        charset: Charset,
        charsetName: String?,
        contentTypeSupplied: Boolean,
        formEncodeBody: Boolean,
    ): PostBodyPlan {
        if (!method.equals("POST", ignoreCase = true)) return PostBodyPlan(body, null)
        val wantsForm = formEncodeBody &&
            !contentTypeSupplied &&
            (body == null || body.isBlank() || (!body.isJsonLike() && !body.isXmlLike()))
        return PostBodyPlan(
            body = if (wantsForm) encodeForm(body.orEmpty(), charset, charsetName) else body,
            defaultContentType = when {
                contentTypeSupplied -> null
                wantsForm -> FORM_CONTENT_TYPE
                else -> JSON_CONTENT_TYPE
            },
        )
    }

/**
 * POST body 决议结果：[body] 是最终要发出去的文本，
 * [defaultContentType] 非 null 表示请求头里需要补上的默认 Content-Type。
 */
internal data class PostBodyPlan(val body: String?, val defaultContentType: String?)

    private companion object {
        /**
         * Android `NetworkUtils.notNeedEncodingQuery`：query 里无需编码的字符集，
         * 用于「整段 query 是否已经编码」的快速判定（`%` 由 `%xx` 规则单独放行）。
         */
        val QUERY_ALREADY_ENCODED_CHARS = java.util.BitSet(256).also { bits ->
            for (code in 'a'.code..'z'.code) bits.set(code)
            for (code in 'A'.code..'Z'.code) bits.set(code)
            for (code in '0'.code..'9'.code) bits.set(code)
            for (char in "!$&()*+,-./:;=?@[\\]^_`{|}~") bits.set(char.code)
        }

        /**
         * Android `AnalyzeUrl.queryEncoder` 的安全集：
         * `RFC3986.UNRESERVED.orNew(PercentCodec.of("!$%&()*+,/:;=?@[\\]^`{|}"))`。
         * 比 [QUERY_ALREADY_ENCODED_CHARS] 多一个 `%`、少一个 `'`。
         */
        val QUERY_ENCODE_SAFE_CHARS = java.util.BitSet(256).also { bits ->
            for (code in 'a'.code..'z'.code) bits.set(code)
            for (code in 'A'.code..'Z'.code) bits.set(code)
            for (code in '0'.code..'9'.code) bits.set(code)
            for (char in "-._~!$%&()*+,/:;=?@[\\]^`{|}") bits.set(char.code)
        }

        /**
         * 对照 Android `NetworkUtils.encodedQuery`：整段文本是否已经是合法 query
         * （字符都属于 `notNeedEncodingQuery`，或 `%` 后跟两个十六进制位）。
         */
        fun isAlreadyQueryEncoded(value: String): Boolean {
            var index = 0
            while (index < value.length) {
                if (value[index].code < 256 && QUERY_ALREADY_ENCODED_CHARS.get(value[index].code)) {
                    index++
                    continue
                }
                if (value[index] == '%' && index + 2 < value.length &&
                    value[index + 1].isHexDigit() && value[index + 2].isHexDigit()
                ) {
                    index += 3
                    continue
                }
                return false
            }
            return true
        }

        private val HEX_DIGITS = "0123456789ABCDEF".toCharArray()

        const val MAX_BODY_BYTES = 4 * 1024 * 1024

        /**
         * 二进制抓取上限（压缩包/字体/图片）。
         *
         * 比文本上限宽：`getZipStringContent`、`queryTTF` 这类书源会整包下载十几 MB 的素材；
         * 但仍必须有界，避免单个书源把服务端内存吃穿。
         */
        const val MAX_BINARY_BYTES = 32 * 1024 * 1024

        /** jsLib 下载缓存有效期（Android ACache 默认 4 小时，这里取同一量级）。 */
        const val JS_LIB_CACHE_TTL_MS = 4 * 60 * 60 * 1000L

        /** jsLib 下载失败后的负缓存时间：避免坏源把每次规则求值都变成一次超时等待。 */
        const val JS_LIB_FAILURE_TTL_MS = 60 * 1000L

        /** jsLib 文件缓存条数上限（Android 作用域 LruCache 为 16，文件缓存另计）。 */
        const val JS_LIB_CACHE_MAX_ENTRIES = 64

        /**
         * 正文分页上限。
         *
         * Android `BookContent.analyzeContent` 只按「下一页地址为空或已访问过」终止，没有页数上限，
         * 因此这里只作为防环之外的最后一道兜底，且**命中上限时保留已抓到的正文**而不是报错：
         * 真实站点整章几十页很常见（实测 `新御宅屋②`/`肉肉屋⑥` 单章 23 页），
         * 直接抛错会把本来能用的正文整段丢掉。
         */
        const val MAX_PAGED_URLS = 200
        const val MAX_LIST_ITEMS = 20000
        const val MAX_REDIRECTS = 10

        /** Android `BookSourceType.file`：只提供下载服务的书源，详情只取 `ruleBookInfo.downloadUrls`。 */
        const val WEB_FILE_SOURCE_TYPE = 3

        /** Android `Book.imgStyleFull`：图片书源没声明 `ruleContent.imageStyle` 时的默认排版。 */
        const val IMAGE_BOOK_DEFAULT_IMAGE_STYLE = "FULL"

        /** Android 默认桌面 Chrome UA（严格对照 getHeaderMap 默认值）；源 header 可覆写，仅 set 单项。 */
        const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

        const val FORM_CONTENT_TYPE = "application/x-www-form-urlencoded"
        /** Android `AnalyzeUrl` POST 默认 media type（`postJson`）。 */
        const val JSON_CONTENT_TYPE = "application/json"

        /** 书源脚本在 startBrowserAwait 之后自报「读不到设置结果」的文案标记（无头端必然触发，属误报）。 */
        const val NO_SETTINGS_RESULT_MARKER = "未读取到设置结果"

        /** 替代误报的如实提示：改动由内置浏览器回传通道自动保存。 */
        const val INLINE_BROWSER_SAVE_HINT = "设置中心已在内置浏览器中打开，改动会自动保存"
    }
}

private class JsSourceRunner(
    private val runner: RuleRunner,
    private val source: JsonObject,
) {
    private val script = source.string("mainJs") ?: error("mainJs 缺失")

    fun search(keyword: String): List<SearchResult> {
        try {
            val rawItems = call("search", arrayOf(keyword, 1)).jsonArray()
            val results = rawItems.mapNotNull { value ->
                val book = Json.parseToJsonElement(value).jsonObject
                val url = book.string("bookUrl") ?: return@mapNotNull null
                val name = book.string("name") ?: return@mapNotNull null
                SearchResult(
                    sourceId = source.string("bookSourceUrl")!!,
                    name = name,
                    author = book.string("author"),
                    bookUrl = url,
                    coverUrl = book.string("coverUrl"),
                    intro = book.string("intro"),
                    bookKind = resolveBookKind(source, url),
                )
            }
            return results
        } catch (error: Throwable) {
            throw error
        }
    }
    fun details(bookUrl: String, book: BookContext? = null): BookDetails {
        val value = callOptional("getBookInfo", arrayOf(bookObject(bookUrl, book)))?.jsonObjectOrEmpty() ?: JsonObject(emptyMap())
        val name = sanitizeBookName(value.string("name"))
        return BookDetails(
            sourceId = source.string("bookSourceUrl")!!,
            name = name.ifBlank { "未命名书籍" },
            author = value.string("author"),
            intro = value.string("intro"),
            coverUrl = value.string("coverUrl"),
            tocUrl = value.string("tocUrl") ?: bookUrl,
            bookKind = resolveBookKind(source, bookUrl, book),
        )
    }
    fun chapters(tocUrl: String, book: BookContext? = null): List<Chapter> = call("getChapters", arrayOf(bookObject(tocUrl, book))).jsonArray().mapIndexedNotNull { index, value ->
        val chapter = Json.parseToJsonElement(value).jsonObject; val url = chapter.string("url") ?: return@mapIndexedNotNull null; Chapter(index, chapter.string("title") ?: "第 ${index + 1} 章", url)
    }
    fun content(chapterUrl: String, book: BookContext? = null): ChapterContent = ChapterContent(content = call("getContent", arrayOf(chapterObject(chapterUrl), bookObject("", book), null)).trim().also { if (it.isBlank()) throw RuleExecutionException("JS书源正文为空") })

    private fun call(name: String, args: Array<Any?>): String = callOptional(name, args) ?: throw RuleExecutionException("JS书源缺少函数 $name")
    private fun callOptional(name: String, args: Array<Any?>): String? {
        val context = Context.enter()
        try {
            context.optimizationLevel = -1; context.setClassShutter(ClassShutter { false })
            val scope = context.initSafeStandardObjects()
            ScriptableObject.putProperty(scope, "java", ajaxFunction(scope))
            context.evaluateString(scope, script, "source.js", 1, null)
            val function = ScriptableObject.getProperty(scope, name) as? Function ?: return null
            val raw = function.call(context, scope, scope, args.map { toJsValue(it, scope) }.toTypedArray())
            if (raw == null || raw == Context.getUndefinedValue()) return null
            if (raw is CharSequence) return raw.toString()
            return NativeJSON.stringify(context, scope, raw, null, null).toString()
        } catch (error: RuleExecutionException) { throw error }
        catch (error: Exception) { throw RuleExecutionException("JS书源 $name 执行失败: ${error.message}") }
        finally { Context.exit() }
    }
    private fun ajaxFunction(scope: Scriptable): NativeObject = NativeObject().also { api ->
        api.parentScope = scope
        ScriptableObject.putProperty(api, "ajax", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: throw RuleExecutionException("ajax 缺少 URL")
                // 同 JsSandbox.jsBridge：受检异常直接冒泡会触发 Rhino 的 (Error) 强转 CCE，
                // 掩盖真实原因并击穿书源自身的 try/catch 容错。
                return try {
                    runner.fetch(url)
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        })
    }
    private fun toJsValue(value: Any?, scope: Scriptable): Any? = when (value) {
        is Map<*, *> -> NativeObject().also { objectValue ->
            objectValue.parentScope = scope
            value.forEach { (key, item) -> if (key is String) ScriptableObject.putProperty(objectValue, key, toJsValue(item, scope)) }
        }
        is List<*> -> Context.getCurrentContext().newArray(scope, value.map { toJsValue(it, scope) }.toTypedArray())
        else -> Context.javaToJS(value, scope)
    }
    /**
     * JS 书源（`mainJs`）看到的 `book` 对象。
     *
     * 与声明式书源的沙箱 `book` 桥接保持**同一份字段**（含 `variable` 变量表 JSON 与 `name/author/kind`），
     * 否则同一本书在两种书源形态下行为不一致 —— 这类"只在某一条路径生效"的差异最难排查。
     */
    private fun bookObject(url: String, book: BookContext? = null): Map<String, Any?> = mapOf(
        "bookUrl" to url,
        "tocUrl" to url,
        "name" to (book?.name ?: ""),
        "author" to (book?.author ?: ""),
        "kind" to (book?.kind ?: ""),
        "type" to (book?.numericType ?: 0),
        "variable" to (book?.variables?.takeIf { it.isNotEmpty() }?.let { Json.encodeToString(it) } ?: ""),
        "variableMap" to (book?.variables ?: emptyMap<String, String>()),
    )
    private fun chapterObject(url: String) = mapOf("url" to url)
    private fun String.jsonArray(): List<String> = (Json.parseToJsonElement(this) as? JsonArray)?.map { it.toString() } ?: throw RuleExecutionException("JS书源返回值必须是数组")
    private fun String.jsonObjectOrEmpty(): JsonObject = runCatching { Json.parseToJsonElement(this).jsonObject }.getOrDefault(JsonObject(emptyMap()))
    private fun JsonObject.string(key: String): String? = (get(key) as? JsonPrimitive)?.contentOrNull
}


/**
 * 清洗书名。
 *
 * 兼容性示例：某书源的书架条目名是
 * `"十日终焉我成魔\n第八十章 星尘归寂，余念长存"` ——
 * 目录页的规则把「最新章节标题」一并取进了书名（`id.info@h1@text` 命中了包含
 * 章节信息的标题块），导致书架显示成两行、且「书名」里混入章节名。
 *
 * 清洗策略（保守，避免误伤合法书名）：
 * 1. 仅取第一行（换行后的内容一律丢弃）；
 * 2. 折叠内部连续空白；
 * 3. 去掉首尾书名号/引号等包裹符。
 *
 * **刻意不做**「按"第X章"截断」——那会误伤本身就叫《第X章》之类的书名。
 */
internal fun sanitizeBookName(raw: String?): String {
    val text = raw ?: return ""
    // 取第一行
    val firstLine = text.lineSequence().firstOrNull { it.isNotBlank() } ?: return ""
    return firstLine
        .replace(Regex("\\s+"), " ")
        .trim()
        .trim('《', '》', '"', '"', '\'', '「', '」')
        .trim()
}

/**
 * Android `BookHelp.formatBookName`：先去掉「作者×××」/「××× 著」尾巴，再按空白裁剪。
 *
 * 与 [sanitizeBookName] 的区别是**语义来源**：本函数用于书源规则提取结果的格式化，
 * 必须与 Android 逐字一致（搜索结果的同名合并、详情页取名都依赖它）；
 * [sanitizeBookName] 用于写入书架时的清洗，行为保持不变。
 */
internal fun formatBookName(raw: String?): String =
    (raw ?: "").replace(Regex("\\s+作\\s*者.*|\\s+\\S+\\s+著"), "").trim { it <= ' ' }

/** Android `BookHelp.formatBookAuthor`：去掉「作者：」前缀与「著」标记。 */
internal fun formatBookAuthor(raw: String?): String =
    (raw ?: "").replace(Regex("^\\s*作\\s*者[:：\\s]+|\\s+著"), "").trim { it <= ' ' }

/**
 * Android `BookInfo` 的简介处理：`<usehtml>`/`<md>`/`<useweb>` 前缀表示
 * 「这段简介本身就是要渲染的标记」，原样保留；其余一律 [HtmlFormatter.format] 成纯文本。
 */
internal fun formatBookIntro(raw: String?): String? {
    if (raw == null) return null
    val trimmedStart = raw.trimStart()
    if (trimmedStart.startsWith("<usehtml>") || trimmedStart.startsWith("<md>") || trimmedStart.startsWith("<useweb>")) {
        return trimmedStart
    }
    return HtmlFormatter.format(raw).takeIf { it.isNotEmpty() }
}

/**
 * Android `BookList.getSearchItem` 的简介处理：**总是**走 [HtmlFormatter.format]。
 *
 * 与详情页的 [formatBookIntro] 不同 —— `<usehtml>`/`<md>` 前缀透传只发生在
 * `BookInfo.analyzeBookInfo`，搜索/发现结果一律格式化成纯文本。
 */
internal fun formatSearchIntro(raw: String?): String? {
    if (raw == null) return null
    return HtmlFormatter.format(raw).takeIf { it.isNotEmpty() }
}

/**
 * Android `StringUtils.wordCountFormat(wc)`：纯数字才换算，`> 10000` 用一位小数 + 万字，
 * 其余原样返回（非数字内容不动，可能是「连载中」这类文案）。
 */
internal fun formatWordCount(raw: String?): String? {
    if (raw == null) return null
    val words = raw.toIntOrNull() ?: return raw
    if (words <= 0) return ""
    if (words > 10000) {
        // Android `DecimalFormat("#.#")`：最多一位小数、去掉末尾 0（20000 => "2"），
        // 且用 float 参与换算（`words * 1.0f / 10000f`）。
        val formatter = java.text.DecimalFormat("#.#", java.text.DecimalFormatSymbols(java.util.Locale.US))
        return formatter.format(words * 1.0f / 10000f.toDouble()) + "万字"
    }
    return words.toString() + "字"
}

/**
 * 把 Java 侧抛出的异常规范化为**脚本可见、可被 `catch(e)` 捕获**的 JS 错误。
 *
 * ## 背景
 * Rhino 在处理「逃逸出脚本的 Java 异常」时假定它是 `java.lang.Error` 系，
 * 会对**受检异常**执行 `(Error)` 强制转换。Kotlin 没有受检异常，桥接函数
 * 会把 `SSLHandshakeException` 这类受检异常原样放行，于是 Rhino 抛出：
 *
 * ```
 * class javax.net.ssl.SSLHandshakeException cannot be cast to class java.lang.Error
 * ```
 *
 * ## 危害（三层，均非「报错难看」）
 * 1. 真实原因（证书/握手/超时）被 `ClassCastException` 完全掩盖；
 * 2. 该 CCE 在 JS 引擎内部抛出，**书源自己的 `try{...}catch(e){}` 抓不到**，
 *    聚合源赖以容错的多节点轮询与主备线路回退被整体击穿；
 * 3. 前端只能显示这行天书，用户无从判断真实原因。
 *
 * ## 实测结论（Rhino 1.8.0，生产沙箱设置 `initSafeStandardObjects` + `ClassShutter{false}`）
 * | 抛出形式 | 可被 JS catch | `e.name` | 错误消息 |
 * | :--- | :--- | :--- | :--- |
 * | 受检异常直接冒泡 | ❌ 抛 CCE | — | — |
 * | `RuntimeException` / `Error` 包装 | ❌ 仍漏过 | — | — |
 * | `Context.throwAsScriptRuntimeEx` | ✅ | `InternalError` | **丢失真实类型名** |
 * | **`ScriptRuntime.constructError`** | ✅ | `Error` | ✅ 保留真实类型名 |
 *
 * 因此采用 `constructError`：既恢复书源容错，又让消息自解释。
 *
 * ## 业务语义异常（RuleExecutionException）同样包裹
 * Android 侧这些异常都来自 Java 方法调用：Rhino 的 `MemberBox` 会把
 * `InvocationTargetException` 包装成 `WrappedException`（RhinoException），
 * 因此书源里的 `try{ java.getString(...) }catch(e){...}` 能捕获到它。服务端桥接是
 * native 函数，异常原样抛出会直接穿过解释器（实测 `java.getString('<js>坏脚本</js>')`
 * 写在 try/catch 里依然整条失败），必须自己转成 JS 错误才与 Android 一致。
 *
 * 未被捕获时行为不变：消息照样冒泡到路由层转成 502「source_execution_failed」提示；
 * `RuleExecutionException` 的文案本身就是给人看的中文提示，因此不再加类名前缀。
 */
internal fun normalizeScriptThrowable(error: Throwable): Nothing {
    // 全部归一成 Rhino 错误（`EcmaError`）：Android 侧这些异常都来自 Java 方法调用，
    // Rhino 的 `MemberBox` 会把它们包装成 `WrappedException`（RhinoException），因此
    // 书源的 `try { java.getString(...) } catch (e) { ... }` 能捕获。服务端桥接是 native
    // 函数，异常原样抛出会直接穿过解释器（实测 `java.getString('<js>坏脚本</js>')` 在
    // try/catch 里依然整条失败），必须自己转成 JS 错误才对齐。
    //
    // 未被捕获时行为不变：上层把消息转成 502「source_execution_failed」提示。消息格式沿用
    // Rhino 的 `类名: 消息`（与 WrappedException.toString() 一致，便于定位）；业务语义异常
    // （RuleExecutionException）本身就是给人看的中文提示，保持原文不加类名前缀。
    val detail = if (error is RuleExecutionException) {
        error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
    } else {
        "${error.javaClass.name}: ${error.message ?: "无详细信息"}"
    }
    throw ScriptRuntime.constructError("Error", detail) as Throwable
}

/** Android `String.isJson()`：只看首尾字符，不校验内容是否为合法 JSON。 */
internal fun String.isJsonLike(): Boolean {
    val value = trim()
    return (value.startsWith("{") && value.endsWith("}")) || (value.startsWith("[") && value.endsWith("]"))
}

/**
 * 目录/正文分页地址是否**真的可以抓取**：只认 http(s) 与 `data:`。
 *
 * 为什么必须挡：沙箱在 JS 规则无返回值时会把全局 `result` 兜回来（`fallbackToGlobalResult`），
 * 于是 `nextTocUrl: <js>JSON.parse(result).next</js>` 这种规则在**没有下一页**时会返回
 * 整段响应体。Android 那边这种值同样不会被当成 URL 请求，服务端也必须在入队前挡掉，
 * 否则会把 JSON 正文当地址去 fetch（表现为「URL 格式无效或包含未解析变量」）。
 */
internal fun String.isFetchableSourceUrl(): Boolean {
    val value = trim()
    return value.startsWith("http://", ignoreCase = true) ||
        value.startsWith("https://", ignoreCase = true) ||
        value.startsWith("data:", ignoreCase = true)
}

/** Android `String.isXml()`：同样只按首尾字符判定。 */
internal fun String.isXmlLike(): Boolean {
    val value = trim()
    return value.startsWith("<") && value.endsWith(">")
}

/**
 * 对照 Android `AnalyzeUrl.encodeParams` 编码表单 body。
 *
 * 无 charset 声明时只编码尚未编码的字段；声明 charset 时始终按该 charset
 * 重新编码。`escape` 使用 Android `EncoderUtils.escape` 的 UTF-16 `%u` 形式。
 */
internal fun encodeForm(body: String, charset: Charset, charsetName: String?): String {
    val checkEncoded = charsetName.isNullOrBlank()
    val encodingCharset = when {
        checkEncoded -> Charsets.UTF_8
        charsetName.equals("escape", ignoreCase = true) -> null
        else -> charset
    }
    val output = StringBuilder()
    var position = 0
    while (position <= body.length) {
        if (output.isNotEmpty()) output.append('&')
        var ampersand = body.indexOf('&', position)
        if (ampersand == -1) ampersand = body.length
        val equals = body.indexOf('=', position)
        val key: String
        val value: String?
        if (equals == -1 || equals > ampersand) {
            key = body.substring(position, ampersand)
            value = null
        } else {
            key = body.substring(position, equals)
            value = body.substring(equals + 1, ampersand)
        }
        output.appendEncodedForm(key, checkEncoded, encodingCharset)
        if (value != null) {
            output.append('=')
            output.appendEncodedForm(value, checkEncoded, encodingCharset)
        }
        position = ampersand + 1
    }
    return output.toString()
}

private fun StringBuilder.appendEncodedForm(value: String, checkEncoded: Boolean, charset: Charset?) {
    when {
        checkEncoded && value.isAlreadyFormEncoded() -> append(value)
        charset == null -> append(escapeFormValue(value))
        else -> append(URLEncoder.encode(value, charset))
    }
}

/** 对照 Android `NetworkUtils.encodedForm` 的字符集判断。 */
private fun String.isAlreadyFormEncoded(): Boolean {
    var index = 0
    while (index < length) {
        val character = this[index]
        if (character in 'a'..'z' || character in 'A'..'Z' || character in '0'..'9' || character in "*-._") {
            index++
            continue
        }
        if (character == '%' && index + 2 < length && this[index + 1].isHexDigit() && this[index + 2].isHexDigit()) {
            index += 3
            continue
        }
        return false
    }
    return true
}

private fun Char.isHexDigit(): Boolean = this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

/** 对照 Android `EncoderUtils.escape`：非字母数字按 UTF-16 code unit 转为 `%xx`/`%uxxxx`。 */
private fun escapeFormValue(value: String): String = buildString {
    value.forEach { character ->
        val code = character.code
        if (code in 48..57 || code in 65..90 || code in 97..122) {
            append(character)
        } else {
            append(if (code < 16) "%0" else if (code < 256) "%" else "%u")
            append(code.toString(16))
        }
    }
}

