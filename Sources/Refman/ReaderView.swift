import CoreImage
import PDFKit
import RefmanCore
import SwiftUI

/// PDF reading window: viewer, annotation toolbar, annotation sidebar, assistant.
struct ReaderView: View {
    @EnvironmentObject var model: AppModel
    let documentId: Int64

    @StateObject private var reader = ReaderModel()
    @State private var showAnnotations = false
    @State private var showAssistant = false
    @State private var pendingQuote: String?
    @State private var pendingAction: AssistantAction?
    @AppStorage(SettingsKeys.highlightPalette)
    private var highlightPalette = AnnotationOptions.defaultPalette
    @AppStorage(SettingsKeys.highlightOpacity)
    private var highlightOpacity = 1.0
    @State private var showTooltipConfig = false

    var body: some View {
        HSplitView {
            if showAnnotations {
                ReaderSidebar(reader: reader)
                    .frame(width: 320)
            }
            ZStack(alignment: .topLeading) {
                PDFKitView(reader: reader)
                if let rect = reader.selectionRect, !reader.highlighterMode {
                    SelectionPen(reader: reader)
                        .position(x: max(rect.midX, 120), y: max(rect.minY - 26, 20))
                        .transition(.opacity)
                }
                if let clicked = reader.clickedAnnotation,
                    let rect = reader.clickedAnnotationRect
                {
                    AnnotationBubble(reader: reader, annotation: clicked)
                        .position(x: max(rect.midX, 60), y: max(rect.minY - 22, 16))
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 500)
            if showAssistant {
                AssistantPanel(
                    documentId: documentId,
                    pendingQuote: $pendingQuote,
                    pendingAction: $pendingAction
                )
                .frame(width: 340)
            }
        }
        .onChange(of: reader.askAIRequest) {
            guard let text = reader.askAIRequest else { return }
            reader.askAIRequest = nil
            pendingQuote = text
            showAssistant = true
        }
        .onChange(of: reader.aiActionRequest?.id) {
            guard let action = reader.aiActionRequest else { return }
            reader.aiActionRequest = nil
            pendingAction = action
            showAssistant = true
        }
        .navigationTitle(reader.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: $showAnnotations) {
                    Label("Annotations", systemImage: "sidebar.left")
                }
            }
            ToolbarItem(placement: .principal) {
                ReaderSearchBar(reader: reader)
            }
            ToolbarItemGroup {
                PageIndicator(reader: reader)

                HStack(spacing: 2) {
                    Button { reader.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out")
                    Button { reader.fitWidth() } label: {
                        Image(systemName: "arrow.left.and.right")
                    }
                    .help("Fit width")
                    Button { reader.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in")
                }

                Menu {
                    Picker("Reading Mode", selection: $reader.readingMode) {
                        ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Two-Up Layout", isOn: $reader.twoUp)
                } label: {
                    Label("View", systemImage: "book")
                }
                .help("Reading mode and page layout")

                HStack(spacing: 7) {
                    Button {
                        reader.highlighterMode.toggle()
                    } label: {
                        Image(systemName: "highlighter")
                            .foregroundStyle(
                                reader.highlighterMode
                                    ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                            .padding(5)
                            .background(
                                reader.highlighterMode
                                    ? Color.accentColor.opacity(0.16) : .clear,
                                in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Highlighter mode: selecting text highlights it immediately")

                    Menu {
                        Picker("Color", selection: $reader.highlighterColorHex) {
                            ForEach(paletteHexes, id: \.self) { hex in
                                Text(reader.label(forHex: hex)).tag(hex)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(nsImage: highlighterSwatch)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Highlighter color")
                }
                .padding(.horizontal, 2)

                Button {
                    showTooltipConfig.toggle()
                } label: {
                    Label("Tooltip Colors", systemImage: "paintpalette")
                }
                .help("Choose the colors and opacity for highlight and underline markups")
                .popover(isPresented: $showTooltipConfig, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(AnnotationOptions.colors, id: \.hex) { entry in
                            Toggle(entry.name, isOn: paletteToggle(entry.hex))
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Opacity")
                                Spacer()
                                Text(
                                    highlightOpacity,
                                    format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $highlightOpacity, in: 0.15...1)
                        }
                    }
                    .padding(14)
                    .frame(width: 220)
                }

                Spacer()

                Toggle(isOn: $showAssistant) {
                    Label("Assistant", systemImage: "sparkles")
                }
            }
        }
        .background {
            // Scoped to this reader window, so it doesn't override text-field
            // undo elsewhere; disabled when there's nothing to act on, letting
            // the shortcut fall through.
            Button(action: reader.undo) {}
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!reader.canUndo)
                .opacity(0)
                .allowsHitTesting(false)
            Button(action: reader.redo) {}
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!reader.canRedo)
                .opacity(0)
                .allowsHitTesting(false)
            Button { reader.cycleAnnotation(forward: true) } label: {}
                .keyboardShortcut("]", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
            Button { reader.cycleAnnotation(forward: false) } label: {}
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onAppear {
            reader.load(documentId: documentId, model: model)
        }
        .onDisappear {
            reader.flushSave()
        }
    }

    private var paletteHexes: [String] {
        highlightPalette.split(separator: ",").map(String.init)
    }

    /// A color dot drawn as a bitmap: toolbars render symbol images as
    /// templates and collapse bare shapes, but leave non-template images alone.
    private var highlighterSwatch: NSImage {
        let color = NSColor(hex: reader.highlighterColorHex) ?? .systemYellow
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Whether a color is part of the highlight tooltip palette; never lets
    /// the last color be removed.
    private func paletteToggle(_ hex: String) -> Binding<Bool> {
        Binding(
            get: { highlightPalette.contains(hex) },
            set: { include in
                var hexes = Set(highlightPalette.split(separator: ",").map(String.init))
                if include { hexes.insert(hex) } else { hexes.remove(hex) }
                let ordered = AnnotationOptions.colors.map(\.hex).filter(hexes.contains)
                if !ordered.isEmpty {
                    highlightPalette = ordered.joined(separator: ",")
                }
            })
    }
}

/// Colors offered for annotation tools, persisted as hex strings.
enum AnnotationOptions {
    static let colors: [(name: String, hex: String)] = [
        ("Yellow", "#FFCC00"),
        ("Green", "#34C759"),
        ("Pink", "#FF2D55"),
        ("Blue", "#007AFF"),
        ("Orange", "#FF9500"),
        ("Purple", "#AF52DE"),
    ]
    static let defaultPalette = "#FFCC00,#34C759,#FF2D55,#007AFF,#FF9500,#AF52DE"
}

/// Page reading tint for comfort.
enum ReadingMode: String, CaseIterable, Identifiable {
    case off, sepia, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }
}

/// A flattened table-of-contents entry.
struct OutlineItem: Identifiable {
    let id = UUID()
    let label: String
    let depth: Int
    let pageIndex: Int?
    let destination: PDFDestination?
}

/// Owns the PDFDocument, mirrors annotations to the repository, persists the PDF.
@MainActor
final class ReaderModel: ObservableObject {
    @Published var annotations: [RefmanCore.Annotation] = []
    @Published var hasSelection = false
    @Published var title = "Reader"
    /// Selection bounds in the PDFView's SwiftUI (top-left) coordinates,
    /// for positioning the floating annotation pen.
    @Published var selectionRect: CGRect?
    /// Set when the user hits “Ask AI” on a selection.
    @Published var askAIRequest: String?
    /// Set when a sidebar note triggers a built-in AI action (summarize/explain).
    @Published var aiActionRequest: AssistantAction?
    /// Annotation the user clicked in the PDF, with its view-space rect,
    /// for the floating remove button.
    @Published var clickedAnnotation: RefmanCore.Annotation?
    @Published var clickedAnnotationRect: CGRect?
    /// Index of the page currently in view, for the sidebar's follow-page mode.
    @Published var currentPageIndex = 0
    /// Per-document display names for annotation colors, keyed by hex.
    @Published var colorLabels: [String: String] = [:]
    /// When on, finishing a text selection immediately applies a highlight.
    @Published var highlighterMode = false
    @Published var highlighterColorHex = AnnotationOptions.colors[0].hex
    /// Whether there's a markup action that Cmd+Z / Cmd+Shift+Z can act on.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Document's table of contents, flattened; empty when the PDF has none.
    @Published private(set) var outline: [OutlineItem] = []
    /// In-document search state.
    @Published var searchText = ""
    @Published private(set) var searchMatches: [PDFSelection] = []
    @Published private(set) var searchActiveIndex = 0
    /// Reading comfort tint applied to the page; re-applied on change.
    @Published var readingMode: ReadingMode = .off { didSet { applyReadingMode() } }
    /// Single-page vs two-up continuous layout.
    @Published var twoUp = false {
        didSet { pdfView?.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous }
    }

    /// Number of pages in the open document.
    var pageCount: Int { pdfDocument?.pageCount ?? 0 }

    /// What `copySelection` puts on the pasteboard.
    enum CopyMode { case plain, inline, full }

    /// Source metadata for citation-aware copy.
    private var documentDetails: DocumentDetails?
    /// Position remembered by `cycleAnnotation`.
    private var cyclePosition: Int?

    /// A reversible markup edit, recording what the user did.
    private enum MarkupAction {
        case added([RefmanCore.Annotation])  // undo removes them; redo re-adds
        case removed(RefmanCore.Annotation)  // undo restores it; redo removes again
    }
    private var undoStack: [MarkupAction] = []
    private var redoStack: [MarkupAction] = []

    private(set) var pdfDocument: PDFDocument?
    private var fileURL: URL?
    private var documentId: Int64?
    private var model: AppModel?
    weak var pdfView: PDFView?

    /// Serializes the (expensive) full-PDF writes off the main thread.
    private static let saveQueue = DispatchQueue(label: "com.refman.pdfsave", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    /// PDFKit drops the standard `.name` (/NM) key when writing the file,
    /// so annotations are tagged with a custom key that does survive a round trip.
    private static let uuidKey = PDFAnnotationKey(rawValue: "/RefmanUUID")
    /// Older builds tagged annotations with this key; still read for compatibility.
    private static let legacyUUIDKey = PDFAnnotationKey(rawValue: "/RefManUUID")

    func load(documentId: Int64, model: AppModel) {
        self.documentId = documentId
        self.model = model
        guard let details = try? model.repository.document(id: documentId),
            let url = model.pdfURL(for: details),
            let doc = PDFDocument(url: url)
        else { return }
        pdfDocument = doc
        fileURL = url
        title = details.document.title
        documentDetails = details
        outline = Self.buildOutline(doc)
        annotations = (try? model.repository.annotations(documentId: documentId)) ?? []
        colorLabels = (try? model.repository.colorLabels(documentId: documentId)) ?? [:]
    }

    // MARK: - Color labels

    /// The user's label for a color, falling back to the stock color name.
    func label(forHex hex: String) -> String {
        colorLabels[hex] ?? AnnotationOptions.colors.first { $0.hex == hex }?.name ?? hex
    }

    func setColorLabel(_ label: String, forHex hex: String) {
        guard let model, let documentId else { return }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        try? model.repository.setColorLabel(documentId: documentId, colorHex: hex, label: trimmed)
        colorLabels[hex] = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Highlighter mode

    private var autoHighlightTask: Task<Void, Never>?

    /// In highlighter mode the finished selection immediately becomes
    /// a highlight.
    private func selectionFinished() {
        guard highlighterMode,
            !(pdfView?.currentSelection?.string?.isEmpty ?? true),
            let color = NSColor(hex: highlighterColorHex)
        else { return }
        addHighlight(color: color)
    }

    func selectionChanged() {
        hasSelection = !(pdfView?.currentSelection?.string?.isEmpty ?? true)
        selectionRect = currentSelectionViewRect()
        if hasSelection { clearClickedAnnotation() }
        autoHighlightTask?.cancel()
        if highlighterMode, hasSelection {
            autoHighlightTask = Task { [weak self] in
                // Wait for the mouse to be released so a drag in progress
                // is not highlighted piecemeal.
                while NSEvent.pressedMouseButtons & 1 != 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if Task.isCancelled { return }
                }
                if Task.isCancelled { return }
                self?.selectionFinished()
            }
        }
    }

    /// Re-anchor (or hide) the pen when the document scrolls under a selection.
    func viewGeometryChanged() {
        if selectionRect != nil {
            selectionRect = currentSelectionViewRect()
        }
        clearClickedAnnotation()
        updateCurrentPage()
    }

    /// Track which page is in view so the sidebar can follow along.
    func pageChanged() {
        updateCurrentPage()
    }

    private func updateCurrentPage() {
        guard let view = pdfView, let doc = pdfDocument else { return }
        // PDFKit updates `currentPage` lazily while scrolling, so locate the
        // page under the viewport center instead.
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let page = view.page(for: center, nearest: true) else { return }
        let idx = doc.index(for: page)
        if idx != currentPageIndex { currentPageIndex = idx }
    }

    // MARK: - Search

    /// Re-runs the document search for the current `searchText`. Matches are
    /// highlighted in the page; the active one is scrolled into view.
    func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard let doc = pdfDocument, q.count >= 2 else {
            searchMatches = []
            searchActiveIndex = 0
            pdfView?.highlightedSelections = nil
            return
        }
        let matches = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for m in matches { m.color = .systemYellow }
        searchMatches = matches
        searchActiveIndex = 0
        pdfView?.highlightedSelections = matches.isEmpty ? nil : matches
        if !matches.isEmpty { focusMatch() }
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        searchActiveIndex = (searchActiveIndex + 1) % searchMatches.count
        focusMatch()
    }

    func prevMatch() {
        guard !searchMatches.isEmpty else { return }
        searchActiveIndex = (searchActiveIndex - 1 + searchMatches.count) % searchMatches.count
        focusMatch()
    }

    /// Tints the active match brighter than the rest and scrolls to it without
    /// disturbing the user's text selection.
    private func focusMatch() {
        for (i, m) in searchMatches.enumerated() {
            m.color = i == searchActiveIndex ? .systemOrange : .systemYellow
        }
        pdfView?.highlightedSelections = searchMatches
        let sel = searchMatches[searchActiveIndex]
        if let page = sel.pages.first {
            pdfView?.go(to: sel.bounds(for: page), on: page)
        }
    }

    // MARK: - Navigation, zoom, layout

    func goToPage(_ index: Int) {
        guard let doc = pdfDocument, index >= 0, index < doc.pageCount,
            let page = doc.page(at: index)
        else { return }
        pdfView?.go(
            to: PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)))
    }

    func zoomIn() {
        guard let v = pdfView else { return }
        v.autoScales = false
        v.scaleFactor = min(v.scaleFactor * 1.15, v.maxScaleFactor)
    }

    func zoomOut() {
        guard let v = pdfView else { return }
        v.autoScales = false
        v.scaleFactor = max(v.scaleFactor / 1.15, v.minScaleFactor)
    }

    /// Returns to width-fitting auto scaling.
    func fitWidth() { pdfView?.autoScales = true }

    /// Applies the current reading tint to the page via Core Image content
    /// filters; `.off` clears them.
    func applyReadingMode() {
        guard let v = pdfView else { return }
        v.wantsLayer = true
        switch readingMode {
        case .off:
            v.contentFilters = []
            v.backgroundColor = .windowBackgroundColor
        case .sepia:
            let f = CIFilter(name: "CISepiaTone")
            f?.setValue(0.55, forKey: kCIInputIntensityKey)
            v.contentFilters = f.map { [$0] } ?? []
            v.backgroundColor = NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 1)
        case .dark:
            v.contentFilters = CIFilter(name: "CIColorInvert").map { [$0] } ?? []
            v.backgroundColor = .black
        }
    }

    // MARK: - Outline (table of contents)

    func go(to item: OutlineItem) {
        if let dest = item.destination {
            pdfView?.go(to: dest)
        } else if let index = item.pageIndex {
            goToPage(index)
        }
    }

    /// Flattens the PDF's outline tree into a depth-tagged list.
    private static func buildOutline(_ doc: PDFDocument) -> [OutlineItem] {
        guard let root = doc.outlineRoot else { return [] }
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let label = child.label ?? ""
                let dest = child.destination
                let pageIndex = dest?.page.map { doc.index(for: $0) }
                if !label.isEmpty {
                    items.append(
                        OutlineItem(
                            label: label, depth: depth, pageIndex: pageIndex, destination: dest))
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return items
    }

    // MARK: - Copy

    /// Copies the current selection, optionally with a formatted citation
    /// (in-text for `.inline`, full reference for `.full`).
    func copySelection(_ mode: CopyMode) {
        guard let text = pdfView?.currentSelection?.string, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        guard mode != .plain, let details = documentDetails else {
            pb.setString(text, forType: .string)
            return
        }
        let style = Citeproc.Style(
            rawValue: UserDefaults.standard.string(forKey: SettingsKeys.citationStyle) ?? "")
            ?? .apa
        let citeMode: Citeproc.Mode = mode == .inline ? .citation : .bibliography
        let citation = (try? Citeproc.format([details], style: style, mode: citeMode)) ?? ""
        pb.setString(citation.isEmpty ? text : "“\(text)”\n\n\(citation)", forType: .string)
    }

    // MARK: - Cycle annotations

    func cycleAnnotation(forward: Bool) {
        guard !annotations.isEmpty else { return }
        let base = cyclePosition ?? (forward ? -1 : 0)
        let next = ((base + (forward ? 1 : -1)) % annotations.count + annotations.count)
            % annotations.count
        cyclePosition = next
        jump(to: annotations[next])
    }

    // MARK: - Clicking annotations in the PDF

    func markupClicked(_ pdfAnn: PDFAnnotation, on page: PDFPage) {
        guard let view = pdfView, let doc = pdfDocument else { return }
        // A drag-selection over highlighted text is not a click.
        if !(view.currentSelection?.string?.isEmpty ?? true) { return }
        let pageIndex = doc.index(for: page)
        guard
            let record = annotations.first(where: {
                $0.pageIndex == pageIndex && pdfAnnotation(for: $0, on: page) === pdfAnn
            })
        else { return }
        var rect = view.convert(pdfAnn.bounds, from: page)
        if !view.isFlipped {
            rect.origin.y = view.bounds.height - rect.maxY
        }
        clickedAnnotation = record
        clickedAnnotationRect = rect
    }

    func clearClickedAnnotation() {
        guard clickedAnnotation != nil else { return }
        clickedAnnotation = nil
        clickedAnnotationRect = nil
    }

    private func currentSelectionViewRect() -> CGRect? {
        guard let view = pdfView, let selection = view.currentSelection,
            !(selection.string?.isEmpty ?? true),
            let page = selection.pages.first
        else { return nil }
        let pageRect = selection.bounds(for: page)
        guard !pageRect.isEmpty else { return nil }
        var rect = view.convert(pageRect, from: page)
        if !view.isFlipped {
            rect.origin.y = view.bounds.height - rect.maxY
        }
        // Ignore selections scrolled out of sight.
        let visible = CGRect(origin: .zero, size: view.bounds.size)
        guard visible.intersects(rect) else { return nil }
        return rect
    }

    func askAI() {
        guard let text = pdfView?.currentSelection?.string, !text.isEmpty else { return }
        askAIRequest = text
        pdfView?.clearSelection()
    }

    // MARK: - Annotation creation

    /// User-chosen render opacity for markups; render-time only, so the stored
    /// colorHex stays RGB. Defaults to fully opaque.
    var highlightOpacity: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: SettingsKeys.highlightOpacity) as? Double ?? 1)
    }

    /// Re-applies the given opacity to every markup in the open document and
    /// repaints. Replaces the alpha only; the RGB is preserved.
    func applyOpacity(_ opacity: CGFloat) {
        guard let doc = pdfDocument else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for ann in page.annotations where ann.type == "Highlight" || ann.type == "Underline" {
                guard let base = ann.color.usingColorSpace(.sRGB) else { continue }
                ann.color = base.withAlphaComponent(opacity)
            }
            pdfView?.annotationsChanged(on: page)
        }
        pdfView?.needsDisplay = true
    }

    func addHighlight(color: NSColor) {
        addMarkup(kind: .highlight, subtype: .highlight, color: color)
    }

    func addUnderline(color: NSColor) {
        addMarkup(kind: .underline, subtype: .underline, color: color)
    }

    private func addMarkup(kind: AnnotationKind, subtype: PDFAnnotationSubtype, color: NSColor) {
        guard let view = pdfView, let selection = view.currentSelection,
            let doc = pdfDocument, let documentId, let model
        else { return }

        var created: [RefmanCore.Annotation] = []
        for page in selection.pages {
            let pageIndex = doc.index(for: page)
            let uuid = UUID().uuidString

            // One markup annotation per line for clean quads.
            let lineSelections = selection.selectionsByLine().filter {
                $0.pages.contains(page)
            }
            var quads: [[Double]] = []
            for line in lineSelections {
                let b = line.bounds(for: page)
                guard !b.isEmpty else { continue }
                quads.append([
                    b.minX, b.maxY, b.maxX, b.maxY,
                    b.minX, b.minY, b.maxX, b.minY,
                ])
            }
            guard !quads.isEmpty else { continue }

            let union = selection.bounds(for: page)
            let pdfAnnotation = PDFAnnotation(
                bounds: union, forType: subtype, withProperties: nil)
            pdfAnnotation.color = color.withAlphaComponent(highlightOpacity)
            pdfAnnotation.quadrilateralPoints = quads.flatMap { quad in
                stride(from: 0, to: quad.count, by: 2).map { i in
                    // PDFKit wants points relative to the annotation bounds origin.
                    NSValue(point: NSPoint(x: quad[i] - union.minX, y: quad[i + 1] - union.minY))
                }
            }
            pdfAnnotation.setValue(uuid as NSString, forAnnotationKey: Self.uuidKey)
            page.addAnnotation(pdfAnnotation)

            let quadJSON = (try? JSONEncoder().encode(quads))
                .flatMap { String(data: $0, encoding: .utf8) }
            let record = RefmanCore.Annotation(
                uuid: uuid, documentId: documentId, pageIndex: pageIndex,
                kind: kind, colorHex: color.hexString,
                quadPoints: quadJSON,
                selectedText: selection.string)
            if let saved = try? model.repository.insert(record) {
                annotations.append(saved)
                created.append(saved)
            }
        }
        if !created.isEmpty { pushUndo(.added(created)) }
        annotations.sort { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
        view.clearSelection()
        savePDF()
    }

    // MARK: - Undo / redo

    func undo() {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .added(let records): records.forEach(removeAnnotation)
        case .removed(let record): restoreAnnotation(record)
        }
        redoStack.append(action)
        refreshUndoRedo()
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        switch action {
        case .added(let records): records.forEach(restoreAnnotation)
        case .removed(let record): removeAnnotation(record)
        }
        undoStack.append(action)
        refreshUndoRedo()
    }

    /// Records a fresh user edit, which invalidates the redo history.
    private func pushUndo(_ action: MarkupAction) {
        undoStack.append(action)
        redoStack.removeAll()
        refreshUndoRedo()
    }

    private func refreshUndoRedo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Recreates a previously removed markup on the page and in the database.
    private func restoreAnnotation(_ annotation: RefmanCore.Annotation) {
        guard let model, let doc = pdfDocument,
            let page = doc.page(at: annotation.pageIndex),
            let json = annotation.quadPoints?.data(using: .utf8),
            let quads = try? JSONDecoder().decode([[Double]].self, from: json),
            !quads.isEmpty
        else { return }

        let xs = quads.flatMap { quad in stride(from: 0, to: quad.count, by: 2).map { quad[$0] } }
        let ys = quads.flatMap { quad in stride(from: 1, to: quad.count, by: 2).map { quad[$0] } }
        let union = CGRect(
            x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let subtype: PDFAnnotationSubtype = annotation.kind == .underline ? .underline : .highlight

        let pdfAnnotation = PDFAnnotation(bounds: union, forType: subtype, withProperties: nil)
        pdfAnnotation.color = (NSColor(hex: annotation.colorHex) ?? .systemYellow)
            .withAlphaComponent(highlightOpacity)
        pdfAnnotation.quadrilateralPoints = quads.flatMap { quad in
            stride(from: 0, to: quad.count, by: 2).map { i in
                NSValue(point: NSPoint(x: quad[i] - union.minX, y: quad[i + 1] - union.minY))
            }
        }
        pdfAnnotation.setValue(annotation.uuid as NSString, forAnnotationKey: Self.uuidKey)
        if let note = annotation.noteText { pdfAnnotation.contents = note }
        page.addAnnotation(pdfAnnotation)

        var record = annotation
        record.id = nil  // fresh rowid; the uuid is what we match on
        if let saved = try? model.repository.insert(record) {
            annotations.append(saved)
            annotations.sort { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
        }
        savePDF()
    }

    // MARK: - Annotation actions

    func jump(to annotation: RefmanCore.Annotation) {
        guard let doc = pdfDocument, let page = doc.page(at: annotation.pageIndex) else { return }
        if let target = pdfAnnotation(for: annotation, on: page) {
            pdfView?.go(to: target.bounds, on: page)
        } else {
            pdfView?.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)))
        }
    }

