// What every journey rule reads from the parity call flow: the capture's end, the first RRC event, the J3
// switch-off radio-off spans and the MCC the NR band rule narrows by. Built once per buildJourney (the port of
// FTJourney's JourneyContext.swift).

import type { Flow, FlowConnection, FlowEvent, FlowProcedure } from '../signalling/flow.ts';
import type { Cell, PhySummary } from '../types.ts';

/** A J3 span: from the switch-off detach's release (or the detach itself) to the first RRC event after it. */
export interface RadioOff {
  detachEvent: number;
  detachMs: number;
  releaseEvent: number | null;
  startMs: number;
  endMs: number;
  /** The first RRC event after the span; null when nothing was heard again before the capture ended. */
  nextEvent: number | null;
}

export const radioOffOpen = (o: RadioOff) => o.nextEvent === null;
export const radioOffContains = (o: RadioOff, tMs: number) => tMs >= o.startMs && tMs < o.endMs;

export const sameCell = (a: Cell | null | undefined, b: Cell | null | undefined): boolean =>
  !!a && !!b && a.earfcn === b.earfcn && a.pci === b.pci && a.nr === b.nr;

/** Times from the parity flow are printed to 3 decimals: equal within half a microsecond is the same instant. */
export const EPS = 0.000_5;

export class JourneyContext {
  /** Where every lane ends: the flow's duration (J1), or its last event when the duration is shorter. The OnePlus
   *  5G registration golden has a negative duration (repo `main` behaviour, kept by D1) but events up to 188 s. */
  readonly endMs: number;
  /** The first RRC event of any channel (J4: before it the state is 'unknown'). */
  readonly firstRrcMs: number | null;
  readonly radioOffs: RadioOff[];
  /** From the capture facts, else the first serving-cell record's PLMN ('310-410' -> 310), for the NR band rule. */
  readonly mcc: number | null;

  constructor(readonly flow: Flow, readonly phy: PhySummary, mcc?: string) {
    let last = 0;
    for (const e of flow.events) last = Math.max(last, e.sinceStartMs);
    this.endMs = Math.max(flow.durationMs, last, 0);
    this.firstRrcMs = flow.events.find((e) => e.layer === 'RRC')?.sinceStartMs ?? null;
    this.mcc = parseMcc(mcc ?? flow.cellDetails[0]?.info.plmn);
    this.radioOffs = radioOffs(flow.events, this.endMs);
  }

  get events(): FlowEvent[] {
    return this.flow.events;
  }

  time(event: number): number | null {
    return this.flow.events[event]?.sinceStartMs ?? null;
  }

  /** The established connection open at `tMs`, if any. */
  connectionAt(tMs: number): FlowConnection | null {
    return this.flow.connections.find((c) => c.established && tMs >= c.startMs && tMs <= (c.endMs ?? this.endMs)) ?? null;
  }

  /** The Handover procedure that starts at `event`, for its duration. */
  handoverProcedure(event: number): FlowProcedure | null {
    return this.flow.procedures.find((p) => p.name === 'Handover' && p.first === event) ?? null;
  }
}

/** '310-410' or '310410' -> 310. */
export function parseMcc(plmn: string | null | undefined): number | null {
  if (!plmn) return null;
  const digits = plmn.split('-')[0].replace(/\D/g, '');
  return digits.length >= 3 ? Number(digits.slice(0, 3)) : null;
}

// ------------------------------------------------------------------------------------------- event classes

export function isRelease(e: FlowEvent): boolean {
  const k = e.key.toLowerCase();
  return e.layer === 'RRC' && (k.startsWith('rrcconnectionrelease') || k.startsWith('rrcrelease'));
}

export const isReestablishmentRequest = (e: FlowEvent) => e.layer === 'RRC' && e.key.toLowerCase().includes('reestablishmentrequest');

export const isScgFailure = (e: FlowEvent) => e.key.toLowerCase().includes('scgfailure');

/** J3: an uplink Detach (or 5G deregistration) request whose 'Switch off' field says yes. */
export function isSwitchOffDetach(e: FlowEvent): boolean {
  if (e.layer !== 'NAS' || !e.uplink) return false;
  const k = e.key.toLowerCase();
  if (!k.includes('detach request') && !k.includes('deregistration request') && !k.includes('de-registration request')) return false;
  const field = e.fields.some((f) => f.label.toLowerCase().includes('switch off') && ['yes', 'switch off', 'true', '1'].includes(f.value.toLowerCase()));
  return field || (e.summary?.toLowerCase().includes('switch off') ?? false);
}

// ---------------------------------------------------------------------------------------------------- J3

function radioOffs(events: FlowEvent[], endMs: number): RadioOff[] {
  const out: RadioOff[] = [];
  events.forEach((e, i) => {
    if (!isSwitchOffDetach(e)) return;
    const t0 = e.sinceStartMs;
    if (out.some((o) => radioOffContains(o, t0) || o.detachEvent === i)) return;
    let release: number | null = null;
    for (let j = i + 1; j < events.length; j++) {
      const x = events[j];
      if (isRelease(x) && x.sinceStartMs >= t0 && x.sinceStartMs <= t0 + 2_000) {
        release = j;
        break;
      }
    }
    const startMs = release === null ? t0 : events[release].sinceStartMs;
    let next: number | null = null;
    for (let j = (release ?? i) + 1; j < events.length; j++) {
      const x = events[j];
      if (x.layer !== 'RRC' || x.sinceStartMs < startMs) continue;
      // No release logged: the UL/DL-DCCH messages that carry the detach itself (within 2 s, on its cell) are not
      // a sign of the radio coming back.
      if (release === null && x.channel.endsWith('DCCH') && sameCell(x.cell, e.cell) && x.sinceStartMs <= t0 + 2_000) continue;
      next = j;
      break;
    }
    const end = next === null ? endMs : events[next].sinceStartMs;
    out.push({ detachEvent: i, detachMs: t0, releaseEvent: release, startMs, endMs: Math.max(end, startMs), nextEvent: next });
  });
  return out;
}
