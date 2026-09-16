# 5gto6G FieldTap design system — "Momentum"

The rules every screen follows. Tokens live in `ui/theme`, components in `ui/components`, and the one
entry point is `com.fieldtap.ui.FieldTapTheme`. Every component has `@FieldTapPreviews` previews: light,
dark, and font scale 1.3.

**Momentum** is a bright, friendly, premium consumer look: a calm scroll of pure-white rounded cards on a
cool light ground, real but soft shadow (never flat), one indigo accent, a **donut/ring gauge** for the
serving signal, soft tinted quality pills, and a rounded trend card with a soft indigo area under the RSRP
line. Light-first and daylight-legible, with a matching dark theme (elevated blue-grey cards on a near-black
blue-grey ground) that is a real equal, which walk mode forces. The type is **Hanken Grotesk** (a friendly
modern geometric sans, SIL OFL, bundled). The **functional signal-quality colours are data, not branding**,
and are kept exactly — the report route colours (`#1a9641` / `#a6d96a` / `#fdae61` / `#d7191c`).

## Principles

1. **Trust every number.** Live values use tabular figures (Hanken with `tnum`), show their age, grey out
   when stale, and show a dash (never 0) when unknown. Numbers never animate their value; the donut arc and
   the meter marker glide, the digits do not.
2. **Colour is never the only cue.** Every signal colour has its level word, every tone its mark, every
   state its words; the meter names its thresholds, the quality pill carries its dot and word.
3. **One obvious primary action, one hero number per screen.** The big full-width indigo button is the
   dominant control; the eye lands on the one big number (the donut on Live, `numeric.hero` in a card)
   first, and everything else steps down.
4. **One accent, no branded surfaces.** Indigo is used only where it must be; no identity colour on chrome,
   no accent-tinted card backgrounds. Dynamic colour is off, so the app looks the same on every phone.
5. **Friendly and modern.** Generous rounded cards with visible soft depth, roomy spacing, large targets
   (48 dp min, 64 dp primary button), plain language, calm standard motion — a best-in-class consumer app.

## Entry point

```kotlin
FieldTapTheme { /* activity content */ }     // follows the system light/dark setting
FieldTapTheme(darkTheme = true) { /* */ }    // walk mode: forces the dark surface; bar icons follow
```

Never wrap content in a bare `MaterialTheme`, never call `dynamicLightColorScheme`, never set system bar
colours yourself. The window theme (`res/values*/themes.xml`) paints the Compose surface colour, so launch
has no flash; `BrandResourcesTest` keeps `res/values/colors.xml` equal to the Kotlin tokens.

FieldTap's own components take their motion from the `Motion` token object (no-overshoot springs and short
cross-fades) and collapse every spec to `snap()` when the user has removed animations
(`rememberReducedMotion()`, from `Settings.Global.ANIMATOR_DURATION_SCALE`, exposed as
`LocalReducedMotion`), so their behaviour is unit-testable and independent of Material internals. The theme
uses the public, non-experimental `MaterialTheme(colorScheme, shapes, typography, content)` overload; bare
Material components (Switch, AlertDialog, the nav bar) keep Material's own default motion.

| Read | From |
| --- | --- |
| Material roles, type scale, shapes | `MaterialTheme.colorScheme`, `.typography`, `.shapes` |
| Status tones, recording, chart colours | `FieldTapDesign.colors` |
| Signal scale colours (incl. quality-pill fills) | `FieldTapDesign.signal.of(quality)` |
| Tabular number styles, `display` | `FieldTapDesign.numeric` |
| The uppercase tracked mini-label | the `Eyebrow` / `EyebrowTag` components (style: `SectionLabel`) |
| Spacing, sizes, shapes by role | `Spacing`, `Sizes`, `ShapeRoles` |
| Depth (soft shadow in light, lift in dark) | `Elevation`, and `cardShadowElevation()` / `tileShadowElevation()` / `cardHairline()` |
| Motion specs (reduced-aware) | `Motion.spatial/container/entry/effect(LocalReducedMotion.current)`, `Durations` |
| Icons | `FieldTapIcons` |
| Numbers as text | `Formats` |

