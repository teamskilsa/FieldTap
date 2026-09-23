// Synthetic CaptureAnalysis fixtures for the security check. Everything here is invented — reserved test PLMN
// 001-01, invented PCIs/EARFCNs, a hand-built call flow — so it carries no capture-derived data and can live in
// web/engine. Each fixture carries exactly one IMSI-catcher signature (plus one clean control), so a test can
// assert the matching check fires and the others stay silent. The golden tool serialises analyzeSecurity() of
// each of these.

import type {
  Cell,
  CaptureAnalysis,
  Event,
  Field,
  JourneyCell,
  PhySample,
  PhySeries,
  Protection,
  Step,
} from '../src/types.ts';
import { CONTRACT_VERSION } from '../src/types.ts';

const A: Cell = { earfcn: 100, pci: 11, nr: false }; // anchor / first-seen cell
const B: Cell = { earfcn: 200, pci: 22, nr: false }; // a second LTE cell

let seq = 0;
export function ev(partial: Partial<Event> & Pick<Event, 'layer' | 'name'>): Event {
  const index = partial.index ?? seq++;
  return {
    index,
    sinceStartMs: partial.sinceStartMs ?? index * 100,
    layer: partial.layer,
    rat: partial.rat ?? 'LTE',
    uplink: partial.uplink ?? false,
    channel: partial.channel ?? (partial.layer === 'NAS' ? 'EMM' : 'DL-DCCH'),
    key: partial.key ?? partial.name,
    name: partial.name,
    fields: partial.fields ?? [],
    ciphered: partial.ciphered ?? false,
    isFailure: partial.isFailure ?? false,
    isHandoverCommand: partial.isHandoverCommand ?? false,
    ...(partial.cell ? { cell: partial.cell } : {}),
    ...(partial.cause != null ? { cause: partial.cause } : {}),
    ...(partial.causeName ? { causeName: partial.causeName } : {}),
    ...(partial.protection ? { protection: partial.protection } : {}),
  };
}

export const field = (label: string, value: string, children: Field[] = []): Field => ({ label, value, children });
const integrityProtected: Protection = { headerType: 1, headerName: 'integrity protected', sequence: 1, mac: 1 };

/** A minimal complete CaptureAnalysis with everything empty; overrides fill in the parts a check reads. */
export function base(overrides: Partial<CaptureAnalysis> = {}): CaptureAnalysis {
  seq = 0;
  return {
    contract: CONTRACT_VERSION,
    fileName: 'synthetic',
    traceWindow: null,
    profile: { status: 'active' },
    guide: { status: 'active', needsAttention: false, evaluatedAt: '2026-09-23T00:00:00.000Z' },
    problems: [],
    records: 0,
    codes: 0,
    encryptedRecords: 0,
    encrypted: { records: 0, codes: 0 },
    crcErrors: 0,
    durationMs: 20000,
    events: [],
    procedures: [],
    steps: [],
    connections: [],
    cellDetails: [],
    ladder: { rows: { ALL: [], RRC: [], NAS: [] }, lanes: { phone: 'UE', ran: 'eNB', core: 'MME' }, procedureGroups: [] },
    journey: { durationMs: 20000, states: [], registration: [], cells: [], markers: [], findings: [], tiles: [] },
    phy: [],
    phySummary: { scellActivity: [], rach: [], txAntennasMib: [], rxAntennasByEarfcn: {} },
    phyChecks: [],
    versionMisses: {},
    availability: [],
    timings: {},
    ...overrides,
  };
}

function journeyCell(cell: Cell, startMs: number, band: string): JourneyCell {
  return { lane: 'pcell', index: 0, cell, band, startMs, endMs: startMs + 5000, endInferred: false };
}

function rsrpSeries(values: number[]): PhySeries {
  const samples: PhySample[] = values.map((v, i) => ({ tMs: i * 100, value: v, cell: A }));
  return { metric: 'lte_rsrp', title: 'RSRP', unit: 'dBm', section: 'signal', confidence: 'high', samples };
}

// ------------------------------------------------------------------------------------------------- the fixtures

/** A legitimate LTE attach: integrity-protected request, an IMEISV identity request, an RRC Security Mode
 *  Command, ordinary signal, one first-seen cell. Every check must stay silent. */
