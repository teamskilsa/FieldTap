// The decoders added after the v1 goldens - 0xB126, 0xB12A, 0xB16C, 0xB179, 0xB063 and 0x184C, plus the 0x1D0B
// clocks - against BOTH real captures (fixture-gated, read in place from $FT_FIXTURES), asserting the numbers
// docs/research/iphone-named-log-codes.md and iphone-unknown-log-codes.md validated them with:
//
//   capture2.qmdl          driving, 22.1 s, B12 -> B2 with carrier aggregation, EN-DC on n77 (30 kHz)
//   iphone-recovered.qmdl  stationary attach, 27.0 s, B66/B12/B2 with two handovers, EN-DC on n5 (15 kHz)
//
// Exact counts are asserted where the research states one (byte totals, record and element counts, the CFI
// histogram); everything else is asserted as a share with the threshold the research proposed, so a firmware
// change shows up as a failing check rather than a plausible chart.

import { readQmdl } from '../src/diag/qmdl.ts';
import { TimeBase } from '../src/diag/timebase.ts';
import { runPhy } from '../src/phy/extract.ts';
import { BUILT_IN_TBS } from '../src/phy/lteTbs.ts';
import type { PhyCheck } from '../src/types.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { assert, assertAlmost, assertEquals } from './assert.ts';

const CAPTURES = {
  capture2: fixture('capture2/capture2.qmdl'),
  first: fixture('iphone-recovered.qmdl'),
} as const;

async function run(path: string) {
  const { records } = readQmdl(await Deno.readFile(path));
  const timeBase = TimeBase.of(records);
  return runPhy(records, timeBase, { records: 0, codes: 0 }, BUILT_IN_TBS);
}

const share = (a: number, b: number) => (b === 0 ? 0 : a / b);
const checkOf = (checks: PhyCheck[], id: string): PhyCheck => {
  const c = checks.find((x) => x.id === id);
  assert(c !== undefined, `no check ${id}`);
  return c!;
};

/** Every expected figure per capture, from the research documents. */
const EXPECTED = {
  capture2: {
    // 0xB126: 62 records x 20 sub-records, and the three identities (99.5% / 97.3%+TxD / 100% where a MIB exists).
    b126Subframes: 1240,
    b126Prb: 0.99,
    b126Rank: 0.99,
    b126TxPorts: 0.95,
    // The driving capture's two serving cells: B2 EARFCN 650 PCI 235 announces 4 ports, B12 EARFCN 5110 PCI 80 has
    // no MIB in the capture and reads 2 - the field follows the serving cell, which is what makes it an antenna count.
    antennas: [{ earfcn: 650, pci: 235, txPorts: 4, mib: 4 }, { earfcn: 5110, pci: 80, txPorts: 2, mib: undefined }],
    // 0xB12A: every element legal, and the CFI split the research measured (CFI 3 on 30% of subframes while driving).
    b12aElements: 32_140,
    cfi: { '1': 19_012, '2': 2823, '3': 9605 },
    cfi3Share: 0.305,
    // 0xB16C: 2,816 uplink grants, matched one-to-one with an 0xB139 PUSCH report four subframes later.
    grants: 2816,
    grantFields: 0.999,
    grantTiming: 0.95,
    // 0xB179: len == 28 + 12n in 380 of 385, 492 neighbour measurements, serving RSRP on 0xB193's scale.
    b179Records: 380,
    b179Malformed: 5,
    neighbourMeasurements: 492,
    b179Within1Db: 0.9,
    // 0xB063: the byte totals and the coverage the research reports (85% of 0xB173's bytes, 80% of the blocks).
    macDeclared: 1230,
    macWalked: 978,
    macBytes: 655_956,
    macPadding: 18_880,
    paddingShare: 0.029,
    macTb: 0.98,
    // 0x184C: the block walk closes on 2,391 of 2,393 records.
    x184cRecords: 2393,
    x184cFramed: 2391,
    // 0x1D0B: 1,914 records, and the four holes the 1024 Hz clock measures across the switch-off detach.
    clockRecords: 1914,
    clockGaps: [2227, 1127, 968, 605],
    clockMissingMs: 5350,
  },
  first: {
    b126Subframes: 2360,
    b126Prb: 0.99,
    b126Rank: 0.99,
    b126TxPorts: 0.99,
    antennas: [{ earfcn: 67_086, pci: 80, txPorts: 4, mib: 4 }, { earfcn: 5110, pci: 235, txPorts: 4, mib: 4 }, {
      earfcn: 650,
      pci: 80,
      txPorts: 4,
      mib: 4,
    }],
    b12aElements: 26_680,
    cfi: { '1': 19_699, '2': 3364, '3': 1734 },
    cfi3Share: 0.07,
    grants: 4763,
    grantFields: 0.999,
    grantTiming: 0.95,
    b179Records: 369,
    b179Malformed: 4,
    neighbourMeasurements: 265,
    b179Within1Db: 0.9,
    macDeclared: 3085,
    macWalked: 2521,
    macBytes: 2_235_835,
    macPadding: 41_730,
    paddingShare: 0.019,
    macTb: 0.98,
    x184cRecords: 4465,
    x184cFramed: 4464,
    clockRecords: 2238,
    clockGaps: [2537, 1192, 473, 396],
    clockMissingMs: 5475,
  },
} as const;

