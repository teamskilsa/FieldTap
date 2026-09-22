#!/bin/zsh
# Screenshots one screen of FieldTap in the $FT_SIM_NAME simulator.
#
#   sim-shot.sh [--config Debug|Harness] [--args '-FTFixture DIR -FTScreen overview ...'] [--env K=V]...
#               [--wait-screen ROUTE] [--expect KEY=VALUE]... [--timeout SEC] [--no-build] --out PNG
#
# 1. Builds the configuration (build-app.sh: a build slot), then takes the simulator lock (with-sim-lock.sh).
# 2. Boots $FT_SIM_NAME if needed (only that one), installs the app, clears Documents/ft-debug.
# 3. Launches with the arguments, and each --env as SIMCTL_CHILD_K=V.
# 4. Waits up to --timeout (60 s) for Documents/ft-debug/screen-ROUTE*.json with "ready": true. ROUTE is
#    --wait-screen, else the -FTScreen argument, else "captures". Loading the real 40 MB qmdl through the
#    Analyzer takes seconds in Debug, so a fixed short sleep is not enough.
# 5. Checks each --expect against the report (dotted keys into it, e.g. ready=true, values.rowCount=157),
#    takes the screenshot, copies the report next to it (PNG name + .json), and terminates the app.
# The simulator is left booted for the next shot; clean.sh shuts it down.
set -euo pipefail
source "${0:A:h}/env.sh"
CONFIG=Debug; ARGS=""; OUT=""; WAIT=""; TIMEOUT=60; BUILD=1
typeset -a ENVS EXPECTS
ORIG=("$@")
while (( $# > 0 )); do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --args) ARGS=$2; shift 2 ;;
    --env) ENVS+=("$2"); shift 2 ;;
    --wait-screen) WAIT=$2; shift 2 ;;
    --expect) EXPECTS+=("$2"); shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    *) echo "sim-shot: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$OUT" ]] || { echo "sim-shot: --out PNG is required" >&2; exit 2; }
APP="$FT_TMP/dd/Build/Products/$CONFIG-iphonesimulator/FieldTap.app"

if [[ "${FT_IN_SIM_LOCK:-}" != 1 ]]; then
  if (( BUILD )); then "${0:A:h}/build-app.sh" "$CONFIG" > /dev/null; fi
  exec "${0:A:h}/with-sim-lock.sh" "${0:A}" "${ORIG[@]}" --no-build
fi
[[ -d "$APP" ]] || { echo "sim-shot: $APP not built" >&2; exit 1; }

if [[ -z "$WAIT" ]]; then
  WAIT=$(print -r -- "$ARGS" | awk '{for (i = 1; i < NF; i++) if ($i == "-FTScreen") print $(i + 1)}')
  WAIT=${WAIT:-captures}
fi
UDID=$("${0:A:h}/sim-udid.sh")
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 > /dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" "$FT_BUNDLE_ID" data)
rm -rf "$DATA/Documents/ft-debug"

typeset -a LAUNCH_ENV
for kv in $ENVS; do LAUNCH_ENV+=("SIMCTL_CHILD_$kv"); done
env "${LAUNCH_ENV[@]}" xcrun simctl launch --terminate-running-process "$UDID" "$FT_BUNDLE_ID" ${=ARGS} > /dev/null

REPORT=""
deadline=$(( SECONDS + TIMEOUT ))
while (( SECONDS < deadline )); do
  for f in "$DATA"/Documents/ft-debug/screen-${WAIT}.json(N) "$DATA"/Documents/ft-debug/screen-${WAIT}-*.json(N); do
    if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ready") else 1)' "$f" 2>/dev/null; then
      REPORT=$f; break
    fi
  done
  [[ -n "$REPORT" ]] && break
  sleep 0.5
done
if [[ -z "$REPORT" ]]; then
  echo "sim-shot: no ready screen-$WAIT report within ${TIMEOUT}s; screenshotting anyway" >&2
  ls "$DATA/Documents/ft-debug" 2>/dev/null >&2 || true
fi
sleep 1
mkdir -p "${OUT:h}"
xcrun simctl io "$UDID" screenshot --type=png "$OUT" > /dev/null 2>&1
[[ -n "$REPORT" ]] && cp "$REPORT" "${OUT:r}.json"
xcrun simctl terminate "$UDID" "$FT_BUNDLE_ID" > /dev/null 2>&1 || true

rc=0
[[ -n "$REPORT" ]] || rc=4
for e in $EXPECTS; do
  python3 - "$REPORT" "$e" <<'PY' || rc=5
import json, sys
path, expect = sys.argv[1], sys.argv[2]
key, want = expect.split('=', 1)
try:
    v = json.load(open(path))
    for part in key.split('.'):
        v = v[part]
except Exception as e:
    sys.exit(f'sim-shot: expect {key}: not in the report ({e})')
got = json.dumps(v) if not isinstance(v, str) else v
if got != want and str(v).lower() != want.lower():
    sys.exit(f'sim-shot: expect {key}={want}, got {got}')
PY
done
BYTES=$(stat -f %z "$OUT" 2>/dev/null || echo 0)
if [[ -n "$REPORT" ]]; then
  echo "sim-shot: $OUT ($BYTES bytes), report ${OUT:r}.json"
else
  echo "sim-shot: $OUT ($BYTES bytes), no ready report"
fi
exit $rc