export function cleanCapture(): CaptureAnalysis {
  const events = [
    ev({ layer: 'NAS', name: 'Attach request', key: 'Attach request', uplink: true, cell: A, protection: integrityProtected }),
    ev({ layer: 'RRC', name: 'RRC Connection Request', key: 'rrcConnectionRequest', uplink: true, channel: 'UL-CCCH', cell: A }),
    ev({ layer: 'RRC', name: 'RRC Connection Setup', key: 'rrcConnectionSetup', channel: 'DL-CCCH', cell: A }),
    ev({ layer: 'NAS', name: 'Identity request', key: 'Identity request', fields: [field('Identity requested', 'IMEISV')], cell: A }),
    ev({ layer: 'NAS', name: 'Identity response', key: 'Identity response', uplink: true, cell: A }),
    ev({ layer: 'RRC', name: 'Security Mode Command', key: 'securityModeCommand', cell: A }),
    ev({ layer: 'RRC', name: 'Security Mode Complete', key: 'securityModeComplete', uplink: true, cell: A }),
    ev({ layer: 'NAS', name: 'Attach accept', key: 'Attach accept', cell: A }),
  ];
  return base({
    events,
    connections: [{ first: 1, outcome: 'OPEN_AT_END', established: true, startMs: 100 }],
    steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }],
    journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] },
    phy: [rsrpSeries([-95, -96, -94, -97, -95, -96, -98, -95])],
  });
}

export function nullCipherCapture(): CaptureAnalysis {
  const events = [
    ev({ layer: 'NAS', name: 'Attach request', key: 'Attach request', uplink: true, cell: A, protection: integrityProtected }),
    ev({
      layer: 'NAS',
      name: 'Security mode command',
      key: 'Security mode command',
      cell: A,
      fields: [field('Ciphering', 'EEA0'), field('Integrity', 'EIA0')],
    }),
    ev({ layer: 'NAS', name: 'Attach accept', key: 'Attach accept', cell: A }),
  ];
  return base({ events, steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }], journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] } });
}

export function imsiInClearCapture(): CaptureAnalysis {
  const events = [
    ev({ layer: 'RRC', name: 'RRC Connection Setup', key: 'rrcConnectionSetup', channel: 'DL-CCCH', cell: A }),
    ev({ layer: 'NAS', name: 'Identity request', key: 'Identity request', fields: [field('Identity requested', 'IMSI')], cell: A }),
    ev({ layer: 'NAS', name: 'Identity response', key: 'Identity response', uplink: true, cell: A }),
    ev({ layer: 'RRC', name: 'Security Mode Command', key: 'securityModeCommand', cell: A }),
  ];
  return base({ events, steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }], journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] } });
}

export function downgrade2gCapture(): CaptureAnalysis {
  const events = [
    ev({ layer: 'RRC', name: 'Security Mode Command', key: 'securityModeCommand', cell: A }),
    ev({ layer: 'RRC', name: 'RRC Connection Release', key: 'rrcConnectionRelease', cell: A, fields: [field('Redirected to', 'GERAN')] }),
  ];
  return base({ events, steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }], journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] } });
}

export function noAuthCapture(): CaptureAnalysis {
  // Plain (not integrity-protected) attach request, an SMC is present, an accept, and NO authentication.
  const events = [
    ev({ layer: 'NAS', name: 'Attach request', key: 'Attach request', uplink: true, cell: A }),
    ev({ layer: 'RRC', name: 'Security Mode Command', key: 'securityModeCommand', cell: A }),
    ev({ layer: 'NAS', name: 'Attach accept', key: 'Attach accept', cell: A }),
  ];
  return base({ events, steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }], journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] } });
}

export function noSecurityCapture(): CaptureAnalysis {
  // Authentication runs (so acceptedWithoutAuth stays silent) and the request is integrity protected, but no
  // Security Mode Command is ever seen: isolates noSecurityEstablished.
  const events = [
    ev({ layer: 'NAS', name: 'Attach request', key: 'Attach request', uplink: true, cell: A, protection: integrityProtected }),
    ev({ layer: 'NAS', name: 'Authentication request', key: 'Authentication request', cell: A }),
    ev({ layer: 'NAS', name: 'Authentication response', key: 'Authentication response', uplink: true, cell: A }),
    ev({ layer: 'NAS', name: 'Attach accept', key: 'Attach accept', cell: A }),
  ];
  return base({ events, steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }], journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] } });
}

export function abnormalRejectCapture(): CaptureAnalysis {
  const events = [
    ev({ layer: 'RRC', name: 'Security Mode Command', key: 'securityModeCommand', cell: A }),
    ev({ layer: 'NAS', name: 'Attach reject', key: 'Attach reject', cell: A, cause: 3, causeName: 'Illegal UE' }),
  ];
  return base({ events, steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }], journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] } });
}

