// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the mark's physics, times in seconds on one clock. the A turns `a` rad at `w` rad/s, is pulled `x`, `y` points
/// at `vx`, `vy` and swells to `s` at `vs`; the comet gives against it by `ca` rad, `cx`, `cy` points and `cs` of its size
final class MarkSpin {
    struct Pose {
        var angle = 0.0, scale = 1.0, pull = CGSize.zero
        /// the comet against the A: turned about the middle, moved on screen, and its size
        var turn = 0.0, shift = CGSize.zero, swell = 1.0
    }

    private var a = 0.0, w = 0.0
    private var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
    private var s = 1.0, vs = 0.0
    private var ca = 0.0, cw = 0.0, cx = 0.0, cy = 0.0, cvx = 0.0, cvy = 0.0, cs = 0.0, cvs = 0.0
    /// the point a finger turns it about, and the angle less the finger's
    private var turning: (centre: CGPoint, offset: Double)?
    /// the finger's point that would mean no pull
    private var pulling: CGPoint?
    private var samples: [(time: Double, angle: Double, pull: CGPoint)] = []
    /// the upright a let-go spin coasts onto, braked to arrive at `Self.arrival`; an infinite one coasts until it stops
    private var landing: Double?
    private var last: Double?
    /// set as it's let go off upright, until it first passes upright
    private var clickArmed = false
    private(set) var clicks = 0, ticks = 0, holds = 0
    /// a tick comes on reaching a multiple of 30° a full 30° from `ticked`, at least 25ms after `tickedAt`; an upright
    /// click takes the place of its tick
    private var ticked = 0.0, tickedAt = -Double.infinity

    /// coasting friction: `drag` per second of speed plus a constant `rub`, in rad/s²
    private static let drag = 1.35, rub = 2.0
    /// the speed a coast arrives upright at, which the detent catches with one small overshoot
    private static let arrival = 0.5
    /// the least share of friction a coast brakes on to land
    private static let least = 0.1

    /// starts let go at `pose`: angle in radians, spin in rad/s, pull in points
    init(pose: (angle: Double, speed: Double, pull: CGSize)? = nil) {
        if let pose {
            (a, w, x, y) = (pose.angle, pose.speed, pose.pull.width, pose.pull.height)
            plan()
        }
    }

    var isHeld: Bool { turning != nil || pulling != nil }
    var reduceMotion = false
    private var home: Double { (a / (2 * .pi)).rounded() * 2 * .pi }
    var isAtRest: Bool {
        !isHeld && (reduceMotion || landing == nil && abs(w) <= 0.005 && abs(a - home) <= 0.002 && hypot(x, y) <= 0.05
            && hypot(vx, vy) <= 0.5 && abs(s - 1) + abs(vs) <= 1e-3 && abs(ca) + abs(cw) <= 1e-3
            && hypot(cx, cy) + hypot(cvx, cvy) <= 0.05 && abs(cs) + abs(cvs) <= 1e-3)
    }

    /// a touch `point` from the middle: farther out than 0.24 of `side` it turns the mark, nearer in it drags it
    func grab(_ point: CGPoint, side: CGFloat, at time: Double) {
        let dx = point.x - x, dy = point.y - y
        if hypot(dx, dy) > 0.24 * side {
            turning = (CGPoint(x: x, y: y), a - atan2(dy, dx))
            landing = nil
        } else {
            pulling = CGPoint(x: dx, y: dy)
        }
        samples = [(time, a, CGPoint(x: x, y: y))]
        holds += 1
    }

    func move(to point: CGPoint, at time: Double) {
        if let turning {
            let finger = atan2(point.y - turning.centre.y, point.x - turning.centre.x) + turning.offset
            a = finger + ((a - finger) / (2 * .pi)).rounded() * 2 * .pi
        } else if let pulling {
            (x, y) = (point.x - pulling.x, point.y - pulling.y)
        }
        samples.append((time, a, CGPoint(x: x, y: y)))
        tick(at: time)
    }

    func release(at time: Double) {
        guard isHeld else { return }
        if reduceMotion {
            (a, w, x, y, vx, vy) = (home, 0, 0, 0, 0, 0)
        } else if turning != nil {
            w = max(-40, min(40, velocity(at: time).spin))
            plan()
        } else {
            let toss = velocity(at: time).pull
            let k = min(1, 3000 / max(1, hypot(toss.x, toss.y)))
            (vx, vy) = (toss.x * k, toss.y * k)
        }
        (turning, pulling) = (nil, nil)
        clickArmed = abs(w) > 1 || abs(a - home) > 0.05
    }

