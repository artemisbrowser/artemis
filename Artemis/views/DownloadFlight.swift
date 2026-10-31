import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A new download's file icon arcs from the click that started it to the
/// window's Library button (or download pill), drawn in Core Animation on a
/// throwaway layer so SwiftUI lays nothing out during the flight.
enum DownloadFlight {
    /// views marking where downloads land; the one in the download's window is the target
    fileprivate static let targets = NSHashTable<NSView>.weakObjects()

    static func launch(filename: String, from webView: NSView?) {
        guard !Motion.reduceMotion, let webView, let window = webView.window,
            let content = window.contentView,
            let target = targets.allObjects.first(where: { $0.window === window && !$0.isHiddenOrHasHiddenAncestor })
        else { return }
        let end = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let press = (webView as? ArtemisWebView)?.lastPress
        let start = press.flatMap { Date.now.timeIntervalSince($0.at) < 2 ? $0.point : nil }
            ?? webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)

        let overlay = PassthroughView(frame: content.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)

        let icon = CALayer()
        let ext = (filename as NSString).pathExtension
        icon.contents = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        icon.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        icon.contentsScale = window.backingScaleFactor
        let a = overlay.convert(start, from: nil), b = overlay.convert(end, from: nil)
        icon.position = b
        icon.opacity = 0
        overlay.layer?.addSublayer(icon)

        // a bow above both ends, wherever they sit
        let arc = CGMutablePath()
        arc.move(to: a)
        arc.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + 120))
        let path = CAKeyframeAnimation(keyPath: "position")
        path.path = arc
        path.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.4
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.8, 1]
        let flight = CAAnimationGroup()
        flight.animations = [path, scale, fade]
        flight.duration = 0.55

        CATransaction.begin()
        CATransaction.setCompletionBlock { overlay.removeFromSuperview() }
        icon.add(flight, forKey: "flight")
        CATransaction.commit()
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// marks where downloads land; place it as the background of the landing control
struct DownloadLanding: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DownloadFlight.targets.add(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
