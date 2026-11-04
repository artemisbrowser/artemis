// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

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

/// a floating preview of a ⇧-clicked link over the current page. the preview
/// (`TabManager.peekTab`) is born in the current space's container, so logins carry
struct PeekView: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage(PeekControlsCorner.storageKey) private var cornerRaw = PeekControlsCorner.topTrailing.rawValue
    let tab: BrowserTab
    @State private var escMonitor: Any?

    private var corner: PeekControlsCorner { PeekControlsCorner(rawValue: cornerRaw) ?? .topTrailing }

    var body: some View {
        ZStack {
            // a click anywhere off the panel dismisses
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { tabManager.closePeek() }

            panel
                .frame(maxWidth: 1120, maxHeight: 820)
                .padding(56)
        }
        .transition(Motion.grow(from: 0.97))
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

    /// pushes the control stack outside the panel; the overlay alignment anchors it vertically
    private var controlsOffset: CGSize {
        let dx: CGFloat = 42  // button (30) + gap, clears the panel edge
        switch corner {
        case .topTrailing, .bottomTrailing: return CGSize(width: dx, height: 0)
        case .topLeading, .bottomLeading: return CGSize(width: -dx, height: 0)
        }
    }

    // a local key monitor: SwiftUI key handling never sees keys over a WKWebView
    private func startEscMonitor() {
        stopEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                tabManager.closePeek()
                return nil
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
