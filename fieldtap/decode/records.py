"""Decoded-object types and the dispatching Decoder."""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

from ..diag.protocol import LogRecord
from .channels import Channel
from .registry import LOG_CODES

GSMTAP_TYPE_LTE_RRC = 13
GSMTAP_TYPE_LTE_NAS = 18


@dataclass
class DecodedMessage:
    rat: str                       # "lte" | "nr"
    layer: str                     # "rrc" | "nas"
    channel: Channel
    direction: str                 # "ul" | "dl" | "unknown"
    payload: bytes
    timestamp: Optional[datetime]
    log_code: int
    version: int
    fields: dict = field(default_factory=dict)
    name: Optional[str] = None

    @property
    def dissector(self) -> str:
        return self.channel.dissector

    @property
    def gsmtap(self) -> Optional[tuple]:
        """(type, subtype) when a GSMTAP encoding exists for this message."""
        if self.rat != "lte":
            return None
        if self.layer == "rrc" and self.channel.gsmtap_subtype is not None:
            return GSMTAP_TYPE_LTE_RRC, self.channel.gsmtap_subtype
        if self.layer == "nas":
            return GSMTAP_TYPE_LTE_NAS, self.channel.gsmtap_subtype or 0
        return None

    @property
    def arfcn(self) -> Optional[int]:
        return self.fields.get("earfcn", self.fields.get("arfcn"))

    def summary(self) -> str:
        rat = "NR" if self.rat == "nr" else "LTE"
        head = "%s %s %s" % (rat, self.layer.upper(), self.channel.label)
        if self.name:
            head += " %s" % self.name
        return head

    def comment(self) -> str:
        """Packet comment for pcapng: what the diag wrapper knew about this PDU."""
        parts = ["FieldTap %s" % self.summary(), "log 0x%04X v%d" % (self.log_code, self.version)]
        f = self.fields
        if "pci" in f:
            parts.append("PCI %d" % f["pci"])
        if self.arfcn is not None:
            parts.append("%s %d" % ("NR-ARFCN" if self.rat == "nr" else "EARFCN", self.arfcn))
        if "sfn" in f:
            parts.append("SFN %d.%d" % (f["sfn"], f.get("subfn", 0)))
        if "rb_id" in f:
            parts.append("RB %d" % f["rb_id"])
        if "pdu_num" in f:
            parts.append("PDU %d" % f["pdu_num"])
        if "sib_mask" in f and f["sib_mask"]:
            parts.append("SIB mask 0x%X" % f["sib_mask"])
        if "security_header" in f and f["security_header"]:
            parts.append("sec-hdr %d" % f["security_header"])
        src = f.get("layout_source") or f.get("nas_locate")
        if src and src != "table":
            parts.append("layout %s" % src)
        if f.get("direction_conflict"):
            parts.append("direction from message, log code disagreed")
        if self.channel.dissector == "data":
            parts.append("not decoded: %s" % self.channel.label)
        return " | ".join(parts)


@dataclass
class CellInfo:
    rat: str
    kind: str                      # "serving_cell" | "mib"
    timestamp: Optional[datetime]
    log_code: int
    version: int
    fields: dict = field(default_factory=dict)


@dataclass
class DiagRecord:
    """Any log record that is not an OTA message, on its way to the pcap.

    The body is kept verbatim so the capture file is complete whether or not
    FieldTap knows the layout; `fields` and `sections` hold what it decoded,
    and `decoded` says how far that went: "fields" (a layout fitted), "partial"
    (header only), or "raw" (nothing but the bytes)."""
    log_code: int
    name: str
    version: int
    timestamp: Optional[datetime]
    timestamp_raw: int
    body: bytes
    fields: dict = field(default_factory=dict)
    sections: list = field(default_factory=list)      # [(label, [dict, ...]), ...]
    decoded: str = "raw"                              # "fields" | "partial" | "raw"
    confidence: str = "low"
    note: str = ""
    # LTE MAC transport blocks: MAC PDUs (often the sub-headers only) with their context,
    # each written as a mac-lte-framed frame so Wireshark runs its own MAC/RLC/PDCP decode.
    # {"pdu": bytes, "downlink": bool, "rnti_type": int, "sfn": int, "subframe": int, "note": str}
    mac_pdus: list = field(default_factory=list)

    def summary(self) -> str:
        head = "0x%04X %s" % (self.log_code, self.name)
        if self.version:
            head += " v%d" % self.version
        return head

    def comment(self) -> str:
        """Packet comment: readable without the Wireshark plugin."""
        parts = ["FieldTap %s" % self.summary()]
        if self.decoded == "raw":
            parts.append("%d bytes, no layout" % len(self.body))
        else:
            # The fields a reader looks for first, then the rest, up to ten in all.
            order = [k for k in _HEADLINE_FIELDS if k in self.fields]
            order += [k for k in self.fields if k not in order]
            shown = 0
            for key in order:
                value = self.fields[key]
                if key.startswith("_") or value is None or isinstance(value, (bytes, list, dict)):
                    continue
                parts.append("%s %s" % (key, _fmt_value(value)))
                shown += 1
                if shown >= 10:
                    break
            for label, rows in self.sections:
                parts.append("%s x%d" % (label, len(rows)))
        if self.note:
            parts.append(self.note)
        return " | ".join(parts)


# What a packet comment leads with, when the record has it.
_HEADLINE_FIELDS = ("state", "plmn", "pci", "dl_earfcn", "earfcn", "arfcn", "nr_arfcn", "band", "tac", "cell_id",
                    "rsrp", "rsrq", "rssi", "sinr", "snr", "sfn", "subframe", "num_cells", "num_neighbours",
                    "tbs_bytes", "grant_bytes", "harq_id", "rnti_type")

