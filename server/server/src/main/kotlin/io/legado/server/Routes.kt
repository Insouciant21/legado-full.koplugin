package io.legado.server

import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.http.content.LocalFileContent
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.websocket.*
import io.ktor.websocket.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import io.ktor.http.content.PartData
import io.ktor.http.content.forEachPart
import io.ktor.http.content.streamProvider
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.UUID
import java.net.URLEncoder
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resumeWithException

/**
 * 本地书籍的**单文件体积上限**（上传入口与 WebDAV 入口共用）。
 *
 * 与备份条目的 64MiB 上限不同：这里是「一本书」的内容，20MiB 足够覆盖
 * 正常 TXT（几 MB）与图文 EPUB；同时挡住「误把几百 MB 的压缩包按 TXT 硬解析」。
 */
private const val MAX_LOCAL_BOOK_BYTES = 20L * 1024 * 1024

/** 手动触发封面自愈时的单轮上限硬顶（防止一次管理请求把整架书都丢给上游）。 */
private const val MAX_SELF_HEAL_LIMIT = 500

fun Route.apiRoutes(
    database: Database,
    auth: AuthService,
    runner: RuleRunner,
    coverCache: CoverCache,
    subscriptions: SubscriptionService,
    bookCache: BookCacheService,
    localBooksDirectory: Path = Path.of(".data/local_books"),
    progressSync: BookProgressSync = BookProgressSync(Path.of(".data/webdav"), database),
    /**
     * WebDAV 存储区，用于「从 WebDAV 导入书籍」。
     *
     * 默认从 [progressSync] 所在的 webdav 根推导，保持与 WebDAV 服务端同一目录。
     */
    webDavStorage: WebDavStorage = WebDavStorage(Path.of(".data/webdav")),
    /** 漫画图片的 L1 字节缓存（方案 E · P1）。 */
    imageCache: ImageCache,
    /** 漫画图片抓取收口（全局限流 + 书源头 + Referer/Cookie + SSRF）。 */
    mangaImageFetcher: MangaImageFetcher,
    /** 漫画图片后台预取（方案 E · P2）。可为 null ⇒ 视为关闭。 */
    mangaPrefetch: MangaPrefetchService? = null,
    /** 有声书音频的 L1 字节缓存（方案 G2 ·  / ）。 */
    audioCache: AudioCache,
    /** 有声书音频抓取收口（全局 Semaphore(3) + 单 host 1 + 流式落盘 + SSRF）。 */
    audioFetcher: AudioFetcher,
    /** 音频后台批量缓存（方案 G2 · G5）。可为 null ⇒ 视为关闭。 */
    audioPrefetch: AudioPrefetchService? = null,
    /**
     * 小说正文插图的落盘缓存（`<data>/images/`，）。
     *
     * 可为 null ⇒ 插图代理路由关闭。
     */
    illustrationCache: IllustrationCache? = null,
    /** 书架 TXT/EPUB 导出任务（异步补齐正文并按需写入最终文件）。 */
    bookExport: BookExportService,
    /**
     * 封面常驻自愈（[CoverSelfHeal]）。可为 null ⇒ 手动触发路由关闭
     * 定时巡检在 `Application` 里另有一份接线。
     */
    coverSelfHeal: CoverSelfHeal? = null,
    kindleSync: KindleSyncService? = null,
    browserRuntime: BrowserRuntime? = null,
    bookshelfRefresh: BookshelfRefreshService,
) {
    val webView = WebViewProxy(database)

    suspend fun refreshSourceLoginBook(
        source: SourceRecord,
        book: BookContext,
        chapter: Chapter?,
        targets: Set<SourceLoginRefreshTarget>,
        previousVariables: Map<String, String>,
    ): SourceLoginBookRefresh? {
        if (book.variables != previousVariables) database.persistBookVariables(book)
        if (targets.isEmpty() && book.variables == previousVariables) return null

        val errors = mutableListOf<String>()
        suspend fun <T : Any> refresh(label: String, block: suspend () -> T): T? = try {
            withTimeoutOrNull(CHAPTERS_TIMEOUT_MS) { block() }
                ?: throw RuleExecutionException("请求超时")
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            errors.add("$label：${error.message ?: "请求失败"}")
            null
        }

        val details = if (SourceLoginRefreshTarget.DETAILS in targets) refresh("刷新书籍详情失败") {
            runInterruptible(Dispatchers.IO) {
                fetchBookDetails(database, runner, source.id, book.bookUrl, book)
                    ?: throw RuleExecutionException("书籍详情不存在")
            }
        } else null
        details?.tocUrl?.takeIf { it.isNotBlank() }?.let { book.tocUrl = it }

        val content = if (SourceLoginRefreshTarget.CONTENT in targets && chapter != null &&
            !chapter.isVolume && book.kind != BookKind.COMIC.wire && book.kind != BookKind.AUDIO.wire
        ) refresh("刷新当前章节失败") {
            val fresh = runInterruptible(Dispatchers.IO) {
                runner.content(source.json, chapter.url, book.name, book)
            }
            if (fresh.content.isBlank()) throw RuleExecutionException("正文为空")
            currentCoroutineContext().ensureActive()
            database.cacheBookContent(source.id, book.bookUrl, chapter.url, fresh, reconcileProgress = true)
            runCatching {
                illustrationCache?.registerFromContent(source.id, book.bookUrl, chapter.url, chapter.index, fresh.content)
            }
            database.persistBookVariables(book)
            fresh
        } else null

        val chapters = if (SourceLoginRefreshTarget.TOC in targets) refresh("刷新目录失败") {
            bookshelfRefresh.refreshToc(source, book)
        } else null

        return SourceLoginBookRefresh(
            details = details,
            chapters = chapters,
            tocUrl = book.tocUrl.takeIf { chapters != null },
            content = content,
            variables = book.variables.toMap().takeIf { it != previousVariables },
            errors = errors,
        )
    }

    /** 网络书源导入：服务端代抓 + 内存票据两步式。 */
    val networkImport = NetworkSourceImport(database, log = { message -> application.log.info(message) })

    /**
     * 把一本书的字节导入为本地书籍（**两个入口共用**）。
     *
     * 上传入口（`POST /bookshelf/import-local`）与 WebDAV 入口
     * （`POST /bookshelf/import-webdav`）都走这里，保证行为完全一致 ——
     * 否则「同一个 TXT 用不同入口导入，结果不一样」会非常难查。
     *
     * 流程：格式校验 → 解析 → 原文件落盘 → 封面提取 → 入库。
     * **任何失败都转成 `success=false` 的结果项**，绝不抛给调用方，
     * 这样批量导入时一个坏文件不会中断其余文件。
     */
    fun importOneLocalBook(
        filename: String,
        bytes: ByteArray,
        booksDirectory: Path,
        covers: CoverCache,
        db: Database,
    ): LocalBookImportItem {
        return try {
            // 只接受 TXT / EPUB。
            // 不拦的话 `LocalBookParser.parse` 会把未知格式**静默按 TXT 解析**，
            // 用户会得到一本正文是乱码的"书"且没有任何报错。
            require(LocalBookParser.isSupported(filename)) {
                "不支持的格式（仅支持 ${LocalBookParser.SUPPORTED_FORMATS}）：$filename"
            }
            val parsed = LocalBookParser.parse(filename, bytes)
            val bookId = UUID.randomUUID().toString().replace("-", "")
            val ext = if (filename.contains('.')) "." + filename.substringAfterLast('.') else ".txt"
            runCatching {
                Files.createDirectories(booksDirectory)
                Files.write(booksDirectory.resolve("$bookId$ext"), bytes)
            }

            val coverKey = if (parsed.coverBytes != null && parsed.coverBytes.isNotEmpty()) {
                covers.saveCoverBytes(
                    parsed.coverBytes,
                    parsed.coverContentType ?: "image/jpeg",
                    // 本地书的身份在这里就能定死（与 `Database.importLocalBook` 同一口径）：
                    // `sourceId = loc_book`、`bookUrl = local://<bookId>` ⇒ 封面文件名就是 `书名 (书哈希).扩展名`
                    CoverBookRef(parsed.title, LocalBookParser.LOC_BOOK_SOURCE_ID, "local://$bookId"),
                )
            } else null

            val item = db.importLocalBook(bookId, parsed, coverKey)
            LocalBookImportItem(
                filename = filename,
                success = true,
                bookUrl = item.bookUrl,
                name = item.name,
                author = item.author,
                totalChapters = item.totalChapters,
            )
        } catch (error: Throwable) {
            LocalBookImportItem(filename = filename, success = false, error = error.message ?: "解析失败")
        }
    }

    /**
     * 把已保存的进度镜像到手机端进度文件。
     *
     * 章节标题从目录缓存里取（前端只传 URL/index，不带标题）。
     * **任何失败都静默**：进度文件只是镜像，权威数据永远是本地 SQLite。
     */
    fun syncProgressToFile(saved: ReadingProgress, fallbackTitle: String?) {
        runCatching {
            val shelf = database.getShelfBookByUrl(saved.bookUrl) ?: return@runCatching
            val title = fallbackTitle?.takeIf { it.isNotBlank() }
                ?: database.getChapterTitle(saved.sourceId, saved.bookUrl, saved.chapterUrl)
                ?: return@runCatching
            // 与手机端行为**完全对齐（含倒退）**：照当前进度写，不做"防倒退"。
            //
            // 用户明确要求：**手机倒退 → 同步也倒退**。
            // 手机自己回翻时也会把 idx 写小（实测 云游异世界 326 → 329 → 328 → 323），
            // 因此这里保持同样语义，不做任何"只增不减"的额外保护。
            // 另外按 bookKind 进行类型隔离（有声加 _audio，漫画加 _comic，小说保持无后缀），
            // 避免同名书籍互相覆盖，手机端开源阅读只同步小说。
            val kind = saved.bookKind?.takeIf { it.isNotBlank() } ?: shelf.bookKind
            progressSync.write(
                bookName = shelf.name,
                author = shelf.author,
                chapterIndex = saved.chapterIndex,
                chapterTitle = title,
                // 有声书：把我们负责的毫秒位置镜像成 `durChapterPos`（同语义直传）；
                // 其它类型为 null ⇒ 沿用文件里手机端写的值（我们无权改写字符偏移量）
                positionMs = saved.positionMs,
                bookKind = kind,
            )
        }
    }

    suspend fun ApplicationCall.startBookshelfExport(forcedFormat: String? = null) {
        if (auth.requireSession(this, csrfRequired = true) == null) return
        val request = try {
            receive<BookshelfExportRequest>()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            respond(HttpStatusCode.BadRequest, ApiError("invalid_request", "导出请求格式无效"))
            return
        }
        try {
            respond(HttpStatusCode.Accepted, bookExport.start(request, forcedFormat))
        } catch (error: BookExportException) {
            respond(HttpStatusCode.fromValue(error.status), ApiError(error.code, error.message ?: error.code))
        }
    }

    suspend fun ApplicationCall.downloadBookshelfExport(jobId: String, fileId: String? = null) {
        if (auth.requireSession(this) == null) return
        val exported = try {
            bookExport.download(jobId, fileId)
        } catch (error: BookExportException) {
            respond(HttpStatusCode.fromValue(error.status), ApiError(error.code, error.message ?: error.code))
            return
        }
        val fallback = "book-${jobId.take(12)}.${exported.file.fileName.substringAfterLast('.', "bin")}"
        val encoded = URLEncoder.encode(exported.file.fileName, Charsets.UTF_8.name()).replace("+", "%20")
        response.header(
            HttpHeaders.ContentDisposition,
            "attachment; filename=\"$fallback\"; filename*=UTF-8''$encoded",
        )
        response.header(HttpHeaders.ETag, "\"${exported.file.sha256}\"")
        response.header(HttpHeaders.CacheControl, "private, no-store")
        respond(
            LocalFileContent(
                exported.path.toFile(),
                ContentType.parse(exported.file.contentType),
            )
        )
    }

    route("/api") {
        route("/settings") {
            get("/locale") {
                val locale = database.getSetting("locale")
                call.respond(LocaleSettingResponse(locale = locale))
            }
            put("/locale") {
                if (auth.requireSession(call, csrfRequired = true) == null) return@put
                val req = runCatching { call.receive<LocaleSettingRequest>() }.getOrNull()
                val normalized = ServerMessages.normalizeLocale(req?.locale)
                if (normalized == null) {
                    call.respondApiError(HttpStatusCode.BadRequest, "invalid_locale", "不支持的语言代码")
                    return@put
                }
                database.setSetting("locale", normalized)
                call.application.log.info("server locale setting updated to: {}", normalized)
                call.respond(LocaleSettingResponse(locale = normalized))
            }
        }
        get("/sources") {
            if (auth.requireSession(call) == null) return@get
            call.respond(database.listSources(call.request.queryParameters["q"]))
        }
        get("/sources/picker") {
            if (auth.requireSession(call) == null) return@get
            val groups = call.request.queryParameters.getAll("group").orEmpty()
            call.respond(database.searchSourcePicker(call.request.queryParameters["q"], groups))
        }
        post("/sources/batch") {
            if (auth.requireSession(call, true) == null) return@post
            val req = call.receive<BatchSourceRequest>()
            if (req.ids.isEmpty()) {
                call.respondApiError(HttpStatusCode.BadRequest, "empty_selection", "请先选择需要操作的书源")
                return@post
            }
            try {
                val count = database.batchUpdateSources(req.ids, req.action, req.group)
                val msg = when (req.action) {
                    "enable" -> "已成功启用 $count 个书源"
                    "disable" -> "已成功停用 $count 个书源"
                    "delete" -> "已成功删除 $count 个书源"
                    "set_group" -> if (req.group.isNullOrBlank()) "已清空 $count 个书源的分组" else "已将 $count 个书源移至分组“${req.group}”"
                    else -> "已处理 $count 个书源"
                }
                call.application.log.info("source batch operation: action={}, count={}", req.action, count)
                call.respond(BatchSourceResponse(ok = true, affected = count, action = req.action, message = msg))
            } catch (error: IllegalArgumentException) {
                call.respondApiError(HttpStatusCode.BadRequest, "invalid_action", error.message ?: "无效的批量操作")
            } catch (error: Throwable) {
                call.application.log.error("source batch operation failed", error)
                call.respondApiError(HttpStatusCode.InternalServerError, "batch_failed", error.message ?: "批量操作失败")
            }
        }
        post("/sources/health-check") {
            if (auth.requireSession(call) == null) return@post
            val req = runCatching { call.receive<SourceHealthCheckRequest>() }.getOrElse { SourceHealthCheckRequest() }
            val timeoutMs = req.timeoutMs.coerceIn(1000L, 10000L)
            val allSources = database.listSources(null)
            val targetSources = if (!req.ids.isNullOrEmpty()) {
                val idSet = req.ids.toSet()
                allSources.filter { it.id in idSet }
            } else {
                allSources
            }

            val startTotalNs = System.nanoTime()
            val semaphore = Semaphore(8)
            val probeClient = java.net.http.HttpClient.newBuilder()
                .connectTimeout(java.time.Duration.ofMillis(timeoutMs))
                .followRedirects(java.net.http.HttpClient.Redirect.NORMAL)
                .build()

            val results = coroutineScope {
                targetSources.map { summary ->
                    async(Dispatchers.IO) {
                        semaphore.withPermit {
                            val record = database.getSource(summary.id)
                            if (record == null) {
                                SourceHealthCheckItem(
                                    id = summary.id,
                                    name = summary.name,
                                    ok = false,
                                    latencyMs = 0L,
                                    statusCode = 0,
                                    statusCategory = "failed",
                                    error = "书源记录不存在",
                                )
                            } else {
                                probeSingleSourceHealth(probeClient, summary.id, summary.name, record.json, timeoutMs)
                            }
                        }
                    }
                }.awaitAll()
            }
            val totalDurationMs = (System.nanoTime() - startTotalNs) / 1_000_000
            val successCount = results.count { it.statusCategory == "valid" }
            val slowCount = results.count { it.statusCategory == "slow" }
            val failedCount = results.count { it.statusCategory == "failed" || it.statusCategory == "blocked" }

            call.respond(
                SourceHealthCheckResponse(
                    total = results.size,
                    successCount = successCount,
                    slowCount = slowCount,
                    failedCount = failedCount,
                    durationMs = totalDurationMs,
                    results = results,
                )
            )
        }
        // Android「校验书源」：按 CheckSourceService 的完整链路校验（搜索→发现→详情→目录→正文），
        // 与只探连通性的 /sources/health-check 是两件事。默认把结论写回书源（失效分组 / respondTime /
        // `// Error:` 注释），可用 options.applyResult=false 只取报告。
        post("/sources/check") {
            if (auth.requireSession(call, true) == null) return@post
            val request = runCatching { call.receive<SourceCheckRequest>() }.getOrElse { SourceCheckRequest() }
            val allSources = database.listSources(null)
            val targetSources = if (!request.ids.isNullOrEmpty()) {
                val idSet = request.ids.toSet()
                allSources.filter { it.id in idSet }
            } else {
                allSources
            }

            val startTotalNs = System.nanoTime()
            val checker = SourceChecker(runner, database)
            val results = boundedConcurrentMap(targetSources, sourceSearchConcurrency()) { summary ->
                withContext(Dispatchers.IO) {
                    val record = database.getSource(summary.id)
                    if (record == null) {
                        SourceChecker.failureResult(summary.id, summary.name, request.options.keyword, "书源记录不存在")
                    } else {
                        runCatching { checker.check(record.json, request.options) }.getOrElse { error ->
                            SourceChecker.failureResult(
                                summary.id,
                                summary.name,
                                request.options.keyword,
                                error.message ?: error.javaClass.simpleName,
                            )
                        }
                    }
                }
            }
            val totalDurationMs = (System.nanoTime() - startTotalNs) / 1_000_000
            call.respond(
                SourceCheckResponse(
                    total = results.size,
                    passed = results.count { it.ok },
                    failed = results.count { !it.ok },
                    durationMs = totalDurationMs,
                    results = results,
                )
            )
        }
        get("/sources/export") {
            if (auth.requireSession(call) == null) return@get
            call.respondText(
                text = Json.encodeToString(database.exportSources(call.request.queryParameters.getAll("id"))),
                contentType = ContentType.Application.Json.withCharset(Charsets.UTF_8),
            )
        }
        // 书源分组：列表 / 改名 / 删除。分组是书源自带的字符串元数据（Legado 的 `bookSourceGroup`），
        // 因此这里的写操作只改 `source.source_group`，**永不删除书源本身**。
        get("/source-groups") {
            if (auth.requireSession(call) == null) return@get
            call.respond(database.listSourceGroups())
        }
        put("/source-groups/rename") {
            if (auth.requireSession(call, true) == null) return@put
            val request = call.receive<SourceGroupRenameRequest>()
            val from = request.from.trim()
            val to = request.to.trim()
            if (from.isEmpty() || to.isEmpty()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_group", "分组名称不能为空"))
                return@put
            }
            if (to.equals(SourceGroupFilter.UNGROUPED, ignoreCase = true)) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_group", "不能使用系统保留字「$to」作为分组名称"))
                return@put
            }
            if (from.equals(to, ignoreCase = true)) {
                call.respond(SourceGroupMutationResponse(ok = true, affected = 0, message = "分组名未变化"))
                return@put
            }
            val affected = database.renameSourceGroup(from, to)
            if (affected == 0) {
                call.respond(HttpStatusCode.NotFound, ApiError("group_not_found", "分组「$from」不存在"))
                return@put
            }
            call.application.log.info("source group renamed: {} -> {} ({} sources)", from, to, affected)
            call.respond(SourceGroupMutationResponse(ok = true, affected = affected, message = "已将 $affected 个书源从「$from」移到分组「$to」"))
        }
        delete("/source-groups") {
            if (auth.requireSession(call, true) == null) return@delete
            val name = call.request.queryParameters["name"]?.trim()
            if (name.isNullOrEmpty()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_group", "分组名称不能为空"))
                return@delete
            }
            val affected = database.clearSourceGroup(name)
            if (affected == 0) {
                call.respond(HttpStatusCode.NotFound, ApiError("group_not_found", "分组「$name」不存在"))
                return@delete
            }
            call.application.log.info("source group cleared: {} ({} sources)", name, affected)
            call.respond(SourceGroupMutationResponse(ok = true, affected = affected, message = "已删除分组「$name」，$affected 个书源变为未分组（书源未被删除）"))
        }
        post("/sources/import") {
            if (auth.requireSession(call, true) == null) return@post
            // 新源沿用文件分组；已有源保留当前分组，仅用文件分组补齐空值。
            // （手机备份导入走 BackupImporter，那条路径仍以备份中的分组为准确覆盖。）
            val response = database.importSources(call.receive<ImportRequest>().sources, applyGroups = false)
            call.application.log.info("source import completed: imported={}, updated={}, skipped={}", response.imported, response.updated, response.skipped)
            call.respond(response)
        }
        /**
         * 网络书源导入：**预览**。
         *
         * 由服务端代抓（浏览器跨域 + 信任边界）→ 逐条试解析 → 只回传元数据与
         * 一次性票据；完整书源原文留在 [networkImport] 的内存缓存里等 commit。
         */
        post("/sources/import-url/preview") {
            if (auth.requireSession(call, true) == null) return@post
            val request = runCatching { call.receive<NetworkImportPreviewRequest>() }.getOrNull()
                ?: return@post call.respondApiError(HttpStatusCode.BadRequest, "invalid_request", "请求格式无效")
            try {
                call.respond(networkImport.preview(request.url))
            } catch (error: NetworkImportException) {
                call.respondApiError(HttpStatusCode.BadRequest, error.code, error.message)
            }
        }
        /**
         * 本地书源文件：**预览**。
         *
         * 与网络导入共用 [NetworkSourceImport.buildPreview] 的解析与判定，只是内容来自
         * 浏览器读出的文件而不是服务端代抓 —— 两条路的「新增 / 更新 / 不可导入」口径、
         * 名称兜底的 id 改写、以及凭票据落库的流程完全一致。
         */
        post("/sources/import-json/preview") {
            if (auth.requireSession(call, true) == null) return@post
            val request = runCatching { call.receive<LocalSourcePreviewRequest>() }.getOrNull()
                ?: return@post call.respondApiError(HttpStatusCode.BadRequest, "invalid_request", "请求格式无效")
            try {
                call.respond(networkImport.previewLocal(request.content, request.label))
            } catch (error: NetworkImportException) {
                call.respondApiError(HttpStatusCode.BadRequest, error.code, error.message)
            }
        }
        /**
         * 网络书源导入：**确认落库**。
         *
         * `selected` 是预览列表下标；`group` 为空表示不改动分组（新源落「未分组」）。
         */
        post("/sources/import-url/commit") {
            if (auth.requireSession(call, true) == null) return@post
            val request = runCatching { call.receive<NetworkImportCommitRequest>() }.getOrNull()
                ?: return@post call.respondApiError(HttpStatusCode.BadRequest, "invalid_request", "请求格式无效")
            try {
                call.respond(networkImport.commit(request.token, request.selected, request.group))
            } catch (error: NetworkImportException) {
                call.respondApiError(HttpStatusCode.BadRequest, error.code, error.message)
            } catch (error: IllegalArgumentException) {
                call.respondApiError(HttpStatusCode.BadRequest, "invalid_source", error.message ?: "书源无效")
            }
        }
        route("/sources/{id}") {
            get {
                if (auth.requireSession(call) == null) return@get
                val source = database.getSource(call.parameters["id"]!!)
                if (source == null) call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")) else call.respond(source)
            }
            put {
                if (auth.requireSession(call, true) == null) return@put
                val request = call.receive<SourceWriteRequest>()
                try { call.respond(database.saveSource(SourceCodec.parse(request.json), request.version)); call.application.log.info("source updated: {}", call.parameters["id"]) }
                catch (_: VersionConflict) { call.respond(HttpStatusCode.Conflict, ApiError("version_conflict", "书源已在其他页面更新，请刷新后重试")) }
                catch (error: IllegalArgumentException) { call.respond(HttpStatusCode.BadRequest, ApiError("invalid_source", error.message ?: "书源无效")) }
            }
            delete {
                if (auth.requireSession(call, true) == null) return@delete
                if (database.deleteSource(call.parameters["id"]!!)) { call.application.log.info("source deleted: {}", call.parameters["id"]); call.respond(HttpStatusCode.NoContent) } else call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
            }
            post("/validate") {
                if (auth.requireSession(call, true) == null) return@post
                val source = database.getSource(call.parameters["id"]!!) ?: run { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")); return@post }
                call.respond(SourceCodec.validate(source.json))
            }
            get("/debug") {
                if (auth.requireSession(call) == null) return@get
                val source = database.getSource(call.parameters["id"]!!) ?: run { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")); return@get }
                call.response.cacheControl(CacheControl.NoStore(null)); call.response.headers.append(HttpHeaders.ContentType, ContentType.Text.EventStream.toString())
                call.respondTextWriter(ContentType.Text.EventStream) {
                    write("event: start\ndata: ${jsonEvent("开始调试 ${source.id}")}\n\n"); flush(); delay(20)
                    val validation = SourceCodec.validate(source.json)
                    if (!validation.valid) write("event: error\ndata: ${jsonEvent(validation.errors.joinToString())}\n\n")
                    else {
                        val keyword = call.request.queryParameters["keyword"] ?: "测试"
                        runCatching { runner.search(source.json, keyword) }
                            .onSuccess { results -> write("event: result\ndata: ${jsonEvent("搜索完成：${results.size} 项")}\n\n") }
                            .onFailure { error -> write("event: error\ndata: ${jsonEvent(error.message ?: "执行失败")}\n\n") }
                    }
                    flush()
                }
            }
            get("/login-ui") {
                if (auth.requireSession(call) == null) return@get
                val source = database.getSource(call.parameters["id"]!!) ?: run { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")); return@get }
                val items = runCatching { runner.parseLoginUi(source.json) }.getOrElse { error ->
                    call.respond(HttpStatusCode.BadRequest, ApiError("login_ui_invalid", error.message ?: "登录界面解析失败"))
                    return@get
                }
                val state = database.getSourceLoginState(source.id)
                val sourceObj = runCatching { Json.parseToJsonElement(source.json).jsonObject }.getOrNull()
                val sourceName = (sourceObj?.get("bookSourceName") as? JsonPrimitive)?.contentOrNull ?: source.id
                val loginUrl = (sourceObj?.get("loginUrl") as? JsonPrimitive)?.contentOrNull
                call.respond(
                    SourceLoginUiResponse(
                        sourceId = source.id,
                        sourceName = sourceName,
                        hasLogin = items.isNotEmpty() || !loginUrl.isNullOrBlank() || sourceObj?.get("loginCheckJs") != null,
                        loginUi = items,
                        loginUrl = loginUrl,
                        loginInfo = state?.loginInfo ?: emptyMap(),
                        loginHeader = state?.loginHeader,
                        sourceVariable = state?.sourceVariable,
                    )
                )
            }
            post("/login-info") {
                if (auth.requireSession(call, true) == null) return@post
                val sourceId = call.parameters["id"]!!
                val req = call.receive<SourceLoginInfoUpdateRequest>()
                database.saveSourceLoginInfo(sourceId, req.loginInfo)
                call.respond(mapOf("ok" to true))
            }
            delete("/login-info") {
                if (auth.requireSession(call, true) == null) return@delete
                val sourceId = call.parameters["id"]!!
                database.removeSourceLoginInfo(sourceId)
                call.respond(mapOf("ok" to true))
            }
            post("/login-header") {
                if (auth.requireSession(call, true) == null) return@post
                val sourceId = call.parameters["id"]!!
                val req = call.receive<SourceLoginHeaderUpdateRequest>()
                database.saveSourceLoginHeader(sourceId, req.loginHeader)
                call.respond(mapOf("ok" to true))
            }
            post("/login-cookie") {
                if (auth.requireSession(call, true) == null) return@post
                val source = database.getSource(call.parameters["id"]!!)
                    ?: run { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")); return@post }
                val resolvedSourceId = source.id
                val req = call.receive<SourceLoginCookieUpdateRequest>()
                val rawCookie = req.cookie.trim()
                var savedCount = 0
                if (rawCookie.isNotEmpty()) {
                    val cookieMap = database.parseCookieString(rawCookie)
                    savedCount = cookieMap.size
                    database.setSourceCookie(resolvedSourceId, req.url ?: resolvedSourceId, rawCookie)
                    val cookieStr = cookieMap.entries.joinToString("; ") { "${it.key}=${it.value}" }
                    val state = database.getSourceLoginState(resolvedSourceId)
                    if (state?.loginHeader.isNullOrBlank() && cookieStr.isNotBlank()) {
                        val headerMap = mapOf("Cookie" to cookieStr)
                        database.saveSourceLoginHeader(resolvedSourceId, Json.encodeToString(headerMap), syncCookie = false)
                    }
                    call.application.log.info("cookie synchronized for source: {}, count: {}", resolvedSourceId, savedCount)
                }
                call.respond(SourceLoginCookieResponse(ok = true, message = "Cookie 同步成功", count = savedCount))
            }
            delete("/login-header") {
                if (auth.requireSession(call, true) == null) return@delete
                val sourceId = call.parameters["id"]!!
                database.removeSourceLoginHeader(sourceId)
                call.respond(mapOf("ok" to true))
            }
            post("/login-action") {
                if (auth.requireSession(call, true) == null) return@post
                val source = database.getSource(call.parameters["id"]!!) ?: run { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")); return@post }
                val req = call.receive<SourceLoginActionRequest>()
                val bookRequest = req.book
                if (bookRequest != null && (bookRequest.sourceId != source.id ||
                    bookRequest.bookUrl.isBlank() || BookKind.isLocalRef(source.id, bookRequest.bookUrl))
                ) {
                    return@post call.respondApiError(HttpStatusCode.BadRequest, "invalid_book", "书籍与当前书源不匹配")
                }
                val book = bookRequest?.let {
                    database.bookContext(source.id, it.bookUrl, it.toBookContextOverlay())
                }
                val chapter = req.chapter?.takeIf { book != null && it.url.isNotBlank() }
                val previousVariables = book?.variables.orEmpty().toMap()
                val targets = mutableSetOf<SourceLoginRefreshTarget>()
                val outcome = runInterruptible(Dispatchers.IO) {
                    runner.executeLoginAction(
                        source.json,
                        req.action,
                        req.loginData,
                        req.isLongClick,
                        browserRuntime?.let(::SourceBrowserHook),
                        book,
                        chapter,
                        targets,
                    )
                }
                val refresh = if (outcome.success && book != null) {
                    refreshSourceLoginBook(source, book, chapter, targets, previousVariables)
                } else null
                call.respond(outcome.copy(bookRefresh = refresh))
            }
            get("/login-check") {
                if (auth.requireSession(call) == null) return@get
                val source = database.getSource(call.parameters["id"]!!) ?: run { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")); return@get }
                val check = runner.checkLoginStatus(source.json)
                call.respond(check)
            }
            route("/browser") {
                post("/session") {
                    if (auth.requireSession(call, true) == null) return@post
                    val source = database.getSource(call.parameters["id"]!!) ?: run { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在")); return@post }
                    val sourceObj = runCatching { Json.parseToJsonElement(source.json).jsonObject }.getOrNull()
                    val loginUrl = (sourceObj?.get("loginUrl") as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.startsWith("http") }
                    val sourceUrl = (sourceObj?.get("bookSourceUrl") as? JsonPrimitive)?.contentOrNull?.trim()
                    val homeUrl = sourceUrl?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
                    // 书源 JS 里的 java.startBrowserAwait(url) 会给出真实入口，优先级最高
                    val requestedRaw = runCatching { call.receive<SourceBrowserSessionRequest>() }.getOrNull()?.url?.trim()
                    val requestedHttp = requestedRaw?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
                    val inlineOnly = requestedRaw != null && requestedHttp == null && webView.isInlineDataUrl(requestedRaw)
                    if (requestedRaw != null && requestedHttp == null && !inlineOnly) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("unsupported_url", "内置浏览器仅支持 HTTP(S) 地址或书源脚本生成的内置页面"))
                        return@post
                    }
                    val startUrl = requestedHttp ?: loginUrl ?: homeUrl ?: WebViewProxy.defaultStartUrl(source.json)
                    if (startUrl == null && !inlineOnly) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("no_login_url", "该书源未配置 loginUrl，且书源内容中没有任何网址，无法打开内置浏览器"))
                        return@post
                    }
                    val token = webView.issueTicket(source.id, source.json, startUrl)
                    call.application.log.info("webview session opened for source: {}, start: {}, inline: {}", source.id, startUrl ?: "(内置页面)", inlineOnly)
                    call.respond(
                        SourceBrowserSessionResponse(
                            token = token,
                            startUrl = startUrl ?: "",
                            expiresInSeconds = 1800,
                            inlineOnly = inlineOnly,
                        )
                    )
                }
                delete("/session") {
                    if (auth.requireSession(call, true) == null) return@delete
                    call.request.queryParameters["t"]?.let { webView.revokeTicket(it) }
                    call.respond(HttpStatusCode.NoContent)
                }
                get("/cookies") {
                    if (auth.requireSession(call) == null) return@get
                    val sourceId = call.parameters["id"]!!
                    val jar = withContext(Dispatchers.IO) { webView.jarSnapshot(sourceId) }
                    call.respond(SourceBrowserCookieResponse(count = jar.size, domains = jar.keys.toList(), cookies = jar))
                }
                get("/page") {
                    val sourceId = call.parameters["id"]!!
                    val token = call.request.queryParameters["t"]
                    if (token.isNullOrBlank()) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("missing_parameter", "缺少 token 参数"))
                        return@get
                    }
                    // i = 服务端托管的内置页面（书源 JS 生成的数据地址，直接进 URL 会超出请求行上限）
                    val inlineKey = call.request.queryParameters["i"]
                    if (!inlineKey.isNullOrBlank()) {
                        call.respondProxied { webView.openInlinePage(sourceId, token, inlineKey) }
                        return@get
                    }
                    val target = call.request.queryParameters["u"]
                    if (target.isNullOrBlank()) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("missing_parameter", "缺少 u 参数"))
                        return@get
                    }
                    call.respondProxied { webView.openPage(sourceId, token, target) }
                }
                post("/inline") {
                    if (auth.requireSession(call, true) == null) return@post
                    val sourceId = call.parameters["id"]!!
                    val req = call.receive<SourceBrowserInlineRequest>()
                    try {
                        val key = webView.registerInlinePage(sourceId, req.token, req.url)
                        call.respond(SourceBrowserInlineResponse(key = key))
                    } catch (error: WebViewException) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("inline_page_failed", error.message ?: "内置页面无法打开"))
                    }
                }
                // 书源自生成页面（设置中心 / 段评气泡）的结果回传：等价于安卓端 startBrowserAwait 的返回体
                post("/result") {
                    if (auth.requireSession(call, true) == null) return@post
                    val sourceId = call.parameters["id"]!!
                    val req = runCatching { call.receive<SourceBrowserResultRequest>() }.getOrNull()
                        ?: run {
                            call.respondApiError(HttpStatusCode.BadRequest, "invalid_browser_result", "设置结果格式无效")
                            return@post
                        }
                    if (database.getSource(sourceId) == null) {
                        call.respondApiError(HttpStatusCode.NotFound, "not_found", "书源不存在")
                        return@post
                    }
                    if (!webView.hasTicket(sourceId, req.token)) {
                        call.respondApiError(HttpStatusCode.BadRequest, "browser_session_expired", "内置浏览器会话已失效，请重新打开设置中心")
                        return@post
                    }
                    val settings = WebViewProxy.normalizeSettingsResult(req.settings)
                        ?: run {
                            call.respondApiError(HttpStatusCode.BadRequest, "invalid_settings_result", "设置结果无法识别")
                            return@post
                        }
                    database.saveSourceVariable(sourceId, settings.toString())
                    call.application.log.info(
                        "source settings saved: {} ({} keys, container={})",
                        sourceId, settings.size, req.resultId.ifBlank { "unknown" },
                    )
                    call.respond(SourceBrowserResultResponse(saved = true, keys = settings.size))
                }
                get("/res") {
                    val sourceId = call.parameters["id"]!!
                    val token = call.request.queryParameters["t"]
                    val target = call.request.queryParameters["u"]
                    if (token.isNullOrBlank() || target.isNullOrBlank()) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("missing_parameter", "缺少 token 或 u 参数"))
                        return@get
                    }
                    call.respondProxied { webView.openResource(sourceId, token, target) }
                }
                get("/submit") {
                    val sourceId = call.parameters["id"]!!
                    val token = call.request.queryParameters["t"]
                    val base = call.request.queryParameters["u"]
                    if (token.isNullOrBlank() || base.isNullOrBlank()) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("missing_parameter", "缺少 token 或 u 参数"))
                        return@get
                    }
                    val extras = call.request.queryParameters.entries()
                        .filter { it.key != "t" && it.key != "u" }
                        .flatMap { entry -> entry.value.map { "${URLEncoder.encode(entry.key, Charsets.UTF_8)}=${URLEncoder.encode(it, Charsets.UTF_8)}" } }
                    val target = if (extras.isEmpty()) base else base + (if (base.contains('?')) "&" else "?") + extras.joinToString("&")
                    call.respondProxied { webView.submitForm(sourceId, token, target, "GET", null, ByteArray(0)) }
                }
                post("/submit") {
                    val sourceId = call.parameters["id"]!!
                    val token = call.request.queryParameters["t"]
                    val target = call.request.queryParameters["u"]
                    if (token.isNullOrBlank() || target.isNullOrBlank()) {
                        call.respond(HttpStatusCode.BadRequest, ApiError("missing_parameter", "缺少 token 或 u 参数"))
                        return@post
                    }
                    val body = call.receiveStream().readBytes()
                    val contentType = call.request.headers[HttpHeaders.ContentType]
                    call.respondProxied { webView.submitForm(sourceId, token, target, "POST", contentType, body) }
                }
            }
        }
        post("/search") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<SearchRequest>()
            val kw = request.effectiveKeyword
            if (kw.isBlank()) { call.respond(HttpStatusCode.BadRequest, ApiError("invalid_keyword", "请输入搜索关键词")); return@post }
            val sourceRecords = database.listSearchSourceRecordsForScope(request.sourceIds, request.groups, request.group)
            // 未显式指定范围的「全部书源」搜索才封顶，避免一次搜索打满所有书源。
            // 用户一旦选了分组或书源，就是明确的收窄意图，应当整组都跑。
            val explicitScope = request.sourceIds.orEmpty().isNotEmpty() || request.groups.any { it.isNotBlank() } || !request.group.isNullOrBlank()
            val searchRecords = if (!explicitScope && sourceRecords.size > 20) sourceRecords.take(20) else sourceRecords
            val singleSource = explicitScope && searchRecords.size == 1
            if (singleSource) {
                // 单源搜索失败必须返回具体阶段原因，不允许吞成空数组冒充成功。
                val outcome = searchSourceOutcome(runner, searchRecords.first().json, kw, request.page)
                if (outcome.failed) {
                    call.respond(HttpStatusCode.BadGateway, ApiError("source_execution_failed", outcome.error ?: "书源搜索失败"))
                    return@post
                }
                call.respond(outcome.results)
                return@post
            }
            val results = boundedConcurrentMap(searchRecords, sourceSearchConcurrency()) { source -> readableSearchResults(runner, source.json, kw, request.page) }.flatten()
            call.respond(results)
        }
        webSocket("/search/stream") {
            val csrf = call.request.queryParameters["csrf"]
            if (!auth.hasWebSocketSession(call, csrf)) {
                close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, "请先登录"))
                return@webSocket
            }
            val request = (incoming.receive() as? Frame.Text)?.readText()?.let { text -> runCatching { Json.decodeFromString<SearchRequest>(text) }.getOrNull() }
            val kw = request?.effectiveKeyword
            if (kw.isNullOrBlank()) {
                send(Frame.Text(Json.encodeToString(SearchStreamEvent("error", message = "请输入搜索关键词"))))
                close(CloseReason(CloseReason.Codes.CANNOT_ACCEPT, "搜索条件无效"))
                return@webSocket
            }
            val sourceRecords = database.listSearchSourceRecordsForScope(request.sourceIds, request.groups, request.group)
            send(Frame.Text(Json.encodeToString(SearchStreamEvent("start", totalSources = sourceRecords.size))))
            coroutineScope {
                val events = Channel<SearchStreamEvent>(Channel.BUFFERED)
                val counters = SearchStreamCounters(sourceRecords.size)
                val semaphore = Semaphore(sourceSearchConcurrency())
                val workers = sourceRecords.map { source -> async {
                    semaphore.withPermit {
                        if (!isActive) return@async
                        val outcome = searchSourceOutcome(runner, source.json, kw, request?.page ?: 1)
                        if (!isActive) return@async
                        runCatching {
                            if (outcome.results.isNotEmpty()) events.send(SearchStreamEvent("results", results = outcome.results))
                            if (outcome.failed) {
                                events.send(SearchStreamEvent("source_failed", sourceId = source.id, error = outcome.error))
                            }
                            events.send(counters.complete(outcome))
                        }
                    }
                } }
                val completionJob = launch {
                    try {
                        workers.awaitAll()
                        runCatching { events.send(counters.snapshot("done")) }
                    } catch (_: CancellationException) {
                        // Workers were cancelled
                    } finally {
                        events.close()
                    }
                }
                val cancellationMonitor = launch {
                    try {
                        for (frame in incoming) {
                            if (frame is Frame.Text && frame.readText().contains("\"cancel\"")) break
                        }
                    } catch (_: Throwable) {
                        // Incoming channel closed
                    } finally {
                        workers.forEach { it.cancel() }
                        completionJob.cancel()
                        events.close()
                    }
                }
                try {
                    for (event in events) send(Frame.Text(Json.encodeToString(event)))
                } catch (_: Throwable) {
                    // Socket closed or disconnected
                } finally {
                    cancellationMonitor.cancel()
                    completionJob.cancel()
                    workers.forEach { it.cancel() }
                    events.close()
                }
            }
        }
        get("/subscriptions") {
            if (auth.requireSession(call) == null) return@get
            call.respond(database.listSubscriptions())
        }
        post("/subscriptions") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<SubscriptionWriteRequest>()
            try {
                validateSubscriptionUrl(request.url)
                call.respond(database.saveSubscription(request))
            } catch (error: IllegalArgumentException) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_subscription", error.message ?: "订阅地址无效"))
            }
        }
        delete("/subscriptions/{id}") {
            if (auth.requireSession(call, true) == null) return@delete
            val id = call.parameters["id"]?.toLongOrNull() ?: return@delete call.respond(HttpStatusCode.BadRequest, ApiError("invalid_subscription", "订阅标识无效"))
            if (database.deleteSubscription(id)) call.respond(HttpStatusCode.NoContent) else call.respond(HttpStatusCode.NotFound, ApiError("not_found", "订阅不存在"))
        }
        post("/subscriptions/{id}/update") {
            if (auth.requireSession(call, true) == null) return@post
            val id = call.parameters["id"]?.toLongOrNull() ?: return@post call.respond(HttpStatusCode.BadRequest, ApiError("invalid_subscription", "订阅标识无效"))
            try { call.respond(subscriptions.updateOne(id)) }
            catch (_: NoSuchElementException) { call.respond(HttpStatusCode.NotFound, ApiError("not_found", "订阅不存在")) }
            catch (error: Throwable) { call.respond(HttpStatusCode.BadGateway, ApiError("subscription_update_failed", error.message ?: "订阅更新失败")) }
        }
        post("/subscriptions/update") {
            if (auth.requireSession(call, true) == null) return@post
            val results = subscriptions.updateAll()
            call.respond(mapOf("updated" to results.count { it.second.isSuccess }, "failed" to results.count { it.second.isFailure }))
        }
        post("/books/details") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<BookRequest>()
            val isLocal = request.sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID
            // 「书源不存在」与「本地书不在书架」是两条既有 404 契约，先在这里区分，
            // 再把真正的取详情交给 [fetchBookDetails]（封面深度回源补抓复用同一份逻辑）。
            if (!isLocal && database.getSource(request.sourceId) == null) {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
                return@post
            }
            if (isLocal && database.listBookshelf().none { it.sourceId == request.sourceId && it.bookUrl == request.bookUrl }) {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "本地书籍不存在"))
                return@post
            }
            call.respondCatching {
                fetchBookDetails(database, runner, request.sourceId, request.bookUrl, request.toBookContextOverlay())!!
            }
        }
        post("/books/chapters") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<BookRequest>()
            val requestTocUrlHint = request.tocUrl?.takeIf { it.isNotBlank() && it != request.bookUrl }
            val cachedToc = if (requestTocUrlHint != null) {
                database.getTocCache(request.sourceId, requestTocUrlHint)
            } else {
                database.getTocCache(request.sourceId, request.bookUrl)
                    ?: database.getTocCache(request.sourceId, request.bookUrl.removeSuffix("/toc") + "/toc")
            }
            if (cachedToc != null && cachedToc.isNotEmpty()) {
                call.respond(cachedToc)
                return@post
            }
            val fallbackFromContent = database.getCachedChaptersFallback(request.sourceId, request.bookUrl)
            if (request.sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID) {
                if (fallbackFromContent.isNotEmpty()) {
                    call.respond(fallbackFromContent)
                } else {
                    call.respond(HttpStatusCode.NotFound, ApiError("not_found", "本地书籍目录不存在"))
                }
                return@post
            }
            val source = database.getSource(request.sourceId) ?: run {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
                return@post
            }
            call.respondCatching {
                try {
                    withContext(Dispatchers.IO) {
                        withTimeout(CHAPTERS_TIMEOUT_MS) {
                            // 书籍上下文（含变量）同样要进目录规则：Legado 的 `getChapters(book)` 就带着 Book。
                            val book = database.bookContext(request.sourceId, request.bookUrl, request.toBookContextOverlay())
                            // 与后台缓存**共用同一个**取目录实现（含 details 回退），杜绝"能读不能缓存"。
                            val chapters = resolveBookChapters(
                                database, runner, request.sourceId, request.bookUrl, source.json, book,
                                tocUrlHint = book.tocUrl,
                            )
                            database.persistBookVariables(book)
                            chapters
                        }
                    }
                } catch (error: Throwable) {
                    // 客户端主动取消必须原样传播（协程取消协议）；120s 分页预算超时
                    // 是 TimeoutCancellationException，仍按既有行为转为 RuleExecutionException。
                    if (error is CancellationException && error !is TimeoutCancellationException) throw error
                    if (fallbackFromContent.isNotEmpty()) {
                        fallbackFromContent
                    } else {
                        throw (error as? RuleExecutionException ?: RuleExecutionException(error.message ?: "获取章节列表失败"))
                    }
                }
            }
        }
        route("/replace-rules") {
            get {
                if (auth.requireSession(call) == null) return@get
                val q = call.request.queryParameters["q"]
                val group = call.request.queryParameters["group"]
                val scope = call.request.queryParameters["scope"] ?: call.request.queryParameters["bookName"]
                call.respond(database.listReplaceRules(q, group, scope))
            }
            get("/{id}") {
                if (auth.requireSession(call) == null) return@get
                val id = call.parameters["id"] ?: return@get call.respond(HttpStatusCode.BadRequest, ApiError("invalid_id", "缺少规则 ID"))
                database.getReplaceRule(id)?.let { call.respond(it) } ?: call.respond(HttpStatusCode.NotFound, ApiError("not_found", "规则不存在"))
            }
            post {
                if (auth.requireSession(call, true) == null) return@post
                val rule = call.receive<ReplaceRule>()
                if (rule.pattern.isBlank()) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_rule", "匹配模式不能为空"))
                    return@post
                }
                call.respond(database.saveReplaceRule(rule))
            }
            put("/{id}") {
                if (auth.requireSession(call, true) == null) return@put
                val id = call.parameters["id"] ?: return@put call.respond(HttpStatusCode.BadRequest, ApiError("invalid_id", "缺少规则 ID"))
                val rule = call.receive<ReplaceRule>().copy(id = id)
                if (rule.pattern.isBlank()) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_rule", "匹配模式不能为空"))
                    return@put
                }
                call.respond(database.saveReplaceRule(rule))
            }
            delete("/{id}") {
                if (auth.requireSession(call, true) == null) return@delete
                val id = call.parameters["id"] ?: return@delete call.respond(HttpStatusCode.BadRequest, ApiError("invalid_id", "缺少规则 ID"))
                if (database.deleteReplaceRule(id)) call.respond(HttpStatusCode.NoContent)
                else call.respond(HttpStatusCode.NotFound, ApiError("not_found", "规则不存在"))
            }
            post("/delete-batch") {
                if (auth.requireSession(call, true) == null) return@post
                val ids = call.receive<List<String>>()
                val count = database.deleteReplaceRules(ids)
                call.respond(mapOf("deleted" to count))
            }
            post("/toggle") {
                if (auth.requireSession(call, true) == null) return@post
                val req = call.receive<ReplaceRuleToggleRequest>()
                val count = database.toggleReplaceRules(req.ids, req.enabled)
                call.respond(mapOf("updated" to count))
            }
            post("/batch") {
                if (auth.requireSession(call, true) == null) return@post
                val req = call.receive<BatchReplaceRuleRequest>()
                if (req.ids.isEmpty()) {
                    call.respond(BatchReplaceRuleResponse(ok = true, affected = 0, action = req.action))
                    return@post
                }
                when (req.action) {
                    "enable" -> {
                        val count = database.toggleReplaceRules(req.ids, true)
                        call.respond(BatchReplaceRuleResponse(ok = true, affected = count, action = req.action))
                    }
                    "disable" -> {
                        val count = database.toggleReplaceRules(req.ids, false)
                        call.respond(BatchReplaceRuleResponse(ok = true, affected = count, action = req.action))
                    }
                    "delete" -> {
                        val count = database.deleteReplaceRules(req.ids)
                        call.respond(BatchReplaceRuleResponse(ok = true, affected = count, action = req.action))
                    }
                    "set_group" -> {
                        val count = database.batchSetReplaceRulesGroup(req.ids, req.group)
                        call.respond(BatchReplaceRuleResponse(ok = true, affected = count, action = req.action))
                    }
                    else -> call.respond(HttpStatusCode.BadRequest, ApiError("invalid_action", "未知的批量操作: ${req.action}"))
                }
            }
            get("/export") {
                if (auth.requireSession(call) == null) return@get
                val ids = call.request.queryParameters.getAll("id")
                call.respondText(
                    text = Json.encodeToString(database.exportReplaceRules(ids)),
                    contentType = ContentType.Application.Json.withCharset(Charsets.UTF_8),
                )
            }
            post("/import") {
                if (auth.requireSession(call, true) == null) return@post
                val bodyText = call.receiveText()
                val parsedRules = parseImportedReplaceRules(bodyText)
                val response = database.importReplaceRules(parsedRules)
                call.respond(response)
            }
            post("/preview") {
                if (auth.requireSession(call) == null) return@post
                val req = call.receive<ReplaceRulePreviewRequest>()
                val rules = if (req.rule != null) listOf(req.rule) else database.getEnabledReplaceRulesForScope(req.bookName, req.sourceUrl)
                val jsSandbox = JsSandbox(runner)
                val cleaned = ContentProcessor.processContent(req.text, rules, jsSandbox = jsSandbox, bookName = req.bookName)
                val appliedNames = rules.filter { ContentProcessor.applyRule(req.text, it, jsSandbox = jsSandbox, bookName = req.bookName) != req.text }.map { it.name.ifBlank { it.pattern } }
                call.respond(ReplaceRulePreviewResponse(
                    originalText = req.text,
                    cleanedText = cleaned,
                    changed = cleaned != req.text,
                    appliedRules = appliedNames,
                ))
            }
        }
        route("/replace-rule-groups") {
            get {
                if (auth.requireSession(call) == null) return@get
                call.respond(database.listReplaceRuleGroups())
            }
            put("/rename") {
                if (auth.requireSession(call, true) == null) return@put
                val request = call.receive<ReplaceRuleGroupRenameRequest>()
                val from = request.from.trim()
                val to = request.to.trim()
                if (from.isBlank() || to.isBlank()) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_name", "原分组名与新分组名均不能为空"))
                    return@put
                }
                if (to.equals(SourceGroupFilter.UNGROUPED, ignoreCase = true)) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("reserved_name", "不能使用系统保留字「$to」作为分组名称"))
                    return@put
                }
                if (from.equals(to, ignoreCase = true)) {
                    call.respond(ReplaceRuleGroupMutationResponse(ok = true, affected = 0, message = "分组名未变化"))
                    return@put
                }
                val affected = database.renameReplaceRuleGroup(from, to)
                call.respond(ReplaceRuleGroupMutationResponse(ok = true, affected = affected, message = "已将 $affected 条规则从「$from」移到分组「$to」"))
            }
            delete {
                if (auth.requireSession(call, true) == null) return@delete
                val name = call.request.queryParameters["name"]?.trim().orEmpty()
                if (name.isBlank()) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("missing_name", "缺少分组名称"))
                    return@delete
                }
                val affected = database.clearReplaceRuleGroup(name)
                call.respond(ReplaceRuleGroupMutationResponse(ok = true, affected = affected, message = "已删除分组「$name」，$affected 条规则变为未分组（规则未被删除）"))
            }
        }
        post("/books/content") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<ContentRequest>()
            if (request.sourceId.isBlank() || request.chapterUrl.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_content", "缺少书源或章节地址"))
                return@post
            }
            val bookUrl = request.bookUrl ?: if (request.chapterUrl.startsWith("local://")) {
                request.chapterUrl.substringBeforeLast('/')
            } else null
            val bookName = request.bookName ?: bookUrl?.let { url ->
                database.listBookshelf().firstOrNull { it.sourceId == request.sourceId && it.bookUrl == url }?.name
            }
            val cached = bookUrl?.let { database.cachedContent(request.sourceId, it, request.chapterUrl) }

            if (request.sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID) {
                if (cached != null) {
                    val rules = database.getEnabledReplaceRulesForScope(bookName, "local://")
                    val jsSandbox = JsSandbox(runner)
                    val cleaned = ContentProcessor.processContent(cached.content, rules, jsSandbox = jsSandbox, bookName = bookName, chapterTitle = cached.title)
                    val cleanedTitle = cached.title?.let { ContentProcessor.processTitle(it, rules, jsSandbox = jsSandbox, bookName = bookName) }
                    call.respond(ChapterContent(title = cleanedTitle ?: cached.title, content = cleaned))
                } else {
                    call.respond(HttpStatusCode.NotFound, ApiError("not_found", "本地章节内容不存在"))
                }
                return@post
            }

            val source = database.getSource(request.sourceId) ?: run {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
                return@post
            }
            // 正文里的插图按**出现顺序**登记一次（序号定死的唯一时机）：
            // 离线缓存与在线代理都按这份登记表取序号，缺它就只能"追加到章末"。
            // 任何失败都静默 —— 登记只是索引，绝不该让正文接口失败。
            fun rememberIllustrations(content: ChapterContent) {
                illustrationCache?.let { cache ->
                    bookUrl?.takeIf { it.isNotBlank() }?.let { url ->
                        runCatching { cache.registerFromContent(request.sourceId, url, request.chapterUrl, 0, content.content) }
                    }
                }
            }
            if (cached != null && cached.content.isNotBlank()) {
                rememberIllustrations(cached)
                call.respond(cached)
            } else call.respondCatching {
                try {
                    // 书籍上下文（含变量）：正文规则里 `book.getVariable('custom')` 与 `book.variable`
                    // 都靠它 —— 听书音色、按书切换线路的书源都依赖这一条。
                    // bookUrl 未知时传 null，保持与从前一致（book 各字段为空串）。
                    val book = bookUrl?.let { url -> database.bookContext(request.sourceId, url, request.toBookContextOverlay(url)) }
                    runner.content(source.json, request.chapterUrl, bookName, book).also { content ->
                        bookUrl?.let { database.cacheBookContent(request.sourceId, it, request.chapterUrl, content) }
                        rememberIllustrations(content)
                        book?.let { database.persistBookVariables(it) }
                    }
                } catch (error: Throwable) {
                    if (cached != null && cached.content.isNotBlank()) cached
                    else throw error
                }
            }
        }
        post("/books/images/manifest") {
            if (auth.requireSession(call) == null) return@post
            val request = call.receive<MangaManifestRequest>()
            if (request.sourceId.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少书源"))
                return@post
            }
            val chapterUrl = request.chapterUrl
            if (chapterUrl.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少章节地址"))
                return@post
            }
            val source = database.getSource(request.sourceId)
                ?: return@post call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
            val bookUrl = request.bookUrl ?: if (chapterUrl.startsWith("local://")) chapterUrl.substringBeforeLast('/') else ""

            // 书自身的类型说法（`tab=漫画`）或书源声明 ⇒ 顺手把书架类型修好
            // （修复「解析器识别之前加进书架的老漫画」——幂等回填）。
            // ⚠️ 必须让**书自己**优先：聚合源不声明 `bookSourceType`，只看源声明会把漫画判成小说。
            if (bookUrl.isNotBlank()) {
                BookKind.resolveOrNull(null, bookUrl, source.json)?.let { kind ->
                    database.setBookKindSilently(request.sourceId, bookUrl, kind)
                }
            }

            // ① L2 命中：清单已在本地 ⇒ **完全不再回源抓章节页**（二次打开零上游请求）
            val existing = database.getMangaChapter(request.sourceId, bookUrl, chapterUrl)
            val urls: List<String> = existing?.let { decodeMangaImageUrls(it.imagesJson) }
                ?: run {
                    // ② 首次解析：失败一律 502 `source_execution_failed` + 真实原因，与
                    // `/books/content` 一致（抛 500「服务器内部错误」会把「书源规则没配好」
                    // 伪装成「服务端故障」，是最容易误导排障的形态）。
                    val parsed = runCatching {
                        val book = bookUrl.takeIf { it.isNotBlank() }?.let { database.bookContext(request.sourceId, it) }
                        try {
                            runner.mangaImages(source.json, chapterUrl, bookName = null, book = book)
                        } finally {
                            book?.let { database.persistBookVariables(it) }
                        }
                    }
                    val failure = parsed.exceptionOrNull()
                    if (failure != null) {
                        call.respond(
                            HttpStatusCode.BadGateway,
                            ApiError("source_execution_failed", failure.message ?: "图片清单解析失败"),
                        )
                        return@post
                    }
                    val list = parsed.getOrThrow()
                    database.saveMangaChapter(
                        MangaChapterRecord(
                            sourceId = request.sourceId,
                            bookUrl = bookUrl,
                            chapterUrl = chapterUrl,
                            chapterIndex = request.chapterIndex,
                            imagesJson = encodeMangaImageUrls(list),
                            total = list.size,
                            state = "pending",
                        ),
                    )
                    list
                }

            // ③ 登记 (key → 上游地址) 并刷新整章就绪度。
            // 清单只回 **key**：上游 URL 留在服务端，否则前端会绕过字节缓存直连
            //（防盗链、离线、去重全部失效，属"死配置"类错误）。
            imageCache.registerChapter(request.sourceId, bookUrl, chapterUrl, request.chapterIndex, urls)
            imageCache.refreshChapterReadiness(request.sourceId, bookUrl, chapterUrl)
            val rows = imageCache.chapterRows(request.sourceId, bookUrl, chapterUrl)
            val chapter = database.getMangaChapter(request.sourceId, bookUrl, chapterUrl)

            call.respond(
                MangaChapterManifest(
                    sourceId = request.sourceId,
                    bookUrl = bookUrl,
                    chapterUrl = chapterUrl,
                    title = null, // 章节标题由前端从自己的目录里取，不必服务端回查
                    chapterIndex = request.chapterIndex,
                    total = rows.size,
                    ready = rows.count { it.state == "ready" },
                    state = chapter?.state ?: "pending",
                    images = rows.map {
                        MangaImageItem(
                            index = it.segmentIndex,
                            key = it.urlHash,
                            status = it.state,
                            width = it.width,
                            height = it.height,
                        )
                    },
                ),
            )
        }
        /**
         * 图片直出（**按需抓取 + 唯一字节副本**）。
         *
         * 首次请求某个 key 时服务端才去抓（受全局闸门约束），抓完落盘并直出；
         * 之后同 key 一律走本地文件。`ETag = cacheKey`（内容哈希）⇒ 可 `immutable`：
         * 内容变了 key 必变，所以浏览器/中间层可以放心长期缓存。
         */
        get("/images/{key}") {
            if (auth.requireSession(call) == null) return@get
            val key = call.parameters["key"].orEmpty()
            if (!key.matches(MANGA_IMAGE_KEY_PATTERN)) {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "图片 key 无效"))
                return@get
            }

            var row = imageCache.getByKey(key)
            if (row == null) {
                // 未就绪 ⇒ 用登记时留下的上游地址按需抓取（这是 key 不可逆的代价，也是它的防护）
                val pending = imageCache.rowByKey(key)
                    ?: return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "该 key 未登记（可能章节清单已清空）"))
                val sourceJson = database.getSource(pending.sourceId)?.json
                if (sourceJson == null) {
                    imageCache.markFailed(key, "书源不存在")
                    return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
                }
                // 防盗链的命门：Referer 必须是**章节页**，并与书源 header/Cookie 一起发
                val fetched = mangaImageFetcher.fetch(
                    upstreamUrl = pending.upstreamUrl,
                    mediaHeaders = runner.mediaHeaders(sourceJson, pending.sourceId),
                    referer = pending.chapterUrl.takeIf { it.startsWith("http") },
                    // 书源声明的图片解密（Android `ImageUtils` 的 ruleContent.imageDecode）
                    decoder = runCatching { runner.imageDecoder(sourceJson, isCover = false) }.getOrNull(),
                )
                if (fetched == null) {
                    imageCache.markFailed(key, "上游抓取失败或内容不是图片")
                    imageCache.refreshChapterReadiness(pending.sourceId, pending.bookUrl, pending.chapterUrl)
                    call.respond(HttpStatusCode.BadGateway, ApiError("image_fetch_failed", "图片抓取失败"))
                    return@get
                }
                imageCache.put(
                    sourceId = pending.sourceId,
                    bookUrl = pending.bookUrl,
                    chapterUrl = pending.chapterUrl,
                    upstreamUrl = pending.upstreamUrl,
                    contentType = fetched.contentType,
                    bytes = fetched.bytes,
                    chapterIndex = pending.chapterIndex,
                    segmentIndex = pending.segmentIndex,
                )
                imageCache.refreshChapterReadiness(pending.sourceId, pending.bookUrl, pending.chapterUrl)
                row = imageCache.rowByKey(key)
                    ?: return@get call.respond(HttpStatusCode.InternalServerError, ApiError("cache_error", "图片落盘后索引丢失"))
            }

            val file = imageCache.fileFor(row)
                ?: return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "图片文件不存在"))
            call.response.headers.append(HttpHeaders.ETag, "\"${row.cacheKey}\"")
            call.response.headers.append(HttpHeaders.CacheControl, "private, max-age=31536000, immutable")
            if (call.request.headers[HttpHeaders.IfNoneMatch]?.contains(row.cacheKey) == true) {
                call.respond(HttpStatusCode.NotModified)
                return@get
            }
            call.respond(LocalFileContent(file.toFile(), ContentType.parse(row.contentType.ifBlank { "image/jpeg" })))
        }
        get("/books/images/cache/stats") {
            if (auth.requireSession(call) == null) return@get
            call.respond(imageCache.stats())
        }
        /**
         * 小说正文**插图代理 + 落盘缓存**）。
         *
         * 为什么前端必须打这里、不能直接 `<img src="上游URL">`：
         * 1. 防盗链 —— 上游判的是书源 `header` + **章节页 Referer** + Cookie，浏览器直连必裂图；
         * 2. 离线 —— 只有服务端落盘，断网才看得到图；
         * 3. 隐私 —— 直连会把用户 IP / UA 暴露给几十个图床；
         * 4. 一致性 —— gzip 假图片、错误页冒充 jpeg、超大文件都要在**唯一收口**里拦掉。
         *
         * 命中判据：`(sourceId, 上游URL)` 的 `url_hash` 行 `ready` **且文件确实在**。
         * 未命中 ⇒ 用书源头 + 章节 Referer 抓一次 → 落盘 → 直出；失败**明确报错**（4xx/502），
         * 绝不返回空 200（空 200 在浏览器里表现为"裂图且无任何线索"）。
         *
         * 落盘命名沿用 v3：`images/<书名 (书哈希)>/<章节名 (章节哈希)>/<8位序号>.<真实扩展名>`。
         */
        get("/books/images/illustration") {
            if (auth.requireSession(call) == null) return@get
            val params = call.request.queryParameters
            val sourceId = params["sourceId"]?.trim().orEmpty()
            val chapterUrl = params["chapterUrl"]?.trim().orEmpty()
            val upstreamUrl = params["url"]?.trim().orEmpty()
            val bookUrl = params["bookUrl"]?.trim().orEmpty()
            val chapterIndex = params["chapterIndex"]?.trim()?.toIntOrNull() ?: 0
            val cache = illustrationCache
            if (cache == null) {
                call.respond(HttpStatusCode.NotFound, ApiError("illustration_disabled", "插图缓存未启用"))
                return@get
            }
            when {
                sourceId.isBlank() -> {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_illustration", "缺少书源"))
                    return@get
                }
                upstreamUrl.isBlank() -> {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_illustration", "缺少插图地址"))
                    return@get
                }
                // 只代理 http(s)：`data:`/`javascript:` 之类**永不代理**（服务端抓不到、浏览器侧又是注入面）
                !IllustrationMarkup.isHttpUrl(upstreamUrl) -> {
                    call.respond(
                        HttpStatusCode.BadRequest,
                        ApiError("invalid_illustration", "插图地址必须是 http(s) 绝对地址"),
                    )
                    return@get
                }
                chapterUrl.isBlank() -> {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_illustration", "缺少章节地址"))
                    return@get
                }
            }

            val urlHash = cache.urlHash(sourceId, upstreamUrl)
            var row = cache.getByKey(urlHash)
            if (row == null) {
                val source = database.getSource(sourceId)
                    ?: return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
                // 抓取收口：书源 header + 登录 Cookie + **章节页 Referer**，缺一必裂图
                val fetched = mangaImageFetcher.fetch(
                    upstreamUrl = upstreamUrl,
                    mediaHeaders = runner.mediaHeaders(source.json, sourceId),
                    referer = chapterUrl.takeIf { it.startsWith("http") },
                    // 书源声明的图片解密（Android `ImageUtils` 的 ruleContent.imageDecode）
                    decoder = runCatching { runner.imageDecoder(source.json, isCover = false) }.getOrNull(),
                )
                if (fetched == null) {
                    call.respond(
                        HttpStatusCode.BadGateway,
                        ApiError(
                            "illustration_fetch_failed",
                            "插图抓取失败（上游不可达、返回的不是图片，或超过单图 ${ImageBytes.MAX_BYTES} 字节上限）",
                        ),
                    )
                    return@get
                }
                // 序号：优先按**正文里的出现顺序**分配（正文取回时已登记过），拿不到就追加到章末
                val pending = cache.ensureRow(sourceId, bookUrl, chapterUrl, chapterIndex, upstreamUrl)
                row = runCatching {
                    cache.put(
                        sourceId = sourceId,
                        bookUrl = bookUrl,
                        chapterUrl = chapterUrl,
                        upstreamUrl = upstreamUrl,
                        contentType = fetched.contentType,
                        bytes = fetched.bytes,
                        chapterIndex = chapterIndex,
                        segmentIndex = pending.segmentIndex,
                    )
                }.getOrElse { error ->
                    return@get call.respond(
                        HttpStatusCode.BadGateway,
                        ApiError("illustration_cache_failed", "插图落盘失败：${error.message}"),
                    )
                }
            }

            val file = cache.fileFor(row)
                ?: return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "插图文件不存在"))
            val etag = row.cacheKey.ifBlank { urlHash }
            call.response.headers.append(HttpHeaders.ETag, "\"$etag\"")
            // 内容变了 cache_key 必变 ⇒ 可以放心 immutable（与封面/漫画同一裁决）
            call.response.headers.append(HttpHeaders.CacheControl, "private, max-age=31536000, immutable")
            if (call.request.headers[HttpHeaders.IfNoneMatch]?.contains(etag) == true) {
                call.respond(HttpStatusCode.NotModified)
                return@get
            }
            call.respond(
                LocalFileContent(file.toFile(), ContentType.parse(row.contentType.ifBlank { "image/jpeg" })),
            )
        }
        /**
         * 后台预取（环节 E8）。
         *
         * **幂等且随时可重复调用**：同一本书的重复请求不会新起并行任务，而是让正在跑的循环改目标
         * （见 `MangaPrefetchService.drain`）。返回 `202 Accepted` 表示"已受理"而非"已完成"。
         *
         * 目录**还没缓存时也照样受理**（`chapters ≥ 1`）：预取会自己把目录抓进 `book_toc_cache`。
         * 返回的 `chapters` 只是"已受理的章数"（目录未知时无法先验知道真实章数，按 1 报），
         * 真实进度一律看 `GET /books/images/prefetch` 的 `done/planned`（**章**口径）。
         */
        post("/books/images/prefetch") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<MangaPrefetchRequest>()
            if (request.sourceId.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少书源"))
                return@post
            }
            val bookUrl = request.bookUrl?.takeIf { it.isNotBlank() }
                ?: run {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少书籍地址"))
                    return@post
                }
            val service = mangaPrefetch
            if (service == null || !service.enabled) {
                // 关闭 ≠ 报错：阅读器对它的唯一正确反应是"什么都不做"
                call.respond(HttpStatusCode.Accepted, MangaPrefetchResponse(false, 0, "prefetch_disabled"))
                return@post
            }
            val chapters = service.enqueue(
                sourceId = request.sourceId,
                bookUrl = bookUrl,
                fromChapterIndex = request.fromChapterIndex,
                ahead = request.ahead,
                pin = request.pin,
            )
            if (request.pin && chapters > 0) {
                // 「整本离线」= 免死金牌，越早打越好：中途重启也不至于被 GC 从半本开始删
                database.setMangaBookPinned(request.sourceId, bookUrl, true)
            }
            call.respond(
                HttpStatusCode.Accepted,
                MangaPrefetchResponse(chapters > 0, chapters, if (chapters > 0) null else "nothing_to_prefetch"),
            )
        }
        get("/books/images/prefetch") {
            if (auth.requireSession(call) == null) return@get
            call.respond(mangaPrefetch?.status() ?: emptyList<MangaPrefetchStatus>())
        }
        /**
         * **只取消、不删缓存**的取消入口（目录底栏那个「取消缓存」按钮）。
         *
         * 为什么必须单开一条：`DELETE /books/images/cache` 里的 `cancel()` 是「清缓存顺带停任务」，
         * 直接拿它当取消按钮用，会把用户已经下好的图片连同清单一起删掉（语义不符、且不可恢复）。
         * 这里只停任务：字节、清单与 pin 一律**原样保留**，用户随时可以再点一次接着缓存。
         */
        post("/books/images/prefetch/cancel") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<MangaPrefetchRequest>()
            if (request.sourceId.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少书源"))
                return@post
            }
            val bookUrl = request.bookUrl?.takeIf { it.isNotBlank() }
                ?: run {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少书籍地址"))
                    return@post
                }
            // 服务为 null（预取功能被 `LEGADO_MANGA_PREFETCH=false` 关掉）时"已经没在跑"，等价于取消成功。
            // ⚠️ 绝不调用 `imageCache.deleteBook` / `database.deleteMangaChapters`：那是 DELETE 的语义。
            mangaPrefetch?.cancel(request.sourceId, bookUrl)
            call.respond(HttpStatusCode.NoContent)
        }
        /**
         * 「整本离线」免死金牌开关（环节 E12）。
         *
         * 只有**用户显式动作**才配得上它：自动预取绝不会自己打 pin（否则配额很快被"永久保留"吃光）。
         */
        put("/books/images/cache/pin") {
            if (auth.requireSession(call, true) == null) return@put
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            val pinned = call.request.queryParameters["pinned"]?.toBooleanStrictOrNull() ?: true
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少书籍标识"))
                return@put
            }
            database.setMangaBookPinned(sourceId, bookUrl, pinned)
            call.respond(MangaPinResponse(sourceId, bookUrl, pinned))
        }
        delete("/books/images/cache") {
            if (auth.requireSession(call, true) == null) return@delete
            if (call.request.queryParameters["all"]?.toBooleanStrictOrNull() == true) {
                // 先停预取再清：否则清理刚删完，还在跑的预取又把它抓回来（用户看到"清不干净"）
                mangaPrefetch?.cancelAll()
                imageCache.deleteAll()
                call.respond(HttpStatusCode.NoContent)
                return@delete
            }
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_manga", "缺少书籍标识"))
                return@delete
            }
            mangaPrefetch?.cancel(sourceId, bookUrl)
            imageCache.deleteBook(sourceId, bookUrl)
            // 清单也一起清：否则下次打开会拿着一张"零图片"的空清单
            database.deleteMangaChapters(sourceId, bookUrl)
            call.respond(HttpStatusCode.NoContent)
        }

        // ==================================================================
        // 有声书（方案 G2 ·  / ）
        //
        // 与漫画段**同构**（鉴权口径、契约形状、失败上报都对齐），只有三处刻意不同：
        // ① 清单项叫 track（一章可能多分段，前端按 segmentIndex 串播）；
        // ② 直出带 `ETag + immutable`（音频内容按 URL 寻址，key 稳定 ⇒ 可长期缓存）；
        // ③ 抓取失败**带原因**（整章听不了时，用户需要知道是"要登录"还是"格式不支持"）。
        // ==================================================================

        /**
         * 解析一章的音频清单。
         *
         * 与漫画同一条铁律：**只回 key + 状态，绝不回上游 URL**
         *（回了前端就会绕过字节缓存直连 ⇒ 防盗链、离线、Range 复用全部失效）。
         */
        post("/books/audio") {
            if (auth.requireSession(call) == null) return@post
            val request = call.receive<AudioManifestRequest>()
            if (request.sourceId.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书源"))
                return@post
            }
            val chapterUrl = request.chapterUrl
            if (chapterUrl.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少章节地址"))
                return@post
            }
            val source = database.getSource(request.sourceId)
                ?: return@post call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
            val bookUrl = request.bookUrl ?: if (chapterUrl.startsWith("local://")) chapterUrl.substringBeforeLast('/') else ""

            // 书自身的类型说法（`tab=听书`）或源声明 ⇒ 顺手把书架类型修好（幂等回填）。
            // ⚠️ 必须让**书自己**优先：聚合源不声明 `bookSourceType`。
            if (bookUrl.isNotBlank()) {
                BookKind.resolveOrNull(null, bookUrl, source.json)?.let { kind ->
                    database.setBookKindSilently(request.sourceId, bookUrl, kind)
                }
            }

            // ① 本地已登记 ⇒ **完全不再回源抓章节页**（二次打开零上游请求）
            val registered = audioCache.chapterRows(request.sourceId, bookUrl, chapterUrl)
            val rows = if (registered.isNotEmpty()) {
                registered
            } else {
                // ② 首次解析：规则失败一律 502 `source_execution_failed` + 真实原因
                // ⚠️ 必须带书籍上下文：音频地址由 `book.getVariable('custom')`（听书音色）参与拼装，
                // 不传就等于变量的值永远为空 ⇒ 换了音色却毫无变化（实测踩过，静默无提示）。
                val book = if (bookUrl.isNotBlank()) database.bookContext(request.sourceId, bookUrl) else null
                val parsed = runCatching { runner.audioTracks(source.json, chapterUrl, bookName = null, book = book) }
                book?.let { database.persistBookVariables(it) }
                val failure = parsed.exceptionOrNull()
                if (failure != null) {
                    call.respond(
                        HttpStatusCode.BadGateway,
                        ApiError("source_execution_failed", failure.message ?: "音频清单解析失败"),
                    )
                    return@post
                }
                val list = parsed.getOrThrow()
                if (list.isEmpty()) {
                    // 明确回一个**空清单**：绝不静默留白（前端据此提示"该书源的音频规则没配好"）
                    call.respond(
                        AudioChapterManifest(
                            sourceId = request.sourceId, bookUrl = bookUrl, chapterUrl = chapterUrl,
                            chapterIndex = request.chapterIndex, total = 0, ready = 0,
                            state = "empty", tracks = emptyList(),
                        ),
                    )
                    return@post
                }
                audioCache.registerChapter(request.sourceId, bookUrl, chapterUrl, request.chapterIndex, list)
            }

            call.respond(
                AudioChapterManifest(
                    sourceId = request.sourceId,
                    bookUrl = bookUrl,
                    chapterUrl = chapterUrl,
                    chapterIndex = request.chapterIndex,
                    total = rows.size,
                    ready = rows.count { it.state == "ready" },
                    state = audioCache.chapterState(rows),
                    tracks = rows.map {
                        AudioTrack(
                            index = it.segmentIndex,
                            key = it.cacheKey,
                            segmentIndex = it.segmentIndex,
                            status = it.state,
                            durationMs = it.durationMs,
                            byteSize = it.byteSize,
                        )
                    },
                ),
            )
        }

        /**
         * 音频直出（**按需抓取 + 唯一字节副本 + 单段 Range**）。
         *
         * `ETag = cacheKey`（URL 派生的稳定哈希）⇒ 可 `immutable`：同一个 key 的内容在我们
         * 这一层不会变，浏览器与中间层可以放心长期缓存（这是"二次播放零上游请求"的关键）。
         *
         * Range 实现**复用 `respondFileRange`**（与 WebDAV 同一份手写实现）——
         * AGENTS.md 明文：Range 写错 ⇒ 播放器 seek 卡死 / 416。
         */
        get("/audio/{key}") {
            if (auth.requireSession(call) == null) return@get
            val key = call.parameters["key"].orEmpty()
            if (!key.matches(AUDIO_KEY_PATTERN)) {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "音频 key 无效"))
                return@get
            }

            var row = audioCache.getByKey(key)
            if (row == null) {
                // 未就绪 ⇒ 用登记时留下的上游地址按需抓取（key 不可逆，这是它的代价也是防护）
                val pending = audioCache.rowByKey(key)
                    ?: return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "该 key 未登记（可能章节清单已清空）"))
                val sourceJson = database.getSource(pending.sourceId)?.json
                if (sourceJson == null) {
                    audioCache.markFailed(key, "书源不存在")
                    return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
                }
                // 防盗链的命门：Referer 必须是**章节页**，并与书源 header/Cookie 一起发
                val outcome = audioFetcher.fetchInto(
                    upstreamUrl = pending.upstreamUrl,
                    mediaHeaders = runner.mediaHeaders(sourceJson, pending.sourceId),
                    referer = pending.chapterUrl.takeIf { it.startsWith("http") },
                    trackHeadersJson = pending.headersJson,
                    store = audioCache.store,
                    target = audioCache.targetFor(pending),
                )
                when (outcome) {
                    is AudioFetchOutcome.Failure -> {
                        audioCache.markFailed(key, outcome.reason)
                        // 502 + **真实原因**：格式不支持 / 要登录 / 上游 404 是三种完全不同的动作
                        call.respond(HttpStatusCode.BadGateway, ApiError("audio_fetch_failed", outcome.reason))
                        return@get
                    }
                    is AudioFetchOutcome.Success -> {
                        audioCache.markReady(pending, outcome.contentType, outcome.byteSize, outcome.filePath)
                        row = audioCache.rowByKey(key)
                            ?: return@get call.respond(HttpStatusCode.InternalServerError, ApiError("cache_error", "音频落盘后索引丢失"))
                    }
                }
            }

            val file = audioCache.fileFor(row)
                ?: return@get call.respond(HttpStatusCode.NotFound, ApiError("not_found", "音频文件不存在"))
            call.respondFileRange(
                file = file,
                contentType = ContentType.parse(row.contentType.ifBlank { "audio/mpeg" }),
                etag = row.cacheKey,
                cacheControl = "private, max-age=31536000, immutable",
            )
        }

        /** 前端 `loadedmetadata` 回传时长（服务端不引音频解析库）。顺带判一次"这一段听完了"。 */
        post("/audio/duration") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<AudioDurationRequest>()
            if (request.key.isBlank() || !request.key.matches(AUDIO_KEY_PATTERN)) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "音频 key 无效"))
                return@post
            }
            audioCache.updateDuration(request.key, request.durationMs)
            if (request.durationMs > 0 && request.positionMs > 0) {
                // 听完判据（> 80%）：GC 顺位 1 的输入之一。失败静默——这只是统计意义上的信息。
                runCatching { audioCache.markListened(request.key, request.positionMs * 100 >= request.durationMs * 80) }
            }
            call.respond(HttpStatusCode.NoContent)
        }

        /**
         * 批量缓存（G5）。
         *
         * **幂等且随时可重复调用**：同一本书的重复请求不会新起并行任务，而是让正在跑的循环改目标。
         * 返回 `202 Accepted` 表示"已受理"而非"已完成"。
         *
         * 目录**还没缓存时也照样受理**（与漫画端同一裁决）：缓存会自己把目录抓进 `book_toc_cache`。
         * 返回的 `chapters` 只是"已受理的章数"（目录未知时按 1 报），
         * 真实进度看 `GET /books/audio/prefetch` 的 `done/planned`（**章**口径）。
         */
        post("/books/audio/cache") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<AudioPrefetchRequest>()
            if (request.sourceId.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书源"))
                return@post
            }
            val bookUrl = request.bookUrl?.takeIf { it.isNotBlank() }
                ?: run {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书籍地址"))
                    return@post
                }
            val service = audioPrefetch
            if (service == null || !service.enabled) {
                // 关闭 ≠ 报错：播放器对它的唯一正确反应是"什么都不做"
                call.respond(HttpStatusCode.Accepted, AudioPrefetchResponse(false, 0, "prefetch_disabled"))
                return@post
            }
            val chapters = service.enqueue(
                sourceId = request.sourceId,
                bookUrl = bookUrl,
                fromChapterIndex = request.fromChapterIndex,
                ahead = request.ahead,
                pin = request.pin,
            )
            call.respond(
                HttpStatusCode.Accepted,
                AudioPrefetchResponse(chapters > 0, chapters, if (chapters > 0) null else "nothing_to_cache"),
            )
        }
        get("/books/audio/prefetch") {
            if (auth.requireSession(call) == null) return@get
            call.respond(audioPrefetch?.status() ?: emptyList<AudioPrefetchStatus>())
        }
        /**
         * **只取消、不删缓存**的取消入口（目录底栏那个「取消缓存」按钮）。
         *
         * 为什么必须单开一条：`DELETE /audio/cache` 里的 `cancel()` 是「清缓存顺带停任务」，
         * 直接拿它当取消按钮用，会把用户已经下好的音频分段一起删掉（语义不符、且不可恢复）。
         * 这里只停任务：字节、清单与 pin 一律**原样保留**，用户随时可以再点一次接着缓存。
         */
        post("/books/audio/prefetch/cancel") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<AudioPrefetchRequest>()
            if (request.sourceId.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书源"))
                return@post
            }
            val bookUrl = request.bookUrl?.takeIf { it.isNotBlank() }
                ?: run {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书籍地址"))
                    return@post
                }
            // 服务为 null（`LEGADO_AUDIO_PREFETCH=false`）时"已经没在跑"，等价于取消成功。
            // ⚠️ 绝不调用 `audioCache.deleteBook` / `deleteKey`：那是 DELETE /audio/cache 的语义。
            audioPrefetch?.cancel(request.sourceId, bookUrl)
            call.respond(HttpStatusCode.NoContent)
        }
        get("/books/audio/cached-chapters") {
            if (auth.requireSession(call, false) == null) return@get
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书籍标识"))
                return@get
            }
            val urls = database.readyAudioChapters(sourceId, bookUrl)
            val total = database.getTocCache(sourceId, bookUrl)?.size ?: 0
            call.respond(CachedChaptersResponse(sourceId, bookUrl, urls, urls.size, total))
        }
        get("/audio/cache/stats") {
            if (auth.requireSession(call) == null) return@get
            call.respond(audioCache.stats())
        }
        /** 「整本离线」免死金牌开关（G8）。只有**用户显式动作**才配得上它。 */
        put("/audio/cache/pin") {
            if (auth.requireSession(call, true) == null) return@put
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            val pinned = call.request.queryParameters["pinned"]?.toBooleanStrictOrNull() ?: true
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书籍标识"))
                return@put
            }
            database.setAudioBookPinned(sourceId, bookUrl, pinned)
            call.respond(AudioPinResponse(sourceId, bookUrl, pinned))
        }
        delete("/audio/cache") {
            if (auth.requireSession(call, true) == null) return@delete
            if (call.request.queryParameters["all"]?.toBooleanStrictOrNull() == true) {
                // 先停任务再清：否则清理刚删完，还在跑的缓存任务又把它抓回来（用户看到"清不干净"）
                audioPrefetch?.cancelAll()
                audioCache.deleteAll()
                call.respond(HttpStatusCode.NoContent)
                return@delete
            }
            val key = call.request.queryParameters["key"]
            if (!key.isNullOrBlank()) {
                audioCache.deleteKey(key)
                call.respond(HttpStatusCode.NoContent)
                return@delete
            }
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_audio", "缺少书籍标识或 key"))
                return@delete
            }
            audioPrefetch?.cancel(sourceId, bookUrl)
            audioCache.deleteBook(sourceId, bookUrl)
            call.respond(HttpStatusCode.NoContent)
        }
        get("/bookshelf") {
            if (auth.requireSession(call) == null) return@get
            call.respond(bookshelfWithMediaCache(database, mangaPrefetch, audioPrefetch))
        }
        post("/bookshelf/refresh") {
            if (auth.requireSession(call, true) == null) return@post
            val request = try {
                call.receive<BookshelfRefreshRequest>()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_refresh", "刷新请求格式无效"))
                return@post
            }
            call.respond(HttpStatusCode.Accepted, bookshelfRefresh.start(request))
        }
        get("/bookshelf/refresh/status") {
            if (auth.requireSession(call) == null) return@get
            call.response.header(HttpHeaders.CacheControl, "no-store")
            call.respond(bookshelfRefresh.status())
        }
        put("/bookshelf/update-enabled") {
            if (auth.requireSession(call, true) == null) return@put
            val request = try {
                call.receive<BookshelfUpdateEnabledRequest>()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "更新设置格式无效"))
                return@put
            }
            if (request.sourceId.isBlank() || request.bookUrl.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "缺少书籍标识"))
                return@put
            }
            database.setBookshelfCanUpdate(request.sourceId, request.bookUrl, request.canUpdate)?.let { call.respond(it) }
                ?: call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书籍不在书架中"))
        }
        post("/bookshelf") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<BookshelfWriteRequest>()
            if (request.sourceId.isBlank() || request.bookUrl.isBlank() || request.name.isBlank() || request.tocUrl.isBlank()) { call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "书架数据无效")); return@post }
            val immediateCover = tryFindCachedCover(
                coverCache, request.coverUrl, request.alternateSources,
                CoverBookRef(request.name, request.sourceId, request.bookUrl),
            )
            // 类型判定：**本地书身份优先，其次书自己的说法，源声明兜底**（issue #66）。
            // ⚠️ 实测教训：聚合源（大灰狼）不声明 `bookSourceType`，但它里面有漫画频道；
            // 只看源声明会把这些漫画判成小说 ⇒ 进文字阅读器 ⇒ 用户看到的是"漫画打不开"。
            // ⚠️ 本地书（`loc_book` / `local://`）不能被 `tab`/源声明推导：它自成一类 `local`，
            // 且「加入书架」会被重复调用（每次开书都会调），若这里推导成 `novel`，
            // upsert 的 `book_kind = coalesce(excluded.book_kind, book_shelf.book_kind)` 会把已有的
            // `local` 冲成 `novel` ⇒ 本地书角标与导出 `type=264` 全丢。
            val bookKind = if (BookKind.isLocalRef(request.sourceId, request.bookUrl)) {
                BookKind.LOCAL.wire
            } else {
                BookKind.resolve(
                    explicit = request.bookKind,
                    bookUrl = request.bookUrl,
                    sourcePayload = database.getSource(request.sourceId)?.json,
                )
            }
            val item = database.saveBookshelf(request.copy(bookKind = bookKind), immediateCover)
            // 漫画/有声书**不进文本章节缓存队列**：那是给文字阅读器用的（拉章节页→抽正文）。
            // 实测：一本漫画被误判成小说时会跑 10 章文本缓存、10 章全失败，白刷上游还污染缓存状态。
            val localBook = BookKind.isLocalRef(request.sourceId, request.bookUrl)
            // 入架请求本身只保存元数据；旧客户端即使发送 `autoCache=true` 也会被忽略。
            // 后台按书源逐章补齐网络小说，显式缓存入口仍可指定范围与并发。
            if (localBook) {
                database.ensureLocalBookStatusReady(request.sourceId, request.bookUrl)
            }
            // 只在「这本书现在还没有本地副本」时才去补抓一次。
            //
            // 语义边界（用户明确要求）：封面只在**导入 / 加入书架 / 手动修改**这三种时机获取，
            // 重复添加或打开阅读都不许刷新。原判断只看 `immediateCover == null`，
            // 于是给一本**已有封面**的书重新「加入书架」时，后台下载会绕过 saveBookshelf 的
            // 「已有 cover_key 优先」保护、直接把封面顶掉（手动选好的封面也会被顶掉）。
            // item 是 upsert 之后的结果，coverKey 非空即代表这本书已经有封面可用 ⇒ 不必再抓。
            if (item.coverKey == null && (!request.coverUrl.isNullOrBlank() || !request.alternateSources.isNullOrEmpty())) {
                application.launch(Dispatchers.IO) {
                    val cached = tryCacheCover(
                        coverCache, request.coverUrl, request.alternateSources,
                        CoverBookRef(request.name, request.sourceId, request.bookUrl),
                        database, runner,
                    )
                    if (cached != null) {
                        database.updateBookshelfCover(request.sourceId, request.bookUrl, cached.key, cached.contentType)
                    }
                }
            }
            // Android `SourceCallBack.callBackBook(ADD_BOOK_SHELF)`：书源开了 `eventListener` 时，
            // 加入书架要通知书源（脚本自己决定做什么，例如给站点"添加追更"）。
            // 与 Android 一致是**后台触发、结果不参与响应**：脚本慢/失败都不影响这次加入书架。
            val callbackSourceJson = database.getSource(request.sourceId)?.json
            if (callbackSourceJson != null && request.sourceId != LocalBookParser.LOC_BOOK_SOURCE_ID) {
                val bookContext = database.bookContext(request.sourceId, request.bookUrl)
                application.launch(Dispatchers.IO) {
                    runCatching { runner.runSourceCallback(callbackSourceJson, "addBookShelf", bookContext) }
                }
            }
            call.respond(item)
        }
        /**
         * 创建书架导出任务。字段默认值、并发、范围、TXT/EPUB 与章节失败语义均对齐 Android。
         * `export-epub` 保留为 EPUB 快捷别名，其余能力走通用入口。
         */
        post("/bookshelf/export") { call.startBookshelfExport() }
        post("/bookshelf/export-epub") { call.startBookshelfExport(forcedFormat = "epub") }
        get("/bookshelf/export/{jobId}") {
            if (auth.requireSession(call) == null) return@get
            val jobId = call.parameters["jobId"].orEmpty()
            try {
                call.respond(bookExport.status(jobId))
            } catch (error: BookExportException) {
                call.respond(HttpStatusCode.fromValue(error.status), ApiError(error.code, error.message ?: error.code))
            }
        }
        get("/bookshelf/export-epub/{jobId}") {
            if (auth.requireSession(call) == null) return@get
            val jobId = call.parameters["jobId"].orEmpty()
            try {
                call.respond(bookExport.status(jobId))
            } catch (error: BookExportException) {
                call.respond(HttpStatusCode.fromValue(error.status), ApiError(error.code, error.message ?: error.code))
            }
        }
        get("/bookshelf/export/{jobId}/download") {
            call.downloadBookshelfExport(call.parameters["jobId"].orEmpty())
        }
        get("/bookshelf/export/{jobId}/download/{fileId}") {
            call.downloadBookshelfExport(
                jobId = call.parameters["jobId"].orEmpty(),
                fileId = call.parameters["fileId"],
            )
        }
        get("/bookshelf/export-epub/{jobId}/download") {
            call.downloadBookshelfExport(call.parameters["jobId"].orEmpty())
        }
        post("/bookshelf/import-local") {
            if (auth.requireSession(call, true) == null) return@post
            val multipart = call.receiveMultipart()
            val items = mutableListOf<LocalBookImportItem>()
            var importedCount = 0
            var failedCount = 0
            multipart.forEachPart { part ->
                if (part is PartData.FileItem) {
                    val originalFilename = part.originalFileName ?: "book.txt"
                    val bytes = part.streamProvider().readBytes()
                    if (bytes.isNotEmpty()) {
                        val item = importOneLocalBook(originalFilename, bytes, localBooksDirectory, coverCache, database)
                        if (item.success) importedCount++ else failedCount++
                        items.add(item)
                    }
                }
                part.dispose()
            }
            call.respond(LocalBookImportResponse(
                total = items.size,
                imported = importedCount,
                failed = failedCount,
                results = items,
            ))
        }
        /**
         * 从 **WebDAV 存储区**导入本地书籍（仅 TXT / EPUB）。
         *
         * 与 [post("/bookshelf/import-local")] 的区别只在**字节来源**：
         * 那个走 HTTP 上传，这个直接从数据目录的 `webdav` 文件夹里读。
         * 解析、落盘、封面提取、入库全部复用 [importOneLocalBook]，
         * 保证两条入口的行为完全一致（否则「同一个文件用不同入口导入结果不同」会很难查）。
         *
         * 归属页面写操作，因此按会话鉴权 + CSRF 双轨校验（与备份导入一致）。
         */
        post("/bookshelf/import-webdav") {
            if (auth.requireSession(call, true) == null) return@post
            val request = runCatching { call.receive<WebDavBookImportRequest>() }.getOrNull()
                ?: run {
                    call.respond(HttpStatusCode.BadRequest, ApiError("invalid_book", "缺少文件路径"))
                    return@post
                }
            val target = webDavStorage.resolve(request.path.trim('/'))
                ?: run {
                    call.respond(HttpStatusCode.Forbidden, ApiError("invalid_path", "文件路径不合法"))
                    return@post
                }
            if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS)) {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "文件不存在"))
                return@post
            }
            val filename = target.fileName.toString()
            // 与上传入口同一套格式约束（TXT / EPUB）
            if (!LocalBookParser.isSupported(filename)) {
                call.respond(
                    HttpStatusCode.BadRequest,
                    ApiError("unsupported_format", "不支持的格式（仅支持 ${LocalBookParser.SUPPORTED_FORMATS}）：$filename"),
                )
                return@post
            }
            // 体积上限：走的是本地文件，但仍要防「误把几百 MB 的东西按 TXT 硬解析」
            val size = runCatching { Files.size(target) }.getOrDefault(0L)
            if (size > MAX_LOCAL_BOOK_BYTES) {
                call.respond(
                    HttpStatusCode.BadRequest,
                    ApiError("too_large", "文件超过 ${MAX_LOCAL_BOOK_BYTES / 1024 / 1024} MiB 上限"),
                )
                return@post
            }
            val bytes = runCatching { Files.readAllBytes(target) }.getOrElse { error ->
                call.respond(HttpStatusCode.InternalServerError, ApiError("read_failed", error.message ?: "读取文件失败"))
                return@post
            }
            // **传 basename，不要传完整相对路径**：
            // `LocalBookParser` 用 `filename.substringBeforeLast('.')` 当书名兜底，
            // 若传 `books/凡人修仙传.txt`，书名会被写成 `books/凡人修仙传`。
            val item = importOneLocalBook(filename, bytes, localBooksDirectory, coverCache, database)
            call.respond(
                LocalBookImportResponse(
                    total = 1,
                    imported = if (item.success) 1 else 0,
                    failed = if (item.success) 0 else 1,
                    results = listOf(item),
                )
            )
        }
        delete("/bookshelf") {
            if (auth.requireSession(call, true) == null) return@delete
            val sourceId = call.request.queryParameters["sourceId"]; val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) { call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "缺少书籍标识")); return@delete }
            bookCache.cancel(sourceId, bookUrl)
            if (sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID) {
                val bookId = bookUrl.removePrefix("local://").substringBefore('/')
                if (bookId.isNotBlank()) {
                    runCatching {
                        if (Files.exists(localBooksDirectory)) {
                            Files.list(localBooksDirectory).use { stream ->
                                stream.filter { it.fileName.toString().startsWith(bookId) }.forEach { Files.deleteIfExists(it) }
                            }
                        }
                    }
                }
            }
            // Android `SourceCallBack.callBackBook(DEL_BOOK_SHELF)`：移出书架要通知书源。
            // 书上下文与书源定义必须在**删行之前**取（删完书名/变量就读不到了）；
            // 与 Android 一致，事件在后台触发、结果不参与响应。
            val callbackSourceJson = if (sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID) {
                null
            } else {
                database.getSource(sourceId)?.json
            }
            val callbackBookContext = callbackSourceJson?.let { runCatching { database.bookContext(sourceId, bookUrl) }.getOrNull() }
            database.removeBookshelf(sourceId, bookUrl)?.let(coverCache::delete)
            if (callbackSourceJson != null && callbackBookContext != null) {
                application.launch(Dispatchers.IO) {
                    runCatching { runner.runSourceCallback(callbackSourceJson, "delBookShelf", callbackBookContext) }
                }
            }
            // 媒体缓存（漫画图片 / 有声音频 / 正文插图）同样是"这本书的私有数据"：不跟着一起清，
            // 行与字节就会永久占盘，且书已不在书架 ⇒ 用户再也无法从任何界面回收
            // （反馈：「为什么书移出书架后漫画，音频，插图没有同步删了」）。
            // 单一入口见 [purgeBookMediaCaches]（批量移出也走它）；任何一类失败只记日志，不阻断移出书架。
            purgeBookMediaCaches(
                sourceId = sourceId,
                bookUrl = bookUrl,
                database = database,
                imageCache = imageCache,
                audioCache = audioCache,
                illustrationCache = illustrationCache,
                mangaPrefetch = mangaPrefetch,
                audioPrefetch = audioPrefetch,
                log = { message -> application.log.info(message) },
            )
            call.respond(HttpStatusCode.NoContent)
        }
        post("/bookshelf/cache") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<BookCacheRangeRequest>()
            if (
                request.chapterConcurrency != null &&
                request.chapterConcurrency !in BOOK_CACHE_MIN_CONCURRENCY..BOOK_CACHE_MAX_CONCURRENCY
            ) {
                call.respond(
                    HttpStatusCode.BadRequest,
                    ApiError(
                        "invalid_cache_concurrency",
                        "章节并发数必须在 $BOOK_CACHE_MIN_CONCURRENCY 到 $BOOK_CACHE_MAX_CONCURRENCY 之间",
                    ),
                )
                return@post
            }
            val item = database.listBookshelf().firstOrNull { it.sourceId == request.sourceId && it.bookUrl == request.bookUrl }
                ?: return@post call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书籍不在书架中"))
            if (item.sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID || item.bookUrl.startsWith("local://")) {
                database.ensureLocalBookStatusReady(item.sourceId, item.bookUrl)
                call.respond(HttpStatusCode.Accepted, mapOf("status" to "ready"))
                return@post
            }
            // 「缓存全本」必须按**书型**分发：漫画/有声的内容是图片/音频，正文缓存对它们
            // 只会去抓不存在的"正文"（实测:书架里漫画点缓存 ⇒ 0 章 + "N 章未缓存"）。
            // 与 GET /bookshelf/cached-chapters 的口径保持一致（那里也是按 kind 换数据源）。
            val from = request.startIndex ?: 0
            val ahead = when {
                request.endIndex != null -> (request.endIndex - from).coerceAtLeast(0)
                request.count != null -> (request.count - 1).coerceAtLeast(0)
                else -> Int.MAX_VALUE // 「全本」：服务端另有 MAX_AHEAD 上限
            }
            val pin = request.endIndex == null && request.count == null
            when (BookKind.from(database.getBookKind(item.sourceId, item.bookUrl))) {
                BookKind.COMIC -> {
                    val service = mangaPrefetch
                    if (service == null || !service.enabled) {
                        call.respond(HttpStatusCode.Accepted, mapOf("status" to "prefetch_disabled"))
                        return@post
                    }
                    val queued = service.enqueue(item.sourceId, item.bookUrl, from, ahead, pin)
                    if (pin && queued > 0) database.setMangaBookPinned(item.sourceId, item.bookUrl, true)
                    call.respond(
                        HttpStatusCode.Accepted,
                        mapOf("status" to if (queued > 0) "queued" else "nothing_to_prefetch"),
                    )
                }
                BookKind.AUDIO -> {
                    val service = audioPrefetch
                    if (service == null || !service.enabled) {
                        call.respond(HttpStatusCode.Accepted, mapOf("status" to "prefetch_disabled"))
                        return@post
                    }
                    val queued = service.enqueue(item.sourceId, item.bookUrl, from, ahead, pin)
                    call.respond(
                        HttpStatusCode.Accepted,
                        mapOf("status" to if (queued > 0) "queued" else "nothing_to_prefetch"),
                    )
                }
                BookKind.NOVEL -> {
                    bookCache.enqueue(CachedBookRequest(
                        item.sourceId,
                        item.bookUrl,
                        item.tocUrl,
                        request.startIndex,
                        request.endIndex,
                        request.count,
                        request.chapterConcurrency,
                    ))
                    call.respond(HttpStatusCode.Accepted, mapOf("status" to "queued"))
                }
                // 本地书正文在导入时就已全部落库（上面的 isLocal 分支已经拦下），这里是**兜底**：
                // `book_kind='local'` 绝不能掉进 NOVEL 分支被排进"网络抓正文"队列。
                BookKind.LOCAL -> {
                    database.ensureLocalBookStatusReady(item.sourceId, item.bookUrl)
                    call.respond(HttpStatusCode.Accepted, mapOf("status" to "ready"))
                }
            }
        }
        post("/bookshelf/cache/pause") {
            if (auth.requireSession(call, true) == null) return@post
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_request", "缺少书籍标识"))
                return@post
            }
            if (BookKind.from(database.getBookKind(sourceId, bookUrl)) != BookKind.NOVEL) {
                call.respond(HttpStatusCode.BadRequest, ApiError("unsupported_book_kind", "仅文本书支持此缓存任务控制"))
                return@post
            }
            if (bookCache.pause(sourceId, bookUrl)) call.respond(mapOf("status" to "paused"))
            else call.respond(HttpStatusCode.NotFound, ApiError("cache_task_not_found", "缓存任务不存在"))
        }
        post("/bookshelf/cache/retry") {
            if (auth.requireSession(call, true) == null) return@post
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_request", "缺少书籍标识"))
                return@post
            }
            if (BookKind.from(database.getBookKind(sourceId, bookUrl)) != BookKind.NOVEL) {
                call.respond(HttpStatusCode.BadRequest, ApiError("unsupported_book_kind", "仅文本书支持此缓存任务控制"))
                return@post
            }
            if (bookCache.retry(sourceId, bookUrl)) call.respond(HttpStatusCode.Accepted, mapOf("status" to "queued"))
            else call.respond(HttpStatusCode.NotFound, ApiError("cache_task_not_found", "可重试缓存任务不存在"))
        }
        post("/bookshelf/cache/ignore-failed-empty") {
            if (auth.requireSession(call, true) == null) return@post
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_request", "缺少书籍标识"))
                return@post
            }
            val cacheError = database.bookCacheLastError(sourceId, bookUrl)
            if (cacheError.isNullOrBlank() || "正文规则未提取到内容" !in cacheError) {
                call.respond(
                    HttpStatusCode.Conflict,
                    ApiError("not_empty_content_failure", "当前缓存失败不是明确的空正文错误"),
                )
                return@post
            }
            val chapterUrl = cacheError
                .substringAfter("首条原因：", "")
                .substringBefore(": ")
                .trim()
            if (!chapterUrl.startsWith("http://", true) && !chapterUrl.startsWith("https://", true)) {
                call.respond(
                    HttpStatusCode.Conflict,
                    ApiError("failed_chapter_unresolved", "无法从缓存错误中定位失败章节"),
                )
                return@post
            }
            val title = database.ignoreBookCacheChapter(sourceId, bookUrl, chapterUrl, cacheError)
            if (title == null) {
                call.respond(
                    HttpStatusCode.NotFound,
                    ApiError("failed_chapter_not_in_toc", "当前目录中找不到该失败章节"),
                )
                return@post
            }
            if (!bookCache.retry(sourceId, bookUrl)) {
                database.setBookCacheState(sourceId, bookUrl, "idle", null)
            }
            call.respond(
                HttpStatusCode.Accepted,
                mapOf("status" to "queued", "title" to title),
            )
        }
        get("/bookshelf/cached-chapters") {
            if (auth.requireSession(call, false) == null) return@get
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "缺少书籍标识"))
                return@get
            }
            // 绿点的唯一口径：文本书看 "正文已缓存"，漫画看 "整章图片全部落盘"，
            // 有声书看 "整章音频分段全部落盘"（三者都是 state='ready' 的同一语义）。
            // 契约（路径 / 字段名）**完全不变**，只是服务端按 kind 换数据源 —— 前端与 SW 无需改。
            val cachedUrls = when (BookKind.from(database.getBookKind(sourceId, bookUrl))) {
                BookKind.COMIC -> database.listReadyMangaChapterUrls(sourceId, bookUrl)
                BookKind.AUDIO -> database.readyAudioChapters(sourceId, bookUrl)
                BookKind.NOVEL -> database.cachedChapterUrls(sourceId, bookUrl).toList()
                // 本地书（issue #66）：正文同样落在 `book_content_cache`（导入即写满），
                // 所以"已缓存章节"的绿点口径与文本一致 —— 不新增数据源、不让前端退化。
                BookKind.LOCAL -> database.cachedChapterUrls(sourceId, bookUrl).toList()
            }
            val total = database.getTocCache(sourceId, bookUrl)?.size ?: 0
            call.respond(CachedChaptersResponse(sourceId, bookUrl, cachedUrls, cachedUrls.size, total))
        }
        delete("/bookshelf/cache") {
            if (auth.requireSession(call, true) == null) return@delete
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            val clearData = call.request.queryParameters["clearData"]?.toBooleanStrictOrNull() ?: false
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "缺少书籍标识"))
                return@delete
            }
            // 取消也要按书型分发，否则漫画/有声"取消缓存"只是取消了一个并不存在的正文任务。
            when (BookKind.from(database.getBookKind(sourceId, bookUrl))) {
                BookKind.COMIC -> mangaPrefetch?.cancel(sourceId, bookUrl)
                BookKind.AUDIO -> audioPrefetch?.cancel(sourceId, bookUrl)
                BookKind.NOVEL -> bookCache.cancel(sourceId, bookUrl)
                // 本地书没有可取消的网络任务；真正的正文保护在 data 层
                // （`Database.clearBookCacheContent` 对本地书恒返回 0，防 UI 绕过）。
                BookKind.LOCAL -> Unit
            }
            if (clearData) {
                database.clearBookCacheContent(sourceId, bookUrl)
                // 正文的插图副本也一起清（只在服务器侧清缓存时做：浏览器侧缓存由前端自己清）
                illustrationCache?.deleteBook(sourceId, bookUrl)
            }
            call.respond(HttpStatusCode.NoContent)
        }
        post("/bookshelf/reclean") {
            if (auth.requireSession(call, true) == null) return@post
            val req = call.receive<BookRecleanRequest>()
            if (req.sourceId.isBlank() || req.bookUrl.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_request", "缺少书籍标识"))
                return@post
            }
            val res = database.recleanBookCache(req.sourceId, req.bookUrl, runner.jsSandbox)
            call.respond(res)
        }
        post("/bookshelf/batch-reclean") {
            if (auth.requireSession(call, true) == null) return@post
            val req = call.receive<BatchBookRecleanRequest>()
            var totalRecleaned = 0
            val results = req.books.map { book ->
                val res = database.recleanBookCache(book.sourceId, book.bookUrl, runner.jsSandbox)
                totalRecleaned += res.recleanedChapters
                res
            }
            call.respond(BatchBookRecleanResponse(totalRecleaned, results))
        }
        /**
         * 补抓封面到本地缓存，并回写 `cover_key`。
         *
         * 用于修复「封面补抓逻辑上线之前导入的书架」——那些书的 `cover_key` 全为空，
         * 前端只能靠 `coverUrl` 直连；补抓完成后即切换为本地副本，不再依赖外部图床。
         * 传入 sourceId/bookUrl 则只补一本，否则补整架。
         *
         * `deep = true` 时改走**深度回源补抓**：这类书的 `cover_url` 往往是番茄（fqnovelpic）等
         * CDN 的**带签名地址、早已过期**，直接抓必然失败 ⇒ 先回书源取一份新地址再物化，
         * 并把新地址一并写回 `cover_url`（外链兜底也随之复活）。
         */
        post("/bookshelf/refresh-covers") {
            if (auth.requireSession(call, true) == null) return@post
            val req = runCatching { call.receive<CoverRefreshRequest>() }.getOrDefault(CoverRefreshRequest())
            val shelf = database.listBookshelf()
            val targets = shelf.filter { item ->
                item.coverKey.isNullOrBlank() &&
                    !item.coverUrl.isNullOrBlank() &&
                    (req.sourceId == null || item.sourceId == req.sourceId) &&
                    (req.bookUrl == null || item.bookUrl == req.bookUrl)
            }
            val skipped = shelf.size - targets.size
            // 封面可能有数 MB，串行补抓整架会很久；这里用信号量限并发，
            // 既压住耗时又不至于把图床/线程池打满。
            // 深度模式还会对每个目标各发一次「回源取详情」请求，同一上限一并约束。
            val refreshed = AtomicInteger()
            val failed = AtomicInteger()
            val resourced = AtomicInteger()
            val fetchDetailsForCover: (BookshelfItem) -> BookDetails? = { item ->
                fetchBookDetails(database, runner, item.sourceId, item.bookUrl)
            }
            // 封面解密（`coverDecodeJs`）与请求头都按**该书的书源**取：缺 Referer/Cookie 会 403，
            // 缺解密规则则解密封面直接落盘成坏图。
            val coverContextOf: (BookshelfItem) -> Pair<Map<String, String>, ImageByteDecoder?> = { item ->
                val record = database.getSource(item.sourceId)
                if (record == null) {
                    emptyMap<String, String>() to null
                } else {
                    runCatching { runner.mediaHeaders(record.json, item.sourceId) }.getOrDefault(emptyMap()) to
                        runCatching { runner.imageDecoder(record.json, isCover = true) }.getOrNull()
                }
            }
            coroutineScope {
                val gate = Semaphore(6)
                targets.map { item ->
                    async(Dispatchers.IO) {
                        gate.withPermit {
                            if (req.deep) {
                                // 回源失败 / 取不到新地址 / 下载失败 ⇒ 只计失败并静默继续，绝不中断整批。
                                val freshUrl = resolveFreshCoverUrl(item, fetchDetailsForCover)
                                if (freshUrl == null) {
                                    failed.incrementAndGet()
                                } else {
                                    if (freshUrl != item.coverUrl) resourced.incrementAndGet()
                                    val (headers, decoder) = coverContextOf(item)
                                    val cached = materializeCover(database, coverCache, item, freshUrl, headers, decoder)
                                    if (cached != null) refreshed.incrementAndGet() else failed.incrementAndGet()
                                }
                            } else {
                                val url = item.coverUrl!!
                                // deep=false 也要带身份落盘：文件名与书目录用同一个书哈希
                                val identity = CoverBookRef(item.name, item.sourceId, item.bookUrl)
                                val (headers, decoder) = coverContextOf(item)
                                val cached = runCatching {
                                    coverCache.getIfCached(url, identity) ?: coverCache.cache(url, identity, headers, decoder)
                                }.getOrNull()
                                if (cached != null && database.updateBookshelfCover(item.sourceId, item.bookUrl, cached.key, cached.contentType)) {
                                    refreshed.incrementAndGet()
                                } else {
                                    failed.incrementAndGet()
                                }
                            }
                        }
                    }
                }.awaitAll()
            }
            call.respond(
                CoverRefreshResponse(
                    total = targets.size,
                    refreshed = refreshed.get(),
                    failed = failed.get(),
                    skipped = skipped,
                    resourced = resourced.get(),
                )
            )
        }
        /**
         * 封面**常驻自愈**：手动触发一轮（运维/验收入口）。
         *
         * 与 `POST /bookshelf/refresh-covers` 的区别（两者刻意分开，语义不同）：
         * - `refresh-covers` 是**一次性修复历史数据**，条件是「`cover_key` 为空**且**有 `cover_url`」；
         * - 本接口跑的是**常驻 worker 的同一轮逻辑**（[CoverSelfHeal.runOnce]），条件是
         *   「`cover_key` 为空 **或** `cover_key` 定位不到文件」—— 后者正是「后期封面丢了」
         *   （磁盘清理/误删/换卷），`refresh-covers` 永远修不到它（它按 `cover_key` 为空过滤）。
         *
         * 参数：`?limit=N` 覆盖单轮上限（默认 20，上限 500）。手动触发**忽略失败退避**
         * （用户点了"现在就补"不该被退避挡住），但不忽略单轮上限（那是防拖垮服务的资源上限）。
         *
         * 同步返回本轮结果（每轮最多 20 本、并发 6、单本 15s ⇒ 最坏约 50s，且只阻塞**这一次**管理请求）。
         */
        post("/bookshelf/self-heal-covers") {
            if (auth.requireSession(call, true) == null) return@post
            val worker = coverSelfHeal
                ?: return@post call.respond(HttpStatusCode.ServiceUnavailable, ApiError("selfheal_disabled", "封面自愈未启用"))
            val limit = call.request.queryParameters["limit"]?.toIntOrNull()?.coerceIn(1, MAX_SELF_HEAL_LIMIT)
            val result = withContext(Dispatchers.IO) { worker.runOnce(force = true, limitOverride = limit) }
            call.respond(result)
        }
        /**
         * 用**存量原始文件**重新解析本地书，覆盖目录与正文缓存。
         *
         * 用于修复「解析器缺陷修复之前导入的本地书」：本地书的目录与正文是在**导入那一刻**
         * 解析落库的，因此解析器修好后老数据不会自动变好——EPUB 的正文段落在导入时已被
         * 压成单行、边界信息不可逆丢失，替换净化规则也救不回来，**只能重新解析**。
         * 原始文件一直保留在 [localBooksDirectory]（文件名 `<bookId>.<ext>`），
         * 所以就地重解析即可：用户不用重新上传，`local://<bookId>` 不变
         * ⇒ 书架元数据、分组、封面、阅读进度与书签全部延续。
         *
         * 幂等；默认处理全部本地书，传 `sourceId`/`bookUrl` 则只处理一本。
         */
        post("/bookshelf/reparse-local") {
            if (auth.requireSession(call, true) == null) return@post
            val req = runCatching { call.receive<LocalReparseRequest>() }.getOrDefault(LocalReparseRequest())
            val targets = database.listBookshelf().filter { item ->
                item.sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID &&
                    item.bookUrl.startsWith("local://") &&
                    (req.sourceId == null || item.sourceId == req.sourceId) &&
                    (req.bookUrl == null || item.bookUrl == req.bookUrl)
            }
            // 一次重新解析要把整本书读进内存（EPUB 解压后可能上百 MB），串行执行即可；
            // 并发只会让多本大书同时展开，收益为零、内存风险实打实。
            val items = mutableListOf<LocalReparseItem>()
            for (item in targets) {
                val bookId = item.bookUrl.removePrefix("local://").substringBefore('/')
                val file = if (Files.isDirectory(localBooksDirectory)) {
                    Files.list(localBooksDirectory).use { stream ->
                        stream.filter { it.fileName.toString().startsWith("$bookId.") }.findFirst().orElse(null)
                    }
                } else null
                if (file == null) {
                    items += LocalReparseItem(item.bookUrl, item.name, 0, "skipped", "原始文件已不在 local_books 目录")
                    continue
                }
                runCatching {
                    val bytes = Files.readAllBytes(file)
                    LocalBookParser.parse(file.fileName.toString(), bytes)
                }.mapCatching { parsed ->
                    database.replaceLocalBookCache(bookId, parsed)
                }.fold(
                    onSuccess = { chapters ->
                        items += if (chapters > 0) {
                            LocalReparseItem(item.bookUrl, item.name, chapters, "reparsed")
                        } else {
                            LocalReparseItem(item.bookUrl, item.name, 0, "skipped", "书籍不在书架中")
                        }
                    },
                    onFailure = { error ->
                        items += LocalReparseItem(item.bookUrl, item.name, 0, "failed", error.message ?: "重新解析失败")
                    },
                )
            }
            call.respond(
                LocalReparseResponse(
                    total = targets.size,
                    reparsed = items.count { it.status == "reparsed" },
                    skipped = items.count { it.status == "skipped" },
                    failed = items.count { it.status == "failed" },
                    chapters = items.sumOf { it.chapters },
                    items = items,
                )
            )
        }
        put("/bookshelf/status") {
            if (auth.requireSession(call, true) == null) return@put
            val request = call.receive<BookshelfStatusRequest>()
            if (request.sourceId.isBlank() || request.bookUrl.isBlank()) return@put call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "缺少书籍标识"))
            database.setBookshelfCompleted(request.sourceId, request.bookUrl, request.completed)?.let { call.respond(it) }
                ?: call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书籍不在书架中"))
        }
        put("/bookshelf/info") {
            if (auth.requireSession(call, true) == null) return@put
            val request = call.receive<BookshelfInfoUpdateRequest>()
            if (request.sourceId.isBlank() || request.bookUrl.isBlank() || request.name.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "书名不能为空"))
                return@put
            }
            val identity = CoverBookRef(request.name, request.sourceId, request.bookUrl)
            val cover = request.coverUrl?.takeIf { it.isNotBlank() }?.let { url ->
                val record = database.getSource(request.sourceId)
                // 用户手填了封面地址 ⇒ 用本书源的 header/Cookie 与 `coverDecodeJs` 抓一次
                // （规则为空时 decoder 为 null，行为与之前一致）。
                val headers = record?.let { source -> runCatching { runner.mediaHeaders(source.json, request.sourceId) }.getOrDefault(emptyMap()) }.orEmpty()
                val decoder = record?.let { source -> runCatching { runner.imageDecoder(source.json, isCover = true) }.getOrNull() }
                runCatching { coverCache.cache(url, identity, headers, decoder) }.getOrNull()
            }
            // 改「书籍变量」= 换听书音色 ⇒ **必须让该书已登记的音频清单失效**。
            //
            // 为什么非做不可：音频是按 **URL 寻址**缓存的（换音色 ⇒ 换地址 ⇒ 换 key），
            // 而清单路由对「已登记」的章节**直接返回旧行、不再回源解析**
            // —— 不失效的话，用户切了音色却发现**已打开过的章节还是旧音色**（且毫无提示）。
            // 这里只在值**确实变了**时才删，避免"只改书名点保存"白清一遍缓存。
            val beforeCustom = if (request.customVariable != null) {
                database.getBookVariables(request.sourceId, request.bookUrl)[Database.CUSTOM_VARIABLE_KEY]
            } else null
            database.updateBookshelfInfo(request, cover)?.let { updated ->
                // 上传的封面在写入那一刻还不知道属于哪本书（文件名是 `未命名 (key).扩展名`），
                // 与书籍关联的这一刻才知道 ⇒ 在这里归位成 `书名 (书哈希).扩展名`（只改名，不重写内容）。
                request.coverKey?.takeIf { it.isNotBlank() }?.let { coverCache.adopt(it, identity) }
                if (request.customVariable != null) {
                    val afterCustom = database.getBookVariables(request.sourceId, request.bookUrl)[Database.CUSTOM_VARIABLE_KEY]
                    if (beforeCustom != afterCustom) {
                        // 连磁盘文件一起释放（AudioCache.deleteBook 内部会 releaseFiles）
                        runCatching { audioCache.deleteBook(request.sourceId, request.bookUrl) }
                    }
                }
                call.respond(updated)
            } ?: call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书籍不在书架中"))
        }
        post("/bookshelf/switch-source") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<BookshelfSourceSwitchRequest>()
            val book = request.book
            if (request.oldSourceId.isBlank() || request.oldBookUrl.isBlank() || book.sourceId.isBlank() || book.bookUrl.isBlank() || book.name.isBlank() || book.tocUrl.isBlank()) { call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "书架数据无效")); return@post }
            val altList = (request.alternateSources ?: emptyList()) + (book.alternateSources ?: emptyList())
            val cover = tryCacheCover(
                coverCache, book.coverUrl, altList,
                CoverBookRef(book.name, book.sourceId, book.bookUrl),
                database, runner,
            )
            val bookKind = database.getSource(book.sourceId)?.let { BookKind.fromSourcePayload(it.json).name.lowercase() } ?: "novel"
            val bookWithKind = book.copy(bookKind = bookKind)
            bookCache.cancel(request.oldSourceId, request.oldBookUrl)
            // 换源要把阅读进度带过去（Android `BookInfoViewModel.saveBook` 用同名同作者的书
            // 回填 `durChapterIndex`/`durChapterPos`）。库内重映射（靠新源目录缓存）在
            // `switchBookshelf` 里做；这里先取旧进度，供"新源目录尚未缓存"时现场补一次。
            val oldProgress = database.getProgress(request.oldSourceId, request.oldBookUrl)
            val (item, orphan) = try {
                database.switchBookshelf(request.oldSourceId, request.oldBookUrl, bookWithKind, cover, request.alternateSources,
                    kindleSync?.sourceSwitchIdentity(request.oldSourceId, request.oldBookUrl, book.sourceId, book.bookUrl))
            } catch (error: KindleSyncException) {
                call.respond(HttpStatusCode.fromValue(error.status), ApiError(error.code, error.message ?: error.code))
                return@post
            }
            orphan?.let(coverCache::delete)
            // 新源目录还没缓存时，进度没法在库内重映射（没有章节地址可写）。此时用新源目录
            // **现场定位**同下标（退化为同标题）章节；取目录失败只丢进度，绝不阻断换源本身。
            val switched = if (oldProgress != null && item.chapterIndex == null) {
                runCatching { adoptProgressOnSwitch(oldProgress, item, database, runner) }.getOrNull() ?: item
            } else {
                item
            }
            call.respond(switched)
        }
        get("/bookshelf/groups") {
            if (auth.requireSession(call) == null) return@get
            call.respond(database.listBookGroups())
        }
        post("/bookshelf/groups") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<BookGroupCreateRequest>()
            if (request.name.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_group", "分组名称不能为空"))
                return@post
            }
            try {
                val group = database.createBookGroup(request.name)
                call.respond(HttpStatusCode.Created, group)
            } catch (e: Exception) {
                call.respond(HttpStatusCode.Conflict, ApiError("group_exists", e.message ?: "分组已存在或创建失败"))
            }
        }
        put("/bookshelf/groups/rename") {
            if (auth.requireSession(call, true) == null) return@put
            val request = call.receive<BookGroupRenameRequest>()
            if (request.oldName.isBlank() || request.newName.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_group", "分组名称不能为空"))
                return@put
            }
            try {
                val updated = database.renameBookGroup(request.oldName, request.newName)
                call.respond(updated)
            } catch (_: NoSuchElementException) {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "原分组不存在"))
            } catch (e: Exception) {
                call.respond(HttpStatusCode.BadRequest, ApiError("group_error", e.message ?: "重命名分组失败"))
            }
        }
        put("/bookshelf/groups/order") {
            if (auth.requireSession(call, true) == null) return@put
            val request = call.receive<BookGroupsOrderRequest>()
            val groups = database.updateBookGroupsOrder(request.groupNames)
            call.respond(groups)
        }
        delete("/bookshelf/groups") {
            if (auth.requireSession(call, true) == null) return@delete
            val name = call.request.queryParameters["name"]
            if (name.isNullOrBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_group", "分组名称不能为空"))
                return@delete
            }
            if (database.deleteBookGroup(name)) {
                call.respond(HttpStatusCode.NoContent)
            } else {
                call.respond(HttpStatusCode.NotFound, ApiError("not_found", "分组不存在"))
            }
        }
        put("/bookshelf/group") {
            if (auth.requireSession(call, true) == null) return@put
            val request = call.receive<BookGroupUpdateRequest>()
            if (request.sourceId.isBlank() || request.bookUrl.isBlank()) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_bookshelf", "缺少书籍标识"))
                return@put
            }
            database.updateBookGroup(request.sourceId, request.bookUrl, request.groupName)?.let { call.respond(it) }
                ?: call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书籍不在书架中"))
        }
        post("/bookshelf/batch") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<BookshelfBatchRequest>()
            if (request.items.isEmpty()) {
                call.respond(mapOf("affected" to 0))
                return@post
            }
            if (request.action == "delete") {
                for (item in request.items) {
                    bookCache.cancel(item.sourceId, item.bookUrl)
                }
            }
            val affected = database.batchBookshelfOperation(request) { orphanKey ->
                coverCache.delete(orphanKey)
            }
            // 批量移出与单本移出是**同一语义**（这本书不再属于书架）⇒ 媒体缓存必须一起清，
            // 且必须复用同一个入口（见 [purgeBookMediaCaches]），否则两条路径迟早再次分叉。
            if (request.action == "delete") {
                request.items.forEach { item ->
                    purgeBookMediaCaches(
                        sourceId = item.sourceId,
                        bookUrl = item.bookUrl,
                        database = database,
                        imageCache = imageCache,
                        audioCache = audioCache,
                        illustrationCache = illustrationCache,
                        mangaPrefetch = mangaPrefetch,
                        audioPrefetch = audioPrefetch,
                        log = { message -> application.log.info(message) },
                    )
                }
            }
            call.respond(mapOf("affected" to affected))
        }
        post("/covers/upload") {
            if (auth.requireSession(call, true) == null) return@post
            val multipart = call.receiveMultipart()
            var uploadedKey: String? = null
            var uploadedType: String? = null
            var errorMsg: String? = null

            multipart.forEachPart { part ->
                if (part is PartData.FileItem && uploadedKey == null) {
                    val bytes = part.streamProvider().readBytes()
                    if (bytes.size > 5 * 1024 * 1024) {
                        errorMsg = "封面文件不能超过 5MB"
                    } else if (bytes.isEmpty()) {
                        errorMsg = "封面文件不能为空"
                    } else {
                        val detectedType = coverCache.detectImageContentType(bytes)
                        if (detectedType == null) {
                            errorMsg = "仅支持常见图片格式（JPG、PNG、GIF、WebP、BMP）"
                        } else {
                            val key = coverCache.saveCoverBytes(bytes, detectedType)
                            database.recordCoverCache(key, detectedType)
                            uploadedKey = key
                            uploadedType = detectedType
                        }
                    }
                }
                part.dispose()
            }

            if (errorMsg != null) {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_cover", errorMsg))
            } else if (uploadedKey != null && uploadedType != null) {
                call.respond(CoverUploadResponse(
                    coverKey = uploadedKey,
                    contentType = uploadedType,
                    url = "/api/covers/$uploadedKey"
                ))
            } else {
                call.respond(HttpStatusCode.BadRequest, ApiError("invalid_cover", "未选择上传的封面文件"))
            }
        }
        get("/covers/{key}") {
            if (auth.requireSession(call) == null) return@get
            val key = call.parameters["key"] ?: return@get call.respond(HttpStatusCode.NotFound)
            val file = coverCache.file(key) ?: return@get call.respond(HttpStatusCode.NotFound)
            val type = database.coverContentType(key)?.let(ContentType::parse) ?: ContentType.Application.OctetStream
            // 封面 URL 里带的就是**内容哈希**（`cover_key = sha256(字节)`）⇒ 同一个 key 的内容永不改变，
            // 因此这里可以声明「永不过期」：一年 + immutable，浏览器与中间层都不再回源校验。
            // 之前是 7 天，纯属白跑请求；服务端本地副本本身也不会被淘汰（CoverCache 只有单文件 5 MiB 上限，
            // delete() 只用于孤儿清理）⇒ 真正意义的「服务器缓存、永不过期」。
            // 注：直接写头值，避免依赖 Ktor 版本里 CacheControl 的 immutable 支持差异。
            call.response.headers.append(HttpHeaders.CacheControl, "private, max-age=31536000, immutable")
            call.respond(LocalFileContent(file.toFile(), type))
        }
        get("/reading-progress") {
            if (auth.requireSession(call) == null) return@get
            val sourceId = call.request.queryParameters["sourceId"]
            val bookUrl = call.request.queryParameters["bookUrl"]
            if (sourceId.isNullOrBlank() || bookUrl.isNullOrBlank()) { call.respond(HttpStatusCode.BadRequest, ApiError("invalid_progress", "缺少 sourceId 或 bookUrl")); return@get }
            database.getProgress(sourceId, bookUrl)?.let { call.respond(it) } ?: call.respond(HttpStatusCode.NoContent)
        }
        put("/reading-progress") {
            if (auth.requireSession(call, true) == null) return@put
            val progress = call.receive<ReadingProgress>()
            // 有声书走 `position_ms`（毫秒），**因此这里刻意不动既有的 0..1 校验**
            // ——`scrollPosition` 仍然是比例语义，毫秒绝不塞进它（G2 §8 的裁决）。
            if (progress.sourceId.isBlank() || progress.bookUrl.isBlank() || progress.chapterUrl.isBlank() || progress.chapterIndex < 0 || !progress.scrollPosition.isFinite() || progress.scrollPosition !in 0.0..1.0 || (progress.positionMs != null && progress.positionMs < 0)) { call.respond(HttpStatusCode.BadRequest, ApiError("invalid_progress", "阅读进度无效")); return@put }
            val saved = database.saveProgress(progress)
            // 顺带把进度镜像到手机端的 bookProgress 文件（失败静默，绝不影响阅读保存）
            syncProgressToFile(saved, progress.chapterTitle)
            call.respond(saved)
        }

        // ------------------------------------------------------------------
        // 书籍进度同步（Legado 手机端 bookProgress 文件夹）
        // ------------------------------------------------------------------
        get("/progress-sync/settings") {
            if (auth.requireSession(call) == null) return@get
            val dir = progressSync.directory()
            call.respond(
                ProgressSyncSettings(
                    directoryName = progressSync.directoryName(),
                    directoryPath = dir?.toString(),
                    available = dir != null,
                    fileCount = dir?.let { d -> runCatching { Files.list(d).use { s -> s.filter { it.fileName.toString().endsWith(".json") }.count().toInt() } }.getOrDefault(0) } ?: 0,
                )
            )
        }
        put("/progress-sync/settings") {
            if (auth.requireSession(call, true) == null) return@put
            val request = call.receive<ProgressSyncSettingsUpdate>()
            val saved = progressSync.setDirectoryName(request.directoryName)
            val dir = progressSync.directory()
            call.respond(
                ProgressSyncSettings(
                    directoryName = saved,
                    directoryPath = dir?.toString(),
                    available = dir != null,
                    fileCount = dir?.let { d -> runCatching { Files.list(d).use { s -> s.filter { it.fileName.toString().endsWith(".json") }.count().toInt() } }.getOrDefault(0) } ?: 0,
                )
            )
        }
        /**
         * 打开书时合并进度：比较数据库与进度文件的时间戳，取更新的那个。
         *
         * 章节对齐用 `BookProgressSync.alignChapter`（index 为主 + 标题规范化匹配），
         * 因为换源后章节数可能不同，单纯按下标会错位。
         */
        post("/progress-sync/merge") {
            if (auth.requireSession(call, true) == null) return@post
            val request = call.receive<ProgressMergeRequest>()
            val shelf = database.getShelfBookByUrl(request.bookUrl)
            val dbProgress = database.getProgress(request.sourceId, request.bookUrl)
            val kind = request.bookKind?.takeIf { it.isNotBlank() } ?: shelf?.bookKind

            // 没有章节列表就无法做标题对齐；此时直接返回数据库进度
            val chapters = request.chapters
            val fileProgress = if (shelf != null) progressSync.read(shelf.name, shelf.author, kind) else null

            if (fileProgress == null || chapters.isEmpty()) {
                call.respond(ProgressMergeResponse(source = "database", progress = dbProgress, fileFound = fileProgress != null))
                return@post
            }

            val fileIndex = progressSync.alignChapter(chapters, fileProgress.chapterIndex, fileProgress.chapterTitle)

            if (fileIndex == null) {
                call.respond(ProgressMergeResponse(source = "database", progress = dbProgress, fileFound = true))
                return@post
            }

            // ------------------------------------------------------------------
            // 冲突消解：**与手机端 `syncBookProgress`（ReadBookLoadDelegate.kt:297）完全一致**
            //
            // 手机端原逻辑：
            //   if (远端 idx < 本地 idx || (idx 相同 && 远端 pos < 本地 pos)) → 不采纳
            //   else                                                       → setProgress(远端)
            // 即「**取更大的 idx**；idx 相同则取更大的 pos；两者都相等则视为无变化」。
            //
            // 为什么不比 `durChapterTime`（实测 ）：
            // 手机的 `durChapterTime` 是「阅读时刻」而非「写入时刻」，
            // 且**全仓 90+ 处引用无一处用它做冲突比较**（只用于书架排序与写库防抖）。
            // 观测到云游异世界 `326 → 329 → 328`：用户回翻时**时间戳更新但 idx 倒退**，
            // 若按"时间戳更新就采纳"，网页进度会跟着往回跳。
            // ------------------------------------------------------------------
            val dbIndex = dbProgress?.chapterIndex
            // 手机侧「本地 pos」对应我们的 scrollPosition（两者语义不同，`> 0` 视为"有进度"）
            val localHasPosition = dbProgress?.positionStarted == true || (dbProgress?.scrollPosition ?: 0.0) > 0.0
            val remoteHasPosition = fileProgress.chapterPos > 0
            val fileWins = when {
                dbIndex == null -> true                                  // 本地没有进度 → 用文件的
                fileIndex > dbIndex -> true                              // 远端更靠后 → 采纳
                fileIndex < dbIndex -> false                             // 远端更靠前 → 保留本地
                else -> remoteHasPosition && !localHasPosition           // idx 相同 → 比 pos
            }

            if (fileWins) {
                // 采纳文件进度并写回数据库
                val aligned = chapters[fileIndex]
                val merged = database.saveProgress(
                    ReadingProgress(
                        sourceId = request.sourceId,
                        bookUrl = request.bookUrl,
                        chapterUrl = aligned.url,
                        chapterIndex = fileIndex,
                        scrollPosition = dbProgress?.scrollPosition ?: 0.0,
                        positionStarted = remoteHasPosition,
                        positionMs = if (kind == "audio") fileProgress.chapterPos.toLong().takeIf { it > 0 } ?: dbProgress?.positionMs else null,
                        chapterTitle = aligned.title,
                        bookKind = kind,
                    )
                )
                call.respond(ProgressMergeResponse(source = "file", progress = merged, fileFound = true, alignedIndex = fileIndex))
            } else {
                call.respond(ProgressMergeResponse(source = "database", progress = dbProgress, fileFound = true, alignedIndex = fileIndex))
            }
        }
        get("/verifications") {
            if (auth.requireSession(call) == null) return@get
            call.respond(browserRuntime?.listSessions() ?: emptyList<SourceVerificationSession>())
        }
        route("/sources/{id}/verifications") {
            post {
                if (auth.requireSession(call, true) == null) return@post
                val runtime = browserRuntime ?: run {
                    call.respond(HttpStatusCode.ServiceUnavailable, ApiError("browser_unavailable", "浏览器运行时未启用"))
                    return@post
                }
                val sourceId = call.parameters["id"]!!
                val source = database.getSource(sourceId) ?: run {
                    call.respond(HttpStatusCode.NotFound, ApiError("not_found", "书源不存在"))
                    return@post
                }
                val request = call.receive<SourceVerificationStartRequest>()
                val sourceObj = runCatching { Json.parseToJsonElement(source.json).jsonObject }.getOrNull()
                val sourceHeaders = (sourceObj?.get("header") as? JsonPrimitive)?.contentOrNull?.let { header ->
                    runCatching { Json.parseToJsonElement(header).jsonObject }.getOrNull()?.entries
                        ?.filter { it.value is JsonPrimitive }
                        ?.associate { it.key to (it.value as JsonPrimitive).content }
                } ?: emptyMap()
                val session = runtime.startVerification(
                    sourceId = source.id,
                    url = request.url,
                    title = request.title,
                    webJs = request.webJs,
                    headers = sourceHeaders + request.headers,
                )
                call.respond(SourceVerificationSession(session.id, session.sourceId, session.url, session.title, session.state, session.mode, session.kind, session.error))
            }
            get("/{sessionId}") {
                if (auth.requireSession(call) == null) return@get
                val runtime = browserRuntime ?: return@get call.respond(HttpStatusCode.ServiceUnavailable, ApiError("browser_unavailable", "浏览器运行时未启用"))
                val session = runtime.getSession(call.parameters["sessionId"]!!) ?: run {
                    call.respond(HttpStatusCode.NotFound, ApiError("not_found", "浏览器会话不存在或已结束"))
                    return@get
                }
                if (session.sourceId != call.parameters["id"]!!) {
                    call.respond(HttpStatusCode.Forbidden, ApiError("forbidden", "会话与书源不匹配"))
                    return@get
                }
                call.respond(SourceVerificationSession(session.id, session.sourceId, session.url, session.title, session.state, session.mode, session.kind, session.error))
            }
            webSocket("/{sessionId}/stream") {
                val csrf = call.request.queryParameters["csrf"]
                if (!auth.hasWebSocketSession(call, csrf)) {
                    close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, "请先登录"))
                    return@webSocket
                }
                val runtime = browserRuntime
                val sourceId = call.parameters["id"]
                val sessionId = call.parameters["sessionId"]
                val view = if (runtime != null && sourceId != null && sessionId != null) {
                    runtime.getSession(sessionId)
                } else {
                    null
                }
                if (runtime == null) {
                    close(CloseReason(CloseReason.Codes.INTERNAL_ERROR, "浏览器运行时未启用"))
                    return@webSocket
                }
                if (view == null || view.sourceId != sourceId) {
                    close(CloseReason(CloseReason.Codes.CANNOT_ACCEPT, "浏览器会话不存在或与书源不匹配"))
                    return@webSocket
                }
                val connection = runtime.attachStream(sessionId!!)
                if (connection == null) {
                    close(CloseReason(CloseReason.Codes.CANNOT_ACCEPT, "浏览器会话已结束"))
                    return@webSocket
                }
                send(
                    Frame.Text(
                        Json.encodeToString(
                            SourceVerificationStreamMessage(
                                type = "ready",
                                state = view.state,
                                url = view.url,
                                title = view.title,
                                error = view.error,
                                width = connection.width,
                                height = connection.height,
                            ),
                        ),
                    ),
                )
                coroutineScope {
                    val sender = launch {
                        try {
                            for (event in connection.events) {
                                when (event) {
                                    is BrowserStreamEvent.Frame ->
                                        send(Frame.Binary(true, event.data))
                                    is BrowserStreamEvent.State ->
                                        send(
                                            Frame.Text(
                                                Json.encodeToString(
                                                    SourceVerificationStreamMessage(
                                                        type = "state",
                                                        state = event.state,
                                                        url = event.url,
                                                        title = event.title,
                                                        error = event.error,
                                                    ),
                                                ),
                                            ),
                                        )
                                    is BrowserStreamEvent.Error ->
                                        send(
                                            Frame.Text(
                                                Json.encodeToString(
                                                    SourceVerificationStreamMessage(type = "error", error = event.message),
                                                ),
                                            ),
                                        )
                                    is BrowserStreamEvent.Closed -> {
                                        send(
                                            Frame.Text(
                                                Json.encodeToString(
                                                    SourceVerificationStreamMessage(
                                                        type = "closed",
                                                        state = event.state,
                                                        error = event.error,
                                                    ),
                                                ),
                                            ),
                                        )
                                        break
                                    }
                                }
                            }
                        } catch (_: IOException) {
                            // 浏览器关闭标签页或网络断开时，WebSocket 写端会以 broken pipe 结束；
                            // 这是实时流的正常生命周期，不应作为未处理请求异常写入服务日志。
                        } finally {
                            close(CloseReason(CloseReason.Codes.NORMAL, "浏览器会话流已结束"))
                        }
                    }
                    try {
                        for (frame in incoming) {
                            if (frame !is Frame.Text) continue
                            val command = runCatching {
                                Json.decodeFromString<BrowserInteraction>(frame.readText())
                            }.getOrNull()
                            if (command == null) {
                                send(
                                    Frame.Text(
                                        Json.encodeToString(
                                            SourceVerificationStreamMessage(type = "error", error = "浏览器操作格式无效"),
                                        ),
                                    ),
                                )
                                continue
                            }
                            try {
                                withContext(Dispatchers.IO) {
                                    runtime.streamInteract(sessionId, command)
                                }
                            } catch (error: Exception) {
                                send(
                                    Frame.Text(
                                        Json.encodeToString(
                                            SourceVerificationStreamMessage(
                                                type = "error",
                                                error = error.message ?: "浏览器操作失败",
                                            ),
                                        ),
                                    ),
                                )
                            }
                        }
                    } finally {
                        sender.cancelAndJoin()
                        connection.close()
                    }
                }
            }
            get("/{sessionId}/screenshot") {
                if (auth.requireSession(call) == null) return@get
                val runtime = browserRuntime ?: return@get call.respond(HttpStatusCode.ServiceUnavailable, ApiError("browser_unavailable", "浏览器运行时未启用"))
                try {
                    if (runtime.getSessionSourceId(call.parameters["sessionId"]!!) != call.parameters["id"]!!) {
                        call.respond(HttpStatusCode.Forbidden, ApiError("forbidden", "会话与书源不匹配"))
                        return@get
                    }
                    val bytes = runtime.screenshot(call.parameters["sessionId"]!!)
                    call.response.header(HttpHeaders.CacheControl, "no-store")
                    call.respondBytes(bytes, ContentType.Image.PNG)
                } catch (error: Exception) {
                    call.respond(HttpStatusCode.ServiceUnavailable, ApiError("screenshot_unavailable", error.message ?: "截图暂不可用"))
                }
            }
            post("/{sessionId}/interact") {
                if (auth.requireSession(call, true) == null) return@post
                val runtime = browserRuntime ?: return@post call.respond(HttpStatusCode.ServiceUnavailable, ApiError("browser_unavailable", "浏览器运行时未启用"))
                val request = call.receive<BrowserInteraction>()
                try {
                    if (runtime.getSessionSourceId(call.parameters["sessionId"]!!) != call.parameters["id"]!!) {
                        call.respond(HttpStatusCode.Forbidden, ApiError("forbidden", "会话与书源不匹配"))
                        return@post
                    }
                    runtime.interact(call.parameters["sessionId"]!!, request)
                    call.respond(HttpStatusCode.NoContent)
                } catch (error: Exception) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("interaction_failed", error.message ?: "操作失败"))
                }
            }
            post("/{sessionId}/complete") {
                if (auth.requireSession(call, true) == null) return@post
                val runtime = browserRuntime ?: return@post call.respond(HttpStatusCode.ServiceUnavailable, ApiError("browser_unavailable", "浏览器运行时未启用"))
                val request = call.receive<SourceVerificationCompleteRequest>()
                try {
                    if (runtime.getSessionSourceId(call.parameters["sessionId"]!!) != call.parameters["id"]!!) {
                        call.respond(HttpStatusCode.Forbidden, ApiError("forbidden", "会话与书源不匹配"))
                        return@post
                    }
                    val session = runtime.complete(call.parameters["sessionId"]!!, request.input) ?: run {
                        call.respond(HttpStatusCode.NotFound, ApiError("not_found", "浏览器会话不存在或已结束"))
                        return@post
                    }
                    call.respond(SourceVerificationSession(session.id, session.sourceId, session.url, session.title, session.state, session.mode, session.kind, session.error))
                } catch (error: Exception) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("interaction_failed", error.message ?: "完成失败"))
                }
            }
            post("/{sessionId}/cancel") {
                if (auth.requireSession(call, true) == null) return@post
                val runtime = browserRuntime ?: return@post call.respond(HttpStatusCode.ServiceUnavailable, ApiError("browser_unavailable", "浏览器运行时未启用"))
                try {
                    if (runtime.getSessionSourceId(call.parameters["sessionId"]!!) != call.parameters["id"]!!) {
                        call.respond(HttpStatusCode.Forbidden, ApiError("forbidden", "会话与书源不匹配"))
                        return@post
                    }
                    if (!runtime.cancel(call.parameters["sessionId"]!!)) {
                        call.respond(HttpStatusCode.NotFound, ApiError("not_found", "浏览器会话不存在或已结束"))
                        return@post
                    }
                    call.respond(HttpStatusCode.NoContent)
                } catch (error: Exception) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("interaction_failed", error.message ?: "取消失败"))
                }
            }
            get("/{sessionId}/result") {
                if (auth.requireSession(call) == null) return@get
                val runtime = browserRuntime ?: return@get call.respond(HttpStatusCode.ServiceUnavailable, ApiError("browser_unavailable", "浏览器运行时未启用"))
                try {
                    if (runtime.getSessionSourceId(call.parameters["sessionId"]!!) != call.parameters["id"]!!) {
                        call.respond(HttpStatusCode.Forbidden, ApiError("forbidden", "会话与书源不匹配"))
                        return@get
                    }
                    val result = runtime.result(call.parameters["sessionId"]!!)
                    if (result == null) {
                        call.respond(HttpStatusCode.Accepted, ApiError("pending", "浏览器验证尚未完成"))
                    } else {
                        call.respond(SourceVerificationResult(result.url, result.body, result.status, result.headers))
                    }
                } catch (error: Exception) {
                    call.respond(HttpStatusCode.BadRequest, ApiError("result_failed", error.message ?: "查询结果失败"))
                }
            }
        }
    }
}

