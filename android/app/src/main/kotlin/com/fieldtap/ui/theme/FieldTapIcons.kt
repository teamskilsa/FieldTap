package com.fieldtap.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/**
 * The app's icon set: 24 dp line icons with a 2 dp stroke and round ends, drawn for FieldTap
 * (Material 3 1.4 no longer bundles icons, and no icon library is added). Use them with
 * `androidx.compose.material3.Icon`, which tints them; always pass a content description, or null
 * when a text label next to the icon says the same thing.
 *
 * Directional icons ([ArrowBack], [ChevronRight], [OpenInNew]) mirror in right-to-left layouts.
 */
object FieldTapIcons {
    val ArrowBack: ImageVector by lazy { icon("ArrowBack", strokes = listOf("M20 12H4", "M10 6L4 12L10 18"), autoMirror = true) }
    val Close: ImageVector by lazy { icon("Close", strokes = listOf("M6 6L18 18", "M18 6L6 18")) }
    val ChevronRight: ImageVector by lazy { icon("ChevronRight", strokes = listOf("M9 5.5L15.5 12L9 18.5"), autoMirror = true) }
    val ExpandMore: ImageVector by lazy { icon("ExpandMore", strokes = listOf("M6 9L12 15L18 9")) }
    val Check: ImageVector by lazy { icon("Check", strokes = listOf("M4.5 12.5L9.5 17.5L19.5 7")) }
    val CheckCircle: ImageVector by lazy {
        icon("CheckCircle", strokes = listOf(circle(12f, 12f, 9f), "M8 12.5L11 15.5L16.5 9.5"))
    }
    val Warning: ImageVector by lazy {
        icon("Warning", strokes = listOf("M12 3.5L21.5 20H2.5Z", "M12 9.5V14"), fills = listOf(circle(12f, 17f, 1.25f)))
    }
    val Error: ImageVector by lazy {
        icon("Error", strokes = listOf(circle(12f, 12f, 9f), "M12 7.5V13"), fills = listOf(circle(12f, 16.5f, 1.25f)))
    }
    val Info: ImageVector by lazy {
        icon("Info", strokes = listOf(circle(12f, 12f, 9f), "M12 11V16.5"), fills = listOf(circle(12f, 7.75f, 1.25f)))
    }

    /** Start a session. */
    val Play: ImageVector by lazy { icon("Play", solids = listOf("M8 5.5V18.5L18.5 12Z")) }

    /** Stop a session. */
    val Stop: ImageVector by lazy { icon("Stop", solids = listOf("M7 7H17V17H7Z")) }
    val Pause: ImageVector by lazy { icon("Pause", strokes = listOf("M9 6V18", "M15 6V18")) }

    /** Mark (a marker event). */
    val Flag: ImageVector by lazy { icon("Flag", strokes = listOf("M5.5 21V3.5", "M5.5 4H17.5L15 8.5L17.5 13H5.5")) }
    val Edit: ImageVector by lazy { icon("Edit", strokes = listOf("M4 20H8L19 9L15 5L4 16Z", "M13 7L17 11")) }
    val Add: ImageVector by lazy { icon("Add", strokes = listOf("M12 5V19", "M5 12H19")) }
    val MoreVert: ImageVector by lazy {
        icon("MoreVert", fills = listOf(circle(12f, 5.5f, 1.75f), circle(12f, 12f, 1.75f), circle(12f, 18.5f, 1.75f)))
    }

    /** Location permission, a place. */
    val Location: ImageVector by lazy {
        icon(
            "Location",
            strokes = listOf("M12 21.5C12 21.5 5 15 5 9.8A7 7 0 0 1 19 9.8C19 15 12 21.5 12 21.5Z", circle(12f, 9.8f, 2.5f)),
        )
    }

    /** A GPS fix is being received. */
    val GpsFixed: ImageVector by lazy {
        icon(
            "GpsFixed",
            strokes = listOf(circle(12f, 12f, 7f), "M12 2V5", "M12 19V22", "M2 12H5", "M19 12H22"),
            fills = listOf(circle(12f, 12f, 2.5f)),
        )
    }

