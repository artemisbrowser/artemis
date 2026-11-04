// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

extension UserDefaults {
    /// when on (the default), a drag-rearrange re-evens every split level so the
    /// panes stay as balanced as possible; off preserves the existing ratios
    var autoResizeSplitOnDrag: Bool {
        object(forKey: "autoResizeSplitOnDrag") as? Bool ?? true
    }
}
