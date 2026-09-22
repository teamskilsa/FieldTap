// Port of ios/Contract/src-v1/LteRrc.kt (contract v1, including D2: packet version 30 = header layout E with
// PDU map D).
//
// 0xB0C0 LTE RRC OTA packets: which cell a message was on, which channel, what the message is, and the handful
// of fields an engineer reads first. Record body: packet version (u8), a header whose layout the version picks,
// then the RRC PDU (UPER). The layout's trailing length, which must equal the bytes after it, confirms or
// rejects the pick. Names come from the outer CHOICE; past that only fields at fixed bit positions are read,
// each pinned to Wireshark's decode of the same bytes. Anything deeper belongs to Wireshark.

import { OutOfBounds, u16le, u32le, u8 } from './bytes.ts';
import type { FlowField } from './flow.ts';
import { fixed, hex } from './javafmt.ts';
import { PerBits } from './per.ts';

export type LteChannel = 'BCCH-BCH' | 'BCCH-DL-SCH' | 'MCCH' | 'PCCH' | 'DL-CCCH' | 'DL-DCCH' | 'UL-CCCH' | 'UL-DCCH';

export const isUplinkLte = (c: LteChannel) => c === 'UL-CCCH' || c === 'UL-DCCH';

/** One RRC message as the modem logged it. */
export interface LteRrcMessage {
  packetVersion: number;
  pci: number;
  earfcn: number;
  sfn: number;
  subframe: number;
  /** Null when the PDU number is one this decoder does not map. */
  channel: LteChannel | null;
  pduNumber: number;
  /** The ASN.1 identifier, e.g. 'rrcConnectionRequest'; null when it could not be read. */
  asn1Name: string | null;
  payload: Uint8Array;
  /** Fields read from fixed positions, in display order. */
  fields: FlowField[];
}

/** The label of the field a handover command carries. */
export const HANDOVER = 'Handover';

export const field = (label: string, value: string, children: FlowField[] = []): FlowField => ({ label, value, children });

// MARK: - Header

interface Raw {
  pci: number;
  earfcn: number;
  sfnSubfn: number;
  pduNum: number;
  length: number;
}

interface Layout {
  name: string;
  size: number;
  read: (b: Uint8Array, o: number) => Raw;
}

const raw = (pci: number, earfcn: number, sfnSubfn: number, pduNum: number, length: number): Raw => ({ pci, earfcn, sfnSubfn, pduNum, length });

// Offsets are after the version byte. All little-endian, no padding.
const A: Layout = { name: 'A', size: 12, read: (b, o) => raw(u16le(b, o + 3), u16le(b, o + 5), u16le(b, o + 7), u8(b, o + 9), u16le(b, o + 10)) };
const B: Layout = { name: 'B', size: 14, read: (b, o) => raw(u16le(b, o + 3), u32le(b, o + 5), u16le(b, o + 9), u8(b, o + 11), u16le(b, o + 12)) };
const C: Layout = { name: 'C', size: 18, read: (b, o) => raw(u16le(b, o + 3), u32le(b, o + 5), u16le(b, o + 9), u8(b, o + 11), u16le(b, o + 16)) };
/** HDR_D: C with three more bytes before the PCI (a release byte and an unexplained u16). SM8450, version 27. */
const D: Layout = { name: 'D', size: 20, read: (b, o) => raw(u16le(b, o + 5), u32le(b, o + 7), u16le(b, o + 11), u8(b, o + 13), u16le(b, o + 18)) };
/** v30 (iPhone 17 / M25 modem): D plus three trailing bytes (D2). */
const E: Layout = { name: 'E', size: 23, read: (b, o) => raw(u16le(b, o + 5), u32le(b, o + 7), u16le(b, o + 11), u8(b, o + 13), u16le(b, o + 18)) };

const LAYOUTS = [A, B, C, D, E];

type PduMap = ReadonlyMap<number, LteChannel>;
const map = (entries: [number, LteChannel][]): PduMap => new Map(entries);

