// "What happened" (rule J12): a handful of sentences, each tied to the moment it describes, ordered by time, then
// the fixed tail: failures (or noFailures), the encrypted records, the trace window. Ids are unique ('handover-82');
// Finding.kind carries the category. Text that quotes the flow is scrubbed: findings have no masked variant.

import { fixed } from '../signalling/javafmt.ts';
import { scrub } from '../signalling/mask.ts';
import type { Flow } from '../signalling/flow.ts';
import type { EncryptedCensus, Finding, Journey, TraceWindow } from '../types.ts';
import { pcellAt } from './lanes.ts';
import { uniqueIds } from './markers.ts';
import { channelName, clock, count, markerTitle, seconds, shortCell, shortClock, spoken } from './text.ts';

/** What the tail quotes about the capture. */
export interface FindingFacts {
  traceDurationMs: number;
  traceWindow: TraceWindow | null;
  encrypted: EncryptedCensus;
}

/** NR data this long past an inferred NR-leg end means the inference was early (J8). */
const PHY_OUTLIVED_MS = 500;

export function findings(flow: Flow, journey: Omit<Journey, 'findings' | 'tiles'>, facts: FindingFacts): Finding[] {
  const timed: Finding[] = [];
  const { markers, states } = journey;
  const on = (t: number) => {
    const s = pcellAt(journey.cells, t);
    return s ? ` on ${shortCell(s)}` : '';
  };

  // Switched off, and when the radio came back.
  for (const m of markers) {
    if (m.kind !== 'detachSwitchOff') continue;
    const off = states.find((s) => s.state === 'radioOff' && s.startMs >= m.tMs - 0.5 && s.startMs <= m.tMs + 2_000.5);
    if (off && !off.openAtEnd) {
      timed.push(finding(`radioOffOn-${m.event}`, 'radioOffOn', `Switched off (switch-off detach)${on(m.tMs)} at ${clock(m.tMs)}; radio back ${seconds(off.endMs - off.startMs)} later.`, m.tMs, m.event));
    } else {
      // J3: nothing heard after it, so nothing is said about a restart.
      timed.push(finding(`switchedOffAtEnd-${m.event}`, 'switchedOffAtEnd', `Switched off at the end: switch-off detach${on(m.tMs)} at ${clock(m.tMs)}.`, m.tMs, m.event));
    }
  }

  // Attach or registration, and whether it was a re-attach after the switch-off.
  const reattached = markers.filter((m) => m.kind === 'reattach' && m.to).map((m) => m.to!);
  for (const m of markers) {
    if (m.kind !== 'attach') continue;
    const seg = m.to ? journey.cells.find((c) => c.lane === 'pcell' && sameAs(c.cell, m.to!) && c.endMs >= m.tMs) : undefined;
    const place = seg ? ` on ${shortCell(seg)} (${channelName(seg.cell)} ${seg.cell.earfcn})` : '';
    const took = m.durationMs === undefined ? '' : ` in ${spoken(m.durationMs)}`;
    const re = !!m.to && reattached.some((c) => sameAs(c, m.to!));
    const verb = m.title === 'Registration' ? (re ? 'Re-registered' : 'Registered') : re ? 'Re-attached' : 'Attached';
    timed.push(finding(`${re ? 'reattach' : 'attach'}-${m.event}`, re ? 'reattach' : 'attach', `${verb}${place}${took}.`, m.tMs, m.event));
  }

  // PDN connections beyond the attach's default bearer (the IMS one, typically).
  for (const p of flow.procedures) {
    if (p.outcome !== 'SUCCEEDED' || !(p.name === 'PDN connectivity' || p.name.startsWith('PDU session'))) continue;
    const e = flow.events[p.first];
    if (!e) continue;
    const apn = p.detail === null ? null : scrub(p.detail);
    const ims = apn?.toLowerCase().startsWith('ims') ?? false;
    const what = p.name === 'PDN connectivity' ? 'PDN connected' : 'PDU session established';
    timed.push(ims
      ? finding(`imsPdn-${p.first}`, 'imsPdn', `IMS ${what} in ${spoken(p.durationMs)}.`, e.sinceStartMs, p.first)
      : finding(`pdn-${p.first}`, 'other', `${what}${apn ? ` (${apn})` : ''} in ${spoken(p.durationMs)}.`, e.sinceStartMs, p.first));
  }

  // The NR leg, and whether NR data outlived its inferred end.
  for (const s of journey.cells) {
    if (s.lane !== 'pscell') continue;
    const add = markers.find((m) => m.kind === 'scgAdd' && Math.abs(m.tMs - s.startMs) < 0.5);
    timed.push(finding(`endcAdded-${add?.event ?? Math.floor(s.startMs)}`, 'endcAdded', `5G NR leg added at ${clock(s.startMs)} (NR-ARFCN ${s.cell.earfcn}, PCI ${s.cell.pci}, ${s.band}).`, s.startMs, add?.event));
    if (s.endInferred && s.phyLastMs !== undefined && s.phyLastMs > s.endMs + PHY_OUTLIVED_MS) {
      timed.push({
        id: `scgPhyOutlived-${Math.floor(s.endMs)}`,
        kind: 'scgPhyOutlived',
        severity: 'warning',
        text: `NR data continued ${seconds(s.phyLastMs - s.endMs)} after the NR leg's inferred end at ${clock(s.endMs)}.`,
        tMs: s.endMs,
      });
    }
  }

  // Moves.
  for (const m of markers) {
    if (m.kind === 'handover') {
      const took = m.durationMs === undefined ? '' : ` in ${spoken(m.durationMs)}`;
      timed.push(finding(`handover-${m.event ?? Math.floor(m.tMs)}`, 'handover', `${markerTitle(m, journey)}${took}.`, m.tMs, m.event));
    } else if (m.kind === 'reselection') {
      timed.push(finding(`reselection-${m.event ?? Math.floor(m.tMs)}`, 'other', `${markerTitle(m, journey)} (idle) at ${clock(m.tMs)}.`, m.tMs, m.event));
    }
  }

  // Carrier aggregation.
  const scells = journey.cells.filter((c) => c.lane === 'scell');
  if (scells.length) {
    const first = scells.reduce((a, b) => (b.startMs < a.startMs ? b : a));
    const pcis = new Set(scells.map((s) => s.cell.pci));
    const onPci = pcis.size === 1 ? ` on PCI ${[...pcis][0]}` : '';
    timed.push(finding('carrierAggregation', 'carrierAggregation', `Carrier aggregation: ${scells.length} ${scells.length === 1 ? 'SCell' : 'SCells'}${onPci} (${scells.map((s) => s.band).join(', ')}), from ${clock(first.startMs)}.`, first.startMs));
  }

  // Failures and warnings, by time with the rest. A failed procedure whose own answer is already a failure marker
  // (the Registration reject) is told once, at the reject.
  const failedAt = new Set(markers.filter((m) => m.severity === 'failure' && m.event !== undefined).map((m) => m.event));
  for (const m of markers) {
    if (m.severity === 'info') continue;
    if (m.kind === 'failure' && m.endEvent !== undefined && m.endEvent !== m.event && failedAt.has(m.endEvent)) continue;
    const kind = m.severity === 'failure' ? 'failure' : 'warning';
    timed.push({ id: m.id.startsWith(`${kind}-`) ? m.id : `${kind}-${m.id}`, kind, severity: m.severity, text: problemText(flow, m, journey, on), tMs: m.tMs, ...(m.event === undefined ? {} : { event: m.event }) });
  }

  const ordered = timed.map((f, i) => ({ f, i })).sort((a, b) => (a.f.tMs ?? 0) - (b.f.tMs ?? 0) || a.i - b.i).map((e) => e.f);
  return uniqueIds([...ordered, ...tail(flow, ordered, journey, facts)]);
}

