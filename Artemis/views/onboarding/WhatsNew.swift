// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the moment after an update: the intro's last seconds, then a card of what changed. A version's written
/// note plays the first time that version opens; any other build plays the notes its own update carried
enum WhatsNew {
    struct Note {
        let headline: String
        /// the colour the moment plays in; nil for the chosen icon's
        var accent: AppIconChoice?
        let highlights: [(symbol: String, title: String, lines: [String])]
        /// how many lines the card left out
        var more = 0
    }

    /// by marketing version, written at release time
    static let notes: [String: Note] = [:]

    static let enabledKey = "showsWhatsNew"
    static let changelog = "https://github.com/artemisbrowser/artemis/releases"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    /// the notes of an update on its way in, kept for that build's first launch
    static func remember(build: String, notes html: String?) {
        UserDefaults.standard.set(html.map { ["build": build, "html": $0] }, forKey: "whatsNewPending")
    }

    /// read once at launch, which also marks the running version and build seen
    private static let launch: (note: Note?, isDue: Bool) = {
        let defaults = UserDefaults.standard
        let seenVersion = defaults.string(forKey: "whatsNewSeen"), seenBuild = defaults.string(forKey: "whatsNewSeenBuild")
        defaults.set(version, forKey: "whatsNewSeen")
        defaults.set(build, forKey: "whatsNewSeenBuild")
        let pending = defaults.dictionary(forKey: "whatsNewPending") as? [String: String]
        let isNightly = Updates.buildChannel == "nightly"
        var arrived = pending?["build"] == build ? pending?["html"].flatMap { parse($0) } : nil
        arrived?.accent = accent(for: build)
        let fresh = pick(written: notes[version], arrived: arrived, isNewVersion: seenVersion != version, isNightly: isNightly)
        let isDue =
            !SelfTest.isRequested && !AppStorageLocation.isExtensionLab
            && due(
                seenBuild: seenBuild, isFresh: Onboarding.isDue,
                isOn: defaults.object(forKey: enabledKey) as? Bool ?? true, hasNote: fresh != nil)
        return (fresh ?? (isNightly ? nil : notes[version]), isDue)
    }()

    /// what plays, at launch or from Settings
    static var note: Note? { launch.note }
    fileprivate(set) static var isDue = launch.isDue

    /// the written note the first time its version opens, never on a nightly; else what this build's update carried
    static func pick(written: Note?, arrived: Note?, isNewVersion: Bool, isNightly: Bool) -> Note? {
        (isNewVersion && !isNightly ? written : nil) ?? arrived
    }

    /// after an update only: a build this Mac has not run, with a note, where Artemis has run before
    static func due(seenBuild: String?, isFresh: Bool, isOn: Bool, hasNote: Bool) -> Bool {
        isOn && hasNote && !isFresh && seenBuild != build
    }

    /// the colour of an update that names none: fixed by its build, and the next icon colour for the next nightly
    static func accent(for build: String) -> AppIconChoice {
        let all = AppIconChoice.allCases.filter { $0 != .home }
        return all[build.unicodeScalars.reduce(0) { $0 + Int($1.value) } % all.count]
    }

    private static let symbols = ["New": "sparkles", "Refined": "wand.and.stars", "Fixed": "wrench.and.screwdriver.fill"]

