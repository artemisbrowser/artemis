// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI
import WebKit

/// what the user sees of a task at work: its new tabs arriving, and its mark where it acts
extension AgentBridge {
    /// the tools whose act has a spot on the page for the mark to go to first
    private static let aimed: Set = ["click", "hover", "fill", "type_text", "press_key"]

    /// how long the mark hovers before the agent acts, when the page is on screen, ms
    static let dwell = 350

    /// a tab about to open in the space the window shows peeks a collapsed sidebar first, so it is seen arriving
    func glance(at space: Space, in manager: TabManager, for task: AgentTask) async {
        guard space.id == manager.currentSpace.id, manager.isSidebarCollapsed, Self.isOnScreen(manager) else { return }
        manager.sidebarGlanceRequest += 1
        try? await Task.sleep(for: .seconds(Motion.sidebarSpring.settlingDuration))
    }

    /// runs once the act may go ahead: a task's tab comes forward while the user follows the task, and the
    /// mark goes beside the element, then hovers for `dwell` where it is seen. An outside client's mark shows
    /// only on a tab already in view, and nothing of focus moves for it
    func aim(_ name: String, _ arguments: [String: Any], on tab: BrowserTab, following task: AgentTask?) async {
        guard Self.aimed.contains(name) else { return }
        if let task, let manager = task.manager, !manager.isShowing(tab), task.isWatched(in: manager) { manager.focus(tab) }
        let seen = BrowserWindows.shared.allManagers.contains { $0.isShowing(tab) && Self.isOnScreen($0) }
        guard seen || task != nil else { return }
        let uid = name == "type_text" || name == "press_key" ? "" : arguments["uid"] as? String ?? ""
        let said = try? await tab.webView.callAsyncJavaScript(
            AgentPage.library + "return A.aim(uid);", arguments: ["uid": uid], contentWorld: AgentPage.world)
        let point = (said as? String)?.split(separator: " ").compactMap { Double($0) } ?? []
        guard point.count == 2 else { return }
        AgentSprite.aim(over: tab.webView, at: CGPoint(x: point[0], y: point[1]))
        if seen { try? await Task.sleep(for: .milliseconds(Self.dwell)) }
    }

    /// an outside client's call, with its mark where it acts
    func marked(
        _ name: String, _ arguments: [String: Any], on tab: BrowserTab, _ run: () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        await aim(name, arguments, on: tab, following: nil)
        defer { AgentSprite.acted(on: tab.webView) }
        return try await run()
    }

    private static func isOnScreen(_ manager: TabManager) -> Bool {
        BrowserWindows.shared.window(of: manager)?.occlusionState.contains(.visible) == true
    }
}
