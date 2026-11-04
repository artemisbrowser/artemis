// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// toggle button wearing the shared sidebar chrome face
struct SidebarToggleButton: View {
    @Environment(TabManager.self) private var tabManager
    @State private var isHovering = false

    var body: some View {
        Button {
            tabManager.isSidebarCollapsed.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .bold))
                .modifier(ChromeButtonFace(isHovering: isHovering, standalone: true))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tabManager.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", keys: ["⌘", "S"])
    }
}
