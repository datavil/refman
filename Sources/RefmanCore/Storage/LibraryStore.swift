import CryptoKit
import Foundation

/// Content-addressed PDF storage: files live at `<root>/<sha256>.pdf`.
/// The database references files by hash, which makes dedup and sync trivial.
public struct LibraryStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Default location: ~/Library/Application Support/RefMan/Storage
    public static func `default`() throws -> LibraryStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try LibraryStore(rootURL: base.appendingPathComponent("RefMan/Storage"))
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the file into the store. Returns its content hash.
    /// Idempotent: importing the same bytes twice is a no-op.
    @discardableResult
    public func ingest(fileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hash = Self.sha256(of: data)
        let dest = self.url(forHash: hash)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try data.write(to: dest, options: .atomic)
        }
        return hash
    }

    public func url(forHash hash: String) -> URL {
        rootURL.appendingPathComponent("\(hash).pdf")
    }

    public func exists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forHash: hash).path)
    }

    public func remove(hash: String) throws {
        let u = url(forHash: hash)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }
}
