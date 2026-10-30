import CoreGraphics
import Foundation
import Observation

/// one node of a split's tiling tree: either a `leaf` (a single tab's pane) or a
/// `split` that lays its `children` out along an `axis`, each child taking a
/// fraction (`ratio`) of the axis. value type — a mutation rebuilds the affected
/// branch and the owning `SplitGroup` reassigns its `root`. each node carries a
/// stable `id` so SwiftUI moves a subtree (and its hosted web view) on a
/// restructure instead of tearing it down.
indirect enum SplitNode: Identifiable {
    case leaf(id: UUID, tab: UUID)
    case split(id: UUID, axis: SplitOrientation, children: [Child])

    /// a child slot in a split node: the subtree plus its fraction of the axis
    struct Child: Identifiable {
        var node: SplitNode
        var ratio: Double
        var id: UUID { node.id }
    }

    var id: UUID {
        switch self {
        case .leaf(let id, _): id
        case .split(let id, _, _): id
        }
    }

    // MARK: - Projections

    /// the tabs of every leaf, left→right / top→bottom (in-order traversal). the
    /// sidebar and most of `TabManager` read a split through this flat list.
    var leafTabIDs: [UUID] {
        switch self {
        case .leaf(_, let tab): [tab]
        case .split(_, _, let children): children.flatMap { $0.node.leafTabIDs }
        }
    }

    var leafCount: Int {
        switch self {
        case .leaf: 1
        case .split(_, _, let children): children.reduce(0) { $0 + $1.node.leafCount }
        }
    }

    func contains(_ tab: UUID) -> Bool { leafTabIDs.contains(tab) }

    var firstLeafTab: UUID? { leafTabIDs.first }

    // MARK: - Structural builders

    /// a flat single-axis split of `tabIDs` (the legacy linear layout). a single
    /// tab returns a bare leaf — a split always holds at least two children.
    static func linear(
        tabIDs: [UUID], axis: SplitOrientation, ratios: [Double]? = nil
    ) -> SplitNode {
        guard tabIDs.count > 1 else {
            return .leaf(id: UUID(), tab: tabIDs.first ?? UUID())
        }
        let r = normalizedRatios(ratios, count: tabIDs.count)
        let children = tabIDs.enumerated().map { i, tab in
            Child(node: .leaf(id: UUID(), tab: tab), ratio: r[i])
        }
        return .split(id: UUID(), axis: axis, children: children)
    }

    /// equal slices for `count` children
    static func balanced(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    /// clamp each ratio to `minRatio` and renormalize to sum 1; falls back to a
    /// balanced split when the input is the wrong length or degenerate
    static func normalizedRatios(_ proposed: [Double]?, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard let p = proposed, p.count == count else { return balanced(count: count) }
        let floored = p.map { max($0, SplitGroup.minRatio) }
        let sum = floored.reduce(0, +)
        return sum > 0 ? floored.map { $0 / sum } : balanced(count: count)
    }

    // MARK: - Mutations (return a rebuilt node; ids preserved where they survive)

    /// drop the leaf for `tab` from this subtree, or nil if this whole node *is*
    /// that leaf. split nodes left with a single child / no leaves are not
    /// collapsed here — that's `normalized`'s job, run once after a removal.
    func removingLeaf(_ tab: UUID) -> SplitNode? {
        switch self {
        case .leaf(_, let t):
            return t == tab ? nil : self
        case .split(let id, let axis, let children):
            let kept = children.compactMap { child -> Child? in
                guard let node = child.node.removingLeaf(tab) else { return nil }
                return Child(node: node, ratio: child.ratio)
            }
            return kept.isEmpty ? nil : .split(id: id, axis: axis, children: kept)
        }
    }

    /// equalize every split node's children to 1/n — "as even as possible" at each
    /// level (e.g. 3-across-top each take a third of the top half). structure +
    /// node ids untouched.
    func balancedRatios() -> SplitNode {
        guard case .split(let id, let axis, let children) = self else { return self }
        let n = children.count
        let kids = children.map {
            Child(node: $0.node.balancedRatios(), ratio: 1.0 / Double(max(n, 1)))
        }
        return .split(id: id, axis: axis, children: kids)
    }

    /// collapse single-child splits into their child, splice a child split that
    /// shares its parent's axis up into the parent (so "3 across" stays flat and
    /// dividers don't jump), and renormalize each node's ratios. bottom-up.
    static func normalized(_ node: SplitNode) -> SplitNode {
        guard case .split(let id, let axis, let children) = node else { return node }

        // normalize children first (bottom-up)
        let norm = children.map { Child(node: normalized($0.node), ratio: $0.ratio) }
        if norm.count == 1 { return norm[0].node }  // absorb the split's slot

        // splice same-axis child splits up, distributing their ratio proportionally
        var spliced: [Child] = []
        for child in norm {
            if case .split(_, let cAxis, let cKids) = child.node, cAxis == axis {
                let innerSum = cKids.reduce(0) { $0 + $1.ratio }
                for ik in cKids {
                    let frac = innerSum > 0 ? ik.ratio / innerSum : 1.0 / Double(cKids.count)
                    spliced.append(Child(node: ik.node, ratio: child.ratio * frac))
                }
            } else {
                spliced.append(child)
            }
        }
        if spliced.count == 1 { return spliced[0].node }

        let ratios = normalizedRatios(spliced.map(\.ratio), count: spliced.count)
        let result = spliced.enumerated().map { i, c in Child(node: c.node, ratio: ratios[i]) }
        return .split(id: id, axis: axis, children: result)
    }

    /// insert a `dragged` leaf next to the `target` leaf, splitting along `axis`.
    /// if the target already sits in a same-axis split it joins as a sibling
    /// (sharing the target's slot); otherwise the target is wrapped in a new
    /// perpendicular split. `before` puts the new pane on the leading/top side.
    /// `leafID`/`wrapperID` default to fresh UUIDs for a real commit; the *preview*
    /// passes stable constants so re-evaluating it every render doesn't churn node
    /// identity (which would remount — and blank — the real panes around it).
    func insertingLeaf(
        _ dragged: UUID, beside target: UUID,
        axis: SplitOrientation, before: Bool,
        leafID: UUID = UUID(), wrapperID: UUID = UUID()
    ) -> SplitNode {
        switch self {
        case .leaf(_, let t):
            guard t == target else { return self }  // only when the root is one leaf
            let dl = Child(node: .leaf(id: leafID, tab: dragged), ratio: 0.5)
            let tl = Child(node: self, ratio: 0.5)
            return .split(id: wrapperID, axis: axis, children: before ? [dl, tl] : [tl, dl])

        case .split(let id, let nodeAxis, let children):
            if let idx = children.firstIndex(where: {
                if case .leaf(_, let t) = $0.node { return t == target }
                return false
            }) {
                let targetChild = children[idx]
                var newKids = children
                if nodeAxis == axis {
                    let half = targetChild.ratio / 2
                    newKids[idx] = Child(node: targetChild.node, ratio: half)
                    let dl = Child(node: .leaf(id: leafID, tab: dragged), ratio: half)
                    newKids.insert(dl, at: before ? idx : idx + 1)
                } else {
                    let dl = Child(node: .leaf(id: leafID, tab: dragged), ratio: 0.5)
                    let tl = Child(node: targetChild.node, ratio: 0.5)
                    let wrapped = SplitNode.split(
                        id: wrapperID, axis: axis, children: before ? [dl, tl] : [tl, dl])
                    newKids[idx] = Child(node: wrapped, ratio: targetChild.ratio)
                }
                return .split(id: id, axis: nodeAxis, children: newKids)
            }
            // not a direct child here — recurse
            let recursed = children.map {
                Child(
                    node: $0.node.insertingLeaf(
                        dragged, beside: target, axis: axis, before: before,
                        leafID: leafID, wrapperID: wrapperID),
                    ratio: $0.ratio)
            }
            return .split(id: id, axis: nodeAxis, children: recursed)
        }
    }

    /// insert `dragged` as a new pane along an outer edge of this whole subtree
    /// (used at the root). pure (no normalize). `leafID`/`wrapperID` default fresh;
    /// the preview passes stable constants (see `insertingLeaf(beside:)`).
    func insertingLeaf(
        _ dragged: UUID, atOuterEdgeAxis axis: SplitOrientation, before: Bool,
        leafID: UUID = UUID(), wrapperID: UUID = UUID()
    ) -> SplitNode {
        if case .split(let id, let sAxis, let children) = self, sAxis == axis {
            let n = children.count
            let newRatio = 1.0 / Double(n + 1)
            let scale = Double(n) / Double(n + 1)
            var scaled = children.map { Child(node: $0.node, ratio: $0.ratio * scale) }
            let dl = Child(node: .leaf(id: leafID, tab: dragged), ratio: newRatio)
            if before { scaled.insert(dl, at: 0) } else { scaled.append(dl) }
            return .split(id: id, axis: axis, children: scaled)
        }
        let dl = Child(node: .leaf(id: leafID, tab: dragged), ratio: 0.5)
        let me = Child(node: self, ratio: 0.5)
        return .split(id: wrapperID, axis: axis, children: before ? [dl, me] : [me, dl])
    }

    /// analytic pane frames, mirroring the render layout (same gap + sum-normalized
    /// ratios). the panes are positioned from these (a flat, stable layer that never
    /// re-parents a `WKWebView`), and the drop hit-test reads them too — a *stable*
    /// reference that doesn't feed back on live frames (the favourites-grid lesson).
    func paneFrames(in rect: CGRect, gap: CGFloat) -> [PaneFrame] {
        switch self {
        case .leaf(_, let tab):
            return [PaneFrame(tab: tab, rect: rect)]
        case .split(_, let axis, let children):
            let isCols = axis == .columns
            let n = children.count
            let total = isCols ? rect.width : rect.height
            let avail = max(total - gap * CGFloat(max(n - 1, 0)), 1)
            let sum = children.reduce(0) { $0 + $1.ratio }
            var out: [PaneFrame] = []
            var pos = isCols ? rect.minX : rect.minY
            for child in children {
                let frac = sum > 0 ? child.ratio / sum : 1.0 / Double(max(n, 1))
                let len = avail * frac
                let r =
                    isCols
                    ? CGRect(x: pos, y: rect.minY, width: len, height: rect.height)
                    : CGRect(x: rect.minX, y: pos, width: rect.width, height: len)
                out.append(contentsOf: child.node.paneFrames(in: r, gap: gap))
                pos += len + gap
            }
            return out
        }
    }

    /// analytic divider rects (the gaps between siblings at every depth), each with
    /// the node path + boundary it resizes and the axis length to convert a point
    /// drag into a ratio. mirrors `paneFrames`'s layout so dividers sit in the gaps.
    func dividers(in rect: CGRect, gap: CGFloat, path: [Int] = []) -> [SplitDividerInfo] {
        guard case .split(_, let axis, let children) = self else { return [] }
        let isCols = axis == .columns
        let n = children.count
        let total = isCols ? rect.width : rect.height
        let avail = max(total - gap * CGFloat(max(n - 1, 0)), 1)
        let sum = children.reduce(0) { $0 + $1.ratio }

        var result: [SplitDividerInfo] = []
        var rects: [CGRect] = []
        var pos = isCols ? rect.minX : rect.minY
        for (i, child) in children.enumerated() {
            let frac = sum > 0 ? child.ratio / sum : 1.0 / Double(max(n, 1))
            let len = avail * frac
            let r =
                isCols
                ? CGRect(x: pos, y: rect.minY, width: len, height: rect.height)
                : CGRect(x: rect.minX, y: pos, width: rect.width, height: len)
            rects.append(r)
            result += child.node.dividers(in: r, gap: gap, path: path + [i])
            pos += len + gap
        }
        // a divider sits in each gap between adjacent children of THIS node
        for i in 0 ..< max(n - 1, 0) {
            let a = rects[i]
            let dRect =
                isCols
                ? CGRect(x: a.maxX, y: rect.minY, width: gap, height: rect.height)
                : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: gap)
            result.append(
                SplitDividerInfo(
                    path: path, boundary: i, axis: axis, rect: dRect, axisLength: avail))
        }
        return result
    }

    /// adjust the divider between children `i` and `i+1` of the split node at
    /// `path` (a list of child indices from here), by a fraction of the axis.
    func resizing(path: ArraySlice<Int>, boundary i: Int, by delta: Double) -> SplitNode {
        guard case .split(let id, let axis, var children) = self else { return self }
        if let idx = path.first {
            guard children.indices.contains(idx) else { return self }
            children[idx].node = children[idx].node.resizing(
                path: path.dropFirst(), boundary: i, by: delta)
            return .split(id: id, axis: axis, children: children)
        }
        guard children.indices.contains(i), children.indices.contains(i + 1) else { return self }
        let lo = SplitGroup.minRatio
        let pair = children[i].ratio + children[i + 1].ratio
        let newA = min(max(children[i].ratio + delta, lo), pair - lo)
        children[i].ratio = newA
        children[i + 1].ratio = pair - newA
        return .split(id: id, axis: axis, children: children)
    }
}

