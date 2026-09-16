"""Diag command codes, request builders and response parsers.

Only the subset FieldTap needs. Everything here is the documented wire format
of the Qualcomm diagnostic protocol as observed on Qualcomm modems for the
last two decades; none of it is copied from another implementation.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

# --- Command codes -----------------------------------------------------------

DIAG_VERNO_F = 0x00          # Version number request/response
DIAG_ESN_F = 0x01            # Electronic serial number
DIAG_STATUS_F = 0x0C
DIAG_LOG_F = 0x10            # Asynchronous log packet (modem -> host)
DIAG_MULTI_LOG_F = 0x98      # qmdl2 container holding one or more DIAG_LOG_F packets
DIAG_BAD_CMD_F = 0x13        # Error responses
DIAG_BAD_PARM_F = 0x14
DIAG_BAD_LEN_F = 0x15
DIAG_BAD_MODE_F = 0x18
DIAG_NV_READ_F = 0x26
DIAG_NV_WRITE_F = 0x27
DIAG_SUBSYS_CMD_F = 0x4B
DIAG_EVENT_REPORT_F = 0x60   # Enable/disable event reports
DIAG_LOG_CONFIG_F = 0x73     # Log mask configuration
DIAG_LOG_ON_DEMAND_F = 0x78
DIAG_EXT_MSG_F = 0x79        # Debug message (modem -> host)
DIAG_EXT_BUILD_ID_F = 0x7C   # Build id / model strings
DIAG_EXT_MSG_CONFIG_F = 0x7D # Debug message mask configuration
DIAG_SUBSYS_CMD_VER_2_F = 0x80
DIAG_EVENT_MASK_GET_F = 0x81
DIAG_EVENT_MASK_SET_F = 0x82
DIAG_QSR_EXT_MSG_TERSE_F = 0x92
DIAG_MULTI_RADIO_CMD_F = 0x98
DIAG_QSR4_EXT_MSG_TERSE_F = 0x99

ERROR_CODES = {
    DIAG_BAD_CMD_F: "bad command",
    DIAG_BAD_PARM_F: "bad parameter",
    DIAG_BAD_LEN_F: "bad length",
    DIAG_BAD_MODE_F: "bad mode",
}

# Asynchronous (unsolicited) packet types the modem pushes without a request.
ASYNC_CODES = {
    DIAG_LOG_F, DIAG_EVENT_REPORT_F, DIAG_EXT_MSG_F,
    DIAG_QSR_EXT_MSG_TERSE_F, DIAG_QSR4_EXT_MSG_TERSE_F,
}

# --- Log configuration (0x73) -------------------------------------------------

LOG_CONFIG_DISABLE_OP = 0
LOG_CONFIG_RETRIEVE_ID_RANGES_OP = 1
LOG_CONFIG_RETRIEVE_VALID_MASK_OP = 2
LOG_CONFIG_SET_MASK_OP = 3
LOG_CONFIG_GET_LOGMASK_OP = 4

LOG_EQUIP_ID_COUNT = 16


def equip_id(log_code: int) -> int:
    """Equipment id is the top nibble of the 16-bit log code (0xB821 -> 0xB)."""
    return (log_code >> 12) & 0xF


def log_item(log_code: int) -> int:
    return log_code & 0xFFF


def build_log_config_disable() -> bytes:
    return struct.pack("<BBBBI", DIAG_LOG_CONFIG_F, 0, 0, 0, LOG_CONFIG_DISABLE_OP)


def build_log_config_get_ranges() -> bytes:
    return struct.pack("<BBBBI", DIAG_LOG_CONFIG_F, 0, 0, 0, LOG_CONFIG_RETRIEVE_ID_RANGES_OP)


def build_log_config_set_mask(equip: int, last_item: int, codes: Iterable[int]) -> bytes:
    """Enable exactly `codes` (all must share `equip`) within items 0..last_item."""
    nbytes = (last_item + 8) // 8
    mask = bytearray(nbytes)
    for code in codes:
        if equip_id(code) != equip:
            raise ValueError("log code 0x%04X is not in equipment id 0x%X" % (code, equip))
        item = log_item(code)
        if item > last_item:
            raise ValueError("log code 0x%04X is beyond last item 0x%X" % (code, last_item))
        mask[item >> 3] |= 1 << (item & 7)
    return struct.pack("<BBBBIII", DIAG_LOG_CONFIG_F, 0, 0, 0,
                       LOG_CONFIG_SET_MASK_OP, equip, last_item) + bytes(mask)


@dataclass
class LogConfigResponse:
    op: int
    status: int
    equip: int = 0
    last_item: int = 0
    ranges: list = field(default_factory=list)   # op 1: last item per equip id
    mask: bytes = b""                             # op 3/4: the mask echoed back

    @property
    def ok(self) -> bool:
        return self.status == 0


def parse_log_config_response(payload: bytes) -> LogConfigResponse:
    if len(payload) < 12 or payload[0] != DIAG_LOG_CONFIG_F:
        raise ValueError("not a log config response")
    op, status = struct.unpack_from("<II", payload, 4)
    resp = LogConfigResponse(op=op, status=status)
    body = payload[12:]
    if op == LOG_CONFIG_RETRIEVE_ID_RANGES_OP:
        count = min(LOG_EQUIP_ID_COUNT, len(body) // 4)
        resp.ranges = list(struct.unpack_from("<%dI" % count, body, 0))
    elif op in (LOG_CONFIG_SET_MASK_OP, LOG_CONFIG_GET_LOGMASK_OP,
                LOG_CONFIG_RETRIEVE_VALID_MASK_OP):
        if len(body) >= 8:
            resp.equip, resp.last_item = struct.unpack_from("<II", body, 0)
            resp.mask = bytes(body[8:])
    return resp


def build_log_config_set_mask_response(equip: int, last_item: int, mask: bytes,
                                       status: int = 0) -> bytes:
    """Used by the replay/fake transports and by tests."""
    return struct.pack("<BBBBIIII", DIAG_LOG_CONFIG_F, 0, 0, 0,
                       LOG_CONFIG_SET_MASK_OP, status, equip, last_item) + mask


def build_log_config_ranges_response(ranges: Iterable[int], status: int = 0) -> bytes:
    values = list(ranges)
    return struct.pack("<BBBBII", DIAG_LOG_CONFIG_F, 0, 0, 0,
                       LOG_CONFIG_RETRIEVE_ID_RANGES_OP, status) + \
        struct.pack("<%dI" % len(values), *values)


# --- Log packets (0x10) ---------------------------------------------------------

LOG_HEADER = struct.Struct("<BBHHHQ")   # cmd, more, outer_len, len, code, timestamp
LOG_HEADER_LEN = LOG_HEADER.size        # 16
LOG_ENTRY_HEADER_LEN = 12               # len, code, timestamp (the DLF entry header)


@dataclass
class LogRecord:
    code: int
    timestamp_raw: int
    body: bytes
    more: int = 0

    @property
    def timestamp(self) -> Optional[datetime]:
        return qc_timestamp(self.timestamp_raw)

    @property
    def equip(self) -> int:
        return equip_id(self.code)


def parse_log_packet(payload: bytes) -> LogRecord:
    """Parse a DIAG_LOG_F payload (already unframed)."""
    if len(payload) < LOG_HEADER_LEN or payload[0] != DIAG_LOG_F:
        raise ValueError("not a log packet")
    _cmd, more, _outer_len, inner_len, code, ts = LOG_HEADER.unpack_from(payload, 0)
    # inner_len covers the 12-byte entry header plus the body. Trust it when it
    # is consistent with what arrived, otherwise take everything that is there.
    body_len = inner_len - LOG_ENTRY_HEADER_LEN
    available = len(payload) - LOG_HEADER_LEN
    if 0 <= body_len <= available:
        body = payload[LOG_HEADER_LEN:LOG_HEADER_LEN + body_len]
    else:
        body = payload[LOG_HEADER_LEN:]
    return LogRecord(code=code, timestamp_raw=ts, body=bytes(body), more=more)


def build_log_packet(code: int, timestamp_raw: int, body: bytes) -> bytes:
    """Inverse of parse_log_packet, used for fixtures and file conversion."""
    inner = LOG_ENTRY_HEADER_LEN + len(body)
    return LOG_HEADER.pack(DIAG_LOG_F, 0, inner, inner, code, timestamp_raw) + body


def build_log_entry(code: int, timestamp_raw: int, body: bytes) -> bytes:
    """A bare log entry (len, code, ts, body) as stored in QXDM .dlf files."""
    inner = LOG_ENTRY_HEADER_LEN + len(body)
    return struct.pack("<HHQ", inner, code, timestamp_raw) + body


MULTI_LOG_HEADER = struct.Struct("<BBHI")   # cmd, version, pad, packet count
MULTI_LOG_HEADER_LEN = MULTI_LOG_HEADER.size    # 8


def iter_qmdl2_log_packets(frame: bytes):
    """Yield each DIAG_LOG_F payload inside a qmdl2 container.

    `diag_mdlog` on a diag-router platform does not write bare log packets. It
    wraps them: 0x98, a version, two pad bytes and a 32-bit count, then that many
    ordinary DIAG_LOG_F packets end to end. The packets inside are exactly what
    the USB stream carries, so everything downstream is unchanged once the
    wrapper is off.

    The count is trusted only as far as the bytes allow, and each packet is
    measured by its own length field rather than by the count, so a truncated
    file yields what it holds instead of raising.
    """
    if len(frame) < MULTI_LOG_HEADER_LEN or frame[0] != DIAG_MULTI_LOG_F:
        return
    _cmd, _version, _pad, count = MULTI_LOG_HEADER.unpack_from(frame, 0)
    offset = MULTI_LOG_HEADER_LEN
    seen = 0
    while offset + LOG_HEADER_LEN <= len(frame) and (count == 0 or seen < count):
        if frame[offset] != DIAG_LOG_F:
            return
        inner_len = struct.unpack_from("<H", frame, offset + 4)[0]
        if inner_len < LOG_ENTRY_HEADER_LEN:
            return
        # A packet spans its 16-byte header plus the body: inner_len counts the
        # 12-byte entry header and the body, so the step is inner_len + 4.
        step = inner_len + 4
        end = offset + step
        if end > len(frame):
            end = len(frame)
        yield frame[offset:end]
        offset = end
        seen += 1


def iter_log_entries(data: bytes):
    """Iterate LogRecords from a stream of bare log entries (.dlf layout)."""
    offset = 0
    total = len(data)
    while offset + LOG_ENTRY_HEADER_LEN <= total:
        inner, code, ts = struct.unpack_from("<HHQ", data, offset)
        if inner < LOG_ENTRY_HEADER_LEN:
            # Corrupt entry; skip a byte and try to resynchronise.
            offset += 1
            continue
        body = data[offset + LOG_ENTRY_HEADER_LEN: offset + inner]
        yield LogRecord(code=code, timestamp_raw=ts, body=bytes(body))
        offset += inner


# --- Timestamps -------------------------------------------------------------------

# Diag timestamps are CDMA system time: the upper 48 bits count 1.25 ms ticks
# since 1980-01-06 00:00:00 (the GPS epoch, no leap seconds applied); the low
# 16 bits are a fraction of that tick in 1/32-chip units at 1.2288 Mcps.
QC_EPOCH = datetime(1980, 1, 6, tzinfo=timezone.utc)
_TICK_SECONDS = 1.25e-3
_FRACTION_HZ = 1.2288e6 * 32


def qc_timestamp(raw: int) -> Optional[datetime]:
    if raw <= 0:
        return None
    ticks = raw >> 16
    frac = raw & 0xFFFF
    seconds = ticks * _TICK_SECONDS + frac / _FRACTION_HZ
    try:
        return QC_EPOCH + timedelta(seconds=seconds)
    except OverflowError:
        return None


def qc_timestamp_from_datetime(when: datetime) -> int:
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    seconds = (when - QC_EPOCH).total_seconds()
    ticks = int(seconds / _TICK_SECONDS)
    frac = int(round((seconds - ticks * _TICK_SECONDS) * _FRACTION_HZ)) & 0xFFFF
    return (ticks << 16) | frac


def timestamp_is_plausible(when: Optional[datetime]) -> bool:
    """A modem that has not acquired network time reports 1980-ish values."""
    return when is not None and when.year >= 2005


# --- Version / build information ----------------------------------------------------

@dataclass
class DeviceInfo:
    compile_date: str = ""
    compile_time: str = ""
    release_date: str = ""
    release_time: str = ""
    version_dir: str = ""
    mobile_model: Optional[int] = None
    mobile_firmware_rev: Optional[int] = None
    msm_revision: Optional[int] = None
    build_id: str = ""
    model_string: str = ""
    esn: Optional[int] = None

    def as_dict(self) -> dict:
        return {k: v for k, v in self.__dict__.items() if v not in ("", None)}


def build_verno_request() -> bytes:
    return bytes((DIAG_VERNO_F,))


def build_ext_build_id_request() -> bytes:
    return bytes((DIAG_EXT_BUILD_ID_F,))


def build_esn_request() -> bytes:
    return bytes((DIAG_ESN_F,))


def _cstr(data: bytes) -> str:
    return data.split(b"\x00", 1)[0].decode("ascii", "replace").strip()


def parse_verno_response(payload: bytes, info: Optional[DeviceInfo] = None) -> DeviceInfo:
    info = info or DeviceInfo()
    if len(payload) < 47 or payload[0] != DIAG_VERNO_F:
        return info
    info.compile_date = _cstr(payload[1:12])
    info.compile_time = _cstr(payload[12:20])
    info.release_date = _cstr(payload[20:31])
    info.release_time = _cstr(payload[31:39])
    info.version_dir = _cstr(payload[39:47])
    if len(payload) >= 52:
        # scm(1) cai_rev(1) model(1) firm_rev(2) slot_cycle(1) hw_maj(1) hw_min(1)
        info.mobile_model = payload[49]
        info.mobile_firmware_rev = struct.unpack_from("<H", payload, 50)[0]
    return info


def parse_ext_build_id_response(payload: bytes, info: Optional[DeviceInfo] = None) -> DeviceInfo:
    info = info or DeviceInfo()
    if len(payload) < 12 or payload[0] != DIAG_EXT_BUILD_ID_F:
        return info
    info.msm_revision, info.mobile_model = struct.unpack_from("<II", payload, 4)
    strings = payload[12:].split(b"\x00")
    if strings:
        info.build_id = _cstr(strings[0])
    if len(strings) > 1:
        info.model_string = _cstr(strings[1])
    return info


def parse_esn_response(payload: bytes, info: Optional[DeviceInfo] = None) -> DeviceInfo:
    info = info or DeviceInfo()
    if len(payload) >= 5 and payload[0] == DIAG_ESN_F:
        info.esn = struct.unpack_from("<I", payload, 1)[0]
    return info


# --- Housekeeping requests that keep the stream quiet -----------------------------------

def build_ext_msg_config_disable_all() -> bytes:
    """DIAG_EXT_MSG_CONFIG_F op 5: set every runtime mask to zero (silence debug text)."""
    return struct.pack("<BBI", DIAG_EXT_MSG_CONFIG_F, 5, 0)


def build_event_report_disable() -> bytes:
    return struct.pack("<BB", DIAG_EVENT_REPORT_F, 0)
