// What cannot be plotted from this iPhone, and why: the "not possible" and "not decoded yet" lists of the design's
// PHY dashboard (FTPhy's PhyCatalog.swift), plus a "not decodable (version N)" entry for every record that came in a
// version the decoders were not validated for. An empty chart is never a mystery.

import type { Availability, EncryptedCensus } from '../types.ts';
import { count } from './checks.ts';
import { VALIDATED_VERSIONS } from './metrics.ts';

const entry = (id: string, title: string, status: Availability['status'], codes: string[], reason: string): Availability => ({
  id,
  title,
  status,
  reason,
  codes,
});

export const NOT_POSSIBLE: readonly Availability[] = [
  entry('nrSinr', 'NR SINR / SNR', 'encryptedByModem', ['0xB8DD'],
    '0xB8DD (NR5G LL1 FW Serving FTL) is a secure record: the modem encrypts its body and only the header is readable. NR SINR appears only when an RRC measurement report carries it.'),
  entry('nrFirmwareCsi', 'NR CSI from the firmware', 'encryptedByModem', ['0xB8E2'],
    '0xB8E2 (NR5G LL1 FW CSF Reports) is encrypted by the modem.'),
  entry('nrPhyEncrypted', 'NR ML1 / LL1 records', 'encryptedByModem',
    ['0xB8C5', '0xB8CB', '0xB9A9', '0xB8C8', '0xB8CD', '0xB8C0', '0xB8CF', '0xB8A3', '0xB881', '0xB8C4'],
    'Most NR physical-layer records (for example 0xB881 NR MAC UL TB stats) arrive encrypted. FieldTap counts them and never guesses at their contents.'),
  entry('lteSinr', 'LTE SINR / SNR', 'notFoundInPlainLogs', ['0xB193', '0xB134', '0xB11B', '0xB15B', '0xB122', '0xB123'],
    "Not in any plain record decoded so far. The old 'projected SIR' slot of 0xB193 is not SIR on v66 (it reads 0 in about half the records and up to 220 dB). The candidates 0xB134, 0xB11B, 0xB15B and 0xB122/0xB123 are unverified."),
  entry('nrPerAntennaRsrp', 'NR RSRP per antenna', 'notOnIPhone', ['0xB97F'],
    'The per-Rx fields of 0xB97F are zero on this modem, and beam-level RSRP is not validated, so NR RSRP is shown per cell only.'),
  entry('liveValues', 'Live values, and a long history', 'notOnIPhone', [],
    "iOS gives apps no modem data. The trace arrives only in a sysdiagnose you trigger, and the archive keeps only the modem's newest ~128 MiB of trace (27 s in a busy EN-DC capture), which may start after you pressed the buttons."),
  entry('actualTxPower', 'Actual LTE Tx power', 'notFoundInPlainLogs', ['0xB139'],
    'The log carries the required PUSCH power before Pcmax capping. The Tx power is then min(Pcmax, about 23 dBm, required).'),
  entry('continuousTa', 'Continuous timing advance', 'notDecodedYet', ['0xB062', '0xB063'],
    'Only the timing advance of each random-access response (0xB062). The TA MAC commands sit in 0xB063, which does not decode yet.'),
];

