// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

extension String {
    /// a space icon is either an SF Symbol name (all ASCII, e.g. "circle.fill")
    /// or an emoji glyph — emoji carry non-ASCII scalars, symbol names never do
    var isEmojiIcon: Bool { !isEmpty && !allSatisfy(\.isASCII) }
}

/// a space icon as a tinted SF Symbol or an emoji glyph, which keeps its own
/// colours; every place that shows `space.icon` goes through this
struct SpaceGlyph: View {
    let icon: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        if icon.isEmojiIcon {
            // nudge emoji up a hair larger so they optically match a symbol
            Text(icon).font(.system(size: size + 1))
        } else {
            Image(systemName: icon).font(.system(size: size, weight: weight))
        }
    }
}

/// how much room each space gets in a row `width` points wide: every space is
/// a dot, bar one icon-width slot for whichever space is expanded
private struct SpaceRowLayout {
    static let full: CGFloat = 28
    static let dot: CGFloat = 13
    static let minDot: CGFloat = 9

    let slot: CGFloat

    init(count: Int, width: CGFloat) {
        slot = max(Self.minDot, min(Self.dot, (width - Self.full) / CGFloat(max(1, count - 1))))
    }
}

/// the space switcher — a row of space icons at the bottom of the sidebar.
/// tap to switch, tap the current one (or right-click any) to edit, + to add
struct SpaceSwitcher: View {
    @Environment(TabManager.self) private var tabManager
    /// which space the cursor is on, held here because the neighbours collapse
    /// to dots in response — a local hover in each icon can't be read sideways
    @State private var hovered: Space.ID?
    /// ⌃ alone is held in this window: the first nine dots show the ⌃1–⌃9 numbers
    @State private var showsNumbers = false
    @State private var flagsMonitor: Any?

    var body: some View {
        let _ = Bench.tick("SpaceSwitcher")
        // dots in a capsule that hugs them; a hovered dot grows into its icon
        // and the glass widens around it
        GeometryReader { geo in
            let inset: CGFloat = 7
            icons(SpaceRowLayout(count: tabManager.spaces.count, width: geo.size.width - 2 * inset))
                .padding(.horizontal, inset)
                .chromeGlass(in: .capsule)
                .animation(Motion.pop, value: hovered)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: SidebarMetrics.glassSide)
        // a slot the cursor leaves diagonally can miss its own exit event
        .onHover { if !$0 { hovered = nil } }
        .onAppear {
            guard tabManager.kind == .main, flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
                [tabManager] event in
                showsNumbers = BrowserWindows.shared.manager(for: event.window) === tabManager
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
        // a ⌃ released in another app never reaches the monitor
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) {
            _ in showsNumbers = false
        }
    }

    private func icons(_ layout: SpaceRowLayout) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(tabManager.spaces.enumerated()), id: \.element.id) { index, space in
                SpaceIcon(
                    space: space, index: index, layout: layout, hovered: $hovered,
                    showsNumber: showsNumbers && index < 9)
            }
        }
    }
}