const sameAs = (a: { earfcn: number; pci: number; nr: boolean }, b: { earfcn: number; pci: number; nr: boolean }) =>
  a.earfcn === b.earfcn && a.pci === b.pci && a.nr === b.nr;

function finding(id: string, kind: Finding['kind'], text: string, tMs?: number, event?: number): Finding {
  const f: Finding = { id, kind, severity: 'info', text };
  if (tMs !== undefined) f.tMs = tMs;
  if (event !== undefined) f.event = event;
  return f;
}

function problemText(flow: Flow, m: Journey['markers'][number], journey: Omit<Journey, 'findings' | 'tiles'>, on: (t: number) => string): string {
  const at = clock(m.tMs);
  const detail = m.detail ? `: ${m.detail}` : '';
  switch (m.kind) {
    case 'redirect':
    case 'reestablishment':
      return `${markerTitle(m, journey)} at ${at}.`;
    case 'cellChange':
      return `${markerTitle(m, journey)} at ${at}: changed cell while connected without a logged handover.`;
    case 'warning':
      return `${m.title}${on(m.tMs)} at ${at}.`;
    default: {
      // 'Registration reject' -> 'Registration rejected', with the procedure's duration when there is one.
      if (/ reject$/i.test(m.title)) {
        const p = flow.procedures.find((x) => x.outcome === 'FAILED' && x.last === m.event);
        const took = p ? ` after ${spoken(p.durationMs)}` : '';
        return `${m.title.slice(0, -7)} rejected${on(m.tMs)}${took} at ${at}${detail}.`;
      }
      if (m.title === 'Connection lost') return `Connection lost${on(m.tMs)} at ${at}, with no release logged (typically a radio link failure).`;
      return `${m.title}${on(m.tMs)} at ${at}${detail}.`;
    }
  }
}

