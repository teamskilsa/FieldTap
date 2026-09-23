"""The log-mask files a handset writes for each capture profile, as golden fixtures.

tests/fixtures/masks/<profile>.hex is the `diag_mdlog -f` mask file for one
profile of fieldtap.decode.registry.PROFILES, built by fieldtap.diag.protocol
and framed by fieldtap.diag.hdlc: a disable command, then one set-mask command
per equipment id present, in equipment-id order, each HDLC-framed and laid end
to end. The equipment-id ranges are the ones the Android app falls back to
(android/diag/.../LogMask.kt DEFAULT_RANGES, recorded from the OnePlus 10 Pro).

The Android app builds the same file on the phone (LogMask.file over
LogCodes.codes(profile)); its golden test compares those bytes with these files,
so the two implementations cannot drift apart without a test saying so.

Regenerate after a profile or a range changes:

    FT_WRITE_MASK_FIXTURES=1 .venv/Scripts/python -m pytest tests/test_mask_profiles.py

Codes the ranges cannot express are dropped the way the app drops them: an
equipment id missing from the ranges is skipped entirely, and an item beyond
its range is left out of the bitmap. The fixture header lists any such code,
and a test here fails if a profile has one, because a code that never reaches
the modem is a decoder that never sees a record.
"""

from __future__ import annotations

import hashlib
import os

import pytest

from fieldtap.decode.registry import profile_codes
from fieldtap.diag import hdlc, protocol

HERE = os.path.dirname(os.path.abspath(__file__))
MASK_DIR = os.path.join(HERE, "fixtures", "masks")
WRITE_ENV = "FT_WRITE_MASK_FIXTURES"

# The profiles the phone offers, in the order its setting lists them.
PROFILES = ("signalling", "engineering", "l2")

# LogMask.DEFAULT_RANGES: equipment id -> highest log item the modem reported.
DEFAULT_RANGES = {
    0x1: 0xDB2,
    0x4: 0x910,
    0x5: 0x420,
    0x7: 0x4FF,
    0xA: 0x38A,
    0xB: 0x9FF,
    0xD: 0x1FF,
}

# The signalling file is the one the app has shipped with; its size and digest are
# pinned in LogMaskTest.theSignallingMaskFileIsByteForByteTheDesktopTools.
SIGNALLING_SIZE = 350
SIGNALLING_SHA256_PREFIX = "00751fc0aee76e3a"

HEX_LINE = 64


def mask_file(codes, ranges):
    """The mask file for `codes`, and the codes the ranges could not express.

    The same rule as LogMask.file: group by equipment id, skip an id the ranges do
    not know (or give a range of 0), and leave out an item beyond the id's range
    rather than widening the bitmap past what the modem accepts.
    """
    dropped = []
    by_equip = {}
    for code in codes:
        by_equip.setdefault(protocol.equip_id(code), []).append(code)
    parts = [hdlc.encode(protocol.build_log_config_disable())]
    for equip in sorted(by_equip):
        group = by_equip[equip]
        last_item = ranges.get(equip, 0)
        if last_item <= 0:
            dropped.extend(group)
            continue
        kept = [c for c in group if protocol.log_item(c) <= last_item]
        dropped.extend(c for c in group if protocol.log_item(c) > last_item)
        parts.append(hdlc.encode(protocol.build_log_config_set_mask(equip, last_item, kept)))
    return b"".join(parts), sorted(dropped)


def fixture_text(profile, codes, data, dropped):
    """The .hex file: a commented header, then the bytes as lowercase hex, 64 digits a line."""
    lines = [
        "# fieldtap log-mask file for the %s capture profile" % profile,
        "# %d codes: %s" % (len(codes), " ".join("%04X" % c for c in codes)),
        "# ranges: %s" % " ".join("%X=%X" % (k, v) for k, v in sorted(DEFAULT_RANGES.items())),
        "# dropped by the ranges: %s" % (" ".join("%04X" % c for c in dropped) if dropped else "none"),
        "# %d bytes, sha256 %s" % (len(data), hashlib.sha256(data).hexdigest()),
        "# written by tests/test_mask_profiles.py; lines starting with # are comments",
    ]
    digits = data.hex()
    lines.extend(digits[i:i + HEX_LINE] for i in range(0, len(digits), HEX_LINE))
    return "\n".join(lines) + "\n"


