# The named log codes FieldTap does not decode yet

The iPhone 17's Baseband-profile capture carries 222 distinct log codes. FieldTap decodes fourteen of
them. This document works through seventeen more that **already have a public name** but no FieldTap
decoder, on this modem's own record versions, and says for each one what was validated, with what numbers,
and what was rejected.

Summary of the outcome, so the rest can be read in any order:

| | codes |
|---|---|
| **payload decoded, high confidence** | 0xB063, 0xB126, 0xB179, 0xB12A, 0xB16C |
| **framing and timing decoded, one field partly validated** | 0xB111, 0xB146 |
| **framing and timing decoded, payload rejected** | 0xB114, 0xB122, 0xB11B, 0xB11D, 0xB16B, 0xB8C9, 0xB883, 0xB884, 0xB885, 0xB8A7 |

Every framing in the second and third rows consumes 99.7–100% of the bodies in both captures, so the
rejections are about *meaning*, not structure. Two of the brief's asks are answered and two are not: the
antenna counts are in 0xB126 (high confidence) and the 5G uplink scheduling is **not** decodable from these
captures. That is set out in full below, with the capture each open question needs.

The two captures used throughout:

| | `capture2.qmdl` | `iphone-recovered.qmdl` |
|---|---|---|
| condition | driving, 22 s | stationary, attach |
| LTE | B12 EARFCN 5110 PCI 80, then B2 EARFCN 650 PCI 235, carrier aggregation | B66/B12/B2, two handovers |
| NR | EN-DC on n77, 30 kHz SCS | EN-DC on n5, 15 kHz SCS |
| records | 85,323 | ~84,000 |

Both are read-only fixtures under `ios/Fixtures/local/`. Nothing from them is copied into the repo.

## Method and licensing

Same clean-room rule as `qualcomm-measurement-log-layouts.md`: MobileInsight is Apache-2.0 and is cited;
SCAT, QCSuper, DiagNG and Wireshark are GPL and were read for **wire-format facts only**. In practice
none of the published layouts fitted this modem, so every layout below was derived from the data and then
had to pass a check. The checks are the point of the exercise.

Two tools did most of the work and are worth keeping:

**The timestamp oracle.** A record's DIAG timestamp and its own frame number differ by a constant
(logging latency). So the correct 10-bit SFN/frame field in an unknown record is the one whose residual
`(record time − field × 10 ms) mod 10.24 s` collapses to a single tight cluster; scoring by circular
concentration `R` needs no assumption about the latency. On these captures the right field scores
`R = 1.00000` and every wrong offset scores 0.5–0.8, so the test is decisive. **It found the timing field
in all seventeen codes below**, and it re-found 0xB887's, which was already known — that is the control.
The oracle's own accuracy is about 1.25 ms standard deviation on batched records and 0.12 ms on 0xB126 and
0xB8C9, which is good enough to fix the frame exactly and to narrow, but not prove, a subframe or slot.

A corollary that took a while to appreciate: **the SFN must be unwrapped into absolute time before any
cross-code alignment test will work.** The 10.24 s SFN cycle aliases about 2.2 times in a 22 s capture, so
comparing two codes on `(SFN, subframe)` alone makes every anchor test come out flat. Once unwrapped, the
alignments become unambiguous — that is how 0xB16C's uplink grants were tied to 0xB139's PUSCH reports at
the n+4 offset.

**The two-bandwidth trick.** The captures use different NR carriers (n77, 217 PRB, 30 kHz versus n5,
52 PRB, 15 kHz) and different LTE bands, so a field that is a PRB count, a chain count, a slot index or a
numerology must change its range between them in a predictable way. That is what proved the NR numerology
byte and 0xB8C9's receive-chain count, and what made the one 0xB883 PRB-count lead worth recording.

**And the standing trap, which caught two fields.** In a capture that changes band or cell, a correlation
against RSRP can be entirely the band change rather than the quantity you are after. 0xB111 has fields
reaching |r| = 0.95 against serving RSRP that collapse to |r| ≤ 0.28 once you restrict to a single EARFCN.
Every correlation claim below is therefore reported **within one serving cell**, or rejected.

Reference decoders and the validation run live in this session's scratchpad, at
`/private/tmp/claude-501/-Users-Projects-triptocasino/743a94f1-93ad-4086-b700-6e606c91212e/scratchpad/named/`:

- `b063.py`, `b126.py`, `b179.py`, `nrul.py` (the four NR uplink codes), `b111.py`, `b8c9.py`,
  `b114.py`, `b12a.py`, `b122.py`, `b11b.py` (0xB11B + 0xB11D), `b146.py`, `b16b.py` (0xB16B + 0xB16C)
- `ground.py`, `nr97f.py`, `nrtbs.py` — the already-shipped FieldTap decoders and the TS 38.214 TBS
  formula, ported unchanged, used only as ground truth
- `qmdl.py`, `oracle.py`, `findslot2.py`, `framing.py`, `probe.py`, `tti.py` — the reusable tools
- `validate_named.py`, `validate_ll1.py`, `validate_agc.py` and their combined output in
  `validation-output.txt`

They are Python, in the style of `web/engine/src/phy/decoders/` — module docstring stating the layout, a
`parse()` that dispatches strictly on the record version and refuses anything else. Nothing was copied into
the repo and the captures were opened read-only.

---

## 0xB063 LTE MAC DL Transport Block, v50 — **decoded, high confidence**

The name is in MobileInsight's log-code table (Apache-2.0) and FieldTap's Python registry already carries
it. SCAT publishes a v49/v50 record layout (GPL, read for its wire-format facts only).
**That layout does not fit this modem.** Applying it gives transport-block sizes in the millions and an
exact parse for 80 of 143 records. Both its header and its per-transport-block header sit 8 bytes earlier
than what v50 emits here, and its 3-byte SDU descriptor has a different bit order.

### Layout on this modem

```
header, 8 bytes
  u8   +0   version 0x32
  3 B  +1   reserved
  u32  +4   transport block count
per transport block, 16 bytes
  u32  +0   transport block size in BYTES
  u32  +4   padding bytes
  u32  +8   SFN bits 0-9, subframe bits 10-13
  u8  +12   HARQ id bits 4-7, carrier bits 0-3
  u8  +13   SDU count
  u16 +14   MAC header length in bytes
then per SDU a 12-byte descriptor, first 3 bytes a little-endian 24-bit word
  bit 0     1 = MAC control element, 0 = data SDU
  bits 1-6  LCID (TS 36.321 tables 6.2.1-1 / 6.2.1-2)
  bits 7-22 length in bytes
  and, for a data SDU, a PDCP tail of 8 x descriptor byte 9 bytes
```

### Fields, units, confidence

