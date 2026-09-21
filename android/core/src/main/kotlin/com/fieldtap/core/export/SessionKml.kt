package com.fieldtap.core.export

import com.fieldtap.format.Csv
import com.fieldtap.format.LocationPrecision
import com.fieldtap.format.SessionFile
import java.io.File
import java.time.Instant
import java.util.Locale

/**
 * A session as a map: every located signal sample as a dot coloured by RSRP, and the GPS track as a line,
 * in KML — the one format Google Earth, Google My Maps, QGIS and every GIS tool opens without a plug-in.
 *
 * It is a separate file on purpose, not an eighth entry in the export zip: the bundle contract allows the
 * seven session files and nothing else, and `fieldtap validate` rejects a zip that carries more.
 *
 * Location precision is the zip's: the rows go through [PrecisionReducer] before they become placemarks, so a
 * map shared at "approximate" is no sharper than the zip shared at "approximate", and at "none" there is no
 * map to share.
 *
 * Owner: workstream `export`.
 */
object SessionKml {

    /** One located sample. */
    data class Point(
        val timeEpochMs: Long?,
        val lat: Double,
        val lon: Double,
        val rat: String,
        val pci: Int?,
        val rsrp: Double?,
        val rsrq: Double?,
        val sinr: Double?,
    )

    /**
     * The app's signal scale (`SignalScale.RSRP_THRESHOLDS`), repeated here because core does not depend on the
     * app; `SessionKmlScaleTest` in the app fails if the two ever drift.
     */
    const val EXCELLENT_AT_LEAST: Int = -85
    const val GOOD_AT_LEAST: Int = -95
    const val FAIR_AT_LEAST: Int = -105

    enum class Level(val styleId: String, val label: String, val kmlColor: String) {
        // KML colours are aabbggrr.
        EXCELLENT("excellent", "Excellent", "ff50b93f"),
        GOOD("good", "Good", "ff5de19b"),
        FAIR("fair", "Fair", "ff4db8f2"),
        POOR("poor", "Poor", "ff4951f8"),
        NONE("none", "No RSRP", "ff9e948b"),
    }

    fun level(rsrp: Double?): Level = when {
        rsrp == null -> Level.NONE
        rsrp >= EXCELLENT_AT_LEAST -> Level.EXCELLENT
        rsrp >= GOOD_AT_LEAST -> Level.GOOD
        rsrp >= FAIR_AT_LEAST -> Level.FAIR
        else -> Level.POOR
    }

    /**
     * The map of the session in [sessionDir], or null when there is nothing to put on one: precision "none",
     * no located sample and no track.
     */
    fun build(sessionDir: File, name: String, precision: LocationPrecision): String? {
        if (precision == LocationPrecision.NONE) return null
        val points = read(sessionDir, SessionFile.KPI, precision)?.let(::points).orEmpty()
        val track = read(sessionDir, SessionFile.TRACK, precision)?.let(::track).orEmpty()
        if (points.isEmpty() && track.isEmpty()) return null
        return kml(name, points, track)
    }

    private fun read(dir: File, file: SessionFile, precision: LocationPrecision): String? {
        val source = File(dir, file.fileName)
        if (!source.isFile) return null
        return PrecisionReducer.reduceCsvText(file, source.readText(Charsets.UTF_8), precision)
    }

    /** kpi.csv rows that have a position. */
    fun points(kpiCsv: String): List<Point> {
        val rows = rows(kpiCsv) ?: return emptyList()
        return rows.mapNotNull { row ->
            val lat = row["lat"]?.toDoubleOrNull() ?: return@mapNotNull null
            val lon = row["lon"]?.toDoubleOrNull() ?: return@mapNotNull null
            Point(
                timeEpochMs = row["time_epoch"]?.toDoubleOrNull()?.let { (it * 1000).toLong() },
                lat = lat,
                lon = lon,
                rat = row["rat"].orEmpty(),
                pci = row["pci"]?.toIntOrNull(),
                rsrp = row["rsrp_dbm"]?.toDoubleOrNull(),
                rsrq = row["rsrq_db"]?.toDoubleOrNull(),
                sinr = row["sinr_db"]?.toDoubleOrNull(),
            )
        }
    }

