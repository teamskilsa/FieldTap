# FieldTap call-flow contract v1

The contract between the Android app (Kotlin, `android/diag` + `CallFlowPresentation.kt`) and the iOS app
(Swift, `ios/FieldTapKit`) is **golden JSON produced by the Kotlin decoders on the JVM**. Both languages are
tested against the same files. Parity is enforced by these fixtures, not by shared binaries.

Contract v1 = repo `main` + D1 + D2 + D3 + D4. Until WP1 lands v1 in `android/`, the v1 Kotlin lives in
`Contract/src-v1/` (git-ignored, local only) and `contract-v1.diff` shows exactly what changes.

## Changes in v1

| | Rule | Measured effect on the iPhone 17 capture (`iphone-recovered.qmdl`) |
| --- | --- | --- |
| D1 | **Time base.** Measure from the first *plausible* (UTC >= 2005-01-01) modem timestamp; only when there is none, from the first non-zero one, as before. `durationMs` runs to the last plausible stamp. | The capture starts with records stamped before the modem had network time (the QDSS stats count 33 implausible and 5,139 zero stamps). With D1 the trace is 26,959.395 ms long and starts at Unix ms 1,790,019,725,984 (2026-09-21 19:42:05.984 UTC). OnePlus goldens are unchanged (their durations, including the negative -99,494.492 ms of the 5G registration capture, are what repo `main` produces). |
| D2 | **Header layouts.** LTE RRC OTA (0xB0C0) packet version 30 = header layout E with PDU map D; NR RRC OTA (0xB821) version 26 = layout E, with PDU 11 = RRCReconfiguration and 12 = RRCReconfigurationComplete. | Without it no iPhone RRC decodes (repo `main`: 75 events, 5 procedures). With it: 128 events (RRC LTE 100, RRC NR 4, NAS 24), 34 procedures, 4 journey steps. |
| D3 | **RAT-scoped procedures.** An open procedure is answered, and superseded by a new start, only by events on the RAT it started on. | On EN-DC the NR RRCReconfiguration inside the LTE one no longer closes the LTE one: RRC reconfiguration goes from 18/20 (2 false UNANSWERED, events 72 and 77) to 20/20. 2 procedure lines and 5 presentation lines change; attach4 and both OnePlus goldens are byte-identical. |
| D4 | **Pending NR cell.** An NR RRC header logged before the SCG cell is assigned carries PCI 0xFFFF or ARFCN 0xFFFFFFFF; `CallFlowPresentation.shortCell` shows it as "NR cell pending", never as a PCI. | Event 73's cell. Swift: `Cell.isPendingNr`. |

`contract-v1.diff` is `diff -u` of the repo's CallFlow.kt, LteRrc.kt, NrRrc.kt and CallFlowPresentation.kt
against `src-v1/` (D1-D4); `contract-v1-d3-d4.diff` is the D3/D4 part alone.

## Masking

**Golden masking** (`tools/GoldenDump.kt`, Swift `Redaction.mask`), applied to every golden:

- A field whose label matches `IDENTITY_LABEL` is masked, and so is every field under it:
  `(?i)(^identity$|imsi|imei|tmsi|guti|suci|supi|msisdn|mobile identity|ue identity|i-rnti|s-tmsi|random ?value|address|\bip\b|ipv4|ipv6|dns|p-cscf|pcscf|interface identifier|cell identity|\bnci\b|\beci\b)`.
  A masked leaf becomes `<masked>`; a masked field *with* children keeps its own value scrubbed ("Identity:
  GUTI" still says which identity it was).
- In every other string (field values, summaries, procedure details and refusals) these are replaced by
  `<masked>`, in this order: IPv6, IPv4, runs of 10+ digits (`\+?\d[\d ]{8,}\d`), 0x-hex of 8+ digits.
- PDU bytes are never written (only `pduLength`); `cellIdentity` is always `"<masked>"`.

**Display rules** (stricter, the app only): identifiers are masked on every screen, in copy and in share unless
the user reveals them for the session (Settings, with a confirmation; reset on relaunch). While masked, the
message sheet hides the hex dump, and the cell views also mask **TAC** and **cell identity**
(`Redaction.displayCellInfo`), because with the PLMN they locate the phone.

## Comparator

`tools/json_equal.py A B [--tolerance 0.0015] [--ignore PATH]...` and Swift `GoldenCodec.jsonDiff` implement
the same rules:

- objects compare by key set and value; arrays by length (`path.length`) and position;
- strings and booleans exactly (a boolean never equals a number);
- numbers within an absolute tolerance of 0.0015 (goldens print 3 decimals), integers too, so equal 17-digit
  modem timestamps compare exactly;
- `--ignore` takes dotted paths without indexes and skips them at every position (`source.file`,
  `events.cell`); `source.file` is ignored by default in Swift.

Presentation strings (`presentation-golden.json`) must match exactly: numbers there are text produced by
Java's `String.format(Locale.ROOT, "%.Nf")`, which rounds the shortest round-trip decimal half up (0.125 ->
"0.13", 2.675 -> "2.68"); Swift uses `Fmt.fixed` / `JavaDecimal.fixed`, checked against openjdk 21.