No literal `Color(...)`, `dp`, `sp` or animation spec in screens: add a token here if one is missing.

## Colour

Light is a cool light ground (`#EEF1F8`) carrying **pure-white** cards; dark is a near-black blue-grey
ground (`#0E1017`) carrying elevated blue-grey cards (`#171A22`), a real equal. The **accent** — indigo
`primary` (`#4F46E5` light, lightened to `#AEB6FF` on dark, `onPrimary` white / dark respectively) — appears
in exactly four places and nowhere else:

1. the single **primary button** per screen (Start session, Allow, Run diagnostics, Save…), a big rounded
   full-width filled indigo control,
2. the **selected** state (nav item, chosen radio/segmented value, active tab, walk-mode-on circle),
3. the **focus** ring and the text cursor,
4. the **RSRP chart line** (RSRP is indigo; SINR is the muted violet `tertiary` `#674EAD` / `#C4A9FF`).

A soft indigo container (`primaryContainer` `#E8E7FB` / `onPrimaryContainer` `#312E81`) carries selected
chips and tonal buttons. Everything else is neutral (`onSurface` / `onSurfaceVariant`) or a functional
signal/status colour: top-bar icons, mini-labels and their leading icons, list chevrons, dividers,
switches-when-off. No accent-tinted card backgrounds, no accent headers. The signal colour is never the
accent.

- **Surfaces:** screen `background` (the cool ground); cards, tiles, rows, the floating action bar, sheets,
  the hero card and the top bar `surfaceContainerLow` (white in light); chart wells `surfaceContainerHigh` +
  an `outlineVariant` hairline; chips, meter tracks and the donut ring track `surfaceContainerHighest`.
- **Text:** `onSurface` (`#151A24` / `#E8EAF0`) for values and titles, `onSurfaceVariant`
  (`#565E70` / `#AAB2C0`) for mini-labels and secondary text.
- **Boundaries:** `outline` for control boundaries that must read (text-field border, meter-track edge,
  focus ring — ≥ 3:1); `outlineVariant` (a faint hairline) for the card frame, dividers, chart-well frame
  and the soft-pill chip border.
- **Depth (`Elevation`, `tonalElevation` always 0) — Momentum is not flat:** light cards = a real but soft
  `Elevation.Card` (6 dp) shadow lifting the white card off the ground, plus a faint `outlineVariant`
  hairline for crisp definition; tiles use the gentler `Elevation.Tile` (3 dp) so a tile inside a card does
  not shout. Dark cards = the hairline + the card's lift over the near-black ground, **no shadow** (shadows
  do not read on true dark). Raised surfaces (sheets, dialogs, the action bar, the scrolled top bar) use
  `Elevation.Raised` (12 dp). Chart wells are the hairline only. Use `cardShadowElevation()`,
  `tileShadowElevation()` and `cardHairline()`.
- **Status tones** (`StatusTone`, `FieldTapDesign.colors.status(tone)`, icon `statusIcon(tone)`): NEUTRAL;
  INFO (the indigo accent); SUCCESS (granted, ready, 2 s cadence); WARNING (works but worse: 10 s cadence,
  an aging sample, advice); ERROR (blocked, failed, stale, lost). Each family has `color`, `onColor`,
  `container` and `onContainer`. The tonal `container`/`onContainer` fill is used **only** for WARNING and
  ERROR banners; calm tones sit on a plain card.
- **Recording** (`colors.recording`) is the running session, its own crimson family — never `error`.
- **Charts:** RSRP `chartRsrp` (indigo accent, with a soft indigo area fill), SINR `chartSinr` (violet),
  decorative grid `chartGrid`, dashed threshold `chartReference` (`outline`), solid −105 dBm key line
  `chartKeyReference` (`onSurfaceVariant`).

