package io.legado.server

import org.mozilla.javascript.BaseFunction
import org.mozilla.javascript.Context
import org.mozilla.javascript.NativeArray
import org.mozilla.javascript.NativeObject
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import org.mozilla.javascript.ScriptRuntime
import java.nio.charset.Charset
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.roundToInt

internal object CryptoPackageBridge {
    private const val AES_TRANSFORMATION = "AES/CBC/NoPadding"
    private const val AES_ALGORITHM = "AES"
    private const val AES_IV_LENGTH = 16
    private const val BASE64_DEFAULT = 0
    private const val DECRYPT_MODE = Cipher.DECRYPT_MODE
    private const val MAX_BYTE_ARRAY_LENGTH = 1_048_576
    private const val MAX_BASE64_TEXT_LENGTH = MAX_BYTE_ARRAY_LENGTH * 4

    fun install(scope: Scriptable) {
        val packages = namespace(scope)
        val javax = namespace(scope)
        val crypto = namespace(scope)
        val spec = namespace(scope)
        val java = namespace(scope)
        val lang = namespace(scope)
        val android = namespace(scope)
        val util = namespace(scope)

        val cipher = namespace(scope)
        ScriptableObject.defineProperty(cipher, "DECRYPT_MODE", DECRYPT_MODE, ScriptableObject.READONLY or ScriptableObject.PERMANENT)
        putFunction(cipher, "getInstance") { _, args ->
            if (args.size != 1) fail("unsupported Cipher.getInstance shape")
            val transformation = textArgument(args[0]) ?: fail("invalid cipher transformation")
            if (transformation != AES_TRANSFORMATION) fail("unsupported cipher transformation")
            createCipher(scope)
        }

        val secretKeySpec = putConstructor(spec, "SecretKeySpec") { constructorScope, args ->
            if (args.size != 2) fail("unsupported SecretKeySpec shape")
            val bytes = byteArrayArgument(args[0])
            val algorithm = textArgument(args[1]) ?: fail("invalid key algorithm")
            if (algorithm != AES_ALGORITHM) fail("unsupported key algorithm")
            if (bytes.size !in setOf(16, 24, 32)) fail("invalid AES key byte length")
            SecretKeySpecWrapper(constructorScope, bytes)
        }

        val ivParameterSpec = putConstructor(spec, "IvParameterSpec") { constructorScope, args ->
            if (args.size != 1) fail("unsupported IvParameterSpec shape")
            IvParameterSpecWrapper(constructorScope, byteArrayArgument(args[0]))
        }

        val javaString = putConstructor(lang, "String") { constructorScope, args ->
            when {
                args.size == 1 && args[0] is CharSequence -> createJavaString(constructorScope, args[0].toString())
                args.size == 2 -> {
                    val charset = textArgument(args[1])?.let(::charsetFor) ?: fail("invalid charset")
                    createJavaString(constructorScope, String(byteArrayArgument(args[0]), charset))
                }
                else -> fail("unsupported Java String constructor shape")
            }
        }

        val base64 = namespace(scope)
        ScriptableObject.defineProperty(base64, "DEFAULT", BASE64_DEFAULT, ScriptableObject.READONLY or ScriptableObject.PERMANENT)
        putFunction(base64, "decode") { functionScope, args ->
            if (args.size != 2) fail("unsupported Android Base64 shape")
            val flags = integerArgument(args[1], "Android Base64 flags")
            if (flags != BASE64_DEFAULT) fail("unsupported Android Base64 flags")
            val text = textArgument(args[0]) ?: fail("invalid Android Base64 input")
            if (text.length > MAX_BASE64_TEXT_LENGTH) fail("Android Base64 input is too long")
            bytesToArray(functionScope, AndroidBase64Default.decode(text))
        }

        ScriptableObject.putProperty(crypto, "Cipher", cipher)
        ScriptableObject.putProperty(crypto, "spec", spec)
        ScriptableObject.putProperty(javax, "crypto", crypto)
        ScriptableObject.putProperty(lang, "String", javaString)
        ScriptableObject.putProperty(java, "lang", lang)
        ScriptableObject.putProperty(util, "Base64", base64)
        ScriptableObject.putProperty(android, "util", util)
        ScriptableObject.putProperty(packages, "javax", javax)
        ScriptableObject.putProperty(packages, "java", java)
        ScriptableObject.putProperty(packages, "android", android)
        ScriptableObject.putProperty(scope, "Packages", packages)

        freeze(packages, javax, crypto, spec, java, lang, android, util, cipher, base64)
        freeze(secretKeySpec, ivParameterSpec, javaString)
    }

    private fun namespace(scope: Scriptable): RestrictedNamespace = RestrictedNamespace().also { node ->
        node.parentScope = scope
    }

