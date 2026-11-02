# Testing Artemis

## The self-test harness

Artemis tests itself from the inside. `SelfTest` (in `Artemis/models/SelfTest.swift`) runs a suite against the **running app** — live `WKWebView`s, the real content blocker, the real on-disk stores — rather than against mocks.

Run it from the repo root:

```sh
# build, run the suite, read the report
xcodebuild -scheme Artemis -configuration Debug -derivedDataPath .build build

pkill -x Artemis; sleep 2   # quits every copy of Artemis, the one you browse with too
ARTEMIS_SELFTEST=1 .build/Build/Products/Debug/Artemis.app/Contents/MacOS/Artemis &

# a few minutes later, once the app has quit itself
cat ~/Downloads/artemis-selftest.log
```

The build needs Xcode 27. If `xcodebuild` picks up a different Xcode, point `DEVELOPER_DIR` at the right one first, for example `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `deploy.sh` and the lab scripts honour the same variable, and sign with `ARTEMIS_SIGN_IDENTITY`, falling back to the identity in an untracked `.signing-identity` file at the repo root, then `Apple Development`.

The suite has finished only if the log ends with a `done` line. A log without one stopped early, whatever its tally says.

The log is appended to as the suite runs, so a hang or crash still leaves the results up to that point.

**Where its data goes:** a build from source keeps its data in `~/Library/Application Support/Artemis`. The released app uses `~/Library/Application Support/app.artemisbrowser.Artemis`, so the suite never touches the browser you use day to day.

**Signing:** the build is signed to run locally, which is all the suite needs. Picture in Picture is the one feature that won't work that way. To try it, re-sign the build with your own Apple Development certificate:

```sh
codesign --force --deep --sign "Apple Development" \
  --entitlements .build/Build/Intermediates.noindex/Artemis.build/Debug/Artemis.build/Artemis.app.xcent \
  --generate-entitlement-der .build/Build/Products/Debug/Artemis.app
