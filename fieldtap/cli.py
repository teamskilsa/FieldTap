"""The `fieldtap` command."""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from typing import Optional

from . import __version__

DEFAULT_CAPTURES = os.environ.get("FIELDTAP_CAPTURES", "captures")


def _log(text: str) -> None:
    sys.stderr.write("[fieldtap %s] %s\n" % (time.strftime("%H:%M:%S"), text))
    sys.stderr.flush()


def _parse_codes(text: Optional[str]) -> Optional[list]:
    if not text:
        return None
    codes = []
    for item in text.split(","):
        item = item.strip()
        if not item:
            continue
        codes.append(int(item, 16) if item.lower().startswith("0x") else int(item, 0))
    return codes


def _hostport(text: str, default_port: int):
    host, _, port = text.rpartition(":")
    if not host:
        return text, default_port
    return host, int(port)


# --- commands ---------------------------------------------------------------------------

def cmd_version(args) -> int:
    print("fieldtap %s" % __version__)
    return 0


def cmd_devices(args) -> int:
    from .diag import transport as tr
    print("serial ports")
    ports = tr.list_serial_ports()
    if not ports:
        print("  (none, or pyserial not installed)")
    for p in ports:
        flag = "  <- looks like a diag port" if p.likely_diag else ""
        vidpid = " [%04X:%04X]" % (p.vid, p.pid) if p.vid is not None else ""
        vendor = tr.vendor_name(p.vid)
        if vendor:
            vidpid += " %s" % vendor
        print("  %-12s %s%s%s" % (p.device, p.description, vidpid, flag))
    print("usb diag interfaces")
    devices = tr.list_usb_diag_devices()
    if not devices:
        print("  (none visible to libusb, or pyusb not installed)")
    for d in devices:
        print("  %04X:%04X bus %s addr %s interface %d (ep in 0x%02X out 0x%02X)"
              % (d["vid"], d["pid"], d["bus"], d["address"], d["interface"], d["ep_in"], d["ep_out"]))
    print("adb devices")
    adb = tr.adb_devices()
    if not adb:
        print("  (none, or adb not on PATH)")
    for d in adb:
        print("  %-24s %-12s %s" % (d["serial"], d["state"], d["info"]))
    return 0


def cmd_enable_diag(args) -> int:
    from .diag import transport as tr
    try:
        state = tr.adb_enable_diag_usb(args.serial)
    except tr.TransportError as exc:
        _log(str(exc))
        return 2
    print("usb state: %s" % state)
    print("now run: fieldtap devices   (then capture with --port or --usb)")
    return 0


def cmd_disable_diag(args) -> int:
    from .diag import transport as tr
    try:
        tr.adb_disable_diag_usb(args.serial, args.config)
    except tr.TransportError as exc:
        _log(str(exc))
        return 2
    print("usb config restored to %s" % args.config)
    return 0


def _build_transport(args):
    from .diag import transport as tr
    if args.port:
        return tr.SerialTransport(args.port, args.baud)
    if args.usb:
        return tr.UsbTransport(_parse_int(args.vid), _parse_int(args.pid), args.interface)
    if args.tcp:
        host, port = _hostport(args.tcp, 2500)
        return tr.TcpTransport(host, port)
    if args.adb:
        return tr.AdbTransport(args.serial, args.helper, args.adb_port, args.remote)
    if args.file:
        return tr.FileTransport(args.file, realtime=args.realtime)
    return None


def _parse_int(text: Optional[str]) -> Optional[int]:
    return int(text, 0) if text else None


