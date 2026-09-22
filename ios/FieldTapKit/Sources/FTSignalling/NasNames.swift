// Port of android/diag/src/main/kotlin/com/fieldtap/diag/NasNames.kt (contract v1: unchanged from repo main).
// The tables are copied entry for entry from the Kotlin; add to both together.

/// The names 3GPP gives NAS message types and causes.
///
/// Message names and directions are the same table as `fieldtap/decode/msgnames.py`, so a session reads the
/// same on the handset as in the report. The cause is the single most useful thing on the screen when a phone
/// will not attach, so it is named here rather than left to Wireshark.
///
/// References: EMM and ESM causes are the EMM and ESM cause IEs of TS 24.301; 5GMM and 5GSM causes those of
/// TS 24.501.
public enum NasNames {
    private struct Key: Hashable {
        var sublayer: String
        var type: Int
    }

    private struct Entry {
        var name: String
        var direction: String?
    }

    private static let MESSAGES: [Key: Entry] = {
        var m: [Key: Entry] = [:]
        func put(_ layer: String, _ type: Int, _ name: String, _ direction: String?) {
            m[Key(sublayer: layer, type: type)] = Entry(name: name, direction: direction)
        }
        // EPS mobility management
        put("emm", 0x41, "Attach request", "ul")
        put("emm", 0x42, "Attach accept", "dl")
        put("emm", 0x43, "Attach complete", "ul")
        put("emm", 0x44, "Attach reject", "dl")
        put("emm", 0x45, "Detach request", nil)
        put("emm", 0x46, "Detach accept", nil)
        put("emm", 0x48, "Tracking area update request", "ul")
        put("emm", 0x49, "Tracking area update accept", "dl")
        put("emm", 0x4A, "Tracking area update complete", "ul")
        put("emm", 0x4B, "Tracking area update reject", "dl")
        put("emm", 0x4C, "Extended service request", "ul")
        put("emm", 0x4D, "Control plane service request", "ul")
        put("emm", 0x4E, "Service reject", "dl")
        put("emm", 0x4F, "Service accept", "dl")
        put("emm", 0x50, "GUTI reallocation command", "dl")
        put("emm", 0x51, "GUTI reallocation complete", "ul")
        put("emm", 0x52, "Authentication request", "dl")
        put("emm", 0x53, "Authentication response", "ul")
        put("emm", 0x54, "Authentication reject", "dl")
        put("emm", 0x55, "Identity request", "dl")
        put("emm", 0x56, "Identity response", "ul")
        put("emm", 0x5C, "Authentication failure", "ul")
        put("emm", 0x5D, "Security mode command", "dl")
        put("emm", 0x5E, "Security mode complete", "ul")
        put("emm", 0x5F, "Security mode reject", "ul")
        put("emm", 0x60, "EMM status", nil)
        put("emm", 0x61, "EMM information", "dl")
        put("emm", 0x62, "Downlink NAS transport", "dl")
        put("emm", 0x63, "Uplink NAS transport", "ul")
        put("emm", 0x64, "CS service notification", "dl")
        put("emm", 0x68, "Downlink generic NAS transport", "dl")
        put("emm", 0x69, "Uplink generic NAS transport", "ul")
        // EPS session management
        put("esm", 0xC1, "Activate default EPS bearer context request", "dl")
        put("esm", 0xC2, "Activate default EPS bearer context accept", "ul")
        put("esm", 0xC3, "Activate default EPS bearer context reject", "ul")
        put("esm", 0xC5, "Activate dedicated EPS bearer context request", "dl")
        put("esm", 0xC6, "Activate dedicated EPS bearer context accept", "ul")
        put("esm", 0xC7, "Activate dedicated EPS bearer context reject", "ul")
        put("esm", 0xC9, "Modify EPS bearer context request", "dl")
        put("esm", 0xCA, "Modify EPS bearer context accept", "ul")
        put("esm", 0xCB, "Modify EPS bearer context reject", "ul")
        put("esm", 0xCD, "Deactivate EPS bearer context request", "dl")
        put("esm", 0xCE, "Deactivate EPS bearer context accept", "ul")
        put("esm", 0xD0, "PDN connectivity request", "ul")
        put("esm", 0xD1, "PDN connectivity reject", "dl")
        put("esm", 0xD2, "PDN disconnect request", "ul")
        put("esm", 0xD3, "PDN disconnect reject", "dl")
        put("esm", 0xD4, "Bearer resource allocation request", "ul")
        put("esm", 0xD5, "Bearer resource allocation reject", "dl")
        put("esm", 0xD6, "Bearer resource modification request", "ul")
        put("esm", 0xD7, "Bearer resource modification reject", "dl")
        put("esm", 0xD9, "ESM information request", "dl")
        put("esm", 0xDA, "ESM information response", "ul")
        put("esm", 0xDB, "ESM notification", "dl")
        put("esm", 0xE8, "ESM status", nil)
        // 5GS mobility management
        put("5gmm", 0x41, "Registration request", "ul")
        put("5gmm", 0x42, "Registration accept", "dl")
        put("5gmm", 0x43, "Registration complete", "ul")
        put("5gmm", 0x44, "Registration reject", "dl")
        put("5gmm", 0x45, "Deregistration request (UE originating)", "ul")
        put("5gmm", 0x46, "Deregistration accept (UE originating)", "dl")
        put("5gmm", 0x47, "Deregistration request (UE terminated)", "dl")
        put("5gmm", 0x48, "Deregistration accept (UE terminated)", "ul")
        put("5gmm", 0x4C, "Service request", "ul")
        put("5gmm", 0x4D, "Service reject", "dl")
        put("5gmm", 0x4E, "Service accept", "dl")
        put("5gmm", 0x4F, "Control plane service request", "ul")
        put("5gmm", 0x54, "Configuration update command", "dl")
        put("5gmm", 0x55, "Configuration update complete", "ul")
        put("5gmm", 0x56, "Authentication request", "dl")
        put("5gmm", 0x57, "Authentication response", "ul")
        put("5gmm", 0x58, "Authentication reject", "dl")
        put("5gmm", 0x59, "Authentication failure", "ul")
        put("5gmm", 0x5A, "Authentication result", "dl")
        put("5gmm", 0x5B, "Identity request", "dl")
        put("5gmm", 0x5C, "Identity response", "ul")
        put("5gmm", 0x5D, "Security mode command", "dl")
        put("5gmm", 0x5E, "Security mode complete", "ul")
        put("5gmm", 0x5F, "Security mode reject", "ul")
        put("5gmm", 0x64, "5GMM status", nil)
        put("5gmm", 0x65, "Notification", "dl")
        put("5gmm", 0x66, "Notification response", "ul")
        put("5gmm", 0x67, "UL NAS transport", "ul")
        put("5gmm", 0x68, "DL NAS transport", "dl")
        // 5GS session management
        put("5gsm", 0xC1, "PDU session establishment request", "ul")
        put("5gsm", 0xC2, "PDU session establishment accept", "dl")
        put("5gsm", 0xC3, "PDU session establishment reject", "dl")
        put("5gsm", 0xC5, "PDU session authentication command", "dl")
        put("5gsm", 0xC9, "PDU session modification request", "ul")
        put("5gsm", 0xCA, "PDU session modification reject", "dl")
        put("5gsm", 0xD1, "PDU session release request", "ul")
        put("5gsm", 0xD3, "PDU session release command", "dl")
        put("5gsm", 0xD6, "5GSM status", nil)
        return m
    }()

