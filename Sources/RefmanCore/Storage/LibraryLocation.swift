import Foundation

/// Resolves where the library lives on disk and relocates it between locations
/// (e.g. local Application Support ↔ an iCloud Drive folder for sync).
///
/// Layout under a root directory:
///   <root>/library.sqlite      — the database
///   <root>/Storage/<sha>.pdf   — content-addressed PDFs
public enum LibraryLocation {
    public static let databaseName = "library.sqlite"
    public static let storeFolderName = "Storage"

    public static func databaseURL(root: URL) -> URL {
        root.appendingPathComponent(databaseName)
    }

    public static func storeURL(root: URL) -> URL {
        root.appendingPathComponent(storeFolderName)
    }

    /// Folder name for the library root in both local and iCloud locations.
    public static let folderName = "Refman"

    /// Default local root: ~/Library/Application Support/Refman
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base.appendingPathComponent(folderName)
    }

    /// The intended Refman folder inside the user's iCloud Drive, or nil when
    /// iCloud Drive isn't enabled on this Mac.
    ///
    /// `com~apple~CloudDocs` is a plain directory in the user's home, so an
    /// unsandboxed app can read/write it with no entitlements; the iCloud
    /// daemon syncs whatever lands there.
    public static func iCloudDriveRoot() -> URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent(folderName)
    }

    /// True when the given root lives inside an iCloud container.
    public static func isICloud(_ root: URL) -> Bool {
        root.standardizedFileURL.path.contains("/Mobile Documents/")
    }

    /// Sets or clears the Finder "hidden" flag on a folder. Unlike a dot-prefixed
    /// name (which iCloud Drive refuses to sync), a hidden-but-normally-named
    /// folder still syncs — it's just tucked away in Finder.
    public static func setHidden(_ hidden: Bool, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var url = url
        var values = URLResourceValues()
        values.isHidden = hidden
        try url.setResourceValues(values)
    }

    /// Fixes the on-disk casing of the library folder to match `root`'s name
    /// (e.g. a differently-cased folder left by an older build). Uses a temp step
    /// case-insensitive volume, where the two names share an inode. Best-effort.
    public static func normalizeCasing(of root: URL) {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        let desired = root.lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(atPath: parent.path),
            let current = entries.first(where: {
                $0.caseInsensitiveCompare(desired) == .orderedSame && $0 != desired
            })
        else { return }
        let currentURL = parent.appendingPathComponent(current)
        let tempURL = parent.appendingPathComponent(".\(desired)-rename-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: currentURL, to: tempURL)
            try fm.moveItem(at: tempURL, to: root)
        } catch {
            try? fm.moveItem(at: tempURL, to: currentURL)  // roll back on failure
        }
    }

    /// Forces iCloud to download every evicted (dataless) file under `root` and
    /// waits until they're materialized. Moving a dataless placeholder out of the
    /// iCloud container loses its data — its bytes only exist in the cloud — so
    /// this must run before relocating a library off iCloud. Best-effort with a
    /// timeout; a no-op for files that aren't in iCloud.
    public static func materialize(at root: URL) async throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]

        func pendingDownloads() -> [URL] {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys))
            else { return [] }
            var result: [URL] = []
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                    values.isUbiquitousItem == true,
                    values.ubiquitousItemDownloadingStatus != .current
                else { continue }
                result.append(url)
            }
            return result
        }

        let deadline = Date().addingTimeInterval(300)
        var pending = pendingDownloads()
        while !pending.isEmpty {
            for url in pending { try? fm.startDownloadingUbiquitousItem(at: url) }
            guard Date() < deadline else { throw LibraryLocationError.downloadTimedOut }
            try await Task.sleep(for: .milliseconds(500))
            pending = pendingDownloads()
        }
    }

    /// Moves an existing library (database + storage) from one root to another,
    /// creating the destination and replacing any items already there. Copies
    /// then deletes the source so a partial failure can't lose data. Items that
    /// don't exist at the source are skipped.
    public static func relocate(from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in [databaseName, storeFolderName] {
            let src = from.appendingPathComponent(name)
            let dst = to.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            try fm.removeItem(at: src)
        }
    }
}

public enum LibraryLocationError: LocalizedError {
    case downloadTimedOut

    public var errorDescription: String? {
        switch self {
        case .downloadTimedOut:
            "Timed out downloading the library from iCloud. Check your connection and try again."
        }
    }
}
