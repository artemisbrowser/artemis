import SwiftUI

/// "example.com says …" — whatever question the page is blocked on.
///
/// Scoped to the page rather than the window: the sidebar, the command bar and
/// every other tab stay live while one page waits for an answer, which is both
/// what a tabbed browser owes you and what stops a page from holding the app.
/// The scrim covers only the pane that asked, so in a split the other pane is
/// still readable — and clicking it does nothing, because WebKit is holding a
/// handler that has to be answered.
struct PageDialogPanel: View {
    let tab: BrowserTab
    let request: PageDialogRequest

    @State private var text = ""
    @State private var secondary = ""
    @State private var checked = false
    @FocusState private var fieldFocused: Bool

    private var site: String { request.host.isEmpty ? "This page" : request.host }

    private var title: String {
        switch request.kind {
        case .leaveConfirm: "Leave this page?"
        case .openExternal(let scheme, let appName):
            appName.map { "Open “\($0)”?" } ?? "Open a “\(scheme):” link?"
        case .httpAuth: "Sign in to \(site)"
        default: request.host.isEmpty ? "This page says" : "\(request.host) says"
        }
    }

    private var detail: String {
        switch request.kind {
        // never the page's own text: letting a page write this warning is
        // letting it write the ransom note
        case .leaveConfirm: "Changes you made may not be saved."
        case .openExternal(_, let appName):
            appName.map { "\(site) wants to open this link in \($0)." }
                ?? "\(site) wants to open this link in another app. Nothing on this Mac handles it."
        case .httpAuth(let realm):
            // the realm is the server's own name for what it's protecting, and
            // often the only clue which of several logins is wanted
            realm.map { "The server says: \($0)" } ?? "This server is asking for a username and password."
        default: request.message
        }
    }

    private var checkboxLabel: String {
        switch request.checkbox {
        case .silencePage: "Don't let this page create more dialogs"
        case .rememberChoice:
            if case .openExternal(_, let appName) = request.kind, let appName {
                "Always let \(site) open \(appName)"
            } else {
                "Always allow this"
            }
        case nil: ""
        }
    }

    private var confirmLabel: String {
        switch request.kind {
        case .leaveConfirm: "Leave"
        case .openExternal(_, let appName): appName == nil ? "Try Anyway" : "Open"
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

                if request.checkbox != nil {
                    Toggle(checkboxLabel, isOn: $checked)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

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
            .padding(16)
            .frame(width: 360, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        }
        .transition(.opacity)
        .onAppear {
            if case .prompt(let defaultText) = request.kind {
                text = defaultText
                fieldFocused = true
            }
            if case .httpAuth = request.kind { fieldFocused = true }
        }
        // a fresh question never inherits the last one's typed text or checkbox
        .id(request.id)
    }

    private func answer(_ confirmed: Bool) {
        tab.answerDialog(confirmed, text: text, secondary: secondary, checked: checked)
    }
}

extension View {
    /// overlay whatever question `tab`'s page is blocked on. Applied by every
    /// surface that hosts a web view — main card, split pane, Peek, Scout — so a
    /// dialog can't be raised somewhere it would never be drawn.
    func pageDialog(for tab: BrowserTab) -> some View {
        overlay {
            if let request = tab.pendingDialog {
                PageDialogPanel(tab: tab, request: request)
            }
        }
        .animation(Motion.fade, value: tab.pendingDialog?.id)
    }
}
