#!/usr/bin/env python3
"""Rank a `sample` call graph by self time: a frame's count minus its direct children's.

    sample Artemis 20 -file out.txt && tools/sample-self.py out.txt
"""
import re
import sys
from collections import defaultdict

LINE = re.compile(r"^([ +!:|]*)(\d+) (.*)$")


def main():
    rows = []  # (depth, count, name)
    for raw in open(sys.argv[1]):
        line = raw.rstrip("\n")
        if line.startswith("Binary Images"):
            break
        if not line or line.startswith("Call graph"):
            continue
        m = LINE.match(line)
        if not m:
            continue
        prefix, count, name = m.group(1), int(m.group(2)), m.group(3)
        name = re.sub(r"\s+\(in .*", "", name).strip()
        name = re.sub(r"\s+\+ \d+\s+\[0x[0-9a-f]+\].*", "", name)
        rows.append((len(prefix), count, name))

    self_time = defaultdict(int)
    total = defaultdict(int)
    for i, (depth, count, name) in enumerate(rows):
        # the subtree runs to the next row at this depth or shallower; its
        # shallowest rows are the direct children
        j = i + 1
        while j < len(rows) and rows[j][0] > depth:
            j += 1
        block = rows[i + 1:j]
        child_sum = 0
        if block:
            child_depth = min(d for d, _, _ in block)
            child_sum = sum(c for d, c, _ in block if d == child_depth)
        self_time[name] += max(count - child_sum, 0)
        total[name] += count

    print(f"{'self':>7} {'total':>7}  symbol")
    print("-" * 78)
    for name, s in sorted(self_time.items(), key=lambda kv: -kv[1])[:30]:
        if s == 0:
            continue
        print(f"{s:>7} {total[name]:>7}  {name[:64]}")


if __name__ == "__main__":
    main()
