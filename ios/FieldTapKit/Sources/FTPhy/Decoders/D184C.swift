// 0x184C "LTE RF FED Tx AGC", version 0x11 (17) on this modem. FED is the front-end driver. Public name from the
// QXDM release notes; the layout was derived on the two iPhone 17 captures
// (docs/research/iphone-unknown-log-codes.md).
//
// A record is one or more blocks; a block is a 16-byte header plus one to three 120-byte sub-records, one per
// transmit chain. `len(body) == 16N + 120M` fits all eight observed lengths, and a walk that finds block headers
// by their signature (version byte 0x11 then five zero bytes at +2) consumes the body exactly on 2,391 of 2,393
// records (99.92%) and 4,464 of 4,465 (99.98%). The subframe counter in the block header steps by exactly 1
// between consecutive blocks, so a record's blocks are consecutive subframes.
//
// Fields, all correlated against the PUSCH transmit power FieldTap already derives from 0xB139 (binned at 50 ms,
// n = 2,391): the amplifier gain state at +1 (r = -0.80: a lower state means more power), the transmit power at +4
// in 0.1 dBm (range -70.0 ... +25.0 dBm, where -70.0 dBm is the "chain off" sentinel), a second power measure at
// +6, and a per-chain limit at +66/+68/+70 in 0.1 dBm (17.7 ... 25.0 dBm, r = -0.73 ... -0.75). A best fit of the
// strongest field leaves a 3.8 dB residual against the PUSCH target, which is the point: this is the front-end
// chain's own power at its own instants, a different and more physical quantity. It is labelled "front-end Tx
// power (chain N)" in the app, never "the phone's transmit power", until a second device confirms the scale.

/// The front end's own transmit power, its limit and the amplifier state, per chain and per subframe: which chain
/// is live, and whether the phone is transmit-limited.
enum D184C {
    struct SubRecord: Hashable {
        /// Chain tag as the record writes it (0x10, 0x11, 0x20, 0x21, 0x22 ...): the high nibble is the group.
        var chain: Int
        /// AGC / power-amplifier gain state.
        var gainState: Int
        /// Front-end transmit power in dBm, or nil for a chain that was off (the -70.0 dBm sentinel).
        var txPowerDbm: Double?
        /// The record's second power measure, 0.1 dBm; kept for the tests, not shown.
        var secondPowerDbm: Double
        /// The binding per-chain limit in dBm: the smallest of the three the record carries (they are equal in the
        /// large majority of sub-records). Nil when the record leaves them at zero, which is not a 0 dBm limit.
        var limitDbm: Double?
        /// How far below its limit this chain was; at or below zero the chain is transmit-limited.
        var headroomDb: Double? {
            guard let limitDbm, let txPowerDbm else { return nil }
            return limitDbm - txPowerDbm
        }
    }

    struct Block: Hashable {
        /// The block header's subframe counter; consecutive blocks are consecutive subframes.
        var subframe: Int
        var subRecords: [SubRecord]
    }

    static let version = 0x11
    static let blockHeaderBytes = 16
    static let subRecordBytes = 120
    /// The value at +4 that marks a chain that was not transmitting.
    static let chainOffDbm = -70.0

    /// The walk: a block header at `o`, recognised by the version byte and the five zero bytes at +2.
    static func isBlockHeader(_ b: [UInt8], _ o: Int) -> Bool {
        guard b.has(o, blockHeaderBytes), b[o] == version else { return false }
        return (o + 2..<o + 7).allSatisfy { b[$0] == 0 }
    }

    /// Blocks in order, and whether the walk ended exactly on the body's last byte (the runtime check).
    static func decode(_ b: [UInt8]) -> Decoded<(blocks: [Block], exact: Bool)> {
        guard b.has(0, 2) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0x184C v\(b[0])") }
        var out: [Block] = []
        var pos = 0
        while pos + blockHeaderBytes <= b.count {
            guard isBlockHeader(b, pos) else { break }
            let subframe = b.u16(pos + 7) >> 4
            pos += blockHeaderBytes
            var subs: [SubRecord] = []
            while pos + subRecordBytes <= b.count, !isBlockHeader(b, pos) {
                subs.append(subRecord(b, pos))
                pos += subRecordBytes
            }
            out.append(Block(subframe: subframe, subRecords: subs))
        }
        return .value((out, pos == b.count))
    }

    /// One 120-byte sub-record: u8 chain @0, u8 gain state @1, i16 Tx power @4 and a second measure @6 in 0.1 dBm,
    /// u16 limits @66/@68/@70 in 0.1 dBm. A limit of zero is an unset field, not a 0 dBm limit, so it is dropped:
    /// the validated range of the field is 17.7 to 25.0 dBm.
    static func subRecord(_ b: [UInt8], _ o: Int) -> SubRecord {
        let power = Double(b.i16(o + 4)) / 10
        let limit = [b.u16(o + 66), b.u16(o + 68), b.u16(o + 70)].min() ?? 0
        return SubRecord(chain: b.u8(o), gainState: b.u8(o + 1),
                         txPowerDbm: power <= chainOffDbm ? nil : power,
                         secondPowerDbm: Double(b.i16(o + 6)) / 10,
                         limitDbm: limit > 0 ? Double(limit) / 10 : nil)
    }
}
