// The integrated engine on the three real captures (read in place, never copied): archive -> deframe -> call
// flow -> PHY -> journey -> CaptureAnalysis, masked, plus the reveal path. Assertions and messages carry counts
// only, never a value from the capture.

import { analyzeCapture } from '../src/analyze.ts';
import type { CaptureAnalysis, ImportProgress } from '../src/types.ts';
import { type CaptureSource, captureSource, gateCapture, REAL } from '../tools/fixtures.ts';
import { assert, assertEquals } from './assert.ts';
import { buildTar, gzip, loggingOffFiles, openCapture, streamOf } from './support.ts';

const FIRST = REAL.first;
const MOVING = REAL.moving;

const NOW = Date.UTC(2026, 8, 22, 13, 0, 0);

/**
 * Timing, and how much memory the analysis holds.
 *
 * Two numbers, because they answer different questions. `heldMB` is this analysis's own footprint: the live JS
 * heap plus external buffers (the tar chunks are ArrayBuffers, so `external` is where the trace actually sits),
 * measured as the rise over the idle baseline before the run. `rssMB` is the process high-water mark, which the
 * tests share — Deno does not return RSS to the OS between tests, so the second capture reports the first
 * capture's peak and cannot be read as its own. Only `heldMB` is per-archive here. For a true per-archive peak
 * RSS, run one capture per process: `/usr/bin/time -l deno run -A tools/pipeline.ts ARCHIVE.tar.gz`.
 */
async function analyze(name: string) {
  const source = captureSource(name) as CaptureSource;
  const { stream, totalBytes } = openCapture(source);
  const progress: ImportProgress[] = [];
  const held = () => {
    const m = Deno.memoryUsage();
    return m.heapUsed + m.external;
  };
  const base = held();
  let peakHeld = base;
  let peakRss = Deno.memoryUsage().rss;
  const sample = () => {
    peakHeld = Math.max(peakHeld, held());
    peakRss = Math.max(peakRss, Deno.memoryUsage().rss);
  };
  const timer = setInterval(sample, 20);
  const t0 = performance.now();
  try {
    // The file name carries the button-press time, so it is the capture's own name in either form.
    const out = await analyzeCapture(stream, (p) => {
      progress.push(p);
      sample();
    }, undefined, { fileName: name, totalBytes, nowMs: NOW });
    sample();
    return {
      ...out,
      progress,
      ms: performance.now() - t0,
      heldMB: Math.round((peakHeld - base) / 1e6),
      rssMB: Math.round(peakRss / 1e6),
      from: source.kind,
    };
  } finally {
    clearInterval(timer);
  }
}

/** What one capture may hold at once. The trace itself is the floor: the reader keeps the kept chunks (133 MB on
 *  the first capture) until the deframer has consumed them, so this bounds the copies made on top of it, not the
 *  trace. A worker that cannot stay under this has no business running on a phone. */
const HELD_CEILING_MB = 500;

/** Every string in `v`. */
function strings(v: unknown, out: string[] = []): string[] {
  if (typeof v === 'string') out.push(v);
  else if (Array.isArray(v)) v.forEach((x) => strings(x, out));
  else if (v && typeof v === 'object') Object.values(v).forEach((x) => strings(x, out));
  return out;
}

/** The decoded identifiers: revealed field values and texts wherever a masked form sits beside them. */
function identifiers(revealed: unknown): Set<string> {
  const out = new Set<string>();
  const walk = (v: unknown) => {
    if (Array.isArray(v)) return v.forEach(walk);
    if (!v || typeof v !== 'object') return;
    const o = v as Record<string, unknown>;
    for (const [shown, masked] of [['value', 'masked'], ['summary', 'summaryMasked'], ['detail', 'detailMasked'], ['refusal', 'refusalMasked']]) {
      if (typeof o[masked!] === 'string' && typeof o[shown!] === 'string' && o[shown!] !== o[masked!]) out.add(o[shown!] as string);
    }
    Object.values(o).forEach(walk);
  };
  walk(revealed);
  return out;
}

/** Identifier-shaped: a long digit or hex run (IMSI, IMEI, MSISDN, TMSI, keys) or an IP address. Masking also
 *  hides harmless children of an identity (its PLMN, 'IPv4' as the PDN type), which may appear elsewhere. */
const IDENTIFIER_SHAPED = /\d{6,}|[0-9a-f]{8,}|\d{1,3}(\.\d{1,3}){3}|[0-9a-f]{0,4}(:[0-9a-f]{0,4}){3,}/i;

/** No identifier the reveal path knows appears anywhere in the masked analysis, journey and findings included. */
function assertMasked(a: CaptureAnalysis, revealedIds: Set<string>, expectIds = true): void {
  assert(a.events.every((e) => e.pduHex === undefined), 'no PDU bytes while masked');
  assert(a.cellDetails.every((c) => c.cellIdentity === undefined), 'no cell identity while masked');
  const text = strings(a).join('\n');
  const shaped = [...revealedIds].filter((id) => IDENTIFIER_SHAPED.test(id));
  if (expectIds) assert(shaped.length > 0, 'the capture has identifier-shaped values to hide');
  const leaks = shaped.filter((id) => text.includes(id.match(IDENTIFIER_SHAPED)![0])).length;
  assertEquals(leaks, 0, 'revealed identifiers found in the masked analysis');
}

