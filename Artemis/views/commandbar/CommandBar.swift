// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

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
    /// false while it closes: it takes no seed and no focus
    var live: () -> Bool = { true }
    @Environment(TabManager.self) private var tabManager
    @Environment(\.colorScheme) private var colorScheme
    /// the field's text: what was typed, then any host completion, selected
    @State private var query = ""
    /// what was typed, without the completion
    @State private var typed = ""
    /// the text `autofill` last wrote, so its own write isn't read as typing
    @State private var written: String?
    @State private var selection: TextSelection?
    @State private var selectedIndex = 0
    @State private var items: [CommandItem] = []
    /// the host completion standing selected in the field
    @State private var fill: CommandAutofill?
    /// the bang ⇥ would arm, set in `refresh()`
    @State private var tabBang: Bang?
    /// full-text hits and engine suggestions arrive late; both are held so the
    /// item list can stay a synchronous function of what's typed
    @State private var textHits: [PageTextHit] = []
    @State private var suggestions: [String] = []
    /// the page's declared feeds, read once the bar is up
    @State private var pageFeeds: [URL] = []
    /// hover only takes the selection once the pointer has actually moved, so a
    /// list scrolling under a resting cursor can't steal the arrow keys' place
    @State private var pointerMoved = false
    /// in screen space: a list moving under a still pointer reports hover too
    @State private var lastPointer: CGPoint?
    @State private var heldModifiers: EventModifiers = []
    @State private var flagsMonitor: Any?
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

    private var engine: CommandBarEngine { CommandBarEngine(manager: tabManager, pageFeeds: pageFeeds) }

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
            syncModifiers()
            // a pointer move carries the keys held now, so it unsticks a missed release
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { event in
                syncModifiers(event.modifierFlags)
                return event
            }
            refresh()
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: tabManager.commandBarSeed, initial: true) {
            guard live(), !address, let seed = tabManager.commandBarSeed else { return }
            tabManager.commandBarSeed = nil
            scope = nil
            query = seed
        }
        .onChange(of: tabManager.commandBarFocusRequest) {
            guard live() else { return }
            if address && !grown { startOnAddress() }
            syncModifiers()
            isFocused = true
        }
        .onDisappear {
            scope = nil
            flagsMonitor.map(NSEvent.removeMonitor)
            flagsMonitor = nil
        }
        .task {
            guard tabManager.kind == .main, let tab = tabManager.selectedTab,
                !SpaceLock.shared.isLocked(tabManager.currentSpace)
            else { return }
            let feeds = await tab.declaredFeeds()
            guard !feeds.isEmpty, tabManager.selectedTab === tab else { return }
            pageFeeds = feeds
            refresh()
        }
        // folding re-hosts the field, which drops its focus
        .onChange(of: isFolded) { isFocused = true }
        .onChange(of: query) { _, new in
            guard new != written else { return written = nil }
            written = nil
            enterScopeIfTyped()
            autofill(new)
            // a suggestion for what you typed a moment ago is still right while
            // you're extending it, and wrong the moment you aren't
            let prefix = typed.trimmingCharacters(in: .whitespaces).lowercased()
            suggestions.removeAll { !$0.lowercased().hasPrefix(prefix) }
            selectedIndex = 0
            pointerMoved = false
            refresh()
        }
        .onChange(of: scope) {
            fill = nil
            selectedIndex = 0
            refresh()
        }
        // searching the page-text index is async and off the main thread; the
        // short-query guard keeps a two-letter query from matching half the web
        .task(id: typed) {
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
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
        .task(id: typed) {
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
            guard scope == nil, SearchSuggest.isEnabled, tabManager.kind != .incognito,
                !trimmed.isEmpty, !URLInput.isPathLike(trimmed), URLInput.directURL(trimmed) == nil,
                !(Bangs.isEnabled && (Bangs.partial(trimmed) != nil || Bangs.split(trimmed) != nil))
            else {
                if !suggestions.isEmpty {
                    suggestions = []
                    refresh()
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let fetched = await SearchSuggest.suggestions(for: trimmed, profile: tabManager.currentProfile.id)
            guard !Task.isCancelled else { return }
            suggestions = fetched
            refresh()
        }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.tab, phases: .down) { press in
            press.modifiers.contains(.shift) ? move(-1) : acceptCompletionOrMove(1)
        }
        // the field moves the caret past the completion itself
        .onKeyPress(keys: [.rightArrow, .end], phases: .down) { _ in
            acceptFill()
            return .ignored
        }
        // taken before the field sees it, so the field never ends editing on the way out
        .onKeyPress(.return, phases: .down) { press in
            let held = press.modifiers.intersection([.shift, .command, .option])
            guard !held.isEmpty || PerfFlags.takesReturnBeforeField else { return .ignored }
            submit(press.modifiers)
            return .handled
        }
        .onKeyPress(.escape) {
            if fill != nil {
                query = typed
            } else if address {
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
        // the address the pill shows: a tab waking or mid-load has no committed url yet
        let tab = tabManager.displayedContentTab
        query = (tab?.requestedURL ?? tab?.url ?? tab?.lastAttemptedURL ?? tab?.pendingURL)?.absoluteString ?? ""
        // centred, the whole address is selected so typing replaces it
        if !grown { selection = TextSelection(range: query.startIndex..<query.endIndex) }
    }

    // MARK: - Results

    /// late results keep whatever row you'd moved to; only typing sends you back
    /// to the top, where what you typed always sits
    private func refresh() {
        let held = selectedIndex == 0 ? nil : selected?.id
        tabBang = scope == nil ? Bangs.tabTarget(typed) : nil
        items = engine.items(
            input: typed, scope: scope, textHits: textHits, suggestions: suggestions, autofill: fill)
        selectedIndex =
            held.flatMap { id in items.firstIndex { $0.id == id } }
            ?? min(selectedIndex, max(items.count - 1, 0))
    }

    private var selected: CommandItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .handled }
        pointerMoved = false
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        // focus stays in the field, so VoiceOver says nothing of the row on its own
        if let selected { AccessibilityNotification.Announcement("\(selected.title), \(kindName(selected))").post() }
        return .handled
    }

    /// a host is completed only on a single typed character at the end: never on
    /// a deletion, a paste or text still being composed
    private func autofill(_ text: String) {
        let before = typed
        typed = text
        fill = nil
        // the field runs ahead of `text` when keys come faster than SwiftUI updates
        guard let editor = BrowserWindows.shared.window(of: tabManager)?.firstResponder as? NSTextView,
            editor.string == text, !editor.hasMarkedText(), scope == nil,
            text.count == before.count + 1, text.hasPrefix(before), let found = engine.autofill(for: text)
        else { return }
        // a vibrant field's selection only blends with the glass once the bar's morph settles
        if let field = editor.delegate as? NSTextField,
            let plain = field.superview?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            field.appearance = NSAppearance(named: plain)
        }
        fill = found
        query = text + found.completion
        written = query
        let completion = query.index(query.startIndex, offsetBy: text.count)..<query.endIndex
        selection = TextSelection(range: completion)
        // in the editor this turn: SwiftUI's own write lands later, over any key typed meanwhile
        editor.string = query
        editor.setSelectedRange(NSRange(completion, in: query))
    }

    /// the completion becomes typed text
    private func acceptFill() {
        guard fill != nil else { return }
        fill = nil
        typed = query
    }

    /// ⇥ arms the site search a lone word names, else accepts the host completion,
    /// else walks the list
    private func acceptCompletionOrMove(_ delta: Int) -> KeyPress.Result {
        if let tabBang {
            query = "!\(tabBang.trigger) "
            return .handled
        }
        if fill != nil {
            acceptFill()
            selection = TextSelection(insertionPoint: query.endIndex)
            return .handled
        }
        return move(delta)
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

    private func submit(_ modifiers: EventModifiers) {
        // pasted or expanded text can arrive with its ↵ before onChange(of: query) reads it
        if query != typed + (fill?.completion ?? "") {
            typed = query
            fill = nil
        }
        refresh()
        executeSelected(launch: engine.launch(for: modifiers, address: address))
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
            engine.run(item, input: typed, launch: launch)
            close()
        }
    }

    private func close() {
        tabManager.isCommandBarVisible = false
        // the address bar shrinks back into the pill still showing what it held, and
        // a closing ⌘T bar fades as it was: its next open is a fresh mount
        guard !grown, !PerfFlags.leavesClosingBarAlone else { return }
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
                .accessibilityHidden(true)

            TextField("URL", text: $query, selection: $selection, prompt: Text(prompt).foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: grown ? Self.addressFontSize : 22))
                .focused($isFocused)
                .onSubmit { submit([]) }

            if let tabBang {
                HStack(spacing: 6) {
                    Text("Search \(tabBang.name)")
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
                            .onTapGesture {
                                syncModifiers()
                                execute(item, launch: engine.launch(for: heldModifiers, address: address))
                            }
                            .accessibilityAction { execute(item, launch: engine.launch(for: [], address: address)) }
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
        .accessibilityValue([kindName(item), item.hint, verb(item)].filter { !$0.isEmpty }.joined(separator: ", "))
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
            favicon(for: tab.faviconHost, size: size)
        case .space(let space):
            SpaceGlyph(icon: space.icon, size: size - 4)
                .foregroundStyle(space.appearance.accent)
        case .action(let action): symbol(action.symbol, size: size - 4)
        case .bang: symbol("exclamationmark.circle", size: size - 4)
        case .suggestion, .search: symbol("magnifyingglass", size: size - 4)
        case .scope(let mode): symbol(mode.symbol, size: size - 4)
        case .closed, .history, .pageText, .openURL:
            favicon(for: item.url?.host(), size: size)
        }
    }

    /// favicons are drawn for white pages, so in dark mode they sit on a white tile.
    /// a light one, drawn for a dark page, sits bare there and on a black tile in light mode
    @ViewBuilder
    private func favicon(for host: String?, size: CGFloat) -> some View {
        if let image = FaviconStore.shared.icon(for: host) {
            let isLight = FaviconStore.shared.isLightIcon(for: host)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size - 4, height: size - 4)
                .frame(width: size + 2, height: size + 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isLight
                                ? .black.opacity(colorScheme == .light ? 0.92 : 0)
                                : .white.opacity(colorScheme == .dark ? 0.92 : 0)))
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

    /// ⌘T's own ⌘ can lift before the bar hears it, so the flags are read live, not only on flagsChanged
    private func syncModifiers(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        var now: EventModifiers = []
        if flags.contains(.shift) { now.insert(.shift) }
        if flags.contains(.command) { now.insert(.command) }
        if flags.contains(.option) { now.insert(.option) }
        if heldModifiers != now { heldModifiers = now }
    }

    /// the launch a held modifier would pick, for results it changes
    private func heldLaunch(for item: CommandItem) -> CommandLaunch {
        let launch = engine.launch(for: heldModifiers, address: address)
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

    /// what a result is, said before what it would do
    private func kindName(_ item: CommandItem) -> String {
        switch item.kind {
        case .tab: "Open tab"
        case .closed: "Recently closed"
        case .history, .pageText: "History"
        case .space: "Space"
        case .action: "Command"
        case .bang: "Search shortcut"
        case .suggestion: "Suggestion"
        case .openURL: "Address"
        case .search: "Web search"
        case .scope: "Scope"
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
