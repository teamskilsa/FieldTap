// Port of ios/Contract/src-v1/NasFields.kt: the fields of a plain NAS message an engineer reads first (TS 24.301,
// TS 24.501): who the phone said it was, what it asked for, what the network gave it, and why anything was
// refused. Each decode is pinned to Wireshark's reading of the same bytes; the rest is in the hex.
//
// A message shorter than its own definition yields the fields read before it ran out, never an invented one:
// every unguarded read is a bounds-checked `u8`, which throws OutOfBounds as the JVM would.

import { ascii, OutOfBounds, u8 } from './bytes.ts';
import type { FlowField } from './flow.ts';
import { hex as hexOf } from './javafmt.ts';
import { field } from './lterrc.ts';
import { decodeNasPdu } from './nas.ts';

/** `pdu` starts at the NAS header; `uplink` is the direction the modem logged it in. */
export function epsFields(sublayer: string, securityHeader: number, messageType: number | null, pdu: Uint8Array, uplink: boolean): FlowField[] {
  const out: FlowField[] = [];
  keepWhatWasRead(() => {
    if (sublayer === 'emm' && securityHeader === 12) serviceRequest(pdu, out);
    else if (securityHeader !== 0 || messageType === null) return;
    else if (sublayer === 'emm') emm(messageType, pdu, uplink, out);
    else if (sublayer === 'esm') esm(messageType, pdu, out);
  });
  return out;
}

/** `pdu` starts at the 5GS NAS header (the extended protocol discriminator). */
export function fiveGsFields(sublayer: string, securityHeader: number, messageType: number | null, pdu: Uint8Array, _uplink: boolean): FlowField[] {
  const out: FlowField[] = [];
  if (securityHeader !== 0 || messageType === null) return out;
  keepWhatWasRead(() => {
    if (sublayer === '5gmm') fiveGmm(messageType, pdu, out);
    else if (sublayer === '5gsm') fiveGsm(messageType, pdu, out);
  });
  return out;
}

/** Truncated: keep what was read. */
function keepWhatWasRead(read: () => void): void {
  try {
    read();
  } catch (e) {
    if (!(e instanceof OutOfBounds)) throw e;
  }
}

const or = (table: ReadonlyMap<number, string>, key: number, fallback = 'reserved') => table.get(key) ?? fallback;

// MARK: - 5GMM

function fiveGmm(type: number, p: Uint8Array, out: FlowField[]): void {
  switch (type) {
    case 0x41: { // Registration request
      const octet = u8(p, 3);
      out.push(field('Registration type', or(REGISTRATION_TYPE, octet & 0x07)));
      if ((octet & 0x08) !== 0) out.push(field('Follow-on request', 'pending'));
      out.push(field('NAS key set', ksi(octet >> 4)));
      const identity = fiveGsIdentity(p, 6, (u8(p, 4) << 8) | u8(p, 5));
      if (identity) out.push(identity);
      break;
    }
    case 0x42: { // Registration accept
      const result = u8(p, 4);
      out.push(field('Registration result', or(REGISTRATION_RESULT, result & 0x07)));
      if ((result & 0x08) !== 0) out.push(field('SMS over NAS', 'allowed'));
      break;
    }
    case 0x44:
    case 0x4d: // Registration reject, Service reject: the cause is on the row
      timers(p, 4, out);
      break;
    case 0x45:
    case 0x47: { // Deregistration request
      const octet = u8(p, 3);
      out.push(field('Deregistration', (octet & 0x08) !== 0 ? 'switch off' : 'normal'));
      out.push(field('Access', or(ACCESS_TYPE, octet & 0x03)));
      if (type === 0x45) out.push(field('NAS key set', ksi(octet >> 4)));
      break;
    }
    case 0x4c: { // Service request: the service type is the high half octet, the key set the low one
      const octet = u8(p, 3);
      out.push(field('Service type', or(SERVICE_TYPE, (octet >> 4) & 0x0f)));
      out.push(field('NAS key set', ksi(octet)));
      break;
    }
    case 0x5b:
      out.push(field('Identity requested', or(FIVE_GS_IDENTITY_TYPE, u8(p, 3) & 0x07)));
      break;
    case 0x5d: { // Security mode command
      const algorithms = u8(p, 3);
      out.push(field('Ciphering', `5G-EA${(algorithms >> 4) & 0x07}`));
      out.push(field('Integrity', `5G-IA${algorithms & 0x07}`));
      out.push(field('NAS key set', ksi(u8(p, 4) & 0x0f)));
      break;
    }
    case 0x67:
    case 0x68: { // UL/DL NAS transport: a session-management message inside a mobility one
      const container = u8(p, 3) & 0x0f;
      out.push(field('Payload', or(PAYLOAD_CONTAINER, container, `type ${container}`)));
      const length = (u8(p, 4) << 8) | u8(p, 5);
      if (container === 1 && 6 + length <= p.length) {
        const inner = decodeNasPdu(p.slice(6, 6 + length), true);
        if (inner?.name != null) out.push(field('Carries', inner.name));
      }
      break;
    }
  }
}

