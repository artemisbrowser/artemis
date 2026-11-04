// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// one connected `Artemis mcp` process
@Observable
final class AgentSession: Identifiable {
    let id = UUID()
    private(set) var name = "Coding agent"
    private(set) var version = ""
    private(set) var parentPath = ""
    @ObservationIgnored fileprivate var isApproved = false
    @ObservationIgnored fileprivate var isRefused = false
    @ObservationIgnored fileprivate var isClosed = false
    /// calls that arrived before the user answered the approval prompt
    @ObservationIgnored fileprivate var waiting: [(id: Int, name: String, arguments: [String: Any])] = []
    @ObservationIgnored fileprivate var touched: Set<BrowserTab.ID> = []

    @ObservationIgnored private let fd: Int32
    @ObservationIgnored private let source: DispatchSourceRead
    @ObservationIgnored private let writes = DispatchQueue(label: "Artemis.Agent.write")
    @ObservationIgnored private var buffer = Data()

    fileprivate init(fd: Int32) {
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        // queued replies go out before the descriptor closes
        source.setCancelHandler { [fd, writes] in writes.async { Darwin.close(fd) } }
        source.resume()
    }

    /// what an approval is remembered under: the client's self-reported name plus the
    /// program that launched it, version folders wildcarded. nil when the launcher is unknown
    fileprivate var identity: String? {
        guard !parentPath.isEmpty else { return nil }
        let path = parentPath.split(separator: "/").map {
            $0.wholeMatch(of: /v?\d+(\.\d+)+/) != nil ? "*" : String($0)
        }
        return "\(name) — /" + path.joined(separator: "/")
    }

    fileprivate func attach(_ client: [String: Any]) {
        name = (client["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        version = client["version"] as? String ?? ""
        parentPath = client["parentPath"] as? String ?? ""
    }

    /// after `close` the descriptor number may already belong to someone else
    fileprivate func send(_ object: [String: Any]) {
        guard !isClosed else { return }
        let line = AgentSocket.line(object)
        writes.async { [fd] in AgentSocket.writeAll(fd, line) }
    }

    fileprivate func reply(_ id: Int, _ result: [String: Any]) {
        send(["result": ["id": id, "result": result]])
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
        AgentBridge.shared.ended(self)
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else {
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            return close()
        }
        buffer.append(contentsOf: chunk[0..<n])
        // bytes without a newline before the peer is dropped
        guard buffer.count < 16 << 20 else { return close() }
        for line in buffer.takeLines() where !isClosed {
            if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                AgentBridge.shared.received(message, from: self)
            }
        }
    }
}

/// lets coding agents drive tabs over MCP: owns the socket while agents are
/// allowed, approves each agent identity once, and runs the tools against the
/// spaces the user has shared
@Observable
final class AgentBridge {
    static let shared = AgentBridge()

    private static let enabledKey = "agentsEnabled"
    private static let scriptsKey = "agentsAllowScripts"
    private static let spacesKey = "agentsAllowedSpaces"
    private static let approvedKey = "agentsApproved"

    var isEnabled = UserDefaults.standard.bool(forKey: enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }
    var allowsScripts = UserDefaults.standard.bool(forKey: scriptsKey) {
        didSet { UserDefaults.standard.set(allowsScripts, forKey: Self.scriptsKey) }
    }
    var allowedSpaceIDs = Set(
        (UserDefaults.standard.stringArray(forKey: spacesKey) ?? []).compactMap(UUID.init(uuidString:))
    ) {
        didSet { UserDefaults.standard.set(allowedSpaceIDs.map(\.uuidString), forKey: Self.spacesKey) }
    }
    /// the `AgentSession.identity` values the user has allowed
    private(set) var approved = UserDefaults.standard.stringArray(forKey: approvedKey) ?? [] {
        didSet { UserDefaults.standard.set(approved, forKey: Self.approvedKey) }
    }
    private(set) var sessions: [AgentSession] = []
    /// why the socket couldn't open, shown in Settings
    private(set) var socketError: String?

    /// identities refused this run, refused again without asking until agents are switched off
    @ObservationIgnored private var denied: Set<String> = []
    @ObservationIgnored private var listener: DispatchSourceRead?
    @ObservationIgnored private var prompts: [AgentSession] = []
    @ObservationIgnored private var isPrompting = false
    @ObservationIgnored private var tabTails: [BrowserTab.ID: Task<Void, Never>] = [:]

    private init() {}

    /// spaces an agent may reach: shared by the user, never locked
    private var reachableSpaces: [Space] {
        BrowserCore.shared.spaces.filter {
            allowedSpaceIDs.contains($0.id) && !SpaceLock.shared.isLocked($0)
        }
    }

