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
    static let minDot: CGFloat = 6

    let slot: CGFloat
    /// the row, one space expanded, is no wider than `width`
    let fits: Bool

    init(count: Int, width: CGFloat) {
        let room = (width - Self.full) / CGFloat(max(1, count - 1))
        slot = max(Self.minDot, min(Self.dot, room))
        fits = room >= Self.minDot
    }
}

/// a row of space icons at the bottom of the sidebar
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
            let layout = SpaceRowLayout(count: tabManager.spaces.count, width: geo.size.width - 2 * inset)
            let row = icons(layout).padding(.horizontal, inset)
            // a row too long for its slot scrolls inside it, never under the library or profile
            Group {
                if layout.fits { row } else { ScrollView(.horizontal) { row }.scrollIndicators(.hidden) }
            }
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
                    && event.modifierFlags.intersection([.shift, .control, .option, .command]) == .control
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
            let frame = proxy.frame(in: .named(SidebarDragState.contentSpace))
            // a dot scrolled out of the row takes no drop
            guard let port = proxy.bounds(of: .scrollView) else { return frame }
            let shown = port.intersection(CGRect(origin: .zero, size: proxy.size))
            return shown.offsetBy(dx: frame.minX, dy: frame.minY)
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
                    Task { await confirmDeleting(space, in: tabManager) }
                } label: {
                    Label("Delete Space…", systemImage: "trash").labelStyle(.titleAndIcon)
                }
            }
        }
    }
}

/// a delete takes every tab, pin and folder with the space, so it is confirmed;
/// a locked space has the owner open it before its tab count shows
private func confirmDeleting(_ space: Space, in tabManager: TabManager) async {
    guard await SpaceLock.shared.unlock(space, to: "delete the \u{201C}\(space.name)\u{201D} space") else { return }
    let tabs = space.tabs.count
    let detail = tabs == 0 ? "" : tabs == 1 ? "Its 1 tab goes with it. " : "Its \(tabs) tabs go with it. "
    guard confirmDelete("Delete \u{201C}\(space.name)\u{201D}?", detail + "You can undo this.") else { return }
    tabManager.deleteSpace(space)
}

/// name / icon / appearance editor shown in a popover from the space header
struct SpaceEditor: View {
    @Environment(TabManager.self) private var tabManager
    let space: Space
    @State private var name = ""
    @State private var appearance = SpaceAppearance()
    // the space wears `appearance` live, uncommitted until the tick;
    // `original` is the committed theme the x and a close go back to
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
                            set: { on in
                                Task {
                                    if on {
                                        SpaceLock.shared.requireUnlock(for: space)
                                    } else {
                                        await SpaceLock.shared.stopRequiringUnlock(for: space)
                                    }
                                    tabManager.scheduleSave()
                                }
                            }))
                    .font(.system(size: 12))
                    Text("Locks again whenever Artemis is in the background.")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.5))
                }

                if tabManager.spaces.count > 1 {
                    Divider()
                    Button(role: .destructive) {
                        Task { await confirmDeleting(space, in: tabManager) }
                    } label: {
                        Label("Delete Space…", systemImage: "trash")
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .onAppear {
            name = space.name
            appearance = space.appearance
            original = appearance
            grainPct = Int(appearance.grain * 100)
            tabManager.isSidebarPopoverOpen = true  // keep the overlay pinned
        }
        // roll the grain label off an animated mirror (the slider stays direct)
        .onChange(of: appearance.grain) { _, v in
            withAnimation(.snappy(duration: 0.25)) { grainPct = Int(v * 100) }
        }
        // switching to gradient needs ≥2 colours for a mesh
        .onChange(of: appearance.fill) { _, fill in
            if fill == .gradient, appearance.colors.count < 2 {
                let base = appearance.colors.first ?? RGBA(0.2, 0.16, 0.42)
                appearance.colors = [base, RGBA(base.r * 1.5, base.g * 1.5, base.b * 1.5)]
            }
        }
        .onChange(of: appearance) { _, worn in tabManager.wearTheme(worn, on: space) }
        .onDisappear {
            commitName()
            tabManager.revertTheme()
            tabManager.isSidebarPopoverOpen = false
        }
    }

    // MARK: - Sections

    private var iconSection: some View {
        section("ICON") {
            IconRow(icon: Binding(get: { space.icon }, set: { tabManager.updateSpace(space, icon: $0) }), name: name)
        }
    }

    private var fillSection: some View {
        section("FILL") {
            HStack(spacing: 5) {
                GlassSegmented(
                    options: SpaceFill.allCases.map { ($0, $0.label) },
                    selection: $appearance.fill)

                Spacer(minLength: 6)
                GlassIconButton("xmark", label: "Discard changes", tint: .red.opacity(0.85)) {
                    appearance = original
                }
                GlassIconButton("checkmark", label: "Save", tint: .green.opacity(0.9)) {
                    tabManager.commitTheme()
                    original = appearance
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
                frostSlider("Sidebar", $appearance.sidebarFrost)
                frostSlider("Background", $appearance.backgroundFrost)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brightness").font(.system(size: 12)).foregroundStyle(.primary.opacity(0.7))
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").frame(width: 17)
                        Slider(value: $appearance.glassBrightness, in: 0...1)
                        Image(systemName: "sun.max").frame(width: 17)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.7))
                }
            }
        }
    }

    /// clear (left) → frosted (right), matching the macOS slider
    private func frostSlider(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.7))
            HStack(spacing: 10) {
                GlassEndIcon(blurred: false)
                    .offset(x: 3.5)  // nudge the clear icon toward the slider
                Slider(value: value, in: 0...1)
                GlassEndIcon(blurred: true)
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

    /// committed at once, unlike the theme: a profile change rebuilds the
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

/// a titled block of the space editor or creator
private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        // section label in the sidebar's muted-ink vocabulary (primary is the
        // popover analog of the backdrop-adaptive chromeInk)
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.45))
        content()
    }
}

