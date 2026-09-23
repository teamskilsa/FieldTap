"""NR cell identity records: 0xB822 NR RRC MIB Info and 0xB823 NR RRC Serving
Cell Info. Not OTA messages; they feed the session sidecar (cells.csv) and the
KPI export, the way 0xB0C1 / 0xB0C2 do for LTE.

Layout facts: docs/research/qualcomm-measurement-log-layouts.md, sections
"0xB822" and "0xB823" (single-sourced there, restated from a GPL parser as
facts only; no code was read or copied). Both records start with the Minor u16
and Major u16 version pair. The layout is chosen by the version table and
confirmed against the record length, the way decode/layout.resolve_header does
for the RRC headers; a length that fits no layout is left raw.

Layout from documentation; confirm on a hardware capture (the OnePlus 10 Pro
records described in android/diag/src/test/resources/oneplus-5g-registration.md
are the check: PCI 417, NR-ARFCN 647328, PLMN 311-480, TAC 360102, band n77).
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .nr_common import DOC_NOTE, check_fields, diag_record, implausible_note, read_version, version_label
from .records import CellInfo

SCS_KHZ = {0: 15, 1: 30, 2: 60, 3: 120}
NR_CHANNEL_BANDWIDTHS_MHZ = (5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100, 200, 400)
VERSION_OFFSET = 4


def _fit(body: bytes, table: dict, sizes: dict, version: tuple):
    """-> (layout key, source, trailing bytes) for the layout whose size fits the
    body after the version word: the version table's layout first, exact-size
    probing of the others next; a table layout with trailing bytes last."""
    payload = len(body) - VERSION_OFFSET
    preferred = table.get(version)
    if preferred is not None and sizes[preferred] == payload:
        return preferred, "table", 0
    for key, size in sizes.items():
        if key != preferred and size == payload:
            return key, "probed", 0
    if preferred is not None and sizes[preferred] < payload:
        return preferred, "table", payload - sizes[preferred]
    return None


# --- 0xB822 NR RRC MIB Info ------------------------------------------------------------------

# Minor u16, Major u16, PCI u16, NR-ARFCN u32, then a bit string read MSB-first:
# SFN in bits 0..9 of both layouts, SCS in bits 30..31 (four bytes, major.minor
# 0.3) or bits 31..32 (five bytes, 2.0).
MIB_TABLE = {(0, 3): "bits4", (2, 0): "bits5"}
MIB_SIZES = {"bits4": 2 + 4 + 4, "bits5": 2 + 4 + 5}


def _mib_bits(bits: bytes, layout: str):
    sfn = (bits[0] << 2) | (bits[1] >> 6)
    if layout == "bits4":
        scs = bits[3] & 0x3
    else:
        scs = ((bits[3] & 0x1) << 1) | (bits[4] >> 7)
    return sfn, scs


def decode_mib(rec: LogRecord, info=None):
    """0xB822 -> CellInfo(kind="mib"), or a partial DiagRecord when a value is implausible."""
    body = rec.body
    ver = read_version(body)
    if ver is None:
        return None
    major, minor, raw_version = ver
    fit = _fit(body, MIB_TABLE, MIB_SIZES, (major, minor))
    if fit is None:
        return None
    layout, source, trailing = fit
    pci, arfcn = struct.unpack_from("<HI", body, VERSION_OFFSET)
    bits = body[VERSION_OFFSET + 6: VERSION_OFFSET + MIB_SIZES[layout]]
    sfn, scs = _mib_bits(bits, layout)
    fields = {
        "version": version_label(major, minor), "pci": pci, "earfcn": arfcn, "sfn": sfn,
        "scs": scs, "scs_khz": SCS_KHZ[scs], "layout": layout, "layout_source": source,
    }
    bad = check_fields(fields, {"pci": "pci", "earfcn": "arfcn", "sfn": "sfn"})
    notes = [DOC_NOTE]
    if trailing:
        notes.append("%d trailing bytes not decoded" % trailing)
    if bad:
        return diag_record(rec, info, "NR RRC MIB Info", raw_version, fields, [], "partial",
                           [implausible_note(bad)] + notes)
    fields["plausible"] = True
    fields["layout_note"] = "; ".join(notes)
    return CellInfo(rat="nr", kind="mib", timestamp=rec.timestamp, log_code=rec.code,
                    version=raw_version, fields=fields)


# --- 0xB823 NR RRC Serving Cell Info -------------------------------------------------------

# After the version pair: PCI u16, [NR-CGI u64 from 3.0], DL NR-ARFCN u32, UL NR-ARFCN u32,
# DL BW u16, UL BW u16, Cell ID u64 (NCI, 36 bits), MCC u16, MNC digit count u8, MNC u16,
# Allowed Access u8, TAC u32, Band u16. 3.2 and 3.3 put three unread bytes before the PCI.
_TAIL = "IIHHQHBHBIH"
_TAIL_NAMES = ("dl_earfcn", "ul_earfcn", "dl_bw", "ul_bw", "cell_id", "mcc", "mnc_digits", "mnc",
               "allowed_access", "tac", "band")
SCELL_LAYOUTS = {
    "v0": ("<H" + _TAIL, ("pci",) + _TAIL_NAMES),
    "v3": ("<HQ" + _TAIL, ("pci", "nr_cgi") + _TAIL_NAMES),
    "v3p": ("<3sHQ" + _TAIL, ("prefix", "pci", "nr_cgi") + _TAIL_NAMES),
}
SCELL_TABLE = {(0, 4): "v0", (3, 0): "v3", (3, 2): "v3p", (3, 3): "v3p"}
SCELL_SIZES = {key: struct.calcsize(fmt) for key, (fmt, _names) in SCELL_LAYOUTS.items()}


def _plmn(mcc: int, mnc_digits: int, mnc: int) -> str:
    return "%03d%0*d" % (mcc, 3 if mnc_digits == 3 else 2, mnc)


def _bw_mhz(raw: int) -> Optional[int]:
    """The bandwidth field's unit is documented as "MHz-ish, not confirmed": only a value
    that is an NR channel bandwidth is reported as MHz."""
    return raw if raw in NR_CHANNEL_BANDWIDTHS_MHZ else None


def decode_serving_cell(rec: LogRecord, info=None):
    """0xB823 -> CellInfo(kind="serving_cell"), or a partial DiagRecord when a value is implausible."""
    body = rec.body
    ver = read_version(body)
    if ver is None:
        return None
    major, minor, raw_version = ver
    fit = _fit(body, SCELL_TABLE, SCELL_SIZES, (major, minor))
    if fit is None:
        return None
    layout, source, trailing = fit
    fmt, names = SCELL_LAYOUTS[layout]
    f = dict(zip(names, struct.unpack_from(fmt, body, VERSION_OFFSET)))
    f.pop("prefix", None)
    fields = {"version": version_label(major, minor)}
    fields.update(f)
    fields["plmn"] = _plmn(f["mcc"], f["mnc_digits"], f["mnc"])
    fields["dl_bw_mhz"] = _bw_mhz(f["dl_bw"])
    fields["ul_bw_mhz"] = _bw_mhz(f["ul_bw"])
    fields["layout"] = layout
    fields["layout_source"] = source
    bad = check_fields(fields, {"pci": "pci", "dl_earfcn": "arfcn", "ul_earfcn": "arfcn", "tac": "tac",
                                "band": "band"})
    if not (200 <= f["mcc"] <= 999 or f["mcc"] == 1):
        bad.append("mcc")
    if f["mnc_digits"] not in (2, 3) or f["mnc"] > 999:
        bad.append("mnc")
    if f["cell_id"] >= 1 << 36:
        bad.append("cell_id")
    notes = [DOC_NOTE]
    if trailing:
        notes.append("%d trailing bytes not decoded" % trailing)
    if bad:
        for name in ("plmn", "mcc", "mnc", "cell_id"):
            if name in bad or (name == "plmn" and ("mcc" in bad or "mnc" in bad)):
                fields[name] = None
        return diag_record(rec, info, "NR RRC Serving Cell Info", raw_version, fields, [], "partial",
                           [implausible_note(sorted(set(bad)))] + notes)
    fields["plausible"] = True
    fields["layout_note"] = "; ".join(notes)
    return CellInfo(rat="nr", kind="serving_cell", timestamp=rec.timestamp, log_code=rec.code,
                    version=raw_version, fields=fields)


DECODERS = {"nr_mib": decode_mib, "nr_serving_cell": decode_serving_cell}
