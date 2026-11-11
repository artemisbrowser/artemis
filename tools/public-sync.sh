#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Mirror this checkout's HEAD into a clone of the public repo as one commit, behind the publish gates.
#   tools/public-sync.sh CLONE MESSAGE_FILE
# Commits in CLONE without pushing; does nothing when the public tree already matches.
set -euo pipefail
cd "$(dirname "$0")/.."
(($# == 2)) || { sed -n 2,4p "$0"; exit 2; }
CLONE=$1 MSG=$2
R=${ARTEMIS_RELEASE_DIR:-"$HOME/Library/Application Support/ArtemisRelease"}
PATHS=(Artemis Artemis.xcodeproj ArtemisDockTile AppIcon.icon Vendor docs tools feedback deploy.sh xcede.yml .prettierignore CLA.md LICENSE THIRD-PARTY-NOTICES.md)
fail() { echo "public-sync: $*" >&2; exit 1; }
# 0 when the search finds something and 1 when it finds nothing; anything else stops the sync
found() { local rc=0; "$@" >&2 || rc=$?; ((rc <= 1)) || fail "$1 failed ($rc)"; return $rc; }

# nothing public may hold a private name, the legal surname or a word listed in $R/leak-words
names=$("$R/private-gate" names) notes=$("$R/private-gate" notes)
surname=$(id -F | awk '{print $NF}')
[[ -n $names && -n $notes && -n $surname && -s $R/leak-words ]] || fail "missing the names lists, the surname or $R/leak-words"
# the message is also the release notes, the appcast entry and the Discord post
found grep -inE "$notes" "$MSG" && fail "the notes hold a private name"
found grep -inFf "$R/leak-words" "$MSG" && fail "the notes hold a word from leak-words"
found grep -qiw -- "$surname" "$MSG" && fail "the notes hold the legal name"

[[ -z $(git status --porcelain) ]] || fail "the checkout has uncommitted changes"
"$R/private-gate" check >/dev/null || fail "$R/private-gate check failed"
TREE=$(mktemp -d)
trap 'rm -rf "$TREE"' EXIT
git archive HEAD -- "${PATHS[@]}" | tar -x -C "$TREE"
"$R/private-gate" strip "$TREE" || fail "$R/private-gate strip failed"
while IFS= read -r -d '' file; do python3 -I "$R/strip_ios.py" "$file"; done < <(grep -rlE --null --exclude-dir=Vendor \
  --include='*.swift' --include='*.h' --include='*.m' '^[[:space:]]*#(if|elseif).*(os\(|canImport\((AppKit|UIKit)\))' "$TREE" || true)

for p in "${PATHS[@]}"; do
  if [[ -d $TREE/$p ]]; then rsync -a --delete "$TREE/$p/" "$CLONE/$p/"; else cp "$TREE/$p" "$CLONE/$p"; fi
done
python3 -I "$R/add_headers.py" "$CLONE" >/dev/null
git -C "$CLONE" add -- "${PATHS[@]}"
# the public tree holds exactly the private files: nothing ignored away, nothing left behind
diff <(cd "$TREE" && find "${PATHS[@]}" ! -type d | sort) \
  <(git -C "$CLONE" -c core.quotepath=off ls-files -- "${PATHS[@]}" | sort) >&2 || fail "file lists differ"
git -C "$CLONE" diff --cached --quiet && exit 0

# renames, binaries and empty files add no lines, so the changed paths are searched as well
added=$(git -C "$CLONE" -c core.quotepath=off diff --cached --name-only --no-renames --diff-filter=d
  git -C "$CLONE" diff --cached -U0 --no-renames -- . ':(exclude)Artemis/models/IconKeywords.swift' ':(exclude)Vendor' | grep '^+' || true)
found grep -inE "$names" <<<"$added" && fail "a private name would go public"
found grep -inFf "$R/leak-words" <<<"$added" && fail "a word from leak-words would go public"
found grep -qi -- "$surname" <<<"$(git -C "$CLONE" -c core.quotepath=off ls-files)" && fail "the legal name is in a public path"
found git -C "$CLONE" grep --cached -qiw -- "$surname" && fail "the legal name is in the public tree"
git -C "$CLONE" -c user.name=Fin -c user.email=188496222+devfindles@users.noreply.github.com commit -q -F "$MSG"
