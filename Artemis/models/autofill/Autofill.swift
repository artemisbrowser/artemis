// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// a frame's live address and card fields, from its last report
struct AutofillFrame {
    let frame: WKFrameInfo
    let origin: String
    /// field types by kind, "address" or "card"
    let kinds: [String: [String]]
}

/// the frame a pick fills first, fixed when its list opens
struct AutofillTarget {
    let frame: WKFrameInfo
    let origin: String
}

enum AutofillChoice: Identifiable {
    case address(SavedAddress)
    case card(SavedCard)

    var id: UUID {
        switch self {
        case .address(let address): address.id
        case .card(let card): card.id
        }
    }

    var kind: String {
        switch self {
        case .address: "address"
        case .card: "card"
        }
    }
}

/// a save or update the person raised by submitting a form; the card number lives only until it's answered
struct AutofillOffer: Identifiable {
    let id = UUID()
    var address: SavedAddress?
    var updatesAddress = false
    var card: SavedCard?
    /// nil keeps a saved card's number
    var number: String?
    var updatesCard = false
    let at = Date()
    /// the popover has opened for it once
    var shown = false
}

/// the rows under a focused field: what the field holds narrows them by prefix, and ↑ and ↓ in the page
/// move `highlighted`
@MainActor
@Observable
final class AutofillList {
    private let all: [AutofillChoice]
    /// the focused field's autofill type
    private let field: String
    var query: String
    var highlighted: Int?

    init(_ all: [AutofillChoice], field: String, query: String) {
        (self.all, self.field, self.query) = (all, field, query)
    }

    var choices: [AutofillChoice] {
        let wanted = Self.fold(query)
        guard !wanted.isEmpty else { return all }
        return all.filter { values(of: $0).contains { Self.fold($0).hasPrefix(wanted) } }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }

    /// what a choice offers this field: a card its holder and last four, an address the field type's value
    private func values(of choice: AutofillChoice) -> [String] {
        let a: SavedAddress
        switch choice {
        case .card(let card): return [card.holder, card.last4]
        case .address(let address): a = address
        }
        let lines = a.streetLines
        switch field {
        case "given-name": return [a.givenName]
        case "family-name": return [a.familyName]
        case "organization": return [a.organization]
        case "street-address", "address-line1": return [lines.first ?? ""]
        case "address-line2": return [lines.dropFirst().first ?? ""]
        case "address-line3": return [lines.dropFirst(2).first ?? ""]
        case "address-level2": return [a.city]
        case "address-level1": return [a.region]
        case "postal-code": return [a.postalCode]
        case "country": return [a.country, Locale.current.localizedString(forRegionCode: a.country) ?? ""]
        case "email": return [a.email]
        case let tel where tel.hasPrefix("tel"):
            return [a.phone, a.phone.filter(\.isNumber), a.phone.split(separator: " ").dropFirst().joined().filter(\.isNumber)]
        default: return [a.name]
        }
    }
}

/// Address and card forms in every frame, watched from an isolated content world: a native list under a focused
/// field, fills of one section per frame, and save offers after a submit.
@MainActor
final class Autofill: NSObject, WKScriptMessageHandler {
    static let shared = Autofill()

    private struct Shown {
        let panel: NSPanel
        let tab: BrowserTab.ID
        weak var webView: WKWebView?
        let list: AutofillList
        let target: AutofillTarget
    }

    private var suggestions: Shown?

