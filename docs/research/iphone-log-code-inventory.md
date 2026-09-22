# iPhone DIAG log-code inventory

Every Qualcomm DIAG log code in the two iPhone 17 captures: what each record type is, how much of it there is,
what shape it has, when the modem emits it, and which ones are worth decoding next.

**Captures.** Both come from the same iPhone 17 (Qualcomm "M25" baseband, firmware 1.60.02) on AT&T, rebuilt from
the iPhone's own QDSS baseband trace by `fieldtap qdss` — see
[`iphone-baseband-capture.md`](iphone-baseband-capture.md) for how the trace is deformatted.

| | C1 `iphone-recovered.qmdl` | C2 `capture2/capture2.qmdl` |
|---|---|---|
| records | 92,133 | 85,323 |
| distinct log codes | 224 | 222 |
| duration (first to last plausible timestamp) | 26.96 s | 22.10 s |
| HDLC frames / CRC errors / short frames | 92,133 / 0 / 0 | 85,323 / 0 / 0 |
| average rate | 3,417 records/s | 3,861 records/s |
| records with no usable timestamp | 5,172 (5.6%) | 4,206 (4.9%) |
| scenario | stationary; an RRC release at 1.85 s, a fresh LTE attach at 2.66 s on EARFCN 67,086, an EN-DC add at 13.80 s on NR ARFCN 174,770 (5 kHz raster → 873.85 MHz, low band), then two handovers: EARFCN 67,086 → 5,110 at 14.36 s and → 650 at 20.95 s | driving; a reselect to EARFCN 650 PCI 235 with a fresh connection at 12.90 s, then an EN-DC add at 16.29 s on NR ARFCN 658,080 (15 kHz raster → 3,871.2 MHz, i.e. C-band n77/n78) that stays up to the end |

227 codes appear across the two; 219 appear in both. Only C1: `0x1D92`, `0xB0B2`, `0xB19E`, `0xB841`, `0xB861`.
Only C2: `0x1340`, `0xB890`, `0xB98F`. **216 of the 227 have a public name; 11 do not** (listed below).

FieldTap decodes 10 of the 227 record types beyond signalling, and the signalling codes themselves. Together that
is **13,693 of 177,456 records — 7.7%. The other 92.3% is what this document is about.**

## What the undecoded 92% actually is

| class | undecoded records | share of the undecoded | codes |
|---|--:|--:|--:|
| LTE LL1 (low layer 1 — the demodulator/AGC firmware) | 52,712 | 32.2% | 21 |
| firmware / RF housekeeping (clock + power manager, Tx AGC, FBRx, thermal) | 27,049 | 16.5% | 15 |
| GNSS (almost all of it `0x1375` cgps_ipc_data) | 23,775 | 14.5% | 6 |
| data path (IPA hardware accelerator, QMI links, DS flow control) | 21,833 | 13.3% | 29 |
| LTE ML1 (managing layer 1 — measurement, mobility, sleep) | 11,069 | 6.8% | 32 |
| NR5G L1 (LL1 firmware) | 9,935 | 6.1% | 3 |
| NR5G MAC | 7,944 | 4.9% | 13 |
| LTE MAC / PHY per-grant reports (0xB160–0xB1FF range) | 2,527 | 1.5% | 15 |
| LTE RLC | 1,604 | 1.0% | 8 |
| LTE MAC | 1,459 | 0.9% | 5 |
| LTE PDCP | 1,196 | 0.7% | 8 |
| NR5G RRC (non-OTA: CA combos, config, blacklist) | 982 | 0.6% | 3 |
| NR5G L2 (PDCP/RLC/L2 PDUs and stats) | 687 | 0.4% | 15 |
| everything else (modem control, UMTS, SMS, low-volume LTE RRC/NAS, NR5G ML1, NR5G NAS, firmware/debug) | 991 | 0.6% | 33 |

Read plainly: **two thirds of the volume is not radio measurement at all.** It is the modem talking to itself —
LL1 demodulator telemetry (`0xB134`, `0xB111`, `0xB146`, `0xB11B`, `0xB11D`, `0xB130`, `0xB122`), the clock and
power manager (`0x1874`, 17,242 records over the two captures), the GNSS subsystem's internal IPC
(`0x1375`, 23,505 records), and the IPA data-path accelerator's periodic counter dumps (`0x1C6E`–`0x1C72`,
`0x1D0B`). Of the remainder, the interesting part is a compact set: ~64,000 LTE LL1/ML1 records and ~18,500
NR5G MAC/L1 records that between them hold per-TTI scheduling, per-antenna receive level, uplink power, and
neighbour measurements. That is where the ranked list below points.

## Method (everything in the tables is measured, not assumed)

* Both files are raw DIAG framed HDLC-style: `payload || crc16 || 0x7E`. Unframing both with
  `fieldtap.diag.hdlc.Unframer` yields 85,323 and 92,133 frames with **0 CRC errors and 0 short frames**, and every
  frame is a `DIAG_LOG_F` (0x10) packet — no multi-log (0x98) wrappers, no other command codes. Record layout is
  `0x10, more(u8), outer_len(u16), len(u16), code(u16), timestamp(u64)`, body = `len - 12` bytes.
* **rec/s** is the code's count divided by that capture's span. It is an average over the whole capture; codes that
  are gated on a radio state (see *when*) run much faster than this while they are active.
* **Ver** is the first body byte for the LTE/1x families, and for the NR5G families the first `u32`, which on this
  modem is consistently `(major << 16) | minor` — `0xB883` reads `0x0003001A` = 3.26, `0xB8C9` reads 3.1,
  `0xB884` 3.5, `0xB885` 3.20, `0xB8A7` 3.5 — matching the versions the web engine's PHY catalogue already records
  for those codes. `0xB821`, `0xB826`, `0xB841` and `0xB842` do not follow it and carry a plain single version byte.
  For the `0x1xxx` families the first byte often is not a version at all (e.g. `0x1375` shows 96/25/180), so treat
  that column as "what byte 0 holds" outside the `0xBxxx` ranges.
* **body min/med/max** is over both captures; **fixed** says whether every record of that code had the same length
  (101 of the 227 are fixed-length, 126 vary). A large variant count usually means a subpacket container
  (`0xB0B1` has 218 distinct lengths, `0xB092` 269).
* **C1/C2 span** is the first and last appearance in seconds from the capture's first plausible timestamp. Records
  whose timestamp is 0 or implausible are excluded; **23 codes never carry a usable timestamp at all** and are
  marked `no ts` (they can still be ordered by record index, not by time).
* **NR frac** is the fraction of that code's records falling inside 0.25 s bins where the NR5G ranges are active
  (≥50 NR records in the bin). Those windows are C1 0–2.0 s (the NR leg the capture opens on, which ends with the
  `rrcConnectionRelease` at 1.854 s), 13.5–15.5 s (opening at the `0xB821` NR reconfigurations at 13.80 and
  14.13 s) and 21.5–22.0 s (around the `0xB821` RadioBearerConfig at 21.65 s); and C2 16.25–22.1 s, starting at
  the `0xB821` reconfiguration at 16.29 s. In other words the bins agree with the RRC signalling without being
  derived from it. A code marked **(NR leg)** has ≥95% of its records inside
  them in both captures; that is the empirical "only exists while the NR leg is up" test.
* **when** compares each code against the idle gaps: C1 2.00–2.50 s (between the `rrcConnectionRelease` at 1.854 s
  and the `rrcConnectionSetupComplete` at 2.664 s) and C2 12.50–13.00 s (before the `rrcConnectionSetupComplete` at
  12.903 s). Those windows hold 2,247 records, 1.27% of the corpus, so absence only means something for codes with
  enough volume: **connected only** is claimed when the code has usable timestamps, zero records in either idle
  window, and ≥3 expected there at the corpus-wide rate. `too few` means the sample cannot decide.
* **ours** is whether FieldTap decodes the record body today: the signalling set (`0xB0C0`–`0xB0C2`, the LTE/NR NAS
  codes, `0xB821`) plus the PHY extractor's `0xB193`, `0xB173`, `0xB139`, `0xB14E`, `0xB14D`, `0xB064`, `0xB062`,
  `0xB97F`, `0xB887`, `0xB888` (`web/engine/src/phy/extract.ts`).

### Result of the idle test

These codes have real volume, real timestamps, and **not one record in either idle gap** — the modem emits them only
while an RRC connection is up:

`0xB8C9` `0x1D0B` `0x1C8E` `0xB8A1` `0xB14E` `0xB8D1` `0xB140` `0xB888` `0xB883` `0xB885` `0xB884` `0xB826`
`0xB198` `0xB89B` `0xB887` `0xB8D8` `0xB129` `0xB064` `0x1CE2` `0xB896` `0x1849` `0xB12C` `0x11EB` `0xB173`

The NR5G half of that list is doubly gated: it is also **(NR leg)** in the NR-fraction column, so those records
exist only while EN-DC is up, not merely while connected. Nothing in the corpus is LTE-only in the strict sense —
every LTE code keeps running through the NR leg, because the NR leg is an EN-DC addition on top of a live LTE
connection, never a standalone NR connection.

## Ranked: what to decode next

Ranked by what a drive-test or diagnostics user could newly answer, not by volume. Counts are C1 + C2.
Every entry is currently undecoded.

