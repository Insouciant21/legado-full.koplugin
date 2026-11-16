package io.legado.server

import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.sql.Connection
import java.time.Instant
import java.time.temporal.ChronoUnit

data class KindlePushArtifactInput(
    val fileId: String,
    val fileName: String,
    val contentType: String,
    val sha256: String,
    val sizeBytes: Long,
    val path: Path,
)

data class KindlePushExportInput(
    val jobId: String,
    val sourceId: String,
    val bookUrl: String,
    val title: String,
    val author: String?,
    val format: String,
    val targetDeviceIds: List<String>,
    val files: List<KindlePushArtifactInput>,
)

data class KindlePushEnqueueResult(
    val deliveryId: String,
    val state: String,
    val message: String,
)

@Serializable private data class KindleStoredPushFile(
    val fileId: String,
    val fileName: String,
    val contentType: String,
    val sha256: String,
    val sizeBytes: Long,
)

@Serializable private data class KindleStoredPushDelivery(
    val deliveryId: String,
    val bookId: String,
    val sourceId: String,
    val bookUrl: String,
    val title: String,
    val author: String?,
    val format: String,
    val files: List<KindleStoredPushFile>,
    val deviceIds: List<String>,
    val createdAt: String,
    var updatedAt: String,
)

@Serializable private data class KindleStoredPushTarget(
    val deliveryId: String,
    val deviceId: String,
    val sequence: Long,
    val state: String = "pending",
    val attempts: Int = 0,
    val lastError: String? = null,
    val deliveredAt: String? = null,
)

@Serializable private data class KindleStoredPushCursor(
    val ackedSequence: Long = 0,
    val updatedAt: String,
)

@Serializable private data class KindleStoredPushSequence(val value: Long)

/**
 * Durable per-device EPUB inbox.
 *
 * Export artifacts are copied into this service's content-addressed directory before a delivery
 * becomes visible. Device tokens and cursor semantics reuse Kindle protocol v1, while the older
 * published-bookshelf sync remains a separate compatibility path.
 */
