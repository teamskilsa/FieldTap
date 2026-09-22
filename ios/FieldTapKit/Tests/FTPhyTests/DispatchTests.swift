// Strict version dispatch: only the versions validated on this modem decode; every other one is counted by its
// "code version" key and yields no samples.

import Testing
import FTModel
@testable import FTPhy

@Suite struct DispatchTests {
    /// A body whose version bytes say `version`, long enough for any layout.
    static func body(_ code: UInt16, firstByte: Int? = nil, major: Int? = nil, minor: Int? = nil,
                     subpacket: (id: Int, version: Int)? = nil) -> [UInt8] {
        var p = Packing(400)
        if let firstByte { p.u8(0, firstByte); p.u8(1, 1) }
        if let major, let minor { p.u16(0, minor); p.u16(2, major) }
        if let s = subpacket { p.u8(4, s.id); p.u8(5, s.version); p.u16(6, 60) }
        return p.bytes
    }

    @Test func strictVersionDispatch() {
        let wrong: [(UInt16, [UInt8], String)] = [
            (0xB0C1, Self.body(0xB0C1, firstByte: 3), "0xB0C1 v3"),
            (0xB0C2, Self.body(0xB0C2, firstByte: 4), "0xB0C2 v4"),
            (0xB193, Self.body(0xB193, firstByte: 2), "0xB193 v2"),
            (0xB193, Self.body(0xB193, firstByte: 1, subpacket: (0x19, 40)), "0xB193 v1/0x19 v40"),
            (0xB173, Self.body(0xB173, firstByte: 48), "0xB173 v48"),
            (0xB139, Self.body(0xB139, firstByte: 145), "0xB139 v145"),
            (0xB14E, Self.body(0xB14E, firstByte: 142), "0xB14E v142"),
            (0xB14D, Self.body(0xB14D, firstByte: 142), "0xB14D v142"),
            (0xB064, Self.body(0xB064, firstByte: 2), "0xB064 v2"),
            (0xB064, Self.body(0xB064, firstByte: 1, subpacket: (0x08, 6)), "0xB064 v1/0x08 v6"),
            (0xB062, Self.body(0xB062, firstByte: 1, subpacket: (0x06, 48)), "0xB062 v1/0x06 v48"),
            (0xB97F, Self.body(0xB97F, major: 2, minor: 9), "0xB97F 2.9"),
            (0xB887, Self.body(0xB887, major: 3, minor: 12), "0xB887 3.12"),
            (0xB888, Self.body(0xB888, major: 2, minor: 2), "0xB888 2.2"),
        ]
        let records = wrong.enumerated().map { i, w in LogRecord(code: w.0, timestampRaw: stamp(Double(i) * 10), body: w.1) }
        let capture = PhyExtractor.extract(records: records, timeBase: TimeBase.of(records), secure: .empty)
        #expect(capture.versionMisses == Dictionary(uniqueKeysWithValues: wrong.map { ($0.2, 1) }))
        #expect(capture.series.values.allSatisfy { $0.samples.isEmpty })
        #expect(capture.checks.isEmpty)
    }

    @Test func validatedVersionsDecodeAlongsideMisses() {
        var mib = Packing(11)
        mib.u8(0, 2); mib.u8(9, 4); mib.u8(10, 50)
        let records = [LogRecord(code: 0xB0C1, timestampRaw: stamp(0), body: mib.bytes),
                       LogRecord(code: 0xB0C1, timestampRaw: stamp(5), body: Self.body(0xB0C1, firstByte: 1)),
                       LogRecord(code: 0xB0C1, timestampRaw: stamp(10), body: mib.bytes)]
        let capture = PhyExtractor.extract(records: records, timeBase: TimeBase.of(records), secure: .empty)
        #expect(capture.series[.lte_tx_antennas_mib]?.samples.map(\.value) == [4, 4])
        #expect(capture.series[.lte_tx_antennas_mib]?.samples.map(\.tMs) == [0, 10])
        #expect(capture.versionMisses == ["0xB0C1 v1": 1])
        #expect(capture.summary.txAntennasMib == [4])
    }

    @Test func everyMetricNamesItsDecoderVersion() {
        for m in PhyMetric.allCases {
            let info = m.info
            #expect(!info.version.isEmpty, "\(m.rawValue)")
            #expect(PhyDispatch.codes.contains(info.code), "\(m.rawValue)")
        }
        #expect(PhyMetric.lte_ul_mcs_derived.info.confidence == .derived)
        #expect(PhyMetric.lte_pusch_tx_power_required.info.confidence == .medium)
        #expect(PhyMetric.lte_ri.info.confidence == .medium, "RI mixes 0xB14D samples")
        #expect(PhyMetric.lte_ul_phy_throughput.info.title == "UL scheduled")
    }

    @Test func samplesAreDecodedInTimeOrderWhateverTheFileOrder() {
        var mib = Packing(11)
        mib.u8(0, 2); mib.u8(9, 2); mib.u8(10, 25)
        var mib4 = mib
        mib4.u8(9, 4)
        let records = [LogRecord(code: 0xB0C1, timestampRaw: stamp(200), body: mib4.bytes),
                       LogRecord(code: 0xB0C1, timestampRaw: stamp(100), body: mib.bytes)]
        let capture = PhyExtractor.extract(records: records, timeBase: TimeBase.of(records), secure: .empty)
        #expect(capture.series[.lte_tx_antennas_mib]?.samples.map(\.value) == [2, 4])
    }
}
