"""Session report: one self-contained HTML page per capture, a summary.json
for machines, and an index page over a captures directory.

Everything the page needs is inline (CSS, SVG charts), so it opens from a
USB stick with no network and no JavaScript dependencies. Inputs are the
files a session directory already holds: session.json, capture.pcapng,
cells.csv, and the optional events.csv, kpi.csv, track.csv and traffic.csv
that `fieldtap auto` writes. Missing ones are rebuilt where possible
(events from the pcapng, KPIs through tshark) and skipped otherwise.
"""

from __future__ import annotations

import csv
import html
import json
import math
import os
from datetime import datetime, timezone
from typing import Optional

from . import __version__
from . import events as events_mod
from . import flow as flow_mod
from . import gps as gps_mod
from . import kpi as kpi_mod
from . import traffic as traffic_mod
from . import tshark as tshark_mod
from .isotime import parse_iso
from .session import CELLS_FILE, PCAPNG_FILE, RAW_FILE, SIDE_CAR, list_sessions

EVENTS_FILE = "events.csv"
KPI_FILE = "kpi.csv"
TRACK_FILE = "track.csv"
TRAFFIC_FILE = "traffic.csv"
SUMMARY_FILE = "summary.json"
REPORT_FILE = "report.html"
INDEX_FILE = "index.html"

MAX_LADDER_LINES = 400
MAX_EVENT_ROWS = 600
# fieldtap.contract.FORMAT. A session that declares it is the Android app's: measurements only.
APP_FORMAT = "fieldtap-session/1"
# Event kinds a reader looks for in the table. When a session has more events than
# the table lists, these stay, with every error and warning, ahead of the rest.
KEEP_EVENT_KINDS = frozenset(["marker", "serving_cell", "rat_change", "service_lost", "emergency_only",
                              "service_restored", "sampling_gap", "gps_lost", "gps_restored", "test_failed",
                              "session_interrupted", "privacy_zone", "handover"])


# --- small helpers -----------------------------------------------------------------------------

