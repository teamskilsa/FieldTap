package com.fieldtap.diag

/**
 * The diag log codes that carry signalling, and what each one is.
 *
 * A log code says which subsystem produced a record and, for NAS, what the modem claims the record
 * is: which sublayer, which direction, and whether it was ciphered on the air. The claim is worth
 * keeping separately from what the PDU itself says, because a disagreement between the two is a
 * decoding bug worth seeing rather than hiding — the desktop tool counts them, and so should this.
 *
 * The signalling codes are what the phone decodes, and [of] answers for them alone. The other codes
 * a [CaptureProfile] can enable — measurements, MAC, state logs — are listed in [extra] so a capture
 * can ask the modem for them; the phone keeps them in the file for the desktop tool and shows nothing.
 * Both lists mirror `fieldtap/decode/registry.py`, and the golden mask files under
 * `tests/fixtures/masks/` hold the two implementations to the same codes.
 *
 * Owner: workstream `diag-on-handset`.
 */
object LogCodes {

    enum class Category {
        RRC, NAS, CELL,

        /** Measurements and PHY reports: RSRP, CSF, transmit power, decode statistics. */
        MEAS,

        /** MAC: RACH, scheduling, transport blocks. */
        MAC,

        /** State and configuration logs, kept for the desktop tool. */
        OTHER,
    }

    /** What the log code says a record is, before the body is read. */
    data class Info(
        val code: Int,
        val name: String,
        /** "lte" or "nr". */
        val rat: String,
        val category: Category,
        /** For NAS: the sublayer the code claims. Null otherwise. */
        val nasSublayer: String? = null,
        /** For NAS: "ul" when the modem sent it, "dl" when it received it. Null otherwise. */
        val nasDirection: String? = null,
        /** For NAS: true when the message was security protected on the air. */
        val nasProtected: Boolean = false,
    ) {
        val isNr: Boolean get() = rat == "nr"
    }

    private fun rrc(code: Int, name: String, rat: String) = Info(code, name, rat, Category.RRC)
    private fun cell(code: Int, name: String, rat: String) = Info(code, name, rat, Category.CELL)
    private fun nas(code: Int, name: String, rat: String, sub: String, dir: String, prot: Boolean) =
        Info(code, name, rat, Category.NAS, sub, dir, prot)

    private val ALL: List<Info> = listOf(
        // LTE RRC and cell identity
        rrc(0xB0C0, "LTE RRC OTA Packet", "lte"),
        cell(0xB0C1, "LTE RRC MIB Message Log Packet", "lte"),
        cell(0xB0C2, "LTE RRC Serving Cell Info Log Packet", "lte"),
        // LTE NAS. "Incoming" is from the network, so downlink.
        nas(0xB0E0, "LTE NAS ESM Security Protected Incoming Msg", "lte", "esm", "dl", true),
        nas(0xB0E1, "LTE NAS ESM Security Protected Outgoing Msg", "lte", "esm", "ul", true),
        nas(0xB0E2, "LTE NAS ESM Plain OTA Incoming Msg", "lte", "esm", "dl", false),
        nas(0xB0E3, "LTE NAS ESM Plain OTA Outgoing Msg", "lte", "esm", "ul", false),
        nas(0xB0EA, "LTE NAS EMM Security Protected Incoming Msg", "lte", "emm", "dl", true),
        nas(0xB0EB, "LTE NAS EMM Security Protected Outgoing Msg", "lte", "emm", "ul", true),
        nas(0xB0EC, "LTE NAS EMM Plain OTA Incoming Msg", "lte", "emm", "dl", false),
        nas(0xB0ED, "LTE NAS EMM Plain OTA Outgoing Msg", "lte", "emm", "ul", false),
        // NR NAS
        nas(0xB800, "NR NAS SM5G Plain OTA Incoming Msg", "nr", "5gsm", "dl", false),
        nas(0xB801, "NR NAS SM5G Plain OTA Outgoing Msg", "nr", "5gsm", "ul", false),
        nas(0xB808, "NR NAS SM5G Security Protected Incoming Msg", "nr", "5gsm", "dl", true),
        nas(0xB809, "NR NAS SM5G Security Protected Outgoing Msg", "nr", "5gsm", "ul", true),
        nas(0xB80A, "NR NAS MM5G Plain OTA Incoming Msg", "nr", "5gmm", "dl", false),
        nas(0xB80B, "NR NAS MM5G Plain OTA Outgoing Msg", "nr", "5gmm", "ul", false),
        nas(0xB80C, "NR NAS MM5G Security Protected Incoming Msg", "nr", "5gmm", "dl", true),
        nas(0xB80D, "NR NAS MM5G Security Protected Outgoing Msg", "nr", "5gmm", "ul", true),
        // NR RRC and cell identity
        rrc(0xB821, "NR RRC OTA Packet", "nr"),
        cell(0xB822, "NR RRC MIB Info", "nr"),
        cell(0xB823, "NR RRC Serving Cell Info", "nr"),
    )

