package com.fieldtap.diag

import java.util.Locale

/**
 * The fields of a plain EPS NAS message an engineer reads first (TS 24.301): who the phone said it was,
 * what it asked for, what the network gave it, and why anything was refused.
 *
 * Not every IE of every message. The ones here are the ones that answer "what happened" — attach and
 * detach types, identities, APNs, the PDN address and QCI, selected security algorithms, timers — and
 * each decode is pinned to Wireshark's reading of the same bytes. The rest of the message is in the hex,
 * and all of it is in the export for Wireshark.
 *
 * A message that is shorter than its own definition yields the fields read before it ran out, never an
 * invented one.
 *
 * Owner: workstream `diag-on-handset`.
 */
object NasFields {

    /** [pdu] starts at the NAS header; [uplink] is the direction the modem logged it in. */
    fun eps(sublayer: String, securityHeader: Int, messageType: Int?, pdu: ByteArray, uplink: Boolean): List<Field> {
        val out = mutableListOf<Field>()
        try {
            when {
                sublayer == "emm" && securityHeader == 12 -> serviceRequest(pdu, out)
                securityHeader != 0 || messageType == null -> {}
                sublayer == "emm" -> emm(messageType, pdu, uplink, out)
                sublayer == "esm" -> esm(messageType, pdu, out)
            }
        } catch (e: IndexOutOfBoundsException) {
            // Truncated: keep what was read.
        }
        return out
    }

    /** [pdu] starts at the 5GS NAS header (the extended protocol discriminator). */
    fun fiveGs(sublayer: String, securityHeader: Int, messageType: Int?, pdu: ByteArray, uplink: Boolean): List<Field> {
        val out = mutableListOf<Field>()
        if (securityHeader != 0 || messageType == null) return out
        try {
            when (sublayer) {
                "5gmm" -> fiveGmm(messageType, pdu, out)
                "5gsm" -> fiveGsm(messageType, pdu, out)
            }
        } catch (e: IndexOutOfBoundsException) {
            // Truncated: keep what was read.
        }
        return out
    }

    // MARK: - 5GMM

    private fun fiveGmm(type: Int, p: ByteArray, out: MutableList<Field>) {
        when (type) {
            0x41 -> { // Registration request
                val octet = u8(p, 3)
                out += Field("Registration type", REGISTRATION_TYPE[octet and 0x07] ?: "reserved")
                if (octet and 0x08 != 0) out += Field("Follow-on request", "pending")
                out += Field("NAS key set", ksi(octet shr 4))
                fiveGsIdentity(p, 6, ((u8(p, 4) shl 8) or u8(p, 5)))?.let { out += it }
            }
            0x42 -> { // Registration accept
                val result = u8(p, 4)
                out += Field("Registration result", REGISTRATION_RESULT[result and 0x07] ?: "reserved")
                if (result and 0x08 != 0) out += Field("SMS over NAS", "allowed")
            }
            0x44, 0x4D -> timers(p, 4, out) // Registration reject, Service reject: the cause is on the row
            0x45, 0x47 -> { // Deregistration request
                val octet = u8(p, 3)
                out += Field("Deregistration", if (octet and 0x08 != 0) "switch off" else "normal")
                out += Field("Access", ACCESS_TYPE[octet and 0x03] ?: "reserved")
                if (uplinkDeregistration(type)) out += Field("NAS key set", ksi(octet shr 4))
            }
            0x4C -> { // Service request: the service type is the high half octet, the key set the low one
                val octet = u8(p, 3)
                out += Field("Service type", SERVICE_TYPE[(octet shr 4) and 0x0F] ?: "reserved")
                out += Field("NAS key set", ksi(octet))
            }
            0x5B -> out += Field("Identity requested", FIVE_GS_IDENTITY_TYPE[u8(p, 3) and 0x07] ?: "reserved")
            0x5D -> { // Security mode command
                val algorithms = u8(p, 3)
                out += Field("Ciphering", "5G-EA${(algorithms shr 4) and 0x07}")
                out += Field("Integrity", "5G-IA${algorithms and 0x07}")
                out += Field("NAS key set", ksi(u8(p, 4) and 0x0F))
            }
            0x67, 0x68 -> { // UL/DL NAS transport: a session-management message inside a mobility one
                val container = u8(p, 3) and 0x0F
                out += Field("Payload", PAYLOAD_CONTAINER[container] ?: "type $container")
                val length = (u8(p, 4) shl 8) or u8(p, 5)
                if (container == 1 && 6 + length <= p.size) {
                    val inner = Nas.decodePdu(p.copyOfRange(6, 6 + length), nr = true)
                    inner?.name?.let { out += Field("Carries", it) }
                }
            }
        }
    }

