package com.fieldtap.core.settings

import com.fieldtap.core.nettest.TestSettings
import com.fieldtap.core.privacy.ConsentRecord
import com.fieldtap.core.privacy.PrivacyZone
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Everything the app remembers between launches. Stored as one JSON string in DataStore by
 * com.fieldtap.platform.settings.DataStoreSettingsRepository.
 *
 * Owner: workstream `location-privacy-core`.
 */
data class AppSettings(
    /** Random UUID made once per installation; `device.key` is `app:` plus it. Never ANDROID_ID. */
    val installId: String,
    /** Null until the disclosure is accepted, and again after consent is withdrawn. */
    val consent: ConsentRecord? = null,
    val tests: TestSettings = TestSettings(),
    val zones: List<PrivacyZone> = emptyList(),
    /** Whether the Start dialog's "run ping and download tests" starts ticked. Off by default. */
    val testsDefaultOn: Boolean = false,
    /** When the readiness check last ran; see `ReadinessPolicy.requiredBeforeSession`. */
    val readinessLastRunUtcMs: Long? = null,
    /** `started_utc` of the most recent session started on this install. */
    val lastSessionStartedUtcMs: Long? = null,
)

/**
 * JSON for [AppSettings]. Unknown keys are ignored and missing keys take defaults, so settings
 * survive app updates in both directions. A document that is not JSON, or has no usable
 * `install_id`, decodes to defaults with [newInstallId]'s value (consent is then absent, so the
 * disclosure is shown again rather than assumed).
 *
 * The document is one compact JSON object with snake_case keys:
 * `settings_version`, `install_id`, `consent` {`version`, `sha256`, `granted_utc_ms`} or null,
 * `tests` {`ping_target`, `ping_interval_ms`, `ping_count`, `ping_timeout_ms`, `download_url`,
 * `download_interval_ms`, `download_cap_bytes`, `session_budget_bytes`}, `zones`
 * [{`id`, `label`, `lat`, `lon`, `radius_m`}], `tests_default_on`,
 * `readiness_last_run_utc_ms`, `last_session_started_utc_ms`.
 *
 * Decoding field by field:
 * - A value of the wrong type counts as missing. Intervals, timeouts, the ping count and the cap must
 *   be positive and the budget not negative, else the default applies, so a damaged value can never
 *   make a test run in a tight loop.
 * - Text is kept exactly as written, blank included: a blank `ping_target` or `download_url` is how a
 *   test is switched off (see `TestSettings`). `download_url` may also be null, which switches the
 *   download off too; only a missing or mistyped value takes the default.
 * - A consent without a version, hash or grant time is absent.
 * - A zone without a numeric `lat`, `lon` and `radius_m` is dropped; a zone without an id gets a new
 *   random one; the order of zones is kept.
 *
 * Tests: round trip; unknown key; missing tests object; corrupt text; zones list order kept.
 *
 * Owner: workstream `location-privacy-core`.
 */
object AppSettingsCodec {
    /** Written as `settings_version`. Raised only if a key changes meaning; new keys need no change. */
    const val VERSION: Int = 1

    fun encode(settings: AppSettings): String = buildJsonObject {
        put(SETTINGS_VERSION, VERSION)
        put(INSTALL_ID, settings.installId)
        put(CONSENT, settings.consent?.let { encodeConsent(it) } ?: JsonNull)
        putJsonObject(TESTS) {
            val tests = settings.tests
            put(PING_TARGET, tests.pingTarget)
            put(PING_INTERVAL_MS, tests.pingIntervalMs)
            put(PING_COUNT, tests.pingCount)
            put(PING_TIMEOUT_MS, tests.pingTimeoutMs)
            put(DOWNLOAD_URL, tests.downloadUrl)
            put(DOWNLOAD_INTERVAL_MS, tests.downloadIntervalMs)
            put(DOWNLOAD_CAP_BYTES, tests.downloadCapBytes)
            put(SESSION_BUDGET_BYTES, tests.sessionBudgetBytes)
        }
        putJsonArray(ZONES) {
            for (zone in settings.zones) {
                addJsonObject {
                    put(ZONE_ID, zone.id)
                    put(ZONE_LABEL, zone.label)
                    put(ZONE_LAT, zone.lat)
                    put(ZONE_LON, zone.lon)
                    put(ZONE_RADIUS_M, zone.radiusM)
                }
            }
        }
        put(TESTS_DEFAULT_ON, settings.testsDefaultOn)
        put(READINESS_LAST_RUN_UTC_MS, settings.readinessLastRunUtcMs)
        put(LAST_SESSION_STARTED_UTC_MS, settings.lastSessionStartedUtcMs)
    }.toString()

    fun decode(text: String?, newInstallId: () -> String): AppSettings {
        val root = parseObject(text) ?: return AppSettings(installId = newInstallId())
        val installId = root.string(INSTALL_ID)?.takeIf { it.isNotBlank() }
            ?: return AppSettings(installId = newInstallId())
        return AppSettings(
            installId = installId,
            consent = root.obj(CONSENT)?.let { decodeConsent(it) },
            tests = root.obj(TESTS)?.let { decodeTests(it) } ?: TestSettings(),
            zones = root.array(ZONES)?.mapNotNull { element -> (element as? JsonObject)?.let { decodeZone(it) } }.orEmpty(),
            testsDefaultOn = root.boolean(TESTS_DEFAULT_ON) ?: false,
            readinessLastRunUtcMs = root.long(READINESS_LAST_RUN_UTC_MS),
            lastSessionStartedUtcMs = root.long(LAST_SESSION_STARTED_UTC_MS),
        )
    }

