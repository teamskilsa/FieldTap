# iPhone baseband capture: the sysdiagnose route

**Date:** 2026-09-22
**Handset:** iPhone 17 (Qualcomm M25 modem), iOS build 23F84, Apple's "Baseband and Telephony Logging" profile
installed from Settings. One capture: `sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz`
(408 MB, 929 MB unpacked).
**Result:** the modem's own Qualcomm DIAG log comes out of a stock, non-jailbroken iPhone. FieldTap rebuilds it
into an ordinary `.qmdl` (`fieldtap qdss`), and the same decoders that read the Android captures read it:
128 call-flow events (LTE RRC 100, NR RRC 4, NAS 24), 34 procedures, and 132 frames in stock Wireshark.

This supersedes the earlier "iOS is a dead end" conclusion in
[`cellular-app-landscape.md`](cellular-app-landscape.md) and [`../APP-AND-CLOUD-PLAN.md`](../APP-AND-CLOUD-PLAN.md).
What stays true: iOS has no API for live cell measurements. What is new: the user can hand FieldTap a modem
trace after the fact.

Everything capture-derived (the archive, the trace chunks, the recovered `.qmdl`, the goldens) stays out of git,
in `ios/Fixtures/local/` or the user's Downloads folder. The capture holds the phone number, IMSI, IMEI and IP
addresses; none of them appear here.

Evidence key: **[measured]** was read from the capture or computed on this Mac; **[source]** is a cited public
page; **[unverified]** is a claim nobody here could check.

---

