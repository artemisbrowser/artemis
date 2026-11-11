#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Run every five minutes by tools/app.artemisbrowser.nightly.plist from $R/nightly/tree. Once a day from 03:00, when the
# Mac is unlocked and lit and Fin says yes on screen, it self-tests stable when the app changed,
# publishes it as a nightly if the test passes and puts its card on #staff, whose Pull takes it back off the appcast.
#   tools/nightly.sh [--dry-run]   passes --dry-run on, talks only to a Worker on 127.0.0.1 and never sounds ping-fin
main() {
  set -euo pipefail
  DRY=${1:-}
  R=${ARTEMIS_RELEASE_DIR:-"$HOME/Library/Application Support/ArtemisRelease"}
  NIGHTLY=$R/nightly TREE=$R/nightly/tree
  [[ -z $DRY || -n ${ARTEMIS_RELEASE_DIR:-} ]] || { echo "a dry run needs its own ARTEMIS_RELEASE_DIR" >&2; exit 2; }
  # one run at a time, awake with the display on for the lab: launchd never overlaps its own, but one started by hand can
  if [[ -z ${NIGHTLY_LOCKED:-} ]]; then
    export NIGHTLY_LOCKED=1
    exec /usr/bin/lockf -k -s -t 0 "$NIGHTLY/lock" /usr/bin/caffeinate -di /bin/bash "$0" "$@"
  fi
  export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  exec >>"$NIGHTLY/log" 2>&1
  trap '(($? == 0)) || alarm "The nightly failed: see $NIGHTLY/log"' EXIT
  # ahead of the config, so a broken setup still reaches Fin
  if [[ -s $NIGHTLY/notice ]] && (($(hour) >= 9 && $(hour) < 23)); then
    local text
    text=$(awk 'NR > 1 {printf "; "} {printf "%s", $0}' "$NIGHTLY/notice")
    if [[ -n $DRY ]]; then echo "would ping Fin: $text"; else ping-fin "$text"; fi
    rm "$NIGHTLY/notice"
  fi
  local secret
  WORKER=$(cat "$R/release-worker")
  WORKER=${WORKER%/}
  secret=$(cat "$R/release-secret")
  [[ -z $DRY || $WORKER == http://127.0.0.1:* ]] || { echo "a dry run only talks to a Worker on 127.0.0.1"; exit 2; }
  # curl reads the bearer from a file: its argv is visible to every account through ps
  (umask 077 && printf 'Authorization: Bearer %s\n' "$secret" >"$NIGHTLY/auth")
  # set by watch while a Pull's pull hasn't finished, and no nightly is made over one
  unsettled=""
  watch
  deliver
  if [[ -f $NIGHTLY/publishing ]]; then publish; fi
  prepare
}

# Every assertion carries its own || exit: bash 3.2's errexit ignores a failing [[ or ((.
# $NIGHTLY/publishing is the candidate release.sh is publishing, until it finishes; $NIGHTLY/live lists the newest three
# published, which Pull can still take back; announce.<build> and report.<build> wait there until the Worker takes them.

# prints the HTTP status, 000 when the Worker is unreachable; the body lands in $NIGHTLY/answer
api() {
  rm -f "$NIGHTLY/answer"
  curl -s --max-time 30 -o "$NIGHTLY/answer" -w '%{http_code}' -H @"$NIGHTLY/auth" -H "Content-Type: application/json" "$@" || true
}
answer() { cat "$NIGHTLY/answer" 2>/dev/null || true; }
hour() { echo $((10#$(date +%H))); }
# "LOCKED ASLEEP SINCE": the screen lock and display sleep as 1 or 0, then the seconds since a click (types 1, 3, 25),
# key (10) or scroll (22) reached the HID system; "1 1 0" when it can't tell
console() {
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics")
var session = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary())) || {}
var since = function (type) { return Math.floor($.CGEventSourceSecondsSinceLastEventType(1, type)) }
;[session.CGSSessionScreenIsLocked ? 1 : 0, $.CGDisplayIsAsleep($.CGMainDisplayID()) ? 1 : 0,
  Math.min(since(1), since(3), since(10), since(22), since(25))].join(" ")' 2>/dev/null || echo "1 1 0"
}
awake() { [[ $(console) == "0 0 "* ]]; }
log() { echo "$(date '+%F %T') $1"; }
# queued one a line for ping-fin, which sounds them in the daytime
notice() { grep -qxF -- "$1" "$NIGHTLY/notice" 2>/dev/null || echo "$1" >>"$NIGHTLY/notice"; }
# a notice that sounds at most once a day
alarm() {
  [[ $(head -1 "$NIGHTLY/alarmed" 2>/dev/null) == "$(date +%F)" ]] || date +%F >"$NIGHTLY/alarmed"
  ! grep -qxF -- "$1" "$NIGHTLY/alarmed" || return 0
  echo "$1" >>"$NIGHTLY/alarmed"
  notice "$1"
}

prepare() {
  local today app out old keep base line rc=0
  today=$(date +%F)
  (($(hour) >= 3)) && [[ $(cat "$NIGHTLY/tried" 2>/dev/null) != "$today" ]] || return 0
  # the lab needs the screen unlocked and lit with its windows in front, and a stuck publish or pull finishes first
  [[ ! -f $NIGHTLY/publishing && -z $unsettled ]] && awake || return 0
  # each step queues for a heavy slot; none starts while other jobs hold both
  [[ $(heavy-job --status) == *": free"* ]] || return 0
  git -C "$TREE" checkout -q --detach stable
  app=$(git -C "$TREE" log -1 --format=%h -- Artemis ArtemisDockTile AppIcon.icon)
  [[ $app != "$(cat "$NIGHTLY/last" 2>/dev/null)" ]] || return 0
  fresh || return 0
  # "Wait and tell me" closes the day; Fin runs it by hand
  if [[ -z $DRY ]]; then
    fin-ask "Self-test stable $app for tonight's nightly? Its windows take the screen while it runs." "Run it" || {
      (($? == 3)) && echo "$today" >"$NIGHTLY/tried"
      return 0
    }
  fi
  log "self-testing $(git -C "$TREE" rev-parse --short HEAD)"
  selftest || rc=$?
  if ((rc == 1)); then
    rc=0
    selftest || rc=$?
  fi
  # a run that proved nothing about the code leaves the day open
  if ((rc == 2)); then return 0; fi
  echo "$today" >"$NIGHTLY/tried"
  if ((rc)); then
    log "the self-test failed twice: see $NIGHTLY/selftest"
    alarm "Today's nightly is skipped: the self-test failed twice, see $NIGHTLY/selftest"
    return 0
  fi
  while :; do
    # a Pull moves the notes' start back, and a beta published meanwhile can leave this tree nothing new
    fresh || { log "nothing new since $base"; return 0; }
    keep=$(cat "$NIGHTLY/live" 2>/dev/null || true)
    for old in "$R"/out/v*-nightly.*; do
      grep -qxF -- "$old" <<<"$keep" || rm -rf "$old"
    done
    log "preparing $(git -C "$TREE" rev-parse --short HEAD), notes since $base"
    heavy-job "nightly: Release build" "$TREE/tools/release.sh" prepare nightly "$NIGHTLY/notes.md" $DRY \
      >"$NIGHTLY/prepare" 2>&1 &
    serve $! || true
    cat "$NIGHTLY/prepare"
    out=$(sed -n 's/^prepared: //p' "$NIGHTLY/prepare")
    [[ -f $out/manifest ]] || { log "the build left no candidate"; exit 1; }
    unsettled=""
    watch
    deliver
    # a Pull since the notes were written, finished or not, leaves them starting too late
    if [[ -n $unsettled ]]; then
      log "a Pull hasn't finished: $out waits for it"
      rm -rf "${out:?}" "$NIGHTLY/tried"
      return 0
    fi
    [[ $(tail -1 "$R/published.log") != "$line" ]] || break
    log "a Pull came during the build: preparing again"
    rm -rf "${out:?}"
  done
  echo "$app" >"$NIGHTLY/last"
  echo "$out" >"$NIGHTLY/publishing"
  publish
}

# $NIGHTLY/notes.md from the last publish still standing ($line, made at $base) to the tree; false when the tree isn't
# past it or none of the app's commits since is a feat, perf or fix
fresh() {
  line=$(tail -1 "$R/published.log")
  base=$(awk '{print $4}' <<<"$line")
  git -C "$TREE" rev-parse -q --verify "${base:-none}^{commit}" >/dev/null ||
    { log "the last line of $R/published.log names no commit of this tree"; exit 1; }
  git -C "$TREE" merge-base --is-ancestor "$base" HEAD || return 1
  notes_since "$base" >"$NIGHTLY/notes.md"
  grep -q '[^[:space:]]' "$NIGHTLY/notes.md"
}

# waits for the background job PID, serving Pull every five minutes meanwhile, and returns its exit code
serve() {
  local tick=0
  while kill -0 "$1" 2>/dev/null; do
    sleep 5
    ((++tick % 60)) || { watch; deliver; }
  done
  wait "$1"
}

# the whole self-test on a Debug lab build of this tree, serving Pull meanwhile. 0: every FAIL is in
# tools/selftest-known-failures; 1: the code failed it; 2: the run proves nothing about the code
selftest() {
  local rc=0 verdict=0 start since
  awake || { log "the screen is locked or dark"; return 2; }
  start=$(date +%s)
  artemis-labtest "$TREE" nightlygate >"$NIGHTLY/selftest" 2>&1 &
  serve $! || rc=$?
  # the verdict ends the output too, which Fin's ping points at; SelfTest notes each record it skips in the dark
  python3 - "$NIGHTLY/selftest" "$TREE/tools/selftest-known-failures" "$rc" <<'PY' | tee -a "$NIGHTLY/selftest" || verdict=$?
import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
known = [l for l in open(sys.argv[2]).read().splitlines() if l and not l.startswith("#")]
title = lambda fail: next((k for k in known if fail == k or fail.startswith(k + " — ")), None)
fails = [l[5:] for l in lines if l.startswith("FAIL ")]
finished = sys.argv[3] in ("0", "1") and any(re.fullmatch(r"\d+ passed, \d+ failed", l) for l in lines)
broken = [l for l in lines if l.startswith(("BUILD FAILED", "NO DONE LINE", "LAB "))]
new = ["FAIL " + f for f in fails if title(f) is None]
dark = ["it proves nothing: " + l for l in lines if "asleep or locked" in l]
if finished and not broken and not dark:
    for k in sorted(set(known) - {title(f) for f in fails}):
        print("self-test: a known failure passed:", k)
for line in dark + broken + new + ([] if finished else ["the suite didn't finish"]):
    print("self-test:", line)
sys.exit(2 if dark else 1 if broken or new or not finished else 0)
PY
  awake || { log "the screen locked or went dark during the self-test"; return 2; }
  # the suite only ever moves the pointer: a click, key or scroll since it started was someone at the Mac
  since=$(console | awk '{print $3}')
  if ((verdict == 1 && ${since:-0} < $(date +%s) - start)); then
    log "someone used the Mac during the self-test that failed"
    return 2
  fi
  return "$verdict"
}

# release.sh exits 3 when the appcast is public and a later step failed: every run carries on from there until it finishes
publish() {
  local out rc=0 thread
  out=$(cat "$NIGHTLY/publishing")
  [[ -f $out/manifest ]] || { log "$out has no manifest"; rm "$NIGHTLY/publishing"; return 0; }
  source "$out/manifest"
  "$TREE/tools/release.sh" publish "$out" $DRY || rc=$?
  case $rc in
    0)
      log "$TAG published"
      # thread_id carries the #updates post's id, which the Worker takes only as 17-20 digits
      thread=$(sed -n 's#^https://discord\.com/channels/[0-9]*/[0-9]*/\([0-9]\{17,20\}\)$#\1#p' "$out/posted" 2>/dev/null || true)
      # the Worker takes notes up to 10,000 UTF-16 units, and jq slices code points, each at most two units
      jq -n --arg build "$BUILD" --arg sha256 "$SHA256" --arg version "$VERSION" --arg channel "$CHANNEL" \
        --arg tag "$TAG" --arg url "$URL" --arg thread_id "$thread" --rawfile notes "$out/notes.md" \
        '$ARGS.named + {state: "published"} | if .thread_id == "" then del(.thread_id) else . end
          | .notes |= if length > 4999 then .[:4999] + "…" else . end' >"$NIGHTLY/announce.$BUILD"
      { grep -vxF -- "$out" "$NIGHTLY/live" 2>/dev/null || true; echo "$out"; } | tail -3 >"$NIGHTLY/live.new"
      mv "$NIGHTLY/live.new" "$NIGHTLY/live"
      ;;
    3)
      log "$TAG stopped after its appcast went public"
      alarm "Nightly $N is stuck halfway through publishing: see $NIGHTLY/log"
      return 0
      ;;
    75)
      log "$TAG is being published by another run"
      alarm "Nightly $N waits for another publish of it to finish: see $NIGHTLY/log"
      return 0
      ;;
    *)
      log "$TAG failed to publish"
      rm -f "$NIGHTLY/last"
      alarm "Nightly $N failed to publish: see $NIGHTLY/log"
      ;;
  esac
  rm "$NIGHTLY/publishing"
  deliver
}

