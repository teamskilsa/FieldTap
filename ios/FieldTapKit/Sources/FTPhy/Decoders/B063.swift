// 0xB063 LTE MAC DL Transport Block, packet v50 (0x32) on this modem. The published (SCAT/MobileInsight) v49/v50
// layout does not fit: its header and its per-transport-block header both sit 8 bytes earlier than what v50 emits
// here, and its 3-byte SDU descriptor has a different bit order. Both were re-derived and each field checked
// (docs/research/iphone-named-log-codes.md).
//
// Validated: every transport block the walk finds is a 0xB173 transport block on (SFN, subframe, carrier, HARQ,
// size) in 968 of 978 (99.0%) and 2,518 of 2,521 (99.9%) — four independent fields right at once. The descriptor
// bit order is confirmed by 3GPP's own fixed control-element sizes (LCID 28 with length 6 is the UE Contention
// Resolution Identity, LCID 27 with length 1 is Activation/Deactivation). The walk over the PDCP tail is the weak
// point: it lands on the last byte of the body in 65% / 56% of records and reaches 80% / 82% of the declared
// transport blocks, which is why the app shows MAC bytes with their coverage and keeps 0xB173 as the throughput
// source.
//
// This code does NOT give continuous timing advance: it logs a control element's LCID and length, not its body,
// so the timing-advance command (LCID 29) carries no value — and it appears twice in 22 s of driving.

/// The downlink transport blocks the MAC received: their size, padding, the SDUs inside them and which LCIDs
/// those were on.
enum B063 {
    struct Sdu: Hashable {
        /// True for a MAC control element, false for a data SDU.
        var control: Bool
        /// TS 36.321 tables 6.2.1-1 / 6.2.1-2.
        var lcid: Int
        var lengthBytes: Int
    }

    struct TransportBlock: Hashable {
        var sizeBytes: Int
        var paddingBytes: Int
        var sfn: Int
        var subframe: Int
        var carrier: Int
        var harq: Int
        /// The logged MAC header length; low confidence (the size identity is off by one byte in half the
        /// single-block records), so the app uses `sizeBytes` and the SDU lengths.
        var headerBytes: Int
        var sdus: [Sdu]

        var tti: Int { sfn * 10 + subframe }
        /// Bytes on LCID 0-2: CCCH and the two default DCCHs, i.e. signalling.
        var signallingBytes: Int { sdus.filter { !$0.control && $0.lcid <= 2 }.reduce(0) { $0 + $1.lengthBytes } }
        /// Bytes on LCID 3 and up: user data.
        var dataBytes: Int { sdus.filter { !$0.control && $0.lcid > 2 }.reduce(0) { $0 + $1.lengthBytes } }
        /// TS 36.321 6.1.3.5: the command is logged, its 6-bit value is not in the record.
        var hasTimingAdvanceCommand: Bool { sdus.contains { $0.control && $0.lcid == timingAdvanceLcid } }
    }

    /// What the walk managed: the app reports this as coverage rather than gating on it.
    struct Walk: Hashable {
        var declared: Int
        var found: Int
        /// True when the last transport block ended exactly on the body's last byte.
        var exact: Bool
        var resynced: Int
    }

    static let version = 0x32
    static let headerBytes = 8
    static let blockHeaderBytes = 16
    static let descriptorBytes = 12
    static let timingAdvanceLcid = 29
    /// The largest LTE transport block (75,376 bits), which bounds a self-consistent header.
    static let maxTransportBlockBytes = 9_422

    /// u32 transport-block count @4; then per block u32 size @0, u32 padding @4, u32 SFN (bits 0-9) and subframe
    /// (bits 10-13) @8, u8 HARQ (bits 4-7) and carrier (bits 0-3) @12, u8 SDU count @13, u16 MAC header length
    /// @14; then one 12-byte descriptor per SDU whose first 3 bytes are a little-endian 24-bit word (bit 0 control
    /// flag, bits 1-6 LCID, bits 7-22 length) and, for a data SDU, a PDCP tail of 8 x descriptor byte 9 bytes.
    static func decode(_ b: [UInt8]) -> Decoded<(blocks: [TransportBlock], walk: Walk)> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB063 v\(b[0])") }
        guard b.has(0, headerBytes) else { return .malformed }
        let declared = Int(b.u32(4))
        var out: [TransportBlock] = []
        var pos = headerBytes
        var resynced = 0
        while out.count < declared {
            guard var tb = blockHeader(b, pos) else {
                // The tail rule missed: look for the next self-consistent header, near in frame number.
                guard let next = resync(b, from: pos, after: out.last) else { break }
                resynced += 1
                pos = next
                continue
            }
            let start = pos + blockHeaderBytes
            tb.sdus = descriptors(b, start, tb.sdus.count)
            var tail = 0
            for i in 0..<tb.sdus.count where b.has(start + descriptorBytes * i, descriptorBytes) {
                tail += 8 * b.u8(start + descriptorBytes * i + 9)
            }
            out.append(tb)
            pos = start + descriptorBytes * tb.sdus.count + tail
        }
        let walk = Walk(declared: declared, found: out.count, exact: pos == b.count && out.count == declared,
                        resynced: resynced)
        return .value((out, walk))
    }

    /// A transport-block header at `o`, or nil when it is not self-consistent: an SDU count of 1-8, a MAC header
    /// of at most 4 bytes per SDU plus 4, and a size that is a possible LTE transport block with less padding
    /// than its own size. `sdus` comes back holding one placeholder per declared SDU.
    static func blockHeader(_ b: [UInt8], _ o: Int) -> TransportBlock? {
        guard b.has(o, blockHeaderBytes) else { return nil }
        let size = Int(b.u32(o)), padding = Int(b.u32(o + 4)), w = b.u32(o + 8)
        let cch = b.u8(o + 12), nSdu = b.u8(o + 13), headerLength = b.u16(o + 14)
        guard (1...8).contains(nSdu), headerLength <= 4 * nSdu + 4, size > 0, size <= maxTransportBlockBytes,
              padding <= size else { return nil }
        return TransportBlock(sizeBytes: size, paddingBytes: padding, sfn: w.bits(0, 10), subframe: w.bits(10, 4),
                              carrier: cch & 15, harq: (cch >> 4) & 15, headerBytes: headerLength,
                              sdus: Array(repeating: Sdu(control: false, lcid: 0, lengthBytes: 0), count: nSdu))
    }

    static func descriptors(_ b: [UInt8], _ o: Int, _ count: Int) -> [Sdu] {
        var out: [Sdu] = []
        for i in 0..<count {
            let p = o + descriptorBytes * i
            guard b.has(p, 3) else { break }
            let v = UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16
            out.append(Sdu(control: v & 1 == 1, lcid: v.bits(1, 6), lengthBytes: v.bits(7, 16)))
        }
        return out
    }

    /// The next self-consistent header at or after `from`, on a 4-byte grid, within two frames of the last block.
    static func resync(_ b: [UInt8], from: Int, after last: TransportBlock?) -> Int? {
        guard from >= 0, b.count > blockHeaderBytes else { return nil }
        var q = from
        while q + blockHeaderBytes <= b.count {
            if let cand = blockHeader(b, q) {
                if let last {
                    if (cand.sfn - last.sfn + 1_024) % 1_024 <= 2 { return q }
                } else {
                    return q
                }
            }
            q += 4
        }
        return nil
    }
}
