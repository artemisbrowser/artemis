import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// a new download's file icon arcs from the click that started it to the window's
/// Library button or download pill, drawn on the window's frame view, above the
/// content view whose page and sidebar hosts would otherwise cover it
enum DownloadFlight {
    /// views marking where downloads land; the one in the download's window is the target
    fileprivate static let targets = NSHashTable<NSView>.weakObjects()

    static func launch(filename: String, from webView: NSView?) {
        // a beat, so the pill the download just put on the shelf is on screen to land on
        let press = (webView as? ArtemisWebView)?.lastPress
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            fly(filename: filename, from: webView, press: press)
        }
    }

    private static func fly(filename: String, from webView: NSView?, press: (point: NSPoint, at: Date)?) {
        guard !Motion.reduceMotion, let window = webView?.window ?? NSApp.keyWindow,
            let content = window.contentView, let frameView = content.superview
        else { return }
        // a hidden sidebar's Library button still sits in the window, off its edge
        let target = targets.allObjects.first { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor
                && content.bounds.insetBy(dx: 4, dy: 4).contains(view.convert(view.bounds, to: content).center)
        }
        // nothing to land on: the window's bottom-left, where the pill appears
        let end = target.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
            ?? content.convert(NSPoint(x: content.bounds.minX + 40, y: content.isFlipped ? content.bounds.maxY - 26 : 26), to: nil)
        // a tab still on the start page has no page in the window: fly from the window's middle
        let page = webView.flatMap { $0.window === window ? $0 : nil } ?? content
        let start = press.flatMap { Date.now.timeIntervalSince($0.at) < 2 ? $0.point : nil }
            ?? page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)

        let overlay = PassthroughView(frame: frameView.bounds)
        overlay.wantsLayer = true
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)

        let icon = CALayer()
        let ext = (filename as NSString).pathExtension
        icon.contents = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        icon.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
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
        flight.duration = 0.7

        CATransaction.begin()
        CATransaction.setCompletionBlock { overlay.removeFromSuperview() }
        icon.add(flight, forKey: "flight")
        CATransaction.commit()
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
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