# Pull on a live nightly's card takes it off the appcast, and release.sh pull leaves report.<build> to tell the card
watch() {
  local out code state sha gone=""
  [[ -f $NIGHTLY/live ]] || return 0
  while IFS= read -r -u 3 out; do
    if [[ ! -f $out/manifest ]]; then gone+=$out$'\n'; continue; fi
    source "$out/manifest"
    # pulled by hand
    if grep -qF " $TAG " "$R/pulled.log" 2>/dev/null; then gone+=$out$'\n'; continue; fi
    # no card to tap until the Worker has the announcement
    [[ ! -f $NIGHTLY/announce.$BUILD ]] || continue
    code=$(api "$WORKER/release/candidates/$BUILD")
    IFS='|' read -r state sha < <(jq -r '"\(.state // .error)|\(.sha256 // "")"' "$NIGHTLY/answer" 2>/dev/null) || true
    case $code:$state in
      # no card, since the Worker refused it and pinged Fin then: only a hand pull or age takes it off live
      200:published | "404:unknown build") continue ;;
      200:pull) ;;
      # nothing left to pull: the card is pulled, or three newer nightlies retired it
      200:pulled | 200:retired)
        log "$TAG leaves the Pull watch: $code $state"
        gone+=$out$'\n'
        continue
        ;;
      *)
        log "asking about $TAG answered $code $(answer)"
        alarm "#staff can't hear about nightlies: see $NIGHTLY/log"
        continue
        ;;
    esac
    if [[ $sha != "$SHA256" ]]; then
      log "Pull on $TAG names $sha, but it was built as $SHA256"
      alarm "Nightly $N's Pull names another DMG: see $NIGHTLY/log"
    elif "$TREE/tools/release.sh" pull "$out" $DRY; then
      log "$TAG pulled"
      gone+=$out$'\n'
    else
      log "$TAG's pull didn't finish"
      alarm "Nightly $N's pull didn't finish: see $NIGHTLY/log"
      unsettled=1
    fi
  done 3<"$NIGHTLY/live"
  grep -vxF -f <(printf '%s' "$gone") "$NIGHTLY/live" >"$NIGHTLY/live.new" || true
  mv "$NIGHTLY/live.new" "$NIGHTLY/live"
}

