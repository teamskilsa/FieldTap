// Reading and writing .qmdl files: HDLC frames holding diag log packets. The reader is CallFlow.read's front end
// (Unframer + Protocol, counted the way GoldenDump.kt counts); the writer lays records out exactly as
// qdss_deframe.py does, so a rebuilt log hashes the same as the Python's.

import { hdlcEncode, Unframer } from './hdlc.ts';
import { encodeLogPacket, hexCode, type LogRecord, logPacketsOf, NotALogPacket, parseLogPacket } from './record.ts';

export interface QmdlRead {
  records: LogRecord[];
  /** Frames whose CRC checked (the golden's source.hdlcFrames). */
  frames: number;
  crcErrors: number;
  /** Log packets too short to parse (source.badPackets). */
  badPackets: number;
}

/** A streaming qmdl reader: feed any split of the file, then `finish`. */
export class QmdlReader {
  private readonly unframer = new Unframer();
  private readonly records: LogRecord[] = [];
  private badPackets = 0;

  feed(bytes: Uint8Array): void {
    this.unframer.feed(bytes, (frame) => {
      for (const packet of logPacketsOf(frame)) {
        try {
          this.records.push(parseLogPacket(packet));
        } catch (e) {
          if (!(e instanceof NotALogPacket)) throw e;
          this.badPackets++;
        }
      }
    });
  }

  finish(): QmdlRead {
    return {
      records: this.records,
      frames: this.unframer.frames,
      crcErrors: this.unframer.crcErrors,
      badPackets: this.badPackets,
    };
  }
}

export function readQmdl(bytes: Uint8Array): QmdlRead {
  const reader = new QmdlReader();
  reader.feed(bytes);
  return reader.finish();
}

/** One HDLC frame per record, in the order given. Returns the bytes written. */
export function writeQmdl(records: Iterable<LogRecord>, sink: (frame: Uint8Array) => void): number {
  let bytes = 0;
  for (const r of records) {
    const frame = hdlcEncode(encodeLogPacket(r));
    bytes += frame.length;
    sink(frame);
  }
  return bytes;
}

/** Records per log code, keyed '0xB0C0' and sorted by code: the golden's recordsPerCode. */
export function recordsPerCode(records: Iterable<LogRecord>): Record<string, number> {
  const counts = new Map<number, number>();
  for (const r of records) counts.set(r.code, (counts.get(r.code) ?? 0) + 1);
  const out: Record<string, number> = {};
  for (const code of [...counts.keys()].sort((a, b) => a - b)) {
    out[hexCode(code)] = counts.get(code)!;
  }
  return out;
}
