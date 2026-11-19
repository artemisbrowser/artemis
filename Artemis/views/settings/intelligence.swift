// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the intelligence pane: the engines that can run a feature, then one switch per
/// feature, each off until it is turned on
struct IntelligenceSettings: View {
    /// a copy the pane can observe: `Intelligence.readiness` is a plain cache
    @State private var readiness = Intelligence.readiness
    @State private var engines = IntelligenceEngine.all
    @State private var isAdding = false
    @AppStorage(AgentTask.enabledKey) private var agentIsOn = false
    @AppStorage(AgentTask.fillsSavedKey) private var agentFillsSaved = false
    private var isReady: Bool { readiness == .ready }

    var body: some View {
        Form {
            Section {
                LabeledContent("Apple on-device model", value: isReady ? "Ready" : "Unavailable")
                    .settingsAnchor(.onDeviceModel)
                if !isReady {
                    Label(readiness.explanation, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Apple Intelligence Settings") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                ForEach(engines) { engine in
                    LabeledContent {
                        Button("Remove", role: .destructive) { remove(engine) }
                    } label: {
                        Text(engine.name)
                        Text("\(engine.model) · \(engine.isOnThisMac ? "this Mac" : engine.host)")
                    }
                }
                Button("Add Engine…") { isAdding = true }
                    .settingsAnchor(.addEngine)
            } header: {
                InfoLabel(
                    "Engines",
                    info: "Apple's model is built into macOS and never leaves this Mac. Add a local server or your own API key to read longer pages."
                )
            }

            Section("Features") {
                FeatureRow(
                    Intelligence.tidyTitlesKey, "Tidy tab names",
                    info: "Gives pinned tabs and favourites short names. Tabs you named yourself are never changed.",
                    sends: "page titles and descriptions", anchor: .tidyTabNames, engines: engines, isAppleReady: isReady
                ) {
                    // names you typed yourself are untouched
                    TabNameStore.shared.clearAllGenerated()
                    Task { await Intelligence.shared.reset() }
                }
                FeatureRow(
                    Intelligence.askPageKey, "Ask about this page (⌘F)",
                    info: "Adds a question mode to Find that answers only from the current page.",
                    sends: "the page's text and your question", anchor: .askAboutPage, engines: engines,
                    isAppleReady: isReady)
                FeatureRow(
                    Intelligence.iconIdeasKey, "Icon ideas",
                    info: "Suggests icons for a space from its name, and for what you type in the icon picker.",
                    sends: "what you type", anchor: .iconIdeas, engines: engines, isAppleReady: isReady)
                FeatureRow(
                    Intelligence.settingsSearchKey, "Ask in Settings search",
                    info: "Finds a setting from a question when no name matches.",
                    sends: "what you type", anchor: .askSettings, engines: engines, isAppleReady: isReady)
                FeatureRow(
                    Intelligence.routingRulesKey, "Link rules from a sentence",
                    info: "Drafts a link rule from a sentence you write. Nothing is saved until you confirm it.",
                    sends: "your sentence and space names", anchor: .rulesFromWords, engines: engines,
                    isAppleReady: isReady)
            }

            Section("Built-in Agent") {
                Toggle(isOn: Binding(get: { agentIsOn }, set: { AgentTask.isEnabled = $0 }).undoable("Built-in agent")) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        InfoLabel(
                            "Built-in agent",
                            info: "Works in your tabs when you ask, from File > Ask Agent. It runs on Claude Code on this Mac, "
                                + "under your Claude account, and counts against that plan.")
                        if agentIsOn {
                            Text("Claude Code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .settingsAnchor(.builtInAgent)
                Toggle(isOn: $agentFillsSaved) {
                    InfoLabel(
                        "Let the agent fill saved passwords and cards",
                        info: "Artemis fills them itself and asks for \(OwnerUnlock.method) every time. The agent never sees them.")
                }
                .disabled(!agentIsOn)
                .settingsAnchor(.agentFillsSaved)
            }

            AgentSections()
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshReadiness)
        // coming back from System Settings, where Apple Intelligence is switched on
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
        .sheet(isPresented: $isAdding) {
            AddEngineSheet { engine in
                engines.append(engine)
                IntelligenceEngine.all = engines
            }
        }
    }

    private func refreshReadiness() {
        Intelligence.refreshReadiness()
        readiness = Intelligence.readiness
    }

    /// features that ran on the engine go back to Apple's model
    private func remove(_ engine: IntelligenceEngine) {
        engine.key = ""
        engines.removeAll { $0.id == engine.id }
        IntelligenceEngine.all = engines
        for key in Intelligence.featureKeys.map(Intelligence.engineKey)
        where UserDefaults.standard.string(forKey: key) == engine.id.uuidString {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private struct FeatureRow: View {
    private let title: String
    private let info: String
    /// what a request carries, as the words after "Sends"
    private let sends: String
    private let anchor: SettingID
    private let engines: [IntelligenceEngine]
    private let isAppleReady: Bool
    private let turnedOff: () -> Void
    @AppStorage private var isOn: Bool
    /// an engine's id, or empty for Apple's model
    @AppStorage private var engineID: String

    init(
        _ key: String, _ title: String, info: String, sends: String, anchor: SettingID,
        engines: [IntelligenceEngine], isAppleReady: Bool, turnedOff: @escaping () -> Void = {}
    ) {
        self.title = title
        self.info = info
        self.sends = sends
        self.anchor = anchor
        self.engines = engines
        self.isAppleReady = isAppleReady
        self.turnedOff = turnedOff
        _isOn = AppStorage(wrappedValue: false, key)
        _engineID = AppStorage(wrappedValue: "", Intelligence.engineKey(key))
    }

    var body: some View {
        let engine = engines.first { $0.id.uuidString == engineID }
        let remote = engine.flatMap { $0.isOnThisMac ? nil : $0 }
        Toggle(isOn: $isOn.undoable(title)) {
            // the row hangs its switch off the label's text baseline, so the tag shares the title's
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                InfoLabel(title, info: remote.map { "\(info) Sends \(sends) to \($0.host)." } ?? info)
                if isOn {
                    Text(remote?.host ?? "On this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // turning it off never needs a model
        .disabled(engine == nil && !isAppleReady && !isOn)
        .settingsAnchor(anchor)
        .onChange(of: isOn) { if !isOn { turnedOff() } }
        if !engines.isEmpty {
            Picker("Runs on", selection: $engineID) {
                Text("Apple on-device model").tag("")
                ForEach(engines) { Text("\($0.name) · \($0.model)").tag($0.id.uuidString) }
            }
        }
    }
}

private struct AddEngineSheet: View {
    let add: (IntelligenceEngine) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()
    @State private var preset = IntelligenceEngine.Preset.ollama
    @State private var address = IntelligenceEngine.Preset.ollama.baseURL
    @State private var key = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var wordBudget = 1500
    @State private var problem: String?

    private var draft: IntelligenceEngine? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.host() != nil else { return nil }
        return IntelligenceEngine(
            id: id, name: preset == .custom ? url.host() ?? "Custom" : preset.rawValue, baseURL: url,
            model: model.trimmingCharacters(in: .whitespaces), wordBudget: wordBudget)
    }

    var body: some View {
        Form {
            Picker("Kind", selection: $preset) {
                ForEach(IntelligenceEngine.Preset.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Address", text: $address, prompt: Text("https://example.com/v1"))
            SecureField("API key", text: $key, prompt: Text(draft?.isOnThisMac == true ? "Not needed" : "Required"))
            if models.isEmpty {
                TextField("Model", text: $model)
            } else {
                Picker("Model", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            Button("Find Models") { Task { await findModels() } }
                .disabled(draft == nil)
            Picker(selection: $wordBudget) {
                Text("Short, 1,500 words").tag(1500)
                Text("Medium, 6,000 words").tag(6000)
                Text("Long, 24,000 words").tag(24000)
            } label: {
                InfoLabel(
                    "Page text",
                    info: "How much of a page goes with a question. Longer needs a model with a larger context window.")
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let draft {
                Text(draft.isOnThisMac ? "Stays on this Mac." : "Features you point here send their text to \(draft.host).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    guard let draft else { return }
                    draft.key = key
                    add(draft)
                    dismiss()
                }
                .disabled(draft?.model.isEmpty != false)
            }
        }
        .onChange(of: preset) {
            address = preset.baseURL
            models = []
            model = ""
            problem = nil
            wordBudget = draft?.isOnThisMac == true ? 1500 : 6000
        }
        // a local server needs no key, so its models can be listed straight away
        .task(id: preset) { if draft?.isOnThisMac == true { await findModels() } }
    }

    private func findModels() async {
        guard let draft else { return }
        let asked = [address, key]
        do {
            let found = try await draft.models(key: key)
            // the answer is for the address and key it was asked with
            guard asked == [address, key] else { return }
            models = found
            if !models.contains(model) { model = models.first ?? "" }
            problem = models.isEmpty ? "The server lists no models." : nil
        } catch {
            guard asked == [address, key] else { return }
            problem =
                switch (error as? IntelligenceEngine.Refusal)?.status {
                case 401: "The server refused the key."
                case let status?: "The server answered \(status)."
                case nil: "Couldn't reach \(draft.host). Is the server running?"
                }
        }
    }
}
