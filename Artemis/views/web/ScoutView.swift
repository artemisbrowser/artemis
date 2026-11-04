// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import Combine
import SwiftUI
import WebKit

/// how the Scout frame paints itself
enum ScoutBarStyle: String, CaseIterable, Identifiable {
    /// a fixed solid colour the user picks
    case solid
    /// a fixed gradient the user designs (reuses the space mesh editor)
    case gradient
    /// translucent liquid glass, sampling the desktop behind the window
    case glass
    /// samples the open page's colours and tracks them as you scroll
    case dynamic
    /// the colours of the space "Open in" targets
    case space

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        case .glass: return "Glass"
        case .dynamic: return "Dynamic"
        case .space: return "Space"
        }
    }

    static let storageKey = "scoutBarStyle"
    static let fallback = ScoutBarStyle.glass
}

/// the user's custom Scout-bar look (a `SpaceAppearance`, reusing the space
/// theme model) persisted as JSON in `@AppStorage`
private enum ScoutBarAppearanceStore {
    static let key = "scoutBarAppearance"

    /// a pleasant gradient out of the box
    static var fallback: SpaceAppearance { SpacePreset.all[0].appearance }

    static func load(_ json: String) -> SpaceAppearance {
        guard let data = json.data(using: .utf8),
            let appearance = try? JSONDecoder().decode(SpaceAppearance.self, from: data)
        else { return fallback }
        return appearance
    }

    static func encode(_ appearance: SpaceAppearance) -> String {
        guard let data = try? JSONEncoder().encode(appearance) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Scout: the small window a link opened from another app lands in, until "Open
/// in …" promotes it to a tab. it drives its own `TabManager` over a private
/// space, so browser commands act on its page, not the main window's
struct ScoutView: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.colorScheme) private var scheme
    @AppStorage(ScoutBarStyle.storageKey) private var barStyleRaw = ScoutBarStyle.fallback.rawValue
    @AppStorage(ScoutBarAppearanceStore.key) private var customAppearanceJSON = ""
    @AppStorage(WindowChrome.edgeInsetKey) private var edgeInset = WindowChrome.defaultEdgeInset
    /// closes the owning `NSWindow`, which SwiftUI's `dismiss` doesn't reach
    let onClose: () -> Void

    /// the one page this window holds
    private var tab: BrowserTab? { tabManager.selectedTab }
    /// the space "Open in …" targets: the url's preferred space among those in
    /// this page's profile, until the user picks one
    @State private var targetSpace: Space?
    @State private var pickedManually = false
    @State private var showSpaceMenu = false
    /// true while a promote waits for its browser window; presses meanwhile do nothing
    @State private var isPromoting = false
    /// colours sampled left→right across the live page's top edge
    @State private var sampledStops: [Color]?
    @State private var lastScrollY: Double = -1
    @State private var isSampling = false
    private static let stopCount = 12

    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    /// the browser window a promoted page lands in
    private var browser: TabManager? { BrowserWindows.shared.browserScope }

    /// falls back to the browser's current space, else the one a new browser window opens on;
    /// never this window's own space, which no browser window holds
    private var target: Space {
        targetSpace ?? browser?.currentSpace
            ?? tabManager.spaces.first { $0.id == tabManager.core.persistedSpaceID } ?? tabManager.spaces[0]
    }

    private var barStyle: ScoutBarStyle { ScoutBarStyle(rawValue: barStyleRaw) ?? .fallback }
    private var rim: CGFloat { CGFloat(edgeInset) }
    /// the main window's toolbar gap: the page keeps its rim but never touches the row
    private var toolbarGap: CGFloat { max(rim, BrowserToolbar.top) }

    private var customAppearance: SpaceAppearance { ScoutBarAppearanceStore.load(customAppearanceJSON) }

