# 5gto6G FieldTap: the Android app plan

> **Decided 2026-09-10:** build an Android app, with no modem module for now. This page is
> the build plan. It replaces the "no app" conclusions in [`UI-PLAN.md`](UI-PLAN.md) and
> [`APP-AND-CLOUD-PLAN.md`](APP-AND-CLOUD-PLAN.md); the research behind those still stands.
>
> **Also decided 2026-09-10:**
> - The app is **5gto6G FieldTap**, and everything is under the 5gto6g name: the app, the
>   publisher, the website and the account.
> - It is **free for now**.
> - The publisher registers as **5gto6g, a company**. That needs 5gto6g to be a legal entity
>   with a free D-U-N-S number.
> - The package ID is **`com.fieldtap`** for now. It is set in one Gradle property, so it can
>   still change before it is registered with Google.
> - The code lives in **`android/` in this repository**, on the `android-app` branch.
> - Before hand-over, the app is verified on an **Android emulator in GitHub Actions**. This
>   Windows PC cannot run one: Hyper-V holds the CPU's virtualization, and it has 7.8 GB of RAM.

How this plan was made: three independent plans (ship fast, one platform for the long term,
what kills it), then a synthesis. Every Android claim the plan depends on was checked against
AOSP source or Google's policy pages on 2026-09-10, and the shared file format was checked by
running the real report code on an app-shaped session.

Research: [`research/android-app-question.md`](research/android-app-question.md),
[`research/android-scanning-without-diag.md`](research/android-scanning-without-diag.md),
[`research/cellular-app-landscape.md`](research/cellular-app-landscape.md),
[`research/cloud-collection-market.md`](research/cloud-collection-market.md),
[`research/upload-privacy-legal.md`](research/upload-privacy-legal.md).

---

## The short version

**Yes, build it, as a walk-test logger that produces the FieldTap report. Not as a signal
meter.**

Without diag, Android gives every app the same numbers: cell identity, RSRP, RSRQ, SINR,
band, ARFCN, service state. NetMonster (5M+ installs), Network Cell Info (10M+) and LTE
Discovery (1M+) already show them for free. Another live meter loses.

Free apps skip four jobs. Those are what this app wins on:

1. **Honest samples.** Android refreshes cell info at most every 2 s (screen on, and Wi-Fi
   off or charging), otherwise every 10 s. Asking more often returns the cached list, and
   free apps log those repeats as new measurements. This app times every sample by when the
   modem measured it and never logs a repeat as a measurement.
2. **Keeps logging on OnePlus, or records exactly when and why it stopped.** dontkillmyapp
   rates OnePlus 5/5 for killing background apps, with no developer-side fix.
3. **Tests forced onto cellular.** Ping and download bound to the cellular network, never
   quietly over Wi-Fi.
4. **The same report as the laptop tool, in an account.** The app writes FieldTap's session
   format and the existing Python renders it.

Three things would sink it:

- **Selling it as a drive-test or protocol tool.** It cannot decode anything, and that
  comparison is lost the moment a customer asks for RRC.
- **Testing only on the rooted, SIM-less OnePlus.** That exercises about half the app.
- **Reports that show layer-3 wording** ("0 handovers") for sessions that could never see
  a handover.

**Effort:** about 7 weeks for one Android developer, plus about 1.5 weeks of Python and
backend.

---

## What it is, and who it is for

**5gto6G FieldTap: the walk-test logger that produces the FieldTap report.**

For:

- Rollout and site-acceptance subcontractors
- In-building, DAS and neutral-host integrators
- Private-network installers
- FieldTap laptop users who need a hands-free walk leg

That is the segment RantCell serves at $1,600/yr for 5 devices, with no layer 3.

**The limits statement,** word for word on the download page, the About screen and the
report:

> Reads what Android exposes: cell identity, RSRP/RSRQ/SINR, band, ARFCN, service state,
> plus ping and download tests. That needs no root, and it is all this app does until you
> turn on signalling capture. Signalling capture reads RRC and NAS from the modem itself and
> needs a rooted phone; it is off unless you switch it on. Neither mode can lock bands or
> cells or scan operators.

The app is free for now, and so is the pilot. Pricing is decided after the pilot; the
reference point is RantCell's roughly $320 per device per year. Never market the live meter or
crowdsourcing.

---

## What the first version does

