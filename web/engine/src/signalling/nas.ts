// Port of ios/Contract/src-v1/Nas.kt: NAS messages, and the cause when the network refuses something.
//
// NAS is a protocol discriminator, a message type and TLVs, so the message and its cause are read straight from
// the bytes. The PDU is found rather than assumed: the header in front of it differs by modem generation, so
// `locate` tries the offsets those generations use and keeps the first where a valid NAS header starts, falling
// back to a short scan. A ciphered message yields its sublayer and security header but no type (the type octet
// is inside the encrypted part), and that is reported as unknown rather than guessed.

import { nasCauseName, nasMessageName } from './nasnames.ts';

export const EPD_5GMM = 0x7e;
export const EPD_5GSM = 0x2e;
export const PD_EMM = 0x07;
export const PD_ESM = 0x02;

/** Header sizes seen in front of an LTE NAS PDU, most likely first. */
const LTE_OFFSETS = [4, 3, 5, 6, 8];
/** Header sizes seen in front of an NR NAS PDU, most likely first. */
const NR_OFFSETS = [4, 7, 8, 5, 6, 12, 16];

const inEsmTypes = (v: number) => v >= 0xc1 && v <= 0xeb;
const in5gsmTypes = (v: number) => v >= 0xc1 && v <= 0xd6;

/** How the PDU was found: straight from the table, by trying another offset, or by scanning. */
export type Located = 'TABLE' | 'PROBED' | 'SCANNED';

/** What one NAS PDU says. */
export interface NasMessage {
  /** 'emm', 'esm', '5gmm' or '5gsm'. */
  sublayer: string;
  /** The security header type; 0 is plain. */
  securityHeader: number;
  /** Null when the message is ciphered, so the type octet cannot be read. */
  messageType: number | null;
  name: string | null;
  /** 'ul', 'dl', or null when the type alone does not say. */
  direction: 'ul' | 'dl' | null;
  /** The 3GPP cause, when this message carries one. */
  cause: number | null;
  causeName: string | null;
  /** Where the PDU started inside the log record body. */
  offset: number;
  located: Located;
}

function looksLikeEps(p: Uint8Array, from: number): boolean {
  if (p.length - from < 2) return false;
  const head = p[from];
  const pd = head & 0x0f;
  const sec = head >> 4;
  if (pd === PD_EMM) return [0, 1, 2, 3, 4, 12].includes(sec);
  if (pd === PD_ESM) return p.length - from >= 3 && inEsmTypes(p[from + 2]);
  return false;
}

function looksLike5gs(p: Uint8Array, from: number): boolean {
  if (p.length - from < 3) return false;
  switch (p[from]) {
    case EPD_5GMM: return p[from + 1] <= 4;
    case EPD_5GSM: return p.length - from >= 4 && in5gsmTypes(p[from + 3]);
    default: return false;
  }
}

/** Where the NAS PDU starts inside `body`, or null when none is recognisable. */
function locate(body: Uint8Array, nr: boolean): [number, Located] | null {
  const offsets = nr ? NR_OFFSETS : LTE_OFFSETS;
  const looks = nr ? looksLike5gs : looksLikeEps;
  for (let index = 0; index < offsets.length; index++) {
    const candidate = offsets[index];
    if (candidate < body.length && looks(body, candidate)) return [candidate, index === 0 ? 'TABLE' : 'PROBED'];
  }
  for (let candidate = 1; candidate < Math.min(24, body.length); candidate++) {
    if (looks(body, candidate)) return [candidate, 'SCANNED'];
  }
  return null;
}

type Classified = [sublayer: string, securityHeader: number, messageType: number | null];

