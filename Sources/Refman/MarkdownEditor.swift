import AppKit
import SwiftUI

/// Plain-text Markdown editor with lightweight syntax highlighting.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = MarkdownHighlighter.baseFont
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.applyHighlighting(to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.applyHighlighting(to: textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        private var isHighlighting = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard !isHighlighting, let storage = textView.textStorage else { return }
            isHighlighting = true
            let selectedRanges = textView.selectedRanges

            storage.beginEditing()
            MarkdownHighlighter.apply(to: storage)
            storage.endEditing()

            textView.selectedRanges = selectedRanges.map {
                NSValue(range: $0.rangeValue.clamped(toLength: storage.length))
            }
            isHighlighting = false
        }
    }
}

private enum MarkdownHighlighter {
    static let baseFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)

    private static let boldFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.systemFontSize, weight: .semibold)

    static func apply(to storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.setAttributes(baseAttributes, range: fullRange)
        apply(pattern: #"^#{1,6}\s.*$"#, to: storage, attributes: [
            .font: boldFont,
            .foregroundColor: NSColor.controlAccentColor,
        ])
        apply(pattern: #"^#{1,6}(?=\s)"#, to: storage, attributes: syntaxAttributes)
        apply(pattern: #"^\s{0,3}(?:[-*+]\s|\d+[.)]\s)"#, to: storage, attributes: syntaxAttributes)
        apply(pattern: #"^\s{0,3}>+\s?"#, to: storage, attributes: syntaxAttributes)
        apply(pattern: #"^\s*```.*$"#, to: storage, attributes: [
            .font: boldFont,
            .foregroundColor: NSColor.systemOrange,
        ])
        apply(pattern: #"`[^`\n]+`"#, to: storage, attributes: [
            .font: baseFont,
            .foregroundColor: NSColor.systemPink,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18),
        ])
        apply(pattern: #"(?:\*\*|__)[^\n]+?(?:\*\*|__)"#, to: storage, attributes: [
            .font: boldFont,
            .foregroundColor: NSColor.labelColor,
        ])
        apply(pattern: #"(?:\*|_)[^\n]+?(?:\*|_)"#, to: storage, attributes: [
            .foregroundColor: NSColor.systemPurple,
        ])
        apply(pattern: #"\[[^\]\n]+\]\([^)]+\)"#, to: storage, attributes: [
            .foregroundColor: NSColor.linkColor,
        ])
        apply(pattern: #"\[\[[^\]\n]+\]\]"#, to: storage, attributes: [
            .foregroundColor: NSColor.systemTeal,
        ])
        apply(pattern: #"#[\p{L}\p{N}_/-]+"#, to: storage, attributes: [
            .foregroundColor: NSColor.systemGreen,
        ])
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    private static var syntaxAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }

    private static func apply(
        pattern: String,
        to storage: NSTextStorage,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return }
        let range = NSRange(location: 0, length: storage.length)
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match, match.range.location != NSNotFound else { return }
            storage.addAttributes(attributes, range: match.range)
        }
    }
}

private extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        let location = min(self.location, length)
        return NSRange(location: location, length: min(self.length, length - location))
    }
}
