package io.legado.server

import kotlinx.serialization.Serializable

@Serializable data class SourceVerificationStartRequest(
    val url: String,
    val title: String = "书源验证",
    val webJs: String? = null,
    val headers: Map<String, String> = emptyMap(),
)

@Serializable data class SourceVerificationCompleteRequest(
    val input: String? = null,
)

/** 实时流文本消息。JPEG 画面由同一连接的二进制消息承载。 */
@Serializable data class SourceVerificationStreamMessage(
    val type: String,
    val state: String? = null,
    val url: String? = null,
    val title: String? = null,
    val error: String? = null,
    val width: Int? = null,
    val height: Int? = null,
)