export function strongSignalCapture(): CaptureAnalysis {
  const events = [ev({ layer: 'RRC', name: 'Security Mode Command', key: 'securityModeCommand', cell: A })];
  return base({
    events,
    steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }],
    journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12')] },
    phy: [rsrpSeries([-42, -40, -41, -39, -43, -40, -38, -41])],
  });
}

export function orphanCellCapture(): CaptureAnalysis {
  // Two LTE serving cells: A is the anchor (first-seen). B appears later with no handover/reselection step into
  // it, is in no neighbour measurement, and the phone opens a connection on it.
  const events = [
    ev({ layer: 'RRC', name: 'Security Mode Command', key: 'securityModeCommand', cell: A }),
    ev({ layer: 'RRC', name: 'RRC Connection Setup', key: 'rrcConnectionSetup', channel: 'DL-CCCH', cell: B, sinceStartMs: 9000 }),
  ];
  const steps: Step[] = [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 0 }];
  return base({
    events,
    steps,
    connections: [
      { first: 0, outcome: 'RELEASED', established: true, startMs: 0, endMs: 5000 },
      { first: 1, outcome: 'OPEN_AT_END', established: true, startMs: 9000 },
    ],
    journey: { ...base().journey, cells: [journeyCell(A, 0, 'B12'), journeyCell(B, 9000, 'B66')] },
  });
}

/**
 * A richer, fully-synthetic capture that trips several checks at once, for a UI screenshot of a flagged view.
 * All invented (reserved test PLMN 001-01, invented PCIs). Cell A carries a null-cipher tell and an IMSI request
 * in the clear; a forced 2G downgrade and an orphan LTE cell (B) follow. Not part of the golden set — it exists
 * only so the app can render a non-alarmist "suspicious" screen.
 */
export function flaggedShowcase(): CaptureAnalysis {
  const events = [
    ev({ layer: 'RRC', name: 'RRC Connection Setup', key: 'rrcConnectionSetup', channel: 'DL-CCCH', cell: A, sinceStartMs: 500 }),
    ev({ layer: 'NAS', name: 'Identity request', key: 'Identity request', cell: A, sinceStartMs: 900, fields: [field('Identity requested', 'IMSI')] }),
    ev({ layer: 'NAS', name: 'Identity response', key: 'Identity response', uplink: true, cell: A, sinceStartMs: 1100 }),
    ev({
      layer: 'NAS',
      name: 'Security mode command',
      key: 'Security mode command',
      cell: A,
      sinceStartMs: 1500,
      fields: [field('Ciphering', 'EEA0'), field('Integrity', 'EIA0')],
    }),
    ev({ layer: 'NAS', name: 'Attach accept', key: 'Attach accept', cell: A, sinceStartMs: 2000 }),
    ev({ layer: 'RRC', name: 'RRC Connection Release', key: 'rrcConnectionRelease', cell: A, sinceStartMs: 6000, fields: [field('Redirected to', 'GERAN')] }),
    ev({ layer: 'RRC', name: 'RRC Connection Setup', key: 'rrcConnectionSetup', channel: 'DL-CCCH', cell: B, sinceStartMs: 11000 }),
  ];
  return base({
    fileName: 'synthetic-flagged',
    durationMs: 14000,
    records: 42000,
    codes: 180,
    events,
    connections: [
      { first: 0, outcome: 'RELEASED', established: true, startMs: 500, endMs: 6000 },
      { first: 6, outcome: 'OPEN_AT_END', established: true, startMs: 11000 },
    ],
    steps: [{ move: 'FIRST_SEEN', to: A, event: 0, sinceStartMs: 500 }],
    journey: {
      ...base().journey,
      durationMs: 14000,
      cells: [journeyCell(A, 500, 'B12'), journeyCell(B, 11000, 'B66')],
    },
  });
}

/** Every synthetic fixture, keyed by the golden file name. */
export const FIXTURES: Record<string, () => CaptureAnalysis> = {
  clean: cleanCapture,
  'null-cipher': nullCipherCapture,
  'imsi-in-clear': imsiInClearCapture,
  'downgrade-2g': downgrade2gCapture,
  'accepted-without-auth': noAuthCapture,
  'no-security-established': noSecurityCapture,
  'abnormal-reject': abnormalRejectCapture,
  'implausible-signal': strongSignalCapture,
  'orphan-cell': orphanCellCapture,
};