    func start() {
        guard isEnabled, listener == nil else { return }
        let fd: Int32
        do {
            fd = try AgentSocket.listen()
        } catch {
            socketError = error.message
            return
        }
        socketError = nil
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { AgentBridge.shared.accept(on: fd) } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listener = source
    }

    private func stop() {
        guard let listener else { return }
        unlink(AgentSocket.path)
        listener.cancel()
        self.listener = nil
        denied = []
        for session in sessions { session.close() }
    }

    private func accept(on listenerFD: Int32) {
        let fd = Darwin.accept(listenerFD, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        guard AgentSocket.peerIsUs(fd) else {
            Darwin.close(fd)
            return
        }
        sessions.append(AgentSession(fd: fd))
    }

    fileprivate func received(_ message: [String: Any], from session: AgentSession) {
        if let attach = message["attach"] as? [String: Any] {
            session.attach(attach["client"] as? [String: Any] ?? [:])
            if let identity = session.identity, approved.contains(identity) {
                approve(session)
            } else if let identity = session.identity, denied.contains(identity) {
                session.isRefused = true
            } else {
                requestApproval(session)
            }
        } else if let call = message["call"] as? [String: Any], let id = call["id"] as? Int {
            let name = call["name"] as? String ?? ""
            let arguments = call["arguments"] as? [String: Any] ?? [:]
            if session.isApproved { run(id, name, arguments, for: session) } else {
                session.waiting.append((id, name, arguments))
                if session.isRefused { refuse(session) }
            }
        }
    }

    fileprivate func ended(_ session: AgentSession) {
        sessions.removeAll { $0 === session }
        let stillUsed = Set(sessions.flatMap(\.touched))
        for tab in BrowserCore.shared.spaces.flatMap(\.tabs) + BrowserCore.shared.allEssentials
        where session.touched.contains(tab.id) && !stillUsed.contains(tab.id) {
            tab.agentName = nil
        }
    }

    func forget(_ identity: String) {
        approved.removeAll { $0 == identity }
        for session in sessions where session.identity == identity { session.close() }
    }

    // MARK: - Approval

    private func approve(_ session: AgentSession) {
        session.isApproved = true
        let waiting = session.waiting
        session.waiting = []
        for call in waiting { run(call.id, call.name, call.arguments, for: session) }
    }

    /// one alert at a time; an agent approved while others queued behind it skips its own.
    /// an agent whose launcher is unknown is approved for its session only.
    /// `RunLoop.perform`, not the main queue: a modal inside a main-queue block starves that queue
    private func requestApproval(_ session: AgentSession) {
        prompts.append(session)
        guard !isPrompting else { return }
        isPrompting = true
        RunLoop.main.perform { [self] in
            MainActor.assumeIsolated { drainPrompts() }
        }
    }

    private func drainPrompts() {
        while !prompts.isEmpty {
            let next = prompts.removeFirst()
            guard !next.isClosed else { continue }
            let identity = next.identity
            if identity.map(denied.contains) == true {
                refuse(next)
            } else if identity.map(approved.contains) == true || ask(next) {
                if let identity, !approved.contains(identity) { approved.append(identity) }
                approve(next)
            } else {
                if let identity { denied.insert(identity) }
                refuse(next)
            }
        }
        isPrompting = false
    }

    private func refuse(_ session: AgentSession) {
        for call in session.waiting {
            session.reply(call.id, Self.failure("The user didn't allow “\(session.name)” to use Artemis."))
        }
        session.close()
    }

    private func ask(_ session: AgentSession) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow “\(session.name)” to use Artemis?"
        var detail = "It will be able to read and control tabs in the spaces you've shared with agents in Settings › Agents."
        if !session.parentPath.isEmpty { detail += "\n\nLaunched by \(session.parentPath)" }
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow").keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Tools

    private func run(_ id: Int, _ name: String, _ arguments: [String: Any], for session: AgentSession) {
        Task {
            let result: [String: Any]
            do {
                result = try await perform(name, arguments, for: session)
            } catch let failure as AgentFailure {
                result = Self.failure(failure.message)
            } catch {
                result = Self.failure(error.localizedDescription)
            }
            session.reply(id, result)
        }
    }

    private func perform(_ name: String, _ arguments: [String: Any], for session: AgentSession) async throws
        -> [String: Any]
    {
        // a call approved after its session closed, or queued behind the close, does nothing
        guard isEnabled, !session.isClosed, let manager = BrowserWindows.shared.browserScope else {
            throw AgentFailure("Artemis has no browser window open, or agents were just turned off.")
        }
        switch name {
        case "list_spaces":
            let spaces = reachableSpaces
            guard !spaces.isEmpty else {
                throw AgentFailure("No spaces are shared with agents. The user can choose some in Artemis › Settings › Agents.")
            }
            return Self.text(Self.json(spaces.map {
                ["id": $0.id.uuidString, "name": $0.name, "tabCount": $0.tabs.count]
            }))
        case "list_tabs":
            let spaces = try arguments["space"] == nil ? reachableSpaces : [space(arguments)]
            return Self.text(Self.json(spaces.flatMap { space in
                space.tabs.map { info($0, in: space, manager: manager) }
            }))
        case "open_tab":
            let space = try space(arguments)
            let url = try Self.webURL(arguments["url"])
            let show = arguments["show"] as? Bool ?? false
            if show { manager.selectSpace(space) }
            let tab = manager.newTab(url: url, select: show, in: space)
            touch(tab, by: session)
            await tab.settle()
            return Self.text(Self.json(info(tab, in: space, manager: manager)))
        default:
            let (tab, _) = try resolveTab(arguments)
            touch(tab, by: session)
            // resolved again in turn: earlier calls on the tab can run for a minute, and its space
            // may lock or stop being shared meanwhile
            return try await serially(tab.id) {
                let (tab, space) = try self.resolveTab(arguments)
                return try await self.perform(name, arguments, on: tab, in: space, manager: manager)
            }
        }
    }

    private func perform(
        _ name: String, _ arguments: [String: Any], on tab: BrowserTab, in space: Space, manager: TabManager
    ) async throws -> [String: Any] {
        if let scheme = Self.location(of: tab)?.scheme?.lowercased(), scheme != "http", scheme != "https" {
            throw AgentFailure("Agents can only work with web pages; this tab shows a \(scheme): page.")
        }
        switch name {
        case "show_tab":
            manager.focus(tab)
            return Self.text("Showing \(tab.displayTitle).")
        case "close_tab":
            guard !tab.isPinned else { throw AgentFailure("Pinned tabs belong to the user and can't be closed by agents.") }
            manager.close(tab)
            return Self.text("Closed.")
        case "navigate":
            await tab.wake()
            _ = try resolveTab(arguments)
            switch (arguments["url"], arguments["action"] as? String) {
            case (let raw?, nil): tab.load(try Self.webURL(raw))
            case (nil, "back"?): tab.goBack()
            case (nil, "forward"?): tab.goForward()
            case (nil, "reload"?): tab.reload()
            default: throw AgentFailure("Pass either url or action (back, forward or reload).")
            }
            await tab.settle()
            return Self.text(Self.json(info(tab, in: space, manager: manager)))
        default:
            break
        }

        guard Self.location(of: tab) != nil else { throw AgentFailure("This tab has no page loaded; navigate it first.") }
        await tab.wake()
        // again once awake, which can take 15 s
        _ = try resolveTab(arguments)
        let uid = arguments["uid"] as? String
        switch name {
        case "take_snapshot":
            return Self.text(try await Self.page(tab, "return A.snapshot();"))
        case "click", "hover":
            let text = try await Self.page(tab, "return A.\(name)(uid);", ["uid": try Self.required(uid, "uid")])
            if name == "click" { await tab.settle() }
            return Self.text(text)
        case "fill":
            let value = try Self.required(arguments["value"] as? String, "value")
            return Self.text(try await Self.page(
                tab, "return A.fill(uid, value);", ["uid": try Self.required(uid, "uid"), "value": value]))
        case "type_text":
            let text = try Self.required(arguments["text"] as? String, "text")
            return Self.text(try await Self.page(tab, "return A.typeText(text);", ["text": text]))
        case "press_key":
            let key = try Self.required(arguments["key"] as? String, "key")
            let modifiers = arguments["modifiers"] as? [String] ?? []
            let text = try await Self.page(
                tab, "return A.pressKey(key, modifiers);", ["key": key, "modifiers": modifiers])
            await tab.settle()
            return Self.text(text)
        case "scroll":
            return Self.text(try await Self.page(
                tab, "return A.scroll(uid, dy);",
                ["uid": uid ?? NSNull(), "dy": (arguments["dy"] as? NSNumber) ?? NSNull()]))
        case "screenshot":
            return ["content": [["type": "image", "data": try await Self.screenshot(tab), "mimeType": "image/png"]]]
        case "wait_for":
            return Self.text(try await Self.wait(
                for: arguments["text"] as? String, in: tab,
                timeout: max(0, min((arguments["timeout_ms"] as? Double) ?? 10_000, 60_000))))
        case "evaluate_script":
            guard allowsScripts else {
                throw AgentFailure("Running scripts is off. The user can allow it in Artemis › Settings › Agents › “Let agents run scripts in pages”.")
            }
            let function = try Self.required(arguments["function"] as? String, "function")
            return Self.text(try await Self.page(
                tab, "return JSON.stringify(await (\(function))()) ?? 'undefined';", world: .page))
        default:
            throw AgentFailure("Unknown tool \(name).")
        }
    }

    // MARK: - Helpers

    private func space(_ arguments: [String: Any]) throws -> Space {
        let key = try Self.required(arguments["space"] as? String, "space")
        guard let space = reachableSpaces.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame
                || $0.name.caseInsensitiveCompare(key) == .orderedSame
        }) else { throw AgentFailure("No space “\(key)” is shared with agents; call list_spaces.") }
        return space
    }

