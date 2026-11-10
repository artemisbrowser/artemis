# Releasing Artemis

`tools/release.sh` does the whole release. It mirrors the source into this repo as one commit, builds that public tree for Release, and makes the DMG and its Sparkle signature. It then publishes the GitHub release, the appcast entry and the site.

## Before you start

- Run the full self-test ([testing.md](testing.md)) and check the log ends with `done`.
- `~/Library/Application Support/ArtemisRelease/` must hold:
  - `sparkle_ed25519`, the private key every update is signed with. Never commit it, and keep a backup: without it, installed copies can't update.
  - `sparkle/bin`, Sparkle's command-line tools.
  - `venv`, a Python environment with `dmgbuild`.
  - `strip_ios.py`, `add_headers.py`, `leak-words` and `private-gate`, which `tools/public-sync.sh` uses to make the public commit.
  - `published.log`, one line per publish: date, tag, build, source commit, public commit, Discord post link (`-` for none) and name. Nightly notes start after its last line, so seed it with the last release's line before the first nightly. A pulled nightly's line moves to `pulled.log`.
- Xcode signed into the builds Apple account (the team in the script), `gh` with access to this repo, and `wrangler` logged in for the site.

## Release

```sh
tools/release.sh 0.9.7 1 release notes.md --dry-run   # everything local; prints each outward step
tools/release.sh 0.9.7 1 release notes.md
tools/release.sh nightly notes.md                     # a nightly of this commit
```

- **Build.** The second argument is the build of that version, 1–99. A second build of 0.9.7 is `0.9.7 2`, tagged `v0.9.7-2`.
- **Channel.** `release` reaches everyone and moves the site's download button. `beta` reaches people who chose Beta or Nightly in Settings › General › Updates. A nightly reaches only Nightly.
- **Nightly.** Its build is the highest build in the appcast plus `.YYMMDDHH`, so the next beta or release always outranks it. The appcast keeps the newest three nightlies that outrank every beta and release.
- **Notes.** Markdown with `##` headings, paragraphs, `**bold**`, `[links](https://…)` and `-` bullets. They show in the update window, on the GitHub release and as the public commit's message.
- **Fixed posts.** A bullet under Fixed that links a #feedback post (`https://discord.com/channels/<guild>/<thread>`) marks that post Fixed once the update is announced. In a nightly, a fix commit gets that link from a `Fixes-post: <link>` line in its message, one line per post. A fix reverted before the nightly is left out.
- **In two steps.** `tools/release.sh prepare …` stops before anything leaves the Mac and prints the candidate's folder. `tools/release.sh publish FOLDER` publishes it, after checking the DMG is still the one prepared. Running it again picks up where a failed publish stopped, and only one publish of a folder runs at a time.
- **Notes go public.** The same checks as the source run over them, so a private name, a word from `leak-words` or the legal name stops the release.

## Nightlies

`tools/nightly.sh` runs every five minutes from a worktree of `stable`. Once a day from 03:00, the first time the Mac sits unlocked with its display on, nobody has touched it for 15 minutes, a heavy slot is free and the app has changed, it does the following:

1. Runs the whole self-test on a lab build (`artemis-labtest`). Only the records listed in `tools/selftest-known-failures` may fail. If the test fails it runs once more. A second failure skips the day and pings Fin. A run that proves nothing about the code, because the screen locked or went dark or someone used the Mac while it failed, leaves the day open for the next chance.
2. Builds the nightly and publishes it without waiting for anyone's go.
3. Writes notes that list every `feat`, `perf` and `fix` commit since the last publish still standing. They open with a "New since" link to that publish: its GitHub release, or in Discord its post.

Each published nightly gets a card on #staff with a Pull button only Fin can use. Pull takes that nightly off the appcast within five minutes, or a few more while the next nightly publishes. `tools/release.sh pull FOLDER` does the same by hand, and the card hears about it within five minutes. Pulling redeploys the site and adds "(pulled)" to the GitHub release's title, and the next nightly's notes start from the publish before it. A Pull during a nightly's build makes it build again with notes from that earlier publish. Macs that already updated keep the pulled nightly until a newer build ships.

If a publish stops after the appcast went public, or the pull for a Pull stops partway, it runs again every five minutes until it finishes, and no new nightly is made before then. The log, the last self-test's output and the notices are in `nightly/` in that folder. To install it:

```sh
R=~/Library/Application\ Support/ArtemisRelease
git worktree add --detach "$R/nightly/tree" stable
cp tools/app.artemisbrowser.nightly.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.artemisbrowser.nightly.plist
```

It also needs `release-worker`, the Worker's address, and `release-secret` in that folder.

## Things that must hold

- The DMG stays unsigned. macOS blocks a signed DMG that isn't notarised.
- Builds aren't notarised, so the first open goes through Open Anyway. The site's download page walks through it.
- `CFBundleVersion` must go up with every release, or Sparkle won't offer it. A release or beta is `x×1,000,000 + y×10,000 + z×100 + build`. Never put a `-` or letters in it.
- Sparkle checks every update against `SUPublicEDKey` in `Info.plist`. Changing the key strands everyone on the old one.