    func setNote(_ text: String, for annotation: RefmanCore.Annotation) {
        guard let model, let documentId else { return }
        var updated = annotation
        updated.noteText = text
        updated.modifiedAt = Date()
        try? model.repository.database.dbWriter.write { db in
            try updated.update(db)
        }
        if let doc = pdfDocument, let page = doc.page(at: annotation.pageIndex),
            let pdfAnn = pdfAnnotation(for: annotation, on: page)
        {
            pdfAnn.contents = text
            savePDF()
        }
        annotations = (try? model.repository.annotations(documentId: documentId)) ?? annotations
    }

    /// Changes an existing markup's color in the page and the database.
    func recolor(_ annotation: RefmanCore.Annotation, to color: NSColor) {
        guard let model, let doc = pdfDocument, let page = doc.page(at: annotation.pageIndex),
            let pdfAnn = pdfAnnotation(for: annotation, on: page)
        else { return }
        pdfAnn.color = color.withAlphaComponent(highlightOpacity)
        pdfView?.annotationsChanged(on: page)
        pdfView?.needsDisplay = true
        var updated = annotation
        updated.colorHex = color.hexString
        updated.modifiedAt = Date()
        try? model.repository.database.dbWriter.write { db in try updated.update(db) }
        if let i = annotations.firstIndex(where: { $0.uuid == annotation.uuid }) {
            annotations[i] = updated
        }
        if clickedAnnotation?.uuid == annotation.uuid { clickedAnnotation = updated }
        savePDF()
    }

