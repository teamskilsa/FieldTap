package com.fieldtap.diag

/**
 * 0xB0C0 LTE RRC OTA packets: which cell a message was on, which channel, what the message is, and the
 * handful of fields an engineer reads first.
 *
 * Record body: packet version (u8), a header whose layout depends on the version, then the RRC PDU (UPER).
 * Five header layouts and four PDU-number maps are known across modem generations; the version picks one,
 * and the layout's trailing length — which must equal the bytes after it — confirms or rejects the pick.
 * This is a port of `fieldtap/decode/lte_rrc.py`, and the tests hold it to the same answers.
 *
 * Names come from the outer CHOICE, a few bits at the front of the PDU. Past that, only fields that sit at
 * fixed bit positions are read — causes, identities — and every one is checked against Wireshark's own
 * decode of the same bytes. Anything deeper is ASN.1 that belongs to Wireshark, and the raw bytes travel in
 * the export for it.
 *
 * Owner: workstream `diag-on-handset`.
 */
object LteRrc {

    enum class Channel(val label: String, val uplink: Boolean) {
        BCCH_BCH("BCCH-BCH", false),
        BCCH_DL_SCH("BCCH-DL-SCH", false),
        MCCH("MCCH", false),
        PCCH("PCCH", false),
        DL_CCCH("DL-CCCH", false),
        DL_DCCH("DL-DCCH", false),
        UL_CCCH("UL-CCCH", true),
        UL_DCCH("UL-DCCH", true),
    }

    /** One RRC message as the modem logged it. */
    data class Message(
        val packetVersion: Int,
        val pci: Int,
        val earfcn: Long,
        val sfn: Int,
        val subframe: Int,
        /** Null when the PDU number is one this decoder does not map. */
        val channel: Channel?,
        val pduNumber: Int,
        /** The ASN.1 identifier, e.g. `rrcConnectionRequest`; null when it could not be read. */
        val asn1Name: String?,
        val payload: ByteArray,
        /** Fields read from fixed positions, in display order. */
        val fields: List<Field>,
    ) {
        override fun equals(other: Any?): Boolean = this === other
        override fun hashCode(): Int = System.identityHashCode(this)
    }

    // MARK: - Header

    private class Layout(val name: String, val size: Int, val read: (ByteArray, Int) -> Raw)

    private class Raw(val pci: Int, val earfcn: Long, val sfnSubfn: Int, val pduNum: Int, val length: Int)

    private fun u8(b: ByteArray, i: Int) = b[i].toInt() and 0xFF
    private fun u16(b: ByteArray, i: Int) = u8(b, i) or (u8(b, i + 1) shl 8)
    private fun u32(b: ByteArray, i: Int) = (u16(b, i).toLong()) or (u16(b, i + 2).toLong() shl 16)

    // Offsets are after the version byte. All little-endian, no padding.
    private val A = Layout("A", 12) { b, o -> Raw(u16(b, o + 3), u16(b, o + 5).toLong(), u16(b, o + 7), u8(b, o + 9), u16(b, o + 10)) }
    private val B = Layout("B", 14) { b, o -> Raw(u16(b, o + 3), u32(b, o + 5), u16(b, o + 9), u8(b, o + 11), u16(b, o + 12)) }
    private val C = Layout("C", 18) { b, o -> Raw(u16(b, o + 3), u32(b, o + 5), u16(b, o + 9), u8(b, o + 11), u16(b, o + 16)) }

    /** HDR_D: C with three more bytes before the PCI (a release byte and an unexplained u16). SM8450, version 27. */
    private val D = Layout("D", 20) { b, o -> Raw(u16(b, o + 5), u32(b, o + 7), u16(b, o + 11), u8(b, o + 13), u16(b, o + 18)) }

    /**
     * HDR_E: D plus three trailing bytes after the length. iPhone 17 (M25 modem), version 30: the length equals the
     * bytes after the header in 100 of 100 records of the recovered QDSS trace (contract v1, D2).
     */
    private val E = Layout("E", 23) { b, o -> Raw(u16(b, o + 5), u32(b, o + 7), u16(b, o + 11), u8(b, o + 13), u16(b, o + 18)) }

    private val LAYOUTS = listOf(A, B, C, D, E)

