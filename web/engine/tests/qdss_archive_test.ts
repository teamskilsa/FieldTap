// The real captures streamed through src/archive and the deframer (archive-gated on $FT_ARCHIVES/$FT_FIXTURES),
// with the elapsed time and memory printed. Only md5s, counts, codes and record versions are asserted or printed.
// - first capture: the whole trace's .qmdl is the Python's (e53a167b..., the contract's iphone-recovered.qmdl), its
//   stats serialise byte for byte as qdss-full-stats.json, and the secure census matches the PHY inventory;
// - moving capture: equal to qdss_deframe.py's default rules run on the same 130 chunks (md5s below, from that run).
//   Those rules keep one phase for the whole stream, and this trace's unit phase slips at its three missing files
//   and inside 0x6222..0x6225, so they recover 18,667 records where a per-segment phase recovers 85,361.

import { hexCode } from '../src/diag/record.ts';
import { archive, fixture, gate, REAL } from '../tools/fixtures.ts';
import { md5 } from '../tools/md5.ts';
import { assert, assertEquals } from './assert.ts';
import { tsvOf } from './qdss_support.ts';
import { type CaptureRun, deframeArchive, qmdlMd5, versions } from './qdss_capture.ts';

const FIRST = archive(REAL.first);
const MOVING = archive(REAL.moving);
const FULL_STATS = fixture('qdss-full-stats.json');
const INVENTORY = fixture('reference-phy/inventory.tsv');

function report(label: string, run: CaptureRun): void {
  const { stats, secure } = run.output;
  console.log(
    `${label}: ${run.chunks} chunks, read ${Math.round(run.readMs)} ms, deframe ${Math.round(run.deframeMs)} ms, ` +
      `sampled peak RSS ${run.sampledRssMb} MB / heap ${run.sampledHeapMb} MB; ${stats.log_records} records, ` +
      `${stats.distinct_codes} codes, secure ${secure.records} / ${secure.codes} codes`,
  );
}

const text = (s: string) => md5(new TextEncoder().encode(s));

Deno.test({
  name: 'first capture (.tar.gz through src/archive): .qmdl e53a167b..., stats equal qdss-full-stats.json, secure census',
  ignore: gate(FIRST, FULL_STATS, INVENTORY),
  fn: async () => {
    const run = await deframeArchive(FIRST);
    report('first capture', run);
    const { output } = run;
    assertEquals(qmdlMd5(output.records), 'e53a167b29b25560938d1f089e719d33');
    assertEquals(JSON.stringify(output.stats, null, 1) + '\n', await Deno.readTextFile(FULL_STATS), 'stats, byte for byte');
    assertEquals(output.bytesPerAtid, { none: 10, '0x32': 124_618_275, '0x10': 37_739, '0x7d': 27, '0x00': 614 });
    // The secure census is the PHY inventory's encrypted rows, code for code.
    const encrypted: Record<string, number> = {};
    for (const line of (await Deno.readTextFile(INVENTORY)).trim().split('\n').slice(1)) {
      const cols = line.split('\t');
      if (cols[cols.length - 1] === 'True') encrypted[cols[0]] = Number(cols[1]);
    }
    assertEquals([output.secure.records, output.secure.codes], [23_764, 61]);
    assertEquals(output.secure.byCode, Object.fromEntries(Object.entries(encrypted).sort(([a], [b]) => parseInt(a, 16) - parseInt(b, 16))));
    // Packet versions the signalling decoders expect: LTE RRC OTA v30, NR RRC OTA 0.26.
    assertEquals(versions(output.records, 0xb0c0), { '30': 100 });
    assertEquals(versions(output.records, 0xb821), { '0.26': 7 });
  },
});

Deno.test({
  name: 'moving capture: default rules, equal to qdss_deframe.py on the same chunks (.qmdl, .tsv, stats.json md5s)',
  ignore: gate(MOVING),
  fn: async () => {
    const run = await deframeArchive(MOVING, { index: true });
    report('moving capture', run);
    const { output } = run;
    const s = output.stats;
    assertEquals(qmdlMd5(output.records), '8c12310db74d60b635e50130da1469e1');
    assertEquals(text(tsvOf(output.index!)), '42e7e5112d1ef9cff89b24051ff88c85', '.tsv');
    assertEquals(text(JSON.stringify(s, null, 1)), '6197829fa1972ced33fb392616207db7', 'stats.json, byte for byte');
    assertEquals([s.chunks, s.atid32_bytes, s.stats['phase'], s.log_records, s.distinct_codes], [130, 123_780_488, 8, 18_667, 105]);
    // The phase slips show as bad-type and fill units read out of phase, and as unknown fragment kinds.
    assert((s.stats['u_badtype'] ?? 0) > 3_000_000 && (s.stats['gather_unknown_kind_0'] ?? 0) > 8_000, 'units read out of phase');
    assertEquals([s.targets[hexCode(0xb0c0)], s.targets[hexCode(0xb821)], output.secure.records, output.secure.codes], [6, 0, 1202, 4]);
    assertEquals(versions(output.records, 0xb0c0), { '30': 6 }, 'the LTE RRC records that survive are v30, as in the first capture');
    assertEquals(output.bytesPerAtid, { none: 84, '0x32': 123_780_488, '0x10': 50_478, '0x7d': 20, '0x00': 438 });
  },
});
