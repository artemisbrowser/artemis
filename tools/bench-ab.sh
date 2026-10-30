#!/bin/bash
# Interleaved A/B: run each arm alternately N times and print every result, so
# the comparison isn't decided by whatever the machine was doing for one minute.
# Usage: tools/bench-ab.sh <loop> <reps> <armA-perf-off> <armB-perf-off>
set -u
cd "$(dirname "$0")/.."
loop="$1"; reps="$2"; a="$3"; b="${4:-}"
for i in $(seq 1 "$reps"); do
  ./tools/bench-loop.sh "$loop" "A$i" "$a" 2>&1 | grep -vE "Terminated|^===|^phase|^---|^TOTAL" | sed "s/^/A($a) /"
  ./tools/bench-loop.sh "$loop" "B$i" "$b" 2>&1 | grep -vE "Terminated|^===|^phase|^---|^TOTAL" | sed "s/^/B($b) /"
done
