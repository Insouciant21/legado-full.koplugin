package io.legado.server

import java.security.MessageDigest

/**
 * 字体混淆（`queryTTF` / `replaceFont`）的服务端实现。
 *
 * Android 用 `QueryTTF`（本目录下的同名 Java 类，**逐字取回 Android 实现**）解析 TTF 的
 * `cmap`/`loca`/`glyf`/`maxp` 表，建立两张对照表：
 * - Unicode → 轮廓数据（`unicodeToGlyph`）；
 * - 轮廓数据 → Unicode（`glyphToUnicode`）。
 *
 * 于是「换过字体的正文」可以按**轮廓**（而不是字形）在错误字体与正确字体之间对照出真正的字：
 * `replaceFont(text, errorTTF, correctTTF, filter)` 正是这个反查。
 *
 * 解析结果按内容哈希缓存在**进程内**（Android 用 `AppCacheManager`，语义相同：同一个字体只解析一次）。
 * 服务端没有持久化需求，因此用有界 LRU，避免书源拿不同字体把内存吃穿。
 */
internal object QueryTtf {
    /** 同时缓存的字体解析结果上限（Android 是磁盘缓存，无上限；服务端必须有界）。 */
    private const val MAX_CACHE_ENTRIES = 24

    private val cache = object : LinkedHashMap<String, QueryTTF>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, QueryTTF>?): Boolean =
            size > MAX_CACHE_ENTRIES
    }

    fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    fun sha256(text: String): String = sha256(text.toByteArray(Charsets.UTF_8))

    /** 命中缓存则直接复用；未命中按 [key] 缓存解析结果。 */
    fun parse(key: String?, bytes: ByteArray): QueryTTF {
        if (key != null) {
            synchronized(cache) { cache[key] }?.let { return it }
        }
        val parsed = QueryTTF(bytes)
        if (key != null) {
            synchronized(cache) { cache[key] = parsed }
        }
        return parsed
    }

    /**
     * Android `JsExtensions.replaceFont`：把 [text] 里「按错误字体取出的轮廓」反查回正确字体的字符。
     *
     * - 空白字符原样保留（`isBlankUnicode`）；
     * - `errorQueryTTF.getGlyfIdByUnicode(code) == 0` 视为轮廓指向保留索引 0 ⇒ 当作「没有轮廓」；
     * - [filter] = true 时**删掉**在错误字体里找不到轮廓的字符，否则原样保留；
     * - 反查不到（返回 0）时保留原字符。
     */
    fun replaceFont(text: String?, errorTtf: QueryTTF?, correctTtf: QueryTTF?, filter: Boolean): String {
        if (text == null) return ""
        if (errorTtf == null || correctTtf == null) return text
        // 不能用 toCharArray：有些字（emoji 等）占多个 code point 单位
        val contentArray = text.toStringArray()
        val intArray = IntArray(1)
        contentArray.forEachIndexed { index, value ->
            val oldCode = value.codePointAt(0)
            // 忽略正常的空白字符
            if (errorTtf.isBlankUnicode(oldCode)) return@forEachIndexed
            var glyf = errorTtf.getGlyfByUnicode(oldCode)
            if (errorTtf.getGlyfIdByUnicode(oldCode) == 0) glyf = null // 轮廓数据指向保留索引 0
            if (filter && glyf == null) {
                contentArray[index] = ""
                return@forEachIndexed
            }
            val code = correctTtf.getUnicodeByGlyf(glyf)
            if (code != 0) {
                intArray[0] = code
                contentArray[index] = String(intArray, 0, 1)
            }
        }
        return contentArray.joinToString("")
    }

    /** Android `CharSequence.toStringArray()`：按 code point 拆字符（emoji 不被劈开）。 */
    private fun CharSequence.toStringArray(): Array<String> = try {
        var codePointIndex = 0
        Array(Character.codePointCount(this, 0, length)) {
            val start = codePointIndex
            codePointIndex = Character.offsetByCodePoints(this, start, 1)
            substring(start, codePointIndex)
        }
    } catch (_: Exception) {
        Array(length) { index -> this[index].toString() }
    }
}
