#!/bin/zsh
# Runs a command while holding the one simulator lock, so only one agent drives the $FT_SIM_NAME simulator
# at a time. Take a build slot first (with-build-slot.sh) and the simulator lock second, never the other way
# round, so two agents can't deadlock.
#
#   with-sim-lock.sh <command> [args...]
set -uo pipefail
source "${0:A:h}/env.sh"
(( $# > 0 )) || { echo "usage: $0 <command> [args...]" >&2; exit 2; }
if [[ "${FT_IN_SIM_LOCK:-}" == 1 ]]; then
  exec "$@"
fi
export FT_IN_SIM_LOCK=1
if ! lockf -k -s -t 0 "$FT_SIM_LOCK" true; then
  echo "with-sim-lock: simulator busy; waiting" >&2
fi
exec lockf -k -t "${FT_SIM_LOCK_TIMEOUT:-3600}" "$FT_SIM_LOCK" "$@"
