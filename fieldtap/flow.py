"""Call-flow ladder (roadmap 3.5): the UE <-> network sequence of RRC and NAS
messages from a FieldTap pcapng, as text, CSV or a Mermaid sequence diagram.

Works without tshark (message names come from the packet comments FieldTap
wrote); with tshark, Wireshark's own Info column is added for detail."""

from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from . import tshark as tshark_mod
from .output import exported_pdu
from .output.pcapng import read_packets

_COMMENT_RE = re.compile(r"^FieldTap (?P<rat>NR|LTE) (?P<layer>RRC|NAS) (?P<channel>\S+)(?: (?P<name>.*?))?(?: \| |$)")


@dataclass
class FlowEvent:
    number: int
    when: datetime
    rel: float
    rat: str
    layer: str
    channel: str
    direction: str
    name: str
    info: str = ""
    comment: str = ""

    @property
    def label(self) -> str:
        return "%s %s %s" % (self.rat, self.layer, self.name or self.channel)


def _parse_comment(comment: str):
    m = _COMMENT_RE.match(comment or "")
    if not m:
        return None
    return m.group("rat"), m.group("layer"), m.group("channel"), (m.group("name") or "").strip()


# Records that are not RRC/NAS messages travel in the same pcap under these dissectors.
NON_MESSAGE_DISSECTORS = ("fieldtap-diag", "mac-lte-framed")


def load_events(path: str, use_tshark: bool = True) -> list:
    events = []
    first: Optional[int] = None
    infos = {}
    if use_tshark and tshark_mod.find_tshark():
        try:
            for number, info in tshark_mod.fields(path, ["frame.number", "_ws.col.Info"]):
                if number:
                    infos[int(number)] = info
        except RuntimeError:
            infos = {}
    for number, pkt in enumerate(read_packets(path), start=1):
        parsed = _parse_comment(pkt.comment or "")
        options, _payload = exported_pdu.parse(pkt.data) if pkt.linktype == exported_pdu.LINKTYPE_WIRESHARK_UPPER_PDU else ({}, b"")
        if options.get("dissector") in NON_MESSAGE_DISSECTORS:
            continue    # cell info, measurements, MAC blocks: in the pcap, not in the call flow
        if parsed is None:
            rat, layer, channel, name = "?", "?", options.get("dissector", "?"), ""
        else:
            rat, layer, channel, name = parsed
        direction = options.get("direction") or ("dl" if channel.startswith(("DL", "BCCH", "PCCH")) else "ul" if channel.startswith("UL") else "?")
        if first is None:
            first = pkt.micros
        events.append(FlowEvent(number, pkt.when, (pkt.micros - first) / 1e6, rat, layer, channel,
                                direction, name, infos.get(number, ""), pkt.comment or ""))
    return events


def render_text(events: list, width: int = 100) -> str:
    inner = max(30, width - 22)
    lines = ["%9s  %-6s %s" % ("t(s)", "", "UE" + " " * (inner - 4) + "Network"),
             "%9s  %-6s %s" % ("", "", "|" + " " * (inner - 2) + "|")]
    for ev in events:
        text = ev.label
        if ev.info and ev.info != ev.name:
            text += "  [%s]" % ev.info
        text = text[: inner - 8]
        if ev.direction == "ul":
            arrow = "|--" + text.center(inner - 6, "-") + "->|"
        elif ev.direction == "dl":
            arrow = "|<-" + text.center(inner - 6, "-") + "--|"
        else:
            arrow = "|  " + text.center(inner - 6) + "  |"
        lines.append("%9.3f  %-6s %s" % (ev.rel, ev.rat, arrow))
    return "\n".join(lines)


def render_mermaid(events: list) -> str:
    lines = ["sequenceDiagram", "    participant UE", "    participant NW as Network"]
    for ev in events:
        text = ev.label.replace(":", " ")
        if ev.direction == "ul":
            lines.append("    UE->>NW: %s" % text)
        elif ev.direction == "dl":
            lines.append("    NW->>UE: %s" % text)
        else:
            lines.append("    Note over UE,NW: %s" % text)
    return "\n".join(lines)


def render_csv(events: list) -> str:
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(["frame", "time_utc", "t_rel_s", "rat", "layer", "channel", "direction", "message", "wireshark_info", "comment"])
    for ev in events:
        writer.writerow([ev.number, ev.when.astimezone(timezone.utc).isoformat(timespec="milliseconds"),
                         "%.6f" % ev.rel, ev.rat, ev.layer, ev.channel, ev.direction, ev.name, ev.info, ev.comment])
    return out.getvalue()


def render(events: list, fmt: str = "text", width: int = 100) -> str:
    if fmt == "mermaid":
        return render_mermaid(events)
    if fmt == "csv":
        return render_csv(events)
    return render_text(events, width)
