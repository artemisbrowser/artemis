#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Build "Artemis Perf": this tree's Release build under its own bundle id, so
# benches get a throwaway container and never touch the installed app or its data.
#   tools/perflab.sh                       build + sign
#   tools/perflab.sh --copy                sign the existing product, no build
#   tools/perflab.sh --run <env...>        start it with ARTEMIS_DIAG=perf plus <env>
#   tools/perflab.sh --lists               give the lab the shipped app's block lists, as --run does
# --run seeds the lists and returns once their rules are compiled; a self-test launch gets neither
# PERF_ID=PerfB keeps a second arm beside the first (own bundle id and container)
# PERF_CONFIG=Debug builds Debug instead, for iterating on a lab test
# PERF_COVERAGE=1 adds coverage counters and ARTEMIS_COVERAGE (tools/test-impact-map.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ID="${PERF_ID:-Perf}"
CONFIG="${PERF_CONFIG:-Release}"
APP=".build/$ID/Artemis $ID.app"
ENTITLEMENTS=".build/Build/Intermediates.noindex/Artemis.build/$CONFIG/Artemis.build/Artemis.app.xcent"
# a worktree has no .signing-identity of its own, so fall back to the main checkout's
IDENTITY="${ARTEMIS_SIGN_IDENTITY:-$(cd "$(dirname "$0")" && cat "$(git rev-parse --show-toplevel)/.signing-identity" 2>/dev/null \
  || cat "$(git rev-parse --path-format=absolute --git-common-dir)/../.signing-identity" 2>/dev/null || echo "Apple Development")}"
OUT=/private/tmp/artemis-perf
mkdir -p "$OUT"
BID="dev.findles.Artemis.$ID"
CACHE="$HOME/.cache/artemis/blocklists"

if [[ "${1-}" == "--lists" ]]; then
  # one holder at a time, so a stale cache is fetched once however many labs start
  mkdir -p "$CACHE"
  [[ -n "${PERFLAB_LISTS_LOCKED-}" ]] || PERFLAB_LISTS_LOCKED=1 exec lockf -k "$CACHE/.lock" bash "tools/$(basename "$0")" --lists
  # id and URL of each list in ContentBlocker.adLists
  lists=$(awk '/static let adLists/,/^    \]/' Artemis/models/extensions/ContentBlocker.swift \
    | grep -oE '(id: |URL\(string: )"[^"]*"' | cut -d'"' -f2 | paste - -)
  [[ -n "$lists" ]] || { echo "perflab: no lists found in ContentBlocker.adLists" >&2; exit 1; }
  due=$(find "$CACHE/.fetched" -mmin -1440 2>/dev/null | grep -q . || echo 1)
  lab="$HOME/Library/Application Support/$BID/blocklists"
  mkdir -p "$lab"
  changed=
  while read -r id url; do
    if [[ -n "$due" || ! -s "$CACHE/$id.txt" ]]; then
      echo "perflab: fetching $id"
      if curl -fsSL --compressed --max-time 60 -o "$CACHE/$id.new" "$url" && [[ -s "$CACHE/$id.new" ]]; then
        mv "$CACHE/$id.new" "$CACHE/$id.txt"
      else
        echo "perflab: $id not fetched" >&2
      fi
    fi
    [[ -s "$CACHE/$id.txt" ]] || continue
    cmp -s "$CACHE/$id.txt" "$lab/$id.txt" || { cp -p "$CACHE/$id.txt" "$lab/$id.txt"; changed=1; }
  done <<< "$lists"
  [[ -z "$due" ]] || touch "$CACHE/.fetched"
  # launch reuses the compiled rules these keys name, whatever the copies say
  if [[ -n "$changed" ]]; then
    for key in contentBlockingCompiledIDs contentBlockingCompiledStats; do defaults delete "$BID" $key 2>/dev/null || true; done
  fi
  exit 0
fi

if [[ "${1-}" != "--run" ]]; then
  if [[ "${1-}" != "--copy" ]]; then
    coverage=()
    [[ -n "${PERF_COVERAGE-}" ]] && coverage=(CLANG_COVERAGE_MAPPING=YES CLANG_ENABLE_CODE_COVERAGE=YES 'OTHER_SWIFT_FLAGS=$(inherited) -DARTEMIS_COVERAGE')
    xcodebuild -scheme Artemis -configuration "$CONFIG" -derivedDataPath .build build \
      ${coverage[@]+"${coverage[@]}"} \
      | grep -E "error:|BUILD" | tee /dev/stderr | grep -q "BUILD SUCCEEDED"
  fi
  rm -rf "$APP" && mkdir -p ".build/$ID"
  cp -R ".build/Build/Products/$CONFIG/Artemis.app" "$APP"
  mv "$APP/Contents/MacOS/Artemis" "$APP/Contents/MacOS/Artemis $ID"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" \
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
  seeded=1; [[ " $* " != *" ARTEMIS_SELFTEST="* ]] || seeded=
  [[ -z "$seeded" ]] || bash "tools/$(basename "$0")" --lists
  open -g -n "${args[@]}" "$APP"
  if [[ -n "$seeded" && "$(defaults read "$BID" contentBlockingEnabledV1 2>/dev/null)" != 0 ]]; then
    SECONDS=0
    until rules=$(defaults read "$BID" contentBlockingCompiledStats 2>/dev/null | sed -n '2s/[ ,]//gp') && [[ -n "$rules" ]]; do
      (( SECONDS < 180 )) || { echo "perflab: no rules compiled after 180s" >&2; exit 1; }
      sleep 0.5
    done
    echo "perflab: $rules rules active after ${SECONDS}s"
  fi
fi