const MAP_A = map([[1, 'BCCH-BCH'], [2, 'BCCH-DL-SCH'], [3, 'MCCH'], [4, 'PCCH'], [5, 'DL-CCCH'], [6, 'DL-DCCH'], [7, 'UL-CCCH'], [8, 'UL-DCCH']]);
const MAP_B = map([[8, 'BCCH-BCH'], [9, 'BCCH-DL-SCH'], [10, 'MCCH'], [11, 'PCCH'], [12, 'DL-CCCH'], [13, 'DL-DCCH'], [14, 'UL-CCCH'], [15, 'UL-DCCH']]);
const MAP_C = map([[1, 'BCCH-BCH'], [2, 'BCCH-DL-SCH'], [4, 'MCCH'], [5, 'PCCH'], [6, 'DL-CCCH'], [7, 'DL-DCCH'], [8, 'UL-CCCH'], [9, 'UL-DCCH']]);
const MAP_D = map([[1, 'BCCH-BCH'], [3, 'BCCH-DL-SCH'], [6, 'MCCH'], [7, 'PCCH'], [8, 'DL-CCCH'], [9, 'DL-DCCH'], [10, 'UL-CCCH'], [11, 'UL-DCCH']]);

function preferred(version: number): [Layout | null, PduMap] {
  switch (version) {
    case 2: case 3: case 4: case 6: case 7: case 8: case 13: case 22:
      return [A, MAP_A];
    case 9: case 12:
      return [B, MAP_B];
    case 14: case 15: case 16:
      return [C, MAP_C];
    case 19: case 26:
      return [C, MAP_D];
    case 27:
      return [D, MAP_D];
    case 30:
      return [E, MAP_D];
    default:
      return [null, version >= 19 ? MAP_D : version >= 14 ? MAP_C : version >= 9 ? MAP_B : MAP_A];
  }
}

export function decodeLteRrc(body: Uint8Array): LteRrcMessage | null {
  if (body.length < 1 + A.size) return null;
  const version = body[0];
  const [layout, pduMap] = preferred(version);
  const order = [...(layout ? [layout] : []), ...LAYOUTS.filter((l) => l !== layout)];
  let chosen: [Layout, Raw] | null = null;
  for (const candidate of order) {
    if (body.length < 1 + candidate.size) continue;
    const r = candidate.read(body, 1);
    // The length that fits is the layout that is right; the first that parses is the fallback.
    if (r.length === body.length - 1 - candidate.size) {
      chosen = [candidate, r];
      break;
    }
    if (chosen === null) chosen = [candidate, r];
  }
  if (chosen === null) return null;
  const [fit, r] = chosen;
  const start = 1 + fit.size;
  const payload = r.length >= 1 && r.length <= body.length - start ? body.slice(start, start + r.length) : body.slice(start);
  const channel = pduMap.get(r.pduNum) ?? null;
  const name = channel !== null ? outerName(channel, payload) : null;
  return {
    packetVersion: version,
    pci: r.pci,
    earfcn: r.earfcn,
    sfn: r.sfnSubfn >> 4,
    subframe: r.sfnSubfn & 0xf,
    channel,
    pduNumber: r.pduNum,
    asn1Name: name,
    payload,
    fields: channel !== null && name !== null ? details(name, payload) : [],
  };
}

// MARK: - Names

const DL_DCCH = [
  'csfbParametersResponseCDMA2000', 'dlInformationTransfer', 'handoverFromEUTRAPreparationRequest',
  'mobilityFromEUTRACommand', 'rrcConnectionReconfiguration', 'rrcConnectionRelease', 'securityModeCommand',
  'ueCapabilityEnquiry', 'counterCheck', 'ueInformationRequest', 'loggedMeasurementConfiguration',
  'rnReconfiguration', 'rrcConnectionResume', 'spare3', 'spare2', 'spare1',
];
const UL_DCCH = [
  'csfbParametersRequestCDMA2000', 'measurementReport', 'rrcConnectionReconfigurationComplete',
  'rrcConnectionReestablishmentComplete', 'rrcConnectionSetupComplete', 'securityModeComplete',
  'securityModeFailure', 'ueCapabilityInformation', 'ulHandoverPreparationTransfer', 'ulInformationTransfer',
  'counterCheckResponse', 'ueInformationResponse', 'proximityIndication', 'rnReconfigurationComplete',
  'mbmsCountingResponse', 'interFreqRSTDMeasurementIndication',
];
const DL_CCCH = ['rrcConnectionReestablishment', 'rrcConnectionReestablishmentReject', 'rrcConnectionReject', 'rrcConnectionSetup'];
const UL_CCCH = ['rrcConnectionReestablishmentRequest', 'rrcConnectionRequest'];
const BCCH_DL_SCH = ['systemInformation', 'systemInformationBlockType1'];

