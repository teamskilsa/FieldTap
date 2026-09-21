package com.fieldtap.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The NR RRC decoder on a real SM8450 capture — a 5G standalone registration attempt on a commercial n77
 * cell — held to Wireshark's reading of the same bytes.
 */
class NrRrcTest {

    private val records: List<LogRecord> by lazy {
        val bytes = javaClass.getResourceAsStream("/oneplus-5g-registration.qmdl")!!.readBytes()
        Unframer().feed(bytes).flatMap { Protocol.logPacketsOf(it) }.map { Protocol.parseLogPacket(it) }
    }

    private val nr: List<NrRrc.Message> by lazy { records.filter { it.code == 0xB821 }.map { NrRrc.decode(it.body)!! } }

    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun List<Field>.value(label: String) = first { it.label == label }.value

    @Test
    fun theHeaderThisModemWritesIsNotTheOneTheTableExpects() {
        // Packet version 17 with a 27-byte header. The Python table maps 17 to the 20-byte layout, which made
        // every record here read as an unmapped PDU type; the trailing length picks the right one instead.
        assertTrue(nr.isNotEmpty())
        assertTrue(nr.all { it.packetVersion == 17 })
        assertTrue("every message named", nr.all { it.asn1Name != null && it.channel != null })
    }

    @Test
    fun theCellsAndMessagesAreWiresharks() {
        assertEquals(
            listOf(
                "BCCH-BCH mib", "BCCH-DL-SCH systemInformationBlockType1", "UL-CCCH rrcSetupRequest",
                "DL-CCCH rrcSetup", "UL-DCCH rrcSetupComplete", "DL-DCCH dlInformationTransfer",
                "DL-DCCH rrcRelease", "PCCH paging", "PCCH paging",
            ),
            nr.map { "${it.channel!!.label} ${it.asn1Name}" },
        )
        // The registration was attempted on PCI 417, NR-ARFCN 647328 (n77); the paging came on another cell.
        assertTrue(nr.take(7).all { it.pci == 417 && it.arfcn == 647_328L })
        assertEquals(152, nr.last().pci)
        assertEquals(501_390L, nr.last().arfcn)
        // SRB1 for the dedicated messages, none for broadcast.
        assertEquals(1, nr.first { it.asn1Name == "rrcSetupComplete" }.bearerId)
        assertNull(nr.first().bearerId)
    }

    @Test
    fun theSetupRequestFieldsAreWiresharks() {
        // Wireshark: ue-Identity randomValue 0fe8e748c4, establishmentCause mo-Signalling (3).
        val request = nr.first { it.asn1Name == "rrcSetupRequest" }
        val identity = request.fields.first { it.label == "UE identity" }
        assertEquals("random value", identity.value)
        assertEquals("0x0fe8e748c4", identity.children.single().value)
        assertEquals("mo-Signalling", request.fields.value("Establishment cause"))
    }

    @Test
    fun theNasInsideTheRrcIsTheOnlyCopyAndComesOutWhole() {
        // Wireshark: RRC Setup Complete carries dedicatedNAS-Message 7e004179...f070, a registration request.
        val complete = nr.first { it.asn1Name == "rrcSetupComplete" }
        assertEquals("1", complete.fields.value("Selected PLMN"))
        assertEquals("7e004179000d0100f110f0ff000010325476982e04f070f070", hex(complete.nas!!))
        // And DL Information Transfer carries the registration reject.
        val transfer = nr.first { it.asn1Name == "dlInformationTransfer" }
        assertEquals("7e00441b16012c", hex(transfer.nas!!))
        assertNull(nr.first { it.asn1Name == "rrcRelease" }.nas)
    }

    @Test
    fun theNasReadsAsTheRegistrationItIs() {
        val complete = nr.first { it.asn1Name == "rrcSetupComplete" }
        val request = Nas.decodePdu(complete.nas!!, nr = true)!!
        assertEquals("Registration request", request.name)
        assertEquals("5gmm", request.sublayer)
        val reject = Nas.decodePdu(nr.first { it.asn1Name == "dlInformationTransfer" }.nas!!, nr = true)!!
        assertEquals("Registration reject", reject.name)
        assertEquals(27, reject.cause)
        assertEquals("N1 mode not allowed", reject.causeName)
    }

    @Test
    fun aReleaseWithNoOptionsSaysNothingRatherThanGuessing() {
        // Wireshark shows rrcRelease with no IEs at all.
        assertEquals(emptyList<Field>(), nr.first { it.asn1Name == "rrcRelease" }.fields)
    }

    @Test
    fun thePagedIdentityIsWiresharks() {
        // Wireshark: one paging record, ue-Identity ng-5G-S-TMSI 400cc6e89880.
        val paging = nr.first { it.asn1Name == "paging" }
        val paged = paging.fields.first { it.label == "Paged" }
        assertEquals("1", paged.value)
        assertEquals(listOf(Field("5G-S-TMSI", "0x400cc6e89880")), paged.children)
    }

    @Test
    fun aSuspendingReleaseAndARejectAreReadFromConstructedBytes() {
        // Constructed; Wireshark: rrcRelease with suspendConfig, and rrcReject waitTime 4.
        assertEquals(
            listOf(Field("Carries", "suspend (RRC inactive)")),
            NrRrc.Details.of("rrcRelease", hex("1020")),
        )
        assertEquals(listOf(Field("Wait time", "4 s")), NrRrc.Details.of("rrcReject", hex("0860")))
    }

    @Test
    fun namesReadLikeTheSpec() {
        assertEquals("RRC Setup Complete", NrRrc.readable("rrcSetupComplete"))
        assertEquals("DL Information Transfer", NrRrc.readable("dlInformationTransfer"))
        assertEquals("MIB", NrRrc.readable("mib"))
        assertEquals("SIB1", NrRrc.readable("systemInformationBlockType1"))
        assertEquals("Mobility From NR Command", NrRrc.readable("mobilityFromNRCommand"))
    }

    @Test
    fun aRecordTooShortForAnyHeaderIsNotDecoded() {
        assertNull(NrRrc.decode(ByteArray(8)))
    }
}