    private val BY_CODE: Map<Int, Info> = ALL.associateBy { it.code }

    private fun meas(code: Int, name: String, rat: String) = Info(code, name, rat, Category.MEAS)
    private fun mac(code: Int, name: String, rat: String) = Info(code, name, rat, Category.MAC)
    private fun other(code: Int, name: String, rat: String) = Info(code, name, rat, Category.OTHER)

    /**
     * What the engineering profile adds to signalling: the register's `meas` codes plus the RACH, PLMN
     * search, bearer and state logs it names. Names are the register's.
     */
    private val ENGINEERING_EXTRA: List<Info> = listOf(
        mac(0xB061, "LTE MAC RACH Trigger", "lte"),
        mac(0xB062, "LTE MAC RACH Attempt", "lte"),
        other(0xB0C3, "LTE RRC PLMN Search Info", "lte"),
        other(0xB0C4, "LTE RRC PLMN Search Request", "lte"),
        other(0xB0E4, "LTE NAS ESM Bearer Context State", "lte"),
        other(0xB0E5, "LTE NAS ESM Bearer Context Info", "lte"),
        other(0xB0EE, "LTE NAS EMM State", "lte"),
        meas(0xB139, "LTE PHY PUSCH Tx Report", "lte"),
        meas(0xB14D, "LTE PHY PUCCH CSF", "lte"),
        meas(0xB14E, "LTE PHY PUSCH CSF", "lte"),
        meas(0xB16B, "LTE PHY PDCCH-PHICH Indication Report", "lte"),
        meas(0xB173, "LTE PDSCH Stat Indication", "lte"),
        meas(0xB179, "LTE ML1 Connected Mode LTE Intra-Freq Meas Results", "lte"),
        meas(0xB17F, "LTE ML1 Serving Cell Meas and Eval", "lte"),
        meas(0xB180, "LTE ML1 Idle Neighbor Meas Results", "lte"),
        meas(0xB193, "LTE ML1 Serving Cell Measurement Result", "lte"),
        meas(0xB195, "LTE ML1 Connected Neighbor Meas Request/Response", "lte"),
        other(0xB80F, "NR NAS MM5G Service Request", "nr"),
        other(0xB814, "NR NAS SM5G State", "nr"),
        other(0xB825, "NR RRC Configuration Info", "nr"),
        other(0xB826, "NR5G RRC Supported CA Combos", "nr"),
        mac(0xB883, "NR MAC UL Physical Channel Schedule Report", "nr"),
        mac(0xB888, "NR MAC PDSCH Stats", "nr"),
        meas(0xB975, "NR ML1 Serving Cell Beam Management", "nr"),
        meas(0xB97F, "NR ML1 Searcher Measurement DB Update Ext", "nr"),
    )

    /** What full L2 adds to engineering: every MAC transport block, and the rest of the register's `mac` codes. */
    private val L2_EXTRA: List<Info> = listOf(
        mac(0xB063, "LTE MAC DL Transport Block", "lte"),
        mac(0xB064, "LTE MAC UL Transport Block", "lte"),
        mac(0xB872, "NR L2 UL Transport Block", "nr"),
        mac(0xB887, "NR MAC PDSCH Info", "nr"),
        mac(0xB88A, "NR MAC RACH Attempt", "nr"),
    )

    /** What [code] is, or null when it is not a signalling code. */
    fun of(code: Int): Info? = BY_CODE[code]

    /** Every signalling code, for building a capture's log mask. */
    fun all(): List<Info> = ALL

    /** The codes a signalling capture should enable. */
    fun signallingCodes(): List<Int> = ALL.map { it.code }

    /** The codes [profile] enables beyond signalling; nothing here is decoded on the phone. */
    fun extra(profile: CaptureProfile): List<Info> = when (profile) {
        CaptureProfile.SIGNALLING -> emptyList()
        CaptureProfile.ENGINEERING -> ENGINEERING_EXTRA
        CaptureProfile.L2 -> ENGINEERING_EXTRA + L2_EXTRA
    }

    /** The codes a capture with [profile] should enable, ascending: `profile_codes(profile.key)` in Python. */
    fun codes(profile: CaptureProfile): List<Int> = (signallingCodes() + extra(profile).map { it.code }).sorted()
}
