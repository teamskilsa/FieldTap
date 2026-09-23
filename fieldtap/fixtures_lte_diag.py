"""Synthetic LTE diag measurement / MAC / PHY record bodies for the test-suite.

Each builder packs one documented layout explicitly - struct formats and literal
bit shifts written from docs/research/qualcomm-measurement-log-layouts.md, not from
the decoder's tables - so a wrong shift on either side shows up as a failure. Bits
and bytes the layout does not define are filled with a pattern (FILL), never zero:
a decoder that reads the wrong bits gets nonsense, not a plausible number.

Values are realistic: a serving cell at about -95 dBm, neighbours a few dB weaker.
What these cannot prove is that the layouts match real modems (docs/CORPUS.md).

The builders after "iPhone 17 layouts" pack the record versions the iPhone 17 (M25)
modem logs, as web/engine/src/phy/decoders/*.ts describe them; those layouts were
validated on the real captures, and tests/test_decode_real_iphone.py replays one when
FT_REAL_QMDL points at it.
"""

from __future__ import annotations

import struct

FILL = 0xEE                      # filler byte for undocumented bytes
SUBPACKET_SCMR = 25              # 0xB193 subpacket 0x19

# --- raw <- engineering units ------------------------------------------------------------

def rsrp_raw(dbm: float) -> int:
    return int(round((dbm + 180) / 0.0625))


def rsrp640_raw(dbm: float) -> int:
    return int(round((dbm + 180) / 0.0625)) - 640


def rsrq_raw(db: float) -> int:
    return int(round((db + 30) / 0.0625))


def rssi_raw(dbm: float) -> int:
    return int(round((dbm + 110) / 0.0625))


def snr_raw(db: float) -> int:
    return int(round((db + 20) / 0.1))


def sir_raw(db: float) -> int:
    return int(round(db * 16)) & 0xFFFFFFFF


def _fill(n: int) -> bytes:
    return bytes([FILL]) * n


def _word(nbytes: int, *fields) -> bytes:
    """Little-endian word from (value, shift, width) fields; undefined bits set to 1."""
    total = 8 * nbytes
    used = 0
    word = 0
    for value, shift, width in fields:
        mask = (1 << width) - 1
        assert 0 <= value <= mask, (value, width)
        word |= value << shift
        used |= mask << shift
    word |= ((1 << total) - 1) & ~used
    return word.to_bytes(nbytes, "little")


# --- 0xB193 LTE ML1 Serving Cell Measurement Result ------------------------------------------

SERVING_CELL = {
    "pci": 101, "serving_cell_index": 0, "is_serving": 1, "sfn": 512, "subframe": 3,
    "rsrp_rx": [-96.0, -94.5, -97.0, -98.5], "rsrp": -95.0, "filtered_rsrp": -95.5,
    "rsrq_rx": [-11.0, -10.0, -11.5, -12.0], "rsrq": -10.5, "filtered_rsrq": -10.75,
    "rssi_rx": [-66.0, -65.0, -67.0, -68.0], "rssi": -65.5,
    "snr_rx": [12.3, 14.1, 10.0, 9.5], "projected_sir": 8.5, "post_ic_rsrq": -9.5,
    "cinr": [1200, 1300, 1100, 1000], "residual_freq_error": 37,
}
NEIGHBOUR_CELL = dict(SERVING_CELL, pci=245, serving_cell_index=1, is_serving=0,
                      rsrp_rx=[-104.0, -103.0, -105.0, -106.0], rsrp=-103.5, filtered_rsrp=-104.0,
                      rsrq_rx=[-14.0, -13.0, -15.0, -15.5], rsrq=-13.5, filtered_rsrq=-13.75,
                      rssi_rx=[-70.0, -69.0, -71.0, -72.0], rssi=-69.5,
                      snr_rx=[4.2, 5.1, 3.0, 2.5], projected_sir=1.25, post_ic_rsrq=-12.5)


def _opt(values, i, conv):
    """Per-antenna raw value; None means "not present" (raw 0)."""
    v = values[i] if i < len(values) else None
    return 0 if v is None else conv(v)


def _pci_word(c, serving_bit: bool) -> bytes:
    fields = [(c["pci"], 0, 9), (c["serving_cell_index"], 9, 3)]
    if serving_bit:
        fields.append((c["is_serving"], 12, 1))
    return _word(2, *fields)


def _sfn_word(c) -> bytes:
    return _word(2, (c["sfn"], 0, 10), (c["subframe"], 10, 4))


def _two_rx_block(c) -> bytes:
    """RSRP Rx0, Rx1, RSRP, RSRQ Rx0, RSRQ Rx1+RSRQ, RSSI Rx0+Rx1, RSSI (v4/v7/v19 shape)."""
    return (_word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 10, 12))
            + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 12, 12))
            + _word(4, (rsrp_raw(c["rsrp"]), 12, 12))
            + _word(4, (_opt(c["rsrq_rx"], 0, rsrq_raw), 12, 10))
            + _word(4, (_opt(c["rsrq_rx"], 1, rsrq_raw), 0, 10), (rsrq_raw(c["rsrq"]), 20, 10))
            + _word(4, (_opt(c["rssi_rx"], 0, rssi_raw), 10, 11), (_opt(c["rssi_rx"], 1, rssi_raw), 21, 11))
            + _word(4, (rssi_raw(c["rssi"]), 0, 11)))


def _snr_word(c, first: int) -> bytes:
    return _word(4, (_opt(c["snr_rx"], first, snr_raw), 0, 9), (_opt(c["snr_rx"], first + 1, snr_raw), 9, 9))


def _sir_post_ic(c) -> bytes:
    return struct.pack("<I", sir_raw(c["projected_sir"])) + struct.pack("<I", rsrq_raw(c["post_ic_rsrq"]))


def _cinr(c, n: int) -> bytes:
    return b"".join(struct.pack("<I", c["cinr"][i]) for i in range(n))


