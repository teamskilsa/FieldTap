#!/bin/zsh
# Copies every capture-derived fixture into the git-ignored ios/Fixtures/local and records md5s in
# local/MANIFEST.json, because the research scratch in /private/tmp can vanish on reboot.
#
#   fixtures.sh            copy (idempotent) and write MANIFEST.json
#   fixtures.sh --verify   re-check every md5 in MANIFEST.json and the pinned md5s below; exit 1 on any mismatch
#
# Nothing here is ever committed: ios/.gitignore ignores Fixtures/local/, and privacy-gate.sh checks it.
set -euo pipefail
source "${0:A:h}/env.sh"

L="$FT_FIXTURES"
SP="$FT_SCRATCH"
MODE=${1:-copy}

# md5s the contract depends on; --verify fails when a copy drifts from these.
typeset -A PINNED
PINNED=(
  iphone-recovered.qmdl                e53a167b29b25560938d1f089e719d33
  reference/qdss_deframe.py            a020cc3fdb9d46e86675ca0cb6bb8b1a
  contract/phy-golden.json             f7096d556831fc8c7de005879557dd57
  contract/phy-summary.json            21711aa5b366360030fed9eb2ccfa3a5
  contract/callflow-golden.json        812920659751853fd251692c0d7b4e98
  contract/presentation-golden.json    4562d3cf8b5c8dc12c7543c71c9d40b0
)

manifest() {
  # Walks local/, hashes every file, and writes MANIFEST.json (sources recorded for the log).
  python3 - "$L" "$SP" <<'PY'
import hashlib, json, os, sys, time
root, sp = sys.argv[1], sys.argv[2]
files = {}
for d, _, names in os.walk(root):
    for n in sorted(names):
        p = os.path.join(d, n)
        rel = os.path.relpath(p, root)
        # shots/ holds each package's screenshots and screen reports: outputs, not fixtures.
        if rel == 'MANIFEST.json' or n == '.DS_Store' or rel.startswith('shots/') or '__pycache__' in rel:
            continue
        h = hashlib.md5()
        with open(p, 'rb') as f:
            for b in iter(lambda: f.read(1 << 20), b''):
                h.update(b)
        files[rel] = {'md5': h.hexdigest(), 'bytes': os.path.getsize(p)}
json.dump({'what': 'Capture-derived FieldTap iOS fixtures. Git-ignored; never commit. Rebuild with ios/scripts/fixtures.sh.',
           'generated': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'scratch': sp,
           'files': dict(sorted(files.items()))},
          open(os.path.join(root, 'MANIFEST.json'), 'w'), indent=1)
print(f'MANIFEST.json: {len(files)} files, {sum(f["bytes"] for f in files.values()) / 1e6:.1f} MB')
PY
}

verify() {
  [[ -f "$L/MANIFEST.json" ]] || { echo "no $L/MANIFEST.json: run fixtures.sh first" >&2; exit 1; }
  local pinned_args=()
  for k v in ${(kv)PINNED}; do pinned_args+=("$k=$v"); done
  python3 - "$L" "${pinned_args[@]}" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
pinned = dict(a.split('=', 1) for a in sys.argv[2:])
m = json.load(open(os.path.join(root, 'MANIFEST.json')))['files']
bad = 0
for rel, want in m.items():
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        print('MISSING', rel); bad += 1; continue
    h = hashlib.md5()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    if h.hexdigest() != want['md5']:
        print('CHANGED', rel, h.hexdigest(), '!=', want['md5']); bad += 1
for rel, md5 in pinned.items():
    got = m.get(rel, {}).get('md5')
    if got != md5:
        print('PINNED', rel, got, '!=', md5); bad += 1
    else:
        print('pinned ok', rel, md5)
print(f'verified {len(m)} files, {bad} problems')
sys.exit(1 if bad else 0)
PY
}

if [[ "$MODE" == "--verify" ]]; then
  verify
  exit $?
fi

[[ -d "$SP" ]] || { echo "research scratch $SP is gone; fixtures can only be verified, not re-copied" >&2; exit 1; }
mkdir -p "$L"/{contract,reference,reference-phy,oneplus,profile,baseband-meta,design}

B="$SP/iphone/wf/build"
PHY="$SP/wf-ios/phy-inventory"
GOLD="$SP/wf-ios/ios-foundation/golden"