# report.<build> tells a card its nightly is pulled and announce.<build> puts one on #staff. Reports go first, since a
# new card retires the oldest the Worker still counts, and a nightly pulled before its card went up gets none.
# 400, 404 and 409 mean never.
deliver() {
  local file name build url code state
  for file in "$NIGHTLY"/report.* "$NIGHTLY"/announce.*; do
    [[ -f $file ]] || continue
    name=${file##*/}
    build=${name#*.} url=$WORKER/release/candidates
    if [[ $name == report.* ]]; then
      url+=/$build
    elif grep -qF " $build " "$R/pulled.log" 2>/dev/null; then
      rm "$file"
      continue
    fi
    code=$(api --data-binary @"$file" "$url")
    state=$(jq -r '.state // .error // ""' "$NIGHTLY/answer" 2>/dev/null || true)
    case $code:${name%%.*}:$state in
      # sent again after its answer got lost, or about a card a newer nightly retired or that never went up
      20[01]:report:* | 409:report:pulled | 409:report:retired | "404:report:unknown build") rm "$file" ;;
      20[01]:announce:published | 20[01]:announce:pull | 20[01]:announce:pulled | 20[01]:announce:retired) rm "$file" ;;
      # a Worker from before Pull keeps the nightly in another state, on a card without the button
      20[01]:announce:*)
        log "sending $name answered $code $(answer)"
        alarm "The Worker has no Pull for nightlies: see $NIGHTLY/log"
        ;;
      400:* | 404:* | 409:*)
        log "sending $name answered $code $(answer)"
        rm "$file"
        alarm "The Worker refused $name: see $NIGHTLY/log"
        ;;
      *)
        log "sending $name answered $code"
        alarm "Nightly cards can't reach #staff: see $NIGHTLY/log"
        ;;
    esac
  done
}

