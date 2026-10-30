import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Shared extension action icon

/// a single extension's toolbar action: its icon, clickable to run the action
/// or open its popup, with a right-click menu to pin, open options, disable, or
/// remove. reused by both the url-bar pinned strip and the dropdown grid so the
/// two stay visually identical, arc-style.
struct ExtensionActionButton: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.chromeInk) private var chromeInk
    let ext: InstalledExtension
    var boxSize: CGFloat = 26
    /// tile mode (the dropdown grid): a rounded, always-visible backing plate and
    /// a pin badge, arc-style. bare mode (the url-bar strip) has neither.
    var tile: Bool = false

    @State private var isHovering = false
    @State private var showPopup = false
    @State private var popupAction: WKWebExtension.Action?

    /// bare icons match the url bar's own glyphs (a 13pt bold symbol reads ~16pt)
    private var iconSize: CGFloat { tile ? boxSize - 16 : 16 }
    private var corner: CGFloat { tile ? 11 : 6 }
    /// popover tiles take the popover's own ink; the url-bar strip takes the sidebar's
    private var ink: Color { tile ? .primary : chromeInk }
    private var plate: AnyShape {
        tile ? AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)) : AnyShape(Capsule())
    }

    var body: some View {
        Button(action: handleClick) {
            iconImage
                .frame(width: boxSize, height: boxSize)
                .background {
                    if tile { plate.fill(ink.opacity(tileFill)) } else { UrlBarHighlight(fill: ink.opacity(tileFill)) }
                }
                .overlay(alignment: .bottomTrailing) { badge }
                .overlay(alignment: .bottomLeading) { pinBadge }
                .contentShape(plate)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(ext.name)
        .contextMenu { contextMenu }
        .popover(isPresented: $showPopup, arrowEdge: .bottom) {
            if let popupAction {
                // the popup web view is created/loaded async by WebKit — present
                // a real-sized placeholder until it lands, or the popover opens
                // as an empty glass blob that only fills in on a later re-render
                ExtensionPopupContainer(action: popupAction)
            }
        }
        // a popup left open holds its web view (and whatever hung state it was
        // in) forever — Surfshark's spinner survived across opens this way.
        // closing the action tears the popup page down so every open is fresh
        .onChange(of: showPopup) { _, shown in
            if !shown {
                popupAction?.closePopup()
                popupAction = nil
            }
        }
        .onChange(of: ext.isEnabled) { _, enabled in
            if !enabled { showPopup = false }
        }
    }

    private var tileFill: Double {
        if tile { return isHovering ? 0.18 : 0.08 }
        return isHovering ? 0.13 : 0
    }

    @ViewBuilder private var iconImage: some View {
        if let icon = ext.icon(size: iconSize) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .opacity(isHovering ? 1 : 0.92)
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: tile ? 16 : 13, weight: tile ? .medium : .bold))
                .foregroundStyle(ink.opacity(isHovering ? 0.9 : 0.6))
        }
    }

    /// the little pushpin that marks a pinned extension in the grid
    @ViewBuilder private var pinBadge: some View {
        if tile && ext.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.7))
                .frame(width: 15, height: 15)
                .background(Circle().fill(.white))
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .offset(x: -3, y: 3)
        }
    }

    /// the unread badge text some actions show (e.g. a blocker's count)
    @ViewBuilder private var badge: some View {
        if let action = extensions.action(for: ext), !action.badgeText.isEmpty {
            Text(action.badgeText)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 12, minHeight: 12)
                .background(Capsule().fill(.red))
                .offset(x: 3, y: 3)
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button(ext.isPinned ? "Unpin from URL Bar" : "Pin to URL Bar") {
            extensions.togglePin(ext)
        }
        if ext.webExtension.hasOptionsPage {
            Button("Options…") {
                Task { try? await extensions.openOptionsPage(for: ext) }
            }
        }
        Divider()
        Button("Disable") { extensions.setEnabled(ext, false, in: extensions.currentProfile) }
        Button("Remove…", role: .destructive) { extensions.remove(ext) }
    }

    private func handleClick() {
        let action = extensions.action(for: ext)
        if action?.presentsPopup == true {
            // a click is the gesture that grants activeTab; Chrome grants it before the popup opens
            if let tab = extensions.currentTab { ext.context.userGesturePerformed(in: tab) }
            popupAction = action
            showPopup = true
        } else {
            extensions.performAction(for: ext)
        }
    }
}