    /// the adaptive colours sampled left→right, falling back to the declared
    /// theme-color, else nil (no sample yet)
    private var adaptiveColors: [Color]? {
        if let sampledStops, !sampledStops.isEmpty { return sampledStops }
        if let tint = tab?.pageTint { return [tint] }
        return nil
    }

    /// how to paint the frame this frame
    private var barPaint: ScoutBarPaint {
        switch barStyle {
        case .glass: return .glass
        case .dynamic: return adaptiveColors.map(ScoutBarPaint.sampled) ?? .glass
        case .space: return target.appearance.fill == .glass ? .glass : .appearance(target.appearance)
        case .solid:
            var a = customAppearance
            a.fill = .solid
            return .appearance(a)
        case .gradient:
            var a = customAppearance
            a.fill = .gradient
            return .appearance(a)
        }
    }

    /// contrasting ink for the toolbar controls
    private var ink: Color {
        switch barPaint {
        case .glass: return scheme == .dark ? .white : SpaceAppearance.darkInk
        case .sampled(let colors):
            return colors.isEmpty || Color.average(of: colors).isDark ? .white : SpaceAppearance.darkInk
        case .appearance(let appearance): return appearance.chromeInk
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, BrowserToolbar.top)
                .padding(.bottom, toolbarGap)
            card
                .padding([.horizontal, .bottom], rim)
        }
        .background { ScoutBackdrop(paint: barPaint).ignoresSafeArea() }
        .environment(\.chromeInk, ink)
        .frame(minWidth: 480, minHeight: 360)
        // the toolbar row sits inline with the traffic lights
        .ignoresSafeArea(.container, edges: .top)
        .background(
            Button("", action: { promote(into: target) })
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .onAppear {
            if targetSpace == nil, let url = tab?.url ?? tab?.lastAttemptedURL {
                targetSpace = (browser ?? BrowserWindows.shared.seed)?.preferredSpace(for: url, in: tabManager.currentSpace.profileID)
            }
        }
        .onChange(of: tab?.url) { _, newURL in
            guard let newURL else { return }
            if !pickedManually {
                targetSpace = (browser ?? BrowserWindows.shared.seed)?.preferredSpace(for: newURL, in: tabManager.currentSpace.profileID)
            }
            scheduleSample()
        }
        .onChange(of: tab?.isLoading) { _, loading in
            if loading == false { scheduleSample() }
        }
        .onChange(of: barStyleRaw) { scheduleSample() }
        .onReceive(ticker) { _ in pollScroll() }
        .onChange(of: target.appearance.accent, initial: true) { _, accent in
            tabManager.tooltipState.accent = accent
        }
    }

    /// the page, as a card on the frame with the main window's rim and rounding
    private var card: some View {
        ZStack {
            // the space's own base, so a loading page never flashes the wrong colour
            target.appearance.cardBase
            if let tab {
                WebViewContainer(tab: tab)
                    .id("\(tab.id)#\(tab.webViewGeneration)")
                    .opacity(tab.loadError == nil ? 1 : 0)
                    .pageDialog(for: tab)
                    .translateSelection(for: tab)
                if tab.loadError != nil { ErrorPage(tab: tab) }
            }
        }
        // find in page, and the permission prompts a real page can raise
        .overlay(alignment: .top) {
            if tabManager.isFindBarVisible, let tab {
                FindBar(tab: tab)
            }
        }
        .animation(Motion.fade, value: tabManager.isFindBarVisible)
        .overlay(alignment: .top) {
            if let request = tabManager.currentPermissionRequest {
                PermissionPrompt(request: request)
            }
        }
        .environment(\.chromeInk, target.appearance.cardInk)
        .clipShape(RoundedRectangle(cornerRadius: WindowChrome.cardRadius(inset: rim), style: .continuous))
        // flush to the frame the toolbar needs a seam, raised the card casts one
        .overlay(alignment: .top) {
            if rim == 0 { Rectangle().fill(ink.opacity(0.12)).frame(height: 1) }
        }
        .shadow(color: .black.opacity(rim > 0 ? 0.3 : 0), radius: 12, y: 3)
    }

