package io.legado.server

import kotlinx.serialization.Serializable

@Serializable data class SourceVerificationStartRequest(
    val url: String,
    val title: String = "书源验证",
    val webJs: String? = null,
    val headers: Map<String, String> = emptyMap(),
)

@Serializable data class SourceVerificationInteractionRequest(
    val action: String,
    val x: Double? = null,
    val y: Double? = null,
    val text: String? = null,
    val key: String? = null,
)

@Serializable data class SourceVerificationCompleteRequest(
    val input: String? = null,
)

/** CDP 实时流上的输入命令；动作字段与 REST 交互接口保持一致。 */
@Serializable data class SourceVerificationStreamCommand(
    val action: String,
    val x: Double? = null,
    val y: Double? = null,
    val text: String? = null,
    val key: String? = null,
)

/** 实时流文本消息。JPEG 帧作为二进制 WebSocket 消息紧随 ready/frame 元数据发送。 */
@Serializable data class SourceVerificationStreamMessage(
    val type: String,
    val state: String? = null,
    val url: String? = null,
    val title: String? = null,
    val error: String? = null,
    val width: Int? = null,
    val height: Int? = null,
)
