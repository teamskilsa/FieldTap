package com.fieldtap.core.session

import com.fieldtap.format.ServingRat
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SignalSummaryTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun theGoldenSessionIsSummarisedByItsLteRows() {
        assertTrue("golden kpi.csv missing at ${GOLDEN_KPI.absolutePath}", GOLDEN_KPI.isFile)

        // Python's statistics.median over the golden rows: 54 LTE values, median -89.0, none below -105; 46 NR values.
        val summary = SignalSummaries.read(GOLDEN_KPI)!!
        assertEquals(
            SignalSummary(ServingRat.LTE, samples = 54, medianRsrpDbm = -89, belowFairPct = 0.0),
            summary.copy(trace = emptyList()),
        )
    }

    @Test
    fun anNrOnlySessionIsSummarisedAsNrWithTheReportsShareBelow105() {
        val lines = GOLDEN_KPI.readText(Charsets.UTF_8).split(CRLF).filter { it.isNotEmpty() }
        val nrOnly = listOf(lines.first()) + lines.drop(1).filter { it.split(',')[2] == "nr" }

        val summary = SignalSummaries.read(kpi(nrOnly))

        // 46 NR values, median -96.0, 4 below -105 dBm (the report's pct_below_-105 rounds this to 8.7).
        assertEquals(ServingRat.NR, summary?.rat)
        assertEquals(46, summary?.samples)
        assertEquals(-96, summary?.medianRsrpDbm)
        assertEquals(400.0 / 46, summary!!.belowFairPct, 1e-9)
    }

    @Test
    fun theRatWithMoreValuesWinsAndLteWinsATie() {
        val nrMore = SignalSummaries.read(kpi(listOf(HEADER, row("lte", "-80.0"), row("nr", "-100.0"), row("nr", "-101.0"))))
        assertEquals(ServingRat.NR, nrMore?.rat)
        assertEquals(-100, nrMore?.medianRsrpDbm)

        val tie = SignalSummaries.read(kpi(listOf(HEADER, row("lte", "-80.0"), row("nr", "-100.0"))))
        assertEquals(ServingRat.LTE, tie?.rat)
        assertEquals(-80, tie?.medianRsrpDbm)
    }

    @Test
    fun anEvenCountAveragesTheMiddleValuesAndRoundsHalfToEven() {
        assertEquals(-92, SignalSummaries.read(kpi(listOf(HEADER, row("lte", "-92.0"), row("lte", "-93.0"))))?.medianRsrpDbm)
        assertEquals(-94, SignalSummaries.read(kpi(listOf(HEADER, row("lte", "-93.0"), row("lte", "-94.0"))))?.medianRsrpDbm)
        assertEquals(-106, SignalSummaries.read(kpi(listOf(HEADER, row("lte", "-105.0"), row("lte", "-107.0"))))?.medianRsrpDbm)
    }

    @Test
    fun onlyValuesStrictlyBelow105CountAsBelow() {
        val summary = SignalSummaries.read(kpi(listOf(HEADER, row("lte", "-105.0"), row("lte", "-105.1"), row("lte", "-90.0"), row("lte", "-120.0"))))

        assertEquals(50.0, summary!!.belowFairPct, 1e-9)
    }

    @Test
    fun blankOutOfRangeAndMisshapenRowsAreLeftOut() {
        val summary = SignalSummaries.read(
            kpi(
                listOf(
                    HEADER,
                    row("lte", ""),
                    row("lte", "-20.0"),
                    row("lte", "-90.0"),
                    ",1789050600.400,lte,,212,-60.0",
                    row("gsm", "-70.0"),
                ),
            ),
        )

        assertEquals(
            SignalSummary(ServingRat.LTE, samples = 1, medianRsrpDbm = -90, belowFairPct = 0.0),
            summary!!.copy(trace = emptyList()),
        )
        assertEquals("only the one usable row reaches the chart", 1, summary.trace.size)
    }

    @Test
    fun aTornLastRowIsLeftOut() {
        val file = kpi(listOf(HEADER, row("lte", "-90.0"), row("lte", "-91.0")))
        file.appendText(row("lte", "-1"), Charsets.UTF_8)

        assertEquals(2, SignalSummaries.read(file)?.samples)
        assertEquals(-90, SignalSummaries.read(file)?.medianRsrpDbm)
    }

    @Test
    fun noValuesMissingColumnsOrAMissingFileGiveNull() {
        assertNull(SignalSummaries.read(kpi(listOf(HEADER))))
        assertNull(SignalSummaries.read(kpi(listOf(HEADER, row("lte", "")))))
        assertNull(SignalSummaries.read(kpi(listOf("frame,time_epoch,pci", ",1789050600.400,212"))))
        assertNull(SignalSummaries.read(File(temp.root, "missing.csv")))
        assertNull(SignalSummaries.read(temp.newFile("empty.csv")))
    }

    /** A kpi.csv of [lines], each ending in CR LF as the writer ends them. */
    private fun kpi(lines: List<String>): File =
        File(temp.root, "kpi-${counter++}.csv").apply { writeText(lines.joinToString("") { it + CRLF }, Charsets.UTF_8) }

    private var counter = 0

    private fun row(rat: String, rsrp: String): String = ",1789050600.400,$rat,,212,$rsrp,-8.0,15.0,android-api age_ms=500 src=request,,"

    private companion object {
        const val CRLF = "\r\n"
        const val HEADER = "frame,time_epoch,rat,meas_id,pci,rsrp_dbm,rsrq_db,sinr_db,comment,lat,lon"
        val GOLDEN_KPI = File("../../tests/fixtures/android_session/20260910-143000_Mall-walk-north-path/kpi.csv")
    }

    @Test
    fun theGoldenSessionTraceIsOnePointPerLteSampleStartingAtZero() {
        val trace = SignalSummaries.read(GOLDEN_KPI)!!.trace

        assertEquals("one point per LTE sample, under the cap", 54, trace.size)
        assertEquals("the first sample is the origin", 0L, trace.first().atMs)
        assertTrue("time only moves forward", trace.zipWithNext().all { (a, b) -> b.atMs >= a.atMs })
        assertTrue("every value is a plausible RSRP", trace.all { it.rsrpDbm in -156..-43 })
    }

    @Test
    fun aTraceIsThinnedToTheCapKeepingItsEnds() {
        val header = "frame,time_epoch,rat,meas_id,pci,rsrp_dbm,rsrq_db,sinr_db,comment,lat,lon"
        val rows = (0 until SignalSummaries.TRACE_MAX * 3).map { i ->
            ",%d.000,lte,,212,%d.0,,,,,".format(1_789_050_600L + i, -80 - (i % 20))
        }
        val summary = SignalSummaries.read(kpi(listOf(header) + rows))!!

        assertEquals("every row is still a sample", SignalSummaries.TRACE_MAX * 3, summary.samples)
        assertEquals("the chart is bounded", SignalSummaries.TRACE_MAX, summary.trace.size)
        assertEquals(0L, summary.trace.first().atMs)
        assertEquals("the last sample is kept", (rows.size - 1) * 1_000L, summary.trace.last().atMs)
    }

    @Test
    fun aSamplingGapStaysAGapInTheTrace() {
        val header = "frame,time_epoch,rat,meas_id,pci,rsrp_dbm,rsrq_db,sinr_db,comment,lat,lon"
        val rows = listOf(
            ",1789050600.000,lte,,212,-80.0,,,,,",
            ",1789050602.000,lte,,212,-81.0,,,,,",
            // 60 s later: the chart must show the hole rather than a line drawn through it.
            ",1789050662.000,lte,,212,-95.0,,,,,",
        )
        val trace = SignalSummaries.read(kpi(listOf(header) + rows))!!.trace

        assertEquals(listOf(0L, 2_000L, 62_000L), trace.map { it.atMs })
        assertEquals(listOf(-80, -81, -95), trace.map { it.rsrpDbm })
    }
}
