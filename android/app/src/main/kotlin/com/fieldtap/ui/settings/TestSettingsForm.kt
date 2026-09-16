package com.fieldtap.ui.settings

import com.fieldtap.core.nettest.TestSettings
import java.net.URI
import java.net.URISyntaxException

/**
 * A field of the test settings form.
 *
 * @param unit stored units per display unit (milliseconds per second, bytes per MB in the decimal units of the
 *   "10 MB" cap).
 * @param displayRange the whole numbers that may be typed, in display units; empty for text fields.
 */
enum class TestSettingsField(val unit: Long, val displayRange: LongRange) {
    PING_TARGET(1, LongRange.EMPTY),

    /** Seconds. At least 10 s: 5 echoes with a 2 s timeout each take that long. */
    PING_INTERVAL(1_000, 10L..3_600L),
    PING_COUNT(1, 1L..20L),
    DOWNLOAD_URL(1, LongRange.EMPTY),

    /** Minutes. */
    DOWNLOAD_INTERVAL(60_000, 1L..1_440L),

    /** MB (1 000 000 bytes). */
    DOWNLOAD_CAP(1_000_000, 1L..1_000L),

    UPLOAD_URL(1, LongRange.EMPTY),

    /** Minutes. */
    UPLOAD_INTERVAL(60_000, 1L..1_440L),

    /** MB (1 000 000 bytes). Smaller than the download's: uplink is the dearer direction. */
    UPLOAD_CAP(1_000_000, 1L..200L),

    /** MB (1 000 000 bytes); 0 turns transfers off for the session. */
    SESSION_BUDGET(1_000_000, 0L..10_000L),
    ;

    /** [displayRange] in stored units. */
    val storedRange: LongRange get() = (displayRange.first * unit)..(displayRange.last * unit)
}

/** What is wrong with a test setting. */
enum class TestSettingsProblemKind {
    NOT_A_WHOLE_NUMBER,
    OUT_OF_RANGE,

    /** The ping target is neither a host name nor an IPv4 address (the ping uses IPv4 only). */
    INVALID_HOST,

    /** The download URL is not https. */
    NOT_HTTPS,

    /** The download URL does not parse, or has no host. */
    INVALID_URL,

    /** The session budget is smaller than one download, so no download could run. */
    BUDGET_BELOW_CAP,
}

/** One problem of the test settings, on [field]. */
data class TestSettingsProblem(val field: TestSettingsField, val kind: TestSettingsProblemKind)

/**
 * The rules for test settings the Settings screen saves. A blank ping target or download URL switches that test off
 * and is valid. Values are checked in stored units, so settings written by any version of the app can be checked.
 *
 * Owner: workstream `ui-setup`.
 */
object TestSettingsRules {
    private const val HTTPS = "https"
    private const val MAX_HOST_LENGTH = 253
    private const val IPV4_PARTS = 4
    private const val IPV4_MAX_PART = 255
    private val HOST_LABEL = Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")

    /** Every problem of [tests], in field order; empty when it may be saved. */
    fun problems(tests: TestSettings): List<TestSettingsProblem> {
        val problems = mutableListOf<TestSettingsProblem>()
        val target = tests.pingTarget.trim()
        if (target.isNotEmpty() && !isValidHost(target)) {
            problems += TestSettingsProblem(TestSettingsField.PING_TARGET, TestSettingsProblemKind.INVALID_HOST)
        }
        checkRange(problems, TestSettingsField.PING_INTERVAL, tests.pingIntervalMs)
        checkRange(problems, TestSettingsField.PING_COUNT, tests.pingCount.toLong())
        val url = tests.downloadUrl?.trim().orEmpty()
        val downloadOn = url.isNotEmpty()
        if (downloadOn) {
            urlProblem(url)?.let { kind -> problems += TestSettingsProblem(TestSettingsField.DOWNLOAD_URL, kind) }
        }
        checkRange(problems, TestSettingsField.DOWNLOAD_INTERVAL, tests.downloadIntervalMs)
        val capValid = checkRange(problems, TestSettingsField.DOWNLOAD_CAP, tests.downloadCapBytes)
        val uploadUrl = tests.uploadUrl?.trim().orEmpty()
        val uploadOn = uploadUrl.isNotEmpty()
        if (uploadOn) {
            urlProblem(uploadUrl)?.let { kind -> problems += TestSettingsProblem(TestSettingsField.UPLOAD_URL, kind) }
        }
        checkRange(problems, TestSettingsField.UPLOAD_INTERVAL, tests.uploadIntervalMs)
        val uploadCapValid = checkRange(problems, TestSettingsField.UPLOAD_CAP, tests.uploadCapBytes)
        val budgetValid = checkRange(problems, TestSettingsField.SESSION_BUDGET, tests.sessionBudgetBytes)
        // The budget has to hold whichever transfer is on; both spend it.
        val needed = listOfNotNull(
            tests.downloadCapBytes.takeIf { downloadOn && capValid },
            tests.uploadCapBytes.takeIf { uploadOn && uploadCapValid },
        ).maxOrNull()
        if (needed != null && budgetValid && tests.sessionBudgetBytes < needed) {
            problems += TestSettingsProblem(TestSettingsField.SESSION_BUDGET, TestSettingsProblemKind.BUDGET_BELOW_CAP)
        }
        return problems
    }

