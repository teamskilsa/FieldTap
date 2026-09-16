package com.fieldtap.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

/**
 * The 5gto6G launcher-and-signature tones. These are **not** the UI accent: the app's accent is the indigo
 * [FieldTapColorSchemes] `primary`, used on the primary action, selection and focus only. [BrandColors] is
 * confined to the launcher icon (`res/drawable/ic_launcher_*.xml`) and the [FieldTapBrandMark] signature on
 * the disclosure and About screens — never as a UI colour. A home-screen icon is an identity, so it stays a
 * blue-to-violet mark; the screens are Momentum indigo. `res/values/colors.xml` keeps these identical
 * (`BrandResourcesTest`).
 */
object BrandColors {
    /** The mark's deeper gradient blue. Launcher/signature only, never a UI accent. */
    val RadioBlue: Color = Color(0xFF2C33C7)

    /** The mark's violet, for the launcher/signature gradient. */
    val SixGViolet: Color = Color(0xFF7236BC)

    /** Launcher and signature gradient start (diagonal blue → violet). */
    val GradientStart: Color = Color(0xFF1D24C4)

    /** Launcher and signature gradient end. */
    val GradientEnd: Color = Color(0xFF5A2BD6)

    /** The sixth bar of the brand mark: the cyan spark that leaps higher. */
    val MarkAccent: Color = Color(0xFF7FE7FF)

    /** The first five bars of the brand mark. */
    val MarkBars: Color = Color(0xFFFFFFFF)
}

/**
 * The **Momentum** Material 3 colour schemes: bright, friendly and premium. Light is a calm scroll of pure
 * white cards on a cool light ground (`#EEF1F8`); dark is elevated blue-grey cards on a near-black
 * blue-grey ground (`#0E1017`). One accent runs through both — indigo `primary` (`#4F46E5` light, lightened
 * to `#AEB6FF` on dark), used **only** on the primary button, the selected state, the focus ring and the
 * RSRP trend line; a soft indigo container (`#E8E7FB` / `#312E81`) carries selected chips and tonal
 * buttons. Everything else is neutral or a functional signal/status colour. Dynamic (wallpaper) colour is
 * deliberately off, so the app looks the same on every phone.
 *
 * Depth is Momentum's, not flat: in light a visible-but-soft shadow lifts white cards off the ground (see
 * `Elevation`), in dark the card's lift over the ground plus a hairline carries the edge. The
 * `surfaceContainer*` roles are explicit values (`tonalElevation` is 0 everywhere), so Material never tints
 * a raised surface toward the accent — cards stay pure white in light and a clean blue-grey in dark.
 *
 * Every load-bearing text role meets WCAG AA (4.5:1) on every surface it can sit on, `outline` meets 3:1 on
 * the grounds it frames, and every signal mark meets 3:1 on the surface it rides; `ThemeContrastTest` proves
 * the numbers (see `DESIGN.md` §2.6 for the tightest guarded pairs).
 */
object FieldTapColorSchemes {
    val Light: ColorScheme = lightColorScheme(
        primary = Color(0xFF4F46E5),
        onPrimary = Color(0xFFFFFFFF),
        primaryContainer = Color(0xFFE8E7FB),
        onPrimaryContainer = Color(0xFF312E81),
        inversePrimary = Color(0xFFBEC2FF),
        secondary = Color(0xFF535B6B),
        onSecondary = Color(0xFFFFFFFF),
        secondaryContainer = Color(0xFFDEE2ED),
        onSecondaryContainer = Color(0xFF3A414F),
        tertiary = Color(0xFF674EAD),
        onTertiary = Color(0xFFFFFFFF),
        tertiaryContainer = Color(0xFFE8DEFB),
        onTertiaryContainer = Color(0xFF43356E),
        background = Color(0xFFEEF1F8),
        onBackground = Color(0xFF151A24),
        surface = Color(0xFFEEF1F8),
        onSurface = Color(0xFF151A24),
        surfaceVariant = Color(0xFFE3E6EE),
        onSurfaceVariant = Color(0xFF565E70),
        surfaceTint = Color(0xFF4F46E5),
        inverseSurface = Color(0xFF2C2F36),
        inverseOnSurface = Color(0xFFF0F2F6),
        error = Color(0xFFBA1A1A),
        onError = Color(0xFFFFFFFF),
        errorContainer = Color(0xFFFFDAD6),
        onErrorContainer = Color(0xFF93000A),
        outline = Color(0xFF737B8B),
        outlineVariant = Color(0xFFD6DBE6),
        scrim = Color(0xFF000000),
        surfaceBright = Color(0xFFFFFFFF),
        surfaceContainer = Color(0xFFF5F7FC),
        surfaceContainerHigh = Color(0xFFEDF0F7),
        surfaceContainerHighest = Color(0xFFE6E9F2),
        surfaceContainerLow = Color(0xFFFFFFFF),
        surfaceContainerLowest = Color(0xFFFFFFFF),
        surfaceDim = Color(0xFFDBDFEA),
        primaryFixed = FixedRoles.PrimaryFixed,
        primaryFixedDim = FixedRoles.PrimaryFixedDim,
        onPrimaryFixed = FixedRoles.OnPrimaryFixed,
        onPrimaryFixedVariant = FixedRoles.OnPrimaryFixedVariant,
        secondaryFixed = FixedRoles.SecondaryFixed,
        secondaryFixedDim = FixedRoles.SecondaryFixedDim,
        onSecondaryFixed = FixedRoles.OnSecondaryFixed,
        onSecondaryFixedVariant = FixedRoles.OnSecondaryFixedVariant,
        tertiaryFixed = FixedRoles.TertiaryFixed,
        tertiaryFixedDim = FixedRoles.TertiaryFixedDim,
        onTertiaryFixed = FixedRoles.OnTertiaryFixed,
        onTertiaryFixedVariant = FixedRoles.OnTertiaryFixedVariant,
    )

