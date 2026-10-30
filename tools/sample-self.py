#!/usr/bin/env python3
"""Rank a `sample` call graph by *self* time.

`sample` prints a tree, and reading a 2000-frame-deep SwiftUI stack by eye tells
you nothing: every frame has the same count as its parent right down to the
leaf. Self time is count-minus-children, which is the only column that says
where the CPU actually went.

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
        if not line or line.startswith("Binary Images") or line.startswith("Call graph"):
            if line.startswith("Binary Images"):
                break
            continue
        m = LINE.match(line)
        if not m:
            continue
        prefix, count, name = m.group(1), int(m.group(2)), m.group(3)
        name = re.sub(r"\s+\(in .*", "", name).strip()
        name = re.sub(r"\s+\+ \d+\s+\[0x[0-9a-f]+\].*", "", name)
        rows.append((len(prefix), count, name))

    # a frame's children are the following rows at greater depth, until a row at
    # the same or lower depth
    self_time = defaultdict(int)
    total = defaultdict(int)
    for i, (depth, count, name) in enumerate(rows):
        child_sum = 0
        for d2, c2, _ in rows[i + 1:]:
            if d2 <= depth:
                break
            if d2 == depth + 2 or (child_sum == 0 and d2 > depth):
                pass
        # simpler: direct children are the first-level rows deeper than `depth`
        j = i + 1
        while j < len(rows) and rows[j][0] > depth:
            if all(rows[k][0] > rows[j][0] or k == j for k in range(i + 1, j + 1)):
                pass
            j += 1
        # direct children = rows strictly deeper whose depth is the minimum
        block = rows[i + 1:j]
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
