// TS 38.214 5.1.3: the PDSCH MCS tables 5.1.3.1-1/-2/-3 and the transport block size of 5.1.3.2 (the formula,
// with table 5.1.3.2-1 for small sizes), typed from the specification (the port of FTPhy's NrTbs.swift).

export type NrMcsTable = 'qam64' | 'qam256' | 'qam64LowSe';

/** (Qm, R x 1024) per MCS index; the reserved indexes (retransmissions) are not listed. */
type McsEntry = readonly [qm: number, r1024: number];

/** Table 5.1.3.1-1 (qam64), MCS 0-28. */
const TABLE1: readonly McsEntry[] = [
  [2, 120], [2, 157], [2, 193], [2, 251], [2, 308], [2, 379], [2, 449], [2, 526], [2, 602], [2, 679],
  [4, 340], [4, 378], [4, 434], [4, 490], [4, 553], [4, 616], [4, 658],
  [6, 438], [6, 466], [6, 517], [6, 567], [6, 616], [6, 666], [6, 719], [6, 772], [6, 822], [6, 873], [6, 910],
  [6, 948],
];

/** Table 5.1.3.1-2 (qam256), MCS 0-27. */
const TABLE2: readonly McsEntry[] = [
  [2, 120], [2, 193], [2, 308], [2, 449], [2, 602],
  [4, 378], [4, 434], [4, 490], [4, 553], [4, 616], [4, 658],
  [6, 466], [6, 517], [6, 567], [6, 616], [6, 666], [6, 719], [6, 772], [6, 822], [6, 873],
  [8, 682.5], [8, 711], [8, 754], [8, 797], [8, 841], [8, 885], [8, 916.5], [8, 948],
];

/** Table 5.1.3.1-3 (qam64LowSE), MCS 0-28. */
const TABLE3: readonly McsEntry[] = [
  [2, 30], [2, 40], [2, 50], [2, 64], [2, 78], [2, 99], [2, 120], [2, 157], [2, 193], [2, 251], [2, 308],
  [2, 379], [2, 449], [2, 526], [2, 602],
  [4, 340], [4, 378], [4, 434], [4, 490], [4, 553], [4, 616],
  [6, 438], [6, 466], [6, 517], [6, 567], [6, 616], [6, 666], [6, 719], [6, 772],
];

export const NR_MCS_TABLES: Record<NrMcsTable, readonly McsEntry[]> = { qam64: TABLE1, qam256: TABLE2, qam64LowSe: TABLE3 };

/** Table 5.1.3.2-1: TBS for N_info <= 3824. */
export const NR_SMALL_TBS: readonly number[] = [
  24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 144, 152, 160, 168, 176, 184, 192, 208, 224, 240,
  256, 272, 288, 304, 320, 336, 352, 368, 384, 408, 432, 456, 480, 504, 528, 552, 576, 608, 640, 672, 704, 736, 768,
  808, 848, 888, 928, 984, 1032, 1064, 1128, 1160, 1192, 1224, 1256, 1288, 1320, 1352, 1416, 1480, 1544, 1608, 1672,
  1736, 1800, 1864, 1928, 2024, 2088, 2152, 2216, 2280, 2408, 2472, 2536, 2600, 2664, 2728, 2792, 2856, 2976, 3104,
  3240, 3368, 3496, 3624, 3752, 3824,
];

/** Modulation order of an MCS, including the reserved retransmission indexes at the top of the table. */
export function nrQm(table: NrMcsTable, mcs: number): number | null {
  const e = NR_MCS_TABLES[table];
  if (mcs >= 0 && mcs < e.length) return e[mcs][0];
  const reserved = table === 'qam256' ? [2, 4, 6, 8] : [2, 4, 6];
  return reserved[mcs - e.length] ?? null;
}

/** (Qm, R x 1024) of a listed MCS, or null for a reserved one. */
export function nrMcs(table: NrMcsTable, mcs: number): McsEntry | null {
  return NR_MCS_TABLES[table][mcs] ?? null;
}

/**
 * TS 38.214 5.1.3.2 in bits: N_RE = min(156, N'RE) x nPRB, N_info = N_RE x R x Qm x layers, then the quantisation
 * of steps 3-4. `r` is the code rate (0-1). 'round' in step 4 rounds half to even, as the reference extractor
 * does; ties need (N_info - 24) / 2^n to be exactly x.5 and do not occur in practice.
 */
export function nrTbsBits(nRePerPrb: number, nPrb: number, qm: number, r: number, layers: number): number | null {
  const nRe = Math.min(156, nRePerPrb) * nPrb;
  const nInfo = nRe * r * qm * layers;
  if (nInfo <= 0) return 0;
  if (nInfo <= 3824) {
    const n = Math.max(3, Math.floor(Math.log2(nInfo)) - 6);
    const step = 2 ** n;
    const q = Math.max(24, step * Math.floor(nInfo / step));
    return NR_SMALL_TBS.find((t) => t >= q) ?? null;
  }
  const n = Math.floor(Math.log2(nInfo - 24)) - 5;
  const step = 2 ** n;
  const q = Math.max(3840, step * roundHalfEven((nInfo - 24) / step));
  const withCrc = q + 24;
  const segmented = (c: number) => 8 * c * Math.ceil(withCrc / (8 * c)) - 24;
  if (r <= 0.25) return segmented(Math.ceil(withCrc / 3816));
  if (q > 8424) return segmented(Math.ceil(withCrc / 8424));
  return 8 * Math.ceil(withCrc / 8) - 24;
}

/** Bytes of one transport block for an MCS of `table`; null for a reserved MCS or an empty allocation. */
export function nrTbsBytes(table: NrMcsTable, mcs: number, nPrb: number, layers: number, nRePerPrb: number): number | null {
  const e = nrMcs(table, mcs);
  if (!e || nPrb <= 0 || layers <= 0 || nRePerPrb <= 0) return null;
  const bits = nrTbsBits(nRePerPrb, nPrb, e[0], e[1] / 1024, layers);
  return bits === null ? null : bits / 8;
}

function roundHalfEven(x: number): number {
  const f = Math.floor(x), d = x - f;
  if (d > 0.5) return f + 1;
  if (d < 0.5) return f;
  return f % 2 === 0 ? f : f + 1;
}