| Area | What ships |
| --- | --- |
| Session | One user-started session at a time, in a foreground service of type `location` started from the visible screen. The notification shows elapsed time, serving RSRP, the age of the newest sample, and Stop and Mark. |
| Radio | A `requestCellInfoUpdate` ticker, which needs only precise location, plus the signal-strength, service-state, display-info and data-state listeners, which need no permission. The push `CellInfoListener` is added only if the user also grants the Phone permission. |
| Freshness | Samples are timed by the modem timestamp and de-duplicated, so cached repeats never become KPI rows. Every row carries its age, and whether the screen was on, the phone charging and Wi-Fi connected. Gaps become `sampling_gap` events. The session records the cadence it actually achieved. |
| Walk mode | Screen kept on (dark and dim) and a prompt to turn Wi-Fi off or plug in, which unlocks the 2 s interval. Pocket mode is labelled "10 s cadence". |
| GPS | 1 Hz from the platform location manager: GPS, with the fused and network providers as indoor fallbacks. No Google Play services. |
| Events | `serving_cell`, `rat_change`, `service_lost`, `emergency_only`, `service_restored`, `data_state`, `nr_display`, `gps_lost`, `gps_restored`, `sampling_gap`, `marker` (with a note), `test_failed`, `session_interrupted`. Never handover or anything RRC. |
| Tests | Off by default, opt-in per session. ICMP ping from an in-process socket bound to cellular. HTTP download bound to cellular: 10 MB cap, every 5 minutes, a per-session data budget, a file on our own host. With no cellular network, a failed row that says so. |
| Files | `session.json`, `kpi.csv`, `track.csv`, `events.csv`, `traffic.csv`, `cells.csv`, `cellinfo.csv`. `fieldtap report <dir>` renders them. |
| Crash safety | Append-only CSVs, flushed every second and synced to disk every 5 s. `session.json` rewritten atomically every 60 s. On the next launch an open session is closed with Android's recorded exit reason: user stop, low memory, or OEM freezer. |
| Readiness check | Before the first session, and before every session on OnePlus, OPPO and realme: precise location, location on, notifications, battery optimisation, background restriction, standby bucket, SIM, Wi-Fi. Each links to its settings screen. An optional 10-minute screen-off soak test reports seconds logged against seconds elapsed. |
| Capability probe | What each API returns on this handset (neighbours, band lists, whether timestamps advance, SINR range, which permissions are refused), exportable as JSON to qualify pilot phones. |
| Screens | Live, Sessions, Session detail (stats, share zip, upload, open report, delete), Readiness, Probe, Account and consent, About. |
| Privacy | Full-screen disclosure before the location prompt. Versioned consent with separate choices for logging and upload. Privacy zones, inside which nothing is written. Location precision per upload: full, about 110 m, or none. No hardware or advertising identifiers. |
| Account | Email one-time-code sign-in. Upload runs after the session stops. The server renders the report with the same Python. Delete session and delete account work from the app and the web. |
| 5gto6g.com | Download page (signed APK, version, APK and certificate SHA-256, the limits statement, privacy notice), an update-check file, and a "My sessions" page with report links. |

## What it will not do, and why

| Not in the app | Why |
| --- | --- |
| RRC, NAS, SIB, MIB, measurement reports, handover causes, call flow | No diag on this phone. Any "decode" wording is out. |
| Operator or PLMN scan | `requestNetworkScan` needs `MODIFY_PHONE_STATE`, which is signature, privileged or role only. It stays a laptop feature (`fieldtap scan --operators`). |
| Carrier aggregation, bandwidth, barring | `PhysicalChannelConfigListener` and `BarringInfoListener` need `READ_PRECISE_PHONE_STATE`, signature or privileged only. The probe records the refusal. |
| Band, cell or RAT lock; root; Magisk | Root throws away the no-root position and breaks on OS updates. |
| Modem module hosting | Not now, by decision. A measurement-source interface and a `group_id` key are reserved so it can land later without a rewrite. |
| Scheduled, unattended or boot-started logging | Needs background location, which Play restricts and customers distrust. |
| Report on the phone | Chaquopy adds tens of MB and a second build system. The laptop and the server already render. |
| Map tiles | The report's tile-free route map is the map. |
| Upload throughput, iperf3, voice, VoLTE, video, web browsing | Later. |
| Wi-Fi scanning, Bluetooth multi-phone control, external GPS, floor plans | Later. |
| Teams, roles, SSO, billing, licences, public API | After the pilot. |
| Google Play listing | Later. The APK stays Play-clean, so a listing is a paperwork task. |
| Certificate pinning | Supabase and Cloudflare rotate certificates, so pinning is an outage risk. System CAs only; user-installed CAs are not trusted. |
| Analytics, crash-reporting or ads SDKs | No third party sees session data. |
| Per-SIM logging on dual-SIM phones | Follows the default data SIM and records which one. |
| iOS | No public cell-measurement API. |

