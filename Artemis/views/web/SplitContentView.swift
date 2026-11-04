// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the content area when a split is shown: its panes tiled from the split's tree,
/// with resizable dividers between. clicking a pane focuses it and still reaches the page
struct SplitContentView: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(RearrangeDragState.self) private var rearrange
    @AppStorage("dimInactivePanes") private var dimInactive = false
    let group: SplitGroup

    /// each pane's window-space frame, for hit-testing clicks to focus
    @State private var paneFrames: [BrowserTab.ID: CGRect] = [:]
    @State private var focusMonitor: Any?
    /// the pane whose link button was tapped and is now choosing a target pane
    @State private var linkingSource: BrowserTab.ID?

    private var accent: Color { tabManager.currentSpace.appearance.accent }
    private var cardBase: Color { tabManager.currentSpace.appearance.cardBase }

    var body: some View {
        // panes sit in one flat layer keyed by tab id and never re-parent:
        // re-parenting tears a WKWebView from its host and blanks it
        GeometryReader { geo in
            let container = CGRect(origin: .zero, size: geo.size)
            let root = rearrange.previewRoot(for: group) ?? group.layoutRoot
            let frames = root.paneFrames(in: container, gap: splitPaneGap)
            let dividers = root.dividers(in: container, gap: splitPaneGap)

            ZStack(alignment: .topLeading) {
                ForEach(frames.filter { $0.tab != RearrangeDragState.placeholderTab }) { pane in
                    if let t = tabManager.currentSpace.tabs.first(where: { $0.id == pane.tab }) {
                        SplitPane(
                            tab: t, group: group, isFocused: t.id == tabManager.selectedTabID,
                            dimInactive: dimInactive, accent: accent, cardBase: cardBase,
                            linkingSource: linkingSource,
                            onFrameChange: { paneFrames[t.id] = $0 },
                            onLinkButton: { linkButtonTapped(t.id) },
                            onChooseTarget: { chooseLinkTarget(t.id) },
                            onCancelLink: { linkingSource = nil }
                        )
                        .frame(width: pane.rect.width, height: pane.rect.height)
                        .position(x: pane.rect.midX, y: pane.rect.midY)
                    }
                }

                if let ph = frames.first(where: { $0.tab == RearrangeDragState.placeholderTab }) {
                    PlaceholderPane(tab: draggedTab, accent: accent)
                        .frame(width: ph.rect.width, height: ph.rect.height)
                        .position(x: ph.rect.midX, y: ph.rect.midY)
                }

                ForEach(dividers) { d in
                    SplitDividerView(info: d, group: group)
                        .frame(width: d.rect.width, height: d.rect.height)
                        .position(x: d.rect.midX, y: d.rect.midY)
                }
            }
            // a divider drag changes ratios, not these, so it stays instant
            .animation(Motion.pop, value: rearrange.isDragging)
            .animation(Motion.pop, value: rearrange.target)
        }
        .onAppear { startFocusMonitor() }
        .onDisappear { stopFocusMonitor() }
    }

    private var draggedTab: BrowserTab? {
        guard let id = rearrange.draggedID else { return nil }
        return tabManager.currentSpace.tabs.first { $0.id == id }
    }

    // MARK: - Link target picker

    /// the link chip on a pane was tapped: unlink if it's already the linked
    /// source, cancel if it's mid-pick, otherwise start choosing a target
    private func linkButtonTapped(_ id: BrowserTab.ID) {
        if group.isLinked, group.linkSourceID == id {
            tabManager.clearSplitLink(group)
            linkingSource = nil
        } else if linkingSource == id {
            linkingSource = nil
        } else {
            linkingSource = id
        }
    }

    /// a candidate pane was chosen as the link target
    private func chooseLinkTarget(_ id: BrowserTab.ID) {
        if let src = linkingSource { tabManager.setSplitLink(group, source: src, target: id) }
        linkingSource = nil
    }

    // MARK: - Click-to-focus

    /// focuses whichever pane a left-mouse-down lands in and passes the event on;
    /// SwiftUI taps don't reach reliably over a WKWebView
    private func startFocusMonitor() {
        stopFocusMonitor()
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let content = event.window?.contentView else { return event }
            // NSEvent is bottom-left origin; SwiftUI .global is top-left
            let point = CGPoint(
                x: event.locationInWindow.x,
                y: content.bounds.height - event.locationInWindow.y)
            if let hit = paneFrames.first(where: { $0.value.contains(point) })?.key,
                tabManager.selectedTabID != hit
            {
                tabManager.selectedTabID = hit
                tabManager.isCommandBarVisible = false
            }
            return event
        }
    }

    private func stopFocusMonitor() {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
        focusMonitor = nil
    }
}

