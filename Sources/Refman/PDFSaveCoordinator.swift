import Foundation

/// Serializes PDF file writes without sharing PDFKit objects across actors.
actor PDFSaveCoordinator {
    func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }
}
