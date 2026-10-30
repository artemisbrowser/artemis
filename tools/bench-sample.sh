#!/bin/bash
# Sample what Artemis costs the machine from *outside* the sandbox, because the
# app process can't see its own WebKit children (launchd owns them) or the
# WindowServer time its rendering causes.
#
# Rows are per *process*, not per category: WebKit content processes come and go
# during a run, and summing a category's CPU across a sample where a process
# exited produces a negative delta — which is how a fix once appeared to make
# the web processes burn -1.8 seconds. `bench-report.py` diffs each pid on its
# own and adds the results up.
#
#   tools/bench-sample.sh out.csv 300 &
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
