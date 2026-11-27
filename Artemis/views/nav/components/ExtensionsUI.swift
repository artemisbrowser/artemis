// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Shared extension action icon

/// one extension's action: a click runs it or opens its popup, a right-click
/// pins, opens options, disables or removes it. drawn by both the url-bar strip
/// and the dropdown grid
private struct ExtensionActionButton: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.chromeInk) private var chromeInk
    let ext: InstalledExtension
    var boxSize: CGFloat = 26
    /// the dropdown grid's form: an always-visible plate and a pin badge
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
                ExtensionPopupContainer(action: popupAction) { showPopup = false }
            }
        }
        // closing the popover must close the popup page, or its web view and any
        // hung state it holds carry over to the next open
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
        if let icon = extensions.action(for: ext)?.icon(for: CGSize(width: iconSize, height: iconSize))
            ?? ext.icon(size: iconSize)
        {
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
                extensions.openOptionsPage(for: ext)
            }
        }
        Divider()
        Button("Disable") { extensions.setEnabled(ext, false, in: extensions.currentProfile) }
        Button("Remove…", role: .destructive) {
            // Settings' question, as an `NSAlert`: a SwiftUI alert won't attach from inside a popover
            let alert = NSAlert()
            alert.messageText = "Remove \(ext.name)?"
            alert.informativeText = "This deletes the extension and its data from Artemis."
            alert.addButton(withTitle: "Remove").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { extensions.remove(ext) }
        }
    }

    private func handleClick() {
        let action = extensions.action(for: ext)
        if action?.presentsPopup == true {
            // a click is the gesture that grants activeTab; Chrome grants it before the popup opens
            if let tab = extensions.actionTab { ext.context.userGesturePerformed(in: tab) }
            popupAction = action
            showPopup = true
        } else {
            extensions.performAction(for: ext)
        }
    }
}

// MARK: - Popup host

/// an action's popup, behind a real-sized placeholder until WebKit has laid its page
/// out (an unsized popover opens as an empty blob). WebKit sends no notice of that, so
/// this polls. `onClose` runs when the extension closes the popup itself
struct ExtensionPopupContainer: View {
    let action: WKWebExtension.Action
    let onClose: () -> Void
    @State private var webView: WKWebView?
    @State private var failed = false

    var body: some View {
        if let webView {
            ExtensionPopupView(webView: webView, owner: action.webExtensionContext?.uniqueIdentifier, onClose: onClose)
        } else if failed {
            Text("This extension's popup didn't open.")
                .foregroundStyle(.secondary)
                .padding(20)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: 360, height: 460)
                .task {
                    for poll in 0..<100 {
                        guard action.webExtensionContext?.isLoaded == true else { break }
                        if let view = action.loadedPopupWebView, poll >= 20 || PopupWebViewHost.isLaidOut(view) {
                            webView = view
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if !Task.isCancelled { failed = true }
                }
        }
    }
}

/// an extension action's popup web view at the size its content asks for
private struct ExtensionPopupView: View {
    let webView: WKWebView
    let owner: String?
    let onClose: () -> Void
    @State private var closeWatch: PopupCloseWatch?

    var body: some View {
        PopupWebViewHost(webView: webView)
            // as in Chrome, a popup belongs to the tab it opened on
            .onChange(of: ExtensionManager.shared.actionTab?.id) { onClose() }
            .onDisappear { owner.map { _ = ExtensionManager.shared.shownPopups.remove($0) } }
            .onAppear {
                owner.map { _ = ExtensionManager.shared.shownPopups.insert($0) }
                closeWatch = PopupCloseWatch(webView, onClose: onClose)
                // first responder so a popup's text field takes typing without a
                // click; deferred, as the popover's window doesn't exist at onAppear
                DispatchQueue.main.async {
                    webView.window?.makeFirstResponder(webView)
                }
            }
    }
}

/// WebKit sizes a popup web view to its content within Chrome's 50×50…800×600 and
/// invalidates its intrinsic size on every change, which re-asks `sizeThatFits`
private struct PopupWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        let content = nsView.intrinsicContentSize
        return CGSize(width: min(max(content.width, 50), 800), height: min(max(content.height, 50), 600))
    }

    static func isLaidOut(_ webView: WKWebView) -> Bool {
        !webView.isLoading && webView.intrinsicContentSize.width >= 50 && webView.intrinsicContentSize.height >= 50
    }
}

