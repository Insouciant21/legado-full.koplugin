package io.legado.server

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.mozilla.javascript.BaseFunction
import org.mozilla.javascript.ClassShutter
import org.mozilla.javascript.Context
import org.mozilla.javascript.ContextFactory
import org.mozilla.javascript.NativeJSON
import org.mozilla.javascript.NativeJavaObject
import org.mozilla.javascript.NativeArray
import org.mozilla.javascript.NativeObject
import org.mozilla.javascript.ScriptRuntime
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import org.mozilla.javascript.Script
import java.nio.file.Files
import java.nio.file.Path
import java.nio.charset.Charset
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.SimpleTimeZone
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** android.util.Base64.URL_SAFE —— `java.base64DecodeToByteArray` 的 flags 参数用它选 URL 安全字母表。 */
private val ANDROID_BASE64_URL_SAFE = 8

/** 单次 JS 求值的墙钟上限（Android 无此限制，服务端按「够重活跑完、坏源跑不出」取值）。 */
private const val JS_WALL_CLOCK_LIMIT_MS = 30_000L

/** 单次 JS 求值的指令上限：只在墙钟被交互暂停时起兜底作用。 */
private const val JS_INSTRUCTION_LIMIT = 200_000_000L

/**
 * 绑定给 JS 的**字节数组**（Android 侧是真正的 `byte[]`/`InputStream`）。
 *
 * 沙箱里不暴露 Java 数组（ClassShutter 只放行显式载体），统一用整数数组桥接，
 * 与 `java.base64DecodeToByteArray` 等函数的返回值保持同一约定 ⇒ 脚本可以把
 * `result` 直接喂给这些函数，也可以原样返回。
 */
internal class JsByteArray(val bytes: ByteArray)

data class JsExecutionContext(
    val sourceId: String? = null,
    val sourceName: String? = null,
    val sourceComment: String? = null,
    /**
     * 书源定义本体。给需要"按书源 header/Cookie 再发一次请求"的桥接函数用
     * （`java.downloadFile`/`cacheFile`/压缩包族），避免它们只能按 sourceId 复读库里的 JSON。
     */
    val sourceJson: JsonObject? = null,
    val database: Database? = null,
    val initialLoginInfo: MutableMap<String, String> = mutableMapOf(),
    val loginUiDefaults: MutableMap<String, String> = mutableMapOf(),
    val isLongClick: Boolean = false,
    val toastMessages: MutableList<String> = mutableListOf(),
    var openUrl: String? = null,
    var copyText: String? = null,
    var reRenderUi: Boolean = false,
    /** 脚本执行失败的原始原因，供登录动作回传给前端展示（否则按钮会「假成功」） */
    var lastError: String? = null,
    /** 当前书籍上下文，供 book 桥接对象读取 */
    val bookUrl: String? = null,
    val bookName: String? = null,
    val bookAuthor: String? = null,
    val bookTocUrl: String? = null,
    val bookType: Int? = null,
    /** 书籍类型（`novel`/`comic`/`audio`）—— 供 `book.kind` 读取（Legado 的 `Book.kind`）。 */
    val bookKind: String? = null,
    val bookVariables: MutableMap<String, String> = mutableMapOf(),
    /** Legado `Book.useReplaceRule`：JS `setUseReplaceRule` 在真实执行时写它，`content()` 据此决定是否跳过全局替换。 */
    var useReplaceRule: Boolean = true,
    /** 当前章节上下文，供 chapter 桥接对象读取 */
    val chapterUrl: String? = null,
    val chapterIndex: Int? = null,
    val chapterTitle: String? = null,
    /** 该书源的 jsLib：所有规则 JS 都应能调用其中的工具函数 */
    val jsLib: String? = null,
    /**
     * jsLib 展开失败的原因（Android `SharedJsScope.getScope` 下载 jsLib 文件失败时抛
     * `下载jsLib-URL失败`）。非空时**任何** JS 规则都视为失败 —— Android 里
     * `evalJS` 先取共享作用域，取不到就抛，规则根本不会执行。
     */
    val jsLibError: String? = null,
    val baseUrl: String? = null,
    val browserHook: BrowserHook? = null,
    val pendingVerifications: MutableList<BrowserVerification> = mutableListOf(),
    /**
     * Android `AnalyzeRule.preUpdateJs` 标记：只有 `ruleToc.preUpdateJs` 内部才允许调用
     * `java.reGetBook()` / `java.refreshTocUrl()`，别处调用直接抛「只能在 preUpdateJs 中调用」。
     */
    var inPreUpdateJs: Boolean = false,
    /**
     * Android `WebBook.getChapterListAwait(isFromBookInfo=...)`：详情页规则刚解析完就顺势取目录时，
     * 上面两个函数只记一行日志（「已跳过重复加载详情页」）而不重复请求详情页，避免自递归。
     */
    var fromBookInfo: Boolean = false,
    /** `java.refreshTocUrl()` 的请求标记，由 RuleRunner 在 preUpdateJs 之后按需重解析目录地址。 */
    var refreshTocRequested: Boolean = false,
    /** `java.reGetBook()` 的请求标记（先精确搜索换 bookUrl，再重解析详情）。 */
    var reGetBookRequested: Boolean = false,
    /** `java.setBaseUrl(...)` 覆盖的规则基准地址（影响本请求内后续脚本与相对链接解析）。 */
    var baseUrlOverride: String? = null,
    /** `java.setRedirectUrl(...)` 覆盖的链接解析地址，优先级高于 [baseUrlOverride]。 */
    var redirectUrlOverride: String? = null,
    /** `java.setRuleName(...)`：与 Android `AnalyzeRule.ruleName` 同义，只影响日志标签。 */
    var ruleName: String? = null,
)

/**
 * 规则求值用的基准地址：`java.setBaseUrl(...)` 覆盖值优先（Android `AnalyzeRule.baseUrl`）。
 * 调用方若要拿"本次规则求值真正用的基准"，还必须再回退到作用域里的 `baseUrl` 绑定，
 * 见 JsSandbox.ruleBaseUrl。
 */
val JsExecutionContext.effectiveBaseUrl: String?
    get() = baseUrlOverride ?: baseUrl

/** 解析规则取出的相对链接用的地址：`setRedirectUrl` → `setBaseUrl` → 响应地址。 */
val JsExecutionContext.effectiveRedirectUrl: String?
    get() = redirectUrlOverride ?: baseUrlOverride ?: baseUrl

interface BrowserHook {
    fun start(sourceId: String, url: String, title: String, html: String?, await: Boolean, refetch: Boolean): JsStrResponse?

    fun webViewGetSource(
        sourceId: String,
        html: String?,
        url: String?,
        js: String?,
        sourceRegex: String,
        cacheFirst: Boolean,
        delayTime: Long,
    ): String? = null

    fun webViewGetOverrideUrl(
        sourceId: String,
        html: String?,
        url: String?,
        js: String?,
        overrideUrlRegex: String,
        cacheFirst: Boolean,
        delayTime: Long,
    ): String? = null
}

data class BrowserVerification(
    val sourceId: String,
    val url: String,
    val title: String,
    val html: String?,
    val await: Boolean,
    val refetch: Boolean,
)

class JsSandbox(private val runner: RuleRunner? = null) {
    private val sessionStore = ConcurrentHashMap<String, Any>()
    /**
     * 书源级 KV（Android `CacheManager` 的 `v_<源>_<键>`）的进程内镜像：按源整表读一次，
     * 读写都走内存、写入再穿透到 `source_login_state.source_kv`。
     * 源头少（每源一张小表），`java.get` 在高频 SVG/正文脚本里也不会变成逐次查库。
     */
    private val sourceKvCache = ConcurrentHashMap<String, MutableMap<String, String>>()
    // Android CacheManager 是进程级共享；这里按沙箱实例共享，保证
    // 登录阶段 cache.put 的值在后续详情/正文 eval 中可读。
    private val cacheMemory = ConcurrentHashMap<String, Any>()
    /**
     * Rhino compilation is deterministic for a source string and does not hold
     * bindings or scope state. Reuse the compiled program while keeping the
     * per-call scope isolated.
     */
    private val compiledScripts = CompiledScriptCache()

    /**
     * 当前线程正在求值的书源上下文。
     *
     * 规则的 `<js>` 片段（NodeValue）无法方便地把执行上下文逐层透传，但书源 JS 普遍依赖
     * `source.getVariable()` 与 jsLib 里的工具函数，因此由 RuleRunner 的入口方法设置本线程上下文，
     * eval 在未显式传入 execContext 时回退到它。
     */
    @PublishedApi
    internal val threadContext = ThreadLocal<JsExecutionContext?>()

    private val threadLastError = ThreadLocal<String?>()
    private val threadBudget = ThreadLocal<ExecutionBudget?>()

    /**
     * 单次 JS 求值的预算。
     *
     * Android 侧 Rhino 只看协程取消，没有时间/指令上限；服务端必须有界，但**不能太紧**：
     * 真实书源在目录/正文里对整页 HTML 做大批量正则替换（po18 系列）单次就能跑十几秒，
     * 掐在 10 秒会把能用的书源判失败。墙钟是主约束，指令上限只用于兜住
     * `java.webView` 交互期间被暂停的墙钟（那时指令仍在累计）。
     */
    private class ExecutionBudget(private val timeLimitMillis: Long = JS_WALL_CLOCK_LIMIT_MS) {
        @Volatile private var deadline = System.currentTimeMillis() + timeLimitMillis
        @Volatile private var pausedAt: Long? = null
        private var instructionCount = 0L
        private var instructionLimit = JS_INSTRUCTION_LIMIT

        fun pauseWallClock() {
            pausedAt = System.currentTimeMillis()
        }

        fun resumeWallClock() {
            val paused = pausedAt ?: return
            deadline += System.currentTimeMillis() - paused
            pausedAt = null
        }

        fun resetForMainScript() {
            instructionCount = 0L
            instructionLimit = JS_INSTRUCTION_LIMIT
        }

        fun observe(instructionCount: Int) {
            this.instructionCount += instructionCount
            if (this.instructionCount > instructionLimit) {
                throw Error("JavaScript 执行超过时限/指令限额")
            }
            if (pausedAt == null && System.currentTimeMillis() >= deadline) {
                throw Error("JavaScript 执行超过时限")
            }
        }
    }

    /** 在指定的书源上下文内执行 block（inline 以便调用方直接 return）。 */
    inline fun <T> withSourceContext(context: JsExecutionContext?, block: () -> T): T {
        val previous = threadContext.get()
        threadContext.set(context)
        try {
            return block()
        } finally {
            threadContext.set(previous)
        }
    }

    fun eval(
        script: String,
        bindings: Map<String, Any?> = emptyMap(),
        execContext: JsExecutionContext? = null,
    ): String? {
        return evalObject(script, bindings, execContext)?.let(::stringifyJsValue)
    }

    /**
     * 图片二次解密（Android `ImageUtils.decode` 的求值入口）：
     * 绑定 `result`（字节数组）、`src`（图片地址）、`baseUrl`，返回脚本产出的字节。
     *
     * 脚本失败（[JsExecutionContext.lastError] 非空）或返回值不是字节数组时返回 null ——
     * Android 侧对应「强转 `as ByteArray` 抛异常 → `runCatching` 得到 null」，
     * 调用方据此判失败，**绝不直出未解密的字节**。
     */
    internal fun evalImageBytes(
        rule: String,
        src: String,
        bytes: ByteArray,
        execContext: JsExecutionContext?,
    ): ByteArray? {
        val result = evalObject(
            rule,
            bindings = mapOf(
                "result" to JsByteArray(bytes),
                "src" to src,
                "baseUrl" to (execContext?.sourceId ?: ""),
            ),
            execContext = execContext,
        )
        if (execContext?.lastError != null) return null
        if (result == null) return null
        val decoded = jsByteArrayArgument(result)
        return decoded.takeIf { it.isNotEmpty() }
    }

    /** Keep the same Rhino conversion rules for a value returned by [evalObject]. */
    internal fun stringifyJsValue(value: Any?): String? {
        val cx = Context.enter()
        try {
            cx.optimizationLevel = -1
            val scope = cx.initSafeStandardObjects()
            return jsValueToString(cx, scope, value)
        } finally {
            Context.exit()
        }
    }

    fun evalObject(
        script: String,
        bindings: Map<String, Any?> = emptyMap(),
        execContext: JsExecutionContext? = null,
    ): Any? {
        return evalObjectInternal(
            script,
            bindings,
            execContext,
            stripJsPrefix = true,
            fallbackToGlobalResult = true,
            wrapTopLevelReturn = true,
        )
    }

    /**
     * `{{...}}` URL 模板片段的求值（Android `AnalyzeUrl.replaceKeyPageJs` 用
     * `evalJS(it) ?: ""`）：**没有返回值就替换成空串**，而不是留着占位符让整条 URL 非法。
     *
     * `fallbackToGlobalResult` 必须关闭：URL 模板里裸表达式（如 `cookie.removeCookie(baseUrl)`）
     * 不能把绑定的 `result` 兜回来 —— 那会把整个请求体当成占位符的取值拼进 URL。
     * 求值失败（返回 null）时由调用方保留原文，便于报出可诊断的「未解析变量」错误。
     */
    fun evalTemplateExpression(
        script: String,
        bindings: Map<String, Any?>,
        execContext: JsExecutionContext?,
    ): String? {
        val context = execContext ?: threadContext.get()
        val previousError = context?.lastError
        if (context != null) context.lastError = null
        val value = evalObjectInternal(
            script,
            bindings,
            context,
            stripJsPrefix = true,
            fallbackToGlobalResult = false,
            wrapTopLevelReturn = true,
        )
        val failed = context?.lastError != null
        if (context != null) context.lastError = previousError
        if (failed) return null
        return when (value) {
            null, Context.getUndefinedValue() -> ""
            // Android `AnalyzeRule.makeUpRule` / `AnalyzeUrl.replaceKeyPageJs` 对 `{{}}` 里
            // JS 数值的统一串化：整数值去掉小数尾巴（`{{page+1}}` 必须是 `2`，不是 `2.0`）。
            is Number -> {
                val number = value.toDouble()
                if (number.isFinite() && number % 1.0 == 0.0) {
                    String.format(java.util.Locale.ROOT, "%.0f", number)
                } else {
                    value.toString()
                }
            }
            else -> stringifyJsValue(value) ?: ""
        }
    }

    /**
     * bodyJs is passed verbatim like Android AnalyzeUrl.evalJS and must expose the
     * raw completion value; in particular undefined is not redirected to a global
     * result binding.
     */
    internal fun evalBodyJsCompletion(
        script: String,
        bindings: Map<String, Any?> = emptyMap(),
        execContext: JsExecutionContext? = null,
    ): Any? {
        return evalObjectInternal(
            script,
            bindings,
            execContext,
            stripJsPrefix = false,
            fallbackToGlobalResult = false,
            wrapTopLevelReturn = false,
        )
    }

