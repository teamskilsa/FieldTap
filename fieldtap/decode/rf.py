"""Modem front-end and clock records of the iPhone 17 (Qualcomm M25): 0x184C and 0x1D0B.

Neither has a published layout. Both were derived and validated on the captures of
2026-09-21/22 by this repository's TypeScript engine (web/engine/src/phy/decoders/
fedTxAgc.ts, modemClock.ts; the evidence is in docs/research/iphone-unknown-log-codes.md)
and are ported here field for field. Each decoder reads one version and refuses the
others, never guessing at a layout.

0x184C "LTE RF FED Tx AGC" v0x11 (FED = front-end driver; the name is in the QXDM release
notes). A record is N blocks; a block is a 16-byte header plus 1..3 120-byte sub-records,
one per transmit chain. Block header: byte 0 = 0x11, five zero bytes at +2, u16 @7 = a
subframe counter packed as frame << 8 | subframe << 4 - the front end's own counter, not
the cell's SFN (it does not place the sample in time; the DIAG timestamp does), so it is
read, range-checked and reported as such. Sub-record: u8 @0 chain tag, u8 @1 AGC / PA
gain state (a lower state means more power), i16 @4 transmit power in 0.1 dBm (-70.0 =
chain off), i16 @6 a second transmit-power measure, u16 @66/@68/@70 the chain's own power
limits in 0.1 dBm (the smallest is the binding one). A walk that finds block headers by
their signature consumes the body exactly on 99.92% / 99.98% of records; a record whose
walk does not close is reported with no sub-records rather than read on a guess. The
powers are the front end's own (a 3.8 dB residual against the PUSCH power of 0xB139):
label them "front-end Tx power", not "PUSCH power".

0x1D0B, a 100 Hz modem sampler, version 7. No public name, and what it samples every
2 ms is not identified, so only its clocks and sequence number are read: u32 version @0,
u32 @4 a 1024 Hz counter (the 32.768 kHz sleep clock / 32, measured 1,023.8..1,023.9
counts/s), u32 @8 a 19.2 MHz counter (24 bits, wraps every 0.874 s), u32 @84 a sequence
number (+1 on 1,902 of 1,907 consecutive records). The 1024 Hz counter measures how much
wall time a hole in the trace swallowed.
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .records import DiagRecord

HW_NOTE = "layout validated on the iPhone 17 (M25) captures of 2026-09-21/22"

FED_TX_AGC_VERSION = 0x11
_BLOCK_HEADER_BYTES = 16
_SUB_BYTES = 120
CHAIN_OFF_DBM = -70.0

MODEM_CLOCK_VERSION = 7
_MODEM_CLOCK_MIN_BODY = 88
CLOCK_1024_HZ = 1024


def _record(rec: LogRecord, info, default_name: str, version: int, fields: dict, sections: list, decoded: str,
            notes: list) -> DiagRecord:
    return DiagRecord(rec.code, info.name if info else default_name, version, rec.timestamp, rec.timestamp_raw,
                      rec.body, fields=fields, sections=sections, decoded=decoded,
                      confidence=info.confidence if info else "low", note="; ".join(notes))


# --- 0x184C LTE RF FED Tx AGC ------------------------------------------------------------------

def _is_block_header(body: bytes, p: int) -> bool:
    return (p + _BLOCK_HEADER_BYTES <= len(body) and body[p] == FED_TX_AGC_VERSION
            and body[p + 2:p + 7] == b"\x00\x00\x00\x00\x00")


def decode_fed_tx_agc(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0x184C v0x11: the transmit chains of one record, block by block (fedTxAgc.ts decodeX184C)."""
    body = rec.body
    if len(body) < 2:
        return None
    version = body[0]
    fields = {"version": version, "num_blocks_declared": body[1]}
    notes = [HW_NOTE]
    if version != FED_TX_AGC_VERSION:
        notes.append("version %d not implemented (only v%d)" % (version, FED_TX_AGC_VERSION))
        return _record(rec, info, "LTE RF FED Tx AGC", version, fields, [], "partial", notes)
    blocks, chains = [], []
    subframes_in_range = 0
    pos = 0
    closed = True
    while pos + _BLOCK_HEADER_BYTES <= len(body):
        if not _is_block_header(body, pos):
            closed = False
            break
        word = struct.unpack_from("<H", body, pos + 7)[0]
        frame, subframe = (word >> 8) & 0x3FF, (word >> 4) & 0xF
        if subframe <= 9:
            subframes_in_range += 1
        counter = frame * 10 + subframe
        index = len(blocks)
        blocks.append({"block": index, "subframe_counter": counter, "frame": frame, "subframe": subframe})
        pos += _BLOCK_HEADER_BYTES
        while pos + _SUB_BYTES <= len(body) and not _is_block_header(body, pos):
            power, power2 = struct.unpack_from("<hh", body, pos + 4)
            limits = struct.unpack_from("<HHH", body, pos + 66)
            chains.append({"block": index, "subframe_counter": counter, "chain": body[pos], "gain_state": body[pos + 1],
                           "tx_power_dbm": power / 10.0, "tx_power2_dbm": power2 / 10.0,
                           "limit0_dbm": limits[0] / 10.0, "limit1_dbm": limits[1] / 10.0, "limit2_dbm": limits[2] / 10.0,
                           "live": int(power / 10.0 > CHAIN_OFF_DBM)})
            pos += _SUB_BYTES
    exact = closed and pos == len(body)
    fields.update({"num_blocks": len(blocks), "walk_exact": int(exact), "subframes_in_range": subframes_in_range})
    if not exact:
        # The walk did not consume the body: the sub-records are not read on a guess.
        notes.append("block walk did not consume the body; no chain samples read")
        return _record(rec, info, "LTE RF FED Tx AGC", version, fields, [("blocks", blocks), ("chains", [])],
                       "partial", notes)
    fields["num_chain_samples"] = len(chains)
    live = [c for c in chains if c["live"]]
    if live:
        first = live[0]
        fields.update({"chain": first["chain"], "gain_state": first["gain_state"], "tx_power_dbm": first["tx_power_dbm"],
                       "tx_power2_dbm": first["tx_power2_dbm"],
                       "limit_dbm": min(first["limit0_dbm"], first["limit1_dbm"], first["limit2_dbm"]),
                       "max_tx_power_dbm": max(c["tx_power_dbm"] for c in live), "num_live": len(live)})
    else:
        fields["num_live"] = 0
    if subframes_in_range < len(blocks):
        notes.append("%d block counters outside subframes 0..9" % (len(blocks) - subframes_in_range))
    notes.append("front-end Tx power, not the PUSCH target; the block counter is not the cell's SFN")
    return _record(rec, info, "LTE RF FED Tx AGC", version, fields, [("blocks", blocks), ("chains", chains)],
                   "fields", notes)