private fun validateSubscriptionUrl(value: String) {
    val uri = runCatching { java.net.URI(value) }.getOrNull()
    require(uri?.scheme in setOf("http", "https") && !uri?.host.isNullOrBlank()) { "仅允许 HTTP(S) 订阅地址" }
}

/** Android SearchModel: 每个书源外层 `withTimeout(30000L)`。 */
private const val SEARCH_TIMEOUT_MS = 30_000L
private const val CHAPTERS_TIMEOUT_MS = 120_000L

private suspend fun readableSearchResults(runner: RuleRunner, sourceJson: String, keyword: String, page: Int): List<SearchResult> =
    searchSourceOutcome(runner, sourceJson, keyword, page).results

internal data class SearchSourceOutcome(
    val results: List<SearchResult>,
    val failed: Boolean,
    /** 单源失败 / WS source_failed 的具体阶段原因。 */
    val error: String? = null,
)

internal class SearchStreamCounters(private val totalSources: Int) {
    private val completed = AtomicInteger()
    private val matched = AtomicInteger()
    private val empty = AtomicInteger()
    private val failed = AtomicInteger()
    private val resultCount = AtomicInteger()

    fun complete(outcome: SearchSourceOutcome): SearchStreamEvent {
        when {
            outcome.results.isNotEmpty() -> {
                matched.incrementAndGet()
                resultCount.addAndGet(outcome.results.size)
            }
            outcome.failed -> failed.incrementAndGet()
            else -> empty.incrementAndGet()
        }
        completed.incrementAndGet()
        return snapshot()
    }

