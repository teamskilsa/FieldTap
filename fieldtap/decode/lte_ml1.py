"""LTE ML1 measurement records: 0xB193, 0xB179, 0xB17F, 0xB180.

Not OTA messages: the modem's own serving-cell and neighbour measurements, logged
whether or not RRC ever sends a MeasurementReport. Each decoder turns a record body
into a DiagRecord (records.py): flat headline fields, per-cell rows in sections, and
the body kept verbatim for the pcap.

Layouts: MobileInsight log_packet.h (Apache-2.0), restated in
docs/research/qualcomm-measurement-log-layouts.md. This module is written from
those facts, not from any other decoder's code. Every layout is from documentation;
confirm on a hardware capture before a report relies on the numbers.

Scaling (shared by all four codes):
    RSRP dBm = raw * 0.0625 - 180        RSRQ dB  = raw * 0.0625 - 30
    RSSI dBm = raw * 0.0625 - 110        FTL SNR dB = raw * 0.1 - 20
    Projected SIR dB = signed 32-bit / 16
    v35/v40 combined RSRP: 0.0625 * (raw + 640) - 180

Every decoded value passes a plausibility check (RSRP -140..-44 dBm, RSRQ -34..3 dB,
RSSI -110..0 dBm, SNR -20..30 dB, PCI 0..503, SFN 0..1023, subframe 0..9). A value
that fails is dropped, the record is marked "partial", and the note names the field:
a reader gets no number rather than a wrong one. A per-antenna value whose raw bits
are all zero is "not present" (a two-antenna modem in a four-antenna layout).

0xB193 headline `snr` is the best FTL SNR branch; the per-branch values are kept as
snr_rx0..snr_rx3. Bit fields: "skip N, then M bits" of a little-endian word means
(word >> N) & ((1 << M) - 1).

The iPhone 17 (Qualcomm M25) logs versions the documentation does not have: 0xB193
subpacket 0x19 v66 and 0xB179 v56. Those two layouts were derived and validated on
the captures of 2026-09-21/22 by this repository's TypeScript engine
(web/engine/src/phy/decoders/b193.ts and b179.ts) and are ported here field for
field; they carry a different note ("validated on the iPhone 17 ...") instead of
the documentation caveat.
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .records import DiagRecord

DOC_NOTE = "layout from documentation; confirm on a hardware capture"
HW_NOTE = "layout validated on the iPhone 17 (M25) captures of 2026-09-21/22"

SUBPACKET_SERVING_CELL_MEAS = 25       # 0x19

# --- scaling and plausibility ------------------------------------------------------

def rsrp_dbm(raw: int) -> float:
    return raw * 0.0625 - 180.0


def rsrq_db(raw: int) -> float:
    return raw * 0.0625 - 30.0


def rssi_dbm(raw: int) -> float:
    return raw * 0.0625 - 110.0


def snr_db(raw: int) -> float:
    return raw * 0.1 - 20.0


def _signed32(raw: int) -> int:
    return raw - (1 << 32) if raw & (1 << 31) else raw


def _signed16(raw: int) -> int:
    return raw - (1 << 16) if raw & (1 << 15) else raw


# kind -> (convert, (low, high)); None range = no check
_KINDS = {
    "u": (lambda x: x, None),
    "pci": (lambda x: x, (0, 503)),
    "sfn": (lambda x: x, (0, 1023)),
    "subframe": (lambda x: x, (0, 9)),
    "rsrp": (rsrp_dbm, (-140.0, -44.0)),
    "rsrp640": (lambda x: (x + 640) * 0.0625 - 180.0, (-140.0, -44.0)),
    "rsrq": (rsrq_db, (-34.0, 3.0)),
    "rssi": (rssi_dbm, (-110.0, 0.0)),
    "snr": (snr_db, (-20.0, 30.0)),
    "sir": (lambda x: _signed32(x) / 16.0, (-40.0, 60.0)),
    "cinr": (lambda x: x, None),
}

RANGES = {k: v[1] for k, v in _KINDS.items() if v[1] is not None}


def plausible(kind: str, value) -> bool:
    rng = RANGES.get(kind)
    return rng is None or value is None or rng[0] <= value <= rng[1]


# --- 0xB193 step tables --------------------------------------------------------------
#
# A step is ("skip", n) or ("w", nbytes, [(name, shift, width, kind), ...]): read an
# nbytes little-endian word and take each bit field out of it. Field names ending in
# _rx0.._rx3 are per antenna and optional (raw 0 = not present).

def _skip(n):
    return ("skip", n)


def _u(name, nbytes, kind="u"):
    return ("w", nbytes, [(name, 0, 8 * nbytes, kind)])


def _w(*fields):
    return ("w", 4, list(fields))


_PCI16 = ("w", 2, [("pci", 0, 9, "pci"), ("serving_cell_index", 9, 3, "u")])
_PCI16_SERVING = ("w", 2, [("pci", 0, 9, "pci"), ("serving_cell_index", 9, 3, "u"), ("is_serving_cell", 12, 1, "u")])
_SFN16 = ("w", 2, [("sfn", 0, 10, "sfn"), ("subframe", 10, 4, "subframe")])
_RSRP_RX0 = _w(("rsrp_rx0", 10, 12, "rsrp"))
_RSRP_RX1 = _w(("rsrp_rx1", 12, 12, "rsrp"))
_RSRP_RX2 = _w(("rsrp_rx2", 12, 12, "rsrp"))
_RSRP_12 = _w(("rsrp", 12, 12, "rsrp"))
_RSRQ_RX0_12 = _w(("rsrq_rx0", 12, 10, "rsrq"))
_RSRQ_RX1_AND_RSRQ = _w(("rsrq_rx1", 0, 10, "rsrq"), ("rsrq", 20, 10, "rsrq"))
_RSSI_RX0_RX1 = _w(("rssi_rx0", 10, 11, "rssi"), ("rssi_rx1", 21, 11, "rssi"))
_RSSI_LOW = _w(("rssi", 0, 11, "rssi"))
_SNR_RX0_RX1 = _w(("snr_rx0", 0, 9, "snr"), ("snr_rx1", 9, 9, "snr"))
_SNR_RX2_RX3 = _w(("snr_rx2", 0, 9, "snr"), ("snr_rx3", 9, 9, "snr"))
_SIR = _u("projected_sir", 4, "sir")
_POST_IC_RSRQ = _u("post_ic_rsrq", 4, "rsrq")
_CINR = [_u("cinr_rx%d_raw" % i, 4, "cinr") for i in range(4)]
# four-antenna block shared by v35 and v40, from RSRP Rx[3] to RSSI
_FOUR_RX_RSRP_RSRQ_RSSI = [
    _w(("rsrp_rx3", 0, 12, "rsrp"), ("rsrp", 12, 12, "rsrp640")),
    _w(("filtered_rsrp", 12, 12, "rsrp")),
    _w(("rsrq_rx0", 0, 10, "rsrq"), ("rsrq_rx1", 20, 10, "rsrq")),
    _w(("rsrq_rx2", 10, 10, "rsrq"), ("rsrq_rx3", 20, 10, "rsrq")),
    _w(("rsrq", 0, 10, "rsrq"), ("filtered_rsrq", 20, 12, "rsrq")),
    _w(("rssi_rx0", 0, 11, "rssi"), ("rssi_rx1", 11, 11, "rssi")),
    _w(("rssi_rx2", 0, 11, "rssi"), ("rssi_rx3", 11, 11, "rssi")),
    _RSSI_LOW,
]

_HEADER_EARFCN16 = [_u("earfcn", 2)]
_HEADER_EARFCN32 = [_u("earfcn", 4)]
_HEADER_CELLS = [_u("earfcn", 4), _u("num_cells", 2), _skip(2)]
_HEADER_CELLS_VALID_RX = [_u("earfcn", 4), _u("num_cells", 2), _u("valid_rx", 2)]

_CELL_V4_TAIL = [_RSRP_RX0, _RSRP_RX1, _RSRP_12, _RSRQ_RX0_12, _RSRQ_RX1_AND_RSRQ, _RSSI_RX0_RX1, _RSSI_LOW,
                 _skip(20), _SNR_RX0_RX1, _skip(12)]

# (header steps, cell steps, multi-cell)
SCMR_LAYOUTS = {
    4: (_HEADER_EARFCN16, [_PCI16, _SFN16, _skip(2), _skip(4)] + _CELL_V4_TAIL, False),
    7: (_HEADER_EARFCN32, [_PCI16, _skip(2), _SFN16, _skip(2), _skip(4)] + _CELL_V4_TAIL, False),
    18: (_HEADER_EARFCN32, [_PCI16, _skip(2), _SFN16, _skip(11),
                            _RSRP_RX0, _RSRP_RX1, _RSRP_12, _RSRQ_RX0_12, _RSRQ_RX1_AND_RSRQ,
                            _w(("rssi_rx0", 10, 11, "rssi"), ("rssi_rx1", 21, 11, "rssi"), ("rssi", 0, 11, "rssi")),
                            _skip(23), _SNR_RX0_RX1, _skip(20)], False),
    19: (_HEADER_CELLS, [_PCI16_SERVING, _skip(2), _SFN16, _skip(2), _skip(4), _skip(4),
                         _RSRP_RX0, _RSRP_RX1, _RSRP_12, _RSRQ_RX0_12, _RSRQ_RX1_AND_RSRQ, _RSSI_RX0_RX1, _RSSI_LOW,
                         _skip(20), _SNR_RX0_RX1, _skip(12), _SIR, _POST_IC_RSRQ], True),
    22: (_HEADER_CELLS, [_PCI16_SERVING, _skip(2), _SFN16, _skip(2), _skip(4), _skip(4),
                         _RSRP_RX0, _RSRP_RX1, _skip(4), _RSRP_12, _RSRQ_RX0_12,
                         _w(("rsrq_rx1", 0, 10, "rsrq")), _w(("rsrq", 10, 10, "rsrq")),
                         _RSSI_RX0_RX1, _skip(4), _RSSI_LOW, _skip(20), _SNR_RX0_RX1, _skip(16),
                         _SIR, _POST_IC_RSRQ, _CINR[0], _CINR[1]], True),
    24: (_HEADER_CELLS, [_PCI16_SERVING, _skip(2), _SFN16, _skip(2), _skip(4), _skip(4), _skip(1),
                         _w(("rsrp_rx0", 1, 12, "rsrp")), _w(("rsrp_rx1", 4, 12, "rsrp")), _w(("rsrp", 4, 12, "rsrp")),
                         ("w", 2, [("rsrq_rx0", 4, 10, "rsrq")]), _skip(1),
                         ("w", 2, [("rsrq_rx1", 0, 10, "rsrq")]), ("w", 2, [("rsrq", 4, 10, "rsrq")]),
                         _RSSI_RX0_RX1, _RSSI_LOW, _skip(20), _SNR_RX0_RX1, _skip(16), _skip(8)], True),
    35: (_HEADER_CELLS, [_PCI16_SERVING, _skip(2), _SFN16, _skip(2), _skip(4), _skip(4),
                         _RSRP_RX0, _RSRP_RX1, _RSRP_RX2] + _FOUR_RX_RSRP_RSRQ_RSSI +
                        [_skip(20), _SNR_RX0_RX1, _SNR_RX2_RX3, _skip(12), _SIR, _POST_IC_RSRQ] + _CINR, True),
    36: (_HEADER_CELLS, [_PCI16_SERVING, _skip(2), _SFN16, _skip(2), _skip(4), _skip(4),
                         _RSRP_RX0, _RSRP_RX1, _skip(4), _skip(4), _w(("rsrp", 0, 12, "rsrp")),
                         _w(("rsrq_rx0", 0, 10, "rsrq"), ("rsrq_rx1", 20, 10, "rsrq")), _skip(4),
                         _w(("rsrq", 0, 10, "rsrq"))], True),
    40: (_HEADER_CELLS_VALID_RX, [_PCI16_SERVING, _skip(2), _SFN16, _skip(2), _skip(4), _skip(4),
                                  _RSRP_RX0, _RSRP_RX1, _RSRP_RX2, _skip(4)] + _FOUR_RX_RSRP_RSRQ_RSSI +
                                 [_skip(10), _u("residual_freq_error", 2), _skip(8), _SNR_RX0_RX1, _SNR_RX2_RX3,
                                  _skip(12), _skip(4), _SIR, _POST_IC_RSRQ] + _CINR, True),
}

# Subpacket 0x19 v66 (iPhone 17, M25): web/engine/src/phy/decoders/b193.ts. The v40 field
# order with each 144-byte cell record starting with a u32 Rx map (bit k = Rx k measured)
# and 4 bytes before the PCI word (pci bits 0-8, carrier bits 9-11, serving bit 15); the
# measurement words sit at cell offset 24 + 4*i. The combined RSRP is stored 640 units
# (40 dB) below the per-Rx scale. There is no SNR: the projected-SIR slot of the older
# versions is not SIR on this version, so nothing is read after RSSI.
_PCI16_V66 = ("w", 2, [("pci", 0, 9, "pci"), ("serving_cell_index", 9, 3, "u"), ("is_serving_cell", 15, 1, "u")])
_CELL_V66 = [_u("rx_map", 4), _skip(4), _PCI16_V66, _skip(14),
             _RSRP_RX0, _RSRP_RX1, _RSRP_RX2, _skip(4),
             _w(("rsrp_rx3", 0, 12, "rsrp"), ("rsrp", 12, 12, "rsrp640")),
             _w(("filtered_rsrp", 12, 12, "rsrp")),
             _w(("rsrq_rx0", 0, 10, "rsrq"), ("rsrq_rx1", 20, 10, "rsrq")),
             _w(("rsrq_rx2", 10, 10, "rsrq"), ("rsrq_rx3", 20, 10, "rsrq")),
             _w(("rsrq", 0, 10, "rsrq"), ("filtered_rsrq", 20, 10, "rsrq")),
             _w(("rssi_rx0", 0, 11, "rssi"), ("rssi_rx1", 11, 11, "rssi")),
             _w(("rssi_rx2", 0, 11, "rssi"), ("rssi_rx3", 11, 11, "rssi")),
             _RSSI_LOW, _skip(72)]
SCMR_LAYOUTS[66] = (_HEADER_CELLS_VALID_RX, _CELL_V66, True)
assert sum(step[1] for step in _CELL_V66) == 144

# Versions whose layout was validated on hardware (the note says so instead of DOC_NOTE).
HW_VALIDATED_SCMR = {66}
# v66 has an Rx map per cell: a per-Rx value of an antenna the map does not cover is not
# a measurement, whatever bits the word holds.
_RX_MAPPED_VERSIONS = {66}

# v36's table ends after RSRQ; the rest of each cell is undocumented, so the cell
# stride comes from the subpacket size rather than from the table.
_OPEN_ENDED_VERSIONS = {36}


def steps_length(steps) -> int:
    return sum(step[1] for step in steps)


def _is_per_antenna(name: str) -> bool:
    return name[-4:-1] == "_rx" and name[-1].isdigit()


def run_steps(body: bytes, off: int, steps, out: dict, bad: list) -> int:
    """Apply the steps at `off`; fill `out`, list implausible field names in `bad`; return the new offset."""
    for step in steps:
        if step[0] == "skip":
            off += step[1]
            continue
        _, nbytes, fields = step
        word = int.from_bytes(body[off:off + nbytes], "little")
        off += nbytes
        for name, shift, width, kind in fields:
            raw = (word >> shift) & ((1 << width) - 1)
            if raw == 0 and _is_per_antenna(name):
                out[name] = None
                continue
            value = _KINDS[kind][0](raw)
            if not plausible(kind, value):
                bad.append("%s=%s" % (name, value if kind in ("u", "pci", "sfn", "subframe") else "%.1f" % value))
                out[name] = None
                continue
            out[name] = value
    return off


def _best_snr(row: dict):
    values = [row.get("snr_rx%d" % i) for i in range(4)]
    values = [v for v in values if v is not None]
    return max(values) if values else None


def _apply_rx_map(row: dict) -> None:
    """v66: drop the per-Rx values of antennas the cell's Rx map says were not measured,
    and count the measured ones as num_rx."""
    rx_map = row.get("rx_map") or 0
    row["num_rx"] = bin(rx_map & 0xF).count("1")
    for i in range(4):
        if not (rx_map >> i) & 1:
            for kind in ("rsrp", "rsrq", "rssi"):
                row["%s_rx%d" % (kind, i)] = None


def _record(rec: LogRecord, info, version: int, fields: dict, sections: list, decoded: str, notes: list) -> DiagRecord:
    return DiagRecord(rec.code, info.name if info else "LTE ML1", version, rec.timestamp, rec.timestamp_raw,
                      rec.body, fields=fields, sections=sections, decoded=decoded,
                      confidence=info.confidence if info else "low", note="; ".join(notes))


# --- 0xB193 LTE ML1 Serving Cell Measurement Result ------------------------------------

def decode_scell_meas(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB193: subpacket container; subpacket 0x19 carries the per-antenna and combined
    RSRP/RSRQ/RSSI/SNR of the serving cell (and, from v19, of every configured cell)."""
    body = rec.body
    if len(body) < 4:
        return None
    version, num_subpackets = body[0], body[1]
    fields = {"version": version, "num_subpackets": num_subpackets}
    notes = []
    subpackets = []
    cells = []
    decoded = "partial"
    off = 4
    for _ in range(num_subpackets):
        if off + 4 > len(body):
            if not subpackets:
                return None
            notes.append("subpacket header beyond the body")
            break
        sp_id, sp_version, sp_size = struct.unpack_from("<BBH", body, off)
        if sp_size < 4 or off + sp_size > len(body):
            if not subpackets:
                return None
            notes.append("subpacket %d size %d does not fit" % (sp_id, sp_size))
            break
        subpackets.append({"subpacket_id": sp_id, "subpacket_version": sp_version, "subpacket_size": sp_size})
        if sp_id == SUBPACKET_SERVING_CELL_MEAS and "subpacket_version" not in fields:
            fields.update({"subpacket_id": sp_id, "subpacket_version": sp_version, "subpacket_size": sp_size})
            result = _decode_scmr(body, off + 4, off + sp_size, sp_version, fields, cells, notes)
            if result is not None:
                decoded = result
        off += sp_size
    if not subpackets:
        notes.append("no subpackets")
    # The source of the layout leads the note: hardware-validated for v66, documentation otherwise.
    notes.insert(0, HW_NOTE if fields.get("subpacket_version") in HW_VALIDATED_SCMR else DOC_NOTE)
    sections = []
    if cells:
        sections.append(("cells", cells))
    sections.append(("subpackets", subpackets))
    return _record(rec, info, version, fields, sections, decoded, notes)


