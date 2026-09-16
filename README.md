# FieldTap

Turn a commercial Android handset into a real-UE network probe: pull RRC/NAS off the
Qualcomm diag port, decode it, and land it in Wireshark as clean GSMTAP.

FieldTap is the real-network counterpart to the Simnovus simulator line. UESIM, ORUSIM
and RuSIM simulate a UE in the lab. FieldTap taps a real one in the field.

> **Status: pre-alpha. First capture and decode off a real handset on 2026-09-14.**
> The `fieldtap` package speaks diag itself and imports nothing from QCSuper or SCAT.
> It decodes LTE and NR RRC/NAS log records and writes pcapng that stock Wireshark
> dissects. On a rooted OnePlus 10 Pro (SM8450) it took 4,416 log records in 40 s
> with no CRC errors, and Wireshark read the LTE RRC out of them as SIB1, SIB2-5,
> SIB24 and Paging. That run also found the first real layout bug: packet version 27
> of `0xB0C0` has a header three bytes longer than the synthetic corpus taught us
> ([`docs/DEVICE-SETUP.md`](docs/DEVICE-SETUP.md)).
>
> One handset, idle, no SIM: everything seen so far is broadcast and paging. No
> registration, no handover and no call flow has been decoded off the air yet, and
> the remaining header layout tables are still verified only against the synthetic
> corpus. Read [`docs/ROADMAP.md`](docs/ROADMAP.md) for what has to happen next, and
> [`docs/LICENSING.md`](docs/LICENSING.md) for the decision that still gates the
> business model.

## Quick start

    pip install -e ".[all]"
    fieldtap setup --install-adb       # check Wireshark, adb, drivers; fetch what is missing
    fieldtap demo                      # a simulated drive test end to end, no handset needed
    fieldtap auto                      # then plug a phone in

`fieldtap auto` is the product: it watches USB, and for every handset that appears it
enables the diag port, configures the log mask, captures, tags with GPS, optionally runs
ping and download tests on the phone, and writes a report when the phone is unplugged.
Several phones can be connected at once; each gets its own session and report. On
Windows, `FieldTap-Auto.cmd` does the same thing by double-click.

    fieldtap auto --profile all --traffic ping,download --live

Each session lands in `captures/<timestamp>_<name>/`:

| File | What it is |
| --- | --- |
| `capture.qmdl` | the raw diag stream, exactly as the modem sent it |
| `capture.pcapng` | decoded RRC/NAS, opens in stock Wireshark |
| `report.html` | the session report: KPIs, events, route map, call flow |
| `summary.json` | the same numbers for machines |
| `events.csv` | procedures and failures with 3GPP causes |
| `kpi.csv` | RSRP/RSRQ/SINR timeline, GPS-tagged |
| `track.csv`, `traffic.csv`, `cells.csv` | route, active tests, serving cells |

Single-shot commands still exist: `capture`, `decode`, `info`, `flow`, `kpi`, `events`,
`report`, `sessions`, `logcodes`, `selftest`. `device/` holds the root helper for the adb
transport; it needs the Android NDK and is untested on hardware.

## Where the project actually stands

As of the last field session (Nov 2025, OnePlus on T-Mobile), the working pipeline was:

    OnePlus handset -> Qualcomm diag port -> QCSuper -> pcap -> Wireshark + Lua dissector

Every component in that chain is third-party. Specifically:

| Component | Origin | Consequence |
| --- | --- | --- |
| QCSuper | [P1sec/QCSuper](https://github.com/P1sec/QCSuper), **GPLv3** | Copyleft. Gates the product's license model — see `docs/LICENSING.md`. |
| SCAT | [fgsect/scat](https://github.com/fgsect/scat), **GPL-2.0-or-later** | Alternative capture backend, same copyleft question. |
| `diag_nr_rrc_dissector.lua` | Ships **inside QCSuper** | Not original work. Covered by QCSuper's GPLv3. |
| `cots_nr_dissector.lua` | Commercial trial, `makemytechnology.com` | **Expired, compiled bytecode, not redistributable.** Currently the only NR decode path — and it no longer runs. |

The honest summary: until Sep 2026 FieldTap was a workflow assembled from other people's
tools, one of which stopped working because its trial ran out. The `fieldtap` package
replaces the capture and decode parts with our own code. What remains is proving that
code on real handsets, which is what the roadmap is about.

## What is deliberately not in this repository

* **Capture files.** The Nov 2025 pcaps contain live commercial network signalling with
  real subscriber and cell identifiers. See [`captures/README.md`](captures/README.md).
* **The expired commercial dissector.** Redistributing licensed third-party bytecode is a
  violation regardless of repo visibility.
* **SCAT.** Pinned as an external dependency, not vendored. See [`tools/README.md`](tools/README.md).

QCSuper **is** vendored, at [`third_party/qcsuper/`](third_party/) — unmodified, GPLv3,
commit `f5f1501`. That means this repository now contains GPLv3 source, which is lawful
but has consequences for the licence model; [`third_party/README.md`](third_party/README.md)
explains what changed and Roadmap task 0.1 is now more urgent, not less.

## Documentation

| Document | What it covers |
| --- | --- |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Phased plan from here to a shippable product |
| [`docs/LICENSING.md`](docs/LICENSING.md) | The GPL problem and the four ways out |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Target design and the decode pipeline |
| [`docs/COMPETITIVE-LANDSCAPE.md`](docs/COMPETITIVE-LANDSCAPE.md) | XCAL-Mobile, NSG, QualiPoc and where FieldTap fits |
| [`docs/DEVICE-SETUP.md`](docs/DEVICE-SETUP.md) | Getting a handset and this laptop ready |
| [`docs/MACOS.md`](docs/MACOS.md) | Testing on a MacBook, where no driver is needed |
| [`docs/CAPTURE-OPTIONS.md`](docs/CAPTURE-OPTIONS.md) | What hardware can actually capture frames, and what to buy |
| [`docs/UI-PLAN.md`](docs/UI-PLAN.md) | The local web UI plan |
| [`docs/APP-AND-CLOUD-PLAN.md`](docs/APP-AND-CLOUD-PLAN.md) | Accounts and upload, the market gap, and the redaction rule that gates it |
| [`docs/APP-PLAN.md`](docs/APP-PLAN.md) | The Android app: what it measures, how it is built, and what it cannot do |
| [`docs/research/`](docs/research/) | Competitor analysis, Windows/diag mechanics, Qualcomm log layouts |
| [`captures/README.md`](captures/README.md) | Capture handling policy and how to reproduce |
| [`third_party/README.md`](third_party/README.md) | Vendored QCSuper: provenance, and what it changed about the licence |
| [`tools/README.md`](tools/README.md) | External dependency setup |