/// a split view: 2–4 tabs tiled together in the content area and shown as one
/// grouped block in the sidebar. the arrangement is a `root` tiling tree; the
/// group's focused pane is the space's `selectedTabID` (always one of the leaves
/// while the split is shown).
///
/// linking: when `linkSourceID` is set, plain link clicks in that pane open in the
/// *next* leaf (in-order) instead of navigating in place. nil = every pane navigates itself.
@Observable
final class SplitGroup: Identifiable {
    let id: UUID
    /// the tiling tree. every mutation reassigns this whole value.
    var root: SplitNode
    /// the pane whose plain link clicks open elsewhere, or nil when independent
    var linkSourceID: UUID?
    /// the explicit pane those links open in (chosen via the link-target picker)
    var linkTargetID: UUID?
    /// the pane that was focused last time this split was shown, so re-opening it
    /// from the sidebar restores that pane rather than jumping to the first
    var lastFocusedID: UUID?

    /// a split needs at least two panes; the owning space dissolves it the moment
    /// it drops below two
    static let minPanes = 2
    static let maxPanes = 4
    /// no pane may shrink below this fraction of its axis, so one can't vanish
    static let minRatio = 0.12

    /// build from a flat linear arrangement (new splits, legacy persisted data)
    init(
        id: UUID = UUID(),
        tabIDs: [UUID],
        orientation: SplitOrientation = .columns,
        ratios: [Double]? = nil,
        linkSourceID: UUID? = nil,
        linkTargetID: UUID? = nil
    ) {
        self.id = id
        self.root = SplitNode.linear(tabIDs: tabIDs, axis: orientation, ratios: ratios)
        self.linkSourceID = linkSourceID
        self.linkTargetID = linkTargetID
    }