# New, Refined and Fixed from the app's feat, perf and fix commits, minus what tools/public-sync.sh refuses
# and what a later commit in the range reverts. Each "Fixes-post: <link>" line in a commit's message links
# its bullet to that #feedback post, "Refixes-post:" to one an earlier update marked Fixed too soon.
notes_since() {
  local names surname
  names=$(cd "$TREE" && "$R/private-gate" notes)
  surname=$(id -F | awk '{print $NF}')
  [[ -n $names && -n $surname && -r $R/leak-words && -s $R/leak-words ]] ||
    { log "no names list, surname or $R/leak-words to filter the notes" >&2; exit 1; }
  git -C "$TREE" log --no-merges --format=%s "$1..HEAD" -- Artemis ArtemisDockTile AppIcon.icon |
    { grep -viE "$names|mobile" | grep -viFf "$R/leak-words" | grep -viw -- "$surname" || true; } |
    python3 -c '
import re, sys
kinds, groups = {"feat": "New", "perf": "Refined", "fix": "Fixed"}, {"New": [], "Refined": [], "Fixed": []}
kept, undone = set(sys.stdin.read().split("\n")), set()
post = r"(?im)^(re)?fixes-post:\s*https://(?:ptb\.|canary\.)?discord(?:app)?\.com/channels/(\d{17,20})/(\d{17,20})(?!\d)"
for record in open(sys.argv[1], encoding="utf-8").read().split("\0"):
    sha, subject, body = (record.split("\x1f") + ["", ""])[:3]
    if sha in undone:
        continue
    undone.update(re.findall(r"This reverts commit ([0-9a-f]{40})", body))
    m = re.match(r"(\w+)(\([^)]*\))?!?: (.+)", subject)
    if subject in kept and m and m[1] in kinds:
        links = ["[%s](https://discord.com/channels/%s/%s)" % ("again" if re_ else "report", g, t) for re_, g, t in re.findall(post, body)]
        groups[kinds[m[1]]].append("- " + m[3][0].upper() + m[3][1:] + (" (" + ", ".join(links) + ")" if links else ""))
print("\n\n".join(f"## {name}\n\n" + "\n".join(lines) for name, lines in groups.items() if lines))' \
      <(git -C "$TREE" log --no-merges -z --format=%H%x1f%s%x1f%b "$1..HEAD" -- Artemis ArtemisDockTile AppIcon.icon)
}

# one line, parsed before it runs: preparing checks out a new copy of this file
main "$@"; exit