/** list[index] with Kotlin's List.get bounds. */
export function at<T>(list: readonly T[], index: number): T {
  if (index < 0 || index >= list.length) throw new OutOfBounds(`index ${index} of ${list.length}`);
  return list[index];
}

function outerName(channel: LteChannel, payload: Uint8Array): string | null {
  if (channel === 'BCCH-BCH') return 'masterInformationBlock';
  if (payload.length === 0) return null;
  const bits = new PerBits(payload);
  try {
    if (bits.read(1) !== 0) return 'messageClassExtension';
    switch (channel) {
      case 'DL-DCCH': return at(DL_DCCH, bits.read(4));
      case 'UL-DCCH': return at(UL_DCCH, bits.read(4));
      case 'DL-CCCH': return at(DL_CCCH, bits.read(2));
      case 'UL-CCCH': return at(UL_CCCH, bits.read(1));
      case 'BCCH-DL-SCH': return at(BCCH_DL_SCH, bits.read(1));
      case 'PCCH': return 'paging';
      case 'MCCH': return 'mbsfnAreaConfiguration';
    }
  } catch (e) {
    if (e instanceof OutOfBounds) return null;
    throw e;
  }
}

const READABLE: Record<string, string> = {
  systemInformationBlockType1: 'SIB1',
  systemInformation: 'System Information',
  masterInformationBlock: 'MIB',
  ulInformationTransfer: 'UL Information Transfer',
  dlInformationTransfer: 'DL Information Transfer',
  ueCapabilityEnquiry: 'UE Capability Enquiry',
  ueCapabilityInformation: 'UE Capability Information',
  csfbParametersResponseCDMA2000: 'CSFB Parameters Response CDMA2000',
  csfbParametersRequestCDMA2000: 'CSFB Parameters Request CDMA2000',
  handoverFromEUTRAPreparationRequest: 'Handover From EUTRA Preparation Request',
  mobilityFromEUTRACommand: 'Mobility From EUTRA Command',
  interFreqRSTDMeasurementIndication: 'Inter-Freq RSTD Measurement Indication',
};

const UPPER_WORDS: Record<string, string> = { rrc: 'RRC', ue: 'UE', ul: 'UL', dl: 'DL' };

/** 'rrcConnectionReconfigurationComplete' -> 'RRC Connection Reconfiguration Complete'. */
export function readableLte(asn1Name: string): string {
  const known = READABLE[asn1Name];
  if (known !== undefined) return known;
  return asn1Name
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(' ')
    .map((word) => UPPER_WORDS[word.toLowerCase()] ?? (word.charAt(0).toUpperCase() + word.slice(1)))
    .join(' ');
}

// MARK: - Fields at fixed positions (Details). Each decode is pinned to Wireshark's reading of a real or
// constructed PDU. A PDU shorter than its own structure is truncated or not what its CHOICE claims: say nothing.

const ESTABLISHMENT_CAUSE = ['emergency', 'highPriorityAccess', 'mt-Access', 'mo-Signalling', 'mo-Data', 'delayTolerantAccess', 'mo-VoiceCall', 'spare1'];
const RELEASE_CAUSE = ['loadBalancingTAUrequired', 'other', 'cs-FallbackHighPriority', 'rrc-Suspend'];
const REESTABLISHMENT_CAUSE = ['reconfigurationFailure', 'handoverFailure', 'otherFailure', 'spare1'];
const REDIRECT_RATS = ['EUTRA', 'GERAN', 'UTRA-FDD', 'UTRA-TDD', 'CDMA2000 HRPD', 'CDMA2000 1xRTT'];