private struct SpaceIcon: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(SidebarDragState.self) private var drag
    @Environment(\.chromeInk) private var ink
    let space: Space
    let index: Int
    let layout: SpaceRowLayout
    @Binding var hovered: Space.ID?
    let showsNumber: Bool

    private var isHovering: Bool { hovered == space.id }

    /// a tab is being dragged over this icon — drop it here to move it into this
    /// space, cookie jar and all
    private var isDropTarget: Bool { drag.spaceDropTarget == space.id }

    /// 1 when this space is centred, falling to 0 one slot away. reads the
    /// backdrop's tint position, not the filmstrip's, whose spring overshoots
    private var selectedness: Double {
        // the strip's slot, not the row's: mid-jump the origin sits beside the
        // destination, and its dot fades out from there
        let slot = tabManager.stripSpaces.firstIndex { $0.id == space.id } ?? index
        return max(0, 1 - abs(tabManager.tintPosition - Double(slot)))
    }

    /// only the hovered space, or one under a dragged tab, shows its icon
    private var isExpanded: Bool { isHovering || isDropTarget }

    /// grey when idle, the space's accent when centred, blended in between
    private var iconColor: Color {
        // a pale accent vanishes into glass, so dots stay in ink
        if !isExpanded { return ink.opacity(0.3 + 0.6 * selectedness) }
        return ink.opacity(isHovering ? 0.8 : 0.45).mix(with: space.appearance.accent, by: selectedness)
    }

    var body: some View {
        let _ = Bench.tick("SpaceIcon")
        Button {
            tabManager.selectSpace(space)
        } label: {
            ZStack {
                SpaceGlyph(icon: space.icon, size: 13, weight: .medium)
                    .foregroundStyle(iconColor)
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.5)
                Circle()
                    .fill(iconColor)
                    .frame(width: 5, height: 5)
                    .opacity(isExpanded || showsNumber ? 0 : 1)
                    .scaleEffect(isExpanded ? 2.2 : 1)
                if showsNumber, !isExpanded {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ink.opacity(0.55 + 0.45 * selectedness))
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: showsNumber)
            .frame(
                width: isExpanded ? SpaceRowLayout.full : layout.slot,
                height: SidebarMetrics.glassSide)
            // lit only under a dragged tab; the active space reads as active via colour
            .background(Capsule().fill(space.appearance.accent.opacity(isDropTarget ? 0.85 : 0)))
            .animation(Motion.hover, value: isHovering)
            .animation(Motion.pop, value: isExpanded)
            // grows a touch under a dragged tab, so the target is unmistakable
            .scaleEffect(isDropTarget ? 1.18 : 1)
            .animation(Motion.pop, value: isDropTarget)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // publish the icon's frame in the sidebar's drag coordinate space so the
        // drop can be resolved without the gesture needing to know about spaces
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(SidebarDragState.contentSpace))
        } action: { frame in
            drag.spaceDropFrames[space.id] = frame
        }
        .onDisappear { drag.spaceDropFrames[space.id] = nil }
        .onHover { hovering in
            if hovering {
                hovered = space.id
            } else if isHovering {
                hovered = nil
            }
        }
        // with several profiles, the tip says which one the space browses as
        .tooltip(
            tabManager.profiles.count > 1
                ? "\(space.name) · \(tabManager.core.profile(of: space).name)" : space.name,
            style: .centered)
        .accessibilityAddTraits(space.id == tabManager.selectedSpaceID ? .isSelected : [])
        .contextMenu {
            Button {
                // select it, then ask the top header to open its editor. the
                // bump is deferred so a space change (which re-creates the
                // header) lands first and the new header sees the request
                tabManager.selectSpace(space)
                DispatchQueue.main.async { tabManager.editSpaceRequest += 1 }
            } label: {
                Label("Edit Space…", systemImage: "pencil").labelStyle(.titleAndIcon)
            }
            if tabManager.spaces.count > 1 {
                Button(role: .destructive) {
                    tabManager.deleteSpace(space)
                } label: {
                    Label("Delete Space", systemImage: "trash").labelStyle(.titleAndIcon)
                }
            }
        }
    }
}

/// name / icon / appearance editor shown in a popover from the space header
struct SpaceEditor: View {
    @Environment(TabManager.self) private var tabManager
    let space: Space
    @State private var name = ""
    @State private var appearance = SpaceAppearance()
    @State private var showingIconPicker = false
    // theme edits are buffered in `appearance` and reach the space only on the
    // tick (the eye wears them until the preview ends); `original` is what the
    // space shows meanwhile, and what the x reverts to
    @State private var original = SpaceAppearance()
    @State private var grainPct = 0  // mirror of grain×100, animated for the rolling label

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Space name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .modifier(EditorField())
                    .onSubmit { commitName() }