    /// one turn on from the nearest upright; 15° at once under Reduce Motion
    func flick(_ direction: Double) {
        if reduceMotion {
            a += direction * .pi / 12
        } else {
            w = direction * 12
            landing = home + direction * 2 * .pi
            clickArmed = true
        }
    }

    /// the distance friction alone coasts a spin of `speed` rad/s before it slows to the arrival speed
    private static func coast(_ speed: Double) -> Double {
        let v = abs(speed)
        guard v > arrival else { return 0 }
        return (v - arrival) / drag - rub / (drag * drag) * log((drag * v + rub) / (drag * arrival + rub))
    }

    /// aims the coast at the upright ahead nearest its natural end, or the next if that one needs over twice
    /// friction. it lands there if 0.35 of friction reaches it, or `least` does and it ends over 0.35 turn past the
    /// upright before; the detent takes any other, at once if it ends that far round, or when friction alone stops it
    private func plan() {
        let direction: Double = w < 0 ? -1 : 1, coast = Self.coast(w), end = a + direction * coast
        var upright = (end / (2 * .pi)).rounded() * 2 * .pi
        if (upright - a) * direction <= 0 || coast > 2 * abs(upright - a) { upright += direction * 2 * .pi }
        let share = coast / abs(upright - a), far = (end - upright) * direction > -1.3 * .pi
        if share >= 0.35 || far && share >= Self.least {
            landing = upright
        } else {
            landing = far ? nil : direction * .infinity
        }
    }

    /// steps to `time` in 1/240s substeps, at most 50ms of them
    func pose(at time: Double) -> Pose {
        var before = (w: w, vx: vx, vy: vy, vs: vs)
        if isHeld {
            let finger = velocity(at: time)
            if turning != nil { w = reduceMotion ? 0 : finger.spin }
            if pulling != nil { (vx, vy) = (finger.pull.x, finger.pull.y) }
        }
        var left = reduceMotion ? 0 : last.map { min(0.05, time - $0) } ?? 0
        while left > 1e-6 {
            let h = min(left, 1.0 / 240)
            if turning == nil { turn(h) }
            if pulling == nil {
                vx -= (200 * x + 15 * vx) * h
                vy -= (200 * y + 15 * vy) * h
                x += vx * h
                y += vy * h
            }
            vs += (400 * ((isHeld ? 1.08 : 1) - s) - 22 * vs) * h
            s += vs * h
            // the comet keeps a share of its speed when the A's changes, and trails the way the A moves
            cw += -0.12 * (w - before.w) + (-80 * (ca + 0.03 * tanh(w / 2)) - 13 * cw) * h
            cvx += -0.07 * (vx - before.vx) + (-300 * (cx + 0.005 * vx) - 28 * cvx) * h
            cvy += -0.07 * (vy - before.vy) + (-300 * (cy + 0.005 * vy) - 28 * cvy) * h
            cvs += -0.2 * (vs - before.vs) + (-250 * cs - 26 * cvs) * h
            ca += cw * h
            cx += cvx * h
            cy += cvy * h
            cs += cvs * h
            before = (w, vx, vy, vs)
            left -= 1.0 / 240
        }
        tick(at: time)
        if isAtRest {
            if !reduceMotion {
                (a, w, x, y, vx, vy, s, vs) = (home, 0, 0, 0, 0, 0, 1, 0)
                (ca, cw, cx, cy, cvx, cvy, cs, cvs) = (0, 0, 0, 0, 0, 0, 0, 0)
            }
            (clickArmed, last) = (false, nil)
        } else {
            last = time
        }
        let shift = hypot(cx, cy), reach = 7 * tanh(shift / 7) / max(shift, 1e-9)
        return Pose(
            angle: a, scale: s, pull: CGSize(width: x, height: y), turn: 0.09 * tanh(ca / 0.09),
            shift: CGSize(width: cx * reach, height: cy * reach), swell: 1 + 0.05 * tanh(cs / 0.05))
    }

