"""The fieldtap-session/1 contract, and `fieldtap validate`.

A session directory written by anything other than this package (the Android
app first) must be readable by `fieldtap.report.build`. This module holds the
contract as data (`schema()`), checks a session directory against it
(`validate_session`) and checks an upload bundle before anything is extracted
(`validate_bundle`).

schema/columns.json is `schema()` written out, so the Kotlin writer can
generate its constants from it; tests/test_android_session.py fails when the
two disagree. docs/SESSION-FORMAT.md is the prose version. Column lists come
from the modules that read and write them (gps.COLUMNS, events.COLUMNS,
traffic.COLUMNS, kpi.SESSION_COLUMNS, session.CELLS_COLUMNS, scan.COLUMNS);
only the Android-only extensions are defined here.

Problems are reported, never raised. Standard library only.
"""

from __future__ import annotations

import collections
import csv
import hashlib
import io
import json
import math
import os
import re
import struct
import zipfile
import zlib
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from . import events as events_mod
from . import gps as gps_mod
from . import kpi as kpi_mod
from . import scan as scan_mod
from . import session as session_mod
from . import traffic as traffic_mod

FORMAT = "fieldtap-session/1"
SCHEMA_VERSION = 1

APP_TRANSPORT = "android-api"
SIMULATED_TRANSPORT = "file"
LAPTOP_TRANSPORTS = ["serial", "usb", "tcp", "adb", "file"]
ANDROID_UNAVAILABLE = 2147483647

SESSION_JSON = session_mod.SIDE_CAR
KPI_CSV = "kpi.csv"
TRACK_CSV = "track.csv"
EVENTS_CSV = "events.csv"
TRAFFIC_CSV = "traffic.csv"
CELLS_CSV = session_mod.CELLS_FILE
CELLINFO_CSV = "cellinfo.csv"
SESSION_FILES = [SESSION_JSON, KPI_CSV, TRACK_CSV, EVENTS_CSV, TRAFFIC_CSV, CELLS_CSV, CELLINFO_CSV]
# Written by `fieldtap report`, never by the app, never uploaded.
REPORT_OUTPUTS = ["summary.json", "report.html", "index.html"]

CSV_LINE_TERMINATOR = "\r\n"     # what Python's csv module writes, on every platform
JSON_LINE_TERMINATOR = "\n"

UTC_PATTERN = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\+00:00$"
UTC_KOTLIN_PATTERN = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
UTC_EXAMPLE = "2026-09-10T14:30:00.000+00:00"
# What datetime.fromisoformat reads on Python 3.9 and 3.10: a date, any one
# separator character, a time whose fraction is 3 or 6 digits, and an offset
# written +HH:MM. Newer Pythons read more, so passing on 3.12 proves nothing.
PORTABLE_ISO_PATTERN = (r"^[0-9]{4}-[0-9]{2}-[0-9]{2}.[0-9]{2}(:[0-9]{2}(:[0-9]{2}(\.[0-9]{3}([0-9]{3})?)?)?)?"
                        r"([+-][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{6})?)?)?$")

DIRECTORY_PATTERN = r"^[0-9]{8}-[0-9]{6}_[A-Za-z0-9._-]{1,48}$"
SLUG_MAX = 48

MAX_COMPRESSED_BYTES = 50 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 200 * 1024 * 1024
ZIP_STORED, ZIP_DEFLATED = 0, 8

# What validate reads at most, so a hostile file costs bounded time and memory.
MAX_SESSION_JSON_BYTES = 16 * 1024 * 1024
MAX_JSON_DEPTH = 32                 # the contract's session.json nests 4 deep
MAX_CSV_LINE_CHARS = 1024 * 1024

# Oldest and newest plausible time_epoch: a value outside is milliseconds, or garbage.
EPOCH_MIN = 946684800.0     # 2000-01-01
EPOCH_MAX = 4102444800.0    # 2100-01-01
KPI_MAX_AGE_MS = 11000      # kpi.csv takes a sample at most 11 s old (10 s interval) ...
KPI_MAX_AGE_SHORT_MS = 2500  # ... and at most 2.5 s old while Android's 2 s interval applies
GPS_MATCH_SECONDS = 5.0     # a KPI row gets a position only from a fix within 5 s
# A kpi.csv time_epoch must lie within the session, give or take this much: a sample
# is measured up to 11 s before it arrives, and an interrupted session is closed at
# its last heartbeat (every 5 s). A local clock written as UTC is off by 30 min or more.
KPI_WINDOW_SLACK_SECONDS = 60.0
APPROX_110M_DECIMALS = 3
INTERRUPTED_STOP_TOLERANCE_SECONDS = 1.0

# Every `pattern` in the contract must match the whole value (re.fullmatch in
# Python, Regex.matches in Kotlin), and is written with explicit character
# classes: \s, \d, \w, \b and "." mean different things in Python, the JVM and
# Android's ICU regex.
NOT_BLANK_PATTERN = r"^[\s\S]*[^ \t\r\n][\s\S]*$"
UUID_PATTERN = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
PLMN_PATTERN = r"^[0-9]{5,6}$"
PLMN_LIST_PATTERN = r"^([0-9]{5,6}(, [0-9]{5,6})*)?$"
TOKEN_PATTERN = r"^[a-z0-9_]+$"
KPI_COMMENT_PATTERN = r"^android-api age_ms=(0|[1-9][0-9]*) src=(request|push)$"

APP_TRAFFIC_TESTS = ["ping", "download", "upload"]
LAPTOP_TRAFFIC_TESTS = ["ping", "download", "upload", "iperf3"]
EVENT_SEVERITIES = ["info", "ok", "warn", "error"]
LOCATION_PRECISIONS = ["full", "approx_110m", "none"]

# --- ranges (3GPP reporting ranges, widened to what Android and fieldtap.kpi produce) -----------

LTE_RSRP = [-156.0, -43.0]      # TS 36.133 RSRP incl. the extended range; kpi.lte_rsrp_dbm(97) = -43
NR_RSRP = [-156.0, -29.0]       # TS 38.133 SS-RSRP 0..127
LTE_RSRQ = [-34.0, 3.0]         # TS 36.133 extended RSRQ; Android getRsrq
NR_RSRQ = [-43.0, 20.5]         # TS 38.133 SS-RSRQ 0..127
LTE_SINR = [-23.0, 40.0]        # RS-SINR; Android getRssnr is -20..30
NR_SINR = [-23.0, 40.5]         # TS 38.133 SS-SINR 0..127
LTE_PCI, NR_PCI = [0, 503], [0, 1007]
LTE_EARFCN, NR_ARFCN = [0, 262143], [0, 3279165]
LTE_ECI, NR_NCI = [0, 268435455], [0, 68719476735]


LIST_SEPARATOR = ", "


def _col(name, type_, required=False, always_blank=False, decimals=None, min_=None, max_=None,
         range_by_rat=None, unit=None, values=None, pattern=None, list_allowed=False,
         list_order=None, breaks_report=False) -> dict:
    """One column, with every key present so code can be generated from it.

    `format` is the Python printf reference for the digits (see
    schema()["encoding"]["number_rounding"]); it is never a java.util.Formatter
    format. A text list column has `list_order` and `list_separator`."""
    if type_ == "integer":
        fmt = "%d"
    elif type_ == "decimal":
        fmt = "%%.%df" % decimals
    else:
        fmt = None
    return {"name": name, "type": type_, "format": fmt, "decimals": decimals, "required": required,
            "always_blank": always_blank, "min": min_, "max": max_, "range_by_rat": range_by_rat,
            "unit": unit, "values": values, "pattern": pattern, "list_allowed": list_allowed,
            "list_separator": LIST_SEPARATOR if list_order else None, "list_order": list_order,
            "breaks_report": breaks_report}


TRACK_SPEC = [
    _col("time_utc", "utc", required=True, breaks_report=True),
    _col("lat", "decimal", required=True, decimals=7, min_=-90.0, max_=90.0, unit="degree", breaks_report=True),
    _col("lon", "decimal", required=True, decimals=7, min_=-180.0, max_=180.0, unit="degree", breaks_report=True),
    _col("accuracy_m", "decimal", decimals=1, min_=0.0, unit="m", breaks_report=True),
    _col("altitude_m", "decimal", decimals=1, min_=-1000.0, max_=20000.0, unit="m", breaks_report=True),
    _col("speed_mps", "decimal", decimals=2, min_=0.0, max_=400.0, unit="m/s", breaks_report=True),
    _col("provider", "enum", required=True, values=["gps", "fused", "network"]),
    _col("source", "enum", required=True, values=["android"]),
]

KPI_SPEC = [
    _col("frame", "integer", always_blank=True),
    _col("time_epoch", "decimal", required=True, decimals=3, min_=EPOCH_MIN, max_=EPOCH_MAX, unit="s",
         breaks_report=True),
    _col("rat", "enum", required=True, values=["lte", "nr"], breaks_report=True),
    _col("meas_id", "integer", always_blank=True),
    _col("pci", "integer", range_by_rat={"lte": LTE_PCI, "nr": NR_PCI}, list_allowed=True),
    _col("rsrp_dbm", "decimal", decimals=1, range_by_rat={"lte": LTE_RSRP, "nr": NR_RSRP}, unit="dBm",
         list_allowed=True, breaks_report=True),
    _col("rsrq_db", "decimal", decimals=1, range_by_rat={"lte": LTE_RSRQ, "nr": NR_RSRQ}, unit="dB",
         list_allowed=True, breaks_report=True),
    _col("sinr_db", "decimal", decimals=1, range_by_rat={"lte": LTE_SINR, "nr": NR_SINR}, unit="dB",
         list_allowed=True, breaks_report=True),
    _col("comment", "text", required=True, pattern=KPI_COMMENT_PATTERN),
    _col("lat", "decimal", decimals=7, min_=-90.0, max_=90.0, unit="degree", breaks_report=True),
    _col("lon", "decimal", decimals=7, min_=-180.0, max_=180.0, unit="degree", breaks_report=True),
]

