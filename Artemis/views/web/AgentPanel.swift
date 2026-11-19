// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the built-in agent's panel on the window edge opposite the sidebar: a view of its own so the
/// conversation's changes invalidate it rather than the window body
struct AgentPanel: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage(AgentTask.enabledKey) private var isEnabled = false
    @State private var isListing = false
    /// stays up while the panel slides away, then lets go of its views and shortcuts
    @State private var isMounted = false

    var body: some View {
        Group {
            if !isMounted {
                Color.clear
            } else if !isEnabled {
                AgentSetup()
            } else if let task = tabManager.agentTask {
                if SpaceLock.shared.isLocked(task.space) {
                    Label("This chat's space is locked.", systemImage: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else if isListing {
                    AgentChatList(task: task, isListing: $isListing)
                } else {
                    AgentConversation(task: task, isListing: $isListing)
                        .id(task.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: tabManager.agentTask?.id) { isListing = false }
        .task(id: tabManager.isAgentPanelVisible) {
            guard !tabManager.isAgentPanelVisible else { return isMounted = true }
            try? await Task.sleep(for: .seconds(Motion.sidebarSpring.settlingDuration))
            if !Task.isCancelled { isMounted = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent")
    }
}

/// what the panel shows until the agent is turned on
private struct AgentSetup: View {
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn on the agent?")
                .font(.system(size: 13, weight: .semibold))
            Text("It runs on Claude Code on this Mac, under your Claude account. What it does counts against that plan.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Not Now") { tabManager.isAgentPanelVisible = false }
                Button("Turn On") {
                    AgentTask.isEnabled = true
                    tabManager.showAgent()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent setup")
    }
}

/// the profile's saved chats, newest first; one opened here replaces the chat in the panel
private struct AgentChatList: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.chromeInk) private var ink
    let task: AgentTask
    @Binding var isListing: Bool
    @State private var renaming: UUID?
    @State private var draft = ""
    @State private var isConfirmingDeleteAll = false
    @FocusState private var isNaming: Bool

    private var profile: Profile { BrowserCore.shared.profile(of: tabManager.currentSpace) }

    /// chats open in another window, which only that window may continue
    private var elsewhere: Set<UUID> {
        Set(BrowserWindows.shared.mainManagers.filter { $0 !== tabManager }.compactMap { $0.agentTask?.chatID })
    }

    var body: some View {
        let chats = AgentChats.shared.chats(in: profile)
        let elsewhere = elsewhere
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HoverIconButton("chevron.left", size: 12, weight: .semibold, boxSize: AgentConversation.slim) { isListing = false }
                    .chromeGlass(in: .circle, interactive: true)
                    .tooltip("Back to the chat")
                    .accessibilityLabel("Back")
                Text("Chats")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)
            VStack(spacing: SidebarMetrics.standard.tabSpacing) {
                AgentMenuRow(symbol: "square.and.pencil", title: "New Chat", isChosen: false, inChrome: true) {
                    isListing = false
                    tabManager.showAgent(fresh: true)
                }
                AgentMenuRow(
                    symbol: "eye.slash", title: "New Throwaway Chat", note: "Never saved.", isChosen: false, inChrome: true
                ) {
                    isListing = false
                    tabManager.showAgent(fresh: true, throwaway: true)
                }
            }
            .padding(.horizontal, 8)
            if task.isWorking {
                Text("Opening another chat stops this task. It stays saved.")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            ink.opacity(0.12)
                .frame(height: 1)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            if chats.isEmpty {
                Text("No saved chats.")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.6))
                    .padding(.horizontal, 14)
            }
            ScrollView {
                VStack(spacing: SidebarMetrics.standard.tabSpacing) {
                    ForEach(chats) { chat in row(chat, isElsewhere: elsewhere.contains(chat.id)) }
                }
                .padding(.horizontal, 8)
            }
            .clippedPastSides()
            if !chats.isEmpty {
                Button { isConfirmingDeleteAll = true } label: {
                    Text("Delete All Chats…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .frame(height: AgentConversation.slim)
                        .chromeGlass(in: .capsule, interactive: true)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .padding(12)
                .confirmationDialog("Delete all chats?", isPresented: $isConfirmingDeleteAll) {
                    Button("Delete All Chats", role: .destructive) {
                        AgentChats.shared.delete(since: .distantPast, in: profile)
                    }
                } message: {
                    Text("Every saved chat in this profile is deleted from this Mac.")
                }
            }
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chats")
    }

    @ViewBuilder
    private func row(_ chat: AgentChat, isElsewhere: Bool) -> some View {
        if renaming == chat.id {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isNaming)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .padding(.horizontal, SidebarMetrics.standard.rowLeadingPadding - 8)
                .frame(height: SidebarMetrics.standard.rowHeight)
                .background(RowHighlight(opacity: 0.12))
                .onAppear { isNaming = true }
                .onSubmit { finishRenaming() }
                .onChange(of: isNaming) { if !isNaming { finishRenaming() } }
                .onKeyPress(.escape) {
                    renaming = nil
                    return .handled
                }
        } else {
            AgentMenuRow(
                title: chat.name.isEmpty ? "Untitled" : chat.name,
                note: isElsewhere ? "Open in another window" : chat.updated.formatted(.relative(presentation: .named)),
                isChosen: chat.id == task.chatID, inChrome: true
            ) {
                isListing = false
                tabManager.openAgentChat(chat)
            }
            .disabled(isElsewhere)
            .contextMenu {
                Button("Rename…") {
                    draft = chat.name
                    renaming = chat.id
                }
                Button("Delete", role: .destructive) { AgentChats.shared.delete(chat.id, in: profile) }
            }
        }
    }

    private func finishRenaming() {
        guard let id = renaming else { return }
        renaming = nil
        AgentChats.shared.rename(id, to: draft, in: profile)
    }
}

private struct AgentConversation: View {
    @Environment(TabManager.self) private var tabManager
    let task: AgentTask
    @Binding var isListing: Bool
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// Bypass was picked and waits for the warning to be answered
    @State private var isWarning = false
    @State private var isChoosingMode = false
    @State private var isChoosingEngine = false
    @AppStorage(AgentModel.storageKey) private var model = AgentModel.stored
    @AppStorage(AgentEffort.storageKey) private var effort = AgentEffort.stored
    @Environment(\.chromeInk) private var ink

    /// the mode the panel shows as chosen
    private var mode: AgentTask.Mode { isWarning ? .bypass : task.mode }

    private func note(_ mode: AgentTask.Mode) -> String {
        switch mode {
        case .manual: "Asks before each action, unless you allow the site."
        case .auto: "Works on its own. A safety check stops risky actions."
        case .bypass where task.mode == .bypass && !task.isFree: "Works like Auto until it knows which model answers."
        case .bypass: "Asks only before deleting, sharing or sensitive steps. Ends with this task."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transcript
            if let question = task.questions.first {
                AgentQuestionCard(task: task, question: question)
            }
            if isWarning { warning }
            composer
        }
        .task(id: tabManager.agentFocusRequest) {
            // focus is refused until the field is laid out at the panel's open width
            for _ in 0..<20 {
                isFocused = true
                try? await Task.sleep(for: .milliseconds(50))
                if isFocused || Task.isCancelled { break }
            }
        }
        .onChange(of: isFocused, initial: true) { tabManager.isAgentFieldFocused = isFocused }
        .onDisappear { tabManager.isAgentFieldFocused = false }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if task.chatID == nil {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.6))
                    .tooltip("Throwaway chat, never saved")
                    .accessibilityLabel("Throwaway chat")
            }
            Spacer(minLength: 0)
            HoverIconButton("list.bullet", standalone: true) { isListing = true }
                .tooltip("Chats")
                .accessibilityLabel("Chats")
            HoverIconButton("square.and.pencil", standalone: true) { tabManager.showAgent(fresh: true) }
                .tooltip("New chat")
                .accessibilityLabel("New Chat")
            HoverIconButton("xmark", size: 12, standalone: true) { tabManager.isAgentPanelVisible = false }
                .tooltip("Hide")
                .accessibilityLabel("Hide")
        }
        .padding(.horizontal, 12)
        .padding(.top, BrowserToolbar.top)
        .padding(.bottom, 8)
    }

    /// who answers: the model it said it is, else the last one that alias named, else the alias; and the effort
    private var engineButton: some View {
        let running = task.launched
        let alias = running?.model ?? model, chosenEffort = running?.effort ?? effort
        let id = task.model ?? UserDefaults.standard.string(forKey: AgentModel.seenKey + alias.rawValue)
        let name = id.map(AgentModel.name) ?? alias.label
        let short = name.split(separator: " ", maxSplits: 1)
        let full = "Claude Code · \(name) · \(chosenEffort.label)"
        return Button { isChoosingEngine.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                Text(full)
                Text("\(name) · \(chosenEffort.label)")
                Text(short.count == 2 ? "\(short[0].prefix(1)) \(short[1]) \(chosenEffort.short)" : "\(name) \(chosenEffort.short)")
            }
            .lineLimit(1)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: Self.slim)
            .chromeGlass(in: .capsule, interactive: true)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .layoutPriority(-1)
        .tooltip("\(full) effort")
        .accessibilityLabel("Model and effort")
        .accessibilityValue(full)
        .onChange(of: task.model, initial: true) {
            if let id = task.model { UserDefaults.standard.set(id, forKey: AgentModel.seenKey + alias.rawValue) }
        }
        // the leading edge holds still while the label changes width
        .popover(isPresented: $isChoosingEngine, attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: Self.slim, height: Self.slim))), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AgentModel.allCases) { choice in
                    AgentMenuRow(title: choice.label, note: choice.note, isChosen: choice == model) { model = choice }
                }
                Divider()
                    .padding(.vertical, 4)
                AgentEffortSlider(effort: $effort)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                if let running, running.model != model || running.effort != effort {
                    Text("Applies from the next task.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            }
            .padding(6)
            .frame(width: 240)
        }
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Bypass never asks. A page can trick the agent into acting as you on any site you are signed in to.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            HStack {
                Button("Cancel") { isWarning = false }
                Spacer(minLength: 0)
                Button("Turn On With \(OwnerUnlock.method)") {
                    Task {
                        await task.choose(.bypass)
                        isWarning = false
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var modeButton: some View {
        HoverIconButton(size: 12, weight: .regular, boxSize: Self.slim) { isChoosingMode.toggle() } icon: {
            Image(systemName: mode.symbol)
                .foregroundStyle(mode == .bypass ? AnyShapeStyle(.orange) : AnyShapeStyle(.foreground))
        }
        .chromeGlass(in: .circle, interactive: true)
        .tooltip("\(mode.rawValue) mode")
        .accessibilityLabel("Mode: \(mode.rawValue)")
        .popover(isPresented: $isChoosingMode, arrowEdge: .top) {
            VStack(spacing: 2) {
                ForEach(AgentTask.Mode.allCases) { choice in
                    AgentMenuRow(symbol: choice.symbol, title: choice.rawValue, note: note(choice), isChosen: choice == mode) {
                        isChoosingMode = false
                        isWarning = choice == .bypass && task.mode != .bypass
                        if !isWarning { Task { await task.choose(choice) } }
                    }
                }
            }
            .padding(6)
            .frame(width: 290)
        }
    }

    private var transcript: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AgentStepRun.runs(of: task.entries), id: \.first?.id) { run in
                        if run.count > 1 {
                            AgentStepRun(steps: run)
                        } else if let entry = run.first {
                            AgentEntryRow(entry: entry)
                        }
                    }
                    if task.isWorking {
                        AgentStatus(word: AgentStatus.word(doing: task.doing, isAsking: !task.questions.isEmpty))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .defaultScrollAnchor(.bottom)
            .onChange(of: task.entries.count) { scroller.scrollTo("end") }
            .onChange(of: task.questions.count) { scroller.scrollTo("end") }
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Instruct \(AgentTask.assistant)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($isFocused)
                // Return is a new line; text an input method is still composing is left to it
                .onKeyPress(.return, phases: .down) { press in
                    guard let editor = (NSApp.currentEvent?.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
                        !editor.hasMarkedText()
                    else { return .ignored }
                    if press.modifiers.contains(.command) { send() } else { editor.insertNewlineIgnoringFieldEditor(nil) }
                    return .handled
                }
            HStack(spacing: 6) {
                modeButton
                engineButton
                Spacer(minLength: 0)
                if task.isWorking {
                    Button { task.stop() } label: { capsule("Stop", tint: nil) }
                } else {
                    let empty = draft.allSatisfy(\.isWhitespace)
                    Button(action: send) { capsule("Send", shortcut: "⌘↩", tint: empty ? nil : .accentColor) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(empty)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 12))
        .padding(10)
    }

    /// the composer's controls stand as tall as the sidebar's update pill
    static let slim: CGFloat = 28

    /// the accent tint makes a glass capsule the one to press, its words white
    private func capsule(_ title: String, shortcut: String = "", tint: Color?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if !shortcut.isEmpty {
                Text(shortcut)
                    .opacity(0.7)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tint == nil ? ink.opacity(0.8) : .white)
        .padding(.horizontal, 12)
        .frame(height: Self.slim)
        .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        .modifier(ChromeGlassScheme())
        .contentShape(.capsule)
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !task.isWorking else { return }
        draft = ""
        task.send(prompt)
    }
}

private extension AgentTask.Mode {
    var symbol: String {
        switch self {
        case .manual: "hand.raised"
        case .auto: "bolt"
        case .bypass: "bolt.trianglebadge.exclamationmark"
        }
    }
}

/// Claude-style status: the word and its three dots type out, and delete back when the step kind changes
private struct AgentStatus: View {
    let word: String
    @Environment(\.chromeInk) private var ink
    @State private var shown = ""

    static func word(doing tool: String?, isAsking: Bool) -> String {
        if isAsking { return "Waiting for you" }
        switch tool {
        case "search": return "Searching"
        case "open_tab": return "Opening"
        case "navigate", "back", "forward", "reload", "wait_for", "show_tab": return "Browsing"
        case "take_snapshot", "screenshot", "list_tabs", "list_spaces": return "Reading"
        case "click", "hover": return "Clicking"
        case "fill", "type_text", "press_key", "fill_saved": return "Typing"
        case "scroll": return "Scrolling"
        default: return "Thinking"
        }
    }

    var body: some View {
        Text(shown)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink.opacity(0.6))
            .frame(height: 16, alignment: .leading)
            .task(id: word) {
                let target = word + "..."
                if Motion.reduceMotion { shown = target; return }
                while !shown.isEmpty, !target.hasPrefix(shown) {
                    shown.removeLast()
                    guard (try? await Task.sleep(for: .milliseconds(42))) != nil else { return }
                }
                while shown.count < target.count {
                    shown = String(target.prefix(shown.count + 1))
                    guard (try? await Task.sleep(for: .milliseconds(85))) != nil else { return }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(word)
            .accessibilityIdentifier("agent-status")
    }
}

/// the five efforts as stops on a capsule track; the thumb rests only on a stop
struct AgentEffortSlider: View {
    @Binding var effort: AgentEffort
    private static let height: CGFloat = 18
    private static let stops = AgentEffort.allCases

    /// the centre of stop `index` along a track `width` wide, in the track's space
    static func x(of index: Int, in width: CGFloat) -> CGFloat {
        height / 2 + CGFloat(index) * (width - height) / CGFloat(stops.count - 1)
    }

    private var index: Int { Self.stops.firstIndex(of: effort) ?? 0 }

    private func step(_ by: Int) {
        effort = Self.stops[min(max(index + by, 0), Self.stops.count - 1)]
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Effort \(Text("(\(effort.label))").foregroundStyle(.secondary))")
                .font(.system(size: 13))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack {
                    Capsule()
                        .fill(.primary.opacity(0.1))
                    ForEach(Self.stops.indices, id: \.self) { stop in
                        Circle()
                            .fill(.primary.opacity(0.3))
                            .frame(width: 4, height: 4)
                            .position(x: Self.x(of: stop, in: width), y: Self.height / 2)
                    }
                    Circle()
                        .fill(.primary.opacity(0.8))
                        .frame(width: Self.height - 4, height: Self.height - 4)
                        .position(x: Self.x(of: index, in: width), y: Self.height / 2)
                        .animation(Motion.pop, value: effort)
                }
                .contentShape(.capsule)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        let nearest = ((drag.location.x - Self.height / 2) / (width - Self.height) * CGFloat(Self.stops.count - 1)).rounded()
                        let stop = Self.stops[Int(min(max(nearest, 0), CGFloat(Self.stops.count - 1)))]
                        if stop != effort { effort = stop }
                    }
                )
            }
            .frame(width: 88, height: Self.height)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                step(-1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                step(1)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Effort")
            .accessibilityValue(effort.label)
            .accessibilityAdjustableAction { step($0 == .decrement ? -1 : 1) }
        }
    }
}

/// one choice in a panel menu: lit under the pointer, ticked when it is the one in force
private struct AgentMenuRow: View {
    var symbol: String?
    let title: String
    var note = ""
    let isChosen: Bool
    /// on the panel's backdrop rather than in a popover: the sidebar's ink and glass rows
    var inChrome = false
    let choose: () -> Void
    @Environment(\.chromeInk) private var ink
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let metrics = SidebarMetrics.standard
        Button(action: choose) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                    if !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(inChrome ? AnyShapeStyle(ink.opacity(0.6)) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if !inChrome {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(isChosen ? 1 : 0)
                }
            }
            .padding(.horizontal, inChrome ? metrics.rowLeadingPadding : 8)
            .padding(.vertical, inChrome ? 0 : 5)
            .frame(minHeight: inChrome ? metrics.rowHeight : nil)
            .foregroundStyle(inChrome ? AnyShapeStyle(ink.opacity(isEnabled ? 1 : 0.4)) : AnyShapeStyle(.primary))
            .background {
                if inChrome {
                    RowHighlight(opacity: isChosen ? 0.22 : isHovered ? 0.09 : 0, isSelected: isChosen)
                } else {
                    RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
            }
            .animation(Motion.hover, value: isHovered)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

struct AgentEntryRow: View {
    @Environment(TabManager.self) private var tabManager
    let entry: AgentTask.Entry

    private var symbol: String {
        switch entry.kind {
        case .user, .agent: ""
        case .step: Self.symbol(of: entry.act)
        case .refused: "hand.raised"
        case .problem: "exclamationmark.triangle"
        }
    }

    /// each step's own symbol, by the tool it used
    static func symbol(of act: String?) -> String {
        switch act {
        case "search": "magnifyingglass"
        case "open_tab": "plus.square.on.square"
        case "open_link": "link"
        case "navigate": "arrow.right.circle"
        case "back": "chevron.backward.circle"
        case "forward": "chevron.forward.circle"
        case "reload": "arrow.clockwise"
        case "take_snapshot": "doc.text.magnifyingglass"
        case "screenshot": "eye"
        case "click": "cursorarrow.click"
        case "hover": "cursorarrow.rays"
        case "fill": "character.cursor.ibeam"
        case "type_text": "keyboard"
        case "press_key": "command"
        case "scroll": "arrow.up.and.down"
        case "fill_saved": "key"
        case "close_tab": "xmark.square"
        case "permission": "checkmark.shield"
        default: "circle.dashed"
        }
    }

    static let acts = [
        "search", "open_tab", "open_link", "navigate", "back", "forward", "reload", "take_snapshot", "screenshot",
        "click", "hover", "fill", "type_text", "press_key", "scroll", "fill_saved", "close_tab", "permission",
    ]

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.primary.opacity(0.1), in: .rect(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            MarkdownText(source: entry.text) { tabManager.newTab(url: $0) }
        case .step, .refused, .problem:
            Label(entry.text, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(entry.kind == .step ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .lineLimit(entry.kind == .problem ? nil : 2)
        }
    }
}

/// steps in a row, shown as the latest with a chevron; a click lists them all in order
struct AgentStepRun: View {
    let steps: [AgentTask.Entry]
    @State private var isOpen = false

    /// the entries in order, each run of steps together and everything else on its own
    static func runs(of entries: [AgentTask.Entry]) -> [[AgentTask.Entry]] {
        entries.reduce(into: []) { runs, entry in
            if entry.kind == .step, runs.last?.last?.kind == .step {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
    }

    var body: some View {
        Button {
            withAnimation(Motion.hover) { isOpen.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(isOpen ? steps : Array(steps.suffix(1))) { AgentEntryRow(entry: $0) }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "\(steps.count) steps" : "\(steps.count) steps, latest: \(steps.last?.text ?? "")")
        .accessibilityHint(isOpen ? "Shows only the latest step" : "Shows every step")
    }
}

/// one question from the agent's gate. Input already on its way as it appears must not allow:
/// no key answers, and the allowing buttons are dead for `PermissionPrompt.armDelay`
private struct AgentQuestionCard: View {
    let task: AgentTask
    let question: AgentTask.Question
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.title)
                .font(.system(size: 12, weight: .semibold))
            if !question.detail.isEmpty {
                // never truncated
                ScrollView {
                    Text(question.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !question.choices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                        Button(choice) { task.answer(question, .pick(index)) }
                            .disabled(!armed)
                    }
                }
                .controlSize(.small)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    decline
                    Spacer(minLength: 0)
                    allows
                }
                VStack(alignment: .trailing, spacing: 6) {
                    allows
                    decline
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12)
        .task {
            try? await Task.sleep(for: PermissionPrompt.armDelay)
            armed = !Task.isCancelled
        }
        .onAppear { AccessibilityNotification.Announcement("The agent asks: \(question.title)").post() }
        .id(question.id)
    }

    private var decline: some View {
        Button(question.permission ? "Don't Allow" : "Decline") { task.answer(question, .refuse) }
    }

    @ViewBuilder private var allows: some View {
        if question.permission {
            Button("Allow") { task.answer(question, .once) }
                .disabled(!armed)
        } else if question.choices.isEmpty {
            if question.always {
                Button("Always allow actions on this site") { task.answer(question, .always) }
                    .disabled(!armed)
            }
            Button("Allow this action") { task.answer(question, .once) }
                .disabled(!armed)
        }
    }
}