    fun snapshot(type: String = "progress") = SearchStreamEvent(
        type = type,
        totalSources = totalSources,
        completedSources = completed.get(),
        matchedSources = matched.get(),
        emptySources = empty.get(),
        failedSources = failed.get(),
        resultCount = resultCount.get(),
    )
}

internal suspend fun searchSourceOutcome(
    runner: RuleRunner,
    sourceJson: String,
    keyword: String,
    page: Int = 1,
    timeoutMillis: Long = SEARCH_TIMEOUT_MS,
): SearchSourceOutcome {
    val results = try {
        val future = CompletableFuture.supplyAsync(
            { runner.search(sourceJson, keyword, page, callTimeoutMillis = timeoutMillis) },
            Dispatchers.IO.asExecutor(),
        )
        withTimeout(timeoutMillis) { future.awaitCancellable() }
    } catch (error: Throwable) {
        if (error is TimeoutCancellationException) {
            return SearchSourceOutcome(emptyList(), failed = true, error = "书源搜索超时")
        }
        if (error is CancellationException) throw error
        return SearchSourceOutcome(emptyList(), failed = true, error = error.message ?: error.javaClass.simpleName)
    }
    return SearchSourceOutcome(results, failed = false)
}

/**
 * 等待阻塞式规则执行，但允许协程超时立即取消。
 *
 * `runInterruptible` 遇到 OkHttp 同步调用时，外层可能仍要等网络线程退出，
 * 导致 Android 的 30 秒搜索边界失效。Future 本身可以立即取消等待，网络调用
 * 也使用同一个 call timeout 作为兜底。
 */