    private fun evalObjectInternal(
        script: String,
        bindings: Map<String, Any?>,
        execContext: JsExecutionContext?,
        stripJsPrefix: Boolean,
        fallbackToGlobalResult: Boolean,
        wrapTopLevelReturn: Boolean,
    ): Any? {
        val context = execContext ?: threadContext.get()
        val rawScript = script.trim().let { value ->
            when {
                stripJsPrefix && value.startsWith("@js:", ignoreCase = true) -> value.substring(4)
                stripJsPrefix && value.startsWith("js:", ignoreCase = true) -> value.substring(3)
                else -> value
            }
        }.trim()
        if (rawScript.isBlank()) return null
        // Android evalJS 先 getShareScope()：jsLib 文件下载失败会直接抛出，
        // 规则脚本一行都不会执行。这里以「整体失败 + lastError」保持同一可见语义。
        context?.jsLibError?.let { failure ->
            context.lastError = failure
            setThreadLastError(failure)
            return null
        }
        // 书源的 jsLib 对所有规则 JS 可见（Legado 语义），集中在这里注入，
        // 避免每个调用点各自拼接、漏拼一处就整段脚本 ReferenceError。
        val library = context?.jsLib?.takeIf { it.isNotBlank() }

        // 关键：jsLib **不能**与规则脚本拼接后共同参与「是否包裹 IIFE」的判定。
        // 聚合源 jsLib 里每个工具函数都含 return，拼接判定会命真 ⇒ 整段被包进 IIFE，
        // 而 Rhino 在 IIFE 下的求值补全值会退化为 undefined，正文规则末尾的裸表达式
        // （如 `data;`）就拿不到值。改为：jsLib 先在同一 scope 内单独求值（只建立函数
        // 定义），规则脚本再按**自身的顶层 return** 决定是否包裹。
        // 实测背景见 历史实现说明。
        val executableScript =
            if (wrapTopLevelReturn && hasTopLevelReturn(rawScript)) "(function(){\n$rawScript\n})()" else rawScript



        // 嵌套求值（`java.getString`/`java.getElement` 的规则里再写 `<js>`、以及后续
        // reGetBook/refreshTocUrl 触发的详情解析）**必须复用当前 Context**：
        // Rhino 的 `ContextFactory.enterContext` 在已有上下文时会把新 Context 丢掉、
        // 返回外层那个，重复 `setClassShutter` 直接抛 SecurityException
        // （实测报「Cannot overwrite existing ClassShutter object」），嵌套规则整条失败。
        val previousBudget = threadBudget.get()
        val cx = boundedContext(previousBudget)
        val entered = previousBudget == null
        previousBudget?.pauseWallClock()
        try {
            cx.optimizationLevel = -1
            if (entered) {
                // Sandbox：禁止通用 Java 反射和任意类访问；Packages 只暴露独立受限 native facade。
                // ClassShutter 仍只放行显式响应载体；Map bridge 是 NativeObject，不需要 java.util。
                // 复用的外层 Context 已经装好同一份 shutter，重复设置会抛 SecurityException。
                cx.setClassShutter(ClassShutter { className ->
                    className == "io.legado.server.QueryTTF" ||
                        className == "io.legado.server.JsHeaders" ||
                        className == "io.legado.server.JsRawResponse" ||
                        className == "io.legado.server.JsStrResponse" ||
                        className == "java.lang.String" ||
                        className == "java.lang.Number" ||
                        className == "java.lang.Integer" ||
                        className == "java.lang.Long" ||
                        className == "java.lang.Double" ||
                        className == "java.lang.Boolean"
                })
            }
            val scope = cx.initSafeStandardObjects()

            // Inject bindings (e.g. result, src, baseUrl, key, page, book, chapter, isLongClick)
            bindings.forEach { (key, value) ->
                ScriptableObject.putProperty(scope, key, toJsValue(value, scope))
            }

            // Inject standard Legado 'java' bridge object
            ScriptableObject.putProperty(scope, "java", createJavaBridge(scope, context))

            // Legado 书源的 jsLib 惯用 `new JavaImporter()` + `with(importer){ ... }` 组织工具函数库。
            // 沙箱禁用了真实 Java 反射，此处提供空实现的安全替身：只要不再抛 ReferenceError，
            // 整个 with 块就能正常完成函数定义，后续登录动作才可能执行。
            ScriptableObject.putProperty(scope, "JavaImporter", createJavaImporterStub(scope))

            // Explicit Jsoup namespace. Android exposes the real classes through Rhino;
            // the server exposes only the bounded native-JS facade in JsoupBridge.kt.
            JsoupBridge.install(scope)
            CryptoPackageBridge.install(scope)

            // Inject 'source' and 'cookie' bridge objects if sourceId is available
            val sourceId = context?.sourceId ?: bindings["sourceId"]?.toString() ?: bindings["baseUrl"]?.toString() ?: bindings["bookSourceUrl"]?.toString()
            if (!sourceId.isNullOrBlank()) {
                val db = context?.database ?: runner?.database
                ScriptableObject.putProperty(scope, "source", createSourceBridge(scope, sourceId, db, context))
                ScriptableObject.putProperty(scope, "cookie", createCookieBridge(scope, sourceId, db))
            }

            // Legado 的 book 对象：书源 JS 会用 book.getVariable('custom') 读取书籍级变量
            ScriptableObject.putProperty(scope, "book", createBookBridge(scope, context))
            // chapter 对象：正文规则会引用 chapter.index / chapter.title
            ScriptableObject.putProperty(scope, "chapter", createChapterBridge(scope, context))

            // 先单独求值 jsLib：只建立函数定义，其结果不参与补全值。
            // 失败不中断解析，但必须保留诊断；登录动作视 lastError 为失败。
            var libraryError: String? = null
            if (library != null) {
                runCatching { compiledScript(cx, library, "jsLib.js").exec(cx, scope) }
                    .onFailure { e ->
                        libraryError = "jsLib 求值失败：" + (e.message ?: e.javaClass.simpleName)
                    }
            }
            threadBudget.get()?.resetForMainScript()

            val result = compiledScript(cx, executableScript, "rule.js").exec(cx, scope)
            // jsLib 失败不可被成功分支抹掉；主脚本错误在 catch 中覆盖。
            // 同步写进执行上下文：登录动作等调用方只读 context.lastError 判定成败。
            setThreadLastError(libraryError)
            if (libraryError != null) {
                if (context?.lastError == null) context?.lastError = libraryError
            } else {
                context?.lastError = null
            }
            if (result == Context.getUndefinedValue()) {
                if (fallbackToGlobalResult) {
                    val globalResult = ScriptableObject.getProperty(scope, "result")
                    if (globalResult != null && globalResult != Context.getUndefinedValue()) {
                        return unwrapJsBridge(globalResult)
                    }
                }
                return null
            }
            return unwrapJsBridge(result)
        } catch (e: Throwable) {
            // 不能静默吞掉：否则登录按钮全部「执行成功」却毫无动作，用户无从判断原因。
            // 记录到执行上下文，由调用方决定是展示还是忽略。
            // 必须连 Error 一起接住：boundedContext 的时限中断以 java.lang.Error 抛出。
            val detail = e.message?.takeIf { it.isNotBlank() } ?: e.javaClass.simpleName
            context?.lastError = detail
            setThreadLastError(detail)
            return null
        } finally {
            // 嵌套求值结束后恢复外层预算（并让外层墙钟不把嵌套耗时算进去），
            // 只有最外层求值才真正退出 Rhino 上下文。
            previousBudget?.resumeWallClock()
            if (entered) {
                threadBudget.remove()
                Context.exit()
            } else {
                threadBudget.set(previousBudget)
            }
        }
    }

    private fun compiledScript(cx: Context, source: String, sourceName: String): Script =
        compiledScripts.get(sourceName, source)
            ?: cx.compileString(source, sourceName, 1, null).also { script ->
                compiledScripts.put(sourceName, source, script)
            }

    private fun setThreadLastError(value: String?) {
        threadLastError.set(value)
    }

    /** 最近一次 eval 的失败原因，供无法拿到执行上下文的调用方读取。 */
    val lastError: String?
        get() = threadLastError.get()

    /**
     * 取得本次求值用的 Rhino Context。
     *
     * [previousBudget] 非空表示这是**嵌套**求值：Rhino 只允许线程上有一个活动 Context
     * （`ContextFactory.enterContext` 会忽略新 Context 并返回当前那个），所以这里直接
     * 复用外层上下文、只换一份新的执行预算；最外层才真正 enter/exit。
     */
    private fun boundedContext(previousBudget: ExecutionBudget?): Context {
        threadBudget.set(ExecutionBudget())
        previousBudget?.let { return Context.getCurrentContext() ?: error("缺少活动 Rhino Context") }
        val context = object : Context() {
            override fun observeInstructionCount(instructionCount: Int) {
                threadBudget.get()?.observe(instructionCount)
                    ?: throw Error("JavaScript 执行超过时限")
            }
        }
        context.setInstructionObserverThreshold(2_500)
        return ContextFactory().enterContext(context)
    }

    companion object {
        private const val COMPILED_SCRIPT_CACHE_ENTRIES = 256
        private const val COMPILED_SCRIPT_CACHE_CHARS = 2_000_000L

        /**
         * 判断脚本是否存在**顶层** `return`。
         *
         * 只有顶层 `return` 才需要把脚本包进 `(function(){…})()`（否则 Rhino 会抛
         * `return not in function`，见部落知识 TK-06）。此前的判定用 `Regex("\\breturn\\b")`，
         * 会命中函数体、字符串、注释里的 `return` ⇒ 整段（含 jsLib）被包裹，
         * 导致 Rhino 的**求值补全值退化为 undefined**，聚合源正文因此取空。
         * （实测过程见 历史实现说明。）
         *
         * 本实现为引号/注释/模板字面量感知的括号扫描：return 只有不在函数体内时
         * 才意味着整个程序必须包 IIFE（包含 `if { return ... }` 这类顶层分支）。
         */
        internal fun hasTopLevelReturn(script: String): Boolean {
            var i = 0
            var depth = 0
            val functionStack = mutableListOf<Boolean>()
            var pendingFunction = false
            var pendingArrow = false
            val n = script.length
            while (i < n) {
                when (val c = script[i]) {
                    '\'', '"' -> {
                        val quote = c
                        i++
                        while (i < n && script[i] != quote) {
                            if (script[i] == '\\') i++
                            i++
                        }
                        i++
                    }
                    '`' -> {
                        i++
                        while (i < n && script[i] != '`') {
                            if (script[i] == '\\') i++
                            i++
                        }
                        i++
                    }
                    '/' -> {
                        val next = if (i + 1 < n) script[i + 1] else ' '
                        if (next == '/') {
                            i += 2
                            while (i < n && script[i] != '\n') i++
                        } else if (next == '*') {
                            i += 2
                            while (i + 1 < n && !(script[i] == '*' && script[i + 1] == '/')) i++
                            i += 2
                        } else {
                            i++
                        }
                    }
                    '(', '[', '{' -> {
                        if (c == '{') {
                            functionStack.add(pendingFunction || pendingArrow)
                            pendingFunction = false
                            pendingArrow = false
                        }
                        depth++; i++
                    }
                    ')', ']', '}' -> {
                        if (c == '}') functionStack.removeLastOrNull()
                        depth--; i++
                    }
                    else -> {
                        if (script.startsWith("function", i) &&
                            (i == 0 || !script[i - 1].isLetterOrDigit() && script[i - 1] != '_' && script[i - 1] != '$')
                        ) {
                            pendingFunction = true
                        }
                        if (c == '=' && script.getOrNull(i + 1) == '>') {
                            pendingArrow = true
                        }
                        if (functionStack.none { it } && c == 'r' && script.startsWith("return", i)) {
                            val prev = script.substring(0, i).lastOrNull { !it.isWhitespace() }
                            val after = script.getOrNull(i + 6)
                            val prevIsWord = prev != null && (prev.isLetterOrDigit() || prev == '_' || prev == '$')
                            val afterIsWord = after != null && (after.isLetterOrDigit() || after == '_' || after == '$')
                            if (!prevIsWord && !afterIsWord) return true
                        }
                        i++
                    }
                }
            }
            pendingFunction = false
            pendingArrow = false
            return false
        }
    }

    /**
     * Small access-ordered cache shared by callers of one [JsSandbox].
     *
     * Only immutable compiled programs are retained. JavaScript globals,
     * bindings, variables, cookies and errors continue to live in the scope
     * created for each individual evaluation.
     */
    private class CompiledScriptCache {
        private data class Key(val sourceName: String, val source: String)
        private val entries = object : LinkedHashMap<Key, Script>(32, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Script>?): Boolean {
                val tooMany = size > COMPILED_SCRIPT_CACHE_ENTRIES
                val tooLarge = retainedChars > COMPILED_SCRIPT_CACHE_CHARS
                if (!tooMany && !tooLarge) return false
                if (eldest != null) retainedChars -= eldest.key.source.length.toLong()
                return true
            }
        }
        private var retainedChars = 0L

        @Synchronized
        fun get(sourceName: String, source: String): Script? = entries[Key(sourceName, source)]

