import SwiftUI

struct DocumentListView: View {
    @Bindable var model: IPadAppModel
    @Binding var isFileImporterPresented: Bool

    var body: some View {
        Group {
            if model.documents.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No References" : "No Results",
                    systemImage: model.searchText.isEmpty ? "books.vertical" : "magnifyingglass",
                    description: Text(
                        model.searchText.isEmpty
                            ? "Import a PDF to start your iPad library."
                            : "Try a different search.")
                )
            } else {
                List(selection: $model.selectedDocumentID) {
                    ForEach(model.documents) { details in
                        DocumentRowView(details: details)
                            .tag(details.id)
                    }
                }
            }
        }
        .navigationTitle("References")
        .searchable(text: $model.searchText, prompt: "Search library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import PDF", systemImage: "square.and.arrow.down") {
                    isFileImporterPresented = true
                }
                .disabled(model.isImporting)
            }
        }
        .onChange(of: model.searchText) { _, _ in
            model.reload()
        }
        .onChange(of: model.selectedDocumentID) { _, id in
            model.selectDocument(id)
        }
    }
}
