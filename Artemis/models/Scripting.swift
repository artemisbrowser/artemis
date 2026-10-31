import AppKit
import SwiftUI
import WebKit

/// AppleScript's view of the browser, as declared in Artemis.sdef. Tabs and
/// spaces are addressed by id from the application, so a reference survives the
/// window it was found through. A locked space shows scripts no tabs.
enum Scripting {
    static let allowsJavaScriptKey = "allowsJavaScriptFromAppleEvents"

    fileprivate static var spaces: [Space] {
        BrowserCore.shared.spaces + BrowserWindows.shared.allManagers.compactMap(\.privateSpace)
    }

    fileprivate static func tabs(of space: Space) -> [BrowserTab] {
        SpaceLock.shared.isLocked(space) ? [] : space.tabs
    }

    fileprivate static var tabs: [BrowserTab] {
        BrowserCore.shared.allEssentials + spaces.flatMap { tabs(of: $0) }
    }

    fileprivate static func space(of tab: BrowserTab) -> Space? {
        spaces.first { $0.tabs.contains { $0 === tab } }
    }

    /// the window a Scout or incognito space belongs to, else the front browser window
    fileprivate static func manager(for space: Space?) -> TabManager? {
        let windows = BrowserWindows.shared
        if let space, let own = windows.allManagers.first(where: { $0.privateSpace?.id == space.id }) {
            return own
        }
        return windows.browserScope
    }

    nonisolated fileprivate static func specifier(key: String, id: UUID) -> NSScriptObjectSpecifier? {
        NSScriptClassDescription(for: NSApplication.self).map {
            NSUniqueIDSpecifier(
                containerClassDescription: $0, containerSpecifier: nil, key: key, uniqueID: id.uuidString)
        }
    }

    fileprivate static func fail(_ command: NSScriptCommand, _ message: String) -> Any? {
        command.scriptErrorNumber = errAEEventFailed
        command.scriptErrorString = message
        return nil
    }

    fileprivate static func code(_ fourCC: String) -> NSNumber {
        NSNumber(value: fourCC.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    private static func keyword(_ fourCC: String) -> UInt32 { code(fourCC).uint32Value }

    /// a JavaScript result as AppleScript: lists stay lists, objects become records
    fileprivate static func descriptor(_ value: Any?) -> NSAppleEventDescriptor {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return NSAppleEventDescriptor(boolean: number.boolValue)
        case let number as NSNumber:
            let double = number.doubleValue
            return double.rounded() == double && abs(double) < Double(Int32.max)
                ? NSAppleEventDescriptor(int32: Int32(double)) : NSAppleEventDescriptor(double: double)
        case let string as String:
            return NSAppleEventDescriptor(string: string)
        case let array as [Any]:
            let list = NSAppleEventDescriptor.list()
            for item in array { list.insert(descriptor(item), at: 0) }
            return list
        case let object as [String: Any]:
            let fields = NSAppleEventDescriptor.list()
            for (key, item) in object {
                fields.insert(NSAppleEventDescriptor(string: key), at: 0)
                fields.insert(descriptor(item), at: 0)
            }
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(fields, forKeyword: keyword("usrf"))
            return record
        default:
            return NSAppleEventDescriptor(typeCode: keyword("msng"))
        }
    }
}

extension NSApplication {
    @objc var scriptSpaces: [ArtemisScriptSpace] { Scripting.spaces.map { ArtemisScriptSpace($0) } }
    @objc var scriptTabs: [BrowserTab] { Scripting.tabs }
}

extension NSWindow {
    private var scriptManager: TabManager? { BrowserWindows.shared.manager(for: self) }

    @objc var scriptActiveTab: BrowserTab? {
        guard let tab = scriptManager?.selectedTab else { return nil }
        return Scripting.tabs.contains { $0 === tab } ? tab : nil
    }

    @objc var scriptActiveSpace: ArtemisScriptSpace? {
        get { scriptManager.map { ArtemisScriptSpace($0.currentSpace) } }
        set { if let newValue { scriptManager?.selectSpace(newValue.space) } }
    }

    @objc var scriptMode: NSNumber? {
        switch scriptManager?.kind {
        case .main: Scripting.code("ArNo")
        case .incognito: Scripting.code("ArIn")
        case .scout: Scripting.code("ArSc")
        case nil: nil
        }
    }

    @objc var scriptTabs: [BrowserTab] {
        guard let manager = scriptManager else { return [] }
        return manager.essentials + Scripting.tabs(of: manager.currentSpace)
    }

    @objc var scriptSpaces: [ArtemisScriptSpace] {
        scriptManager?.allSpaces.map { ArtemisScriptSpace($0) } ?? []
    }
}

@objc(ArtemisScriptSpace)
final class ArtemisScriptSpace: NSObject {
    let space: Space
    let id: UUID

    init(_ space: Space) {
        self.space = space
        id = space.id
    }

    @objc var uniqueID: String { id.uuidString }

    @objc var name: String {
        get { space.name }
        set {
            space.name = newValue
            Scripting.manager(for: space)?.scheduleSave()
        }
    }

