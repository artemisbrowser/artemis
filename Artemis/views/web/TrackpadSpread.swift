// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// two fingers' spread on the trackpad, read from the private MultitouchSupport framework:
/// macOS sends a pinch only to the active app, and the mini-player never makes Artemis active
enum TrackpadSpread {
    private struct Point { var x: Float; var y: Float }
    private struct Vector { var position: Point; var velocity: Point }
    /// MultitouchSupport's MTTouch, unchanged since 10.5
    private struct Touch {
        var frame: Int32; var timestamp: Double; var identifier: Int32; var state: Int32
        var fingerID: Int32; var handID: Int32; var normalized: Vector; var size: Float; var zero1: Int32
        var angle: Float; var majorAxis: Float; var minorAxis: Float; var absolute: Vector
        var zero2: Int32; var zero3: Int32; var density: Float
    }
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Each = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Run = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

    private static let symbols: (list: @convention(c) () -> Unmanaged<CFArray>, register: Each, unregister: Each, start: Run, stop: @convention(c) (UnsafeMutableRawPointer) -> Void)? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
            let list = dlsym(lib, "MTDeviceCreateList"), let register = dlsym(lib, "MTRegisterContactFrameCallback"),
            let unregister = dlsym(lib, "MTUnregisterContactFrameCallback"), let start = dlsym(lib, "MTDeviceStart"),
            let stop = dlsym(lib, "MTDeviceStop")
        else { return nil }
        return (unsafeBitCast(list, to: (@convention(c) () -> Unmanaged<CFArray>).self), unsafeBitCast(register, to: Each.self),
            unsafeBitCast(unregister, to: Each.self), unsafeBitCast(start, to: Run.self),
            unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self))
    }()
    private static var devices: [AnyObject] = []
    private static var handler: ((Double?) -> Void)?
    /// touched only on MultitouchSupport's own thread
    nonisolated(unsafe) private static var hadTwo = false

    /// `handler` gets the normalised distance between two touching fingers each frame, and nil once they part
    static func start(_ handler: @escaping (Double?) -> Void) {
        guard devices.isEmpty, let mt = symbols else { return }
        self.handler = handler
        devices = mt.list().takeRetainedValue() as [AnyObject]
        for device in devices {
            let p = Unmanaged.passUnretained(device).toOpaque()
            mt.register(p, frame)
            mt.start(p, 0)
        }
    }

    static func stop() {
        guard let mt = symbols else { return }
        for device in devices {
            let p = Unmanaged.passUnretained(device).toOpaque()
            mt.unregister(p, frame)
            mt.stop(p)
        }
        devices = []
        handler = nil
    }

    private static let frame: Callback = { _, touches, count, _, _ in
        guard count == 2, let touches else {
            if hadTwo { hadTwo = false; DispatchQueue.main.async { MainActor.assumeIsolated { handler?(nil) } } }
            return 0
        }
        hadTwo = true
        let t = touches.assumingMemoryBound(to: Touch.self)
        let a = t[0].normalized.position, b = t[1].normalized.position
        let spread = Double(hypot(a.x - b.x, a.y - b.y))
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(spread) } }
        return 0
    }
}
