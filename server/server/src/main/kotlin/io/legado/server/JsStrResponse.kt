package io.legado.server

/**
 * okhttp3.Headers 风格的只读多值头对象。
 *
 * Android 的 StrResponse.headers 是 okhttp3.Headers：保留同名多值（Set-Cookie）
 * 且按名称大小写不敏感读取。这里保留同一 JS 可用面：get/values/names/size/
 * name/value/toMultimap，绝不拍扁成单值 Map 丢失重复头。
 */
class JsHeaders private constructor(private val entries: List<Pair<String, String>>) {
    companion object {
        fun of(multiValue: Map<String, List<String>>): JsHeaders =
            JsHeaders(multiValue.flatMap { (name, values) -> values.map { name to it } })

        fun ofSingle(singleValue: Map<String, String>): JsHeaders =
            JsHeaders(singleValue.map { it.key to it.value })
    }

    val size: Int
        get() = entries.size

    fun get(name: String): String? =
        entries.firstOrNull { it.first.equals(name, ignoreCase = true) }?.second

    fun values(name: String): List<String> =
        entries.filter { it.first.equals(name, ignoreCase = true) }.map { it.second }

    fun name(index: Int): String = entries[index].first

    fun value(index: Int): String = entries[index].second

    fun names(): Set<String> =
        entries.fold(LinkedHashSet<String>()) { acc, (name, _) -> acc.add(name); acc }

    fun toMultimap(): Map<String, List<String>> {
        val result = LinkedHashMap<String, MutableList<String>>()
        entries.forEach { entry -> result.getOrPut(entry.first) { mutableListOf() }.add(entry.second) }
        return result
    }

    fun all(): List<Pair<String, String>> = entries

    override fun toString(): String = entries.joinToString("; ") { "${it.first}: ${it.second}" }
}

/**
 * okhttp3.Response 的纯 JVM 快照形状：Android StrResponse.raw 指向 Response
 * 对象而非字节数组，源脚本可能读取 raw.code/raw.headers/raw.body 等。
 */
class JsRawResponse(
    val url: String,
    val code: Int,
    val message: String,
    val headers: JsHeaders,
    val body: String? = null,
) {
    val isSuccessful: Boolean
        get() = code in 200..299

    fun url(): String = url
    fun code(): Int = code
    fun message(): String = message
    fun headers(): JsHeaders = headers
    fun body(): String? = body

    override fun toString(): String = "Response{url=$url, code=$code, message=$message}"
}

/**
 * Android io.legado.app.help.http.StrResponse 的纯 JVM 形状。
 *
 * 属性与方法两种访问都可用（如 `response.body` 与 `response.body()`）；
 * raw 始终是 [JsRawResponse] 响应对象，headers 是保留多值的 [JsHeaders]。
 * 调用方必须保留 Java 对象身份传递，绝不能 stringify 后再作为响应解析载荷。
 */
class JsStrResponse(
    val url: String,
    @Volatile var body: String?,
    val code: Int = 200,
    val message: String = if (code in 200..299) "OK" else "HTTP $code",
    headers: JsHeaders = JsHeaders.ofSingle(emptyMap()),
    rawResponse: JsRawResponse? = null,
) {
    constructor(
        url: String,
        body: String?,
        code: Int,
        message: String,
        headers: Map<String, String>,
    ) : this(url, body, code, message, JsHeaders.ofSingle(headers))

    val headers: JsHeaders = headers

    /** Android 构造器语义：raw 始终存在；(url, body) 形式默认 200/OK。 */
    val raw: JsRawResponse =
        rawResponse ?: JsRawResponse(url, code, message, headers, body)

    val isSuccessful: Boolean
        get() = code in 200..299

    val kind: String = "StrResponse"

    fun url(): String = url
    fun body(): String? = body
    fun code(): Int = code
    fun message(): String = message
    fun headers(): JsHeaders = headers
    fun raw(): JsRawResponse = raw

    fun header(name: String): String? = headers.get(name)

    fun cookies(): Map<String, String> {
        val result = linkedMapOf<String, String>()
        headers.values("Set-Cookie").forEach { headerValue ->
            headerValue.substringBefore(';').let { pair ->
                val eq = pair.indexOf('=')
                if (eq > 0) result[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim()
            }
        }
        headers.get("Cookie")?.takeIf { it.isNotBlank() }?.split(';')?.forEach { part ->
            val eq = part.indexOf('=')
            if (eq > 0) result[part.substring(0, eq).trim()] = part.substring(eq + 1).trim()
        }
        return result
    }

    override fun toString(): String =
        "StrResponse{url=$url, code=$code, bodyLength=${body?.length ?: 0}}"
}

/** 网络集成用的轻量响应载体；headers 必须是多值形态以保留 Set-Cookie。 */
data class JsHttpResponse(
    val url: String,
    val body: String?,
    val code: Int = 200,
    val message: String? = null,
    val headers: Map<String, List<String>> = emptyMap(),
    val raw: Any? = null,
)
