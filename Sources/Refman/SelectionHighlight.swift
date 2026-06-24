import AppKit
import SwiftUI

/// Recolors the selected-row highlight of the documents table to a user-chosen
/// accent — and nothing else. SwiftUI's `Table` draws its selection with the
/// system accent and ignores `.tint`. We let the row draw its real (rounded,
/// inset) selection but feed it our accent: only while our tagged table's
/// selected row runs `drawSelection(in:)`, the selection colors it reads return
/// the accent.
///
/// The active (emphasized) selection reads the class color
/// `alternateSelectedControlColor`; the inactive one reads the row's instance
/// `secondarySelectedControlColor`. The class colors are dynamic system colors
/// that re-enter themselves through their own selector while recaching, so a
/// *permanent* swizzle of them recurses infinitely (crash). We therefore swap
/// their implementation in only for the duration of our draw call and restore it
/// immediately after — during that window we return a flat color, so there is no
/// recache and no recursion.
enum DocumentTableHighlight {
    static let tableIdentifier = NSUserInterfaceItemIdentifier("refmanDocumentTable")
    static var accent: NSColor = .controlAccentColor

    /// True only while our selected row's `drawSelection(in:)` runs (main thread).
    static var overrideActive = false

    private static var swizzledRowClasses = Set<ObjectIdentifier>()

    /// Class color getters the emphasized selection may read, with their real and
    /// accent-returning implementations, so we can swap back and forth cheaply.
    private struct ColorHook {
        let method: Method
        let original: IMP
        let accent: IMP
    }
    private static let colorHooks: [ColorHook] = {
        let accentBlock: @convention(block) (AnyObject) -> NSColor = { _ in accent }
        let accentIMP = imp_implementationWithBlock(accentBlock)
        return [
            "alternateSelectedControlColor", "selectedContentBackgroundColor", "controlAccentColor",
        ].compactMap { name in
            guard let m = class_getClassMethod(NSColor.self, NSSelectorFromString(name)) else {
                return nil
            }
            return ColorHook(method: m, original: method_getImplementation(m), accent: accentIMP)
        }
    }()

    private static func beginAccentColors() {
        for hook in colorHooks { method_setImplementation(hook.method, hook.accent) }
    }
    private static func endAccentColors() {
        for hook in colorHooks { method_setImplementation(hook.method, hook.original) }
    }

    static func swizzleRowViewClass(_ cls: AnyClass) {
        _ = colorHooks  // build the hook table before first use

        let key = ObjectIdentifier(cls)
        guard !swizzledRowClasses.contains(key) else { return }
        swizzledRowClasses.insert(key)

        // drawSelection(in:): swap accent colors in just for our selected row.
        let drawSel = #selector(NSTableRowView.drawSelection(in:))
        if let method = class_getInstanceMethod(cls, drawSel) {
            let original = method_getImplementation(method)
            typealias DrawFn = @convention(c) (NSTableRowView, Selector, NSRect) -> Void
            let block: @convention(block) (NSTableRowView, NSRect) -> Void = { rowView, rect in
                let ours =
                    rowView.isSelected
                    && (rowView.superview as? NSTableView)?.identifier == tableIdentifier
                if ours {
                    overrideActive = true
                    beginAccentColors()
                }
                defer {
                    if ours {
                        endAccentColors()
                        overrideActive = false
                    }
                }
                unsafeBitCast(original, to: DrawFn.self)(rowView, drawSel, rect)
            }
            class_replaceMethod(
                cls, drawSel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }

        // Inactive-window selection reads this instance color (SwiftUI overrides
        // it). It's a plain row method — safe to leave swizzled permanently.
        let secSel = NSSelectorFromString("secondarySelectedControlColor")
        if let method = class_getInstanceMethod(cls, secSel) {
            let original = method_getImplementation(method)
            typealias ColorFn = @convention(c) (NSTableRowView, Selector) -> NSColor
            let block: @convention(block) (NSTableRowView) -> NSColor = { rowView in
                overrideActive
                    ? accent : unsafeBitCast(original, to: ColorFn.self)(rowView, secSel)
            }
            class_replaceMethod(
                cls, secSel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
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
