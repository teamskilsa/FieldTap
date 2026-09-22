// Rule J8: the EN-DC NR leg. The parity call flow has no SCG model, so the PSCell is read from the NR RRC messages
// logged inside an open LTE connection, and its end is inferred from what ends an SCG (v1 decodes no SCG release).

import { isPendingNr } from '../signalling/presentation.ts';
import type { CarrierActivity, Cell, JourneyCell, Marker } from '../types.ts';
import { isReestablishmentRequest, isRelease, isScgFailure, type JourneyContext } from './context.ts';
import { segment } from './lanes.ts';
import { idTime } from './text.ts';

export interface EnDc {
  pscells: JourneyCell[];
  markers: Marker[];
}

/** How long after the SCG-add reconfiguration the PSCell's first NR message may come (the NR complete). */
const ADD_WINDOW_MS = 200;

export function enDc(ctx: JourneyContext, pcells: readonly JourneyCell[]): EnDc {
  const events = ctx.events;
  const out: EnDc = { pscells: [], markers: [] };
  let active: { cell: Cell; startMs: number; addedMs: number | null } | null = null;
  let lastMs = 0;

  const close = (t: number, inferred: boolean, reason: string, event: number | null) => {
    if (!active) return;
    out.pscells.push(segment(ctx, 'pscell', out.pscells.length, active.cell, active.startMs, Math.max(t, active.startMs), {
      addedMs: active.addedMs ?? undefined,
      endInferred: inferred,
      startReason: 'SCG add',
      endReason: reason,
      source: 'rrc',
    }));
    if (inferred) {
      const m: Marker = {
        id: `scgRelease-${event ?? idTime(t)}`,
        kind: 'scgRelease',
        tMs: t,
        severity: 'info',
        title: 'NR leg released (inferred)',
        detail: reason,
        from: active.cell,
        inferred: true,
      };
      if (event !== null) m.event = event;
      out.markers.push(m);
    }
    active = null;
  };

  events.forEach((e, i) => {
    if (active) {
      const off = ctx.radioOffs.find((o) => o.startMs > lastMs && o.startMs <= e.sinceStartMs);
      if (off) close(off.startMs, true, `radio off (switch-off detach, event ${off.detachEvent})`, off.detachEvent);
    }
    lastMs = e.sinceStartMs;
    if (active && e.rat === 'lte') {
      if (e.isHandoverCommand) close(e.sinceStartMs, true, `LTE handover command (event ${i}); NR release not in the decoded fields`, i);
      else if (isRelease(e)) close(e.sinceStartMs, true, `LTE RRC release (event ${i})`, i);
      else if (isReestablishmentRequest(e)) close(e.sinceStartMs, true, `RRC re-establishment request (event ${i})`, i);
    }
    // Logged, not inferred: the failure marker itself comes from J11 (the event is a failure).
    if (active && isScgFailure(e)) close(e.sinceStartMs, false, `SCG failure (event ${i})`, i);

    if (e.layer !== 'RRC' || e.rat !== 'nr' || e.uplink || e.key.toLowerCase() !== 'rrcreconfiguration') return;
    if (!ctx.connectionAt(e.sinceStartMs)) return;
    const pcell = pcells.find((p) => e.sinceStartMs >= p.startMs && e.sinceStartMs <= p.endMs);
    if (!pcell || pcell.cell.nr) return;

    const header = e.cell;
    const current = active as { cell: Cell } | null;
    if (current && header && !isPendingNr(header) && header.earfcn === current.cell.earfcn && header.pci === current.cell.pci) {
      out.markers.push({ id: `scgModify-${i}`, kind: 'scgModify', tMs: e.sinceStartMs, event: i, severity: 'info', title: 'NR leg modified', to: current.cell });
      return;
    }
    // An SCG add: the PSCell is the first NR RRC message on a real cell within 200 ms (usually the NR
    // RRCReconfigurationComplete; the header before it is D4's pending cell).
    let named: number | null = null, complete: number | null = null;
    for (let j = i; j < events.length && events[j].sinceStartMs <= e.sinceStartMs + ADD_WINDOW_MS; j++) {
      const x = events[j];
      if (named === null && x.layer === 'RRC' && x.rat === 'nr' && x.cell && !isPendingNr(x.cell)) named = j;
      if (complete === null && x.rat === 'nr' && x.key.toLowerCase() === 'rrcreconfigurationcomplete') complete = j;
    }
    const cell = named === null ? null : events[named].cell;
    if (named === null || !cell) {
      out.markers.push({ id: `scgAdd-${i}`, kind: 'scgAdd', tMs: e.sinceStartMs, event: i, severity: 'info', title: 'NR leg requested', detail: 'no NR cell logged within 200 ms' });
      return;
    }
    if (active) close(e.sinceStartMs, true, `SCG change (event ${i})`, i);
    const endEvent = complete ?? named;
    const addedMs = ctx.time(endEvent);
    active = { cell, startMs: e.sinceStartMs, addedMs };
    const m: Marker = { id: `scgAdd-${i}`, kind: 'scgAdd', tMs: e.sinceStartMs, event: i, endEvent, severity: 'info', title: 'NR leg added', to: cell };
    if (addedMs !== null) m.durationMs = addedMs - e.sinceStartMs;
    out.markers.push(m);
  });
  const still = active as { cell: Cell; startMs: number; addedMs: number | null } | null;
  if (still) {
    out.pscells.push(segment(ctx, 'pscell', out.pscells.length, still.cell, still.startMs, ctx.endMs, {
      addedMs: still.addedMs ?? undefined,
      openAtEnd: true,
      startReason: 'SCG add',
      source: 'rrc',
    }));
  }
  attributeNrPhy(ctx.phy.nrDlActivity, out.pscells);
  return out;
}

/** The NR DL PHY activity names no NR-ARFCN (0xB887 carries a PCI and a carrier index), so it is given to the
 *  PSCell it overlaps in time: phyLastMs, the cross-check of an inferred end. */
function attributeNrPhy(a: CarrierActivity | undefined, pscells: JourneyCell[]): void {
  if (!a) return;
  pscells.forEach((s, k) => {
    if (a.earfcn !== undefined && a.earfcn !== s.cell.earfcn) return;
    if (a.pci !== undefined && a.pci !== s.cell.pci) return;
    const nextStart = k + 1 < pscells.length ? pscells[k + 1].startMs : Infinity;
    if (!(a.firstMs < nextStart && a.lastMs >= s.startMs)) return;
    s.phyLastMs = Math.min(a.lastMs, nextStart);
  });
}
