// The marker row: moves (J7), connection outcomes (J2), the switch-off detach (J3), RRC setup and attach, RRC
// releases, RACH (J10) and failures (J11). The NR leg's markers come from endc.ts (J8). Marker text that quotes
// the flow (causes, APNs) is scrubbed by the golden masking rules: markers have no masked variant.

import { scrub } from '../signalling/mask.ts';
import { lteTimingAdvanceMetres } from '../signalling/spectrum.ts';
import type { FlowEvent, FlowStep } from '../signalling/flow.ts';
import type { Marker, MarkerKind, Severity } from '../types.ts';
import { isRelease, type JourneyContext } from './context.ts';
import { REGISTERING } from './lanes.ts';
import { distance, idTime } from './text.ts';

/** The contract's tie order at one instant: MarkerKind's order in src/types.ts. */
export const KIND_ORDER: readonly MarkerKind[] = [
  'handover', 'reselection', 'reattach', 'redirect', 'reestablishment', 'cellChange', 'scgAdd', 'scgModify', 'scgRelease',
  'attach', 'detachSwitchOff', 'rrcSetup', 'rrcRelease', 'rach', 'failure', 'warning',
];

export const kindRank = (k: MarkerKind): number => KIND_ORDER.indexOf(k);

const SEVERITY: Record<Severity, number> = { info: 0, warning: 1, failure: 2 };

export function markers(ctx: JourneyContext, endc: readonly Marker[]): Marker[] {
  const all = [...moves(ctx), ...procedures(ctx), ...releases(ctx), ...switchOffs(ctx), ...rach(ctx), ...endc, ...merged(problems(ctx))];
  return uniqueIds(sorted(all));
}

// ------------------------------------------------------------------------------------------------- J7 moves

function moves(ctx: JourneyContext): Marker[] {
  const events = ctx.events;
  const out: Marker[] = [];
  ctx.flow.journey.forEach((step, n) => {
    const base = { from: step.from ?? undefined, to: step.to };
    switch (step.move) {
      case 'FIRST_SEEN':
        return;
      case 'HANDOVER': {
        // The command is the last handover RRCConnectionReconfiguration within 1 s before the arrival.
        let at: number | null = null;
        for (let i = 0; i < events.length; i++) {
          const e = events[i];
          if (e.isHandoverCommand && e.sinceStartMs <= step.sinceStartMs && e.sinceStartMs >= step.sinceStartMs - 1_000) at = i;
        }
        const t = at === null ? step.sinceStartMs : events[at].sinceStartMs;
        const m: Marker = clean({
          id: `handover-${at ?? step.event}`,
          kind: 'handover',
          tMs: t,
          event: at ?? step.event,
          endEvent: step.event,
          arrivalMs: step.sinceStartMs,
          severity: 'info',
          title: 'Handover',
          ...base,
        });
        const duration = at === null ? undefined : ctx.handoverProcedure(at)?.durationMs ?? step.sinceStartMs - t;
        if (duration !== undefined) m.durationMs = duration;
        if (at === null) {
          m.inferred = true;
          m.detail = 'no handover command logged within 1 s';
        }
        out.push(m);
        return;
      }
      case 'RESELECTION': {
        const re = isReattach(ctx, step, n);
        out.push(clean({
          id: `${re ? 'reattach' : 'reselection'}-${step.event}`,
          kind: re ? 'reattach' : 'reselection',
          tMs: step.sinceStartMs,
          event: step.event,
          severity: 'info',
          title: re ? 'Re-attach' : 'Reselection',
          detail: re ? 'Reselection, after switch-off detach' : 'Idle-mode reselection',
          ...base,
        }));
        return;
      }
      case 'REDIRECT':
        out.push(move(step, 'redirect', 'Redirect', 'The network released the connection and sent the phone to another cell.'));
        return;
      case 'REESTABLISHMENT':
        out.push(move(step, 'reestablishment', 'Re-establishment', 'The phone re-established its connection, usually after a radio link failure.'));
        return;
      case 'CELL_CHANGE':
        out.push(move(step, 'cellChange', 'Cell change', 'Changed cell while connected without a logged handover.'));
        return;
    }
  });
  return out;
}

