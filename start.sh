#!/bin/bash
cd "$(dirname "$0")"

window_count() {
    python3 -c '
import json, os
p = os.path.expanduser("~/.config/dock-scrcpy.conf")
try:
    print(len(json.load(open(p))["windows"]))
except Exception:
    print(2)'
}

VIEWER_PIDS=""
stop_viewers() {
    for p in $VIEWER_PIDS; do kill "$p" 2>/dev/null; done
    VIEWER_PIDS=""
}
cleanup() {
    stop_viewers
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

# Master exits with code 2 to request a restart (fresh process resets a
# poisoned ScreenCaptureKit connection; also used by Settings Apply).
# Viewers are restarted each round so config changes (count/crops) take effect.
# Backoff: 5 consecutive fast deaths (<30s) → sleep 30s, avoids a restart storm
# when the failure is persistent (e.g. screen-recording permission revoked).
FAILS=0
while true; do
    COUNT=$(window_count)
    stop_viewers
    i=1
    while [ "$i" -lt "$COUNT" ]; do
        ./dock-scrcpy "$i" &
        VIEWER_PIDS="$VIEWER_PIDS $!"
        i=$((i + 1))
    done
    STARTED=$(date +%s)
    ./dock-scrcpy 0
    code=$?
    [ "$code" -eq 2 ] || break
    if [ $(($(date +%s) - STARTED)) -lt 30 ]; then
        FAILS=$((FAILS + 1))
    else
        FAILS=0
    fi
    if [ "$FAILS" -ge 5 ]; then
        echo "start.sh: $FAILS fast failures — backing off 30s" >&2
        sleep 30
    else
        echo "start.sh: restarting (exit $code)" >&2
        sleep 1
    fi
done