def _four_rx_block(c) -> bytes:
    """RSRP Rx3+RSRP(640), filtered RSRP, three RSRQ words, three RSSI words (v35/v40 shape)."""
    return (_word(4, (_opt(c["rsrp_rx"], 3, rsrp_raw), 0, 12), (rsrp640_raw(c["rsrp"]), 12, 12))
            + _word(4, (rsrp_raw(c["filtered_rsrp"]), 12, 12))
            + _word(4, (_opt(c["rsrq_rx"], 0, rsrq_raw), 0, 10), (_opt(c["rsrq_rx"], 1, rsrq_raw), 20, 10))
            + _word(4, (_opt(c["rsrq_rx"], 2, rsrq_raw), 10, 10), (_opt(c["rsrq_rx"], 3, rsrq_raw), 20, 10))
            + _word(4, (rsrq_raw(c["rsrq"]), 0, 10), (rsrq_raw(c["filtered_rsrq"]), 20, 12))
            + _word(4, (_opt(c["rssi_rx"], 0, rssi_raw), 0, 11), (_opt(c["rssi_rx"], 1, rssi_raw), 11, 11))
            + _word(4, (_opt(c["rssi_rx"], 2, rssi_raw), 0, 11), (_opt(c["rssi_rx"], 3, rssi_raw), 11, 11))
            + _word(4, (rssi_raw(c["rssi"]), 0, 11)))


def _scmr_v4_cell(c) -> bytes:
    return (_pci_word(c, False) + _sfn_word(c) + _fill(2) + _fill(4) + _two_rx_block(c)
            + _fill(20) + _snr_word(c, 0) + _fill(12))


def _scmr_v7_cell(c) -> bytes:
    return (_pci_word(c, False) + _fill(2) + _sfn_word(c) + _fill(2) + _fill(4) + _two_rx_block(c)
            + _fill(20) + _snr_word(c, 0) + _fill(12))


def _scmr_v18_cell(c) -> bytes:
    return (_pci_word(c, False) + _fill(2) + _sfn_word(c) + _fill(11)
            + _word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 10, 12))
            + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 12, 12))
            + _word(4, (rsrp_raw(c["rsrp"]), 12, 12))
            + _word(4, (_opt(c["rsrq_rx"], 0, rsrq_raw), 12, 10))
            + _word(4, (_opt(c["rsrq_rx"], 1, rsrq_raw), 0, 10), (rsrq_raw(c["rsrq"]), 20, 10))
            + _word(4, (rssi_raw(c["rssi"]), 0, 11), (_opt(c["rssi_rx"], 0, rssi_raw), 10, 11),
                    (_opt(c["rssi_rx"], 1, rssi_raw), 21, 11))
            + _fill(23) + _snr_word(c, 0) + _fill(20))


def _scmr_v19_cell(c) -> bytes:
    return (_pci_word(c, True) + _fill(2) + _sfn_word(c) + _fill(2) + _fill(4) + _fill(4) + _two_rx_block(c)
            + _fill(20) + _snr_word(c, 0) + _fill(12) + _sir_post_ic(c))


def _scmr_v22_cell(c) -> bytes:
    return (_pci_word(c, True) + _fill(2) + _sfn_word(c) + _fill(2) + _fill(4) + _fill(4)
            + _word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 10, 12))
            + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 12, 12))
            + _fill(4)
            + _word(4, (rsrp_raw(c["rsrp"]), 12, 12))
            + _word(4, (_opt(c["rsrq_rx"], 0, rsrq_raw), 12, 10))
            + _word(4, (_opt(c["rsrq_rx"], 1, rsrq_raw), 0, 10))
            + _word(4, (rsrq_raw(c["rsrq"]), 10, 10))
            + _word(4, (_opt(c["rssi_rx"], 0, rssi_raw), 10, 11), (_opt(c["rssi_rx"], 1, rssi_raw), 21, 11))
            + _fill(4)
            + _word(4, (rssi_raw(c["rssi"]), 0, 11))
            + _fill(20) + _snr_word(c, 0) + _fill(16) + _sir_post_ic(c) + _cinr(c, 2))


def _scmr_v24_cell(c) -> bytes:
    return (_pci_word(c, True) + _fill(2) + _sfn_word(c) + _fill(2) + _fill(4) + _fill(4) + _fill(1)
            + _word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 1, 12))
            + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 4, 12))
            + _word(4, (rsrp_raw(c["rsrp"]), 4, 12))
            + _word(2, (_opt(c["rsrq_rx"], 0, rsrq_raw), 4, 10))
            + _fill(1)
            + _word(2, (_opt(c["rsrq_rx"], 1, rsrq_raw), 0, 10))
            + _word(2, (rsrq_raw(c["rsrq"]), 4, 10))
            + _word(4, (_opt(c["rssi_rx"], 0, rssi_raw), 10, 11), (_opt(c["rssi_rx"], 1, rssi_raw), 21, 11))
            + _word(4, (rssi_raw(c["rssi"]), 0, 11))
            + _fill(20) + _snr_word(c, 0) + _fill(16) + _fill(8))


def _scmr_v35_cell(c) -> bytes:
    return (_pci_word(c, True) + _fill(2) + _sfn_word(c) + _fill(2) + _fill(4) + _fill(4)
            + _word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 10, 12))
            + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 12, 12))
            + _word(4, (_opt(c["rsrp_rx"], 2, rsrp_raw), 12, 12))
            + _four_rx_block(c)
            + _fill(20) + _snr_word(c, 0) + _snr_word(c, 2) + _fill(12) + _sir_post_ic(c) + _cinr(c, 4))


def _scmr_v36_cell(c, stride: int = 64) -> bytes:
    out = (_pci_word(c, True) + _fill(2) + _sfn_word(c) + _fill(2) + _fill(4) + _fill(4)
           + _word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 10, 12))
           + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 12, 12))
           + _fill(4) + _fill(4)
           + _word(4, (rsrp_raw(c["rsrp"]), 0, 12))
           + _word(4, (_opt(c["rsrq_rx"], 0, rsrq_raw), 0, 10), (_opt(c["rsrq_rx"], 1, rsrq_raw), 20, 10))
           + _fill(4)
           + _word(4, (rsrq_raw(c["rsrq"]), 0, 10)))
    assert len(out) == 48
    return out + _fill(stride - 48)


def _scmr_v40_cell(c) -> bytes:
    return (_pci_word(c, True) + _fill(2) + _sfn_word(c) + _fill(2) + _fill(4) + _fill(4)
            + _word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 10, 12))
            + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 12, 12))
            + _word(4, (_opt(c["rsrp_rx"], 2, rsrp_raw), 12, 12))
            + _fill(4)
            + _four_rx_block(c)
            + _fill(10) + struct.pack("<H", c["residual_freq_error"]) + _fill(8)
            + _snr_word(c, 0) + _snr_word(c, 2) + _fill(12) + _fill(4) + _sir_post_ic(c) + _cinr(c, 4))


