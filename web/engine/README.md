# FieldTap web engine

The decoding engine behind **FieldTap Log Analyzer**: the owner of an iPhone sysdiagnose (taken with Apple's
Baseband logging profile) opens the `.tar.gz` in a browser and sees the modem's RRC/NAS call flow, the cell
journey and radio KPIs. **Everything runs in the visitor's browser, in a Web Worker. The file is never
uploaded, and nothing is stored.**

The UI is the Lovable project `f36314b3-6255-4a3b-bd6f-67532b2fdddd`. It depends only on `src/types.ts` (copied
byte for byte to its `src/lib/analysis/types.ts`) and on `analyzeFile` from `src/index.ts` (its `src/engine/`).
`src/types.ts` goes to Lovable as it is, so every example in its comments is synthetic (no capture-derived PCI,
EARFCN, count or time).

## Test

```sh
cd web/engine
deno task check      # src/ against browser libs only (deno.browser.json: no Deno namespace); src/types.ts under the
                     # Lovable tsconfig's flags (deno.lovable.json); tests/ and tools/ with Deno
deno lint src tests tools
deno test -A         # 160 tests: 154 that need nothing, 6 gated on a real capture being present
deno test -A tests/pipeline_test.ts           # the three captures end to end, with time and memory
deno test -A tests/qdss_test.ts --filter resync
deno run  -A tools/build.ts                   # dist/: engine.js, worker.js, sample-analysis.json
deno run  -A tools/pipeline.ts ARCHIVE.tar.gz # one capture, one process (under /usr/bin/time -l for peak RSS)
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `FT_FIXTURES` | `../../ios/Fixtures/local` | The contract fixtures (git-ignored, capture-derived). Read in place, never copied. |
| `FT_ARCHIVES` | `~/Downloads` | The real sysdiagnose archives (`tools/fixtures.ts` `REAL` names them). Read in place. |
| `FT_REQUIRE_FIXTURES=1` | off | A missing fixture fails its test instead of skipping it. Use it on the fixture machine. |

The fixture-gated tests run whenever their files exist, and skip only when the files are absent. With every
capture present the result is **160 passed, 0 ignored**; with only the moving capture's extracted folder, as on
this Mac today, **154 passed, 0 failed, 6 ignored**.

**A capture counts as present in either form.** The `.tar.gz` downloads are ~400 MB each and get cleaned up when
the disk runs short — both were removed from `~/Downloads` while this engine was being written — so
`captureSource()` falls back to the extracted folder beside them, which `openCapture()` tars on the fly (plain
tar, streamed, never held in memory). The moving capture's end-to-end and deframer tests run from its folder.
Only the tests that assert archive-format facts (gzip, compressed size, AppleDouble entries skipped) still need
the real `.tar.gz`, and those are the 6 ignored above. **Restore the two archives to `~/Downloads` to run the
first capture's golden-parity tests** — nothing else can stand in for them.

Nothing is gated on the profile-off capture any more: the 14-39-54 archive the task named was never on this Mac,
and the extracted folder that stood in for it has since been deleted too, so `tests/support.ts`
`loggingOffFiles()` invents that shape instead (an ambtool log saying logging is off, one unrelated MDM stub, no
trace directory). It runs everywhere.

Tools (Deno, not part of the engine):

- `deno run -A tools/golden.ts A.json B.json [--tolerance 0.0015] [--ignore path]`: the contract comparator. It is
  `ios/Contract/tools/json_equal.py` rule for rule. `source.file` is ignored by default. It uses `tools/json.ts`,
  which keeps the goldens' 17-digit `timestampRaw` values exact as bigint (JSON.parse would round them).
- `deno run -A tools/md5.ts FILE...`: MD5 for parity checks. `Md5` is incremental: hash a rebuilt qmdl while
  `writeQmdl` produces it, with no file written.
- `deno run -A tools/scan.ts ARCHIVE [--full]`: an archive's structure as counts only. It prints no path outside
  the trace directory.

## Rules

- `src/` is plain browser TypeScript: Web Streams, `DecompressionStream('gzip')`, `TextDecoder`, typed arrays.
  There is no Node/Deno API, networking, storage or `eval`. `deno task check` enforces the API side and
  `tests/policy_test.ts` scans for the rest.
- No capture-derived data inside `web/engine`, ever (the policy test checks for it). Fixtures stay in `$FT_FIXTURES`. Never commit, print or upload
  identifiers. Lovable only ever receives synthetic data.
- Parity is the contract. TS outputs must equal the golden JSON under `tools/golden.ts` (numbers within 0.0015,
  `source.file` ignored), and rebuilt qmdl md5s must equal the Python deframer's.
- Style: FieldTap's. Short comments that explain why; names that read like the Kotlin/Swift; small files; strict
  TypeScript.

## Layout and ownership

| Path | Owner | State |
| --- | --- | --- |
| `src/types.ts` | foundation (changes go through this README's contract list) | done |
| `src/archive/` (tar, stream, sysdiagnose, info, plist, profile) | foundation | done, tested on the real archives |
| `src/diag/` (hdlc, record, timebase, qmdl) | foundation | done, parity-tested |
| `src/qdss/` (deframer, units, formatter, packets) | **qdss agent** | done, md5-parity with the Python, plus the resync below |
| `src/signalling/` (flow, callflow, presentation, mask, ui) | **signalling agent** | done, byte-for-byte on all five goldens |
| `src/phy/`, `src/journey/` | **phy-journey agent** | done, parity with the v1 PHY and journey goldens |
| `src/analyze.ts`, `src/worker.ts`, `src/index.ts` | **integrator** | done (`src/mapping.ts` is gone: `signalling/ui.ts` replaced it) |
| `tests/`, `tools/` | shared; each agent adds its own `*_test.ts` | done: 160 tests, plus `tools/build.ts` and `tools/make-sample.ts` |

Everything is implemented. The signatures and parity targets each part was built to are kept below, as the
record of what "done" was measured against.

## Public API

`src/index.ts` is the only entry point the UI imports (shipped as `dist/engine.js`):

```ts
analyzeFile(file: File, onProgress: (p: ImportProgress) => void, signal?: AbortSignal,
            makeWorker?: () => Worker): Promise<CaptureAnalysis>
