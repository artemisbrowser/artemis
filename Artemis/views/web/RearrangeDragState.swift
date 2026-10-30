import SwiftUI

/// the named coordinate space the rearrange gesture, pane frames and overlay all
/// share, so the cursor, the drop highlight and the ghost line up. `SplitBoxEdge`
/// and `SplitDropTarget` live in the model (SplitGroup.swift).
let splitRearrangeSpace = "splitRearrangeSpace"

/// shared state for dragging a pane around its split to re-tile it. the rearrange
/// button on each pane feeds it (cursor + which pane), each `SplitPane` reports
/// its frame into it, and the split container reads it to draw the grey drop
/// highlight + the floating mini-rect ghost and to commit the drop on release.
/// distinct from `SidebarDragState`: that one lives in the sidebar's coordinate
/// space and carries a list slot; this is the content area and carries a node
/// target.
@Observable
final class RearrangeDragState {
    /// sentinel tab the preview tree renders as the drop placeholder (never
    /// persisted; only ever lives in the ephemeral preview tree)
    static let placeholderTab = UUID()
    /// stable node ids for the placeholder leaf and any split that wraps a pane to
    /// host it — so re-evaluating `previewRoot` every render keeps identity and
    /// doesn't remount (blank) the surrounding panes
    static let placeholderNodeID = UUID()
    static let placeholderWrapperID = UUID()

    /// the split being targeted, or nil when the content shows a single page
    /// (an incoming tab dropped there starts a fresh split)
    var group: SplitGroup?
    /// the pane being dragged — an existing leaf (rearrange) or an incoming
    /// sidebar tab (`incoming`) being dragged into the content
    var draggedID: BrowserTab.ID?
    /// true when `draggedID` is a sidebar tab dragged in (not yet a pane)
    var incoming = false
    /// over a single page (no split), the lone focused tab acts as the one pane to
    /// split against
    var singlePaneTab: BrowserTab.ID?
    /// the cursor in `splitRearrangeSpace`
    var cursor: CGPoint = .zero
    /// the split container's size, for the outer sliver and region geometry
    var containerSize: CGSize = .zero

    /// thin outer strip, as a fraction of each container axis, that drops the dragged
    /// pane at the whole split's edge. only with ≥2 other panes: a lone other pane's
    /// own edges already reach the rim.
    private static let outerSliver: CGFloat = 0.06

    @ObservationIgnored private var zoneCache: Zones?

    var isDragging: Bool { draggedID != nil }

    /// begin rearranging an existing pane within its split
    func begin(_ group: SplitGroup, pane: BrowserTab.ID, at p: CGPoint) {
        self.group = group
        draggedID = pane
        incoming = false
        singlePaneTab = nil
        cursor = p
    }

    /// begin (or update) dragging a sidebar tab into the content. `group` is the
    /// split shown there, or nil + `singlePaneTab` when a single page is shown
    func beginIncoming(
        tab: BrowserTab.ID, group: SplitGroup?, singlePaneTab: BrowserTab.ID?, at p: CGPoint
    ) {
        self.group = group
        self.singlePaneTab = singlePaneTab
        draggedID = tab
        incoming = true
        cursor = p
    }

    func clear() {
        group = nil
        draggedID = nil
        incoming = false
        singlePaneTab = nil
    }

    // MARK: - Base layout (stable: independent of the cursor / placeholder)

    /// the tree the panes lay out from while dragging, *without* the placeholder:
    /// the dragged pane is removed so its slot is fully reclaimed and the rest
    /// reflow to fill (an incoming tab isn't in the split, so it's left as-is). the
    /// drag is driven by an NSEvent monitor, not the pane's gesture, so removing the
    /// pane can't cancel it. nil when no split is shown.
    func baseRoot() -> SplitNode? {
        guard let group else { return nil }
        if incoming { return group.root }
        guard let draggedID, let pruned = group.root.removingLeaf(draggedID) else {
            return group.root
        }
        return SplitNode.normalized(pruned)
    }

    /// the drop zones of one base layout. `canonical` maps every raw target to the
    /// first target yielding the same tiling, so each outcome owns exactly one zone.
    private struct Zones {
        struct Key: Equatable {
            var size: CGSize
            var frames: [PaneFrame]
            var shape: String?
        }
        let key: Key
        let base: SplitNode?
        let outer: Bool
        /// each pane's rect grown to the gap centrelines, in container-normalised units
        /// (0…1 on both axes), so the cells tile the container with no dead gaps
        let cells: [PaneFrame]
        let canonical: [SplitDropTarget: SplitDropTarget]
        var guide: Path?

