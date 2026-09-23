# FieldTap security check (fake base station / IMSI catcher)

A **local, no-network** cross-check of the decoded RRC/NAS call flow for the Layer-3 signatures long associated
with IMSI catchers / Stingrays / fake base stations. It takes a `CaptureAnalysis` and returns a `SecurityReport`
(per-cell verdicts, an overall verdict, and a plain-language reason for every finding). It calls nothing, stores
nothing, and sends nothing — `tests/policy_test.ts` enforces that no code in `src/` touches the network or the
host, this module included.

## Why this is different from CellGuard

CellGuard reads shallow **QMI management packets** and cross-checks **Apple's cell-location database**. FieldTap
decodes the **actual RRC/NAS trace**, so it can look for the *classic* catcher signatures that live in **Layer 3** —
the same class SnoopSnitch and Darshak look for on Android — mapped onto the fields our `CaptureAnalysis` already
carries: `events` (RRC + NAS with names, causes, `ciphered`, `protection`), `cells`, `procedures`, `steps`,
`connections`, `journey`, `cellDetails`, and `phy`. Every check cites the exact decoded field(s) it reads, and no
detection is invented for data we do not have.

The single design rule: **a false positive on a real network is worse than a miss.** Every threshold below was
tuned to leave the real AT&T reference capture (`web/app/public/dev/analysis.json`) with a **trusted** verdict, and
only then to fire on a synthetic carrying the matching signature. A sophisticated catcher that mimics a real cell
can pass — this is evidence to check, not a guarantee, and the UI says so.

## The ruleset

Ruleset version: `fieldtap-security/1` (`SECURITY_RULESET`). Bump it when a rule or threshold changes so the iOS
port can pin the golden reports it matches.

| Check (`SecurityCheckId`) | Rule | Decoded fields it reads | Severity |
| --- | --- | --- | --- |
| `nullCipher` | A NAS Security Mode Command that chose **EEA0** (null ciphering) or **EIA0** (null integrity). | `Event.fields` `Ciphering` / `Integrity` (from `signalling/nasfields.ts`). | **suspicious** |
| `noSecurityEstablished` | A registration/attach **accept** was seen but **no** Security Mode Command (RRC or NAS) anywhere in the trace. | `Event.name` / `Event.key` (accept + `securityModeCommand`). | **suspicious** |
| `imsiRequestedInClear` | An **Identity Request for the IMSI** before security is established. IMEISV/IMEI/GUTI requests are never flagged. | `Event.fields` `Identity requested`, position vs. the first Security Mode Command. | **suspicious** |
| `ratDowngrade` | A forced redirect/reselection to **GERAN (2G)** or **UTRAN (3G)**. | `Event.fields` `Redirected to` (`signalling/lterrc.ts`, `nrrrc.ts`). | 2G **suspicious**, 3G **warning** |
| `acceptedWithoutAuth` | An **accept** with **no Authentication** message **and** no prior security context (the initial NAS request was not integrity protected). | accept + `Authentication request/response` events + `Event.protection.headerName` on the initial request. | **suspicious** |
| `abnormalReject` | A NAS reject whose EMM/5GMM cause strands the phone: **#3, #6, #7, #8, #11, #12, #13, #14, #15**. | `Event.layer`, `Event.cause`, `Event.causeName` on reject messages. | **suspicious** |
| `implausibleSignal` | Serving-cell RSRP above the per-RAT threshold, **sustained** over several samples. | `phy` `lte_rsrp` / `lte_rsrp_filtered` / `nr_ss_rsrp` samples + carrier attribution. | **warning** |
| `orphanCell` | An **LTE serving/connection cell** that is not the first camped cell, reached by **no** handover/reselection, and in **no** neighbour evidence. | `journey.cells`, `steps`, `connections`, `cellDetails`, measurement-report `PCI n` fields, `phySummary.intraFreqNeighbours`, `phy` `lte_neighbour_*`. | **warning** |

### Thresholds (`thresholds.ts`)

- **Strong signal.** `STRONG_RSRP_DBM = { lte: -50, nr: -50 }` dBm. A real macro cell tops out near -60 dBm; the
  reference capture peaks at about **-81.8 dBm**, far below. To avoid a spike triggering it, at least
  `STRONG_RSRP_MIN_SAMPLES = 5` samples **and** `STRONG_RSRP_MIN_SHARE = 0.2` of the series must be over threshold.
