// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// KVC on private keys: where this OS lacks the accessor, a read is nil and a write does nothing,
/// never NSUndefinedKeyException. a read needs a getter named exactly `key`
extension NSObject {
    func spiValue(forKey key: String) -> Any? {
        responds(to: NSSelectorFromString(key)) ? value(forKey: key) : nil
    }

    /// KVC's own setter search: `set<Key>:`, then `_set<Key>:`
    func setSPIValue(_ value: Any?, forKey key: String) {
        let name = key.prefix(1).uppercased() + key.dropFirst()
        guard responds(to: NSSelectorFromString("set\(name):")) || responds(to: NSSelectorFromString("_set\(name):"))
        else { return }
        setValue(value, forKey: key)
    }
}