    /** A host name of letters, digits and hyphens, or a dotted IPv4 address; no scheme, port, path or spaces. */
    fun isValidHost(host: String): Boolean {
        if (host.isEmpty() || host.length > MAX_HOST_LENGTH) return false
        val labels = host.split('.')
        if (labels.all { label -> label.isNotEmpty() && label.all { it in '0'..'9' } }) {
            return labels.size == IPV4_PARTS && labels.all { label -> label.length <= 3 && label.toInt() <= IPV4_MAX_PART }
        }
        return labels.all { label -> HOST_LABEL.matches(label) }
    }

    /** Why [url] cannot be the download URL, or null when it is an https URL with a host. */
    fun urlProblem(url: String): TestSettingsProblemKind? {
        if (url.any { it.isWhitespace() }) return TestSettingsProblemKind.INVALID_URL
        val uri = try {
            URI(url)
        } catch (e: URISyntaxException) {
            return TestSettingsProblemKind.INVALID_URL
        }
        if (!HTTPS.equals(uri.scheme, ignoreCase = true)) return TestSettingsProblemKind.NOT_HTTPS
        if (uri.host.isNullOrBlank()) return TestSettingsProblemKind.INVALID_URL
        return null
    }

    /** The host [url] downloads from, for "Downloads from speed.cloudflare.com"; null when it has none. */
    fun downloadHost(url: String?): String? {
        val trimmed = url?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() }) return null
        return try {
            URI(trimmed).host?.takeIf { it.isNotBlank() }
        } catch (e: URISyntaxException) {
            null
        }
    }

    private fun checkRange(problems: MutableList<TestSettingsProblem>, field: TestSettingsField, value: Long): Boolean {
        if (value in field.storedRange) return true
        problems += TestSettingsProblem(field, TestSettingsProblemKind.OUT_OF_RANGE)
        return false
    }
}

/** The test settings form parsed: either settings that may be saved, or the problems to show. */
internal sealed interface TestSettingsParse {
    data class Valid(val settings: TestSettings) : TestSettingsParse

    data class Invalid(val problems: List<TestSettingsProblem>) : TestSettingsParse
}

/**
 * The test settings as typed: text for every field, in display units (seconds, minutes, MB). [from] shows stored
 * settings rounded half up to whole display units; [parse] turns the text back into settings, keeping what the form
 * does not edit (the ping timeout) from its base.
 */