def _read_csv(path: str) -> list:
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def _write_csv(path: str, rows: list, columns: list) -> None:
    with open(path, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=columns, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def _floats(text: str) -> list:
    out = []
    for item in (text or "").split(","):
        try:
            out.append(float(item))
        except ValueError:
            pass
    return out


def _fmt(value, digits: int = 1, unit: str = "") -> str:
    if value is None or value == "":
        return "-"
    if isinstance(value, float):
        return ("%%.%df%%s" % digits) % (value, unit)
    return "%s%s" % (value, unit)


def _iso_to_dt(text: Optional[str]) -> Optional[datetime]:
    if not text:
        return None
    try:
        return parse_iso(text)
    except ValueError:
        return None


def _haversine_km(a, b) -> float:
    r = 6371.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = p2 - p1
    dl = math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def _esc(text) -> str:
    return html.escape("" if text is None else str(text))


def _utc_text(value) -> str:
    """A *_utc value as yyyy-mm-dd HH:MM:SS in UTC, whatever offset it was written with."""
    when = _iso_to_dt(value) if isinstance(value, str) else None
    if when is not None and when.utcoffset() is not None:
        try:
            return when.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        except (OverflowError, ValueError):
            pass
    return value[:19].replace("T", " ") if isinstance(value, str) else ""


def _events_for_table(events: list, limit: int = MAX_EVENT_ROWS) -> tuple:
    """The events the report lists, in time order, and how many the limit left out.

    Low-priority signalling (measurement reports, paging, ...) is left out while
    anything else remains. Past the limit, errors, warnings and KEEP_EVENT_KINDS
    (markers, cell changes, failures) are kept first, then the other non-info
    events, then info events such as the 5G icon changing."""
    shown = [e for e in events if e.kind not in events_mod.LOW_PRIORITY] or list(events)
    if len(shown) <= limit:
        return shown, 0

    def rank(item):
        index, event = item
        if event.severity in ("error", "warn") or event.kind in KEEP_EVENT_KINDS:
            return 0, index
        return (2 if event.severity == "info" else 1), index

    kept = sorted(sorted(enumerate(shown), key=rank)[:limit], key=lambda item: item[0])
    return [event for _index, event in kept], len(shown) - limit


# --- SVG charts ------------------------------------------------------------------------------------

def svg_timeseries(series: list, y_label: str, y_min: float, y_max: float, x_max: float,
                   width: int = 940, height: int = 230, ref_lines: Optional[dict] = None) -> str:
    """series: [(label, colour, [(x_seconds, y)])]. Returns an <svg>."""
    left, right, top, bottom = 52, 16, 14, 34
    w, h = width - left - right, height - top - bottom
    x_max = max(x_max, 1.0)
    span = (y_max - y_min) or 1.0

    def sx(x):
        return left + w * (x / x_max)

    def sy(y):
        return top + h * (1 - (y - y_min) / span)

    parts = ['<svg class="chart" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg" role="img">' % (width, height)]
    parts.append('<rect x="%d" y="%d" width="%d" height="%d" fill="#fff" stroke="#d6d6d6"/>' % (left, top, w, h))
    for i in range(5):
        y = y_min + span * i / 4
        parts.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#eee"/>' % (left, sy(y), left + w, sy(y)))
        parts.append('<text x="%d" y="%.1f" font-size="10" text-anchor="end" fill="#666">%g</text>' % (left - 6, sy(y) + 3, y))
    for i in range(6):
        x = x_max * i / 5
        parts.append('<text x="%.1f" y="%d" font-size="10" text-anchor="middle" fill="#666">%s</text>'
                     % (sx(x), height - 14, _fmt_seconds(x)))
    parts.append('<text x="12" y="%d" font-size="10" fill="#444" transform="rotate(-90 12 %d)" text-anchor="middle">%s</text>'
                 % (top + h // 2, top + h // 2, _esc(y_label)))
    for label, value in (ref_lines or {}).items():
        if y_min <= value <= y_max:
            parts.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#c33" stroke-dasharray="4 3"/>' % (left, sy(value), left + w, sy(value)))
            parts.append('<text x="%d" y="%.1f" font-size="9" fill="#c33">%s</text>' % (left + 4, sy(value) - 3, _esc(label)))
    lx = left
    for label, colour, points in series:
        pts = [(sx(x), sy(max(y_min, min(y_max, y)))) for x, y in points]
        if len(pts) > 1:
            parts.append('<polyline fill="none" stroke="%s" stroke-width="1.5" points="%s"/>'
                         % (colour, " ".join("%.1f,%.1f" % p for p in pts)))
        for px, py in pts[:2000]:
            parts.append('<circle cx="%.1f" cy="%.1f" r="2" fill="%s"/>' % (px, py, colour))
        parts.append('<rect x="%d" y="%d" width="10" height="10" fill="%s"/><text x="%d" y="%d" font-size="10" fill="#333">%s</text>'
                     % (lx, 1, colour, lx + 13, 10, _esc(label)))
        lx += 16 + 6 * len(label) + 12
    parts.append("</svg>")
    return "".join(parts)


def _fmt_seconds(x: float) -> str:
    if x >= 3600:
        return "%dh%02dm" % (x // 3600, (x % 3600) // 60)
    if x >= 60:
        return "%dm%02ds" % (x // 60, x % 60)
    return "%ds" % x


def svg_bars(buckets: list, width: int = 940, height: int = 120, colour: str = "#4a78b5") -> str:
    """buckets: [(label, value)] -> bar chart."""
    if not buckets:
        return ""
    left, right, top, bottom = 52, 16, 8, 26
    w, h = width - left - right, height - top - bottom
    vmax = max(v for _l, v in buckets) or 1
    bw = w / len(buckets)
    parts = ['<svg class="chart" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg">' % (width, height),
             '<rect x="%d" y="%d" width="%d" height="%d" fill="#fff" stroke="#d6d6d6"/>' % (left, top, w, h),
             '<text x="%d" y="%d" font-size="10" text-anchor="end" fill="#666">%d</text>' % (left - 6, top + 8, vmax)]
    for i, (label, v) in enumerate(buckets):
        bh = h * v / vmax
        parts.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"><title>%s: %d</title></rect>'
                     % (left + i * bw, top + h - bh, max(bw - 1, 1), bh, colour, _esc(label), v))
        if len(buckets) <= 40 or i % max(1, len(buckets) // 12) == 0:
            parts.append('<text x="%.1f" y="%d" font-size="9" text-anchor="middle" fill="#666">%s</text>'
                         % (left + i * bw + bw / 2, height - 10, _esc(label)))
    parts.append("</svg>")
    return "".join(parts)


def svg_track(fixes: list, coloured: list, width: int = 460, height: int = 320) -> str:
    """A tile-free map: the GPS track as a path, with measurement points
    coloured by RSRP when available. coloured: [(lat, lon, rsrp or None)]."""
    if not fixes:
        return ""
    lats = [f.lat for f in fixes] + [c[0] for c in coloured]
    lons = [f.lon for f in fixes] + [c[1] for c in coloured]
    lat0, lat1, lon0, lon1 = min(lats), max(lats), min(lons), max(lons)
    pad_lat = (lat1 - lat0) * 0.08 or 0.0005
    pad_lon = (lon1 - lon0) * 0.08 or 0.0005
    lat0, lat1, lon0, lon1 = lat0 - pad_lat, lat1 + pad_lat, lon0 - pad_lon, lon1 + pad_lon
    scale_lon = math.cos(math.radians((lat0 + lat1) / 2)) or 1.0
    span_x = (lon1 - lon0) * scale_lon
    span_y = (lat1 - lat0)
    scale = min((width - 20) / (span_x or 1e-9), (height - 20) / (span_y or 1e-9))

    def pt(lat, lon):
        return 10 + (lon - lon0) * scale_lon * scale, height - 10 - (lat - lat0) * scale

    def colour(rsrp):
        if rsrp is None:
            return "#999"
        if rsrp >= -85:
            return "#1a9641"
        if rsrp >= -95:
            return "#a6d96a"
        if rsrp >= -105:
            return "#fdae61"
        return "#d7191c"

    parts = ['<svg class="map" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg">' % (width, height),
             '<rect width="%d" height="%d" fill="#f4f6f8" stroke="#d6d6d6"/>' % (width, height)]
    path = " ".join("%.1f,%.1f" % pt(f.lat, f.lon) for f in fixes)
    parts.append('<polyline fill="none" stroke="#4a78b5" stroke-width="2" points="%s"/>' % path)
    for lat, lon, rsrp in coloured[:3000]:
        x, y = pt(lat, lon)
        parts.append('<circle cx="%.1f" cy="%.1f" r="3.5" fill="%s"><title>%.6f,%.6f RSRP %s</title></circle>'
                     % (x, y, colour(rsrp), lat, lon, _fmt(rsrp, 1, " dBm")))
    sx, sy = pt(fixes[0].lat, fixes[0].lon)
    ex, ey = pt(fixes[-1].lat, fixes[-1].lon)
    parts.append('<circle cx="%.1f" cy="%.1f" r="5" fill="#fff" stroke="#1a9641" stroke-width="2"><title>start</title></circle>' % (sx, sy))
    parts.append('<rect x="%.1f" y="%.1f" width="9" height="9" fill="#fff" stroke="#d7191c" stroke-width="2"><title>end</title></rect>' % (ex - 4.5, ey - 4.5))
    parts.append('<text x="8" y="14" font-size="10" fill="#555">%.5f,%.5f .. %.5f,%.5f</text>' % (lat0, lon0, lat1, lon1))
    parts.append("</svg>")
    return "".join(parts)


# --- assembling the data -------------------------------------------------------------------------------

def _kpi_stats(rows: list) -> dict:
    out = {}
    for rat in ("lte", "nr"):
        rsrp, rsrq, sinr = [], [], []
        for r in rows:
            if r.get("rat") != rat:
                continue
            v = _floats(r.get("rsrp_dbm", ""))
            if v:
                rsrp.append(v[0])
            v = _floats(r.get("rsrq_db", ""))
            if v:
                rsrq.append(v[0])
            v = _floats(r.get("sinr_db", ""))
            if v:
                sinr.append(v[0])
        if rsrp or rsrq or sinr:
            out[rat] = {
                "samples": max(len(rsrp), len(rsrq), len(sinr)),
                "rsrp_avg": round(sum(rsrp) / len(rsrp), 1) if rsrp else None,
                "rsrp_min": min(rsrp) if rsrp else None, "rsrp_max": max(rsrp) if rsrp else None,
                "rsrq_avg": round(sum(rsrq) / len(rsrq), 1) if rsrq else None,
                "sinr_avg": round(sum(sinr) / len(sinr), 1) if sinr else None,
                "pct_below_-105": round(100.0 * sum(1 for x in rsrp if x < -105) / len(rsrp), 1) if rsrp else None,
            }
    return out


def _event_summary(events: list) -> dict:
    counts = {}
    for e in events:
        counts[e.kind] = counts.get(e.kind, 0) + 1
    procs = {}
    for proc, (attempt, successes, failures) in events_mod.PROCEDURES.items():
        a = counts.get(attempt, 0)
        if proc == "service":
            s = counts.get("service_accept", 0)
        elif proc == "pdn":
            s = counts.get("bearer_setup", 0)
        else:
            s = sum(counts.get(k, 0) for k in successes if k not in ("rrc_release", "bearer_setup"))
        f = sum(counts.get(k, 0) for k in failures)
        times = [float(e.fields["setup_ms"]) for e in events
                 if e.fields.get("setup_ms") not in (None, "") and e.kind in successes and proc != "service"]
        procs[proc] = {"attempts": a, "successes": min(s, a) if a else s, "failures": f,
                       "success_rate": round(100.0 * min(s, a) / a, 1) if a else None,
                       "setup_ms_avg": round(sum(times) / len(times), 1) if times else None,
                       "setup_ms_max": round(max(times), 1) if times else None}
    return {"events": len(events), "by_kind": dict(sorted(counts.items())),
            "errors": sum(1 for e in events if e.severity == "error"),
            "warnings": sum(1 for e in events if e.severity == "warn"),
            "handovers": counts.get("handover", 0) + counts.get("handover_command", 0),
            "reestablishments": counts.get("reestablishment_attempt", 0),
            "cell_changes": max(0, counts.get("serving_cell", 0) - 1),
            "procedures": procs}


def build(session_dir: str, tshark: Optional[str] = None, log=lambda s: None, rebuild: bool = False,
          open_after: bool = False) -> dict:
    """Produce summary.json and report.html for one session directory."""
    sidecar = os.path.join(session_dir, SIDE_CAR)
    with open(sidecar, encoding="utf-8") as fh:
        meta = json.load(fh)
    pcapng = os.path.join(session_dir, PCAPNG_FILE)
    have_pcapng = os.path.isfile(pcapng)
    exe = tshark or tshark_mod.find_tshark()

    # events. A rebuild re-derives events and KPIs from the capture; a session
    # with no capture (an Android app session, a scan log) keeps the files it has
    # instead of being silently emptied.
    ev_path = os.path.join(session_dir, EVENTS_FILE)
    if os.path.isfile(ev_path) and not (rebuild and have_pcapng):
        events = events_mod.read_csv(ev_path)
    elif have_pcapng:
        det = events_mod.from_pcapng(pcapng)
        events = det.events
        if exe:
            events_mod.enrich_with_tshark(events, pcapng, exe)
        with open(ev_path, "w", encoding="utf-8", newline="") as fh:
            fh.write(events_mod.to_csv(events))
    else:
        events = []

    # GPS track
    track_path = os.path.join(session_dir, TRACK_FILE)
    track = gps_mod.Track.read_csv(track_path) if os.path.isfile(track_path) else gps_mod.Track()

    # KPI rows (MeasurementReport-derived, through tshark)
    kpi_path = os.path.join(session_dir, KPI_FILE)
    kpi_note = ""
    if os.path.isfile(kpi_path) and not (rebuild and have_pcapng and exe):
        kpi_rows = _read_csv(kpi_path)
    elif have_pcapng and exe:
        try:
            kpi_rows = kpi_mod.extract(pcapng, exe)
        except RuntimeError as exc:
            kpi_rows, kpi_note = [], str(exc)
        if len(track):
            gps_mod.tag_rows(kpi_rows, track)
        _write_csv(kpi_path, kpi_rows, kpi_mod.SESSION_COLUMNS)
    else:
        kpi_rows = []
        kpi_note = "tshark not found: measurement KPIs need Wireshark" if have_pcapng else ""

    traffic_path = os.path.join(session_dir, TRAFFIC_FILE)
    traffic_results = traffic_mod.read_csv(traffic_path) if os.path.isfile(traffic_path) else []
    cells = _read_csv(os.path.join(session_dir, CELLS_FILE))

    # flow ladder and message-rate histogram
    ladder, flow_events = "", []
    if have_pcapng:
        try:
            flow_events = flow_mod.load_events(pcapng, use_tshark=bool(exe))
            ladder = flow_mod.render_text(flow_events[:MAX_LADDER_LINES], width=118)
            if len(flow_events) > MAX_LADDER_LINES:
                ladder += "\n... %d more messages: open capture.pcapng in Wireshark" % (len(flow_events) - MAX_LADDER_LINES)
        except Exception as exc:  # a damaged pcapng must not kill the report
            ladder = "(call flow unavailable: %s)" % exc

    started = _iso_to_dt(meta.get("started_utc"))
    stopped = _iso_to_dt(meta.get("stopped_utc"))
    duration = (stopped - started).total_seconds() if started and stopped else None
    # A replayed file finishes in a moment of wall-clock time, but it represents
    # however long the modem was logging. Report the longer of the two, and use
    # the modem clock as the chart origin when it is the one that spans.
    modem_first = _iso_to_dt((meta.get("summary") or {}).get("modem_time_first_utc"))
    modem_last = _iso_to_dt((meta.get("summary") or {}).get("modem_time_last_utc"))
    if modem_first and modem_last:
        modem_span = (modem_last - modem_first).total_seconds()
        if duration is None or modem_span > duration:
            duration = modem_span
            started = modem_first
    fixes = track.fixes()
    distance_km = sum(_haversine_km((a.lat, a.lon), (b.lat, b.lon)) for a, b in zip(fixes, fixes[1:])) if len(fixes) > 1 else 0.0
    ev_summary = _event_summary(events)
    summary = {
        "fieldtap_version": __version__,
        "name": meta.get("name"), "note": meta.get("note"), "location": meta.get("location"),
        "started_utc": meta.get("started_utc"), "stopped_utc": meta.get("stopped_utc"),
        "duration_s": round(duration, 1) if duration is not None else None,
        "stopped_by": meta.get("summary", {}).get("stopped_by"),
        "handset": meta.get("handset", {}), "device": meta.get("device", {}), "modem": meta.get("modem", {}),
        "transport": meta.get("transport", {}), "log_profile": meta.get("log_profile"),
        "network": {"plmns": meta.get("summary", {}).get("plmns", {}),
                    "operator": meta.get("handset", {}).get("operator_name"),
                    "mccmnc": meta.get("handset", {}).get("operator_mccmnc"),
                    "cells": len(cells)},
        "counts": {"messages": meta.get("summary", {}).get("messages", {}),
                   "records": meta.get("summary", {}).get("client", {}).get("logs"),
                   "crc_errors": meta.get("summary", {}).get("framing", {}).get("crc_errors")},
        "events": ev_summary,
        "kpi": _kpi_stats(kpi_rows),
        "traffic": traffic_mod.summary(traffic_results),
        "gps": {"fixes": len(fixes), "distance_km": round(distance_km, 3), "bounds": track.bounds()},
        "files": {k: v for k, v in meta.get("files", {}).items()},
    }
    for name in (EVENTS_FILE, KPI_FILE, TRACK_FILE, TRAFFIC_FILE):
        if os.path.isfile(os.path.join(session_dir, name)):
            summary["files"][name.split(".")[0]] = name
    with open(os.path.join(session_dir, SUMMARY_FILE), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, default=str)
        fh.write("\n")

    # A session with no capture file is measurements only: an Android app using
    # the public telephony interface, or a scan log. Its report must not show
    # signalling sections, which would read as failures rather than as "not
    # collected". The Android app writes events of its own (cell changes,
    # markers, sampling gaps), so it declares this rather than leaving it to be
    # inferred from whether an events file exists.
    if (meta.get("capabilities") or {}).get("layer3") is False or meta.get("format") == APP_FORMAT or \
            (meta.get("transport") or {}).get("transport") == "android-api":
        has_signalling = False
    else:
        has_signalling = have_pcapng or bool(events)
    page = render_html(summary, meta, events, kpi_rows, track, traffic_results, cells, ladder, flow_events,
                       started, kpi_note, has_signalling)
    report_path = os.path.join(session_dir, REPORT_FILE)
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write(page)
    log("report: %s" % report_path)
    if open_after:
        import pathlib
        import webbrowser
        # as_uri() gets the slashes right on both Windows (file:///C:/...) and
        # Unix (file:///Users/...); string-building produced file://// there.
        webbrowser.open(pathlib.Path(os.path.abspath(report_path)).as_uri())
    return {"report": report_path, "summary": os.path.join(session_dir, SUMMARY_FILE), "events": ev_path,
            "kpi": kpi_path if os.path.isfile(kpi_path) else None}


# --- HTML ------------------------------------------------------------------------------------------------

_CSS = """
body{font:14px/1.45 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#f7f8fa;color:#222}
header{background:#1f2d3d;color:#fff;padding:18px 28px}header h1{margin:0;font-size:22px;font-weight:600}
header .sub{opacity:.85;margin-top:4px;font-size:13px}main{padding:18px 28px;max-width:1080px;margin:0 auto}
/* A wide table scrolls inside its own card; the page itself never scrolls sideways. */
section{background:#fff;border:1px solid #e3e6ea;border-radius:6px;padding:14px 18px;margin:0 0 16px;overflow-x:auto}
@media(max-width:600px){header{padding:14px 12px}main{padding:14px 12px}section{padding:12px}}
h2{font-size:16px;margin:0 0 10px;color:#1f2d3d}table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:5px 8px;border-bottom:1px solid #eee;vertical-align:top}th{background:#f1f3f6;font-weight:600}
.tiles{display:flex;flex-wrap:wrap;gap:10px}.tile{flex:1 1 150px;background:#f1f3f6;border-radius:6px;padding:10px 12px}
.tile .v{font-size:22px;font-weight:600}.tile .l{font-size:12px;color:#555}.tile.bad .v{color:#c0392b}.tile.good .v{color:#1a9641}
.chart{width:100%;height:auto;display:block;margin:6px 0 10px}.map{max-width:100%;height:auto}
pre{background:#0f172a;color:#e2e8f0;padding:12px;border-radius:6px;overflow:auto;font-size:11.5px;line-height:1.35}
.sev-error{color:#c0392b;font-weight:600}.sev-warn{color:#b9770e}.sev-ok{color:#1a9641}.muted{color:#777}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:3px 14px;font-size:13px}.kv b{font-weight:600;color:#444}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px}@media(max-width:800px){.grid2{grid-template-columns:1fr}}
footer{padding:10px 28px 24px;color:#777;font-size:12px}
"""


def _hhmmss(value):
    """The time of day out of an ISO timestamp, as the events table shows it. The date is in the
    header, and repeating it in every row of every table buys nothing. Anything that is not an ISO
    timestamp is passed through untouched."""
    text = "" if value is None else str(value)
    if len(text) >= 19 and text[10:11] == "T":
        return text[11:23].rstrip(".")
    return text


def _transport_text(value):
    """The transport as a phrase. A replayed file is named, never located: the report is meant to be
    shared, and the path to it says more about the machine that read it than about the capture."""
    if value is None:
        return None
    if not isinstance(value, dict):
        return str(value)
    name = value.get("transport") or "unknown"
    if name == "file":
        path = value.get("path")
        return "%s (%s)" % (name, os.path.basename(path)) if path else name
    app = value.get("app")
    version = value.get("app_version")
    if app:
        return "%s (%s %s)" % (name, app, version) if version else "%s (%s)" % (name, app)
    return name


def _tile(label, value, cls=""):
    return '<div class="tile %s"><div class="v">%s</div><div class="l">%s</div></div>' % (cls, _esc(value), _esc(label))


def _rate_tile(label, proc):
    if not proc or not proc.get("attempts"):
        return _tile(label, "-")
    rate = proc["success_rate"]
    cls = "good" if rate is not None and rate >= 98 else ("bad" if rate is not None and rate < 90 else "")
    return _tile("%s (%d/%d)" % (label, proc["successes"], proc["attempts"]), "%s%%" % _fmt(rate, 1), cls)


def render_html(summary: dict, meta: dict, events: list, kpi_rows: list, track, traffic_results: list,
                cells: list, ladder: str, flow_events: list, started: Optional[datetime], kpi_note: str,
                has_signalling: bool = True) -> str:
    hs = summary.get("handset") or {}
    modem = summary.get("modem") or {}
    net = summary.get("network") or {}
    ev = summary["events"]
    procs = ev["procedures"]
    kpi = summary["kpi"]
    traffic_sum = summary["traffic"]
    simulated = bool((meta.get("transport") or {}).get("transport") == "file")
    app_session = meta.get("format") == APP_FORMAT or (meta.get("transport") or {}).get("transport") == "android-api"

    handset_line = " ".join(x for x in (hs.get("manufacturer"), hs.get("model")) if x) or (summary.get("device") or {}).get("label") or "handset"
    title = "%s - %s" % (summary.get("name") or "session", handset_line)
    sub = []
    if summary.get("started_utc"):
        sub.append("%s UTC" % _utc_text(summary["started_utc"]))
    if summary.get("duration_s") is not None:
        sub.append("%s" % _fmt_seconds(summary["duration_s"]))
    if net.get("operator") or net.get("mccmnc"):
        sub.append("%s %s" % (net.get("operator") or "", net.get("mccmnc") or ""))
    elif net.get("plmns"):
        sub.append("PLMN " + ", ".join(net["plmns"]))
    if summary.get("location"):
        sub.append(summary["location"])
    if simulated:
        sub.append("SIMULATED (file replay)")

    # tiles
    rsrp_avg = None
    for rat in ("nr", "lte"):
        if kpi.get(rat, {}).get("rsrp_avg") is not None:
            rsrp_avg = (rat.upper(), kpi[rat]["rsrp_avg"])
            break
    messages = (summary.get("counts") or {}).get("messages")
    msgs = sum(v for v in (messages.values() if isinstance(messages, dict) else ())
               if isinstance(v, int) and not isinstance(v, bool))
    tiles = [
        _tile("RRC/NAS messages", msgs),
        _tile("events (errors / warnings)", "%d (%d / %d)" % (ev["events"], ev["errors"], ev["warnings"]),
              "bad" if ev["errors"] else ""),
        _rate_tile("RRC setup success", procs.get("rrc")),
        _rate_tile("Attach success", procs.get("attach")) if procs.get("attach", {}).get("attempts") else _rate_tile("Registration success", procs.get("registration")),
        _tile("handovers", ev["handovers"]),
        _tile("radio link failures", ev["reestablishments"], "bad" if ev["reestablishments"] else ""),
        _tile("avg RSRP %s" % rsrp_avg[0] if rsrp_avg else "avg RSRP", _fmt(rsrp_avg[1], 1, " dBm") if rsrp_avg else "-"),
    ]
    if not has_signalling:
        # No procedures, events or messages were captured, so those tiles would
        # show zeros that look like failures. Show what was actually measured.
        rat_kpi = kpi.get(rsrp_avg[0].lower(), {}) if rsrp_avg else {}
        below = rat_kpi.get("pct_below_-105")
        plmns_seen = sorted({str(c.get("plmn")) for c in cells if c.get("plmn")}) or \
            sorted(str(p) for p in (net.get("plmns") or {}))
        tiles = [
            tiles[-1],
            _tile("measurements", rat_kpi.get("samples", 0)),
            _tile("share below -105 dBm", ("%.1f%%" % below) if below is not None else "-",
                  "bad" if (below or 0) > 10 else ""),
            _tile("serving cells", len(cells)),
            _tile("PLMN", ", ".join(plmns_seen) or "-"),
        ]
        if events:
            tiles.append(_tile("events (errors / warnings)", "%d (%d / %d)" % (ev["events"], ev["errors"], ev["warnings"]),
                               "bad" if ev["errors"] else ""))
    if traffic_sum.get("ping"):
        tiles.append(_tile("ping avg / loss", "%s ms / %s%%" % (_fmt(traffic_sum["ping"]["rtt_avg_ms"]), _fmt(traffic_sum["ping"]["loss_pct_avg"]))))
    if traffic_sum.get("download"):
        tiles.append(_tile("download avg / max", "%s / %s Mbit/s" % (_fmt(traffic_sum["download"]["mbps_avg"], 1), _fmt(traffic_sum["download"]["mbps_max"], 1))))
    if traffic_sum.get("upload"):
        tiles.append(_tile("upload avg / max", "%s / %s Mbit/s" % (_fmt(traffic_sum["upload"]["mbps_avg"], 1), _fmt(traffic_sum["upload"]["mbps_max"], 1))))
    if summary["gps"]["fixes"]:
        tiles.append(_tile("GPS fixes / distance", "%d / %.2f km" % (summary["gps"]["fixes"], summary["gps"]["distance_km"])))

    # charts
    charts = []
    if kpi_rows and started:
        t0 = started.timestamp()
        series = []
        for rat, colour in (("lte", "#4a78b5"), ("nr", "#d35400")):
            pts = []
            for r in kpi_rows:
                if r.get("rat") != rat:
                    continue
                v = _floats(r.get("rsrp_dbm", ""))
                try:
                    x = float(r["time_epoch"]) - t0
                except (KeyError, ValueError):
                    continue
                if v:
                    pts.append((x, v[0]))
            if pts:
                series.append(("%s RSRP" % rat.upper(), colour, pts))
        x_max = max((x for _l, _c, pts in series for x, _y in pts), default=0)
        if series:
            charts.append("<h3>RSRP over time (%s)</h3>" % ("from MeasurementReports" if has_signalling
                                                             else "measured by the phone") +
                          svg_timeseries(series, "dBm", -140, -40, x_max, ref_lines={"-105 dBm": -105}))
        series = []
        for rat, colour in (("lte", "#4a78b5"), ("nr", "#d35400")):
            pts = []
            for r in kpi_rows:
                if r.get("rat") != rat:
                    continue
                v = _floats(r.get("sinr_db", "")) if rat == "nr" else _floats(r.get("rsrq_db", ""))
                try:
                    x = float(r["time_epoch"]) - t0
                except (KeyError, ValueError):
                    continue
                if v:
                    pts.append((x, v[0]))
            if pts:
                series.append(("NR SINR" if rat == "nr" else "LTE RSRQ", colour, pts))
        if series:
            charts.append("<h3>RSRQ / SINR over time</h3>" + svg_timeseries(series, "dB", -25, 40, x_max))
    if flow_events:
        rel_max = max(e.rel for e in flow_events) or 1
        bucket = 10 if rel_max <= 1200 else (60 if rel_max <= 7200 else 300)
        n = int(rel_max // bucket) + 1
        counts = [0] * n
        for e in flow_events:
            counts[int(e.rel // bucket)] += 1
        charts.append("<h3>Messages per %s</h3>" % _fmt_seconds(bucket) +
                      svg_bars([(_fmt_seconds(i * bucket), c) for i, c in enumerate(counts)]))
    charts_html = "".join(charts) or '<p class="muted">No measurement KPIs in this session%s.</p>' % (": " + _esc(kpi_note) if kpi_note else "")

    # map
    map_html = ""
    fixes = track.fixes()
    if fixes:
        coloured = []
        for r in kpi_rows:
            if r.get("lat") and r.get("lon"):
                v = _floats(r.get("rsrp_dbm", ""))
                coloured.append((float(r["lat"]), float(r["lon"]), v[0] if v else None))
        map_html = svg_track(fixes, coloured) + \
            '<p class="muted">%d fixes, %.2f km. Green &ge; -85 dBm, light green &ge; -95, orange &ge; -105, red below.</p>' % (
                len(fixes), summary["gps"]["distance_km"])

    # tables
    shown, left_out = _events_for_table(events)
    ev_rows = []
    for e in shown:
        t = (e.when - started).total_seconds() if (e.when and started) else None
        ev_rows.append("<tr><td>%s</td><td>%s</td><td>%s</td><td class=\"sev-%s\">%s</td><td>%s</td><td>%s</td></tr>" % (
            _esc("%.1f" % t) if t is not None else "", _esc(e.when_iso[11:23]), _esc(e.rat.upper()),
            _esc(e.severity), _esc(e.severity), _esc(e.title),
            _esc(e.detail) + ((" <span class=\"muted\">PCI %s</span>" % _esc(e.fields.get("pci"))) if e.fields.get("pci") not in (None, "") else "")))
    events_html = ("<table><tr><th>t (s)</th><th>UTC</th><th>RAT</th><th>severity</th><th>event</th><th>detail</th></tr>%s</table>"
                   % "".join(ev_rows)) if ev_rows else '<p class="muted">No events detected.</p>'
    if left_out:
        events_html += ('<p class="muted">%d more events are not listed here; %s has all %d.</p>'
                        % (left_out, EVENTS_FILE, len(events)))

    _CELL_KEYS = ("first_seen_utc", "rat", "plmn", "tac", "enb_id", "sector", "pci", "band", "dl_earfcn", "dl_bw_mhz")

    def _cell_cell(c, k):
        value = c.get(k, "")
        if k == "first_seen_utc":
            return _hhmmss(value)
        if k == "rat":
            return str(value).upper()
        return value

    cell_rows = "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % _esc(_cell_cell(c, k)) for k in _CELL_KEYS)
                        for c in cells)
    cells_html = ("<table><tr><th>first seen</th><th>RAT</th><th>PLMN</th><th>TAC</th><th>eNB</th><th>sector</th><th>PCI</th><th>band</th><th>DL EARFCN</th><th>BW MHz</th></tr>%s</table>" % cell_rows) if cells else '<p class="muted">No serving-cell records%s in this session.</p>' % (" (log code 0xB0C2)" if has_signalling else "")

    tr_rows = "".join("<tr><td>%s</td><td>%s</td><td>%s</td><td class=\"sev-%s\">%s</td><td>%s</td></tr>" % (
        _esc(r.when_iso[11:19]), _esc(r.test), _esc(r.target), "ok" if r.ok else "error", "ok" if r.ok else "failed", _esc(r.line() if r.ok else r.metrics.get("error", "")))
        for r in traffic_results)
    traffic_html = ("<table><tr><th>UTC</th><th>test</th><th>target</th><th>result</th><th>detail</th></tr>%s</table>" % tr_rows) if traffic_results else \
        '<p class="muted">No traffic tests were run%s.</p>' % ("" if app_session else " (enable with --traffic ping,download)")

    proc_rows = "".join("<tr><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
        _esc(name), p["attempts"], p["successes"], p["failures"], _fmt(p["success_rate"], 1, "%"), _fmt(p["setup_ms_avg"], 0, " ms"), _fmt(p["setup_ms_max"], 0, " ms"))
        for name, p in procs.items() if p["attempts"] or p["failures"])
    proc_html = ("<table><tr><th>procedure</th><th>attempts</th><th>success</th><th>failure</th><th>rate</th><th>avg setup</th><th>max setup</th></tr>%s</table>" % proc_rows) if proc_rows else '<p class="muted">No signalling procedures observed.</p>'

    rec_counts = summary.get("counts") or {}
    records_crc = ("%s / %s" % (rec_counts.get("records"), rec_counts.get("crc_errors"))
                   if rec_counts.get("records") is not None or rec_counts.get("crc_errors") is not None else None)
    # An app session records the cadence Android actually delivered, which is
    # what a reader needs to judge how dense the measurements are.
    collection = meta.get("collection") or {}
    cadence = None
    try:
        if collection.get("median_fresh_interval_ms") not in (None, ""):
            cadence = "%.1f s between fresh samples (median)" % (float(collection["median_fresh_interval_ms"]) / 1000.0)
            if collection.get("short_interval_pct") not in (None, ""):
                cadence += ", %.0f%% of the time at the 2 s interval" % float(collection["short_interval_pct"])
    except (TypeError, ValueError):
        cadence = None
    kv = []
    for label, value in (("Handset", handset_line), ("Android", "%s (%s)" % (hs.get("android_version", "?"), hs.get("android_build", "?")) if hs.get("android_version") else None),
                         ("Baseband", hs.get("baseband")), ("Modem build", modem.get("build_id") or modem.get("version_dir")),
                         ("SoC", hs.get("soc") or hs.get("platform")), ("SIM operator", "%s %s" % (hs.get("sim_operator_name", ""), hs.get("sim_mccmnc", "")) if hs.get("sim_mccmnc") else None),
                         ("PLMNs seen", ", ".join(net.get("plmns", {}).keys()) or None), ("Transport", _transport_text(summary.get("transport"))),
                         ("Log profile", summary.get("log_profile")), ("Records / CRC errors", records_crc),
                         ("Cadence", cadence),
                         ("Stopped by", (meta.get("summary") or {}).get("stopped_by")), ("Note", summary.get("note"))):
        if value:
            kv.append("<b>%s</b><span>%s</span>" % (_esc(label), _esc(value)))
    files = summary.get("files", {})
    files_html = ", ".join('<a href="%s">%s</a>' % (_esc(v), _esc(v)) for v in files.values())

    return """<!doctype html><html><head><meta charset="utf-8">\
<meta name="viewport" content="width=device-width, initial-scale=1"><title>%(title)s</title><style>%(css)s</style></head>
<body><header><h1>%(title)s</h1><div class="sub">%(sub)s</div></header><main>
<section><div class="tiles">%(tiles)s</div></section>
<div class="grid2"><section><h2>Session</h2><div class="kv">%(kv)s</div><p class="muted" style="margin-top:8px">Files: %(files)s</p></section>
<section><h2>Route</h2>%(map)s</section></div>
%(source_note)s<section><h2>Radio</h2>%(charts)s</section>
%(procs_section)s%(events_section)s<section><h2>Serving cells</h2>%(cells)s</section>
<section><h2>Traffic tests</h2>%(traffic)s</section>
%(ladder_section)s</main><footer>Generated by FieldTap %(version)s. %(footer_note)s</footer></body></html>
""" % {"title": _esc(title), "css": _CSS, "sub": _esc(" | ".join(sub)), "tiles": "".join(tiles), "kv": "".join(kv),
       "files": files_html,
       "map": map_html or ('<p class="muted">No GPS track in this session.</p>' if app_session
                           else '<p class="muted">No GPS track (enable with --gps adb or --gps nmea:COMx).</p>'),
       "charts": charts_html, "cells": cells_html, "traffic": traffic_html,
       "procs_section": ("<section><h2>Procedures</h2>%s</section>\n" % proc_html) if has_signalling else "",
       "events_section": ("<section><h2>Events</h2>%s</section>\n" % events_html) if (has_signalling or events) else "",
       "ladder_section": ("<section><h2>Call flow</h2><pre>%s</pre></section>\n" % _esc(ladder or "(no messages)"))
                         if has_signalling else "",
       "source_note": "" if has_signalling else (
           '<section class="muted">Measurements from the Android public telephony interface: signal strength '
           'and cell identity. No signalling was captured, so this report has no procedures, handovers or call '
           'flow.</section>\n'),
       "footer_note": ("Decode by Wireshark; open capture.pcapng for the full message detail." if has_signalling
                       else "Measurements only; no signalling decode."),
       "version": _esc(__version__)}


# --- index over a captures directory ---------------------------------------------------------------------------

def build_index(root: str, log=lambda s: None) -> Optional[str]:
    sessions = list_sessions(root)
    rows = []
    for s in sessions:
        summ = {}
        sp = os.path.join(s["dir"], SUMMARY_FILE)
        if os.path.isfile(sp):
            try:
                with open(sp, encoding="utf-8") as fh:
                    summ = json.load(fh)
            except (OSError, ValueError):
                summ = {}
        rel = os.path.relpath(s["dir"], root).replace("\\", "/")
        ev = summ.get("events", {})
        kpi = summ.get("kpi", {})
        rsrp = next((kpi[r]["rsrp_avg"] for r in ("nr", "lte") if kpi.get(r, {}).get("rsrp_avg") is not None), None)
        report_link = ('<a href="%s/%s">report</a>' % (rel, REPORT_FILE)) if os.path.isfile(os.path.join(s["dir"], REPORT_FILE)) else '<span class="muted">no report</span>'
        rows.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%d</td><td class=\"%s\">%s</td><td>%s</td><td>%s</td></tr>" % (
            _esc(_utc_text(s["started_utc"])), _esc(s["name"]), _esc(s["handset"]), _esc(s["plmns"]),
            _esc(_fmt_seconds(summ["duration_s"]) if summ.get("duration_s") is not None else "-"), s["messages"],
            "sev-error" if ev.get("errors") else "", _esc(ev.get("errors", "-")), _esc(_fmt(rsrp, 1, " dBm")), report_link))
    page = """<!doctype html><html><head><meta charset="utf-8">\
<meta name="viewport" content="width=device-width, initial-scale=1"><title>FieldTap sessions</title><style>%s</style></head>
<body><header><h1>FieldTap sessions</h1><div class="sub">%s</div></header><main><section>
<table><tr><th>started (UTC)</th><th>name</th><th>handset</th><th>PLMN</th><th>duration</th><th>messages</th><th>errors</th><th>avg RSRP</th><th></th></tr>%s</table>
</section></main><footer>Generated by FieldTap %s</footer></body></html>
""" % (_CSS, _esc(os.path.abspath(root)), "".join(rows) or '<tr><td colspan="9" class="muted">no sessions yet</td></tr>', _esc(__version__))
    path = os.path.join(root, INDEX_FILE)
    os.makedirs(root, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(page)
    log("index: %s (%d sessions)" % (path, len(sessions)))
    return path