Deno.test({
  name: 'pipeline, first capture (profile on): contract counts, attributed PHY, masked output, reveal on request',
  ignore: gateCapture(FIRST),
  fn: async () => {
    const { analysis: a, reveal, progress, ms, heldMB, rssMB, from } = await analyze(FIRST);
    assertEquals([a.records, a.codes, a.events.length, a.procedures.length], [92133, 224, 128, 34]);
    assert(a.procedures.every((p) => p.outcome === 'SUCCEEDED'), 'every procedure succeeded');
    assertEquals(a.steps.map((s) => s.move), ['FIRST_SEEN', 'RESELECTION', 'HANDOVER', 'HANDOVER']);
    assertEquals([a.ladder.rows.ALL.length, a.ladder.rows.RRC.length, a.ladder.rows.NAS.length], [157, 127, 29]);
    assertEquals([a.journey.markers.length, a.journey.findings.length], [13, 10]);
    assert(a.steps.some((s) => s.annotation), 'the journey annotates the ladder moves');
    assert(a.journey.tiles.some((t) => t.id === 'lteDlPeak') && a.journey.tiles.some((t) => t.id === 'nrDlPeak'), 'PHY peak tiles');
    assertEquals(a.phy.length, 47);
    assert(a.phy.some((s) => s.samples.some((x) => x.cell)), 'carrier samples placed on cells');
    assertEquals([a.versionMisses, a.problems, a.guide.status], [{}, [], 'active']);
    assertEquals(a.deframe?.log_records, 92133);
    assertEquals([...new Set(progress.map((p) => p.stage))], ['reading', 'extracting', 'deframing', 'decoding', 'radio', 'done']);

    assert(reveal, 'the call flow is kept for reveal');
    const revealed = reveal();
    assertEquals(revealed.events.length, 128);
    assert(revealed.events.every((e) => e.pduHex !== undefined || e.pduLength === 0), 'bytes when revealed');
    const ids = identifiers(revealed);
    assert(ids.size > 0, 'the reveal path has identifiers to hide');
    assertMasked(a, ids);
    assert(heldMB < HELD_CEILING_MB, `held ${heldMB} MB, over the ${HELD_CEILING_MB} MB ceiling`);
    console.log(`first capture (${from}): ${Math.round(ms)} ms, held ${heldMB} MB (process RSS high-water ${rssMB} MB)`, a.timings);
  },
});

Deno.test({
  name: 'pipeline, moving capture (profile on): the deframer resync recovers the trace, and the gaps are reported',
  ignore: gateCapture(MOVING),
  fn: async () => {
    const { analysis: a, reveal, ms, heldMB, rssMB, from } = await analyze(MOVING);
    // Without the resync one phase for the whole stream gives 18,667 records, 105 codes and 6 messages. The
    // reference's offline per-segment run gives 85,361 records, 222 codes and 102 messages; the online resync
    // notices each slip RESYNC_RUN units late, which costs 10 unstamped records and 2 messages of that.
    assert(a.records >= 80_000, `${a.records} records, under the 80,000 floor`);
    assertEquals([a.records, a.codes, a.events.length], [85351, 222, 100]);
    assertEquals(a.deframe?.stats['resync_slip'], 5);
    assertEquals(a.deframe?.stats['resync_gap'], 3, 'one reset per missing-file hole');
    assertEquals(a.problems.map((p) => [p.kind, p.blocking]), [['traceGaps', false]]);
    assertEquals([a.traceWindow?.filesKept, a.traceWindow?.filesMissing, a.guide.status], [130, 3, 'active']);
    assertEquals(a.versionMisses, {});
    // The recovered trace carries the cell change the fixed phase could not show: a detach and re-attach.
    assertEquals(a.steps.map((s) => s.move), ['FIRST_SEEN', 'RESELECTION']);
    assert(a.phy.length > 0 && a.journey.findings.length > 0, 'radio series and findings');
    assert(reveal);
    assertMasked(a, identifiers(reveal())); // the recovered NAS messages carry identifiers to hide
    assert(heldMB < HELD_CEILING_MB, `held ${heldMB} MB, over the ${HELD_CEILING_MB} MB ceiling`);
    console.log(`moving capture (${from}): ${Math.round(ms)} ms, held ${heldMB} MB (process RSS high-water ${rssMB} MB)`, a.timings);
  },
});

Deno.test({
  name: "pipeline, profile-off capture: 'logging was off' problems and the 'off' guide, nothing to reveal",
  fn: async () => {
    // Synthetic, and not gated: the 14-39-54 archive was never on this Mac, and the extracted folder that stood
    // in for it has since been deleted from ~/Downloads. loggingOffFiles invents the same shape (an ambtool log
    // saying logging is off, one unrelated MDM stub, no trace), as an in-memory tar.gz never written to disk.
    const root = 'sysdiagnose_2026.09.21_14-39-54-0400_iPhone-OS_iPhone_23F84';
    const gz = await gzip(buildTar(loggingOffFiles(root)));
    const { analysis: a, reveal } = await analyzeCapture(streamOf(gz, [65536]), () => {}, undefined, {
      fileName: `${root}.tar.gz`,
      totalBytes: gz.length,
      nowMs: NOW,
    });
    assertEquals(a.problems.map((p) => [p.kind, p.blocking]), [['loggingNotEnabled', true], ['noBasebandTrace', true]]);
    assertEquals([a.guide.status, a.guide.needsAttention, a.profile.status], ['off', true, 'missing']);
    assertEquals([a.records, a.events.length, a.phy.length, a.traceWindow], [0, 0, 0, null]);
    assertEquals(reveal, null);
  },
});