## Journey rules J1-J12 (FTJourney, WP5)

FTJourney is a pure function `build(flow, phySummary, facts)`. It uses only parity CallFlow outputs (steps,
connections, procedures, events) plus the PHY summary, so Android can implement the same rules against
`journey-expected.json` later.

- **J1** time base = CallFlow D1 (first plausible timestamp); length = `flow.durationMs`.
- **J2** established Connections give 'connected' [startMs, endMs or end of capture; openAtEnd]. LOST gives
  connected then a failure marker. REJECTED gives a failure marker; NO_ANSWER a warning.
- **J3** an uplink 'Detach request' with 'Switch off' = 'yes' at t0 starts 'radio off'. It begins at the first
  RRC release within 2 s after t0 (else at t0) and ends at the first RRC event of any channel after it. Marker
  detachSwitchOff at t0. If no later event exists, the finding reads 'switched off at the end' and says nothing
  about a radio restart.
- **J4** other gaps after the first RRC event are 'idle'; before it, 'unknown'.
- **J5** registration is 'deregistered' from a switch-off detach (or Detach accept / Attach or Registration
  reject) until the end of a successful Attach or Registration. Before the first NAS evidence it is 'registered
  (assumed)' if the first NAS procedure is Detach/TAU/Service request, otherwise 'unknown'.
- **J6** PCell segments come from `flow.journey` steps. Start = the earlier of step.sinceStartMs and the first
  RRC event, any channel, on step.to after the previous segment ended. End = the next step, the start of radio
  off, or the capture end. Band from the Spectrum port. NR SA steps use `NrBands.candidates(arfcn, mcc)`.
