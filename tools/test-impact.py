#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

"""Which self-test groups and bench loops a change can affect, from a measured coverage map.

  tools/test-impact.py select [--base stable] [--head HEAD] [--perf] [-v]
      prints the groups to run comma-separated, 1 for the whole suite, or none (--perf: bench loops)
  tools/test-impact.py build-map <slice-dir> <instrumented-binary> <sha>
      writes tools/test-impact-map.json from one coverage run (tools/test-impact-map.sh runs both steps)
"""
import argparse, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(ROOT, "tools", "test-impact-map.json")
SUITE = "Artemis/models/SelfTest.swift"
LAUNCH = "_launch"
# a selection over this share of the groups runs the whole suite instead
THRESHOLD = 0.5
# paths no self-test or bench can reach
INERT = re.compile(r"^(docs|website|discord|feedback|sync|\.github|\.claude)/|^tools/(?!perflab\.sh$)|\.md$|^(LICENSE|CLA|\.gitignore)")
# paths that reach every group: build settings and the app's declared capabilities
GLOBAL = re.compile(r"[/+][Ss]ync(Lab)?[/.]|^Artemis\.xcodeproj/|^xcede\.yml$|^tools/perflab\.sh$|\.(entitlements|plist|sdef)$")
ENTRY = re.compile(r'^\s*\(?\s*"([a-z0-9]+)",')


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], check=True, capture_output=True, text=True).stdout


def hunks(a, b, path):
    """(old_start, old_len, new_start, new_len) of each -U0 hunk of `path` from a to b."""
    out = []
    for line in git("diff", "-U0", "--no-renames", a, b, "--", path).splitlines():
        m = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
        if m:
            o, ol, n, nl = m.groups()
            out.append((int(o), 1 if ol is None else int(ol), int(n), 1 if nl is None else int(nl)))
    return out


def translate(line, diff):
    """`line` on the new side of `diff`, as a line of its old side; None when the diff changed it."""
    shift = 0
    for o, ol, n, nl in diff:
        if nl and n <= line < n + nl:
            return None
        if line < (n if nl else n + 1):
            break
        shift += ol - nl
    return line + shift


def suite_table(text):
    """SelfTest.run's group names in order, and {test function: groups whose entry calls it}."""
    body = text[text.index("static func run(manager: TabManager)") :]
    body = body[: body.index("forgetTestTraces(manager)")]
    order, calls, group = [], {}, None
    for line in body.splitlines():
        if m := ENTRY.match(line):
            group = m.group(1)
            order.append(group)
        for fn in re.findall(r"\b(test[A-Z]\w*)\(", line):
            calls.setdefault(fn, set()).add(group)
    order.insert(order.index("session"), "sync")
    return order, calls


def build_map(slice_dir, binary, sha):
    xcrun = lambda *a: subprocess.run(["xcrun", *a], check=True, capture_output=True, text=True).stdout
    present = {f[: -len(".profraw")] for f in os.listdir(slice_dir) if f.endswith(".profraw")}
    groups = [g for g in suite_table(git("show", f"{sha}:{SUITE}"))[0] if g in present]
    slices = [LAUNCH] + groups + sorted(s for s in present if s.startswith("loop-"))
    raw = [os.path.join(slice_dir, s + ".profraw") for s in slices]
    merged = os.path.join(slice_dir, "all.profdata")
    xcrun("llvm-profdata", "merge", "-sparse", "-o", merged, *raw)
    executed = {}
    for bit, path in enumerate(raw):
        name = None
        for line in xcrun("llvm-profdata", "show", "--all-functions", path).splitlines():
            if line.startswith("  ") and not line.startswith("   ") and line.endswith(":"):
                # file-private symbols carry "<path>:" here and not in the export
                name = line.strip()[:-1]
                name = name[name.find(":$") + 1 :] if ":$" in name else name
            elif line.strip().startswith("Function count:") and int(line.split(":")[1]) > 0:
                executed[name] = executed.get(name, 0) | 1 << bit
    export = json.loads(xcrun("llvm-cov", "export", "-format=text", "-skip-expansions", "-instr-profile", merged, binary))
    tracked = set(git("ls-files", "*.swift").split())
    files = {}
    for fn in export["data"][0]["functions"]:
        path = os.path.relpath(os.path.realpath(fn["filenames"][0]), os.path.realpath(ROOT))
        lines = [n for r in fn["regions"] if r[5] == 0 for n in (r[0], r[2])]
        if path in tracked and lines:
            files.setdefault(path, set()).add((min(lines), max(lines), format(executed.get(fn["name"], 0), "x")))
    with open(MAP, "w") as f:
        f.write('{"sha":"%s","slices":%s,"files":{\n' % (sha, json.dumps(slices)))
        f.write(",\n".join(f"{json.dumps(p)}:{json.dumps(sorted(fs), separators=(',', ':'))}" for p, fs in sorted(files.items())))
        f.write("\n}}\n")
    print(f"{len(files)} files, {sum(map(len, files.values()))} functions, {len(groups)} groups, {len(slices) - len(groups) - 1} loops")


