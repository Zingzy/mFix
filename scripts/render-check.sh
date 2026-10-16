#!/bin/sh
# Builds the three panels off-screen from the windows on this Space and writes PNGs.
cd "$(dirname "$0")/.." || exit 1
OUT="${1:-$HOME/scratch/mfix-render}"
mkdir -p "$OUT"
swift build 2>&1 | grep -E 'error' && exit 1
.build/debug/mFix --render "$OUT" &
pid=$!
i=0
while [ $i -lt 40 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i+1)); done
if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "render check timed out"; exit 1; fi
wait "$pid"
