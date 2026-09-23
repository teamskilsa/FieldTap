# What a FieldTap pcap holds, and how completely it is decoded

Until 2026-09-22 a FieldTap pcapng held the RRC and NAS messages and nothing else. Every
other record the modem logged (cell identity, measurements, MAC and PHY reports, state
logs, and any code without a known layout) was counted and dropped before the file was
written, so a capture opened in Wireshark showed the call flow and no more.

Now **every log record in the capture is in the pcapng**:

| What the modem logged | How it appears in Wireshark |
| --- | --- |
| RRC OTA messages (`0xB0C0` LTE, `0xB821` NR) | Native `lte-rrc.*` / `nr-rrc.*` PDUs, dissected by stock Wireshark |
| NAS messages (`0xB0Ex`, `0xB80x`) | Native `nas-eps` / `nas-5gs` PDUs |
| LTE MAC transport blocks (`0xB063`, `0xB064`) | `mac-lte-framed` frames: Wireshark runs its own MAC → RLC → PDCP decode on the logged MAC sub-headers, plus a `fieldtap-diag` frame with the sample fields |
| Everything else, known or unknown | `fieldtap-diag` frames: the record, byte for byte, behind an 18-byte header (log code, modem timestamp, flags) |

The bytes are in the file whether or not the FieldTap plugin is installed. With the
plugin, Wireshark shows each record's code, name, modem time and, for the layouts
FieldTap knows, its fields. The packet comment carries the headline fields too, so the
packet list reads without the plugin.

`fieldtap decode capture.qmdl` prints a **coverage table**: every log code in the
capture, how many records, and what each became (`message`, `cell`, `fields`,
`partial`, `raw`). Nothing is silently lost: a code with no layout shows as `raw`.

## The Wireshark plugin

Three Lua files in `wireshark/`:

- `fieldtap.lua`: the `fieldtap-diag` frame, the log-code names (rendered from the
  decoder's register by `python -m fieldtap.wireshark_plugin`; a test fails when stale).
- `fieldtap_lte.lua`, `fieldtap_nr.lua`: the per-code field decoders, mirroring the
  Python decoders. A tshark test checks both read the same fields from the same bytes.

Install: copy all three into Wireshark's personal plugins folder (Help › About Wireshark
› Folders › Personal Lua Plugins), restart Wireshark. For tshark:
`tshark -X lua_script:fieldtap.lua -X lua_script:fieldtap_lte.lua -X lua_script:fieldtap_nr.lua -r capture.pcapng`.

Filter on `fieldtap-diag`, `fieldtap.code == 0xb193`, `fieldtap.lte.rsrp < -100`, and so on.

## Capture profiles

The phone's own logger and the laptop tool both take a profile. The mask decides what
the modem writes; the decoder can only decode what was captured.

