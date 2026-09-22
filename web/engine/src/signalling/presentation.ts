// Port of ios/Contract/src-v1/CallFlowPresentation.kt (android app ui/signalling, contract v1 with D4).
//
// Turns a Flow into what the call-flow ladder draws, and formats the numbers on it, kept apart from any UI so
// the row building (what folds, where banners go) is tested on its own. The strings equal
// contract/presentation-golden.json exactly: numbers go through javafmt.fixed, Java's '%.Nf' rounding.

import type { Cell, FlowFilter, Ladder, LadderRow, ProcedureGroup } from '../types.ts';
import { sameCell } from './callflow.ts';
import type { Flow, FlowEvent, FlowProcedure, FlowStep, Layer } from './flow.ts';
import { fixed, hex } from './javafmt.ts';
import { lteCarrier, nrMhz } from './spectrum.ts';

export const FILTERS: readonly FlowFilter[] = ['ALL', 'RRC', 'NAS'];

const BROADCAST = new Set(['BCCH-BCH', 'BCCH-DL-SCH', 'MCCH', 'PCCH']);

/** One line of the ladder, holding the flow's own objects (LadderRow in the Kotlin). */
export type FlowRow =
  /** The phone moved to another cell here. `stepIndex` indexes flow.journey. */
  | { kind: 'move'; key: string; step: FlowStep; stepIndex: number }
  /** A procedure starts at the next message. `ordinal` indexes flow.procedures. */
  | { kind: 'procedure'; key: string; procedure: FlowProcedure; ordinal: number }
  /**
   * One message, or a run of broadcast messages folded into one line. An idle phone reads SIB1 and paging over
   * and over, and a phone searching for service reads the system information of every cell it hears: one
   * overnight capture held 40,000 of them around 400 messages that mattered.
   */
  | { kind: 'message'; key: string; event: FlowEvent; repeats: FlowEvent[] };

export type FlowMessageRow = Extract<FlowRow, { kind: 'message' }>;

export const messageCount = (row: FlowMessageRow) => 1 + row.repeats.length;

/** More than one kind of message, or more than one cell, in the run. */
export const messageMixed = (row: FlowMessageRow) => row.repeats.some((r) => r.key !== row.event.key || !sameCell(r.cell, row.event.cell));

/** Ladder rows for one filter: folded repeats, procedure banners and move rows, in time order. */
export function flowRows(flow: Flow, filter: FlowFilter): FlowRow[] {
  const shown = flow.events.filter((e) => filter === 'ALL' || e.layer === filter);
  // associateBy: a later step at the same event replaces an earlier one.
  const moves = new Map<number, [FlowStep, number]>();
  if (filter !== 'NAS') flow.journey.forEach((s, i) => { if (s.move !== 'FIRST_SEEN') moves.set(s.event, [s, i]); });
  const starts = new Map<number, [FlowProcedure, number][]>();
  flow.procedures.forEach((p, ordinal) => {
    if (filter !== 'ALL' && p.layer !== filter) return;
    const list = starts.get(p.first);
    if (list) list.push([p, ordinal]);
    else starts.set(p.first, [[p, ordinal]]);
  });

  const rows: FlowRow[] = [];
  let index = 0;
  while (index < shown.length) {
    const event = shown[index];
    const move = moves.get(event.index);
    if (move) rows.push({ kind: 'move', key: `move-${move[0].event}`, step: move[0], stepIndex: move[1] });
    for (const [procedure, ordinal] of starts.get(event.index) ?? []) rows.push({ kind: 'procedure', key: `procedure-${ordinal}`, procedure, ordinal });
    let end = index + 1;
    if (BROADCAST.has(event.channel)) {
      while (end < shown.length && foldsInto(event, shown[end], moves, starts)) end++;
    }
    rows.push({ kind: 'message', key: `event-${event.index}`, event, repeats: shown.slice(index + 1, end) });
    index = end;
  }
  return rows;
}

function foldsInto(first: FlowEvent, next: FlowEvent, moves: Map<number, unknown>, starts: Map<number, unknown>): boolean {
  return BROADCAST.has(next.channel) && !moves.has(next.index) && !starts.has(next.index) &&
    // Paging is on the serving cell and says the phone is idle there; it does not join a search.
    (next.channel === 'PCCH') === (first.channel === 'PCCH');
}

/** The ladder row a message is on, for scrolling to it. Folded messages land on their run. */
export function rowOf(rows: FlowRow[], eventIndex: number): number {
  return rows.findIndex((r) => r.kind === 'message' && (r.event.index === eventIndex || r.repeats.some((e) => e.index === eventIndex)));
}

function distinctCells(row: FlowMessageRow): Cell[] {
  const out: Cell[] = [];
  for (const e of [row.event, ...row.repeats]) {
    if (e.cell && !out.some((c) => sameCell(c, e.cell))) out.push(e.cell);
  }
  return out;
}

