// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// unpacks a .zip with `ditto`
nonisolated enum ZipArchive {
    static func extract(_ zip: URL, to destination: URL) async -> Bool {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, destination.path]
        let launched = await withCheckedContinuation { finished in
            ditto.terminationHandler = { _ in finished.resume(returning: true) }
            do { try ditto.run() } catch { finished.resume(returning: false) }
        }
        return launched && ditto.terminationStatus == 0
    }
}