/// the gap between panes, which is also a divider's hit area
let splitPaneGap: CGFloat = 10

/// one resizable divider in a gap between panes; dragging adjusts the node and
/// boundary it was computed for
private struct SplitDividerView: View {
    @Environment(TabManager.self) private var tabManager
    let info: SplitDividerInfo
    let group: SplitGroup

    var body: some View {
        let isCols = info.axis == .columns
        ZStack {
            Capsule()
                .fill(tabManager.currentSpace.appearance.chromeInk.opacity(0.22))
                .frame(width: isCols ? 3 : 28, height: isCols ? 28 : 3)
                .accessibilityHidden(true)
            SplitDivider(
                orientation: info.axis,
                onDrag: { delta in
                    group.resize(
                        path: info.path, boundary: info.boundary,
                        by: delta / max(info.axisLength, 1))
                },
                onCommit: { tabManager.commitSplitLayout(group) })
        }
    }
}

/// one pane of a split: a tab's web view under a focus ring, with hover controls
/// in its top-trailing corner
private struct SplitPane: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(RearrangeDragState.self) private var rearrange
    let tab: BrowserTab
    let group: SplitGroup
    let isFocused: Bool
    let dimInactive: Bool
    let accent: Color
    let cardBase: Color
    /// the pane currently choosing a link target
    let linkingSource: BrowserTab.ID?
    let onFrameChange: (CGRect) -> Void
    let onLinkButton: () -> Void
    let onChooseTarget: () -> Void
    let onCancelLink: () -> Void

    @State private var hovering = false

    private var ringWidth: CGFloat { isFocused ? 2 : 1 }
    private var isLinkSource: Bool { group.isLinked && group.linkSourceID == tab.id }
    private var isLinkTarget: Bool { group.isLinked && group.linkTargetID == tab.id }
    /// this pane is the source of a pick underway
    private var isPickingHere: Bool { linkingSource == tab.id }
    /// a pick is underway and this pane is an eligible target
    private var isCandidate: Bool { linkingSource != nil && linkingSource != tab.id }

    var body: some View {
        ZStack {
            cardBase
            WebViewContainer(tab: tab)
                // a container rebuild (new web view, same tab) re-mounts the host
                .id("\(tab.id)#\(tab.webViewGeneration)")
                .opacity(tab.loadError == nil ? 1 : 0)
            if tab.loadError != nil {
                ErrorPage(tab: tab)
            }
        }
        .pageDialog(for: tab)
        .translateSelection(for: tab)
        .overlay(alignment: .top) {
            PageLoadBar(tab: tab, accent: PageLoadBar.accent(for: tabManager.currentSpace.appearance))
                .padding(.top, ringWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? accent.opacity(0.9) : .white.opacity(0.08), lineWidth: ringWidth)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { linkBadge }
        .overlay(alignment: .topTrailing) { controls }
        .overlay { linkPicker }
        .opacity(dimInactive && !isFocused ? 0.5 : 1)
        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split pane, \(tab.displayTitle)")
        .accessibilityActions {
            Button(isLinkSource ? "Unlink This Pane" : "Open This Pane's Links in Another Pane", action: onLinkButton)
            Button("Close This Pane") { tabManager.removeFromSplit(tab) }
        }
        // for the click-to-focus monitor only; the drop hit-test uses the tree's frames
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { onFrameChange($0) }
        .animation(Motion.fade, value: isFocused)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.pop, value: linkingSource)
    }

    /// during a link pick, every other pane offers itself and the source offers a cancel
    @ViewBuilder
    private var linkPicker: some View {
        if isCandidate {
            Button(action: onChooseTarget) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.2))
                    Label("Link here", systemImage: "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(accent, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if isPickingHere {
            Button(action: onCancelLink) {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 6) {
                        Image(systemName: "link.badge.plus").font(.system(size: 22, weight: .semibold))
                        Text("Pick a pane to link to").font(.system(size: 13, weight: .semibold))
                        Text("Click here to cancel").font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }

    /// the top-trailing hover region; hover is reliable here because the cursor is
    /// over this SwiftUI overlay, not the web view
    private var controls: some View {
        HStack(spacing: 6) {
            if hovering {
                rearrangeHandle
                paneButton(
                    isLinkSource ? "link" : "link.badge.plus",
                    tint: isLinkSource ? accent : nil,
                    help: isLinkSource ? "Unlink this pane"
                        : "Open this pane's links in another pane…"
                ) {
                    onLinkButton()
                }
                paneButton("xmark", help: "Close this pane") {
                    tabManager.removeFromSplit(tab)
                }
            }
        }
        .padding(7)
        .frame(width: 118, height: 38, alignment: .topTrailing)
        // hovered below its top band, which stays the page's, so at rim 0 the window drags from there
        .background(alignment: .bottom) {
            Color.clear.frame(height: 38 - PageDragBand.height).contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
    }

    /// picks the pane up to re-tile the split. it only starts the drag: MainView's
    /// monitor tracks and commits it, since this handle unmounts once the pane leaves
    private var rearrangeHandle: some View {
        chip("arrow.up.and.down.and.arrow.left.and.right", tint: nil)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(splitRearrangeSpace))
                    .onChanged { value in
                        if rearrange.draggedID == nil {
                            rearrange.begin(group, pane: tab.id, at: value.location)
                        } else {
                            rearrange.cursor = value.location
                        }
                    })
            .tooltip("Drag to rearrange the split")
            .transition(Motion.grow(from: 0.85))
    }

    private func paneButton(
        _ symbol: String, tint: Color? = nil, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chip(symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .tooltip(help)
        .transition(Motion.grow(from: 0.85))
    }

    /// the shared chip look for a pane control (a button or the drag handle)
    private func chip(_ symbol: String, tint: Color?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint ?? .white.opacity(0.85))
            .frame(width: 24, height: 24)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    @ViewBuilder
    private var linkBadge: some View {
        if isLinkSource || isLinkTarget {
            Image(systemName: isLinkSource ? "arrow.right.circle.fill" : "arrow.down.right.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .padding(8)
                .tooltip(isLinkSource ? "Links here open in the linked pane" : "Receives links from the linked pane")
        }
    }
}

/// what a drag in the content shows besides the in-layout placeholder: the drop
/// guides, the single-page region highlight and the floating ghost. drawn in
/// `splitRearrangeSpace`, never hit-testing
struct RearrangeOverlay: View {
    @Environment(RearrangeDragState.self) private var rearrange
    @Environment(TabManager.self) private var tabManager
    @AppStorage("showSplitDropGuides") private var showDropGuides = true
    let accent: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showDropGuides, let guide = rearrange.dropGuide() {
                dropGuideCanvas(guide)
                    .frame(width: guide.size.width, height: guide.size.height)
                    .transition(.opacity)
            }
            if let region = rearrange.regionRect {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                accent.opacity(0.6),
                                style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                    .frame(width: max(region.width - 6, 0), height: max(region.height - 6, 0))
                    .position(x: region.midX, y: region.midY)
            }
            if rearrange.showsFloatingGhost, let tab = draggedTab {
                ghost(tab).position(rearrange.cursor)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.fade, value: rearrange.regionRect)
        .animation(Motion.fade, value: rearrange.isDragging)
    }

    private var draggedTab: BrowserTab? {
        guard let id = rearrange.draggedID else { return nil }
        return tabManager.currentSpace.tabs.first { $0.id == id }
    }

    /// the lines between zones that drop differently
    private func dropGuideCanvas(_ guide: RearrangeDragState.DropGuide) -> some View {
        Canvas { ctx, _ in
            ctx.stroke(
                guide.lines, with: .color(accent.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    /// the predicted region scaled down, aspect preserved
    private var ghostSize: CGSize {
        guard let r = rearrange.regionRect, r.width > 0, r.height > 0 else {
            return CGSize(width: 132, height: 96)
        }
        let s = min(170 / max(r.width, r.height), 0.5)
        return CGSize(width: max(r.width * s, 64), height: max(r.height * s, 54))
    }

    private func ghost(_ tab: BrowserTab) -> some View {
        let size = ghostSize
        return VStack(spacing: 7) {
            favicon(tab)
            Text(tab.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .frame(width: size.width, height: size.height)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .animation(Motion.pop, value: size)
    }

    @ViewBuilder
    private func favicon(_ tab: BrowserTab) -> some View {
        if let icon = tab.favicon {
            Image(nsImage: icon)
                .resizable().scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
        }
    }
}

/// the leaf in the preview tree where a dragged pane would land
private struct PlaceholderPane: View {
    let tab: BrowserTab?
    let accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
            .overlay {
                if let tab {
                    VStack(spacing: 7) {
                        if let icon = tab.favicon {
                            Image(nsImage: icon)
                                .resizable().scaledToFit()
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        } else {
                            Image(systemName: "globe")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Text(tab.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 12)
                    }
                }
            }
    }
}

/// AppKit-backed resize strip between two panes; reports the drag as a running
/// delta in points along the split axis
struct SplitDivider: NSViewRepresentable {
    let orientation: SplitOrientation
    let onDrag: (CGFloat) -> Void
    let onCommit: () -> Void

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: Handle, context: Context) { configure(nsView) }

    private func configure(_ view: Handle) {
        view.orientation = orientation
        view.onDrag = onDrag
        view.onCommit = onCommit
    }

    final class Handle: NSView {
        var orientation: SplitOrientation = .columns
        var onDrag: ((CGFloat) -> Void)?
        var onCommit: (() -> Void)?
        private var last: CGFloat = 0

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: orientation == .columns ? .resizeLeftRight : .resizeUpDown)
        }

        private func axisValue(_ event: NSEvent) -> CGFloat {
            orientation == .columns ? event.locationInWindow.x : event.locationInWindow.y
        }

        override func mouseDown(with event: NSEvent) {
            last = axisValue(event)
        }

        override func mouseDragged(with event: NSEvent) {
            let cur = axisValue(event)
            var delta = cur - last
            // window y is bottom-up: dragging down (shrinking the top pane) is a
            // negative dy, but should grow the upper pane `i`, so invert for rows
            if orientation == .rows { delta = -delta }
            onDrag?(delta)
            last = cur
        }

        override func mouseUp(with event: NSEvent) {
            onCommit?()
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { "Resize panes" }
        override func accessibilityOrientation() -> NSAccessibilityOrientation {
            orientation == .columns ? .vertical : .horizontal
        }
        /// VoiceOver's increment grows the first pane by 20pt
        override func accessibilityPerformIncrement() -> Bool { nudge(20) }
        override func accessibilityPerformDecrement() -> Bool { nudge(-20) }

        private func nudge(_ delta: CGFloat) -> Bool {
            onDrag?(delta)
            onCommit?()
            return true
        }
    }
}
