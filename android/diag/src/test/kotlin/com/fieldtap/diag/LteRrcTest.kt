package com.fieldtap.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The LTE RRC decoder on a real SM8450 capture, held to Python's decode and Wireshark's reading of the same bytes. */
class LteRrcTest {

    private val records: List<LogRecord> by lazy {
        val bytes = javaClass.getResourceAsStream("/oneplus-callbox-service-request.qmdl")!!.readBytes()
        Unframer().feed(bytes).flatMap { Protocol.logPacketsOf(it) }.map { Protocol.parseLogPacket(it) }
    }

    private val rrc: List<LteRrc.Message> by lazy { records.filter { it.code == 0xB0C0 }.map { LteRrc.decode(it.body)!! } }

    @Test
    fun everyRrcPacketOfTheCaptureDecodesWithTheLengthConfirmingTheLayout() {
        // 13 LTE RRC packets; the 14th "RRC" record the old screen counted is an NR RRC packet (0xB821).
        assertEquals(13, rrc.size)
        assertTrue(rrc.all { it.packetVersion == 27 })
        assertTrue("every message named", rrc.all { it.asn1Name != null && it.channel != null })
    }

    @Test
    fun theCellAndChannelMatchWhatPythonReads() {
        // fieldtap/decode/lte_rrc.py on the same file: every message on PCI 3, EARFCN 1575.
        assertTrue(rrc.all { it.pci == 3 && it.earfcn == 1575L })
        assertEquals(
            listOf(
                "UL-CCCH rrcConnectionRequest", "DL-CCCH rrcConnectionSetup", "UL-DCCH rrcConnectionSetupComplete",
                "DL-DCCH securityModeCommand", "UL-DCCH securityModeComplete", "DL-DCCH rrcConnectionReconfiguration",
                "UL-DCCH rrcConnectionReconfigurationComplete", "UL-DCCH ulInformationTransfer",
                "DL-DCCH rrcConnectionReconfiguration", "UL-DCCH rrcConnectionReconfigurationComplete",
                "UL-DCCH ulInformationTransfer", "UL-DCCH ulInformationTransfer", "DL-DCCH rrcConnectionRelease",
            ),
            rrc.map { "${it.channel!!.label} ${it.asn1Name}" },
        )
        assertEquals("UL-CCCH rrcConnectionRequest", rrc.first().let { "${it.channel!!.label} ${it.asn1Name}" })
        assertEquals("DL-DCCH rrcConnectionRelease", rrc.last().let { "${it.channel!!.label} ${it.asn1Name}" })
    }

    @Test
    fun theConnectionRequestFieldsAreWiresharks() {
        // Wireshark: s-TMSI mmec 01, m-TMSI f51a62ad, establishmentCause mo-Data (4).
        val request = rrc.first()
        val identity = request.fields.first { it.label == "UE identity" }
        assertEquals("S-TMSI", identity.value)
        assertEquals("1", identity.children.first { it.label == "MMEC" }.value)
        assertEquals("0xf51a62ad", identity.children.first { it.label == "M-TMSI" }.value)
        assertEquals("mo-Data", request.fields.first { it.label == "Establishment cause" }.value)
    }

    @Test
    fun theReleaseCauseIsWiresharks() {
        // Wireshark: RRCConnectionRelease [cause=other].
        assertEquals(listOf(Field("Release cause", "other")), rrc.last().fields)
    }

    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // The PDUs below have no real sample yet. Each was built bit by bit and then decoded by Wireshark 4.x
    // (exported-PDU, lte-rrc.* dissectors); the expectations are Wireshark's reading, not this decoder's.

    @Test
    fun aMeasurementReportGivesServingAndNeighboursAsWiresharkReadsThem() {
        // Wireshark: measId 1; PCell -98..-97 dBm (43), -6.5..-6 dB (27); EUTRA PCI 3 -94..-93 (47) -7.5..-7 (25);
        // PCI 5 -99..-98 (42) -15..-14.5 (10).
        val fields = LteRrc.Details.of(LteRrc.Channel.UL_DCCH, "measurementReport", hex("08102b6c100daf64056a8a"))
        assertEquals("1", fields.first { it.label == "Measurement ID" }.value)
        assertEquals("−98 to −97 dBm", fields.first { it.label == "Serving RSRP" }.value)
        assertEquals("−6.5 to −6.0 dB", fields.first { it.label == "Serving RSRQ" }.value)
        val neighbours = fields.first { it.label == "Neighbours" }
        assertEquals(listOf("PCI 3", "PCI 5"), neighbours.children.map { it.label })
        assertEquals("−94 to −93 dBm · −7.5 to −7.0 dB", neighbours.children[0].value)
        assertEquals("−99 to −98 dBm · −15.0 to −14.5 dB", neighbours.children[1].value)
    }