EVENTS_SPEC = [
    _col("time_utc", "utc", required=True, breaks_report=True),
    _col("rat", "enum", required=True, values=["lte", "nr", "-"]),
    _col("kind", "text", required=True, pattern=TOKEN_PATTERN),
    _col("severity", "enum", required=True, values=EVENT_SEVERITIES, breaks_report=True),
    _col("title", "text", required=True),
    _col("detail", "text"),
    _col("frame", "integer", always_blank=True, min_=1, breaks_report=True),
    _col("pci", "integer", range_by_rat={"lte": LTE_PCI, "nr": NR_PCI}),
    _col("arfcn", "integer", range_by_rat={"lte": LTE_EARFCN, "nr": NR_ARFCN}),
    _col("cause", "text", pattern=TOKEN_PATTERN),
    _col("setup_ms", "decimal", always_blank=True, decimals=1, min_=0.0, unit="ms", breaks_report=True),
]

TRAFFIC_SPEC = [
    _col("time_utc", "utc", required=True, breaks_report=True),
    _col("test", "enum", required=True, values=APP_TRAFFIC_TESTS),
    _col("target", "text", required=True),
    _col("ok", "enum", required=True, values=["0", "1"], breaks_report=True),
    _col("seconds", "decimal", required=True, decimals=2, min_=0.0, unit="s", breaks_report=True),
    _col("loss_pct", "decimal", decimals=1, min_=0.0, max_=100.0, unit="%", breaks_report=True),
    _col("rtt_min_ms", "decimal", decimals=1, min_=0.0, unit="ms", breaks_report=True),
    _col("rtt_avg_ms", "decimal", decimals=1, min_=0.0, unit="ms", breaks_report=True),
    _col("rtt_max_ms", "decimal", decimals=1, min_=0.0, unit="ms", breaks_report=True),
    _col("mbps", "decimal", decimals=3, min_=0.0, unit="Mbit/s", breaks_report=True),
    _col("bytes", "integer", min_=0, unit="byte", breaks_report=True),
    _col("http_code", "integer", min_=100, max_=599),
    _col("error", "text"),
]

CELLS_APP_COLUMNS = ["operator", "additional_plmns", "samples", "rsrp_min", "rsrp_max"]
CELLS_SPEC = [
    _col("first_seen_utc", "utc", required=True),
    _col("rat", "enum", required=True, values=["lte", "nr"]),
    _col("plmn", "text", pattern=PLMN_PATTERN),
    _col("mcc", "text", pattern=r"^[0-9]{3}$"),
    _col("mnc", "text", pattern=r"^[0-9]{2,3}$"),
    _col("tac", "integer", min_=0, max_=16777215),
    _col("cell_id", "integer", range_by_rat={"lte": LTE_ECI, "nr": NR_NCI}),
    _col("enb_id", "integer", min_=0, max_=1048575),
    _col("sector", "integer", min_=0, max_=255),
    _col("pci", "integer", range_by_rat={"lte": LTE_PCI, "nr": NR_PCI}),
    _col("band", "integer", min_=1, max_=1024),
    _col("dl_earfcn", "integer", range_by_rat={"lte": LTE_EARFCN, "nr": NR_ARFCN}),
    _col("ul_earfcn", "integer", range_by_rat={"lte": LTE_EARFCN, "nr": NR_ARFCN}),
    _col("dl_bw_mhz", "decimal", decimals=1, min_=0.0, max_=400.0, unit="MHz"),
    _col("ul_bw_mhz", "decimal", decimals=1, min_=0.0, max_=400.0, unit="MHz"),
    _col("version", "enum", required=True, values=["android"]),
    _col("plausible", "enum", required=True, values=["True", "False"]),
    _col("operator", "text"),
    _col("additional_plmns", "text", pattern=PLMN_LIST_PATTERN, list_order="ascending"),
    _col("samples", "integer", required=True, min_=0),
    _col("rsrp_min", "decimal", decimals=1, range_by_rat={"lte": LTE_RSRP, "nr": NR_RSRP}, unit="dBm"),
    _col("rsrp_max", "decimal", decimals=1, range_by_rat={"lte": LTE_RSRP, "nr": NR_RSRP}, unit="dBm"),
]

CELLINFO_APP_COLUMNS = ["time_epoch", "timestamp_ms", "age_ms", "stale", "connection_status", "source", "cqi",
                        "timing_advance", "csi_rsrp", "csi_rsrq", "csi_sinr", "screen_on", "charging",
                        "wifi_connected", "sub_id", "lat", "lon"]
CELLINFO_SPEC = [
    # the columns `fieldtap scan --watch -o` writes (scan.COLUMNS)
    _col("seen_utc", "utc", required=True),
    _col("rat", "enum", required=True, values=["nr", "lte", "wcdma", "gsm", "tdscdma", "cdma"]),
    _col("registered", "enum", required=True, values=["0", "1"]),
    _col("plmn", "text", pattern=PLMN_PATTERN),
    _col("mcc", "text", pattern=r"^[0-9]{3}$"),
    _col("mnc", "text", pattern=r"^[0-9]{2,3}$"),
    _col("operator", "text"),
    _col("pci", "integer", range_by_rat={"lte": LTE_PCI, "nr": NR_PCI}),
    _col("arfcn", "integer", range_by_rat={"lte": LTE_EARFCN, "nr": NR_ARFCN}),
    _col("bands", "text", pattern=r"^([0-9]+(, [0-9]+)*)?$", list_order="as_reported"),
    _col("tac", "integer", min_=0, max_=16777215),
    _col("cell_id", "integer", range_by_rat={"lte": LTE_ECI, "nr": NR_NCI}),
    _col("bandwidth_khz", "integer", min_=0, max_=400000, unit="kHz"),
    _col("rsrp", "integer", range_by_rat={"lte": [-156, -43], "nr": [-156, -29]}, unit="dBm"),
    _col("rsrq", "integer", range_by_rat={"lte": [-34, 3], "nr": [-43, 20]}, unit="dB"),
    _col("sinr", "integer", range_by_rat={"lte": [-23, 40], "nr": [-23, 40]}, unit="dB"),
    _col("rssi", "integer", min_=-150, max_=0, unit="dBm"),
    _col("level", "integer", min_=0, max_=4),
    _col("additional_plmns", "text", pattern=PLMN_LIST_PATTERN, list_order="ascending"),
    # Android-only extensions
    _col("time_epoch", "decimal", required=True, decimals=3, min_=EPOCH_MIN, max_=EPOCH_MAX, unit="s"),
    _col("timestamp_ms", "integer", required=True, min_=0, unit="ms"),
    _col("age_ms", "integer", required=True, min_=0, unit="ms"),
    _col("stale", "enum", required=True, values=["0", "1"]),
    _col("connection_status", "enum", values=["0", "1", "2"]),
    _col("source", "enum", required=True, values=["request", "push"]),
    _col("cqi", "integer", min_=0, max_=15),
    _col("timing_advance", "integer", min_=0, max_=3846),
    _col("csi_rsrp", "integer", min_=-156, max_=-31, unit="dBm"),
    _col("csi_rsrq", "integer", min_=-20, max_=-3, unit="dB"),
    _col("csi_sinr", "integer", min_=-23, max_=23, unit="dB"),
    _col("screen_on", "enum", required=True, values=["0", "1"]),
    _col("charging", "enum", required=True, values=["0", "1"]),
    _col("wifi_connected", "enum", required=True, values=["0", "1"]),
    _col("sub_id", "integer", min_=0),
    _col("lat", "decimal", decimals=7, min_=-90.0, max_=90.0, unit="degree"),
    _col("lon", "decimal", decimals=7, min_=-180.0, max_=180.0, unit="degree"),
]

# name -> (python constant the header must equal, spec, minimum leading columns, presence rule)
CSV_FILES = [
    (KPI_CSV, kpi_mod.SESSION_COLUMNS, KPI_SPEC, len(kpi_mod.COLUMNS), "always"),
    (TRACK_CSV, gps_mod.COLUMNS, TRACK_SPEC, len(gps_mod.COLUMNS), "unless_precision_none"),
    (EVENTS_CSV, events_mod.COLUMNS, EVENTS_SPEC, len(events_mod.COLUMNS), "always"),
    (TRAFFIC_CSV, traffic_mod.COLUMNS, TRAFFIC_SPEC, len(traffic_mod.COLUMNS), "always"),
    (CELLS_CSV, session_mod.CELLS_COLUMNS + CELLS_APP_COLUMNS, CELLS_SPEC, len(session_mod.CELLS_COLUMNS), "always"),
    (CELLINFO_CSV, scan_mod.COLUMNS + CELLINFO_APP_COLUMNS, CELLINFO_SPEC, len(scan_mod.COLUMNS), "always"),
]

# --- events -------------------------------------------------------------------------------------

# kind -> (allowed rat values, allowed severities, whether pci and arfcn are filled)
APP_EVENT_KINDS = [
    ("serving_cell", ["lte", "nr"], ["info"], True),
    ("rat_change", ["lte", "nr"], ["info", "warn"], True),
    ("service_lost", ["lte", "nr", "-"], ["error"], False),
    ("emergency_only", ["lte", "nr"], ["error"], True),
    ("service_restored", ["lte", "nr"], ["ok"], True),
    ("data_state", ["-"], ["info", "warn"], False),
    ("nr_display", ["nr"], ["info"], False),
    ("gps_lost", ["-"], ["warn"], False),
    ("gps_restored", ["-"], ["ok"], False),
    ("sampling_gap", ["-"], ["warn"], False),
    ("marker", ["-"], ["info"], False),
    ("test_failed", ["-"], ["error"], False),
    ("session_interrupted", ["-"], ["error"], False),
    ("privacy_zone", ["-"], ["info"], False),
]

