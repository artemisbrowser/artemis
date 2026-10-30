import AppKit
import SwiftUI

/// whether a folder's header counts the tabs filed under it
enum FolderTabCount: String, CaseIterable, Identifiable {
    case count
    case none

    static let storageKey = "folderTabCount"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .count: "Count"
        case .none: "None"
        }
    }
}

/// a folder's header row in the sidebar: a disclosure chevron, the name, and the
/// number of tabs filed under it. Clicking folds it; its children draw indented
/// beneath, and folders are made from the context menus rather than by a drag.
struct FolderRow: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    /// the accent of the space this row is drawn for — the carousel shows two at
    /// once, so the manager's current space is the wrong one to ask
    @Environment(\.spaceAccent) private var accent
    let folder: TabFolder
    /// a dragged row is hovering the middle of this header — it'll file inside
    var isDropTarget = false
    var dragInProgress = false
    /// the sidebar owns the hover panel, since it draws above the list's clip
    var onHoverChanged: ((Bool) -> Void)?
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @AppStorage(FolderTabCount.storageKey) private var countStyleRaw = FolderTabCount.count.rawValue

    private var showsHover: Bool { isHovering && !dragInProgress }

    /// every tab under it, nested folders included — the count the row shows and
    /// the one "Close N Tabs" acts on
    private var tabCount: Int {
        tabManager.currentSpace.tabIDs(under: .folder(folder.id)).count
    }

    /// folded, with the tab you are on filed somewhere inside — the state the
    /// row draws that tab for
    private var holdsCurrentTab: Bool {
        guard !folder.isExpanded, let active = tabManager.selectedTabID
        else { return false }
        return tabManager.currentSpace.tabIDs(under: .folder(folder.id)).contains(active)
    }

    /// the folder's name, or the field that is renaming it — the same gesture as
    /// a tab: enter or click-away commits, escape discards
    @ViewBuilder private var name: some View {
        if isEditing {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: metrics.fontSize, weight: .medium))
                .foregroundStyle(ink)
                .focused($nameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { isEditing = false }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitRename() }
                }
                .onAppear {
                    nameFocused = true
                    // the whole name arrives selected, so typing replaces it
                    DispatchQueue.main.async {
                        (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                    }
                }
        } else {
            Text(folder.name)
                .font(.system(size: metrics.fontSize, weight: .medium))
                .foregroundStyle(ink.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func beginRename() {
        draftName = folder.name
        isEditing = true
        // the hover panel would take the keyboard the moment it appeared
        onHoverChanged?(false)
    }

    private func commitRename() {
        guard isEditing else { return }
        isEditing = false
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != folder.name else { return }
        tabManager.rename(folder, to: name)
    }

    var body: some View {
        HStack(spacing: 6) {
            FolderMark(
                open: folder.isExpanded ? 1 : 0, color: accent, marked: holdsCurrentTab)
            name
            Spacer(minLength: 4)
            if tabCount > 0, FolderTabCount(rawValue: countStyleRaw) != FolderTabCount.none {
                Text("\(tabCount)")
                    .font(.system(size: metrics.fontSize - 2, weight: .medium))
                    .foregroundStyle(ink.opacity(0.45))
                    .monospacedDigit()
            }
        }
        .padding(.leading, metrics.rowLeadingPadding)
        .padding(.trailing, metrics.rowTrailingPadding)
        .frame(height: metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ink.opacity(isDropTarget ? 0.18 : (showsHover ? 0.09 : 0))))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.85), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folder.name)
        .accessibilityValue("\(tabCount) tabs, \(folder.isExpanded ? "expanded" : "collapsed")")
        .accessibilityAddTraits(.isButton)
        .onHover {
            isHovering = $0
            onHoverChanged?($0)
        }
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(Motion.pop) { tabManager.setExpanded(folder, !folder.isExpanded) }
        }
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("Rename Folder…", systemImage: "pencil").labelStyle(.titleAndIcon)
            }
            if tabManager.currentSpace.canNestFolder(in: .folder(folder.id)) {
                Button {
                    tabManager.newFolder(in: .folder(folder.id), at: 0)
                    tabManager.setExpanded(folder, true)
                } label: {
                    Label("New Folder Inside", systemImage: "folder.badge.plus")
                        .labelStyle(.titleAndIcon)
                }
            }
            Divider()
            Button {
                tabManager.ungroup(folder)
            } label: {
                Label("Ungroup Folder", systemImage: "folder.badge.minus").labelStyle(.titleAndIcon)
            }
            Button(role: .destructive) {
                tabManager.closeFolder(folder)
            } label: {
                Label(
                    tabCount == 0 ? "Delete Folder" : "Close Folder and \(tabCount) Tabs",
                    systemImage: "xmark").labelStyle(.titleAndIcon)
            }
        }
        .animation(Motion.hover, value: showsHover)
        .animation(Motion.hover, value: isDropTarget)
    }
}

