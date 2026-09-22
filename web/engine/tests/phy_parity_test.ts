// src/phy against the reference extractor on the real capture (fixture-gated, read in place from $FT_FIXTURES):
// the 48 KPIs of phy-golden-v1.json, the summary the journey reads (phy-summary-v1.json), the reference's
// validation numbers as runtime self-checks, the strict version policy, and the shipped build (whose TS 36.213
// table is not generated yet) against the same run.

import { extractPhy } from '../src/phy/extract.ts';
import { PHY_METRIC_ORDER, TAG } from '../src/phy/metrics.ts';
import type { PhySample } from '../src/types.ts';
import { gate } from '../tools/fixtures.ts';
import { readJson } from '../tools/golden.ts';
import { assert, assertAlmost, assertEquals } from './assert.ts';
import {
  CENSUS,
  endsDiff,
  type Golden,
  loadCapture,
  PHY_GOLDEN,
  PHY_SUMMARY,
  QMDL,
  statsDiff,
  TBS_REFERENCE,
} from './phy_support.ts';

Deno.test({
  name: 'phy: the 48 KPIs of phy-golden-v1.json (counts, min/max/mean, first and last samples)',
  ignore: gate(QMDL, PHY_GOLDEN, TBS_REFERENCE),
  fn: async () => {
    const { run } = await loadCapture();
    const golden: Golden = await readJson(PHY_GOLDEN);
    const kpis: Record<string, Golden> = golden.kpis;
    assertEquals(Object.keys(kpis).length, 48);
    // The golden is the v1 contract's 48 KPIs, which are the first 48 metrics; the decoders added since (0xB126,
    // 0xB12A, 0xB16C, 0xB179, 0xB063, 0x184C) come after them and are asserted in phy_records_test.ts.
    const v1 = PHY_METRIC_ORDER.slice(0, 48);
    assertEquals([...Object.keys(kpis)].sort(), [...v1].sort(), 'the golden names every v1 PhyMetric');
    const present = new Set(run.capture.series.map((s) => s.metric));
    assertEquals(
      run.capture.series.map((s) => s.metric),
      PHY_METRIC_ORDER.filter((m) => present.has(m)),
      'one series per metric, in PhyMetric order',
    );
    assertEquals(
      run.capture.series.filter((s) => kpis[s.metric]).map((s) => s.metric),
      v1,
      'every v1 metric still has a series',
    );
    const diffs: string[] = [];
    for (const s of run.capture.series) {
      const g = kpis[s.metric];
      if (!g) continue; // added after the v1 goldens
      if (s.unit !== g.unit) diffs.push(`${s.metric} unit ${s.unit} != ${g.unit}`);
      if (s.code !== g.code) diffs.push(`${s.metric} code ${s.code} != ${g.code}`);
      if (s.samples.length !== g.samples) diffs.push(`${s.metric} samples ${s.samples.length} != ${g.samples}`);
      if (g.perIndex) {
        g.perIndex.forEach((want: Golden, i: number) => {
          const v = s.samples.flatMap((
            x,
          ) => (x.perIndex && x.perIndex[i] !== null && x.perIndex[i] !== undefined ? [x.perIndex[i]!] : []));
          diffs.push(...statsDiff(v, want, `${s.metric}[${i}]`));
        });
      } else {
        diffs.push(...statsDiff(s.samples.flatMap((x) => (x.value === null ? [] : [x.value])), g, s.metric));
      }
      // The reference appends 0xB14D's CSI samples after 0xB14E's; the series keeps one time order.
      let ordered: PhySample[] = s.samples;
      if (s.metric === 'lte_cqi_wideband_cw0' || s.metric === 'lte_ri' || s.metric === 'lte_pmi_wideband') {
        ordered = [
          ...s.samples.filter((x) => x.tag === TAG.puschCsf),
          ...s.samples.filter((x) => x.tag === TAG.pucchCsf),
        ];
      }
      diffs.push(...endsDiff(ordered.slice(0, 3), g.first, `${s.metric} first`));
      diffs.push(...endsDiff(ordered.slice(-3), g.last, `${s.metric} last`));
      for (let i = 1; i < s.samples.length; i++) {
        if (s.samples[i].tMs < s.samples[i - 1].tMs) {
          diffs.push(`${s.metric} not in time order at ${i}`);
          break;
        }
      }
    }
    assertEquals(diffs, []);
    assertEquals(run.capture.versionMisses, {}, 'every record is in a validated version');
    // 0xB179's own length identity rejects 4 of its 373 records; everything else parses (see phy_records_test.ts).
    assertEquals(run.stats.malformed, { '0xB179': 4 });
    assertEquals(run.stats.unstamped, {}, 'no PHY record needs an interpolated time, and 0xB179 places itself by TTI');
  },
});

