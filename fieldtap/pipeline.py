"""The capture/decode loop shared by `capture`, `decode`, `auto` and `selftest`.

    transport -> DiagClient -> LogRecord -> Decoder -> DecodedMessage -> sinks
                     |                                    |
                  raw .qmdl                     session sidecar, observers
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

from .decode import Decoder
from .decode.records import DiagRecord
from .decode.records import DecodedMessage
from .decode.registry import ALL_PROFILE, profile_codes
from .diag.client import DiagClient, DiagError
from .diag.hdlc import Unframer
from .diag.protocol import iter_log_entries
from .diag.transport import FileTransport, Transport, TransportError
from .output.sinks import MultiSink, Sink
from .session import Session


@dataclass
class RunOptions:
    profile: str = "signalling"
    codes: Optional[list] = None          # explicit log codes override the profile
    quiet_modem: bool = True              # silence debug text / event reports
    max_seconds: Optional[float] = None
    max_records: Optional[int] = None
    progress_every: float = 2.0


@dataclass
class RunResult:
    records: int = 0
    messages: int = 0
    cell_info: int = 0
    diag_records: int = 0
    seconds: float = 0.0
    log_mask: dict = field(default_factory=dict)
    modem: dict = field(default_factory=dict)
    client_stats: dict = field(default_factory=dict)
    framing: dict = field(default_factory=dict)
    decoder: dict = field(default_factory=dict)
    sinks: dict = field(default_factory=dict)
    stopped_by: str = "end"               # end | user | time | records | interrupt | unplugged
    error: Optional[str] = None


def _framing_stats(unframer: Unframer) -> dict:
    return {"frames": unframer.frames, "crc_errors": unframer.crc_errors,
            "short_frames": unframer.short_frames, "resyncs": unframer.resyncs}


def _mask_summary(mask) -> dict:
    """Sidecar-friendly view of a LogMaskResult: explicit lists when short,
    counts and ranges when the whole modem was enabled."""
    out = {"enabled_count": len(mask.enabled), "unsupported": mask.unsupported,
           "failed_count": len(mask.failed), "ranges": mask.ranges}
    if len(mask.enabled) <= 96:
        out["enabled"] = mask.enabled
        out["failed"] = mask.failed
    else:
        by_equip = {}
        for code in mask.enabled:
            by_equip[code >> 12] = by_equip.get(code >> 12, 0) + 1
        out["enabled_by_equip"] = {"0x%X" % k: v for k, v in sorted(by_equip.items())}
    return out


def run(transport: Transport, sinks: list, decoder: Optional[Decoder] = None,
        session: Optional[Session] = None, raw_sink=None, options: Optional[RunOptions] = None,
        stop: Optional[Callable[[], bool]] = None, log: Callable[[str], None] = lambda s: None,
        observer: Optional[Callable[[object], None]] = None) -> RunResult:
    """Drive one capture (or one replay) to completion.

    `observer` sees every decoded object (DecodedMessage or CellInfo) as it is
    produced, for live event detection and displays. A transport that dies
    mid-stream (the phone was unplugged) ends the run with stopped_by =
    "unplugged" rather than an exception, so the files are still finished.
    """
    options = options or RunOptions()
    decoder = decoder or Decoder()
    multi = MultiSink(sinks)
    result = RunResult()
    client = DiagClient(transport, raw_sink=raw_sink)
    started = time.monotonic()
    last_progress = started
    # Opening is the caller's problem: a port that will not open (busy, gone,
    # no driver) is an error worth showing. Everything after it happens with a
    # phone that could be unplugged at any moment, so from here on a dead
    # transport ends the session tidily instead of raising.
    transport.open()
    setup_failed = False
    try:
        if transport.interactive:
            try:
                info = client.probe()
                result.modem = info.as_dict()
                if info.build_id or info.version_dir:
                    log("modem: %s" % (info.build_id or info.version_dir))
                else:
                    log("modem did not answer the version query (continuing; is this really a diag port?)")
                if options.quiet_modem:
                    client.quiet()
                if options.codes:
                    mask = client.configure_logs(options.codes)
                elif options.profile == ALL_PROFILE:
                    mask = client.configure_all_logs()
                else:
                    mask = client.configure_logs(profile_codes(options.profile))
            except TransportError as exc:
                setup_failed = True
                result.stopped_by = "unplugged"
                result.error = str(exc)
                log("transport gone while configuring the modem (%s)" % exc)
            if not setup_failed:
                result.log_mask = _mask_summary(mask)
                log("log mask: %d codes enabled, %d unsupported, %d failed"
                    % (len(mask.enabled), len(mask.unsupported), len(mask.failed)))
                if not mask.enabled:
                    raise DiagError("the modem accepted none of the requested log codes")

        def should_stop() -> bool:
            if stop is not None and stop():
                result.stopped_by = "user"
                return True
            if options.max_seconds is not None and time.monotonic() - started >= options.max_seconds:
                result.stopped_by = "time"
                return True
            if options.max_records is not None and result.records >= options.max_records:
                result.stopped_by = "records"
                return True
            return False

        # Even when setup failed, records the modem already pushed are sitting in
        # the client's queue. stream() drains that queue before it consults stop(),
        # so this keeps them instead of throwing away a partial capture.
        stream = client.stream(stop=(lambda: True) if setup_failed else should_stop)
        try:
            for rec in stream:
                result.records += 1
                for obj in decoder.decode(rec):
                    if session is not None:
                        session.observe(obj)
                    if observer is not None:
                        observer(obj)
                    if isinstance(obj, DecodedMessage):
                        multi.write(obj)
                        result.messages += 1
                    elif isinstance(obj, DiagRecord):
                        multi.write(obj)
                        result.diag_records += 1
                    else:
                        result.cell_info += 1
                now = time.monotonic()
                if now - last_progress >= options.progress_every:
                    last_progress = now
                    log("%d records, %d messages, %d crc errors"
                        % (result.records, result.messages, client.unframer.crc_errors))
                if should_stop():
                    break
        except TransportError as exc:
            if not transport.interactive:
                raise
            result.stopped_by = "unplugged"
            result.error = str(exc)
            log("transport gone (%s): finishing the session" % exc)
    except KeyboardInterrupt:
        result.stopped_by = "interrupt"
    finally:
        try:
            multi.flush()
        except Exception:
            pass
        try:
            client.close()
        except Exception:
            pass
        multi.close()
    result.seconds = time.monotonic() - started
    result.client_stats = dict(client.stats)
    result.framing = _framing_stats(client.unframer)
    result.decoder = decoder.report()
    result.sinks = multi.report()
    return result


def replay_dlf(path: str, sinks: list, decoder: Optional[Decoder] = None,
               session: Optional[Session] = None,
               observer: Optional[Callable[[object], None]] = None) -> RunResult:
    """Decode a QXDM-style .dlf (bare log entries, no HDLC)."""
    decoder = decoder or Decoder()
    multi = MultiSink(sinks)
    result = RunResult()
    started = time.monotonic()
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        for rec in iter_log_entries(data):
            result.records += 1
            for obj in decoder.decode(rec):
                if session is not None:
                    session.observe(obj)
                if observer is not None:
                    observer(obj)
                if isinstance(obj, DecodedMessage):
                    multi.write(obj)
                    result.messages += 1
                elif isinstance(obj, DiagRecord):
                    multi.write(obj)
                    result.diag_records += 1
                else:
                    result.cell_info += 1
    finally:
        multi.close()
    result.seconds = time.monotonic() - started
    result.decoder = decoder.report()
    result.sinks = multi.report()
    return result


def replay(path: str, sinks: list, decoder: Optional[Decoder] = None,
           session: Optional[Session] = None, log: Callable[[str], None] = lambda s: None,
           observer: Optional[Callable[[object], None]] = None) -> RunResult:
    """Decode a recorded capture: .qmdl (HDLC stream) or .dlf (log entries)."""
    ext = os.path.splitext(path)[1].lower()
    if ext == ".dlf":
        return replay_dlf(path, sinks, decoder, session, observer=observer)
    return run(FileTransport(path), sinks, decoder, session, options=RunOptions(), log=log,
               observer=observer)
