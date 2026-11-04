// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// opens an incognito window from anywhere; each browses in a jar of its own that
/// goes when it closes
@MainActor
enum IncognitoWindow {
    static let id = "incognito"

    /// the scene opener, captured from the first browser window that appears
    static var openWindow: OpenWindowAction?
    /// whose history the next window reads for suggestions
    fileprivate static var pendingParent: Profile.ID?

    static func open() {
        pendingParent = BrowserWindows.shared.browserScope?.currentProfile.id
        openWindow?(id: id)
    }
}

/// one incognito window: its own manager over one private space, never in the
/// shared spaces and never restored
struct IncognitoWindowRoot: View {
    @State private var box = IncognitoManagerBox()

    var body: some View {
        let manager = box.resolve()
        MainView()
            .environment(manager)
            .environment(manager.tooltipState)
            .background(WindowBinder(manager: manager))
    }
}

@MainActor
private final class IncognitoManagerBox {
    private var manager: TabManager?

    func resolve() -> TabManager {
        if let manager { return manager }
        let core = BrowserCore.shared
        let made = TabManager(core: core, kind: .incognito)
        made.openIncognitoSpace(
            parent: core.profile(IncognitoWindow.pendingParent) ?? core.defaultProfile)
        IncognitoWindow.pendingParent = nil
        manager = made
        return made
    }
}
