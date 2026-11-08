// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI
import WebKit

/// find-in-page bar over the web card (⌘F): searches as you type, shows current/total matches
struct FindBar: View {
    let tab: BrowserTab
    @Environment(TabManager.self) private var tabManager
    @State private var query = ""
    @State private var matchCount = 0
    @State private var currentMatch = 0
    @FocusState private var isFocused: Bool

    /// the bar asks a question about the page instead of finding text
    @State private var isAsking = false
    @State private var reply: Reply?
    @State private var asked = ""
    /// what the page was read as when the question was asked, for making it stand alone
    @State private var askedPage: String?
    /// the question as general knowledge and search take it
    @State private var resolved = ""
    @State private var isRecalling = false
    @State private var isThinking = false
    @State private var answerTask: Task<Void, Never>?

    private var canAsk: Bool {
        Intelligence.isOn(Intelligence.askPageKey) && Intelligence.isReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if isAsking, isThinking || reply != nil {
                answerPanel
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(12)
        .onAppear {
            isFocused = true
            // ⌥⌘F opens straight into asking
            if tabManager.opensFindBarAsking, canAsk { isAsking = true }
        }
        .onChange(of: query) {
            if !isAsking { startSearch() }
        }
        // ⌘G / ⌘⇧G from the menu: the bar owns the query and the match count,
        // so the menu asks for the next match rather than searching itself
        .onChange(of: tabManager.findNextRequest) {
            if !isAsking { find(forward: true) }
        }
        .onChange(of: tabManager.findPreviousRequest) {
            if !isAsking { find(forward: false) }
        }
        .onExitCommand {
            close()
        }
        .onDisappear { answerTask?.cancel() }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if canAsk {
                Button {
                    isAsking.toggle()
                    answerTask?.cancel()
                    reply = nil
                    isThinking = false
                    isFocused = true
                    if !isAsking { startSearch() }
                } label: {
                    Image(systemName: isAsking ? "sparkle.magnifyingglass" : "magnifyingglass")
                        .foregroundStyle(isAsking ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .tooltip(isAsking ? "Switch to Find" : "Ask about this page")
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }

            TextField(isAsking ? "Ask about this page" : "Find on page", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    if isAsking { ask() } else { find(forward: true) }
                }
                .frame(width: isAsking ? 260 : 170)

            if isAsking {
                if isThinking {
                    ProgressView().controlSize(.small)
                }
            } else if !query.isEmpty {
                Text("\(currentMatch)/\(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !isAsking {
                Button {
                    find(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .tooltip("Previous match")

                Button {
                    find(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .tooltip("Next match")
            }

            Button {
                close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .tooltip("Close", keys: ["esc"])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private enum Reply {
        case page(String)
        case notStated
        case known(String)
        case excuse(String)
    }

    private static let excuses = [
        "No way am I getting that right.", "Sorry, too small for that one.", "You've befuddled me.",
        "That one's above my pay grade.", "I'd only be guessing.", "My tiny brain says no.",
        "Computer says no.",
    ]

    /// the answer and where it came from
    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            switch reply {
            case .page(let text):
                answerText(text)
                footnote("Answered from this page only, on this Mac.")
            case .known(let text):
                resolvedQuestion
                answerText(text)
                footnote("From general knowledge, not this page.")
            case .notStated:
                offer("Not on this page.", action: "Use general knowledge", recall)
            case .excuse(let text):
                resolvedQuestion
                // Scout has no command bar to search from
                if tabManager.kind == .scout {
                    Text(text).font(.system(size: 12))
                } else {
                    offer(text, action: "Search instead", searchInstead)
                }
            case nil:
                Text(isRecalling ? "Thinking…" : "Reading the page…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(width: 340, alignment: .leading)
    }

    /// the question as answered or searched, when the page changed it; search
    /// sends exactly this, so it shows before the link is clicked
    @ViewBuilder private var resolvedQuestion: some View {
        if resolved != asked {
            Text("“\(resolved)”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func answerText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }

    private func offer(_ text: String, action: String, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12))
            Button(action, action: run)
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    // MARK: - Ask

    private func ask() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !question.isEmpty else { return }
        answerTask?.cancel()
        reply = nil
        asked = question
        askedPage = nil
        isRecalling = false
        isThinking = true
        // a replaced task still resumes; only the current one may touch the panel
        answerTask = Task {
            defer { if !Task.isCancelled { isThinking = false } }
            let page = await PageText.focus(from: tab.webView)
            guard !Task.isCancelled else { return }
            askedPage = page?.text
            guard let page else {
                reply = Intelligence.asksForSummary(question)
                    ? .page("There's no readable text on this page.") : .notStated
                return
            }
            var answer = await Intelligence.shared.answer(
                question: question, pageText: page.text, actions: page.actions)
            guard !Task.isCancelled else { return }
            // a fact outside the main region, such as a footer's phone number
            if !Intelligence.asksForSummary(question),
                answer?.localizedCaseInsensitiveContains("not stated") == true,
                let whole = await PageText.extract(from: tab.webView), whole != page.text
            {
                answer = await Intelligence.shared.answer(question: question, pageText: whole)
                guard !Task.isCancelled else { return }
            }
            let sentinel = answer?.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == "not stated"
            reply = sentinel && !Intelligence.asksForSummary(question)
                ? .notStated : .page(answer ?? "Couldn't answer that one.")
        }
    }

    private func recall() {
        answerTask?.cancel()
        reply = nil
        isRecalling = true
        isThinking = true
        answerTask = Task {
            defer { if !Task.isCancelled { isThinking = false } }
            let question = await Intelligence.shared.standalone(question: asked, pageText: askedPage)
            guard !Task.isCancelled else { return }
            resolved = question
            // freshness is judged on the words typed: a rewrite can drop "still" or "now"
            let recalled: Intelligence.Recall =
                Intelligence.needsLiveData(asked) ? .unsure : await Intelligence.shared.recall(question: question)
            guard !Task.isCancelled else { return }
            if case .known(let text) = recalled {
                reply = .known(text)
            } else {
                reply = .excuse(Self.excuses.randomElement()!)
            }
        }
    }

    /// ⌘T with the question typed in, so Return searches it
    private func searchInstead() {
        tabManager.commandBarSeed = resolved
        close()
        tabManager.openNewTabBar()
    }

    // MARK: - Search

    /// search-as-you-type: recount, restart from the top of the page
    private func startSearch() {
        guard !query.isEmpty else {
            matchCount = 0
            currentMatch = 0
            clearSelection()
            return
        }
        updateMatchCount()
        clearSelection {
            find(forward: true, fromStart: true)
        }
    }

    private func find(forward: Bool, fromStart: Bool = false) {
        guard !query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        tab.webView.find(query, configuration: configuration) { result in
            guard result.matchFound else {
                currentMatch = 0
                return
            }
            if fromStart || currentMatch == 0 {
                currentMatch = 1
            } else if forward {
                currentMatch = matchCount > 0 ? (currentMatch % matchCount) + 1 : 0
            } else {
                currentMatch = matchCount > 0 ? ((currentMatch - 2 + matchCount) % matchCount) + 1 : 0
            }
        }
    }

    /// count occurrences in the page text; split-based so no regex escaping
    private func updateMatchCount() {
        guard let data = try? JSONSerialization.data(withJSONObject: [query]),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let script =
            "(((document.body && document.body.innerText) || '').toLowerCase()"
            + ".split(\(json)[0].toLowerCase()).length - 1)"
        tab.webView.evaluateJavaScript(script) { result, _ in
            matchCount = (result as? Int) ?? ((result as? Double).map(Int.init) ?? 0)
        }
    }

    private func clearSelection(_ then: (() -> Void)? = nil) {
        tab.webView.evaluateJavaScript("window.getSelection().removeAllRanges()") { _, _ in
            then?()
        }
    }

    private func close() {
        tabManager.isFindBarVisible = false
        clearSelection()
    }
}