---

## How it is built

**Kotlin, Jetpack Compose, coroutines. minSdk 31, targetSdk 36, compileSdk 37.**

- **minSdk 31** because `TelephonyCallback`, the fused location provider and the
  executor-based location request all arrived in Android 12, and the cell-info timestamp
  in Android 11.
- **targetSdk 36** because Play requires it for new apps and updates since 31 Aug 2026.
- **Libraries:** kotlinx-coroutines, kotlinx-serialization, WorkManager, DataStore, OkHttp.
  No Room, Hilt, Google Play services or Firebase.
- **Not Flutter or React Native.** Every call that matters is Android-only, and iOS has no
  cell API, so a cross-platform layer adds a bridge and buys no reach.

**Three Gradle modules:**

- `:format`, plain Kotlin/JVM: the session model, the CSV and JSON writers, and the column
  constants, generated from `schema/columns.json`. Its tests reproduce the golden session the
  Python tests check.
- `:core`, plain Kotlin/JVM: everything that does not need Android, which is the freshness
  engine, events, GPS matching, privacy zones and the session state machine, all tested on a
  JVM.
- `:app`, the Android app: thin adapters over the platform APIs, the service and the screens.

**In this repository, under `android/`.** It lives on the `android-app` branch, which is based
on the PR #1 branch because the Python package and the session-format contract are only there.
Its CI runs only when `android/`, the schema, the fixtures, `fieldtap/` or the workflow itself
changes.

### The parts

**SessionService.** A foreground service of type `location`, started only by the Start tap
while the screen is visible. A running location service keeps location access after Home or
screen-off, so background location is never needed. Not `dataSync`, which Android 15 caps
at 6 hours a day. It does not rely on `START_STICKY`: a restart happens while the app is
invisible, and location cannot be started then. Recovery is explicit instead.

**RadioSampler: surviving cached cell info.** This is the part free apps get wrong.

- Ask for a cell-info update every second. Inside Android's 2 s or 10 s window, the answer
  is the cached list.
- De-duplicate on the cell plus its modem timestamp. An unchanged timestamp is a repeat. It
  goes to `cellinfo.csv` marked stale, never to `kpi.csv`.
- Row time is the wall clock minus the sample's age, so it is when the modem measured it.
- `kpi.csv` accepts a serving sample only if it is at most 2.5 s old on the short interval,
  or 11 s old on the long one.
- The serving cell is the one reported as primary serving; the NSA NR leg is secondary
  serving. Emergency-only comes from service state, because the SIM-less OnePlus reports
  its emergency-camped NR cell as registered.
- Android's "unavailable" value is written blank, never as 2147483647.
- Screen, charging and Wi-Fi state are recorded with every sample, because they change
  Android's interval.
- With the screen off on battery, signal-strength updates stop unless tethering or Android
  Auto is on. Pocket mode therefore has no signal fill, and the screen says so.
- Each listener is registered separately, so one refused permission costs one column, not
  the session.

**LocationSource.** GPS at 1 s, with the fused and network providers as indoor fallbacks.
Samples are matched to fixes on the monotonic clock. A KPI row gets a position only if a
fix is within 5 s.

**Surviving OxygenOS.** Foreground service, readiness check, soak test, a heartbeat file
every 5 s. On the next launch an open session is closed at its last heartbeat, with the
reason from `getHistoricalProcessExitReasons`.

**No wake lock by default.** Play's wake-lock rule exempts the system's own location
wake-ups but not an app's wake lock. Week 1 measures whether one is needed. If it is, it
ships only in the website build.

**TestRunner.** Requests the cellular network explicitly.

- Ping is an in-process ICMP socket bound to that network; Android permits unprivileged
  ICMP sockets. Running `/system/bin/ping` is avoided, because a child process cannot be
  bound to cellular.
- Download counts bytes through the cellular network, with a cap and a budget.
- No tests run while an upload runs.

**Storage.** App-specific `sessions/YYYYMMDD-HHMMSS_name/`. No storage permission, no
database: the sessions list reads the `session.json` files. A 2 GB cap blocks new sessions
rather than deleting old ones. Backup is off, so tracks never reach cloud backup.

**UploadWorker.** WorkManager, keyed by session ID so a session uploads once and survives a
reboot. It builds a privacy-filtered zip copy, uploads it with its SHA-256, then waits for
the report.

---

## The session format

> The authoritative contract is now [`SESSION-FORMAT.md`](SESSION-FORMAT.md) with
> `schema/columns.json`. Where this summary differs, they win.