| # | Code(s) | Name | Records | The question it would answer that we cannot answer today |
|--:|---|---|--:|---|
| 1 | `0xB179` | LTE ML1 Connected Mode LTE Intra-Freq Meas Results | 758 | **"Why did the phone not hand over?"** The per-neighbour RSRP/RSRQ the UE was actually measuring while connected — the input to the A3 comparison. Today we see only the measurement reports the UE chose to send, so a missing handover is indistinguishable from a neighbour that was never good enough. |
| 2 | `0xB134` | LTE LL1 DemFront Serving Cell RS Log | 9,427 | **"What was the SINR?"** FieldTap reports no LTE SINR at all: the web engine's catalogue records that the old projected-SIR slot of `0xB193` is not SIR on this modem's v66 subpacket. This is the reference-signal record at the demodulator front end and the largest remaining candidate. 175–205 records/s means a per-subframe series, not a 1 Hz sample. |
| 3 | `0xB132` | LTE LL1 PDSCH Decoding Results | 1,724 | **"What limited downlink throughput?"** Per-TTI modulation, layers and CRC outcome separates a bad channel (low MCS) from a thin pipe (few grants) from a rank-1 ceiling. 107 distinct body lengths, so it is a per-TTI container. |
| 4 | `0xB130` | LTE LL1 PDCCH Decoding Result | 3,479 | **"Was the cell scheduling me at all?"** Grant count per subframe. A throughput complaint with plenty of grants and low MCS is coverage; few grants at good MCS is congestion. Nothing in FieldTap today distinguishes them. |
| 5 | `0xB111` | LTE LL1 Rx AGC Log | 9,021 | **"Is one antenna dead, or is the front end being desensitised?"** Per-antenna RSSI and gain state. Second-largest LTE code in the corpus (155–220 records/s) and it has no public layout. |
| 6 | `0xB146` | LTE LL1 UL AGC Tx Report | 3,763 | **"Was the phone at maximum transmit power?"** The uplink-limited half of every coverage problem. FieldTap's catalogue already notes actual LTE Tx power is not available from plain records. |
| 7 | `0xB8C9` | NR5G LL1 FW Rx Control AGC | 7,424 | **"What was the NR receive level?"** v3.1, plain, 99–216 records/s, connected-and-NR-only. NR receive level today exists only when an RRC measurement report happens to carry it, i.e. a few samples per minute instead of hundreds per second. |
| 8 | `0xB8A7` | NR5G MAC CSF Report | 184 | **"How good is the NR channel, and what rank is the phone asking for?"** CQI/RI/PMI. v3.5, plain. Distinguishes "NR is attached but useless" from "NR is genuinely carrying data". |
| 9 | `0xB883` | NR5G MAC UL Physical Channel Schedule Report | 1,238 | **"What is the NR uplink actually getting?"** PRBs, MCS and TBS per grant — the NR uplink throughput ceiling, and the record the catalogue already flags as plain-but-undecoded at v3.26. |
| 10 | `0xB884` | NR5G MAC UL Physical Channel Power Control | 1,147 | **"Is NR uplink power-limited?"** Power headroom. The classic n77 mid-band failure: downlink is fine, uplink falls back to LTE because the phone runs out of power. |
| 11 | `0xB8A1` | NR5G MAC Symbol Arbitration | 2,954 | **"Why is NR slow while LTE is busy?"** How EN-DC divides symbols between the LTE and NR legs. No other record explains an NR rate that collapses only when LTE is active. |
| 12 | `0x1476` `0x147C` `0x147D` `0x147E` | GNSS Position Report / PE WLS / PE KF Position Report / PRx RF HW Status | 227 | **"Where was this measured?"** The modem's own fix, inside the .qmdl. A drive test becomes a map from the capture file alone — no phone location API, no separate GPS log to align. For its size, the highest product value in the corpus. |
| 13 | `0x14D8` | Temperature Monitor Log | 1,415 | **"Did the phone thermally throttle?"** The explanation for a throughput cliff that no RF record shows. 84 bytes in all but two records (152 bytes), ~29 records/s, present in both captures. |
| 14 | `0xB1DC` | **UNKNOWN** | 3,103 | **"What is the biggest thing we cannot name?"** Fixed 136 bytes, ~50–70 records/s, in the LTE ML1 range, and no public source names it. Every record has timestamp 0, which itself narrows what it can be (a state dump, not an event). Worth reverse-engineering precisely because a code this busy with no name is a gap in the map. |
| 15 | `0xB122` `0xB123` | LTE LL1 Serving Cell CER / Neighbor Cell CER | 4,270 | **"How much interference is there?"** Channel-estimate quality per cell. Already listed as an unverified LTE SINR candidate; `0xB123` covering neighbours makes it an interference measure rather than just a signal measure. |
| 16 | `0xB885` | NR5G MAC DCI Info | 1,237 | **"How is the NR cell scheduling this phone?"** DCI formats and grant cadence — the NR counterpart of #4, plain at v3.20. |
| 17 | `0xB16B` `0xB16C` | LTE PDCCH-PHICH Indication Report / DCI Information Report | 1,151 | **"Were the uplink grants arriving, and were they being ACKed?"** Per-grant DCI plus PHICH outcome gives uplink HARQ behaviour, which no decoded record carries. |
| 18 | `0xB15B` | LTE LL1 Rx Antenna Info | 2,007 | **"Which antennas were in use?"** Antenna imbalance is the most common cause of a phone that measures fine but performs badly, and it caps achievable MIMO rank. Fixed 272 bytes. |
| 19 | `0xB198` | LTE ML1 CDRX Events Info | 843 | **"Why is latency spiky, and where is the battery going?"** Connected-mode DRX cycles. Connected-only, so its presence alone already marks connected time. |
| 20 | `0xB066` | LTE MAC Buffer Status Int Log | 1,149 | **"Is the uplink queue backing up?"** Buffer status reports separate "the app has nothing to send" from "the network is not granting". 72 distinct body lengths — a per-LCG container. |
| 21 | `0x1D0B` `0x1C6E`–`0x1C72` | IPA ABM / IPA common, DL, UL and QBAP stats | 8,471 | **"What throughput did the device actually achieve?"** The data-path accelerator's own byte and packet counters, dumped ~18 times/s. Throughput ground truth with no speed test, and the denominator every RF metric needs. All five `0x1C6x/0x1C7x` codes are fixed-length and arrive in lockstep (867–868 records each), so they are one periodic snapshot split across five records. |
| 22 | `0xB196` | LTE ML1 Cell Measurement Results | 448 | **"What did coverage look like while idle?"** `0xB193` covers connected measurement; this is the idle-mode counterpart, and idle coverage is what decides whether a call can start at all. |
| 23 | `0xB1D9` | LTE ML1 Handover Timeline Info | 3 | **"How long was the interruption?"** Three records in 49 s, but it is the only record that times the handover gap directly, and C1 contains two handovers to validate it against. Highest value-per-record in the corpus. |
| 24 | `0x12E8` | TRM (Transceiver Resource Manager) | 651 | **"Which RAT has which RF chain?"** EN-DC antenna contention — why adding NR can make LTE worse. Byte 0 varies (0x17/0x0F/0x24), so it is a multiplexed record. |
| 25 | `0xB063` | LTE MAC DL Transport Block | 272 | **"How far is the phone from the cell?"** Timing-advance commands live here, and continuous TA is a distance estimate. The catalogue already notes the known framing did not validate on this modem, so this is a re-derivation job, not a new one. |

