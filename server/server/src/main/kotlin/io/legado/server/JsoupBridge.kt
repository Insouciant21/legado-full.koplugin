package io.legado.server

import org.jsoup.Jsoup
import org.jsoup.nodes.Attribute
import org.jsoup.nodes.Element
import org.mozilla.javascript.BaseFunction
import org.mozilla.javascript.Context
import org.mozilla.javascript.Function
import org.mozilla.javascript.NativeArray
import org.mozilla.javascript.NativeObject
import org.mozilla.javascript.ScriptRuntime
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject

/**
 * Bounded Jsoup facade for book-source scripts.
 *
 * Android gives Rhino the real Jsoup classes. Here only native JavaScript wrappers
 * for parsed documents, elements and their attributes leave this file. No host
 * object is exposed, so scripts cannot reach reflection, class loaders, files or
 * network APIs through Jsoup.
 */
internal object JsoupBridge {
    internal fun unwrapElements(value: Any?): List<Element>? =
        (value as? ArrayLikeObject)?.elements

    /**
     * 内部安全 DOM 载体（单个元素）→ Jsoup [Element]；其他值返回 null。
     * 供 `java.getString` 等内容入口识别已解析节点，避免被 NativeJSON 字符串化成 `{}`。
     */
    internal fun unwrapElement(value: Any?): Element? = (value as? ElementWrapper)?.element

    fun install(scope: Scriptable) {
        val jsoupClass = NativeObject().also { it.parentScope = scope }
        putFunction(jsoupClass, "parse") { _, _, args ->
            wrapElement(
                scope,
                Jsoup.parse(htmlArgument(args.getOrNull(0)), baseUriArgument(args.getOrNull(1))),
            )
        }
        putFunction(jsoupClass, "parseBodyFragment") { _, _, args ->
            wrapElement(
                scope,
                Jsoup.parseBodyFragment(
                    htmlArgument(args.getOrNull(0)),
                    baseUriArgument(args.getOrNull(1)),
                ).body(),
            )
        }
        val jsoup = NativeObject().also { it.parentScope = scope }
        ScriptableObject.putProperty(jsoup, "Jsoup", jsoupClass)
        val org = NativeObject().also { it.parentScope = scope }
        ScriptableObject.putProperty(org, "jsoup", jsoup)
        ScriptableObject.putProperty(scope, "org", org)
    }

