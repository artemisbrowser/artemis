import Foundation

/// A question a page has put to the user and is blocked on: `alert()`,
/// `confirm()`, `prompt()`, leaving a page with unsaved work, or handing a link
/// to another app.
///
/// WebKit holds a completion handler for the JavaScript ones and traps if it is
/// called twice, so every path — the buttons, a navigation, the tab closing —
/// goes through `answer`, which drops the handler after the first call.
@MainActor
final class PageDialogRequest: Identifiable {
    enum Kind: Equatable {
        case alert
        case confirm
        case prompt(defaultText: String)
        /// `beforeunload`. The page's own message is ignored: letting a page
        /// write the warning is letting it write the ransom note
        case leaveConfirm
        /// a link in a scheme WebKit doesn't render; `appName` is whichever app
        /// macOS says would handle it, nil when nothing is installed
        case openExternal(scheme: String, appName: String?)
        /// a server asking who you are — basic, digest or NTLM. `realm` is the
        /// server's own name for the area being protected, shown as-is because
        /// it is often the only clue which of several logins is wanted
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

    /// what came back from the panel. `secondary` is only used where a question
    /// has two fields, which today means a password
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

    /// the tab or the page went away with the question still on screen.
    /// A pending `beforeunload` resolves as "leave" — anything else would keep a
    /// closing tab alive waiting for an answer nobody can give
    func abandon() { answer(kind == .leaveConfirm) }
}
