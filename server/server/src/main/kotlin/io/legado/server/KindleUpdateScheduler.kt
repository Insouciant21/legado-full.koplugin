package io.legado.server

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Durable publication refresh loop. Task state lives in SQLite, so restart resumes due/paused/retried
 * work without conflating the immutable published binding with current draft source edits.
 */
class KindleUpdateScheduler(
    private val service: KindleSyncService,
    private val runner: RuleRunner,
    private val scanIntervalMs: Long = 60_000,
    private val log: (String) -> Unit = {},
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val started = AtomicBoolean(false)
    private val refreshing = AtomicBoolean(false)

    fun start() {
        if (started.getAndSet(true)) return
        scope.launch {
            while (isActive) {
                runCatching { refreshDueNow() }.onFailure { error ->
                    log("Kindle publication update scan failed: ${error.message}")
                }
                delay(scanIntervalMs)
            }
        }
    }

    fun stop() {
        started.set(false)
        refreshing.set(false)
        scope.cancel()
    }

    suspend fun refreshDueNow(): Int {
        if (!started.get() || !refreshing.compareAndSet(false, true)) return 0
        try {
            val due = withContext(Dispatchers.IO) { service.duePublicationUpdateBookIds() }
            due.forEach { bookId ->
                withContext(Dispatchers.IO) {
                    runCatching {
                        service.refreshPublication(bookId, runner)
                        service.prepareMissingEpubs(listOf(bookId))
                    }
                        .onFailure { error -> log("Kindle publication update failed: $bookId, error=${error.message}") }
                }
            }
            return due.size
        } finally {
            refreshing.set(false)
        }
    }
}
