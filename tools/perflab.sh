#!/bin/bash
# Build "Artemis Perf": this tree's Release build under its own bundle id, so
# benches get a throwaway container and never touch the installed app or its data.
#   tools/perflab.sh                       build + sign
#   tools/perflab.sh --copy                sign the existing product, no build
#   tools/perflab.sh --run <env...>        start it with ARTEMIS_DIAG=perf plus <env>
# PERF_ID=PerfB keeps a second arm beside the first (own bundle id and container)
# PERF_CONFIG=Debug builds Debug instead, for iterating on a lab test
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

ID="${PERF_ID:-Perf}"
CONFIG="${PERF_CONFIG:-Release}"
APP=".build/$ID/Artemis $ID.app"
ENTITLEMENTS=".build/Build/Intermediates.noindex/Artemis.build/$CONFIG/Artemis.build/Artemis.app.xcent"
# a worktree has no .signing-identity of its own, so fall back to the main checkout's
IDENTITY="${ARTEMIS_SIGN_IDENTITY:-$(cd "$(dirname "$0")" && cat "$(git rev-parse --show-toplevel)/.signing-identity" 2>/dev/null \
  || cat "$(git rev-parse --path-format=absolute --git-common-dir)/../.signing-identity" 2>/dev/null || echo "Apple Development")}"
OUT=/private/tmp/artemis-perf
mkdir -p "$OUT"

if [[ "${1-}" != "--run" ]]; then
  if [[ "${1-}" != "--copy" ]]; then
    xcodebuild -scheme Artemis -configuration "$CONFIG" -derivedDataPath .build build \
      | grep -E "error:|BUILD" | tee /dev/stderr | grep -q "BUILD SUCCEEDED"
  fi
  rm -rf "$APP" && mkdir -p ".build/$ID"
  cp -R ".build/Build/Products/$CONFIG/Artemis.app" "$APP"
  mv "$APP/Contents/MacOS/Artemis" "$APP/Contents/MacOS/Artemis $ID"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.findles.Artemis.$ID" \
    -c "Set :CFBundleExecutable Artemis $ID" -c "Set :CFBundleName Artemis $ID" \
    -c "Delete :CFBundleURLTypes" -c "Delete :CFBundleDocumentTypes" "$APP/Contents/Info.plist" || true
  # same fence as tools/extlab.sh: nothing that can prompt or reach the user's data
  PERF_ENTITLEMENTS=".build/$ID/perf.entitlements"
  cp "$ENTITLEMENTS" "$PERF_ENTITLEMENTS"
  for key in com.apple.security.files.downloads.read-write com.apple.security.device.camera \
    com.apple.security.device.audio-input com.apple.security.personal-information.location \
    com.apple.security.temporary-exception.files.home-relative-path.read-only \
    com.apple.security.temporary-exception.files.absolute-path.read-write; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PERF_ENTITLEMENTS" 2>/dev/null || true
  done
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write array" \
    -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write:0 string $OUT/" \
    "$PERF_ENTITLEMENTS"
  codesign --force --deep --sign "$IDENTITY" \
    --entitlements "$PERF_ENTITLEMENTS" --generate-entitlement-der "$APP"
fi

if [[ "${1-}" == "--run" ]]; then
  shift
  pkill -f "$APP/Contents/MacOS/Artemis $ID" 2>/dev/null || true
  sleep 1
  args=(--env ARTEMIS_DIAG=perf --env "ARTEMIS_BENCH_DIR=$OUT")
  for kv in "$@"; do args+=(--env "$kv"); done
  open -g -n "${args[@]}" "$APP"
fi