- **Abnormal reject causes.** `ABNORMAL_REJECT_CAUSES = {3, 6, 7, 8, 11, 12, 13, 14, 15}` (EMM TS 24.301 / 5GMM
  TS 24.501; the numbers coincide for this set). These deny service or force a forbidden list.
- **Downgrade tokens.** `GERAN` (2G, suspicious); `UTRA`/`UTRAN`/`UTRA-FDD`/`UTRA-TDD` (3G, warning).

### Aggregation

Each finding has a severity (`info` / `warning` / `suspicious`). A cell's verdict is the **worst** of its
findings; the capture verdict is the worst across all cells and unattached findings. `info` never lowers a
verdict. `trusted` = nothing found.

## The real-capture result (why each check stays silent)

On the moving AT&T capture (`web/app/public/dev/analysis.json`): verdict **trusted**, zero findings.

- `nullCipher` — the NAS Security Mode Command is ciphered, so no `Ciphering`/`Integrity` field is exposed; the AS
  security procedure ran.
- `noSecurityEstablished` — an RRC Security Mode Command is present.
- `imsiRequestedInClear` — the identity request is for **IMEISV**, not IMSI.
- `ratDowngrade` — no `Redirected to` GERAN/UTRAN in the trace.
- `acceptedWithoutAuth` — the Attach request is **integrity protected** (a reused GUTI context), so skipping
  fresh authentication is legitimate.
- `abnormalReject` — no NAS reject in the trace.
- `implausibleSignal` — peak RSRP -81.8 dBm, far below -50.
- `orphanCell` — the two serving cells are the first-seen anchor and a **reselection** target; the NR PSCell is
  excluded (NR legs are added by the anchor, not by a step, and NR neighbour decode is limited).

## What the current decode does NOT expose (the `gaps` in every report)

- **`sibNeighbourList`** — SIB neighbour lists and full measurement configurations are not decoded, so
  "advertised neighbour" cannot be read directly. The orphan-cell check falls back to *measured* neighbours and
  mobility context, which is why it is a warning, not a suspicious verdict.
- **`asSecurityAlgorithm`** — the RRC Security Mode Command is decoded by name, but its chosen AS
  ciphering/integrity algorithm is not surfaced, so AS null-algorithm cannot be read. Null-algorithm detection
  therefore uses the **NAS** Security Mode Command.
- **`sibAuthenticity`** — SIB1/SI are decoded for cell identity but not cross-checked for broadcast tampering
  (a spoofed cell barring, a spoofed PLMN), which would need fields the SIB decode does not yet surface.

These would each strengthen a check; they are listed in the report so the gap is visible, not hidden.

## Optional external cell-database cross-check (`external.ts`) — design only, off by default

`external.ts` defines the **interface** for an opt-in cross-check against a cell database and contains **no**
network code. It is not wired into `analyzeSecurity` or the default pipeline. Enabling it would send **coarse cell
IDs** (MCC, MNC, TAC, cell id, EARFCN, PCI — never IMSI/IMEI/GUTI, never PHY samples, never the trace) off-device,
so any implementation MUST be disabled by default, require explicit per-session consent, and say so in the UI.

- **OpenCelliD** (CC-BY-SA 4.0, API key, attribution + share-alike) — the clean, documented option.
- **Apple ALS** (`gs-loc.apple.com`) — an **undocumented** endpoint with no public terms for this use; a gray
  area that may change or block without notice. Note it, prefer OpenCelliD, do not rely on it.
- Mozilla Location Service is retired; do not use it.

An external result may only ever **raise** a cell's suspicion (an unknown cell is more suspect), never lower it.

## Golden fixtures (for the iOS port)

`deno run -A tools/security-goldens.ts` writes the golden `SecurityReport` for each synthetic case to
`tests/security/golden/*.security.json` (invented data — reserved PLMN, invented PCIs — committed) and, when the
real capture is present, the real-capture report to `out/security/real-analysis.security.json` (git-ignored,
capture-derived, **never committed**). `tests/security_golden_test.ts` asserts the synthetic goldens are stable,
and `tests/security_real_test.ts` asserts the real capture stays trusted. iOS matches these byte for byte.
