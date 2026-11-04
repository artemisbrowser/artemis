// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// a page's load progress along its own top edge. lives inside the page's clip,
/// so it takes the card's or pane's corners; reads only its tab, so progress
/// ticks re-run this view alone
struct PageLoadBar: View {
    let tab: BrowserTab
    let accent: Color

    @State private var fill: Double = 0
    @State private var shown = false
    @State private var reveal: Task<Void, Never>?

    /// a glass space's accent is white, which vanishes over a white page
    static func accent(for appearance: SpaceAppearance) -> Color {
        appearance.fill == .glass ? .accentColor : appearance.accent
    }

    /// a load quicker than this never shows a bar
    static let revealDelay: Duration = .milliseconds(150)

    /// where the bar is heading: nil while idle. finishing runs it to the end;
    /// a stopped load has no tail, so it fades where it stands
    static func target(isLoading: Bool, progress: Double, isFinishing: Bool) -> Double? {
        if isLoading { return max(progress, 0.1) }
        return isFinishing ? 1 : nil
    }

    private var target: Double? {
        Self.target(isLoading: tab.isLoading, progress: tab.progress, isFinishing: tab.isFinishingLoad)
    }

    private let height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            bar
                // the leading cap sits past the edge, so the fill starts square
                .frame(width: geo.size.width * fill + height, height: height)
                .offset(x: -height)
                .opacity(shown ? 1 : 0)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .onChange(of: target, initial: true) { _, new in update(to: new) }
        .onDisappear { reveal?.cancel() }
    }

    /// the accent is a plain fill inside the glass: glass alone loses its tint
    /// in a window that isn't key
    private var bar: some View {
        Capsule().fill(accent).padding(2).glassEffect(.regular, in: .capsule)
    }

    private func update(to new: Double?) {
        guard let new else {
            reveal?.cancel()
            reveal = nil
            withAnimation(Motion.fade) { shown = false } completion: { if target == nil { fill = 0 } }
            return
        }
        if new < fill {
            // a reload over the last load's tail starts again from the left
            fill = new
        } else {
            withAnimation(.easeOut(duration: 0.25)) { fill = new }
        }
        if !shown, reveal == nil {
            reveal = Task {
                try? await Task.sleep(for: Self.revealDelay)
                // a task not cancelled is still the current handle
                guard !Task.isCancelled else { return }
                reveal = nil
                guard tab.isLoading else { return }
                withAnimation(Motion.fade) { shown = true }
            }
        }
    }
}
