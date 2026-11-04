#!/usr/bin/env python3 -I
"""Regenerate Artemis/models/extensions/compat-gaps.json: every enum, constant
and event of Chrome's extension API, from @types/chrome. The shim fills the ones
WebKit lacks at runtime, so this table never needs to know what WebKit has.
    tools/compat-gaps.py [path/to/chrome.d.ts]"""
import json, os, re, sys, urllib.request

SOURCE = "https://unpkg.com/@types/chrome@0.1.24/index.d.ts"
OUT = os.path.join(os.path.dirname(__file__), "../Artemis/models/extensions/compat-gaps.json")
# ChromeOS, enterprise and app-only namespaces: no desktop extension can use them
SKIP = re.compile(r"^(accessibilityFeatures|audio|certificateProvider|devtools|documentScan|"
                  r"enterprise|events|extensionTypes|fileBrowserHandler|fileSystemProvider|input|"
                  r"instanceID|loginState|platformKeys|printerProvider|printing|printingMetrics|"
                  r"serial|socket|system\.(display|network|storage)|types|vpnProvider|wallpaper|"
                  r"webAuthenticationProxy|ttsEngine)")

text = open(sys.argv[1]).read() if len(sys.argv) > 1 else urllib.request.urlopen(SOURCE).read().decode()
text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
text = re.sub(r"//[^\n]*", "", text)

def blocks(body, keyword):
    """yield (name, inner text, start, end) for each `export <keyword> Name {...}`"""
    for m in re.finditer(r"export (?:declare )?" + keyword + r" ([\w.]+)\s*\{", body):
        depth, i = 1, m.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(body[i], 0)
            i += 1
        yield m.group(1), body[m.end():i - 1], m.start(), i

def top_level(body):
    """the namespace body with nested namespaces cut out"""
    out, last = [], 0
    for _, _, start, end in blocks(body, "namespace"):
        out.append(body[last:start])
        last = end
    return "".join(out) + body[last:]

table = {}
def walk(body, prefix):
    for name, inner, _, _ in blocks(body, "namespace"):
        full = f"{prefix}{name}".replace("_debugger", "debugger")  # a reserved word in the .d.ts
        if prefix == "" and name == "chrome":
            walk(inner, "")
            continue
        if SKIP.match(full):
            continue
        own = top_level(inner)
        entry = {}
        enums = {}
        for ename, ebody, _, _ in blocks(own, "enum"):
            values = dict(re.findall(r"(\w+)\s*=\s*(\"[^\"]*\"|-?\d+)", ebody))
            if values:
                enums[ename] = {k: json.loads(v) for k, v in values.items()}
        consts = {k: json.loads(v) for k, v in
                  re.findall(r"export const ([A-Z][A-Z0-9_]+)\s*[:=]\s*(\"[^\"]*\"|-?\d+)\s*;", own)}
        events = sorted(set(re.findall(r"export (?:const|var|let) (on[A-Z]\w*)\s*:", own)))
        if enums: entry["enums"] = enums
        if consts: entry["consts"] = consts
        if events: entry["events"] = events
        if entry:
            table[full] = entry
        walk(inner, full + ".")

walk(text, "")
with open(OUT, "w") as f:
    json.dump(table, f, separators=(",", ":"), sort_keys=True)
print(f"{len(table)} namespaces, {os.path.getsize(OUT)} bytes → {os.path.relpath(OUT)}")
