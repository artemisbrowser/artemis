import AppKit
import SwiftUI

/// a mini mesh-gradient canvas: tap empty space to drop a colour blob, drag a
/// blob to move it, tap one to select it (then ⌫ to remove or recolour via the
/// swatch), with a Sharpness slider.
///
/// edits flow to the bound `appearance` live, but the SpaceEditor holds gradient
/// changes buffered off the window (the eye previews, the tick commits), so the
/// heavy full-window mesh stays off the per-frame path while dragging
struct MeshEditor: View {
    @Binding var appearance: SpaceAppearance
    /// the canvas height — short and wide for the Scout bar, tall for spaces
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
        // push canvas edits to the appearance live; the SpaceEditor decides when
        // (preview / commit) they actually reach the window
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
            // tap on empty canvas drops a new blob there
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
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
            // move by translation from the grab point — a plain tap (zero drag)
            // never nudges the blob, no matter where in the circle you press
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
                        // a tap: first selects, a second tap on the selected blob
                        // opens its colour picker
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

    /// push the draft onto the appearance — this is what updates the window
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

    @discardableResult
    private func deleteSelected() -> Bool {
        guard let id = selectedID, let i = draft.firstIndex(where: { $0.id == id })
        else { return false }
        draft.remove(at: i)
        selectedID = nil
        return true
    }

    // MARK: Key monitor

    /// `.onKeyPress` won't fire reliably for this canvas living inside a popover
    /// (it never owns keyboard focus), so watch ⌫ / forward-delete directly.
    /// guarded so it stays out of the way while a colour picker (with its hex
    /// field) is open or any text field is being edited
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 51 || event.keyCode == 117,  // delete / forward-delete
                  pickerID == nil, !isEditingText(),
                  deleteSelected()
            else { return event }
            return nil  // consume — we handled it
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func isEditingText() -> Bool {
        guard let r = NSApp.keyWindow?.firstResponder else { return false }
        return r is NSText || r is NSTextView
    }

    // MARK: Selection plumbing

    private func colorBinding(for id: MeshPoint.ID) -> Binding<Color>? {
        guard let i = draft.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft[i].color.color },
            set: { draft[i].color = RGBA($0) })
    }

    private func clamp(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }

    private static let rainbow: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red,
    ]
}
