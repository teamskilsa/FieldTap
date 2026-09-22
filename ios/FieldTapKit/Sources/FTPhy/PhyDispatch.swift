// The strict version table: every PHY decoder accepts only the record versions validated on this modem (iPhone
// 17, Qualcomm M25, baseband 1.60.02). Anything else is counted in PhyCapture.versionMisses and shown as "not
// decodable (version N)", never guessed at. A new iPhone model or baseband gets its own fixture set first.

enum PhyDispatch {
    /// Code -> the version the decoder accepts, as the Radio page and the version-miss keys spell it.
    static let validated: [UInt16: String] = [
        0xB0C1: "v2",
        0xB0C2: "v3",
        0xB193: "v1/0x19 v66",
        0xB173: "v50",
        0xB139: "v162",
        0xB14E: "v164",
        0xB14D: "v164",
        0xB064: "v1/0x08 v7",
        0xB062: "v1/0x06 v50",
        0xB97F: "3.0",
        0xB887: "3.13",
        0xB888: "3.1",
        0xB126: "v163",
        0xB12A: "v161",
        0xB16C: "v50",
        0xB179: "v56",
        0xB063: "v50",
        0x184C: "v17",
        0x1D0B: "v7",
    ]

    /// The codes FTPhy decodes, in the order it decodes them. The order matters: 0xB0C1 and 0xB193 give the cells
    /// the later codes are attributed to, and 0xB173 and 0xB139 are what 0xB126, 0xB16C, 0xB063 and 0xB179 are
    /// checked against, so they are decoded first.
    static let codes: [UInt16] = [0xB0C1, 0xB0C2, 0xB193, 0xB173, 0xB139, 0xB14E, 0xB14D, 0xB064, 0xB062, 0xB97F,
                                  0xB887, 0xB888, 0xB126, 0xB12A, 0xB16C, 0xB179, 0xB063, 0x184C, 0x1D0B]

    /// 0xB179 carries no DIAG timestamp: it is placed by its own in-record TTI (PhyTtiAxis), not by the transport.
    static let unstampedCodes: Set<UInt16> = [0xB179]

    static func version(of code: UInt16) -> String { validated[code] ?? "" }
}