def is_code(line):
    """Neither blank, a comment, nor closing punctuation alone."""
    t = line.strip()
    return bool(t) and not t.startswith("//") and not re.fullmatch(r"[)\]}]+[,;]?", t)


DECL = re.compile(r"(@[\w.]+(\(.*\))?\s+)*((private|fileprivate)\b|((public|internal|final|nonisolated)\s+)*(struct|class|enum|actor|typealias)\b)")


def inert_members(lines):
    """Whether `lines` only declare private members or new types, each complete."""
    depth = 0
    for line in lines:
        t = line.strip()
        if depth == 0 and is_code(line) and not t.startswith(("@", "#")) and not DECL.match(t):
            return False
        depth += t.count("{") + t.count("(") - t.count("}") - t.count(")")
    return depth == 0


def type_scopes(text):
    """(first, last, name) of every type or extension body, by brace depth outside strings and comments."""
    scopes, stack, depth, in_block = [], [], 0, False
    for k, line in enumerate(text.splitlines(), 1):
        if line.count('"""') % 2:
            in_block = not in_block
            continue
        if in_block:
            continue
        code = re.sub(r'"(\\.|[^"\\])*"', '""', line).split("//")[0]
        if decl := re.match(r"\s*(@[\w.]+(\(.*\))?\s+)*((public|internal|private|fileprivate|final|nonisolated|indirect)\s+)*(struct|class|enum|actor|extension|protocol)\s+(\w+)", code):
            stack.append((k, depth, decl.group(6)))
        for ch in code:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if stack and depth == stack[-1][1] and k > stack[-1][0]:
                    first, _, name = stack.pop()
                    scopes.append((first, k, name))
    return scopes


HOOK = re.compile(r"(@[\w.]+(\(.*\))?\s+)*(\w+\s+)*(override\b|@objc\b)|@objc\b")


def hooks(added):
    """Whether `added` declares an override or @objc member at its outermost level: callers it never names."""
    depth, at = 0, []
    for line in added:
        at.append((depth, line.strip()))
        depth += line.count("{") - line.count("}")
    low = min((d for d, _ in at), default=0)
    return any(d == low and HOOK.match(t) for d, t in at)


