// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// how a tooltip is anchored and shaped
enum TooltipStyle {
    /// attached to the cursor: top-left corner sharpened, the bubble's top-left
    /// sitting just below-right of the pointer, and following it. the default.
    case cursor
    /// an even pill centred above the control
    case centered
}

/// one window's tooltip. over that window the bubble draws in `TooltipLayer`;
/// anywhere else (a popover, a sheet) it moves to a panel above every window
@Observable
final class TooltipState {
    struct Active: Equatable, Identifiable {
        let id: UUID
        var text: String
        /// keycap glyphs for the control's shortcut, e.g. ["⌘", "S"] — rendered as
        /// space-tinted caps after the label. empty = no shortcut shown
        var keys: [String]
        /// the hovered control's frame in global (window) space — used by `.centered`
        var anchor: CGRect
        /// the live cursor in global space — used by `.cursor`, which tracks it
        var cursor: CGPoint
        var style: TooltipStyle
    }

    /// the tooltip currently shown, or nil
    var active: Active? {
        didSet {
            if active?.id != oldValue?.id { inline = active != nil && pointerIsOverWindow }
            present()
        }
    }

    /// the space accent the keycaps are tinted with, kept current by the window
    var accent: Color = .white {
        didSet { present() }
    }

    /// white frost and dark text, for when the chrome around it has gone light
    var light = false {
        didSet { if light != oldValue { present() } }
    }

    /// the window `TooltipLayer` draws in; nil leaves every bubble to the panel
    @ObservationIgnored weak var window: NSWindow?

    @ObservationIgnored private static let all = NSHashTable<TooltipState>.weakObjects()
    init() { Self.all.add(self) }

    /// for a control the environment doesn't reach (a popover is a window of its
    /// own and often doesn't inherit it; Settings has none): the main window's
    /// state, else any, since off-window bubbles draw in the panel either way
    static var fallback: TooltipState? {
        let states = all.allObjects
        return states.first { $0.window != nil && $0.window === NSApp.mainWindow } ?? states.first
    }
    /// whether `active` draws inside `window` rather than in the panel
    private(set) var inline = false

    private let presenter = TooltipPresenter()

    private func present() {
        presenter.update(inline ? nil : active, accent: accent, light: light)
    }

    /// popovers and sheets are windows of their own, so a control in one misses this
    private var pointerIsOverWindow: Bool {
        guard let window, window.isVisible else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            == window.windowNumber
    }

    /// once a tooltip has shown, neighbouring controls skip the dwell and appear
    /// instantly until the cursor sits in dead space for this long
    private(set) var warm = false
    private var cooldown: Task<Void, Never>?
    private var clear: Task<Void, Never>?
    private static let warmGraceMS = 1200
    /// grace after leaving a control before its bubble clears, so moving straight
    /// onto a neighbour swaps the bubble in place rather than fading it out and in
    private static let clearGraceMS = 70

    /// show a tooltip and (re)enter the warm period
    func show(_ a: Active) {
        clear?.cancel()
        clear = nil
        active = a
        warm = true
        cooldown?.cancel()
        cooldown = nil
    }

    /// clears at once, for a control whose view is going away: `hide` debounces
    /// on a task, and a task owned by a closing window may never run
    func hideNow(id: UUID) {
        guard active?.id == id else { return }
        clear?.cancel()
        clear = nil
        active = nil
    }

    /// clear the tooltip if `id` still owns it, and start the warm cooldown, so a
    /// jump to the next control within the grace window shows instantly
    func hide(id: UUID) {
        guard active?.id == id else { return }
        // debounce the clear: a show() from a neighbour lands first and cancels it,
        // so active goes straight A→B with no nil flicker (hence no cross-fade)
        clear?.cancel()
        clear = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.clearGraceMS))
            guard !Task.isCancelled else { return }
            self?.active = nil
        }
        cooldown?.cancel()
        cooldown = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.warmGraceMS))
            guard !Task.isCancelled else { return }
            self?.warm = false
        }
    }
}

extension View {
    /// show a styled tooltip after a brief hover. `style` picks cursor-attached
    /// (default) or a pill centred above the control. `keys` are keycap glyphs for
    /// the control's shortcut (e.g. ["⌘", "S"]) shown as space-tinted caps.
    func tooltip(_ text: String, keys: [String] = [], style: TooltipStyle = .cursor) -> some View {
        modifier(TooltipModifier(text: text, keys: keys, style: style))
    }
}

