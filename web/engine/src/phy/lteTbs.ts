// TS 36.213 transport block sizes: table 7.1.7.2.1-1 (I_TBS x N_PRB), the PDSCH MCS tables 7.1.7.1-1 and -1A and
// the PUSCH MCS table 8.6.1-1. The 34 x 110 size table is generated source (lteTbsTable.ts, written by
// tools/gen_lte_tbs.ts from the 3GPP document itself); the short MCS tables are typed here from the same document.

import { LTE_TBS_ROWS } from './lteTbsTable.ts';

/** Table 7.1.7.1-1: PDSCH MCS 0-28 -> I_TBS (64QAM table). */
export const DL_MCS_TO_ITBS: readonly number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 10, 11, 12, 13, 14, 15, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
];

/** Table 7.1.7.1-1A: PDSCH MCS 0-27 -> I_TBS (256QAM table). */
export const DL_MCS256_TO_ITBS: readonly number[] = [
  0, 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 27, 28, 29, 30, 31, 32, 33,
];

/** Table 8.6.1-1: PUSCH MCS 0-28 -> I_TBS. */
export const UL_MCS_TO_ITBS: readonly number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26,
];

/** Table 8.6.1-1's modulation order per PUSCH MCS (no 64QAM restriction): QPSK 0-10, 16QAM 11-20, 64QAM 21-28. */
export function ulQm(mcs: number): number | null {
  if (mcs >= 0 && mcs <= 10) return 2;
  if (mcs >= 11 && mcs <= 20) return 4;
  if (mcs >= 21 && mcs <= 28) return 6;
  return null;
}

/** A TBS table to look sizes up in: the generated one, or one a test supplies. */
export class LteTbsLookup {
  /** rows[I_TBS][N_PRB - 1] in bits. */
  constructor(readonly rows: readonly (readonly number[])[]) {}

  get isAvailable(): boolean {
    return this.rows.length > 0;
  }

  /** Transport block size in bits for one layer, or null outside the table. */
  bits(iTbs: number, nPrb: number): number | null {
    const row = this.rows[iTbs];
    return row && nPrb >= 1 && nPrb <= row.length ? row[nPrb - 1] : null;
  }

  /** PDSCH TBS for an MCS. `layers` > 1 reads the layers x N_PRB column (TS 36.213 7.1.7.2.2, N_PRB <= 55); larger
   *  allocations need the layer translation table 7.1.7.2.2-1, which 10 MHz cells never reach. */
  dl(mcs: number, nPrb: number, layers: number, table256: boolean): number | null {
    const iTbs = (table256 ? DL_MCS256_TO_ITBS : DL_MCS_TO_ITBS)[mcs];
    return iTbs === undefined ? null : this.bits(iTbs, nPrb * layers);
  }

  /** Every I_TBS whose size at `nPrb` is `bits`. */
  iTbsMatching(bits: number, nPrb: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.rows.length; i++) if (this.bits(i, nPrb) === bits) out.push(i);
    return out;
  }

  /** The PUSCH MCS a (TBS, nRB, Qm) triple implies, by inverting table 8.6.1-1: the MCSs whose I_TBS gives the size
   *  and whose modulation matches. Empty when nothing fits, several when it is ambiguous. */
  ulMcs(bits: number, nPrb: number, qm: number | null): { matchesTable: boolean; mcs: number[] } {
    const candidates = this.iTbsMatching(bits, nPrb);
    const mcs: number[] = [];
    for (let m = 0; m <= 28; m++) if (candidates.includes(UL_MCS_TO_ITBS[m]) && ulQm(m) === qm) mcs.push(m);
    return { matchesTable: candidates.length > 0, mcs };
  }
}

/** The table this build carries (empty until tools/gen_lte_tbs.ts has run). */
export const BUILT_IN_TBS = new LteTbsLookup(LTE_TBS_ROWS);