cp -p "$SP"/wf-ios/design/contract/fixtures/*.json "$L/contract/"
cp -p "$B/iphone-recovered.qmdl" "$L/"
cp -p "$B/run.json" "$L/qdss-full-stats.json"
for f in qdss_deframe.py ft_decode_v30.py timeline_v30.tsv iphone-recovered-v30.pcapng iphone-recovered.tsv; do
  cp -p "$B/$f" "$L/reference/"
done
for w in qdss-first3 qdss-attach4; do
  rsync -a --delete "$GOLD/$w/" "$L/$w/"
done
for f in kpis.py decoders.py b193.py b173.py b064.py b97f.py b063.py tbs.py nrtbs.py load.py summary.json kpis.json inventory.tsv; do
  cp -p "$PHY/$f" "$L/reference-phy/"
done
# refs/ holds third-party files (srsRAN AGPL, SCAT GPL, MobileInsight Apache): facts-only references for
# tbs.py/nrtbs.py/inventory.py; never copy them into FieldTap code.
rsync -a --delete --exclude __pycache__ "$PHY/refs/" "$L/reference-phy/refs/"
# load.py hard-codes the scratch paths; point it at this folder (FT_PHY_QMDL / FT_PHY_TSV override).
python3 - "$L/reference-phy/load.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("sys.path.insert(0, '/Users/nikhiljain/Projects/fieldTap')",
              "sys.path.insert(0, os.environ.get('FT_REPO', '/Users/nikhiljain/Projects/fieldTap'))")
s = re.sub(r"^QMDL = '.*'$",
           "QMDL = os.environ.get('FT_PHY_QMDL', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'iphone-recovered.qmdl'))",
           s, flags=re.M)
s = re.sub(r"^TSV = '.*'$",
           "TSV = os.environ.get('FT_PHY_TSV', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reference', 'iphone-recovered.tsv'))",
           s, flags=re.M)
assert '/private/tmp' not in s, 'load.py still names the scratch'
open(p, 'w').write(s)
PY
cp -p "$FT_REPO"/android/diag/src/test/resources/*.qmdl "$L/oneplus/"
cp -p "$SP"/wf-ios/{design,critique,research}.json "$L/design/"

# The Baseband profile stub and the trace metadata from the user's sysdiagnose. Only the
# com.apple.basebandlogging stub is kept; the archive's other profile stub is unrelated.
if [[ -f "$FT_SYSDIAGNOSE" ]]; then
  X=$(mktemp -d "${TMPDIR:-/tmp}/ft-fixtures.XXXXXX")
  bsdtar -xzf "$FT_SYSDIAGNOSE" -C "$X" \
    --include '*/logs/MCState/Shared/profile-*.stub' \
    --include '*/logs/Baseband/ambtool_output.log' \
    --include '*/logs/Baseband/log-bb-*-qdss/info.txt' \
    --include '*/logs/Baseband/log-bb-*-qdss/trace.info'
  rm -f "$L"/profile/*.stub(N)
  python3 - "$X" "$L/profile" <<'PY'
import glob, os, plistlib, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
kept = 0
for p in glob.glob(os.path.join(src, '**', 'profile-*.stub'), recursive=True):
    if os.path.basename(p).startswith('._'):
        continue
    try:
        d = plistlib.load(open(p, 'rb'))
    except Exception:
        continue
    if d.get('PayloadIdentifier') == 'com.apple.basebandlogging':
        shutil.copy2(p, os.path.join(dst, os.path.basename(p))); kept += 1
print(f'profile stubs kept: {kept} (com.apple.basebandlogging only)')
PY
  find "$X" -name ambtool_output.log -not -name '._*' -exec cp -p {} "$L/baseband-meta/" \;
  find "$X" -path '*-qdss/*' \( -name info.txt -o -name trace.info \) -not -name '._*' -exec cp -p {} "$L/baseband-meta/" \;
  find "$X" -type d -name 'log-bb-*-qdss' -exec basename {} \; > "$L/baseband-meta/trace-dir-name.txt"
  basename "$FT_SYSDIAGNOSE" > "$L/baseband-meta/archive-name.txt"
  rm -rf "$X"
else
  echo "warning: $FT_SYSDIAGNOSE not found; profile/ and baseband-meta/ left as they were" >&2
fi

manifest
verify
