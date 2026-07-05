import AppKit
import Foundation
import Observation

/// Checks GitHub Releases for a newer build and, when the app is running from a
/// proper `.app` bundle, downloads the latest `.zip`, swaps the bundle in place,
/// and relaunches. Unsigned-app friendly: it strips the quarantine flag itself.
@MainActor
@Observable
final class Updater {
    /// owner/repo on GitHub that publishes the releases.
    private static let repo = "datavil/refman"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        /// Fetching the zip; `fraction` is 0...1, or nil while the size is unknown.
        case downloading(fraction: Double?)
        /// Extracting the downloaded zip — no granular progress available.
        case unpacking
        case failed(String)

        /// True while a check or install is in flight, used to disable controls.
        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .unpacking: return true
            default: return false
            }
        }
    }

    private(set) var status: Status = .idle

    /// Version baked into the bundle's Info.plist; "0.0.0" when run unbundled.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    /// `Refman.app` URL when running from a bundle, else nil (e.g. `swift run`).
    private var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private var latest: (version: String, zipURL: URL, page: URL)?

    private static let lastCheckKey = "lastUpdateCheck"

    /// Checks GitHub at most once a day, silently — the result surfaces as the
    /// sidebar "Update available" pill rather than an alert. Call on launch.
    func checkInBackgroundIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < 24 * 3600 { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        check(userInitiated: false)
    }

    /// Fetches the latest release and compares it to the running version.
    /// `userInitiated` surfaces the result (and any error) in an alert.
    func check(userInitiated: Bool) {
        guard !status.isBusy else { return }
        status = .checking
        Task {
            do {
                let release = try await fetchLatest()
                let latestVersion = release.tagName
                let zip = release.assets.first { $0.name.hasSuffix(".zip") }
                if Self.isNewer(latestVersion, than: Self.currentVersion), let zip,
                    let zipURL = URL(string: zip.browserDownloadURL),
                    let page = URL(string: release.htmlURL)
                {
                    latest = (latestVersion, zipURL, page)
                    status = .available(version: latestVersion)
                    if userInitiated { promptInstall(version: latestVersion, page: page) }
                } else {
                    latest = nil
                    status = .upToDate
                    if userInitiated { info("You're up to date", "Refman \(Self.currentVersion) is the latest version.") }
                }
            } catch {
                status = .failed(error.localizedDescription)
                if userInitiated {
                    info("Couldn't check for updates", error.localizedDescription)
                }
            }
        }
    }

    /// Downloads the pending update's zip and installs it (replacing this app).
    func installPending() {
        guard let latest else { return }
        guard let target = appBundleURL else {
            info(
                "Update available",
                "Refman \(latest.version) is available, but in-app install only works "
                    + "in the installed Refman.app. Opening the download page.")
            NSWorkspace.shared.open(latest.page)
            return
        }
        status = .downloading(fraction: nil)
        Task {
            do {
                try await downloadAndSwap(zipURL: latest.zipURL, target: target)
                // downloadAndSwap relaunches via a helper, so terminate here.
                NSApp.terminate(nil)
            } catch {
                status = .failed(error.localizedDescription)
                info("Update failed", error.localizedDescription)
            }
        }
    }

    // MARK: - Networking

    private func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "Updater", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "GitHub returned an unexpected response."])
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func downloadAndSwap(zipURL: URL, target: URL) async throws {
        let downloaded = try await download(zipURL)
        // Unpack immediately — the temporary download is short-lived.
        status = .unpacking
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefmanUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", downloaded.path, stage.path])
        guard let newApp = firstApp(in: stage) else {
            throw NSError(
                domain: "Updater", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No Refman.app found in the download."])
        }
        scheduleSwapAndRelaunch(newApp: newApp, target: target)
    }

    /// Downloads `url`, reporting progress onto `status`, and returns a stable
    /// file URL. Uses a session-scoped delegate because the per-task delegate of
    /// `download(from:delegate:)` does not receive `didWriteData` callbacks.
    private func download(_ url: URL) async throws -> URL {
        let delegate = DownloadProgressDelegate { [weak self] fraction in
            Task { @MainActor in self?.status = .downloading(fraction: fraction) }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// Writes a helper that waits for this process to exit, replaces the bundle,
    /// clears quarantine, and relaunches — then runs it detached.
    private func scheduleSwapAndRelaunch(newApp: URL, target: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            #!/bin/bash
            while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
            rm -rf "\(target.path)"
            /usr/bin/ditto "\(newApp.path)" "\(target.path)"
            /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null || true
            /usr/bin/open "\(target.path)"
            """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refman-update-\(UUID().uuidString).sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        try? task.run()  // detached; we terminate right after
    }

    // MARK: - Helpers

    private func firstApp(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(
                domain: "Updater", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(launchPath) failed."])
        }
        return task.terminationStatus
    }

    /// Compares dotted versions (leading "v" allowed), e.g. "v0.2.1" > "0.2.0".
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { !$0.isNumber }).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Alerts

    private func promptInstall(version: String, page: URL) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText =
            "Refman \(version) is available (you have \(Self.currentVersion)). "
            + "Download and install it now? Refman will relaunch."
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: installPending()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(page)
        default: break
        }
    }

    private func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Session delegate that reports download progress and bridges completion to an
/// async continuation. Callbacks arrive serially on the session's delegate queue.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let onProgress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system reclaims `location` once this returns, so move it out first.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefmanDownload-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
