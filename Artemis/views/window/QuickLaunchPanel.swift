import AppKit
import SwiftUI

/// ⌘⌥N from anywhere: a corner panel that opens a url or a search in a Scout
/// window, never in the browser's tabs
@MainActor
enum QuickLaunch {
    private static var panel: NSPanel?
    private static var resignObserver: NSObjectProtocol?

    /// how far the panel sits from the top-right corner of the screen
    private static let margin: CGFloat = 24
    private static let size = NSSize(width: 560, height: 320)

    static func toggle() {
        if panel != nil { close() } else { show() }
    }

    private static func show() {
        let window = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(
            rootView: QuickLaunchView(onOpen: open(_:), onClose: close))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // it is a launcher: it should be reachable from any desktop, and over a
        // fullscreen app rather than sending you back to another one
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setContentSize(size)
        window.setFrameOrigin(corner())
        panel = window

        // activating while Artemis is already frontmost hands key straight back
        // to the browser window, and the panel closes on the spot
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        // after the focus settles: the shuffle of becoming key is itself a
        // resign for whatever held it, and it lands before the panel is up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard panel === window else { return }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { close() }
            }
        }
    }

    private static func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// what you chose, in its own Scout window
    private static func open(_ url: URL) {
        close()
        ScoutWindow.open(url)
    }

    /// top-right of whichever screen the pointer is on
    private static func corner() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: frame.maxX - size.width - margin,
            y: frame.maxY - size.height - margin)
    }
}

/// borderless panels don't take the keyboard unless they say they can
private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// the launcher's list: what you typed, then the pages you have been to that
/// match it — the same rule the command bar follows, where row 0 is always the
/// literal input
private struct QuickLaunchView: View {
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var input = ""
    @State private var matches: [HistoryEntry] = []
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    /// the trail of whichever profile the browser is showing
    private var history: HistoryStore {
        (BrowserWindows.shared.browserScope?.currentProfile ?? BrowserCore.shared.defaultProfile).history
    }

    /// enough to be useful in a glance, few enough to read at once
    private static let limit = 5

    private var rows: [Row] {
        var out: [Row] = []
        if !input.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Row(title: input, host: nil, url: nil))
        }
        out.append(
            contentsOf: matches.prefix(Self.limit).map {
                Row(
                    title: $0.title.isEmpty ? ($0.url.host() ?? $0.url.absoluteString) : $0.title,
                    host: $0.url.host(), url: $0.url)
            })
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !rows.isEmpty {
                Divider().opacity(0.5)
                list
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { isFocused = true }
        .onChange(of: input) { _, text in
            selection = 0
            matches = text.isEmpty
                ? Array(history.entries.prefix(Self.limit))
                : history.search(text, limit: Self.limit)
        }
        .onExitCommand(perform: onClose)
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search or Enter URL…", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($isFocused)
                .onSubmit(openSelection)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                QuickLaunchRow(row: row, isSelected: index == selection)
                    .onTapGesture { open(row) }
            }
        }
        .padding(8)
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        selection = (selection + offset + rows.count) % rows.count
        return .handled
    }

    private func openSelection() {
        guard rows.indices.contains(selection) else { return }
        open(rows[selection])
    }

    private func open(_ row: Row) {
        guard let url = row.url ?? URLInput.resolve(row.title) else { return }
        onOpen(url)
    }

    struct Row {
        let title: String
        let host: String?
        let url: URL?
    }
}

private struct QuickLaunchRow: View {
    let row: QuickLaunchView.Row
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 26, height: 26)
            Text(row.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            if let host = row.host {
                Text("— \(host)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.85) : .clear)
        )
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        if let host = row.host, let image = FaviconStore.shared.icon(for: host) {
            Image(nsImage: image).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: row.url == nil ? "magnifyingglass" : "globe")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .white : .secondary)
        }
    }
}