    @Test
    fun aConnectionRejectGivesItsWaitTime() {
        // Wireshark: rrcConnectionReject-r8, waitTime: 10s.
        assertEquals(listOf(Field("Wait time", "10 s")), LteRrc.Details.of(LteRrc.Channel.DL_CCCH, "rrcConnectionReject", hex("4120")))
    }

    @Test
    fun aReestablishmentRequestGivesTheFailureAndTheCellItHappenedOn() {
        // Wireshark: c-RNTI 1234, physCellId 2, reestablishmentCause handoverFailure (1).
        val fields = LteRrc.Details.of(LteRrc.Channel.UL_CCCH, "rrcConnectionReestablishmentRequest", hex("0246802abcd4"))
        assertEquals("handoverFailure", fields.first { it.label == "Cause" }.value)
        assertEquals("2", fields.first { it.label == "Previous cell PCI" }.value)
        assertEquals("0x1234", fields.first { it.label == "C-RNTI" }.value)
    }

    @Test
    fun aReleaseWithARedirectGivesTheTargetCarrier() {
        // Wireshark: releaseCause other (1), redirectedCarrierInfo eutra (0): 1300.
        assertEquals(
            listOf(Field("Release cause", "other"), Field("Redirected to", "EUTRA EARFCN 1300")),
            LteRrc.Details.of(LteRrc.Channel.DL_DCCH, "rrcConnectionRelease", hex("282200a280")),
        )
    }

    @Test
    fun aHandoverCommandWithoutMeasConfigNamesItsTarget() {
        // Constructed; Wireshark: mobilityControlInfo, targetPhysCellId 2, dl-CarrierFreq 2850, t304 ms500.
        assertEquals(
            listOf(Field(LteRrc.HANDOVER, "to PCI 2, EARFCN 2850")),
            LteRrc.Details.of(LteRrc.Channel.DL_DCCH, "rrcConnectionReconfiguration", hex("220820040b228246800000000000")),
        )
    }

    @Test
    fun aHandoverCommandBehindAMeasConfigIsStillAHandover() {
        // Constructed; Wireshark: measConfig then mobilityControlInfo present.
        assertEquals(
            listOf(Field(LteRrc.HANDOVER, "command"), Field("Carries", "measurement config")),
            LteRrc.Details.of(LteRrc.Channel.DL_DCCH, "rrcConnectionReconfiguration", hex("221800")),
        )
    }

    @Test
    fun theRealReconfigurationSaysWhatItCarries() {
        // Frame 13; Wireshark: dedicatedInfoNASList (1 item) and radioResourceConfigDedicated, no mobilityControlInfo.
        val reconfigurations = rrc.filter { it.asn1Name == "rrcConnectionReconfiguration" }
        assertEquals(listOf(Field("Carries", "NAS, radio resources")), reconfigurations[1].fields)
        assertTrue(reconfigurations.none { m -> m.fields.any { it.label == LteRrc.HANDOVER } })
    }

    @Test
    fun theEdgesOfTheReportingRangesAreOpenEnded() {
        assertEquals("< −140 dBm", LteRrc.Details.rsrp(0))
        assertEquals("≥ −44 dBm", LteRrc.Details.rsrp(97))
        assertEquals("< −19.5 dB", LteRrc.Details.rsrq(0))
    }

    @Test
    fun namesReadLikeTheSpec() {
        assertEquals("RRC Connection Reconfiguration Complete", LteRrc.readable("rrcConnectionReconfigurationComplete"))
        assertEquals("Security Mode Command", LteRrc.readable("securityModeCommand"))
        assertEquals("UL Information Transfer", LteRrc.readable("ulInformationTransfer"))
        assertEquals("SIB1", LteRrc.readable("systemInformationBlockType1"))
    }

    @Test
    fun aTruncatedPduNamesTheMessageButClaimsNoFields() {
        val decoded = LteRrc.Details.of(LteRrc.Channel.UL_CCCH, "rrcConnectionRequest", byteArrayOf(0x40))
        assertTrue(decoded.isEmpty())
    }

    @Test
    fun aRecordTooShortForAnyHeaderIsNotDecoded() {
        assertEquals(null, LteRrc.decode(ByteArray(5)))
        assertNotNull(rrc.first().payload)
    }
}