SCMR_CELL_PACKERS = {4: _scmr_v4_cell, 7: _scmr_v7_cell, 18: _scmr_v18_cell, 19: _scmr_v19_cell,
                     22: _scmr_v22_cell, 24: _scmr_v24_cell, 35: _scmr_v35_cell, 36: _scmr_v36_cell,
                     40: _scmr_v40_cell}
SCMR_CELL_SIZES = {4: 74, 7: 76, 18: 88, 19: 88, 22: 112, 24: 92, 35: 124, 36: 64, 40: 132}
SCMR_MULTI_CELL = {19, 22, 24, 35, 36, 40}


def scmr_subpacket(sp_version: int, cells=None, earfcn: int = 1850, valid_rx: int = 3) -> bytes:
    """Subpacket 0x19 (header included) for one MobileInsight-numbered version."""
    cells = list(cells or [SERVING_CELL])
    if sp_version == 4:
        header = struct.pack("<H", earfcn)
    elif sp_version in (7, 18):
        header = struct.pack("<I", earfcn)
    elif sp_version == 40:
        header = struct.pack("<IHH", earfcn, len(cells), valid_rx)
    else:
        header = struct.pack("<IH", earfcn, len(cells)) + _fill(2)
    if sp_version not in SCMR_MULTI_CELL:
        assert len(cells) == 1
    payload = header + b"".join(SCMR_CELL_PACKERS[sp_version](c) for c in cells)
    return struct.pack("<BBH", SUBPACKET_SCMR, sp_version, 4 + len(payload)) + payload


def ml1_scell_meas_body(sp_version: int, cells=None, earfcn: int = 1850, container_version: int = 1,
                        extra_subpackets=()) -> bytes:
    """0xB193 body: container, then the 0x19 subpacket and any extra (id, version, payload)."""
    subpackets = [scmr_subpacket(sp_version, cells, earfcn)]
    for sp_id, ver, payload in extra_subpackets:
        subpackets.append(struct.pack("<BBH", sp_id, ver, 4 + len(payload)) + payload)
    return struct.pack("<BB", container_version, len(subpackets)) + _fill(2) + b"".join(subpackets)


# --- 0xB179 LTE ML1 Connected Mode Intra-Freq Meas ------------------------------------------

INTRA_NEIGHBOURS = [(245, -103.5, -13.5), (17, -108.0, -16.0)]
INTRA_DETECTED = [(333, 0x1234, 0x0102030405060708)]


def intra_meas_body(version: int = 4, earfcn: int = 1850, pci: int = 101, subframe_number: int = 0x2003,
                    rsrp: float = -95.0, rsrq: float = -10.5, neighbours=None, detected=None,
                    serving_cell_index: int = 0, neighbour_size: int = 12) -> bytes:
    neighbours = INTRA_NEIGHBOURS if neighbours is None else neighbours
    detected = INTRA_DETECTED if detected is None else detected
    out = bytes([version]) + _fill(3) + bytes([serving_cell_index | 0xF8]) + _fill(3)
    out += struct.pack("<H" if version == 3 else "<I", earfcn)
    out += struct.pack("<HHh", pci, subframe_number, rsrp_raw(rsrp)) + _fill(2)
    out += struct.pack("<h", rsrq_raw(rsrq)) + _fill(2)
    out += struct.pack("<BB", len(neighbours), len(detected))
    if version == 4:
        out += _fill(2)
    for n_pci, n_rsrp, n_rsrq in neighbours:
        out += struct.pack("<Hh", n_pci, rsrp_raw(n_rsrp)) + _fill(2) + struct.pack("<h", rsrq_raw(n_rsrq))
        out += _fill(neighbour_size - 8)
    for d_pci, sss, ref in detected:
        if version == 3:
            out += struct.pack("<IIQ", d_pci, sss, ref)
        else:
            out += struct.pack("<H", d_pci) + _fill(2) + struct.pack("<IQ", sss, ref)
    return out


# --- 0xB17F / 0xB180 (single-sourced headers) ----------------------------------------------

def scell_eval_body(version: int = 4, rrc_release: int = 1, earfcn: int = 1850, pci: int = 101, priority: int = 5,
                    rsrp: float = -95.0, rsrp_avg: float = -95.5, rsrq: float = -10.5, rsrq_avg: float = -11.0,
                    rssi: float = -65.5) -> bytes:
    out = bytes([version, rrc_release])
    if version == 4:
        out += struct.pack("<H", earfcn) + _word(2, (pci, 0, 9), (priority, 9, 7)) + _fill(2)
    else:
        out += _fill(2) + struct.pack("<I", earfcn) + _word(2, (pci, 0, 9), (priority, 9, 7)) + _fill(2)
    out += _word(4, (rsrp_raw(rsrp), 0, 12)) + _word(4, (rsrp_raw(rsrp_avg), 0, 12))
    out += _word(4, (rsrq_raw(rsrq), 0, 10), (rsrq_raw(rsrq_avg), 20, 10))
    out += _word(4, (rssi_raw(rssi), 10, 11))
    out += _fill(4) + _fill(4)            # reselection criteria, not decoded
    return out


def ncell_meas_body(version: int = 4, rrc_release: int = 1, earfcn: int = 1850, num_cells: int = 3,
                    cell_size: int = 32, count_shift: int = 0) -> bytes:
    out = bytes([version, rrc_release])
    if version == 4:
        out += struct.pack("<H", earfcn) + _fill(2) + _word(2, (num_cells, count_shift, 10))
    else:
        out += _fill(2) + struct.pack("<I", earfcn) + _word(4, (num_cells, count_shift, 10))
    return out + _fill(num_cells * cell_size)


# --- 0xB0C1 LTE RRC MIB --------------------------------------------------------------------