    private val MAP_A = mapOf(1 to Channel.BCCH_BCH, 2 to Channel.BCCH_DL_SCH, 3 to Channel.MCCH, 4 to Channel.PCCH, 5 to Channel.DL_CCCH, 6 to Channel.DL_DCCH, 7 to Channel.UL_CCCH, 8 to Channel.UL_DCCH)
    private val MAP_B = mapOf(8 to Channel.BCCH_BCH, 9 to Channel.BCCH_DL_SCH, 10 to Channel.MCCH, 11 to Channel.PCCH, 12 to Channel.DL_CCCH, 13 to Channel.DL_DCCH, 14 to Channel.UL_CCCH, 15 to Channel.UL_DCCH)
    private val MAP_C = mapOf(1 to Channel.BCCH_BCH, 2 to Channel.BCCH_DL_SCH, 4 to Channel.MCCH, 5 to Channel.PCCH, 6 to Channel.DL_CCCH, 7 to Channel.DL_DCCH, 8 to Channel.UL_CCCH, 9 to Channel.UL_DCCH)
    private val MAP_D = mapOf(1 to Channel.BCCH_BCH, 3 to Channel.BCCH_DL_SCH, 6 to Channel.MCCH, 7 to Channel.PCCH, 8 to Channel.DL_CCCH, 9 to Channel.DL_DCCH, 10 to Channel.UL_CCCH, 11 to Channel.UL_DCCH)

    private fun preferred(version: Int): Pair<Layout?, Map<Int, Channel>> = when (version) {
        2, 3, 4, 6, 7, 8, 13, 22 -> A to MAP_A
        9, 12 -> B to MAP_B
        14, 15, 16 -> C to MAP_C
        19, 26 -> C to MAP_D
        27 -> D to MAP_D
        30 -> E to MAP_D
        else -> null to when {
            version >= 19 -> MAP_D
            version >= 14 -> MAP_C
            version >= 9 -> MAP_B
            else -> MAP_A
        }
    }

    fun decode(body: ByteArray): Message? {
        if (body.size < 1 + A.size) return null
        val version = u8(body, 0)
        val (layout, map) = preferred(version)
        val order = listOfNotNull(layout) + LAYOUTS.filter { it !== layout }
        var chosen: Pair<Layout, Raw>? = null
        for (candidate in order) {
            if (body.size < 1 + candidate.size) continue
            val raw = candidate.read(body, 1)
            // The length that fits is the layout that is right; the first that parses is the fallback.
            if (raw.length == body.size - 1 - candidate.size) {
                chosen = candidate to raw
                break
            }
            if (chosen == null) chosen = candidate to raw
        }
        val (fit, raw) = chosen ?: return null
        val start = 1 + fit.size
        val payload = if (raw.length in 1..(body.size - start)) body.copyOfRange(start, start + raw.length) else body.copyOfRange(start, body.size)
        val channel = map[raw.pduNum]
        val name = channel?.let { outerName(it, payload) }
        return Message(
            packetVersion = version,
            pci = raw.pci,
            earfcn = raw.earfcn,
            sfn = raw.sfnSubfn shr 4,
            subframe = raw.sfnSubfn and 0xF,
            channel = channel,
            pduNumber = raw.pduNum,
            asn1Name = name,
            payload = payload,
            fields = if (channel != null && name != null) Details.of(channel, name, payload) else emptyList(),
        )
    }

    // MARK: - Names

    private val DL_DCCH = listOf(
        "csfbParametersResponseCDMA2000", "dlInformationTransfer", "handoverFromEUTRAPreparationRequest",
        "mobilityFromEUTRACommand", "rrcConnectionReconfiguration", "rrcConnectionRelease", "securityModeCommand",
        "ueCapabilityEnquiry", "counterCheck", "ueInformationRequest", "loggedMeasurementConfiguration",
        "rnReconfiguration", "rrcConnectionResume", "spare3", "spare2", "spare1",
    )
    private val UL_DCCH = listOf(
        "csfbParametersRequestCDMA2000", "measurementReport", "rrcConnectionReconfigurationComplete",
        "rrcConnectionReestablishmentComplete", "rrcConnectionSetupComplete", "securityModeComplete",
        "securityModeFailure", "ueCapabilityInformation", "ulHandoverPreparationTransfer", "ulInformationTransfer",
        "counterCheckResponse", "ueInformationResponse", "proximityIndication", "rnReconfigurationComplete",
        "mbmsCountingResponse", "interFreqRSTDMeasurementIndication",
    )
    private val DL_CCCH = listOf("rrcConnectionReestablishment", "rrcConnectionReestablishmentReject", "rrcConnectionReject", "rrcConnectionSetup")
    private val UL_CCCH = listOf("rrcConnectionReestablishmentRequest", "rrcConnectionRequest")
    private val BCCH_DL_SCH = listOf("systemInformation", "systemInformationBlockType1")