internal data class TestSettingsForm(
    val pingTarget: String,
    val pingIntervalS: String,
    val pingCount: String,
    val downloadUrl: String,
    val downloadIntervalMin: String,
    val downloadCapMb: String,
    val uploadUrl: String,
    val uploadIntervalMin: String,
    val uploadCapMb: String,
    val sessionBudgetMb: String,
) {
    fun parse(base: TestSettings): TestSettingsParse {
        val numberProblems = mutableListOf<TestSettingsProblem>()
        fun number(text: String, field: TestSettingsField): Long? {
            val value = parseWholeNumber(text)
            if (value == null) numberProblems += TestSettingsProblem(field, TestSettingsProblemKind.NOT_A_WHOLE_NUMBER)
            return value
        }
        val pingInterval = number(pingIntervalS, TestSettingsField.PING_INTERVAL)
        val count = number(pingCount, TestSettingsField.PING_COUNT)
        val downloadInterval = number(downloadIntervalMin, TestSettingsField.DOWNLOAD_INTERVAL)
        val cap = number(downloadCapMb, TestSettingsField.DOWNLOAD_CAP)
        val uploadInterval = number(uploadIntervalMin, TestSettingsField.UPLOAD_INTERVAL)
        val uploadCap = number(uploadCapMb, TestSettingsField.UPLOAD_CAP)
        val budget = number(sessionBudgetMb, TestSettingsField.SESSION_BUDGET)
        val target = pingTarget.trim()
        val url = downloadUrl.trim().ifEmpty { null }
        val upUrl = uploadUrl.trim().ifEmpty { null }
        if (pingInterval == null || count == null || downloadInterval == null || cap == null ||
            uploadInterval == null || uploadCap == null || budget == null
        ) {
            val textProblems = TestSettingsRules.problems(
                base.copy(pingTarget = target, downloadUrl = url, uploadUrl = upUrl),
            ).filter { problem ->
                problem.field == TestSettingsField.PING_TARGET ||
                    problem.field == TestSettingsField.DOWNLOAD_URL ||
                    problem.field == TestSettingsField.UPLOAD_URL
            }
            return TestSettingsParse.Invalid((numberProblems + textProblems).sortedBy { it.field.ordinal })
        }
        val settings = base.copy(
            pingTarget = target,
            pingIntervalMs = pingInterval * TestSettingsField.PING_INTERVAL.unit,
            pingCount = count.toInt(),
            downloadUrl = url,
            downloadIntervalMs = downloadInterval * TestSettingsField.DOWNLOAD_INTERVAL.unit,
            downloadCapBytes = cap * TestSettingsField.DOWNLOAD_CAP.unit,
            uploadUrl = upUrl,
            uploadIntervalMs = uploadInterval * TestSettingsField.UPLOAD_INTERVAL.unit,
            uploadCapBytes = uploadCap * TestSettingsField.UPLOAD_CAP.unit,
            sessionBudgetBytes = budget * TestSettingsField.SESSION_BUDGET.unit,
        )
        val problems = TestSettingsRules.problems(settings)
        return if (problems.isEmpty()) TestSettingsParse.Valid(settings) else TestSettingsParse.Invalid(problems)
    }

    /**
     * True when this form holds edits that saving would apply to [saved]: its text is not how [saved] is shown, and it
     * does not parse to [saved]. Spaces or a leading zero are not edits, and neither is an untouched form over stored
     * values the rules no longer accept. Text that cannot be saved is an edit. The Settings screen asks before leaving
     * with such edits.
     */
    fun hasUnsavedChanges(saved: TestSettings): Boolean {
        if (this == from(saved)) return false
        val parsed = parse(saved)
        return parsed !is TestSettingsParse.Valid || parsed.settings != saved
    }

    companion object {
        /** Up to 9 digits, so a value times its unit never overflows. */
        private val WHOLE_NUMBER = Regex("[0-9]{1,9}")

        fun from(tests: TestSettings): TestSettingsForm = TestSettingsForm(
            pingTarget = tests.pingTarget,
            pingIntervalS = display(tests.pingIntervalMs, TestSettingsField.PING_INTERVAL),
            pingCount = tests.pingCount.toString(),
            downloadUrl = tests.downloadUrl.orEmpty(),
            downloadIntervalMin = display(tests.downloadIntervalMs, TestSettingsField.DOWNLOAD_INTERVAL),
            downloadCapMb = display(tests.downloadCapBytes, TestSettingsField.DOWNLOAD_CAP),
            uploadUrl = tests.uploadUrl.orEmpty(),
            uploadIntervalMin = display(tests.uploadIntervalMs, TestSettingsField.UPLOAD_INTERVAL),
            uploadCapMb = display(tests.uploadCapBytes, TestSettingsField.UPLOAD_CAP),
            sessionBudgetMb = display(tests.sessionBudgetBytes, TestSettingsField.SESSION_BUDGET),
        )

        /** A whole number of ASCII digits with surrounding spaces ignored, or null. */
        fun parseWholeNumber(text: String): Long? {
            val trimmed = text.trim()
            return if (WHOLE_NUMBER.matches(trimmed)) trimmed.toLong() else null
        }

        /** [stored] in [field]'s display unit, rounded half up; negative values show as 0. */
        private fun display(stored: Long, field: TestSettingsField): String {
            val value = stored.coerceAtLeast(0)
            val whole = value / field.unit
            val rest = value % field.unit
            return (if (rest * 2 >= field.unit) whole + 1 else whole).toString()
        }
    }
}