        @Synchronized
        fun put(sourceName: String, source: String, script: Script) {
            if (source.length > COMPILED_SCRIPT_CACHE_CHARS) return
            val key = Key(sourceName, source)
            entries.put(key, script)?.let { retainedChars -= source.length.toLong() }
            retainedChars += source.length.toLong()
        }
    }

    /** `chapter` 桥接对象：正文规则会引用 chapter.index / chapter.title，缺失会让整段脚本中断。 */
    private fun createChapterBridge(scope: Scriptable, execContext: JsExecutionContext?): NativeObject {
        val chapter = NativeObject()
        chapter.parentScope = scope
        ScriptableObject.putProperty(chapter, "index", execContext?.chapterIndex ?: 0)
        ScriptableObject.putProperty(chapter, "title", execContext?.chapterTitle ?: "")
        ScriptableObject.putProperty(chapter, "url", execContext?.chapterUrl ?: "")
        ScriptableObject.putProperty(chapter, "start", 0)
        ScriptableObject.putProperty(chapter, "end", 0)
        return chapter
    }

    /**
     * `book` 桥接对象。
     *
     * 语义**逐条对齐开源阅读**（`legado-with-MD3`）：
     * - `book.variable` = **整张变量表的 JSON 字符串**（Legado `BaseBook.variable = GSON.toJson(variableMap)`）；
     *   书源里 `JSON.parse(book.variable)`、`if (!book.variable)` 这类写法都依赖它。空表给**空串**
     *   （保持假值语义，与"从未设置过"一致）；
     * - `book.variableMap` = 变量表本身（Legado 由 `RuleDataInterface` 暴露）；
     * - `book.getVariable(key)`：**键不存在返回空串**（Legado：`variableMap[key] ?: getBigVariable(key) ?: ""`）
     *   —— 这里**刻意不是**字符串 `"null"`；
     * - `book.putVariable(key, value)`：`value == null` ⇒ **删除该键**，否则写入（Legado 同款分派）。
     *
     * 规则执行期间对变量的修改只落在内存表里；调用方（Routes）在规则跑完后比对并落库，
     * 与 Legado「改完 Book 对象再 saveBook」等价。
     */
    private fun createBookBridge(scope: Scriptable, execContext: JsExecutionContext?): NativeObject {
        val book = NativeObject()
        book.parentScope = scope
        val variables = execContext?.bookVariables ?: mutableMapOf()
        ScriptableObject.putProperty(book, "type", execContext?.bookType ?: 0)
        ScriptableObject.putProperty(book, "name", execContext?.bookName ?: "")
        ScriptableObject.putProperty(book, "author", execContext?.bookAuthor ?: "")
        ScriptableObject.putProperty(book, "bookUrl", execContext?.bookUrl ?: "")
        ScriptableObject.putProperty(book, "tocUrl", execContext?.bookTocUrl ?: "")
        ScriptableObject.putProperty(book, "kind", execContext?.bookKind ?: "")
        ScriptableObject.putProperty(book, "durChapterIndex", execContext?.chapterIndex ?: 0)
        ScriptableObject.putProperty(book, "durChapterTitle", "")
        ScriptableObject.putProperty(book, "order", 0)
        val readConfig = NativeObject()
        readConfig.parentScope = scope
        ScriptableObject.putProperty(book, "readConfig", readConfig)

        // `variable` / `variableMap` 必须在**每次写入后**重新同步：
        // 书源里"先 putVariable 再 JSON.parse(book.variable)"是真实写法，读到旧值就前功尽弃。
        val variableMap = NativeObject()
        variableMap.parentScope = scope
        fun syncVariableViews() {
            ScriptableObject.putProperty(book, "variable", bookVariableJson(variables))
            variables.forEach { (key, value) -> ScriptableObject.putProperty(variableMap, key, value) }
        }
        syncVariableViews()
        // ⚠️ 这一行不能少：只声明不挂载 ⇒ JS 里 `book.variableMap` 是 `undefined`，
        // 而 `book.variableMap['x']` 会抛 TypeError。**抛在规则内部是静默的**（`<js>` 求值失败后
        // 正文规则会回退到页面正文抽取，不报错），表现为"书源规则没生效"却毫无提示。
        // 实测由本文件的用例抓出：漏挂载时 `typeof book.variableMap` 是 `'undefined'`。
        ScriptableObject.putProperty(book, "variableMap", variableMap)

        ScriptableObject.putProperty(book, "getVariable", object : BaseFunction() {
            override fun call(cx: Context, s: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val key = args.firstOrNull()?.toString() ?: return ""
                // Legado：缺失返回**空串**
                return variables[key] ?: ""
            }
        })
        ScriptableObject.putProperty(book, "putVariable", object : BaseFunction() {
            override fun call(cx: Context, s: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val key = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                val raw = args.getOrNull(1)
                if (raw == null || raw === Context.getUndefinedValue()) variables.remove(key)
                else variables[key] = raw.toString()
                syncVariableViews()
                return Context.getUndefinedValue()
            }
        })
        // 兼容别名：书源生态里 `setVariable` 也常见（Legado 的老写法）
        ScriptableObject.putProperty(book, "setVariable", object : BaseFunction() {
            override fun call(cx: Context, s: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val key = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                variables[key] = args.getOrNull(1)?.toString() ?: ""
                syncVariableViews()
                return Context.getUndefinedValue()
            }
        })
        ScriptableObject.putProperty(book, "setUseReplaceRule", object : BaseFunction() {
            override fun call(cx: Context, s: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val value = args.firstOrNull()
                execContext?.useReplaceRule = value != null && ScriptRuntime.toBoolean(value)
                return Context.getUndefinedValue()
            }
        })
        return book
    }

    /**
     * 变量表 → **JSON 字符串**（`book.variable`）。
     *
     * 空表返回空串而不是 `"{}"`：书源里 `if (!book.variable)` 这类判空在"确实没有变量"时要成立
     * —— 这正是 `🍅大灰狼聚合` 源判断"缺少必要参数"的那一行。
     *
     * 手写而不是用 kotlinx 序列化：这是**给 JS 用的**字符串，必须保证与 `JSON.parse` 互通，
     * 且转义要显式覆盖引号/反斜杠/控制字符（书名里出现换行是真实数据，见 AGENTS.md）。
     */
    private fun bookVariableJson(variables: Map<String, String>): String =
        if (variables.isEmpty()) "" else buildString {
            append('{')
            variables.entries.forEachIndexed { index, (key, value) ->
                if (index > 0) append(',')
                append('"').append(escapeJsonText(key)).append("\":\"").append(escapeJsonText(value)).append('"')
            }
            append('}')
        }

    private fun escapeJsonText(raw: String): String = buildString(raw.length + 8) {
        raw.forEach { char ->
            when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (char < ' ') append("\\u%04x".format(char.code)) else append(char)
            }
        }
    }

    /**
     * `JavaImporter` 的安全替身。     *
     * Legado 的 Rhino 环境提供 `JavaImporter`，大量书源的 jsLib 用它配合 `with` 语句组织工具函数库。
     * 沙箱出于安全禁用真实 Java 反射，因此这里只返回一个**空的**导入器：importClass/importPackage
     * 为空操作，不暴露任何 Java 能力，但足以让脚本不再抛 ReferenceError、正常完成函数定义。
     */
    private fun createJavaImporterStub(scope: Scriptable): BaseFunction = object : BaseFunction() {
        override fun call(cx: Context, s: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
            val importer = NativeObject()
            importer.parentScope = scope
            val noop = object : BaseFunction() {
                override fun call(cx: Context, s: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any =
                    Context.getUndefinedValue()
            }
            ScriptableObject.putProperty(importer, "importClass", noop)
            ScriptableObject.putProperty(importer, "importPackage", noop)
            return importer
        }

        override fun construct(cx: Context, s: Scriptable, args: Array<out Any?>): Scriptable =
            call(cx, s, s, args) as Scriptable
    }

    private fun unwrapJsBridge(value: Any?): Any? = when (value) {
        is JsStrResponseBridge -> value.response
        is NativeJavaObject -> value.unwrap()
        else -> value
    }

    private fun jsValueToString(context: Context, scope: Scriptable, value: Any?): String? = when (value) {
        null, Context.getUndefinedValue() -> null
        is JsStrResponseBridge -> value.response.toString()
        is CharSequence -> value.toString()
        is Number, is Boolean -> value.toString()
        is ByteArray -> String(value, Charsets.UTF_8)
        else -> runCatching {
            NativeJSON.stringify(context, scope, value, null, null).toString()
        }.getOrNull() ?: value.toString()
    }

    private fun createSourceBridge(
        scope: Scriptable,
        sourceId: String,
        db: Database?,
        execContext: JsExecutionContext?,
    ): NativeObject = NativeObject().also { api ->
        api.parentScope = scope

        // source.bookSourceUrl / source.getKey() / source.key
        val keyFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any = sourceId
        }
        ScriptableObject.putProperty(api, "getKey", keyFn)
        ScriptableObject.putProperty(api, "bookSourceUrl", sourceId)
        ScriptableObject.putProperty(api, "key", sourceId)
        ScriptableObject.putProperty(api, "bookSourceName", execContext?.sourceName ?: sourceId)
        ScriptableObject.putProperty(api, "bookSourceComment", execContext?.sourceComment ?: "")
        // Android 的 `source` 就是 BookSource 实体（`NativeBaseSource` 只挡 setter），
        // 脚本可以读任意标量字段（典型：`typeof source.loginUi == 'function'` 的客户端探测、
        // `source.bookSourceType` 分支）。这里把定义里的标量字段原样挂上，
        // 未在定义中出现的字段保持"没有该属性"（与实体上的默认值一致时行为不变）。
        execContext?.sourceJson?.forEach { (field, value) ->
            if (field == "bookSourceUrl" || field == "bookSourceName" || field == "bookSourceComment") return@forEach
            if (ScriptableObject.hasProperty(api, field)) return@forEach
            toJsValue(jsonScalarValue(value), scope)?.let { ScriptableObject.putProperty(api, field, it) }
        }

        // source.getLoginInfo() -> JSON string
        ScriptableObject.putProperty(api, "getLoginInfo", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val current = mutableMapOf<String, String>().apply {
                    putAll(execContext?.loginUiDefaults ?: emptyMap())
                    putAll(db?.getSourceLoginState(sourceId)?.loginInfo ?: emptyMap())
                    putAll(execContext?.initialLoginInfo ?: emptyMap())
                }
                return Json.encodeToString(current)
            }
        })

        // source.getLoginInfoMap() -> NativeObject
        ScriptableObject.putProperty(api, "getLoginInfoMap", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val current = LinkedHashMap<String, String>()
                current.apply {
                    putAll(execContext?.loginUiDefaults ?: emptyMap())
                    putAll(db?.getSourceLoginState(sourceId)?.loginInfo ?: emptyMap())
                    putAll(execContext?.initialLoginInfo ?: emptyMap())
                }
                // Android 返回 Java Map：源脚本用 info.get('key') 读取；沙箱白名单
                // 放行 java.util 后方法调用可用，同时保留 Rhino 的属性访问兼容。
                return LoginInfoMapBridge(current, scope, execContext)
            }
        })

        // source.putLoginInfo(info)
        ScriptableObject.putProperty(api, "putLoginInfo", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val arg = args.firstOrNull() ?: return false
                val map = parseJsMapOrJson(arg)
                if (execContext != null) {
                    execContext.initialLoginInfo.clear()
                    execContext.initialLoginInfo.putAll(map)
                }
                db?.saveSourceLoginInfo(sourceId, execContext?.initialLoginInfo ?: map)
                return true
            }
        })

        // source.removeLoginInfo()
        ScriptableObject.putProperty(api, "removeLoginInfo", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                execContext?.initialLoginInfo?.clear()
                db?.removeSourceLoginInfo(sourceId)
                return true
            }
        })

        // source.getLoginHeader()
        ScriptableObject.putProperty(api, "getLoginHeader", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return db?.getSourceLoginState(sourceId)?.loginHeader ?: ""
            }
        })

        // source.getLoginHeaderMap()
        ScriptableObject.putProperty(api, "getLoginHeaderMap", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val header = db?.getSourceLoginState(sourceId)?.loginHeader ?: ""
                val map = runCatching { Json.decodeFromString<Map<String, String>>(header) }.getOrDefault(emptyMap())
                return toJsValue(map, scope) ?: NativeObject().also { it.parentScope = scope }
            }
        })

        // source.putLoginHeader(header)
        ScriptableObject.putProperty(api, "putLoginHeader", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val h = args.firstOrNull()?.toString() ?: ""
                db?.saveSourceLoginHeader(sourceId, h)
                val cookie = runCatching { Json.decodeFromString<Map<String, String>>(h) }.getOrNull()
                    ?.let { it["Cookie"] ?: it["cookie"] }
                if (!cookie.isNullOrBlank()) {
                    val normalizedCookie = cookie.split(';')
                        .mapNotNull { part ->
                            val pair = part.trim()
                            val separator = pair.indexOf('=')
                            if (separator <= 0) return@mapNotNull null
                            val name = pair.substring(0, separator).trim()
                            if (name.isEmpty() || name in setOf(
                                    "Path", "Domain", "Expires", "Max-Age", "HttpOnly", "Secure", "SameSite", "Partitioned",
                                )
                            ) {
                                return@mapNotNull null
                            }
                            "$name=${pair.substring(separator + 1).trim()}"
                        }
                        .joinToString("; ")
                    if (normalizedCookie.isNotBlank()) {
                        db?.setSourceCookie(sourceId, sourceId, normalizedCookie)
                    }
                }
                return true
            }
        })

        // source.removeLoginHeader()
        ScriptableObject.putProperty(api, "removeLoginHeader", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                db?.removeSourceLoginHeader(sourceId)
                return true
            }
        })

        // source.getVariable()
        ScriptableObject.putProperty(api, "getVariable", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return db?.getSourceVariable(sourceId) ?: ""
            }
        })

        // source.setVariable(val)
        ScriptableObject.putProperty(api, "setVariable", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val v = args.firstOrNull()?.toString() ?: ""
                db?.saveSourceVariable(sourceId, v)
                return v
            }
        })

        // source.put(key, val)
        ScriptableObject.putProperty(api, "put", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val k = args.getOrNull(0)?.toString() ?: return Context.getUndefinedValue()
                val raw = args.getOrNull(1)?.takeUnless { it === Context.getUndefinedValue() }
                if (raw == null) {
                    // Android `BaseSource.put(key, null)` → `CacheManager.put(key, null)` = 删除。
                    sourceKvRemove(sourceId, db, k)
                    return Context.getUndefinedValue()
                }
                val v = raw.toString()
                sourceKvPut(sourceId, db, k, v)
                return v
            }
        })

        // source.get(key)
        ScriptableObject.putProperty(api, "get", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val k = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                // Android `BaseSource.get(key) = CacheManager.get("v_${getKey()}_${key}") ?: ""`。
                return sourceKvGet(sourceId, db, k) ?: ""
            }
        })
    }

    private fun createCookieBridge(
        scope: Scriptable,
        sourceId: String,
        db: Database?,
    ): NativeObject = NativeObject().also { api ->
        api.parentScope = scope

        // cookie.getCookie(url)
        ScriptableObject.putProperty(api, "getCookie", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: return ""
                return db?.getSourceCookie(sourceId, url) ?: ""
            }
        })

        // cookie.setCookie(url, cookie)
        // Android `CookieStore.setCookie/replaceCookie/setWebCookie/removeCookie` 全部返回 Unit
        // ⇒ JS 里是 undefined ⇒ URL 模板 `{{cookie.removeCookie(url)}}/path` 只替换成空串。
        // 旧实现返回写入的 cookie 文本/true，会被原样拼进 URL（实测把搜索地址变成
        // `true/search.html`），属于必须对齐的返回值语义。
        val setFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.getOrNull(0)?.toString() ?: return Context.getUndefinedValue()
                val c = args.getOrNull(1)?.toString() ?: return Context.getUndefinedValue()
                db?.setSourceCookie(sourceId, url, c)
                return Context.getUndefinedValue()
            }
        }
        ScriptableObject.putProperty(api, "setCookie", setFn)
        ScriptableObject.putProperty(api, "replaceCookie", setFn)
        ScriptableObject.putProperty(api, "setWebCookie", setFn)

        // cookie.removeCookie(url)
        ScriptableObject.putProperty(api, "removeCookie", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                db?.removeSourceCookie(sourceId, url)
                return Context.getUndefinedValue()
            }
        })

        // cookie.getKey(url, key)
        ScriptableObject.putProperty(api, "getKey", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.getOrNull(0)?.toString() ?: return ""
                val key = args.getOrNull(1)?.toString() ?: return ""
                val cookieStr = db?.getSourceCookie(sourceId, url) ?: ""
                val map = parseCookieString(cookieStr)
                return map[key] ?: ""
            }
        })

        // cookie.mapToCookie(map)
        ScriptableObject.putProperty(api, "mapToCookie", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val arg = args.firstOrNull() ?: return ""
                val map = parseJsMapOrJson(arg)
                return map.entries.joinToString("; ") { "${it.key}=${it.value}" }
            }
        })
    }

    private fun createJavaBridge(
        scope: Scriptable,
        execContext: JsExecutionContext?,
    ): NativeObject = NativeObject().also { api ->
        api.parentScope = scope

        // Android `AnalyzeRule.setContent(...)` 替换的是**同一实例**的内容：书源普遍写成
        // `java.setContent(res.body()); java.getElement(path);`（如 🔞第一版主）——后续
        // `java.getElement/getString` 必须看到新内容。这里用本次求值（本次 bridge 实例）
        // 的闭包变量承载，生命周期与 Android 每字段新建的 AnalyzeRule 一致，不会漏到别的字段。
        var contentOverride: String? = null

        // java.ajax(url)
        ScriptableObject.putProperty(api, "ajax", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: return ""
                val callTimeoutMillis = args.getOrNull(1)?.let { value ->
                    (value as? Number)?.toLong() ?: ScriptRuntime.toNumber(value).toLong()
                }
                if (url.startsWith("data:text/html;base64,")) {
                    val encoded = url.removePrefix("data:text/html;base64,")
                    return runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }.getOrDefault("")
                }
                return try {
                    runner?.fetchResponse(
                        url,
                        sourceId = execContext?.sourceId,
                        source = execContext?.sourceJson,
                        database = execContext?.database,
                        callTimeoutMillis = callTimeoutMillis,
                    )
                        ?.body ?: ""
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        })

        // java.post(url, body, headers)
        ScriptableObject.putProperty(api, "post", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.getOrNull(0)?.toString() ?: return ""
                val body = args.getOrNull(1)?.toString() ?: ""
                val headers = args.getOrNull(2)?.let { parseJsMapOrJson(it) } ?: emptyMap()
                // 严禁用 mapOf(...)+encodeToString：其静态类型是 Map<String, Any>，
                // kotlinx 会抛 "Serializer for class 'Any' is not found"，
                // 且该异常位于归一化 try/catch 之外 ⇒ 桥接静默返回 null。
                val fullUrl = "$url,${buildUrlOptionsJson("POST", body, headers)}"
                return try {
                    // Android JsExtensions.post 使用 requestBody(body) 原样发送，不经过
                    // AnalyzeUrl 的表单编码；同时 followRedirects(false) 必须先返回首个 3xx。
                    runner?.fetchResponse(
                        fullUrl,
                        sourceId = execContext?.sourceId,
                        source = execContext?.sourceJson,
                        database = execContext?.database,
                        callTimeoutMillis = args.getOrNull(3)?.let { value ->
                            (value as? Number)?.toLong() ?: ScriptRuntime.toNumber(value).toLong()
                        } ?: 30_000L,
                        firstResponseOnly = true,
                        formEncodeBody = false,
                        hostnamePolicy = SourceHostnamePolicy.ANDROID_JSOUP,
                    )
                        ?.let { toJsResponse(it, scope) } ?: ""
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        })

        // java.get(url[, headers]) —— HTTP GET
        // 注意：此方法**不能**再被同名属性覆盖（历史上 748 行的 session store 曾把
        // 它整个顶掉，导致 java.get 静默失效、永远返回 session 值或 undefined）。
        // 两种语义改为在同一函数内按参数形态分派：http(s) 开头视为 URL 请求，
        // 否则视为读取 session store（保持 java.put 的既有配对语义）。
        ScriptableObject.putProperty(api, "get", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val first = args.getOrNull(0)?.toString() ?: return Context.getUndefinedValue()
                val isHttp = first.startsWith("http://", ignoreCase = true) ||
                    first.startsWith("https://", ignoreCase = true)
                if (!isHttp) {
                    // Android `AnalyzeRule.get`：bookName/title 先被书籍/章节字段覆盖，其余按
                    // 章节/书籍变量 → 规则数据 → `BaseSource.get`（CacheManager 的 `v_<源>_<键>`）
                    // 顺序读取，**读不到返回空串**（不是 undefined，源脚本常直接对它做字符串操作）。
                    if (first == "bookName") return execContext?.bookName ?: ""
                    if (first == "title") return execContext?.chapterTitle ?: ""
                    execContext?.bookVariables?.get(first)?.let { return it }
                    sourceKvGet(execContext?.sourceId, execContext?.database ?: runner?.database, first)?.let { return it }
                    return sessionStore[first] ?: ""
                }
                val headers = args.getOrNull(1)?.let { parseJsMapOrJson(it) } ?: emptyMap()
                val fullUrl = "$first,${buildUrlOptionsJson("GET", null, headers)}"
                return try {
                    // Android JsExtensions.get 使用 Jsoup .followRedirects(false)，源脚本
                    // 依赖首个 302 的 Location；不能落入公共声明式抓取的跟随重定向循环。
                    runner?.fetchResponse(
                        fullUrl,
                        sourceId = execContext?.sourceId,
                        source = execContext?.sourceJson,
                        database = execContext?.database,
                        callTimeoutMillis = args.getOrNull(2)?.let { value ->
                            (value as? Number)?.toLong() ?: ScriptRuntime.toNumber(value).toLong()
                        } ?: 30_000L,
                        firstResponseOnly = true,
                        hostnamePolicy = SourceHostnamePolicy.ANDROID_JSOUP,
                    )
                        ?.let { toJsResponse(it, scope) } ?: ""
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        })

        // java.toast(msg) / java.longToast(msg)
        val toastFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val msg = args.firstOrNull()?.toString()?.trim() ?: return Context.getUndefinedValue()
                if (msg.isNotBlank()) {
                    execContext?.toastMessages?.add(msg)
                }
                return Context.getUndefinedValue()
            }
        }
        ScriptableObject.putProperty(api, "toast", toastFn)
        ScriptableObject.putProperty(api, "longToast", toastFn)

        // java.getCookie(tag[,key])：Android getCookie/getKey 走同一个 source tag。
        ScriptableObject.putProperty(api, "getCookie", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val tag = args.getOrNull(0)?.toString() ?: return ""
                val database = execContext?.database ?: runner?.database
                val sourceId = execContext?.sourceId
                if (sourceId.isNullOrBlank() || database == null) return ""
                val key = args.getOrNull(1)?.toString()
                if (key == null) return database.getSourceCookie(sourceId, tag) ?: ""
                return database.getSourceCookie(sourceId, tag)
                    ?.let { parseCookieString(it)[key] } ?: ""
            }
        })

        // java.log(msg) —— Android 的 log 返回入参本身（书源常写 `java.log(x) || y` 之类的串联），
        // 返回 undefined 会让这类规则静默变成空值。
        ScriptableObject.putProperty(api, "log", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return args.firstOrNull() ?: Context.getUndefinedValue()
            }
        })

        // java.logType(any) —— Android 打印入参的 Java 类名；无 IDE 可看时退化为 log。
        ScriptableObject.putProperty(api, "logType", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val value = args.firstOrNull()
                if (value == null || value === Context.getUndefinedValue()) return ""
                return (value as? NativeJavaObject)?.unwrap()?.javaClass?.name ?: value.javaClass.name
            }
        })

        // java.startBrowser(url, title) / java.startBrowserAwait(url, title) / java.openWeb(url)
        val startBrowserFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: ""
                execContext?.openUrl = url
                val title = args.getOrNull(1)?.toString() ?: ""
                val html = args.getOrNull(2)?.toString()
                execContext?.pendingVerifications?.add(
                    BrowserVerification(execContext?.sourceId ?: "", url, title, html, await = false, refetch = false),
                )
                // 非 await：只发待验证事件，绝不声称完成；有 hook 时也走事件通道。
                execContext?.browserHook?.start(execContext?.sourceId ?: "", url, title, html, await = false, refetch = false)
                return Context.getUndefinedValue()
            }
        }
        ScriptableObject.putProperty(api, "webViewGetSource", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val hook = execContext?.browserHook
                    ?: throw IllegalStateException("需要浏览器验证/浏览器运行时未配置")
                val sourceRegex = args.getOrNull(3)?.toString()
                    ?: throw IllegalArgumentException("webViewGetSource sourceRegex is required")
                threadBudget.get()?.pauseWallClock()
                try {
                    return hook.webViewGetSource(
                        execContext?.sourceId ?: "",
                        args.getOrNull(0)?.toString(),
                        args.getOrNull(1)?.toString(),
                        args.getOrNull(2)?.toString(),
                        sourceRegex,
                        args.getOrNull(4)?.let { ScriptRuntime.toBoolean(it) } ?: false,
                        (args.getOrNull(5) as? Number)?.toLong() ?: 0L,
                    ) ?: Context.getUndefinedValue()
                } finally {
                    threadBudget.get()?.resumeWallClock()
                }
            }
        })
        ScriptableObject.putProperty(api, "webViewGetOverrideUrl", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val hook = execContext?.browserHook
                    ?: throw IllegalStateException("需要浏览器验证/浏览器运行时未配置")
                val overrideUrlRegex = args.getOrNull(3)?.toString()
                    ?: throw IllegalArgumentException("webViewGetOverrideUrl overrideUrlRegex is required")
                threadBudget.get()?.pauseWallClock()
                try {
                    return hook.webViewGetOverrideUrl(
                        execContext?.sourceId ?: "",
                        args.getOrNull(0)?.toString(),
                        args.getOrNull(1)?.toString(),
                        args.getOrNull(2)?.toString(),
                        overrideUrlRegex,
                        args.getOrNull(4)?.let { ScriptRuntime.toBoolean(it) } ?: false,
                        (args.getOrNull(5) as? Number)?.toLong() ?: 0L,
                    ) ?: Context.getUndefinedValue()
                } finally {
                    threadBudget.get()?.resumeWallClock()
                }
            }
        })
        val startBrowserAwaitFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: ""
                execContext?.openUrl = url
                val hook = execContext?.browserHook
                if (hook == null) {
                    // 内联页必须回传给前端打开内置浏览器；无头沙箱没有 hook 时也不能把它误判成验证失败。
                    if (url.startsWith("data:", ignoreCase = true)) {
                        return JsStrResponseBridge(JsStrResponse(url, ""))
                    }
                    throw IllegalStateException("需要浏览器验证/浏览器运行时未配置")
                }
                threadBudget.get()?.pauseWallClock()
                try {
                    val response = hook.start(
                        execContext?.sourceId ?: "",
                        url,
                        args.getOrNull(1)?.toString() ?: "",
                        args.getOrNull(3)?.toString(),
                        await = true,
                        refetch = args.getOrNull(2)?.let { ScriptRuntime.toBoolean(it) } ?: true,
                    ) ?: throw IllegalStateException("需要浏览器验证/浏览器验证未完成")
                    execContext?.openUrl = null
                    return JsStrResponseBridge(response)
                } finally {
                    threadBudget.get()?.resumeWallClock()
                }
            }
        }
        ScriptableObject.putProperty(api, "getVerificationCode", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val hook = execContext?.browserHook
                    ?: throw IllegalStateException("需要浏览器验证/浏览器运行时未配置")
                val url = args.firstOrNull()?.toString() ?: ""
                threadBudget.get()?.pauseWallClock()
                try {
                    return hook.start(execContext?.sourceId ?: "", url, "验证码", null, await = true, refetch = false)
                        ?.body ?: throw IllegalStateException("需要浏览器验证/验证码输入未完成")
                } finally {
                    threadBudget.get()?.resumeWallClock()
                }
            }
        })
        ScriptableObject.putProperty(api, "initUrl", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return args.firstOrNull()?.toString() ?: execContext?.baseUrl ?: ""
            }
        })
        ScriptableObject.putProperty(api, "getStrResponse", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: execContext?.baseUrl ?: ""
                return try {
                    JsStrResponseBridge(JsStrResponse(url, runner?.fetch(url, execContext?.sourceId, execContext?.database)))
                } catch (error: Throwable) {
                    JsStrResponseBridge(JsStrResponse(url, error.message ?: error.javaClass.simpleName, code = 0, message = error.javaClass.simpleName))
                }
            }
        })
        ScriptableObject.putProperty(api, "importScript", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val path = args.firstOrNull()?.toString() ?: throw IllegalArgumentException("importScript path is required")
                val content = runner?.fetch(path, execContext?.sourceId, execContext?.database)
                    ?: throw IllegalStateException("$path 内容获取失败或者为空")
                if (content.isBlank()) throw IllegalStateException("$path 内容获取失败或者为空")
                return content
            }
        })
        ScriptableObject.putProperty(api, "startBrowser", startBrowserFn)
        ScriptableObject.putProperty(api, "startBrowserAwait", startBrowserAwaitFn)
        // openWeb 与 Android 一致是“打开网页”动作：只发待验证事件，不等待结果。
        ScriptableObject.putProperty(api, "openWeb", startBrowserFn)
        // 聚合类书源常用的其它打开网页别名
        ScriptableObject.putProperty(api, "showBrowser", startBrowserFn)
        ScriptableObject.putProperty(api, "showReadingBrowser", startBrowserFn)
        ScriptableObject.putProperty(api, "startBrowserDp", startBrowserFn)

        // java.getWebViewUA()：部分书源用它给站点请求伪装 WebView 的 UA
        ScriptableObject.putProperty(api, "getWebViewUA", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any =
                "Mozilla/5.0 (Linux; Android 13; Pixel 5 Build/TQ3A.230805.001; wv) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Version/4.0 Chrome/131.0.0.0 Mobile Safari/537.36"
        })

        // ---------- WebView 通道（Android JsExtensions.webView） ----------
        // Android：`html` 非空时用 webView 载入这段 HTML（`url` 作为相对资源基准），
        // `js` 为空返回整页源码，非空则返回该 JS 的求值结果；`cacheFirst` 只是优先用缓存。
        // 服务端把同一件事交给无头浏览器通道（BrowserRuntime），`cacheFirst` 无对应物（无浏览器缓存）⇒ 忽略。
        ScriptableObject.putProperty(api, "webView", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val html = args.getOrNull(0)?.toString()?.takeIf { it.isNotBlank() && it != "null" }
                val url = args.getOrNull(1)?.toString().orEmpty()
                val js = args.getOrNull(2)?.toString()?.takeIf { it.isNotBlank() && it != "null" }
                if (url.isBlank()) return null
                val runtime = runner?.browserRuntime ?: return null
                val headers = execContext?.sourceJson?.let { source ->
                    runCatching { runner?.mediaHeaders(source.toString(), execContext.sourceId) }.getOrNull()
                }.orEmpty()
                threadBudget.get()?.pauseWallClock()
                return try {
                    runtime.webViewSnapshot(
                        sourceId = execContext?.sourceId ?: url,
                        url = url,
                        html = html,
                        js = js,
                        headers = headers,
                    ).body
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                } finally {
                    threadBudget.get()?.resumeWallClock()
                }
            }
        })

        // ---------- 阅读界面配置（服务端没有界面，报告 Android 出厂默认值） ----------
        ScriptableObject.putProperty(api, "getThemeMode", constantFunction { ClientConfigDefaults.THEME_MODE })
        ScriptableObject.putProperty(api, "getThemeConfig", constantFunction { ClientConfigDefaults.themeConfigJson() })
        ScriptableObject.putProperty(api, "getReadBookConfig", constantFunction { ClientConfigDefaults.readBookConfigJson() })
        // `getXxxConfigMap` 必须交给 JS **原生对象**：直接把 `java.util.LinkedHashMap` 递出去，
        // 沙箱的 ClassShutter 会拒绝脚本访问（`map.themeName` → 报错），Android 侧 Rhino
        // 也是把 Map 当普通对象暴露给脚本的。
        ScriptableObject.putProperty(api, "getThemeConfigMap", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any =
                toJsValue(ClientConfigDefaults.themeConfigMap(), scope)!!
        })
        ScriptableObject.putProperty(api, "getReadBookConfigMap", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any =
                toJsValue(ClientConfigDefaults.readBookConfigMap(), scope)!!
        })

        // ---------- 字体混淆（Android JsExtensions.queryTTF / replaceFont） ----------
        // `data` 与 Android 一致地自动判定：http(s) 地址 / base64 / 字节数组；`useCache` 默认 true。
        ScriptableObject.putProperty(api, "queryTTF", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? =
                queryTtf(args.getOrNull(0), args.getOrNull(1)?.let { Context.toBoolean(it) } ?: true, execContext)
        })
        // 已过时的别名：Android 会打一条日志后转调 queryTTF。
        ScriptableObject.putProperty(api, "queryBase64TTF", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                execContext?.toastMessages?.add("queryBase64TTF(String)方法已过时,请改用queryTTF(Any)")
                return queryTtf(args.getOrNull(0), true, execContext)
            }
        })
        ScriptableObject.putProperty(api, "replaceFont", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.getOrNull(0)?.toString()
                val errorTtf = unwrapJsBridge(args.getOrNull(1)) as? QueryTTF
                val correctTtf = unwrapJsBridge(args.getOrNull(2)) as? QueryTTF
                val filter = args.getOrNull(3)?.let { Context.toBoolean(it) } ?: false
                return QueryTtf.replaceFont(text, errorTtf, correctTtf, filter)
            }
        })

        // ---------- 界面动作（服务端无对应交互） ----------
        // Android `openUrl`：用系统/内置浏览器打开地址；`openVideoPlayer`：内置播放器。
        // 服务端没有 UI 进程，但**不能缺失**（书源里的 `openUrl(...)` 缺失会让整段脚本中断），
        // 因此这里只记录意图（登录/验证流程可读 `execContext.openUrl`），不打开任何东西。
        ScriptableObject.putProperty(api, "openUrl", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                require(url.length < 64 * 1024) { "openUrl parameter url too long" }
                execContext?.openUrl = url
                return Context.getUndefinedValue()
            }
        })
        ScriptableObject.putProperty(api, "openVideoPlayer", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any =
                Context.getUndefinedValue()
        })

        // java.copyText(text)
        ScriptableObject.putProperty(api, "copyText", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                execContext?.copyText = args.firstOrNull()?.toString() ?: ""
                return Context.getUndefinedValue()
            }
        })

        // java.upLoginData(data)
        ScriptableObject.putProperty(api, "upLoginData", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val arg = args.firstOrNull()
                if (arg != null) {
                    val map = parseJsMapOrJson(arg)
                    execContext?.initialLoginInfo?.putAll(map)
                }
                execContext?.reRenderUi = true
                return Context.getUndefinedValue()
            }
        })

        // java.reLoginView(deltaUp) / java.reUiView()
        val reUiFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                execContext?.reRenderUi = true
                return Context.getUndefinedValue()
            }
        }
        ScriptableObject.putProperty(api, "reLoginView", reUiFn)
        ScriptableObject.putProperty(api, "reUiView", reUiFn)
        ScriptableObject.putProperty(api, "refreshExplore", reUiFn)
        ScriptableObject.putProperty(api, "refreshBookInfo", reUiFn)
        ScriptableObject.putProperty(api, "refreshBookToc", reUiFn)
        ScriptableObject.putProperty(api, "refreshContent", reUiFn)

        // java.base64Decode(str)
        ScriptableObject.putProperty(api, "base64Decode", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val input = args.firstOrNull()?.toString() ?: return ""
                return runCatching {
                    val clean = input.trim()
                    val bytes = try {
                        Base64.getDecoder().decode(clean)
                    } catch (_: Exception) {
                        Base64.getUrlDecoder().decode(clean)
                    }
                    // Android 的 @JavascriptInterface 返回值在 Rhino 中是 Java String 包装对象；
                    // 书源会调用 `value.length()`。普通 JS string 的 length 是 number，不能这样调用。
                    NativeJavaObject(scope, String(bytes, Charsets.UTF_8), String::class.java)
                }.getOrDefault("")
            }
        })

        // java.base64Encode(str)
        ScriptableObject.putProperty(api, "base64Encode", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val input = args.firstOrNull()?.toString() ?: return ""
                return Base64.getEncoder().encodeToString(input.toByteArray(Charsets.UTF_8))
            }
        })

        // java.hexDecodeToString(hex) / java.hexEncodeToString(str)
        // 聚合类书源用 data:;hex,... 之类的载荷在搜索→详情→目录→正文之间传递参数
        ScriptableObject.putProperty(api, "hexDecodeToString", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val input = args.firstOrNull()?.toString() ?: return ""
                val clean = input.trim().removePrefix("0x")
                // 载荷可能是十六进制，也可能已经被上层解码成普通文本（如 JSON），
                // 非十六进制时原样返回，避免把正确的数据破坏成乱码。
                if (clean.isEmpty() || clean.length % 2 != 0 || !clean.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) {
                    return input
                }
                return runCatching {
                    String(ByteArray(clean.length / 2) { index ->
                        clean.substring(index * 2, index * 2 + 2).toInt(16).toByte()
                    }, Charsets.UTF_8)
                }.getOrDefault(input)
            }
        })
        ScriptableObject.putProperty(api, "hexEncodeToString", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val input = args.firstOrNull()?.toString() ?: return ""
                return input.toByteArray(Charsets.UTF_8).joinToString("") { "%02x".format(it) }
            }
        })

        // java.md5Encode(str) / java.md5(str)
        val md5Fn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val input = args.firstOrNull()?.toString() ?: return ""
                return MessageDigest.getInstance("MD5").digest(input.toByteArray(Charsets.UTF_8))
                    .joinToString("") { "%02x".format(it) }
            }
        }
        ScriptableObject.putProperty(api, "md5Encode", md5Fn)
        ScriptableObject.putProperty(api, "md5", md5Fn)

        // java.md5Encode16(str)
        ScriptableObject.putProperty(api, "md5Encode16", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val input = args.firstOrNull()?.toString() ?: return ""
                val full = MessageDigest.getInstance("MD5").digest(input.toByteArray(Charsets.UTF_8))
                    .joinToString("") { "%02x".format(it) }
                return if (full.length >= 24) full.substring(8, 24) else full
            }
        })

        // java.strToBytes(str[, charset]) / java.bytesToStr(bytes[, charset])
        // Android 这里的 byte[] 在 Rhino 里是「可下标、可 length、可整体回传」的数组；
        // 服务端沿用 CryptoPackageBridge 的 NativeArray(带符号整数) 约定，保证
        // `java.bytesToStr(java.base64DecodeToByteArray(x))` 这类链路可逆。
        ScriptableObject.putProperty(api, "strToBytes", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.firstOrNull()?.toString() ?: ""
                return jsByteArrayValue(scope, text.toByteArray(jsCharsetArgument(args.getOrNull(1))))
            }
        })
        ScriptableObject.putProperty(api, "bytesToStr", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val bytes = jsByteArrayArgument(args.firstOrNull())
                return String(bytes, jsCharsetArgument(args.getOrNull(1)))
            }
        })

        // java.base64DecodeToByteArray(str[, flags])
        // flags 与 android.util.Base64 一致：8 为 URL_SAFE，其余 flag 影响编码侧，
        // 解码按 Android 的宽松规则（忽略空白、容忍缺省补位）。空白输入返回 null。
        ScriptableObject.putProperty(api, "base64DecodeToByteArray", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val input = args.firstOrNull()?.toString()
                // Android 对空输入返回 null（JS null），不是空数组。
                if (input.isNullOrBlank()) return null
                val flags = (args.getOrNull(1) as? Number)?.toInt()
                    ?: args.getOrNull(1)?.toString()?.toIntOrNull()
                    ?: 0
                val normalized = if (flags and ANDROID_BASE64_URL_SAFE != 0) {
                    input.replace('-', '+').replace('_', '/')
                } else {
                    input
                }
                return jsByteArrayValue(scope, AndroidBase64Default.decode(normalized))
            }
        })

        // java.hexDecodeToByteArray(hex) —— 非法/奇数长度输入与 Android HexUtil 一致返回 null。
        ScriptableObject.putProperty(api, "hexDecodeToByteArray", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val clean = args.firstOrNull()?.toString()?.trim()?.removePrefix("0x") ?: return null
                if (clean.isEmpty() || clean.length % 2 != 0 ||
                    !clean.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }
                ) {
                    return null
                }
                return jsByteArrayValue(
                    scope,
                    ByteArray(clean.length / 2) { index ->
                        clean.substring(index * 2, index * 2 + 2).toInt(16).toByte()
                    },
                )
            }
        })

        // ---------- 文件族（Android JsExtensions 文件操作 + ArchiveUtils） ----------
        // 统一落在 runner.sourceFiles 的根目录（Android 对应 appCtx.externalCache）。
        ScriptableObject.putProperty(api, "getFile", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val store = runner?.sourceFiles ?: return null
                val path = args.firstOrNull()?.toString() ?: return null
                return runCatching { store.resolve(path) }.getOrNull()?.let { fileBridge(scope, store, path, it) }
            }
        })

        // java.readFile(path) -> byte[] | null
        ScriptableObject.putProperty(api, "readFile", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val store = runner?.sourceFiles ?: return null
                val path = args.firstOrNull()?.toString() ?: return null
                val bytes = runCatching { store.readBytes(path) }.getOrNull() ?: return null
                return jsByteArrayValue(scope, bytes)
            }
        })

        // java.readTxtFile(path[, charset]) —— 无 charset 时按 Android EncodingDetect 的策略探测
        ScriptableObject.putProperty(api, "readTxtFile", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val store = runner?.sourceFiles ?: return ""
                val path = args.firstOrNull()?.toString() ?: return ""
                val charsetName = args.getOrNull(1)?.toString()
                return runCatching { store.readText(path, charsetName) }.getOrDefault("")
            }
        })

        // java.deleteFile(path) -> boolean
        ScriptableObject.putProperty(api, "deleteFile", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val store = runner?.sourceFiles ?: return false
                val path = args.firstOrNull()?.toString() ?: return false
                return runCatching { store.delete(path) }.getOrDefault(false)
            }
        })

        // java.downloadFile(url) -> 相对路径（Android 用 AnalyzeUrl 抓取后写入 externalCache）
        ScriptableObject.putProperty(api, "downloadFile", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val store = runner?.sourceFiles ?: return ""
                val url = args.firstOrNull()?.toString() ?: return ""
                val fileName = SourceFileStore.md5Encode16(url) + "." + sourceUrlSuffix(url)
                val bytes = runner.fetchBytes(
                    url,
                    sourceId = execContext?.sourceId,
                    source = execContext?.sourceJson,
                    database = execContext?.database,
                )
                store.writeBytes(fileName, bytes)
                return "/$fileName"
            }
        })

        // java.cacheFile(url[, saveTime]) —— 文本缓存：命中读缓存，未命中先下载再读
        // （Android CacheManager 持久化 key -> 文件路径 + 过期时间，服务端同样落库）
        ScriptableObject.putProperty(api, "cacheFile", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val store = runner?.sourceFiles ?: return ""
                val url = args.firstOrNull()?.toString() ?: return ""
                val saveTime = (args.getOrNull(1) as? Number)?.toInt() ?: 0
                val database = execContext?.database ?: runner.database
                val key = SourceFileStore.md5Encode16(url)
                val cachedPath = database?.jsCacheGet(key)?.takeIf { it.isNotBlank() }
                if (cachedPath != null && store.exists(cachedPath)) {
                    return store.readText(cachedPath)
                }
                val fileName = SourceFileStore.md5Encode16(url) + "." + sourceUrlSuffix(url)
                val bytes = runner.fetchBytes(
                    url,
                    sourceId = execContext?.sourceId,
                    source = execContext?.sourceJson,
                    database = database,
                )
                store.writeBytes(fileName, bytes)
                database?.jsCachePut(key, "/$fileName", saveTime)
                return LocalBookParser.decodeText(bytes)
            }
        })

        // java.unzipFile / un7zFile / unrarFile / unArchiveFile —— 按包内容自动识别格式
        val unArchive = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val store = runner?.sourceFiles ?: return ""
                val path = args.firstOrNull()?.toString() ?: return ""
                return runCatching { store.extractArchive(path) }.getOrDefault("")
            }
        }
        ScriptableObject.putProperty(api, "unArchiveFile", unArchive)
        ScriptableObject.putProperty(api, "unzipFile", unArchive)
        ScriptableObject.putProperty(api, "un7zFile", unArchive)
        ScriptableObject.putProperty(api, "unrarFile", unArchive)

        // java.getTxtInFolder(path) —— 目录内所有文本文件按探测编码拼接，随后删除目录
        ScriptableObject.putProperty(api, "getTxtInFolder", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val store = runner?.sourceFiles ?: return ""
                val path = args.firstOrNull()?.toString() ?: return ""
                if (path.isEmpty()) return ""
                val files = runCatching { store.listFiles(path) }.getOrDefault(emptyList())
                val contents = files.filter { java.nio.file.Files.isRegularFile(it) }
                    .joinToString("\n") { file ->
                        runCatching {
                            LocalBookParser.decodeText(java.nio.file.Files.readAllBytes(file))
                        }.getOrDefault("")
                    }
                runCatching { store.delete(path) }
                return contents
            }
        })

        // java.getZip/Rar/7zStringContent(url, path[, charset]) 与 ByteArray 版本：
        // url 既可以是 http(s) 地址（带书源 header/Cookie 抓取），也可以是十六进制字符串。
        fun archiveBytes(url: String): ByteArray? = runCatching {
            if (url.startsWith("http://", true) || url.startsWith("https://", true)) {
                runner?.fetchBytes(
                    url,
                    sourceId = execContext?.sourceId,
                    source = execContext?.sourceJson,
                    database = execContext?.database,
                )
            } else {
                val clean = url.trim()
                if (clean.isEmpty() || clean.length % 2 != 0 || !clean.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) {
                    null
                } else {
                    ByteArray(clean.length / 2) { index -> clean.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
                }
            }
        }.getOrNull()

        fun registerArchiveReader(
            byteArrayName: String,
            stringName: String,
        ) {
            ScriptableObject.putProperty(api, byteArrayName, object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                    val store = runner?.sourceFiles ?: return null
                    val url = args.getOrNull(0)?.toString() ?: return null
                    val entryPath = args.getOrNull(1)?.toString() ?: return null
                    val bytes = archiveBytes(url) ?: return null
                    val entry = store.readEntryFromBytes(bytes, entryPath) ?: return null
                    return jsByteArrayValue(scope, entry)
                }
            })
            ScriptableObject.putProperty(api, stringName, object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                    val store = runner?.sourceFiles ?: return ""
                    val url = args.getOrNull(0)?.toString() ?: return ""
                    val entryPath = args.getOrNull(1)?.toString() ?: return ""
                    val bytes = archiveBytes(url) ?: return ""
                    val entry = store.readEntryFromBytes(bytes, entryPath) ?: return ""
                    val charsetName = args.getOrNull(2)?.toString()
                    return if (charsetName.isNullOrBlank()) {
                        LocalBookParser.decodeText(entry)
                    } else {
                        runCatching { String(entry, Charset.forName(charsetName)) }.getOrDefault("")
                    }
                }
            })
        }
        registerArchiveReader("getZipByteArrayContent", "getZipStringContent")
        registerArchiveReader("getRarByteArrayContent", "getRarStringContent")
        registerArchiveReader("get7zByteArrayContent", "get7zStringContent")

        // java.head(url[, headers][, timeout]) —— Android 走 Jsoup：HEAD、不跟随重定向、
        // ignoreContentType、无 body，返回 Connection.Response（状态码/响应头/最终地址）。
        ScriptableObject.putProperty(api, "head", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: return ""
                val headers = args.getOrNull(1)?.let { parseJsMapOrJson(it) } ?: emptyMap()
                val fullUrl = "$url,${buildUrlOptionsJson("HEAD", null, headers)}"
                return try {
                    runner?.fetchResponse(
                        fullUrl,
                        sourceId = execContext?.sourceId,
                        source = execContext?.sourceJson,
                        database = execContext?.database,
                        callTimeoutMillis = args.getOrNull(2)?.let { value ->
                            (value as? Number)?.toLong() ?: ScriptRuntime.toNumber(value).toLong()
                        } ?: 30_000L,
                        firstResponseOnly = true,
                        formEncodeBody = false,
                        hostnamePolicy = SourceHostnamePolicy.ANDROID_JSOUP,
                    )?.let { toJsResponse(it, scope) } ?: ""
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        })

        // java.htmlFormat(str) —— Android HtmlFormatter.formatKeepImg：
        // 段落标签折叠成换行、其余标签剥掉、保留 img（并把模板/懒加载 src 归一化）。
        ScriptableObject.putProperty(api, "htmlFormat", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return HtmlFormatter.formatKeepImg(args.firstOrNull()?.toString())
            }
        })

        // java.timeFormatUTC(time, format, sh) —— 逐字对齐 Android：
        // SimpleTimeZone(sh, "UTC") 的 sh 直接作为 rawOffset（毫秒），格式沿用系统 Locale。
        ScriptableObject.putProperty(api, "timeFormatUTC", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val millis = (args.getOrNull(0) as? Number)?.toLong()
                    ?: args.getOrNull(0)?.toString()?.toLongOrNull()
                    ?: return ""
                val format = args.getOrNull(1)?.toString() ?: return ""
                val rawOffset = (args.getOrNull(2) as? Number)?.toInt()
                    ?: args.getOrNull(2)?.toString()?.toIntOrNull()
                    ?: 0
                return SimpleDateFormat(format, Locale.getDefault()).apply {
                    timeZone = SimpleTimeZone(rawOffset, "UTC")
                }.format(Date(millis))
            }
        })

        // java.s2t(text) —— 与 java.t2s 共用同一张常用字表（反向映射）。
        ScriptableObject.putProperty(api, "s2t", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.firstOrNull()?.toString() ?: return ""
                return ChineseTextUtils.s2t(text)
            }
        })

        // java.toURL(url[, baseUrl]) —— Android JsURL：host/origin/pathname/searchParams
        ScriptableObject.putProperty(api, "toURL", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val url = args.firstOrNull()?.toString() ?: return null
                val baseUrl = args.getOrNull(1)?.toString()?.takeIf { it.isNotEmpty() }
                return jsUrl(scope, url, baseUrl)
            }
        })

        // java.getSource() / java.getTag() —— Android 返回当前书源对象与书源名。
        ScriptableObject.putProperty(api, "getSource", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val context = execContext ?: return null
                val id = context.sourceId?.takeIf { it.isNotBlank() } ?: return null
                return createSourceBridge(scope, id, context.database, context)
            }
        })
        ScriptableObject.putProperty(api, "getTag", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return execContext?.sourceName ?: ""
            }
        })

        // java.randomUUID()
        ScriptableObject.putProperty(api, "randomUUID", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return UUID.randomUUID().toString()
            }
        })

        // ------------------------------------------------------------------
        // 对称加解密族：Legado 书源用它们解密目录/正文地址
        //
        // 兼容性示例：书源 `api.jmlldsc.com` 的 chapterUrl 规则是
        //   $.path@js:java.aesBase64DecodeToString(result,"f041c49714d39908","AES/CBC/PKCS5Padding","0123456789abcdef")
        // 沙箱**没有**这个 API ⇒ JS 抛 ReferenceError ⇒ 每一章都被
        // `mapIndexedNotNull` 丢掉 ⇒ 目录 0 章、正文自然取不到。
        // 补上后同一密文可正确解出 `http://api.lemiyigou.com/697/697604/75510.json`。
        // ------------------------------------------------------------------

        /** Android JsEncodeUtils 语义：String key/iv 按 UTF-8 原始字节使用。 */
        fun cryptoKeyBytes(raw: String?, algorithm: String): ByteArray {
            val text = raw ?: ""
            return text.toByteArray(Charsets.UTF_8)
        }

        /**
         * Android 书源的加解密走 hutool + BouncyCastle，`PKCS7Padding` 是合法写法；
         * JDK 自带的 SunJCE 只认 `PKCS5Padding`（对块密码语义等价：都按块补齐）。
         * 不做映射时 `Cipher.getInstance` 抛 `NoSuchAlgorithmException`，而受检异常
         * 逃出 Rhino 会被包成 `ClassCastException`（见 [normalizeScriptThrowable] 注释），
         * 连书源自己的 `try/catch` 都接不住。
         */
        fun normalizedTransformation(raw: String?): String {
            val value = raw?.takeIf { it.isNotBlank() } ?: "AES/CBC/PKCS5Padding"
            return value.replace("PKCS7Padding", "PKCS5Padding", ignoreCase = true)
        }

        fun runCrypto(mode: Int, data: ByteArray, key: String?, transformation: String?, iv: String?): ByteArray {
            val t = normalizedTransformation(transformation)
            val algorithm = t.substringBefore('/')
            val spec = Cipher.getInstance(t)
            val keySpec = SecretKeySpec(cryptoKeyBytes(key, algorithm), algorithm)
            val ivBytes = iv?.takeIf { it.isNotBlank() }?.let { cryptoKeyBytes(it, algorithm) }
            if (ivBytes != null && ivBytes.isNotEmpty()) {
                spec.init(mode, keySpec, IvParameterSpec(ivBytes))
            } else {
                spec.init(mode, keySpec)
            }
            return spec.doFinal(data)
        }

        fun cryptoInputBytes(value: Any?): ByteArray {
            val unwrapped = (value as? NativeJavaObject)?.unwrap() ?: value
            if (unwrapped is ByteArray) return unwrapped
            val text = unwrapped?.toString() ?: return ByteArray(0)
            return if (text.length >= 2 && text.length % 2 == 0 && text.all { it in '0'..'9' || it in 'A'..'F' || it in 'a'..'f' }) {
                text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            } else {
                runCatching { Base64.getDecoder().decode(text) }
                    .getOrElse { Base64.getMimeDecoder().decode(text) }
            }
        }

        // java.aesBase64DecodeToString(base64Data, key, transformation, iv)
        ScriptableObject.putProperty(api, "aesBase64DecodeToString", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val data = args.getOrNull(0)?.toString() ?: return ""
                val key = args.getOrNull(1)?.toString()
                val transformation = args.getOrNull(2)?.toString()
                val iv = args.getOrNull(3)?.toString()
                return try {
                    val decoded = runCatching { Base64.getDecoder().decode(data) }
                        .getOrElse { Base64.getMimeDecoder().decode(data) }
                    String(runCrypto(Cipher.DECRYPT_MODE, decoded, key, transformation, iv), Charsets.UTF_8)
                } catch (error: Throwable) {
                    // Android 这里是 hutool CryptoException（运行时异常，JS 可 catch）；
                    // 服务端统一走 normalizeScriptThrowable，保证密码/填充错误同样可被书源容错。
                    throw normalizeScriptThrowable(error)
                }
            }
        })

        // java.aesBase64EncodeToString(plainText, key, transformation, iv)
        ScriptableObject.putProperty(api, "aesBase64EncodeToString", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.getOrNull(0)?.toString() ?: return ""
                val key = args.getOrNull(1)?.toString()
                val transformation = args.getOrNull(2)?.toString()
                val iv = args.getOrNull(3)?.toString()
                return try {
                    val encrypted = runCrypto(Cipher.ENCRYPT_MODE, text.toByteArray(Charsets.UTF_8), key, transformation, iv)
                    Base64.getEncoder().encodeToString(encrypted)
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        })

        // java.aesDecodeToString(base64Data, key, transformation, iv) —— 与上面同语义，Legado 两种命名都有
        val aesDecodeAlias = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val data = args.getOrNull(0)?.toString() ?: return ""
                val key = args.getOrNull(1)?.toString()
                val transformation = args.getOrNull(2)?.toString()
                val iv = args.getOrNull(3)?.toString()
                return try {
                    val decoded = runCatching { Base64.getDecoder().decode(data) }
                        .getOrElse { Base64.getMimeDecoder().decode(data) }
                    String(runCrypto(Cipher.DECRYPT_MODE, decoded, key, transformation, iv), Charsets.UTF_8)
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        }
        ScriptableObject.putProperty(api, "aesDecodeToString", aesDecodeAlias)
        ScriptableObject.putProperty(api, "aesBase64Decode", aesDecodeAlias)

        // java.createSymmetricCrypto(transformation, key, iv) -> { encrypt, decrypt }
        ScriptableObject.putProperty(api, "createSymmetricCrypto", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val transformation = args.getOrNull(0)?.toString()
                val key = args.getOrNull(1)?.toString()
                val iv = args.getOrNull(2)?.toString()
                val obj = NativeObject()
                obj.parentScope = scope
                fun crypto(block: () -> Any): Any = try {
                    block()
                } catch (error: Throwable) {
                    // 与 Android 一致：解密失败（填充错误/密钥长度不合法）必须能被书源 catch 到，
                    // 否则「解密失败就换 webView/其它密钥」这类容错路径整体失效。
                    throw normalizeScriptThrowable(error)
                }
                fun bytes(a2: Array<out Any?>): ByteArray =
                    crypto { runCrypto(Cipher.DECRYPT_MODE, cryptoInputBytes(a2.firstOrNull()), key, transformation, iv) } as ByteArray
                ScriptableObject.putProperty(obj, "encrypt", object : BaseFunction() {
                    override fun call(cx2: Context, s2: Scriptable, t2: Scriptable, a2: Array<out Any?>): Any {
                        val text = a2.firstOrNull()?.toString() ?: return ByteArray(0)
                        return crypto {
                            runCrypto(Cipher.ENCRYPT_MODE, text.toByteArray(Charsets.UTF_8), key, transformation, iv)
                        }
                    }
                })
                ScriptableObject.putProperty(obj, "encryptBase64", object : BaseFunction() {
                    override fun call(cx2: Context, s2: Scriptable, t2: Scriptable, a2: Array<out Any?>): Any {
                        val text = a2.firstOrNull()?.toString() ?: return ""
                        return crypto {
                            Base64.getEncoder().encodeToString(
                                runCrypto(Cipher.ENCRYPT_MODE, text.toByteArray(Charsets.UTF_8), key, transformation, iv)
                            )
                        }
                    }
                })
                ScriptableObject.putProperty(obj, "encryptHex", object : BaseFunction() {
                    override fun call(cx2: Context, s2: Scriptable, t2: Scriptable, a2: Array<out Any?>): Any {
                        val text = a2.firstOrNull()?.toString() ?: return ""
                        return crypto {
                            runCrypto(Cipher.ENCRYPT_MODE, text.toByteArray(Charsets.UTF_8), key, transformation, iv)
                                .joinToString("") { "%02x".format(it) }
                        }
                    }
                })
                ScriptableObject.putProperty(obj, "decrypt", object : BaseFunction() {
                    override fun call(cx2: Context, s2: Scriptable, t2: Scriptable, a2: Array<out Any?>): Any {
                        return bytes(a2)
                    }
                })
                ScriptableObject.putProperty(obj, "decryptStr", object : BaseFunction() {
                    override fun call(cx2: Context, s2: Scriptable, t2: Scriptable, a2: Array<out Any?>): Any {
                        return String(bytes(a2), Charsets.UTF_8)
                    }
                })
                return obj
            }
        })

        // java.deviceID() / java.androidId()
        val deviceIdFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                return "legado-headless-client-001"
            }
        }
        ScriptableObject.putProperty(api, "deviceID", deviceIdFn)
        ScriptableObject.putProperty(api, "androidId", deviceIdFn)

        // java.timeFormat(timestamp)
        ScriptableObject.putProperty(api, "timeFormat", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val arg = args.firstOrNull() ?: return ""
                val millis = when (arg) {
                    is Number -> arg.toLong()
                    is Date -> arg.time
                    else -> arg.toString().toLongOrNull() ?: System.currentTimeMillis()
                }
                return SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(millis))
            }
        })

        // java.getString(rule[, content][, isUrl]) 与 java.getString(rule, unescape) —— content 优先
        // 显式第二参数，其次 java.setContent 的一次性覆盖，再其次 src，最后 result（Android
        // `setContent` 直接替换 AnalyzeRule.content）；isUrl=true 时按 redirectUrl 补全绝对地址、
        // 空结果回退 baseUrl。内部 DOM 载体（parsed Element/元素集合）必须保真，不能经 NativeJSON 变成 {}。
        ScriptableObject.putProperty(api, "getString", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val rule = args.firstOrNull()?.toString() ?: return ""
                val second = args.getOrNull(1)?.takeIf { it !== Context.getUndefinedValue() }
                // Android 里 `getString(rule, unescape: Boolean)` 与 `getString(rule, mContent, isUrl)`
                // 是两个重载，Rhino 按参数类型分派：第二参是布尔时走 unescape 版本。
                val explicit = second?.takeUnless { it is Boolean }
                val unescape = (second as? Boolean) ?: true
                val isUrl = args.getOrNull(2)?.let { Context.toBoolean(it) } == true
                val content = explicit ?: contentOverride ?: bridgeBinding(scope, "src") ?: bridgeBinding(scope, "result")
                val (node, contentText) = bridgeContentNode(cx, scope, content)
                val baseUrl = ruleBaseUrl(scope, execContext)
                val value = try {
                    node.value(
                        rule,
                        this@JsSandbox,
                        contentText,
                        baseUrl,
                        // Android `getString(..., isUrl = true)` 对 DEFAULT 模式用 getString0（优先 URL/属性）。
                        urlExtractionMode = if (isUrl) {
                            NodeValue.UrlExtractionMode.FIRST_HTML
                        } else {
                            NodeValue.UrlExtractionMode.JOINED
                        },
                        unescape = unescape,
                    )
                } catch (error: Throwable) {
                    // Android 里这是 Java 方法抛出的异常，Rhino 包装后书源 try/catch 可捕获。
                    throw normalizeScriptThrowable(error)
                }
                if (!isUrl) return value ?: ""
                // Android `isUrl=true`：空结果回退 baseUrl，否则按 redirectUrl 补全为绝对地址。
                if (value.isNullOrBlank()) return baseUrl ?: ""
                return runner?.absoluteUrl(ruleRedirectUrl(scope, execContext), value) ?: value
            }
        })

        // java.getStringList(rule, content, isUrl) —— WebJs 页面脚本用它按规则批量取值。
        // isUrl = true 时按 redirectUrl 补全为绝对地址并去重（Android `AnalyzeRule.getStringList`）。
        ScriptableObject.putProperty(api, "getStringList", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val rule = args.firstOrNull()?.toString() ?: return emptyArray<Any?>()
                val explicit = args.getOrNull(1)?.takeIf { it !== Context.getUndefinedValue() }
                val content = explicit ?: contentOverride ?: bridgeBinding(scope, "src") ?: bridgeBinding(scope, "result")
                val (node, contentText) = bridgeContentNode(cx, scope, content)
                val listBaseUrl = ruleBaseUrl(scope, execContext)
                val values = try {
                    node.valueList(rule, this@JsSandbox, contentText, listBaseUrl).orEmpty()
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
                val isUrl = args.getOrNull(2)?.let { Context.toBoolean(it) } == true
                val resolved = if (isUrl) {
                    val base = ruleRedirectUrl(scope, execContext)
                    values.map { runner?.absoluteUrl(base, it) ?: it }.filter { it.isNotEmpty() }.distinct()
                } else {
                    values
                }
                // Rhino 的 `newArray(scope, Object[])` 要求数组组件类型**恰好是 Object**
                // （`Array<String>` 会抛 IllegalArgumentException），必须显式装箱。
                return Context.getCurrentContext().newArray(scope, Array<Any?>(resolved.size) { index -> resolved[index] })
            }
        })

        // java.put(key, val) / java.get(key)
        // 注意：`java.get` 已在上面统一定义（按参数形态分派 HTTP GET / session 读取），
        // 这里**严禁**再次 putProperty("get", ...) —— 那会静默覆盖 HTTP GET 能力。
        // Android `AnalyzeRule.put`：章节/书籍变量 → 规则数据 → `BaseSource.put`（CacheManager）。
        // `bookName`/`title` 只是"会被书籍/章节字段覆盖"的提示，值**照存**（Android 同）。
        ScriptableObject.putProperty(api, "put", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val key = args.getOrNull(0)?.toString() ?: return Context.getUndefinedValue()
                val value = args.getOrNull(1)
                val kvDb = execContext?.database ?: runner?.database
                // Android `AnalyzeRule.put(key, value: String)` 的参数是 Java String：Rhino 把 JS 的
                // undefined/null 转成 null ⇒ `putVariable(key, null)` 是**删除**该键。若不判，
                // `java.put('book_id', undefined)` 会把 "org.mozilla.javascript.Undefined@…"
                // 这种垃圾当参数存下来，聚合源再把它拼进目录/正文请求。
                if (value == null || value === Context.getUndefinedValue()) {
                    if (!execContext?.bookUrl.isNullOrBlank()) {
                        execContext.bookVariables.remove(key)
                    } else if (!sourceKvRemove(execContext?.sourceId, kvDb, key)) {
                        sessionStore.remove(key)
                    }
                    return null
                }
                // JS 的 ToString 语义：整数型数值串化成 `1` 而不是 Kotlin 的 `1.0`
                // （Android `ScriptRuntime.toString` 同）。
                val text = when (value) {
                    is Number -> {
                        val number = value.toDouble()
                        if (number.isFinite() && number % 1.0 == 0.0) {
                            String.format(java.util.Locale.ROOT, "%.0f", number)
                        } else {
                            value.toString()
                        }
                    }
                    else -> value.toString()
                }
                // 有书籍上下文（详情/目录/正文）时写书籍变量，随 `persistBookVariables` 落库；
                // 搜索/发现/登录这类"还没有具体书"的脚本走书源级持久 KV，跨请求可见。
                if (!execContext?.bookUrl.isNullOrBlank()) {
                    execContext.bookVariables[key] = text
                } else if (!sourceKvPut(execContext?.sourceId, kvDb, key, text)) {
                    sessionStore[key] = text
                }
                return value
            }
        })

        // java.toNumChapter(s) —— 把「第123章 / 123 / 一百二十三」之类标题归一成数字。
        // 4 个书源用到（ 扫描），缺失会让依赖它排序/对齐的规则抛 ReferenceError。
        ScriptableObject.putProperty(api, "toNumChapter", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.firstOrNull()?.toString()?.trim() ?: return 0
                Regex("\\d+").find(text)?.value?.toIntOrNull()?.let { return it }
                // 中文数字（仅支持常见的一~九百九十九，够覆盖章节标题）
                return chineseNumberToInt(text)
            }
        })

        // java.t2s(text) —— 繁体转简体（10 处使用）。服务端无完整词表，
        // 用一个可用的映射表覆盖常见字；未命中则原样返回，绝不抛错。
        ScriptableObject.putProperty(api, "t2s", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.firstOrNull()?.toString() ?: return ""
                return ChineseTextUtils.t2s(text)
            }
        })

        // java.encodeURI(text[, enc]) —— Android 直接使用 URLEncoder.encode，
        // 因此空格编码为 `+`（不是 `%20`）。改成 %20 会让依赖 `+` 的站点参数校验失败，
        // 且与 Android 参数签名（第二个参数是字符集名，不是 flags）不一致。
        ScriptableObject.putProperty(api, "encodeURI", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.firstOrNull()?.toString() ?: return ""
                val charsetName = args.getOrNull(1)?.toString()?.takeIf { it.isNotBlank() }
                return runCatching {
                    if (charsetName == null) {
                        java.net.URLEncoder.encode(text, Charsets.UTF_8)
                    } else {
                        java.net.URLEncoder.encode(text, charsetName)
                    }
                }.getOrDefault("")
            }
        })
        ScriptableObject.putProperty(api, "decodeURI", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val text = args.firstOrNull()?.toString() ?: return ""
                val charsetName = args.getOrNull(1)?.toString()?.takeIf { it.isNotBlank() }
                return runCatching {
                    if (charsetName == null) {
                        java.net.URLDecoder.decode(text, Charsets.UTF_8)
                    } else {
                        java.net.URLDecoder.decode(text, charsetName)
                    }
                }.getOrDefault(text)
            }
        })

        // java.connect(url) —— Android 返回真实 StrResponse。
        // 失败语义与 JsExtensions.connect 一致：StrResponse(url, 错误说明)，由源脚本
        // 依据正文判断；这里不伪造网络成功，也不吞成普通字符串。
        ScriptableObject.putProperty(api, "connect", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val url = args.firstOrNull()?.toString() ?: ""
                val headers = args.getOrNull(1)?.let { parseJsMapOrJson(it) } ?: emptyMap()
                val callTimeoutMillis = args.getOrNull(2)?.let { value ->
                    (value as? Number)?.toLong() ?: ScriptRuntime.toNumber(value).toLong()
                }
                return try {
                    val body = runner?.fetchResponse(
                        "$url,${buildUrlOptionsJson("GET", null, headers)}",
                        sourceId = execContext?.sourceId,
                        source = execContext?.sourceJson,
                        database = execContext?.database,
                        callTimeoutMillis = callTimeoutMillis,
                    )?.body ?: ""
                    JsStrResponseBridge(JsStrResponse(url, body))
                } catch (error: Throwable) {
                    JsStrResponseBridge(JsStrResponse(url, "connect(${url}) error: ${error.message ?: error.javaClass.simpleName}", message = error.javaClass.simpleName))
                }
            }
        })

        ScriptableObject.putProperty(api, "ajaxAll", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val urls = args.firstOrNull()?.let { parseJsList(it) } ?: emptyList()
                // Rhino 1.8.0 只接受 Object[]：Array<Any?> 才能安全交给 cx.newArray。
                return cx.newArray(scope, Array<Any?>(urls.size) { index ->
                    val url = urls[index].toString()
                    // 复用既有安全 facade：StrResponse 以 JsStrResponseBridge 暴露，不把 host 对象交给 JS。
                    toJsValue(JsStrResponse(url, runner?.fetch(url, execContext?.sourceId, execContext?.database) ?: ""), scope)
                })
            }
        })
        ScriptableObject.putProperty(api, "ajaxTestAll", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val urls = args.firstOrNull()?.let { parseJsList(it) } ?: emptyList()
                val callTimeoutMillis = args.getOrNull(1)?.let { value ->
                    (value as? Number)?.toLong() ?: ScriptRuntime.toNumber(value).toLong()
                }
                return cx.newArray(scope, Array<Any?>(urls.size) { index ->
                    val url = urls[index].toString()
                    toJsValue(
                        JsStrResponse(
                            url,
                            runner?.fetch(url, execContext?.sourceId, execContext?.database, callTimeoutMillis) ?: "",
                        ),
                        scope,
                    )
                })
            }
        })
        val cacheApi = NativeObject().also { cache ->
            cache.parentScope = scope
            // Android CacheManager：saveTime 单位为秒，0 = 不过期。
            // put 同时写内存 + DB；get 先内存再 DB，过期不返回旧值。
            // putMemory/getFromMemory 纯内存，保留 JS 原始值。
            val putFn = object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                    val key = args.getOrNull(0)?.toString() ?: return Context.getUndefinedValue()
                    val value = args.getOrNull(1) ?: Context.getUndefinedValue()
                    cacheMemory[key] = value
                    val saveTime = args.getOrNull(2)?.let { ScriptRuntime.toNumber(it).toInt() } ?: 0
                    execContext?.database?.jsCachePut(key, value.toString(), saveTime)
                    return value
                }
            }
            ScriptableObject.putProperty(cache, "put", putFn)
            ScriptableObject.putProperty(cache, "putMemory", object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                    val key = args.getOrNull(0)?.toString() ?: return Context.getUndefinedValue()
                    val value = args.getOrNull(1) ?: Context.getUndefinedValue()
                    cacheMemory[key] = value
                    return value
                }
            })
            ScriptableObject.putProperty(cache, "get", object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                    val key = args.firstOrNull()?.toString() ?: return null
                    val fromMemory = cacheMemory[key]
                    if (fromMemory is String) return fromMemory
                    val persisted = execContext?.database?.jsCacheGet(key)
                    if (persisted != null) {
                        cacheMemory[key] = persisted
                        return persisted
                    }
                    // Android `CacheManager.get(key): String?` 取不到返回 null（不是空串）：
                    // 源脚本惯用 `cache.get(k) === null` / `String(cache.get(k))` 判定，两边必须一致。
                    return null
                }
            })
            ScriptableObject.putProperty(cache, "getFromMemory", object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                    val key = args.firstOrNull()?.toString() ?: return null
                    // Android `CacheManager.getFromMemory(key): Any?` 同样返回 null，
                    // 脚本里的 `getFromMemory(k) < 1`（null 视作 0）依赖这个语义。
                    return cacheMemory[key]
                }
            })
        }
        ScriptableObject.putProperty(api, "cache", cacheApi)
        // Android evalJS 顶层绑定 cache = CacheManager，源脚本直接用 cache.put/get。
        ScriptableObject.putProperty(scope, "cache", cacheApi)

        // java.getElements(rule) / java.getElement(rule) —— Android AnalyzeRule 边界：
        // HTML/XPath/Regex 返回元素集合，JSON 返回单个对象，JS 规则返回求值单值；
        // result/src 的 StrResponse 身份（含 body）与 baseUrl 必须保留，不得压成字符串。
        fun selectionNode(cx: Context): Pair<NodeValue, String> {
            // 与 java.getString 共用同一内容转换：DOM 载体/StrResponse/JSON 对象/Map 身份都保留，
            // 缺失 src 走 Rhino NOT_FOUND 判定后回退 result；java.setContent 的一次性覆盖优先级最高。
            val content = contentOverride ?: bridgeBinding(scope, "src") ?: bridgeBinding(scope, "result")
            return bridgeContentNode(cx, scope, content)
        }
        ScriptableObject.putProperty(api, "getElements", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val rule = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                val (node, body) = selectionNode(cx)
                // JS 链沿用既有求值路径；求值失败按 Android 语义抛可被 JS 捕获的错误，
                // 不能静默返回空集合（书源靠 catch 决定回退策略）。
                val selection = try {
                    node.selectRawNodes(
                        rule,
                        jsSandbox = this@JsSandbox,
                        rawBody = body,
                        baseUrl = ruleBaseUrl(scope, execContext),
                    )
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
                return rawSelectionToJs(cx, scope, selection.nodes)
            }
        })
        ScriptableObject.putProperty(api, "getElement", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val rule = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                if (rule.isEmpty()) return Context.getUndefinedValue()
                val (node, body) = selectionNode(cx)
                return try {
                    elementSelection(cx, scope, node, body, rule, ruleBaseUrl(scope, execContext))
                } catch (error: Throwable) {
                    throw normalizeScriptThrowable(error)
                }
            }
        })
        // java.setContent(...) 的链式入口与被覆盖后的 java.getString/getElement(...) 共用同一求值
        // 路径：内容字符串先经 NodeValue.document 重建（JSON 自动识别），规则模式分派与主桥一致。
        fun chainedRuleValue(chainedCx: Context, chainedScope: Scriptable, content: String, rule: String): Any {
            val node = NodeValue.document(content)
            return try {
                node.value(rule, this@JsSandbox, content, ruleBaseUrl(chainedScope, execContext)) ?: ""
            } catch (error: Throwable) {
                throw normalizeScriptThrowable(error)
            }
        }
        fun chainedRuleStringList(chainedCx: Context, chainedScope: Scriptable, content: String, rule: String): Any {
            val node = NodeValue.document(content)
            val values = try {
                node.valueList(rule, this@JsSandbox, content, ruleBaseUrl(chainedScope, execContext)).orEmpty()
            } catch (error: Throwable) {
                throw normalizeScriptThrowable(error)
            }
            return chainedCx.newArray(chainedScope, Array<Any?>(values.size) { index -> values[index] })
        }
        fun chainedRuleElement(chainedCx: Context, chainedScope: Scriptable, content: String, rule: String): Any? {
            val node = NodeValue.document(content)
            return try {
                elementSelection(chainedCx, chainedScope, node, content, rule, ruleBaseUrl(chainedScope, execContext))
            } catch (error: Throwable) {
                throw normalizeScriptThrowable(error)
            }
        }
        fun chainedRuleElements(chainedCx: Context, chainedScope: Scriptable, content: String, rule: String): Any {
            val node = NodeValue.document(content)
            val selection = try {
                node.selectRawNodes(rule, jsSandbox = this@JsSandbox, rawBody = content, baseUrl = ruleBaseUrl(chainedScope, execContext))
            } catch (error: Throwable) {
                throw normalizeScriptThrowable(error)
            }
            return rawSelectionToJs(chainedCx, chainedScope, selection.nodes)
        }

        ScriptableObject.putProperty(api, "setContent", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val arg = args.firstOrNull()?.takeIf { it !== Context.getUndefinedValue() }
                    ?: throw normalizeScriptThrowable(AssertionError("内容不可空（Content cannot be null）"))
                val content = if (arg is JsStrResponse) arg.body ?: "" else arg.toString()
                contentOverride = content
                // Android `setContent(content, baseUrl)` 顺带 setBaseUrl(baseUrl)。
                val baseArg = args.getOrNull(1)?.toString()?.takeIf { it.isNotEmpty() }
                if (baseArg != null) execContext?.let { it.baseUrlOverride = baseArg }
                // 返回链式可用的取值入口（Android `setContent` 返回 AnalyzeRule 自身：
                // `java.setContent(x).getString(rule)`），同时把内容写进上面的一次性覆盖，
                // 供后续 `java.getElement` 继续使用。
                return NativeObject().also { chained ->
                    chained.parentScope = scope
                    putBridgeFunction(chained, "getString") { chainedCx, chainedScope, chainedArgs ->
                        chainedRuleValue(chainedCx, chainedScope, content, chainedArgs.getOrNull(0)?.toString().orEmpty())
                    }
                    putBridgeFunction(chained, "getStringList") { chainedCx, chainedScope, chainedArgs ->
                        chainedRuleStringList(chainedCx, chainedScope, content, chainedArgs.getOrNull(0)?.toString().orEmpty())
                    }
                    putBridgeFunction(chained, "getElement") { chainedCx, chainedScope, chainedArgs ->
                        chainedRuleElement(chainedCx, chainedScope, content, chainedArgs.getOrNull(0)?.toString().orEmpty())
                    }
                    putBridgeFunction(chained, "getElements") { chainedCx, chainedScope, chainedArgs ->
                        chainedRuleElements(chainedCx, chainedScope, content, chainedArgs.getOrNull(0)?.toString().orEmpty())
                    }
                }
            }
        })

        // java.setBaseUrl(url) / java.setRedirectUrl(url) —— Android `AnalyzeRule` 的状态设置：
        // 只影响随后（同一字段/同一请求）的 `baseUrl` 绑定与相对链接解析，见 JsExecutionContext 注释。
        ScriptableObject.putProperty(api, "setBaseUrl", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val value = args.firstOrNull()?.toString()
                if (value != null) execContext?.let { it.baseUrlOverride = value }
                return Context.getUndefinedValue()
            }
        })
        ScriptableObject.putProperty(api, "setRedirectUrl", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val value = args.firstOrNull()?.toString()?.trim().orEmpty()
                // Android `AnalyzeRule.setRedirectUrl`：data: 地址不参与相对链接解析。
                if (execContext != null && value.isNotEmpty() && !value.startsWith("data:", ignoreCase = true)) {
                    execContext.redirectUrlOverride = value
                }
                return Context.getUndefinedValue()
            }
        })

        // java.setRuleName(name) —— Android 只在 name 非空时生效；仅用于日志标签。
        ScriptableObject.putProperty(api, "setRuleName", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val name = args.firstOrNull()?.toString()?.takeIf { it.isNotBlank() }
                if (name != null) execContext?.let { it.ruleName = name }
                return Context.getUndefinedValue()
            }
        })

        // java.evalJS(jsStr[, result]) —— Android `AnalyzeRule.evalJS`：在同一个作用域族里再求值
        // 一段原生 JS 并返回其值（书源用它做模板化计算）。
        ScriptableObject.putProperty(api, "evalJS", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val script = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                val resultArg = args.getOrNull(1)?.takeIf { it !== Context.getUndefinedValue() }
                val bindings = mapOf(
                    "result" to (resultArg ?: bridgeBinding(scope, "result") ?: ""),
                    "src" to (bridgeBinding(scope, "src") ?: ""),
                    "baseUrl" to (execContext?.effectiveBaseUrl ?: bridgeBinding(scope, "baseUrl") ?: ""),
                    // Android `AnalyzeRule.evalJS` 的 `bindings["fromBookInfo"]`：详情页直出目录时为 true。
                    "fromBookInfo" to (execContext?.fromBookInfo == true),
                )
                return evalBodyJsCompletion(script, bindings, execContext)
            }
        })

        // java.refreshTocUrl() / java.reGetBook() —— Android 里只有 ruleToc.preUpdateJs 能调用，
        // 其余位置抛「只能在 preUpdateJs 中调用」；详情页直出目录（isFromBookInfo）时只记日志。
        // 真正的重新解析由 RuleRunner.chapters 在 preUpdateJs 之后统一完成。
        val refreshTocFn = object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val context = execContext ?: return Context.getUndefinedValue()
                if (!context.inPreUpdateJs) {
                    throw normalizeScriptThrowable(IllegalStateException("只能在 preUpdateJs 中调用"))
                }
                if (context.fromBookInfo) {
                    // Android `AnalyzeRule.refreshTocUrl`：详情页直出目录时只记一行日志就跳过重解析。
                    System.err.println("已跳过重复加载详情页，请优化代码")
                    return Context.getUndefinedValue()
                }
                context.refreshTocRequested = true
                return Context.getUndefinedValue()
            }
        }
        ScriptableObject.putProperty(api, "refreshTocUrl", refreshTocFn)
        ScriptableObject.putProperty(api, "reGetBook", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val context = execContext ?: return Context.getUndefinedValue()
                if (!context.inPreUpdateJs) {
                    throw normalizeScriptThrowable(IllegalStateException("只能在 preUpdateJs 中调用"))
                }
                if (context.fromBookInfo) {
                    // Android `AnalyzeRule.reGetBook`：详情页直出目录时只记一行日志，随后照常精确搜索换书链。
                    System.err.println("重新获取book")
                }
                context.reGetBookRequested = true
                return Context.getUndefinedValue()
            }
        })
    }

    /** 中文数字转整数，覆盖「一」到「九百九十九」以及「十/十一/二十」等常见章节写法。 */
    private fun chineseNumberToInt(text: String): Int {
        val digits = mapOf(
            '零' to 0, '一' to 1, '二' to 2, '两' to 2, '三' to 3, '四' to 4,
            '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9,
        )
        var result = 0
        var section = 0
        var seen = false
        for (ch in text) {
            when {
                ch in digits -> { section = digits.getValue(ch); seen = true }
                ch == '十' -> {
                    result += (if (section == 0) 1 else section) * 10
                    section = 0
                    seen = true
                }
                ch == '百' -> {
                    result += (if (section == 0) 1 else section) * 100
                    section = 0
                    seen = true
                }
                else -> if (seen) break
            }
        }
        return result + section
    }

    /**
     * 构造 Legado 的 URL 选项 JSON（拼接在 URL 之后的 `,{...}` 部分）。
     *
     * 必须显式构造 `JsonObject`，**严禁**写成
     * `Json.encodeToString(mapOf("method" to ..., "body" to ..., "headers" to ...))`：
     * 该 map 的静态类型是 `Map<String, Any>`，kotlinx 无法为多态 value 解析序列化器，
     * 会抛 `SerializationException: Serializer for class 'Any' is not found`。
     * 由于该语句位于归一化 try/catch 之外，异常会让桥接**静默返回 null**，
     * 书源的 `java.post/get` 全部拿不到响应却毫无提示。
     */
    private fun buildUrlOptionsJson(method: String, body: String?, headers: Map<String, String>): String =
        buildJsonObject {
            put("method", method)
            if (body != null) put("body", body)
            put(
                "headers",
                buildJsonObject {
                    headers.forEach { (key, value) -> put(key, value) }
                },
            )
        }.toString()

    /** JS 传来的 charset 参数（第二参）：空/非法一律回退 UTF-8，与 Android 的默认一致。 */
    private fun jsCharsetArgument(value: Any?): Charset =
        value?.toString()?.takeIf { it.isNotBlank() }?.let { Charset.forName(it) } ?: Charsets.UTF_8

    /**
     * 从 URL 猜扩展名（`java.downloadFile`/`cacheFile` 的落盘文件名用）。
     *
     * 取最后一个 `/` 之后的路径段、去掉 `?`/`#`/查询串，再取 `.` 之后的部分；
     * 超过 5 个字符或不是纯字母数字（含 `%`、`=` 等）时一律退化 `ext` —— 文件名会被
     * 拼进路径，绝不能让 URL 里的怪字符跑进磁盘名。
     */
    private fun sourceUrlSuffix(url: String): String {
        val suffix = url.substringAfterLast('/').substringBefore('?').substringBefore('#').substringAfterLast('.')
        return if (suffix.length > 5 || !Regex("^[a-z\\d]+$", RegexOption.IGNORE_CASE).matches(suffix)) "ext" else suffix
    }

    /** 常量函数：`java.xxx()` 里不依赖参数的那些（返回 `File` 属性、随机 UUID 等）。 */
    private fun constantFunction(value: () -> Any?): BaseFunction = object : BaseFunction() {
        override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? = value()
    }

    /**
     * Android `java.getFile(path)` 返回的 `File` 桥接对象。
     *
     * 属性与方法并存（`f.name` / `f.getName()`），全部**失败静默降级**：
     * 文件不存在、权限不足、路径越界时给空值/0/false，绝不让文件操作把书源规则打断。
     */
    private fun fileBridge(scope: Scriptable, store: SourceFileStore, path: String, file: Path): NativeObject {
        val bridge = NativeObject()
        bridge.parentScope = scope
        ScriptableObject.putProperty(bridge, "name", file.fileName?.toString() ?: "")
        ScriptableObject.putProperty(bridge, "path", file.toString())
        ScriptableObject.putProperty(bridge, "getName", constantFunction { file.fileName?.toString() ?: "" })
        ScriptableObject.putProperty(bridge, "getPath", constantFunction { file.toString() })
        ScriptableObject.putProperty(bridge, "getAbsolutePath", constantFunction { file.toString() })
        ScriptableObject.putProperty(bridge, "exists", constantFunction { Files.exists(file) })
        ScriptableObject.putProperty(bridge, "isDirectory", constantFunction { Files.isDirectory(file) })
        ScriptableObject.putProperty(bridge, "isFile", constantFunction { Files.isRegularFile(file) })
        ScriptableObject.putProperty(bridge, "length", constantFunction { runCatching { Files.size(file) }.getOrDefault(0L) })
        ScriptableObject.putProperty(bridge, "delete", constantFunction { runCatching { store.delete(path) }.getOrDefault(false) })
        ScriptableObject.putProperty(
            bridge,
            "readBytes",
            constantFunction {
                runCatching { jsByteArrayValue(scope, store.readBytes(path) ?: ByteArray(0)) }.getOrNull()
            },
        )
        ScriptableObject.putProperty(bridge, "readText", constantFunction { runCatching { store.readText(path) }.getOrDefault("") })
        ScriptableObject.putProperty(bridge, "listFiles", object : BaseFunction() {
            override fun call(cx: Context, callScope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val files = runCatching { store.listFiles(path) }.getOrDefault(emptyList())
                val array = cx.newArray(callScope, files.size)
                files.forEachIndexed { index, child ->
                    val childPath = runCatching { store.relativePath(child) }.getOrDefault(child.toString())
                    ScriptableObject.putProperty(array, index, fileBridge(callScope, store, childPath, child))
                }
                return array
            }
        })
        return bridge
    }

    /** JS 值 → 字节数组（`java.strToBytes`/压缩包族/`queryTTF` 共用）。 */
    internal fun jsByteArrayArgument(value: Any?): ByteArray = when (val unwrapped = unwrapJsBridge(value)) {
        is ByteArray -> unwrapped
        // NativeArray.length 是 long（Rhino 的 length 属性按 Number 建模）。
        is NativeArray -> ByteArray(unwrapped.length.toInt()) { index ->
            (unwrapped.get(index, unwrapped) as? Number)?.toByte() ?: 0
        }
        is Array<*> -> ByteArray(unwrapped.size) { index -> (unwrapped[index] as? Number)?.toByte() ?: 0 }
        is Number -> byteArrayOf(unwrapped.toByte())
        else -> ByteArray(0)
    }

    /**
     * Android `JsExtensions.queryTTF(data, useCache)` 的服务端等价物。
     *
     * `data` 三种形态（与 Android 的自动判定一致）：
     * 1. http(s) 地址 ⇒ 按书源身份抓取字体字节（带书源 header/Cookie）；
     * 2. 其它字符串 ⇒ 按 base64 解码（`android.util.Base64` 的宽松规则）；
     * 3. 字节数组 ⇒ 直接使用。
     *
     * 解析失败（网络失败 / 不是合法 TTF / 形态不认识）返回 JS null —— Android 侧同样会
     * 抛出并被书源自己的 `try{}catch` 处理，服务端把「拿不到字体」表达为 null 更安全。
     */
    private fun queryTtf(data: Any?, useCache: Boolean, execContext: JsExecutionContext?): QueryTTF? {
        val value = unwrapJsBridge(data) ?: return null
        val (key, bytes) = when {
            value is String -> {
                if (value.startsWith("http://", true) || value.startsWith("https://", true)) {
                    val fetched = runCatching {
                        runner?.fetchBytes(
                            value,
                            sourceId = execContext?.sourceId,
                            source = execContext?.sourceJson,
                            database = execContext?.database,
                            hostnamePolicy = SourceHostnamePolicy.ANDROID_JSOUP,
                        )
                    }.getOrNull() ?: return null
                    (if (useCache) QueryTtf.sha256(fetched) else null) to fetched
                } else {
                    val decoded = runCatching { AndroidBase64Default.decode(value.trim()) }.getOrNull() ?: return null
                    (if (useCache) QueryTtf.sha256(decoded) else null) to decoded
                }
            }
            value is ByteArray || value is NativeArray || value is Array<*> -> {
                val bytes = jsByteArrayArgument(value)
                if (bytes.isEmpty()) return null
                (if (useCache) QueryTtf.sha256(bytes) else null) to bytes
            }
            else -> return null
        }
        return runCatching { QueryTtf.parse(key, bytes) }.getOrNull()
    }

    /** ByteArray → JS 数组；与 CryptoPackageBridge 的 Android Base64 返回值保持同一约定。 */
    private fun jsByteArrayValue(scope: Scriptable, bytes: ByteArray): NativeArray {
        val values = Array<Any?>(bytes.size) { index -> bytes[index].toInt() }
        return NativeArray(values).also { array ->
            array.parentScope = scope
            // Android 的 byte[] 由 Rhino 包成 NativeJavaArray，自带 Array.prototype
            // （`String(bytes)`/`bytes.map(...)` 都依赖它）；稠密 NativeArray 默认没有原型。
            array.setPrototype(ScriptableObject.getArrayPrototype(scope))
        }
    }

    /** Android `JsURL`：host/origin/pathname/searchParams（searchParams 支持 .get(k) 与属性访问）。 */
    private fun jsUrl(scope: Scriptable, url: String, baseUrl: String?): NativeObject {
        val parsed = if (baseUrl.isNullOrEmpty()) {
            java.net.URL(url)
        } else {
            java.net.URL(java.net.URL(baseUrl), url)
        }
        val result = NativeObject()
        result.parentScope = scope
        ScriptableObject.putProperty(result, "host", parsed.host ?: "")
        ScriptableObject.putProperty(
            result,
            "origin",
            if (parsed.port > 0) "${parsed.protocol}://${parsed.host}:${parsed.port}" else "${parsed.protocol}://${parsed.host}",
        )
        ScriptableObject.putProperty(result, "pathname", parsed.path ?: "")
        val searchParams = NativeObject()
        searchParams.parentScope = scope
        parsed.query?.split("&")?.forEach { pair ->
            val parts = pair.split("=", limit = 2)
            if (parts.size == 2) {
                val key = parts[0]
                val value = runCatching { java.net.URLDecoder.decode(parts[1], Charsets.UTF_8) }.getOrDefault(parts[1])
                if (!ScriptableObject.hasProperty(searchParams, key)) {
                    ScriptableObject.putProperty(searchParams, key, value)
                }
            }
        }
        ScriptableObject.putProperty(searchParams, "get", object : BaseFunction() {
            override fun call(cx: Context, scope2: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val key = args.firstOrNull()?.toString() ?: return Context.getUndefinedValue()
                return ScriptableObject.getProperty(searchParams, key)
                    .takeIf { it != Scriptable.NOT_FOUND } ?: Context.getUndefinedValue()
            }
        })
        ScriptableObject.putProperty(result, "searchParams", searchParams)
        return result
    }

    private fun parseJsMapOrJson(value: Any?): Map<String, String> {
        if (value == null) return emptyMap()
        if (value is NativeObject) {
            val result = mutableMapOf<String, String>()
            value.ids.forEach { id ->
                val k = id.toString()
                val v = ScriptableObject.getProperty(value, k)
                if (v != null && v !is BaseFunction && v != Context.getUndefinedValue()) {
                    result[k] = v.toString()
                }
            }
            return result
        }
        if (value is Map<*, *>) {
            return value.entries.filter { it.key != null && it.value != null }
                .associate { it.key.toString() to it.value.toString() }
        }
        val str = value.toString().trim()
        if (str.startsWith("{")) {
            return runCatching { Json.decodeFromString<Map<String, String>>(str) }.getOrDefault(emptyMap())
        }
        return emptyMap()
    }

    private fun parseJsList(value: Any?): List<Any?> = when (value) {
        null -> emptyList()
        is List<*> -> value
        is Array<*> -> value.toList()
        else -> runCatching { Json.decodeFromString<List<String>>(value.toString()) }.getOrDefault(emptyList())
    }

    private fun parseCookieString(cookieStr: String): Map<String, String> {
        val result = linkedMapOf<String, String>()
        cookieStr.split(';').forEach { part ->
            val trimmed = part.trim()
            val eq = trimmed.indexOf('=')
            if (eq > 0) {
                val key = trimmed.substring(0, eq).trim()
                val value = trimmed.substring(eq + 1).trim()
                result[key] = value
            }
        }
        return result
    }

    /**
     * `src`/`result` 绑定读取：Rhino 的 `NOT_FOUND` 与 `undefined`/`null` 一样视为"未绑定"，
     * 否则缺失的 `src` 会被当作真实内容（D031 观测到的身份破坏同类问题）。
     */
    private fun bridgeBinding(scope: Scriptable, name: String): Any? =
        ScriptableObject.getProperty(scope, name)
            .takeIf { it !== Context.getUndefinedValue() && it !== Scriptable.NOT_FOUND && it != null }

    /**
     * 规则求值用的基准地址：`java.setBaseUrl(...)` 的覆盖值优先，其次本次求值的 `baseUrl`
     * 绑定（Android 里 `java` 就是 AnalyzeRule 本身，其 `baseUrl` 由调用方按响应地址设置）。
     * 少了这一层回退，嵌套 `<js>` 规则与 `isUrl=true` 的相对地址都会拿到空基准。
     */
    private fun ruleBaseUrl(scope: Scriptable, execContext: JsExecutionContext?): String? =
        execContext?.effectiveBaseUrl ?: bridgeBinding(scope, "baseUrl")?.toString()

    /** 相对链接解析基准：`setRedirectUrl` → `setBaseUrl` → 本次求值的 `baseUrl` 绑定 → 书源地址。 */
    private fun ruleRedirectUrl(scope: Scriptable, execContext: JsExecutionContext?): String? =
        execContext?.effectiveRedirectUrl ?: ruleBaseUrl(scope, execContext) ?: execContext?.sourceId

    /**
     * `java.getString` / `java.getElement(s)` 共用的内容 → [NodeValue] 转换，保留载体身份：
     * 内部安全 DOM 载体（单个元素/元素集合）→ HTML 节点，**绝不**经 NativeJSON 变成 `{}`；
     * StrResponse → body 且响应对象作为 source；其他 NativeObject/NativeArray/Map/List → JSON 语义；
     * 其余 → 字符串正文。返回 (node, rawBody)，rawBody 供 XPath/正则按文本取值。
     */
    private fun bridgeContentNode(cx: Context, scope: Scriptable, content: Any?): Pair<NodeValue, String> {
        JsoupBridge.unwrapElement(content)?.let { element ->
            return NodeValue.html(element) to element.outerHtml()
        }
        JsoupBridge.unwrapElements(content)?.let { elements ->
            val html = elements.joinToString("") { it.outerHtml() }
            return NodeValue.document(html) to html
        }
        return when (content) {
            null -> NodeValue.document("") to ""
            is JsStrResponse -> {
                val body = content.body ?: ""
                NodeValue.document(body, content) to body
            }
            is JsStrResponseBridge -> {
                val body = content.response.body ?: ""
                NodeValue.document(body, content.response) to body
            }
            is NativeObject, is org.mozilla.javascript.NativeArray, is Map<*, *>, is List<*> -> {
                val text = jsValueToString(cx, scope, content).orEmpty()
                NodeValue.document(content, content) to text
            }
            else -> {
                val text = content.toString()
                NodeValue.document(text) to text
            }
        }
    }

    /**
     * 原始选择结果 → JS：命中全为 HTML 节点时复用 [JsoupBridge] 的安全元素集合包装
     * （与 Android `AnalyzeRule.getElement(s)` 的 JSoup `Elements` 集合语义一致），
     * 其余（JSON/正则/JS 求值）逐个走既有 [toJsValue] 安全转换。
     */
    /**
     * `java.get` 最后一层回退：Android `BaseSource.get(key)` = CacheManager 的
     * `v_<bookSourceUrl>_<key>`；服务端对应 `source_login_state.source_kv`（每个书源一张表）。
     */
    /** 取某个书源级 KV 的内存镜像（首次访问时从库里整表载入一次）。 */
    private fun sourceKvMap(sourceId: String, db: Database?): MutableMap<String, String> =
        sourceKvCache.computeIfAbsent(sourceId) {
            db?.getSourceLoginState(sourceId)?.sourceKv?.toMutableMap() ?: mutableMapOf()
        }

    private fun sourceKvGet(sourceId: String?, db: Database?, key: String): String? {
        if (sourceId.isNullOrBlank()) return null
        return sourceKvMap(sourceId, db)[key]?.takeIf { it.isNotEmpty() }
    }

    /** 删库源级 KV（内存 + 落库）。没有书源 id 时返回 false，调用方退到 session store。 */
    private fun sourceKvRemove(sourceId: String?, db: Database?, key: String): Boolean {
        if (sourceId.isNullOrBlank()) return false
        sourceKvMap(sourceId, db).remove(key)
        db?.saveSourceKv(sourceId, key, null)
        return true
    }

    /** 写库源级 KV（内存先行 + 落库）。没有书源 id 时返回 false，调用方退到 session store。 */
    private fun sourceKvPut(sourceId: String?, db: Database?, key: String, value: String): Boolean {
        if (sourceId.isNullOrBlank()) return false
        sourceKvMap(sourceId, db)[key] = value
        db?.saveSourceKv(sourceId, key, value)
        return true
    }

    /**
     * 给任意 JS 载体挂一个 [BaseFunction]（`java.setContent(...)` 返回的链式对象等）：
     * 与 JsoupBridge 的同名工具同形态，回调里带着调用方的 (cx, scope)。
     */
    private fun putBridgeFunction(
        target: Scriptable,
        name: String,
        function: (Context, Scriptable, Array<out Any?>) -> Any?,
    ) {
        ScriptableObject.putProperty(target, name, object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? =
                function(cx, scope, args)
        })
    }

    /**
     * `java.getElement(rule)` 的共用求值：JSON/JS/正则等单值模式返回单值，HTML/XPath 返回元素集合
     * （Android `AnalyzeRule.getElement` 对非 JSON/非 JS 规则返回 `List`，JS 规则返回求值单值）。
     * 异常按 Android 语义归一成可被书源 `try/catch` 捕获的 JS 错误。
     */
    private fun elementSelection(
        cx: Context,
        scope: Scriptable,
        node: NodeValue,
        body: String,
        rule: String,
        baseUrl: String?,
    ): Any? {
        val selection = node.selectRawNodes(rule, forElement = true, jsSandbox = this, rawBody = body, baseUrl = baseUrl)
        return if (selection.singleValueMode) {
            toJsValue(selection.singleValue, scope)
        } else {
            rawSelectionToJs(cx, scope, selection.nodes)
        }
    }

    private fun rawSelectionToJs(cx: Context, scope: Scriptable, nodes: List<Any?>): Any =
        if (nodes.all { it is org.jsoup.nodes.Element }) {
            JsoupBridge.wrapElements(scope, nodes.filterIsInstance<org.jsoup.nodes.Element>())
        } else {
            cx.newArray(scope, Array<Any?>(nodes.size) { index -> toJsValue(nodes[index], scope) })
        }

    /** 书源定义里的标量（字符串/数字/布尔）→ JS 值；对象/数组不展开，避免把规则 JSON 塞进作用域。 */
    private fun jsonScalarValue(value: kotlinx.serialization.json.JsonElement): Any? = when (value) {
        is kotlinx.serialization.json.JsonPrimitive -> when {
            value.isString -> value.content
            value.content == "true" -> true
            value.content == "false" -> false
            value.content.toDoubleOrNull() != null -> value.content.toDouble()
            else -> value.content
        }
        else -> null
    }

    private fun toJsValue(value: Any?, scope: Scriptable): Any? = when (value) {
        null -> null
        is JsByteArray -> jsByteArrayValue(scope, value.bytes)
        is org.jsoup.nodes.Element -> JsoupBridge.wrapElement(scope, value)
        is JsStrResponse -> JsStrResponseBridge(value).also { it.parentScope = scope }
        is Map<*, *> -> NativeObject().also { obj ->
            // Use a real Object prototype. A bare NativeObject with only parentScope set
            // cannot be converted by String()/ToString in Rhino ("Cannot find default
            // value for object"), while Android passes JSON items as ordinary JS objects.
            ScriptRuntime.setObjectProtoAndParent(obj, scope)
            value.forEach { (k, v) -> if (k is String) ScriptableObject.putProperty(obj, k, toJsValue(v, scope)) }
            // Android 把 Java Map 直接交给 JS，源脚本惯用 map.get('k')；NativeObject
            // 没有同名方法，这里补齐等价 get() 以保持脚本兼容。
            ScriptableObject.putProperty(obj, "get", object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                    val key = args.firstOrNull()?.toString() ?: return null
                    return if (obj.has(key, obj)) obj.get(key, obj) else null
                }
            })
            ScriptableObject.putProperty(obj, "put", object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                    val key = args.getOrNull(0)?.toString() ?: return null
                    val value = args.getOrNull(1)
                    ScriptableObject.putProperty(obj, key, value)
                    return value
                }
            })
            ScriptableObject.putProperty(obj, "entries", object : BaseFunction() {
                override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                    val entries = obj.ids.filterIsInstance<String>().map { key ->
                        NativeObject().also { entry ->
                            entry.parentScope = scope
                            ScriptableObject.putProperty(entry, "key", key)
                            ScriptableObject.putProperty(entry, "value", ScriptableObject.getProperty(obj, key))
                        }
                    }
                    return Context.getCurrentContext().newArray(scope, Array<Any?>(entries.size) { index -> entries[index] })
                }
            })
        }
        is List<*> -> Context.getCurrentContext().newArray(scope, value.map { toJsValue(it, scope) }.toTypedArray())
        else -> Context.javaToJS(value, scope)
    }

    private fun toJsResponse(response: FetchedResponse, scope: Scriptable): JsStrResponseBridge {
        val raw = response.raw as? JsRawResponse
        val bridge = JsStrResponseBridge(
            JsStrResponse(
                response.url,
                response.body,
                response.status,
                message = raw?.message ?: if (response.status in 200..299) "OK" else "HTTP ${response.status}",
                headers = JsHeaders.of(response.headers),
                rawResponse = raw,
            ),
        ).also {
            it.parentScope = scope
            // A bare NativeObject subclass has no Object prototype; even String(response)
            // then throws "Cannot find default value for object". Android's response is
            // an ordinary script object for source expressions.
            ScriptRuntime.setObjectProtoAndParent(it, scope)
        }
        // Android StrResponse.headers() is a method, and okhttp Headers.headers(name)
        // returns all values. Existing scripts also read property methods such as
        // headers.get; this callable bridge preserves both access forms.
        ScriptableObject.putProperty(bridge, "headers", JsHeadersBridge(bridge.response.headers(), scope))
        return bridge
    }
}