/** GPRS timers a reject can carry: T3346 (0x5F) and T3502 (0x16), both one octet of value. */
function timers(p: Uint8Array, from: number, out: FlowField[]): void {
  let i = from;
  while (i + 2 < p.length) {
    const tag = u8(p, i);
    const length = u8(p, i + 1);
    if (tag === 0x5f && length === 1) out.push(field('T3346', gprsTimer(u8(p, i + 2))));
    else if (tag === 0x16 && length === 1) out.push(field('T3502', gprsTimer(u8(p, i + 2))));
    else if (tag >= 0x80) {
      i += 1;
      continue;
    }
    i += 2 + length;
  }
}

const be32 = (p: Uint8Array, at: number) => u8(p, at) * 0x1000000 + (u8(p, at + 1) << 16) + (u8(p, at + 2) << 8) + u8(p, at + 3);

/**
 * 5GS mobile identity (TS 24.501 9.11.3.4): a SUCI, which carries the subscriber's own MSIN in the clear under
 * the null scheme, or a 5G-GUTI the network handed out.
 */
function fiveGsIdentity(p: Uint8Array, at: number, length: number): FlowField | null {
  if (length < 1 || at + length > p.length) return null;
  switch (u8(p, at) & 0x07) {
    case 1: { // SUCI
      // Type octet, PLMN (3), routing indicator (2), protection scheme, public key id, then the MSIN.
      const scheme = u8(p, at + 6) & 0x0f;
      const children = [
        field('PLMN', plmn(p, at + 1)),
        field('Routing indicator', bcd(p, at + 4, 2)),
        field('Protection scheme', or(SUCI_SCHEME, scheme, `scheme ${scheme}`)),
      ];
      // Only the null scheme leaves the MSIN readable; the others are the whole point of SUCI.
      if (scheme === 0) children.push(field('MSIN', bcd(p, at + 8, length - 8)));
      return field('Identity', 'SUCI', children);
    }
    case 2:
      return field('Identity', '5G-GUTI', [
        field('PLMN', plmn(p, at + 1)),
        field('AMF region', `${u8(p, at + 4)}`),
        field('AMF set', `${((u8(p, at + 5) << 8) | u8(p, at + 6)) >> 6}`),
        field('AMF pointer', `${u8(p, at + 6) & 0x3f}`),
        field('5G-TMSI', '0x' + hexOf(be32(p, at + 7), 8)),
      ]);
    case 3:
      return field('Identity', `IMEI ${bcdDigits(p, at, length)}`);
    case 4:
      return field('Identity', '5G-S-TMSI');
    case 5:
      return field('Identity', `IMEISV ${bcdDigits(p, at, length)}`);
    default:
      return null;
  }
}

// MARK: - 5GSM

function fiveGsm(type: number, p: Uint8Array, out: FlowField[]): void {
  out.push(field('PDU session', `${u8(p, 1)}`));
  out.push(field('Procedure transaction', `${u8(p, 2)}`));
  if (type === 0xc1) { // PDU session establishment request
    let i = 6; // after the integrity protection maximum data rate
    while (i < p.length) {
      const tag = u8(p, i);
      if (tag >> 4 === 0x9) {
        out.push(field('PDU session type', or(FIVE_GS_PDN_TYPE, tag & 0x0f)));
        i += 1;
      } else if (tag >> 4 === 0xa) {
        out.push(field('SSC mode', `${tag & 0x0f}`));
        i += 1;
      } else if (tag >= 0x80) i += 1;
      else i += 2 + u8(p, i + 1);
    }
  } else if (type === 0xc2) { // PDU session establishment accept
    out.push(field('PDU session type', or(FIVE_GS_PDN_TYPE, u8(p, 4) & 0x0f)));
    out.push(field('SSC mode', `${(u8(p, 4) >> 4) & 0x07}`));
  }
}