Also considered and deliberately left lower: `0xB11B`/`0xB11D` (frequency and time tracking loops — Doppler, and a
drive-test speed cross-check, but no user question they answer alone), `0xB126` (PDSCH demapper: antennas and
transmission mode per TTI, subsumed by #3), `0xB1EA`/`0xB1DA`/`0xB98F` (antenna-diversity switching status),
`0xB826` (NR CA combos: 967 records, median 5.8 KB, a capability dump rather than a measurement — decoding it
answers "what could this phone do", not "what happened"), `0x1391`/`0x1390` (QMI link PDUs — valuable for
explaining an AP-side decision such as data being disabled, but it is a control channel, not radio), and
`0x1874`/`0x184C` (the clock/power manager and RF Tx AGC: 24,100 records between them, almost all of the
firmware/RF class, and almost nothing a field user would act on).

## The encrypted 0x9E set

The iPhone's modem wraps some log records in `DIAG_SECURE_LOG_F` (0x9E) — header readable, body encrypted. In C1
those were 23,764 records over 61 codes; `fieldtap qdss` counts them and never writes them to the .qmdl, which is
why **every code in the main table is plain**.

Re-deframing the two QDSS chunk subsets kept in the fixtures (`qdss-first3`, `qdss-attach4`) recovers 39 of those
codes by name. **The encrypted set and the plain set are disjoint: not one of these 39 codes ever appears as a
plain record in either capture.** So this is not sampling — the modem decides per log code, and for these codes
there is no plain version to find. Every one is in the NR5G ranges, and DiagNG names only 8 of the 39, which is
itself a finding: this is the newest, least-documented corner of the log space.

This census is partial (two ~4 s subsets, not the full 61-code trace) and is included because it is the only
per-code evidence available without re-running the full QDSS extraction.

| Code | Name | Src | Class | records (first3 subset) | records (attach4 subset) |
|---|---|---|---|--:|--:|
| `0xB82A` | **UNKNOWN** | - | NR5G RRC | 0 | 1 |
| `0xB843` | **UNKNOWN** | - | NR5G L2 (PDCP/RLC) | 1 | 1 |
| `0xB856` | **UNKNOWN** | - | NR5G L2 (PDCP/RLC) | 1 | 1 |
| `0xB864` | **UNKNOWN** | - | NR5G L2 (PDCP/RLC) | 1 | 0 |
| `0xB881` | nr5g_mac_ul_tb_stats | DiagNG | NR5G MAC | 74 | 0 |
| `0xB88F` | **UNKNOWN** | - | NR5G MAC | 16 | 0 |
| `0xB89E` | **UNKNOWN** | - | NR5G MAC | 6 | 0 |
| `0xB8A3` | **UNKNOWN** | - | NR5G MAC | 92 | 0 |
| `0xB8A8` | **UNKNOWN** | - | NR5G MAC | 12 | 0 |
| `0xB8B7` | **UNKNOWN** | - | NR5G MAC | 1 | 0 |
| `0xB8C0` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 184 | 0 |
| `0xB8C5` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 368 | 0 |
| `0xB8C6` | nr5g_ll1_fw_rx_control_ftl | DiagNG | NR5G L1 (LL1/FW) | 7 | 0 |
| `0xB8C7` | nr5g_ll1_fw_rx_control_ttl | DiagNG | NR5G L1 (LL1/FW) | 5 | 0 |
| `0xB8C8` | nr5g_ll1_fw_rx_control_cch | DiagNG | NR5G L1 (LL1/FW) | 314 | 0 |
| `0xB8CB` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 353 | 0 |
| `0xB8CD` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 314 | 0 |
| `0xB8CF` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 86 | 0 |
| `0xB8DA` | nr5g_ll1_fw_ul_ftl | DiagNG | NR5G L1 (LL1/FW) | 1 | 0 |
| `0xB8DD` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 21 | 0 |
| `0xB8DE` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 5 | 0 |
| `0xB8E2` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 14 | 0 |
| `0xB8E5` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 36 | 0 |
| `0xB8E7` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 18 | 0 |
| `0xB8FB` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 5 | 0 |
| `0xB8FF` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 4 | 0 |
| `0xB95B` | **UNKNOWN** | - | NR5G ML1 | 9 | 0 |
| `0xB95C` | **UNKNOWN** | - | NR5G ML1 | 9 | 0 |
| `0xB960` | **UNKNOWN** | - | NR5G ML1 | 9 | 0 |
| `0xB969` | nr5g_ml1_searcher_fw_cell_meas_request | DiagNG | NR5G ML1 | 17 | 0 |
| `0xB96A` | **UNKNOWN** | - | NR5G ML1 | 16 | 0 |
| `0xB96B` | **UNKNOWN** | - | NR5G ML1 | 2 | 0 |
| `0xB96C` | **UNKNOWN** | - | NR5G ML1 | 2 | 0 |
| `0xB974` | **UNKNOWN** | - | NR5G ML1 | 16 | 0 |
| `0xB977` | **UNKNOWN** | - | NR5G ML1 | 16 | 0 |
| `0xB98E` | **UNKNOWN** | - | NR5G ML1 | 12 | 2 |
| `0xB992` | nr5g_ml1_afc_services | DiagNG | NR5G ML1 | 21 | 0 |
| `0xB9A3` | **UNKNOWN** | - | NR5G ML1 | 9 | 0 |
| `0xB9A9` | **UNKNOWN** | - | NR5G ML1 | 77 | 35 |

## The 11 codes with no public name

Checked against MobileInsight `consts.h` and `log_packet.h`, SCAT `diagcmd.py` and its per-RAT parsers, QCSuper
`log_types.py`, DiagNG `log_codes.ksy` (3,464 entries), Wireshark's QCDIAG dissector, osmo-qcdiag `diagcmd.h`, and
mobile_sentinel's `diagcmd.py`. None of these eight sources names any of them.

| Code | Records | Body | Byte 0 | Timestamps | Range suggests |
|---|--:|---|---|---|---|
| `0xB1DC` | 3,103 | fixed 136 | 0x30 | never | LTE ML1 — the largest unnamed record in the corpus (rank 14 above) |
| `0xB8D8` | 524 | fixed 28 | v3.2 (u32) | yes, connected+NR only | NR5G L1 firmware. `registry.py` already records that it was checked and is **not** the NR L2 UL transport block |
| `0xB1D8` | 439 | 24 or 72 (4 lengths) | 0x30 | yes | LTE ML1, adjacent to the `0xB1D0`–`0xB1D7` DLM/GM family |
| `0x1DB3` | 119 | 576–1376 (51 lengths) | 0x12 | yes | 1x/data range; a large variable container |
| `0x1D39` | 97 | fixed 1,148 | 0x00 | never | 1x/data range |
| `0xB0A8` | 93 | fixed 82 | 0x31 | yes | LTE PDCP (DL side, `0xB0A0`–`0xB0AF`) |
| `0xB1FC` | 188 | 32 or 60 | 0x34 | yes | LTE ML1, between `0xB1FB` MTPL flow control and `0xB1FD` dedicated-config handover |
| `0xB1EF` | 33 | fixed 2,572 | 0x28 | never | LTE ML1; a large fixed state dump |
| `0xB0CE` | 28 | fixed 53 | 0x20 | yes | LTE RRC range, next to `0xB0CD` LTE RRC supported CA combos |
| `0x1D1C` | 24 | fixed 2,528 | 0x09 | yes | 1x/data range; a large fixed state dump |
| `0xB0D4` | 2 | fixed 294 | 0x01 | yes | LTE RRC range |

## Full inventory

227 codes, ordered by total records across the two captures. `**UNKNOWN**` marks a code no public source names.
`Src` is which name tables carry it: `DiagNG` = P1sec/DiagNG `log_codes.ksy`, `SCAT` = fgsect/scat `diagcmd.py`,
`MI` = MobileInsight `consts.h`. Every code here is **plain** (the 0x9E set is the separate table above).

| Code | Name | Src | Class | Ver | C1 n | C2 n | rec/s C1·C2 | body min/med/max | fixed | C1 span s | C2 span s | NR frac | when | plain/enc | ours | rank |
|---|---|---|---|---|--:|--:|---|---|:-:|---|---|---|---|:-:|:-:|:-:|
| `0x1375` | cgps_ipc_data | DiagNG | GNSS | 96, 25, 180 | 10934 | 12571 | 405.6·568.9 | 28/44/11556 | no(43) | 0.0–26.8 | 0.0–22.1 | 0.26·0.30 | idle too | plain | no |  |
| `0x1874` | mcpm_general_sessopm_power | DiagNG | firmware/RF | 17 | 9214 | 8028 | 341.8·363.3 | 58/98/367 | no(11) | 0.0–27.0 | 0.0–22.1 | 0.41·0.35 | idle too | plain | no |  |
| `0xB134` | lte_ll1_demfront_serving_cell_rs_log | DiagNG | LTE LL1 | 163 | 4888 | 4539 | 181.3·205.4 | 116/980/1540 | no(20) | 0.0–26.9 | 0.0–22.1 | 0.15·0.40 | idle too | plain | no | 2 |
| `0xB111` | lte_ll1_rx_agc_log | DiagNG | LTE LL1 | 166 | 4172 | 4849 | 154.8·219.5 | 64/872/1016 | no(46) | 0.0–26.9 | 0.0–22.1 | 0.15·0.39 | idle too | plain | no | 5 |
| `0xB8C9` | nr5g_ll1_fw_rx_control_agc | DiagNG | NR5G L1 (LL1/FW) | 3.1 | 2660 | 4764 | 98.7·215.6 | 24/308/452 | no(6) | 0.0–22.4 | 14.0–22.1 | **0.99·0.99 (NR leg)** | **connected only** | plain | no | 7 |
| `0x184C` | lte_rf_fed_tx_agc | DiagNG | firmware/RF | 17 | 4465 | 2393 | 165.6·108.3 | 392/632/680 | no(9) | 0.0–26.9 | 0.0–22.1 | 0.15·0.30 | idle too | plain | no |  |
| `0xB193` | lte_ml1_serving_cell_meas_response | DiagNG+SCAT+MI | LTE ML1 | 1 | 1945 | 2566 | 72.1·116.1 | 160/160/592 | no(4) | 0.0–26.9 | 0.0–22.1 | 0.14·0.34 | idle too | plain | yes |  |
| `0x1D0B` | ipa_abm | DiagNG | data path | 7 | 2238 | 1914 | 83.0·86.6 | 146/370/370 | no(5) | 1.8–27.0 | 0.0–22.1 | 0.12·0.31 | **connected only** | plain | no | 21 |
| `0x1C8E` | ds_burst_flow | DiagNG | data path | 4 | 2346 | 1507 | 87.0·68.2 | 58/58/58 | yes | 0.0–27.0 | 0.0–22.1 | 0.21·0.36 | **connected only** | plain | no |  |
| `0xB146` | lte_ll1_ul_agc_tx_report | DiagNG | LTE LL1 | 165 | 2276 | 1487 | 84.4·67.3 | 64/512/848 | no(15) | 0.0–26.9 | 0.0–22.1 | 0.16·0.33 | idle too | plain | no | 6 |
| `0xB11B` | lte_ll1_srch_serving_cell_ftl_result_int_log | DiagNG | LTE LL1 | 161 | 1848 | 1825 | 68.5·82.6 | 120/1868/1868 | no(20) | 0.0–26.9 | 0.0–22.1 | 0.25·0.31 | idle too | plain | no |  |
| `0xB11D` | lte_ll1_serving_cell_ttl_results | DiagNG | LTE LL1 | 143 | 1803 | 1825 | 66.9·82.6 | 56/816/816 | no(20) | 0.0–26.9 | 0.0–22.1 | 0.23·0.31 | idle too | plain | no |  |
| `0xB130` | lte_ll1_pdcch_decoding_result | DiagNG+MI | LTE LL1 | 163 | 2104 | 1375 | 78.0·62.2 | 36/196/708 | no(22) | 0.0–26.9 | 0.0–22.1 | 0.16·0.35 | idle too | plain | no | 4 |
| `0xB122` | lte_ll1_serving_cell_cer | DiagNG | LTE LL1 | 141 | 1767 | 1512 | 65.5·68.4 | 336/592/592 | no(2) | 0.0–26.9 | 0.0–22.1 | 0.25·0.35 | idle too | plain | no | 15 |
| `0xB114` | lte_ll1_serving_cell_frame_timing | DiagNG | LTE LL1 | 161 | 1517 | 1716 | 56.3·77.7 | 112/976/976 | no(19) | 0.0–26.9 | 0.0–22.1 | 0.22·0.32 | idle too | plain | no |  |
| `0xB1DC` | **UNKNOWN** | - | LTE ML1 | 48 | 1850 | 1253 | 68.6·56.7 | 136/136/136 | yes | no ts | no ts | no ts | no ts | plain | no | 14 |
| `0xB8A1` | nr5g_mac_symbol_arbitration | DiagNG | NR5G MAC | 3.1 | 774 | 2180 | 28.7·98.7 | 152/200/460 | no(16) | 0.0–15.1 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no | 11 |
| `0xB12A` | lte_ll1_pcfich_decoding_results | DiagNG | LTE LL1 | 161 | 1334 | 1607 | 49.5·72.7 | 176/176/176 | yes | 0.0–26.9 | 0.0–22.1 | 0.18·0.33 | idle too | plain | no |  |
| `0x19EF` | ds_flow_control_trigger | DiagNG | data path | 4, 2 | 1768 | 1072 | 65.6·48.5 | 345/345/345 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB139` | lte_ll1_pusch_tx_report | DiagNG+MI | LTE LL1 | 162 | 1381 | 951 | 51.2·43.0 | 108/208/1108 | no(11) | 0.0–26.9 | 0.0–22.1 | 0.15·0.38 | idle too | plain | yes |  |
| `0xB14E` | lte_ll1_pusch_csf | DiagNG+MI | LTE LL1 | 164 | 1770 | 334 | 65.7·15.1 | 60/60/60 | yes | 0.0–26.9 | 0.0–22.0 | 0.17·0.20 | **connected only** | plain | yes |  |
| `0xB15B` | lte_ll1_rx_antenna_info | DiagNG | LTE LL1 | 162 | 1064 | 943 | 39.5·42.7 | 272/272/272 | yes | 0.0–26.9 | 0.0–22.1 | 0.25·0.22 | idle too | plain | no | 18 |
| `0xB8D1` | nr5g_ll1_fw_tx_iu_rf | DiagNG | NR5G L1 (LL1/FW) | 3.7 | 1168 | 819 | 43.3·37.1 | 24/188/964 | no(18) | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no |  |
| `0xB140` | lte_ll1_srs_tx_report | DiagNG | LTE LL1 | 161 | 1403 | 464 | 52.0·21.0 | 16/16/24 | no(2) | 0.0–26.9 | 0.0–12.3 | 0.16·0.03 | **connected only** | plain | no |  |
| `0xB13C` | lte_ll1_pucch_tx_report | DiagNG+MI | LTE LL1 | 162 | 1132 | 645 | 42.0·29.2 | 76/144/620 | no(9) | 0.0–26.9 | 0.1–22.1 | 0.14·0.45 | idle too | plain | no |  |
| `0xB132` | lte_ll1_pdsch_decoding_results | DiagNG+MI | LTE LL1 | 168 | 1253 | 471 | 46.5·21.3 | 92/192/2016 | no(107) | 2.4–26.8 | 0.1–22.0 | 0.10·0.14 | idle too | plain | no | 3 |
| `0xB14D` | lte_ll1_pucch_csf | DiagNG+MI | LTE LL1 | 164 | 1103 | 465 | 40.9·21.0 | 36/36/36 | yes | 0.0–26.9 | 0.0–22.1 | 0.27·0.17 | idle too | plain | yes |  |
| `0x1544` | qmi_mcs_qcsi_pkt | DiagNG | data path | 2 | 721 | 844 | 26.7·38.2 | 28/88/1599 | no(164) | 0.7–26.7 | 0.4–22.0 | 0.45·0.32 | idle too | plain | no |  |
| `0xB888` | nr5g_mac_pdsch_stats | DiagNG+MI | NR5G MAC | 3.1 | 602 | 947 | 22.3·42.9 | 92/92/92 | yes | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | yes |  |
| `0x1951` | dpl_hw_sio_conf | DiagNG | data path | 0 | 660 | 825 | 24.5·37.3 | 22/22/190 | no(4) | 1.8–26.1 | 0.5–21.4 | 0.19·0.32 | idle too | plain | no |  |
| `0x1391` | qmi_link_2_tx_pdu | DiagNG | data path | 1 | 669 | 813 | 24.8·36.8 | 17/80/3717 | no(171) | 0.7–26.9 | 0.3–22.0 | 0.46·0.36 | idle too | plain | no |  |
| `0x14D8` | temperature_monitor_log | DiagNG | firmware/RF | 0 | 785 | 630 | 29.1·28.5 | 84/84/152 | no(2) | 0.4–27.0 | 0.1–21.7 | 0.34·0.36 | idle too | plain | no | 13 |
| `0xB18F` | lte_ml1_advrx_ic_cell_list | DiagNG | LTE ML1 | 57 | 513 | 848 | 19.0·38.4 | 48/104/160 | no(5) | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB883` | nr5g_mac_ul_physical_channel_schedule_report | DiagNG+MI | NR5G MAC | 3.26 | 633 | 605 | 23.5·27.4 | 40/68/248 | no(14) | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no | 9 |
| `0xB885` | nr5g_mac_dci_info | DiagNG | NR5G MAC | 3.20 | 632 | 605 | 23.4·27.4 | 52/64/352 | no(22) | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no | 16 |
| `0xB066` | lte_mac_buffer_status_int_log | DiagNG+MI | LTE MAC | 48 | 621 | 528 | 23.0·23.9 | 32/2080/2772 | no(72) | 0.0–26.9 | 0.0–22.1 | 0.20·0.29 | idle too | plain | no | 20 |
| `0xB884` | nr5g_mac_ul_physical_channel_power_control | DiagNG | NR5G MAC | 3.5 | 605 | 542 | 22.4·24.5 | 40/40/136 | no(4) | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no | 10 |
| `0xB1F3` | lte_ml1_traffic_ext_log | DiagNG | LTE ML1 | 46 | 592 | 518 | 22.0·23.4 | 56/104/440 | no(8) | 0.1–27.0 | 0.0–22.1 | 0.18·0.41 | idle too | plain | no |  |
| `0xB123` | lte_ll1_neighbor_cell_cer | DiagNG | LTE LL1 | 41 | 385 | 606 | 14.3·27.4 | 160/160/160 | yes | 0.0–21.6 | 0.0–22.0 | 0.25·0.52 | idle too | plain | no | 15 |
| `0xB826` | nr5g_rrc_supported_ca_combos | DiagNG+SCAT | NR5G RRC | 23 | 610 | 357 | 22.6·16.2 | 1201/5781/7341 | no(103) | 2.9–21.9 | 9.5–13.5 | **0.97·0.99 (NR leg)** | **connected only** | plain | no |  |
| `0x1C6E` | ipa_common_stats | DiagNG | data path | 4 | 475 | 393 | 17.6·17.8 | 345/345/345 | yes | 1.9–26.9 | 0.0–22.1 | 0.11·0.30 | idle too | plain | no | 21 |
| `0x1C6F` | ipa_dl_common_stats | DiagNG | data path | 4 | 475 | 393 | 17.6·17.8 | 548/548/548 | yes | 1.9–26.9 | 0.0–22.1 | 0.11·0.30 | idle too | plain | no | 21 |
| `0x1C70` | ipa_dl_nlo_stats | DiagNG | data path | 7 | 475 | 393 | 17.6·17.8 | 368/368/368 | yes | 1.9–26.9 | 0.0–22.1 | 0.11·0.30 | idle too | plain | no | 21 |
| `0x1C72` | ipa_ul_qbap_extd_stats | DiagNG | data path | 3 | 475 | 393 | 17.6·17.8 | 152/152/152 | yes | 1.9–26.9 | 0.0–22.1 | 0.11·0.30 | idle too | plain | no | 21 |
| `0x1C71` | ipa_ul_common_stats | DiagNG | data path | 16 | 475 | 392 | 17.6·17.7 | 1124/1124/1124 | yes | 1.9–26.9 | 0.0–22.1 | 0.11·0.30 | idle too | plain | no | 21 |
| `0xB198` | lte_ml1_cdrx_events_info | DiagNG+MI | LTE ML1 | 2 | 524 | 319 | 19.4·14.4 | 20/404/404 | no(27) | 0.1–26.6 | 0.0–22.0 | 0.15·0.30 | **connected only** | plain | no | 19 |
| `0xB194` | lte_ml1_search_request_response | DiagNG+SCAT | LTE ML1 | 1 | 413 | 367 | 15.3·16.6 | 32/52/96 | no(6) | 0.0–26.8 | 0.0–22.0 | 0.23·0.37 | idle too | plain | no |  |
| `0xB179` | lte_ml1_connected_mode_lte_intra_freq_meas_results | DiagNG+SCAT+MI | LTE ML1 | 56 | 373 | 385 | 13.8·17.4 | 28/40/76 | no(8) | no ts | no ts | no ts | no ts | plain | no | 1 |
| `0xB0B1` | lte_pdcp_ul_data_pdu | DiagNG+SCAT+MI | LTE PDCP | 60 | 374 | 338 | 13.9·15.3 | 50/270/2038 | no(218) | 0.7–26.8 | 0.0–22.1 | 0.13·0.33 | idle too | plain | no |  |
| `0xB89B` | nr5g_mac_uci_information | DiagNG | NR5G MAC | 3.0 | 192 | 485 | 7.1·21.9 | 28/36/96 | no(14) | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no |  |
| `0xB092` | lte_rlc_ul_am_all_pdu | DiagNG+MI | LTE RLC | 57 | 358 | 317 | 13.3·14.3 | 46/187/942 | no(269) | 0.7–26.8 | 0.0–22.1 | 0.14·0.33 | idle too | plain | no |  |
| `0xB16B` | lte_pdcch_phich_indication_report | DiagNG+MI | LTE MAC/PHY report | 49 | 440 | 216 | 16.3·9.8 | 20/559/801 | no(268) | 0.1–26.9 | 0.0–22.1 | 0.18·0.28 | idle too | plain | no | 17 |
| `0x12E8` | trm | DiagNG | firmware/RF | 23, 15, 36 | 328 | 323 | 12.2·14.6 | 38/245/2222 | no(16) | 1.8–21.7 | 3.7–16.5 | 0.54·0.45 | idle too | plain | no | 24 |
| `0xB887` | nr5g_mac_pdsch_status | DiagNG | NR5G MAC | 3.13 | 179 | 428 | 6.6·19.4 | 52/96/316 | no(7) | 13.9–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | yes |  |
| `0xB8D8` | **UNKNOWN** | - | NR5G L1 (LL1/FW) | 3.2 | 173 | 351 | 6.4·15.9 | 28/28/28 | yes | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no |  |
| `0xB16C` | lte_dci_information_report | DiagNG | LTE MAC/PHY report | 50 | 318 | 177 | 11.8·8.0 | 28/396/588 | no(50) | 1.0–26.5 | 0.0–22.1 | 0.15·0.30 | idle too | plain | no | 17 |
| `0xB16D` | lte_gm_tx_report | DiagNG | LTE MAC/PHY report | 51 | 316 | 175 | 11.7·7.9 | 48/1104/1404 | no(27) | 0.3–26.8 | 0.0–22.0 | 0.16·0.29 | idle too | plain | no |  |
| `0xB129` | lte_ll1_rlm_result_int_log | DiagNG | LTE LL1 | 161 | 269 | 208 | 10.0·9.4 | 96/464/464 | no(5) | 0.1–26.8 | 0.4–22.0 | 0.14·0.16 | **connected only** | plain | no |  |
| `0xB064` | lte_mac_ul_transport_block | DiagNG+SCAT+MI | LTE MAC | 1 | 262 | 194 | 9.7·8.8 | 28/304/472 | no(98) | 0.8–26.8 | 0.0–22.1 | 0.15·0.30 | **connected only** | plain | yes |  |
| `0xB093` | lte_rlc_ul_am_control_pdu | DiagNG | LTE RLC | 56 | 292 | 161 | 10.8·7.3 | 16/16/58 | no(15) | 2.7–26.6 | 0.1–22.1 | 0.09·0.33 | idle too | plain | no |  |
| `0xB1EA` | lte_ml1_qc_ard_status_log | DiagNG | LTE ML1 | 55 | 169 | 284 | 6.3·12.9 | 52/52/140 | no(3) | 0.5–26.9 | 0.0–22.1 | 0.21·0.17 | idle too | plain | no |  |
| `0xB196` | lte_ml1_cell_measurement_results | DiagNG | LTE ML1 | 42 | 193 | 255 | 7.2·11.5 | 44/124/204 | no(5) | no ts | no ts | no ts | no ts | plain | no | 22 |
| `0xB195` | lte_ml1_connected_neighbor_meas_request_response | DiagNG+SCAT+MI | LTE ML1 | 1 | 192 | 254 | 7.1·11.5 | 100/168/372 | no(5) | 0.0–21.6 | 0.0–22.0 | 0.24·0.42 | idle too | plain | no |  |
| `0xB1D8` | **UNKNOWN** | - | LTE ML1 | 48 | 229 | 210 | 8.5·9.5 | 24/40/72 | no(4) | 0.3–26.8 | 0.0–22.1 | 0.16·0.36 | idle too | plain | no |  |
| `0xB172` | lte_uplink_pkt_build_indication | DiagNG | LTE MAC/PHY report | 38 | 279 | 159 | 10.3·7.2 | 32/564/564 | no(18) | 0.3–26.3 | 0.1–22.0 | 0.16·0.25 | idle too | plain | no |  |
| `0x1CE2` | ipa_ul_ack_mgmnt | DiagNG | data path | 8 | 226 | 203 | 8.4·9.2 | 643/791/1679 | no(8) | 15.4–26.9 | 0.0–22.1 | 0.05·0.55 | **connected only** | plain | no |  |
| `0x18F7` | rflm_fbrx_basic_param_updates | DiagNG | firmware/RF | 5 | 255 | 143 | 9.5·6.5 | 24/204/204 | no(3) | 0.1–26.6 | 0.0–22.1 | 0.18·0.37 | idle too | plain | no |  |
| `0xB113` | lte_ll1_pss_results | DiagNG | LTE LL1 | 181 | 210 | 188 | 7.8·8.5 | 16/52/88 | no(19) | 0.0–26.8 | 0.0–22.0 | 0.22·0.36 | idle too | plain | no |  |
| `0x1390` | qmi_link_2_rx_pdu | DiagNG | data path | 1 | 184 | 210 | 6.8·9.5 | 13/21/1295 | no(41) | 0.7–26.9 | 0.3–22.0 | 0.50·0.19 | idle too | plain | no |  |
| `0xB115` | lte_ll1_sss_results | DiagNG | LTE LL1 | 122 | 206 | 184 | 7.6·8.3 | 8/40/72 | no(5) | 0.0–26.8 | 0.0–22.0 | 0.22·0.37 | idle too | plain | no |  |
| `0xB896` | nr5g_mac_uci_payload_information | DiagNG | NR5G MAC | 3.0 | 176 | 200 | 6.5·9.1 | 80/84/104 | no(6) | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | **connected only** | plain | no |  |
| `0x1849` | rflm_fbrx_packet | DiagNG | firmware/RF | 10 | 213 | 119 | 7.9·5.4 | 732/4372/4372 | no(3) | 0.0–26.7 | 0.1–22.0 | 0.18·0.36 | **connected only** | plain | no |  |
| `0xB12C` | lte_ll1_phich_decoding_results | DiagNG | LTE LL1 | 121 | 186 | 125 | 6.9·5.7 | 244/244/244 | yes | 2.9–23.2 | 0.1–22.0 | 0.13·0.30 | **connected only** | plain | no |  |
| `0x1952` | mppm_pdn_db | DiagNG | data path | 7 | 130 | 154 | 4.8·7.0 | 168/168/172 | no(2) | 1.8–21.7 | 3.8–16.4 | 0.85·0.55 | idle too | plain | no |  |
| `0xB063` | lte_mac_dl_transport_block | DiagNG+SCAT+MI | LTE MAC | 50 | 129 | 143 | 4.8·6.5 | 36/116/4260 | no(125) | 0.8–26.0 | 0.9–22.0 | 0.33·0.65 | idle too | plain | no | 25 |
| `0x11EB` | data_protocol_logging | DiagNG+SCAT | data path | 1 | 98 | 155 | 3.6·7.0 | 48/68/68 | no(2) | 3.3–10.4 | 9.3–20.7 | 0.09·0.19 | **connected only** | plain | no |  |
| `0xB173` | lte_pdsch_stat_indication | DiagNG+MI | LTE MAC/PHY report | 50 | 151 | 95 | 5.6·4.3 | 44/724/1044 | no(26) | 1.0–26.7 | 0.3–22.1 | 0.15·0.31 | **connected only** | plain | yes |  |
| `0xB1DA` | lte_ml1_antenna_switch_diversity | DiagNG | LTE ML1 | 53 | 112 | 121 | 4.2·5.5 | 32/32/32 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0x19B7` | uim_apdu | DiagNG | modem control | 1 | 114 | 90 | 4.2·4.1 | 13/17/271 | no(20) | 1.9–21.9 | 12.4–19.1 | 0.54·0.29 | idle too | plain | no |  |
| `0xB087` | lte_rlc_dl_statistics | DiagNG+MI | LTE RLC | 50 | 106 | 91 | 3.9·4.1 | 172/472/472 | no(3) | 0.2–26.9 | 0.2–21.9 | 0.24·0.32 | idle too | plain | no |  |
| `0xB1FC` | **UNKNOWN** | - | LTE ML1 | 52 | 92 | 96 | 3.4·4.3 | 32/32/60 | no(2) | 0.4–26.8 | 0.5–22.0 | 0.35·0.33 | idle too | plain | no |  |
| `0xB16E` | lte_pusch_power_control | DiagNG+MI | LTE MAC/PHY report | 51 | 116 | 69 | 4.3·3.1 | 52/804/804 | no(28) | 1.2–25.9 | 0.2–21.9 | 0.18·0.22 | too few | plain | no |  |
| `0xB8A7` | nr5g_mac_csf_report | DiagNG | NR5G MAC | 3.5 | 42 | 142 | 1.6·6.4 | 84/84/84 | yes | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | too few | plain | no | 8 |
| `0xB0A4` | lte_pdcp_dl_statistics_pkt | DiagNG+MI | LTE PDCP | 52 | 99 | 84 | 3.7·3.8 | 140/384/506 | no(4) | 0.2–26.9 | 0.2–21.9 | 0.19·0.30 | too few | plain | no |  |
| `0xB126` | lte_ll1_pdsch_demapper_configuration | DiagNG+MI | LTE LL1 | 163 | 118 | 62 | 4.4·2.8 | 968/968/968 | yes | 2.4–25.1 | 1.9–22.0 | 0.14·0.35 | idle too | plain | no |  |
| `0xB1C6` | lte_ml1_gm_csf_tx_report | DiagNG | LTE ML1 | 40 | 139 | 37 | 5.2·1.7 | 84/404/404 | no(3) | 0.2–26.6 | 0.6–21.7 | 0.19·0.16 | too few | plain | no |  |
| `0xB0C0` | lte_rrc_ota_packet | DiagNG+SCAT+MI | LTE RRC | 30 | 100 | 67 | 3.7·3.0 | 26/42/5097 | no(57) | 0.7–25.1 | 3.7–22.1 | 0.54·0.40 | idle too | plain | yes |  |
| `0xB190` | lte_ml1_advrx_ic_req_log | DiagNG | LTE ML1 | 54 | 99 | 50 | 3.7·2.3 | 260/260/260 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB842` | nr5g_pdcp_dl_rbs_stats | DiagNG | NR5G L2 (PDCP/RLC) | 6 | 76 | 73 | 2.8·3.3 | 140/140/140 | yes | 0.0–26.9 | 0.0–22.0 | 0.26·0.34 | too few | plain | no |  |
| `0x1CEE` | ds_ui_icon_info | DiagNG | data path | 14 | 68 | 76 | 2.5·3.4 | 751/751/751 | yes | 1.8–21.8 | 3.8–22.0 | 0.65·0.46 | idle too | plain | no |  |
| `0xB12E` | lte_ll1_pbch_decoding_results | DiagNG | LTE LL1 | 142 | 57 | 84 | 2.1·3.8 | 188/188/188 | yes | 2.4–21.7 | 12.7–19.9 | 0.68·0.32 | idle too | plain | no |  |
| `0xB1F2` | lte_ml1_ard_eval_results_log | DiagNG | LTE ML1 | 49 | 69 | 67 | 2.6·3.0 | 96/96/280 | no(3) | 2.8–26.7 | 0.1–22.1 | 0.12·0.51 | too few | plain | no |  |
| `0x1476` | gnss_position_report | DiagNG | GNSS | 30 | 22 | 105 | 0.8·4.8 | 1245/2265/2745 | no(14) | 0.7–17.7 | 0.4–21.5 | 0.18·0.31 | idle too | plain | no | 12 |
| `0x1DB3` | **UNKNOWN** | - | other (1x/data) | 18 | 63 | 56 | 2.3·2.5 | 576/976/1376 | no(51) | 0.3–26.8 | 0.3–21.8 | 0.29·0.32 | idle too | plain | no |  |
| `0x1850` | data_modem_ipa_ipfltr_stats | DiagNG | data path | 11 | 56 | 60 | 2.1·2.7 | 1738/10937/12885 | no(29) | 1.8–26.3 | 0.4–21.5 | 0.46·0.52 | idle too | plain | no |  |
| `0x19CE` | data_interfaces_messages | DiagNG | data path | 1 | 33 | 81 | 1.2·3.7 | 96/112/124 | no(6) | no ts | no ts | no ts | no ts | plain | no |  |
| `0x5385` | gsm_wms_event_notify | DiagNG | SMS (WMS) | 1 | 61 | 43 | 2.3·1.9 | 4/4/4 | yes | 1.9–21.8 | 12.4–13.3 | 0.46·0.02 | idle too | plain | no |  |
| `0xB082` | lte_rlc_dl_am_all_pdu | DiagNG+MI | LTE RLC | 48 | 59 | 45 | 2.2·2.0 | 108/528/4088 | no(54) | 1.9–26.9 | 0.5–21.9 | 0.20·0.33 | too few | plain | no |  |
| `0xB18B` | lte_ml1_sleep | DiagNG | LTE ML1 | 48 | 55 | 48 | 2.0·2.2 | 66/66/66 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB18A` | lte_ml1_rlm_report | DiagNG+MI | LTE ML1 | 1 | 62 | 36 | 2.3·1.6 | 16/244/244 | no(18) | 0.4–26.6 | 0.2–21.1 | 0.16·0.14 | too few | plain | no |  |
| `0x1D39` | **UNKNOWN** | - | other (1x/data) | 0 | 54 | 43 | 2.0·1.9 | 1148/1148/1148 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB857` | nr5g_l2_dl_data_pdu | DiagNG | NR5G L2 (PDCP/RLC) | 3.3 | 16 | 81 | 0.6·3.7 | 41/561/2209 | no(81) | 1.9–15.0 | 16.4–22.0 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB0A8` | **UNKNOWN** | - | LTE PDCP | 49 | 50 | 43 | 1.9·1.9 | 82/82/82 | yes | 0.2–26.9 | 0.3–21.9 | 0.18·0.28 | too few | plain | no |  |
| `0x184E` | call_manager_serving_system_msim_event | DiagNG | modem control | 7 | 51 | 39 | 1.9·1.8 | 1147/1147/1147 | yes | 0.2–26.2 | 0.7–21.5 | 0.53·0.46 | idle too | plain | no |  |
| `0xB083` | lte_rlc_dl_am_control_pdu | DiagNG | LTE RLC | 48 | 50 | 39 | 1.9·1.8 | 18/68/232 | no(23) | 1.2–26.9 | 0.5–21.9 | 0.18·0.38 | too few | plain | no |  |
| `0xB16F` | lte_pucch_power_control | DiagNG+MI | LTE MAC/PHY report | 49 | 58 | 31 | 2.2·1.4 | 28/604/604 | no(26) | 0.0–26.0 | 1.1–22.0 | 0.17·0.39 | too few | plain | no |  |
| `0xB872` | nr5g_l2_ul_tb | DiagNG+MI | NR5G L2 (PDCP/RLC) | 3.17 | 66 | 22 | 2.4·1.0 | 43/528/567 | no(37) | 0.0–15.0 | 16.4–22.1 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB840` | nr5g_pdcp_dl_data_pdu | DiagNG | NR5G L2 (PDCP/RLC) | 3.2 | 45 | 42 | 1.7·1.9 | 68/908/4028 | no(36) | 3.4–26.6 | 0.3–21.8 | 0.27·0.40 | too few | plain | no |  |
| `0xB873` | nr5g_l2_ul_bsr | DiagNG+MI | NR5G L2 (PDCP/RLC) | 3.6 | 65 | 21 | 2.4·1.0 | 31/77/330 | no(13) | 0.0–15.0 | 16.5–22.1 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB890` | nr5g_mac_cdrx_events_info | DiagNG | NR5G MAC | 3.11 | 0 | 86 | 0.0·3.9 | 64/204/344 | no(11) | — | 16.4–22.1 | **1.00 (NR leg)** | too few | plain | no |  |
| `0x1CCA` | pm_rf_band_info | DiagNG | firmware/RF | 3 | 37 | 43 | 1.4·1.9 | 277/277/277 | yes | 1.8–13.6 | 12.3–13.3 | 0.49·0.09 | idle too | plain | no |  |
| `0xB0B5` | lte_pdcp_ul_srb_integrity_data_pdu | DiagNG+SCAT+MI | LTE PDCP | 56 | 49 | 31 | 1.8·1.4 | 65/75/1064 | no(21) | 0.7–22.8 | 3.8–22.1 | 0.55·0.39 | idle too | plain | no |  |
| `0x1D1E` | iface_routing | DiagNG | data path | 1 | 37 | 36 | 1.4·1.6 | 117/117/117 | yes | 3.0–3.4 | 13.4–13.8 | 1.00·0.56 | too few | plain | no |  |
| `0xB170` | lte_srs_tx_report | DiagNG | LTE MAC/PHY report | 49 | 61 | 12 | 2.3·0.5 | 16/208/208 | no(16) | 0.1–26.7 | 0.2–5.1 | 0.11·0.00 | too few | plain | no |  |
| `0xB0CD` | lte_rrc_supported_ca_combos | DiagNG+SCAT | LTE RRC | 41 | 44 | 22 | 1.6·1.0 | 844/2223/2769 | no(21) | 2.9–15.2 | 13.2–13.2 | 1.00·0.00 | too few | plain | no |  |
| `0xB97F` | nr5g_ml1_searcher_measurement_database_update_ext | DiagNG+SCAT+MI | NR5G ML1 | 3.0 | 26 | 40 | 1.0·1.8 | 160/260/560 | no(5) | 0.1–22.4 | 14.1–22.1 | 0.85·0.72 | too few | plain | yes |  |
| `0x1851` | data_modem_ipa_pkt_status_dl | DiagNG | data path | 3 | 34 | 25 | 1.3·1.1 | 1036/1036/1036 | yes | 2.0–26.3 | 0.4–21.5 | 0.12·0.28 | idle too | plain | no |  |
| `0x1852` | data_modem_ipa_pkt_status_ul | DiagNG | data path | 3 | 34 | 25 | 1.3·1.1 | 1036/1036/1036 | yes | 2.0–26.3 | 0.4–21.5 | 0.12·0.28 | idle too | plain | no |  |
| `0x1CE5` | mppm_global_info | DiagNG | data path | 1 | 23 | 27 | 0.9·1.2 | 24/24/24 | yes | 1.8–21.7 | 3.8–16.4 | 0.83·0.52 | idle too | plain | no |  |
| `0xB0B4` | lte_pdcp_ul_statistics_pkt | DiagNG+MI | LTE PDCP | 59 | 26 | 22 | 1.0·1.0 | 120/444/444 | no(3) | 0.9–25.7 | 0.5–21.5 | 0.42·0.36 | too few | plain | no |  |
| `0x1393` | qmi_link_3_tx_pdu | DiagNG | data path | 1 | 27 | 19 | 1.0·0.9 | 20/20/66 | no(5) | 1.9–2.7 | 12.4–12.9 | 0.33·0.00 | idle too | plain | no |  |
| `0xB0A5` | lte_pdcp_dl_srb_integrity_data_pdu | DiagNG+SCAT+MI | LTE PDCP | 1 | 30 | 16 | 1.1·0.7 | 72/104/1056 | no(24) | 1.9–22.8 | 3.7–21.6 | 0.60·0.38 | idle too | plain | no |  |
| `0xB097` | lte_rlc_ul_statistics | DiagNG+MI | LTE RLC | 57 | 23 | 21 | 0.9·1.0 | 76/268/268 | no(3) | 0.9–25.7 | 0.5–21.5 | 0.35·0.38 | too few | plain | no |  |
| `0xB192` | lte_ml1_neighbor_cell_meas_request_response | DiagNG+MI | LTE ML1 | 1 | 43 | 1 | 1.6·0.0 | 96/164/232 | no(3) | 0.0–21.4 | 12.7–12.7 | 0.37·0.00 | idle too | plain | no |  |
| `0x147B` | gnss_cd_db_report | DiagNG | GNSS | 28 | 22 | 21 | 0.8·1.0 | 2635/2635/2635 | yes | 0.7–17.8 | 0.4–21.4 | 0.32·0.33 | too few | plain | no |  |
| `0xB171` | lte_srs_power_control_report | DiagNG | LTE MAC/PHY report | 24 | 34 | 9 | 1.3·0.4 | 16/580/604 | no(19) | 0.2–26.2 | 0.0–5.2 | 0.15·0.00 | too few | plain | no |  |
| `0xB19E` | lte_ml1_inter_frequency_log | DiagNG+MI | LTE ML1 | 2 | 42 | 0 | 1.6·0.0 | 40/52/68 | no(5) | no ts | — | no ts | no ts | plain | no |  |
| `0xB870` | nr5g_l2_ul_data_pdu | DiagNG | NR5G L2 (PDCP/RLC) | 3.10 | 37 | 4 | 1.4·0.2 | 372/892/1140 | no(33) | 13.9–15.0 | 16.5–17.0 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB84D` | nr5g_rlc_dl_stats | DiagNG+MI | NR5G L2 (PDCP/RLC) | 3.5 | 16 | 24 | 0.6·1.1 | 564/672/672 | no(2) | 0.0–15.0 | 12.4–22.0 | 1.00·0.92 | too few | plain | no |  |
| `0x147C` | gnss_pe_wls_position_report | DiagNG | GNSS | 13 | 18 | 21 | 0.7·1.0 | 796/1642/2018 | no(7) | 0.8–17.8 | 0.4–21.4 | 0.28·0.33 | too few | plain | no | 12 |
| `0x147E` | gnss_prx_rf_hw_status_report | DiagNG | GNSS | 7 | 18 | 21 | 0.7·1.0 | 816/816/816 | yes | 0.8–17.8 | 0.4–21.4 | 0.28·0.33 | too few | plain | no | 12 |
| `0xB0A1` | lte_pdcp_dl_data_pdu | DiagNG+SCAT | LTE PDCP | 55 | 21 | 12 | 0.8·0.5 | 100/556/4076 | no(25) | 3.7–21.7 | 9.5–20.4 | 0.14·0.25 | too few | plain | no |  |
| `0xB19C` | lte_ml1_conn_meas_eval_log | DiagNG | LTE ML1 | 42 | 24 | 9 | 0.9·0.4 | 16/16/32 | no(3) | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB1EF` | **UNKNOWN** | - | LTE ML1 | 40 | 17 | 16 | 0.6·0.7 | 2572/2572/2572 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0x1392` | qmi_link_3_rx_pdu | DiagNG | data path | 1 | 19 | 13 | 0.7·0.6 | 13/22/62 | no(4) | 1.9–2.7 | 12.5–12.9 | 0.32·0.00 | idle too | plain | no |  |
| `0xB1C5` | lte_ml1_ca_scell_config_log | DiagNG | LTE ML1 | 57 | 17 | 14 | 0.6·0.6 | 48/80/232 | no(10) | 3.0–22.4 | 14.1–16.2 | 0.12·0.00 | too few | plain | no |  |
| `0x7130` | umts_nas_gmm_state | DiagNG+MI | UMTS/NAS | 1, 0, 3 | 15 | 15 | 0.6·0.7 | 3/3/3 | yes | 1.8–2.9 | 12.4–13.3 | 0.60·0.13 | idle too | plain | no |  |
| `0xB869` | nr5g_rlc_ul_status_pdu | DiagNG | NR5G L2 (PDCP/RLC) | 3.2 | 6 | 24 | 0.2·1.1 | 32/224/272 | no(13) | 14.0–15.0 | 16.5–21.9 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0x1C07` | nr5g_sub6_txagc | DiagNG | firmware/RF | 8 | 12 | 16 | 0.4·0.7 | 464/464/464 | yes | 0.2–15.1 | 16.4–21.7 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB060` | lte_mac_configuration | DiagNG+MI | LTE MAC | 1 | 17 | 11 | 0.6·0.5 | 1080/1080/1080 | yes | 1.9–22.8 | 3.8–16.4 | 0.59·0.45 | idle too | plain | no |  |
| `0xB0CE` | **UNKNOWN** | - | LTE RRC | 32 | 13 | 15 | 0.5·0.7 | 53/53/53 | yes | 1.8–4.9 | 9.5–14.8 | 0.62·0.20 | idle too | plain | no |  |
| `0xB8AE` | nr5g_mac_skip_ul_tx | DiagNG | NR5G MAC | 3.12 | 22 | 5 | 0.8·0.2 | 16/16/32 | no(3) | 14.0–15.0 | 16.5–21.8 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0x7131` | umts_nas_mm_state | DiagNG+MI | UMTS/NAS | 0, 19, 18 | 13 | 13 | 0.5·0.6 | 3/3/3 | yes | 1.9–2.9 | 12.4–13.3 | 0.69·0.08 | idle too | plain | no |  |
| `0xB091` | lte_rlc_ul_config_log_packet | DiagNG+MI | LTE RLC | 59 | 13 | 13 | 0.5·0.6 | 128/236/272 | no(4) | 1.9–21.7 | 9.5–16.4 | 0.92·0.62 | idle too | plain | no |  |
| `0x12C1` | cm_call_event | DiagNG | modem control | 5 | 12 | 13 | 0.4·0.6 | 366/366/366 | yes | 1.8–21.7 | 9.5–16.4 | 0.92·0.54 | idle too | plain | no |  |
| `0xB860` | nr5g_pdcp_ul_stats | DiagNG | NR5G L2 (PDCP/RLC) | 3.14 | 12 | 13 | 0.4·0.6 | 308/308/308 | yes | 0.2–21.7 | 12.4–21.8 | 1.00·0.85 | too few | plain | no |  |
| `0x1D1C` | **UNKNOWN** | - | other (1x/data) | 9 | 11 | 13 | 0.4·0.6 | 2528/2528/2528 | yes | 1.8–21.7 | 9.3–16.3 | 1.00·0.54 | too few | plain | no |  |
| `0x7001` | umts_call_flow_analysis | DiagNG | UMTS/NAS | 161 | 12 | 11 | 0.4·0.5 | 12/12/62 | no(3) | 1.9–2.9 | 3.4–13.4 | 0.33·0.18 | idle too | plain | no |  |
| `0xB183` | lte_ml1_pbch_decode_log | DiagNG | LTE ML1 | 56 | 13 | 10 | 0.5·0.5 | 34/34/34 | yes | 2.4–21.7 | 12.7–19.9 | 0.69·0.50 | idle too | plain | no |  |
| `0x147D` | gnss_pe_kf_position_report | DiagNG | GNSS | 9 | 1 | 21 | 0.0·1.0 | 773/3579/3671 | no(6) | 1.3–1.3 | 0.4–21.4 | 1.00·0.33 | too few | plain | no | 12 |
| `0xB165` | lte_grant_manager_dedicated_configuration | DiagNG | LTE MAC/PHY report | 5 | 13 | 9 | 0.5·0.4 | 60/60/60 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0x19E3` | ds_bearer_info | DiagNG | data path | 9 | 8 | 13 | 0.3·0.6 | 83/83/161 | no(2) | 1.8–3.3 | 9.5–13.7 | 0.88·0.46 | idle too | plain | no |  |
| `0xB868` | nr5g_rlc_ul_stats | DiagNG | NR5G L2 (PDCP/RLC) | 3.8 | 9 | 12 | 0.3·0.5 | 212/212/212 | yes | 0.2–15.0 | 16.3–21.8 | 1.00·0.92 | too few | plain | no |  |
| `0x1854` | data_modem_ipa_wan_cfg | DiagNG | data path | 4 | 8 | 10 | 0.3·0.5 | 65/65/65 | yes | 2.9–3.4 | 9.3–13.8 | 1.00·0.40 | too few | plain | no |  |
| `0x1273` | cm_phone_event | DiagNG | modem control | 11 | 8 | 8 | 0.3·0.4 | 1854/1854/1854 | yes | 1.8–2.9 | 12.3–13.3 | 0.75·0.12 | idle too | plain | no |  |
| `0x7138` | umts_ue_dynamic_id | DiagNG | UMTS/NAS | 0, 1 | 8 | 8 | 0.3·0.4 | 5/5/5 | yes | 1.9–1.9 | 12.4–12.4 | 1.00·0.00 | too few | plain | no |  |
| `0xB081` | lte_rlc_dl_config_log_packet | DiagNG+MI | LTE RLC | 52 | 8 | 8 | 0.3·0.4 | 186/324/370 | no(4) | 1.9–21.7 | 9.5–16.3 | 0.88·0.50 | idle too | plain | no |  |
| `0xB0E5` | lte_nas_esm_bearer_context_info | DiagNG+MI | LTE NAS | 1 | 9 | 7 | 0.3·0.3 | 20/20/20 | yes | 2.9–21.7 | 11.0–16.4 | 1.00·0.71 | too few | plain | no |  |
| `0x189E` | dpl_iface_description_and_status | DiagNG | data path | 0 | 7 | 7 | 0.3·0.3 | 36/46/47 | no(4) | 2.6–3.4 | 12.8–13.8 | 0.71·0.57 | idle too | plain | no |  |
| `0x5386` | gsm_wms_ind_notify | DiagNG | SMS (WMS) | 1 | 8 | 6 | 0.3·0.3 | 5/5/5 | yes | 1.9–2.7 | 12.4–12.5 | 0.38·0.00 | idle too | plain | no |  |
| `0xB0EE` | lte_nas_emm_state | DiagNG+MI | LTE NAS | 2 | 7 | 7 | 0.3·0.3 | 19/19/19 | yes | 1.8–2.9 | 12.3–13.3 | 0.57·0.29 | idle too | plain | no |  |
| `0xB174` | lte_ml1_srch_list_freq_scan_log | DiagNG | LTE ML1 | 48 | 7 | 7 | 0.3·0.3 | 24/24/24 | yes | 2.2–2.3 | 12.5–12.7 | 0.00·0.00 | idle too | plain | no |  |
| `0x1994` | sdsr_list_print_packet | DiagNG | firmware/RF | 1 | 6 | 5 | 0.2·0.2 | 2757/2757/2757 | yes | 2.1–21.8 | 12.5–16.4 | 0.50·0.40 | idle too | plain | no |  |
| `0x7152` | umts_nas_fplmn_list | DiagNG | UMTS/NAS | 20 | 6 | 5 | 0.2·0.2 | 73/73/73 | yes | 2.1–21.8 | 12.5–16.4 | 0.83·0.80 | idle too | plain | no |  |
| `0xB0E4` | lte_nas_esm_bearer_context_state | DiagNG | LTE NAS | 1 | 5 | 6 | 0.2·0.3 | 4/4/4 | yes | 1.8–3.3 | 9.5–13.7 | 1.00·0.50 | too few | plain | no |  |
| `0xB0EA` | lte_nas_emm_security_protected_incoming_msg | DiagNG+SCAT | LTE NAS | 1 | 5 | 6 | 0.2·0.3 | 13/39/220 | no(5) | 2.7–3.3 | 9.5–13.7 | 0.60·0.50 | idle too | plain | yes |  |
| `0xB821` | nr5g_rrc_ota_packet | DiagNG+SCAT+MI | NR5G RRC | 26 | 7 | 4 | 0.3·0.2 | 36/44/695 | no(6) | 2.9–21.6 | 16.3–22.1 | **1.00·1.00 (NR leg)** | too few | plain | yes |  |
| `0x1CD9` | smart_transmit_information | DiagNG | firmware/RF | 21 | 5 | 5 | 0.2·0.2 | 28/32/32 | no(2) | 4.3–24.3 | 0.3–20.3 | 0.20·0.20 | too few | plain | no |  |
| `0xB0EB` | lte_nas_emm_security_protected_outgoing_msg | DiagNG+SCAT | LTE NAS | 1 | 5 | 5 | 0.2·0.2 | 12/22/140 | no(5) | 1.8–2.9 | 12.3–13.3 | 0.60·0.40 | idle too | plain | yes |  |
| `0xB84B` | nr5g_l2_dl_config | DiagNG | NR5G L2 (PDCP/RLC) | 3.5 | 7 | 3 | 0.3·0.1 | 196/230/262 | no(4) | 1.9–21.7 | 12.4–16.3 | 1.00·0.67 | too few | plain | no |  |
| `0xB0E6` | lte_nas_esm_procedure_state | DiagNG | LTE NAS | 1 | 4 | 5 | 0.1·0.2 | 7/7/7 | yes | 2.6–3.3 | 9.5–13.7 | 0.75·0.60 | idle too | plain | no |  |
| `0x1853` | data_modem_ipa_sio_config | DiagNG | data path | 6 | 4 | 4 | 0.1·0.2 | 112/112/112 | yes | 3.0–3.0 | 13.4–13.4 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0x1998` | pm_ph_history_info | DiagNG | firmware/RF | 1 | 4 | 4 | 0.1·0.2 | 70/70/70 | yes | 1.9–2.1 | 12.4–12.5 | 0.50·0.00 | idle too | plain | no |  |
| `0x7132` | umts_nas_reg_state | DiagNG | UMTS/NAS | 3, 0, 2 | 4 | 4 | 0.1·0.2 | 3/3/3 | yes | 1.8–2.9 | 12.3–13.3 | 0.75·0.25 | idle too | plain | no |  |
| `0xB0C1` | lte_rrc_mib_message_log_packet | DiagNG+SCAT+MI | LTE RRC | 2 | 5 | 3 | 0.2·0.1 | 11/11/11 | yes | 2.4–21.7 | 12.7–17.0 | 0.60·0.67 | idle too | plain | yes |  |
| `0xB0E1` | lte_nas_esm_security_protected_outgoing_msg | DiagNG+SCAT | LTE NAS | 1 | 3 | 5 | 0.1·0.2 | 13/29/79 | no(4) | 2.7–3.3 | 9.5–13.7 | 0.67·0.40 | idle too | plain | yes |  |
| `0xB0E3` | lte_nas_esm_plain_ota_outgoing_message | DiagNG+SCAT+MI | LTE NAS | 1 | 3 | 5 | 0.1·0.2 | 7/23/73 | no(4) | 2.7–3.3 | 9.5–13.7 | 0.67·0.40 | idle too | plain | yes |  |
| `0xB0ED` | lte_nas_emm_plain_ota_outgoing_message | DiagNG+SCAT+MI | LTE NAS | 1 | 4 | 4 | 0.1·0.2 | 11/19/134 | no(4) | 1.8–2.9 | 12.3–13.3 | 0.50·0.25 | idle too | plain | yes |  |
| `0xB160` | lte_downlink_common_configuration | DiagNG | LTE MAC/PHY report | 2 | 5 | 3 | 0.2·0.1 | 12/12/12 | yes | 2.6–21.8 | 12.8–16.4 | 0.80·0.67 | idle too | plain | no |  |
| `0xB166` | lte_prach_configuration | DiagNG | LTE MAC/PHY report | 40 | 5 | 3 | 0.2·0.1 | 8/8/8 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB17E` | lte_ml1_ue_mobility_state_change | DiagNG | LTE ML1 | 56 | 6 | 2 | 0.2·0.1 | 52/76/100 | no(3) | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB82C` | nr5g_rrc_blacklist_update | DiagNG | NR5G RRC | 2.0 | 4 | 4 | 0.1·0.2 | 20/20/20 | yes | 1.9–13.8 | 12.4–16.3 | 1.00·0.50 | too few | plain | no |  |
| `0xB9A7` | nr5g_ml1_dlm2_ca_metrics_request | DiagNG | NR5G ML1 | 3.2 | 6 | 2 | 0.2·0.1 | 240/240/240 | yes | 1.9–15.0 | 16.3–16.4 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0x199A` | pm_call_history_info | DiagNG | firmware/RF | 1 | 3 | 4 | 0.1·0.2 | 7/7/7 | yes | 1.8–3.3 | 9.5–13.7 | 1.00·0.50 | too few | plain | no |  |
| `0xB0E2` | lte_nas_esm_plain_ota_incoming_message | DiagNG+SCAT+MI | LTE NAS | 1 | 3 | 4 | 0.1·0.2 | 7/200/201 | no(4) | 2.7–3.3 | 9.5–13.7 | 0.67·0.50 | idle too | plain | yes |  |
| `0xB825` | nr5g_rrc_configuration_info | DiagNG+SCAT | NR5G RRC | 3.8 | 5 | 2 | 0.2·0.1 | 72/92/122 | no(3) | 1.9–21.7 | 12.4–16.4 | 1.00·0.50 | too few | plain | no |  |
| `0xB871` | nr5g_l2_ul_config | DiagNG | NR5G L2 (PDCP/RLC) | 3.4 | 5 | 2 | 0.2·0.1 | 152/164/180 | no(3) | 1.9–21.7 | 12.4–16.3 | 1.00·0.50 | too few | plain | no |  |
| `0xB886` | nr5g_mac_dl_tb_report | DiagNG | NR5G MAC | 3.8 | 1 | 6 | 0.0·0.3 | 24/24/28 | no(2) | 13.9–13.9 | 18.8–21.9 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB959` | nr5g_ml1_rlm_stats | DiagNG | NR5G ML1 | 3.2 | 3 | 4 | 0.1·0.2 | 1688/1688/1688 | yes | 0.8–15.0 | 17.4–21.2 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB0EC` | lte_nas_emm_plain_ota_incoming_message | DiagNG+SCAT+MI | LTE NAS | 1 | 3 | 3 | 0.1·0.1 | 7/33/214 | no(3) | 2.7–3.0 | 13.0–13.4 | 0.67·0.67 | idle too | plain | yes |  |
| `0xB89C` | nr5g_mac_flow_control | DiagNG | NR5G MAC | 3.1 | 3 | 3 | 0.1·0.1 | 36/36/36 | yes | 13.9–13.9 | 16.4–16.4 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB061` | lte_mac_rach_trigger | DiagNG+SCAT+MI | LTE MAC | 1 | 3 | 2 | 0.1·0.1 | 52/52/52 | yes | 2.6–21.7 | 12.8–16.3 | 0.67·0.50 | idle too | plain | no |  |
| `0xB062` | lte_mac_rach_attempt | DiagNG+SCAT+MI | LTE MAC | 1 | 3 | 2 | 0.1·0.1 | 60/60/60 | yes | 2.7–21.7 | 12.9–16.4 | 0.67·0.50 | idle too | plain | yes |  |
| `0xB06E` | lte_mac_dl_rar_transport_block | DiagNG | LTE MAC | 48 | 3 | 2 | 0.1·0.1 | 52/52/52 | yes | 2.6–21.7 | 12.9–16.4 | 0.67·0.50 | idle too | plain | no |  |
| `0xB0C2` | lte_rrc_serving_cell_info_log_pkt | DiagNG+SCAT+MI | LTE RRC | 3 | 3 | 2 | 0.1·0.1 | 29/29/29 | yes | 2.6–21.8 | 12.8–16.4 | 0.67·0.50 | idle too | plain | yes |  |
| `0xB144` | lte_ll1_rach_tx_report | DiagNG | LTE LL1 | 161 | 3 | 2 | 0.1·0.1 | 16/16/16 | yes | 2.6–21.7 | 12.9–16.4 | 0.67·0.50 | idle too | plain | no |  |
| `0xB167` | lte_random_access_request_msg1_report | DiagNG+SCAT | LTE MAC/PHY report | 40 | 3 | 2 | 0.1·0.1 | 32/32/32 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB168` | lte_random_access_response_msg2_report | DiagNG+SCAT | LTE MAC/PHY report | 24 | 3 | 2 | 0.1·0.1 | 12/12/12 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB169` | lte_ue_identification_message_msg3_report | DiagNG+SCAT | LTE MAC/PHY report | 40 | 3 | 2 | 0.1·0.1 | 12/12/12 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0x18AA` | policy_manager_subscription_info | DiagNG | firmware/RF | 3 | 2 | 2 | 0.1·0.1 | 100/100/100 | yes | 2.1–2.1 | 12.5–12.5 | 0.00·0.00 | idle too | plain | no |  |
| `0x1991` | call_manager_stats_event | DiagNG | modem control | 3 | 2 | 2 | 0.1·0.1 | 192/192/192 | yes | 1.8–1.9 | 12.4–12.4 | 1.00·0.00 | too few | plain | no |  |
| `0x1D15` | diag_wrapped_key_info | DiagNG+SCAT | firmware/debug | 1 | 2 | 2 | 0.1·0.1 | 724/724/724 | yes | 7.8–17.8 | 7.9–17.9 | 0.00·0.50 | too few | plain | no |  |
| `0x7139` | umts_ue_static_id | DiagNG | UMTS/NAS | 8 | 2 | 2 | 0.1·0.1 | 28/28/28 | yes | 1.9–1.9 | 12.4–12.4 | 1.00·0.00 | too few | plain | no |  |
| `0xB16A` | lte_contention_resolution_message_msg4_report | DiagNG+SCAT | LTE MAC/PHY report | 1 | 2 | 2 | 0.1·0.1 | 8/8/8 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB84E` | nr5g_rlc_dl_status_pdu | DiagNG | NR5G L2 (PDCP/RLC) | 3.0 | 3 | 1 | 0.1·0.0 | 49/107/206 | no(4) | 14.3–15.0 | 16.8–16.8 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0x1340` | delta_stats | DiagNG | data path | 1 | 0 | 3 | 0.0·0.1 | 16/16/16 | yes | — | 9.3–9.5 | 0.33 | too few | plain | no |  |
| `0x1D92` | cafi_peripheral_info | DiagNG | firmware/RF | 4 | 3 | 0 | 0.1·0.0 | 2753/2753/2753 | yes | 2.7–17.0 | — | 0.00 | too few | plain | no |  |
| `0xB17D` | lte_ml1_idle_measurement_request | DiagNG | LTE ML1 | 1 | 2 | 1 | 0.1·0.0 | 76/76/84 | no(2) | 2.4–2.6 | 12.7–12.7 | 0.00·0.00 | idle too | plain | no |  |
| `0xB187` | lte_ml1_idle_irat_measurement_request | DiagNG+MI | LTE ML1 | 1 | 2 | 1 | 0.1·0.0 | 288/288/288 | yes | 2.4–2.6 | 12.7–12.7 | 0.00·0.00 | idle too | plain | no |  |
| `0xB1D9` | lte_ml1_handover_timeline_info | DiagNG | LTE ML1 | 32 | 2 | 1 | 0.1·0.0 | 136/136/136 | yes | no ts | no ts | no ts | no ts | plain | no | 23 |
| `0xB88A` | nr5g_mac_rach_attempt | DiagNG+SCAT | NR5G MAC | 3.18 | 2 | 1 | 0.1·0.0 | 232/232/232 | yes | 13.9–13.9 | 16.4–16.4 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0x18A9` | policy_manager_config_info | DiagNG | firmware/RF | 3 | 1 | 1 | 0.0·0.0 | 90/90/90 | yes | 2.1–2.1 | 12.5–12.5 | 0.00·0.00 | idle too | plain | no |  |
| `0x1CD8` | nas_registration_status_info | DiagNG | modem control | 5 | 1 | 1 | 0.0·0.0 | 38/38/38 | yes | 3.0–3.0 | 13.3–13.3 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0x7150` | umts_nas_eplmn_list_log_packet | DiagNG | UMTS/NAS | 19 | 1 | 1 | 0.0·0.0 | 19/19/19 | yes | 2.9–2.9 | 13.3–13.3 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB0D4` | **UNKNOWN** | - | LTE RRC | 1 | 1 | 1 | 0.0·0.0 | 294/294/294 | yes | 2.7–2.7 | 12.9–12.9 | 0.00·0.00 | idle too | plain | no |  |
| `0xB0F5` | lte_nas_emm_usim_service_table | DiagNG | LTE NAS | 3 | 1 | 1 | 0.0·0.0 | 18/18/18 | yes | 1.9–1.9 | 12.4–12.4 | 1.00·0.00 | too few | plain | no |  |
| `0xB0F7` | lte_nas_emm_rrc_service_request | DiagNG | LTE NAS | 32 | 1 | 1 | 0.0·0.0 | 389/389/389 | yes | 2.1–2.1 | 12.5–12.5 | 0.00·0.00 | idle too | plain | no |  |
| `0xB176` | lte_initial_acquisition_results | DiagNG | LTE ML1 | 32 | 1 | 1 | 0.0·0.0 | 60/76/76 | no(2) | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB17F` | lte_ml1_serving_cell_meas_and_eval | DiagNG+SCAT | LTE ML1 | 5 | 1 | 1 | 0.0·0.0 | 40/40/40 | yes | no ts | no ts | no ts | no ts | plain | no |  |
| `0xB181` | lte_ml1_intra_frequency_cell_reselection | DiagNG+SCAT | LTE ML1 | 1 | 1 | 1 | 0.0·0.0 | 88/164/164 | no(2) | 2.6–2.6 | 12.9–12.9 | 0.00·0.00 | idle too | plain | no |  |
| `0xB18E` | lte_ml1_system_scan_results | DiagNG+MI | LTE ML1 | 41 | 1 | 1 | 0.0·0.0 | 116/116/116 | yes | 2.3–2.3 | 12.7–12.7 | 0.00·0.00 | idle too | plain | no |  |
| `0xB80C` | nr5g_nas_mm5g_state | DiagNG+MI | NR5G NAS | 3.0 | 1 | 1 | 0.0·0.0 | 27/27/27 | yes | 1.8–1.8 | 12.4–12.4 | 1.00·0.00 | too few | plain | no |  |
| `0xB889` | nr5g_mac_rach_trigger | DiagNG+MI | NR5G MAC | 3.14 | 1 | 1 | 0.0·0.0 | 72/72/72 | yes | 13.9–13.9 | 16.4–16.4 | **1.00·1.00 (NR leg)** | too few | plain | no |  |
| `0xB0B2` | lte_pdcp_ul_ctrl_pdu | DiagNG+SCAT+MI | LTE PDCP | 56 | 1 | 0 | 0.0·0.0 | 21/21/21 | yes | 13.8–13.8 | — | **1.00 (NR leg)** | too few | plain | no |  |
| `0xB841` | nr5g_pdcp_dl_control_pdu | DiagNG | NR5G L2 (PDCP/RLC) | 4 | 1 | 0 | 0.0·0.0 | 17/17/17 | yes | 13.9–13.9 | — | **1.00 (NR leg)** | too few | plain | no |  |
| `0xB861` | nr5g_pdcp_ul_control_pdu | DiagNG+MI | NR5G L2 (PDCP/RLC) | 3.2 | 1 | 0 | 0.0·0.0 | 24/24/24 | yes | 13.8–13.8 | — | **1.00 (NR leg)** | too few | plain | no |  |
| `0xB98F` | nr5g_ml1_antenna_switch_diversity | DiagNG | NR5G ML1 | 3.6 | 0 | 1 | 0.0·0.0 | 188/188/188 | yes | — | 16.5–16.5 | **1.00 (NR leg)** | too few | plain | no |  |

## Sources, and what each one is good for

Every name in this document comes from one of these. They are used as **facts only** — code numbers and the names
attached to them. No source code was copied from any of them, and none of their licences applies to FieldTap.

| Source | URL | Licence | Log-code names extracted | Notes |
|---|---|---|--:|---|
| P1sec/DiagNG, `struct/qualcomm/diag/log/log_codes.ksy` | https://github.com/P1sec/DiagNG/blob/main/struct/qualcomm/diag/log/log_codes.ksy | GPL-3.0 | 3,464 | By far the widest public table, and the source of **all 216** names here: every code SCAT, MobileInsight or mobile_sentinel names, DiagNG names too, so those tables are strict subsets for this corpus. Its own header credits QCSuper 2.1.1 as its origin. |
| fgsect/scat, `src/scat/parsers/qualcomm/diagcmd.py` | https://github.com/fgsect/scat/blob/master/src/scat/parsers/qualcomm/diagcmd.py | GPL-2.0 | 121 | Narrower but each entry is a code SCAT actually parses, so a name appearing here is stronger evidence than one appearing only in a list. Per-RAT parsers: `diagltelogparser.py`, `diagnrlogparser.py`. |
| MobileInsight core, `dm_collector_c/consts.h` | https://github.com/mobile-insight/mobileinsight-core/blob/master/dm_collector_c/consts.h | Apache-2.0 (per repo `LICENSE`; GitHub's API reports NOASSERTION) | 117 | The `LogPacketType` enum. `log_packet.h` holds its field layouts, which is where the measurement-layout work in [`qualcomm-measurement-log-layouts.md`](qualcomm-measurement-log-layouts.md) came from. |
| QCSuper, `src/qcsuper/protocol/log_types.py` | https://github.com/P1sec/QCSuper/blob/master/src/qcsuper/protocol/log_types.py | GPL-3.0 | 0 log codes | Equipment-ID and subsystem constants only; the log-code table moved to DiagNG. |
| Wireshark, `epan/dissectors/packet-qcdiag.c` | https://gitlab.com/wireshark/wireshark/-/raw/master/epan/dissectors/packet-qcdiag.c | GPL-2.0-or-later | 0 | **Wireshark has no built-in log-code table.** `qcdictionary_load()` builds `qcdiag_logcodes_ext` at startup from Qualcomm dictionary XML files the user drops in `<datadir>/qualcomm/`, and dumps them when `WIRESHARK_DUMP_QC_DICT` is set. Useful for the *framing*, not for names. Its header does cite the Qualcomm ICD document numbers (80-V1294-1, 80-V4083-1, 80-V2708-1, 80-V5295-1). |
| osmocom/osmo-qcdiag | https://github.com/osmocom/osmo-qcdiag | GPL-2.0 | 0 relevant | Covers 1x, GSM/GPRS, WCDMA, UMTS and QMI log codes; it has no LTE or NR table, so it contributes nothing to a corpus where the LTE and NR ranges are 157 of the 227 codes and 58.6% of the volume. |
| RUB-SysSec/mobile_sentinel, `parsers/qualcomm/diagcmd.py` | https://github.com/RUB-SysSec/mobile_sentinel/blob/master/app/src/main/python/parsers/qualcomm/diagcmd.py | GPL-2.0 | 91 | An earlier fork of the same table SCAT uses; a strict subset here. Used only as a cross-check. |
| Qualcomm documentation | — | proprietary | — | **Unverified.** No Qualcomm ICD was consulted for this document; the document numbers above are quoted from Wireshark's header comment, not read. |
| Academic papers | — | — | — | **Unverified.** MobileInsight's paper (Li et al., MobiCom '16) documents the collector architecture, not a log-code table; nothing in this document rests on it. |

