import Foundation

/// dev-only file logger (sandbox container tmp); read from outside via
/// ~/Library/Containers/dev.findles.Artemis/Data/tmp/artemis-debug.log
nonisolated private let isDebugLoggingEnabled =
    ProcessInfo.processInfo.environment["ARTEMIS_DEBUG"] != nil
        || ProcessInfo.processInfo.environment["ARTEMIS_TEST_URL"] != nil

nonisolated func debugLog(_ message: String) {
    guard isDebugLoggingEnabled else { return }
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("artemis-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}