// MARK: - EMM

function emm(type: number, p: Uint8Array, uplink: boolean, out: FlowField[]): void {
  switch (type) {
    case 0x41: { // Attach request
      out.push(field('Attach type', or(ATTACH_TYPE, u8(p, 2) & 0x07)));
      out.push(field('NAS key set', ksi(u8(p, 2) >> 4)));
      const identity = identityLv(p, 3);
      if (identity) out.push(identity);
      break;
    }
    case 0x42: { // Attach accept
      out.push(field('Attach result', or(ATTACH_RESULT, u8(p, 2) & 0x07)));
      out.push(field('T3412', gprsTimer(u8(p, 3))));
      const tai = firstTai(p, 5, u8(p, 4));
      if (tai) out.push(tai);
      break;
    }
    case 0x45: { // Detach request
      const octet = u8(p, 2);
      if (uplink) {
        // Switch-off bit and a detach type, then the identity.
        out.push(field('Detach type', or(DETACH_TYPE_UL, octet & 0x07)));
        out.push(field('Switch off', (octet & 0x08) !== 0 ? 'yes' : 'no'));
        out.push(field('NAS key set', ksi(octet >> 4)));
        const identity = identityLv(p, 3);
        if (identity) out.push(identity);
      } else {
        out.push(field('Detach type', or(DETACH_TYPE_DL, octet & 0x07)));
      }
      break;
    }
    case 0x48: { // Tracking area update request
      out.push(field('Update type', or(UPDATE_TYPE, u8(p, 2) & 0x07)));
      out.push(field('Active flag', (u8(p, 2) & 0x08) !== 0 ? 'set' : 'not set'));
      const identity = identityLv(p, 3);
      if (identity) out.push({ ...identity, label: 'Old GUTI' });
      break;
    }
    case 0x49:
      out.push(field('Update result', or(UPDATE_RESULT, u8(p, 2) & 0x07)));
      break;
    case 0x52: // Authentication request
      out.push(field('NAS key set', ksi(u8(p, 2) & 0x0f)));
      out.push(field('RAND', hexBytes(p, 3, 16)));
      break;
    case 0x55:
      out.push(field('Identity requested', or(IDENTITY_TYPE, u8(p, 2) & 0x07)));
      break;
    case 0x5d: { // Security mode command
      const algorithms = u8(p, 2);
      out.push(field('Ciphering', `EEA${(algorithms >> 4) & 0x07}`));
      out.push(field('Integrity', `EIA${algorithms & 0x07}`));
      out.push(field('NAS key set', ksi(u8(p, 3) & 0x0f)));
      break;
    }
    // 0x44, 0x4B, 0x4E, rejects: the cause is shown on the row already.
  }
}

/** SERVICE REQUEST: KSI and short sequence number, then a 2-octet short MAC. */
function serviceRequest(p: Uint8Array, out: FlowField[]): void {
  const ksiSeq = u8(p, 1);
  out.push(field('NAS key set', ksi(ksiSeq >> 5)));
  out.push(field('Sequence number', `${ksiSeq & 0x1f}`));
  out.push(field('Short MAC', '0x' + hexOf((u8(p, 2) << 8) | u8(p, 3), 4)));
}

// MARK: - ESM

