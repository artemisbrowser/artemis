// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// the scripts an extension registers through the `userScripts` shim. they run in a content world
/// of the extension's own, where `chrome` is only the messaging `configureWorld` allows, and that
/// messaging is carried from here: to the extension pages listening on `onUserScriptMessage`, and
/// the extension's `tabs.sendMessage` back to the scripts
@MainActor
final class UserScriptWorld: NSObject, WKScriptMessageHandlerWithReply {
    /// one per running extension instance, keyed as `ExtensionAPIBridge.key`
    private static var running: [String: UserScriptWorld] = [:]
    private static let handlerName = "artemisUserScript"
    private static let remove = NSSelectorFromString("_removeUserScript:")
    /// names a document the same in every world of its frame; compat.js's `frameKey` returns this expression
    static let frameKey =
        #"[performance.timeOrigin, (performance.getEntriesByType("navigation")[0] || {}).name, document.referrer].join("|")"#

    private let world: WKContentWorld
    private weak var context: WKWebExtensionContext?
    private var installed: [(controller: WKUserContentController, scripts: [WKUserScript], handles: Bool)] = []
    /// the push ports of the extension pages that have a user-script listener
    private var listeners: [WKWebExtension.MessagePort] = []
    /// `silent`: the listening pages that have answered a message with nothing
    private var replies: [String: (reply: (String?) -> Void, silent: Int)] = [:]
    private var ports: [String: (webView: WKWebView, frame: WKFrameInfo)] = [:]
    /// the documents with a script listening on `runtime.onMessage`, by frame key
    private var hearing: [String: WKFrameInfo] = [:]
    private var outbox = Task<Void, Never> {}

    private init(context: WKWebExtensionContext) {
        self.context = context
        world = .world(name: "Artemis.UserScripts." + context.uniqueIdentifier)
    }

    // MARK: - Lifecycle

    /// rebuild a running extension's world from its registry: when it loads, and after every change to either
    static func sync(_ context: WKWebExtensionContext, in profile: UUID) {
        guard context.isLoaded, ExtensionData.declares("userScripts", context) else { return }
        let key = ExtensionAPIBridge.key(of: context, in: profile)
        let world = running[key] ?? UserScriptWorld(context: context)
        running[key] = world
        world.install(context, in: profile)
    }

    static func stop(_ key: String) {
        guard let world = running.removeValue(forKey: key) else { return }
        world.uninstall()
        world.listeners = []
        world.drop()
    }

