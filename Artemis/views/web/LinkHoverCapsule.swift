// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the status-style capsule that floats at the bottom of the content while the
/// cursor is over a link, showing where it points. holding a link modifier flips
/// it to where that click would open ("Open … in Peek", "… in Split View", …)
struct LinkHoverCapsule: View {
    @Environment(TabManager.self) private var tabManager
    @State private var click: LinkClick?
    @State private var flagsMonitor: Any?

    var body: some View {
        Group {
            if let url = tabManager.hoveredLinkURL {
                capsule(for: url)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: tabManager.hoveredLinkURL)
        .animation(.easeOut(duration: 0.12), value: click)
        .onAppear { startFlagsMonitor() }
        .onDisappear { stopFlagsMonitor() }
    }

    private func capsule(for url: URL) -> some View {
        label(for: url)
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            // pre-trimmed label, so the capsule hugs its text and never overflows
            .fixedSize()
    }

    /// a modified click's site is drawn at full strength, so the place it opens stands out
    private func label(for url: URL) -> Text {
        let isPrivate = tabManager.displayedContentTab?.isPrivate == true
        let place: String
        switch click.flatMap({ tabManager.destination(of: $0, isPrivate: isPrivate) }) {
        case .peek: place = "in Peek"
        case .backgroundTab: place = "in a Background Tab"
        case .foregroundTab: place = "in a New Tab"
        case .split: place = "in Split View"
        case .scout: place = "in Scout"
        case nil: return Text(verbatim: trimmed(url))
        }
        let host = Text(verbatim: url.host() ?? trimmed(url)).foregroundStyle(.primary)
        return Text("Open \(host) \(place)")
    }

    /// a tidy, length-capped form of the url: drop the scheme, ellipsise the middle
    private func trimmed(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        let max = 90
        guard text.count > max else { return text }
        let head = text.prefix(max / 2 - 1)
        let tail = text.suffix(max / 2 - 1)
        return "\(head)…\(tail)"
    }

    /// watch the modifiers directly — SwiftUI doesn't see them change over a WKWebView
    private func startFlagsMonitor() {
        stopFlagsMonitor()
        click = LinkClick.route(NSEvent.modifierFlags)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            click = LinkClick.route(event.modifierFlags)
            return event
        }
    }

    private func stopFlagsMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }
}
