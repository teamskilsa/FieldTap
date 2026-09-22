"""Where decoded messages go. Every sink takes DecodedMessage objects."""

from __future__ import annotations

import os
import subprocess
from collections import Counter
from datetime import datetime, timezone
from typing import Optional

from ..decode.records import DecodedMessage, DiagRecord
from ..diag.protocol import timestamp_is_plausible
from . import exported_pdu, fieldtap_diag, gsmtap
from .pcap import PcapWriter
from .pcapng import PcapngWriter


def _when(msg: DecodedMessage, counter: Counter) -> datetime:
    if timestamp_is_plausible(msg.timestamp):
        counter["ts_modem"] += 1
        return msg.timestamp
    counter["ts_host"] += 1
    return datetime.now(timezone.utc)


def _col_proto(msg: DecodedMessage) -> Optional[str]:
    # The RRC dissectors leave the Protocol column to the encapsulation; NAS sets its own.
    if msg.layer == "rrc":
        return "%s RRC %s" % ("NR" if msg.rat == "nr" else "LTE", msg.channel.label)
    return None


class Sink:
    def __init__(self):
        self.stats: Counter = Counter()

    def write(self, msg: DecodedMessage) -> None:
        raise NotImplementedError

    def flush(self) -> None:
        pass

    def close(self) -> None:
        pass


class PcapngSink(Sink):
    """The primary format: pcapng, exported-PDU link type, one packet per PDU,
    diag metadata in the packet comment. Opens in stock Wireshark."""

    def __init__(self, target, comment: Optional[str] = None, hardware: Optional[str] = None,
                 application: Optional[str] = None):
        super().__init__()
        from .. import __version__
        self._own = isinstance(target, (str, os.PathLike))
        fh = open(target, "wb") if self._own else target
        self.path = str(target) if self._own else None
        self.writer = PcapngWriter(fh, application or "FieldTap %s" % __version__, comment, hardware)
        self.if_id = self.writer.add_interface(exported_pdu.LINKTYPE_WIRESHARK_UPPER_PDU, "fieldtap",
                                               "RRC/NAS PDUs from the Qualcomm diag port")

    def write(self, msg) -> None:
        if isinstance(msg, DiagRecord):
            self._write_record(msg)
            return
        frame = exported_pdu.build(msg.dissector, msg.payload, msg.direction, _col_proto(msg))
        self.writer.write_packet(self.if_id, frame, when=_when(msg, self.stats), comment=msg.comment())
        self.stats["packets"] += 1
        self.stats[msg.rat + "_" + msg.layer] += 1

    def _write_record(self, rec: DiagRecord) -> None:
        """A non-message record: the fieldtap-diag wrapper, then any MAC PDUs it carried
        as mac-lte-framed frames so Wireshark decodes MAC, RLC and PDCP itself."""
        when = _when(rec, self.stats)
        plausible = timestamp_is_plausible(rec.timestamp)
        frame = exported_pdu.build(fieldtap_diag.DISSECTOR,
                                   fieldtap_diag.build(rec.log_code, rec.timestamp_raw, rec.body, plausible,
                                                       rec.decoded != "raw"),
                                   None, "FieldTap 0x%04X" % rec.log_code)
        self.writer.write_packet(self.if_id, frame, when=when, comment=rec.comment())
        self.stats["packets"] += 1
        self.stats["diag_records"] += 1
        self.stats["diag_" + rec.decoded] += 1
        for pdu in rec.mac_pdus:
            framed = fieldtap_diag.build_mac_lte_framed(pdu["pdu"], pdu["downlink"], pdu.get("rnti_type", 3),
                                                        pdu.get("rnti"), pdu.get("ueid"), pdu.get("sfn"),
                                                        pdu.get("subframe"))
            mac_frame = exported_pdu.build(fieldtap_diag.MAC_LTE_DISSECTOR, framed,
                                           "dl" if pdu["downlink"] else "ul")
            comment = "FieldTap %s | MAC PDU%s" % (rec.summary(), (" | " + pdu["note"]) if pdu.get("note") else "")
            self.writer.write_packet(self.if_id, mac_frame, when=when, comment=comment)
            self.stats["packets"] += 1
            self.stats["mac_lte_pdus"] += 1

    def flush(self) -> None:
        self.writer.flush()

    def close(self) -> None:
        if self._own:
            self.writer.close()
        else:
            self.writer.flush()