def fed_tx_agc_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "num_chain_samples" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    head = "%d blocks %d chain samples" % (fields["num_blocks"], fields["num_chain_samples"])
    if fields.get("num_live"):
        return head + " Tx %.1f dBm chain 0x%02X gain state 0x%02X limit %.1f dBm" % (
            fields["tx_power_dbm"], fields["chain"], fields["gain_state"], fields["limit_dbm"])
    return head + " no chain transmitting"


# --- 0x1D0B modem 100 Hz sampler ----------------------------------------------------------------

def decode_modem_clock(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0x1D0B v7: the two clocks and the sequence number (modemClock.ts decodeX1D0B)."""
    body = rec.body
    if len(body) < 4:
        return None
    version = struct.unpack_from("<I", body, 0)[0]
    fields = {"version": version}
    notes = [HW_NOTE]
    if version != MODEM_CLOCK_VERSION:
        notes.append("version %d not implemented (only v%d)" % (version, MODEM_CLOCK_VERSION))
        return _record(rec, info, "Modem 100 Hz sampler", version, fields, [], "partial", notes)
    if len(body) < _MODEM_CLOCK_MIN_BODY:
        return None
    ticks_1024, ticks_19m2 = struct.unpack_from("<II", body, 4)
    fields.update({"ticks_1024hz": ticks_1024, "ticks_19m2": ticks_19m2 & 0xFFFFFF,
                   "sequence": struct.unpack_from("<I", body, 84)[0]})
    notes.append("only the clocks and the sequence number are read; the five 2 ms entries are not identified")
    return _record(rec, info, "Modem 100 Hz sampler", version, fields, [], "fields", notes)


def modem_clock_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "sequence" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    return "seq %d sleep clock %d (1024 Hz) TCXO %d (19.2 MHz)" % (fields["sequence"], fields["ticks_1024hz"],
                                                                  fields["ticks_19m2"])


DECODERS = {"lte_fed_tx_agc": decode_fed_tx_agc, "modem_clock": decode_modem_clock}