    /// a coast brakes onto its upright, where a detent with a pendulum's pull catches it and settles it
    private func turn(_ h: Double) {
        let upright = home, before = a - upright
        if let landing {
            let direction: Double = landing > a ? 1 : -1
            let brake = landing.isInfinite ? 1 : min(2, max(Self.least, Self.coast(w) / abs(landing - a)))
            w -= brake * (Self.drag * w + Self.rub * direction) * h
            a += w * h
            let arrived = (a - landing) * direction >= 0
            guard arrived || w * direction <= 0 else { return }
            self.landing = nil
            if arrived, clickArmed { (clickArmed, clicks, ticked) = (false, clicks + 1, landing) }
            return
        }
        w += (-20 * sin(a) - 5 * w) * h
        a += w * h
        if clickArmed, abs(before) < 1, (a - upright) * before < 0 { (clickArmed, clicks, ticked) = (false, clicks + 1, upright) }
    }

    private func tick(at time: Double) {
        let step = Double.pi / 6, reached = ((a - ticked) / step * (1 + 1e-9)).rounded(.towardZero)
        guard reached != 0 else { return }
        ticked += reached * step
        if time - tickedAt >= 0.025 { (ticks, tickedAt) = (ticks + 1, time) }
    }

    /// the finger's spin and drag over its last 100ms; the 30ms floor keeps a tap's jitter from flinging it
    private func velocity(at time: Double) -> (spin: Double, pull: CGPoint) {
        samples.removeAll { time - $0.time > 0.1 }
        guard let first = samples.first, let last = samples.last else { return (0, .zero) }
        let span = max(0.03, last.time - first.time)
        return ((last.angle - first.angle) / span, CGPoint(x: (last.pull.x - first.pull.x) / span, y: (last.pull.y - first.pull.y) / span))
    }
}


/// the mark at `pose`: the A in glass of the icon's colours, the comet's glass over it, the A's leg read through its frost
struct MarkFace: View {
    let pose: MarkSpin.Pose
    let side: CGFloat
    let icon: AppIconChoice
    let dark: Bool

    var body: some View {
        let tint = icon.markTint(dark: dark), trail = trail
        let a = MarkPart(isComet: false, angle: pose.angle, trail: trail, gap: 0)
        let comet = MarkPart(isComet: true, angle: pose.angle, trail: trail)
        let crossing = MarkPart(isComet: false, angle: pose.angle, trail: trail, crossing: true)
        // not in a GlassEffectContainer, which smears the parts together where they meet
        ZStack {
            crossing.fill(tint.feet.opacity(0.7))
            a.fill(LinearGradient(colors: [tint.top.opacity(0.35), .clear], startPoint: unit(256), endPoint: unit(819)))
                .glassEffect(.regular.tint(tint.feet), in: a)
            Color.clear.glassEffect(.regular.tint(tint.comet), in: comet)
            crossing.fill(tint.feet.opacity(0.45))
        }
        .scaleEffect(pose.scale)
        .offset(pose.pull)
    }

    /// the comet's pose against the A in the icon's 1024-point space, before the A turns
    private var trail: CGAffineTransform {
        guard pose.turn != 0 || pose.shift != .zero || pose.swell != 1 else { return .identity }
        let k = 1024 / side, c = cos(pose.angle), s = sin(pose.angle)
        let dx = (pose.shift.width * c + pose.shift.height * s) * k, dy = (pose.shift.height * c - pose.shift.width * s) * k
        return CGAffineTransform(translationX: -512, y: -512)
            .concatenating(CGAffineTransform(scaleX: pose.swell, y: pose.swell))
            .concatenating(CGAffineTransform(rotationAngle: pose.turn))
            .concatenating(CGAffineTransform(translationX: 512 + dx, y: 512 + dy))
    }

    /// the point on the A's upright axis `y` units down the icon's space, turned with the A
    private func unit(_ y: Double) -> UnitPoint {
        UnitPoint(x: 0.5 - (y - 512) * sin(pose.angle) / 1024, y: 0.5 + (y - 512) * cos(pose.angle) / 1024)
    }
}

extension AppIconChoice {
    /// tints that land on the icon's rendered colours: the A's at its top and feet, and the comet's
    fileprivate func markTint(dark: Bool) -> (top: Color, feet: Color, comet: Color) {
        let (light, base) = glyph
        return dark
            ? (light.mix(with: base, by: 0.37, in: .perceptual), base.mix(with: .black, by: 0.2, in: .perceptual).opacity(0.8), light.opacity(0.7))
            : (base.mix(with: .black, by: 0.125, in: .perceptual), base.opacity(0.82), light.mix(with: base, by: 0.42, in: .perceptual).opacity(0.7))
    }
}
