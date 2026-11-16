package io.legado.server

import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.origin
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.sessions.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val kindleWireJson = Json { encodeDefaults = true; explicitNulls = false }

private suspend inline fun <reified T> ApplicationCall.respondKindle(value: T, status: HttpStatusCode = HttpStatusCode.OK) {
    respondText(kindleWireJson.encodeToString(value), ContentType.Application.Json, status)
}

private suspend fun ApplicationCall.kindleRequest(block: suspend () -> Unit) {
    try {
        block()
    } catch (error: CancellationException) {
        throw error
    } catch (error: KindleSyncException) {
        respondKindle(KindleErrorEnvelope(KindleErrorDetail(error.code, error.message ?: error.code, error.status >= 500)), HttpStatusCode.fromValue(error.status))
    } catch (error: BadRequestException) {
        respondKindle(KindleErrorEnvelope(KindleErrorDetail("invalid_request", "请求格式无效")), HttpStatusCode.BadRequest)
    } catch (error: SerializationException) {
        respondKindle(KindleErrorEnvelope(KindleErrorDetail("invalid_request", "请求格式无效")), HttpStatusCode.BadRequest)
    } catch (error: Throwable) {
        application.log.error("Kindle protocol request failed", error)
        respondKindle(KindleErrorEnvelope(KindleErrorDetail("internal_error", "服务器内部错误", true)), HttpStatusCode.InternalServerError)
    }
}

/** Device Bearer credentials are deliberately not accepted as administrator credentials. */
private fun ApplicationCall.requireKindleAdmin(auth: AuthService, write: Boolean = false) {
    if (request.headers[HttpHeaders.Authorization] != null) throw KindleSyncException(401, "admin_session_required", "请使用管理会话")
    val session = sessions.get<UserSession>()
    val csrf = session?.let(auth::csrf) ?: throw KindleSyncException(401, "admin_session_required", "请先登录管理界面")
    if (write && request.headers[AuthService.CSRF_HEADER] != csrf) throw KindleSyncException(403, "csrf_invalid", "请求验证失败")
}

private fun ApplicationCall.requireKindleDevice(service: KindleSyncService): String {
    val header = request.headers[HttpHeaders.Authorization]
    if (header == null || !header.startsWith("Bearer ", ignoreCase = true)) throw KindleSyncException(401, "device_unauthorized", "需要设备令牌")
    return service.authenticate(header.substring(7).trim())
}

/**
 * Reading-progress conflicts are readable and resolvable from both sides:
 * a paired Kindle may only see and resolve conflicts it created, while an
 * authenticated WebUI administrator may manage the complete set.
 */
private fun ApplicationCall.requireKindleReaderOrAdmin(
    auth: AuthService,
    service: KindleSyncService,
    write: Boolean = false,
): String? {
    if (request.headers[HttpHeaders.Authorization] != null) return requireKindleDevice(service)
    requireKindleAdmin(auth, write)
    return null
}

