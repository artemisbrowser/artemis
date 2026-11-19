// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// markdown shown as one selectable text. nothing it shows is fetched, and a link does nothing but call `open`
struct MarkdownText: NSViewRepresentable {
    let source: String
    let open: (URL) -> Void
    @Environment(TooltipState.self) private var tooltips: TooltipState?

    func makeNSView(context: Context) -> MarkdownTextView { .make() }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        // the scheme of what it sits on, which may not be the window's
        let appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        view.open = open
        view.tooltips = tooltips ?? .fallback
        view.show(source)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.height(width: width))
    }
}

extension NSAttributedString.Key {
    /// the NSRange of the markdown source a run was written from
    static let markdownSource = NSAttributedString.Key("artemisMarkdownSource")
}

/// what a markdown source shows
struct MarkdownRender {
    let text: NSAttributedString
    /// each code block's range in `text`
    let code: [NSRange]

    /// `url` if a link may lead there: web addresses only
    static func destination(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host()?.isEmpty == false
        else { return nil }
        return url
    }

    private static func font(_ size: CGFloat, _ traits: NSFontDescriptor.SymbolicTraits, mono: Bool) -> NSFont {
        let base = mono ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : NSFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor
        return NSFont(descriptor: descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(traits)), size: 0) ?? base
    }

    private static func box(_ change: (NSTextBlock) -> Void) -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        change(block)
        return block
    }

    /// clear space around the block nested in it: a block's own margin is painted with its background
    private static func gap(above: CGFloat, below: CGFloat) -> NSTextBlock {
        box {
            $0.setWidth(above, type: .absoluteValueType, for: .padding, edge: .minY)
            $0.setWidth(below, type: .absoluteValueType, for: .padding, edge: .maxY)
        }
    }

    init(_ source: String) {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)

        let bytes = source.utf8
        var lines = [bytes.startIndex]
        for index in bytes.indices {
            let next = bytes.index(after: index)
            if bytes[index] == 10 || (bytes[index] == 13 && (next == bytes.endIndex || bytes[next] != 10)) { lines.append(next) }
        }
        /// the UTF-16 offset of byte `column` of `line`, both counted from 1
        func offset(_ line: Int, _ column: Int) -> Int {
            guard lines.indices.contains(line - 1) else { return source.utf16.count }
            return (bytes.index(lines[line - 1], offsetBy: column - 1, limitedBy: bytes.endIndex) ?? bytes.endIndex).utf16Offset(in: source)
        }

        let out = NSMutableAttributedString()
        var code: [NSRange] = []
        var blocks: [Int: NSTextBlock] = [:], tables: [Int: NSTextTable] = [:]
        var items: Set<Int> = []
        var current: Int?, loose = 0
        var style = NSParagraphStyle(), size: CGFloat = 13, traits: NSFontDescriptor.SymbolicTraits = [], color = NSColor.labelColor
        var isCode = false, wasCell = false

        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            loose -= 1
            let identity = intents.first?.identity ?? loose
            var text = String(parsed[run.range].characters)

            if identity != current {
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: Self.font(size, [], mono: false)])) }
                current = identity
                (size, traits, color, isCode) = (13, [], .labelColor, false)
                let next = NSMutableParagraphStyle()
                next.paragraphSpacing = 8
                var enclosing: [NSTextBlock] = [], depth = 0, isOrdered = false, marker: String?, row = 0
                var table: NSTextTable?, alignments: [PresentationIntent.TableColumn.Alignment] = []
                // outermost first
                for intent in intents.reversed() {
                    let id = intent.identity
                    switch intent.kind {
                    case .blockQuote:
                        color = .secondaryLabelColor
                        enclosing.append(blocks[id] ?? Self.box {
                            $0.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
                            $0.setBorderColor(.tertiaryLabelColor)
                            $0.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                        })
                        blocks[id] = enclosing.last
                    case .orderedList, .unorderedList:
                        depth += 1
                        isOrdered = intent.kind == .orderedList
                    case .listItem(let ordinal):
                        marker = items.insert(id).inserted ? (isOrdered ? "\(ordinal)." : "•") : nil
                    case .codeBlock:
                        isCode = true
                        next.paragraphSpacing = 0
                        enclosing.append(Self.gap(above: 4, below: 8))
                        enclosing.append(Self.box {
                            $0.backgroundColor = .labelColor.withAlphaComponent(0.07)
                            $0.setWidth(8, type: .absoluteValueType, for: .padding)
                            $0.setWidth(28, type: .absoluteValueType, for: .padding, edge: .maxX)
                        })
                    case .table(let columns):
                        alignments = columns.map(\.alignment)
                        table = tables[id] ?? NSTextTable()
                        table?.numberOfColumns = columns.count
                        table?.collapsesBorders = true
                        tables[id] = table
                    case .tableHeaderRow:
                        traits = .bold
                    case .tableRow(let index):
                        row = index
                    case .tableCell(let column):
                        guard let table else { break }
                        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(.tertiaryLabelColor)
                        cell.setWidth(5, type: .absoluteValueType, for: .padding)
                        // AppKit raises when a table with collapsed borders is drawn inside a plain block
                        enclosing = [cell]
                        next.paragraphSpacing = 0
                        next.alignment = switch alignments.indices.contains(column) ? alignments[column] : .left {
                        case .center: .center
                        case .right: .right
                        default: .left
                        }
                    case .header(let level):
                        size = level == 1 ? 16 : level == 2 ? 15 : 13
                        traits = .bold
                        next.paragraphSpacingBefore = 4
                    case .thematicBreak:
                        text = "\u{00A0}"
                        size = 2
                        enclosing.append(Self.box {
                            $0.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                            $0.setBorderColor(.tertiaryLabelColor)
                            $0.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
                        })
                    default:
                        break
                    }
                }
                let indent = CGFloat(depth) * 20
                if wasCell, enclosing.isEmpty { next.paragraphSpacingBefore += 6 }
                wasCell = enclosing.last is NSTextTableBlock
                next.textBlocks = enclosing
                next.headIndent = indent
                next.firstLineHeadIndent = marker == nil ? indent : indent - 20
                next.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                if depth > 0 { next.paragraphSpacing = 3 }
                style = next
                if let marker {
                    out.append(NSAttributedString(string: marker + "\t", attributes: [
                        .paragraphStyle: style, .font: Self.font(size, [], mono: false), .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
            }

            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.lineBreak) { text = "\u{2028}" }
            if isCode || intents.isEmpty { while text.last?.isNewline == true { text.removeLast() } }
            var marks = traits
            if inline.contains(.stronglyEmphasized) { marks.insert(.bold) }
            if inline.contains(.emphasized) { marks.insert(.italic) }
            var attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: style, .foregroundColor: color, .font: Self.font(size, marks, mono: isCode || inline.contains(.code)),
            ]
            if inline.contains(.code) { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = Self.destination(run.link ?? run.imageURL) { attributes[.link] = url }
            if let at = run.markdownSourcePosition {
                let start = offset(at.startLine, at.startColumn)
                attributes[.markdownSource] = NSValue(range: NSRange(location: start, length: max(offset(at.endLine, at.endColumn + 1) - start, 0)))
            }
            if isCode, !text.isEmpty { code.append(NSRange(location: out.length, length: (text as NSString).length)) }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        self.text = out
        self.code = code
    }
}

