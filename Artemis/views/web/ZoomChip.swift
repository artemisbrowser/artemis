import SwiftUI

/// the page zoom, floated in the card's top corner while it isn't 100%, so a site
/// you once zoomed doesn't look broken months later. click resets it
struct ZoomChip: View {
    let tab: BrowserTab
    @State private var isHovering = false

    var body: some View {
        if abs(tab.zoomLevel - ZoomStore.defaultZoom) > 0.001 {
            Button {
                tab.resetZoom()
            } label: {
                Text("\(Int((tab.zoomLevel * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .onHover { isHovering = $0 }
            .tooltip("Reset Zoom", keys: ["⌘", "0"])
            .contextMenu {
                Button("Zoom In") { tab.zoomIn() }
                Button("Zoom Out") { tab.zoomOut() }
                Button("Actual Size") { tab.resetZoom() }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topTrailing)))
        }
    }
}
