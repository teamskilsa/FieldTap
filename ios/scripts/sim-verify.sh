#!/bin/zsh
# End-to-end harness run of FieldTap in the $FT_SIM_NAME simulator (WP7): the user's real sysdiagnose, read in
# place from the Mac, through the app's own importer and analyzer, then every screen, each gated on the values
# its screen report states (not on PNG sizes). Commands, files and formats: ios/scripts/HARNESS.md.
#
#   sim-verify.sh [--stage scan|full|all] [--sysdiagnose PATH] [--shots DIR] [--config Harness|Debug]
#                 [--capture auto|import|fixture] [--only NAME,...] [--timeout SEC]
#                 [--keep-build] [--keep-sim] [--no-build]
#
# scan  Launch with SIMCTL_CHILD_FT_FEED_PATH=<archive> -FTScanOnly; check Documents/ft-debug/scan.json against
#       Fixtures/expected/sim-scan.json (135 Baseband files, 130 chunks, adler32 a0e39d83). Needs no decoder.
# full  Launch with FT_FEED_PATH alone: the importer stores the capture and the Analyzer runs; wait up to
#       --timeout (240 s) for analysis.json and check it against Fixtures/expected/sim-analysis.json. Then, for
#       each shot in Fixtures/expected/sim-screens.json, relaunch (sim-shot.sh) with the shot's arguments after
#       the capture's own and check its screen report. --capture auto (the default) shows the imported capture
#       (-FTOpenLatest) when the import worked, else the -FTFixture capture, so the screens are captured
#       whatever has merged; a failed import still fails the run.
# Then privacy-gate.sh over every output file, uninstall the app, shut the simulator down, delete DerivedData,
# and print the elapsed time and the change in free disk. Exit 0 only when every check passed.
#
# Outputs go to --shots (default $FT_TMP/shots), never inside the repo except under the git-ignored
# Fixtures/local. The archive is only read; its size and modification time are checked again at the end.
set -uo pipefail
source "${0:A:h}/env.sh"
SCRIPTS=${0:A:h}
STAGE=full; SYSDIAG=$FT_SYSDIAGNOSE; SHOTS=""; CONFIG=Harness; CAPTURE=auto; ONLY=""; TIMEOUT=240
KEEP_BUILD=0; KEEP_SIM=0; BUILD=1
ORIG=("$@")
while (( $# > 0 )); do
  case $1 in
    --stage) STAGE=$2; shift 2 ;;
    --sysdiagnose) SYSDIAG=$2; shift 2 ;;
    --shots) SHOTS=$2; shift 2 ;;
    --config) CONFIG=$2; shift 2 ;;
    --capture) CAPTURE=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --keep-build) KEEP_BUILD=1; shift ;;
    --keep-sim) KEEP_SIM=1; shift ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) sed -n '2,24p' "${0:A}"; exit 0 ;;
    *) echo "sim-verify: unknown argument $1" >&2; exit 2 ;;
  esac
done
case $STAGE in scan|full|all) ;; *) echo "sim-verify: --stage scan|full|all" >&2; exit 2 ;; esac
case $CONFIG in Harness|Debug) ;; *) echo "sim-verify: --config Harness|Debug (Release has no hooks)" >&2; exit 2 ;; esac
case $CAPTURE in auto|import|fixture) ;; *) echo "sim-verify: --capture auto|import|fixture" >&2; exit 2 ;; esac
[[ -f "$SYSDIAG" ]] || { echo "sim-verify: no sysdiagnose at $SYSDIAG" >&2; exit 2; }
SYSDIAG=${SYSDIAG:A}
SHOTS=${SHOTS:-$FT_TMP/shots}
mkdir -p "$SHOTS"
SHOTS=${SHOTS:A}
for repo in "$FT_IOS" "$FT_REPO" "$FT_CANONICAL_REPO"; do
  repo=${repo:A}
  if [[ "$SHOTS/" == "$repo/"* && "$SHOTS/" != "$repo/Fixtures/local/"* && "$SHOTS/" != "$repo/ios/Fixtures/local/"* ]]; then
    echo "sim-verify: --shots $SHOTS is inside the repo; use \$FT_TMP or ios/Fixtures/local" >&2; exit 2
  fi
done
EXPECTED="$FT_IOS/Fixtures/expected"
APP="$FT_TMP/dd/Build/Products/$CONFIG-iphonesimulator/FieldTap.app"

