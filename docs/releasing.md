# Releasing Artemis

`tools/release.sh` does the whole release: a Release build, the DMG, the Sparkle signature, the GitHub release, the appcast entry and the site's download button.

## Before you start

- Run the full self-test ([testing.md](testing.md)) and check the log ends with `done`.
- Push the source you're releasing to this repo's `main`. The release tag points there.
- `~/Library/Application Support/ArtemisRelease/` must hold:
  - `sparkle_ed25519`, the private key every update is signed with. Never commit it, and keep a backup: without it, installed copies can't update.
  - `sparkle/bin`, Sparkle's command-line tools.
  - `venv`, a Python environment with `dmgbuild`.
- Xcode signed into the builds Apple account (the team in the script), `gh` with access to this repo, and `wrangler` logged in for the site.

## Release

```sh
tools/release.sh 0.9.7 1 release notes.md --dry-run   # builds and signs, publishes nothing
tools/release.sh 0.9.7 1 release notes.md
```

- **Build.** The second argument is the build of that version, 1–99. A second build of 0.9.7 is `0.9.7 2`, tagged `v0.9.7-2`.
- **Channel.** `beta` reaches only people who chose Beta in Settings › General › Updates. `release` reaches everyone and moves the site's download button.
- **Notes.** Markdown with paragraphs, `**bold**` and `-` bullets. They show in the update window and on the GitHub release.

## Things that must hold

- The DMG stays unsigned. macOS blocks a signed DMG that isn't notarised.
- Builds aren't notarised, so the first open goes through Open Anyway. The site's download page walks through it.
- `CFBundleVersion` is `x×1,000,000 + y×10,000 + z×100 + build` and must go up with every release, or Sparkle won't offer it.
- Sparkle checks every update against `SUPublicEDKey` in `Info.plist`. Changing the key strands everyone on the old one.
