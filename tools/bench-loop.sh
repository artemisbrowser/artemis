#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Repeat one ARTEMIS_BENCH_LOOP interaction (a case in Bench.swift) for a minute,
# then print it joined with the outside sampler.
# Usage: tools/bench-loop.sh <loop> <label> [PERF_OFF] [live]
set -u
cd "$(dirname "$0")/.."
loop="$1"; label="$2"; off="${3:-}"; mode="${4:-1}"
dir="${BENCH_DIR:-/tmp/artemis-bench}"
mkdir -p "$dir"
pkill -x Artemis 2>/dev/null
sleep 2
./tools/bench-sample.sh "$dir/sample-$label.csv" 300 >/dev/null 2>&1 &
sampler=$!
sleep 1
ARTEMIS_BENCH="$mode" ARTEMIS_BENCH_LOOP="$loop" ARTEMIS_BENCH_LABEL="$label" \
  ARTEMIS_PERF_OFF="$off" /Applications/Artemis.app/Contents/MacOS/Artemis >/dev/null 2>&1
kill "$sampler" 2>/dev/null
echo "=== $label (loop $loop, off: ${off:-none}, mode $mode) ==="
./tools/bench-report.py "$HOME/Downloads/artemis-bench-$label.log" "$dir/sample-$label.csv"