    /** No GPS fix. */
    val GpsOff: ImageVector by lazy {
        icon("GpsOff", strokes = listOf(circle(12f, 12f, 7f), "M12 2V5", "M12 19V22", "M2 12H5", "M19 12H22", "M4 4L20 20"))
    }

    /** Notifications permission. */
    val Notifications: ImageVector by lazy {
        icon("Notifications", strokes = listOf("M6 17V11A6 6 0 0 1 18 11V17", "M4 17H20", "M10 20.5H14", "M12 3V5"))
    }

    /** Phone permission, the handset. */
    val Phone: ImageVector by lazy {
        icon(
            "Phone",
            strokes = listOf("M8 2.5H16A2 2 0 0 1 18 4.5V19.5A2 2 0 0 1 16 21.5H8A2 2 0 0 1 6 19.5V4.5A2 2 0 0 1 8 2.5Z", "M11 18.5H13"),
        )
    }
    val Battery: ImageVector by lazy {
        icon("Battery", strokes = listOf("M8 4.5H16A1 1 0 0 1 17 5.5V20A1 1 0 0 1 16 21H8A1 1 0 0 1 7 20V5.5A1 1 0 0 1 8 4.5Z", "M10 2.5H14"))
    }

    /** Plugged in: unlocks the 2 s cadence with Wi-Fi on. */
    val Charging: ImageVector by lazy {
        icon("Charging", strokes = listOf("M9 3V7", "M15 3V7", "M7 7H17V11A5 5 0 0 1 7 11Z", "M12 16V21"))
    }
    val Wifi: ImageVector by lazy {
        icon(
            "Wifi",
            strokes = listOf("M3.1 10A12 12 0 0 1 20.9 10", "M6.05 12.65A8 8 0 0 1 17.95 12.65", "M9.03 15.32A4 4 0 0 1 14.97 15.32"),
            fills = listOf(circle(12f, 18.5f, 1.4f)),
        )
    }

    /** Cellular signal, cells, neighbours. */
    val SignalBars: ImageVector by lazy { icon("SignalBars", strokes = listOf("M5 19V16", "M9.67 19V12.5", "M14.33 19V9", "M19 19V5")) }
    val Sim: ImageVector by lazy {
        icon("Sim", strokes = listOf("M7 3H14L18 7V20A1 1 0 0 1 17 21H7A1 1 0 0 1 6 20V4A1 1 0 0 1 7 3Z", "M9.5 11.5H14.5V17.5H9.5Z"))
    }
    val Storage: ImageVector by lazy {
        icon("Storage", strokes = listOf("M5 6A7 2.5 0 1 0 19 6A7 2.5 0 1 0 5 6Z", "M5 6V18A7 2.5 0 0 0 19 18V6", "M5 12A7 2.5 0 0 0 19 12"))
    }

    /** The cadence indicator. */
    val Timer: ImageVector by lazy { icon("Timer", strokes = listOf(circle(12f, 13.5f, 7.5f), "M12 13.5V9.5", "M9.5 2.5H14.5", "M12 2.5V6")) }

    /** Settings. */
    val Tune: ImageVector by lazy {
        icon(
            "Tune",
            strokes = listOf("M4 6H9", "M13 6H20", "M4 12H13", "M17 12H20", "M4 18H6", "M10 18H20", circle(11f, 6f, 2f), circle(15f, 12f, 2f), circle(8f, 18f, 2f)),
        )
    }

