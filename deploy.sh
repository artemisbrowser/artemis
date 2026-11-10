#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Build Artemis (Release; --debug for Debug), sign it with ARTEMIS_SIGN_IDENTITY (the extension runtime needs a real
# certificate) and install it into /Applications. Flags: --run, --no-install, --install-only, --any-tree.
# With `git config artemis.installFrom <branch>`, installs come only from a clean checkout of <branch>.
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

CONFIG="Release" BUILD=1 INSTALL=1 RUN=0 ANY_TREE=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="Debug" ;;
    --run) RUN=1 ;;
    --no-install) INSTALL=0 ;;
    --install-only) BUILD=0 ;;
    --any-tree) ANY_TREE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

BUILT=".build/Build/Products/$CONFIG/Artemis.app"
INSTALLED="/Applications/Artemis.app"
ENTITLEMENTS=".build/Build/Intermediates.noindex/Artemis.build/$CONFIG/Artemis.build/Artemis.app.xcent"
# a worktree has no .signing-identity of its own, so fall back to the main checkout's
IDENTITY="${ARTEMIS_SIGN_IDENTITY:-$(cat "$(git rev-parse --show-toplevel)/.signing-identity" 2>/dev/null \
  || cat "$(git rev-parse --path-format=absolute --git-common-dir)/../.signing-identity" 2>/dev/null || echo "Apple Development")}"

PIN=$(git config artemis.installFrom || true)
if (( INSTALL && !ANY_TREE )) && [[ -n "$PIN" ]] && ! { [[ "$(git branch --show-current)" == "$PIN" ]] && git diff --quiet HEAD; }; then
  echo "refusing to install: this is not a clean checkout of $PIN (--any-tree overrides)" >&2
  exit 1
fi

if (( BUILD )); then
  echo "→ building ($CONFIG)"
  xcodebuild -scheme Artemis -configuration "$CONFIG" -derivedDataPath .build build \
    | { grep -E "error:|warning: .*(unused|never)|BUILD" || true; }
  plutil -replace ArtemisGitSHA -string "$(git rev-parse --short=8 HEAD)$(git diff --quiet HEAD || echo -dirty)" "$BUILT/Contents/Info.plist"

  if [[ "$CONFIG" == "Release" ]]; then
    echo "→ keeping the dSYM"
    # crash reports name the binary by UUID, which tools/symbolicate.sh looks up here
    for uuid in $(xcrun dwarfdump --uuid "$BUILT/Contents/MacOS/Artemis" | awk '{print $2}'); do
      mkdir -p "$HOME/Library/Developer/Artemis/dSYMs/$uuid"
      cp -R "$BUILT.dSYM" "$HOME/Library/Developer/Artemis/dSYMs/$uuid/"
    done
  fi

  echo "→ signing (real cert — the extension runtime needs it)"
  codesign --force --deep --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" --generate-entitlement-der "$BUILT"
fi
(( INSTALL )) || { echo "built $BUILT ($(defaults read "$PWD/$BUILT/Contents/Info" ArtemisGitSHA))"; exit 0; }
codesign --verify "$BUILT"

echo "→ installing to $INSTALLED"
# quit politely so the session is saved; kill only the installed copy, never a build running from a worktree
if [[ -d "$INSTALLED" ]]; then
  BUNDLE_ID=$(defaults read "$INSTALLED/Contents/Info" CFBundleIdentifier)
  osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" || true
  for _ in {1..30}; do pgrep -qf "^$INSTALLED/Contents/MacOS/" || break; sleep 1; done
  pkill -f "^$INSTALLED/Contents/MacOS/" && sleep 1 || true
fi
rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"
# make sure Finder/Dock pick up the new icon rather than a cached one
touch "$INSTALLED"

if (( RUN )); then
  echo "→ launching"
  open "$INSTALLED"
fi
echo "done: $(defaults read "$INSTALLED/Contents/Info" ArtemisGitSHA)"
