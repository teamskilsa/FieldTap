// Constructed signalling records for the synthetic tests: the helpers of android/diag CallFlowTest.kt (and its
// Swift port, FTSignallingTests/CallFlowTests.swift), with the same inline bytes. Nothing here is capture-derived.

import { hdlcEncode } from '../src/diag/hdlc.ts';
import { encodeLogPacket, type LogRecord } from '../src/diag/record.ts';
import type { Cell } from '../src/signalling/flow.ts';

/** '0 1 0 00000001' -> bytes, zero-padded to a whole octet. */
export function bits(s: string): Uint8Array {
  const b = s.replace(/\s+/g, '');
  const padded = b.padEnd(Math.ceil(b.length / 8) * 8, '0');
  return Uint8Array.from({ length: padded.length / 8 }, (_, i) => parseInt(padded.slice(8 * i, 8 * i + 8), 2));
}

/** '0748010b' (spaces allowed) -> bytes. */
export function hex(s: string): Uint8Array {
  const h = s.replace(/\s+/g, '');
  return Uint8Array.from({ length: h.length / 2 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
}

export const cat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
};

/** A raw modem stamp `gpsMs` after the GPS epoch, in 1.25 ms ticks (the low 16 bits zero). */
export const stampAt = (gpsMs: number) => BigInt(Math.floor((gpsMs * 4) / 5)) << 16n;

export const ULCCCH = 10, DLCCCH = 8, ULDCCH = 11, DLDCCH = 9, BCCH = 3;

/** Constructed records on a running clock, as the Kotlin test's `record()` helpers build them. One per test. */
export class Capture {
  private clockMs = 1_000_000_000;

  record(code: number, body: Uint8Array, afterMs = 20): LogRecord {
    this.clockMs += afterMs;
    return { code, timestampRaw: stampAt(this.clockMs), body, more: 0 };
  }

  /** A version-27 (SM8450) LTE RRC OTA record body: header layout D, then the PDU. */
  static rrc(cell: Cell, pdu: number, payload: Uint8Array): Uint8Array {
    const header = new Uint8Array(21);
    const view = new DataView(header.buffer);
    header[0] = 27;
    view.setUint16(1 + 5, cell.pci, true);
    view.setUint16(1 + 7, cell.earfcn, true);
    header[1 + 13] = pdu;
    view.setUint16(1 + 18, payload.length, true);
    return cat(header, payload);
  }

  /** A version-30 (iPhone 17) LTE RRC OTA record body: header layout E (D2), then the PDU. */
  static rrcV30(cell: Cell, pdu: number, payload: Uint8Array): Uint8Array {
    const header = new Uint8Array(24);
    const view = new DataView(header.buffer);
    header[0] = 30;
    view.setUint16(1 + 5, cell.pci, true);
    view.setUint32(1 + 7, cell.earfcn, true);
    header[1 + 13] = pdu;
    view.setUint16(1 + 18, payload.length, true);
    return cat(header, payload);
  }

  /** A version-26 (iPhone 17) NR RRC OTA record body: 4-byte version, the 31-byte header of layout E, the PDU. */
  static nrRrc(cell: Cell, pdu: number, payload: Uint8Array): Uint8Array {
    const body = new Uint8Array(4 + 31);
    const view = new DataView(body.buffer);
    body[0] = 26;
    body[4 + 2] = 1;
    view.setUint16(4 + 3, cell.pci, true);
    view.setUint32(4 + 13, cell.earfcn, true);
    body[4 + 20] = pdu;
    view.setUint16(4 + 25, payload.length, true);
    return cat(body, payload);
  }

  request(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, ULCCCH, bits('0 1 0 0 00000001 11110101 00011010 01100010 10101101 100 0')));
  }
  setup(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, DLCCCH, bits('0 11 0000')));
  }
  setupComplete(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, ULDCCH, bits('0 0100 000')));
  }
  handoverTo2(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, DLDCCH, hex('22082004 0b228246 80000000 0000')));
  }
  reconfigurationComplete(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, ULDCCH, bits('0 0010 000')));
  }
  release(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, DLDCCH, hex('2801')));
  }
  releaseRedirect(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, DLDCCH, hex('282200a280')));
  }
  reestablishment(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, ULCCCH, hex('0246802abcd4')));
  }
  sib1(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, BCCH, bits('0 1 000000')), 800);
  }
  connected(cell: Cell) {
    return [this.request(cell), this.setup(cell), this.setupComplete(cell)];
  }
  /** An LTE reconfiguration that is not a handover: it carries radio resources only. */
  reconfiguration(cell: Cell) {
    return this.record(0xb0c0, Capture.rrc(cell, DLDCCH, bits('0 0100 00 0 000 0 0 0 1 0 0')));
  }
  nrReconfiguration(cell: Cell) {
    return this.record(0xb821, Capture.nrRrc(cell, 11, hex('0800')), 1);
  }
  nrReconfigurationComplete(cell: Cell) {
    return this.record(0xb821, Capture.nrRrc(cell, 12, hex('0000')), 1);
  }
  /** A NAS record: a 4-byte header, then the PDU. */
  nas(code: number, pdu: string) {
    return this.record(code, hex('01000000 ' + pdu), 1);
  }
}

/** A record re-stamped `gpsMs` after the GPS epoch. */
export const stamped = (gpsMs: number, r: LogRecord): LogRecord => ({ ...r, timestampRaw: stampAt(gpsMs) });

/** One log packet, HDLC-framed as a capture holds it. */
export const framed = (code: number, body: Uint8Array, timestampRaw = 42n) =>
  hdlcEncode(encodeLogPacket({ code, timestampRaw, body, more: 0 }));