def mib_body(version: int = 2, pci: int = 101, earfcn: int = 1850, sfn: int = 512, num_antennas: int = 2,
             dl_bw: int = 5, sib1_br: int = 7, sfn_msb4: int = 3, hsfn_lsb2: int = 1, sib1_sch: int = 4,
             value_tag: int = 9, barring: int = 0, op_mode: int = 3, raster: int = 2) -> bytes:
    if version == 1:
        return struct.pack("<BHHHBB", 1, pci, earfcn, sfn, num_antennas, dl_bw)
    if version == 2:
        return struct.pack("<BHIHBB", 2, pci, earfcn, sfn, num_antennas, dl_bw)
    if version == 3:
        return struct.pack("<BHIHBBB", 3, pci, earfcn, sfn, num_antennas, dl_bw, sib1_br)
    if version == 17:
        return struct.pack("<BHIHBBBBBBHB", 17, pci, earfcn, sfn, sfn_msb4, hsfn_lsb2, sib1_sch, value_tag, barring,
                           op_mode, raster, num_antennas)
    raise ValueError(version)


# --- 0xB063 / 0xB064 LTE MAC transport blocks ---------------------------------------------

def mac_subheaders(entries) -> bytes:
    """TS 36.321 sub-headers from [(lcid, length or None), ...]; E set on all but the last,
    F/L for SDU LCIDs (0..10) that are not last and for any entry given a length (the
    uplink's variable-size CEs, LCID 24/25)."""
    out = bytearray()
    for i, (lcid, length) in enumerate(entries):
        last = i == len(entries) - 1
        out.append((0 if last else 0x20) | lcid)
        if not last and (lcid <= 10 or length is not None):
            assert length is not None
            if length < 128:
                out.append(length)
            else:
                out += bytes([0x80 | (length >> 8), length & 0xFF])
    return bytes(out)


DL_SAMPLE = {"sfn": 512, "subframe": 3, "rnti_type": 0, "harq_id": 5, "pmch_id": 0, "tbs_bytes": 1421,
             "rlc_pdus": 2, "padding_bytes": 3, "subheaders": [(1, 120), (3, 1290), (31, None)],
             "sub_id": 0, "cell_id": 0}
UL_SAMPLE = {"sfn": 513, "subframe": 7, "rnti_type": 0, "harq_id": 2, "grant_bytes": 328, "rlc_pdus": 1,
             "padding_bytes": 0, "bsr_event": 1, "bsr_trigger": 3, "subheaders": [(29, None), (1, 300), (31, None)],
             "sub_id": 0, "cell_id": 0, "extra_bytes": b"\x1f"}     # the short BSR control element


def mac_tb_body(downlink: bool, sp_version: int, samples=None, container_version: int = 1,
                subpacket_id: int = 7, extra_subpackets=()) -> bytes:
    samples = list(samples or [DL_SAMPLE if downlink else UL_SAMPLE])
    payload = bytearray([len(samples)])
    for s in samples:
        hdr = mac_subheaders(s["subheaders"]) + s.get("extra_bytes", b"")
        subfn = (s["sfn"] << 4) | s["subframe"]
        if downlink:
            fixed = struct.pack("<HBBHHBHB", subfn, s["rnti_type"], s["harq_id"], s["pmch_id"], s["tbs_bytes"],
                                s["rlc_pdus"], s["padding_bytes"], len(hdr))
            if sp_version == 4:
                fixed = struct.pack("<BB", s["sub_id"], s["cell_id"]) + fixed
        else:
            fixed = struct.pack("<BBHHBHBBB", s["harq_id"], s["rnti_type"], subfn, s["grant_bytes"], s["rlc_pdus"],
                                s["padding_bytes"], s["bsr_event"], s["bsr_trigger"], len(hdr))
            if sp_version == 7:                     # iPhone 17: the cell id alone leads the v1 order
                fixed = bytes([s["cell_id"]]) + fixed
            elif sp_version != 1:
                fixed = struct.pack("<BB", s["sub_id"], s["cell_id"]) + fixed
        payload += fixed + hdr
    if sp_version == 7 and len(payload) % 4:        # v7 pads its subpacket to a multiple of 4 bytes
        payload += _fill(4 - len(payload) % 4)
    subpackets = [struct.pack("<BBH", subpacket_id, sp_version, 4 + len(payload)) + bytes(payload)]
    for sp_id, ver, extra in extra_subpackets:
        subpackets.append(struct.pack("<BBH", sp_id, ver, 4 + len(extra)) + extra)
    return struct.pack("<BB", container_version, len(subpackets)) + _fill(2) + b"".join(subpackets)


# --- 0xB173 LTE PDSCH Stat Indication ------------------------------------------------------

PDSCH_TB = {"harq_id": 6, "rv": 0, "ndi": 1, "crc_pass": 1, "rnti_type": 0, "tb_index": 0,
            "discarded_retx_present": 0, "did_recombining": 0, "tb_size": 2792, "mcs": 20, "num_rbs": 25,
            "modulation_code": 6, "qed_status": 1, "qed_iteration": 2}
PDSCH_TB_FAILED = dict(PDSCH_TB, harq_id=7, rv=2, ndi=0, crc_pass=0, tb_index=1, did_recombining=1, tb_size=1608,
                       mcs=14, modulation_code=4)
PDSCH_RECORD = {"sfn": 512, "subframe": 3, "num_rbs": 25, "num_layers": 2, "serving_cell_index": 0,
                "hsic_enabled": 1, "tbs": [PDSCH_TB, PDSCH_TB_FAILED], "pmch_id": 0, "area_id": 0}
PDSCH_RECORD_ONE_TB = dict(PDSCH_RECORD, sfn=513, subframe=4, num_layers=1, tbs=[PDSCH_TB])


def _pdsch_tb_bytes(version: int, tb) -> bytes:
    harq = tb["harq_id"] | tb["rv"] << 4 | tb["ndi"] << 6 | tb["crc_pass"] << 7
    rnti = tb["rnti_type"] | tb["tb_index"] << 4 | tb["discarded_retx_present"] << 5 | tb["did_recombining"] << 6
    out = bytes([harq, rnti])
    if version == 36:
        out += _fill(2)
    out += struct.pack("<HBB", tb["tb_size"], tb["mcs"], tb["num_rbs"])
    if version in (24, 32):
        out += bytes([tb["modulation_code"]]) + _fill(1)
    elif version == 36:
        out += bytes([tb["modulation_code"], tb["qed_status"] | tb["qed_iteration"] << 2]) + _fill(2)
    return out


PDSCH_TB_SIZE = {5: 6, 16: 6, 24: 8, 32: 8, 36: 12}


