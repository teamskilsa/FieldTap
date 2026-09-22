// Port of ios/Contract/src-v1/NrRrc.kt (contract v1, including D2: packet version 26 = header layout E, with
// PDU 11 = RRCReconfiguration and 12 = RRCReconfigurationComplete).
//
// 0xB821 NR RRC OTA packets: the cell, the channel, the message, and the 5G NAS carried inside it. Same shape as
// LTE (version, a header the version picks, the PDU), chosen the same way: by the trailing length agreeing with
// the record, so a wrong table entry costs nothing and a new modem generation is picked up by probing. The NAS
// is pulled out of the three messages that carry one (RRCSetupComplete, UL/DLInformationTransfer).

import { OutOfBounds, u16le, u32le, u8 } from './bytes.ts';
import type { FlowField } from './flow.ts';
import { hex } from './javafmt.ts';
import { at, field, readableLte } from './lterrc.ts';
import { PerBits } from './per.ts';

export type NrChannel =
  | 'BCCH-BCH'
  | 'BCCH-DL-SCH'
  | 'DL-CCCH'
  | 'DL-DCCH'
  | 'PCCH'
  | 'UL-CCCH'
  | 'UL-CCCH1'
  | 'UL-DCCH'
  /** EN-DC: an NR message the modem logs on its own, having carried it inside an LTE RRC message. */
  | 'RRCReconfiguration'
  | 'RRCReconfigurationComplete';

export const isUplinkNr = (c: NrChannel) =>
  c === 'UL-CCCH' || c === 'UL-CCCH1' || c === 'UL-DCCH' || c === 'RRCReconfigurationComplete';

/** One NR RRC message as the modem logged it. */
export interface NrRrcMessage {
  packetVersion: number;
  pci: number;
  arfcn: number;
  /** SRB the message went on; null when the header does not name one (broadcast and paging). */
  bearerId: number | null;
  channel: NrChannel | null;
  pduNumber: number;
  asn1Name: string | null;
  payload: Uint8Array;
  fields: FlowField[];
  /** The NAS message this RRC message carried, when it carried one. */
  nas: Uint8Array | null;
}

// MARK: - Header

interface Raw {
  bearerId: number;
  pci: number;
  arfcn: number;
  pduNum: number;
  length: number;
}

interface Layout {
  name: string;
  size: number;
  read: (b: Uint8Array, o: number) => Raw;
}

const raw = (bearerId: number, pci: number, arfcn: number, pduNum: number, length: number): Raw => ({ bearerId, pci, arfcn, pduNum, length });

// Offsets are after the 4-byte packet version. All little-endian.
/** rel, ver, rb, pci, arfcn, sfn/subframe (u16), pdu, sib mask, length. */
const A: Layout = { name: 'A', size: 18, read: (b, o) => raw(u8(b, o + 2), u16le(b, o + 3), u32le(b, o + 5), u8(b, o + 11), u16le(b, o + 16)) };
/** A with a 32-bit frame field. */
const B: Layout = { name: 'B', size: 20, read: (b, o) => raw(u8(b, o + 2), u16le(b, o + 3), u32le(b, o + 9 + 4), u8(b, o + 13), u16le(b, o + 18)) };
/** SM8450, packet version 17: five bytes of cell identity before the ARFCN, and a wider tail. */
const C: Layout = { name: 'C', size: 27, read: (b, o) => raw(u8(b, o + 2), u16le(b, o + 3), u32le(b, o + 13), u8(b, o + 20), u16le(b, o + 25)) };
/** v26 (iPhone 17 / M25 modem): C plus four trailing reserved bytes (35-byte header incl. version). */
const E: Layout = { name: 'E', size: 31, read: (b, o) => raw(u8(b, o + 2), u16le(b, o + 3), u32le(b, o + 13), u8(b, o + 20), u16le(b, o + 25)) };

const LAYOUTS = [E, C, B, A];

const VERSIONS = new Map<number, Layout>([
  [7, A], [9, A], [12, A], [14, A],
  [15, B], [19, B], [23, B], [25, B], [26, E],
  [17, C], [27, C],
]);

