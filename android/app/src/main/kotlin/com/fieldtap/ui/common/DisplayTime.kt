package com.fieldtap.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.fieldtap.R
import com.fieldtap.ui.theme.Formats
import java.time.Instant
import java.time.ZoneId
import java.time.chrono.IsoChronology
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.Locale

/** How far a day lies before today, for naming it in a list: see [DisplayTime.dayDistance]. */
enum class DayDistance {
    TODAY,
    YESTERDAY,

    /** Two to six days before today: named by its weekday. */
    THIS_WEEK,

    /** Earlier this calendar year, or a day after today in it: named by month and day. */
    THIS_YEAR,

    /** Another year: named by its full date. */
    EARLIER,
}

/**
 * Times and small numbers for display, in the phone's zone and locale. Session files keep UTC; only the
 * screens convert. Pure, so it is unit-tested with a fixed zone and locale.
 *
 * Owner: workstream `ui-session`.
 */
object DisplayTime {
    /** "10 Sep 2026, 14:30" in [locale]'s medium date and short time. */
    fun dateTime(utcMs: Long, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(locale)
            .withZone(zone)
            .format(Instant.ofEpochMilli(utcMs))

    /** "14:30" in [locale]'s short time. */
    fun time(utcMs: Long, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
            .withLocale(locale)
            .withZone(zone)
            .format(Instant.ofEpochMilli(utcMs))

    /** "14:30:05" in [locale]'s medium time, for events that seconds matter to. */
    fun timeWithSeconds(utcMs: Long, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofLocalizedTime(FormatStyle.MEDIUM)
            .withLocale(locale)
            .withZone(zone)
            .format(Instant.ofEpochMilli(utcMs))

    /**
     * How far the day of [utcMs] lies before the day of [nowUtcMs] in [zone], for a list row that says "Today 6:19 PM",
     * "Yesterday 9:12 AM", "Wed 6:02 PM", "Sep 9" or "Sep 9, 2025". A day after today (a clock set back) is never
     * called today; it is named by its date.
     */
    fun dayDistance(utcMs: Long, nowUtcMs: Long, zone: ZoneId = ZoneId.systemDefault()): DayDistance {
        val day = Instant.ofEpochMilli(utcMs).atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(nowUtcMs).atZone(zone).toLocalDate()
        val days = ChronoUnit.DAYS.between(day, today)
        return when {
            days == 0L -> DayDistance.TODAY
            days == 1L -> DayDistance.YESTERDAY
            days in 2L..6L -> DayDistance.THIS_WEEK
            day.year == today.year -> DayDistance.THIS_YEAR
            else -> DayDistance.EARLIER
        }
    }

    /** "Wed": [locale]'s short weekday name. */
    fun weekday(utcMs: Long, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofPattern("EEE", locale).withZone(zone).format(Instant.ofEpochMilli(utcMs))

    /** "Sep 11": [locale]'s medium date without its year. */
    fun monthDay(utcMs: Long, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String {
        val pattern = DateTimeFormatterBuilder.getLocalizedDateTimePattern(FormatStyle.MEDIUM, null, IsoChronology.INSTANCE, locale)
        return DateTimeFormatter.ofPattern(withoutYear(pattern), locale).withZone(zone).format(Instant.ofEpochMilli(utcMs))
    }

    /** "Sep 11, 2026": [locale]'s medium date. */
    fun date(utcMs: Long, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
            .withLocale(locale)
            .withZone(zone)
            .format(Instant.ofEpochMilli(utcMs))

    /**
     * A localized date [pattern] without its year, and without the separators and quoted words that belong only to the
     * year: "MMM d, y" is "MMM d", "dd.MM.y" is "dd.MM", "y/MM/dd" is "MM/dd", "d 'de' MMM 'de' y" is "d 'de' MMM". A
     * pattern that would be left empty is returned whole.
     */
    fun withoutYear(pattern: String): String =
        YEAR_FIELD.replace(pattern, "").trim { it.isWhitespace() || it == ',' }.ifEmpty { pattern }

    private val YEAR_FIELD = Regex("""(\s*'[^']*')?[\s,./\-]*[yu]+[\s,./\-]*([年년]|'[^']*')?""")

    /** Milliseconds as seconds with one decimal, half up: 2000 is "2.0", 14050 is "14.1". */
    fun seconds(ms: Long, locale: Locale = Locale.getDefault()): String = Formats.oneDecimal(ms / 1000.0, locale)

    /** A share with one decimal ("88.3"), or null when it is unknown or not a finite number. */
    fun percent(value: Double?, locale: Locale = Locale.getDefault()): String? =
        value?.takeIf { it.isFinite() }?.let { Formats.oneDecimal(it, locale) }
}

/**
 * "Today 6:19 PM", "Yesterday 9:12 AM", "Wed 6:02 PM", "Sep 9", or "Sep 9, 2025" from another year: when
 * something was recorded, on one line of a row or in a screen's title.
 *
 * It lives here rather than beside the drives list because a signalling capture is asked the same question,
 * and a capture whose title read `20260915-130400` was answering a different one.
 */
@Composable
fun startedWords(utcMs: Long, nowUtcMs: Long): String = when (DisplayTime.dayDistance(utcMs, nowUtcMs)) {
    DayDistance.TODAY -> stringResource(R.string.sessions_when_today, DisplayTime.time(utcMs))
    DayDistance.YESTERDAY -> stringResource(R.string.sessions_when_yesterday, DisplayTime.time(utcMs))
    DayDistance.THIS_WEEK -> stringResource(R.string.sessions_when_weekday, DisplayTime.weekday(utcMs), DisplayTime.time(utcMs))
    DayDistance.THIS_YEAR -> DisplayTime.monthDay(utcMs)
    DayDistance.EARLIER -> DisplayTime.date(utcMs)
}
