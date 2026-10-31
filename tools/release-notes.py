#!/usr/bin/env python3
"""Release notes Markdown (paragraphs, **bold**, - bullets) to the small HTML page
Sparkle's update window shows, styled like the system in light and dark mode.
usage: release-notes.py NOTES.md"""
import html, re, sys

STYLE = (
    "<style>:root{color-scheme:light dark}"
    "body{font:13px -apple-system,system-ui;line-height:1.45;margin:4px 2px}"
    "p{margin:0 0 9px}ul{margin:0 0 9px;padding-left:18px}li{margin:0 0 4px}</style>"
)

def inline(text):
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(text, quote=False))

out, items = [], []
for block in open(sys.argv[1]).read().strip().split("\n\n"):
    lines = block.strip().splitlines()
    if all(l.startswith("- ") for l in lines):
        out.append("<ul>" + "".join(f"<li>{inline(l[2:])}</li>" for l in lines) + "</ul>")
    elif lines[0].startswith("**") and len(lines) > 1 and all(l.startswith("- ") for l in lines[1:]):
        out.append(f"<p>{inline(lines[0])}</p><ul>" + "".join(f"<li>{inline(l[2:])}</li>" for l in lines[1:]) + "</ul>")
    else:
        out.append(f"<p>{inline(' '.join(lines))}</p>")
print(STYLE + "".join(out))
