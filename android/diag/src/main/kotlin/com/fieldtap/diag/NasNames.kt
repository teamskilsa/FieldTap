package com.fieldtap.diag

/**
 * The names 3GPP gives NAS message types and causes.
 *
 * Message names and directions are the same table as `fieldtap/decode/msgnames.py`, so a session
 * reads the same on the handset as in the report. The cause names are new here: the desktop tool
 * leaves those to Wireshark, which is not available on a phone, and the cause is the single most
 * useful thing on the screen when a phone will not attach.
 *
 * References: EMM and ESM causes are TS 24.301 (9.9.3.9 and 9.9.4.4); 5GMM and 5GSM causes are
 * TS 24.501 (9.11.3.2 and 9.11.4.2).
 *
 * Owner: workstream `diag-on-handset`.
 */
object NasNames {

    private data class Entry(val name: String, val direction: String?)

    private val MESSAGES: Map<Pair<String, Int>, Entry> = buildMap {
        fun put(layer: String, type: Int, name: String, direction: String?) {
            put(layer to type, Entry(name, direction))
        }
        // EPS mobility management
        put("emm", 0x41, "Attach request", "ul"); put("emm", 0x42, "Attach accept", "dl")
        put("emm", 0x43, "Attach complete", "ul"); put("emm", 0x44, "Attach reject", "dl")
        put("emm", 0x45, "Detach request", null); put("emm", 0x46, "Detach accept", null)
        put("emm", 0x48, "Tracking area update request", "ul")
        put("emm", 0x49, "Tracking area update accept", "dl")
        put("emm", 0x4A, "Tracking area update complete", "ul")
        put("emm", 0x4B, "Tracking area update reject", "dl")
        put("emm", 0x4C, "Extended service request", "ul")
        put("emm", 0x4D, "Control plane service request", "ul")
        put("emm", 0x4E, "Service reject", "dl"); put("emm", 0x4F, "Service accept", "dl")
        put("emm", 0x50, "GUTI reallocation command", "dl")
        put("emm", 0x51, "GUTI reallocation complete", "ul")
        put("emm", 0x52, "Authentication request", "dl")
        put("emm", 0x53, "Authentication response", "ul")
        put("emm", 0x54, "Authentication reject", "dl"); put("emm", 0x55, "Identity request", "dl")
        put("emm", 0x56, "Identity response", "ul"); put("emm", 0x5C, "Authentication failure", "ul")
        put("emm", 0x5D, "Security mode command", "dl")
        put("emm", 0x5E, "Security mode complete", "ul")
        put("emm", 0x5F, "Security mode reject", "ul"); put("emm", 0x60, "EMM status", null)
        put("emm", 0x61, "EMM information", "dl"); put("emm", 0x62, "Downlink NAS transport", "dl")
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
        put("esm", 0xDB, "ESM notification", "dl"); put("esm", 0xE8, "ESM status", null)
        // 5GS mobility management
        put("5gmm", 0x41, "Registration request", "ul")
        put("5gmm", 0x42, "Registration accept", "dl")
        put("5gmm", 0x43, "Registration complete", "ul")
        put("5gmm", 0x44, "Registration reject", "dl")
        put("5gmm", 0x45, "Deregistration request (UE originating)", "ul")
        put("5gmm", 0x46, "Deregistration accept (UE originating)", "dl")
        put("5gmm", 0x47, "Deregistration request (UE terminated)", "dl")
        put("5gmm", 0x48, "Deregistration accept (UE terminated)", "ul")
        put("5gmm", 0x4C, "Service request", "ul"); put("5gmm", 0x4D, "Service reject", "dl")
        put("5gmm", 0x4E, "Service accept", "dl")
        put("5gmm", 0x4F, "Control plane service request", "ul")
        put("5gmm", 0x54, "Configuration update command", "dl")
        put("5gmm", 0x55, "Configuration update complete", "ul")
        put("5gmm", 0x56, "Authentication request", "dl")
        put("5gmm", 0x57, "Authentication response", "ul")
        put("5gmm", 0x58, "Authentication reject", "dl")
        put("5gmm", 0x59, "Authentication failure", "ul")
        put("5gmm", 0x5A, "Authentication result", "dl")
        put("5gmm", 0x5B, "Identity request", "dl"); put("5gmm", 0x5C, "Identity response", "ul")
        put("5gmm", 0x5D, "Security mode command", "dl")
        put("5gmm", 0x5E, "Security mode complete", "ul")
        put("5gmm", 0x5F, "Security mode reject", "ul")
        put("5gmm", 0x64, "5GMM status", null); put("5gmm", 0x65, "Notification", "dl")
        put("5gmm", 0x66, "Notification response", "ul")
        put("5gmm", 0x67, "UL NAS transport", "ul"); put("5gmm", 0x68, "DL NAS transport", "dl")
        // 5GS session management
        put("5gsm", 0xC1, "PDU session establishment request", "ul")
        put("5gsm", 0xC2, "PDU session establishment accept", "dl")
        put("5gsm", 0xC3, "PDU session establishment reject", "dl")
        put("5gsm", 0xC5, "PDU session authentication command", "dl")
        put("5gsm", 0xC9, "PDU session modification request", "ul")
        put("5gsm", 0xCA, "PDU session modification reject", "dl")
        put("5gsm", 0xD1, "PDU session release request", "ul")
        put("5gsm", 0xD3, "PDU session release command", "dl")
        put("5gsm", 0xD6, "5GSM status", null)
    }