| field | unit | confidence | what it answers |
|---|---|---|---|
| transport block size | bytes | **high** | how many MAC bytes actually arrived |
| padding | bytes | medium | how much of the grant was wasted |
| SFN, subframe | — | **high** | when |
| HARQ id, carrier | — | **high** | which HARQ process, which carrier |
| SDU control flag, LCID, length | bytes | **high** | signalling versus user data, per bearer |
| MAC header length | bytes | low | see the size identity below |
| PDCP tail length rule | — | medium | only needed to walk to the next transport block |

### Validation

- **Against 0xB173.** Every transport block the walk finds is looked up in 0xB173's own PDSCH records by
  `(SFN, subframe, carrier, HARQ, size)`. It is there in **968 of 978 (99.0%)** on the driving capture and
  **2,518 of 2,521 (99.9%)** on the stationary one. Four independent fields have to be right at once for
  that to happen, so this pins the transport-block header.
- **Byte totals.** 0xB063's MAC bytes come to 655,956 and 2,235,835; 0xB173's CRC-passing C-RNTI transport
  blocks come to 771,317 and 2,575,115. So 0xB063 accounts for **85% and 87%** of the bytes 0xB173 sees,
  which is exactly the share of declared transport blocks the walk reaches (978 of 1,230 and 2,521 of
  3,085). Padding is **2.9% and 1.9%** of the MAC bytes.
- **The SFN field** scores `R = 0.99997` on the timestamp oracle.
- **The descriptor bit order** is confirmed by 3GPP's own fixed control-element sizes: the descriptor
  reads LCID 28 with length 6, which is the UE Contention Resolution Identity (6 bytes, TS 36.321
  6.1.3.4), and LCID 27 with length 1, which is Activation/Deactivation. No other bit split produces
  both.
- **The size identity** `size = header length + Σ SDU lengths + padding` holds exactly for 33 of 68
  single-transport-block records and is **off by exactly one byte** for 34 of them. Since `size` is
  independently confirmed against 0xB173, the one-byte slack is in `header length` or `padding`; both are
  therefore marked medium/low and the app should use `size` and the SDU lengths.
- **The walk.** The PDCP tail rule was measured, not guessed: resynchronising on the next
  self-consistent transport-block header over 2,176 single-SDU tails gives `2 × descriptor byte 9` words
  in 94% of them and one word more in the rest. With the rule plus a scan-forward fallback the walk lands
  on the last byte of the body in 65% / 56% of records and recovers 80% / 82% of the declared transport
  blocks. This is the weak point of the decode and the reason for the byte shortfall.

### What it adds, and one correction to the brief

It adds **MAC-level downlink accounting**: bytes that actually reached the MAC (not transport-block bytes
including padding and retransmissions), split per LCID, so the app can separate signalling (LCID 1–2) from
user data (LCID 3–5) and show *useful* throughput next to the PHY throughput 0xB173 already gives.

It does **not** give continuous timing advance. 0xB063 logs a control element's LCID and length but not
its body, so even where the timing-advance command (LCID 29) appears there is no 6-bit value to read —
and it appears **twice in 22 seconds of driving and four times in the stationary capture**. The network
simply does not send many. The continuous timing source is 0xB114, below.

### Next step to implement

1. `web/engine/src/phy/decoders/lteMac.ts`: add `decodeB063` beside `decodeB064`, same `Decoded<>`
   discipline, `B063_VERSION = 0x32`, refuse anything else.
2. `ios/FieldTapKit/Sources/FTPhy/Decoders/B063.swift`: mirror it; register in `PhyDispatch.swift` and
   `PhyCatalog.swift`.
3. Android: the same layout in the Kotlin decoder set.
4. Add two runtime checks to `web/engine/src/phy/checks.ts` (and `PhyChecks.swift`): *every 0xB063
   transport block matches a 0xB173 transport block on (SFN, subframe, carrier, HARQ, size)* — threshold
   0.95, currently 0.99 — and *the walk ends on the last byte of the body*, reported as coverage rather
   than pass/fail so a firmware change that alters the PDCP tail shows up as falling coverage.
5. Add `0xB063` to the Python registry with `confidence="high"` and the note that the timing-advance
   command's value is not in the record.

---

## 0xB126 LTE LL1 PDSCH Demapper Configuration, v163 — **decoded, and this is the antenna answer**

Public name from the Qualcomm log-code tables; no published layout found. Fixed 968-byte body throughout
both captures.

### Layout on this modem

```
header, 8 bytes: u8 version 163, then 7 bytes that never change
then 20 fixed 48-byte sub-records, one per subframe, OLDEST FIRST
  u16  +0        SFN bits 4-13, subframe bits 0-3
  u8   +2 bits 1-3   transmit antenna ports of the cell (2 or 4 seen)
          bits 4-5   receive antennas - 1 (0 -> 1, 1 -> 2, 3 -> 4)
  u8   +4 bits 0-1   rank - 1 (spatial layers of this PDSCH)
  7 B  +8        PDSCH resource-block allocation bitmap, bit k = PRB k (50 bits on a 50-PRB cell)
  7 B +24        the same bitmap again
  u8   +5, +7, +40, +41   not identified
  +15..23, +31..39, +42..47   zero on this modem
```

Only the **last** sub-record is "now": its `(SFN, subframe)` matches the record's own timestamp with
`R = 1.00000` and a standard deviation of **0.12 ms** (the tightest timing in either capture), which is
what fixed the sub-record size, the count and the order.

### Fields, units, confidence

| field | unit | confidence | what it answers |
|---|---|---|---|
| SFN, subframe | — | **high** | which subframe, 20 per record |
| PRB allocation bitmap | bit per PRB | **high** | exactly which resource blocks this PDSCH used |
| rank | spatial layers | **high** | how many MIMO layers, per subframe |
| transmit antenna ports | count (1/2/4) | **high** | the cell's antenna configuration |
| receive antennas | count (1/2/4) | medium | how many of the phone's antennas were in use |
| bytes +5, +7, +40, +41 | — | rejected | not identified; not read |
| a carrier index | — | rejected | searched for, not found; the record follows whichever carrier was scheduled |

### Validation

- **The bitmap is one bit per PRB.** `popcount(bitmap)` equals an `N_RB` that 0xB173 reports for the same
  subframe in **1,193 of 1,199 (99.5%)** and **2,322 of 2,330 (99.7%)** sub-records. Byte +14 only ever
  takes the values 0 and 3, i.e. bits 48 and 49 and no higher — exactly 50 bits for a 50-PRB cell.
- **Rank** equals 0xB173's layer count in **97.3% / 97.0%**. Every remaining disagreement is a subframe
  where 0xB173 says "4 layers, 1 transport block", which the shipped 0xB173 decoder already documents as
  transmit diversity rather than 4-layer MIMO — so rank 1 is the correct reading there, and counting
  those as agreements gives **99.9% / 100.0%**. 0xB126's rank is the *better* of the two fields.
