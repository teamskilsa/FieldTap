# PHY and journey (src/phy, src/journey)

Owner: phy-journey agent. The TypeScript port of FTPhy and FTJourney (ios/FieldTapKit). It ports the numbers of the
validated reference extractor (`Fixtures/local/reference-phy/kpis.py`), not its code, and applies rules J1-J12 with
the v1 amendments (ios/Contract/CONTRACT.md).

## Entry points

```ts
extractPhy(records, timeBase, secure): PhyCapture              // src/phy/extract.ts
buildJourney(flow, phySummary, facts, series?): Journey         // src/journey/build.ts
stepAnnotations(flow, journey): Map<stepEvent, string>          // the ladder's Move-row subtitles
attributeCarriers(series, journey): PhySeries[]                 // sets PhySample.cell
```

**For the integrator (analyze.ts):** pass `phy.series` as `buildJourney`'s fourth argument. That adds the Integrity
tiles (`lteDlPeak`, `nrDlPeak`). Then publish `attributeCarriers(phy.series, journey)` as `analysis.phy`, so every
sample that carries only a carrier index names its cell.

## Parity targets and what differs from the original goldens

| Target | Status |
| --- | --- |
| `contract/phy-golden-v1.json` (48 KPIs) | Equal: counts exact; min, max and mean within 0.01; first and last 3 samples within 1 ms. Tested against the reference's own TBS table (`reference-phy/lte-tbs-reference.json`, a local oracle that never enters web/engine). |
| `contract/phy-summary-v1.json` | Equal. RACH distance uses TA x 78.12 m (J10, Spectrum.kt). The reference uses 78.125 m, so TA 19 gives 1484.3 m instead of 1484.4 m. |
| `contract/journey-expected.json` | Equal under the v1 amendments (tests/journey_expected.ts). The fixture is compared rather than regenerated. |

- **The v1 PHY goldens** were already regenerated under the critique's rule by the iOS workflow's
  `ios/FieldTapKit/Tests/FTPhyTests/TestData/tools/regen_phy_v1.py`, from the reference output `kpis.json`.
  - The three bin KPIs (`lte_dl_bler`, `lte_dl_phy_throughput`, `lte_ul_phy_throughput`) are keyed by (whole UTC
    second, carrier index) at second + 0.5 s, not by the reference's hard-coded PCell table. That gives 35/35/27
    bins, where the original had 37/37/29.
  - `nrDlActivity.earfcn` is null instead of the hard-coded NR cell; the journey attributes it.
  - The RACH events gain `preambleTargetDbm`.
  - Rerunning that script reproduces both files byte for byte (md5 `7d7048da…` and `95f26f30…`). The other 45 KPIs
    equal `phy-golden.json`, and the script asserts this.
- **journey-expected.json** predates the amendments, so the comparator applies them:
  - Markers are compared in the contract order: a stable sort by tMs, then MarkerKind's order in src/types.ts.
  - `procedures` and `proceduresAnswered` are checked against the flow. src/types.ts has no such tiles.
  - The journey may add only `serviceRequest`, `registration` and the PHY peak tiles.
  - Ids are tested for uniqueness separately.

## The second decoder pass (docs/research/iphone-named-log-codes.md, iphone-unknown-log-codes.md)

Seven more records, each ported with the same discipline: strict version dispatch, a runtime self-check with a
stated expectation, an entry in the availability catalogue, and a test against **both** captures
(`tests/phy_records_test.ts`: capture2 = driving, iphone-recovered = stationary).

| code | what it gives | the identity its check holds to | measured (driving / stationary) |
| --- | --- | --- | --- |
| 0xB126 v163 | transmit antenna ports, receive antennas, rank and the PRB allocation bitmap, 20 subframes per record | popcount(bitmap) is an N_RB 0xB173 reports for the same subframe; rank equals 0xB173's layers (transmit diversity excepted); the ports equal the MIB's count for the serving cell | 99.8% / 99.9%, 100% / 100%, 98.9% / 100% |
| 0xB12A v161 | the cell's PDCCH load (CFI) | the field is 4 x CFI with CFI in {1,2,3}, and zero exactly when the decode flag is zero | 32,140 / 26,680 elements, no exception |
| 0xB16C v50 | the uplink grant (start RB, RB count, modulation) and the per-subframe assignment count | the grant equals 0xB139's PUSCH report four subframes later | 2,774 / 4,757 matched grants, all exact |
| 0xB179 v56 | the intra-frequency neighbour list and the handover margin | `len == 28 + 12n`, and the serving RSRP is 0xB193's own for the same cell | 380/385 and 369/373; 96% / 99% within 1 dB |
| 0xB063 v50 | MAC downlink accounting (bytes, padding, the per-LCID split) | every transport block is a 0xB173 one on (SFN, subframe, carrier, HARQ, size); coverage is reported, not gated | 98.9% / 99.8%; coverage 79.5% / 81.7% |
| 0x184C v0x11 | per-chain front-end transmit power, its limit and the PA gain state | the block walk consumes the body exactly; the block's subframe field stays inside 0..9 | 2,391/2,393 and 4,464/4,465 |
| 0x1D0B v7 | the two modem clocks, as a trace-gap meter | the record sequence number steps by exactly 1 | 1,902/1,913 and 2,237/2,237 |