    /// Delete via the PDF annotation (context-menu removal in the viewer).
    func removeMarkup(_ pdfAnn: PDFAnnotation, on page: PDFPage) {
        guard let doc = pdfDocument else { return }
        let pageIndex = doc.index(for: page)
        guard
            let record = annotations.first(where: {
                $0.pageIndex == pageIndex && pdfAnnotation(for: $0, on: page) === pdfAnn
            })
        else { return }
        clearClickedAnnotation()
        delete(record)
    }

    /// User-initiated removal: reversible via undo.
    func delete(_ annotation: RefmanCore.Annotation) {
        removeAnnotation(annotation)
        pushUndo(.removed(annotation))
    }

    /// Removes a markup from the page and database without touching the
    /// undo/redo history (used by undo/redo themselves).
    private func removeAnnotation(_ annotation: RefmanCore.Annotation) {
        guard let model else { return }
        if let doc = pdfDocument, let page = doc.page(at: annotation.pageIndex),
            let pdfAnn = pdfAnnotation(for: annotation, on: page)
        {
            page.removeAnnotation(pdfAnn)
            // PDFView does not repaint on removal by itself; the stale
            // highlight would stay visible until the next scroll.
            pdfView?.annotationsChanged(on: page)
            pdfView?.needsDisplay = true
            savePDF()
        }
        try? model.repository.deleteAnnotation(uuid: annotation.uuid)
        annotations.removeAll { $0.uuid == annotation.uuid }
    }