def fixture_bytes(text):
    """The bytes a .hex file holds, ignoring comments and whitespace."""
    digits = "".join(line.strip() for line in text.splitlines() if not line.lstrip().startswith("#"))
    return bytes.fromhex(digits)


def fixture_path(profile):
    return os.path.join(MASK_DIR, profile + ".hex")


@pytest.fixture(scope="module", autouse=True)
def written_fixtures():
    """With FT_WRITE_MASK_FIXTURES set, (re)write every fixture before the checks run."""
    if not os.environ.get(WRITE_ENV):
        return
    os.makedirs(MASK_DIR, exist_ok=True)
    for profile in PROFILES:
        codes = profile_codes(profile)
        data, dropped = mask_file(codes, DEFAULT_RANGES)
        with open(fixture_path(profile), "w", encoding="ascii", newline="\n") as fh:
            fh.write(fixture_text(profile, codes, data, dropped))


@pytest.mark.parametrize("profile", PROFILES)
def test_the_committed_fixture_is_what_the_desktop_tool_builds(profile):
    codes = profile_codes(profile)
    data, dropped = mask_file(codes, DEFAULT_RANGES)
    path = fixture_path(profile)
    assert os.path.isfile(path), "%s is missing: run with %s=1" % (path, WRITE_ENV)
    with open(path, "r", encoding="ascii") as fh:
        text = fh.read()
    assert fixture_bytes(text) == data, (
        "%s differs from what the profile builds now: rerun with %s=1" % (os.path.basename(path), WRITE_ENV))
    assert text == fixture_text(profile, codes, data, dropped), (
        "%s header is stale: rerun with %s=1" % (os.path.basename(path), WRITE_ENV))


@pytest.mark.parametrize("profile", PROFILES)
def test_every_profile_code_reaches_the_modem(profile):
    _data, dropped = mask_file(profile_codes(profile), DEFAULT_RANGES)
    assert dropped == [], "codes the default ranges cannot express: %s" % ["0x%04X" % c for c in dropped]


def test_the_file_is_a_disable_then_one_set_mask_per_equipment_id():
    codes = profile_codes("l2")
    data, _dropped = mask_file(codes, DEFAULT_RANGES)
    frames = hdlc.Unframer().feed(data)
    assert frames[0] == protocol.build_log_config_disable()
    equips = sorted({protocol.equip_id(c) for c in codes})
    assert len(frames) == 1 + len(equips)
    for frame, equip in zip(frames[1:], equips):
        assert frame[:4] == b"\x73\x00\x00\x00"
        assert int.from_bytes(frame[4:8], "little") == protocol.LOG_CONFIG_SET_MASK_OP
        assert int.from_bytes(frame[8:12], "little") == equip
        assert int.from_bytes(frame[12:16], "little") == DEFAULT_RANGES[equip]
        mask = frame[16:]
        wanted = {protocol.log_item(c) for c in codes if protocol.equip_id(c) == equip}
        lit = {i for i in range(len(mask) * 8) if mask[i >> 3] & (1 << (i & 7))}
        assert lit == wanted


def test_the_signalling_file_is_the_one_the_app_shipped_with():
    data, _dropped = mask_file(profile_codes("signalling"), DEFAULT_RANGES)
    assert len(data) == SIGNALLING_SIZE
    assert hashlib.sha256(data).hexdigest().startswith(SIGNALLING_SHA256_PREFIX)


def test_the_profiles_nest():
    signalling, engineering, l2 = (set(profile_codes(p)) for p in PROFILES)
    assert signalling < engineering < l2
    assert len(signalling) == 22 and len(engineering) == 47 and len(l2) == 52


def test_a_code_the_ranges_cannot_express_is_dropped_not_widened():
    data, dropped = mask_file([0xB0C0, 0xBA00, 0x2001], {0xB: 0x9FF})
    assert dropped == [0x2001, 0xBA00]
    frames = hdlc.Unframer().feed(data)
    assert len(frames) == 2, "the disable and equipment 0xB only"
    assert len(frames[1]) == 16 + (0x9FF + 8) // 8
