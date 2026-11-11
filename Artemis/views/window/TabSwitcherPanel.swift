// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// ⌃⇥'s cards, centred over the window while the switcher is shown
struct TabSwitcherOverlay: View {
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        let switcher = tabManager.tabSwitcher
        GeometryReader { geo in
            if switcher.isShown {
                ZStack {
                    // a click off the cards puts the switcher away
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { switcher.cancel() }
                    // values, so the panel fading out keeps the cards the switcher just let go of
                    TabSwitcherPanel(
                        cards: switcher.cards, selection: switcher.selection, frames: switcher.frames,
                        size: geo.size, pick: switcher.pick)
                        .environment(\.chromeInk, tabManager.currentSpace.appearance.chromeInk)
                }
                .transition(Motion.grow(from: 0.94))
            }
        }
        .animation(Motion.pop, value: switcher.isShown)
    }
}

private struct TabSwitcherPanel: View {
    @Environment(\.chromeInk) private var ink
    let cards: [BrowserTab]
    let selection: Int
    let frames: [BrowserTab.ID: NSImage]
    /// the window's, which the cards share
    let size: CGSize
    let pick: (Int) -> Void

    private enum Metrics {
        static let radius: CGFloat = 26
        static let inset: CGFloat = 10
        static let cardPadding: CGFloat = 6
        static let gap: CGFloat = 4
        static let margin: CGFloat = 24
        static let title: CGFloat = 16
        /// between a card's snapshot and its title
        static let titleGap: CGFloat = 6
        static let aspect: CGFloat = 0.625
    }

    var body: some View {
        let count = cards.count
        // the most columns that give the widest cards inside the window, then rows of even length
        let fitting = (1...max(1, count)).reversed().reduce(max(1, count)) { best, columns in
            cardWidth(columns: columns) > cardWidth(columns: best) ? columns : best
        }
        let rows = max(1, (count + fitting - 1) / fitting)
        let columns = max(1, (count + rows - 1) / rows)
        let width = max(1, cardWidth(columns: fitting))
        let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
        let lightInk = RGBA(ink).brightness < 0.5
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: Metrics.gap) {
                    ForEach(row * columns..<min(count, (row + 1) * columns), id: \.self) { index in
                        card(index, width: width)
                    }
                }
            }
        }
        .animation(Motion.hover, value: selection)
        .padding(Metrics.inset)
        .chromeGlass(in: shape)
        // a dimming layer under the glass, as under the command bar
        .background(shape.fill(lightInk ? .white.opacity(0.6) : .black.opacity(0.5)))
        .padding(Metrics.margin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent tabs")
    }

    /// the widest a card can draw with this many columns and the window's width and height
    private func cardWidth(columns: Int) -> CGFloat {
        let count = cards.count
        let rows = CGFloat(max(1, (count + columns - 1) / columns))
        let room = CGSize(
            width: size.width - 2 * (Metrics.margin + Metrics.inset),
            height: size.height - 2 * (Metrics.margin + Metrics.inset))
        let across = (room.width - CGFloat(columns - 1) * Metrics.gap) / CGFloat(columns) - 2 * Metrics.cardPadding
        let down = (room.height - (rows - 1) * Metrics.gap) / rows - Metrics.title - Metrics.titleGap - 2 * Metrics.cardPadding
        return min(TabSwitcher.frameWidth, across, down / Metrics.aspect)
    }

    private func card(_ index: Int, width: CGFloat) -> some View {
        let tab = cards[index]
        let isSelected = index == selection
        let inner = Metrics.radius - Metrics.inset
        return Button {
            pick(index)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.titleGap) {
                thumbnail(tab)
                    .frame(width: width, height: width * Metrics.aspect, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: inner - Metrics.cardPadding, style: .continuous))
                HStack(spacing: 6) {
                    favicon(tab, size: 14)
                    Text(tab.displayTitle)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(ink.opacity(isSelected ? 1 : 0.75))
                        .lineLimit(1)
                }
                .frame(width: width, height: Metrics.title, alignment: .leading)
            }
            .padding(Metrics.cardPadding)
            .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill(ink.opacity(isSelected ? 0.16 : 0)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func thumbnail(_ tab: BrowserTab) -> some View {
        if let image = frames[tab.id] ?? tab.stillFrame {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                ink.opacity(0.08)
                favicon(tab, size: 28)
            }
        }
    }

    @ViewBuilder
    private func favicon(_ tab: BrowserTab, size: CGFloat) -> some View {
        if let icon = tab.favicon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 4))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.75))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: size, height: size)
        }
    }
}
