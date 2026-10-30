import AppKit
import SwiftUI

/// the command bar (⌘T): one input for switching tabs, opening urls, searching
/// the web, jumping between spaces and running commands
struct CommandBar: View {
    /// editing the page's address (⌘L, the url pill): starts on its url and
    /// opens in this tab
    var address = false
    /// inside the AddressBar growing out of the pill, which draws the glass
    var grown = false
    @Environment(TabManager.self) private var tabManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var selection: TextSelection?
    @State private var selectedIndex = 0
    @State private var items: [CommandItem] = []
    @State private var fill: CommandAutofill?
    /// full-text hits and engine suggestions arrive late; both are held so the
    /// item list can stay a synchronous function of what's typed
    @State private var textHits: [PageTextHit] = []
    @State private var suggestions: [String] = []
    /// hover only takes the selection once the pointer has actually moved, so a
    /// list scrolling under a resting cursor can't steal the arrow keys' place
    @State private var pointerMoved = false
    /// in screen space: a list moving under a still pointer reports hover too
    @State private var lastPointer: CGPoint?
    @State private var heldModifiers: EventModifiers = []
    @FocusState private var isFocused: Bool

    /// held by the window so the menu's ⌘1–4 can switch it mid-query
    private var scope: CommandScope? {
        get { tabManager.commandBarScope }
        nonmutating set { tabManager.commandBarScope = newValue }
    }

    /// once you pick a scope or type, the buttons fold into the field
    private var isFolded: Bool { grown || scope != nil || !query.isEmpty }

    private enum Metrics {
        /// the whole bar: the field and its buttons, or the field folded over them
        static let width: CGFloat = 780
        static let fieldHeight: CGFloat = 56
        static let padding: CGFloat = 18
        static let icon: CGFloat = 22
        static let iconGap: CGFloat = 12
        static let radius: CGFloat = 22
        static let inset: CGFloat = 8
        static let rowHeight: CGFloat = 40
        /// a scoped list scrolls past this many rows
        static let scopedRows = 9
        static let button: CGFloat = 50
        static let gap: CGFloat = 10
        static let buttons = 4 * button + 3 * gap
    }

    static let addressFieldHeight: CGFloat = 44
    static let addressFontSize: CGFloat = 16
    /// where the typed text starts, from the bar's leading edge
    static let textLeading = Metrics.padding + Metrics.icon + Metrics.iconGap

    private var fieldHeight: CGFloat { grown ? Self.addressFieldHeight : Metrics.fieldHeight }

    private var engine: CommandBarEngine { CommandBarEngine(manager: tabManager) }

