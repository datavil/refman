import AppKit
import QuickLook
import RefmanCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.light.rawValue
    @AppStorage(SettingsKeys.citationStyle) private var citationStyleRaw = Citeproc.Style.apa.rawValue
    @State private var newCollectionName = ""
    @State private var showingNewCollection = false
    @State private var collectionToDelete: RefmanCore.Collection?
    @State private var subcollectionParent: RefmanCore.Collection?
    @State private var subcollectionName = ""
    @State private var renamingCollectionId: Int64?
    @State private var renameText = ""
    @State private var previewURL: URL?
    @State private var showingAddPopover = false
    @State private var identifierText = ""
    @State private var sortOrder = [KeyPathComparator(\DocumentDetails.sortTitle)]
    @State private var columnCustomization = TableColumnCustomization<DocumentDetails>()
    @State private var showingImportReport = false
    @State private var showingPalette = false

    private var inTrash: Bool { model.sidebarSelection == .trash }

    /// PDF file-type glyph for the document table, loaded once from the bundle.
    /// Black artwork for light mode, a white variant for dark mode.
    private static let pdfIcon = loadSVG("pdf-svgrepo-com")
    private static let pdfIconWhite = loadSVG("pdf-svgrepo-com-white")

    private static func loadSVG(_ name: String) -> NSImage {
        resourceBundle?.url(forResource: name, withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    }

    /// True when the bundled PDF glyphs load (non-empty). Drives the
    /// `--check-resources` CI smoke check, which exercises this exact path in
    /// the packaged `.app` — where a missing resource bundle would otherwise
    /// only surface as a crash once the document table renders a row.
    static func verifyResources() -> Bool {
        pdfIcon.size.width > 0 && pdfIconWhite.size.width > 0
            && Citeproc.resourcesAvailable()
    }

    /// The SwiftPM resource bundle, located without `Bundle.module`'s trap:
    /// in a packaged `.app` the bundle lives in `Contents/Resources`, but the
    /// generated `Bundle.module` only checks the app root and a dev build path,
    /// so it crashes. This checks the real locations and degrades gracefully.
    private static let resourceBundle: Bundle? = {
        let name = "Refman_Refman.bundle"
        let candidates = [
            Bundle.main.resourceURL,  // .app/Contents/Resources
            Bundle.main.bundleURL,  // .app root and `swift run` exe dir
            Bundle(for: BundleToken.self).resourceURL,
        ]
        for url in candidates.compactMap({ $0?.appendingPathComponent(name) }) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.main
    }()

    private final class BundleToken {}

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 189, ideal: 240)
                .toolbar(removing: .sidebarToggle)
        } content: {
            documentTable
                .navigationSplitViewColumnWidth(min: 400, ideal: 560)
        } detail: {
            Group {
                if model.selectedDocumentIds.count > 1 {
                    multiSelectionSummary
                } else if let details = model.selectedDocument {
                    InspectorView(details: details)
                        .id(details.document.id)  // reset editing state on selection change
                } else {
                    ContentUnavailableView(
                        "No Selection", systemImage: "doc.text",
                        description: Text("Select a document, or drop PDFs anywhere to import."))
                }
            }
            .navigationSplitViewColumnWidth(min: 392, ideal: 470)
        }
        .searchable(text: $model.searchText, prompt: "Search title, authors, full text")
        // Defer reloads off the current update cycle: mutating the Table's data
        // synchronously from .onChange reenters the backing NSTableView delegate.
        .onChange(of: model.searchText) { Task { @MainActor in model.reload() } }
        .onChange(of: model.sidebarSelection) { Task { @MainActor in model.reload() } }
        .onChange(of: appearance, initial: true) {
            // Drive AppKit appearance too, so panels and sheets follow along.
            switch AppAppearance(rawValue: appearance) ?? .system {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
        .background(ToolbarConfigurator())
        .background {
            // Cmd+F focuses the library search field; scoped to this window so
            // it doesn't shadow the reader's own Cmd+F find bar.
            Button { focusLibrarySearch() } label: {}
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .quickLookPreview($previewURL)
        .task { model.updater.checkInBackgroundIfDue() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onChange(of: model.addRequested) { showingAddPopover = true }
        .onChange(of: model.paletteRequested) { showingPalette = true }
        .sheet(isPresented: $showingPalette) {
            CommandPalette(isPresented: $showingPalette)
        }
        .sheet(isPresented: $showingImportReport) {
            ImportReportView(outcomes: model.importLog)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem {
                Button {
                    showingAddPopover = true
                } label: {
                    Label("Add Reference", systemImage: "plus.circle")
                }
                .help("Add a reference")
                .popover(isPresented: $showingAddPopover, arrowEdge: .bottom) {
                    addPopover
                }
            }
            if inTrash {
                ToolbarItem {
                    Button(role: .destructive) {
                        model.emptyTrash()
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                    .help("Permanently delete all documents in the Trash")
                    .disabled(model.documents.isEmpty)
                }
            }
            ToolbarItem {
                if let progress = model.importProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(progress.done)/\(progress.total)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.isImporting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.statusMessage {
                HStack {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if hasImportReport {
                        Button("Report") { showingImportReport = true }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(.bar)
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    if model.statusMessage == message { model.statusMessage = nil }
                }
            }
        }
    }

    /// The last import had something worth reporting (a duplicate or failure).
    private var hasImportReport: Bool {
        model.importLog.contains { $0.status != .imported }
    }

    private var sidebar: some View {
        List(selection: $model.sidebarSelection) {
            Section("Library") {
                Label("All Documents", systemImage: "books.vertical")
                    .tag(SidebarItem.all)
                    .contextMenu {
                        Menu("Export All") {
                            Button("BibTeX…") {
                                model.exportViaPanel(format: .bibtex)
                            }
                            Button("RIS…") {
                                model.exportViaPanel(format: .ris)
                            }
                            Button("PDFs…") {
                                model.exportBundleViaPanel(collectionId: nil)
                            }
                            Button("RIS + BibTeX + PDFs…") {
                                model.exportBundleViaPanel(collectionId: nil, includeRIS: true)
                            }
                        }
                    }
                Label("Recently Added", systemImage: "clock")
                    .tag(SidebarItem.recent)
                Label("Uncategorized", systemImage: "tray")
                    .tag(SidebarItem.uncategorized)
                Label("Trash", systemImage: "trash")
                    .tag(SidebarItem.trash)
            }
            Section("Reading") {
                Label("Currently Reading", systemImage: "book")
                    .tag(SidebarItem.reading)
                Label("Recently Opened", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.recentlyOpened)
            }
            Section("Collections") {
                CollectionTree(
                    parentId: nil,
                    collectionToDelete: $collectionToDelete,
                    subcollectionParent: $subcollectionParent,
                    renamingCollectionId: $renamingCollectionId,
                    renameText: $renameText)
                if showingNewCollection {
                    TextField("Collection name", text: $newCollectionName)
                    .onSubmit {
                        if !newCollectionName.isEmpty {
                            model.createCollection(named: newCollectionName)
                        }
                        newCollectionName = ""
                        showingNewCollection = false
                    }
                }
                Button {
                    showingNewCollection = true
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.id) { tag in
                        Label(tag.name, systemImage: "tag")
                            .tag(SidebarItem.tag(tag.id!))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            "Delete “\(collectionToDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { collectionToDelete != nil },
                set: { if !$0 { collectionToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = collectionToDelete?.id { model.deleteCollection(id: id) }
                collectionToDelete = nil
            }
        } message: {
            Text("Subcollections are also deleted. Documents stay in the library.")
        }
        .alert(
            "New Subcollection in “\(subcollectionParent?.name ?? "")”",
            isPresented: Binding(
                get: { subcollectionParent != nil },
                set: { if !$0 { subcollectionParent = nil } }
            )
        ) {
            TextField("Name", text: $subcollectionName)
            Button("Create") {
                if let parent = subcollectionParent, !subcollectionName.isEmpty {
                    model.createCollection(named: subcollectionName, parentId: parent.id)
                }
                subcollectionName = ""
            }
            Button("Cancel", role: .cancel) { subcollectionName = "" }
        }
        .safeAreaInset(edge: .top, alignment: .leading) {
            HStack(spacing: 8) {
                Image(nsImage: colorScheme == .dark ? AppIcon.markWhite : AppIcon.mark)
                    .resizable()
                    .frame(width: 40, height: 40)
                Text("Refman")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            SidebarFooter(
                updater: model.updater,
                openSettings: { openSettings() },
                openAISettings: { openWindow(id: "ai-settings") })
        }
    }

    fileprivate static let collectionIcons: [(group: String, icons: [(name: String, symbol: String)])] = [
        (
            "Library",
            [
                ("Folder", "folder"), ("Books", "books.vertical"), ("Book", "book.closed"),
                ("Document", "doc.text"), ("Archive", "archivebox"), ("Tray", "tray.full"),
                ("Bookmark", "bookmark"), ("Tag", "tag"), ("Pin", "pin"),
                ("Paperclip", "paperclip"),
            ]
        ),
        (
            "Science",
            [
                ("Flask", "flask"), ("Test Tube", "testtube.2"), ("Microbe", "microbe"),
                ("Allergens", "allergens"), ("Atom", "atom"), ("Brain", "brain"),
                ("Syringe", "syringe"), ("Pills", "pills"), ("Stethoscope", "stethoscope"),
                ("Leaf", "leaf"), ("Pawprint", "pawprint"), ("Fish", "fish"),
                ("Bird", "bird"),
            ]
        ),
        (
            "Data",
            [
                ("Bar Chart", "chart.bar"), ("Trend", "chart.line.uptrend.xyaxis"),
                ("Function", "function"), ("Square Root", "x.squareroot"),
                ("Terminal", "terminal"), ("Gear", "gearshape"),
            ]
        ),
        (
            "Symbols",
            [
                ("Star", "star"), ("Heart", "heart"), ("Flag", "flag"), ("Bolt", "bolt"),
                ("Flame", "flame"), ("Drop", "drop"), ("Snowflake", "snowflake"),
                ("Sun", "sun.max"), ("Moon", "moon"), ("Sparkles", "sparkles"),
                ("Globe", "globe"), ("Map", "map"), ("Clock", "clock"),
                ("Calendar", "calendar"), ("Lightbulb", "lightbulb"),
                ("Graduation Cap", "graduationcap"), ("People", "person.2"),
                ("Museum", "building.columns"), ("Puzzle", "puzzlepiece"),
                ("Cube", "cube"), ("Palette", "paintpalette"), ("Camera", "camera"),
                ("Music Note", "music.note"), ("Eye", "eye"),
            ]
        ),
    ]

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add by Identifier").font(.headline)
            HStack(spacing: 8) {
                TextField("DOI, PubMed ID, arXiv ID, or link", text: $identifierText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitIdentifier)
                Button("Add", action: submitIdentifier)
                    .keyboardShortcut(.defaultAction)
                    .disabled(identifierText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            Button {
                showingAddPopover = false
                model.importViaPanel()
            } label: {
                Label("Import PDF…", systemImage: "doc.badge.plus")
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func submitIdentifier() {
        let text = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addByIdentifier(text)
        identifierText = ""
        showingAddPopover = false
    }

    private var documentTable: some View {
        Table(
            of: DocumentDetails.self,
            selection: $model.selectedDocumentIds,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Title", value: \.sortTitle) { details in
                VStack(alignment: .leading, spacing: 2) {
                    Text(details.document.title.isEmpty ? "Untitled" : details.document.title)
                        .lineLimit(2)
                    if !details.authorsText.isEmpty {
                        Text(details.authorsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 250, ideal: 380)
            .customizationID("title")
            TableColumn("Year", value: \.sortYear) { details in
                Text(details.document.year.map(String.init) ?? "—")
            }
            .width(48)
            .customizationID("year")
            TableColumn("Venue", value: \.sortVenue) { details in
                Text(details.document.venue ?? "—").lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            .customizationID("venue")
            TableColumn("PDF") { details in
                if details.document.fileHash != nil {
                    Image(nsImage: colorScheme == .dark ? Self.pdfIconWhite : Self.pdfIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                }
            }
            .width(36)
            .customizationID("pdf")
        } rows: {
            ForEach(model.documents.sorted(using: sortOrder)) { details in
                TableRow(details)
                    .itemProvider { NSItemProvider(object: String(details.id) as NSString) }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: Int64.self) { ids in
            documentContextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, !inTrash { openReader(id) }
        }
        .onKeyPress(.space) {
            guard let details = model.selectedDocument,
                let url = model.pdfURL(for: details)
            else { return .ignored }
            previewURL = url
            return .handled
        }
        .overlay {
            if model.documents.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private func documentContextMenu(_ ids: Set<Int64>) -> some View {
        if !ids.isEmpty {
            if inTrash {
                Button(ids.count == 1 ? "Restore" : "Restore \(ids.count)") {
                    for id in ids { model.restoreFromTrash(id: id) }
                }
                Divider()
                Button(ids.count == 1 ? "Delete Permanently" : "Delete \(ids.count) Permanently", role: .destructive) {
                    for id in ids { model.purgeDocument(id: id) }
                }
            } else {
                if ids.count == 1, let id = ids.first {
                    Button("Open PDF") { openReader(id) }
                    Button("Quick Look") { quickLook(id) }
                    Button("Fetch PDF") { model.fetchPDF(id: id) }
                    Button("Refresh Metadata") { model.refreshMetadata(id: id) }
                    Divider()
                    Button("Summarize") { model.generateInsight(.summary, for: id) }
                    Button("Key Points") { model.generateInsight(.keyPoints, for: id) }
                    Button("Methods") { model.generateInsight(.methods, for: id) }
                    Button("Limitations") { model.generateInsight(.limitations, for: id) }
                    Divider()
                    if model.documents.first(where: { $0.id == id })?.document.isReading == true {
                        Button("Remove from Currently Reading") { model.clearReading() }
                    } else {
                        Button("Mark as Currently Reading") { model.setReading(id: id) }
                    }
                } else {
                    Button("Refresh Metadata") { model.refreshMetadata(ids: Array(ids)) }
                }
                copyMenu("Copy Formatted Citation", ids: ids, mode: .bibliography)
                copyMenu("Copy In-Text Citation", ids: ids, mode: .citation)
                Menu("Export") {
                    Button("BibTeX…") {
                        model.exportViaPanel(format: .bibtex, documentIds: Array(ids))
                    }
                    Button("RIS…") {
                        model.exportViaPanel(format: .ris, documentIds: Array(ids))
                    }
                    Button("PDFs…") {
                        model.exportBundleViaPanel(documentIds: Array(ids))
                    }
                    Button("RIS + BibTeX + PDFs…") {
                        model.exportBundleViaPanel(documentIds: Array(ids), includeRIS: true)
                    }
                }
                Menu("Add to Collection") {
                    ForEach(model.collections, id: \.id) { collection in
                        Button(collection.name) {
                            model.add(documentIds: Array(ids), toCollection: collection.id!)
                        }
                    }
                }
                Divider()
                Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) References", role: .destructive) {
                    model.delete(documentIds: Array(ids))
                }
            }
        }
    }

    /// The remembered citation style used for a direct (primary-action) copy.
    private var citationStyle: Citeproc.Style {
        Citeproc.Style(rawValue: citationStyleRaw) ?? .apa
    }

    /// A split button: clicking copies with the remembered style; the submenu
    /// switches the style (and remembers it) before copying.
    private func copyMenu(_ title: String, ids: Set<Int64>, mode: Citeproc.Mode) -> some View {
        Menu {
            ForEach(Citeproc.Style.allCases, id: \.self) { style in
                Button {
                    citationStyleRaw = style.rawValue
                    model.copyCitation(documentIds: Array(ids), style: style, mode: mode)
                } label: {
                    if style == citationStyle {
                        Label(style.label, systemImage: "checkmark")
                    } else {
                        Text(style.label)
                    }
                }
            }
        } label: {
            Text("\(title) (\(citationStyle.label))")
        } primaryAction: {
            model.copyCitation(documentIds: Array(ids), style: citationStyle, mode: mode)
        }
    }

    private var multiSelectionSummary: some View {
        let selected = model.documents.filter { model.selectedDocumentIds.contains($0.id) }
        let venues = Set(
            selected.compactMap { $0.document.venue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        let years = selected.compactMap { $0.document.year }

        var parts: [String] = []
        if !venues.isEmpty {
            if venues.count <= 3 {
                parts.append("from \(venues.sorted().joined(separator: ", "))")
            } else {
                parts.append("across \(venues.count) venues")
            }
        }
        if let lo = years.min(), let hi = years.max() {
            parts.append(lo == hi ? "\(lo)" : "\(lo)–\(hi)")
        }

        return ContentUnavailableView {
            Label("\(selected.count) papers selected", systemImage: "doc.on.doc")
        } description: {
            if !parts.isEmpty { Text(parts.joined(separator: " · ")) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if inTrash {
            ContentUnavailableView("Trash is Empty", systemImage: "trash")
        } else if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.sidebarSelection == .recentlyOpened {
            ContentUnavailableView(
                "Nothing Opened Recently", systemImage: "clock.arrow.circlepath",
                description: Text("Papers you open appear here for two days."))
        } else if model.sidebarSelection == .reading {
            ContentUnavailableView(
                "Not Reading Anything", systemImage: "book",
                description: Text("Right-click a paper and choose “Mark as Currently Reading.”"))
        } else if model.sidebarSelection == .all {
            ContentUnavailableView {
                Label("Your Library is Empty", systemImage: "books.vertical")
            } description: {
                Text("Import PDFs or add a reference by DOI, PubMed ID, or arXiv ID.")
            } actions: {
                Button("Import PDF…") { model.importViaPanel() }
                Button("Add by Identifier…") { showingAddPopover = true }
                Button("Settings…") { openSettings() }
            }
        } else {
            ContentUnavailableView("No Documents", systemImage: "doc")
        }
    }

    private func quickLook(_ id: Int64) {
        guard let details = try? model.repository.document(id: id),
            let url = model.pdfURL(for: details)
        else { return }
        previewURL = url
    }

    /// Makes the toolbar's `.searchable` field first responder in the key window.
    private func focusLibrarySearch() {
        guard let window = NSApp.keyWindow, let toolbar = window.toolbar else { return }
        for item in toolbar.items {
            if let searchItem = item as? NSSearchToolbarItem {
                window.makeFirstResponder(searchItem.searchField)
                return
            }
            if let field = item.view as? NSSearchField {
                window.makeFirstResponder(field)
                return
            }
        }
    }

    private func openReader(_ id: Int64) {
        guard let details = try? model.repository.document(id: id),
            model.pdfURL(for: details) != nil
        else {
            model.statusMessage = "No PDF attached to this reference."
            return
        }
        model.markOpened(id: id)
        openWindow(id: "reader", value: id)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.pathExtension.lowercased() == "pdf" {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { model.importPDFs(at: urls) }
        }
        return true
    }
}

/// Forces the window toolbar to icon-only and locks it down, so toolbar items
/// never show labels and the right-click "Icon and Text / Icon Only / Text Only"
/// menu doesn't appear. (`allowsDisplayModeCustomization` is macOS 15+; on
/// earlier systems items are still pinned to icon-only.)
private struct ToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if let toolbar = window.toolbar {
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            if #available(macOS 15.0, *) {
                toolbar.allowsDisplayModeCustomization = false
            }
        }
        // Stop the leading sidebar from collapsing when dragged fully left.
        // SwiftUI's NavigationSplitView is backed by an NSSplitView whose delegate
        // is the (private) NSSplitViewController; it isn't in the VC tree, so reach
        // it via the split view's delegate.
        guard let split = window.contentView?.firstSplitViewInTree,
            let splitVC = split.delegate as? NSSplitViewController
        else { return }
        for item in splitVC.splitViewItems where item.behavior == .sidebar {
            item.canCollapse = false
            item.minimumThickness = 189
            // SwiftUI's drag handling collapses the sidebar even with canCollapse
            // = false, so watch isCollapsed and force it back open.
            SidebarCollapseGuard.attach(to: item)
        }
        // On a fresh install SwiftUI doesn't reliably honor the columns' `ideal`
        // widths, so snap to the built-in defaults the first time.
        LayoutReset.applyDefaultsIfFresh(split)
    }
}

/// Observes a split view item's `isCollapsed` and snaps it back open, defeating
/// SwiftUI's drag-to-collapse on the library sidebar. Retained on the item.
private final class SidebarCollapseGuard {
    private var observation: NSKeyValueObservation?

    static func attach(to item: NSSplitViewItem) {
        if objc_getAssociatedObject(item, &guardKey) != nil { return }
        let guardian = SidebarCollapseGuard()
        guardian.observation = item.observe(\.isCollapsed, options: [.new]) { item, _ in
            if item.isCollapsed {
                DispatchQueue.main.async { item.isCollapsed = false }
            }
        }
        objc_setAssociatedObject(item, &guardKey, guardian, .OBJC_ASSOCIATION_RETAIN)
    }
}

private var guardKey: UInt8 = 0

/// Restores window size and sidebar widths to their built-in defaults.
enum LayoutReset {
    /// Sidebar/inspector ideal widths and the library window's default size.
    /// Keep these in sync with `navigationSplitViewColumnWidth` and `defaultSize`.
    static let sidebarWidth: CGFloat = 240
    static let inspectorWidth: CGFloat = 470
    static let windowSize = NSSize(width: 1280, height: 800)

    /// Set once per launch, so we don't re-snap dividers the user has dragged
    /// before SwiftUI persists their new geometry.
    private static var appliedFreshDefaults = false

    /// First-launch only: when SwiftUI has no saved split geometry yet, force the
    /// default divider positions (its `ideal` column widths are applied
    /// unreliably). Leaves the window size alone and never overrides a layout the
    /// user has already saved.
    static func applyDefaultsIfFresh(_ split: NSSplitView) {
        guard !appliedFreshDefaults, split.subviews.count >= 3 else { return }
        let hasSavedLayout = UserDefaults.standard.dictionaryRepresentation().keys
            .contains { $0.hasPrefix("NSSplitView Subview Frames") }
        guard !hasSavedLayout else { return }
        appliedFreshDefaults = true
        split.layoutSubtreeIfNeeded()
        split.setPosition(sidebarWidth, ofDividerAt: 0)
        split.setPosition(split.bounds.width - inspectorWidth, ofDividerAt: 1)
    }

    static func run() {
        // Forget the autosaved geometry so the next launch also starts fresh.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView Subview Frames") {
            defaults.removeObject(forKey: key)
        }
        // Snap the open library window back to defaults now.
        for window in NSApp.windows {
            guard let split = window.contentView?.firstSplitViewInTree,
                split.delegate is NSSplitViewController,
                split.subviews.count >= 3
            else { continue }
            window.setContentSize(windowSize)
            window.center()
            split.layoutSubtreeIfNeeded()
            split.setPosition(sidebarWidth, ofDividerAt: 0)
            split.setPosition(split.bounds.width - inspectorWidth, ofDividerAt: 1)
        }
    }
}

extension NSView {
    /// Depth-first search for the first NSSplitView in this subtree.
    fileprivate var firstSplitViewInTree: NSSplitView? {
        if let split = self as? NSSplitView { return split }
        for sub in subviews {
            if let found = sub.firstSplitViewInTree { return found }
        }
        return nil
    }
}

/// Bottom of the sidebar: the Settings button, plus an "Update available" pill
/// when a newer release was found by the background check.
private struct SidebarFooter: View {
    @ObservedObject var updater: Updater
    let openSettings: () -> Void
    let openAISettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .available(let version) = updater.status {
                Button {
                    updater.installPending()
                } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Install Refman \(version) and relaunch")
            }
            Button {
                openAISettings()
            } label: {
                Label("AI Settings", systemImage: "sparkles")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Assistant agent and model settings")
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refman Settings (⌘,)")
        }
        .padding(10)
    }
}

/// One level of the collection hierarchy; recurses for subcollections.
private struct CollectionTree: View {
    @EnvironmentObject var model: AppModel
    let parentId: Int64?
    @Binding var collectionToDelete: RefmanCore.Collection?
    @Binding var subcollectionParent: RefmanCore.Collection?
    @Binding var renamingCollectionId: Int64?
    @Binding var renameText: String
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        ForEach(model.collections.filter { $0.parentId == parentId }, id: \.id) { collection in
            if model.collections.contains(where: { $0.parentId == collection.id }) {
                DisclosureGroup {
                    CollectionTree(
                        parentId: collection.id,
                        collectionToDelete: $collectionToDelete,
                        subcollectionParent: $subcollectionParent,
                        renamingCollectionId: $renamingCollectionId,
                        renameText: $renameText)
                } label: {
                    row(for: collection)
                }
                .tag(SidebarItem.collection(collection.id!))
            } else {
                row(for: collection)
                    .tag(SidebarItem.collection(collection.id!))
            }
        }
        .onMove { source, destination in
            model.moveCollections(parentId: parentId, from: source, to: destination)
        }
    }

    @ViewBuilder
    private func row(for collection: RefmanCore.Collection) -> some View {
        if renamingCollectionId == collection.id {
            Label {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onAppear { renameFieldFocused = true }
                    .onSubmit { commitRename(collection) }
                    .onExitCommand { renamingCollectionId = nil }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused, renamingCollectionId == collection.id {
                            commitRename(collection)
                        }
                    }
            } icon: {
                Image(systemName: collection.icon ?? "folder")
            }
        } else {
            Label(collection.name, systemImage: collection.icon ?? "folder")
            .contextMenu {
                Menu("Icon") {
                    ForEach(LibraryView.collectionIcons, id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.icons, id: \.symbol) { icon in
                                Button {
                                    model.setCollectionIcon(id: collection.id!, to: icon.symbol)
                                } label: {
                                    Label(icon.name, systemImage: icon.symbol)
                                }
                            }
                        }
                    }
                }
                Button("Rename") {
                    renameText = collection.name
                    renamingCollectionId = collection.id
                }
                Button("New Subcollection") {
                    subcollectionParent = collection
                }
                Menu("Export") {
                    Button("BibTeX…") {
                        model.exportViaPanel(
                            format: .bibtex, collectionId: collection.id!, name: collection.name)
                    }
                    Button("RIS…") {
                        model.exportViaPanel(
                            format: .ris, collectionId: collection.id!, name: collection.name)
                    }
                    Button("PDFs…") {
                        model.exportBundleViaPanel(
                            collectionId: collection.id!, name: collection.name)
                    }
                    Button("RIS + BibTeX + PDFs…") {
                        model.exportBundleViaPanel(
                            collectionId: collection.id!, name: collection.name, includeRIS: true)
                    }
                }
                Button("Import from Folder…") {
                    model.importFromFolderViaPanel(collectionId: collection.id!)
                }
                Button("Delete Collection", role: .destructive) {
                    collectionToDelete = collection
                }
            }
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(Int64.init)
                guard !ids.isEmpty else { return false }
                model.add(documentIds: ids, toCollection: collection.id!)
                return true
            }
        }
    }

    private func commitRename(_ collection: RefmanCore.Collection) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != collection.name {
            model.renameCollection(id: collection.id!, to: name)
        }
        renamingCollectionId = nil
    }
}

/// ⌘K quick navigation across documents, collections, and actions.
private struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var allDocs: [DocumentDetails] = []
    @FocusState private var focused: Bool

    private var docs: [DocumentDetails] {
        guard !query.isEmpty else { return Array(allDocs.prefix(8)) }
        let q = query.lowercased()
        return allDocs.filter {
            $0.document.title.lowercased().contains(q)
                || $0.authorsText.lowercased().contains(q)
        }.prefix(12).map { $0 }
    }

    private var collections: [RefmanCore.Collection] {
        guard !query.isEmpty else { return [] }
        return model.collections.filter { $0.name.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to a document, collection, or action…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { if let first = docs.first { open(first) } }
            Divider()
            List {
                if !collections.isEmpty {
                    Section("Collections") {
                        ForEach(collections, id: \.id) { c in
                            Button {
                                model.sidebarSelection = .collection(c.id!)
                                isPresented = false
                            } label: {
                                Label(c.name, systemImage: c.icon ?? "folder")
                            }
                        }
                    }
                }
                Section(query.isEmpty ? "Recent" : "Documents") {
                    ForEach(docs) { d in
                        Button { open(d) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.document.title.isEmpty ? "Untitled" : d.document.title)
                                    .lineLimit(1)
                                if !d.authorsText.isEmpty {
                                    Text(d.authorsText)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                if query.isEmpty {
                    Section("Actions") {
                        Button {
                            isPresented = false
                            model.importViaPanel()
                        } label: { Label("Import PDF…", systemImage: "doc.badge.plus") }
                        Button {
                            isPresented = false
                            model.requestAdd()
                        } label: { Label("Add by Identifier…", systemImage: "plus.circle") }
                    }
                }
            }
            .listStyle(.inset)
            .buttonStyle(.plain)
        }
        .frame(width: 560, height: 420)
        .onAppear {
            allDocs = (try? model.repository.allDocuments()) ?? []
            focused = true
        }
        .onExitCommand { isPresented = false }
    }

    private func open(_ d: DocumentDetails) {
        model.sidebarSelection = .all
        model.selectedDocumentId = d.id
        isPresented = false
    }
}

/// Per-file results of the most recent import.
private struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let outcomes: [ImportOutcome]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Report").font(.headline).padding()
            Divider()
            List(outcomes) { outcome in
                HStack {
                    Image(systemName: symbol(outcome.status))
                        .foregroundStyle(color(outcome.status))
                    Text(outcome.name).lineLimit(1)
                    Spacer()
                    Text(label(outcome.status)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 360)
    }

    private func symbol(_ s: ImportOutcome.Status) -> String {
        switch s {
        case .imported: return "checkmark.circle.fill"
        case .duplicate: return "doc.on.doc"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ s: ImportOutcome.Status) -> Color {
        switch s {
        case .imported: return .green
        case .duplicate: return .secondary
        case .failed: return .orange
        }
    }

    private func label(_ s: ImportOutcome.Status) -> String {
        switch s {
        case .imported: return "Imported"
        case .duplicate: return "Duplicate"
        case .failed: return "Failed"
        }
    }
}