The app writes the same directory the laptop tool writes, so `fieldtap report <dir>`
renders it. **This was tested before planning:** an app-shaped 10-minute NSA session
rendered on Python 3.11 and 3.12 with the RSRP chart, the coloured route, the serving-cell
table, the traffic tables and the session index.

Contract name: `fieldtap-session/1`. Phase 0 moves this section into
`docs/SESSION-FORMAT.md` and `schema/columns.json`, and the Kotlin constants are generated
from that JSON.

### Rules, each learnt from a case that broke the report

- Directory `<YYYYMMDD-HHMMSS UTC start>_<slug>`; slug characters `[A-Za-z0-9._-]`, at
  most 48.
- UTF-8, no BOM, header row always present. CSV lines end in CR LF, which is what fieldtap's
  Python writers produce; `session.json` ends lines in LF.
- **Blank means unknown.** Never `null`, never 2147483647.
- Every `*_utc` value is exactly `yyyy-MM-ddTHH:mm:ss.SSS+00:00`. Never a trailing `Z`,
  which Python before 3.11 rejects, and never a time with no offset, which crashes the
  report. In Kotlin: `DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSxxx")` at UTC,
  never `Instant.toString()`.
- `time_epoch` is Unix seconds with 3 decimals, at modem time.
- The `session.json` objects `transport`, `handset`, `device`, `modem`, `log_mask`, `files`
  and `summary` are `{}` when empty, never `null`. Null crashed the report.
- `transport.transport` is never `"file"`, which labels a session SIMULATED.
- The app never writes `summary.json`, `report.html` or `index.html`.
- Never IMEI, IMSI, ICCID, ANDROID_ID or an adb serial.

### Files

| File | Header | Notes |
| --- | --- | --- |
| `session.json` | | `format`, `session_id`, `group_id` (null), `name`, `note`, `location`, `started_utc`, `stopped_utc`. `transport`: `{"transport": "android-api", "app", "app_version", "version_code"}`. `handset`: the keys the laptop reads over adb. `device.key`: `app:<random install UUID>`. `summary`: `stopped_by`, `plmns`. `capabilities`: `{"layer3": false}`. `collection`: median fresh interval, share of time at 2 s, screen/Wi-Fi/charging shares, repeats dropped, gaps with exit reasons. `privacy`: data class, precision, zone pauses, consent version and hash. |
| `kpi.csv` | `frame,time_epoch,rat,meas_id,pci,rsrp_dbm,rsrq_db,sinr_db,comment,lat,lon` | One row per fresh serving sample per RAT; NSA gives an `lte` and an `nr` row with the same time. `frame` and `meas_id` blank. One value per cell, never lists. NR: SS-RSRP, SS-RSRQ, SS-SINR. LTE: RSRP, RSRQ, RSSNR. `comment`: `android-api age_ms=<n> src=<request\|push>`. Drives the charts, the averages and the route colour. |
| `track.csv` | `time_utc,lat,lon,accuracy_m,altitude_m,speed_mps,provider,source` | Every row has lat and lon; a blank one crashed the reader. Suppressed fixes are left out, not blanked. The whole file is left out at precision "none". |
| `events.csv` | `time_utc,rat,kind,severity,title,detail,frame,pci,arfcn,cause,setup_ms` | The kinds listed above, plus `privacy_zone` with no coordinates. `rat` is `-` for non-radio rows. Never `handover`, `rrc_*`, `attach_*` or `registration_*`: the report counts those as signalling procedures. |
| `traffic.csv` | `time_utc,test,target,ok,seconds,loss_pct,rtt_min_ms,rtt_avg_ms,rtt_max_ms,mbps,bytes,http_code,error` | `test` is `ping` or `download` only; the summary silently ignores other names. |
| `cells.csv` | `first_seen_utc,rat,plmn,mcc,mnc,tac,cell_id,enb_id,sector,pci,band,dl_earfcn,ul_earfcn,dl_bw_mhz,ul_bw_mhz,version,plausible`, then `operator,additional_plmns,samples,rsrp_min,rsrp_max` | One row per serving cell. LTE: eNB is ECI>>8, sector ECI&0xFF. NR: NCI in `cell_id`, eNB and sector blank, NR-ARFCN in `dl_earfcn`. `version` is `android`. |
| `cellinfo.csv` | The first 19 columns exactly as `fieldtap scan --watch` writes them, then `time_epoch,timestamp_ms,age_ms,stale,connection_status,source,cqi,timing_advance,csi_rsrp,csi_rsrq,csi_sinr,screen_on,charging,wifi_connected,sub_id,lat,lon` | The raw log: every cell seen, serving and neighbour, fresh and stale. The report ignores it. `fieldtap scan --watch` on the same phone is its test oracle. |

