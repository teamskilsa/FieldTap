// The journey strip's lanes (rules J2-J6 and J9, ios/Contract/CONTRACT.md): RRC state, registration, PCell and
// SCells. The NR leg (J8) is in endc.ts because it also makes markers.

import { lteCarrier, nrMhz } from '../signalling/spectrum.ts';
import { isPendingNr } from '../signalling/presentation.ts';
import type { Cell, EvidenceSource, JourneyCell, JourneyState, LaneKind, RegistrationSegment, RegistrationState } from '../types.ts';
import { EPS, isSwitchOffDetach, type JourneyContext, radioOffContains, radioOffOpen, sameCell } from './context.ts';
import { nrBandCandidates } from './nrBands.ts';

// ---------------------------------------------------------------------------------------------- J2-J4 state

export function states(ctx: JourneyContext): JourneyState[] {
  const end = ctx.endMs;
  let segs: JourneyState[] = ctx.firstRrcMs === null
    ? [{ state: 'unknown', startMs: 0, endMs: end }]
    : [{ state: 'unknown', startMs: 0, endMs: Math.min(ctx.firstRrcMs, end) }, { state: 'idle', startMs: Math.min(ctx.firstRrcMs, end), endMs: end }];
  ctx.flow.connections.forEach((c, i) => {
    if (!c.established) return;
    const s: JourneyState = { state: 'connected', startMs: c.startMs, endMs: Math.min(c.endMs ?? end, end), source: `connection ${i} ${c.outcome}` };
    if (c.endMs === null || c.outcome === 'OPEN_AT_END') s.openAtEnd = true;
    segs = paint(segs, s);
  });
  for (const off of ctx.radioOffs) {
    let source = `switch-off detach (event ${off.detachEvent})`;
    if (off.releaseEvent !== null) source += ` then release (event ${off.releaseEvent})`;
    source += off.nextEvent !== null ? `; next cell heard (event ${off.nextEvent})` : '; nothing heard after it';
    const s: JourneyState = { state: 'radioOff', startMs: off.startMs, endMs: off.endMs, source };
    if (radioOffOpen(off)) s.openAtEnd = true;
    segs = paint(segs, s);
  }
  return merged(segs);
}

/** Lays `s` over the segments, cutting whatever it covers. */
function paint(segs: JourneyState[], s: JourneyState): JourneyState[] {
  if (!(s.endMs > s.startMs)) return segs;
  const out: JourneyState[] = [];
  for (const x of segs) {
    if (x.endMs <= s.startMs || x.startMs >= s.endMs) {
      out.push(x);
      continue;
    }
    if (x.startMs < s.startMs) {
      const left: JourneyState = { ...x, endMs: s.startMs };
      delete left.openAtEnd;
      out.push(left);
    }
    if (x.endMs > s.endMs) out.push({ ...x, startMs: s.endMs });
  }
  out.push(s);
  return out.filter((x) => x.endMs - x.startMs > EPS).sort((a, b) => a.startMs - b.startMs);
}

/** Joins neighbouring unknown/idle pieces (connected spans from different connections stay apart). */
function merged(segs: JourneyState[]): JourneyState[] {
  const out: JourneyState[] = [];
  for (const s of segs) {
    const last = out[out.length - 1];
    if (last && last.state === s.state && last.source === undefined && s.source === undefined && Math.abs(last.endMs - s.startMs) < EPS) {
      last.endMs = s.endMs;
      if (s.openAtEnd) last.openAtEnd = true;
      else delete last.openAtEnd;
    } else out.push({ ...s });
  }
  return out;
}

// --------------------------------------------------------------------------------------------- J5 registration

/** A first NAS procedure that a registered phone runs: registered (assumed) before any NAS evidence. */
const ASSUMED_REGISTERED_FIRST = new Set(['Detach', 'Tracking area update', 'Service request', 'Deregistration']);
export const REGISTERING = new Set(['Attach', 'Registration']);

export function registration(ctx: JourneyContext): RegistrationSegment[] {
  const transitions: { t: number; state: RegistrationState }[] = [];
  for (const e of ctx.events) {
    if (e.layer !== 'NAS') continue;
    const k = e.key.toLowerCase();
    if (isSwitchOffDetach(e) || k.includes('detach accept') || k.includes('deregistration accept') || k.includes('attach reject') || k.includes('registration reject')) {
      transitions.push({ t: e.sinceStartMs, state: 'deregistered' });
    }
  }
  for (const p of ctx.flow.procedures) {
    if (p.layer !== 'NAS' || !REGISTERING.has(p.name) || p.outcome !== 'SUCCEEDED') continue;
    const t = ctx.time(p.last);
    if (t !== null) transitions.push({ t, state: 'registered' });
  }
  transitions.sort((a, b) => a.t - b.t);

  const nas = ctx.flow.procedures.filter((p) => p.layer === 'NAS');
  const firstNas = nas.length ? nas.reduce((a, b) => (b.first < a.first ? b : a)) : null;
  const assumed = firstNas !== null && ASSUMED_REGISTERED_FIRST.has(firstNas.name);
  let state: RegistrationState = assumed ? 'registered' : 'unknown';
  let isAssumed = assumed;
  let start = 0;
  const out: RegistrationSegment[] = [];
  for (const { t, state: next } of transitions) {
    if (next === state) continue;
    const at = Math.min(Math.max(t, start), ctx.endMs);
    if (at > start) out.push({ state, startMs: start, endMs: at, assumed: isAssumed });
    state = next;
    isAssumed = false;
    start = at;
  }
  if (ctx.endMs > start || !out.length) out.push({ state, startMs: start, endMs: ctx.endMs, assumed: isAssumed });
  return out;
}

