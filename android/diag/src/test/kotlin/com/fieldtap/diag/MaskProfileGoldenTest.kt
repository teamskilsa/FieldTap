package com.fieldtap.diag

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The mask file for each [CaptureProfile] is byte for byte the one `fieldtap/diag/protocol.py` builds for
 * the same profile of `fieldtap/decode/registry.py`, over [LogMask.DEFAULT_RANGES].
 *
 * The goldens are tests/fixtures/masks/<profile>.hex, written by tests/test_mask_profiles.py (which also
 * checks they are current) and read here relative to the :diag module directory, the way the :core tests
 * read the golden session. Lines starting with `#` are the generator's notes; the rest is hex.
 */
class MaskProfileGoldenTest {

    private fun golden(profile: CaptureProfile): ByteArray {
        val file = File("../../tests/fixtures/masks/${profile.key}.hex")
        assertTrue("${file.path} is missing: run tests/test_mask_profiles.py with FT_WRITE_MASK_FIXTURES=1", file.isFile)
        val digits = file.readLines().filterNot { it.trimStart().startsWith("#") }.joinToString("") { it.trim() }
        return ByteArray(digits.length / 2) { digits.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    private fun assertProfileMatchesItsGolden(profile: CaptureProfile) {
        val want = golden(profile)
        val got = LogMask.file(LogCodes.codes(profile), LogMask.DEFAULT_RANGES)
        assertEquals("${profile.key}: size", want.size, got.size)
        assertEquals("${profile.key}: bytes", want.hex(), got.hex())
    }

    @Test
    fun theSignallingMaskIsTheDesktopTools() = assertProfileMatchesItsGolden(CaptureProfile.SIGNALLING)

    @Test
    fun theEngineeringMaskIsTheDesktopTools() = assertProfileMatchesItsGolden(CaptureProfile.ENGINEERING)

    @Test
    fun theFullL2MaskIsTheDesktopTools() = assertProfileMatchesItsGolden(CaptureProfile.L2)

    @Test
    fun theSignallingProfileIsExactlyTheSignallingCodes() {
        // The default profile must not change what a capture asked for before profiles existed.
        assertEquals(LogCodes.signallingCodes().sorted(), LogCodes.codes(CaptureProfile.SIGNALLING))
    }

    @Test
    fun theProfilesNestAndMatchTheRegistersCounts() {
        val signalling = LogCodes.codes(CaptureProfile.SIGNALLING).toSet()
        val engineering = LogCodes.codes(CaptureProfile.ENGINEERING).toSet()
        val l2 = LogCodes.codes(CaptureProfile.L2).toSet()
        assertEquals(22, signalling.size)
        assertEquals(47, engineering.size)
        assertEquals(52, l2.size)
        assertTrue(engineering.containsAll(signalling))
        assertTrue(l2.containsAll(engineering))
    }

    @Test
    fun everyProfileCodeIsWithinTheDefaultRangesSoNoneIsSilentlyDropped() {
        for (profile in CaptureProfile.entries) {
            for (code in LogCodes.codes(profile)) {
                val last = LogMask.DEFAULT_RANGES[Protocol.equipId(code)]
                assertTrue("${profile.key}: 0x%04X has no range".format(code), last != null && last > 0)
                assertTrue("${profile.key}: 0x%04X is beyond its range".format(code), Protocol.logItem(code) <= last!!)
            }
        }
    }

    @Test
    fun aProfileIsFoundByItsRegisterName() {
        for (profile in CaptureProfile.entries) assertEquals(profile, CaptureProfile.fromKey(profile.key))
        assertEquals(null, CaptureProfile.fromKey("corpus"))
        assertEquals(null, CaptureProfile.fromKey(null))
    }

    @Test
    fun noExtraCodeIsASignallingCode() {
        for (info in LogCodes.extra(CaptureProfile.L2)) {
            assertEquals("0x%04X".format(info.code), null, LogCodes.of(info.code))
            assertTrue(info.category in setOf(LogCodes.Category.MEAS, LogCodes.Category.MAC, LogCodes.Category.OTHER))
        }
    }
}