Upload and export bundle: `<dirname>.zip`, flat, only these seven files, at most 50 MiB,
sent with its SHA-256.

### Keeping both sides honest

- `schema/columns.json` is the one source of the column lists.
- `tests/fixtures/make_android_session.py` generates `tests/fixtures/android_session/`, and the
  app's `:format` test must reproduce its CSVs byte for byte.
- `tests/test_android_session.py` renders it and runs `fieldtap validate`, including the
  broken cases above.
- CI runs both sides, and the server runs `fieldtap validate` on every upload.

---

## Python side

The file format needs no Python change. Already done on the PR #1 branch:

- A session with no signalling (no capture file, or `capabilities.layer3` false) renders
  without Procedures, Call flow or the signalling tiles, keeps its Events section when it
  has events, and shows the cadence it achieved.
- `rebuild=True` on a session with no capture file keeps its KPI and event files instead of
  silently emptying them.

Also done: the contract itself. [`SESSION-FORMAT.md`](SESSION-FORMAT.md) and
`schema/columns.json` define it, `fieldtap validate DIR [--upload]` checks a session or an
upload zip, and `tests/fixtures/android_session/` is the golden session both sides test against.

Still to do: `server/worker.py`, about 150 lines. The fieldtap package has no third-party
dependencies, so the worker needs only Python 3.11 plus a Supabase client or plain `urllib`.

---

## Backend

Buy auth, database and storage. Reuse the Python for rendering.

**Supabase**, in one region chosen for the pilot (us-east-1 or ap-south-1). Paid tier before
real users, because free projects pause.

- **Auth:** email one-time code.
- **Tables,** each readable only by its owner: `profiles` (with a region from day one),
  `consents` (kind, version, text and its hash, granted and withdrawn times), `sessions`
  (the app's session ID, data class fixed to `kpi`, summary fields, zip path and hash,
  status `uploaded`, `rendering`, `ready` or `rejected`), `access_log`.
- **Private buckets** `kpi-uploads/<user>/<session>.zip` and
  `kpi-reports/<user>/<session>/`, with policies on the user prefix. There is no diag bucket
  at all, so separating data classes is structural.

**Render worker,** `server/worker.py` in this repo. It claims an uploaded row; downloads and
checks the zip (hash, 50 MiB compressed and 200 MiB uncompressed, only the seven names, no
path tricks); runs `fieldtap validate`; runs `report.build(dir, tshark=None, rebuild=False)`;
uploads `report.html` and `summary.json`; and copies the summary fields into the row. Runs
on a $5–10/month container with no inbound port.

**5gto6g.com,** static on Cloudflare Pages: landing and download page, `/privacy`,
`/delete-account`, `/app/version.json`, and "My sessions" through supabase-js with the same
one-time code. A report opens through a 5-minute signed link on the storage domain, never
inside 5gto6g.com, because reports carry notes the user typed.

**Deletion and export.** Delete session and delete account remove rows and files, from the
app and the web, with no ticket. Export is the zip. The backup retention window is published.

**Cost:** about $25/month for Supabase Pro plus $5–10 for the worker.

Not built: a custom API server, a job queue, chunked upload, device enrolment, aggregates,
roles, billing. A laptop `fieldtap upload` can use the same tables later.

---

## Distribution

**Pilot: a signed APK from 5gto6g.com, plus adb installs at onboarding. Play later.**

Android developer verification, as checked on 2026-09-10:

- **30 Sep 2026:** Brazil, Indonesia, Singapore and Thailand only, and only for installs from
  seven stores (Google Play, HONOR, OPPO, Galaxy Store, Palm Store, V-Appstore, GetApps).
  **A website APK is not covered.**
- **2027:** global. From then an unverified developer's website APK needs the advanced flow:
  a developer-options toggle, screen-lock confirmation, a warning, a restart and a one-time
  24-hour wait. That flow has been rolling out since August 2026. No field customer will sit
  through it.
- **Exempt:** adb installs, an organisation's own managed store, and non-certified devices.
- **Accounts:** limited distribution is free, needs no government ID and covers up to 20
  devices. A full account is $25, and an organisation needs a free D-U-N-S number.

**Do this week:**