private struct TooltipModifier: ViewModifier {
    @Environment(TooltipState.self) private var environmentState: TooltipState?
    private var state: TooltipState? { environmentState ?? TooltipState.fallback }
    let text: String
    let keys: [String]
    let style: TooltipStyle

    /// identifies this control as the owner of the shown tooltip, so leaving it
    /// only clears the bubble if it's still ours (not a neighbour's that took over)
    @State private var id = UUID()
    /// written whenever the control moves or the pointer does, read only when a
    /// bubble is summoned: a reference box, so the writes don't re-run the body
    @State private var place = AnchorBox()
    @State private var hovering = false
    @State private var showTask: Task<Void, Never>?

    /// dwell before the tooltip appears
    private static let delayMS = 1500

    @ViewBuilder
    func body(content: Content) -> some View {
        // the tooltip's words are also the control's accessibility label
        labelled(decorated(content))
    }

    private func labelled(_ view: some View) -> some View {
        view
            .accessibilityLabel(text)
            .accessibilityHint(keys.isEmpty ? "" : keys.joined(separator: " "))
    }

    @ViewBuilder
    private func decorated(_ content: Content) -> some View {
        if let state {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { place.frame = $0 }
                .onContinuousHover(coordinateSpace: .global) { phase in
                    switch phase {
                    case .active(let loc):
                        place.cursor = loc
                        // a shown bubble rides the pointer rather than staying
                        // where it was first summoned
                        if state.active?.id == id { state.active?.cursor = loc }
                        guard !hovering else { return }
                        hovering = true
                        showTask?.cancel()
                        // warm → appear instantly; cold → wait out the dwell
                        if state.warm {
                            state.show(
                                .init(id: id, text: text, keys: keys, anchor: place.frame, cursor: place.cursor, style: style))
                        } else {
                            showTask = Task {
                                try? await Task.sleep(for: .milliseconds(Self.delayMS))
                                guard !Task.isCancelled else { return }
                                state.show(
                                    .init(
                                        id: id, text: text, keys: keys, anchor: place.frame, cursor: place.cursor, style: style)
                                )
                            }
                        }
                    case .ended:
                        hovering = false
                        showTask?.cancel()
                        state.hide(id: id)
                    }
                }
                .onDisappear {
                    showTask?.cancel()
                    state.hideNow(id: id)
                }
                // a control whose label changes (e.g. Copy → Copied!) refreshes the
                // live bubble in place
                .onChange(of: text) { _, new in
                    if state.active?.id == id { state.active?.text = new }
                }
        } else {
            content.help(text)
        }
    }
}

private final class AnchorBox {
    var frame: CGRect = .zero
    var cursor: CGPoint = .zero
}

/// the bubble itself, at its natural size plus room for its shadow in the panel;
/// `TooltipPresenter` or `TooltipLayer` owns where it goes
private struct TooltipBubble: View {
    let active: TooltipState.Active
    /// the current space's accent, tinting the shortcut keycaps to match the theme
    var accent: Color = .white
    /// the pointer sits to the bubble's right, so the sharp corner swaps sides
    var flipped = false
    /// drawn inside its window's own layer rather than the floating panel
    var inline = false
    /// white frost and dark text instead of dark frost and white text
    var light = false
    @State private var size: CGSize = .zero
    /// watches the keyboard so a keycap flattens while its real key is held
    @State private var press = KeycapPressTracker()

    /// room around the bubble for its shadow, and the panel's inset to its corner
    static let shadowPad: CGFloat = 14

    var body: some View {
        bubble(flipped: flipped)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .padding(inline ? 0 : Self.shadowPad)
            .allowsHitTesting(false)
            .onAppear { press.start(keys: active.keys) }
            .onChange(of: active.keys) { _, keys in press.update(keys) }
            .onDisappear { press.stop() }
    }