final class MarkdownTextView: NSTextView, NSTextViewDelegate {
    var open: (URL) -> Void = { _ in }
    weak var tooltips: TooltipState?
    private(set) var source = ""
    private var code: [NSRange] = []
    private var buttons: [NSView] = []
    private var tracking: NSTrackingArea?
    private let tip = UUID()
    private var dwell: Task<Void, Never>?
    private var hovered: URL?

    static func make() -> MarkdownTextView {
        // TextKit 1: text tables and text blocks have no TextKit 2 layout
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.delegate = view
        return view
    }

    func show(_ source: String, again: Bool = false) {
        guard again || source != self.source else { return }
        self.source = source
        let render = MarkdownRender(source)
        textStorage?.setAttributedString(render.text)
        code = render.code
        buttons.forEach { $0.removeFromSuperview() }
        buttons = code.map { NSHostingView(rootView: MarkdownCopyButton(code: (render.text.string as NSString).substring(with: $0))) }
        buttons.forEach(addSubview)
        place()
    }

    // a text block keeps the colours of the appearance it was first drawn in
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        show(source, again: true)
    }

    func height(width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        place()
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    /// each copy button in the top right corner of its code block
    private func place() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        for (button, range) in zip(buttons, code) {
            let first = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let top = layoutManager.boundingRect(forGlyphRange: first, in: textContainer).minY
            button.frame = NSRect(x: textContainer.size.width - 25, y: top - 5, width: 22, height: 22)
        }
    }

    /// the markdown the selection was written from: all of it for the whole text, else the span its runs cover
    var selectedSource: String {
        let selection = selectedRange()
        guard let textStorage, selection.length > 0 else { return "" }
        if selection.length == textStorage.length { return source }
        let whole = NSRange(location: 0, length: textStorage.length), written = source as NSString
        var span: NSRange?
        textStorage.enumerateAttribute(.markdownSource, in: selection) { value, range, _ in
            guard var piece = (value as? NSValue)?.rangeValue else { return }
            var run = NSRange()
            _ = textStorage.attribute(.markdownSource, at: range.location, longestEffectiveRange: &run, in: whole)
            // a run shown exactly as written maps character for character
            if run.length == piece.length { piece = NSRange(location: piece.location + range.location - run.location, length: range.length) }
            span = span.map { NSUnionRange($0, piece) } ?? piece
        }
        guard var span, NSMaxRange(span) <= written.length else { return "" }
        let line = written.lineRange(for: NSRange(location: span.location, length: 0))
        let lead = written.substring(with: NSRange(location: line.location, length: span.location - line.location))
        if lead.wholeMatch(of: /[\s>*+\-#|\d.)`~]*/) != nil { span = NSUnionRange(span, NSRange(location: line.location, length: 0)) }
        return written.substring(with: span)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        pboard.clearContents()
        return pboard.setString(selectedSource, forType: .string)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = MarkdownRender.destination(link as? URL) { open(url) }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        point(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        point(at: nil)
    }

    private func link(at spot: NSPoint) -> URL? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: spot, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(spot) else { return nil }
        return textStorage.attribute(.link, at: layoutManager.characterIndexForGlyph(at: glyph), effectiveRange: nil) as? URL
    }

    /// the pointer is at `spot` in this view, or has left it: a link under it names where it leads
    func point(at spot: NSPoint?) {
        let url = spot.flatMap(link)
        let inWindow = spot.map { convert($0, to: nil) } ?? .zero
        let cursor = CGPoint(x: inWindow.x, y: (window?.contentView?.bounds.height ?? 0) - inWindow.y)
        guard url != hovered else {
            if tooltips?.active?.id == tip { tooltips?.active?.cursor = cursor }
            return
        }
        hovered = url
        dwell?.cancel()
        tooltips?.hide(id: tip)
        guard let url, let window else { return }
        let bubble = TooltipState.Active(
            id: tip, text: String(url.absoluteString.prefix(160)), keys: [], anchor: .zero, cursor: cursor, style: .cursor,
            windowNumber: window.windowNumber)
        dwell = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.hovered == url else { return }
            self.tooltips?.show(bubble)
        }
    }
}

private struct MarkdownCopyButton: View {
    let code: String
    @State private var isCopied = false

    var body: some View {
        Button("Copy Code", systemImage: isCopied ? "checkmark" : "square.on.square") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            isCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                isCopied = false
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .contentShape(.rect)
        .tooltip(isCopied ? "Copied" : "Copy code")
    }
}
