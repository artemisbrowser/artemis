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
                // shapes sit in the box mouth; on hover they rise, the
                // triangle/circle splay to an even row, the star spins.
                // box is drawn last so the shape bases tuck into it.
                // star — big, left, tilted left, spins on hover; its bottom is
                // clipped to the triangle's bottom line (mask after rotation
                // keeps the cut horizontal). big rect so rotation never clips top
                // star spins ~200° and rises on hover. all three rise by the
                // same amount so the star's cut stays on the triangle's bottom
                Star(cornerRadius: 0.32)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(isHovering ? -208 : -8))
                    .mask(
                        Rectangle()
                            .frame(width: 40, height: 40)
                            .offset(y: -19)
                    )
                    .offset(x: -2.5, y: isHovering ? -3.5 : -2.5)

                // triangle — right; rises and rotates a little clockwise on hover
                Image(systemName: "triangle.fill")
                    .font(.system(size: 3.3))
                    .rotationEffect(.degrees(isHovering ? -5 : -20))
                    .offset(x: 4.5, y: isHovering ? -5 : -4)

                // circle — middle dot; rises and drifts right on hover
                Circle()
                    .frame(width: 2, height: 2)
                    .offset(x: isHovering ? 3.5 : 2, y: isHovering ? -8 : -7)

                // storage box: rounded bin with a horizontal slot on the front
                StorageBox()
                    .offset(y: 4)
            }
            .modifier(ChromeButtonFace(isHovering: isHovering, standalone: true))
            .overlay { DownloadRing() }
        }
        .buttonStyle(.plain)
        .background(DownloadLanding())
        .onHover { hovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) {
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
    @State private var files: [DownloadFile] = []

    var body: some View {
        Group {
            // no downloads → no slab at all
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        PeekRow(file: file)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chromeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            }
        }
        .task {
            files = Array(await DownloadFile.loadAllOffMain().prefix(4))
        }
    }
}

private struct PeekRow: View {
    @Environment(\.chromeInk) private var ink
    let file: DownloadFile
    @State private var isHovering = false
    /// NSWorkspace's icon is a synchronous fetch, so it is read once per row
    @State private var icon: NSImage?

    private var relativeTime: String {
        RelativeDateTimeFormatter().localizedString(for: file.date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() } else { Color.clear }
            }
            .frame(width: 32, height: 32)
            .onAppear { if icon == nil { icon = file.icon } }

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
        .background(RowHighlight(opacity: isHovering ? 0.09 : 0))
        .animation(Motion.hover, value: isHovering)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            NSWorkspace.shared.open(file.url)
        }
        .onHover { isHovering = $0 }
    }
}
