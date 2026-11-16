package io.legado.server

import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.w3c.dom.Element
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Android 备份恢复所需的最小外部 WebDAV 客户端。
 *
 * 与手机端一致：
 * - 根地址末尾补 `/` 后追加子目录；
 * - `PROPFIND Depth: 1` 列出备份；
 * - HTTP Basic 认证；
 * - 只展示文件名以 `backup` 开头的 ZIP；
 * - `GET` 下载后交给统一的 [BackupImporter]。
 *
 * 这里不创建远端目录、不上传，也不把凭据持久化到 Server。
 */
internal class ExternalWebDavClient(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .callTimeout(90, TimeUnit.SECONDS)
        .followRedirects(true)
        .build(),
) {
    fun list(config: ExternalWebDavConfig): ExternalWebDavListResponse {
        val root = rootUrl(config)
        val request = Request.Builder()
            .url(root)
            .header("Depth", "1")
            .applyAuth(config)
            .method("PROPFIND", PROPFIND_BODY.toRequestBody(XML_MEDIA_TYPE))
            .build()

        client.newCall(request).execute().use { response ->
            if (response.code !in 200..299) {
                checkResponse(response.code, response.message, response.body.string())
            }
            val body = response.body
            val responseUrl = response.request.url
            val xml = body.byteStream().use { it.readLimited(MAX_DIRECTORY_XML_BYTES) }
            val entries = parseMultiStatus(xml)
            val rootSegments = responseUrl.pathSegments.filter(String::isNotEmpty)
            val files = entries.mapNotNull { entry ->
                val target = responseUrl.resolve(entry.href)
                    ?: throw ExternalWebDavException("WebDAV 返回了无效文件地址")
                if (!sameOrigin(responseUrl, target) || !hasPathPrefix(target, rootSegments)) return@mapNotNull null
                if (target.pathSegments.filter(String::isNotEmpty) == rootSegments) return@mapNotNull null
                if (entry.directory) return@mapNotNull null
                val name = entry.displayName?.takeIf(String::isNotBlank)
                    ?: target.pathSegments.lastOrNull(String::isNotBlank)
                    ?: return@mapNotNull null
                if (!name.startsWith("backup") || !name.endsWith(".zip", ignoreCase = true)) {
                    return@mapNotNull null
                }
                ExternalWebDavBackup(
                    name = name,
                    href = target.toString(),
                    size = entry.size.coerceAtLeast(0L),
                    modifiedAt = entry.modifiedAt,
                )
            }.distinctBy { it.href }
                .sortedWith { left, right -> compareNatural(right.name, left.name) }

            return ExternalWebDavListResponse(root.toString(), files)
        }
    }

    /**
     * 下载选中备份到 Server 临时目录。调用方必须在 `finally` 中删除返回值。
     */
    fun download(config: ExternalWebDavConfig, href: String): Path {
        val root = rootUrl(config)
        val target = href.trim().toHttpUrlOrNull()
            ?: throw ExternalWebDavException("备份文件地址无效")
        val rootSegments = root.pathSegments.filter(String::isNotEmpty)
        if (!sameOrigin(root, target) || !hasPathPrefix(target, rootSegments)) {
            throw ExternalWebDavException("备份文件不在当前 WebDAV 目录中")
        }
        val name = target.pathSegments.lastOrNull(String::isNotBlank).orEmpty()
        if (!name.startsWith("backup") || !name.endsWith(".zip", ignoreCase = true)) {
            throw ExternalWebDavException("只支持导入 backup 开头的 ZIP 备份")
        }

        val request = Request.Builder()
            .url(target)
            .applyAuth(config)
            .get()
            .build()
        val temp = Files.createTempFile("legado-external-backup-", ".zip")
        try {
            client.newCall(request).execute().use { response ->
                if (response.code !in 200..299) {
                    checkResponse(response.code, response.message, response.body.string())
                }
                val body = response.body
                val declared = body.contentLength()
                if (declared > MAX_BACKUP_ZIP_BYTES) {
                    throw ExternalWebDavException("备份 ZIP 超过 256 MiB，已拒绝")
                }
                body.byteStream().use { input ->
                    Files.newOutputStream(temp).use { output ->
                        val copied = copyLimited(input, output, MAX_BACKUP_ZIP_BYTES)
                        if (copied == 0L) throw ExternalWebDavException("WebDAV 返回了空备份")
                    }
                }
            }
            return temp
        } catch (error: Throwable) {
            Files.deleteIfExists(temp)
            throw error
        }
    }

    private fun rootUrl(config: ExternalWebDavConfig): HttpUrl {
        val raw = config.url.trim().replaceFirst(Regex("^davs://", RegexOption.IGNORE_CASE), "https://")
            .replaceFirst(Regex("^dav://", RegexOption.IGNORE_CASE), "http://")
        if (raw.isBlank()) throw ExternalWebDavException("WebDAV 地址不能为空")
        val base = raw.toHttpUrlOrNull() ?: throw ExternalWebDavException("WebDAV 地址格式无效")
        if (base.query != null || base.fragment != null) {
            throw ExternalWebDavException("WebDAV 地址不能包含查询参数或锚点")
        }
        val builder = base.newBuilder()
        val segments = config.directory.trim('/').split('/')
            .map(String::trim)
            .filter(String::isNotEmpty)
        if (segments.any { it == "." || it == ".." || it.contains('\\') || it.contains('\u0000') }) {
            throw ExternalWebDavException("WebDAV 子目录无效")
        }
        segments.forEach(builder::addPathSegment)
        return builder.build()
    }

    private fun Request.Builder.applyAuth(config: ExternalWebDavConfig): Request.Builder {
        val username = config.username
        val password = config.password
        if (username.isEmpty() && password.isEmpty()) return this
        if (username.isEmpty() || password.isEmpty()) {
            throw ExternalWebDavException("WebDAV 用户名和密码需要同时填写")
        }
        // 与 Android OkHttp Basic 默认值一致。
        return header("Authorization", Credentials.basic(username, password, Charsets.ISO_8859_1))
    }

    private fun checkResponse(code: Int, message: String, body: String?) {
        if (code in 200..299) return
        if (code == 401) throw ExternalWebDavException("WebDAV 认证失败，请检查用户名和密码")
        val detail = body?.trim()?.takeIf(String::isNotEmpty)?.take(500)
        throw ExternalWebDavException(
            buildString {
                append("WebDAV 请求失败：HTTP ").append(code)
                if (message.isNotBlank()) append(' ').append(message)
                if (detail != null) append(" · ").append(detail)
            },
        )
    }

    private fun parseMultiStatus(xml: ByteArray): List<DavEntry> {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
            setFeature("http://xml.org/sax/features/external-general-entities", false)
            setFeature("http://xml.org/sax/features/external-parameter-entities", false)
            setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "")
            setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "")
        }
        val document = ByteArrayInputStream(xml).use { factory.newDocumentBuilder().parse(it) }
        val responseNodes = document.getElementsByTagNameNS("DAV:", "response")
        val responses = if (responseNodes.length > 0) {
            (0 until responseNodes.length).map { responseNodes.item(it) as Element }
        } else {
            document.documentElement.childElements().filter { it.localNameOrNodeName() == "response" }
        }
        return responses.mapNotNull { response ->
            val href = response.firstDescendantElement("href")?.textContent?.trim()
                ?.takeIf(String::isNotEmpty)
                ?: return@mapNotNull null
            val resourceType = response.firstDescendantElement("resourcetype")
            val contentType = response.firstDescendantElement("getcontenttype")?.textContent?.trim().orEmpty()
            val directory = resourceType?.childElements()?.any {
                it.localNameOrNodeName() == "collection"
            } == true || contentType.equals("httpd/unix-directory", ignoreCase = true)
            DavEntry(
                href = href,
                displayName = response.firstDescendantElement("displayname")?.textContent?.trim(),
                size = response.firstDescendantElement("getcontentlength")?.textContent?.trim()?.toLongOrNull() ?: 0L,
                modifiedAt = response.firstDescendantElement("getlastmodified")?.textContent?.trim()
                    ?.let(::parseHttpDate) ?: 0L,
                directory = directory,
            )
        }
    }

    private fun parseHttpDate(value: String): Long =
        runCatching {
            ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli()
        }.getOrDefault(0L)

    private fun sameOrigin(left: HttpUrl, right: HttpUrl): Boolean =
        left.scheme.equals(right.scheme, ignoreCase = true) &&
            left.host.equals(right.host, ignoreCase = true) &&
            left.port == right.port

    private fun hasPathPrefix(target: HttpUrl, rootSegments: List<String>): Boolean {
        val targetSegments = target.pathSegments.filter(String::isNotEmpty)
        return targetSegments.size >= rootSegments.size &&
            targetSegments.subList(0, rootSegments.size) == rootSegments
    }

    private fun compareNatural(left: String, right: String): Int {
        var leftIndex = 0
        var rightIndex = 0
        while (leftIndex < left.length && rightIndex < right.length) {
            val leftDigit = left[leftIndex].isDigit()
            val rightDigit = right[rightIndex].isDigit()
            if (leftDigit && rightDigit) {
                val leftEnd = left.indexOfFirst(leftIndex) { !it.isDigit() }.let { if (it < 0) left.length else it }
                val rightEnd = right.indexOfFirst(rightIndex) { !it.isDigit() }.let { if (it < 0) right.length else it }
                val leftNumber = left.substring(leftIndex, leftEnd).trimStart('0').ifEmpty { "0" }
                val rightNumber = right.substring(rightIndex, rightEnd).trimStart('0').ifEmpty { "0" }
                val numberCompare = leftNumber.length.compareTo(rightNumber.length)
                    .takeIf { it != 0 }
                    ?: leftNumber.compareTo(rightNumber)
                if (numberCompare != 0) return numberCompare
                leftIndex = leftEnd
                rightIndex = rightEnd
                continue
            }
            val charCompare = left[leftIndex].lowercaseChar().compareTo(right[rightIndex].lowercaseChar())
            if (charCompare != 0) return charCompare
            leftIndex++
            rightIndex++
        }
        return (left.length - leftIndex).compareTo(right.length - rightIndex)
    }

    private inline fun String.indexOfFirst(start: Int, predicate: (Char) -> Boolean): Int {
        for (index in start until length) if (predicate(this[index])) return index
        return -1
    }

    private fun Element.firstDescendantElement(name: String): Element? {
        val nodes = getElementsByTagName("*")
        for (index in 0 until nodes.length) {
            val element = nodes.item(index) as? Element ?: continue
            if (element.localNameOrNodeName() == name) return element
        }
        return null
    }

    private fun Element.childElements(): List<Element> {
        val result = mutableListOf<Element>()
        var child = firstChild
        while (child != null) {
            if (child is Element) result += child
            child = child.nextSibling
        }
        return result
    }

    private fun Element.localNameOrNodeName(): String = localName ?: nodeName.substringAfter(':')

    private fun InputStream.readLimited(maxBytes: Long): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val copied = copyLimited(this, output, maxBytes)
        if (copied == 0L) throw ExternalWebDavException("WebDAV 返回了空响应")
        return output.toByteArray()
    }

    private fun copyLimited(input: InputStream, output: OutputStream, maxBytes: Long): Long {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            total += count
            if (total > maxBytes) throw ExternalWebDavException("文件超过允许大小，已拒绝")
            output.write(buffer, 0, count)
        }
        return total
    }

    private data class DavEntry(
        val href: String,
        val displayName: String?,
        val size: Long,
        val modifiedAt: Long,
        val directory: Boolean,
    )

    companion object {
        internal const val MAX_BACKUP_ZIP_BYTES = 256L * 1024L * 1024L
        private const val MAX_DIRECTORY_XML_BYTES = 8L * 1024L * 1024L
        private val XML_MEDIA_TYPE = "application/xml; charset=utf-8".toMediaType()
        private const val PROPFIND_BODY = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:">
              <d:prop>
                <d:displayname/>
                <d:resourcetype/>
                <d:getcontentlength/>
                <d:getcontenttype/>
                <d:getlastmodified/>
              </d:prop>
            </d:propfind>
        """
    }
}

internal class ExternalWebDavException(message: String) : Exception(message)