    /// build from a restored tiling tree
    init(
        id: UUID = UUID(), root: SplitNode,
        linkSourceID: UUID? = nil, linkTargetID: UUID? = nil
    ) {
        self.id = id
        self.root = SplitNode.normalized(root)
        self.linkSourceID = linkSourceID
        self.linkTargetID = linkTargetID
    }

    // MARK: - Projections

    /// the panes left→right / top→bottom — the flat list every linear reader uses
    var tabIDs: [UUID] { root.leafTabIDs }
    var leafCount: Int { root.leafCount }
    func contains(_ id: UUID) -> Bool { root.contains(id) }

    /// the root's axis when it's a split (else a sensible default) — the axis a
    /// sidebar reorder flattens to, and the orientation the sidebar block shows
    var primaryAxis: SplitOrientation {
        if case .split(_, let axis, _) = root { return axis }
        return .columns
    }

    /// a valid link needs a distinct source + target both still in the group
    var isLinked: Bool {
        guard let s = linkSourceID, let t = linkTargetID, s != t else { return false }
        return contains(s) && contains(t)
    }

    // MARK: - Mutations

    /// remove a pane, collapsing and rebalancing the tree around the gap
    func removeLeaf(_ id: UUID) {
        guard let pruned = root.removingLeaf(id) else { return }
        root = SplitNode.normalized(pruned)
        // linking breaks if either end leaves
        if linkSourceID == id || linkTargetID == id {
            linkSourceID = nil
            linkTargetID = nil
        }
    }