# Every kind fieldtap.events derives from signalling, plus the handover kinds.
# The report counts these as procedures, handovers and radio link failures.
SIGNALLING_EVENT_KINDS = sorted({rule[0] for rule in events_mod._RULES.values()} |
                                {"handover", "handover_command"} |
                                {k for attempt, ok, bad in events_mod.PROCEDURES.values() for k in {attempt} | ok | bad})
SIGNALLING_KIND_PREFIXES = ["handover", "rrc_", "attach_", "registration_", "tau_", "pdn_", "pdu_",
                            "reestablishment", "bearer_"]

# --- session.json -------------------------------------------------------------------------------

# Objects the report dereferences: null crashes it. Checked in every session.
NEVER_NULL_OBJECTS = ["transport", "handset", "device", "modem", "log_mask", "files", "summary",
                      "summary.plmns", "summary.messages", "summary.client", "summary.framing"]

HANDSET_KEYS = ["manufacturer", "model", "device", "android_version", "android_build", "security_patch",
                "baseband", "soc", "platform", "hardware", "operator_mccmnc", "operator_name", "sim_mccmnc",
                "sim_operator_name", "network_type"]

FORBIDDEN_KEYS = ["imei", "imeisv", "meid", "imsi", "iccid", "msisdn", "phone_number", "line1_number",
                  "subscriber_id", "sim_serial", "serial", "serial_number", "android_id", "advertising_id",
                  "tmsi", "guti", "supi", "suci", "ssid", "bssid", "mac", "mac_address", "ip", "ip_address"]

# Top-level keys only the app writes. A session with any of them is checked as an
# app session even when `format` or `transport.transport` is missing or misspelt,
# as a JSON serializer that leaves out default values would write it.
APP_ONLY_KEYS = ["capabilities", "collection", "privacy"]
# Laptop summary keys the report takes the duration and time origin from.
LAPTOP_SUMMARY_KEYS = ["modem_time_first_utc", "modem_time_last_utc"]
# Objects whose null crashes the report; the others are read defensively today.
_CRASH_IF_NULL = frozenset(["summary", "handset", "files", "summary.plmns", "summary.messages", "summary.client",
                            "summary.framing"])


def _field(path, type_, required=False, nullable=False, values=None, pattern=None, min_=None, max_=None,
           decimals=None) -> dict:
    """One session.json field. `decimals`: a number rounded to that many decimals
    (half-even on the exact binary value, as Python's round()) and written as the
    shortest decimal that reads back to the same double."""
    return {"path": path, "type": type_, "required": required, "nullable": nullable, "values": values,
            "pattern": pattern, "min": min_, "max": max_, "decimals": decimals}


def _pct(path):
    return _field(path, "number", required=True, nullable=True, min_=0, max_=100, decimals=1)


SESSION_FIELDS = [
    _field("format", "string", required=True, values=[FORMAT]),
    _field("session_id", "string", required=True, pattern=UUID_PATTERN),
    _field("group_id", "string", required=True, nullable=True),
    _field("name", "string", required=True, pattern=NOT_BLANK_PATTERN),
    _field("note", "string", required=True, nullable=True),
    _field("location", "string", required=True, nullable=True),
    _field("started_utc", "utc", required=True),
    _field("stopped_utc", "utc", required=True, nullable=True),
    _field("transport", "object", required=True),
    _field("transport.transport", "string", required=True, values=[APP_TRANSPORT]),
    _field("transport.app", "string", required=True, pattern=NOT_BLANK_PATTERN),
    _field("transport.app_version", "string", required=True, pattern=NOT_BLANK_PATTERN),
    _field("transport.version_code", "integer", required=True, min_=1),
    _field("handset", "object", required=True),
] + [_field("handset." + key, "string", pattern=PLMN_PATTERN if key.endswith("mccmnc") else None)
     for key in HANDSET_KEYS] + [
    _field("device", "object", required=True),
    _field("device.key", "string", required=True, pattern=r"^app:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"),
    _field("device.label", "string"),
    _field("modem", "object", required=True),
    _field("log_mask", "object", required=True),
    _field("files", "object", required=True),
    _field("summary", "object", required=True),
    _field("summary.stopped_by", "string", required=True, pattern=TOKEN_PATTERN),
    _field("summary.plmns", "object", required=True),
    _field("capabilities", "object", required=True),
    _field("capabilities.layer3", "boolean", required=True, values=[False]),
    _field("collection", "object", required=True),
    _field("collection.median_fresh_interval_ms", "integer", required=True, nullable=True, min_=0),
    _pct("collection.short_interval_pct"),
    _pct("collection.screen_on_pct"),
    _pct("collection.wifi_connected_pct"),
    _pct("collection.charging_pct"),
    _field("collection.fresh_samples", "integer", required=True, min_=0),
    _field("collection.repeats_dropped", "integer", required=True, min_=0),
    _field("collection.gaps", "array", required=True),
    _field("collection.gaps[]", "object", required=True),
    _field("collection.gaps[].start_utc", "utc", required=True),
    _field("collection.gaps[].stop_utc", "utc", required=True),
    _field("collection.gaps[].seconds", "number", required=True, min_=0, decimals=1),
    _field("collection.gaps[].reason", "string", required=True, pattern=TOKEN_PATTERN),
    _field("privacy", "object", required=True),
    _field("privacy.data_class", "string", required=True, values=["kpi"]),
    _field("privacy.location_precision", "string", required=True, values=LOCATION_PRECISIONS),
    _field("privacy.zone_pauses", "integer", required=True, min_=0),
    _field("privacy.consent_version", "string", required=True, pattern=NOT_BLANK_PATTERN),
    _field("privacy.consent_sha256", "string", required=True, pattern=r"^[0-9a-f]{64}$"),
]


def _file_schema(name, columns, spec, min_columns, presence) -> dict:
    return {"name": name, "presence": presence, "min_columns": min_columns,
            "header": list(columns), "columns": spec}


def schema() -> dict:
    """The contract as data. schema/columns.json is exactly this, written by write_schema()."""
    return {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "encoding": {
            "charset": "utf-8",
            "byte_order_mark": False,
            "csv_line_terminator": CSV_LINE_TERMINATOR,
            "csv_delimiter": ",",
            "csv_quote": "\"",
            "csv_quoting": "minimal",
            "csv_quote_if_contains": [",", "\"", "\r", "\n"],
            "csv_blank": "",
            "csv_max_line_chars": MAX_CSV_LINE_CHARS,
            "text_line_breaks": "replace_with_space",
            "number_rounding": "half_even_exact_binary",
            "number_digits": "ascii",
            "decimal_separator": ".",
            "negative_zero": False,
            "json_line_terminator": JSON_LINE_TERMINATOR,
            "json_indent": 2,
            "json_ascii_only": False,
        },
        "patterns": {
            "match": "full",
            "python": "re.fullmatch(pattern, value)",
            "kotlin": "Regex(pattern).matches(value)",
            "syntax": "explicit character classes such as [0-9] and [^ \\t\\r\\n]; no \\s, \\d, \\w, \\b or '.', "
                      "which mean different things in Python, the JVM and Android's ICU, except in [\\s\\S], "
                      "which is any character in all three",
            "search_patterns": ["directory.slug_replace_pattern", "identifiers.digit_token_pattern"],
            "python_only_patterns": ["timestamps.python_portable_pattern"],
        },
        "timestamps": {
            "utc_suffix": "_utc",
            "utc_pattern": UTC_PATTERN,
            "utc_kotlin_pattern": UTC_KOTLIN_PATTERN,
            "utc_example": UTC_EXAMPLE,
            "python_portable_pattern": PORTABLE_ISO_PATTERN,
            "time_epoch_decimals": 3,
        },
        "android_unavailable": ANDROID_UNAVAILABLE,
        "directory": {
            "pattern": DIRECTORY_PATTERN,
            "time_format_python": "%Y%m%d-%H%M%S",
            "time_format_kotlin": "yyyyMMdd-HHmmss",
            "slug_replace_pattern": "[^A-Za-z0-9._-]+",
            "slug_replacement": "-",
            "slug_strip": "-",
            "slug_max_length": SLUG_MAX,
            "slug_empty": "session",
        },
        "files": [SESSION_JSON] + [f[0] for f in CSV_FILES],
        "report_outputs": list(REPORT_OUTPUTS),
        "session_json": {
            "never_null_objects": list(NEVER_NULL_OBJECTS),
            "transport_app": APP_TRANSPORT,
            "transport_laptop": list(LAPTOP_TRANSPORTS),
            "transport_simulated": SIMULATED_TRANSPORT,
            "app_only_keys": list(APP_ONLY_KEYS),
            "laptop_summary_keys": list(LAPTOP_SUMMARY_KEYS),
            "handset_keys": list(HANDSET_KEYS),
            "location_precisions": list(LOCATION_PRECISIONS),
            "approx_110m_decimals": APPROX_110M_DECIMALS,
            "forbidden_keys": list(FORBIDDEN_KEYS),
            "max_bytes": MAX_SESSION_JSON_BYTES,
            "max_depth": MAX_JSON_DEPTH,
            "fields": SESSION_FIELDS,
        },
        "csv": [_file_schema(*f) for f in CSV_FILES],
        "events": {
            "severities": list(EVENT_SEVERITIES),
            "app_kinds": [{"kind": k, "rat": rats, "severity": sev, "pci_arfcn": cell}
                          for k, rats, sev, cell in APP_EVENT_KINDS],
            "signalling_kinds": list(SIGNALLING_EVENT_KINDS),
            "signalling_kind_prefixes": list(SIGNALLING_KIND_PREFIXES),
            "interrupted_stop_tolerance_seconds": INTERRUPTED_STOP_TOLERANCE_SECONDS,
        },
        "traffic_tests": {"app": list(APP_TRAFFIC_TESTS), "laptop": list(LAPTOP_TRAFFIC_TESTS)},
        "kpi": {"max_age_ms": KPI_MAX_AGE_MS, "max_age_ms_short_interval": KPI_MAX_AGE_SHORT_MS,
                "gps_match_seconds": GPS_MATCH_SECONDS, "time_window_slack_seconds": KPI_WINDOW_SLACK_SECONDS,
                "comment_pattern": KPI_COMMENT_PATTERN},
        "identifiers": {
            "digit_token_pattern": _DIGIT_TOKEN,
            "imei": "a 15-digit token that passes the Luhn check",
            "imsi": "a 14- or 15-digit token starting with 2 to 7 (a mobile country code)",
            "iccid": "a 19- or 20-digit token starting with 89, optionally ending in F",
        },
        "upload_bundle": {
            "name": "<session directory name>.zip",
            "file_names": list(SESSION_FILES),
            "required": [SESSION_JSON],
            "max_compressed_bytes": MAX_COMPRESSED_BYTES,
            "max_uncompressed_bytes": MAX_UNCOMPRESSED_BYTES,
            "compression_methods": [ZIP_STORED, ZIP_DEFLATED],
            "zip64": False,
            "hash": "sha256",
        },
    }


