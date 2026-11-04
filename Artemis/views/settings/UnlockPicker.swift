// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the section title over the unlock pickers, named for what this Mac's sheet asks for
struct UnlockHeader: View {
    var body: some View {
        InfoLabel(
            "Ask for \(OwnerUnlock.method)",
            info: "Locking, sleeping or switching user always asks again. These apply to every profile.")
    }
}

/// how often `kind` asks the device owner; a looser choice needs a check first, and Never a confirm
struct UnlockPicker: View {
    let kind: OwnerUnlock.Kind
    let info: String
    @AppStorage private var policy: UnlockPolicy

    init(_ kind: OwnerUnlock.Kind, info: String) {
        self.kind = kind
        self.info = info
        _policy = AppStorage(wrappedValue: kind.standard, kind.key)
    }

    var body: some View {
        Picker(selection: Binding(get: { policy }, set: { choice in Task { await choose(choice) } })) {
            ForEach(UnlockPolicy.allCases) { option in
                if option == .minute || option == .untilQuit { Divider() }
                Text(option.title).tag(option)
            }
        } label: {
            InfoLabel(kind.rawValue.capitalized, info: info)
        }
    }

    private func choose(_ choice: UnlockPolicy) async {
        guard choice.isLooser(than: policy) else { return policy = choice }
        if choice == .never {
            let alert = NSAlert()
            alert.messageText = "Never ask before using \(kind.rawValue)?"
            alert.informativeText = "Anyone using this Mac could use your saved \(kind.rawValue)."
            alert.addButton(withTitle: "Never Ask")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard await OwnerUnlock.authenticate(kind, "ask less often before using your \(kind.rawValue)") else { return }
        policy = choice
    }
}
