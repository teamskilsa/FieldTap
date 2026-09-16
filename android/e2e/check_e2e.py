#!/usr/bin/env python3
"""Helpers and assertions for android/e2e/run_e2e.sh, the end-to-end proof of the Android app on an emulator.

    check_e2e.py plan-walk [--seconds N]
        The walking GPS track run_e2e.sh injects with "adb emu geo fix": one "lat,lon,alt" line per second.
    check_e2e.py instrumentation RAW [--junit XML] [--name NAME]
        Summarises "am instrument -w -r" output and writes it as JUnit XML. Exit 1 unless at least one test ran,
        every test passed and the process did not crash.
    check_e2e.py exit-reason DUMPSYS --pid PID
        Prints the summary.stopped_by token that "dumpsys activity exit-info" implies for process PID, using the
        app's own table (com.fieldtap.core.session.ExitReasons). Exit 1 when Android recorded no exit for PID.
    check_e2e.py check --out DIR --repo REPO [--walk-seconds N] [--expect-lte-nr true|false] [--variants "light dark"]
        Asserts what the sessions, screenshots and results of a run hold. Prints one PASS or FAIL line per check,
        writes checks/results.json and exits 1 on any FAIL.

Standard library only; Python 3.9 or newer.
"""
from __future__ import annotations

import argparse
import bisect
import csv
import hashlib
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from typing import Optional

# The walk: a 160 m by 120 m loop at walking pace, starting where probe.sh put its fixes.
WALK_START = (12.9716, 77.5946)
WALK_SPEED_MPS = 1.4
WALK_LEGS = ((160.0, 0.0), (0.0, 120.0), (-160.0, 0.0), (0.0, -120.0))  # (north, east) metres
METRES_PER_DEGREE = 111_320.0
EARTH_RADIUS_M = 6_371_008.8

# ApplicationExitInfo.REASON_* 0..16 as ExitReasons.token writes them; any other value is "unknown".
EXIT_TOKENS = (
    "unknown", "exit_self", "signaled", "low_memory", "crash", "crash_native", "anr",
    "initialization_failure", "permission_change", "excessive_resource_usage", "user_requested",
    "user_stopped", "dependency_died", "other", "freezer", "package_state_change", "package_updated",
)

BUNDLE = ("session.json", "kpi.csv", "track.csv", "events.csv", "traffic.csv", "cells.csv", "cellinfo.csv")
KPI_COMMENT = re.compile(r"android-api age_ms=(\d+) src=(request|push)")
HEX64 = re.compile(r"[0-9a-f]{64}")

# SESSION-FORMAT.md: KPI rows at most 11000 ms old; positions from the nearest fix within 5.000 s.
KPI_MAX_AGE_MS = 11_000
JOIN_MS = 5_000
# Track and measurement times are separate millisecond translations of the elapsed clock.
ROUNDING_MS = 2
# The emulator's modem reports a new cell-info measurement every 10.0 s (the probe's facts).
MODEM_REPORT_S = 10
# A fix matches the injected walk when it is this close to a point sent this close in time (after the clock offset).
TRACK_MATCH_M = 10.0
TRACK_MATCH_MS = 5_000
# A track row is a fix accepted while recording: it may be up to the join buffer (60 s) older than the start, never later
# than the stop by more than a callback's delay.
TRACK_BEFORE_START_MS = 60_000
TRACK_AFTER_STOP_MS = 5_000
# A kill lands within one 5 s heartbeat of the last one; slack for a busy emulator.
HEARTBEAT_SLACK_MS = 7_000

# Screens taken at every scroll position: NAME-p1.png, NAME-p2.png and so on (Screens.shotFull).
FIRST_RUN_PAGED = ("01-disclosure", "01b-disclosure-notice", "02-permissions")
TOUR_PAGED = ("03-live", "04-sessions", "05-session-detail", "06-readiness", "07-traffic", "07-probe", "07c-probe-root-check",
              "08-settings", "08b-test-targets", "09-about")
# Taken once: the Start dialog, and the bottom navigation bar with Live selected (10-nav-live) and with another tab
# selected (10b-nav-traffic) — the tab-navigation evidence, in every variant.
TOUR_SINGLE = ("03b-start-dialog", "10-nav-live", "10b-nav-traffic")
# Upright variants also turn the phone for Live; the landscape variant takes every screen turned.
LIVE_TURNED = "03e-live-landscape"
WALK_SCREENS = (
    "01-disclosure", "02-permissions", "03-permissions-allowed", "04-live-radio", "05-settings-tests",
    "06-start-dialog", "08-mark-dialog", "09-marker-added", "09b-notification-marker", "10-recording", "11-stop-dialog",
    "12-sessions", "13-session-detail", "14-zip-ready", "15-share-sheet",
)
LOCATION_OFF_SCREENS = ("20-live-location-off", "21-live-marker-dropped", "22-session-detail-marker-dropped-p1")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# The words the app writes, as com.fieldtap.core.location.GpsEventDeriver and com.fieldtap.core.privacy.PrivacyZoneGate
# write them.
LOCATION_OFF_DETAIL = "Location services turned off"
PAUSED_NO_FIX_TITLE = "Logging paused until the location is known"
RESUMED_TITLE = "Logging resumed"
# A fix Android measured just before location went off may still arrive, and the first after it may take a moment.
LOCATION_SWITCH_SLACK_MS = 2_000


# ---------------------------------------------------------------------------------------------------- plan-walk

def walk_point(second: int) -> tuple[float, float]:
    """Latitude and longitude after [second] seconds of walking the loop."""
    loop_m = sum(abs(north) + abs(east) for north, east in WALK_LEGS)
    remaining = (second * WALK_SPEED_MPS) % loop_m
    north_m = east_m = 0.0
    for north, east in WALK_LEGS:
        step = min(remaining, abs(north) + abs(east))
        north_m += math.copysign(step, north) if north else 0.0
        east_m += math.copysign(step, east) if east else 0.0
        remaining -= step
        if remaining <= 0:
            break
    lat = WALK_START[0] + north_m / METRES_PER_DEGREE
    lon = WALK_START[1] + east_m / (METRES_PER_DEGREE * math.cos(math.radians(WALK_START[0])))
    return lat, lon


def cmd_plan_walk(args: argparse.Namespace) -> int:
    for second in range(args.seconds):
        lat, lon = walk_point(second)
        sys.stdout.write("%.7f,%.7f,%.1f\n" % (lat, lon, 920.0 + 2.0 * math.sin(second / 60.0)))
    return 0


# ---------------------------------------------------------------------------------------------- instrumentation

STATUS_WORDS = {0: "passed", -1: "error", -2: "failed", -3: "ignored", -4: "assumption failed"}


