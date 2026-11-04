// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// what Send Feedback is about to send: the user's words and the boxes they
/// ticked. A private window offers neither its page nor a screenshot.
@Observable
final class FeedbackDraft {
    enum Category: String, CaseIterable {
        case bug, idea, other

        var prompt: String {
            switch self {
            case .bug: "What happened, and what did you expect?"
            case .idea: "What would make Artemis better?"
            case .other: "What’s on your mind?"
            }
        }
    }

    /// `issue`: the public issue the report became, which the sheet links
    enum Phase: Equatable { case writing, sending, refused, done(String, issue: URL?) }

    var category = Category.bug
    var message = ""
    var includesScreenshot = true
    var includesPage = false
    var includesDiagnostics = true
    /// the words go to the public issue tracker unless this is on
    var keepsPrivate = false
    var phase = Phase.writing
    /// the window as it was when the sheet opened, a JPEG at most 1600 px wide
    var screenshot: Data? {
        didSet { preview = screenshot.flatMap(NSImage.init(data:)) }
    }
    private(set) var preview: NSImage?
    let page: URL?
    let isPrivate: Bool

    init(page: URL?, isPrivate: Bool) {
        self.page = isPrivate ? nil : page
        self.isPrivate = isPrivate
    }

    /// over `manager`'s window, which comes to the front; a draft already open
    /// there is kept
    static func open(in manager: TabManager) {
        guard let window = BrowserWindows.shared.window(of: manager) else { return }
        window.makeKeyAndOrderFront(nil)
        guard manager.feedback == nil else { return }
        let isPrivate = manager.kind == .incognito || manager.selectedTab?.isPrivate == true
        let draft = FeedbackDraft(page: manager.selectedTab?.url, isPrivate: isPrivate)
        if !isPrivate { draft.capture(window) }
        manager.feedback = draft
    }