export const NOT_DECODED_YET: readonly Availability[] = [
  entry('bsr', 'Buffer status reports', 'notDecodedYet', ['0xB064'],
    'The MAC control elements in 0xB064 are parsed, but the BSR levels are not validated against another source yet, so they are not plotted.'),
  entry('nrUlSchedule', 'NR UL MCS, PRB and TBS', 'notDecodedYet', ['0xB883'],
    '0xB883 (NR5G MAC UL Physical Channel Schedule Report) v3.26 is plain but not decoded yet.'),
  entry('nrUlPower', 'NR UL power', 'notDecodedYet', ['0xB884'], '0xB884 (NR5G MAC UL Power Control) v3.5 is plain but not decoded yet.'),
  entry('nrDci', 'NR DCI', 'notDecodedYet', ['0xB885'], '0xB885 (NR5G MAC DCI Info) v3.20 is plain but not decoded yet.'),
  entry('nrCsf', 'NR CQI, RI and PMI', 'notDecodedYet', ['0xB8A7'], '0xB8A7 (NR5G MAC CSF Report) v3.5 is plain but not decoded yet.'),
  entry('nrLl1', 'NR Rx AGC and Tx', 'notDecodedYet', ['0xB8C9', '0xB8D1'],
    '0xB8C9 (LL1 Rx AGC) v3.1 and 0xB8D1 (LL1 Tx) v3.7 are plain but not decoded yet.'),
  entry('lteDlMac', 'LTE DL MAC TBs and TA commands', 'notDecodedYet', ['0xB063'], '0xB063 v50: the known framing did not validate on this modem.'),
  entry('pdschDemapper', 'PDSCH demapper (antennas, TM per TTI)', 'notDecodedYet', ['0xB126'], '0xB126 v163 is plain but not decoded yet.'),
  entry('lteRxAgc', 'LTE Rx AGC', 'notDecodedYet', ['0xB111'], '0xB111 v166 has no public layout.'),
  entry('lteDciPhich', 'LTE DCI and PHICH', 'notDecodedYet', ['0xB16B', '0xB16C'], '0xB16B and 0xB16C are plain but not decoded yet.'),
  entry('intraFreqNeighbours', 'Intra-frequency neighbour search', 'notDecodedYet', ['0xB179'], '0xB179 is plain but not decoded yet.'),
  entry('b134', 'Unnamed record 0xB134', 'notDecodedYet', ['0xB134'], '0xB134 has no public name or layout; it is a candidate for LTE SINR.'),
];

/** Shown while this build carries no TS 36.213 table (src/phy/lteTbsTable.ts). */
export const TBS_TABLE_MISSING: Availability = entry('lteTbsTable', 'TBS checks and UL MCS', 'notDecodedYet', ['0xB173', '0xB139'],
  'This build has no TS 36.213 transport block size table (it is generated from the 3GPP document), so the TBS self-checks and the UL MCS, which is derived from the table, are not run.');

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
};

/** Entries the per-capture record count is added to (the rest do not depend on what was logged). */
const COUNTED = new Set(NOT_DECODED_YET.filter((e) => e.id !== 'bsr').map((e) => e.id));

/** The catalogue with this capture's record counts, the encrypted census, the TBS-table entry if needed, and one
 *  entry per record type that arrived in a version not validated here. */
export function availability(
  recordsPerCode: ReadonlyMap<number, number>,
  secure: EncryptedCensus,
  tbsAvailable: boolean,
  misses: { code: string; versions: string[]; records: number }[],
): Availability[] {
  const out = [...NOT_POSSIBLE, ...NOT_DECODED_YET].map((e): Availability => {
    const c = { ...e, codes: [...(e.codes ?? [])] };
    if (c.id === 'nrPhyEncrypted' && secure.records > 0) {
      c.reason += ` This capture: ${count(secure.records)} encrypted records across ${secure.codes} codes.`;
    } else if (COUNTED.has(c.id)) {
      const n = c.codes.reduce((sum, code) => sum + (recordsPerCode.get(parseInt(code, 16)) ?? 0), 0);
      c.reason += n > 0 ? ` This capture: ${count(n)} records.` : ' None in this capture.';
    }
    return c;
  });
  if (!tbsAvailable) out.splice(NOT_POSSIBLE.length, 0, TBS_TABLE_MISSING);
  for (const m of misses) {
    const shown = m.versions.map((v) => v.replace(/^v/, '')).join(', ');
    out.push(entry(`version-${m.code}`, `${RECORD_NAMES[m.code] ?? 'Record'} (${m.code})`, 'notDecodedYet', [m.code],
      `Not decodable (version ${shown}): FieldTap decodes only version ${VALIDATED_VERSIONS[m.code]}, the one validated on this modem, and never guesses at another layout. ${count(m.records)} records skipped.`));
  }
  return out;
}