                iconSection
                fillSection
                if appearance.fill != .glass {
                    grainSection
                }
                presetSection
                profileSection
                section("PRIVACY") {
                    Toggle(
                        "Require Touch ID to open",
                        isOn: Binding(
                            get: { space.requiresUnlock },
                            set: {
                                SpaceLock.shared.setRequiresUnlock($0, for: space)
                                tabManager.scheduleSave()
                            }))
                    .font(.system(size: 12))
                    Text("Locks again whenever Artemis is in the background.")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.5))
                }

                if tabManager.spaces.count > 1 {
                    Divider()
                    Button(role: .destructive) {
                        tabManager.deleteSpace(space)
                    } label: {
                        Label("Delete Space", systemImage: "trash")
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .onAppear {
            name = space.name
            // resume an edit that was interrupted by a full-window preview, else
            // load the space fresh. the space is never committed mid-edit, so its
            // current appearance is the original either way
            if let resume = tabManager.resumeGradientEdit, resume.id == space.id {
                appearance = resume.appearance
                tabManager.resumeGradientEdit = nil
            } else {
                appearance = space.appearance
            }
            original = space.appearance
            grainPct = Int(appearance.grain * 100)
            tabManager.isSidebarPopoverOpen = true  // keep the overlay pinned
        }
        // roll the grain label off an animated mirror (the slider stays direct)
        .onChange(of: appearance.grain) { _, v in
            withAnimation(.snappy(duration: 0.25)) { grainPct = Int(v * 100) }
        }
        // switching to gradient needs ≥2 colours for a mesh; nothing here touches
        // the real space — edits only land via the tick
        .onChange(of: appearance.fill) { _, fill in
            if fill == .gradient, appearance.colors.count < 2 {
                let base = appearance.colors.first ?? RGBA(0.2, 0.16, 0.42)
                appearance.colors = [base, RGBA(base.r * 1.5, base.g * 1.5, base.b * 1.5)]
            }
        }
        .onDisappear {
            commitName()
            tabManager.isSidebarPopoverOpen = false
        }
    }

    // MARK: Preview / commit / revert

    /// the eye: show the working theme on the real space (frozen, no interaction)
    /// and stash both what to restore and the in-progress edit. the space header
    /// tucks this editor away while the preview is up and reopens it on exit
    private func launchPreview() {
        tabManager.resumeGradientEdit = (space.id, appearance)
        tabManager.previewRevert = original           // what the space goes back to
        tabManager.updateSpace(space, appearance: appearance)  // wear it for real
        tabManager.gradientPreview = appearance        // flag the overlay + close editor
    }

    /// the tick: the only thing that writes the theme to the real space
    private func confirmEdit() {
        tabManager.updateSpace(space, appearance: appearance)
        original = appearance  // becomes the new revert point
    }

    /// the x: throw away the working edits; the space never changed, so this just
    /// snaps the editor UI back to where it started
    private func cancelEdit() {
        appearance = original
    }

    // MARK: - Sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            // section label in the sidebar's muted-ink vocabulary (primary is the
            // popover analog of the backdrop-adaptive chromeInk)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.45))
            content()
        }
    }

    private var iconSection: some View {
        section("ICON") {
            // tapping opens a second popover (the icon/emoji browser) rather than
            // expanding inline — keeps the editor short and gives the grid room
            Button {
                showingIconPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    SpaceGlyph(icon: space.icon, size: 14)
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(width: 20)
                    Text(space.icon.isEmojiIcon ? "Emoji" : space.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.5)).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.4))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingIconPicker, arrowEdge: .trailing) {
                IconPicker(
                    icon: Binding(get: { space.icon }, set: { tabManager.updateSpace(space, icon: $0) }))
            }
        }
    }

    private var fillSection: some View {
        section("FILL") {
            HStack(spacing: 5) {
                GlassSegmented(
                    options: SpaceFill.allCases.map { ($0, $0.label) },
                    selection: $appearance.fill)

                Spacer(minLength: 6)
                GlassIconButton("eye", label: "Preview") { launchPreview() }
                GlassIconButton("xmark", label: "Discard changes", tint: .red.opacity(0.85)) {
                    cancelEdit()
                }
                GlassIconButton("checkmark", label: "Save", tint: .green.opacity(0.9)) {
                    confirmEdit()
                }
            }

            switch appearance.fill {
            case .solid:
                HStack {
                    Text("Colour").font(.system(size: 13)).foregroundStyle(.primary.opacity(0.7))
                    Spacer()
                    ColorSwatchPicker(color: colorBinding(0))
                }
            case .gradient:
                MeshEditor(appearance: $appearance)
            case .glass:
                // clear (left) → blurred (right), matching the macOS slider
                HStack(spacing: 10) {
                    GlassEndIcon(blurred: false)
                        .offset(x: 3.5)  // nudge the clear icon toward the slider
                    Slider(value: $appearance.glassBlur, in: 0...1)
                    GlassEndIcon(blurred: true)
                }
            }
        }
    }

    private var grainSection: some View {
        section("GRAIN") {
            HStack {
                Slider(value: $appearance.grain, in: 0...1)
                // label rolls (slot-machine) off a mirror state animated in
                // onChange, so the slider knob itself never lags the cursor
                Text("\(grainPct)%")
                    .font(.system(size: 12).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary.opacity(0.5))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private var presetSection: some View {
        section("PRESETS") {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(SpacePreset.all) { preset in
                        Button {
                            appearance = preset.appearance
                        } label: {
                            PresetSwatch(appearance: preset.appearance)
                        }
                        .buttonStyle(.plain)
                        .tooltip(preset.name)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            // reach toward the popover edge so all swatches fit without scrolling
            .padding(.trailing, -12)
        }
    }

    /// applied live, unlike the buffered theme: a profile change rebuilds the
    /// space's web views in the new jar
    private var profileSection: some View {
        section("PROFILE") {
            ProfilePicker(
                selection: Binding(
                    get: { space.profileID }, set: { tabManager.setProfile($0, for: space) }))
            Text("The space signs in, keeps history and shows favourites as this profile. Changing it reloads the space's tabs.")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bindings

    private func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                appearance.colors.indices.contains(index) ? appearance.colors[index].color : .black
            },
            set: { newValue in
                var colors = appearance.colors
                while colors.count <= index { colors.append(RGBA(.black)) }
                colors[index] = RGBA(newValue)
                appearance.colors = colors
            })
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != space.name {
            tabManager.updateSpace(space, name: trimmed)
        }
    }
}

/// text-field chrome matching a sidebar row: 10pt continuous corners over the
/// sidebar's faint ink fill, so editor fields read like the rest of the app
/// rather than system rounded-border boxes
private struct EditorField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.06)))
    }
}