// ------------------------------------------------------------------------------------------------ J6 PCell

export function pcells(ctx: JourneyContext): JourneyCell[] {
  const steps = ctx.flow.journey;
  const events = ctx.events;
  const out: JourneyCell[] = [];
  let previousEnd = 0;
  steps.forEach((step, n) => {
    if (isPendingNr(step.to)) return;
    const nextStepMs = n + 1 < steps.length ? steps[n + 1].sinceStartMs : null;
    const limit = Math.min(nextStepMs ?? ctx.endMs, ctx.endMs);
    // J6: the earlier of the step and the first RRC message on the new cell since the last segment ended.
    const firstHere = events.find((e) => e.layer === 'RRC' && sameCell(e.cell, step.to) && e.sinceStartMs >= previousEnd);
    let start = Math.min(step.sinceStartMs, firstHere?.sinceStartMs ?? step.sinceStartMs);
    let reason: string | undefined;
    if (firstHere && firstHere.sinceStartMs < step.sinceStartMs - EPS) reason = `first message on the cell (${shortName(firstHere.key, firstHere.name)})`;
    const inOff = ctx.radioOffs.find((o) => radioOffContains(o, start));
    if (inOff) {
      start = inOff.endMs;
      reason = 'back after radio off';
    }
    const pieces: { start: number; end: number; startReason?: string; endReason?: string; open: boolean }[] = [];
    let cursor = start;
    while (cursor < limit) {
      const off = ctx.radioOffs.find((o) => o.startMs >= cursor && o.startMs < limit);
      if (!off) {
        pieces.push({ start: cursor, end: limit, startReason: reason, open: nextStepMs === null });
        break;
      }
      pieces.push({ start: cursor, end: off.startMs, startReason: reason, endReason: 'radioOff', open: false });
      // The same cell again after the radio came back, if that is where it came back.
      if (!(off.endMs < limit) || off.nextEvent === null || !sameCell(events[off.nextEvent].cell, step.to)) break;
      cursor = off.endMs;
      reason = 'back after radio off';
    }
    for (const p of pieces) {
      if (!(p.end > p.start)) continue;
      out.push(segment(ctx, 'pcell', out.length, step.to, p.start, p.end, {
        openAtEnd: p.open,
        startReason: p.startReason,
        endReason: p.endReason,
        source: 'rrc',
      }));
    }
    previousEnd = pieces.length ? pieces[pieces.length - 1].end : limit;
  });
  return out;
}

/** 'SIB1', 'SI', 'MIB' for the broadcast messages; otherwise the event's name. */
function shortName(key: string, name: string): string {
  switch (key) {
    case 'systemInformationBlockType1':
      return 'SIB1';
    case 'systemInformation':
      return 'SI';
    case 'mib':
    case 'masterInformationBlock':
      return 'MIB';
    default:
      return name;
  }
}

// ------------------------------------------------------------------------------------------------ J9 SCells

export function scells(ctx: JourneyContext): JourneyCell[] {
  return [...ctx.phy.scellActivity].sort((a, b) => a.index - b.index).flatMap((a) =>
    a.earfcn === undefined ? [] : [segment(ctx, 'scell', a.index, { earfcn: a.earfcn, pci: a.pci ?? -1, nr: false }, a.firstMs, Math.max(a.lastMs, a.firstMs), {
      startReason: 'first PHY record',
      endReason: 'last PHY record',
      source: 'phy',
    })]
  );
}

// -------------------------------------------------------------------------------------------------- segments

export interface SegmentOptions {
  addedMs?: number | undefined;
  openAtEnd?: boolean | undefined;
  endInferred?: boolean | undefined;
  startReason?: string | undefined;
  endReason?: string | undefined;
  source: EvidenceSource;
}

/** A lane segment with its band ('B66', or the NR candidates 'n5/n26') and DL frequency from the Spectrum port. */
export function segment(ctx: JourneyContext, lane: LaneKind, index: number, cell: Cell, startMs: number, endMs: number, o: SegmentOptions): JourneyCell {
  const out: JourneyCell = { lane, index, cell, band: '', startMs, endMs, endInferred: o.endInferred ?? false, source: o.source };
  if (cell.nr) {
    const candidates = nrBandCandidates(cell.earfcn, ctx.mcc);
    out.band = candidates.length ? candidates.map((b) => `n${b}`).join('/') : 'NR';
    out.bandCandidates = candidates;
    const mhz = nrMhz(cell.earfcn);
    if (mhz !== null) out.dlMhz = mhz;
  } else {
    const carrier = lteCarrier(cell.earfcn);
    out.band = carrier ? `B${carrier.band}` : 'LTE';
    if (carrier) out.dlMhz = carrier.dlMhz;
  }
  if (o.addedMs !== undefined) out.addedMs = o.addedMs;
  if (o.openAtEnd) out.openAtEnd = true;
  if (o.startReason !== undefined) out.startReason = o.startReason;
  if (o.endReason !== undefined) out.endReason = o.endReason;
  return out;
}

/** The PCell segment covering `tMs` (the last one, so a move instant belongs to the new cell). */
export function pcellAt(cells: readonly JourneyCell[], tMs: number, slack = 0.5): JourneyCell | undefined {
  let found: JourneyCell | undefined;
  for (const c of cells) if (c.lane === 'pcell' && tMs >= c.startMs - slack && tMs <= c.endMs + slack) found = c;
  return found;
}