function esm(type: number, p: Uint8Array, out: FlowField[]): void {
  out.push(field('EPS bearer identity', `${u8(p, 0) >> 4}`));
  out.push(field('Procedure transaction', `${u8(p, 1)}`));
  switch (type) {
    case 0xd0: // PDN connectivity request
      out.push(field('PDN type', or(PDN_TYPE, u8(p, 3) >> 4)));
      out.push(field('Request type', or(REQUEST_TYPE, u8(p, 3) & 0x0f)));
      optional(p, 4, (tag, at, length) => {
        if (tag === 0x28) out.push(field('APN', apn(p, at, length)));
      });
      break;
    case 0xc1: { // Activate default EPS bearer context request
      let at = 3;
      const qosLength = u8(p, at);
      out.push(field('QCI', `${u8(p, at + 1)}`));
      at += 1 + qosLength;
      const apnLength = u8(p, at);
      out.push(field('APN', apn(p, at + 1, apnLength)));
      at += 1 + apnLength;
      const address = pdnAddress(p, at + 1, u8(p, at));
      if (address) out.push(address);
      at += 1 + u8(p, at);
      optional(p, at, (tag, valueAt, length) => {
        if (tag === 0x27 || tag === 0x7b) out.push(...pco(p, valueAt, length));
      });
      break;
    }
    case 0xc5: // Activate dedicated EPS bearer context request
      out.push(field('Linked bearer', `${u8(p, 3) & 0x0f}`));
      out.push(field('QCI', `${u8(p, 5)}`));
      break;
    case 0xda:
      optional(p, 3, (tag, at, length) => {
        if (tag === 0x28) out.push(field('APN', apn(p, at, length)));
      });
      break;
  }
}

// MARK: - Information elements

/** EPS mobile identity, LV at `at`: IMSI, GUTI or IMEI. */
function identityLv(p: Uint8Array, at: number): FlowField | null {
  const length = u8(p, at);
  const start = at + 1;
  switch (u8(p, start) & 0x07) {
    case 6: { // GUTI
      const plmnText = plmn(p, start + 1);
      const mmeGroup = (u8(p, start + 4) << 8) | u8(p, start + 5);
      const mmeCode = u8(p, start + 6);
      const mTmsi = be32(p, start + 7);
      return field('Identity', 'GUTI', [
        field('PLMN', plmnText),
        field('MME group', `${mmeGroup}`),
        field('MME code', `${mmeCode}`),
        field('M-TMSI', '0x' + hexOf(mTmsi, 8)),
      ]);
    }
    case 1:
      return field('Identity', `IMSI ${bcdDigits(p, start, length)}`);
    case 2:
    case 3:
      return field('Identity', `IMEI ${bcdDigits(p, start, length)}`);
    default:
      return null;
  }
}

/** Plain BCD digits, low nibble first, stopping at the 0xF filler. */
export function bcd(p: Uint8Array, at: number, octets: number): string {
  let s = '';
  for (let i = 0; i < octets; i++) {
    const o = u8(p, at + i);
    const low = o & 0x0f;
    if (low === 0x0f) break;
    s += `${low}`;
    const high = o >> 4;
    if (high === 0x0f) break;
    s += `${high}`;
  }
  return s;
}

/** Digits of an odd/even BCD identity: the first digit in the high nibble of the type octet. */
function bcdDigits(p: Uint8Array, start: number, length: number): string {
  const odd = (u8(p, start) & 0x08) !== 0;
  let s = `${u8(p, start) >> 4}`;
  for (let i = 1; i < length; i++) {
    const o = u8(p, start + i);
    s += `${o & 0x0f}`;
    if (i < length - 1 || odd) s += `${o >> 4}`;
  }
  return s;
}

/** Three octets of BCD MCC and MNC, as '001-01'. */
export function plmn(p: Uint8Array, at: number): string {
  const o1 = u8(p, at);
  const o2 = u8(p, at + 1);
  const o3 = u8(p, at + 2);
  const mcc = `${o1 & 0x0f}${o1 >> 4}${o2 & 0x0f}`;
  const mnc3 = o2 >> 4;
  const mnc = `${o3 & 0x0f}${o3 >> 4}` + (mnc3 === 0x0f ? '' : `${mnc3}`);
  return `${mcc}-${mnc}`;
}

function firstTai(p: Uint8Array, at: number, length: number): FlowField | null {
  if (length < 6) return null;
  // All three list types put the first PLMN and TAC straight after the type-and-count octet.
  const tac = (u8(p, at + 4) << 8) | u8(p, at + 5);
  return field('Tracking area', `${plmn(p, at + 1)} TAC ${tac}`);
}

/** APN: length-prefixed labels, shown dotted. */
export function apn(p: Uint8Array, at: number, length: number): string {
  const labels: string[] = [];
  let i = at;
  while (i < at + length) {
    const n = u8(p, i);
    labels.push(ascii(p, i + 1, n));
    i += 1 + n;
  }
  return labels.join('.');
}

