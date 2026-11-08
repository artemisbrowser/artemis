// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

extension InstalledExtension {
    /// toolbar/menu icon for the action, falling back to the extension icon
    func icon(size: CGFloat) -> NSImage? {
        let dimension = CGSize(width: size, height: size)
        return webExtension.actionIcon(for: dimension) ?? webExtension.icon(for: dimension)
    }
}