    /** track.csv fixes, as (lat, lon). */
    fun track(trackCsv: String): List<Pair<Double, Double>> {
        val rows = rows(trackCsv) ?: return emptyList()
        return rows.mapNotNull { row ->
            val lat = row["lat"]?.toDoubleOrNull() ?: return@mapNotNull null
            val lon = row["lon"]?.toDoubleOrNull() ?: return@mapNotNull null
            lat to lon
        }
    }

    private fun rows(csv: String): List<Map<String, String>>? {
        val records = Csv.records(csv)
        if (records.isEmpty()) return null
        val header = Csv.parseRecord(records.first())
        return records.drop(1).filter { it.isNotBlank() }.map { line ->
            val fields = Csv.parseRecord(line)
            header.indices.associate { header[it] to fields.getOrElse(it) { "" } }
        }
    }

    fun kml(name: String, points: List<Point>, track: List<Pair<Double, Double>>): String = buildString {
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        append("<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n<Document>\n")
        append("  <name>").append(escape(name)).append("</name>\n")
        for (level in Level.entries) {
            append("  <Style id=\"").append(level.styleId).append("\"><IconStyle><color>").append(level.kmlColor)
                .append("</color><scale>0.6</scale><Icon><href>https://maps.google.com/mapfiles/kml/shapes/shaded_dot.png</href></Icon></IconStyle>")
                .append("<LabelStyle><scale>0</scale></LabelStyle></Style>\n")
        }
        append("  <Style id=\"track\"><LineStyle><color>ffeae63d</color><width>3</width></LineStyle></Style>\n")
        if (track.size >= 2) {
            append("  <Placemark><name>Track</name><styleUrl>#track</styleUrl><LineString><tessellate>1</tessellate><coordinates>")
            track.joinTo(this, " ") { (lat, lon) -> coordinate(lat, lon) }
            append("</coordinates></LineString></Placemark>\n")
        }
        if (points.isNotEmpty()) {
            append("  <Folder><name>RSRP</name>\n")
            for (level in Level.entries) {
                val atLevel = points.filter { level(it.rsrp) == level }
                if (atLevel.isEmpty()) continue
                append("    <Folder><name>").append(level.label).append(" (").append(atLevel.size).append(")</name>\n")
                for (p in atLevel) {
                    append("      <Placemark><styleUrl>#").append(level.styleId).append("</styleUrl>")
                    p.timeEpochMs?.let { append("<TimeStamp><when>").append(Instant.ofEpochMilli(it)).append("</when></TimeStamp>") }
                    append("<description>").append(escape(describe(p))).append("</description>")
                    append("<Point><coordinates>").append(coordinate(p.lat, p.lon)).append("</coordinates></Point></Placemark>\n")
                }
                append("    </Folder>\n")
            }
            append("  </Folder>\n")
        }
        append("</Document>\n</kml>\n")
    }

    /** "RSRP −84 dBm · RSRQ −8 dB · SINR 15 dB · PCI 212 · LTE". */
    internal fun describe(p: Point): String = listOfNotNull(
        p.rsrp?.let { "RSRP ${number(it)} dBm" },
        p.rsrq?.let { "RSRQ ${number(it)} dB" },
        p.sinr?.let { "SINR ${number(it)} dB" },
        p.pci?.let { "PCI $it" },
        p.rat.takeIf { it.isNotEmpty() }?.uppercase(Locale.ROOT),
    ).joinToString(" · ")

    private fun number(v: Double): String =
        if (v == Math.floor(v)) v.toLong().toString() else String.format(Locale.ROOT, "%.1f", v)

    private fun coordinate(lat: Double, lon: Double) = String.format(Locale.ROOT, "%.7f,%.7f,0", lon, lat)

    private fun escape(text: String): String =
        text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}
