import AppKit
import SwiftUI

/// Recolors the selected-row highlight of the documents table to a user-chosen
/// accent — and nothing else. SwiftUI's `Table` draws its selection with the
/// system accent and ignores `.tint`. We let the row draw its real (rounded,
/// inset) selection but feed it our accent: while that one draw call runs, the
/// selection-color getters it reads return our accent. Scoped to the table we tag.
///
/// Observed on macOS 26: the active (emphasized) selection reads the class color
/// `alternateSelectedControlColor`; the inactive one reads the row's instance
/// `secondarySelectedControlColor`. We override the wider set below so the recolor
/// survives either path across OS versions.
enum DocumentTableHighlight {
    static let tableIdentifier = NSUserInterfaceItemIdentifier("refmanDocumentTable")
    static var accent: NSColor = .controlAccentColor

    /// Set only while our selected row's `drawSelection(in:)` runs (main thread).
    static var overrideActive = false

    private static var swizzledRowClasses = Set<ObjectIdentifier>()
    private static var colorSwizzled = false

    static func swizzleRowViewClass(_ cls: AnyClass) {
        installClassColorSwizzleOnce()

        let key = ObjectIdentifier(cls)
        guard !swizzledRowClasses.contains(key) else { return }
        swizzledRowClasses.insert(key)

        // Wrap drawSelection(in:) to mark our selected row's draw window.
        let drawSel = #selector(NSTableRowView.drawSelection(in:))
        if let method = class_getInstanceMethod(cls, drawSel) {
            let original = method_getImplementation(method)
            typealias DrawFn = @convention(c) (NSTableRowView, Selector, NSRect) -> Void
            let block: @convention(block) (NSTableRowView, NSRect) -> Void = { rowView, rect in
                let ours =
                    rowView.isSelected
                    && (rowView.superview as? NSTableView)?.identifier == tableIdentifier
                if ours { overrideActive = true }
                unsafeBitCast(original, to: DrawFn.self)(rowView, drawSel, rect)
                overrideActive = false
            }
            class_replaceMethod(
                cls, drawSel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }

        // Inactive-window selection reads this instance color (SwiftUI overrides it).
        let secSel = NSSelectorFromString("secondarySelectedControlColor")
        if let method = class_getInstanceMethod(cls, secSel) {
            let original = method_getImplementation(method)
            typealias ColorFn = @convention(c) (NSTableRowView, Selector) -> NSColor
            let block: @convention(block) (NSTableRowView) -> NSColor = { rowView in
                overrideActive ? accent : unsafeBitCast(original, to: ColorFn.self)(rowView, secSel)
            }
            class_replaceMethod(
                cls, secSel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
    }

    /// Active-window selection reads one of these class colors; return our accent
    /// for all of them while `overrideActive` is set. The getter selectors are
    /// built by name to avoid referencing deprecated symbols at compile time.
    private static func installClassColorSwizzleOnce() {
        guard !colorSwizzled else { return }
        colorSwizzled = true
        let pairs: [(String, Selector)] = [
            ("alternateSelectedControlColor", #selector(NSColor.refman_alternateSelectedControlColor)),
            ("selectedContentBackgroundColor", #selector(NSColor.refman_selectedContentBackgroundColor)),
            ("controlAccentColor", #selector(NSColor.refman_controlAccentColor)),
        ]
        for (name, repl) in pairs {
            guard let a = class_getClassMethod(NSColor.self, NSSelectorFromString(name)),
                let b = class_getClassMethod(NSColor.self, repl)
            else { continue }
            method_exchangeImplementations(a, b)
        }
    }
}

extension NSColor {
    // After exchange, each `refman_*` selector points at the original getter. These
    // must be `dynamic` so the self-call dispatches through objc (hitting the
    // swapped original) instead of recursing into this same Swift method.
    @objc dynamic class func refman_alternateSelectedControlColor() -> NSColor {
        DocumentTableHighlight.overrideActive
            ? DocumentTableHighlight.accent : refman_alternateSelectedControlColor()
    }
    @objc dynamic class func refman_selectedContentBackgroundColor() -> NSColor {
        DocumentTableHighlight.overrideActive
            ? DocumentTableHighlight.accent : refman_selectedContentBackgroundColor()
    }
    @objc dynamic class func refman_controlAccentColor() -> NSColor {
        DocumentTableHighlight.overrideActive
            ? DocumentTableHighlight.accent : refman_controlAccentColor()
    }
}

/// Tags the documents table, swizzles its row-view class, and keeps the accent in
/// sync. Drop into the table's `.background`.
struct DocumentTableHighlighter: NSViewRepresentable {
    var accent: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(from: view, attempt: 0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView, attempt: 0) }
    }

    /// Find the documents table's row view, tag the table, and swizzle the row's
    /// class. SwiftUI backs `Table` with row views of class `SwiftUITableRowView`
    /// (distinct from the sidebar's `ListTableRowView`). The table is built after
    /// this view appears, so retry briefly until a row exists. Also redraws the
    /// current selection so a changed accent applies live.
    private func apply(from view: NSView, attempt: Int) {
        DocumentTableHighlight.accent = NSColor(accent)
        guard
            let row = view.window?.contentView?
                .firstDescendant(ofClassNamed: "SwiftUITableRowView") as? NSTableRowView,
            let table = row.superview as? NSTableView
        else {
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    apply(from: view, attempt: attempt + 1)
                }
            }
            return
        }
        table.identifier = DocumentTableHighlight.tableIdentifier
        DocumentTableHighlight.swizzleRowViewClass(type(of: row))
        table.enumerateAvailableRowViews { rowView, _ in
            if rowView.isSelected { rowView.needsDisplay = true }
        }
    }
}

extension NSView {
    /// Depth-first search for the first view whose class is exactly `name`.
    fileprivate func firstDescendant(ofClassNamed name: String) -> NSView? {
        if String(describing: type(of: self)) == name { return self }
        for sub in subviews {
            if let found = sub.firstDescendant(ofClassNamed: name) { return found }
        }
        return nil
    }
}
