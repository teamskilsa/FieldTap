"""Locate and drive tshark / Wireshark. Wireshark is the decoder; FieldTap
only needs to find it and ask it questions."""

from __future__ import annotations

import os
import shutil
import subprocess
from collections import Counter
from typing import Optional

_WINDOWS_DIRS = [r"C:\Program Files\Wireshark", r"C:\Program Files (x86)\Wireshark"]
_MAC_DIRS = ["/Applications/Wireshark.app/Contents/MacOS"]
_UNIX_DIRS = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/snap/bin"]


def _find(name: str, env_var: str) -> Optional[str]:
    override = os.environ.get(env_var)
    if override and os.path.isfile(override):
        return override
    found = shutil.which(name)
    if found:
        return found
    exe = name + (".exe" if os.name == "nt" else "")
    for directory in _WINDOWS_DIRS + _MAC_DIRS + _UNIX_DIRS:
        candidate = os.path.join(directory, exe)
        if os.path.isfile(candidate):
            return candidate
    return None


def find_tshark() -> Optional[str]:
    return _find("tshark", "FIELDTAP_TSHARK")


def find_wireshark() -> Optional[str]:
    return _find("wireshark", "FIELDTAP_WIRESHARK") or _find("Wireshark", "FIELDTAP_WIRESHARK")


def version(tshark: Optional[str] = None) -> Optional[str]:
    tshark = tshark or find_tshark()
    if not tshark:
        return None
    try:
        out = subprocess.run([tshark, "--version"], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return out.splitlines()[0].strip() if out else None


def fields(path: str, names: list, display_filter: Optional[str] = None,
           tshark: Optional[str] = None, occurrence: str = "a", lua_scripts: Optional[list] = None) -> list:
    """Run tshark -T fields and return rows of strings (one per packet).
    Multiple occurrences of a field in one packet are joined with ','.
    lua_scripts: plugin files to load with -X lua_script (the FieldTap dissector)."""
    tshark = tshark or find_tshark()
    if not tshark:
        raise RuntimeError("tshark not found (install Wireshark, or set FIELDTAP_TSHARK)")
    cmd = [tshark, "-r", path, "-T", "fields", "-E", "separator=\t", "-E", "occurrence=%s" % occurrence,
           "-E", "aggregator=,"]
    for script in lua_scripts or []:
        cmd += ["-X", "lua_script:%s" % script]
    for name in names:
        cmd += ["-e", name]
    if display_filter:
        cmd += ["-Y", display_filter]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError("tshark failed: %s" % proc.stderr.strip())
    rows = []
    for line in proc.stdout.splitlines():
        cells = line.split("\t")
        cells += [""] * (len(names) - len(cells))
        rows.append(cells)
    return rows


def protocol_summary(path: str, tshark: Optional[str] = None) -> Counter:
    counter: Counter = Counter()
    for (protocols,) in fields(path, ["frame.protocols"], tshark=tshark):
        counter[protocols] += 1
    return counter


def malformed(path: str, tshark: Optional[str] = None, lua_scripts: Optional[list] = None) -> list:
    """Frames Wireshark flags as malformed or with error-level expert info."""
    rows = fields(path, ["frame.number", "_ws.expert.message"],
                  display_filter="_ws.malformed || _ws.expert.severity == error", tshark=tshark,
                  lua_scripts=lua_scripts)
    return [(int(r[0]), r[1]) for r in rows if r[0]]
