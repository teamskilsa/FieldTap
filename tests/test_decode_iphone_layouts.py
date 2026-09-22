"""The RRC header layouts the iPhone 17 (M25 modem) logs: LTE RRC OTA version 30 and NR RRC OTA version 26.

Synthetic records hold each layout to its field positions. With FT_FIXTURES set (ios/Fixtures/local, never
committed), `fieldtap decode` of the recovered iPhone trace must give the reference pcapng's 132 frames, protocol
for protocol, as tshark reads them.
"""

import os
import struct

import pytest

from fieldtap import cli
from fieldtap import tshark as tshark_mod
from fieldtap.decode import lte_rrc, nr_rrc
from fieldtap.diag.protocol import LogRecord

LTE_RELEASE = bytes.fromhex("2801")          # DL-DCCH rrcConnectionRelease
NR_RELEASE = bytes.fromhex("1000")           # DL-DCCH rrcRelease


def lte_v30(pdu_num, payload, pci=235, earfcn=5110):
    header = struct.pack("<BBBHHIHBIH3s", 15, 0, 15, 0x0060, pci, earfcn, 0x1234, pdu_num, 0, len(payload),
                         b"\xa5\xa5\xa5")
    return bytes([30]) + header + payload


def nr_v26(pdu_num, payload, pci=80, arfcn=174_770, ncgi=bytes(range(0xC1, 0xC9))):
    header = struct.pack("<BBBH8sI3sBIH4s", 15, 0, 1, pci, ncgi, arfcn, b"\x01\x02\x03", pdu_num, 0,
                         len(payload), b"\xa5\xa5\xa5\xa5")
    return struct.pack("<I", 26) + header + payload


def test_lte_version_30_is_header_e30_with_map_d():
    body = lte_v30(9, LTE_RELEASE)
    assert len(body) - len(LTE_RELEASE) == 24
    msg = lte_rrc.decode(LogRecord(0xB0C0, 1 << 20, body))
    assert msg.fields["layout"] == "E30" and msg.fields["layout_source"] == "table"
    assert msg.fields["pdu_map"] == "D"
    assert (msg.fields["pci"], msg.fields["earfcn"]) == (235, 5110)
    assert msg.channel.key == "DL_DCCH"
    assert msg.payload == LTE_RELEASE
    assert msg.name == "rrcConnectionRelease"


def test_lte_version_30_would_be_misread_as_header_d():
    # The same bytes read with the version-27 layout put the three trailing bytes in front of the PDU.
    fields = lte_rrc.HDR_D.unpack(lte_v30(9, LTE_RELEASE), 1)
    assert fields["length"] != len(lte_v30(9, LTE_RELEASE)) - 1 - lte_rrc.HDR_D.size


def test_nr_version_26_is_header_n26_and_never_outputs_the_cell_identity():
    body = nr_v26(4, NR_RELEASE)
    assert len(body) - len(NR_RELEASE) == 35
    msg = nr_rrc.decode(LogRecord(0xB821, 1 << 20, body))
    assert msg.fields["layout"] == "N26" and msg.fields["layout_source"] == "table"
    assert (msg.fields["pci"], msg.fields["arfcn"], msg.fields["rb_id"]) == (80, 174_770, 1)
    assert msg.channel.key == "DL_DCCH" and msg.name == "rrcRelease"
    assert msg.payload == NR_RELEASE
    assert "ncgi" not in msg.fields
    assert all(not isinstance(v, bytes) for v in msg.fields.values())
    assert bytes(range(0xC1, 0xC9)).hex() not in repr(msg.fields) + msg.comment()


def test_nr_version_26_pdus_11_12_and_36():
    kinds = {n: nr_rrc.decode(LogRecord(0xB821, 1 << 20, nr_v26(n, b"\x08\x00"))).channel for n in (11, 12, 36)}
    assert kinds[11].key == "RRC_RECONFIGURATION"
    assert kinds[12].key == "RRC_RECONFIGURATION_COMPLETE"
    assert kinds[36].key == "RADIO_BEARER_CONFIG" and kinds[36].dissector == "nr-rrc.radiobearerconfig"


TSHARK = tshark_mod.find_tshark()


@pytest.mark.skipif(not os.environ.get("FT_FIXTURES"), reason="FT_FIXTURES not set")
@pytest.mark.skipif(TSHARK is None, reason="tshark not installed")
def test_the_recovered_iphone_trace_decodes_like_the_reference(tmp_path):
    fixtures = os.environ["FT_FIXTURES"]
    out = tmp_path / "iphone.pcapng"
    try:
        assert cli.main(["decode", os.path.join(fixtures, "iphone-recovered.qmdl"), "-o", str(out)]) == 0
        ours = tshark_mod.protocol_summary(str(out), tshark=TSHARK)
        reference = tshark_mod.protocol_summary(
            os.path.join(fixtures, "reference", "iphone-recovered-v30.pcapng"), tshark=TSHARK)
        assert sum(ours.values()) == 132
        assert ours == reference
    finally:
        out.unlink(missing_ok=True)
