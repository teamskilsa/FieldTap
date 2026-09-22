// A tar reader fed arbitrary splits of the uncompressed stream (the TS counterpart of TarWalker in
// FTCore/SysdiagScanner.swift). ustar and GNU headers, pax 'x' records (path, size, mtime), GNU 'L' long names and
// base-256 sizes. Only entries `select` accepts are materialised, each into one buffer of its exact size; every
// other body is skipped by arithmetic, so a 900 MB sysdiagnose costs no more memory than what is kept.
//
// AppleDouble leaves ('._0x0000006F.bin', written by macOS tar next to every file with extended attributes) are
// skipped before `select` is asked: the user's archive has 130 of them beside the 130 chunks, and feeding them
// to the deframer would silently change its output.

export interface TarHeader {
  /** Full path in the archive, after pax / GNU long-name overrides. */
  path: string;
  size: number;
  /** The typeflag character ('0' regular, '5' directory, ...). A NUL typeflag reads as '0'. */
  type: string;
  /** Modification time, Unix seconds. */
  mtimeS: number;
}

export interface TarEntry extends TarHeader {
  bytes: Uint8Array;
}

export class TarError extends Error {
  constructor(readonly kind: 'notTar' | 'corrupt' | 'truncated', message: string) {
    super(message);
  }
}

export interface TarCounts {
  /** Real entries (files, directories, links), not counting pax / long-name headers. */
  entries: number;
  appleDoubleSkipped: number;
  selected: number;
  selectedBytes: number;
  /** Uncompressed tar bytes consumed. */
  bytes: number;
}

export interface TarReaderOptions {
  /** Asked for every regular, non-AppleDouble file; true keeps its bytes. */
  select: (header: TarHeader) => boolean;
  onEntry: (entry: TarEntry) => void;
  /** Called for every real entry (including skipped ones) before `select`, so a caller can see directory
   *  boundaries go by. */
  onHeader?: (header: TarHeader) => void;
  skipAppleDouble?: boolean;
}

const BLOCK = 512;
const decoder = new TextDecoder();

const isRegular = (type: string) => type === '0' || type === '7';
const leafOf = (path: string) => path.slice(path.lastIndexOf('/') + 1);

/** Why the entry the reader is in the middle of is being read. */
type Body = { kind: 'keep'; buffer: Uint8Array; header: TarHeader } | { kind: 'meta'; buffer: Uint8Array; type: string } | {
  kind: 'skip';
};

export class TarReader {
  readonly counts: TarCounts = { entries: 0, appleDoubleSkipped: 0, selected: 0, selectedBytes: 0, bytes: 0 };
  /** True once the end-of-archive zero block has been read. */
  ended = false;

  private readonly header = new Uint8Array(BLOCK);
  private headerFill = 0;
  private body: Body | null = null;
  private bodyFill = 0;
  private bodySize = 0;
  private pad = 0;
  private sawHeader = false;
  /** Overrides for the next entry, from a pax 'x' record or a GNU 'L' name. */
  private next: { path?: string; size?: number; mtimeS?: number } = {};
  private readonly skipAppleDouble: boolean;

  constructor(private readonly options: TarReaderOptions) {
    this.skipAppleDouble = options.skipAppleDouble ?? true;
  }

  /** True while an entry's body or padding is incomplete. */
  get midEntry(): boolean {
    return this.body !== null || this.pad > 0 || this.headerFill > 0;
  }

  feed(chunk: Uint8Array): void {
    this.counts.bytes += chunk.length;
    let i = 0;
    while (i < chunk.length) {
      if (this.ended) return; // everything after the end block is padding
      if (this.pad > 0) {
        const n = Math.min(this.pad, chunk.length - i);
        this.pad -= n;
        i += n;
      } else if (this.body !== null) {
        const n = Math.min(this.bodySize - this.bodyFill, chunk.length - i);
        if (this.body.kind !== 'skip') this.body.buffer.set(chunk.subarray(i, i + n), this.bodyFill);
        this.bodyFill += n;
        i += n;
        if (this.bodyFill === this.bodySize) this.endBody();
      } else {
        const n = Math.min(BLOCK - this.headerFill, chunk.length - i);
        this.header.set(chunk.subarray(i, i + n), this.headerFill);
        this.headerFill += n;
        i += n;
        if (this.headerFill === BLOCK) {
          this.headerFill = 0;
          this.startEntry();
        }
      }
    }
  }

  /** Call at the end of input: throws when the stream stopped inside an entry or before the end-of-archive
   *  block. The second matters: an inflater given a cut-short gzip may simply stop at an entry boundary. */
  finish(): void {
    if (!this.sawHeader) throw new TarError('notTar', 'empty input');
    if (this.midEntry) throw new TarError('truncated', 'the archive ends inside an entry');
    if (!this.ended) throw new TarError('truncated', 'the archive ends before its end-of-archive block');
  }