for (const name of ['capture2', 'first'] as const) {
  const path = CAPTURES[name];
  const want = EXPECTED[name];

  Deno.test({
    name: `phy records on ${name}: 0xB126 antennas, rank and PRB bitmap against 0xB173 and the MIB`,
    ignore: gate(path),
    fn: async () => {
      const { stats, capture } = await run(path);
      const b = stats.b126;
      assertEquals(b.subframes, want.b126Subframes, '20 sub-records per record');
      assert(share(b.prbMatched, b.prbChecked) >= want.b126Prb, `PRB bitmap ${b.prbMatched}/${b.prbChecked}`);
      assert(share(b.rankMatched, b.rankChecked) >= want.b126Rank, `rank ${b.rankMatched}/${b.rankChecked}`);
      assert(
        share(b.txPortsMatched, b.txPortsChecked) >= want.b126TxPorts,
        `tx ports ${b.txPortsMatched}/${b.txPortsChecked}`,
      );
      // The measured antenna configuration per serving cell, which is what the Antennas section shows.
      const measured = capture.summary.measuredAntennas!;
      assertEquals(measured.length, want.antennas.length);
      for (const cell of want.antennas) {
        const got = measured.find((m) => m.earfcn === cell.earfcn && m.pci === cell.pci);
        assert(got !== undefined, `no measured antennas for ${cell.earfcn}/${cell.pci}`);
        assertEquals(got!.txPorts, cell.txPorts, `tx ports on ${cell.earfcn}/${cell.pci}`);
        assertEquals(got!.mibTxAntennas, cell.mib, `MIB antennas on ${cell.earfcn}/${cell.pci}`);
        assert([1, 2, 3, 4].includes(got!.rxAntennas), 'receive antennas are 1-4');
      }
      // The bitmap is carried as a mask and the PRB count is derived from it, never read from a second field.
      const allocation = capture.series.find((x) => x.metric === 'lte_dl_prb_allocation')!;
      assertEquals(allocation.samples.length, want.b126Subframes);
      for (const sample of allocation.samples) {
        const bits = (sample.mask ?? []).reduce((n, w) => n + popcount(w), 0);
        assertEquals(bits, sample.value, 'popcount(mask) is the PRB count');
      }
      // Byte +14 only ever holds bits 48 and 49, i.e. exactly 50 bits for a 50-PRB cell.
      assert(allocation.samples.every((x) => ((x.mask ?? [0, 0])[1] & ~0x3ffff) === 0), 'the bitmap stops at PRB 49');
      for (const id of ['b126PrbBitmap', 'b126Rank', 'b126TxAntennas']) assert(checkOf(capture.checks, id).passed, id);
    },
  });

  Deno.test({
    name: `phy records on ${name}: 0xB12A's CFI is 4 x {1,2,3}, and the PDCCH load it measures`,
    ignore: gate(path),
    fn: async () => {
      const { stats, capture } = await run(path);
      assertEquals(stats.b12a.elements, want.b12aElements);
      assertEquals(stats.b12a.consistent, want.b12aElements, 'every element is 4 x CFI or zero with the flag clear');
      const load = capture.summary.pdcchLoad!;
      assertEquals(load.cfi, want.cfi);
      assertAlmost(load.cfi3Share, want.cfi3Share, 0.01, 'subframes at CFI 3');
      assertEquals(load.subframes + load.notDecoded, want.b12aElements);
      assert(checkOf(capture.checks, 'b12aCfi').passed);
    },
  });

  Deno.test({
    name: `phy records on ${name}: 0xB16C's uplink grant equals 0xB139's four subframes later`,
    ignore: gate(path),
    fn: async () => {
      const { stats, capture } = await run(path);
      const b = stats.b16c;
      assertEquals(b.records, b.exact, 'the element chain consumes every body exactly');
      assertEquals(b.grantSubframes, want.grants);
      assert(
        share(b.fieldsMatched, b.fieldsChecked) >= want.grantFields,
        `grant fields ${b.fieldsMatched}/${b.fieldsChecked}`,
      );
      assert(
        share(b.precedesPusch, b.grantSubframes) >= want.grantTiming,
        `n+4 timing ${b.precedesPusch}/${b.grantSubframes}`,
      );
      assert(share(b.assignmentsOnPdsch, b.assignmentSubframes) >= 0.95, 'the 8-byte records land on a PDSCH subframe');
      // What the network granted against what the phone sent: equal on every matched subframe.
      const g = capture.summary.uplinkGrants!;
      assertEquals(g.prbGranted, g.prbSent, 'the matched grants and the PUSCH reports allocate the same PRBs');
      for (const id of ['b16cUplinkGrant', 'b16cGrantTiming']) assert(checkOf(capture.checks, id).passed, id);
    },
  });

  Deno.test({
    name: `phy records on ${name}: 0xB179's neighbours, its length identity and its own TTI as the time source`,
    ignore: gate(path),
    fn: async () => {
      const { stats, capture } = await run(path);
      const b = stats.b179;
      assertEquals([b.records, b.malformed], [want.b179Records, want.b179Malformed], 'len == 28 + 12 x count');
      // Every one of these records arrives with a zero DIAG timestamp, and none is counted as unstamped.
      assertEquals(capture.versionMisses, {});
      assert(stats.unstamped['0xB179'] === undefined, '0xB179 places itself by its own TTI');
      const rsrp = capture.series.find((x) => x.metric === 'lte_neighbour_rsrp_intra')!;
      assertEquals(rsrp.samples.length, want.neighbourMeasurements);
      assert(
        rsrp.samples.every((x) => x.tMs > -5000 && x.tMs < 40_000),
        'the TTI-derived times land inside the capture',
      );
      assert(rsrp.samples.every((x) => (x.value ?? 0) > -160 && (x.value ?? 0) < -30), 'RSRP is on 0xB193 scale');
      const margin = capture.series.find((x) => x.metric === 'lte_neighbour_margin')!;
      assertEquals(margin.samples.length, want.neighbourMeasurements);
      // The serving RSRP is 0xB193's own, which is what fixes the scale with no published constant taken on trust.
      assert(
        share(b.servingWithin1Db, b.servingChecked) >= want.b179Within1Db,
        `serving RSRP ${b.servingWithin1Db}/${b.servingChecked}`,
      );
      const cells = capture.summary.intraFreqNeighbours!;
      assert(cells.length > 0 && cells.some((c) => c.onlySource), 'some neighbours are measured by nothing else');
      assert(cells.every((c) => c.marginBestDb >= c.marginMedianDb), 'the best margin is at least the median');
      for (const id of ['b179Length', 'b179ServingRsrp']) assert(checkOf(capture.checks, id).passed, id);
    },
  });

  Deno.test({
    name: `phy records on ${name}: 0xB063's MAC accounting, its coverage and its transport blocks against 0xB173`,
    ignore: gate(path),
    fn: async () => {
      const { stats, capture } = await run(path);
      const b = stats.b063;
      assertEquals(
        [b.declared, b.walked],
        [want.macDeclared, want.macWalked],
        'the walk reaches about 80% of the blocks',
      );
      assert(share(b.tbMatched, b.tbChecked) >= want.macTb, `against 0xB173 ${b.tbMatched}/${b.tbChecked}`);
      const mac = capture.summary.macDl!;
      assertEquals([mac.bytes, mac.paddingBytes], [want.macBytes, want.macPadding]);
      assertAlmost(mac.paddingShare, want.paddingShare, 0.002, 'padding share');
      assertAlmost(mac.coverageShare, want.macWalked / want.macDeclared, 0.001, 'coverage is explicit');
      assert(mac.coverageShare < 0.9, 'and it is never presented as a total');
      // The signalling-versus-data split, and the timing-advance commands whose value is not in the record.
      assert(mac.channels.some((c) => c.kind === 'data') && mac.channels.some((c) => c.kind === 'signalling'));
      assert(mac.timingAdvanceCommands >= 2 && mac.timingAdvanceCommands <= 8, 'a handful of TA commands, no value');
      assert(checkOf(capture.checks, 'b063VsB173').passed);
      assert(checkOf(capture.checks, 'b063Coverage').measured.includes('declared transport blocks'));
      // 0xB173 stays the throughput source: the MAC series are bytes per second, badged as partial.
      const bytes = capture.series.find((x) => x.metric === 'lte_mac_dl_bytes')!;
      assertEquals(bytes.unit, 'bytes');
      assertEquals(bytes.badges, ['partial coverage']);
    },
  });

  Deno.test({
    name: `phy records on ${name}: 0x184C's chains and limits, and 0x1D0B's clocks as the trace-gap meter`,
    ignore: gate(path),
    fn: async () => {
      const { stats, capture } = await run(path);
      assertEquals(
        [stats.x184c.records, stats.x184c.framed],
        [want.x184cRecords, want.x184cFramed],
        'the block walk closes',
      );
      assertEquals(stats.x184c.subframesInRange, stats.x184c.blocks, "the block header's subframe field stays 0..9");
      const front = capture.summary.uplinkFrontEnd!;
      assert(front.liveChain !== undefined, 'the transmitting chain is named');
      assert(front.chains.some((c) => c.limitDbm !== undefined), 'the chain limits are logged');
      assert(front.atLimitShare > 0 && front.atLimitShare <= 1);
      // The -70 dBm sentinel is never plotted as a power.
      const power = capture.series.find((x) => x.metric === 'lte_fed_tx_power')!;
      assert(power.samples.every((x) => (x.value ?? 0) > -70), 'the off sentinel is not a measurement');
      assert(power.confidence === 'medium', 'the front-end power is medium confidence');
      // 0x1D0B: the exact seconds of trace that were never written.
      const clock = capture.summary.traceClock!;
      assertEquals(clock.records, want.clockRecords);
      const biggest = clock.gaps.map((g) => g.missingMs).sort((a, b) => b - a).slice(0, 4);
      assertEquals(biggest, [...want.clockGaps], 'the largest holes, in ms');
      assertAlmost(clock.missingMs, want.clockMissingMs, 1, 'total missing trace');
      assert(clock.gaps.every((g) => g.tMs >= 0), 'each hole is placed in time');
      for (const id of ['x184cFraming', 'x184cSubframeField', 'x1d0bSequence']) {
        assert(checkOf(capture.checks, id).passed, id);
      }
    },
  });

  Deno.test({
    name: `phy records on ${name}: every self-check passes and the 5G uplink codes stay in the not-available list`,
    ignore: gate(path),
    fn: async () => {
      const { capture } = await run(path);
      for (const c of capture.checks) assert(c.passed, `${c.id}: ${c.measured}`);
      // The rejected 5G uplink payloads are named, with their presence, their rate and the reason.
      for (const id of ['nrUlSchedule', 'nrUlPower', 'nrDci', 'nrCsf']) {
        const e = capture.availability.find((a) => a.id === id)!;
        assertEquals(e.status, 'notDecodedYet', id);
        assert(/\d+ records, \d+ per second/.test(e.reason), `${id} states its presence and rate: ${e.reason}`);
        assert(e.reason.includes('sustained 5G upload'), `${id} says what capture it needs`);
      }
      // And nothing claims a 5G uplink MCS, PRB, TBS, power or CQI series.
      for (const s of capture.series) {
        assert(!['0xB883', '0xB884', '0xB885', '0xB8A7'].includes(s.code ?? ''), s.metric);
      }
    },
  });
}

function popcount(w: number): number {
  let n = 0;
  for (let x = w >>> 0; x !== 0; x >>>= 1) n += x & 1;
  return n;
}
