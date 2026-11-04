// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the command bar editing the page's address: one glass shape that springs out
/// of the url pill into the bar, and back into the pill when the bar closes
struct AddressBar: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.colorScheme) private var colorScheme
    /// the pill's frame in this view's space; .zero when the pill is off screen
    let origin: CGRect
    let size: CGSize
    @State private var expanded = false

    private enum Metrics {
        static let fieldHeight = CommandBar.addressFieldHeight
        static let radius: CGFloat = 22
        static let width: CGFloat = 680
        static let outset: CGFloat = 6
    }

    /// the shape it grows from: the pill, or a capsule where the bar will sit
    private var pill: CGRect {
        guard origin.isEmpty else { return origin }
        return CGRect(x: (size.width - 240) / 2, y: size.height * 0.2 + 4, width: 240, height: 36)
    }

    /// the bar keeps the pill's vertical centre, so the text grows in place
    private var bar: CGRect {
        let y = pill.midY - Metrics.fieldHeight / 2
        guard !origin.isEmpty else {
            let width = min(Metrics.width, size.width - 32)
            return CGRect(x: (size.width - width) / 2, y: y, width: width, height: 0)
        }
        let x = max(8, pill.minX - Metrics.outset)
        return CGRect(x: x, y: y, width: min(Metrics.width, size.width - x - 16), height: 0)
    }

    var body: some View {
        let frame = expanded ? bar : pill
        let shape = RoundedRectangle(
            cornerRadius: expanded ? Metrics.radius : pill.height / 2,
            style: .continuous)
        ZStack(alignment: .topLeading) {
            CommandBar(address: true, grown: true)
                .frame(width: bar.width)
                .opacity(expanded ? 1 : 0)
            standIn
                .scaleEffect(expanded ? CommandBar.addressFontSize / 13 : 1, anchor: .leading)
                .offset(
                    x: expanded ? CommandBar.textLeading + hostOffset : textInset,
                    y: expanded ? (Metrics.fieldHeight - pill.height) / 2 : 0)
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: frame.width, height: expanded ? nil : pill.height, alignment: .topLeading)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        // the bar's dimming layer comes up as it leaves the pill behind
        .background(
            shape.fill(colorScheme == .dark ? .black.opacity(0.62) : .white.opacity(0.7))
                .opacity(expanded ? 1 : 0))
        .shadow(color: .black.opacity(expanded ? 0.3 : 0), radius: 24, y: 10)
        .offset(x: frame.minX, y: frame.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // the first frame is the pill itself; growing has to start from it
            DispatchQueue.main.async { withAnimation(Motion.address) { expanded = true } }
        }
        .onChange(of: tabManager.isCommandBarVisible) { _, visible in
            withAnimation(Motion.address) {
                expanded = visible
            } completion: {
                guard !tabManager.isCommandBarVisible else { return }
                withAnimation(Motion.fade) { tabManager.addressBarOrigin = nil }
            }
        }
    }

    private var host: String {
        origin.isEmpty ? "" : UrlField.displayText(for: tabManager.displayedContentTab)
    }

    /// the pill's text, gliding onto the same text in the field's url
    private var standIn: some View {
        Text(host)
            .font(.system(size: 13))
            .foregroundStyle(tabManager.blendedInk.opacity(0.9))
            .lineLimit(1)
            .frame(height: pill.height)
    }

    /// matches PillChrome's leading padding
    private let textInset: CGFloat = 14

    /// the width of the url ahead of its domain, at the field's size
    private var hostOffset: CGFloat {
        guard let url = tabManager.displayedContentTab?.url?.absoluteString,
            let range = url.range(of: host)
        else { return 0 }
        return NSAttributedString(
            string: String(url[..<range.lowerBound]),
            attributes: [.font: NSFont.systemFont(ofSize: CommandBar.addressFontSize)]
        ).size().width
    }
}