    /// TS 24.301, EMM cause.
    private static let EMM_CAUSES: [Int: String] = [
        2: "IMSI unknown in HSS",
        3: "Illegal UE",
        5: "IMEI not accepted",
        6: "Illegal ME",
        7: "EPS services not allowed",
        8: "EPS services and non-EPS services not allowed",
        9: "UE identity cannot be derived by the network",
        10: "Implicitly detached",
        11: "PLMN not allowed",
        12: "Tracking area not allowed",
        13: "Roaming not allowed in this tracking area",
        14: "EPS services not allowed in this PLMN",
        15: "No suitable cells in tracking area",
        16: "MSC temporarily not reachable",
        17: "Network failure",
        18: "CS domain not available",
        19: "ESM failure",
        20: "MAC failure",
        21: "Synch failure",
        22: "Congestion",
        23: "UE security capabilities mismatch",
        24: "Security mode rejected, unspecified",
        25: "Not authorized for this CSG",
        26: "Non-EPS authentication unacceptable",
        35: "Requested service option not authorized in this PLMN",
        39: "CS service temporarily not available",
        40: "No EPS bearer context activated",
        42: "Severe network failure",
        95: "Semantically incorrect message",
        96: "Invalid mandatory information",
        97: "Message type non-existent or not implemented",
        98: "Message type not compatible with the protocol state",
        99: "Information element non-existent or not implemented",
        100: "Conditional IE error",
        101: "Message not compatible with the protocol state",
        111: "Protocol error, unspecified",
    ]