def pdsch_stat_body(version: int = 24, records=None) -> bytes:
    records = [PDSCH_RECORD, PDSCH_RECORD_ONE_TB] if records is None else records
    out = bytes([version, len(records)]) + _fill(2)
    for r in records:
        cell = r["serving_cell_index"] | (r["hsic_enabled"] << 3 if version != 5 else 0xF8)
        out += struct.pack("<HBBBB", (r["sfn"] << 4) | r["subframe"], r["num_rbs"], r["num_layers"], len(r["tbs"]), cell)
        if version == 36:
            out += _fill(6)
        for tb in r["tbs"]:
            out += _pdsch_tb_bytes(version, tb)
        if len(r["tbs"]) == 1:
            out += _fill(PDSCH_TB_SIZE[version])
        out += bytes([r["pmch_id"], r["area_id"]])
        if version == 36:
            out += _fill(2)
    return out


# --- 0xB139 LTE PHY PUSCH Tx Report --------------------------------------------------------

PUSCH_GRANT = {"sfn": 512, "subframe": 8, "coding_rate_raw": 614, "ack": 1, "cqi": 0, "ri": 0, "freq_hopping": 0,
               "rv": 0, "mirror_hopping": 0, "cs_slot0": 4, "cs_slot1": 10, "dmrs_root_slot0": 300, "ue_srs": 0,
               "dmrs_root_slot1": 301, "start_rb_slot0": 12, "start_rb_slot1": 12, "num_rbs": 20, "tb_size": 1736,
               "num_ack_bits": 2, "ack_payload": 3, "rate_matched_ack_bits": 48, "num_ri_bits": 0, "ri_payload": 0,
               "rate_matched_ri_bits": 0, "mod_order": 2, "ri_payload2": 0, "digital_gain": 60, "srs_occasion": 0,
               "retx_index": 0, "tx_power_dbm": 17, "num_cqi_bits": 0, "rate_matched_cqi_bits": 0,
               "cqi_payload": bytes(range(16)), "tx_resampler": 0x01020304, "num_repetition": 1, "rb_nb_start": 0}
PUSCH_GRANT_RETX = dict(PUSCH_GRANT, sfn=513, subframe=2, rv=2, retx_index=1, tx_power_dbm=-7, mod_order=1,
                        tb_size=1736, ack=0)


# ============================================================================================
# iPhone 17 layouts
# ============================================================================================

# --- 0xB193 subpacket 0x19 v66 (b193.ts) ---------------------------------------------------------

IPHONE_CELL = {
    "pci": 80, "serving_cell_index": 0, "is_serving": 1, "rx_map": 3,
    "rsrp_rx": [-113.0, -115.25, None, None], "rsrp": -113.0, "filtered_rsrp": -113.5,
    "rsrq_rx": [-15.0, -14.5, None, None], "rsrq": -14.5, "filtered_rsrq": -14.75,
    "rssi_rx": [-82.0, -83.5, None, None], "rssi": -82.0,
}
IPHONE_SCELL = dict(IPHONE_CELL, pci=235, serving_cell_index=1, rx_map=15,
                    rsrp_rx=[-100.0, -101.0, -102.0, -103.0], rsrp=-100.5, filtered_rsrp=-101.0,
                    rsrq_rx=[-9.0, -9.5, -10.0, -10.5], rsrq=-9.25, filtered_rsrq=-9.5,
                    rssi_rx=[-70.0, -71.0, -72.0, -73.0], rssi=-70.5)
IPHONE_NEIGHBOUR = dict(IPHONE_CELL, pci=388, is_serving=0, serving_cell_index=0, rx_map=15,
                        rsrp_rx=[-116.0, -117.0, -118.0, -119.0], rsrp=-116.5, filtered_rsrp=-117.0,
                        rsrq_rx=[-17.0, -17.5, -18.0, -18.5], rsrq=-17.25, filtered_rsrq=-17.5,
                        rssi_rx=[-84.0, -85.0, -86.0, -87.0], rssi=-84.5)


def scmr_v66_cell(c) -> bytes:
    """One 144-byte v66 cell record: u32 Rx map @0, PCI word @8, measurement words @24 + 4*i."""
    out = struct.pack("<I", c["rx_map"]) + _fill(4)
    out += _word(2, (c["pci"], 0, 9), (c["serving_cell_index"], 9, 3), (c["is_serving"], 15, 1)) + _fill(14)
    out += (_word(4, (_opt(c["rsrp_rx"], 0, rsrp_raw), 10, 12))
            + _word(4, (_opt(c["rsrp_rx"], 1, rsrp_raw), 12, 12))
            + _word(4, (_opt(c["rsrp_rx"], 2, rsrp_raw), 12, 12))
            + _fill(4)
            + _word(4, (_opt(c["rsrp_rx"], 3, rsrp_raw), 0, 12), (rsrp640_raw(c["rsrp"]), 12, 12))
            + _word(4, (rsrp_raw(c["filtered_rsrp"]), 12, 12))
            + _word(4, (_opt(c["rsrq_rx"], 0, rsrq_raw), 0, 10), (_opt(c["rsrq_rx"], 1, rsrq_raw), 20, 10))
            + _word(4, (_opt(c["rsrq_rx"], 2, rsrq_raw), 10, 10), (_opt(c["rsrq_rx"], 3, rsrq_raw), 20, 10))
            + _word(4, (rsrq_raw(c["rsrq"]), 0, 10), (rsrq_raw(c["filtered_rsrq"]), 20, 10))
            + _word(4, (_opt(c["rssi_rx"], 0, rssi_raw), 0, 11), (_opt(c["rssi_rx"], 1, rssi_raw), 11, 11))
            + _word(4, (_opt(c["rssi_rx"], 2, rssi_raw), 0, 11), (_opt(c["rssi_rx"], 3, rssi_raw), 11, 11))
            + _word(4, (rssi_raw(c["rssi"]), 0, 11)))
    out += _fill(72)
    assert len(out) == 144
    return out


def ml1_scell_meas_v66_body(cells=None, earfcn: int = 650, valid_rx: int = 0) -> bytes:
    """0xB193 v1 container with one subpacket 0x19 v66 (u32 EARFCN, u16 cells, u16 valid-Rx flags, 144-byte cells)."""
    cells = list(cells or [IPHONE_CELL])
    payload = struct.pack("<IHH", earfcn, len(cells), valid_rx) + b"".join(scmr_v66_cell(c) for c in cells)
    subpacket = struct.pack("<BBH", SUBPACKET_SCMR, 66, 4 + len(payload)) + payload
    return struct.pack("<BB", 1, 1) + _fill(2) + subpacket