def _decode_scmr(body: bytes, start: int, end: int, sp_version: int, fields: dict, cells: list, notes: list):
    """Subpacket 0x19 payload [start, end): fill the headline fields and the cell rows.
    Returns "fields" / "partial", or None when the version is not implemented."""
    layout = SCMR_LAYOUTS.get(sp_version)
    if layout is None:
        notes.append("subpacket version %d not implemented" % sp_version)
        return None
    header_steps, cell_steps, multi = layout
    bad = []
    header = {}
    if start + steps_length(header_steps) > end:
        notes.append("subpacket shorter than its header")
        return None
    off = run_steps(body, start, header_steps, header, bad)
    num_cells = header.get("num_cells", 1) if multi else 1
    remaining = end - off
    cell_len = steps_length(cell_steps)
    if multi and num_cells == 0:
        notes.append("no cells in the subpacket")
        fields.update(header)
        return "partial"
    if sp_version in _OPEN_ENDED_VERSIONS:
        stride = remaining // num_cells
        if stride < cell_len:
            notes.append("cell stride %d shorter than the documented %d bytes" % (stride, cell_len))
            return None
        notes.append("v%d: %d of %d bytes per cell documented" % (sp_version, cell_len, stride))
    else:
        stride = cell_len
        if remaining < num_cells * cell_len:
            notes.append("%d cells of %d bytes do not fit in %d" % (num_cells, cell_len, remaining))
            return None
    for i in range(num_cells):
        row = {"cell": i}
        run_steps(body, off + i * stride, cell_steps, row, bad)
        if sp_version in _RX_MAPPED_VERSIONS:
            _apply_rx_map(row)
        row["snr"] = _best_snr(row)
        cells.append(row)
    # The headline is the PCell (a serving cell on carrier 0), else any serving cell, else the first.
    serving_cells = [c for c in cells if c.get("is_serving_cell") == 1]
    serving = next((c for c in serving_cells if c.get("serving_cell_index") == 0),
                   serving_cells[0] if serving_cells else cells[0])
    fields.update(header)
    for key in ("pci", "serving_cell_index", "sfn", "subframe", "rx_map", "num_rx", "rsrp", "rsrq", "rssi", "snr",
                "filtered_rsrp", "filtered_rsrq", "projected_sir", "post_ic_rsrq"):
        if key in serving:
            fields[key] = serving[key]
    fields["num_cells"] = num_cells
    if sp_version in HW_VALIDATED_SCMR:
        notes.append("v%d: no SNR field (the older versions' projected-SIR slot is not SIR here)" % sp_version)
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        return "partial"
    return "fields"