    private fun outerName(channel: Channel, payload: ByteArray): String? {
        if (channel == Channel.BCCH_BCH) return "masterInformationBlock"
        if (payload.isEmpty()) return null
        val bits = PerBits(payload)
        return try {
            if (bits.read(1) != 0) return "messageClassExtension"
            when (channel) {
                Channel.DL_DCCH -> DL_DCCH[bits.read(4)]
                Channel.UL_DCCH -> UL_DCCH[bits.read(4)]
                Channel.DL_CCCH -> DL_CCCH[bits.read(2)]
                Channel.UL_CCCH -> UL_CCCH[bits.read(1)]
                Channel.BCCH_DL_SCH -> BCCH_DL_SCH[bits.read(1)]
                Channel.PCCH -> "paging"
                Channel.MCCH -> "mbsfnAreaConfiguration"
                Channel.BCCH_BCH -> "masterInformationBlock"
            }
        } catch (e: IndexOutOfBoundsException) {
            null
        }
    }

    /** "rrcConnectionReconfigurationComplete" → "RRC Connection Reconfiguration Complete". */
    fun readable(asn1Name: String): String = READABLE[asn1Name] ?: asn1Name
        .replace(Regex("([a-z0-9])([A-Z])"), "$1 $2")
        .split(' ')
        .joinToString(" ") { word ->
            when (word.lowercase()) {
                "rrc" -> "RRC"
                "ue" -> "UE"
                "ul" -> "UL"
                "dl" -> "DL"
                else -> word.replaceFirstChar { it.uppercase() }
            }
        }

    private val READABLE = mapOf(
        "systemInformationBlockType1" to "SIB1",
        "systemInformation" to "System Information",
        "masterInformationBlock" to "MIB",
        "ulInformationTransfer" to "UL Information Transfer",
        "dlInformationTransfer" to "DL Information Transfer",
        "ueCapabilityEnquiry" to "UE Capability Enquiry",
        "ueCapabilityInformation" to "UE Capability Information",
        "csfbParametersResponseCDMA2000" to "CSFB Parameters Response CDMA2000",
        "csfbParametersRequestCDMA2000" to "CSFB Parameters Request CDMA2000",
        "handoverFromEUTRAPreparationRequest" to "Handover From EUTRA Preparation Request",
        "mobilityFromEUTRACommand" to "Mobility From EUTRA Command",
        "interFreqRSTDMeasurementIndication" to "Inter-Freq RSTD Measurement Indication",
    )

    // MARK: - Fields at fixed positions

    /** Fields past the outer CHOICE. Each decode is pinned to Wireshark's reading of a real or constructed PDU. */
    /** The label of the field a handover command carries. */
    const val HANDOVER: String = "Handover"

    internal object Details {
        private val ESTABLISHMENT_CAUSE = listOf(
            "emergency", "highPriorityAccess", "mt-Access", "mo-Signalling", "mo-Data", "delayTolerantAccess", "mo-VoiceCall", "spare1",
        )
        private val RELEASE_CAUSE = listOf("loadBalancingTAUrequired", "other", "cs-FallbackHighPriority", "rrc-Suspend")
        private val REESTABLISHMENT_CAUSE = listOf("reconfigurationFailure", "handoverFailure", "otherFailure", "spare1")

        fun of(channel: Channel, name: String, payload: ByteArray): List<Field> = try {
            when (name) {
                "rrcConnectionRequest" -> connectionRequest(payload)
                "rrcConnectionRelease" -> connectionRelease(payload)
                "rrcConnectionReject" -> connectionReject(payload)
                "rrcConnectionReestablishmentRequest" -> reestablishmentRequest(payload)
                "measurementReport" -> measurementReport(payload)
                "rrcConnectionReconfiguration" -> connectionReconfiguration(payload)
                else -> emptyList()
            }
        } catch (e: IndexOutOfBoundsException) {
            // A PDU shorter than its own structure is truncated or not what its CHOICE claims. Say nothing.
            emptyList()
        }