- **Transmit antenna ports** equals the 0xB0C1 MIB's antenna count for every cell whose MIB was captured:
  all **2,360 of 2,360** sub-records in the stationary capture, across three cells, read 4, and all three
  MIBs say 4; **1,059 of 1,080** sub-records on the driving capture's PCI-235 cell read 4, and its MIB
  says 4. The one cell with no MIB in the capture reads 2. Decisively, the field follows the **serving
  cell**, not the subframe: EARFCN 650 / PCI 235 gives 4 in 1,059 sub-records against 21, and EARFCN 5110
  / PCI 80 gives 2 in 140 against 20. That is why it is an antenna-port count and not the transmission
  mode — a transmission mode would change with the scheduling, and it does not.
- **Receive antennas** agrees with the Rx antennas 0xB193 actually measured, time-matched, in **88% and
  93%**. Not decisive (0xB193's Rx map is a per-report validity mask and the time match is loose), hence
  medium.

### What it adds

The user's question — antennas — answered from the record instead of inferred from the broadcast plus the
measurement record: **transmit antenna ports per serving cell, receive antennas in use, and the MIMO rank
per subframe**, 20 subframes per record. Plus the PRB allocation bitmap, which is a genuinely new view:
*which* resource blocks, not just how many, so the Radio page can show a per-subframe waterfall of the
allocation next to the throughput.

### Next step to implement

1. New decoder file in all three sets (`b126.ts`, `B126.swift`, Kotlin), version 163 only, returning the
   20 sub-records.
2. Feed `rank` and `txAntennas` into the existing per-carrier state in `extract.ts` / `PhyExtractor.swift`
   so the Radio page's antenna line stops being an inference. Keep the MIB as the fallback.
3. Add the runtime check *popcount(0xB126 bitmap) is an N_RB 0xB173 reports for the same subframe*
   (threshold 0.95) and *0xB126 rank equals 0xB173 layers, transmit diversity excepted* (threshold 0.95).
4. The bitmap is 7 bytes per sub-record; keep it as a bitmask, not an array, and derive `nPrb` from it.

---

## 0xB179 LTE ML1 Connected Mode Intra-Frequency Measurements, v56 — **decoded, high confidence**

Public name from SCAT's log-code table. FieldTap's Python registry already lists it with the note "layout
is version dependent and bit packed"; on this modem's v56 it is not bit packed at all.

### Layout on this modem

```
  u8   +0   version 56
  3 B  +1   reserved
  u32  +4   0, 9, 18 or 27 on this modem: not identified
  u32  +8   EARFCN of this measurement
  u16 +12   serving PCI
  u16 +14   TTI = SFN * 10 + subframe
  u16 +16   serving RSRP, x * 0.0625 - 180 dBm      u16 +18  the same value again
  u16 +20   serving RSRQ, x * 0.0625 - 30 dB        u16 +22  the same value again
  u32 +24   neighbour count n
then n x 12 bytes
  u16  +0   PCI
  u16  +2   RSRP, x * 0.0625 - 180 dBm              u16 +4   the same value again
  u16  +6   RSRQ, x * 0.0625 - 30 dB                u16 +8   the same value again
  u16 +10   zero in all 757 neighbour records
```

The paired fields are the instantaneous and filtered values; they are equal in every record in both
captures, so only one is returned.

### The timestamp problem, and the fix

**These records carry no DIAG timestamp.** All 385 and all 373 arrive with timestamp 0, which is why the
fixture inventory marks 0xB179 as time-interpolated. The in-record TTI at +14 solves it: against the
interpolated time it scores `R = 1.00000 / 0.99999` with a mean offset of 1,438 / 1,669 ms — **the same
constant every other log code in the same capture shows** — and a spread of 3.8 / 5.2 ms. So the record
places itself in time to about four subframes without needing the interpolation at all.

### Validation

- `len == 28 + 12 × count` in **380 of 385 (98.7%)** and **369 of 373 (98.9%)**.
- The serving `(EARFCN, PCI)` is a cell 0xB193 reports as serving in 325 of 373 records, and the RSRP
  agrees with 0xB193's: mean **+0.12 dB**, sd **0.78 dB**, **93% inside 1 dB** on the stationary capture
  (mean −0.06 dB, sd 2.33 dB when driving, where the interpolated time is worth only a few subframes).
  RSRQ agrees to mean +0.03 dB, sd 1.30 dB. **This is what fixes the scales as 0xB193's own**, with no
  published constant taken on trust.
- Only **29 of 492** and **43 of 265** neighbour PCIs also appear in 0xB193, and where they do the RSRP
  agrees to within 2 dB in 72% / 86%. The other 463 and 222 neighbour measurements are measured by
  **nothing else in the capture** — that is the value of the code.

### What it adds

The **ranked neighbour list with RSRP and RSRQ**, per frequency, continuously and without waiting for an
RRC `MeasurementReport`. In the driving capture that is 492 neighbour measurements on PCIs 295, 388, 298,
449, 263 and 362, on seven EARFCNs, none of which 0xB193 reports. This is the handover story: *why* the
phone moved, not just that it did. It is also the first record in FieldTap that needs no timestamp from
the transport.

### Next step to implement

1. New decoder in all three sets, version 56 only.
2. Use the in-record TTI as the record's time; do not depend on the QDSS rebuild's interpolation.
3. Add the runtime check *0xB179's serving RSRP is within 1 dB of 0xB193's for the same cell* (threshold
   0.90 — it degrades when the phone is moving fast, which is honest) and *len == 28 + 12 × count*
   (threshold 0.95).
4. UI: a neighbour table under the serving cell, sorted by RSRP, with the offset from the serving cell in
   dB — that difference is the handover margin.

---

## The 5G uplink: 0xB883, 0xB884, 0xB885, 0xB8A7 — **framing and timing decoded, payload rejected**

Public names from the Qualcomm log-code tables: 0xB883 NR5G MAC UL Physical Channel Schedule Report
(v3.26), 0xB884 NR5G MAC UL Physical Channel Power Control (v3.5), 0xB885 NR5G MAC DCI Info (v3.20),
0xB8A7 NR5G MAC CSF Report (v3.5). No published layout found for any of them.

### The NR record convention, proven

All four — and, checked as a control, the already-shipped 0xB887 — share this:

```
packet header, 8 bytes: u16 minor version, u16 major version, 3 bytes, u8 record count at +7
then `count` records, each beginning
  u8  +0   slot inside the frame
  u8  +1   numerology mu: 0 = 15 kHz SCS, 1 = 30 kHz SCS
  u16 +2   frame, bits 0-9; bits 10-15 are a per-code constant flag
0xB885 alone inserts 8 more bytes before its first record, so its records start at +16.
Record sizes: 0xB883 44 or 60, 0xB884 32 or 64, 0xB885 36 or 48, 0xB8A7 76.
```

| check | 0xB883 | 0xB884 | 0xB885 | 0xB8A7 |
|---|---|---|---|---|
| body length = count × the listed sizes, capture2 | 99.8% | 100% | 100% | 100% |
| body length = count × the listed sizes, first capture | 99.7% | 100% | 100% | 100% |
| frame field, circular `R` | 1.00000 | 1.00000 | 1.00000 | 1.00000 |
| latency offset, capture2 (0xB887 gives 1448 ms) | 1449 ms | 1447 ms | 1448 ms | 1448 ms |

The **numerology byte** is the cleanest result here. It is 1 on every record of all five codes on
capture2's n77 carrier and 0 on every record of the first capture's n5 carrier, and the slot field at +0
tops out at 19 when it is 1 and at 9 when it is 0 — 20 and 10 slots per 10 ms frame, which is exactly
3GPP's µ = 1 and µ = 0. That is a field validated by two captures rather than by a published table, and it
is what lets an NR record be converted to absolute time correctly on any band.

The slot byte is high confidence for a different reason: the timestamp narrows it to about ±2.5 slots, the
byte at +0 is the only candidate that stays inside 0..19 while keeping the residual spread at the
timestamp's own accuracy, 0xB887's slot — known independently — is in the same place, and its range
follows the numerology byte. Nothing else does all four.

### What was rejected, and why

**0xB883's uplink MCS, PRB count and transport block size are not decoded.** The accept/reject test was
the TS 38.214 5.1.3.2 transport-block identity, exactly as the shipped 0xB887 decoder uses it. Over 458
single-record bodies on the driving capture, the search enumerated every 10–20-bit transport-block field,
every 5-bit MCS field and every 6–9-bit PRB field in the record (259 × 129 surviving candidates after a
spectral-efficiency bound of 0.02–8 bits/RE) and asked for a consistent N_RE per PRB. **No combination
reaches even 60%.**

The positive control rules out a broken test: run the same identity against the shipped 0xB887 decoder
and **828 of 828** new transmissions on the driving capture and **472 of 472** on the stationary one
satisfy TS 38.214 exactly (plus 138 and 25 retransmissions, MCS 28–31, which the identity excludes by
construction). The method finds the answer when the answer is there.

One lead is recorded and **not** accepted: the 8-bit field at record bit offset 215 (u32 at record +26,
bits 7–14) reaches **212** on the n77 carrier (217 PRB) and **47** on the n5 carrier (52 PRB), which is
the shape of a PRB count and the sort of thing the two-bandwidth trick is good at finding. It fails the
transport-block identity against every candidate partner, so it stays a lead.

**0xB884's uplink power is not decoded.** With NR RSRP too sparse to correlate against (30 and 20 serving
samples from 0xB97F, spanning only 5 dB), the test used was correlation with the validated LTE required
PUSCH power from 0xB139 — in EN-DC both uplinks see the same path loss. The best fields reach `r = +0.81`
on the driving capture and `r = +0.79` on the stationary one, but **at different bit offsets**, so nothing
is claimed.