/// stands in as the popup's UI and navigation delegate, forwarding all to WebKit's own,
/// to hear `window.close()` and a crashed page: WebKit then closes the web view but
/// can't close the popover it doesn't own
private final class PopupCloseWatch: NSObject, WKUIDelegate, WKNavigationDelegate {
    private let inner: NSObject
    private let onClose: () -> Void

    init?(_ webView: WKWebView, onClose: @escaping () -> Void) {
        guard let inner = webView.uiDelegate as? NSObject else { return nil }
        self.inner = inner
        self.onClose = onClose
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || inner.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { inner }

    func webViewDidClose(_ webView: WKWebView) {
        (inner as? WKUIDelegate)?.webViewDidClose?(webView)
        onClose()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        (inner as? WKNavigationDelegate)?.webViewWebContentProcessDidTerminate?(webView)
        onClose()
    }
}

// MARK: - Pinned strip (lives in the url bar)

/// the pinned extensions' icons in the url pill; zero-width when none are pinned
struct PinnedExtensionsBar: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        let pinned = extensions.enabledExtensions(in: tabManager).filter(\.isPinned)
        if !pinned.isEmpty {
            HStack(spacing: 2) {
                ForEach(pinned) { ext in
                    ExtensionActionButton(ext: ext, boxSize: 22)
                }
            }
        }
    }
}

// MARK: - Dropdown grid (lives in the site-settings popover)

/// the "Extensions" block of the site-settings popover: every enabled
/// extension's icon in a grid, then an add button
struct ExtensionsDropdownSection: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(TabManager.self) private var tabManager
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
                ForEach(extensions.enabledExtensions(in: tabManager)) { ext in
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
                AddSourceRow(title: "From Disk…", subtitle: "Folder, .zip, .xpi, .crx, Safari app", icon: "folder") {
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
        addError = nil
        isAdding = true
        Task {
            do {
                let ext = try await extensions.installFromDisk(url)
                await ExtensionInstallFlow.finalize(ext, manager: extensions)
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }
}

/// a row in the "add extension" source chooser
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

// MARK: - Install

/// the open panel for sideloading: an unpacked folder, a .zip, .xpi or .crx, or a Safari extension's app
enum ExtensionPicker {
    @MainActor static func run() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Extension"
        panel.message = "Choose an extension folder, a .zip / .xpi / .crx archive, or a Safari extension's app."
        var types: [UTType] = [.folder, .zip, .applicationBundle, .applicationExtension]
        if let xpi = UTType(filenameExtension: "xpi") { types.append(xpi) }
        if let crx = UTType(filenameExtension: "crx") { types.append(crx) }
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// finishes every install once the extension is parsed but still disabled:
/// the consent gate then enables it or removes it
enum ExtensionInstallFlow {
    @MainActor static func finalize(_ ext: InstalledExtension, manager: ExtensionManager) async {
        // enabled in the current profile only; Settings › Extensions adds others
        if ExtensionConsent.confirm(for: ext) {
            manager.setEnabled(ext, true, in: manager.currentProfile)
        } else {
            manager.remove(ext)
        }
    }
}

/// what a parsed extension asks for, before any of it runs, needing an explicit
/// yes. an `NSAlert`, since a SwiftUI sheet won't attach from inside a popover
private enum ExtensionConsent {
    @MainActor static func confirm(for ext: InstalledExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install “\(ext.name)”?"

        var lines = ["This extension will be able to:"] + ext.consentLines.map { "• \($0)" }
        lines.append("\n" + ext.consentCaution)
        alert.informativeText = lines.joined(separator: "\n")

        if let icon = ext.icon(size: 64) { alert.icon = icon }
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