    /**
     * A namespace is a whitelist node, not a Java package proxy. Installed
     * names resolve normally; any other lookup is an explicit sandbox failure
     * so `Packages.java.lang.Runtime` cannot silently resolve to undefined.
     *
     * 抛出的必须是 **JS 异常**（`ScriptRuntime.typeError`）而不是普通 Java 异常：
     * Android 的 ClassShutter 只是让类解析失败，书源普遍把它当成客户端环境探测
     * （`try { new Packages.io.legato.kazusa.utils.TimeoutCancellationException('') } catch (e) {}`）。
     * Java 异常会直接逃出 Rhino 求值、连脚本自己的 try/catch 都接不住，
     * 源脚本就整条中断（🍅大灰狼聚合的 exploreUrl 因此拿不到任何分类）。
     */
    private class RestrictedNamespace : NativeObject() {
        override fun get(name: String, start: Scriptable): Any? {
            if (super.has(name, this)) return super.get(name, this)
            throw ScriptRuntime.typeError("forbidden Packages property: $name")
        }
    }

    private fun putFunction(
        target: Scriptable,
        name: String,
        function: (Scriptable, Array<out Any?>) -> Any,
    ) {
        ScriptableObject.putProperty(target, name, object : BaseFunction() {
            override fun call(context: Context, scope: Scriptable, thisObject: Scriptable, args: Array<out Any?>): Any =
                function(scope, args)
        })
    }

    private fun putConstructor(
        target: Scriptable,
        name: String,
        construct: (Scriptable, Array<out Any?>) -> Any,
    ): BaseFunction {
        val function = object : BaseFunction() {
            override fun call(context: Context, scope: Scriptable, thisObject: Scriptable, args: Array<out Any?>): Any =
                fail("$name is not callable without new")

            override fun construct(context: Context, scope: Scriptable, args: Array<out Any?>): Scriptable {
                val value = construct(scope, args)
                return value as? Scriptable ?: fail("constructor returned an unsupported value")
            }
        }
        ScriptableObject.putProperty(target, name, function)
        return function
    }

    private fun createCipher(scope: Scriptable): CipherWrapper = CipherWrapper(scope).also { facade ->
        putFunction(facade, "init") { _, args ->
            if (args.size != 3) fail("unsupported cipher init shape")
            val mode = integerArgument(args[0], "cipher mode")
            if (mode != DECRYPT_MODE) fail("unsupported cipher mode")
            val keySpec = keySpecArgument(args[1])
            val ivSpec = ivSpecArgument(args[2])
            val nextCipher = Cipher.getInstance(AES_TRANSFORMATION)
            nextCipher.init(mode, keySpec, ivSpec)
            facade.activeCipher = nextCipher
            Context.getUndefinedValue()
        }
        putFunction(facade, "doFinal") { functionScope, args ->
            if (args.size != 1) fail("unsupported cipher doFinal shape")
            val activeCipher = facade.activeCipher ?: fail("cipher has not been initialized")
            val output = activeCipher.doFinal(byteArrayArgument(args[0]))
            bytesToArray(functionScope, output)
        }
    }

    private class CipherWrapper(scope: Scriptable) : NativeObject() {
        internal var activeCipher: Cipher? = null

        init {
            parentScope = scope
        }
    }

    private class SecretKeySpecWrapper(
        scope: Scriptable,
        internal val bytes: ByteArray,
    ) : NativeObject() {
        init {
            parentScope = scope
        }
    }

    private class IvParameterSpecWrapper(
        scope: Scriptable,
        internal val bytes: ByteArray,
    ) : NativeObject() {
        init {
            parentScope = scope
            if (bytes.size != AES_IV_LENGTH) fail("invalid IV byte length")
        }
    }

    private class JavaStringWrapper(
        scope: Scriptable,
        internal val value: String,
    ) : NativeObject() {
        init {
            parentScope = scope
        }

        override fun toString(): String = value

        override fun getDefaultValue(typeHint: Class<*>?): Any = value
    }

    private fun createJavaString(scope: Scriptable, value: String): JavaStringWrapper =
        JavaStringWrapper(scope, value).also { wrapper ->
            putFunction(wrapper, "toString") { _, _ -> value }
            putFunction(wrapper, "valueOf") { _, _ -> value }
            putFunction(wrapper, "getBytes") { _, args ->
                if (args.size != 1) fail("unsupported String.getBytes shape")
                val charset = textArgument(args[0])?.let(::charsetFor) ?: fail("invalid charset")
                bytesToArray(scope, value.toByteArray(charset))
            }
        }

    private fun bytesToArray(scope: Scriptable, bytes: ByteArray): NativeArray {
        if (bytes.size > MAX_BYTE_ARRAY_LENGTH) fail("decoded byte array is too long")
        val values = Array<Any?>(bytes.size) { index -> bytes[index].toInt() }
        return NativeArray(values).also { array ->
            array.parentScope = scope
            // Android 侧 Java byte[] 被 Rhino 包成 NativeJavaArray（带 Array.prototype）；
            // 稠密 NativeArray 默认无原型，`String(bytes)`/`bytes.map(...)` 会直接 TypeError。
            array.setPrototype(ScriptableObject.getArrayPrototype(scope))
        }
    }

