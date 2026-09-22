# Harness expectations (committed)

What `scripts/sim-verify.sh` checks the simulator run against (WP7). These files hold counts, kinds, ids and
flags only. They carry no identifier, no decoded field value and nothing that would locate the phone, so
they may be committed. The capture-derived inputs they were computed from stay in the git-ignored
`Fixtures/local`.

| File | Checked against |
| --- | --- |
| `sim-scan.json` | `scan.json` from `-FTScanOnly`: the archive route (135 Baseband files, 130 chunks, adler32 a0e39d83) |
| `sim-analysis.json` | `analysis.json` from the FT_FEED_PATH import: capture, call flow, PHY, journey |
| `sim-screens.json` | the 18 shots: launch arguments and the screen-report values each must show |

The comparison rules and operators (`$exact`, `$approx`, `$contains`...) are in `scripts/check_sim_analysis.py`.
Where each number comes from, and how to refresh the PHY counts after WP4 regenerates `phy-golden.json`,
is in `scripts/HARNESS.md`.