# --- 0xB179 v56 (b179.ts) -------------------------------------------------------------------------

INTRA_V56_NEIGHBOURS = [(235, -116.25, -17.5), (388, -120.0, -19.0)]


def intra_meas_v56_body(earfcn: int = 650, pci: int = 80, tti: int = 2093, rsrp: float = -113.5, rsrq: float = -13.5,
                        neighbours=None, unidentified: int = 9, trailing: bytes = b"") -> bytes:
    """Flat v56 body: 28-byte header then 12-byte neighbours; `trailing` breaks the length identity."""
    neighbours = INTRA_V56_NEIGHBOURS if neighbours is None else neighbours
    out = bytes([56]) + _fill(3) + struct.pack("<IIHH", unidentified, earfcn, pci, tti)
    out += struct.pack("<HHHH", rsrp_raw(rsrp), rsrp_raw(rsrp), rsrq_raw(rsrq), rsrq_raw(rsrq))
    out += struct.pack("<I", len(neighbours))
    for n_pci, n_rsrp, n_rsrq in neighbours:
        out += struct.pack("<HHHHHH", n_pci, rsrp_raw(n_rsrp), rsrp_raw(n_rsrp), rsrq_raw(n_rsrq), rsrq_raw(n_rsrq), 0)
    return out + trailing


# --- 0xB173 v50 (b173.ts) -------------------------------------------------------------------------

PDSCH_V50_TB = {"harq_id": 6, "rv": 0, "ndi": 1, "crc_pass": 1, "rnti_type": 0, "tb_index": 0, "tb_size": 2792,
                "mcs": 20, "num_rbs": 25, "qm": 6}
PDSCH_V50_TB_FAILED = dict(PDSCH_V50_TB, harq_id=7, rv=2, ndi=0, crc_pass=0, tb_index=1, tb_size=1608, mcs=14, qm=4)
PDSCH_V50_RECORD = {"sfn": 512, "subframe": 3, "num_layers": 2, "carrier": 0, "tbs": [PDSCH_V50_TB, PDSCH_V50_TB_FAILED]}
PDSCH_V50_RECORD_ONE_TB = {"sfn": 513, "subframe": 4, "num_layers": 1, "carrier": 1, "tbs": [dict(PDSCH_V50_TB, tb_size=7, mcs=0,
                                                                                               num_rbs=3, qm=2)]}


def pdsch_stat_v50_body(records=None) -> bytes:
    """4-byte header, 40-byte records with two 12-byte TB slots at 12 and 24."""
    records = [PDSCH_V50_RECORD, PDSCH_V50_RECORD_ONE_TB] if records is None else records
    out = bytes([50, len(records)]) + _fill(2)
    for r in records:
        out += struct.pack("<H", (r["sfn"] << 4) | r["subframe"]) + bytes([r["num_layers"], len(r["tbs"]), r["carrier"] | 0xF8])
        out += _fill(7)
        for j in range(2):
            if j < len(r["tbs"]):
                tb = r["tbs"][j]
                hb = tb["harq_id"] | tb["rv"] << 4 | tb["ndi"] << 6 | tb["crc_pass"] << 7
                rw = tb["rnti_type"] | tb["tb_index"] << 4
                out += struct.pack("<BH", hb, rw) + _fill(1) + struct.pack("<HBBB", tb["tb_size"], tb["mcs"], tb["num_rbs"], tb["qm"])
                out += _fill(3)
            else:
                out += _fill(12)
        out += _fill(4)
    return out


# --- 0xB139 v162 (b139.ts) ------------------------------------------------------------------------

PUSCH_V162_GRANT = {"tti": 5128, "carrier": 0, "retx_index": 0, "start_rb": 12, "num_rbs": 20, "tb_size": 1736,
                    "coding_rate_raw": 614, "modulation_code": 2, "power_raw": 90}
PUSCH_V162_GRANT_RETX = dict(PUSCH_V162_GRANT, tti=5132, retx_index=1, modulation_code=1, power_raw=62, start_rb=30, num_rbs=8,
                             tb_size=328)


def pusch_tx_v162_body(grants=None, serving_cell_id: int = 80, dispatch_sfn_sf: int = 0x2008) -> bytes:
    """8-byte header (serving cell 9b | count 5b), 100-byte records."""
    grants = [PUSCH_V162_GRANT, PUSCH_V162_GRANT_RETX] if grants is None else grants
    out = bytes([162]) + _word(2, (serving_cell_id, 0, 9), (len(grants), 9, 5)) + _fill(1)
    out += struct.pack("<H", dispatch_sfn_sf) + _fill(2)
    for g in grants:
        rec = _word(4, (g["tti"], 0, 16), (g["carrier"], 16, 2), (g["retx_index"], 23, 5))
        rec += _word(4, (g["start_rb"], 1, 7), (g["num_rbs"], 15, 7))
        rec += struct.pack("<HH", g["tb_size"], g["coding_rate_raw"])
        rec += _fill(24) + _word(1, (g["modulation_code"], 2, 3)) + _fill(9) + bytes([g["power_raw"]]) + _fill(53)
        assert len(rec) == 100
        out += rec
    return out


# --- 0xB063 v50 (lteMac.ts decodeB063) ------------------------------------------------------------

# an SDU is (control, lcid, length_bytes, tail_words): the descriptor's byte 9 is tail_words,
# and a tail of 8 * tail_words bytes follows the block's descriptors
MAC_DL_V50_BLOCK = {"size_bytes": 1421, "padding_bytes": 3, "sfn": 512, "subframe": 3, "carrier": 0, "harq_id": 5,
                    "header_length": 6, "sdus": [(0, 3, 1290, 2), (1, 29, 1, 0)]}
MAC_DL_V50_BLOCK_NEXT = {"size_bytes": 7, "padding_bytes": 2, "sfn": 513, "subframe": 1, "carrier": 1, "harq_id": 1,
                         "header_length": 3, "sdus": [(0, 1, 2, 0)]}


