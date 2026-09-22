package com.fieldtap.diag

/**
 * 0xB821 NR RRC OTA packets: the cell, the channel, the message, and the 5G NAS carried inside it.
 *
 * Same shape as [LteRrc] — packet version, a header whose layout the version picks, then the PDU — with two
 * differences that matter.
 *
 * The first is that the layout table from `fieldtap/decode/nr_rrc.py` does not cover this modem. An SM8450
 * logs packet version 17 with a 27-byte header; the Python table maps version 17 to the 20-byte layout, which
 * is why every NR record in a real capture came out as "unmapped PDU type". The header is chosen the way
 * [LteRrc] chooses one — by the trailing length field agreeing with the record — so a wrong table entry costs
 * nothing and a new modem generation is picked up by probing.
 *
 * The second is that 5G NAS travels inside it. [Message.nas] pulls `dedicatedNAS-Message` out of the three
 * messages that carry one — RRCSetupComplete, ULInformationTransfer and DLInformationTransfer. This modem also
 * logs the plain NAS on its own (0xB80A, 0xB80B; 0xB80C and 0xB80D hold state, not messages), and the call
 * flow keeps that copy: the RRC one says which message carried it and on which cell, and is the only copy on a
 * modem that does not log the plain one. Every field here is checked against Wireshark's reading of the same
 * bytes.
 *
 * Owner: workstream `diag-on-handset`.
 */
object NrRrc {

    enum class Channel(val label: String, val uplink: Boolean) {
        BCCH_BCH("BCCH-BCH", false),
        BCCH_DL_SCH("BCCH-DL-SCH", false),
        DL_CCCH("DL-CCCH", false),
        DL_DCCH("DL-DCCH", false),
        PCCH("PCCH", false),
        UL_CCCH("UL-CCCH", true),
        UL_CCCH1("UL-CCCH1", true),
        UL_DCCH("UL-DCCH", true),

        /** EN-DC: an NR message the modem logs on its own, having carried it inside an LTE RRC message. */
        RRC_RECONFIGURATION("RRCReconfiguration", false),
        RRC_RECONFIGURATION_COMPLETE("RRCReconfigurationComplete", true),
    }

    /** One NR RRC message as the modem logged it. */
    data class Message(
        val packetVersion: Int,
        val pci: Int,
        val arfcn: Long,
        /** SRB the message went on; null when the header does not name one (broadcast and paging). */
        val bearerId: Int?,
        val channel: Channel?,
        val pduNumber: Int,
        val asn1Name: String?,
        val payload: ByteArray,
        val fields: List<Field>,
        /** The NAS message this RRC message carried, when it carried one. */
        val nas: ByteArray?,
    ) {
        override fun equals(other: Any?): Boolean = this === other
        override fun hashCode(): Int = System.identityHashCode(this)
    }

    // MARK: - Header

    private class Layout(val name: String, val size: Int, val read: (ByteArray, Int) -> Raw)

    private class Raw(val bearerId: Int, val pci: Int, val arfcn: Long, val pduNum: Int, val length: Int)

    private fun u8(b: ByteArray, i: Int) = b[i].toInt() and 0xFF
    private fun u16(b: ByteArray, i: Int) = u8(b, i) or (u8(b, i + 1) shl 8)
    private fun u32(b: ByteArray, i: Int) = (u16(b, i).toLong()) or (u16(b, i + 2).toLong() shl 16)

    // Offsets are after the 4-byte packet version. All little-endian.
    /** rel, ver, rb, pci, arfcn, sfn/subframe (u16), pdu, sib mask, length. */
    private val A = Layout("A", 18) { b, o -> Raw(u8(b, o + 2), u16(b, o + 3), u32(b, o + 5), u8(b, o + 11), u16(b, o + 16)) }

    /** A with a 32-bit frame field. */
    private val B = Layout("B", 20) { b, o -> Raw(u8(b, o + 2), u16(b, o + 3), u32(b, o + 9 + 4), u8(b, o + 13), u16(b, o + 18)) }

    /** SM8450, packet version 17: five bytes of cell identity before the ARFCN, and a wider tail. */
    private val C = Layout("C", 27) { b, o -> Raw(u8(b, o + 2), u16(b, o + 3), u32(b, o + 13), u8(b, o + 20), u16(b, o + 25)) }