/** PDN address: a PDN type, then IPv4 (4), an IPv6 interface identifier (8), or both. */
function pdnAddress(p: Uint8Array, at: number, length: number): FlowField | null {
  const type = u8(p, at) & 0x07;
  const children = [field('PDN type', or(PDN_TYPE, type))];
  if (type === 1) children.push(field('IPv4', ipv4(p, at + 1)));
  else if (type === 2) children.push(field('IPv6 interface ID', ipv6Iid(p, at + 1)));
  else if (type === 3) {
    children.push(field('IPv6 interface ID', ipv6Iid(p, at + 1)));
    children.push(field('IPv4', ipv4(p, at + 9)));
  }
  if (length < 5) return null;
  // The row shows the IPv4 address when there is one: it is the one people ping.
  const shown = children.find((c) => c.label === 'IPv4') ?? children[children.length - 1];
  return field('PDN address', shown.value, children);
}

const ipv4 = (p: Uint8Array, at: number) => [0, 1, 2, 3].map((k) => `${u8(p, at + k)}`).join('.');

const group = (p: Uint8Array, at: number) => (u8(p, at) << 8) | u8(p, at + 1);

/** Wireshark writes the 64-bit interface identifier as '::2001:468:3000:1'; so does this. */
const ipv6Iid = (p: Uint8Array, at: number) => '::' + [0, 1, 2, 3].map((k) => group(p, at + 2 * k).toString(16)).join(':');

/**
 * Walks optional IEs from `at`. Tags 0x80 and up are one-octet (type 1 and 2) IEs; ESM cause (0x58) and LLC
 * SAPI (0x32) are two-octet TVs; the extended PCO (0x7B) and extended QoS-like containers (0x78) have a
 * two-octet length; the rest are TLVs with one length octet.
 */
function optional(p: Uint8Array, at: number, each: (tag: number, valueAt: number, length: number) => void): void {
  let i = at;
  while (i < p.length) {
    const tag = u8(p, i);
    if (tag >= 0x80) {
      i += 1;
      continue;
    }
    if (tag === 0x58 || tag === 0x32) {
      i += 2;
      continue;
    }
    if (tag === 0x7b || tag === 0x78) { // LV-E: two-octet length
      const length = (u8(p, i + 1) << 8) | u8(p, i + 2);
      each(tag, i + 3, length);
      i += 3 + length;
      continue;
    }
    const length = u8(p, i + 1);
    each(tag, i + 2, length);
    i += 2 + length;
  }
}

/**
 * Protocol configuration options (TS 24.008 10.5.6.3), network to phone: the DNS servers and P-CSCFs. The rest
 * (IPCP, slices, QoS rules) is Wireshark's to show. Containers 0x0023 and 0x0024 carry a two-octet length;
 * everything else one.
 */
function pco(p: Uint8Array, at: number, length: number): FlowField[] {
  const end = Math.min(at + length, p.length);
  const out: FlowField[] = [];
  let i = at + 1; // configuration protocol octet
  while (i + 3 <= end) {
    const id = (u8(p, i) << 8) | u8(p, i + 1);
    const wide = id === 0x0023 || id === 0x0024;
    const size = wide ? (u8(p, i + 2) << 8) | u8(p, i + 3) : u8(p, i + 2);
    const valueAt = i + (wide ? 4 : 3);
    if (valueAt + size > end) break;
    if (id === 0x000d && size === 4) out.push(field('DNS server', ipv4(p, valueAt)));
    else if (id === 0x0003 && size === 16) out.push(field('DNS server', ipv6(p, valueAt)));
    else if (id === 0x000c && size === 4) out.push(field('P-CSCF', ipv4(p, valueAt)));
    else if (id === 0x0001 && size === 16) out.push(field('P-CSCF', ipv6(p, valueAt)));
    i = valueAt + size;
  }
  return out;
}

/** An IPv6 address the way Wireshark and RFC 5952 write it: the longest run of zero groups as '::'. */
export function ipv6(p: Uint8Array, at: number): string {
  const groups = Array.from({ length: 8 }, (_, k) => group(p, at + 2 * k));
  let bestStart = -1;
  let bestLength = 1;
  let i = 0;
  while (i < 8) {
    if (groups[i] === 0) {
      let j = i;
      while (j < 8 && groups[j] === 0) j++;
      if (j - i > bestLength) {
        bestStart = i;
        bestLength = j - i;
      }
      i = j;
    } else {
      i++;
    }
  }
  const text = (from: number, to: number) => groups.slice(from, to).map((g) => g.toString(16)).join(':');
  return bestStart < 0 ? text(0, 8) : text(0, bestStart) + '::' + text(bestStart + bestLength, 8);
}