    private fun parseObject(text: String?): JsonObject? {
        if (text.isNullOrBlank()) return null
        return try {
            Json.parseToJsonElement(text) as? JsonObject
        } catch (e: IllegalArgumentException) {
            // kotlinx.serialization's SerializationException, thrown for malformed JSON, is one.
            null
        }
    }

    private fun encodeConsent(consent: ConsentRecord): JsonObject = buildJsonObject {
        put(CONSENT_VERSION, consent.version)
        put(CONSENT_SHA256, consent.sha256)
        put(CONSENT_GRANTED_UTC_MS, consent.grantedUtcMs)
    }

    private fun decodeConsent(obj: JsonObject): ConsentRecord? {
        val version = obj.string(CONSENT_VERSION)?.takeIf { it.isNotBlank() } ?: return null
        val sha256 = obj.string(CONSENT_SHA256)?.takeIf { it.isNotBlank() } ?: return null
        val grantedUtcMs = obj.long(CONSENT_GRANTED_UTC_MS) ?: return null
        return ConsentRecord(version = version, sha256 = sha256, grantedUtcMs = grantedUtcMs)
    }

    private fun decodeTests(obj: JsonObject): TestSettings {
        val defaults = TestSettings()
        return TestSettings(
            pingTarget = obj.string(PING_TARGET) ?: defaults.pingTarget,
            pingIntervalMs = obj.long(PING_INTERVAL_MS)?.takeIf { it > 0 } ?: defaults.pingIntervalMs,
            pingCount = obj.int(PING_COUNT)?.takeIf { it > 0 } ?: defaults.pingCount,
            pingTimeoutMs = obj.long(PING_TIMEOUT_MS)?.takeIf { it > 0 } ?: defaults.pingTimeoutMs,
            downloadUrl = when (val url = obj[DOWNLOAD_URL]) {
                null -> defaults.downloadUrl
                is JsonNull -> null
                is JsonPrimitive -> if (url.isString) url.content else defaults.downloadUrl
                else -> defaults.downloadUrl
            },
            downloadIntervalMs = obj.long(DOWNLOAD_INTERVAL_MS)?.takeIf { it > 0 } ?: defaults.downloadIntervalMs,
            downloadCapBytes = obj.long(DOWNLOAD_CAP_BYTES)?.takeIf { it > 0 } ?: defaults.downloadCapBytes,
            sessionBudgetBytes = obj.long(SESSION_BUDGET_BYTES)?.takeIf { it >= 0 } ?: defaults.sessionBudgetBytes,
        )
    }

    private fun decodeZone(obj: JsonObject): PrivacyZone? {
        val lat = obj.double(ZONE_LAT) ?: return null
        val lon = obj.double(ZONE_LON) ?: return null
        val radiusM = obj.double(ZONE_RADIUS_M) ?: return null
        return PrivacyZone(
            id = obj.string(ZONE_ID)?.takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString(),
            label = obj.string(ZONE_LABEL).orEmpty(),
            lat = lat,
            lon = lon,
            radiusM = radiusM,
        )
    }

    /** The primitive under [key], or null when it is absent, JSON null, an object or an array. */
    private fun JsonObject.primitiveAt(key: String): JsonPrimitive? =
        (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }

    private fun JsonObject.string(key: String): String? = primitiveAt(key)?.takeIf { it.isString }?.content

    private fun JsonObject.long(key: String): Long? = primitiveAt(key)?.takeUnless { it.isString }?.longOrNull

    private fun JsonObject.int(key: String): Int? = primitiveAt(key)?.takeUnless { it.isString }?.intOrNull

    private fun JsonObject.double(key: String): Double? =
        primitiveAt(key)?.takeUnless { it.isString }?.doubleOrNull?.takeIf { it.isFinite() }

    private fun JsonObject.boolean(key: String): Boolean? =
        primitiveAt(key)?.takeUnless { it.isString }?.booleanOrNull

    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

    private fun JsonObject.array(key: String): JsonArray? = this[key] as? JsonArray

    private const val SETTINGS_VERSION = "settings_version"
    private const val INSTALL_ID = "install_id"
    private const val CONSENT = "consent"
    private const val CONSENT_VERSION = "version"
    private const val CONSENT_SHA256 = "sha256"
    private const val CONSENT_GRANTED_UTC_MS = "granted_utc_ms"
    private const val TESTS = "tests"
    private const val PING_TARGET = "ping_target"
    private const val PING_INTERVAL_MS = "ping_interval_ms"
    private const val PING_COUNT = "ping_count"
    private const val PING_TIMEOUT_MS = "ping_timeout_ms"
    private const val DOWNLOAD_URL = "download_url"
    private const val DOWNLOAD_INTERVAL_MS = "download_interval_ms"
    private const val DOWNLOAD_CAP_BYTES = "download_cap_bytes"
    private const val SESSION_BUDGET_BYTES = "session_budget_bytes"
    private const val ZONES = "zones"
    private const val ZONE_ID = "id"
    private const val ZONE_LABEL = "label"
    private const val ZONE_LAT = "lat"
    private const val ZONE_LON = "lon"
    private const val ZONE_RADIUS_M = "radius_m"
    private const val TESTS_DEFAULT_ON = "tests_default_on"
    private const val READINESS_LAST_RUN_UTC_MS = "readiness_last_run_utc_ms"
    private const val LAST_SESSION_STARTED_UTC_MS = "last_session_started_utc_ms"
}