class GsmtapPcapSink(Sink):
    """Classic pcap, GSMTAP over UDP/IPv4: what the Nov 2025 workflow produced.
    Only LTE RRC and LTE NAS have GSMTAP payload types; NR messages are counted
    as skipped, which is the reason this is not the default format."""

    def __init__(self, target):
        super().__init__()
        self._own = isinstance(target, (str, os.PathLike))
        fh = open(target, "wb") if self._own else target
        self.path = str(target) if self._own else None
        self.writer = PcapWriter(fh, gsmtap.LINKTYPE_RAW)

    def write(self, msg) -> None:
        if not isinstance(msg, DecodedMessage):
            self.stats["skipped_diag_record"] += 1
            return
        mapping = msg.gsmtap
        if mapping is None:
            self.stats["skipped_no_gsmtap"] += 1
            self.stats["skipped_" + msg.rat + "_" + msg.layer] += 1
            return
        gsmtap_type, sub_type = mapping
        frame = gsmtap.build_frame(gsmtap_type, sub_type, msg.payload, msg.arfcn, msg.direction == "ul",
                                   msg.fields.get("sfn", 0), msg.fields.get("subfn", 0))
        self.writer.write_packet(frame, when=_when(msg, self.stats))
        self.stats["packets"] += 1

    def flush(self) -> None:
        self.writer.flush()

    def close(self) -> None:
        if self._own:
            self.writer.close()
        else:
            self.writer.flush()


class GsmtapUdpSink(Sink):
    """Live GSMTAP datagrams for a Wireshark listening on udp/4729 (LTE only)."""

    def __init__(self, host: str = "127.0.0.1", port: int = gsmtap.GSMTAP_UDP_PORT):
        super().__init__()
        self.sender = gsmtap.UdpSender(host, port)

    def write(self, msg) -> None:
        if not isinstance(msg, DecodedMessage):
            self.stats["skipped_diag_record"] += 1
            return
        mapping = msg.gsmtap
        if mapping is None:
            self.stats["skipped_no_gsmtap"] += 1
            return
        self.sender.send(mapping[0], mapping[1], msg.payload, msg.arfcn, msg.direction == "ul",
                         msg.fields.get("sfn", 0), msg.fields.get("subfn", 0))
        self.stats["packets"] += 1

    def close(self) -> None:
        self.sender.close()


class WiresharkLiveSink(Sink):
    """Pipe the pcapng stream into a freshly started Wireshark (all RATs).
    Wireshark reads a capture from stdin with `-k -i -`, on every platform."""

    def __init__(self, wireshark: str, extra_args: Optional[list] = None):
        super().__init__()
        cmd = [wireshark, "-k", "-i", "-"] + list(extra_args or [])
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        self.inner = PcapngSink(self.proc.stdin, comment="FieldTap live view")
        self.alive = True

    def write(self, msg: DecodedMessage) -> None:
        if not self.alive:
            self.stats["dropped_after_exit"] += 1
            return
        try:
            self.inner.write(msg)
            self.inner.flush()
            self.stats["packets"] += 1
        except (BrokenPipeError, OSError):
            self.alive = False
            self.stats["wireshark_closed"] += 1

    def close(self) -> None:
        try:
            if self.alive:
                self.proc.stdin.close()
        except OSError:
            pass


class MultiSink(Sink):
    def __init__(self, sinks: list):
        super().__init__()
        self.sinks = list(sinks)

    def write(self, msg: DecodedMessage) -> None:
        for sink in self.sinks:
            sink.write(msg)
        self.stats["packets"] += 1

    def flush(self) -> None:
        for sink in self.sinks:
            sink.flush()

    def close(self) -> None:
        for sink in self.sinks:
            try:
                sink.close()
            except Exception:
                pass

    def report(self) -> dict:
        return {type(s).__name__: dict(s.stats) for s in self.sinks}