def cmd_capture(args) -> int:
    from . import pipeline
    from .decode import Decoder
    from .diag import transport as tr
    from .output.sinks import GsmtapPcapSink, GsmtapUdpSink, PcapngSink, WiresharkLiveSink
    from .session import Session
    from .tshark import find_wireshark

    transport = _build_transport(args)
    if transport is None:
        _log("choose a source: --port COMx | --usb | --tcp host:port | --adb | --file capture.qmdl")
        return 2
    session = Session(args.captures, args.name, args.note, args.location)
    _log("session %s" % session.dir)
    sinks = []
    files = {}
    if args.format in ("wireshark", "both"):
        sinks.append(PcapngSink(session.pcapng_path, comment="FieldTap session %s" % session.name))
        files["pcapng"] = session.pcapng_path
    if args.format in ("gsmtap", "both"):
        sinks.append(GsmtapPcapSink(session.gsmtap_path))
        files["gsmtap_pcap"] = session.gsmtap_path
    if args.udp:
        host, port = _hostport(args.udp, 4729)
        sinks.append(GsmtapUdpSink(host, port))
        _log("streaming GSMTAP (LTE) to udp://%s:%d" % (host, port))
    if args.live:
        wireshark = find_wireshark()
        if not wireshark:
            _log("--live: Wireshark not found; continuing without the live window")
        else:
            sinks.append(WiresharkLiveSink(wireshark))
            _log("live view: Wireshark started, reading from FieldTap")
    raw = None
    if not args.no_raw and transport.interactive:
        raw = open(session.raw_path, "wb")
        files["raw"] = session.raw_path
    handset = tr.adb_getprops(args.serial) if (args.adb or args.handset_info) and tr.adb_path() else {}
    if handset:
        _log("handset: %s %s (%s)" % (handset.get("manufacturer", ""), handset.get("model", ""), handset.get("baseband", "")))
    options = pipeline.RunOptions(profile=args.profile, codes=_parse_codes(args.codes),
                                  quiet_modem=not args.keep_debug, max_seconds=args.seconds,
                                  max_records=args.records)
    stop_flag = threading.Event()

    def stop() -> bool:
        return stop_flag.is_set()

    if transport.interactive and args.seconds is None and args.records is None:
        _log("capturing; press Ctrl-C to stop")
    decoder = Decoder()
    try:
        result = pipeline.run(transport, sinks, decoder, session, raw_sink=raw, options=options,
                              stop=stop, log=_log)
    except tr.TransportError as exc:
        _log("transport: %s" % exc)
        if raw:
            raw.close()
        return 2
    except Exception as exc:  # DiagError and friends
        _log("capture failed: %s" % exc)
        if raw:
            raw.close()
        return 2
    if raw:
        raw.close()
    session.finish(transport.describe(), handset, result.modem, args.profile if not args.codes else "custom",
                   result.log_mask, result.client_stats, result.framing, result.decoder, result.sinks, files)
    _log("stopped (%s): %d records, %d messages, %d cell-info records in %.1f s"
         % (result.stopped_by, result.records, result.messages, result.cell_info, result.seconds))
    if result.framing.get("crc_errors"):
        _log("framing: %d crc errors" % result.framing["crc_errors"])
    if result.decoder["unknown_codes"]:
        _log("unknown log codes: %s" % ", ".join(result.decoder["unknown_codes"]))
    if result.decoder["layout_sources"].get("probed") or result.decoder["layout_sources"].get("forced"):
        _log("layout note: %s  (new packet versions? keep the .qmdl, see docs/CORPUS.md)"
             % result.decoder["layout_sources"])
    _log("files: %s" % ", ".join(os.path.basename(p) for p in files.values()))
    _log("sidecar: %s" % session.sidecar_path)
    return 0 if result.messages or not transport.interactive else 1


def cmd_decode(args) -> int:
    from . import pipeline
    from .decode import Decoder
    from .output.sinks import GsmtapPcapSink, PcapngSink
    from .session import Session

    if not os.path.isfile(args.input):
        _log("no such file: %s" % args.input)
        return 2
    base = os.path.splitext(args.input)[0]
    session = None
    sinks = []
    outputs = []
    if args.session_dir:
        session = Session(os.path.dirname(args.session_dir) or ".", os.path.basename(args.session_dir),
                          directory=args.session_dir)
        pcapng_path, gsmtap_path = session.pcapng_path, session.gsmtap_path
    else:
        pcapng_path = args.output or base + ".pcapng"
        gsmtap_path = (args.output or base) + "_gsmtap.pcap" if args.output else base + "_gsmtap.pcap"
    if args.format in ("wireshark", "both"):
        sinks.append(PcapngSink(pcapng_path, comment="FieldTap decode of %s" % os.path.basename(args.input)))
        outputs.append(pcapng_path)
    if args.format in ("gsmtap", "both"):
        sinks.append(GsmtapPcapSink(gsmtap_path))
        outputs.append(gsmtap_path)
    decoder = Decoder()
    result = pipeline.replay(args.input, sinks, decoder, session, log=_log)
    if session is not None:
        session.finish({"transport": "file", "path": args.input}, {}, {}, None, {}, result.client_stats,
                       result.framing, result.decoder, result.sinks, {"pcapng": pcapng_path})
    _log("%d records -> %d messages, %d cell-info records, %d other records kept"
         % (result.records, result.messages, result.cell_info, result.diag_records))
    if result.framing.get("crc_errors"):
        _log("framing: %d crc errors" % result.framing["crc_errors"])
    _log_coverage(result.decoder.get("coverage", {}))
    if result.decoder["errors"]:
        _log("decoder notes: %s" % result.decoder["errors"])
    for path in outputs:
        print(path)
    return 0 if (result.messages or result.diag_records) else 1