    /// split the `target` pane and drop `dragged` into the new half
    func insertLeaf(
        _ dragged: UUID, beside target: UUID,
        axis: SplitOrientation, before: Bool
    ) {
        root = SplitNode.normalized(
            root.insertingLeaf(dragged, beside: target, axis: axis, before: before))
    }

    /// split the whole group along an outer edge, dropping `dragged` on that side
    /// so it spans across everything else
    func insertLeaf(_ dragged: UUID, atOuterEdge axis: SplitOrientation, before: Bool) {
        let newRoot: SplitNode
        if case .split(let id, let rAxis, let children) = root, rAxis == axis {
            let n = children.count
            let newRatio = 1.0 / Double(n + 1)
            let scale = Double(n) / Double(n + 1)
            var scaled = children.map { SplitNode.Child(node: $0.node, ratio: $0.ratio * scale) }
            let dl = SplitNode.Child(node: .leaf(id: UUID(), tab: dragged), ratio: newRatio)
            if before { scaled.insert(dl, at: 0) } else { scaled.append(dl) }
            newRoot = .split(id: id, axis: axis, children: scaled)
        } else {
            let dl = SplitNode.Child(node: .leaf(id: UUID(), tab: dragged), ratio: 0.5)
            let rootChild = SplitNode.Child(node: root, ratio: 0.5)
            newRoot = .split(
                id: UUID(), axis: axis, children: before ? [dl, rootChild] : [rootChild, dl])
        }
        root = SplitNode.normalized(newRoot)
    }

