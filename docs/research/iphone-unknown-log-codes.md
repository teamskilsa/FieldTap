# The unidentified log codes that dominate the iPhone trace

Owner: this file. `docs/research/iphone-log-code-inventory.md` is a different document.

Ten log codes carry **43.7 % of every record** the iPhone 17 (Qualcomm "M25", baseband 1.60.02)
writes into its QDSS baseband trace, and FieldTap shows none of them. This file is the
reverse-engineering of those ten: what each record is, how it is framed, which fields are
identified and with what evidence, and whether it is worth surfacing.

Nothing here reads or reports a subscriber identity, an IP address or a location. One code in
the same range (0x1476) *is* a position report; see the warning at the end.

## Method and evidence base

Two independent captures, both read with the repo's own HDLC unframer and log parser:

| | capture 2 | capture 1 |
|---|---|---|
| file | `ios/Fixtures/local/capture2/capture2.qmdl` | `ios/Fixtures/local/iphone-recovered.qmdl` |
| records | 85,323 in 22.1 s | 92,133 in 27 s |
| radio | driving, AT&T: LTE B12 (EARFCN 5110, PCI 80) → switch-off detach at t = 12.26 s → re-attach on B2 (EARFCN 650, PCI 235) at t = 12.84 s → EN-DC add on n77 at t = 16.29 s | stationary: attach, EN-DC on n5, two handovers |

Ground truth came from the repo's own decoders, not from guesswork: RRC/NAS message names and
times from `fieldtap.decode`, and per-antenna RSRP/RSRQ/RSSI/SNR (0xB193), DL transport blocks
(0xB173), PUSCH Tx reports (0xB139), CQI/RI (0xB14D/0xB14E), RACH (0xB062), serving cell
(0xB0C2) and the NR set (0xB887/0xB888/0xB97F) from `ios/Fixtures/local/reference-phy/`.

Four kinds of evidence are used, in descending order of strength:

1. **A framing rule that closes exactly.** A length arithmetic or a walk that consumes the body
   with no bytes left over, on every record, in *both* captures. Every rule below does this.
2. **A field that matches a quantity another code already gives us.** The SFN of 0xB134 against
   the SFN of 0xB193; the NR frame number of 0xB8A1 against that of 0xB887; a tick counter
   regressed against the DIAG record clock.
3. **A conservation law.** `used + remaining == 475,000` in 0x1C8E; `end >= start` on all 8,028
   sessions of 0x1874; a sequence number that never skips.
4. **Presence/absence tied to a state change.** 0xB8A1 exists only after the EN-DC add.

Public sources were used as documentation only — no code was copied from any of them. The
useful ones turned out to be the **QXDM Professional release notes** (which list code→name pairs
verbatim) plus SCAT's and MobileInsight's name tables and osmo-qcdiag's equipment-ID scheme.
**Four of the seven original targets turn out to have public names after all**; the earlier
inventory's "(no public name found)" was a search miss, not a fact about the codes. That is
recorded per code below.

Reference decoders and their validation output:
`/private/tmp/claude-501/-Users-Projects-triptocasino/743a94f1-93ad-4086-b700-6e606c91212e/scratchpad/unknown/`
(`validate.py` runs every framing rule against both captures; `d1375.py`, `d1874.py`, `d184c.py`,
`d1c8e.py`, `d1d0b.py`, `d19ef.py`, `db134.py`, `db1dc.py`, `db11b.py`, `db8a1.py` each print
their own checks.) These are scratch references, deliberately not in the repo.

## Summary

