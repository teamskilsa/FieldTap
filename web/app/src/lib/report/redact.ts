// The redacted copy of an analysis, for export.
//
// Exporting is the one moment a capture can leave the machine, so the copy that leaves is built to be shareable
// without a second thought: every identifier is already gone from the object itself, not merely hidden behind a
// UI switch. Nothing here invents its own masking — it reuses the engine's (`@engine/signalling/mask`), which is
// the same port of the Android and iOS redaction the goldens are written with, so the exported strings and the
// masked strings on screen can never disagree.
//
// What is removed:
//   - every field whose label is an identity label, and everything under it            → '<masked>'
//   - IPs, long digit runs and long hex anywhere else in a string                      → '<masked>'
//   - the PDU hex of every message                                                     → dropped
//   - the TAC and the cell identity of every cell                                      → dropped
//   - the archive's own file name                                                      → scrubbed
//   - every trace of a location-bearing record type, by log code                        → dropped
//
// The last one is the modem's GNSS subsystem: its own position reports (0x1476, 0x147C-0x147E) and the QMI links
// that carry NMEA (0x1391, 0x1544). FieldTap decodes none of them, and the export drops them by code anyway, so
// no census, count or future decoder can put a 5 Hz position track in a file the user shares
// (@engine/report/privacy, which owns the list).
//
// What stays, deliberately: EARFCN, PCI, band, PLMN, timings, counts, measurements and message names. Those
// describe the *network*, not the person holding the phone, and a report without them says nothing.
import { stripLocationRecords } from "@engine/report/privacy";
import { maskField, scrub } from "@engine/signalling/mask";
import type { CaptureAnalysis, CellDetail, Event, Field, Finding, Marker } from "@engine/types";

const s = (v: string | undefined): string | undefined => (v == null ? undefined : scrub(v));

function redactField(field: Field): Field {
  const masked = maskField(field) as Field;
  // `masked` is now the only value there is, so the parallel "masked" copy is dropped rather than left to rot.
  return { label: masked.label, value: masked.value, children: masked.children.map(redactField) };
}

function redactEvent(event: Event): Event {
  const { summaryMasked, pduHex: _pduHex, ...rest } = event;
  return {
    ...rest,
    ...(summaryMasked ?? event.summary ? { summary: summaryMasked ?? s(event.summary) } : {}),
    fields: event.fields.map(redactField),
  };
}

function redactCell(cell: CellDetail): CellDetail {
  const { tac: _tac, cellIdentity: _cellIdentity, ...rest } = cell;
  // TAC is required by the type, so it is zeroed rather than deleted: a reader sees 0, not a real area code.
  return { ...rest, tac: 0 };
}

const redactFinding = (f: Finding): Finding => ({ ...f, text: scrub(f.text) });
const redactMarker = (m: Marker): Marker => ({
  ...m,
  title: scrub(m.title),
  ...(m.detail ? { detail: scrub(m.detail) } : {}),
});

/** A deep copy of the analysis with every identifier and every location-bearing record gone. The original object is
 *  never touched. */
export function redactAnalysis(analysis: CaptureAnalysis): CaptureAnalysis {
  // By log code first, so nothing downstream has to remember which records carry a position.
  analysis = stripLocationRecords(analysis);
  return {
    ...analysis,
    fileName: scrub(analysis.fileName.replace(/^dev:/, "")),
    events: analysis.events.map(redactEvent),
    cellDetails: analysis.cellDetails.map(redactCell),
    ladder: {
      ...analysis.ladder,
      rows: {
        ALL: analysis.ladder.rows.ALL,
        RRC: analysis.ladder.rows.RRC,
        NAS: analysis.ladder.rows.NAS,
      },
    },
    journey: {
      ...analysis.journey,
      findings: analysis.journey.findings.map(redactFinding),
      markers: analysis.journey.markers.map(redactMarker),
    },
  };
}
