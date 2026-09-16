package com.fieldtap.format

/**
 * Enumerated values as the files spell them. Every enum carries its exact wire text in `wire`;
 * nothing else in the app turns these into strings.
 *
 * Owner: workstream `format`.
 */

/** `cellinfo.csv` `rat`: the `CellInfo` subclass. */
enum class Rat(val wire: String) {
    NR("nr"),
    LTE("lte"),
    WCDMA("wcdma"),
    GSM("gsm"),
    TDSCDMA("tdscdma"),
    CDMA("cdma");

    /** LTE and NR can serve a KPI row; the other RATs never can. */
    val servingRat: ServingRat?
        get() = when (this) {
            NR -> ServingRat.NR
            LTE -> ServingRat.LTE
            else -> null
        }
}

/** `rat` in kpi.csv and cells.csv: only `lte` and `nr` exist there. */
enum class ServingRat(val wire: String) {
    LTE("lte"),
    NR("nr");

    val rat: Rat get() = if (this == LTE) Rat.LTE else Rat.NR
    val eventRat: EventRat get() = if (this == LTE) EventRat.LTE else EventRat.NR
}

/** `events.csv` `rat`: `-` marks a row that is not about a radio. */
enum class EventRat(val wire: String) {
    LTE("lte"),
    NR("nr"),
    NONE("-"),
}

/** `events.csv` `severity`. The report counts only `error` and `warn`. */
enum class Severity(val wire: String) {
    INFO("info"),
    OK("ok"),
    WARN("warn"),
    ERROR("error"),
}

/** Which API delivered a cell-info answer: `requestCellInfoUpdate` or `CellInfoListener`. */
enum class CellInfoSource(val wire: String) {
    REQUEST("request"),
    PUSH("push"),
}

/** `track.csv` `provider`. */
enum class FixProvider(val wire: String) {
    GPS("gps"),
    FUSED("fused"),
    NETWORK("network"),
}

/** `traffic.csv` `test`. The report silently ignores any other name, so no other exists. */
enum class TrafficTest(val wire: String) {
    PING("ping"),
    DOWNLOAD("download"),
    UPLOAD("upload"),
}

/** `privacy.location_precision`, and the choice made when exporting a copy. */
enum class LocationPrecision(val wire: String) {
    FULL("full"),
    APPROX_110M("approx_110m"),
    NONE("none");

    companion object {
        fun fromWire(text: String): LocationPrecision? = entries.firstOrNull { it.wire == text }
    }
}
