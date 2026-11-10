// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the empty space's app-icon mark, swelling while held. a drag from near its middle moves it and a let-go springs it
/// home; from anywhere else it turns with the pointer, and a flick coasts on to an upright
struct HeldMark: View {
    let side: CGFloat
    @AppStorage(AppIconChoice.storageKey) private var icon = AppIconChoice.bundled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = MarkSpin()
    @State private var isMoving = false

    var body: some View {
        TimelineView(.animation(paused: !isMoving)) { context in
            MarkFace(pose: spin.pose(at: context.date.timeIntervalSinceReferenceDate), side: side, icon: icon, dark: scheme == .dark)
                .sensoryFeedback(.alignment, trigger: spin.clicks)
                .sensoryFeedback(.levelChange, trigger: spin.ticks)
                .onChange(of: context.date) { if spin.isAtRest { isMoving = false } }
        }
        .frame(width: side, height: side)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let point = CGPoint(x: drag.location.x - side / 2, y: drag.location.y - side / 2)
                    let time = drag.time.timeIntervalSinceReferenceDate
                    if !spin.isHeld {
                        spin.grab(point, side: side, at: time)
                        isMoving = true
                    }
                    spin.move(to: point, at: time)
                }
                .onEnded { spin.release(at: $0.time.timeIntervalSinceReferenceDate) }
        )
        .onChange(of: reduceMotion, initial: true) { spin.reduceMotion = reduceMotion }
        .accessibilityElement()
        .accessibilityLabel("No open tabs")
        .accessibilityAdjustableAction { direction in
            spin.flick(direction == .decrement ? -1 : 1)
            isMoving = true
        }
    }
}
