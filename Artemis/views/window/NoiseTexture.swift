// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// tiling film-grain. the noise tile is generated once and cached
struct NoiseTexture: View {
    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
    }

    static let tile: NSImage = {
        let size = 128
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        for x in 0..<size {
            for y in 0..<size {
                let v = CGFloat.random(in: 0...1)
                NSColor(white: v, alpha: 1).setFill()
                NSRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        image.unlockFocus()
        return image
    }()
}
