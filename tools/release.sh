#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Publish a tester release of Artemis: build, DMG, Sparkle signature, GitHub
# release, appcast entry and the site's download link.
#
#   tools/release.sh VERSION N CHANNEL NOTES.md [--dry-run]
#     VERSION  x.y.z (CFBundleShortVersionString)
#     N        1-99, the build of that version; CFBundleVersion = x*1e6 + y*1e4 + z*100 + N
#     CHANNEL  release | beta (beta items reach only users on the Beta channel)
#     --dry-run builds, signs and writes the appcast locally; publishes nothing
#
# Needs: ~/Library/Application Support/ArtemisRelease/{sparkle_ed25519, sparkle/bin, venv}
# and a checkout of the public repo at $ARTEMIS_PUBLIC (default ~/artemis).
set -euo pipefail
cd "$(dirname "$0")/.."

(($# >= 4)) || { sed -n 2,11p "$0"; exit 2; }
VERSION=$1 N=$2 CHANNEL=$3 NOTES=$4 DRY=${5:-}
[[ -z $DRY || $DRY == --dry-run ]] || { echo "the fifth argument can only be --dry-run" >&2; exit 2; }
[[ $VERSION =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "VERSION must be x.y.z" >&2; exit 2; }
((N >= 1 && N <= 99)) || { echo "N must be 1-99" >&2; exit 2; }
[[ $CHANNEL == release || $CHANNEL == beta ]] || { echo "CHANNEL must be release or beta" >&2; exit 2; }
[[ -f $NOTES ]] || { echo "no notes file $NOTES" >&2; exit 2; }
BUILD=$((BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 10000 + BASH_REMATCH[3] * 100 + N))

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
R="$HOME/Library/Application Support/ArtemisRelease"
KEY="$R/sparkle_ed25519"
PUBLIC="${ARTEMIS_PUBLIC:-$HOME/artemis}"
TEAM=Z49XSUZ64Q
FEED=https://artemisbrowser.app/appcast.xml
SUFFIX=""
if ((N > 1)); then SUFFIX="-$N"; fi
TAG="v$VERSION$SUFFIX"
ASSET="Artemis-$VERSION$SUFFIX.dmg"
BETA=""
if [[ $CHANNEL == beta ]]; then BETA=" (beta)"; fi
URL="https://github.com/artemisbrowser/artemis/releases/download/$TAG/$ASSET"
OUT="$R/out/$TAG"
APPCAST="$PUBLIC/website/src/static/appcast.xml"

[[ -f $KEY ]] || { echo "missing $KEY" >&2; exit 1; }
if [[ -z $DRY ]] && gh release view "$TAG" -R artemisbrowser/artemis >/dev/null 2>&1; then
  echo "$TAG already released" >&2; exit 1
fi
if [[ -f $APPCAST ]] && grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"; then
  echo "build $BUILD is already in the appcast" >&2; exit 1
fi

echo "→ Artemis $VERSION ($BUILD), $CHANNEL"
rm -rf "$OUT" && mkdir -p "$OUT"
APP="$R/build/Build/Products/Release/Artemis.app"
rm -rf "$APP"
# no get-task-allow (CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO); Xcode signs Sparkle's helpers inside-out
xcodebuild -scheme Artemis -configuration Release -derivedDataPath "$R/build" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARTEMIS_BUNDLE_ID=app.artemisbrowser.Artemis ARTEMIS_FEED_URL=$FEED \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION=$BUILD ARCHS=arm64 build >"$OUT/build.log" 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$OUT/build.log" || true
grep -q "BUILD SUCCEEDED" "$OUT/build.log" || { echo "build failed, see $OUT/build.log" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]]
# captured, not piped: grep -q stops reading early and pipefail counts the writer's SIGPIPE
[[ "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" != *get-task-allow* ]]
[[ "$(codesign -dvv "$APP" 2>&1)" == *"TeamIdentifier=$TEAM"* ]]

echo "→ DMG"
swift tools/dmg/background.swift "$OUT" && tiffutil -cathidpicheck "$OUT/bg.png" "$OUT/bg@2x.png" -out "$OUT/bg.tiff" >/dev/null
# unsigned on purpose: a signed but un-notarised DMG is itself blocked by Gatekeeper
"$R/venv/bin/dmgbuild" -s tools/dmg/settings.py -D app="$APP" -D bg="$OUT/bg.tiff" "Artemis $VERSION" "$OUT/$ASSET" >/dev/null
hdiutil verify "$OUT/$ASSET" >/dev/null

echo "→ Sparkle signature"
SIG=$("$R/sparkle/bin/sign_update" --ed-key-file "$KEY" "$OUT/$ASSET")
CHANNEL_TAG=""
if [[ $CHANNEL == beta ]]; then CHANNEL_TAG="<sparkle:channel>beta</sparkle:channel>"; fi
ITEM="    <item>
      <title>Artemis $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$(python3 tools/release-notes.py "$NOTES")]]></description>
      $CHANNEL_TAG
      <enclosure url=\"$URL\" type=\"application/octet-stream\" $SIG />
    </item>"
echo "$ITEM" > "$OUT/item.xml"

if [[ -n $DRY ]]; then echo "dry run: $OUT"; exit 0; fi

echo "→ GitHub release $TAG"
gh release create "$TAG" "$OUT/$ASSET" -R artemisbrowser/artemis --title "Artemis $VERSION$BETA (alpha)" \
  --notes-file "$NOTES" --prerelease --target main >/dev/null
curl -sfIL -o /dev/null "$URL"

echo "→ appcast and site"
git -C "$PUBLIC" pull -q --ff-only
if [[ ! -f $APPCAST ]]; then
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' \
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
    '  <channel>' '    <title>Artemis</title>' '    <!-- items -->' '  </channel>' '</rss>' > "$APPCAST"
fi
# newest first, under the marker
python3 - "$APPCAST" "$OUT/item.xml" <<'PY'
import sys
path, item = sys.argv[1], open(sys.argv[2]).read()
s = open(path).read()
assert s.count("<!-- items -->") == 1
open(path, "w").write(s.replace("<!-- items -->", "<!-- items -->\n" + item.rstrip("\n")))
PY
xmllint --noout "$APPCAST"
if [[ $CHANNEL == release ]]; then
  sed -i '' "s#^export const DOWNLOAD_URL = .*#export const DOWNLOAD_URL = \"$URL\";#" "$PUBLIC/website/src/site.config.mjs"
fi
(cd "$PUBLIC/website" && node build.mjs --check | grep -E "^fail|check:" && node build.mjs >/dev/null)
git -C "$PUBLIC" add website/src/static/appcast.xml website/src/site.config.mjs
git -C "$PUBLIC" -c user.name=Fin -c user.email=188496222+devfindles@users.noreply.github.com \
  commit -q -m "release: Artemis $VERSION ($BUILD), $CHANNEL"
git -C "$PUBLIC" push -q origin main
(cd "$PUBLIC/website" && npx --yes wrangler@4 deploy | grep "Current Version")
echo "done: $URL"
