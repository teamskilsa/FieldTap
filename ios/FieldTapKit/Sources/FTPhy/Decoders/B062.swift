// 0xB062 LTE MAC RACH Attempt, packet v1 with subpacket 0x06 v50: the SCAT v50 field order (facts only),
// validated on the iPhone 17 capture (UL EARFCNs of the target cells; preamble target power = SIB2's).

/// One random-access attempt: the preamble, its target power and the timing advance of the response.
enum B062 {
    struct Attempt: Hashable {
        var cell: Int
        var attempts: Int
        var result: Int
        var contention: Int
        var preamble: Int
        var preambleTargetDbm: Int
        /// The RAR's timing advance, when the message bitmask says Msg2 was received.
        var taRar: Int?
        var ulEarfcn: Int64
    }

    static let version = 1
    static let subpacketId = 0x06
    static let subpacketVersion = 50
    static let minBody = 41

    /// 4-byte packet header; subpackets of (id, version, u16 size excluding this header). Subpacket 0x06: u8
    /// id, cell, attempts, result, contention, message bitmask @0-5; Msg1 @6: u8 preamble, u8 mask, s16 target
    /// power; Msg2 @13: u16 backoff, u8 result, u16 TC-RNTI, u16 TA @18; u32 UL EARFCN @37.
    static func decode(_ b: [UInt8]) -> Decoded<[Attempt]> {
        guard b.has(0, 2) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB062 v\(b[0])") }
        var out: [Attempt] = []
        var pos = 4
        for _ in 0..<Int(b[1]) {
            guard b.has(pos, 4) else { return .malformed }
            let id = b.u8(pos), ver = b.u8(pos + 1), size = b.u16(pos + 2)
            let body = pos + 4
            pos = body + size
            guard id == subpacketId else { continue }
            guard ver == subpacketVersion else { return .versionMiss("0xB062 v1/0x06 v\(ver)") }
            guard size >= minBody, b.has(body, minBody) else { return .malformed }
            let mask = b.u8(body + 5)
            out.append(Attempt(cell: b.u8(body + 1), attempts: b.u8(body + 2), result: b.u8(body + 3),
                               contention: b.u8(body + 4), preamble: b.u8(body + 6), preambleTargetDbm: b.i16(body + 8),
                               taRar: mask & 2 != 0 ? b.u16(body + 18) : nil, ulEarfcn: Int64(b.u32(body + 37))))
        }
        return .value(out)
    }
}
