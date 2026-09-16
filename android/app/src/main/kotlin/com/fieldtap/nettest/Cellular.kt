package com.fieldtap.nettest

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import com.fieldtap.core.nettest.BodyCount
import com.fieldtap.core.nettest.BodyCounter
import com.fieldtap.core.nettest.DownloadOutcome
import com.fieldtap.core.nettest.UploadOutcome
import com.fieldtap.core.nettest.IcmpEcho
import com.fieldtap.core.nettest.NetFailure
import com.fieldtap.core.nettest.NetTestTransport
import com.fieldtap.core.nettest.PingOutcome
import com.fieldtap.core.nettest.interruptingOnCancel
import com.fieldtap.core.time.Clock
import java.io.FileDescriptor
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.MalformedURLException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The cellular network, requested explicitly: `ConnectivityManager.requestNetwork` with
 * `TRANSPORT_CELLULAR` and `NET_CAPABILITY_INTERNET`, held for exactly one test and released after it.
 * [withCellular] hands the block null after the timeout (or when Android refuses the request): the caller
 * writes a failed row saying "no cellular network". Never falls back to the default network, which may be
 * Wi-Fi.
 *
 * The request is a scoped block rather than an acquire and release pair, so a cancelled or failed test can
 * never leave cellular data held up.
 *
 * Owner: workstream `service-and-tests`.
 */
class CellularNetworks(private val context: Context) {
    suspend fun <T> withCellular(timeoutMs: Long, block: suspend (Network?) -> T): T {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return block(null)
        val available = CompletableDeferred<Network?>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                available.complete(network)
            }

            override fun onUnavailable() {
                available.complete(null)
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val timeout = timeoutMs.coerceIn(1, Int.MAX_VALUE.toLong())
        try {
            manager.requestNetwork(request, callback, timeout.toInt())
        } catch (e: RuntimeException) {
            Log.w(TAG, "Android refused the cellular network request", e)
            return block(null)
        }
        try {
            val network = withTimeoutOrNull(timeout + CALLBACK_GRACE_MS) { available.await() }
            return block(network)
        } finally {
            try {
                manager.unregisterNetworkCallback(callback)
            } catch (e: IllegalArgumentException) {
                // Already released: Android drops a request by itself after onUnavailable.
            }
        }
    }

    private companion object {
        const val TAG = "FieldTapNetTest"
        const val CALLBACK_GRACE_MS = 1_000L
    }
}

/**
 * [NetTestTransport] on cellular.
 *
 * - [ping]: `Os.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` (IPv4 target) bound with
 *   `Network.bindSocket(FileDescriptor)`, [IcmpEcho] packets, 1 s apart, each waiting up to `timeoutMs` for
 *   its own reply (late replies to earlier echoes are ignored); the target resolved with
 *   `Network.getAllByName`. An `EACCES` or `EPERM` from socket creation is `SOCKET_NOT_PERMITTED`. RTTs come
 *   from [nanoTime] (`SystemClock.elapsedRealtimeNanos`) for 0.1 ms resolution. `seconds` run from the moment
 *   the cellular network is available (the name lookup included) to the last reply or timeout, as in the
 *   golden session (4.13 s for 5 echoes); with no cellular network they are the time spent waiting for one.
 *   Never runs `/system/bin/ping` (a child process cannot be bound).
 * - [download]: `Network.openConnection(URL)` (HTTPS only), `Accept-Encoding: identity` so body bytes are wire
 *   bytes, counts body bytes until `capBytes` or `timeoutMs`, then disconnects. `seconds` run from the request
 *   on the acquired network to the last byte, on the clock's elapsed time. The User-Agent names the app only,
 *   never the phone model or Android build.
 * - Cancellation is prompt: the ping's blocking socket calls run on `Dispatchers.IO` in slices of at most 200 ms, and a
 *   download's connection is disconnected from another thread the moment its test is cancelled
 *   ([interruptingOnCancel]), which fails its response wait or body read at once.
 *
 * Owner: workstream `service-and-tests`.
 */