    private func pdfAnnotation(
        for annotation: RefmanCore.Annotation, on page: PDFPage
    ) -> PDFAnnotation? {
        if let match = page.annotations.first(where: {
            let value = ($0.value(forAnnotationKey: Self.uuidKey) as? String)
                ?? ($0.value(forAnnotationKey: Self.legacyUUIDKey) as? String)
            return value == annotation.uuid
        }) {
            return match
        }
        // Markups saved before the UUID key existed carry no identifier in the
        // PDF; match them by type and the bounding box of their stored quads.
        guard let json = annotation.quadPoints?.data(using: .utf8),
            let quads = try? JSONDecoder().decode([[Double]].self, from: json),
            !quads.isEmpty
        else { return nil }
        let xs = quads.flatMap { quad in stride(from: 0, to: quad.count, by: 2).map { quad[$0] } }
        let ys = quads.flatMap { quad in stride(from: 1, to: quad.count, by: 2).map { quad[$0] } }
        let bounds = CGRect(
            x: xs.min()!, y: ys.min()!,
            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let typeName = annotation.kind == .underline ? "Underline" : "Highlight"
        return page.annotations.first {
            $0.type == typeName && abs($0.bounds.minX - bounds.minX) < 1
                && abs($0.bounds.minY - bounds.minY) < 1
                && abs($0.bounds.maxX - bounds.maxX) < 1
                && abs($0.bounds.maxY - bounds.maxY) < 1
        }
    }

    /// Writes the PDF off the main thread, coalescing edits made in quick
    /// succession into a single write.
    private func savePDF() {
        guard let doc = pdfDocument, let url = fileURL else { return }
        pendingSave?.cancel()
        // The debounce keeps the document idle while the background write runs.
        nonisolated(unsafe) let writeDoc = doc
        let work = DispatchWorkItem { writeDoc.write(to: url) }
        pendingSave = work
        Self.saveQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Flush any pending write immediately (e.g. when closing the reader).
    func flushSave() {
        guard let work = pendingSave, !work.isCancelled else { return }
        pendingSave = nil
        work.cancel()
        guard let doc = pdfDocument, let url = fileURL else { return }
        nonisolated(unsafe) let writeDoc = doc
        Self.saveQueue.async { writeDoc.write(to: url) }
    }
}

/// PDFView that reports clicks landing on highlight/underline annotations.
final class MarkupClickPDFView: PDFView {
    var onMarkupClick: ((PDFAnnotation, PDFPage) -> Void)?
    var onEmptyClick: (() -> Void)?
    var onMarkupRemove: ((PDFAnnotation, PDFPage) -> Void)?

    private var menuMarkup: (annotation: PDFAnnotation, page: PDFPage)?

    /// PDFKit's built-in "Remove Highlight" deletes the annotation from the
    /// page only, bypassing the database, so the markup reappears on reload.
    /// Replace the menu with a removal that goes through the model.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false) {
            let pagePoint = convert(point, to: page)
            if let ann = page.annotations.first(where: {
                ($0.type == "Highlight" || $0.type == "Underline")
                    && $0.bounds.contains(pagePoint)
            }) {
                menuMarkup = (ann, page)
                let menu = NSMenu()
                let title = ann.type == "Underline" ? "Remove Underline" : "Remove Highlight"
                let item = NSMenuItem(
                    title: title, action: #selector(removeMarkup), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
                return menu
            }
        }
        return super.menu(for: event)
    }

    @objc private func removeMarkup() {
        guard let (annotation, page) = menuMarkup else { return }
        menuMarkup = nil
        onMarkupRemove?(annotation, page)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var hit: (PDFAnnotation, PDFPage)?
        if let page = page(for: point, nearest: false) {
            let pagePoint = convert(point, to: page)
            if let ann = page.annotations.first(where: {
                ($0.type == "Highlight" || $0.type == "Underline")
                    && $0.bounds.contains(pagePoint)
            }) {
                hit = (ann, page)
            }
        }
        // Let PDFView handle selection first, so a drag over highlighted
        // text still selects instead of registering as a click.
        super.mouseDown(with: event)
        if let (ann, page) = hit {
            onMarkupClick?(ann, page)
        } else {
            onEmptyClick?()
        }
    }
}

/// NSViewRepresentable wrapper around PDFView.
struct PDFKitView: NSViewRepresentable {
    @ObservedObject var reader: ReaderModel
    @AppStorage(SettingsKeys.highlightOpacity) private var highlightOpacity = 1.0