    /// tools/release-notes.py's HTML: each `<h2>` with the list under it is a highlight, of three lines at most
    static func parse(_ html: String, headline: String = "Since the last \(Updates.buildChannel ?? "build")") -> Note? {
        let sections = html.matches(of: #/(?s)<h2>(.*?)</h2>\s*<ul>(.*?)</ul>/#).map {
            (title: plain($0.1), lines: $0.2.matches(of: #/(?s)<li>(.*?)</li>/#).map { plain($0.1) })
        }
        let highlights = sections.prefix(3).map {
            (symbol: symbols[$0.title] ?? "sparkles", title: $0.title, lines: Array($0.lines.prefix(3)))
        }
        let shown = highlights.reduce(0) { $0 + $1.lines.count }
        guard shown > 0 else { return nil }
        return Note(headline: headline, highlights: highlights, more: sections.reduce(0) { $0 + $1.lines.count } - shown)
    }

    /// a line of the notes without its markup or its trailing report link
    private static func plain(_ html: Substring) -> String {
        html.replacing(#/<[^>]+>/#, with: "").replacing(#/\s*\(report\)$/#, with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static weak var owner: TabManager?
    /// the manager whose window plays it again, as Settings asks
    static let replay = Onboarding.Replay()

    /// whether `manager`'s window plays it: the first main window to ask
    static func claims(_ manager: TabManager) -> Bool {
        guard isDue, manager.kind == .main else { return false }
        if owner == nil { owner = manager }
        return owner === manager
    }
}

/// the moment over the first window, until it is dismissed
struct WhatsNewOverlay: View {
    @Environment(TabManager.self) private var tabManager
    @State private var isShowing = true

    var body: some View {
        let replays = WhatsNew.replay.target === tabManager
        if let note = WhatsNew.note, replays || isShowing && WhatsNew.claims(tabManager) {
            WhatsNewView(note: note) {
                if replays { WhatsNew.replay.target = nil }
                WhatsNew.isDue = false
                isShowing = false
                if tabManager.selectedTab?.url == nil { tabManager.openNewTabBar() }
            }
            // the launch's blank tab opens ⌘T, which would sit over the card
            .onChange(of: tabManager.isCommandBarVisible, initial: true) { _, shown in
                if shown { tabManager.isCommandBarVisible = false }
            }
        }
    }
}

private struct WhatsNewView: View {
    let note: WhatsNew.Note
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(TabManager.self) private var tabManager
    @AppStorage(AppIconChoice.storageKey) private var icon = AppIconChoice.bundled
    @State private var show = IntroShow()
    @State private var isUp = false
    /// how many highlights have come in
    @State private var arrived = 0

    /// the stretch of the intro it plays, in the score's seconds: the right arm landing, the comet's sweep, the title
    private static let excerpt = IntroBeat.arms[1] - 0.2...IntroBeat.title + 1.3

    var body: some View {
        ZStack {
            IntroStage(show: show, isCovered: false, accent: note.accent)
                .onTapGesture { show.begin(quietly: false) }
            if show.phase == .cards {
                card.transition(Motion.grow(from: 0.94))
            }
        }
        .environment(\.colorScheme, .dark)
        .opacity(isUp ? 1 : 0)
        .onExitCommand(perform: leave)
        .task {
            let range = Self.excerpt
            show.startedAt = Date(timeIntervalSinceNow: -(reduceMotion ? range.upperBound : range.lowerBound))
            withAnimation(.easeOut(duration: 0.4)) { isUp = true }
            if !reduceMotion { try? await Task.sleep(for: .seconds(range.upperBound - range.lowerBound)) }
            show.begin(quietly: false)
        }
        .task(id: show.phase) {
            guard show.phase == .cards else { return }
            for index in note.highlights.indices {
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(Motion.pop) { arrived = index + 1 }
            }
        }
    }

    private var card: some View {
        let tint = (note.accent ?? icon).glyph
        return VStack(alignment: .leading, spacing: 0) {
            Text("What's new in Artemis \(Updates.running)")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(note.headline)
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(note.highlights.enumerated()), id: \.offset) { index, each in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: each.symbol)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(tint.light)
                            .frame(width: 34, height: 26)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(each.title).font(.title3.weight(.medium)).lineLimit(1)
                            ForEach(each.lines, id: \.self) { Text($0).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    .opacity(index < arrived ? 1 : 0)
                    .offset(y: index < arrived ? 0 : 12)
                }
            }
            .padding(.top, 28)
            HStack {
                if note.more > 0, let changelog = URL(string: WhatsNew.changelog) {
                    Button {
                        tabManager.revealTab(tabManager.newTab(url: changelog))
                        leave()
                    } label: {
                        Label("\(note.more) more in the changelog", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Continue", action: leave)
                    .buttonStyle(.glassProminent)
                    .tint(tint.base)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 32)
        }
        .padding(40)
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }

    private func leave() {
        withAnimation(.easeIn(duration: 0.35)) { isUp = false } completion: { finish() }
    }
}
