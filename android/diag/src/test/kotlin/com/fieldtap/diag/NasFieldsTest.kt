package com.fieldtap.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** NAS fields on the real callbox capture, each value as Wireshark 4.x reads the same bytes. */
class NasFieldsTest {

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

    private fun fields(pduHex: String, uplink: Boolean): List<Field> {
        val pdu = hex(pduHex)
        val m = Nas.decodePdu(pdu, nr = false)!!
        return NasFields.eps(m.sublayer, m.securityHeader, m.messageType, pdu, uplink)
    }

    private fun List<Field>.value(label: String) = first { it.label == label }.value

    @Test
    fun serviceRequest() {
        // Frame 1: KSI 0, sequence number 13, short MAC 0xda42.
        val f = fields("c70dda42", uplink = true)
        assertEquals("0", f.value("NAS key set"))
        assertEquals("13", f.value("Sequence number"))
        assertEquals("0xda42", f.value("Short MAC"))
    }

    @Test
    fun pdnConnectivityRequest() {
        // Frame 10: EBI 0, PTI 19, IPv4v6, initial request, APN "ims".
        val f = fields(
            "0213d031280403696d73273c8080211001000010810600000000830600000000000d00000300000100000c00001200000200000a00000500001000001100001a0102002300002400",
            uplink = true,
        )
        assertEquals("0", f.value("EPS bearer identity"))
        assertEquals("19", f.value("Procedure transaction"))
        assertEquals("IPv4v6", f.value("PDN type"))
        assertEquals("initial request", f.value("Request type"))
        assertEquals("ims", f.value("APN"))
    }

    @Test
    fun activateDefaultBearerRequest() {
        // Frame 16: EBI 6, PTI 19, QCI 5, APN ims.mnc001.mcc001.gprs, IPv4v6 ::2001:468:3000:1 and 192.168.4.2,
        // and from the extended PCO: DNS 8.8.8.8 and 2001:4860:4860::8888, P-CSCF 192.168.4.1 and 2001:468:3000:1::.
        val f = fields(
            "6213c101051703696d73066d6e63303031066d636330303104677072730d032001046830000001c0a804027b00728080210a0300000a810608080808000d040808080800031020014860486000000000000000008888000c04c0a8040100011020010468300000010000000000000000000200001b040100f110001d0606271004b71b0023000901000631300101ff0100240009012042010105070160001100",
            uplink = false,
        )
        assertEquals("6", f.value("EPS bearer identity"))
        assertEquals("19", f.value("Procedure transaction"))
        assertEquals("5", f.value("QCI"))
        assertEquals("ims.mnc001.mcc001.gprs", f.value("APN"))
        val address = f.first { it.label == "PDN address" }
        assertEquals("192.168.4.2", address.value)
        assertEquals(
            listOf(Field("PDN type", "IPv4v6"), Field("IPv6 interface ID", "::2001:468:3000:1"), Field("IPv4", "192.168.4.2")),
            address.children,
        )
        assertEquals(listOf("8.8.8.8", "2001:4860:4860::8888"), f.filter { it.label == "DNS server" }.map { it.value })
        assertEquals(listOf("192.168.4.1", "2001:468:3000:1::"), f.filter { it.label == "P-CSCF" }.map { it.value })
    }

    @Test
    fun activateDefaultBearerAccept() {
        // Frame 17: EBI 6, PTI 0.
        val f = fields("6200c2", uplink = true)
        assertEquals(listOf(Field("EPS bearer identity", "6"), Field("Procedure transaction", "0")), f)
    }

    @Test
    fun detachRequest() {
        // Frame 20: combined EPS/IMSI detach, switch off, KSI 0, GUTI 001-01 MMEGI 32769 MMEC 1 M-TMSI 0xf51a62ad.
        val f = fields("07450b0bf600f110800101f51a62ad", uplink = true)
        assertEquals("combined EPS/IMSI detach", f.value("Detach type"))
        assertEquals("yes", f.value("Switch off"))
        assertEquals("0", f.value("NAS key set"))
        val guti = f.first { it.label == "Identity" }
        assertEquals("GUTI", guti.value)
        assertEquals(
            listOf(Field("PLMN", "001-01"), Field("MME group", "32769"), Field("MME code", "1"), Field("M-TMSI", "0xf51a62ad")),
            guti.children,
        )
    }