1. **Register 5gto6g as an organisation** and register the package. 5gto6g must be a legal
   entity with a D-U-N-S number, and the D-U-N-S is the calendar risk. The working package ID
   is `com.fieldtap`; confirm it is available when registering, because a contested name goes
   to the verified developer with more installs. `com.5gto6g` is not legal, because each
   segment must start with a letter. If the paperwork stalls, a limited-distribution account
   covers a 20-device pilot.
2. **Generate the release key once.** Keep an offline escrow copy and a CI secret. When Play
   comes, upload the same key to Play App Signing so website and Play installs can update
   each other.
3. **The download page publishes** the version code, APK SHA-256 and certificate SHA-256,
   over HTTPS only.
4. **Updates:** a daily check of `/app/version.json` and a banner that opens the browser.
   No self-installer.
5. **Keep the manifest Play-clean:** no background location, no all-packages query, no
   battery-exemption request, no root code.

**Play, later:** an organisation account, which skips the 12-tester, 14-day closed test; the
location foreground-service declaration with a video; the new precise-location declaration
(opens November 2026, mandatory 27 Jan 2027); the data safety form; an account-deletion URL;
targetSdk 37 before August 2027; and a managed Google Play private app for fleet customers.

---

## Privacy

The app handles only the KPI data class from
[`upload-privacy-legal.md`](research/upload-privacy-legal.md). It is personal data because of
GPS, and it is about the user only. No diag, no paging, and no other subscriber's identifier
exist anywhere in it, so the interception and disclosure exposure that makes diag upload hard
does not arise.

**Collect only:** cell identity, signal values, service and data state, the 5G icon indicator,
GPS fixes at the chosen precision, test results, markers and notes, handset make, model,
build, baseband and SoC, SIM and network codes and names, a random per-install ID, the app
version.

**Never collect:** IMEI, IMSI, ICCID, serial or phone number (Android has required a
privileged permission for these since Android 10 anyway), ANDROID_ID, advertising ID, adb
serial, Wi-Fi names or MAC addresses, installed apps, contacts, call or SMS logs, IP
addresses, or any location outside a session the user started.

**In the first version:**

- **Privacy zones** applied when writing: nothing is written inside one, only an event with no
  coordinates. They ship before upload does.
- **Location precision per upload** (full, about 110 m, or none), applied to the upload copy.
  The local copy stays full.
- **Versioned consent** stored with its text and hash. Logging and upload are separate choices,
  and withdrawing upload consent leaves local logging working.
- **Full-screen disclosure** before the location prompt, explaining that Android returns no
  cell info without precise location.
- **HTTPS only,** system CAs only.
- **On the phone:** app-specific storage, no backup, uploads only after a session stops, and
  crash logs never attach session files.

**Legal posture.** Self-serve signup would make Simnovus a GDPR controller, and a CPRA handler
of precise geolocation, which is sensitive personal information. **So the pilot is
invite-only, for a named team.** A privacy notice, a record of processing and a short risk
assessment come before any public signup. India's DPDP rules apply if the pilot is in India.

---

## Development setup

**The MacBook is primary,** because the phone is attached there.

- Android Studio (Apple Silicon), SDK 36 and 37. No USB driver needed. Approve macOS's
  "Allow accessory to connect" prompt; a missed prompt looks like a charge-only cable.
- `./gradlew installDebug`, then Logcat and the Background Task Inspector.
- Run `fieldtap scan --watch 2 -o oracle.csv` while the app records. The first 19 columns
  of `cellinfo.csv` diff directly against it.
- Pull sessions with `adb pull /sdcard/Android/data/com.fieldtap/files/sessions`,
  then run `fieldtap report` on the Mac.

**Measurement traps,** from Android's own `DeviceStateMonitor`:

- USB to the Mac charges the phone. That forces the 2 s interval with the screen on, and keeps
  signal updates on with the screen off.
- Wireless debugging connects Wi-Fi, which forces 10 s unless charging.
- **So cadence and kill-survival tests run unplugged, with Wi-Fi off and the screen off,** and
  results are pulled afterwards.

**The Windows machine** has JDK 21, the Android SDK and Gradle installed in the user folder
(`~/tools/android-env.sh` sets the paths), so it compiles the app and runs the JVM tests. It
cannot run an emulator: Hyper-V holds the CPU's virtualization, and it has 7.8 GB of RAM. An
emulator's modem is synthetic anyway, so an emulator run proves the app works end to end, not
that its measurements are right.

**CI, GitHub Actions:** on push, the JVM tests, a debug build, and an **emulator job**. That
job boots an Android emulator on a Linux runner, installs the app, runs a session end to end,
checks the session with `fieldtap validate` and renders it with `fieldtap report`. On a tag: a
signed release build, upload to 5gto6g.com, and an updated `version.json`.