    static func install(into controller: WKUserContentController) {
        controller.add(shared, contentWorld: AutofillPage.world, name: AutofillPage.messageName)
        controller.addUserScript(
            WKUserScript(source: AutofillPage.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: AutofillPage.world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = webView.navigationDelegate as? BrowserTab,
            tab.webView === webView, let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }
        let frame = message.frameInfo
        let origin = SitePermissionStore.originString(frame.securityOrigin)
        let shown = suggestions?.tab == tab.id ? suggestions : nil
        switch type {
        case "fields":
            let kinds = body["kinds"] as? [String: [String]] ?? [:]
            tab.autofillFrames[LoginKeys.key(frame)] =
                kinds.isEmpty ? nil : AutofillFrame(frame: frame, origin: origin, kinds: kinds)
        case "focus":
            suggest(body, into: AutofillTarget(frame: frame, origin: origin), in: tab)
        case "dismiss":
            if shown != nil { closeSuggestions() }
        case "highlight":
            shown?.list.highlighted = body["index"] as? Int
        case "filter":
            guard let shown else { return }
            shown.list.query = body["text"] as? String ?? ""
            shown.list.highlighted = nil
            let count = shown.list.choices.count
            guard count > 0 else { return closeSuggestions() }
            webView.evaluateJavaScript("globalThis.__artemisAutofill?.listing(\(count))", in: frame, in: AutofillPage.world)
            // the rows change on SwiftUI's next pass; the panel keeps its top edge
            DispatchQueue.main.async {
                let size = shown.panel.contentView?.fittingSize ?? .zero
                var box = shown.panel.frame
                box.origin.y = box.maxY - size.height
                box.size = size
                shown.panel.setFrame(box, display: true)
                shown.panel.invalidateShadow()
            }
        case "pick":
            guard let shown, let index = body["index"] as? Int, shown.list.choices.indices.contains(index) else { return }
            closeSuggestions()
            Task { await fill(shown.list.choices[index], into: shown.target, in: tab) }
        case "submit":
            learn(body, origin: origin, in: tab)
        default:
            break
        }
    }

    /// the main frame committed a new document
    func pageDidCommit(in tab: BrowserTab) {
        if suggestions?.tab == tab.id { closeSuggestions() }
        tab.autofillFrames = [:]
        if let offer = tab.autofillOffer, Date().timeIntervalSince(offer.at) > 5 { tab.autofillOffer = nil }
    }

    // MARK: - Filling

    /// what a field of `kind` in `target` is offered; cards only where the frame and the page are secure
    func choices(_ kind: String, for target: AutofillTarget, in tab: BrowserTab) -> [AutofillChoice] {
        let store = AutofillStore.shared
        guard kind == "card" else {
            return store.fillsAddresses ? store.addresses(in: tab.loginProfile).map(AutofillChoice.address) : []
        }
        guard store.fillsCards, PasswordStore.isSecure(target.origin), PasswordStore.isSecure(topOrigin(of: tab, or: target.origin))
        else { return [] }
        return store.cards(in: tab.loginProfile).map(AutofillChoice.card)
    }

    private func topOrigin(of tab: BrowserTab, or fallback: String) -> String {
        SitePermissionStore.originString(tab.webView.url) ?? fallback
    }

    /// Fills `choice` into the section it was picked from and into other frames of the page on the same origin as
    /// that frame; nothing crosses origins. A card needs a secure frame and page. Either kind asks the device owner as
    /// its unlock policy says. False when nothing filled.
    @discardableResult
    func fill(_ choice: AutofillChoice, into target: AutofillTarget, in tab: BrowserTab) async -> Bool {
        let store = AutofillStore.shared
        let top = topOrigin(of: tab, or: target.origin)
        let values: [String: Any]
        switch choice {
        case .address(let address):
            guard store.addresses(in: tab.loginProfile).contains(where: { $0.id == address.id }),
                await OwnerUnlock.authenticate(.addresses, "fill your address")
            else { return false }
            values = [
                "given": address.givenName, "family": address.familyName, "organization": address.organization,
                "street": address.streetLines, "city": address.city, "region": address.region,
                "postal": address.postalCode, "country": address.country, "phone": address.phone, "email": address.email,
            ]
        case .card(let card):
            guard store.cards(in: tab.loginProfile).contains(where: { $0.id == card.id }),
                PasswordStore.isSecure(target.origin), PasswordStore.isSecure(top)
            else { return false }
            guard await OwnerUnlock.authenticate(.cards, "fill your \(card.label)") else { return false }
            guard let number = store.number(for: card) else { return false }
            values = [
                "name": card.holder, "number": number, "month": card.expiryMonth, "year": card.expiryYear,
                "brand": card.brand.name,
            ]
        }
        let asked = LoginKeys.key(target.frame)
        var filled = await fill(values, kind: choice.kind, in: target.frame, origin: target.origin, of: tab)
        for (key, other) in tab.autofillFrames
        where key != asked && other.origin == target.origin && other.kinds[choice.kind] != nil {
            if !other.frame.isMainFrame, await !PasswordAutofill.shared.frameIsShown(other.origin, in: tab) { continue }
            filled += await fill(values, kind: choice.kind, in: other.frame, origin: other.origin, of: tab)
        }
        guard filled > 0 else { return false }
        if !tab.isPrivate {
            switch choice {
            case .address(let address): store.markUsed(address)
            case .card(let card): store.markUsed(card)
            }
        }
        return true
    }

    private func fill(
        _ values: [String: Any], kind: String, in frame: WKFrameInfo, origin: String, of tab: BrowserTab
    ) async -> Int {
        let result = try? await tab.webView.callAsyncJavaScript(
            "return globalThis.__artemisAutofill?.fill(origin, values, kind) ?? 0",
            arguments: ["origin": origin, "values": values, "kind": kind],
            in: frame, contentWorld: AutofillPage.world)
        return result as? Int ?? 0
    }

    // MARK: - Suggestions

    private func suggest(_ body: [String: Any], into target: AutofillTarget, in tab: BrowserTab) {
        guard let kind = body["kind"] as? String, let box = body["rect"] as? [String: Any], tab.webView.window != nil
        else { return }
        let list = AutofillList(
            choices(kind, for: target, in: tab), field: body["field"] as? String ?? "", query: body["text"] as? String ?? "")
        let count = list.choices.count
        guard count > 0 else { return closeSuggestions() }
        let number = { (key: String) in (box[key] as? Double) ?? 0 }
        var field = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        Task {
            if box["resolved"] as? Bool == false {
                guard let offset = await PasswordAutofill.shared.frameOffset(of: target.origin, in: tab) else { return }
                field.origin.x += offset.x
                field.origin.y += offset.y
            }
            closeSuggestions(tellingPage: false)
            let view = AutofillSuggestions(
                list: list,
                pick: { choice in
                    self.closeSuggestions()
                    Task { await self.fill(choice, into: target, in: tab) }
                },
                manage: {
                    self.closeSuggestions()
                    ProfilesNavigator.show(.autofill, for: tab.loginProfile)
                })
            guard let panel = suggestionPanel(view, below: field, in: tab.webView) else { return }
            suggestions = Shown(panel: panel, tab: tab.id, webView: tab.webView, list: list, target: target)
            tab.webView.evaluateJavaScript(
                "globalThis.__artemisAutofill?.listing(\(count))", in: target.frame, in: AutofillPage.world)
        }
    }

    /// `tellingPage` ends ↑ and ↓ in the field it was under
    private func closeSuggestions(tellingPage: Bool = true) {
        guard let shown = suggestions else { return }
        suggestions = nil
        shown.panel.parent?.removeChildWindow(shown.panel)
        shown.panel.orderOut(nil)
        if tellingPage {
            shown.webView?.evaluateJavaScript(
                "globalThis.__artemisAutofill?.listing(0)", in: shown.target.frame, in: AutofillPage.world)
        }
    }

    // MARK: - Saving

    func learn(_ body: [String: Any], origin: String, in tab: BrowserTab) {
        let store = AutofillStore.shared
        guard store.offersToSave, !tab.isPrivate else { return }
        let profile = tab.loginProfile
        var offer = AutofillOffer()
        if let found = body["address"] as? [String: Any] {
            let text = { (key: String) in (found[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let country = (found["country"] as? [String] ?? [text("country")]).lazy.compactMap(AutofillStore.countryCode).first
            let address = SavedAddress(
                givenName: text("given"), familyName: text("family"), organization: text("organization"),
                street: text("street"), city: text("city"), region: text("region"), postalCode: text("postal"),
                country: country ?? "", phone: text("phone"), email: text("email"), profileID: PasswordStore.stored(profile))
            if let saved = store.addresses(in: profile).first(where: { $0.isSamePlace(as: address) }) {
                let merged = saved.merging(address)
                if merged != saved { (offer.address, offer.updatesAddress) = (merged, true) }
            } else {
                offer.address = address
            }
        }
        if let found = body["card"] as? [String: Any], let number = found["number"] as? String, CardBrand.isValid(number),
            let month = found["month"] as? Int, (1...12).contains(month), let year = found["year"] as? Int,
            (2000...2100).contains(year), PasswordStore.isSecure(origin),
            PasswordStore.isSecure(topOrigin(of: tab, or: origin))
        {
            let holder = (found["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if var card = store.card(numbered: number, in: profile) {
                let saved = card
                (card.expiryMonth, card.expiryYear) = (month, year)
                if !holder.isEmpty { card.holder = holder }
                if card != saved { (offer.card, offer.updatesCard) = (card, true) }
            } else {
                offer.card = SavedCard(
                    holder: holder, expiryMonth: month, expiryYear: year, brand: CardBrand(number: number),
                    last4: String(number.suffix(4)), profileID: PasswordStore.stored(profile))
                offer.number = number
            }
        }
        guard offer.address != nil || offer.card != nil else { return }
        tab.autofillOffer = offer
    }

    func accept(in tab: BrowserTab) {
        guard let offer = tab.autofillOffer else { return }
        tab.autofillOffer = nil
        if let address = offer.address { AutofillStore.shared.save(address) }
        if let card = offer.card { AutofillStore.shared.save(card, number: offer.number) }
    }
}

/// the list under a focused address or card field
struct AutofillSuggestions: View {
    let list: AutofillList
    let pick: (AutofillChoice) -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(list.choices.enumerated()), id: \.element.id) { index, choice in
                switch choice {
                case .address(let address):
                    SuggestionRow(
                        icon: "house", title: address.name.isEmpty ? address.summary : address.name,
                        detail: address.name.isEmpty ? nil : address.summary, isHighlighted: list.highlighted == index
                    ) { pick(choice) }
                case .card(let card):
                    SuggestionRow(
                        icon: "creditcard", title: card.label,
                        detail: card.holder.isEmpty ? "Expires \(card.expiry)" : "\(card.holder), expires \(card.expiry)",
                        isHighlighted: list.highlighted == index
                    ) { pick(choice) }
                }
            }
            Divider().padding(.vertical, 2)
            SuggestionRow(icon: "gearshape", title: "Manage Autofill…", detail: nil, action: manage)
        }
        .padding(6)
        .frame(width: 260)
        .background(VisualEffectView(material: .menu, blending: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
