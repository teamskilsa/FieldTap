# FieldTap for iPhone

A native SwiftUI + Swift Charts app (iOS 26+, iPhone, portrait, fully offline) that imports an iPhone
sysdiagnose taken with Apple's Baseband logging profile, rebuilds the Qualcomm DIAG log from the QDSS trace,
and shows the same RRC/NAS call flow as the Android app, a journey strip, and a radio dashboard. Identifiers
are masked by default. There is no networking code, and nothing capture-derived is ever committed.

**Nobody commits.** Agents working on a package leave their changes uncommitted in the working tree for the
owner of the repo to review. No `git commit`, `push`, branches or history rewrites.

## Layout

```
ios/
  FieldTap.xcodeproj/        hand-written (objectVersion 77); one app target, shared scheme FieldTap,
                             configurations Debug, Harness (Release + FT_HARNESS), Release
  Config/FieldTap-Info.plist document types (gzip/tar sysdiagnose, role Viewer), no in-place opening, no file sharing
  App/                       the app target: one synchronized folder, every file in it is compiled
    FieldTapApp.swift        @main; runs DebugHooks.launch in Debug/Harness; onOpenURL -> import
    Shell/                   RootView (tabs), CaptureDetailView (header, strip, page picker, cursor bar,
                             message sheet), SettingsView, Theme, screen-report modifier, seed placeholder
    Capture/ Journey/ CallFlow/ Radio/ Debug/   one folder per package (seeded, see below)
    Resources/               Assets.xcassets (AppIcon placeholder, AccentColor #4F46E5), PrivacyInfo.xcprivacy
  FieldTapKit/               the local Swift package (tools 6.2, Swift 6, strict concurrency)
    Sources/FTModel          shared value types, TimeBase (D1), Redaction, GoldenCodec, GuideState
    Sources/FTCore           HDLC, DIAG protocol, log codes, Spectrum, Fmt, streaming SysdiagScanner
    Sources/FTSignalling     call-flow decoders (WP2)
    Sources/FTPresentation   ladder rows and strings (WP6)
    Sources/FTCapture        QDSS deframer, importer, store, profile stub reader (WP3)
    Sources/FTPhy            PHY/MAC decoders, queries, availability (WP4)
    Sources/FTJourney        journey lanes, markers, findings, tiles (WP5; depends on FTPhy)
    Sources/FTApp            AppModel, CaptureSession, TimeCursor, Analyzer, FixtureLoader, LaunchPlan, ScreenReport
    Sources/FTTestSupport    Fixtures, the .fixture trait, JSONAssert (test targets only)
    Tests/<Target>Tests      one test target per source target; synthetic inputs in TestData/
  Contract/                  the Kotlin<->Swift contract: CONTRACT.md, diffs, run-kotlin-golden.sh, tools/
  Fixtures/local/            git-ignored capture-derived fixtures (fixtures.sh); never committed
  Fixtures/synthetic/        identifier-free inputs that may be committed
  scripts/                   env, fixtures, locks, tests, builds, screenshots, privacy gate, clean
```

## Who owns what

After WP0 the owner alone edits these paths. Files a package inherits from WP0 start with
`SEED from WP0; owned by <WP>`: their **public signatures are final** (the seeds win over the design text);
bodies are placeholders to replace. Anything else you need from another package's paths, or from a WP0 file,
goes into your report under `interface_requests`; work around it locally meanwhile.

| Package | Owns |
| --- | --- |
| WP0 foundation | `README.md`, `.gitignore`, `FieldTap.xcodeproj/`, `Config/`, `App/FieldTapApp.swift`, `App/Shell/`, `App/Resources/`, `FieldTapKit/Package.swift`, `Sources/FTModel/` (except the files below), `Sources/FTCore/`, `Sources/FTApp/`, `Sources/FTTestSupport/`, `Tests/FTModelTests/`, `Tests/FTCoreTests/`, `Tests/FTAppTests/`, `Contract/`, `Fixtures/README.md`, `Fixtures/synthetic/`, the scripts except `sim-verify.sh` and `check_sim_analysis.py` |
| WP1 upstream | the Kotlin and Python paths in `android/` and `fieldtap/` listed in the design |
| WP2 signalling | `Sources/FTSignalling/`, `Tests/FTSignallingTests/` |
| WP3 capture | `Sources/FTCapture/`, `Tests/FTCaptureTests/`, `App/Capture/`, and `Sources/FTModel/Capture*.swift` (CaptureModel, CaptureGuideState) |
| WP4 phy | `Sources/FTPhy/`, `Tests/FTPhyTests/`, `App/Radio/`, and `Sources/FTModel/Phy*.swift` |
| WP5 journey | `Sources/FTJourney/`, `Tests/FTJourneyTests/`, `App/Journey/`, and `Sources/FTModel/Journey*.swift` |
| WP6 callflow-ui | `Sources/FTPresentation/`, `Tests/FTPresentationTests/`, `App/CallFlow/` |
| WP7 harness | `App/Debug/`, `scripts/sim-verify.sh`, `scripts/check_sim_analysis.py`, `Fixtures/expected/` |

