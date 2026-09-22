# src/signalling

The LTE/NR RRC and NAS call flow: the Kotlin sources at contract v1 (`ios/Contract/src-v1`, D1-D4), ported
file by file. Each `.ts` file names its Kotlin source in its first line.

| File | Kotlin source | What it holds |
| --- | --- | --- |
| `logcodes.ts` | LogCodes.kt | the signalling log codes and what each claims |
| `per.ts` | LteRrc.kt (PerBits) | the unaligned-PER bit reader |
| `bytes.ts` | (JVM bounds) | `u8` that throws `OutOfBounds` where Kotlin throws IndexOutOfBoundsException |
| `lterrc.ts` | LteRrc.kt | 0xB0C0, header layouts A-E (v30 = E, map D), names, fixed-position fields |
| `nrrrc.ts` | NrRrc.kt | 0xB821, layouts A/B/C/E (v26 = E, PDU 11/12), carried 5G NAS |
| `nas.ts`, `nasnames.ts`, `nasfields.ts` | Nas.kt, NasNames.kt, NasFields.kt | NAS location, names, causes, fields |
| `cellinfo.ts` | CellInfo.kt | 0xB0C2 serving cell |
| `callflow.ts` | CallFlow.kt | `readFlow(records, crcErrors)`, `readQmdlFlow(bytes)`: events, procedures (D3), journey, connections |
| `presentation.ts` | CallFlowPresentation.kt | ladder rows, groups, lanes, `shortCell` (D4), `sinceStart`, `duration` |
| `spectrum.ts` | Spectrum.kt | EARFCN/NR-ARFCN to band and MHz, ECI split, TA distance |
| `javafmt.ts` | (Java's Formatter) | `fixed(v, n)` = `String.format(Locale.ROOT, "%.nf")`, which rounds half up |
| `mask.ts` | tools/GoldenDump.kt | the golden masking rules |
| `golden.ts` | tools/GoldenDump.kt, PresDump.kt | `goldenDump`, `presentationDump`: the fixtures' exact text |
| `ui.ts` | (the web contract) | `uiSignalling(flow, {reveal, annotations})`: the src/types.ts arrays and the ladder |
| `flow.ts` | CallFlow.kt (types) | `Flow`, the parity model (null for absent, bigint stamps, PDU bytes) |

Protocol.kt and Hdlc.kt are `src/diag/record.ts` and `src/diag/hdlc.ts` (foundation). D1 is `diag/timebase.ts`.

## Parity

`tests/signalling_golden_test.ts` checks this. For each of `iphone-recovered.qmdl`, `attach4`, and the two
OnePlus captures, `goldenDump(readFlow(...))` matches its fixture byte for byte (the md5s in CONTRACT.md), and
`presentationDump` matches presentation-golden.json. The other three captures have no presentation fixture, so
the test pins the md5s of PresDump.kt run on the same qmdls. The real first archive, run through the QDSS
deframer, gives the same flow.

## Identifiers

`Flow` holds the decoded values and the PDU bytes. It stays in the worker, and the UI types get
`uiSignalling(flow)`, which is masked by default:

- Every `Field.value`, `Event.summary`, `Procedure.detail` and `Procedure.refusal` holds the golden-masked text.
- The matching `masked`, `summaryMasked`, `detailMasked` and `refusalMasked` are set to that same text wherever
  masking changed it, so they also act as the flag the UI shows next to a sensitive value.
- `pduHex` and `CellDetail.cellIdentity` are left out.
- TAC stays, because the golden keeps it. The UI hides it while identifiers are masked.

`uiSignalling(flow, { reveal: true })` returns the decoded values, with the masked forms beside them, plus the
bytes and the cell identity. Call it only after the user has confirmed a reveal, and keep the `Flow` so that no
second decode is needed.