private class JsHeadersBridge(
    private val headers: JsHeaders,
    ownerScope: Scriptable,
) : BaseFunction() {
    init {
        parentScope = ownerScope
        ScriptableObject.putProperty(this, "size", headers.size)
        ScriptableObject.putProperty(this, "get", valueFunction { headers.get(firstString(it)) })
        ScriptableObject.putProperty(this, "header", valueFunction { headers.get(firstString(it)) })
        // Do not expose Kotlin List/Map through NativeJavaObject. The class shutter
        // correctly rejects java.util classes, but Android source rules expect these
        // helpers to return ordinary JavaScript arrays/objects.
        ScriptableObject.putProperty(this, "values", arrayFunction { headers.values(firstString(it)) })
        ScriptableObject.putProperty(this, "names", arrayFunction { headers.names().toList() })
        ScriptableObject.putProperty(this, "toMultimap", object : BaseFunction() {
            override fun call(context: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val result = NativeObject()
                ScriptRuntime.setObjectProtoAndParent(result, scope)
                headers.names().forEach { name ->
                    val values = headers.values(name)
                    ScriptableObject.putProperty(
                        result,
                        name,
                        context.newArray(scope, Array<Any?>(values.size) { index -> Context.javaToJS(values[index], scope) }),
                    )
                }
                return result
            }
        })
    }

    override fun call(context: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
        val name = args.firstOrNull()?.toString() ?: return this
        val values = headers.values(name)
        val array = context.newArray(scope, values.size)
        values.forEachIndexed { index, value -> ScriptableObject.putProperty(array, index, value) }
        return array
    }

    private fun firstString(args: Array<out Any?>): String = args.firstOrNull()?.toString() ?: ""

    private fun arrayFunction(values: (Array<out Any?>) -> List<String>): BaseFunction = object : BaseFunction() {
        override fun call(context: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
            val result = context.newArray(scope, 0)
            values(args).forEachIndexed { index, value -> ScriptableObject.putProperty(result, index, value) }
            return result
        }
    }

    private fun valueFunction(function: (Array<out Any?>) -> Any?): BaseFunction = object : BaseFunction() {
        override fun call(
            context: Context,
            scope: Scriptable,
            thisObj: Scriptable,
            args: Array<out Any?>,
        ): Any? = Context.javaToJS(function(args), scope)
    }
}

