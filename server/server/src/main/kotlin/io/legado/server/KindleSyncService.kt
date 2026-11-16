package io.legado.server

import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.slf4j.LoggerFactory
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.security.SecureRandom
import java.sql.Connection
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.Base64
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class KindleSyncException(val status: Int, val code: String, message: String) : RuntimeException(message)

@Serializable private data class KindleStoredDevice(
    val deviceId: String, val deviceName: String, val createdAt: String,
    val lastSeenAt: String? = null, val ackedCursor: String? = null,
    val pendingSyncId: String? = null, val revokedAt: String? = null,
    val ackedLibraryVersion: String? = null, val ackedBatchId: String? = null,
)
@Serializable private data class KindleStoredCode(val deviceName: String, val expiresAt: Long)
@Serializable private data class KindlePairAttempts(val windowStart: Long, val count: Int)
@Serializable private data class KindleDraftEntry(
    val bookId: String, val title: String, val author: String?, val sourceId: String,
    val bookUrl: String, val tocUrl: String, val sourceJson: String?,
    /**
     * Many books share one source. Store its normalized hash with the binding so
     * scheduled comparisons do not parse the same large payload repeatedly.
     * Rows written by older builds omit this field and use the compatibility path.
     */
    val sourceFingerprint: String? = null,
)
@Serializable private data class KindleStoredBook(
    val binding: KindleDraftEntry, val book: KindleBook, val chapterUrls: Map<String, String>,
    val frozenToc: List<Chapter> = emptyList(),
)
@Serializable private data class KindlePublishedSummary(
    val bookId: String,
    val title: String,
    val sourceId: String,
    val bookUrl: String,
    val bindingVersion: String = "",
    val bindingFingerprint: String,
    val managementFingerprint: String,
)
@Serializable private data class KindleStoredSyncBook(
    val sourceId: String,
    val bookUrl: String,
    val book: KindleBook,
)
@Serializable private data class KindleStoredChapterUrls(val urls: Map<String, String>)
@Serializable private data class KindleStoredPublicationRequest(val fingerprint: String, val response: KindlePublication)
@Serializable private data class KindleLibrarySnapshot(val publicationId: String?, val books: List<KindleBook>)
@Serializable private data class KindleStoredBatch(
    val deviceId: String, val response: KindleSyncResponse,
    val snapshot: KindleLibrarySnapshot, val acked: Boolean = false,
    val libraryVersion: String? = null,
)
@Serializable private data class KindleStoredBundle(val deviceId: String, val syncId: String, val descriptor: KindleBundleDescriptor)
@Serializable private data class KindleStoredEvent(val fingerprint: String, val result: KindleProgressResult)
@Serializable private data class KindleCanonicalProgress(
    val position: KindleProgressPosition, val bindingVersion: String, val nativeUpdatedAt: Long? = null,
)
@Serializable private data class KindleStoredUpdateTask(
    val bookId: String, val state: String, val lastAttemptAt: Long,
    val nextDueAt: Long? = null, val lastError: String? = null,
)

internal data class KindleAutoPublishTarget(
    val bookId: String,
    val title: String,
    val sourceId: String,
    val bookUrl: String,
    val local: Boolean,
    val operation: String,
)
internal data class KindleAutoPublishPlan(
    val draft: KindleDraftResponse,
    val targets: List<KindleAutoPublishTarget>,
)