- **J7** moves give markers. HANDOVER: marker at the last isHandoverCommand event within 1 s before the step,
  arrivalMs = step time, durationMs from the Handover procedure. RESELECTION becomes 'reattach' when a J3 radio
  off ended inside the gap and an Attach starts on the new cell before any other connection; otherwise it stays
  'reselection'. REDIRECT and REESTABLISHMENT (warning) and CELL_CHANGE (warning: 'changed cell while
  connected without a logged handover') each give their own marker. The ladder shows the annotation as a
  subtitle on the parity Move row.
- **J8** EN-DC. An NR rrcReconfiguration (0xB821) while an LTE connection is open starts an SCG add when no
  PSCell is active or the header cell is pending or different. The PSCell is the first NR RRC event on a
  non-pending cell within 200 ms (the NR rrcReconfigurationComplete; addedMs). Later NR rrcReconfigurations on
  the same cell give scgModify. The end is the first of: an LTE handover command (endInferred, reason
  'handover'), LTE RRC release, re-establishment request, radio off, a key containing 'scgFailure' (failure
  marker), or capture end (openAtEnd). phyLastMs comes from PhySummary.nrDlActivity; if NR PHY continues more
  than 500 ms past the inferred end, a warning finding is added.
- **J9** one SCell lane per PhySummary.scellActivity entry [firstMs, lastMs], band from the Spectrum port,
  source phy.
- **J10** RACH markers from PhySummary.rach (TA x 78.12 m).
- **J11** failure markers: each Event.isFailure (failure); Procedure FAILED (failure at its first event, with
  the refusal text); Procedure UNANSWERED (warning); duplicate markers at one event are merged, keeping the
  highest severity.
- **J12** findings are ordered by time, then the fixed tail: failures or noFailures, encryptedRecords,
  traceWindow. KPI tiles as listed in the Overview screen.

**v1 amendments from the design critique** (binding for WP5; `journey-expected.json` is regenerated or
compared as described):

- Marker order: stable sort by tMs, then kind rank (the fixture lists attach at 2592.758 after rrcSetup at
  2593.419 and RACH at 2659.6); compare in that order or as a multiset.
- Ids are unique and stable: kind plus event (or time for PHY-derived markers), e.g. `handover-82`,
  `rach-2659.6`; finding ids likewise (`Finding.kind` carries the category).
- NR band candidates for test PLMNs (001/999) are not narrowed, and overlapping bands are all listed:
  647328 (3709.92 MHz) gives [77, 78], 501390 gives [41, 90], 174770 (873.85 MHz) gives [5, 26].
- Carrier attribution: 0xB173/0xB139/CSF/0xB064 samples carry only a carrier index; they are mapped to cells
  through the Journey at time t (FTJourney or the Radio page), with a test.
- Tiles include serviceRequest and registration.

Expected for this capture: state unknown 0-725.8, connected 725.8-1854.5, radio off 1854.5-2415.5, idle
2415.5-2593.4, connected 2593.4-26959.4 (open); registration registered (assumed) until 1813.0, deregistered
1813.0-2927.6, registered after; PCell B2 650/80, B66 67086/80, B12 5110/235, B2 650/80; PSCell NR 174770/80
(n5/n26) 13798.7 (added 13812.8) to 15039.5, inferred at the HO command, NR PHY last 15023.0; SCells 1/2/3
15390.5-16067.4 / 20214.3 / 20175.5; 13 markers, 0 failure markers, 10 findings. Tolerance 1 ms for
event-derived times, 100 ms for PHY-derived.

## PHY parity (FTPhy, WP4)

FTPhy ports the validated reference extractor (`Fixtures/local/reference-phy/kpis.py` and friends) with the
same numbers, not the same code: `phy-golden.json` (48 KPIs: unit, code, count, min, max, mean, per-index
arrays, first and last 3 samples) and `phy-summary.json` (SCell and NR DL activity, RACH/TA, antennas,
encrypted census) are the contract. Sample counts are exact; min, max and mean within 0.01 (or 1e-4
relative); sample times within 1.0 ms. Times are ms since the D1 time base (`timeBase.unixStart` in the
golden is 1,790,019,725.984205 s).

Known reference shortcuts that the Swift port must **not** copy (critique): `kpis.py` keys the
lte_dl_bler / lte_dl_phy_throughput bins by (UTC second, earfcn, pci, cc) and lte_ul_phy_throughput by
(UTC second, earfcn, pci) from a hard-coded PCELL table, and takes NR ARFCN 174770 from a hard-coded NR_CELL.
Contract rule: bins are keyed by (whole UTC second, carrier index) with tMs = second + 0.5 s relative to the
time base, and the NR DL earfcn is null (FTJourney attributes it). WP4 regenerates phy-golden/phy-summary with
`reduce_phy.py` under that rule, or exempts exactly those 3 KPIs and fields, and says which. N_RB per EARFCN is
inferred by snapping (RSRQ - RSRP + RSSI) to the nearest 10log10 of {6, 15, 25, 50, 75, 100}. The TBS tables
come from 3GPP TS 36.213 / 38.214 (the srsRAN files in reference-phy/refs are AGPL-3.0: facts only).

## Strict version policy

Every PHY decoder accepts only the record versions validated on this modem: B0C1 v2, B0C2 v3, B193 v1/0x19
v66, B173 v50, B139 v162, B14E/B14D v164, B064 v1/0x08 v7, B062 v1/0x06 v50, B97F 3.0, B887 3.13, B888 3.1.
Any other version is counted in `PhyCapture.versionMisses` and shown as "not decodable (version N)", never
guessed. The same holds for the RRC header layouts (D2): an unknown packet version is undecoded, not
approximated. A new iPhone model or baseband firmware first gets its own local fixture set.

## Fixture inventory

All in the git-ignored `ios/Fixtures/local/` (populated by `ios/scripts/fixtures.sh`, verified by
`fixtures.sh --verify` against `MANIFEST.json`; never committed).

| File | md5 | Key counts |
| --- | --- | --- |
| `iphone-recovered.qmdl` | e53a167b29b25560938d1f089e719d33 | 39,974,284 bytes; 92,133 HDLC frames, 0 CRC errors, 92,133 records, 224 codes |
| `contract/callflow-golden.json` | 812920659751853fd251692c0d7b4e98 | 128 events, 34 procedures (all SUCCEEDED), 4 steps (FIRST_SEEN, RESELECTION, HANDOVER, HANDOVER), 2 connections (RELEASED, OPEN_AT_END), 3 cell details, 5 undecoded, 26,959.395 ms |
| `contract/presentation-golden.json` | 4562d3cf8b5c8dc12c7543c71c9d40b0 | rows ALL 157 / RRC 127 / NAS 29, lanes UE/RAN/Core, 10 procedure groups |
| `contract/callflow-attach4.json` | 324b2571b5cea4bd37b91c4c9162bc41 | attach window: 2,351 records, 151 codes, 33 events, 7 procedures |
| `contract/oneplus-5g-registration.json` | abf8bed05c879913998ad318a4eadb83 | 18 records, 11 events, 2 procedures, 2 steps |
| `contract/oneplus-callbox-service-request.json` | f7a9be3a01adf0701de6f198e0de9543 | 26 records, 18 events, 7 procedures |
| `contract/phy-golden.json` | f7096d556831fc8c7de005879557dd57 | 48 KPIs |
| `contract/phy-summary.json` | 21711aa5b366360030fed9eb2ccfa3a5 | 3 SCells, NR DL 497 records, 3 RACH, encrypted 23,764 records / 61 codes |
| `contract/journey-expected.json` | d0c0bcc1e79359eb4651328bb81f785a | 13 markers, 10 findings |
| `qdss-full-stats.json` | 15168d9bb47f71ca62174cb51eeeab93 | the Python deframer's stats for all 130 chunks |
| `qdss-first3/`, `qdss-attach4/` | per `manifest.json` | QDSS chunk windows; first3.qmdl 8bee416586647da91511a952c527c272, attach4.qmdl 245d59fc9af24e3acb5535966de6946d |
| `reference/qdss_deframe.py` | a020cc3fdb9d46e86675ca0cb6bb8b1a | the verified Python deframer |
| `oneplus/*.qmdl` | 58a2a3a6..., 29aeca6f... | the Android test captures |
| `profile/profile-*.stub` | (see MANIFEST) | com.apple.basebandlogging only: installed 2026-09-21T19:40:06Z, removal 2026-09-28T19:40:02Z (7.0 days) |
| `baseband-meta/` | (see MANIFEST) | archive and trace-dir names, ambtool_output.log, info.txt and trace.info (only names and times are read) |

## Regeneration

```sh
source ios/scripts/env.sh
# Kotlin v1 (src-v1) goldens for any qmdl, then compare:
ios/Contract/run-kotlin-golden.sh "$FT_SCRATCH/wf-ios/design/contract/src-v1" "$FT_TMP/golden" "$FT_FIXTURES/iphone-recovered.qmdl"
python3 ios/Contract/tools/json_equal.py "$FT_TMP/golden/iphone-recovered/callflow-golden.json" "$FT_FIXTURES/contract/callflow-golden.json" --ignore source.file
python3 ios/Contract/tools/json_equal.py "$FT_TMP/golden/iphone-recovered/presentation-golden.json" "$FT_FIXTURES/contract/presentation-golden.json" --ignore source.file
# The Android sources themselves (equal to the fixtures once WP1 has landed v1 in android/):
ios/Contract/run-kotlin-golden.sh --from-repo "$FT_TMP/golden-repo" "$FT_FIXTURES/iphone-recovered.qmdl"
# PHY goldens from the reference extractor output:
python3 ios/Contract/reduce_phy.py "$FT_FIXTURES/reference-phy/kpis.json" "$FT_FIXTURES/contract/callflow-golden.json" "$FT_TMP/phy"
```

Needs Homebrew openjdk@21 and the Gradle-cached Kotlin 2.4.20 jars (no Gradle run, no network). Verified
2026-09-22: `src-v1` reproduces both iPhone goldens ("equal"); `--from-repo` on today's `android/` differs
(925 callflow paths, 398 presentation paths), because repo `main` has none of D1-D4 yet.

## v2 backlog

- NR PDU 36 (RadioBearerConfig) mapped and decoded.
- Relabel 0xB80C/0xB80D as 5GMM state records (v1 keeps the Kotlin labels verbatim).
- Reassemble segmented NR RRC (v26 `segment_id`).
- NR band from FreqBandIndicatorNR (Wireshark shows 5 for this capture) instead of the candidate list.
- Decode SCG release.