| code | records (cap 2) | share | what it is | confidence | surface it? |
|---|---|---|---|---|---|
| 0x1375 | 12,571 | 14.7 % | modem-internal metric/event bus; 95 message types, 28-byte self-describing header | framing certain, purpose high, payloads unknown | yes — as an event lane and a trace-health signal |
| 0x1874 | 8,028 | 9.4 % | MCPM (Modem Clock and Power Manager) session, with 19.2 MHz start/end ticks | high (public name + clock validated) | yes — one "modem power churn" number |
| 0xB134 | 4,539 | 5.3 % | LTE LL1 Serving Cell RS: per-subframe, per-Rx-branch reference-signal measurement | name high, framing certain, fields low | no — 0xB193 already answers the question better |
| 0x184C | 2,393 | 2.8 % | LTE RF FED Tx AGC: per-chain transmit power and PA gain state | high | **yes — the biggest single win here** |
| 0xB8A1 | 2,180 | 2.6 % | NR5G per-slot MAC↔LL1 record, v3.1; frame and slot identified | framing certain, identity medium, payload low | not yet |
| 0x1D0B | 1,914 | 2.2 % | 100 Hz modem sampler: five 2 ms entries per 10 ms record, two validated clocks | framing certain, purpose low | yes — but only the clocks, as a gap meter |
| 0xB11B | 1,825 | 2.1 % | an LTE LL1 searcher/tracking record, 28 + 92·n | framing certain, identity none | no |
| 0x1C8E | 1,507 | 1.8 % | a resource quota / token-bucket report, budget 475,000 | framing certain, resource unknown | no |
| 0xB1DC | 1,253 | 1.5 % | LTE ML1 Modem Clocks: per-domain clock-level snapshot | high | maybe — a "modem clock level" tile |
| 0x19EF | 1,072 | 1.3 % | the same subsystem as 0x1C8E, bursty 345-byte snapshot | framing certain, identity none | no |

---

## 0x1375 — the modem's internal metric and event bus

**14.7 % of all records (12,571 in capture 2, 10,934 in capture 1) — the single largest code in
the trace.** No public name. Equipment ID 1, item 0x375, which is the catch-all non-3GPP range;
no public source names it and no public source publishes the item-block allocation that would.

### Structure — certain

A 28-byte header and a length-delimited opaque payload:

| offset | width | field |
|---|---|---|
| 0 | u32 | message id, read as `(group << 16) \| item`; group is 0 or 1 |
| 4 | u32 | message type: 1, 2, 5, 6, 7, 8, 9 or 16 |
| 8 | u32 | `0x010100XX`; the low byte is the emitting instance (observed 0,1,2,4,5,6,7,8,16,19,21) |
| 12 | u32 | per-instance counter A |
| 16 | u32 | per-instance counter B |
| 20 | u32 | per-instance counter C |
| 24 | u32 | payload length in bytes |
| 28 | … | payload |

**`len(body) == 28 + u32@24` holds on 12,571 of 12,571 records in capture 2 and 10,934 of 10,934
in capture 1, with no exceptions.** A 28-byte header and a self-consistent length field over
23,505 records is not a coincidence; the framing is settled.

95 distinct message ids appear in 22 s, and **91 of the 95 have exactly one payload length** —
the id names a struct. Counters A/B/C advance per record but their bases differ per instance
(instance 2 sits near 0x1279xx while instance 0 sits near 0x06D4xx), so they are per-instance
sequence numbers, not a global clock.

### What it is — high confidence

Two behaviours identify it:

* **A 1 Hz statistics sweep.** 32 of the 95 message ids have a median inter-arrival gap of
  1.00 ± 0.05 s, and within any given second all 32 land inside a ~50 ms window (e.g. t = 5.373
  through 5.424). That is a periodic metrics dump walking a table of counters.
* **Event-driven records that fire exactly on state changes.** Six ids appear *only* inside the
  detach/re-attach window 12.2–13.4 s: `0x000011`, `0x00003A`, `0x000052`, `0x0100A1`,
  `0x0100EE`, `0x01874F`. `0x000011` fires at 12.27 (the Detach request), 12.43, 12.83
  (Attach request) and 13.35 (Attach complete). Others fire on 3 s, 4 s and 7 s periods.

So 0x1375 is a **transport for the modem's own metrics and events**, not a radio measurement:
a message id, a type, an emitting instance, per-instance sequence numbers, a length, and a
struct the log itself does not describe.

A plausible but unproven identification is Qualcomm's QSH (snapshot/health) framework: the
recovered F3 debug text from the same firmware prints `[AWD]VoiceLastCallEnd key:source:qsh_event,
client 13, event 91` and `key:qindex, client 13, metric 5, last_read 14, last_write 14`, i.e. a
client/metric/ring-index vocabulary that matches this header's shape. **Flagged as inference.**

### What was ruled out

