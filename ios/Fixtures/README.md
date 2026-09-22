# Fixtures

## local/ (git-ignored, never committed)

Everything derived from the user's iPhone capture: the recovered `iphone-recovered.qmdl`, the contract goldens
made from it, the QDSS chunk windows, the Python and PHY reference extractors with their outputs, the
Baseband profile stub and the trace metadata from the sysdiagnose, and copies of the design documents. The
goldens are scrubbed (identifiers, IPs, cell identity and PDU bytes masked or omitted), but PCI, EARFCN, band,
TAC and PLMN remain, and the qmdl and chunks carry subscriber and handset identifiers, so the whole folder
follows `captures/README.md`: it lives on this Mac only. `ios/.gitignore` ignores it and
`ios/scripts/privacy-gate.sh` fails if anything under it would be committed.

Rebuild and check it with:

```sh
source ios/scripts/env.sh
ios/scripts/fixtures.sh            # copy from the research scratch and the sysdiagnose, write MANIFEST.json
ios/scripts/fixtures.sh --verify   # re-check every md5 (and the pinned ones, e.g. iphone-recovered.qmdl e53a167b...)
```

The research scratch in /private/tmp can vanish on reboot; once copied, `--verify` needs only this folder.
`MANIFEST.json` lists every file with its md5 and size. The contents and their key counts are in
`ios/Contract/CONTRACT.md` (Fixture inventory).

| Folder | What |
| --- | --- |
| `iphone-recovered.qmdl`, `qdss-full-stats.json` | the capture the Python deframer rebuilt from all 130 QDSS chunks, and its stats |
| `contract/` | the v1 goldens: call flow (4), presentation, PHY (golden + summary), journey expectation |
| `qdss-first3/`, `qdss-attach4/` | chunk windows with the Python outputs, for the Swift deframer's md5 parity |
| `reference/` | `qdss_deframe.py`, the v30 decoder, timeline and pcapng exports, `iphone-recovered.tsv` |
| `reference-phy/` | `kpis.py` and the decoders it uses, `kpis.json`, `summary.json`, `inventory.tsv`; `load.py` reads its paths from `FT_PHY_QMDL` / `FT_PHY_TSV` or this folder. `refs/` holds third-party references (srsRAN AGPL-3.0, SCAT GPL, MobileInsight Apache-2.0): facts only, never copied into FieldTap |
| `oneplus/` | the Android test captures |
| `profile/` | the com.apple.basebandlogging profile stub only (the archive's other stub is unrelated) |
| `baseband-meta/` | archive and trace directory names, ambtool_output.log, info.txt, trace.info |
| `design/` | design.json, critique.json, research.json of the iOS plan |

## synthetic/ (committed)

Identifier-free inputs made by hand or by code. See `synthetic/README.md`.
