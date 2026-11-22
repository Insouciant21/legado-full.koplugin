package io.legado.server

import com.microsoft.playwright.Browser
import com.microsoft.playwright.BrowserContext
import com.microsoft.playwright.BrowserType
import com.microsoft.playwright.CDPSession
import com.microsoft.playwright.Page
import com.microsoft.playwright.Playwright
import com.microsoft.playwright.Route
import com.microsoft.playwright.Response
import com.google.gson.JsonObject
import kotlinx.serialization.Serializable
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import com.microsoft.playwright.options.Cookie as PwCookie
import com.microsoft.playwright.options.LoadState
import com.microsoft.playwright.options.ScreenshotType
import com.microsoft.playwright.options.ViewportSize
import com.microsoft.playwright.options.WaitUntilState
import java.net.URI
import java.net.URLDecoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Path
import java.time.Duration
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Chromium 任务的真实最终结果；body 是 DOM/脚本生成的 HTML，不是客户端伪造字段。 */
data class BrowserFetchResult(
    val url: String,
    val body: String,
    val status: Int,
    val headers: Map<String, List<String>>,
)

/** Live stream and screenshot controls use the same remote viewport coordinates. */
@Serializable
data class BrowserInteraction(
    val action: String,
    val x: Double? = null,
    val y: Double? = null,
    val text: String? = null,
    val key: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val deltaX: Double? = null,
    val deltaY: Double? = null,
)

sealed interface BrowserStreamEvent {
    data class Frame(
        val data: ByteArray,
        val width: Int,
        val height: Int,
        val timestamp: Double,
    ) : BrowserStreamEvent

    data class State(
        val state: String,
        val url: String,
        val title: String,
        val error: String? = null,
    ) : BrowserStreamEvent

    data class Error(val message: String) : BrowserStreamEvent
    data class Closed(val state: String, val error: String? = null) : BrowserStreamEvent
}

class BrowserStreamConnection internal constructor(
    val events: ReceiveChannel<BrowserStreamEvent>,
    val width: Int,
    val height: Int,
    private val closeAction: () -> Unit,
) : AutoCloseable {
    private var closed = false

    override fun close() {
        if (closed) return
        closed = true
        closeAction()
    }
}

@Serializable
data class BrowserSessionView(
    val id: String,
    val sourceId: String,
    val url: String,
    val title: String,
    val state: String,
    val mode: String = "manual",
    val kind: String = "page",
    val error: String? = null,
)

/**
 * 有界 Chromium 运行时。
 *
 * Playwright 对象只能由 [worker] 线程访问；同一时刻只有一个活动页。
 * AUTO 模式（webView*）在 JS 执行完或 sniffing 捕获后自动完成；
 * MANUAL 模式（startBrowserAwait/startVerification）等待用户 complete/cancel。
 * 完成结果保留在有界队列中供查询（TTL 5 min, max 50 条）。
 */
