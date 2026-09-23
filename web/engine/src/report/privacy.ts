// The record types that must never leave the phone, by log code.
//
// The modem trace carries the GNSS subsystem's own position reports. 0x1476 is publicly named "GNSS Position
// Report" and the driving capture holds 105 of them at a steady 5 Hz across 22 seconds: a position track of the
// person holding the phone, which is more identifying than the IMSI. FieldTap decodes none of them, and this
// module is the second line: every code below is stripped from anything the app writes out - the redacted report
// and the JSON beside it - so a future decoder, a debug field or a record census cannot leak one by accident.
//
// The list is deliberately wider than the codes this trace happens to contain: the whole 0x147x GNSS block, the
// assistance and almanac reports at 0x1923/0x1924, and the two QMI link codes that carry NMEA sentences
// (0x1391 QMI Link 2 TX Message and 0x1544 QMI_MCS_QCSI_PKT), which is how a position reaches the AP.
//
// Nothing here removes a measurement: EARFCN, PCI, band, PLMN, timings and radio measurements describe the
// network, not the person, and a report without them says nothing (see web/app/src/lib/report/redact.ts).

import type { CaptureAnalysis } from '../types.ts';

export interface LocationCode {
  code: number;
  /** '0x1476', as the analysis spells a log code. */
  hex: string;
  name: string;
}

export const LOCATION_LOG_CODES: readonly LocationCode[] = [
  { code: 0x1476, hex: '0x1476', name: 'GNSS position report' },
  { code: 0x1477, hex: '0x1477', name: 'GNSS measurement report' },
  { code: 0x1478, hex: '0x1478', name: 'GNSS report' },
  { code: 0x1479, hex: '0x1479', name: 'GNSS report' },
  { code: 0x147a, hex: '0x147A', name: 'GNSS report' },
  { code: 0x147b, hex: '0x147B', name: 'GNSS CD database report' },
  { code: 0x147c, hex: '0x147C', name: 'GNSS PE WLS position report' },
  { code: 0x147d, hex: '0x147D', name: 'GNSS PE KF position report' },
  { code: 0x147e, hex: '0x147E', name: 'GNSS PRx RF hardware status' },
  { code: 0x147f, hex: '0x147F', name: 'GNSS report' },
  { code: 0x1480, hex: '0x1480', name: 'GNSS position report (extended)' },
  { code: 0x1923, hex: '0x1923', name: 'GNSS assistance data' },
  { code: 0x1924, hex: '0x1924', name: 'GNSS almanac / ephemeris' },
  { code: 0x1391, hex: '0x1391', name: 'QMI link 2 TX message (carries NMEA)' },
  { code: 0x1544, hex: '0x1544', name: 'QMI_MCS_QCSI_PKT (carries NMEA)' },
];

const CODES = new Set(LOCATION_LOG_CODES.map((c) => c.code));

/** True when a log code is one of the location-bearing record types. */
export const isLocationCode = (code: number): boolean => CODES.has(code);

/** True when a '0x1476'-style string names one (either case). */
export function isLocationCodeHex(hex: string): boolean {
  const n = Number.parseInt(hex, 16);
  return Number.isFinite(n) && CODES.has(n);
}

/** One line for the export dialog and the report: what was excluded and why. */
export const LOCATION_EXCLUSION_NOTE =
  "Records from the modem's GNSS subsystem - its own position reports (0x1476, 0x147C-0x147E) and the QMI links " +
  'that carry NMEA sentences (0x1391, 0x1544) - are excluded from this export by log code. A 5 Hz position track ' +
  'is the most identifying data in a modem trace, and FieldTap neither decodes it nor writes it out.';

/**
 * A copy of the analysis with every trace of those record types removed: the deframer's code census, the encrypted
 * census, any decoded message that came from one, and any availability entry that names one. The original object is
 * never touched.
 */
export function stripLocationRecords(a: CaptureAnalysis): CaptureAnalysis {
  const out: CaptureAnalysis = { ...a };
  if (a.deframe) {
    out.deframe = {
      ...a.deframe,
      top_codes: a.deframe.top_codes.filter(([hex]) => !isLocationCodeHex(hex)),
    };
  }
  if (a.encrypted.byCode) {
    const byCode = Object.fromEntries(Object.entries(a.encrypted.byCode).filter(([hex]) => !isLocationCodeHex(hex)));
    out.encrypted = { ...a.encrypted, byCode };
  }
  // No decoder reads these records, so this only ever fires if one is added later - which is the point.
  out.events = a.events.filter((e) => !(e.logCode && isLocationCodeHex(e.logCode)));
  out.phy = a.phy.filter((s) => !(s.code && isLocationCodeHex(s.code)));
  out.availability = a.availability
    .filter((x) => !(x.codes ?? []).some(isLocationCodeHex))
    .map((x) => (x.codes ? { ...x, codes: [...x.codes] } : { ...x }));
  out.versionMisses = Object.fromEntries(
    Object.entries(a.versionMisses).filter(([key]) => !isLocationCodeHex(key.split(' ')[0] ?? '')),
  );
  return out;
}

/** Every location code a piece of exported text mentions: the check the export tests run. */
export function locationCodesIn(text: string): string[] {
  const found = new Set<string>();
  for (const c of LOCATION_LOG_CODES) {
    if (text.includes(c.hex) || text.includes(c.hex.toLowerCase())) found.add(c.hex);
  }
  return [...found];
}
