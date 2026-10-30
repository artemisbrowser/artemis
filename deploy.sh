#!/bin/bash
# Build Artemis (Release; --debug for Debug), sign it with ARTEMIS_SIGN_IDENTITY
# (Picture in Picture and the extension runtime need a real certificate) and
# install it into /Applications. --run launches it afterwards.
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

CONFIG="Release"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="Debug" ;;
    *) ARGS+=("$arg") ;;
  esac
done

BUILT=".build/Build/Products/$CONFIG/Artemis.app"
INSTALLED="/Applications/Artemis.app"
ENTITLEMENTS=".build/Build/Intermediates.noindex/Artemis.build/$CONFIG/Artemis.build/Artemis.app.xcent"
IDENTITY="${ARTEMIS_SIGN_IDENTITY:-Apple Development}"

echo "→ building ($CONFIG)"
xcodebuild -scheme Artemis -configuration "$CONFIG" -derivedDataPath .build build \
  | grep -E "error:|warning: .*(unused|never)|BUILD" || true

if [[ "$CONFIG" == "Release" ]]; then
  echo "→ keeping the dSYM"
  # crash reports name the binary by UUID, which tools/symbolicate.sh looks up here
  for uuid in $(xcrun dwarfdump --uuid "$BUILT/Contents/MacOS/Artemis" | awk '{print $2}'); do
    mkdir -p "$HOME/Library/Developer/Artemis/dSYMs/$uuid"
    cp -R "$BUILT.dSYM" "$HOME/Library/Developer/Artemis/dSYMs/$uuid/"
  done
fi

echo "→ signing (real cert — PiP and the extension runtime need it)"
codesign --force --deep --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" --generate-entitlement-der "$BUILT"

echo "→ installing to $INSTALLED"
# only the installed copy — it is the one blocking the replace. `-x Artemis`
# would also kill a build running out of a worktree
pkill -f '/Applications/Artemis.app/Contents/MacOS/Artemis' 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"
# make sure Finder/Dock pick up the new icon rather than a cached one
touch "$INSTALLED"

if [[ " ${ARGS[*]-} " == *" --run "* ]]; then
  echo "→ launching"
  open "$INSTALLED"
fi
echo "done"