private suspend fun <T> CompletableFuture<T>.awaitCancellable(): T =
    suspendCancellableCoroutine { continuation ->
        whenComplete { value, error ->
            if (error == null) {
                continuation.resume(value) { _, _, _ -> }
            } else {
                val cause = (error as? CompletionException)?.cause ?: error
                continuation.resumeWithException(cause)
            }
        }
        continuation.invokeOnCancellation { cancel(true) }
    }

/**
 * Android SearchModel 使用 `min(AppConfig.threadCount, AppConst.MAX_THREAD)` 个线程，
 * 默认配置会落到 [ANDROID_SEARCH_MAX_THREAD]。
 */
internal fun sourceSearchConcurrency(): Int = ANDROID_SEARCH_MAX_THREAD

private const val ANDROID_SEARCH_MAX_THREAD = 9

internal suspend fun <T, R> boundedConcurrentMap(values: List<T>, limit: Int, action: suspend (T) -> R): List<R> = coroutineScope {
    val semaphore = Semaphore(limit.coerceAtLeast(1))
    values.map { value -> async { semaphore.withPermit { action(value) } } }.awaitAll()
}

/** 图片 key = sha256 的十六进制（64 位）。非法 key 直接 404，绝不拿它去拼路径。 */
private val MANGA_IMAGE_KEY_PATTERN = Regex("[0-9a-f]{64}")
/**
 * 音频 key 只接受 64 位小写十六进制。
 *
 * 与图片同样必须**先校验再落到 `Path.resolve`**：AGENTS.md 铁律——`Path.resolve()` 对非法字符
 * （换行、`..`、绝对路径…）会**抛异常**，而不是返回一个不存在的路径。
 */