def scell_meas_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "pci" not in fields:
        return "v%d, subpacket v%s (partial)" % (fields.get("version", 0), fields.get("subpacket_version", "?"))
    parts = ["PCI %d" % fields["pci"], "EARFCN %d" % fields["earfcn"]]
    for key, label, unit in (("rsrp", "RSRP", "dBm"), ("rsrq", "RSRQ", "dB"), ("rssi", "RSSI", "dBm"), ("snr", "SNR", "dB")):
        if fields.get(key) is not None:
            parts.append("%s %.1f %s" % (label, fields[key], unit))
    return " ".join(parts)


# --- 0xB179 LTE ML1 Connected Mode Intra-Freq Meas Results ------------------------------

_INTRA_HEADER = {3: ("<HHHhhhhBB", ("earfcn", "serving_pci", "subframe_number", "rsrp_raw", "_dup1", "rsrq_raw", "_dup2",
                                    "num_neighbours", "num_detected")),
                 4: ("<IHHhhhhBBH", ("earfcn", "serving_pci", "subframe_number", "rsrp_raw", "_dup1", "rsrq_raw", "_dup2",
                                     "num_neighbours", "num_detected", "_pad"))}
_NEIGHBOUR_12 = ("<Hhhh4x", 12)
_NEIGHBOUR_10 = ("<Hhhh2x", 10)
_DETECTED = {3: "<IIQ", 4: "<H2xIQ"}

