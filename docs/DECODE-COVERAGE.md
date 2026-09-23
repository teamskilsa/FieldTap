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

_(Filled in when the LTE and NR decoders land; see the table `fieldtap decode` prints.)_

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
