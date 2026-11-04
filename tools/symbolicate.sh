#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Symbolicate the crashes in an Artemis report: tools/symbolicate.sh report.json
# Walks each attributed thread innermost-first; frames whose binary has a dSYM
# that deploy.sh kept (filed by UUID) are resolved with atos.
set -euo pipefail
/usr/bin/python3 -I - "$1" "$HOME/Library/Developer/Artemis/dSYMs" <<'PY'
import json, os, subprocess, sys

report, dsyms = json.load(open(sys.argv[1])), sys.argv[2]
for crash in report.get("crashes") or [{"summary": "", "payload": report}]:
    print(crash["summary"])
    stacks = crash["payload"].get("callStackTree", {}).get("callStacks", [])
    stack = next((s for s in stacks if s.get("threadAttributed")), stacks[0] if stacks else {})
    frame = (stack.get("callStackRootFrames") or [None])[0]
    while frame:
        offset, binary = frame["offsetIntoBinaryTextSegment"], frame.get("binaryName", "?")
        dwarf = f'{dsyms}/{frame.get("binaryUUID")}/Artemis.app.dSYM/Contents/Resources/DWARF/Artemis'
        symbol = f"+{offset}"
        if os.path.exists(dwarf):
            symbol = subprocess.run(
                ["atos", "-arch", report.get("arch", "arm64"), "-o", dwarf, "-l", "0x100000000",
                 hex(0x100000000 + offset)], capture_output=True, text=True).stdout.strip()
        print(f"  {binary:<28} {symbol}")
        frame = (frame.get("subFrames") or [None])[0]
PY
