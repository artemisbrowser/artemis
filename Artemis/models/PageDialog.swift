// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// a question a page is blocked on: `alert()`, `confirm()`, `prompt()`, leaving
/// with unsaved work, or handing a link to another app. WebKit traps if a
/// completion handler runs twice, so every path answers through `answer`
@MainActor
final class PageDialogRequest: Identifiable {
    enum Kind: Equatable {
        case alert
        case confirm
        case prompt(defaultText: String)
        /// `beforeunload`; the page's own message is never shown
        case leaveConfirm
        /// a link in a scheme WebKit doesn't render; `appName` is the app macOS says handles it
        case openExternal(scheme: String, appName: String)
        /// basic, digest or NTLM sign-in; the server's realm text is never shown
        case httpAuth

        /// the page's scripts are held until the user answers
        var stallsPage: Bool {
            switch self {
            case .openExternal, .httpAuth: false
            default: true
            }
        }
    }

    /// the optional checkbox above the buttons
    enum Checkbox: Equatable {
        /// "Don't let this page create more dialogs"
        case silencePage
        /// the site may be trusted with this app, or with every app: a menu, not a checkbox
        case rememberChoice
    }

    let id = UUID()
    let kind: Kind
    let message: String
    /// host of the frame that asked, for the "example.com says" line. empty for
    /// an opaque origin (a `data:` or sandboxed frame), which then goes unnamed
    let host: String
    let checkbox: Checkbox?
    /// the address a sign-in is for, which the pill shows while it is up
    let url: URL?
    /// when it went up; an app it offers can't be opened within `PermissionPrompt.armDelay` of this
    let asked = Date()
    private var respond: ((Answer) -> Void)?

    /// what came back from the panel; `secondary` is a second field's text
    struct Answer {
        var confirmed: Bool
        var text: String = ""
        var secondary: String = ""
    }

    init(
        kind: Kind, message: String, host: String, checkbox: Checkbox? = nil, url: URL? = nil,
        respond: @escaping (Answer) -> Void
    ) {
        self.kind = kind
        self.message = message
        self.host = host
        self.checkbox = checkbox
        self.url = url
        self.respond = respond
    }

    func answer(_ confirmed: Bool, text: String = "", secondary: String = "") {
        let respond = self.respond
        self.respond = nil
        respond?(Answer(confirmed: confirmed, text: text, secondary: secondary))
    }

    /// the tab or page went away with the question open; a pending
    /// `beforeunload` resolves as "leave"
    func abandon() { answer(kind == .leaveConfirm) }
}
