#!/bin/zsh
# Builds the FieldTap app for the $FT_SIM_NAME simulator into $FT_TMP/dd, holding a build slot.
#
#   build-app.sh [Debug|Harness|Release] [extra xcodebuild args...]
#
# The destination names the simulator (not "generic/platform=iOS Simulator", which builds two architectures and
# about twice the DerivedData), and ONLY_ACTIVE_ARCH=YES keeps Release and Harness to the simulator's arch.
# Prints the .app path on the last line.
set -euo pipefail
source "${0:A:h}/env.sh"
CONFIG=${1:-Debug}
(( $# > 0 )) && shift
case $CONFIG in Debug|Harness|Release) ;; *) echo "usage: $0 [Debug|Harness|Release]" >&2; exit 2 ;; esac
mkdir -p "$FT_TMP"
LOG="$FT_TMP/build-$CONFIG.log"
echo "build-app: $CONFIG for '$FT_SIM_NAME' -> $FT_TMP/dd (log $LOG)" >&2
set +e
"${0:A:h}/with-build-slot.sh" xcodebuild -project "$FT_IOS/FieldTap.xcodeproj" -scheme FieldTap -configuration "$CONFIG" \
  -destination "platform=iOS Simulator,name=$FT_SIM_NAME" -derivedDataPath "$FT_TMP/dd" \
  ONLY_ACTIVE_ARCH=YES "$@" build > "$LOG" 2>&1
rc=$?
set -e
grep -E '(error|warning): ' "$LOG" | grep -v '^ld: warning: ' | sort -u | head -40 >&2 || true
grep -E '\*\* BUILD (SUCCEEDED|FAILED) \*\*' "$LOG" >&2 || tail -20 "$LOG" >&2
(( rc == 0 )) || exit $rc
echo "$FT_TMP/dd/Build/Products/$CONFIG-iphonesimulator/FieldTap.app"
