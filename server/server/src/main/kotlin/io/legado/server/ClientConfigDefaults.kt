package io.legado.server

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/**
 * 书源 JS 里 `getThemeConfig*` / `getReadBookConfig*` 的**服务端答案**。
 *
 * 这四个函数在 Android 上读的是**阅读界面配置**（主题色、字号、行距…）。服务端没有界面，
 * 但书源脚本确实会读它们（例如按 `getThemeMode()` 判断夜间模式）—— 因此不能缺失，
 * 否则整段脚本抛 ReferenceError。
 *
 * 语义选择：**报告 Android 的出厂默认值**（浅色「默认」主题 + 第一种阅读样式「微信读书」），
 * 与「全新安装的阅读」逐字段一致；资源文件直接取自 Android `assets/defaultData/`，
 * 因此两边不会各自漂移。
 */
internal object ClientConfigDefaults {
    private val json = Json { ignoreUnknownKeys = true }

    /** Android `AppConfig.themeMode ?: "0"`：0 = 跟随系统/日间。 */
    const val THEME_MODE = "0"

    private val themeConfigs: JsonArray by lazy { loadArray("themeConfig.json") }
    private val readConfigs: JsonArray by lazy { loadArray("readConfig.json") }

    /** 当前主题（列表第一项 = 「默认」）。 */
    fun themeConfigJson(): String = themeConfigs.first().toString()

    /** 当前阅读样式（列表第一项 = 「微信读书」）。 */
    fun readBookConfigJson(): String = readConfigs.first().toString()

    /**
     * Android `ThemeConfig.Config.toMap()` 的等价物：九个键，缺省的背景图相关字段补默认值
     * （资源文件里省略了它们，Android 的 data class 默认值同样是 `null`/`0`）。
     */
    fun themeConfigMap(): Map<String, Any?> {
        val config = themeConfigs.first().jsonObject
        return linkedMapOf(
            "themeName" to config.string("themeName"),
            "isNightTheme" to config.boolean("isNightTheme"),
            "primaryColor" to config.string("primaryColor"),
            "accentColor" to config.string("accentColor"),
            "backgroundColor" to config.string("backgroundColor"),
            "bottomBackground" to config.string("bottomBackground"),
            "transparentNavBar" to false,
            "backgroundImgPath" to null,
            "backgroundImgBlur" to 0,
        )
    }

    /** Android `ReadBookConfig.durConfig.toMap()`：资源里就是完整的样式对象。 */
    fun readBookConfigMap(): Map<String, Any?> =
        readConfigs.first().jsonObject.mapValues { (_, value) -> value.toPlainValue() }

    private fun loadArray(name: String): JsonArray {
        val text = ClientConfigDefaults::class.java.getResourceAsStream("/legado/defaultData/$name")
            ?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: error("缺少内置资源 /legado/defaultData/$name")
        val element = json.parseToJsonElement(text)
        return element as? JsonArray ?: error("内置资源 $name 不是 JSON 数组")
    }

    private fun JsonObject.string(key: String): String? = (get(key) as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.boolean(key: String): Boolean? = (get(key) as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull()

    private fun JsonElement.toPlainValue(): Any? = when (this) {
        is JsonPrimitive -> when {
            isString -> content
            content == "true" -> true
            content == "false" -> false
            else -> content.toDoubleOrNull()?.let { number -> if (number == number.toLong().toDouble()) number.toLong() else number }
                ?: content
        }
        is JsonArray -> map { it.toPlainValue() }
        is JsonObject -> mapValues { (_, value) -> value.toPlainValue() }
    }
}
