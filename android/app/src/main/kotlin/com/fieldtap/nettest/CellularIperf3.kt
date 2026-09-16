package com.fieldtap.nettest

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.fieldtap.core.nettest.Iperf3Client
import com.fieldtap.core.nettest.Iperf3Connector
import com.fieldtap.core.nettest.Iperf3Failure
import com.fieldtap.core.nettest.Iperf3Interval
import com.fieldtap.core.nettest.Iperf3Options
import com.fieldtap.core.nettest.Iperf3Result
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import java.net.UnknownHostException
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * Sockets on the cellular network, for [Iperf3Client].
 *
 * `Network.socketFactory` and `Network.bindSocket` pin a socket to one network regardless of the default
 * route. In a lab the phone is usually on the building's Wi-Fi too, and an iperf3 test that quietly went
 * out over it would measure the office uplink and report it as the callbox's.
 *
 * The server's address is resolved through the cellular network's own DNS, so a callbox that hands out a
 * name for its iperf3 host is honoured; an IP literal needs no lookup at all.
 */
class NetworkIperf3Connector(private val network: Network) : Iperf3Connector {
    override fun openTcp(host: String, port: Int, timeoutMs: Int): Socket {
        val socket = network.socketFactory.createSocket()
        socket.connect(InetSocketAddress(resolve(host), port), timeoutMs)
        return socket
    }

    override fun openUdp(host: String, port: Int): DatagramSocket {
        val socket = DatagramSocket()
        network.bindSocket(socket)
        socket.connect(InetSocketAddress(resolve(host), port))
        return socket
    }

    private fun resolve(host: String) = try {
        network.getAllByName(host).let { all -> all.firstOrNull { it is Inet4Address } ?: all.first() }
    } catch (e: UnknownHostException) {
        throw Iperf3Failure.Protocol("could not resolve $host on the cellular network")
    }
}

/** Runs an iperf3 test on the cellular network, or reports that there is none. */
class CellularIperf3(private val networks: CellularNetworks) {
    /** Null when no cellular data network came up in time. */
    suspend fun run(options: Iperf3Options, onInterval: (Iperf3Interval) -> Unit): Iperf3Result? =
        networks.withCellular(NETWORK_TIMEOUT_MS) { network ->
            network?.let { Iperf3Client(NetworkIperf3Connector(it)).run(options, onInterval) }
        }

    private companion object {
        const val NETWORK_TIMEOUT_MS = 10_000L
    }
}

/** Whether the phone has a cellular data bearer, and what it is called on it. */
data class CellularLink(
    val up: Boolean,
    /** The phone's IPv4 address on the bearer — the address a callbox's routing and firewall see. */
    val ipv4: String? = null,
    val interfaceName: String? = null,
)

/**
 * Watches for a cellular data network without requesting one.
 *
 * `registerNetworkCallback` observes; `requestNetwork` would bring the bearer up just by opening the tab,
 * spending data and changing the thing being looked at. A phone attached to a callbox with no PDN shows
 * "no data bearer" here, which is the truth, and the fix belongs on the callbox.
 */
fun cellularLinks(context: Context): Flow<CellularLink> = callbackFlow {
    val manager = context.getSystemService(ConnectivityManager::class.java)
    if (manager == null) {
        trySend(CellularLink(up = false))
        close()
        return@callbackFlow
    }
    val links = mutableMapOf<Network, LinkProperties?>()
    fun publish() {
        val (network, properties) = links.entries.firstOrNull()?.toPair() ?: (null to null)
        trySend(
            CellularLink(
                up = network != null,
                ipv4 = properties?.linkAddresses?.map { it.address }?.firstOrNull { it is Inet4Address }?.hostAddress,
                interfaceName = properties?.interfaceName,
            ),
        )
    }
    val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            links[network] = manager.getLinkProperties(network)
            publish()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            links[network] = linkProperties
            publish()
        }

        override fun onLost(network: Network) {
            links.remove(network)
            publish()
        }
    }
    publish()
    manager.registerNetworkCallback(
        NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR).build(),
        callback,
    )
    awaitClose { runCatching { manager.unregisterNetworkCallback(callback) } }
}.distinctUntilChanged()
