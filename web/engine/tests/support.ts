// Synthetic inputs for the tests: tar archives built byte by byte (ustar, GNU, pax, long names, base-256 sizes),
// gzip through the platform's CompressionStream, and streams that deliver bytes in chosen or random splits.
// Nothing here is capture-derived, apart from openCapture, which only streams a capture the caller already has.

import type { CaptureSource } from '../tools/fixtures.ts';

export interface TarSpec {
  path: string;
  data?: Uint8Array | string;
  /** Typeflag; default '0' (regular file). */
  type?: string;
  /** 'posix' (default) splits long paths into prefix + name; 'gnu' writes 'ustar  ' and a GNU 'L' entry. */
  format?: 'posix' | 'gnu';
  /** Emit a pax 'x' header carrying these records before the entry. */
  pax?: Record<string, string>;
  /** Write the size field in GNU base-256. */
  base256?: boolean;
  mtimeS?: number;
}

const enc = new TextEncoder();
const bytesOf = (d: Uint8Array | string | undefined) => (typeof d === 'string' ? enc.encode(d) : d ?? new Uint8Array(0));

function put(h: Uint8Array, at: number, len: number, s: string) {
  const b = enc.encode(s);
  if (b.length > len) throw new Error(`field too long: ${s}`);
  h.set(b, at);
}

function octal(h: Uint8Array, at: number, len: number, v: number) {
  put(h, at, len, v.toString(8).padStart(len - 1, '0') + '\0');
}

function header(name: string, size: number, type: string, spec: TarSpec, prefix = ''): Uint8Array {
  const h = new Uint8Array(512);
  put(h, 0, 100, name);
  octal(h, 100, 8, 0o644);
  octal(h, 108, 8, 501);
  octal(h, 116, 8, 20);
  if (spec.base256) {
    h[124] = 0x80;
    let v = size;
    for (let i = 135; i > 124; i--) {
      h[i] = v % 256;
      v = Math.floor(v / 256);
    }
  } else {
    octal(h, 124, 12, size);
  }
  octal(h, 136, 12, spec.mtimeS ?? 1_790_019_725);
  h.fill(0x20, 148, 156);
  h[156] = type.charCodeAt(0);
  if (spec.format === 'gnu') put(h, 257, 8, 'ustar  \0');
  else {
    put(h, 257, 6, 'ustar\0');
    put(h, 263, 2, '00');
  }
  put(h, 265, 32, 'mobile');
  put(h, 297, 32, 'staff');
  if (prefix) put(h, 345, 155, prefix);
  let sum = 0;
  for (const b of h) sum += b;
  put(h, 148, 8, sum.toString(8).padStart(6, '0') + '\0 ');
  return h;
}

function padded(data: Uint8Array): Uint8Array {
  const out = new Uint8Array(Math.ceil(data.length / 512) * 512);
  out.set(data);
  return out;
}

function paxRecords(records: Record<string, string>): Uint8Array {
  let text = '';
  for (const [k, v] of Object.entries(records)) {
    const body = ` ${k}=${v}\n`;
    let len = body.length + 1;
    while (String(len).length + body.length !== len) len = String(len).length + body.length;
    text += `${len}${body}`;
  }
  return enc.encode(text);
}

/** A complete tar with the end-of-archive blocks. */
export function buildTar(specs: TarSpec[]): Uint8Array {
  const blocks: Uint8Array[] = [];
  for (const spec of specs) {
    const data = bytesOf(spec.data);
    const type = spec.type ?? '0';
    if (spec.pax) {
      const body = paxRecords(spec.pax);
      blocks.push(header(`PaxHeader/${spec.path.slice(-80)}`, body.length, 'x', spec), padded(body));
    }
    let name = spec.path, prefix = '';
    if (enc.encode(name).length > 100) {
      if (spec.format === 'gnu') {
        const long = enc.encode(spec.path + '\0');
        blocks.push(header('././@LongLink', long.length, 'L', { ...spec, format: 'gnu' }), padded(long));
        name = spec.path.slice(0, 100);
      } else if (!spec.pax?.path) {
        const cut = spec.path.lastIndexOf('/');
        prefix = spec.path.slice(0, cut);
        name = spec.path.slice(cut + 1);
      } else {
        name = spec.path.slice(-100);
      }
    }
    blocks.push(header(name, type === '0' || type === '7' ? data.length : 0, type, spec, prefix));
    if (data.length && (type === '0' || type === '7')) blocks.push(padded(data));
  }
  blocks.push(new Uint8Array(1024));
  return concat(blocks);
}

export function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