**Phones:**

- **Put a prepaid data SIM in the OnePlus on day one.** Without one it is emergency-camped on
  a single Verizon NR cell (n2, PCI 269), sees no real neighbours, and cannot run any data
  test. Keep one SIM-less run as a regression case.
- **Add one unrooted Samsung Galaxy, and optionally a Pixel, before the pilot.** The rooted
  OnePlus is not a customer's phone.

---

## Phases

| Phase | Deliverable | Effort |
| --- | --- | --- |
| **0. Prerequisites** | SIM in the OnePlus; unrooted Samsung ordered. Organisation registration and D-U-N-S started; package and release certificate registered; key escrowed. The `android/` project, with CI that builds it and runs it on an emulator. `SESSION-FORMAT.md` and `columns.json` agreed. `dumpsys telephony.registry` baselines captured with and without the SIM. | 2–3 days; verification paperwork runs 1–4 weeks in the background |
| **1. Probe spike** (week 1) | A throwaway APK writing `cellinfo.csv`. It measures: the fresh-sample interval across screen, Wi-Fi and charging states; whether timestamps advance and SINR looks plausible; that cell-info updates work without the Phone permission while the push and physical-channel listeners refuse; and a 2-hour screen-off, unplugged soak on OxygenOS 15, with and without the battery settings and a wake lock, with exit reasons. **Ends in a go/no-go** on the wake lock and on what walk and pocket modes can promise. | 1 week |
| **2. Logger alpha** (weeks 2–3) | The `:format` writer for all seven files, the freshness engine, events, GPS matching, crash recovery, readiness check and soak test, probe screen, disclosure and consent, privacy zones, the Live, Sessions and Detail screens, zip export. Python: `fieldtap validate`, fixture, contract tests, CI green. **Exit test:** a 30-minute pocket walk and a 30-minute walk-mode walk on the OnePlus with a SIM render with `fieldtap report`, and `cellinfo.csv` agrees with `fieldtap scan --watch`. Debug APK to 2–3 friendly engineers. | 2 weeks, plus 2 days Python |
| **3. Tests and hardening** (week 4) | Ping and download bound to cellular, with caps, budget, and failures as events. Storage cap; Mark and Stop in the notification; illustrated OxygenOS and One UI battery guidance. **Exit test:** a 1-hour screen-off session with the SIM in and Wi-Fi left on survives, `traffic.csv` shows cellular round-trip times, and battery drain per hour is measured and published. | 1 week |
| **4. Account and upload** (weeks 5–6) | Supabase tables, policies and buckets; the render worker; the 5gto6g.com pages; in the app, sign-in, consent, precision, upload, open report, delete, update banner; the first signed release APK with checksums. | 1 week backend and web, plus 1 week app |
| **5. Pilot** (week 7) | One invite-only team, up to 20 devices, at least two phone makers. The probe run on every handset, and fixes for what it finds. A weekly review of gaps, repeat ratios and exit reasons. A published supported-device list. | 1 week, then 1–2 weeks a quarter of upkeep |
| **6. Play and managed distribution** (later) | Organisation Play account with the same key; the declarations; data safety form; a managed Google Play private app for the first fleet customer; targetSdk 37 before August 2027. | 1–2 engineer-weeks, plus 2–6 weeks of review |

---

## Risks

| Risk | Mitigation |
| --- | --- |
| The test phone exercises half the product: SIM-less, emergency-camped on one cell, and rooted. | A SIM on day one, and an unrooted Samsung before the pilot. |
| OxygenOS kills the session, and its battery settings revert on their own. No developer-side fix exists. | Foreground service, a readiness check before every session, soak test, heartbeats, recovery with the exit reason. Nothing fully solves it; the app records it honestly. |
| Cadence collapses in normal use: 10 s with the screen off or on Wi-Fi, and no signal updates screen-off on battery. Users expecting laptop density will call it broken. | Walk mode; cadence shown live and stored; tests run unplugged with Wi-Fi off. |
| The wake-lock trade-off. Without one, the ticker may stall indoors; with one, a future Play listing risks the wake-lock penalty. | The week 1 measurement decides. If needed, the website build only. |
| The Kotlin writer and the Python reader drift apart. | `columns.json`, the golden fixture, and `fieldtap validate` in CI and on every upload. |
| The Python package lives only on open PR #1, and another account pushes to main. | The app branch is based on PR #1's branch; merge PR #1 before the app branch. |
| Vendor variation: timestamps that never advance, SINR in the wrong unit, a missing NSA leg or neighbours, dual-SIM confusion. | The probe, a supported-device list, and implausible values written blank instead of wrong. |
| Seen as a NetMonster clone. | Lead with the report, the account and honest freshness, never the live meter. |
| 2027 verification makes website installs painful. | Register the organisation now. |
| The release key is lost or leaked, stranding every install or enabling a malicious update. | Escrow, a CI secret, a named custodian. |
| Controller liability for precise location. | Invite-only pilot; consent, precision and zones in the same release as upload; a notice and assessment before public signup. |
| Test data cost, and tests polluting the measurement. | Off by default, 10 MB cap, a budget, our own host, no uploads during a session. |
| No named Android owner. SDK bumps, Play declarations and the device list rot without one, as they did for MobileInsight. | Name one before Phase 4. |
| A small market on its own: RantCell has run this shape for 16 years at under $1M revenue. | Treat the app as the walk leg and the route into a FieldTap account, not as the whole business. |