        init(key: Key, base: SplitNode?) {
            self.key = key
            self.base = base
            outer = key.frames.count >= 2
            let w = key.size.width, h = key.size.height
            cells = key.frames.map { f in
                let r = f.rect.insetBy(dx: -splitPaneGap / 2, dy: -splitPaneGap / 2)
                    .intersection(CGRect(origin: .zero, size: key.size))
                return PaneFrame(
                    tab: f.tab,
                    rect: CGRect(x: r.minX / w, y: r.minY / h, width: r.width / w, height: r.height / h))
            }
            var canonical: [SplitDropTarget: SplitDropTarget] = [:]
            if let base {
                let edges: [SplitBoxEdge] = [.left, .right, .top, .bottom]
                let outerTargets = outer ? edges.map { SplitDropTarget.outerEdge($0) } : []
                let panes = key.frames.flatMap { f in
                    edges.map { SplitDropTarget.paneEdge(leaf: f.tab, edge: $0) }
                }
                var firstByShape: [String: SplitDropTarget] = [:]
                for t in outerTargets + panes {
                    let tree: SplitNode =
                        switch t {
                        case .paneEdge(let leaf, let edge):
                            base.insertingLeaf(
                                RearrangeDragState.placeholderTab, beside: leaf, axis: edge.axis, before: edge.before)
                        case .outerEdge(let edge):
                            base.insertingLeaf(
                                RearrangeDragState.placeholderTab, atOuterEdgeAxis: edge.axis, before: edge.before)
                        }
                    let shape = SplitNode.normalized(tree).shape
                    canonical[t] = firstByShape[shape, default: t]
                    firstByShape[shape] = canonical[t]
                }
            }
            self.canonical = canonical
        }

        /// the edge of `r` nearest `(u, v)`. measured in normalised units, so every zone
        /// boundary runs parallel to a container side or diagonal
        private static func nearestEdge(
            _ u: CGFloat, _ v: CGFloat, in r: CGRect
        ) -> (edge: SplitBoxEdge, distance: CGFloat) {
            let d: [(edge: SplitBoxEdge, distance: CGFloat)] = [
                (.left, u - r.minX), (.right, r.maxX - u), (.top, v - r.minY), (.bottom, r.maxY - v),
            ]
            return d.min { $0.distance < $1.distance } ?? d[0]
        }

