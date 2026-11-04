// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// four bars and a word for how hard `password` is to guess
struct StrengthMeter: View {
    let password: String
    /// fragments of the password, kept only while the meter is shown
    @State private var words = PasswordStrength.Words()

    var body: some View {
        let strength = PasswordStrength(password, words: words)
        let (title, color): (String, Color) =
            switch strength {
            case .weak: ("Weak", .red)
            case .fair: ("Fair", .orange)
            case .good: ("Good", .yellow)
            case .strong: ("Strong", .green)
            }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<4) { bar in
                    Capsule().fill(bar <= strength.rawValue ? color : .primary.opacity(0.1)).frame(height: 4)
                }
            }
            HStack(spacing: 4) {
                Text(title).foregroundStyle(color)
                if strength < .good {
                    Text(password.count < 12 ? "Try 12 characters or more." : "Add a word nobody would link to you.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .animation(Motion.fade, value: strength)
    }
}