    /**
     * iPhone 17 (M25 modem), packet version 26: C plus four reserved bytes after the length, 35 bytes with the
     * version. The length fits in 7 of 7 records of the recovered QDSS trace (contract v1, D2).
     */
    private val E = Layout("E", 31) { b, o -> Raw(u8(b, o + 2), u16(b, o + 3), u32(b, o + 13), u8(b, o + 20), u16(b, o + 25)) }

    private val LAYOUTS = listOf(E, C, B, A)

    private val VERSIONS = mapOf(
        7 to A, 9 to A, 12 to A, 14 to A,
        15 to B, 19 to B, 23 to B, 25 to B, 26 to E,
        17 to C, 27 to C,
    )

    private val PDU_MAP = mapOf(
        1 to Channel.BCCH_BCH, 2 to Channel.BCCH_DL_SCH, 3 to Channel.DL_CCCH, 4 to Channel.DL_DCCH,
        5 to Channel.PCCH, 6 to Channel.UL_CCCH, 7 to Channel.UL_CCCH1, 8 to Channel.UL_DCCH,
        9 to Channel.RRC_RECONFIGURATION, 10 to Channel.RRC_RECONFIGURATION_COMPLETE,
        // Version 26 (iPhone 17) numbers the same EN-DC containers 11 and 12. Its PDU 36, RadioBearerConfig,
        // stays unmapped until contract v2, so the Android and iPhone call flows count it the same way.
        11 to Channel.RRC_RECONFIGURATION, 12 to Channel.RRC_RECONFIGURATION_COMPLETE,
    )

    private const val VERSION_SIZE = 4

    fun decode(body: ByteArray): Message? {
        if (body.size < VERSION_SIZE + A.size) return null
        val version = u32(body, 0).toInt()
        val preferred = VERSIONS[version]
        val order = listOfNotNull(preferred) + LAYOUTS.filter { it !== preferred }
        var chosen: Pair<Layout, Raw>? = null
        for (candidate in order) {
            if (body.size < VERSION_SIZE + candidate.size) continue
            val raw = candidate.read(body, VERSION_SIZE)
            // The length that fits is the layout that is right; the first that parses is the fallback.
            if (raw.length == body.size - VERSION_SIZE - candidate.size) {
                chosen = candidate to raw
                break
            }
            if (chosen == null) chosen = candidate to raw
        }
        val (fit, raw) = chosen ?: return null
        val start = VERSION_SIZE + fit.size
        val payload = if (raw.length in 1..(body.size - start)) body.copyOfRange(start, start + raw.length) else body.copyOfRange(start, body.size)
        val channel = PDU_MAP[raw.pduNum]
        val name = channel?.let { outerName(it, payload) }
        val fields = if (channel != null && name != null) Details.of(name, payload) else emptyList()
        return Message(
            packetVersion = version,
            pci = raw.pci,
            arfcn = raw.arfcn,
            bearerId = raw.bearerId.takeIf { it != 0xFF },
            channel = channel,
            pduNumber = raw.pduNum,
            asn1Name = name,
            payload = payload,
            fields = fields,
            nas = if (name != null) Details.nas(name, payload) else null,
        )
    }

    // MARK: - Names

    private val DL_DCCH = listOf(
        "rrcReconfiguration", "rrcResume", "rrcRelease", "rrcReestablishment", "securityModeCommand",
        "dlInformationTransfer", "ueCapabilityEnquiry", "counterCheck", "mobilityFromNRCommand",
        "dlDedicatedMessageSegment", "ueInformationRequest", "dlInformationTransferMRDC",
        "loggedMeasurementConfiguration", "spare3", "spare2", "spare1",
    )
    private val UL_DCCH = listOf(
        "measurementReport", "rrcReconfigurationComplete", "rrcSetupComplete", "rrcReestablishmentComplete",
        "rrcResumeComplete", "securityModeComplete", "securityModeFailure", "ulInformationTransfer",
        "locationMeasurementIndication", "ueCapabilityInformation", "counterCheckResponse",
        "ueAssistanceInformation", "failureInformation", "ulInformationTransferMRDC",
        "scgFailureInformation", "scgFailureInformationEUTRA",
    )
    private val DL_CCCH = listOf("rrcReject", "rrcSetup", "spare2", "spare1")
    private val UL_CCCH = listOf("rrcSetupRequest", "rrcResumeRequest", "rrcReestablishmentRequest", "rrcSystemInfoRequest")
    private val UL_CCCH1 = listOf("rrcResumeRequest1", "spare3", "spare2", "spare1")
    private val BCCH_DL_SCH = listOf("systemInformation", "systemInformationBlockType1")

