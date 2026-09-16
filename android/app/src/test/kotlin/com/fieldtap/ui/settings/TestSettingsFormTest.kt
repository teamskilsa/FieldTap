package com.fieldtap.ui.settings

import com.fieldtap.core.nettest.TestSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TestSettingsFormTest {
    private val defaults = TestSettings()

    @Test
    fun theDefaultsPassTheRules() {
        assertEquals(emptyList<TestSettingsProblem>(), TestSettingsRules.problems(defaults))
    }

    @Test
    fun theDefaultsShowInDisplayUnitsAndParseBackUnchanged() {
        val form = TestSettingsForm.from(defaults)

        assertEquals(TestSettingsForm("8.8.8.8", "60", "5", TestSettings.DEFAULT_DOWNLOAD_URL, "5", "10", "", "5", "2", "100"), form)
        assertEquals(TestSettingsParse.Valid(defaults), form.parse(defaults))
    }

    @Test
    fun storedValuesRoundHalfUpToWholeDisplayUnits() {
        val form = TestSettingsForm.from(
            defaults.copy(pingIntervalMs = 60_499, downloadIntervalMs = 90_000, downloadCapBytes = 1_499_999, sessionBudgetBytes = 1_500_000),
        )
        assertEquals("60", form.pingIntervalS)
        assertEquals("2", form.downloadIntervalMin)
        assertEquals("1", form.downloadCapMb)
        assertEquals("2", form.sessionBudgetMb)
        assertEquals("61", TestSettingsForm.from(defaults.copy(pingIntervalMs = 60_500)).pingIntervalS)
        assertEquals("0", TestSettingsForm.from(defaults.copy(sessionBudgetBytes = -5)).sessionBudgetMb)
        assertEquals("", TestSettingsForm.from(defaults.copy(downloadUrl = null)).downloadUrl)
    }

    @Test
    fun parsingConvertsDisplayUnitsTrimsTextAndKeepsTheTimeout() {
        val base = defaults.copy(pingTimeoutMs = 3_000)

        val parsed = TestSettingsForm(" 10.0.2.2 ", "30", "3", " https://example.com/1mb ", "2", "1", "", "5", "2", "20").parse(base)

        assertEquals(
            TestSettingsParse.Valid(
                TestSettings(
                    pingTarget = "10.0.2.2",
                    pingIntervalMs = 30_000,
                    pingCount = 3,
                    pingTimeoutMs = 3_000,
                    downloadUrl = "https://example.com/1mb",
                    downloadIntervalMs = 120_000,
                    downloadCapBytes = 1_000_000,
                    sessionBudgetBytes = 20_000_000,
                ),
            ),
            parsed,
        )
    }

    @Test
    fun anEmptyTargetOrUrlTurnsThatTestOff() {
        val parsed = TestSettingsForm.from(defaults).copy(pingTarget = "  ", downloadUrl = " ", sessionBudgetMb = "0").parse(defaults)

        val settings = (parsed as TestSettingsParse.Valid).settings
        assertEquals("", settings.pingTarget)
        assertNull(settings.downloadUrl)
        assertEquals(0L, settings.sessionBudgetBytes)
    }

    @Test
    fun onlyPlainWholeNumbersParse() {
        listOf("", " ", "1.5", "1e3", "-5", "+5", "1,000", "１０", "1234567890").forEach { text ->
            assertNull(text, TestSettingsForm.parseWholeNumber(text))
        }
        assertEquals(42L, TestSettingsForm.parseWholeNumber(" 42 "))
        assertEquals(0L, TestSettingsForm.parseWholeNumber("0"))
        assertEquals(999_999_999L, TestSettingsForm.parseWholeNumber("999999999"))
    }

    @Test
    fun aFieldThatIsNotANumberIsReportedWithTheTextProblemsInFieldOrder() {
        val parsed = TestSettingsForm.from(defaults)
            .copy(pingTarget = "exa mple", pingIntervalS = "x", downloadUrl = "ftp://example.com/file")
            .parse(defaults)

        assertEquals(
            TestSettingsParse.Invalid(
                listOf(
                    TestSettingsProblem(TestSettingsField.PING_TARGET, TestSettingsProblemKind.INVALID_HOST),
                    TestSettingsProblem(TestSettingsField.PING_INTERVAL, TestSettingsProblemKind.NOT_A_WHOLE_NUMBER),
                    TestSettingsProblem(TestSettingsField.DOWNLOAD_URL, TestSettingsProblemKind.NOT_HTTPS),
                ),
            ),
            parsed,
        )
    }

    @Test
    fun valuesOutsideTheirRangeAreReported() {
        val base = TestSettingsForm.from(defaults)
        assertEquals(listOf(outOfRange(TestSettingsField.PING_INTERVAL)), problemsOf(base.copy(pingIntervalS = "9")))
        assertEquals(listOf(outOfRange(TestSettingsField.PING_INTERVAL)), problemsOf(base.copy(pingIntervalS = "3601")))
        assertEquals(listOf(outOfRange(TestSettingsField.PING_COUNT)), problemsOf(base.copy(pingCount = "0")))
        assertEquals(listOf(outOfRange(TestSettingsField.PING_COUNT)), problemsOf(base.copy(pingCount = "21")))
        assertEquals(listOf(outOfRange(TestSettingsField.DOWNLOAD_INTERVAL)), problemsOf(base.copy(downloadIntervalMin = "0")))
        assertEquals(listOf(outOfRange(TestSettingsField.DOWNLOAD_INTERVAL)), problemsOf(base.copy(downloadIntervalMin = "1441")))
        assertEquals(listOf(outOfRange(TestSettingsField.DOWNLOAD_CAP)), problemsOf(base.copy(downloadCapMb = "0")))
        assertEquals(listOf(outOfRange(TestSettingsField.DOWNLOAD_CAP)), problemsOf(base.copy(downloadCapMb = "1001")))
        assertEquals(listOf(outOfRange(TestSettingsField.SESSION_BUDGET)), problemsOf(base.copy(sessionBudgetMb = "10001")))

        val edges = base.copy(pingIntervalS = "10", pingCount = "20", downloadIntervalMin = "1440", downloadCapMb = "1000", sessionBudgetMb = "10000")
        assertTrue(edges.parse(defaults) is TestSettingsParse.Valid)
    }

    @Test
    fun aBudgetBelowOneDownloadIsReportedOnlyWhileTheDownloadIsOn() {
        val base = TestSettingsForm.from(defaults)
        val belowCap = TestSettingsProblem(TestSettingsField.SESSION_BUDGET, TestSettingsProblemKind.BUDGET_BELOW_CAP)

        assertEquals(listOf(belowCap), problemsOf(base.copy(downloadCapMb = "10", sessionBudgetMb = "5")))
        assertEquals(listOf(belowCap), problemsOf(base.copy(sessionBudgetMb = "0")))
        assertTrue(base.copy(downloadUrl = "", sessionBudgetMb = "0").parse(defaults) is TestSettingsParse.Valid)
        assertTrue(base.copy(downloadCapMb = "10", sessionBudgetMb = "10").parse(defaults) is TestSettingsParse.Valid)
    }

    @Test
    fun pingTargetsAreHostNamesOrIpv4Addresses() {
        listOf("8.8.8.8", "10.0.2.2", "0.0.0.0", "255.255.255.255", "localhost", "speed.cloudflare.com", "a-b.example", "xn--bcher-kva.example", "a")
            .forEach { host -> assertTrue(host, TestSettingsRules.isValidHost(host)) }
        listOf(
            "",
            "256.1.1.1",
            "1.2.3",
            "1.2.3.4.5",
            "1234.1.1.1",
            "http://8.8.8.8",
            "8.8.8.8:53",
            "exa mple.com",
            "-bad.com",
            "bad-.com",
            "a..b",
            "example.com.",
            "::1",
            "2001:db8::1",
            "host/path",
            "ex_ample.com",
            "a".repeat(64) + ".com",
            "a".repeat(254),
        ).forEach { host -> assertFalse(host, TestSettingsRules.isValidHost(host)) }
    }

    @Test
    fun downloadsNeedAnHttpsUrlWithAHost() {
        assertNull(TestSettingsRules.urlProblem(TestSettings.DEFAULT_DOWNLOAD_URL))
        assertNull(TestSettingsRules.urlProblem("HTTPS://Example.com/x"))
        listOf("http://example.com/file", "ftp://example.com/file", "speed.cloudflare.com/__down").forEach { url ->
            assertEquals(url, TestSettingsProblemKind.NOT_HTTPS, TestSettingsRules.urlProblem(url))
        }
        listOf("https://", "https:///path", "https://exa mple.com/", "https://example.com/a b").forEach { url ->
            assertEquals(url, TestSettingsProblemKind.INVALID_URL, TestSettingsRules.urlProblem(url))
        }
    }

    @Test
    fun theDownloadHostIsNamedForTheSettingsScreen() {
        assertEquals("speed.cloudflare.com", TestSettingsRules.downloadHost(TestSettings.DEFAULT_DOWNLOAD_URL))
        assertEquals("example.com", TestSettingsRules.downloadHost(" https://example.com/file "))
        assertNull(TestSettingsRules.downloadHost(null))
        assertNull(TestSettingsRules.downloadHost(""))
        assertNull(TestSettingsRules.downloadHost("not a url"))
        assertNull(TestSettingsRules.downloadHost("https://"))
        assertNull(TestSettingsRules.downloadHost("speed.cloudflare.com/__down"))
    }

    @Test
    fun storedRangesAreTheDisplayRangesInStoredUnits() {
        assertEquals(10_000L..3_600_000L, TestSettingsField.PING_INTERVAL.storedRange)
        assertEquals(1L..20L, TestSettingsField.PING_COUNT.storedRange)
        assertEquals(60_000L..86_400_000L, TestSettingsField.DOWNLOAD_INTERVAL.storedRange)
        assertEquals(1_000_000L..1_000_000_000L, TestSettingsField.DOWNLOAD_CAP.storedRange)
        assertEquals(0L..10_000_000_000L, TestSettingsField.SESSION_BUDGET.storedRange)
    }

    @Test
    fun storedSettingsOutsideTheRangesAreReported() {
        assertEquals(
            listOf(outOfRange(TestSettingsField.PING_COUNT), outOfRange(TestSettingsField.DOWNLOAD_INTERVAL)),
            TestSettingsRules.problems(defaults.copy(pingCount = -1, downloadIntervalMs = 0)),
        )
    }

    @Test
    fun anUntouchedFormHasNoUnsavedChanges() {
        assertFalse(TestSettingsForm.from(defaults).hasUnsavedChanges(defaults))
        // Stored values the rules reject, or that round to the text shown, are not edits until the text changes.
        val outOfRange = defaults.copy(pingCount = -1)
        assertFalse(TestSettingsForm.from(outOfRange).hasUnsavedChanges(outOfRange))
        val rounded = defaults.copy(pingIntervalMs = 60_499)
        assertFalse(TestSettingsForm.from(rounded).hasUnsavedChanges(rounded))
        assertTrue(TestSettingsForm.from(rounded).copy(pingIntervalS = "61").hasUnsavedChanges(rounded))
    }

    @Test
    fun editsStayUnsavedUntilTheSettingsHoldThem() {
        val form = TestSettingsForm.from(defaults)

        assertFalse("spaces and a leading zero change nothing", form.copy(pingIntervalS = " 060 ").hasUnsavedChanges(defaults))
        assertTrue(form.copy(pingIntervalS = "30").hasUnsavedChanges(defaults))
        assertTrue(form.copy(downloadUrl = "").hasUnsavedChanges(defaults))
        assertTrue("text that cannot be saved is still an edit", form.copy(pingIntervalS = "x").hasUnsavedChanges(defaults))

        val edited = form.copy(pingTarget = "10.0.2.2", pingIntervalS = "30")
        val saved = (edited.parse(defaults) as TestSettingsParse.Valid).settings
        assertFalse("once saved, the same text is no longer an edit", edited.hasUnsavedChanges(saved))
    }

    private fun problemsOf(form: TestSettingsForm): List<TestSettingsProblem> =
        (form.parse(defaults) as TestSettingsParse.Invalid).problems

    private fun outOfRange(field: TestSettingsField) = TestSettingsProblem(field, TestSettingsProblemKind.OUT_OF_RANGE)

    @Test
    fun uploadIsOffByDefaultAndItsFieldsStillShow() {
        val form = TestSettingsForm.from(defaults)
        assertEquals("", form.uploadUrl)
        assertEquals("5", form.uploadIntervalMin)
        assertEquals("2", form.uploadCapMb)
        assertEquals(TestSettingsParse.Valid(defaults), form.parse(defaults))
    }

    @Test
    fun anUploadUrlThatIsNotHttpsIsRejected() {
        val problems = TestSettingsRules.problems(defaults.copy(uploadUrl = "http://example.com/up"))
        assertEquals(listOf(TestSettingsField.UPLOAD_URL), problems.map { it.field })
    }

    @Test
    fun theBudgetMustHoldWhicheverTransferIsOn() {
        // Download off, upload on with a 2 MB cap and a 1 MB budget: the budget is the problem.
        val tooSmall = defaults.copy(
            downloadUrl = null,
            uploadUrl = "https://example.com/up",
            uploadCapBytes = 2_000_000,
            sessionBudgetBytes = 1_000_000,
        )
        assertEquals(
            listOf(TestSettingsField.SESSION_BUDGET),
            TestSettingsRules.problems(tooSmall).map { it.field },
        )
        // The same budget is fine once the upload is off again.
        assertTrue(TestSettingsRules.problems(tooSmall.copy(uploadUrl = null)).isEmpty())
    }

    @Test
    fun turningTheUploadOnIsAnUnsavedChange() {
        val form = TestSettingsForm.from(defaults)
        assertFalse(form.hasUnsavedChanges(defaults))
        assertTrue(form.copy(uploadUrl = "https://example.com/up").hasUnsavedChanges(defaults))
    }
}
