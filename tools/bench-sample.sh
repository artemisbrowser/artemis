#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Sample Artemis, its WebKit processes (launchd's children, not the app's) and
# WindowServer once a second, one row per process: bench-report.py diffs each pid.
#   tools/bench-sample.sh [out.csv] [seconds] &
out="${1:-/tmp/artemis-sample.csv}"
seconds="${2:-300}"

echo "epoch,category,pid,rss_mb,cpu_sec" > "$out"

end=$(( $(date +%s) + seconds ))
while [ "$(date +%s)" -lt "$end" ]; do
  ps -Ao pid,rss,time,comm | awk -v now="$(date +%s)" '
    function secs(t,   n, p) {
      n = split(t, p, ":")
      if (n == 3) return p[1]*3600 + p[2]*60 + p[3]
      if (n == 2) return p[1]*60 + p[2]
      return t
    }
    {
      cmd = $4
      for (i = 5; i <= NF; i++) cmd = cmd " " $i
      cat = ""
      if (cmd ~ /Artemis\.app\/Contents\/MacOS\/Artemis$/) cat = "artemis"
      else if (cmd ~ /WebKit\.WebContent/) cat = "webcontent"
      else if (cmd ~ /WebKit\.GPU/) cat = "webkit-gpu"
      else if (cmd ~ /WebKit\.Networking/) cat = "webkit-net"
      else if (cmd ~ /WindowServer$/) cat = "windowserver"
      if (cat == "") next
      printf "%d,%s,%d,%.1f,%.2f\n", now, cat, $1, $2/1024, secs($3)
    }
  ' >> "$out"
  sleep 1
done
