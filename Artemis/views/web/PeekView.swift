import AppKit
import SwiftUI

/// which corner the Peek's floating control stack sits in
enum PeekControlsCorner: String, CaseIterable, Identifiable {
    case topTrailing, topLeading, bottomTrailing, bottomLeading

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topTrailing: return "Top Right"
        case .topLeading: return "Top Left"
        case .bottomTrailing: return "Bottom Right"
        case .bottomLeading: return "Bottom Left"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topTrailing: return .topTrailing
        case .topLeading: return .topLeading
        case .bottomTrailing: return .bottomTrailing
        case .bottomLeading: return .bottomLeading
        }
    }

    static let storageKey = "peekControlsCorner"
}

/// Peek / Glance — a floating preview of a ⇧-clicked link over the current page.
/// Just the page in a rounded rectangle, with a stack of liquid-glass buttons in
/// a corner: close, open as a tab, or split it beside the current tab. ESC or a
/// click on the dimmed backdrop dismisses it. The preview is a throwaway web view
/// (`TabManager.peekTab`) born in the current space's container, so logins carry.
struct PeekView: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage(PeekControlsCorner.storageKey) private var cornerRaw = PeekControlsCorner.topTrailing.rawValue
    let tab: BrowserTab
    @State private var escMonitor: Any?

    private var corner: PeekControlsCorner { PeekControlsCorner(rawValue: cornerRaw) ?? .topTrailing }

    var body: some View {
        ZStack {
            // dim backdrop; a click anywhere off the panel dismisses
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { tabManager.closePeek() }

            panel
                .frame(maxWidth: 1120, maxHeight: 820)
                .padding(56)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .onAppear { startEscMonitor() }
        .onDisappear { stopEscMonitor() }
    }

    private var panel: some View {
        ZStack {
            Color(white: 0.1)
            WebViewContainer(tab: tab)
                // a container rebuild (new web view, same tab) re-mounts the host
                .id("\(tab.id)#\(tab.webViewGeneration)")
                .opacity(tab.loadError == nil ? 1 : 0)
            if tab.loadError != nil { ErrorPage(tab: tab) }
        }
        .pageDialog(for: tab)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        // the controls sit just outside the panel, anchored to the chosen corner
        .overlay(alignment: corner.alignment) {
            controls.offset(controlsOffset)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            PeekControlButton(symbol: "xmark", help: "Close (Esc)") {
                tabManager.closePeek()
            }
            PeekControlButton(symbol: "rectangle.stack.badge.plus", help: "Open as a tab") {
                tabManager.promotePeek()
            }
            PeekControlButton(symbol: "rectangle.split.2x1", help: "Split with the current tab") {
                tabManager.splitPeekWithCurrent()
            }
        }
    }

    /// push the control stack outside the panel — left of left corners, right of
    /// right ones; vertical anchoring (top/bottom) comes from the overlay alignment
    private var controlsOffset: CGSize {
        let dx: CGFloat = 42  // button (30) + gap, clears the panel edge
        switch corner {
        case .topTrailing, .bottomTrailing: return CGSize(width: dx, height: 0)
        case .topLeading, .bottomLeading: return CGSize(width: -dx, height: 0)
        }
    }

    // ESC dismiss — a local key monitor is reliable over a WKWebView, where SwiftUI
    // key handling doesn't get a look in (same approach as the split focus monitor)
    private func startEscMonitor() {
        stopEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                tabManager.closePeek()
                return nil  // consume it
            }
            return event
        }
    }

    private func stopEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }
}

/// a single liquid-glass round button in the Peek control stack
private struct PeekControlButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.8))
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(help)
    }
}