    /**
     * The instrument panel: near-black blue-grey grounds, one cyan accent, tabular numbers doing the
     * talking. It is the look of a spectrum analyser and of LTE Discovery, and for the same reason —
     * the values are the product, and a dark ground lets a coloured signal level be the brightest
     * thing on the screen instead of competing with a white card around it.
     */
    val Dark: ColorScheme = darkColorScheme(
        primary = Color(0xFF3DD6EA),
        onPrimary = Color(0xFF00262D),
        primaryContainer = Color(0xFF0E3A43),
        onPrimaryContainer = Color(0xFFC2F4FB),
        inversePrimary = Color(0xFF00687A),
        secondary = Color(0xFFA7B6C6),
        onSecondary = Color(0xFF1B2530),
        secondaryContainer = Color(0xFF26313D),
        onSecondaryContainer = Color(0xFFD5DEE8),
        tertiary = Color(0xFFB9A4FF),
        onTertiary = Color(0xFF26185A),
        tertiaryContainer = Color(0xFF362A6E),
        onTertiaryContainer = Color(0xFFE6DEFF),
        background = Color(0xFF090D12),
        onBackground = Color(0xFFE6EDF3),
        surface = Color(0xFF090D12),
        onSurface = Color(0xFFE6EDF3),
        surfaceVariant = Color(0xFF1D2530),
        onSurfaceVariant = Color(0xFF98A6B4),
        surfaceTint = Color(0xFF3DD6EA),
        inverseSurface = Color(0xFFE6EDF3),
        inverseOnSurface = Color(0xFF1B2530),
        error = Color(0xFFFF8A80),
        onError = Color(0xFF5C0A06),
        errorContainer = Color(0xFF5A1712),
        onErrorContainer = Color(0xFFFFDAD6),
        outline = Color(0xFF6B7886),
        outlineVariant = Color(0xFF232C37),
        scrim = Color(0xFF000000),
        surfaceBright = Color(0xFF28323E),
        surfaceContainer = Color(0xFF141B23),
        surfaceContainerHigh = Color(0xFF19212B),
        surfaceContainerHighest = Color(0xFF202934),
        surfaceContainerLow = Color(0xFF10161D),
        surfaceContainerLowest = Color(0xFF05080B),
        surfaceDim = Color(0xFF090D12),
        primaryFixed = FixedRoles.PrimaryFixed,
        primaryFixedDim = FixedRoles.PrimaryFixedDim,
        onPrimaryFixed = FixedRoles.OnPrimaryFixed,
        onPrimaryFixedVariant = FixedRoles.OnPrimaryFixedVariant,
        secondaryFixed = FixedRoles.SecondaryFixed,
        secondaryFixedDim = FixedRoles.SecondaryFixedDim,
        onSecondaryFixed = FixedRoles.OnSecondaryFixed,
        onSecondaryFixedVariant = FixedRoles.OnSecondaryFixedVariant,
        tertiaryFixed = FixedRoles.TertiaryFixed,
        tertiaryFixedDim = FixedRoles.TertiaryFixedDim,
        onTertiaryFixed = FixedRoles.OnTertiaryFixed,
        onTertiaryFixedVariant = FixedRoles.OnTertiaryFixedVariant,
    )

    /** The scheme for [dark]. */
    fun of(dark: Boolean): ColorScheme = if (dark) Dark else Light
}

/**
 * Material's "fixed" roles keep one value in light and dark, by definition. Derived from the indigo accent
 * container. They are unused by screens (this design's surfaces are explicit) but must be non-null, and
 * their on/container pairs still meet AA (`ThemeContrastTest`).
 */
private object FixedRoles {
    val PrimaryFixed = Color(0xFFE8E7FB)
    val PrimaryFixedDim = Color(0xFFBEC2FF)
    val OnPrimaryFixed = Color(0xFF312E81)
    val OnPrimaryFixedVariant = Color(0xFF332C86)
    val SecondaryFixed = Color(0xFFDEE2ED)
    val SecondaryFixedDim = Color(0xFFC3C6CF)
    val OnSecondaryFixed = Color(0xFF191C22)
    val OnSecondaryFixedVariant = Color(0xFF3A414F)
    val TertiaryFixed = Color(0xFFE8DEFB)
    val TertiaryFixedDim = Color(0xFFC4A9FF)
    val OnTertiaryFixed = Color(0xFF2A1A54)
    val OnTertiaryFixedVariant = Color(0xFF43356E)
}
