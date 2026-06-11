import AppKit
import QuickLook
import RefManCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue
    @State private var newCollectionName = ""
    @State private var showingNewCollection = false
    @State private var previewURL: URL?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            documentTable
                .navigationSplitViewColumnWidth(min: 400, ideal: 560)
        } detail: {
            if let details = model.selectedDocument {
                InspectorView(details: details)
                    .id(details.document.id)  // reset editing state on selection change
            } else {
                ContentUnavailableView(
                    "No Selection", systemImage: "doc.text",
                    description: Text("Select a document, or drop PDFs anywhere to import."))
            }
        }
        .searchable(text: $model.searchText, prompt: "Search title, authors, full text")
        .onChange(of: model.searchText) { model.reload() }
        .onChange(of: model.sidebarSelection) { model.reload() }
        .onChange(of: appearance, initial: true) {
            // Drive AppKit appearance too, so panels and sheets follow along.
            switch AppAppearance(rawValue: appearance) ?? .system {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
        .quickLookPreview($previewURL)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.importViaPanel()
                } label: {
                    Label("Import PDFs", systemImage: "plus.circle")
                }
                .help("Import PDFs (⌘I)")
            }
            ToolbarItem {
                if model.isImporting { ProgressView().controlSize(.small) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    private var sidebar: some View {
        List(selection: $model.sidebarSelection) {
            Section("Library") {
                Label("All Documents", systemImage: "books.vertical")
                    .tag(SidebarItem.all)
            }
            Section("Collections") {
                ForEach(model.collections, id: \.id) { collection in
                    Label(collection.name, systemImage: "folder")
                        .tag(SidebarItem.collection(collection.id!))
                        .contextMenu {
                            Button("Delete Collection", role: .destructive) {
                                model.deleteCollection(id: collection.id!)
                            }
                        }
                }
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
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(10)
            .help("RefMan Settings (⌘,)")
        }
    }

    private var documentTable: some View {
        Table(model.documents, selection: $model.selectedDocumentId) {
            TableColumn("Title") { details in
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
            TableColumn("Year") { details in
                Text(details.document.year.map(String.init) ?? "—")
            }
            .width(48)
            TableColumn("Venue") { details in
                Text(details.document.venue ?? "—").lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            TableColumn("PDF") { details in
                if details.document.fileHash != nil {
                    Image(systemName: "doc.fill").foregroundStyle(.red.opacity(0.7))
                }
            }
            .width(36)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first {
                Button("Open PDF") { openReader(id) }
                Menu("Add to Collection") {
                    ForEach(model.collections, id: \.id) { collection in
                        Button(collection.name) {
                            model.selectedDocumentId = id
                            model.addSelectedDocument(toCollection: collection.id!)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    model.selectedDocumentId = id
                    model.deleteSelectedDocument()
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { openReader(id) }
        }
        .onKeyPress(.space) {
            guard let details = model.selectedDocument,
                let url = model.pdfURL(for: details)
            else { return .ignored }
            previewURL = url
            return .handled
        }
    }

    private func openReader(_ id: Int64) {
        guard let details = try? model.repository.document(id: id),
            model.pdfURL(for: details) != nil
        else {
            model.statusMessage = "No PDF attached to this reference."
            return
        }
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
