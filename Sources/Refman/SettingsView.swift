import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The app's accent color, applied through the macOS per-app `AppleAccentColor`
/// override so the selected-paper highlight (and other accent controls) use it.
/// macOS reads the accent at launch, so a change takes effect after relaunch.
enum AppAccent: String, CaseIterable, Identifiable {
    case system, graphite, red, orange, yellow, green, blue, purple, pink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Default"
        case .graphite: return "Graphite"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// Swatch shown in the picker.
    var color: Color {
        switch self {
        case .system: return Color(.controlAccentColor)
        case .graphite: return Color(.systemGray)
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }

    /// The `AppleAccentColor` value macOS expects, or nil to inherit the system
    /// accent (the override key is removed).
    var appleAccentValue: Int? {
        switch self {
        case .system: return nil
        case .graphite: return -1
        case .red: return 0
        case .orange: return 1
        case .yellow: return 2
        case .green: return 3
        case .blue: return 4
        case .purple: return 5
        case .pink: return 6
        }
    }

    /// Writes (or clears) the per-app accent override. Takes effect on next launch.
    func applyToDefaults() {
        let defaults = UserDefaults.standard
        if let value = appleAccentValue {
            defaults.set(value, forKey: "AppleAccentColor")
        } else {
            defaults.removeObject(forKey: "AppleAccentColor")
        }
    }

    /// The accent currently chosen in Settings (defaults to following the system).
    static var stored: AppAccent {
        AppAccent(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.accentColor) ?? "")
            ?? .system
    }
}

enum SettingsKeys {
    static let appearance = "appearance"
    static let agentPath = "agentPath"
    static let llmProvider = "llmProvider"  // "ollama" | "openai" | "claude"
    static let ollamaModel = "ollamaModel"
    static let claudeModel = "claudeModel"
    static let openaiModel = "openaiModel"
    static let accentColor = "accentColor"
    static let highlightPalette = "highlightPalette"
    static let highlightOpacity = "highlightOpacity"
    static let citationStyle = "citationStyle"
    static let contactEmail = "contactEmail"
    static let libraryRootPath = "libraryRootPath"

    /// UserDefaults key holding the user's override for a preset AI prompt.
    /// `raw` is the DocumentInsight raw value (e.g. "summary").
    static func promptOverride(forInsight raw: String) -> String {
        "prompt.\(raw)"
    }
}

/// Lists models from a local Ollama for the model picker.
@MainActor
final class OllamaModelList: ObservableObject {
    @Published var models: [String] = []
    @Published var loadFailed = false

    func load() {
        Task {
            do {
                let host = ProcessInfo.processInfo.environment["REFMAN_OLLAMA_HOST"]
                    ?? "http://127.0.0.1:11434"
                let (data, _) = try await URLSession.shared.data(
                    from: URL(string: "\(host)/api/tags")!)
                struct Tags: Decodable {
                    struct Model: Decodable { let name: String }
                    let models: [Model]
                }
                models = try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
                loadFailed = false
            } catch {
                models = []
                loadFailed = true
            }
        }
    }
}

/// Lists Codex's available models from its local cache (`~/.codex/models_cache.json`)
/// for the model picker — Codex has no list-models command.
@MainActor
final class CodexModelList: ObservableObject {
    @Published var models: [(slug: String, name: String)] = []