    @objc var profileName: String { BrowserCore.shared.profile(of: space).name }
    @objc var isLocked: Bool { SpaceLock.shared.isLocked(space) }
    @objc var scriptTabs: [BrowserTab] { Scripting.tabs(of: space) }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Scripting.specifier(key: "scriptSpaces", id: id)
    }

    @objc func handleFocusScriptCommand(_ command: NSScriptCommand) -> Any? {
        Scripting.manager(for: space)?.selectSpace(space)
        return nil
    }
}

extension BrowserTab {
    @objc var uniqueID: String { id.uuidString }
    @objc var scriptTitle: String { displayTitle }
    @objc var scriptLoading: Bool { isLoading }
    @objc var scriptLocation: NSNumber {
        Scripting.code(isEssential ? "ArFv" : isPinned ? "ArPn" : "ArUp")
    }

    @objc var scriptURL: String {
        get { (url ?? pendingURL ?? lastAttemptedURL)?.absoluteString ?? "" }
        set {
            // JavaScript reaches a page only through `execute`, which the setting guards
            guard !newValue.lowercased().hasPrefix("javascript:"), let target = URLInput.resolve(newValue)
            else { return }
            load(target)
        }
    }

    @objc var scriptMuted: Bool {
        get { isMuted }
        set { setMuted(newValue) }
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Scripting.specifier(key: "scriptTabs", id: id)
    }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        Scripting.manager(for: Scripting.space(of: self))?.close(self)
        return nil
    }

    @objc func handleSelectScriptCommand(_ command: NSScriptCommand) -> Any? {
        Scripting.manager(for: Scripting.space(of: self))?.focus(self)
        return nil
    }

    @objc func handleReloadScriptCommand(_ command: NSScriptCommand) -> Any? {
        reload()
        return nil
    }

    @objc func handleStopScriptCommand(_ command: NSScriptCommand) -> Any? {
        stopLoading()
        return nil
    }

    @objc func handleGoBackScriptCommand(_ command: NSScriptCommand) -> Any? {
        goBack()
        return nil
    }

    @objc func handleGoForwardScriptCommand(_ command: NSScriptCommand) -> Any? {
        goForward()
        return nil
    }

    @objc func handleExecuteScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard UserDefaults.standard.bool(forKey: Scripting.allowsJavaScriptKey) else {
            return Scripting.fail(
                command,
                "JavaScript from Apple Events is turned off. Turn it on in Artemis Settings → Privacy.")
        }
        guard let source = command.evaluatedArguments?["JavaScript"] as? String else {
            return Scripting.fail(command, "No JavaScript given.")
        }
        command.suspendExecution()
        webView.evaluateJavaScript(source) { result, error in
            if let error = error as NSError? {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString =
                    error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            }
            command.resumeExecution(withResult: Scripting.descriptor(result))
        }
        return nil
    }
}

/// `make new tab` and `make new window`: neither can be built by Cocoa's
/// alloc-init, so the standard command is answered here.
@objc(ArtemisMakeCommand)
final class ArtemisMakeCommand: NSCreateCommand {
    nonisolated override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            switch createClassDescription.className {
            case "tab": makeTab()
            case "window": makeWindow()
            default: Scripting.fail(self, "Artemis can only make tabs and windows.")
            }
        }
    }

    private func makeTab() -> Any? {
        let position = arguments?["Location"] as? NSPositionalSpecifier
        position?.evaluate()
        let manager: TabManager?
        let space: Space?
        switch position?.insertionContainer {
        case let window as NSWindow:
            manager = BrowserWindows.shared.manager(for: window)
            space = manager?.currentSpace
        case let scripted as ArtemisScriptSpace:
            manager = Scripting.manager(for: scripted.space)
            space = scripted.space
        default:
            manager = BrowserWindows.shared.browserScope
            space = manager?.currentSpace
        }
        guard let manager, let space else { return Scripting.fail(self, "No browser window is open.") }
        guard !SpaceLock.shared.isLocked(space) else { return Scripting.fail(self, "That space is locked.") }
        let tab = manager.newTab(select: space === manager.currentSpace, in: space)
        if let url = resolvedKeyDictionary["scriptURL"] as? String { tab.scriptURL = url }
        return tab.objectSpecifier
    }

    private func makeWindow() -> Any? {
        let windows = BrowserWindows.shared
        let known = Set(windows.allManagers.map(ObjectIdentifier.init))
        if resolvedKeyDictionary["scriptMode"] as? NSNumber == Scripting.code("ArIn") {
            IncognitoWindow.open()
        } else {
            windows.pendingSpaceID = windows.browserScope?.selectedSpaceID
            IncognitoWindow.openWindow?(id: ArtemisApp.browserWindowID)
        }
        suspendExecution()
        awaitWindow(after: known, attempts: 60)
        return nil
    }

    /// a SwiftUI window registers a beat after it is asked for
    private func awaitWindow(after known: Set<ObjectIdentifier>, attempts: Int) {
        let windows = BrowserWindows.shared
        if let manager = windows.allManagers.first(where: { !known.contains(ObjectIdentifier($0)) }) {
            resumeExecution(withResult: windows.window(of: manager)?.objectSpecifier)
        } else if attempts == 0 {
            resumeExecution(withResult: Scripting.fail(self, "The window didn't open."))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.awaitWindow(after: known, attempts: attempts - 1)
            }
        }
    }
}
