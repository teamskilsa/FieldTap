// The validation identities of the reference extractor, shipped as runtime self-checks ("Decoder health"), so a
// firmware update that shifts a field shows up as a failing check instead of a plausible-looking chart.

import type { PhyCheck } from '../types.ts';
import type { PhyStats } from './extract.ts';

/** A check passes while its identity holds for at least this share of what it checks. */
export const CHECK_THRESHOLD = 0.95;

export const count = (n: number): string => n.toLocaleString('en-US');
const percent = (share: number) => `${(share * 100).toFixed(1)}%`;
const signed = (v: number, digits: number) => (v >= 0 ? '+' : '') + v.toFixed(digits);

/** 1 when equal, else the smaller over the larger. */
const ratio = (a: number, b: number) => (a === b ? 1 : Math.max(a, b) === 0 ? 1 : Math.min(a, b) / Math.max(a, b));

export function phyChecks(s: PhyStats, tbsAvailable: boolean): PhyCheck[] {
  const out: PhyCheck[] = [];
  const check = (id: string, code: string, share: number, measured: string, expectation: string) =>
    out.push({ id, code, passed: share >= CHECK_THRESHOLD, measured, expectation });

  if (s.rsrqResiduals > 0) {
    const perRx = [...s.rsrqResidual.entries()].map(([k, r]) => `Rx${k} mean ${signed(r.mean, 3)} dB, sd ${r.sd.toFixed(3)} (${count(r.n)})`);
    const prb = [...s.inferredPrb.entries()].map(([e, n]) => `${e}: ${n}`).join(', ');
    check(
      'b193RsrqIdentity',
      '0xB193',
      s.rsrqWithinQuarterDb / s.rsrqResiduals,
      `${percent(s.rsrqWithinQuarterDb / s.rsrqResiduals)} within 0.25 dB. ${perRx.join('; ')}. N_RB inferred per EARFCN: ${prb}`,
      'RSRQ = RSRP - RSSI + 10log10(N_RB) on each Rx antenna',
    );
  }
  const t = s.dlTbs, dlTotal = t.table64 + t.table256 + t.retx + t.unexplained;
  if (tbsAvailable && dlTotal > 0) {
    const checked = dlTotal - t.retx;
    check(
      'b173TbsTable',
      '0xB173',
      checked > 0 ? (t.table64 + t.table256) / checked : 1,
      `${count(t.table64)} match the 64QAM table, ${count(t.table256)} the 256QAM table, ${count(t.retx)} retransmissions (MCS 29-31), ${count(t.unexplained)} unexplained`,
      'every new C-RNTI transport block has a TS 36.213 table 7.1.7.2.1-1 size',
    );
  }
  const u = s.ul, ulTotal = u.unique + u.ambiguous + u.uciOnly + u.noMatch;
  if (tbsAvailable && ulTotal > 0) {
    const checked = ulTotal - u.uciOnly;
    check(
      'b139TbsModulation',
      '0xB139',
      checked > 0 ? (u.unique + u.ambiguous) / checked : 1,
      `${count(u.unique)} give one MCS, ${count(u.ambiguous)} are ambiguous, ${count(u.uciOnly)} are UCI only, ${count(u.noMatch)} match no table size`,
      'TBS and modulation agree with TS 36.213 tables 7.1.7.2.1-1 and 8.6.1-1',
    );
  }
  const n = s.nrTbs;
  if (n.matched + n.unexplained > 0) {
    check(
      'b887TbsFormula',
      '0xB887',
      n.matched / (n.matched + n.unexplained),
      `${count(n.matched)} of ${count(n.matched + n.unexplained)} new transmissions match, ${count(n.retx)} retransmissions; negative control (MCS + 1): ${count(n.controlMatched)} match`,
      'TBS = TS 38.214 5.1.3.2 (qam256 MCS table, layers from the record)',
    );
  }
  const nr = s.nr;
  if (nr.deltaDecodes !== undefined && nr.deltaCrcFail !== undefined && nr.deltaPassBytes !== undefined) {
    check(
      'b887VsB888',
      '0xB887',
      Math.min(ratio(nr.b887Records, nr.deltaDecodes), ratio(nr.b887CrcFail, nr.deltaCrcFail), ratio(nr.b887PassBytes, nr.deltaPassBytes)),
      `0xB887: ${count(nr.b887Records)} decodes, ${count(nr.b887CrcFail)} CRC fails, ${count(nr.b887PassBytes)} pass bytes; 0xB888 counters: ${count(nr.deltaDecodes)} / ${count(nr.deltaCrcFail)} / ${count(nr.deltaPassBytes)}`,
      'the per-slot records sum to the MAC counters over the same window',
    );
  }
  const id = s.b888Identity;
  if (id.records > 0) {
    check(
      'b888CounterIdentity',
      '0xB888',
      id.holds / id.records,
      `${count(id.holds)} of ${count(id.records)} records`,
      'CRC pass + CRC fail = decodes, and pass bytes + fail bytes = TB bytes',
    );
  }
  if (s.macSamples > 0) {
    check(
      'b064HeaderAccounting',
      '0xB064',
      s.macConsistent / s.macSamples,
      `${count(s.macConsistent)} of ${count(s.macSamples)} MAC headers`,
      'subheaders and control elements use exactly the logged header length (TS 36.321 6.1.2)',
    );
  }
  return out;
}