    private fun byteArrayArgument(value: Any?): ByteArray {
        if (value !is NativeArray) fail("expected a JavaScript byte array")
        val length = value.length
        if (length < 0 || length > MAX_BYTE_ARRAY_LENGTH) fail("byte array is too long")
        val result = ByteArray(length.toInt())
        for (index in 0 until length.toInt()) {
            if (!value.has(index, value)) fail("byte array is sparse")
            val raw = value.get(index, value)
            val number = raw as? Number ?: fail("byte array contains a non-number")
            val decimal = number.toDouble()
            if (!decimal.isFinite() || decimal != decimal.roundToInt().toDouble() || decimal < -128 || decimal > 127) {
                fail("byte array requires an integer in signed byte range")
            }
            result[index] = decimal.toInt().toByte()
        }
        return result
    }

    private fun keySpecArgument(value: Any?): SecretKeySpec {
        if (value !is SecretKeySpecWrapper) fail("expected a SecretKeySpec")
        return SecretKeySpec(value.bytes, AES_ALGORITHM)
    }

    private fun ivSpecArgument(value: Any?): IvParameterSpec {
        if (value !is IvParameterSpecWrapper) fail("expected an IvParameterSpec")
        return IvParameterSpec(value.bytes)
    }

    private fun textArgument(value: Any?): String? = when (value) {
        is String -> value
        is CharSequence -> value.toString()
        else -> null
    }

    private fun integerArgument(value: Any?, name: String): Int {
        val number = value as? Number ?: fail("invalid $name")
        val decimal = number.toDouble()
        if (!decimal.isFinite() || decimal < Int.MIN_VALUE || decimal > Int.MAX_VALUE) fail("invalid $name")
        val rounded = decimal.roundToInt()
        if (rounded.toDouble() != decimal) fail("invalid $name")
        return rounded
    }

    private fun charsetFor(name: String): Charset = try {
        Charset.forName(name)
    } catch (_: Exception) {
        fail("unsupported charset")
    }

    private fun freeze(vararg nodes: ScriptableObject) {
        nodes.forEach { node ->
            node.preventExtensions()
            node.sealObject()
        }
    }

    /**
     * 与 [RestrictedNamespace] 同理：facade 内的失败一律以 **JS 异常**抛出，
     * 书源的 `try { … } catch (e) { … }` 才能按 Android 的方式兜底
     * （Android 侧这些失败是 Java 异常，Rhino 会把它变成可捕获的 JS 异常）。
     */
    private fun fail(message: String): Nothing = throw ScriptRuntime.typeError(message)
}

internal object AndroidBase64Default {
    private const val SKIP = -1
    private const val EQUALS = -2

    fun decode(text: String): ByteArray {
        val output = ByteArray(text.length * 3 / 4)
        var state = 0
        var value = 0
        var outputIndex = 0

        text.forEach { character ->
            val symbol = decode(character)
            when (state) {
                0 -> when {
                    symbol >= 0 -> {
                        value = symbol
                        state = 1
                    }
                    symbol != SKIP -> state = 6
                }
                1 -> when {
                    symbol >= 0 -> {
                        value = (value shl 6) or symbol
                        state = 2
                    }
                    symbol != SKIP -> state = 6
                }
                2 -> when {
                    symbol >= 0 -> {
                        value = (value shl 6) or symbol
                        state = 3
                    }
                    symbol == EQUALS -> {
                        output[outputIndex++] = (value shr 4).toByte()
                        state = 4
                    }
                    symbol != SKIP -> state = 6
                }
                3 -> when {
                    symbol >= 0 -> {
                        value = (value shl 6) or symbol
                        output[outputIndex++] = (value shr 16).toByte()
                        output[outputIndex++] = (value shr 8).toByte()
                        output[outputIndex++] = value.toByte()
                        state = 0
                    }
                    symbol == EQUALS -> {
                        output[outputIndex++] = (value shr 10).toByte()
                        output[outputIndex++] = (value shr 2).toByte()
                        state = 5
                    }
                    symbol != SKIP -> state = 6
                }
                4 -> if (symbol == EQUALS) {
                    state = 5
                } else if (symbol != SKIP) {
                    state = 6
                }
                5 -> if (symbol != SKIP) state = 6
            }
            if (state == 6) throw IllegalArgumentException("invalid base64 padding")
        }

        if (state == 1 || state == 4) throw IllegalArgumentException("invalid base64 padding")
        if (state == 2) {
            output[outputIndex++] = (value shr 4).toByte()
        } else if (state == 3) {
            output[outputIndex++] = (value shr 10).toByte()
            output[outputIndex++] = (value shr 2).toByte()
        }
        return output.copyOf(outputIndex)
    }

    private fun decode(character: Char): Int = when (character) {
        in 'A'..'Z' -> character - 'A'
        in 'a'..'z' -> character - 'a' + 26
        in '0'..'9' -> character - '0' + 52
        '+' -> 62
        '/' -> 63
        '=' -> EQUALS
        else -> SKIP
    }
}
