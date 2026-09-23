// Transport block sizes: TS 38.214 5.1.3.2 on cases worked by hand from the specification, the TS 36.213 MCS
// tables against the reference extractor's copy (a git-ignored local oracle, fixture-gated), and the TS 36.213
// table generator (tools/gen_lte_tbs.ts) on a synthetic .docx, stored and deflated, plus its validity checks on
// the oracle table (which a correct 3GPP table must pass) and on a corrupted copy (which must fail).

import { DL_MCS256_TO_ITBS, DL_MCS_TO_ITBS, LteTbsLookup, ulQm, UL_MCS_TO_ITBS } from '../src/phy/lteTbs.ts';
import { LTE_TBS_ROWS } from '../src/phy/lteTbsTable.ts';
import { NR_MCS_TABLES, NR_SMALL_TBS, nrQm, nrTbsBits, nrTbsBytes } from '../src/phy/nrTbs.ts';
import { documentXml, grid, parseTable, rowsAfterCaption, segmentsCleanly, tsSource } from '../tools/gen_lte_tbs.ts';
import { gate } from '../tools/fixtures.ts';
import { readJson } from '../tools/golden.ts';
import { assert, assertEquals, assertThrows } from './assert.ts';
import { concat } from './support.ts';
import { TBS_REFERENCE } from './phy_support.ts';

Deno.test('nr tbs: TS 38.214 5.1.3.2 cases worked by hand (small-TBS table, one block, segmented, low code rate)', () => {
  // 132 RE x 4 PRB, QPSK R 120/1024: N_info 123.75 -> n 3 -> N'_info 120 -> the first size >= 120.
  assertEquals(nrTbsBits(132, 4, 2, 120 / 1024, 1), 120);
  // 144 RE x 52 PRB, 64QAM R 567/1024, 2 layers: N_info 49,753.5 -> n 10 -> N' 50,176 > 8424: C 6 -> 50,184.
  assertEquals(nrTbsBits(144, 52, 6, 567 / 1024, 2), 50_184);
  // 156 RE x 273 PRB, QPSK R 120/1024 (R <= 1/4): N_info 9981.6 -> n 8 -> N' 9984: C 3 -> 9984.
  assertEquals(nrTbsBits(156, 273, 2, 120 / 1024, 1), 9_984);
  // More than 156 RE per PRB counts as 156.
  assertEquals(nrTbsBits(200, 52, 6, 567 / 1024, 2), nrTbsBits(156, 52, 6, 567 / 1024, 2));
  assertEquals(nrTbsBytes('qam256', 13, 52, 2, 144), nrTbsBits(144, 52, 6, 567 / 1024, 2)! / 8);
  assertEquals(nrTbsBytes('qam256', 28, 52, 2, 144), null, 'a reserved MCS has no size');
  assertEquals(nrTbsBits(144, 0, 2, 0.1, 1), 0);
});

Deno.test('nr tbs: MCS tables and the small-size table have the shape of TS 38.214', () => {
  assertEquals([NR_MCS_TABLES.qam64.length, NR_MCS_TABLES.qam256.length, NR_MCS_TABLES.qam64LowSe.length], [29, 28, 29]);
  assertEquals(NR_MCS_TABLES.qam256[20], [8, 682.5]);
  assertEquals([28, 29, 30, 31].map((m) => nrQm('qam256', m)), [2, 4, 6, 8]);
  assertEquals([29, 30, 31, 32].map((m) => nrQm('qam64', m)), [2, 4, 6, null]);
  assertEquals(NR_SMALL_TBS.length, 93);
  assert(NR_SMALL_TBS.every((t, i) => t % 8 === 0 && (i === 0 || t > NR_SMALL_TBS[i - 1])));
  // Spectral efficiencies as the specification prints them (it dips where the modulation steps up: MCS 16 -> 17).
  const se = (t: keyof typeof NR_MCS_TABLES, m: number) => Math.round((NR_MCS_TABLES[t][m][0] * NR_MCS_TABLES[t][m][1]) / 1024 * 1e4) / 1e4;
  assertEquals([se('qam64', 16), se('qam64', 17), se('qam256', 27), se('qam64LowSe', 0)], [2.5703, 2.5664, 7.4063, 0.0586]);
  // Every size the formula gives is whole bytes.
  for (let prb = 1; prb <= 273; prb += 17) for (const [q, r] of NR_MCS_TABLES.qam256) assertEquals(nrTbsBits(132, prb, q, r / 1024, 2)! % 8, 0);
});

