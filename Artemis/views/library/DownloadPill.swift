import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar footer's view of downloads under way: the newest one, or a count,
/// with its progress along the bottom. Finished, a click opens the file (⌘-click
/// shows it in Finder); before that it opens Library › Downloads.
struct DownloadPill: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.chromeInk) private var ink
    /// where a new download's flight ends, when no Library button is on screen
    var isLanding = false
    @State private var isHovering = false
    private var downloads: DownloadManager { .shared }

    var body: some View {
        if let item = downloads.shelf.first {
            let many = downloads.shelf.count > 1
            Button { act(on: item, many: many) } label: {
                HStack(spacing: 7) {
                    symbol(for: item)
                    Text(many ? "\(downloads.shelf.count) downloads" : label(for: item))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if isHovering, item.state != .finished || many {
                        Button { dismiss(item, many: many) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 16, height: 16)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .tooltip(item.state == .downloading ? "Cancel" : "Dismiss")
                    } else {
                        Text(status(for: item, many: many))
                            .monospacedDigit()
                            .foregroundStyle(ink.opacity(0.6))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28)
                .overlay(alignment: .bottomLeading) { progress }
                .chromeGlass(in: .capsule, interactive: true)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .background(isLanding || tabManager.kind == .incognito ? DownloadLanding() : nil)
            .onHover { isHovering = $0 }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    /// draw-only, so progress never re-lays out the footer
    private var progress: some View {
        Capsule()
            .fill(ink.opacity(0.35))
            .frame(height: 2)
            .scaleEffect(x: downloads.fraction, anchor: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
            .opacity(downloads.shelf.contains { $0.state == .downloading } ? 1 : 0)
            .animation(Motion.fade, value: downloads.fraction)
    }

    @ViewBuilder
    private func symbol(for item: DownloadItem) -> some View {
        switch item.state {
        case .finished: Image(systemName: "checkmark.circle.fill")
        case .failed: Image(systemName: "exclamationmark.circle")
        default:
            if item.isPrivate {
                Image(systemName: "arrow.down.circle")
            } else {
                let type = UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data
                Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().frame(width: 16, height: 16)
            }
        }
    }

    private func label(for item: DownloadItem) -> String {
        let name = item.isPrivate ? "Private download" : item.filename
        return item.state == .failed ? "Failed · \(name)" : name
    }

    private func status(for item: DownloadItem, many: Bool) -> String {
        if many || item.state == .downloading { return "\(Int(downloads.fraction * 100))%" }
        return item.state == .finished ? "Open" : ""
    }

    private func act(on item: DownloadItem, many: Bool) {
        if !many, item.state == .finished {
            if NSEvent.modifierFlags.contains(.command) { item.revealInFinder() } else { item.open() }
            downloads.dismiss(item)
        } else {
            UserDefaults.standard.set("Downloads", forKey: "libraryLastMode")
            tabManager.isLibraryOpen = true
        }
    }

    private func dismiss(_ item: DownloadItem, many: Bool) {
        let items = many ? downloads.shelf : [item]
        for item in items {
            if item.state == .downloading { item.cancel() } else { downloads.dismiss(item) }
        }
    }
}

/// progress drawn around the Library button while anything is downloading
struct DownloadRing: View {
    @Environment(\.chromeInk) private var ink
    private var downloads: DownloadManager { .shared }

    var body: some View {
        let running = downloads.shelf.contains { $0.state == .downloading }
        Circle()
            .trim(from: 0, to: running ? max(0.04, downloads.fraction) : 1)
            .stroke(ink.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1)
            .opacity(running ? 1 : 0)
            .animation(Motion.fade, value: downloads.fraction)
            .animation(Motion.fade, value: running)
            .allowsHitTesting(false)
    }
}
