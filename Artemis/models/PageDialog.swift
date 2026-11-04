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
        /// a link in a scheme WebKit doesn't render; `appName` is whichever app
        /// macOS says would handle it, nil when nothing is installed
        case openExternal(scheme: String, appName: String?)
        /// basic, digest or NTLM sign-in; `realm` is the server's own text, shown as-is
        case httpAuth(realm: String?)
    }

    /// the optional checkbox above the buttons
    enum Checkbox: Equatable {
        /// "Don't let this page create more dialogs"
        case silencePage
        /// "Always allow this site to open <app>"
        case rememberChoice
    }

    let id = UUID()
    let kind: Kind
    let message: String
    /// host of the frame that asked, for the "example.com says" line. empty for
    /// an opaque origin (a `data:` or sandboxed frame), which then goes unnamed
    let host: String
    let checkbox: Checkbox?
    private var respond: ((Answer) -> Void)?

    /// what came back from the panel; `secondary` is a second field's text
    struct Answer {
        var confirmed: Bool
        var text: String = ""
        var secondary: String = ""
    }

    init(
        kind: Kind, message: String, host: String, checkbox: Checkbox? = nil,
        respond: @escaping (Answer) -> Void
    ) {
        self.kind = kind
        self.message = message
        self.host = host
        self.checkbox = checkbox
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
