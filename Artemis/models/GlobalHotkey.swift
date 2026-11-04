import AppKit
import Carbon.HIToolbox

/// a key combination Artemis answers system-wide while it runs, through Carbon's
/// `RegisterEventHotKey`, which needs no accessibility permission
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKey: EventHotKeyRef?
    private var installed: EventHandlerRef?
    private var action: (() -> Void)?
    /// the menu item carries the same shortcut, so the press can arrive twice —
    /// once through the menu, once through Carbon
    private var lastFired = Date.distantPast

    private init() {}

    /// the combinations Artemis claims system-wide, so the Carbon constants stay
    /// in the one file that imports Carbon
    struct Combo {
        let keyCode: Int
        let modifiers: Int

        static let commandOptionN = Combo(keyCode: kVK_ANSI_N, modifiers: cmdKey | optionKey)
    }

    func register(_ combo: Combo, action: @escaping () -> Void) {
        unregister()
        self.action = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                MainActor.assumeIsolated { GlobalHotkey.shared.fire() }
                return noErr
            }, 1, &spec, nil, &installed)

        let id = EventHotKeyID(signature: OSType(0x4152_544D), id: 1)  // 'ARTM'
        RegisterEventHotKey(
            UInt32(combo.keyCode), UInt32(combo.modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let installed { RemoveEventHandler(installed) }
        hotKey = nil
        installed = nil
    }

    /// also the way the menu item calls it, so both routes debounce together
    func fire() {
        guard Date().timeIntervalSince(lastFired) > 0.25 else { return }
        lastFired = Date()
        action?()
    }
}
