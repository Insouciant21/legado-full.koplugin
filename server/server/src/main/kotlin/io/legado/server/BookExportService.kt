package io.legado.server

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.nio.charset.Charset
import java.nio.charset.IllegalCharsetNameException
import java.nio.charset.UnsupportedCharsetException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class BookExportException(
    val status: Int,
    val code: String,
    message: String,
) : RuntimeException(message)

data class BookExportDownload(
    val status: BookshelfExportStatus,
    val file: BookshelfExportFile,
    val path: Path,
)

/**
 * 服务端书架导出。
 *
 * 产品语义对齐 Android：
 * - 多书任务按提交顺序逐本执行（[BOOK_CONCURRENCY] = 1）；
 * - 单本默认逐章；`parallel=true` 时最多 9 章并发；
 * - 正文缺失按 Android `CacheBook` 的方式重试 3 次、每次间隔 1 秒；最终失败仍保留章节结构；
 * - 支持 TXT、EPUB、EPUB 范围与按章节数拆分；
 * - 导出时重新应用当前正文/标题替换规则、卷结构、简介、作者、封面与 EPUB 元数据。
 */
class BookExportService(
    private val database: Database,
    private val runner: RuleRunner,
    private val coverCache: CoverCache,
    private val illustrationCache: IllustrationCache?,
    private val imageFetcher: MangaImageFetcher,
    private val directory: Path,
    private val pushHandler: ((KindlePushExportInput) -> KindlePushEnqueueResult)? = null,
    private val now: () -> Instant = Instant::now,
    private val log: (String) -> Unit = {},
) {
    private data class ExportScope(
        val raw: String,
        /** Android `parseScope` 的 0 起始结果。 */
        val indexes: LinkedHashSet<Int>,
    )

    private data class ExportRequest(
        val sourceId: String,
        val bookUrl: String,
        val format: String,
        val parallel: Boolean,
        val useReplace: Boolean,
        val includeChapterTitle: Boolean,
        val scope: ExportScope?,
        val epubSize: Int,
        val charset: Charset,
        val pushToKindle: Boolean,
        val kindleDeviceIds: List<String>,
    )

    private data class JobState(
        val jobId: String,
        val request: ExportRequest,
        val bookName: String,
        var status: String = "queued",
        var totalChapters: Int = 0,
        var selectedChapters: Int = 0,
        var processedChapters: Int = 0,
        var completedChapters: Int = 0,
        var failedChapters: Int = 0,
        var imageFailures: Int = 0,
        var kindleDeliveryId: String? = null,
        var kindlePushState: String? = null,
        var kindlePushMessage: String? = null,
        var message: String = "等待导出",
        var artifacts: List<Artifact> = emptyList(),
        val createdAt: String,
        var updatedAt: String,
    )

    private data class Artifact(
        val fileId: String,
        val fileName: String,
        val contentType: String,
        val path: Path,
        val sizeBytes: Long,
        val sha256: String,
    )

    private data class ImageAsset(
        val entryName: String,
        val mediaType: String,
    )

    private data class EpubResource(
        val id: String,
        val href: String,
        val mediaType: String,
        val bytes: ByteArray? = null,
        val source: Path? = null,
    )

    private data class EpubChapterPage(
        val index: Int,
        val chapter: AcquiredChapter,
    )

    private data class AndroidEpubAssets(
        val chapterTemplate: String,
        val introTemplate: String,
        val coverTemplate: String,
        val mainCss: ByteArray,
        val fontsCss: ByteArray,
        val logo: ByteArray,
    )

    private data class AcquiredChapter(
        val selectionIndex: Int,
        val chapterPosition: Int,
        val chapter: Chapter,
        val title: String,
        val bodyFile: Path,
        val missing: Boolean,
        /** 正文内原始图片 URL → EPUB 资源路径；`null` 表示图片下载失败。 */
        val imageEntries: Map<String, String?>,
    )

    private data class AcquisitionContext(
        val item: BookshelfItem,
        val source: SourceRecord?,
        val bookContext: BookContext,
        val rules: List<ReplaceRule>,
        val useReplace: Boolean,
        val workspace: Path,
        val imageAssets: ConcurrentHashMap<String, ImageAsset>,
        val imageFailures: AtomicInteger,
        val resolveImage: suspend (String, String?, Chapter) -> ImageAsset?,
    )

    private data class StartedJob(val jobId: String, val created: Boolean)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val jobs = LinkedHashMap<String, JobState>()
    private val activeByBook = HashMap<String, String>()
    private val jobGate = Semaphore(BOOK_CONCURRENCY)
    private val androidEpubAssets by lazy {
        AndroidEpubAssets(
            chapterTemplate = resourceText("/epub/chapter.html"),
            introTemplate = resourceText("/epub/intro.html"),
            coverTemplate = resourceText("/epub/cover.html"),
            mainCss = resourceBytes("/epub/main.css"),
            fontsCss = resourceBytes("/epub/fonts.css"),
            logo = resourceBytes("/epub/logo.png"),
        )
    }

    @Volatile
    private var stopped = false

    init {
        resetDirectory()
    }

    fun start(request: BookshelfExportRequest, forcedFormat: String? = null): BookshelfExportStatus {
        if (stopped) fail(503, "export_unavailable", "导出服务正在停止")
        val normalized = normalizeRequest(request, forcedFormat)
        val item = database.listBookshelf().firstOrNull {
            it.sourceId == normalized.sourceId && it.bookUrl == normalized.bookUrl
        } ?: fail(404, "not_found", "书籍不在书架中")

        cleanupExpired()
        val bookKey = "${normalized.sourceId}\u0000${normalized.bookUrl}"
        val started = synchronized(lock) {
            activeByBook[bookKey]?.let { existingId ->
                jobs[existingId]?.takeIf { it.status in ACTIVE_OR_READY }?.let {
                    return@synchronized StartedJob(existingId, false)
                }
            }
            val jobId = UUID.randomUUID().toString().replace("-", "")
            val timestamp = now().truncatedTo(ChronoUnit.SECONDS).toString()
            jobs[jobId] = JobState(
                jobId = jobId,
                request = normalized,
                bookName = item.name,
                createdAt = timestamp,
                updatedAt = timestamp,
            )
            activeByBook[bookKey] = jobId
            StartedJob(jobId, true)
        }
        if (started.created) {
            scope.launch {
                jobGate.withPermit { runJob(started.jobId) }
            }
        }
        return status(started.jobId)
    }

    fun status(jobId: String): BookshelfExportStatus = synchronized(lock) {
        snapshot(jobs[jobId] ?: fail(404, "export_not_found", "导出任务不存在"))
    }

    fun download(jobId: String, fileId: String? = null): BookExportDownload {
        val state = synchronized(lock) {
            val job = jobs[jobId] ?: fail(404, "export_not_found", "导出任务不存在")
            val artifact = if (fileId.isNullOrBlank()) job.artifacts.firstOrNull()
            else job.artifacts.firstOrNull { it.fileId == fileId }
            if (job.status != "ready") fail(409, "export_not_ready", "导出尚未完成")
            artifact ?: fail(404, "export_file_not_found", "导出文件不存在")
            val status = snapshot(job)
            val exportFile = status.files.first { it.fileId == artifact.fileId }
            Triple(job, exportFile, artifact.path)
        }
        if (!Files.isRegularFile(state.third)) {
            fail(503, "export_unavailable", "导出文件暂不可用")
        }
        return BookExportDownload(
            status = snapshot(state.first),
            file = state.second,
            path = state.third,
        )
    }

    fun stop() {
        stopped = true
        scope.cancel()
    }

    private fun normalizeRequest(request: BookshelfExportRequest, forcedFormat: String?): ExportRequest {
        val sourceId = request.sourceId.trim()
        val bookUrl = request.bookUrl.trim()
        if (sourceId.isEmpty() || bookUrl.isEmpty()) fail(400, "invalid_bookshelf", "缺少书籍标识")
        val format = (forcedFormat ?: request.format).trim().lowercase().ifBlank { "txt" }
        if (format !in setOf("txt", "epub")) {
            fail(400, "unsupported_export_format", "导出格式仅支持 txt 或 epub")
        }
        if (format == "epub" && request.epubSize <= 0) {
            fail(400, "invalid_epub_size", "epubSize 必须大于 0")
        }
        if (format == "txt" && !request.epubScope.isNullOrBlank()) {
            fail(400, "invalid_epub_scope", "章节范围仅适用于 EPUB 导出")
        }
        if (request.pushToKindle && format != "epub") {
            fail(400, "kindle_requires_epub", "Kindle 自动推送仅支持 EPUB")
        }
        val charset = if (format == "txt") {
            try {
                Charset.forName(request.charset.ifBlank { "UTF-8" })
            } catch (_: IllegalCharsetNameException) {
                fail(400, "invalid_charset", "TXT 编码名称无效")
            } catch (_: UnsupportedCharsetException) {
                fail(400, "invalid_charset", "服务端不支持此 TXT 编码")
            }
        } else {
            Charsets.UTF_8
        }
        val exportScope = request.epubScope
            ?.takeIf { it.isNotBlank() }
            ?.let { ExportScope(it, parseScope(it)) }
        return ExportRequest(
            sourceId = sourceId,
            bookUrl = bookUrl,
            format = format,
            parallel = request.parallel,
            useReplace = request.useReplace,
            includeChapterTitle = request.includeChapterTitle,
            scope = exportScope,
            epubSize = request.epubSize,
            charset = charset,
            pushToKindle = request.pushToKindle,
            kindleDeviceIds = request.kindleDeviceIds.map(String::trim).filter(String::isNotEmpty).distinct(),
        )
    }

    private fun parseScope(raw: String): LinkedHashSet<Int> {
        val result = linkedSetOf<Int>()
        raw.split(',').map { it.trim() }.filter { it.isNotEmpty() }.forEach { token ->
            val range = token.split('-')
            if (range.size == 2) {
                val left = range[0].trim().toIntOrNull()
                val right = range[1].trim().toIntOrNull()
                if (left == null || right == null) fail(400, "invalid_epub_scope", "章节范围格式无效：$token")
                if (left <= right) {
                    for (index in left..right) if (index > 0) result.add(index - 1)
                }
            } else {
                val index = token.toIntOrNull()
                    ?: fail(400, "invalid_epub_scope", "章节范围格式无效：$token")
                if (index > 0) result.add(index - 1)
            }
        }
        if (result.isEmpty()) fail(400, "invalid_epub_scope", "章节范围为空")
        return result
    }

    private suspend fun runJob(jobId: String) {
        val workspace = directory.resolve("$jobId.tmp")
        var shelfItem: BookshelfItem? = null
        try {
            update(jobId) {
                it.status = "running"
                it.message = "正在读取目录"
            }
            val job = synchronized(lock) {
                jobs[jobId] ?: fail(404, "export_not_found", "导出任务不存在")
            }
            val item = database.listBookshelf().firstOrNull {
                it.sourceId == job.request.sourceId && it.bookUrl == job.request.bookUrl
            } ?: fail(404, "not_found", "书籍已不在书架中")
            shelfItem = item
            val localBook = BookKind.isLocalRef(item.sourceId, item.bookUrl)
            val source = if (localBook) null else {
                database.getSource(item.sourceId) ?: fail(404, "source_not_found", "书源不存在")
            }
            val bookContext = withContext(Dispatchers.IO) {
                database.bookContext(item.sourceId, item.bookUrl)
            }
            val details = loadDetails(item, source, bookContext)
            val chapters = withContext(Dispatchers.IO) {
                if (localBook) {
                    database.getTocCache(item.sourceId, item.tocUrl)
                        ?: database.getTocCache(item.sourceId, item.bookUrl)
                        ?: database.getCachedChaptersFallback(item.sourceId, item.bookUrl)
                } else {
                    resolveBookChapters(
                        database = database,
                        runner = runner,
                        sourceId = item.sourceId,
                        bookUrl = item.bookUrl,
                        sourceJson = source!!.json,
                        bookContext = bookContext,
                        tocUrlHint = item.tocUrl,
                    )
                }
            }
            if (chapters.isEmpty()) fail(502, "toc_empty", "目录为空，无法导出")

            val selectedPositions = if (job.request.scope == null) {
                chapters.indices.toList()
            } else {
                chapters.indices.filter { it in job.request.scope.indexes }
            }
            if (selectedPositions.isEmpty()) fail(400, "empty_export_scope", "章节范围未选中任何章节")
            val chapterConcurrency = if (job.request.parallel) PARALLEL_CHAPTER_CONCURRENCY else 1
            update(jobId) {
                it.totalChapters = chapters.size
                it.selectedChapters = selectedPositions.size
                it.message = "目录解析完成，将导出 ${selectedPositions.size} 章"
                it.updatedAt = now().toString()
            }

            if (!localBook) {
                database.beginBookCache(
                    sourceId = item.sourceId,
                    bookUrl = item.bookUrl,
                    total = chapters.size,
                    startIndex = selectedPositions.first(),
                    endIndex = selectedPositions.last(),
                )
            } else {
                database.ensureLocalBookStatusReady(item.sourceId, item.bookUrl)
            }

            val parsedSource = source?.let { runCatching { SourceCodec.parse(it.json) }.getOrNull() }
            val sourceUrl = if (localBook) "local://" else parsedSource?.url ?: item.sourceId
            val rules = database.getEnabledReplaceRulesForScope(
                item.name,
                sourceUrl,
                parsedSource?.name,
            )
            val effectiveReplace = job.request.useReplace && database.getUseReplaceRule(item.sourceId, item.bookUrl)

            Files.createDirectories(workspace.resolve("processed"))
            Files.createDirectories(workspace.resolve("Images"))
            val imageAssets = ConcurrentHashMap<String, ImageAsset>()
            val imageJobs = ConcurrentHashMap<String, Deferred<ImageAsset?>>()
            val imageFailures = AtomicInteger(0)
            val contentFailures = ConcurrentLinkedQueue<Pair<String, String>>()
            val acquired = arrayOfNulls<AcquiredChapter>(selectedPositions.size)

            coroutineScope {
                val mediaHeaders = source?.let {
                    runCatching { runner.mediaHeaders(it.json, item.sourceId) }
                        .onFailure { error ->
                            log("book export media headers failed: ${item.bookUrl.take(160)}, ${error.message}")
                        }
                        .getOrDefault(emptyMap())
                }.orEmpty()
                val imageDecoder = source?.let {
                    runCatching {
                        runner.imageDecoder(it.json, isCover = false, book = bookContext)
                    }.getOrNull()
                }
                suspend fun resolveImage(url: String, referer: String?, chapter: Chapter): ImageAsset? {
                    val deferred = imageJobs.computeIfAbsent(url) {
                        async {
                            fetchImage(
                                url = url,
                                referer = referer,
                                item = item,
                                workspace = workspace,
                                mediaHeaders = mediaHeaders,
                                decoder = imageDecoder,
                                chapter = chapter,
                            ).also { asset ->
                                if (asset == null) imageFailures.incrementAndGet()
                                else imageAssets[url] = asset
                            }
                        }
                    }
                    return deferred.await()
                }
                val context = AcquisitionContext(
                    item = item,
                    source = source,
                    bookContext = bookContext,
                    rules = rules,
                    useReplace = effectiveReplace,
                    workspace = workspace,
                    imageAssets = imageAssets,
                    imageFailures = imageFailures,
                    resolveImage = ::resolveImage,
                )
                val gate = Semaphore(chapterConcurrency)
                selectedPositions.withIndex().chunked(ACQUISITION_BATCH_SIZE).forEach { batch ->
                    batch.map { (selectionIndex, chapterPosition) ->
                        async {
                            gate.withPermit {
                                val chapter = chapters[chapterPosition]
                                val result = acquireChapter(
                                    selectionIndex = selectionIndex,
                                    chapterPosition = chapterPosition,
                                    chapter = chapter,
                                    context = context,
                                )
                                if (result.missing) contentFailures.add(chapter.title to "正文下载失败")
                                chapterFinished(
                                    jobId = jobId,
                                    success = !result.missing,
                                    imageFailures = imageFailures.get(),
                                )
                                result
                            }
                        }
                    }.awaitAll().forEach { result ->
                        acquired[result.selectionIndex] = result
                    }
                }
            }

            database.persistBookVariables(bookContext)
            val completed = acquired.filterNotNull().sortedBy { it.selectionIndex }
            val failed = completed.count { it.missing }
            if (!localBook) {
                val error = contentFailures.take(3).joinToString("；") { (title, reason) -> "$title：$reason" }
                    .takeIf { contentFailures.isNotEmpty() }
                database.updateBookCacheProgress(
                    item.sourceId,
                    item.bookUrl,
                    database.cachedChapterUrls(item.sourceId, item.bookUrl).size,
                )
                database.finishBookCache(item.sourceId, item.bookUrl, error)
            }

            update(jobId) {
                it.message = if (failed == 0) "正在生成导出文件" else "正文失败 $failed 章，正在生成带章节结构的导出文件"
                it.failedChapters = failed
                it.imageFailures = imageFailures.get()
                it.updatedAt = now().toString()
            }
            val cover = fetchCover(item, details, source, bookContext, workspace)
            val bookMeta = BookMeta(
                title = item.name,
                author = formatBookAuthor(details?.author ?: item.author),
                // fetchBookDetails 已按 Android BookInfo 规则处理简介，导出时不再二次改写。
                intro = details?.intro.orEmpty(),
                kind = details?.kind,
                wordCount = details?.wordCount,
            )
            val artifacts = if (job.request.format == "txt") {
                listOf(
                    buildTxtArtifact(
                        jobId = jobId,
                        charset = job.request.charset,
                        includeChapterTitle = job.request.includeChapterTitle,
                        book = bookMeta,
                        chapters = completed,
                        workspace = workspace,
                    ),
                )
            } else {
                buildEpubArtifacts(
                    jobId = jobId,
                    request = job.request,
                    bookMeta = bookMeta,
                    completed = completed,
                    cover = cover,
                    imageAssets = imageAssets,
                    metadataDate = job.createdAt,
                    workspace = workspace,
                )
            }
            val pushResult = if (!job.request.pushToKindle) {
                null
            } else if (failed > 0) {
                KindlePushEnqueueResult(
                    deliveryId = "",
                    state = "skipped",
                    message = "有 $failed 章正文失败，未自动推送到 Kindle",
                )
            } else {
                runCatching {
                    val handler = pushHandler ?: error("Kindle 推送服务未启用")
                    handler(
                        KindlePushExportInput(
                            jobId = jobId,
                            sourceId = item.sourceId,
                            bookUrl = item.bookUrl,
                            title = bookMeta.title,
                            author = bookMeta.author,
                            format = job.request.format,
                            targetDeviceIds = job.request.kindleDeviceIds,
                            files = artifacts.map { artifact ->
                                KindlePushArtifactInput(
                                    fileId = artifact.fileId,
                                    fileName = artifact.fileName,
                                    contentType = artifact.contentType,
                                    sha256 = artifact.sha256,
                                    sizeBytes = artifact.sizeBytes,
                                    path = artifact.path,
                                )
                            },
                        ),
                    )
                }.getOrElse { error ->
                    log("kindle push enqueue failed: job=$jobId, error=${error.message}")
                    KindlePushEnqueueResult(
                        deliveryId = "",
                        state = "failed",
                        message = error.message ?: "加入 Kindle 投递失败",
                    )
                }
            }
            synchronized(lock) {
                activeByBook.remove("${item.sourceId}\u0000${item.bookUrl}")
                jobs[jobId]?.let { state ->
                    state.status = "ready"
                    state.artifacts = artifacts
                    state.completedChapters = selectedPositions.size - failed
                    state.failedChapters = failed
                    state.imageFailures = imageFailures.get()
                    state.kindleDeliveryId = pushResult?.deliveryId?.takeIf { it.isNotBlank() }
                    state.kindlePushState = pushResult?.state
                    state.kindlePushMessage = pushResult?.message
                    state.message = if (failed == 0) {
                        "导出完成"
                    } else {
                        "导出完成；$failed 章正文下载失败，已按 Android 语义保留章节结构"
                    }
                    state.updatedAt = now().toString()
                }
            }
            log(
                "book export completed: ${item.bookUrl}, format=${job.request.format}, " +
                    "chapters=${selectedPositions.size}, failed=$failed, files=${artifacts.size}",
            )
        } catch (error: CancellationException) {
            updateIfPresent(jobId) {
                it.status = "failed"
                it.message = "导出已取消"
                it.updatedAt = now().toString()
            }
            throw error
        } catch (error: BookExportException) {
            shelfItem?.let(::releaseActiveBook)
            updateIfPresent(jobId) {
                it.status = "failed"
                it.message = error.message ?: error.code
                it.updatedAt = now().toString()
            }
            log("book export failed: ${shelfItem?.bookUrl ?: jobId}, code=${error.code}")
        } catch (error: Throwable) {
            shelfItem?.let(::releaseActiveBook)
            updateIfPresent(jobId) {
                it.status = "failed"
                it.message = error.message ?: "导出失败"
                it.updatedAt = now().toString()
            }
            log("book export failed: ${shelfItem?.bookUrl ?: jobId}, error=${error.message}")
        } finally {
            runCatching { deleteTree(workspace) }
            val ready = synchronized(lock) { jobs[jobId]?.status == "ready" }
            if (!ready) {
                synchronized(lock) { jobs[jobId]?.artifacts }.orEmpty()
                    .forEach { runCatching { Files.deleteIfExists(it.path) } }
                runCatching {
                    Files.list(directory).use { stream ->
                        stream.filter { it.fileName.toString().startsWith("$jobId-") }
                            .forEach { Files.deleteIfExists(it) }
                    }
                }
            }
        }
    }

    private suspend fun loadDetails(
        item: BookshelfItem,
        source: SourceRecord?,
        bookContext: BookContext,
    ): BookDetails? {
        if (source == null || BookKind.isLocalRef(item.sourceId, item.bookUrl)) return null
        return withTimeoutOrNull(30_000) {
            withContext(Dispatchers.IO) {
                runCatching {
                    fetchBookDetails(
                        database = database,
                        runner = runner,
                        sourceId = item.sourceId,
                        bookUrl = item.bookUrl,
                        bookContext = bookContext,
                    )
                }.getOrNull()
            }
        }
    }

    private suspend fun acquireChapter(
        selectionIndex: Int,
        chapterPosition: Int,
        chapter: Chapter,
        context: AcquisitionContext,
    ): AcquiredChapter {
        val cached = if (chapter.url.isBlank()) null else withContext(Dispatchers.IO) {
            database.cachedContent(context.item.sourceId, context.item.bookUrl, chapter.url)
        }
        var content = cached
        var missing = false
        if (chapter.isVolume) {
            content = ChapterContent(
                title = chapter.title,
                content = "",
                rawTitle = chapter.title,
                rawContent = "",
            )
        } else if (content == null || content.content.isBlank()) {
            val source = context.source
            val fetched = if (source == null || chapter.url.isBlank()) {
                null
            } else {
                downloadContentWithAndroidRetries(
                    item = context.item,
                    source = source,
                    chapter = chapter,
                    bookContext = context.bookContext,
                )
            }
            if (fetched == null) {
                missing = true
                content = ChapterContent(
                    title = chapter.title,
                    content = MISSING_CONTENT_MARKER,
                    rawTitle = chapter.title,
                    rawContent = MISSING_CONTENT_MARKER,
                )
            } else {
                content = fetched
            }
        }

        val rawContent = content.rawContent ?: content.content
        // Android ExportBookService 的章节名始终取目录里的 BookChapter.title；
        // 正文规则顺带解析出的 title 只属于正文接口，不能覆盖 EPUB/TXT 的目录标题。
        val rawTitle = chapter.title.ifBlank {
            content.rawTitle?.takeIf { it.isNotBlank() } ?: ""
        }.replace(TITLE_LINE_BREAK, "")
        val displayTitle = if (context.useReplace && context.rules.isNotEmpty()) {
            ContentProcessor.processTitle(
                rawTitle,
                context.rules,
                jsSandbox = runner.jsSandbox,
                bookName = context.item.name,
            ).ifBlank { rawTitle }
        } else {
            rawTitle
        }
        var body = rawContent
        if (body != MISSING_CONTENT_MARKER && body.isNotBlank()) {
            val afterRawTitleRemoval = removeLeadingDuplicateTitle(body, context.item.name, rawTitle)
            // Android ContentProcessor 使用 else-if：仅当原章节名未命中时，才尝试替换后的标题。
            body = if (
                afterRawTitleRemoval == body &&
                context.useReplace &&
                context.rules.isNotEmpty() &&
                displayTitle != rawTitle
            ) {
                removeLeadingDuplicateTitle(body, context.item.name, displayTitle)
            } else {
                afterRawTitleRemoval
            }
            if (context.useReplace) {
                body = body.lines().joinToString("\n") { it.trim() }
            }
            if (context.useReplace && context.rules.isNotEmpty()) {
                body = ContentProcessor.processContent(
                    body,
                    context.rules,
                    jsSandbox = runner.jsSandbox,
                    bookName = context.item.name,
                    chapterTitle = rawTitle,
                )
            }
        } else if (body != MISSING_CONTENT_MARKER) {
            body = ""
        }

        val urls = IllustrationMarkup.urlsIn(body).distinct()
        if (urls.isNotEmpty()) {
            illustrationCache?.let { cache ->
                runCatching {
                    cache.registerChapter(
                        sourceId = context.item.sourceId,
                        bookUrl = context.item.bookUrl,
                        chapterUrl = chapter.url,
                        chapterIndex = chapter.index,
                        upstreamUrls = urls,
                    )
                }.onFailure {
                    log("book export illustration registration failed: ${context.item.bookUrl}, ${it.message}")
                }
            }
        }
        val images: Map<String, String?> = coroutineScope {
            urls.map { url ->
                url to async {
                    context.resolveImage(
                        url,
                        chapter.url.takeIf { it.startsWith("http://", true) || it.startsWith("https://", true) },
                        chapter,
                    )
                }
            }.associate { (url, result) ->
                val asset = result.await()
                url to asset?.entryName
            }
        }
        val bodyFile = context.workspace.resolve("processed/$selectionIndex.txt")
        Files.writeString(bodyFile, body, Charsets.UTF_8)
        withContext(Dispatchers.IO) {
            illustrationCache?.let { cache ->
                urls.forEach { url ->
                    val asset = context.imageAssets[url] ?: return@forEach
                    val row = cache.getByKey(cache.urlHash(context.item.sourceId, url)) ?: return@forEach
                    val file = cache.fileFor(row) ?: return@forEach
                    runCatching { Files.copy(file, context.workspace.resolve(asset.entryName), StandardCopyOption.REPLACE_EXISTING) }
                }
            }
        }
        return AcquiredChapter(
            selectionIndex = selectionIndex,
            chapterPosition = chapterPosition,
            chapter = chapter,
            title = displayTitle,
            bodyFile = bodyFile,
            missing = missing,
            imageEntries = images,
        )
    }

    private suspend fun downloadContentWithAndroidRetries(
        item: BookshelfItem,
        source: SourceRecord,
        chapter: Chapter,
        bookContext: BookContext,
    ): ChapterContent? {
        var lastError: Throwable? = null
        repeat(ANDROID_DOWNLOAD_ATTEMPTS) { attempt ->
            try {
                val content = withContext(Dispatchers.IO) {
                    val contentBook = bookContext.copy(variables = bookContext.variables.toMutableMap())
                    val value = runner.content(source.json, chapter.url, item.name, contentBook)
                        .let { it.copy(title = it.title ?: chapter.title) }
                    if (value.content.isBlank()) throw IllegalStateException("正文为空")
                    database.cacheBookContent(item.sourceId, item.bookUrl, chapter.url, value)
                    bookContext.useReplaceRule = contentBook.useReplaceRule
                    value
                }
                return content
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
                if (attempt + 1 < ANDROID_DOWNLOAD_ATTEMPTS) delay(ANDROID_RETRY_DELAY_MS)
            }
        }
        log(
            "book export chapter download failed after $ANDROID_DOWNLOAD_ATTEMPTS attempts: " +
                "${chapter.url}, error=${lastError?.message}",
        )
        return null
    }

    private fun removeLeadingDuplicateTitle(content: String, bookName: String, title: String): String {
        val cleanTitle = title.trim()
        if (cleanTitle.isEmpty()) return content
        val pattern = runCatching {
            val escapedTitle = cleanTitle
                .split(Regex("\\s+"))
                .filter { it.isNotEmpty() }
                .joinToString("\\s*") { Regex.escape(it) }
            val escapedBookName = bookName.trim().takeIf { it.isNotEmpty() }
                ?.let(Regex::escape)
                .orEmpty()
            Regex(
                "^(\\s|\\p{P}|$escapedBookName)*${escapedTitle}(\\s)*",
            )
        }.getOrNull() ?: return content
        return pattern.replaceFirst(content, "")
    }

    private suspend fun fetchImage(
        url: String,
        referer: String?,
        item: BookshelfItem,
        workspace: Path,
        mediaHeaders: Map<String, String>,
        decoder: ImageByteDecoder?,
        chapter: Chapter,
    ): ImageAsset? {
        val cache = illustrationCache
        val hash = cache?.urlHash(item.sourceId, url)
        if (cache != null && hash != null) {
            val row = cache.getByKey(hash)
            val cachedFile = row?.let { cache.fileFor(it) }
            if (cachedFile != null) {
                val bytes = runCatching { Files.readAllBytes(cachedFile) }.getOrNull()
                if (bytes != null) {
                    val contentType = ImageBytes.detectImageContentType(bytes)
                        ?: row.contentType.takeIf { it.startsWith("image/") }
                        ?: "image/jpeg"
                    return writeImage(workspace, url, bytes, contentType)
                }
            }
        }
        val fetched = imageFetcher.fetch(url, mediaHeaders, referer, decoder) ?: return null
        if (cache != null && hash != null) {
            val pending = cache.rowByKey(hash)
            runCatching {
                cache.put(
                    sourceId = item.sourceId,
                    bookUrl = item.bookUrl,
                    chapterUrl = chapter.url,
                    upstreamUrl = url,
                    contentType = fetched.contentType,
                    bytes = fetched.bytes,
                    chapterIndex = pending?.chapterIndex ?: chapter.index,
                    segmentIndex = pending?.segmentIndex ?: 0,
                )
            }.onFailure {
                log("book export illustration cache write failed: ${item.bookUrl}, ${it.message}")
            }
        }
        return writeImage(workspace, url, fetched.bytes, fetched.contentType)
    }

    private fun writeImage(
        workspace: Path,
        url: String,
        bytes: ByteArray,
        contentType: String,
    ): ImageAsset {
        val actualType = ImageBytes.detectImageContentType(bytes)
            ?: contentType.substringBefore(';').takeIf { it.startsWith("image/") }
            ?: "image/jpeg"
        val entryName = expectedImageEntry(url)
        Files.write(workspace.resolve(entryName), bytes)
        return ImageAsset(entryName, epubMediaType(entryName, actualType))
    }

    /**
     * Android epublib 的 `Resource(data, href)` 按 href 后缀确定媒体类型。
     * 对它会识别的 EPUB 2 图片后缀沿用这一规则；服务端额外支持的格式继续使用魔数结果。
     */
    private fun epubMediaType(entryName: String, detectedType: String): String =
        when (entryName.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "svg" -> "image/svg+xml"
            "webp" -> "image/webp"
            else -> detectedType
        }

    private fun expectedImageEntry(url: String): String {
        val path = runCatching { java.net.URI(url).path.orEmpty() }.getOrDefault(url.substringBefore('?'))
        val suffix = path.substringAfterLast('.', "jpg")
            .lowercase()
            .takeIf { it.length in 2..5 && it.all(Char::isLetterOrDigit) }
            ?: "jpg"
        return "Images/${SourceFileStore.md5Encode16(url)}.$suffix"
    }

    private fun fetchCover(
        item: BookshelfItem,
        details: BookDetails?,
        source: SourceRecord?,
        bookContext: BookContext,
        workspace: Path,
    ): ImageAsset? {
        val ref = CoverBookRef(item.name, item.sourceId, item.bookUrl)
        fun bytesFromKey(key: String?): Pair<ByteArray, String?>? {
            if (key.isNullOrBlank()) return null
            val path = coverCache.file(key, ref) ?: return null
            val bytes = runCatching { Files.readAllBytes(path) }.getOrNull() ?: return null
            return bytes to database.coverContentType(key)
        }
        var coverBytes = bytesFromKey(item.coverKey)
        val candidateUrls = listOfNotNull(details?.coverUrl, item.coverUrl)
            .map(String::trim)
            .filter { it.isNotEmpty() }
            .distinct()
        for (url in candidateUrls) {
            if (coverBytes != null) break
            val cached = runCatching { coverCache.getIfCached(url, ref) }.getOrNull()
            coverBytes = bytesFromKey(cached?.key)
            if (coverBytes != null) break
            val headers = source?.let { runner.mediaHeaders(it.json, item.sourceId) }.orEmpty()
            val decoder = source?.let {
                runCatching {
                    runner.imageDecoder(it.json, isCover = true, book = bookContext)
                }.getOrNull()
            }
            val downloaded = runCatching {
                coverCache.cache(url, ref, headers, decoder)
            }.onFailure {
                log("book export cover failed: ${item.bookUrl.take(160)}, ${it.message}")
            }.getOrNull()
            coverBytes = bytesFromKey(downloaded?.key)
        }
        val (bytes, declaredType) = coverBytes ?: return null
        ImageBytes.detectImageContentType(bytes)
            ?: declaredType?.takeIf { it.startsWith("image/") }
            ?: return null
        // Android epublib 按资源 href 后缀推断 manifest 媒体类型；
        // ExportBookService 固定使用 Images/cover.jpg，因此它是 JPEG。
        val entryName = "Images/cover.jpg"
        Files.write(workspace.resolve(entryName), bytes)
        return ImageAsset(entryName, "image/jpeg")
    }

    private data class BookMeta(
        val title: String,
        val author: String,
        val intro: String,
        val kind: String?,
        val wordCount: String?,
    )

    private fun buildTxtArtifact(
        jobId: String,
        charset: Charset,
        includeChapterTitle: Boolean,
        book: BookMeta,
        chapters: List<AcquiredChapter>,
        workspace: Path,
    ): Artifact {
        val fileName = exportFileName(book.title, book.author, "txt")
        val temporary = workspace.resolve("$jobId.txt.tmp")
        Files.newBufferedWriter(temporary, charset).use { writer ->
            writer.append(book.title).append('\n')
            writer.append("作者：").append(book.author).append('\n')
            writer.append("简介：\n").append(book.intro).append("\n\n")
            chapters.forEach { chapter ->
                if (includeChapterTitle && chapter.title.isNotBlank()) writer.append(chapter.title).append('\n')
                val body = Files.readString(chapter.bodyFile, Charsets.UTF_8)
                if (body.isNotEmpty()) writer.append(body)
                writer.append("\n\n")
            }
        }
        val output = directory.resolve("$jobId-1.txt")
        Files.move(temporary, output, StandardCopyOption.REPLACE_EXISTING)
        return artifact("file-1", fileName, "text/plain; charset=${charset.name()}", output)
    }

    private fun buildEpubArtifacts(
        jobId: String,
        request: ExportRequest,
        bookMeta: BookMeta,
        completed: List<AcquiredChapter>,
        cover: ImageAsset?,
        imageAssets: Map<String, ImageAsset>,
        metadataDate: String,
        workspace: Path,
    ): List<Artifact> {
        val partitions = if (request.scope == null) {
            listOf(completed)
        } else {
            completed.chunked(request.epubSize)
        }
        if (partitions.isEmpty()) fail(400, "empty_export_scope", "章节范围未选中任何章节")
        return partitions.mapIndexed { index, chapters ->
            val indexSuffix = if (request.scope == null) "" else " [${index + 1}]"
            val fileName = exportFileName(bookMeta.title, bookMeta.author, "epub", indexSuffix)
            val output = directory.resolve("$jobId-${index + 1}.epub")
            buildEpubFile(
                output = output,
                jobId = jobId,
                request = request,
                book = bookMeta,
                chapters = chapters,
                cover = cover,
                imageAssets = imageAssets,
                metadataDate = metadataDate,
                workspace = workspace,
            )
            artifact("file-${index + 1}", fileName, "application/epub+zip", output)
        }
    }

    private fun buildEpubFile(
        output: Path,
        jobId: String,
        request: ExportRequest,
        book: BookMeta,
        chapters: List<AcquiredChapter>,
        cover: ImageAsset?,
        imageAssets: Map<String, ImageAsset>,
        metadataDate: String,
        workspace: Path,
    ) {
        val assets = androidEpubAssets
        val identifier = UUID.randomUUID().toString()
        val pages = chapters.mapIndexed { index, chapter -> EpubChapterPage(index, chapter) }
        val usedImageEntries = chapters.flatMap { acquired ->
            acquired.imageEntries.values.filterNotNull()
        }.toSet()
        val epubImages = imageAssets.values.filter { it.entryName in usedImageEntries }
            .distinctBy { it.entryName }
            .sortedBy { it.entryName }
        val chapterHtml = pages.associate { page ->
            page.index to renderChapter(
                template = assets.chapterTemplate,
                // Android 只用去掉锁图标的标题生成正文页；NCX 仍保留目录原标题。
                title = page.chapter.title.replace(LOCK_ICON, ""),
                body = Files.readString(page.chapter.bodyFile, Charsets.UTF_8),
                imageEntries = page.chapter.imageEntries,
            )
        }
        val coverPage = assets.coverTemplate
            .replace("{name}", book.title)
            .replace("{author}", book.author)
            .replace("{kind}", book.kind.orEmpty())
            .replace("{wordCount}", book.wordCount.orEmpty())
            .replace("{intro}", "")
        val introPage = assets.introTemplate
            .replace("{name}", book.title)
            .replace("{author}", book.author)
            .replace("{kind}", book.kind.orEmpty())
            .replace("{wordCount}", book.wordCount.orEmpty())
            .replace("{intro}", androidFormatHtml(book.intro))
        val coverPageId = if (cover == null) "cover" else "item_1"
        val resources = mutableListOf<EpubResource>()
        cover?.let {
            resources += EpubResource(
                id = "cover",
                href = it.entryName,
                mediaType = it.mediaType,
                source = workspace.resolve(it.entryName),
            )
        }
        resources += EpubResource(
            id = coverPageId,
            href = "Text/cover.html",
            mediaType = "application/xhtml+xml",
            bytes = coverPage.toByteArray(Charsets.UTF_8),
        )
        resources += EpubResource(
            id = "fonts",
            href = "Styles/fonts.css",
            mediaType = "text/css",
            bytes = assets.fontsCss,
        )
        resources += EpubResource(
            id = "intro",
            href = "Text/intro.html",
            mediaType = "application/xhtml+xml",
            bytes = introPage.toByteArray(Charsets.UTF_8),
        )
        resources += EpubResource(
            id = "logo",
            href = "Images/logo.png",
            mediaType = "image/png",
            bytes = assets.logo,
        )
        resources += EpubResource(
            id = "main",
            href = "Styles/main.css",
            mediaType = "text/css",
            bytes = assets.mainCss,
        )
        pages.forEach { page ->
            resources += EpubResource(
                id = "chapter_${page.index}",
                href = "Text/chapter_${page.index}.html",
                mediaType = "application/xhtml+xml",
                bytes = chapterHtml.getValue(page.index).toByteArray(Charsets.UTF_8),
            )
        }
        epubImages.forEach { image ->
            val basename = image.entryName.substringAfterLast('/').substringBeforeLast('.')
            resources += EpubResource(
                id = if (basename.firstOrNull()?.isJavaIdentifierStart() == true) basename
                else "image_$basename",
                href = image.entryName,
                mediaType = image.mediaType,
                source = workspace.resolve(image.entryName),
            )
        }
        val manifestResources = resources.sortedBy { it.id.lowercase() }
        val manifest = buildString {
            append("""  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
""")
            manifestResources.forEach { resource ->
                append("""  <item id="${xmlEscape(resource.id)}" href="${xmlEscape(resource.href)}" media-type="${xmlEscape(resource.mediaType)}"/>
""")
            }
        }
        val spine = buildString {
            append("""  <itemref idref="$coverPageId"/>
  <itemref idref="intro"/>
""")
            pages.forEach { page ->
                append("""  <itemref idref="chapter_${page.index}"/>
""")
            }
        }
        val metadataDateValue = runCatching {
            Instant.parse(metadataDate).atZone(ZoneId.systemDefault()).toLocalDate().toString()
        }.getOrDefault(metadataDate.take(10))
        val coverMetadata = if (cover == null) "" else """
  <meta name="cover" content="cover"/>"""
        val opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="duokan-book-id">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
  <dc:identifier id="duokan-book-id" opf:scheme="UUID">${xmlEscape(identifier)}</dc:identifier>
  <dc:title>${xmlEscape(book.title)}</dc:title>
  <dc:description>${xmlEscape(book.intro)}</dc:description>
  <dc:publisher>Legado</dc:publisher>
  <dc:creator opf:role="aut" opf:file-as="${xmlEscape(book.author)}, ">${xmlEscape(" ${book.author}")}</dc:creator>
  <dc:date>${xmlEscape(metadataDateValue)}</dc:date>
  <dc:language>zh</dc:language>$coverMetadata
  <meta name="generator" content="Ag2S EpubLib"/>
  <meta name="duokan-body-font" content="DK-SONGTI"/>
 </metadata>
 <manifest>
$manifest </manifest>
 <spine toc="ncx">
$spine </spine>
 <guide>
  <reference type="cover" title="cover" href="Text/cover.html"/>
 </guide>
</package>
"""
        val ncx = buildNcx(
            identifier = identifier,
            bookTitle = book.title,
            author = book.author,
            pages = pages,
            hierarchy = request.scope == null,
        )
        val container = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
 <rootfiles>
  <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
 </rootfiles>
</container>
"""
        val temporary = workspace.resolve("$jobId-${output.fileName}.tmp")
        ZipOutputStream(Files.newOutputStream(temporary)).use { zip ->
            fun entry(name: String, bytes: ByteArray, stored: Boolean = false) {
                val value = ZipEntry(name).apply {
                    time = 0
                    method = if (stored) ZipEntry.STORED else ZipEntry.DEFLATED
                    if (stored) {
                        size = bytes.size.toLong()
                        compressedSize = bytes.size.toLong()
                        crc = CRC32().apply { update(bytes) }.value
                    }
                }
                zip.putNextEntry(value)
                zip.write(bytes)
                zip.closeEntry()
            }
            fun resource(resource: EpubResource) {
                zip.putNextEntry(ZipEntry("OEBPS/${resource.href}").apply { time = 0 })
                when {
                    resource.bytes != null -> zip.write(resource.bytes)
                    resource.source != null -> Files.newInputStream(resource.source).use { it.transferTo(zip) }
                    else -> error("EPUB resource has no content: ${resource.href}")
                }
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip".toByteArray(Charsets.US_ASCII), stored = true)
            entry("META-INF/container.xml", container.toByteArray(Charsets.UTF_8))
            manifestResources.forEach(::resource)
            entry("OEBPS/toc.ncx", ncx.toByteArray(Charsets.UTF_8))
            entry("OEBPS/content.opf", opf.toByteArray(Charsets.UTF_8))
        }
        Files.move(temporary, output, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    private fun buildNcx(
        identifier: String,
        bookTitle: String,
        author: String,
        pages: List<EpubChapterPage>,
        hierarchy: Boolean,
    ): String {
        var playOrder = 0
        fun nextOrder(): Int = ++playOrder
        fun leafNavPoint(title: String, href: String): String {
            val order = nextOrder()
            return """ <navPoint id="nav-point-$order" playOrder="$order" class="chapter"><navLabel><text>${xmlEscape(title)}</text></navLabel><content src="$href"/></navPoint>"""
        }
        fun chapterHref(page: EpubChapterPage): String = "Text/chapter_${page.index}.html"
        val root = StringBuilder()
        root.append(leafNavPoint("封面", "Text/cover.html")).append('\n')
        root.append(leafNavPoint("内容简介", "Text/intro.html")).append('\n')
        if (!hierarchy) {
            pages.forEach { page ->
                root.append(leafNavPoint(page.chapter.title, chapterHref(page))).append('\n')
            }
        } else {
            var index = 0
            while (index < pages.size) {
                val page = pages[index]
                if (!page.chapter.chapter.isVolume) {
                    root.append(leafNavPoint(page.chapter.title, chapterHref(page))).append('\n')
                    index++
                    continue
                }
                val volumeOrder = nextOrder()
                val children = StringBuilder()
                var child = index + 1
                while (child < pages.size && !pages[child].chapter.chapter.isVolume) {
                    val value = pages[child]
                    children.append("  ")
                        .append(leafNavPoint(value.chapter.title, chapterHref(value)))
                        .append('\n')
                    child++
                }
                root.append(""" <navPoint id="nav-point-$volumeOrder" playOrder="$volumeOrder" class="chapter"><navLabel><text>${xmlEscape(page.chapter.title)}</text></navLabel><content src="${chapterHref(page)}"/>
${children.toString().trimEnd()}
 </navPoint>""").append('\n')
                index = child
            }
        }
        val depth = if (hierarchy && pages.any { it.chapter.chapter.isVolume }) 2 else 1
        return """<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
 <head>
  <meta name="dtb:UUID" content="${xmlEscape(identifier)}"/>
  <meta name="dtb:generator" content="Ag2S EpubLib"/>
  <meta name="dtb:depth" content="$depth"/>
  <meta name="dtb:totalPageCount" content="0"/>
  <meta name="dtb:maxPageNumber" content="0"/>
 </head>
 <docTitle><text>${xmlEscape(bookTitle)}</text></docTitle>
 <docAuthor><text>${xmlEscape(author)}, </text></docAuthor>
 <navMap>
${root.toString().trimEnd()}
 </navMap>
</ncx>
"""
    }

    private fun renderChapter(
        template: String,
        title: String,
        body: String,
        imageEntries: Map<String, String?>,
    ): String {
        var rewrittenBody = body
        imageEntries.forEach { (source, entry) ->
            rewrittenBody = rewrittenBody.replace(source, "../${entry ?: expectedImageEntry(source)}")
        }
        val originalTitle = title.ifBlank { "未命名章节" }
        var renderedTitle = originalTitle.replaceFirst(Regex("\\s+"), "</span><br />")
        if (renderedTitle.contains("</span>")) {
            renderedTitle = "<span class=\"chapter-sequence-number\">$renderedTitle"
        }
        return template
            .replace("{title}", renderedTitle)
            .replace("{ori_title}", originalTitle)
            .replace("{content}", androidFormatHtml(rewrittenBody))
    }

    /** Android `StringUtil.formatHtml`：逐行去首尾空白，图片独占行使用多看单图结构。 */
    private fun androidFormatHtml(text: String): String = buildString {
        text.replace("\r\n", "\n").split('\n').forEach { line ->
            val value = line.trim()
            if (value.isEmpty()) return@forEach
            val standaloneImage = STANDALONE_IMAGE.matchEntire(value)
            if (standaloneImage != null) {
                append("<div class=\"duokan-image-single\"><img class=\"picture-80\" ")
                    .append(standaloneImage.groupValues[1])
                    .append("/></div>")
            } else {
                append("<p>").append(value).append("</p>")
            }
        }
    }

    private fun resourceBytes(path: String): ByteArray =
        BookExportService::class.java.getResourceAsStream(path)?.use { it.readBytes() }
            ?: fail(500, "epub_asset_missing", "EPUB 资源缺失：$path")

    private fun resourceText(path: String): String = resourceBytes(path).toString(Charsets.UTF_8)

    private fun artifact(fileId: String, fileName: String, contentType: String, path: Path): Artifact =
        Artifact(
            fileId = fileId,
            fileName = fileName,
            contentType = contentType,
            path = path,
            sizeBytes = Files.size(path),
            sha256 = sha256(path),
        )

    private fun chapterFinished(jobId: String, success: Boolean, imageFailures: Int) {
        updateIfPresent(jobId) { state ->
            state.processedChapters++
            if (success) state.completedChapters++ else state.failedChapters++
            state.imageFailures = imageFailures
            state.message = "正在下载章节 ${state.processedChapters}/${state.selectedChapters}"
            state.updatedAt = now().toString()
        }
    }

    private fun update(jobId: String, block: (JobState) -> Unit) {
        synchronized(lock) {
            jobs[jobId]?.let(block)
        }
    }

    private fun updateIfPresent(jobId: String, block: (JobState) -> Unit) = update(jobId, block)

    private fun snapshot(state: JobState): BookshelfExportStatus {
        val files = state.artifacts.map { artifact ->
            BookshelfExportFile(
                fileId = artifact.fileId,
                fileName = artifact.fileName,
                contentType = artifact.contentType,
                sizeBytes = artifact.sizeBytes,
                sha256 = artifact.sha256,
                downloadUrl = "/api/bookshelf/export/${state.jobId}/download/${artifact.fileId}",
            )
        }
        val first = files.firstOrNull()
        return BookshelfExportStatus(
            jobId = state.jobId,
            sourceId = state.request.sourceId,
            bookUrl = state.request.bookUrl,
            bookName = state.bookName,
            format = state.request.format,
            status = state.status,
            totalChapters = state.totalChapters,
            selectedChapters = state.selectedChapters,
            processedChapters = state.processedChapters,
            completedChapters = state.completedChapters,
            failedChapters = state.failedChapters,
            imageFailures = state.imageFailures,
            chapterConcurrency = if (state.request.parallel) PARALLEL_CHAPTER_CONCURRENCY else 1,
            bookConcurrency = BOOK_CONCURRENCY,
            message = state.message,
            files = files,
            fileName = first?.fileName,
            sizeBytes = first?.sizeBytes,
            sha256 = first?.sha256,
            downloadUrl = first?.downloadUrl,
            kindleDeliveryId = state.kindleDeliveryId,
            kindlePushState = state.kindlePushState,
            kindlePushMessage = state.kindlePushMessage,
            createdAt = state.createdAt,
            updatedAt = state.updatedAt,
        )
    }

    private fun cleanupExpired() {
        val cutoff = now().minus(EXPORT_RETENTION).toEpochMilli()
        val removed = synchronized(lock) {
            val expired = jobs.values.filter {
                it.status in setOf("ready", "failed") &&
                    runCatching { Instant.parse(it.updatedAt).toEpochMilli() }.getOrDefault(0) < cutoff
            }
            expired.forEach { state ->
                jobs.remove(state.jobId)
                activeByBook.entries.removeIf { it.value == state.jobId }
            }
            expired.flatMap { it.artifacts }.map { it.path }
        }
        removed.forEach { runCatching { Files.deleteIfExists(it) } }
    }

    private fun releaseActiveBook(item: BookshelfItem) {
        synchronized(lock) {
            activeByBook.remove("${item.sourceId}\u0000${item.bookUrl}")
        }
    }

    private fun exportFileName(
        title: String,
        author: String,
        suffix: String,
        indexSuffix: String = "",
    ): String {
        val raw = buildString {
            append(title)
            if (author.isNotBlank()) append(" 作者：").append(author)
            append(indexSuffix)
        }
        val clean = raw
            .replace(INVALID_FILENAME_CHAR, "_")
            .trim(' ', '.')
        val extension = ".$suffix"
        val base = takeCodePoints(clean, MAX_FILENAME_LENGTH - extension.length)
            .ifBlank { "book-${UUID.randomUUID().toString().take(8)}" }
        return base + extension
    }

    private fun takeCodePoints(value: String, max: Int): String {
        if (value.codePointCount(0, value.length) <= max) return value
        return value.substring(0, value.offsetByCodePoints(0, max))
    }

    private fun xmlEscape(raw: String): String = buildString(raw.length + 16) {
        var index = 0
        while (index < raw.length) {
            val codePoint = raw.codePointAt(index)
            index += Character.charCount(codePoint)
            val valid = codePoint == 0x09 || codePoint == 0x0A || codePoint == 0x0D ||
                codePoint in 0x20..0xD7FF || codePoint in 0xE000..0xFFFD ||
                codePoint in 0x10000..0x10FFFF
            if (!valid) continue
            when (codePoint) {
                '&'.code -> append("&amp;")
                '<'.code -> append("&lt;")
                '>'.code -> append("&gt;")
                '"'.code -> append("&quot;")
                '\''.code -> append("&apos;")
                else -> appendCodePoint(codePoint)
            }
        }
    }

    private fun resetDirectory() {
        runCatching { deleteTree(directory) }
        Files.createDirectories(directory)
    }

    private fun deleteTree(path: Path) {
        if (!Files.exists(path)) return
        Files.walk(path).use { stream ->
            stream.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
        }
    }

    private fun sha256(path: Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(path).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun fail(status: Int, code: String, message: String): Nothing =
        throw BookExportException(status, code, message)

    private companion object {
        const val BOOK_CONCURRENCY = 1
        const val PARALLEL_CHAPTER_CONCURRENCY = 9
        const val ACQUISITION_BATCH_SIZE = 36
        const val ANDROID_DOWNLOAD_ATTEMPTS = 3
        const val ANDROID_RETRY_DELAY_MS = 1_000L
        const val MISSING_CONTENT_MARKER = "null"
        const val MAX_FILENAME_LENGTH = 160
        const val LOCK_ICON = "\uD83D\uDD12"
        val EXPORT_RETENTION = java.time.Duration.ofHours(24)
        val ACTIVE_OR_READY = setOf("queued", "running", "ready")
        val STANDALONE_IMAGE = Regex("(?i)^<img\\s([^>]+)/?>$")
        val TITLE_LINE_BREAK = Regex("[\\r\\n]")
        val INVALID_FILENAME_CHAR = Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]")
    }
}
