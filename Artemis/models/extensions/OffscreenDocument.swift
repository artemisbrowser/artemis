// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// an extension page in a web view no window shows: WebKit gives it the full
/// extension API and runtime messaging with the background, which is all an
/// offscreen document promises
final class OffscreenDocument: NSObject, WKNavigationDelegate {
    let url: URL
    private let webView: WKWebView
    private var outcome: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(url: URL, configuration: WKWebViewConfiguration) {
        self.url = url
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.finish(false)
        }
    }

    /// true once the first load finishes, so messages sent next find listeners
    func loaded() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(_ ok: Bool) {
        guard outcome == nil else { return }
        outcome = ok
        waiters.forEach { $0.resume(returning: ok) }
        waiters = []
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(false)
    }
}