def schema_json() -> str:
    return json.dumps(schema(), indent=2, ensure_ascii=False) + "\n"


def write_schema(path: str) -> None:
    """Regenerate schema/columns.json:
    python -c "from fieldtap import contract; contract.write_schema('schema/columns.json')"
    """
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(schema_json())


# --- identifiers ------------------------------------------------------------------------------------

_DIGIT_TOKEN = r"(?<![0-9A-Za-z])[0-9]{14,20}[Ff]?(?![0-9A-Za-z])"
_DIGIT_TOKEN_RE = re.compile(_DIGIT_TOKEN)


def _luhn_ok(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = ord(ch) - 48
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def identifier_kind(text: str) -> Optional[str]:
    """"IMEI", "IMSI" or "ICCID" when text contains something that looks like one."""
    for m in _DIGIT_TOKEN_RE.finditer(text):
        token = m.group(0)
        digits = token.rstrip("Ff")
        if len(digits) in (19, 20) and digits.startswith("89"):
            return "ICCID"
        if token != digits:
            continue
        if len(digits) == 15 and _luhn_ok(digits):
            return "IMEI"
        if len(digits) in (14, 15) and digits[0] in "234567":
            return "IMSI"
    return None


# --- problems ---------------------------------------------------------------------------------------

ERROR = "error"
WARNING = "warning"
_SHOWN_PER_RULE = 5


@dataclass
class Problem:
    severity: str              # "error" | "warning"
    file: str                  # "session.json", "kpi.csv", ... ; "" for the directory or bundle itself
    line: Optional[int]        # 1-based physical line (the header is line 1), or None
    message: str

    def __str__(self) -> str:
        where = self.file or "."
        if self.line is not None:
            where = "%s:%d" % (where, self.line)
        return "%s %s: %s" % (self.severity, where, self.message)

    def to_dict(self) -> dict:
        return {"severity": self.severity, "file": self.file, "line": self.line, "message": self.message}


class _Problems:
    """Collects problems. A rule that fires on every row is shown a few times
    and then summarised, so a million-row file gives a readable report."""

    def __init__(self) -> None:
        self.items: list = []
        self._counts: dict = {}

    def add(self, severity: str, file: str, line: Optional[int], message: str, rule: Optional[str] = None) -> None:
        if rule is not None:
            key = (severity, file, rule)
            entry = self._counts.setdefault(key, [0, line])
            entry[0] += 1
            if entry[0] > _SHOWN_PER_RULE:
                return
        self.items.append(Problem(severity, file, line, message))

    def error(self, file, line, message, rule=None) -> None:
        self.add(ERROR, file, line, message, rule)

    def warning(self, file, line, message, rule=None) -> None:
        self.add(WARNING, file, line, message, rule)

    def close_file(self, file: str) -> None:
        for key in [k for k in self._counts if k[1] == file]:
            count, first = self._counts.pop(key)
            if count > _SHOWN_PER_RULE:
                more = count - _SHOWN_PER_RULE
                message = ("%d more rows with the same %s as line %s" % (more, key[0], first) if first is not None
                           else "%d more %ss like the ones above" % (more, key[0]))
                self.items.append(Problem(key[0], file, None, message))


# --- value checks -------------------------------------------------------------------------------------

_UTC_RE = re.compile(UTC_PATTERN)
_PORTABLE_ISO_RE = re.compile(PORTABLE_ISO_PATTERN)
_DIRECTORY_RE = re.compile(DIRECTORY_PATTERN)
_INT_RE = re.compile(r"^-?(0|[1-9][0-9]*)$")
_DECIMAL_RES: dict = {}


def _decimal_re(decimals: int):
    if decimals not in _DECIMAL_RES:
        _DECIMAL_RES[decimals] = re.compile(r"^-?(0|[1-9][0-9]*)\.[0-9]{%d}$" % decimals)
    return _DECIMAL_RES[decimals]


def _json_type(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, (int, float)):
        return "a number"
    if isinstance(value, str):
        return "a string"
    if isinstance(value, list):
        return "an array"
    return "an object"


def parse_utc(value) -> Optional[datetime]:
    """A `*_utc` value as the report reads it, or None when it cannot be read
    portably or has no offset."""
    if not isinstance(value, str):
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    if not _PORTABLE_ISO_RE.fullmatch(text):
        return None
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        return None
    return when if when.utcoffset() is not None else None


def _check_utc(value, label: str, file: str, line: Optional[int], out: _Problems,
               rule: Optional[str] = None) -> Optional[datetime]:
    if not isinstance(value, str):
        out.error(file, line, "%s is %s, not a timestamp string" % (label, _json_type(value)), rule)
        return None
    text = value
    if value.endswith("Z"):
        out.warning(file, line, "%s %r ends in Z: Python before 3.11 cannot read that, so older fieldtap "
                                "installs crash on it; write +00:00" % (label, value), rule and rule + ":z")
        text = value[:-1] + "+00:00"
    if not _PORTABLE_ISO_RE.fullmatch(text):
        out.error(file, line, "%s %r is not a timestamp Python 3.9 can read; write it like %s"
                  % (label, value, UTC_EXAMPLE), rule)
        return None
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        out.error(file, line, "%s %r is not a valid date and time" % (label, value), rule)
        return None
    if when.utcoffset() is None:
        out.error(file, line, "%s %r has no UTC offset: the report subtracts it from offset-aware times "
                              "and crashes; write +00:00" % (label, value), rule)
        return None
    if not value.endswith("Z") and not _UTC_RE.fullmatch(value):
        out.warning(file, line, "%s %r is readable but not written as %s" % (label, value, UTC_EXAMPLE),
                    rule and rule + ":form")
    return when


def _number(text: str, integer: bool):
    """The value the Python readers get from text, or None when they would fail."""
    try:
        value = int(text) if integer else float(text)
    except ValueError:
        return None
    if not integer and not math.isfinite(value):
        return None
    return value


class _Context:
    """What kind of session this is, which decides how strict the checks are.

    An app session gets every contract rule. A session is one when it declares
    format fieldtap-session/1, or transport android-api, or has a key only the
    app writes (APP_ONLY_KEYS), so a misspelt or missing transport cannot switch
    the app rules off. Other sessions (the laptop tool's, which predate the
    contract and have none of these) get the checks whose failure breaks the
    report, plus timestamps, headers and identifiers."""

    def __init__(self, meta: dict):
        transport = meta.get("transport") if isinstance(meta.get("transport"), dict) else {}
        self.app = (meta.get("format") == FORMAT or transport.get("transport") == APP_TRANSPORT
                    or any(key in meta for key in APP_ONLY_KEYS))
        caps = meta.get("capabilities") if isinstance(meta.get("capabilities"), dict) else {}
        self.measurement_only = self.app or caps.get("layer3") is False
        privacy = meta.get("privacy") if isinstance(meta.get("privacy"), dict) else {}
        precision = privacy.get("location_precision")
        self.precision = precision if precision in LOCATION_PRECISIONS else None
        self.started = parse_utc(meta.get("started_utc"))
        self.stopped = parse_utc(meta.get("stopped_utc"))
        self.interrupted: Optional[tuple] = None     # (time, text) of the session_interrupted event


# --- session.json -------------------------------------------------------------------------------------

def _get(obj, path: str):
    """-> (present, value) for a dotted path through objects."""
    value = obj
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return False, None
        value = value[part]
    return True, value


def _resolve(obj, path: str) -> list:
    """-> [(label, present, value)] for a dotted path; "name[]" steps into every array item."""
    results = [("", True, obj)]
    for part in path.split("."):
        many = part.endswith("[]")
        key = part[:-2] if many else part
        found = []
        for label, present, value in results:
            if not present or not isinstance(value, dict):
                continue                      # the parent's own field reports it
            label = "%s.%s" % (label, key) if label else key
            if key not in value:
                found.append((label, False, None))
            elif many:
                if isinstance(value[key], list):
                    found.extend(("%s[%d]" % (label, i), True, item) for i, item in enumerate(value[key]))
            else:
                found.append((label, True, value[key]))
        results = found
    return results


_TYPE_CHECKS = {
    "string": lambda v: isinstance(v, str),
    "utc": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v),
    "boolean": lambda v: isinstance(v, bool),
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
}


def _shown(value) -> str:
    """A JSON value for a message: a scalar as JSON, an object or array by its type."""
    return _json_type(value) if isinstance(value, (dict, list)) else json.dumps(value)