function details(name: string, payload: Uint8Array): FlowField[] {
  try {
    switch (name) {
      case 'rrcConnectionRequest': return connectionRequest(payload);
      case 'rrcConnectionRelease': return connectionRelease(payload);
      case 'rrcConnectionReject': return connectionReject(payload);
      case 'rrcConnectionReestablishmentRequest': return reestablishmentRequest(payload);
      case 'measurementReport': return measurementReport(payload);
      case 'rrcConnectionReconfiguration': return connectionReconfiguration(payload);
      default: return [];
    }
  } catch (e) {
    if (e instanceof OutOfBounds) return [];
    throw e;
  }
}

/** UL-CCCH: c1, rrcConnectionRequest, r8, ue-Identity CHOICE, establishmentCause. */
function connectionRequest(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 2);
  if (b.read(1) !== 0) return []; // criticalExtensionsFuture
  const fields: FlowField[] = [];
  if (b.read(1) === 0) {
    const mmec = b.read(8);
    const mTmsi = b.readLong(32);
    fields.push(field('UE identity', 'S-TMSI', [field('MMEC', `${mmec}`), field('M-TMSI', '0x' + hex(mTmsi, 8))]));
  } else {
    b.readLong(40);
    fields.push(field('UE identity', 'random value'));
  }
  fields.push(field('Establishment cause', at(ESTABLISHMENT_CAUSE, b.read(3))));
  return fields;
}

/** DL-DCCH: rrc-TransactionIdentifier, c1, r8, optional bitmap (3), releaseCause, then a redirect if present. */
function connectionRelease(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 5);
  b.read(2); // transaction id
  if (b.read(1) !== 0) return [];
  if (b.read(2) !== 0) return []; // not r8
  const redirect = b.read(1) === 1;
  b.read(1); // idleModeMobilityControlInfo
  b.read(1); // nonCriticalExtension
  const fields = [field('Release cause', at(RELEASE_CAUSE, b.read(2)))];
  if (redirect) {
    // RedirectedCarrierInfo: extensible CHOICE of six; eutra carries a 16-bit EARFCN.
    const extended = b.read(1) === 1;
    const index = extended ? -1 : b.read(3);
    fields.push(index === 0 ? field('Redirected to', `EUTRA EARFCN ${b.read(16)}`) : field('Redirected to', REDIRECT_RATS[index] ?? 'another RAT'));
  }
  return fields;
}

/**
 * DL-DCCH: transaction id, c1, r8, then the r8 presence bitmap: measConfig, mobilityControlInfo,
 * dedicatedInfoNASList, radioResourceConfigDedicated, securityConfigHO, nonCriticalExtension.
 *
 * The one with mobilityControlInfo is a handover command. Its target sits at a fixed place only when no
 * measConfig comes before it; otherwise the target is the cell the next message is logged on.
 */
function connectionReconfiguration(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 5);
  b.read(2); // transaction id
  if (b.read(1) !== 0) return [];
  if (b.read(3) !== 0) return []; // not r8
  const meas = b.read(1) === 1;
  const mobility = b.read(1) === 1;
  const nas = b.read(1) === 1;
  const radio = b.read(1) === 1;
  const securityHo = b.read(1) === 1;
  b.read(1); // nonCriticalExtension
  const fields: FlowField[] = [];
  if (mobility) fields.push(field(HANDOVER, meas ? 'command' : mobilityTarget(b)));
  const carries = [
    meas ? 'measurement config' : null,
    nas ? 'NAS' : null,
    radio ? 'radio resources' : null,
    securityHo ? 'handover security' : null,
  ].filter((c) => c !== null);
  if (carries.length) fields.push(field('Carries', carries.join(', ')));
  return fields;
}

