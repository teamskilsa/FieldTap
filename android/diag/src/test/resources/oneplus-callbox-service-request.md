# oneplus-callbox-service-request.qmdl

The 26 log packets of a real capture, re-framed one per HDLC frame, without the 6.9 MB message
database (`.qdb`) transfer that surrounded them.

- Phone: OnePlus 10 Pro (SM8450), `diag_mdlog` with FieldTap's own signalling mask.
- Network: Simnovus callbox, PLMN 001-01, LTE band 3, PCI 3, EARFCN 1575.
- Taken 2026-09-17 while toggling airplane mode and pinging the PDN gateway.

What Wireshark (4.x) reads in it, used as ground truth by the tests:

| # | Message | Fields |
|---|---|---|
| 1 | NAS Service request | |
| 2 | RRCConnectionRequest | s-TMSI mmec 01, m-TMSI f51a62ad; establishmentCause mo-Data |
| 3–9 | RRCConnectionSetup, SetupComplete, SecurityModeCommand/Complete, RRCConnectionReconfiguration/Complete | |
| 10 | NAS PDN connectivity request | EBI 0, PTI 19, PDN type IPv4v6, request type initial, APN "ims" |
| 16 | NAS Activate default EPS bearer context request | EBI 6, PTI 19, QCI 5, APN ims.mnc001.mcc001.gprs, IPv4v6, 192.168.4.2 |
| 17 | NAS Activate default EPS bearer context accept | |
| 20 | NAS Detach request | switch off, combined EPS/IMSI, GUTI 001-01 MMEGI 32769 MMEC 1 M-TMSI 0xf51a62ad |
| 23 | RRCConnectionRelease | cause other |

Frames 11, 15, 18, 21 are the security-protected copies of neighbouring plain NAS messages. Wireshark reads
frame 11 (copy of 10) as integrity protected and ciphered, MAC 0x053bcb66, sequence number 46, and frame 15
(copy of 16, logged before it and as EMM) as MAC 0xca666570, sequence number 32.

More of frame 16, from its extended PCO: DNS 8.8.8.8 and 2001:4860:4860::8888, P-CSCF 192.168.4.1 and
2001:468:3000:1::. Frame 1's service request: KSI 0, sequence number 13, short MAC 0xda42. Frame 13's
RRCConnectionReconfiguration carries dedicatedInfoNASList and radioResourceConfigDedicated, no mobilityControlInfo.