def _check_app_fields(meta: dict, out: _Problems) -> None:
    F = SESSION_JSON
    for spec in SESSION_FIELDS:
        path = spec["path"]
        # _check_session_json reports these for every session; say it once
        null_reported = path in NEVER_NULL_OBJECTS or path == "started_utc"
        type_reported = path in NEVER_NULL_OBJECTS or spec["type"] == "utc"
        for label, present, value in _resolve(meta, path):
            if not present:
                if spec["required"] and path != "started_utc":
                    out.error(F, None, "%s is missing" % label)
                continue
            if value is None:
                if not spec["nullable"] and not null_reported:
                    out.error(F, None, "%s is null" % label)
                continue
            if not _TYPE_CHECKS[spec["type"]](value):
                if not type_reported:
                    out.error(F, None, "%s is %s; it must be %s" % (label, _json_type(value), spec["type"]))
                continue
            if spec["values"] is not None and value not in spec["values"]:
                message = "%s is %s; allowed: %s" % (label, _shown(value),
                                                     ", ".join(json.dumps(v) for v in spec["values"]))
                if path == "transport.transport":
                    message += ("; the report is labelled SIMULATED (file replay)" if value == SIMULATED_TRANSPORT
                                else "; fieldtap tells an app session from a laptop session by this value")
                elif path == "capabilities.layer3":
                    message += "; the report shows signalling sections unless it is false"
                out.error(F, None, message)
            if spec["pattern"] is not None and not re.fullmatch(spec["pattern"], value):
                out.error(F, None, "%s %s does not match %s" % (label, json.dumps(value), spec["pattern"]))
            if spec["min"] is not None and value < spec["min"]:
                out.error(F, None, "%s is %s, below %s" % (label, value, spec["min"]))
            if spec["max"] is not None and value > spec["max"]:
                out.error(F, None, "%s is %s, above %s" % (label, value, spec["max"]))
            if spec["decimals"] is not None and round(value, spec["decimals"]) != value:
                out.warning(F, None, "%s is %s; it is written rounded to %d decimal%s"
                            % (label, value, spec["decimals"], "" if spec["decimals"] == 1 else "s"))
    plmns = _get(meta, "summary.plmns")[1]
    if isinstance(plmns, dict):
        for plmn, count in plmns.items():
            if not re.fullmatch(PLMN_PATTERN, plmn) or not _TYPE_CHECKS["integer"](count) or count < 0:
                out.error(F, None, "summary.plmns entry %s: %s must map a 5- or 6-digit PLMN to a sample count"
                          % (json.dumps(plmn), _shown(count)), "plmns")


