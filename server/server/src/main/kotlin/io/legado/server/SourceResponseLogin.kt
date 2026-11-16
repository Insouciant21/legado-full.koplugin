package io.legado.server

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * 搜索/详情/目录/正文响应进入规则解析前的 `loginCheckJs` 适配层。
 *
 * 与 Android WebBook.getResponse 语义逐条对齐：
 * 1. 每条响应先包装为 StrResponse，`result` 绑定为该对象后执行脚本；
 * 2. 脚本必须返回 StrResponse（Android 是 `evalJS(checkJs, it) as StrResponse`
 *    的强转），返回 null/字符串/普通 JS 对象都视为失败，绝不把任意载荷
 *    解释成新 body；
 * 3. 第一次执行失败（网络错误或脚本异常）时，用 code=500、body=错误说明的
 *    错误 StrResponse 再执行一次；第二次返回非 500 的 StrResponse 才算恢复，
 *    否则沿用第一次失败让请求失败（Android 对应“重抛原始异常”）。
 */
class SourceResponseLogin(private val jsSandbox: JsSandbox = JsSandbox()) {

    data class Result(
        val response: JsHttpResponse?,
        val error: String?,
    )

    fun prepare(sourceJson: String, response: JsHttpResponse, context: JsExecutionContext? = null): Result {
        val source = runCatching { Json.parseToJsonElement(sourceJson).jsonObject }.getOrNull()
            ?: return Result(response, null)
        val script = source["loginCheckJs"]?.jsonPrimitive?.content?.trim()
            ?: return Result(response, null)
        if (script.isEmpty()) return Result(response, null)

        val sourceUrl = source["bookSourceUrl"]?.jsonPrimitive?.content ?: ""
        val executionContext = context ?: JsExecutionContext(
            sourceId = sourceUrl,
            sourceName = source["bookSourceName"]?.jsonPrimitive?.content ?: sourceUrl,
            sourceComment = source["bookSourceComment"]?.jsonPrimitive?.content,
            jsLib = source["jsLib"]?.jsonPrimitive?.content,
        )
        val bindings: (JsStrResponse) -> Map<String, Any?> = { request ->
            mapOf(
                "result" to request,
                "baseUrl" to response.url,
                "key" to null,
                "page" to null,
                "sourceId" to sourceUrl,
                "bookSourceUrl" to sourceUrl,
            )
        }

        val request = JsStrResponse(
            response.url,
            response.body,
            response.code,
            response.message ?: if (response.code in 200..299) "OK" else "HTTP ${response.code}",
            JsHeaders.of(response.headers),
        )
        val first = unwrap(jsSandbox.evalObject(script, bindings(request), executionContext))
        if (first is JsStrResponse) {
            return Result(merge(response, first), null)
        }

        val firstError = executionContext.lastError
            ?: "loginCheckJs 必须返回 StrResponse（得到 ${first?.javaClass?.simpleName ?: "null"}）"
        executionContext.lastError = null
        val errorRequest = JsStrResponse(response.url, firstError, code = 500, message = firstError)
        val second = unwrap(jsSandbox.evalObject(script, bindings(errorRequest), executionContext))
        return if (second is JsStrResponse && second.code != 500) {
            Result(merge(response, second), null)
        } else {
            Result(null, executionContext.lastError ?: firstError)
        }
    }

    /** Rhino 会把 Java 对象包成 NativeJavaObject，先解包再做类型判定。 */
    private fun unwrap(value: Any?): Any? =
        (value as? org.mozilla.javascript.NativeJavaObject)?.unwrap() ?: value

    /** 用脚本返回的 StrResponse 覆盖原始响应；身份保真，绝不 stringify。 */
    private fun merge(original: JsHttpResponse, replacement: JsStrResponse): JsHttpResponse =
        original.copy(
            url = replacement.url,
            body = replacement.body,
            code = replacement.code,
            message = replacement.message,
            headers = replacement.headers.toMultimap(),
            raw = replacement.raw,
        )
}