  private startEntry(): void {
    const h = this.header;
    if (h.every((b) => b === 0)) {
      if (!this.sawHeader) throw new TarError('notTar', 'no tar header');
      this.ended = true;
      return;
    }
    if (!checksumOk(h)) {
      throw new TarError(this.sawHeader ? 'corrupt' : 'notTar', 'tar header checksum mismatch');
    }
    this.sawHeader = true;
    const rawType = String.fromCharCode(h[156]);
    const type = rawType === '\0' ? '0' : rawType;
    const next = this.next;
    if (type === 'x' || type === 'g' || type === 'L' || type === 'K') {
      // Metadata for the next real entry ('g' global pax and 'K' long link are read and ignored). A pax size
      // override is for that entry, never for another metadata header in between.
      const metaSize = sizeOf(h);
      this.beginBody({ kind: 'meta', buffer: new Uint8Array(metaSize), type }, metaSize);
      return;
    }
    const size = next.size ?? sizeOf(h);
    this.next = {};
    const header: TarHeader = { path: next.path ?? nameOf(h), size, type, mtimeS: next.mtimeS ?? octal(h, 136, 12) };
    this.counts.entries++;
    this.options.onHeader?.(header);
    let body: Body = { kind: 'skip' };
    if (isRegular(type)) {
      if (this.skipAppleDouble && leafOf(header.path).startsWith('._')) {
        this.counts.appleDoubleSkipped++;
      } else if (this.options.select(header)) {
        this.counts.selected++;
        this.counts.selectedBytes += size;
        body = { kind: 'keep', buffer: new Uint8Array(size), header };
      }
    }
    // Directories, links and devices carry no body whatever their size field says.
    this.beginBody(body, isRegular(type) ? size : 0);
  }

  private beginBody(body: Body, size: number): void {
    this.body = body;
    this.bodySize = size;
    this.bodyFill = 0;
    if (size === 0) this.endBody();
  }

  private endBody(): void {
    const body = this.body!;
    this.body = null;
    this.pad = (BLOCK - (this.bodySize % BLOCK)) % BLOCK;
    if (body.kind === 'keep') {
      this.options.onEntry({ ...body.header, bytes: body.buffer });
    } else if (body.kind === 'meta') {
      if (body.type === 'L') this.next.path = cString(body.buffer, 0, body.buffer.length);
      if (body.type === 'x') Object.assign(this.next, paxOverrides(body.buffer));
    }
  }
}

function cString(b: Uint8Array, from: number, len: number): string {
  let end = from;
  while (end < from + len && b[end] !== 0) end++;
  return decoder.decode(b.subarray(from, end));
}

/** Octal text as tar writes numbers: optional leading spaces, digits, then a NUL or space. */
function octal(b: Uint8Array, from: number, len: number): number {
  const end = from + len;
  let i = from;
  while (i < end && b[i] === 0x20) i++;
  let v = 0;
  for (; i < end && b[i] >= 0x30 && b[i] <= 0x37; i++) v = v * 8 + (b[i] - 0x30);
  return v;
}

/** The size field: octal, or GNU base-256 when the top bit of the first byte is set. */
function sizeOf(h: Uint8Array): number {
  if (h[124] & 0x80) {
    let v = h[124] & 0x7f;
    for (let i = 125; i < 136; i++) v = v * 256 + h[i];
    return v;
  }
  return octal(h, 124, 12);
}

/** POSIX ustar splits long paths into prefix (345..500) and name; GNU tar ('ustar  ') uses those bytes for other
 *  things, so the prefix is read only for 'ustar\0'. */
function nameOf(h: Uint8Array): string {
  const name = cString(h, 0, 100);
  const posix = h[257] === 0x75 && h[258] === 0x73 && h[259] === 0x74 && h[260] === 0x61 && h[261] === 0x72 &&
    h[262] === 0;
  if (!posix) return name;
  const prefix = cString(h, 345, 155);
  return prefix ? prefix + '/' + name : name;
}

/** The header checksum: the byte sum with the checksum field read as spaces (signed sums are accepted too). */
function checksumOk(h: Uint8Array): boolean {
  const stored = octal(h, 148, 8);
  let unsigned = 0, signed = 0;
  for (let i = 0; i < BLOCK; i++) {
    const b = i >= 148 && i < 156 ? 0x20 : h[i];
    unsigned += b;
    signed += b > 127 ? b - 256 : b;
  }
  return stored === unsigned || stored === signed;
}

/** pax records are '<len> <key>=<value>\n', measured by their length prefix (values may hold newlines). */
function paxOverrides(buf: Uint8Array): { path?: string; size?: number; mtimeS?: number } {
  const out: { path?: string; size?: number; mtimeS?: number } = {};
  let i = 0;
  while (i < buf.length) {
    let sp = i;
    while (sp < buf.length && buf[sp] !== 0x20) sp++;
    const len = Number(decoder.decode(buf.subarray(i, sp)));
    if (!Number.isInteger(len) || len <= 0 || i + len > buf.length) break;
    const record = decoder.decode(buf.subarray(sp + 1, i + len - 1)); // drop the trailing '\n'
    const eq = record.indexOf('=');
    if (eq > 0) {
      const key = record.slice(0, eq), value = record.slice(eq + 1);
      if (key === 'path') out.path = value;
      else if (key === 'size' && /^\d+$/.test(value)) out.size = Number(value);
      else if (key === 'mtime' && Number.isFinite(Number(value))) out.mtimeS = Number(value);
    }
    i += len;
  }
  return out;
}