    /** TS 24.301 9.9.3.9. */
    private val EMM_CAUSES = mapOf(
        2 to "IMSI unknown in HSS", 3 to "Illegal UE", 5 to "IMEI not accepted",
        6 to "Illegal ME", 7 to "EPS services not allowed",
        8 to "EPS services and non-EPS services not allowed",
        9 to "UE identity cannot be derived by the network", 10 to "Implicitly detached",
        11 to "PLMN not allowed", 12 to "Tracking area not allowed",
        13 to "Roaming not allowed in this tracking area",
        14 to "EPS services not allowed in this PLMN", 15 to "No suitable cells in tracking area",
        16 to "MSC temporarily not reachable", 17 to "Network failure",
        18 to "CS domain not available", 19 to "ESM failure", 20 to "MAC failure",
        21 to "Synch failure", 22 to "Congestion", 23 to "UE security capabilities mismatch",
        24 to "Security mode rejected, unspecified", 25 to "Not authorized for this CSG",
        26 to "Non-EPS authentication unacceptable",
        35 to "Requested service option not authorized in this PLMN",
        39 to "CS service temporarily not available", 40 to "No EPS bearer context activated",
        42 to "Severe network failure", 95 to "Semantically incorrect message",
        96 to "Invalid mandatory information",
        97 to "Message type non-existent or not implemented",
        98 to "Message type not compatible with the protocol state",
        99 to "Information element non-existent or not implemented",
        100 to "Conditional IE error", 101 to "Message not compatible with the protocol state",
        111 to "Protocol error, unspecified",
    )

    /** TS 24.501 9.11.3.2. */
    private val FIVE_GMM_CAUSES = mapOf(
        3 to "Illegal UE", 5 to "PEI not accepted", 6 to "Illegal ME",
        7 to "5GS services not allowed", 9 to "UE identity cannot be derived by the network",
        10 to "Implicitly de-registered", 11 to "PLMN not allowed",
        12 to "Tracking area not allowed", 13 to "Roaming not allowed in this tracking area",
        15 to "No suitable cells in tracking area", 20 to "MAC failure", 21 to "Synch failure",
        22 to "Congestion", 23 to "UE security capabilities mismatch",
        24 to "Security mode rejected, unspecified", 26 to "Non-5G authentication unacceptable",
        27 to "N1 mode not allowed", 28 to "Restricted service area",
        43 to "LADN not available", 65 to "Maximum number of PDU sessions reached",
        67 to "Insufficient resources for specific slice and DNN",
        69 to "Insufficient resources for specific slice", 71 to "ngKSI already in use",
        72 to "Non-3GPP access to 5GCN not allowed", 73 to "Serving network not authorized",
        74 to "Temporarily not authorized for this SNPN",
        75 to "Permanently not authorized for this SNPN",
        76 to "Not authorized for this CAG or authorized for CAG cells only",
        77 to "Wireline access area not allowed", 90 to "Payload was not forwarded",
        91 to "DNN not supported or not subscribed in the slice",
        92 to "Insufficient user-plane resources for the PDU session",
        95 to "Semantically incorrect message", 96 to "Invalid mandatory information",
        97 to "Message type non-existent or not implemented",
        98 to "Message type not compatible with the protocol state",
        99 to "Information element non-existent or not implemented",
        100 to "Conditional IE error", 101 to "Message not compatible with the protocol state",
        111 to "Protocol error, unspecified",
    )

    /** TS 24.301 9.9.4.4. */
    private val ESM_CAUSES = mapOf(
        8 to "Operator determined barring", 26 to "Insufficient resources",
        27 to "Missing or unknown APN", 28 to "Unknown PDN type",
        29 to "User authentication failed", 30 to "Request rejected by Serving GW or PDN GW",
        31 to "Request rejected, unspecified", 32 to "Service option not supported",
        33 to "Requested service option not subscribed",
        34 to "Service option temporarily out of order", 35 to "PTI already in use",
        36 to "Regular deactivation", 37 to "EPS QoS not accepted", 38 to "Network failure",
        39 to "Reactivation requested", 50 to "PDN type IPv4 only allowed",
        51 to "PDN type IPv6 only allowed", 54 to "PDN connection does not exist",
        55 to "Multiple PDN connections for a given APN not allowed",
        65 to "Maximum number of EPS bearers reached",
    )

    /** TS 24.501 9.11.4.2. */
    private val FIVE_GSM_CAUSES = mapOf(
        8 to "Operator determined barring", 26 to "Insufficient resources",
        27 to "Missing or unknown DNN", 28 to "Unknown PDU session type",
        29 to "User authentication or authorization failed",
        31 to "Request rejected, unspecified", 32 to "Service option not supported",
        33 to "Requested service option not subscribed", 36 to "Regular deactivation",
        38 to "Network failure", 39 to "Reactivation requested",
        50 to "PDU session type IPv4 only allowed", 51 to "PDU session type IPv6 only allowed",
        54 to "PDU session does not exist", 67 to "Insufficient resources for specific slice and DNN",
        69 to "Insufficient resources for specific slice",
    )

    /** The 3GPP name and direction of a message type, or nulls when the type is unknown. */
    fun message(sublayer: String, messageType: Int?): Pair<String?, String?> {
        if (messageType == null) return null to null
        val entry = MESSAGES[sublayer to messageType] ?: return null to null
        return entry.name to entry.direction
    }

    /** The 3GPP name of a cause within its sublayer, or null when it is not one we name. */
    fun cause(sublayer: String, value: Int): String? = when (sublayer) {
        "emm" -> EMM_CAUSES[value]
        "esm" -> ESM_CAUSES[value]
        "5gmm" -> FIVE_GMM_CAUSES[value]
        "5gsm" -> FIVE_GSM_CAUSES[value]
        else -> null
    }
}
