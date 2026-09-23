// Carrier attribution (CONTRACT.md v1 amendments): 0xB173, 0xB139, the CSF records and 0xB064 carry only a
// carrier index, and the NR DL records only a PCI. Index 0 is the PCell at that moment and index k the SCell of
// that index, so each such sample is mapped to a cell through the journey's lanes at its time; NR DL samples go to
// the PSCell (up to its last NR PHY record, which may outlive an inferred end).
//
// Where no lane covers the sample, the records decide: the nearest 0xB193 serving measurement on the same carrier
// index, which names its EARFCN and PCI, within 500 ms (FTPhy's PhyCarriers.swift). That places the PHY records
// logged before the capture's first RRC message (no PCell lane yet), in the moments after an RRC release, and at
// the edges of an SCell's measured window, all of which the lanes alone leave out.

import type { Cell, Journey, JourneyCell, PhyMetric, PhySample, PhySeries } from '../types.ts';

/** The series whose samples name no cell of their own (the measurement records name theirs). */
const CARRIER_INDEXED: ReadonlySet<PhyMetric> = new Set<PhyMetric>([
  'lte_dl_mcs', 'lte_dl_prb', 'lte_dl_tbs', 'lte_dl_modulation', 'lte_dl_crc_ok', 'lte_dl_layers', 'lte_dl_bler', 'lte_dl_phy_throughput',
  'lte_ul_prb', 'lte_ul_tbs', 'lte_ul_modulation', 'lte_ul_code_rate', 'lte_pusch_tx_power_required', 'lte_ul_mcs_derived', 'lte_ul_phy_throughput',
  'lte_cqi_wideband_cw0', 'lte_ri', 'lte_pmi_wideband', 'lte_csf_tx_mode', 'lte_cqi_wideband_cw1', 'lte_mac_ul_grant', 'lte_power_headroom',
  'lte_timing_advance_rar',
]);

const NR_DL: ReadonlySet<PhyMetric> = new Set<PhyMetric>(['nr_dl_mcs', 'nr_dl_prb', 'nr_dl_layers', 'nr_dl_tbs', 'nr_dl_modulation', 'nr_dl_crc_ok', 'nr_dl_bler', 'nr_dl_mac_throughput']);

/** 0xB193 reports each serving cell about every 40 ms while connected; farther than this, it says nothing. */
export const MEASUREMENT_REACH_MS = 500;

/** The cell carrier index `carrier` was on at `tMs`, from the journey's lanes. */
export function cellForCarrier(journey: Pick<Journey, 'cells'>, carrier: number, tMs: number): JourneyCell | undefined {
  if (carrier === 0) {
    // The last covering PCell segment, so a move instant belongs to the new cell.
    let found: JourneyCell | undefined;
    for (const c of journey.cells) if (c.lane === 'pcell' && covers(c, tMs)) found = c;
    return found;
  }
  return journey.cells.find((c) => c.lane === 'scell' && c.index === carrier && covers(c, tMs));
}

/** The PSCell whose NR PHY activity covers `tMs` (its segment, stretched to its last NR PHY record). */
export function pscellAt(journey: Pick<Journey, 'cells'>, tMs: number, pci?: number): JourneyCell | undefined {
  return journey.cells.find((c) =>
    c.lane === 'pscell' && (pci === undefined || c.cell.pci === pci) && tMs >= c.startMs && tMs <= Math.max(c.endMs, c.phyLastMs ?? -Infinity)
  );
}

const covers = (c: JourneyCell, t: number) => t >= c.startMs && (t < c.endMs || (t === c.endMs && !!c.openAtEnd));

/** Per carrier index, the serving measurements in time order: where the records alone place a carrier. */
class Measured {
  private readonly byCarrier = new Map<number, { t: number; cell: Cell }[]>();

  constructor(series: readonly PhySeries[]) {
    for (const x of series.find((s) => s.metric === 'lte_rsrp')?.samples ?? []) {
      if (x.carrier === undefined || x.earfcn === undefined || x.pci === undefined) continue;
      let list = this.byCarrier.get(x.carrier);
      if (!list) this.byCarrier.set(x.carrier, (list = []));
      list.push({ t: x.tMs, cell: { earfcn: x.earfcn, pci: x.pci, nr: false } });
    }
  }

  /** The cell of the nearest measurement on `carrier` within MEASUREMENT_REACH_MS of `t`. */
  nearest(carrier: number, t: number): Cell | undefined {
    const list = this.byCarrier.get(carrier);
    if (!list?.length) return undefined;
    let lo = 0, hi = list.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (list[mid].t < t) lo = mid + 1;
      else hi = mid;
    }
    const before = list[lo - 1], after = list[lo];
    const best = !before ? after : !after ? before : t - before.t <= after.t - t ? before : after;
    return best && Math.abs(best.t - t) <= MEASUREMENT_REACH_MS ? best.cell : undefined;
  }
}

/** `series` with `cell` set on every carrier-indexed and NR DL sample that can be placed; the rest unchanged. */
export function attributeCarriers(series: readonly PhySeries[], journey: Pick<Journey, 'cells'>): PhySeries[] {
  const measured = new Measured(series);
  return series.map((s) => {
    const nr = NR_DL.has(s.metric);
    if (!nr && !CARRIER_INDEXED.has(s.metric)) return s;
    const samples = s.samples.map((x): PhySample => {
      let cell: Cell | undefined;
      if (nr) cell = pscellAt(journey, x.tMs, x.pci)?.cell;
      else if (x.carrier !== undefined) cell = cellForCarrier(journey, x.carrier, x.tMs)?.cell ?? measured.nearest(x.carrier, x.tMs);
      return cell ? { ...x, cell: { earfcn: cell.earfcn, pci: cell.pci, nr: cell.nr } } : x;
    });
    return { ...s, samples };
  });
}