* Not a radio measurement. The only float in any payload (ids `0x0186B4`/`0x000026`, 50 Hz) is
  −29.741 dB moving once to −29.716 dB across 22 s; correlated against RSRP, RSRQ, RSSI, SNR,
  CQI, RI, DL/UL TBS, MCS, PRB, Tx power and every NR KPI tracked, every |r| < 0.03. It is a
  calibration constant, not a measurement.
* Not QMI: the payloads are fixed-size C structs, not TLV sequences.
* Not protobuf, so not an AWD metric blob in serialized form.

### What it buys us

A **modem-internal event lane** we cannot draw today: a timestamped list of "the modem's own
software reacted here", alignable with the RRC/NAS lane, which is exactly the evidence a user
needs when the radio looks fine but the phone still misbehaves. And the 1 Hz sweep is a free
**heartbeat**: a missing sweep is a missing second of trace.

**Recommendation: surface it**, at the level of "message id + instance + time", not payloads.
A 95-row id histogram and the six transition-only ids are useful with no payload decoding at all.
Do not try to decode payloads without symbols; there is no public id table and there will not be
one.

---

## 0x1874 — MCPM General Session Power

**9.4 % of all records (8,028 in capture 2, 9,214 in capture 1).** Public name found:
**"MCPM General Session Power"**, QXDM release notes (two separate version entries). MCPM is
Qualcomm's Modem Clock and Power Manager. Version byte 0x11.

### Structure — certain, and the clock is proven

| offset | width | field |
|---|---|---|
| 0 | u8 | version, 0x11 |
| 1 | u16 | 0xFFFF |
| 3 | u8 | a resource/reason byte (4, 8, 14, 15, 16, 18, 28) |
| 4 | u8 | session kind; it selects the body length |
| 8 | u64 | resource bitmask A (e.g. `0x0000C00000000000`) |
| 16 | u64 | resource bitmask B (e.g. `0xC000000000000000`) |
| 42 | u64 | **session start, 19.2 MHz ticks** |
| 50 | u64 | **session end, 19.2 MHz ticks** |

Session kind → length: 1 → 86/98/114/158/174/190; 4,5,6,7 → 58; 0 → 271/295/343/367. The two
64-bit fields are at the same offsets in every variant.

**Validation.** Regressing `u64@42` against the DIAG record timestamp over the whole capture
gives **19.2000 MHz with r = +1.00000**. Independently, `end − start` is **non-negative on all
8,028 records** — a field-order test that would fail about half the time if the two were swapped
or mis-sized. Durations: min 0.16 µs, median 7.97 µs, p90 17.8 µs, max 73.9 µs.

### What it is — high confidence

One record per clock/power-manager session, i.e. per request the modem's power manager handled,
with the exact interval it took. The two 64-bit words are the resources involved.

### What it buys us

Total session time is 2–3 ms per second of trace while the radio is steady and **rises 4× during
the second of the detach and re-attach** (records per second go 327 → **1003** → 720 across
t = 11, 12, 13 s). Session duration does **not** track throughput (|r| ≤ 0.12 against DL, UL and
NR volume) — it measures *manager work*, not radio work.

That is a real, currently missing answer to "why did the battery drop while nothing was
happening": a per-second count of clock/power requests and the time spent in them, spiking
exactly on RAT and cell changes.

**Recommendation: surface one derived number** — MCPM sessions per second, with the per-second
series — not the raw records. Cheap (two u64 reads) and directly interpretable.

---

## 0x184C — LTE RF FED Tx AGC. The biggest win here.

**2,393 records in capture 2, 4,465 in capture 1.** Public name found: **"LTE RF FED Tx AGC"**,
QXDM release notes (V8 entry). FED = front-end driver. Version byte 0x11.

### Structure — 99.9 % exact

`record = N blocks; block = 16-byte block header + k × 120-byte sub-records`, with
`body[1] = N` (2..5) and k = 1..3 per block.

`len(body) == 16·N + 120·M` fits **all eight observed lengths** (392, 512, 528, 544, 632, 648,
664, 680), and a walk that finds block headers by the signature `body[p] == 0x11` and five zero
bytes at `p+2` consumes the body exactly on **2,391 of 2,393** records (99.92 %) in capture 2 and
**4,464 of 4,465** (99.98 %) in capture 1.

