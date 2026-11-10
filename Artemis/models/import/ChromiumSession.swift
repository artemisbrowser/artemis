// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// Chromium's SNSS command logs: `Session_*` holds the open windows, `Tabs_*`
/// the recently closed tabs. Upstream and Vivaldi number the commands differently.
nonisolated enum ChromiumSession {
    enum Dialect { case upstream, vivaldi }

    enum Log { case session, tabs }

    struct Command {
        let id: UInt8
        let body: [UInt8]
    }

    enum Pick {
        /// the commands of the chosen log and when it was last written
        case commands([Command], Date)
        /// the current log is encrypted and there is no key
        case sealed
        case none
    }

    struct Tab {
        var url: String
        var title: String?
        var pinned: Bool
        var group: String?
        var split: String?
        /// AddTabExtraData pairs, where Brave keeps its tree
        var extras: [String: String]
        /// Vivaldi's `vivExtData` JSON
        var extData: String?
    }

    struct Window {
        var id: Int32
        var title: String?
        /// in strip order
        var tabs: [Tab]
    }

    struct Group {
        var title: String
        var collapsed: Bool
    }

    struct Session {
        /// open normal windows, oldest first
        var windows: [Window] = []
        var groups: [String: Group] = [:]
        var splits: [String: SplitOrientation] = [:]
        /// ids the dialect has no entry for, with how often each came
        var unknown: [UInt8: Int] = [:]
    }

    struct Closed {
        var url: String
        var title: String?
        var closedAt: Date
    }

    // MARK: - Choosing the log

    /// Chromium's own choice: the newest cleartext log with the marker, unless an
    /// encrypted one was started more than 60 s after it was last written; then
    /// the legacy files in the profile root
    static func pick(_ profile: URL, _ log: Log, key: Data?) -> Pick {
        let prefix = log == .session ? "Session_" : "Tabs_"
        var clear: (commands: [Command], written: Date)?
        for (file, _) in logs(profile.appending(path: "Sessions"), prefix) {
            guard let data = try? Data(contentsOf: file), let commands = parse(data, key: nil),
                commands.contains(where: { $0.id == marker })
            else { continue }
            clear = (commands, ChromiumData.modified(file) ?? .distantPast)
            break
        }
        for (file, started) in logs(profile.appending(path: "Sessions_Encrypted"), prefix) {
            if let clear, clear.written >= started - 60 { break }
            guard let data = try? Data(contentsOf: file), version(data) == 5 else { continue }
            guard let key else { return .sealed }
            if let commands = parse(data, key: key), commands.contains(where: { $0.id == marker }) {
                return .commands(commands, ChromiumData.modified(file) ?? started)
            }
        }
        if let clear { return .commands(clear.commands, clear.written) }
        for name in log == .session ? ["Current Session", "Last Session"] : ["Current Tabs", "Last Tabs"] {
            let file = profile.appending(path: name)
            if let data = try? Data(contentsOf: file), let commands = parse(data, key: nil) {
                return .commands(commands, ChromiumData.modified(file) ?? .distantPast)
            }
        }
        return .none
    }

    /// `<prefix><µs since 1601>` files, newest first
    private static func logs(_ folder: URL, _ prefix: String) -> [(URL, Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (URL, Int64)? in
            guard name.hasPrefix(prefix), let stamp = Int64(name.dropFirst(prefix.count)) else { return nil }
            return (folder.appending(path: name), stamp)
        }
        .sorted { $0.1 > $1.1 }
        .map { ($0.0, ChromiumData.date($0.1)) }
    }

    private static let marker: UInt8 = 255

    private static func version(_ data: Data) -> Int32? {
        let bytes = [UInt8](data.prefix(8))
        guard bytes.count == 8, bytes[0..<4].elementsEqual([0x53, 0x4E, 0x53, 0x53]) else { return nil }
        return int32(bytes, 4)
    }

    /// nil when the header is wrong, or the file is encrypted and `key` is nil;
    /// a truncated last record is dropped, a version 5 record that won't open skipped
    private static func parse(_ data: Data, key: Data?) -> [Command]? {
        let bytes = [UInt8](data)
        var commands: [Command] = []
        var at = 8
        switch version(data) {
        // 102: Yandex, upstream's framing and numbering plus its own ids from 100
        case 1, 3, 102:
            while at + 2 <= bytes.count {
                let size = Int(le(bytes, at, 2))
                at += 2
                guard size > 0, at + size <= bytes.count else { break }
                commands.append(Command(id: bytes[at], body: Array(bytes[at + 1..<at + size])))
                at += size
            }
        case 5:
            guard let key else { return nil }
            while at + 4 <= bytes.count {
                let size = Int(le(bytes, at, 4))
                at += 4
                guard size > 0, size <= bytes.count - at else { break }
                if let plain = BrowserKeychain.open(Data(bytes[at..<at + size]), key: key), let id = plain.first {
                    commands.append(Command(id: id, body: Array(plain.dropFirst())))
                }
                at += size
            }
        default:
            return nil
        }
        return commands
    }

    // MARK: - Open windows

    private enum Op {
        case tabWindow, tabIndex, navigation, selectedNavigation, windowType, pinned, appName, tabClosed
        case windowClosed, pruned, tabGroup, groupMetadata, windowTitle, tabExtra, splitTab
        case splitData, extData, ignored
    }

    private static let upstream = ops(
        [
            24: .pruned, 25: .tabGroup, 27: .groupMetadata, 31: .windowTitle, 33: .tabExtra, 36: .splitTab,
            37: .splitData,
        ], ignoring: [21, 22, 23, 26, 28, 29, 30, 32, 34, 35])

    private static let vivaldi = ops(
        [
            21: .extData, 26: .pruned, 27: .tabGroup, 29: .groupMetadata, 33: .windowTitle, 35: .tabExtra,
            38: .splitTab, 39: .splitData,
        ], ignoring: [22, 23, 24, 25, 30, 31, 32, 34, 36, 37, 200, 201, 202])

    private static func ops(_ own: [UInt8: Op], ignoring: [UInt8]) -> [UInt8: Op] {
        let shared: [UInt8: Op] = [
            0: .tabWindow, 2: .tabIndex, 6: .navigation, 7: .selectedNavigation, 9: .windowType, 12: .pinned,
            15: .appName, 16: .tabClosed, 17: .windowClosed,
        ]
        let skipped = (ignoring + [1, 3, 4, 5, 8, 10, 11, 13, 14, 18, 19, 20, marker]).map { ($0, Op.ignored) }
        return shared.merging(own) { $1 }.merging(skipped) { kept, _ in kept }
    }

    private struct Draft {
        var window: Int32 = 0
        var index = 0
        /// by navigation index
        var navigations: [Int: (url: String, title: String)] = [:]
        var selected = -1
        var pinned = false
        var group: String?
        var split: String?
        var extras: [String: String] = [:]
        var extData: String?
    }

    /// Replays a session log the way Chromium restores it. Raw payloads of the
    /// wrong size and pickles that won't read are skipped.
    static func replay(_ commands: [Command], dialect: Dialect) -> Session {
        let ops = dialect == .upstream ? upstream : vivaldi
        var session = Session()
        var tabs: [Int32: Draft] = [:]
        var windows: [Int32: (normal: Bool, app: Bool, title: String?)] = [:]
        var closed: Set<Int32> = []
        let plain = (normal: true, app: false, title: String?.none)
        for command in commands {
            guard let op = ops[command.id] else {
                session.unknown[command.id, default: 0] += 1
                continue
            }
            let b = command.body
            var pickle = Pickle(b)
            switch op {
            case .tabWindow where b.count == 8:
                tabs[int32(b, 4), default: Draft()].window = int32(b, 0)
            case .tabIndex where b.count == 8:
                tabs[int32(b, 0), default: Draft()].index = Int(int32(b, 4))
            case .navigation:
                guard let nav = navigation(b) else { continue }
                tabs[nav.tab, default: Draft()].navigations[nav.index] = (nav.url, nav.title)
            case .selectedNavigation where b.count == 8:
                tabs[int32(b, 0), default: Draft()].selected = Int(int32(b, 4))
            case .windowType where b.count == 8:
                windows[int32(b, 0), default: plain].normal = int32(b, 4) == 0
            case .pinned where b.count == 8:
                tabs[int32(b, 0), default: Draft()].pinned = b[4] != 0
            case .appName:
                guard let window = pickle?.int32(), let name = pickle?.string() else { continue }
                windows[window, default: plain].app = !name.isEmpty
            case .tabClosed where b.count == 16:
                tabs[int32(b, 0)] = nil
            case .windowClosed where b.count == 16:
                windows[int32(b, 0)] = nil
                closed.insert(int32(b, 0))
            case .pruned where b.count == 12:
                let (index, count) = (Int(int32(b, 4)), Int(int32(b, 8)))
                guard index >= 0, count > 0 else { continue }
                prune(&tabs[int32(b, 0), default: Draft()], index: index, count: count)
            case .tabGroup where b.count == 32:
                tabs[int32(b, 0), default: Draft()].group = b[24] != 0 ? token(le(b, 8, 8), le(b, 16, 8)) : nil
            case .splitTab where b.count == 32:
                tabs[int32(b, 0), default: Draft()].split = b[24] != 0 ? token(le(b, 8, 8), le(b, 16, 8)) : nil
            case .groupMetadata:
                guard let group = pickle?.token(), let title = pickle?.string16(), pickle?.uint32() != nil else { continue }
                session.groups[group] = Group(title: title, collapsed: pickle?.bool() ?? false)
            case .splitData:
                guard let split = pickle?.token(), pickle?.double() != nil, let layout = pickle?.string() else { continue }
                session.splits[split] = layout == "Horizontal" ? .rows : .columns
            case .windowTitle:
                guard let window = pickle?.int32(), let title = pickle?.string() else { continue }
                windows[window, default: plain].title = title
            case .tabExtra:
                guard let tab = pickle?.int32(), let key = pickle?.string(), let value = pickle?.string() else { continue }
                tabs[tab, default: Draft()].extras[key] = value
            case .extData:
                guard let tab = pickle?.int32(), let data = pickle?.string() else { continue }
                tabs[tab, default: Draft()].extData = data
            default:
                continue
            }
        }

        var strips: [Int32: [(id: Int32, index: Int, tab: Tab)]] = [:]
        for (id, draft) in tabs where draft.window != 0 && !closed.contains(draft.window) {
            let window = windows[draft.window] ?? plain
            let indices = draft.navigations.keys.sorted()
            guard window.normal, !window.app, let last = indices.last else { continue }
            let nav = draft.navigations[indices.first { $0 >= draft.selected } ?? last]!
            let tab = Tab(
                url: nav.url, title: nav.title.isEmpty ? nil : nav.title, pinned: draft.pinned,
                group: draft.group, split: draft.split, extras: draft.extras,
                extData: draft.extData)
            strips[draft.window, default: []].append((id, draft.index, tab))
        }
        session.windows = strips.keys.sorted().map { id in
            let tabs = strips[id]!.sorted { ($0.index, $0.id) < ($1.index, $1.id) }.map(\.tab)
            return Window(id: id, title: windows[id]?.title, tabs: tabs)
        }
        return session
    }

    /// Chromium's prune: drop `count` entries from `index`, shift the rest down
    private static func prune(_ tab: inout Draft, index: Int, count: Int) {
        if tab.selected >= index, tab.selected < index + count {
            tab.selected = max(index - 1, 0)
        } else if tab.selected >= index + count {
            tab.selected -= count
        }
        var kept: [Int: (url: String, title: String)] = [:]
        for (at, nav) in tab.navigations where at < index || at >= index + count {
            kept[at < index ? at : at - count] = nav
        }
        tab.navigations = kept
    }

    private static func navigation(_ body: [UInt8]) -> (tab: Int32, index: Int, url: String, title: String)? {
        guard var pickle = Pickle(body), let tab = pickle.int32(), let index = pickle.int32(),
            let url = pickle.string(), let title = pickle.string16()
        else { return nil }
        return (tab, Int(index), url, title)
    }

    // MARK: - Recently closed

    /// Closed tabs, and the tabs of closed windows, groups and splits, newest
    /// first. A tab with no timestamp takes `written`.
    static func closed(_ commands: [Command], written: Date) -> [Closed] {
        var entries: [(id: Int32, stamp: Int64, tabs: [(id: Int32, selected: Int, navigations: [(String, String)])])] =
            []
        var pending = 0
        var inTab = false
        func remove(_ id: Int32) {
            if let at = entries.firstIndex(where: { $0.id == id }) {
                entries.remove(at: at)
                return
            }
            for at in entries.indices {
                if let tab = entries[at].tabs.firstIndex(where: { $0.id == id }) {
                    entries[at].tabs.remove(at: tab)
                    return
                }
            }
        }
        func open(_ id: Int32, _ stamp: Int64, tabs: Int32) {
            remove(id)
            entries.append((id, stamp, []))
            pending = Int(tabs)
            inTab = false
        }

        replay: for command in commands {
            let b = command.body
            var pickle = Pickle(b)
            switch command.id {
            case 1:
                guard inTab, let nav = navigation(b) else { break replay }
                entries[entries.count - 1].tabs[entries[entries.count - 1].tabs.count - 1].navigations
                    .append((nav.url, nav.title))
            case 2:
                guard pending == 0, b.count == 4 else { break replay }
                remove(int32(b, 0))
                inTab = false
            case 4:
                guard b.count == 16 || b.count == 8 else { break replay }
                let tab = (id: int32(b, 0), selected: Int(int32(b, 4)), navigations: [(String, String)]())
                if pending > 0 {
                    entries[entries.count - 1].tabs.append(tab)
                    pending -= 1
                } else {
                    remove(tab.id)
                    entries.append((tab.id, b.count == 16 ? int64(b, 8) : 0, [tab]))
                }
                inTab = true
            case 9:
                guard pending == 0, let id = pickle?.int32(), pickle?.int32() != nil, let count = pickle?.int32(),
                    let stamp = pickle?.int64(), count > 0
                else { break replay }
                open(id, stamp, tabs: count)
            case 13:
                guard pending == 0, pickle?.token() != nil, let id = pickle?.int32(), let count = pickle?.int32(),
                    pickle?.int32() != nil, pickle?.string16() != nil, pickle?.uint32() != nil, count > 0
                else { break replay }
                if pickle?.bool() == true, pickle?.string()?.isEmpty != false { break replay }
                guard let stamp = pickle?.int64() else { break replay }
                open(id, stamp, tabs: count)
            case 15:
                guard pending == 0, pickle?.token() != nil, let id = pickle?.int32(), let stamp = pickle?.int64() else {
                    break replay
                }
                open(id, stamp, tabs: 2)
            default:
                continue
            }
        }

        return entries.reversed().flatMap { entry in
            entry.tabs.compactMap { tab -> Closed? in
                guard !tab.navigations.isEmpty else { return nil }
                let (url, title) = tab.navigations[min(max(tab.selected, 0), tab.navigations.count - 1)]
                return Closed(
                    url: url, title: title.isEmpty ? nil : title,
                    closedAt: entry.stamp > 0 ? ChromiumData.date(entry.stamp) : written)
            }
        }
    }

    // MARK: - Bytes

    /// `base::Pickle`: a u32 payload size, then 4-byte aligned fields; a read past
    /// the end is nil, which Chromium treats as an absent trailing field
    private struct Pickle {
        private let bytes: [UInt8]
        private var at: Int

        init?(_ body: [UInt8]) {
            guard body.count >= 4 else { return nil }
            let start = body.count - Int(le(body, 0, 4))
            guard start >= 4, start % 4 == 0 else { return nil }
            bytes = body
            at = start
        }

        private mutating func take(_ count: Int) -> Int? {
            guard count >= 0, count <= bytes.count - at else { return nil }
            defer { at += (count + 3) & ~3 }
            return at
        }

        mutating func int32() -> Int32? { take(4).map { ChromiumSession.int32(bytes, $0) } }
        mutating func uint32() -> UInt32? { take(4).map { UInt32(le(bytes, $0, 4)) } }
        mutating func int64() -> Int64? { take(8).map { ChromiumSession.int64(bytes, $0) } }
        mutating func double() -> Double? { take(8).map { Double(bitPattern: le(bytes, $0, 8)) } }
        mutating func bool() -> Bool? { int32().map { $0 != 0 } }

        mutating func string() -> String? {
            guard let count = int32(), let start = take(Int(count)) else { return nil }
            return String(decoding: bytes[start..<start + Int(count)], as: UTF8.self)
        }

        mutating func string16() -> String? {
            guard let count = int32(), count >= 0, let start = take(Int(count) * 2) else { return nil }
            return String(decoding: (0..<Int(count)).map { UInt16(le(bytes, start + 2 * $0, 2)) }, as: UTF16.self)
        }

        mutating func token() -> String? {
            guard let high = take(8), let low = take(8) else { return nil }
            return ChromiumSession.token(le(bytes, high, 8), le(bytes, low, 8))
        }
    }

    private static func token(_ high: UInt64, _ low: UInt64) -> String {
        String(high, radix: 16) + ":" + String(low, radix: 16)
    }

    private static func le(_ bytes: [UInt8], _ at: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * $1) }
    }

    private static func int32(_ bytes: [UInt8], _ at: Int) -> Int32 {
        Int32(truncatingIfNeeded: le(bytes, at, 4))
    }

    private static func int64(_ bytes: [UInt8], _ at: Int) -> Int64 {
        Int64(bitPattern: le(bytes, at, 8))
    }
}
