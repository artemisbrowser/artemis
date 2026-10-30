import SwiftUI

/// "meet.google.com wants to use your camera and microphone."
///
/// Anchored to the top-leading corner of the page, where the site's own content
/// is, rather than floating in the middle of the window: the question is about
/// the page, and a modal sheet over the whole browser would be both heavier than
/// the decision deserves and easy to mistake for something the *browser* wants.
///
/// It deliberately has no dismiss affordance. WebKit is holding a decision
/// handler for this request and it has to be answered; the two buttons are the
/// only ways out, and closing the tab answers it with a refusal.
struct PermissionPrompt: View {
    @Environment(TabManager.self) private var tabManager
    let request: PermissionRequest

    /// on by default — being asked the same question on every page load is how
    /// browsers train people to click Allow without reading
    @State private var remember = true

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
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
        // a fresh question gets a fresh checkbox, and never inherits the last
        // site's answer
        .id(request.id)
    }
}
