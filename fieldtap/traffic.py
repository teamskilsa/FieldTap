"""Active tests run on the phone through adb while the capture is running.

No app is installed on the phone. `ping` ships with Android (toybox). `curl`
does not ship on stock Android, so its presence is checked once and the
download test is skipped with a note when it is missing; push a static arm64
curl (or iperf3) to /data/local/tmp and it is used. Results are time-stamped
with host UTC so they line up with the signalling and the GPS track in the
report.
"""

from __future__ import annotations

import csv
import io
import re
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Optional

from .diag import transport as tr
from .isotime import parse_iso

DEFAULT_PING_HOST = "8.8.8.8"
DEFAULT_DOWNLOAD_URL = "https://speed.cloudflare.com/__down?bytes=25000000"
IPERF_REMOTE = "/data/local/tmp/iperf3"


@dataclass
class TestResult:
    when: datetime
    test: str                      # ping | download | upload | iperf3
    target: str
    ok: bool
    metrics: dict = field(default_factory=dict)
    raw: str = ""
    seconds: float = 0.0

    @property
    def when_iso(self) -> str:
        return self.when.astimezone(timezone.utc).isoformat(timespec="milliseconds")

    def line(self) -> str:
        m = self.metrics
        if self.test == "ping":
            return "ping %s: %s%% loss, rtt avg %s ms (min %s / max %s)" % (
                self.target, m.get("loss_pct", "?"), m.get("rtt_avg_ms", "?"), m.get("rtt_min_ms", "?"), m.get("rtt_max_ms", "?"))
        if self.test in ("download", "upload"):
            return "%s: %.2f Mbit/s, %s bytes in %.1f s, http %s" % (
                self.test, m.get("mbps", 0.0), m.get("bytes", "?"), m.get("seconds", self.seconds),
                m.get("http_code", "?"))
        if self.test == "iperf3":
            return "iperf3 %s: %.2f Mbit/s" % (self.target, m.get("mbps", 0.0))
        return "%s: %s" % (self.test, "ok" if self.ok else "failed")


COLUMNS = ["time_utc", "test", "target", "ok", "seconds", "loss_pct", "rtt_min_ms", "rtt_avg_ms", "rtt_max_ms",
           "mbps", "bytes", "http_code", "error"]


def to_csv(results: list) -> str:
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(COLUMNS)
    for r in results:
        m = r.metrics
        w.writerow([r.when_iso, r.test, r.target, int(r.ok), "%.2f" % r.seconds,
                    m.get("loss_pct", ""), m.get("rtt_min_ms", ""), m.get("rtt_avg_ms", ""), m.get("rtt_max_ms", ""),
                    ("%.3f" % m["mbps"]) if "mbps" in m else "", m.get("bytes", ""), m.get("http_code", ""),
                    m.get("error", "")])
    return out.getvalue()