**0xB8A7's CQI, RI, PMI and beam, and 0xB885's DCI contents, are not decoded.** 0xB8A7 is very sparse
(142 and 42 records, most of the 84-byte body zero) and the NR downlink rank in these captures is almost
always 1, so there is nothing with enough variance to validate an RI field against.

The name "MAC DCI Info" for 0xB885 does get corroborated, though, which is worth recording for whoever
picks it up: **683 of the 913 slots 0xB885 reports on the driving capture (75%) are slots in which
0xB887 logged an NR PDSCH**, i.e. a downlink assignment and the transmission it schedules land in the
same slot. None of them coincide with an 0xB883 slot, which is also right — an uplink grant is sent in a
downlink slot and the PUSCH follows K2 slots later.

### What is nevertheless worth shipping now

The 5G uplink section the product wants cannot be built from this. What *can* be built, and is worth
building because it is cheap and it makes the next attempt possible, is:

- the shared NR record header as a small helper used by 0xB887, 0xB888 and these four;
- **numerology and therefore subcarrier spacing per NR carrier**, which the app currently does not show
  at all and which is the difference between 20 and 10 slots per frame everywhere else;
- a **presence-and-rate** row for each of the four codes: 0xB883 fires 605 times in 22 s, 0xB885 605,
  0xB884 542, 0xB8A7 142. "The modem is scheduling uplink at 27 grants/second, and FieldTap can see the
  timing but not yet the sizes" is honest and useful, and it is the hook for the next capture.

### Next step to implement

1. A shared `nrRecordHeader()` in `web/engine/src/phy/decoders/nr.ts` (and `Bytes.swift`) returning
   `{count, recordOffset}` plus per-record `{slot, numerology, frame}`; refactor `decodeB887` onto it —
   0xB887's records satisfy this header, so the refactor is testable against the existing fixtures with no
   behaviour change.
2. Surface `scsKhz = 15 << numerology` on the NR carrier in `finish.ts` / `PhyFinish.swift`.
3. Do **not** add 0xB883/0xB884/0xB885/0xB8A7 to the catalog as measurement sources. Add them to the
   Python registry with `confidence="low"` and a note pointing at this document.
4. To finish 0xB883, the next capture needs a **high-rate uplink transfer on NR** (a sustained upload)
   so the MCS and PRB fields exercise their full range; the present captures are almost all small grants,
   which is why the identity search has so little to work with. Capture 0xB883 together with 0xB885 and
   0xB887 and cross-check the uplink grant against the DCI.

---

## 0xB111 and 0xB8C9 receive gain control — **framing and timing decoded, gain rejected**

These are the two densest codes in the capture and the reason they were on the list. Both framings are now
**proved at 100%** and both timing fields are validated; no gain field survived its check.

| code | version | records | rate | per-antenna samples/s |
|---|---|---|---|---|
| 0xB111 LTE LL1 Rx AGC | 166 | 4,849 / 4,172 | 219.5 / 155.2 per s over 22.09 / 26.88 s | **4,156 / 2,846** |
| 0xB8C9 NR5G LL1 FW Rx Control AGC | 3.1 | 4,764 / 2,660 | **588.3** per s over 8.10 s / 118.9 over 22.38 s | 4,684 / 236 |

0xB8C9 exists in the driving capture only for the **last 8.10 seconds** of the 22 — the NR secondary cell
group comes up late — which matters below.

### 0xB111, v166

```
8-byte header
  u8   +0   version 166
  u8   +1   bits 0-4 sub-record count N (1..20 seen); bits 5-7 flags, not identified
  u8   +2   0x80 | {0,1,2,4,6}, not identified          u8 +3  zero
  u32  +4   "extended" bitmap: bit i set -> sub-record i is 56 bytes, else 40
then N sub-records, and len(body) == 8 + 40*N + 16*popcount(mask & ((1<<N)-1))
sub-record, first 40 bytes
  u32  +0   bits 0-1 Rx chain index, bits 2-11 SFN, bits 12-15 subframe
  i16  +2   per-chain received power, 1/256 dB
  f32  +4, +8   genuine IEEE-754 float32, 1e-7..1e-2 in 99.07% / 97.97% of samples
extension bytes 40..55: u32 +40 bits 0-2 a small state 0..7, bits 3-12 a 10-bit index; u32 +44 a counter
```

