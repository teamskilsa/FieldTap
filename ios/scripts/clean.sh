#!/bin/zsh
# Removes this work package's build products ($FT_TMP), uninstalls com.fieldtap.ios from the $FT_SIM_NAME
# simulator and shuts that simulator down (under the simulator lock, so another agent's shot is not cut off).
#
#   clean.sh [--keep-sim]     --keep-sim: uninstall but leave the simulator booted
set -euo pipefail
source "${0:A:h}/env.sh"
KEEP_SIM=0
[[ "${1:-}" == "--keep-sim" ]] && KEEP_SIM=1
if [[ "$FT_TMP" == /private/tmp/fieldtap-build/* && -d "$FT_TMP" ]]; then
  rm -rf "$FT_TMP"
  echo "clean: removed $FT_TMP"
fi
if UDID=$("${0:A:h}/sim-udid.sh" 2>/dev/null); then
  "${0:A:h}/with-sim-lock.sh" zsh -c '
    xcrun simctl uninstall "$1" "$2" 2>/dev/null && echo "clean: uninstalled $2" || true
    if [[ "$3" == 0 ]] && xcrun simctl list devices | grep -q "$1) (Booted)"; then
      xcrun simctl shutdown "$1" && echo "clean: shut down the simulator"
    fi' _ "$UDID" "$FT_BUNDLE_ID" "$KEEP_SIM"
fi
df -h "$HOME" | awk 'NR==2 {print "clean: " $4 " free on " $9}'
