// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the sidebar's Now Playing bars: one per tab with media playing (or paused
/// mid-track) that no window is showing. clicking one brings that tab forward
struct NowPlayingCard: View {
    static let enabledKey = "showNowPlayingInSidebar"
    private static let maxBars = 3

    @Environment(TabManager.self) private var tabManager
    @AppStorage(Self.enabledKey) private var isEnabled = true

    /// tabs with media in this window's unlocked spaces and the favourites that
    /// no window or mini player is showing, top-ranked first
    private var sources: [(tab: BrowserTab, media: PageMedia)] {
        guard isEnabled else { return [] }
        let managers = BrowserWindows.shared.allManagers
        // `spaces` is every main window's; an incognito or Scout window reaches only its own
        let reach = tabManager.kind == .main ? tabManager.spaces : [tabManager.currentSpace]
        let open = reach.filter { !SpaceLock.shared.isLocked($0) }
        return (open.flatMap(\.tabs) + tabManager.essentials)
            .compactMap { tab in
                guard let media = tab.media, !tab.isMiniPlayerActive,
                    !managers.contains(where: { $0.isShowing(tab) })
                else { return nil }
                return (tab, media)
            }
            .sorted { $0.media.rank > $1.media.rank }
            .prefix(Self.maxBars)
            .map { $0 }
    }

    var body: some View {
        let sources = sources
        VStack(spacing: 6) {
            ForEach(sources, id: \.tab.id) { source in
                Bar(tab: source.tab, media: source.media, space: tabManager.space(of: source.tab))
                    .transition(Motion.grow(from: 0.96, anchor: .bottom))
            }
        }
        .padding(.bottom, sources.isEmpty ? 0 : 8)
        .animation(Motion.pop, value: sources.map(\.tab.id))
    }
}

private struct Bar: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.chromeInk) private var ink
    private let metrics = SidebarMetrics.standard
    let tab: BrowserTab
    let media: PageMedia
    /// nil for a favourite
    let space: Space?
    @State private var isHovering = false
    @State private var width: CGFloat = .infinity

    /// below this the seek buttons drop out so the title keeps some room
    private static let seekWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 0) {
            Button {
                tabManager.focus(tab)
            } label: {
                HStack(spacing: 8) {
                    favicon
                    Text(media.title.isEmpty ? tab.displayTitle : media.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, metrics.rowLeadingPadding)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(media.title.isEmpty ? tab.displayTitle : media.title)
            .accessibilityValue(media.isPlaying ? "playing" : "paused")
            .tooltip("Go to Tab")

            SpaceGlyph(icon: space?.icon ?? "star.fill", size: 10)
                .foregroundStyle(ink.opacity(0.5))
                .frame(width: 18)
                .tooltip(space?.name ?? "Favourite")

            if width >= Self.seekWidth {
                HoverIconButton(media.hasTracks ? "backward.fill" : "gobackward.10", size: 11, boxSize: 24) {
                    tab.sendMediaCommand(.back)
                }
                .tooltip(media.hasTracks ? "Previous Track" : "Back 10 Seconds")
            }
            HoverIconButton(media.isPlaying ? "pause.fill" : "play.fill", size: 13, boxSize: 24) {
                tab.sendMediaCommand(.toggle)
            }
            .tooltip(media.isPlaying ? "Pause" : "Play")
            if width >= Self.seekWidth {
                HoverIconButton(media.hasTracks ? "forward.fill" : "goforward.10", size: 11, boxSize: 24) {
                    tab.sendMediaCommand(.forward)
                }
                .tooltip(media.hasTracks ? "Next Track" : "Forward 10 Seconds")
            }
            HoverIconButton(tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 11, boxSize: 24) {
                tab.toggleMuted()
            }
            .tooltip(tab.isMuted ? "Unmute Tab" : "Mute Tab")
        }
        .padding(.trailing, metrics.rowTrailingPadding)
        .frame(height: metrics.rowHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .chromeGlass(in: Capsule(), interactive: true, lit: isHovering)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
    }

    @ViewBuilder private var favicon: some View {
        if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable().scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: 16, height: 16)
        }
    }
}