## 1. The route in one picture

    Apple's Baseband profile (installed by the user, lasts 7 days)
      -> the modem writes a QDSS trace into a ring of ~1 MiB chunks
      -> the user presses the sysdiagnose buttons; iOS dumps the ring into the sysdiagnose
      -> Settings > Privacy & Security > Analytics & Improvements > Analytics Data > sysdiagnose_... > Share
      -> FieldTap for iPhone (share sheet), or a Mac: fieldtap qdss sysdiagnose_....tar.gz -o capture.qmdl
      -> the call flow (FieldTap's decoders), or pcapng for Wireshark (fieldtap decode capture.qmdl)

On a Mac:

```sh
python3 -m fieldtap qdss ~/Downloads/sysdiagnose_....tar.gz -o capture.qmdl --stats stats.json
python3 -m fieldtap decode capture.qmdl          # capture.pcapng, stock Wireshark dissectors
```

`fieldtap qdss` streams the archive, keeps only `logs/Baseband/log-bb-*-qdss/0x*.bin` (134 MB of the 929 MB) in a
temporary folder, skips the AppleDouble `._` copies macOS tar leaves next to every file, and deletes the chunks
when it is done. On this capture it takes about 70 s and writes 39,974,284 bytes, md5
`e53a167b29b25560938d1f089e719d33`, the same bytes as the reference deframer **[measured]**. It also prints the
profile's install and removal dates and the stretch the trace covers after the button press ("0:19 to 0:46"), and
for an archive without a trace, which of the reasons in section 2 applies.

## 2. Turning modem logging on

What the user does, once every 7 days (about 3 to 5 minutes, free):

1. Open Apple's Profiles and Logs page in Safari,
   <https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=baseband> (the older
   `/bug-reporting/profiles-and-logs/` address answers 301 to it), and sign in with an Apple Account **[source]**.
   Third parties say a free developer account is enough; Apple's page does not say **[unverified]**.
2. Under iOS, tap Baseband, then Download, and Allow when iOS asks whether the website may download a
   configuration profile.
3. Within 8 minutes: Settings > Profile Downloaded > Install, enter the passcode, read the consent text, Install.
   A downloaded profile that is not installed within 8 minutes is deleted, and only one can wait at a time.
   Stolen Device Protection blocks the install away from a familiar location **[source: Apple Support 102400]**.
4. Restart only if asked, or if the first import shows no modem trace. On this phone the trace was running
   within two minutes of the install **[measured]** (whether it was restarted in between is not known);
   CellGuard's guide tells users to restart **[source]**.

FieldTap can tell from each imported archive which state the phone was in **[measured, from the archive
layout]**:

| What the archive shows | What it means |
| --- | --- |
| `logs/Baseband/log-bb-*-qdss/` with `0x*.bin` chunks | logging was on; the trace is there |
| no qdss folder, and `logs/Baseband/ambtool_output.log` says baseband logs are not enabled | modem logging is off |
| no `logs/MCState/Shared/profile-*.stub` carrying `com.apple.basebandlogging` | the profile was never installed, or was removed |
| the stub's `RemovalDate` is in the past | the profile expired |
| the stub is there and current, but no qdss folder | installed, but no trace yet: restart and try again |

The stub is an 18 KB XML plist with `PayloadIdentifier`, `InstallDate` and `RemovalDate`, so the app can show
"Logging is on until <date>" and remind the user a day before it lapses, without touching any system file.

## 3. What the profile is, and why FieldTap cannot ship it

Read from the copy installed on this phone (`logs/MCState/Shared/profile-*.stub`) **[measured]**:

- PayloadIdentifier `com.apple.basebandlogging`, "Baseband and Telephony Logging", organisation Apple Inc.,
  installed interactively from Settings. Signed by Apple's "AppleCare Profile Signing Certificate", issued under
  Apple Root CA.
- Two payloads. `com.apple.system.logging` raises about 30 telephony logging subsystems to Info level with public
  privacy. `com.apple.defaults.managed` writes the `com.apple.commcenter` domain: `EnableBasebandLogging =
  {History 8, Profile 1, Sleep 0}`, `TelephonyLoggingPriority 3`, `TelephonyLoggingVersion 18`.
- It is only a switch. The list of what the modem logs is already on the phone: the trace folder's
  `Default.dmc` (a QXDM configuration) enables 1,349 log codes, every PHY code FieldTap plots among them.
- InstallDate 2026-09-21 19:40:06 UTC, RemovalDate 2026-09-28 19:40:02 UTC: **7 days**. A public 2025 copy
  used 21 days **[source: pathtofile/ios_configuration_profiles]**, so the app reads the dates from each archive
  rather than assuming.

Why it cannot be part of the app, ranked:

1. **No API.** iOS has no call that installs a configuration profile; opening a profile URL hands it to
   Safari and Settings, and the user still installs it by hand. Apple's engineers say only Apple can create
   logging profiles for iOS, and that apps get no supported access to low-level cellular data
   **[source: Apple Developer Forums threads 70696, 726871, 751785]**. Bundling would not save a single tap.
2. **It is Apple's file.** It is served only after sign-in, as developer-site content the Apple Developer
   Agreement forbids sharing or redistributing (sections 3, 5 and 7); the 2025 copy's consent text calls it
   confidential and not for distribution **[source]**. Editing it breaks Apple's signature.
3. **App Review.** Guideline 5.5 puts apps that offer configuration profiles under the MDM rules (enterprises,
   schools, governments), and 2.5.1 allows public APIs only **[source]**. A look-alike FieldTap profile would
   also clone an Apple-only payload that, on all the evidence, iOS would not honour.

So v1 of the iPhone app opens Apple's page in Safari (never an in-app browser), explains each system prompt
before it appears, and checks the result from the next import. For company-owned supervised iPhones, an MDM can
push Apple's profile without the Settings steps **[unverified for this profile]**.

## 4. Taking a capture: press first, reproduce 20 to 40 s later

This is the timing measured on the one capture above; treat it as an early result.

The archive name carries the moment the buttons were pressed: 15:41:47 local, UTC-4, so **19:41:47 UTC**. The
trace folder's `info.txt` lists every chunk the modem wrote for this dump and when each started, and the folder name
(`log-bb-2026-09-21-15-42-33-844-qdss`) says when the dump ended **[measured]**:

| | Seconds after the press |
| --- | --- |
| first chunk listed (0x00), start | -2 |
| chunks started before the press | 8 chunks, 7.8 MiB; `info.txt` says "Max memory file count: 8" |
| first kept chunk (0x6F), start | +19 |
| first plausible modem timestamp in the trace, 19:42:05.984 UTC | +19.0 |
| last modem timestamp, 26,959 ms later | +45.9 |
| last chunk (0xF0), start | +46 |
| dump finished (folder name) | +46.8 |

241 chunks were written (237 MiB in 48 s, about 4.9 MiB/s), and the ring kept the last 130: 111 were
overwritten. So a sysdiagnose does **not** capture the seconds before the press. Before the press only the 8
buffered chunks, about 1.6 s, exist, and they were overwritten too. What survives is roughly **19 to 46 s after
the press**. Hence the capture steps the app coaches:

1. Press both volume buttons and the side button together, briefly (about a quarter of a second; holding
   longer than a second locks the phone), until it buzzes **[source: Apple's sysdiagnose instructions]**.
2. About 20 to 40 s later, do the thing that fails (the call, the attach, the handover).
3. Wait up to 10 minutes for the sysdiagnose to finish.
4. Settings > Privacy & Security > Analytics & Improvements > Analytics Data > sysdiagnose_... > Share > FieldTap.

On import the app computes the same window from the archive name, `info.txt` and the chunk times, and says
what the trace covers ("0:19 to 0:46 after you pressed the buttons") and how many chunks were overwritten. It
says nothing about airplane mode or any other radio state it did not see in the trace.

## 5. The QDSS trace format

What `fieldtap/diag/qdss.py` undoes. It ports the verified default rules of the reference deframer kept with
the local fixtures, and matches it byte for byte on the whole capture, on two chunk windows (first3: chunks
0x6F to 0x71; attach4: chunks 0x81 to 0x84) and on the synthetic traces in `tests/test_qdss.py` **[measured]**.

- **Files.** `0x%08X.bin` chunks of about 1 MiB, named in trace order, and `header.qmdl2`, a 77-byte descriptor
  that is not stream data. The sysdiagnose adds `info.txt` and `trace.info`; FieldTap reads only file names and
  times from them, never the GUID, DiagID or hardware model.
- **Layer 1, the ARM CoreSight trace formatter.** 16-byte frames (TMC/ETR memory-aligned, no FSYNC), aligned to
  the start of each chunk, with the current trace ID carried from one chunk into the next. An even byte with its
  low bit set is a change of trace ID; the aux byte (byte 15) gives the low bits of the data bytes and says
  whether the byte after an ID change still belongs to the old ID. The DIAG traffic is trace ID 0x32:
  124,618,275 bytes of the 134 MB.
- **Layer 2, 16-byte units** at a fixed phase (8 here) in that stream. The first byte is a 3-bit lane and a
  5-bit type: fill (every 65th unit), channel (binds a lane to a u16 channel), start of fragment (class, u16
  length, then up to 8 payload bytes) and continuation. Payloads of 240 bytes or more travel as bursts of 16
  units: 15 carry bytes 1 to 15 of a 16-byte line whose byte 0 the unit tag overwrote, and the 16th carries
  those 15 displaced bytes. The rest comes 12 bytes per unit, and the last unit, when it is partial, carries its
  32-bit words in reverse order. Fragments are gathered per channel by kind: whole, QShrink F3 text (skipped),
  first, middle, last. 1,128,612 fragments, every one fitting its length exactly.
- **Layer 3, DIAG packets.** `98 01` wraps several packets; `10 00` is a plain log packet (code, 64-bit modem
  timestamp, body); `9e 01 c2 00` is a "secure" log whose body the modem encrypted; F3 text, extended messages,
  events and command responses are counted and dropped. Result: 92,133 log records over 224 log codes, written
  one HDLC frame each; 23,764 secure records over 61 NR physical-layer codes, which the modem encrypted and
  FieldTap cannot read.
- **Order.** Timestamps rise within a channel but channels interleave with a lag, so records are sorted by an
  effective timestamp: the record's own when it is plausible, otherwise the last plausible one on its channel.
  5,139 records carry no timestamp and 33 an implausible one.

What changed in the decoders so the iPhone trace reads (contract v1, `ios/Contract/CONTRACT.md`):

- LTE RRC OTA (0xB0C0) **packet version 30**: the version-27 header plus three bytes after the length, 24 bytes
  with the version, PDU numbering map D. The length fits in 100 of 100 records.
- NR RRC OTA (0xB821) **packet version 26**: 35 bytes with the version; eight bytes of cell identity (never
  output) before the NR-ARFCN, and four reserved bytes after the length. PDUs 11 and 12 are the EN-DC
  RRCReconfiguration and its Complete; 36 is RadioBearerConfig (decoded by the Python tools; Android and the
  iPhone app leave it for contract v2). The length fits in 7 of 7 records.
- The call flow measures time from the first plausible timestamp, and answers a procedure only on the RAT it
  started on (the NR reconfiguration inside an LTE one no longer closes it as unanswered). An NR header logged
  before the 5G cell is assigned (PCI 0xFFFF) shows as "NR cell pending".
- The log-code register names 0xB80C as the 5GMM state record it is (MobileInsight, SCAT and DiagNG agree, and
  the one record in the trace is state-shaped), 0xB826 as NR5G RRC Supported CA Combos, and 0xB061 as LTE MAC
  RACH Trigger.

## 6. Limits

- **About 27 s of trace per sysdiagnose,** because the ring holds 130 chunks (about 128 MiB) and the modem logs
  about 4.9 MiB/s with Apple's default log mask. A longer test needs several sysdiagnoses.
- **After the fact only.** Nothing is live; each import is a batch.
- **Encrypted records.** 23,764 of the records are encrypted by the modem (the NR5G ML1/L1 set): counted, shown
  as such, never guessed at.
- **One handset, one build.** Every layout above is measured on the iPhone 17 with iOS 23F84. A new model or
  baseband firmware first gets its own local fixtures; an unknown packet version is shown as "not decodable",
  never approximated.
- **The profile lapses** after 7 days, and Apple has changed that length before.

## 7. Who else does this

Summarised in [`../COMPETITIVE-LANDSCAPE.md`](../COMPETITIVE-LANDSCAPE.md#iphone). In short: the commercial
suites that log iPhones (TEMS, ROMES4 with ROMES Probe, XCAL-iSolo) do not publish how, and appear to rely on
partner access; CellGuard, a TU Darmstadt research app, uses the same Apple profile and sysdiagnose but reads the
modem's control messages from the system log, not the QDSS trace; the open DIAG tools do not read `.qdss`. No
public tool was found that decodes iPhone RRC and NAS from a sysdiagnose **[source; an absence of evidence, not
proof]**.

## Licences

The deframer and the layouts are FieldTap's own work from the capture. GPL projects (SCAT, QCSuper, DiagNG,
CellGuard, BaseTrace, Wireshark's dissectors) and AGPL srsRAN were read for facts only: no code, tables or
comments were copied. The log-code names added to `fieldtap/decode/registry.py` follow MobileInsight's table
(Apache-2.0); names are factual identifiers, and the iPhone app credits MobileInsight in Settings > Licences
(`ios/README.md`).

## Sources

- Apple Profiles and Logs, Baseband: https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=baseband
- Apple Support, install a configuration profile (8 minutes, one pending, Stolen Device Protection): https://support.apple.com/en-us/102400
- Apple sysdiagnose instructions (button chord, 10 minutes, Analytics Data): https://podcasters.apple.com/assets/iOS-sysdiagnose-logging-instructions.pdf
- Apple DTS on installing profiles from an app: https://developer.apple.com/forums/thread/70696
- Apple DTS, only Apple creates iOS logging profiles: https://developer.apple.com/forums/thread/726871
- Apple DTS, no supported low-level cellular access: https://developer.apple.com/forums/thread/751785
- App Review Guidelines 2.5.1 and 5.5: https://developer.apple.com/app-store/review/guidelines/
- Apple Developer Agreement (March 2025): https://developer.apple.com/support/downloads/terms/apple-developer-agreement/Apple-Developer-Agreement-20250318-English.pdf
- Public 2025 copy of the profile (21 days): https://github.com/pathtofile/ios_configuration_profiles
- CellGuard install guide and source: https://cellguard.seemoo.de/docs/install/ ; https://github.com/seemoo-lab/CellGuard
- SCAT, `.qdss` not supported: https://github.com/fgsect/scat/wiki/Baseband-Dumps
- QMDL-to-pcap and the newer qdss format: https://blog.cacombos.com/2021/06/13/convert-qmdl-to-pcap/
- MobileInsight (Apache-2.0): https://github.com/mobile-insight/mobileinsight-core
