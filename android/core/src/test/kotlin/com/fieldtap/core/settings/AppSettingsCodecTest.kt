package com.fieldtap.core.settings

import com.fieldtap.core.nettest.TestSettings
import com.fieldtap.core.privacy.ConsentRecord
import com.fieldtap.core.privacy.PrivacyZone
import com.fieldtap.diag.CaptureProfile
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppSettingsCodecTest {

    private val full = AppSettings(
        installId = "7d0e5b8c-1f2a-4c3d-9e6f-0a1b2c3d4e5f",
        consent = ConsentRecord(
            version = "2026-09-10-draft",
            sha256 = "f63cb16aa9e2ae42f6feac10f42b470d85967b6b5ecc563cf655a1b61d4a442e",
            grantedUtcMs = 1_789_050_000_123L,
        ),
        tests = TestSettings(
            pingTarget = "10.0.2.2",
            pingIntervalMs = 30_000,
            pingCount = 3,
            pingTimeoutMs = 1_500,
            downloadUrl = "https://speed.cloudflare.com/__down?bytes=1000000",
            downloadIntervalMs = 120_000,
            downloadCapBytes = 1_000_000,
            sessionBudgetBytes = 5_000_000,
        ),
        zones = listOf(
            PrivacyZone(id = "b-id", label = "Office \"north\" \\ wing, café", lat = 51.5007292, lon = -0.1246254, radiusM = 150.0),
            PrivacyZone(id = "a-id", label = "Home", lat = -33.8567844, lon = 151.2152967, radiusM = 50.0),
        ),
        testsDefaultOn = true,
        readinessLastRunUtcMs = 1_789_050_500_000L,
        lastSessionStartedUtcMs = 1_789_050_600_000L,
        captureProfile = CaptureProfile.L2,
    )

    private val neverCalled: () -> String = { throw AssertionError("a document with an install id keeps it") }

    private val newId: () -> String = { "new-install-id" }

    private fun decode(text: String?) = AppSettingsCodec.decode(text, neverCalled)

    @Test
    fun aRoundTripKeepsEveryField() {
        assertEquals(full, decode(AppSettingsCodec.encode(full)))
    }

    @Test
    fun defaultsRoundTrip() {
        val defaults = AppSettings(installId = "abc")
        assertEquals(defaults, decode(AppSettingsCodec.encode(defaults)))
    }

    @Test
    fun noTextGivesDefaultsWithANewInstallId() {
        for (text in listOf(null, "", "   ")) {
            assertEquals(AppSettings(installId = "new-install-id"), AppSettingsCodec.decode(text, newId))
        }
    }

    @Test
    fun corruptTextGivesDefaultsWithANewInstallIdAndNoConsent() {
        val truncated = AppSettingsCodec.encode(full).dropLast(10)
        for (text in listOf(truncated, "not json", "[1, 2]", "42", "\"install_id\"", "{\"install_id\": }")) {
            val decoded = AppSettingsCodec.decode(text, newId)
            assertEquals(text, AppSettings(installId = "new-install-id"), decoded)
            assertNull(decoded.consent)
        }
    }

    @Test
    fun aDocumentWithoutAUsableInstallIdStartsOverWithoutConsent() {
        val consent = "\"consent\": {\"version\": \"2026-09-10-draft\", \"sha256\": \"abc\", \"granted_utc_ms\": 5}"
        val ids = listOf("", "\"install_id\": null, ", "\"install_id\": \"  \", ", "\"install_id\": 42, ")
        for (id in ids) {
            val text = "{" + id + consent + "}"
            assertEquals(text, AppSettings(installId = "new-install-id"), AppSettingsCodec.decode(text, newId))
        }
    }

    @Test
    fun unknownKeysAreIgnored() {
        val text = "{\"install_id\": \"abc\", \"future_feature\": {\"x\": [1, 2]}, " +
            "\"tests\": {\"ping_count\": 7, \"future_test\": true}}"
        assertEquals(AppSettings(installId = "abc", tests = TestSettings(pingCount = 7)), decode(text))
    }

    @Test
    fun missingKeysTakeDefaults() {
        assertEquals(AppSettings(installId = "abc"), decode("{\"install_id\": \"abc\"}"))
    }

    @Test
    fun aMissingOrMistypedTestsObjectGivesDefaultTests() {
        for (tests in listOf("", ", \"tests\": null", ", \"tests\": [1]", ", \"tests\": \"fast\"")) {
            assertEquals(tests, TestSettings(), decode("{\"install_id\": \"abc\"" + tests + "}").tests)
        }
    }

    @Test
    fun aPartialTestsObjectKeepsWhatItHas() {
        val text = "{\"install_id\": \"abc\", \"tests\": {\"ping_target\": \"10.0.2.2\", \"download_interval_ms\": 600000}}"
        assertEquals(TestSettings(pingTarget = "10.0.2.2", downloadIntervalMs = 600_000), decode(text).tests)
    }

    @Test
    fun damagedTestValuesFallBackToDefaults() {
        val text = "{\"install_id\": \"abc\", \"tests\": {\"ping_target\": 8, \"ping_interval_ms\": 0, " +
            "\"ping_count\": -1, \"ping_timeout_ms\": \"2000\", \"download_interval_ms\": 1.5, " +
            "\"download_cap_bytes\": -5, \"session_budget_bytes\": -1}}"
        assertEquals(TestSettings(), decode(text).tests)
    }

    @Test
    fun aZeroSessionBudgetIsKept() {
        val text = "{\"install_id\": \"abc\", \"tests\": {\"session_budget_bytes\": 0}}"
        assertEquals(0L, decode(text).tests.sessionBudgetBytes)
    }

    @Test
    fun blankTargetsAreKeptAsTheUserLeftThemAndANullDownloadUrlStaysNull() {
        val blank = decode("{\"install_id\": \"abc\", \"tests\": {\"ping_target\": \"\", \"download_url\": \"  \"}}").tests
        assertEquals("a blank target switches ping off; it is not replaced", "", blank.pingTarget)
        assertEquals("  ", blank.downloadUrl)
        assertNull(decode("{\"install_id\": \"abc\", \"tests\": {\"download_url\": null}}").tests.downloadUrl)

        assertEquals(TestSettings().downloadUrl, decode("{\"install_id\": \"abc\", \"tests\": {}}").tests.downloadUrl)
        assertEquals(
            "a mistyped URL takes the default",
            TestSettings().downloadUrl,
            decode("{\"install_id\": \"abc\", \"tests\": {\"download_url\": 5}}").tests.downloadUrl,
        )
        assertEquals(
            "a mistyped target takes the default",
            TestSettings().pingTarget,
            decode("{\"install_id\": \"abc\", \"tests\": {\"ping_target\": [\"8.8.8.8\"]}}").tests.pingTarget,
        )

        val choices = listOf(
            TestSettings(downloadUrl = "https://example.org/1MB.bin"),
            TestSettings(downloadUrl = null),
            TestSettings(pingTarget = "", downloadUrl = ""),
        )
        for (tests in choices) {
            val settings = AppSettings(installId = "abc", tests = tests)
            assertEquals(settings, decode(AppSettingsCodec.encode(settings)))
        }
    }

    @Test
    fun zonesKeepTheirOrder() {
        val zones = (1..5).map { PrivacyZone(id = "id-$it", label = "Zone $it", lat = 10.0 + it, lon = 20.0 - it, radiusM = 50.0 * it) }
        val settings = AppSettings(installId = "abc", zones = zones.reversed())
        assertEquals(zones.reversed(), decode(AppSettingsCodec.encode(settings)).zones)
    }

    @Test
    fun aZoneWithoutAUsablePositionOrRadiusIsDroppedAndTheOthersKept() {
        val text = """
            {"install_id": "abc", "zones": [
              {"id": "keep-1", "label": "A", "lat": 1.5, "lon": 2.5, "radius_m": 100},
              {"id": "no-lat", "label": "B", "lon": 2.5, "radius_m": 100},
              {"id": "text-lon", "label": "C", "lat": 1.5, "lon": "2.5", "radius_m": 100},
              {"id": "null-radius", "label": "D", "lat": 1.5, "lon": 2.5, "radius_m": null},
              "not a zone",
              {"id": "keep-2", "lat": -1.5, "lon": -2.5, "radius_m": 75.5}
            ]}
        """.trimIndent()
        assertEquals(
            listOf(
                PrivacyZone(id = "keep-1", label = "A", lat = 1.5, lon = 2.5, radiusM = 100.0),
                PrivacyZone(id = "keep-2", label = "", lat = -1.5, lon = -2.5, radiusM = 75.5),
            ),
            decode(text).zones,
        )
    }

    @Test
    fun aZoneWithoutAnIdGetsANewOne() {
        val text = "{\"install_id\": \"abc\", \"zones\": [{\"label\": \"A\", \"lat\": 1.5, \"lon\": 2.5, \"radius_m\": 100}]}"
        val zone = decode(text).zones.single()
        assertTrue(zone.id.isNotBlank())
        assertEquals(PrivacyZone(id = zone.id, label = "A", lat = 1.5, lon = 2.5, radiusM = 100.0), zone)
    }

    @Test
    fun mistypedValuesFallBackToDefaults() {
        val text = "{\"install_id\": \"abc\", \"tests_default_on\": 1, " +
            "\"readiness_last_run_utc_ms\": \"123\", \"last_session_started_utc_ms\": true, " +
            "\"zones\": {\"id\": \"x\"}, \"consent\": \"granted\"}"
        assertEquals(AppSettings(installId = "abc"), decode(text))
    }

    @Test
    fun anIncompleteConsentIsAbsent() {
        val consents = listOf(
            "{\"version\": \"v\", \"sha256\": \"h\"}",
            "{\"version\": \"\", \"sha256\": \"h\", \"granted_utc_ms\": 1}",
            "{\"sha256\": \"h\", \"granted_utc_ms\": 1}",
            "{\"version\": \"v\", \"sha256\": 5, \"granted_utc_ms\": 1}",
            "{\"version\": \"v\", \"sha256\": \"h\", \"granted_utc_ms\": \"1\"}",
        )
        for (consent in consents) {
            assertNull(consent, decode("{\"install_id\": \"abc\", \"consent\": " + consent + "}").consent)
        }
    }

    @Test
    fun everyCaptureProfileRoundTripsUnderItsRegisterName() {
        for (profile in CaptureProfile.entries) {
            val settings = AppSettings(installId = "abc", captureProfile = profile)
            val text = AppSettingsCodec.encode(settings)
            assertTrue(text, text.contains("\"capture_profile\":\"${profile.key}\""))
            assertEquals(settings, decode(text))
        }
    }

    @Test
    fun aMissingUnknownOrMistypedCaptureProfileIsSignalling() {
        // A build that drops a profile, or a hand-edited document, must still read; the smallest capture is the
        // one that cannot surprise anyone with a large file.
        for (profile in listOf("", ", \"capture_profile\": \"corpus\"", ", \"capture_profile\": 2", ", \"capture_profile\": null", ", \"capture_profile\": \"L2\"")) {
            assertEquals(profile, CaptureProfile.SIGNALLING, decode("{\"install_id\": \"abc\"" + profile + "}").captureProfile)
        }
    }

    @Test
    fun theDocumentUsesStableSnakeCaseKeys() {
        val root = Json.parseToJsonElement(AppSettingsCodec.encode(full)) as JsonObject
        assertEquals(
            setOf(
                "settings_version", "install_id", "consent", "tests", "zones",
                "tests_default_on", "readiness_last_run_utc_ms", "last_session_started_utc_ms", "capture_profile",
            ),
            root.keys,
        )
        assertEquals("1", root["settings_version"].toString())
        assertEquals("\"l2\"", root["capture_profile"].toString())
        assertEquals(setOf("version", "sha256", "granted_utc_ms"), (root["consent"] as JsonObject).keys)
        assertEquals(
            setOf(
                "ping_target", "ping_interval_ms", "ping_count", "ping_timeout_ms", "download_url",
                "download_interval_ms", "download_cap_bytes", "session_budget_bytes",
            ),
            (root["tests"] as JsonObject).keys,
        )
    }
}
