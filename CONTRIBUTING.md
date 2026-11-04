# Contributing to Artemis

Cheers for wanting to help out.

## Reporting bugs

The quickest way is in Artemis itself: Help › Send Feedback… turns your note into an issue here, with the app and macOS versions attached. Screenshots and diagnostics stay private, and Keep this private keeps the whole thing private. Or open an issue and tell us what you did, what you expected and what happened instead. A bug we can make happen again is a bug we can fix.

## Sending a PR

You'll need an Apple silicon Mac on macOS 26 and Xcode 27.

1. Fork the repo on GitHub.
2. Clone your fork and open it in Xcode:
   ```sh
   git clone https://github.com/<your-username>/artemis.git
   cd artemis
   open Artemis.xcodeproj
   ```
3. Make a branch for your change:
   ```sh
   git checkout -b fix-sidebar-flicker
   ```
4. Make your change, hit ⌘R and check it works.
5. Run the self-test. [docs/testing.md](docs/testing.md) covers how.
6. Commit and push to your fork:
   ```sh
   git add .
   git commit -m "Fix the sidebar flickering on collapse"
   git push origin fix-sidebar-flicker
   ```
7. Open a pull request against `main`. Say what it changes and why.
8. If it's your first PR, sign the CLA (see below).

A few things that make a PR easier to merge:

- Keep it to one thing. Two fixes means two PRs.
- Match the code around it.
- If it changes how something looks, stick a screenshot in.

## Working on the website

The website lives in [website/](website/) and takes PRs the same way. It has its own [README](website/README.md) on running it locally.

## The CLA

Artemis is open source under the GPL 3.0 (see [LICENSE](LICENSE)). Before we can merge anything you've written, you'll need to sign our [Contributor Licence Agreement](CLA.md). A bot will comment on your first PR. To sign, reply with:

```
I have read the CLA Document and I hereby sign the CLA
```

You only do it once.

The short version: you keep the copyright on your work, and you give us the right to use it in Artemis under whatever licence Artemis ends up under.
