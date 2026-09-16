"""DiagClient: request/response plus a log stream on top of any Transport."""

from __future__ import annotations

import time
from collections import Counter, deque
from dataclasses import dataclass, field
from typing import Callable, Iterable, Iterator, Optional

from . import hdlc, protocol
from .protocol import DeviceInfo, LogRecord
from .transport import Transport


class DiagError(RuntimeError):
    pass


class DiagTimeout(DiagError):
    pass


@dataclass
class LogMaskResult:
    enabled: list = field(default_factory=list)      # codes the modem accepted
    unsupported: list = field(default_factory=list)  # beyond the modem's reported range
    failed: list = field(default_factory=list)       # set-mask returned an error status
    ranges: dict = field(default_factory=dict)       # equip id -> last item reported

    @property
    def ok(self) -> bool:
        return bool(self.enabled) and not self.failed


class DiagClient:
    """Speak diag over a transport.

    * `raw_sink` receives every byte read from the transport, so a .qmdl
      recording is a faithful copy of the wire.
    * Log packets that arrive while a response is awaited are queued, never
      dropped.
    """

    def __init__(self, transport: Transport, raw_sink=None):
        self.transport = transport
        self.raw_sink = raw_sink
        self.unframer = hdlc.Unframer()
        self.stats: Counter = Counter()
        self.device = DeviceInfo()
        self.debug_messages: deque = deque(maxlen=200)
        self._pending: deque = deque()
        self._closed = False

    # -- low level ---------------------------------------------------------------

    def _read_frames(self, timeout: float) -> list:
        data = self.transport.read(timeout=timeout)
        if not data:
            return []
        self.stats["bytes"] += len(data)
        if self.raw_sink is not None:
            self.raw_sink.write(data)
        return self.unframer.feed(data)

    def _absorb_async(self, frame: bytes) -> bool:
        code = frame[0]
        if code == protocol.DIAG_MULTI_LOG_F:
            # A qmdl2 container from the handset's own diag_mdlog: unwrap and take
            # every log packet inside it.
            found = False
            for packet in protocol.iter_qmdl2_log_packets(frame):
                found = True
                try:
                    self._pending.append(protocol.parse_log_packet(packet))
                    self.stats["logs"] += 1
                except ValueError:
                    self.stats["bad_logs"] += 1
            return found
        if code == protocol.DIAG_LOG_F:
            try:
                self._pending.append(protocol.parse_log_packet(frame))
                self.stats["logs"] += 1
            except ValueError:
                self.stats["bad_logs"] += 1
            return True
        if code in (protocol.DIAG_EXT_MSG_F, protocol.DIAG_QSR_EXT_MSG_TERSE_F,
                    protocol.DIAG_QSR4_EXT_MSG_TERSE_F):
            self.stats["debug_msgs"] += 1
            self.debug_messages.append(frame)
            return True
        if code == protocol.DIAG_EVENT_REPORT_F and len(frame) > 2:
            self.stats["events"] += 1
            return True
        return False

    def request(self, payload: bytes, timeout: float = 2.0, retries: int = 1) -> bytes:
        """Send one request and return the matching response payload."""
        if not self.transport.interactive:
            raise DiagError("transport is not interactive (replay)")
        code = payload[0]
        last_error: Optional[str] = None
        for _attempt in range(retries + 1):
            self.transport.write(hdlc.encode(payload))
            self.stats["requests"] += 1
            deadline = time.monotonic() + timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                try:
                    frames = self._read_frames(min(0.2, remaining))
                except EOFError:
                    raise DiagError("transport closed while waiting for 0x%02X" % code)
                response: Optional[bytes] = None
                rejected: Optional[str] = None
                for frame in frames:
                    # Every frame in the batch is examined, even after the
                    # response is found: log packets that shared a read with
                    # the response must be queued, not dropped.
                    if not frame or self._absorb_async(frame):
                        continue
                    if response is None and rejected is None:
                        if frame[0] == code:
                            response = frame
                            continue
                        if frame[0] in protocol.ERROR_CODES:
                            rejected = protocol.ERROR_CODES[frame[0]]
                            continue
                    self.stats["stray_responses"] += 1
                if response is not None:
                    self.stats["responses"] += 1
                    return response
                if rejected is not None:
                    raise DiagError("modem rejected 0x%02X: %s" % (code, rejected))
            last_error = "no response to 0x%02X within %.1fs" % (code, timeout)
        raise DiagTimeout(last_error or "timeout")

    # -- high level ---------------------------------------------------------------

    def probe(self) -> DeviceInfo:
        """Identify the modem. Every query is optional; failures are tolerated."""
        for build, parse in (
            (protocol.build_verno_request, protocol.parse_verno_response),
            (protocol.build_ext_build_id_request, protocol.parse_ext_build_id_response),
            (protocol.build_esn_request, protocol.parse_esn_response),
        ):
            try:
                parse(self.request(build(), timeout=1.5), self.device)
            except DiagError:
                continue
        return self.device

    def quiet(self) -> None:
        """Turn off debug text and event reports so logs get the bandwidth."""
        for build in (protocol.build_ext_msg_config_disable_all, protocol.build_event_report_disable):
            try:
                self.request(build(), timeout=1.0, retries=0)
            except DiagError:
                pass

    def disable_logs(self) -> bool:
        try:
            resp = protocol.parse_log_config_response(self.request(protocol.build_log_config_disable()))
            return resp.ok
        except (DiagError, ValueError):
            return False

    def configure_logs(self, codes: Iterable[int]) -> LogMaskResult:
        result = LogMaskResult()
        wanted = sorted(set(codes))
        self.disable_logs()
        ranges = protocol.parse_log_config_response(self.request(protocol.build_log_config_get_ranges()))
        if not ranges.ok:
            raise DiagError("modem refused log id range query (status %d)" % ranges.status)
        result.ranges = {i: v for i, v in enumerate(ranges.ranges)}
        by_equip: dict = {}
        for code in wanted:
            by_equip.setdefault(protocol.equip_id(code), []).append(code)
        for equip, equip_codes in sorted(by_equip.items()):
            last_item = result.ranges.get(equip, 0)
            usable = [c for c in equip_codes if protocol.log_item(c) <= last_item]
            result.unsupported += [c for c in equip_codes if protocol.log_item(c) > last_item]
            if not usable:
                continue
            req = protocol.build_log_config_set_mask(equip, last_item, usable)
            resp = protocol.parse_log_config_response(self.request(req, timeout=3.0))
            if resp.ok:
                result.enabled += usable
            else:
                result.failed += usable
        return result

    def configure_all_logs(self) -> LogMaskResult:
        """Enable every log item in every equipment-id range the modem reports.
        This is the "capture everything" mode: the raw .qmdl then holds all the
        modem is willing to emit, decoded or not."""
        result = LogMaskResult()
        self.disable_logs()
        ranges = protocol.parse_log_config_response(self.request(protocol.build_log_config_get_ranges()))
        if not ranges.ok:
            raise DiagError("modem refused log id range query (status %d)" % ranges.status)
        result.ranges = {i: v for i, v in enumerate(ranges.ranges)}
        for equip, last_item in sorted(result.ranges.items()):
            if last_item <= 0:
                continue
            codes = [(equip << 12) | item for item in range(last_item + 1)]
            req = protocol.build_log_config_set_mask(equip, last_item, codes)
            try:
                resp = protocol.parse_log_config_response(self.request(req, timeout=5.0))
            except DiagError:
                result.failed += codes
                continue
            if resp.ok:
                result.enabled += codes
            else:
                result.failed += codes
        return result

    def stream(self, stop: Optional[Callable[[], bool]] = None, idle_timeout: float = 0.5,
               on_idle: Optional[Callable[[], None]] = None) -> Iterator[LogRecord]:
        """Yield log records until the transport ends or `stop()` returns True."""
        while True:
            while self._pending:
                yield self._pending.popleft()
            if stop is not None and stop():
                return
            try:
                frames = self._read_frames(idle_timeout)
            except EOFError:
                while self._pending:
                    yield self._pending.popleft()
                return
            if not frames:
                if on_idle is not None:
                    on_idle()
                continue
            for frame in frames:
                if frame and not self._absorb_async(frame):
                    self.stats["stray_responses"] += 1

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self.transport.interactive:
            try:
                self.disable_logs()
            except Exception:
                pass
        self.transport.close()