export async function gzip(data: Uint8Array): Promise<Uint8Array> {
  const stream = streamOf(data).pipeThrough(new CompressionStream('gzip'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** A stream delivering `data` in pieces of the given sizes (cycled), or in one piece. */
export function streamOf(data: Uint8Array, sizes: number[] = [data.length || 1]): ReadableStream<Uint8Array<ArrayBuffer>> {
  let at = 0, k = 0;
  return new ReadableStream<Uint8Array<ArrayBuffer>>({
    pull(controller) {
      if (at >= data.length) return controller.close();
      const n = Math.max(1, sizes[k++ % sizes.length]);
      controller.enqueue(data.slice(at, at + n));
      at += n;
    },
  });
}

/** A seeded PRNG (mulberry32), so random splits are reproducible. */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** `count` split sizes between 1 and `max`. */
export function randomSizes(seed: number, count: number, max: number): number[] {
  const r = rng(seed);
  return Array.from({ length: count }, () => 1 + Math.floor(r() * max));
}

/** Pieces of `data` at random cut points. */
export function randomPieces(data: Uint8Array, seed: number, max: number): Uint8Array[] {
  const sizes = randomSizes(seed, 1 + Math.ceil(data.length / Math.max(1, max / 2)), max);
  const out: Uint8Array[] = [];
  for (let at = 0, k = 0; at < data.length; k++) {
    const n = sizes[k % sizes.length];
    out.push(data.subarray(at, at + n));
    at += n;
  }
  return out;
}

/** A value for buildBinaryPlist: dates as { date: Unix ms }. */
export type BplistInput = string | number | boolean | Uint8Array | { date: number } | BplistInput[] | { [k: string]: BplistInput };

/**
 * A bplist00 file, written the way CoreFoundation lays one out (objects, offset table, 32-byte trailer), for
 * testing the reader without depending on a capture-derived plist.
 */
export function buildBinaryPlist(root: BplistInput): Uint8Array {
  const objects: Uint8Array[] = [];
  const intBytes = (v: number): number[] => {
    if (v >= 0 && v < 256) return [0x10, v];
    if (v >= 0 && v < 65536) return [0x11, v >> 8, v & 0xff];
    const b = new Uint8Array(9);
    b[0] = 0x13;
    new DataView(b.buffer).setBigInt64(1, BigInt(v));
    return [...b];
  };
  const withLength = (kind: number, n: number): number[] => (n < 15 ? [(kind << 4) | n] : [(kind << 4) | 0xf, ...intBytes(n)]);
  const add = (v: BplistInput): number => {
    const ref = objects.length;
    objects.push(new Uint8Array(0)); // reserve the slot: children follow their parent
    let out: number[];
    if (typeof v === 'boolean') out = [v ? 0x09 : 0x08];
    else if (typeof v === 'number') {
      if (Number.isInteger(v)) out = intBytes(v);
      else {
        const b = new Uint8Array(9);
        b[0] = 0x23;
        new DataView(b.buffer).setFloat64(1, v);
        out = [...b];
      }
    } else if (typeof v === 'string') {
      // ASCII strings are bplist type 5, anything else UTF-16 (type 6); the range starts at NUL on purpose.
      // deno-lint-ignore no-control-regex
      if (/^[\x00-\x7f]*$/.test(v)) out = [...withLength(0x5, v.length), ...[...v].map((c) => c.charCodeAt(0))];
      else out = [...withLength(0x6, v.length), ...[...Array(v.length).keys()].flatMap((i) => [v.charCodeAt(i) >> 8, v.charCodeAt(i) & 0xff])];
    } else if (v instanceof Uint8Array) out = [...withLength(0x4, v.length), ...v];
    else if (Array.isArray(v)) {
      const refs = v.map(add);
      out = [...withLength(0xa, refs.length), ...refs];
    } else if ('date' in v && typeof v.date === 'number' && Object.keys(v).length === 1) {
      const b = new Uint8Array(9);
      b[0] = 0x33;
      new DataView(b.buffer).setFloat64(1, v.date / 1000 - 978_307_200);
      out = [...b];
    } else {
      const entries = Object.entries(v as Record<string, BplistInput>);
      const keys = entries.map(([k]) => add(k));
      const values = entries.map(([, x]) => add(x));
      out = [...withLength(0xd, entries.length), ...keys, ...values];
    }
    objects[ref] = new Uint8Array(out);
    return ref;
  };
  add(root);
  if (objects.length > 255) throw new Error('test plist too large for 1-byte refs');
  const header = new TextEncoder().encode('bplist00');
  const offsets: number[] = [];
  let at = header.length;
  for (const o of objects) {
    offsets.push(at);
    at += o.length;
  }
  const table = new Uint8Array(offsets.length * 2);
  offsets.forEach((o, i) => {
    table[2 * i] = o >> 8;
    table[2 * i + 1] = o & 0xff;
  });
  const trailer = new Uint8Array(32);
  const tv = new DataView(trailer.buffer);
  trailer[6] = 2; // offset int size
  trailer[7] = 1; // object ref size
  tv.setBigUint64(8, BigInt(objects.length));
  tv.setBigUint64(16, 0n);
  tv.setBigUint64(24, BigInt(at));
  return concat([header, ...objects, table, trailer]);
}

/**
 * A capture taken with baseband logging OFF, invented end to end: an ambtool log that says so, one unrelated
 * MDM profile stub, and no trace directory at all. It stands in for the 14-39-54 archive, which was never on
 * this Mac, and for its extracted folder, which has since been deleted from ~/Downloads. Nothing here is
 * capture-derived: the identifier is a reserved example domain and the dates are round numbers.
 *
 * `root` is the archive's top-level directory, whose name carries the button-press time.
 */
export function loggingOffFiles(root: string, installMs = Date.UTC(2026, 1, 3, 9, 0, 0)): TarSpec[] {
  const stub = buildBinaryPlist({
    InstallDate: { date: installMs },
    PayloadDisplayName: 'Example Device Management',
    PayloadIdentifier: 'com.example.mdm.settings',
    PayloadVersion: 1,
  });
  return [
    {
      path: `${root}/logs/Baseband/ambtool_output.log`,
      // ambtool's own wording when the profile is not installed.
      data: new TextEncoder().encode('Baseband logs are not enabled\n'),
    },
    // The reader only takes 'profile-<hex>.stub' under logs/MCState/Shared, as the phone names them.
    { path: `${root}/logs/MCState/Shared/profile-a1b2c3d4.stub`, data: stub },
  ];
}

/**
 * A tar of files read from disk, as a stream: each file is read only when the consumer pulls it, so a 133 MB
 * trace never sits in memory at once. It feeds a capture that exists only as an extracted folder, which is how
 * the real captures survive on a machine short of disk (the .tar.gz downloads get cleaned up).
 *
 * `path` is the name inside the tar, `from` the file on disk. Plain tar, not gzip: `readSysdiagnose` takes both.
 */
export function tarStreamOfFiles(files: readonly { path: string; from: string }[]): ReadableStream<Uint8Array> {
  let i = 0;
  return new ReadableStream({
    pull(c) {
      if (i >= files.length) {
        c.enqueue(new Uint8Array(1024)); // the end-of-archive blocks
        c.close();
        return;
      }
      const f = files[i++];
      let name = f.path, prefix = '';
      if (enc.encode(name).length > 100) {
        const cut = name.lastIndexOf('/');
        prefix = name.slice(0, cut);
        name = name.slice(cut + 1);
      }
      const data = Deno.readFileSync(f.from);
      c.enqueue(header(name, data.length, '0', { path: f.path }, prefix));
      if (data.length) c.enqueue(padded(data));
    },
  });
}

/**
 * A capture as a stream, from its `.tar.gz` or from its extracted folder. Returns the byte total for the reading
 * stage's progress: exact for an archive, and for a folder the tar's own size (headers plus padded bodies), which
 * is what the reader will actually see.
 */
export function openCapture(source: CaptureSource): { stream: ReadableStream<Uint8Array>; totalBytes: number } {
  if (source.kind === 'archive') {
    return { stream: Deno.openSync(source.path).readable, totalBytes: Deno.statSync(source.path).size };
  }
  // Only the parts the reader wants: the Baseband tree (ambtool log, trace directories) and MCState/Shared.
  const leaf = source.path.split('/').filter(Boolean).pop()!;
  const files: { path: string; from: string }[] = [];
  const walk = (rel: string) => {
    for (const e of Deno.readDirSync(`${source.path}/${rel}`)) {
      const next = `${rel}/${e.name}`;
      if (e.isDirectory) walk(next);
      else if (e.isFile) files.push({ path: `${leaf}/${next}`, from: `${source.path}/${next}` });
    }
  };
  for (const dir of ['logs/Baseband', 'logs/MCState/Shared']) {
    try {
      walk(dir);
    } catch {
      // absent in this capture (a profile-off folder has no MCState): nothing to add
    }
  }
  files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const totalBytes = files.reduce((n, f) => n + 512 + Math.ceil(Deno.statSync(f.from).size / 512) * 512, 1024);
  return { stream: tarStreamOfFiles(files), totalBytes };
}
