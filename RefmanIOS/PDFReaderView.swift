import PDFKit
import SwiftUI

struct PDFReaderView: View {
    let url: URL
    @State private var searchText = ""

    var body: some View {
        PDFKitReader(url: url, searchText: searchText)
            .ignoresSafeArea(edges: .bottom)
            .searchable(text: $searchText, prompt: "Search PDF")
    }
}

private struct PDFKitReader: UIViewRepresentable {
    let url: URL
    let searchText: String

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }

        guard !searchText.isEmpty else {
            view.highlightedSelections = nil
            return
        }

        let selections = view.document?.findString(
            searchText, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? []
        view.highlightedSelections = selections
        if let first = selections.first {
            view.setCurrentSelection(first, animate: true)
            view.go(to: first)
        }
    }
}
