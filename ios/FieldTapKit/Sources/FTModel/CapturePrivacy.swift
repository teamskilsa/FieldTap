// The log codes FieldTap drops before a capture is written to disk, so they cannot reach anything the user
// exports or shares. Owned by WP4-phy alongside the PHY decoders that could otherwise read them.
//
// The modem writes a GNSS position report at 5 Hz (0x1476 is publicly named "GNSS Position Report"; capture 2
// holds 105 of them across a 22 s drive). A position track is more identifying than the IMSI, and the two QMI
// links in the same family carry whatever the modem's control plane was passing at the time, so none of them is
// decoded, stored or exported. They are counted, by code, and the count is what the app shows.
//
// This is a hard rule, not a setting: there is no "reveal" for it, the way there is for a masked identifier.

public enum CapturePrivacy: Sendable {
    /// Location and QMI-link records: never written to a capture file, never decoded, never in an export.
    ///
    /// 0x1476 GNSS Position Report, 0x147C-0x147E the rest of that position block, 0x1391 QMI Link 2 TX Message
    /// and 0x1544 QMI_MCS_QCSI_PKT (see docs/research/iphone-unknown-log-codes.md, "0x1476 is location").
    public static let excludedCodes: Set<UInt16> = [0x1476, 0x147C, 0x147D, 0x147E, 0x1391, 0x1544]

    /// The excluded codes in order, for the UI and the tests.
    public static let excludedCodeList: [UInt16] = excludedCodes.sorted()

    /// One line for the UI, listing the codes it drops.
    public static let statement =
        "Location stays on the phone. FieldTap drops the modem's position records (GNSS position reports and the "
        + "QMI links that carry them) when it saves a capture, so they are in nothing you copy, share or export. "
        + "They are counted and never decoded."

    public static func isExcluded(_ code: UInt16) -> Bool { excludedCodes.contains(code) }

    /// `records` without any excluded code, and how many of each code was dropped. Every path that writes or
    /// shares records goes through this, and `CaptureStore.save` is the one that does it for the capture file.
    public static func filter(_ records: [LogRecord]) -> (kept: [LogRecord], dropped: [UInt16: Int]) {
        var dropped: [UInt16: Int] = [:]
        var kept: [LogRecord] = []
        kept.reserveCapacity(records.count)
        for r in records {
            if isExcluded(r.code) {
                dropped[r.code, default: 0] += 1
            } else {
                kept.append(r)
            }
        }
        return (kept, dropped)
    }
}