    /// the report, holding only what the boxes allow
    func body(email: String, diagnostics: [String: any Sendable]?, events: [Diagnostics.Event]) -> Data? {
        // within the server's limits, in UTF-16 units: 8000 of message, 2048 of address
        var units = 0
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).prefix {
            units += $0.utf16.count
            return units <= 8000
        }
        var feedback: [String: any Sendable] = ["category": category.rawValue, "message": String(text)]
        if keepsPrivate { feedback["private"] = true }
        if !email.isEmpty { feedback["email"] = email }
        if includesPage, let page { feedback["page"] = String(page.absoluteString.prefix(2048)) }
        let shot = includesScreenshot && !isPrivate ? screenshot : nil
        return Reports.body(
            kind: "feedback", feedback: feedback,
            diagnostics: includesDiagnostics ? diagnostics : nil,
            events: includesDiagnostics ? events : [],
            attachments: shot.map {
                [["name": "screenshot.jpg", "type": "image/jpeg", "data": $0.base64EncodedString()]]
            } ?? [])
    }

    func send(email: String, from manager: TabManager) {
        phase = .sending
        let report = body(
            email: email.trimmingCharacters(in: .whitespaces),
            diagnostics: Reports.snapshot(of: manager), events: Array(Diagnostics.recent.suffix(50)))
        Task {
            let outcome: Reports.Outcome = if let report { await Reports.deliver(report, automatic: false) } else { .rejected }
            switch outcome {
            case .sent(let issue?):
                // stays up so the link can be followed
                phase = .done("Posted as #\(issue.lastPathComponent)", issue: issue)
                return
            case .sent(nil): phase = .done("Thanks, sent", issue: nil)
            case .queued: phase = .done("Will send when you’re online", issue: nil)
            case .rejected:
                phase = .refused
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            if manager.feedback === self { manager.feedback = nil }
        }
    }

    /// AppKit draws the chrome and each visible page adds its own snapshot, since
    /// web content never reaches `cacheDisplay`. All in-process, so no
    /// screen-recording permission is ever asked for
    private func capture(_ window: NSWindow) {
        guard let content = window.contentView,
            let chrome = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: chrome)
        let pages = Self.visiblePages(in: content).map { ($0, content.convert($0.bounds, from: $0)) }
        let size = content.bounds.size
        let flipped = content.isFlipped
        // the chrome alone first: a hung page never answers its snapshot
        screenshot = Self.jpeg(chrome, [], size: size, flipped: flipped)
        Task {
            var shots: [(NSImage, NSRect)] = []
            for (page, frame) in pages {
                if let image = try? await page.takeSnapshot(configuration: nil) { shots.append((image, frame)) }
            }
            if !shots.isEmpty { screenshot = Self.jpeg(chrome, shots, size: size, flipped: flipped) }
        }
    }

    /// in paint order, skipping pages hidden, faded out, or parked off the window
    /// as a neighbouring space's page is
    private static func visiblePages(in root: NSView) -> [WKWebView] {
        func walk(_ view: NSView) -> [WKWebView] {
            guard let page = view as? WKWebView else { return view.subviews.flatMap(walk) }
            let opaque = sequence(first: page as NSView, next: { $0.superview }).allSatisfy {
                $0.alphaValue > 0.01 && ($0.layer?.opacity ?? 1) > 0.01
            }
            let onWindow = root.convert(page.bounds, from: page).intersects(root.bounds)
            return !page.isHiddenOrHasHiddenAncestor && opaque && onWindow ? [page] : []
        }
        return walk(root)
    }

    private static func jpeg(
        _ chrome: NSBitmapImageRep, _ pages: [(NSImage, NSRect)], size: NSSize, flipped: Bool
    ) -> Data? {
        let width = min(1600, chrome.pixelsWide)
        let height = Int((Double(width) * size.height / max(size.width, 1)).rounded())
        guard width > 0, height > 0,
            let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        canvas.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(origin: .zero, size: size)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        chrome.draw(in: bounds)
        for (image, frame) in pages {
            var frame = frame
            if flipped { frame.origin.y = size.height - frame.maxY }
            image.draw(in: frame)
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

/// Send Feedback, modal over the window like the space creator
struct FeedbackSheet: View {
    @Environment(TabManager.self) private var tabManager
    @Bindable var draft: FeedbackDraft
    @AppStorage(Reports.emailKey) private var email = ""
    @AppStorage(Reports.enabledKey) private var sendsErrorReports = false
    @FocusState private var isWriting: Bool

    /// the server refuses a whole report over an address it can't reply to
    private var emailIsValid: Bool {
        let address = email.trimmingCharacters(in: .whitespaces)
        return address.isEmpty || address.utf16.count <= 254 && address.wholeMatch(of: /[^\s@]+@[^\s@]+/) != nil
    }

    private var canSend: Bool {
        draft.phase != .sending && emailIsValid
            && !draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .done(let note, let issue) = draft.phase {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(note)
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                if let issue {
                    Text("You can follow it, and anyone can add to it, on GitHub.")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                    HStack {
                        Button("Close") { tabManager.feedback = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.6))
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(issue)
                            tabManager.feedback = nil
                        } label: {
                            Text("View on GitHub")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.accentColor.opacity(0.9)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                form
            }
        }
        .padding(18)
        .frame(width: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .animation(Motion.pop, value: draft.phase)
        .onAppear { DispatchQueue.main.async { isWriting = true } }
    }

    @ViewBuilder
    private var form: some View {
        Text("Send Feedback")
            .font(.system(size: 15, weight: .semibold))

        HStack(spacing: 4) {
            ForEach(FeedbackDraft.Category.allCases, id: \.self) { category in
                Button { draft.category = category } label: {
                    Text(category.rawValue.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.primary.opacity(draft.category == category ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(draft.category == category ? .isSelected : [])
            }
        }
        .animation(Motion.hover, value: draft.category)

        TextEditor(text: $draft.message)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($isWriting)
            .accessibilityLabel(draft.category.prompt)
            .frame(height: 110)
            .padding(6)
            .background(well)
            .overlay(alignment: .topLeading) {
                if draft.message.isEmpty {
                    Text(draft.category.prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.35))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

        TextField("Email for a reply (optional)", text: $email)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(well)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.red.opacity(emailIsValid ? 0 : 0.6)))
            .accessibilityHint(emailIsValid ? "" : "Not a valid email address")

        VStack(alignment: .leading, spacing: 6) {
            if !draft.isPrivate {
                HStack(alignment: .top) {
                    Toggle("Include a screenshot of this window", isOn: $draft.includesScreenshot)
                    Spacer(minLength: 8)
                    if let preview = draft.preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .opacity(draft.includesScreenshot ? 1 : 0.35)
                            .accessibilityHidden(true)
                    }
                }
                if draft.page != nil {
                    Toggle("Include this page’s address", isOn: $draft.includesPage)
                }
            }
            Toggle("Include diagnostics", isOn: $draft.includesDiagnostics)
            // the ⓘ sits outside the checkbox: a click on a checkbox's label toggles it
            HStack(spacing: 6) {
                Toggle("Send error reports automatically", isOn: $sendsErrorReports)
                InfoButton(Reports.disclosure)
            }
            Toggle("Keep this private", isOn: $draft.keepsPrivate)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))

        Text(draft.keepsPrivate
            ? "Only the Artemis team will see this."
            : "Your message will be posted publicly on GitHub. Your email, screenshot and page address stay private.")
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)

        if draft.phase == .refused {
            Label("That couldn’t be sent. Try without the screenshot or diagnostics.", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 12))
        }

        HStack {
            Button("Cancel") { tabManager.feedback = nil }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.6))
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button { draft.send(email: email, from: tabManager) } label: {
                Text(draft.phase == .sending ? "Sending…" : "Send")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(canSend ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.12)))
                    .foregroundStyle(canSend ? .white : .primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
        }
        .padding(.top, 2)
    }

    private var well: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06))
    }
}