class BrowserRuntime(
    private val database: Database? = null,
    executablePath: Path? = null,
    private val allowLoopbackForTests: Boolean = false,
) : AutoCloseable {
    private val executablePath = executablePath ?: System.getenv("PLAYWRIGHT_CHROMIUM_PATH")?.let { Path.of(it) }
    private val browserMaxOldSpaceMb = System.getenv("LEGADO_BROWSER_MAX_OLD_SPACE_MB")?.toIntOrNull()
    private val streamJpegQuality = System.getenv("LEGADO_STREAM_JPEG_QUALITY")
        ?.toIntOrNull()
        ?.coerceIn(60, 100)
        ?: 90
    private val worker = Thread(this::runLoop, "legado-browser-runtime").apply { isDaemon = true }
    private val pending = LinkedBlockingQueue<BrowserSession>(MAX_PENDING_SESSIONS)
    private val operations = LinkedBlockingQueue<() -> Unit>(MAX_PENDING_OPERATIONS)
    private val activeSessions = ConcurrentHashMap<String, BrowserSession>()
    private val completedResults = ConcurrentLinkedQueue<BrowserSession>()
    private var playwright: Playwright? = null
    private var browser: Browser? = null
    private val refetchClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build()
    @Volatile private var stopped = false
    @Volatile private var activeSession: BrowserSession? = null

    private companion object {
        /** Android BackstageWebView 默认 60 秒。 */
        const val AUTO_TIMEOUT_MS = 60_000L
        const val MANUAL_ACTIVITY_TIMEOUT_MS = 15 * 60_000L
        const val MANUAL_LOAD_SETTLE_MS = 600L
        const val STREAM_VIEWPORT_WIDTH = 1072
        const val STREAM_VIEWPORT_HEIGHT = 1448
        const val MAX_STREAM_VIEWPORT_EDGE = 1600
        const val RESULT_TTL_MS = 5 * 60_000L
        const val MAX_COMPLETED_RESULTS = 50
        const val DEFAULT_JS = "document.documentElement.outerHTML"
        const val MAX_PENDING_SESSIONS = 20
        const val MAX_PENDING_OPERATIONS = 50
        const val REFETCH_TIMEOUT_S = 30L
        const val REFETCH_MAX_BODY_BYTES = 5L * 1024 * 1024
    }

    private inner class BrowserSession(
        val id: String,
        val sourceId: String,
        val url: String,
        val title: String,
        val html: String?,
        val webJs: String?,
        val headers: Map<String, String>,
        val mode: String,
        val refetchAfterSuccess: Boolean,
        val kind: String,
        val sourceRegex: String? = null,
        val overrideUrlRegex: String? = null,
        val delayTimeMs: Long = 0L,
    ) {
        val future = CompletableFuture<BrowserFetchResult>()
        @Volatile var state = "queued"
        @Volatile var error: String? = null
        @Volatile var completeRequested = false
        @Volatile var cancelRequested = false
        @Volatile var completionInput: String? = null
        @Volatile var lastActivity = System.currentTimeMillis()
        @Volatile var sniffedResult: String? = null
        @Volatile var jsResult: String? = null
        @Volatile var lastResponse: Response? = null
        @Volatile var currentUrl = displayUrl(url)
        @Volatile var viewport = ViewportSize(STREAM_VIEWPORT_WIDTH, STREAM_VIEWPORT_HEIGHT)
        @Volatile var lastStreamFrame: BrowserStreamEvent.Frame? = null
        val streamSinks = ConcurrentHashMap.newKeySet<(BrowserStreamEvent) -> Unit>()
        var cdpSession: CDPSession? = null
        var screencastHandler: java.util.function.Consumer<JsonObject>? = null
        var page: Page? = null
        var context: BrowserContext? = null
        val createdAt = System.currentTimeMillis()

        val isManual: Boolean get() = mode == "manual"
        val isSniffing: Boolean get() = !sourceRegex.isNullOrBlank() || !overrideUrlRegex.isNullOrBlank()
    }

    init {
        worker.start()
    }

    /** 供 JS 网页验证与 RuleRunner webView/webJs 共用；每个源单独隔离 Cookie。 */
    fun start(
        sourceId: String,
        url: String,
        title: String,
        html: String? = null,
        webJs: String? = null,
        headers: Map<String, String> = emptyMap(),
        await: Boolean,
        refetch: Boolean = true,
        kind: String = if (title == "验证码") "captcha" else "page",
        sourceRegex: String? = null,
        overrideUrlRegex: String? = null,
        delayTimeMs: Long = 0L,
    ): BrowserFetchResult? {
        if (!await) {
            val session = BrowserSession(
                id = UUID.randomUUID().toString(),
                sourceId = sourceId.ifBlank { url },
                url = url,
                title = title,
                html = html,
                webJs = webJs,
                headers = headers,
                mode = "manual",
                refetchAfterSuccess = refetch,
                kind = kind,
                sourceRegex = sourceRegex,
                overrideUrlRegex = overrideUrlRegex,
                delayTimeMs = delayTimeMs,
            )
            activeSessions[session.id] = session
            pending.put(session)
            return null
        }
        val session = BrowserSession(
            id = UUID.randomUUID().toString(),
            sourceId = sourceId.ifBlank { url },
            url = url,
            title = title,
            html = html,
            webJs = webJs,
            headers = headers,
            mode = "manual",
            refetchAfterSuccess = refetch,
            kind = kind,
            sourceRegex = sourceRegex,
            overrideUrlRegex = overrideUrlRegex,
            delayTimeMs = delayTimeMs,
        )
        activeSessions[session.id] = session
        pending.put(session)
        return try {
            session.future.get(30, TimeUnit.MINUTES)
        } catch (_: TimeoutException) {
            cancel(session.id, "浏览器验证超时")
            throw IllegalStateException("浏览器验证超时")
        } catch (error: Exception) {
            throw IllegalStateException(error.cause?.message ?: error.message ?: "浏览器执行失败", error)
        }
    }

    /** 直接验证入口：立即返回会话 ID，任务按全局一页预算排队，由网页轮询操作。 */
    fun startVerification(
        sourceId: String,
        url: String,
        title: String = "书源验证",
        html: String? = null,
        webJs: String? = null,
        headers: Map<String, String> = emptyMap(),
        refetch: Boolean = false,
    ): BrowserSessionView {
        val session = BrowserSession(
            id = UUID.randomUUID().toString(),
            sourceId = sourceId,
            url = url,
            title = title,
            html = html,
            webJs = webJs,
            headers = headers,
            mode = "manual",
            refetchAfterSuccess = refetch,
            kind = if (title == "验证码") "captcha" else "page",
        )
        activeSessions[session.id] = session
        pending.put(session)
        return sessionView(session)
    }

    fun result(sessionId: String): BrowserFetchResult? {
        val session = activeSessions[sessionId] ?: completedResults.firstOrNull { it.id == sessionId } ?: return null
        return if (session.future.isDone && !session.future.isCompletedExceptionally) {
            runCatching { session.future.get() }.getOrNull()
        } else {
            null
        }
    }

    fun listSessions(): List<BrowserSessionView> {
        val active = activeSessions.values.filter { it.isManual }.map { sessionView(it) }
        val completed = completedResults.filter { it.isManual }.map { sessionView(it) }
        return active + completed
    }

    fun getSession(sessionId: String): BrowserSessionView? {
        val session = activeSessions[sessionId] ?: completedResults.firstOrNull { it.id == sessionId } ?: return null
        return sessionView(session)
    }

    fun getSessionSourceId(sessionId: String): String? {
        val session = activeSessions[sessionId] ?: completedResults.firstOrNull { it.id == sessionId } ?: return null
        return session.sourceId
    }

    /**
     * 为当前人工会话订阅 CDP JPEG 画面流。
     *
     * WebSocket 路由只消费 [BrowserStreamConnection.events]；所有 Playwright/CDP 调用仍排队到
     * [worker] 线程，避免破坏 Playwright 的线程约束。每个网页每帧都会立即 ack，慢客户端由
     * 有界 Channel 丢弃旧帧，不会拖住 Chromium 页面。
     */
    fun attachStream(sessionId: String): BrowserStreamConnection? {
        val session = activeSessions[sessionId] ?: return null
        val events = Channel<BrowserStreamEvent>(
            capacity = 8,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
        val sink: (BrowserStreamEvent) -> Unit = { events.trySend(it) }
        session.streamSinks.add(sink)
        sink(BrowserStreamEvent.State(session.state, session.currentUrl, session.title, session.error))
        session.lastStreamFrame?.let(sink)
        operations += {
            runCatching { ensureScreencast(session) }.onFailure { error ->
                session.streamSinks.forEach {
                    it(BrowserStreamEvent.Error(error.message ?: "实时画面启动失败"))
                }
            }
        }
        val viewport = session.viewport
        return BrowserStreamConnection(
            events = events,
            width = viewport.width,
            height = viewport.height,
        ) {
            session.streamSinks.remove(sink)
            events.close()
            if (session.streamSinks.isEmpty()) {
                operations += { stopScreencast(session) }
            }
        }
    }

    fun screenshot(sessionId: String): ByteArray {
        val future = CompletableFuture<ByteArray>()
        val session = activeSessions[sessionId] ?: throw IllegalArgumentException("浏览器会话不存在或已结束")
        operations += {
            runCatching {
                val bytes = session.page?.screenshot(Page.ScreenshotOptions().setType(ScreenshotType.PNG))
                    ?: throw IllegalStateException("浏览器页面尚未就绪")
                future.complete(bytes)
            }.onFailure { future.completeExceptionally(it) }
        }
        try {
            return future.get(15, TimeUnit.SECONDS)
        } catch (error: Exception) {
            throw when (error) {
                is IllegalArgumentException -> error
                is IllegalStateException -> error
                else -> IllegalStateException(error.cause?.message ?: error.message ?: "截图失败", error)
            }
        }
    }

    fun interact(sessionId: String, interaction: BrowserInteraction): Unit = runOperation(sessionId) { session ->
        val page = session.page ?: error("浏览器页面尚未就绪")
        performInteraction(session, page, interaction, useCdpInput = false)
    }

    /** WebSocket 实时流的低延迟输入通道；输入成功后会主动广播最新地址和状态。 */
    fun streamInteract(sessionId: String, interaction: BrowserInteraction) = runOperation(sessionId) { session ->
        val page = session.page ?: error("浏览器页面尚未就绪")
        performInteraction(session, page, interaction, useCdpInput = true)
        publishStreamState(session)
    }

    private fun performInteraction(
        session: BrowserSession,
        page: Page,
        interaction: BrowserInteraction,
        useCdpInput: Boolean,
    ) {
        val viewport = session.viewport
        // A frame from before a resize can still be on screen. Its coordinates
        // must not click a different control after Chromium has reflowed the page.
        if ((interaction.action == "click" || interaction.action == "scroll") &&
            ((interaction.width != null && interaction.width != viewport.width) ||
                (interaction.height != null && interaction.height != viewport.height))) return

        val cdp = session.cdpSession.takeIf { useCdpInput }
        when (interaction.action) {
            "resize" -> {
                require(session.isManual && session.state == "interactive") {
                    "当前浏览器会话无法调整视口"
                }
                val width = requireNotNull(interaction.width) { "缺少视口宽度" }
                val height = requireNotNull(interaction.height) { "缺少视口高度" }
                require(width in 1..MAX_STREAM_VIEWPORT_EDGE && height in 1..MAX_STREAM_VIEWPORT_EDGE) {
                    "视口尺寸超出范围"
                }
                if (width == viewport.width && height == viewport.height) return
                session.lastStreamFrame = null
                page.setViewportSize(width, height)
                session.viewport = ViewportSize(width, height)
            }
            "click" -> {
                val x = requireNotNull(interaction.x) { "缺少 x" }
                val y = requireNotNull(interaction.y) { "缺少 y" }
                if (cdp != null) dispatchCdpClick(cdp, x, y) else page.mouse().click(x, y)
            }
            "type" -> {
                val text = requireNotNull(interaction.text) { "缺少 text" }
                if (cdp != null) {
                    cdp.send("Input.insertText", JsonObject().apply { addProperty("text", text) })
                } else {
                    page.keyboard().type(text)
                }
            }
            "key" -> page.keyboard().press(requireNotNull(interaction.key) { "缺少 key" })
            "scroll" -> {
                // Older clients use x/y for the wheel deltas. The new shape
                // carries the cursor position separately so nested panes scroll.
                val hasDeltas = interaction.deltaX != null || interaction.deltaY != null
                val deltaX = (if (hasDeltas) interaction.deltaX else interaction.x) ?: 0.0
                val deltaY = (if (hasDeltas) interaction.deltaY else interaction.y) ?: 0.0
                val x = interaction.x.takeIf { hasDeltas } ?: (viewport.width - 1) / 2.0
                val y = interaction.y.takeIf { hasDeltas } ?: (viewport.height - 1) / 2.0
                if (cdp != null) {
                    cdp.send(
                        "Input.dispatchMouseEvent",
                        JsonObject().apply {
                            addProperty("type", "mouseWheel")
                            addProperty("x", x)
                            addProperty("y", y)
                            addProperty("deltaX", deltaX)
                            addProperty("deltaY", deltaY)
                        },
                    )
                } else {
                    if (hasDeltas) page.mouse().move(x, y)
                    page.mouse().wheel(deltaX, deltaY)
                }
            }
            "back" -> page.goBack().also { session.lastResponse = it }
            "forward" -> page.goForward().also { session.lastResponse = it }
            "reload" -> page.reload().also { session.lastResponse = it }
            "navigate" -> page.navigate(
                requireNotNull(interaction.text) { "缺少地址" },
                Page.NavigateOptions().setTimeout(30_000.0).setWaitUntil(WaitUntilState.DOMCONTENTLOADED),
            ).also { session.lastResponse = it }
            else -> throw IllegalArgumentException("不支持的操作: ${interaction.action}")
        }
        page.url().takeIf { it.isNotBlank() && !it.startsWith("about:blank", ignoreCase = true) }?.let {
            session.currentUrl = displayUrl(it)
        }
        session.lastActivity = System.currentTimeMillis()
    }

    private fun dispatchCdpClick(cdp: CDPSession, x: Double, y: Double) {
        cdp.send(
            "Input.dispatchMouseEvent",
            JsonObject().apply {
                addProperty("type", "mousePressed")
                addProperty("x", x)
                addProperty("y", y)
                addProperty("button", "left")
                addProperty("buttons", 1)
                addProperty("clickCount", 1)
            },
        )
        cdp.send(
            "Input.dispatchMouseEvent",
            JsonObject().apply {
                addProperty("type", "mouseReleased")
                addProperty("x", x)
                addProperty("y", y)
                addProperty("button", "left")
                addProperty("buttons", 0)
                addProperty("clickCount", 1)
            },
        )
    }

    fun complete(sessionId: String, input: String? = null): BrowserSessionView? {
        val session = activeSessions[sessionId] ?: return null
        if (input != null) session.completionInput = input
        session.completeRequested = true
        session.lastActivity = System.currentTimeMillis()
        return sessionView(session)
    }

    fun cancel(sessionId: String, reason: String = "浏览器验证已取消"): Boolean {
        val session = activeSessions[sessionId] ?: return false
        session.error = reason
        session.cancelRequested = true
        if (session.state == "queued") {
            pending.remove(session)
            finish(session, completed = false)
        }
        return true
    }

    fun webViewSnapshot(
        sourceId: String,
        url: String,
        html: String? = null,
        js: String? = null,
        headers: Map<String, String> = emptyMap(),
        sourceRegex: String? = null,
        overrideUrlRegex: String? = null,
        delayTimeMs: Long = 0L,
    ): BrowserFetchResult {
        val session = BrowserSession(
            id = UUID.randomUUID().toString(),
            sourceId = sourceId.ifBlank { url },
            url = url,
            title = "WebView",
            html = html,
            webJs = js,
            headers = headers,
            mode = "auto",
            refetchAfterSuccess = false,
            kind = "page",
            sourceRegex = sourceRegex,
            overrideUrlRegex = overrideUrlRegex,
            delayTimeMs = delayTimeMs,
        )
        activeSessions[session.id] = session
        pending.put(session)
        return try {
            session.future.get(AUTO_TIMEOUT_MS + 30_000, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            cancel(session.id, "WebView 执行超时")
            throw IllegalStateException("WebView 执行超时")
        } catch (error: Exception) {
            throw IllegalStateException(error.cause?.message ?: error.message ?: "WebView 执行失败", error)
        }
    }

    fun webViewGetSource(
        sourceId: String,
        url: String,
        html: String? = null,
        js: String? = null,
        sourceRegex: String? = null,
        cacheFirst: Boolean = false,
        delayTimeMs: Long = 0L,
    ): String = webViewSnapshot(
        sourceId,
        url,
        html,
        js,
        sourceRegex = sourceRegex,
        delayTimeMs = delayTimeMs,
    ).body

    fun webViewGetOverrideUrl(
        sourceId: String,
        url: String,
        html: String? = null,
        js: String? = null,
        overrideUrlRegex: String,
        cacheFirst: Boolean = false,
        delayTimeMs: Long = 0L,
    ): String = webViewSnapshot(
        sourceId, url, html, js, overrideUrlRegex = overrideUrlRegex, delayTimeMs = delayTimeMs,
    ).body

    override fun close() {
        if (stopped) return
        stopped = true
        runCatching { worker.interrupt() }
        runCatching { worker.join(5_000) }
        activeSessions.values.forEach { session ->
            session.future.completeExceptionally(IllegalStateException("浏览器运行时已关闭"))
        }
        activeSessions.clear()
        completedResults.clear()
    }

    private fun runOperation(sessionId: String, block: (BrowserSession) -> Unit) {
        val session = activeSessions[sessionId] ?: throw IllegalArgumentException("浏览器会话不存在或已结束")
        val future = CompletableFuture<Unit>()
        operations += {
            runCatching { block(session) }.fold(
                onSuccess = { future.complete(it) },
                onFailure = { future.completeExceptionally(it) },
            )
        }
        try {
            future.get(15, TimeUnit.SECONDS)
        } catch (error: Exception) {
            throw when (error) {
                is IllegalArgumentException -> error
                is IllegalStateException -> error
                else -> IllegalStateException(error.cause?.message ?: error.message ?: "浏览器操作失败", error)
            }
        }
    }

    private fun runLoop() {
        try {
            while (!stopped) {
                drainOperations()
                val session = try {
                    pending.poll(200, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    break
                } ?: continue
                if (session.cancelRequested) {
                    finish(session, completed = false)
                    continue
                }
                activeSession = session
                session.state = "loading"
                try {
                    openSession(session)
                    controlLoop(session)
                } catch (error: Throwable) {
                    if (!session.cancelRequested) {
                        session.error = error.message ?: error.javaClass.simpleName
                        error.printStackTrace()
                    }
                } finally {
                    val completed = !session.cancelRequested && session.error == null
                    finish(session, completed = completed)
                    activeSession = null
                }
                drainOperations()
                pruneCompletedResults()
            }
        } finally {
            activeSessions.values.forEach { session ->
                session.future.completeExceptionally(IllegalStateException("浏览器运行时已关闭"))
            }
            activeSessions.clear()
            completedResults.clear()
            runCatching { browser?.close() }
            runCatching { playwright?.close() }
        }
    }

    private fun openSession(session: BrowserSession) {
        val browser = ensureBrowser()
        val contextOptions = Browser.NewContextOptions()
            .setViewportSize(STREAM_VIEWPORT_WIDTH, STREAM_VIEWPORT_HEIGHT)
            .setDeviceScaleFactor(1.0)
            .setJavaScriptEnabled(true)
        if (session.headers.isNotEmpty()) {
            contextOptions.setExtraHTTPHeaders(session.headers)
        }
        val context = browser.newContext(contextOptions)
        session.context = context
        restoreCookies(session)
        setupRouteFilter(context, session)
        val page = context.newPage()
        session.page = page
        page.onFrameNavigated(java.util.function.Consumer { frame: com.microsoft.playwright.Frame ->
            val navUrl = frame.url()
            if (frame.parentFrame() == null && navUrl.isNotBlank() && !navUrl.startsWith("about:blank", ignoreCase = true)) {
                session.currentUrl = displayUrl(navUrl)
                publishStreamState(session)
                session.overrideUrlRegex?.let { regex ->
                    if (runCatching { navUrl.matches(regex.toRegex()) }.getOrDefault(false)) {
                        if (session.sniffedResult == null) session.sniffedResult = navUrl
                    }
                }
            }
        })
        val target = session.url
        /*
         * Android 在 onPageFinished（对应 load 事件）后才把页面交给用户保存结果。
         * 只等 DOMContentLoaded 会让登录后台这类延迟渲染的页面在首张截图里仍停在遮罩上。
         * load 完成后再留一个很短的渲染窗口，同时保持排队任务有界。
         */
        val waitUntil = if (session.isManual) WaitUntilState.LOAD else WaitUntilState.DOMCONTENTLOADED
        session.lastResponse = navigateToUrl(page, target, waitUntil)
        page.waitForLoadState(if (session.isManual) LoadState.LOAD else LoadState.DOMCONTENTLOADED)
        if (session.isManual) {
            runCatching { page.waitForTimeout(MANUAL_LOAD_SETTLE_MS.toDouble()) }
        }
        page.url().takeIf { it.isNotBlank() && !it.startsWith("about:blank", ignoreCase = true) }?.let {
            session.currentUrl = displayUrl(it)
        }
        session.lastActivity = System.currentTimeMillis()
        session.state = if (session.isManual) "interactive" else "evaluating"
        if (session.isManual && session.streamSinks.isNotEmpty()) {
            runCatching { ensureScreencast(session) }
                .onFailure { error -> session.streamSinks.forEach { it(BrowserStreamEvent.Error(error.message ?: "实时画面启动失败")) } }
        }
    }

    private fun navigateToUrl(
        page: Page,
        target: String,
        waitUntil: WaitUntilState = WaitUntilState.DOMCONTENTLOADED,
    ): Response? {
        return if (target.startsWith("data:", ignoreCase = true)) {
            page.setContent(decodeDataHtml(target), Page.SetContentOptions().setTimeout(30_000.0).setWaitUntil(waitUntil))
            null
        } else {
            page.navigate(
                target,
                Page.NavigateOptions()
                    .setTimeout(AUTO_TIMEOUT_MS.toDouble())
                    .setWaitUntil(waitUntil),
            )
        }
    }

    private fun ensureScreencast(session: BrowserSession) {
        if (session.cdpSession != null) return
        val context = session.context ?: error("浏览器页面尚未就绪")
        val page = session.page ?: error("浏览器页面尚未就绪")
        val cdp = context.newCDPSession(page)
        val handler = java.util.function.Consumer<JsonObject> { payload ->
            try {
                val data = payload.get("data").asString
                val metadata = payload.getAsJsonObject("metadata")
                val frame = BrowserStreamEvent.Frame(
                    data = Base64.getDecoder().decode(data),
                    width = metadata.get("deviceWidth")?.asInt ?: session.viewport.width,
                    height = metadata.get("deviceHeight")?.asInt ?: session.viewport.height,
                    timestamp = metadata.get("timestamp")?.asDouble ?: 0.0,
                )
                session.lastStreamFrame = frame
                cdp.send(
                    "Page.screencastFrameAck",
                    JsonObject().apply {
                        addProperty("sessionId", payload.get("sessionId")?.asInt ?: 0)
                    },
                )
                session.streamSinks.forEach { it(frame) }
            } catch (error: Throwable) {
                session.streamSinks.forEach {
                    it(BrowserStreamEvent.Error(error.message ?: "实时画面帧解析失败"))
                }
            }
        }
        session.cdpSession = cdp
        session.screencastHandler = handler
        cdp.on("Page.screencastFrame", handler)
        cdp.send(
            "Page.startScreencast",
            JsonObject().apply {
                addProperty("format", "jpeg")
                addProperty("quality", streamJpegQuality)
                // Capture at the full viewport size so frame pixels and input
                // coordinates remain interchangeable after a resize.
                addProperty("maxWidth", MAX_STREAM_VIEWPORT_EDGE)
                addProperty("maxHeight", MAX_STREAM_VIEWPORT_EDGE)
                addProperty("everyNthFrame", 1)
            },
        )
        publishStreamState(session)
    }

    private fun stopScreencast(session: BrowserSession) {
        val cdp = session.cdpSession ?: return
        runCatching { cdp.send("Page.stopScreencast") }
        session.screencastHandler?.let { handler ->
            runCatching { cdp.off("Page.screencastFrame", handler) }
        }
        runCatching { cdp.detach() }
        session.cdpSession = null
        session.screencastHandler = null
    }

    private fun publishStreamState(session: BrowserSession) {
        val event = BrowserStreamEvent.State(
            state = session.state,
            url = session.currentUrl,
            title = session.title,
            error = session.error,
        )
        session.streamSinks.forEach { it(event) }
    }

    private fun controlLoop(session: BrowserSession) {
        if (session.isManual) {
            if (session.delayTimeMs > 0) {
                runCatching { session.page?.waitForTimeout(session.delayTimeMs.toDouble()) }
            }
            evaluateJs(session)
            while (!session.completeRequested && !session.cancelRequested && !stopped) {
                drainOperations()
                if (System.currentTimeMillis() - session.lastActivity > MANUAL_ACTIVITY_TIMEOUT_MS) {
                    session.error = "浏览器验证过期"
                    break
                }
                val waitMs = if (session.streamSinks.isEmpty()) 200.0 else 32.0
                runCatching { session.page?.waitForTimeout(waitMs) }
                    .onFailure { error -> if (!session.cancelRequested && !stopped) throw error }
            }
            drainOperations()
        } else {
            if (session.delayTimeMs > 0) {
                runCatching { session.page?.waitForTimeout(session.delayTimeMs.toDouble()) }
            }
            if (session.isSniffing) {
                val snifferDeadline = System.currentTimeMillis() + AUTO_TIMEOUT_MS
                while (session.sniffedResult == null && System.currentTimeMillis() < snifferDeadline && !stopped) {
                    drainOperations()
                    if (session.sniffedResult == null) {
                        session.webJs?.let { js -> if (js.isNotBlank()) runCatching { evaluateJs(session, js) } }
                    }
                    runCatching { session.page?.waitForTimeout(200.0) }
                        .onFailure { error -> if (!session.cancelRequested && !stopped) throw error }
                }
                if (session.sniffedResult == null && !stopped && !session.cancelRequested) {
                    session.error = "WebView 资源捕获超时"
                }
            } else {
                if (session.webJs.isNullOrBlank() && session.delayTimeMs <= 0L) {
                    runCatching { session.page?.waitForTimeout(900.0) }
                        .onFailure { error -> if (!session.cancelRequested && !stopped) throw error }
                }
                evaluateJs(session)
            }
        }
    }

    private fun evaluateJs(session: BrowserSession, jsOverride: String? = null) {
        val page = session.page ?: return
        val js = jsOverride ?: session.webJs ?: DEFAULT_JS
        if (js.isBlank()) return
        try {
            val encoded = java.util.Base64.getEncoder().encodeToString(js.toByteArray(Charsets.UTF_8))
            val result = page.evaluate("""(function() { return eval(atob("$encoded")); })()""")
            val value = result?.toString() ?: ""
            if (value.isNotBlank() && value != "null") {
                session.jsResult = value
            }
        } catch (error: Throwable) {
            System.err.println("BrowserRuntime evaluateJs error: ${error.message}")
        }
    }

    private fun setupRouteFilter(context: BrowserContext, session: BrowserSession) {
        val sourcePattern = session.sourceRegex?.let { runCatching { it.toRegex() }.getOrNull() }
        context.route("**/*") { route ->
            try {
                val uri = URI(route.request().url())
                val allowed = (uri.scheme == "http" || uri.scheme == "https") &&
                    (allowLoopbackForTests || runCatching {
                        NetworkSecurity.resolveAndValidateSafeHttpTarget(uri, "浏览器")
                        true
                    }.getOrDefault(false))
                if (!allowed) {
                    route.fulfill(Route.FulfillOptions().setStatus(403).setBody("浏览器请求被安全策略拒绝"))
                    return@route
                }
                val resUrl = route.request().url()
                if (!session.html.isNullOrBlank() &&
                    route.request().isNavigationRequest() &&
                    resUrl == session.url
                ) {
                    route.fulfill(
                        Route.FulfillOptions()
                            .setStatus(200)
                            .setContentType("text/html; charset=utf-8")
                            .setBody(session.html),
                    )
                    return@route
                }
                if (route.request().isNavigationRequest()) {
                    session.overrideUrlRegex?.let { regex ->
                        if (session.sniffedResult == null &&
                            runCatching { resUrl.matches(regex.toRegex()) }.getOrDefault(false)
                        ) {
                            session.sniffedResult = resUrl
                        }
                    }
                }
                if (sourcePattern != null && session.sniffedResult == null &&
                    runCatching { resUrl.matches(sourcePattern) }.getOrDefault(false)) {
                    session.sniffedResult = resUrl
                }
                route.resume()
            } catch (_: Throwable) {
                route.fulfill(Route.FulfillOptions().setStatus(403).setBody("浏览器请求被安全策略拒绝"))
            }
        }
    }

    private fun finish(session: BrowserSession, completed: Boolean) {
        try {
            val page = session.page
            val context = session.context
            if (completed && page != null && context != null) {
                val response = session.lastResponse
                val sniffed = session.sniffedResult
                val result = when {
                    session.isSniffing && sniffed != null ->
                        BrowserFetchResult(url = session.url, body = sniffed, status = 200, headers = emptyMap())
                    session.completionInput != null && session.kind == "captcha" ->
                        BrowserFetchResult(url = page.url().ifBlank { session.url }, body = session.completionInput!!, status = 200, headers = emptyMap())
                    session.mode == "auto" && !session.isSniffing && !session.jsResult.isNullOrBlank() ->
                        BrowserFetchResult(
                            url = page.url().ifBlank { session.url },
                            body = session.jsResult!!,
                            status = response?.status() ?: 200,
                            headers = response?.headers()?.mapValues { (_, v) -> listOf(v) } ?: emptyMap(),
                        )
                    session.refetchAfterSuccess -> refetchAfterSuccess(session)
                    else -> {
                        val finalUrl = page.url().ifBlank { session.url }
                        BrowserFetchResult(
                            url = finalUrl,
                            body = page.content(),
                            status = response?.status() ?: 200,
                            headers = response?.headers()?.mapValues { (_, v) -> listOf(v) } ?: emptyMap(),
                        )
                    }
                }
                persistCookies(session.sourceId, context.cookies())
                session.state = "completed"
                session.future.complete(result)
            } else {
                val reason = session.error ?: "浏览器验证已取消"
                session.future.completeExceptionally(IllegalStateException(reason))
                session.state = if (session.cancelRequested) "canceled" else "error"
            }
        } catch (error: Throwable) {
            session.future.completeExceptionally(error)
            session.state = "error"
        } finally {
            session.streamSinks.forEach {
                it(BrowserStreamEvent.Closed(session.state, session.error))
            }
            session.streamSinks.clear()
            stopScreencast(session)
            runCatching { session.context?.close() }
            session.page = null
            session.context = null
            activeSessions.remove(session.id)
            completedResults.add(session)
        }
    }

    private fun refetchAfterSuccess(session: BrowserSession): BrowserFetchResult {
        val deadline = System.currentTimeMillis() + REFETCH_TIMEOUT_S * 1000
        var target = URI(session.url)
        repeat(6) {
            if (!allowLoopbackForTests) {
                NetworkSecurity.resolveAndValidateSafeHttpTarget(target, "浏览器重抓")
            }
            val cookieHeader = buildCookieHeader(session.context?.cookies() ?: emptyList(), target)
            val builder = HttpRequest.newBuilder(target).GET().timeout(Duration.ofSeconds(10))
            if (cookieHeader.isNotBlank()) builder.header("Cookie", cookieHeader)
            session.headers.forEach { (key, value) ->
                if (!key.equals("Cookie", ignoreCase = true)) builder.header(key, value)
            }
            val response = refetchClient.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray())
            val status = response.statusCode()
            if (status !in setOf(301, 302, 303, 307, 308)) {
                val bytes = response.body()
                if (bytes.size > REFETCH_MAX_BODY_BYTES) {
                    throw IllegalStateException("浏览器重抓响应超过大小限制")
                }
                val headerMap = response.headers().map().mapValues { (_, values) -> values }
                return BrowserFetchResult(target.toString(), String(bytes, Charsets.UTF_8), status, headerMap)
            }
            if (System.currentTimeMillis() >= deadline) throw IllegalStateException("浏览器重抓超时")
            val location = response.headers().firstValue("location").orElse(null)
                ?: throw IllegalStateException("重定向缺少 Location")
            target = target.resolve(location)
        }
        throw IllegalStateException("浏览器重抓跳转次数超限")
    }

    private fun buildCookieHeader(contextCookies: List<PwCookie>, uri: URI): String {
        val host = uri.host ?: return ""
        return contextCookies
            .filter { (it.domain ?: "").removePrefix(".").let { d -> host.endsWith(d, true) || host == d } }
            .map { "${it.name}=${it.value}" }
            .joinToString("; ")
    }

    private fun restoreCookies(session: BrowserSession) {
        val database = database ?: return
        val jar = database.getSourceCookieJar(session.sourceId)
        if (jar.isEmpty()) return
        val context = session.context ?: return
        val cookies = jar.entries.flatMap { (domain, value) ->
            parseCookieString(value).entries.map { (name, cookieValue) ->
                PwCookie(name, cookieValue).setDomain(domain).setPath("/")
            }
        }
        if (cookies.isNotEmpty()) context.addCookies(cookies)
    }

    private fun persistCookies(sourceId: String, cookies: List<PwCookie>) {
        val database = database ?: return
        if (cookies.isEmpty()) return
        val jar = database.getSourceCookieJar(sourceId).toMutableMap()
        cookies.forEach { cookie ->
            val domain = cookie.domain.orEmpty().removePrefix(".").ifBlank { return@forEach }
            val existing = parseCookieString(jar[domain] ?: "")
            existing[cookie.name] = cookie.value
            jar[domain] = existing.entries.joinToString("; ") { "${it.key}=${it.value}" }
        }
        database.saveSourceCookieJar(sourceId, jar)
    }

    private fun ensureBrowser(): Browser {
        val existing = browser
        if (existing != null) return existing
        val current = Playwright.create()
        playwright = current
        val launchOptions = BrowserType.LaunchOptions().setHeadless(true)
        executablePath?.let { launchOptions.setExecutablePath(it) }
        launchOptions.setArgs(
            buildList {
                add("--disable-dev-shm-usage")
                browserMaxOldSpaceMb?.takeIf { it > 0 }?.let { add("--js-flags=--max-old-space-size=$it") }
            },
        )
        val launched = current.chromium().launch(launchOptions)
        browser = launched
        return launched
    }

    private fun drainOperations() {
        while (true) {
            val operation = operations.poll() ?: break
            operation()
        }
    }

    private fun pruneCompletedResults() {
        val now = System.currentTimeMillis()
        val toKeep = completedResults.filter { now - it.createdAt < RESULT_TTL_MS }
        completedResults.clear()
        toKeep.takeLast(MAX_COMPLETED_RESULTS).forEach { completedResults.add(it) }
    }

    private fun sessionView(session: BrowserSession) = BrowserSessionView(
        id = session.id,
        sourceId = session.sourceId,
        url = session.currentUrl,
        title = session.title,
        state = session.state,
        mode = session.mode,
        kind = session.kind,
        error = session.error,
    )

    /**
     * 前端只展示可读地址。`data:`/`about:blank` 内置页不回传大段页面；
     * 普通页移除 query 与 fragment，避免把一次性交接码、设置 JSON 或 token 带进轮询 DTO。
     */
    private fun displayUrl(value: String): String {
        if (value.startsWith("data:", ignoreCase = true) || value.startsWith("about:blank", ignoreCase = true)) {
            return "data:text/html"
        }
        return runCatching {
            val uri = URI(value)
            if (uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank()) {
                URI(uri.scheme, null, uri.host, uri.port, uri.path.orEmpty().ifBlank { "/" }, null, null).toString()
            } else {
                value
            }
        }.getOrDefault(value)
    }

    private fun decodeDataHtml(value: String): String {
        val raw = value.substringAfter("data:", "")
        val header = raw.substringBefore(",", "")
        val payload = raw.substringAfter(",", "")
        return if (header.contains("base64", ignoreCase = true)) {
            String(Base64.getDecoder().decode(payload), Charsets.UTF_8)
        } else {
            URLDecoder.decode(payload, Charsets.UTF_8)
        }
    }

    private operator fun <T> LinkedBlockingQueue<T>.plusAssign(value: T) {
        put(value)
    }
}

/** 登录代理已公布的 BrowserHook 实现；await 真实挂起，非 await 只建立可发现会话。 */
class SourceBrowserHook(private val runtime: BrowserRuntime) : BrowserHook {
    override fun start(
        sourceId: String,
        url: String,
        title: String,
        html: String?,
        await: Boolean,
        refetch: Boolean,
    ): JsStrResponse? {
        val result = runtime.start(
            sourceId = sourceId,
            url = url,
            title = title,
            html = html,
            await = await,
            refetch = refetch,
        ) ?: return null
        return JsStrResponse(
            url = result.url,
            body = result.body,
            code = result.status,
            message = if (result.status in 200..299) "OK" else "HTTP ${result.status}",
            headers = JsHeaders.of(result.headers),
        )
    }

    override fun webViewGetSource(
        sourceId: String,
        html: String?,
        url: String?,
        js: String?,
        sourceRegex: String,
        cacheFirst: Boolean,
        delayTime: Long,
    ): String? {
        if (url.isNullOrBlank()) return null
        return runtime.webViewGetSource(
            sourceId = sourceId,
            url = url,
            html = html,
            js = js,
            sourceRegex = sourceRegex,
            delayTimeMs = delayTime,
        )
    }

    override fun webViewGetOverrideUrl(
        sourceId: String,
        html: String?,
        url: String?,
        js: String?,
        overrideUrlRegex: String,
        cacheFirst: Boolean,
        delayTime: Long,
    ): String? {
        if (url.isNullOrBlank()) return null
        return runtime.webViewGetOverrideUrl(
            sourceId = sourceId,
            url = url,
            html = html,
            js = js,
            overrideUrlRegex = overrideUrlRegex,
            delayTimeMs = delayTime,
        )
    }
}

private fun parseCookieString(value: String): MutableMap<String, String> {
    val result = linkedMapOf<String, String>()
    value.split(';').forEach { part ->
        val separator = part.indexOf('=')
        if (separator > 0) {
            result[part.substring(0, separator).trim()] = part.substring(separator + 1).trim()
        }
    }
    return result
}