    private func install(_ context: WKWebExtensionContext, in profile: UUID) {
        uninstall()
        guard let folder = ExtensionData.userScriptFolder(of: context, in: profile)?.folder,
            let registry = (try? Data(contentsOf: folder.appendingPathComponent("registry.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
            let entries = registry["scripts"] as? [String: [String: Any]]
        else { return }
        let granted = context.currentPermissionMatchPatterns.map(\.string)
        var scripts: [WKUserScript] = []
        for script in (registry["order"] as? [String] ?? entries.keys.sorted()).compactMap({ entries[$0] })
        where script["world"] as? String != "MAIN" {
            for path in script["files"] as? [String] ?? [] {
                // only this profile's own files, whatever path the registry gives
                let file = folder.appendingPathComponent((path as NSString).lastPathComponent)
                guard let code = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scripts.append(
                    WKUserScript(
                        source: Self.matching(script, granted: granted, code),
                        injectionTime: script["runAt"] as? String == "document_start" ? .atDocumentStart : .atDocumentEnd,
                        forMainFrameOnly: script["allFrames"] as? Bool != true, in: world))
            }
        }
        guard !scripts.isEmpty else { return }
        let messaging = (registry["world"] as? [String: Any])?["messaging"] as? Bool == true
        if messaging {
            scripts.insert(
                WKUserScript(
                    source: Self.runtime(id: context.baseURL.host() ?? ""), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world),
                at: 0)
        }
        for isPrivate in [false, true] where !isPrivate || context.hasAccessToPrivateData {
            let controller = SharedWebContent.userContentController(for: profile, isPrivate: isPrivate)
            guard controller.responds(to: Self.remove) else { continue }
            if messaging { controller.addScriptMessageHandler(self, contentWorld: world, name: Self.handlerName) }
            scripts.forEach(controller.addUserScript)
            installed.append((controller, scripts, messaging))
        }
    }

    private func uninstall() {
        for (controller, scripts, handles) in installed {
            if handles { controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world) }
            for script in scripts { controller.perform(Self.remove, with: script) }
        }
        installed = []
    }

    /// `code` behind the script's match patterns and the extension's host access, neither of which
    /// WebKit checks for a script added to the page natively
    private static func matching(_ script: [String: Any], granted: [String], _ code: String) -> String {
        let test = { (patterns: [String]) -> String in
            let sources = (try? JSONSerialization.data(withJSONObject: patterns.compactMap(PageNamespaceGate.regexSource)))
                .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            return sources + ".some((p) => new RegExp(p).test(location.href.split('#')[0]))"
        }
        var conditions = [test(granted)]
        if let matches = script["matches"] as? [String], !matches.isEmpty { conditions.append(test(matches)) }
        if let excluded = script["excludeMatches"] as? [String], !excluded.isEmpty { conditions.append("!" + test(excluded)) }
        return "if (\(conditions.joined(separator: " && "))) {\n\(code)\n}"
    }

    /// the world's whole `chrome`: `runtime.id` and the four messaging members Chrome gives a user script,
    /// messages sent as JSON text through the message handler. `onMessage` hears the extension's
    /// `tabs.sendMessage`; `onConnect` never fires
    private static func runtime(id: String) -> String {
        """
        (() => {
          const send = (body) => webkit.messageHandlers.\(handlerName).postMessage(body);
          const text = (message) => JSON.stringify(message === undefined ? null : message);
          const event = () => {
            const fns = new Set();
            return { addListener: (fn) => fns.add(fn), removeListener: (fn) => fns.delete(fn),
              hasListener: (fn) => fns.has(fn),
              fire: (...args) => [...fns].map((fn) => { try { return fn(...args); } catch (e) { console.error(e); } }) };
          };
          const ports = new Map();
          const runtime = {
            id: "\(id)", onMessage: event(), onConnect: event(),
            sendMessage: (...args) => {
              const cb = typeof args[args.length - 1] === "function" ? args.pop() : null;
              const message = args.length > 1 && typeof args[0] === "string" ? args[1] : args[0];
              const sent = send({ type: "message", message: text(message) })
                .then((reply) => (typeof reply === "string" ? JSON.parse(reply) : undefined));
              if (!cb) return sent;
              sent.then(cb, () => cb());
            },
            connect: (...args) => {
              const info = args.find((arg) => arg && typeof arg === "object") || {};
              const id = Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(36)).join("");
              const port = { name: info.name || "", onMessage: event(), onDisconnect: event(),
                postMessage: (message) => {
                  if (!ports.has(id)) throw new Error("Attempting to use a disconnected port object");
                  send({ type: "post", port: id, message: text(message) });
                },
                disconnect: () => { if (ports.delete(id)) send({ type: "disconnect", port: id }); } };
              ports.set(id, port);
              send({ type: "connect", port: id, name: port.name });
              return port;
            },
          };
          let listening = false;
          const hear = runtime.onMessage.addListener;
          runtime.onMessage.addListener = (fn) => {
            hear(fn);
            if (!listening) { listening = true; send({ type: "listen" }); }
          };
          if (window === window.top) send({ type: "start" });
          addEventListener("pageshow", (event) => { if (event.persisted && listening) send({ type: "listen" }); });
          Object.defineProperty(globalThis, "__artemisUserMessage", { value: (message) => new Promise((resolve) => {
            const respond = (reply) => resolve(text(reply));
            const waiting = runtime.onMessage.fire(JSON.parse(message), { id: runtime.id }, respond).filter((result) => {
              const later = !!result && typeof result.then === "function";
              if (later) result.then(respond, () => resolve(null));
              return later || result === true;
            });
            if (!waiting.length) resolve(null);
          }) });
          Object.defineProperty(globalThis, "__artemisUserPort", { value: (id, message, closed) => {
            const port = ports.get(id);
            if (!port) return;
            if (!closed) return port.onMessage.fire(JSON.parse(message), port);
            ports.delete(id);
            port.onDisconnect.fire(port);
          } });
          addEventListener("pagehide", () => {
            for (const id of [...ports.keys()]) { ports.delete(id); send({ type: "disconnect", port: id }); }
          });
          globalThis.chrome = globalThis.browser = { runtime };
        })();
        """
    }

    // MARK: - From the page

    /// called in the order the page posted, which a port's `connect` and its first `post` rely on
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let webView = message.webView else { return replyHandler(nil, nil) }
        let frame = message.frameInfo
        let port = body["port"] as? String ?? ""
        let text = body["message"] as? String
        switch body["type"] as? String {
        case "message":
            let id = UUID().uuidString
            replies[id] = ({ replyHandler($0, nil) }, 0)
            enqueue {
                guard let text, let sender = await self.describe(frame, in: webView),
                    await self.deliver(["event": "userScripts.message", "id": id, "message": text, "frame": sender])
                else { return self.answer(id, nil) }
            }
            return
        case "connect":
            ports[port] = (webView, frame)
            let name = body["name"] as? String ?? ""
            enqueue {
                guard let sender = await self.describe(frame, in: webView),
                    await self.deliver(["event": "userScripts.connect", "port": port, "name": name, "frame": sender])
                else { return self.close(port) }
            }
        case "post":
            guard ports[port] != nil, let text else { break }
            enqueue { _ = await self.deliver(["event": "userScripts.port", "port": port, "message": text]) }
        case "start" where frame.isMainFrame:
            // a new main document ends every document its web view held
            enqueue { self.hearing = self.hearing.filter { $0.value.webView != nil && $0.value.webView !== webView } }
        case "listen":
            enqueue {
                guard let key = await self.describe(frame, in: webView)?["key"] as? String else { return }
                self.hearing[key] = frame
            }
        case "disconnect":
            guard ports.removeValue(forKey: port) != nil else { break }
            enqueue { _ = await self.deliver(["event": "userScripts.port", "port": port, "closed": true], waking: false) }
        default:
            break
        }
        replyHandler(nil, nil)
    }

    /// events reach the extension in the order their pages sent them
    private func enqueue(_ work: @escaping () async -> Void) {
        let earlier = outbox
        outbox = Task {
            await earlier.value
            await work()
        }
    }

    /// what the shim finds the sender by, read in a world no page or user script can reach
    private func describe(_ frame: WKFrameInfo, in webView: WKWebView) async -> [String: Any]? {
        guard
            let found = try? await webView.evaluateJavaScript(
                "[\(Self.frameKey), location.href]", in: frame, contentWorld: .defaultClient) as? [String],
            found.count == 2
        else { return nil }
        return ["key": found[0], "url": found[1], "page": webView.url?.absoluteString ?? ""]
    }

    /// false when no page is listening, the background having been started to listen if `waking`
    private func deliver(_ event: [String: Any], waking: Bool = true) async -> Bool {
        if listeners.isEmpty, waking {
            context?.loadBackgroundContent { _ in }
            for _ in 0..<100 where listeners.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        }
        for port in listeners { port.sendMessage(event, completionHandler: nil) }
        return !listeners.isEmpty
    }

    private func answer(_ id: String, _ reply: String?) {
        replies.removeValue(forKey: id)?.reply(reply)
    }

    private func close(_ id: String) {
        guard let port = ports.removeValue(forKey: id) else { return }
        port.webView.callAsyncJavaScript(
            "__artemisUserPort(id, null, true)", arguments: ["id": id], in: port.frame, in: world)
    }

    // MARK: - From the extension

    /// a page of the extension with a user-script listener, heard on its push port
    static func listen(on port: WKWebExtension.MessagePort, for key: String) {
        guard let world = running[key], !world.listeners.contains(where: { $0 === port }) else { return }
        world.listeners.append(port)
    }

    static func stopped(_ port: WKWebExtension.MessagePort, for key: String) {
        guard let world = running[key] else { return }
        world.listeners.removeAll { $0 === port }
        if world.listeners.isEmpty { world.drop() }
    }

    /// nothing is listening: every waiting reply is empty and every port closes
    private func drop() {
        for id in Array(replies.keys) { answer(id, nil) }
        for id in Array(ports.keys) { close(id) }
    }

    /// the shim's replies, port traffic, `tabs.sendMessage` and `userScripts.execute`
    static func handle(
        _ type: String, _ message: [String: Any], for context: WKWebExtensionContext, in profile: UUID
    ) async -> [String: Any] {
        guard let world = running[ExtensionAPIBridge.key(of: context, in: profile)] else { return ["ok": false] }
        let id = message["port"] as? String ?? message["id"] as? String ?? ""
        switch type {
        case "userScripts.reply":
            if let text = message["message"] as? String {
                world.answer(id, text)
            } else if let silent = world.replies[id]?.silent {
                world.replies[id]?.silent = silent + 1
                if silent + 1 >= world.listeners.count { world.answer(id, nil) }
            }
        case "userScripts.port" where message["closed"] as? Bool == true:
            world.close(id)
        case "userScripts.port":
            guard let port = world.ports[id], let text = message["message"] as? String else { break }
            port.webView.callAsyncJavaScript(
                "__artemisUserPort(id, message, false)", arguments: ["id": id, "message": text], in: port.frame,
                in: world.world)
        case "userScripts.tabMessage":
            return await world.tell(message)
        default:
            return await world.run(message, for: context, in: profile)
        }
        return ["ok": true]
    }

    /// `tabs.sendMessage` for the scripts of the documents `keys` names: whether any listens there, and the
    /// first answer. with no keys, whether any listens anywhere
    private func tell(_ message: [String: Any]) async -> [String: Any] {
        guard let keys = message["keys"] as? [String], let text = message["message"] as? String else {
            return ["ok": true, "heard": !hearing.isEmpty]
        }
        let frames = keys.compactMap { key in hearing[key].flatMap { frame in frame.webView.map { ($0, frame) } } }
        guard !frames.isEmpty else { return ["ok": true, "heard": false] }
        let replies = AsyncStream<String?> { replies in
            for (webView, frame) in frames {
                webView.callAsyncJavaScript(
                    "return typeof __artemisUserMessage === 'function' ? __artemisUserMessage(message) : null",
                    arguments: ["message": text], in: frame, in: world
                ) { replies.yield((try? $0.get()) as? String) }
            }
        }
        var left = frames.count
        for await reply in replies {
            left -= 1
            if let reply { return ["ok": true, "heard": true, "reply": reply] }
            if left == 0 { break }
        }
        return ["ok": true, "heard": true]
    }

    /// `userScripts.execute`: the code runs in the main frame of the tab showing a document `keys` names
    private func run(
        _ message: [String: Any], for context: WKWebExtensionContext, in profile: UUID
    ) async -> [String: Any] {
        guard let keys = message["keys"] as? [String], let code = message["code"] as? [String] else { return ["ok": false] }
        let tabs = BrowserWindows.shared.allManagers.flatMap(\.allTabs).filter {
            ProfileStore.proxyProfile(of: $0.dataStore) == profile && !$0.isHibernated
                && (!$0.isPrivate || context.hasAccessToPrivateData)
        }
        for tab in tabs {
            guard let url = tab.url, context.hasAccess(to: url, in: tab),
                let key = try? await tab.webView.evaluateJavaScript(Self.frameKey, contentWorld: .defaultClient) as? String,
                keys.contains(key)
            else { continue }
            var result: Any = NSNull()
            for source in code {
                let value = try? await tab.webView.evaluateJavaScript(source, contentWorld: world)
                result = value.flatMap { JSONSerialization.isValidJSONObject([$0]) ? $0 : nil } ?? NSNull()
            }
            return ["ok": true, "result": result]
        }
        return ["ok": false]
    }
}