revealIdentifiers(): Promise<RevealedSignalling | null>   // only after the user confirms
forgetCapture(): void                                     // ends the kept worker
STAGE_ORDER: ImportStage[]                                // reading, extracting, deframing, decoding, radio
STAGE_LABELS: Record<ImportStage, string>
CONTRACT_VERSION                                          // re-exported, with every type of src/types.ts
```

`analyzeFile` starts a Web Worker, streams the `File` into it and resolves with a masked `CaptureAnalysis`. It
**always resolves** unless cancelled: a file that is not a sysdiagnose, a truncated copy or a capture taken with
logging off still gives a complete analysis whose `problems` say why (blocking ones first). It rejects only with
an `AbortError`. The worker stays alive after `done`, holding the call flow and nothing else, so
`revealIdentifiers()` can answer; `forgetCapture()` terminates it.

`src/worker.ts` speaks the Lovable mock worker's protocol, so either side can be swapped alone:

| in | out |
| --- | --- |
| `{type:'analyze', file: Blob \| ArrayBuffer, fileName, nowMs?}` | `{type:'progress', progress}` … then `{type:'done', analysis}` |
| `{type:'cancel'}` | `{type:'error', name:'AbortError', message}` |
| `{type:'reveal'}` | `{type:'revealed', signalling}` |
| `{type:'forget'}` | — |

> The success reply is `done`, not `result`: both files in the live Lovable project send and expect `done`, so
> the engine matches what is deployed rather than the integration brief.

For tests and tools there is a direct, worker-free entry:

```ts
// src/analyze.ts
analyzeArchive(stream: ReadableStream<Uint8Array>, onProgress, signal, options): Promise<CaptureAnalysis>
analyzeCapture(stream, onProgress, signal, options): Promise<{ analysis, reveal }>
// options: { fileName: string; totalBytes?: number; nowMs?: number; earlyStop?: boolean }
```

`fileName` gives the button-press time, `nowMs` is when the guide state is judged, and `earlyStop` (default on)
stops reading once the trace directory and `MCState/Shared` have both been passed.

## Pipeline stages

`analyze.ts` runs six stages, reporting `{stage, fraction, detail}` after each and checking `signal` between
them (it yields to the event loop every 8 chunks, so a `cancel` is seen mid-deframe). `timings` records the ms
each took.

| stage | what it does |
| --- | --- |
| `reading` | stream the `.tar.gz`, keep only the trace chunks, `info.txt`, the ambtool log and the profile stubs |
| `extracting` | archive facts: press time, trace window, profile state, guide state, problems |
| `deframing` | QDSS chunks → DIAG log records, one chunk at a time, each released once fed |
| `decoding` | records → time base (D1) → call flow → ladder, masked through `signalling/ui.ts` |
| `radio` | records → PHY series → journey → carrier attribution → findings and tiles |
| `done` | the assembled `CaptureAnalysis` |

Memory is bounded at every step: the tar is streamed, each chunk's bytes are dropped as soon as the deframer has
them, record bodies live in shared 1 MiB blocks that go when the analysis is built, and only the call flow (a few
hundred events, PDUs copied out) outlives the run for `revealIdentifiers`. If a decoder throws, its stage adds a
non-blocking `unsupportedTrace` problem and falls back to empty output, so one broken decoder cannot hide what
the others found.

### Capture facts

`archiveFacts` compares the archive's own name (the button press) and `info.txt` (what the phone held) with what
the tar actually carries, so the UI can say what was and was not captured:

- `traceWindow`: `filesOnPhone = filesKept + filesOverwritten + filesMissing`, and the window relative to the
  press (`afterPressStartS` / `afterPressEndS`, null when the press time is unknown);
- `profile` (judged **at the press**: was logging on for this capture?) and `guide` (judged **now**: what should
  the user do?), both from the `MCState/Shared` stub;
- `problems`: `notASysdiagnose`, `truncatedArchive`, `noBasebandTrace`, `loggingNotEnabled`, `profileMissing`,
  `profileExpired`, `profileExpiresSoon`, `profileInstalledAfterTrace`, `profileInstalledNoTrace`,
  `unsupportedTrace`, `traceGaps`.

## The two fixes found on the moving capture

Both are required, and both are documented in the Python reference's findings. They are the only rules in the
engine that go beyond the verified reference behaviour.

### 1. The deframer re-finds the unit phase (`src/qdss/deframer.ts`)

The reference settles one unit phase over the first 320,031 bytes and keeps it for the whole stream. That holds
for a trace whose chunks are all present, but the sysdiagnose collector had taken 3 of the moving capture's 133
segments out, and its phase slips **8 times**: 3 at the holes and 5 mid-chunk in `0x6222..0x6225`. With one phase
it recovers **18,667 of 85,361 records**. So layer 2 now also:

- **re-finds the phase on lost sync** — `RESYNC_RUN` (8) consecutive units failing the tag check means the phase
  slipped, not that one unit is damaged, so it re-runs `find_phase` over `RESYNC_WINDOW` (4,096) bytes from the
  first unit of the bad run. It waits for that window before deciding, which keeps the result split-invariant. If
  no better phase is in view it steps over the bad run instead, so a long damaged stretch always moves forward;
- **resets at chunk-sequence gaps** — `QdssDeframer.gap()`, called by `analyze.ts` between `endChunk()` and the
  next `feed()` wherever the chunk numbers (`0x000061BE.bin`) skip. The deframer never sees a file name, so the
  caller detects the hole.

At either kind of break the fragments in flight are closed for what they already hold (their leading bytes were
read before the slip) rather than discarded, which is worth about 125 records, and the lanes are unbound.

Measured on the moving capture, against the reference's offline per-segment run:

| | reference (offline, 9 segments) | engine (online resync) |
| --- | --- | --- |
| log records | 85,361 | 85,351 |
| distinct codes | 222 | **222** |
| `ts` plausible / zero / other | 81,155 / 4,126 / 80 | 81,145 / **4,126** / **80** |
| 0xB0C0 / B0C1 / B0C2 / B821 / B825 / B826 / B80C | 67 / 3 / 2 / 4 / 2 / 357 / 1 | **identical** |
| encrypted / 0x79 / QSR4 / events | 35,214 / 8,238 / 50,471 / 1,009 | **identical** |
| decoded messages | 102 | 100 |

Every code the signalling and PHY decoders read is recovered in full. The 10 remaining records are unstamped
filler in fragments cut short because detecting a slip online costs the 8 units it takes to notice, where the
offline run switched phase exactly; `fits.short` is 30 against the reference's 5 for the same reason.

**The first capture is untouched, by construction, not by tolerance:** it has *no* bad unit at all in 5,411,059
(`qdss-full-stats.json` has no `u_badtype` key) and no missing chunk, so neither trigger can fire. Its qmdl md5
is still `e53a167b…` and its `stats` still serialise byte for byte. The resync keys appear in `stats` only when a
resync actually happened, so that parity stays literal.

### 2. 0xB887 v3.13 needs wider bit fields (`src/phy/decoders/nr.ts`)

nRB is **8** bits, layers **2**, TBS **18** (bit 23 is a flag) and slot **5**. The moving capture's n77 carrier
proved it: the TBS self-check against TS 38.214 goes **0 of 828 → 828 of 828** on that capture, and stays **497
of 497** on the first one, which decodes identically either way. `nr_dl_prb` then reaches 217 (an 80 MHz n77
carrier at 30 kHz SCS) and `nr_dl_layers` 4, both of which the narrow fields could not represent.

### Module signatures and their parity targets

```ts
// src/qdss/deframer.ts: port of Fixtures/local/reference/qdss_deframe.py (verified rules only), plus the resync
class QdssDeframer { feed(bytes: Uint8Array): void; endChunk(): void; gap(): void; finish(): DeframeOutput }
interface DeframeOutput { records: LogRecord[]; secure: EncryptedCensus; stats: DeframeStats;
                          bytesPerAtid: Record<string, number>; index?: IndexRow[] }