```

**Why run it directly rather than via `open`:** `open` launches through LaunchServices, which doesn't pass environment variables through.

## What it covers

Assertions across: durable storage and `.bak` recovery, session snapshot/round-trip/tolerant decoding, the zoom store and live page zoom, engine-level mute, media-state aggregation across frames, ranged history and archive clears, the Adblock→WebKit converter (including "does WebKit actually compile this"), **live blocking inside a real page**, the privacy cleaner, printing, hibernate/wake, reader extraction and the live reader toggle, backup capture and idempotent re-merge, cross-space tab moves, the space creator's model path, profiles (each one's own jar, favourites, history and passwords; moving a space between profiles; migrating isolated containers; deleting a profile), incognito windows' no-trace guarantees (a non-persistent jar per window with no extensions, history/zoom/undo/session-snapshot exclusion, Peek inheriting the private jar, the Touch ID setting), window-chrome geometry, the traffic lights living in the sidebar, performance budgets, and a layout pass over every Settings pane (the rest of the suite is model-level, so a pane that crashes on construction would otherwise only surface when a human opened Settings).

Suites that drive the real thing rather than a model in isolation:

- **`panels`** — the file picker and JavaScript dialog delegates. A live page's `confirm()` reaching the panel and its answer reaching the page; `prompt()` carrying its default in and typed text back; a cancelled prompt arriving as `null` rather than an empty string, because sites branch on it; a page that spams `alert()` earning a suppression checkbox and then _running on_ instead of hanging; silencing being cleared by a navigation; an abandoned dialog still answering WebKit's handler. Two assertions check selectors rather than behaviour — `webView:runOpenPanelWithParameters:…`, the SPI `_webView:runBeforeUnloadConfirmPanelWithMessage:…`, and `_acceptedMIMETypes`/`_acceptedFileExtensions` — because WebKit dispatches by selector and a rename is not a compile error, it is a silently dead delegate.
- **`schemes`** — which url schemes stay in the browser, which are offered to another app, and which (the shell-reaching ones) are never offered at all; the per-site-and-scheme allowance round-tripping and being cleared with site permissions; and a live `mailto:` navigation raising the offer. The live half always answers _no_, deliberately: a yes would launch Mail on the developer's machine.
- **`files`** — a typed path resolving to a file url while a non-existent one stays a search, and a real local page rendering through `loadFileURL`.
- **`durable`** — the rotation under concurrent writers (24 tasks writing 200 KB each, then asserting both the primary and the backup still decode), and a per-store recovery drill: each of History, Archive and Zoom is built against a scratch file, written twice, has its primary replaced with garbage, and is reopened. A store on the rotating path comes back with the first write; one writing plain atomic comes back empty.
- **`session v2`** — tab records carrying the live tabs' own ids through an encode/decode cycle, the selection stored by id, the derived v1 mirror agreeing with the records (so the file still opens on an older build), and a hand-written v1-only blob decoding into records with freshly minted, distinct ids and its `selectedIndex` becoming a `selectedTabID`.
- **`tabstate`** — a blob round-tripping, an oversized one being dropped rather than written, the orphan sweep keeping the right file, and the end-to-end case: a real loaded tab's `interactionState` written under its id, then a tab constructed with that same id adopting the blob and replaying it on wake.
- **`detached`** — a Scout page joining the weak registry, being reachable from `allTabs`, mapping back from its web view, never being persisted, and being released when the last strong reference goes.
- **`auth`** — the disposition each authentication method gets, driven against the real delegate with a hand-built `URLAuthenticationChallenge` and no network: server trust left to the system, basic and digest raising a login that carries the realm and the host, signing in handing back a `.forSession` credential with the typed username and password, and cancelling actually cancelling rather than falling through to a handler that answers the server with nothing.
- **`handoff` / `translate`** — what Handoff refuses to advertise (an incognito page, a local file, nothing at all) as much as what it offers, and the page's own selection reaching the translation popover: nothing selected translates nothing, a real selection comes through exactly, dismissing clears it. The popover itself is system UI and isn't asserted on.
- **`import`** — both bookmark formats parsed from bytes the test writes itself: entity decoding in titles _and_ urls, nesting flattened rather than dropped, a bookmarklet that isn't a url skipped, an empty folder making no space, and a file that is neither format refused. Then the translation against the real `TabManager` — one space per folder plus one for loose links, everything pinned, everything but the page you land on still lazy, and the filed title becoming the tab's name.
- **`folders`** — the sidebar tree against the live `TabManager`. An empty folder existing and drawing a row (it is a place you made, not a grouping the tabs implied, so it survives being emptied); tabs filing into it and the flat `space.tabs` order following the tree; collapsing hiding the rows while keeping the membership, and a ⇧-click range refusing to reach into a folded folder; nesting, and a folder dropped inside itself being refused rather than making a cycle the flatten would walk forever; ⌘⇧K sparing what's filed. Then the repair pass, which is the load-bearing half: a dangling entry dropped, a tab the tree never heard of adopted rather than lost, a duplicated entry collapsing to one row. Then ungroup lifting children into the folder's slot, close-folder taking its tabs with one ⇧⌘T bringing folder _and_ tabs back, and the round trip — empty folders, names, fold state and nesting all surviving an encode/decode, and a deliberately corrupted tree costing the folders rather than the whole session.
- **`certs`** — that an exception can't be minted for a host whose certificate was never seen (with nothing to scope it to, refusing is the only honest answer), that an unstored exception is never applied, and which failures are offered a way past: untrusted / bad date / unknown root yes, "couldn't find the host" and anything from another error domain no.
- **`bulk`** — the selection reading back in list order, each verb (pin, unpin, mute, unmute) taking the whole selection and then clearing it, a bulk close removing every selected tab and stamping them with one `undoGroup`, and a single ⇧⌘T bringing the whole group back and emptying it off the stack.
- **`notifications`** — Artemis' own `window.Notification` shim: absent in an insecure page; in a secure one a frozen `EventTarget` class starting at `"default"`; `requestPermission()` without user activation prompts nobody; posting while unallowed fires `error`; an app-evaluated (activated) request reaches the prompt and a refusal reaches the page as `"denied"`; a remembered allow reads `"granted"`, and the same site reads `"denied"` in incognito. Nothing is allowed for real, so macOS is never asked for authorization.
- **`scripting`** — the AppleScript dictionary through a child `osascript`, so every line is a real Apple Event round trip (an app scripting itself raises no Automation prompt): reading a tab, its window and its space by id; `execute` refused while Allow JavaScript from Apple Events is off and a `javascript:` URL refused regardless; JavaScript values coming back as text, lists and script errors; setting the URL and mute; `make new tab` and `close`.
- **`downloads`** — a real download finishing under its own name with no `.download` partial left behind, and staying on the sidebar's shelf for a moment after it finishes.
- **`feedback` / `reports`** — an incognito window's feedback carrying no page or screenshot while an ordinary one sends what was ticked, an error report carrying the server's fields, a crash grouping across builds by the frames outside Artemis, and the outbox keeping only the newest reports.
- **`incognito extensions`** — an extension reaching an incognito window only when allowed, `"not_allowed"` staying binding, and a closed incognito window leaving nothing in the runtime.
- **`window drag`** — a press on the page's top edge held while the button is down: let go in place and the page gets a click where it was pressed; move past the slop and it becomes a window drag the page never sees. A double click and a control-click go straight to the page.
- **`escalation`** — a throwaway extension whose manifest declares one permission and offers another. Declared permissions grant silently; an undeclared one is refused with the declared half intact; allowing grants both; undeclared hosts and match patterns are refused; and a context the manager doesn't recognise is granted nothing. The alert is answered by `escalationAnswerForTesting` — a real modal in an unattended suite would hang the run rather than fail it.

## Notes on the tricky assertions

- **Live blocking** runs in two halves: first a hand-made one-rule list (does WebKit blocking reach our web views at all?), then the real converted lists (does the ruleset catch a known ad host?). When it breaks, the pair says which half broke.
- **The probe must not use `fetch`'s outcome.** A cross-origin request either fails CORS (looks blocked but wasn't) or resolves opaquely under `no-cors` (looks fine when nothing arrived). The honest signal is Resource Timing: a content-blocked request never reaches the network stack, so it leaves no timing entry. The entry is written when the response _completes_, which is after `fetch` resolves — so the probe waits on a `PerformanceObserver` rather than reading the buffer straight after the await.
- **Probe hosts must resolve.** Pointing a block test at a made-up domain "passes" purely because DNS failed.
- **Performance budgets wait for the blocker to go idle** — measuring while it compiles the full rule set times the machine, not the code. Waiting on `isUpdating` is not enough: that flag only covers the download path, and the launch rebuild compiles through the same queue without it, so the test awaits `ContentBlocker.waitForIdle()` (the work queue itself). The converter budget is set for the unoptimised debug build; release is several times faster and conversion runs off the main actor either way.

- **The traffic lights are tested as real buttons in the sidebar** — superview is `TrafficLightMount.MountView` inside the SwiftUI hosting tree, resting at window x=12, sweeping through 12+ distinct positions mid-animation (genuine per-frame motion, the assertion no external-sync design could pass), and landing back at exactly x=12. Park the pointer first (`CGWarpMouseCursorPosition` — the peek won't dismiss under the cursor); wait for a _stable_ rest x rather than a fixed sleep (the app may start collapsed, and a busy main thread delays the spring); and the theme-widget buttons are **flipped** views, so rect-convert — a point-convert of `.zero` reads their top and throws the y math off by 14pt.
- **Some assertions skip themselves rather than fail on machine state.** The live geolocation path can only be exercised once macOS has granted Artemis location access for the app as a whole. While that answer is `notDetermined`, WebKit waits on the system prompt and never puts the page's question to the app, so there is nothing there to assert about the code — the suite says so in a note and moves on rather than reporting a failure it can't act on. Grant it once in System Settings › Privacy & Security › Location Services to turn the assertion back on. The traffic-light hover and sweep checks do the same when the browser window isn't key: they read rendered pixels and animated positions, and macOS renders an inactive traffic light grey with no glyph and doesn't ask a background app to draw at all. Run the suite without touching the machine.
- **The suite steals focus.** It activates Artemis at the start and drives real UI for several minutes — run it when you're not mid-something, and prefer a quiet machine for the perf budgets (they're best-of-three, but sustained load still skews them).
- **Perf budgets measure fixtures the test owns**, not the developer's session: the display-name budget builds its own query-bearing tab, since its cost depends on the url's shape.
- **`chrome.idle` is asserted to be live, not low.** It reads the clock twice and watches it move, allowing for a reset to zero if someone touches the machine mid-test, so it holds for an unattended run too.

## Build configuration

Build Debug while iterating (⌘R in Xcode, or the `xcodebuild` line above): Debug compiles incrementally and in parallel. Release is what ships, and what the perf budgets other than the converter's assume; its build time is whole-module optimisation, not slow type-checking.

## The converter harness

`AdblockConverter` has no app dependencies, so it can also be exercised standalone against real filter lists — useful when changing the conversion rules:

```sh
mkdir -p /tmp/conv
cp Artemis/models/extensions/AdblockConverter.swift /tmp/conv/   # from the repo root
cd /tmp/conv
# write a main.swift that downloads EasyList, calls AdblockConverter.convert,
# and compiles each chunk through WKContentRuleListStore
xcrun swiftc -O AdblockConverter.swift main.swift -o conv && ./conv
```