/** J7's warnings: a move the network or the radio forced. */
const move = (step: FlowStep, kind: MarkerKind, title: string, detail: string): Marker =>
  clean({ id: `${kind}-${step.event}`, kind, tMs: step.sinceStartMs, event: step.event, severity: 'warning', title, detail, from: step.from ?? undefined, to: step.to });

/** J7: a reselection is a re-attach when a switch-off radio off ended inside the gap before it and an Attach (or
 *  Registration) starts on the new cell before, or inside, the first connection after the radio came back. */
function isReattach(ctx: JourneyContext, step: FlowStep, index: number): boolean {
  const previous = index > 0 ? ctx.flow.journey[index - 1].sinceStartMs : 0;
  const offs = ctx.radioOffs.filter((o) => o.nextEvent !== null && o.endMs >= previous && o.endMs <= step.sinceStartMs + 0.000_5);
  const off = offs[offs.length - 1];
  if (!off) return false;
  const after = ctx.flow.connections.filter((c) => c.startMs >= off.endMs).sort((a, b) => a.startMs - b.startMs)[0];
  const limit = after ? after.endMs ?? ctx.endMs : ctx.endMs;
  return ctx.flow.procedures.some((p) => {
    const t = ctx.time(p.first);
    const cell = ctx.events[p.first]?.cell;
    return REGISTERING.has(p.name) && t !== null && t >= off.endMs && t <= limit && !!cell && cell.earfcn === step.to.earfcn && cell.pci === step.to.pci && cell.nr === step.to.nr;
  });
}

// --------------------------------------------------------------------------------- procedures and releases

function procedures(ctx: JourneyContext): Marker[] {
  const out: Marker[] = [];
  for (const p of ctx.flow.procedures) {
    if (p.outcome !== 'SUCCEEDED') continue;
    const t = ctx.time(p.first);
    if (t === null) continue;
    const detail = p.detail === null ? undefined : scrub(p.detail);
    if (p.name === 'RRC connection setup' || p.name === 'RRC setup') {
      out.push(clean({ id: `rrcSetup-${p.first}`, kind: 'rrcSetup', tMs: t, event: p.first, endEvent: p.last, durationMs: p.durationMs, severity: 'info', title: 'RRC setup', detail }));
    } else if (REGISTERING.has(p.name)) {
      out.push(clean({ id: `attach-${p.first}`, kind: 'attach', tMs: t, event: p.first, endEvent: p.last, durationMs: p.durationMs, severity: 'info', title: p.name, detail, to: ctx.events[p.first].cell ?? undefined }));
    }
  }
  return out;
}

function releases(ctx: JourneyContext): Marker[] {
  return ctx.events.flatMap((e, i) =>
    isRelease(e)
      ? [clean({ id: `rrcRelease-${i}`, kind: 'rrcRelease', tMs: e.sinceStartMs, event: i, severity: 'info', title: 'RRC release', detail: e.summary === null ? undefined : `Cause: ${scrub(e.summary)}`, from: e.cell ?? undefined })]
      : []
  );
}

function switchOffs(ctx: JourneyContext): Marker[] {
  return ctx.radioOffs.map((off) =>
    clean({
      id: `detachSwitchOff-${off.detachEvent}`,
      kind: 'detachSwitchOff',
      tMs: off.detachMs,
      event: off.detachEvent,
      severity: 'info',
      title: 'Switched off',
      detail: 'Switch-off detach: the phone told the network it was powering its radio down.',
      from: ctx.events[off.detachEvent].cell ?? undefined,
    })
  );
}

// ----------------------------------------------------------------------------------------------------- J10

function rach(ctx: JourneyContext): Marker[] {
  return ctx.phy.rach.map((r) => {
    const computed = lteTimingAdvanceMetres(r.ta);
    const metres = r.distanceM ?? (computed === null ? undefined : Math.round(computed * 10) / 10);
    return clean({
      id: `rach-${idTime(r.tMs)}`,
      kind: 'rach',
      tMs: r.tMs,
      severity: 'info',
      title: 'Random access',
      detail: `Timing advance ${r.ta}${metres === undefined ? '' : `, about ${distance(metres)} from the cell`}`,
      ta: r.ta,
      distanceM: metres,
    });
  });
}

// ------------------------------------------------------------------------------------------------ J2, J11

/** Failure and warning markers, before merging duplicates at one event. Event failures come first so that, at
 *  equal severity, the merge keeps the most specific marker. */