```
Feed each chunk in name order, in any split, then call `endChunk()`, and `gap()` where the chunk numbers skip. Layer-1 frames align to each chunk's
offset 0, and the ATID state carries across chunks. Output order is the reference's effective-timestamp sort.
Targets:
- `writeQmdl(records)` md5 = qdss-first3 `8bee4165…` and qdss-attach4 `245d59fc…`;
- the full 130-chunk trace = `e53a167b…` (iphone-recovered.qmdl);
- `stats` equals the Python `stats.json` on `atid32_bytes, chunks, stats, fits, fragment_kinds, packets, log_records, distinct_codes, ts`.

`DeframeStats` uses the Python's snake_case keys verbatim, so it compares with `stats.json` directly. The chunks
the archive reader hands over are byte-identical to the fixtures' inputs (tested by md5).
Critique items that apply: `find_phase` scans `[p, min(len-16, p+320000))` in 16-byte steps over a 320,031-byte buffer, and no atid32 cache is kept.

```ts
// src/signalling/callflow.ts: CallFlow.kt at contract v1 (D1-D4)
readFlow(records: readonly LogRecord[], crcErrors = 0): Flow
// src/signalling/presentation.ts: CallFlowPresentation.kt
rows(flow, filter): LadderRow[]; lanes(flow); procedureGroups(flow); ladder(flow): Ladder
shortCell(cell); band(cell); downlinkMhz(cell); sinceStart(ms); duration(ms)
```
`Flow` (`signalling/flow.ts`) mirrors Kotlin field for field (null for absent, bigint stamps, PDU bytes), so the
golden dump is a direct serialisation. Targets: `callflow-golden.json`, `callflow-attach4.json`, both OnePlus
goldens, and `presentation-golden.json` (strings exact; Java `%.Nf` rounding). The masking rules the goldens use
are already in `signalling/mask.ts`.

```ts
// src/phy/extract.ts
extractPhy(records: readonly LogRecord[], timeBase: TimeBase, secure: EncryptedCensus): PhyCapture
// src/journey/build.ts: rules J1-J12 + v1 amendments
buildJourney(flow: Flow, phySummary: PhySummary, facts: CaptureFacts): Journey
stepAnnotations(flow, journey): Map<eventIndex, string>
```
Targets:
- `phy-golden-v1.json` / `phy-summary-v1.json`: bins keyed by (whole UTC second, carrier index), NR DL earfcn null;
  strict record versions (anything else goes to `versionMisses`).
- `journey-expected.json`: markers sorted stably by tMs then kind rank; ids unique, e.g. `handover-82`, `rach-2659.6`.

```ts
// src/analyze.ts (integrator): the pipeline the worker runs; `options.fileName` gives the press time
analyzeArchive(stream: ReadableStream<Uint8Array>, onProgress: (p: ImportProgress) => void,
               signal: AbortSignal | undefined, options: { fileName: string; totalBytes?: number; nowMs?: number; earlyStop?: boolean }): Promise<CaptureAnalysis>