/// a liquid-glass segmented control: one continuous glass capsule with a single
/// highlighted pill that slides to the selected option — the iOS Apple Music tab
/// bar look. sizes to its content so it can sit flush-left beside siblings
struct GlassSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let sel = opt.value == selection
                Text(opt.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)  // never wrap a label letter-by-letter
                    .foregroundStyle(.primary.opacity(sel ? 0.95 : 0.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background {
                        // the single selection pill, shared across options so it
                        // slides between them instead of cross-fading
                        if sel {
                            Capsule().fill(.primary.opacity(0.18))
                                .matchedGeometryEffect(id: "segPill", in: ns)
                        }
                    }
                    .contentShape(.capsule)
                    .onTapGesture { withAnimation(Motion.pop) { selection = opt.value } }
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        // claim intrinsic width so siblings (the gradient buttons) can't squeeze
        // it down to a wrapping blob
        .fixedSize()
    }
}

/// a single liquid-glass icon button island (preview / revert / commit)
private struct GlassIconButton: View {
    let systemName: String
    let label: String
    let tint: Color
    let action: () -> Void

    init(_ systemName: String, label: String, tint: Color = .primary.opacity(0.8),
         action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .tooltip(label)
    }
}

/// the icon browser shown as a second popover from an ICON row (a space's or a
/// profile's). a kind toggle (Icons / Emoji) and a search field sit above a large
/// scrollable grid; cells use the same selected/idle ink fills as a sidebar tab row
struct IconPicker: View {
    @Binding var icon: String

    private enum Kind: String, CaseIterable { case icons = "Icons", emoji = "Emoji" }
    @State private var kind: Kind
    @State private var query = ""

    init(icon: Binding<String>) {
        _icon = icon
        // open on whichever kind the current icon already is
        _kind = State(initialValue: icon.wrappedValue.isEmojiIcon ? .emoji : .icons)
    }

    private var results: [String] {
        kind == .emoji ? Emojis.search(query) : SFSymbols.search(query)
    }

    /// both tabs browse as macOS-style categories; a search collapses to a flat
    /// result grid
    private var showsCategories: Bool { query.isEmpty }

    /// the category sections for the current tab, normalised to (title, glyphs)
    private var sections: [(String, [String])] {
        kind == .emoji
            ? Emojis.categories.map { ($0.name, $0.emoji.map(\.glyph)) }
            : SFSymbols.categories.map { ($0.name, $0.symbols) }
    }

    // emoji read larger so they get roomier cells; symbols pack denser
    private var cellSize: CGFloat { kind == .emoji ? 40 : 36 }

