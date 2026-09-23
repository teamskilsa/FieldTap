package com.fieldtap.diag

/**
 * How much of the modem a signalling capture asks for.
 *
 * Each profile is a set of log codes, [LogCodes.codes], mirrored from `fieldtap/decode/registry.py`'s
 * PROFILES of the same [key] so a phone records exactly what the desktop decoder reads. They nest:
 * every profile holds everything the one before it holds.
 *
 * The cost is file size. Signalling is a few kilobytes a minute; every MAC transport block is the
 * air interface itself, and a busy download fills megabytes in seconds.
 *
 * Owner: workstream `diag-on-handset`.
 */
enum class CaptureProfile(
    /** The name `fieldtap/decode/registry.py` uses, and what a capture's summary records. */
    val key: String,
    /** What the setting and the capture card call it. */
    val label: String,
    /** One line: what it adds, and what it costs. */
    val description: String,
) {
    SIGNALLING("signalling", "Signalling", "RRC, NAS and cell identity, small files"),
    ENGINEERING("engineering", "Engineering", "Adds measurements, PHY reports, RACH and state logs"),
    L2("l2", "Full L2", "Adds every MAC transport block; large files"),
    ;

    companion object {
        /** The profile called [key], or null: an unknown name is not silently some other profile. */
        fun fromKey(key: String?): CaptureProfile? = entries.firstOrNull { it.key == key }
    }
}