Block header: `u16@7 >> 4` is a subframe counter that steps by exactly 1 between consecutive
blocks — the blocks of one record are consecutive subframes.

Sub-record (120 bytes), fields identified:

| offset | width | field | evidence |
|---|---|---|---|
| 0 | u8 | chain index within the record (0x10, 0x11, 0x20, 0x21, 0x22 …) | sequential per record |
| 1 | u8 | AGC/PA gain state (0x10, 0x24, 0x30, 0x34 …) | **r = −0.80** against PUSCH Tx power: a lower state means more power |
| 2 | i16 | a small negative constant per record (−6, −7) | |
| 4 | i16 | **transmit power, 0.1 dBm** | range −70.0 … +25.0 dBm; −70.0 dBm is the "chain off" sentinel; r = +0.47 |
| 6 | i16 | **transmit power, 0.1 dBm** (a second measure) | range −2.9 … +28.8 dBm; r = +0.54 |
| 8 | i16 | mirrors @4 | |
| 10 | u16 | linear gain word | 600 … 5,500; r = +0.57 |
| 12 | u16 | linear gain word | 10,532 … 61,648; r = **+0.72** |
| 66/68/70 | u16 | per-chain limit, 0.1 dBm | 17.7 … 25.0 dBm; r = −0.73 … −0.75 |
| 114 | u16 | linear gain word | 773 … 11,299; r = **+0.82** |

All correlations are against the PUSCH transmit power FieldTap already derives from 0xB139
(`pwr_raw/4 − 1.5`, range 7.3 … 41.5 dBm), binned at 50 ms, n = 2,391. A best-fit of the
strongest field leaves a 3.8 dB residual, so this is the *front-end* chain's own power and gain,
measured at its own instants — a different, more physical quantity than the PUSCH target, which
is precisely why it is worth having.

### What it buys us

Things FieldTap cannot answer today and could answer from this code alone:

* **Is the phone transmit-limited?** Per-chain actual Tx power against the per-chain limit at
  offsets 66/68/70. An uplink-limited phone at the cell edge is the single most common cause of
  "full bars, nothing works", and no code we decode today says it.
* **Which antenna/chain is transmitting**, and when the modem switches. The `−70.0 dBm` sentinel
  marks chains that are off; a record carries 3–5 subframes × 1–3 chains.
* **PA gain state**, which is what actually drives handset heat and battery during upload.

**Recommendation: implement this one first.** The framing is nailed down, the fields are in
physically sensible units with a ±0.1 dB resolution, and it fills a genuine hole. The residual
against 0xB139 should be checked against a second device before the numbers are labelled
"transmit power" in the UI; until then label them "front-end Tx power (chain N)".

---

## 0xB8A1 — an NR5G per-slot record

