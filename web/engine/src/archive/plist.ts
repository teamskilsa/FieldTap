// Property lists, XML and binary (bplist00): enough for the MCState profile stubs, which iOS writes as XML today
// but has written as binary before. Dates come back as PlistDate (Unix ms).

export type PlistValue =
  | string
  | number
  | bigint
  | boolean
  | null
  | PlistDate
  | Uint8Array
  | PlistValue[]
  | PlistDict;

export interface PlistDict {
  [key: string]: PlistValue;
}

/** A plist <date>. A class, not a {ms} object, so a dict can never be mistaken for one. */
export class PlistDate {
  constructor(readonly ms: number) {}
}

export class PlistError extends Error {}

export const isDict = (v: PlistValue | undefined): v is PlistDict =>
  typeof v === 'object' && v !== null && !Array.isArray(v) && !(v instanceof Uint8Array) && !(v instanceof PlistDate);

/** Either form, by its first bytes. */
export function parsePlist(bytes: Uint8Array): PlistValue {
  const magic = new TextDecoder().decode(bytes.subarray(0, 8));
  if (magic === 'bplist00') return parseBinaryPlist(bytes);
  return parseXmlPlist(new TextDecoder().decode(bytes));
}

// --------------------------------------------------------------------------------------------------------- XML

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, (_, e: string) => {
    if (e[0] !== '#') return ENTITIES[e];
    return String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
  });
}

interface Tag {
  name: string;
  closing: boolean;
  selfClosing: boolean;
}

/** A small pull tokenizer: tags and the text between them. Comments, PIs and the DOCTYPE are skipped. */
class XmlTokens {
  private i = 0;
  constructor(private readonly s: string) {}