/** The cells of a folded run, in the order first heard: 'B3 PCI 3, B7 PCI 2 +14'. */
export function cellsOf(row: FlowMessageRow, shown = 2): string {
  const cells = distinctCells(row);
  const head = cells.slice(0, shown).map(shortCell).join(', ');
  return cells.length > shown ? `${head} +${cells.length - shown}` : head;
}

export const cellCount = (row: FlowMessageRow) => distinctCells(row).length;

// MARK: - Procedures

/** Every attempt at one kind of procedure, and how they went; `items` index flow.procedures. */
export interface FlowProcedureGroup {
  name: string;
  layer: Layer;
  items: FlowProcedure[];
  ordinals: number[];
  succeeded: number;
  failed: number;
  unanswered: number;
  /** The median time of the ones that succeeded: what "how long does an attach take here" means. */
  medianMs: number | null;
}

/** Procedures by kind, in the order each kind first happened. */
export function flowProcedureGroups(flow: Flow): FlowProcedureGroup[] {
  const groups = new Map<string, { items: FlowProcedure[]; ordinals: number[] }>();
  flow.procedures.forEach((p, i) => {
    const g = groups.get(p.name);
    if (g) {
      g.items.push(p);
      g.ordinals.push(i);
    } else groups.set(p.name, { items: [p], ordinals: [i] });
  });
  return [...groups].map(([name, { items, ordinals }]) => {
    const count = (o: FlowProcedure['outcome']) => items.filter((p) => p.outcome === o).length;
    return {
      name,
      layer: items[0].layer,
      items,
      ordinals,
      succeeded: count('SUCCEEDED'),
      failed: count('FAILED'),
      unanswered: count('UNANSWERED'),
      medianMs: medianMs(items),
    };
  });
}

export function medianMs(items: FlowProcedure[]): number | null {
  const times = items.filter((p) => p.outcome === 'SUCCEEDED').map((p) => p.durationMs).sort((a, b) => a - b);
  if (times.length === 0) return null;
  const mid = times.length >> 1;
  return times.length % 2 === 1 ? times[mid] : (times[mid - 1] + times[mid]) / 2;
}

// MARK: - Lanes

/** Lane titles: 'UE' | 'eNB' or 'gNB' (or 'RAN' when both) | 'MME' or 'AMF' (or 'Core'). */
export function lanes(flow: Flow): Ladder['lanes'] {
  const rats = new Set(flow.events.map((e) => e.rat));
  if (rats.size === 1 && rats.has('nr')) return { phone: 'UE', ran: 'gNB', core: 'AMF' };
  if (rats.has('nr')) return { phone: 'UE', ran: 'RAN', core: 'Core' };
  return { phone: 'UE', ran: 'eNB', core: 'MME' };
}

// MARK: - Cells

/** Kotlin's Long.toInt(): the low 32 bits as a signed int. */
const toInt = (v: number) => v | 0;

/**
 * 'B3' for an LTE cell, or null when the EARFCN is in no band this app knows. Always null for NR: NR bands
 * overlap (n77 contains n78), so the ARFCN alone does not name one, and a guessed band would often be wrong.
 */
export function band(cell: Cell): string | null {
  if (cell.nr) return null;
  const carrier = lteCarrier(toInt(cell.earfcn));
  return carrier ? `B${carrier.band}` : null;
}

/** Downlink centre frequency in MHz, one decimal: TS 36.101 for an EARFCN, the TS 38.104 raster for NR. */
export function downlinkMhz(cell: Cell): string | null {
  const mhz = cell.nr ? nrMhz(toInt(cell.earfcn)) : lteCarrier(toInt(cell.earfcn))?.dlMhz ?? null;
  return mhz === null ? null : `${fixed(mhz, 1)} MHz`;
}

/** What the cell's channel number is called: EARFCN on LTE, NR-ARFCN on NR. */
export const channelLabel = (cell: Cell) => (cell.nr ? 'NR-ARFCN' : 'EARFCN');

/** D4: an NR RRC header logged before the SCG cell is assigned carries PCI 0xFFFF or ARFCN 0xFFFFFFFF. */
export const isPendingNr = (cell: Cell) => cell.nr && (cell.pci === 0xffff || cell.earfcn === 0xffffffff);

/** 'B3 PCI 3', 'NR PCI 417', 'NR cell pending' (D4), or 'EARFCN 70000 PCI 3' when an LTE band is unknown. */
export function shortCell(cell: Cell): string {
  if (isPendingNr(cell)) return 'NR cell pending';
  if (cell.nr) return `NR PCI ${cell.pci}`;
  return `${band(cell) ?? `EARFCN ${cell.earfcn}`} PCI ${cell.pci}`;
}