private val AUDIO_KEY_PATTERN = Regex("[0-9a-f]{64}")
private val mangaImagesJson = Json { ignoreUnknownKeys = true }

/** 章节图片清单（有序上游 URL 数组）的序列化 —— **仅服务端可见**，绝不下发前端。 */
internal fun encodeMangaImageUrls(urls: List<String>): String =
    mangaImagesJson.encodeToString(ListSerializer(String.serializer()), urls)

internal fun decodeMangaImageUrls(json: String): List<String>? =
    runCatching { mangaImagesJson.decodeFromString(ListSerializer(String.serializer()), json) }.getOrNull()

private suspend fun ApplicationCall.respondCatching(block: suspend () -> Any) {
    try { respond(block()) }
    catch (error: RuleExecutionException) { respond(HttpStatusCode.BadGateway, ApiError("source_execution_failed", error.message ?: "书源执行失败")) }
    catch (error: Exception) { respond(HttpStatusCode.BadGateway, ApiError("source_execution_failed", error.message ?: "书源执行失败")) }
}

internal fun tryFindCachedCover(coverCache: CoverCache, primaryUrl: String?, alternateSources: List<SearchResult>?, book: CoverBookRef? = null): CachedCover? {
    val candidates = buildList {
        primaryUrl?.takeIf { it.isNotBlank() }?.let { add(it) }
        alternateSources?.forEach { s ->
            s.coverUrl?.takeIf { it.isNotBlank() && it !in this }?.let { add(it) }
        }
    }
    for (url in candidates) {
        val cached = coverCache.getIfCached(url, book)
        if (cached != null) return cached
    }
    return null
}