### Caveats

* Names are names. A public name tells you what a code *is*; it does not give a body layout, and for this modem
  generation the layouts are frequently new (`0xB193` needed a re-derived v66 subpacket; `0xB0C0` needed a new
  header layout E30 at packet version 30). Treat every name here as a starting hypothesis for a decode, to be
  validated against the record length the way `layout.py` does.
* The two captures are 49 seconds of one handset on one operator. Rates, version bytes and the presence or absence
  of a code are facts about *this* modem and firmware, not about Qualcomm modems generally. In particular no code
  here was seen in more than one version, so the "Ver" column says which version needs a layout, not which versions
  exist.
* The idle-window and NR-leg tests use short windows (1.0 s of idle, 8.1 s of NR). They are stated with their
  sample sizes above so a reader can judge them; a code marked `too few` is genuinely undecided, not negative.
* The encrypted census covers 39 of the 61 codes the full C1 trace held, because only two QDSS chunk subsets are
  kept in the fixtures. The disjointness claim (no encrypted code ever appears plain) holds for those 39.

### Reproducing

Scripts live outside the repo, in the session scratchpad
`.../scratchpad/codes/`: `scan2.py` (per-code counts, sizes, version bytes, 0.25 s bins),
`timeline2.py` (the RRC/NR event timeline used for the phase windows), `names.py` (name-table extraction),
`table.py` and `md.py` (classification and this document's tables). They read the two .qmdl fixtures read-only and
write nothing into the repo. No identifiers (IMSI, IMEI, phone numbers, IP addresses) were read or recorded: the
inventory works on log codes, record lengths and timestamps only.
