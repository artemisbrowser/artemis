// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// library button: a storage tray with little shapes peeking out of its
/// mouth. hovering lifts the shapes higher and twirls the star.
struct LibraryButton: View {
    let action: () -> Void
    var onHoverChanged: ((Bool) -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // the star's bottom is cut level with the triangle's base by an oversized mask
                // applied after rotation; every shape rises by the same 1pt on hover so the cut
                // stays put. the box is drawn last, over their bases
                Star(cornerRadius: 0.32)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(isHovering ? -208 : -8))
                    .mask(
                        Rectangle()
                            .frame(width: 40, height: 40)
                            .offset(y: -19)
                    )
                    .offset(x: -2.5, y: isHovering ? -3.5 : -2.5)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 3.3))
                    .rotationEffect(.degrees(isHovering ? -5 : -20))
                    .offset(x: 4.5, y: isHovering ? -5 : -4)

                Circle()
                    .frame(width: 2, height: 2)
                    .offset(x: isHovering ? 3.5 : 2, y: isHovering ? -8 : -7)

                StorageBox()
                    .offset(y: 4)
            }
            .modifier(ChromeButtonFace(isHovering: isHovering, standalone: true))
            .overlay { DownloadRing() }
        }
        .buttonStyle(.plain)
        .background(DownloadLanding())
        .onHover { hovering in
            withAnimation(Motion.pop) {
                isHovering = hovering
            }
            onHoverChanged?(hovering)
        }
        .tooltip("Library")
    }
}

/// a 5-point star with rounded tips. `innerRatio` sets how pointy the star
/// is (lower = pointier); `cornerRadius` (fraction of the outer radius)
/// softens every vertex with a curve, so the points read round, not blunt
private struct Star: Shape {
    var points = 5
    var innerRatio: CGFloat = 0.42
    var cornerRadius: CGFloat = 0.26

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let steps = points * 2

        let verts: [CGPoint] = (0..<steps).map { i in
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = (CGFloat(i) / CGFloat(steps)) * 2 * .pi - .pi / 2
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }

        func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.0001)
            return CGPoint(x: dx / len, y: dy / len)
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

        let r = outer * cornerRadius
        var path = Path()
        for i in 0..<steps {
            let curr = verts[i]
            let prev = verts[(i - 1 + steps) % steps]
            let next = verts[(i + 1) % steps]
            let toPrev = unit(from: curr, to: prev)
            let toNext = unit(from: curr, to: next)
            let rIn = min(r, dist(curr, prev) / 2)
            let rOut = min(r, dist(curr, next) / 2)
            let entry = CGPoint(x: curr.x + toPrev.x * rIn, y: curr.y + toPrev.y * rIn)
            let exit = CGPoint(x: curr.x + toNext.x * rOut, y: curr.y + toNext.y * rOut)
            if i == 0 { path.move(to: entry) } else { path.addLine(to: entry) }
            path.addQuadCurve(to: exit, control: curr)
        }
        path.closeSubpath()
        return path
    }
}

/// rounded storage bin with a horizontal slot punched in the front face
private struct StorageBox: View {
    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 1.5,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 3,
                topTrailingRadius: 1.5,
                style: .continuous
            )
            .frame(width: 12, height: 9)
            // opaque source + destinationOut = a transparent slot
            Capsule()
                .fill(.black)
                .frame(width: 4, height: 2)
                .offset(y: -2.5)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

/// floating peek of the most recent downloads, shown while hovering the inbox
struct RecentDownloadsPeek: View {
    /// the panel rounds like the bottom bar's glass buttons under it
    static let radius = SidebarMetrics.glassSide / 2
    static let inset: CGFloat = 6
    let files: [DownloadFile]

    var body: some View {
        Group {
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        PeekRow(file: file)
                    }
                }
                .padding(Self.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chromeGlass(in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            }
        }
    }
}

private struct PeekRow: View {
    /// concentric with the panel's corners
    static let radius = RecentDownloadsPeek.radius - RecentDownloadsPeek.inset
    @Environment(\.chromeInk) private var ink
    let file: DownloadFile
    @State private var isHovering = false

    private var relativeTime: String {
        RelativeDateTimeFormatter().localizedString(for: file.date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: file.icon).resizable().scaledToFit()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name.replacingOccurrences(of: " ", with: "\u{00A0}"))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(ink)
                Text(relativeTime)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RowHighlight(opacity: isHovering ? 0.09 : 0, radius: Self.radius))
        .animation(Motion.hover, value: isHovering)
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { NSWorkspace.shared.open(file.url) }
        .onTapGesture {
            NSWorkspace.shared.open(file.url)
        }
        .onHover { isHovering = $0 }
        .onDrag { file.dragItem }
    }
}
