package io.legado.server

import java.util.concurrent.ConcurrentHashMap

/**
 * Android `io.legado.app.help.ConcurrentRateLimiter` 的等价实现。
 *
 * 语义逐字对齐：
 * - `concurrentRate` 形态为 `次数/毫秒`（如 `2/1000`），或单个整数（表示 `1/该值` 毫秒）；
 * - 空、`0`、非法值 ⇒ 不限流；
 * - 同一书源在一个窗口内最多放行 `次数` 次；窗口从**放行时**开始计时，
 *   超出配额时等待到窗口结束再重试（Android 在 suspend/blocking 两个变体里都是等待重试）。
 *
 * 与 Android 的差异：Android 的等待没有上限（协程里可被取消，阻塞版会一直睡），
 * 服务端对同步执行线程加了一个上限，超时抛错而不是无限占用工作线程。
 */
internal object SourceRateLimiter {
    private const val MAX_WAIT_MS = 15_000L

    private data class Record(
        var time: Long,
        var accessLimit: Int,
        var interval: Long,
        var frequency: Int,
    )

    private val records = ConcurrentHashMap<String, Record>()

    /** Android `updateConcurrentRate`：源被编辑后立即生效（这里每次请求都重算）。 */
    fun acquire(sourceKey: String, concurrentRate: String?) {
        val (accessLimit, interval) = parse(concurrentRate) ?: return
        val deadline = System.nanoTime() + MAX_WAIT_MS * 1_000_000
        while (true) {
            val record = records.computeIfAbsent(sourceKey) {
                Record(System.currentTimeMillis(), accessLimit, interval.toLong(), 0)
            }
            val waitMs = synchronized(record) {
                record.accessLimit = accessLimit
                record.interval = interval.toLong()
                val now = System.currentTimeMillis()
                val nextTime = record.time + record.interval
                when {
                    // 窗口已过：重新开始计时并放行
                    now >= nextTime -> {
                        record.time = now
                        record.frequency = 1
                        0L
                    }
                    record.frequency < record.accessLimit -> {
                        record.frequency++
                        0L
                    }
                    else -> nextTime - now
                }
            }
            if (waitMs <= 0) return
            if (System.nanoTime() >= deadline) {
                throw RuleExecutionException("书源并发率限制：等待已超过 ${MAX_WAIT_MS}ms")
            }
            runCatching { Thread.sleep(waitMs.coerceAtLeast(1)) }
            if (Thread.currentThread().isInterrupted) {
                throw RuleExecutionException("书源并发率限制等待被中断")
            }
        }
    }

    /** 返回 `accessLimit to intervalMs`；不限流返回 null。 */
    private fun parse(concurrentRate: String?): Pair<Int, Int>? {
        val text = concurrentRate?.trim().orEmpty()
        if (text.isEmpty() || text == "0") return null
        val rateIndex = text.indexOf("/")
        val parsed = if (rateIndex > 0) {
            val limit = text.substring(0, rateIndex).toIntOrNull() ?: return null
            val interval = text.substring(rateIndex + 1).toIntOrNull() ?: return null
            limit to interval
        } else {
            1 to (text.toIntOrNull() ?: return null)
        }
        val (limit, interval) = parsed
        if (limit <= 0 || interval <= 0) return null
        return parsed
    }
}
