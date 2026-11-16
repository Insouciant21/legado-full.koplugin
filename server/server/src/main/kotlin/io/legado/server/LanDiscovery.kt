package io.legado.server

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.DatagramPacket
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.UUID

private const val DISCOVERY_SETTING_KEY = "lan_discovery_server_id"
private const val DISCOVERY_PROBE = "LEGADO_DISCOVERY_V1"

@Serializable
data class LanDiscoveryAnnouncement(
    @SerialName("protocol_version") val protocolVersion: Int = 1,
    val type: String = "legado-server",
    @SerialName("server_id") val serverId: String,
    @SerialName("server_name") val serverName: String,
    val transport: String = "http",
    @SerialName("http_port") val httpPort: Int,
    @SerialName("discovery_port") val discoveryPort: Int,
    @SerialName("probe") val probe: String? = null,
    val capabilities: List<String> = listOf(
        "kindle-sync-v1",
        "kindle-inbox-v1",
        "kindle-progress-v1",
    ),
)

/**
 * Small LAN-only discovery responder.
 *
 * This intentionally uses a compact UDP request instead of mDNS: Kindle/KOReader
 * deployments do not consistently ship an mDNS resolver, while LuaSocket already
 * provides UDP. The response only advertises identity and the HTTP port; the
 * device derives the URL from the datagram source address, so DHCP address
 * changes do not require a persisted hostname.
 */
class LanDiscoveryService(
    private val database: Database,
    private val enabled: Boolean,
    private val port: Int,
    private val httpPort: Int,
    private val multicastGroup: String,
    private val serverName: String,
    private val log: (String) -> Unit = {},
) : AutoCloseable {
    private val json = Json { encodeDefaults = true; explicitNulls = false }
    val serverId: String = ensureServerId(database)
    val announcement = LanDiscoveryAnnouncement(
        serverId = serverId,
        serverName = serverName,
        httpPort = httpPort,
        discoveryPort = port,
    )

    @Volatile private var running = false
    private var socket: MulticastSocket? = null
    private var worker: Thread? = null

    fun start() {
        if (!enabled || running) return
        val candidate = try {
            MulticastSocket(port).apply {
                reuseAddress = true
                broadcast = true
                soTimeout = 1_000
            }
        } catch (error: Throwable) {
            log("LAN discovery disabled on port $port: ${error.message ?: error.javaClass.simpleName}")
            return
        }
        runCatching {
            val group = InetAddress.getByName(multicastGroup)
            if (group.isMulticastAddress) {
                candidate.joinGroup(InetSocketAddress(group, port), null)
            }
        }.onFailure {
            log("LAN discovery multicast join failed: ${it.message ?: it.javaClass.simpleName}")
        }
        socket = candidate
        running = true
        worker = Thread(this::runLoop, "legado-lan-discovery").apply {
            isDaemon = true
            start()
        }
        log("LAN discovery listening on UDP $port as $serverName ($serverId)")
    }

    override fun close() {
        if (!running && socket == null) return
        running = false
        runCatching { socket?.close() }
        socket = null
        runCatching { worker?.interrupt() }
        runCatching { worker?.join(2_000) }
        worker = null
    }

    private fun runLoop() {
        val activeSocket = socket ?: return
        while (running) {
            val bytes = ByteArray(512)
            val packet = DatagramPacket(bytes, bytes.size)
            try {
                activeSocket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (error: SocketException) {
                if (running) log("LAN discovery socket stopped: ${error.message ?: "socket error"}")
                break
            } catch (error: Throwable) {
                if (running) log("LAN discovery receive failed: ${error.message ?: error.javaClass.simpleName}")
                continue
            }

            val source = packet.address
            if (!isPrivatePeer(source)) continue
            val request = String(packet.data, packet.offset, packet.length, StandardCharsets.UTF_8).trim()
            if (!request.startsWith("$DISCOVERY_PROBE|")) continue
            val probe = request.substringAfter('|').take(128)
            if (probe.isBlank() || probe.any { it.code < 0x21 || it.code > 0x7e }) continue
            val response = json.encodeToString(announcement.copy(probe = probe))
                .toByteArray(StandardCharsets.UTF_8)
            runCatching {
                activeSocket.send(DatagramPacket(response, response.size, source, packet.port))
            }.onFailure {
                if (running) log("LAN discovery response failed: ${it.message ?: it.javaClass.simpleName}")
            }
        }
    }

    private fun isPrivatePeer(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress ||
            address.isSiteLocalAddress || address.isLinkLocalAddress
        ) return true
        return address is Inet6Address && (address.address.first().toInt() and 0xfe) == 0xfc
    }

    companion object {
        private fun ensureServerId(database: Database): String {
            val existing = database.getSetting(DISCOVERY_SETTING_KEY)
                ?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{16,64}")) }
            if (existing != null) return existing
            val generated = "srv_" + UUID.randomUUID().toString().replace("-", "")
            database.setSetting(DISCOVERY_SETTING_KEY, generated)
            return generated
        }
    }
}
