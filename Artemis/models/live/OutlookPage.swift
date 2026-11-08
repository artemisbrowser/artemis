// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import WebKit

/// Outlook on the web's unread inbox, read off the tab's own page: Microsoft serves its mail only
/// to the page's in-memory token, never to cookies. the page's markup is undocumented, so every
/// read is checked and a miss is unreadable, never an empty inbox
enum OutlookPage {
    private static let world = WKContentWorld.world(name: "Artemis.Outlook")
    private nonisolated static let hosts = [
        "outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft",
    ]

    /// on an Outlook host, or that host behind Defender for Cloud Apps (`<host>.mcas.ms`,
    /// `<host>.<region>.mcas.ms`)
    private nonisolated static func isOutlook(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasPrefix($0 + ".") && host.hasSuffix(".mcas.ms") }
    }

    /// the mailbox's root, as `https://<host>/mail/0` or `/mail/<address>`: what a conversation's
    /// and compose's links hang off
    nonisolated static func base(of url: URL) -> URL? {
        guard isOutlook(url), let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents
        let mailbox =
            parts.count > 2 && parts[1] == "mail" && (Int(parts[2]) != nil || parts[2].contains("@"))
            ? parts[2] : host == "outlook.live.com" ? "0" : nil
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/mail" + (mailbox.map { "/" + $0 } ?? "")
        return components.url
    }

    /// `/mail`, under `/mail/<n>` or `/mail/<address>` too, on its Inbox or a message open there
    nonisolated static func showsInbox(_ url: URL) -> Bool {
        var rest = url.pathComponents.dropFirst()
        guard rest.first == "mail" else { return false }
        rest = rest.dropFirst()
        if let mailbox = rest.first, Int(mailbox) != nil || mailbox.contains("@") { rest = rest.dropFirst() }
        return rest.isEmpty || rest.first?.lowercased() == "inbox"
    }

    nonisolated static func link(conversation: String, base: URL) -> URL? {
        guard let id = conversation.prefix(512).addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return URL(string: base.absoluteString + "/inbox/id/" + id)
    }

    /// the conversation id a card line's link carries; nil for any other link
    nonisolated static func conversation(in link: URL) -> String? {
        guard isOutlook(link), let range = link.path(percentEncoded: true).range(of: "/inbox/id/") else { return nil }
        return link.path(percentEncoded: true)[range.upperBound...].removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// wakes `tab` if it sleeps, then reads its Inbox for up to 10 s while the app draws it. a page
    /// off Outlook for 2 s is signed out; Outlook's own sign-in hops pass quicker than that
    static func unread(in tab: BrowserTab, base: URL) async -> LiveOutcome {
        let staged = stage(tab.webView)
        defer { staged.map { unstage(tab, from: $0) } }
        await tab.wake()
        let mailbox = base.lastPathComponent.contains("@") ? base.lastPathComponent.lowercased() : ""
        let deadline = ContinuousClock.now + .seconds(10)
        var away = 0
        var last: [String: Any]?
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if let page = tab.webView.url, !tab.webView.isLoading {
                away = isOutlook(page) ? 0 : away + 1
                if away == 8 { return .needsSignIn }
                if isOutlook(page), !["", "/"].contains(page.path()) {
                    guard showsInbox(page) else { return .unavailable(.unreadable) }
                    last = try? await tab.webView.callAsyncJavaScript(
                        reader, arguments: ["mailbox": mailbox], contentWorld: world) as? [String: Any]
                    if let last, last["ready"] as? Bool == true { return outcome(of: last, base: base) }
                }
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
        }
        // a list that never drew still leaves the folder tree's count
        return last.map { outcome(of: $0, base: base) } ?? .unavailable(.unreadable)
    }

    /// a web view in no window draws nothing, so the app never mounts its list: it reads from an
    /// invisible window behind every other, with occlusion throttling off. nil when already in a window
    private static func stage(_ webView: WKWebView) -> NSWindow? {
        guard webView.window == nil else { return nil }
        let frame = CGRect(origin: NSScreen.main?.visibleFrame.origin ?? .zero, size: CGSize(width: 1280, height: 800))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = content
        webView.frame = content.bounds
        content.addSubview(webView)
        throttles(webView, false)
        window.orderBack(nil)
        return window
    }

    /// a tab shown meanwhile has already taken its web view into its own window; throttling is back
    /// on wherever it went, bar the mini-player, which keeps it off
    private static func unstage(_ tab: BrowserTab, from window: NSWindow) {
        if tab.webView.superview === window.contentView { tab.webView.removeFromSuperview() }
        if !tab.isMiniPlayerActive { throttles(tab.webView, true) }
        window.orderOut(nil)
    }

    private static func throttles(_ webView: WKWebView, _ enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }

    /// no unread row drawn is all clear only when the Inbox's own count says so
    private static func outcome(of read: [String: Any], base: URL) -> LiveOutcome {
        let count = (read["count"] as? NSNumber)?.intValue
        let rows = (read["rows"] as? [[String: Any]] ?? []).compactMap { row -> LiveRow? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return LiveRow(
                id: id, title: row["subject"] as? String ?? "", subtitle: row["sender"] as? String ?? "",
                link: link(conversation: id, base: base), date: (row["when"] as? String).flatMap(date))
        }
        if rows.isEmpty, count == nil { return .unavailable(.unreadable) }
        return .rows(rows, total: count)
    }

    /// the full date a row's time carries, as "Mon 4/20/2026 5:16 PM" or "Mon 20/04/2026 17:16": the
    /// one reading whose weekday matches; nil when none or both do, or for another language
    nonisolated static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        let day = String(text.prefix { $0.isLetter })
        guard let weekday = formatter.shortWeekdaySymbols.firstIndex(where: { $0.caseInsensitiveCompare(day) == .orderedSame })
        else { return nil }
        let formats = ["M/d/yyyy h:mm a", "d/M/yyyy h:mm a", "M/d/yyyy H:mm", "d/M/yyyy H:mm", "yyyy-MM-dd H:mm", "d.M.yyyy H:mm"]
        let readings = Set(
            formats.compactMap { format -> Date? in
                formatter.dateFormat = "EEE " + format
                guard let date = formatter.date(from: text), Calendar.current.component(.weekday, from: date) == weekday + 1
                else { return nil }
                return date
            })
        return readings.count == 1 ? readings.first : nil
    }

    /// clicks the conversation's row in the open page, as the user would; false when it isn't drawn
    static func select(_ conversation: String, in tab: BrowserTab) async -> Bool {
        guard isOutlook(tab.webView.url) else { return false }
        let clicked = try? await tab.webView.callAsyncJavaScript(
            """
            const row = [...document.querySelectorAll('[role="option"][data-convid]')]
              .find(r => r.getAttribute("data-convid") === id);
            if (!row) return false;
            row.scrollIntoView({ block: "nearest" });
            row.click();
            return true;
            """, arguments: ["id": conversation], contentWorld: world)
        return clicked as? Bool == true
    }

    /// the Inbox's unread count from the route's account in the folder tree, else its one Favorites
    /// copy, and the unread rows of a list drawn from its top. unread is the row's label, its "Mark as
    /// read" button, or a semibold sender, so a language other than English still reads by weight
    private static let reader = """
        const digits = s => { const d = String(s ?? "").replace(/\\D/g, ""); return d ? Number(d) : null; };
        const tree = [...document.querySelectorAll('[role="treeitem"]')];
        const children = start => {
          const level = Number(tree[start].getAttribute("aria-level")), out = [];
          for (const t of tree.slice(start + 1)) {
            const l = Number(t.getAttribute("aria-level"));
            if (l <= level) break;
            if (l === level + 1) out.push(t);
          }
          return out;
        };
        const name = t => (t.getAttribute("data-folder-name") || "").toLowerCase();
        const roots = tree.map((t, i) => i).filter(i => (tree[i].id || "").startsWith("primaryMailboxRoot"));
        const root = roots.find(i => name(tree[i]) === mailbox) ?? roots[0];
        const favorites = tree.findIndex(t => t.id === "favoritesRoot");
        const own = root === undefined ? [] : children(root);
        const inbox = own.find(t => name(t).startsWith("inbox")) || own[0]
          || (favorites < 0 ? undefined : children(favorites).find(t => name(t).startsWith("inbox")));
        let count = null;
        if (inbox) {
          const chip = inbox.querySelector("span.screenReaderOnly");
          count = chip?.previousSibling ? digits(chip.previousSibling.textContent) : null;
          if (count === null && inbox.title) {
            const group = inbox.title.split(" - ").pop().match(/\\(([^)]*)\\)\\s*$/);
            count = group ? digits((group[1].match(/\\d[\\d.,\\s]*/g) || []).pop()) : 0;
          }
        }
        const dated = t => /\\d{1,4}[\\/.\\-]\\d{1,2}[\\/.\\-]\\d{1,4}/.test(t) && /\\d:\\d\\d/.test(t);
        const list = [...document.querySelectorAll('[role="listbox"]')].find(l => l.querySelector('[role="option"][data-convid]'));
        const rows = [];
        if (list) {
          const seen = new Set(), drawn = [];
          for (const row of list.querySelectorAll('[role="option"][data-convid]')) {
            const id = row.getAttribute("data-convid");
            if (id && !seen.has(id)) { seen.add(id); drawn.push(row); }
          }
          const at = r => Number(r.getAttribute("aria-posinset")) || 0;
          drawn.sort((a, b) => at(a) - at(b));
          // a list scrolled down has unmounted its newest rows
          const top = drawn.length === 0 || at(drawn[0]) <= 1;
          for (const row of top ? drawn : []) {
            const leaves = [...row.querySelectorAll("span, div")].filter(e =>
              !e.children.length && e.textContent.trim() && !e.closest('[role="img"], button') && e.getBoundingClientRect().height > 0);
            const lines = [];
            for (const e of leaves) {
              const y = e.getBoundingClientRect().top;
              let line = lines.find(l => Math.abs(l.y - y) < 5);
              if (!line) lines.push(line = { y, items: [] });
              line.items.push(e);
            }
            lines.sort((a, b) => a.y - b.y);
            for (const l of lines) l.items.sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left);
            const who = [...row.querySelectorAll('[title*="@"]')].find(e => !/\\s/.test(e.title)) || lines[0]?.items[0];
            const unread = /^unread\\b/i.test(row.getAttribute("aria-label") || "")
              || !!row.querySelector('button[title="Mark as read"]')
              || (!!who && parseInt(getComputedStyle(who).fontWeight, 10) >= 600);
            if (!unread) continue;
            // a one-line list puts the subject beside the sender
            const subject = (lines.length > 1 ? lines[1].items : (lines[0]?.items || []).filter(e => e !== who && !who?.contains(e)))
              .find(e => !dated(e.closest("[title]")?.title || ""));
            const when = [...row.querySelectorAll("[title]")].map(e => e.title).find(dated);
            rows.push({ id: row.getAttribute("data-convid"), sender: who?.textContent.trim() || "",
              subject: subject?.textContent.trim() || "", when: when || null });
            if (rows.length === 6) break;
          }
        }
        return { ready: !!list || count === 0, count, rows };
        """
}