def _log_coverage(coverage: dict) -> None:
    """What every log code in the capture became in the pcap. Nothing is dropped:
    a code with no layout is still written, as bytes, under the fieldtap-diag wrapper."""
    if not coverage:
        return
    _log("coverage (every record is in the pcap; 'raw' = no layout, bytes only):")
    for code, row in coverage.items():
        ways = ", ".join("%s %d" % (k, v) for k, v in sorted(row["as"].items()))
        _log("  %s  %-48s %6d  %s" % (code, row["name"][:48], row["records"], ways))
    raw_codes = [c for c, r in coverage.items() if set(r["as"]) == {"raw"}]
    if raw_codes:
        _log("  %d code(s) have no layout yet; the Wireshark plugin (wireshark/fieldtap.lua) shows their bytes"
             % len(raw_codes))


def _mmss(seconds: float) -> str:
    minutes, rest = divmod(round(abs(seconds)), 60)
    return "%s%d:%02d" % ("-" if seconds < 0 else "", minutes, rest)


def cmd_qdss(args) -> int:
    """An iPhone sysdiagnose (or one of its log-bb-*-qdss folders) -> the .qmdl every other command reads."""
    import tempfile
    from .diag import qdss

    source = args.input
    workdir = None
    pressed = None
    try:
        if os.path.isdir(source):
            paths = qdss.chunk_paths(source)
        elif os.path.isfile(source):
            workdir = args.workdir or tempfile.mkdtemp(prefix="fieldtap-qdss-")
            paths, info = qdss.chunks_from_sysdiagnose(source, workdir)
            if info["appledouble_skipped"]:
                _log("skipped %d AppleDouble ('._') entries" % info["appledouble_skipped"])
            pressed = qdss.pressed_at(source)
            installed, removal = qdss.profile_dates(info["profile_stub"]) if info["profile_stub"] else (None, None)
            if removal is not None:
                lapsed = pressed is not None and removal < pressed
                _log("Baseband logging profile: installed %s, %s %s" % (
                    installed.strftime("%Y-%m-%d %H:%M UTC") if installed else "?",
                    "had expired on" if lapsed else "until", removal.strftime("%Y-%m-%d %H:%M UTC")))
            if info["trace_dir"] is None:
                if not info["profile_stub"]:
                    _log("no modem trace in this archive: modem logging is off (no Baseband logging profile). "
                         "Install Apple's profile, then take a new sysdiagnose")
                elif removal is not None and pressed is not None and removal < pressed:
                    _log("no modem trace in this archive: the logging profile had expired. Install it again, "
                         "then take a new sysdiagnose")
                else:
                    _log("no modem trace in this archive although the profile is installed: restart the iPhone "
                         "and take a new sysdiagnose")
                return 1
            _log("trace %s" % info["trace_dir"])
        else:
            _log("no such file or folder: %s" % source)
            return 2
        if not paths:
            _log("no trace chunks (0x*.bin) in %s" % source)
            return 1
        _log("%d chunks, deframing" % len(paths))
        result = qdss.deframe_chunks(paths)
    finally:
        if workdir is not None and not args.keep_chunks:
            qdss.remove_workdir(workdir)
    qdss.write_qmdl(result.records, args.output)
    if args.stats:
        with open(args.stats, "w") as fh:
            json.dump(result.stats, fh, indent=1)
    _log("%d log records (%d codes), %d encrypted by the modem and left out"
         % (len(result.records), result.stats["distinct_codes"], len(result.secure)))
    window = qdss.trace_window(result.records, pressed) if os.path.isfile(source) and pressed else None
    if window:
        _log("the trace covers %s to %s after the buttons were pressed (timing from early tests: press first, "
             "then reproduce the problem 20 to 40 s later)" % (_mmss(window[0]), _mmss(window[1])))
    print(args.output)
    return 0 if result.records else 1


def cmd_info(args) -> int:
    from . import info
    try:
        report = info.inspect(args.file)
    except (OSError, ValueError) as exc:
        _log(str(exc))
        return 2
    if args.json:
        print(json.dumps(report, indent=2, default=str))
    else:
        print(info.render(report))
    return 0


