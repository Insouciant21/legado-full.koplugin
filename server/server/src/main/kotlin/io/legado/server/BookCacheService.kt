package io.legado.server

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.coroutineContext

internal const val BOOK_CACHE_MIN_CONCURRENCY = 1
internal const val BOOK_CACHE_MAX_CONCURRENCY = 9
internal const val BOOK_CACHE_DEFAULT_CONCURRENCY = BOOK_CACHE_MAX_CONCURRENCY

internal fun chapterCacheKeys(chapters: List<Chapter>): Set<String> = chapters.asSequence()
    .filterNot { it.isVolume }
    .map { SourceUrlOptions.cacheKey(it.url) }
    .filter { it.isNotBlank() }
    .toSet()

class BookCacheService(
    private val database: Database,
    private val runner: RuleRunner,
    /**
     * 小说正文插图的落盘缓存（`<data>/images/`）。
     *
     * 传 null ⇒ 只缓存正文、不预热插图。
     * 给了它就必须同时给 [illustrationFetcher]：抓图必须有书源 header/Referer/Cookie 与限流收口，
     * 那条链路只有 `MangaImageFetcher` 有。
     */
    private val illustrationCache: IllustrationCache? = null,
    private val illustrationFetcher: MangaImageFetcher? = null,
    private val autoCacheEnabled: Boolean = true,
    /** ⚠️ 必须**留在最后**：既有调用点大量使用尾随 lambda 传 `log`。 */
    private val log: (String) -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val started = AtomicBoolean(false)
    private val jobs = ConcurrentHashMap<String, Job>()
    private val schedulingLock = Any()
    /** Android CacheBookService.addDownloadData 用同一 Mutex 串行加载缺失目录。 */
    private val tocLoadMutex = Mutex()

    /**
     * Android `CacheBookService` 的线程池大小是
     * `min(AppConfig.threadCount, AppConst.MAX_THREAD)`；默认配置最终为 9。
     *
     * 这里是整机共享的正文抓取闸门。单书不再额外限制为 4，也不会再因为一批中的慢章节
     * 阻塞下一批：所有缓存书共同竞争这 9 个槽位。抓取失败后的退避等待不占槽位，
     * 因而重试不会挡住其他章节。
     */
    private val globalGate = Semaphore(BOOK_CACHE_DEFAULT_CONCURRENCY)
    private val automaticSources = ConcurrentHashMap<String, Mutex>()
    private val automaticWakeups = Channel<Unit>(Channel.CONFLATED)

    fun start() {
        if (started.getAndSet(true)) return
        // 启动续做必须限流：整架书的缓存任务若一次性全部 launch，
        // 会把 Dispatchers.IO 线程池占满，导致服务无法响应任何请求。
        val pending = database.cacheRequests()
        val manual = pending.filterNot { it.automatic }
        if (manual.isNotEmpty()) {
            log("book cache resume: ${manual.size} manual book(s) pending (global concurrency=$BOOK_CACHE_DEFAULT_CONCURRENCY)")
            scope.launch {
                manual.chunked(RESUME_BATCH_SIZE).forEach { batch ->
                    batch.forEach(::enqueue)
                    delay(RESUME_BATCH_DELAY_MS)
                }
            }
        }
        if (autoCacheEnabled) scope.launch { automaticLoop() }
    }
    fun stop() {
        started.set(false)
        scope.cancel()
    }

    internal fun wakeAutomaticQueue() {
        automaticWakeups.trySend(Unit)
    }

    internal fun automaticSourceLock(sourceId: String): Mutex =
        automaticSources.computeIfAbsent(sourceId) { Mutex() }

    private suspend fun automaticLoop() {
        log("automatic book cache enabled: one chapter per source at a time")
        while (scope.isActive) {
            runCatching {
                synchronized(schedulingLock) {
                    val occupiedSources = jobs.keys.mapTo(mutableSetOf()) { it.substringBefore('\u0000') }
                    automaticSources.forEach { (sourceId, mutex) ->
                        if (mutex.isLocked) occupiedSources.add(sourceId)
                    }
                    for (candidate in database.autoCacheCandidates()) {
                        if (jobs.size >= BOOK_CACHE_DEFAULT_CONCURRENCY) break
                        if (occupiedSources.add(candidate.sourceId) && enqueue(candidate)) {
                            log("automatic book cache started: ${candidate.bookUrl}")
                        }
                    }
                }
            }.onFailure {
                if (it is CancellationException) throw it
                log("automatic book cache scan failed: ${it.message}")
            }
            withTimeoutOrNull(AUTO_CACHE_SCAN_DELAY_MS) { automaticWakeups.receive() }
        }
    }

    private fun isLocalBook(sourceId: String, bookUrl: String): Boolean {
        return sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID ||
            bookUrl.startsWith("local://") ||
            bookUrl.startsWith("content://") ||
            bookUrl.startsWith("file://")
    }

    fun enqueue(book: CachedBookRequest): Boolean {
        if (isLocalBook(book.sourceId, book.bookUrl)) {
            database.ensureLocalBookStatusReady(book.sourceId, book.bookUrl)
            return false
        }
        val request = book.copy(
            chapterConcurrency = if (book.automatic) 1 else {
                (book.chapterConcurrency ?: BOOK_CACHE_DEFAULT_CONCURRENCY)
                    .coerceIn(BOOK_CACHE_MIN_CONCURRENCY, BOOK_CACHE_MAX_CONCURRENCY)
            },
        )
        val key = "${book.sourceId}\u0000${book.bookUrl}"
        synchronized(schedulingLock) {
            if (jobs[key]?.isActive == true) return false
            database.beginBookCache(
                request.sourceId, request.bookUrl, 0,
                request.startIndex, request.endIndex, request.count,
                request.chapterConcurrency, request.automatic,
            )
            val job = scope.launch(start = CoroutineStart.LAZY) { cache(request) }
            jobs[key] = job
            job.invokeOnCompletion {
                jobs.remove(key, job)
                wakeAutomaticQueue()
            }
            job.start()
        }
        return true
    }

    fun cancel(sourceId: String, bookUrl: String) {
        synchronized(schedulingLock) {
            jobs.remove("$sourceId\u0000$bookUrl")?.cancel()
            if (!isLocalBook(sourceId, bookUrl)) {
                database.finishBookCache(sourceId, bookUrl, "已取消缓存")
            }
        }
    }

    /** Pause a durable text-cache task. Cached chapters and its original range remain in SQLite. */
    fun pause(sourceId: String, bookUrl: String): Boolean = synchronized(schedulingLock) {
        if (isLocalBook(sourceId, bookUrl)) return@synchronized false
        jobs.remove("$sourceId\u0000$bookUrl")?.cancel()
        database.setBookCacheState(sourceId, bookUrl, "paused", "已暂停缓存")
    }

    /** Retry a paused or failed task from its persisted request range and cached chapters. */
    fun retry(sourceId: String, bookUrl: String): Boolean = synchronized(schedulingLock) {
        if (isLocalBook(sourceId, bookUrl) || jobs["$sourceId\u0000$bookUrl"]?.isActive == true) return@synchronized false
        if (!database.setBookCacheState(sourceId, bookUrl, "pending", null)) return@synchronized false
        val request = database.cacheRequest(sourceId, bookUrl) ?: return@synchronized false
        if (request.automatic && autoCacheEnabled) {
            wakeAutomaticQueue()
            true
        } else {
            enqueue(request)
        }
    }

    private suspend fun cache(book: CachedBookRequest) {
        if (book.automatic) {
            automaticSourceLock(book.sourceId).withLock { cacheInternal(book) }
        } else {
            cacheInternal(book)
        }
    }

    private suspend fun cacheInternal(book: CachedBookRequest) {
        val jobContext = coroutineContext
        if (isLocalBook(book.sourceId, book.bookUrl)) {
            database.ensureLocalBookStatusReady(book.sourceId, book.bookUrl)
            return
        }
        try {
            val source = database.getSource(book.sourceId) ?: throw IllegalArgumentException("书源不存在")
            // 离线缓存也必须带书籍上下文：缓存的正文/目录要跟在线读**一模一样**，
            // 否则按音色/线路参数分派的源会缓存出错版本的正文（Legado 的 CacheBook 同样带着 Book）。
            val bookContext = database.bookContext(book.sourceId, book.bookUrl)
            // 取目录与阅读路径**共用同一实现**（含 details 回退）：聚合源书架里存的 toc_url
            // 可能是一次性错误载荷，过去这里只试一次 ⇒ 出现"能读不能缓存"（实测 462 章的书缓存 0 章）。
            val chapters = tocLoadMutex.withLock {
                withContext(Dispatchers.IO) {
                    resolveBookChapters(
                        database, runner, book.sourceId, book.bookUrl, source.json, bookContext,
                        tocUrlHint = book.tocUrl,
                    )
                }
            }
            database.persistBookVariables(bookContext)
            if (chapters.isEmpty()) throw RuleExecutionException("目录规则未提取到章节")

            // Slice chapters by range if specified
            val targetChapters = if (book.startIndex != null || book.endIndex != null || book.count != null) {
                val start = (book.startIndex ?: 0).coerceIn(0, chapters.size)
                val end = if (book.endIndex != null) {
                    (book.endIndex + 1).coerceIn(start, chapters.size)
                } else if (book.count != null) {
                    (start + book.count).coerceIn(start, chapters.size)
                } else {
                    chapters.size
                }
                if (start < end) chapters.subList(start, end) else emptyList()
            } else {
                chapters
            }

            // Android compares chapter identity after URL options have been consumed.
            // Two rows for `chapter.html` and `chapter.html,{"webView":true}` are one chapter.
            val currentCacheKeys = chapterCacheKeys(chapters)
            val alreadyCachedKeys = database.cachedChapterUrls(book.sourceId, book.bookUrl)
                .asSequence()
                .map(SourceUrlOptions::cacheKey)
                .filter { it.isNotBlank() }
                .toSet()
            val cachedProgressKeys = ConcurrentHashMap.newKeySet<String>()
            cachedProgressKeys.addAll(currentCacheKeys.intersect(alreadyCachedKeys))
            val initialCachedCount = cachedProgressKeys.size
            val progressLock = Any()
            // Android CacheBookModel.addDownload 按请求区间从低到高加入 LinkedHashSet，
            // 后台缓存不按阅读进度重排；卷标题同样不抓正文（CacheBook.download 直接跳过 volume）。
            val remaining = targetChapters.filter { chapter ->
                !chapter.isVolume && SourceUrlOptions.cacheKey(chapter.url) !in alreadyCachedKeys
            }.distinctBy { SourceUrlOptions.cacheKey(it.url) }

            val failures = AtomicInteger(0)
            // 只记**第一条**失败原因：过去这里静默只计数，用户只看到"N 章未缓存"，
            // 完全无从判断是上游登录态、网络不通还是规则问题。
            val firstFailure = AtomicReference<String?>(null)
            // 插图预热的战果：**单张失败绝不影响正文缓存**（离线读文字优先），只计数 + 记首条原因
            val illustrationsCached = AtomicInteger(0)
            val illustrationFailures = AtomicInteger(0)
            val firstIllustrationFailure = AtomicReference<String?>(null)

            val bookName = database.listBookshelf().firstOrNull { it.sourceId == book.sourceId && it.bookUrl == book.bookUrl }?.name
            val chapterConcurrency = (book.chapterConcurrency ?: BOOK_CACHE_DEFAULT_CONCURRENCY)
                .coerceIn(BOOK_CACHE_MIN_CONCURRENCY, BOOK_CACHE_MAX_CONCURRENCY)
            synchronized(schedulingLock) {
                jobContext.ensureActive()
                database.beginBookCache(
                    book.sourceId,
                    book.bookUrl,
                    chapters.size,
                    book.startIndex,
                    book.endIndex,
                    book.count,
                    chapterConcurrency,
                    book.automatic,
                )
            }
            coroutineScope {
                if (remaining.isNotEmpty()) {
                    // Android 的失败章节会重新加入等待集合；这里同样使用 FIFO 队列。
                    // 1 秒退避后追加到队尾，因此不会立即再次打同一错误，也不会占住全局抓取槽。
                    val queue = Channel<ChapterCacheAttempt>(Channel.UNLIMITED)
                    val pending = AtomicInteger(remaining.size)
                    remaining.forEach { queue.send(ChapterCacheAttempt(it)) }

                    fun finishTask() {
                        if (pending.decrementAndGet() == 0) queue.close()
                    }

                    repeat(minOf(chapterConcurrency, remaining.size)) {
                        launch {
                            for (task in queue) {
                                try {
                                    cacheChapter(
                                        sourceJson = source.json,
                                        book = book,
                                        chapter = task.chapter,
                                        bookName = bookName,
                                        bookContext = bookContext,
                                        illustrationsCached = illustrationsCached,
                                        illustrationFailures = illustrationFailures,
                                        firstIllustrationFailure = firstIllustrationFailure,
                                        progressLock = progressLock,
                                        cachedProgressKeys = cachedProgressKeys,
                                    )
                                    finishTask()
                                } catch (error: Throwable) {
                                    if (error is CancellationException) throw error
                                    if (task.attempt < MAX_CHAPTER_ATTEMPTS) {
                                        log(
                                            "chapter cache retry: ${task.chapter.url}, " +
                                                "attempt=${task.attempt}/$MAX_CHAPTER_ATTEMPTS, " +
                                                "error=${error.message}",
                                        )
                                        pending.incrementAndGet()
                                        delay(CHAPTER_RETRY_DELAY_MS)
                                        queue.send(task.copy(attempt = task.attempt + 1))
                                        finishTask()
                                    } else {
                                        if (firstFailure.compareAndSet(null, "${task.chapter.url}: ${error.message}")) {
                                            log(
                                                "chapter cache failed: ${task.chapter.url}, " +
                                                    "attempts=$MAX_CHAPTER_ATTEMPTS, error=${error.message}",
                                            )
                                        }
                                        failures.incrementAndGet()
                                        finishTask()
                                    }
                                }
                            }
                        }
                    }
                }
            }

            val totalFailures = failures.get()
            val error = if (totalFailures == 0) null else {
                val reason = firstFailure.get()
                if (reason == null) "$totalFailures 章未缓存" else "$totalFailures 章未缓存（首条原因：$reason）"
            }
            synchronized(schedulingLock) {
                jobContext.ensureActive()
                database.finishBookCache(
                    book.sourceId,
                    book.bookUrl,
                    error,
                    followCatalogFrom = currentCacheKeys.takeIf { autoCacheEnabled },
                )
            }
            val illustrationNote = if (illustrationFailures.get() == 0) {
                "插图=$illustrationsCached"
            } else {
                "插图=$illustrationsCached（失败 ${illustrationFailures.get()}，首条原因：${firstIllustrationFailure.get()}）"
            }
            log(
                "book cache completed: ${book.bookUrl}, chapters=${chapters.size}, skipped=$initialCachedCount, " +
                    "cached=${cachedProgressKeys.size}, " +
                    "concurrency=$chapterConcurrency, failures=$totalFailures, $illustrationNote",
            )
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            synchronized(schedulingLock) {
                jobContext.ensureActive()
                database.finishBookCache(book.sourceId, book.bookUrl, error.message ?: "缓存失败")
            }
            log("book cache failed: ${book.bookUrl}, error=${error.message}")
        }
    }

    /**
     * 抓取并落盘一章。全局闸门只包住正文请求，不含成功后的数据库写入、插图和重试退避；
     * 这样一页很慢的正文不会同时占住一个抓取槽和一个额外等待槽。
     */
    private suspend fun cacheChapter(
        sourceJson: String,
        book: CachedBookRequest,
        chapter: Chapter,
        bookName: String?,
        bookContext: BookContext,
        illustrationsCached: AtomicInteger,
        illustrationFailures: AtomicInteger,
        firstIllustrationFailure: AtomicReference<String?>,
        progressLock: Any,
        cachedProgressKeys: MutableSet<String>,
    ) {
        // 每次尝试都使用新的变量副本：第一次尝试中规则写入的临时状态不能污染重试。
        val contentBook = bookContext.copy(variables = bookContext.variables.toMutableMap())
        val content = globalGate.withPermit {
            withContext(Dispatchers.IO) {
                runner.content(sourceJson, chapter.url, bookName, contentBook)
            }
        }
        // setUseReplaceRule 落库已由 content() 内部完成；同步回共享上下文，供后续章节读取。
        bookContext.useReplaceRule = contentBook.useReplaceRule
        val chapterCacheKey = SourceUrlOptions.cacheKey(chapter.url)
        synchronized(progressLock) {
            val nextCachedCount = if (chapterCacheKey in cachedProgressKeys) {
                cachedProgressKeys.size
            } else {
                cachedProgressKeys.size + 1
            }
            database.cacheBookContent(
                book.sourceId, book.bookUrl, chapter.url,
                content.copy(title = content.title ?: chapter.title),
                cachedChapterCount = nextCachedCount,
            )
            cachedProgressKeys.add(chapterCacheKey)
        }
        // cacheBookContent 在同一写锁内同步章节正文和 book_cache_status.cached_chapters，
        // 因此这里不再做秒级节流。节流留下的旧值会在慢章节等待期间被界面一直显示，
        // 看起来像缓存已经停止；分离更新还可能被并发请求用较小值覆盖。
        // 正文里的插图随章节一起落盘；插图失败只计数，不影响本章正文成功。
        prefetchIllustrations(sourceJson, book, chapter.index, chapter.url, content.content)
            ?.let { outcome ->
                illustrationsCached.addAndGet(outcome.cached)
                if (outcome.failed > 0) {
                    illustrationFailures.addAndGet(outcome.failed)
                    outcome.firstError?.let { firstIllustrationFailure.compareAndSet(null, it) }
                }
            }
    }

    /**
     * 把一章正文里的插图抓下来落盘（离线阅读要用）。
     *
     * 三条硬约束（都来自历史事故，改了就会复发）：
     * 1. **任何失败都只返回计数与首条原因**，绝不抛出 —— 插图是正文的附属物，
     *    "图挂了"不该让整章正文被判为缓存失败；
     * 2. 抓取**必须**走 [MangaImageFetcher]（书源 `header` + 章节页 `Referer` + Cookie、
     *    全局限流、gzip 魔数解压、单图体积上限、图片魔数校验都在那里）——缺 Referer 必裂图；
     * 3. 单章图片数封顶 [MAX_ILLUSTRATIONS_PER_CHAPTER]，防止一页几十张图的章把队列占满。
     *
     * @return null 表示当前实例没接插图缓存（功能未启用）
     */
    private suspend fun prefetchIllustrations(
        sourceJson: String,
        book: CachedBookRequest,
        chapterIndex: Int,
        chapterUrl: String,
        content: String,
    ): IllustrationPrefetchOutcome? {
        val cache = illustrationCache ?: return null
        val fetcher = illustrationFetcher ?: return null
        val urls = runCatching { IllustrationMarkup.urlsIn(content) }.getOrDefault(emptyList())
        if (urls.isEmpty()) return IllustrationPrefetchOutcome(0, 0, null)
        // 正文顺序决定章节内序号（登记是幂等的：已登记的号不会被改写）
        val rows = runCatching {
            cache.registerChapter(book.sourceId, book.bookUrl, chapterUrl, chapterIndex, urls)
        }.getOrElse { error ->
            return IllustrationPrefetchOutcome(0, 1, "$chapterUrl 插图登记失败：${error.message}")
        }
        var cached = 0
        var failed = 0
        var firstError: String? = null
        // 书源请求头解析失败只会返回空表（静默降级），Referer 才是防盗链的主判据
        val headers by lazy { runner.mediaHeaders(sourceJson, book.sourceId) }
        // 书源声明的图片解密（Android `ImageUtils` 的 ruleContent.imageDecode）
        val decoder by lazy { runner.imageDecoder(sourceJson, isCover = false) }
        val referer = chapterUrl.takeIf { it.startsWith("http") }
        for (row in rows.take(MAX_ILLUSTRATIONS_PER_CHAPTER)) {
            if (cache.getByKey(row.urlHash) != null) {
                cached++
                continue
            }
            val fetched = fetcher.fetch(row.upstreamUrl, headers, referer, decoder)
            if (fetched == null) {
                failed++
                if (firstError == null) firstError = "${row.upstreamUrl}（上游抓取失败或内容不是图片）"
                continue
            }
            runCatching {
                cache.put(
                    sourceId = book.sourceId,
                    bookUrl = book.bookUrl,
                    chapterUrl = chapterUrl,
                    upstreamUrl = row.upstreamUrl,
                    contentType = fetched.contentType,
                    bytes = fetched.bytes,
                    chapterIndex = chapterIndex,
                    segmentIndex = row.segmentIndex,
                )
                cached++
            }.onFailure { error ->
                failed++
                if (firstError == null) firstError = "${row.upstreamUrl}（落盘失败：${error.message}）"
            }
        }
        return IllustrationPrefetchOutcome(cached, failed, firstError)
    }

    /** 一章插图预热的战果（`cached` 张落盘、`failed` 张失败、首条失败原因）。 */
    private data class IllustrationPrefetchOutcome(val cached: Int, val failed: Int, val firstError: String?)

    private data class ChapterCacheAttempt(val chapter: Chapter, val attempt: Int = 1)

    private companion object {
        /** Android 失败章节累计第 3 次失败后不再重排，即最多尝试 3 次。 */
        const val MAX_CHAPTER_ATTEMPTS = 3
        const val CHAPTER_RETRY_DELAY_MS = 1_000L
        /**
         * 单章插图预热的张数上限。
         *
         * 图片书 / 图文混排的"章节"动辄几十张图，无上限时一本书的后台缓存会退化成
         * 「章节队列被图片占满」；超出部分仍在**在线阅读时按需下载并落盘**（不丢功能）。
         */
        const val MAX_ILLUSTRATIONS_PER_CHAPTER = 20
        /** 启动续做时每批投放的书数，避免一次性占满线程池。 */
        const val RESUME_BATCH_SIZE = 3
        /** 批次之间的让出间隔，给前台请求留出调度机会。 */
        const val RESUME_BATCH_DELAY_MS = 300L
        const val AUTO_CACHE_SCAN_DELAY_MS = 5_000L
    }
}
