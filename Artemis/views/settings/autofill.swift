// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// one profile's addresses and cards, and how Artemis offers them
struct AutofillSettings: View {
    let profileID: Profile.ID
    @AppStorage(AutofillStore.fillAddressesKey) private var fillsAddresses = true
    @AppStorage(AutofillStore.fillCardsKey) private var fillsCards = true
    @AppStorage(AutofillStore.offerToSaveKey) private var offersToSave = true
    @State private var editingAddress: SavedAddress?
    @State private var editingCard: SavedCard?
    private var store: AutofillStore { .shared }

    var body: some View {
        Form {
            if store.isUnreadable {
                Section {
                    Label("Artemis couldn't read its saved addresses and cards, so nothing new will be saved.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(store.addresses(in: profileID)) { address in
                    LabeledContent {
                        rowButtons(edit: { open(address) }) {
                            if confirmDelete("Delete this address?", address.summary) { store.delete(address) }
                        }
                    } label: {
                        Text(address.name.isEmpty ? address.summary : address.name)
                        if !address.name.isEmpty { Text(address.summary) }
                    }
                }
                Button("Add Address…") { editingAddress = SavedAddress(profileID: PasswordStore.stored(profileID)) }
            } header: {
                InfoLabel("Addresses", info: "Only this profile's. They stay on this Mac.")
            }

            Section {
                ForEach(store.cards(in: profileID)) { card in
                    LabeledContent {
                        rowButtons(edit: { open(card) }) {
                            if confirmDelete("Delete \(card.label)?", "Its number is removed from your keychain.") {
                                store.delete(card)
                            }
                        }
                    } label: {
                        Text(card.label)
                        Text(card.holder.isEmpty ? "Expires \(card.expiry)" : "\(card.holder), expires \(card.expiry)")
                    }
                }
                Button("Add Card…") {
                    editingCard = SavedCard(
                        expiryMonth: 1, expiryYear: Calendar.current.component(.year, from: Date()), brand: .other,
                        last4: "", profileID: PasswordStore.stored(profileID))
                }
            } header: {
                InfoLabel("Cards", info: "Card numbers are kept in your keychain. Security codes are never saved.")
            }

            Section {
                Toggle(isOn: $fillsAddresses) {
                    InfoLabel("Fill addresses", info: "Suggests a saved address when you click into an address field.")
                }
                Toggle(isOn: $fillsCards) {
                    InfoLabel("Fill cards", info: "Suggests a saved card when you click into a card field on a secure page.")
                }
                Toggle(isOn: $offersToSave) {
                    InfoLabel(
                        "Offer to save",
                        info: "Asks to save a new address or card after you submit a form. Incognito windows never save.")
                }
            } header: {
                InfoLabel("Options", info: "These apply to every profile.")
            }

            Section {
                UnlockPicker(.cards, info: "Covers filling cards and seeing their numbers.")
                UnlockPicker(.addresses, info: "Covers filling and editing addresses.")
            } header: {
                UnlockHeader()
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingAddress) { AddressEditor(address: $0) }
        .sheet(item: $editingCard) { CardEditor(card: $0) }
    }

    private func open(_ address: SavedAddress) {
        Task { if await OwnerUnlock.authenticate(.addresses, "edit your address") { editingAddress = address } }
    }

    private func open(_ card: SavedCard) {
        Task { if await OwnerUnlock.authenticate(.cards, "see your \(card.label)") { editingCard = card } }
    }

    private func rowButtons(edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        HStack {
            Button("Edit", action: edit).controlSize(.small)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete")
        }
    }
}

/// a grouped form whose ideal height is its rows, so a fitted sheet shows them all and scrolls only when it
/// gets less room than that
private struct FittedForm: ViewModifier {
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom
            } action: { _, rows in
                height = rows
            }
            .frame(idealHeight: height)
    }
}

private struct AddressEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var address: SavedAddress

    private static let countries: [(code: String, name: String)] = Locale.Region.isoRegions
        .map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code, $0) } }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("First name", text: $address.givenName)
                    TextField("Last name", text: $address.familyName)
                    TextField("Company", text: $address.organization)
                }
                Section {
                    TextField("Street", text: $address.street, axis: .vertical).lineLimit(1...3)
                    TextField("Town or city", text: $address.city)
                    TextField("State or region", text: $address.region)
                    TextField("Postcode", text: $address.postalCode)
                    Picker("Country", selection: $address.country) {
                        Text("None").tag("")
                        ForEach(Self.countries, id: \.code) { Text($0.name).tag($0.code) }
                    }
                }
                Section {
                    TextField("Phone", text: $address.phone)
                    TextField("Email", text: $address.email)
                }
            }
            .modifier(FittedForm())
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    AutofillStore.shared.save(address)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.streetLines.isEmpty && address.name.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
        .presentationSizing(.fitted)
    }
}

private struct CardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var card: SavedCard
    @State private var number = ""
    @State private var refused = false
    @FocusState private var editingNumber: Bool

    private var isNew: Bool { !AutofillStore.shared.cards.contains { $0.id == card.id } }
    private var years: [Int] {
        let now = Calendar.current.component(.year, from: Date())
        return Array(Set(Array(now...(now + 15)) + [card.expiryYear])).sorted()
    }

    /// spaced as printed; while not being typed, every digit but the last four hidden
    private var shownNumber: Binding<String> {
        Binding(
            get: {
                let hidden = number.filter(\.isNumber).count - 4
                guard !editingNumber, hidden > 0 else { return number }
                var seen = 0
                return String(number.map { c -> Character in
                    guard c.isNumber else { return c }
                    seen += 1
                    return seen <= hidden ? "•" : c
                })
            },
            set: { if editingNumber { number = CardBrand.grouped($0) } })
    }

    private var problem: String? {
        let digits = number.filter(\.isNumber)
        let finished = !editingNumber || digits.count >= CardBrand(number: digits).lengths.last ?? 19
        if !digits.isEmpty, finished, !CardBrand.isValid(digits) { return "That isn't a valid card number." }
        return card.isExpired ? "This card has expired." : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Card number", text: shownNumber, prompt: Text(isNew ? "" : "•••• \(card.last4)"))
                        .focused($editingNumber)
                    TextField("Name on card", text: $card.holder)
                    Picker("Expiry month", selection: $card.expiryMonth) {
                        ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    Picker("Expiry year", selection: $card.expiryYear) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                }
            }
            .modifier(FittedForm())
            HStack {
                // beside the buttons, so it never changes the form's height
                if let message = refused ? "Your keychain didn't keep this card, so it wasn't saved." : problem {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if AutofillStore.shared.save(card, number: number.isEmpty ? nil : number) { dismiss() } else { refused = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((number.isEmpty ? isNew : !CardBrand.isValid(number)) || card.isExpired)
            }
            .padding()
        }
        .frame(width: 400)
        .presentationSizing(.fitted)
        // opened only through a cards check
        .onAppear { if !isNew { number = CardBrand.grouped(AutofillStore.shared.number(for: card) ?? "") } }
    }
}
