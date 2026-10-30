import Foundation
import Security

struct AgentFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// the Unix socket the running app serves agent tool calls on, as newline-delimited
/// JSON. both ends are the same sandboxed binary, so the path lands in the one
/// app container they share
nonisolated enum AgentSocket {
    static let path = URL.homeDirectory.appendingPathComponent(".agent/socket").path

    private static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        // sun_path is 104 bytes including the terminator
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    private static func withAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        guard var addr = address() else { return -1 }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func makeSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        if fd >= 0 { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        return fd
    }

    /// a blocking connection to the app, or nil when nothing is listening
    static func connect() -> Int32? {
        let fd = makeSocket()
        guard fd >= 0 else { return nil }
        guard withAddress({ Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// a nonblocking listening socket: dir 0700, socket 0600, any stale file replaced
    static func listen() throws(AgentFailure) -> Int32 {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        if let live = connect() {
            close(live)
            throw AgentFailure("Another copy of Artemis is already serving agents.")
        }
        unlink(path)
        guard address() != nil else { throw AgentFailure("The agent socket path is too long: \(path)") }
        let fd = makeSocket()
        guard fd >= 0, withAddress({ bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0,
            Darwin.listen(fd, 8) == 0
        else {
            let reason = String(cString: strerror(errno))
            if fd >= 0 { close(fd) }
            throw AgentFailure("Couldn't open the agent socket (\(reason)).")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    /// same user and the same code identity as this process; anything unverifiable rejects
    static func peerIsUs(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let attributes = [kSecGuestAttributeAudit as String: Data(bytes: &token, count: Int(length))]
        var guest: SecCode?, me: SecCode?, staticMe: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess,
            let guest, SecCodeCopySelf([], &me) == errSecSuccess, let me,
            SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
            SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    static func line(_ object: Any) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}

extension Data {
    /// removes and returns each complete newline-terminated line
    nonisolated mutating func takeLines() -> [Data] {
        var lines: [Data] = []
        while let newline = firstIndex(of: 0x0A) {
            lines.append(Data(self[startIndex..<newline]))
            removeSubrange(startIndex...newline)
        }
        return lines
    }
}
