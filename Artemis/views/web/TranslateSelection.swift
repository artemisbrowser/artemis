import SwiftUI
import Translation

extension View {
    /// the system's on-device translation popover, over the page whose selection
    /// is being translated, and the download a page translation may need first
    func translateSelection(for tab: BrowserTab) -> some View {
        modifier(TranslateSelection(tab: tab))
    }
}

private struct TranslateSelection: ViewModifier {
    let tab: BrowserTab

    func body(content: Content) -> some View {
        content.translationPresentation(
            isPresented: Binding(
                get: { tab.pendingTranslation != nil },
                set: { presented in if !presented { tab.clearTranslation() } }),
            text: tab.pendingTranslation ?? "")
        .translationTask(tab.pageTranslationRequest) { await tab.downloadLanguages(with: $0) }
    }
}