Two pieces of plumbing came with them:

- **`src/phy/ttiAxis.ts`, the absolute-TTI axis.** SFN x 10 + subframe cycles every 10.24 s and a capture is twice
  that, so without unwrapping it every cross-record alignment comes out flat. The modem's logging latency is
  measured from the records that carry both a timestamp and a subframe (0xB173, 0xB139) as a circular mean, and the
  concentration of that sample (0.9995 on both captures) is itself a self-check.
- **0xB179 has no DIAG timestamp at all** - every one of its records arrives stamped zero. Its position in the
  trace gives a rough time and its own in-record TTI fixes the rest, so it is the first record FieldTap places
  without help from the transport, and it is not counted as "unstamped".

What was deliberately **not** implemented, because validation rejected it: the 5G uplink payloads
(0xB883/0xB884/0xB885/0xB8A7 MCS, PRB, TBS, power and CQI - they need a capture with a sustained 5G upload),
0xB16C's 8-byte downlink assignment contents, 0xB111's and 0xB8C9's receive gain, 0xB114's timing scale (about five
times 0xB062's over the same seconds) and 0xB146's transmit power. Each has an availability entry saying so.

## Decisions (with the evidence the tests hold)

- **Strict versions.** The decoders accept only B0C1 v2, B0C2 v3, B193 v1/0x19 v66, B173 v50, B139 v162, B14E/B14D
  v164, B064 v1/0x08 v7, B062 v1/0x06 v50, B97F 3.0, B887 3.13, B888 3.1, and, from the second pass, B126 v163,
  B12A v161, B16C v50, B179 v56, B063 v50 (0x32), 0x184C v0x11 and 0x1D0B v7.
  - Any other version is counted in `versionMisses` ('0xB173 v48').
  - It also gets a `version-0xB173` availability entry reading "Not decodable (version 48)".
  - Both real captures have 0 misses, 0 malformed and 0 unstamped PHY records.
- **0xB887 field widths.** Slot is 5 bits, TBS 18 bits (bit 23 is a flag), nRB 8 bits and layers 2 bits, where
  the reference had 4, 21, 7 and 1.
  - The first capture decodes identically (497 of 497 slots).
  - On the moving capture's n77 carrier (217 PRB, up to 4 layers), 828 of 828 new transmissions match TS 38.214. The
    old widths match 0.
  - The NR TBS check tries N'RE 96-156. With only 120-150, the moving capture reaches 744 of 828.
  - It reports a negative control (MCS + 1 also fits: 138 of 472 on the first capture).
- **N_RB per EARFCN** is inferred by snapping the median of RSRQ - RSRP + RSSI to 10log10 of {6, 15, 25, 50, 75,
  100}. On the first capture this gives 650: 50, 975: 25, 5110: 50 and 67086: 50, with residual sd <= 0.089 dB on
  every Rx.
- **TxD.** 4 layers with one TB is tagged `TxD` (transmit diversity, one layer of data), and 3 layers is tagged
  `unverified`. `lte_ul_phy_throughput` is badged and titled "UL scheduled", since it includes retransmissions.
- **TBS tables.**
  - NR (TS 38.214 tables 5.1.3.1-1/-2/-3 and 5.1.3.2-1, and the formula) is typed from the specification. It is
    tested on hand-worked cases, and it gives 472 of 472 on the first capture and 828 of 828 on the moving one.
  - The LTE MCS tables are typed from TS 36.213 and equal the reference's.
  - The 34 x 110 LTE size table is **not generated yet**, because no copy of TS 36.213 was available offline and
    srsRAN's AGPL header is not a source. `src/phy/lteTbsTable.ts` stays empty until
    `deno run -A tools/gen_lte_tbs.ts 36213-xxx.docx > src/phy/lteTbsTable.ts` runs.
  - Until then the browser build has no `lte_ul_mcs_derived` and no `b173TbsTable` / `b139TbsModulation` checks,
    and the `lteTbsTable` availability entry says why. The generator's checks accept the oracle table and reject a
    single wrong size.
- **Carrier attribution** goes through the journey's lanes: index 0 is the PCell of the moment, k is the SCell of
  index k, and NR DL goes to the PSCell up to its last NR PHY record.
  - Where no lane covers a sample, the nearest 0xB193 serving record on the same carrier within 500 ms decides. This
    covers the time before the first RRC message, just after a release, and the edges of an SCell window.
  - On the first capture all samples of the 31 carrier-indexed series are placed.
- **Plain data.** No undefined values anywhere, and text that quotes the flow (causes, APNs) is scrubbed by the
  golden masking rules, because markers and findings have no masked variant.