`ThemeContrastTest` proves the palette in light and dark on the surfaces each thing is placed on: text roles
≥ 4.5:1 on every surface; status words, signal `content` and quality-pill text ≥ 4.5:1; signal `fill`/`edge`,
chart lines and `outline` ≥ 3:1 on the grounds they frame; `onPrimary` ≥ 4.5 on `primary`. The tightest
pairs (guarded explicitly, §2.6) sit on the cool ground (`outline` 3.76), a white card (FAIR edge 4.25), a
dark card (POOR edge 4.64), the light well (chart SINR 5.63), the chip track (GOOD content 5.25, dark POOR
content 6.21, `onSurfaceVariant` 5.36) and the soft quality pills (EXCELLENT 4.57, GOOD 4.60) — change a
colour only with the test green.

## Signal scale

One scale, `SignalScale`, identical to the report's route colours, with the same thresholds for LTE and NR.
**Frozen** — reviewers must not neutralise it, and it must match `fieldtap/report.py`; it is data.

| Level | RSRP (dBm) | RSRQ (dB) | SINR (dB) | Fill | Quality pill (light) |
| --- | --- | --- | --- | --- | --- |
| EXCELLENT | >= -85 | >= -10 | >= 20 | #1a9641 green | `#DCFCE7` / `#15803D` |
| GOOD | >= -95 | >= -15 | >= 13 | #a6d96a light green | `#ECFCCB` / `#4D7C0F` |
| FAIR | >= -105 | >= -20 | >= 0 | #fdae61 orange | `#FEF3C7` / `#92400E` |
| POOR | below | below | below | #d7191c red (#f0443e dark) | `#FEE2E2` / `#B91C1C` |

- `SignalScale.quality(metric, value)` is null for an unknown value: show the neutral swatch and the
  unknown word.
- `SignalLevelColors`: `fill` for swatches, bars and the donut arc (never text); `edge` around a fill, which
  keeps 3:1 where the pale green and orange are too light; `onFill` for text on a fill; `content` for the
  level word on a surface; `pillContainer` / `onPillContainer` for the Momentum **quality pill** — a soft
  tinted fill with readable text (the pill's leading dot is still the exact report `fill` over its `edge`,
  so the true colour is always on screen).
- Display ranges are for drawing only (RSRP -140..-40, RSRQ -30..0, SINR -25..40). Text always shows the
  measured value. The donut arc sweeps the value's position in the display range; the centred number is the
  reading. The emphasised reference line is -105 dBm (0 dB for SINR).
- A signal meter spans `SignalScale.barRange` (RSRP -130..-50); a Live chart panel spans
  `ChartMath.fittedRange`. `SignalScale.zones(metric, range)` gives the zones either draws.
- Build one `SignalQualityLabels` per screen from string resources and pass `labels.of(quality)`.

## Typography

**Hanken Grotesk**, a friendly modern geometric sans (SIL OFL — the licence ships at
`assets/fonts/HankenGrotesk-OFL.txt`), bundled as one variable `ttf`
(`res/font/hanken_grotesk_variable.ttf`) and pinned to each weight through `FontVariation` (minSdk 31, so
the `wght` axis is honoured everywhere). It is the app's default `FontFamily`; sizes stay in sp so text
follows the user's font scale. Momentum weight: **ExtraBold (800)** display/headline/`titleLarge` and the
big numbers, **Bold (700)** titles and other numbers, **SemiBold (600)** labels, Regular body. *(If bundling
ever breaks the build, swap `HankenGrotesk` for `FontFamily.Default`: the Momentum feel is carried by shape,
colour, spacing and depth.)*