const PDU_MAP = new Map<number, NrChannel>([
  [1, 'BCCH-BCH'], [2, 'BCCH-DL-SCH'], [3, 'DL-CCCH'], [4, 'DL-DCCH'],
  [5, 'PCCH'], [6, 'UL-CCCH'], [7, 'UL-CCCH1'], [8, 'UL-DCCH'],
  [9, 'RRCReconfiguration'], [10, 'RRCReconfigurationComplete'],
  [11, 'RRCReconfiguration'], [12, 'RRCReconfigurationComplete'],
]);

const VERSION_SIZE = 4;

export function decodeNrRrc(body: Uint8Array): NrRrcMessage | null {
  if (body.length < VERSION_SIZE + A.size) return null;
  // Kotlin's u32(...).toInt(): the same bits as a signed int.
  const version = u32le(body, 0) | 0;
  const pref = VERSIONS.get(version) ?? null;
  const order = [...(pref ? [pref] : []), ...LAYOUTS.filter((l) => l !== pref)];
  let chosen: [Layout, Raw] | null = null;
  for (const candidate of order) {
    if (body.length < VERSION_SIZE + candidate.size) continue;
    const r = candidate.read(body, VERSION_SIZE);
    // The length that fits is the layout that is right; the first that parses is the fallback.
    if (r.length === body.length - VERSION_SIZE - candidate.size) {
      chosen = [candidate, r];
      break;
    }
    if (chosen === null) chosen = [candidate, r];
  }
  if (chosen === null) return null;
  const [fit, r] = chosen;
  const start = VERSION_SIZE + fit.size;
  const payload = r.length >= 1 && r.length <= body.length - start ? body.slice(start, start + r.length) : body.slice(start);
  const channel = PDU_MAP.get(r.pduNum) ?? null;
  const name = channel !== null ? outerName(channel, payload) : null;
  return {
    packetVersion: version,
    pci: r.pci,
    arfcn: r.arfcn,
    bearerId: r.bearerId !== 0xff ? r.bearerId : null,
    channel,
    pduNumber: r.pduNum,
    asn1Name: name,
    payload,
    fields: channel !== null && name !== null ? details(name, payload) : [],
    nas: name !== null ? carriedNas(name, payload) : null,
  };
}

// MARK: - Names

const DL_DCCH = [
  'rrcReconfiguration', 'rrcResume', 'rrcRelease', 'rrcReestablishment', 'securityModeCommand',
  'dlInformationTransfer', 'ueCapabilityEnquiry', 'counterCheck', 'mobilityFromNRCommand',
  'dlDedicatedMessageSegment', 'ueInformationRequest', 'dlInformationTransferMRDC',
  'loggedMeasurementConfiguration', 'spare3', 'spare2', 'spare1',
];
const UL_DCCH = [
  'measurementReport', 'rrcReconfigurationComplete', 'rrcSetupComplete', 'rrcReestablishmentComplete',
  'rrcResumeComplete', 'securityModeComplete', 'securityModeFailure', 'ulInformationTransfer',
  'locationMeasurementIndication', 'ueCapabilityInformation', 'counterCheckResponse',
  'ueAssistanceInformation', 'failureInformation', 'ulInformationTransferMRDC',
  'scgFailureInformation', 'scgFailureInformationEUTRA',
];
const DL_CCCH = ['rrcReject', 'rrcSetup', 'spare2', 'spare1'];
const UL_CCCH = ['rrcSetupRequest', 'rrcResumeRequest', 'rrcReestablishmentRequest', 'rrcSystemInfoRequest'];
const UL_CCCH1 = ['rrcResumeRequest1', 'spare3', 'spare2', 'spare1'];
const BCCH_DL_SCH = ['systemInformation', 'systemInformationBlockType1'];