def _members(path: str, value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield ("%s.%s" % (path, key) if path else str(key)), key, child
    else:
        for i, child in enumerate(value):
            yield "%s[%d]" % (path, i), None, child


def _walk(value, visit) -> None:
    """visit(label, key, child) for every member and item under value, depth
    first in document order. Iterative, so no nesting depth can raise."""
    if not isinstance(value, (dict, list)):
        return
    stack = [_members("", value)]
    while stack:
        item = next(stack[-1], None)
        if item is None:
            stack.pop()
            continue
        label, key, child = item
        visit(label, key, child)
        if isinstance(child, (dict, list)):
            stack.append(_members(label, child))


def _depth(value) -> int:
    """How many levels of objects and arrays nest in value, value itself included."""
    deepest, stack = 0, [(value, 1)]
    while stack:
        node, level = stack.pop()
        if isinstance(node, (dict, list)):
            deepest = max(deepest, level)
            stack.extend((child, level + 1) for child in (node.values() if isinstance(node, dict) else node))
    return deepest


def _check_session_json(directory: str, out: _Problems) -> Optional[dict]:
    F = SESSION_JSON
    path = os.path.join(directory, F)
    if not os.path.isfile(path):
        out.error(F, None, "missing: without it the directory is not a session and the report cannot start")
        return None
    try:
        size = os.path.getsize(path)
        if size > MAX_SESSION_JSON_BYTES:
            out.error(F, None, "%d bytes; a session.json is at most %d bytes, so it is not read"
                      % (size, MAX_SESSION_JSON_BYTES))
            return None
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        out.error(F, None, "cannot be read: %s" % exc)
        return None
    if raw.startswith(b"\xef\xbb\xbf"):
        out.error(F, 1, "starts with a UTF-8 byte order mark: json.load rejects it and the report cannot start")
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        out.error(F, None, "not UTF-8 (byte %d): the report cannot read it" % exc.start)
        return None
    try:
        meta = json.loads(text)
    except ValueError as exc:
        out.error(F, getattr(exc, "lineno", None), "not valid JSON: %s" % getattr(exc, "msg", exc))
        return None
    except RecursionError:
        out.error(F, None, "objects and arrays nest too deeply to read; a session.json nests at most %d levels"
                  % MAX_JSON_DEPTH)
        return None
    if not isinstance(meta, dict):
        out.error(F, None, "the top level is %s, not an object" % _json_type(meta))
        return None
    depth = _depth(meta)
    if depth > MAX_JSON_DEPTH:
        out.error(F, None, "objects and arrays nest %d levels deep; a session.json nests at most %d"
                  % (depth, MAX_JSON_DEPTH))
        return None
    ctx = _Context(meta)

    fmt = meta.get("format")
    if not ctx.app:                 # an app session's format is checked with its other fields
        if fmt is None:
            out.warning(F, None, "no format key: a session from before %s, as laptop sessions are" % FORMAT)
        else:
            out.error(F, None, "format %s is not one this fieldtap reads (%s)" % (_shown(fmt), FORMAT))

    for key in NEVER_NULL_OBJECTS:
        present, value = _get(meta, key)
        if not present:
            continue
        if value is None:
            out.error(F, None, "%s is null%s; write {}" % (key, ": the report reads keys from it and crashes"
                                                              if key in _CRASH_IF_NULL else
                                                              ", where every reader expects an object"))
        elif not isinstance(value, dict):
            out.error(F, None, "%s is %s; it must be an object" % (key, _json_type(value)))
    messages = _get(meta, "summary.messages")[1]
    if isinstance(messages, dict):
        for key, count in messages.items():
            if not _TYPE_CHECKS["integer"](count) or count < 0:
                crashes = not isinstance(count, (int, float))
                out.error(F, None, "summary.messages.%s is %s, not a message count (an integer, 0 or more)%s"
                          % (key, _shown(count), "; the report adds these up and crashes" if crashes else ""),
                          "messages")

    transport = meta.get("transport") if isinstance(meta.get("transport"), dict) else {}
    kind = transport.get("transport")
    if not ctx.app:
        if kind == SIMULATED_TRANSPORT:
            out.warning(F, None, "transport.transport is \"file\": the report is labelled SIMULATED (file replay)")
        elif kind is not None and kind not in LAPTOP_TRANSPORTS:
            out.warning(F, None, "transport.transport %s is not one fieldtap knows (%s)"
                        % (_shown(kind), ", ".join([APP_TRANSPORT] + LAPTOP_TRANSPORTS)))

    if ctx.app:
        _check_app_fields(meta, out)
        summary = meta.get("summary") if isinstance(meta.get("summary"), dict) else {}
        for key in LAPTOP_SUMMARY_KEYS:
            if key in summary:
                out.error(F, None, "summary.%s is a laptop session's modem clock, which the report takes for the "
                                   "duration and the time origin; an app session never writes it" % key)
    if meta.get("started_utc") is None:
        out.error(F, None, "started_utc is %s: the report has no time origin for its charts and events"
                  % ("null" if "started_utc" in meta else "missing"))

    def visit(label, key, value):
        if isinstance(key, str):
            if key.endswith("_utc") and value is not None:
                _check_utc(value, label, F, None, out, "utc")
            if ctx.app and key.lower() in FORBIDDEN_KEYS:
                out.error(F, None, "%s: the key names a subscriber or device identifier, which is never written"
                          % label, "forbidden-key")
            found = identifier_kind(key)
            if found:
                out.error(F, None, "%s: the key looks like an %s" % (label, found), "identifier-key")
        if isinstance(value, str) or (isinstance(value, int) and not isinstance(value, bool)):
            found = identifier_kind(str(value))
            if found:
                out.error(F, None, "%s looks like an %s; subscriber and device identifiers are never written"
                          % (label, found), "identifier")

    _walk(meta, visit)

    if ctx.app and "stopped_utc" in meta and meta["stopped_utc"] is None:
        out.warning(F, None, "stopped_utc is null: the session is still recording, or was never closed")
    if ctx.started and ctx.stopped and ctx.stopped < ctx.started:
        out.warning(F, None, "stopped_utc is before started_utc: the report shows a negative duration")

    files = meta.get("files")
    if ctx.app and isinstance(files, dict):
        for key, name in files.items():
            if not isinstance(name, str) or name not in SESSION_FILES[1:]:
                out.error(F, None, "files.%s is %s, which is not a session file name" % (key, _shown(name)), "files")
            elif not os.path.isfile(os.path.join(directory, name)):
                out.warning(F, None, "files.%s names %s, which is not in the directory" % (key, name), "files-absent")
    out.close_file(F)
    return meta


def _utc_stamp(when: Optional[datetime]) -> Optional[str]:
    """yyyyMMdd-HHmmss of when in UTC; None without a time, or for one out of datetime's range."""
    if when is None:
        return None
    try:
        return when.astimezone(timezone.utc).strftime("%Y%m%d-%H%M%S")
    except (OverflowError, ValueError):
        return None


def _check_directory(directory: str, meta: dict, ctx: _Context, out: _Problems, upload: bool) -> None:
    base = os.path.basename(os.path.normpath(directory))
    if ctx.app:
        if not _DIRECTORY_RE.fullmatch(base):
            out.warning("", None, "directory name %r is not <yyyyMMdd-HHmmss>_<slug>; session lists sort by it" % base)
        else:
            stamp = _utc_stamp(ctx.started)
            if stamp is not None and base[:15] != stamp:
                out.warning("", None, "directory name %r does not start with started_utc (%s)" % (base, stamp))
            if isinstance(meta.get("name"), str) and base[16:] != session_mod.slugify(meta["name"]):
                out.warning("", None, "directory slug %r is not slugify(name) = %r"
                            % (base[16:], session_mod.slugify(meta["name"])))
    entries = sorted(os.listdir(directory))
    if upload:
        for name in entries:
            full = os.path.join(directory, name)
            if name not in SESSION_FILES:
                out.error(name, None, "not one of the seven session files, so it cannot be uploaded")
            elif os.path.islink(full) or not os.path.isfile(full):
                out.error(name, None, "not a regular file, so it cannot be uploaded")
    if ctx.app:
        for name, _header, _spec, _min, presence in CSV_FILES:
            exists = os.path.isfile(os.path.join(directory, name))
            if presence == "unless_precision_none" and ctx.precision == "none":
                if exists:
                    out.error(name, None, "present although privacy.location_precision is \"none\"; "
                                          "at that precision the track is left out")
            elif not exists:
                out.warning(name, None, "missing; the app writes it at session start, header row included")


# --- csv files ------------------------------------------------------------------------------------------

# Blank values the laptop readers cannot convert: the report crashes on them.
_CRASH_IF_BLANK = {(TRACK_CSV, "time_utc"), (TRACK_CSV, "lat"), (TRACK_CSV, "lon"), (TRAFFIC_CSV, "time_utc")}
_ENUM_NOTES = {
    (TRAFFIC_CSV, "test"): "the report's traffic summary silently ignores any other test name",
    (KPI_CSV, "rat"): "the report ignores rows of any other RAT",
    (EVENTS_CSV, "severity"): "the report counts only error and warn",
    (TRAFFIC_CSV, "ok"): "the report reads anything but 1 as a failure",
}
_SIGNALLING_SET = frozenset(SIGNALLING_EVENT_KINDS)
_APP_KINDS = {kind: (rats, severities, cell) for kind, rats, severities, cell in APP_EVENT_KINDS}
_COORDINATES_RE = re.compile(r"-?[0-9]{1,3}\.[0-9]{3,}\s*[, ;]\s*-?[0-9]{1,3}\.[0-9]{3,}")


def _bounds_text(low, high) -> str:
    return "%s..%s" % ("" if low is None else low, "" if high is None else high)


def _check_value(col: dict, value: str, row: dict, ctx: _Context, file: str, line: int, out: _Problems) -> None:
    name = col["name"]
    if value == "":
        if col["required"] and (ctx.app or (file, name) in _CRASH_IF_BLANK):
            crash = (file, name) in _CRASH_IF_BLANK
            out.error(file, line, "%s is blank; %s" % (name, "the reader cannot convert a blank and the report crashes"
                                                       if crash else "every row the app writes fills it"),
                      "blank:" + name)
        return
    if ctx.app and col["always_blank"]:
        out.warning(file, line, "%s is %r; the app leaves it blank" % (name, value), "filled:" + name)
    if col["type"] == "text":
        found = identifier_kind(value)
        if found:
            out.error(file, line, "%s contains something that looks like an %s; subscriber and device identifiers "
                                  "are never written" % (name, found), "identifier:" + name)
    if not (ctx.app or col["breaks_report"]):
        return
    kind = col["type"]
    if kind == "utc":
        _check_utc(value, name, file, line, out, "utc:" + name)
    elif kind in ("integer", "decimal"):
        _check_number(col, value, row.get("rat", ""), ctx, file, line, out)
    elif kind == "enum":
        if value not in col["values"]:
            note = _ENUM_NOTES.get((file, name))
            out.error(file, line, "%s %r is not one of %s%s" % (name, value, ", ".join(col["values"]),
                                                               ": " + note if note else ""), "enum:" + name)
    elif kind == "text" and ctx.app and col["pattern"] is not None and not re.fullmatch(col["pattern"], value):
        out.error(file, line, "%s %r does not match %s" % (name, value, col["pattern"]), "pattern:" + name)


# kpi.csv columns the report reads leniently: it leaves out a value it cannot convert.
_SKIPPED_IF_UNREADABLE = frozenset([(KPI_CSV, "time_epoch"), (KPI_CSV, "rsrp_dbm"), (KPI_CSV, "rsrq_db"),
                                    (KPI_CSV, "sinr_db")])


def _check_number(col: dict, value: str, rat: str, ctx: _Context, file: str, line: int, out: _Problems) -> None:
    name = col["name"]
    integer = col["type"] == "integer"
    items = value.split(",") if (col["list_allowed"] and not ctx.app) else [value]
    for item in items:
        number = _number(item, integer)
        if number is None:
            if not col["breaks_report"]:
                why = ""
            elif (file, name) in _SKIPPED_IF_UNREADABLE:
                why = "; the report silently leaves it out"
            else:
                why = "; the reader cannot convert it and the report crashes"
            out.error(file, line, "%s %r is not %s%s" % (name, value, "an integer" if integer else "a number", why),
                      "number:" + name)
            return
        if abs(number) in (ANDROID_UNAVAILABLE, ANDROID_UNAVAILABLE + 1):
            out.error(file, line, "%s is %s, Android's \"unavailable\" value; write it blank" % (name, item.strip()),
                      "unavailable:" + name)
            return
        low, high = col["min"], col["max"]
        by_rat = col["range_by_rat"]
        if by_rat is not None and rat in by_rat:
            low, high = by_rat[rat]
        if (low is not None and number < low) or (high is not None and number > high):
            out.error(file, line, "%s %s is outside %s%s%s" % (
                name, item.strip(), _bounds_text(low, high), " " + col["unit"] if col["unit"] else "",
                " for " + rat if by_rat is not None and rat in by_rat else ""), "range:" + name)
            return
    if ctx.app:
        pattern = _INT_RE if integer else _decimal_re(col["decimals"])
        canonical = pattern.fullmatch(value) is not None
        # a canonical value with a minus sign that reads as zero is -0 or -0.0
        if not canonical or (value.startswith("-") and float(value) == 0):
            out.warning(file, line, "%s %r is not written as %s%s" % (
                name, value, col["format"], " (no sign on zero)" if canonical else ""), "format:" + name)


def _check_position(row: dict, ctx: _Context, file: str, line: int, out: _Problems) -> None:
    lat, lon = row.get("lat", ""), row.get("lon", "")
    if (lat == "") != (lon == ""):
        if ctx.app and file != TRACK_CSV:       # track.csv reports the blank one itself
            out.error(file, line, "only one of lat and lon is filled; write both or neither", "half-position")
        return
    if lat == "":
        return
    if ctx.precision == "none":
        out.error(file, line, "has a position although privacy.location_precision is \"none\"", "precision")
    elif ctx.precision == "approx_110m":
        scale = 10 ** APPROX_110M_DECIMALS
        for text in (lat, lon):
            number = _number(text, False)
            # an out-of-range value is the range check's to report; skipping it keeps round() finite
            if number is not None and abs(number) <= 180 and abs(number * scale - round(number * scale)) > 1e-4:
                out.error(file, line, "%s is more precise than privacy.location_precision \"approx_110m\" "
                                      "(3 decimals) allows" % text, "precision")
                break


def _plmn_consistent(row: dict, file: str, line: int, out: _Problems) -> None:
    if row.get("plmn") and row.get("mcc") and row.get("mnc") and row["plmn"] != row["mcc"] + row["mnc"]:
        out.error(file, line, "plmn %s is not mcc + mnc (%s%s)" % (row["plmn"], row["mcc"], row["mnc"]), "plmn")


def _track_row(row, ctx, file, line, out, state) -> None:
    # Both silently corrupt the route and its distance: errors in an app session.
    flag = out.error if ctx.app else out.warning
    if _number(row["lat"], False) == 0 and _number(row["lon"], False) == 0:
        flag(file, line, "lat,lon is 0,0: a fix with no position, which stretches the map across the globe and adds "
                         "thousands of kilometres to the distance", "null-island")
    _check_position(row, ctx, file, line, out)
    when = parse_utc(row["time_utc"])
    if when is None:
        return
    previous = state.get("previous")
    if previous is not None and when < previous[0]:
        flag(file, line, "time_utc %s is before the row above (%s): the route joins fixes in file order, so it "
                         "zigzags and its distance grows" % (row["time_utc"], previous[1]), "time-order")
    state["previous"] = (when, row["time_utc"])


_KPI_COMMENT_RE = re.compile(KPI_COMMENT_PATTERN)
_REPEAT_WINDOW = 8          # a cached repeat follows the sample it repeats within a few rows


def _span(seconds: float) -> str:
    seconds = abs(seconds)
    if seconds >= 3600:
        return "%.1f h" % (seconds / 3600.0)
    if seconds >= 60:
        return "%.0f min" % (seconds / 60.0)
    return "%.0f s" % seconds


def _kpi_row(row, ctx, file, line, out, state) -> None:
    _check_position(row, ctx, file, line, out)
    if not ctx.app:
        return
    if not (row["rsrp_dbm"] or row["rsrq_db"] or row["sinr_db"]):
        out.warning(file, line, "no rsrp_dbm, rsrq_db or sinr_db: the row adds nothing to the report", "no-values")
    match = _KPI_COMMENT_RE.fullmatch(row["comment"])
    if match and (len(match.group(1)) > 9 or int(match.group(1)) > KPI_MAX_AGE_MS):
        out.warning(file, line, "age_ms=%s is older than the %d ms a fresh sample may be"
                    % (match.group(1)[:12], KPI_MAX_AGE_MS), "age")
    epoch = _number(row["time_epoch"], False) if row["time_epoch"] else None
    if epoch is None or row["rat"] not in ("lte", "nr"):
        return
    recent = state.setdefault("recent", {}).get(row["rat"])
    if recent is None:
        recent = state["recent"][row["rat"]] = collections.deque(maxlen=_REPEAT_WINDOW)
    if row["time_epoch"] in recent:
        out.warning(file, line, "a second %s row at time_epoch %s: a cached repeat logged as a measurement"
                    % (row["rat"], row["time_epoch"]), "repeat")
    recent.append(row["time_epoch"])
    if not EPOCH_MIN <= epoch <= EPOCH_MAX:
        return                                  # reported as outside the time_epoch range
    if ctx.started is not None and epoch < ctx.started.timestamp() - KPI_MAX_AGE_MS / 1000.0 - KPI_WINDOW_SLACK_SECONDS:
        out.error(file, line, "time_epoch %s is %s before started_utc, outside the session, so the charts leave it "
                              "out; a local time written as UTC is off by whole hours"
                  % (row["time_epoch"], _span(ctx.started.timestamp() - epoch)), "window")
    elif ctx.stopped is not None and epoch > ctx.stopped.timestamp() + KPI_WINDOW_SLACK_SECONDS:
        out.error(file, line, "time_epoch %s is %s after stopped_utc, outside the session, so the charts misplace it; "
                              "a local time written as UTC is off by whole hours"
                  % (row["time_epoch"], _span(epoch - ctx.stopped.timestamp())), "window")


def _events_row(row, ctx, file, line, out, state) -> None:
    kind = row["kind"]
    if ctx.measurement_only and (kind in _SIGNALLING_SET or kind.startswith(tuple(SIGNALLING_KIND_PREFIXES))):
        out.error(file, line, "kind %r is a signalling event, which a session without layer 3 cannot have: the report "
                              "counts it as a procedure, handover or radio link failure" % kind, "signalling")
        return
    if not ctx.app or not kind:
        return
    if kind == "session_interrupted":
        when = parse_utc(row["time_utc"])
        if when is not None:
            ctx.interrupted = (when, row["time_utc"])
    if kind not in _APP_KINDS:
        out.warning(file, line, "kind %r is not one of the app's event kinds" % kind, "kind")
        return
    rats, severities, cell = _APP_KINDS[kind]
    if row["rat"] and row["rat"] not in rats:
        out.warning(file, line, "rat %r for %s; expected %s" % (row["rat"], kind, " or ".join(rats)), "kind-rat")
    if row["severity"] and row["severity"] not in severities:
        out.warning(file, line, "severity %r for %s; expected %s" % (row["severity"], kind, " or ".join(severities)),
                    "kind-severity")
    if cell and not row["pci"]:
        out.warning(file, line, "%s without a pci" % kind, "kind-pci")
    if kind == "privacy_zone" and _COORDINATES_RE.search(row["title"] + " " + row["detail"]):
        out.error(file, line, "a privacy_zone event must not carry coordinates", "zone-coordinates")


def _traffic_row(row, ctx, file, line, out, state) -> None:
    test = row["test"]
    if not ctx.app:
        if test not in LAPTOP_TRAFFIC_TESTS:
            out.warning(file, line, "test %r: %s" % (test, _ENUM_NOTES[(TRAFFIC_CSV, "test")]), "test")
        return
    if row["ok"] == "1":
        if test == "ping" and not row["rtt_avg_ms"]:
            out.warning(file, line, "a successful ping without rtt_avg_ms", "ping-rtt")
        if test == "download" and not row["mbps"]:
            out.warning(file, line, "a successful download without mbps", "download-mbps")
        if test == "upload" and not row["mbps"]:
            out.warning(file, line, "a successful upload without mbps", "upload-mbps")
    elif row["ok"] == "0" and not row["error"]:
        out.warning(file, line, "a failed test without an error text", "failed-no-error")
    rtts = [_number(row[k], False) for k in ("rtt_min_ms", "rtt_avg_ms", "rtt_max_ms") if row[k]]
    if len(rtts) == 3 and None not in rtts and not rtts[0] <= rtts[1] <= rtts[2]:
        out.warning(file, line, "rtt_min_ms <= rtt_avg_ms <= rtt_max_ms does not hold", "rtt-order")


def _cells_row(row, ctx, file, line, out, state) -> None:
    if not ctx.app:
        return
    _plmn_consistent(row, file, line, out)
    cell_id = _number(row["cell_id"], True) if row["cell_id"] else None
    if row["rat"] == "lte":
        if cell_id is not None:
            if row["enb_id"] != str(cell_id >> 8) or row["sector"] != str(cell_id & 0xFF):
                out.error(file, line, "enb_id and sector must be cell_id >> 8 and cell_id & 255 (%d and %d)"
                          % (cell_id >> 8, cell_id & 0xFF), "enb")
        elif row["enb_id"] or row["sector"]:
            out.error(file, line, "enb_id and sector are filled but cell_id is blank", "enb")
    elif row["rat"] == "nr" and (row["enb_id"] or row["sector"]):
        out.error(file, line, "enb_id and sector are LTE only; leave them blank for NR", "enb")
    low, high = _number(row["rsrp_min"], False), _number(row["rsrp_max"], False)
    if row["rsrp_min"] and row["rsrp_max"] and low is not None and high is not None and low > high:
        out.warning(file, line, "rsrp_min is above rsrp_max", "rsrp-order")
    if row["plausible"] in ("True", "False"):
        expected = "True" if row["pci"] and row["dl_earfcn"] else "False"
        if row["plausible"] != expected:
            out.error(file, line, "plausible is %s; it is True exactly when pci and dl_earfcn are both filled"
                      % row["plausible"], "plausible")


def _cellinfo_row(row, ctx, file, line, out, state) -> None:
    _check_position(row, ctx, file, line, out)
    if ctx.app:
        _plmn_consistent(row, file, line, out)


_ROW_CHECKS = {TRACK_CSV: _track_row, KPI_CSV: _kpi_row, EVENTS_CSV: _events_row, TRAFFIC_CSV: _traffic_row,
               CELLS_CSV: _cells_row, CELLINFO_CSV: _cellinfo_row}


def _header_message(header: list, full: list, min_columns: int) -> str:
    for i, (got, want) in enumerate(zip(header, full)):
        if got != want:
            return ("column %d is %r where the contract has %r: readers look columns up by name, so the report "
                    "crashes or silently loses that column" % (i + 1, got, want))
    if len(header) < min_columns:
        return "the header stops after %d columns; it needs at least %d (missing %s)" % (
            len(header), min_columns, ", ".join(full[len(header):min_columns]))
    return "%d columns after the last contract column %r: %s" % (
        len(header) - len(full), full[-1], ", ".join(header[len(full):]))


_NOT_UTF8_RE = re.compile("[\udc80-\udcff]")      # a byte that is not UTF-8, as errors="surrogateescape" reads it


class _Lines:
    """The physical lines of a CSV file, handed to csv.reader one at a time, so
    a large file costs a line of memory rather than the whole file. Keeps each
    line's ending for the line-ending checks, and stops at a line that is not
    UTF-8 or is longer than MAX_CSV_LINE_CHARS."""

    def __init__(self, fh):
        self._fh = fh
        self._endings: list = []
        self.count = 0                          # physical lines read
        self.last_ending: Optional[str] = None
        self.stopped: Optional[tuple] = None    # (line, message) when reading stopped early

    def __iter__(self):
        return self

    def __next__(self) -> str:
        if self.stopped is not None:
            raise StopIteration
        line = self._fh.readline(MAX_CSV_LINE_CHARS)
        if not line:
            raise StopIteration
        self.count += 1
        if line.endswith("\r\n"):
            ending = "\r\n"
        elif line.endswith(("\n", "\r")):
            ending = line[-1]
        elif len(line) >= MAX_CSV_LINE_CHARS:
            self.stopped = (self.count, "a line longer than %d characters, which no session file has; the rest of "
                                        "the file is not checked" % MAX_CSV_LINE_CHARS)
            raise StopIteration
        else:
            ending = ""
        if _NOT_UTF8_RE.search(line):
            self.stopped = (self.count, "not UTF-8: the report cannot read it")
            raise StopIteration
        self.last_ending = ending
        self._endings.append(ending)
        return line

    def take(self) -> list:
        """The endings of the lines read since the last call."""
        endings, self._endings = self._endings, []
        return endings


def _check_csv(directory: str, entry: tuple, ctx: _Context, out: _Problems) -> None:
    name, _header_const, spec, min_columns, _presence = entry
    try:
        raw = open(os.path.join(directory, name), "rb")
    except OSError as exc:
        out.error(name, None, "cannot be read: %s" % exc)
        return
    try:
        if raw.read(3) == b"\xef\xbb\xbf":
            out.error(name, 1, "starts with a UTF-8 byte order mark: the first column reads as '\\ufeff%s', which no "
                               "reader finds" % spec[0]["name"])
        else:
            raw.seek(0)
        text = io.TextIOWrapper(raw, encoding="utf-8", errors="surrogateescape", newline="")
        try:
            _check_csv_rows(_Lines(text), name, spec, min_columns, ctx, out)
        finally:
            text.detach()
    except OSError as exc:
        out.error(name, None, "cannot be read: %s" % exc)
    finally:
        raw.close()
    out.close_file(name)


def _check_csv_rows(lines: _Lines, name: str, spec: list, min_columns: int, ctx: _Context, out: _Problems) -> None:
    full = [col["name"] for col in spec]
    reader = csv.reader(lines)
    not_crlf = [0, None]                  # how many lines end in LF or CR alone, and the first of them

    def endings_of_record(first_line: int) -> None:
        endings = lines.take()
        last_line = first_line + len(endings) - 1
        if len(endings) > 1 and ctx.app:
            out.warning(name, first_line, "a quoted field holds a line break, so this row runs over lines %d to %d: "
                                          "free text is written with CR and LF replaced by a space"
                        % (first_line, last_line), "line-break")
        if endings and endings[-1] not in ("\r\n", ""):
            not_crlf[0] += 1
            if not_crlf[1] is None:
                not_crlf[1] = last_line

    try:
        header = next(reader, None)
    except csv.Error as exc:
        out.error(name, 1, "no readable header row (%s)" % exc)
        return
    if lines.stopped is not None:
        out.error(name, lines.stopped[0], lines.stopped[1])
        return
    if header is None:
        (out.error if ctx.app else out.warning)(name, None, "empty: the header row is missing")
        return
    endings_of_record(1)
    count = len(header)
    if not (min_columns <= count <= len(full) and header == full[:count]):
        out.error(name, 1, _header_message(header, full, min_columns))
        return
    if ctx.app and count < len(full):
        out.error(name, 1, "the header stops after %r; the app writes all %d columns (missing %s)"
                  % (header[-1], len(full), ", ".join(full[count:])))
    columns = spec[:count]
    names = full[:count]
    row_check = _ROW_CHECKS.get(name)
    state: dict = {}
    while True:
        first_line = lines.count + 1
        try:
            fields = next(reader)
        except StopIteration:
            break
        except csv.Error as exc:
            out.error(name, lines.count, "cannot be parsed as CSV: %s" % exc)
            return
        if lines.stopped is not None:
            break                         # the row was cut short where reading stopped
        endings_of_record(first_line)
        if not fields:
            if ctx.app:
                out.warning(name, first_line, "empty line", "empty-line")
            continue
        if len(fields) != count:
            why = ("a row cut short, or blank last fields left out (a blank last field still leaves a comma before "
                   "the line ending)" if len(fields) < count else "a comma inside a field that was not quoted")
            out.error(name, first_line, "%d fields where the header has %d: %s" % (len(fields), count, why), "fields")
            continue
        row = dict(zip(names, fields))
        for col in columns:
            _check_value(col, row[col["name"]], row, ctx, name, first_line, out)
        if row_check is not None:
            row_check(row, ctx, name, first_line, out, state)
    if lines.stopped is not None:
        out.error(name, lines.stopped[0], lines.stopped[1])
    elif lines.last_ending == "":
        if ctx.app:
            out.error(name, lines.count, "the last line has no line ending: a row cut short when the app stopped; on "
                                         "the next launch, cut the file back to the end of its last \\r\\n")
        else:
            out.warning(name, lines.count, "the last line has no line ending: a row cut short when the capture stopped?")
    if ctx.app and not_crlf[0]:
        out.warning(name, not_crlf[1], "%d line%s end%s in LF or CR alone instead of CR LF (\\r\\n), the first at line %d"
                    % (not_crlf[0], "" if not_crlf[0] == 1 else "s", "s" if not_crlf[0] == 1 else "", not_crlf[1]))


def _size(path: str) -> int:
    try:
        return os.path.getsize(path) if os.path.isfile(path) else 0
    except OSError:
        return 0


def validate_session(path: str, upload: bool = False) -> list:
    """Check a session directory against fieldtap-session/1.

    Returns a list of Problem, errors and warnings, in file order; an empty
    list means the session is clean. With upload=True the directory must hold
    nothing but the seven session files, at most MAX_UNCOMPRESSED_BYTES of them.
    Never raises for a bad session. CSV files are read a line at a time, so
    memory stays small whatever their size.
    """
    out = _Problems()
    if not os.path.isdir(path):
        out.error("", None, "not a directory: %s" % path)
        return out.items
    if upload:
        total = sum(_size(os.path.join(path, name)) for name in SESSION_FILES)
        if total > MAX_UNCOMPRESSED_BYTES:
            out.error("", None, "the session files hold %d bytes; an upload holds at most %d, so nothing else is "
                                "checked" % (total, MAX_UNCOMPRESSED_BYTES))
            return out.items
    meta = _check_session_json(path, out)
    ctx = _Context(meta or {})
    _check_directory(path, meta or {}, ctx, out, upload)
    for entry in CSV_FILES:
        if os.path.isfile(os.path.join(path, entry[0])):
            _check_csv(path, entry, ctx, out)
    if ctx.app and ctx.interrupted is not None and ctx.stopped is not None:
        when, text = ctx.interrupted
        if abs((ctx.stopped - when).total_seconds()) > INTERRUPTED_STOP_TOLERANCE_SECONDS:
            out.error(SESSION_JSON, None, "stopped_utc %s is not the time of the session_interrupted event (%s): a "
                                          "session Android stopped is closed at its last heartbeat, and the report's "
                                          "duration runs to stopped_utc" % (meta.get("stopped_utc"), text))
    return out.items


def errors(problems: list) -> list:
    return [p for p in problems if p.severity == ERROR]


# --- upload bundle -----------------------------------------------------------------------------------------

def sha256_file(path: str, chunk_size: int = 1 << 20) -> str:
    """Hex SHA-256 of a file, read in chunks: the hash an upload is sent with."""
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(chunk_size), b""):
            digest.update(block)
    return digest.hexdigest()


