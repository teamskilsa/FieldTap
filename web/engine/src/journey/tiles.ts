// KPI tiles in the operator groups MobileInsight's KPI manager uses (Accessibility, Mobility, Retainability,
// Integrity), from the parity procedures and connections, plus EN-DC from the journey and the Integrity peaks from
// the PHY series. Durations are the ladder's strings (CallFlowPresentation.duration: '70.2 ms', 'median 34.9 ms').

import { fixed } from '../signalling/javafmt.ts';
import type { Flow } from '../signalling/flow.ts';
import { duration, medianMs } from '../signalling/presentation.ts';
import type { JourneyCell, Marker, PhySeries, Tile, TileGroup } from '../types.ts';
import { isReestablishmentRequest } from './context.ts';

export function tiles(flow: Flow, markers: readonly Marker[], cells: readonly JourneyCell[], series: readonly PhySeries[] = []): Tile[] {
  const out: Tile[] = [];
  const procedureTile = (id: string, group: TileGroup, title: string, names: string[]) => {
    const items = flow.procedures.filter((p) => names.includes(p.name));
    if (!items.length) return;
    const ok = items.filter((p) => p.outcome === 'SUCCEEDED');
    const t: Tile = { id, group, title, succeeded: ok.length, attempts: items.length, event: (items.find((p) => p.outcome !== 'SUCCEEDED') ?? items[0]).first };
    const m = medianMs(items);
    if (m !== null) t.value = ok.length > 1 ? `median ${duration(m)}` : duration(m);
    out.push(t);
  };
  procedureTile('rrcSetup', 'Accessibility', 'RRC setup', ['RRC connection setup', 'RRC setup']);
  procedureTile('serviceRequest', 'Accessibility', 'Service request', ['Service request']);
  procedureTile('attach', 'Accessibility', 'Attach', ['Attach']);
  procedureTile('registration', 'Accessibility', 'Registration', ['Registration']);
  procedureTile('pdn', 'Accessibility', 'PDN', ['PDN connectivity', 'PDU session establishment']);
  procedureTile('handover', 'Mobility', 'Handover', ['Handover']);

  const adds = markers.filter((m) => m.kind === 'scgAdd');
  if (adds.length) {
    const t: Tile = { id: 'scgAdd', group: 'EN-DC', title: 'SCG add', succeeded: adds.filter((m) => m.to).length, attempts: adds.length };
    const pscell = cells.find((c) => c.lane === 'pscell');
    if (pscell) t.value = pscell.band;
    if (adds[0].event !== undefined) t.event = adds[0].event;
    out.push(t);
  }

  // Retainability: connections that ended without a release (radio link failure) plus re-establishments.
  const established = flow.connections.filter((c) => c.established).length;
  const lost = flow.connections.filter((c) => c.outcome === 'LOST');
  const reestablishments = flow.events.flatMap((e, i) => (isReestablishmentRequest(e) ? [i] : []));
  const abnormal = lost.length + reestablishments.length;
  const r: Tile = {
    id: 'abnormalReleases',
    group: 'Retainability',
    title: 'Abnormal releases',
    succeeded: abnormal,
    attempts: established,
    value: `${abnormal} of ${established} connection${established === 1 ? '' : 's'}`,
  };
  const at = lost[0]?.last ?? reestablishments[0];
  if (at !== undefined && at !== null) r.event = at;
  out.push(r);

  out.push(...peaks(series));
  return out;
}

/**
 * Integrity: the LTE DL PHY and NR MAC throughput peaks. The LTE bins are per (UTC second, carrier), so a second's
 * carriers are added first: with CA the peak is the phone's, not one carrier's. The NR values are already rates
 * over each counter window, so the peak is the highest window (summed across NR carriers at one instant).
 */
export function peaks(series: readonly PhySeries[]): Tile[] {
  const out: Tile[] = [];
  const lte = series.find((s) => s.metric === 'lte_dl_phy_throughput');
  if (lte) {
    const perSecond = new Map<number, number>();
    for (const s of lte.samples) if (s.value !== null) perSecond.set(s.tMs, (perSecond.get(s.tMs) ?? 0) + s.value);
    const peak = Math.max(...perSecond.values());
    if (Number.isFinite(peak)) out.push({ id: 'lteDlPeak', group: 'Integrity', title: 'LTE DL PHY peak', succeeded: 0, attempts: 0, value: `${fixed(peak, 1)} Mbit/s` });
  }
  const nr = series.find((s) => s.metric === 'nr_dl_mac_throughput');
  if (nr) {
    const atOnce = new Map<number, number>();
    for (const s of nr.samples) if (s.value !== null) atOnce.set(s.tMs, (atOnce.get(s.tMs) ?? 0) + s.value);
    const peak = Math.max(...atOnce.values());
    if (Number.isFinite(peak)) out.push({ id: 'nrDlPeak', group: 'Integrity', title: 'NR MAC peak', succeeded: 0, attempts: 0, value: `${fixed(peak, 1)} Mbit/s` });
  }
  return out;
}