    private fun uplinkDeregistration(type: Int) = type == 0x45

    /** GPRS timers a reject can carry: T3346 (0x5F) and T3502 (0x16), both one octet of value. */
    private fun timers(p: ByteArray, from: Int, out: MutableList<Field>) {
        var i = from
        while (i + 2 < p.size) {
            val tag = u8(p, i)
            val length = u8(p, i + 1)
            when {
                tag == 0x5F && length == 1 -> out += Field("T3346", gprsTimer(u8(p, i + 2)))
                tag == 0x16 && length == 1 -> out += Field("T3502", gprsTimer(u8(p, i + 2)))
                tag >= 0x80 -> {
                    i += 1
                    continue
                }
            }
            i += 2 + length
        }
    }

    /**
     * 5GS mobile identity (TS 24.501 9.11.3.4): a SUCI, which carries the subscriber's own MSIN in the clear
     * under the null scheme, or a 5G-GUTI the network handed out.
     */
    private fun fiveGsIdentity(p: ByteArray, at: Int, length: Int): Field? {
        if (length < 1 || at + length > p.size) return null
        return when (u8(p, at) and 0x07) {
            1 -> { // SUCI
                // Type octet, PLMN (3), routing indicator (2), protection scheme, public key id, then the MSIN.
                val scheme = u8(p, at + 6) and 0x0F
                val children = mutableListOf(
                    Field("PLMN", plmn(p, at + 1)),
                    Field("Routing indicator", bcd(p, at + 4, 2)),
                    Field("Protection scheme", SUCI_SCHEME[scheme] ?: "scheme $scheme"),
                )
                // Only the null scheme leaves the MSIN readable; the others are the whole point of SUCI.
                if (scheme == 0) children += Field("MSIN", bcd(p, at + 8, length - 8))
                Field("Identity", "SUCI", children)
            }
            2 -> Field(
                "Identity",
                "5G-GUTI",
                listOf(
                    Field("PLMN", plmn(p, at + 1)),
                    Field("AMF region", "${u8(p, at + 4)}"),
                    Field("AMF set", "${((u8(p, at + 5) shl 8) or u8(p, at + 6)) shr 6}"),
                    Field("AMF pointer", "${u8(p, at + 6) and 0x3F}"),
                    Field("5G-TMSI", "0x%08x".format(
                        (u8(p, at + 7).toLong() shl 24) or (u8(p, at + 8).toLong() shl 16) or
                            (u8(p, at + 9).toLong() shl 8) or u8(p, at + 10).toLong(),
                    )),
                ),
            )
            3 -> Field("Identity", "IMEI ${bcdDigits(p, at, length)}")
            4 -> Field("Identity", "5G-S-TMSI")
            5 -> Field("Identity", "IMEISV ${bcdDigits(p, at, length)}")
            else -> null
        }
    }

    // MARK: - 5GSM

    private fun fiveGsm(type: Int, p: ByteArray, out: MutableList<Field>) {
        out += Field("PDU session", "${u8(p, 1)}")
        out += Field("Procedure transaction", "${u8(p, 2)}")
        when (type) {
            0xC1 -> { // PDU session establishment request
                var i = 6 // after the integrity protection maximum data rate
                while (i < p.size) {
                    val tag = u8(p, i)
                    when {
                        tag shr 4 == 0x9 -> {
                            out += Field("PDU session type", FIVE_GS_PDN_TYPE[tag and 0x0F] ?: "reserved")
                            i += 1
                        }
                        tag shr 4 == 0xA -> {
                            out += Field("SSC mode", "${tag and 0x0F}")
                            i += 1
                        }
                        tag >= 0x80 -> i += 1
                        else -> i += 2 + u8(p, i + 1)
                    }
                }
            }
            0xC2 -> { // PDU session establishment accept
                out += Field("PDU session type", FIVE_GS_PDN_TYPE[u8(p, 4) and 0x0F] ?: "reserved")
                out += Field("SSC mode", "${(u8(p, 4) shr 4) and 0x07}")
            }
        }
    }