Deno.test({
  name: 'phy: the summary of phy-summary-v1.json (SCells, NR DL without an earfcn, RACH, antennas)',
  ignore: gate(QMDL, PHY_SUMMARY, TBS_REFERENCE),
  fn: async () => {
    const got = (await loadCapture()).run.capture.summary;
    const want: Golden = await readJson(PHY_SUMMARY);
    assertEquals(got.scellActivity.length, want.scellActivity.length);
    got.scellActivity.forEach((a, i) => {
      const b = want.scellActivity[i];
      assertEquals(
        [a.index, a.earfcn, a.pci, a.records, a.source],
        [b.index, b.earfcn, b.pci, b.records, b.source],
        `scell ${i}`,
      );
      assertAlmost(a.firstMs, b.firstMs, 1.0);
      assertAlmost(a.lastMs, b.lastMs, 1.0);
    });
    const nr = got.nrDlActivity!, wantNr = want.nrDlActivity;
    assertEquals(wantNr.earfcn, null, 'v1: the NR DL earfcn is left to the journey');
    assert(!('earfcn' in nr), 'nor does the engine name one');
    assertEquals([nr.index, nr.pci, nr.records, nr.source], [wantNr.index, wantNr.pci, wantNr.records, wantNr.source]);
    assertAlmost(nr.firstMs, wantNr.firstMs, 1.0);
    assertAlmost(nr.lastMs, wantNr.lastMs, 1.0);
    assertEquals(got.rach.length, want.rach.length);
    got.rach.forEach((a, i) => {
      const b = want.rach[i];
      assertEquals([a.ta, a.ulEarfcn, a.preambleTargetDbm], [b.ta, b.ulEarfcn, b.preambleTargetDbm], `rach ${i}`);
      assertAlmost(a.tMs, b.tMs, 1.0);
      // TA x 78.12 m (J10 and Spectrum.kt); the reference multiplies by 78.125, so TA 19 reads 1484.3, not 1484.4.
      assertAlmost(a.distanceM!, b.distanceM, 0.15);
    });
    assertEquals(got.txAntennasMib, want.txAntennasMib);
    assertEquals(got.rxAntennasByEarfcn, want.rxAntennasByEarfcn);
    // v1 knew nothing of the measured antenna configuration; it is additional, not a change to what was there.
    assert(got.measuredAntennas!.length > 0, '0xB126 now measures the antennas per serving cell');
  },
});

Deno.test({
  name: "phy: the self-checks reproduce the reference's validation, and all pass",
  ignore: gate(QMDL, TBS_REFERENCE),
  fn: async () => {
    const { run } = await loadCapture();
    const s = run.stats;
    for (let rx = 0; rx < 4; rx++) {
      const r = s.rsrqResidual.get(rx)!;
      assert(Math.abs(r.mean) < 0.01 && r.sd < 0.1, `Rx${rx}: mean ${r.mean} sd ${r.sd} n ${r.n}`);
    }
    // N_RB per EARFCN from the identity itself (the reference hard-coded {975: 25} and 50 elsewhere).
    assertEquals([...s.inferredPrb.entries()], [[650, 50], [975, 25], [5110, 50], [67086, 50]]);
    assertEquals(s.dlTbs, { table64: 2632, table256: 644, retx: 27, unexplained: 0 });
    assertEquals(s.ul, { unique: 5270, ambiguous: 28, uciOnly: 67, noMatch: 0 });
    assertEquals(s.nr, {
      b887Records: 497,
      b887CrcFail: 27,
      b887PassBytes: 653_592,
      deltaDecodes: 497,
      deltaCrcFail: 27,
      deltaPassBytes: 653_592,
    });
    assertEquals(s.nrTbs, { matched: 472, retx: 25, unexplained: 0, controlMatched: 138 });
    assertEquals(s.b888Identity, { holds: 602, records: 602 });
    assertEquals([s.macSamples, s.macConsistent], [4537, 4537]);
    const checks = run.capture.checks;
    assertEquals(checks.map((c) => c.id), [
      'b193RsrqIdentity',
      'b173TbsTable',
      'b139TbsModulation',
      'b887TbsFormula',
      'b887VsB888',
      'b888CounterIdentity',
      'b064HeaderAccounting',
      'ttiAxisLatency',
      'b126PrbBitmap',
      'b126Rank',
      'b126TxAntennas',
      'b12aCfi',
      'b16cUplinkGrant',
      'b16cGrantTiming',
      'b179Length',
      'b179ServingRsrp',
      'b063VsB173',
      'b063Coverage',
      'x184cFraming',
      'x184cSubframeField',
      'x184cAgainstLimit',
      'x1d0bSequence',
    ]);
    for (const c of checks) assert(c.passed, `${c.id}: ${c.measured}`);
  },
});

