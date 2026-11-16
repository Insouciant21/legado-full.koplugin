package io.legado.server

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable data class KindleErrorDetail(val code: String, val message: String, val retryable: Boolean = false)
@Serializable data class KindleErrorEnvelope(val error: KindleErrorDetail)
@Serializable data class KindleDeviceName(@SerialName("device_name") val deviceName: String = "Kindle")
@Serializable data class KindlePairingCode(
    @SerialName("pairing_code") val pairingCode: String,
    @SerialName("expires_at") val expiresAt: String,
)
@Serializable data class KindlePairRequest(
    @SerialName("pairing_code") val pairingCode: String,
    @SerialName("device_name") val deviceName: String = "Kindle",
    @SerialName("protocol_version") val protocolVersion: Int = 1,
)
@Serializable data class KindlePairResponse(
    @SerialName("protocol_version") val protocolVersion: Int = 1,
    @SerialName("server_id") val serverId: String,
    @SerialName("device_id") val deviceId: String,
    @SerialName("device_token") val deviceToken: String,
    @SerialName("token_type") val tokenType: String = "Bearer",
)
@Serializable data class KindleDeviceSummary(
    @SerialName("device_id") val deviceId: String,
    @SerialName("device_name") val deviceName: String,
    @SerialName("last_seen_at") val lastSeenAt: String? = null,
    @SerialName("acked_cursor") val ackedCursor: String? = null,
    @SerialName("revoked_at") val revokedAt: String? = null,
)
@Serializable data class KindleDevicesResponse(val devices: List<KindleDeviceSummary>)
@Serializable data class KindleDraftChange(
    val operation: String,
    @SerialName("book_id") val bookId: String,
    val title: String,
)
@Serializable data class KindleDraftResponse(
    @SerialName("draft_version") val draftVersion: String,
    @SerialName("base_publication_id") val basePublicationId: String? = null,
    val changes: List<KindleDraftChange>,
)
@Serializable data class KindlePublishRequest(
    @SerialName("request_id") val requestId: String,
    @SerialName("draft_version") val draftVersion: String,
)
@Serializable data class KindlePublication(
    @SerialName("publication_id") val publicationId: String,
    @SerialName("draft_version") val draftVersion: String,
    @SerialName("published_at") val publishedAt: String,
)
@Serializable data class KindleAutoPublishBlocker(
    @SerialName("book_id") val bookId: String,
    val title: String,
    val state: String,
    @SerialName("cached_chapters") val cachedChapters: Int = 0,
    @SerialName("total_chapters") val totalChapters: Int = 0,
    @SerialName("last_error") val lastError: String? = null,
)
@Serializable data class KindleAutoPublishStatus(
    val enabled: Boolean,
    val state: String,
    @SerialName("draft_version") val draftVersion: String? = null,
    val changes: Int = 0,
    val blockers: List<KindleAutoPublishBlocker> = emptyList(),
    @SerialName("current_book_id") val currentBookId: String? = null,
    @SerialName("current_book_title") val currentBookTitle: String? = null,
    @SerialName("waiting_since") val waitingSince: String? = null,
    @SerialName("last_publication_id") val lastPublicationId: String? = null,
    @SerialName("last_published_at") val lastPublishedAt: String? = null,
    @SerialName("last_error") val lastError: String? = null,
    @SerialName("next_retry_at") val nextRetryAt: String? = null,
)
@Serializable data class KindleChapter(
    @SerialName("chapter_id") val chapterId: String,
    @SerialName("chapter_index") val chapterIndex: Int,
    val title: String,
    val status: String,
    @SerialName("content_hash") val contentHash: String? = null,
    @SerialName("content_path") val contentPath: String? = null,
    @SerialName("size_bytes") val sizeBytes: Long? = null,
)
@Serializable data class KindleProgressPosition(
    @SerialName("progress_version") val progressVersion: String? = null,
    @SerialName("chapter_id") val chapterId: String,
    @SerialName("chapter_index") val chapterIndex: Int,
    @SerialName("chapter_progress") val chapterProgress: Double,
    @SerialName("device_id") val deviceId: String? = null,
    @SerialName("device_name") val deviceName: String? = null,
    @SerialName("recorded_at") val recordedAt: String? = null,
)
@Serializable data class KindleEpubDescriptor(
    @SerialName("sha256") val sha256: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    val url: String,
    @SerialName("media_type") val mediaType: String = "application/epub+zip",
    @SerialName("binding_version") val bindingVersion: String,
    @SerialName("toc_version") val tocVersion: String,
    @SerialName("source_hash") val sourceHash: String? = null,
)
@Serializable data class KindleBook(
    @SerialName("book_id") val bookId: String,
    val title: String,
    val author: String? = null,
    @SerialName("binding_version") val bindingVersion: String,
    @SerialName("toc_version") val tocVersion: String,
    val chapters: List<KindleChapter>,
    val epub: KindleEpubDescriptor? = null,
    val progress: KindleProgressPosition? = null,
)
@Serializable data class KindleDeletedBook(
    @SerialName("book_id") val bookId: String,
    @SerialName("publication_id") val publicationId: String,
    @SerialName("deleted_at") val deletedAt: String,
)
@Serializable data class KindleBundleDescriptor(
    @SerialName("bundle_id") val bundleId: String,
    val url: String,
    val sha256: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    @SerialName("media_type") val mediaType: String = "application/zip",
)
@Serializable data class KindleBundleFile(
    val path: String,
    val sha256: String,
    @SerialName("size_bytes") val sizeBytes: Long,
)
@Serializable data class KindleBundleManifest(
    @SerialName("protocol_version") val protocolVersion: Int = 1,
    @SerialName("bundle_id") val bundleId: String,
    val files: List<KindleBundleFile>,
)
@Serializable data class KindleSyncResponse(
    @SerialName("protocol_version") val protocolVersion: Int = 1,
    @SerialName("sync_id") val syncId: String? = null,
    @SerialName("from_cursor") val fromCursor: String? = null,
    @SerialName("next_cursor") val nextCursor: String,
    val reset: Boolean,
    @SerialName("publication_id") val publicationId: String? = null,
    val books: List<KindleBook> = emptyList(),
    @SerialName("deleted_books") val deletedBooks: List<KindleDeletedBook> = emptyList(),
    val bundles: List<KindleBundleDescriptor> = emptyList(),
)
@Serializable data class KindleAckRequest(
    @SerialName("sync_id") val syncId: String,
    @SerialName("next_cursor") val nextCursor: String,
    @SerialName("applied_bundle_ids") val appliedBundleIds: List<String> = emptyList(),
)
@Serializable data class KindleAckResponse(
    val acked: Boolean = true,
    @SerialName("next_cursor") val nextCursor: String,
)
@Serializable data class KindleProgressEvent(
    @SerialName("event_id") val eventId: String,
    @SerialName("device_seq") val deviceSeq: String,
    @SerialName("book_id") val bookId: String,
    @SerialName("chapter_id") val chapterId: String,
    @SerialName("chapter_index") val chapterIndex: Int,
    @SerialName("chapter_progress") val chapterProgress: Double,
    @SerialName("binding_version") val bindingVersion: String,
    @SerialName("base_progress_version") val baseProgressVersion: String? = null,
    @SerialName("recorded_at") val recordedAt: String,
)
@Serializable data class KindleProgressRequest(val events: List<KindleProgressEvent>)
@Serializable data class KindleProgressResult(
    @SerialName("event_id") val eventId: String,
    val status: String,
    @SerialName("progress_version") val progressVersion: String? = null,
    @SerialName("conflict_id") val conflictId: String? = null,
    @SerialName("error_code") val errorCode: String? = null,
)
@Serializable data class KindleProgressResponse(val results: List<KindleProgressResult>)
@Serializable data class KindleProgressConflict(
    @SerialName("conflict_id") val conflictId: String,
    @SerialName("book_id") val bookId: String,
    val title: String,
    val current: KindleProgressPosition? = null,
    val candidate: KindleProgressPosition,
    @SerialName("binding_version") val bindingVersion: String? = null,
    @SerialName("event_id") val eventId: String? = null,
    @SerialName("created_at") val createdAt: String,
    val status: String = "unresolved",
    @SerialName("resolved_at") val resolvedAt: String? = null,
    val resolution: String? = null,
    @SerialName("resolved_progress_version") val resolvedProgressVersion: String? = null,
)
@Serializable data class KindleConflictsResponse(val conflicts: List<KindleProgressConflict>)
@Serializable data class KindleConflictResolutionRequest(
    val resolution: String,
    @SerialName("expected_progress_version") val expectedProgressVersion: String? = null,
)
@Serializable data class KindleConflictResolutionResponse(
    @SerialName("conflict_id") val conflictId: String,
    val resolution: String,
    @SerialName("resolved_at") val resolvedAt: String,
    val progress: KindleProgressPosition? = null,
)

