// 0xB064 LTE MAC UL Transport Block, packet v1 with subpacket 0x08 v7 (this modem). Each sample header is the
// cell id followed by the SCAT v1 order (facts only), re-derived for v7, then the MAC PDU's header bytes, whose
// subheaders and control elements are parsed per TS 36.321 6.1.2 / 6.1.3.

/// One uplink MAC transport block: its grant and the MAC control elements it carried (the PHR among them).
enum B064 {
    struct Sample: Hashable {
        var carrier: Int
        var harq: Int
        var rntiType: Int
        var sfn: Int
        var subframe: Int
        var grantBytes: Int
        var paddingBytes: Int
        var headerLength: Int
        /// MAC control elements: (UL LCID, payload bytes).
        var controlElements: [ControlElement]
        /// The subheaders and CEs consumed exactly `headerLength` bytes: the layout check.
        var headerConsistent: Bool

        /// The power headroom level of the PHR CE (LCID 26): PH index - 23, the lower edge of the 1 dB bin (TS
        /// 36.133 9.1.8.4).
        var powerHeadroomDb: Int? {
            controlElements.first { $0.lcid == 26 && !$0.payload.isEmpty }.map { Int($0.payload[0] & 63) - 23 }
        }
    }

    struct ControlElement: Hashable {
        var lcid: Int
        var payload: [UInt8]
    }

    static let version = 1
    static let subpacketId = 0x08
    static let subpacketVersion = 7
    static let sampleHeaderBytes = 13

    /// 4-byte packet header; subpackets of (id, version, u16 size including this header); subpacket 0x08: u8
    /// sample count, then per sample u8 cell, u8 HARQ, u8 RNTI type, u16 SFN<<4|SF, u16 grant, u8 RLC PDUs, u16
    /// padding, u8 BSR event, u8 BSR trigger, u8 header length, and the header bytes.
    static func decode(_ b: [UInt8]) -> Decoded<[Sample]> {
        guard b.has(0, 2) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB064 v\(b[0])") }
        var out: [Sample] = []
        var pos = 4
        for _ in 0..<Int(b[1]) {
            guard b.has(pos, 4) else { return .malformed }
            let id = b.u8(pos), ver = b.u8(pos + 1), size = b.u16(pos + 2)
            guard size >= 4 else { return .malformed }
            let body = pos + 4, end = min(pos + size, b.count)
            pos += size
            guard id == subpacketId else { continue }
            guard ver == subpacketVersion else { return .versionMiss("0xB064 v1/0x08 v\(ver)") }
            guard body < end else { continue }
            var p = body + 1
            for _ in 0..<b.u8(body) {
                guard p + sampleHeaderBytes <= end else { break }
                let sfnWord = b.u16(p + 3), headerLength = b.u8(p + 12)
                let header = Array(b[(p + sampleHeaderBytes)..<min(p + sampleHeaderBytes + headerLength, end)])
                let (ces, used) = controlElements(header)
                out.append(Sample(carrier: b.u8(p), harq: b.u8(p + 1), rntiType: b.u8(p + 2), sfn: sfnWord >> 4,
                                  subframe: sfnWord & 15, grantBytes: b.u16(p + 5), paddingBytes: b.u16(p + 8),
                                  headerLength: headerLength, controlElements: ces, headerConsistent: used == headerLength))
                p += sampleHeaderBytes + headerLength
            }
        }
        return .value(out)
    }

    /// Fixed-size UL MAC CEs by LCID (TS 36.321 table 6.2.1-2): PHR, C-RNTI, truncated, short and long BSR.
    static let fixedCeBytes: [Int: Int] = [26: 1, 27: 2, 28: 1, 29: 1, 30: 3]

    /// Walks the subheaders (R/F2/E/LCID, then F/L for SDUs and the variable CEs) until E = 0, then the CEs in
    /// subheader order. Returns the CEs and the bytes consumed.
    static func controlElements(_ h: [UInt8]) -> ([ControlElement], Int) {
        var subheaders: [(lcid: Int, length: Int?)] = []
        var i = 0
        while i < h.count {
            let x = Int(h[i]), extends = (x >> 5) & 1 == 1, lcid = x & 31
            i += 1
            var length: Int?
            if (lcid <= 10 || lcid == 24 || lcid == 25) && extends {
                guard i < h.count else { break }
                if h[i] >> 7 == 1 {
                    guard i + 1 < h.count else { break }
                    length = Int(h[i] & 0x7F) << 8 | Int(h[i + 1])
                    i += 2
                } else {
                    length = Int(h[i] & 0x7F)
                    i += 1
                }
            }
            subheaders.append((lcid, length))
            if !extends { break }
        }
        var ces: [ControlElement] = []
        for s in subheaders {
            let n: Int?
            if let fixed = fixedCeBytes[s.lcid] { n = fixed } else if s.lcid == 24 || s.lcid == 25 { n = s.length } else { n = nil }
            guard let n else { continue }
            let lo = min(i, h.count), hi = min(i + n, h.count)
            ces.append(ControlElement(lcid: s.lcid, payload: Array(h[lo..<hi])))
            i += n
        }
        return (ces, i)
    }
}