        /// the outer sliver first, then the nearest edge of the cell under `p`
        func raw(_ p: CGPoint) -> SplitDropTarget? {
            let u = p.x / key.size.width, v = p.y / key.size.height
            let rim = Self.nearestEdge(u, v, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if outer, rim.distance <= RearrangeDragState.outerSliver { return .outerEdge(rim.edge) }
            guard let cell = cells.first(where: { $0.rect.contains(CGPoint(x: u, y: v)) }) else {
                return nil
            }
            return .paneEdge(leaf: cell.tab, edge: Self.nearestEdge(u, v, in: cell.rect).edge)
        }

        func resolve(_ p: CGPoint) -> SplitDropTarget? {
            raw(p).map { canonical[$0] ?? $0 }
        }

        /// every candidate line (sliver rims, cell edges, each cell's corner-to-ridge
        /// diagonals and ridge), cut at every crossing, keeping the pieces whose two
        /// sides resolve to different drops
        func boundaries() -> Path {
            let w = key.size.width, h = key.size.height
            func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: u * w, y: v * h) }
            var lines: [(CGPoint, CGPoint)] = []
            if outer {
                let k = RearrangeDragState.outerSliver
                lines += [
                    (pt(k, 0), pt(k, 1)), (pt(1 - k, 0), pt(1 - k, 1)),
                    (pt(0, k), pt(1, k)), (pt(0, 1 - k), pt(1, 1 - k)),
                ]
            }
            for c in cells.map(\.rect) {
                let r = min(c.width, c.height) / 2
                let tl = pt(c.minX, c.minY), tr = pt(c.maxX, c.minY)
                let bl = pt(c.minX, c.maxY), br = pt(c.maxX, c.maxY)
                let a = pt(c.minX + r, c.minY + r), b = pt(c.maxX - r, c.maxY - r)
                lines += [
                    (tl, tr), (tr, br), (br, bl), (bl, tl), (a, b),
                    (tl, a), (bl, CGPoint(x: a.x, y: b.y)), (tr, CGPoint(x: b.x, y: a.y)), (br, b),
                ]
            }
            func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }
            var drawn = Set<String>()
            var path = Path()
            for (p, q) in lines {
                let r = CGPoint(x: q.x - p.x, y: q.y - p.y)
                let len = hypot(r.x, r.y)
                guard len > 1 else { continue }
                var cuts: [CGFloat] = [0, 1]
                for (p2, q2) in lines {
                    let s = CGPoint(x: q2.x - p2.x, y: q2.y - p2.y)
                    let qp = CGPoint(x: p2.x - p.x, y: p2.y - p.y)
                    let denom = cross(r, s)
                    if abs(denom) > 1e-6 {
                        let u = cross(qp, r) / denom
                        if u >= -1e-6, u <= 1 + 1e-6 { cuts.append(cross(qp, s) / denom) }
                    } else if abs(cross(qp, r)) / len < 0.01 {
                        for e in [p2, q2] {
                            cuts.append(((e.x - p.x) * r.x + (e.y - p.y) * r.y) / (len * len))
                        }
                    }
                }
                let ts = cuts.filter { $0 >= 0 && $0 <= 1 }.sorted()
                func at(_ t: CGFloat) -> CGPoint { CGPoint(x: p.x + r.x * t, y: p.y + r.y * t) }
                let nx = -r.y / len * 1.5, ny = r.x / len * 1.5
                var run: (start: CGFloat, end: CGFloat)?
                for (t0, t1) in zip(ts, ts.dropFirst()) where (t1 - t0) * len > 0.5 {
                    let m = at((t0 + t1) / 2)
                    let one = resolve(CGPoint(x: m.x + nx, y: m.y + ny))
                    let two = resolve(CGPoint(x: m.x - nx, y: m.y - ny))
                    let ends = [at(t0), at(t1)].map { "\(Int(($0.x * 4).rounded())),\(Int(($0.y * 4).rounded()))" }
                    if one != nil, two != nil, one != two, drawn.insert(ends.sorted().joined(separator: ";")).inserted {
                        run = (run?.start ?? t0, t1)
                    } else if let r = run {
                        path.move(to: at(r.start))
                        path.addLine(to: at(r.end))
                        run = nil
                    }
                }
                if let r = run {
                    path.move(to: at(r.start))
                    path.addLine(to: at(r.end))
                }
            }
            return path
        }
    }

    /// zones for the current base layout, rebuilt only when that layout changes
    private var zones: Zones {
        let container = CGRect(origin: .zero, size: containerSize)
        let base = baseRoot()
        let frames: [PaneFrame] =
            if let base {
                base.paneFrames(in: container, gap: splitPaneGap)
                    .filter { incoming || $0.tab != draggedID }
            } else if let single = singlePaneTab {
                [PaneFrame(tab: single, rect: container)]
            } else { [] }
        let key = Zones.Key(size: containerSize, frames: frames, shape: base?.shape)
        if let cached = zoneCache, cached.key == key { return cached }
        let z = Zones(key: key, base: base)
        zoneCache = z
        return z
    }

    // MARK: - Hit-test

    /// where the current cursor would drop; spots that yield the same tiling share
    /// one target, so crossing between them changes nothing
    var target: SplitDropTarget? {
        guard draggedID != nil, containerSize.width > 0, containerSize.height > 0 else { return nil }
        return zones.resolve(cursor)
    }

    // MARK: - Drop-zone guide

    /// the lines separating zones that drop differently, in `splitRearrangeSpace`
    struct DropGuide {
        var lines: Path
        var size: CGSize
    }

    func dropGuide() -> DropGuide? {
        guard isDragging, containerSize.width > 0, containerSize.height > 0 else { return nil }
        let z = zones
        let lines = z.guide ?? z.boundaries()
        zoneCache?.guide = lines
        return DropGuide(lines: lines, size: containerSize)
    }

    // MARK: - Preview / display

    /// the tree to render while dragging over `group`: the base layout with a
    /// placeholder leaf inserted where the drop would land, so the real panes
    /// reflow/resize around it. nil when this isn't the dragged group (render the
    /// real `group.root`).
    func previewRoot(for group: SplitGroup) -> SplitNode? {
        guard isDragging, self.group?.id == group.id, let base = baseRoot() else { return nil }
        let balance = UserDefaults.standard.autoResizeSplitOnDrag
        func finish(_ node: SplitNode) -> SplitNode { balance ? node.balancedRatios() : node }
        guard let target else { return finish(base) }  // no target → just the reflowed base
        let ph = Self.placeholderTab
        let leafID = Self.placeholderNodeID
        let wrapID = Self.placeholderWrapperID
        switch target {
        case .paneEdge(let leaf, let edge):
            return finish(
                base.insertingLeaf(
                    ph, beside: leaf, axis: edge.axis, before: edge.before,
                    leafID: leafID, wrapperID: wrapID))
        case .outerEdge(let edge):
            return finish(
                base.insertingLeaf(
                    ph, atOuterEdgeAxis: edge.axis, before: edge.before,
                    leafID: leafID, wrapperID: wrapID))
        }
    }

    /// the placeholder shows the drop inside a split; over a single page there's no
    /// tree to reflow, so a grey region highlight stands in instead
    var regionRect: CGRect? {
        guard group == nil, let target else { return nil }
        let w = containerSize.width, h = containerSize.height
        switch target.edge {
        case .left: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .right: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        }
    }

    /// the floating mini-rect ghost is shown only when no in-layout placeholder is:
    /// over a single page, or over a split before a target is resolved
    var showsFloatingGhost: Bool { group == nil || target == nil }

    /// the drop to apply on release, or nil if the cursor isn't over a valid target
    func commitAction() -> SplitRearrange? {
        guard let draggedID, let target else { return nil }
        switch target {
        case .paneEdge(let leaf, let edge):
            guard leaf != draggedID else { return nil }
            return .besideLeaf(
                dragged: draggedID, target: leaf, axis: edge.axis, before: edge.before)
        case .outerEdge(let edge):
            return .outerEdge(dragged: draggedID, axis: edge.axis, before: edge.before)
        }
    }
}

extension SplitNode {
    /// structure and leaf order, ignoring ids and ratios
    fileprivate var shape: String {
        switch self {
        case .leaf(_, let tab): tab.uuidString
        case .split(_, let axis, let children):
            "\(axis.rawValue)(" + children.map(\.node.shape).joined(separator: ",") + ")"
        }
    }
}
