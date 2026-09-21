# oneplus-5g-registration.qmdl

Eighteen log records from a real capture, re-framed one per HDLC frame: a 5G standalone registration
attempt on a commercial network, plus two paging records and two LTE cell-identity records.

- Phone: OnePlus 10 Pro (SM8450), `diag_mdlog` with FieldTap's own signalling mask.
- Network: a commercial n77 cell, PLMN 311-480, PCI 417, NR-ARFCN 647328, TAC 360102.
- Taken 2026-09-17 with the lab test SIM (IMSI 001010123456789), which this network refuses.

**Why this file exists.** `fieldtap/decode/nr_rrc.py` maps packet version 17 to a 20-byte header; this
modem writes 27 bytes, so every NR record in a real capture decoded as "unmapped PDU type". The Kotlin
decoder picks the layout by the trailing length field instead, and these records are the proof.

What Wireshark (4.x) reads in it, used as ground truth by `NrRrcTest`:

| # | Message | Fields |
|---|---|---|
| 2 | NR MIB | on PCI 417, NR-ARFCN 647328 |
| 3 | NR SIB1 | PLMN 311-480, TAC 360102, cellIdentity 2167f401a0, band n77 |
| 7 | RRCSetupRequest | ue-Identity randomValue 0fe8e748c4, establishmentCause mo-Signalling |
| 8 | RRCSetup | |
| 9 | RRCSetupComplete | selectedPLMN-Identity 1, dedicatedNAS-Message `7e004179000d0100f110f0ff000010325476982e04f070f070` — Registration request, initial registration, follow-on pending, KSI 7, SUCI 001-01 MSIN 0123456789 |
| 10 | DLInformationTransfer | dedicatedNAS-Message `7e00441b16012c` — Registration reject, 5GMM cause 27 "N1 mode not allowed", T3502 12 min |
| 13 | RRCRelease | no IEs at all |
| 15, 16 | Paging | one record, ng-5G-S-TMSI 400cc6e89880 |

Records 6 (0xB80B) and 11 (0xB80A) are the plain copies of the registration request and reject, logged
alongside the RRC messages that carried them; the call flow keeps these and folds the carried copies in.
Records 1, 4, 5, 12 and 14 are NR state logs (0xB80C, 0xB80D, 0xB822, 0xB823) that hold no PDU. Record 17
is the LTE serving-cell record of the lab callbox (PLMN 001-01, PCI 8, B20, eNB 107216, TAC 1), record 18
an LTE MIB.

Two constructed PDUs, decoded by Wireshark, cover what this capture does not hold:
`1020` (RRCRelease with suspendConfig) and `0860` (RRCReject, waitTime 4 s).
