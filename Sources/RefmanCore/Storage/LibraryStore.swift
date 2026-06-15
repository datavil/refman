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

    /// Default location: ~/Library/Application Support/Refman/Storage
    public static func `default`() throws -> LibraryStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try LibraryStore(rootURL: base.appendingPathComponent("Refman/Storage"))
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the file into the store. Returns its content hash.
    /// Idempotent: importing the same bytes twice is a no-op.
    @discardableResult
    public func ingest(fileAt url: URL) throws -> String {
        try ingest(data: try Data(contentsOf: url))
    }

    /// Stores raw PDF bytes (e.g. a downloaded paper). Returns the content hash.
    @discardableResult
    public func ingest(data: Data) throws -> String {
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

    /// When a stored PDF has been evicted by iCloud (kept only as a
    /// `.<name>.icloud` placeholder), kicks off a download. Returns true if the
    /// file is already materialized. Non-blocking: the daemon downloads async.
    @discardableResult
    public func ensureDownloaded(hash: String) -> Bool {
        let target = url(forHash: hash)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return true }
        let placeholder = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: target)
        }
        return false
    }

    public func remove(hash: String) throws {
        let u = url(forHash: hash)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    /// Content hashes of every PDF currently on disk (filename minus `.pdf`).
    public func allStoredHashes() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil)
        return Set(files.filter { $0.pathExtension == "pdf" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    /// Total size in bytes of all stored PDFs.
    public func totalSize() throws -> Int64 {
        let files = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.fileSizeKey])
        return try files.reduce(0) { sum, url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return sum + Int64(size)
        }
    }
}
