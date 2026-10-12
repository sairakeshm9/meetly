import AppKit
import Combine
import MeetingCore
import SwiftUI

enum NativeAnswerFormatting {
    static func prose(_ source: String, size: Double) -> NSAttributedString {
        let styled = AnswerTypography.emphasized(source)
        let result = NSMutableAttributedString(string: String(styled.characters))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        result.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph,
                .foregroundColor: NSColor.textColor,
            ], range: NSRange(location: 0, length: result.length))
        for run in styled.runs {
            let range = NSRange(
                location: String(styled.characters[..<run.range.lowerBound]).utf16.count,
                length: String(styled[run.range].characters).utf16.count)
            let intent = run.inlinePresentationIntent ?? []
            var font =
                intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size)
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            result.addAttribute(.font, value: font, range: range)
            if let color = run.foregroundColor {
                result.addAttribute(.foregroundColor, value: NSColor(color), range: range)
            }
        }
        return result
    }
}

final class ProseGlyphLayout {
    let manager = NSLayoutManager()
    let storage: NSTextStorage
    let container: NSTextContainer
    init(_ source: String, size: Double, width: Double) {
        storage = NSTextStorage(attributedString: NativeAnswerFormatting.prose(source, size: size))
        container = NSTextContainer(
            containerSize: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
    }
    func rectangles(_ range: NSRange) -> [CGRect] {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var result: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
            let intersection = NSIntersectionRange(glyphs, line)
            if intersection.length > 0 {
                result.append(self.manager.boundingRect(forGlyphRange: intersection, in: self.container))
            }
        }
        return result
    }
    func minY(_ range: NSRange) -> Double { Double(rectangles(range).first?.minY ?? 0) }
}

final class AnswerRenderCache: ObservableObject {
    struct Row {
        let styled: AttributedString
        let layout: ProseGlyphLayout?
    }
    struct Plan {
        let blocks: [AnswerBlock]
        let rows: [Row]
        let size: Double
    }
    private struct Key: Equatable {
        let text: String
        let size: Double
        let width: Double
        let height: Double
        let fit: Bool
    }
    private var key: Key?
    private var plan: Plan?
    private(set) var preparations = 0
    func resolve(_ text: String, requested: Double, width: Double, height: Double, fit: Bool) -> Plan {
        let next = Key(text: text, size: requested, width: width, height: height, fit: fit)
        if next == key, let plan { return plan }
        let size = AnswerTypography.fit(
            text, requested: requested, width: width, height: height, enabled: fit)
        let blocks = AnswerBlock.parse(text.isEmpty ? "Preparing a brief answer…" : text)
        let rows = blocks.map { block in
            Row(
                styled: AnswerTypography.emphasized(block.text),
                layout: block.isCode || MarkdownAnswerTable.parse(block.text) != nil
                    ? nil : ProseGlyphLayout(block.text, size: size, width: width))
        }
        let prepared = Plan(blocks: blocks, rows: rows, size: size)
        preparations += 1
        key = next
        plan = prepared
        return prepared
    }
}

struct SpeechHighlightLayer: NSViewRepresentable {
    let layout: ProseGlyphLayout?
    let passages: [SpeechPassage]
    let progress: SpeechProgress?
    let opacity: Double
    func makeNSView(context: Context) -> HighlightCanvas { HighlightCanvas() }
    func updateNSView(_ view: HighlightCanvas, context: Context) {
        view.layout = layout
        view.passages = passages
        view.progress = progress
        view.opacity = opacity
        view.needsDisplay = true
    }
    final class HighlightCanvas: NSView {
        var layout: ProseGlyphLayout?
        var passages: [SpeechPassage] = []
        var progress: SpeechProgress?
        var opacity = 1.0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let layout, let progress else { return }
            let next = progress.current.flatMap { current in
                passages.first { $0.id > current && $0.trackable }?.id
            }
            for passage in passages {
                let color: NSColor
                if passage.id == progress.current {
                    color = NSColor(MeetlyPalette.accent).withAlphaComponent(0.2 * opacity)
                } else if progress.covered.contains(passage.id) {
                    color = NSColor(MeetlyPalette.accent).withAlphaComponent(0.06 * opacity)
                } else if passage.id == next {
                    color = NSColor.secondaryLabelColor.withAlphaComponent(0.075 * opacity)
                } else {
                    continue
                }
                color.setFill()
                for rect in layout.rectangles(passage.plainRange) {
                    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                }
            }
        }
    }
}
