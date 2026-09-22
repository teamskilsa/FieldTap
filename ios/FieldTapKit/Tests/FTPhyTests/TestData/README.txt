Synthetic, identifier-free test inputs for FTPhyTests, read through Bundle.module.
Capture-derived fixtures never go here: they live in the git-ignored ios/Fixtures/local (see Fixtures/README.md).

tools/regen_phy_v1.py  rebuilds the v1 PHY contract fixtures (CONTRACT.md, PHY parity: bins keyed by UTC second
                       and carrier index, NR DL earfcn null) into Fixtures/local/contract/phy-golden-v1.json and
                       phy-summary-v1.json, plus the reference TBS oracle reference-phy/lte-tbs-reference.json:
                         python3 regen_phy_v1.py ios/Fixtures/local
tools/gen_lte_tbs.py   writes Sources/FTPhy/LteTbsTable.swift from the 3GPP TS 36.213 .docx (Rel-12 or later):
                         python3 gen_lte_tbs.py 36213-xxx.docx > ios/FieldTapKit/Sources/FTPhy/LteTbsTable.swift
                         python3 gen_lte_tbs.py --self-test