// MARK: - Time

const pad = (n: number, width: number) => `${n}`.padStart(width, '0');

/**
 * Since the start of the capture, as a clock: '0:00.064', '1:58.338', '1:02:03.004'. Tabular and sortable by
 * eye, which a mix of '64 ms' and '2 min' is not.
 */
export function sinceStart(ms: number): string {
  const total = Math.round(Math.max(ms, 0)); // Java's Math.round: ties toward +infinity, as here
  const millis = total % 1000;
  const seconds = Math.floor(total / 1000) % 60;
  const minutes = Math.floor(total / 60_000) % 60;
  const hours = Math.floor(total / 3_600_000);
  return hours > 0 ? `${hours}:${pad(minutes, 2)}:${pad(seconds, 2)}.${pad(millis, 3)}` : `${minutes}:${pad(seconds, 2)}.${pad(millis, 3)}`;
}

/** A span: '0.4 ms', '67.5 ms', '1.24 s', '2 min 3 s'. */
export function duration(ms: number): string {
  if (ms < 0) return duration(0);
  if (ms < 100) return `${fixed(ms, 1)} ms`;
  if (ms < 1000) return `${fixed(ms, 0)} ms`;
  if (ms < 10_000) return `${fixed(ms / 1000, 2)} s`;
  if (ms < 60_000) return `${fixed(ms / 1000, 1)} s`;
  if (ms < 3_600_000) return `${Math.trunc(ms / 60_000)} min ${Math.trunc((ms % 60_000) / 1000)} s`;
  return `${Math.trunc(ms / 3_600_000)} h ${Math.trunc((ms % 3_600_000) / 60_000)} min`;
}

/** The gap to the message before, or null for the first. */
export function gap(events: FlowEvent[], index: number): number | null {
  return index <= 0 ? null : events[index].sinceStartMs - events[index - 1].sinceStartMs;
}

// MARK: - Bytes

/** Eight bytes a line (what fits a phone in monospace), with the offset and the printable characters. */
export function hexDump(bytes: Uint8Array, perLine = 8): string {
  const lines: string[] = [];
  for (let at = 0; at < bytes.length; at += perLine) {
    const chunk = [...bytes.subarray(at, at + perLine)];
    const hexText = chunk.map((b) => hex(b, 2)).join(' ').padEnd(perLine * 3 - 1);
    const text = chunk.map((b) => (b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : '.')).join('');
    lines.push(`${hex(at, 4)}  ${hexText}  ${text}`);
  }
  return lines.join('\n');
}

export const hexString = (bytes: Uint8Array) => [...bytes].map((b) => hex(b, 2)).join('');

// MARK: - The UI's ladder (src/types.ts)

/** Ladder rows for one filter, as the UI types carry them (indexes into the analysis' arrays). */
export function rows(flow: Flow, filter: FlowFilter): LadderRow[] {
  return flowRows(flow, filter).map((r): LadderRow => {
    switch (r.kind) {
      case 'move': {
        const row: LadderRow = { type: 'move', key: r.key, step: r.stepIndex, move: r.step.move, to: shortCell(r.step.to) };
        const b = band(r.step.to), dl = downlinkMhz(r.step.to);
        if (b !== null) row.band = b;
        if (dl !== null) row.downlink = dl;
        return row;
      }
      case 'procedure':
        return { type: 'procedure', key: r.key, procedure: r.ordinal, name: r.procedure.name, outcome: r.procedure.outcome, duration: duration(r.procedure.durationMs) };
      case 'message': {
        const row: LadderRow = {
          type: 'message',
          key: r.key,
          event: r.event.index,
          repeats: r.repeats.map((e) => e.index),
          name: r.event.name,
          count: messageCount(r),
          mixed: messageMixed(r),
          cells: cellsOf(r),
          cellCount: cellCount(r),
          since: sinceStart(r.event.sinceStartMs),
        };
        const g = gap(flow.events, r.event.index);
        if (g !== null) row.gap = duration(g);
        return row;
      }
    }
  });
}

export function procedureGroups(flow: Flow): ProcedureGroup[] {
  return flowProcedureGroups(flow).map((g) => {
    const out: ProcedureGroup = {
      name: g.name,
      layer: g.layer,
      n: g.items.length,
      succeeded: g.succeeded,
      failed: g.failed,
      unanswered: g.unanswered,
      procedures: g.ordinals,
    };
    if (g.medianMs !== null) out.median = duration(g.medianMs);
    return out;
  });
}

/** Everything the UI's ladder needs. */
export function ladder(flow: Flow): Ladder {
  return {
    rows: { ALL: rows(flow, 'ALL'), RRC: rows(flow, 'RRC'), NAS: rows(flow, 'NAS') },
    lanes: lanes(flow),
    procedureGroups: procedureGroups(flow),
  };
}