/** Durable protocol state shares the application's SQLite transaction and write lock. */
class KindleSyncService(
    private val database: Database,
    private val directory: Path,
    private val serverId: String,
    private val now: () -> Instant = Instant::now,
) {
    private val log = LoggerFactory.getLogger(KindleSyncService::class.java)
    private val json = Json { encodeDefaults = true; explicitNulls = true; ignoreUnknownKeys = true }
    private val random = SecureRandom()
    private val contentDirectory = directory.resolve("content")
    private val bundleDirectory = directory.resolve("bundles")
    private val exportDirectory = directory.resolve("exports")

    init {
        Files.createDirectories(contentDirectory)
        Files.createDirectories(bundleDirectory)
        Files.createDirectories(exportDirectory)
        val quarantinedBooks = database.kindleTransaction { db ->
            db.createStatement().use {
                it.executeUpdate("create table if not exists kindle_sync_entry (kind text not null, entry_key text not null, payload text not null, primary key(kind,entry_key))")
            }
            migrateBatchStorage(db)
            ensureLibraryVersion(db)
            pruneOrphanedBatches(db)
            val validIds = hashSetOf<String>()
            var quarantinePublication: KindlePublication? = null
            var quarantinedCount = 0

            fun quarantine(bookId: String) {
                val publication = quarantinePublication
                    ?: KindlePublication(id("pub_"), id("draft_recovery_"), now().toString())
                        .also { quarantinePublication = it }
                quarantinedCount += 1
                db.remove("published-book", bookId)
                db.remove("published-summary", bookId)
                db.remove("sync-book", bookId)
                db.remove("chapter-urls", bookId)
                db.remove("update-task", bookId)
                db.put(
                    "deleted-book",
                    bookId,
                    KindleDeletedBook(bookId, publication.publicationId, publication.publishedAt),
                )
            }

            fun indexStored(stored: KindleStoredBook) {
                if (db.read<KindleStoredUpdateTask>("update-task", stored.book.bookId) == null) {
                    db.put(
                        "update-task",
                        stored.book.bookId,
                        newUpdateTask(
                            stored.book.bookId,
                            if (isLocalBinding(stored.binding.sourceId, stored.binding.bookUrl)) null
                            else scheduledNextDueAt(),
                        ),
                    )
                }
                db.put(
                    "published-summary",
                    stored.book.bookId,
                    publishedSummary(stored.binding, stored.book.bindingVersion),
                )
                db.put("sync-book", stored.book.bookId, stored.toSyncBook())
                db.put("chapter-urls", stored.book.bookId, KindleStoredChapterUrls(stored.chapterUrls))
            }

            // A healthy index lets most restarts avoid decoding the large full
            // publication payloads entirely. Missing or stale derived rows are
            // repaired from one complete book at a time.
            for (bookId in db.keys("published-book")) {
                val indexed = db.read<KindleStoredSyncBook>("sync-book", bookId)
                val summary = db.read<KindlePublishedSummary>("published-summary", bookId)
                val indexedComplete = indexed != null &&
                    indexed.book.chapters.isNotEmpty() &&
                    indexed.book.chapters.all { it.status == "ready" }
                if (indexedComplete && summary?.bindingVersion == indexed.book.bindingVersion) {
                    validIds.add(bookId)
                    if (db.read<KindleStoredUpdateTask>("update-task", bookId) == null) {
                        db.put(
                            "update-task",
                            bookId,
                            newUpdateTask(
                                bookId,
                                if (isLocalBinding(indexed.sourceId, indexed.bookUrl)) null
                                else scheduledNextDueAt(),
                            ),
                        )
                    }
                    if (db.read<KindleStoredChapterUrls>("chapter-urls", bookId) == null) {
                        val stored = db.read<KindleStoredBook>("published-book", bookId)
                        if (stored == null) quarantine(bookId)
                        else db.put("chapter-urls", bookId, KindleStoredChapterUrls(stored.chapterUrls))
                    }
                    continue
                }
                val stored = db.read<KindleStoredBook>("published-book", bookId)
                if (stored == null ||
                    stored.book.chapters.isEmpty() ||
                    stored.book.chapters.any { it.status != "ready" }
                ) {
                    quarantine(bookId)
                } else {
                    validIds.add(bookId)
                    indexStored(stored)
                }
            }
            quarantinePublication?.let { db.put("meta", "publication", it) }
            db.keys("published-summary").filter { it !in validIds }
                .forEach { db.remove("published-summary", it) }
            db.keys("sync-book").filter { it !in validIds }
                .forEach { db.remove("sync-book", it) }
            db.keys("chapter-urls").filter { it !in validIds }
                .forEach { db.remove("chapter-urls", it) }
            db.keys("update-task").filter { it !in validIds }
                .forEach { db.remove("update-task", it) }
            quarantinedCount
        }
        if (quarantinedBooks > 0) {
            database.kindleTransaction { db ->
                bumpLibraryVersion(db)
            }
            log.warn("removed {} incomplete book(s) from the published Kindle shelf", quarantinedBooks)
        }
    }

    private inline fun <reified T> Connection.read(kind: String, key: String): T? =
        prepareStatement("select payload from kindle_sync_entry where kind=? and entry_key=?").use { statement ->
            statement.setString(1, kind); statement.setString(2, key)
            statement.executeQuery().use { rows -> if (rows.next()) json.decodeFromString<T>(rows.getString(1)) else null }
        }

    private inline fun <reified T> Connection.all(kind: String): List<T> =
        prepareStatement("select payload from kindle_sync_entry where kind=? order by entry_key").use { statement ->
            statement.setString(1, kind)
            statement.executeQuery().use { rows -> buildList { while (rows.next()) add(json.decodeFromString<T>(rows.getString(1))) } }
        }

    private inline fun <reified T> Connection.allEntries(kind: String): Map<String, T> =
        prepareStatement("select entry_key,payload from kindle_sync_entry where kind=? order by entry_key").use { statement ->
            statement.setString(1, kind)
            statement.executeQuery().use { rows ->
                buildMap {
                    while (rows.next()) put(rows.getString(1), json.decodeFromString<T>(rows.getString(2)))
                }
            }
        }

    private fun Connection.keys(kind: String): List<String> =
        prepareStatement("select entry_key from kindle_sync_entry where kind=? order by entry_key").use { statement ->
            statement.setString(1, kind)
            statement.executeQuery().use { rows -> buildList { while (rows.next()) add(rows.getString(1)) } }
        }

    private inline fun <reified T> Connection.put(kind: String, key: String, value: T) {
        prepareStatement("insert into kindle_sync_entry(kind,entry_key,payload) values(?,?,?) on conflict(kind,entry_key) do update set payload=excluded.payload").use {
            it.setString(1, kind); it.setString(2, key); it.setString(3, json.encodeToString(value)); it.executeUpdate()
        }
    }

    private fun Connection.remove(kind: String, key: String) {
        prepareStatement("delete from kindle_sync_entry where kind=? and entry_key=?").use {
            it.setString(1, kind); it.setString(2, key); it.executeUpdate()
        }
    }

    private fun id(prefix: String): String = prefix + UUID.randomUUID().toString().replace("-", "")
    private fun currentLibraryVersion(db: Connection): String =
        db.read<String>("meta", LIBRARY_VERSION_KEY) ?: id("library_").also {
            db.put("meta", LIBRARY_VERSION_KEY, it)
        }

    private fun ensureLibraryVersion(db: Connection) {
        if (db.read<String>("meta", LIBRARY_VERSION_KEY) == null) {
            db.put("meta", LIBRARY_VERSION_KEY, id("library_"))
        }
    }

    private fun bumpLibraryVersion(db: Connection) {
        db.put("meta", LIBRARY_VERSION_KEY, id("library_"))
    }

    /**
     * Older builds retained every acknowledged batch forever. Each batch embeds a
     * complete library snapshot, so their 45 rows already occupied 573 MiB.
     * Keep only the latest acknowledged and current pending batch for active
     * devices, then maintain this bound incrementally in [ack] and [revoke].
     */
    private fun migrateBatchStorage(db: Connection) {
        if (db.read<String>("meta", BATCH_STORAGE_VERSION_KEY) == BATCH_STORAGE_VERSION) return
        db.createStatement().use { statement ->
            statement.executeUpdate("""
                delete from kindle_sync_entry
                where kind='batch'
                  and entry_key not in (
                    select entry_key from (
                      select batch.entry_key,
                             row_number() over (
                               partition by json_extract(batch.payload, '$.deviceId')
                               order by batch.rowid desc
                             ) as batch_rank
                      from kindle_sync_entry batch
                      join kindle_sync_entry device
                        on device.kind='device'
                       and device.entry_key=json_extract(batch.payload, '$.deviceId')
                      where batch.kind='batch'
                        and json_extract(batch.payload, '$.acked')=1
                        and json_extract(device.payload, '$.revokedAt') is null
                    )
                    where batch_rank=1
                  )
                  and not exists (
                    select 1
                    from kindle_sync_entry device
                    where device.kind='device'
                      and json_extract(device.payload, '$.revokedAt') is null
                      and json_extract(device.payload, '$.pendingSyncId')=kindle_sync_entry.entry_key
                  )
            """.trimIndent())
            statement.executeUpdate("delete from kindle_sync_entry where kind='batch-cursor'")
            statement.executeUpdate("""
                insert or replace into kindle_sync_entry(kind,entry_key,payload)
                select 'batch-cursor',
                       json_extract(payload, '$.response.nextCursor'),
                       json_quote(entry_key)
                from kindle_sync_entry
                where kind='batch'
                  and json_extract(payload, '$.acked')=1
                  and json_extract(payload, '$.response.nextCursor') is not null
            """.trimIndent())
        }
        db.put("meta", BATCH_STORAGE_VERSION_KEY, BATCH_STORAGE_VERSION)
        log.info("migrated Kindle sync batch storage to bounded per-device retention")
    }

    /**
     * The one-time migration marker may predate batches left behind by an
     * interrupted client, manual recovery, or an older acknowledgement path.
     * Enforce the same bound on every startup so those rows self-heal instead
     * of staying in the database forever.
     */
    private fun pruneOrphanedBatches(db: Connection) {
        val activeDevices = db.all<KindleStoredDevice>("device").filter { it.revokedAt == null }
        val retainedBatches = hashSetOf<String>()
        val retainedCursors = hashSetOf<String>()
        for (device in activeDevices) {
            device.pendingSyncId?.let(retainedBatches::add)
            val ackedBatchId = device.ackedBatchId
                ?: device.ackedCursor?.let { db.read<String>("batch-cursor", it) }
            ackedBatchId?.let(retainedBatches::add)
            device.ackedCursor?.let(retainedCursors::add)
        }
        var removed = 0
        for (batchId in db.keys("batch")) {
            if (batchId !in retainedBatches) {
                db.remove("batch", batchId)
                removed += 1
            }
        }
        for (cursor in db.keys("batch-cursor")) {
            if (cursor !in retainedCursors) db.remove("batch-cursor", cursor)
        }
        if (removed > 0) {
            log.info("pruned {} orphaned Kindle sync batch(es)", removed)
        }
    }

    private fun Connection.removeBatch(batchId: String?, cursor: String?) {
        batchId ?: return
        remove("batch", batchId)
        cursor?.let { remove("batch-cursor", it) }
    }

    private fun removeDeviceSyncState(db: Connection, device: KindleStoredDevice) {
        val acknowledgedId = device.ackedBatchId
            ?: device.ackedCursor?.let { db.read<String>("batch-cursor", it) }
        db.removeBatch(acknowledgedId, device.ackedCursor)
        db.removeBatch(device.pendingSyncId, null)
    }

    private fun sha(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun sha(path: Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(path).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private fun sha(value: String): String = sha(value.toByteArray(Charsets.UTF_8))
    private fun fail(status: Int, code: String, message: String): Nothing = throw KindleSyncException(status, code, message)
    private fun requireText(value: String, name: String, max: Int = 200) {
        if (value.isBlank() || value.length > max) fail(400, "invalid_request", "$name 无效")
    }

    fun createPairingCode(deviceName: String): KindlePairingCode = database.kindleTransaction { db ->
        requireText(deviceName, "device_name", 100)
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var code: String
        do { code = (1..12).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("") }
        while (db.read<KindleStoredCode>("pairing", sha(code)) != null)
        val expires = now().plusSeconds(300)
        db.put("pairing", sha(code), KindleStoredCode(deviceName, expires.toEpochMilli()))
        KindlePairingCode(code.chunked(4).joinToString("-"), expires.toString())
    }

    fun pair(request: KindlePairRequest, remote: String): KindlePairResponse = database.kindleTransaction { db ->
        if (request.protocolVersion != 1) fail(400, "unsupported_protocol_version", "不支持此同步协议版本")
        requireText(request.deviceName, "device_name", 100)
        val rateKey = sha(remote.take(200))
        val instant = now()
        val attempts = db.read<KindlePairAttempts>("pair-attempt", rateKey)
            ?.takeIf { instant.toEpochMilli() - it.windowStart < 60_000 }
            ?: KindlePairAttempts(instant.toEpochMilli(), 0)
        // The limiter must commit rejected attempts, so pair validation is returned as data below.
        if (attempts.count >= 10) return@kindleTransaction null
        db.put("pair-attempt", rateKey, attempts.copy(count = attempts.count + 1))
        val code = request.pairingCode.trim().uppercase().replace("-", "")
        val codeKey = sha(code)
        val stored = db.read<KindleStoredCode>("pairing", codeKey)
        if (code.length != 12 || stored == null || stored.expiresAt <= instant.toEpochMilli()) {
            return@kindleTransaction Pair<KindlePairResponse?, Boolean>(null, false)
        }
        db.remove("pairing", codeKey)
        val deviceId = id("dev_")
        val token = ByteArray(32).also(random::nextBytes).let { Base64.getUrlEncoder().withoutPadding().encodeToString(it) }
        db.put("device", deviceId, KindleStoredDevice(deviceId, request.deviceName, instant.toString()))
        db.put("device-token", sha(token), deviceId)
        Pair(
            KindlePairResponse(
                serverId = serverId,
                deviceId = deviceId,
                deviceToken = token,
            ),
            true,
        )
    }.let { outcome ->
        if (outcome == null) fail(429, "pairing_rate_limited", "配对尝试过于频繁，请稍后再试")
        outcome.first ?: fail(400, "invalid_pairing_code", "配对码无效或已过期")
    }

    fun authenticate(token: String): String = database.kindleTransaction { db ->
        if (token.isBlank() || token.length > 512) fail(401, "device_unauthorized", "设备认证失败")
        val deviceId = db.read<String>("device-token", sha(token)) ?: fail(401, "device_unauthorized", "设备认证失败")
        val device = db.read<KindleStoredDevice>("device", deviceId) ?: fail(401, "device_unauthorized", "设备认证失败")
        if (device.revokedAt != null) fail(401, "device_revoked", "此设备已被撤销")
        db.put("device", deviceId, device.copy(lastSeenAt = now().toString()))
        deviceId
    }

    private fun Connection.device(deviceId: String): KindleStoredDevice {
        val value = read<KindleStoredDevice>("device", deviceId) ?: fail(401, "device_unauthorized", "设备认证失败")
        if (value.revokedAt != null) fail(401, "device_revoked", "此设备已被撤销")
        return value
    }

    fun devices(): KindleDevicesResponse = database.kindleTransaction { db ->
        KindleDevicesResponse(db.all<KindleStoredDevice>("device").map {
            KindleDeviceSummary(it.deviceId, it.deviceName, it.lastSeenAt, it.ackedCursor, it.revokedAt)
        })
    }

    /** Validate push targets against revocation while already holding the shared write lock. */
    internal fun activeDeviceIds(db: Connection): Set<String> =
        db.all<KindleStoredDevice>("device")
            .filter { it.revokedAt == null }
            .mapTo(linkedSetOf()) { it.deviceId }

    fun revoke(deviceId: String) = database.kindleTransaction { db ->
        val device = db.read<KindleStoredDevice>("device", deviceId) ?: fail(404, "device_not_found", "设备不存在")
        removeDeviceSyncState(db, device)
        db.put(
            "device",
            deviceId,
            device.copy(
                revokedAt = device.revokedAt ?: now().toString(),
                pendingSyncId = null,
                ackedBatchId = null,
            ),
        )
    }

    private fun sourceFingerprint(source: String?): String? = source?.let {
        val ignored = setOf("lastUpdateTime", "respondTime", "weight", "customOrder", "bookSourceGroup")
        val value = json.parseToJsonElement(it) as JsonObject
        sha(JsonObject(value.filterKeys { key -> key !in ignored }).toString())
    }

    private fun draftSourceFingerprint(value: KindleDraftEntry): String? =
        value.sourceFingerprint ?: sourceFingerprint(value.sourceJson)

    private fun bindingFingerprint(value: KindleDraftEntry): String = sha(json.encodeToString(listOf(
        value.sourceId, value.bookUrl, value.tocUrl, draftSourceFingerprint(value),
    )))

    private fun managementFingerprint(value: KindleDraftEntry): String = sha(json.encodeToString(listOf(
        value.bookId, value.title, value.author, bindingFingerprint(value),
    )))

    private fun publishedSummary(
        value: KindleDraftEntry,
        bindingVersion: String,
    ): KindlePublishedSummary =
        KindlePublishedSummary(
            bookId = value.bookId,
            title = value.title,
            sourceId = value.sourceId,
            bookUrl = value.bookUrl,
            bindingVersion = bindingVersion,
            bindingFingerprint = bindingFingerprint(value),
            managementFingerprint = managementFingerprint(value),
        )

    private fun KindleStoredBook.toSyncBook(): KindleStoredSyncBook =
        KindleStoredSyncBook(binding.sourceId, binding.bookUrl, book.forKindleWire())

    private fun draftEntries(db: Connection): List<KindleDraftEntry> {
        val sourceRecords = mutableMapOf<String, SourceRecord?>()
        val sourceFingerprints = mutableMapOf<String, String?>()
        return database.listBookshelf()
            .filter { it.bookKind == "novel" || it.bookKind == "local" }
            .map { shelf ->
                val key = sha(shelf.sourceId + "\u0000" + shelf.bookUrl)
                val bookId = db.read<String>("draft-identity", key) ?: id("book_").also { db.put("draft-identity", key, it) }
                val sourceRecord = if (sourceRecords.containsKey(shelf.sourceId)) {
                    sourceRecords[shelf.sourceId]
                } else {
                    database.getSource(shelf.sourceId).also { sourceRecords[shelf.sourceId] = it }
                }
                val fingerprint = if (sourceFingerprints.containsKey(shelf.sourceId)) {
                    sourceFingerprints[shelf.sourceId]
                } else {
                    sourceFingerprint(sourceRecord?.json).also { sourceFingerprints[shelf.sourceId] = it }
                }
                KindleDraftEntry(
                    bookId, shelf.name, shelf.author, shelf.sourceId, shelf.bookUrl, shelf.tocUrl,
                    sourceRecord?.json, fingerprint,
                )
            }
            .sortedBy { it.bookId }
    }

    private fun draftResponse(db: Connection, entries: List<KindleDraftEntry>): KindleDraftResponse {
        val published = db.all<KindlePublishedSummary>("published-summary").associateBy { it.bookId }
        val fingerprinted = entries.map { draft -> draft to managementFingerprint(draft) }
        val changes = fingerprinted.mapNotNull { (draft, fingerprint) ->
            val previous = published[draft.bookId]
            val operation = when {
                previous == null -> "add_book"
                previous.sourceId != draft.sourceId || previous.bookUrl != draft.bookUrl -> "change_source"
                previous.managementFingerprint != fingerprint -> "update_book"
                else -> null
            }
            operation?.let { KindleDraftChange(it, draft.bookId, draft.title) }
        } + published.values.filter { old -> entries.none { it.bookId == old.bookId } }
            .map { KindleDraftChange("delete_book", it.bookId, it.title) }
        val head = db.read<KindlePublication>("meta", "publication")?.publicationId
        val version = "draft_" + sha(json.encodeToString(listOf(head) + fingerprinted.map { it.second }))
        return KindleDraftResponse(version, head, changes.sortedBy { it.bookId })
    }

    fun draft(): KindleDraftResponse = database.kindleTransaction { db -> draftResponse(db, draftEntries(db)) }

    /**
     * Resolve the changed draft books in shelf-change order.
     *
     * The automatic scheduler shelves each ready book independently. Deletions and
     * local books need no network cache work; additions, source changes and metadata
     * updates become publishable as soon as their own full-book cache is ready.
     */
    internal fun autoPublishPlan(): KindleAutoPublishPlan = database.kindleTransaction { db ->
        val entries = draftEntries(db)
        val draft = draftResponse(db, entries)
        val entriesById = entries.associateBy { it.bookId }
        KindleAutoPublishPlan(
            draft = draft,
            targets = draft.changes.map { change ->
                val entry = entriesById[change.bookId]
                if (entry == null) {
                    KindleAutoPublishTarget(
                        bookId = change.bookId,
                        title = change.title,
                        sourceId = "",
                        bookUrl = "",
                        local = false,
                        operation = change.operation,
                    )
                } else {
                    KindleAutoPublishTarget(
                        bookId = entry.bookId,
                        title = entry.title,
                        sourceId = entry.sourceId,
                        bookUrl = entry.bookUrl,
                        local = isLocalBinding(entry),
                        operation = change.operation,
                    )
                }
            },
        )
    }

    /** Called by the existing source-switch route; the published binding stays untouched. */
    internal fun sourceSwitchIdentity(oldSourceId: String, oldBookUrl: String, sourceId: String, bookUrl: String): (Connection) -> Unit = { db ->
        val oldKey = sha(oldSourceId + "\u0000" + oldBookUrl)
        val newKey = sha(sourceId + "\u0000" + bookUrl)
        val stableId = db.read<String>("draft-identity", oldKey) ?: id("book_")
        val existing = db.read<String>("draft-identity", newKey)
        if (existing != null && existing != stableId) fail(409, "book_identity_conflict", "目标书籍已有独立身份")
        db.put("draft-identity", newKey, stableId)
        if (oldKey != newKey) db.remove("draft-identity", oldKey)
    }

    private fun publishSelection(
        db: Connection,
        entries: List<KindleDraftEntry>,
        draftVersion: String,
        entryIds: Set<String>,
        deletionIds: Set<String>,
        updateDueNow: Boolean,
    ): KindlePublication {
        if (entryIds.isEmpty() && deletionIds.isEmpty()) {
            fail(409, "draft_target_unchanged", "没有可上架的书架改动")
        }
        val publication = KindlePublication(id("pub_"), draftVersion, now().toString())
        val oldBooks = (entryIds + deletionIds)
            .asSequence()
            .distinct()
            .mapNotNull { oldBookId ->
                db.read<KindleStoredBook>("published-book", oldBookId)
                    ?.let { oldBookId to it }
            }
            .toMap()
        for (entry in entries.filter { it.bookId in entryIds }) {
            val previous = oldBooks[entry.bookId]
            val changedBinding = previous == null || bindingFingerprint(previous.binding) != bindingFingerprint(entry)
            val version = if (changedBinding) id("binding_") else previous.book.bindingVersion
            val updated = materialize(
                entry, previous, version, bindingChanged = changedBinding,
                frozenToc = if (changedBinding) null else previous.frozenToc,
                allowSharedCache = previous == null ||
                    draftSourceFingerprint(previous.binding) == draftSourceFingerprint(entry),
            )
            if (updated.book.chapters.isEmpty() || updated.book.chapters.any { it.status != "ready" }) {
                fail(409, "book_not_complete", "书籍缓存未完整，暂不能上架")
            }
            val published = attachEpub(updated)
            db.put("published-book", entry.bookId, published)
            db.put(
                "published-summary",
                entry.bookId,
                publishedSummary(entry, published.book.bindingVersion),
            )
            db.put("sync-book", entry.bookId, published.toSyncBook())
            db.put("chapter-urls", entry.bookId, KindleStoredChapterUrls(published.chapterUrls))
            val task = db.read<KindleStoredUpdateTask>("update-task", entry.bookId)
            val nextDueAt = if (isLocalBinding(entry)) null
                else if (updateDueNow && changedBinding) now().toEpochMilli()
                else scheduledNextDueAt()
            db.put("update-task", entry.bookId, if (task?.state == "paused") task
                else newUpdateTask(entry.bookId, nextDueAt))
            db.remove("deleted-book", entry.bookId)
            adoptNativeProgress(db, published)
        }
        for (old in oldBooks.values.filter { it.book.bookId in deletionIds }) {
            db.remove("published-book", old.book.bookId)
            db.remove("published-summary", old.book.bookId)
            db.remove("sync-book", old.book.bookId)
            db.remove("chapter-urls", old.book.bookId)
            db.remove("update-task", old.book.bookId)
            db.put("deleted-book", old.book.bookId, KindleDeletedBook(old.book.bookId, publication.publicationId, publication.publishedAt))
        }
        db.put("meta", "publication", publication)
        bumpLibraryVersion(db)
        return publication
    }

    fun publish(
        request: KindlePublishRequest,
        updateDueNow: Boolean = false,
    ): KindlePublication = database.kindleTransaction { db ->
        requireText(request.requestId, "request_id")
        val fingerprint = sha(json.encodeToString(request))
        db.read<KindleStoredPublicationRequest>("publication-request", request.requestId)?.let {
            if (it.fingerprint != fingerprint) fail(409, "idempotency_key_reused", "此请求编号已用于其他上架")
            return@kindleTransaction it.response
        }
        val entries = draftEntries(db)
        val draft = draftResponse(db, entries)
        if (draft.draftVersion != request.draftVersion) fail(409, "draft_conflict", "草稿已变化，请刷新后上架")
        val entryIds = entries.mapTo(linkedSetOf()) { it.bookId }
        val deletionIds = db.all<KindlePublishedSummary>("published-summary")
            .asSequence()
            .map { it.bookId }
            .filterNot { it in entryIds }
            .toCollection(linkedSetOf())
        val publication = publishSelection(
            db, entries, draft.draftVersion, entryIds, deletionIds, updateDueNow,
        )
        db.put("publication-request", request.requestId, KindleStoredPublicationRequest(fingerprint, publication))
        publication
    }

    /**
     * Shelf exactly the selected draft books as one atomic publication step.
     *
     * The automatic scheduler calls this with one book at a time so a slow or
     * failed cache for another shelf book cannot hold this book back.
     */
    internal fun publishSelectedBooks(
        requestId: String,
        draftVersion: String,
        bookIds: Collection<String>,
        updateDueNow: Boolean = false,
    ): KindlePublication = database.kindleTransaction { db ->
        requireText(requestId, "request_id")
        requireText(draftVersion, "draft_version")
        val selectedIds = bookIds.filter { it.isNotBlank() }.distinct().sorted()
        if (selectedIds.isEmpty()) fail(400, "invalid_request", "缺少待上架书籍")
        val fingerprint = sha(listOf(
            "selected-books",
            requestId,
            draftVersion,
            selectedIds.joinToString("\u0000"),
        ).joinToString("\u0000"))
        db.read<KindleStoredPublicationRequest>("publication-request", requestId)?.let {
            if (it.fingerprint != fingerprint) fail(409, "idempotency_key_reused", "此请求编号已用于其他上架")
            return@kindleTransaction it.response
        }
        val entries = draftEntries(db)
        val draft = draftResponse(db, entries)
        if (draft.draftVersion != draftVersion) fail(409, "draft_conflict", "草稿已变化，请刷新后上架")
        val changedIds = draft.changes.mapTo(hashSetOf()) { it.bookId }
        if (selectedIds.any { it !in changedIds }) {
            fail(409, "draft_conflict", "待上架书籍已变化，请刷新后重试")
        }
        val currentIds = entries.mapTo(hashSetOf()) { it.bookId }
        val entryIds = selectedIds.filterTo(linkedSetOf()) { it in currentIds }
        val deletionIds = selectedIds.filterTo(linkedSetOf()) { it !in currentIds }
        val publication = publishSelection(
            db, entries, draft.draftVersion, entryIds, deletionIds, updateDueNow,
        )
        db.put("publication-request", requestId, KindleStoredPublicationRequest(fingerprint, publication))
        publication
    }

    private fun newUpdateTask(bookId: String, nextDueAt: Long? = now().toEpochMilli() + UPDATE_INTERVAL_MS) =
        KindleStoredUpdateTask(
            bookId,
            if (nextDueAt != null && nextDueAt <= now().toEpochMilli()) "pending" else "ready",
            0L, nextDueAt,
        )

    private fun scheduledNextDueAt(): Long = now().toEpochMilli() + UPDATE_INTERVAL_MS

    private fun isLocalBinding(sourceId: String, bookUrl: String): Boolean =
        sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID ||
            bookUrl.startsWith("local://") ||
            bookUrl.startsWith("content://") ||
            bookUrl.startsWith("file://")

    private fun isLocalBinding(binding: KindleDraftEntry): Boolean =
        isLocalBinding(binding.sourceId, binding.bookUrl)

    private fun Connection.ensureUpdateTask(
        bookId: String,
        binding: KindleDraftEntry? = null,
    ): KindleStoredUpdateTask =
        read<KindleStoredUpdateTask>("update-task", bookId)
            ?: newUpdateTask(bookId, if (binding?.let(::isLocalBinding) == true) null else scheduledNextDueAt())
                .also { put("update-task", bookId, it) }

    private fun Connection.currentSourceJson(sourceId: String): String? =
        prepareStatement("select payload from source where id = ?").use { statement ->
            statement.setString(1, sourceId)
            statement.executeQuery().use { rows -> if (rows.next()) rows.getString(1) else null }
        }

    private fun Connection.sharedCacheTrusted(binding: KindleDraftEntry): Boolean =
        draftSourceFingerprint(binding) == sourceFingerprint(currentSourceJson(binding.sourceId))

    fun updateTasks(): KindleUpdateTasksResponse = database.kindleTransaction { db ->
        val summaries = db.all<KindlePublishedSummary>("published-summary").associateBy { it.bookId }
        KindleUpdateTasksResponse(db.all<KindleStoredUpdateTask>("update-task").mapNotNull { task ->
            val summary = summaries[task.bookId] ?: return@mapNotNull null
            KindleUpdateTaskSummary(
                bookId = task.bookId,
                title = summary.title,
                bindingVersion = summary.bindingVersion,
                state = task.state,
                lastAttemptAt = task.lastAttemptAt
                    .takeIf { it != 0L }
                    ?.let { Instant.ofEpochMilli(it).toString() },
                nextDueAt = task.nextDueAt?.let { Instant.ofEpochMilli(it).toString() },
                lastError = task.lastError,
            )
        }.sortedBy { it.bookId })
    }

    fun pausePublicationUpdate(bookId: String) = database.kindleTransaction { db ->
        val stored = db.read<KindleStoredBook>("published-book", bookId) ?: fail(404, "book_not_published", "书籍尚未上架")
        val task = db.ensureUpdateTask(bookId, stored.binding)
        db.put("update-task", bookId, task.copy(state = "paused", lastError = "更新已暂停"))
    }

    fun retryPublicationUpdate(bookId: String) = database.kindleTransaction { db ->
        val stored = db.read<KindleStoredBook>("published-book", bookId) ?: fail(404, "book_not_published", "书籍尚未上架")
        val task = db.ensureUpdateTask(bookId, stored.binding)
        db.put("update-task", bookId, task.copy(state = "pending", nextDueAt = 0, lastError = null))
    }

    fun duePublicationUpdateBookIds(): List<String> = database.kindleTransaction { db ->
        val instant = now().toEpochMilli()
        db.all<KindleStoredUpdateTask>("update-task").mapNotNull { task ->
            task.takeIf { it.state != "paused" && it.nextDueAt != null && it.nextDueAt <= instant }?.bookId
        }.sorted()
    }

    /**
     * Refresh one publication using its immutable source binding. Draft source edits remain invisible
     * until the administrator explicitly publishes a new binding.
     */
    fun refreshPublication(bookId: String, runner: RuleRunner): KindleBook {
        val original = database.kindleTransaction { db ->
            val stored = db.read<KindleStoredBook>("published-book", bookId) ?: fail(404, "book_not_published", "书籍尚未上架")
            val task = db.read<KindleStoredUpdateTask>("update-task", bookId)
                ?: newUpdateTask(bookId, if (isLocalBinding(stored.binding)) null else scheduledNextDueAt())
            if (task.state == "paused") fail(409, "update_paused", "更新任务已暂停")
            db.put("update-task", bookId, task.copy(state = "running", lastAttemptAt = now().toEpochMilli(), lastError = null))
            stored
        }
        try {
            fun currentForRefresh(db: Connection): KindleStoredBook? {
                val current = db.read<KindleStoredBook>("published-book", bookId)
                    ?: fail(409, "publication_changed", "上架状态已变化")
                val task = db.ensureUpdateTask(bookId, current.binding)
                if (task.state == "paused") return null
                if (bindingFingerprint(current.binding) != bindingFingerprint(original.binding)) {
                    fail(409, "publication_changed", "上架绑定已变化，放弃本次更新")
                }
                return current
            }
            if (isLocalBinding(original.binding)) {
                database.kindleTransaction { db ->
                    val current = db.read<KindleStoredBook>("published-book", bookId)
                    if (current == null || bindingFingerprint(current.binding) != bindingFingerprint(original.binding)) {
                        return@kindleTransaction
                    }
                    val task = db.read<KindleStoredUpdateTask>("update-task", bookId) ?: return@kindleTransaction
                    if (task.state == "paused") return@kindleTransaction
                    db.put("update-task", bookId, task.copy(
                        state = "ready", nextDueAt = null, lastError = null,
                    ))
                }
                return original.book
            }
            val sourceJson = original.binding.sourceJson
                ?: fail(409, "publication_binding_invalid", "上架绑定缺少书源定义")
            if (database.kindleTransaction(::currentForRefresh) == null) return original.book
            val context = database.bookContext(original.binding.sourceId, original.binding.bookUrl)
            val chapters = database.applyIgnoredBookCacheChapters(
                original.binding.sourceId,
                original.binding.bookUrl,
                runner.chapters(sourceJson, original.binding.tocUrl, context),
            )
            if (chapters.isEmpty()) fail(502, "toc_unavailable", "目录更新未返回章节")
            if (chapters.map { it.url }.toSet().size != chapters.size) fail(502, "toc_update_ambiguous", "目录更新包含重复章节地址")
            if (database.kindleTransaction(::currentForRefresh) == null) return original.book
            database.kindleTransaction { db ->
                val current = currentForRefresh(db) ?: return@kindleTransaction
                if (db.sharedCacheTrusted(current.binding)) {
                    db.prepareStatement("""
                        insert into book_toc_cache(source_id, toc_url, chapters_json, updated_at)
                        values(?, ?, ?, ?)
                        on conflict(source_id, toc_url) do update set
                            chapters_json = excluded.chapters_json, updated_at = excluded.updated_at
                    """.trimIndent()).use { statement ->
                        statement.setString(1, original.binding.sourceId)
                        statement.setString(2, original.binding.tocUrl)
                        statement.setString(3, json.encodeToString(chapters))
                        statement.setLong(4, System.currentTimeMillis())
                        statement.executeUpdate()
                    }
                }
            }
            val initial = database.kindleTransaction { db ->
                val current = currentForRefresh(db) ?: return@kindleTransaction null
                val refreshed = materialize(
                    current.binding, current, current.book.bindingVersion,
                    frozenToc = chapters, allowSharedCache = false,
                )
                current.book.tocVersion to refreshed
            } ?: return original.book
            val baseTocVersion = initial.first
            var updated = initial.second
            val contentOverrides = linkedMapOf<String, String>()

            // Only missing/new chapters are fetched in this incremental pass; existing immutable hashes
            // remain available to devices until an explicit content revision changes the cache.
            for (chapter in updated.book.chapters.filter { it.status == "pending" }) {
                if (database.kindleTransaction(::currentForRefresh) == null) return original.book
                val url = updated.chapterUrls[chapter.chapterId] ?: fail(502, "content_unavailable", "新增章节地址无效")
                val content = runner.content(sourceJson, url, original.binding.title, context)
                if (content.content.isBlank()) fail(502, "content_unavailable", "新增章节正文为空")
                database.kindleTransaction { db ->
                    val current = currentForRefresh(db) ?: return@kindleTransaction false
                    if (!db.sharedCacheTrusted(current.binding)) return@kindleTransaction false
                    db.prepareStatement("""
                        insert into book_content_cache(source_id, book_url, chapter_url, title, content, cached_at, raw_title, raw_content)
                        values(?, ?, ?, ?, ?, ?, ?, ?)
                        on conflict(source_id, book_url, chapter_url) do update set
                            title = excluded.title,
                            content = excluded.content,
                            cached_at = excluded.cached_at,
                            raw_title = coalesce(excluded.raw_title, book_content_cache.raw_title),
                            raw_content = coalesce(excluded.raw_content, book_content_cache.raw_content)
                    """.trimIndent()).use { statement ->
                        statement.setString(1, original.binding.sourceId)
                        statement.setString(2, original.binding.bookUrl)
                        statement.setString(3, url)
                        statement.setString(4, content.title)
                        statement.setString(5, content.content)
                        statement.setLong(6, System.currentTimeMillis())
                        statement.setString(7, content.rawTitle ?: content.title)
                        statement.setString(8, content.rawContent ?: content.content)
                        statement.executeUpdate()
                    }
                    true
                }
                contentOverrides[url] = content.content
                updated = database.kindleTransaction { db ->
                    val current = currentForRefresh(db) ?: return@kindleTransaction null
                    materialize(
                        current.binding, current, current.book.bindingVersion,
                        frozenToc = chapters, allowSharedCache = false,
                        contentOverrides = contentOverrides,
                    )
                } ?: return original.book
            }
            if (updated.book.chapters.isEmpty() || updated.book.chapters.any { it.status != "ready" }) {
                fail(503, "content_unavailable", "更新章节尚未完整下载")
            }
            // Build outside the shared SQLite write lock, then publish the complete
            // revision atomically. Readers keep using the previous EPUB until then.
            val published = attachEpub(updated)
            database.kindleTransaction { db ->
                val current = currentForRefresh(db) ?: return@kindleTransaction
                if (current.book.tocVersion != baseTocVersion) {
                    fail(409, "publication_changed", "上架内容已变化，放弃本次更新")
                }
                db.put("published-book", bookId, published)
                db.put("sync-book", bookId, published.toSyncBook())
                db.put("chapter-urls", bookId, KindleStoredChapterUrls(published.chapterUrls))
                bumpLibraryVersion(db)
                val task = db.read<KindleStoredUpdateTask>("update-task", bookId) ?: return@kindleTransaction
                if (task.state == "paused") return@kindleTransaction
                db.put("update-task", bookId, task.copy(
                    state = "ready", nextDueAt = now().toEpochMilli() + UPDATE_INTERVAL_MS, lastError = null,
                ))
            }
            return published.book
        } catch (error: Throwable) {
            database.kindleTransaction { db ->
                val current = db.read<KindleStoredBook>("published-book", bookId)
                if (current == null || bindingFingerprint(current.binding) != bindingFingerprint(original.binding)) {
                    return@kindleTransaction
                }
                val task = db.read<KindleStoredUpdateTask>("update-task", bookId) ?: return@kindleTransaction
                if (task.state == "paused") return@kindleTransaction
                db.put("update-task", bookId, task.copy(
                    state = "failed", nextDueAt = now().toEpochMilli() + UPDATE_INTERVAL_MS,
                    lastError = error.message?.take(500) ?: error.javaClass.simpleName,
                ))
            }
            throw error
        }
    }

    private fun xhtml(title: String, text: String): ByteArray {
        fun escape(value: String) = xmlSafe(value)
            .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
        val paragraphs = text.replace("\r\n", "\n").split(Regex("\n+"))
            .filter { it.isNotBlank() }.joinToString("") { "<p>${escape(it)}</p>" }
        return ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>${escape(title)}</title></head>" +
            "<body><h1>${escape(title)}</h1>$paragraphs</body></html>").toByteArray(Charsets.UTF_8)
    }

    private fun writeContent(bytes: ByteArray): Pair<String, Long> {
        val hash = sha(bytes)
        val path = contentDirectory.resolve("$hash.xhtml")
        if (!Files.exists(path) || sha(Files.readAllBytes(path)) != hash) {
            val temp = Files.createTempFile(contentDirectory, ".content-", ".tmp")
            try {
                Files.write(temp, bytes)
                Files.move(temp, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } finally { Files.deleteIfExists(temp) }
        }
        return hash to bytes.size.toLong()
    }

    private fun materialize(binding: KindleDraftEntry, previous: KindleStoredBook?, version: String,
                            bindingChanged: Boolean = false, frozenToc: List<Chapter>? = null,
                            allowSharedCache: Boolean = false,
                            contentOverrides: Map<String, String> = emptyMap()): KindleStoredBook {
        val cachedToc = if (allowSharedCache || bindingChanged || previous == null) {
            database.getTocCache(binding.sourceId, binding.tocUrl)
                ?: database.getTocCache(binding.sourceId, binding.bookUrl)
        } else null
        val toc = frozenToc ?: cachedToc
            ?: if (bindingChanged && previous != null) null else previous?.frozenToc
        val readableToc = toc.orEmpty().filterNot { it.isVolume }
        val old = previous?.book?.chapters.orEmpty()
        if (readableToc.isEmpty() && previous != null && !bindingChanged) {
            return previous.copy(binding = binding, frozenToc = frozenToc.orEmpty(),
                book = previous.book.copy(title = binding.title, author = binding.author))
        }
        if (bindingChanged && previous != null && old.isNotEmpty() && cachedToc.isNullOrEmpty()) {
            fail(409, "chapter_mapping_pending", "换源目录尚未就绪，无法确认章节映射")
        }
        val oldByUrl = previous?.chapterUrls.orEmpty().entries.associate { it.value to it.key }
        val oldByTitle = old.groupBy { it.title }
        val newTitleCounts = readableToc.groupingBy { it.title }.eachCount()
        if (readableToc.map { it.url }.toSet().size != readableToc.size) {
            fail(409, "chapter_mapping_ambiguous", "目录包含重复章节地址，需要确认映射")
        }
        val urls = linkedMapOf<String, String>()
        val chapters = readableToc.mapIndexed { index, chapter ->
            val byUrl = oldByUrl[chapter.url]?.takeIf { !bindingChanged }
            val titleMatches = oldByTitle[chapter.title].orEmpty()
            if (bindingChanged && previous != null && titleMatches.isNotEmpty() &&
                (titleMatches.size != 1 || newTitleCounts[chapter.title] != 1)) {
                fail(409, "chapter_mapping_ambiguous", "换源章节存在重名，需要确认映射")
            }
            val chapterId = byUrl ?: titleMatches.singleOrNull()?.takeIf { newTitleCounts[chapter.title] == 1 }?.chapterId ?: id("chapter_")
            urls[chapterId] = chapter.url
            val content = contentOverrides[chapter.url]
                ?: if (allowSharedCache || binding.sourceId == LocalBookParser.LOC_BOOK_SOURCE_ID) {
                    database.cachedContent(binding.sourceId, binding.bookUrl, chapter.url)?.content?.takeIf { it.isNotBlank() }
                } else null
            val existing = old.singleOrNull { it.chapterId == chapterId }?.takeIf { !bindingChanged }
            if (content != null) {
                val (hash, size) = writeContent(xhtml(chapter.title, content))
                KindleChapter(chapterId, index, chapter.title, "ready", hash, "chapters/$hash.xhtml", size)
            } else existing?.copy(chapterIndex = index, title = chapter.title)
                ?: KindleChapter(chapterId, index, chapter.title, "pending")
        }
        val tocVersion = "toc_" + sha(json.encodeToString(chapters))
        val book = KindleBook(binding.bookId, binding.title, binding.author, version, tocVersion, chapters)
        val epub = previous?.book?.epub?.takeIf { descriptor ->
            descriptor.sourceHash == epubSourceHash(book) &&
                descriptor.bindingVersion == book.bindingVersion &&
                descriptor.tocVersion == book.tocVersion &&
                Files.isRegularFile(exportDirectory.resolve(epubFilename(book))) &&
                runCatching { Files.size(exportDirectory.resolve(epubFilename(book))) }
                    .getOrNull() == descriptor.sizeBytes
        }
        return KindleStoredBook(binding, book.copy(epub = epub),
            urls, readableToc)
    }

    private fun adoptNativeProgress(
        db: Connection,
        sourceId: String,
        bookUrl: String,
        book: KindleBook,
    ): Boolean {
        val canonical = db.read<KindleCanonicalProgress>("progress", book.bookId)
        val native = database.getProgress(db, sourceId, bookUrl) ?: return false
        if (canonical != null && canonical.nativeUpdatedAt == native.updatedAt) return false
        val chapter = book.chapters.getOrNull(native.chapterIndex) ?: return false
        val position = KindleProgressPosition(
            id("progress_"), chapter.chapterId, chapter.chapterIndex, native.scrollPosition,
            deviceName = "WebUI", recordedAt = Instant.ofEpochMilli(native.updatedAt).toString(),
        )
        if (canonical != null && canonical.position.chapterId == position.chapterId &&
            canonical.position.chapterProgress == position.chapterProgress) {
            db.put("progress", book.bookId, canonical.copy(nativeUpdatedAt = native.updatedAt))
            return false
        } else {
            db.put("progress", book.bookId, KindleCanonicalProgress(position, book.bindingVersion, native.updatedAt))
            bumpLibraryVersion(db)
            return true
        }
    }

    private fun adoptNativeProgress(db: Connection, stored: KindleStoredBook) =
        adoptNativeProgress(db, stored.binding.sourceId, stored.binding.bookUrl, stored.book)

    /**
     * Import only WebUI/Android progress that has changed since the canonical
     * Kindle position was adopted. This scans compact progress rows and reads a
     * full sync-book only for the changed book.
     */
    private fun adoptNativeProgressChanges(db: Connection) {
        val summariesByBook = db.all<KindlePublishedSummary>("published-summary")
            .associateBy { it.sourceId + "\u0000" + it.bookUrl }
        for (native in database.listReadingAnchors()) {
            val summary = summariesByBook[native.sourceId + "\u0000" + native.bookUrl] ?: continue
            val canonical = db.read<KindleCanonicalProgress>("progress", summary.bookId)
            if (canonical?.nativeUpdatedAt == native.updatedAt) continue
            val stored = db.read<KindleStoredSyncBook>("sync-book", summary.bookId) ?: continue
            adoptNativeProgress(db, native.sourceId, native.bookUrl, stored.book)
        }
    }

    private fun currentSnapshot(db: Connection): KindleLibrarySnapshot {
        val books = db.all<KindleStoredSyncBook>("sync-book").map { stored ->
            // Published books are immutable complete snapshots. Cache refreshes commit
            // a replacement only after every chapter and its EPUB are ready.
            adoptNativeProgress(db, stored.sourceId, stored.bookUrl, stored.book)
            val progress = db.read<KindleCanonicalProgress>("progress", stored.book.bookId)?.position
            stored.book.copy(progress = progress)
        }.sortedBy { it.bookId }
        return KindleLibrarySnapshot(db.read<KindlePublication>("meta", "publication")?.publicationId, books)
    }

    /**
     * The whole-book EPUB already contains every byte. Its synchronization
     * record only needs stable chapter identity, order, title, and completeness
     * for TOC/progress mapping. Per-chapter hashes and paths remain in storage
     * for bundle publications and EPUB generation, but sending them again
     * multiplies the snapshot payload on large books.
     */
    private fun KindleBook.forKindleWire(): KindleBook {
        if (epub == null) return this
        return copy(chapters = chapters.map { chapter ->
            chapter.copy(
                status = "ready",
                contentHash = null,
                contentPath = null,
                sizeBytes = null,
            )
        })
    }

    private fun acknowledgedBatch(
        db: Connection,
        device: KindleStoredDevice,
        cursor: String,
    ): Pair<String, KindleStoredBatch> {
        val indexedId = device.ackedBatchId ?: db.read<String>("batch-cursor", cursor)
        val indexed = indexedId?.let { batchId ->
            db.read<KindleStoredBatch>("batch", batchId)?.takeIf {
                it.deviceId == device.deviceId &&
                    it.acked &&
                    it.response.nextCursor == cursor
            }?.let { batchId to it }
        }
        if (indexed != null) return indexed
        return db.allEntries<KindleStoredBatch>("batch").entries
            .firstOrNull { (_, batch) ->
                batch.deviceId == device.deviceId &&
                    batch.acked &&
                    batch.response.nextCursor == cursor
            }
            ?.let { it.key to it.value }
            ?: fail(410, "cursor_expired", "同步游标已过期，请获取完整快照")
    }

    fun sync(deviceId: String, cursor: String?): KindleSyncResponse = database.kindleTransaction { db ->
        val device = db.device(deviceId)
        val pending = device.pendingSyncId?.let { db.read<KindleStoredBatch>("batch", it) }
        if (pending != null && !pending.acked && pending.response.fromCursor == cursor) return@kindleTransaction pending.response
        if (cursor != null && device.ackedCursor != cursor) fail(410, "cursor_expired", "同步游标无效，请获取完整快照")
        adoptNativeProgressChanges(db)
        val libraryVersion = currentLibraryVersion(db)
        if (cursor != null && device.ackedLibraryVersion == libraryVersion) {
            return@kindleTransaction KindleSyncResponse(
                fromCursor = cursor,
                nextCursor = cursor,
                reset = false,
                publicationId = db.read<KindlePublication>("meta", "publication")?.publicationId,
            )
        }
        val baselineEntry = cursor?.let { acknowledgedBatch(db, device, it) }
        val baseline = baselineEntry?.second
        val snapshot = currentSnapshot(db)
        if (baseline != null && baseline.snapshot == snapshot) {
            db.put("batch-cursor", cursor!!, baselineEntry.first)
            db.put(
                "device",
                deviceId,
                device.copy(
                    ackedLibraryVersion = libraryVersion,
                    ackedBatchId = baselineEntry.first,
                    pendingSyncId = null,
                ),
            )
            return@kindleTransaction KindleSyncResponse(
                fromCursor = cursor,
                nextCursor = cursor,
                reset = false,
                publicationId = snapshot.publicationId,
            )
        }
        val previousBooks = baseline?.snapshot?.books.orEmpty().associateBy { it.bookId }
        val changed = snapshot.books.filter { it != previousBooks[it.bookId] }
        val removed = previousBooks.keys - snapshot.books.map { it.bookId }.toSet()
        val deleted = removed.map { db.read<KindleDeletedBook>("deleted-book", it)
            ?: fail(500, "publication_inconsistent", "已上架书架缺少删除记录") }
        val previousHashes = baseline?.snapshot?.books.orEmpty().flatMap { it.chapters }.mapNotNull { it.contentHash }.toSet()
        val needed = changed.filter { it.epub == null }.flatMap { it.chapters }
            .filter { it.status == "ready" && it.contentHash !in previousHashes }
            .distinctBy { it.contentHash }
        val syncId = id("syn_")
        val bundles = bundles(db, deviceId, syncId, needed)
        val response = KindleSyncResponse(syncId = syncId, fromCursor = cursor, nextCursor = id("cur_"), reset = cursor == null,
                                          publicationId = snapshot.publicationId, books = changed, deletedBooks = deleted, bundles = bundles)
        db.put("batch", syncId, KindleStoredBatch(deviceId, response, snapshot, libraryVersion = libraryVersion))
        db.put("device", deviceId, device.copy(pendingSyncId = syncId))
        response
    }

    private fun bundles(db: Connection, deviceId: String, syncId: String, chapters: List<KindleChapter>): List<KindleBundleDescriptor> {
        val groups = mutableListOf<MutableList<KindleChapter>>()
        var size = 0L
        for (chapter in chapters.sortedBy { it.contentHash }) {
            if (groups.isEmpty() || (size + chapter.sizeBytes!! > 4L * 1024 * 1024 - 65536 && groups.last().isNotEmpty())) {
                groups.add(mutableListOf()); size = 0
            }
            groups.last().add(chapter); size += chapter.sizeBytes!!
        }
        return groups.map { group ->
            val bundleId = id("bundle_")
            val files = group.map { KindleBundleFile(it.contentPath!!, it.contentHash!!, it.sizeBytes!!) }
            val temp = Files.createTempFile(bundleDirectory, ".bundle-", ".tmp")
            val final = bundleDirectory.resolve("$bundleId.zip")
            try {
                ZipOutputStream(Files.newOutputStream(temp)).use { zip ->
                    fun entry(name: String, bytes: ByteArray) {
                        zip.putNextEntry(ZipEntry(name).apply { time = 0 })
                        zip.write(bytes); zip.closeEntry()
                    }
                    entry("manifest.json", json.encodeToString(KindleBundleManifest(bundleId = bundleId, files = files)).toByteArray(Charsets.UTF_8))
                    for (file in files) {
                        val bytes = Files.readAllBytes(contentDirectory.resolve("${file.sha256}.xhtml"))
                        if (bytes.size.toLong() != file.sizeBytes || sha(bytes) != file.sha256) fail(503, "content_unavailable", "章节文件校验失败")
                        entry(file.path, bytes)
                    }
                }
                Files.move(temp, final, StandardCopyOption.ATOMIC_MOVE)
            } finally { Files.deleteIfExists(temp) }
            val descriptor = KindleBundleDescriptor(bundleId, "/api/v1/bundles/$bundleId", sha(Files.readAllBytes(final)), Files.size(final))
            db.put("bundle", bundleId, KindleStoredBundle(deviceId, syncId, descriptor))
            descriptor
        }
    }

    private fun xmlSafe(value: String): String {
        val result = StringBuilder(value.length)
        var offset = 0
        while (offset < value.length) {
            val codePoint = value.codePointAt(offset)
            if (codePoint == 0x9 || codePoint == 0xA || codePoint == 0xD ||
                codePoint in 0x20..0xD7FF || codePoint in 0xE000..0xFFFD ||
                codePoint in 0x10000..0x10FFFF) {
                result.appendCodePoint(codePoint)
            }
            offset += Character.charCount(codePoint)
        }
        return result.toString()
    }

    private fun xmlEscape(value: String) = xmlSafe(value)
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    private fun epubFilename(book: KindleBook): String = "${book.bookId}-${book.tocVersion}.epub"

    private fun epubChunkHref(index: Int): String = "text/chunk-${index.toString().padStart(4, '0')}.xhtml"

    private fun epubSourceHash(book: KindleBook): String = sha(json.encodeToString(listOf(
        EPUB_FORMAT_VERSION,
        book.bookId,
        book.title,
        book.author,
        book.bindingVersion,
        book.tocVersion,
    )))

    private fun epubDescriptor(exported: KindleEpubExport): KindleEpubDescriptor =
        KindleEpubDescriptor(
            sha256 = exported.sha256,
            sizeBytes = exported.sizeBytes,
            url = "/api/v1/books/${exported.bookId}/epub",
            bindingVersion = exported.bindingVersion,
            tocVersion = exported.tocVersion,
            sourceHash = epubSourceHash(KindleBook(
                exported.bookId,
                exported.title,
                exported.author,
                exported.bindingVersion,
                exported.tocVersion,
                emptyList(),
            )),
        )

    /** Attach one immutable whole-book EPUB to a fully cached publication. */
    private fun attachEpub(stored: KindleStoredBook): KindleStoredBook {
        if (stored.book.chapters.isEmpty() || stored.book.chapters.any {
                it.status != "ready" || it.contentHash == null || it.contentPath == null || it.sizeBytes == null
            }) {
            return stored.copy(book = stored.book.copy(epub = null))
        }
        val current = stored.book.epub
        val target = exportDirectory.resolve(epubFilename(stored.book))
        if (current != null && current.sourceHash == epubSourceHash(stored.book) &&
            current.bindingVersion == stored.book.bindingVersion &&
            current.tocVersion == stored.book.tocVersion && Files.isRegularFile(target) &&
            Files.size(target) == current.sizeBytes && sha(target) == current.sha256) {
            return stored
        }
        val descriptor = epubDescriptor(buildEpub(stored))
        return stored.copy(book = stored.book.copy(epub = descriptor))
    }

    /**
     * Prepare whole-book EPUBs for already published books and completed source
     * updates. Each book is independent so one failed export cannot block the
     * rest of the shelf.
     */
    fun prepareMissingEpubs(bookIds: Collection<String>? = null): Int {
        val selected = bookIds?.toSet()
        val candidateIds = database.kindleTransaction { db ->
            if (selected == null) db.keys("published-book") else selected.sorted()
        }
        var prepared = 0
        for (bookId in candidateIds) {
            runCatching {
                val indexed = database.kindleTransaction { db ->
                    db.read<KindleStoredSyncBook>("sync-book", bookId)
                } ?: return@runCatching
                if (indexed.book.chapters.isEmpty() ||
                    indexed.book.chapters.any { it.status != "ready" } ||
                    !epubNeedsRepair(indexed.book)
                ) {
                    return@runCatching
                }
                val stored = database.kindleTransaction { db ->
                    db.read<KindleStoredBook>("published-book", bookId)
                } ?: return@runCatching
                if (stored.book.chapters.isEmpty() ||
                    stored.book.chapters.any { it.status != "ready" } ||
                    !epubNeedsRepair(stored.book)
                ) {
                    return@runCatching
                }
                val updated = attachEpub(stored)
                val committed = database.kindleTransaction { db ->
                    val current = db.read<KindleStoredBook>("published-book", stored.book.bookId)
                        ?: return@kindleTransaction false
                    if (current.book.bindingVersion == stored.book.bindingVersion &&
                        current.book.tocVersion == stored.book.tocVersion) {
                        db.put("published-book", current.book.bookId, updated)
                        db.put("sync-book", current.book.bookId, updated.toSyncBook())
                        bumpLibraryVersion(db)
                        true
                    } else {
                        false
                    }
                }
                if (committed) prepared += 1
            }.onFailure { error ->
                log.warn(
                    "failed to prepare whole-book EPUB for {}: {}",
                    bookId,
                    error.message,
                )
            }
        }
        return prepared
    }

    private fun epubNeedsRepair(book: KindleBook): Boolean {
        val descriptor = book.epub ?: return true
        val target = exportDirectory.resolve(epubFilename(book))
        return descriptor.sourceHash != epubSourceHash(book) ||
            descriptor.bindingVersion != book.bindingVersion ||
            descriptor.tocVersion != book.tocVersion ||
            !Files.isRegularFile(target) ||
            runCatching { Files.size(target) }.getOrNull() != descriptor.sizeBytes ||
            runCatching { sha(target) }.getOrNull() != descriptor.sha256
    }

    /** Build an EPUB 3 from one immutable, fully cached publication binding. */
    fun exportEpub(bookId: String): KindleEpubExport {
        val stored = database.kindleTransaction { db ->
            db.read<KindleStoredBook>("published-book", bookId) ?: fail(404, "book_not_published", "书籍尚未上架")
        }
        return buildEpub(stored)
    }

    private fun buildEpub(stored: KindleStoredBook): KindleEpubExport {
        if (stored.book.chapters.isEmpty() || stored.book.chapters.any { it.status != "ready" || it.contentHash == null || it.contentPath == null || it.sizeBytes == null }) {
            fail(409, "book_not_complete", "书籍缓存未完整，暂不能导出EPUB")
        }
        val chapterFiles = stored.book.chapters.map { chapter ->
            val expectedPath = "chapters/${chapter.contentHash}.xhtml"
            if (chapter.contentPath != expectedPath) fail(409, "content_path_invalid", "章节内容路径无效")
            val source = contentDirectory.resolve("${chapter.contentHash}.xhtml")
            if (!Files.isRegularFile(source)) fail(503, "content_unavailable", "章节文件不存在")
            if (Files.size(source) != chapter.sizeBytes) fail(503, "content_unavailable", "章节文件校验失败")
            chapter to source
        }
        val chapterChunks = chapterFiles.chunked(EPUB_CHAPTER_BUNDLE_SIZE)
        val bookIdXml = xmlEscape(stored.book.bookId)
        val titleXml = xmlEscape(stored.book.title)
        val authorXml = stored.book.author?.let(::xmlEscape)
        val opf = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="zh">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:identifier id="book-id">urn:legado:${bookIdXml}</dc:identifier>
  <dc:title>${titleXml}</dc:title>${if (authorXml == null) "" else "\n  <dc:creator>$authorXml</dc:creator>"}
  <dc:language>zh</dc:language>
  <meta property="dcterms:modified">${xmlEscape(now().truncatedTo(ChronoUnit.SECONDS).toString())}</meta>
 </metadata>
 <manifest>
  <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
${chapterChunks.indices.joinToString("\n") { "  <item id=\"chunk-$it\" href=\"${epubChunkHref(it)}\" media-type=\"application/xhtml+xml\"/>" }}
 </manifest>
 <spine>${chapterChunks.indices.joinToString("") { "\n  <itemref idref=\"chunk-$it\"/>" }}
 </spine>
</package>
""".toByteArray(Charsets.UTF_8)
        val nav = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>${titleXml}</title></head>
<body><nav epub:type="toc"><h1>${titleXml}</h1><ol>${chapterFiles.joinToString("") { (chapter, _) ->
    "<li><a href=\"${epubChunkHref(chapter.chapterIndex / EPUB_CHAPTER_BUNDLE_SIZE)}#chapter-${chapter.chapterIndex}\">${xmlEscape(chapter.title)}</a></li>"
}}</ol></nav></body></html>"""
            .toByteArray(Charsets.UTF_8)
        val filename = epubFilename(stored.book)
        val target = exportDirectory.resolve(filename)
        val temp = Files.createTempFile(exportDirectory, ".epub-", ".tmp")
        try {
            ZipOutputStream(Files.newOutputStream(temp)).use { zip ->
                fun entry(name: String, bytes: ByteArray, stored: Boolean = false) {
                    zip.putNextEntry(ZipEntry(name).apply {
                        time = 0
                        method = if (stored) ZipEntry.STORED else ZipEntry.DEFLATED
                        if (stored) {
                            size = bytes.size.toLong()
                            compressedSize = bytes.size.toLong()
                            crc = java.util.zip.CRC32().apply { update(bytes) }.value
                        }
                    })
                    zip.write(bytes); zip.closeEntry()
                }
                entry("mimetype", "application/epub+zip".toByteArray(Charsets.US_ASCII), stored = true)
                entry("META-INF/container.xml", """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""".toByteArray(Charsets.UTF_8))
                entry("content.opf", opf)
                entry("nav.xhtml", nav)
                chapterChunks.forEachIndexed { chunkIndex, chunk ->
                    val sections = chunk.joinToString("") { (chapter, source) ->
                        val raw = Files.readAllBytes(source)
                        if (raw.size.toLong() != chapter.sizeBytes || sha(raw) != chapter.contentHash) {
                            fail(503, "content_unavailable", "章节文件校验失败")
                        }
                        val safe = xmlSafe(raw.toString(Charsets.UTF_8))
                        val bodyStart = safe.indexOf("<body>")
                        val bodyEnd = safe.lastIndexOf("</body>")
                        if (bodyStart < 0 || bodyEnd < bodyStart) {
                            fail(503, "content_unavailable", "章节正文结构无效")
                        }
                        "<section id=\"chapter-${chapter.chapterIndex}\">${safe.substring(bodyStart + 6, bodyEnd)}</section>"
                    }
                    val document = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>${titleXml}</title></head><body>$sections</body></html>"""
                        .toByteArray(Charsets.UTF_8)
                    zip.putNextEntry(ZipEntry(epubChunkHref(chunkIndex)).apply { time = 0 })
                    zip.write(document)
                    zip.closeEntry()
                }
            }
            Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { Files.deleteIfExists(temp) }
        val digest = MessageDigest.getInstance("SHA-256")
        val exportSha = Files.newInputStream(target).use { input ->
            val stream = java.security.DigestInputStream(input, digest)
            stream.transferTo(java.io.OutputStream.nullOutputStream())
            digest.digest().joinToString("") { "%02x".format(it) }
        }
        return KindleEpubExport(stored.book.bookId, stored.book.title, stored.book.author, stored.book.bindingVersion,
            stored.book.tocVersion, filename, exportSha, Files.size(target))
    }

    fun exportPath(@Suppress("UNUSED_PARAMETER") bookId: String, filename: String): Path {
        require(filename == filename.substringAfterLast('/') && filename.endsWith(".epub")) { "invalid EPUB filename" }
        return exportDirectory.resolve(filename)
    }

    fun publishedEpub(deviceId: String, bookId: String): Pair<KindleEpubDescriptor, Path> =
        database.kindleTransaction { db ->
            db.device(deviceId)
            val stored = db.read<KindleStoredSyncBook>("sync-book", bookId)
                ?: fail(404, "book_not_published", "书籍尚未上架")
            val descriptor = stored.book.epub
                ?: fail(409, "epub_not_ready", "书籍 EPUB 尚未生成")
            val path = exportDirectory.resolve(epubFilename(stored.book))
            if (!Files.isRegularFile(path) || Files.size(path) != descriptor.sizeBytes) {
                fail(503, "epub_unavailable", "书籍 EPUB 暂不可用")
            }
            descriptor to path
        }

    fun bundle(deviceId: String, bundleId: String): Pair<KindleBundleDescriptor, Path> = database.kindleTransaction { db ->
        db.device(deviceId)
        val stored = db.read<KindleStoredBundle>("bundle", bundleId)?.takeIf { it.deviceId == deviceId }
            ?: fail(404, "bundle_not_found", "同步包不存在")
        val path = bundleDirectory.resolve("${stored.descriptor.bundleId}.zip")
        if (!Files.isRegularFile(path) || Files.size(path) != stored.descriptor.sizeBytes) fail(503, "bundle_unavailable", "同步包暂不可用")
        stored.descriptor to path
    }

    fun ack(deviceId: String, request: KindleAckRequest): KindleAckResponse = database.kindleTransaction { db ->
        val device = db.device(deviceId)
        val batch = db.read<KindleStoredBatch>("batch", request.syncId)?.takeIf { it.deviceId == deviceId }
            ?: fail(409, "sync_ack_mismatch", "同步确认与批次不匹配")
        val expected = batch.response.bundles.map { it.bundleId }.toSet()
        if (batch.response.nextCursor != request.nextCursor || request.appliedBundleIds.toSet() != expected ||
            request.appliedBundleIds.size != expected.size || (!batch.acked && device.pendingSyncId != request.syncId)) {
            fail(409, "sync_ack_mismatch", "同步确认与批次不匹配")
        }
        if (!batch.acked) {
            val previousBatchId = device.ackedBatchId
                ?: device.ackedCursor?.let { db.read<String>("batch-cursor", it) }
            db.put("batch", request.syncId, batch.copy(acked = true))
            db.put("batch-cursor", request.nextCursor, request.syncId)
            db.put(
                "device",
                deviceId,
                device.copy(
                    ackedCursor = request.nextCursor,
                    pendingSyncId = null,
                    ackedLibraryVersion = batch.libraryVersion,
                    ackedBatchId = request.syncId,
                ),
            )
            if (previousBatchId != null && previousBatchId != request.syncId) {
                db.removeBatch(previousBatchId, device.ackedCursor)
            }
        }
        KindleAckResponse(nextCursor = request.nextCursor)
    }

    fun progress(deviceId: String, request: KindleProgressRequest): KindleProgressResponse = database.kindleTransaction { db ->
        val device = db.device(deviceId)
        if (request.events.isEmpty() || request.events.size > 100) fail(400, "invalid_request", "每批需包含 1 至 100 条阅读记录")
        KindleProgressResponse(request.events.map { event ->
            if (event.eventId.isBlank() || event.eventId.length > 200 || !event.deviceSeq.matches(Regex("[1-9][0-9]{0,39}")) ||
                !event.chapterProgress.isFinite() || event.chapterProgress !in 0.0..1.0 || event.chapterIndex < 0 ||
                runCatching { Instant.parse(event.recordedAt) }.isFailure) {
                return@map KindleProgressResult(event.eventId, "rejected", errorCode = "invalid_progress")
            }
            val fingerprint = sha(json.encodeToString(event))
            val eventKey = sha(deviceId + "\u0000" + event.eventId)
            val seqKey = sha(deviceId + "\u0000" + event.deviceSeq)
            val previous = db.read<KindleStoredEvent>("progress-event", eventKey)
            val sequenceEvent = db.read<String>("progress-sequence", seqKey)
            if (previous != null) {
                return@map if (previous.fingerprint == fingerprint) previous.result.copy(status = "duplicate")
                    else KindleProgressResult(event.eventId, "rejected", errorCode = "idempotency_key_reused")
            }
            if (sequenceEvent != null) return@map KindleProgressResult(event.eventId, "rejected", errorCode = "idempotency_key_reused")
            val published = db.read<KindleStoredSyncBook>("sync-book", event.bookId)
            val result = if (published == null) {
                val deleted = db.read<KindleDeletedBook>("deleted-book", event.bookId) != null
                KindleProgressResult(event.eventId, "rejected", errorCode = if (deleted) "book_deleted" else "book_not_published")
            } else {
                adoptNativeProgress(db, published.sourceId, published.bookUrl, published.book)
                val chapter = published.book.chapters.singleOrNull { it.chapterId == event.chapterId }
                val current = db.read<KindleCanonicalProgress>("progress", event.bookId)
                val candidate = KindleProgressPosition(chapterId = event.chapterId, chapterIndex = event.chapterIndex,
                    chapterProgress = event.chapterProgress, deviceId = deviceId, deviceName = device.deviceName, recordedAt = event.recordedAt)
                val matches = chapter != null && chapter.chapterIndex == event.chapterIndex &&
                    published.book.bindingVersion == event.bindingVersion && current?.position?.progressVersion == event.baseProgressVersion
                val samePosition = chapter != null && chapter.chapterIndex == event.chapterIndex &&
                    published.book.bindingVersion == event.bindingVersion && current?.position?.let {
                        it.chapterId == event.chapterId && it.chapterIndex == event.chapterIndex &&
                            it.chapterProgress == event.chapterProgress
                    } == true
                if (matches) {
                    val position = candidate.copy(progressVersion = id("progress_"))
                    val urls = db.read<KindleStoredChapterUrls>("chapter-urls", event.bookId)
                        ?: fail(500, "publication_inconsistent", "上架章节地址索引缺失")
                    val chapterUrl = urls.urls[event.chapterId]
                        ?: fail(500, "publication_inconsistent", "上架章节地址缺失")
                    val native = database.saveProgress(ReadingProgress(
                        published.sourceId,
                        published.bookUrl,
                        chapterUrl,
                        event.chapterIndex,
                        event.chapterProgress,
                    ))
                    db.put("progress", event.bookId, KindleCanonicalProgress(position, event.bindingVersion, native.updatedAt))
                    bumpLibraryVersion(db)
                    KindleProgressResult(event.eventId, "applied", position.progressVersion)
                } else if (samePosition) {
                    KindleProgressResult(
                        event.eventId, "duplicate", progressVersion = current.position.progressVersion,
                    )
                } else {
                    val existing = db.all<KindleProgressConflict>("conflict")
                        .filter {
                            it.status == "unresolved" && it.bookId == event.bookId &&
                                it.candidate.deviceId == deviceId
                        }
                        .maxByOrNull { it.createdAt }
                    val conflict = existing?.copy(
                        title = published.book.title,
                        current = current?.position,
                        candidate = candidate,
                        bindingVersion = event.bindingVersion,
                        eventId = event.eventId,
                    ) ?: KindleProgressConflict(
                        conflictId = id("conflict_"),
                        bookId = event.bookId,
                        title = published.book.title,
                        current = current?.position,
                        candidate = candidate,
                        bindingVersion = event.bindingVersion,
                        eventId = event.eventId,
                        createdAt = now().toString(),
                    )
                    db.put("conflict", conflict.conflictId, conflict)
                    KindleProgressResult(event.eventId, "conflict", current?.position?.progressVersion, conflict.conflictId)
                }
            }
            db.put("progress-event", eventKey, KindleStoredEvent(fingerprint, result))
            db.put("progress-sequence", seqKey, eventKey)
            result
        })
    }

    fun conflicts(deviceId: String? = null): KindleConflictsResponse = database.kindleTransaction { db ->
        KindleConflictsResponse(db.all<KindleProgressConflict>("conflict")
            .filter { it.status == "unresolved" && (deviceId == null || it.candidate.deviceId == deviceId) }
            .mapNotNull { conflict ->
                val latest = db.read<KindleCanonicalProgress>("progress", conflict.bookId)?.position
                if (latest != null && latest.chapterId == conflict.candidate.chapterId &&
                    latest.chapterIndex == conflict.candidate.chapterIndex &&
                    latest.chapterProgress == conflict.candidate.chapterProgress) {
                    db.put(
                        "conflict",
                        conflict.conflictId,
                        conflict.copy(
                            current = latest,
                            status = "resolved",
                            resolvedAt = now().toString(),
                            resolution = "server",
                            resolvedProgressVersion = latest.progressVersion,
                        ),
                    )
                    null
                } else if (latest?.progressVersion != conflict.current?.progressVersion) {
                    conflict.copy(current = latest).also { db.put("conflict", conflict.conflictId, it) }
                } else conflict
            }
            .sortedBy { it.createdAt })
    }

    /**
     * Resolve a progress conflict without inventing a last-writer-wins timestamp rule.
     *
     * "server" accepts the canonical position recorded in the conflict. "kindle" promotes
     * the persisted candidate through the same book mapping and native progress write used
     * by ordinary uploads. Repeating the same resolution is idempotent.
     */
    fun resolveConflict(
        deviceId: String?,
        conflictId: String,
        request: KindleConflictResolutionRequest,
    ): KindleConflictResolutionResponse = database.kindleTransaction { db ->
        requireText(conflictId, "conflict_id")
        if (request.resolution != "server" && request.resolution != "kindle") {
            fail(400, "invalid_resolution", "冲突解决方式无效")
        }
        val conflict = db.read<KindleProgressConflict>("conflict", conflictId)
            ?: fail(404, "conflict_not_found", "阅读进度冲突不存在")
        if (deviceId != null && conflict.candidate.deviceId != deviceId) {
            fail(404, "conflict_not_found", "阅读进度冲突不存在")
        }
        if (conflict.status == "resolved") {
            if (conflict.resolution != request.resolution) {
                fail(409, "conflict_already_resolved", "此阅读进度冲突已按其他方式解决")
            }
            return@kindleTransaction KindleConflictResolutionResponse(
                conflictId = conflict.conflictId,
                resolution = request.resolution,
                resolvedAt = conflict.resolvedAt ?: now().toString(),
                progress = db.read<KindleCanonicalProgress>("progress", conflict.bookId)?.position,
            )
        }

        val published = db.read<KindleStoredBook>("published-book", conflict.bookId)
            ?: fail(409, "conflict_book_unavailable", "冲突书籍已不在已上架书架")
        if (conflict.bindingVersion != null && conflict.bindingVersion != published.book.bindingVersion) {
            fail(409, "conflict_stale", "书籍版本已变化，请重新同步后再解决")
        }
        val canonical = db.read<KindleCanonicalProgress>("progress", conflict.bookId)
        val resolvedAt = now().toString()
        val position = if (request.resolution == "server") {
            canonical?.position
        } else {
            val expectedVersion = request.expectedProgressVersion ?: conflict.current?.progressVersion
            if (expectedVersion != canonical?.position?.progressVersion) {
                fail(409, "conflict_stale", "阅读进度已在其他设备更新，请刷新后再解决")
            }
            val chapter = published.book.chapters.singleOrNull {
                it.chapterId == conflict.candidate.chapterId &&
                    it.chapterIndex == conflict.candidate.chapterIndex
            } ?: fail(409, "conflict_stale", "候选章节已不在当前目录中")
            val chapterUrl = published.chapterUrls[chapter.chapterId]
                ?: fail(409, "conflict_stale", "候选章节缺少内容地址")
            val selected = conflict.candidate.copy(
                progressVersion = id("progress_"),
                recordedAt = conflict.candidate.recordedAt ?: resolvedAt,
            )
            val native = database.saveProgress(
                ReadingProgress(
                    published.binding.sourceId,
                    published.binding.bookUrl,
                    chapterUrl,
                    chapter.chapterIndex,
                    conflict.candidate.chapterProgress,
                )
            )
            db.put(
                "progress",
                conflict.bookId,
                KindleCanonicalProgress(selected, published.book.bindingVersion, native.updatedAt),
            )
            bumpLibraryVersion(db)
            selected
        }
        val resolved = conflict.copy(
            status = "resolved",
            resolvedAt = resolvedAt,
            resolution = request.resolution,
            resolvedProgressVersion = position?.progressVersion,
        )
        db.put("conflict", conflict.conflictId, resolved)
        KindleConflictResolutionResponse(
            conflictId = conflict.conflictId,
            resolution = request.resolution,
            resolvedAt = resolvedAt,
            progress = position,
        )
    }

    private companion object {
        const val EPUB_FORMAT_VERSION = "whole-book-epub-v3"
        const val EPUB_CHAPTER_BUNDLE_SIZE = 128
        const val UPDATE_INTERVAL_MS = 30L * 60 * 1000
        const val LIBRARY_VERSION_KEY = "library-version"
        const val BATCH_STORAGE_VERSION_KEY = "batch-storage-version"
        const val BATCH_STORAGE_VERSION = "2"
    }
}