```

### Foundation APIs the agents build on

- `diag/record.ts`: `LogRecord { code: number; timestampRaw: bigint; body: Uint8Array; more: number }`,
  `parseLogPacket`, `logPacketsOf` (bare and 0x98 containers), `encodeLogPacket` (the Python's
  `<BBHHHQ>` layout), `hexCode`.
  - **`timestampRaw` is a bigint**: the exact 64-bit value, as Kotlin's Long holds it. The goldens print it with
    17 digits, which is beyond 2^53, so a double would round it. D1, sorting and re-encoding need the exact bits,
    and only `modemMs()` turns it into a double. `LogRecord` never crosses into the UI types.
- `diag/timebase.ts`: `TimeBase` (rule D1: first plausible, >= 2005, stamp; else first non-zero), `modemMs`,
  `utcMs`, `sinceStartMs`, `durationMs`, `startUtcMs`, `unixStartS`. Tested against all 128 golden events
  (sinceStartMs within 0.0015) and the OnePlus goldens' negative duration (-99,494.492 ms).
- `diag/hdlc.ts` / `diag/qmdl.ts`: CRC-16/X-25, `hdlcEncode`, a split-invariant `Unframer`, `readQmdl` /
  `QmdlReader`, `writeQmdl`, `recordsPerCode`.
- `archive/sysdiagnose.ts`:
  - `readSysdiagnose(stream, {totalBytes, onProgress, signal, earlyStop})` returns `{parts, stats}`;
  - `archiveFacts(parts, fileName, nowMs)` returns the trigger, trace window, profile, guide and problems;
  - `SysdiagnoseCollector` builds the same parts from a dropped folder.

## The contract (`src/types.ts`)

- Plain data only (no bigint, Date or Map), so it structured-clones and JSON-serialises. The tests check this.
- Times are ms since the D1 time base, and UTC instants are ISO strings.
- `analyzeFile` always resolves unless cancelled. A file that is not a sysdiagnose, a truncated copy, or a capture
  with logging off still gives a complete `CaptureAnalysis`: its `problems` say why, and blocking problems come
  first. It rejects only with an `AbortError`.
- Identifiers: the engine delivers real values, plus the golden-masked form of every string masking would change.
  While identifiers are hidden, the UI shows `masked` / `summaryMasked` / `detailMasked` / `refusalMasked` and
  hides `pduHex`, `CellDetail.tac` and `CellDetail.cellIdentity`.
- `ProfileState.status` is judged at the button press (was logging on for this capture?). `GuideState` is judged
  when the file is analysed (what should the user do now?).
- D4: an NR cell with `pci === 0xFFFF` or `earfcn === 0xFFFFFFFF` is shown as "NR cell pending".

### The exact names the UI can rely on

`src/types.ts` exports these **56** names and no others. All 55 types are `export type` / `export interface`, so
they erase at compile time; `CONTRACT_VERSION` is the one runtime value. `src/index.ts` re-exports every one of
them (`export type * from './types.ts'`), plus `RevealedSignalling`, `STAGE_ORDER` and `STAGE_LABELS`, so the UI
imports only from the engine entry point. Anything not on this list is engine-internal and may change.

| group | names |
| --- | --- |
| root | `CaptureAnalysis`, `CONTRACT_VERSION` |
| import | `ImportProgress`, `ImportStage`, `ImportProblem`, `ImportProblemKind` |
| capture facts | `TraceWindow`, `ProfileState`, `ProfileStatus`, `GuideState`, `GuideStatus` |
| call flow | `Event`, `Field`, `Procedure`, `Step`, `Connection`, `ConnectionOutcome`, `Protection`, `CellDetail`, `Cell`, `Layer`, `Rat`, `Outcome`, `Move` |
| ladder | `Ladder`, `LadderRow`, `LaneKind`, `ProcedureGroup`, `FlowFilter` |
| journey | `Journey`, `JourneyState`, `JourneyStateName`, `JourneyCell`, `RegistrationSegment`, `RegistrationState`, `Marker`, `MarkerKind`, `Finding`, `FindingKind`, `Severity`, `EvidenceSource`, `Tile`, `TileGroup` |
| radio | `PhySeries`, `PhySample`, `PhyMetric`, `PhySection`, `PhyConfidence`, `PhySummary`, `PhyCheck`, `CarrierActivity`, `RachEvent` |
| decoder health | `Availability`, `AvailabilityStatus`, `DeframeStats`, `EncryptedCensus` |

`PhyMetric` is a closed union of the 48 series names (the mock's short names map to them in the table below);
`ImportStage` is `'reading' | 'extracting' | 'deframing' | 'decoding' | 'radio' | 'done'`.

Everything is plain structured-cloneable data: no `bigint`, `Date`, `Map` or class instance crosses the worker
boundary, and `tests/analyze_test.ts` asserts that of a real analysis.

### Contract changes relative to the first Lovable types (the UI to-do list)

Compared with the types the first Lovable build wrote (`src/lib/analysis/types.ts` at commit `4832cd5`, message
`umsg_01m34tjjh6exb9e7cpfgp790x1`, read with the Lovable MCP). Every Lovable name is kept (`JourneyStateName`,
`JourneyState`, `JourneyCell`, `Tile`, ...), as is its `?: T | undefined` style, which the Lovable tsconfig's
`exactOptionalPropertyTypes` needs. `src/index.ts` also exports `STAGE_ORDER` and `STAGE_LABELS` with the Lovable
values. The worker speaks the Lovable mock worker's messages (`analyze` / `cancel` in; `progress`, `done`, `error`
out), so either side can be swapped alone.

> The success reply is `done`, not `result`. The integration brief specified `{type:'result'}`, but both
> `src/engine/worker.ts` and `src/engine/index.ts` in the live Lovable project send and expect `done`
> (verified by reading them over the Lovable MCP). Renaming it here would have broken the shipped UI for no
> gain, so the engine matches what is deployed. `src/worker.ts` also adds `reveal` / `revealed` and `forget`,
> which the mock has no equivalent of.

**Breaking (the UI and mock must change):**

1. `problems: string[]` becomes `ImportProblem[]` (`{kind, message, blocking, date?, detail?}`). The kinds are
   `notASysdiagnose`, `truncatedArchive`, `noBasebandTrace`, `loggingNotEnabled`, `profileMissing`,
   `profileExpired`, `profileExpiresSoon`, `profileInstalledAfterTrace`, `profileInstalledNoTrace`,
   `unsupportedTrace` and `traceGaps`. Show one problem card per entry, with a fix-it link to the guide.
2. `traceWindow` becomes `TraceWindow | null`: null when the archive has no trace directory with an info.txt.
   - `afterPressStartS` and `afterPressEndS` become `number | null` (null when the press time is unknown).
   - New required fields: `filesOverwritten` (listed files older than the first kept one) and `filesMissing`
     (listed files newer than it that the archive lacks). `filesKept + filesOverwritten + filesMissing =
     filesOnPhone`: moving capture 130 + 891 + 3 = 1,024.
   - `afterPressEndS` is the dump time from the trace directory's ms timestamp. For the first capture it is
     46.844, so floor it for "0:46".
3. `PhySeries.metric: string` becomes `PhyMetric`: the 48 names of `phy-golden.json`. The mock's names map as
   follows:

   | mock | engine |
   | --- | --- |
   | `rsrp_rx` | `lte_rsrp_per_rx` (`perIndex`) |
   | `rsrp_filtered` | `lte_rsrp_filtered` |
   | `rsrq` | `lte_rsrq_filtered` |
   | `rssi` | `lte_rssi` |
   | `dl_mcs` | `lte_dl_mcs` |
   | `dl_prb` | `lte_dl_prb` |
   | `dl_bler` | `lte_dl_bler` |
   | `dl_tput` | `lte_dl_phy_throughput` |
   | `ul_prb` | `lte_ul_prb` |
   | `ul_mcs` | `lte_ul_mcs_derived` |
   | `ul_power` | `lte_pusch_tx_power_required` |
   | `ul_headroom` | `lte_power_headroom` |
   | `cqi` | `lte_cqi_wideband_cw0` (+ `_cw1`) |
   | `ri` | `lte_ri` |
   | `pmi` | `lte_pmi_wideband` |
   | `nr_ssrsrp` | `nr_ss_rsrp` |
   | `nr_mcs` | `nr_dl_mcs` |
   | `nr_layers` | `nr_dl_layers` |
   | `nr_bler` | `nr_dl_bler` |
   | `nr_tput` | `nr_dl_mac_throughput` (MAC, not PHY) |
   | `ca_tput` | no series: split `lte_dl_phy_throughput` by `sample.carrier >= 1` |
   | `rach_attempts` | no series: use `phySummary.rach` (TA, distance, preamble target power) |

   The engine also emits `lte_rsrq_per_rx`, `lte_rssi_per_rx`, `lte_neighbour_*`, `lte_dl_tbs`,
   `lte_dl_modulation`, `lte_dl_crc_ok`, `lte_dl_layers`, `lte_ul_tbs`, `lte_ul_modulation`, `lte_ul_code_rate`,
   `lte_ul_phy_throughput` (label it "UL scheduled"), `lte_csf_tx_mode`, `lte_mac_ul_grant`,
   `lte_timing_advance_rar`, `lte_tx_antennas_mib`, `lte_dl_bandwidth_prb`, `lte_band`,
   `lte_rx_antennas_measured`, `nr_ss_rsrq`, `nr_dl_prb`, `nr_dl_tbs`, `nr_dl_modulation` and `nr_dl_crc_ok`.
4. `Journey.registration: RegistrationSegment[]` is new and required (J5, the "not registered" overlay).
5. `Finding.kind: FindingKind` is new and required. Ids are unique: two handovers no longer share an id.
6. `ProfileState.status` gains `'expiringSoon'`.
7. `MarkerKind` gains `'redirect' | 'reestablishment' | 'cellChange'` (J7). Give them icons.
8. New required `CaptureAnalysis` fields:
   - `contract` (`CONTRACT_VERSION`);
   - `guide: GuideState` (`off | expired | expiringSoon | active | installedNoTrace | unknown`, `removalDate`,
     `daysLeft`, `needsAttention`);
   - `encrypted: EncryptedCensus`, `crcErrors`, `durationMs`;
   - `cellDetails: CellDetail[]`;
   - `ladder: Ladder`: rows per filter as the Android app builds them, with folded repeats, procedure banners and
     move rows, plus lanes and procedure groups with the formatted strings;
   - `phySummary: PhySummary` (SCell / NR DL activity, RACH, Tx antennas from MIB, Rx antennas per EARFCN);
   - `phyChecks: PhyCheck[]` (decoder health), `versionMisses`, and `timings` (ms per stage).

**Non-breaking (optional or new names):**

- New optional `CaptureAnalysis` fields: `deframe?: DeframeStats` and `startUtc?`.
- Optional fields on the existing types:

  | Type | New optional fields |
  | --- | --- |
  | `Field` | `masked` |
  | `Event` | `record`, `logCode` ('0xB0C0'), `summaryMasked`, `protection` ({headerType, headerName, sequence, mac}), `pduLength` |
  | `Procedure` | `detail`, `detailMasked`, `refusalMasked` |
  | `Step` | `annotation` (J7 subtitle for the ladder's Move row) |
  | `Connection` | `established` |
  | `JourneyState` | `openAtEnd`, `source` |
  | `JourneyCell` | `bandCandidates` (NR: [5, 26]), `dlMhz`, `addedMs`, `openAtEnd`, `source` (`rrc`/`phy`/`inferred`, where `phy` means "from PHY"), `phyLastMs` |
  | `Marker` | `endEvent`, `arrivalMs`, `from`, `to`, `durationMs`, `ta`, `distanceM`, `inferred` |
  | `Tile` | `event` |
  | `PhySample` | `earfcn`, `pci`, `cell`: carrier attribution, where the Journey maps a carrier index to a cell at tMs |
  | `PhySeries` | `code`, `version`, `badges` ('derived', 'medium confidence', 'before Pcmax') |
  | `Availability` | `codes` |
  | `ProfileState` | `identifier`, `displayName`, `observedAt` |

- New named types for the existing inline unions: `Layer`, `Rat`, `Outcome`, `Move`, `ConnectionOutcome`,
  `LaneKind`, `TileGroup`, `PhySection`, `PhyConfidence` and `AvailabilityStatus`.

**Added with the second decoder pass (0xB126, 0xB12A, 0xB16C, 0xB179, 0xB063, 0x184C, 0x1D0B).** All additive: the
48 v1 metrics and every existing field are unchanged, and a UI that ignores the new names keeps working.

- `PhyMetric` gains 16 names, in this order after the v1 48: `lte_pdsch_tx_antennas`, `lte_pdsch_rx_antennas`,
  `lte_dl_rank`, `lte_dl_prb_allocation`, `lte_pdcch_cfi`, `lte_dl_assignments`, `lte_ul_grant_prb`,
  `lte_ul_grant_start_rb`, `lte_neighbour_rsrp_intra`, `lte_neighbour_rsrq_intra`, `lte_neighbour_margin`,
  `lte_fed_tx_power`, `lte_fed_tx_limit`, `lte_pa_gain_state`, `lte_mac_dl_bytes` and `lte_mac_dl_padding`.
- `PhySample` gains `mask?: number[]`: a bitmap the record carries, low word first (0xB126's PRB allocation;
  `value` is its popcount).
- `PhySummary` gains six optional views, each absent when the capture has no such record: `measuredAntennas`
  (`AntennaConfig[]`, the antenna answer measured per serving cell), `intraFreqNeighbours` (`NeighbourCell[]`, with
  the handover margin), `macDl` (`MacDlAccounting`, with the coverage share it must be read with), `uplinkFrontEnd`
  (`FrontEndUplink`, transmit-limited and which chain), `pdcchLoad` (`PdcchLoad`) and `uplinkGrants`
  (`UplinkGrants`), plus `traceClock` (`TraceClock`, the measured holes in the trace).
- `MacDlChannel.kind` includes `'other'` for an LCID that is not a 3GPP downlink channel; it is never counted as
  user data.
- `Availability.status` `'available'` is now used: an entry a new decoder has answered stays on the page with what
  was validated and what was rejected (the UI groups those under a heading of its own).
- The `traceGaps` problem's `message` is rewritten from the modem's own 1024 Hz clock ("3 trace files are missing
  ...: 5.3 s of trace was never written, in 6 holes, the largest 2.2 s at 0:10.2") and its `detail` becomes
  "`N` files, `M` ms". A capture with no missing files but measurable holes now raises the same problem kind.
- `src/report/privacy.ts` is new and is not part of the analysis: it lists the location-bearing log codes (0x1476
  and the rest of the GNSS block, 0x1391 and 0x1544) and strips them from anything the app writes out.

## What the real archives showed

The shape the archive layer relies on, measured with `tools/scan.ts --full`. Both archives were read in place in
about 6 s each.

| | first capture (15-41-47) | moving capture (08-57-25) |
| --- | --- | --- |
| compressed / tar bytes | 408,450,455 / 929,382,400 | 424,644,471 / 915,179,520 |
| entries / AppleDouble (in qdss dir) | 4,671 / 1,741 (134) | 4,407 / 1,728 (134) |
| contiguous runs: qdss, MCState/Shared, rest of logs/Baseband | 1, 1, 1 | 1, 1, 1 |
| qdss ends / MCState ends / ambtool at (tar bytes) | 163.4 M / 271.9 M / 922.4 M | 163.1 M / 248.4 M / 906.5 M |
| early stop at | 272.7 MB (29 %) | 249.5 MB (27 %) |
| chunks kept (tar order: newest first) | 130: 0x6F..0xF0 | 130: 0x61BE..0x6242, missing 0x61D6, 0x620B, 0x621F |
| info.txt files | 241 (111 overwritten) | 1,024 (891 overwritten, 3 missing) |
| trace window after the press | +19 .. +46.844 s | -4 .. +18.506 s |
| profile | com.apple.basebandlogging, installed 2026-09-21T19:40:06Z, removed 2026-09-28T19:40:02Z (6.99995 days); active at both presses | same stub |

- **Early stop.** Reading stops once the trace directory and MCState/Shared have both been passed, and the dump
  time is not before the press. `ambtool_output.log` comes last and matters only when there is no trace, so a
  capture without a trace is read to the end.
- **Truncation.** A copy cut short after the needed parts is analysed whole, because early stop never reaches
  the damage. A tar that ends without its end-of-archive block is `truncatedArchive`: Deno's inflater does not
  always signal a cut-short gzip, and this check catches it.
- **Profile-off capture.** The task names `sysdiagnose_2026.09.21_14-39-54…tar.gz`, but no such file exists. Only
  the extracted folder `~/Downloads/sysdiagnose_2026.09.21_14-35-58-0400_iPhone-OS_iPhone_23F84` is on this Mac.
  - Its `ambtool_output.log` says "Baseband logs are not enabled".
  - Its only stub is an unrelated profile.
  - Its test reads the folder through `SysdiagnoseCollector`, and through an in-memory tar.gz of the same paths.
  - Result: guide `off`, with problems `loggingNotEnabled` and `noBasebandTrace`, both blocking.
- **Identifiers.** Never kept: info.txt's GUID, DiagID and QSR lines; trace.info's hardware model and boot args.
  Only names, times, sizes and counts are parsed.

## Measured

One capture per process (`/usr/bin/time -l deno run -A tools/pipeline.ts ARCHIVE`), so the peak RSS is that
capture's own; `tests/pipeline_test.ts` prints the same numbers per test.

**Treat the times as upper bounds.** This Mac carried load averages between 7 and 168 throughout (an iOS
simulator, other agents, concurrent builds), and the same run varied by 5x — the moving capture's deframing
measured anywhere from 1.6 s to 9.8 s. The figures below are the *lowest* observed, which are the closest to
idle. The counts, memory and sizes are stable.

| | first capture (15-41-47) | moving capture (08-57-25) |
| --- | --- | --- |
| wall clock, whole analysis | 1.6-5.5 s | 2.1-11.2 s |
| reading / extracting / deframing / decoding / radio | 2,427 / 9 / 2,848 / 82 / 238 ms | 329 / 9 / 1,590 / 54 / 92 ms |
| peak RSS (one process) | 407-474 MB | 352-463 MB |
| held by the analysis (heap + external, over idle) | 287 MB | 189-245 MB |
| log records / distinct codes | 92,133 / 224 | 85,351 / 222 |
| decoded messages / procedures | 128 / 34 | 100 / 23 |
| PHY series / samples / attributed to a cell | 47 / 83,544 / 64,091 | 47 / 56,678 / 33,730 |
| journey markers / findings / tiles | 13 / 10 / 8 | 11 / 12 / 8 |
| `CaptureAnalysis` as JSON | 8.58 MB | 5.67 MB |

The trace itself is the floor for memory: the reader holds the kept chunks (133 MB) until the deframer has
consumed them, so the numbers above are that plus the copies made on it. `tests/pipeline_test.ts` asserts the
analysis holds under 500 MB, and record bodies live in shared 1 MiB blocks that are released when the analysis is
built.

## Notes for the integrator

- Deno cannot structured-clone a Blob into a worker, so `WorkerRequest.file` also accepts an ArrayBuffer (the
  worker test uses one). Browsers get the `File` itself, streamed from disk and never copied whole.
- **The worker boundary, measured.** Inbound costs nothing: a `File` is cloned by handle, and the worker reads it
  as a stream, so a 273 MB archive is never held as one buffer on either side. Outbound is a structured clone of
  the `CaptureAnalysis` — 8.58 MB and 83,544 PHY samples on the first capture, which `structuredClone` takes
  **48–68 ms** over three runs (`JSON.stringify` of the same object: 23 ms, for scale). That is ~3% of the 1.7 s
  analysis and it lands once, after the progress bar is already full, so the result is *not* packed into a
  transferable `ArrayBuffer`: doing so would force the UI to decode bytes instead of reading a typed object, for
  50 ms it never sees. If the analysis ever grows an order of magnitude, revisit that trade, not before.
- After deframing, `analyze.ts` drops each chunk's bytes. If a decoder throws, its stage adds an
  `unsupportedTrace` problem and falls back to empty output; the analysis still resolves.
### Shipping the bundle

> **Lovable is no longer the UI.** The app is now `web/app` (Vite, built in this repo). The worker protocol and
> the `STAGE_ORDER` / `STAGE_LABELS` values below keep the names the earlier Lovable mock used, because the
> engine was written against them and there is nothing to gain from renaming — but no Lovable tool is used, and
> the steps below apply to `web/app/src/engine/` rather than to a Lovable project. The tsconfig note still holds:
> any consumer with those strict flags should take the bundle, not the source.

**Ship the engine as a bundle, not as source.** The stricter tsconfig adds `noUncheckedIndexedAccess`,
`exactOptionalPropertyTypes` and `noPropertyAccessFromIndexSignature` to `strict`, and includes `src/**/*.ts`.
Under those flags today's `src/` has **285** type errors (`deno check --config deno.lovable.json $(find src -name
'*.ts')`), overwhelmingly `Uint8Array` indexing, which those flags type as `number | undefined`. They are not
defects — parity is pinned by the goldens — but Lovable's editor would surface them and its agent could "fix"
them, silently breaking a decoder that no test in that project covers. Only `src/types.ts` has to pass those
flags, and `tests/policy_test.ts` checks that it does.

Build with `deno run -A tools/build.ts`, which writes `dist/` and prints the sizes:

| file | size | what it is |
| --- | --- | --- |
| `dist/engine.js` | 1.4 kB | `analyzeFile`, `revealIdentifiers`, `forgetCapture`, `STAGE_ORDER`, `STAGE_LABELS` |
| `dist/engine.js.map` | 28.9 kB | sourcemap |
| `dist/worker.js` | 152.8 kB | the whole analysis: archive, QDSS, signalling, PHY, journey |
| `dist/worker.js.map` | 665.0 kB | sourcemap |
| `dist/sample-analysis.json` | 505.7 kB | the "Try the sample" capture, invented end to end |

ES modules, minified, `--target=es2022`. `tests/bundle_test.ts` runs `dist/worker.js` in a real worker on a
synthetic archive and asserts the last reply is `done` and that neither file contains `Deno.`, `fetch(`,
`XMLHttpRequest`, `WebSocket`, `localStorage` or `indexedDB`.

Then, in `web/app`:

1. Copy `src/types.ts` to `src/lib/analysis/types.ts` **byte for byte**. It is the canonical copy; the comment
   examples in it are synthetic, so it can go across as it is. (Already done as of this writing: the Lovable
   copy carries the same header and all 56 exports. md5 of the canonical file:
   `12512551ac3a77128fc86078fca05584` — re-check it before assuming they are still in sync.)
2. Copy `dist/worker.js` (and its `.map`) to `src/engine/worker.js`, and delete the mock `src/engine/worker.ts`.
   Add `/* eslint-disable */` at the top, or list the file in `.eslintignore`.
3. Copy `dist/engine.js` (and its `.map`) to `src/engine/index.js`, replacing Lovable's `src/engine/index.ts`.
   Vite resolves its `new URL('./worker.js', import.meta.url)` natively.

**Step 3 is a replacement, not a patch — do not keep Lovable's own `src/engine/index.ts`.** It speaks the same
message protocol, so it *appears* interchangeable, and pointing its worker URL at `worker.js` does produce a
working import. But on `done` it calls `cleanup()`, which calls `worker.terminate()`. That discards the call
flow the worker is holding, and `revealIdentifiers()` then has nothing to ask: **"show identifiers" would be
dead, with no error to explain why.** `dist/engine.js` keeps the worker alive after `done` and ends it in
`forgetCapture()`. Either replace the file, or, to keep Lovable's, delete its `worker.terminate()` from the
`done` path and call `forgetCapture()` when the capture is cleared.

The UI does not call `revealIdentifiers` yet (nothing in the Lovable tree references it), so this costs nothing
today and silently forecloses the feature tomorrow — hence the note.

### The sample capture

`tools/make-sample.ts` generates the "Try the sample" analysis into `dist/sample-analysis.json`
(`deno run -A tools/make-sample.ts`, or `--out FILE` / `--stdout`; `tools/build.ts` writes it too).
Everything in it is invented — cells on the reserved test PLMN `001-01`, a seeded pseudo-random walk for the radio
series — but it is built by the *real* call-flow, UI-mapping and journey rules, so it cannot drift from the
contract. `tests/sample_test.ts` asserts it is byte-stable, that no PLMN but `001-01` appears, and that none of the
real captures' EARFCNs (650, 975, 5110, 67086, 174770) is present.

Ship it as a static asset and `fetch` it. It is 506 kB of pretty-printed JSON (14 radio series, 32 events,
8 tiles) — small enough to inline, but a static asset keeps it out of the main bundle and lets the browser cache
it. The output is byte-stable, so it can be committed as a fixed asset.

**Never copy fixtures or capture output: the app receives synthetic data only.**
