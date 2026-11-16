package io.legado.server

import com.github.liuyueyi.quick.transfer.ChineseUtils
import com.github.liuyueyi.quick.transfer.constants.TransType

/**
 * 简繁转换（Android `io.legado.app.utils.ChineseUtils` 的服务端等价实现）。
 *
 * **刻意使用与 Android 完全相同的第三方库**（`quick-transfer-core`）：
 * 简繁转换是**词表级**功能（`後臺` → `后台` vs 逐字转换出的 `后台`），
 * 自建字表必然与手机结果不一致 —— 而书源会把转换结果直接拼进请求或比对正文。
 *
 * `t2s` 在首次调用时装载 Android 的**例外词表**（`fixT2sDict`）：
 * 台湾用语（`雪梨`/`桌球`/`晶片`…）按阅读的定义保留原样，不转成大陆对应词。
 */
internal object ChineseTextUtils {
    private var fixed = false

    fun s2t(content: String): String = ChineseUtils.s2t(content)

    fun t2s(content: String): String {
        if (!fixed) fixT2sDict()
        return ChineseUtils.t2s(content)
    }

    @Synchronized
    private fun fixT2sDict() {
        fixed = true
        ChineseUtils.loadExcludeDict(TransType.TRADITIONAL_TO_SIMPLE, T2S_EXCLUDE_LIST)
    }

    /** Android `ChineseUtils.fixT2sDict()` 的例外词表，逐项一致。 */
    private val T2S_EXCLUDE_LIST = listOf(
        "槃",
        "划槳", "列根", "雪梨", "雪糕", "多士", "起司", "芝士", "沙芬", "母音",
        "华乐", "民乐", "晶元", "晶片", "映像", "明覆", "明瞭", "新力", "新喻",
        "零錢", "零钱", "離線", "碟片", "模組", "桌球", "案頭", "機車", "電漿",
        "鳳梨", "魔戒", "載入", "菲林", "整合", "變數", "解碼", "散钱", "插水",
        "房屋", "房价", "快取", "德士", "建立", "常式", "席丹", "布殊", "布希",
        "巴哈", "巨集", "夜学", "向量", "半形", "加彭", "列印", "函式", "全形",
        "光碟", "介面", "乳酪", "沈船", "永珍", "演化", "牛油", "相容", "磁碟",
        "菲林", "規則", "酵素", "雷根", "饭盒",
        "路易斯", "非同步", "出租车", "周杰倫", "马铃薯", "馬鈴薯", "機械人", "電單車",
        "電扶梯", "音效卡", "飆車族", "點陣圖", "個入球", "顆進球", "沃尓沃", "晶片集",
        "斯瓦巴", "斜角巷", "战列舰", "快速面", "希特拉", "太空梭", "吐瓦魯", "吉布堤",
        "吉布地", "史太林", "南冰洋", "区域网", "波札那", "解析度", "酷洛米", "金夏沙",
        "魔獸紀元", "高空彈跳", "铁达尼号", "太空战士", "埃及妖后", "吉里巴斯", "附加元件",
        "魔鬼終結者", "純文字檔案", "奇幻魔法Melody", "列支敦斯登",
    )
}