**2,180 records in capture 2, 774 in capture 1.** **No public name.** Version 3.1 (u16 minor,
u16 major — the NR convention 0xB887/0xB888 use). Public sources name 0xB8A0 ("NR5G MAC LL1
PUSCH Tx") and 0xB8A7 ("NR5G MAC CSF Report") and leave 0xB8A1–0xB8A6 blank, so the code sits
inside the NR5G MAC↔LL1 cluster. That is adjacency, not documentation.

### It is NR, and that is certain

**0xB8A1 does not exist before the EN-DC add and appears in the same second as it.** Records per
second across t = 0…22 s are zero everywhere up to t = 15 and then 288, 500, 439, 178, 343, 391 —
exactly the profile of 0xB887 and 0xB888, and the NR `rrcReconfiguration` is at t = 16.291 s.

### Structure — 100 % exact on both captures

```
header  8 bytes : u16 minor=1, u16 major=3, 3 reserved, u8 nsub
sub     8 bytes : u8 slot, u8 flags, u16 w, u32 nblk     then nblk x 20-byte blocks
```

**2,180 of 2,180 records parse with zero bytes left over** (774 of 774 in capture 1).
9,507 sub-records; `nblk` is 2 (7,398), 3 (2,097) or 1 (12).

Two fields are identified and validated:

* **`sub[0]` = NR slot.** Its range is **exactly 0…19, all 20 values present** — which is the slot
  count per frame for numerology µ = 1 (30 kHz SCS), the correct numerology for n77.
* **`u16@2 & 0x3FF` = NR frame number.** Compared with the frame number independently decoded
  from 0xB887 on time-matched samples (±10 ms), the difference is **0 on 4,926 samples and ±1 on
  2,186**, with 22 samples further out — i.e. it agrees within one frame on 99.7 % of samples,
  the ±1 being the expected pipeline lag. Upper 6 bits of the word are flags.

Inside the 20-byte blocks, `u32@16 >> 14` behaves like a 19.2 MHz tick: the gap between
consecutive sub-records matches `slots_elapsed × 9,600` ticks to within 10 µs on 4,986 of 9,496
consecutive pairs. Medium confidence — the other half is scattered, probably a per-block offset.
The blocks' `u32@0` carries a 12-bit signed value whose two blocks differ by a constant 144, and
a 14-bit field whose all-ones state `0x3FFF` reads as "unset".

### What was ruled out

Neither `nblk` nor any block u32 correlates with NR throughput, MCS, PRB count or the 0xB888 byte
counters (every |r| < 0.2). So it is not a PDSCH/PUSCH statistics record.

### Recommendation

**Not yet.** What it gives us today is an NR slot-accurate timeline — 1,655 slot records per
second (9,507 sub-records over 5.74 s) out of the 2,000 slots per second n77 has at mu = 1 — with no identified content. The frame/slot
pair is genuinely useful as a time axis for other NR codes, so record the framing and revisit if
a second device or a newer QXDM name list turns up.

---

## 0xB134 — LTE LL1 Serving Cell RS

**4,539 records in capture 2, 4,888 in capture 1.** Public name found: **"LTE LL1 Serving Cell
RS"**, QXDM release notes (v129 and v141 entries). Version 0xA3. One release-notes line calls
0xB134 "LTE PDCCH-PHICH Indication Report", but MobileInsight independently puts that record at
0xB16B and two other release-notes lines say "Serving Cell RS", so that line is a document typo.

### Structure — 100 % exact on both captures

20-byte header, then n sub-records of 96 or 152 bytes:

| offset | width | field | evidence |
|---|---|---|---|
| 0 | u8 | version, 0xA3 | |
| 1 | u8 | pipeline/instance (0x10–0x13 or 0x20–0x32); two records per radio frame, one of each | |
| 3 | u8 | number of Rx branches: 2 or 4 | matches the sub-record size |
| 6–11 | — | 0xFF ×6, the family's "unset" marker (0xB11B uses it too) | |
| 12 | u8 | **`(n_subrecords << 3) \| branches`** | reproduces all 20 observed body lengths |
| 14 | u16 | **bits 6–15 = SFN** | see below |

`len(body) == 20 + n × (96 if branches == 2 else 152)` reproduces every one of the 20 observed
lengths (116 … 1540), and **4,539 of 4,539 records frame exactly** (4,888 of 4,888 in capture 1).
n runs 1…10 and is 10 on 4,095 of them.

**Two hard validations.**

1. **SFN.** `u16@14 >> 6` compared with the SFN decoded independently from 0xB193 on 3,573
   time-matched records: the difference is 0 (1,183) or 1023, i.e. −1 (2,284) — **97.0 % within
   one frame**, the −1 being the pipeline lag of a record emitted after its frame.
2. **Sub-records are consecutive subframes.** `sub[0] >> 4` is the subframe and `sub[0] & 1` a
   frame-wrap flag; across 38,621 sub-record transitions, only **102 (0.26 %)** are not the next
   subframe modulo 10.

So: a per-subframe, per-Rx-branch record, ten subframes (one radio frame) per record, two records
per frame from two pipelines, with 2 or 4 branches.

### Fields — low confidence, and what was ruled out

The 4-branch sub-record holds 12 i16 at offset 20, four i16 all equal to −6 at 44, and
**4 × branches u16 at offset 52** that read as dBm × 100 over −136 … −89 dBm. Read that way they
are in the right physical range, and smoothed to 0.25 s their mean correlates −0.70 with RSSI,
−0.59 with RSRP, +0.68 with SNR and +0.61 with PUSCH Tx power: it moves with link quality.

**Ruled out** (these are the negatives, stated so nobody repeats the work):

* **Not per-antenna RSRP, RSRQ, RSSI or SNR.** Correlated column-by-column against the four
  per-antenna values 0xB193 gives, every |r| ≤ 0.34 (n = 5,268). Grouping the 16 values into four
  groups of four and comparing group means to the four antenna values: |r| ≤ 0.34 again, and the
  **antenna imbalance test fails outright** — `group1 − group0` against `rsrp_rx[1] − rsrp_rx[0]`
  gives r = +0.07. The four group means span only 1.4 dB while 0xB193's four antennas span 15.6 dB.
* **Not MCS, PRB count, TBS or CQI**: no field reaches |r| = 0.35 against any of them.
* Not a noise estimate either: a noise floor would fall as SNR rises, and these rise.

Within a sub-record the 16 values increase monotonically (e.g. −107.8 … −89.3 dBm), which points
at a per-symbol or per-resource-group profile rather than a per-antenna set. The dBm/100 scale
itself is inferred from the range, not proven.

### Recommendation

**Do not surface it.** The name says reference-signal measurement and the framing is certain, but
0xB193 already gives calibrated per-antenna RSRP/RSRQ/RSSI/SNR with a decoder we trust, at 100+
samples a second. 0xB134 would add 5.3 % of the trace for a quantity we cannot label. Keep the
framing and the SFN field — the SFN is a useful, independently validated time axis — and leave
the measurement block alone until a second handset lets the units be pinned down.

---

## 0x1D0B — a 100 Hz modem sampler with two validated clocks

**1,914 records in capture 2, 2,238 in capture 1.** **No public name.** Nearest named item in
the range is 0x1D15 (a secure-log public key), which tells us nothing.

### Structure — 100 % exact, and both clocks are proven

| offset | width | field |
|---|---|---|
| 0 | u32 | version, 7 |
| 4 | u32 | **timestamp, 1024 Hz** |
| 8 | u32 | **timestamp, 19.2 MHz, 24 bits** (wraps every 0.874 s) |
| 84 | u32 | **record sequence number** |
| 90 | 5 × 56 | five entries |

Body length 370 on 1,911 of 1,914 records (the other three are truncated); 90 + 5 × 56 = 370.
The entry array's stride was found by autocorrelation and then confirmed the hard way: scanning
the body for values within 250,000 ticks of the record's own 19.2 MHz stamp finds tick fields at
offsets **8, 90, 146, 202, 258 and 314** — one header stamp and five entries on a 56-byte stride.

**Validations.**

* `u32@8`: median per-record rate **19,200,006 counts/s** — the 19.2 MHz TCXO, to seven figures.
* `u32@4`: **1023.8 … 1023.9 counts/s** measured over three gap-free stretches (0–6 s, 0–9.5 s,
  14–22 s), with per-record increments of 10 (1,441×) or 11 (451×). That is the 32.768 kHz sleep
  clock divided by 32 = 1024 Hz.
* `u32@84`: **1,902 of 1,907 consecutive deltas are exactly +1** — a sequence number that does
  not skip.
* The five entry ticks are spaced **38,400 ticks = 2.000 ms** apart (mode 38,400, spread ±200
  ticks = ±10 µs), covering the 10 ms the sequence number steps over. The entry's `u32@4` carries
  a ring index in bits 12–15 that cycles 0,1,2,3,4.

So: a **100 Hz record carrying five 2 ms samples** of something, nominally one record per LTE
radio frame.

### What resists identification

What is being sampled every 2 ms. The entry's remaining fields are mostly zero with a handful of
slowly varying words (a constant high byte 0x8A on one of them, a per-record-constant pair that
differs from the per-entry pair). Correlating them against RSRP, RSSI, SNR, CQI, MCS, PRB,
TBS and Tx power produced nothing above |r| = 0.5. Not identified; not claimed.

### What it buys us anyway

The clocks make it a **trace-integrity meter**. The record rate drops from 100/s to 14/s across
the detach (t = 10–13 s), and the 1024 Hz counter says exactly how much wall time went missing:
steps of +2280, +1154, +991, +620 counts = **2.23 s, 1.13 s, 0.97 s and 0.61 s of trace that was
never written**. The existing `traceGaps` problem in the analysis output only knows that three
chunk files are missing; this turns that into seconds, in the right places.

**Recommendation: surface the clocks only.** Two u32 reads and a subtraction turn a vague
"messages around the gaps may be incomplete" warning into "2.2 s of the capture is missing, here".
Ignore the entries.

---

## 0xB11B — an unnamed LTE LL1 record

**1,825 records in capture 2, 1,848 in capture 1.** **No public name**, and the gap is real:
public tables name 0xB119 ("LTE LL1 Neighbor Cell Measurements and Tracking") and 0xB11D ("LTE LL1
Serving Cell TTL Results") and leave 0xB11A–0xB11C blank, so the code sits inside the LL1
searcher/tracking cluster.

### Structure — 100 % exact on both captures

28-byte header (version 0xA1 at offset 0; `byte[3]` is 0x14 on 925 records and 0x3A on 900 — two
variants in near-equal proportion; bytes 10–15 are 0xFF ×6 on 1,345 of them, the same "unset"
marker 0xB134 uses, confirming the family), then **n sub-records of 92 bytes**:
`(len(body) − 28) % 92 == 0` on **1,825 of 1,825** records, n running 1…20.
The 92-byte stride was found by byte autocorrelation (0.72 at lag 92, 0.66 at 184, 0.61 at 276).

### Recommendation

**No.** Framing settled, content not identified, and the LL1 tracking cluster it belongs to is
already represented by codes we do decode. Recorded here so the 2.1 % is accounted for and so the
next person starts from the framing rather than from bytes.

---

## 0x1C8E and 0x19EF — one resource-accounting subsystem, two codes

**0x1C8E: 1,507 records (2,346 in capture 1). 0x19EF: 1,072 (1,768).** Neither has a public name.
0x1C8E sits in the newest 0x1Cxx block whose only public anchors are NR5G RFE (0x1C01/0x1C02) and
IMS ICS (0x1C40–0x1C49).

### They are the same subsystem — and that is checkable

0x1C8E's `byte[5]` is an instance id, 47 or 52. **0x19EF's `byte[28]` carries the same two ids**
(47 on 1,046 records, 52 on 16), and **0x19EF's `u32@29` matches 0x1C8E's `u32@7` for instance 47
to within 2,000 units on 561 of 1,072 time-matched records**. Two codes carrying the same
instance id and the same counter value at the same instant are the same accounting subsystem;
0x1C8E is the per-event report and 0x19EF the larger, bursty snapshot (0 records in 8 of the 22
seconds).

### 0x1C8E structure — 100 % exact, with a conservation law

Fixed 58 bytes, `u32@0 == 4`:

| offset | width | field |
|---|---|---|
| 0 | u32 | version, 4 |
| 4 | u8 | kind: 5 (with instance 47) or 6 (with instance 52) |
| 5 | u8 | instance id: 47 or 52 |
| 6 | u8 | state: 0, 1 or 2 |
| 7 | u32 | **amount used / available** |
| 27 | u32 | a cumulative counter (29.67 M → 30.60 M on instance 47; 150 k → 162 k on instance 52) |
| 35 | u32 | **the complement of `u32@7`** |
| 43 | u32 | flags, `0x9000xx00` |
| 46, 50, 54 | u32 | **250,000 / 500,000 / 1,000,000** — three thresholds, byte-identical in both instances and both captures |

**The conservation law: `u32@7 + u32@35 == 475,000`** on **528 of the 645** records of instance 47
whose pair is non-zero (the remainder are transitional), and the pair is 0/0 otherwise. A pair of
independent 32-bit fields summing to the same constant 475,000 over hundreds of records is a
token bucket: used and remaining against a fixed budget, with 250 k / 500 k / 1 M as the
configured watermarks.

### What the budget counts — not identified, and here is what it is not

The drain rate of `u32@7` was correlated against everything the radio does: PUSCH Tx power,
uplink volume, uplink PRB count, downlink volume, NR volume and RSRP. **Every |r| < 0.2**
(n = 529). So it is **not** a transmit-time or SAR budget, **not** a throughput or data-volume
quota, and **not** thermally driven by transmit power. It drains at a median of a few thousand
units per second in either direction, which would exhaust 475,000 in roughly five minutes.

### Recommendation

**No.** The framing and the invariant are solid enough to hand on, but a quota over an
unidentified resource is not something to put in front of a user. 3.1 % of the trace accounted
for, and the negatives above save the next attempt.

---

## 0xB1DC — LTE ML1 Modem Clocks

**1,253 records in capture 2, 1,850 in capture 1.** Public name found: **"LTE ML1 Modem Clocks"**,
QXDM release notes (including a changelist line "0xB1DC LTE ML1 Modem Clocks (added)").
Version 0x30, fixed 136 bytes, **1,253 of 1,253 parsed**.

| offset | width | field | evidence |
|---|---|---|---|
| 0 | u8 | version, 0x30 | |
| 4 | u32 | a request/sequence value | |
| 8 | u32 | **timestamp, 32.768 kHz sleep clock** | **32.7153 kHz with r = +0.99991** against the DIAG record clock over 22.09 s — 0.16 % off nominal, which is the sleep clock's own accuracy |
| 20 | u32 | 1193 → 1198, slowly rising | not identified; a plausible temperature or drift word, not claimed |
| 24 | u32 | number of level blocks: 1 or 2 | it also moves where the array sits |
| 28–99 | 72 × u8 | **per-domain clock level, 0…17** | see below |

**The clock-level array behaves exactly as the name implies.** It is a snapshot, not a delta:
**78 distinct patterns before the EN-DC add and only 13 after** (the modem settles into a steady
clock plan once NR is up), 12 of those 13 never occur before it, and **two clock domains (indices
6 and 26) raise their maximum level once NR is configured** while fourteen others drop theirs.
A clock plan that reorganises itself at the moment NR is added is the confirmation.

**Recommendation: maybe.** One derived tile — "modem clock level" as the maximum or the sum over
domains — is a legible proxy for modem load, and it is two lines of parsing on top of a name we
trust. Not a priority; 0x184C and 0x1874 are worth more per byte.

---

## Warning for whoever implements the rest: 0x1476 is location

`0x1476` is publicly named **"GNSS Position Report"** (QXDM release notes, three separate
mentions). Capture 2 contains **105 of them at a steady 5 Hz** across a 22 s drive; capture 1
contains 22.

This document did not decode them and deliberately reports no field, no value and no range from
them. Anyone extending FieldTap should treat 0x1476 — and 0x1477, 0x1480, 0x1923, 0x1924 and the
rest of the GNSS block — as **the most sensitive data in the whole trace**: a 5 Hz position track
of the user, which is more identifying than the IMSI. It must not be decoded into any output the
user can share, must not reach an upload path, and should be excluded by log code before any
capture leaves the phone. The existing "no identifiers" rule in
`ios/Fixtures/local/reference-phy/decoders.py` covers ECI and TAC; it needs a line about GNSS too.

## Also worth recording: names found for codes the inventory left blank

Verified only as names (from the QXDM release notes and SCAT's tables), not exercised against the
capture here, but they close gaps in `docs/research/iphone-log-code-inventory.md`:

| code | public name | records, capture 2 |
|---|---|---|
| 0xB15B | LTE LL1 RX Antenna Info | 943 |
| 0xB113 | LTE LL1 PSS Results | 188 |
| 0xB123 | LTE LL1 Neighbor Cell CER | 606 |
| 0xB126 | LTE LL1 PDSCH Demapper Configuration | 62 |
| 0x1544 | QMI_MCS_QCSI_PKT | 844 |
| 0x1391 | QMI Link 2 TX Message | 813 |
| 0x12E8 | TRM (Transceiver Resource Manager) | 323 |
| 0x11EB | Protocol Services Data (the IP-packet log) | 155 |

0xB15B is worth a note: its 272-byte body is a 32-byte header followed by 30 eight-byte entries
that read as (address, value) pairs with the address stepping by 4 — a register dump, which is
consistent with "RX Antenna Info" reading the RF front end directly.

One route would settle every remaining unknown here: QXDM/QCAT ships an ASCII `LogItem` table
(id, name, category_id) that osmo-qcdiag's `tools/qxdm_db.py` already knows how to read. It is
not on the public web. If anyone ever has a QXDM installation to hand, that table answers
0x1375, 0x1C8E, 0x1D0B, 0x19EF, 0xB11B and 0xB8A1 in one go — and gives Qualcomm's own subsystem
grouping for the whole 0x1xxx range, which no public document reproduces.
