package com.fieldtap.diag

/**
 * The diag log codes that carry signalling, and what each one is.
 *
 * A log code says which subsystem produced a record and, for NAS, what the modem claims the record
 * is: which sublayer, which direction, and whether it was ciphered on the air. The claim is worth
 * keeping separately from what the PDU itself says, because a disagreement between the two is a
 * decoding bug worth seeing rather than hiding — the desktop tool counts them, and so should this.
 *
 * Only the signalling codes are listed. A capture holds hundreds of others, which are kept in the
 * file for export but have nothing to show on a phone screen.
 *
 * Owner: workstream `diag-on-handset`.
 */
object LogCodes {

    enum class Category { RRC, NAS, CELL }

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

    /** What [code] is, or null when it is not a signalling code. */
    fun of(code: Int): Info? = BY_CODE[code]

    /** Every signalling code, for building a capture's log mask. */
    fun all(): List<Info> = ALL

    /** The codes a signalling capture should enable. */
    fun signallingCodes(): List<Int> = ALL.map { it.code }
}
