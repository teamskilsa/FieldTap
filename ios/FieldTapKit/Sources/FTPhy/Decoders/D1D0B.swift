// 0x1D0B — a 100 Hz modem sampler, version 7, no public name. What it samples every 2 ms was not identified and is
// deliberately not read; its two clocks were, and they are what the app uses
// (docs/research/iphone-unknown-log-codes.md).
//
// Validated on both captures: the u32 at +8 advances at a median 19,200,006 counts per second — the 19.2 MHz TCXO
// to seven figures; the u32 at +4 advances at 1023.8 ... 1023.9 counts per second over gap-free stretches, i.e. the
// 32.768 kHz sleep clock divided by 32; the u32 at +84 is a sequence number whose consecutive deltas are exactly
// +1 in 1,902 of 1,907 (and 2,237 of 2,237 on the other capture). The body is 370 bytes = 90 + 5 x 56.
//
// What that buys: the 1024 Hz counter measures wall time the trace does not contain. Across the detach in the
// driving capture the record rate falls from 100/s to 14/s and the counter steps by 2,280, 1,154, 991 and 620
// counts — 2.23 s, 1.13 s, 0.97 s and 0.61 s of trace that was never written. That turns "messages around the gaps
// may be incomplete" into seconds, in the right places.

/// The modem's own clocks, once per 10 ms: enough to say exactly how much trace is missing.
enum D1D0B {
    struct Sample: Hashable {
        /// The 1024 Hz sleep-clock stamp: 1,024 counts is one second of wall time.
        var sleepCounts: UInt32
        /// The 19.2 MHz TCXO stamp, 24 bits (it wraps every 0.874 s).
        var tcxoTicks: UInt32
        /// A sequence number that steps by 1 per record.
        var sequence: UInt32
    }

    static let version = 7
    static let headerBytes = 90
    static let entryBytes = 56
    static let entries = 5
    static let bodyBytes = headerBytes + entryBytes * entries
    /// Counts per second of the sleep clock (32.768 kHz / 32).
    static let sleepClockHz = 1_024.0
    /// Ticks per second of the TCXO.
    static let tcxoHz = 19_200_000.0

    /// u32 version @0 (7), u32 1024 Hz stamp @4, u32 19.2 MHz stamp @8 (24 bits), u32 sequence @84. The five 56-byte
    /// entries at +90 are not read: what they sample was not identified.
    static func decode(_ b: [UInt8]) -> Decoded<Sample> {
        guard b.has(0, 4) else { return .malformed }
        guard b.u32(0) == UInt32(version) else { return .versionMiss("0x1D0B v\(b.u32(0))") }
        guard b.has(0, headerBytes) else { return .malformed }
        return .value(Sample(sleepCounts: b.u32(4), tcxoTicks: b.u32(8) & 0xFF_FFFF, sequence: b.u32(84)))
    }
}
