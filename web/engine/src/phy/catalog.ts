// What cannot be plotted from this iPhone, and why: the "not possible" and "not decoded yet" lists of the design's
// PHY dashboard (FTPhy's PhyCatalog.swift), plus a "not decodable (version N)" entry for every record that came in a
// version the decoders were not validated for. An empty chart is never a mystery.

import type { Availability, EncryptedCensus } from '../types.ts';
import { count } from './checks.ts';
import { VALIDATED_VERSIONS } from './metrics.ts';

const entry = (
  id: string,
  title: string,
  status: Availability['status'],
  codes: string[],
  reason: string,
): Availability => ({
  id,
  title,
  status,
  reason,
  codes,
});

export const NOT_POSSIBLE: readonly Availability[] = [
  entry(
    'nrSinr',
    'NR SINR / SNR',
    'encryptedByModem',
    ['0xB8DD'],
    '0xB8DD (NR5G LL1 FW Serving FTL) is a secure record: the modem encrypts its body and only the header is readable. NR SINR appears only when an RRC measurement report carries it.',
  ),
  entry(
    'nrFirmwareCsi',
    'NR CSI from the firmware',
    'encryptedByModem',
    ['0xB8E2'],
    '0xB8E2 (NR5G LL1 FW CSF Reports) is encrypted by the modem.',
  ),
  entry(
    'nrPhyEncrypted',
    'NR ML1 / LL1 records',
    'encryptedByModem',
    ['0xB8C5', '0xB8CB', '0xB9A9', '0xB8C8', '0xB8CD', '0xB8C0', '0xB8CF', '0xB8A3', '0xB881', '0xB8C4'],
    'Most NR physical-layer records (for example 0xB881 NR MAC UL TB stats) arrive encrypted. FieldTap counts them and never guesses at their contents.',
  ),
  entry(
    'lteSinr',
    'LTE SINR / SNR',
    'notFoundInPlainLogs',
    ['0xB193', '0xB134', '0xB11B', '0xB15B', '0xB122', '0xB123'],
    "Not in any plain record decoded so far. The old 'projected SIR' slot of 0xB193 is not SIR on v66 (it reads 0 in about half the records and up to 220 dB). The candidates 0xB134, 0xB11B, 0xB15B and 0xB122/0xB123 are unverified.",
  ),
  entry(
    'nrPerAntennaRsrp',
    'NR RSRP per antenna',
    'notOnIPhone',
    ['0xB97F'],
    'The per-Rx fields of 0xB97F are zero on this modem, and beam-level RSRP is not validated, so NR RSRP is shown per cell only.',
  ),
  entry(
    'liveValues',
    'Live values, and a long history',
    'notOnIPhone',
    [],
    "iOS gives apps no modem data. The trace arrives only in a sysdiagnose you trigger, and the archive keeps only the modem's newest ~128 MiB of trace (27 s in a busy EN-DC capture), which may start after you pressed the buttons.",
  ),
  entry(
    'actualTxPower',
    'Actual LTE Tx power',
    'available',
    ['0xB139', '0x184C', '0xB146'],
    "0xB139 carries the required PUSCH power before Pcmax capping, and 0x184C now adds the front end's own per-chain transmit power and its per-chain limit, which is what says whether the phone was transmit-limited. The two are different quantities: a best fit between them leaves a 3.8 dB residual, so the front-end figure is labelled as the front end's and carries medium confidence. 0xB146 (UL AGC Tx Report) was searched for a third figure and rejected: the best candidate field correlates at |r| = 0.71-0.89 at different offsets in the two captures, with slopes disagreeing by a factor of two.",
  ),
  entry(
    'continuousTa',
    'Continuous timing advance',
    'notDecodedYet',
    ['0xB062', '0xB063', '0xB114'],
    "Still only the timing advance of each random-access response (0xB062). 0xB063 does decode now, but it logs a timing-advance command's LCID and length and never its body, so the 6-bit value is not in the record (and the network sent 2 in 22 s of driving). 0xB114 (Serving Cell Frame Timing) is the right record and its internal identity holds, but its scale is about five times 0xB062's timing advance over the same seconds, so nothing is put on screen until a capture with several RACH events calibrates it.",
  ),
  entry(
    'delaySpread',
    'Delay spread',
    'notDecodedYet',
    ['0xB122'],
    "0xB122 (Serving Cell CER) frames exactly and its timing is the tightest of any record here, and its body is a single-peaked energy-versus-delay profile. But the level is not power (r = -0.04 / -0.25 against 0xB193's RSRP: it is a post-AGC channel estimate) and the peak index does not track 0xB114's timing, so the delay axis is unanchored and the tap spacing unknown.",
  ),
];

