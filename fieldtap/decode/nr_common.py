"""What the NR record decoders share: the version pair, the Q7 fixed point,
and the plausibility ranges every decoded value is held to.

NR log records (0xB8xx / 0xB9xx) start with a Minor Version u16 and a Major
Version u16; "2.7" in the documentation is major 2, minor 7. The DiagRecord
keeps the pair as the little-endian u32 it is on the wire (what the Lua
plugin shows as the packet version) and as "major.minor" in fields["version"].

Layout facts: MobileInsight (Apache License 2.0) and
docs/research/qualcomm-measurement-log-layouts.md, which restates some layouts
read from GPL sources as facts only. Nothing here is copied from any of them.
"""

from __future__ import annotations

import struct
from typing import Optional, Tuple

from .records import DiagRecord

DOC_NOTE = "layout from documentation; confirm on a hardware capture"

# The ranges a decoded value must sit in: TS 38.133 reporting ranges for the
# measurements, TS 38.331 / 38.104 for the identities.
RANGES = {
    "rsrp": (-156.0, -31.0),     # SS-RSRP dBm
    "rsrq": (-43.0, 20.0),       # SS-RSRQ dB
    "sinr": (-23.0, 40.0),       # SS-SINR dB
    "pci": (0, 1007),
    "arfcn": (0, 3279165),       # NR-ARFCN
    "tac": (0, 0xFFFFFF),
    "sfn": (0, 1023),
    "band": (1, 1024),
    "scs_khz": (15, 120),
    "numerology": (0, 4),
    "slot": (0, 159),
    "ssb_index": (0, 63),
    "harq_id": (0, 15),
    "tb_bytes": (0, 1 << 20),    # one NR transport block is below a megabyte
}


def read_version(body: bytes) -> Optional[Tuple[int, int, int]]:
    """-> (major, minor, raw_u32) from the first four bytes, or None when short."""
    if len(body) < 4:
        return None
    minor, major = struct.unpack_from("<HH", body, 0)
    return major, minor, struct.unpack_from("<I", body, 0)[0]


def version_label(major: int, minor: int) -> str:
    return "%d.%d" % (major, minor)


def nr_q7(raw: int) -> Optional[float]:
    """The NR ML1 fixed point of major.minor 2.7 and later: bits 7..14 hold the
    integer part offset by 256, bits 0..6 the fraction in 1/128 dB. Raw 0 is
    "not available". Both open decoders land on this formula."""
    if raw == 0:
        return None
    integer = (raw >> 7) & 0xFF
    frac = raw & 0x7F
    return (integer - 256) + frac * 0.0078125


def in_range(kind: str, value) -> bool:
    if value is None:
        return True
    lo, hi = RANGES[kind]
    return lo <= value <= hi


def check_fields(fields: dict, kinds: dict) -> list:
    """Replace every implausible value in `fields` by None and return the names
    that failed. `kinds` maps field name -> RANGES key."""
    bad = []
    for name, kind in kinds.items():
        if name in fields and not in_range(kind, fields[name]):
            fields[name] = None
            bad.append(name)
    return bad


def check_rows(rows: list, kinds: dict, label: str) -> list:
    """check_fields over every row of a section; failures are reported as
    "<label>[i].<field>"."""
    bad = []
    for i, row in enumerate(rows):
        for name in check_fields(row, kinds):
            bad.append("%s[%d].%s" % (label, i, name))
    return bad


def implausible_note(bad: list) -> str:
    return "implausible: %s" % ", ".join(bad)


def diag_record(rec, info, name: str, version: int, fields: dict, sections: list,
                decoded: str, notes: list) -> DiagRecord:
    return DiagRecord(rec.code, info.name if info else name, version, rec.timestamp, rec.timestamp_raw,
                      rec.body, fields=fields, sections=sections, decoded=decoded,
                      confidence=info.confidence if info else "low",
                      note="; ".join(n for n in notes if n))
