#!/bin/zsh
# Runs the FieldTapKit tests, on macOS (default) or on the $FT_SIM_NAME simulator (--sim).
#
#   test-kit.sh [--release] [--sim] [--filter REGEX] [--allow-skips]
#
# macOS: swift test in a build slot, scratch in $FT_TMP/spm; --release adds -c release -Xswiftc -enable-testing.
# --sim: build-for-testing in a build slot, then test-without-building under the simulator lock, run from the
#        package root with the package's own scheme (the app scheme cannot run package tests), DerivedData in
#        $FT_TMP/dd-kit. REGEX 'FTModelTests|FTCoreTests' becomes -only-testing:FTModelTests -only-testing:
#        FTCoreTests; for 'Target.*name' only the target part is used there.
# Both export FT_FIXTURES, FT_SYSDIAGNOSE and FT_REQUIRE_FIXTURES=1 (TEST_RUNNER_* for the simulator, which
# strips the prefix), so a missing fixture fails instead of skipping. The result is counted from the xunit XML
# (macOS) or the xcresult (simulator) and the script fails when anything failed or, unless --allow-skips, when
# anything was skipped.
set -euo pipefail
HERE=${0:A:h}
source "$HERE/env.sh"
RELEASE=0; SIM=0; FILTER=""; ALLOW_SKIPS=0
while (( $# > 0 )); do
  case $1 in
    --release) RELEASE=1; shift ;;
    --sim) SIM=1; shift ;;
    --filter) FILTER=$2; shift 2 ;;
    --allow-skips) ALLOW_SKIPS=1; shift ;;
    *) echo "usage: $0 [--release] [--sim] [--filter REGEX] [--allow-skips]" >&2; exit 2 ;;
  esac
done
export FT_FIXTURES FT_SYSDIAGNOSE
export FT_REQUIRE_FIXTURES=${FT_REQUIRE_FIXTURES:-1}
mkdir -p "$FT_TMP"
PKG="$FT_IOS/FieldTapKit"
STAMP=$(date +%H%M%S)

if (( ! SIM )); then
  typeset -a CMD
  CMD=(swift test --package-path "$PKG" --scratch-path "$FT_TMP/spm" --xunit-output "$FT_TMP/xunit-$STAMP.xml")
  (( RELEASE )) && CMD+=(-c release -Xswiftc -enable-testing)
  [[ -n "$FILTER" ]] && CMD+=(--filter "$FILTER")
  LOG="$FT_TMP/test-kit-$STAMP.log"
  set +e
  "$HERE/with-build-slot.sh" "${CMD[@]}" > "$LOG" 2>&1
  rc=$?
  set -e
  grep -E '✘|error:|Test run with|recorded an issue' "$LOG" | head -60 || true
  python3 - "$FT_TMP" "$STAMP" "$ALLOW_SKIPS" "$rc" <<'PY'
import glob, os, sys
import xml.etree.ElementTree as ET
tmp, stamp, allow_skips, rc = sys.argv[1], sys.argv[2], sys.argv[3] == '1', int(sys.argv[4])
total = failed = skipped = 0
names = []
for path in glob.glob(os.path.join(tmp, f'xunit-{stamp}*.xml')):
    for case in ET.parse(path).getroot().iter('testcase'):
        total += 1
        if case.find('failure') is not None or case.find('error') is not None:
            failed += 1; names.append('FAILED ' + case.get('classname', '') + '.' + case.get('name', ''))
        elif case.find('skipped') is not None:
            skipped += 1; names.append('SKIPPED ' + case.get('classname', '') + '.' + case.get('name', ''))
for n in names[:40]:
    print(n)
print(f'test-kit: {total} tests, {total - failed - skipped} passed, {failed} failed, {skipped} skipped (swift test exit {rc})')
bad = rc != 0 or failed or total == 0 or (skipped and not allow_skips)
sys.exit(1 if bad else 0)
PY
  exit $?
fi

# --sim
SCHEME=$(cd "$PKG" && xcodebuild -list -json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
schemes = (d.get("workspace") or d.get("project") or {}).get("schemes", [])
pick = [s for s in schemes if s == "FieldTapKit-Package"] or [s for s in schemes if s == "FieldTapKit"] or schemes
print(pick[0] if pick else "")')
[[ -n "$SCHEME" ]] || { echo "test-kit: no package scheme found" >&2; exit 1; }
typeset -a ONLY
if [[ -n "$FILTER" ]]; then
  for part in ${(s:|:)FILTER}; do ONLY+=("-only-testing:${part%%.*}"); done
fi
DEST="platform=iOS Simulator,name=$FT_SIM_NAME"
RESULT="$FT_TMP/kit-$STAMP.xcresult"
LOG="$FT_TMP/test-kit-sim-$STAMP.log"
echo "test-kit: scheme $SCHEME on '$FT_SIM_NAME' ${ONLY[*]:-(all targets)}" >&2
set +e
(cd "$PKG" && "$HERE/with-build-slot.sh" xcodebuild build-for-testing -scheme "$SCHEME" -destination "$DEST" \
  -derivedDataPath "$FT_TMP/dd-kit" ONLY_ACTIVE_ARCH=YES > "$LOG" 2>&1)
rc=$?
if (( rc == 0 )); then
  (cd "$PKG" && TEST_RUNNER_FT_FIXTURES="$FT_FIXTURES" TEST_RUNNER_FT_SYSDIAGNOSE="$FT_SYSDIAGNOSE" \
    TEST_RUNNER_FT_REQUIRE_FIXTURES="$FT_REQUIRE_FIXTURES" \
    "$HERE/with-sim-lock.sh" xcodebuild test-without-building -scheme "$SCHEME" -destination "$DEST" \
    -derivedDataPath "$FT_TMP/dd-kit" -resultBundlePath "$RESULT" -parallel-testing-enabled NO \
    -disable-concurrent-destination-testing "${ONLY[@]}" >> "$LOG" 2>&1)
  rc=$?
fi
set -e
grep -E '✘|error:|\*\* TEST|Test run with|recorded an issue' "$LOG" | head -60 || true
if [[ -d "$RESULT" ]]; then
  xcrun xcresulttool get test-results summary --path "$RESULT" --compact 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
allow, rc = sys.argv[1] == "1", int(sys.argv[2])
p, f, s, t = d.get("passedTests", 0), d.get("failedTests", 0), d.get("skippedTests", 0), d.get("totalTestCount", 0)
res = d.get("result")
print(f"test-kit: {t} tests, {p} passed, {f} failed, {s} skipped on the simulator ({res}, xcodebuild exit {rc})")
sys.exit(1 if rc or f or t == 0 or (s and not allow) else 0)' "$ALLOW_SKIPS" "$rc"
  exit $?
fi
echo "test-kit: no result bundle (xcodebuild exit $rc); see $LOG" >&2
exit $(( rc == 0 ? 1 : rc ))