    private func resolveTab(_ arguments: [String: Any]) throws -> (BrowserTab, Space) {
        let raw = try Self.required(arguments["tab"] as? String, "tab")
        for space in reachableSpaces {
            if let tab = space.tabs.first(where: { $0.id.uuidString.caseInsensitiveCompare(raw) == .orderedSame }) {
                return (tab, space)
            }
        }
        throw AgentFailure("No tab \(raw) in a space shared with agents; call list_tabs.")
    }

    private func touch(_ tab: BrowserTab, by session: AgentSession) {
        tab.agentName = session.name
        session.touched.insert(tab.id)
    }

    /// runs `body` after every earlier call on the same tab has finished
    private func serially<T>(_ id: BrowserTab.ID, _ body: @escaping () async throws -> T) async throws -> T {
        let previous = tabTails[id]
        let task = Task {
            await previous?.value
            return try await body()
        }
        tabTails[id] = Task { _ = try? await task.value }
        return try await task.value
    }

    private func info(_ tab: BrowserTab, in space: Space, manager: TabManager) -> [String: Any] {
        [
            "id": tab.id.uuidString, "space": space.name, "title": tab.displayTitle,
            "url": Self.location(of: tab)?.absoluteString ?? NSNull(), "isPinned": tab.isPinned,
            "selected": manager.selectedTab(in: space) === tab,
        ]
    }

