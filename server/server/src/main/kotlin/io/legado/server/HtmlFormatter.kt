package io.legado.server

import java.util.regex.Pattern

/**
 * Android `io.legado.app.utils.HtmlFormatter` 的等价实现。
 *
 * 书源在三个地方依赖它，语义必须一致：
 * - `java.htmlFormat`（JS 桥接，[formatKeepImg]）；
 * - 书籍简介（`BookInfo`，[format]）：Android 会剥掉全部标签，只保留文本；
 * - 正文净化（`BookContent`）走的是 KOReader/前端侧的处理，不在这里。
 *
 * 与 Android 的唯一差异：Android 的 `formatKeepImg` 接受一个 redirectUrl 用来把
 * 图片地址补成绝对地址；服务端只在 `java.htmlFormat` 场景调用它，而该场景 Android
 * 传的是 null（`NetworkUtils.getAbsoluteURL(null, url)` 原样返回），因此这里不提供该参数。
 */
internal object HtmlFormatter {
    private val nbspRegex = Regex("(&nbsp;)+")
    private val espRegex = Regex("(&ensp;|&emsp;)")
    private val noPrintRegex = Regex("(&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D)")
    private val wrapHtmlRegex = Regex("</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>")
    private val commentRegex = Regex("<!--[^>]*-->")
    private val notImgHtmlRegex = Regex("</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>")
    private val otherHtmlRegex = Regex("</?[a-zA-Z]+(?=[ >])[^<>]*>")
    private val indent1Regex = Regex("\\s*\\n+\\s*")
    private val indent2Regex = Regex("^[\\n\\s]+")
    private val lastRegex = Regex("[\\n\\s]+$")

    /** 模板型 src 尾部的 `,{...}` URL 选项起点（Android `AnalyzeUrl.paramPattern`）。 */
    private val paramPattern: Pattern = Pattern.compile("\\s*,\\s*(?=\\{)")

    private val formatImagePattern: Pattern = Pattern.compile(
        "<img[^>]*\\ssrc\\s*=\\s*['\"]([^'\"{>]*\\{(?:[^{}]|\\{[^}>]+\\})+\\})['\"][^>]*>" +
            "|<img[^>]*\\sdata-(?:src|original|srcset)\\s*=\\s*['\"]([^'\">]+)['\"][^>]*>" +
            "|<img[^>]*\\ssrc\\s*=\\s*\"([^\">]+)\"[^>]*>" +
            "|<img[^>]*\\s(?:data-[^=>]*|src)=\\s*['\"]([^'\">]*)['\"][^>]*>",
        Pattern.CASE_INSENSITIVE,
    )

    /**
     * Android `format(html, otherRegex = otherHtmlRegex)`：段落标签折成换行、
     * 其余标签清空、连续空白归一成两个全角空格缩进。
     */
    fun format(html: String?, otherRegex: Regex = otherHtmlRegex): String {
        if (html == null) return ""
        return html
            .replace(nbspRegex, " ")
            .replace(espRegex, " ")
            .replace(noPrintRegex, "")
            .replace(wrapHtmlRegex, "\n")
            .replace(commentRegex, "")
            .replace(otherRegex, "")
            .replace(indent1Regex, "\n　　")
            .replace(indent2Regex, "　　")
            .replace(lastRegex, "")
    }

    /** Android `formatKeepImg(html, redirectUrl = null)`：剥标签但保留 img，并归一化其 src。 */
    fun formatKeepImg(html: String?): String {
        if (html == null) return ""
        val kept = format(html, notImgHtmlRegex)
        val matcher = formatImagePattern.matcher(kept)
        var appendPos = 0
        val sb = StringBuilder()
        while (matcher.find()) {
            // Android 在拼回 <img> 前会走 NetworkUtils.getAbsoluteURL(null, src)，
            // 对空 base 而言就是 trim；模板型 src 的 `,{...}` 选项要保留在末尾。
            var param = ""
            val src = matcher.group(1)?.let { candidate ->
                val urlMatcher = paramPattern.matcher(candidate)
                if (urlMatcher.find()) {
                    param = "," + candidate.substring(urlMatcher.end())
                    candidate.substring(0, urlMatcher.start())
                } else {
                    candidate
                }
            } ?: matcher.group(2) ?: matcher.group(3) ?: matcher.group(4) ?: ""
            sb.append(kept, appendPos, matcher.start())
                .append("<img src=\"")
                .append(src.trim())
                .append(param)
                .append("\">")
            appendPos = matcher.end()
        }
        sb.append(kept, appendPos, kept.length)
        return sb.toString()
    }
}