    var body: some View {
        VStack(spacing: 10) {
            GlassSegmented(
                options: Kind.allCases.map { ($0, $0.rawValue) },
                selection: $kind)
                .frame(maxWidth: .infinity, alignment: .center)
                .onChange(of: kind) { query = "" }

            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .modifier(EditorField())

            ScrollView {
                // one lazy grid whose Section headers span all columns; the
                // selection is read once for the whole pass
                let current = icon
                LazyVGrid(
                    columns: columns, spacing: 6,
                    pinnedViews: showsCategories ? [.sectionHeaders] : []
                ) {
                    if showsCategories {
                        ForEach(sections, id: \.0) { title, glyphs in
                            Section {
                                ForEach(glyphs, id: \.self) { cell($0, selected: $0 == current) }
                            } header: {
                                sectionHeader(title)
                            }
                        }
                    } else {
                        ForEach(results, id: \.self) { cell($0, selected: $0 == current) }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 300)
        }
        .padding(14)
        .frame(width: 320)
    }

    private static let emojiFont = Font.system(size: 22)
    private static let symbolFont = Font.system(size: 16)

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cellSize), spacing: 6)] }

    // a bare glyph and tap: no Button, no tooltip tracking area, and only the
    // selected cell draws a background
    private func cell(_ icon: String, selected: Bool) -> some View {
        glyph(icon)
            .frame(width: cellSize, height: cellSize)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.18))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { self.icon = icon }
            // the glyph's own name is the only thing distinguishing one cell from
            // the next; without it the grid is 250 unnamed shapes
            .accessibilityElement()
            .accessibilityLabel(kind == .emoji ? icon : icon.replacingOccurrences(of: ".", with: " "))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { self.icon = icon }
    }

    @ViewBuilder
    private func glyph(_ icon: String) -> some View {
        if kind == .emoji {
            // verbatim: skip the LocalizedStringKey lookup Text(_:) would run on
            // every emoji string while scrolling
            Text(verbatim: icon).font(Self.emojiFont)
        } else {
            Image(systemName: icon).font(Self.symbolFont).foregroundStyle(.primary.opacity(0.8))
        }
    }

    /// pinned category label in the sidebar's muted-ink vocabulary, riding a
    /// liquid-glass capsule that hugs just the title — glyphs scrolling past the
    /// rest of the row stay visible, and the glass refracts them softly under it
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// the glass slider's end glyphs: a 12.5×14.5 panel rectangle and an equal
/// capsule offset 2.5 down and right. clear = 1pt outlines; blurred = both
/// filled, with a 0.5pt gap around the capsule
private struct GlassEndIcon: View {
    var blurred: Bool

    private let rectW: CGFloat = 14.5
    private let rectH: CGFloat = 12.5
    private let capW: CGFloat = 14.5
    private let capH: CGFloat = 12.5
    private let off: CGFloat = 2.5
    private let lw: CGFloat = 1
    private let gap: CGFloat = 0.5

