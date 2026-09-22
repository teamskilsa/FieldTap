"""Log record -> RRC/NAS payload with the channel Wireshark needs.

FieldTap does not decode ASN.1. It strips the Qualcomm log-record wrapper,
works out which logical channel the message belongs to, and hands the bytes
to Wireshark's own nr-rrc / lte-rrc / nas-5gs / nas-eps dissectors. The hard
part, and the part these modules are built around, is that the wrapper layout
changes with the record's packet version across modem generations.
"""

from .records import CellInfo, DecodedMessage, Decoder, DiagRecord  # noqa: F401
