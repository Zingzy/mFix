#!/bin/sh
# Runs a guarded on-screen check against the running Snap11 once the Mac is idle, retrying
# every 15 s for up to 10 min. Exit 3 means the Mac was in use, 4 that someone touched it.
# Usage: scripts/when-idle.sh --dock-check|--drive
cd "$(dirname "$0")/.." || exit 1
i=0
while [ $i -lt 40 ]; do
    app=$(pgrep -f 'build/Snap11.app/Contents/MacOS/Snap11$' | head -1)
    out=$(.build/debug/Snap11 "$1" "$app" 2>&1)
    rc=$?
    if [ $rc -ne 3 ] && [ $rc -ne 4 ]; then
        echo "$out"
        exit $rc
    fi
    i=$((i+1))
    sleep 15
done
echo "the Mac never sat idle for 10 s"
exit 3
