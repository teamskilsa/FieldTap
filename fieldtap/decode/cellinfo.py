"""Serving-cell identity records. These are not OTA messages; they feed the
session sidecar and the KPI export."""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .records import CellInfo

LTE_BANDWIDTHS = {0: 1.4, 1: 3.0, 2: 5.0, 3: 10.0, 4: 15.0, 5: 20.0}


def _plausible_lte(f: dict) -> bool:
    return 0 <= f["pci"] <= 503 and 1 <= f["band"] <= 256 and (100 <= f["mcc"] <= 999 or f["mcc"] == 0)


def decode_serving_cell(rec: LogRecord, info=None) -> Optional[CellInfo]:
    """0xB0C2 LTE RRC Serving Cell Info."""
    body = rec.body
    if not body:
        return None
    version = body[0]
    names = ("pci", "dl_earfcn", "ul_earfcn", "dl_bw", "ul_bw", "cell_id", "tac",
             "band", "mcc", "mnc_digits", "mnc", "allowed_access")
    fmt = {2: "<HHHBBIHIHBHB", 3: "<HIIBBIHIHBHB"}.get(version)
    if fmt is None:
        # Unknown version: the 32-bit EARFCN layout is what every modern modem uses.
        fmt = "<HIIBBIHIHBHB"
    if len(body) < 1 + struct.calcsize(fmt):
        return None
    f = dict(zip(names, struct.unpack_from(fmt, body, 1)))
    f["version"] = version
    f["dl_bw_mhz"] = LTE_BANDWIDTHS.get(f["dl_bw"])
    f["ul_bw_mhz"] = LTE_BANDWIDTHS.get(f["ul_bw"])
    f["plmn"] = "%03d%0*d" % (f["mcc"], 3 if f["mnc_digits"] == 3 else 2, f["mnc"])
    f["enb_id"] = f["cell_id"] >> 8
    f["sector"] = f["cell_id"] & 0xFF
    f["plausible"] = _plausible_lte(f)
    return CellInfo(rat="lte", kind="serving_cell", timestamp=rec.timestamp, log_code=rec.code,
                    version=version, fields=f)


# The DL bandwidth byte is a code (0..5) in the layouts FieldTap has seen; some firmware
# writes the PRB count instead. The two ranges do not overlap, so both are read.
LTE_PRB_TO_MHZ = {6: 1.4, 15: 3.0, 25: 5.0, 50: 10.0, 75: 15.0, 100: 20.0}

# 0xB0C1 layouts by version: MobileInsight log_packet.h (Apache-2.0) and
# docs/research/qualcomm-measurement-log-layouts.md agree on 1, 2 and 17; 3 is 2 plus a byte.
_MIB_LAYOUTS = {
    1: ("<HHHBB", ("pci", "earfcn", "sfn", "num_tx_antennas", "dl_bw")),
    2: ("<HIHBB", ("pci", "earfcn", "sfn", "num_tx_antennas", "dl_bw")),
    3: ("<HIHBBB", ("pci", "earfcn", "sfn", "num_tx_antennas", "dl_bw", "sib1_br_sch_info")),
    17: ("<HIHBBBBBBHB", ("pci", "earfcn", "sfn", "sfn_msb4", "hsfn_lsb2", "sib1_sch_info", "sys_info_value_tag",
                          "access_barring_enabled", "op_mode_type", "raster_offset", "num_tx_antennas")),
}
MIB_OP_MODE = {0: "inband-DifferentPCI", 1: "inband-SamePCI", 2: "guardband", 3: "standalone"}
MIB_RASTER_OFFSET = {0: "-7.5 kHz", 1: "-2.5 kHz", 2: "+2.5 kHz", 3: "+7.5 kHz"}


def decode_mib(rec: LogRecord, info=None) -> Optional[CellInfo]:
    """0xB0C1 LTE RRC MIB Message Log Packet, versions 1, 2, 3 and 17."""
    body = rec.body
    if not body:
        return None
    version = body[0]
    fmt, names = _MIB_LAYOUTS.get(version, (None, None))
    layout = "table"
    if fmt is None:
        # Unknown version: the v2 layout is what every modern modem has led with.
        fmt, names = _MIB_LAYOUTS[2]
        layout = "assumed v2"
    if len(body) < 1 + struct.calcsize(fmt):
        return None
    f = dict(zip(names, struct.unpack_from(fmt, body, 1)))
    f["version"] = version
    if layout != "table":
        f["layout"] = layout
    if "dl_bw" in f:
        if f["dl_bw"] in LTE_BANDWIDTHS:
            f["dl_bw_mhz"] = LTE_BANDWIDTHS[f["dl_bw"]]
            f["dl_bw_reading"] = "code"
        elif f["dl_bw"] in LTE_PRB_TO_MHZ:
            f["dl_bw_mhz"] = LTE_PRB_TO_MHZ[f["dl_bw"]]
            f["dl_bw_reading"] = "prb"
        else:
            f["dl_bw_mhz"] = None
            f["dl_bw_reading"] = "unknown"
    if version == 17:
        f["op_mode"] = MIB_OP_MODE.get(f["op_mode_type"], "unknown")
        f["raster_offset_khz"] = MIB_RASTER_OFFSET.get(f["raster_offset"], "unknown")
    f["plausible"] = 0 <= f["pci"] <= 503 and f["sfn"] < 1024
    return CellInfo(rat="lte", kind="mib", timestamp=rec.timestamp, log_code=rec.code,
                    version=version, fields=f)
