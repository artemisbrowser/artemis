#!/usr/bin/env python3
"""Score a tab-name sweep.

Reads ~/Downloads/artemis-sweep.jsonl (written by ARTEMIS_DIAG=sweep) and
reports, for every prompt × context-depth combination, the things that can be
measured without an opinion:

  named      how often a page ended up with a name at all
  words      how long those names are (the sidebar column fits about four)
  site-only  names that are just the site's brand — true of the page and
             useless as a name for it
  dupes      one name landing on two different pages of the same site, which
             is the failure that makes a sidebar unreadable
  junk       consent walls, "enable JavaScript", error pages: the name is
             fine, the page was never really loaded
  echo       the name is the title with nothing removed

None of these say whether a name is *good* — that still needs judgement, and
`--sample` prints a comparison table to judge from. What they do is throw out
the variants that are obviously broken, so judgement is spent on the handful
that aren't.
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
        # a site's own name IS the right name for its front page; only count
        # it as a failure on a page that is one of many
        path = r["url"].split(r["host"], 1)[-1] if r["host"] in r["url"] else "/"
        front = path in ("", "/")
        if not front and name.replace(" ", "") in {b for b in brandish(r["host"])}:
            site_only += 1
        if name == r["title"].lower().strip():
            echo += 1

    # a tab name is a label, not a sentence: joining words are wasted column
    # ("Minimal prompt for shell" should read "Minimal shell prompt")
    filler = sum(
        1
        for r in named
        if any(f" {w} " in f" {r['name'].lower()} " for w in
               ("for", "of", "with", "to", "and", "the", "a", "in", "on"))
    )

    # Names carrying a word the title doesn't. Every other measure here is
    # satisfied by a good shortening, so without this one abstraction is invisible.
    new_word = 0
    for r in named:
        title_words = set(re.findall(r"[a-z0-9]+", r["title"].lower()))
        name_words = set(re.findall(r"[a-z0-9]+", r["name"].lower())) - STOP
        if name_words - title_words:
            new_word += 1

    # a name that lands on two different pages of one site tells them apart
    # from nothing
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
        groups[(row["prompt"], row["tier"])].append(row)

    print(f"{len(rows)} names over {len({r['url'] for r in rows})} pages\n")
    header = (
        f"{'prompt':10} {'context':11} {'chars':>6} {'named':>6} {'words':>6} "
        f"{'>4w':>5} {'site':>5} {'dupe':>5} {'junk':>5} {'echo':>5} {'fill':>5} "
        f"{'new':>5} {'ms':>6}"
    )
    print(header)
    print("-" * len(header))
    for key in sorted(groups):
        s = summarise(groups[key])
        print(
            f"{key[0]:10} {key[1]:11} {s['context']:6.0f} {s['named_pct']:5.0f}% "
            f"{s['mean_words']:6.1f} {s['over_four']:4.0f}% {s['site_only']:5} "
            f"{s['dupes']:5} {s['junk']:5} {s['echo']:5} {s['filler']:5} "
            f"{s['new_word']:4.0f}% {s['ms']:6.0f}"
        )

    print("\nwhy a page ended up unnamed")
    for key in sorted(groups):
        s = summarise(groups[key])
        if s["rejections"]:
            detail = ", ".join(f"{k}: {v}" for k, v in sorted(s["rejections"].items()))
            print(f"  {key[0]:10} {key[1]:11} {detail}")

    if args.sample:
        print("\n" + "=" * 100)
        urls = sorted({r["url"] for r in rows})[: args.sample]
        for url in urls:
            page = [r for r in rows if r["url"] == url]
            print(f"\n{page[0]['category']}  {url}")
            print(f"  title: {page[0]['title'][:110]}")
            for r in sorted(page, key=lambda r: (r["prompt"], r["tier"])):
                mark = " " if r["name"] else "×"
                print(
                    f"  {mark} {r['prompt']:9} {r['tier']:11} "
                    f"{r['name'] or '(' + r['rejection'] + ')'}"
                )

    if args.compare:
        # the same pages, two runs, side by side — the only honest way to tell
        # which prompt is better once the countable measures agree. Order is
        # shuffled per page so a reader can't drift into favouring one column.
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
            print(f"  [{reason}] {r['prompt']}/{r['tier']} {r['host']}")
            print(f"      title: {r['title'][:90]}")
            print(f"      name:  {r['name']}")


if __name__ == "__main__":
    main()
