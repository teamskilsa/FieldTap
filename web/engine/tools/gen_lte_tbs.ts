// Generates src/phy/lteTbsTable.ts from 3GPP TS 36.213 itself (the port of FTPhy's gen_lte_tbs.py).
//
//   deno run -A tools/gen_lte_tbs.ts 36213-h00.docx > src/phy/lteTbsTable.ts   (or the 36213-h00.zip 3GPP ships)
//
// Input: the specification as 3GPP publishes it (https://www.3gpp.org/ftp/Specs/archive/36_series/36.213/; any
// release from 12 on has the 34 x 110 table). A .docx is a zip of WordprocessingML; table 7.1.7.2.1-1 is read from
// the tables that follow its caption, up to the next table caption. Nothing is taken from any other
// implementation's copy of the table (srsRAN's, in the reference extractor's refs, is AGPL-3.0).
//
// Checks before writing: 34 (or 27, pre-Rel-12) rows of 110 sizes; every size is a multiple of 8 whose TB + CRC
// segments into turbo code blocks without filler (TS 36.212 5.1.2); sizes never shrink as N_PRB grows from 2 on.

/** The entry `name` of a zip archive (stored or deflated), or null when it is not there. */
export async function zipEntry(zip: Uint8Array, name: (entry: string) => boolean): Promise<{ name: string; data: Uint8Array } | null> {
  const v = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
  let eocd = -1;
  for (let i = zip.length - 22; i >= Math.max(0, zip.length - 65_557); i--) {
    if (v.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a zip archive');
  const entries = v.getUint16(eocd + 10, true);
  let at = v.getUint32(eocd + 16, true);
  for (let k = 0; k < entries; k++) {
    if (v.getUint32(at, true) !== 0x02014b50) throw new Error('bad zip central directory');
    const method = v.getUint16(at + 10, true), size = v.getUint32(at + 20, true);
    const nameLen = v.getUint16(at + 28, true), extraLen = v.getUint16(at + 30, true), commentLen = v.getUint16(at + 32, true);
    const local = v.getUint32(at + 42, true);
    const entry = new TextDecoder().decode(zip.subarray(at + 46, at + 46 + nameLen));
    at += 46 + nameLen + extraLen + commentLen;
    if (!name(entry)) continue;
    const start = local + 30 + v.getUint16(local + 26, true) + v.getUint16(local + 28, true);
    const raw = zip.subarray(start, start + size);
    if (method === 0) return { name: entry, data: raw.slice() };
    if (method !== 8) throw new Error(`zip method ${method} not supported`);
    const out = new Blob([raw]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
    return { name: entry, data: new Uint8Array(await new Response(out).arrayBuffer()) };
  }
  return null;
}

/** word/document.xml of a .docx, or of the one .docx inside 3GPP's .zip. */
export async function documentXml(file: Uint8Array): Promise<string> {
  let docx = file;
  const inner = await zipEntry(file, (n) => n.toLowerCase().endsWith('.docx'));
  if (inner) docx = inner.data;
  const doc = await zipEntry(docx, (n) => n === 'word/document.xml');
  if (!doc) throw new Error('no word/document.xml: not a .docx');
  return new TextDecoder().decode(doc.data);
}

const unescape = (s: string) =>
  s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).replace(/&amp;/g, '&');

const text = (xml: string) => [...xml.matchAll(/<w:t(?:\s[^>]*)?>([^<]*)<\/w:t>/g)].map((m) => unescape(m[1])).join('').trim();

const CAPTION = /^\s*Table\s+7\.1\.7\.2\.1-1\b/;
const NEXT_CAPTION = /^\s*Table\s+\d/;

/** The cell texts of every table row between the 7.1.7.2.1-1 caption and the next table caption. */
export function rowsAfterCaption(documentXml: string): string[][] {
  const rows: string[][] = [];
  let inside = false;
  // Top-level paragraphs and tables in document order (the TBS tables are not nested).
  for (const m of documentXml.matchAll(/<w:tbl\b[\s\S]*?<\/w:tbl>|<w:p\b[\s\S]*?<\/w:p>/g)) {
    const el = m[0];
    if (el.startsWith('<w:p')) {
      const t = text(el);
      if (CAPTION.test(t)) inside = true;
      else if (inside && NEXT_CAPTION.test(t)) break;
    } else if (inside) {
      for (const tr of el.matchAll(/<w:tr\b[\s\S]*?<\/w:tr>/g)) rows.push([...tr[0].matchAll(/<w:tc\b[\s\S]*?<\/w:tc>/g)].map((tc) => text(tc[0])));
    }
  }
  return rows;
}

const integer = (s: string): number | null => {
  const t = s.replace(/[\s ]/g, '');
  return /^\d+$/.test(t) ? Number(t) : null;
};

/** 'iTbs/nPrb' -> size, from header rows (consecutive N_PRB numbers) and data rows (I_TBS, sizes...). */
export function parseTable(rows: string[][]): Map<string, number> {
  const table = new Map<string, number>();
  let columns: number[] | null = null;
  for (const cells of rows) {
    const nums = cells.map(integer);
    const tail = nums.slice(1).filter((n): n is number => n !== null);
    const consecutive = tail.length >= 2 && tail.every((n, i) => i === 0 || n === tail[i - 1] + 1);
    if (consecutive && (nums[0] === null || tail.length >= 5) && tail.length === cells.length - 1) {
      columns = tail;
      continue;
    }
    if (columns && nums[0] !== null && nums.slice(1).every((n) => n !== null) && nums.length - 1 === columns.length) {
      columns.forEach((nPrb, k) => table.set(`${nums[0]}/${nPrb}`, nums[k + 1]!));
    }
  }
  return table;
}

/** TS 36.212 5.1.3.2.3 table 5.1.3-3: the turbo interleaver sizes K. */
const INTERLEAVER = new Set<number>();
for (let k = 40; k <= 512; k += 8) INTERLEAVER.add(k);
for (let k = 528; k <= 1024; k += 16) INTERLEAVER.add(k);
for (let k = 1056; k <= 2048; k += 32) INTERLEAVER.add(k);
for (let k = 2112; k <= 6144; k += 64) INTERLEAVER.add(k);

/** TS 36.212 5.1.2: TB + 24-bit CRC, split into C blocks each with its own CRC, all of one interleaver size. */
export function segmentsCleanly(tbs: number): boolean {
  if (tbs % 8) return false;
  const b = tbs + 24;
  if (b <= 6144) return INTERLEAVER.has(b);
  const c = Math.ceil(b / 6120);
  return (b + 24 * c) % c === 0 && INTERLEAVER.has((b + 24 * c) / c);
}

/** rows[I_TBS][N_PRB - 1], checked; throws with every problem found. */
export function grid(table: Map<string, number>, validate = true): number[][] {
  const iTbs = [...table.keys()].map((k) => Number(k.split('/')[0]));
  const nRows = iTbs.length ? Math.max(...iTbs) + 1 : 0;
  const rows = Array.from({ length: nRows }, (_, i) => Array.from({ length: 110 }, (_, n) => table.get(`${i}/${n + 1}`) ?? null));
  const problems: string[] = [];
  if (nRows !== 27 && nRows !== 34) problems.push(`${nRows} I_TBS rows (expected 34, or 27 before Rel-12)`);
  rows.forEach((row, i) => {
    const missing = row.flatMap((v, n) => (v === null ? [n + 1] : []));
    if (missing.length) {
      problems.push(`I_TBS ${i}: N_PRB ${missing.slice(0, 5).join(', ')} missing`);
      return;
    }
    if (!validate) return;
    const bad = (row as number[]).filter((v) => !segmentsCleanly(v));
    if (bad.length) problems.push(`I_TBS ${i}: sizes ${bad.slice(0, 5).join(', ')} do not segment cleanly`);
    // From N_PRB 2 on: the published table has one known oddity in its first column (I_TBS 6, N_PRB 1).
    if (row.slice(2).some((v, n) => v! < row[n + 1]!)) problems.push(`I_TBS ${i}: a size shrinks as N_PRB grows`);
  });
  if (problems.length) throw new Error(`gen_lte_tbs: ${problems.join('; ')}`);
  return rows as number[][];
}

/** src/phy/lteTbsTable.ts for `rows`. */
export function tsSource(rows: number[][], source: string): string {
  const out = [
    `// GENERATED by tools/gen_lte_tbs.ts from 3GPP TS 36.213 (${source}); do not edit. LTE_TBS_ROWS[I_TBS][N_PRB - 1] is`,
    `// the transport block size in bits of table 7.1.7.2.1-1 (I_TBS 0-${rows.length - 1}, N_PRB 1-110).`,
    '',
    '/** The specification the rows were read from. */',
    `export const LTE_TBS_SOURCE = '3GPP TS 36.213 ${source}';`,
    '',
    'export const LTE_TBS_ROWS: readonly (readonly number[])[] = [',
  ];
  rows.forEach((row, i) => {
    out.push(`  // I_TBS ${i}`, '  [');
    for (let k = 0; k < 110; k += 12) out.push(`    ${row.slice(k, k + 12).join(', ')},`);
    out.push('  ],');
  });
  out.push('];', '');
  return out.join('\n');
}

if (import.meta.main) {
  const [path] = Deno.args;
  if (!path) {
    console.error('usage: deno run -A tools/gen_lte_tbs.ts <36213-xxx.docx | 36213-xxx.zip>');
    Deno.exit(2);
  }
  const rows = grid(parseTable(rowsAfterCaption(await documentXml(await Deno.readFile(path)))));
  const source = path.split('/').pop()!.replace(/\.(docx|zip)$/i, '');
  Deno.stdout.writeSync(new TextEncoder().encode(tsSource(rows, source)));
}