        /** UL-CCCH: c1, rrcConnectionRequest, r8, ue-Identity CHOICE, establishmentCause. */
        private fun connectionRequest(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 2)
            if (b.read(1) != 0) return emptyList() // criticalExtensionsFuture
            val fields = mutableListOf<Field>()
            if (b.read(1) == 0) {
                val mmec = b.read(8)
                val mTmsi = b.readLong(32)
                fields += Field("UE identity", "S-TMSI", listOf(Field("MMEC", "%d".format(mmec)), Field("M-TMSI", "0x%08x".format(mTmsi))))
            } else {
                b.readLong(40)
                fields += Field("UE identity", "random value")
            }
            fields += Field("Establishment cause", ESTABLISHMENT_CAUSE[b.read(3)])
            return fields
        }

        /** DL-DCCH: rrc-TransactionIdentifier, c1, r8, optional bitmap (3), releaseCause, then a redirect if present. */
        private fun connectionRelease(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 5)
            b.read(2) // transaction id
            if (b.read(1) != 0) return emptyList()
            if (b.read(2) != 0) return emptyList() // not r8
            val redirect = b.read(1) == 1
            b.read(1) // idleModeMobilityControlInfo
            b.read(1) // nonCriticalExtension
            val fields = mutableListOf(Field("Release cause", RELEASE_CAUSE[b.read(2)]))
            if (redirect) {
                // RedirectedCarrierInfo: extensible CHOICE of six; eutra carries a 16-bit EARFCN.
                val extended = b.read(1) == 1
                val index = if (extended) -1 else b.read(3)
                fields += if (index == 0) {
                    Field("Redirected to", "EUTRA EARFCN ${b.read(16)}")
                } else {
                    Field("Redirected to", listOf("EUTRA", "GERAN", "UTRA-FDD", "UTRA-TDD", "CDMA2000 HRPD", "CDMA2000 1xRTT").getOrNull(index) ?: "another RAT")
                }
            }
            return fields
        }

        /**
         * DL-DCCH: transaction id, c1, r8, then the r8 presence bitmap — measConfig, mobilityControlInfo,
         * dedicatedInfoNASList, radioResourceConfigDedicated, securityConfigHO, nonCriticalExtension.
         *
         * The one with mobilityControlInfo is a handover command. Its target sits at a fixed place only when
         * no measConfig comes before it; otherwise the target is the cell the next message is logged on.
         */
        private fun connectionReconfiguration(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 5)
            b.read(2) // transaction id
            if (b.read(1) != 0) return emptyList()
            if (b.read(3) != 0) return emptyList() // not r8
            val meas = b.read(1) == 1
            val mobility = b.read(1) == 1
            val nas = b.read(1) == 1
            val radio = b.read(1) == 1
            val securityHo = b.read(1) == 1
            b.read(1) // nonCriticalExtension
            val fields = mutableListOf<Field>()
            if (mobility) fields += Field(HANDOVER, if (meas) "command" else mobilityTarget(b))
            val carries = listOfNotNull(
                "measurement config".takeIf { meas },
                "NAS".takeIf { nas },
                "radio resources".takeIf { radio },
                "handover security".takeIf { securityHo },
            )
            if (carries.isNotEmpty()) fields += Field("Carries", carries.joinToString(", "))
            return fields
        }

        /** MobilityControlInfo: extension bit, four optionals, targetPhysCellId (9), then carrierFreq if present. */
        private fun mobilityTarget(b: PerBits): String {
            b.read(1)
            val carrier = b.read(1) == 1
            b.read(3) // carrierBandwidth, additionalSpectrumEmission, rach-ConfigDedicated
            val pci = b.read(9)
            if (!carrier) return "to PCI $pci, same EARFCN"
            b.read(1) // ul-CarrierFreq
            return "to PCI $pci, EARFCN ${b.read(16)}"
        }

        /** DL-CCCH: c1, rrcConnectionReject, r8, optional bitmap (1), waitTime 1..16 s. */
        private fun connectionReject(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 3)
            if (b.read(1) != 0) return emptyList()
            if (b.read(2) != 0) return emptyList()
            b.read(1) // nonCriticalExtension
            return listOf(Field("Wait time", "${b.read(4) + 1} s"))
        }

        /** UL-CCCH: c1, reestablishment request, r8, C-RNTI (16), PCI (9), shortMAC-I (16), cause. */
        private fun reestablishmentRequest(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 2)
            if (b.read(1) != 0) return emptyList()
            val cRnti = b.read(16)
            val pci = b.read(9)
            b.read(16)
            return listOf(
                Field("Cause", REESTABLISHMENT_CAUSE[b.read(2)]),
                Field("Previous cell PCI", "$pci"),
                Field("C-RNTI", "0x%04x".format(cRnti)),
            )
        }

        /**
         * UL-DCCH: c1, measurementReport, r8 (1 + 3 bits), the r8 bitmap (1), then MeasResults: extension bit,
         * neighbour-present bit, measId (1..32), PCell RSRP and RSRQ, and an EUTRA neighbour list when present.
         * RSRP is reported as 0..97 for -140..-44 dBm; RSRQ as 0..34 for -19.5..-3 dB.
         */
        private fun measurementReport(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 5)
            if (b.read(1) != 0) return emptyList()
            if (b.read(3) != 0) return emptyList()
            b.read(1) // nonCriticalExtension
            b.read(1) // MeasResults extension
            val neighbours = b.read(1) == 1
            val measId = b.read(5) + 1
            val fields = mutableListOf(
                Field("Measurement ID", "$measId"),
                Field("Serving RSRP", rsrp(b.read(7))),
                Field("Serving RSRQ", rsrq(b.read(6))),
            )
            if (neighbours && b.read(1) == 0 && b.read(2) == 0) {
                val count = b.read(3) + 1
                val cells = (1..count).map {
                    val cgi = b.read(1) == 1
                    val pci = b.read(9)
                    if (cgi) return fields + Field("Neighbours", "$count reported, with cell identity (not decoded)")
                    val ext = b.read(1) == 1
                    val hasRsrp = b.read(1) == 1
                    val hasRsrq = b.read(1) == 1
                    val r = if (hasRsrp) rsrp(b.read(7)) else "—"
                    val q = if (hasRsrq) rsrq(b.read(6)) else "—"
                    if (ext) b.skipExtensionAdditions()
                    Field("PCI $pci", "$r · $q")
                }
                fields += Field("Neighbours", "$count", cells)
            }
            return fields
        }

        /**
         * A reported RSRP index is a 1 dB bin, not a value: n means n−141 ≤ RSRP < n−140 (TS 36.133). Quoting
         * n−140 alone reads one dB high on every report, so the bin is shown, as Wireshark shows it.
         */
        internal fun rsrp(v: Int) = when (v) {
            0 -> "< −140 dBm"
            97 -> "≥ −44 dBm"
            else -> "${v - 141} to ${v - 140} dBm".replace("-", "−")
        }

        /** RSRQ index n: −20 + n/2 ≤ RSRQ < −19.5 + n/2 dB. */
        internal fun rsrq(v: Int) = when (v) {
            0 -> "< −19.5 dB"
            34 -> "≥ −3 dB"
            else -> "%.1f to %.1f dB".format(java.util.Locale.ROOT, -20 + v * 0.5, -19.5 + v * 0.5).replace("-", "−")
        }
    }
}

