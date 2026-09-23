Synthetic, identifier-free test inputs for FTSecurityTests, read through Bundle.module.

golden/*.security.json are copied verbatim from web/engine/tests/security/golden (the browser engine's
committed SecurityReport goldens, ruleset fieldtap-security/1). They are invented data (reserved test PLMN,
invented PCIs/EARFCNs) and carry nothing capture-derived. The Swift detector must reproduce them byte for byte.
