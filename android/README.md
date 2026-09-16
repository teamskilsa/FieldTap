# 5gto6G FieldTap for Android

5gto6G FieldTap is a free drive-test logger for Android phones, published by 5gto6g. It records what Android's public
telephony API reports about the cells a phone uses and sees, joins every measurement to the phone's GPS position, can run
ping and download tests over the cellular network, and writes each session as the seven files of `fieldtap-session/1`.
The `fieldtap` tools in this repository validate those files and render them as a report on a computer.

| | |
| --- | --- |
| Version | 1.0.0 (versionCode 2), set in [`app/build.gradle.kts`](app/build.gradle.kts) and shown in About |
| Application ID | `com.fieldtap` |
| Android | 12 (API 31) or newer, on a phone with a SIM; built for Android 16 (target API 36) |
| Price, account | Free; no account and no upload yet |

## What it reads, and what it does not

The app shows this statement word for word:

> Reads what Android exposes: cell identity, RSRP/RSRQ/SINR, band, ARFCN, service state, plus ping
> and download tests. That needs no root, and it is all this app does until you turn on signalling
> capture. Signalling capture reads RRC and NAS from the modem itself and needs a rooted phone; it is
> off unless you switch it on. Neither mode can lock bands or cells or scan operators.

What that means in practice:

- **Two modes, and the default is the quiet one.** Without root the app reads only Android's public telephony
  API: no RRC, NAS or SIB, no procedures or call flows, and `capabilities.layer3` is `false` in every session it
  writes. Signalling capture is a separate, opt-in mode that needs a rooted phone; it reads RRC and NAS off the
  modem through the handset's own diag path. Neither mode locks bands or cells or scans operators.
- **Numbers are Android's, with their age.** Android decides how often the modem measures. A kpi row is written only for
  a fresh measurement, with its age and source; answers Android repeats from its cache are dropped and counted, and
  stretches without fresh samples are written as `sampling_gap` events. Live shows the cadence in force and how old each
  value is.
- **Nothing leaves the phone by itself.** Sessions stay in the app's storage until you share one as a zip or delete it.
  No account, no upload, no report on the phone, no cloud backup or device-to-device transfer.
- **No Google Play services, Firebase, analytics, ads or crash reporting.**
- **No phone or SIM identifiers.** The app never reads the IMEI, IMSI, ICCID, phone number, Android ID or advertising ID.
- **Location only while you use it.** Live measures while it is on screen; a session runs in a foreground service with a
  notification, started from the screen. There is no background location permission. Privacy zones stop recording near
  places you mark, and a shared zip can carry reduced location precision.
- **Honest tracks.** The release build rejects mock locations; only the debug build accepts them, for the emulator.

## Build

The build needs JDK 21, and the Android SDK with Platform 37 and Build-Tools 36.0.0 (Android Studio's SDK Manager, or
`sdkmanager`). The Gradle wrapper downloads Gradle 9.7.1; the Android Gradle plugin 9.4.0 fetches everything else. Run
every command from `android/`.