    func load() {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? "\(NSHomeDirectory())/.codex"
        let url = URL(fileURLWithPath: "\(home)/models_cache.json")
        struct Cache: Decodable {
            struct Model: Decodable {
                let slug: String
                let display_name: String?
                let visibility: String?
            }
            let models: [Model]
        }
        guard let data = try? Data(contentsOf: url),
            let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else {
            models = []
            return
        }
        models =
            cache.models
            .filter { $0.visibility == "list" }
            .map { (slug: $0.slug, name: $0.display_name ?? $0.slug) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.light.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentColor = AppAccent.system.rawValue
    @AppStorage(SettingsKeys.contactEmail) private var contactEmail = ""

    @FocusState private var emailFocused: Bool
    @State private var accentNeedsRelaunch = false

    private var isEmailValid: Bool {
        let pattern = #/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/#.ignoresCase()
        return contactEmail.wholeMatch(of: pattern) != nil
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent") {
                    AccentColorPicker(selection: $accentColor)
                }
                if accentNeedsRelaunch {
                    HStack {
                        Text("Relaunch Refman to apply the accent.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch") { model.relaunch() }
                            .controlSize(.small)
                    }
                }
            }
            .onChange(of: accentColor) { _, newValue in
                (AppAccent(rawValue: newValue) ?? .system).applyToDefaults()
                accentNeedsRelaunch = true
            }

            LibrarySettingsSection()

            ICloudSettingsSection()

            UpdatesSettingsSection(updater: model.updater)

            Section("Metadata & Downloads") {
                TextField(
                    "Contact email", text: $contactEmail,
                    prompt: Text("you@example.com"))
                    .focused($emailFocused)
                if !contactEmail.isEmpty && !isEmailValid {
                    Text("Enter a valid email address.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(
                    "Used to fetch open-access PDFs (Unpaywall) and for polite API "
                        + "access to CrossRef. Required for DOI PDF downloads."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .contentShape(Rectangle())
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                emailFocused = false
            }
        }
        .onTapGesture { emailFocused = false }
        .frame(width: 480, height: 600)
        .background {
            // Esc closes the Settings window.
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

}

/// A row of accent swatches; the selected one shows a ring.
struct AccentColorPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppAccent.allCases.filter { $0 != .system }) { accent in
                Circle()
                    .fill(accent.color)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .strokeBorder(.primary, lineWidth: 2)
                            .padding(-3)
                            .opacity(selection == accent.rawValue ? 1 : 0)
                    }
                    .contentShape(Circle())
                    .onTapGesture { selection = accent.rawValue }
                    .help(accent.label)
            }
        }
    }
}

/// Library stats, backup/restore, and integrity check.
struct LibrarySettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var stats: LibraryStats?
    @State private var report: IntegrityReport?
    @State private var showingReport = false
    @State private var confirmRestore: URL?

    var body: some View {
        Section("Library") {
            if let stats {
                LabeledContent("Documents", value: "\(stats.documents)")
                LabeledContent("With PDF", value: "\(stats.withPDF)")
                LabeledContent("In Trash", value: "\(stats.trashed)")
                LabeledContent(
                    "Storage",
                    value: ByteCountFormatter.string(
                        fromByteCount: stats.sizeBytes, countStyle: .file))
            }
            HStack {
                Button("Back Up…", action: backUp)
                Button("Restore…", action: chooseRestore)
                Spacer()
                Button("Check Integrity", action: checkIntegrity)
            }
            .buttonStyle(.bordered)
        }
        .onAppear { stats = model.libraryStats() }
        .alert("Library Integrity", isPresented: $showingReport, presenting: report) { report in
            if !report.orphanHashes.isEmpty {
                Button("Remove \(report.orphanHashes.count) Orphaned File\(report.orphanHashes.count == 1 ? "" : "s")") {
                    model.removeOrphanFiles(report.orphanHashes)
                    stats = model.libraryStats()
                }
            }
            Button("OK", role: .cancel) {}
        } message: { report in
            if report.isClean {
                Text("No problems found.")
            } else {
                Text(
                    "\(report.missing.count) document(s) missing their PDF, "
                        + "\(report.orphanHashes.count) orphaned file(s) on disk.")
            }
        }
        .alert(
            "Restore from Backup?",
            isPresented: Binding(
                get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })
        ) {
            Button("Restore", role: .destructive) {
                if let url = confirmRestore { model.restore(from: url) }
                confirmRestore = nil
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("This replaces your current library. Quit and reopen Refman afterward.")
        }
    }

    private func backUp() {
        model.backupViaPanel()
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmRestore = url
    }

    private func checkIntegrity() {
        report = model.runIntegrityCheck()
        showingReport = report != nil
    }
}

/// App version and the GitHub-backed update check.
struct UpdatesSettingsSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: Updater.currentVersion)
            HStack {
                Button("Check for Updates") { updater.check(userInitiated: true) }
                    .disabled(updater.status.isBusy)
                if let detail = statusDetail { Text(detail).foregroundStyle(.secondary) }
                Spacer()
                if case .available = updater.status {
                    Button("Install") { updater.installPending() }
                }
            }
            switch updater.status {
            case .downloading(let fraction):
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
            case .unpacking:
                ProgressView().controlSize(.small)
            default:
                EmptyView()
            }
            Text("Checks GitHub Releases and installs the latest version, then relaunches.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusDetail: String? {
        switch updater.status {
        case .idle: return nil
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let version): return "\(version) available"
        case .downloading(let fraction):
            guard let fraction else { return "Downloading…" }
            return "Downloading… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .unpacking: return "Installing…"
        case .failed(let message): return message
        }
    }
}