def cmd_flow(args) -> int:
    from . import flow
    events = flow.load_events(args.file, use_tshark=not args.no_tshark)
    text = flow.render(events, args.format, args.width)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        _log("wrote %s (%d messages)" % (args.output, len(events)))
    else:
        print(text)
    return 0


def cmd_kpi(args) -> int:
    from . import kpi
    try:
        rows = kpi.extract(args.file)
    except RuntimeError as exc:
        _log(str(exc))
        return 2
    text = kpi.to_csv(rows)
    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        _log("wrote %s (%d measurement rows)" % (args.output, len(rows)))
    else:
        sys.stdout.write(text)
    return 0


def cmd_sessions(args) -> int:
    from .session import list_sessions
    sessions = list_sessions(args.captures)
    if not sessions:
        print("no sessions under %s" % args.captures)
        return 0
    print("%-26s %-20s %-8s %-14s %s" % ("started (UTC)", "name", "msgs", "plmn", "handset / note"))
    for s in sessions:
        print("%-26s %-20s %-8d %-14s %s" % ((s["started_utc"] or "")[:19], (s["name"] or "")[:20], s["messages"],
                                              s["plmns"][:14], " ".join(x for x in (s["handset"], s["note"]) if x)))
    return 0


def cmd_logcodes(args) -> int:
    from .decode.registry import LOG_CODES, PROFILES, profile_codes
    codes = profile_codes(args.profile) if args.profile else sorted(LOG_CODES)
    print("%-8s %-4s %-6s %-8s %-10s %s" % ("code", "rat", "cat", "decoder", "confidence", "name"))
    for code in codes:
        i = LOG_CODES[code]
        print("%-8s %-4s %-6s %-8s %-10s %s%s" % ("0x%04X" % code, i.rat, i.category, i.decoder or "-",
                                                i.confidence, i.name, ("  [%s]" % i.note) if i.note else ""))
    print("\nprofiles: %s" % ", ".join("%s (%d)" % (k, len(v)) for k, v in sorted(PROFILES.items())))
    return 0


def cmd_selftest(args) -> int:
    from . import selftest
    report = selftest.run(args.keep)
    print(report.render())
    return 0 if report.passed else 1


def cmd_fixtures(args) -> int:
    from . import fixtures
    paths = fixtures.write_fixture_files(args.directory)
    for kind, path in paths.items():
        print("%s: %s" % (kind, path))
    return 0


def _add_auto_arguments(p) -> None:
    src = p.add_argument_group("handsets")
    src.add_argument("--simulate", action="append", metavar="QMDL",
                     help="stand in a recorded .qmdl for a handset (repeatable: several files = several phones)")
    src.add_argument("--no-enable-diag", action="store_true", help="never touch the phone's USB config; only use ports that already exist")
    src.add_argument("--once", action="store_true", help="exit after the first handset finishes")
    src.add_argument("--poll", type=float, default=2.0, help="seconds between USB scans")
    out = p.add_argument_group("output")
    out.add_argument("--captures", default=DEFAULT_CAPTURES, help="sessions root (default: %(default)s)")
    out.add_argument("--name", help="session name (default: handset model + serial)")
    out.add_argument("--note")
    out.add_argument("--location")
    out.add_argument("--gsmtap", action="store_true", help="also write the classic GSMTAP pcap (LTE only)")
    out.add_argument("--live", action="store_true", help="open a Wireshark window per handset and stream into it")
    out.add_argument("--no-raw", action="store_true", help="do not keep the raw .qmdl")
    out.add_argument("--no-report", action="store_true")
    out.add_argument("--open-report", action="store_true", help="open report.html in the browser when a session ends")
    logs = p.add_argument_group("logs")
    logs.add_argument("--profile", default="signalling", help="signalling (default), lte, nr, corpus, or all")
    logs.add_argument("--codes", help="explicit log codes, e.g. 0xB821,0xB0C0")
    logs.add_argument("--keep-debug", action="store_true")
    logs.add_argument("--seconds", type=float, help="stop each session after N seconds")
    side = p.add_argument_group("gps and traffic")
    side.add_argument("--gps", default="auto",
                      help="auto (phone via adb when available), adb, none, or nmea:PORT[@baud] "
                           "where PORT is COM7, /dev/ttyUSB0 or /dev/cu.usbserial-XXXX")
    side.add_argument("--gps-interval", type=float, default=5.0)
    side.add_argument("--traffic", help="comma list of ping,download,iperf3 to run on the phone during capture")
    side.add_argument("--traffic-interval", type=float, default=60.0)
    side.add_argument("--ping-host", default="8.8.8.8")
    side.add_argument("--download-url", default=None, help="URL for the download test (default: a 25 MB Cloudflare test file)")
    side.add_argument("--iperf-server", help="iperf3 server for the iperf3 test (needs iperf3 pushed to the phone)")