    private fun outerName(channel: Channel, payload: ByteArray): String? {
        if (payload.isEmpty()) return null
        if (channel == Channel.RRC_RECONFIGURATION) return "rrcReconfiguration"
        if (channel == Channel.RRC_RECONFIGURATION_COMPLETE) return "rrcReconfigurationComplete"
        val bits = PerBits(payload)
        return try {
            // BCCH-BCH is a SEQUENCE holding a CHOICE of two, with no c1 level above it.
            if (channel == Channel.BCCH_BCH) return if (bits.read(1) == 0) "mib" else "messageClassExtension"
            if (bits.read(1) != 0) return "messageClassExtension"
            when (channel) {
                Channel.DL_DCCH -> DL_DCCH[bits.read(4)]
                Channel.UL_DCCH -> UL_DCCH[bits.read(4)]
                Channel.DL_CCCH -> DL_CCCH[bits.read(2)]
                Channel.UL_CCCH -> UL_CCCH[bits.read(2)]
                Channel.UL_CCCH1 -> UL_CCCH1[bits.read(2)]
                Channel.BCCH_DL_SCH -> BCCH_DL_SCH[bits.read(1)]
                Channel.PCCH -> "paging"
                else -> null
            }
        } catch (e: IndexOutOfBoundsException) {
            null
        }
    }

    /** "rrcSetupComplete" → "RRC Setup Complete". */
    fun readable(asn1Name: String): String = READABLE[asn1Name] ?: LteRrc.readable(asn1Name)

    private val READABLE = mapOf(
        "mib" to "MIB",
        "systemInformationBlockType1" to "SIB1",
        "systemInformation" to "System Information",
        "paging" to "Paging",
        "ulInformationTransfer" to "UL Information Transfer",
        "dlInformationTransfer" to "DL Information Transfer",
        "ueCapabilityEnquiry" to "UE Capability Enquiry",
        "ueCapabilityInformation" to "UE Capability Information",
        "mobilityFromNRCommand" to "Mobility From NR Command",
        "ulInformationTransferMRDC" to "UL Information Transfer MRDC",
        "dlInformationTransferMRDC" to "DL Information Transfer MRDC",
        "scgFailureInformationEUTRA" to "SCG Failure Information EUTRA",
    )

    // MARK: - Fields at fixed positions

    internal object Details {
        /** TS 38.331 EstablishmentCause. */
        private val ESTABLISHMENT_CAUSE = listOf(
            "emergency", "highPriorityAccess", "mt-Access", "mo-Signalling", "mo-Data", "mo-VoiceCall",
            "mo-VideoCall", "mo-SMS", "mps-PriorityAccess", "mcs-PriorityAccess",
            "spare6", "spare5", "spare4", "spare3", "spare2", "spare1",
        )
        private val REESTABLISHMENT_CAUSE = listOf("reconfigurationFailure", "handoverFailure", "otherFailure", "spare1")

        fun of(name: String, payload: ByteArray): List<Field> = try {
            when (name) {
                "rrcSetupRequest" -> setupRequest(payload)
                "rrcReestablishmentRequest" -> reestablishmentRequest(payload)
                "rrcReject" -> reject(payload)
                "rrcRelease" -> release(payload)
                "paging" -> paging(payload)
                "rrcSetupComplete" -> setupComplete(payload).first
                else -> emptyList()
            }
        } catch (e: IndexOutOfBoundsException) {
            emptyList()
        }

        /** The `dedicatedNAS-Message` of the messages that carry one, or null. */
        fun nas(name: String, payload: ByteArray): ByteArray? = try {
            when (name) {
                "rrcSetupComplete" -> setupComplete(payload).second
                "ulInformationTransfer", "dlInformationTransfer" -> informationTransfer(payload)
                else -> null
            }
        } catch (e: IndexOutOfBoundsException) {
            null
        }

        /** UL-CCCH: c1, rrcSetupRequest, ue-Identity CHOICE (39 bits either way), establishmentCause, spare. */
        private fun setupRequest(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 3)
            val random = b.read(1) == 1
            // Wireshark prints a BIT STRING left-aligned in whole octets; 39 bits carry one pad bit.
            val identity = b.readLong(39) shl 1
            val fields = mutableListOf(
                Field(
                    "UE identity",
                    if (random) "random value" else "5G-S-TMSI part 1",
                    listOf(Field("Value", "0x%010x".format(identity))),
                ),
            )
            fields += Field("Establishment cause", ESTABLISHMENT_CAUSE[b.read(4)])
            return fields
        }