class KindlePushService(
    private val database: Database,
    private val kindleSync: KindleSyncService,
    directory: Path,
    private val now: () -> Instant = Instant::now,
    private val log: (String) -> Unit = {},
) {
    private val json = Json { encodeDefaults = true; explicitNulls = true; ignoreUnknownKeys = true }
    private val fileDirectory = directory.resolve("files")

    init {
        Files.createDirectories(fileDirectory)
        database.kindleTransaction { db ->
            db.createStatement().use {
                it.executeUpdate(
                    "create table if not exists kindle_sync_entry (" +
                        "kind text not null, entry_key text not null, payload text not null, " +
                        "primary key(kind,entry_key))",
                )
            }
        }
        // Deployments created before cancellable target queues may contain pending work for
        // devices that were already revoked.
        kindleSync.devices().devices
            .filter { it.revokedAt != null }
            .forEach { cancelPendingForDevice(it.deviceId) }
    }

    private inline fun <reified T> Connection.readPush(kind: String, key: String): T? =
        prepareStatement("select payload from kindle_sync_entry where kind=? and entry_key=?").use { statement ->
            statement.setString(1, kind)
            statement.setString(2, key)
            statement.executeQuery().use { rows ->
                if (rows.next()) json.decodeFromString<T>(rows.getString(1)) else null
            }
        }

    private inline fun <reified T> Connection.allPush(kind: String): List<T> =
        prepareStatement("select payload from kindle_sync_entry where kind=? order by entry_key").use { statement ->
            statement.setString(1, kind)
            statement.executeQuery().use { rows ->
                buildList {
                    while (rows.next()) add(json.decodeFromString<T>(rows.getString(1)))
                }
            }
        }

    private inline fun <reified T> Connection.putPush(kind: String, key: String, value: T) {
        prepareStatement(
            "insert into kindle_sync_entry(kind,entry_key,payload) values(?,?,?) " +
                "on conflict(kind,entry_key) do update set payload=excluded.payload",
        ).use { statement ->
            statement.setString(1, kind)
            statement.setString(2, key)
            statement.setString(3, json.encodeToString(value))
            statement.executeUpdate()
        }
    }

    private fun fail(status: Int, code: String, message: String): Nothing =
        throw KindleSyncException(status, code, message)

    private fun sha(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun sha(path: Path): String {
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

    private fun timestamp(): String = now().truncatedTo(ChronoUnit.SECONDS).toString()

    private fun targetKey(deliveryId: String, deviceId: String) = "$deliveryId\u0000$deviceId"

    private fun prepareFile(artifact: KindlePushArtifactInput): KindleStoredPushFile {
        if (artifact.fileName.isBlank() || artifact.fileName.length > 200 ||
            artifact.fileName.contains('/') || artifact.fileName.contains('\\') ||
            artifact.contentType != "application/epub+zip" ||
            artifact.sizeBytes <= 0
        ) {
            fail(400, "invalid_kindle_file", "Kindle 推送仅支持有效 EPUB 文件")
        }
        if (!Files.isRegularFile(artifact.path) || Files.size(artifact.path) != artifact.sizeBytes) {
            fail(503, "kindle_file_unavailable", "导出文件暂不可用")
        }
        val actual = sha(artifact.path)
        if (actual != artifact.sha256) fail(503, "kindle_file_checksum_mismatch", "导出文件校验失败")
        val target = fileDirectory.resolve("$actual.epub")
        if (!Files.isRegularFile(target) || Files.size(target) != artifact.sizeBytes || sha(target) != actual) {
            val temp = Files.createTempFile(fileDirectory, ".push-", ".tmp")
            try {
                Files.copy(artifact.path, temp, StandardCopyOption.REPLACE_EXISTING)
                if (sha(temp) != actual) fail(503, "kindle_file_checksum_mismatch", "导出文件复制校验失败")
                Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } finally {
                Files.deleteIfExists(temp)
            }
        }
        return KindleStoredPushFile(
            fileId = artifact.fileId,
            fileName = artifact.fileName,
            contentType = artifact.contentType,
            sha256 = actual,
            sizeBytes = artifact.sizeBytes,
        )
    }

    fun enqueue(input: KindlePushExportInput): KindlePushEnqueueResult {
        if (input.format != "epub") fail(400, "kindle_requires_epub", "Kindle 推送仅支持 EPUB")
        if (input.files.isEmpty()) fail(400, "empty_kindle_delivery", "没有可推送的 EPUB 文件")
        val requested = input.targetDeviceIds.map(String::trim).filter(String::isNotEmpty).distinct()
        val files = input.files.map(::prepareFile)
        val deliveryKey = sha(
            input.sourceId + "\u0000" + input.bookUrl + "\u0000" +
                files.joinToString("\u0001") { "${it.fileName}\u0000${it.sha256}\u0000${it.sizeBytes}" },
        )
        val deliveryId = "push_${deliveryKey.take(32)}"
        val bookId = "pushbook_${sha(input.sourceId + "\u0000" + input.bookUrl).take(32)}"
        return database.kindleTransaction { db ->
            val active = kindleSync.activeDeviceIds(db)
            if (active.isEmpty()) fail(409, "kindle_not_paired", "请先配对 Kindle 设备")
            val targets = if (requested.isEmpty()) active.toList() else requested
            if (targets.any { it !in active }) {
                fail(400, "kindle_device_invalid", "推送目标包含无效或已撤销的设备")
            }
            val current = timestamp()
            var sequence = db.readPush<KindleStoredPushSequence>("push-meta", "sequence")?.value ?: 0L
            val existing = db.readPush<KindleStoredPushDelivery>("push-delivery", deliveryId)
            val allTargetIds = LinkedHashSet<String>()
            allTargetIds.addAll(existing?.deviceIds.orEmpty())
            allTargetIds.addAll(targets)
            val storedFiles = files.mapIndexed { index, file ->
                file.copy(fileId = "pushfile_${sha("$deliveryId\u0000${file.sha256}\u0000$index").take(32)}")
            }
            val delivery = KindleStoredPushDelivery(
                deliveryId = deliveryId,
                bookId = bookId,
                sourceId = input.sourceId,
                bookUrl = input.bookUrl,
                title = input.title,
                author = input.author,
                format = "epub",
                files = storedFiles,
                deviceIds = allTargetIds.toList().sorted(),
                createdAt = existing?.createdAt ?: current,
                updatedAt = current,
            )
            for (deviceId in targets) {
                val key = targetKey(deliveryId, deviceId)
                if (db.readPush<KindleStoredPushTarget>("push-target", key) == null) {
                    sequence += 1
                    db.putPush("push-target", key, KindleStoredPushTarget(deliveryId, deviceId, sequence))
                }
            }
            db.putPush("push-meta", "sequence", KindleStoredPushSequence(sequence))
            db.putPush("push-delivery", deliveryId, delivery)
            val summary = summary(db, delivery)
            log(
                "kindle push queued: job=${input.jobId}, delivery=$deliveryId, " +
                    "files=${input.files.size}, devices=${targets.size}",
            )
            KindlePushEnqueueResult(
                deliveryId = deliveryId,
                state = summary.state,
                message = "已加入 Kindle 投递，等待设备联网领取",
            )
        }
    }

    private fun deliveryTargets(db: Connection, deliveryId: String): List<KindleStoredPushTarget> =
        db.allPush<KindleStoredPushTarget>("push-target").filter { it.deliveryId == deliveryId }

    private fun summary(db: Connection, delivery: KindleStoredPushDelivery): KindlePushDeliverySummary {
        val targets = deliveryTargets(db, delivery.deliveryId)
        val delivered = targets.count { it.state == "delivered" }
        val pending = targets.count { it.state == "pending" }
        val canceled = targets.count { it.state == "canceled" }
        val state = when {
            pending > 0 && delivered > 0 -> "partial"
            pending > 0 -> "queued"
            delivered > 0 -> "delivered"
            canceled > 0 || targets.isEmpty() -> "canceled"
            else -> "queued"
        }
        return KindlePushDeliverySummary(
            deliveryId = delivery.deliveryId,
            bookName = delivery.title,
            format = delivery.format,
            state = state,
            fileCount = delivery.files.size,
            totalBytes = delivery.files.sumOf { it.sizeBytes },
            targetCount = targets.size,
            deliveredCount = delivered,
            pendingCount = pending,
            canceledCount = canceled,
            createdAt = delivery.createdAt,
            updatedAt = delivery.updatedAt,
        )
    }

    fun deliveries(): KindlePushDeliveriesResponse = database.kindleTransaction { db ->
        KindlePushDeliveriesResponse(
            db.allPush<KindleStoredPushDelivery>("push-delivery")
                .map { summary(db, it) }
                .sortedByDescending { it.createdAt },
        )
    }

    private fun parseCursor(value: String?, fallback: Long): Long {
        val raw = value?.trim().orEmpty()
        if (raw.isEmpty()) return fallback
        if (!raw.matches(Regex("[0-9]{1,18}"))) fail(400, "invalid_inbox_cursor", "收件箱游标无效")
        return raw.toLongOrNull() ?: fail(400, "invalid_inbox_cursor", "收件箱游标无效")
    }

    fun inbox(deviceId: String, requestedCursor: String?): KindleInboxResponse = database.kindleTransaction { db ->
        val storedCursor = db.readPush<KindleStoredPushCursor>("push-cursor", deviceId)?.ackedSequence ?: 0L
        val cursor = parseCursor(requestedCursor, storedCursor)
        if (cursor > storedCursor) fail(409, "inbox_cursor_mismatch", "设备尚未确认此前的收件箱批次")
        val allTargets = db.allPush<KindleStoredPushTarget>("push-target")
            .filter { it.deviceId == deviceId }
            .sortedBy { it.sequence }
        val nextCursor = maxOf(storedCursor, allTargets.maxOfOrNull { it.sequence } ?: 0L)
        val pending = allTargets.filter {
            it.state == "pending" || (it.state == "delivered" && it.sequence > storedCursor)
        }
        val deliveries = pending.mapNotNull { target ->
            val delivery = db.readPush<KindleStoredPushDelivery>("push-delivery", target.deliveryId)
                ?: fail(500, "kindle_push_inconsistent", "Kindle 投递索引不完整")
            KindleInboxDelivery(
                deliveryId = delivery.deliveryId,
                bookId = delivery.bookId,
                title = delivery.title,
                author = delivery.author,
                format = delivery.format,
                createdAt = delivery.createdAt,
                files = delivery.files.map { file ->
                    KindleInboxFile(
                        fileId = file.fileId,
                        fileName = file.fileName,
                        contentType = file.contentType,
                        sha256 = file.sha256,
                        sizeBytes = file.sizeBytes,
                        url = "/api/v1/inbox/files/${file.fileId}",
                    )
                },
            )
        }
        KindleInboxResponse(
            fromCursor = storedCursor.toString(),
            nextCursor = nextCursor.toString(),
            reset = false,
            deliveries = deliveries,
        )
    }

    fun file(deviceId: String, fileId: String): Pair<KindleInboxFile, Path> = database.kindleTransaction { db ->
        val deliveries = db.allPush<KindleStoredPushDelivery>("push-delivery")
        val targetIds = db.allPush<KindleStoredPushTarget>("push-target")
            .filter { it.deviceId == deviceId && it.state != "canceled" }
            .map { it.deliveryId }
            .toSet()
        val delivery = deliveries.firstOrNull { it.deliveryId in targetIds && it.files.any { file -> file.fileId == fileId } }
            ?: fail(404, "kindle_inbox_file_not_found", "推送文件不存在")
        val file = delivery.files.first { it.fileId == fileId }
        val path = fileDirectory.resolve("${file.sha256}.epub")
        if (!Files.isRegularFile(path) || Files.size(path) != file.sizeBytes) {
            fail(503, "kindle_inbox_file_unavailable", "推送文件暂不可用")
        }
        KindleInboxFile(
            fileId = file.fileId,
            fileName = file.fileName,
            contentType = file.contentType,
            sha256 = file.sha256,
            sizeBytes = file.sizeBytes,
            url = "/api/v1/inbox/files/${file.fileId}",
        ) to path
    }

    fun ack(deviceId: String, request: KindleInboxAckRequest): KindleInboxAckResponse =
        database.kindleTransaction { db ->
            val storedCursor = db.readPush<KindleStoredPushCursor>("push-cursor", deviceId)?.ackedSequence ?: 0L
            var requested = parseCursor(request.cursor, storedCursor)
            if (requested < storedCursor) requested = storedCursor
            val allTargets = db.allPush<KindleStoredPushTarget>("push-target").filter { it.deviceId == deviceId }
            val maxSequence = allTargets.maxOfOrNull { it.sequence } ?: 0L
            if (requested > maxSequence) fail(409, "inbox_ack_mismatch", "收件箱确认游标超出设备投递范围")
            if (request.results.map { it.deliveryId }.toSet().size != request.results.size) {
                fail(400, "invalid_inbox_ack", "收件箱确认包含重复投递")
            }
            val current = timestamp()
            request.results.forEach { result ->
                if (result.status != "applied" && result.status != "failed") {
                    fail(400, "invalid_inbox_ack", "收件箱确认状态无效")
                }
                val key = targetKey(result.deliveryId, deviceId)
                val target = db.readPush<KindleStoredPushTarget>("push-target", key)
                    ?: fail(409, "inbox_ack_mismatch", "收件箱确认与设备投递不匹配")
                if (target.sequence > requested) {
                    fail(409, "inbox_ack_mismatch", "收件箱确认包含尚未领取的投递")
                }
                val updated = if (result.status == "applied") {
                    if (target.state == "delivered") {
                        // Replaying an acknowledgement after a lost response must remain idempotent.
                        target
                    } else {
                        target.copy(
                            state = "delivered",
                            attempts = target.attempts + 1,
                            lastError = null,
                            deliveredAt = current,
                        )
                    }
                } else {
                    if (target.state == "delivered") {
                        fail(409, "inbox_ack_conflict", "已完成的投递不能被重新标记为失败")
                    }
                    if (target.state == "canceled") {
                        target
                    } else {
                        target.copy(
                            state = "pending",
                            attempts = target.attempts + 1,
                            lastError = result.error?.take(500) ?: "设备安装失败",
                        )
                    }
                }
                if (updated != target) {
                    db.putPush("push-target", key, updated)
                    db.readPush<KindleStoredPushDelivery>("push-delivery", target.deliveryId)?.let { delivery ->
                        db.putPush("push-delivery", delivery.deliveryId, delivery.copy(updatedAt = current))
                    }
                }
            }
            val ackedCursor = maxOf(storedCursor, requested)
            if (ackedCursor > storedCursor) {
                db.putPush(
                    "push-cursor",
                    deviceId,
                    KindleStoredPushCursor(ackedCursor, current),
                )
            }
            KindleInboxAckResponse(cursor = ackedCursor.toString())
        }

    fun cancelPendingForDevice(deviceId: String): Int = database.kindleTransaction { db ->
        val current = timestamp()
        val pending = db.allPush<KindleStoredPushTarget>("push-target")
            .filter { it.deviceId == deviceId && it.state == "pending" }
        pending.forEach { target ->
            db.putPush(
                "push-target",
                targetKey(target.deliveryId, deviceId),
                target.copy(
                    state = "canceled",
                    lastError = "设备已撤销",
                ),
            )
            db.readPush<KindleStoredPushDelivery>("push-delivery", target.deliveryId)?.let { delivery ->
                db.putPush("push-delivery", delivery.deliveryId, delivery.copy(updatedAt = current))
            }
        }
        if (pending.isNotEmpty()) {
            log("kindle push canceled pending targets: device=$deviceId, count=${pending.size}")
        }
        pending.size
    }
}