    @Test
    fun aNetworkDetachIsNotReadAsAPhoneDetach() {
        // Constructed; Wireshark: Downlink, Detach Type Re-attach required (1), EMM cause IMSI unknown in HSS (2).
        val f = fields("0745015302", uplink = false)
        assertEquals(listOf(Field("Detach type", "re-attach required")), f)
    }

    @Test
    fun aTruncatedMessageKeepsWhatWasRead() {
        val f = fields("07450b0bf600f1", uplink = true)
        assertEquals(listOf("Detach type", "Switch off", "NAS key set"), f.map { it.label })
    }

    // MARK: - 5GS

    private fun fiveGs(pduHex: String, uplink: Boolean): List<Field> {
        val pdu = hex(pduHex)
        val m = Nas.decodePdu(pdu, nr = true)!!
        return NasFields.fiveGs(m.sublayer, m.securityHeader, m.messageType, pdu, uplink)
    }

    @Test
    fun theRealRegistrationRequestCarriesTheSubscribersOwnSuci() {
        // The registration request this phone sent, out of the RRCSetupComplete that carried it. Wireshark:
        // initial registration, follow-on pending, ngKSI 7, SUCI with MCC 001 MNC 01, null scheme, MSIN 0123456789.
        val f = fiveGs("7e004179000d0100f110f0ff000010325476982e04f070f070", uplink = true)
        assertEquals("initial registration", f.value("Registration type"))
        assertEquals("pending", f.value("Follow-on request"))
        assertEquals("no key available", f.value("NAS key set"))
        val identity = f.first { it.label == "Identity" }
        assertEquals("SUCI", identity.value)
        assertEquals(
            listOf(
                Field("PLMN", "001-01"),
                Field("Routing indicator", "0"),
                Field("Protection scheme", "null scheme"),
                Field("MSIN", "0123456789"),
            ),
            identity.children,
        )
    }

    @Test
    fun theRealRegistrationRejectCarriesItsBackoffTimer() {
        // Wireshark: 5GMM cause 27, T3502 12 min.
        assertEquals(listOf(Field("T3502", "12 min")), fiveGs("7e00441b16012c", uplink = false))
    }

    @Test
    fun aRegistrationAcceptSaysWhichAccessItCovers() {
        // Constructed; Wireshark: 5GS registration result 3GPP access, SMS over NAS not allowed.
        val f = fiveGs("7e0042010116012c", uplink = false)
        assertEquals("3GPP access", f.value("Registration result"))
        assertTrue(f.none { it.label == "SMS over NAS" })
    }

    @Test
    fun theServiceRequestHalfOctetsAreNotSwapped() {
        // Constructed; Wireshark reads 0x11 as service type 1 and NAS key set identifier 1, in that order.
        val f = fiveGs("7e004c1100067c1234567890", uplink = true)
        assertEquals("data", f.value("Service type"))
        assertEquals("1", f.value("NAS key set"))
    }

    @Test
    fun theFiveGsSecurityModeCommandNamesItsAlgorithms() {
        // Constructed; Wireshark: 128-5G-EA2, 5G-IA0, ngKSI 1.
        val f = fiveGs("7e005d2001e1360102", uplink = false)
        assertEquals("5G-EA2", f.value("Ciphering"))
        assertEquals("5G-IA0", f.value("Integrity"))
        assertEquals("1", f.value("NAS key set"))
    }

    @Test
    fun aSessionMessageInsideAMobilityMessageIsNamed() {
        // Constructed; Wireshark: UL NAS transport, N1 SM information, PDU session establishment request
        // for PDU session 5, IPv4, SSC mode 1.
        val transport = fiveGs("7e00670100082e0501c1ffff91a1", uplink = true)
        assertEquals("N1 SM information", transport.value("Payload"))
        assertEquals("PDU session establishment request", transport.value("Carries"))

        val session = fiveGs("2e0501c1ffff91a1", uplink = true)
        assertEquals("5", session.value("PDU session"))
        assertEquals("1", session.value("Procedure transaction"))
        assertEquals("IPv4", session.value("PDU session type"))
        assertEquals("1", session.value("SSC mode"))
    }

    @Test
    fun ipv6CompressesTheLongestZeroRunOnly() {
        assertEquals("2001:db8::1:0:0:1", NasFields.ipv6(hex("20010db8000000000001000000000001"), 0))
        assertEquals("::", NasFields.ipv6(hex("00000000000000000000000000000000"), 0))
        assertEquals("fe80::1", NasFields.ipv6(hex("fe800000000000000000000000000001"), 0))
    }
}
