import Testing
@testable import FTCore

@Suite struct SpectrumTests {
    @Test func lteBandsAndFrequenciesOfThisCapture() throws {
        let b66 = try #require(Spectrum.lte(67_086))
        #expect(b66.band == 66 && b66.dlMhz == 2175.0 && !b66.tdd)
        let b12 = try #require(Spectrum.lte(5_110))
        #expect(b12.band == 12 && b12.dlMhz == 739.0)
        let b2 = try #require(Spectrum.lte(650))
        #expect(b2.band == 2 && b2.dlMhz == 1935.0 && b2.ulMhz == 1855.0)
        #expect(Spectrum.lte(975)?.band == 2)
    }

    @Test func tddUplinkIsTheDownlinkAndUnknownEarfcnsAreNil() {
        #expect(Spectrum.lte(40_000)?.band == 41)
        #expect(Spectrum.lte(40_000)?.ulMhz == Spectrum.lte(40_000)?.dlMhz)
        #expect(Spectrum.lte(9_700)?.ulMhz == nil, "band 29 is downlink only")
        #expect(Spectrum.lte(-1) == nil)
        #expect(Spectrum.lte(10_400) == nil)
        #expect(Spectrum.lte(Int64(67_086))?.band == 66)
    }

    @Test func nrGlobalRaster() {
        #expect(Spectrum.nrMhz(174_770) == 873.85)
        #expect(Spectrum.nrMhz(647_328) == 3709.92)
        #expect(Spectrum.nrMhz(2_016_667) == 24_250.08)
        #expect(Spectrum.nrMhz(3_279_166) == nil)
        #expect(Spectrum.nrMhz(Int64(174_770)) == 873.85)
    }

    @Test func timingAdvanceAndCellIds() {
        #expect(Spectrum.lteTimingAdvanceMetres(18) == 18 * 78.12)
        #expect(Spectrum.lteTimingAdvanceMetres(-1) == nil)
        #expect(Spectrum.lteTimingAdvanceMetres(1283) == nil)
        #expect(Spectrum.lteCellId(0x1A2_B3C4) == Spectrum.LteCellId(enb: 0x1A2B3, cell: 0xC4))
        #expect(Spectrum.lteCellId(1 << 28) == nil)
    }
}

@Suite struct LogCodesTests {
    @Test func theSignallingCodesAsKotlinListsThem() throws {
        #expect(LogCodes.all.count == 22)
        #expect(Set(LogCodes.signallingCodes).count == 22)
        let rrc = try #require(LogCodes.of(0xB0C0))
        #expect(rrc.category == .rrc && rrc.rat == "lte" && !rrc.isNr)
        let nas = try #require(LogCodes.of(0xB0EB))
        #expect(nas.category == .nas && nas.nasSublayer == "emm" && nas.nasDirection == "ul" && nas.nasProtected)
        // Contract v1 keeps the 0xB80C label as it is (the v2 backlog relabels it).
        #expect(LogCodes.of(0xB80C)?.name == "NR NAS MM5G Security Protected Incoming Msg")
        #expect(LogCodes.of(0xB821)?.isNr == true)
        #expect(LogCodes.of(0xB193) == nil, "PHY codes are not signalling codes")
    }
}

@Suite struct FmtTests {
    @Test func fmtMatchesJava() {
        #expect(Fmt.fixed(0.15, 1) == "0.2")
        #expect(Fmt.fixed(0.125, 2) == "0.13")
        #expect(Fmt.fixed(2.675, 2) == "2.68")
        #expect(Fmt.fixed(70.248, 1) == "70.2")
        #expect(Fmt.fixed(334.816, 0) == "335")
        #expect(Fmt.fixed(26_959.395, 3) == "26959.395")
        #expect(Fmt.fixed(-0.04, 1) == "-0.0")
        #expect(Fmt.fixed(0, 3) == "0.000")
        #expect(Fmt.fixed(9.995, 2) == "10.00")
        #expect(Fmt.fixed(1e-7, 3) == "0.000")
        // Checked against String.format(Locale.ROOT, ...) on openjdk 21.
        #expect(Fmt.fixed(0.05, 1) == "0.1")
        #expect(Fmt.fixed(1.005, 2) == "1.01")
        #expect(Fmt.fixed(123_456.785, 2) == "123456.79")
    }

    @Test func hexLikeKotlin() {
        #expect(Fmt.hex(UInt16(0xB0C0), width: 4) == "0xB0C0")
        #expect(Fmt.hex(0x7, width: 2) == "0x07")
        #expect(Fmt.hex(UInt8(0xAB), width: 2, prefix: false, uppercase: false) == "ab")
        #expect(Fmt.hex(Int8(-1), width: 2) == "0xFF")
    }
}