export const NOT_DECODED_YET: readonly Availability[] = [
  entry(
    'bsr',
    'Buffer status reports',
    'notDecodedYet',
    ['0xB064'],
    'The MAC control elements in 0xB064 are parsed, but the BSR levels are not validated against another source yet, so they are not plotted.',
  ),
  entry(
    'nrUlSchedule',
    'NR UL MCS, PRB and TBS',
    'notDecodedYet',
    ['0xB883'],
    '0xB883 (NR5G MAC UL Physical Channel Schedule Report) v3.26: the record header is validated - frame, slot and the numerology byte, which gives 15 or 30 kHz subcarrier spacing and 10 or 20 slots per frame - but the payload was rejected. Every 10-20-bit transport-block, 5-bit MCS and 6-9-bit PRB field in the record was tried against the TS 38.214 5.1.3.2 size identity and none reaches 60%, while the same test on the shipped 0xB887 decoder passes 828 of 828. Needs a capture with a sustained 5G upload, where the fields exercise their range.',
  ),
  entry(
    'nrUlPower',
    'NR UL power',
    'notDecodedYet',
    ['0xB884'],
    '0xB884 (NR5G MAC UL Power Control) v3.5: framing and timing validated, power rejected. With NR RSRP too sparse to correlate against, the test was the validated LTE required PUSCH power (in EN-DC both uplinks see the same path loss); the best fields reach r = +0.81 and +0.79 but at different bit offsets in the two captures. Needs a capture with a sustained 5G upload.',
  ),
  entry(
    'nrDci',
    'NR DCI',
    'notDecodedYet',
    ['0xB885'],
    '0xB885 (NR5G MAC DCI Info) v3.20: framing and timing validated, contents not decoded. The name is corroborated - 683 of the 913 slots it reports (75%) are slots where 0xB887 logged an NR PDSCH, and none coincides with an 0xB883 uplink slot, which is right for a downlink assignment. Needs a capture with a sustained 5G upload.',
  ),
  entry(
    'nrCsf',
    'NR CQI, RI and PMI',
    'notDecodedYet',
    ['0xB8A7'],
    '0xB8A7 (NR5G MAC CSF Report) v3.5: framing and timing validated, contents rejected. The record is sparse and the NR downlink rank in these captures is almost always 1, so there is nothing with enough variance to validate an RI or CQI field against. Needs a capture with a sustained 5G upload.',
  ),
  entry(
    'nrLl1',
    'NR Rx AGC and Tx',
    'notDecodedYet',
    ['0xB8C9', '0xB8D1'],
    '0xB8C9 (LL1 Rx AGC) v3.1 is framed exactly - a self-describing chunk chain, 7,424 of 7,424 bodies - and its timing is validated to 0.13 ms, and the element count turns out to be the number of receive chains (4 on n77, 2 on n5). The gain itself is rejected: the best correlations come from fields with two to six distinct values that step at a handover, with the sign disagreeing between chains. It needs a purpose-built capture with the secondary cell group up throughout at a usable level. 0xB8D1 (LL1 Tx) v3.7 is plain but not decoded yet.',
  ),
  entry(
    'lteRxAgc',
    'LTE Rx AGC gain',
    'notDecodedYet',
    ['0xB111'],
    '0xB111 v166 is framed exactly (len == 8 + 40N + 16 x popcount(mask), 100.0000%) and its TTI is validated, but the receive gain is rejected: what looked like a gain tracking RSRP was the B12-to-B2 band change, and inside a single serving EARFCN it collapses to |r| <= 0.28 with the sign flipping between chains and captures. The record also carries no PCI, EARFCN or carrier id anywhere, so a sample cannot be attributed to a component carrier. What did validate is the per-chain differential (antenna imbalance), which is a relative measure only and is not shipped as a dBm.',
  ),
  entry(
    'lteDciPhich',
    'LTE DL assignment contents and PHICH',
    'notDecodedYet',
    ['0xB16B', '0xB16C'],
    "0xB16C's uplink grant is decoded (start RB, RB count and modulation, 99.96% against 0xB139), but its 8-byte downlink assignment's contents are rejected: the bytes are nearly constant and no field matches 0xB173's MCS, RB count, TBS or HARQ above chance, in either bit order, so only the per-subframe count is read. 0xB16B (PDCCH-PHICH Indication Report) v49 frames exactly but has no subframe field anywhere, so nothing in it can be aligned with 0xB173's HARQ feedback and no PHICH field is claimed.",
  ),
  entry(
    'lteLl1Loops',
    'LTE LL1 tracking-loop state',
    'notDecodedYet',
    ['0xB11B', '0xB11D'],
    '0xB11B and 0xB11D are proved to be a pair - the same timestamp, the same element count, and the same per-element SFN element-for-element in 31,860 of 31,860 sub-records - and both frame exactly (16 + 40n and 28 + 92n). The 36 and 90 bytes of tracking-loop state per element could not be tied to any decoded quantity, so no field is claimed.',
  ),
  entry(
    'b134',
    'Unnamed record 0xB134',
    'notDecodedYet',
    ['0xB134'],
    '0xB134 has no public name or layout; it is a candidate for LTE SINR.',
  ),
];

