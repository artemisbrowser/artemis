#!/bin/bash
# One bench arm end to end: kill the app, start the outside sampler, run the
# in-app harness, then print the joined table.
# Usage: tools/bench-run.sh <label> [ARTEMIS_PERF_OFF value]
set -u
cd "$(dirname "$0")/.."
label="$1"
off="${2:-}"
dir="${BENCH_DIR:-/tmp/artemis-bench}"
mkdir -p "$dir"

pkill -x Artemis 2>/dev/null
sleep 2
./tools/bench-sample.sh "$dir/sample-$label.csv" 400 >/dev/null 2>&1 &
sampler=$!
sleep 1
ARTEMIS_BENCH=1 ARTEMIS_BENCH_LABEL="$label" ARTEMIS_PERF_OFF="$off" \
  /Applications/Artemis.app/Contents/MacOS/Artemis >/dev/null 2>&1
kill "$sampler" 2>/dev/null
echo "=== $label (off: ${off:-none}) ==="
./tools/bench-report.py "$HOME/Downloads/artemis-bench-$label.log" "$dir/sample-$label.csv"
