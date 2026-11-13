// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// a site's camera, microphone or location question, over the page that asked. no dismiss:
/// WebKit's handler is answered by a button, or refused when the tab closes. input already
/// on its way as it appears must not grant: no key allows, and Allow is dead for `armDelay`
struct PermissionPrompt: View {
    static let armDelay = Duration.milliseconds(600)

    @Environment(TabManager.self) private var tabManager
    let request: PermissionRequest

    @State private var remember = false
    @State private var armed = false

    private var host: String {
        request.origin
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(request.permissions) { permission in
                    Image(systemName: permission.icon)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.1), in: .circle)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(host)
                        .font(.system(size: 13, weight: .semibold))
                    Text("wants to \(request.summary).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Remember this for \(host)", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Don't Allow") {
                    tabManager.answerPermission(.deny, remember: remember)
                }
                .keyboardShortcut(.cancelAction)
                Button("Allow") {
                    tabManager.answerPermission(.allow, remember: remember)
                }
                .disabled(!armed)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
        // the page stays live under it, so VoiceOver is told rather than moved
        .task {
            try? await Task.sleep(for: Self.armDelay)
            armed = !Task.isCancelled
        }
        .onAppear { AccessibilityNotification.Announcement("\(host) wants to \(request.summary).").post() }
        // a fresh question never inherits the last one's checkbox or its armed Allow
        .id(request.id)
    }
}