/** Shown while this build carries no TS 36.213 table (src/phy/lteTbsTable.ts). */
export const TBS_TABLE_MISSING: Availability = entry(
  'lteTbsTable',
  'TBS checks and UL MCS',
  'notDecodedYet',
  ['0xB173', '0xB139'],
  'This build has no TS 36.213 transport block size table (it is generated from the 3GPP document), so the TBS self-checks and the UL MCS, which is derived from the table, are not run.',
);

/** The records the extractor decodes, as the "not decodable" entries name them. */
const RECORD_NAMES: Readonly<Record<string, string>> = {
  '0xB0C1': 'LTE MIB',
  '0xB0C2': 'LTE serving cell info',
  '0xB193': 'LTE serving and neighbour measurements',
  '0xB173': 'LTE PDSCH statistics',
  '0xB139': 'LTE PUSCH transmissions',
  '0xB14E': 'LTE aperiodic CSI',
  '0xB14D': 'LTE periodic CSI',
  '0xB064': 'LTE MAC UL transport blocks',
  '0xB062': 'LTE RACH',
  '0xB97F': 'NR measurements',
  '0xB887': 'NR PDSCH status',
  '0xB888': 'NR PDSCH statistics',
  '0xB126': 'LTE PDSCH demapper configuration',
  '0xB12A': 'LTE PCFICH results',
  '0xB16C': 'LTE DCI information report',
  '0xB179': 'LTE intra-frequency neighbour measurements',
  '0xB063': 'LTE MAC DL transport blocks',
  '0x184C': 'LTE front-end Tx AGC',
  '0x1D0B': 'Modem clock sampler',
};

/** Entries the per-capture record count is added to (the rest do not depend on what was logged). */
const COUNTED = new Set(NOT_DECODED_YET.filter((e) => e.id !== 'bsr').map((e) => e.id));

/** Entries that also carry the rate, because "how often" is the useful part of "present but not decoded". */
const RATED = new Set(['nrUlSchedule', 'nrUlPower', 'nrDci', 'nrCsf', 'nrLl1', 'lteRxAgc', 'lteDciPhich']);

/** The catalogue with this capture's record counts, the encrypted census, the TBS-table entry if needed, and one
 *  entry per record type that arrived in a version not validated here. */
export function availability(
  recordsPerCode: ReadonlyMap<number, number>,
  secure: EncryptedCensus,
  tbsAvailable: boolean,
  misses: { code: string; versions: string[]; records: number }[],
  durationMs = 0,
): Availability[] {
  const out = [...NOT_POSSIBLE, ...NOT_DECODED_YET].map((e): Availability => {
    const c = { ...e, codes: [...(e.codes ?? [])] };
    if (c.id === 'nrPhyEncrypted' && secure.records > 0) {
      c.reason += ` This capture: ${count(secure.records)} encrypted records across ${secure.codes} codes.`;
    } else if (COUNTED.has(c.id)) {
      const n = c.codes.reduce((sum, code) => sum + (recordsPerCode.get(parseInt(code, 16)) ?? 0), 0);
      const rate = RATED.has(c.id) && durationMs > 0 && n > 0
        ? `, ${(n / (durationMs / 1000)).toFixed(0)} per second`
        : '';
      c.reason += n > 0 ? ` This capture: ${count(n)} records${rate}.` : ' None in this capture.';
    }
    return c;
  });
  if (!tbsAvailable) out.splice(NOT_POSSIBLE.length, 0, TBS_TABLE_MISSING);
  for (const m of misses) {
    const shown = m.versions.map((v) => v.replace(/^v/, '')).join(', ');
    out.push(
      entry(
        `version-${m.code}`,
        `${RECORD_NAMES[m.code] ?? 'Record'} (${m.code})`,
        'notDecodedYet',
        [m.code],
        `Not decodable (version ${shown}): FieldTap decodes only version ${
          VALIDATED_VERSIONS[m.code]
        }, the one validated on this modem, and never guesses at another layout. ${count(m.records)} records skipped.`,
      ),
    );
  }
  return out;
}
