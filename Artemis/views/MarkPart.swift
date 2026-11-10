// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the icon's shapes in its 1024-point space, fitted to a square and turned `angle` radians about its centre.
/// the comet passes behind the left leg and its foot; over the right leg it cuts a `gap` round itself from the A.
/// `crossing` is the A under the comet
struct MarkPart: Shape {
    let isComet: Bool
    var angle = 0.0
    /// the comet moved from its place on the A, in the icon's space
    var trail = CGAffineTransform.identity
    var gap: CGFloat = 24
    var crossing = false
    /// the share of the comet drawn, swept round its orbit from the tail
    var sweep = 1.0

    /// the circle the comet's arc lies on, and the angles in radians its sweep runs between, tail to past the head
    nonisolated static let orbit = (centre: CGPoint(x: 394, y: 176), radius: 525.0)
    nonisolated static let sweepAngles = (from: 2.3, to: 0.25)

    /// comet.svg: its lower edge from the tail, then its upper edge back from the head
    nonisolated private static let edges: [CGFloat] = [
        83.7, 616.3, 94.8, 626.9, 106.3, 637.1, 118.4, 646.9, 131.0, 656.3, 144.0, 665.2, 157.5, 673.7, 171.5, 681.7,
        185.9, 689.3, 200.8, 696.4, 216.1, 702.9, 231.7, 709.0, 247.8, 714.6, 264.2, 719.7, 281.0, 724.3, 298.1, 728.3,
        315.6, 731.7, 333.3, 734.6, 351.4, 736.9, 369.7, 738.6, 388.3, 739.7, 407.1, 740.2, 426.1, 740.1, 445.4, 739.3,
        464.8, 737.9, 484.4, 735.7, 504.2, 732.9, 524.1, 729.4, 544.1, 725.2, 564.3, 720.2, 584.5, 714.4, 604.7, 707.9,
        625.0, 700.6, 645.3, 692.5, 665.6, 683.6, 685.9, 673.9, 706.1, 663.3, 726.2, 651.8, 746.2, 639.5, 766.1, 626.2,
        785.9, 612.1, 805.5, 597.1, 824.8, 581.1, 844.0, 564.2, 862.8, 546.3, 881.4, 527.5, 899.7, 507.7, 917.7, 486.9,
        935.3, 465.1, 800.7, 374.9, 789.4, 394.7, 777.7, 413.8, 765.7, 432.2, 753.3, 449.7, 740.5, 466.6, 727.4, 482.7,
        714.0, 498.2, 700.2, 512.9, 686.2, 526.9, 671.9, 540.2, 657.3, 552.9, 642.5, 564.9, 627.5, 576.2, 612.3, 586.8,
        596.8, 596.7, 581.2, 606.0, 565.4, 614.7, 549.5, 622.7, 533.5, 630.0, 517.3, 636.7, 501.1, 642.8, 484.8, 648.2,
        468.5, 653.0, 452.2, 657.1, 435.8, 660.7, 419.5, 663.6, 403.3, 665.9, 387.1, 667.6, 371.0, 668.6, 355.0, 669.1,
        339.2, 669.0, 323.5, 668.3, 308.1, 667.0, 292.8, 665.1, 277.8, 662.7, 263.1, 659.7, 248.6, 656.2, 234.5, 652.1,
        220.7, 647.5, 207.3, 642.4, 194.3, 636.8, 181.7, 630.6, 169.5, 624.0, 157.8, 616.8, 146.6, 609.3, 135.9, 601.2,
        125.8, 592.7, 116.3, 583.7,
    ]
    nonisolated private static let comet = Path { path in
        let points = stride(from: 0, to: edges.count, by: 2).map { CGPoint(x: edges[$0], y: edges[$0 + 1]) }
        path.addLines(Array(points[..<49]))
        path.addRelativeArc(center: CGPoint(x: 868, y: 420), radius: 81, startAngle: .degrees(33.8), delta: .degrees(-180))
        points[49...].forEach { path.addLine(to: $0) }
        path.addRelativeArc(center: CGPoint(x: 100, y: 600), radius: 23, startAngle: .degrees(-45), delta: .degrees(-180))
        path.closeSubpath()
    }
    /// the left leg and its foot, as comet-behind.svg clips them
    nonisolated private static let leftLeg = Path { path in
        path.addLines([CGPoint(x: 195.3, y: 726.5), CGPoint(x: 439.2, y: 226.5), CGPoint(x: 584.8, y: 297.5), CGPoint(x: 340.9, y: 797.5)])
        path.closeSubpath()
    }
    .union(Path(ellipseIn: CGRect(x: 268.1 - 81, y: 762 - 81, width: 162, height: 162)))
    /// a.svg
    nonisolated private static let wholeA = Path { path in
        path.addLines([CGPoint(x: 268.1, y: 762), CGPoint(x: 512, y: 262), CGPoint(x: 755.9, y: 762)])
    }
    .strokedPath(StrokeStyle(lineWidth: 162, lineCap: .round, lineJoin: .round))

    func path(in rect: CGRect) -> Path {
        let moved = Self.comet.applying(trail)
        let front = sweep < 1 ? moved.subtracting(Self.leftLeg).intersection(Self.wedge(sweep)) : moved.subtracting(Self.leftLeg)
        let part =
            isComet ? front
            // front first: the other order can return all of front
            : crossing ? front.intersection(Self.wholeA)
            : Self.wholeA.subtracting(gap > 0 ? moved.strokedPath(StrokeStyle(lineWidth: 2 * gap)).union(moved).subtracting(Self.leftLeg) : front)
        let side = min(rect.width, rect.height)
        return part.applying(
            CGAffineTransform(translationX: -512, y: -512).concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(scaleX: side / 1024, y: side / 1024))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }

    /// the slice of the icon round the orbit's centre that a `sweep` of the comet covers
    nonisolated private static func wedge(_ sweep: Double) -> Path {
        guard sweep > 0 else { return Path() }
        let (from, to) = sweepAngles, centre = orbit.centre
        return Path { path in
            path.move(to: centre)
            for k in 0...32 {
                let angle = from + (to - from) * sweep * Double(k) / 32
                path.addLine(to: CGPoint(x: centre.x + 2400 * cos(angle), y: centre.y + 2400 * sin(angle)))
            }
            path.closeSubpath()
        }
    }
}