Nobody but WP0 edits `Package.swift` or `project.pbxproj`. The package already has what the design needs:
FTJourney depends on FTPhy (for `PhyQuery` at the cursor), every test target has a `TestData/` folder copied
into its bundle, and FTApp links everything. A generated table (WP4's TBS tables) goes in as Swift source.

Two naming rules the build imposes:

- App files need unique base names across `App/` (Swift rejects two `Seed.swift` in one target), so the app
  seeds are `App/<Folder>/<Folder>Seed.swift`. Package seeds are `Sources/<Target>/Seed.swift` and
  `Tests/<Target>Tests/SeedTests.swift`.
- A test bundle's copied folder must not be called `Resources` (codesign rejects the flat iOS bundle), hence
  `TestData/`.

## Working in parallel

Several agents build at once on a 10-core, 16 GB Mac with little disk.

**Private copy.** Work in your own copy and bring back only your owned paths:

```sh
WP=wp3
mkdir -p /private/tmp/fieldtap-work/$WP
rsync -a --exclude Fixtures/local --exclude Contract/src-v1 /Users/nikhiljain/Projects/fieldTap/ios/ /private/tmp/fieldtap-work/$WP/ios/
cd /private/tmp/fieldtap-work/$WP/ios && export FT_WP=$WP && source scripts/env.sh   # FT_IOS is this copy
# ... edit only your owned paths, test, then copy them back, e.g.:
rsync -a FieldTapKit/Sources/FTCapture/ /Users/nikhiljain/Projects/fieldTap/ios/FieldTapKit/Sources/FTCapture/
```

Every script derives `FT_IOS` from its own location, so it runs against the copy it sits in. `FT_FIXTURES`
falls back to the canonical `ios/Fixtures/local` when the copy has none (do not copy the 68 MB). `FT_REPO`
(the Android and Python sources) falls back to the canonical repo.

**Environment** (`source ios/scripts/env.sh`, zsh or bash): `FT_IOS`, `FT_REPO`, `FT_FIXTURES`,
`FT_SYSDIAGNOSE` (the user's archive in ~/Downloads, read in place, never copied), `FT_SIM_NAME` ("iPhone 17"),
`FT_TMP=/private/tmp/fieldtap-build/$FT_WP` (all your build products), `FT_BUNDLE_ID` (com.fieldtap.ios),
`FT_SCRATCH` (the research scratch the fixtures came from).

**Locks.** `scripts/with-build-slot.sh CMD` runs CMD in one of two build slots (`lockf` on
`/private/tmp/fieldtap-build-slot-{A,B}.lock`; macOS has no flock) and refuses to start below 3 GB free.
`scripts/with-sim-lock.sh CMD` holds the one simulator lock (`/private/tmp/fieldtap-sim.lock`). Take the build
slot first and the simulator lock second; the scripts below already do. Never boot another simulator than
`$FT_SIM_NAME`, never touch the physical iPhone (no devicectl), and no adb.

**Disk.** Check `df -h ~` before heavy steps and stop below 3 GB. A Debug app build is about 150 MB of
DerivedData, the macOS SwiftPM scratch about 200 MB, a simulator test build about 140 MB. Run
`scripts/clean.sh` when you finish.

## Scripts

| Script | What it does |
| --- | --- |
| `fixtures.sh [--verify]` | copies the capture-derived fixtures into `Fixtures/local` and writes `MANIFEST.json` (md5s); `--verify` re-checks every md5 and the pinned ones (iphone-recovered.qmdl e53a167b...) |
| `test-kit.sh [--release] [--sim] [--filter REGEX] [--allow-skips]` | macOS `swift test` (scratch `$FT_TMP/spm`), or `--sim`: build-for-testing then test-without-building on `$FT_SIM_NAME` from the package root. Exports `FT_FIXTURES`, `FT_SYSDIAGNOSE`, `FT_REQUIRE_FIXTURES=1` (and the `TEST_RUNNER_` forms). Counts tests from the xunit XML / xcresult and fails on any failure or skip |
| `build-app.sh Debug\|Harness\|Release` | `xcodebuild` for `platform=iOS Simulator,name=$FT_SIM_NAME` into `$FT_TMP/dd`; prints the .app path |
| `sim-shot.sh --args '...' --out PNG` | builds (Debug by default), takes the simulator lock, boots, installs, launches with the arguments, waits up to 60 s for the screen report with `"ready": true`, screenshots, copies the report next to the PNG, checks `--expect KEY=VALUE` |
| `privacy-gate.sh [--scan PATH]` | nothing under `Fixtures/local` or any trace file would be committed; no 10+ digit runs, IPs or long 0x-hex in tracked text; no networking API or in-app browser in `App/` or `Sources/` |
| `clean.sh [--keep-sim]` | removes `$FT_TMP`, uninstalls the app, shuts the simulator down |
| `with-build-slot.sh`, `with-sim-lock.sh`, `sim-udid.sh` | the locks, and the UDID of `$FT_SIM_NAME` |

Numeric literals in tracked files use `_` separators (`315_964_800_000`, `0xFFFF_FFFF`), and identifier-shaped
test strings are built at run time, so the privacy gate's patterns only ever catch real identifiers.

## Tests

```sh
export FT_WP=wp0
ios/scripts/test-kit.sh --filter 'FTModelTests|FTCoreTests'   # macOS, fast
ios/scripts/test-kit.sh --sim --filter FTCoreTests            # the same on the iPhone 17 simulator
ios/scripts/test-kit.sh --release --filter 'FTCaptureTests.*fullSysdiagnose'
```

Tests use Swift Testing. A test that needs a capture-derived file declares it and asks for it:

```swift
@Test(.fixture("contract/callflow-golden.json")) func parity() throws {
    guard let url = Fixtures.require("contract/callflow-golden.json") else { return }
    JSONAssert.equal(encoded, url)            // GoldenCodec.jsonDiff, the contract comparator
}
```

Without `FT_REQUIRE_FIXTURES=1` a missing fixture skips the test; with it (always, through test-kit.sh) the test
runs and `require` records a failure, so a skipped parity test never passes for a real one. `"sysdiagnose"`
names `FT_SYSDIAGNOSE`. Simulator test processes can read host paths, so the same fixtures work there.

The app scheme cannot run package tests, which is why all logic lives in package targets (FTApp holds the
analyzer, the fixture loader and the launch plan, with tests in FTAppTests).

## Screenshots and launch arguments

Debug and Harness builds read launch arguments (`FTApp.LaunchPlan`) through `DebugHooks.launch`:

| Argument | Effect |
| --- | --- |
| `-FTScreen captures\|guide\|settings\|importSheet\|overview\|callflow\|radio\|message` | route after launch |
| `-FTFixture DIR` | load `Fixtures/local` as a capture (`FixtureLoader`): the qmdl through the Analyzer; an empty call flow falls back to `contract/callflow-golden.json`, an empty PHY summary to `contract/phy-summary.json`; the summary is built from the archive name, the profile stub, ambtool_output.log and info.txt |
| `-FTOpenLatest` | open the newest capture |
| `-FTCursorMs MS`, `-FTEvent N`, `-FTFilter ALL\|RRC\|NAS`, `-FTRadioSection NAME` | cursor, selected event (the message sheet for `message`), ladder filter, Radio section |
| `-FTImportState TOKEN` | an import sheet state without importing: `done`, a stage (`reading` ... `saving`), or a problem (`noBasebandTrace`, `profileExpired`, `loggingNotEnabled`, `profileInstalledNoTrace`, ...) |
| `-FTGuideState TOKEN` | a Modem logging guide state (R1): `off`, `expired`, `expiringSoon`, `active`, `installedNoTrace`, `unknown` |

```sh
ios/scripts/sim-shot.sh --args "-FTFixture $FT_FIXTURES -FTScreen overview -FTCursorMs 15040" \
  --expect ready=true --out $FT_TMP/shots/overview.png
```

When a screen shows its real content it writes `Documents/ft-debug/screen-<route>[-<qualifier>].json`
(`ScreenReport`: route, qualifier, rendered, ready, captureId, cursorMs, values). The WP0 seed writes the
common keys; WP7 adds the per-route values. Screenshots and reports stay under `$FT_TMP` or
`Fixtures/local`, never elsewhere in the repo.

`FT_HARNESS` is an app-module condition only (Harness builds the package as Release), so nothing in
FieldTapKit may depend on it; code only the hooks call (LaunchPlan, ScreenReport) is plain logic. Note for
binary checks: Swift keeps string literals of 15 bytes or less inline in code, so `strings` cannot see them
("ft-debug" is invisible in every build); check a longer marker or the symbols (`nm | grep DebugHooks`: 0 in
Release, present in Harness).

## Privacy and App Store rules (v1)

- Capture-derived fixtures stay in git-ignored `Fixtures/local` (the repo's captures policy).
- Bundle id placeholder `com.fieldtap.ios`, no team. v1 is App Store-safe: no profile bundling or look-alike
  profile, no system-file probes, no private APIs, no networking. Apple's profile page is opened in Safari
  (`openURL`): https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=baseband
- From info.txt and trace.info only file names and times are parsed; the GUID, DiagID and hardware model are
  never kept.
- GPL projects (SCAT, QCSuper, DiagNG, CellGuard, BaseTrace, Wireshark dissectors) and AGPL srsRAN are
  facts-only references; MobileInsight (Apache-2.0) layout facts are credited in Settings > Licences.

## Status of the unverified parts

- The share-sheet route (CFBundleDocumentTypes with LSSupportsOpeningDocumentsInPlace NO) builds and is in the
  Info.plist, but has not been exercised end to end on a device; the POC proved `FT_FEED_PATH` and
  `.fileImporter`.
- The capture-coaching timings (press first, reproduce 20-40 s later) come from one capture; the app says so.