/// the folder's row, floating under the cursor while it's dragged
struct FolderDragGhost: View {
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    let folder: TabFolder
    let rowSize: CGSize

    var body: some View {
        HStack(spacing: 6) {
            FolderMark(open: 0, color: ink.opacity(0.9))
            Text(folder.name)
                .font(.system(size: metrics.fontSize, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.rowLeadingPadding)
        .frame(width: rowSize.width, height: rowSize.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ink.opacity(0.14)))
    }
}

/// the folder mark: a back panel carrying the tab, and a front panel over it.
/// opening swings the two apart about the crease they share while the camera
/// turns to the pose the mark was modelled in
struct FolderMark: View {
    var open: Double
    var color: Color
    /// the folded folder holds the tab you are on
    var marked = false

    /// the slot a tab's favicon uses, with the extra height a folder needs
    static let size = CGSize(width: 16, height: 13)

    var body: some View {
        let t = min(max(open, 0), 1)
        // each panel is filled, then rimmed on top: an opaque stroke over the
        // translucent back reads as one band rather than two
        let edge = color.mix(with: .white, by: folderEdgeLift)
        ZStack {
            FolderBack(open: t).fill(color.opacity(folderBackOpacity))
            FolderBack(open: t).stroke(edge, lineWidth: folderEdgeWidth)
            FolderFront(open: t).fill(color)
            FolderFront(open: t).stroke(edge, lineWidth: folderEdgeWidth)
            // the star rides the front face, and goes as the folder opens: an
            // open folder shows its tabs outright
            FolderStar(open: t).fill(edge).opacity(marked ? 1 - t : 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .rotationEffect(folderSpin * t)
    }
}

/// where the camera stands when the folder is fully open. closed is head-on,
/// so the mark at rest is the plain rectangle it draws today
private let folderAzimuth = Angle.degrees(-35)
private let folderElevation = Angle.degrees(-1)
private let folderDistance: CGFloat = 300
private let folderFieldOfView = Angle.degrees(80)
/// how far the front swings toward the eye, and the back away, about the crease
private let folderFold = Angle.degrees(25)
private let folderBackTilt = Angle.degrees(15)
/// the front's free edge widens by this, tapering from the crease, so it opens
/// out to the left and the right by the same amount
private let folderSpread: CGFloat = 0.05
/// sideways shift of the front, in mark widths, and how far it floats off the
/// back in points
private let folderSlide: CGFloat = -0.04
private let folderLift: CGFloat = 0.55
/// how far the finished glyph leans in the plane of the screen
private let folderSpin = Angle.degrees(-4)
/// corner radius as a fraction of the mark's width, measured on the panel
private let folderRadius: CGFloat = 0.15
/// where the back's body starts, as a fraction of the height. the tab rises
/// above it, and the crease the panels share is the edge below
private let folderBodyTop: CGFloat = 0.16
private let folderTabWidth: CGFloat = 0.55
private let folderTabTop: CGFloat = 0
private let folderTabBottom: CGFloat = 0.50
private let folderBackOpacity: Double = 0.6
/// the star's reach and waist, in mark widths, and how far its points are taken
/// off being sharp
private let folderStarSize: CGFloat = 0.21
private let folderStarWaist: CGFloat = 0.42
private let folderStarRounding: CGFloat = 0.006
/// the edge that rims both panels: the folder's own colour lifted toward white
private let folderEdgeWidth: CGFloat = 1
private let folderEdgeLift: Double = 0.45
/// segments per rounded corner
private let folderCornerSteps = 7

/// the mark's two panels as real geometry: each outline is rounded in its own
/// plane and then projected, so the near corner foreshortens sharper than the
/// far one. the back's bounds are held to their closed rect, so opening never
/// changes the size of the glyph
private struct FolderPanels {
    let back: [CGPoint]
    let front: [CGPoint]
    let star: [CGPoint]

    init(open t: Double, in rect: CGRect) {
        let w = rect.width, h = rect.height
        let rest = Self.pose(0, w, h), live = Self.pose(t, w, h)
        // the closed pose sets the scale: at rest the glyph measures w by h
        let r = Self.bounds(rest.back)
        let sx = w / max(r.width, 0.001), sy = h / max(r.height, 0.001)
        func into(_ points: [CGPoint]) -> [CGPoint] {
            points.map { CGPoint(x: ($0.x - r.minX) * sx, y: ($0.y - r.minY) * sy) }
        }
        let now = Self.bounds(into(live.body)), closed = Self.bounds(into(rest.body))
        let kx = closed.width / max(now.width, 0.001), ky = closed.height / max(now.height, 0.001)
        func hold(_ points: [CGPoint]) -> [CGPoint] {
            into(points).map {
                CGPoint(
                    x: closed.minX + ($0.x - now.minX) * kx,
                    y: closed.minY + ($0.y - now.minY) * ky)
            }
        }
        back = hold(live.back)
        front = hold(live.front)
        star = hold(live.star)
    }

    /// the outlines in screen space for one point of the opening. `body` is the
    /// back's body alone — never drawn, it is what the fit holds still
    private static func pose(_ t: Double, _ w: CGFloat, _ h: CGFloat)
        -> (back: [CGPoint], body: [CGPoint], front: [CGPoint], star: [CGPoint])
    {
        let turn = CGFloat(t)
        let az = CGFloat(folderAzimuth.radians) * turn
        let el = CGFloat(folderElevation.radians) * turn
        let ca = cos(az), sa = sin(az), ce = cos(el), se = sin(el)
        let focal = 1 / tan(CGFloat(folderFieldOfView.radians) / 2)
        func project(_ p: (x: CGFloat, y: CGFloat, z: CGFloat)) -> CGPoint {
            let xr = p.x * ca - p.z * sa, zr = p.x * sa + p.z * ca
            let yr = p.y * ce - zr * se, zc = p.y * se + zr * ce - folderDistance
            let d = max(-zc, 0.01)
            return CGPoint(x: focal * xr / d, y: -focal * yr / d)
        }
        // panel space has y up from the crease the two panels share
        let base = -h / 2, panel = h - folderBodyTop * h
        func hinged(_ angle: CGFloat, _ taper: CGFloat)
            -> (CGPoint) -> (x: CGFloat, y: CGFloat, z: CGFloat)
        {
            let c = cos(angle), s = sin(angle)
            return { p in
                let up = p.y - base
                return (p.x * (1 + 2 * taper * (up / panel)), base + up * c, up * s)
            }
        }
        /// a closed outline through `points`, every corner filleted to `radius`
        /// whichever way it turns, sampled so the projection can bend it
        func outline(_ points: [CGPoint], radius: CGFloat) -> [CGPoint] {
            let n = points.count
            var ring: [CGPoint] = []
            ring.reserveCapacity(n * (folderCornerSteps + 1))
            for i in 0 ..< n {
                let a = points[(i + n - 1) % n], b = points[i], c = points[(i + 1) % n]
                let ab = hypot(a.x - b.x, a.y - b.y), cb = hypot(c.x - b.x, c.y - b.y)
                guard ab > 0.0001, cb > 0.0001 else { continue }
                let u = CGPoint(x: (a.x - b.x) / ab, y: (a.y - b.y) / ab)
                let v = CGPoint(x: (c.x - b.x) / cb, y: (c.y - b.y) / cb)
                let turn = acos(min(max(u.x * v.x + u.y * v.y, -1), 1))
                guard turn > 0.001, turn < .pi - 0.001 else {
                    ring.append(b)
                    continue
                }
                // the fillet has to fit both edges, and the neighbours claim half
                let reach = min(radius / tan(turn / 2), ab / 2, cb / 2)
                let fillet = reach * tan(turn / 2)
                let t1 = CGPoint(x: b.x + u.x * reach, y: b.y + u.y * reach)
                let t2 = CGPoint(x: b.x + v.x * reach, y: b.y + v.y * reach)
                let bis = CGPoint(x: u.x + v.x, y: u.y + v.y)
                let bisLen = hypot(bis.x, bis.y)
                guard bisLen > 0.0001 else {
                    ring.append(b)
                    continue
                }
                let span = fillet / sin(turn / 2)
                let centre = CGPoint(
                    x: b.x + bis.x / bisLen * span, y: b.y + bis.y / bisLen * span)
                let from = atan2(t1.y - centre.y, t1.x - centre.x)
                var sweep = atan2(t2.y - centre.y, t2.x - centre.x) - from
                while sweep > .pi { sweep -= 2 * .pi }
                while sweep < -.pi { sweep += 2 * .pi }
                for step in 0 ... folderCornerSteps {
                    let angle = from + sweep * CGFloat(step) / CGFloat(folderCornerSteps)
                    ring.append(
                        CGPoint(x: centre.x + fillet * cos(angle), y: centre.y + fillet * sin(angle)))
                }
            }
            return ring
        }
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
            [CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1), CGPoint(x: x0, y: y0)]
        }

        let leaning = hinged(-CGFloat(folderBackTilt.radians) * turn, 0)
        let falling = hinged(CGFloat(folderFold.radians) * turn, folderSpread * turn)
        let slide = w * folderSlide * turn, lift = folderLift * turn
        let bodyTop = h / 2 - folderBodyTop * h
        let tabTop = h / 2 - folderTabTop * h
        let tabRight = -w / 2 + folderTabWidth * w
        // the back is one piece of card, so its outline is the folder's whole
        // silhouette — tab and body traced as a single ring, no seam to stroke
        let silhouette = [
            CGPoint(x: w / 2, y: -h / 2), CGPoint(x: w / 2, y: bodyTop),
            CGPoint(x: tabRight, y: bodyTop), CGPoint(x: tabRight, y: tabTop),
            CGPoint(x: -w / 2, y: tabTop), CGPoint(x: -w / 2, y: -h / 2),
        ]
        // five points about the middle of the front face
        let centre = CGPoint(x: 0, y: (-h / 2 + bodyTop) / 2)
        let star = (0 ..< 10).map { point -> CGPoint in
            let angle = -CGFloat.pi / 2 + .pi / 5 * CGFloat(point)
            let reach = w * (point.isMultiple(of: 2) ? folderStarSize : folderStarSize * folderStarWaist)
            return CGPoint(x: centre.x + reach * cos(angle), y: centre.y + reach * sin(angle))
        }
        func onFront(_ p: CGPoint) -> CGPoint {
            var q = falling(p)
            q.x += slide
            q.z += lift
            return project(q)
        }
        let face = rect(-w / 2, -h / 2, w / 2, bodyTop)
        return (
            back: outline(silhouette, radius: w * folderRadius).map { project(leaning($0)) },
            body: outline(face, radius: w * folderRadius).map { project(leaning($0)) },
            front: outline(face, radius: w * folderRadius).map(onFront),
            star: outline(star, radius: w * folderStarRounding).map(onFront)
        )
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max()
        else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// the panel behind, and the tab that makes the whole thing read as a folder
private struct FolderBack: Shape {
    var open: Double
    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ring = FolderPanels(open: open, in: rect).back
        guard !ring.isEmpty else { return Path() }
        var p = Path()
        p.move(to: ring[0])
        p.addLines(Array(ring.dropFirst()))
        p.closeSubpath()
        return p
    }
}

/// the star on the front face, marking the folded folder that holds the tab
/// you are on. it rides the panel, so it turns and foreshortens with it
private struct FolderStar: Shape {
    var open: Double
    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ring = FolderPanels(open: open, in: rect).star
        guard !ring.isEmpty else { return Path() }
        var p = Path()
        p.move(to: ring[0])
        p.addLines(Array(ring.dropFirst()))
        p.closeSubpath()
        return p
    }
}

/// the panel in front. closed it sits exactly over the back's body, so the two
/// read as one folder; open it swings toward the eye and projects wider
private struct FolderFront: Shape {
    var open: Double
    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ring = FolderPanels(open: open, in: rect).front
        guard !ring.isEmpty else { return Path() }
        var p = Path()
        p.move(to: ring[0])
        p.addLines(Array(ring.dropFirst()))
        p.closeSubpath()
        return p
    }
}
