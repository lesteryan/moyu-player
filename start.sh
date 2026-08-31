#!/bin/bash
cd "$(dirname "$0")"

COUNT=$(python3 -c '
import json, os
p = os.path.expanduser("~/.config/dock-scrcpy.conf")
try:
    print(len(json.load(open(p))["windows"]))
except Exception:
    print(2)')

VIEWER_PIDS=""
cleanup() {
    for p in $VIEWER_PIDS; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

# Viewers are pure shared-memory readers; start them first, they wait for master.
i=1
while [ "$i" -lt "$COUNT" ]; do
    ./dock-scrcpy "$i" &
    VIEWER_PIDS="$VIEWER_PIDS $!"
    i=$((i + 1))
done

# Master exits with code 2 to request a restart (fresh process resets a
# poisoned ScreenCaptureKit connection).
while true; do
    ./dock-scrcpy 0
    code=$?
    [ "$code" -eq 2 ] || break
    echo "start.sh: restarting master (exit $code)" >&2
    sleep 1
done