    private func bubble(flipped: Bool) -> some View {
        let shape = shape(flipped: flipped)
        return HStack(spacing: 7) {
            Text(active.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(light ? SpaceAppearance.darkInk : .white)
                .lineLimit(1)
                .fixedSize()
            if !active.keys.isEmpty {
                HStack(spacing: 3) {
                    ForEach(active.keys, id: \.self, content: keycap)
                }
            }
        }
        .padding(.leading, 11)
        // tighter on the trailing edge when keycaps sit there — they carry their
        // own visual padding, so equal text-padding would read as a gap
        .padding(.trailing, active.keys.isEmpty ? 11 : 6)
        .padding(.vertical, active.keys.isEmpty ? 6.5 : 5)
        // AppKit's blur, since SwiftUI's material can't see through the panel's window
        .background {
            VisualEffectView(material: .fullScreenUI, blending: inline ? .withinWindow : .behindWindow)
                .environment(\.colorScheme, light ? .light : .dark)
                .clipShape(shape)
        }
        // frosted acrylic: light catches the top edge and fades by the middle
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [.white.opacity(light ? 0.9 : 0.45), .white.opacity(0)],
                    startPoint: .top, endPoint: .center),
                lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 7, y: 2)
    }

    /// a soft, light tint of the space accent for the keycap face
    private var capFill: Color { accent.tuned(brightness: 0.05, saturation: 0.45) }
    /// a darker accent for the keycap outline + its 3D bottom lip
    private var capEdge: Color { accent.tuned(brightness: -0.45, saturation: 1.0) }

    /// one shortcut keycap in a 19pt slot: a face at least 17×15.5pt over a darker
    /// base showing as a 1pt rim and a 2.5pt bottom lip. while its key is held the
    /// lip shrinks to 1pt and the cap sinks to the slot's bottom
    private func keycap(_ key: String) -> some View {
        let down = press.pressed.contains(key)
        let bottomLip: CGFloat = down ? 1 : 2.5
        // brackets render large in SF — shrink them a touch and nudge left 0.5pt
        let bracket = key == "[" || key == "]"
        let face = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let outer = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Text(key)
            .font(.system(size: bracket ? 10.5 : 12, weight: .semibold))
            .foregroundStyle(capEdge)
            .offset(x: bracket ? -0.5 : 0)
            .padding(.horizontal, 3)  // breathing room so wider glyphs don't touch
            .frame(minWidth: 17, minHeight: 15.5, maxHeight: 15.5)
            .background(face.fill(capFill))
            // darker base peeks through these insets: 1pt top + sides, the bottom lip
            .padding(EdgeInsets(top: 1, leading: 1, bottom: bottomLip, trailing: 1))
            .background(outer.fill(capEdge))
            // cap is 19pt (rest) / 17.5pt (pressed) tall; pin it bottom of a 19pt slot
            // so the press drops the whole key rather than thickening the top edge
            .frame(height: 19, alignment: .bottom)
            .opacity(0.9)
            .animation(Motion.pop, value: down)
    }

    /// a `.cursor` bubble sharpens the top corner nearest the pointer, its others
    /// rounded to half the measured height: `UnevenRoundedRectangle` would otherwise
    /// curve the whole edge. a `.centered` bubble is a plain capsule
    private func shape(flipped: Bool) -> AnyShape {
        switch active.style {
        case .cursor:
            let r = size.height / 2
            return AnyShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: flipped ? r : 2, bottomLeadingRadius: r,
                    bottomTrailingRadius: r, topTrailingRadius: flipped ? 2 : r,
                    style: .continuous))
        case .centered:
            return AnyShape(Capsule(style: .continuous))
        }
    }
}

/// draws the bubble inside its window while the pointer is over it
struct TooltipLayer: View {
    @Environment(TooltipState.self) private var state
    @State private var bubbleWidth: CGFloat = 0
    @State private var layerWidth: CGFloat = 0