    // MARK: - EMM

    private fun emm(type: Int, p: ByteArray, uplink: Boolean, out: MutableList<Field>) {
        when (type) {
            0x41 -> { // Attach request
                out += Field("Attach type", ATTACH_TYPE[u8(p, 2) and 0x07] ?: "reserved")
                out += Field("NAS key set", ksi(u8(p, 2) shr 4))
                identityLv(p, 3)?.let { out += it }
            }
            0x42 -> { // Attach accept
                out += Field("Attach result", ATTACH_RESULT[u8(p, 2) and 0x07] ?: "reserved")
                out += Field("T3412", gprsTimer(u8(p, 3)))
                val taiLength = u8(p, 4)
                firstTai(p, 5, taiLength)?.let { out += it }
            }
            0x44, 0x4B, 0x4E -> {} // Rejects: the cause is shown on the row already.
            0x45 -> { // Detach request
                val octet = u8(p, 2)
                if (uplink) {
                    // Switch-off bit and a detach type, then the identity.
                    out += Field("Detach type", DETACH_TYPE_UL[octet and 0x07] ?: "reserved")
                    out += Field("Switch off", if (octet and 0x08 != 0) "yes" else "no")
                    out += Field("NAS key set", ksi(octet shr 4))
                    identityLv(p, 3)?.let { out += it }
                } else {
                    out += Field("Detach type", DETACH_TYPE_DL[octet and 0x07] ?: "reserved")
                }
            }
            0x48 -> { // Tracking area update request
                out += Field("Update type", UPDATE_TYPE[u8(p, 2) and 0x07] ?: "reserved")
                out += Field("Active flag", if (u8(p, 2) and 0x08 != 0) "set" else "not set")
                identityLv(p, 3)?.let { out += it.copy(label = "Old GUTI") }
            }
            0x49 -> out += Field("Update result", UPDATE_RESULT[u8(p, 2) and 0x07] ?: "reserved")
            0x52 -> { // Authentication request
                out += Field("NAS key set", ksi(u8(p, 2) and 0x0F))
                out += Field("RAND", hex(p, 3, 16))
            }
            0x55 -> out += Field("Identity requested", IDENTITY_TYPE[u8(p, 2) and 0x07] ?: "reserved")
            0x5D -> { // Security mode command
                val algorithms = u8(p, 2)
                out += Field("Ciphering", "EEA${(algorithms shr 4) and 0x07}")
                out += Field("Integrity", "EIA${algorithms and 0x07}")
                out += Field("NAS key set", ksi(u8(p, 3) and 0x0F))
            }
        }
    }

    /** SERVICE REQUEST: KSI and short sequence number, then a 2-octet short MAC. */
    private fun serviceRequest(p: ByteArray, out: MutableList<Field>) {
        val ksiSeq = u8(p, 1)
        out += Field("NAS key set", ksi(ksiSeq shr 5))
        out += Field("Sequence number", "${ksiSeq and 0x1F}")
        out += Field("Short MAC", "0x%04x".format(Locale.ROOT, (u8(p, 2) shl 8) or u8(p, 3)))
    }

    // MARK: - ESM

    private fun esm(type: Int, p: ByteArray, out: MutableList<Field>) {
        out += Field("EPS bearer identity", "${u8(p, 0) shr 4}")
        out += Field("Procedure transaction", "${u8(p, 1)}")
        when (type) {
            0xD0 -> { // PDN connectivity request
                out += Field("PDN type", PDN_TYPE[u8(p, 3) shr 4] ?: "reserved")
                out += Field("Request type", REQUEST_TYPE[u8(p, 3) and 0x0F] ?: "reserved")
                optional(p, 4) { tag, at, length -> if (tag == 0x28) out += Field("APN", apn(p, at, length)) }
            }
            0xC1 -> { // Activate default EPS bearer context request
                var at = 3
                val qosLength = u8(p, at)
                out += Field("QCI", "${u8(p, at + 1)}")
                at += 1 + qosLength
                val apnLength = u8(p, at)
                out += Field("APN", apn(p, at + 1, apnLength))
                at += 1 + apnLength
                pdnAddress(p, at + 1, u8(p, at))?.let { out += it }
                at += 1 + u8(p, at)
                optional(p, at) { tag, valueAt, length -> if (tag == 0x27 || tag == 0x7B) out += pco(p, valueAt, length) }
            }
            0xC5 -> { // Activate dedicated EPS bearer context request
                out += Field("Linked bearer", "${u8(p, 3) and 0x0F}")
                out += Field("QCI", "${u8(p, 5)}")
            }
            0xDA -> optional(p, 3) { tag, at, length -> if (tag == 0x28) out += Field("APN", apn(p, at, length)) }
        }
    }