def cmd_auto(args) -> int:
    from . import auto, traffic as traffic_mod
    options = auto.AutoOptions(
        captures=args.captures, profile=args.profile, codes=_parse_codes(args.codes), gsmtap=args.gsmtap,
        live=args.live, keep_raw=not args.no_raw, report=not args.no_report, open_report=args.open_report,
        gps=args.gps, gps_interval=args.gps_interval,
        traffic=[t.strip() for t in (args.traffic or "").split(",") if t.strip()],
        traffic_interval=args.traffic_interval, ping_host=args.ping_host,
        download_url=args.download_url or traffic_mod.DEFAULT_DOWNLOAD_URL, iperf_server=args.iperf_server,
        max_seconds=args.seconds, poll=args.poll, once=args.once, simulate=args.simulate or [],
        name=args.name, note=args.note, location=args.location, enable_diag=not args.no_enable_diag,
        keep_debug=args.keep_debug)
    workers = auto.run(options, _log)
    if workers:
        print("\n".join(auto.summarize(workers)))
    failed = [w for w in workers if w.state in ("failed",)]
    done = [w for w in workers if w.state == "done"]
    return 0 if done and not failed else (1 if workers else 0)


def cmd_report(args) -> int:
    from . import report
    if args.index:
        path = report.build_index(args.target, _log)
        print(path)
        return 0
    session_dir = args.target
    if os.path.isfile(session_dir):
        session_dir = os.path.dirname(session_dir)
    if not os.path.isfile(os.path.join(session_dir, "session.json")):
        _log("not a session directory (no session.json): %s" % session_dir)
        return 2
    paths = report.build(session_dir, log=_log, rebuild=args.rebuild, open_after=args.open)
    print(paths["report"])
    return 0


def _print_safe(text: str) -> None:
    """print(), without dying on a console that cannot encode the text."""
    encoding = getattr(sys.stdout, "encoding", None) or "utf-8"
    print(text.encode(encoding, "backslashreplace").decode(encoding, "replace"))


def cmd_validate(args) -> int:
    """Check a session directory, or an upload bundle, against fieldtap-session/1."""
    from . import contract
    target = args.target
    if os.path.isdir(target):
        kind = "session"
        problems = contract.validate_session(target, upload=args.upload)
    elif os.path.isfile(target) and target.lower().endswith(".zip"):
        kind = "bundle"
        problems = contract.validate_bundle(target)
    else:
        _log("not a session directory or a .zip bundle: %s" % target)
        return 2
    errors = sum(1 for p in problems if p.severity == contract.ERROR)
    warnings = len(problems) - errors
    if args.json:
        print(json.dumps({"target": target, "kind": kind, "format": contract.FORMAT, "errors": errors,
                          "warnings": warnings, "problems": [p.to_dict() for p in problems]}, indent=2))
    else:
        for problem in problems:
            _print_safe(str(problem))
    _log("%s %s: %d error(s), %d warning(s)" % (kind, target, errors, warnings))
    return 1 if errors else 0


def cmd_events(args) -> int:
    from . import events as events_mod
    det = events_mod.from_pcapng(args.file)
    evs = det.events
    if not args.no_tshark:
        events_mod.enrich_with_tshark(evs, args.file)
    if not args.all:
        evs = [e for e in evs if e.kind not in events_mod.LOW_PRIORITY]
    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="") as fh:
            fh.write(events_mod.to_csv(evs))
        _log("wrote %s (%d events)" % (args.output, len(evs)))
    else:
        for e in evs:
            print("%s %-4s %-6s %s%s" % (e.when_iso[11:23] if e.when_iso else "            ", e.rat.upper(), e.severity,
                                         e.title, ("  [%s]" % e.detail) if e.detail else ""))
        s = det.summary()
        print("\n%d events, %d errors, %d warnings, %d handovers" % (s["events"], s["errors"], s["warnings"], s["handovers"]))
    return 0