    /// snapshots only when the scroll offset moved since the last tick
    private func pollScroll() {
        guard barStyle == .dynamic, let webView = tab?.webView, webView.window != nil
        else { return }
        webView.evaluateJavaScript(
            "(window.scrollY || document.documentElement.scrollTop || 0)"
        ) { result, _ in
            let y = (result as? Double) ?? (result as? Int).map(Double.init) ?? 0
            if abs(y - lastScrollY) > 0.5 {
                lastScrollY = y
                sampleTopColor()
            }
        }
    }

    private func scheduleSample() {
        guard barStyle == .dynamic else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            sampleTopColor()
        }
    }

    private func sampleTopColor() {
        guard barStyle == .dynamic, !isSampling, let webView = tab?.webView else { return }
        let width = webView.bounds.width
        guard width > 0 else { return }
        isSampling = true
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: 8)
        config.snapshotWidth = NSNumber(value: 128)
        webView.takeSnapshot(with: config) { image, _ in
            isSampling = false
            guard let columns = image?.columnColors(Self.stopCount) else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                sampledStops = columns.map(Color.init(nsColor:))
            }
        }
    }

    // MARK: - Toolbar

    /// the main window's toolbar row: lights and navigation left, the page's
    /// controls around the url pill in the middle, "Open in …" pinned right
    private var header: some View {
        ToolbarRow {
            HStack(spacing: 6) {
                // the mount's 9pt inset lands the close button at the system's x=12
                TrafficLightMount()
                    .frame(width: TrafficLightMount.width, height: TrafficLightMount.height)
                    .padding(.leading, 3)
                NavigationControls()
            }
            HStack(spacing: 6) {
                if let tab {
                    ScoutUrlField(tab: tab)
                    PageActions(tab: tab)
                }
            }
            HStack {
                // an incognito page's popup has nowhere to go but its own window
                if tab?.isPrivate != true { promoteControl }
            }
        }
        .frame(height: BrowserToolbar.height)
        .padding(.trailing, toolbarGap)
        .background(WindowDragStrip().padding(.top, -BrowserToolbar.top).padding(.bottom, -toolbarGap))
    }

    /// promotes into `target`, or the chevron picks another space
    private var promoteControl: some View {
        HStack(spacing: 0) {
            ScoutPromoteButton(space: target) { promote(into: target) }
                .tooltip("Open this page as a tab in \(target.name)", keys: ["⌘", "O"])
            HoverIconButton("chevron.down", size: 10, weight: .semibold, boxSize: 28) {
                showSpaceMenu = true
            }
            .tooltip("Pick a space")
            .popover(isPresented: $showSpaceMenu, arrowEdge: .bottom) { spaceMenu }
        }
        .padding(.horizontal, (BrowserToolbar.height - 28) / 2)
        .frame(height: BrowserToolbar.height)
        .chromeGlass(in: .capsule)
    }

    private var spaceMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabManager.spaces) { space in
                SpaceMenuRow(space: space, isTarget: space.id == target.id) {
                    showSpaceMenu = false
                    pick(space)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 200)
    }

    private func pick(_ space: Space) {
        pickedManually = true
        targetSpace = space
        promote(into: space)
    }

    /// hands the page to the main browser as a tab in `space`, opening a browser window
    /// when none is open, then closes; stays open if no window comes
    private func promote(into space: Space) {
        guard !isPromoting, tab?.isPrivate != true,
            let url = tab?.url ?? tab?.lastAttemptedURL ?? tab?.pendingURL
        else { return }
        isPromoting = true
        Task {
            var destination = browser
            if destination == nil { destination = await Scripting.openWindow(incognito: false, on: space.id) }
            guard let destination else {
                isPromoting = false
                return
            }
            destination.adoptIntoBrowser(url, into: space)
            tab?.stopLoading()
            onClose()
        }
    }
}

