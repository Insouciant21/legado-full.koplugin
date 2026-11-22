package io.legado.server

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Android `MainViewModel.upToc` / `updateToc` 的服务端实现。
 *
 * 关键边界与 Android 一致：
 * - 跳过本地书与 `canUpdate=false`；
 * - `onlyFinished=true` 时只处理没有未读章节的书；
 * - 同一批内按书籍身份去重，最多 9 本并发；
 * - 目录刷新绕过 Server 的 TOC 缓存，但成功后仍用新目录覆盖缓存；
 * - 失败只置 `updateError`，保留旧目录、总章数与最新章信息；
 * - 成功更新总章数、末章标题与检查时间，新增章节才刷新 `lastCheckCount/latestChapterTime`。
 */
class BookshelfRefreshService(
    private val database: Database,
    private val runner: RuleRunner,
    private val autoCacheEnabled: Boolean = true,
    private val onCacheQueued: () -> Unit = {},
    private val log: (String) -> Unit,
) {
    private data class Entry(
        val item: BookshelfItem,
        var state: String = "queued",
        var error: String? = null,
        var totalChapters: Int = item.catalogChapters,
        var newChapters: Int = 0,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    @Volatile private var state = "idle"
    @Volatile private var activeJob: Job? = null

    fun stop() {
        scope.cancel()
    }

    fun status(): BookshelfRefreshStatus = synchronized(lock) {
        val snapshot = entries.values.toList()
        BookshelfRefreshStatus(
            state = state,
            total = snapshot.size,
            completed = snapshot.count { it.state == "succeeded" || it.state == "failed" },
            succeeded = snapshot.count { it.state == "succeeded" },
            failed = snapshot.count { it.state == "failed" },
            items = snapshot.map {
                BookshelfRefreshItemStatus(
                    sourceId = it.item.sourceId,
                    bookUrl = it.item.bookUrl,
                    name = it.item.name,
                    state = it.state,
                    error = it.error,
                    previousChapters = it.item.catalogChapters,
                    totalChapters = it.totalChapters,
                    newChapters = it.newChapters,
                )
            },
        )
    }

    fun start(request: BookshelfRefreshRequest): BookshelfRefreshStatus = synchronized(lock) {
        if (activeJob?.isActive == true) return status()

        val shelf = database.listBookshelf().associateBy { key(it.sourceId, it.bookUrl) }
        val requested = if (request.books.isEmpty()) {
            shelf.values.toList()
        } else {
            request.books.distinctBy { key(it.sourceId, it.bookUrl) }
                .mapNotNull { shelf[key(it.sourceId, it.bookUrl)] }
        }
        val eligible = requested.distinctBy { key(it.sourceId, it.bookUrl) }.filter { item ->
            item.canUpdate &&
                !isLocal(item) &&
                (!request.onlyFinished || unreadChapterCount(item) == 0)
        }

        entries.clear()
        eligible.forEach { entries[key(it.sourceId, it.bookUrl)] = Entry(it) }
        state = if (entries.isEmpty()) "idle" else "running"
        if (entries.isEmpty()) {
            activeJob = null
            return status()
        }

        val batch = entries.values.toList()
        val concurrency = request.concurrency.coerceIn(1, 9)
        log("bookshelf refresh queued: ${batch.size} book(s), concurrency=$concurrency, onlyFinished=${request.onlyFinished}")
        activeJob = scope.launch {
            try {
                notifySources(batch, "startShelfRefresh")
                val permits = Semaphore(concurrency)
                coroutineScope {
                    batch.map { entry ->
                        launch(Dispatchers.IO) {
                            permits.withPermit { refreshOne(entry) }
                        }
                    }.joinAll()
                }
            } finally {
                try {
                    notifySources(batch, "endShelfRefresh")
                } finally {
                    synchronized(lock) {
                        state = "completed"
                        activeJob = null
                    }
                    val snapshot = status()
                    log("bookshelf refresh completed: success=${snapshot.succeeded} failed=${snapshot.failed}")
                }
            }
        }
        status()
    }

    private suspend fun refreshOne(entry: Entry) {
        synchronized(lock) { entry.state = "running" }
        val item = entry.item
        try {
            val source = database.getSource(item.sourceId)
                ?: throw IllegalStateException("书源不存在")
            val context = database.bookContext(item.sourceId, item.bookUrl)
            val chapters = refreshToc(source, context, item)
            synchronized(lock) {
                entry.state = "succeeded"
                entry.error = null
                entry.totalChapters = chapters.size
                entry.newChapters = (chapters.size - item.catalogChapters).coerceAtLeast(0)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            val persistError = runCatching {
                database.markBookshelfRefreshFailed(item.sourceId, item.bookUrl)
            }.exceptionOrNull()
            synchronized(lock) {
                entry.state = "failed"
                entry.error = error.message?.take(500) ?: "刷新目录失败"
            }
            val failure = error.message ?: error.javaClass.simpleName
            log("bookshelf refresh failed: ${item.name}: $failure")
            if (persistError != null) {
                log("bookshelf refresh error marker failed: ${item.name}: ${persistError.message ?: persistError.javaClass.simpleName}")
            }
        }
    }

    internal suspend fun refreshToc(
        source: SourceRecord,
        context: BookContext,
        item: BookshelfItem? = database.getBookshelf(context.sourceId, context.bookUrl),
    ): List<Chapter> {
        val bookUrl = context.bookUrl
        // Android 仅在缺少目录地址时先取详情。
        val details = if (context.tocUrl.isNullOrBlank()) {
            runInterruptible(Dispatchers.IO) { runner.details(source.json, bookUrl, context) }
        } else null
        val tocUrlHint = context.tocUrl?.takeIf { it.isNotBlank() } ?: details?.tocUrl
        context.tocUrl = tocUrlHint
        val chapters = resolveBookChapters(
            database = database,
            runner = runner,
            sourceId = source.id,
            bookUrl = bookUrl,
            sourceJson = source.json,
            bookContext = context,
            tocUrlHint = tocUrlHint,
            forceRefresh = true,
        )
        if (chapters.isEmpty()) throw RuleExecutionException("目录为空")
        currentCoroutineContext().ensureActive()
        val tocUrl = context.tocUrl?.trim()?.takeIf { it.isNotEmpty() } ?: bookUrl
        context.tocUrl = tocUrl
        database.persistBookVariables(context)
        if (item == null) {
            database.saveTocCacheAliases(source.id, setOf(bookUrl, tocUrl, context.bookUrl), chapters)
        } else {
            val updated = database.finishBookshelfRefresh(
                item = item,
                tocUrl = tocUrl,
                name = details?.name,
                author = details?.author,
                coverUrl = details?.coverUrl,
                chapters = chapters,
                queueAutomaticCache = autoCacheEnabled,
                resolvedBookUrl = context.bookUrl,
            ) ?: throw IllegalStateException("书籍已离开书架")
            if (updated.cacheState == "pending") onCacheQueued()
        }
        return chapters
    }

    private suspend fun notifySources(batch: List<Entry>, event: String) {
        val bySource = batch.map { it.item }.distinctBy { it.sourceId }.associateBy { it.sourceId }
        coroutineScope {
            bySource.map { (sourceId, _) ->
                async(Dispatchers.IO) {
                    try {
                        val source = database.getSource(sourceId) ?: return@async
                        val finished = withTimeoutOrNull(30_000) {
                            runner.runSourceCallback(source.json, event)
                        }
                        if (finished == null) {
                            log("bookshelf source callback timed out: source=$sourceId event=$event")
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        log("bookshelf source callback failed: source=$sourceId event=$event: ${error.message ?: error.javaClass.simpleName}")
                    }
                }
            }.awaitAll()
        }
    }

    private fun unreadChapterCount(item: BookshelfItem): Int {
        val total = item.catalogChapters
        val index = item.chapterIndex ?: 0
        return (total - index - 1).coerceAtLeast(0)
    }

    private fun isLocal(item: BookshelfItem): Boolean =
        item.sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID ||
            item.bookUrl.startsWith("local://") ||
            item.bookUrl.startsWith("content://") ||
            item.bookUrl.startsWith("file://") ||
            item.bookKind == BookKind.LOCAL.wire

    private fun key(sourceId: String, bookUrl: String) = "$sourceId\u0000$bookUrl"
}