    func makeNSView(context: Context) -> PDFView {
        let view = MarkupClickPDFView()
        view.onMarkupClick = { [weak reader] annotation, page in
            reader?.markupClicked(annotation, on: page)
        }
        view.onEmptyClick = { [weak reader] in
            reader?.clearClickedAnnotation()
        }
        view.onMarkupRemove = { [weak reader] annotation, page in
            reader?.removeMarkup(annotation, on: page)
        }
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = reader.pdfDocument
        reader.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged, object: view)
        // Track scrolling/zooming so the floating pen follows the selection.
        if let scrollView = view.subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.geometryChanged),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.geometryChanged),
            name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== reader.pdfDocument {
            view.document = reader.pdfDocument
            context.coordinator.lastOpacity = nil
        }
        // Apply on first display and whenever the Settings slider changes.
        if context.coordinator.lastOpacity != highlightOpacity {
            context.coordinator.lastOpacity = highlightOpacity
            reader.applyOpacity(CGFloat(highlightOpacity))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(reader: reader)
    }

    @MainActor
    final class Coordinator: NSObject {
        let reader: ReaderModel
        var lastOpacity: Double?
        init(reader: ReaderModel) { self.reader = reader }

        @objc func selectionChanged() {
            reader.selectionChanged()
        }

        @objc func geometryChanged() {
            reader.viewGeometryChanged()
        }

        @objc func pageChanged() {
            reader.pageChanged()
        }
    }
}