| Profile | Adds | Size |
| --- | --- | --- |
| `signalling` (default) | RRC, NAS, cell identity | small |
| `engineering` | serving and neighbour measurements, PHY reports, MAC RACH, state logs, PLMN search | moderate |
| `l2` | every MAC transport block (per-TTI throughput, sub-headers for Wireshark's MAC/RLC/PDCP decode) | large |

Laptop: `fieldtap capture --profile engineering ...`. Phone: Settings › Capture profile.

## Per-code coverage

Status is what `fieldtap decode` reports for the version (`message`, `cell`, `fields`,
`partial`); the table it prints for a capture is the ground truth for that file.

### LTE

The iPhone 17 (Qualcomm M25) logs record versions the documentation does not have. Their
layouts were derived and validated by this repository's TypeScript engine
(`web/engine/src/phy/decoders/*.ts`; the evidence is in `docs/research/iphone-named-log-codes.md`
and `iphone-unknown-log-codes.md`) on the captures of 2026-09-21/22 and ported field for field
into `fieldtap/decode/lte_ml1.py`, `lte_phy.py`, `lte_mac.py`, `lte_ll1.py` and `rf.py`, each
mirrored in `wireshark/fieldtap_lte.lua`. `tests/test_decode_real_iphone.py` replays a capture
named by `FT_REAL_QMDL` and checks the decoded share and the plausibility of every value.
"Documentation" means MobileInsight's Apache-licensed tables, not a capture off this project's
own phones.

| Code | Name | Versions decoded | Status | Confidence | Validated on |
| --- | --- | --- | --- | --- | --- |
| `0xB0C0` | LTE RRC OTA Packet | header table incl. v30 | message | high | iPhone 17 (v30) and the OnePlus corpus |
| `0xB0C1` | LTE RRC MIB Message Log Packet | 1, 2, 3, 17 | cell | high | v2: iPhone 17, 2026-09-21/22 (PCI 80/235, EARFCN 650/5110/67086, 4 Tx antennas, 50 PRB) |
| `0xB0C2` | LTE RRC Serving Cell Info Log Packet | 2, 3 | cell | medium | v3: iPhone 17, 2026-09-21/22 (bands 12/2/66, TAC and UL EARFCN consistent with 0xB062) |
| `0xB0Ex` | LTE NAS EMM/ESM | plain and security-protected | message | high/medium | iPhone 17 and the OnePlus corpus |
| `0xB062` | LTE MAC RACH Attempt | v1 / subpacket 0x06 v50 | fields | high | iPhone 17, 2026-09-21 (3 attempts, none in the second capture; UL EARFCN 132622/23110 = the serving cell's, preamble target -110/-118 dBm = SIB2's, TA 13-18) |
| `0xB063` | LTE MAC DL Transport Block | v1 subpackets (sample v2, v4); v50 walk | fields | high | v50: iPhone 17, 2026-09-21/22 (129 + 9 records, 2,521 blocks; 99.0% / 99.9% match an 0xB173 block on SFN, subframe, carrier, HARQ and size; the walk closes on 72 of 129 records and reaches about 80% of the declared blocks, reported in the note) |
| `0xB064` | LTE MAC UL Transport Block | v1 subpackets (sample v1, v2, v3, v5, v7, v8) | fields | high | v7: iPhone 17, 2026-09-21/22 (262 + 44 records, 4,537 samples, all header-consistent; 442 PHR control elements) |
| `0xB126` | LTE LL1 PDSCH Demapper Configuration | 163 | fields | high | iPhone 17, 2026-09-21/22 (118 + 4 records; PRB bitmap popcount = 0xB173's N_RB in 99.5% / 99.7%, rank = 0xB173's layers, Tx antenna ports = the MIB's; Rx antennas agree with 0xB193 in 88% / 93% only) |
| `0xB12A` | LTE LL1 PCFICH Decoding Results | 161 | fields | high | iPhone 17, 2026-09-21/22 (1,334 + 453 records; the CFI/decode-flag identity holds in every one of the 20 elements of every record) |
| `0xB139` | LTE PHY PUSCH Tx Report | 23, 24, 26 (documentation); 162 | fields | medium | v162: iPhone 17, 2026-09-21/22 (1,381 + 194 records, 5,365 grants; TTI 0..10239, nRB 1..50, required power 8.5..46.5 dBm before Pcmax capping, calibrated against 442 PHRs to about 1.5 dB) |
| `0xB14D` | LTE PHY PUCCH CSF | 164 | fields | medium | iPhone 17, 2026-09-21/22 (1,103 + 204 records; report types 2 and 3; CQI/PMI/RI positions re-derived, agree with 0xB14E) |
| `0xB14E` | LTE PHY PUSCH CSF | 164 | fields | high | iPhone 17, 2026-09-21/22 (1,770 + 101 records; Tx mode 4 = the RRC's tm4, RI against 0xB173) |
| `0xB16C` | LTE ML1 DCI Information Report | 50 | fields | high | iPhone 17, 2026-09-21/22 (318 + 27 records; the element chain closes on every record; the uplink grant's start RB, nRB and modulation code equal 0xB139's four subframes later on 4,212 matched grants; downlink assignments counted only) |
| `0xB173` | LTE PDSCH Stat Indication | 5, 16, 24, 32, 36 (documentation); 50 | fields | high | v50: iPhone 17, 2026-09-21/22 (151 + 19 records, 3,326 TBs; every TBS is a TS 36.213 size, Qm in {2,4,6,8}, 99% match 0xB063) |
| `0xB179` | LTE ML1 Connected Mode LTE Intra-Freq Meas Results | 3, 4 (documentation); 56 | fields | high | v56: iPhone 17, 2026-09-21/22 (369 of 373 and 115 of 116 records read; body = 28 + 12 x neighbours is the framing; serving RSRP -125..-98 dBm within 1 dB of 0xB193's; no DIAG timestamp, the in-record TTI is the clock) |
| `0xB17F` | LTE ML1 Serving Cell Meas and Eval | 4, 5 header | partial | low | one v5 record on the iPhone 17 reads PCI 80 / EARFCN 67086 / RSRP -112.7 dBm, consistent with 0xB193 |
| `0xB180` | LTE ML1 Idle Neighbor Meas Results | 4, 5 header | partial | low | documentation only |
| `0xB193` | LTE ML1 Serving Cell Measurement Result | subpacket 0x19 v4-40 (documentation); v66 | fields | high | v66: iPhone 17, 2026-09-21/22 (1,945 + 726 records, 2,420 cells; PCI 80/235, RSRP -126..-93 dBm, RSRQ, RSSI per Rx and combined with an Rx map; no SNR on this version; 0xB179 agrees within 1 dB) |
| `0x184C` | LTE RF FED Tx AGC | 0x11 | fields | high | iPhone 17, 2026-09-21/22 (4,465 + 511 records; the block walk closes on all but one; per-chain front-end Tx power, PA gain state and limits; the block counter is not the cell's SFN) |
| `0x1D0B` | Modem 100 Hz sampler | 7 | fields | medium | iPhone 17, 2026-09-21/22 (2,238 + 633 records; 1024 Hz sleep-clock and 19.2 MHz counters, sequence +1 on 99.7%; the 2 ms entries are not identified) |

Codes the register names but does not decode (`0xB061`, `0xB16B`, `0xB195`, the PLMN search
and NAS state logs) are captured raw. `0xB126`, `0xB12A`, `0xB16C`, `0x184C` and `0x1D0B` sit in
category "other", outside the phone-side capture profiles, so the committed mask files stay what
the Android app builds; the QDSS trace of the iPhone carries them regardless.

### NR

The iPhone 17 (Qualcomm M25) logs newer record versions than the documented ones. Their
layouts were derived and validated by this repository's TypeScript engine
(`web/engine/src/phy/decoders/nr.ts`) on the captures of 2026-09-21/22 and ported field for
field into `fieldtap/decode/nr_*.py`; `tests/test_decode_nr_real.py` re-runs the checks on a
capture named by `FT_REAL_QMDL`. Status is what `fieldtap decode` reports for the version.

| Code | Name | Versions decoded | Status | Confidence | Validated on |
| --- | --- | --- | --- | --- | --- |
| `0xB821` | NR RRC OTA Packet | header self-validated | message | medium | iPhone 17 (v26) |
| `0xB822` | NR RRC MIB Info | 2.0, 0.3 | cell | medium | documentation only |
| `0xB823` | NR RRC Serving Cell Info | 0.4, 3.0, 3.2, 3.3 | cell | medium | documentation only |
| `0xB80C` | NR NAS MM5G State | 1, 3.0 | fields | medium | 3.0: iPhone 17, 2026-09-21 (one record; PLMN cross-checked; 5G-TMSI never reported) |
| `0xB975` | NR ML1 Serving Cell Beam Management | 2.1 | fields | medium | documentation only |
| `0xB97F` | NR ML1 Searcher Measurement DB Update Ext | 2.6, 2.7, 3.0 (2.9, 2.10 header and cells) | fields | high | 3.0: iPhone 17, 2026-09-21/22 (26 records; PCI 80, n5, SS-RSRP -108 to -102 dBm; beams counted, not read) |
| `0xB887` | NR MAC PDSCH Info | 3.13 | fields | high | iPhone 17, 2026-09-21/22 (179 records, 497 slots; TBS against TS 38.214, sums against 0xB888) |
| `0xB888` | NR MAC PDSCH Stats | 2.2, 3.1 | fields | high | 3.1: iPhone 17, 2026-09-21/22 (602 records; pass + fail = decodes, pass + fail bytes = TB bytes in all) |
| `0xB883` | NR MAC UL Physical Channel Schedule Report | 2.11 header and first slot; 3.26 version only | partial | low | 3.26 not implemented (iPhone 17: 633 records, payload failed every identity check) |
| `0xB872` | NR L2 UL Transport Block | 4; 3.17 version only | fields / partial | low | 3.17 not implemented (iPhone 17: 66 records) |

The second capture on this PC (2026.09.22_08-57-25) holds no NR records at all, so the NR
rows were validated on 2026.09.21_15-41-47 alone; the n77 figures in the TypeScript notes
come from the engine's own copy of the second capture.

## Confirming layouts on hardware

The measurement, MAC and PHY layouts come from documentation (Apache-licensed
MobileInsight tables, restated in `docs/research/qualcomm-measurement-log-layouts.md`),
not from a capture off this project's own phones. Each decoder self-checks (record
sizes, counts, plausible ranges) and marks a record `partial` rather than emit a number
it cannot vouch for, but a real capture is what confirms them. To do that:

1. On the phone: Settings › Capture profile › Engineering (or Full L2), then record a
   capture that includes a connected-mode session (a download test is enough).
2. Export the capture (the `.qmdl`) and decode it on a laptop:
   `fieldtap decode capture.qmdl`.
3. Compare the decoded RSRP/RSRQ/SINR against the app's own Android readings for the
   same minute and against any `MeasurementReport` in the call flow; check PCI, EARFCN
   and TAC in the cell records against the serving cell. Values that disagree point at
   a layout version this project has not seen; keep the `.qmdl`.

## Licensing

Clean room: no code from GPL projects. Layout facts (field order, widths, scaling) were
taken from MobileInsight (Apache License 2.0) and from this repository's own research
document; the decoders are written independently. See `docs/LICENSING.md`.