private class LoginInfoMapBridge(
    private val loginValues: LinkedHashMap<String, String>,
    ownerScope: Scriptable,
    private val execContext: JsExecutionContext?,
) : NativeObject() {
    init {
        parentScope = ownerScope
        val values = loginValues
        ScriptableObject.defineProperty(this, "values", values, ScriptableObject.READONLY or ScriptableObject.PERMANENT)
        loginValues.forEach { (key, value) -> ScriptableObject.putProperty(this, key, value) }

        putFunction("get", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val key = args.firstOrNull()?.toString() ?: return null
                return Context.javaToJS(loginValues[key], scope)
            }
        })
        putFunction("put", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? {
                val key = args.getOrNull(0)?.toString()?.takeIf { it.isNotEmpty() } ?: return null
                val value = args.getOrNull(1)?.takeUnless { it === Context.getUndefinedValue() }?.toString() ?: ""
                loginValues[key] = value
                putValue(key, value)
                return Context.javaToJS(value, scope)
            }
        })
        putFunction("entries", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val entries = loginValues.map { (key, value) ->
                    NativeObject().also { entry ->
                        entry.parentScope = scope
                        ScriptableObject.putProperty(entry, "key", key)
                        ScriptableObject.putProperty(entry, "value", Context.javaToJS(value, entry))
                    }
                }
                return Context.getCurrentContext().newArray(scope, Array<Any?>(entries.size) { index -> entries[index] })
            }
        })
        putFunction("entrySet", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val entries = loginValues.map { (key, value) ->
                    NativeObject().also { entry ->
                        entry.parentScope = scope
                        ScriptableObject.putProperty(entry, "key", key)
                        ScriptableObject.putProperty(entry, "value", Context.javaToJS(value, entry))
                    }
                }
                return Context.getCurrentContext().newArray(scope, Array<Any?>(entries.size) { index -> entries[index] })
            }
        })
        putFunction("keySet", object : BaseFunction() {
            override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any {
                val keys = loginValues.keys.toList()
                return Context.getCurrentContext().newArray(scope, Array<Any?>(keys.size) { index -> keys[index] })
            }
        })
                putValue("size", loginValues.size)
    }

    override fun put(name: String, start: Scriptable, value: Any?) {
        val normalized = value?.takeUnless { it === Context.getUndefinedValue() }?.toString() ?: ""
        loginValues[name] = normalized
        execContext?.initialLoginInfo?.put(name, normalized)
        super.put(name, start, Context.javaToJS(normalized, this))
    }

    private fun putFunction(name: String, function: BaseFunction) {
        super.put(name, this, function)
    }

    private fun putValue(name: String, value: Any?) {
        super.put(name, this, value)
    }
}