function outerName(channel: NrChannel, payload: Uint8Array): string | null {
  if (payload.length === 0) return null;
  if (channel === 'RRCReconfiguration') return 'rrcReconfiguration';
  if (channel === 'RRCReconfigurationComplete') return 'rrcReconfigurationComplete';
  const bits = new PerBits(payload);
  try {
    // BCCH-BCH is a SEQUENCE holding a CHOICE of two, with no c1 level above it.
    if (channel === 'BCCH-BCH') return bits.read(1) === 0 ? 'mib' : 'messageClassExtension';
    if (bits.read(1) !== 0) return 'messageClassExtension';
    switch (channel) {
      case 'DL-DCCH': return at(DL_DCCH, bits.read(4));
      case 'UL-DCCH': return at(UL_DCCH, bits.read(4));
      case 'DL-CCCH': return at(DL_CCCH, bits.read(2));
      case 'UL-CCCH': return at(UL_CCCH, bits.read(2));
      case 'UL-CCCH1': return at(UL_CCCH1, bits.read(2));
      case 'BCCH-DL-SCH': return at(BCCH_DL_SCH, bits.read(1));
      case 'PCCH': return 'paging';
    }
  } catch (e) {
    if (e instanceof OutOfBounds) return null;
    throw e;
  }
}

const READABLE: Record<string, string> = {
  mib: 'MIB',
  systemInformationBlockType1: 'SIB1',
  systemInformation: 'System Information',
  paging: 'Paging',
  ulInformationTransfer: 'UL Information Transfer',
  dlInformationTransfer: 'DL Information Transfer',
  ueCapabilityEnquiry: 'UE Capability Enquiry',
  ueCapabilityInformation: 'UE Capability Information',
  mobilityFromNRCommand: 'Mobility From NR Command',
  ulInformationTransferMRDC: 'UL Information Transfer MRDC',
  dlInformationTransferMRDC: 'DL Information Transfer MRDC',
  scgFailureInformationEUTRA: 'SCG Failure Information EUTRA',
};

/** 'rrcSetupComplete' -> 'RRC Setup Complete'. */
export const readableNr = (asn1Name: string): string => READABLE[asn1Name] ?? readableLte(asn1Name);

// MARK: - Fields at fixed positions (Details). Every field is checked against Wireshark's reading of the bytes.

/** TS 38.331 EstablishmentCause. */
const ESTABLISHMENT_CAUSE = [
  'emergency', 'highPriorityAccess', 'mt-Access', 'mo-Signalling', 'mo-Data', 'mo-VoiceCall',
  'mo-VideoCall', 'mo-SMS', 'mps-PriorityAccess', 'mcs-PriorityAccess',
  'spare6', 'spare5', 'spare4', 'spare3', 'spare2', 'spare1',
];
const REESTABLISHMENT_CAUSE = ['reconfigurationFailure', 'handoverFailure', 'otherFailure', 'spare1'];

function details(name: string, payload: Uint8Array): FlowField[] {
  try {
    switch (name) {
      case 'rrcSetupRequest': return setupRequest(payload);
      case 'rrcReestablishmentRequest': return reestablishmentRequest(payload);
      case 'rrcReject': return reject(payload);
      case 'rrcRelease': return release(payload);
      case 'paging': return paging(payload);
      case 'rrcSetupComplete': return setupComplete(payload)[0];
      default: return [];
    }
  } catch (e) {
    if (e instanceof OutOfBounds) return [];
    throw e;
  }
}

/** The `dedicatedNAS-Message` of the messages that carry one, or null. */
function carriedNas(name: string, payload: Uint8Array): Uint8Array | null {
  try {
    switch (name) {
      case 'rrcSetupComplete': return setupComplete(payload)[1];
      case 'ulInformationTransfer':
      case 'dlInformationTransfer':
        return informationTransfer(payload);
      default: return null;
    }
  } catch (e) {
    if (e instanceof OutOfBounds) return null;
    throw e;
  }
}

/** UL-CCCH: c1, rrcSetupRequest, ue-Identity CHOICE (39 bits either way), establishmentCause, spare. */
function setupRequest(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 3);
  const random = b.read(1) === 1;
  // Wireshark prints a BIT STRING left-aligned in whole octets; 39 bits carry one pad bit.
  const identity = b.readLong(39) * 2;
  const fields = [field('UE identity', random ? 'random value' : '5G-S-TMSI part 1', [field('Value', '0x' + hex(identity, 10))])];
  fields.push(field('Establishment cause', at(ESTABLISHMENT_CAUSE, b.read(4))));
  return fields;
}