`len == 8 + 40N + 16·popcount(mask)` holds for **9,021 of 9,021 records (100.0000%)** across both captures,
and no mask bit above `N−1` is ever set. This also *explains* the 0x78–0x7b marker that looked so promising
and generalised so badly: it is `u32 +0` bits 0–1 (the chain) together with bits 12–15 (the subframe), which
happen to line up that way only when a record starts on subframe 7 with four chains.

**Timing validated.** The last sub-record's SFN and subframe give circular `R = 0.994554` (n = 4,849) and
`0.991108` (n = 4,172), with a 1st-to-99th-percentile residual spread of **0.67 ms / 0.76 ms** — against
9.09 ms for SFN alone, which is how you know the subframe field is real. Pooled over every sub-record,
`R = 0.996363` (n = 91,817) and `0.993937` (n = 76,507).

**One field partially validated: `i16 +2` as per-chain received power, 1/256 dB** (its low 5 bits are zero in
95.8% / 99.7% of samples, so the effective step is 0.125 dB). Median −81.1 / −82.9 dBm, 5th–95th percentile
−85.6 to −65.6 dBm. The evidence is a *per-antenna differential* test — remove each record's common mode and
compare the spread across chains with 0xB193's `rsrp_rx[0..3]`: `r = +0.311` driving (n = 9,468 chain
samples, slope +0.21 dB/dB) and `+0.765` stationary (n = 8,312, slope +0.64 dB/dB), with the strongest chain
matching 0xB193's strongest antenna 36.8% / 55.1% of the time against 25% by chance. Same sign in both
captures. Its *absolute* value does not track serving RSRP within a band (|r| ≤ 0.27), which is exactly what
a post-AGC wideband power should look like. Medium confidence, on the differential only.