    // MARK: - Information elements

    /** EPS mobile identity, LV at [at]: IMSI, GUTI or IMEI. */
    private fun identityLv(p: ByteArray, at: Int): Field? {
        val length = u8(p, at)
        val start = at + 1
        return when (u8(p, start) and 0x07) {
            6 -> { // GUTI
                val plmn = plmn(p, start + 1)
                val mmeGroup = (u8(p, start + 4) shl 8) or u8(p, start + 5)
                val mmeCode = u8(p, start + 6)
                val mTmsi = (u8(p, start + 7).toLong() shl 24) or (u8(p, start + 8).toLong() shl 16) or
                    (u8(p, start + 9).toLong() shl 8) or u8(p, start + 10).toLong()
                Field(
                    "Identity",
                    "GUTI",
                    listOf(
                        Field("PLMN", plmn),
                        Field("MME group", "$mmeGroup"),
                        Field("MME code", "$mmeCode"),
                        Field("M-TMSI", "0x%08x".format(Locale.ROOT, mTmsi)),
                    ),
                )
            }
            1 -> Field("Identity", "IMSI ${bcdDigits(p, start, length)}")
            2, 3 -> Field("Identity", "IMEI ${bcdDigits(p, start, length)}")
            else -> null
        }
    }

    /** Plain BCD digits, low nibble first, stopping at the 0xF filler. */
    internal fun bcd(p: ByteArray, at: Int, octets: Int): String {
        val sb = StringBuilder()
        for (i in 0 until octets) {
            val o = u8(p, at + i)
            val low = o and 0x0F
            if (low == 0x0F) break
            sb.append(low)
            val high = o shr 4
            if (high == 0x0F) break
            sb.append(high)
        }
        return sb.toString()
    }

    /** Digits of an odd/even BCD identity: the first digit in the high nibble of the type octet. */
    private fun bcdDigits(p: ByteArray, start: Int, length: Int): String {
        val sb = StringBuilder()
        val odd = u8(p, start) and 0x08 != 0
        sb.append(u8(p, start) shr 4)
        for (i in 1 until length) {
            val o = u8(p, start + i)
            sb.append(o and 0x0F)
            val high = o shr 4
            if (i < length - 1 || odd) sb.append(high)
        }
        return sb.toString()
    }

    /** Three octets of BCD MCC and MNC, as "001-01". */
    internal fun plmn(p: ByteArray, at: Int): String {
        val o1 = u8(p, at)
        val o2 = u8(p, at + 1)
        val o3 = u8(p, at + 2)
        val mcc = "${o1 and 0x0F}${o1 shr 4}${o2 and 0x0F}"
        val mnc3 = o2 shr 4
        val mnc = "${o3 and 0x0F}${o3 shr 4}" + if (mnc3 == 0x0F) "" else "$mnc3"
        return "$mcc-$mnc"
    }

    private fun firstTai(p: ByteArray, at: Int, length: Int): Field? {
        if (length < 6) return null
        // All three list types put the first PLMN and TAC straight after the type-and-count octet.
        val tac = (u8(p, at + 4) shl 8) or u8(p, at + 5)
        return Field("Tracking area", "${plmn(p, at + 1)} TAC $tac")
    }

    /** APN: length-prefixed labels, shown dotted. */
    internal fun apn(p: ByteArray, at: Int, length: Int): String {
        val labels = mutableListOf<String>()
        var i = at
        while (i < at + length) {
            val n = u8(p, i)
            labels += String(p, i + 1, n, Charsets.US_ASCII)
            i += 1 + n
        }
        return labels.joinToString(".")
    }