/** UL-CCCH: c1, rrcReestablishmentRequest, c-RNTI (16), physCellId (10), shortMAC-I (16), cause. */
function reestablishmentRequest(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 3);
  const cRnti = b.read(16);
  const pci = b.read(10);
  b.read(16);
  return [
    field('Cause', at(REESTABLISHMENT_CAUSE, b.read(2))),
    field('Previous cell PCI', `${pci}`),
    field('C-RNTI', '0x' + hex(cRnti, 4)),
  ];
}

/** DL-CCCH: c1, rrcReject, extension marker, three optionals, waitTime 1..16 s. */
function reject(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 3);
  if (b.read(1) !== 0) return []; // criticalExtensionsFuture
  const waitTime = b.read(1) === 1;
  b.read(2); // lateNonCriticalExtension, nonCriticalExtension
  return waitTime ? [field('Wait time', `${b.read(4) + 1} s`)] : [];
}

/**
 * DL-DCCH: transaction id, then RRCRelease-IEs: redirectedCarrierInfo, cellReselectionPriorities,
 * suspendConfig, deprioritisationReq and the two extension slots. A release with suspendConfig is the one that
 * leaves the phone in RRC inactive rather than idle, which is a different thing to see.
 */
function release(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 5);
  b.read(2); // transaction id
  if (b.read(1) !== 0) return [];
  const redirect = b.read(1) === 1;
  b.read(1); // cellReselectionPriorities
  const suspend = b.read(1) === 1;
  const deprioritise = b.read(1) === 1;
  const carries = [
    redirect ? 'redirect' : null,
    suspend ? 'suspend (RRC inactive)' : null,
    deprioritise ? 'deprioritisation' : null,
  ].filter((c) => c !== null);
  return carries.length ? [field('Carries', carries.join(', '))] : [];
}

/** PCCH: c1, paging, extension marker, optionals, then the paging records. */
function paging(p: Uint8Array): FlowField[] {
  const b = new PerBits(p, 2);
  const records = b.read(1) === 1;
  b.read(2); // lateNonCriticalExtension, nonCriticalExtension
  if (!records) return [];
  const count = b.read(5) + 1;
  const identities: FlowField[] = [];
  for (let k = 0; k < count; k++) {
    // PagingRecord and PagingUE-Identity are both extensible, so each opens with an extension bit.
    if (b.read(1) !== 0) continue;
    const accessType = b.read(1) === 1;
    if (b.read(1) !== 0) continue;
    const fiveGsTmsi = b.read(1) === 0;
    const value = fiveGsTmsi ? b.readLong(48) : b.readLong(44) * 16;
    if (accessType) b.read(1);
    identities.push(field(fiveGsTmsi ? '5G-S-TMSI' : 'I-RNTI', '0x' + hex(value, 12)));
  }
  return [field('Paged', `${count}`, identities)];
}

/**
 * UL-DCCH: transaction id, then RRCSetupComplete-IEs: four optionals, the selected PLMN, and the NAS message.
 * The NAS is the point: on this modem it is the only copy of the registration request there is.
 */
function setupComplete(p: Uint8Array): [FlowField[], Uint8Array | null] {
  const b = new PerBits(p, 5);
  b.read(2); // transaction id
  if (b.read(1) !== 0) return [[], null];
  const registeredAmf = b.read(1) === 1;
  const guamiType = b.read(1) === 1;
  const nssai = b.read(1) === 1;
  const tmsi = b.read(1) === 1;
  b.read(2); // lateNonCriticalExtension, nonCriticalExtension
  const plmn = b.read(4) + 1; // selectedPLMN-Identity, INTEGER (1..12)
  const fields = [field('Selected PLMN', `${plmn}`)];
  // Anything before the NAS message that this decoder cannot walk means the NAS cannot be trusted.
  if (registeredAmf || guamiType || nssai) return [fields, null];
  const nas = b.readOctetString();
  if (tmsi) fields.push(field('5G-S-TMSI', 'included'));
  return [fields, nas];
}

/** DL-DCCH / UL-DCCH: transaction id, then a NAS message and nothing else that moves. */
function informationTransfer(p: Uint8Array): Uint8Array | null {
  const b = new PerBits(p, 5);
  b.read(2); // transaction id
  if (b.read(1) !== 0) return null;
  const nas = b.read(1) === 1;
  b.read(2); // lateNonCriticalExtension, nonCriticalExtension
  return nas ? b.readOctetString() : null;
}
