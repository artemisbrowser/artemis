import SwiftUI

extension UserDefaults {
    /// when on (the default), a drag-rearrange re-evens every split level so the
    /// panes stay as balanced as possible; off preserves the existing ratios
    var autoResizeSplitOnDrag: Bool {
        object(forKey: "autoResizeSplitOnDrag") as? Bool ?? true
    }
}
