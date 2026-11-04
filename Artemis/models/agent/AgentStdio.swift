import Foundation

/// `Artemis mcp`: the stdio MCP server a coding agent launches. It answers the
/// handshake and the tool catalog itself and relays each `tools/call` to the
/// running app over `AgentSocket`. Single-threaded: one poll loop over stdin and the socket
enum AgentStdio {
    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static var socket: Int32 = -1
    private static var input = Data()
    private static var replies = Data()
    /// relay call id → the client's JSON-RPC id
    private static var pending: [Int: Any] = [:]
    private static var nextCallID = 0
    private static var clientInfo: [String: Any] = [:]

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
            if socket >= 0 { fds.append(pollfd(fd: socket, events: Int16(POLLIN), revents: 0)) }
            guard poll(&fds, nfds_t(fds.count), -1) >= 0 else {
                if errno == EINTR { continue }
                exit(1)
            }
            if fds.count > 1, fds[1].revents != 0 {
                let n = read(socket, &chunk, chunk.count)
                if n > 0 {
                    replies.append(contentsOf: chunk[0..<n])
                    for line in replies.takeLines() { relayReply(line) }
                } else {
                    disconnect("Artemis closed the connection. Ask again once it's running with agents allowed.")
                }
            }
            if fds[0].revents != 0 {
                let n = read(STDIN_FILENO, &chunk, chunk.count)
                guard n > 0 else { exit(0) }
                input.append(contentsOf: chunk[0..<n])
                for line in input.takeLines() { handle(line) }
            }
        }
    }

    private static func handle(_ line: Data) {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { return }
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        // notifications and stray responses get no reply
        guard let id = message["id"], let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            clientInfo = params["clientInfo"] as? [String: Any] ?? [:]
            let asked = params["protocolVersion"] as? String ?? ""
            reply(id, [
                "protocolVersion": protocolVersions.contains(asked) ? asked : protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "artemis",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                ],
                "instructions": instructions,
            ])
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Missing tool name"]])
                return
            }
            forward(id, name, params["arguments"] as? [String: Any] ?? [:])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private static func forward(_ id: Any, _ name: String, _ arguments: [String: Any]) {
        if socket < 0 {
            guard let fd = AgentSocket.connect() else {
                reply(id, failure(
                    "Artemis isn't reachable. Open Artemis, then turn on Settings › Agents › “Allow coding agents to use Artemis”."))
                return
            }
            socket = fd
            AgentSocket.writeAll(fd, AgentSocket.line(["attach": [
                "version": 1,
                "client": [
                    "name": clientInfo["name"] as? String ?? "Coding agent",
                    "version": clientInfo["version"] as? String ?? "",
                    "parentPath": parentPath() ?? "",
                ],
            ]]))
        }
        nextCallID += 1
        pending[nextCallID] = id
        AgentSocket.writeAll(socket, AgentSocket.line(["call": ["id": nextCallID, "name": name, "arguments": arguments]]))
    }

    private static func relayReply(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let envelope = message["result"] as? [String: Any], let callID = envelope["id"] as? Int,
            let id = pending.removeValue(forKey: callID)
        else { return }
        reply(id, envelope["result"] ?? failure("Artemis sent an empty result."))
    }

    private static func disconnect(_ reason: String) {
        close(socket)
        socket = -1
        replies = Data()
        for id in pending.values { reply(id, failure(reason)) }
        pending = [:]
    }

    private static func parentPath() -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getppid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private static func reply(_ id: Any, _ result: Any) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        AgentSocket.writeAll(STDOUT_FILENO, AgentSocket.line(object))
    }

    // MARK: - Catalog

    private static let instructions = """
        Artemis is the user's own browser: its tabs are real and signed in. Work in tabs \
        you open with open_tab where you can, and leave the user's tabs as they are unless asked. \
        Call take_snapshot before click/fill/hover; uids come from the latest snapshot. Input is \
        synthesized DOM events, so a few sites may ignore it. Passwords are never typed by agents.
        """

    private static let tab: [String: Any] = ["type": "string", "description": "Tab id from list_tabs or open_tab."]
    private static let uid: [String: Any] = [
        "type": "string", "description": "Element uid from the latest take_snapshot, e.g. e12.",
    ]

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static let tools: [[String: Any]] = [
        tool("list_spaces", "List the Artemis spaces the user has shared with agents."),
        tool(
            "list_tabs", "List tabs (id, space, title, url, isPinned, selected) in shared spaces.",
            ["space": string("Only this space (id or name).")]),
        tool(
            "open_tab", "Open an http(s) URL in a new tab. Opens in the background unless show is true.",
            ["space": string("Space id or name from list_spaces."), "url": string("http or https URL."),
             "show": ["type": "boolean", "description": "Bring the new tab to the front."]],
            required: ["space", "url"]),
        tool(
            "navigate", "Load a URL in a tab, or go back, forward or reload. Pass url or action.",
            ["tab": tab, "url": string("http or https URL."),
             "action": ["type": "string", "enum": ["back", "forward", "reload"]]],
            required: ["tab"]),
        tool("show_tab", "Bring a tab to the front in Artemis so the user sees it.", ["tab": tab], required: ["tab"]),
        tool("close_tab", "Close a tab. Pinned tabs and favourites can't be closed.", ["tab": tab], required: ["tab"]),
        tool(
            "take_snapshot",
            "Text accessibility outline of the page. Interactive elements carry [uid=…] for click, hover, fill and scroll. Take a new one after the page changes.",
            ["tab": tab], required: ["tab"]),
        tool("click", "Click an element.", ["tab": tab, "uid": uid], required: ["tab", "uid"]),
        tool("hover", "Move the pointer over an element.", ["tab": tab, "uid": uid], required: ["tab", "uid"]),
        tool(
            "fill",
            "Set a text field or textarea, pick a select option (value or label), or set a checkbox with \"true\"/\"false\". Refuses password fields.",
            ["tab": tab, "uid": uid, "value": string("The value to set.")], required: ["tab", "uid", "value"]),
        tool(
            "type_text", "Type text key by key into the focused element. Refuses password fields.",
            ["tab": tab, "text": string("Text to type.")], required: ["tab", "text"]),
        tool(
            "press_key",
            "Press a key on the focused element, named as KeyboardEvent.key (Enter, Tab, Escape, ArrowDown, a…). Enter in a form field submits its form.",
            ["tab": tab, "key": string("KeyboardEvent.key value."),
             "modifiers": ["type": "array", "items": ["type": "string", "enum": ["Shift", "Control", "Alt", "Meta"]]]],
            required: ["tab", "key"]),
        tool(
            "scroll",
            "Scroll the page, or the element uid, by dy CSS pixels (default: most of a screen). With only uid, scroll that element into view.",
            ["tab": tab, "uid": uid, "dy": ["type": "number", "description": "Pixels; negative scrolls up."]],
            required: ["tab"]),
        tool("screenshot", "PNG of the tab's viewport, at most 1600px wide.", ["tab": tab], required: ["tab"]),
        tool(
            "wait_for", "Wait until text appears on the page, or until it finishes loading when text is omitted.",
            ["tab": tab, "text": string("Text to wait for."),
             "timeout_ms": ["type": "integer", "description": "Default 10000, at most 60000."]],
            required: ["tab"]),
        tool(
            "evaluate_script",
            "Run a JavaScript function such as `() => document.title` in the page and return its JSON result. Only works when the user has allowed scripts.",
            ["tab": tab, "function": string("Function source; may be async.")], required: ["tab", "function"]),
    ]
}
