import AppKit
import SwiftUI

/// a "freeze-frame" theme preview: the real space you're editing is shown
/// wearing the in-progress theme, with every interaction disabled so you can
/// just look at the colour. pressing any key or mouse button returns to the
/// editor. a transparent layer swallows hover/scroll/clicks from the real chrome
/// underneath; a local event monitor catches the exit input.
struct GradientPreview: View {
    let onExit: () -> Void
    @State private var monitor: Any?

    var body: some View {
        ZStack(alignment: .top) {
            // block all interaction with the real window beneath
            Color.black.opacity(0.0001).contentShape(Rectangle())

            banner.padding(.top, 14)
        }
        .ignoresSafeArea()
        .onAppear(perform: startMonitor)
        .onDisappear(perform: stopMonitor)
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill").font(.system(size: 12, weight: .semibold))
            Text("Previewing this theme on your space — interactions are off. Press any key or click to return to the editor.")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private func startMonitor() {
        // any key or mouse-button press exits; the event is swallowed so it can't
        // act on whatever is underneath
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            onExit()
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
