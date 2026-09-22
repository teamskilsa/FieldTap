// Port of LogRecord in android/diag/src/main/kotlin/com/fieldtap/diag/Protocol.kt.

/// One decoded DIAG log packet header and its body.
public struct LogRecord: Hashable, Codable, Sendable {
    /// The 16-bit log code, e.g. 0xB0C0 for LTE RRC OTA.
    public var code: UInt16
    /// The modem's own timestamp, in its raw 64-bit form (see `TimeBase.modemMs`).
    public var timestampRaw: UInt64
    public var body: [UInt8]
    /// Non-zero when the modem split one logical record across packets.
    public var more: UInt8

    public init(code: UInt16, timestampRaw: UInt64, body: [UInt8], more: UInt8 = 0) {
        self.code = code
        self.timestampRaw = timestampRaw
        self.body = body
        self.more = more
    }

    /// The top nibble of the log code: which subsystem emitted it.
    public var equipId: Int { Int(code >> 12) & 0xF }
}
