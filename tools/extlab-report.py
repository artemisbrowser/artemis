#!/usr/bin/env python3 -I
"""Summarise an extension-lab sweep: one status per package, failures grouped
by normalised error signature (largest group first), missing-API frequency.
    tools/extlab-report.py [results.jsonl] [--ext KEY]
    tools/extlab-report.py --compare BASE.jsonl CANDIDATE.jsonl
      (writes the candidate's worse packages to confirm-queue.txt beside it)"""
import collections, json, os, re, sys

path = next((a for a in sys.argv[1:] if not a.startswith("--") and a.endswith(".jsonl")),
            os.path.expanduser("~/Downloads/artemis-extlab/results.jsonl"))
only = sys.argv[sys.argv.index("--ext") + 1] if "--ext" in sys.argv else None

def signature(text):
    text = re.sub(r"webkit-extension://[^\s)'\"]+", "<url>", text)
    text = re.sub(r"https?://[^\s)'\"]+", "<url>", text)
    text = re.sub(r"\(\S+:\d+:\d+\)", "", text)
    named = re.search(r"evaluating '([^']{0,120})'|'([\w.$]+)' is (?:undefined|not)", text)
    text = re.sub(r"'[^']{0,200}'", "'…'", text)
    if named:
        text += "  ⟨" + re.sub(r"\w+\(.*", "", named.group(1) or named.group(2) or "") + "⟩"
    text = re.sub(r"\d+", "N", text)
    return text.split("\n")[0].strip()[:160]

LOADING = re.compile(r"^(loading|please wait|loading, please wait)\W*$", re.I)
# what Chrome logs too: a desktop companion app that isn't installed
EXPECTED = re.compile(r"Invalid call to runtime\.connectNative\(\)|NativeMessaging port disconnected"
                      r"|Specified native messaging host not found")

def errors_of(v):
    out = [e for e in v.get("contextErrors", []) if "WKWebExtensionContextErrorDomain" in e
           and not EXPECTED.search(e)]
    out += [c for c in v.get("console", []) if c.startswith(("[uncaught]", "[rejection]", "[error]"))
            and not re.match(r"\[\w+\] ([\w.$]*@\S+|Script error\.|\?|undefined)$", c.split("\n")[0])
            and not EXPECTED.search(c)]
    return out

def surface_problem(state):
    if not state:
        return None
    if state.get("error"):
        return state["error"]
    text = (state.get("text") or "").strip()
    if state.get("chars", 0) == 0 and state.get("elements", 0) < 30:
        return "blank"
    if LOADING.match(text):
        return "stuck loading"
    return None

def status(v):
    if v.get("crash"):
        return "crash"
    if v.get("install"):
        return "install"
    if not v.get("loaded"):
        return "load"
    if errors_of(v):
        return "errors"
    if surface_problem(v.get("popup")) or surface_problem(v.get("options")):
        return "ui"
    return "pass"

def load(file):
    return {v["key"]: v for v in map(json.loads, open(file)) if v.get("key") != "__done__"}

if "--compare" in sys.argv:
    i = sys.argv.index("--compare")
    base, cand = load(sys.argv[i + 1]), load(sys.argv[i + 2])
    shared = [k for k in cand if k in base]
    rank = ["crash", "install", "load", "errors", "ui", "pass"]
    moves = sorted(((rank.index(status(cand[k])) - rank.index(status(base[k])), k) for k in shared))
    print(f"{len(shared)} packages in both: " + ", ".join(
        f"{label} {sum(1 for d, _ in moves if cmp(d))}" for label, cmp in
        [("worse", lambda d: d < 0), ("better", lambda d: d > 0), ("same", lambda d: d == 0)]))
    # one run can't tell a flaky page from a regression: re-run these before believing them
    worse = [k for d, k in moves if d < 0]
    open(os.path.join(os.path.dirname(sys.argv[i + 2]), "confirm-queue.txt"), "w").write("\n".join(worse) + "\n")
    for delta, k in moves:
        if delta == 0:
            continue
        b, c = base[k], cand[k]
        print(f"{'WORSE ' if delta < 0 else 'better'} {status(b):7} → {status(c):7} {(c.get('name') or k)[:40]}")
        if delta < 0:
            for e in sorted(set(errors_of(c)) - set(errors_of(b)))[:4]:
                print("         + " + signature(e))
    for k in shared:
        gone, new = set(map(signature, errors_of(base[k]))), set(map(signature, errors_of(cand[k])))
        if new - gone and status(cand[k]) == status(base[k]) != "pass":
            print(f"new errors (same status) {(cand[k].get('name') or k)[:40]}: " + "; ".join(sorted(new - gone))[:300])
    sys.exit()

verdicts = []
for line in open(path):
    v = json.loads(line)
    if v.get("key") != "__done__" and (not only or only in v["key"]):
        verdicts.append(v)

if only:
    print(json.dumps(verdicts, indent=1)[:20000])
    sys.exit()

by_status = collections.Counter(status(v) for v in verdicts)
print(f"{len(verdicts)} packages: " + ", ".join(f"{k} {n}" for k, n in by_status.most_common()))

def works(v):
    """what a user sees: it loads, its background runs, its popup and options render"""
    failed = any("background content failed" in e for e in v.get("contextErrors", []))
    return (not v.get("crash") and not v.get("install") and v.get("loaded") and not failed
            and not surface_problem(v.get("popup")) and not surface_problem(v.get("options")))
working = sum(map(works, verdicts))
print(f"works (loads, background runs, UI renders): {working}/{len(verdicts)} = {working * 100 // max(1, len(verdicts))}%")

groups = collections.defaultdict(set)
for v in verdicts:
    for e in errors_of(v):
        groups[signature(e)].add(v.get("name") or v["key"])
    for part in ("popup", "options"):
        problem = surface_problem(v.get(part))
        if problem:
            groups[f"{part}: {problem}"].add(v.get("name") or v["key"])
print("\n== failure groups")
for sig, names in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:60]:
    print(f"{len(names):4}  {sig}\n      {', '.join(sorted(names)[:8])}")

named = collections.Counter()
for v in verdicts:
    apis = set()
    for e in errors_of(v):
        apis.update(re.findall(r"(?:chrome|browser)\.(\w+(?:\.\w+)?)", e))
    named.update(apis)
print("\n== APIs named in errors")
for name, n in named.most_common(40):
    print(f"{n:4}  {name}")

print("\n== per package")
for v in verdicts:
    print(f"{status(v):8} {(v.get('name') or '?')[:40]:40} {v['key']}")
