// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the current space's profile, in the sidebar's bottom-right corner. its panel
/// moves the space to another profile or a new one, and holds new space,
/// incognito and Settings
struct ProfileButton: View {
    @Environment(TabManager.self) private var tabManager
    @State private var isHovering = false
    @State private var isShowingPanel = false

    var body: some View {
        let profile = tabManager.currentProfile
        Button {
            isShowingPanel.toggle()
        } label: {
            SpaceGlyph(icon: profile.icon, size: 14, weight: .medium)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.pop, value: profile.id)
                .modifier(ChromeButtonFace(isHovering: isHovering, standalone: true))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(profile.name)
        .holdsSidebar(while: isShowingPanel)
        .popover(isPresented: $isShowingPanel, arrowEdge: .top) {
            ProfilePanel(close: { isShowingPanel = false })
        }
    }
}

private struct ProfilePanel: View {
    @Environment(TabManager.self) private var tabManager
    let close: () -> Void
    @State private var isCreating = false
    @State private var name = ""
    @State private var icon = "person.crop.circle"
    @State private var showingIconPicker = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let space = tabManager.currentSpace
        VStack(alignment: .leading, spacing: 2) {
            Text("\(space.name.uppercased()) BROWSES AS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 3)
            ForEach(tabManager.profiles) { profile in
                ProfileRow(profile: profile, isCurrent: profile.id == space.profileID) {
                    tabManager.setProfile(profile.id, for: space)
                }
            }
            if isCreating {
                creator
            } else {
                PopoverActionRow(title: "New Profile…", icon: "plus.circle") {
                    isCreating = true
                    nameFocused = true
                }
            }
            Divider().padding(.vertical, 3)
            PopoverActionRow(title: "New Space…", icon: "plus") {
                close()
                tabManager.isSpaceCreatorVisible = true
            }
            PopoverActionRow(title: "New Incognito Window", icon: "eyeglasses") {
                close()
                IncognitoWindow.open()
            }
            Divider().padding(.vertical, 3)
            PopoverActionRow(title: "Profile Settings…", icon: "person.2") {
                close()
                ProfilesNavigator.show(for: space.profileID)
            }
            PopoverActionRow(title: "Settings…", icon: "gearshape") {
                close()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        .padding(6)
        .frame(width: 240)
    }

    /// name and icon, then the current space moves into it
    private var creator: some View {
        HStack(spacing: 6) {
            Button {
                showingIconPicker.toggle()
            } label: {
                SpaceGlyph(icon: icon, size: 13)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingIconPicker, arrowEdge: .trailing) {
                IconPicker(icon: $icon)
            }
            TextField("Profile name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($nameFocused)
                .onSubmit(create)
                .onExitCommand { isCreating = false }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = tabManager.createProfile(name: trimmed, icon: icon)
        tabManager.setProfile(profile.id, for: tabManager.currentSpace)
        name = ""
        isCreating = false
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SpaceGlyph(icon: profile.icon, size: 12, weight: .medium)
                    .frame(width: 16)
                Text(profile.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.white.opacity(isHovering || isCurrent ? 0.95 : 0.8))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(isHovering ? 0.13 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(Motion.hover, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
