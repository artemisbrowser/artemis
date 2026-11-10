#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

"""Release notes Markdown (## and ### headings, paragraphs, **bold**, [links](https://…), - bullets) to the small HTML page
Sparkle's update window shows, styled like the system in light and dark mode.
usage: release-notes.py NOTES.md"""
import html, re, sys

STYLE = (
    "<style>:root{color-scheme:light dark}"
    "body{font:13px -apple-system,system-ui;line-height:1.45;margin:4px 2px}"
    "p{margin:0 0 9px}ul{margin:0 0 9px;padding-left:18px}li{margin:0 0 4px}"
    "h2{font-size:15px;margin:14px 0 6px}h3{font-size:13px;margin:10px 0 4px}</style>"
)

def inline(text):
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(text, quote=False))
    return re.sub(r"\[([^\[\]]+)\]\((https://[^\s()\"<>]+)\)", r'<a href="\2">\1</a>', text)

out = []
for block in open(sys.argv[1]).read().strip().split("\n\n"):
    lines = block.strip().splitlines()
    while lines and lines[0].startswith(("## ", "### ")):
        level, text = lines.pop(0).split(" ", 1)
        out.append(f"<h{len(level)}>{inline(text)}</h{len(level)}>")
    if not lines:
        continue
    if all(l.startswith("- ") for l in lines):
        out.append("<ul>" + "".join(f"<li>{inline(l[2:])}</li>" for l in lines) + "</ul>")
    elif lines[0].startswith("**") and len(lines) > 1 and all(l.startswith("- ") for l in lines[1:]):
        out.append(f"<p>{inline(lines[0])}</p><ul>" + "".join(f"<li>{inline(l[2:])}</li>" for l in lines[1:]) + "</ul>")
    else:
        out.append(f"<p>{inline(' '.join(lines))}</p>")
print(STYLE + "".join(out))