/** MobilityControlInfo: extension bit, four optionals, targetPhysCellId (9), then carrierFreq if present. */
function mobilityTarget(b: PerBits): string {
  b.read(1);
  const carrier = b.read(1) === 1;
  b.read(3); // carrierBandwidth, additionalSpectrumEmission, rach-ConfigDedicated
  const pci = b.read(9);
  if (!carrier) return `to PCI ${pci}, same EARFCN`;
  b.read(1); // ul-CarrierFreq
  return `to PCI ${pci}, EARFCN ${b.read(16)}`;
}

/** DL-CCCH: c1, rrcConnectionReject, r8, optional bitmap (1), waitTime 1..16 s. */
function connectionReject(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 3);
  if (b.read(1) !== 0) return [];
  if (b.read(2) !== 0) return [];
  b.read(1); // nonCriticalExtension
  return [field('Wait time', `${b.read(4) + 1} s`)];
}

/** UL-CCCH: c1, reestablishment request, r8, C-RNTI (16), PCI (9), shortMAC-I (16), cause. */
function reestablishmentRequest(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 2);
  if (b.read(1) !== 0) return [];
  const cRnti = b.read(16);
  const pci = b.read(9);
  b.read(16);
  return [
    field('Cause', at(REESTABLISHMENT_CAUSE, b.read(2))),
    field('Previous cell PCI', `${pci}`),
    field('C-RNTI', '0x' + hex(cRnti, 4)),
  ];
}

/**
 * UL-DCCH: c1, measurementReport, r8 (1 + 3 bits), the r8 bitmap (1), then MeasResults: extension bit,
 * neighbour-present bit, measId (1..32), PCell RSRP and RSRQ, and an EUTRA neighbour list when present.
 * RSRP is reported as 0..97 for -140..-44 dBm; RSRQ as 0..34 for -19.5..-3 dB.
 */
function measurementReport(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 5);
  if (b.read(1) !== 0) return [];
  if (b.read(3) !== 0) return [];
  b.read(1); // nonCriticalExtension
  b.read(1); // MeasResults extension
  const neighbours = b.read(1) === 1;
  const measId = b.read(5) + 1;
  const fields = [
    field('Measurement ID', `${measId}`),
    field('Serving RSRP', rsrp(b.read(7))),
    field('Serving RSRQ', rsrq(b.read(6))),
  ];
  if (neighbours && b.read(1) === 0 && b.read(2) === 0) {
    const count = b.read(3) + 1;
    const cells: FlowField[] = [];
    for (let k = 0; k < count; k++) {
      const cgi = b.read(1) === 1;
      const pci = b.read(9);
      if (cgi) return [...fields, field('Neighbours', `${count} reported, with cell identity (not decoded)`)];
      const ext = b.read(1) === 1;
      const hasRsrp = b.read(1) === 1;
      const hasRsrq = b.read(1) === 1;
      const r = hasRsrp ? rsrp(b.read(7)) : '—';
      const q = hasRsrq ? rsrq(b.read(6)) : '—';
      if (ext) b.skipExtensionAdditions();
      cells.push(field(`PCI ${pci}`, `${r} · ${q}`));
    }
    fields.push(field('Neighbours', `${count}`, cells));
  }
  return fields;
}

const minus = (s: string) => s.replaceAll('-', '−');

/**
 * A reported RSRP index is a 1 dB bin, not a value: n means n-141 <= RSRP < n-140 (TS 36.133). Quoting n-140
 * alone reads one dB high on every report, so the bin is shown, as Wireshark shows it.
 */
export function rsrp(v: number): string {
  if (v === 0) return '< −140 dBm';
  if (v === 97) return '≥ −44 dBm';
  return minus(`${v - 141} to ${v - 140} dBm`);
}

/** RSRQ index n: -20 + n/2 <= RSRQ < -19.5 + n/2 dB. */
export function rsrq(v: number): string {
  if (v === 0) return '< −19.5 dB';
  if (v === 34) return '≥ −3 dB';
  return minus(`${fixed(-20 + v * 0.5, 1)} to ${fixed(-19.5 + v * 0.5, 1)} dB`);
}