    /** The sessions list. */
    val Sessions: ImageVector by lazy {
        icon(
            "Sessions",
            strokes = listOf("M9 6H20", "M9 12H20", "M9 18H20"),
            fills = listOf(circle(4.75f, 6f, 1.25f), circle(4.75f, 12f, 1.25f), circle(4.75f, 18f, 1.25f)),
        )
    }
    val File: ImageVector by lazy {
        icon("File", strokes = listOf("M6 3H14L19 8V20A1 1 0 0 1 18 21H6A1 1 0 0 1 5 20V4A1 1 0 0 1 6 3Z", "M14 3V8H19"))
    }
    val Share: ImageVector by lazy {
        icon(
            "Share",
            strokes = listOf(circle(18f, 5.5f, 2.5f), circle(6f, 12f, 2.5f), circle(18f, 18.5f, 2.5f), "M8.2 10.8L15.8 6.7", "M8.2 13.2L15.8 17.3"),
        )
    }
    val Delete: ImageVector by lazy {
        icon(
            "Delete",
            strokes = listOf(
                "M4 6.5H20",
                "M9 6.5V4.5A1 1 0 0 1 10 3.5H14A1 1 0 0 1 15 4.5V6.5",
                "M6 6.5L7 19.5A1.5 1.5 0 0 0 8.5 21H15.5A1.5 1.5 0 0 0 17 19.5L18 6.5",
                "M10 10.5V17",
                "M14 10.5V17",
            ),
        )
    }

    /** Opens a system settings screen or another app. */
    val OpenInNew: ImageVector by lazy {
        icon("OpenInNew", strokes = listOf("M14 4H20V10", "M20 4L11 13", "M18 14V19A1 1 0 0 1 17 20H5A1 1 0 0 1 4 19V7A1 1 0 0 1 5 6H10"), autoMirror = true)
    }
    val Refresh: ImageVector by lazy { icon("Refresh", strokes = listOf("M19.5 12A7.5 7.5 0 1 1 17.3 6.7", "M13 6.7H17.3V2.4")) }
    val Download: ImageVector by lazy { icon("Download", strokes = listOf("M12 4V15", "M7 10L12 15L17 10", "M5 20H19")) }

    /** Ping and download tests. */
    val Transfer: ImageVector by lazy { icon("Transfer", strokes = listOf("M8 20V4", "M4 8L8 4L12 8", "M16 4V20", "M12 16L16 20L20 16")) }

    /** Privacy zones and consent. */
    val Shield: ImageVector by lazy { icon("Shield", strokes = listOf("M12 3L19 6V11C19 15.5 16 19.2 12 21C8 19.2 5 15.5 5 11V6Z")) }

    /** The capability probe. */
    val Search: ImageVector by lazy { icon("Search", strokes = listOf(circle(10.5f, 10.5f, 6.5f), "M15.5 15.5L20.5 20.5")) }

    /** The activity/pulse waveform, for the Signalling tab. */
    val Pulse: ImageVector by lazy { icon("Pulse", strokes = listOf("M3 12H8L10.5 6L13.5 18L16 12H21")) }

    /** Walk mode. */
    val Walk: ImageVector by lazy {
        icon(
            "Walk",
            strokes = listOf("M12.5 8.5L10.5 14.5", "M10.5 14.5L8 21", "M10.5 14.5L14 17L14.5 21", "M7.5 12L10 8.8L12.5 8.5L15 11.5L17.5 12.5"),
            fills = listOf(circle(13.5f, 4.5f, 1.9f)),
        )
    }
}

/** A full circle as SVG path data. */
private fun circle(cx: Float, cy: Float, r: Float): String =
    "M${cx - r} ${cy}A$r $r 0 1 0 ${cx + r} ${cy}A$r $r 0 1 0 ${cx - r} ${cy}Z"

/**
 * Builds a 24 dp icon. [strokes] are 2 dp round lines, [fills] are filled shapes, and [solids] are
 * filled and outlined with a round join, which rounds their corners.
 */
private fun icon(
    name: String,
    strokes: List<String> = emptyList(),
    fills: List<String> = emptyList(),
    solids: List<String> = emptyList(),
    autoMirror: Boolean = false,
): ImageVector {
    val ink = SolidColor(Color.Black)
    val builder = ImageVector.Builder(
        name = "FieldTap.$name",
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
        autoMirror = autoMirror,
    )
    for (data in fills) {
        builder.addPath(pathData = addPathNodes(data), fill = ink)
    }
    for (data in solids) {
        builder.addPath(
            pathData = addPathNodes(data),
            fill = ink,
            stroke = ink,
            strokeLineWidth = 2f,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }
    for (data in strokes) {
        builder.addPath(
            pathData = addPathNodes(data),
            stroke = ink,
            strokeLineWidth = 2f,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }
    return builder.build()
}