    private static func location(of tab: BrowserTab) -> URL? {
        tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL
    }

    private static func required<T>(_ value: T?, _ key: String) throws -> T {
        guard let value else { throw AgentFailure("Missing `\(key)`.") }
        return value
    }

    private static func webURL(_ raw: Any?) throws -> URL {
        guard let raw = raw as? String, let url = URL(string: raw),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil
        else { throw AgentFailure("Agents can only open http and https URLs.") }
        return url
    }

    private static func page(
        _ tab: BrowserTab, _ call: String, _ arguments: [String: Any] = [:], world: WKContentWorld = AgentPage.world
    ) async throws -> String {
        let source = world == AgentPage.world ? AgentPage.library + call : call
        do {
            let value = try await tab.webView.callAsyncJavaScript(source, arguments: arguments, contentWorld: world)
            return value as? String ?? "\(value ?? "null")"
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw AgentFailure(message ?? error.localizedDescription)
        }
    }

    private static func wait(for text: String?, in tab: BrowserTab, timeout milliseconds: Double) async throws -> String {
        let deadline = Date(timeIntervalSinceNow: milliseconds / 1000)
        let check = "return String(text == null ? document.readyState === 'complete' : (document.body?.innerText ?? '').includes(text));"
        while Date() < deadline {
            if !tab.webView.isLoading,
                (try? await page(tab, check, ["text": text ?? NSNull()])) == "true"
            {
                return text.map { "Found “\($0)”." } ?? "The page has finished loading."
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AgentFailure("Timed out after \(Int(milliseconds))ms waiting for \(text.map { "“\($0)”" } ?? "the page to load").")
    }

    private static func screenshot(_ tab: BrowserTab) async throws -> String {
        let image = try await tab.webView.takeSnapshot(configuration: nil)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = await png(cgImage)
        else { throw AgentFailure("The tab couldn't be captured.") }
        return png
    }

    /// base64 PNG, at most 1600px wide
    @concurrent nonisolated private static func png(_ image: CGImage) async -> String? {
        var image = image
        if image.width > 1600, let context = CGContext(
            data: nil, width: 1600, height: image.height * 1600 / image.width, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            image = context.makeImage() ?? image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? (data as Data).base64EncodedString() : nil
    }

    private static func text(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private static func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