/**
 * 抓一张封面并按内容哈希落盘。
 *
 * 每个候选地址都按**它自己的书源**取 `coverDecodeJs`（候选源与本书源规则可能不同）：
 * 拿错规则去解一张没加密的图就是把好图解坏；解码器为空则完全不解密（Android `skipDecode`）。
 */
internal fun tryCacheCover(
    coverCache: CoverCache,
    primaryUrl: String?,
    alternateSources: List<SearchResult>?,
    book: CoverBookRef? = null,
    database: Database? = null,
    runner: RuleRunner? = null,
): CachedCover? {
    val candidates = buildList {
        primaryUrl?.takeIf { it.isNotBlank() }?.let { add(it to book?.sourceId) }
        alternateSources?.forEach { s ->
            s.coverUrl?.takeIf { it.isNotBlank() && it !in this.map { candidate -> candidate.first } }
                ?.let { add(it to s.sourceId) }
        }
    }
    for ((url, ownerSourceId) in candidates) {
        val decoder = ownerSourceId?.let { sourceId ->
            val record = database?.getSource(sourceId)
            if (record == null) null else runCatching { runner?.imageDecoder(record.json, isCover = true) }.getOrNull()
        }
        val cached = runCatching { coverCache.cache(url, book, emptyMap(), decoder) }.getOrNull()
        if (cached != null) return cached
    }
    return null
}