fun Route.kindleSyncRoutes(
    auth: AuthService,
    service: KindleSyncService,
    pushService: KindlePushService,
    autoPublish: KindleAutoPublishScheduler,
) {
    route("/api/v1") {
        post("/devices/pairing-codes") { call.kindleRequest {
            call.requireKindleAdmin(auth, write = true)
            call.respondKindle(service.createPairingCode(call.receive<KindleDeviceName>().deviceName))
        } }
        post("/devices/pair") { call.kindleRequest {
            call.respondKindle(service.pair(call.receive<KindlePairRequest>(), call.request.origin.remoteHost))
        } }
        get("/devices") { call.kindleRequest {
            call.requireKindleAdmin(auth)
            call.respondKindle(service.devices())
        } }
        delete("/devices/{device_id}") { call.kindleRequest {
            call.requireKindleAdmin(auth, write = true)
            val deviceId = call.parameters["device_id"]
                ?: throw KindleSyncException(400, "invalid_request", "缺少设备编号")
            service.revoke(deviceId)
            pushService.cancelPendingForDevice(deviceId)
            call.respond(HttpStatusCode.NoContent)
        } }
        get("/push/deliveries") { call.kindleRequest {
            call.requireKindleAdmin(auth)
            call.respondKindle(pushService.deliveries())
        } }
        get("/inbox") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            call.respondKindle(pushService.inbox(device, call.request.queryParameters["cursor"]))
        } }
        get("/inbox/files/{file_id}") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            val fileId = call.parameters["file_id"]
                ?: throw KindleSyncException(400, "invalid_request", "缺少推送文件编号")
            val (descriptor, path) = pushService.file(device, fileId)
            call.respondFileRange(
                file = path,
                contentType = ContentType.parse(descriptor.contentType),
                etag = descriptor.sha256,
                cacheControl = "private, max-age=31536000, immutable",
                strictRange = true,
                honorIfRange = true,
            )
        } }
        post("/inbox/ack") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            call.respondKindle(pushService.ack(device, call.receive<KindleInboxAckRequest>()))
        } }
        get("/draft") { call.kindleRequest {
            call.requireKindleAdmin(auth)
            call.respondKindle(service.draft())
        } }
        post("/publish") { call.kindleRequest {
            call.requireKindleAdmin(auth, write = true)
            call.respondKindle(service.publish(call.receive<KindlePublishRequest>()))
        } }
        get("/publish/auto-status") { call.kindleRequest {
            call.requireKindleAdmin(auth)
            call.respondKindle(autoPublish.status())
        } }
        post("/publish/auto-retry") { call.kindleRequest {
            call.requireKindleAdmin(auth, write = true)
            call.respondKindle(autoPublish.retryNow())
        } }
        get("/sync") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            call.respondKindle(service.sync(device, call.request.queryParameters["cursor"]))
        } }
        get("/bundles/{bundle_id}") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            val bundleId = call.parameters["bundle_id"] ?: throw KindleSyncException(400, "invalid_request", "缺少同步包编号")
            val (descriptor, path) = service.bundle(device, bundleId)
            call.respondFileRange(path, ContentType.Application.Zip, descriptor.sha256, "private, max-age=31536000, immutable",
                strictRange = true, honorIfRange = true)
        } }
        get("/books/{book_id}/epub") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            val bookId = call.parameters["book_id"] ?: throw KindleSyncException(400, "invalid_request", "缺少书籍编号")
            val (descriptor, path) = service.publishedEpub(device, bookId)
            call.respondFileRange(
                path,
                ContentType.parse(descriptor.mediaType),
                descriptor.sha256,
                "private, max-age=31536000, immutable",
                strictRange = true,
                honorIfRange = true,
            )
        } }
        post("/sync/ack") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            call.respondKindle(service.ack(device, call.receive<KindleAckRequest>()))
        } }
        post("/progress") { call.kindleRequest {
            val device = call.requireKindleDevice(service)
            call.respondKindle(service.progress(device, call.receive<KindleProgressRequest>()))
        } }
        get("/updates") { call.kindleRequest {
            call.requireKindleAdmin(auth)
            call.respondKindle(service.updateTasks())
        } }
        post("/updates/pause") { call.kindleRequest {
            call.requireKindleAdmin(auth, write = true)
            service.pausePublicationUpdate(call.receive<KindleUpdateTarget>().bookId)
            call.respond(HttpStatusCode.NoContent)
        } }
        post("/updates/retry") { call.kindleRequest {
            call.requireKindleAdmin(auth, write = true)
            service.retryPublicationUpdate(call.receive<KindleUpdateTarget>().bookId)
            call.respond(HttpStatusCode.NoContent)
        } }
        get("/books/{book_id}/export") { call.kindleRequest {
            call.requireKindleAdmin(auth)
            val bookId = call.parameters["book_id"] ?: throw KindleSyncException(400, "invalid_request", "缺少书籍编号")
            val exported = service.exportEpub(bookId)
            val path = service.exportPath(bookId, exported.filename)
            call.response.header(HttpHeaders.ContentType, "application/epub+zip")
            call.response.header(HttpHeaders.ContentDisposition, "attachment; filename=\"${exported.filename}\"")
            call.response.header(HttpHeaders.ETag, "\"${exported.sha256}\"")
            call.respondFile(path.toFile())
        } }
        get("/progress/conflicts") { call.kindleRequest {
            val deviceId = call.requireKindleReaderOrAdmin(auth, service)
            call.respondKindle(service.conflicts(deviceId))
        } }
        post("/progress/conflicts/{conflict_id}/resolve") { call.kindleRequest {
            val deviceId = call.requireKindleReaderOrAdmin(auth, service, write = true)
            val conflictId = call.parameters["conflict_id"]
                ?: throw KindleSyncException(400, "invalid_request", "缺少冲突编号")
            call.respondKindle(service.resolveConflict(deviceId, conflictId, call.receive<KindleConflictResolutionRequest>()))
        } }
    }
}