    private var tint: Color { Color.primary.opacity(blurred ? 0.8 : 0.6) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if blurred { blurredContent } else { clearContent }
        }
        .frame(width: off + capW, height: off + capH, alignment: .topLeading)
    }

    // MARK: Clear — outlines, rectangle bottom bows down inside the capsule

    @ViewBuilder private var clearContent: some View {
        // shortened 2.5pt off the top (bottoms stay); rectangle 2pt and capsule
        // 1pt narrower, both off the left (right edges stay put)
        let capX = off + 2  // left edge in; right edge unchanged
        let capWidth = capW - 1
        let capRadius = (capH - 2.5) / 2
        let rectX: CGFloat = 2.25  // left edge fixed
        let rectWidth = rectW - 3  // 0.5pt off the right edge

        // capsule's semicircle centres, in the rectangle's coordinate space, so
        // the bottom/right edges break exactly where they meet the capsule
        let capDY = (off + 2.5) - 3
        let capCenterLeft = CGPoint(x: (capX - rectX) + capRadius, y: capDY + capRadius)
        let capCenterRight = CGPoint(x: (capX - rectX) + capWidth - capRadius, y: capDY + capRadius)

        // capsule first, then the panel on top, so the panel's dipping bottom
        // line shows at the capsule edge instead of hiding under the capsule
        Capsule()
            .strokeBorder(tint, lineWidth: lw)
            .frame(width: capWidth, height: capH - 2.5)
            .offset(x: capX, y: off + 2.5)

        RefractedPanel(
            cornerRadius: 1.5, lineWidth: lw,
            capCenterLeft: capCenterLeft, capCenterRight: capCenterRight, capRadius: capRadius,
            bottomDrop: 1.5, bottomRunIn: 1.5,  // inside tip drops 3px
            bottomShift: 1.5,  // inside curve tip sits 3px right of the capsule edge
            rightDrop: 1, rightRunIn: 1,  // smaller: inside tip curves 2px left
            rightShift: 1  // inside curve tip sits 2px below the capsule edge
        )
        .stroke(tint, lineWidth: lw)
        .frame(width: rectWidth, height: rectH - 4)  // 0.5pt off the top, bottom fixed
        .offset(x: rectX, y: 3)
    }

    // MARK: Blurred — the clear icon's shapes, filled, with `gap` punched
    // around the capsule (matches the clear icon's rectangle/capsule geometry)

    @ViewBuilder private var blurredContent: some View {
        let capWidth = capW - 1
        let capHeight = capH - 2.5
        let capY = off + 2.5

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: rectW - 2, height: rectH - 3)  // 0.5pt bigger all round
                .offset(x: 1.75, y: 2.5)
            Capsule()
                .fill(.black)
                .frame(width: capWidth + 2 * gap, height: capHeight + 2 * gap)
                .offset(x: (off + 2) - gap, y: capY - gap)
                .blendMode(.destinationOut)
        }
        .compositingGroup()

        Capsule()
            .fill(tint)
            .frame(width: capWidth, height: capHeight)
            .offset(x: off + 2, y: capY)
    }
}

/// the clear icon's panel: a rounded rectangle broken where the capsule crosses its
/// bottom and right edges, drawn as two open subpaths, an outside frame and an
/// inside corner piece whose two free tips curve away like refracted glass
private struct RefractedPanel: Shape {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var capCenterLeft: CGPoint   // centre of the capsule's left semicircle
    var capCenterRight: CGPoint  // centre of the capsule's right semicircle
    var capRadius: CGFloat
    var bottomDrop: CGFloat      // how far the bottom inside segment curves down
    var bottomRunIn: CGFloat     // flat run before the bottom curve
    var bottomShift: CGFloat     // slide the bottom tip right of the crossing
    var rightDrop: CGFloat       // how far the right inside segment curves left
    var rightRunIn: CGFloat      // flat run before the right curve
    var rightShift: CGFloat      // slide the right tip below the crossing

    func path(in rect: CGRect) -> Path {
        let r = rect  // full bounds, matching a stroked RoundedRectangle's size
        let cr = cornerRadius

        // capsule's left edge ∩ bottom line, and its top edge ∩ right line:
        // the outside segments stop here; the inside tips are slid past them
        let dyB = r.maxY - capCenterLeft.y
        let xCross = capCenterLeft.x - sqrt(max(0, capRadius * capRadius - dyB * dyB))
        let dxR = r.maxX - capCenterRight.x
        let yCross = capCenterRight.y - sqrt(max(0, capRadius * capRadius - dxR * dxR))

        let bTipX = xCross + bottomShift
        let bCurveX = min(r.maxX - cr, bTipX + bottomRunIn)
        let rTipY = yCross + rightShift
        let rCurveY = min(r.maxY - cr, rTipY + rightRunIn)

        var p = Path()
        // outside frame: right free end (at the capsule's top edge) up and around
        // to the bottom free end (at the capsule's left edge)
        p.move(to: CGPoint(x: r.maxX, y: yCross))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cr))
        p.addQuadCurve(to: CGPoint(x: r.maxX - cr, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + cr, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + cr), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cr))
        p.addQuadCurve(to: CGPoint(x: r.minX + cr, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: xCross, y: r.maxY))

        // inside corner piece: bottom tip → up around the bottom-right corner →
        // right tip, both free, gapped from the outside frame
        p.move(to: CGPoint(x: bTipX, y: r.maxY + bottomDrop))
        p.addQuadCurve(to: CGPoint(x: bCurveX, y: r.maxY), control: CGPoint(x: bTipX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - cr, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - cr), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: rCurveY))
        p.addQuadCurve(
            to: CGPoint(x: r.maxX - rightDrop, y: rTipY), control: CGPoint(x: r.maxX, y: rTipY))
        return p
    }
}

