# The simulator harness (WP7)

`sim-verify.sh` runs FieldTap in the `$FT_SIM_NAME` simulator on the user's real sysdiagnose, read in place
from `~/Downloads` (never copied), through the app's own importer and analyzer. It then screenshots every
screen. Each screen is gated on the values its screen report states, not on the PNG's size: a placeholder
screen is as large as a real one (the seed screens came out at 580 KB).

Everything here is DEBUG/Harness only. `App/Debug` is compiled under `#if DEBUG || FT_HARNESS`, and a Release
app contains none of it (see "Release carries no hooks" below). Harness is the Release-optimised configuration
with `FT_HARNESS` set for the app module only, so the timings are close to what a user would see.

## Commands

```sh
export FT_WP=wp7                                  # or your package; build products go to $FT_TMP
source ios/scripts/env.sh

# 1. The archive route alone (no decoder needed): 135 Baseband files, 130 chunks, adler32 a0e39d83.
ios/scripts/sim-verify.sh --stage scan --sysdiagnose "$FT_SYSDIAGNOSE"

# 2. The whole pipeline and the 18 screens (the integration gate, once WP2-WP6 have merged).
ios/scripts/sim-verify.sh --stage full --sysdiagnose "$FT_SYSDIAGNOSE" --shots "$FT_TMP/shots"

# Both in one run; keep the build and the booted simulator while iterating; only some shots:
ios/scripts/sim-verify.sh --stage all --keep-build --keep-sim
ios/scripts/sim-verify.sh --stage full --no-build --keep-build --only overview,radio-nr,message-18

# The checker on its own:
python3 ios/scripts/check_sim_analysis.py "$FT_TMP/shots/analysis.json" ios/Fixtures/expected/sim-analysis.json
```

Options: `--config Harness|Debug` (default Harness; Release has no hooks), `--capture auto|import|fixture`,
`--timeout SEC` (import, default 240), `--shots DIR` (default `$FT_TMP/shots`; refused inside the repo except
under the git-ignored `Fixtures/local`), `--keep-build`, `--keep-sim`, `--no-build`, `--only NAME,...`.

