#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

"""Score a tab-name sweep.

Reads ~/Downloads/artemis-sweep.jsonl (written by ARTEMIS_DIAG=sweep) and
reports, for every context depth:

  named      how often a page ended up with a name at all
  words      how long those names are (the sidebar column fits about four)
  site       names that are just the site's brand, on a page other than its front
  dupe       one name landing on two different pages of the same site
  junk       names that read as a consent wall, "enable JavaScript" or an error page
  echo       the name is the title with nothing removed
  fill       names containing a joining word ("for", "of", "the", ...)
  new        names carrying a word the title doesn't

`--sample` and `--compare` print names side by side for judging quality.
"""

import argparse
import json
import os
import random
import re
from collections import defaultdict

STOP = {"the", "a", "an", "of", "for", "and", "in", "on", "to", "with", "s"}

JUNK = re.compile(
    r"just a moment|enable javascript|access denied|are you a robot|captcha|"
    r"page not found|404|403|forbidden|cloudflare|attention required|"
    r"unsupported browser|cookies? (policy|notice|consent)",
    re.I,
)


def brandish(host: str) -> set[str]:
    """the words a site's name is likely made of, from its domain"""
    parts = host.lower().replace("www.", "").split(".")
    return {p for p in parts if p not in {"com", "org", "net", "co", "uk", "io", "dev", "app"}}


def load(path: str) -> list[dict]:
    with open(path) as handle:
        return [json.loads(line) for line in handle if line.strip()]


def summarise(rows: list[dict]) -> dict:
    named = [r for r in rows if r["name"]]
    words = [len(r["name"].split()) for r in named]
    site_only = 0
    echo = 0
    junk = 0
    for r in named:
        name = r["name"].lower().strip()
        if JUNK.search(name):
            junk += 1
        # a site's own name is the right name for its front page
        path = r["url"].split(r["host"], 1)[-1] if r["host"] in r["url"] else "/"
        front = path in ("", "/")
        if not front and name.replace(" ", "") in brandish(r["host"]):
            site_only += 1
        if name == r["title"].lower().strip():
            echo += 1

    filler = sum(
        1
        for r in named
        if any(f" {w} " in f" {r['name'].lower()} " for w in
               ("for", "of", "with", "to", "and", "the", "a", "in", "on"))
    )

    new_word = 0
    for r in named:
        title_words = set(re.findall(r"[a-z0-9]+", r["title"].lower()))
        name_words = set(re.findall(r"[a-z0-9]+", r["name"].lower())) - STOP
        if name_words - title_words:
            new_word += 1

    per_host = defaultdict(lambda: defaultdict(set))
    for r in named:
        per_host[r["host"]][r["name"].lower()].add(r["url"])
    dupes = sum(
        len(urls) - 1
        for names in per_host.values()
        for urls in names.values()
        if len(urls) > 1
    )

    rejections = defaultdict(int)
    for r in rows:
        if not r["name"] and r["rejection"]:
            rejections[r["rejection"]] += 1

    return {
        "rows": len(rows),
        "named": len(named),
        "named_pct": 100 * len(named) / max(1, len(rows)),
        "mean_words": sum(words) / max(1, len(words)),
        "over_four": 100 * sum(1 for w in words if w > 4) / max(1, len(words)),
        "site_only": site_only,
        "echo": echo,
        "junk": junk,
        "dupes": dupes,
        "filler": filler,
        "new_word": 100 * new_word / max(1, len(named)),
        "ms": sum(r["ms"] for r in rows) / max(1, len(rows)),
        "rejections": dict(rejections),
        "context": sum(r["contextChars"] for r in rows) / max(1, len(rows)),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", default=os.path.expanduser("~/Downloads/artemis-sweep.jsonl"))
    parser.add_argument("--sample", type=int, default=0, help="print N pages across variants")
    parser.add_argument("--category", help="only this category")
    parser.add_argument("--worst", type=int, default=0, help="print N suspect names")
    parser.add_argument("--compare", help="another sweep file to set side by side")
    args = parser.parse_args()

    rows = load(args.file)
    if args.category:
        rows = [r for r in rows if r["category"] == args.category]
    if not rows:
        print("no rows")
        return

    groups = defaultdict(list)
    for row in rows:
        groups[row["tier"]].append(row)

    print(f"{len(rows)} names over {len({r['url'] for r in rows})} pages\n")
    header = (
        f"{'context':11} {'chars':>6} {'named':>6} {'words':>6} "
        f"{'>4w':>5} {'site':>5} {'dupe':>5} {'junk':>5} {'echo':>5} {'fill':>5} "
        f"{'new':>5} {'ms':>6}"
    )
    print(header)
    print("-" * len(header))
    summaries = {key: summarise(groups[key]) for key in sorted(groups)}
    for key, s in summaries.items():
        print(
            f"{key:11} {s['context']:6.0f} {s['named_pct']:5.0f}% "
            f"{s['mean_words']:6.1f} {s['over_four']:4.0f}% {s['site_only']:5} "
            f"{s['dupes']:5} {s['junk']:5} {s['echo']:5} {s['filler']:5} "
            f"{s['new_word']:4.0f}% {s['ms']:6.0f}"
        )

    print("\nwhy a page ended up unnamed")
    for key, s in summaries.items():
        if s["rejections"]:
            detail = ", ".join(f"{k}: {v}" for k, v in sorted(s["rejections"].items()))
            print(f"  {key:11} {detail}")

    if args.sample:
        print("\n" + "=" * 100)
        urls = sorted({r["url"] for r in rows})[: args.sample]
        for url in urls:
            page = [r for r in rows if r["url"] == url]
            print(f"\n{page[0]['category']}  {url}")
            print(f"  title: {page[0]['title'][:110]}")
            for r in sorted(page, key=lambda r: r["tier"]):
                mark = " " if r["name"] else "×"
                print(
                    f"  {mark} {r['tier']:11} "
                    f"{r['name'] or '(' + r['rejection'] + ')'}"
                )

    if args.compare:
        # column order is shuffled per page so the reader can't favour one run
        other = load(args.compare)
        by_url = {r["url"]: r for r in rows}
        pairs = [(by_url[r["url"]], r) for r in other if r["url"] in by_url]
        random.Random(11).shuffle(pairs)
        print("\n" + "=" * 100)
        print(f"A = {args.file}\nB = {args.compare}\n")
        for a, b in pairs[: args.sample or 40]:
            if a["name"] == b["name"]:
                continue
            flip = random.Random(hash(a["url"]) & 0xffff).random() < 0.5
            first, second = (b, a) if flip else (a, b)
            print(f"[{a['category']}] {a['title'][:78]}")
            print(f"   {'B' if flip else 'A'}: {first['name'] or '(' + first['rejection'] + ')'}")
            print(f"   {'A' if flip else 'B'}: {second['name'] or '(' + second['rejection'] + ')'}")

    if args.worst:
        print("\n" + "=" * 100)
        print("suspect names")
        suspects = []
        for r in rows:
            if not r["name"]:
                continue
            name = r["name"].lower()
            reason = None
            if JUNK.search(name):
                reason = "junk"
            elif name.replace(" ", "") in brandish(r["host"]):
                reason = "site name only"
            elif len(r["name"].split()) > 4:
                reason = "too long"
            if reason:
                suspects.append((reason, r))
        for reason, r in suspects[: args.worst]:
            print(f"  [{reason}] {r['tier']} {r['host']}")
            print(f"      title: {r['title'][:90]}")
            print(f"      name:  {r['name']}")


if __name__ == "__main__":
    main()
