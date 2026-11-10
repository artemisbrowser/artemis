// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CoreServices
import Foundation

/// Yab keeps its spaces where only its AppleScript dictionary reaches them, so
/// detect finds the data, cookies and history, and `live` asks the running app for spaces.
nonisolated enum YabImport {
    private static let bundleID = "dev.serafim.fast"
    /// under Library; the generic Chromium scan skips it
    static let chromium = "Application Support/Yab/Chromium"
    private static let script = """
        on txt(v)
            if v is missing value then return ""
            set AppleScript's text item delimiters to {character id 30, character id 31}
            set parts to text items of (v as text)
            set AppleScript's text item delimiters to " "
            set s to parts as text
            set AppleScript's text item delimiters to ""
            return s
        end txt
        set RS to character id 30
        set US to character id 31
        set out to ""
        with timeout of 10 seconds
            tell application id "dev.serafim.fast"
                repeat with s in spaces of window 1
                    set out to out & "space" & US & my txt(id of s) & US & my txt(title of s) & US & my txt(icon of s) & US & my txt(color of s) & RS
                    repeat with t in tabs of s
                        set loc to (location of t) as text
                        set out to out & "tab" & US & loc & US & my txt(title of t) & US & my txt(URL of t) & RS
                    end repeat
                end repeat
            end tell
        end timeout
        return out
        """

    /// never sends an Apple Event
    static func detect(home: URL) -> [ImportedBrowser] {
        let files = FileManager.default
        let library = home.appending(path: "Library")
        let jar = library.appending(path: "HTTPStorages/\(bundleID).binarycookies")
        let store = library.appending(
            path: "WebKit/\(bundleID)/WebsiteDataStore/00000000-0000-0000-0000-000000000001/Cookies/Cookies.binarycookies")
        let roots = ["Application Support/Yab", "Application Support/Fast", "WebKit/\(bundleID)"].map { library.appending(path: $0) } + [jar]
        guard let root = roots.first(where: { files.fileExists(atPath: $0.path) }) else { return [] }
        let jars = [jar, store].filter { files.fileExists(atPath: $0.path) }
        let history = library.appending(path: "Application Support/Yab/history.json")
        let visits = files.fileExists(atPath: history.path) ? Self.history(history).count : 0
        let profile = ImportedProfile(
            id: Importers.stableID("\(bundleID)/profile/default"), key: "default", name: "Yab", isDefault: true, folder: root,
            history: visits > 0 ? .yab(history) : nil,
            cookies: jars.map { .binary($0) }, logins: .csvOnly(hint: "In the Passwords app, choose File > Export All Passwords to File."),
            historyCount: visits, cookieCount: jars.reduce(0) { $0 + BinaryCookies.count($1) })
        return [
            ImportedBrowser(
                name: "Yab", bundleID: bundleID, family: .yab, root: root, profiles: [profile],
                wall: isRunning(bundleID) ? nil : .notRunning)
        ]
    }

    /// Yab's own history.json, which covers both its engines; `last` is seconds since 2001
    static func history(_ file: URL) -> [ImportedVisit] {
        struct Row: Decodable {
            let url: String
            let title: String?
            let last: Double
            let count: Int?
        }
        guard let data = try? Data(contentsOf: file), let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.sorted { $0.last > $1.last }.prefix(Importers.historyLimit).map {
            ImportedVisit(
                url: $0.url, title: $0.title ?? "", lastVisited: Date(timeIntervalSinceReferenceDate: $0.last), visitCount: $0.count ?? 1)
        }
    }

    /// reads Yab's spaces over AppleScript, which may raise the Automation prompt
    static func live(_ browser: ImportedBrowser) async -> ImportedBrowser {
        var out = browser
        switch await permission() {
        case noErr: break
        case OSStatus(procNotFound):
            out.wall = .notRunning
            return out
        default:
            out.wall = .automationDenied
            return out
        }
        let (reply, error) = await run(script)
        switch error {
        case procNotFound, connectionInvalid: out.wall = .notRunning
        case Int(errAEEventNotPermitted): out.wall = .automationDenied
        case Int(errAEIllegalIndex), Int(errAENoSuchObject): out.wall = .noWindow
        default:
            guard error == nil, let reply, !out.profiles.isEmpty else {
                out.wall = .noReply
                break
            }
            let read = parse(reply)
            out.profiles[0].spaces = read.spaces
            out.profiles[0].favourites = read.favourites
            out.wall = nil
        }
        return out
    }

    /// `source` run by osascript off main: its reply, or AppleScript's error number
    @concurrent private static func run(_ source: String) async -> (reply: String?, error: Int?) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return (nil, nil) }
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        let failure = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // stderr ends "execution error: … (-1728)"
            return (nil, failure.split(separator: "(").last.flatMap { Int($0.prefix { $0 != ")" }) })
        }
        return (String(decoding: reply.dropLast(reply.last == 0x0A ? 1 : 0), as: UTF8.self), nil)
    }

    /// Yab's reply to `script`: records split by U+001E, fields by U+001F. A
    /// `space` record (id, title, icon, colour) opens a space that later `tab`
    /// records (location, title, URL) fill; top-app tabs are the favourites.
    static func parse(_ reply: String) -> (spaces: [ImportedSpace], favourites: [ImportedTab]) {
        var spaces: [ImportedSpace] = []
        var favourites: [ImportedTab] = []
        for record in reply.split(separator: "\u{1E}") {
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "space", fields.count >= 5 {
                spaces.append(
                    ImportedSpace(
                        id: Importers.stableID("\(bundleID)/default/space/\(fields[1])"), name: fields[2].isEmpty ? "Space" : fields[2],
                        icon: fields[3].isEmpty ? nil : fields[3], colors: RGBA(hex: fields[4]).map { [$0] } ?? []))
            }
            guard fields.first == "tab", fields.count >= 4, !fields[3].isEmpty else { continue }
            let tab = ImportedTab(url: fields[3], title: fields[2].isEmpty ? nil : fields[2])
            switch fields[1].lowercased().filter({ !$0.isWhitespace }) {
            case "topapp": if !favourites.contains(where: { $0.url == tab.url }) { favourites.append(tab) }
            case "pinned" where !spaces.isEmpty: spaces[spaces.count - 1].pinned.append(.tab(tab))
            default: if !spaces.isEmpty { spaces[spaces.count - 1].today.append(.tab(tab)) }
            }
        }
        return (spaces, favourites)
    }

    /// whether a process runs from an app bundle whose Info.plist names
    /// `bundleID`, from the kernel's process list and executable paths
    static func isRunning(_ bundleID: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var checked: Set<String> = []
        for pid in pids.prefix(max(0, count)) where proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let inside = executable.range(of: ".app/Contents/MacOS/", options: .backwards) else { continue }
            let app = String(executable[..<inside.lowerBound]) + ".app"
            guard checked.insert(app).inserted else { continue }
            if NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String == bundleID { return true }
        }
        return false
    }

    /// the Automation check, which blocks until the user answers any prompt
    @concurrent private static func permission() async -> OSStatus {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return OSStatus(procNotFound) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
    }
}
