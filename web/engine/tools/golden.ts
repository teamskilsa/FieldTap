// Structural JSON comparison for the FieldTap contract fixtures: the rules of ios/Contract/tools/json_equal.py
// (and Swift GoldenCodec.jsonDiff), one for one.
//
//   deno run -A tools/golden.ts A.json B.json [--tolerance 0.0015] [--ignore source.file ...]
//
// Objects compare by key set and value; arrays by length ('path.length') and position; strings and booleans
// exactly (a boolean never equals a number); numbers within an absolute tolerance, integers too, so equal 17-digit
// modem timestamps compare exactly (they are bigint on both sides: see json.ts). Paths are dotted with [i] for
// array positions; --ignore takes dotted paths without indexes and skips them at every position.
// `source.file` is ignored by default, as in Swift; pass --no-default-ignore to compare it.

import { type Json, parseJsonExact } from './json.ts';

export interface DiffOptions {
  tolerance?: number;
  ignore?: Iterable<string>;
}

export const DEFAULT_TOLERANCE = 0.0015;
export const DEFAULT_IGNORE = ['source.file'];

/** Every differing path, in json_equal.py's order (object keys sorted). Empty means equal. */
export function jsonDiff(a: unknown, b: unknown, options: DiffOptions = {}): string[] {
  const tol = options.tolerance ?? DEFAULT_TOLERANCE;
  const ignore = new Set(options.ignore ?? DEFAULT_IGNORE);
  const out: string[] = [];
  walk(a, b, '', tol, ignore, out);
  return out;
}

const stripIndex = (path: string) => path.replace(/\[\d+\]/g, '');

type Kind = 'null' | 'bool' | 'number' | 'string' | 'array' | 'object' | 'other';

function kindOf(v: unknown): Kind {
  if (v === null) return 'null';
  if (typeof v === 'boolean') return 'bool';
  if (typeof v === 'number' || typeof v === 'bigint') return 'number';
  if (typeof v === 'string') return 'string';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'object') return 'object';
  return 'other';
}

function numbersEqual(a: number | bigint, b: number | bigint, tol: number): boolean {
  if (typeof a === 'bigint' || typeof b === 'bigint') {
    // A big integer is compared exactly with any integer; with a fraction, as doubles within the tolerance.
    const ai = typeof a === 'bigint' ? a : Number.isInteger(a) ? BigInt(a) : null;
    const bi = typeof b === 'bigint' ? b : Number.isInteger(b) ? BigInt(b) : null;
    if (ai !== null && bi !== null) return ai === bi;
    return Math.abs(Number(a) - Number(b)) <= tol;
  }
  return a === b || Math.abs(a - b) <= tol;
}

function walk(a: unknown, b: unknown, path: string, tol: number, ignore: Set<string>, out: string[]): void {
  if (ignore.has(stripIndex(path))) return;
  const ka = kindOf(a), kb = kindOf(b);
  if (ka === 'bool' || kb === 'bool') {
    if (a !== b) out.push(path);
    return;
  }
  if (ka === 'number' && kb === 'number') {
    if (!numbersEqual(a as number | bigint, b as number | bigint, tol)) out.push(path);
    return;
  }
  if (ka !== kb) {
    out.push(path);
    return;
  }
  if (ka === 'object') {
    const ao = a as Record<string, unknown>, bo = b as Record<string, unknown>;
    const keys = [...new Set([...Object.keys(ao), ...Object.keys(bo)])].sort(pythonOrder);
    for (const k of keys) {
      const p = path ? `${path}.${k}` : k;
      if (!(k in ao) || !(k in bo)) {
        if (!ignore.has(stripIndex(p))) out.push(p);
        continue;
      }
      walk(ao[k], bo[k], p, tol, ignore, out);
    }
  } else if (ka === 'array') {
    const aa = a as unknown[], ba = b as unknown[];
    if (aa.length !== ba.length) out.push(`${path}.length`);
    for (let i = 0; i < Math.min(aa.length, ba.length); i++) walk(aa[i], ba[i], `${path}[${i}]`, tol, ignore, out);
  } else if (a !== b) {
    out.push(path);
  }
}

/** Python's sorted() order for str keys: by code point, which is JS's default for BMP text. */
function pythonOrder(x: string, y: string): number {
  return x < y ? -1 : x > y ? 1 : 0;
}

/** Reads a JSON file exactly (big integers kept). */
export async function readJson(path: string): Promise<Json> {
  return parseJsonExact(await Deno.readTextFile(path));
}

if (import.meta.main) {
  const args = [...Deno.args];
  const files: string[] = [];
  const ignore = new Set<string>(DEFAULT_IGNORE);
  let tolerance = DEFAULT_TOLERANCE;
  while (args.length) {
    const a = args.shift()!;
    if (a === '--tolerance') tolerance = Number(args.shift());
    else if (a === '--ignore') ignore.add(args.shift()!);
    else if (a === '--no-default-ignore') DEFAULT_IGNORE.forEach((p) => ignore.delete(p));
    else files.push(a);
  }
  if (files.length !== 2) {
    console.error('usage: golden.ts A.json B.json [--tolerance 0.0015] [--ignore path]... [--no-default-ignore]');
    Deno.exit(2);
  }
  const diffs = jsonDiff(await readJson(files[0]), await readJson(files[1]), { tolerance, ignore });
  if (diffs.length) {
    for (const p of diffs.slice(0, 200)) console.log(p);
    console.log(`${diffs.length} differences`);
    Deno.exit(1);
  }
  console.log('equal');
}