def parse_instrumentation(text: str) -> tuple[list[dict], dict, Optional[int]]:
    """The finished tests, the INSTRUMENTATION_RESULT fields and the INSTRUMENTATION_CODE of "am instrument -r"."""
    tests: list[dict] = []
    result: dict = {}
    fields: dict = {}
    last: Optional[tuple[dict, str]] = None
    code: Optional[int] = None
    for line in text.splitlines():
        if line.startswith("INSTRUMENTATION_STATUS: "):
            key, _, value = line[len("INSTRUMENTATION_STATUS: "):].partition("=")
            fields[key] = value
            last = (fields, key)
        elif line.startswith("INSTRUMENTATION_STATUS_CODE: "):
            status = int(line.split(":", 1)[1].strip())
            # 1 starts a test and 2 streams output; every other code ends one.
            if status not in (1, 2) and fields.get("test"):
                tests.append({
                    "class": fields.get("class", ""),
                    "test": fields.get("test", ""),
                    "status": status,
                    "stack": fields.get("stack", "").strip(),
                })
            fields, last = {}, None
        elif line.startswith("INSTRUMENTATION_RESULT: "):
            key, _, value = line[len("INSTRUMENTATION_RESULT: "):].partition("=")
            result[key] = value
            last = (result, key)
        elif line.startswith("INSTRUMENTATION_CODE: "):
            code = int(line.split(":", 1)[1].strip())
            last = None
        elif last is not None:
            target, key = last
            target[key] += "\n" + line
    return tests, result, code


def cmd_instrumentation(args: argparse.Namespace) -> int:
    path = Path(args.raw)
    text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
    tests, result, code = parse_instrumentation(text)
    name = args.name or path.stem
    crashed = "shortMsg" in result
    failed = [t for t in tests if t["status"] not in (0, -3)]
    ok = bool(tests) and not failed and not crashed and code == -1

    print("%s: %s, %d test(s), %d failed%s" % (
        name, "PASS" if ok else "FAIL", len(tests), len(failed), ", process crashed" if crashed else ""))
    for test in tests:
        print("  %s %s#%s" % (STATUS_WORDS.get(test["status"], str(test["status"])), test["class"], test["test"]))
        if test["status"] not in (0, -3):
            for line in test["stack"].splitlines()[:25]:
                print("    " + line)
    if crashed:
        print("  " + result.get("shortMsg", "") + " " + result.get("longMsg", ""))
    if not tests:
        print("  no test finished; the last lines of the output:")
        for line in text.splitlines()[-15:]:
            print("    " + line)

    if args.junit:
        suite = ET.Element("testsuite", name=name, tests=str(len(tests)),
                           failures=str(sum(1 for t in tests if t["status"] == -2)),
                           errors=str(sum(1 for t in tests if t["status"] in (-1, -4)) + (1 if crashed else 0)),
                           skipped=str(sum(1 for t in tests if t["status"] == -3)))
        for test in tests:
            case = ET.SubElement(suite, "testcase", classname=test["class"], name=test["test"])
            first_line = test["stack"].splitlines()[0] if test["stack"] else ""
            if test["status"] == -2:
                ET.SubElement(case, "failure", message=first_line).text = test["stack"]
            elif test["status"] in (-1, -4):
                ET.SubElement(case, "error", message=first_line).text = test["stack"]
            elif test["status"] == -3:
                ET.SubElement(case, "skipped")
        if crashed or not tests:
            case = ET.SubElement(suite, "testcase", classname="instrumentation", name=name)
            ET.SubElement(case, "error", message=result.get("shortMsg", "no test finished")).text = \
                result.get("longMsg", "") or "\n".join(text.splitlines()[-15:])
        ET.ElementTree(suite).write(args.junit, encoding="utf-8", xml_declaration=True)
    return 0 if ok else 1


# ---------------------------------------------------------------------------------------------------- exit-reason

def exit_records(text: str) -> list[dict]:
    """pid and reason of each ApplicationExitInfo in "dumpsys activity exit-info" output."""
    records: list[dict] = []
    current: Optional[dict] = None
    for line in text.splitlines():
        if re.search(r"ApplicationExitInfo #\d+", line):
            current = {}
            records.append(current)
            continue
        if current is None:
            continue
        for key in ("pid", "reason"):
            if key not in current:
                match = re.search(r"(?<![A-Za-z])%s=(-?\d+)" % key, line)
                if match:
                    current[key] = int(match.group(1))
    return records


def exit_token(text: str, pid: int) -> Optional[str]:
    """The token of the newest exit record of [pid], or None when there is none."""
    for record in exit_records(text):
        if record.get("pid") == pid and "reason" in record:
            reason = record["reason"]
            return EXIT_TOKENS[reason] if 0 <= reason < len(EXIT_TOKENS) else "unknown"
    return None


def cmd_exit_reason(args: argparse.Namespace) -> int:
    token = exit_token(Path(args.dumpsys).read_text(encoding="utf-8", errors="replace"), args.pid)
    if token is None:
        return 1
    print(token)
    return 0


# ----------------------------------------------------------------------------------------------------------- check

class Results:
    """PASS and FAIL lines, kept for checks/results.json."""

    def __init__(self) -> None:
        self.items: list[dict] = []

    def check(self, name: str, ok: object, detail: object = "") -> bool:
        passed = bool(ok)
        text = "" if detail is None or detail == "" else str(detail)
        if len(text) > 600:
            text = text[:600] + "..."
        self.items.append({"check": name, "ok": passed, "detail": text})
        print("%s %s%s" % ("PASS" if passed else "FAIL", name, ": " + text if text else ""))
        return passed

    @property
    def failures(self) -> list[dict]:
        return [item for item in self.items if not item["ok"]]