/// three clusters: the first pinned left, the last right, the middle centred on
/// the row while it fits and slid clear of both when it doesn't. short of room
/// the last gives up width before the middle does, so nothing ever overlaps
private struct ToolbarRow: Layout {
    private let gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(2 * gap, +)
        return CGSize(width: proposal.width ?? ideal, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (first, middle, last) = (subviews[0], subviews[1], subviews[2])
        let leading = first.sizeThatFits(.unspecified).width
        let room = bounds.width - leading - 2 * gap
        let centre = middle.sizeThatFits(.unspecified).width
        let trailing = last.sizeThatFits(ProposedViewSize(width: max(room - centre, 0), height: bounds.height)).width
        let width = middle.sizeThatFits(ProposedViewSize(width: max(room - trailing, 0), height: bounds.height)).width
        let lo = bounds.minX + leading + gap, hi = bounds.maxX - trailing - gap
        first.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        last.place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
            proposal: ProposedViewSize(width: trailing, height: bounds.height))
        middle.place(
            at: CGPoint(x: max(lo, min(bounds.midX - width / 2, hi - width)), y: bounds.midY),
            anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// what fills the Scout frame, toolbar and rim alike
private enum ScoutBarPaint {
    case glass
    /// a left→right gradient of colours sampled from the page
    case sampled([Color])
    /// a user-chosen solid colour or gradient (a space theme)
    case appearance(SpaceAppearance)
}

/// the window's frame behind the toolbar and around the card
private struct ScoutBackdrop: View {
    let paint: ScoutBarPaint

    var body: some View {
        switch paint {
        case .glass:
            ScoutGlass()
        case .sampled(let colors):
            GradientBar(colors: colors)
        case .appearance(let appearance):
            ScoutAppearanceFill(appearance: appearance)
        }
    }
}

/// a frost of whatever sits behind the window, lit along its top edge. no glass
/// effect: one across the frame swallows the drags meant for the toolbar
private struct ScoutGlass: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blending: .behindWindow)
            RoundedRectangle(cornerRadius: WindowChrome.outerWindowRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06), .clear],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// renders a `SpaceAppearance` (solid / gradient / glass) as the bar fill,
/// reusing the same mesh renderer the space backdrops use
private struct ScoutAppearanceFill: View {
    let appearance: SpaceAppearance

    var body: some View {
        switch appearance.fill {
        case .solid:
            appearance.colors.first?.color ?? .black
        case .gradient:
            MeshGradientView(
                points: appearance.effectiveMeshPoints, sharpness: appearance.meshSharpness)
        case .glass:
            ScoutGlass()
        }
    }
}

/// a horizontal gradient of sampled page colours that morphs between samples
private struct GradientBar: View, Animatable {
    var colors: [Color]

    var animatableData: AnimatableVector {
        get { AnimatableVector(colors: colors) }
        set { colors = newValue.colors }
    }

    var body: some View {
        LinearGradient(
            colors: colors.isEmpty ? [.clear] : colors,
            startPoint: .leading, endPoint: .trailing)
    }
}

/// flattened sRGB colour components SwiftUI can interpolate, so a gradient animates
private struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    init(values: [Double]) { self.values = values }

    init(colors: [Color]) {
        values = colors.flatMap { color -> [Double] in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
            return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        }
    }

    var colors: [Color] {
        stride(from: 0, to: values.count - 2, by: 3).map { i in
            Color(.sRGB, red: values[i], green: values[i + 1], blue: values[i + 2])
        }
    }

    static var zero: AnimatableVector { AnimatableVector(values: []) }

    static func + (l: AnimatableVector, r: AnimatableVector) -> AnimatableVector {
        AnimatableVector(values: pairwise(l.values, r.values, +))
    }

    static func - (l: AnimatableVector, r: AnimatableVector) -> AnimatableVector {
        AnimatableVector(values: pairwise(l.values, r.values, -))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    /// element-wise, padding the shorter with zeros so a changing stop count can't crash
    private static func pairwise(
        _ a: [Double], _ b: [Double], _ op: (Double, Double) -> Double
    ) -> [Double] {
        let n = max(a.count, b.count)
        return (0..<n).map { op($0 < a.count ? a[$0] : 0, $0 < b.count ? b[$0] : 0) }
    }
}

