# Synthetic fixtures

Inputs that contain no real identifiers and can be committed: hand-made records, archives and states for unit
tests and screenshots. Anything taken from a real capture, even a single record, belongs in the git-ignored
`../local/` instead.

Rules, all checked by `ios/scripts/privacy-gate.sh`:

- no runs of 10 or more digits, no IPv4 or IPv6 addresses, no 0x-hex of 8 or more digits (build such values at
  run time in the test, as `FTModelTests/RedactionTests.swift` does);
- no `.qmdl`, `.bin`, `.stub`, `.tar.gz` or `.pcap(ng)` files: tests build small archives and records in
  memory (see `FTCoreTests/SysdiagScannerTests.swift` and `FTCoreTests/ProtocolTests.swift`);
- test PLMN 001-01 and made-up cells only.

Test targets that want a file bundled put it in their own `Tests/<Target>Tests/TestData/` and read it through
`Bundle.module`; this folder is for inputs shared across packages or used by the app's screenshots.