# Outside the simulator lock: note the start, build (in a build slot), then re-run this script under the lock.
if [[ "${FT_IN_SIM_LOCK:-}" != 1 ]]; then
  export FT_VERIFY_START=$(date +%s)
  export FT_VERIFY_FREE_KB=$(df -k "$HOME" | awk 'NR==2 {print $4}')
  if (( BUILD )); then
    "$SCRIPTS/build-app.sh" "$CONFIG" > /dev/null || { echo "sim-verify: the $CONFIG build failed" >&2; exit 1; }
  fi
  exec "$SCRIPTS/with-sim-lock.sh" "${0:A}" "${ORIG[@]}" --no-build
fi
: "${FT_VERIFY_START:=$(date +%s)}"
: "${FT_VERIFY_FREE_KB:=$(df -k "$HOME" | awk 'NR==2 {print $4}')}"
[[ -d "$APP" ]] || { echo "sim-verify: $APP not built" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ft-verify.XXXXXX")
typeset -a RESULTS
FAILED=0
note() { print -r -- "sim-verify: $*"; }
result() {   # result NAME ok|FAIL DETAIL
  RESULTS+=("$(printf '%-22s %-4s %s' "$1" "$2" "$3")")
  [[ "$2" == ok ]] || FAILED=1
}
ARCHIVE_STAMP=$(stat -f '%z %m' "$SYSDIAG")

UDID=$("$SCRIPTS/sim-udid.sh") || exit 1
cleanup() {
  xcrun simctl terminate "$UDID" "$FT_BUNDLE_ID" > /dev/null 2>&1
  xcrun simctl uninstall "$UDID" "$FT_BUNDLE_ID" > /dev/null 2>&1 && note "uninstalled $FT_BUNDLE_ID"
  if (( !KEEP_SIM )) && xcrun simctl list devices | grep -q "$UDID) (Booted)"; then
    xcrun simctl shutdown "$UDID" > /dev/null 2>&1 && note "shut the simulator down"
  fi
  if (( !KEEP_BUILD )) && [[ "$FT_TMP" == /private/tmp/fieldtap-build/* ]]; then
    rm -rf "$FT_TMP/dd" && note "deleted $FT_TMP/dd"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

xcrun simctl bootstatus "$UDID" -b > /dev/null || { echo "sim-verify: could not boot $FT_SIM_NAME" >&2; exit 1; }
xcrun simctl uninstall "$UDID" "$FT_BUNDLE_ID" > /dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || { echo "sim-verify: install failed" >&2; exit 1; }
DATA=$(xcrun simctl get_app_container "$UDID" "$FT_BUNDLE_ID" data)
DBG="$DATA/Documents/ft-debug"
note "$CONFIG build on $FT_SIM_NAME ($UDID), archive ${SYSDIAG:t} ($(( $(stat -f %z "$SYSDIAG") / 1048576 )) MiB, read in place)"

json_ok() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2> /dev/null; }

# wait_json FILE SECONDS: until FILE exists and parses; prints the import stage now and then.
wait_json() {
  local file=$1 limit=$2 start=$SECONDS last=0
  while (( SECONDS - start < limit )); do
    json_ok "$file" && return 0
    if (( SECONDS - last >= 15 )) && json_ok "$DBG/import.json"; then
      last=$SECONDS
      python3 - "$DBG/import.json" "$(( SECONDS - start ))" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
e = d.get('events') or [{}]
f = e[-1].get('fraction', 0)
done = f'{round(100 * f)}%' if f >= 0 else '(no fraction)'
print(f"sim-verify:   {sys.argv[2]} s: import {d.get('state')}, stage {e[-1].get('stage', '-')} {done}, "
      f"{d.get('progressEvents', 0)} progress events")
PY
    fi
    sleep 1
  done
  return 1
}

launch_feed() {   # launch_feed [app args...]: a fresh ft-debug, FT_FEED_PATH set, the given arguments
  rm -rf "$DBG"
  env SIMCTL_CHILD_FT_FEED_PATH="$SYSDIAG" xcrun simctl launch --terminate-running-process "$UDID" "$FT_BUNDLE_ID" "$@" > /dev/null
}

check() {   # check NAME ACTUAL EXPECTED: runs the checker, records the result
  local name=$1 out rc
  out=$(python3 "$SCRIPTS/check_sim_analysis.py" "$2" "$3" --label "$name")
  rc=$?
  print -r -- "$out"
  if (( rc == 0 )); then
    result "$name" ok "$(print -r -- "$out" | tail -1 | sed 's/^check_sim_analysis: [^:]*: //')"
  else
    result "$name" FAIL "$(print -r -- "$out" | tail -1 | sed 's/^check_sim_analysis: [^:]*: //')"
  fi
}

# ---- stage scan
if [[ $STAGE == scan || $STAGE == all ]]; then
  rm -f "$SHOTS/scan.json"
  note "scan: -FTScanOnly"
  launch_feed -FTScanOnly
  if wait_json "$DBG/scan.json" 120; then
    cp "$DBG/scan.json" "$SHOTS/scan.json"
    check scan "$SHOTS/scan.json" "$EXPECTED/sim-scan.json"
  else
    result scan FAIL "no scan.json within 120 s"
  fi
  xcrun simctl terminate "$UDID" "$FT_BUNDLE_ID" > /dev/null 2>&1
fi

# ---- stage full
if [[ $STAGE == full || $STAGE == all ]]; then
  rm -f "$SHOTS"/(import|analysis|analysis-fixture).json(N) "$SHOTS"/[0-9][0-9]-*.(png|json)(N)
  SOURCE=fixture
  if [[ $CAPTURE != fixture ]]; then
    note "full: importing through FT_FEED_PATH (timeout ${TIMEOUT} s)"
    launch_feed
    if wait_json "$DBG/analysis.json" "$TIMEOUT"; then
      cp "$DBG/analysis.json" "$SHOTS/analysis.json"
      json_ok "$DBG/import.json" && cp "$DBG/import.json" "$SHOTS/import.json"
      check analysis "$SHOTS/analysis.json" "$EXPECTED/sim-analysis.json"
      # WP4's v1 golden carries the contract's (UTC second, carrier) bins; the WP0-pinned one predates them.
      PHY_GOLDEN="$FT_FIXTURES/contract/phy-golden-v1.json"
      [[ -f "$PHY_GOLDEN" ]] || PHY_GOLDEN="$FT_FIXTURES/contract/phy-golden.json"
      python3 "$SCRIPTS/check_sim_analysis.py" --phy-golden "$PHY_GOLDEN" "$EXPECTED/sim-analysis.json" | tail -1
      if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ok") else 1)' "$SHOTS/analysis.json"; then
        SOURCE=import
        python3 - "$SHOTS/import.json" "$SHOTS/analysis.json" <<'PY'
import json, sys
i, a = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
stages = ', '.join(f'{k} {v:.1f} s' for k, v in i.get('stageSeconds', {}).items())
r = a.get('run', {})
print(f"sim-verify: import {i.get('elapsedS', 0):.1f} s ({stages}); analyzer {r.get('analyzeSeconds') or 0:.1f} s")
PY
      else
        note "the import failed: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error"))' "$SHOTS/analysis.json")"
      fi
    else
      result analysis FAIL "no analysis.json within ${TIMEOUT} s"
    fi
    xcrun simctl terminate "$UDID" "$FT_BUNDLE_ID" > /dev/null 2>&1
  fi
  if [[ $SOURCE == fixture && $CAPTURE == import ]]; then
    note "--capture import and no imported capture: no screenshots"
  else
    if [[ $SOURCE == fixture ]]; then
      note "screens from the -FTFixture capture ($FT_FIXTURES), not an import"
      CAP_PLAIN="-FTFixture $FT_FIXTURES"; CAP_DETAIL="-FTFixture $FT_FIXTURES"
      # The fixture's own analysis, checked against the same expectation for information (not gated).
      rm -rf "$DBG"
      xcrun simctl launch --terminate-running-process "$UDID" "$FT_BUNDLE_ID" -FTFixture "$FT_FIXTURES" -FTDumpAnalysis > /dev/null
      if wait_json "$DBG/analysis-fixture.json" 120; then
        cp "$DBG/analysis-fixture.json" "$SHOTS/analysis-fixture.json"
        python3 "$SCRIPTS/check_sim_analysis.py" "$SHOTS/analysis-fixture.json" "$EXPECTED/sim-analysis.json" \
          --label analysis-fixture --ignore source --ignore run --ignore capture.storedRecords \
          --ignore capture.traceWindowAfterPressMs | tail -1
      fi
      xcrun simctl terminate "$UDID" "$FT_BUNDLE_ID" > /dev/null 2>&1
    else
      CAP_PLAIN=""; CAP_DETAIL="-FTOpenLatest"
    fi

    # The guide's state today, from the profile stub's RemovalDate (as GuideState.from reads it).
    python3 - "$FT_FIXTURES" > "$WORK/tokens.json" <<'PY'
import datetime, glob, json, math, plistlib, sys
removal = None
for path in sorted(glob.glob(sys.argv[1] + '/profile/*.stub')):
    d = plistlib.load(open(path, 'rb'))
    if d.get('PayloadIdentifier') == 'com.apple.basebandlogging':
        removal = d.get('RemovalDate')
if removal is None:
    print(json.dumps({'@guideStatus': 'off', '@needsAttention': True, '@daysLeft': {'$present': False}}))
    sys.exit()
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
left = (removal - now).total_seconds()
status = 'expired' if left <= 0 else 'expiringSoon' if left <= 86400 else 'active'
print(json.dumps({'@guideStatus': status, '@needsAttention': status != 'active',
                  '@daysLeft': 0 if left <= 0 else math.floor(left / 86400)}))
PY
    python3 - "$EXPECTED/sim-screens.json" "$ONLY" > "$WORK/shots.tsv" <<'PY'
import json, sys
only = set(filter(None, sys.argv[2].split(',')))
for n, s in enumerate(json.load(open(sys.argv[1]))['shots'], 1):
    if not only or s['name'] in only:
        print(f"{n:02d}-{s['name']}\t{s['route']}\t{int(s['detail'])}\t{s['args']}")
PY
    while IFS=$'\t' read -r name route detail args; do
      cap=$CAP_PLAIN; (( detail )) && cap=$CAP_DETAIL
      png="$SHOTS/$name.png"
      "$SCRIPTS/sim-shot.sh" --config "$CONFIG" --no-build --args "$cap $args" --wait-screen "$route" \
        --timeout 90 --out "$png" > "$WORK/shot.log" 2>&1 < /dev/null
      rc=$?
      if [[ ! -f "${png:r}.json" ]]; then
        result "$name" FAIL "no ready screen report within 90 s (sim-shot rc $rc)"
        tail -3 "$WORK/shot.log"
        continue
      fi
      python3 - "$EXPECTED/sim-screens.json" "${name#[0-9][0-9]-}" "$WORK/tokens.json" > "$WORK/expect.json" <<'PY'
import json, sys
shot = next(s for s in json.load(open(sys.argv[1]))['shots'] if s['name'] == sys.argv[2])
tokens = json.load(open(sys.argv[3]))
def sub(v):
    if isinstance(v, str) and v in tokens: return tokens[v]
    if isinstance(v, dict): return {k: sub(x) for k, x in v.items()}
    if isinstance(v, list): return [sub(x) for x in v]
    return v
print(json.dumps(sub(shot['expect'])))
PY
      check "$name" "${png:r}.json" "$WORK/expect.json" < /dev/null
      print -r -- "  $(stat -f %z "$png" 2> /dev/null || echo 0) bytes, $png"
    done < "$WORK/shots.tsv"
  fi
fi

# ---- the outputs must not carry an identifier; the archive must be untouched
gate=$("$SCRIPTS/privacy-gate.sh" --scan "$SHOTS" 2>&1); rc=$?
print -r -- "$gate" | tail -5
if (( rc == 0 )); then result privacy-gate ok "$(print -r -- "$gate" | tail -1 | sed 's/^privacy-gate: //')"
else result privacy-gate FAIL "$(print -r -- "$gate" | tail -1 | sed 's/^privacy-gate: //')"; fi
if [[ "$(stat -f '%z %m' "$SYSDIAG" 2> /dev/null)" == "$ARCHIVE_STAMP" ]]; then result archive ok "unchanged (size, mtime)"
else result archive FAIL "the sysdiagnose changed or disappeared during the run"; fi

cleanup
trap - EXIT
print ""
print "sim-verify summary ($STAGE, $CONFIG, capture ${SOURCE:-n/a})"
for r in $RESULTS; do print -r -- "  $r"; done
free_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
print "  elapsed $(( $(date +%s) - FT_VERIFY_START )) s; free disk $(( FT_VERIFY_FREE_KB / 1024 )) -> $(( free_kb / 1024 )) MB" \
  "(change $(( (FT_VERIFY_FREE_KB - free_kb) / 1024 )) MB used; other agents' builds count too); outputs in $SHOTS"
print -r -- "${(F)RESULTS}" > "$SHOTS/summary.txt"
exit $FAILED
