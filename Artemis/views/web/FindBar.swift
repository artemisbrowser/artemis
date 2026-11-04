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
    @State private var answer: String?
    @State private var isThinking = false
    @State private var answerTask: Task<Void, Never>?

    private var canAsk: Bool {
        Intelligence.isOn(Intelligence.askPageKey) && Intelligence.isReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if isAsking, isThinking || answer != nil {
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
                    answer = nil
                    isFocused = true
                    if !isAsking { startSearch() } else { clearSelection() }
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

    /// the answer and where on the page it came from
    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let answer {
                Text(answer)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Answered from this page only, on this Mac.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Reading the page…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(width: 340, alignment: .leading)
    }

    // MARK: - Ask

    private func ask() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !question.isEmpty else { return }
        answerTask?.cancel()
        answer = nil
        isThinking = true
        answerTask = Task {
            defer { isThinking = false }
            guard let text = await PageText.extract(from: tab.webView) else {
                answer = "There's no readable text on this page."
                return
            }
            let reply = await Intelligence.shared.answer(question: question, pageText: text)
            guard !Task.isCancelled else { return }
            answer = reply ?? "Couldn't answer that one."
        }
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