def read_csv(path: str) -> list:
    results = []
    with open(path, encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            metrics = {}
            for key in ("loss_pct", "rtt_min_ms", "rtt_avg_ms", "rtt_max_ms", "mbps", "bytes"):
                if row.get(key):
                    metrics[key] = float(row[key]) if key != "bytes" else int(float(row[key]))
            if row.get("http_code"):
                metrics["http_code"] = row["http_code"]
            if row.get("error"):
                metrics["error"] = row["error"]
            results.append(TestResult(parse_iso(row["time_utc"]), row["test"], row["target"],
                                      row["ok"] == "1", metrics, "", float(row.get("seconds") or 0)))
    return results


def summary(results: list) -> dict:
    out = {}
    pings = [r for r in results if r.test == "ping"]
    if pings:
        ok = [r for r in pings if r.ok]
        avg = [r.metrics["rtt_avg_ms"] for r in ok if "rtt_avg_ms" in r.metrics]
        # every run that measured loss, failed runs too: a ping that lost every packet failed with 100% loss
        loss = [r.metrics["loss_pct"] for r in pings if "loss_pct" in r.metrics]
        out["ping"] = {"runs": len(pings), "failed": len(pings) - len(ok),
                       "rtt_avg_ms": round(sum(avg) / len(avg), 1) if avg else None,
                       "rtt_max_ms": max((r.metrics.get("rtt_max_ms", 0) for r in ok), default=None),
                       "loss_pct_avg": round(sum(loss) / len(loss), 1) if loss else None}
    for name in ("download", "upload", "iperf3"):
        runs = [r for r in results if r.test == name]
        if runs:
            ok = [r for r in runs if r.ok and "mbps" in r.metrics]
            mbps = [r.metrics["mbps"] for r in ok]
            out[name] = {"runs": len(runs), "failed": len(runs) - len(ok),
                         "mbps_avg": round(sum(mbps) / len(mbps), 2) if mbps else None,
                         "mbps_max": round(max(mbps), 2) if mbps else None,
                         "mbps_min": round(min(mbps), 2) if mbps else None}
    return out


# --- parsers -------------------------------------------------------------------------------------------

_PING_STATS_RE = re.compile(r"(\d+) packets transmitted, (\d+) (?:packets )?received.*?([\d.]+)% packet loss", re.S)
_PING_RTT_RE = re.compile(r"(?:rtt|round-trip) min/avg/max(?:/mdev|/stddev)? = ([\d.]+)/([\d.]+)/([\d.]+)")


def parse_ping(output: str) -> dict:
    m = _PING_STATS_RE.search(output)
    metrics = {}
    if m:
        sent, received, loss = int(m.group(1)), int(m.group(2)), float(m.group(3))
        metrics.update(sent=sent, received=received, loss_pct=loss)
    r = _PING_RTT_RE.search(output)
    if r:
        metrics.update(rtt_min_ms=float(r.group(1)), rtt_avg_ms=float(r.group(2)), rtt_max_ms=float(r.group(3)))
    return metrics


def parse_curl_write_out(output: str) -> dict:
    """`%{speed_download} %{size_download} %{time_total} %{http_code}` -> metrics.

    Tolerates surrounding quotes: adb's shell passes the -w argument through
    verbatim, so depending on how the command was quoted curl may echo them.
    """
    parts = output.strip().strip("'\"").split()
    if len(parts) < 4:
        return {}
    try:
        speed_bps = float(parts[0])
        size = int(float(parts[1]))
        seconds = float(parts[2])
    except ValueError:
        return {}
    return {"mbps": speed_bps * 8 / 1e6, "bytes": size, "seconds": seconds, "http_code": parts[3]}


_IPERF_RE = re.compile(r"([\d.]+)\s+([KMG])bits/sec.*?(?:receiver|sender)", re.S)


def parse_iperf3(output: str) -> dict:
    best = None
    for m in re.finditer(r"([\d.]+)\s+([KMG])bits/sec\s+(?:\S+\s+)?(sender|receiver)", output):
        value, unit, role = float(m.group(1)), m.group(2), m.group(3)
        mbps = value * {"K": 1e-3, "M": 1.0, "G": 1e3}[unit]
        if role == "receiver" or best is None:
            best = mbps
    return {"mbps": best} if best is not None else {}


# --- the runner ------------------------------------------------------------------------------------------

class TrafficRunner(threading.Thread):
    """Run the configured tests every `interval` seconds until stopped."""

    def __init__(self, serial: Optional[str], tests: list, interval: float = 60.0,
                 ping_host: str = DEFAULT_PING_HOST, download_url: str = DEFAULT_DOWNLOAD_URL,
                 iperf_server: Optional[str] = None, ping_count: int = 5,
                 log: Callable[[str], None] = lambda s: None, stop: Optional[threading.Event] = None,
                 shell: Optional[Callable[[list, float], str]] = None):
        super().__init__(name="fieldtap-traffic", daemon=True)
        self.serial = serial
        self.tests = [t for t in tests if t in ("ping", "download", "iperf3")]
        self.interval = interval
        self.ping_host, self.download_url, self.iperf_server, self.ping_count = ping_host, download_url, iperf_server, ping_count
        self.log = log
        self.stop_event = stop or threading.Event()
        self.results: list = []
        self._shell = shell or self._adb_shell
        self.curl_available: Optional[bool] = None

    def _adb_shell(self, args: list, timeout: float) -> str:
        return tr.adb(["shell"] + args, serial=self.serial, timeout=timeout, check=False)

    def _run(self, test: str, target: str, args: list, timeout: float, parse) -> TestResult:
        started = datetime.now(timezone.utc)
        t0 = __import__("time").monotonic()
        try:
            out = self._shell(args, timeout)
            metrics = parse(out)
            ok = bool(metrics) and (metrics.get("received", 1) > 0 if test == "ping" else True)
            if test == "download" and str(metrics.get("http_code", "200")) not in ("200", "206"):
                ok = False
            if not metrics:
                metrics = {"error": (out.strip().splitlines() or ["no output"])[-1][:120]}
        except Exception as exc:
            out, metrics, ok = "", {"error": str(exc)[:120]}, False
        return TestResult(started, test, target, ok, metrics, out[-2000:], __import__("time").monotonic() - t0)

    def run_once(self) -> list:
        results = []
        for test in self.tests:
            if self.stop_event.is_set():
                break
            if test == "ping":
                r = self._run("ping", self.ping_host,
                              ["ping", "-c", str(self.ping_count), "-W", "2", self.ping_host],
                              self.ping_count * 3 + 10, parse_ping)
            elif test == "download":
                if self.curl_available is None:
                    self.curl_available = "curl" in self._shell(["which", "curl"], 10)
                    if not self.curl_available:
                        self.log("traffic: curl not on the phone, download test skipped")
                if not self.curl_available:
                    continue
                r = self._run("download", self.download_url,
                              ["curl", "-s", "-L", "-o", "/dev/null", "--max-time", "60",
                               "-w", "%{speed_download} %{size_download} %{time_total} %{http_code}",
                               self.download_url],
                              75, parse_curl_write_out)
            else:
                if not self.iperf_server:
                    continue
                r = self._run("iperf3", self.iperf_server,
                              [IPERF_REMOTE, "-c", self.iperf_server, "-t", "10", "-R"], 40, parse_iperf3)
            results.append(r)
            self.results.append(r)
            self.log("traffic: " + r.line() if r.ok else "traffic: %s failed (%s)" % (r.test, r.metrics.get("error", "?")))
        return results

    def run(self) -> None:
        while not self.stop_event.is_set():
            self.run_once()
            self.stop_event.wait(self.interval)