def _fmt_value(value) -> str:
    if isinstance(value, float):
        return "%.1f" % value
    return str(value)


class Decoder:
    """Route log records to parsers and keep the statistics the reports need."""

    def __init__(self):
        self.stats: Counter = Counter()
        self.by_code: Counter = Counter()
        self.versions = defaultdict(Counter)     # code -> version -> count
        self.unknown_codes: Counter = Counter()
        self.errors: Counter = Counter()
        self.layout_sources: Counter = Counter()
        self.decoded_as = defaultdict(Counter)     # code -> "message"|"cell"|"fields"|"partial"|"raw" -> count

    def decode(self, rec: LogRecord) -> list:
        self.by_code[rec.code] += 1
        info = LOG_CODES.get(rec.code)
        if info is None:
            self.unknown_codes[rec.code] += 1
            self.stats["unknown"] += 1
            return [self._raw(rec, None)]
        if not info.decoder:
            self.stats["not_decoded"] += 1
            return [self._raw(rec, info)]
        parser = decoders().get(info.decoder)
        if parser is None:
            self.stats["not_decoded"] += 1
            return [self._raw(rec, info)]
        try:
            result = parser(rec, info)
        except Exception as exc:  # a bad record must never stop the capture
            self.errors["%s: %s" % (info.decoder, exc.__class__.__name__)] += 1
            self.stats["errors"] += 1
            return [self._raw(rec, info, note="decoder error: %s" % exc.__class__.__name__)]
        if result is None:
            self.stats["unparsed"] += 1
            self.errors["%s: unparsed 0x%04X" % (info.decoder, rec.code)] += 1
            return [self._raw(rec, info, note="layout did not fit; raw bytes kept")]
        self.versions[rec.code][result.version] += 1
        if isinstance(result, DecodedMessage):
            self.stats["messages"] += 1
            self.stats["messages_%s_%s" % (result.rat, result.layer)] += 1
            self.decoded_as[rec.code]["message"] += 1
            src = result.fields.get("layout_source") or result.fields.get("nas_locate")
            if src:
                self.layout_sources[src] += 1
            if result.fields.get("direction_conflict"):
                self.stats["direction_conflicts"] += 1
            if result.channel.dissector == "data":
                self.stats["unmapped_channel"] += 1
            return [result]
        if isinstance(result, CellInfo):
            # The sidecar and KPI export keep the CellInfo; the pcap gets the same record
            # with its fields, so the capture file is complete.
            self.stats["cell_info"] += 1
            self.decoded_as[rec.code]["cell"] += 1
            self.stats["diag_records"] += 1
            return [result, DiagRecord(rec.code, info.name, result.version, rec.timestamp, rec.timestamp_raw,
                                       rec.body, fields=dict(result.fields), decoded="fields",
                                       confidence=info.confidence)]
        if isinstance(result, DiagRecord):
            self.stats["diag_records"] += 1
            self.decoded_as[rec.code][result.decoded] += 1
            return [result]
        self.errors["%s: returned %s" % (info.decoder, type(result).__name__)] += 1
        return [self._raw(rec, info, note="decoder returned an unexpected object")]

    def _raw(self, rec: LogRecord, info, note: str = "") -> DiagRecord:
        """The record as it is: name and bytes, no layout."""
        self.stats["diag_records"] += 1
        self.decoded_as[rec.code]["raw"] += 1
        name = info.name if info is not None else "unknown log 0x%04X" % rec.code
        version = rec.body[0] if rec.body else 0
        return DiagRecord(rec.code, name, version, rec.timestamp, rec.timestamp_raw, rec.body,
                          decoded="raw", confidence=info.confidence if info is not None else "low", note=note)

    def report(self) -> dict:
        stats = dict(self.stats)
        stats.setdefault("errors", 0)
        coverage = {}
        for code, n in sorted(self.by_code.items()):
            info = LOG_CODES.get(code)
            ways = self.decoded_as.get(code, Counter())
            coverage["0x%04X" % code] = {
                "name": info.name if info else "unknown log 0x%04X" % code,
                "records": n,
                "as": dict(ways),
                "confidence": info.confidence if info else "low",
            }
        return {
            "stats": stats,
            "coverage": coverage,
            "by_code": {"0x%04X" % c: n for c, n in sorted(self.by_code.items())},
            "versions": {"0x%04X" % c: dict(v) for c, v in sorted(self.versions.items())},
            "unknown_codes": {"0x%04X" % c: n for c, n in sorted(self.unknown_codes.items())},
            "errors": dict(self.errors),
            "layout_sources": dict(self.layout_sources),
        }


_DECODERS: dict = {}


# Modules that contribute record decoders. Each exposes DECODERS = {key: parser}, where a
# parser is parser(rec, info) -> DecodedMessage | CellInfo | DiagRecord | None. A module that
# is not there yet is skipped, so the register can name a decoder before it exists.
_DECODER_MODULES = ("lte_ml1", "lte_mac", "lte_phy", "lte_ll1", "rf", "nr_cell", "nr_ml1", "nr_state", "nr_mac")


def decoders() -> dict:
    """Parser table, built on first use so the parser modules can import this one."""
    if not _DECODERS:
        import importlib
        from . import cellinfo, lte_rrc, nas, nr_rrc
        _DECODERS.update({
            "lte_rrc": lte_rrc.decode,
            "nr_rrc": nr_rrc.decode,
            "nas": nas.decode,
            "lte_serving_cell": cellinfo.decode_serving_cell,
            "lte_mib": cellinfo.decode_mib,
        })
        for name in _DECODER_MODULES:
            try:
                module = importlib.import_module("fieldtap.decode." + name)
            except ImportError:
                continue
            _DECODERS.update(getattr(module, "DECODERS", {}))
    return _DECODERS
