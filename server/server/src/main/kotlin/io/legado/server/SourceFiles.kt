package io.legado.server

import com.github.junrar.Archive as RarArchive
import org.apache.commons.compress.archivers.sevenz.SevenZFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.charset.Charset
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

/**
 * 书源脚本的文件与压缩包能力（Android `JsExtensions` 文件族 + `ArchiveUtils`）。
 *
 * Android 把这些文件都放在 `appCtx.externalCache` 下，`getFile(path)` 用相对路径解析；
 * 服务端对应 `<data>/source_cache`：
 * - 相对路径以该根目录解析；
 * - 压缩包解压产物与 Android 同名同结构：`ArchiveTemp/<md5_16(压缩包文件名)>/`。
 *
 * 与 Android 的**有意差异**（仅一处，安全收紧）：Android 的越界校验只要求落在
 * externalCache 的父目录之内（`../` 可以写出去），这里要求必须落在根目录内。
 */
internal class SourceFileStore(private val root: Path) {
    /** Android `FileUtils.getCachePath()` 的等价物（下载产物被指到该根下）。 */
    val cachePath: String get() = root.toString()

    fun resolve(path: String): Path {
        val relative = path.trim().removePrefix("/")
        val resolved = root.resolve(relative).normalize()
        if (!resolved.startsWith(root.normalize())) {
            throw SecurityException("非法路径")
        }
        return resolved
    }

    fun exists(path: String): Boolean = Files.exists(resolve(path))

    fun isDirectory(path: String): Boolean = Files.isDirectory(resolve(path))

    fun readBytes(path: String): ByteArray? {
        val file = resolve(path)
        if (!Files.isRegularFile(file)) return null
        return Files.readAllBytes(file)
    }

    fun readText(path: String, charsetName: String? = null): String {
        val bytes = readBytes(path) ?: return ""
        if (!charsetName.isNullOrBlank()) {
            return runCatching { String(bytes, Charset.forName(charsetName)) }.getOrDefault("")
        }
        return LocalBookParser.decodeText(bytes)
    }

    fun writeBytes(path: String, bytes: ByteArray): String {
        val file = resolve(path)
        file.parent?.let { Files.createDirectories(it) }
        Files.write(file, bytes)
        return path
    }

    fun delete(path: String): Boolean {
        val file = resolve(path)
        if (!Files.exists(file)) return false
        if (Files.isDirectory(file)) {
            Files.walk(file).use { stream ->
                stream.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
            }
            return true
        }
        return Files.deleteIfExists(file)
    }

    fun listFiles(path: String): List<Path> {
        val folder = resolve(path)
        if (!Files.isDirectory(folder)) return emptyList()
        Files.list(folder).use { stream -> return stream.toList() }
    }

    /** 与 Android `FileUtils.getCachePath()` 一致的相对路径（含前导 `/`）。 */
    fun relativePath(path: Path): String = "/" + root.relativize(path).toString().replace('\\', '/')

    /**
     * Android `ArchiveUtils.deCompress`：按压缩包名解压到
     * `<root>/ArchiveTemp/<md5_16(文件名)>/`，返回相对目录（无前导 `/`）。
     */
    fun extractArchive(archiveRelativePath: String): String {
        val archive = resolve(archiveRelativePath)
        if (!Files.isRegularFile(archive)) throw IllegalArgumentException("压缩包不存在: $archiveRelativePath")
        val folderName = md5Encode16(archive.fileName.toString())
        val target = root.resolve(TEMP_FOLDER_NAME).resolve(folderName)
        if (Files.exists(target)) delete(root.relativize(target).toString())
        Files.createDirectories(target)
        extractInto(archive, target)
        return "$TEMP_FOLDER_NAME/$folderName"
    }

    /**
     * 从压缩包字节里取出单个条目（Android `getZip/Rar/7zByteArrayContent`）：
     * 按魔数识别格式，条目名精确匹配。
     */
    fun readEntryFromBytes(bytes: ByteArray, entryPath: String): ByteArray? {
        if (bytes.isEmpty()) return null
        return when {
            bytes.size >= 2 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte() ->
                readZipEntry(ByteArrayInputStream(bytes), entryPath)
            isRar(bytes) -> runCatching {
                RarArchive(ByteArrayInputStream(bytes)).use { archive ->
                    archive.fileHeaders.firstOrNull { !it.isDirectory && it.fileNameString == entryPath }
                        ?.let { header ->
                            val output = ByteArrayOutputStream()
                            archive.extractFile(header, output)
                            output.toByteArray()
                        }
                }
            }.getOrNull()
            isSevenZ(bytes) -> {
                val temp = Files.createTempFile(root, "archive-", ".7z")
                try {
                    Files.write(temp, bytes)
                    readSevenZEntry(temp, entryPath)
                } finally {
                    Files.deleteIfExists(temp)
                }
            }
            else -> null
        }
    }