/// one row in the space picker — icon left, name right, with the hover highlight
/// used across the rest of the chrome; a checkmark marks the current target
private struct SpaceMenuRow: View {
    let space: Space
    let isTarget: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SpaceGlyph(icon: space.icon, size: 13)
                    .foregroundStyle(space.appearance.accent)
                    .frame(width: 18)
                Text(space.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if isTarget {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.85))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.10 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(Motion.hover, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// the promote half of the split control: the target space's glyph in its
/// accent, then its name
private struct ScoutPromoteButton: View {
    @Environment(\.chromeInk) private var ink
    let space: Space
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SpaceGlyph(icon: space.icon, size: 12, weight: .medium)
                    .foregroundStyle(space.appearance.accent)
                Text("Open in \(space.name)")
                    .font(.system(size: 13))
                    .foregroundStyle(ink.opacity(isHovering ? 1 : 0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Capsule().fill(ink.opacity(isHovering ? 0.13 : 0)))
            .contentShape(.capsule)
            .animation(Motion.hover, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// the Scout address pill: copy, the domain at rest and the pinned extensions,
/// hugging them like the main toolbar's; a click on the domain (or ⌘L) opens it
/// up into the full, editable url
private struct ScoutUrlField: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.chromeInk) private var ink
    @Bindable var tab: BrowserTab
    @FocusState private var isFocused: Bool
    @State private var isEditing = false

    /// the page is loading and you aren't typing over it — a load you started by
    /// editing the field shouldn't fight the text you're still writing
    private var isLoading: Bool { tab.isLoading && !isEditing }
    /// extensions never see a private page
    private var showsExtensions: Bool { !isEditing && !tab.isPrivate && !extensions.pinnedExtensions.isEmpty }

    var body: some View {
        let inset: CGFloat = 14
        // a button at either end tucks to the pill's edge, as in the main toolbar's pill
        let tuck = (BrowserToolbar.height - 22) / 2
        HStack(spacing: 6) {
            if !isEditing { CopyURLButton(tab: tab) }
            Group {
                if isEditing {
                    TextField(
                        "URL", text: $tab.addressText,
                        prompt: Text("Search or enter URL").foregroundStyle(ink.opacity(0.45))
                    )
                    .textFieldStyle(.plain)
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .focused($isFocused)
                    .onSubmit {
                        tab.submit(tab.addressText)
                        endEditing()
                    }
                    .onExitCommand { endEditing() }
                    .disableAutocorrection(true)
                    .textContentType(.URL)
                } else {
                    Text(UrlField.displayText(for: tab))
                        .foregroundStyle(ink.opacity(tab.url == nil ? 0.45 : 0.9))
                }
            }
            // the url lifts to make room, and the bar rises into the space it left
            .offset(y: isLoading ? -2 : 0)
            if showsExtensions { PinnedExtensionsBar() }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.leading, isEditing ? inset : tuck)
        .padding(.trailing, showsExtensions ? tuck : inset)
        .frame(maxWidth: isEditing ? .infinity : nil)
        .frame(height: BrowserToolbar.height)
        .overlay(alignment: .bottom) { loadingBar }
        .chromeGlass(in: .capsule)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { beginEditing() } }
        .animation(Motion.pop, value: isLoading)
        .animation(Motion.address, value: isEditing)
        .animation(Motion.address, value: UrlField.displayText(for: tab))
        .onChange(of: isFocused) { _, focused in if !focused { endEditing() } }
        .onChange(of: tab.url) { if isEditing { endEditing() } }
        // ⌘L
        .onChange(of: tabManager.urlFieldFocusRequest) { beginEditing() }
    }

    /// the load, drawn along the pill's own bottom edge, inside its rounding
    private var loadingBar: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(ink.opacity(0.7))
                .frame(width: geometry.size.width * max(tab.progress, 0.04))
                .animation(.easeOut(duration: 0.25), value: tab.progress)
        }
        .frame(height: 2)
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
        .opacity(isLoading ? 1 : 0)
        .allowsHitTesting(false)
    }

