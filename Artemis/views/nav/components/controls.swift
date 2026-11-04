import SwiftUI

/// main navigation controls: `back`, `forward` and `refresh`/`stop`
///
/// in compact mode (narrow sidebar) the reload button becomes a … menu
/// holding both reload and the sidebar toggle
struct NavigationControls: View {
    @Environment(TabManager.self) private var tabManager
    var isCompact = false
    var onToggleSidebar: (() -> Void)? = nil

    var body: some View {
        // displayedContentTab so back/forward/reload track the shown page in
        // lockstep with a space switch, matching the url field
        let tab = tabManager.displayedContentTab
        let canGoForward = tab?.canGoForward == true

        // back and forward share one capsule; forward only exists while there
        // is somewhere to go, and grows out of back rather than popping in
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                back(tab)
                forward(tab)
                    .opacity(canGoForward ? 1 : 0)
                    .scaleEffect(canGoForward ? 1 : 0.4)
                    .frame(width: canGoForward ? SidebarMetrics.glassSide : 0)
            }
            .clipShape(.capsule)
            .chromeGlass(in: .capsule, interactive: true)
            .animation(Motion.pop, value: canGoForward)
            trailing(tab)
        }
    }

    private func back(_ tab: BrowserTab?) -> some View {
        HoverIconButton(
            "chevron.left", size: 14, weight: .semibold, boxSize: SidebarMetrics.glassSide,
            enabled: tab?.canGoBack == true
        ) {
            tab?.goBack()
        }
        .tooltip("Back", keys: ["⌘", "["])
    }

    private func forward(_ tab: BrowserTab?) -> some View {
        HoverIconButton(
            "chevron.right", size: 14, weight: .semibold, boxSize: SidebarMetrics.glassSide,
            enabled: tab?.canGoForward == true
        ) {
            tab?.goForward()
        }
        .tooltip("Forward", keys: ["⌘", "]"])
    }

    @ViewBuilder
    private func trailing(_ tab: BrowserTab?) -> some View {
        if isCompact {
            CompactNavMenu(onToggleSidebar: onToggleSidebar)
        } else {
            HoverIconButton(
                tab?.isLoading == true ? "xmark" : "arrow.clockwise",
                size: tab?.isLoading == true ? 12 : 14,
                enabled: tab?.url != nil,
                standalone: true
            ) {
                if tab?.isLoading == true {
                    tab?.stopLoading()
                } else {
                    tab?.reload()
                }
            }
            .tooltip(tab?.isLoading == true ? "Stop loading" : "Reload", keys: ["⌘", "R"])
        }
    }
}

/// … dropdown shown when the sidebar is too narrow for every button
private struct CompactNavMenu: View {
    @Environment(TabManager.self) private var tabManager
    var onToggleSidebar: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        let tab = tabManager.displayedContentTab

        Menu {
            Button {
                if tab?.isLoading == true {
                    tab?.stopLoading()
                } else {
                    tab?.reload()
                }
            } label: {
                Label(
                    tab?.isLoading == true ? "Stop" : "Reload Page",
                    systemImage: tab?.isLoading == true ? "xmark" : "arrow.clockwise"
                )
                .labelStyle(.titleAndIcon)  // macOS menus hide icons by default
            }
            .disabled(tab?.url == nil)

            Button {
                onToggleSidebar?()
            } label: {
                Label(
                    tabManager.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar",
                    systemImage: "sidebar.left"
                )
                .labelStyle(.titleAndIcon)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .modifier(ChromeButtonFace(isHovering: isHovering, standalone: true))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()  // exactly one button slot, like its siblings
        .onHover { isHovering = $0 }
        .tooltip("More")
    }
}

/// sidebar icon button: glyph in the shared chrome face (see `ChromeButtonFace`)
struct HoverIconButton<Icon: View>: View {
    private let size: CGFloat
    private let weight: Font.Weight
    private let boxSize: CGFloat
    private let enabled: Bool
    private let standalone: Bool
    private let action: () -> Void
    private let icon: Icon
    @State private var isHovering = false

    init(
        size: CGFloat = 13,
        weight: Font.Weight = .bold,
        boxSize: CGFloat = 28,
        enabled: Bool = true,
        standalone: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.size = size
        self.weight = weight
        self.boxSize = boxSize
        self.enabled = enabled
        self.standalone = standalone
        self.action = action
        self.icon = icon()
    }

    init(
        _ systemName: String,
        size: CGFloat = 13,
        weight: Font.Weight = .bold,
        boxSize: CGFloat = 28,
        enabled: Bool = true,
        standalone: Bool = false,
        action: @escaping () -> Void
    ) where Icon == Image {
        self.init(
            size: size, weight: weight, boxSize: boxSize, enabled: enabled, standalone: standalone, action: action
        ) {
            Image(systemName: systemName)
        }
    }

    var body: some View {
        Button(action: action) {
            icon
                .font(.system(size: size, weight: weight))
                .modifier(ChromeButtonFace(
                    isHovering: isHovering, enabled: enabled, standalone: standalone, boxSize: boxSize))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            isHovering = hovering && enabled
        }
    }
}

/// "–" and "✕" as two bars sized for a 13pt semibold glyph: stacked flat they
/// read as the minus, turned ±45° they cross
struct MinusCrossGlyph: View {
    let isCross: Bool

    var body: some View {
        ZStack {
            ForEach([45.0, -45.0], id: \.self) { angle in
                Capsule()
                    .frame(width: isCross ? 11.5 : 9.5, height: 1.75)
                    .rotationEffect(.degrees(isCross ? angle : 0))
            }
        }
        .animation(Motion.pop, value: isCross)
    }
}
