"""The fieldtap-session/1 contract, from the Python side.

The golden session in tests/fixtures/android_session/ is what the Android
app's writer must produce byte for byte. These tests render it, validate it,
check that its generator still reproduces it, and break copies of it in each
of the ways that once broke the report. schema/columns.json, which the Kotlin
constants are generated from, must agree with the Python constants.
"""

import csv
import hashlib
import importlib.util
import json
import math
import os
import re
import shutil
import struct
import tracemalloc
import warnings
import zipfile
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_EVEN, ROUND_HALF_UP, Decimal

import pytest

from fieldtap import cli, contract, events as events_mod, gps, kpi, report, scan, session, traffic
from fieldtap.isotime import parse_iso

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FIXTURE_ROOT = os.path.join(HERE, "fixtures", "android_session")
SCHEMA_PATH = os.path.join(REPO, "schema", "columns.json")
REGENERATE_SCHEMA = "python -c \"from fieldtap import contract; contract.write_schema('schema/columns.json')\""


def _load_generator():
    path = os.path.join(HERE, "fixtures", "make_android_session.py")
    spec = importlib.util.spec_from_file_location("make_android_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GENERATOR = _load_generator()


def _fixture_dir() -> str:
    entries = [e for e in os.listdir(FIXTURE_ROOT) if os.path.isdir(os.path.join(FIXTURE_ROOT, e))]
    assert len(entries) == 1, entries
    return os.path.join(FIXTURE_ROOT, entries[0])


@pytest.fixture(scope="module")
def expected(tmp_path_factory):
    """The numbers the generator wrote, from a fresh run."""
    return GENERATOR.build(str(tmp_path_factory.mktemp("generated")))


@pytest.fixture
def app_session(tmp_path):
    """A private copy of the golden session, under its own directory name."""
    source = _fixture_dir()
    target = tmp_path / "sessions" / os.path.basename(source)
    shutil.copytree(source, str(target))
    return str(target)


def _replace(path, old, new):
    with open(path, "rb") as fh:
        data = fh.read()
    assert old.encode("utf-8") in data, (path, old)
    with open(path, "wb") as fh:
        fh.write(data.replace(old.encode("utf-8"), new.encode("utf-8"), 1))


def _edit_json(path, change):
    with open(path, encoding="utf-8") as fh:
        meta = json.load(fh)
    change(meta)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")


def _luhn_complete(body: str) -> str:
    """body plus its Luhn check digit: an IMEI-shaped number built at run time,
    so no identifier-shaped value is committed."""
    for digit in "0123456789":
        if contract._luhn_ok(body + digit):
            return body + digit
    raise AssertionError(body)


# --- the schema ---------------------------------------------------------------------------------------

def test_columns_json_matches_the_python_constants():
    with open(SCHEMA_PATH, encoding="utf-8") as fh:
        on_disk = json.load(fh)
    headers = {f["name"]: f["header"] for f in on_disk["csv"]}
    assert headers["track.csv"] == gps.COLUMNS
    assert headers["events.csv"] == events_mod.COLUMNS
    assert headers["traffic.csv"] == traffic.COLUMNS
    assert headers["kpi.csv"] == kpi.SESSION_COLUMNS == kpi.COLUMNS + ["lat", "lon"]
    assert headers["cells.csv"] == session.CELLS_COLUMNS + contract.CELLS_APP_COLUMNS
    assert headers["cellinfo.csv"] == scan.COLUMNS + contract.CELLINFO_APP_COLUMNS
    assert len(scan.COLUMNS) == 19
    for entry in on_disk["csv"]:
        assert [col["name"] for col in entry["columns"]] == entry["header"], entry["name"]
    assert on_disk["format"] == contract.FORMAT == "fieldtap-session/1"
    assert on_disk["files"] == contract.SESSION_FILES
    assert on_disk["upload_bundle"]["file_names"] == contract.SESSION_FILES
    assert on_disk["traffic_tests"]["app"] == ["ping", "download", "upload"]
    assert on_disk["events"]["signalling_kinds"] == contract.SIGNALLING_EVENT_KINDS
    # everything else too, key order included
    assert json.dumps(on_disk, indent=2) == json.dumps(contract.schema(), indent=2), \
        "schema/columns.json is out of date: " + REGENERATE_SCHEMA


def test_app_event_kinds_are_never_signalling_kinds():
    for kind, _rats, _severities, _cell in contract.APP_EVENT_KINDS:
        assert kind not in contract.SIGNALLING_EVENT_KINDS, kind
        assert not kind.startswith(tuple(contract.SIGNALLING_KIND_PREFIXES)), kind
    counted = {"handover", "handover_command"}
    for attempt, successes, failures in events_mod.PROCEDURES.values():
        counted |= {attempt} | successes | failures
    assert counted <= set(contract.SIGNALLING_EVENT_KINDS)


def test_readers_accept_a_trailing_z(tmp_path):
    z = "2026-09-10T14:30:00.000Z"
    utc = datetime(2026, 9, 10, 14, 30, tzinfo=timezone.utc)
    assert parse_iso(z) == utc and parse_iso("2026-09-10T14:30:00.000+00:00") == utc
    assert report._iso_to_dt(z) == utc
    with pytest.raises(ValueError):
        parse_iso("10/09/2026 14:30")
    (tmp_path / "track.csv").write_bytes(
        ("%s\r\n%s,38.8895000,-77.0353000,,,,gps,android\r\n" % (",".join(gps.COLUMNS), z)).encode())
    (tmp_path / "events.csv").write_bytes(
        ("%s\r\n%s,-,marker,info,Marker,,,,,,\r\n" % (",".join(events_mod.COLUMNS), z)).encode())
    (tmp_path / "traffic.csv").write_bytes(
        ("%s\r\n%s,ping,8.8.8.8,1,4.00,0.0,1.0,2.0,3.0,,,,\r\n" % (",".join(traffic.COLUMNS), z)).encode())
    assert gps.Track.read_csv(str(tmp_path / "track.csv")).fixes()[0].when == utc
    assert events_mod.read_csv(str(tmp_path / "events.csv"))[0].when == utc
    assert traffic.read_csv(str(tmp_path / "traffic.csv"))[0].when == utc


# --- the golden session ---------------------------------------------------------------------------------

def test_generator_reproduces_the_committed_fixture(tmp_path):
    result = GENERATOR.build(str(tmp_path))
    committed = _fixture_dir()
    assert os.path.basename(result["dir"]) == os.path.basename(committed)
    assert sorted(os.listdir(result["dir"])) == sorted(os.listdir(committed)) == sorted(contract.SESSION_FILES)
    for name in contract.SESSION_FILES:
        with open(os.path.join(result["dir"], name), "rb") as fh:
            fresh = fh.read()
        with open(os.path.join(committed, name), "rb") as fh:
            golden = fh.read()
        assert fresh == golden, ("%s differs from the committed fixture: rerun tests/fixtures/make_android_session.py, "
                                 "and check .gitattributes still marks the fixture -text" % name)


def test_fixture_bytes_follow_the_contract():
    directory = _fixture_dir()
    for name in contract.SESSION_FILES:
        with open(os.path.join(directory, name), "rb") as fh:
            data = fh.read()
        assert not data.startswith(b"\xef\xbb\xbf"), name
        data.decode("utf-8")
        if name.endswith(".csv"):
            assert data.endswith(b"\r\n") and data.count(b"\n") == data.count(b"\r\n"), name
        else:
            assert data.endswith(b"}\n") and b"\r" not in data, name
    assert os.path.basename(directory) == "20260910-143000_" + session.slugify("Mall walk (north path)")


def test_report_renders_the_app_session(app_session, expected):
    paths = report.build(app_session, tshark=None)
    with open(paths["summary"], encoding="utf-8") as fh:
        summary = json.load(fh)
    assert summary["kpi"]["lte"]["rsrp_avg"] == expected["lte_rsrp_avg"]
    assert summary["kpi"]["nr"]["rsrp_avg"] == expected["nr_rsrp_avg"]
    assert summary["kpi"]["lte"]["samples"] == expected["lte_samples"]
    assert summary["kpi"]["nr"]["samples"] == expected["nr_samples"]
    assert summary["gps"]["fixes"] == expected["gps_fixes"] == 120
    assert summary["traffic"]["ping"]["rtt_avg_ms"] == expected["ping_rtt_avg_ms"]
    assert summary["traffic"]["download"]["mbps_avg"] == expected["download_mbps_avg"]
    assert summary["events"]["events"] == expected["events"]
    assert summary["events"]["cell_changes"] == expected["cell_changes"] == 1
    assert summary["events"]["handovers"] == 0
    assert summary["network"]["cells"] == expected["cells"]
    assert summary["duration_s"] == 120.0
    assert summary["stopped_by"] == "user"
    assert expected["stale_rows"] > 0
    with open(paths["report"], encoding="utf-8") as fh:
        page = fh.read()
    assert '<svg class="map"' in page and "RSRP over time" in page
    assert "<h2>Serving cells</h2>" in page and "<td>84532</td>" in page
    assert "<h2>Events</h2>" in page and "North entrance" in page and "Sampling gap" in page
    assert "2.0 s between fresh samples" in page
    assert "10031250 bytes in 4.0 s" in page              # the seconds column, not 0.0
    assert "2026-09-10 14:30:00 UTC" in page
    for signalling_only in ("SIMULATED", "<h2>Procedures</h2>", "<h2>Call flow</h2>", "RRC/NAS messages"):
        assert signalling_only not in page, signalling_only
    index = report.build_index(os.path.dirname(app_session))
    with open(index, encoding="utf-8") as fh:
        listing = fh.read()
    assert "Mall walk (north path)" in listing
    assert "%s/report.html" % os.path.basename(app_session) in listing


def test_rebuild_keeps_the_app_session_data(app_session, expected):
    before = {name: open(os.path.join(app_session, name), "rb").read() for name in contract.SESSION_FILES}
    paths = report.build(app_session, tshark=None, rebuild=True)
    with open(paths["summary"], encoding="utf-8") as fh:
        summary = json.load(fh)
    assert summary["kpi"]["lte"]["rsrp_avg"] == expected["lte_rsrp_avg"]
    assert summary["events"]["events"] == expected["events"]
    for name, data in before.items():
        assert open(os.path.join(app_session, name), "rb").read() == data, name


def test_app_session_validates_clean(app_session):
    assert contract.validate_session(_fixture_dir()) == []
    assert contract.validate_session(app_session) == []
    assert contract.validate_session(app_session, upload=True) == []


def test_validate_command(app_session, tmp_path, capsys):
    assert cli.main(["validate", app_session]) == 0
    capsys.readouterr()
    assert cli.main(["validate", app_session, "--upload", "--json"]) == 0
    result = json.loads(capsys.readouterr().out)
    assert result["errors"] == 0 and result["problems"] == [] and result["format"] == contract.FORMAT
    assert cli.main(["validate", str(tmp_path / "no-such-session")]) == 2
    _replace(os.path.join(app_session, "traffic.csv"), ",ping,", ",tcp_connect,")
    capsys.readouterr()
    assert cli.main(["validate", app_session]) == 1
    out = capsys.readouterr().out
    assert out.startswith("error traffic.csv:2: ") and "tcp_connect" in out


def test_laptop_sessions_are_not_rejected(tmp_path):
    from fieldtap import auto, demo
    qmdl = str(tmp_path / "drive.qmdl")
    demo.write_qmdl(qmdl)
    workers = auto.run(auto.AutoOptions(captures=str(tmp_path / "captures"), simulate=[qmdl], open_report=False,
                                        name="demo"), log=lambda s: None)
    assert workers and workers[0].state == "done", workers[0].error
    problems = contract.validate_session(workers[0].session.dir)
    assert contract.errors(problems) == [], [str(p) for p in problems]


# --- broken copies ------------------------------------------------------------------------------------------

def _set(key, value, sub=None):
    def change(meta):
        if sub is None:
            meta[key] = value
        else:
            meta[key][sub] = value
    return lambda d: _edit_json(os.path.join(d, "session.json"), change)


def _text(name, old, new):
    return lambda d: _replace(os.path.join(d, name), old, new)


def _write(name, data):
    def mutate(d):
        with open(os.path.join(d, name), "wb") as fh:
            fh.write(data)
    return mutate


def _prepend_bom(name):
    def mutate(d):
        path = os.path.join(d, name)
        with open(path, "rb") as fh:
            data = fh.read()
        with open(path, "wb") as fh:
            fh.write(b"\xef\xbb\xbf" + data)
    return mutate


def _replace_all(path, old, new):
    with open(path, "rb") as fh:
        data = fh.read()
    assert old.encode("utf-8") in data, (path, old)
    with open(path, "wb") as fh:
        fh.write(data.replace(old.encode("utf-8"), new.encode("utf-8")))


def _put(value, *path):
    def change(meta):
        target = meta
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
    return change


def _pop(*path):
    def change(meta):
        target = meta
        for key in path[:-1]:
            target = target[key]
        target.pop(path[-1])
    return change


def _json(*changes):
    """A mutation that applies each session.json change in turn."""
    def mutate(d):
        def change(meta):
            for one in changes:
                one(meta)
        _edit_json(os.path.join(d, "session.json"), change)
    return mutate


def _both(*mutations):
    def mutate(d):
        for one in mutations:
            one(d)
    return mutate


def _append(name, text):
    def mutate(d):
        with open(os.path.join(d, name), "ab") as fh:
            fh.write(text.encode("utf-8"))
    return mutate


def _rows(name, change):
    """Rewrite a CSV's data rows with change(rows), written back as the csv module writes them."""
    def mutate(d):
        path = os.path.join(d, name)
        with open(path, encoding="utf-8", newline="") as fh:
            rows = list(csv.reader(fh))
        with open(path, "w", encoding="utf-8", newline="") as fh:
            csv.writer(fh).writerows(rows[:1] + change(rows[1:]))
    return mutate


def _swap(i, j):
    def change(rows):
        rows[i], rows[j] = rows[j], rows[i]
        return rows
    return change


def _shift_epoch(seconds):
    def change(rows):
        for row in rows:
            whole, fraction = row[1].split(".")
            row[1] = "%d.%s" % (int(whole) + seconds, fraction)
        return rows
    return change


def _cut_last_line(name, keep):
    """The file cut `keep` characters into its last field, with no line ending: an app killed mid-write."""
    def mutate(d):
        path = os.path.join(d, name)
        with open(path, "rb") as fh:
            data = fh.read()
        start = data.rstrip(b"\r\n").rfind(b"\r\n") + 2
        last = data[start:].rstrip(b"\r\n")
        with open(path, "wb") as fh:
            fh.write(data[:start] + last[:last.rfind(b",") + 1 + keep])
    return mutate


def _lf_rows(name):
    """The header ending in CR LF and the rows in LF: a header constant, then Kotlin's appendLine."""
    def mutate(d):
        path = os.path.join(d, name)
        with open(path, "rb") as fh:
            data = fh.read()
        end = data.index(b"\r\n") + 2
        with open(path, "wb") as fh:
            fh.write(data[:end] + data[end:].replace(b"\r\n", b"\n"))
    return mutate


def _nested(levels):
    value = []
    for _ in range(levels - 1):
        value = [value]
    return value


INTERRUPTED_EVENT = "2026-09-10T14:32:00.000+00:00,-,session_interrupted,error,Session interrupted,,,,,low_memory,\r\n"

IMEI_LIKE = _luhn_complete("35" + "".join(str(i % 10) for i in range(1, 13)))
IMSI_LIKE = "2" + "0" * 13 + "7"
ICCID_LIKE = "89" + "0" * 17

BROKEN = [
    # id, mutation, upload, file of the expected error, words in its message
    ("naive-timestamp", _text("events.csv", "2026-09-10T14:30:45.200+00:00", "2026-09-10T14:30:45.200"), False,
     "events.csv", "no UTC offset"),
    ("naive-started", _set("started_utc", "2026-09-10T14:30:00.000"), False, "session.json", "no UTC offset"),
    ("blank-lat", _text("track.csv", ",38.8895000,-77.0353000,", ",,-77.0353000,"), False, "track.csv", "lat is blank"),
    ("partial-last-line", lambda d: open(os.path.join(d, "track.csv"), "ab").write(b"2026-09-10T14:32:00.0"), False,
     "track.csv", "fields where the header has"),
    ("summary-null", _set("summary", None), False, "session.json", "summary is null"),
    ("handset-null", _set("handset", None), False, "session.json", "handset is null"),
    ("files-null", _set("files", None), False, "session.json", "files is null"),
    ("plmns-list", _set("summary", {"stopped_by": "user", "plmns": ["311480"]}), False, "session.json",
     "summary.plmns is an array"),
    ("renamed-header", _text("kpi.csv", "rsrp_dbm", "rsrp"), False, "kpi.csv", "column 6 is 'rsrp'"),
    ("byte-order-mark", _prepend_bom("track.csv"), False, "track.csv", "byte order mark"),
    ("handover-event", _text("events.csv", ",marker,info,", ",handover,ok,"), False, "events.csv", "signalling"),
    ("rrc-event", _text("events.csv", ",marker,info,", ",rrc_attempt,info,"), False, "events.csv", "signalling"),
    ("traffic-test", _text("traffic.csv", ",ping,", ",tcp_connect,"), False, "traffic.csv", "silently ignores"),
    ("traffic-ok", _text("traffic.csv", ",8.8.8.8,1,", ",8.8.8.8,yes,"), False, "traffic.csv", "ok 'yes'"),
    ("decimal-comma", _text("traffic.csv", ",44.7,", ",\"44,7\","), False, "traffic.csv", "not a number"),
    ("extra-file-upload", _write("notes.txt", b"lobby"), True, "notes.txt", "cannot be uploaded"),
    ("report-output-upload", _write("summary.json", b"{}"), True, "summary.json", "cannot be uploaded"),
    ("imei-in-note", _text("events.csv", "North entrance", "handset " + IMEI_LIKE), False, "events.csv", "IMEI"),
    ("imei-in-session-json", _set("note", "phone " + IMEI_LIKE), False, "session.json", "IMEI"),
    ("imsi-in-session-json", _set("location", "sim " + IMSI_LIKE), False, "session.json", "IMSI"),
    ("iccid-in-handset", _set("handset", {"sim_operator_name": ICCID_LIKE}), False, "session.json", "ICCID"),
    ("identifier-key", _set("handset", {"model": "SM-S921U", "serial": "R5CX00000"}), False, "session.json",
     "subscriber or device identifier"),
    ("android-unavailable", _text("kpi.csv", ",-84.0,-8.0,", ",2147483647,-8.0,"), False, "kpi.csv", "unavailable"),
    ("rsrp-out-of-range", _text("kpi.csv", ",-84.0,-8.0,", ",-184.0,-8.0,"), False, "kpi.csv", "outside"),
    ("kpi-rat", _text("kpi.csv", ",lte,,212,", ",5g,,212,"), False, "kpi.csv", "ignores rows"),
    ("time-epoch-ms", _text("kpi.csv", ",1789050600.400,", ",1789050600400,"), False, "kpi.csv", "outside"),
    ("format-missing", lambda d: _edit_json(os.path.join(d, "session.json"), lambda m: m.pop("format")), False,
     "session.json", "format is missing"),
    ("transport-file", _set("transport", "file", sub="transport"), False, "session.json", "SIMULATED"),
    ("precision-none-with-track", _set("privacy", {"data_class": "kpi", "location_precision": "none", "zone_pauses": 0,
                                                   "consent_version": "2026-09-01", "consent_sha256": "0" * 64}),
     False, "track.csv", "left out"),
    # a misspelt or missing transport, or defaults a JSON serializer left out, keep every app rule on
    ("transport-misspelt", _json(_put("android_api", "transport", "transport"), _pop("capabilities")), False,
     "session.json", 'transport.transport is "android_api"; allowed: "android-api"'),
    ("transport-missing", _json(_pop("transport", "transport"), _pop("capabilities")), False, "session.json",
     "transport.transport is missing"),
    ("misspelt-transport-identifier-key", _json(_put("Android-API", "transport", "transport"),
                                                _put("R5CX00000", "handset", "serial")), False, "session.json",
     "subscriber or device identifier"),
    ("misspelt-transport-handover", _both(_json(_put("android_api", "transport", "transport"), _pop("capabilities")),
                                          _text("events.csv", ",marker,info,", ",handover,ok,")), False,
     "events.csv", "signalling"),
    ("defaults-left-out-handover", _both(_json(_pop("format"), _pop("transport", "transport"), _pop("capabilities")),
                                         _text("events.csv", ",marker,info,", ",handover,ok,")), False,
     "events.csv", "signalling"),
    ("summary-messages-string", _json(_put({"lte_rrc": "12"}, "summary", "messages")), False, "session.json",
     "summary.messages.lte_rrc"),
    ("summary-messages-null-value", _json(_put({"lte_rrc": None}, "summary", "messages")), False, "session.json",
     "summary.messages.lte_rrc"),
    ("modem-clock-in-app-summary", _json(_put("2026-09-10T13:30:00.000+00:00", "summary", "modem_time_first_utc")),
     False, "session.json", "modem clock"),
    ("interrupted-closed-at-relaunch", _both(_json(_put("2026-09-11T09:12:33.000+00:00", "stopped_utc")),
                                             _append("events.csv", INTERRUPTED_EVENT)), False, "session.json",
     "session_interrupted"),
    ("mccmnc-trailing-newline", _json(_put("311480\n", "handset", "operator_mccmnc")), False, "session.json",
     "does not match"),
    ("session-json-too-deep", _json(_put(_nested(40), "note")), False, "session.json", "nest 41 levels deep"),
    ("torn-kpi-lon", _cut_last_line("kpi.csv", 2), False, "kpi.csv", "no line ending"),
    ("track-out-of-order", _rows("track.csv", _swap(10, 90)), False, "track.csv", "before the row above"),
    ("track-null-island", _text("track.csv", ",38.8895000,-77.0353000,", ",0.0000000,0.0000000,"), False,
     "track.csv", "0,0"),
    ("kpi-local-time-as-utc", _rows("kpi.csv", _shift_epoch(-4 * 3600)), False, "kpi.csv", "before started_utc"),
    ("plausible-mismatch", _text("cells.csv", ",android,True,", ",android,False,"), False, "cells.csv", "plausible"),
]


@pytest.mark.parametrize("mutate, upload, file, words", [case[1:] for case in BROKEN], ids=[case[0] for case in BROKEN])
def test_broken_sessions_are_reported(app_session, mutate, upload, file, words):
    mutate(app_session)
    problems = contract.validate_session(app_session, upload=upload)
    errors = contract.errors(problems)
    assert any(p.file == file and words in p.message for p in errors), [str(p) for p in problems]


def test_a_trailing_z_is_only_a_warning(app_session):
    _replace(os.path.join(app_session, "events.csv"), "2026-09-10T14:30:45.200+00:00", "2026-09-10T14:30:45.200Z")
    problems = contract.validate_session(app_session)
    assert contract.errors(problems) == [], [str(p) for p in problems]
    assert [(p.severity, p.file, p.line) for p in problems] == [("warning", "events.csv", 4)]
    assert "ends in Z" in problems[0].message


def test_an_extra_file_is_fine_until_upload(app_session):
    _write("notes.txt", b"lobby")(app_session)
    assert contract.validate_session(app_session) == []
    assert contract.errors(contract.validate_session(app_session, upload=True))


def test_validation_never_raises_on_junk(tmp_path):
    assert contract.errors(contract.validate_session(str(tmp_path / "missing")))
    junk = tmp_path / "20260910-143000_junk"
    junk.mkdir()
    assert any(p.file == "session.json" for p in contract.validate_session(str(junk)))
    (junk / "session.json").write_bytes(b"\xff\xfe not json")
    (junk / "kpi.csv").write_bytes(b"\x00\x01\x02")
    (junk / "track.csv").write_bytes(b"")
    (junk / "events.csv").write_bytes(b'time_utc,rat\r\n"unterminated')
    assert contract.errors(contract.validate_session(str(junk)))
    (junk / "session.json").write_bytes(b"[1, 2]")
    assert contract.errors(contract.validate_session(str(junk)))


@pytest.mark.parametrize("mutate", [
    _both(_json(_put("approx_110m", "privacy", "location_precision")),
          _text("track.csv", ",38.8895000,-77.0353000,", ",1e308,-77.0350000,")),
    _text("kpi.csv", "age_ms=500 src", "age_ms=" + "9" * 5000 + " src"),
    _json(_put("0001-01-01T00:00:00.000+05:00", "started_utc")),
    _json(_put("9999-12-31T23:59:59.000-05:00", "stopped_utc")),
    _write("kpi.csv", b"frame,time_epoch\r\n\xff\xfe\r\n"),
    _write("events.csv", b"\r" * 10),
], ids=["huge-lat", "huge-age", "year-1", "year-9999", "not-utf8", "bare-cr"])
def test_validation_never_raises_on_hostile_values(app_session, mutate):
    mutate(app_session)
    assert contract.errors(contract.validate_session(app_session, upload=True)) is not None


@pytest.mark.parametrize("payload", [
    b"[" * 3000 + b"]" * 3000,
    b'{"started_utc": "2026-09-10T14:30:00.000+00:00", "x": ' + b"[" * 1000 + b"]" * 1000 + b"}",
    b'{"a":' * 3000 + b"1" + b"}" * 3000,
], ids=["arrays", "object-around-arrays", "objects"])
def test_deeply_nested_session_json_is_an_error_not_a_crash(tmp_path, capsys, payload):
    session_dir = tmp_path / "20260910-143000_deep"
    session_dir.mkdir()
    (session_dir / "session.json").write_bytes(payload)
    problems = contract.validate_session(str(session_dir), upload=True)
    assert any(p.file == "session.json" and "nest" in p.message for p in contract.errors(problems)), \
        [str(p) for p in problems]
    assert cli.main(["validate", str(session_dir), "--json"]) == 1
    assert json.loads(capsys.readouterr().out)["errors"] >= 1
    assert os.path.isfile(report.build_index(str(tmp_path)))


def test_validation_limits(app_session, monkeypatch):
    monkeypatch.setattr(contract, "MAX_CSV_LINE_CHARS", 60)
    problems = contract.validate_session(app_session)
    assert any(p.file == "kpi.csv" and p.line == 1 and "longer than 60 characters" in p.message
               for p in contract.errors(problems)), [str(p) for p in problems]
    monkeypatch.setattr(contract, "MAX_SESSION_JSON_BYTES", 100)
    assert any(p.file == "session.json" and "at most 100 bytes" in p.message
               for p in contract.errors(contract.validate_session(app_session)))
    monkeypatch.setattr(contract, "MAX_UNCOMPRESSED_BYTES", 1000)
    problems = contract.validate_session(app_session, upload=True)
    assert len(problems) == 1 and "an upload holds at most 1000" in problems[0].message, [str(p) for p in problems]


def test_a_large_csv_is_validated_in_little_memory(app_session):
    """validate reads a CSV a line at a time: memory must not grow with the file."""
    path = os.path.join(app_session, "kpi.csv")
    with open(path, "rb") as fh:
        header = fh.readline()
        row = fh.readline().decode("utf-8").split(",")
    with open(path, "wb") as fh:
        fh.write(header)
        start_ms = int(row[1].replace(".", ""))
        for i in range(24000):
            row[1] = "%d.%03d" % divmod(start_ms + i, 1000)
            fh.write((",".join(row)).encode("utf-8"))
    size = os.path.getsize(path)
    assert size > 2 * 1024 * 1024
    tracemalloc.start()
    try:
        problems = contract.validate_session(app_session)
        _current, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert contract.errors(problems) == [], [str(p) for p in problems]
    assert peak < size / 8, (peak, size)


# --- what the checks catch, beyond the broken cases -----------------------------------------------------------

WARNED = [
    # id, mutation, file, line, words in the one warning
    ("lf-data-rows", _lf_rows("kpi.csv"), "kpi.csv", 2, "instead of CR LF (\\r\\n), the first at line 2"),
    ("line-break-in-note", _text("events.csv", "North entrance – badge reader, door 3",
                                 "North entrance\r\nbadge reader, door 3"), "events.csv", 4, "runs over lines 4 to 5"),
]


@pytest.mark.parametrize("mutate, file, line, words", [case[1:] for case in WARNED], ids=[case[0] for case in WARNED])
def test_writer_slips_are_warnings(app_session, mutate, file, line, words):
    mutate(app_session)
    problems = contract.validate_session(app_session)
    assert [(p.severity, p.file, p.line) for p in problems] == [("warning", file, line)], [str(p) for p in problems]
    assert words in problems[0].message


def test_the_zero_sign_note_names_only_a_negative_zero(app_session):
    _text("kpi.csv", ",-84.0,-8.0,", ",-84,-0.0,")(app_session)
    messages = [p.message for p in contract.validate_session(app_session)]
    assert "rsrp_dbm '-84' is not written as %.1f" in messages, messages
    assert "rsrq_db '-0.0' is not written as %.1f (no sign on zero)" in messages, messages


def test_route_problems_are_warnings_in_a_laptop_session(app_session):
    _json(_pop("format"), _pop("capabilities"), _pop("collection"), _pop("privacy"),
          _put("usb", "transport", "transport"))(app_session)
    _rows("track.csv", _swap(10, 90))(app_session)
    _text("track.csv", ",38.8895000,-77.0353000,", ",0.0000000,0.0000000,")(app_session)
    problems = contract.validate_session(app_session)
    assert contract.errors(problems) == [], [str(p) for p in problems]
    warned = " | ".join(p.message for p in problems)
    assert "0,0" in warned and "before the row above" in warned, warned


def test_an_interrupted_session_closed_at_its_heartbeat_is_clean(app_session):
    _json(_put("low_memory", "summary", "stopped_by"))(app_session)
    _append("events.csv", INTERRUPTED_EVENT)(app_session)
    assert contract.validate_session(app_session) == []


def test_an_nr_leg_without_identity_is_valid(app_session):
    _text("cells.csv", ",393,77,650000,,,,android,True,", ",,77,,,,,android,False,")(app_session)
    _replace_all(os.path.join(app_session, "kpi.csv"), ",nr,,393,", ",nr,,,")
    assert contract.validate_session(app_session) == []
    report.build(app_session, tshark=None)


def test_patterns_mean_the_same_in_python_and_kotlin():
    schema = contract.schema()
    assert schema["patterns"]["match"] == "full"
    patterns = [field["pattern"] for field in schema["session_json"]["fields"] if field["pattern"]]
    patterns += [col["pattern"] for entry in schema["csv"] for col in entry["columns"] if col["pattern"]]
    patterns += [schema["kpi"]["comment_pattern"], schema["timestamps"]["utc_pattern"], schema["directory"]["pattern"]]
    for pattern in patterns:
        plain = pattern.replace(r"[\s\S]", "").replace("\\.", "")
        assert not re.search(r"\\[sSdDwWbB]", plain), pattern
        assert "." not in re.sub(r"\[[^\]]*\]", "", plain), pattern
    not_blank = contract.NOT_BLANK_PATTERN
    for value in ("Mall walk (north path)", "0.1.0", " x\n"):
        assert re.fullmatch(not_blank, value), value
    for value in ("", " ", " \t\r\n"):
        assert not re.fullmatch(not_blank, value), value


def _digits(value, decimals, rounding, shortest=False):
    exact = Decimal(repr(value)) if shortest else Decimal(value)
    return str(exact.quantize(Decimal(1).scaleb(-decimals), rounding=rounding))


# The usual Kotlin mistakes, emulated. java.util.Formatter rounds half up on the
# shortest decimal form, as BigDecimal.valueOf(v) with HALF_UP does.
ROUNDING_MISTAKES = {
    "String.format, BigDecimal.valueOf(v) HALF_UP": lambda v, n: _digits(v, n, ROUND_HALF_UP, shortest=True),
    "BigDecimal.valueOf(v) HALF_EVEN": lambda v, n: _digits(v, n, ROUND_HALF_EVEN, shortest=True),
    "BigDecimal(v) HALF_UP": lambda v, n: _digits(v, n, ROUND_HALF_UP),
    "Math.round": lambda v, n: "%.*f" % (n, math.floor(v * 10 ** n + 0.5) / 10 ** n),
}


def test_the_fixture_catches_the_usual_rounding_mistakes():
    directory = _fixture_dir()
    probes = GENERATOR.rounding_probes()
    for name, when, column, value, decimals in probes:
        with open(os.path.join(directory, name), encoding="utf-8", newline="") as fh:
            rows = [row for row in csv.DictReader(fh) if row["time_utc"] == when]
        assert len(rows) == 1, (name, when)
        # the contract's BigDecimal(v).setScale(n, HALF_EVEN) gives Python's "%.nf"
        assert rows[0][column] == "%.*f" % (decimals, value) == _digits(value, decimals, ROUND_HALF_EVEN), \
            (name, column, rows[0][column])
    for mistake, digits in ROUNDING_MISTAKES.items():
        assert any(digits(value, decimals) != "%.*f" % (decimals, value) for _n, _w, _c, value, decimals in probes), \
            mistake


# --- the report, on sessions validate flags ---------------------------------------------------------------------

def test_the_event_table_keeps_markers_past_its_limit(app_session):
    """A 5G icon flapping through a long NSA drive gives far more events than the table lists."""
    start = datetime(2026, 9, 10, 14, 30, 1, tzinfo=timezone.utc)

    def flapping(rows):
        extra = [[session.iso(start + timedelta(milliseconds=150 * i)), "nr", "nr_display", "info",
                  "5G icon on" if i % 2 == 0 else "5G icon off", "override NR_NSA, network LTE", "", "", "", "", ""]
                 for i in range(report.MAX_EVENT_ROWS)]
        return sorted(rows + extra, key=lambda row: row[0])

    _rows("events.csv", flapping)(app_session)
    assert contract.validate_session(app_session) == []
    paths = report.build(app_session, tshark=None)
    with open(paths["summary"], encoding="utf-8") as fh:
        total = json.load(fh)["events"]["events"]
    assert total > report.MAX_EVENT_ROWS
    with open(paths["report"], encoding="utf-8") as fh:
        table = re.search(r"<h2>Events</h2>(.*?)</section>", fh.read(), re.S).group(1)
    assert table.count("<tr><td>") == report.MAX_EVENT_ROWS
    for kept in ("North entrance", "Serving cell changed", "Sampling gap"):
        assert kept in table, kept
    assert "%d more events are not listed here; events.csv has all %d." % (total - report.MAX_EVENT_ROWS, total) \
        in table


def test_report_and_index_survive_a_bad_summary(app_session):
    _json(_put({"lte_rrc": "12"}, "summary", "messages"), _put(None, "modem"), _pop("handset", "model"))(app_session)
    assert contract.errors(contract.validate_session(app_session))
    report.build(app_session, tshark=None)
    with open(report.build_index(os.path.dirname(app_session)), encoding="utf-8") as fh:
        assert "Mall walk (north path)" in fh.read()


def test_report_times_are_utc_whatever_the_offset(app_session):
    _json(_put("2026-09-10T10:30:00.000-04:00", "started_utc"))(app_session)
    paths = report.build(app_session, tshark=None)
    with open(paths["report"], encoding="utf-8") as fh:
        page = fh.read()
    assert "2026-09-10 14:30:00 UTC" in page and "10:30:00 UTC" not in page
    with open(report.build_index(os.path.dirname(app_session)), encoding="utf-8") as fh:
        assert "<td>2026-09-10 14:30:00</td>" in fh.read()


def test_report_of_a_misspelt_transport_stays_measurement_only(app_session):
    _json(_put("android_api", "transport", "transport"), _pop("capabilities"))(app_session)
    paths = report.build(app_session, tshark=None)
    with open(paths["report"], encoding="utf-8") as fh:
        page = fh.read()
    for signalling_only in ("<h2>Procedures</h2>", "<h2>Call flow</h2>", "RRC/NAS messages"):
        assert signalling_only not in page, signalling_only


def test_report_of_an_app_session_gives_no_laptop_hints(app_session):
    os.remove(os.path.join(app_session, "track.csv"))
    _json(_pop("files", "track"))(app_session)
    _write("traffic.csv", (",".join(traffic.COLUMNS) + "\r\n").encode("utf-8"))(app_session)
    paths = report.build(app_session, tshark=None)
    with open(paths["report"], encoding="utf-8") as fh:
        page = fh.read()
    assert "--gps" not in page and "--traffic" not in page
    assert "No GPS track in this session." in page and "No traffic tests were run." in page


def test_ping_loss_counts_the_failed_runs():
    when = datetime(2026, 9, 10, 14, 30, tzinfo=timezone.utc)
    results = [traffic.TestResult(when, "ping", "8.8.8.8", True, {"loss_pct": 0.0, "rtt_avg_ms": 40.0}),
               traffic.TestResult(when, "ping", "8.8.8.8", False, {"loss_pct": 100.0, "error": "100% packet loss"})]
    ping = traffic.summary(results)["ping"]
    assert ping["loss_pct_avg"] == 50.0 and ping["rtt_avg_ms"] == 40.0 and ping["failed"] == 1


# --- upload bundles ---------------------------------------------------------------------------------------

def _bundle(path, extra=(), skip=()):
    with zipfile.ZipFile(str(path), "w", zipfile.ZIP_DEFLATED) as archive:
        for name in contract.SESSION_FILES:
            if name not in skip:
                archive.write(os.path.join(_fixture_dir(), name), name)
        for item, data in extra:
            archive.writestr(item, data)
    return str(path)


def _raw_name(name, mode=None):
    """A ZipInfo whose stored name is exactly `name` (zipfile would otherwise
    turn a backslash into a slash on Windows)."""
    info = zipfile.ZipInfo("placeholder")
    info.filename = name
    info.compress_type = zipfile.ZIP_DEFLATED
    if mode is not None:
        info.external_attr = mode << 16
    return info


def test_a_bundle_of_the_fixture_is_accepted(tmp_path):
    path = _bundle(tmp_path / (os.path.basename(_fixture_dir()) + ".zip"))
    assert contract.validate_bundle(path) == []
    with open(path, "rb") as fh:
        assert contract.sha256_file(path) == hashlib.sha256(fh.read()).hexdigest()
    assert cli.main(["validate", path]) == 0


@pytest.mark.parametrize("entry, words", [
    ("../x", "containing .."),
    ("../session.json", "containing .."),
    ("/etc/passwd", "absolute path"),
    ("C:/Windows/x.csv", "drive-letter"),
    (_raw_name("sessions\\kpi.csv"), "backslash"),
    ("sessions/", "directory entry"),
    ("sessions/kpi.csv", "inside a directory"),
    (_raw_name("cellinfo.csv", mode=0o120777), "symbolic link"),
    ("notes.txt", "not one of the seven"),
    ("Session.json", "differs only in case"),
], ids=["dotdot", "dotdot-allowed-name", "absolute", "drive", "backslash", "directory", "nested", "symlink",
        "not-allowed", "case"])
def test_bundles_with_bad_entries_are_rejected(tmp_path, entry, words):
    path = _bundle(tmp_path / "bad.zip", extra=[(entry, b"x")], skip=("cellinfo.csv",))
    problems = contract.validate_bundle(path)
    assert any(words in p.message for p in contract.errors(problems)), [str(p) for p in problems]


def test_bundles_with_duplicate_names_are_rejected(tmp_path):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        path = _bundle(tmp_path / "dup.zip", extra=[("kpi.csv", b"frame\r\n")], skip=("cellinfo.csv",))
    problems = contract.validate_bundle(path)
    assert any(p.file == "kpi.csv" and "duplicate" in p.message for p in problems), [str(p) for p in problems]


def test_bundle_limits(tmp_path):
    path = _bundle(tmp_path / "ok.zip")
    assert contract.errors(contract.validate_bundle(path, max_compressed_bytes=1000))
    assert contract.errors(contract.validate_bundle(path, max_uncompressed_bytes=1000))
    too_many = tmp_path / "many.zip"
    with zipfile.ZipFile(str(too_many), "w") as archive:
        for i in range(8):
            archive.writestr("f%d.csv" % i, b"x")
    assert any("entries" in p.message for p in contract.validate_bundle(str(too_many)))
    not_zip = tmp_path / "not.zip"
    not_zip.write_bytes(b"PK but not really")
    assert contract.errors(contract.validate_bundle(str(not_zip)))


@pytest.fixture(scope="module")
def zip_bomb(tmp_path_factory):
    """A few hundred kilobytes that inflate past the 200 MiB cap."""
    path = str(tmp_path_factory.mktemp("bomb") / "bomb.zip")
    block = b"0" * (1 << 20)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.writestr("session.json", b"{}")
        with archive.open("cellinfo.csv", "w") as fh:
            for _ in range(contract.MAX_UNCOMPRESSED_BYTES // len(block) + 1):
                fh.write(block)
    return path


def test_a_zip_bomb_is_rejected_while_reading(zip_bomb):
    assert os.path.getsize(zip_bomb) < contract.MAX_COMPRESSED_BYTES // 50
    problems = contract.validate_bundle(zip_bomb)
    assert any("uncompressed" in p.message for p in contract.errors(problems)), [str(p) for p in problems]


def test_a_bundle_that_lies_about_its_size_is_rejected(zip_bomb, tmp_path):
    with open(zip_bomb, "rb") as fh:
        data = bytearray(fh.read())
    entry = data.rfind(b"PK\x01\x02")                  # central directory record of cellinfo.csv
    assert data[entry + 46:entry + 46 + len("cellinfo.csv")] == b"cellinfo.csv"
    struct.pack_into("<I", data, entry + 24, 1000)     # claims 1000 bytes uncompressed
    liar = tmp_path / "liar.zip"
    liar.write_bytes(bytes(data))
    problems = contract.validate_bundle(str(liar))
    assert any(p.file == "cellinfo.csv" for p in contract.errors(problems)), [str(p) for p in problems]
