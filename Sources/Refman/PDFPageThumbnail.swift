import PDFKit
import SwiftUI

/// A compact preview of the first page of a locally stored PDF.
struct PDFPageThumbnail: View {
    @Environment(\.colorScheme) private var colorScheme

    let url: URL

    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .border(.secondary.opacity(0.3), width: 1)
                    .shadow(
                        color: colorScheme == .dark
                            ? .white.opacity(0.2) : .black.opacity(0.18),
                        radius: 4,
                        y: 2
                    )
                    .accessibilityHidden(true)
            } else if isLoading {
                ProgressView()
            } else {
                Label("Preview unavailable", systemImage: "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 225, height: 300)
        .task(id: url) {
            isLoading = true
            thumbnail = PDFDocument(url: url)?.page(at: 0)?.thumbnail(
                of: CGSize(width: 600, height: 800), for: .cropBox)
            isLoading = false
        }
    }
}