def mac_dl_tb_v50_body(blocks=None, declared=None, tail_extra=None) -> bytes:
    """u8 0x32, 3 reserved, u32 count; 16-byte TB headers, 12-byte SDU descriptors, 8 x byte-9 tails.
    tail_extra {block index: bytes} appends undeclared tail bytes, which makes the walk resync."""
    blocks = [MAC_DL_V50_BLOCK, MAC_DL_V50_BLOCK_NEXT] if blocks is None else blocks
    tail_extra = tail_extra or {}
    out = bytes([0x32]) + _fill(3) + struct.pack("<I", len(blocks) if declared is None else declared)
    for i, b in enumerate(blocks):
        out += struct.pack("<II", b["size_bytes"], b["padding_bytes"])
        out += _word(4, (b["sfn"], 0, 10), (b["subframe"], 10, 4))
        out += bytes([b["carrier"] | b["harq_id"] << 4, len(b["sdus"])]) + struct.pack("<H", b["header_length"])
        tail = 0
        for control, lcid, length, tail_words in b["sdus"]:
            word = control | lcid << 1 | length << 7
            out += word.to_bytes(3, "little") + _fill(6) + bytes([tail_words]) + _fill(2)
            tail += 8 * tail_words
        out += _fill(tail + tail_extra.get(i, 0))
    return out


# --- 0xB064 v1 / subpacket 0x08 v7: the PHR control element -----------------------------------------

# PHR CE byte 0x21: PH index 33 -> 33 - 23 = 10 dB (reserved bits zero, so Wireshark's own MAC decode is clean)
UL_SAMPLE_PHR = dict(UL_SAMPLE, subheaders=[(26, None), (29, None), (1, 300), (31, None)], extra_bytes=b"\x21\x1f")


# --- 0xB062 v1 / subpacket 0x06 v50 (lteMac.ts decodeB062) -----------------------------------------

def rach_attempt_body(cell: int = 0, attempts: int = 1, result: int = 0, contention: int = 1, msg_mask: int = 7,
                      preamble: int = 27, target_dbm: int = -110, ta: int = 18, ul_earfcn: int = 132622,
                      sp_version: int = 50, size: int = 41, extra_subpackets=()) -> bytes:
    """The subpacket size EXCLUDES the 4-byte subpacket header in this record."""
    sp = _fill(1) + bytes([cell, attempts, result, contention, msg_mask, preamble]) + _fill(1)
    sp += struct.pack("<h", target_dbm) + _fill(8) + struct.pack("<H", ta) + _fill(17) + struct.pack("<I", ul_earfcn)
    assert len(sp) == 41
    sp += _fill(size - 41)
    subpackets = [struct.pack("<BBH", 6, sp_version, len(sp)) + sp]
    for sp_id, ver, payload in extra_subpackets:
        subpackets.append(struct.pack("<BBH", sp_id, ver, len(payload)) + payload)
    return struct.pack("<BB", 1, len(subpackets)) + _fill(2) + b"".join(subpackets)


# --- 0xB14E / 0xB14D v164 (csf.ts) -----------------------------------------------------------------

def pusch_csf_body(sfn: int = 512, subframe: int = 3, carrier: int = 0, ri: int = 2, cqi_cw0: int = 9, cqi_cw1: int = 7,
                   pmi: int = 6, tx_mode: int = 4, version: int = 164) -> bytes:
    out = bytes([version]) + _word(4, (subframe, 0, 4), (sfn, 4, 10), (carrier, 14, 4), (ri - 1, 28, 2))
    out += _word(4, (cqi_cw0, 7, 4), (cqi_cw1, 11, 4), (pmi, 24, 4)) + _word(1, (tx_mode, 0, 4)) + _fill(6)
    return out


def pucch_csf_body(report_type: int = 2, sfn: int = 512, subframe: int = 6, carrier: int = 0, ri: int = 1, cqi_cw0: int = 7,
                   cqi_cw1: int = 0, pmi: int = 6, tx_mode: int = 4, version: int = 164) -> bytes:
    out = bytes([version]) + _word(4, (subframe, 0, 4), (sfn, 4, 10), (carrier, 14, 4), (report_type, 26, 4)) + _fill(1)
    out += _word(2, (cqi_cw0, 4, 4), (cqi_cw1, 8, 4), (pmi, 12, 4)) + _word(2, (tx_mode, 0, 4)) + _word(2, (ri - 1, 8, 2))
    return out + _fill(2)


# --- 0xB126 v163 (b126.ts) --------------------------------------------------------------------------