    var body: some View {
        // a capsule while it's only the field, a card once results hang from it
        let shape = RoundedRectangle(
            cornerRadius: items.isEmpty ? fieldHeight / 2 : Metrics.radius,
            style: .continuous)
        // the buttons are drawn first and never move off their row, so the field
        // widens over them as they slide behind it
        ZStack(alignment: .topTrailing) {
            if !grown { scopeButtons }
            field(shape)
                .padding(.trailing, isFolded ? 0 : Metrics.gap + Metrics.buttons)
        }
        .frame(maxWidth: Metrics.width)
        .padding(.horizontal, grown ? 0 : 24)
        .animation(Motion.pop, value: isFolded)
        .animation(Motion.pop, value: items.isEmpty)
        .onAppear {
            if address { startOnAddress() }
            refresh()
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: tabManager.commandBarFocusRequest) {
            if address && !grown { startOnAddress() }
            isFocused = true
        }
        .onDisappear { scope = nil }
        // folding re-hosts the field, which drops its focus
        .onChange(of: isFolded) { isFocused = true }
        .onModifierKeysChanged(mask: [.shift, .command, .option]) { _, now in
            heldModifiers = now
        }
        .onChange(of: query) {
            enterScopeIfTyped()
            // a suggestion for what you typed a moment ago is still right while
            // you're extending it, and wrong the moment you aren't
            let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
            suggestions.removeAll { !$0.lowercased().hasPrefix(typed) }
            selectedIndex = 0
            pointerMoved = false
            refresh()
        }
        .onChange(of: scope) {
            selectedIndex = 0
            refresh()
        }
        // searching the page-text index is async and off the main thread; the
        // short-query guard keeps a two-letter query from matching half the web
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard scope == nil, trimmed.count >= 3,
                UserDefaults.standard.bool(forKey: FullTextIndex.enabledKey)
            else {
                if !textHits.isEmpty {
                    textHits = []
                    refresh()
                }
                return
            }
            let hits = await tabManager.currentProfile.pageIndex.search(trimmed, limit: 4)
            guard !Task.isCancelled else { return }
            textHits = hits
            refresh()
        }
        // engine completions: opt-in, never from incognito, and debounced
        // so a fast typist doesn't fire a request per character
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard scope == nil, SearchSuggest.isEnabled, tabManager.kind != .incognito,
                !trimmed.isEmpty, URLInput.directURL(trimmed) == nil, !trimmed.hasPrefix("!")
            else {
                if !suggestions.isEmpty {
                    suggestions = []
                    refresh()
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let fetched = await SearchSuggest.suggestions(for: trimmed)
            guard !Task.isCancelled else { return }
            suggestions = fetched
            refresh()
        }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.tab, phases: .down) { press in
            press.modifiers.contains(.shift) ? move(-1) : acceptCompletionOrMove(1)
        }
        // plain ↵ arrives through the field's own submit; this is only the
        // modified forms, which the field doesn't answer
        .onKeyPress(.return, phases: .down) { press in
            let held = press.modifiers.intersection([.shift, .command, .option])
            guard !held.isEmpty else { return .ignored }
            executeSelected(launch: launch(for: press.modifiers))
            return .handled
        }
        .onKeyPress(.escape) {
            if address {
                close()
            } else if !query.isEmpty {
                query = ""
            } else if scope != nil {
                scope = nil
            } else {
                close()
            }
            return .handled
        }
        .onKeyPress(.delete) {
            guard query.isEmpty, scope != nil else { return .ignored }
            scope = nil
            return .handled
        }
    }

    private func startOnAddress() {
        scope = nil
        query = tabManager.selectedTab?.url?.absoluteString ?? ""
        // centred, the whole address is selected so typing replaces it
        if !grown { selection = TextSelection(range: query.startIndex..<query.endIndex) }
    }

    // MARK: - Results

    /// late results keep whatever row you'd moved to; only typing sends you back
    /// to the top, where what you typed always sits
    private func refresh() {
        let held = selectedIndex == 0 ? nil : selected?.id
        fill = scope == nil ? engine.autofill(for: query) : nil
        items = engine.items(
            input: query, scope: scope, textHits: textHits, suggestions: suggestions)
        selectedIndex =
            held.flatMap { id in items.firstIndex { $0.id == id } }
            ?? min(selectedIndex, max(items.count - 1, 0))
    }

    private var selected: CommandItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    @discardableResult
    private func move(_ delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .handled }
        pointerMoved = false
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        return .handled
    }

    /// ⇥ arms the site search a lone word names, else finishes the host the bar is
    /// offering, else walks the list
    private func acceptCompletionOrMove(_ delta: Int) -> KeyPress.Result {
        if scope == nil, let bang = Bangs.tabTarget(query) {
            query = "!\(bang.trigger) "
            return .handled
        }
        if let fill, !fill.completion.isEmpty {
            query = fill.host
            return .handled
        }
        return move(delta)
    }

    private func launch(for modifiers: EventModifiers) -> CommandLaunch {
        if modifiers.contains(.shift) { return .scout }
        if modifiers.contains(.command) { return .beside }
        if modifiers.contains(.option) || address { return .current }
        return .normal
    }

    /// typing a whole mode token drops you into that mode, chip and all
    private func enterScopeIfTyped() {
        guard scope == nil, query.hasPrefix("@"), query.hasSuffix(" ") else { return }
        let token = query.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
        guard let mode = CommandScope(rawValue: token) else { return }
        enter(mode)
    }

    private func enter(_ mode: CommandScope) {
        scope = mode
        query = ""
    }

    private func executeSelected(launch: CommandLaunch) {
        guard let item = selected else { return }
        execute(item, launch: launch)
    }

    private func execute(_ item: CommandItem, launch: CommandLaunch) {
        switch item.kind {
        case .scope(let mode):
            enter(mode)
            return
        // a bang picked while still typing its trigger arms it instead of firing
        // it: "!yt" then a query is the whole point of a bang
        case .bang(let bang, let trigger, let remainder)
        where remainder.isEmpty && bang != nil && !query.hasSuffix(" "):
            query = "!\(trigger) "
            return
        default:
            engine.run(item, input: query, launch: launch)
            close()
        }
    }

    private func close() {
        tabManager.isCommandBarVisible = false
        // the address bar shrinks back into the pill still showing what it held
        guard !grown else { return }
        query = ""
        textHits = []
        suggestions = []
    }

    // MARK: - Input

    private func field(_ shape: RoundedRectangle) -> some View {
        VStack(spacing: 0) {
            inputRow

            if !items.isEmpty {
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .frame(height: 1)
                resultsList
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(grown ? .identity : .regular, in: shape)
        // the HIG's dimming layer: text-heavy glass over a busy page stays legible
        .background(shape.fill(grown ? .clear : colorScheme == .dark ? .black.opacity(0.62) : .white.opacity(0.7)))
    }

    private var inputRow: some View {
        HStack(spacing: Metrics.iconGap) {
            fieldIcon
                .frame(width: Metrics.icon, height: Metrics.icon)

            TextField("URL", text: $query, selection: $selection, prompt: Text(prompt).foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: grown ? Self.addressFontSize : 22))
                .focused($isFocused)
                .onSubmit {
                    // pasted or expanded text can arrive with its ↵ before the rows catch up
                    refresh()
                    executeSelected(launch: launch(for: []))
                }

            if let completion {
                HStack(spacing: 6) {
                    Text(completion)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    keycap("⇥")
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.padding)
        .frame(height: fieldHeight)
    }

    /// what ⇥ would do, kept apart from the typed text so it never reads as
    /// where ↵ goes
    private var completion: String? {
        if scope == nil, let bang = Bangs.tabTarget(query) { return "Search \(bang.name)" }
        if let fill, !fill.completion.isEmpty { return fill.host }
        return nil
    }

    /// the scope you're in, else the icon of whatever ↵ would do, so the field
    /// says it before you press it
    @ViewBuilder
    private var fieldIcon: some View {
        if let scope {
            Image(systemName: scope.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(scopeTint)
        } else if query.isEmpty || selected == nil {
            symbol("magnifyingglass", size: 16)
        } else if let selected {
            rowIcon(selected, size: 20)
        }
    }

    private var prompt: String {
        switch scope {
        case .tabs: "Search open tabs"
        case .history: "Search history"
        case .actions: "Run a command"
        case .spaces: "Jump to a space"
        case nil: "Search or enter URL"
        }
    }

    /// Spotlight's browse buttons, each its own glass. they fold behind the
    /// field one after another, tabs first, and come back out in the same order
    private var scopeButtons: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(Array(CommandScope.allCases.enumerated()), id: \.element) { index, mode in
                Button {
                    scope = mode
                    isFocused = true
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: Metrics.button, height: Metrics.button)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .offset(x: isFolded ? -Metrics.button : 0)
                .opacity(isFolded ? 0 : 1)
                .allowsHitTesting(!isFolded)
                .accessibilityHidden(isFolded)
                .animation(Motion.pop.delay(Double(index) * 0.035), value: isFolded)
                .tooltip(mode.label, keys: ["⌘", "\(index + 1)"])
                .accessibilityLabel("Search \(mode.label)")
            }
        }
        .frame(height: Metrics.fieldHeight)
    }

    /// a glass space has no colour of its own, so it borrows the system's
    private var scopeTint: Color {
        let appearance = tabManager.currentSpace.appearance
        return appearance.fill == .glass ? .accentColor : appearance.accent
    }

    // MARK: - List

    private var resultsList: some View {
        let limit = scope == nil ? CommandBarEngine.rowLimit : Metrics.scopedRows
        let visible = CGFloat(min(items.count, limit))
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selectedIndex)
                            .id(item.id)
                            .onTapGesture { execute(item, launch: launch(for: heldModifiers)) }
                            .onHover { hovering in
                                if hovering, pointerMoved { selectedIndex = index }
                            }
                    }
                }
                .padding(Metrics.inset)
                .onContinuousHover { phase in
                    guard case .active = phase else { return }
                    let now = NSEvent.mouseLocation
                    if let lastPointer, lastPointer != now { pointerMoved = true }
                    lastPointer = now
                }
            }
            .scrollDisabled(items.count <= limit)
            .scrollIndicators(.never)
            .frame(height: visible * Metrics.rowHeight + Metrics.inset * 2)
            .onChange(of: selectedIndex) {
                guard let id = selected?.id else { return }
                proxy.scrollTo(id)
            }
            // a new set of results starts at the top, however far the last set
            // had been scrolled
            .onChange(of: items.map(\.id)) {
                proxy.scrollTo(items.first?.id, anchor: .top)
            }
        }
    }

    private func row(_ item: CommandItem, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            rowIcon(item, size: 18)
                .frame(width: 20, height: 20)

            HStack(spacing: 8) {
                titleText(item)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !item.hint.isEmpty {
                    Text(item.hint)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            if case .tab(let tab) = item.kind, let space = elsewhere(tab) {
                HStack(spacing: 4) {
                    SpaceGlyph(icon: space.icon, size: 10)
                        .foregroundStyle(space.appearance.accent)
                    Text(space.name)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if isSelected {
                HStack(spacing: 6) {
                    Text(verb(item))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    keycap(keys(for: item))
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radius - Metrics.inset, style: .continuous)
                .fill(isSelected ? selectionFill : .clear)
        )
        .contentShape(Rectangle())
        // a result is one thing you can pick, named by what it is and what it
        // would do — not an icon, a title and a hint read out separately
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(verb(item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// the space's own colour marks the row ↵ will take; a glass space has none
    private var selectionFill: Color {
        let appearance = tabManager.currentSpace.appearance
        return appearance.fill == .glass ? .primary.opacity(0.1) : appearance.accent.opacity(0.28)
    }

    /// the letters that matched, emboldened, so a fuzzy hit shows its working
    private func titleText(_ item: CommandItem) -> Text {
        let characters = Array(item.title)
        guard !item.ranges.isEmpty, characters.count == item.title.utf8.count else {
            return Text(item.title)
        }
        var out = Text("")
        var cursor = 0
        for range in item.ranges where range.upperBound <= characters.count {
            if range.lowerBound > cursor {
                out = out + Text(String(characters[cursor..<range.lowerBound]))
            }
            out = out + Text(String(characters[range])).fontWeight(.semibold)
            cursor = range.upperBound
        }
        if cursor < characters.count {
            out = out + Text(String(characters[cursor...]))
        }
        return out
    }

    @ViewBuilder
    private func rowIcon(_ item: CommandItem, size: CGFloat) -> some View {
        switch item.kind {
        case .tab(let tab):
            favicon(tab.favicon, size: size)
        case .space(let space):
            SpaceGlyph(icon: space.icon, size: size - 4)
                .foregroundStyle(space.appearance.accent)
        case .action(let action): symbol(action.symbol, size: size - 4)
        case .bang: symbol("exclamationmark.circle", size: size - 4)
        case .suggestion, .search: symbol("magnifyingglass", size: size - 4)
        case .scope(let mode): symbol(mode.symbol, size: size - 4)
        case .closed, .history, .pageText, .openURL:
            favicon(FaviconStore.shared.icon(for: item.url?.host()), size: size)
        }
    }

    /// favicons are drawn for white pages, so they sit on a white tile: a black
    /// logo on the dark panel would otherwise vanish
    @ViewBuilder
    private func favicon(_ image: NSImage?, size: CGFloat) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size - 4, height: size - 4)
                .frame(width: size + 2, height: size + 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.white.opacity(colorScheme == .dark ? 0.92 : 0)))
        } else {
            symbol("globe", size: size - 4)
        }
    }

    private func symbol(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size))
            .foregroundStyle(.secondary)
    }

    /// the space a listed tab lives in, when that isn't the one you're looking at
    private func elsewhere(_ tab: BrowserTab) -> Space? {
        guard !tab.isEssential, let space = tabManager.space(of: tab),
            space.id != tabManager.selectedSpaceID
        else { return nil }
        return space
    }

    private func keycap(_ cap: String) -> some View {
        Text(cap)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.primary.opacity(0.08))
            )
    }

    // MARK: - What ↵ does

    /// the launch a held modifier would pick, for results it changes
    private func heldLaunch(for item: CommandItem) -> CommandLaunch {
        let launch = launch(for: heldModifiers)
        switch item.kind {
        case .tab: return launch == .beside ? .beside : .normal
        case .space, .action, .scope: return .normal
        default: return launch
        }
    }

    private func keys(for item: CommandItem) -> String {
        switch heldLaunch(for: item) {
        case .normal: "↵"
        case .scout: "⇧↵"
        case .beside: "⌘↵"
        case .current: address ? "↵" : "⌥↵"
        }
    }

    private func verb(_ item: CommandItem) -> String {
        switch heldLaunch(for: item) {
        case .scout: return "Open in Little Window"
        case .beside: return "Open in Split"
        case .current where !address: return "Open Here"
        case .current, .normal: break
        }
        switch item.kind {
        case .tab: return "Switch to Tab"
        case .space: return "Switch to Space"
        case .action(let action): return action.id == "calculate" ? "Copy" : "Run"
        case .closed: return heldLaunch(for: item) == .normal ? "Reopen" : "Open"
        case .scope: return "Narrow"
        case .bang, .suggestion: return "Search"
        case .search: return "Search \(SearchEngine.current.label)"
        case .history, .pageText, .openURL: return "Open"
        }
    }
}
