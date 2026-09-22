/// How many records the modem wrote encrypted (the QDSS "secure" packets): counted, never decoded.
///
/// Shared by the PHY summary (WP4), the import summary (WP3) and the journey findings (WP5), so it lives in a
/// WP0 file and does not change shape.
public struct EncryptedCensus: Hashable, Codable, Sendable {
    public var records: Int
    public var codes: Int
    /// Records per log code ("0xB8DD" -> 412), when the importer kept the breakdown.
    public var byCode: [String: Int]?

    public init(records: Int, codes: Int, byCode: [String: Int]? = nil) {
        self.records = records
        self.codes = codes
        self.byCode = byCode
    }

    public static let empty = EncryptedCensus(records: 0, codes: 0)
}
