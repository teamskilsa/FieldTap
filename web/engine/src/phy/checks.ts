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
    const perRx = [...s.rsrqResidual.entries()].map(([k, r]) =>
      `Rx${k} mean ${signed(r.mean, 3)} dB, sd ${r.sd.toFixed(3)} (${count(r.n)})`
    );
    const prb = [...s.inferredPrb.entries()].map(([e, n]) => `${e}: ${n}`).join(', ');
    check(
      'b193RsrqIdentity',
      '0xB193',
      s.rsrqWithinQuarterDb / s.rsrqResiduals,
      `${percent(s.rsrqWithinQuarterDb / s.rsrqResiduals)} within 0.25 dB. ${
        perRx.join('; ')
      }. N_RB inferred per EARFCN: ${prb}`,
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
      `${count(t.table64)} match the 64QAM table, ${count(t.table256)} the 256QAM table, ${
        count(t.retx)
      } retransmissions (MCS 29-31), ${count(t.unexplained)} unexplained`,
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
      `${count(u.unique)} give one MCS, ${count(u.ambiguous)} are ambiguous, ${count(u.uciOnly)} are UCI only, ${
        count(u.noMatch)
      } match no table size`,
      'TBS and modulation agree with TS 36.213 tables 7.1.7.2.1-1 and 8.6.1-1',
    );
  }
  const n = s.nrTbs;
  if (n.matched + n.unexplained > 0) {
    check(
      'b887TbsFormula',
      '0xB887',
      n.matched / (n.matched + n.unexplained),
      `${count(n.matched)} of ${count(n.matched + n.unexplained)} new transmissions match, ${
        count(n.retx)
      } retransmissions; negative control (MCS + 1): ${count(n.controlMatched)} match`,
      'TBS = TS 38.214 5.1.3.2 (qam256 MCS table, layers from the record)',
    );
  }
  const nr = s.nr;
  if (nr.deltaDecodes !== undefined && nr.deltaCrcFail !== undefined && nr.deltaPassBytes !== undefined) {
    check(
      'b887VsB888',
      '0xB887',
      Math.min(
        ratio(nr.b887Records, nr.deltaDecodes),
        ratio(nr.b887CrcFail, nr.deltaCrcFail),
        ratio(nr.b887PassBytes, nr.deltaPassBytes),
      ),
      `0xB887: ${count(nr.b887Records)} decodes, ${count(nr.b887CrcFail)} CRC fails, ${
        count(nr.b887PassBytes)
      } pass bytes; 0xB888 counters: ${count(nr.deltaDecodes)} / ${count(nr.deltaCrcFail)} / ${
        count(nr.deltaPassBytes)
      }`,
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

  // The absolute-TTI axis every check below is keyed on. Its concentration is 0.9995 on both captures; anything
  // lower means the modem's logging latency has stopped being a constant, and every cross-record key with it.
  const axis = s.ttiAxis;
  if (axis.records > 0) {
    check(
      'ttiAxisLatency',
      '0xB173',
      axis.r,
      `offset ${
        axis.latencyMs.toFixed(1)
      } ms (modulo the 10.24 s cycle, against this capture's own time base), circular R = ${axis.r.toFixed(5)} over ${
        count(axis.records)
      } records`,
      "a record's timestamp trails the subframe it reports by a constant, so the 10.24 s SFN cycle can be unwrapped",
    );
  }

  const b126 = s.b126;
  if (b126.prbChecked > 0) {
    check(
      'b126PrbBitmap',
      '0xB126',
      b126.prbMatched / b126.prbChecked,
      `${count(b126.prbMatched)} of ${count(b126.prbChecked)} sub-records`,
      'popcount(the PRB allocation bitmap) is an N_RB 0xB173 reports for the same subframe',
    );
  }
  if (b126.rankChecked > 0) {
    check(
      'b126Rank',
      '0xB126',
      b126.rankMatched / b126.rankChecked,
      `${count(b126.rankMatched)} of ${count(b126.rankChecked)} sub-records, including ${
        count(b126.rankTxDiversity)
      } transmit-diversity subframes`,
      "rank equals 0xB173's layer count, with 4 layers and one transport block read as transmit diversity",
    );
  }
  if (b126.txPortsChecked > 0) {
    check(
      'b126TxAntennas',
      '0xB126',
      b126.txPortsMatched / b126.txPortsChecked,
      `${count(b126.txPortsMatched)} of ${count(b126.txPortsChecked)} sub-records whose serving cell had a MIB`,
      "the transmit antenna ports equal the MIB's antenna count for the serving cell",
    );
  }

  const b12a = s.b12a;
  if (b12a.elements > 0) {
    const cfi = b12a.elements > 0 ? b12a.consistent / b12a.elements : 1;
    out.push({
      id: 'b12aCfi',
      code: '0xB12A',
      passed: cfi >= 0.99,
      measured: `${count(b12a.consistent)} of ${count(b12a.elements)} elements, ${count(b12a.decoded)} carrying a CFI`,
      expectation: 'the field is 4 x CFI with CFI in {1, 2, 3}, and zero exactly when the decode flag is zero',
    });
  }

  const b16c = s.b16c;
  if (b16c.fieldsChecked > 0) {
    check(
      'b16cUplinkGrant',
      '0xB16C',
      b16c.fieldsMatched / b16c.fieldsChecked,
      `${count(b16c.fieldsMatched)} of ${count(b16c.fieldsChecked)} grants matched one-to-one with a PUSCH report`,
      "the uplink grant's start RB, RB count and modulation equal 0xB139's for the subframe four later",
    );
  }
  if (b16c.grantSubframes > 0) {
    out.push({
      id: 'b16cGrantTiming',
      code: '0xB16C',
      passed: b16c.precedesPusch / b16c.grantSubframes >= 0.9,
      measured: `${count(b16c.precedesPusch)} of ${count(b16c.grantSubframes)} grant subframes; ${
        count(b16c.assignmentsOnPdsch)
      } of ${count(b16c.assignmentSubframes)} assignment subframes carried a PDSCH`,
      expectation: 'a 16-byte record precedes an 0xB139 PUSCH by exactly 4 subframes (FDD uplink grant timing)',
    });
  }

  const b179 = s.b179;
  if (b179.records + b179.malformed > 0) {
    check(
      'b179Length',
      '0xB179',
      b179.records / (b179.records + b179.malformed),
      `${count(b179.records)} of ${count(b179.records + b179.malformed)} records`,
      'the body is exactly 28 + 12 x the neighbour count the record declares',
    );
  }
  if (b179.servingChecked > 0) {
    // Within 1 dB is the number the research reports (93% when stationary), but it falls to about 40% while
    // driving, where the phone moves between the two measurements: the gate is 3 dB, and both shares are shown.
    const mean = b179.servingDeltaSum / b179.servingChecked;
    out.push({
      id: 'b179ServingRsrp',
      code: '0xB179',
      passed: b179.servingWithin3Db / b179.servingChecked >= 0.9,
      measured: `mean ${signed(mean, 2)} dB over ${count(b179.servingChecked)} records; ${
        percent(b179.servingWithin1Db / b179.servingChecked)
      } within 1 dB, ${percent(b179.servingWithin3Db / b179.servingChecked)} within 3 dB`,
      expectation: "the serving RSRP is 0xB193's own for the same cell, within 3 dB (it is read on 0xB193's scale)",
    });
  }

  const b063 = s.b063;
  if (b063.tbChecked > 0) {
    check(
      'b063VsB173',
      '0xB063',
      b063.tbMatched / b063.tbChecked,
      `${count(b063.tbMatched)} of ${count(b063.tbChecked)} transport blocks`,
      'every transport block is a 0xB173 one on (SFN, subframe, carrier, HARQ, size)',
    );
  }
  if (b063.declared > 0) {
    // Reported, never gated: the walk's coverage is the weak point of this decode and its *drift* is the signal.
    out.push({
      id: 'b063Coverage',
      code: '0xB063',
      passed: true,
      measured: `${percent(b063.walked / b063.declared)} of ${count(b063.declared)} declared transport blocks; ${
        count(b063.exact)
      } of ${count(b063.records)} walks ended on the body's last byte, ${count(b063.resynced)} resynchronisations`,
      expectation:
        'coverage is reported, not gated: a fall means the PDCP tail rule changed, and the accounting is a floor either way',
    });
  }

  const x184c = s.x184c;
  if (x184c.records > 0) {
    check(
      'x184cFraming',
      '0x184C',
      x184c.framed / x184c.records,
      `${count(x184c.framed)} of ${count(x184c.records)} records; ${count(x184c.live)} transmitting chain samples, ${
        count(x184c.atLimit)
      } at the limit`,
      'the block walk (16-byte header + 120-byte sub-records) consumes the body exactly',
    );
  }
  if (x184c.blocks > 0) {
    check(
      'x184cSubframeField',
      '0x184C',
      x184c.subframesInRange / x184c.blocks,
      `${count(x184c.subframesInRange)} of ${count(x184c.blocks)} blocks; ${
        percent(x184c.blockSteps > 0 ? x184c.blockStepsByOne / x184c.blockSteps : 1)
      } of consecutive blocks step by one subframe`,
      "the block header's subframe field stays inside 0..9, which is what makes it a subframe counter at all",
    );
  }
  if (x184c.live > 0) {
    // Reported, never gated. The logged limit is the ceiling of the moment (it moves with the allocation) and the
    // power is the front end's own instant, so a few per cent read above it. That is why the UI says "at or above
    // its logged limit" rather than "capped", and why the limit carries medium confidence.
    out.push({
      id: 'x184cAgainstLimit',
      code: '0x184C',
      passed: true,
      measured: `${percent(x184c.atLimit / x184c.live)} of ${
        count(x184c.live)
      } transmitting samples sit at or above the chain's own limit; ${
        percent(1 - x184c.withinLimit / x184c.live)
      } read more than 0.5 dB above it`,
      expectation:
        'reported, not gated: power and limit are logged at different instants, so the share above it is drift to watch, not a failure',
    });
  }

  const clock = s.x1d0b;
  if (clock.steps > 0) {
    check(
      'x1d0bSequence',
      '0x1D0B',
      clock.stepsByOne / clock.steps,
      `${count(clock.stepsByOne)} of ${count(clock.steps)} consecutive records`,
      'the record sequence number steps by exactly 1 (the steps it misses are the holes in the trace)',
    );
  }
  return out;
}
