// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// where links open: rules sending a site to a space, links handed over by
/// other apps, and the Peek and Scout previews. A rule is a glob over
/// `host/path`, and the first one that matches wins, so the list is reorderable.
struct LinksSettings: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage("externalLinkRouting") private var externalRaw = ExternalLinkRouting.scout.rawValue
    @AppStorage(PeekControlsCorner.storageKey) private var peekControlsCornerRaw = PeekControlsCorner.topTrailing.rawValue
    @State private var routing = RoutingStore.shared
    @State private var draftPattern = ""
    @State private var draftSpaceID: UUID?
    @State private var sentence = ""
    @State private var proposal: RoutingProposal?
    @State private var thinking = false
    @State private var declined: String?

    var body: some View {
        Form {
            Section {
                if routing.rules.isEmpty {
                    Text("No rules yet. A rule sends a site to a space, and a space signs in as its profile, so the same site can be two different logins.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(routing.rules) { rule in
                    ruleRow(rule)
                }
                .onMove { routing.move(fromOffsets: $0, toOffset: $1) }
                addRow
            } header: {
                InfoLabel(
                    "Rules",
                    info: "Patterns match the host and path, so *.github.com covers every subdomain. Logins differ only between spaces in different profiles.")
            }

            Section {
                HStack(spacing: 10) {
                    // in a Form a TextField's title becomes a leading label,
                    // so the example goes in the prompt instead
                    TextField(
                        "", text: $sentence,
                        prompt: Text("Keep my work GitHub in the Work space"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(ask)
                    Button("Draft", action: ask)
                        .disabled(thinking || sentence.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if thinking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Drafting, then checking it against its own examples…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let declined {
                    Label(declined, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                if let proposal { proposalView(proposal) }
            } header: {
                InfoLabel(
                    "Describe a rule",
                    info: "Write a sentence and Artemis drafts a rule from it on this Mac. Nothing is added until you approve it.")
            }

            Section("Links from other apps") {
                Picker(selection: $externalRaw) {
                    ForEach(ExternalLinkRouting.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                } label: {
                    InfoLabel(
                        "A link that matches a rule",
                        info: "Links that match no rule always open in Scout.")
                }
                .pickerStyle(.radioGroup)
            }

            Section("Peek") {
                Picker(selection: $peekControlsCornerRaw) {
                    ForEach(PeekControlsCorner.allCases) { corner in
                        Text(corner.label).tag(corner.rawValue)
                    }
                } label: {
                    InfoLabel(
                        "Controls corner",
                        info: "The corner that holds Peek's buttons. ⇧-click a link to open it in Peek.")
                }
            }

            Section("Scout") {
                ScoutBarSetting()
            }
        }
        .formStyle(.grouped)
    }

    /// what the model drafted, with the outcome of checking it; a rule that fails
    /// its own examples is shown with the problem but can't be added
    @ViewBuilder
    private func proposalView(_ proposal: RoutingProposal) -> some View {
        let destination = tabManager.spaces.first { $0.name == proposal.spaceName }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(proposal.pattern)
                    .font(.system(.body, design: .monospaced))
                Text("→ \(proposal.spaceName)")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(
                    proposal.source == .model
                        ? (proposal.revised ? "corrected on the second pass" : "drafted on device")
                        : "read from your sentence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem = proposal.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            } else if !proposal.examples.isEmpty {
                Text("Catches \(proposal.examples.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Add rule") {
                    if let destination {
                        routing.add(pattern: proposal.pattern, spaceID: destination.id)
                    }
                    self.proposal = nil
                    sentence = ""
                }
                .disabled(destination == nil || proposal.problem != nil)
                Button("Discard") { self.proposal = nil }
            }
        }
    }

    private func ask() {
        let request = sentence
        guard !thinking, !request.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        proposal = nil
        declined = nil
        let names = tabManager.spaces.map(\.name)
        Intelligence.refreshReadiness()
        guard Intelligence.isOn(Intelligence.enabledKey), Intelligence.isReady else {
            propose(RoutingRule.suggest(from: request, spaces: names))
            return
        }
        thinking = true
        Task {
            let answer = await Intelligence.shared.routingRule(from: request, spaces: names)
            thinking = false
            propose(answer ?? RoutingRule.suggest(from: request, spaces: names))
        }
    }

    private func propose(_ answer: RoutingProposal?) {
        proposal = answer
        declined = answer == nil ? "Nothing in that sentence named a site and a space." : nil
    }

    @ViewBuilder
    private func ruleRow(_ rule: RoutingRule) -> some View {
        let destination = tabManager.spaces.first { $0.id == rule.spaceID }
        HStack(spacing: 10) {
            Text(rule.pattern)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let destination {
                SpaceGlyph(icon: destination.icon, size: 12)
                    .foregroundStyle(destination.appearance.accent)
                Text(destination.name)
                    .foregroundStyle(.secondary)
            } else {
                Label("Space deleted", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            Button {
                routing.remove(rule)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove rule")
            .foregroundStyle(.secondary)
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            TextField("*.example.com/path/*", text: $draftPattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(commit)
            Picker("", selection: $draftSpaceID) {
                Text("Choose a space").tag(UUID?.none)
                ForEach(tabManager.spaces) { space in
                    Text(space.name).tag(UUID?.some(space.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)
            Button("Add", action: commit)
                .disabled(draftPattern.trimmingCharacters(in: .whitespaces).isEmpty
                    || draftSpaceID == nil)
        }
    }

    private func commit() {
        guard let spaceID = draftSpaceID, !draftPattern.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        routing.add(pattern: draftPattern, spaceID: spaceID)
        draftPattern = ""
    }
}
