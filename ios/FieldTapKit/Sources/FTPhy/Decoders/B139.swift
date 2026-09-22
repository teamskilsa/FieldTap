// 0xB139 LTE LL1 PUSCH Tx Report, v162 (0xA2). Header and record words follow the MobileInsight v145 order;
// the modulation and power bytes and the power scale were re-derived on the iPhone 17 capture (power calibrated
// against 442 TTI-matched power headroom reports).

/// One PUSCH transmission per record: resource blocks, TBS, code rate, modulation and required Tx power.
enum B139 {
    struct Transmission: Hashable {
        /// Serving-cell id from the header (9 bits).
        var pci: Int
        var tti: Int
        var carrier: Int
        var retxIndex: Int
        var startRb: Int
        var nRb: Int
        var tbsBytes: Int
        /// Code rate x1024 over 1024.
        var codeRate: Double
        /// 1 QPSK, 2 16QAM, 3 64QAM, 4 256QAM.
        var modulation: Int
        /// Required PUSCH power in 0.25 dB units, before Pcmax capping.
        var powerRaw: Int

        /// Modulation order Qm, or nil for a code outside 1-4.
        var qm: Int? { [1: 2, 2: 4, 3: 6, 4: 8][modulation] }

        /// dBm = raw / 4 - 1.5: 0.25 dB steps (slope 4.0 per dB against 10log10(nRB)); the -1.5 dB offset comes
        /// from the PHRs and assumes Pcmax,c = 23 dBm, so the absolute value is good to about 1.5 dB.
        var requiredPowerDbm: Double { Double(powerRaw) / 4 - 1.5 }
    }

    static let version = 162
    static let recordBytes = 100

    /// 8-byte header: version, u16 serving cell 9b | record count 5b, u8, u16 dispatch SFN, 2 reserved. Records:
    /// u32 @0 = TTI (low 16) | flags (carrier 2b, ACK, CQI, RI, hopping 2b, retx index 5b, RV 2b); u32 @4 = RA
    /// type 1b, start RB 7b, ..., nRB 7b @15; u16 TBS bytes @8; u16 code rate @10; byte @36 bits 2-4 modulation;
    /// byte @46 required power.
    static func decode(_ b: [UInt8]) -> Decoded<[Transmission]> {
        guard b.has(0, 3) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB139 v\(b[0])") }
        let w = b.u16(1), pci = w & 511, n = (w >> 9) & 31
        var out: [Transmission] = []
        for k in 0..<n {
            let r = 8 + recordBytes * k
            guard b.has(r, recordBytes) else { break }
            let w0 = b.u32(r), w1 = b.u32(r + 4)
            let flags = Int(w0 >> 16)
            out.append(Transmission(pci: pci, tti: Int(w0 & 0xFFFF), carrier: flags & 3, retxIndex: (flags >> 7) & 31,
                                    startRb: w1.bits(1, 7), nRb: w1.bits(15, 7), tbsBytes: b.u16(r + 8),
                                    codeRate: Double(b.u16(r + 10)) / 1024, modulation: (b.u8(r + 36) >> 2) & 7,
                                    powerRaw: b.u8(r + 46)))
        }
        return .value(out)
    }
}