function tail(flow: Flow, timed: Finding[], journey: Omit<Journey, 'findings' | 'tiles'>, facts: FindingFacts): Finding[] {
  const out: Finding[] = [];
  const failures = timed.filter((f) => f.kind === 'failure').length;
  const warnings = timed.filter((f) => f.kind === 'warning').length;
  const total = flow.procedures.length;
  const unanswered = flow.procedures.filter((p) => p.outcome === 'UNANSWERED').length;
  if (failures > 0) {
    const w = warnings ? ` and ${warnings} warning${warnings === 1 ? '' : 's'}` : '';
    out.push({ id: 'failures', kind: 'failures', severity: 'failure', text: `${failures} failure${failures === 1 ? '' : 's'}${w} in this capture.` });
  } else {
    const text = total === 0
      ? 'No failures logged.'
      : unanswered === 0
      ? `No failures: ${total} procedure${total === 1 ? '' : 's'}, all answered.`
      : `No failures; ${unanswered} of ${total} procedures got no answer.`;
    out.push({ id: 'noFailures', kind: 'noFailures', severity: 'info', text });
  }
  const census = facts.encrypted;
  if (census.records > 0) {
    const codes = census.byCode ? Object.keys(census.byCode) : [];
    const nrPhy = codes.length > 0 && codes.every((c) => {
      const v = parseInt(c, 16);
      return v >= 0xb800 && v <= 0xb9ff;
    });
    const inCodes = census.codes > 0 ? ` in ${census.codes} log code${census.codes === 1 ? '' : 's'}` : '';
    out.push({ id: 'encryptedRecords', kind: 'encryptedRecords', severity: 'info', text: `${count(census.records)} ${nrPhy ? 'NR PHY records' : 'records'}${inCodes} were encrypted by the modem and can't be read.` });
  }
  const traceMs = facts.traceDurationMs > 0 ? facts.traceDurationMs : journey.durationMs;
  out.push({ id: 'traceWindow', kind: 'traceWindow', severity: 'info', text: `Trace covers ${fixed(traceMs / 1_000, 1)} s${windowText(facts.traceWindow)}.` });
  return out;
}

/** ' (0:19–0:46 after you pressed the buttons; 111 of 241 trace files had already been overwritten)': the kept
 *  window is often not the seconds before the press (the modem keeps writing after it and the archive keeps the
 *  newest ~128 MiB), which is what the capture guide coaches. */
function windowText(w: TraceWindow | null): string {
  if (!w || w.afterPressStartS === null || w.afterPressEndS === null) return '';
  const s = w.afterPressStartS, e = w.afterPressEndS;
  const span = s < 0
    ? `from ${shortClock(-s)} before to ${shortClock(e)} after you pressed the buttons`
    : `${shortClock(s)}–${shortClock(e)} after you pressed the buttons`;
  const over = w.filesOverwritten > 0 ? `; ${count(w.filesOverwritten)} of ${count(w.filesOnPhone)} trace files had already been overwritten` : '';
  return ` (${span}${over})`;
}