        /** UL-CCCH: c1, rrcReestablishmentRequest, c-RNTI (16), physCellId (10), shortMAC-I (16), cause. */
        private fun reestablishmentRequest(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 3)
            val cRnti = b.read(16)
            val pci = b.read(10)
            b.read(16)
            return listOf(
                Field("Cause", REESTABLISHMENT_CAUSE[b.read(2)]),
                Field("Previous cell PCI", "$pci"),
                Field("C-RNTI", "0x%04x".format(cRnti)),
            )
        }

        /** DL-CCCH: c1, rrcReject, extension marker, three optionals, waitTime 1..16 s. */
        private fun reject(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 3)
            if (b.read(1) != 0) return emptyList() // criticalExtensionsFuture
            val waitTime = b.read(1) == 1
            b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            return if (waitTime) listOf(Field("Wait time", "${b.read(4) + 1} s")) else emptyList()
        }

        /**
         * DL-DCCH: transaction id, then RRCRelease-IEs — redirectedCarrierInfo, cellReselectionPriorities,
         * suspendConfig, deprioritisationReq and the two extension slots. A release with suspendConfig is the
         * one that leaves the phone in RRC inactive rather than idle, which is a different thing to see.
         */
        private fun release(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 5)
            b.read(2) // transaction id
            if (b.read(1) != 0) return emptyList()
            val redirect = b.read(1) == 1
            b.read(1) // cellReselectionPriorities
            val suspend = b.read(1) == 1
            val deprioritise = b.read(1) == 1
            val carries = listOfNotNull(
                "redirect".takeIf { redirect },
                "suspend (RRC inactive)".takeIf { suspend },
                "deprioritisation".takeIf { deprioritise },
            )
            return if (carries.isEmpty()) emptyList() else listOf(Field("Carries", carries.joinToString(", ")))
        }

        /** PCCH: c1, paging, extension marker, optionals, then the paging records. */
        private fun paging(p: ByteArray): List<Field> {
            val b = PerBits(p, startBit = 2)
            val records = b.read(1) == 1
            b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            if (!records) return emptyList()
            val count = b.read(5) + 1
            val identities = (1..count).mapNotNull {
                // PagingRecord and PagingUE-Identity are both extensible, so each opens with an extension bit.
                if (b.read(1) != 0) return@mapNotNull null
                val accessType = b.read(1) == 1
                if (b.read(1) != 0) return@mapNotNull null
                val fiveGsTmsi = b.read(1) == 0
                val value = if (fiveGsTmsi) b.readLong(48) else (b.readLong(44) shl 4)
                if (accessType) b.read(1)
                Field(if (fiveGsTmsi) "5G-S-TMSI" else "I-RNTI", "0x%012x".format(value))
            }
            return listOf(Field("Paged", "$count", identities))
        }

        /**
         * UL-DCCH: transaction id, then RRCSetupComplete-IEs — four optionals, the selected PLMN, and the NAS
         * message. The NAS is the point: on this modem it is the only copy of the registration request there is.
         */
        private fun setupComplete(p: ByteArray): Pair<List<Field>, ByteArray?> {
            val b = PerBits(p, startBit = 5)
            b.read(2) // transaction id
            if (b.read(1) != 0) return emptyList<Field>() to null
            val registeredAmf = b.read(1) == 1
            val guamiType = b.read(1) == 1
            val nssai = b.read(1) == 1
            val tmsi = b.read(1) == 1
            b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            val plmn = b.read(4) + 1 // selectedPLMN-Identity, INTEGER (1..12)
            val fields = mutableListOf(Field("Selected PLMN", "$plmn"))
            // Anything before the NAS message that this decoder cannot walk means the NAS cannot be trusted.
            if (registeredAmf || guamiType || nssai) return fields to null
            val nas = b.readOctetString()
            if (tmsi) fields += Field("5G-S-TMSI", "included")
            return fields to nas
        }

        /** DL-DCCH / UL-DCCH: transaction id, then a NAS message and nothing else that moves. */
        private fun informationTransfer(p: ByteArray): ByteArray? {
            val b = PerBits(p, startBit = 5)
            b.read(2) // transaction id
            if (b.read(1) != 0) return null
            val nas = b.read(1) == 1
            b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            return if (nas) b.readOctetString() else null
        }
    }
}