class Selector:
    def __init__(self, base, head):
        self.base, self.head = base, head
        data = json.load(open(MAP))
        self.sha, self.slices, self.files = data["sha"], data["slices"], data["files"]
        self.bit = {s: i for i, s in enumerate(self.slices)}
        self.groups = sum(1 << i for i, s in enumerate(self.slices) if s != LAUNCH and not s.startswith("loop-"))
        self.launch = 1 << self.bit[LAUNCH]
        self.mask, self.new_groups, self.full, self.notes = 0, set(), [], []
        _, self.callers = suite_table(git("show", f"{head}:{SUITE}"))
        self.since_map, self.scopes = {}, {}

    def map_line(self, path, ref, line):
        """`line` of `path` at `ref`, as a line of the map's sha."""
        if ref == self.sha:
            return line
        if (path, ref) not in self.since_map:
            self.since_map[path, ref] = hunks(self.sha, ref, path)
        return translate(line, self.since_map[path, ref])

    @staticmethod
    def line_mask(funcs, line):
        """Every function a line belongs to, innermost out: a line a function starts or ends on is shared with its parent."""
        mask, inside = None, sorted((f for f in funcs if f[0] <= line <= f[1]), key=lambda f: f[1] - f[0])
        for start, end, m in inside:
            mask = (mask or 0) | int(m, 16)
            if start < line < end:
                break
        return mask

    def file_mask(self, path):
        m = 0
        for f in self.files[path]:
            m |= int(f[2], 16)
        return m

    def add(self, mask, why):
        if mask & self.launch and not mask & ~self.launch:
            self.full.append(f"{why}: runs only at launch")
        else:
            self.mask |= mask
            self.notes.append(f"{why}: {bin(mask & self.groups).count('1')} groups")

    def users(self, path):
        """The functions that name an unmapped file: its top-level types, or a resource's file name."""
        if path.endswith(".swift"):
            text = git("show", f"{self.head}:{path}") if path in git("ls-tree", "-r", "--name-only", self.head, "--", path) else ""
            names = set(re.findall(r"^(?:[a-z@]\w* )*(?:enum|struct|class|actor|protocol|extension|let|var|func) (\w+)", text, re.M))
        else:
            names = {os.path.splitext(os.path.basename(path))[0]}
        mask, hits = 0, 0
        for name in names:
            try:
                found = git("grep", "-n", "-w", "-F", name, self.head, "--", "Artemis/*.swift", "Vendor/*.swift")
            except subprocess.CalledProcessError:
                continue
            for hit in found.splitlines():
                _, where, line, code = hit.split(":", 3)
                if where == path or where not in self.files or not is_code(code):
                    continue
                hits += 1
                at = self.map_line(where, self.head, int(line))
                m = self.line_mask(self.files[where], at) if at else None
                if m is None and at:
                    m = self.scope_mask(where, at)
                mask |= self.file_mask(where) if m is None else m
        return mask if hits else None

    def place(self, path, ref, lines):
        """Map-sha lines for `lines` of `path` at `ref`. A line changed since the map stands for each function
        overlapping the gap between its placeable neighbours; None if none does or a whole one fits in it unheld."""
        out = []
        for line in lines:
            at = self.map_line(path, ref, line)
            if at is not None:
                out.append(at)
                continue
            up = next((a for k in range(line - 1, 0, -1) if (a := self.map_line(path, ref, k)) is not None), 0)
            down = next((a for k in range(line + 1, line + 400) if (a := self.map_line(path, ref, k)) is not None), 10**9)
            lo, hi = (up + 1, down - 1) if up + 1 < down else (up, down)
            over = [f for f in self.files[path] if f[0] <= hi and lo <= f[1]]
            whole = any(lo <= f[0] and f[1] <= hi for f in over) and not any(f[0] < lo and hi < f[1] for f in over)
            out += [None] if whole or not over else [min(f[0] + 1, f[1]) for f in over]
        return out

    def scope_mask(self, path, line):
        """Every function inside the innermost type block around map-sha `line`, or, when none of those ran,
        in every block of that type in the file; None at top level."""
        if path not in self.scopes:
            self.scopes[path] = type_scopes(git("show", f"{self.sha}:{path}"))
        around = [sc for sc in self.scopes[path] if sc[0] <= line <= sc[1]]
        if not around:
            return None
        inner = min(around, key=lambda sc: sc[1] - sc[0])
        mask = 0
        for blocks in ([inner], [sc for sc in self.scopes[path] if sc[2] == inner[2]]):
            for lo, hi, _ in blocks:
                for f in self.files[path]:
                    if lo <= f[0] and f[1] <= hi:
                        mask |= int(f[2], 16)
            if mask:
                break
        return mask

    def change(self, path, status):
        if status in ("A", "D"):
            return self.add(self.file_mask(path), f"{path}: whole file")
        base_text = git("show", f"{self.base}:{path}").splitlines()
        head_text = git("show", f"{self.head}:{path}").splitlines()
        for o, ol, n, nl in hunks(self.base, self.head, path):
            where = f"{path}:{o}"
            removed, added = base_text[o - 1 : o - 1 + ol], head_text[n - 1 : n - 1 + nl]
            if not any(map(is_code, removed + added)):
                continue
            if path == SUITE:
                # table entries and test functions name their groups, whatever the coverage says
                named = {g for line in added for fn in re.findall(r"\b(test[A-Z]\w*)\b", line) for g in self.callers.get(fn, ())}
                named |= {m.group(1) for line in added if (m := ENTRY.match(line))}
                if named:
                    self.new_groups |= named - set(self.bit)
                    self.add(sum(1 << self.bit[g] for g in named if g in self.bit), f"{where} names {','.join(sorted(named))}")
                    continue
            # base side: its code lines, or the two lines an insertion sits between
            olds = [o + i for i, line in enumerate(removed) if is_code(line)] or ([o - 1, o + ol] if ol else [o, o + 1])
            spots = self.place(path, self.base, olds)
            if None not in spots:
                self.lines(path, where, spots, removed, added, ol)
            else:
                self.new_code(path, where, n, nl, added)
            if hooks(added):
                at = spots[0] if None not in spots else self.place(path, self.head, (max(n - 1, 1),))[0]
                mask = self.scope_mask(path, at) if at else None
                self.add(self.file_mask(path) if mask is None else mask, f"{where}: adds an override, its type's functions")

    def lines(self, path, where, spots, removed, added, ol):
        masks = [self.line_mask(self.files[path], line) for line in spots]
        if None not in masks:
            mask = 0
            for m in masks:
                mask |= m
            self.add(mask, where)
        elif not any(map(is_code, removed)) and inert_members(added):
            # new private members, or new types, do nothing until a changed line uses them
            self.notes.append(f"{where}: new private members")
        elif path == SUITE and not ol:
            self.notes.append(f"{where}: new code outside a test")
        elif (mask := self.scope_mask(path, spots[0])) is not None:
            self.add(mask, f"{where}: a declaration, its type's functions")
        else:
            self.add(self.file_mask(path), f"{where}: top-level declaration, whole file")

    def new_code(self, path, where, n, nl, added):
        """A hunk the map postdates: the functions its head-side code sits in, found by its unchanged
        neighbours; functions wholly between them are new and select nothing by themselves."""
        before, after = (n - 1, n + nl) if nl else (n, n + 1)
        up = next((a for k in range(before, 0, -1) if (a := self.map_line(path, self.head, k)) is not None), 0)
        down = next((a for k in range(after, after + 400) if (a := self.map_line(path, self.head, k)) is not None), 10**9)
        edges = [f for f in self.files[path] if f[0] < down and up < f[1] and not (up < f[0] and f[1] <= down)]
        mask = 0
        for f in edges:
            mask |= int(f[2], 16)
        if edges:
            self.add(mask, f"{where}: new code, by the functions around it")
        elif inert_members(added):
            self.notes.append(f"{where}: new private members")
        elif (mask := self.scope_mask(path, up)) is not None:
            self.add(mask, f"{where}: new code, its type's functions")
        else:
            self.full.append(f"{where}: new top-level code the map can't place")

    def run(self):
        for row in git("diff", "--name-status", "--no-renames", self.base, self.head).splitlines():
            status, path = row.split("\t", 1)
            if INERT.search(path):
                continue
            if GLOBAL.search(path):
                self.full.append(f"{path}: build-wide")
            elif path in self.files:
                self.change(path, status)
            elif (mask := self.users(path)) is not None:
                self.add(mask, f"{path}: unmapped, by its users")
            else:
                self.full.append(f"{path}: not in the map and named nowhere")
        groups = [s for i, s in enumerate(self.slices) if self.mask >> i & 1 and self.groups >> i & 1] + sorted(self.new_groups)
        total = bin(self.groups).count("1")
        if len(groups) > THRESHOLD * total:
            self.full.append(f"{len(groups)} of {total} groups is over {THRESHOLD:.0%}")
        loops = [s[5:] for i, s in enumerate(self.slices) if s.startswith("loop-") and self.mask >> i & 1]
        return groups, loops


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select")
    s.add_argument("--base", default="stable")
    s.add_argument("--head", default="HEAD")
    s.add_argument("--perf", action="store_true")
    s.add_argument("-v", action="store_true")
    b = sub.add_parser("build-map")
    for arg in ("slice_dir", "binary", "sha"):
        b.add_argument(arg)
    a = p.parse_args()
    if a.cmd == "build-map":
        return build_map(a.slice_dir, a.binary, a.sha)
    sel = Selector(git("merge-base", a.base, a.head).strip(), a.head)
    groups, loops = sel.run()
    behind = int(git("rev-list", "--count", f"{sel.sha}..{sel.base}"))
    if behind > 50:
        print(f"test-impact: the map is {behind} commits behind; regenerate it with tools/test-impact-map.sh", file=sys.stderr)
    for note in (sel.notes if a.v else []) + [f"FULL {why}" for why in sel.full]:
        print(f"test-impact: {note}", file=sys.stderr)
    if a.perf:
        every = [s[5:] for s in sel.slices if s.startswith("loop-")]
        print(",".join(every if any("over" not in w for w in sel.full) else loops) or "none")
    else:
        print("1" if sel.full else ",".join(groups) or "none")


if __name__ == "__main__":
    main()