    private func beginEditing() {
        tab.addressText = tab.url?.absoluteString ?? tab.addressText
        isEditing = true
        // the field has to exist before it can take focus
        DispatchQueue.main.async { isFocused = true }
    }

    /// FocusState alone doesn't resign the AppKit first responder on macOS
    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        isFocused = false
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

/// the Scout-bar setting row: a label and a colour circle showing the current
/// look; tapping the circle opens the glass dropdown to change it
struct ScoutBarSetting: View {
    @AppStorage(ScoutBarStyle.storageKey) private var styleRaw = ScoutBarStyle.fallback.rawValue
    @AppStorage(ScoutBarAppearanceStore.key) private var json = ""
    @State private var showEditor = false

    private var style: ScoutBarStyle { ScoutBarStyle(rawValue: styleRaw) ?? .fallback }
    private var appearance: SpaceAppearance { ScoutBarAppearanceStore.load(json) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Frame")
                Spacer()
                ScoutBarSwatch(style: style, appearance: appearance)
                    .contentShape(.circle)
                    .onTapGesture { showEditor.toggle() }
                    .popover(isPresented: $showEditor, arrowEdge: .bottom) { ScoutBarEditor() }
            }
            Text("How Scout's frame is painted. Dynamic follows the colours of the open page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// the colour circle that previews the current Scout-bar look
private struct ScoutBarSwatch: View {
    let style: ScoutBarStyle
    let appearance: SpaceAppearance
    private let size: CGFloat = 26

    var body: some View {
        preview
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }

    @ViewBuilder
    private var preview: some View {
        switch style {
        case .solid:
            appearance.colors.first?.color ?? .black
        case .gradient:
            MeshGradientView(
                points: appearance.effectiveMeshPoints, sharpness: appearance.meshSharpness)
        case .glass:
            Color.white.opacity(0.12).glassEffect(.regular, in: .circle)
        case .dynamic:
            // a multicolour wheel to read as "automatic / page-driven"
            AngularGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                center: .center)
        case .space:
            Color.secondary.opacity(0.3)
                .overlay(Image(systemName: "square.stack.fill").font(.system(size: 11)).foregroundStyle(.secondary))
        }
    }
}

/// the glass dropdown to change the Scout bar — styled exactly like the sidebar's
/// space editor, pared down to the fill control and its editor
struct ScoutBarEditor: View {
    @AppStorage(ScoutBarStyle.storageKey) private var styleRaw = ScoutBarStyle.fallback.rawValue
    @AppStorage(ScoutBarAppearanceStore.key) private var json = ""
    @State private var appearance = ScoutBarAppearanceStore.fallback

