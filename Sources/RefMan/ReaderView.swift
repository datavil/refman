import PDFKit
import RefManCore
import SwiftUI

/// PDF reading window: viewer, annotation toolbar, annotation sidebar, assistant.
struct ReaderView: View {
    @EnvironmentObject var model: AppModel
    let documentId: Int64

    @StateObject private var reader = ReaderModel()
    @State private var showAnnotations = true
    @State private var showAssistant = false
    @State private var pendingQuestion: String?

    var body: some View {
        HSplitView {
            ZStack(alignment: .topLeading) {
                PDFKitView(reader: reader)
                if let rect = reader.selectionRect {
                    SelectionPen(reader: reader)
                        .position(x: max(rect.midX, 120), y: max(rect.minY - 26, 20))
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 500)
            if showAnnotations {
                AnnotationSidebar(reader: reader)
                    .frame(width: 260)
            }
            if showAssistant {
                AssistantPanel(documentId: documentId, pendingQuestion: $pendingQuestion)
                    .frame(width: 320)
            }
        }
        // The two sidebars are mutually exclusive.
        .onChange(of: showAssistant) {
            if showAssistant { showAnnotations = false }
        }
        .onChange(of: showAnnotations) {
            if showAnnotations { showAssistant = false }
        }
        .onChange(of: reader.askAIRequest) {
            guard let text = reader.askAIRequest else { return }
            reader.askAIRequest = nil
            pendingQuestion = "Regarding this passage from the paper:\n\n“\(text)”\n\n"
            showAssistant = true
        }
        .navigationTitle(reader.title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    reader.addHighlight(color: .yellow)
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }
                .help("Highlight selection")
                .disabled(!reader.hasSelection)

                Button {
                    reader.addUnderline()
                } label: {
                    Label("Underline", systemImage: "underline")
                }
                .disabled(!reader.hasSelection)

                Button {
                    reader.addNoteToSelection()
                } label: {
                    Label("Note", systemImage: "note.text.badge.plus")
                }
                .disabled(!reader.hasSelection)

                Spacer()

                Toggle(isOn: $showAnnotations) {
                    Label("Annotations", systemImage: "sidebar.right")
                }
                Toggle(isOn: $showAssistant) {
                    Label("Assistant", systemImage: "sparkles")
                }
            }
        }
        .onAppear {
            reader.load(documentId: documentId, model: model)
        }
    }
}

/// Owns the PDFDocument, mirrors annotations to the repository, persists the PDF.
@MainActor
final class ReaderModel: ObservableObject {
    @Published var annotations: [RefManCore.Annotation] = []
    @Published var hasSelection = false
    @Published var title = "Reader"
    /// Selection bounds in the PDFView's SwiftUI (top-left) coordinates,
    /// for positioning the floating annotation pen.
    @Published var selectionRect: CGRect?
    /// Set when the user hits “Ask AI” on a selection.
    @Published var askAIRequest: String?