    /** PDN address: a PDN type, then IPv4 (4), an IPv6 interface identifier (8), or both. */
    private fun pdnAddress(p: ByteArray, at: Int, length: Int): Field? {
        val type = u8(p, at) and 0x07
        val children = mutableListOf(Field("PDN type", PDN_TYPE[type] ?: "reserved"))
        when (type) {
            1 -> children += Field("IPv4", ipv4(p, at + 1))
            2 -> children += Field("IPv6 interface ID", ipv6Iid(p, at + 1))
            3 -> {
                children += Field("IPv6 interface ID", ipv6Iid(p, at + 1))
                children += Field("IPv4", ipv4(p, at + 9))
            }
        }
        if (length < 5) return null
        // The row shows the IPv4 address when there is one: it is the one people ping.
        return Field("PDN address", (children.firstOrNull { it.label == "IPv4" } ?: children.last()).value, children)
    }

    private fun ipv4(p: ByteArray, at: Int) = (0 until 4).joinToString(".") { "${u8(p, at + it)}" }

    /** Wireshark writes the 64-bit interface identifier as "::2001:468:3000:1"; so does this. */
    private fun ipv6Iid(p: ByteArray, at: Int) =
        "::" + (0 until 4).joinToString(":") { Integer.toHexString((u8(p, at + 2 * it) shl 8) or u8(p, at + 2 * it + 1)) }

    /**
     * Walks optional IEs from [at]. Tags 0x80 and up are one-octet (type 1 and 2) IEs; ESM cause (0x58) and
     * LLC SAPI (0x32) are two-octet TVs; the extended PCO (0x7B) and extended QoS-like containers (0x78) have
     * a two-octet length; the rest are TLVs with one length octet.
     */
    private fun optional(p: ByteArray, at: Int, each: (tag: Int, valueAt: Int, length: Int) -> Unit) {
        var i = at
        while (i < p.size) {
            val tag = u8(p, i)
            if (tag >= 0x80) {
                i += 1
                continue
            }
            if (tag == 0x58 || tag == 0x32) {
                i += 2
                continue
            }
            if (tag == 0x7B || tag == 0x78) { // LV-E: two-octet length
                val length = (u8(p, i + 1) shl 8) or u8(p, i + 2)
                each(tag, i + 3, length)
                i += 3 + length
                continue
            }
            val length = u8(p, i + 1)
            each(tag, i + 2, length)
            i += 2 + length
        }
    }

    /**
     * Protocol configuration options (TS 24.008 10.5.6.3), network to phone: the DNS servers and P-CSCFs.
     * The rest (IPCP, slices, QoS rules) is Wireshark's to show. Containers 0x0023 and 0x0024 carry a
     * two-octet length; everything else one.
     */
    private fun pco(p: ByteArray, at: Int, length: Int): List<Field> {
        val end = minOf(at + length, p.size)
        val out = mutableListOf<Field>()
        var i = at + 1 // configuration protocol octet
        while (i + 3 <= end) {
            val id = (u8(p, i) shl 8) or u8(p, i + 1)
            val wide = id == 0x0023 || id == 0x0024
            val size = if (wide) (u8(p, i + 2) shl 8) or u8(p, i + 3) else u8(p, i + 2)
            val valueAt = i + if (wide) 4 else 3
            if (valueAt + size > end) break
            when {
                id == 0x000D && size == 4 -> out += Field("DNS server", ipv4(p, valueAt))
                id == 0x0003 && size == 16 -> out += Field("DNS server", ipv6(p, valueAt))
                id == 0x000C && size == 4 -> out += Field("P-CSCF", ipv4(p, valueAt))
                id == 0x0001 && size == 16 -> out += Field("P-CSCF", ipv6(p, valueAt))
            }
            i = valueAt + size
        }
        return out
    }

    /** An IPv6 address the way Wireshark and RFC 5952 write it: the longest run of zero groups as "::". */
    internal fun ipv6(p: ByteArray, at: Int): String {
        val groups = IntArray(8) { (u8(p, at + 2 * it) shl 8) or u8(p, at + 2 * it + 1) }
        var bestStart = -1
        var bestLength = 1
        var i = 0
        while (i < 8) {
            if (groups[i] == 0) {
                var j = i
                while (j < 8 && groups[j] == 0) j++
                if (j - i > bestLength) {
                    bestStart = i
                    bestLength = j - i
                }
                i = j
            } else {
                i++
            }
        }
        fun hex(range: IntRange) = range.joinToString(":") { Integer.toHexString(groups[it]) }
        return if (bestStart < 0) hex(0..7) else hex(0 until bestStart) + "::" + hex(bestStart + bestLength..7)
    }

