// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import CoreImage.CIFilterBuiltins

/// "Gift Artemis to a Friend": one line and the site's invite page, whose link preview is the ticket.
enum Gift {
    static let title = "Gift Artemis to a Friend"
    static let link = URL(string: "https://artemisbrowser.app/invite")!
    static let items: [Any] = ["This is my new favourite browser for Mac. Check it out:", link]

    /// the link as a QR code, one pixel a module, with its quiet margin
    static let code: CGImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
    }()

    /// the card over `manager`'s window, which comes to the front
    static func open(in manager: TabManager) {
        BrowserWindows.shared.window(of: manager)?.makeKeyAndOrderFront(nil)
        manager.isGiftVisible = true
    }

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    /// straight into the service's own window; AirDrop takes the link alone
    static func send(_ name: NSSharingService.Name) {
        NSSharingService(named: name)?.perform(withItems: name == .sendViaAirDrop ? [link] : items)
    }

    /// the system's share menu out of `anchor`'s side, level with its top `face` points; `chose` runs
    /// once a service is picked from it. A press on `anchor` while the menu is open closes it and goes no further
    static func more(from anchor: NSView, face: CGFloat, chose: @escaping () -> Void) {
        let picker = NSSharingServicePicker(items: items)
        let open = OpenMenu(chose: chose)
        open.press = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak anchor] event in
            guard let anchor, event.window === anchor.window,
                anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
            else { return event }
            picker.close()
            return nil
        }
        picker.delegate = open
        menu = open
        picker.show(
            relativeTo: anchor.bounds.divided(atDistance: face, from: .maxYEdge).slice, of: anchor, preferredEdge: .maxX)
    }

    /// alive until the menu reports its choice or its closing: the picker holds its delegate weakly,
    /// and a picker released mid-close stays on screen
    private static var menu: OpenMenu?

    private final class OpenMenu: NSObject, NSSharingServicePickerDelegate {
        let chose: () -> Void
        var press: Any?

        init(chose: @escaping () -> Void) { self.chose = chose }

        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if service != nil { chose() }
            // a turn later: the press that dismissed the menu has still to meet the monitor
            DispatchQueue.main.async { [self] in
                if let press { NSEvent.removeMonitor(press) }
                press = nil
                if Gift.menu === self { Gift.menu = nil }
            }
        }
    }
}