/**
 * 取一本书的详情（`POST /books/details` 与封面深度回源补抓**共用同一份逻辑**）。
 *
 * 返回 null 表示「取不到」——书源不存在，或本地书不在书架；
 * 书源侧的失败（[RuleExecutionException] 等）原样抛出，由调用方决定转成 HTTP 提示还是计入 failed。
 * **不要在这里把异常吞掉**：`/books/details` 依赖它把书源错误转成明确提示（`source_execution_failed`）。
 */
/**
 * 取一本书的目录 —— **阅读路径与后台缓存共用这一份**。
 *
 * 历史缺陷（2026-10-17 实测）：后台批量缓存过去直接 `runner.chapters(source, tocUrl)` 只试一次，
 * 而阅读路径 `/books/chapters` 在失败时会先 `details()` 拿到真正的 tocUrl 再重试。
 * 聚合源（`data:;base64,…` 的书号/书名）在书架里存的 `toc_url` 可能是一次性错误载荷，
 * 于是出现「**能读不能缓存**」：阅读器 200 拿到 462 章，缓存却 failed / 目录规则未提取到章节。
 *
 * 缓存优先级：有 distinct [tocUrlHint] 时只查 hint 缓存，避免旧 bookUrl 缓存截胡；
 * 无 hint 时查 [bookUrl] 及 `/toc` 变体。解析候选仍为 hint → bookUrl → details(bookUrl).tocUrl。
 * 命中后统一把目录写进 TOC 缓存，并返回章列表（空列表表示真的取不到）。
 */
/**
 * 换源时把旧书的阅读进度迁移到新书：按**章节下标**定位，越界时退化为**章节标题**匹配
 * （对齐 Android `BookHelp.getDurChapter` 的定位顺序）。
 *
 * 只有真的定位到章节才写进度 —— 宁可暂时没有进度，也不能留一个指向旧源的脏章节地址。
 * 目录取不到时抛错交给调用方兜底（调用方只记日志，不影响换源结果）。
 */
internal suspend fun adoptProgressOnSwitch(
    oldProgress: ReadingProgress,
    item: BookshelfItem,
    database: Database,
    runner: RuleRunner,
): BookshelfItem {
    val source = database.getSource(item.sourceId) ?: return item
    val context = database.bookContext(
        item.sourceId,
        item.bookUrl,
        BookContext(
            sourceId = item.sourceId,
            bookUrl = item.bookUrl,
            name = item.name,
            author = item.author,
            tocUrl = item.tocUrl,
            kind = item.bookKind,
            variables = mutableMapOf(),
        ),
    )
    val chapters = withContext(Dispatchers.IO) {
        resolveBookChapters(database, runner, item.sourceId, item.bookUrl, source.json, context, tocUrlHint = item.tocUrl)
    }
    if (chapters.isEmpty()) return item
    val byIndex = chapters.getOrNull(oldProgress.chapterIndex)
    val byTitle = oldProgress.chapterTitle?.trim()?.takeIf { it.isNotEmpty() }?.let { title ->
        chapters.firstOrNull { chapter -> chapter.title.trim() == title }
    }
    val target = byIndex ?: byTitle ?: return item
    database.saveProgress(
        ReadingProgress(
            sourceId = item.sourceId,
            bookUrl = item.bookUrl,
            chapterUrl = target.url,
            chapterIndex = target.index,
            scrollPosition = oldProgress.scrollPosition,
            positionStarted = oldProgress.positionStarted,
            chapterTitle = target.title,
            positionMs = oldProgress.positionMs,
        ),
    )
    val catalogChapters = chapters.size
    return item.copy(
        chapterIndex = target.index,
        scrollPosition = oldProgress.scrollPosition,
        positionMs = oldProgress.positionMs ?: item.positionMs,
        catalogChapters = catalogChapters,
        isUnread = target.index == 0 && !oldProgress.positionStarted,
        isReading = target.index > 0 && target.index < catalogChapters - 1,
        isReadFinished = target.index >= catalogChapters - 1,
    )
}