function problems(ctx: JourneyContext): Marker[] {
  const events = ctx.events;
  const out: Marker[] = [];
  events.forEach((e, i) => {
    if (!e.isFailure) return;
    out.push(clean({ id: `failure-${i}`, kind: 'failure', tMs: e.sinceStartMs, event: i, severity: 'failure', title: e.name, detail: causeText(e), from: e.cell ?? undefined }));
  });
  for (const p of ctx.flow.procedures) {
    if (p.outcome === 'SUCCEEDED') continue;
    const t = ctx.time(p.first);
    if (t === null) continue;
    const failed = p.outcome === 'FAILED';
    out.push(clean({
      id: `${failed ? 'failure' : 'warning'}-${p.first}`,
      kind: failed ? 'failure' : 'warning',
      tMs: t,
      event: p.first,
      endEvent: p.last,
      severity: failed ? 'failure' : 'warning',
      title: failed ? `${p.name} failed` : `${p.name}: no answer`,
      detail: failed ? (p.refusal === null ? undefined : scrub(p.refusal)) : 'Nothing answered this request in the capture.',
      durationMs: failed ? p.durationMs : undefined,
      from: events[p.first].cell ?? undefined,
    }));
  }
  for (const c of ctx.flow.connections) {
    const at = c.last ?? c.first;
    const cause = c.establishmentCause === null ? undefined : `Requested for ${c.establishmentCause}`;
    if (c.outcome === 'LOST') {
      out.push(clean({ id: `failure-${at}`, kind: 'failure', tMs: c.endMs ?? events[at].sinceStartMs, event: at, severity: 'failure', title: 'Connection lost', detail: 'The phone was idle again with no release logged, typically a radio link failure.', from: events[at].cell ?? undefined }));
    } else if (c.outcome === 'REJECTED') {
      out.push(clean({ id: `failure-${at}`, kind: 'failure', tMs: events[at].sinceStartMs, event: at, severity: 'failure', title: 'Connection rejected', detail: cause, from: events[at].cell ?? undefined }));
    } else if (c.outcome === 'NO_ANSWER') {
      out.push(clean({ id: `warning-${c.first}`, kind: 'warning', tMs: c.startMs, event: c.first, severity: 'warning', title: 'Connection request not answered', detail: cause, from: events[c.first].cell ?? undefined }));
    }
  }
  return out;
}

const causeText = (e: FlowEvent): string | undefined =>
  e.cause !== null ? `#${e.cause}${e.causeName === null ? '' : ` ${e.causeName}`}` : e.summary === null ? undefined : scrub(e.summary);

/** J11: markers at one event merge, keeping the highest severity (the first one at a tie). */
function merged(ms: Marker[]): Marker[] {
  const byEvent = new Map<number, number>();
  const out: Marker[] = [];
  for (const m of ms) {
    if (m.event === undefined) {
      out.push(m);
      continue;
    }
    const k = byEvent.get(m.event);
    if (k === undefined) {
      byEvent.set(m.event, out.length);
      out.push(m);
    } else if (SEVERITY[m.severity] > SEVERITY[out[k].severity]) out[k] = m;
  }
  return out;
}

// ---------------------------------------------------------------------------------------------- order, ids

/** Contract amendment: a stable sort by time, then kind rank, then event. */
function sorted(ms: Marker[]): Marker[] {
  return ms.map((m, i) => ({ m, i })).sort((a, b) =>
    a.m.tMs - b.m.tMs || kindRank(a.m.kind) - kindRank(b.m.kind) || (a.m.event ?? -1) - (b.m.event ?? -1) || a.i - b.i
  ).map((e) => e.m);
}

/** Ids are unique within a journey (the UI keys lists on them): a repeat gets '-2', '-3'. */
export function uniqueIds<T extends { id: string }>(items: T[]): T[] {
  const seen = new Map<string, number>();
  return items.map((x) => {
    const n = (seen.get(x.id) ?? 0) + 1;
    seen.set(x.id, n);
    return n > 1 ? { ...x, id: `${x.id}-${n}` } : x;
  });
}

/** `o` without its undefined keys: the UI receives plain data, with absent values left out. */
export function clean<T extends object>(o: T): T {
  for (const k of Object.keys(o) as (keyof T)[]) if (o[k] === undefined) delete o[k];
  return o;
}