/** A decoded field for display: a label, a value, and any fields nested under it. */
data class Field(val label: String, val value: String, val children: List<Field> = emptyList())

/** Unaligned PER bit reader, most significant bit first. */
internal class PerBits(private val data: ByteArray, startBit: Int = 0) {
    var position: Int = startBit
        private set

    fun read(n: Int): Int = readLong(n).toInt()

    fun readLong(n: Int): Long {
        var value = 0L
        repeat(n) {
            val byte = position ushr 3
            if (byte >= data.size) throw IndexOutOfBoundsException("PDU ends at bit ${data.size * 8}")
            val bit = (data[byte].toInt() ushr (7 - (position and 7))) and 1
            value = (value shl 1) or bit.toLong()
            position++
        }
        return value
    }

    /**
     * An unaligned-PER length determinant: one bit for a length under 128, two for one under 16K. A fragmented
     * length (the 16K-and-over form) is not read.
     */
    fun readLength(): Int = when {
        read(1) == 0 -> read(7)
        read(1) == 0 -> read(14)
        else -> throw IndexOutOfBoundsException("fragmented length determinant")
    }

    /** An OCTET STRING with an unconstrained length. Unaligned PER, so the content starts at the current bit. */
    fun readOctetString(): ByteArray {
        val length = readLength()
        if (position + length * 8 > data.size * 8) throw IndexOutOfBoundsException("octet string runs past the PDU")
        return ByteArray(length) { read(8).toByte() }
    }

    /** Skips a SEQUENCE's extension additions: a normally-small count, a presence bitmap, and each as an open type. */
    fun skipExtensionAdditions() {
        val count = if (read(1) == 0) read(6) + 1 else throw IndexOutOfBoundsException("large extension count")
        val present = (0 until count).count { read(1) == 1 }
        repeat(present) {
            val length = if (read(1) == 0) read(7) else throw IndexOutOfBoundsException("long open type")
            position += length * 8
        }
    }
}