// MARK: - Popup host

/// bridges the async gap between "user clicked" and "WebKit built the popup web
/// view": shows a fixed-size loading placeholder, polls briefly for the view
/// (there's no notification for its creation), then swaps the real popup in
struct ExtensionPopupContainer: View {
    let action: WKWebExtension.Action
    @State private var webView: WKWebView?

    var body: some View {
        if let webView {
            ExtensionPopupView(webView: webView)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: 360, height: 460)
                .task {
                    // ~5s of 50ms polls: popups are local resources, so the view
                    // appears almost immediately — the tail is pure safety
                    for _ in 0..<100 {
                        // an unloaded extension's popup has no configuration, and
                        // WebKit throws building a web view without one
                        guard action.webExtensionContext?.isLoaded == true else { return }
                        if let view = action.popupWebView {
                            webView = view
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
        }
    }
}

/// hosts an extension action's popup `WKWebView` in a SwiftUI popover. WebKit
/// drives the popup's content size; we size to it, clamped to sane bounds so a
/// misbehaving popup can't take over the screen.
struct ExtensionPopupView: View {
    let webView: WKWebView
    @State private var size = ExtensionPopupView.clamp(.zero)

    var body: some View {
        PopupWebViewHost(webView: webView)
            .frame(width: size.width, height: size.height)
            // WebKit drives the popup web view's size to the extension's own
            // content — and keeps adjusting it as the popup lays out (Surfshark
            // resizes itself well after load). track it live, or the popover
            // freezes at the first guess and slices the content off at the edge
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSView.frameDidChangeNotification, object: webView)
            ) { _ in resize() }
            .onAppear {
                webView.postsFrameChangedNotifications = true
                resize()
                // a password manager's popup opens onto a text field (unlock,
                // search); make the web view first responder so typing works
                // without a click-inside first. deferred: the popover's window
                // doesn't exist yet at onAppear
                DispatchQueue.main.async {
                    webView.window?.makeFirstResponder(webView)
                }
            }
    }

    private func resize() {
        let intrinsic = webView.intrinsicContentSize
        let reported = CGSize(
            width: intrinsic.width > 1 ? intrinsic.width : webView.frame.width,
            height: intrinsic.height > 1 ? intrinsic.height : webView.frame.height)
        let clamped = Self.clamp(reported)
        if clamped != size { size = clamped }
    }

    /// popup bounds: Chrome's own limits (800×600 max), so any popup written
    /// for Chrome fits whole — the old 520-wide cap cut wide popups' flanks off
    private static func clamp(_ reported: CGSize) -> CGSize {
        CGSize(
            width: min(max(reported.width > 1 ? reported.width : 360, 250), 800),
            height: min(max(reported.height > 1 ? reported.height : 460, 100), 600))
    }
}

private struct PopupWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Pinned strip (lives in the url bar)

/// the row of pinned extension icons that sits just left of the settings button
/// in the url pill. empty (and zero-width) when nothing is pinned, so it never
/// disturbs the bar's existing layout.
struct PinnedExtensionsBar: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        let pinned = extensions.pinnedExtensions
        // extensions don't run in incognito, so they don't offer buttons there
        if !pinned.isEmpty, tabManager.kind != .incognito {
            HStack(spacing: 2) {
                ForEach(pinned) { ext in
                    ExtensionActionButton(ext: ext, boxSize: 22)
                }
            }
        }
    }
}

// MARK: - Dropdown grid (lives in the site-settings popover)