internal suspend fun resolveBookChapters(
    database: Database,
    runner: RuleRunner,
    sourceId: String,
    bookUrl: String,
    sourceJson: String,
    bookContext: BookContext,
    tocUrlHint: String? = null,
    forceRefresh: Boolean = false,
): List<Chapter> {
    val tocUrlCacheHint = tocUrlHint?.takeIf { it.isNotBlank() && it != bookUrl }
    val callerContext = currentCoroutineContext()
    val cancellationCheck = { callerContext.ensureActive() }
    val cacheKeys = if (tocUrlCacheHint != null) {
        listOf(tocUrlCacheHint)
    } else {
        listOfNotNull(
            bookUrl,
            bookUrl.removeSuffix("/toc") + "/toc",
        )
    }
    if (!forceRefresh) {
        for (key in cacheKeys) {
            val cached = database.getTocCache(sourceId, key)
            if (!cached.isNullOrEmpty()) {
                callerContext.ensureActive()
                return database.applyIgnoredBookCacheChapters(sourceId, bookUrl, cached)
            }
        }
    }

    val hintRaw = tocUrlHint?.takeIf { it.isNotBlank() }
    // Android 的调用点（ReadBookViewModel:126、CacheBookService:112、MainViewModel:192 …）在
    // **book.tocUrl 为空**时一律先 `loadBookInfo(book)` 把 tocUrl 补出来再解析目录；只有详情规则
    // 也取不到 tocUrl 时才回退成详情页地址（BookInfo.kt:158）。少了这一步，「详情页上的最新章节块」
    // 会被当成完整目录：爱丽丝书屋实测只解析出 5 章，而真机同一本书是 647 章。
    // 已经带 tocUrl 的调用（前端、详情页流程）不受影响，仍按 hint → 书链顺序走。
    val preResolvedDetails = if (hintRaw == null) {
        try {
            runInterruptible(Dispatchers.IO) { runner.details(sourceJson, bookUrl, bookContext) }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        }
    } else {
        null
    }
    val candidates = listOfNotNull(
        hintRaw?.takeIf { it != bookUrl },
        preResolvedDetails?.tocUrl?.takeIf { it.isNotBlank() },
        bookUrl,
    ).distinct()
    for (url in candidates) {
        // 单次失败不抛出：继续试下一个候选（最后还有 details 回退），
        // 这样"某个 url 不可用"不会让整本书的缓存直接失败。
        val chapters = try {
            runInterruptible(Dispatchers.IO) {
                // 这是真正的网络取目录（缓存未命中/主动刷新），对齐 Android 刷新目录时
                // `runPerJs = true` 的语义：先执行 ruleToc.preUpdateJs 再解析列表。
                runner.chapters(sourceJson, url, bookContext, cancellationCheck, runPreUpdateJs = true)
            }.also { callerContext.ensureActive() }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        }.orEmpty()
        if (chapters.isNotEmpty()) {
            callerContext.ensureActive()
            val effectiveChapters = database.applyIgnoredBookCacheChapters(sourceId, bookUrl, chapters)
            // The shelf refresher commits the new TOC and queued cache work together.
            if (!forceRefresh) {
                database.saveTocCache(sourceId, url, effectiveChapters)
                callerContext.ensureActive()
                if (url != bookUrl) database.saveTocCache(sourceId, bookUrl, effectiveChapters)
            }
            return effectiveChapters
        }
    }

    callerContext.ensureActive()
    val details = preResolvedDetails
        ?: runInterruptible(Dispatchers.IO) { runner.details(sourceJson, bookUrl, bookContext) }
    callerContext.ensureActive()
    val toc = runInterruptible(Dispatchers.IO) {
        // 详情规则刚在本请求里解析完就顺势取目录：对齐 Android `getChapterListAwait(isFromBookInfo = true)`，
        // 这样 preUpdateJs 里的 `refreshTocUrl()` 只记日志跳过重解析（避免详情→目录自递归）。
        runner.chapters(
            sourceJson,
            details.tocUrl,
            bookContext,
            cancellationCheck,
            runPreUpdateJs = true,
            fromBookInfo = true,
        )
    }
    callerContext.ensureActive()
    if (toc.isNotEmpty()) {
        callerContext.ensureActive()
        val effectiveToc = database.applyIgnoredBookCacheChapters(sourceId, bookUrl, toc)
        if (!forceRefresh) {
            database.saveTocCache(sourceId, details.tocUrl, effectiveToc)
            callerContext.ensureActive()
            // `preUpdateJs` 的 `reGetBook()` 可能就地换掉书链，缓存与变量同时按当前地址保存。
            if (bookContext.bookUrl != bookUrl) {
                database.saveTocCache(sourceId, bookContext.bookUrl, effectiveToc)
                database.persistBookVariables(bookContext)
            }
            callerContext.ensureActive()
            database.saveTocCache(sourceId, bookUrl, effectiveToc)
        }
        return effectiveToc
    }
    return toc
}

internal fun fetchBookDetails(
    database: Database,
    runner: RuleRunner,
    sourceId: String,
    bookUrl: String,
    bookContext: BookContext? = null,
): BookDetails? {
    if (sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID) {
        val shelf = database.listBookshelf().firstOrNull { it.sourceId == sourceId && it.bookUrl == bookUrl } ?: return null
        return BookDetails(
            sourceId = LocalBookParser.LOC_BOOK_SOURCE_ID,
            name = shelf.name,
            author = shelf.author,
            intro = null,
            coverUrl = shelf.coverKey?.let { "/api/covers/$it" },
            tocUrl = shelf.tocUrl,
            variables = database.getBookVariables(sourceId, bookUrl),
            bookKind = BookKind.LOCAL.wire,
        )
    }
    val source = database.getSource(sourceId) ?: return null
    // 详情规则也带书籍上下文：Legado 的 `getBookInfo(book)` 里 `book.getVariable(...)` 是常见写法
    // （音色/线路参数往往在详情步骤就参与拼 URL）。
    val book = bookContext ?: database.bookContext(sourceId, bookUrl)
    val details = runner.details(source.json, bookUrl, book)
    database.persistBookVariables(book)
    // 详情页必须吐出变量表：前端「编辑书籍信息」的变量栏据此回显，且**未入架的书**
    // （`saveBookVariables` 只更新已有书架行，写不进去）也要靠响应把变量带回给客户端，
    // 下一步目录/正文才能用 `@get:{...}` 读到详情步骤 `@put` 的值 —— Android 里这份
    // 变量本来就挂在内存中的 Book 对象上，服务端无状态，只能靠响应往返。
    return details.copy(variables = book.variables.toMap())
}

/**
 * 深度补抓的第一步：回书源取**新的**封面地址。
 *
 * [fetchDetails] 使用 [fetchBookDetails] 获取书源详情；
 * 任何失败（回源异常、书源没配封面规则、取到空值）都静默返回 null。
 */
internal fun resolveFreshCoverUrl(item: BookshelfItem, fetchDetails: (BookshelfItem) -> BookDetails?): String? =
    runCatching { fetchDetails(item)?.coverUrl }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() }

/**
 * 深度补抓的第二步：把新地址物化成服务端本地副本，并**同时**把 `cover_url` 更新成新地址。
 *
 * 注意这里走的是 [CoverCache.cache]——内置下载路径的魔数校验与 gzip 兜底解压都在它内部，
 * 不要绕过（历史踩坑：gzip 字节当 JPEG 落盘 ⇒ 接口 200 但 `<img>` 是裂图）。
 * 下载失败静默返回 null，由调用方计入 failed 并继续处理下一本。
 *
 * @param headers 书源自带的 `header` / `Cookie`（回源下载必须带上，否则防盗链 403）。
 */
internal fun materializeCover(
    database: Database,
    coverCache: CoverCache,
    item: BookshelfItem,
    url: String,
    headers: Map<String, String> = emptyMap(),
    decoder: ImageByteDecoder? = null,
): CachedCover? =
    runCatching {
        // 带着书籍身份去落盘：文件名就是 `书名 (书哈希).扩展名`（哈希与书目录同源）
        val identity = CoverBookRef(item.name, item.sourceId, item.bookUrl)
        coverCache.getIfCached(url, identity) ?: coverCache.cache(url, identity, headers, decoder)
    }.getOrNull()
        ?.takeIf { database.updateBookshelfCover(item.sourceId, item.bookUrl, it.key, it.contentType, coverUrl = url) }

private fun jsonEvent(message: String): String = Json.encodeToString(message)

/**
 * 把代理结果写回响应；失败时返回一张可读的 HTML 错误页（因为它会被渲染进内置浏览器 iframe）。
 */
private suspend fun ApplicationCall.respondProxied(block: () -> ProxiedPayload) {
    // iframe 处于 sandbox 不透明源下，页面内 JS 发起的请求需要 CORS 放行；
    // 这些端点本身由一次性令牌鉴权，不依赖管理会话，因此放开 * 不会泄露权限。
    response.headers.append(HttpHeaders.AccessControlAllowOrigin, "*")
    try {
        val payload = withContext(Dispatchers.IO) { block() }
        // 透传上游的缓存元数据：此前一个都不转发，浏览器什么都缓存不了，
        // 连 CDN 明确声明 `max-age=30672000, immutable` 的字体/JS/CSS 也被迫每次重下。
        payload.cacheHeaders.forEach { (name, value) -> response.headers.append(name, value) }
        respondBytes(
            bytes = payload.body,
            contentType = runCatching { ContentType.parse(payload.contentType) }.getOrNull(),
            status = HttpStatusCode.fromValue(payload.status),
        )
    } catch (error: WebViewException) {
        application.log.warn("webview proxy failed: {}", error.message)
        respondText(
            text = webViewErrorPage(error.message ?: "内置浏览器请求失败"),
            contentType = ContentType.Text.Html.withCharset(Charsets.UTF_8),
            status = HttpStatusCode.BadGateway,
        )
    }
}

private fun webViewErrorPage(message: String): String {
    val escaped = message
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><title>内置浏览器无法打开页面</title>
        <style>
          body{margin:0;padding:32px;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;
               background:#0f1115;color:#e6e8eb;display:flex;align-items:center;justify-content:center;min-height:100vh}
          .card{max-width:520px;background:#171a21;border:1px solid #262b36;border-radius:12px;padding:24px}
          h1{margin:0 0 12px;font-size:16px;color:#f87171}
          p{margin:0;font-size:13px;line-height:1.7;color:#9aa4b2;word-break:break-all}
        </style></head>
        <body><div class="card"><h1>无法打开该页面</h1><p>$escaped</p></div></body></html>
    """.trimIndent()
}

private suspend fun parseImportedReplaceRules(bodyText: String): List<ReplaceRule> {
    val cleanText = bodyText.trim().removePrefix("\uFEFF")
    if (cleanText.isBlank()) return emptyList()

    val json = Json { ignoreUnknownKeys = true; isLenient = true }
    val jsonElement = runCatching { json.parseToJsonElement(cleanText) }.getOrNull() ?: return emptyList()

    // Check if it's an object with "url"
    if (jsonElement is kotlinx.serialization.json.JsonObject) {
        val url = jsonElement["url"]?.let { if (it is JsonPrimitive) it.contentOrNull else null }
        if (!url.isNullOrBlank()) {
            validateSubscriptionUrl(url)
            val client = java.net.http.HttpClient.newBuilder().connectTimeout(java.time.Duration.ofSeconds(10)).build()
            val req = java.net.http.HttpRequest.newBuilder().uri(java.net.URI(url)).GET().build()
            val resp = withContext(Dispatchers.IO) { client.send(req, java.net.http.HttpResponse.BodyHandlers.ofString(Charsets.UTF_8)) }
            return parseImportedReplaceRules(resp.body())
        }
    }

    val array = when (jsonElement) {
        is kotlinx.serialization.json.JsonArray -> jsonElement
        is kotlinx.serialization.json.JsonObject -> {
            (jsonElement["rules"] ?: jsonElement["data"] ?: jsonElement["replaceRules"] ?: jsonElement["items"]) as? kotlinx.serialization.json.JsonArray
        }
        else -> null
    } ?: return emptyList()

    return array.mapNotNull { item ->
        if (item !is kotlinx.serialization.json.JsonObject) return@mapNotNull null
        val pattern = item["pattern"]?.let { if (it is JsonPrimitive) it.contentOrNull else null } ?: return@mapNotNull null
        if (pattern.isBlank()) return@mapNotNull null
        val id = item["id"]?.let { if (it is JsonPrimitive) it.contentOrNull else null } ?: ""
        val name = item["name"]?.let { if (it is JsonPrimitive) it.contentOrNull else null } ?: pattern
        val group = item["group"]?.let { if (it is JsonPrimitive) it.contentOrNull else null } ?: item["groupName"]?.let { if (it is JsonPrimitive) it.contentOrNull else null }
        val replacement = item["replacement"]?.let { if (it is JsonPrimitive) it.contentOrNull else null } ?: ""
        val isRegex = item["isRegex"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toBooleanStrictOrNull() ?: (it.contentOrNull?.toIntOrNull() != 0) else null } ?: true
        val scope = item["scope"]?.let { if (it is JsonPrimitive) it.contentOrNull else null }
        val excludeScope = item["excludeScope"]?.let { if (it is JsonPrimitive) it.contentOrNull else null }
        val scopeTitle = item["scopeTitle"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toBooleanStrictOrNull() ?: (it.contentOrNull?.toIntOrNull() == 1) else null } ?: false
        val scopeContent = item["scopeContent"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toBooleanStrictOrNull() ?: (it.contentOrNull?.toIntOrNull() != 0) else null } ?: true
        val isEnabled = item["isEnabled"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toBooleanStrictOrNull() ?: (it.contentOrNull?.toIntOrNull() != 0) else null } ?: true
        val order = item["order"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toIntOrNull() else null } ?: item["sortOrder"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toIntOrNull() else null } ?: 0
        val timeoutMs = item["timeoutMillisecond"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toLongOrNull() else null } ?: item["timeout_ms"]?.let { if (it is JsonPrimitive) it.contentOrNull?.toLongOrNull() else null } ?: 3000L

        ReplaceRule(
            id = id,
            name = name,
            group = group,
            pattern = pattern,
            replacement = replacement,
            isRegex = isRegex,
            scope = scope,
            excludeScope = excludeScope,
            scopeTitle = scopeTitle,
            scopeContent = scopeContent,
            isEnabled = isEnabled,
            order = order,
            timeoutMillisecond = timeoutMs,
        )
    }
}

private suspend fun probeSingleSourceHealth(
    client: java.net.http.HttpClient,
    sourceId: String,
    sourceName: String,
    rawJson: String,
    timeoutMs: Long,
): SourceHealthCheckItem {
    val validation = SourceCodec.validate(rawJson)
    if (!validation.valid) {
        return SourceHealthCheckItem(
            id = sourceId,
            name = sourceName,
            ok = false,
            latencyMs = 0L,
            statusCode = 0,
            statusCategory = "failed",
            error = validation.errors.firstOrNull() ?: "书源规则语法无效",
        )
    }

    val sourceObj = runCatching { Json.parseToJsonElement(rawJson).jsonObject }.getOrNull()
    val isJs = sourceObj?.get("mainJs")?.let { (it as? JsonPrimitive)?.contentOrNull?.isNotBlank() } == true
    val bookSourceUrl = (sourceObj?.get("bookSourceUrl") as? JsonPrimitive)?.contentOrNull?.trim()
    val searchUrl = (sourceObj?.get("searchUrl") as? JsonPrimitive)?.contentOrNull?.trim()

    val candidateUrl = when {
        bookSourceUrl?.startsWith("http://", ignoreCase = true) == true || bookSourceUrl?.startsWith("https://", ignoreCase = true) == true -> bookSourceUrl
        searchUrl?.startsWith("http://", ignoreCase = true) == true || searchUrl?.startsWith("https://", ignoreCase = true) == true -> searchUrl.substringBefore("{{").substringBefore("@").substringBefore(",")
        else -> null
    }

    if (candidateUrl == null) {
        return if (isJs) {
            SourceHealthCheckItem(
                id = sourceId,
                name = sourceName,
                ok = true,
                latencyMs = 1L,
                statusCode = 200,
                statusCategory = "valid",
                error = null,
            )
        } else {
            SourceHealthCheckItem(
                id = sourceId,
                name = sourceName,
                ok = false,
                latencyMs = 0L,
                statusCode = 0,
                statusCategory = "failed",
                error = "未配置可达的 HTTP(S) 地址",
            )
        }
    }

    val startNs = System.nanoTime()
    return try {
        val cleanUrl = candidateUrl.substringBefore("#").trim()
        val targetUri = java.net.URI.create(cleanUrl)
        try {
            NetworkSecurity.resolveAndValidateSafeHttpTarget(targetUri, "书源")
        } catch (ssrfEx: IllegalArgumentException) {
            return SourceHealthCheckItem(
                id = sourceId,
                name = sourceName,
                ok = false,
                latencyMs = 0L,
                statusCode = 0,
                statusCategory = "failed",
                error = ssrfEx.message ?: "安全校验未通过",
            )
        }

        val req = java.net.http.HttpRequest.newBuilder(targetUri)
            .timeout(java.time.Duration.ofMillis(timeoutMs))
            .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
            .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
            .GET()
            .build()

        val resp = withContext(Dispatchers.IO) {
            client.send(req, java.net.http.HttpResponse.BodyHandlers.discarding())
        }
        val latencyMs = (System.nanoTime() - startNs) / 1_000_000
        val code = resp.statusCode()

        when (code) {
            in 200..399 -> {
                val category = if (latencyMs > 2500) "slow" else "valid"
                SourceHealthCheckItem(
                    id = sourceId,
                    name = sourceName,
                    ok = true,
                    latencyMs = latencyMs,
                    statusCode = code,
                    statusCategory = category,
                    error = null,
                )
            }
            401, 403 -> {
                SourceHealthCheckItem(
                    id = sourceId,
                    name = sourceName,
                    ok = false,
                    latencyMs = latencyMs,
                    statusCode = code,
                    statusCategory = "blocked",
                    error = "访问受限 (HTTP $code)",
                )
            }
            else -> {
                SourceHealthCheckItem(
                    id = sourceId,
                    name = sourceName,
                    ok = false,
                    latencyMs = latencyMs,
                    statusCode = code,
                    statusCategory = "failed",
                    error = "响应异常 (HTTP $code)",
                )
            }
        }
    } catch (ex: java.net.http.HttpTimeoutException) {
        val latencyMs = (System.nanoTime() - startNs) / 1_000_000
        SourceHealthCheckItem(
            id = sourceId,
            name = sourceName,
            ok = false,
            latencyMs = latencyMs,
            statusCode = 0,
            statusCategory = "failed",
            error = "连接超时 (>${timeoutMs}ms)",
        )
    } catch (ex: java.net.UnknownHostException) {
        SourceHealthCheckItem(
            id = sourceId,
            name = sourceName,
            ok = false,
            latencyMs = 0L,
            statusCode = 0,
            statusCategory = "failed",
            error = "域名解析失败 (${ex.message ?: "DNS Error"})",
        )
    } catch (ex: javax.net.ssl.SSLException) {
        val latencyMs = (System.nanoTime() - startNs) / 1_000_000
        SourceHealthCheckItem(
            id = sourceId,
            name = sourceName,
            ok = false,
            latencyMs = latencyMs,
            statusCode = 0,
            statusCategory = "failed",
            error = "SSL证书或握手失败 (${ex.message ?: "SSL Error"})",
        )
    } catch (ex: java.net.ConnectException) {
        val latencyMs = (System.nanoTime() - startNs) / 1_000_000
        SourceHealthCheckItem(
            id = sourceId,
            name = sourceName,
            ok = false,
            latencyMs = latencyMs,
            statusCode = 0,
            statusCategory = "failed",
            error = "连接被拒绝 (${ex.message ?: "Connection Refused"})",
        )
    } catch (ex: Throwable) {
        val latencyMs = (System.nanoTime() - startNs) / 1_000_000
        SourceHealthCheckItem(
            id = sourceId,
            name = sourceName,
            ok = false,
            latencyMs = latencyMs,
            statusCode = 0,
            statusCategory = "failed",
            error = ex.message ?: "探测异常",
        )
    }
}



/**
 * 书架列表 + **按书型**的缓存进度。
 *
 * 背景：列表里的 `cacheState`/`cachedChapters` 过去只来自 `book_cache_status`（正文缓存表），
 * 而漫画/有声的缓存是**媒体预取**（图片 / 音频）⇒ 列表永远显示"0 章 / 重试离线缓存"，
 * 与目录抽屉里绿点在涨自相矛盾（用户反馈"书架弹窗里缓存不动"）。
 * 这里对 COMIC/AUDIO 用媒体口径覆盖：
 *   - 有在跑的预取任务 → `caching` + done/planned（列表进度条能动）
 *   - 否则按"整章就绪章数"给 `ready`/`idle`，且**不再透出正文缓存的错误**（那不是它们的缓存）
 * 小说保持原样（正文缓存）。
 */
internal fun bookshelfWithMediaCache(
    database: Database,
    mangaPrefetch: MangaPrefetchService?,
    audioPrefetch: AudioPrefetchService?,
): List<BookshelfItem> {
    val books = database.listBookshelf()
    if (books.isEmpty()) return books
    val mangaReady = database.readyMangaChapterCountsByBook()
    val audioReady = database.readyAudioChapterCountsByBook()
    val mangaRunning = mangaPrefetch?.status()?.filter { it.running }?.associateBy { "${it.sourceId}\u0000${it.bookUrl}" }.orEmpty()
    val audioRunning = audioPrefetch?.status()?.filter { it.running }?.associateBy { "${it.sourceId}\u0000${it.bookUrl}" }.orEmpty()

    return books.map { item ->
        val key = "${item.sourceId}\u0000${item.bookUrl}"
        when (BookKind.from(item.bookKind)) {
            BookKind.COMIC -> {
                val running = mangaRunning[key]
                val ready = mangaReady[key] ?: 0
                item.copy(
                    cachedChapters = running?.done ?: ready,
                    totalChapters = running?.planned?.takeIf { it > 0 } ?: item.totalChapters.coerceAtLeast(ready),
                    cacheState = when {
                        running != null -> "caching"
                        ready > 0 -> "ready"
                        else -> "idle"
                    },
                    // 正文缓存的错误对漫画没有意义，别在列表里报"重试离线缓存"
                    cacheError = null,
                )
            }
            BookKind.AUDIO -> {
                val running = audioRunning[key]
                val ready = audioReady[key] ?: 0
                item.copy(
                    cachedChapters = running?.done ?: ready,
                    totalChapters = running?.planned?.takeIf { it > 0 } ?: item.totalChapters.coerceAtLeast(ready),
                    cacheState = when {
                        running != null -> "caching"
                        ready > 0 -> "ready"
                        else -> "idle"
                    },
                    cacheError = null,
                )
            }
            BookKind.NOVEL -> item
            // 本地书（issue #66）：缓存进度就是导入时落库的正文行数（`book_cache_status` 已是 ready），
            // 列表原样透出即可 —— 这是 `when` 的表达式分支，漏写会直接编译不过。
            BookKind.LOCAL -> item
        }
    }
}