The script builds in a build slot (`build-app.sh`), then holds the simulator lock for the whole run, so no
other agent's shot lands in the middle of an import. It uninstalls and reinstalls `com.fieldtap.ios` first. At
the end it runs `privacy-gate.sh --scan` over every output file, checks that the archive's size and
modification time did not change, uninstalls the app (removing the imported capture from the container), shuts
the simulator down and deletes `$FT_TMP/dd`. It prints a summary with the elapsed time and the change in free
disk space (other agents' builds count in that number too). It exits 0 only when every check passed.

### What each stage does

**scan**: `SIMCTL_CHILD_FT_FEED_PATH=<archive> xcrun simctl launch ... -FTScanOnly`. `DebugHooks` streams the
archive through `SysdiagScanner` and writes `Documents/ft-debug/scan.json`. The script checks it against
`Fixtures/expected/sim-scan.json`. This works before any other package merges.

**full**:
1. `SIMCTL_CHILD_FT_FEED_PATH=<archive>`, no other argument. `DebugHooks` calls
   `app.importer.importArchive(at:securityScoped: false)` on the host file, so the importer stores the
   capture in the container. It writes `import.json` as the progress events arrive, then runs the `Analyzer`
   on the imported records and writes `analysis.json`. The script waits up to `--timeout` seconds for
   `analysis.json` and checks it against `Fixtures/expected/sim-analysis.json`.
2. For each shot in `Fixtures/expected/sim-screens.json`, the script calls `sim-shot.sh`, which relaunches the
   app with the shot's arguments after the capture's own. For a capture page that is `-FTOpenLatest` (the
   stored import). It waits for the screen report with `"ready": true`, screenshots, and copies the report next
   to the PNG. The script then checks the report against the shot's `expect`.
3. With `--capture auto` (the default), a failed import makes the shots use `-FTFixture $FT_FIXTURES`
   instead, so the screens are captured with whatever has merged. The script also writes
   `analysis-fixture.json` (`-FTDumpAnalysis`) and checks it for information. The run still fails.

### The 18 shots

captures; guide; settings; overview; callflow ALL; callflow NAS; message 82 (the handover command); message 18
(identity response: bytes hidden); radio signal, dl, ul, csi, nr, antennas, carriers (cursor 15.5 s, PCell +
3 SCells), rach (added by the critique), unavailable; overview at cursor 15040 (B66 PCell, NR leg just ended).

## Launch hooks (App/Debug)

| Input | Effect |
| --- | --- |
| env `FT_FEED_PATH=<path>` (`SIMCTL_CHILD_FT_FEED_PATH` via simctl) | import that host file in place before the launch plan: `import.json`, `analysis.json` |
| `-FTScanOnly` (with `FT_FEED_PATH`) | only stream the archive: `scan.json` |
| `-FTDumpAnalysis` (with `-FTFixture DIR`) | also write `analysis-fixture.json` for the loaded fixture |
| the `LaunchPlan` arguments (`-FTScreen`, `-FTFixture`, `-FTOpenLatest`, `-FTCursorMs`, `-FTEvent`, `-FTFilter`, `-FTRadioSection`, `-FTImportState`, `-FTGuideState`) | as in ios/README.md |

All files go to the app's `Documents/ft-debug/` (`xcrun simctl get_app_container <udid> com.fieldtap.ios data`).
`sim-shot.sh` clears that folder before each launch.

## Files

**`scan.json`**: `ok`, `compressedBytes`, `uncompressedBytes`, `tarEntries`, `basebandFiles`, `basebandBytes`,
`adler32Hex`, `appleDoubleSkipped`, `qdssChunks`, `qdssDirs`, `profileStubs` (counted, not read), `ambtoolLog`,
`basebandLoggingEnabled` (false when ambtool_output.log says the logs are not enabled; R1), `seconds`.

**`import.json`**: `state` (running, done, failed), `archiveBytes`, `elapsedS`, `stageSeconds` (from each
stage's first progress event to the next stage's), `progressEvents`, `events` (every stage change, then at
most one event per stage every 0.5 s), `error`. It is rewritten as the import runs, at most twice a second.

**`analysis.json`** (`AnalysisReport`; counts, kinds and ids only):
- `source` (import or fixture), `ok`, `error`
- `capture`:
  - `records`, `distinctCodes`, `crcErrors`
  - `qmdlMd5` and `qmdlBytes` of the stored capture.qmdl, and `storedRecords` (read back through the store,
    as the screens read it)
  - `chunkCount`, `chunkBytes`, `traceDirFound`, `hasTrace`, `problems` (ImportProblem tokens)
  - `basebandLoggingEnabled`, and `profile` (status when the archive was taken, lifetime, consent days)
  - R2: `traceWindowAfterPressMs`, `overwrittenFiles`, `listedFiles`
  - `deframe` (the compared DeframeStats keys), `secure` (census), `durationMs`, `hasDigest`, `hasPreview`
- `flow`:
  - `records`, `undecoded`, `crcErrors`, `durationMs`, `startUtcKnown`
  - `events` and `eventsByLayerRatDirection` ("RRC/lte/UL")
  - `pendingNrEvents` (D4), `failures`, `procedures`, `procedureOutcomes`
  - `steps` (moves), `connections` (outcomes), `cellDetails`, `searched`
- `phy`:
  - `samples` for all 48 PhyMetric cases (0 when missing) and `versionMisses`
  - `checks`, `checksPassed`, `checksFailed` (ids), `availability`
  - `scellActivity`, `nrDlRecords`, `nrDlEarfcnKnown`, `rach`, `rachTa`, `txAntennasMib`, `rxAntennaEarfcns`,
    `encrypted`
- `journey`:
  - `lanes` (state, registration, pcell, pscell, scell), `states`, `registration`, `pcellBands`,
    `pscellBandCandidates`
  - `markers`, `markersByKind`, `failureMarkers`, `markerIdsUnique`
  - `findings`, `findingIds`, `findingKinds`, `findingKindsTail`, `findingIdsUnique`
  - `tiles` (id -> "succeeded/attempts")
- `run` (never compared exactly): `config`, `feedBytes`, `importSeconds` (bounded at 240 s), `analyzeSeconds`,
  `reportSeconds`, `stageSeconds`, `importerTimings` (CaptureSummary.timings), `progressEvents`, and for
  fixtures `flowSource` / `phySource`.

Doubles are rounded to 3 decimals. That is how the goldens print them, and a raw Double's 17 significant
digits would be a digit run the privacy gate treats as an identifier.

**`screen-<route>[-<qualifier>].json`** (`ScreenReport`): `route`, `qualifier` (the event for message, the
section for radio), `rendered`, `ready`, `captureId` (the first 8 hex digits of the capture's UUID: a random
UUID's last group can be 12 decimal digits), `cursorMs`, and `values`:

| Route | values |
| --- | --- |
| captures | `cardCount`, `fixtureLoaded`, `guideStatus`, `latestProblems`, `latestHasTrace`, `latestHasDigest` |
| guide | `status` (GuideState token), `needsAttention`, `daysLeft`, `profileStatus`, `overridden` |
| settings | `revealIdentifiers`, `captureCount` |
| importSheet | `importState`, `pending` |
| overview | `findingIds`, `findingCount`, `markerCount`, `tileCount`, `eventCount`, `procedureCount`, `pcellBandAtCursor`, `pscellAtCursor`, `scellsAtCursor` |
| callflow | `filter`, `rowCount`, `firstRowIds` (5), `eventCount` |
| message | `event`, `key`, `layer`, `rat`, `uplink`, `masked`, `bytesVisible`, `pduPresent`, `sectionCount`, `lineCount`, `maskedLineCount` |
| radio | `section`, `metrics`, `sampleCounts`, `pointCounts` (after `PhyQuery.decimate` to the visible window), `chartCount` (metrics with data), `versionMisses`; carriers `carriersAtCursor`, `scellActivity`; rach `rachCount`; antennas `txAntennasMib`, `rxAntennaEarfcns`; unavailable `availabilityCount`, `catalogCount` |

The values come from the same model the view draws from: the session, `CallFlowPresentation.rows`,
`MessageSheetModel`, `JourneyQuery`, `PhyQuery`. The metrics per Radio section follow the design's dashboard
list (`RadioSections` in `App/Debug/ScreenValues.swift`). If WP4's Radio page groups them differently, change
that table and `sim-screens.json` together.

## Expectations (Fixtures/expected, committed, counts only)

- `sim-scan.json`: the foundation POC's scan numbers.
- `sim-analysis.json`: the sources are:
  - callflow-golden (128 events, the per-layer/RAT/direction split, 34 SUCCEEDED, the 4 moves, 2 connections)
  - qdss-full-stats (deframe counters)
  - the capture.qmdl md5 e53a167b29b25560938d1f089e719d33
  - the PHY sample counts of phy-golden, with the contract's (UTC second, carrier) bins: lte_dl_bler and
    lte_dl_phy_throughput 35, lte_ul_phy_throughput 27 (the old golden's 37/37/29 came from kpis.py's
    hard-coded PCELL table)
  - phy-summary, and journey-expected with the CONTRACT.md v1 amendments. Finding kinds are checked as
    "contains" plus the J12 tail, because the fixture's finding names predate `FindingKind`.
  - the R2 trace window (19.0 to 46.8 s after the press, within 1 s), 111 of 241 files overwritten, and the
    7.0-day profile.
- `sim-screens.json`: the 18 shots, their arguments and the report values each must show.
  - `@guideStatus`, `@needsAttention` and `@daysLeft` are worked out when the script runs, from the profile
    stub's RemovalDate and the Mac's clock. The Sep 21 profile reads "active" until Sep 27 19:40Z, then
    "expiringSoon", then "expired" from Sep 28 19:40Z.

`check_sim_analysis.py ACTUAL EXPECTED` does a subset compare. Keys starting with `_` are comments. Numbers
compare within 0.0015. It has operators: `$exact` (an object with exactly these keys, used for count maps),
`$approx`/`tol`, `$min`/`$max`, `$present`, `$oneOf`, `$multiset`, `$contains`, `$len`, `$unique`. It prints
each difference with its dotted path, and exits 1 on any difference and 2 on an unreadable file.

When WP4 regenerates `phy-golden.json`, `check_sim_analysis.py --phy-golden GOLDEN EXPECTED` lists where the
golden and the expectation differ. `--update-phy-from GOLDEN EXPECTED` copies the golden's counts in. Commit
that only after checking the three binned KPIs.

## Release carries no hooks

```sh
FT_WP=wp7 ios/scripts/build-app.sh Release; FT_WP=wp7 ios/scripts/build-app.sh Harness
B=$FT_TMP/dd/Build/Products
strings $B/Release-iphonesimulator/FieldTap.app/FieldTap | grep -c -E 'FT_FEED_PATH|ft-debug'   # 0
strings $B/Harness-iphonesimulator/FieldTap.app/FieldTap | grep -c -E 'FT_FEED_PATH|ft-debug'   # 1
nm $B/Release-iphonesimulator/FieldTap.app/FieldTap | grep -c DebugHooks                        # 0
nm $B/Harness-iphonesimulator/FieldTap.app/FieldTap | grep -c DebugHooks                        # > 0
```

Swift stores string literals of 15 bytes or fewer inside the code, so `strings` never sees "ft-debug" or
"FT_FEED_PATH" alone. It finds the Harness build's longer log line "FieldTap harness: FT_FEED_PATH import
failed: ". The `nm` count is the robust check. A Debug build keeps its code in `FieldTap.app/FieldTap.debug.dylib`
(Xcode's debug dylib), not in `FieldTap`, so check that file there.

## Privacy

- The archive is read in place and never copied. Its size and modification time are checked after the run.
- The imported capture lives in the app's container until the uninstall at the end.
- Reports carry counts, kinds, ids and flags only, never a decoded field value. The script runs the privacy
  gate over every output.
- Keep outputs in `$FT_TMP` or the git-ignored `Fixtures/local` (for example
  `Fixtures/local/shots/<package>`).