/// the "Extensions" block inside the url-bar settings dropdown: a grid of every
/// enabled extension's icon, plus an add button, mirroring Arc's panel. shows
/// nothing but the add button when no extensions are installed.
struct ExtensionsDropdownSection: View {
    @Environment(ExtensionManager.self) private var extensions
    @State private var isAdding = false
    @State private var addError: String?
    @State private var showSourceChooser = false
    @State private var addHovering = false

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extensions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.9))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(extensions.enabledExtensions) { ext in
                    ExtensionActionButton(ext: ext, boxSize: 44, tile: true)
                }
                addButton
            }

            if let addError {
                Text(addError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var addButton: some View {
        Button { showSourceChooser = true } label: {
            Image(systemName: isAdding ? "ellipsis" : "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary.opacity(addHovering ? 0.95 : 0.7))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.primary.opacity(addHovering ? 0.18 : 0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { addHovering = $0 }
        .disabled(isAdding)
        .tooltip("Add an extension")
        // ask where to browse for extensions rather than jumping straight to Finder
        .popover(isPresented: $showSourceChooser, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                AddSourceRow(
                    title: "Chrome Web Store", subtitle: "Browse and add extensions",
                    icon: "puzzlepiece.extension"
                ) {
                    showSourceChooser = false
                    extensions.openStorePage(ExtensionStores.chromeWebStoreHome)
                }
                AddSourceRow(
                    title: "Firefox Add-ons", subtitle: "Browse and add extensions",
                    icon: "puzzlepiece.extension"
                ) {
                    showSourceChooser = false
                    extensions.openStorePage(ExtensionStores.firefoxAddonsHome)
                }
                Divider().overlay(.primary.opacity(0.08)).padding(.vertical, 2)
                AddSourceRow(title: "From Disk…", subtitle: "Folder, .zip, .xpi, .crx", icon: "folder") {
                    showSourceChooser = false
                    pickAndInstall()
                }
            }
            .padding(6)
            .frame(width: 240)
        }
    }

    private func pickAndInstall() {
        guard let url = ExtensionPicker.run() else { return }
        runInstall { try await extensions.installFromDisk(url) }
    }

    /// shared install-and-finalize wrapper
    private func runInstall(_ install: @escaping () async throws -> InstalledExtension) {
        addError = nil
        isAdding = true
        Task {
            do {
                let ext = try await install()
                await ExtensionInstallFlow.finalize(ext, manager: extensions)
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }
}

/// a row in the "add extension" source chooser, styled like the other sidebar
/// action rows (icon + title, hover highlight)
private struct AddSourceRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.8))
            .padding(.horizontal, 8)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.13 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Store-page install banner

/// shared open-panel for sideloading: accepts an unpacked folder or a packed
/// .zip / .xpi / .crx archive
enum ExtensionPicker {
    @MainActor static func run() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Extension"
        panel.message = "Choose an unpacked extension folder, or a .zip / .xpi / .crx archive."
        var types: [UTType] = [.folder, .zip]
        if let xpi = UTType(filenameExtension: "xpi") { types.append(xpi) }
        if let crx = UTType(filenameExtension: "crx") { types.append(crx) }
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// finishes any install once the extension is parsed (but still disabled):
/// shows the consent gate and either enables it or removes it. shared by every
/// entry point — disk, store URL, and catalog — so they behave identically.
enum ExtensionInstallFlow {
    @MainActor static func finalize(_ ext: InstalledExtension, manager: ExtensionManager) async {
        // on where it was installed; Settings › Extensions adds other profiles
        if ExtensionConsent.confirm(for: ext) {
            manager.setEnabled(ext, true, in: manager.currentProfile)
        } else {
            manager.remove(ext)  // declined → leave nothing behind
        }
    }
}

/// the security gate: after an extension is parsed (but before anything runs),
/// show exactly what it's asking for and require an explicit yes. an NSAlert
/// works from any context — including inside the url-bar popover, where a SwiftUI
/// sheet wouldn't attach cleanly.
enum ExtensionConsent {
    @MainActor static func confirm(for ext: InstalledExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install “\(ext.name)”?"

        var lines = ["This extension will be able to:"] + ext.consentLines.map { "• \($0)" }
        lines.append("\nOnly install extensions you trust.")
        alert.informativeText = lines.joined(separator: "\n")

        if let icon = ext.icon(size: 64) { alert.icon = icon }
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