/// Toolbar in-document search: live match count with prev/next navigation.
struct ReaderSearchBar: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: $reader.searchText)
                .textFieldStyle(.plain)
                .frame(width: 150)
                .onSubmit { reader.nextMatch() }
            if !reader.searchText.isEmpty {
                Text(
                    reader.searchMatches.isEmpty
                        ? "0"
                        : "\(reader.searchActiveIndex + 1)/\(reader.searchMatches.count)"
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Button { reader.prevMatch() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(reader.searchMatches.isEmpty)
            Button { reader.nextMatch() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(reader.searchMatches.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .frame(width: 280)
        .onChange(of: reader.searchText) { reader.runSearch() }
    }
}

/// Toolbar page-number field with total; jumps to the typed page on submit and
/// follows the visible page while scrolling.
struct PageIndicator: View {
    @ObservedObject var reader: ReaderModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 40)
                .focused($focused)
                .onSubmit { if let n = Int(text) { reader.goToPage(n - 1) } }
            Text("/ \(reader.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onChange(of: reader.currentPageIndex) { syncText() }
        .onChange(of: focused) { if !focused { syncText() } }
        .onAppear { syncText() }
    }

    private func syncText() {
        if !focused { text = String(reader.currentPageIndex + 1) }
    }
}

/// Floating annotation pen shown next to the current text selection:
/// highlight colors, underline, note, and Ask AI.
struct SelectionPen: View {
    @ObservedObject var reader: ReaderModel
    @AppStorage(SettingsKeys.highlightPalette)
    private var highlightPalette = AnnotationOptions.defaultPalette

    private var highlightColors: [(name: String, color: NSColor)] {
        highlightPalette.split(separator: ",").compactMap { hex in
            guard AnnotationOptions.colors.contains(where: { $0.hex == hex }),
                let color = NSColor(hex: String(hex))
            else { return nil }
            return (reader.label(forHex: String(hex)), color)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(highlightColors, id: \.name) { entry in
                Button {
                    reader.addHighlight(color: entry.color)
                } label: {
                    Circle()
                        .fill(Color(nsColor: entry.color))
                        .frame(width: 13, height: 13)
                }
                .buttonStyle(.plain)
                .help("Highlight: \(entry.name)")
            }

            separator

            ForEach(highlightColors, id: \.name) { entry in
                Button {
                    reader.addUnderline(color: entry.color)
                } label: {
                    VStack(spacing: 1.5) {
                        Text("U")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(nsColor: entry.color))
                            .frame(width: 13, height: 3.5)
                    }
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Underline: \(entry.name)")
            }

            separator

            Menu {
                Button("Copy") { reader.copySelection(.plain) }
                Button("Copy with Citation (in-text)") { reader.copySelection(.inline) }
                Button("Copy with Citation") { reader.copySelection(.full) }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Copy the selection, optionally with a formatted citation")

            separator

            Button {
                reader.askAI()
            } label: {
                Label("Ask AI", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.purple)
            .help("Ask the assistant about this selection")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var separator: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 18)
    }
}

/// Floating action shown when the user clicks an existing highlight/underline:
/// recolor swatches and remove.
struct AnnotationBubble: View {
    @ObservedObject var reader: ReaderModel
    let annotation: RefmanCore.Annotation
    @AppStorage(SettingsKeys.highlightPalette)
    private var highlightPalette = AnnotationOptions.defaultPalette

    private var paletteColors: [(name: String, color: NSColor)] {
        highlightPalette.split(separator: ",").compactMap { hex in
            guard AnnotationOptions.colors.contains(where: { $0.hex == hex }),
                let color = NSColor(hex: String(hex))
            else { return nil }
            return (reader.label(forHex: String(hex)), color)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(paletteColors, id: \.name) { entry in
                Button {
                    reader.recolor(annotation, to: entry.color)
                } label: {
                    Circle()
                        .fill(Color(nsColor: entry.color))
                        .frame(width: 13, height: 13)
                        .overlay {
                            if annotation.colorHex == entry.color.hexString {
                                Circle().strokeBorder(.primary, lineWidth: 1.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Recolor: \(entry.name)")
            }

            Rectangle().fill(.quaternary).frame(width: 1, height: 18)

            Button {
                reader.clearClickedAnnotation()
                reader.delete(annotation)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this annotation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// Left sidebar: a segmented Outline / Annotations switch when the PDF has a
/// table of contents, otherwise just the annotations list.
struct ReaderSidebar: View {
    @ObservedObject var reader: ReaderModel
    @State private var tab = Tab.annotations

    enum Tab { case outline, annotations }

    var body: some View {
        VStack(spacing: 0) {
            if !reader.outline.isEmpty {
                Picker("", selection: $tab) {
                    Text("Outline").tag(Tab.outline)
                    Text("Annotations").tag(Tab.annotations)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            if tab == .outline, !reader.outline.isEmpty {
                OutlineList(reader: reader)
            } else {
                AnnotationSidebar(reader: reader)
            }
        }
    }
}

/// The document's table of contents; click an entry to jump there.
struct OutlineList: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(reader.outline) { item in
                    Button {
                        reader.go(to: item)
                    } label: {
                        HStack(spacing: 6) {
                            Text(item.label)
                                .font(.callout)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            if let page = item.pageIndex {
                                Text("\(page + 1)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, CGFloat(item.depth) * 14)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

/// Lists annotations; click to jump, edit note text inline.
struct AnnotationSidebar: View {
    @ObservedObject var reader: ReaderModel
    @State private var followPage = false
    /// Color hexes to show; empty means no filter.
    @State private var colorFilter: Set<String> = []
    /// Color being labeled via the chip context menu.
    @State private var labelingHex: String?
    @State private var labelText = ""

    /// Distinct annotation colors, in first-seen order.
    private var presentColors: [String] {
        var seen = Set<String>()
        return reader.annotations.compactMap {
            seen.insert($0.colorHex).inserted ? $0.colorHex : nil
        }
    }

    private var filteredAnnotations: [RefmanCore.Annotation] {
        colorFilter.isEmpty
            ? reader.annotations
            : reader.annotations.filter { colorFilter.contains($0.colorHex) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Annotations (\(filteredAnnotations.count))")
                    .font(.headline)
                Spacer()
                Toggle(isOn: $followPage) {
                    Label("Follow page", systemImage: "arrow.down.doc")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Scroll the list to keep the current page's annotations in view")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !presentColors.isEmpty {
                HStack(spacing: 8) {
                    ForEach(presentColors, id: \.self) { hex in
                        Button {
                            if colorFilter.contains(hex) {
                                colorFilter.remove(hex)
                            } else {
                                colorFilter.insert(hex)
                            }
                        } label: {
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: hex) ?? .systemYellow))
                                .frame(width: 14, height: 14)
                                .opacity(
                                    colorFilter.isEmpty || colorFilter.contains(hex) ? 1 : 0.25)
                        }
                        .buttonStyle(.plain)
                        .help("\(reader.label(forHex: hex)) — click to filter")
                        .contextMenu {
                            Button("Label “\(reader.label(forHex: hex))”…") {
                                labelText = reader.colorLabels[hex] ?? ""
                                labelingHex = hex
                            }
                        }
                    }
                    Spacer()
                    if !colorFilter.isEmpty {
                        Button("All") { colorFilter.removeAll() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredAnnotations, id: \.uuid) { annotation in
                            AnnotationRow(reader: reader, annotation: annotation)
                                .id(annotation.uuid)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .onChange(of: reader.currentPageIndex) { scrollToCurrentPage(proxy) }
                .onChange(of: followPage) {
                    if followPage { scrollToCurrentPage(proxy) }
                }
            }
        }
        .alert(
            "Label Color",
            isPresented: Binding(
                get: { labelingHex != nil },
                set: { if !$0 { labelingHex = nil } }
            )
        ) {
            TextField("e.g. Key finding", text: $labelText)
            Button("Save") {
                if let hex = labelingHex { reader.setColorLabel(labelText, forHex: hex) }
                labelText = ""
            }
            Button("Cancel", role: .cancel) { labelText = "" }
        } message: {
            Text("Names this color in this document. Leave empty to remove the label.")
        }
    }

    /// In follow-page mode, bring the first annotation on (or after) the
    /// visible page to the top of the list.
    private func scrollToCurrentPage(_ proxy: ScrollViewProxy) {
        guard followPage,
            let target = filteredAnnotations.first(where: {
                $0.pageIndex >= reader.currentPageIndex
            })
        else { return }
        // Defer past the current layout pass so the proxy can find the row.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target.uuid, anchor: .top) }
        }
    }
}

struct AnnotationRow: View {
    @ObservedObject var reader: ReaderModel
    let annotation: RefmanCore.Annotation
    @State private var noteText: String
    @State private var editingNote: Bool

    init(reader: ReaderModel, annotation: RefmanCore.Annotation) {
        self.reader = reader
        self.annotation = annotation
        let note = annotation.noteText ?? ""
        _noteText = State(initialValue: note)
        _editingNote = State(initialValue: !note.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(Color(nsColor: NSColor(hex: annotation.colorHex) ?? .systemYellow))
                    .frame(width: 8, height: 8)
                Text(
                    "p. \(annotation.pageIndex + 1) · \(annotation.kind.rawValue)"
                        + (reader.colorLabels[annotation.colorHex].map { " · \($0)" } ?? "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    reader.delete(annotation)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let text = annotation.selectedText, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .lineLimit(3)
                    .padding(.leading, 4)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
                HStack(spacing: 12) {
                    Button("Summarize") { reader.aiActionRequest = AssistantPrompts.summarize(text) }
                    Button("Explain") { reader.aiActionRequest = AssistantPrompts.explain(text) }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption)
                .foregroundStyle(.purple)
            }
            if editingNote {
                TextField("Note…", text: $noteText, axis: .vertical)
                    .font(.callout)
                    .onSubmit { reader.setNote(noteText, for: annotation) }
            } else {
                Button {
                    editingNote = true
                } label: {
                    Label("Add note", systemImage: "note.text.badge.plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { reader.jump(to: annotation) }
    }
}

// MARK: - Color helpers

extension NSColor {
    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}