/** (sublayer, security header, message type) for an EPS PDU. */
function classifyEps(p: Uint8Array): Classified {
  const head = p[0];
  const pd = head & 0x0f;
  const sec = head >> 4;
  if (pd === PD_ESM) return ['esm', 0, p.length > 2 ? p[2] : null];
  if (sec === 0) return ['emm', 0, p.length > 1 ? p[1] : null];
  // Service request carries a short header and no type octet.
  if (sec === 12) return ['emm', 12, null];
  const innerAt = 6;
  if ((sec === 1 || sec === 3) && p.length - innerAt >= 2) {
    const ih = p[innerAt];
    if ((ih & 0x0f) === PD_EMM && ih >> 4 === 0) return ['emm', sec, p[innerAt + 1]];
    if (p.length - innerAt >= 3 && (ih & 0x0f) === PD_ESM) return ['esm', sec, p[innerAt + 2]];
  }
  return ['emm', sec, null];
}

/** (sublayer, security header, message type) for a 5GS PDU. */
function classify5gs(p: Uint8Array): Classified {
  if (p[0] === EPD_5GSM) return ['5gsm', 0, p.length > 3 ? p[3] : null];
  const sec = p[1];
  if (sec === 0) return ['5gmm', 0, p.length > 2 ? p[2] : null];
  const innerAt = 7;
  if ((sec === 1 || sec === 3) && p.length - innerAt >= 3) {
    const ih = p[innerAt];
    if (ih === EPD_5GMM && p[innerAt + 1] === 0) return ['5gmm', sec, p[innerAt + 2]];
    if (p.length - innerAt >= 4 && ih === EPD_5GSM) return ['5gsm', sec, p[innerAt + 3]];
  }
  return ['5gmm', sec, null];
}

/**
 * The cause carried by a plain reject, or null. In every message below the cause is the mandatory octet
 * straight after the message type, so it is read from a fixed place: EMM and ESM put the type second in the
 * PDU, 5GMM and 5GSM third and fourth. A ciphered message has no readable type and so no readable cause.
 */
function causeOf(sublayer: string, securityHeader: number, msgType: number | null, pdu: Uint8Array): number | null {
  if (securityHeader !== 0 || msgType === null) return null;
  let at: number;
  if (sublayer === 'emm' && [0x44, 0x4b, 0x4e].includes(msgType)) at = 2;
  else if (sublayer === 'esm' && [0xc3, 0xc7, 0xcb, 0xd1, 0xd3, 0xd5, 0xd7].includes(msgType)) at = 3;
  else if (sublayer === '5gmm' && [0x44, 0x4d].includes(msgType)) at = 3;
  else if (sublayer === '5gsm' && [0xc5, 0xc7, 0xca].includes(msgType)) at = 4;
  else return null;
  return at < pdu.length ? pdu[at] : null;
}

/** The NAS PDU out of a log record `body`, or null when there is none. `nr` selects the 5GS reading. */
export function decodeNas(body: Uint8Array, nr: boolean): NasMessage | null {
  const found = locate(body, nr);
  if (found === null) return null;
  const [offset, located] = found;
  return decode(body.slice(offset), nr, offset, located);
}

/**
 * A PDU already known to start at its NAS header, such as the message inside a security-protected one. Null
 * when it does not look like NAS.
 */
export function decodeNasPdu(pdu: Uint8Array, nr: boolean): NasMessage | null {
  const looks = nr ? looksLike5gs(pdu, 0) : looksLikeEps(pdu, 0);
  return looks ? decode(pdu, nr, 0, 'TABLE') : null;
}

function decode(pdu: Uint8Array, nr: boolean, offset: number, located: Located): NasMessage {
  const [sublayer, sec, msgType] = nr ? classify5gs(pdu) : classifyEps(pdu);
  const [name, direction] = sublayer === 'emm' && sec === 12 ? ['Service request', 'ul' as const] : nasMessageName(sublayer, msgType);
  const cause = causeOf(sublayer, sec, msgType, pdu);
  return {
    sublayer,
    securityHeader: sec,
    messageType: msgType,
    name,
    direction,
    cause,
    causeName: cause !== null ? nasCauseName(sublayer, cause) : null,
    offset,
    located,
  };
}