---

## Decisions

**Made on 2026-09-10:** the brand is 5gto6G FieldTap; everything is under 5gto6g; the publisher
is 5gto6g as a company; the working package ID is `com.fieldtap`; the code is in `android/` of
this repository; the app is free for now.

**Still open:**

1. **Is 5gto6g already a registered company?** If not, registering it and getting a D-U-N-S
   number come before Google developer verification.
2. **Confirm the package ID** before registering it. It is permanent once registered.
3. **Pilot model and region.** An invite-only named team (recommended) or public signup; US or
   India hosting. This decides whether the privacy paperwork blocks launch.
4. **Hardware budget.** A prepaid data SIM for the OnePlus and at least one unrooted Samsung,
   optionally a Pixel.
5. **Who owns Android after launch:** releases, SDK bumps, Play declarations, the device list.
   Needed before Phase 4.

---

## The Android facts this rests on

Checked against AOSP source and Google's documentation on 2026-09-10.

| Call | Min API | Needs | What it means here |
| --- | --- | --- | --- |
| `TelephonyManager.requestCellInfoUpdate` | 29 | Precise location only | The main source. Inside the refresh interval it returns the cached list. |
| `TelephonyManager.getAllCellInfo` | 17 | Precise location | Cached results only, for apps targeting Android 10+. Used for the first screen only. |
| Cell-info refresh interval | | | 2 s if a display is on and (no Wi-Fi network with internet is connected, or the phone is charging); otherwise 10 s. Charging is `BatteryManager.isCharging()`: plugged in below 90 %, only once the battery level rises, reported 15 min later; not merely plugged in. A display the proximity sensor blanks is off. |
| `CellInfoListener` | 31 | Phone **and** precise location | Optional. `READ_BASIC_PHONE_STATE` does not satisfy it. |
| `SignalStrengthsListener`, `DataConnectionStateListener` | 31 | Nothing | Signal updates stop screen-off on battery unless tethering or Android Auto is on. |
| `ServiceStateListener` | 31 | Nothing to register | Operator fields are null without location. |
| `DisplayInfoListener` | 31 | Nothing, at targetSdk 31+ | The 5G icon decision, not a measurement. |
| `CellInfo.getTimestampMillis` | 30 | | Milliseconds since boot when the modem reported it. Unchanged means a repeat. |
| `CellSignalStrengthLte.getRssnr` | | | dB, −20 to +30. Out-of-range values are already mapped to unavailable; the probe checks in-range units. |
| `PhysicalChannelConfigListener`, `BarringInfoListener`, `RegistrationFailedListener` | 31 | `READ_PRECISE_PHONE_STATE` (signature or privileged) | **Not usable.** |
| `TelephonyManager.requestNetworkScan` | 28 | `MODIFY_PHONE_STATE` (signature, privileged or role) | **Not usable.** |
| Foreground service type `location` | 29 | `FOREGROUND_SERVICE_LOCATION`, location granted at start | Cannot be started from the background. Keeps location after Home or screen-off. No Android 15 time limit. |
| `POST_NOTIFICATIONS` | 33 | Runtime prompt | Refusing it does not stop the service. |
| ICMP datagram socket plus `Network.bindSocket` | 21 / 23 | `CHANGE_NETWORK_STATE` (normal) | Allowed by Android's `ping_group_range`; still to confirm on OxygenOS. |
| Partial wake lock | 1 | `WAKE_LOCK` | Play flags over 2 h a day in more than 5% of sessions. System location wake-ups are exempt; app wake locks are not. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | 23 | Normal | Restricted on Play, so not declared. Link to the settings screen instead. |