/// the ICON row: the glyph and its name, opening the icon browser in a second
/// popover, over a strip of icons suggested by the space's name
private struct IconRow: View {
    @Binding var icon: String
    let name: String
    @State private var showingPicker = false
    @State private var suggested: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            pickerButton
            if !suggested.isEmpty {
                HStack(spacing: 4) {
                    ForEach(suggested.prefix(9), id: \.self) { glyph in
                        SpaceGlyph(icon: glyph, size: 14)
                            .foregroundStyle(.primary.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .background {
                                if glyph == icon {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.18))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { icon = glyph }
                            .accessibilityElement()
                            .accessibilityLabel(glyph.isEmojiIcon ? glyph : glyph.replacingOccurrences(of: ".", with: " "))
                            .accessibilityAddTraits(glyph == icon ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { icon = glyph }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Suggested icons")
            }
        }
        .task(id: name) { await suggestIcons(for: name) { suggested = $0 } }
    }

    private var pickerButton: some View {
        Button {
            showingPicker.toggle()
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
        .popover(isPresented: $showingPicker, arrowEdge: .trailing) {
            IconPicker(icon: $icon, name: name)
        }
    }
}

/// icons for `name` from its words at once, then again with the model's ideas
/// when Intelligence is on. debounced for typing
private func suggestIcons(for name: String, _ deliver: ([String]) -> Void) async {
    try? await Task.sleep(for: .milliseconds(250))
    guard !Task.isCancelled else { return }
    deliver(await IconSearch.shared.suggestions(for: name))
    guard Intelligence.isEnabled, let ideas = await Intelligence.shared.iconIdeas(for: name),
        !Task.isCancelled
    else { return }
    deliver(await IconSearch.shared.suggestions(for: name, ideas: ideas))
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
/// highlighted pill that slides to the selected option — the Apple Music tab
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
                    .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { withAnimation(Motion.pop) { selection = opt.value } }
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
    /// what the icon is for (a space's or profile's name), for the Suggested section
    var name = ""

    private enum Kind: String, CaseIterable { case icons = "Icons", emoji = "Emoji" }
    @State private var kind: Kind
    @State private var query = ""
    @State private var results: [String] = []
    @State private var suggested: [String] = []
    @State private var askingModel = false

    init(icon: Binding<String>, name: String = "") {
        _icon = icon
        self.name = name
        // open on whichever kind the current icon already is
        _kind = State(initialValue: icon.wrappedValue.isEmojiIcon ? .emoji : .icons)
    }

    /// both tabs browse as macOS-style categories; a search collapses to a flat
    /// result grid
    private var showsCategories: Bool { query.isEmpty }

    /// the category sections for the current tab, normalised to (title, glyphs),
    /// under the name's suggestions
    private var sections: [(String, [String])] {
        let mine = suggested.filter { $0.isEmojiIcon == (kind == .emoji) }
        return (mine.isEmpty ? [] : [("Suggested", mine)])
            + (kind == .emoji
                ? Emojis.categories.map { ($0.name, $0.emoji.map(\.glyph)) }
                : SFSymbols.categories.map { ($0.name, $0.symbols) })
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

            TextField("Search, or describe it", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .modifier(EditorField())
                .overlay(alignment: .trailing) {
                    if askingModel {
                        ProgressView().controlSize(.mini).padding(.trailing, 10)
                    }
                }

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
        .task(id: name) { await suggestIcons(for: name) { suggested = $0 } }
        .task(id: "\(kind.rawValue)\n\(query)") { await search(query, emoji: kind == .emoji) }
    }

    /// matches by meaning at once; a phrase, or a word that found little, then asks
    /// the model what it brings to mind
    private func search(_ query: String, emoji: Bool) async {
        guard !query.isEmpty else { return }
        results = await IconSearch.shared.search(query, emoji: emoji)
        guard Intelligence.isEnabled, query.contains(" ") || results.count < 8 else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        askingModel = true
        defer { askingModel = false }
        guard let ideas = await Intelligence.shared.iconIdeas(for: query), !Task.isCancelled else { return }
        results = await IconSearch.shared.search(query, emoji: emoji, ideas: ideas)
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

/// the glass slider's end glyphs: a panel under a capsule that crosses its lower right
/// corner. clear = 1pt outlines, the panel's edges breaking where the capsule crosses;
/// blurred = both filled, the panel grown 0.5pt all round and cut 0.5pt clear of the capsule
private struct GlassEndIcon: View {
    var blurred: Bool

    /// in the glyph's top-left space, pt
    private static let panel = CGRect(x: 2.25, y: 3, width: 11.5, height: 8.5)
    private static let capsule = CGRect(x: 4.5, y: 5, width: 13.5, height: 10)

    private var tint: Color { Color.primary.opacity(blurred ? 0.8 : 0.6) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if blurred { blurredContent } else { clearContent }
        }
        // the capsule overhangs this box's right edge by 1pt
        .frame(width: 17, height: 15, alignment: .topLeading)
    }

    // MARK: Clear

    @ViewBuilder private var clearContent: some View {
        let panel = Self.panel, capsule = Self.capsule
        let radius = capsule.height / 2
        // the capsule's semicircle centres in the panel's own space
        let centreY = capsule.minY - panel.minY + radius
        let left = CGPoint(x: capsule.minX - panel.minX + radius, y: centreY)
        let right = CGPoint(x: capsule.maxX - panel.minX - radius, y: centreY)

        // capsule first, then the panel on top, so the panel's dipping bottom
        // line shows at the capsule edge instead of hiding under the capsule
        Capsule()
            .strokeBorder(tint, lineWidth: 1)
            .frame(width: capsule.width, height: capsule.height)
            .offset(x: capsule.minX, y: capsule.minY)

        RefractedPanel(
            cornerRadius: 1.5, capCenterLeft: left, capCenterRight: right, capRadius: radius,
            bottomDrop: 1.5, bottomRunIn: 1.5, bottomShift: 1.5,
            rightDrop: 1, rightRunIn: 1, rightShift: 1
        )
        .stroke(tint, lineWidth: 1)
        .frame(width: panel.width, height: panel.height)
        .offset(x: panel.minX, y: panel.minY)
    }

    // MARK: Blurred

    @ViewBuilder private var blurredContent: some View {
        let panel = Self.panel.insetBy(dx: -0.5, dy: -0.5)
        let cut = Self.capsule.insetBy(dx: -0.5, dy: -0.5)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: panel.width, height: panel.height)
                .offset(x: panel.minX, y: panel.minY)
            Capsule()
                .fill(.black)
                .frame(width: cut.width, height: cut.height)
                .offset(x: cut.minX, y: cut.minY)
                .blendMode(.destinationOut)
        }
        .compositingGroup()

        Capsule()
            .fill(tint)
            .frame(width: Self.capsule.width, height: Self.capsule.height)
            .offset(x: Self.capsule.minX, y: Self.capsule.minY)
    }
}

/// the clear icon's panel: a rounded rectangle broken where the capsule crosses its
/// bottom and right edges, drawn as two open subpaths, an outside frame and an
/// inside corner piece whose two free tips curve away like refracted glass
private struct RefractedPanel: Shape {
    var cornerRadius: CGFloat
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

            section("ICON") { IconRow(icon: $icon, name: name) }
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
                .accessibilityAddTraits(selectedPresetID == preset.id ? .isSelected : [])
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
