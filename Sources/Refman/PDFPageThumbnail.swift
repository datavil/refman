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
            let image = await Self.renderFirstPage(of: url)
            guard !Task.isCancelled else { return }
            thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
            isLoading = false
        }
    }

    /// Loads and renders off the main thread: an iCloud-evicted (dataless) PDF
    /// downloads on first read, which can take a minute.
    @concurrent
    private nonisolated static func renderFirstPage(of url: URL) async -> CGImage? {
        PDFDocument(url: url)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 600, height: 800), for: .cropBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
