// MD5 (RFC 1321), incremental, for parity checks only: the fixtures' manifests and the Python deframer's outputs
// are identified by md5. Not part of the engine (src/ never hashes anything).
//
//   deno run -A tools/md5.ts FILE...     prints '<md5>  FILE' like md5sum

const S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
const K = new Uint32Array(64).map((_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0);

export class Md5 {
  private readonly h = new Uint32Array([0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]);
  private readonly block = new Uint8Array(64);
  private readonly words = new Uint32Array(16);
  private fill = 0;
  private length = 0;

  update(data: Uint8Array): this {
    this.length += data.length;
    let i = 0;
    if (this.fill > 0) {
      const n = Math.min(64 - this.fill, data.length);
      this.block.set(data.subarray(0, n), this.fill);
      this.fill += n;
      i = n;
      if (this.fill < 64) return this;
      this.compress(this.block, 0);
      this.fill = 0;
    }
    for (; i + 64 <= data.length; i += 64) this.compress(data, i);
    if (i < data.length) {
      this.block.set(data.subarray(i), 0);
      this.fill = data.length - i;
    }
    return this;
  }

  hex(): string {
    const bits = this.length * 8;
    const pad = new Uint8Array(((this.fill < 56 ? 56 : 120) - this.fill) + 8);
    pad[0] = 0x80;
    const view = new DataView(pad.buffer);
    view.setUint32(pad.length - 8, bits >>> 0, true);
    view.setUint32(pad.length - 4, Math.floor(bits / 2 ** 32), true);
    this.update(pad);
    let out = '';
    for (const word of this.h) for (let b = 0; b < 4; b++) out += ((word >>> (8 * b)) & 0xff).toString(16).padStart(2, '0');
    return out;
  }

  private compress(d: Uint8Array, at: number): void {
    const w = this.words;
    for (let j = 0; j < 16; j++) {
      const o = at + 4 * j;
      w[j] = d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);
    }
    let [a, b, c, e] = this.h;
    for (let j = 0; j < 64; j++) {
      let f: number, g: number;
      if (j < 16) {
        f = (b & c) | (~b & e);
        g = j;
      } else if (j < 32) {
        f = (e & b) | (~e & c);
        g = (5 * j + 1) % 16;
      } else if (j < 48) {
        f = b ^ c ^ e;
        g = (3 * j + 5) % 16;
      } else {
        f = c ^ (b | ~e);
        g = (7 * j) % 16;
      }
      const t = e;
      e = c;
      c = b;
      const x = (a + f + K[j] + w[g]) | 0;
      const s = S[(j >> 4) * 4 + (j % 4)];
      b = (b + ((x << s) | (x >>> (32 - s)))) | 0;
      a = t;
    }
    this.h[0] += a;
    this.h[1] += b;
    this.h[2] += c;
    this.h[3] += e;
  }
}

export function md5(data: Uint8Array): string {
  return new Md5().update(data).hex();
}

export async function md5File(path: string): Promise<string> {
  const h = new Md5();
  const file = await Deno.open(path);
  for await (const chunk of file.readable) h.update(chunk); // the stream closes the file at its end
  return h.hex();
}

if (import.meta.main) {
  for (const path of Deno.args) console.log(`${await md5File(path)}  ${path}`);
}
