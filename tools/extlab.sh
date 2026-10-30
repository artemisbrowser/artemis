#!/bin/bash
# Build "Artemis Lab": this tree under its own bundle id, so the extension sweep
# gets a fresh container and never touches the installed app or its data.
#   tools/extlab.sh            build + sign
#   tools/extlab.sh --run      build, sign, start the sweep in the background
#   tools/extlab.sh --launch   start the sweep without rebuilding
# LAB_ID=LabB runs a second lab beside the first (own bundle id and container);
# EXTLAB_ENV="ARTEMIS_EXTLAB_RUN=name" sends its verdicts to runs/name
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

ID="${LAB_ID:-Lab}"
LAB=".build/$ID/Artemis $ID.app"
ENTITLEMENTS=".build/Build/Intermediates.noindex/Artemis.build/Debug/Artemis.build/Artemis.app.xcent"
IDENTITY="${ARTEMIS_SIGN_IDENTITY:-Apple Development}"

if [[ "${1-}" != "--launch" ]]; then
  xcodebuild -scheme Artemis -configuration Debug -derivedDataPath .build build \
    | grep -E "error:|BUILD" | tee /dev/stderr | grep -q "BUILD SUCCEEDED"
  rm -rf "$LAB" && mkdir -p ".build/$ID"
  cp -R .build/Build/Products/Debug/Artemis.app "$LAB"
  # its own executable name, so `pkill -x Artemis` and the lab never touch each other
  mv "$LAB/Contents/MacOS/Artemis" "$LAB/Contents/MacOS/Artemis $ID"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.findles.Artemis.$ID" \
    -c "Set :CFBundleExecutable Artemis $ID" -c "Set :CFBundleName Artemis $ID" \
    -c "Delete :CFBundleURLTypes" -c "Delete :CFBundleDocumentTypes" "$LAB/Contents/Info.plist" || true
  # nothing that can raise a consent prompt or reach the user's own data: no
  # Downloads, camera, microphone, location, Arc folder or installed app; one
  # sandbox exception for the lab folder in /private/tmp, which macOS never guards
  LAB_ENTITLEMENTS=".build/$ID/lab.entitlements"
  cp "$ENTITLEMENTS" "$LAB_ENTITLEMENTS"
  for key in com.apple.security.files.downloads.read-write com.apple.security.device.camera \
    com.apple.security.device.audio-input com.apple.security.personal-information.location \
    com.apple.security.temporary-exception.files.home-relative-path.read-only \
    com.apple.security.temporary-exception.files.absolute-path.read-write; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$LAB_ENTITLEMENTS" 2>/dev/null || true
  done
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write array" \
    -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write:0 string /private/tmp/artemis-extlab/" \
    "$LAB_ENTITLEMENTS"
  codesign --force --deep --sign "$IDENTITY" \
    --entitlements "$LAB_ENTITLEMENTS" --generate-entitlement-der "$LAB"
fi

if [[ "${1-}" == "--run" || "${1-}" == "--launch" ]]; then
  pkill -f "$LAB/Contents/MacOS/Artemis $ID" 2>/dev/null || true
  sleep 1
  open -g -n --env ARTEMIS_DIAG=extlab ${EXTLAB_ENV:+--env "$EXTLAB_ENV"} "$LAB"
fi
