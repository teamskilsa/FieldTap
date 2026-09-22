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
deno test -A         # 52 tests: 38 synthetic + 14 fixture-gated
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `FT_FIXTURES` | `../../ios/Fixtures/local` | The contract fixtures (git-ignored, capture-derived). Read in place, never copied. |
| `FT_ARCHIVES` | `~/Downloads` | The real sysdiagnose archives (`tools/fixtures.ts` `REAL` names them). Read in place. |
| `FT_REQUIRE_FIXTURES=1` | off | A missing fixture fails its test instead of skipping it. Use it on the fixture machine. |

The fixture-gated tests run whenever their files exist, and skip only when the files are absent. With the
fixtures absent the result is 38 passed and 14 ignored; with them present, 52 passed and 0 ignored.

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
| `src/qdss/deframer.ts` | **qdss agent** | stub with the final interface |
| `src/signalling/` (flow, callflow, presentation, mask) | **signalling agent** | `flow.ts` types and `mask.ts` done; `callflow.ts` and `presentation.ts` are stubs |
| `src/phy/extract.ts`, `src/journey/build.ts` | **phy-journey agent** | stubs |
| `src/analyze.ts`, `src/worker.ts`, `src/index.ts`, `src/mapping.ts` | **integrator** | working skeleton; archive stages real, decoders stubbed |
| `tests/`, `tools/` | shared; each agent adds its own `*_test.ts` | foundation tests + tools done |

### Stub signatures (final) and their parity targets

```ts
// src/qdss/deframer.ts: port of Fixtures/local/reference/qdss_deframe.py (verified rules only)
class QdssDeframer { feed(bytes: Uint8Array): void; endChunk(): void; finish(): DeframeOutput }
interface DeframeOutput { records: LogRecord[]; secure: EncryptedCensus; stats: DeframeStats }
```
Feed each chunk in name order, in any split, then call `endChunk()`. Layer-1 frames align to each chunk's
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

### Contract changes relative to the first Lovable types (the UI to-do list)

Compared with the types the first Lovable build wrote (`src/lib/analysis/types.ts` at commit `4832cd5`, message
`umsg_01m34tjjh6exb9e7cpfgp790x1`, read with the Lovable MCP). Every Lovable name is kept (`JourneyStateName`,
`JourneyState`, `JourneyCell`, `Tile`, ...), as is its `?: T | undefined` style, which the Lovable tsconfig's
`exactOptionalPropertyTypes` needs. `src/index.ts` also exports `STAGE_ORDER` and `STAGE_LABELS` with the Lovable
values. The worker speaks the Lovable mock worker's messages (`analyze` / `cancel` in; `progress`, `done`, `error`
out), so either side can be swapped alone.

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

## Notes for the integrator

- Deno cannot structured-clone a Blob into a worker, so `WorkerRequest.file` also accepts an ArrayBuffer (the
  worker test uses one). Browsers get the `File` itself, streamed from disk and never copied whole.
- After deframing, `analyze.ts` drops each chunk's bytes. If a decoder throws, its stage adds an
  `unsupportedTrace` problem and falls back to empty output; the analysis still resolves.
- **Ship the engine to Lovable as a bundle, not as source.** The Lovable tsconfig adds `noUncheckedIndexedAccess`,
  `exactOptionalPropertyTypes` and `noPropertyAccessFromIndexSignature` to `strict`, and includes `src/**/*.ts`.
  Under those flags today's `src/` has 66 type errors (`deno check --config deno.lovable.json $(find src -name
  '*.ts')`), mostly `Uint8Array` indexing, which those flags type as `number | undefined`. Lovable's editor would
  show them and its agent could "fix" them, while parity is only tested here. Only `src/types.ts` must pass them,
  and a test checks that it does. So:
  1. Copy `src/types.ts` to `src/lib/analysis/types.ts` byte for byte.
  2. Build `npx esbuild src/worker.ts --bundle --format=esm --platform=browser --target=es2022
     --banner:js='/* eslint-disable */' --outfile=<lovable>/src/engine/worker.js`. This is 48.6 KB today, with no
     Deno reference; a Deno Worker ran the bundle on a synthetic archive and got `done`.
  3. Keep Lovable's own `src/engine/index.ts`, which speaks the same protocol. Change its worker URL to
     `./worker.js`, and delete the mock `worker.ts`.
  Vite resolves `new URL('./worker.js', import.meta.url)` natively.
- Never copy fixtures or capture output: Lovable receives synthetic data only.