/** GPRS timer (TS 24.008 10.5.7.3): 3-bit unit, 5-bit value. */
export function gprsTimer(octet: number): string {
  const value = octet & 0x1f;
  switch (octet >> 5) {
    case 0: return `${value * 2} s`;
    case 1: return `${value} min`;
    case 2: return `${value * 6} min`;
    case 7: return 'deactivated';
    default: return `${value} min`;
  }
}

const ksi = (value: number) => ((value & 0x07) === 7 ? 'no key available' : `${value & 0x07}`);

function hexBytes(p: Uint8Array, at: number, length: number): string {
  let s = '';
  for (let k = 0; k < length; k++) s += hexOf(u8(p, at + k), 2);
  return s;
}

const table = (entries: [number, string][]): ReadonlyMap<number, string> => new Map(entries);

const ATTACH_TYPE = table([[1, 'EPS attach'], [2, 'combined EPS/IMSI attach'], [3, 'EPS RLOS attach'], [6, 'EPS emergency attach']]);
const ATTACH_RESULT = table([[1, 'EPS only'], [2, 'combined EPS/IMSI']]);
const DETACH_TYPE_UL = table([[1, 'EPS detach'], [2, 'IMSI detach'], [3, 'combined EPS/IMSI detach']]);
const DETACH_TYPE_DL = table([[1, 're-attach required'], [2, 're-attach not required'], [3, 'IMSI detach']]);
const UPDATE_TYPE = table([[0, 'TA updating'], [1, 'combined TA/LA updating'], [2, 'combined TA/LA with IMSI attach'], [3, 'periodic updating']]);
const UPDATE_RESULT = table([[0, 'TA updated'], [1, 'combined TA/LA updated'], [4, 'TA updated, ISR activated'], [5, 'combined TA/LA updated, ISR activated']]);
const IDENTITY_TYPE = table([[1, 'IMSI'], [2, 'IMEI'], [3, 'IMEISV'], [4, 'TMSI']]);
const PDN_TYPE = table([[1, 'IPv4'], [2, 'IPv6'], [3, 'IPv4v6'], [5, 'non-IP'], [6, 'Ethernet']]);
const REQUEST_TYPE = table([[1, 'initial request'], [2, 'handover'], [4, 'emergency']]);
const REGISTRATION_TYPE = table([
  [1, 'initial registration'], [2, 'mobility registration updating'], [3, 'periodic registration updating'],
  [4, 'emergency registration'], [7, 'SNPN onboarding registration'],
]);
const REGISTRATION_RESULT = table([[1, '3GPP access'], [2, 'non-3GPP access'], [3, '3GPP and non-3GPP access']]);
const ACCESS_TYPE = table([[1, '3GPP access'], [2, 'non-3GPP access'], [3, '3GPP and non-3GPP access']]);
const SERVICE_TYPE = table([
  [0, 'signalling'], [1, 'data'], [2, 'mobile terminated services'], [3, 'emergency services'],
  [4, 'emergency services fallback'], [5, 'high priority access'], [6, 'elevated signalling'],
]);
const FIVE_GS_IDENTITY_TYPE = table([[1, 'SUCI'], [2, '5G-GUTI'], [3, 'IMEI'], [4, '5G-S-TMSI'], [5, 'IMEISV']]);
const SUCI_SCHEME = table([[0, 'null scheme'], [1, 'Profile A'], [2, 'Profile B']]);
const FIVE_GS_PDN_TYPE = table([[1, 'IPv4'], [2, 'IPv6'], [3, 'IPv4v6'], [4, 'unstructured'], [5, 'Ethernet']]);
const PAYLOAD_CONTAINER = table([
  [1, 'N1 SM information'], [2, 'SMS'], [3, 'LTE positioning protocol'], [4, 'SOR transparent container'],
  [5, 'UE policy container'], [6, 'UE parameters update'], [8, 'CIoT user data container'],
]);