# v56 (iPhone 17, M25): web/engine/src/phy/decoders/b179.ts. Not bit packed at all:
#   u8 version @0, 3 reserved, u32 @4 not identified (0, 9, 18 or 27; not the neighbour
#   count), u32 EARFCN @8, u16 serving PCI @12, u16 TTI @14 (= SFN * 10 + subframe),
#   u16 RSRP @16 (the same value again @18), u16 RSRQ @20 (again @22), u32 neighbour
#   count @24, then 12-byte neighbours: u16 PCI @0, u16 RSRP @2 (again @4), u16 RSRQ @6
#   (again @8), u16 zero @10. The body length must equal 28 + 12 * count: a body the count
#   does not explain is not read. These records carry no DIAG timestamp; the TTI is
#   their only clock.
_INTRA_V56_VERSION = 56
_INTRA_V56_HEADER = 28
_INTRA_V56_NEIGHBOUR = 12


def decode_intra_meas(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB179: serving RSRP/RSRQ plus the intra-frequency neighbours the modem measured
    and the cells it only detected (versions 3 and 4), or the flat v56 layout of the
    iPhone 17 modem."""
    body = rec.body
    if len(body) < 8:
        return None
    version = body[0]
    if version == _INTRA_V56_VERSION:
        return _decode_intra_meas_v56(rec, info)
    serving_cell_index = body[4] & 7
    layout = _INTRA_HEADER.get(version)
    fields = {"version": version, "serving_cell_index": serving_cell_index}
    notes = [DOC_NOTE]
    if layout is None:
        notes.append("version %d not implemented" % version)
        return _record(rec, info, version, fields, [], "partial", notes)
    fmt, names = layout
    off = 8
    if len(body) < off + struct.calcsize(fmt):
        return None
    header = dict(zip(names, struct.unpack_from(fmt, body, off)))
    off += struct.calcsize(fmt)
    n_nb, n_det = header["num_neighbours"], header["num_detected"]
    det_fmt = _DETECTED[version]
    det_size = struct.calcsize(det_fmt)
    nb_fmt, nb_size = _NEIGHBOUR_12
    if off + n_nb * nb_size + n_det * det_size > len(body):
        nb_fmt, nb_size = _NEIGHBOUR_10
        if off + n_nb * nb_size + n_det * det_size == len(body):
            notes.append("10-byte neighbour records (the 12-byte layout did not fit)")
        else:
            return None
    bad = []

    def meas(prefix, raw_rsrp, raw_rsrq, out):
        for name, raw, conv, kind in (("rsrp", raw_rsrp, rsrp_dbm, "rsrp"), ("rsrq", raw_rsrq, rsrq_db, "rsrq")):
            value = conv(raw)
            if plausible(kind, value):
                out[name] = value
            else:
                out[name] = None
                bad.append("%s%s=%.1f" % (prefix, name, value))

    fields.update({"earfcn": header["earfcn"], "pci": header["serving_pci"],
                   "subframe_number": header["subframe_number"]})
    meas("", header["rsrp_raw"], header["rsrq_raw"], fields)
    if not plausible("pci", fields["pci"]):
        bad.append("pci=%d" % fields["pci"])
        fields["pci"] = None
    fields["num_neighbours"] = n_nb
    fields["num_detected"] = n_det
    neighbours = []
    for i in range(n_nb):
        pci, raw_rsrp, _dup, raw_rsrq = struct.unpack_from(nb_fmt, body, off)
        off += nb_size
        row = {"pci": pci if plausible("pci", pci) else None}
        if row["pci"] is None:
            bad.append("neighbour%d.pci=%d" % (i, pci))
        meas("neighbour%d." % i, raw_rsrp, raw_rsrq, row)
        neighbours.append(row)
    detected = []
    for i in range(n_det):
        pci, sss_corr, ref_time = struct.unpack_from(det_fmt, body, off)
        off += det_size
        detected.append({"pci": pci, "sss_corr": sss_corr, "reference_time": ref_time})
    sections = [("neighbours", neighbours), ("detected", detected)]
    decoded = "fields"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        decoded = "partial"
    return _record(rec, info, version, fields, sections, decoded, notes)


def _decode_intra_meas_v56(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    body = rec.body
    if len(body) < _INTRA_V56_HEADER:
        return None
    n_nb = struct.unpack_from("<I", body, 24)[0]
    if len(body) != _INTRA_V56_HEADER + _INTRA_V56_NEIGHBOUR * n_nb:
        return None
    unidentified, earfcn, pci, tti, rsrp_raw, _dup1, rsrq_raw, _dup2 = struct.unpack_from("<IIHHHHHH", body, 4)
    fields = {"version": _INTRA_V56_VERSION, "unidentified_word": unidentified, "earfcn": earfcn,
              "tti": tti, "sfn": tti // 10, "subframe": tti % 10}
    notes = [HW_NOTE, "no DIAG timestamp on this version; the TTI is the record's clock"]
    bad = []

    def meas(prefix, raw_rsrp, raw_rsrq, out):
        for name, raw, conv, kind in (("rsrp", raw_rsrp, rsrp_dbm, "rsrp"), ("rsrq", raw_rsrq, rsrq_db, "rsrq")):
            value = conv(raw)
            if plausible(kind, value):
                out[name] = value
            else:
                out[name] = None
                bad.append("%s%s=%.1f" % (prefix, name, value))

    fields["pci"] = pci if plausible("pci", pci) else None
    if fields["pci"] is None:
        bad.append("pci=%d" % pci)
    meas("", rsrp_raw, rsrq_raw, fields)
    if fields["sfn"] > 1023:
        bad.append("tti=%d" % tti)
        fields["sfn"] = fields["subframe"] = None
    fields["num_neighbours"] = n_nb
    neighbours = []
    for i in range(n_nb):
        o = _INTRA_V56_HEADER + _INTRA_V56_NEIGHBOUR * i
        n_pci, n_rsrp, _d1, n_rsrq = struct.unpack_from("<HHHH", body, o)
        row = {"pci": n_pci if plausible("pci", n_pci) else None}
        if row["pci"] is None:
            bad.append("neighbour%d.pci=%d" % (i, n_pci))
        meas("neighbour%d." % i, n_rsrp, n_rsrq, row)
        neighbours.append(row)
    decoded = "fields"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        decoded = "partial"
    return _record(rec, info, _INTRA_V56_VERSION, fields, [("neighbours", neighbours), ("detected", [])], decoded, notes)


def intra_meas_summary(fields: dict) -> str:
    if "earfcn" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    parts = ["PCI %s" % _na(fields.get("pci")), "EARFCN %d" % fields["earfcn"]]
    if fields.get("rsrp") is not None:
        parts.append("RSRP %.1f dBm" % fields["rsrp"])
    if fields.get("rsrq") is not None:
        parts.append("RSRQ %.1f dB" % fields["rsrq"])
    parts.append("%d neighbours" % fields["num_neighbours"])
    return " ".join(parts)


def _na(value) -> str:
    return "n/a" if value is None else str(value)


# --- 0xB17F LTE ML1 Serving Cell Meas and Eval (header only, single-sourced) --------------

# version -> (offset of rrc_release, earfcn fmt/offset, pci-word offset, first measurement word offset, body length)
_EVAL_LAYOUT = {4: ("<H", 2, 4, 8, 32), 5: ("<I", 4, 8, 12, 36)}


def decode_scell_eval(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB17F: version, RRC release, EARFCN, PCI and layer priority, and the measured and
    averaged RSRP/RSRQ/RSSI when they are plausible. The reselection criteria that follow
    are bit-packed from a single source and are left undecoded; always "partial"."""
    body = rec.body
    if len(body) < 2:
        return None
    version = body[0]
    fields = {"version": version, "rrc_release": body[1]}
    notes = [DOC_NOTE, "single-sourced layout: header fields only"]
    layout = _EVAL_LAYOUT.get(version)
    if layout is None:
        notes.append("version %d not documented" % version)
        return _record(rec, info, version, fields, [], "partial", notes)
    earfcn_fmt, earfcn_off, pci_off, meas_off, length = layout
    if len(body) < length:
        return None
    fields["earfcn"] = struct.unpack_from(earfcn_fmt, body, earfcn_off)[0]
    pci_word = struct.unpack_from("<H", body, pci_off)[0]
    pci = pci_word & 0x1FF
    fields["pci"] = pci if plausible("pci", pci) else None
    fields["serving_layer_priority"] = pci_word >> 9
    w = struct.unpack_from("<IIII", body, meas_off)
    candidates = {
        "rsrp": (rsrp_dbm(w[0] & 0xFFF), "rsrp"),
        "rsrp_avg": (rsrp_dbm(w[1] & 0xFFF), "rsrp"),
        "rsrq": (rsrq_db(w[2] & 0x3FF), "rsrq"),
        "rsrq_avg": (rsrq_db((w[2] >> 20) & 0x3FF), "rsrq"),
        "rssi": (rssi_dbm((w[3] >> 10) & 0x7FF), "rssi"),
    }
    bad = [name for name, (value, kind) in candidates.items() if not plausible(kind, value)]
    if bad:
        notes.append("measurement words implausible (%s); not reported" % ", ".join(bad))
    else:
        for name, (value, _kind) in candidates.items():
            fields[name] = value
    if fields["pci"] is None:
        notes.append("implausible: pci=%d" % pci)
    return _record(rec, info, version, fields, [], "partial", notes)


def scell_eval_summary(fields: dict) -> str:
    parts = ["v%d" % fields.get("version", 0)]
    if "earfcn" in fields:
        parts += ["PCI %s" % _na(fields.get("pci")), "EARFCN %d" % fields["earfcn"]]
    if fields.get("rsrp") is not None:
        parts.append("RSRP %.1f dBm" % fields["rsrp"])
    parts.append("(partial)")
    return " ".join(parts)


# --- 0xB180 LTE ML1 Idle Neighbor Meas Results (header only, single-sourced) -------------

_NCELL_LAYOUT = {4: ("<H", 2, "<H", 6, 8), 5: ("<I", 4, "<I", 8, 12)}    # earfcn fmt/off, packed fmt/off, header len
_NCELL_RECORD_SIZES = (32, 36)


def decode_ncell_meas(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB180: version, RRC release and EARFCN; the cell count only when one reading of
    the packed count word makes the per-cell records fit the body. Per-cell fields are
    bit-packed from a single source and are left undecoded; always "partial"."""
    body = rec.body
    if len(body) < 2:
        return None
    version = body[0]
    fields = {"version": version, "rrc_release": body[1]}
    notes = [DOC_NOTE, "single-sourced layout: header fields only"]
    layout = _NCELL_LAYOUT.get(version)
    if layout is None:
        notes.append("version %d not documented" % version)
        return _record(rec, info, version, fields, [], "partial", notes)
    earfcn_fmt, earfcn_off, packed_fmt, packed_off, header_len = layout
    if len(body) < header_len:
        return None
    fields["earfcn"] = struct.unpack_from(earfcn_fmt, body, earfcn_off)[0]
    packed = struct.unpack_from(packed_fmt, body, packed_off)[0]
    remaining = len(body) - header_len
    fits = set()
    for reading, count in (("low 10 bits", packed & 0x3FF), ("bits 6..15", (packed >> 6) & 0x3FF)):
        if count and any(remaining == count * size for size in _NCELL_RECORD_SIZES):
            fits.add((reading, count))
    if len({count for _r, count in fits}) == 1:
        reading, count = fits.pop()
        fields["num_cells"] = count
        notes.append("cell count from the %s of the packed word (%d bytes per cell fit)" % (reading, remaining // count))
    else:
        notes.append("cell count not determined")
    return _record(rec, info, version, fields, [], "partial", notes)


def ncell_meas_summary(fields: dict) -> str:
    parts = ["v%d" % fields.get("version", 0)]
    if "earfcn" in fields:
        parts.append("EARFCN %d" % fields["earfcn"])
    if "num_cells" in fields:
        parts.append("%d cells" % fields["num_cells"])
    parts.append("(partial)")
    return " ".join(parts)


DECODERS = {
    "lte_ml1_scell_meas": decode_scell_meas,
    "lte_ml1_intra_meas": decode_intra_meas,
    "lte_ml1_scell_eval": decode_scell_eval,
    "lte_ml1_ncell_meas": decode_ncell_meas,
}