_EOCD = b"PK\x05\x06"
_ZIP64_LOCATOR = b"PK\x06\x07"
_DRIVE_RE = re.compile(r"^[A-Za-z]:")
_S_IFMT, _S_IFDIR, _S_IFLNK = 0o170000, 0o040000, 0o120000
_MSDOS_DIRECTORY = 0x10


def _end_of_central_directory(path: str) -> Optional[dict]:
    """The archive's own entry count, read before zipfile builds an index of
    every entry, so an archive claiming a million entries costs nothing."""
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        tail_size = min(size, 22 + 65535)
        fh.seek(size - tail_size)
        tail = fh.read(tail_size)
    at = tail.rfind(_EOCD)
    if at < 0 or len(tail) - at < 22:
        return None
    disk, cd_disk, disk_entries, entries, cd_size, cd_offset = struct.unpack("<HHHHII", tail[at + 4:at + 20])
    return {
        "entries": entries,
        "multi_disk": disk != 0 or cd_disk != 0 or disk_entries != entries,
        "zip64": (0xFFFF in (entries, disk_entries) or 0xFFFFFFFF in (cd_size, cd_offset)
                  or tail[max(0, at - 20):at].startswith(_ZIP64_LOCATOR)),
    }


def _entry_path_problem(info: zipfile.ZipInfo) -> Optional[str]:
    # orig_filename is the name as stored; zipfile's filename has already had
    # backslashes turned into slashes on Windows and been cut at a NUL.
    name = info.orig_filename
    mode = info.external_attr >> 16
    if name == "":
        return "an entry with no name"
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in name):
        return "a name with control characters"
    if "\\" in name:
        return "a backslash in the name, which is a path on Windows"
    if name.startswith("/"):
        return "an absolute path"
    if _DRIVE_RE.match(name):
        return "a drive-letter path"
    if ".." in name.split("/"):
        return "a path containing .."
    if name.endswith("/") or (mode & _S_IFMT) == _S_IFDIR or info.external_attr & _MSDOS_DIRECTORY:
        return "a directory entry; the bundle is flat"
    if (mode & _S_IFMT) == _S_IFLNK:
        return "a symbolic link"
    if "/" in name:
        return "a file inside a directory; the bundle is flat"
    return None


