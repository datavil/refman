import SwiftUI

struct DocumentDetailView: View {
    @Bindable var model: IPadAppModel
    @State private var showsMetadata = false

    var body: some View {
        Group {
            if let details = model.selectedDocument {
                if let url = model.pdfURL(for: details) {
                    PDFReaderView(url: url)
                        .navigationTitle(details.document.title)
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                Button(
                                    details.document.isReading
                                        ? "Stop Reading" : "Mark as Currently Reading",
                                    systemImage: details.document.isReading
                                        ? "bookmark.slash" : "bookmark"
                                ) {
                                    model.toggleReading()
                                }
                                Button("Document Details", systemImage: "info.circle") {
                                    showsMetadata = true
                                }
                                DocumentActionButton(
                                    isInTrash: model.section == .trash, model: model)
                            }
                        }
                        .sheet(isPresented: $showsMetadata) {
                            NavigationStack {
                                DocumentMetadataView(details: details)
                            }
                        }
                } else {
                    DocumentMetadataView(details: details)
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                Button(
                                    details.document.isReading
                                        ? "Stop Reading" : "Mark as Currently Reading",
                                    systemImage: details.document.isReading
                                        ? "bookmark.slash" : "bookmark"
                                ) {
                                    model.toggleReading()
                                }
                                DocumentActionButton(
                                    isInTrash: model.section == .trash, model: model)
                            }
                        }
                }
            } else {
                ContentUnavailableView(
                    "Select a Reference",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a reference to read its PDF and metadata.")
                )
            }
        }
    }
}