@Serializable data class KindlePushDeliverySummary(
    @SerialName("delivery_id") val deliveryId: String,
    @SerialName("book_name") val bookName: String,
    val format: String,
    val state: String,
    @SerialName("file_count") val fileCount: Int,
    @SerialName("total_bytes") val totalBytes: Long,
    @SerialName("target_count") val targetCount: Int,
    @SerialName("delivered_count") val deliveredCount: Int,
    @SerialName("pending_count") val pendingCount: Int = 0,
    @SerialName("canceled_count") val canceledCount: Int = 0,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String,
)
@Serializable data class KindlePushDeliveriesResponse(val deliveries: List<KindlePushDeliverySummary>)

@Serializable data class KindleInboxFile(
    @SerialName("file_id") val fileId: String,
    @SerialName("file_name") val fileName: String,
    @SerialName("content_type") val contentType: String,
    val sha256: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    val url: String,
)
@Serializable data class KindleInboxDelivery(
    @SerialName("delivery_id") val deliveryId: String,
    @SerialName("book_id") val bookId: String,
    val title: String,
    val author: String? = null,
    val format: String,
    @SerialName("created_at") val createdAt: String,
    val files: List<KindleInboxFile>,
)
@Serializable data class KindleInboxResponse(
    @SerialName("protocol_version") val protocolVersion: Int = 1,
    @SerialName("from_cursor") val fromCursor: String? = null,
    @SerialName("next_cursor") val nextCursor: String,
    val reset: Boolean = false,
    val deliveries: List<KindleInboxDelivery> = emptyList(),
)
@Serializable data class KindleInboxAckResult(
    @SerialName("delivery_id") val deliveryId: String,
    val status: String,
    val error: String? = null,
)
@Serializable data class KindleInboxAckRequest(
    val cursor: String,
    val results: List<KindleInboxAckResult> = emptyList(),
)
@Serializable data class KindleInboxAckResponse(
    val acked: Boolean = true,
    val cursor: String,
)

@Serializable data class KindleEpubExport(
    @SerialName("book_id") val bookId: String,
    val title: String,
    val author: String? = null,
    @SerialName("binding_version") val bindingVersion: String,
    @SerialName("toc_version") val tocVersion: String,
    val filename: String,
    val sha256: String,
    @SerialName("size_bytes") val sizeBytes: Long,
)

@Serializable data class KindleUpdateTaskSummary(
    @SerialName("book_id") val bookId: String,
    val title: String,
    @SerialName("binding_version") val bindingVersion: String,
    val state: String,
    @SerialName("last_attempt_at") val lastAttemptAt: String? = null,
    @SerialName("next_due_at") val nextDueAt: String? = null,
    @SerialName("last_error") val lastError: String? = null,
)
@Serializable data class KindleUpdateTasksResponse(val tasks: List<KindleUpdateTaskSummary>)
@Serializable data class KindleUpdateTarget(@SerialName("book_id") val bookId: String)