| Command | Result |
| --- | --- |
| `./gradlew :app:assembleDebug` | `app/build/outputs/apk/debug/app-debug.apk`: debuggable, accepts mock locations, and contains the debug automation hook. For development and CI only; never give it to field users. |
| `./gradlew :app:assembleRelease` | R8-minified, resources shrunk, not debuggable. `app/build/outputs/apk/release/app-release.apk` when the release key is configured ([Release key](#release-key)); otherwise `app-release-unsigned.apk`, which Android will not install. R8's `mapping.txt` is in `app/build/outputs/mapping/release/`; keep it with each release to read obfuscated stack traces. |
| `./gradlew :format:test :core:test :app:testDebugUnitTest :app:lintDebug` | Unit tests of the three modules and lint. |

### Windows

In Git Bash:

```bash
export JAVA_HOME="C:/Program Files/Eclipse Adoptium/jdk-21"   # any JDK 21
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
cd android
./gradlew :app:assembleDebug :app:assembleRelease
./gradlew --stop
```

In PowerShell:

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
cd android
.\gradlew.bat :app:assembleDebug :app:assembleRelease
.\gradlew.bat --stop
```

On the Simnovus lab PC, `source /c/Users/Simnovus-Lab/tools/android-env.sh` in Git Bash sets all of this, including
`JAVA_TOOL_OPTIONS`: without it, JDK 21 cannot open its AF_UNIX selector pipe under that PC's `%TEMP%` and Gradle does not
start. The PC has 7.8 GB of RAM, so run one Gradle build at a time and `./gradlew --stop` afterwards
([ARCHITECTURE.md, section 12](ARCHITECTURE.md#12-building-on-this-pc)).

### macOS

```bash
brew install --cask temurin@21                        # or any JDK 21
export JAVA_HOME="$(/usr/libexec/java_home -v 21)"
export ANDROID_HOME="$HOME/Library/Android/sdk"       # Android Studio's default
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platforms;android-37.0" "build-tools;36.0.0" "platform-tools"
cd android
./gradlew :app:assembleDebug :app:assembleRelease
```

### A signed release

The signing config in `app/build.gradle.kts` reads the key from the environment, or from `~/.gradle/gradle.properties`;
nothing about the key is in the repository. An environment variable wins over the property.

| Environment variable | Gradle property | Value |
| --- | --- | --- |
| `FIELDTAP_RELEASE_STORE_FILE` | `fieldtap.release.storeFile` | The PKCS12 keystore |
| `FIELDTAP_RELEASE_STORE_PASSWORD_FILE` | `fieldtap.release.storePasswordFile` | A file whose first line is the password |
| `FIELDTAP_RELEASE_STORE_PASSWORD` | `fieldtap.release.storePassword` | The password itself, instead of the file |
| `FIELDTAP_RELEASE_KEY_ALIAS` | `fieldtap.release.keyAlias` | The key's alias; default `5gto6g-fieldtap` |

With none of them set, the release APK is built unsigned, which is what CI's build job does. Setting only some of them
fails the build, so a release meant to be signed never comes out unsigned without notice. On the release PC, in Git Bash:

```bash
source /c/Users/Simnovus-Lab/tools/android-env.sh
export FIELDTAP_RELEASE_STORE_FILE=C:/Users/Simnovus-Lab/tools/keys/5gto6g-fieldtap-release.jks
export FIELDTAP_RELEASE_STORE_PASSWORD_FILE=C:/Users/Simnovus-Lab/tools/keys/5gto6g-fieldtap-release.password.txt
cd android
./gradlew :app:assembleRelease :app:assembleDebug
./gradlew --stop
"$ANDROID_HOME/build-tools/36.0.0/apksigner.bat" verify --print-certs app/build/outputs/apk/release/app-release.apk
sha256sum app/build/outputs/apk/release/app-release.apk
```

`apksigner` must print `Signer #1 certificate DN: CN=5gto6g` and the certificate SHA-256 under [Release key](#release-key).
Publish the APK's SHA-256 and the certificate SHA-256 with every download. Raise `versionCode` for every APK that installs
over an older one: Android refuses an update with the same or a lower code.

## Install on a phone

### With adb

1. On the phone, turn on Developer options (tap Build number in About phone seven times), then USB debugging. Connect the
   phone and allow the computer when it asks.
2. Install, or update while keeping the app's sessions and settings:

   ```bash
   adb install -r 5gto6g-fieldtap-1.0.0.apk
   ```

   versionCode 2 installs over the first 1.0.0 (versionCode 1) and keeps its sessions: both are signed with the release
   key. `adb shell dumpsys package com.fieldtap | grep versionCode` shows which one a phone has.

3. `INSTALL_FAILED_UPDATE_INCOMPATIBLE` means the phone has a copy signed with another key, such as a debug build. Export
   the sessions you need first (below), then `adb uninstall com.fieldtap` and install again. **Uninstalling deletes every
   session on the phone.**

### Sideload, without a computer

Copy the APK to the phone (download it, or copy it over USB), open it from Files, allow "Install unknown apps" for that
app when Android asks, and install. Before installing, check that its SHA-256 and certificate SHA-256 match the
published values; `apksigner verify --print-certs` shows the certificate on a computer. Android's developer verification
does not yet affect installs from a website; when it does (2027 globally, per [docs/APP-PLAN.md](../docs/APP-PLAN.md)),
installs over adb stay exempt.

### First run

The app opens on its disclosure: what it records, that it stays on the phone, that it never reads phone or SIM
identifiers. Accepting it leads to the permissions: precise location (required, because Android returns no cell
information without it), notifications (recommended, for the session notification), and the Phone permission only if you
later turn on "Instant cell updates" in Settings. Live then shows the serving cell. **Start session** checks that the
phone is ready and names what could cost samples (battery optimisation, Wi-Fi, background limits) with a fix for each,
and **Start anyway**. **Stop** closes the files.

## Get sessions off the phone and render them

### Share a zip

Sessions, then a session, then Share: choose the location precision, **Build zip** (the screen shows its SHA-256), and
**Share zip** to any app, such as email, Drive or Files. On a computer, from the repository root:

```bash
python -m fieldtap validate 20260910-143000_Mall-walk-north-path.zip
mkdir 20260910-143000_Mall-walk-north-path
unzip 20260910-143000_Mall-walk-north-path.zip -d 20260910-143000_Mall-walk-north-path   # PowerShell: Expand-Archive
python -m fieldtap report 20260910-143000_Mall-walk-north-path
```

### With adb

Sessions are directories under the app's external files:

```bash
adb shell ls /sdcard/Android/data/com.fieldtap/files/sessions
adb pull /sdcard/Android/data/com.fieldtap/files/sessions/20260910-143000_Mall-walk-north-path
python -m fieldtap validate 20260910-143000_Mall-walk-north-path --upload
python -m fieldtap report 20260910-143000_Mall-walk-north-path
```

`fieldtap` needs Python 3.9 or newer and nothing outside the standard library. `validate --upload` also requires that
the directory holds only the seven session files, so run it before `report`, which adds `report.html` and `summary.json`
to the directory. Open `report.html` in a browser. A session still recording has no `stopped_utc`; one Android killed is
closed with a `session_interrupted` event the next time the app starts. [docs/SESSION-FORMAT.md](../docs/SESSION-FORMAT.md)
and [schema/columns.json](../schema/columns.json) define every file and column.

## How CI proves it

[`.github/workflows/android.yml`](../.github/workflows/android.yml) runs on every push to `android-app` and every pull
request that touches `android/`, `schema/`, `tests/fixtures/` or `fieldtap/`.

| Job | What must hold |
| --- | --- |
| **build** | The unit tests of `:format`, `:core` and `:app`, lint, the debug, instrumented-test and release APKs. The release APK has no debug automation hook, and without a release key it comes out unsigned and minified. |
| **emulator (API 36, API 31)** | [`e2e/run_e2e.sh`](e2e/run_e2e.sh) with the debug build, through the real UI. API 36 runs on a Pixel 7 screen (411 x 914 dp), where the design is judged; API 31 keeps the emulator's 320 x 640 dp screen as the robustness check. The first run (the disclosure before any permission prompt, then with its full notice open) and every screen, each at every scroll position, in light, dark, font scale 1.3 and, on API 36, landscape; on the Pixel 7 screen upright, Live's trend chart must lie wholly on the first screen; the recording strip must stay on one line in every state at font scale 1.3 on a 360 dp width; a 180 s walk while the host feeds `adb emu geo fix` and signal profiles, with Settings, a marker on Live and one from the notification, whose text must confirm it, Stop, the zip built, its SHA-256 checked and shared; location services switched off mid-session with a privacy zone set, written as `gps_lost` and `gps_restored`, with a marker that waits for a fix, is dropped and is shown as not saved on Session detail; `am force-stop` and `kill -9` mid-session, each closed with Android's exit reason. Every session must pass `fieldtap validate --upload` and `fieldtap report`, and [`e2e/check_e2e.py`](e2e/check_e2e.py) checks what the files and screenshots hold. Then the capability probe records what the emulator's radio provides. |
| **release build (API 36, API 31)** | On the same screens as the emulator job. The APK a phone gets: signed by Gradle with a key made in the job and deleted at once, checked with `apksigner` and `aapt2` (signed, minified, version, not debuggable, no hook), then driven by [`e2e/release_smoke.sh`](e2e/release_smoke.sh) with nothing but `uiautomator dump` and `input tap` on the app's own strings: install with `adb install -r`, the disclosure, Live with a serving cell, the version in About, a session with ping and download tests for 90 s while a GPS walk is fed, Stop. The pulled session must pass `fieldtap validate --upload` and `fieldtap report` and hold GPS fixes, positioned measurements, test rows, the release's version and `stopped_by` user, plus kpi rows and a `serving_cell` event on API 36; the app must not crash. This is the job that catches a class, keep rule or resource R8 got wrong. |

Artifacts per run: `apks`; `e2e-sessions-api<N>` (sessions with `report.html`, the exported zip), `e2e-screenshots-api<N>`
(one folder per look, then `walk`, `location-off` and `recovery`; a screen that scrolls is `NAME-p1.png`, `NAME-p2.png` and
so on, top to bottom), `e2e-logcat-api<N>`, `e2e-reports-api<N>`, `emulator-probe-api<N>`; `release-smoke-api<N>` (summary, a screenshot and window
dump per step, the session with `report.html`, logcat) and `release-apk-api<N>` (the throwaway-signed APK and its R8
mapping). Download them with `gh run download RUN_ID -D DIR`. Logcat is redacted of anything shaped like an identifier.

### Screenshots

Every push leaves the app's screens at phone size in `e2e-screenshots-api36`, taken on the Pixel 7 screen (1080 x 2400
px). The screens to look at first, in `light/`, `dark/` and `landscape/`:

| Screen | File |
| --- | --- |
| Disclosure, before any permission prompt | `01-disclosure-p1.png` |
| Live, idle, with the trend on the first screen | `03-live-p1.png` (`landscape/03-live-p1.png` turned) |
| The Start dialog | `03b-start-dialog.png` |
| Sessions | `04-sessions-p1.png` |
| Session detail | `05-session-detail-p1.png` |
| Settings, and its Test targets screen | `08-settings-p1.png`, `08b-test-targets-p1.png` |
| About | `09-about-p1.png` |

A screen that scrolls continues in `-p2.png` and on. The walk's own folder, `walk/`, holds the moments a session goes
through, light and upright: `07-prestart-sheet.png` (the checks Start runs), `10-recording.png`, `13-session-detail.png`
and `14-zip-ready.png`. `release-smoke-api36` has the same path through the signed, minified build, one screenshot per
step.

The emulator jobs run only in CI. `release_smoke.sh` also runs against a local emulator: with bash, adb and Python on the
path, `RELEASE_APK=path/to/app-release.apk bash android/e2e/release_smoke.sh`.

## Architecture in brief

```
:format  Kotlin/JVM  the bytes of the seven session files (CSV and session.json writers, schema constants)
   ^
:core    Kotlin/JVM  every decision that needs no Android: freshness, serving cell, events, gaps, GPS join,
   ^                 privacy zones, the session recorder, crash recovery, storage cap, export zip, consent
:app     Android     thin adapters (telephony, location, device state, exit reasons), the foreground service,
                     the Compose screens
```

A cell measurement travels like this: `requestCellInfoUpdate` and the telephony callbacks reach a shared measurement hub;
the session recorder, on a single dispatcher, drops answers Android repeats, picks the serving cell, derives events and
sampling gaps, and joins each row to the nearest GPS fix within 5 s; rows are appended to the CSVs, flushed every second
and synced every 5 s, and `session.json` is written every 60 s and at Stop. A heartbeat outside the session lets launch
recovery close a session Android killed, with the exit reason Android recorded. `:format` and `:core` never import
`android.*`, so all of that is unit-tested on a plain JVM.

Read on in [ARCHITECTURE.md](ARCHITECTURE.md) (modules, contracts, threads, recovery, the debug automation hook, and every
decision with its reason), [docs/APP-PLAN.md](../docs/APP-PLAN.md) (the product and the Android facts it rests on), and
[app/src/main/kotlin/com/fieldtap/ui/theme/DESIGN.md](app/src/main/kotlin/com/fieldtap/ui/theme/DESIGN.md) (the design
system).

## Release key

Every APK for phones is signed with one key, generated once on 2026-09-11 on the Simnovus lab PC:

| | |
| --- | --- |
| Keystore | `C:\Users\Simnovus-Lab\tools\keys\5gto6g-fieldtap-release.jks` (PKCS12) |
| Password | `C:\Users\Simnovus-Lab\tools\keys\5gto6g-fieldtap-release.password.txt`, one line; the store and the key share it |
| Alias | `5gto6g-fieldtap` |
| Key | RSA 4096, SHA256withRSA, `CN=5gto6g`, valid from 2026-09-11 to 2056-09-11 |
| Certificate SHA-256 | `82:10:16:BF:25:0D:15:29:6E:17:0D:CA:C0:9E:1E:EB:3C:CC:62:CE:65:F0:1A:54:B9:2B:F0:95:63:A9:D5:F0` |

Neither file is in this repository, in CI or in any Gradle properties file; `.gitignore` refuses `*.jks` and `*.keystore`.
The password file is the only record of the password.

**Back up both files offline, now.** Keep at least two copies apart from the PC, for example on two encrypted USB drives
stored in different places, or in the company password manager as an attached file, with a named custodian. After
copying, check that each copy opens:

```bash
keytool -list -keystore COPY.jks -storepass:file COPY.password.txt
```

It must list `5gto6g-fieldtap` with the certificate SHA-256 above.

**Losing the key strands every installed copy.** Android installs an update only when it is signed with the same key as
the installed app. Without this key no installed FieldTap can ever be updated: every user would have to uninstall it,
which deletes the sessions on the phone, and install a different app. A leaked key is as bad the other way: anyone holding
it can publish an update that installs over FieldTap and reads its sessions. If that happens, stop publishing and tell
users to uninstall. When the app goes to Google Play, upload this same key to Play App Signing, so installs from the
website and from Play can update each other ([docs/APP-PLAN.md](../docs/APP-PLAN.md), Distribution).