    /// TS 24.501, 5GMM cause.
    private static let FIVE_GMM_CAUSES: [Int: String] = [
        3: "Illegal UE",
        5: "PEI not accepted",
        6: "Illegal ME",
        7: "5GS services not allowed",
        9: "UE identity cannot be derived by the network",
        10: "Implicitly de-registered",
        11: "PLMN not allowed",
        12: "Tracking area not allowed",
        13: "Roaming not allowed in this tracking area",
        15: "No suitable cells in tracking area",
        20: "MAC failure",
        21: "Synch failure",
        22: "Congestion",
        23: "UE security capabilities mismatch",
        24: "Security mode rejected, unspecified",
        26: "Non-5G authentication unacceptable",
        27: "N1 mode not allowed",
        28: "Restricted service area",
        43: "LADN not available",
        65: "Maximum number of PDU sessions reached",
        67: "Insufficient resources for specific slice and DNN",
        69: "Insufficient resources for specific slice",
        71: "ngKSI already in use",
        72: "Non-3GPP access to 5GCN not allowed",
        73: "Serving network not authorized",
        74: "Temporarily not authorized for this SNPN",
        75: "Permanently not authorized for this SNPN",
        76: "Not authorized for this CAG or authorized for CAG cells only",
        77: "Wireline access area not allowed",
        90: "Payload was not forwarded",
        91: "DNN not supported or not subscribed in the slice",
        92: "Insufficient user-plane resources for the PDU session",
        95: "Semantically incorrect message",
        96: "Invalid mandatory information",
        97: "Message type non-existent or not implemented",
        98: "Message type not compatible with the protocol state",
        99: "Information element non-existent or not implemented",
        100: "Conditional IE error",
        101: "Message not compatible with the protocol state",
        111: "Protocol error, unspecified",
    ]

    /// TS 24.301, ESM cause.
    private static let ESM_CAUSES: [Int: String] = [
        8: "Operator determined barring",
        26: "Insufficient resources",
        27: "Missing or unknown APN",
        28: "Unknown PDN type",
        29: "User authentication failed",
        30: "Request rejected by Serving GW or PDN GW",
        31: "Request rejected, unspecified",
        32: "Service option not supported",
        33: "Requested service option not subscribed",
        34: "Service option temporarily out of order",
        35: "PTI already in use",
        36: "Regular deactivation",
        37: "EPS QoS not accepted",
        38: "Network failure",
        39: "Reactivation requested",
        50: "PDN type IPv4 only allowed",
        51: "PDN type IPv6 only allowed",
        54: "PDN connection does not exist",
        55: "Multiple PDN connections for a given APN not allowed",
        65: "Maximum number of EPS bearers reached",
    ]

    /// TS 24.501, 5GSM cause.
    private static let FIVE_GSM_CAUSES: [Int: String] = [
        8: "Operator determined barring",
        26: "Insufficient resources",
        27: "Missing or unknown DNN",
        28: "Unknown PDU session type",
        29: "User authentication or authorization failed",
        31: "Request rejected, unspecified",
        32: "Service option not supported",
        33: "Requested service option not subscribed",
        36: "Regular deactivation",
        38: "Network failure",
        39: "Reactivation requested",
        50: "PDU session type IPv4 only allowed",
        51: "PDU session type IPv6 only allowed",
        54: "PDU session does not exist",
        67: "Insufficient resources for specific slice and DNN",
        69: "Insufficient resources for specific slice",
    ]

    /// The message name and its direction ("ul"/"dl"), or nils when the type is unknown.
    public static func message(sublayer: String, messageType: Int?) -> (name: String?, direction: String?) {
        guard let messageType, let entry = MESSAGES[Key(sublayer: sublayer, type: messageType)] else { return (nil, nil) }
        return (entry.name, entry.direction)
    }

    /// The 3GPP name of a cause within its sublayer, or nil when it is not one we name.
    public static func cause(sublayer: String, value: Int) -> String? {
        switch sublayer {
        case "emm": EMM_CAUSES[value]
        case "esm": ESM_CAUSES[value]
        case "5gmm": FIVE_GMM_CAUSES[value]
        case "5gsm": FIVE_GSM_CAUSES[value]
        default: nil
        }
    }
}
