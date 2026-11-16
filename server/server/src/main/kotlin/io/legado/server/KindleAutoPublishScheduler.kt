package io.legado.server

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Debounced automatic shelves books independently.
 *
 * Each changed network book becomes visible to Kindle as soon as that book reports a
 * complete text cache. A failed or slow cache for another book only keeps that other
 * book off the shelf and never blocks books that are already ready.
 */
class KindleAutoPublishScheduler(
    private val service: KindleSyncService,
    private val database: Database,
    private val enabled: Boolean = true,
    private val debounceMs: Long = 15_000,
    private val retryDelayMs: Long = 60_000,
    private val scanIntervalMs: Long = 5_000,
    private val planRefreshMs: Long = 60_000,
    private val afterPublish: suspend () -> Unit = {},
    private val now: () -> Instant = Instant::now,
    private val log: (String) -> Unit = {},
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val started = AtomicBoolean(false)
    private val retryRequested = AtomicBoolean(false)

    @Volatile
    private var currentStatus = KindleAutoPublishStatus(
        enabled = enabled,
        state = if (enabled) "observing" else "disabled",
    )

    fun start() {
        if (!enabled || started.getAndSet(true)) return
        scope.launch { runLoop() }
    }

    fun stop() {
        started.set(false)
        scope.cancel()
    }

    fun status(): KindleAutoPublishStatus = currentStatus

    /** Finish the current debounce immediately. Cache readiness remains mandatory. */
    fun retryNow(): KindleAutoPublishStatus {
        if (enabled) retryRequested.set(true)
        return currentStatus
    }

    private suspend fun runLoop() {
        var armedKey: String? = null
        var armedAt = 0L
        val deferredUntil = mutableMapOf<String, Long>()
        val deferredErrors = mutableMapOf<String, String>()
        val failureCounts = mutableMapOf<String, Int>()
        var cachedPlan: KindleAutoPublishPlan? = null
        var cachedPlanAt = 0L

        fun deferFailure(key: String, message: String, currentMillis: Long): Long {
            val failures = (failureCounts[key] ?: 0) + 1
            failureCounts[key] = failures
            val exponent = (failures - 1).coerceAtMost(5)
            val delayMs = minOf(MAX_RETRY_DELAY_MS, retryDelayMs * (1L shl exponent))
            val nextRetryAt = currentMillis + delayMs
            deferredUntil[key] = nextRetryAt
            deferredErrors[key] = message
            return nextRetryAt
        }

        while (scope.isActive) {
            try {
                val force = retryRequested.getAndSet(false)
                if (force) {
                    deferredUntil.clear()
                    deferredErrors.clear()
                    failureCounts.clear()
                    if (armedKey != null) armedAt = now().toEpochMilli() - debounceMs
                }
                val currentMillis = now().toEpochMilli()
                if (force || cachedPlan == null || currentMillis - cachedPlanAt >= planRefreshMs) {
                    cachedPlan = service.autoPublishPlan()
                    cachedPlanAt = currentMillis
                }
                val plan = checkNotNull(cachedPlan)
                val draft = plan.draft
                if (draft.changes.isEmpty()) {
                    armedKey = null
                    deferredUntil.clear()
                    deferredErrors.clear()
                    failureCounts.clear()
                    currentStatus = currentStatus.copy(
                        enabled = true,
                        state = "observing",
                        draftVersion = null,
                        changes = 0,
                        blockers = emptyList(),
                        currentBookId = null,
                        currentBookTitle = null,
                        waitingSince = null,
                        lastError = null,
                        nextRetryAt = null,
                    )
                    delay(scanIntervalMs)
                    continue
                }

                val blockers = cacheBlockers(plan.targets)
                val blockedIds = blockers.mapTo(hashSetOf()) { it.bookId }
                val readyTargets = plan.targets.filter { it.bookId !in blockedIds }
                if (readyTargets.isEmpty()) {
                    armedKey = null
                    val hardBlocked = blockers.any { it.state == "failed" || it.state == "paused" }
                    currentStatus = currentStatus.copy(
                        enabled = true,
                        state = if (hardBlocked) "blocked" else "caching",
                        draftVersion = draft.draftVersion,
                        changes = draft.changes.size,
                        blockers = blockers,
                        currentBookId = null,
                        currentBookTitle = null,
                        waitingSince = null,
                        lastError = null,
                        nextRetryAt = null,
                    )
                    delay(scanIntervalMs)
                    continue
                }

                fun key(target: KindleAutoPublishTarget): String =
                    "${draft.draftVersion}\u0000${target.bookId}"

                val dueTargets = readyTargets.filter { target ->
                    force || currentMillis >= (deferredUntil[key(target)] ?: 0L)
                }
                if (dueTargets.isEmpty()) {
                    armedKey = null
                    val nextRetryAt = readyTargets.minOf { deferredUntil[key(it)] ?: Long.MAX_VALUE }
                    val firstError = readyTargets.firstNotNullOfOrNull { deferredErrors[key(it)] }
                    currentStatus = currentStatus.copy(
                        state = "failed",
                        draftVersion = draft.draftVersion,
                        changes = draft.changes.size,
                        blockers = blockers,
                        currentBookId = null,
                        currentBookTitle = null,
                        waitingSince = null,
                        lastError = firstError,
                        nextRetryAt = Instant.ofEpochMilli(nextRetryAt).toString(),
                    )
                    delay(scanIntervalMs)
                    continue
                }

                val candidate = dueTargets.first()
                val candidateKey = key(candidate)
                if (armedKey != candidateKey) {
                    armedKey = candidateKey
                    armedAt = currentMillis
                }
                if (force || currentMillis - armedAt >= debounceMs) {
                    currentStatus = currentStatus.copy(
                        state = "publishing",
                        draftVersion = draft.draftVersion,
                        changes = draft.changes.size,
                        blockers = blockers,
                        currentBookId = candidate.bookId,
                        currentBookTitle = candidate.title,
                        waitingSince = Instant.ofEpochMilli(armedAt).toString(),
                        lastError = null,
                        nextRetryAt = null,
                    )
                    try {
                        val publication = service.publishSelectedBooks(
                            requestId = "auto_" + UUID.randomUUID().toString().replace("-", ""),
                            draftVersion = draft.draftVersion,
                            bookIds = listOf(candidate.bookId),
                            updateDueNow = true,
                        )
                        armedKey = null
                        cachedPlan = null
                        failureCounts.clear()
                        deferredUntil.clear()
                        deferredErrors.clear()
                        currentStatus = currentStatus.copy(
                            state = "observing",
                            draftVersion = null,
                            changes = (draft.changes.size - 1).coerceAtLeast(0),
                            blockers = blockers,
                            currentBookId = null,
                            currentBookTitle = null,
                            waitingSince = null,
                            lastPublicationId = publication.publicationId,
                            lastPublishedAt = publication.publishedAt,
                            lastError = null,
                            nextRetryAt = null,
                        )
                        log("automatic shelf completed: ${candidate.title}")
                        try {
                            afterPublish()
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: Throwable) {
                            log("automatic shelf cache refresh failed: ${error.message}")
                        }
                    } catch (error: KindleSyncException) {
                        if (error.code == "draft_conflict") {
                            armedKey = null
                            cachedPlan = null
                            currentStatus = currentStatus.copy(
                                state = "observing",
                                draftVersion = draft.draftVersion,
                                changes = draft.changes.size,
                                blockers = blockers,
                                currentBookId = null,
                                currentBookTitle = null,
                                lastError = null,
                            )
                        } else {
                            val nextRetryAt = deferFailure(
                                candidateKey,
                                error.message ?: error.code,
                                now().toEpochMilli(),
                            )
                            armedKey = null
                            currentStatus = currentStatus.copy(
                                state = "failed",
                                draftVersion = draft.draftVersion,
                                changes = draft.changes.size,
                                blockers = blockers,
                                currentBookId = candidate.bookId,
                                currentBookTitle = candidate.title,
                                lastError = error.message ?: error.code,
                                nextRetryAt = Instant.ofEpochMilli(nextRetryAt).toString(),
                            )
                            log("automatic shelf failed: ${candidate.title}, ${error.code}: ${error.message}")
                        }
                    } catch (error: Throwable) {
                        val nextRetryAt = deferFailure(
                            candidateKey,
                            error.message ?: error.javaClass.simpleName,
                            now().toEpochMilli(),
                        )
                        armedKey = null
                        currentStatus = currentStatus.copy(
                            state = "failed",
                            draftVersion = draft.draftVersion,
                            changes = draft.changes.size,
                            blockers = blockers,
                            currentBookId = candidate.bookId,
                            currentBookTitle = candidate.title,
                            lastError = error.message ?: error.javaClass.simpleName,
                            nextRetryAt = Instant.ofEpochMilli(nextRetryAt).toString(),
                        )
                        log("automatic shelf failed: ${candidate.title}, ${error.message}")
                    }
                } else {
                    currentStatus = currentStatus.copy(
                        state = "waiting",
                        draftVersion = draft.draftVersion,
                        changes = draft.changes.size,
                        blockers = blockers,
                        currentBookId = candidate.bookId,
                        currentBookTitle = candidate.title,
                        waitingSince = Instant.ofEpochMilli(armedAt).toString(),
                        lastError = null,
                        nextRetryAt = null,
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                currentStatus = currentStatus.copy(
                    state = "failed",
                    lastError = error.message ?: error.javaClass.simpleName,
                )
                log("automatic shelf scan failed: ${error.message}")
            }
            delay(scanIntervalMs)
        }
    }

    private fun cacheBlockers(targets: List<KindleAutoPublishTarget>): List<KindleAutoPublishBlocker> =
        targets.mapNotNull { target ->
            if (target.operation == "delete_book" || target.local) return@mapNotNull null
            val readiness = database.bookCacheReadiness(target.sourceId, target.bookUrl)
            val ready = readiness?.state == "ready" &&
                readiness.totalChapters > 0 &&
                readiness.fullBook
            val state = if (readiness?.state == "ready" && !ready) "partial" else readiness?.state ?: "not_started"
            if (ready) null else KindleAutoPublishBlocker(
                bookId = target.bookId,
                title = target.title,
                state = state,
                cachedChapters = readiness?.cachedChapters ?: 0,
                totalChapters = readiness?.totalChapters ?: 0,
                lastError = readiness?.lastError,
            )
        }

    private companion object {
        const val MAX_RETRY_DELAY_MS = 30L * 60 * 1000
    }
}
