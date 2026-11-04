// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

// Window content is 660x400pt; app icon centred at (180,190), Applications at (480,190).
let size = NSSize(width: 660, height: 400)

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // flipped so y runs down, like Finder's icon positions
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    let bg = NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.09, alpha: 1)])!
    bg.draw(fromCenter: NSPoint(x: 330, y: 150), radius: 0, toCenter: NSPoint(x: 330, y: 200), radius: 460, options: [])

    // soft wells behind the two icons
    for x in [180.0, 480.0] {
        let well = NSGradient(colors: [NSColor(white: 1, alpha: 0.07), NSColor(white: 1, alpha: 0)])!
        well.draw(fromCenter: NSPoint(x: x, y: 185), radius: 0, toCenter: NSPoint(x: x, y: 185), radius: 110, options: [])
    }

    // arrow: a gentle arc from the app to Applications
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 268, y: 186))
    arrow.curve(to: NSPoint(x: 384, y: 186), controlPoint1: NSPoint(x: 300, y: 160), controlPoint2: NSPoint(x: 352, y: 160))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    NSColor(white: 1, alpha: 0.55).setStroke()
    arrow.stroke()
    // arms at ±35° either side of the curve's direction where it ends
    let tip = NSPoint(x: 384, y: 186)
    let back = atan2(160.0 - 186, 352.0 - 384)
    let head = NSBezierPath()
    head.move(to: NSPoint(x: tip.x + 14 * cos(back + 0.6), y: tip.y + 14 * sin(back + 0.6)))
    head.line(to: tip)
    head.line(to: NSPoint(x: tip.x + 14 * cos(back - 0.6), y: tip.y + 14 * sin(back - 0.6)))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let caption = NSAttributedString(
        string: "Drag Artemis into Applications",
        attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ])
    // text draws upright in an unflipped context
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    let w = caption.size().width
    caption.draw(at: NSPoint(x: (size.width - w) / 2, y: size.height - 340))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
render(scale: 1, to: dir + "/bg.png")
render(scale: 2, to: dir + "/bg@2x.png")
