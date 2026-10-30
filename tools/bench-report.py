#!/usr/bin/env python3
"""Join the in-app bench log with the outside sampler into one table.

    tools/bench-report.py ~/Downloads/artemis-bench-before.log /tmp/sample-before.csv

The in-app log knows the phase boundaries, its own CPU, its footprint and how
many frames were late. The sampler knows what the WebKit children and the
WindowServer cost during the same window. Neither half is the whole picture: a
"fix" that moves work out of the app process and into the compositor is not a
fix, and only the join shows that.

CPU is diffed per process and then summed, because WebKit content processes are
started and killed during a run — summing a category first and diffing after
makes an exiting process look like negative CPU.
"""
import csv
import sys
from collections import defaultdict

CATS = ["artemis", "webcontent", "webkit-gpu", "webkit-net", "windowserver"]


def load_phases(path):
    phases = []
    for line in open(path):
        if line.startswith("WARNING"):
            print(line.rstrip())
        if not line.startswith("#csv ") or line.startswith("#csv phase,"):
            continue
        f = line[5:].strip().split(",")
        phases.append({
            "name": f[0], "start": float(f[1]), "end": float(f[2]),
            "cpu": float(f[3]), "mem": float(f[4]),
            "frames": int(f[5]), "late": int(f[6]), "bodies": int(f[7]),
        })
    return phases


def load_samples(path):
    """category -> pid -> [(epoch, rss, cpu)]"""
    rows = defaultdict(lambda: defaultdict(list))
    for r in csv.DictReader(open(path)):
        rows[r["category"]][r["pid"]].append(
            (int(r["epoch"]), float(r["rss_mb"]), float(r["cpu_sec"])))
    for pids in rows.values():
        for v in pids.values():
            v.sort()
    return rows


def window(by_pid, start, end):
    """cpu seconds burned inside [start, end], and peak total rss"""
    cpu = 0.0
    by_epoch = defaultdict(float)
    for series in by_pid.values():
        inside = [s for s in series if start <= s[0] <= end]
        if len(inside) >= 2:
            cpu += inside[-1][2] - inside[0][2]
        for epoch, rss, _ in inside:
            by_epoch[epoch] += rss
    return cpu, (max(by_epoch.values()) if by_epoch else 0.0)


def main():
    log, sample = sys.argv[1], sys.argv[2]
    phases = load_phases(log)
    samples = load_samples(sample)

    head = f"{'phase':<20}{'wall':>7}{'app cpu':>9}{'web cpu':>9}{'gpu':>7}{'wsrv':>7}"
    head += f"{'app mb':>8}{'web mb':>8}{'late':>6}{'bodies':>8}"
    print(head)
    print("-" * len(head))
    for p in phases:
        wall = p["end"] - p["start"]
        web, webmb = window(samples.get("webcontent", {}), p["start"], p["end"])
        gpu, _ = window(samples.get("webkit-gpu", {}), p["start"], p["end"])
        wsrv, _ = window(samples.get("windowserver", {}), p["start"], p["end"])
        _, appmb = window(samples.get("artemis", {}), p["start"], p["end"])
        print(f"{p['name']:<20}{wall:>6.1f}s{p['cpu']:>8.2f}s{web:>8.2f}s"
              f"{gpu:>6.2f}s{wsrv:>6.2f}s{appmb or p['mem']:>8.1f}{webmb:>8.1f}"
              f"{p['late']:>6}{p['bodies']:>8}")

    tot_app = sum(p["cpu"] for p in phases)
    print("-" * len(head))
    print(f"{'TOTAL':<20}{'':>7}{tot_app:>8.2f}s")


if __name__ == "__main__":
    main()