def cmd_scan(args) -> int:
    """Cells and operators from the Android telephony layer: no root, no diag."""
    from . import scan as scan_mod
    from .diag import transport as tr
    if not tr.adb_path():
        _log("adb is not installed: run `fieldtap setup --install-adb`")
        return 2
    serial = args.serial
    if serial is None:
        devices = [d for d in tr.adb_devices() if d["state"] == "device"]
        if not devices:
            _log("no phone in 'device' state; `fieldtap devices` shows what adb sees")
            return 2
        serial = devices[0]["serial"]
    if args.operators:
        if scan_mod.sim_state(serial) == "ABSENT":
            _log("note: no SIM. The modem can still search, but some builds refuse a manual")
            _log("      network search without one. If nothing appears, insert any SIM.")
        scan_mod.clear_radio_log(serial)
        scan_mod.request_operator_search(serial)
        _log("the phone is running a PLMN search across the bands it supports; this takes a minute")
        screen = scan_mod.read_operator_list(serial, log=_log)
        radio, raw_lines = scan_mod.read_radio_scan_log(serial)
        if radio:
            print("operators found (from the phone's radio log):")
            for name, short, plmn, state in radio:
                print("  %-24s %-8s %s" % (name, plmn, state))
        if screen:
            print("")
            print("read from the network-selection screen:")
            for item in screen:
                print("  %s%s" % (item, "   <- PLMN code" if scan_mod.looks_like_plmn(item) else ""))
        if not radio and not screen:
            _log("no operator list could be read.")
            if scan_mod.sim_state(serial) == "ABSENT":
                _log("the phone has no SIM, and many builds grey out manual network search")
                _log("without one. Insert any SIM and run this again.")
            if raw_lines:
                _log("radio log did mention a scan; last lines:")
                for line in raw_lines[-5:]:
                    _log("  " + line[:160])
            return 1
        return 0

    if args.full:
        _log("sweeping for %.0f s, forcing the modem to re-select between samples" % args.full)
        cells = scan_mod.sweep(serial, args.full, log=lambda t: print(t, flush=True))
        print("")
        print(scan_mod.render(cells, {}, scan_mod.sim_state(serial)))
        if args.output and cells:
            with open(args.output, "w", encoding="utf-8", newline="") as fh:
                fh.write(scan_mod.to_csv(cells))
            _log("wrote %s (%d cells)" % (args.output, len(cells)))
        return 0 if cells else 1
    if args.watch:
        _log("sampling every %.0f s; Ctrl-C to stop" % args.watch)
        history = scan_mod.watch(serial, args.watch, args.seconds, log=lambda t: print(t, flush=True))
        if args.output and history:
            with open(args.output, "w", encoding="utf-8", newline="") as fh:
                fh.write(scan_mod.to_csv(history))
            _log("wrote %s (%d samples)" % (args.output, len(history)))
        return 0
    cells, state = scan_mod.snapshot(serial)
    print(scan_mod.render(cells, state, scan_mod.sim_state(serial)))
    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="") as fh:
            fh.write(scan_mod.to_csv(cells))
        _log("wrote %s" % args.output)
    return 0 if cells else 1


def cmd_demo(args) -> int:
    """Generate a simulated drive test and take it through the whole product."""
    from . import auto, demo
    directory = args.directory or os.path.join(args.captures, "_demo")
    os.makedirs(directory, exist_ok=True)
    qmdl = os.path.join(directory, "simulated_drive.qmdl")
    profile = demo.DriveProfile(seconds=args.seconds)
    demo.write_qmdl(qmdl, profile)
    _log("wrote a simulated %.0f s drive test: %s (%d bytes)" % (args.seconds, qmdl, os.path.getsize(qmdl)))
    _log("NOTE: this is generated data, not a handset capture. The report is labelled SIMULATED.")
    options = auto.AutoOptions(captures=args.captures, simulate=[qmdl], name=args.name or "simulated-drive",
                               note="Simulated drive test generated by `fieldtap demo` - not a real capture.",
                               location=args.location, open_report=not args.no_open, gsmtap=args.gsmtap)
    workers = auto.run(options, _log)
    print("\n".join(auto.summarize(workers)))
    return 0 if workers and workers[0].state == "done" else 1


def cmd_setup(args) -> int:
    from . import setup as setup_mod
    return setup_mod.run(install_adb=args.install_adb, log=print)