    /// add a pane as a new top-level child of the root, at `index` among them
    /// (default: end) — the sidebar/merge "add to split" entry point
    func appendLeaf(_ id: UUID, at index: Int? = nil) {
        guard !contains(id) else { return }
        if case .split(let rid, let axis, let children) = root {
            let n = children.count
            let newRatio = 1.0 / Double(n + 1)
            let scale = Double(n) / Double(n + 1)
            var scaled = children.map { SplitNode.Child(node: $0.node, ratio: $0.ratio * scale) }
            let slot = max(0, min(index ?? scaled.count, scaled.count))
            scaled.insert(
                SplitNode.Child(node: .leaf(id: UUID(), tab: id), ratio: newRatio), at: slot)
            root = SplitNode.normalized(.split(id: rid, axis: axis, children: scaled))
        } else if let only = root.firstLeafTab {
            root = SplitNode.linear(tabIDs: [only, id], axis: primaryAxis)
        }
    }

    /// rebuild the layout as one flat single-axis split in the given pane order —
    /// what a sidebar reorder (an inherently 1-D gesture) lands on
    func flatten(order: [UUID]) {
        let ids = order.filter { contains($0) }
        guard ids.count >= SplitGroup.minPanes else { return }
        root = SplitNode.linear(tabIDs: ids, axis: primaryAxis)
    }

    /// adjust the divider at `boundary` inside the split node addressed by `path`
    func resize(path: [Int], boundary: Int, by delta: Double) {
        root = root.resizing(path: path[...], boundary: boundary, by: delta)
    }
}

/// a pane's analytic frame in the split container's space — the panes are
/// positioned from these and the drop hit-test reads them. `id` is the tab, stable
/// across renders so the flat pane layer's `ForEach` never remounts a pane.
struct PaneFrame: Identifiable, Equatable {
    let tab: UUID
    let rect: CGRect
    var id: UUID { tab }
}

/// one resizable divider, computed analytically from the tree: where it sits, the
/// node path + boundary it adjusts, and the axis length to turn a point drag into
/// a ratio delta. `id` is stable across renders (path + boundary) so the divider
/// view isn't remounted as the layout reflows.
struct SplitDividerInfo: Identifiable {
    let path: [Int]
    let boundary: Int
    let axis: SplitOrientation
    let rect: CGRect
    let axisLength: CGFloat
    var id: String { "\(path).\(boundary)" }
}

