package com.fieldtap.core.export

import com.fieldtap.format.LocationPrecision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SessionKmlTest {

    @get:Rule
    val temp = TemporaryFolder()

    // The golden session's header rows, with three samples: excellent, poor, and one with no RSRP.
    private val kpi = "frame,time_epoch,rat,meas_id,pci,rsrp_dbm,rsrq_db,sinr_db,comment,lat,lon\r\n" +
        ",1789050600.400,lte,,212,-84.0,-8.0,15.0,android-api,38.8895000,-77.0353000\r\n" +
        ",1789050602.400,lte,,212,-112.0,-15.5,-2.0,android-api,38.8895011,-77.0353323\r\n" +
        ",1789050604.400,nr,,417,,,,android-api,38.8895200,-77.0353600\r\n" +
        ",1789050606.400,lte,,212,-90.0,-9.0,10.0,android-api,,\r\n"

    private val track = "time_utc,lat,lon,accuracy_m,altitude_m,speed_mps,provider,source\r\n" +
        "2026-09-10T14:30:00.000+00:00,38.8895000,-77.0353000,4.9,18.0,1.40,gps,android\r\n" +
        "2026-09-10T14:30:01.000+00:00,38.8895005,-77.0353162,5.0,18.0,1.42,gps,android\r\n"

    private fun session(): java.io.File = temp.newFolder("20260910-143000_Walk").apply {
        resolve("kpi.csv").writeText(kpi)
        resolve("track.csv").writeText(track)
    }

    @Test
    fun onlyLocatedSamplesBecomeDotsAndEachIsColouredByItsRsrp() {
        val points = SessionKml.points(kpi)
        assertEquals(3, points.size)
        assertEquals(
            listOf(SessionKml.Level.EXCELLENT, SessionKml.Level.POOR, SessionKml.Level.NONE),
            points.map { SessionKml.level(it.rsrp) },
        )
        assertEquals("RSRP -84 dBm · RSRQ -8 dB · SINR 15 dB · PCI 212 · LTE", SessionKml.describe(points.first()))
        assertTrue(SessionKml.describe(points[1]).contains("RSRQ -15.5 dB"))
    }

    @Test
    fun theThresholdsSplitWhereTheAppsScaleDoes() {
        assertEquals(SessionKml.Level.EXCELLENT, SessionKml.level(-85.0))
        assertEquals(SessionKml.Level.GOOD, SessionKml.level(-85.5))
        assertEquals(SessionKml.Level.GOOD, SessionKml.level(-95.0))
        assertEquals(SessionKml.Level.FAIR, SessionKml.level(-105.0))
        assertEquals(SessionKml.Level.POOR, SessionKml.level(-105.1))
    }

    @Test
    fun theFullMapHasTheTrackTheDotsAndTheirTimes() {
        val kml = SessionKml.build(session(), "Mall walk <north>", LocationPrecision.FULL)!!
        assertTrue(kml.startsWith("<?xml"))
        assertTrue(kml.contains("<name>Mall walk &lt;north&gt;</name>"))
        assertTrue(kml.contains("<LineString>"))
        assertTrue(kml.contains("-77.0353000,38.8895000,0 -77.0353162,38.8895005,0"))
        assertTrue(kml.contains("<TimeStamp><when>2026-09-10T14:30:00.400Z</when></TimeStamp>"))
        assertEquals(3, Regex("<Point>").findAll(kml).count())
        assertTrue(kml.contains("<name>Poor (1)</name>"))
    }

    @Test
    fun anApproximateMapIsNoSharperThanTheApproximateZip() {
        val kml = SessionKml.build(session(), "Walk", LocationPrecision.APPROX_110M)!!
        val coordinates = Regex("(-?\\d+\\.\\d+),(-?\\d+\\.\\d+),0").findAll(kml).toList()
        assertTrue(coordinates.isNotEmpty())
        // Three decimals of a degree is about 110 m; nothing finer survives.
        assertTrue(coordinates.all { m -> m.groupValues.drop(1).all { it.substringAfter('.').drop(3).all { d -> d == '0' } } })
        assertFalse(kml.contains("38.8895011"))
    }

    @Test
    fun thereIsNoMapAtPrecisionNoneOrWithNothingLocated() {
        assertNull(SessionKml.build(session(), "Walk", LocationPrecision.NONE))
        val empty = temp.newFolder("20260910-150000_Empty").apply {
            resolve("kpi.csv").writeText("frame,time_epoch,rat,meas_id,pci,rsrp_dbm,rsrq_db,sinr_db,comment,lat,lon\r\n")
        }
        assertNull(SessionKml.build(empty, "Empty", LocationPrecision.FULL))
    }
}