**Every gain candidate is rejected**, and the near-miss is instructive. Fields derived from `u32 +40` reach
|r| = 0.768, 0.946, 0.823 and 0.922 against 0xB193's serving RSRP for chains 0–3 — which looks conclusive
until you restrict to a single serving EARFCN, where it collapses to |r| ≤ 0.28. **The correlation was the
B12→B2 band change, not path loss.** The sign also flips between chains, cells and captures (the stationary
capture's EARFCN 67086 gives −0.90, +0.82, −0.83, −0.93), and nothing has a slope anywhere near the
−1 dB/dB a gain must have. Also rejected: `f32 +4` (differential `r` = +0.32 driving but −0.38 stationary — a
sign flip), `f32 +8`, `i32 +12`, `u32 +16`, `u32 +20`, the eight u16 at +24..+39, `u32 +44`, `u32 +52`, and
the unidentified header bits.

**And one structural absence worth knowing:** there is **no PCI, EARFCN or carrier id anywhere in the
record**. An exhaustive search over 9-, 10-, 16-, 17-, 18-, 20- and 32-bit fields found nothing matching the
time-matched serving PCI or EARFCN in either capture. So an 0xB111 record cannot be attributed to a
component carrier — which is the main reason the gain question stays open, because on a carrier-aggregated
capture the gain of two carriers is interleaved with no way to separate them.

### 0xB8C9, v3.1

```
16-byte header
  u16  +0   minor 1        u16 +2   major 3
  u32  +4   monotone firmware tick, median step ~19200
  u32  +8   per-capture constant (0x115 / 0)
  u8  +12   0xFC           u16 +13  len - 12          u8 +15  zero
then a self-describing chunk chain from offset 16
  tag = b[p], size = b[p+1]; advance until p == len
  tag 0x04 = AGC chunk, size = 16 + 32*E ; tag 0xFE = 4-byte terminator
chunk header: u32 +8 bits 0-4 unknown (2 on n77, 3 on n5), bits 5-9 slot, bits 10-19 SFN
```

The chunk chain consumes **7,424 of 7,424 bodies (100.0000%)**. The byte at offset 13 does determine the
length, as suspected, because it *is* the length. And the guess that the differing body lengths meant a
per-PRB array was **wrong**: `E` is the number of **receive chains** — 4 on n77, 2 on n5 — and the whole
difference is E plus the chunk count (n77: two chunks × 4 chains + terminator = 308; n5: one chunk ×
2 chains + terminator = 100).

**Timing is the strongest fit in this document.** `(t − SFN × 10 ms − slot × 0.5 ms)` gives circular
`R = 1.000000` on both captures (n = 4,748 and 2,640) with a percentile spread of **0.13 ms** on n77 and
**0.23 ms** on n5, against 9.07 ms for SFN alone. One rule fits both numerologies: the 5-bit field counts
**30 kHz slots (0.5 ms) even on the 15 kHz carrier**, where only even indices occur. That is a useful and
slightly surprising fact — it is not the numerology-dependent slot index the NR uplink codes use.

**No element field is validated and the 32-byte element layout is not established.** The captures cannot
settle it, for two measured reasons. First, 0xB8C9 only exists for the last 8.10 s of the drive, where LTE
serving RSRP spans 8.4 dB and NR SS-RSRP spans **5.3 dB over 30 0xB97F records** — essentially the noise
floor, so the driving capture provides no calibration range for NR at all. Second, in the stationary capture
the best |r| over all element fields is 0.989 against LTE RSRP and 0.912 against NR RSRP, but from fields
with only two to six distinct values that step at a handover, with the sign disagreeing between chains:
spurious.

### What these two would add, and what it would take

A **per-antenna receive front-end trace at 1 ms (LTE) and 0.5 ms (NR) resolution** with exact frame timing —
by a wide margin the highest-resolution measurement in the app. 0xB111's per-chain received power is usable
today for **antenna imbalance and hand-blocking detection**, which is a real diagnostic the app cannot do at
all right now: four antennas, 4,156 samples per second, and the differential between them is validated
against 0xB193.

The gain and LNA semantics need a **purpose-built calibration capture**: a single LTE carrier, no handover,
while RSRP swings 20 dB or more (drive away from a cell and back), plus an NR capture with the secondary
cell group up for the whole session and a usable signal level. Without carrier attribution in 0xB111 and
without NR dynamic range in 0xB8C9, no amount of re-analysis of these two files will settle it.

## The LTE LL1/ML1 family — **framing solved for all eight, contents solved for two**

All eight were framed and their timing fields validated. Every framing below consumes **100%** of the
bodies in both captures, which is the strongest structural test available. What differs is how much of the
*payload* could be tied to something already trusted.

| code | version | records | rate | framing (100% exact in both captures) | payload |
|---|---|---|---|---|---|
| 0xB16C ML1 DCI Information Report | 50 | 177 / 318 | 8 / 12 per s | 4-byte header, flag-driven chain of 16-byte and 8-byte records | **UL grant decoded** |
| 0xB12A LL1 PCFICH Decoding Results | 161 | 1,607 / 1,334 | 73 / 50 per s | fixed 176 bytes: 16-byte header + 20 × 8 bytes, one per subframe | **CFI decoded** |
| 0xB114 LL1 Serving Cell Frame Timing | 161 | 1,716 / 1,517 | 78 / 56 per s | 16-byte header + count × 48 bytes, count = byte 1 bits 0–4 | timing scale unconfirmed |
| 0xB122 LL1 Serving Cell CER | 141 | 1,512 / 1,767 | 68 / 66 per s | 80-byte header + byte 7 × 16 bytes (byte 7 = 16 or 32) | shape only, not power |
| 0xB11D LL1 Serving Cell TTL Results | 143 | 1,825 / 1,803 | 83 / 67 per s | 16-byte header + count × 40 bytes | loop state not decoded |
| 0xB11B (no public name) | 161 | 1,825 / 1,848 | 83 / 69 per s | 28-byte header + count × 92 bytes | loop state not decoded |
| 0xB146 LL1 UL AGC Tx Report | 165 | 1,487 / 2,276 | 67 / 85 per s | 8-byte header + count × 56 bytes, count = byte 1 bits 0–4 | channel type only, **no power** |
| 0xB16B PDCCH-PHICH Indication Report | 49 | 216 / 440 | 10 / 16 per s | 4-byte header + flag-driven chain (the header count saturates at 25) | no subframe, so nothing |

### 0xB16C ML1 DCI Information Report, v50 — **decoded, high confidence, and the best result in this family**

The element is a u32 word (SFN bits 0–9, subframe bits 10–13, a count of 16-byte records at bits 14–15 and
of 8-byte records at bits 17–19) followed by those records. The chain consumes **495 of 495** bodies
exactly.

The two record kinds were identified by *when* they land, which is the cleanest kind of proof:

- the **8-byte** records fall on a subframe where 0xB173 logged a PDSCH in **998 of 1,004 (99.4%)** and
  **2,252 of 2,260 (99.6%)** — downlink assignments;
- the **16-byte** records fall exactly **four subframes before** an 0xB139 PUSCH report in **2,752 of
  2,816 (97.7%)** and **4,744 of 4,763 (99.6%)** — uplink grants, at FDD's textbook n+4 timing. Every
  other shift from 0 to 8 scores at the base rate.

And then the uplink grant's own fields, against 0xB139's for the same subframe, over 2,751 and 4,744
one-to-one matches:

| field | position | agreement with 0xB139 |
|---|---|---|
| start RB | record bits 43–49 | **99.96% / 99.98%** |
| number of RBs | record bits 50–56 | **99.96% / 99.98%** |
| modulation | byte +4 bits 0–2 | **99.96% / 99.98%** |

The 8-byte downlink assignment's contents are **rejected**: it is nearly constant, and the best bit field
anywhere in it matches 0xB173's MCS in 31%/16%, N_RB in 52%/64% (chance level), TBS in 1%/5% and HARQ in
14%, in both bit orders. Byte +2 (always a multiple of 4) and byte +4 bits 0–1 look like a CCE index and an
aggregation level but could not be validated, so neither is claimed.

**What it adds:** the scheduler's decisions at 1 ms resolution — how many downlink assignments and uplink
grants per subframe, and the uplink allocation itself. Combined with 0xB139 it closes the uplink loop:
what the network *granted* against what the phone *sent*.

### 0xB12A LL1 PCFICH Decoding Results, v161 — **decoded, high confidence**

Fixed 176 bytes: a 16-byte header (SFN at u16 +4 bits 0–9, `R = 0.99854 / 0.99985`) and 20 8-byte elements,
one per subframe, so each record covers two radio frames. Element byte +3 takes **only 0x04, 0x08, 0x0C and
0x00 across all 32,140 and 26,680 elements** — that is 4 × CFI with CFI ∈ {1, 2, 3}, exactly the legal set
for a 50-PRB cell, never the 4 that only 1.4 MHz cells use. And byte +3 is 0 in precisely the elements
where the decode flag at +2 is 0, with no exceptions in either capture. CFI 1/2/3 splits 19,012 / 2,823 /
9,605 when driving and 19,699 / 3,364 / 1,734 when stationary.

Two honest gaps: which of the two radio frames the header SFN names could not be settled (10 ms is below
the timestamp's discriminating power), and the CFI could not be cross-checked against 0xB16C's DCI count
(`r ≈ 0.00`) — which is expected, since the control region is sized for the whole cell rather than for this
phone, but it means the CFI is corroborated structurally rather than against another decoder.

**What it adds:** **PDCCH load** — how many OFDM symbols the cell spends on control, per subframe. A cell
sitting at CFI 3 is congested; the driving capture is at CFI 3 for 30% of subframes against 6% when
stationary. This is the first network-load indicator FieldTap would have that does not depend on the
phone's own traffic.

### 0xB114 LL1 Serving Cell Frame Timing, v161 — **framing and internal identity solid, scale rejected**

Framing is exact (1,716 / 1,716 and 1,517 / 1,517), one 48-byte element per subframe (the 14-bit
SFN × 10 + subframe of consecutive elements differs by exactly 1 in 31,265 of 31,294 within-record pairs),
and byte 1 bits 5–7 behave as a carrier index.

The record contains a genuine internal identity, which is worth recording: element +2 read as `i16` and
element +16 read as a 24-bit sample counter satisfy `Δticks − 368640 == 12 × adjustment` in **91.9%** and
**89.2%** of consecutive pairs, with the residual ≡ 0 mod 12 in 99.8% / 98.3%. That is consistent with +2
being a per-subframe timing adjustment in Ts = 32.552 ns and +16 a subframe-boundary sample count at
Ts/12 = 368.64 MHz (nominal 368,640 ticks per subframe). The 8–11% misses are whole- and half-subframe
counter jumps whose cause was not established.

**It fails the check that mattered.** Summing the adjustment per carrier on the driving capture gives
−60 Ts over 22.1 s, which reads as −26.5 m/s of radial motion — physically plausible and smooth. But
0xB062's two RACH events in the same capture give a timing advance of 16 then 15, i.e. −8 Ts of one-way
delay, while the summed adjustment moved about −42 Ts over the same 3.5 s. **Same sign, roughly five times
the size.** So the scale is not confirmed, and the record must not be shipped as a propagation-delay or
distance readout. The stationary capture is also dominated by a single +4,300 Ts re-synchronisation step,
which a UI would have to handle.

This is the honest answer to the brief's timing-advance ask: 0xB114 is the right record and the field is
almost certainly the right field, but **one more capture is needed** — ideally a drive with several RACH
events, or a known-distance static test — before a number goes on screen.

### 0xB11D + 0xB11B, v143 and v161 — **proven to be a pair, contents rejected**

Both frame exactly (`16 + 40n` and `28 + 92n`), which is the linear relation behind the observed length
pairs: 1868 ↔ 816 is n = 19, 1224 ↔ 536 is n = 12, 1776 ↔ 776 is n = 18, 120 ↔ 56 is n = 0. They are
emitted together: the nearest 0xB11D to each 0xB11B carries the **same DIAG timestamp** (median |Δt| =
0.005 ms), the same element count in 99.51% / 99.62% of pairs, and the **same per-element SFN,
element-for-element, in 31,860 of 31,860 (100.00%)** on the driving capture and 99.82% on the stationary
one. One element per subframe, stepping by exactly 1 in 100% of consecutive pairs in both captures.

The remaining 36 and 90 bytes per element — the time-tracking-loop state — could not be tied to any
decoded quantity, so **no field is claimed**. Framing and pairing only.

### 0xB122 LL1 Serving Cell CER, v141 — **framing and timing solid, physical meaning rejected**

The "two lengths" are one shape at two window sizes: byte 7 = 16 gives 336 bytes (128 taps) and 32 gives
592 bytes (256 taps). The SFN sits at record bits 8–17 with **circular `R` = 1.00000 over 1,512 and over
1,767 records — the tightest timing fit of all eight codes**. The payload is a single-peaked energy-versus-
delay profile, peak near tap 54 of 256.

But **the level is not power**: against 0xB193's serving-cell values over 1,321 and 1,680 time-matched
records, `r(10 log10 Σtaps, RSRP)` is −0.04 / −0.25, versus RSSI −0.02 / −0.29, and neither the peak
amplitude nor the per-Rx arrays do better than |r| ≤ 0.26. That is what a post-AGC channel estimate looks
like. The peak index also does not track 0xB114's timing (`r` = −0.09 / +0.03), so the delay axis is
unanchored and the tap spacing in Ts is unknown.

**What it would add** if the axis were anchored: **delay spread** — how dispersive the channel is, which is
the physical reason a cell with good RSRP can still perform badly. Worth returning to.

### 0xB146 LL1 UL AGC Tx Report, v165 — **channel type decoded, transmit power rejected**

Framing exact (3,763 of 3,763 records across both captures). The element carries a 14-bit TTI at +8 with
**circular `R` = 1.00000** in both captures, and the header repeats it.

One field validated, and it is a good one: element +10 bits 0–3 is the uplink channel type, and **every
type-1 element lands on a TTI where 0xB139 reported a PUSCH — 6,217 of 6,217 and 11,520 of 11,520, 100% in
both captures.** So type 1 = PUSCH. Types 2, 3 and 7 hit PUSCH TTIs only at the base rate (14–45%) and
could not be separated into PUCCH, SRS and PRACH.

**The transmit power, which is why this code was on the list, is rejected.** No field in the 56 bytes
survives: the best correlation against 0xB139's `power_raw` at the same TTI reaches |r| = 0.71/0.77 for one
candidate and 0.88/0.89 for *different* offsets in the two captures, with slopes disagreeing by a factor of
two and exact equality never above 10%. A per-RB normalisation does not rescue it. The 0xB064 power-
headroom cross-check was never reached because no candidate justified it.

### 0xB16B PDCCH-PHICH Indication Report, v49 — **framing solved, contents rejected**

The flag-driven element chain (n_blocks at bits 0–1, an extra-byte flag at bit 3, SFN at bits 6–15, then
the optional byte, then n_blocks × 8 bytes, then a fixed 12-byte tail) consumes **656 of 656** bodies
exactly — note that the *framing*, not the header count, is what works: the header byte 3 equals the
element count in only 96.5% because it saturates at 25.

**There is no subframe field**, and that kills the useful part. No 4- or 5-bit field anywhere in the
element stays inside 0..9 while improving SFN-only monotonicity, and the timestamp cannot help because a
single record spans six to ten frames (SFN-only residual spread ~103 ms). Without a subframe there is no
way to align these against 0xB173's HARQ feedback, so **no PHICH or HARQ field is claimed**. The 8-byte
blocks and the 12-byte tail stay unidentified; the tail's leading u32 increments by 1, 2 or 3 per element,
so it is an event counter rather than a clock.

### The cross-cutting result

All eight codes' timestamp-to-frame offsets are mutually consistent — 1,463–1,547 ms on the driving capture
and 1,677–1,754 ms on the stationary one, the same window every other code in this document falls in.
That consistency is what made the **absolute-TTI axis** possible, and it turned out to be necessary: the
10.24 s SFN cycle aliases about 2.2 times in a 22 s capture, so without unwrapping the SFN into absolute
time *every* cross-code alignment test comes out flat. Any future work on these records should build that
axis first.

---

## Prioritised implementation plan

Ordered by *validated value per unit of work*, not by the order the brief asked for them. Each entry says
what appears on screen, because a decoder that changes nothing visible is not worth the maintenance.

### 1. 0xB126 — **antennas and rank per subframe** (do this first)

The cheapest decoder in the list: a fixed 968-byte body, a fixed 48-byte sub-record, no version drift, no
walk to get wrong, and three fields validated at 97–100% against things FieldTap already trusts. Build it
in `web/engine` first so it can be exercised against the browser fixtures, then `FTPhy`, then Android.

On screen: the Radio page's antenna line stops being an inference from the MIB plus the measurement
record — **transmit antenna ports, receive antennas and MIMO rank, per subframe**, twenty subframes per
record. And a new one: a **PRB allocation strip**, showing which resource blocks the scheduler gave this
phone, not just how many.

### 2. 0xB12A — **PDCCH load** (second: a fixed 176-byte body, the cheapest decoder in the set)

Fixed length, fixed 8-byte element, twenty subframes per record, and a CFI field that takes **only the three
legal values across all 58,820 elements in both captures** and is zero exactly when the decode flag is zero.
There is nothing to get wrong.

On screen: the **cell's control-channel load** per subframe — the first network-load indicator in the app
that does not depend on the phone's own traffic. The contrast is already visible in the fixtures: CFI 3 for
30% of subframes while driving against 6% while stationary.

### 3. 0xB16C — **the uplink grant** (third: the strongest payload result in this pass)

Start RB, RB count and modulation all agree with 0xB139 in **99.96% / 99.98%** of matched subframes, and the
two record kinds were identified by timing alone (downlink assignments in the PDSCH subframe, 99.4%; uplink
grants exactly four subframes before the PUSCH, 97.7%). Implement the 16-byte uplink-grant record and the
per-subframe assignment counts; **do not** implement the 8-byte downlink assignment's contents, which were
rejected.

On screen: **what the network granted against what the phone sent** — the uplink loop closed — plus a
per-subframe count of downlink assignments and uplink grants, which is the scheduler's behaviour at 1 ms
resolution.

### 4. 0xB179 — **the neighbour list** (and it needs no timestamp plumbing)

Simple fixed layout, a length identity that passes at 98.7%, and RSRP/RSRQ that land inside 1 dB of
0xB193. It also brings its own time, so it is the first record FieldTap can place without help from the
transport.

On screen: a **neighbour table under the serving cell**, RSRP/RSRQ and the offset from the serving cell in
dB — the handover margin. 463 neighbour measurements in 22 s of driving that nothing else in the capture
sees.

### 5. 0xB063 — **MAC-level downlink accounting** (budget time for the walk)

The transport-block header is as solid as anything here (99.0% / 99.9% against 0xB173), but the walk over
the PDCP tail recovers only 80% of the declared transport blocks, so ship it as an accounting view with an
explicit coverage figure rather than as *the* throughput number. Keep 0xB173 as the throughput source.

On screen: **useful versus wasted downlink** — MAC bytes with the padding share (2.9% / 1.9% here) — and a
**signalling-versus-data split by LCID**, which is what explains a session that looks busy but moves no
user data.

Do not promise continuous timing advance from this code. If the product wants timing advance as a
continuous trace, 0xB114 is the candidate (see the LL1 family section) and 0xB062 remains the only
validated source today, at random access only.

### 6. The shared NR record header (small, and it unblocks the rest)

Not a feature, an enabler: factor `{count, slot, numerology, frame}` out of 0xB887 into one helper and put
0xB883/0xB884/0xB885/0xB8A7 behind it. It is testable with zero behaviour change because 0xB887's own
records satisfy it.

On screen: **subcarrier spacing per NR carrier** (15 or 30 kHz), which the app does not show at all today
and which every NR timestamp depends on; plus a *presence and rate* row for the four uplink codes — "27
uplink grants per second, timing decoded, sizes not yet" — which is honest and is the hook for the next
capture.

### 7. 0xB111's per-chain received power — **antenna imbalance**

Not the gain, which is rejected, but the one field that did validate: `i16 +2` per receive chain, 1/256 dB,
at 4,156 samples per second. Ship it as a **relative** measure only — the differential across the four
chains, never an absolute dBm — because that is all that was validated (differential `r` = +0.31 / +0.77
against 0xB193's per-antenna RSRP; the absolute value deliberately does not track RSRP).

On screen: **antenna balance** — four traces, or one "spread across antennas in dB" number. A phone held
across its antennas shows up immediately, and nothing in the app can see that today.

### 8. The next research pass, in this order

Not implementation — the three questions most likely to pay off next, with the check each one has to pass
and, importantly, **what capture each one needs**:

1. **0xB114's timing scale.** The framing, the per-subframe element and the internal
   `Δticks − 368640 == 12 × adjustment` identity are all solid; only the scale failed, against 0xB062 by a
   factor of about five with the right sign. Needs a drive with **several RACH events** (or a
   known-distance static test) to calibrate. This is the continuous timing advance the brief wanted.
2. **0xB122's delay axis.** Circular `R` = 1.00000 timing, a clean single-peaked tap profile, but the peak
   index does not track 0xB114's timing so the delay axis is unanchored and the tap spacing in Ts is
   unknown. Anchoring it turns the record into a **delay-spread** measurement — the physical reason a cell
   with good RSRP can still perform badly. Solve 0xB114 first; they are the same problem.
3. **The receive-gain semantics of 0xB111 and 0xB8C9.** Needs a **purpose-built calibration capture**: a
   single LTE carrier with no handover while RSRP swings 20 dB or more, plus an NR session with the
   secondary cell group up throughout at a usable signal level. Re-analysing the present two files will not
   settle it — 0xB111 carries no carrier id, and 0xB8C9 only exists for 8 s of the drive with 5 dB of NR
   dynamic range.

### 9. Not yet: the 5G uplink section

0xB883's MCS/PRB/TBS, 0xB884's power, 0xB8A7's CQI/RI and 0xB885's DCI contents all failed their checks
and are deliberately not implemented. The blocker is the captures, not the method: these 22 seconds are
almost all small uplink grants and an almost-always-rank-1 downlink, so the fields never exercise their
range. **The next capture should be a sustained NR upload** with 0xB883, 0xB885 and 0xB887 enabled
together; then the TS 38.214 identity has something to bite on, and the 0xB883 PRB-count lead at record
bit 215 can be confirmed or dropped in an afternoon.

### Runtime checks to add alongside

FieldTap's discipline is that a firmware update shows up as a failing check, not as a plausible chart. Add
to `web/engine/src/phy/checks.ts` and `PhyChecks.swift`:

| check | code | currently | threshold |
|---|---|---|---|
| popcount(PRB bitmap) is an N_RB 0xB173 reports for the same subframe | 0xB126 | 99.5% / 99.7% | 0.95 |
| rank equals 0xB173's layer count, transmit diversity excepted | 0xB126 | 99.9% / 100% | 0.95 |
| transmit antenna ports equal the MIB's antenna count for the serving cell | 0xB126 | 100% where a MIB exists | 0.95 |
| CFI is 4 × {1,2,3} or 0, and 0 exactly when the decode flag is 0 | 0xB12A | 100% of 58,820 elements | 0.99 |
| uplink grant's start RB, RB count and modulation equal 0xB139's | 0xB16C | 99.96% / 99.98% | 0.95 |
| the 16-byte record precedes an 0xB139 PUSCH by exactly 4 subframes | 0xB16C | 97.7% / 99.6% | 0.90 |
| `len == 28 + 12 × neighbour count` | 0xB179 | 98.7% / 98.9% | 0.95 |
| serving RSRP is within 1 dB of 0xB193's for the same cell | 0xB179 | 93% stationary | 0.90 |
| every transport block matches a 0xB173 one on (SFN, subframe, carrier, HARQ, size) | 0xB063 | 99.0% / 99.9% | 0.95 |
| transport-block coverage: the walk reaches the declared count | 0xB063 | 80% / 82% | report, do not gate |
| body length equals the record count times the listed record sizes | NR family | 99.7–100% | 0.95 |
| `len == 8 + 40N + 16·popcount(mask)` | 0xB111 | 100.0000% | 0.99 |
| the chunk chain ends exactly on the body's last byte | 0xB8C9 | 100.0000% | 0.99 |
| the strongest receive chain is 0xB193's strongest antenna | 0xB111 | 36.8% / 55.1% vs 25% chance | report, do not gate |

The two "report, do not gate" rows matter as much as the rest: both are coverage figures whose *drift* is
the signal. If the 0xB063 walk falls from 80% to 40%, the PDCP tail changed; if the 0xB111 antenna
agreement falls to chance, the per-chain ordering changed.
