import SwiftUI

/// a setting's name with its explanation tucked behind an ⓘ beside it
struct InfoLabel: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(info)
        }
    }
}

/// an ⓘ whose explanation appears in a glass popover while the pointer rests on it
struct InfoButton: View {
    let text: String
    @State private var isShown = false
    @State private var dwell: Task<Void, Never>?

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(isShown ? .primary : .secondary)
            .contentShape(Circle())
            .onHover { hovering in
                dwell?.cancel()
                guard hovering else { return isShown = false }
                // a short dwell, so sweeping the pointer down a list doesn't flash every one
                dwell = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !Task.isCancelled { isShown = true }
                }
            }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
            .accessibilityLabel(text)
    }
}
