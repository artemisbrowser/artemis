// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// "example.com says …": whatever question the page is blocked on. scoped to the
/// pane that asked, so the rest of the window stays live while it waits
struct PageDialogPanel: View {
    let tab: BrowserTab
    let request: PageDialogRequest
    /// false over a warm page mounted out of sight, which neither speaks nor takes focus
    let isShown: Bool

    @State private var text = ""
    @State private var secondary = ""
    @State private var checked = false
    @FocusState private var fieldFocused: Bool
    /// VoiceOver's cursor, moved onto the question: an overlay isn't a window it notices opening
    @AccessibilityFocusState private var titleFocused: Bool

    /// a long host is cut in the labels before its registrable domain, which stays whole
    private var site: String {
        let host = request.host
        guard !host.isEmpty else { return "This page" }
        let domain = PasswordStore.registrableDomain(host) ?? host
        let lead = host.dropLast(domain.count + 1), room = max(6, 38 - domain.count)
        return host.count > 40 && lead.count > room ? "\(lead.prefix(room))….\(domain)" : host
    }

    private var title: String {
        switch request.kind {
        case .leaveConfirm: "Leave this page?"
        case .openExternal(_, let appName):
            "Open \(appName)?"
        case .httpAuth: "Sign in to \(site)"
        default: "\(site) says"
        }
    }

    private var detail: String {
        switch request.kind {
        // never the page's own text
        case .leaveConfirm: "Changes you made may not be saved."
        case .openExternal(let scheme, let appName):
            "\(site) wants to open \(appName) with a “\(scheme):” link."
        case .httpAuth(let realm):
            // the realm is the server's name for what it protects
            realm.map { "The server says: \($0)" } ?? "This server is asking for a username and password."
        default: request.message
        }
    }

    private var checkboxLabel: String {
        switch request.checkbox {
        case .silencePage: "Don't let this page create more dialogs"
        case .rememberChoice, nil: ""
        }
    }

    private var confirmLabel: String {
        switch request.kind {
        case .leaveConfirm: "Leave"
        case .openExternal: "Open"
        case .httpAuth: "Sign In"
        default: "OK"
        }
    }

    private var cancelLabel: String? {
        switch request.kind {
        case .alert: nil
        case .leaveConfirm: "Stay"
        default: "Cancel"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityFocused($titleFocused)

                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .prompt = request.kind {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit { answer(true) }
                }

                if case .httpAuth = request.kind {
                    TextField("Username", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                    SecureField("Password", text: $secondary)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { answer(true) }
                }

                if request.checkbox == .silencePage {
                    Toggle(checkboxLabel, isOn: $checked)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if case .openExternal(_, let appName) = request.kind {
                    // Cancel answers Return and Escape: opening an app is never the default
                    HStack(spacing: 8) {
                        if request.checkbox == .rememberChoice {
                            Menu("Trust") {
                                Button("Trust \(site) to open \(appName)") { answer(true, trustEveryApp: false) }
                                Button("Trust \(site) to open all apps") { answer(true, trustEveryApp: true) }
                            }
                            .fixedSize()
                        }
                        Spacer(minLength: 0)
                        Button(confirmLabel) { answer(true) }
                        Button("Cancel") { answer(false) }
                            .keyboardShortcut(.defaultAction)
                            .background(
                                Button("") { answer(false) }
                                    .keyboardShortcut(.cancelAction)
                                    .opacity(0)
                                    .accessibilityHidden(true))
                    }
                } else {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if let cancelLabel {
                            Button(cancelLabel) { answer(false) }
                                .keyboardShortcut(.cancelAction)
                        }
                        Button(confirmLabel) { answer(true) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .accessibilityElement(children: .contain)
            .disabled(!isShown)
        }
        .transition(.opacity)
        .accessibilityHidden(!isShown)
        .onAppear {
            if case .prompt(let defaultText) = request.kind { text = defaultText }
        }
        .onChange(of: isShown, initial: true) {
            guard isShown else { return }
            switch request.kind {
            case .prompt, .httpAuth: fieldFocused = true
            default: titleFocused = true
            }
            AccessibilityNotification.Announcement(detail.isEmpty ? title : "\(title). \(detail)").post()
        }
        // a fresh question never inherits the last one's typed text or checkbox
        .id(request.id)
    }

    private func answer(_ confirmed: Bool, trustEveryApp: Bool? = nil) {
        tab.answerDialog(confirmed, text: text, secondary: secondary, checked: checked, trustEveryApp: trustEveryApp)
    }
}

extension View {
    /// overlays whatever question `tab`'s page is blocked on; every surface that
    /// hosts a web view must apply it, or the dialog is never drawn
    func pageDialog(for tab: BrowserTab, isShown: Bool = true) -> some View {
        overlay {
            if let request = tab.pendingDialog {
                PageDialogPanel(tab: tab, request: request, isShown: isShown)
            }
        }
        .animation(Motion.fade, value: tab.pendingDialog?.id)
    }
}