/// a 26pt preview of a preset appearance. the mesh image is rendered once and
/// cached, so re-renders of the editor (e.g. dragging another slider) don't
/// recompute every swatch
private struct PresetSwatch: View {
    let appearance: SpaceAppearance
    @State private var meshImage: CGImage?

    var body: some View {
        content
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.15)))
            .task {
                if appearance.fill == .gradient {
                    meshImage = MeshGradientView.render(
                        points: appearance.effectiveMeshPoints, sharpness: appearance.meshSharpness)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch appearance.fill {
        case .solid:
            appearance.colors.first?.color ?? .black
        case .gradient:
            if let meshImage {
                Image(decorative: meshImage, scale: 1).resizable().interpolation(.high)
            } else {
                appearance.colors.first?.color ?? .black
            }
        case .glass:
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Image(systemName: "snowflake")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

// MARK: - Space creator

/// the new-space dialog: the space doesn't exist until "Create", so Cancel leaves
/// nothing behind
struct SpaceCreator: View {
    @Environment(TabManager.self) private var tabManager
    @State private var icon = "circle.fill"
    @State private var name = ""
    @State private var appearance = SpacePreset.all[0].appearance
    @State private var selectedPresetID: Int? = 0
    @State private var profileID = Profile.defaultID
    @State private var showingIconPicker = false
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Space")
                .font(.system(size: 15, weight: .semibold))

            TextField("Name your space", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .modifier(EditorField())
                .focused($nameFocused)
                .onSubmit { if canCreate { create() } }

            section("ICON") { iconRow }
            section("PALETTE") { presetRow }
            // one profile is no choice at all, so the row waits for a second
            if tabManager.profiles.count > 1 {
                section("PROFILE") { ProfilePicker(selection: $profileID) }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.6))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button { create() } label: {
                    Text("Create Space")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                canCreate
                                    ? appearance.accent.opacity(0.9)
                                    : Color.primary.opacity(0.12)))
                        .foregroundStyle(canCreate ? .white : .primary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .onAppear {
            // a suggested identity, confirmed or changed before the space exists
            let n = tabManager.spaces.count
            icon = TabManager.defaultIcons[n % TabManager.defaultIcons.count]
            profileID = tabManager.currentProfile.id
            let preset = SpacePreset.all[n % SpacePreset.all.count]
            appearance = preset.appearance
            selectedPresetID = preset.id
            nameFocused = true
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.45))
            content()
        }
    }

    private var iconRow: some View {
        Button {
            showingIconPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                SpaceGlyph(icon: icon, size: 14)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 20)
                Text(icon.isEmojiIcon ? "Emoji" : icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.5)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingIconPicker, arrowEdge: .trailing) {
            IconPicker(icon: $icon)
        }
    }

    /// the preset palettes as one row of swatches; the chosen one wears a ring.
    /// (finer control — custom meshes, grain — lives in the editor afterwards)
    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(SpacePreset.all) { preset in
                Button {
                    appearance = preset.appearance
                    selectedPresetID = preset.id
                } label: {
                    PresetSwatch(appearance: preset.appearance)
                        .overlay(
                            Circle()
                                .stroke(
                                    selectedPresetID == preset.id
                                        ? Color.primary.opacity(0.9) : .clear,
                                    lineWidth: 2)
                                .padding(-3))
                }
                .buttonStyle(.plain)
                .tooltip(preset.name)
            }
        }
        .padding(.vertical, 3)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabManager.createSpace(
            name: trimmed, icon: icon, appearance: appearance, profileID: profileID)
        dismiss()
    }

    private func dismiss() {
        tabManager.isSpaceCreatorVisible = false
    }
}

/// which profile a space browses as, by icon and name
private struct ProfilePicker: View {
    @Environment(TabManager.self) private var tabManager
    @Binding var selection: Profile.ID

    var body: some View {
        Picker("Profile", selection: $selection) {
            ForEach(tabManager.profiles) { profile in
                Label { Text(profile.name) } icon: { SpaceGlyph(icon: profile.icon) }
                    .tag(profile.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}