def demapper_subframes():
    """20 subframes, oldest first: SFN 500.0 .. 501.9, the last one with 25 PRB (10..34) at rank 2."""
    rows = []
    for k in range(20):
        mask = ((1 << (k + 1)) - 1) << 5              # k + 1 PRBs from PRB 5
        rows.append({"sfn": 500 + k // 10, "subframe": k % 10, "tx_antennas": 4, "rx_antennas": 2, "rank": 1, "prb_mask": mask})
    rows[-1] = {"sfn": 501, "subframe": 9, "tx_antennas": 4, "rx_antennas": 4, "rank": 2, "prb_mask": ((1 << 25) - 1) << 10}
    return rows


def pdsch_demapper_body(subframes=None, version: int = 163) -> bytes:
    subframes = demapper_subframes() if subframes is None else subframes
    out = bytes([version]) + _fill(7)
    for s in subframes:
        bitmap = s["prb_mask"].to_bytes(7, "little")
        sub = _word(2, (s["subframe"], 0, 4), (s["sfn"], 4, 10)) + _word(1, (s["tx_antennas"], 1, 3), (s["rx_antennas"] - 1, 4, 2))
        sub += _fill(1) + _word(1, (s["rank"] - 1, 0, 2)) + _fill(3) + bitmap + _fill(9) + bitmap + _fill(17)
        assert len(sub) == 48
        out += sub
    return out


# --- 0xB12A v161 (b12a.ts) --------------------------------------------------------------------------

def pcfich_elements():
    """20 subframes: CFI 1 except 2 at k=3, 3 at k=4/5, nothing decoded at k=7 (raw 0)."""
    rows = []
    for k in range(20):
        cfi = {3: 2, 4: 3, 5: 3}.get(k, 1)
        decoded = 0 if k == 7 else 1
        rows.append({"index": k, "subframe": k % 10, "decoded": decoded, "raw": 4 * cfi if decoded else 0})
    return rows


def pcfich_body(sfn: int = 520, elements=None, version: int = 161) -> bytes:
    elements = pcfich_elements() if elements is None else elements
    out = bytes([version]) + _fill(3) + _word(2, (sfn, 0, 10)) + _fill(10)
    for e in elements:
        out += struct.pack("<HBB", e["index"], e["decoded"], e["raw"]) + _word(2, (e["subframe"], 8, 4)) + _fill(2)
    return out


# --- 0xB16C v50 (b16c.ts) --------------------------------------------------------------------------

DCI_SUBFRAMES = [{"sfn": 187, "subframe": 9, "grants": [(4, 1, 1)], "assignments": 0},
                 {"sfn": 188, "subframe": 3, "grants": [(12, 20, 2), (30, 8, 3)], "assignments": 2},
                 {"sfn": 188, "subframe": 5, "grants": [], "assignments": 1}]


def dci_info_body(subframes=None, declared=None, truncate: int = 0) -> bytes:
    """u8 50, count in bits 6-11 of the u16 at +1; per element a u32 then 16-byte grants and 8-byte assignments."""
    subframes = DCI_SUBFRAMES if subframes is None else subframes
    out = bytes([50]) + _word(2, (len(subframes) if declared is None else declared, 6, 6)) + _fill(1)
    for s in subframes:
        out += _word(4, (s["sfn"], 0, 10), (s["subframe"], 10, 4), (len(s["grants"]), 14, 2), (s["assignments"], 17, 3))
        for start_rb, num_rbs, modulation in s["grants"]:
            out += _word(16, (modulation, 32, 3), (start_rb, 43, 7), (num_rbs, 50, 7))
        out += _fill(8 * s["assignments"])
    return out[:len(out) - truncate] if truncate else out


# --- 0x184C v0x11 (fedTxAgc.ts) ----------------------------------------------------------------------

FED_CHAIN = {"chain": 0x10, "gain_state": 0x24, "power_dbm": 10.0, "power2_dbm": 12.6, "limits_dbm": (22.7, 23.0, 25.0)}
FED_CHAIN_OFF = {"chain": 0x11, "gain_state": 0x30, "power_dbm": -70.0, "power2_dbm": -2.9, "limits_dbm": (22.7, 22.7, 22.7)}
FED_BLOCKS = [{"frame": 203, "subframe": 9, "chains": [FED_CHAIN, FED_CHAIN_OFF]},
              {"frame": 204, "subframe": 0, "chains": [dict(FED_CHAIN, power_dbm=15.5, gain_state=0x10)]}]


def fed_tx_agc_body(blocks=None, version: int = 0x11, junk: bytes = b"") -> bytes:
    """16-byte block headers (0x11, N, five zero bytes, u16 counter @7) and 120-byte chain sub-records."""
    blocks = FED_BLOCKS if blocks is None else blocks
    out = b""
    for b in blocks:
        header = bytes([version, len(blocks)]) + bytes(5) + _word(2, (b["subframe"], 4, 4), (b["frame"], 8, 8)) + _fill(7)
        assert len(header) == 16
        out += header
        for c in b["chains"]:
            sub = bytes([c["chain"], c["gain_state"]]) + _fill(2)
            sub += struct.pack("<hhh", int(round(c["power_dbm"] * 10)), int(round(c["power2_dbm"] * 10)),
                               int(round(c["power_dbm"] * 10)))
            sub += _fill(56) + struct.pack("<HHH", *[int(round(x * 10)) for x in c["limits_dbm"]]) + _fill(48)
            assert len(sub) == 120
            out += sub
    return out + junk


# --- 0x1D0B v7 (modemClock.ts) -------------------------------------------------------------------------

def modem_clock_body(ticks_1024hz: int = 44728, ticks_19m2: int = 11435733, sequence: int = 1707, version: int = 7,
                     length: int = 370) -> bytes:
    out = struct.pack("<III", version, ticks_1024hz, ticks_19m2 | 0xAB << 24) + _fill(84 - 12) + struct.pack("<I", sequence)
    return out + _fill(length - 88)


def pusch_tx_body(version: int = 23, grants=None, serving_cell_id: int = 101, dispatch_sfn_sf: int = 0x2008) -> bytes:
    grants = [PUSCH_GRANT, PUSCH_GRANT_RETX] if grants is None else grants
    out = bytes([version]) + _word(2, (serving_cell_id, 0, 9), (len(grants), 9, 5)) + _fill(1)
    out += struct.pack("<H", dispatch_sfn_sf) + _fill(2)
    for g in grants:
        out += struct.pack("<HH", (g["sfn"] << 4) | g["subframe"], g["coding_rate_raw"])
        out += _word(4, (g["ack"], 0, 1), (g["cqi"], 1, 1), (g["ri"], 2, 1), (g["freq_hopping"], 3, 2), (g["rv"], 5, 2),
                     (g["mirror_hopping"], 7, 2), (g["cs_slot0"], 9, 4), (g["cs_slot1"], 13, 4),
                     (g["dmrs_root_slot0"], 17, 11), (g["ue_srs"], 28, 1))
        out += _word(4, (g["dmrs_root_slot1"], 0, 11), (g["start_rb_slot0"], 11, 7), (g["start_rb_slot1"], 18, 7),
                     (g["num_rbs"], 25, 7))
        out += struct.pack("<H", g["tb_size"])
        out += _word(2, (g["num_ack_bits"], 0, 3), (g["ack_payload"], 3, 4))
        out += _word(4, (g["rate_matched_ack_bits"], 0, 11), (g["num_ri_bits"], 11, 2), (g["ri_payload"], 13, 2),
                     (g["rate_matched_ri_bits"], 15, 11), (g["mod_order"], 26, 2), (g["ri_payload2"], 28, 4))
        out += bytes([g["digital_gain"]]) + _word(1, (g["srs_occasion"], 0, 1), (g["retx_index"], 1, 5)) + _fill(2)
        out += _word(4, (g["tx_power_dbm"] & 0x3FF, 0, 10), (g["num_cqi_bits"], 10, 8), (g["rate_matched_cqi_bits"], 18, 14))
        out += g["cqi_payload"] + struct.pack("<I", g["tx_resampler"])
        if version == 26:
            out += _word(4, (g["num_repetition"], 0, 12), (g["rb_nb_start"], 12, 8))
    return out