Deno.test('lte tbs: this build carries no table yet, and the lookup reads layers x N_PRB (TS 36.213 7.1.7.2.2)', () => {
  assertEquals(LTE_TBS_ROWS.length, 0, 'regenerate with tools/gen_lte_tbs.ts from the 3GPP document');
  const t = new LteTbsLookup([[16, 32, 56, 88]]);
  assertEquals([t.bits(0, 1), t.bits(0, 4), t.bits(0, 5), t.bits(1, 1)], [16, 88, null, null]);
  assertEquals(t.dl(0, 2, 2, false), 88, '2 layers on 2 PRB read the 4-PRB column');
  assertEquals(t.dl(29, 1, 1, false), null, 'MCS 29-31 are retransmissions');
  assertEquals([ulQm(0), ulQm(10), ulQm(11), ulQm(20), ulQm(21), ulQm(28), ulQm(29)], [2, 2, 4, 4, 6, 6, null]);
  assertEquals([DL_MCS_TO_ITBS.length, DL_MCS256_TO_ITBS.length, UL_MCS_TO_ITBS.length], [29, 28, 29]);
});

Deno.test({
  name: "lte tbs: the MCS tables typed from TS 36.213 equal the reference extractor's, and its table passes the generator's checks",
  ignore: gate(TBS_REFERENCE),
  fn: async () => {
    // deno-lint-ignore no-explicit-any
    const ref: any = await readJson(TBS_REFERENCE);
    assertEquals(DL_MCS_TO_ITBS, ref.dlMcs);
    assertEquals(DL_MCS256_TO_ITBS, ref.dlMcs256);
    assertEquals(UL_MCS_TO_ITBS, ref.ulMcs);
    const table = new Map<string, number>();
    (ref.tbs as number[][]).forEach((row, i) => row.forEach((v, n) => table.set(`${i}/${n + 1}`, v)));
    assertEquals(grid(table).length, 34, 'a real table 7.1.7.2.1-1 passes every check');
    const broken = new Map(table);
    broken.set('20/50', table.get('20/50')! + 8);
    assertThrows(() => grid(broken), (e) => String(e).includes('I_TBS 20'), 'one wrong size is caught');
  },
});

// ------------------------------------------------------------------------------------------ the generator

/** A synthetic document laid out like the specification: a caption, blocks of 10 N_PRB columns, the next caption.
 *  The sizes are valid turbo sizes in increasing order, not 3GPP's values. */
function syntheticDocument(): { xml: string; sizes: number[] } {
  const sizes: number[] = [];
  for (let t = 16; sizes.length < 34 * 3 + 110; t += 8) if (segmentsCleanly(t)) sizes.push(t);
  const p = (t: string) => `<w:p><w:pPr><w:pStyle w:val="TH"/></w:pPr><w:r><w:t>${t}</w:t></w:r></w:p>`;
  const tr = (cells: string[]) => '<w:tr>' + cells.map((c) => `<w:tc><w:p><w:r><w:t xml:space="preserve">${c}</w:t></w:r></w:p></w:tc>`).join('') + '</w:tr>';
  const blocks: string[] = [];
  for (let k = 0; k < 110; k += 10) {
    const rows = [tr(['I<w:t>TBS</w:t>', 'N']), tr(['', ...Array.from({ length: 10 }, (_, n) => String(k + n + 1))])];
    for (let i = 0; i < 34; i++) rows.push(tr([String(i), ...Array.from({ length: 10 }, (_, n) => String(sizes[i * 3 + k + n]))]));
    blocks.push('<w:tbl>' + rows.join('') + '</w:tbl>');
  }
  const xml = '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
    p('Table 7.1.7.1-1: other') + '<w:tbl>' + tr(['0', '99']) + '</w:tbl>' +
    p('Table 7.1.7.2.1-1: Transport block size table (dimension 34&#215;110)') + blocks.join('') +
    p('Table 7.1.7.2.2-1: One-layer to two-layer TBS translation table') + '<w:tbl>' + tr(['1', '2']) + '</w:tbl></w:body></w:document>';
  return { xml, sizes };
}