def validate_bundle(zip_path: str, max_compressed_bytes: int = MAX_COMPRESSED_BYTES,
                    max_uncompressed_bytes: int = MAX_UNCOMPRESSED_BYTES) -> list:
    """Check an upload bundle without extracting anything to disk.

    Flat names from the seven session files only; no path tricks, directories,
    symlinks, duplicates or names that differ only in case; stored or deflate
    compression; at most max_compressed_bytes on disk and at most
    max_uncompressed_bytes in total, counted while decompressing rather than
    taken from the archive's headers. Returns a list of Problem; never raises
    for a bad archive.
    """
    out = _Problems()
    try:
        size = os.path.getsize(zip_path)
        facts = _end_of_central_directory(zip_path)
    except OSError as exc:
        out.error("", None, "cannot read the bundle: %s" % exc)
        return out.items
    if size > max_compressed_bytes:
        out.error("", None, "%d bytes; a bundle is at most %d bytes compressed" % (size, max_compressed_bytes))
        return out.items
    if facts is None:
        out.error("", None, "not a zip archive (no end-of-central-directory record)")
        return out.items
    if facts["zip64"]:
        out.error("", None, "a zip64 archive; a bundle is far below the sizes that need zip64, so it is refused")
        return out.items
    if facts["multi_disk"]:
        out.error("", None, "a multi-part archive")
        return out.items
    if facts["entries"] > len(SESSION_FILES):
        out.error("", None, "%d entries; a bundle holds at most the %d session files" % (facts["entries"], len(SESSION_FILES)))
        return out.items
    try:
        archive = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, zipfile.LargeZipFile, OSError, ValueError, NotImplementedError) as exc:
        out.error("", None, "not a readable zip archive: %s" % exc)
        return out.items
    with archive:
        infos = archive.infolist()
        if len(infos) > len(SESSION_FILES):
            out.error("", None, "%d entries; a bundle holds at most the %d session files" % (len(infos), len(SESSION_FILES)))
            return out.items
        readable = []
        names: dict = {}
        for info in infos:
            name = info.orig_filename
            problem = _entry_path_problem(info)
            if problem is None and name.lower() in names:
                other = names[name.lower()]
                problem = "a duplicate entry" if other == name else "differs only in case from %r" % other
            if problem is None and name not in SESSION_FILES:
                problem = "not one of the seven session files (%s)" % ", ".join(SESSION_FILES)
            if problem is None and info.flag_bits & 0x1:
                problem = "encrypted"
            if problem is None and info.compress_type not in (ZIP_STORED, ZIP_DEFLATED):
                problem = "compression method %d; only stored (0) and deflate (8) are accepted" % info.compress_type
            if problem is not None:
                out.error(name, None, problem)
                continue
            names[name.lower()] = name
            readable.append(info)
        if SESSION_JSON not in names.values():
            out.error("", None, "no session.json in the bundle")
        total = 0
        for info in readable:
            try:
                with archive.open(info) as fh:
                    while True:
                        block = fh.read(1 << 16)
                        if not block:
                            break
                        total += len(block)
                        if total > max_uncompressed_bytes:
                            out.error("", None, "more than %d bytes uncompressed, counted while reading %s; refused"
                                      % (max_uncompressed_bytes, info.orig_filename))
                            return out.items
            except (zipfile.BadZipFile, zlib.error, EOFError, OSError, ValueError, NotImplementedError,
                    RuntimeError) as exc:
                out.error(info.orig_filename, None, "corrupt: %s" % exc)
    return out.items