/// an edge of a box (a pane, or the whole split container)
enum SplitBoxEdge: Hashable {
    case left, right, top, bottom

    /// the split axis created by dropping against this edge
    var axis: SplitOrientation { (self == .left || self == .right) ? .columns : .rows }
    /// whether the new pane lands on the leading/top side of the split
    var before: Bool { self == .left || self == .top }
}

/// where a content tiling drop would land, computed by the rearrange overlay from
/// the cursor: split a pane along an edge, or split the whole group's outer edge.
/// every spot on a pane resolves to its nearest edge (no neutral centre).
enum SplitDropTarget: Hashable {
    /// split the given pane along an edge, dropping the dragged pane in that half
    case paneEdge(leaf: UUID, edge: SplitBoxEdge)
    /// split the whole group along an outer edge (the dragged pane spans it)
    case outerEdge(SplitBoxEdge)

    /// the box edge this drop splits along
    var edge: SplitBoxEdge {
        switch self {
        case .paneEdge(_, let e): e
        case .outerEdge(let e): e
        }
    }
}

/// the outcome of a drag-to-rearrange drop, computed by the rearrange overlay and
/// applied through `TabManager.rearrangeSplit`. `besideLeaf` splits a pane,
/// `outerEdge` splits the whole group along an outer edge.
enum SplitRearrange {
    case besideLeaf(dragged: UUID, target: UUID, axis: SplitOrientation, before: Bool)
    case outerEdge(dragged: UUID, axis: SplitOrientation, before: Bool)

    /// the pane being moved (kept focused after the drop)
    var draggedID: UUID {
        switch self {
        case .besideLeaf(let d, _, _, _): d
        case .outerEdge(let d, _, _): d
        }
    }
}

// MARK: - Persistence

extension SplitNodeData {
    /// resolve leaves back to live tab ids, dropping any that have gone stale
    func toNode(resolve: (UUID?, Int) -> UUID?) -> SplitNode? {
        switch self {
        case .leaf(let id, let idx):
            guard let tab = resolve(id, idx) else { return nil }
            return .leaf(id: UUID(), tab: tab)
        case .split(let axis, let children):
            let kids = children.compactMap { c -> SplitNode.Child? in
                guard let node = c.node.toNode(resolve: resolve) else { return nil }
                return SplitNode.Child(node: node, ratio: c.ratio)
            }
            return kids.isEmpty ? nil : .split(id: UUID(), axis: axis, children: kids)
        }
    }
}

extension SplitNode {
    /// snapshot to persistable data, dropping leaves whose tab isn't in `indexOf`
    func toData(indexOf: (UUID) -> Int?) -> SplitNodeData? {
        switch self {
        case .leaf(_, let tab):
            guard let idx = indexOf(tab) else { return nil }
            return .leaf(tabID: tab, tabIndex: idx)
        case .split(_, let axis, let children):
            let kids = children.compactMap { c -> SplitNodeData.Child? in
                guard let node = c.node.toData(indexOf: indexOf) else { return nil }
                return SplitNodeData.Child(node: node, ratio: c.ratio)
            }
            return kids.isEmpty ? nil : .split(axis: axis, children: kids)
        }
    }
}

extension SplitGroupData {
    /// the live root for this group, from the tree if present, else synthesized
    /// from the legacy flat fields. nil when fewer than two panes survive.
    func effectiveRoot(resolve: (UUID?, Int) -> UUID?) -> SplitNode? {
        if let tree, let node = tree.toNode(resolve: resolve) {
            return node
        }
        let tabs = tabIDs.isEmpty
            ? tabIndices.compactMap { resolve(nil, $0) }
            : tabIDs.compactMap { resolve($0, -1) }
        guard tabs.count >= SplitGroup.minPanes else { return nil }
        return SplitNode.linear(
            tabIDs: tabs, axis: orientation, ratios: ratios.isEmpty ? nil : ratios)
    }
}