/// Borderless icon button that reveals a URL in Finder.
struct RevealInFinderButton: View {
    let url: URL
    let tooltip: String

    var body: some View {
        Button("Reveal in Finder", systemImage: "arrow.up.forward.app") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(tooltip)
    }
}

/// Library location and iCloud Drive sync.
struct ICloudSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmMove: MoveTarget?

    enum MoveTarget { case iCloud, local }

    var body: some View {
        Section("iCloud Sync") {
            if model.isInICloudDrive {
                HStack {
                    Label("Syncing via iCloud Drive", systemImage: "checkmark.icloud")
                        .foregroundStyle(.green)
                    Spacer()
                    RevealInFinderButton(url: model.libraryRootURL, tooltip: model.libraryLocationDisplay)
                }
                Button("Move Back to This Mac…") { confirmMove = .local }
            } else {
                HStack {
                    Label("Stored on this Mac", systemImage: "internaldrive")
                        .foregroundStyle(.secondary)
                    Spacer()
                    RevealInFinderButton(url: model.libraryRootURL, tooltip: model.libraryLocationDisplay)
                }
                Button("Move to iCloud Drive…") { confirmMove = .iCloud }
                    .disabled(!model.iCloudDriveAvailable)
                if !model.iCloudDriveAvailable {
                    Text("iCloud Drive isn't enabled on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(
                "Keep Refman open on only one Mac at a time. iCloud Drive syncs files "
                    + "but can't merge simultaneous edits to the library database."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .alert(
            "Move Library?",
            isPresented: Binding(
                get: { confirmMove != nil }, set: { if !$0 { confirmMove = nil } })
        ) {
            Button("Move & Restart", role: .destructive) {
                switch confirmMove {
                case .iCloud: Task { await model.moveLibraryToICloudDrive() }
                case .local: Task { await model.moveLibraryToLocal() }
                case nil: break
                }
                confirmMove = nil
            }
            Button("Cancel", role: .cancel) { confirmMove = nil }
        } message: {
            Text(
                "Your library (database and PDFs) will be moved, then Refman will "
                    + "restart to use the new location.")
        }
    }
}

struct AssistantProviderPicker: View {
    @Binding var selection: String

    var label = "Provider"
    var compact = false

    var body: some View {
        Picker(label, selection: $selection) {
            Text(compact ? "Ollama" : "Local (Ollama)").tag("ollama")
            Text("OpenAI").tag("openai")
            Text("Claude").tag("claude")
        }
        .pickerStyle(.segmented)
    }
}

struct AgentPicker: View {
    @AppStorage(SettingsKeys.agentPath) private var agentPath = ""

    var stackAlignment: HorizontalAlignment = .leading
    var pathAlignment: Alignment = .leading
    var pathMaxWidth: CGFloat? = nil
    var controlSize: ControlSize = .regular

    var body: some View {
        VStack(alignment: stackAlignment, spacing: 4) {
            Text(agentPath.isEmpty ? "Bundled refman-agent" : agentPath)
                .font(.callout)
                .foregroundStyle(agentPath.isEmpty ? .secondary : .primary)
                .truncationMode(.middle)
                .lineLimit(1)
                .frame(maxWidth: pathMaxWidth, alignment: pathAlignment)
            HStack(spacing: 6) {
                Button {
                    chooseAgent()
                } label: {
                    Label("Choose…", systemImage: "folder")
                }
                if !agentPath.isEmpty {
                    Button {
                        agentPath = ""
                    } label: {
                        Label("Use Bundled", systemImage: "shippingbox")
                    }
                }
            }
            .controlSize(controlSize)
        }
    }

    private func chooseAgent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose an ACP-compatible agent executable"
        if panel.runModal() == .OK, let url = panel.url {
            agentPath = url.path
        }
    }
}