# --- parser ---------------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fieldtap",
                                     description="Qualcomm handset -> diag -> RRC/NAS -> Wireshark.")
    parser.add_argument("--version", action="version", version="fieldtap %s" % __version__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("devices", help="list serial ports, USB diag interfaces and adb devices")
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("enable-diag", help="switch a rooted handset's USB config to expose diag (via adb)")
    p.add_argument("--serial", help="adb device serial")
    p.set_defaults(func=cmd_enable_diag)

    p = sub.add_parser("disable-diag", help="restore the handset's normal USB config (via adb)")
    p.add_argument("--serial")
    p.add_argument("--config", default="mtp,adb")
    p.set_defaults(func=cmd_disable_diag)

    p = sub.add_parser("capture", help="capture from a handset into a session directory")
    src = p.add_argument_group("source")
    src.add_argument("--port", help="serial port of the Qualcomm diag interface (COM5, /dev/ttyUSB0)")
    src.add_argument("--baud", type=int, default=115200)
    src.add_argument("--usb", action="store_true", help="raw USB diag interface via libusb")
    src.add_argument("--vid", help="USB vendor id filter, e.g. 0x2A70")
    src.add_argument("--pid", help="USB product id filter")
    src.add_argument("--interface", type=int, help="USB interface number")
    src.add_argument("--tcp", help="diag relay host:port")
    src.add_argument("--adb", action="store_true", help="rooted handset via adb + fieldtap-diagd helper")
    src.add_argument("--serial", help="adb device serial")
    src.add_argument("--helper", help="local fieldtap-diagd binary to push to the handset")
    src.add_argument("--adb-port", type=int, default=45299)
    src.add_argument("--remote", help="helper --remote value for modems on a remote processor (mdm)")
    src.add_argument("--file", help="replay a .qmdl instead of a handset")
    src.add_argument("--realtime", action="store_true", help="pace file replay")
    out = p.add_argument_group("output")
    out.add_argument("--captures", default=DEFAULT_CAPTURES, help="sessions root (default: %(default)s)")
    out.add_argument("--name", help="session name")
    out.add_argument("--note", help="free text for the sidecar")
    out.add_argument("--location", help="where the capture was taken")
    out.add_argument("--format", choices=("wireshark", "gsmtap", "both"), default="wireshark",
                     help="pcapng exported-PDU (all RATs) and/or classic GSMTAP pcap (LTE only)")
    out.add_argument("--live", action="store_true", help="open Wireshark and stream into it")
    out.add_argument("--udp", help="also send GSMTAP datagrams to host:port (LTE only)")
    out.add_argument("--no-raw", action="store_true", help="do not keep the raw .qmdl")
    out.add_argument("--handset-info", action="store_true", help="query adb getprop for the sidecar")
    logs = p.add_argument_group("logs")
    logs.add_argument("--profile", default="signalling",
                      help="log profile: signalling, lte, nr, corpus, or all (every code the modem reports)")
    logs.add_argument("--codes", help="explicit log codes, e.g. 0xB821,0xB0C0")
    logs.add_argument("--keep-debug", action="store_true", help="do not silence modem debug messages")
    logs.add_argument("--seconds", type=float, help="stop after N seconds")
    logs.add_argument("--records", type=int, help="stop after N log records")
    p.set_defaults(func=cmd_capture)

    p = sub.add_parser("decode", help="decode a recorded .qmdl / .dlf into pcapng")
    p.add_argument("input")
    p.add_argument("-o", "--output", help="pcapng path (default: next to the input)")
    p.add_argument("--format", choices=("wireshark", "gsmtap", "both"), default="wireshark")
    p.add_argument("--session-dir", help="also write a session sidecar into this directory")
    p.set_defaults(func=cmd_decode)

    p = sub.add_parser("qdss", help="rebuild a .qmdl from an iPhone sysdiagnose's baseband (QDSS) trace")
    p.add_argument("input", help="sysdiagnose_*.tar.gz, or a logs/Baseband/log-bb-*-qdss folder")
    p.add_argument("-o", "--output", required=True, help="the .qmdl to write")
    p.add_argument("--stats", help="also write the deframer's counters as JSON")
    p.add_argument("--workdir", help="where the trace chunks are unpacked (default: a temporary folder)")
    p.add_argument("--keep-chunks", action="store_true",
                   help="keep the unpacked chunks; they hold subscriber identifiers")
    p.set_defaults(func=cmd_qdss)

    p = sub.add_parser("info", help="summarise a .qmdl, .dlf or .pcapng")
    p.add_argument("file")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("flow", help="call-flow ladder from a FieldTap pcapng")
    p.add_argument("file")
    p.add_argument("--format", choices=("text", "mermaid", "csv"), default="text")
    p.add_argument("--width", type=int, default=100)
    p.add_argument("--no-tshark", action="store_true", help="do not ask tshark for Info text")
    p.add_argument("-o", "--output")
    p.set_defaults(func=cmd_flow)

    p = sub.add_parser("kpi", help="RSRP/RSRQ/SINR timeline from the decoded signalling (needs tshark)")
    p.add_argument("file")
    p.add_argument("-o", "--output")
    p.set_defaults(func=cmd_kpi)

    p = sub.add_parser("sessions", help="list capture sessions")
    p.add_argument("--captures", default=DEFAULT_CAPTURES)
    p.set_defaults(func=cmd_sessions)

    p = sub.add_parser("logcodes", help="show the log-code register")
    p.add_argument("--profile")
    p.set_defaults(func=cmd_logcodes)

    p = sub.add_parser("selftest", help="verify the toolchain with a synthetic capture and Wireshark")
    p.add_argument("--keep", help="keep the generated files in this directory")
    p.set_defaults(func=cmd_selftest)

    p = sub.add_parser("fixtures", help="write the synthetic corpus files")
    p.add_argument("directory")
    p.set_defaults(func=cmd_fixtures)

    p = sub.add_parser("auto", help="plug-and-go: watch USB, capture every handset that appears, report on unplug")
    _add_auto_arguments(p)
    p.set_defaults(func=cmd_auto)

    p = sub.add_parser("report", help="build report.html + summary.json for a session directory")
    p.add_argument("target", help="session directory (or --index: captures root)")
    p.add_argument("--index", action="store_true", help="build index.html over a captures root instead")
    p.add_argument("--rebuild", action="store_true", help="recompute events and KPIs instead of reusing the CSVs")
    p.add_argument("--open", action="store_true")
    p.set_defaults(func=cmd_report)

    p = sub.add_parser("validate", help="check a session directory (or an upload .zip) against fieldtap-session/1")
    p.add_argument("target", help="session directory, or an upload bundle .zip")
    p.add_argument("--upload", action="store_true",
                   help="also require that the directory holds only the seven session files")
    p.add_argument("--json", action="store_true", help="print the problems as JSON")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("events", help="list the procedures and failures in a FieldTap pcapng")
    p.add_argument("file")
    p.add_argument("--all", action="store_true", help="include low-priority events (measurement reports, paging, SIB1)")
    p.add_argument("--no-tshark", action="store_true")
    p.add_argument("-o", "--output", help="write CSV instead of printing")
    p.set_defaults(func=cmd_events)

    p = sub.add_parser("scan", help="list nearby cells, operators and signal strength (no root, no diag)")
    p.add_argument("--serial", help="adb device serial")
    p.add_argument("--watch", type=float, metavar="SECONDS", help="keep sampling every N seconds")
    p.add_argument("--seconds", type=float, help="with --watch, stop after N seconds")
    p.add_argument("--operators", action="store_true",
                   help="run a real PLMN search and read the operator list off the phone screen")
    p.add_argument("--full", type=float, metavar="SECONDS", nargs="?", const=180.0,
                   help="sweep: sample repeatedly for N seconds (default 180), forcing the modem "
                        "to re-select in between, and report every cell seen")
    p.add_argument("-o", "--output", help="write the cells to CSV")
    p.set_defaults(func=cmd_scan)

    p = sub.add_parser("demo", help="generate a simulated drive test and produce a full report (no handset needed)")
    p.add_argument("--captures", default=DEFAULT_CAPTURES)
    p.add_argument("--directory", help="where to put the generated .qmdl (default: <captures>/_demo)")
    p.add_argument("--seconds", type=float, default=480.0, help="length of the simulated drive")
    p.add_argument("--name", help="session name")
    p.add_argument("--location", default="simulated route")
    p.add_argument("--gsmtap", action="store_true")
    p.add_argument("--no-open", action="store_true", help="do not open the report in a browser")
    p.set_defaults(func=cmd_demo)

    p = sub.add_parser("setup", help="check this machine (Wireshark, adb, drivers) and install what is missing")
    p.add_argument("--install-adb", action="store_true", help="download Google platform-tools into tools/")
    p.set_defaults(func=cmd_setup)

    p = sub.add_parser("version")
    p.set_defaults(func=cmd_version)
    return parser


def main(argv: Optional[list] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
