#!/bin/zsh
# Prints the UDID of the available simulator named $1 (default $FT_SIM_NAME): a booted one first, else the
# one on the newest runtime. Exits 1 when there is none. Never creates or boots anything.
set -euo pipefail
source "${0:A:h}/env.sh"
NAME=${1:-$FT_SIM_NAME}
xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d.get("name") == name and d.get("isAvailable", True):
            found.append((d.get("state") == "Booted", runtime, d["udid"]))
if not found:
    sys.exit(f"no available simulator named {name!r}")
print(sorted(found)[-1][2])
' "$NAME"
