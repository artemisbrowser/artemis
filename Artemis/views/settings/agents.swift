// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// Agents: which coding agents may drive Artemis over MCP, and where.
struct AgentSettings: View {
    private var bridge = AgentBridge.shared
    @State private var copied: String?

    private static let executable = Bundle.main.executablePath!

    private static let setups: [(name: String, command: String)] = [
        ("Claude Code", "claude mcp add --transport stdio artemis -- \"\(executable)\" mcp"),
        ("Codex", "codex mcp add artemis -- \"\(executable)\" mcp"),
        ("JSON", String(decoding: (try? JSONSerialization.data(
            withJSONObject: ["mcpServers": ["artemis": ["command": executable, "args": ["mcp"]]]],
            options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)),
    ]

    var body: some View {
        @Bindable var bridge = bridge
        return Form {
            Section {
                Toggle(isOn: $bridge.isEnabled) {
                    InfoLabel(
                        "Allow coding agents to use Artemis",
                        info: "Lets MCP clients such as Claude Code read and drive tabs in the spaces you allow. Each new agent asks first.")
                }
                if let error = bridge.socketError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Setup") {
                ForEach(Self.setups, id: \.name) { setup in
                    HStack(alignment: .top) {
                        Text(setup.command)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(copied == setup.name ? "Copied" : "Copy \(setup.name)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(setup.command, forType: .string)
                            copied = setup.name
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section {
                ForEach(BrowserCore.shared.spaces) { space in
                    Toggle(
                        space.name,
                        isOn: Binding(
                            get: { bridge.allowedSpaceIDs.contains(space.id) },
                            set: { allowed in
                                if allowed { bridge.allowedSpaceIDs.insert(space.id) } else {
                                    bridge.allowedSpaceIDs.remove(space.id)
                                }
                            }))
                }
                Toggle(isOn: $bridge.allowsScripts) {
                    InfoLabel(
                        "Let agents run scripts in pages",
                        info: "Scripts run with the page's full access, including your signed-in session.")
                }
            } header: {
                InfoLabel("Spaces Agents Can Reach", info: "Incognito windows are never shared.")
            }

            Section("Approved Agents") {
                if bridge.approved.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(bridge.approved, id: \.self) { identity in
                    HStack {
                        Text(identity).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Forget") { bridge.forget(identity) }
                            .controlSize(.small)
                    }
                }
            }

            Section("Connected") {
                if bridge.sessions.isEmpty {
                    Text("No agents connected.").foregroundStyle(.secondary)
                }
                ForEach(bridge.sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text([session.name, session.version].filter { !$0.isEmpty }.joined(separator: " "))
                            if !session.parentPath.isEmpty {
                                Text(session.parentPath).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Disconnect") { session.close() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