  nextTag(): Tag | null {
    for (;;) {
      const lt = this.s.indexOf('<', this.i);
      if (lt < 0) return null;
      if (this.s.startsWith('<!--', lt)) {
        this.i = this.after(lt, '-->');
        continue;
      }
      if (this.s.startsWith('<?', lt) || this.s.startsWith('<!', lt)) {
        this.i = this.after(lt, '>');
        continue;
      }
      const gt = this.s.indexOf('>', lt);
      if (gt < 0) throw new PlistError('unterminated tag');
      const body = this.s.slice(lt + 1, gt).trim();
      this.i = gt + 1;
      const closing = body.startsWith('/');
      const selfClosing = body.endsWith('/');
      const name = body.replace(/^\//, '').replace(/\/$/, '').trim().split(/\s+/)[0];
      return { name, closing, selfClosing };
    }
  }

  /** The text up to the closing tag `</name>`, consuming it. */
  textUntil(name: string): string {
    const end = this.s.indexOf(`</${name}>`, this.i);
    if (end < 0) throw new PlistError(`missing </${name}>`);
    const text = this.s.slice(this.i, end);
    this.i = end + name.length + 3;
    return decodeEntities(text);
  }

  private after(from: number, marker: string): number {
    const at = this.s.indexOf(marker, from);
    if (at < 0) throw new PlistError('unterminated markup');
    return at + marker.length;
  }
}

export function parseXmlPlist(text: string): PlistValue {
  const t = new XmlTokens(text);
  let tag = t.nextTag();
  if (tag?.name === 'plist' && !tag.closing) tag = tag.selfClosing ? null : t.nextTag();
  if (!tag) throw new PlistError('empty plist');
  return xmlValue(t, tag, 0);
}

function xmlValue(t: XmlTokens, tag: Tag, depth: number): PlistValue {
  if (depth > 64) throw new PlistError('plist nested too deeply');
  if (tag.closing) throw new PlistError(`unexpected </${tag.name}>`);
  const text = () => (tag.selfClosing ? '' : t.textUntil(tag.name));
  switch (tag.name) {
    case 'string':
      return text();
    case 'integer': {
      const s = text().trim();
      const n = Number(s);
      return Number.isSafeInteger(n) ? n : BigInt(s);
    }
    case 'real':
      return Number(text().trim());
    case 'true':
      if (!tag.selfClosing) t.textUntil('true');
      return true;
    case 'false':
      if (!tag.selfClosing) t.textUntil('false');
      return false;
    case 'date': {
      const ms = Date.parse(text().trim());
      if (Number.isNaN(ms)) throw new PlistError('bad <date>');
      return new PlistDate(ms);
    }
    case 'data':
      return base64(text());
    case 'array': {
      const out: PlistValue[] = [];
      if (tag.selfClosing) return out;
      for (;;) {
        const next = t.nextTag();
        if (!next) throw new PlistError('unterminated <array>');
        if (next.closing && next.name === 'array') return out;
        out.push(xmlValue(t, next, depth + 1));
      }
    }
    case 'dict': {
      const out: PlistDict = {};
      if (tag.selfClosing) return out;
      for (;;) {
        const next = t.nextTag();
        if (!next) throw new PlistError('unterminated <dict>');
        if (next.closing && next.name === 'dict') return out;
        if (next.name !== 'key') throw new PlistError(`<${next.name}> where a <key> belongs`);
        const key = next.selfClosing ? '' : t.textUntil('key');
        const valueTag = t.nextTag();
        if (!valueTag || valueTag.closing) throw new PlistError(`no value for key ${key}`);
        out[key] = xmlValue(t, valueTag, depth + 1);
      }
    }
    default:
      throw new PlistError(`unknown plist element <${tag.name}>`);
  }
}

function base64(s: string): Uint8Array {
  const clean = s.replace(/\s+/g, '');
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ------------------------------------------------------------------------------------------------------ binary

/** Seconds between the Unix epoch and 2001-01-01, CFAbsoluteTime's zero. */
const CF_EPOCH_S = 978_307_200;

export function parseBinaryPlist(b: Uint8Array): PlistValue {
  if (b.length < 40) throw new PlistError('binary plist too short');
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const trailer = b.length - 32;
  const offsetSize = b[trailer + 6];
  const refSize = b[trailer + 7];
  const count = Number(view.getBigUint64(trailer + 8));
  const top = Number(view.getBigUint64(trailer + 16));
  const tableAt = Number(view.getBigUint64(trailer + 24));
  if (!offsetSize || !refSize || top >= count || tableAt + count * offsetSize > trailer) {
    throw new PlistError('bad binary plist trailer');
  }
  const uint = (at: number, size: number) => {
    if (at + size > b.length) throw new PlistError('binary plist read past the end');
    let v = 0;
    for (let i = 0; i < size; i++) v = v * 256 + b[at + i];
    return v;
  };
  const offsetOf = (ref: number) => {
    if (ref >= count) throw new PlistError('object ref out of range');
    return uint(tableAt + ref * offsetSize, offsetSize);
  };
  const decodeUtf16be = (at: number, n: number) => {
    let s = '';
    for (let i = 0; i < n; i++) s += String.fromCharCode(uint(at + 2 * i, 2));
    return s;
  };

  const object = (ref: number, depth: number): PlistValue => {
    if (depth > 64) throw new PlistError('plist nested too deeply');
    const at = offsetOf(ref);
    const marker = b[at];
    const kind = marker >> 4, info = marker & 0xf;
    // The length of data, strings and collections: in the marker, or an int object after it.
    const length = (): [number, number] => {
      if (info !== 0xf) return [info, at + 1];
      const intMarker = b[at + 1];
      if (intMarker >> 4 !== 0x1) throw new PlistError('bad length marker');
      const size = 1 << (intMarker & 0xf);
      return [uint(at + 2, size), at + 2 + size];
    };
    switch (kind) {
      case 0x0:
        if (marker === 0x00) return null;
        if (marker === 0x08) return false;
        if (marker === 0x09) return true;
        throw new PlistError(`unknown marker 0x${marker.toString(16)}`);
      case 0x1: {
        const size = 1 << info;
        if (size === 8) return safe(view.getBigInt64(at + 1));
        if (size === 16) return safe(view.getBigInt64(at + 9)); // 128-bit: the low 64 bits hold any real value
        return uint(at + 1, size);
      }
      case 0x2:
        return info === 2 ? view.getFloat32(at + 1) : view.getFloat64(at + 1);
      case 0x3:
        return new PlistDate(Math.round((view.getFloat64(at + 1) + CF_EPOCH_S) * 1000));
      case 0x4: {
        const [n, from] = length();
        return b.slice(from, from + n);
      }
      case 0x5: {
        const [n, from] = length();
        let s = '';
        for (let i = 0; i < n; i++) s += String.fromCharCode(uint(from + i, 1));
        return s;
      }
      case 0x6: {
        const [n, from] = length();
        return decodeUtf16be(from, n);
      }
      case 0x8:
        return uint(at + 1, info + 1); // UID: only in keyed archives, read as its number
      case 0xa: {
        const [n, from] = length();
        const out: PlistValue[] = [];
        for (let i = 0; i < n; i++) out.push(object(uint(from + i * refSize, refSize), depth + 1));
        return out;
      }
      case 0xd: {
        const [n, from] = length();
        const out: PlistDict = {};
        for (let i = 0; i < n; i++) {
          const key = object(uint(from + i * refSize, refSize), depth + 1);
          if (typeof key !== 'string') throw new PlistError('non-string dict key');
          out[key] = object(uint(from + (n + i) * refSize, refSize), depth + 1);
        }
        return out;
      }
      default:
        throw new PlistError(`unknown marker 0x${marker.toString(16)}`);
    }
  };
  return object(top, 0);
}

const safe = (v: bigint): number | bigint => (v >= BigInt(Number.MIN_SAFE_INTEGER) && v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : v);
