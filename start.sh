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

# Dock appends tiles in the order apps register as Foreground, so launch
# index 0 first and wait for its tile before starting the next one —
# otherwise viewer 1 lands left of master and the picture is mirrored.
wait_foreground() {
    local pid=$1 asn
    for _ in $(seq 50); do
        kill -0 "$pid" 2>/dev/null || return 1
        asn=$(lsappinfo find "pid=$pid")
        if [ -n "$asn" ] && lsappinfo info -only applicationtype "$asn" | grep -q Foreground; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

MASTER_PID=""
VIEWER_PIDS=""
# Wait for viewers to actually exit: each holds a per-index flock and a Dock
# tile, and a new viewer started before the old one is gone would see the
# lock held and quit.
stop_viewers() {
    for p in $VIEWER_PIDS; do kill "$p" 2>/dev/null; done
    for p in $VIEWER_PIDS; do wait "$p" 2>/dev/null; done
    VIEWER_PIDS=""
}
cleanup() {
    trap - EXIT INT TERM HUP
    [ -n "$MASTER_PID" ] && kill "$MASTER_PID" 2>/dev/null
    stop_viewers
    wait 2>/dev/null
    exit 0
}
trap cleanup EXIT INT TERM HUP

# Master exits with code 2 to request a restart (fresh process resets a
# poisoned ScreenCaptureKit connection; also used by Settings Apply).
# Viewers are restarted each round (after master, to keep Dock order) so
# config changes (count/crops) take effect.
# Backoff: 5 consecutive fast deaths (<30s) → sleep 30s, avoids a restart storm
# when the failure is persistent (e.g. screen-recording permission revoked).
FAILS=0
while true; do
    COUNT=$(window_count)
    stop_viewers
    STARTED=$(date +%s)
    ./dock-scrcpy 0 &
    MASTER_PID=$!
    if wait_foreground "$MASTER_PID"; then
        i=1
        while [ "$i" -lt "$COUNT" ]; do
            ./dock-scrcpy "$i" &
            VIEWER_PIDS="$VIEWER_PIDS $!"
            wait_foreground $! || true
            i=$((i + 1))
        done
    fi
    wait "$MASTER_PID"
    code=$?
    MASTER_PID=""
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