    var body: some View {
        ZStack {
            if state.inline, let active = state.active {
                let flipped = TooltipPresenter.flips(
                    active, width: bubbleWidth, cursorX: active.cursor.x, maxX: layerWidth)
                TooltipPlacement(active: active, flipped: flipped) {
                    TooltipBubble(
                        active: active, accent: state.accent, flipped: flipped, inline: true,
                        light: state.light)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { bubbleWidth = $0 }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { layerWidth = $0 }
        .allowsHitTesting(false)
    }
}

/// places the bubble from the pointer in the layer's space, which must be the
/// window's global space — the space the control reported its cursor and anchor in
private struct TooltipPlacement: Layout {
    var active: TooltipState.Active
    var flipped: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(.unspecified)
        let offset = TooltipPresenter.offset(
            active, width: size.width, height: size.height, flipped: flipped)
        let margin = TooltipPresenter.margin
        let x = TooltipPresenter.clamp(
            active.cursor.x + offset.width, bounds.minX + margin, bounds.maxX - margin - size.width)
        let y = TooltipPresenter.clamp(
            active.cursor.y + offset.height, bounds.minY + margin, bounds.maxY - margin - size.height)
        bubble.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
    }
}

/// puts the bubble in a borderless panel above every window, placed from the
/// pointer's own screen position — which is what lets it follow the cursor out
/// over a popover, a sheet, or the page.
@MainActor
private final class TooltipPresenter {
    /// `nonisolated(unsafe)` only so `deinit` can reach it: a presenter dies
    /// with the window whose state owned it, and a panel left on screen then has
    /// nothing left alive to take it down
    nonisolated(unsafe) private var panel: NSPanel?

    deinit {
        if let watch { NotificationCenter.default.removeObserver(watch) }
        panel?.orderOut(nil)
    }

    /// a window closing is the general case of "the control I was over has gone",
    /// and the one the per-control teardown can miss
    private var watch: (any NSObjectProtocol)?
    /// one hosting view for the life of the panel: the bubble follows the pointer,
    /// so this is re-rooted on every move, and a fresh view each time would restart
    /// the keycap tracker as fast as the mouse reports
    private var host: NSHostingView<TooltipBubble>?

    /// gap above a `.centered` bubble's control
    private nonisolated static let gap: CGFloat = 6
    nonisolated static let margin: CGFloat = 6
    /// how far past the cursor's top-left the bubble's top-left sits
    private nonisolated static let cursorOffset: CGFloat = 10
    /// when flipped to the cursor's left, sit this much closer to the pointer
    private nonisolated static let flippedNudge: CGFloat = 5

    func update(_ active: TooltipState.Active?, accent: Color, light: Bool) {
        guard let active else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero

        // measure unflipped, then decide — the flip depends on the width
        var size = self.size(of: active, accent: accent, light: light, flipped: false, in: panel)
        let flipped = Self.flips(active, width: size.width, cursorX: mouse.x, maxX: screen.maxX)
        if flipped {
            size = self.size(of: active, accent: accent, light: light, flipped: true, in: panel)
        }

        panel.setFrameOrigin(
            origin(active, mouse: mouse, size: size, flipped: flipped, screen: screen))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    /// the bubble's own offset from the pointer, applied to the pointer's screen
    /// position — the anchor and cursor share a coordinate space, so a `.centered`
    /// bubble needs no window conversion either
    private func origin(
        _ active: TooltipState.Active, mouse: NSPoint, size: CGSize, flipped: Bool, screen: CGRect
    ) -> NSPoint {
        let pad = TooltipBubble.shadowPad
        let w = size.width - pad * 2, h = size.height - pad * 2
        let offset = Self.offset(active, width: w, height: h, flipped: flipped)
        // the panel's origin is its bottom-left and the pad sits outside the bubble,
        // so every bound is the bubble's, shifted out by the pad
        let x = mouse.x + offset.width - pad
        let y = mouse.y - offset.height - h - pad
        return NSPoint(
            x: Self.clamp(x, screen.minX + Self.margin - pad, screen.maxX - Self.margin - w - pad),
            y: Self.clamp(y, screen.minY + Self.margin - pad, screen.maxY - Self.margin - h - pad))
    }

    /// the bubble's top-left relative to the pointer, y down
    nonisolated static func offset(
        _ active: TooltipState.Active, width w: CGFloat, height h: CGFloat, flipped: Bool
    ) -> CGSize {
        switch active.style {
        case .cursor:
            CGSize(
                width: flipped ? -cursorOffset - w + flippedNudge : cursorOffset,
                height: cursorOffset)
        case .centered:
            CGSize(
                width: active.anchor.midX - w / 2 - active.cursor.x,
                height: active.anchor.minY - gap - h - active.cursor.y)
        }
    }

    /// a `.cursor` bubble flips to the pointer's left when it would cross `maxX`
    nonisolated static func flips(
        _ active: TooltipState.Active, width: CGFloat, cursorX: CGFloat, maxX: CGFloat
    ) -> Bool {
        guard case .cursor = active.style else { return false }
        return cursorX + cursorOffset + width + margin > maxX
    }

    nonisolated static func clamp(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(v, low), max(low, high))
    }

    /// what a cached measurement was taken for
    private struct BubbleKey: Equatable {
        var text: String
        var keys: [String]
        var accent: Color
        var light: Bool
        var flipped: Bool
    }
    private var measuredKey: BubbleKey?
    private var measuredSize: CGSize = .zero

    /// the bubble's size, measured once per distinct bubble: a `.cursor` tooltip
    /// rewrites `active` on every mouse move, changing only the cursor
    private func size(
        of active: TooltipState.Active, accent: Color, light: Bool, flipped: Bool, in panel: NSPanel
    ) -> CGSize {
        let key = BubbleKey(
            text: active.text, keys: active.keys, accent: accent, light: light, flipped: flipped)
        guard key != measuredKey else { return measuredSize }
        measuredSize = fit(
            TooltipBubble(active: active, accent: accent, flipped: flipped, light: light), in: panel)
        measuredKey = key
        return measuredSize
    }

    /// re-root the bubble and size the panel to it
    private func fit(_ bubble: TooltipBubble, in panel: NSPanel) -> CGSize {
        let view: NSHostingView<TooltipBubble>
        if let host {
            host.rootView = bubble
            view = host
        } else {
            view = NSHostingView(rootView: bubble)
            host = view
            panel.contentView = view
        }
        view.layout()
        let size = view.fittingSize
        view.frame = CGRect(origin: .zero, size: size)
        panel.setContentSize(size)
        return size
    }

    private func makePanel() -> NSPanel {
        watch = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
        }
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the bubble draws its own
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu  // above popovers
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        return panel
    }
}

/// which of a shown tooltip's keycaps are held. modifier caps follow the live
/// flags; other caps release on their own shortly after key-down, since macOS
/// drops key-up events while ⌘ is held
@MainActor
@Observable
private final class KeycapPressTracker {
    /// the keycaps currently shown as pressed
    private(set) var pressed: Set<String> = []

