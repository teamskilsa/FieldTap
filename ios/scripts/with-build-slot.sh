#!/bin/zsh
# Runs a command in one of two shared build slots, so at most two swift/xcodebuild builds run at once on
# this Mac (10 cores, 16 GB, little disk). Tries slot A, then slot B, then waits for whichever frees first.
# Refuses to start when the home volume has less than FT_MIN_FREE_GB free.
#
#   with-build-slot.sh <command> [args...]
#
# Nested calls (a script that already holds a slot) run the command directly.
set -uo pipefail
source "${0:A:h}/env.sh"
(( $# > 0 )) || { echo "usage: $0 <command> [args...]" >&2; exit 2; }

if [[ "${FT_IN_BUILD_SLOT:-}" == 1 ]]; then
  exec "$@"
fi

free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
if (( free_gb < FT_MIN_FREE_GB )); then
  echo "with-build-slot: only ${free_gb} GB free (< ${FT_MIN_FREE_GB} GB); not starting a build" >&2
  exit 3
fi

export FT_IN_BUILD_SLOT=1
slots=(${=FT_BUILD_SLOTS})
EX_TEMPFAIL=75
waited=0
deadline=$(( SECONDS + ${FT_BUILD_SLOT_TIMEOUT:-3600} ))
while true; do
  for slot in $slots; do
    FT_BUILD_SLOT_NAME=${slot:t:r} lockf -k -s -t 0 "$slot" "$@"
    rc=$?
    if (( rc != EX_TEMPFAIL )); then
      exit $rc
    fi
  done
  if (( !waited )); then
    echo "with-build-slot: both build slots busy; waiting" >&2
    waited=1
  fi
  if (( SECONDS > deadline )); then
    echo "with-build-slot: gave up waiting for a build slot" >&2
    exit $EX_TEMPFAIL
  fi
  sleep 1
done
