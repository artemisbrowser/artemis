// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// a mesh-gradient canvas: tap to drop a blob, drag one to move it, tap it to
/// select, again to recolour, ⌫ to remove. edits reach `appearance` live; the
/// SpaceEditor decides when they reach the window
struct MeshEditor: View {
    @Binding var appearance: SpaceAppearance
    var canvasHeight: CGFloat = 150

    @State private var draft: [MeshPoint] = []
    @State private var sharpness: Double = 4
    @State private var selectedID: MeshPoint.ID?
    @State private var pickerID: MeshPoint.ID?
    @State private var dragOrigin: CGPoint?
    @State private var didDrag = false
    @State private var keyMonitor: Any?

    private let space = "meshCanvas"

    var body: some View {
        VStack(spacing: 8) {
            canvas
            sharpnessRow
            hint
        }
        .onAppear { loadDraft(); startKeyMonitor() }
        .onDisappear { stopKeyMonitor() }
        // a preset pick (or any external change) replaces the points — resync
        .onChange(of: appearance.meshPoints) { _, _ in loadDraft() }
        .onChange(of: draft) { commit() }
        .onChange(of: sharpness) { commit() }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                MeshGradientView(points: draft, sharpness: sharpness)

                ForEach(draft) { point in
                    ring(for: point, in: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(coordinateSpace: .named(space))
                    .onEnded { addPoint(at: $0.location, in: size) }
            )
            .coordinateSpace(name: space)
        }
        .frame(height: canvasHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// a draggable control ring (rainbow = "this is a colour"); the selected one
    /// grows and gains a white halo
    private func ring(for point: MeshPoint, in size: CGSize) -> some View {
        let isSelected = point.id == selectedID
        return Circle()
            .fill(point.color.color)
            .frame(width: 15, height: 15)
            .overlay(
                Circle().stroke(
                    AngularGradient(colors: Self.rainbow, center: .center), lineWidth: 2.5)
            )
            .overlay(Circle().strokeBorder(.white.opacity(isSelected ? 0.95 : 0), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .scaleEffect(isSelected ? 1.25 : 1)
            .position(x: point.x * size.width, y: point.y * size.height)
            .animation(Motion.pop, value: isSelected)
            // moves by translation from the grab point, so a plain tap never
            // nudges the blob
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = CGPoint(x: point.x * size.width, y: point.y * size.height)
                            didDrag = false
                        }
                        if abs(value.translation.width) > 2 || abs(value.translation.height) > 2 {
                            didDrag = true
                            selectedID = point.id
                        }
                        if didDrag, let base = dragOrigin {
                            move(point, to: CGPoint(x: base.x + value.translation.width,
                                                    y: base.y + value.translation.height), in: size)
                        }
                    }
                    .onEnded { _ in
                        defer { dragOrigin = nil }
                        guard !didDrag else { return }
                        // a tap selects; a tap on the selected blob opens its picker
                        if selectedID == point.id { pickerID = point.id }
                        else { selectedID = point.id }
                    }
            )
            .popover(
                isPresented: Binding(
                    get: { pickerID == point.id },
                    set: { if !$0 { pickerID = nil } }),
                arrowEdge: .trailing
            ) {
                if let binding = colorBinding(for: point.id) {
                    ColorPickerPanel(color: binding)
                }
            }
    }

    // MARK: Controls

    private var sharpnessRow: some View {
        HStack(spacing: 8) {
            Text("Sharpness").font(.system(size: 13))
            Slider(value: $sharpness, in: 1...10)
        }
    }

    private var hint: some View {
        Text("Tap to add · click a blob to recolour · ⌫ to remove")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Draft ↔ appearance

    private func loadDraft() {
        draft = appearance.effectiveMeshPoints
        sharpness = appearance.meshSharpness
    }

    private func commit() {
        appearance.meshPoints = draft
        appearance.meshSharpness = sharpness
    }

    // MARK: Mutations (draft only)

    private func addPoint(at location: CGPoint, in size: CGSize) {
        let point = MeshPoint(
            x: clamp(location.x / size.width),
            y: clamp(location.y / size.height),
            color: RGBA(1, 1, 1))
        draft.append(point)
        selectedID = point.id
    }

    private func move(_ point: MeshPoint, to location: CGPoint, in size: CGSize) {
        guard let i = draft.firstIndex(where: { $0.id == point.id }) else { return }
        draft[i].x = clamp(location.x / size.width)
        draft[i].y = clamp(location.y / size.height)
    }

    private func deleteSelected() -> Bool {
        // an empty draft reads back as the default mesh, so the last blob stays
        guard let id = selectedID, draft.count > 1, let i = draft.firstIndex(where: { $0.id == id })
        else { return false }
        draft.remove(at: i)
        selectedID = nil
        return true
    }

    // MARK: Key monitor

    /// a local monitor, since `.onKeyPress` misses a canvas inside a popover (it
    /// never holds focus). stands aside while a picker is open or text is edited
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 51 || event.keyCode == 117,  // delete / forward-delete
                  pickerID == nil, !isEditingText(),
                  deleteSelected()
            else { return event }
            return nil
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func isEditingText() -> Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    // MARK: Selection plumbing

    private func colorBinding(for id: MeshPoint.ID) -> Binding<Color>? {
        guard let start = draft.first(where: { $0.id == id })?.color.color else { return nil }
        // looked up by id on each access: the points can be replaced under an open picker
        return Binding(
            get: { draft.first { $0.id == id }?.color.color ?? start },
            set: { color in
                if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].color = RGBA(color) }
            })
    }

    private func clamp(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }

    private static let rainbow: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red,
    ]
}