    fun wrapElement(scope: Scriptable, element: Element): NativeObject = ElementWrapper(scope, element).also { api ->
        putFunction(api, "select") { _, _, args ->
            wrapElements(scope, element.select(textArgument(args.getOrNull(0))))
        }
        putFunction(api, "selectFirst") { _, _, args ->
            element.selectFirst(textArgument(args.getOrNull(0)))
                ?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(api, "attr") { _, _, args ->
            val name = textArgument(args.getOrNull(0))
            if (args.size >= 2) {
                element.attr(name, textArgument(args[1]))
                api
            } else {
                element.attr(name)
            }
        }
        putFunction(api, "absUrl") { _, _, args ->
            element.absUrl(textArgument(args.getOrNull(0)))
        }
        putFunction(api, "hasAttr") { _, _, args ->
            element.hasAttr(textArgument(args.getOrNull(0)))
        }
        putFunction(api, "text") { _, _, _ -> element.text() }
        putFunction(api, "ownText") { _, _, _ -> element.ownText() }
        putFunction(api, "html") { _, _, _ -> element.html() }
        putFunction(api, "outerHtml") { _, _, _ -> element.outerHtml() }
        putFunction(api, "tagName") { _, _, _ -> element.tagName() }
        putFunction(api, "id") { _, _, _ -> element.id() }
        putFunction(api, "className") { _, _, _ -> element.className() }
        putFunction(api, "children") { _, _, _ -> wrapElements(scope, element.children()) }
        putFunction(api, "child") { _, _, args ->
            element.child(indexArgument(args.getOrNull(0)))
                ?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(api, "parent") { _, _, _ ->
            element.parent()?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(api, "nextElementSibling") { _, _, _ ->
            element.nextElementSibling()?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(api, "previousElementSibling") { _, _, _ ->
            element.previousElementSibling()?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(api, "siblingElements") { _, _, _ -> wrapElements(scope, element.siblingElements()) }
        putFunction(api, "nextElementSiblings") { _, _, _ -> wrapElements(scope, element.nextElementSiblings()) }
        putFunction(api, "previousElementSiblings") { _, _, _ -> wrapElements(scope, element.previousElementSiblings()) }
        putFunction(api, "getElementsByTag") { _, _, args ->
            wrapElements(scope, element.getElementsByTag(textArgument(args.getOrNull(0))))
        }
        putFunction(api, "getElementsByClass") { _, _, args ->
            wrapElements(scope, element.getElementsByClass(textArgument(args.getOrNull(0))))
        }
        putFunction(api, "attributes") { _, _, _ ->
            val items: Array<Any?> = element.attributes().map { attribute ->
                wrapAttribute(scope, attribute)
            }.toTypedArray()
            jsArray(scope, items)
        }
        putFunction(api, "toString") { _, _, _ -> element.outerHtml() }
    }

    /**
     * JS 数组替身 —— 对应 Android 侧 Java 数组被 Rhino 包成的 `NativeJavaArray`。
     *
     * Rhino 的 `NativeArray(Object[])` 是**稠密**数组：构造后**不带任何原型**，
     * `map/join/forEach/String(arr)` 全部缺失（`b.map` 直接 TypeError）。Android 里
     * `Elements.toArray()` 返回真 Java 数组，Rhino 包装后带 `Array.prototype`；书源
     * 普遍依赖 `b.map(x=>({n:x.text(),u:x.attr('href')}))` 这类写法（例：`🚬 po18城` 目录）。
     */
    private fun jsArray(scope: Scriptable, values: Array<Any?>): NativeArray =
        NativeArray(values).also { array ->
            array.parentScope = scope
            array.setPrototype(ScriptableObject.getArrayPrototype(scope))
        }

    /**
     * jsoup `Attribute` 的安全替身。
     *
     * 书源普遍用 `Array.from(element.attributes())` 后按 `toString().match(/"(.*)"/)` 取属性值
     * （例：`🌙 深夜看书/蓝海` 的目录规则），因此 `toString()` 必须与 jsoup 完全一致
     * （`key="value"`）。缺了这一条，属性会被字符串化成 `[object Object]`，
     * 规则静默取到空值而不是报错，目录直接变空。
     */
    private fun wrapAttribute(scope: Scriptable, attribute: Attribute): NativeObject =
        NativeObject().also { item ->
            item.parentScope = scope
            ScriptableObject.putProperty(item, "key", attribute.key)
            ScriptableObject.putProperty(item, "value", attribute.value)
            putFunction(item, "getKey") { _, _, _ -> attribute.key }
            putFunction(item, "getValue") { _, _, _ -> attribute.value }
            putFunction(item, "toString") { _, _, _ -> attributeText(attribute) }
        }

    /** jsoup `Attribute.toString()`：`key="value"`。 */
    private fun attributeText(attribute: Attribute): String = "${attribute.key}=\"${attribute.value}\""

    /** `java.getElement(s)` 复用它把 HTML 命中包成 Elements 形状的安全集合。 */
    internal fun wrapElements(scope: Scriptable, elements: Collection<Element>): ScriptableObject {
        val values = elements.toList()
        val array = arrayLike(scope, values)
        putFunction(array, "get") { _, _, args ->
            val index = indexArgument(args.getOrNull(0))
            values.getOrNull(index)?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(array, "first") { _, _, _ ->
            values.firstOrNull()?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(array, "last") { _, _, _ ->
            values.lastOrNull()?.let { wrapElement(scope, it) } ?: Context.getUndefinedValue()
        }
        putFunction(array, "size") { _, _, _ -> values.size }
        putFunction(array, "isEmpty") { _, _, _ -> values.isEmpty() }
        putFunction(array, "text") { _, _, _ -> values.joinToString(" ") { it.text() } }
        putFunction(array, "attr") { _, _, args ->
            values.firstOrNull()?.attr(textArgument(args.getOrNull(0))) ?: ""
        }
        putFunction(array, "html") { _, _, _ -> values.joinToString("\n") { it.outerHtml() } }
        putFunction(array, "outerHtml") { _, _, _ -> values.joinToString("\n") { it.outerHtml() } }
        putFunction(array, "toString") { _, _, _ -> values.joinToString("\n") { it.outerHtml() } }
        return array
    }

    /**
     * A native JS object shaped like a read-only array: numeric indices, `length`,
     * and own iterable helpers. A `NativeArray` cannot be used here because Rhino
     * returns the raw dense entry for numeric reads, which strips the methods of a
     * wrapped element subclass.
     */
    private fun arrayLike(scope: Scriptable, elements: List<Element>): ScriptableObject {
        val items = elements.map { wrapElement(scope, it) }
        return ArrayLikeObject(scope, elements).also { array ->
            items.forEachIndexed { index, item ->
                ScriptableObject.putProperty(array, index, item)
            }
            ScriptableObject.putProperty(array, "length", items.size)
            putFunction(array, "forEach") { _, _, args ->
                val callback = args.getOrNull(0)
                if (callback !is Function) return@putFunction Context.getUndefinedValue()
                val cx = Context.getCurrentContext()
                items.forEachIndexed { index, item ->
                    callback.call(cx, scope, array, arrayOf(item, index, array))
                }
                Context.getUndefinedValue()
            }
            putFunction(array, "map") { _, _, args ->
                val callback = args.getOrNull(0)
                if (callback !is Function) return@putFunction Context.getUndefinedValue()
                val cx = Context.getCurrentContext()
                jsArray(scope, items.mapIndexed { index, item ->
                    callback.call(cx, scope, array, arrayOf(item, index, array)) as Any
                }.toTypedArray())
            }
            putFunction(array, "toArray") { _, _, _ -> jsArray(scope, items.toTypedArray()) }
        }
    }

    /**
     * `Jsoup.parse(node)` accepts an already wrapped node and reparses its outer HTML,
     * matching Android's `Jsoup.parse(result.toString())` idiom.
     */
    private fun htmlArgument(value: Any?): String {
        if (value is ElementWrapper) return value.element.outerHtml()
        return textArgument(value)
    }

    private fun textArgument(value: Any?): String =
        if (value == null || value === Context.getUndefinedValue()) "" else ScriptRuntime.toString(value)

    private fun baseUriArgument(value: Any?): String =
        if (value == null || value === Context.getUndefinedValue()) "" else ScriptRuntime.toString(value)

    private fun indexArgument(value: Any?): Int {
        if (value == null || value === Context.getUndefinedValue()) return -1
        val number = ScriptRuntime.toNumber(value)
        if (!number.isFinite()) return -1
        return number.toInt()
    }

    private fun putFunction(
        target: Scriptable,
        name: String,
        function: (Context, Scriptable, Array<out Any?>) -> Any?,
    ) {
        ScriptableObject.putProperty(target, name, object : BaseFunction() {
            override fun call(cx: Context, s: Scriptable, thisObj: Scriptable, args: Array<out Any?>): Any? =
                function(cx, s, args)
        })
    }

    /** A parsed node exposed as a plain JS object; the host [Element] stays private. */
    private class ElementWrapper(
        scope: Scriptable,
        internal val element: Element,
    ) : NativeObject() {
        init {
            parentScope = scope
        }

        override fun toString(): String = element.outerHtml()

        override fun getDefaultValue(typeHint: Class<*>?): Any =
            if (typeHint == null || typeHint == ScriptRuntime.StringClass) element.outerHtml()
            else super.getDefaultValue(typeHint)
    }

    /** Minimal concrete [ScriptableObject] used for the safe element collection. */
    private class ArrayLikeObject(
        scope: Scriptable,
        internal val elements: List<Element>,
    ) : ScriptableObject() {
        init {
            prototype = ScriptableObject.getObjectPrototype(scope)
            parentScope = scope
        }

        override fun getClassName(): String = "Elements"
    }
}