    private fun extractInto(archive: Path, target: Path) {
        val name = archive.fileName.toString().lowercase()
        when {
            name.endsWith(".zip") -> extractZip(Files.newInputStream(archive), target)
            name.endsWith(".7z") -> extractSevenZ(archive, target)
            name.endsWith(".rar") -> extractRar(archive, target)
            else -> {
                val bytes = Files.readAllBytes(archive)
                when {
                    isSevenZ(bytes) -> extractSevenZ(archive, target)
                    isRar(bytes) -> extractRar(archive, target)
                    else -> extractZip(ByteArrayInputStream(bytes), target)
                }
            }
        }
    }

    private fun extractZip(input: java.io.InputStream, target: Path) {
        ZipInputStream(input).use { zip ->
            var entry: ZipEntry? = zip.nextEntry
            while (entry != null) {
                writeEntry(target, entry.name, zip, entry.isDirectory)
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
    }

    private fun extractSevenZ(archive: Path, target: Path) {
        SevenZFile.builder().setPath(archive).get().use { sevenZ ->
            var entry = sevenZ.nextEntry
            while (entry != null) {
                val resolved = resolveEntryPath(target, entry.name)
                if (entry.isDirectory) {
                    Files.createDirectories(resolved)
                } else {
                    resolved.parent?.let { Files.createDirectories(it) }
                    Files.newOutputStream(resolved).use { output -> copyEntry(sevenZ, output) }
                }
                entry = sevenZ.nextEntry
            }
        }
    }

    private fun extractRar(archive: Path, target: Path) {
        RarArchive(archive.toFile()).use { rar ->
            rar.fileHeaders.forEach { header ->
                if (header.isDirectory) return@forEach
                val output = ByteArrayOutputStream()
                rar.extractFile(header, output)
                writeEntry(target, header.fileNameString, ByteArrayInputStream(output.toByteArray()), false)
            }
        }
    }

    private fun readZipEntry(input: java.io.InputStream, entryPath: String): ByteArray? {
        ZipInputStream(input).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: return null
                if (!entry.isDirectory && entry.name == entryPath) {
                    return zip.readBytes()
                }
                zip.closeEntry()
            }
        }
    }

    private fun readSevenZEntry(archive: Path, entryPath: String): ByteArray? {
        SevenZFile.builder().setPath(archive).get().use { sevenZ ->
            var entry = sevenZ.nextEntry
            while (entry != null) {
                if (!entry.isDirectory && entry.name == entryPath) {
                    val output = ByteArrayOutputStream()
                    copyEntry(sevenZ, output)
                    return output.toByteArray()
                }
                entry = sevenZ.nextEntry
            }
        }
        return null
    }

    /** 解压落盘统一走这里：拒绝 `..` 逃逸（Android 由 libarchive 侧兜底，这里显式校验）。 */
    private fun writeEntry(target: Path, entryName: String, input: java.io.InputStream, directory: Boolean) {
        val resolved = resolveEntryPath(target, entryName)
        if (directory) {
            Files.createDirectories(resolved)
            return
        }
        resolved.parent?.let { Files.createDirectories(it) }
        Files.newOutputStream(resolved).use { output -> input.copyTo(output) }
    }

    /** 条目路径必须落在解压目标内（拒绝 `..` 逃逸）。 */
    private fun resolveEntryPath(target: Path, entryName: String): Path {
        val resolved = target.resolve(entryName).normalize()
        if (!resolved.startsWith(target)) throw SecurityException("压缩包条目越界: $entryName")
        return resolved
    }

    /** `SevenZFile` 不是 InputStream，按当前条目读到 -1 为止。 */
    private fun copyEntry(sevenZ: SevenZFile, output: java.io.OutputStream) {
        val buffer = ByteArray(8192)
        while (true) {
            val read = sevenZ.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
        }
    }

    private fun isRar(bytes: ByteArray): Boolean =
        bytes.size >= 4 && bytes[0] == 'R'.code.toByte() && bytes[1] == 'a'.code.toByte() &&
            bytes[2] == 'r'.code.toByte() && bytes[3] == '!'.code.toByte()

    private fun isSevenZ(bytes: ByteArray): Boolean = bytes.size >= 6 &&
        bytes[0] == 0x37.toByte() && bytes[1] == 0x7A.toByte() && bytes[2] == 0xBC.toByte() &&
        bytes[3] == 0xAF.toByte() && bytes[4] == 0x27.toByte() && bytes[5] == 0x1C.toByte()

    companion object {
        const val TEMP_FOLDER_NAME = "ArchiveTemp"

        /** Android `MD5Utils.md5Encode16`：md5 十六进制的前 16 位（8..24）。 */
        fun md5Encode16(text: String): String {
            val full = MessageDigest.getInstance("MD5").digest(text.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            return if (full.length >= 24) full.substring(8, 24) else full
        }
    }
}