    private var keys: [String] = []
    private var monitor: Any?
    private var releases: [String: Task<Void, Never>] = [:]

    /// glyph → modifier flag, for the caps that track held state continuously
    private static let mods: [(String, NSEvent.ModifierFlags)] = [
        ("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control),
    ]
    private static let modGlyphs = Set(mods.map(\.0))

    func start(keys: [String]) {
        self.keys = keys
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .keyUp]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
        syncModifiers(NSEvent.modifierFlags)
    }

    /// the shown tooltip changed — adopt its keys, drop stale presses, reseed mods
    func update(_ keys: [String]) {
        self.keys = keys
        pressed = pressed.intersection(Set(keys))
        syncModifiers(NSEvent.modifierFlags)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        releases.values.forEach { $0.cancel() }
        releases.removeAll()
        pressed = []
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            syncModifiers(event.modifierFlags)
        case .keyDown:
            if let cap = match(event) { pressDown(cap) }
        case .keyUp:
            if let cap = match(event) { liftUp(cap) }
        default:
            break
        }
    }

    private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        var next = pressed
        for (glyph, flag) in Self.mods where keys.contains(glyph) {
            if flags.contains(flag) { next.insert(glyph) } else { next.remove(glyph) }
        }
        if next != pressed { pressed = next }
    }

    /// the non-modifier keycap this event hits, if any
    private func match(_ event: NSEvent) -> String? {
        for cap in keys where !Self.modGlyphs.contains(cap) {
            if cap == "esc" {
                if event.keyCode == 53 { return cap }
            } else if let chars = event.charactersIgnoringModifiers,
                chars.compare(cap, options: .caseInsensitive) == .orderedSame
            {
                return cap
            }
        }
        return nil
    }

    private func pressDown(_ cap: String) {
        pressed.insert(cap)
        releases[cap]?.cancel()
        // safety release: key-up rarely arrives while ⌘ is held, so pop back up
        releases[cap] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }
            self?.pressed.remove(cap)
        }
    }

    private func liftUp(_ cap: String) {
        releases[cap]?.cancel()
        releases[cap] = nil
        pressed.remove(cap)
    }
}

private extension Color {
    /// this colour shifted in HSB: `brightness` is added (toward white or black),
    /// `saturation` scales the existing saturation
    func tuned(brightness db: Double, saturation ss: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(
            hue: Double(h),
            saturation: min(max(Double(s) * ss, 0), 1),
            brightness: min(max(Double(b) + db, 0), 1))
    }
}