function crc32(data: Uint8Array): number {
  let c = ~0;
  for (const b of data) {
    c ^= b;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}

/** A zip with the given entries, stored (method 0) or deflated (method 8). */
async function zip(entries: { name: string; data: Uint8Array; deflate?: boolean }[]): Promise<Uint8Array> {
  const enc = new TextEncoder();
  const locals: Uint8Array[] = [], central: Uint8Array[] = [];
  let offset = 0;
  for (const e of entries) {
    const body = e.deflate ? new Uint8Array(await new Response(new Blob([new Uint8Array(e.data)]).stream().pipeThrough(new CompressionStream('deflate-raw'))).arrayBuffer()) : e.data;
    const name = enc.encode(e.name), crc = crc32(e.data), method = e.deflate ? 8 : 0;
    const local = new Uint8Array(30 + name.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(8, method, true);
    lv.setUint32(14, crc, true);
    lv.setUint32(18, body.length, true);
    lv.setUint32(22, e.data.length, true);
    lv.setUint16(26, name.length, true);
    local.set(name, 30);
    const dir = new Uint8Array(46 + name.length);
    const dv = new DataView(dir.buffer);
    dv.setUint32(0, 0x02014b50, true);
    dv.setUint16(10, method, true);
    dv.setUint32(16, crc, true);
    dv.setUint32(20, body.length, true);
    dv.setUint32(24, e.data.length, true);
    dv.setUint16(28, name.length, true);
    dv.setUint32(42, offset, true);
    dir.set(name, 46);
    locals.push(local, body);
    central.push(dir);
    offset += local.length + body.length;
  }
  const dirBytes = concat(central);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, entries.length, true);
  ev.setUint16(10, entries.length, true);
  ev.setUint32(12, dirBytes.length, true);
  ev.setUint32(16, offset, true);
  return concat([...locals, dirBytes, end]);
}

Deno.test('gen_lte_tbs: reads table 7.1.7.2.1-1 from a .docx and from the zip 3GPP ships, then writes the module', async () => {
  const { xml, sizes } = syntheticDocument();
  const enc = new TextEncoder();
  for (const deflate of [false, true]) {
    const docx = await zip([{ name: '[Content_Types].xml', data: enc.encode('<Types/>') }, { name: 'word/document.xml', data: enc.encode(xml), deflate }]);
    for (const file of [docx, await zip([{ name: '36213-x00.docx', data: docx, deflate }])]) {
      const rows = grid(parseTable(rowsAfterCaption(await documentXml(file))));
      assertEquals([rows.length, rows.every((r) => r.length === 110)], [34, true]);
      assertEquals([rows[5][17], rows[33][109], rows[0][0]], [sizes[5 * 3 + 17], sizes[33 * 3 + 109], sizes[0]]);
    }
  }
  const rows = grid(parseTable(rowsAfterCaption(xml)));
  const src = tsSource(rows, 'x00');
  const mod = await import(`data:application/typescript;base64,${btoa(src)}`);
  assertEquals(mod.LTE_TBS_ROWS, rows);
  assertEquals(mod.LTE_TBS_SOURCE, '3GPP TS 36.213 x00');
  // The table before the caption and the one after the next caption are not read.
  assert(!rowsAfterCaption(xml).some((r) => r.join() === '0,99' || r.join() === '1,2'));
});

Deno.test('gen_lte_tbs: refuses a table with missing columns or sizes that do not segment into turbo blocks', () => {
  const { xml } = syntheticDocument();
  const table = parseTable(rowsAfterCaption(xml));
  table.delete('7/33');
  assertThrows(() => grid(table), (e) => String(e).includes('I_TBS 7: N_PRB 33 missing'));
  table.set('7/33', 1_004);
  assertThrows(() => grid(table), (e) => String(e).includes('I_TBS 7: sizes 1004 do not segment cleanly'));
  assertEquals([segmentsCleanly(16), segmentsCleanly(20), segmentsCleanly(6120), segmentsCleanly(75_376)], [true, false, true, true]);
});