    private(set) var pdfDocument: PDFDocument?
    private var fileURL: URL?
    private var documentId: Int64?
    private var model: AppModel?
    weak var pdfView: PDFView?

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
        annotations = (try? model.repository.annotations(documentId: documentId)) ?? []
    }

    func selectionChanged() {
        hasSelection = !(pdfView?.currentSelection?.string?.isEmpty ?? true)
        selectionRect = currentSelectionViewRect()
    }

    /// Re-anchor (or hide) the pen when the document scrolls under a selection.
    func viewGeometryChanged() {
        guard selectionRect != nil else { return }
        selectionRect = currentSelectionViewRect()
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

    func addHighlight(color: NSColor) {
        addMarkup(kind: .highlight, subtype: .highlight, color: color)
    }

    func addUnderline() {
        addMarkup(kind: .underline, subtype: .underline, color: .systemBlue)
    }

    func addNoteToSelection() {
        guard let view = pdfView, let selection = view.currentSelection,
            let page = selection.pages.first, let doc = pdfDocument,
            let documentId, let model
        else { return }
        let pageIndex = doc.index(for: page)
        let bounds = selection.bounds(for: page)
        let uuid = UUID().uuidString

        let noteBounds = CGRect(
            x: bounds.maxX + 4, y: bounds.midY - 10, width: 20, height: 20)
        let pdfAnnotation = PDFAnnotation(
            bounds: noteBounds, forType: .text, withProperties: nil)
        pdfAnnotation.color = .systemOrange
        pdfAnnotation.contents = ""
        pdfAnnotation.setValue(uuid as NSString, forAnnotationKey: .name)
        page.addAnnotation(pdfAnnotation)

        let record = RefManCore.Annotation(
            uuid: uuid, documentId: documentId, pageIndex: pageIndex,
            kind: .note, colorHex: "#FF9500",
            selectedText: selection.string, noteText: "")
        if let saved = try? model.repository.insert(record) {
            annotations.append(saved)
            annotations.sort { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
        }
        savePDF()
    }

    private func addMarkup(kind: AnnotationKind, subtype: PDFAnnotationSubtype, color: NSColor) {
        guard let view = pdfView, let selection = view.currentSelection,
            let doc = pdfDocument, let documentId, let model
        else { return }

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
            pdfAnnotation.color = color
            pdfAnnotation.quadrilateralPoints = quads.flatMap { quad in
                stride(from: 0, to: quad.count, by: 2).map { i in
                    // PDFKit wants points relative to the annotation bounds origin.
                    NSValue(point: NSPoint(x: quad[i] - union.minX, y: quad[i + 1] - union.minY))
                }
            }
            pdfAnnotation.setValue(uuid as NSString, forAnnotationKey: .name)
            page.addAnnotation(pdfAnnotation)

            let quadJSON = (try? JSONEncoder().encode(quads))
                .flatMap { String(data: $0, encoding: .utf8) }
            let record = RefManCore.Annotation(
                uuid: uuid, documentId: documentId, pageIndex: pageIndex,
                kind: kind, colorHex: color.hexString,
                quadPoints: quadJSON,
                selectedText: selection.string)
            if let saved = try? model.repository.insert(record) {
                annotations.append(saved)
            }
        }
        annotations.sort { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
        view.clearSelection()
        savePDF()
    }

    // MARK: - Annotation actions

    func jump(to annotation: RefManCore.Annotation) {
        guard let doc = pdfDocument, let page = doc.page(at: annotation.pageIndex) else { return }
        if let target = pdfAnnotation(for: annotation, on: page) {
            pdfView?.go(to: target.bounds, on: page)
        } else {
            pdfView?.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)))
        }
    }

    func setNote(_ text: String, for annotation: RefManCore.Annotation) {
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

    func delete(_ annotation: RefManCore.Annotation) {
        guard let model else { return }
        if let doc = pdfDocument, let page = doc.page(at: annotation.pageIndex),
            let pdfAnn = pdfAnnotation(for: annotation, on: page)
        {
            page.removeAnnotation(pdfAnn)
            savePDF()
        }
        try? model.repository.deleteAnnotation(uuid: annotation.uuid)
        annotations.removeAll { $0.uuid == annotation.uuid }
    }

    private func pdfAnnotation(
        for annotation: RefManCore.Annotation, on page: PDFPage
    ) -> PDFAnnotation? {
        page.annotations.first {
            ($0.value(forAnnotationKey: .name) as? String) == annotation.uuid
        }
    }

    private func savePDF() {
        guard let doc = pdfDocument, let url = fileURL else { return }
        doc.write(to: url)
    }
}

/// NSViewRepresentable wrapper around PDFView.
struct PDFKitView: NSViewRepresentable {
    @ObservedObject var reader: ReaderModel

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
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
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== reader.pdfDocument {
            view.document = reader.pdfDocument
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(reader: reader)
    }

    @MainActor
    final class Coordinator: NSObject {
        let reader: ReaderModel
        init(reader: ReaderModel) { self.reader = reader }

        @objc func selectionChanged() {
            reader.selectionChanged()
        }

        @objc func geometryChanged() {
            reader.viewGeometryChanged()
        }
    }
}

/// Floating annotation pen shown next to the current text selection:
/// highlight colors, underline, note, and Ask AI.
struct SelectionPen: View {
    @ObservedObject var reader: ReaderModel

    private static let highlightColors: [(name: String, color: NSColor)] = [
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Pink", .systemPink),
        ("Blue", .systemBlue),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.highlightColors, id: \.name) { entry in
                Button {
                    reader.addHighlight(color: entry.color)
                } label: {
                    Circle()
                        .fill(Color(nsColor: entry.color))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.quaternary))
                }
                .buttonStyle(.plain)
                .help("Highlight \(entry.name.lowercased())")
            }

            Divider().frame(height: 14)

            Button {
                reader.addUnderline()
            } label: {
                Image(systemName: "underline")
            }
            .buttonStyle(.plain)
            .help("Underline")

            Button {
                reader.addNoteToSelection()
            } label: {
                Image(systemName: "note.text.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Add note")

            Divider().frame(height: 14)

            Button {
                reader.askAI()
            } label: {
                Label("Ask AI", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.purple)
            .help("Ask the assistant about this selection")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .shadow(radius: 3, y: 1)
    }
}

/// Lists annotations; click to jump, edit note text inline.
struct AnnotationSidebar: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        List {
            Section("Annotations (\(reader.annotations.count))") {
                ForEach(reader.annotations, id: \.uuid) { annotation in
                    AnnotationRow(reader: reader, annotation: annotation)
                }
            }
        }
        .listStyle(.inset)
    }
}

struct AnnotationRow: View {
    @ObservedObject var reader: ReaderModel
    let annotation: RefManCore.Annotation
    @State private var noteText: String

    init(reader: ReaderModel, annotation: RefManCore.Annotation) {
        self.reader = reader
        self.annotation = annotation
        _noteText = State(initialValue: annotation.noteText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(Color(nsColor: NSColor(hex: annotation.colorHex) ?? .systemYellow))
                    .frame(width: 8, height: 8)
                Text("p. \(annotation.pageIndex + 1) · \(annotation.kind.rawValue)")
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
            }
            if annotation.kind == .note {
                TextField("Note…", text: $noteText, axis: .vertical)
                    .font(.callout)
                    .onSubmit { reader.setNote(noteText, for: annotation) }
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
