#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Publish a build of Artemis: the public source, a Release build of it, the DMG, the Sparkle signature,
# the GitHub release, the appcast, the site and the Discord post.
#
#   tools/release.sh VERSION N CHANNEL NOTES.md [--dry-run]   a release or beta of this commit
#   tools/release.sh nightly NOTES.md [--dry-run]             a nightly: <highest build in the appcast>.<YYMMDDHH>
#   tools/release.sh prepare ARGS...                          either of those, stopping before anything leaves the Mac
#   tools/release.sh publish DIR [--dry-run]                  publish the candidate prepare left in DIR
#   tools/release.sh pull DIR [--dry-run]                     take a published nightly back off the appcast
#     VERSION  x.y.z (CFBundleShortVersionString)
#     N        1-99, the build of that version; CFBundleVersion = x*1e6 + y*1e4 + z*100 + N
#     CHANNEL  release | beta (beta items reach users on the Beta and Nightly channels)
#     --dry-run prints each outward step instead of running it; pushes to a local ARTEMIS_PUBLIC_REMOTE still run
#   COLLAGE=spec.json the Discord post's feature collage: required for release, with "approved": true
#
# Needs $R = ~/Library/Application Support/ArtemisRelease with sparkle_ed25519, sparkle/bin, venv, strip_ios.py,
# add_headers.py, leak-words and private-gate. ARTEMIS_RELEASE_DIR (another $R) and ARTEMIS_PUBLIC_REMOTE (a local bare repo, with
# its own $R) are for dry runs only.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { sed -n 2,18p "$0"; exit 2; }
die() { echo "$*" >&2; exit 1; }
# every assertion carries its own || die: bash 3.2's errexit ignores a failing [[ or ((
(($#)) || usage
MODE=all
if [[ $1 == prepare || $1 == publish || $1 == pull ]]; then MODE=$1; shift; fi
DRY=""
if [[ ${!#} == --dry-run ]]; then DRY=1; set -- "${@:1:$#-1}"; fi
[[ -n $DRY || -z ${ARTEMIS_RELEASE_DIR:-}${ARTEMIS_PUBLIC_REMOTE:-} ]] ||
  die "ARTEMIS_RELEASE_DIR and ARTEMIS_PUBLIC_REMOTE only go with --dry-run"
[[ -z ${ARTEMIS_PUBLIC_REMOTE:-} || -n ${ARTEMIS_RELEASE_DIR:-} ]] ||
  die "ARTEMIS_PUBLIC_REMOTE needs its own ARTEMIS_RELEASE_DIR, away from the real candidates and published.log"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export ARTEMIS_RELEASE_DIR=${ARTEMIS_RELEASE_DIR:-"$HOME/Library/Application Support/ArtemisRelease"}
R=$ARTEMIS_RELEASE_DIR
REMOTE=${ARTEMIS_PUBLIC_REMOTE:-https://github.com/artemisbrowser/artemis.git}
REPO=artemisbrowser/artemis
TEAM=Z49XSUZ64Q
FEED=https://artemisbrowser.app/appcast.xml
FIN=(-c user.name=Fin -c user.email=188496222+devfindles@users.noreply.github.com)

out() { if [[ -n $DRY ]]; then printf 'would run:'; printf ' %q' "$@"; echo; else "$@"; fi; }
push() { if [[ $REMOTE == /* ]]; then git -C "$PUB" push -q origin "$1"; else out git -C "$PUB" push -q origin "$1"; fi; }
# lock FILE [wait]: FILE's flock for as long as this shell's fd 9 stays open; one already held exits 75 unless told to wait
lock() {
  exec 9>>"$1"
  python3 -c 'import fcntl, sys
try: fcntl.flock(9, fcntl.LOCK_EX | (0 if sys.argv[2] else fcntl.LOCK_NB))
except BlockingIOError: print("another release.sh holds", sys.argv[1], file=sys.stderr); sys.exit(75)' "$1" "${2:-}" || exit
}
# the live feed, past any cached copy, still lists $ENCLOSURE
offered() {
  local feed
  feed=$(curl -sfL --max-time 30 "$FEED?pulled=$N.$(date +%s)") || die "can't read $FEED"
  grep -qF -- "$ENCLOSURE" <<<"$feed"
}

prepare() {
  if [[ $1 == nightly ]]; then
    (($# == 2)) || usage
    CHANNEL=nightly NOTES=$2
  else
    (($# == 4)) || usage
    VERSION=$1 N=$2 CHANNEL=$3 NOTES=$4
    [[ $VERSION =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "VERSION must be x.y.z"
    ((N >= 1 && N <= 99)) || die "N must be 1-99"
    [[ $CHANNEL == release || $CHANNEL == beta ]] || die "CHANNEL must be release or beta"
    BUILD=$((BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 10000 + BASH_REMATCH[3] * 100 + N))
  fi
  [[ -f $NOTES ]] || die "no notes file $NOTES"
  # a release from the private tree announces itself on Discord, and that post needs a collage Fin approved
  COLLAGE=${COLLAGE:+$(cd "$(dirname "$COLLAGE")" && pwd)/$(basename "$COLLAGE")}
  if [[ $CHANNEL == release && -f discord/release/post.mjs ]]; then
    [[ -n $COLLAGE && -f $COLLAGE ]] && grep -q '"approved": *true' "$COLLAGE" ||
      die "a release needs COLLAGE=spec.json, with \"approved\": true once Fin has seen it"
  fi
  [[ -f $R/sparkle_ed25519 ]] || die "missing $R/sparkle_ed25519"

  mkdir -p "$R/out"
  CLONE=$(mktemp -d "$R/out/clone.XXXXXX")
  trap 'rm -rf "$CLONE"' EXIT
  git clone -q "$REMOTE" "$CLONE"
  APPCAST=$CLONE/website/src/static/appcast.xml
  if [[ $CHANNEL == nightly ]]; then
    read -r TOP VERSION < <(python3 - "$APPCAST" <<'PY'
import re, sys
items = re.findall(r"<item>.*?</item>", open(sys.argv[1]).read(), re.S)
tag = lambda t, s: re.search(f"<sparkle:{t}>([^<]+)</sparkle:{t}>", s).group(1)
top = max(items, key=lambda s: [int(x) for x in tag("version", s).split(".")])
print(tag("version", top).split(".")[0], tag("shortVersionString", top))
PY
    )
    N=$(date +%y%m%d%H)
    BUILD=$TOP.$N TAG=v$VERSION-nightly.$N NAME="Artemis $VERSION-nightly.$N"
  else
    TAG=v$VERSION NAME="Artemis $VERSION"
    if ((N > 1)); then TAG+=-$N; fi
    if [[ $CHANNEL == beta ]]; then NAME+=" (beta)"; fi
  fi
  ASSET=Artemis-${TAG#v}.dmg
  URL=https://github.com/$REPO/releases/download/$TAG/$ASSET
  if [[ -z $DRY ]] && gh release view "$TAG" -R $REPO >/dev/null 2>&1; then die "$TAG already released"; fi
  ! grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" || die "build $BUILD is already in the appcast"

  echo "→ $NAME ($BUILD), $CHANNEL"
  OUT=$R/out/$TAG
  rm -rf "$OUT" && mkdir -p "$OUT" && mv "$CLONE" "$OUT/public"
  PUB=$OUT/public
  cp "$NOTES" "$OUT/notes.md"
  cp "$NOTES" "$OUT/notes-discord.md"
  # a nightly opens with the last publish it's new since: its GitHub release, or in Discord its post
  if [[ $CHANNEL == nightly && -s $R/published.log ]]; then
    read -r _ PREV _ _ _ PREV_POST PREV_NAME <<<"$(tail -1 "$R/published.log")"
    PREV_NAME=${PREV_NAME:-the last update} PREV_RELEASE=https://github.com/$REPO/releases/tag/$PREV
    LEAD="[$PREV_NAME]($PREV_RELEASE)."
    printf 'New since %s\n\n' "$LEAD" | cat - "$NOTES" >"$OUT/notes.md"
    # Discord renders a bare message link as a chip
    if [[ ${PREV_POST:--} != - ]]; then LEAD=$PREV_POST; fi
    printf 'New since %s\n\n' "$LEAD" | cat - "$NOTES" >"$OUT/notes-discord.md"
  fi
  printf '%s\n\n' "$NAME" | cat - "$OUT/notes.md" >"$OUT/message"
  echo "→ public source"
  tools/public-sync.sh "$PUB" "$OUT/message"
  SOURCE=$(git -C "$PUB" rev-parse HEAD) PRIVATE=$(git rev-parse --short=8 HEAD)

  echo "→ Release build of the public tree"
  # every prepare builds into $R/build, and a nightly and a beta can hold the two heavy slots at once
  lock "$R/build.lock" wait
  APP="$R/build/Build/Products/Release/Artemis.app"
  rm -rf "$APP" "$APP.dSYM"
  # no get-task-allow (CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO); Xcode signs Sparkle's helpers inside-out
  xcodebuild -project "$PUB/Artemis.xcodeproj" -scheme Artemis -configuration Release -derivedDataPath "$R/build" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARTEMIS_BUNDLE_ID=app.artemisbrowser.Artemis ARTEMIS_FEED_URL=$FEED \
    ARTEMIS_CHANNEL=$CHANNEL ARTEMIS_GIT_SHA="$PRIVATE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION=$BUILD ARCHS=arm64 build >"$OUT/build.log" 2>&1 || true
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$OUT/build.log" || true
  grep -q "BUILD SUCCEEDED" "$OUT/build.log" || die "build failed, see $OUT/build.log"
  codesign --verify --deep --strict "$APP"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] ||
    die "the app's build isn't $BUILD"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print ArtemisChannel' "$APP/Contents/Info.plist")" == "$CHANNEL" ]] ||
    die "the app's channel isn't $CHANNEL"
  # captured, not piped: grep -q stops reading early and pipefail counts the writer's SIGPIPE
  [[ "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" != *get-task-allow* ]] ||
    die "the app carries get-task-allow"
  [[ "$(codesign -dvv "$APP" 2>&1)" == *"TeamIdentifier=$TEAM"* ]] || die "the app isn't signed by team $TEAM"
  # crash reports name the binary by UUID, which tools/symbolicate.sh looks up here
  for uuid in $(xcrun dwarfdump --uuid "$APP/Contents/MacOS/Artemis" | awk '{print $2}'); do
    mkdir -p "$HOME/Library/Developer/Artemis/dSYMs/$uuid" && cp -R "$APP.dSYM" "$HOME/Library/Developer/Artemis/dSYMs/$uuid/"
  done

  echo "→ DMG"
  swift tools/dmg/background.swift "$OUT" && tiffutil -cathidpicheck "$OUT/bg.png" "$OUT/bg@2x.png" -out "$OUT/bg.tiff" >/dev/null
  # unsigned on purpose: a signed but un-notarised DMG is itself blocked by Gatekeeper
  "$R/venv/bin/dmgbuild" -s tools/dmg/settings.py -D app="$APP" -D bg="$OUT/bg.tiff" "Artemis $VERSION" "$OUT/$ASSET" >/dev/null
  hdiutil verify "$OUT/$ASSET" >/dev/null

  echo "→ Sparkle signature"
  SIG=$("$R/sparkle/bin/sign_update" --ed-key-file "$R/sparkle_ed25519" "$OUT/$ASSET")
  DESC=$(python3 tools/release-notes.py "$OUT/notes.md")
  CHANNEL_TAG=""
  if [[ $CHANNEL != release ]]; then CHANNEL_TAG="<sparkle:channel>$CHANNEL</sparkle:channel>"; fi
  cat >"$OUT/item.xml" <<EOF
    <item>
      <title>Artemis $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$DESC]]></description>
      $CHANNEL_TAG
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
EOF
  SHA256=$(shasum -a 256 "$OUT/$ASSET" | awk '{print $1}')
  for v in VERSION N BUILD CHANNEL TAG NAME ASSET URL SHA256 SOURCE PRIVATE COLLAGE; do
    printf '%s=%q\n' "$v" "${!v}"
  done >"$OUT/manifest"
  echo "prepared: $OUT"
}

publish() {
  OUT=${1%/}
  [[ $OUT == "$R/out/"* && -f $OUT/manifest ]] || die "no candidate in $OUT"
  lock "$OUT/lock"
  [[ ! -f $OUT/pulled ]] || die "$OUT was pulled"
  # a failure exits 3 only while this candidate's item is on public main's appcast ($OUT/pushed): publishing again finishes it.
  # Only DONE exits 0: bash 3.2 runs this trap with $? = 0 after a set -u abort.
  PUSHED="" DONE=""
  if [[ -f $OUT/pushed ]]; then PUSHED=1; fi
  trap 'rc=$?; [[ -n $DONE ]] || exit $((PUSHED ? 3 : rc == 0 || rc == 3 ? 1 : rc))' EXIT
  source "$OUT/manifest"
  PUB=$OUT/public
  APPCAST=$PUB/website/src/static/appcast.xml
  [[ "$(shasum -a 256 "$OUT/$ASSET" | awk '{print $1}')" == "$SHA256" ]] || die "$ASSET changed since prepare"
  # push() trusts $REMOTE, so it must be where this candidate's clone pushes
  [[ $(git -C "$PUB" remote get-url origin) == "$REMOTE" ]] || die "$OUT was prepared against another remote"

  echo "→ appcast and site, locally"
  git -C "$PUB" fetch -q origin
  git -C "$PUB" reset -q --hard origin/main
  # this DMG's item already on public main: an earlier attempt pushed the appcast, and what follows the push runs again
  ENCLOSURE=$(grep -o '<enclosure .*/>' "$OUT/item.xml")
  if grep -qF -- "$ENCLOSURE" "$APPCAST"; then
    PUSHED=1
    touch "$OUT/pushed"
  else
    # never pushed, or pruned since: a failure from here is final
    PUSHED=""
    rm -f "$OUT/pushed"
    git -C "$PUB" reset -q --hard "$SOURCE"
    git -C "$PUB" "${FIN[@]}" rebase -q origin/main || { git -C "$PUB" rebase --abort; die "the source commit doesn't rebase onto public main"; }
    git -C "$PUB" diff --quiet "$SOURCE" HEAD -- Artemis Artemis.xcodeproj ArtemisDockTile AppIcon.icon ||
      die "the public app sources changed since prepare"
    ! grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" || die "build $BUILD is already in the appcast"
    # newest first under the marker; nightlies keep the newest 3 above every beta and release
    python3 - "$APPCAST" "$OUT/item.xml" <<'PY' || die "a newer beta or release supersedes $BUILD"
import re, sys
path, new = sys.argv[1], open(sys.argv[2]).read()
head, tail = open(path).read().split("<!-- items -->\n")
item = re.compile(r"    <item>\n.*?\n    </item>\n", re.S)
items, rest = [new] + item.findall(tail), item.sub("", tail)
build = lambda i: [int(x) for x in re.search(r"<sparkle:version>([^<]+)<", i).group(1).split(".")]
nightly = lambda i: "<sparkle:channel>nightly</sparkle:channel>" in i
top = max((build(i) for i in items if not nightly(i)), default=[0])
nights = [i for i in items if nightly(i) and build(i) > top][:3]
items = [i for i in items if not nightly(i) or i in nights]
open(path, "w").write(head + "<!-- items -->\n" + "".join(items) + rest)
sys.exit(new not in items)
PY
    xmllint --noout "$APPCAST"
    if [[ $CHANNEL == release ]]; then
      sed -i '' "s#^export const DOWNLOAD_URL = .*#export const DOWNLOAD_URL = \"$URL\";#" "$PUB/website/src/site.config.mjs"
    fi
  fi
  SOURCE=$(git -C "$PUB" rev-parse HEAD)
  (cd "$PUB/website" && node build.mjs --check | grep -E "^fail|check:" && node build.mjs >/dev/null)
  if [[ -z $PUSHED ]]; then
    git -C "$PUB" add website/src/static/appcast.xml website/src/site.config.mjs
    git -C "$PUB" "${FIN[@]}" commit -q -m "release: Artemis $VERSION ($BUILD), $CHANNEL"
  fi
  # the Discord announcement, only from a checkout that carries the private bot and its token
  POST=()
  if [[ -f discord/release/post.mjs && -f $R/discord-token && ! -f $OUT/posted ]]; then
    DL=$URL DISCORD_NOTES=$OUT/notes.md
    if [[ -f $OUT/notes-discord.md ]]; then DISCORD_NOTES=$OUT/notes-discord.md; fi
    if [[ $CHANNEL == release ]]; then DL=https://artemisbrowser.app/download; fi
    # 20 fps keeps a release collage under Discord's 10 MB
    POST=(env FPS=20 node discord/release/post.mjs "$VERSION" "$N" "$CHANNEL" "$DISCORD_NOTES"
      "https://github.com/$REPO/releases/tag/$TAG" "$DL" ${COLLAGE:+"$COLLAGE"})
    # rendering uploads any keycap emoji the bot lacks, so a dry run doesn't
    if [[ -z $DRY ]]; then
      [[ -d discord/node_modules ]] || npm --prefix discord ci --silent
      "${POST[@]}" --dry-run >"$OUT/discord.json" || die "the Discord post doesn't render, see $OUT/discord.json"
    fi
  fi

  echo "→ public source $SOURCE"
  push "$SOURCE:refs/heads/main"
  echo "→ GitHub release $TAG"
  PRERELEASE=--prerelease
  if [[ $CHANNEL == release ]]; then PRERELEASE=""; fi
  if ! gh release view "$TAG" -R $REPO >/dev/null 2>&1; then
    out gh release create "$TAG" "$OUT/$ASSET" -R $REPO --title "$NAME" --notes-file "$OUT/notes.md" \
      $PRERELEASE --target "$SOURCE"
  else
    # an earlier attempt made the release, a draft until its assets are up; the appcast signs only this DMG
    if [[ $(gh release view "$TAG" -R $REPO --json assets --jq ".assets[] | select(.name == \"$ASSET\") | .digest") == "sha256:$SHA256" ]]; then
      echo "$ASSET is already up"
    else
      out gh release upload "$TAG" "$OUT/$ASSET" -R $REPO --clobber
    fi
    out gh release edit "$TAG" -R $REPO --draft=false
  fi
  out curl -sfIL -o /dev/null "$URL"
  echo "→ appcast"
  if ! push HEAD:refs/heads/main; then
    # git can fail after the remote took the push: unless public main shows it didn't, the next run finishes it
    if ! git -C "$PUB" fetch -q origin || [[ $(git -C "$PUB" show origin/main:website/src/static/appcast.xml) == *"$ENCLOSURE"* ]]; then
      PUSHED=1
      touch "$OUT/pushed"
    fi
    die "the appcast push failed"
  fi
  if [[ -z $DRY || $REMOTE == /* ]]; then
    PUSHED=1
    touch "$OUT/pushed"
  fi
  echo "→ site"
  # from the public site: wrangler leaves .wrangler/ in its working directory
  (cd "$PUB/website" && out npx --yes wrangler@4 deploy)
  if ((${#POST[@]})); then
    echo "→ Discord"
    POSTED=$(out "${POST[@]}") || echo "Discord post failed" >&2
    echo "$POSTED"
    # the post's link, which the next nightly opens with; once it's kept, no rerun posts again
    if [[ -z $DRY && $POSTED == *"posted https://"* ]]; then sed -n 's/^posted //p' <<<"$POSTED" >"$OUT/posted"; fi
  fi
  # only what really reached a remote counts as published
  if [[ -z $DRY || $REMOTE == /* ]] && ! grep -qF " $TAG " "$R/published.log" 2>/dev/null; then
    echo "$(date +%F) $TAG $BUILD $PRIVATE $SOURCE $(grep -m1 . "$OUT/posted" 2>/dev/null || echo -) $NAME" >>"$R/published.log"
  fi
  DONE=1
  echo "done: $URL"
}

# idempotent: a failed pull runs again from the top
pull() {
  OUT=${1%/}
  [[ $OUT == "$R/out/"* && -f $OUT/manifest ]] || die "no candidate in $OUT"
  lock "$OUT/lock"
  source "$OUT/manifest"
  [[ $CHANNEL == nightly ]] || die "only a nightly can be pulled"
  PUB=$OUT/public
  APPCAST=$PUB/website/src/static/appcast.xml
  [[ $(git -C "$PUB" remote get-url origin) == "$REMOTE" ]] || die "$OUT was prepared against another remote"
  # a dry run against the real candidates leaves them publishable
  if [[ -z $DRY || $REMOTE == /* ]]; then touch "$OUT/pulled"; fi
  ENCLOSURE=$(grep -o '<enclosure .*/>' "$OUT/item.xml")
  git -C "$PUB" fetch -q origin
  git -C "$PUB" reset -q --hard origin/main
  if grep -qF -- "$ENCLOSURE" "$APPCAST"; then
    echo "→ appcast without $BUILD"
    python3 - "$APPCAST" "$ENCLOSURE" <<'PY'
import re, sys
path, enclosure = sys.argv[1:]
item = re.compile(r"    <item>\n.*?\n    </item>\n", re.S)
text = open(path).read()
open(path, "w").write(item.sub(lambda m: "" if enclosure in m[0] else m[0], text))
PY
    xmllint --noout "$APPCAST"
    ! grep -qF -- "$ENCLOSURE" "$APPCAST" || die "the appcast still holds $BUILD"
    git -C "$PUB" add website/src/static/appcast.xml
    git -C "$PUB" "${FIN[@]}" commit -q -m "release: pull Artemis $VERSION ($BUILD), nightly"
    push HEAD:refs/heads/main
  fi
  # a rerun deploys only while the live feed still offers it
  if [[ -n $DRY ]] || offered; then
    (cd "$PUB/website" && node build.mjs --check | grep -E "^fail|check:" && node build.mjs >/dev/null)
    echo "→ site"
    (cd "$PUB/website" && out npx --yes wrangler@4 deploy)
    if [[ -z $DRY ]] && offered; then die "$FEED still offers $BUILD"; fi
  fi
  echo "→ GitHub release $TAG"
  out gh release edit "$TAG" -R $REPO --title "$NAME (pulled)" || echo "$TAG's GitHub release keeps its title" >&2
  # the next nightly's notes start after the last publish still standing, and nightly.sh tells the card
  if [[ -z $DRY || $REMOTE == /* ]]; then
    grep -F " $TAG " "$R/published.log" >>"$R/pulled.log" || true
    { grep -vF " $TAG " "$R/published.log" || true; } >"$R/published.log.new"
    mv "$R/published.log.new" "$R/published.log"
    if [[ -d $R/nightly ]]; then echo '{"state": "pulled"}' >"$R/nightly/report.$BUILD"; fi
  fi
  echo "pulled: $TAG"
}

case $MODE in
  prepare) prepare "$@" ;;
  publish) (($# == 1)) || usage; publish "$1" ;;
  pull) (($# == 1)) || usage; pull "$1" ;;
  # not prepare && publish: errexit is off inside a function on the left of &&
  all) prepare "$@"; publish "$OUT" ;;
esac
