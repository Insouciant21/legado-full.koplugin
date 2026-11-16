package io.legado.server

import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.cio.*
import io.ktor.server.engine.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.plugins.statuspages.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.sessions.*
import io.ktor.server.websocket.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

fun main(args: Array<String>) {
    if (args.firstOrNull() == "reset-password") {
        resetPasswordMain(args.drop(1).toTypedArray())
        return
    }
    val config = ServerConfig.fromEnvironment()
    embeddedServer(CIO, host = config.host, port = config.port) {
        legadoApplication(config)
    }.start(wait = true)
}

fun Application.legadoApplication(
    config: ServerConfig = ServerConfig.fromEnvironment(),
) {
    val database = Database(config.databasePath)
    database.initialize(config.initialAdminPassword)
    val reconciledCacheProgress = database.reconcileBookCacheProgressAndTotalsFromTocCache()
    if (reconciledCacheProgress > 0) {
        log.info("reconciled cache progress and totals against current TOCs for {} book(s)", reconciledCacheProgress)
    }
    val lanDiscovery = LanDiscoveryService(
        database = database,
        enabled = config.lanDiscoveryEnabled,
        port = config.lanDiscoveryPort,
        httpPort = config.port,
        multicastGroup = config.lanDiscoveryGroup,
        serverName = config.serverName,
    ) { message -> log.info(message) }
    // 缓存目录结构升级到 v3 的唯一入口（同一套 `app_setting.cache_layout` 版本判断）：
    // - v2 → v3：漫画根 `images` 改名成 `comic`，动作是**移动**（布局没变 ⇒ 用户零数据损失），
    //   顺带把封面文件名从 `covers/<key>` 改成 `covers/<书名 (书哈希).扩展名>`；
    // - 更旧（v1 散列布局）→ 沿用既有裁决"清掉重下"（与新语义不兼容）；
    // - **幂等**：第二次启动读到 cache_layout=v3 直接 no-op，不做任何磁盘扫描。
    // 无论哪个版本，都会确保「小说插图」根目录存在（空目录，本次不实现写入）。
    migrateCacheLayout(
        database = database,
        comicRoot = config.comicCacheDirectory,
        illustrationRoot = config.illustrationCacheDirectory,
        audioRoot = config.audioCacheDirectory,
        coverRoot = config.coverCacheDirectory,
        log = { message -> log.info(message) },
    )
    val auth = AuthService(database, config.secureCookies)
    val kindleSync = KindleSyncService(
        database,
        config.coverCacheDirectory.resolveSibling("kindle_sync"),
        serverId = lanDiscovery.serverId,
    )
    val kindlePush = KindlePushService(
        database = database,
        kindleSync = kindleSync,
        directory = config.coverCacheDirectory.resolveSibling("kindle_push"),
    ) { message -> log.info(message) }
    val subscriptions = SubscriptionService(database) { message -> log.info(message) }
    val browserRuntime = BrowserRuntime(database)
    val runner = RuleRunner(
        database = database,
        browserRuntime = browserRuntime,
        // 书源脚本的文件区（Android `externalCache` 的对应物）：缓存文件、压缩包解压都落在这里。
        sourceFileRoot = config.coverCacheDirectory.parent.resolve("source_cache"),
    )
    // 手动刷新书架目录的 Android `MainViewModel.upToc` 对应物。独立生命周期，
    // 关闭服务时与缓存/推送任务一起停止。
    val bookshelfRefresh = BookshelfRefreshService(
        database = database,
        runner = runner,
        log = { message -> log.info(message) },
    )
    val kindleUpdates = KindleUpdateScheduler(kindleSync, runner) { message -> log.info(message) }
    val kindleAutoPublish = KindleAutoPublishScheduler(
        service = kindleSync,
        database = database,
        enabled = config.kindleAutoPublishEnabled,
        debounceMs = config.kindleAutoPublishDebounceMs,
        afterPublish = { kindleUpdates.refreshDueNow() },
    ) { message -> log.info(message) }
    // 图片抓取的**唯一收口**（漫画与小说正文插图共用）：书源 header + 章节页 Referer + Cookie、
    // 全局限流、gzip 魔数解压、单图体积上限、SSRF 防护都在这里（见 MangaImageFetcher 的说明）。
    val imageFetcher = MangaImageFetcher(config, log = { message -> log.info(message) })
    // 小说正文插图的落盘缓存（`<data>/images/`）。离线缓存章节时顺手把插图抓下来。
    val illustrationCache = IllustrationCache(config.illustrationCacheDirectory, database) { message -> log.info(message) }
    val bookCache = BookCacheService(
        database,
        runner,
        illustrationCache = illustrationCache,
        illustrationFetcher = imageFetcher,
        autoCacheEnabled = config.automaticBookCacheEnabled,
    ) { message -> log.info(message) }
    // 封面缓存带库：文件名是 `书名 (书哈希).扩展名`，`file_path` 就是索引里那一列
    // （拿不到库时只能按 key 命名/定位，那是上传接口等"还不知道属于哪本书"的场景）。
    val coverCache = CoverCache(config.coverCacheDirectory, database = database)
    val bookExport = BookExportService(
        database = database,
        runner = runner,
        coverCache = coverCache,
        illustrationCache = illustrationCache,
        imageFetcher = imageFetcher,
        directory = config.coverCacheDirectory.resolveSibling("book_exports"),
        pushHandler = { input -> kindlePush.enqueue(input) },
        log = { message -> log.info(message) },
    )
    // WebDAV 存储区在多个地方用到（WebDAV 服务端 + 「从 WebDAV 导入书籍」+ 定时备份导出），
    // 因此在这里先建好，保证几边看到的是同一个根目录。
    val webDavStorage = WebDavStorage(config.webDavDirectory)
    val backupExportScheduler = BackupExportScheduler(
        database,
        webDavStorage,
        BackupExporter(database),
    ) { message -> log.info(message) }
    subscriptions.start()
    bookCache.start()
    kindleUpdates.start()
    kindleAutoPublish.start()
    backupExportScheduler.start()
    lanDiscovery.start()
    val kindleEpubMigrationJob = launch {
        delay(5_000)
        runCatching {
            withContext(Dispatchers.IO) { kindleSync.prepareMissingEpubs() }
        }.onSuccess { count ->
            if (count > 0) log.info("prepared whole-book EPUBs for {} published book(s)", count)
        }.onFailure { error ->
            log.warn("published EPUB migration failed: {}", error.message)
        }
    }
    val stopServices = {
        kindleEpubMigrationJob.cancel()
        lanDiscovery.close()
        subscriptions.stop(); bookCache.stop(); bookExport.stop()
        bookshelfRefresh.stop()
        kindleAutoPublish.stop(); kindleUpdates.stop(); backupExportScheduler.stop()
        browserRuntime.close()
        database.close()
    }
    environment.monitor.subscribe(ApplicationStopping) { stopServices() }
    environment.monitor.subscribe(ApplicationStopped) { stopServices() }

    install(ContentNegotiation) {
        json(Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true })
    }
    install(Sessions) {
        cookie<UserSession>(AuthService.COOKIE_NAME) {
            cookie.path = "/"
            cookie.httpOnly = true
            cookie.secure = config.secureCookies
            cookie.extensions["SameSite"] = "Strict"
        }
    }
    install(WebSockets)
    install(StatusPages) {
        exception<Throwable> { call, cause ->
            this@legadoApplication.log.error("Unhandled request failure", cause)
            call.respond(HttpStatusCode.InternalServerError, ApiError("internal_error", "服务器内部错误"))
        }
    }
    routing {
        get("/healthz") { call.respond(mapOf("status" to "ok")) }
        get("/api/v1/discovery") {
            call.response.header(HttpHeaders.CacheControl, "no-store")
            call.respond(lanDiscovery.announcement)
        }
        // 封面**常驻自愈**：后期封面文件丢了（磁盘清理/误删/换卷）自动补回来。
        // 与 `AudioCacheGc` / `ImageCacheGc` 同风格的低优先级后台 worker：
        // **延迟启动、分批投放、全局限流、绝不阻塞启动与任何用户请求**（见 AGENTS.md `[启动/缓存]`）。
        val coverSelfHeal = CoverSelfHeal(database, coverCache, runner, enabled = config.coverSelfHealEnabled) { message -> log.info(message) }
        if (config.coverSelfHealEnabled) {
            val coverSelfHealJob = launch {
                // 先等一会儿：启动期已经有续做/预取在抢 IO 与书源并发，保洁不该挤进去。
                delay(ServerConfig.COVER_SELF_HEAL_START_DELAY_MS)
                while (isActive) {
                    // runOnce 内部把一切异常都收成一行日志，这里不会因单轮失败退出循环。
                    coverSelfHeal.runOnce()
                    delay(ServerConfig.COVER_SELF_HEAL_INTERVAL_MS)
                }
            }
            environment.monitor.subscribe(ApplicationStopping) { coverSelfHealJob.cancel() }
            environment.monitor.subscribe(ApplicationStopped) { coverSelfHealJob.cancel() }
        }
        // 漫画 P1：L1 字节缓存 + 抓取收口（配额默认 10 GiB，见  的滑窗 GC 裁决）
        val imageCache = ImageCache(config.comicCacheDirectory, database, config.imageCacheQuotaBytes) { message -> log.info(message) }
        val mangaImageFetcher = imageFetcher
        // 漫画 P2：滑窗 GC + 后台预取。
        // GC 的"每次落盘后检查"落在预取循环与章节收口处（每张图都查一次是没必要的写放大）。
        val imageGc = ImageCacheGc(database, imageCache, config.imageCacheQuotaBytes, config.mangaGcEnabled) { message -> log.info(message) }
        val mangaPrefetch = MangaPrefetchService(
            database = database,
            runner = runner,
            imageCache = imageCache,
            fetcher = mangaImageFetcher,
            scope = this@legadoApplication,
            gc = imageGc,
            enabled = config.mangaPrefetchEnabled,
        ) { message -> log.info(message) }
        if (config.mangaGcEnabled) {
            // 定时巡检：不抓图的时候也要能收敛（例如用户手动改小了 LEGADO_MANGA_CACHE_MAX_GB）
            val gcJob = launch {
                while (isActive) {
                    delay(ServerConfig.IMAGE_GC_INTERVAL_MS)
                    imageGc.maybeRun()
                }
            }
            environment.monitor.subscribe(ApplicationStopping) { gcJob.cancel() }
            environment.monitor.subscribe(ApplicationStopped) { gcJob.cancel() }
        }
        // 有声书 P1/P2：L1 字节缓存 + 抓取收口 + 滑窗 GC + 后台批量缓存（方案 G2）
        val audioCache = AudioCache(config.audioCacheDirectory, database, config.audioCacheQuotaBytes) { message -> log.info(message) }
        val audioFetcher = AudioFetcher(config, log = { message -> log.info(message) })
        val audioGc = AudioCacheGc(database, audioCache, config.audioCacheQuotaBytes, config.audioGcEnabled) { message -> log.info(message) }
        val audioPrefetch = AudioPrefetchService(
            database = database,
            runner = runner,
            audioCache = audioCache,
            fetcher = audioFetcher,
            scope = this@legadoApplication,
            gc = audioGc,
            enabled = config.audioPrefetchEnabled,
        ) { message -> log.info(message) }
        if (config.audioGcEnabled) {
            // 定时巡检：不抓音频的时候也要能收敛（例如用户手动改小了 LEGADO_AUDIO_CACHE_MAX_GB）
            val audioGcJob = launch {
                while (isActive) {
                    delay(ServerConfig.AUDIO_GC_INTERVAL_MS)
                    audioGc.maybeRun()
                }
            }
            environment.monitor.subscribe(ApplicationStopping) { audioGcJob.cancel() }
            environment.monitor.subscribe(ApplicationStopped) { audioGcJob.cancel() }
        }
        authRoutes(auth)
        kindleSyncRoutes(auth, kindleSync, kindlePush, kindleAutoPublish)
        apiRoutes(
            database, auth, runner, coverCache, subscriptions, bookCache,
            config.localBooksDirectory,
            // 进度文件落在 WebDAV 根目录下的 bookProgress（与手机端备份结构一致）
            BookProgressSync(config.webDavDirectory, database),
            webDavStorage,
            imageCache,
            mangaImageFetcher,
            mangaPrefetch,
            audioCache,
            audioFetcher,
            audioPrefetch,
            illustrationCache,
            bookExport,
            // 手动触发一轮封面自愈的入口（`POST /api/bookshelf/self-heal-covers`，便于验收）。
            // 开关关掉时传 null ⇒ 该路由回 503「未启用」，与"不动任何东西"的回滚语义一致。
            coverSelfHeal.takeIf { config.coverSelfHealEnabled },
            kindleSync,
            browserRuntime,
            bookshelfRefresh,
        )
        webDavRoutes(auth, webDavStorage, database, coverCache, runner)
        staticWeb()
    }
}
