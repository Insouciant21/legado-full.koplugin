package io.legado.server

import org.mozilla.javascript.BaseFunction
import org.mozilla.javascript.Context
import org.mozilla.javascript.ScriptRuntime
import org.mozilla.javascript.NativeObject
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject

/**
 * JS 侧的 StrResponse 适配器。
 *
 * 直接暴露 Kotlin 对象时，Rhino 会把 `body` 当作 Java 方法，导致
 * `result.body = ...` 无法赋值。这里用 NativeObject 提供属性与方法两种访问面；
 * 宿主侧仍通过 [response] 拿回原始对象，保证身份、headers 与 raw 保真。
 */
class JsStrResponseBridge(val response: JsStrResponse) : NativeObject() {
    init {
        val headers = response.headers()
        val headersObject = NativeObject().also { bridge ->
            ScriptableObject.putProperty(bridge, "size", headers.size)
            ScriptableObject.putProperty(
                bridge,
                "get",
                AccessorFunction { arguments -> headers.get(arguments.firstOrNull()?.toString() ?: "") },
            )
            ScriptableObject.putProperty(
                bridge,
                "values",
                AccessorFunction { arguments -> headers.values(arguments.firstOrNull()?.toString() ?: "") },
            )
            ScriptableObject.putProperty(
                bridge,
                "names",
                AccessorFunction { headers.names().toList() },
            )
            ScriptableObject.putProperty(
                bridge,
                "toMultimap",
                AccessorFunction { headers.toMultimap() },
            )
        }
        putProperty("kind", response.kind)
        putProperty("url") { response.url() }
        putProperty("body") { response.body() }
        putProperty("code") { response.code() }
        putProperty("message") { response.message() }
        super.put("headers", this, headersObject)
        putProperty("raw") { response.raw() }
        putProperty("isSuccessful") { response.isSuccessful }
        putProperty("header") { arguments -> response.header(arguments.firstOrNull()?.toString() ?: "") }
        putProperty("cookies") {
            NativeObject().also { cookies ->
                response.cookies().forEach { (name, value) ->
                    ScriptableObject.putProperty(cookies, name, Context.javaToJS(value, cookies))
                }
            }
        }
    }

    private class AccessorFunction(
        private val function: (Array<out Any?>) -> Any?,
    ) : BaseFunction() {
        init {
            ScriptableObject.putProperty(
                this,
                "toString",
                object : BaseFunction() {
                    override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any =
                        Context.javaToJS(function(emptyArray())?.toString() ?: "", scope)
                },
            )
            ScriptableObject.putProperty(
                this,
                "valueOf",
                object : BaseFunction() {
                    override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any =
                        function(emptyArray())?.let { Context.javaToJS(it, scope) } ?: Context.getUndefinedValue()
                },
            )
        }

        override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
            val value = function(args)
            return value?.let { toJsNative(it, scope) } ?: Context.getUndefinedValue()
        }

        override fun getDefaultValue(typeHint: Class<*>?): Any? {
            val value = function(emptyArray())
            if (value == null || value === Context.getUndefinedValue()) return Context.getUndefinedValue()
            val normalized = when (typeHint) {
                ScriptRuntime.StringClass -> value.toString()
                ScriptRuntime.NumberClass -> ScriptRuntime.toNumber(value)
                ScriptRuntime.BooleanClass -> ScriptRuntime.toBoolean(value)
                else -> value
            }
            return Context.javaToJS(normalized, this)
        }

        override fun toString(): String = function(emptyArray())?.toString() ?: ""
    }

    override fun put(name: String, start: Scriptable, value: Any?) {
        if (name == "body") {
            response.body = value?.takeUnless { it === Context.getUndefinedValue() }?.toString()
            return
        }
        super.put(name, start, value)
    }

    private fun putProperty(name: String, value: Any?) {
        super.put(name, this, Context.javaToJS(value, this))
    }

    private fun putProperty(
        name: String,
        function: (Array<out Any?>) -> Any?,
    ) {
        super.put(name, this, AccessorFunction(function))
    }
}

private fun toJsNative(value: Any?, scope: Scriptable): Any = when (value) {
    is List<*> -> Context.getCurrentContext().newArray(scope, value.map { toJsNative(it, scope) }.toTypedArray())
    is Map<*, *> -> NativeObject().also { obj ->
        value.forEach { (key, nested) ->
            ScriptableObject.putProperty(obj, key.toString(), toJsNative(nested, scope))
        }
    }
    else -> Context.javaToJS(value, scope)
}