    private var style: ScoutBarStyle { ScoutBarStyle(rawValue: styleRaw) ?? .fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSegmented(
                options: ScoutBarStyle.allCases.map { ($0, $0.label) },
                selection: styleBinding)
                .frame(maxWidth: .infinity, alignment: .center)

            switch style {
            case .solid:
                HStack {
                    Text("Colour").font(.system(size: 13)).foregroundStyle(.primary.opacity(0.7))
                    Spacer()
                    ColorSwatchPicker(color: solidBinding)
                }
            case .gradient:
                // a short, wide canvas so the mesh you design maps onto the bar
                MeshEditor(appearance: $appearance, canvasHeight: 60)
            case .glass:
                Text("The frame stays translucent over the desktop behind it.")
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.55))
            case .dynamic:
                Text("The frame takes the open page's colours and follows them as you scroll.")
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.55))
            case .space:
                Text("The frame wears the colours of the space the page would open in.")
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.55))
            }

            if style == .solid || style == .gradient {
                Text("PRESETS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.45))
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(SpacePreset.all) { preset in
                            Button { applyPreset(preset.appearance) } label: {
                                ScoutPresetSwatch(appearance: preset.appearance)
                            }
                            .buttonStyle(.plain)
                            .tooltip(preset.name)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { appearance = ScoutBarAppearanceStore.load(json) }
        .onChange(of: appearance) { _, new in json = ScoutBarAppearanceStore.encode(new) }
    }

    /// solid and gradient seed colours so their editor has something to work with
    private var styleBinding: Binding<ScoutBarStyle> {
        Binding(
            get: { style },
            set: { newStyle in
                switch newStyle {
                case .gradient:
                    if appearance.colors.count < 2 {
                        let b = appearance.colors.first ?? RGBA(0.2, 0.16, 0.42)
                        appearance.colors = [
                            b, RGBA(min(b.r * 1.6, 1), min(b.g * 1.6, 1), min(b.b * 1.6, 1)),
                        ]
                    }
                    appearance.fill = .gradient
                case .solid:
                    if appearance.colors.isEmpty { appearance.colors = [RGBA(.white)] }
                    appearance.fill = .solid
                case .glass, .dynamic, .space:
                    break
                }
                styleRaw = newStyle.rawValue
            })
    }

    private var solidBinding: Binding<Color> {
        Binding(
            get: { appearance.colors.first?.color ?? .black },
            set: { newValue in
                var colors = appearance.colors
                if colors.isEmpty { colors = [RGBA(.black)] }
                colors[0] = RGBA(newValue)
                appearance.colors = colors
            })
    }

    /// a preset carries its own fill; adopt it and flip the style to match
    private func applyPreset(_ preset: SpaceAppearance) {
        appearance = preset
        styleRaw = (preset.fill == .solid ? ScoutBarStyle.solid : .gradient).rawValue
    }
}

/// a small preview of a preset appearance for the Scout editor's preset row
private struct ScoutPresetSwatch: View {
    let appearance: SpaceAppearance

    var body: some View {
        Group {
            if appearance.fill == .solid {
                appearance.colors.first?.color ?? .black
            } else {
                MeshGradientView(
                    points: appearance.effectiveMeshPoints, sharpness: appearance.meshSharpness)
            }
        }
        .frame(width: 46, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private extension Color {
    /// rough perceptual-luminance test, for picking contrasting ink over a fill
    var isDark: Bool {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let l = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return l < 0.55
    }

    /// the mean of several colours in sRGB
    static func average(of colors: [Color]) -> Color {
        let comps = colors.map { color -> (Double, Double, Double) in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        guard !comps.isEmpty else { return .gray }
        let n = Double(comps.count)
        return Color(
            .sRGB,
            red: comps.reduce(0) { $0 + $1.0 } / n,
            green: comps.reduce(0) { $0 + $1.1 } / n,
            blue: comps.reduce(0) { $0 + $1.2 } / n)
    }
}

private extension NSImage {
    /// the average colour of each of `count` equal columns, left→right
    func columnColors(_ count: Int) -> [NSColor]? {
        guard count > 0,
            let tiff = tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let cgImage = bitmap.cgImage
        else { return nil }

        let bytesPerRow = count * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow)
        // the context draws through the pointer, so it must not outlive the closure
        let drawn = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: count, height: 1, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: count, height: 1))
            return true
        }
        guard drawn else { return nil }

        return (0..<count).map { i in
            let o = i * 4
            return NSColor(
                srgbRed: CGFloat(data[o]) / 255, green: CGFloat(data[o + 1]) / 255,
                blue: CGFloat(data[o + 2]) / 255, alpha: 1)
        }
    }
}