The **mini-label** (`Eyebrow` component; style `SectionLabel`, from `labelMedium` + Bold + `0.08em`
tracking) is the signature small-caps overline of the mockup: the component **uppercases** the text and
tracks it, in `onSurfaceVariant` — callers pass ordinary sentence-case strings ("Serving cell", "Band /
ARFCN") and TalkBack still hears the natural case. `EyebrowTag` is a subtle identity pill (`NR N78`, `PLMN
311480`), text as-is (acronym identifiers stay uppercase because that is how they are written).

| Numeric style | Use |
| --- | --- |
| `numeric.display` 56 sp | The Live serving-RSRP hero; rendered with `TextAutoSize` (min 36 sp) so it shrinks, never clips |
| `numeric.hero` 44 sp | The donut centre and session-detail median RSRP: the hero within a card |
| `numeric.large` 32 sp | Metric-tile / stat-tile values |
| `numeric.medium` 22 sp | Compact tiles, elapsed time, statistics |
| `numeric.body`, `numeric.bodySmall` | Values in rows and lists |
| `numeric.label` | Badges, chips, units |
| `numeric.axis` | Chart axes |

The big numbers are ExtraBold Hanken with tight tracking. Units (`dBm`, `dB`) render one step down in
`onSurfaceVariant`. Exactly one `display`/`hero` figure per screen. Any other changing number:
`MaterialTheme.typography.titleSmall.tabular()`. All numeric styles keep tabular figures.

## Shape, spacing, size, motion

- `ShapeRoles`: `Tile` (18 dp) for tiles/wells, list rows and chart panels; `Card` (24 dp) for section
  cards, banners, the hero card and the floating action bar; `Sheet` (28 dp) for sheets and dialogs;
  `Field` (14 dp) for text fields; `Control` (16 dp) for buttons (rounded rectangles, incl. the big
  primary); `Pill` for badges, chips and identity tags; `Bar` (4 dp) for the signal meter and bar tracks.
- `Spacing` is a 4 dp grid: `ScreenGutter` 20 dp (`ScreenGutterWide` 32 dp from 600 dp), `SectionGap` 20 dp
  between cards, `ItemGap` 12 dp and `CardPadding` 20 dp inside them, `EyebrowGap` 6 dp.
- `Sizes.MinTouchTarget` (48 dp) for everything tappable; `PrimaryButtonHeight` 64 dp; `DonutHero` 132 dp
  (the serving-RSRP ring), `DonutCompact` 96 dp. Cap content at `Sizes.MaxContentWidth` (720 dp), centred,
  on tablets and in landscape; prose at `Sizes.MaxTextWidth`.
- A window at least `Sizes.WideLayoutMinWidth` wide and lower than `Sizes.ShortWindowMaxHeight` (a phone in
  landscape) moves primary actions to a `Sizes.ActionRailWidth` (168 dp) column beside the content.
- Never let a separator (" · ") end a line: break a two-part value with "\n".
- **Motion** — calm and standard, never showy. `Durations`: SHORT 150, MEDIUM 250, LONG 400 ms. `Motion`
  gives critically-damped, **no-overshoot** springs (`spatial` for position, the meter marker and the donut
  arc; `container` for resize; `entry` a calm settle for one-shot appearance — no bounce) and an `effect`
  tween for colour/opacity cross-fades. Numbers never tween their value. Each spec takes
  `LocalReducedMotion.current`: when animations are removed, every spec collapses to `snap()`.

## Icons, words, numbers

- `FieldTapIcons` are 24 dp line icons. An icon that stands alone needs a content description; pass null
  when a label beside it says the same.
- Components take every user-facing word as a parameter and add no strings. Screens take the words from
  their own files (`strings_session_ui.xml`, `strings_setup_ui.xml`).
- `Formats` makes the numbers; the words around them come from resources. `ageSeconds(ms)` gives "2.1";
  `elapsed` "12:34" or "1:02:03"; `decimalBytes` "4.2 MB"; `oneDecimal` "88.3". Signal values are plain
  integers, and unknown stays null.

## Components

| Component | Use it for |
| --- | --- |
| `FieldTapTopBar`, `TopBarAction`, `TopBarToggleAction`, `rememberTopBarScroll` | Every screen's top bar; neutral icon actions. A 1 px hairline fades in once content scrolls under it. `TopBarToggleAction` sits in a tonal accent circle when on (walk mode). |
| `SignalDonut`, `SignalDonutHero` | The Momentum signature: the serving RSRP as a **donut/ring gauge** — a `surfaceContainerHighest` track with a rounded arc in the quality's report colour, swept to the value's position, the big centred value + unit in the hole (auto-sized). `SignalDonutHero` is the white hero card pairing the donut with the mini-label, a soft `SignalQualityChip` and the age. The arc glides; the number never animates. |
| `MetricTile`, `MetricGrid` | A live value with an uppercase `Eyebrow` label, unit, quality chip, age badge and optional `footer` (a `SignalMeter`). `MetricEmphasis.HERO` is an open block; other tiles are white rounded wells (hairline + a soft tile shadow). `MetricGrid(minCellWidth, maxColumns)` keeps a 2-up tile grid at font scale 1.3. |
| `SecondaryMetricTile` | Two under a hero: RSRQ and SINR. A value the cell does not report is one 48 dp line ("Not reported"), no dash. |
| `AgeIndicator` | "2.1 s old": FRESH neutral, AGING WARNING with a timer, STALE ERROR with a warning. A soft tonal pill. |
| `Eyebrow`, `EyebrowTag` | The uppercase tracked mini-label (`heading = true` makes it a TalkBack heading); `EyebrowTag` a subtle identity pill. |
| `SignalQualityChip`, `SignalQualityLabels` | The Momentum **quality pill** — a soft tinted fill, a signal dot and the level word — wherever a signal colour appears. |
| `SignalMeter` (was `SignalBar`) | The flat, labelled four-zone gauge over `SignalScale.barRange`, edge-stroked, with a neutral `onSurface` marker that glides, and the thresholds ticked and labelled from 280 dp wide, the -105 key tick heavier. |
| `SpectrumStrip` | The session-at-a-glance route verdict: one proportional stacked bar of the four route colours; a `SignalQualityChip` legend beneath. |
| `CellSignalRow`, `SignalBars` | A neighbour or the NSA leg: bars, identity, value, level word. |
| `CadenceIndicator`, `cadenceTone` | Soft pill: "2 s" (success) or "10 s" (warning), with the reason. |
| `StatusBanner` | A bordered banner: tone `color` for the leading icon, the tonal `container` fill **only** for WARNING/ERROR; calm tones on a plain card. Optional accent fix button. |
| `StatusChip` | Soft white pills side by side: service, data, 5G icon, GPS, cadence. Tone lives in the leading mark and the word. Tabular text. |
| `FieldTapFloatingActionBar` | The inset raised `Surface` holding a screen's primary actions in portrait; the `ActionRailWidth` column replaces it in a short, wide window. |
| `SectionCard`, `KeyValueRow`, `SectionDivider` | Titled groups of labelled values; the header is an uppercase `Eyebrow` with a neutral leading icon. `KeyValueRow(stacked, selectable)` for a SHA-256 or a URL; `itemGap`/`minHeight` for a dense card. |
| `ToggleRow`, `RadioRow`, `NavigationRow` | Settings rows: switch-on = accent; selected radio = accent ring; `NavigationRow` a neutral trailing chevron. |
| `ChecklistRow` | A check with its level and fix: Readiness items, findings. |
| `ReadinessSheet`, `ReadinessSheetContent`, `ReadinessProblems` | The pre-start sheet: named problems with fixes, blocking first, "Start anyway" only when nothing blocks. |
| `SessionButton`, `RecordingDot` | The one dominant primary action: a big rounded full-width filled indigo `Control`, 64 dp tall, in the action bar. Start → Starting → Recording (elapsed + Stop) → Stopping. The recording dot is a gentle steady pulse; steady under reduced motion. Confirm Stop in a dialog. |
| `SignalHistoryChart`, `TimeSeriesChart`, `ChartMath` | Five minutes of RSRP and SINR over a neutral rounded well: a faint zone tint (≤ 12 %), 1 dp dashed threshold lines and a solid `chartKeyReference` -105 line, the indigo RSRP line with a **soft indigo area fill**, the violet SINR line, gaps left open, and a TalkBack summary. |
| `SessionListRow`, `RecordingChip` | A recording on one 72 dp rounded card row: status badge (`icon` overrides it for a signalling capture's waveform), name with its `SignalQualityChip` ("Good -92") or `RecordingChip`, and one line of start, duration and size. |
| `ViewSwitcher` | Equal-width segments picking which view of one screen is shown (Live: Signal / Cell / Neighbours). The chosen segment wears the `primaryContainer` pill, the same mark the bottom bar puts under the chosen tab. Three or four at most; it is not navigation and not a list filter. |
| `EmptyState`, `LoadingState` | Nothing to show, waiting, or could not load. A neutral badge, plain copy, an indigo primary button when there is an action. |
| `PermissionRationale` | A permission, why it is needed (neutral tonal icon circle), its status, and an accent fix button. |
| `LimitsStatementCard` | `R.string.limits_statement`, word for word, never truncated. |
| `FieldTapBrandMark` | The 5gto6G mark, on the disclosure and About screens only — a small signature, not a UI accent. |
| `PreviewSurface`, `@FieldTapPreviews` | Every preview, of components and screens alike. |

The theme already styles the Material components it does not wrap, so use them as they come: `Scaffold`,
`AlertDialog` (`Sheet` shape, `Elevation.Raised`), `OutlinedTextField`, `Button`, `TextButton`, `Snackbar`.
Pass `shape = ShapeRoles.Control` to a `Button`/`OutlinedButton`/`FilledTonalButton`. The one filled indigo
`Button` per screen lives in the `FieldTapFloatingActionBar`.

## Brand assets

- Launcher: the adaptive icon `mipmap-anydpi/ic_launcher.xml` (and `ic_launcher_round.xml`), with the
  5gto6G blue-to-violet gradient background and the mark as foreground (five bars + a `#7FE7FF` sixth). This
  is a home-screen identity, not the app's chrome; the app's UI is Momentum indigo. The launcher hexes live
  in `res/values/colors.xml` = `BrandColors`.
- Window/splash: `res/values*/themes.xml` paint the `surface` ground (`#EEF1F8` / `#0E1017`) and the accent
  `colorPrimary`/`colorAccent` (`#4F46E5` / `#AEB6FF`), kept equal to the Kotlin tokens by
  `BrandResourcesTest`.
- Notification: `R.drawable.ic_stat_fieldtap`, a flat silhouette for `setSmallIcon`.
- `FieldTapBrandMark` draws the mark in Compose for the disclosure and About screens.

## Accessibility checklist

- TalkBack: tiles, rows and chips read as one phrase; mini-labels are headings; the donut and chart read
  their summary; WARNING and ERROR banners announce themselves. Never put a live region on a value that ticks.
- 48 dp targets, no information by colour alone, and AA contrast from the tokens in both themes.
- Check every screen in its `@FieldTapPreviews`, in landscape, and with TalkBack. Numbers shrink to fit
  rather than clip; rows wrap.

## Tests

`app/src/test/kotlin/com/fieldtap/ui/theme` and `.../ui/components`: contrast (re-baselined for Momentum,
the tightest pairs and the quality pills guarded), the signal scale, number formats, brand resources against
the XML, the motion contract (physical specs by default, `snap()` under reduced motion), chart and grid
arithmetic, and the component decisions (age and cadence tones, readiness ordering, level words).