    /** GPRS timer (TS 24.008 10.5.7.3): 3-bit unit, 5-bit value. */
    internal fun gprsTimer(octet: Int): String {
        val value = octet and 0x1F
        return when (octet shr 5) {
            0 -> "${value * 2} s"
            1 -> "$value min"
            2 -> "${value * 6} min"
            7 -> "deactivated"
            else -> "$value min"
        }
    }

    private fun ksi(value: Int) = if (value and 0x07 == 7) "no key available" else "${value and 0x07}"

    private fun hex(p: ByteArray, at: Int, length: Int) = (0 until length).joinToString("") { "%02x".format(Locale.ROOT, u8(p, at + it)) }

    private fun u8(p: ByteArray, i: Int): Int = p[i].toInt() and 0xFF

    private val ATTACH_TYPE = mapOf(1 to "EPS attach", 2 to "combined EPS/IMSI attach", 3 to "EPS RLOS attach", 6 to "EPS emergency attach")
    private val ATTACH_RESULT = mapOf(1 to "EPS only", 2 to "combined EPS/IMSI")
    private val DETACH_TYPE_UL = mapOf(1 to "EPS detach", 2 to "IMSI detach", 3 to "combined EPS/IMSI detach")
    private val DETACH_TYPE_DL = mapOf(1 to "re-attach required", 2 to "re-attach not required", 3 to "IMSI detach")
    private val UPDATE_TYPE = mapOf(0 to "TA updating", 1 to "combined TA/LA updating", 2 to "combined TA/LA with IMSI attach", 3 to "periodic updating")
    private val UPDATE_RESULT = mapOf(0 to "TA updated", 1 to "combined TA/LA updated", 4 to "TA updated, ISR activated", 5 to "combined TA/LA updated, ISR activated")
    private val IDENTITY_TYPE = mapOf(1 to "IMSI", 2 to "IMEI", 3 to "IMEISV", 4 to "TMSI")
    private val PDN_TYPE = mapOf(1 to "IPv4", 2 to "IPv6", 3 to "IPv4v6", 5 to "non-IP", 6 to "Ethernet")
    private val REQUEST_TYPE = mapOf(1 to "initial request", 2 to "handover", 4 to "emergency")
    private val REGISTRATION_TYPE = mapOf(
        1 to "initial registration", 2 to "mobility registration updating", 3 to "periodic registration updating",
        4 to "emergency registration", 7 to "SNPN onboarding registration",
    )
    private val REGISTRATION_RESULT = mapOf(1 to "3GPP access", 2 to "non-3GPP access", 3 to "3GPP and non-3GPP access")
    private val ACCESS_TYPE = mapOf(1 to "3GPP access", 2 to "non-3GPP access", 3 to "3GPP and non-3GPP access")
    private val SERVICE_TYPE = mapOf(
        0 to "signalling", 1 to "data", 2 to "mobile terminated services", 3 to "emergency services",
        4 to "emergency services fallback", 5 to "high priority access", 6 to "elevated signalling",
    )
    private val FIVE_GS_IDENTITY_TYPE = mapOf(1 to "SUCI", 2 to "5G-GUTI", 3 to "IMEI", 4 to "5G-S-TMSI", 5 to "IMEISV")
    private val SUCI_SCHEME = mapOf(0 to "null scheme", 1 to "Profile A", 2 to "Profile B")
    private val FIVE_GS_PDN_TYPE = mapOf(1 to "IPv4", 2 to "IPv6", 3 to "IPv4v6", 4 to "unstructured", 5 to "Ethernet")
    private val PAYLOAD_CONTAINER = mapOf(
        1 to "N1 SM information", 2 to "SMS", 3 to "LTE positioning protocol", 4 to "SOR transparent container",
        5 to "UE policy container", 6 to "UE parameters update", 8 to "CIoT user data container",
    )
}