def read_csv(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def read_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def utc_ms(value: str) -> int:
    return round(datetime.fromisoformat(value).timestamp() * 1000)


def epoch_ms(value: str) -> int:
    return int(Decimal(value) * 1000)


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def exit_status(out: Path, name: str) -> Optional[int]:
    path = out / "validate" / (name + ".exit")
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def android_string(repo: Path, name: str) -> Optional[str]:
    """A string resource of the app, as the UI shows it."""
    for path in sorted((repo / "android/app/src/main/res/values").glob("strings*.xml")):
        for element in ET.parse(path).getroot().iter("string"):
            if element.get("name") == name:
                return (element.text or "").replace("\\'", "'")
    return None


def consent_version(repo: Path) -> Optional[str]:
    for path in sorted((repo / "android/core/src/main/kotlin/com/fieldtap/core/privacy").glob("*.kt")):
        match = re.search(r'version\s*=\s*"([^"]+)"', path.read_text(encoding="utf-8"))
        if match:
            return match.group(1)
    return None


def acceptable_positions(fixes: list[tuple[int, str, str]], times: list[int], t: int) -> set:
    """What a row measured at [t] may carry: the nearest fix within 5 s, earlier on a tie, or blank without one."""
    low = bisect.bisect_left(times, t - JOIN_MS - ROUNDING_MS)
    high = bisect.bisect_right(times, t + JOIN_MS + ROUNDING_MS)
    window = fixes[low:high]
    if not window:
        return {None}
    best = min(abs(fix[0] - t) for fix in window)
    allowed = {(fix[1], fix[2]) for fix in window if abs(fix[0] - t) <= best + ROUNDING_MS}
    if best >= JOIN_MS - ROUNDING_MS:
        allowed.add(None)
    return allowed


def positions_not_joined(rows: list[dict], fixes: list[tuple[int, str, str]], times: list[int]) -> list[str]:
    """Rows of kpi.csv or cellinfo.csv whose lat and lon are not the nearest fix within 5 s of their time_epoch."""
    wrong = []
    for line, row in enumerate(rows, 2):
        position = (row["lat"], row["lon"]) if row["lat"] else None
        allowed = acceptable_positions(fixes, times, epoch_ms(row["time_epoch"]))
        if position not in allowed:
            wrong.append("line %d: %s, expected one of %s" % (line, position, sorted(allowed, key=str)[:2]))
    return wrong


def check_kpi(kpi: list[dict], cellinfo: list[dict], fixes: list, fix_times: list[int], walk_seconds: int, r: Results) -> None:
    """kpi.csv of a walk whose modem reports LTE or NR cells."""
    minimum = walk_seconds // MODEM_REPORT_S - 3
    r.check("kpi.csv: fresh rows for the walk", len(kpi) >= minimum,
            "%d rows, at least %d expected from a %d s modem report interval" % (len(kpi), minimum, MODEM_REPORT_S))
    comments = [KPI_COMMENT.fullmatch(row["comment"]) for row in kpi]
    r.check("kpi.csv: every comment gives the sample's age and source", all(comments),
            [line for line, match in enumerate(comments, 2) if not match][:5])
    ages = [int(match.group(1)) for match in comments if match]
    r.check("kpi.csv: no sample older than %d ms" % KPI_MAX_AGE_MS, all(age <= KPI_MAX_AGE_MS for age in ages),
            "oldest %s ms" % (max(ages) if ages else None))
    keys = [(row["rat"], row["pci"], row["time_epoch"]) for row in kpi]
    duplicated = sorted(key for key, count in Counter(keys).items() if count > 1)
    r.check("kpi.csv: no modem timestamp twice for the same cell", not duplicated, duplicated[:5])
    fresh_serving = {
        (row["rat"], row["pci"], row["time_epoch"]) for row in cellinfo
        if row["stale"] == "0" and (row["connection_status"] in ("1", "2") or (row["connection_status"] == "" and row["registered"] == "1"))
    }
    not_fresh = [key for key in keys if key not in fresh_serving]
    r.check("kpi.csv: every row is a fresh serving-cell measurement in cellinfo.csv", not not_fresh, not_fresh[:5])
    rsrp = sorted({row["rsrp_dbm"] for row in kpi if row["rsrp_dbm"]}, key=float)
    r.check("kpi.csv: RSRP follows the signal-profile changes", len(rsrp) >= 3, rsrp)
    positioned = [row for row in kpi if row["lat"] and row["lon"]]
    r.check("kpi.csv: rows carry lat and lon", positioned, "%d of %d rows" % (len(positioned), len(kpi)))
    halves = [line for line, row in enumerate(kpi, 2) if bool(row["lat"]) != bool(row["lon"])]
    r.check("kpi.csv: lat and lon are filled together", not halves, halves[:5])
    wrong = positions_not_joined(kpi, fixes, fix_times)
    r.check("kpi.csv: each position is the nearest fix within 5 s", not wrong, wrong[:3])


def check_without_lte_nr(kpi: list[dict], cells: list[dict], cellinfo: list[dict], fixes: list, fix_times: list[int],
                         r: Results) -> None:
    """A walk whose modem reports no LTE or NR cell: nothing may pass for a measurement, and the raw log stays whole."""
    rats = dict(Counter(row["rat"] for row in cellinfo))
    r.check("cellinfo.csv: logs the cells Android reports, none LTE or NR",
            cellinfo and not any(row["rat"] in ("lte", "nr") for row in cellinfo), "%d rows, %s" % (len(cellinfo), rats))
    r.check("kpi.csv: no rows without an LTE or NR serving cell", not kpi, "%d rows" % len(kpi))
    r.check("cells.csv: no serving cells without an LTE or NR serving cell", not cells, "%d rows" % len(cells))
    positioned = [row for row in cellinfo if row["lat"] and row["lon"]]
    r.check("cellinfo.csv: rows carry lat and lon", positioned, "%d of %d rows" % (len(positioned), len(cellinfo)))
    wrong = positions_not_joined(cellinfo, fixes, fix_times)
    r.check("cellinfo.csv: each position is the nearest fix within 5 s", not wrong, wrong[:3])


FIVE_G_SHOWN = re.compile(r"TelephonyDisplayInfo \{network=NR[,}]|overrideNetwork=(NR_NSA|NR_NSA_MMWAVE|NR_ADVANCED)[,}]")


def five_g_icon_shown(snapshot: Path):
    """From a telephony_snapshot: True when the registry's display info shows the 5G icon, False when not, None when unknown."""
    if not snapshot.is_file():
        return None
    line = next((line for line in snapshot.read_text(encoding="utf-8", errors="replace").splitlines()
                 if "mTelephonyDisplayInfo=TelephonyDisplayInfo" in line), None)
    return None if line is None else bool(FIVE_G_SHOWN.search(line))


def check_gaps_inside(label: str, meta: dict, r: Results) -> None:
    """No collection.gaps entry begins before the session: a sample measured before the start is no gap reference."""
    started = utc_ms(meta["started_utc"])
    gaps = (meta.get("collection") or {}).get("gaps") or []
    early = [gap for gap in gaps if utc_ms(gap["start_utc"]) < started]
    r.check("%s: no sampling gap begins before the session started" % label, not early, early[:3])


def check_counts_from_rows(label: str, meta: dict, kpi: list, cellinfo: list, cells: list, events: list, r: Results) -> None:
    """summary.plmns, cells.csv and collection agree with the rows the session holds, however early it was killed."""
    serving = {}
    for row in cellinfo:
        if row["stale"] == "0" and row["connection_status"] in ("1", "2"):
            serving.setdefault((row["rat"], row["pci"], row["time_epoch"]), row["plmn"])
    by_plmn = Counter()
    placed = 0
    for row in kpi:
        key = (row["rat"], row["pci"], row["time_epoch"])
        if key in serving:
            placed += 1
            if serving[key]:
                by_plmn[serving[key]] += 1
    plmns = {key: value for key, value in ((meta.get("summary") or {}).get("plmns") or {}).items() if value}
    r.check("%s: summary.plmns counts the kpi.csv rows the session holds" % label, plmns == dict(by_plmn),
            "session.json %s, kpi.csv %s" % (plmns, dict(by_plmn)))
    samples = sum(int(row["samples"]) for row in cells)
    r.check("%s: cells.csv accounts for every kpi.csv row" % label, samples == placed,
            "cells.csv %d samples, %d kpi.csv rows of a serving cell" % (samples, placed))
    collection = meta.get("collection") or {}
    fresh = collection.get("fresh_samples") or 0
    r.check("%s: collection.fresh_samples counts the fresh answers the session holds" % label, fresh >= (1 if kpi else 0),
            "fresh_samples %s, kpi rows %d" % (fresh, len(kpi)))
    gap_events = [e for e in events if e["kind"] == "sampling_gap"]
    gaps = collection.get("gaps") or []
    r.check("%s: collection has one gap per sampling_gap event" % label, len(gaps) == len(gap_events),
            "%d gaps, %d events" % (len(gaps), len(gap_events)))


def check_walk(out: Path, repo: Path, walk_seconds: int, expect_lte_nr: bool, r: Results) -> None:
    result_path = out / "device" / "walk-result.json"
    if not r.check("walk: the test wrote its result", result_path.is_file(), result_path):
        return
    result = read_json(result_path)
    r.check("walk: the disclosure showed before any permission prompt", result.get("disclosure_before_prompt") is True,
            "location %s, notifications %s" % (result.get("location_permission"), result.get("notification_permission")))
    dir_name = result.get("dir_name")
    session = out / "sessions" / str(dir_name)
    if not r.check("walk: the session was pulled", dir_name and (session / "session.json").is_file(), session):
        return
    r.check("walk: fieldtap validate --upload exit 0", exit_status(out, dir_name) == 0, exit_status(out, dir_name))

    meta = read_json(session / "session.json")
    kpi = read_csv(session / "kpi.csv")
    track = read_csv(session / "track.csv")
    events = read_csv(session / "events.csv")
    traffic = read_csv(session / "traffic.csv")
    cells = read_csv(session / "cells.csv")
    cellinfo = read_csv(session / "cellinfo.csv")
    summary = meta.get("summary") or {}

    # session.json
    r.check("session.json: summary.stopped_by is user", summary.get("stopped_by") == "user", summary.get("stopped_by"))
    r.check("session.json: capabilities.layer3 is false", (meta.get("capabilities") or {}).get("layer3") is False,
            meta.get("capabilities"))
    transport = meta.get("transport") or {}
    r.check("session.json: an app session", meta.get("format") == "fieldtap-session/1"
            and transport.get("transport") == "android-api" and transport.get("app") == "5gto6G FieldTap",
            "format %s, transport %s" % (meta.get("format"), transport))
    r.check("session.json: the name typed in the Start dialog", meta.get("name") == result.get("session_name"), meta.get("name"))
    started = utc_ms(meta["started_utc"])
    stopped = utc_ms(meta["stopped_utc"]) if meta.get("stopped_utc") else None
    duration_s = (stopped - started) / 1000.0 if stopped is not None else 0.0
    r.check("session.json: recorded for the whole walk", stopped is not None and walk_seconds - 2 <= duration_s <= walk_seconds + 120,
            "%.1f s for a %d s walk" % (duration_s, walk_seconds))
    collection = meta.get("collection") or {}
    fresh = collection.get("fresh_samples")
    r.check("collection: fresh_samples", isinstance(fresh, int) and fresh >= 1 and len(kpi) <= 2 * fresh,
            "fresh_samples %s, kpi rows %d" % (fresh, len(kpi)))
    repeats = collection.get("repeats_dropped")
    r.check("collection: repeats_dropped", isinstance(repeats, int) and repeats >= 0, repeats)
    median = collection.get("median_fresh_interval_ms")
    r.check("collection: median_fresh_interval_ms", isinstance(median, int) and median > 0, median)
    for key in ("short_interval_pct", "screen_on_pct", "wifi_connected_pct", "charging_pct"):
        value = collection.get(key)
        r.check("collection: %s is a share" % key,
                isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= 100, value)
    gaps = collection.get("gaps")
    gap_events = [e for e in events if e["kind"] == "sampling_gap"]
    r.check("collection: one gap per sampling_gap event", isinstance(gaps, list) and len(gaps) == len(gap_events),
            "%s gaps, %d events" % (len(gaps) if isinstance(gaps, list) else gaps, len(gap_events)))
    check_gaps_inside("walk", meta, r)
    # Android delivers display info once, when the Live screen registered its listeners; the session starts later.
    shown = five_g_icon_shown(out / "checks" / "telephony-before-walk.txt")
    icon = [(e["time_utc"], e["title"]) for e in events if e["kind"] == "nr_display"]
    if shown:
        r.check("events.csv: the 5G icon the session started with (nr_display)", icon and icon[0][1] == "5G icon on", icon[:3])
    elif shown is False:
        r.check("events.csv: no 5G icon event while the phone shows none", not icon or icon[0][1] == "5G icon on", icon[:3])
    r.check("screen: kept on only while recording, brightness left to the phone, flag cleared at Stop",
            result.get("keep_screen_on_before_recording") is False
            and result.get("keep_screen_on_while_recording") is True
            and result.get("keep_screen_on_brightness_override") is False
            and result.get("keep_screen_on_cleared_after_stop") is True,
            "before %s, while recording %s, brightness override %s, cleared %s"
            % (result.get("keep_screen_on_before_recording"), result.get("keep_screen_on_while_recording"),
               result.get("keep_screen_on_brightness_override"), result.get("keep_screen_on_cleared_after_stop")))
    r.check("walk: the recording Stop and Mark controls sit wholly above the bottom navigation bar",
            result.get("recording_controls_clear") is True,
            "clear %s, gap %s px" % (result.get("recording_controls_clear"), result.get("recording_controls_gap_px")))
    privacy = meta.get("privacy") or {}
    version = consent_version(repo)
    r.check("session.json: privacy", privacy.get("data_class") == "kpi" and privacy.get("location_precision") == "full"
            and privacy.get("zone_pauses") == 0 and privacy.get("consent_version") == version
            and HEX64.fullmatch(privacy.get("consent_sha256") or ""), "%s (consent in the app: %s)" % (privacy, version))

    # kpi.csv, cells.csv and cellinfo.csv, by what the modem reports
    r.check("walk: the test ran with the host's LTE and NR expectation", result.get("expect_lte_nr") is expect_lte_nr,
            "test %s, host %s" % (result.get("expect_lte_nr"), expect_lte_nr))
    fixes = sorted((utc_ms(row["time_utc"]), row["lat"], row["lon"]) for row in track)
    fix_times = [fix[0] for fix in fixes]
    measurements = [(row["rat"], row["pci"], row["arfcn"], row["cell_id"], row["timestamp_ms"]) for row in cellinfo if row["stale"] == "0"]
    logged_twice = sorted(key for key, count in Counter(measurements).items() if count > 1)
    r.check("cellinfo.csv: a measurement is fresh only once", not logged_twice, logged_twice[:5])
    if expect_lte_nr:
        check_kpi(kpi, cellinfo, fixes, fix_times, walk_seconds, r)
    else:
        check_without_lte_nr(kpi, cells, cellinfo, fixes, fix_times, r)

    # track.csv against the walk the host injected
    offset_path = out / "checks" / "clock-offset-ms.txt"
    offset = int(offset_path.read_text().strip()) if offset_path.is_file() else 0
    injected = sorted((int(row["host_ms"]) + offset, float(row["lat"]), float(row["lon"]))
                      for row in read_csv(out / "checks" / "injected-track.csv"))
    injected_times = [point[0] for point in injected]
    r.check("track.csv: about one fix a second", len(track) >= 0.8 * duration_s,
            "%d fixes in %.0f s, %d points injected" % (len(track), duration_s, len(injected)))
    unmatched = []
    for line, row in enumerate(track, 2):
        t, lat, lon = utc_ms(row["time_utc"]), float(row["lat"]), float(row["lon"])
        low = bisect.bisect_left(injected_times, t - TRACK_MATCH_MS)
        high = bisect.bisect_right(injected_times, t + TRACK_MATCH_MS)
        best = min((distance_m(lat, lon, p[1], p[2]) for p in injected[low:high]), default=math.inf)
        if best > TRACK_MATCH_M:
            unmatched.append("line %d: %s m from the walk" % (line, "no point in time" if best == math.inf else "%.1f" % best))
    r.check("track.csv: every fix lies on the injected walk (%.0f m, %d s)" % (TRACK_MATCH_M, TRACK_MATCH_MS // 1000),
            track and not unmatched, "%d of %d unmatched %s" % (len(unmatched), len(track), unmatched[:3]))
    walked = sum(distance_m(float(a["lat"]), float(a["lon"]), float(b["lat"]), float(b["lon"])) for a, b in zip(track, track[1:]))
    r.check("track.csv: the route covers the walk", walked >= 0.5 * WALK_SPEED_MPS * duration_s,
            "%.0f m walked, %.0f m injected in that time" % (walked, WALK_SPEED_MPS * duration_s))
    outside = [row["time_utc"] for row in track
               if stopped is None or not started - TRACK_BEFORE_START_MS <= utc_ms(row["time_utc"]) <= stopped + TRACK_AFTER_STOP_MS]
    r.check("track.csv: every fix time lies within the session", track and not outside,
            "%d of %d outside %s .. %s, first %s" % (len(outside), len(track), meta.get("started_utc"), meta.get("stopped_utc"),
                                                     outside[:2]))
    r.check("track.csv: providers", set(row["provider"] for row in track) <= {"gps", "fused", "network"},
            dict(Counter(row["provider"] for row in track)))

    # events.csv
    serving = [e for e in events if e["kind"] == "serving_cell"]
    if expect_lte_nr:
        r.check("events.csv: serving_cell with its PCI and ARFCN", serving and all(e["pci"] and e["arfcn"] for e in serving),
                [(e["time_utc"], e["rat"], e["pci"], e["arfcn"]) for e in serving][:4])
    else:
        r.check("events.csv: no serving_cell without an LTE or NR serving cell", not serving,
                [(e["time_utc"], e["rat"]) for e in serving][:4])
    markers = [e for e in events if e["kind"] == "marker"]
    r.check("events.csv: the marker from Live with its note, then the one from the notification without a note",
            len(markers) == 2 and markers[0]["detail"] == result.get("marker_note") and markers[1]["detail"] == ""
            and all(m["rat"] == "-" and m["severity"] == "info" for m in markers)
            and stopped is not None and started <= utc_ms(markers[0]["time_utc"]) <= utc_ms(markers[1]["time_utc"]) <= stopped,
            [(m["time_utc"], m["detail"]) for m in markers])
    sent = result.get("notification_marker_sent_utc_ms")
    r.check("events.csv: the notification's marker has the time of its tap",
            len(markers) == 2 and isinstance(sent, int) and abs(utc_ms(markers[1]["time_utc"]) - sent) <= 3_000,
            "marker %s, action sent at %s" % (markers[1]["time_utc"] if len(markers) == 2 else None, sent))
    confirmation = result.get("notification_marker_text") or ""
    r.check("notification: Mark confirmed which marker was added and when", confirmation.startswith("Marker 2 added at "),
            confirmation)
    r.check("notification: the confirmation was brief", result.get("notification_marker_text_cleared") is True,
            result.get("notification_text_after"))
    r.check("events.csv: no session_interrupted in a stopped session", not any(e["kind"] == "session_interrupted" for e in events))

    # traffic.csv
    pings = [row for row in traffic if row["test"] == "ping"]
    downloads = [row for row in traffic if row["test"] == "download"]
    r.check("traffic.csv: ping rows to %s" % result.get("ping_target"),
            pings and all(row["target"] == result.get("ping_target") for row in pings),
            [(row["time_utc"], row["ok"], row["loss_pct"], row["rtt_avg_ms"], row["error"]) for row in pings][:6])
    r.check("traffic.csv: a ping got replies", any(row["ok"] == "1" and row["rtt_avg_ms"] and float(row["loss_pct"]) < 100 for row in pings))
    r.check("traffic.csv: download rows from the download URL",
            downloads and all(row["target"] == result.get("download_url") for row in downloads),
            [(row["time_utc"], row["ok"], row["bytes"], row["http_code"], row["mbps"], row["error"]) for row in downloads][:4])
    r.check("traffic.csv: a 1 MB download completed",
            any(row["ok"] == "1" and row["http_code"] == "200" and row["bytes"] == "1000000" and float(row["mbps"] or 0) > 0
                for row in downloads))
    failed_tests = [row for row in traffic if row["ok"] != "1"]
    failure_events = [e for e in events if e["kind"] == "test_failed"]
    r.check("traffic.csv: each failed test has an error and a test_failed event",
            all(row["error"] for row in failed_tests) and len(failure_events) == len(failed_tests),
            "%d failed rows, %d test_failed events" % (len(failed_tests), len(failure_events)))

    # cells.csv and summary.plmns
    samples = sum(int(row["samples"]) for row in cells)
    r.check("cells.csv: its samples account for every kpi row", samples == len(kpi), "%d samples, %d kpi rows" % (samples, len(kpi)))
    by_plmn: dict = {}
    for row in cells:
        if row["plmn"] and int(row["samples"]):
            by_plmn[row["plmn"]] = by_plmn.get(row["plmn"], 0) + int(row["samples"])
    plmns = {key: value for key, value in (summary.get("plmns") or {}).items() if value}
    r.check("session.json: summary.plmns matches cells.csv", plmns == by_plmn, "session.json %s, cells.csv %s" % (plmns, by_plmn))

    # report.html
    report = session / "report.html"
    html = report.read_text(encoding="utf-8", errors="replace") if report.is_file() else ""
    r.check("report.html: rendered", "<html" in html.lower(), report)
    r.check("report.html: no Procedures section", html and "<h2>Procedures</h2>" not in html)
    r.check("report.html: no Call flow section", html and "<h2>Call flow</h2>" not in html)

    # the exported zip
    zip_name = result.get("zip_name")
    zip_path = out / "device" / str(zip_name)
    if r.check("export: the zip was pulled", zip_name and zip_path.is_file(), zip_path):
        digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        r.check("export: the SHA-256 shown in the app is the zip's",
                digest == result.get("zip_sha256_ui") == result.get("zip_sha256_file"),
                "file %s, shown %s" % (digest, result.get("zip_sha256_ui")))
        with zipfile.ZipFile(zip_path) as archive:
            names = tuple(archive.namelist())
        r.check("export: the seven files in bundle order", names == BUNDLE, names)
        r.check("export: fieldtap validate on the zip exit 0", exit_status(out, zip_name) == 0, exit_status(out, zip_name))
    r.check("export: the share sheet opened", result.get("share_sheet") is True)


def check_recovered(out: Path, repo: Path, r: Results) -> None:
    listing = out / "checks" / "recovered.txt"
    killed = {}
    if listing.is_file():
        for line in listing.read_text().splitlines():
            parts = line.split()
            if len(parts) == 4:
                killed[parts[0]] = parts
    title = android_string(repo, "live_recovered_title") or "Session interrupted"
    for scenario in ("force_stop", "kill_9"):
        if not r.check("%s: a recording session was killed" % scenario, scenario in killed, sorted(killed)):
            continue
        _, dir_name, pid, kill_ms = killed[scenario]
        session = out / "sessions" / dir_name
        if not r.check("%s: the session was pulled" % scenario, (session / "session.json").is_file(), session):
            continue
        meta = read_json(session / "session.json")
        events = read_csv(session / "events.csv")
        check_counts_from_rows(scenario, meta, read_csv(session / "kpi.csv"), read_csv(session / "cellinfo.csv"),
                               read_csv(session / "cells.csv"), events, r)
        check_gaps_inside(scenario, meta, r)
        dump = out / "checks" / ("exit-info-%s.txt" % scenario)
        expected = exit_token(dump.read_text(encoding="utf-8", errors="replace"), int(pid)) if dump.is_file() else None
        r.check("%s: Android recorded an exit for pid %s" % (scenario, pid), expected is not None, expected)
        stopped_by = (meta.get("summary") or {}).get("stopped_by")
        r.check("%s: summary.stopped_by is that exit reason" % scenario, expected is not None and stopped_by == expected,
                "stopped_by %s, Android's reason %s" % (stopped_by, expected))
        interrupted = [e for e in events if e["kind"] == "session_interrupted"]
        r.check("%s: one session_interrupted event, written last" % scenario,
                len(interrupted) == 1 and events and events[-1]["kind"] == "session_interrupted",
                [(e["time_utc"], e["cause"]) for e in interrupted])
        if interrupted:
            event = interrupted[0]
            r.check("%s: session_interrupted carries the exit reason" % scenario,
                    event["cause"] == stopped_by and event["severity"] == "error" and event["rat"] == "-",
                    "cause %s, severity %s" % (event["cause"], event["severity"]))
            r.check("%s: stopped_utc is the event's time" % scenario, event["time_utc"] == meta.get("stopped_utc"),
                    "%s and %s" % (event["time_utc"], meta.get("stopped_utc")))
        if meta.get("stopped_utc"):
            before_kill = int(kill_ms) - utc_ms(meta["stopped_utc"])
            r.check("%s: stopped at the last heartbeat before the kill" % scenario, -1_000 <= before_kill <= HEARTBEAT_SLACK_MS,
                    "%d ms before the kill" % before_kill)
        else:
            r.check("%s: stopped_utc is set" % scenario, False)
        r.check("%s: capabilities.layer3 is false" % scenario, (meta.get("capabilities") or {}).get("layer3") is False)
        r.check("%s: fieldtap validate --upload exit 0" % scenario, exit_status(out, dir_name) == 0, exit_status(out, dir_name))
        if scenario == "kill_9":
            ui = out / "device" / "recovery-kill_9.json"
            ui_result = read_json(ui) if ui.is_file() else {}
            r.check("kill_9: Live named the interrupted session after the relaunch",
                    ui_result.get("banner") is True and ui_result.get("stopped_by") == stopped_by, ui_result or ui)
        else:
            window = out / "recovery" / "force_stop-relaunch.xml"
            text = window.read_text(encoding="utf-8", errors="replace") if window.is_file() else ""
            name = meta.get("name") or dir_name
            r.check("force_stop: Live named the interrupted session after the relaunch",
                    'text="%s"' % title in text and name in text, window)


def check_location_off(out: Path, r: Results) -> None:
    """LocationOffTest's session: location services switched off and on again while it recorded, with a far privacy zone."""
    result_path = out / "device" / "location-off-result.json"
    if not r.check("location off: the test wrote its result", result_path.is_file(), result_path):
        return
    result = read_json(result_path)
    dir_name = result.get("dir_name")
    session = out / "sessions" / str(dir_name)
    if not r.check("location off: the session was pulled", dir_name and (session / "session.json").is_file(), session):
        return
    r.check("location off: fieldtap validate --upload exit 0", exit_status(out, dir_name) == 0, exit_status(out, dir_name))
    meta = read_json(session / "session.json")
    events = read_csv(session / "events.csv")
    track = read_csv(session / "track.csv")
    off_ms, on_ms = result.get("location_off_utc_ms"), result.get("location_on_utc_ms")
    if not r.check("location off: the test switched location off, then on", isinstance(off_ms, int) and isinstance(on_ms, int)
                   and off_ms < on_ms, "off %s, on %s" % (off_ms, on_ms)):
        return
    story = [(i, e["time_utc"], e["kind"], e["title"], e["detail"]) for i, e in enumerate(events)
             if e["kind"] in ("gps_lost", "gps_restored", "privacy_zone", "marker")]
    lost = [i for i, e in enumerate(events) if e["kind"] == "gps_lost" and e["detail"] == LOCATION_OFF_DETAIL]
    r.check("location off: one gps_lost says location services were turned off, when they were",
            len(lost) == 1 and off_ms - LOCATION_SWITCH_SLACK_MS <= utc_ms(events[lost[0]]["time_utc"]) <= off_ms + 5_000,
            story)
    if not lost:
        return
    after = events[lost[0] + 1:]
    restored = [e for e in after if e["kind"] == "gps_restored"]
    r.check("location off: gps_restored follows once location is back on",
            restored and utc_ms(restored[0]["time_utc"]) >= on_ms - LOCATION_SWITCH_SLACK_MS, story)
    until_restored = after[:after.index(restored[0])] if restored else after
    r.check("location off: no other gps_lost before GPS is restored", not any(e["kind"] == "gps_lost" for e in until_restored), story)
    paused = [e for e in after if e["kind"] == "privacy_zone" and e["title"] == PAUSED_NO_FIX_TITLE]
    resumed = [e for e in after if e["kind"] == "privacy_zone" and e["title"] == RESUMED_TITLE]
    r.check("location off: with no fix for a minute logging paused, before location came back",
            len(paused) == 1 and off_ms < utc_ms(paused[0]["time_utc"]) < on_ms, story)
    r.check("location off: logging resumed at a fix once location was back on",
            len(resumed) == 1 and utc_ms(resumed[0]["time_utc"]) >= on_ms - LOCATION_SWITCH_SLACK_MS, story)
    r.check("location off: the marker that waited for a fix was dropped, not written",
            not any(e["kind"] == "marker" for e in events) and result.get("outcome_markers_dropped") == 1,
            "markers in events.csv %d, outcome %s" % (sum(1 for e in events if e["kind"] == "marker"),
                                                      result.get("outcome_markers_dropped")))
    privacy = meta.get("privacy") or {}
    r.check("location off: no fix placed the phone in the zone, so no pause is counted", privacy.get("zone_pauses") == 0, privacy)
    r.check("location off: stopped by the user", (meta.get("summary") or {}).get("stopped_by") == "user", meta.get("summary"))
    during = [row["time_utc"] for row in track if off_ms + LOCATION_SWITCH_SLACK_MS < utc_ms(row["time_utc"]) < on_ms]
    r.check("location off: no fix while location was off", not during, during[:3])
    r.check("location off: Live and the notification said location was off",
            result.get("live_location_off_banner") is True and result.get("notification_location_off") is True, result)
    r.check("location off: Live said the marker waits, then that it was not saved, and so did the notification",
            result.get("mark_held_message") is True and result.get("mark_dropped_message") is True
            and result.get("notification_markers_dropped") is True, result)
    r.check("location off: Session detail says a marker was not saved", result.get("detail_markers_dropped_banner") is True, result)


# The capability export's honest values. Layer-3 is never POSSIBLE on the emulator (it has no /dev/diag); the
# diag node is never PRESENT. su either grants root (then diag is ABSENT and layer-3 NOT_POSSIBLE), is absent
# (NOT_POSSIBLE), or is denied/timed out/errored (honestly UNKNOWN).
SU_STATUSES = {"GRANTED", "DENIED", "TIMED_OUT", "NOT_PRESENT", "ERROR"}
CAPABILITY_CAVEAT_MARK = "not proof"


def check_capability(out: Path, r: Results) -> None:
    """CapabilityProbeTest: the app's real capability/root/diag/USB-debugging detection and its fieldtap-capability/2 export."""
    result_path = out / "device" / "capability-result.json"
    if not r.check("capability: the test wrote its result", result_path.is_file(), result_path):
        return
    res = read_json(result_path)

    # USB debugging is reported on, and the developer-options state was read.
    r.check("capability: USB debugging (adb_enabled) is reported ON",
            res.get("adb_enabled") is True and res.get("adb_enabled_setting") == "1",
            "adb_enabled=%s, Settings adb_enabled=%s" % (res.get("adb_enabled"), res.get("adb_enabled_setting")))
    r.check("capability: developer-options state was read and matches Settings",
            isinstance(res.get("developer_options_enabled"), bool)
            and res.get("developer_options_enabled") == (res.get("developer_options_setting") == "1"),
            "reported %s, Settings %s" % (res.get("developer_options_enabled"), res.get("developer_options_setting")))

    # The passive root signals carry the always-present root-hiding caveat.
    r.check("capability: the passive root signals carry the root-hiding caveat",
            res.get("caveat_matches") is True and CAPABILITY_CAVEAT_MARK in (res.get("root_caveat") or ""),
            res.get("root_caveat"))
    r.check("capability: a root confidence was assessed", res.get("root_confidence") in {"NONE", "LOW", "MEDIUM", "HIGH"},
            res.get("root_confidence"))

    # The tiered verdict: public-API measurements always yes; push updates need the Phone permission.
    r.check("capability: tier 1 (public-API measurements) is YES", res.get("public_api") == "YES", res.get("public_api"))
    r.check("capability: tier 2 (push cell updates) needs the Phone permission",
            res.get("push_updates") == "NO" and res.get("read_phone_state_granted") is False,
            "push_updates=%s, READ_PHONE_STATE granted=%s" % (res.get("push_updates"), res.get("read_phone_state_granted")))

    # The "Check with root" outcome is honest and self-consistent for a device that genuinely has no /dev/diag.
    su_status = res.get("su_status")
    layer3 = res.get("layer3")
    r.check("capability: Check with root ran with an honest su status", su_status in SU_STATUSES, su_status)
    r.check("capability: the emulator genuinely has no /dev/diag",
            res.get("diag_absent_on_device") is True, res.get("device_diag_ls"))
    r.check("capability: the diag node is never PRESENT and layer-3 is never POSSIBLE",
            res.get("diag_device") != "PRESENT" and layer3 != "POSSIBLE",
            "diag_device=%s, layer3=%s" % (res.get("diag_device"), layer3))
    if su_status == "GRANTED" and res.get("is_root") is True:
        ok = res.get("diag_device") == "ABSENT" and layer3 == "NOT_POSSIBLE"
        detail = "rooted with no /dev/diag must read ABSENT/NOT_POSSIBLE: diag=%s, layer3=%s" % (res.get("diag_device"), layer3)
    elif su_status in ("DENIED", "TIMED_OUT", "ERROR"):
        ok, detail = layer3 == "UNKNOWN", "an untested device is honestly UNKNOWN: layer3=%s" % layer3
    else:  # NOT_PRESENT, or GRANTED-but-not-root
        ok, detail = layer3 == "NOT_POSSIBLE", "no working root means NOT_POSSIBLE: layer3=%s" % layer3
    r.check("capability: the layer-3 verdict matches the honest %s outcome" % su_status, ok, detail)
    r.check("capability: layer-3 verdict agrees with the folded report", layer3 == res.get("layer3_verdict"),
            "probe %s, verdict %s" % (layer3, res.get("layer3_verdict")))
    # Layer-3 is not definitively possible here, so the laptop-over-USB path is shown.
    r.check("capability: the laptop-over-USB path is shown when layer-3 is not possible",
            bool(res.get("laptop_path")) and "USB debugging" in (res.get("laptop_path") or ""), res.get("laptop_path"))

    # The fieldtap-capability/2 JSON export parses and carries the fields a pilot needs.
    json_path = out / "device" / str(res.get("capability_json") or "capability.json")
    if not r.check("capability: the JSON export was written", json_path.is_file(), json_path):
        return
    try:
        report = read_json(json_path)
    except (OSError, ValueError) as error:
        r.check("capability: the JSON export parses", False, str(error))
        return
    r.check("capability: the JSON export parses", True)
    r.check("capability: format is fieldtap-capability/2", report.get("format") == "fieldtap-capability/2", report.get("format"))
    top = ("app_version", "version_code", "sdk_int", "handset", "root", "root_probe", "usb", "cellular", "verdict", "notes")
    missing_top = [key for key in top if key not in report]
    r.check("capability: the export has every top-level field", not missing_top, missing_top)
    root = report.get("root") or {}
    root_fields = ("confidence", "su_binaries_present", "root_manager_packages", "build_tags_test_keys",
                   "debuggable", "secure_off", "writable_system_paths")
    r.check("capability: root carries the passive signals", all(key in root for key in root_fields),
            [key for key in root_fields if key not in root])
    probe = report.get("root_probe")
    probe_fields = ("su_status", "is_root", "selinux", "diag_device", "kernel_diag", "layer3", "elapsed_ms")
    r.check("capability: root_probe is present after Check with root",
            isinstance(probe, dict) and all(key in probe for key in probe_fields),
            probe if not isinstance(probe, dict) else [key for key in probe_fields if key not in probe])
    usb = report.get("usb") or {}
    r.check("capability: usb.adb_enabled is true and developer_options_enabled is present",
            usb.get("adb_enabled") is True and "developer_options_enabled" in usb, usb)
    cellular = report.get("cellular") or {}
    r.check("capability: cellular.read_phone_state_granted is false", cellular.get("read_phone_state_granted") is False, cellular)
    verdict = report.get("verdict") or {}
    r.check("capability: verdict tiers match (public YES, push NO, layer-3 %s)" % layer3,
            verdict.get("public_api_measurements") == "YES" and verdict.get("push_cell_updates") == "NO"
            and verdict.get("layer3_signalling") == layer3, verdict)
    notes = report.get("notes") or []
    caveat_in_notes = any(CAPABILITY_CAVEAT_MARK in note for note in notes)
    r.check("capability: notes carry the root-hiding caveat (or the check confirmed working root)",
            caveat_in_notes or (su_status == "GRANTED" and probe and probe.get("is_root") is True), notes[:2])
    for key in ("sdk_int", "version_code", "elapsed_ms"):
        source = report if key != "elapsed_ms" else probe
        r.check("capability: %s is an integer" % key,
                isinstance((source or {}).get(key), int) and not isinstance((source or {}).get(key), bool),
                (source or {}).get(key))


def is_png(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 1_000 and path.read_bytes()[:8] == PNG_SIGNATURE


def png_size(path: Path) -> Optional[tuple]:
    """Width and height from a PNG's IHDR chunk, or None."""
    header = path.read_bytes()[:24] if path.is_file() else b""
    if len(header) < 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        return None
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def device_facts(out: Path) -> dict:
    path = out / "checks" / "device.txt"
    facts = {}
    if path.is_file():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            key, _, value = line.partition("=")
            facts[key.strip()] = value.strip()
    return facts


def check_screenshots(out: Path, variants: list, r: Results) -> None:
    base = out / "device" / "screenshots"
    screen = re.fullmatch(r"(\d+)x(\d+)", device_facts(out).get("screen", ""))
    upright = (int(screen.group(1)), int(screen.group(2))) if screen else None
    for variant in variants:
        turned = variant == "landscape"
        expected = [name + "-p1" for name in FIRST_RUN_PAGED + TOUR_PAGED] + list(TOUR_SINGLE)
        if not turned:
            expected.append(LIVE_TURNED + "-p1")
        missing = [name for name in expected if not is_png(base / variant / (name + ".png"))]
        pages = len(list((base / variant).glob("*-p[0-9]*.png"))) if (base / variant).is_dir() else 0
        r.check("screenshots: every screen in %s, at every scroll position" % variant, not missing,
                "missing %s" % missing if missing else "%d pages" % pages)
        if upright:
            want = (upright[1], upright[0]) if turned else upright
            sample = base / variant / "03-live-p1.png"
            r.check("screenshots: %s is taken on the %dx%d px screen%s" % (variant, want[0], want[1], ", turned" if turned else ""),
                    png_size(sample) == want, "%s is %s" % (sample.name, png_size(sample)))
    walk_result = out / "device" / "walk-result.json"
    expected = list(WALK_SCREENS)
    if walk_result.is_file() and read_json(walk_result).get("prestart_sheet") is True:
        expected.append("07-prestart-sheet")
    missing = [name for name in expected if not is_png(base / "walk" / (name + ".png"))]
    r.check("screenshots: every step of the walk", not missing, "missing %s" % missing if missing else "")
    missing = [name for name in LOCATION_OFF_SCREENS if not is_png(base / "location-off" / (name + ".png"))]
    r.check("screenshots: location off, the dropped marker and its Session detail", not missing, "missing %s" % missing if missing else "")
    r.check("screenshots: Live after the kill -9 relaunch", is_png(base / "recovery" / "16-live-recovered-kill_9.png"))


def cmd_check(args: argparse.Namespace) -> int:
    out, repo = Path(args.out), Path(args.repo)
    r = Results()
    expect_lte_nr = args.expect_lte_nr == "true"
    print("expect LTE and NR cells: %s" % expect_lte_nr)
    variants = args.variants.split()
    print("variants: %s" % " ".join(variants))
    check_walk(out, repo, args.walk_seconds, expect_lte_nr, r)
    check_capability(out, r)
    check_location_off(out, r)
    check_recovered(out, repo, r)
    check_screenshots(out, variants, r)
    failures = r.failures
    print("%d checks, %d failed" % (len(r.items), len(failures)))
    (out / "checks").mkdir(parents=True, exist_ok=True)
    (out / "checks" / "results.json").write_text(json.dumps({"checks": r.items, "failed": len(failures)}, indent=2) + "\n",
                                                 encoding="utf-8")
    return 1 if failures else 0


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan-walk")
    plan.add_argument("--seconds", type=int, default=3600)
    plan.set_defaults(func=cmd_plan_walk)
    instrumentation = commands.add_parser("instrumentation")
    instrumentation.add_argument("raw")
    instrumentation.add_argument("--junit")
    instrumentation.add_argument("--name")
    instrumentation.set_defaults(func=cmd_instrumentation)
    reason = commands.add_parser("exit-reason")
    reason.add_argument("dumpsys")
    reason.add_argument("--pid", type=int, required=True)
    reason.set_defaults(func=cmd_exit_reason)
    check = commands.add_parser("check")
    check.add_argument("--out", required=True)
    check.add_argument("--repo", required=True)
    check.add_argument("--walk-seconds", type=int, default=180)
    check.add_argument("--expect-lte-nr", choices=("true", "false"), default="true",
                       help="false when the modem reports no LTE or NR cell (run_e2e.sh reads it from the registry)")
    check.add_argument("--variants", default="light dark font130",
                       help="the looks the first run and the screen tour were taken in, space separated")
    check.set_defaults(func=cmd_check)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