Deno.test({
  name: 'phy: the shipped extractor equals the reference run apart from what needs the TS 36.213 table',
  ignore: gate(QMDL, TBS_REFERENCE),
  fn: async () => {
    const { records, timeBase, run } = await loadCapture();
    const shipped = extractPhy(records, timeBase, CENSUS);
    const without = (s: typeof shipped.series) => s.filter((x) => x.metric !== 'lte_ul_mcs_derived');
    assertEquals(without(shipped.series), without(run.capture.series));
    assertEquals(shipped.summary, run.capture.summary);
    // Until src/phy/lteTbsTable.ts is generated: no derived UL MCS, no table checks, and the catalogue says why.
    assert(!shipped.series.some((x) => x.metric === 'lte_ul_mcs_derived'));
    assertEquals(shipped.checks.map((c) => c.id), [
      'b193RsrqIdentity',
      'b887TbsFormula',
      'b887VsB888',
      'b888CounterIdentity',
      'b064HeaderAccounting',
      'ttiAxisLatency',
      'b126PrbBitmap',
      'b126Rank',
      'b126TxAntennas',
      'b12aCfi',
      'b16cUplinkGrant',
      'b16cGrantTiming',
      'b179Length',
      'b179ServingRsrp',
      'b063VsB173',
      'b063Coverage',
      'x184cFraming',
      'x184cSubframeField',
      'x184cAgainstLimit',
      'x1d0bSequence',
    ]);
    assert(shipped.availability.some((a) => a.id === 'lteTbsTable'));
    assert(!run.capture.availability.some((a) => a.id === 'lteTbsTable'));
    // The census reaches the encrypted-records entry; the not-decoded-yet entries carry this capture's counts.
    const enc = shipped.availability.find((a) => a.id === 'nrPhyEncrypted')!;
    assert(enc.reason.includes('23,764 encrypted records across 61 codes'), enc.reason);
    const counts = Object.fromEntries(
      shipped.availability.map((a) => [a.id, /This capture: ([\d,]+) records/.exec(a.reason)?.[1] ?? null]),
    );
    assertEquals([counts.nrUlSchedule, counts.nrUlPower, counts.nrDci, counts.nrCsf, counts.b134], [
      '633',
      '605',
      '632',
      '42',
      '4,888',
    ]);
  },
});

Deno.test({
  name: 'phy: series metadata (sections, titles, units, confidence, badges, versions)',
  ignore: gate(QMDL, TBS_REFERENCE),
  fn: async () => {
    const { run } = await loadCapture();
    const by = Object.fromEntries(run.capture.series.map((s) => [s.metric, s]));
    assertEquals(by.lte_ul_phy_throughput.badges, ['UL scheduled']);
    assertEquals(by.lte_ul_mcs_derived.confidence, 'derived');
    assertEquals(by.lte_pusch_tx_power_required.badges, ['before Pcmax', 'medium confidence']);
    assertEquals([by.lte_ri.confidence, by.lte_ri.version, by.lte_ri.code], ['medium', '164', '0xB14E']);
    assertEquals([by.lte_rsrp.section, by.lte_rsrp.version], ['signal', '1/0x19 v66']);
    assertEquals([by.nr_dl_mcs.section, by.nr_dl_mcs.version, by.nr_dl_mcs.unit], [
      'nr',
      '3.13',
      'index (qam256 table)',
    ]);
    assertEquals(by.lte_timing_advance_rar.section, 'rach');
    for (const s of run.capture.series) assert(s.title.length > 0 && s.unit.length > 0 && s.version, s.metric);
    // TxD: 4 layers with one transport block (53 records) is tagged, as are the 2 records with 3 layers.
    const layers = by.lte_dl_layers.samples;
    assertEquals(layers.filter((x) => x.tag === TAG.txDiversity).length, layers.filter((x) => x.value === 4).length);
    assert(layers.filter((x) => x.tag === TAG.txDiversity).length > 0);
    assertEquals(layers.filter((x) => x.tag === TAG.unverified).length, layers.filter((x) => x.value === 3).length);
    // Samples that carry only a carrier index say so, and name no EARFCN (the journey attributes them).
    for (
      const m of [
        'lte_dl_mcs',
        'lte_ul_prb',
        'lte_cqi_wideband_cw0',
        'lte_mac_ul_grant',
        'lte_dl_bler',
        'nr_dl_mcs',
      ] as const
    ) {
      assert(by[m].samples.every((x) => x.carrier !== undefined && x.earfcn === undefined), m);
    }
    // Serving measurements name their cell; neighbours carry no carrier index.
    assert(by.lte_rsrp.samples.every((x) => x.earfcn !== undefined && x.pci !== undefined && x.carrier !== undefined));
    assert(by.lte_neighbour_rsrp.samples.every((x) => x.carrier === undefined && x.tag === TAG.neighbour));
  },
});
