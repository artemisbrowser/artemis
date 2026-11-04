import Foundation
import NaturalLanguage
import Translation
import WebKit

/// on-device full-page translation: the page-side scripts and the tab-facing state.
/// scripts run via `callAsyncJavaScript` in an isolated world the page can't see
enum PageTranslation {
    enum State: Equatable {
        case idle
        /// reading the page's language, or waiting on a language download
        case detecting
        /// progress is 0...1 over the unique strings found so far
        case translating(from: Locale.Language, to: Locale.Language, progress: Double)
        case translated(from: Locale.Language, to: Locale.Language)
        case failed(String)

        /// the page shows, or is turning into, translated text
        var isActive: Bool {
            switch self {
            case .detecting, .translating, .translated: true
            case .idle, .failed: false
            }
        }

        var languages: (from: Locale.Language, to: Locale.Language)? {
            switch self {
            case .translating(let from, let to, _), .translated(let from, let to): (from, to)
            default: nil
            }
        }
    }

    static let world = WKContentWorld.world(name: "Artemis.Translation")

    /// named by language and script only, as the target picker lists it
    static func name(of language: Locale.Language) -> String {
        let id = listed(language).minimalIdentifier
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    private static func listed(_ language: Locale.Language) -> Locale.Language {
        Locale.Language(languageCode: language.languageCode, script: language.script)
    }

    static var systemTarget: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "en") }

    /// one entry per language and script, so English appears once and Chinese twice
    static func targetLanguages() async -> [Locale.Language] {
        var seen = Set<String>()
        return await LanguageAvailability().supportedLanguages
            .map(listed)
            .filter { seen.insert($0.minimalIdentifier).inserted }
            .sorted { name(of: $0).localizedCompare(name(of: $1)) == .orderedAscending }
    }

    static func sameTarget(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode && a.script == b.script
    }

    /// detection reads at most 3000 chars; the declared `lang` is the fallback
    static func language(of texts: [String], declared: String?) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(texts.joined(separator: "\n").prefix(3000)))
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.5 {
            return Locale.Language(identifier: best.key.rawValue)
        }
        guard let declared, !declared.isEmpty else { return nil }
        return Locale.Language(identifier: declared)
    }

    /// every frame to translate, parents first; `[nil]` (the main frame) without the frame-tree SPI.
    /// a frame whose element opts out is skipped with everything inside it
    static func frames(in webView: WKWebView) async -> [WKFrameInfo?] {
        guard webView.responds(to: NSSelectorFromString("_frames:")) else { return [nil] }
        let root: FrameNode? = await withCheckedContinuation { done in
            unsafeBitCast(webView, to: WKWebViewFramesSPI.self)._frames { node in
                done.resume(returning: node.map(FrameNode.init))
            }
        }
        guard let root else { return [nil] }
        var out: [WKFrameInfo?] = []
        func walk(_ node: FrameNode) async {
            out.append(node.info)
            guard !node.children.isEmpty else { return }
            let skips = (try? await webView.callAsyncJavaScript(
                script("return T.frameSkips();"), in: node.info, contentWorld: world) as? [Bool]) ?? []
            for (index, child) in node.children.enumerated() where !(skips.indices.contains(index) && skips[index]) {
                await walk(child)
            }
        }
        await walk(root)
        return out
    }

    private struct FrameNode {
        let info: WKFrameInfo
        let children: [FrameNode]

        init(_ node: AnyObject) {
            let spi = unsafeBitCast(node, to: WKFrameTreeNodeSPI.self)
            info = spi.info
            children = spi.childFrames.map(FrameNode.init)
        }
    }

    /// `T` is the frame's translator in this world, installed on first use.
    /// a unit is a text node, an attribute or the document title; `written` is what it last held from us
    private static let prelude = #"""
        const T = window.artemisTranslation ??= (() => {
            const never = "[translate=no],.notranslate,[contenteditable]:not([contenteditable=false]),[role=textbox]";
            const noText = "head,script,style,noscript,template,code,pre,kbd,samp,var,svg,math,canvas,"
                + "iframe,frame,object,embed,textarea,select,option";
            const blocked = never + "," + noText;
            const letter = /\p{L}/u;
            const TEXT = Node.TEXT_NODE, ELEMENT = Node.ELEMENT_NODE;
            let s = null;

            const read = (u) => u.kind === "#text" ? u.node.data
                : u.kind === "#title" ? document.title : u.node.getAttribute(u.kind);
            const write = (u, value) => {
                if (u.kind === "#text") u.node.data = value;
                else if (u.kind === "#title") document.title = value;
                else u.node.setAttribute(u.kind, value);
            };
            const ours = (node, kind, value) => value === s.tracked.get(node)?.[kind]?.written;

            function consider(node, kind, out) {
                const value = read({ node, kind });
                const units = s.tracked.get(node) ?? {};
                const old = units[kind];
                if (old && value === old.written) return;
                if (old) old.dead = true;
                const text = value?.trim();
                if (!text || value.length > 5000 || !letter.test(text)) return;
                const unit = { node, kind, original: value, written: value };
                units[kind] = unit;
                s.tracked.set(node, units);
                out.push([s.units.push(unit) - 1, text]);
            }

            function attributes(el, out) {
                for (const name of ["placeholder", "title", "alt", "aria-label"]) {
                    if (el.hasAttribute(name)) consider(el, name, out);
                }
                if (el.localName === "input" && (el.type === "submit" || el.type === "button")
                    && el.hasAttribute("value")) consider(el, "value", out);
            }

            function watch(root) {
                if (s.shadows.has(root)) return;
                s.shadows.add(root);
                s.observer.observe(root, options);
                s.roots.push([root, true]);
            }

            const filter = (node) => {
                if (node.nodeType === TEXT) return NodeFilter.FILTER_ACCEPT;
                if (node.matches(never)) return NodeFilter.FILTER_REJECT;
                attributes(node, s.out);
                if (node.shadowRoot) watch(node.shadowRoot);
                return node.matches(noText) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
            };

            // no page task of ours runs past this many ms, under one frame at 120Hz
            const slice = 8;
            const nextTask = () => new Promise((resolve) => {
                const channel = new MessageChannel();
                channel.port1.onmessage = resolve;
                channel.port2.postMessage(0);
            });

            // one slice of the walk, resuming where the last call stopped
            function collect() {
                const out = s.out = [];
                const deadline = performance.now() + slice;
                while (performance.now() < deadline) {
                    if (s.walker && !s.walker.currentNode.isConnected) {
                        s.roots.unshift([s.walker.root, true]);
                        s.walker = null;
                    }
                    if (!s.walker) {
                        const [root, deep] = s.roots.shift() ?? [];
                        if (!root) break;
                        if (root === document) { consider(document, "#title", out); continue; }
                        if (!root.isConnected) continue;
                        if (root.nodeType === TEXT) {
                            if (!root.parentElement?.closest(blocked)) consider(root, "#text", out);
                            continue;
                        }
                        if (root.nodeType === ELEMENT) {
                            if (root.closest(never) || root.parentElement?.closest(noText)) continue;
                            attributes(root, out);
                            if (!deep || root.matches(noText)) continue;
                            if (root.shadowRoot) watch(root.shadowRoot);
                        }
                        s.walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, filter);
                    }
                    const node = s.walker.nextNode();
                    if (node) consider(node, "#text", out);
                    else s.walker = null;
                }
                return out;
            }

            const options = {
                childList: true, subtree: true, characterData: true,
                attributes: true, attributeFilter: ["placeholder", "title", "alt", "aria-label", "value"],
            };

            function observed(records) {
                const later = (node, deep) => s.pending.set(node, deep || s.pending.get(node) === true);
                for (const r of records) {
                    const t = r.target;
                    if (t.nodeName === "TITLE" || t.parentNode?.nodeName === "TITLE") {
                        if (!ours(document, "#title", document.title)) later(document, false);
                    } else if (r.type === "attributes") {
                        if (!ours(t, r.attributeName, t.getAttribute(r.attributeName))) later(t, false);
                    } else if (r.type === "characterData") {
                        if (!ours(t, "#text", t.data)) later(t, true);
                    } else {
                        for (const n of r.addedNodes) {
                            if (n.nodeType !== TEXT && n.nodeType !== ELEMENT) continue;
                            later(n.nodeName === "TITLE" ? document : n, n.nodeName !== "TITLE");
                            if (n.nodeType === ELEMENT && n.matches("iframe,frame") || n.querySelector?.("iframe,frame")) {
                                s.frames = true;
                            }
                        }
                    }
                }
                if (s.pending.size || s.frames) soon();
            }

            // mutations arrive in bursts; each burst reaches Swift at most every 250ms
            function soon() {
                if (s.timer) return;
                s.timer = setTimeout(() => {
                    s.timer = 0;
                    for (const entry of s.pending) s.roots.push(entry);
                    s.pending.clear();
                    s.wake?.();
                }, 250);
            }

            addEventListener("load", (e) => {
                if (s && (e.target.localName === "iframe" || e.target.localName === "frame")) { s.frames = true; soon(); }
            }, true);
            addEventListener("pagehide", () => api.restore());

            const api = {
                start() {
                    if (s) return s.token;
                    s = {
                        token: Math.random().toString(36).slice(2) + Date.now().toString(36),
                        units: [], tracked: new WeakMap(), shadows: new WeakSet(), pending: new Map(),
                        roots: [[document, false], [document.body ?? document.documentElement, true]],
                        walker: null, out: [], timer: 0, wake: null, frames: false, size: 8, last: null,
                        observer: new MutationObserver(observed),
                    };
                    s.observer.observe(document, options);
                    return s.token;
                },
                // resolves when there is work, or with null once translation stops
                async next() {
                    const run = s;
                    if (!run) return null;
                    if (!run.walker && !run.roots.length && !run.frames) await new Promise((r) => (run.wake = r));
                    if (s !== run) return null;
                    run.wake = null;
                    const frames = run.frames;
                    run.frames = false;
                    const units = collect();
                    return { units, frames, more: !!(run.walker || run.roots.length) };
                },
                // writes in slices sized so each, with the observers it wakes, fits `slice`
                async apply(token, pairs) {
                    const run = s;
                    if (run?.token !== token) return;
                    for (let i = 0; i < pairs.length; ) {
                        const started = performance.now(), count = Math.min(run.size, pairs.length - i);
                        for (const end = i + count; i < end; i++) {
                            const u = run.units[pairs[i][0]];
                            if (!u || u.dead || read(u) !== u.written) continue;
                            const [, lead, trail] = u.original.match(/^(\s*)[\s\S]*?(\s*)$/);
                            write(u, lead + pairs[i][1] + trail);
                            u.written = read(u);
                        }
                        // resumes after the page's mutation observers have had these records
                        await null;
                        const spent = performance.now() - started;
                        // a slice costs fixed + perWrite × count, fitted to this slice and the last
                        const last = run.last;
                        const perWrite = Math.max(0.001,
                            last && last.count !== count ? (spent - last.spent) / (count - last.count) : spent / count);
                        const fixed = Math.max(0, spent - perWrite * count);
                        run.last = { count, spent };
                        // past the budget even when empty: fewer, larger slices cost the page least
                        run.size = Math.max(1, Math.min(run.size * 2,
                            fixed >= slice ? Infinity : Math.floor((slice - fixed) / perWrite)));
                        if (i === pairs.length) break;
                        await nextTask();
                        if (s !== run) return;
                    }
                },
                restore() {
                    const run = s;
                    if (!run) return;
                    s = null;
                    run.observer.disconnect();
                    clearTimeout(run.timer);
                    run.wake?.();
                    for (const u of run.units) if (!u.dead && read(u) === u.written) write(u, u.original);
                },
                // for detection: up to 400 strings, stateless
                sample() {
                    const texts = letter.test(document.title) ? [document.title] : [];
                    const walker = document.createTreeWalker(
                        document.body ?? document.documentElement, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
                        (n) => n.nodeType === TEXT ? NodeFilter.FILTER_ACCEPT
                            : n.matches(blocked) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP);
                    for (let n, chars = 0; texts.length < 400 && chars < 3000 && (n = walker.nextNode()); ) {
                        const text = n.data.trim();
                        if (!letter.test(text)) continue;
                        texts.push(text);
                        chars += text.length;
                    }
                    return { lang: document.documentElement.lang, texts };
                },
                // one flag per `window.frames` entry, in frame-tree order: true when its element opts out
                frameSkips() {
                    const elements = [...document.querySelectorAll("iframe,frame")];
                    return Array.from({ length: window.frames.length }, (_, i) =>
                        !!elements.find((el) => el.contentWindow === window.frames[i])?.closest(never));
                },
            };
            return api;
        })();
        """#

    static func script(_ body: String) -> String { prelude + "\n" + body }

    static let sample = script("return T.sample();")
    static let start = script("return T.start();")
    static let next = script("return await T.next();")
    /// args `token`, `pairs` ([[unit, text]]); keeps each unit's original edge whitespace
    static let apply = script("await T.apply(token, pairs);")
    static let restore = script("T.restore();")
}

/// one page's translation: polls every frame for new text, translates it on device
/// and writes it back, until `stop`
@MainActor
final class PageTranslator {
    let source: Locale.Language
    let target: Locale.Language
    var report: (PageTranslation.State) -> Void = { _ in }

    private weak var webView: WKWebView?
    private let session: TranslationSession
    private let batches: AsyncStream<Batch>
    private let sink: AsyncStream<Batch>.Continuation
    private var isStopped = false
    private var frames: [WKFrameInfo?] = []
    private var tokens: Set<String> = []
    /// frames whose first pass over the document hasn't finished
    private var scanning: Set<String> = []
    /// source text to its translation, for every string this page has shown
    private var cache: [String: String] = [:]
    private var polling = 0
    private var queued = 0
    private var task: Task<Void, Never>?

    private struct Batch {
        let frame: WKFrameInfo?
        let token: String
        let units: [(Int, String)]
        let framesChanged: Bool
        let more: Bool
    }

    init(webView: WKWebView, from source: Locale.Language, to target: Locale.Language) {
        self.webView = webView
        self.source = source
        self.target = target
        session = TranslationSession(installedSource: source, target: target)
        (batches, sink) = AsyncStream.makeStream()
    }

    func start() {
        task = Task { await run() }
    }

    /// `restoring` puts the original text back in every frame
    func stop(restoring: Bool) {
        guard !isStopped else { return }
        isStopped = true
        task?.cancel()
        session.cancel()
        sink.finish()
        guard restoring, let webView else { return }
        for frame in frames {
            webView.callAsyncJavaScript(PageTranslation.restore, in: frame, in: PageTranslation.world)
        }
    }

    private func run() async {
        await discoverFrames()
        guard !frames.isEmpty else { return report(.failed("There's no text on this page to translate.")) }
        var found = 0
        var done = 0
        var settled = false
        for await batch in batches {
            queued -= 1
            if batch.framesChanged { await discoverFrames() }
            guard !isStopped else { return }

            // one request per unique uncached string, in page order
            var pairs: [[Any]] = []
            var members: [String: [Int]] = [:]
            var texts: [String] = []
            for (unit, text) in batch.units {
                if let known = cache[text] {
                    pairs.append([unit, known])
                } else {
                    if members[text] == nil { texts.append(text) }
                    members[text, default: []].append(unit)
                }
            }
            found += texts.count
            var lastFlush = ContinuousClock.now
            var progress: Double { found == 0 ? 0 : Double(done) / Double(found) }
            func flush() async {
                guard !pairs.isEmpty else { return }
                _ = try? await webView?.callAsyncJavaScript(
                    PageTranslation.apply, arguments: ["token": batch.token, "pairs": pairs],
                    in: batch.frame, contentWorld: PageTranslation.world)
                pairs = []
                lastFlush = .now
                if !settled, !isStopped { report(.translating(from: source, to: target, progress: progress)) }
            }
            await flush()
            if !texts.isEmpty {
                do {
                    let requests = texts.indices.map {
                        TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0))
                    }
                    for try await response in session.translate(batch: requests) {
                        guard !isStopped else { return }
                        if let index = response.clientIdentifier.flatMap(Int.init) {
                            cache[texts[index]] = response.targetText
                            pairs += members[texts[index], default: []].map { [$0, response.targetText] }
                        }
                        done += 1
                        if pairs.count >= 8 || ContinuousClock.now - lastFlush > .milliseconds(60) { await flush() }
                    }
                    await flush()
                } catch {
                    guard !isStopped else { return }
                    return report(.failed(error.localizedDescription))
                }
            }
            if !batch.more { scanning.remove(batch.token) }
            if !settled, scanning.isEmpty, queued == 0 {
                settled = true
                report(.translated(from: source, to: target))
            }
        }
    }

    private func discoverFrames() async {
        guard let webView else { return }
        for frame in await PageTranslation.frames(in: webView) {
            let token = try? await webView.callAsyncJavaScript(
                PageTranslation.start, in: frame, contentWorld: PageTranslation.world) as? String
            if isStopped {
                webView.callAsyncJavaScript(PageTranslation.restore, in: frame, in: PageTranslation.world)
                return
            }
            guard let token, tokens.insert(token).inserted else { continue }
            frames.append(frame)
            scanning.insert(token)
            poll(frame, token)
        }
    }

    private func poll(_ frame: WKFrameInfo?, _ token: String) {
        polling += 1
        Task {
            defer {
                polling -= 1
                if polling == 0 { sink.finish() }
            }
            while !isStopped,
                let reply = try? await webView?.callAsyncJavaScript(
                    PageTranslation.next, in: frame, contentWorld: PageTranslation.world) as? [String: Any]
            {
                let units = (reply["units"] as? [[Any]] ?? []).compactMap { pair -> (Int, String)? in
                    guard pair.count == 2, let unit = pair[0] as? Int, let text = pair[1] as? String else { return nil }
                    return (unit, text)
                }
                queued += 1
                sink.yield(
                    Batch(
                        frame: frame, token: token, units: units,
                        framesChanged: reply["frames"] as? Bool ?? false, more: reply["more"] as? Bool ?? false))
            }
        }
    }
}

/// `_frames:` hands back the root `_WKFrameTreeNode`; guarded by `responds(to:)`
@objc private protocol WKWebViewFramesSPI {
    func _frames(_ completionHandler: @escaping (AnyObject?) -> Void)
}

@objc private protocol WKFrameTreeNodeSPI {
    var info: WKFrameInfo { get }
    var childFrames: [AnyObject] { get }
}