class CellularTestTransport(
    private val networks: CellularNetworks,
    private val clock: Clock,
    private val nanoTime: () -> Long = SystemClock::elapsedRealtimeNanos,
) : NetTestTransport {
    /**
     * [ping], reporting each echo as it completes: its sequence and its round trip, or null when it was
     * lost. The Traffic tab draws these as they arrive, since a ping that says nothing for ten seconds
     * and then prints a summary tells an engineer nothing while they are watching the link.
     */
    suspend fun pingLive(
        target: String,
        count: Int,
        timeoutMs: Long,
        onEcho: (sequence: Int, rttMs: Double?) -> Unit,
    ): PingOutcome = withContext(Dispatchers.IO) {
        val waitStartedMs = clock.elapsedRealtimeMillis()
        networks.withCellular(NETWORK_TIMEOUT_MS) { network ->
            if (network == null) {
                PingOutcome.Failed(NetFailure.NO_CELLULAR_NETWORK, null, secondsSince(waitStartedMs))
            } else {
                pingOn(network, target, count.coerceAtLeast(1), timeoutMs.coerceAtLeast(1), onEcho)
            }
        }
    }

    override suspend fun ping(target: String, count: Int, timeoutMs: Long): PingOutcome = withContext(Dispatchers.IO) {
        val waitStartedMs = clock.elapsedRealtimeMillis()
        networks.withCellular(NETWORK_TIMEOUT_MS) { network ->
            if (network == null) {
                PingOutcome.Failed(NetFailure.NO_CELLULAR_NETWORK, null, secondsSince(waitStartedMs))
            } else {
                pingOn(network, target, count.coerceAtLeast(1), timeoutMs.coerceAtLeast(1))
            }
        }
    }

    override suspend fun download(url: String, capBytes: Long, timeoutMs: Long): DownloadOutcome =
        withContext(Dispatchers.IO) {
            val parsed = try {
                URL(url)
            } catch (e: MalformedURLException) {
                null
            }
            if (parsed == null || !parsed.protocol.equals(HTTPS, ignoreCase = true) || parsed.host.isNullOrEmpty()) {
                return@withContext DownloadOutcome.Failed(NetFailure.INVALID_URL, null, 0.0, null, null)
            }
            val waitStartedMs = clock.elapsedRealtimeMillis()
            networks.withCellular(NETWORK_TIMEOUT_MS) { network ->
                if (network == null) {
                    DownloadOutcome.Failed(NetFailure.NO_CELLULAR_NETWORK, null, secondsSince(waitStartedMs), null, null)
                } else {
                    downloadOn(network, parsed, capBytes, timeoutMs.coerceAtLeast(1))
                }
            }
        }

    override suspend fun upload(url: String, capBytes: Long, timeoutMs: Long): UploadOutcome =
        withContext(Dispatchers.IO) {
            val parsed = try {
                URL(url)
            } catch (e: MalformedURLException) {
                null
            }
            if (parsed == null || !parsed.protocol.equals(HTTPS, ignoreCase = true) || parsed.host.isNullOrEmpty()) {
                return@withContext UploadOutcome.Failed(NetFailure.INVALID_URL, null, 0.0, null, null)
            }
            val waitStartedMs = clock.elapsedRealtimeMillis()
            networks.withCellular(NETWORK_TIMEOUT_MS) { network ->
                if (network == null) {
                    UploadOutcome.Failed(NetFailure.NO_CELLULAR_NETWORK, null, secondsSince(waitStartedMs), null, null)
                } else {
                    uploadOn(network, parsed, capBytes, timeoutMs.coerceAtLeast(1))
                }
            }
        }

    /**
     * POSTs [capBytes] of generated bytes over [network] and times it.
     *
     * The body is written in fixed-length streaming mode, so the bytes go out as they are produced
     * rather than being buffered whole: a 2 MB buffer on a phone with a slow uplink is both a memory
     * cost and a lie about when the transfer started. The clock stops when the server answers, not
     * when the last byte is handed to the socket, because bytes sitting in a send buffer have not
     * crossed the network yet and counting them would report an uplink faster than the radio's.
     */
    private suspend fun uploadOn(network: Network, url: URL, capBytes: Long, timeoutMs: Long): UploadOutcome {
        val startedMs = clock.elapsedRealtimeMillis()
        val bytesToSend = capBytes.coerceIn(1, MAX_UPLOAD_BYTES)
        val opened = try {
            network.openConnection(url)
        } catch (e: IOException) {
            return uploadFailureOf(e, secondsSince(startedMs), null, null)
        }
        val connection: HttpURLConnection = opened as? HttpURLConnection
            ?: return UploadOutcome.Failed(NetFailure.INVALID_URL, null, 0.0, null, null)

        val job = currentCoroutineContext()[Job]
        var httpCode: Int? = null
        var sent = 0L
        try {
            return interruptingOnCancel(interrupt = { connection.disconnect() }) {
                val socketTimeoutMs = minOf(timeoutMs, SOCKET_TIMEOUT_MS).toInt()
                connection.connectTimeout = socketTimeoutMs
                connection.readTimeout = socketTimeoutMs
                connection.useCaches = false
                connection.doOutput = true
                connection.requestMethod = "POST"
                connection.setFixedLengthStreamingMode(bytesToSend)
                connection.setRequestProperty("Content-Type", "application/octet-stream")
                connection.setRequestProperty("Cache-Control", "no-cache")
                connection.setRequestProperty("User-Agent", USER_AGENT)
                currentCoroutineContext().ensureActive()

                val deadlineMs = startedMs + timeoutMs
                val chunk = ByteArray(UPLOAD_CHUNK_BYTES)
                connection.outputStream.use { out ->
                    while (sent < bytesToSend) {
                        if (job?.isActive == false) {
                            currentCoroutineContext().ensureActive()
                        }
                        if (clock.elapsedRealtimeMillis() >= deadlineMs) {
                            return@interruptingOnCancel UploadOutcome.Failed(
                                NetFailure.TIMEOUT, null, secondsSince(startedMs), null, sent,
                            )
                        }
                        val n = minOf(chunk.size.toLong(), bytesToSend - sent).toInt()
                        out.write(chunk, 0, n)
                        sent += n
                    }
                    out.flush()
                }
                val code = connection.responseCode
                httpCode = code
                // Drain and close so the connection is not left half-open on a keep-alive socket.
                runCatching { connection.inputStream.use { it.readBytes() } }
                UploadOutcome.Completed(sent, secondsSince(startedMs), code)
            }
        } catch (e: IOException) {
            return uploadFailureOf(e, secondsSince(startedMs), httpCode, sent)
        } catch (e: SecurityException) {
            return UploadOutcome.Failed(NetFailure.IO, NOT_PERMITTED, secondsSince(startedMs), httpCode, sent)
        } finally {
            connection.disconnect()
        }
    }

    private fun uploadFailureOf(error: IOException?, seconds: Double, httpCode: Int?, bytes: Long?): UploadOutcome.Failed =
        when (error) {
            is SocketTimeoutException -> UploadOutcome.Failed(NetFailure.TIMEOUT, null, seconds, httpCode, bytes)
            is UnknownHostException -> UploadOutcome.Failed(NetFailure.DNS, null, seconds, httpCode, bytes)
            else -> UploadOutcome.Failed(NetFailure.IO, error?.javaClass?.simpleName, seconds, httpCode, bytes)
        }

    private suspend fun pingOn(
        network: Network,
        target: String,
        count: Int,
        timeoutMs: Long,
        onEcho: ((sequence: Int, rttMs: Double?) -> Unit)? = null,
    ): PingOutcome {
        val startedMs = clock.elapsedRealtimeMillis()
        val addresses: Array<InetAddress> = try {
            network.getAllByName(target)
        } catch (e: UnknownHostException) {
            return PingOutcome.Failed(NetFailure.DNS, null, secondsSince(startedMs))
        } catch (e: SecurityException) {
            return PingOutcome.Failed(NetFailure.IO, NOT_PERMITTED, secondsSince(startedMs))
        }
        val address: InetAddress = addresses.firstOrNull { it is Inet4Address }
            ?: return PingOutcome.Failed(NetFailure.DNS, NO_IPV4, secondsSince(startedMs))

        val socket = try {
            Os.socket(OsConstants.AF_INET, OsConstants.SOCK_DGRAM, OsConstants.IPPROTO_ICMP)
        } catch (e: ErrnoException) {
            val failure = if (e.errno == OsConstants.EACCES || e.errno == OsConstants.EPERM) {
                NetFailure.SOCKET_NOT_PERMITTED
            } else {
                NetFailure.IO
            }
            return PingOutcome.Failed(failure, OsConstants.errnoName(e.errno), secondsSince(startedMs))
        }
        try {
            try {
                network.bindSocket(socket)
            } catch (e: IOException) {
                return PingOutcome.Failed(NetFailure.IO, BIND_FAILED, secondsSince(startedMs))
            }
            val payload = IcmpEcho.payload()
            val buffer = ByteArray(IcmpEcho.HEADER_BYTES + payload.size + RECEIVE_SLACK_BYTES)
            val rtts = ArrayList<Double>(count)
            var attempted = 0
            var sent = 0
            var lastError: String? = null
            for (index in 1..count) {
                currentCoroutineContext().ensureActive()
                val sequence = index and 0xFFFF
                val packet = IcmpEcho.request(sequence, payload)
                val sentAtNanos = nanoTime()
                attempted++
                try {
                    Os.sendto(socket, packet, 0, packet.size, 0, address, 0)
                    sent++
                    val rtt = awaitReply(socket, buffer, sequence, sentAtNanos, timeoutMs)
                    rtt?.let { rtts += it }
                    onEcho?.invoke(index, rtt)
                } catch (e: ErrnoException) {
                    lastError = OsConstants.errnoName(e.errno)
                    onEcho?.invoke(index, null)
                } catch (e: SocketException) {
                    lastError = e.javaClass.simpleName
                    onEcho?.invoke(index, null)
                }
                if (index < count) {
                    val spentMs = (nanoTime() - sentAtNanos) / NANOS_PER_MS
                    if (spentMs < ECHO_SPACING_MS) delay(ECHO_SPACING_MS - spentMs)
                }
            }
            if (sent == 0) return PingOutcome.Failed(NetFailure.IO, lastError, secondsSince(startedMs))
            return PingOutcome.Replies(sent = attempted, rttsMs = rtts, seconds = secondsSince(startedMs))
        } finally {
            try {
                Os.close(socket)
            } catch (e: ErrnoException) {
                // The socket is gone either way.
            }
        }
    }

    private suspend fun awaitReply(
        socket: FileDescriptor,
        buffer: ByteArray,
        sequence: Int,
        sentAtNanos: Long,
        timeoutMs: Long,
    ): Double? {
        val deadlineNanos = sentAtNanos + timeoutMs * NANOS_PER_MS
        while (true) {
            currentCoroutineContext().ensureActive()
            val remainingMs = (deadlineNanos - nanoTime()) / NANOS_PER_MS
            if (remainingMs <= 0) return null
            val pollfd = StructPollfd()
            pollfd.fd = socket
            pollfd.events = OsConstants.POLLIN.toShort()
            val ready = try {
                Os.poll(arrayOf(pollfd), minOf(remainingMs, POLL_SLICE_MS).toInt())
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.EINTR) continue
                return null
            }
            if (ready <= 0) continue
            val length = try {
                Os.recvfrom(socket, buffer, 0, buffer.size, 0, null)
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.EINTR || e.errno == OsConstants.EAGAIN) continue
                return null
            } catch (e: SocketException) {
                return null
            }
            val receivedAtNanos = nanoTime()
            if (IcmpEcho.isReplyTo(buffer, length, sequence)) {
                return (receivedAtNanos - sentAtNanos) / NANOS_PER_MS.toDouble()
            }
        }
    }

    private suspend fun downloadOn(network: Network, url: URL, capBytes: Long, timeoutMs: Long): DownloadOutcome {
        val startedMs = clock.elapsedRealtimeMillis()
        val deadlineMs = startedMs + timeoutMs
        val opened = try {
            network.openConnection(url)
        } catch (e: IOException) {
            return failureOf(e, secondsSince(startedMs), null, null)
        }
        val connection: HttpURLConnection = opened as? HttpURLConnection
            ?: return DownloadOutcome.Failed(NetFailure.INVALID_URL, null, 0.0, null, null)

        val job = currentCoroutineContext()[Job]
        var httpCode: Int? = null
        try {
            // The response wait and the body reads block their thread and ignore cancellation. Disconnecting from
            // another thread the moment the test is cancelled (Stop, the service destroyed) closes the socket, so
            // they fail at once and the cellular request is released with the test, not at the 15 s read timeout.
            return interruptingOnCancel(interrupt = { connection.disconnect() }) {
                transfer(connection, capBytes, timeoutMs, startedMs, deadlineMs, job) { code -> httpCode = code }
            }
        } catch (e: IOException) {
            return failureOf(e, secondsSince(startedMs), httpCode, null)
        } catch (e: SecurityException) {
            return DownloadOutcome.Failed(NetFailure.IO, NOT_PERMITTED, secondsSince(startedMs), httpCode, null)
        } finally {
            connection.disconnect()
        }
    }

    /** The request and the body of one download on [connection]; blocking. [onResponse] learns the HTTP status. */
    private suspend fun transfer(
        connection: HttpURLConnection,
        capBytes: Long,
        timeoutMs: Long,
        startedMs: Long,
        deadlineMs: Long,
        job: Job?,
        onResponse: (Int) -> Unit,
    ): DownloadOutcome {
        val socketTimeoutMs = minOf(timeoutMs, SOCKET_TIMEOUT_MS).toInt()
        connection.connectTimeout = socketTimeoutMs
        connection.readTimeout = socketTimeoutMs
        connection.instanceFollowRedirects = true
        connection.useCaches = false
        connection.setRequestProperty("Accept-Encoding", "identity")
        connection.setRequestProperty("Cache-Control", "no-cache")
        connection.setRequestProperty("User-Agent", USER_AGENT)
        // Before the connection has an engine, a disconnect has nothing to close: a cancellation that came first stops here.
        currentCoroutineContext().ensureActive()
        val code = connection.responseCode
        onResponse(code)
        if (code != HttpURLConnection.HTTP_OK) {
            return DownloadOutcome.Failed(NetFailure.HTTP_STATUS, code.toString(), secondsSince(startedMs), code, null)
        }
        val counted = connection.inputStream.use { input ->
            BodyCounter.count(input, capBytes, clock, deadlineMs, isActive = { job?.isActive != false })
        }
        val seconds = secondsSince(startedMs)
        return when (counted.end) {
            BodyCount.End.COMPLETE, BodyCount.End.CAP, BodyCount.End.DEADLINE -> when {
                counted.bytes > 0 ->
                    DownloadOutcome.Completed(counted.bytes, seconds, code, capped = counted.end != BodyCount.End.COMPLETE)
                counted.end == BodyCount.End.DEADLINE ->
                    DownloadOutcome.Failed(NetFailure.TIMEOUT, null, seconds, code, 0)
                else ->
                    DownloadOutcome.Failed(NetFailure.IO, EMPTY_BODY, seconds, code, 0)
            }
            BodyCount.End.CANCELLED -> {
                currentCoroutineContext().ensureActive()
                DownloadOutcome.Failed(NetFailure.IO, CANCELLED, seconds, code, counted.bytes)
            }
            BodyCount.End.ERROR -> failureOf(counted.error, seconds, code, counted.bytes)
        }
    }

    private fun failureOf(error: IOException?, seconds: Double, httpCode: Int?, bytes: Long?): DownloadOutcome.Failed =
        when (error) {
            is SocketTimeoutException -> DownloadOutcome.Failed(NetFailure.TIMEOUT, null, seconds, httpCode, bytes)
            is UnknownHostException -> DownloadOutcome.Failed(NetFailure.DNS, null, seconds, httpCode, bytes)
            else -> DownloadOutcome.Failed(NetFailure.IO, error?.javaClass?.simpleName, seconds, httpCode, bytes)
        }

    private fun secondsSince(startedMs: Long): Double =
        (clock.elapsedRealtimeMillis() - startedMs).coerceAtLeast(0) / 1000.0

    private companion object {
        /** How long a test waits for Android to bring up or confirm the cellular network. */
        const val NETWORK_TIMEOUT_MS = 10_000L
        const val ECHO_SPACING_MS = 1_000L
        const val POLL_SLICE_MS = 200L
        const val SOCKET_TIMEOUT_MS = 15_000L

        /** Never send more than this in one test, whatever the settings say. */
        const val MAX_UPLOAD_BYTES = 50_000_000L
        const val UPLOAD_CHUNK_BYTES = 32 * 1024
        const val RECEIVE_SLACK_BYTES = 128
        const val NANOS_PER_MS = 1_000_000L
        const val HTTPS = "https"
        const val USER_AGENT = "5gto6G-FieldTap"
        const val NOT_PERMITTED = "not permitted"
        const val NO_IPV4 = "no IPv4 address"
        const val BIND_FAILED = "could not bind to cellular"
        const val EMPTY_BODY = "empty body"
        const val CANCELLED = "cancelled"
    }
}
