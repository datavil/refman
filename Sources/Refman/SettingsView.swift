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

enum SettingsKeys {
    static let appearance = "appearance"
    static let agentPath = "agentPath"
    static let llmProvider = "llmProvider"  // "ollama" | "openai" | "claude"
    static let ollamaModel = "ollamaModel"
    static let claudeModel = "claudeModel"
    static let openaiModel = "openaiModel"
    static let highlightPalette = "highlightPalette"
    static let highlightOpacity = "highlightOpacity"
    static let citationStyle = "citationStyle"
    static let contactEmail = "contactEmail"
    static let libraryRootPath = "libraryRootPath"
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
    @AppStorage(SettingsKeys.agentPath) private var agentPath = ""
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = "ollama"
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = ""
    @AppStorage(SettingsKeys.openaiModel) private var openaiModel = ""
    @AppStorage(SettingsKeys.contactEmail) private var contactEmail = ""

    @StateObject private var modelList = OllamaModelList()
    @StateObject private var codexList = CodexModelList()
    @StateObject private var providerSetup = ProviderSetupModel()
    @FocusState private var emailFocused: Bool

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            LibrarySettingsSection()

            ICloudSettingsSection()

            UpdatesSettingsSection(updater: model.updater)

            Section("Metadata & Downloads") {
                TextField(
                    "Contact email", text: $contactEmail,
                    prompt: Text("you@example.com"))
                    .focused($emailFocused)
                Text(
                    "Used to fetch open-access PDFs (Unpaywall) and for polite API "
                        + "access to CrossRef. Required for DOI PDF downloads."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Assistant Agent") {
                LabeledContent("Agent") {
                    AgentPicker(
                        stackAlignment: .trailing,
                        pathAlignment: .trailing,
                        pathMaxWidth: 280)
                }
                Text(
                    "Any executable speaking the Agent Client Protocol on stdio works here. "
                        + "The bundled refman-agent bridges to a local Ollama."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Provider and model choice only apply to the bundled agent.
            if agentPath.isEmpty {
                Section("Model Provider") {
                    AssistantProviderPicker(selection: $llmProvider)
                }

                if llmProvider == "claude" {
                    Section("Claude") {
                        ProviderSetupView(provider: .claude, setup: providerSetup)
                        Picker("Model", selection: $claudeModel) {
                            Text("Default").tag("")
                            Text("Sonnet").tag("sonnet")
                            Text("Opus").tag("opus")
                            Text("Haiku").tag("haiku")
                        }
                        Text(
                            "Uses the Claude Code CLI signed in with your Claude "
                                + "subscription — no API key, no per-token billing."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else if llmProvider == "openai" {
                    Section("OpenAI (Codex)") {
                        ProviderSetupView(provider: .openai, setup: providerSetup)
                        if codexList.models.isEmpty {
                            TextField(
                                "Model", text: $openaiModel,
                                prompt: Text("Codex default"))
                        } else {
                            Picker("Model", selection: $openaiModel) {
                                Text("Default (Codex config)").tag("")
                                ForEach(codexList.models, id: \.slug) { model in
                                    Text(model.name).tag(model.slug)
                                }
                            }
                        }
                        Text(
                            "Uses the Codex CLI signed in with your ChatGPT subscription "
                                + "— no API key, no per-token billing."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Ollama") {
                        ProviderSetupView(provider: .ollama, setup: providerSetup)
                    }
                    Section("Ollama Model") {
                        if modelList.models.isEmpty {
                            TextField(
                                "Model", text: $ollamaModel,
                                prompt: Text("largest installed (auto)"))
                            if modelList.loadFailed {
                                Label(
                                    "Can't reach Ollama — start it above, then Refresh.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        } else {
                            Picker("Model", selection: $ollamaModel) {
                                Text("Largest installed (auto)").tag("")
                                ForEach(modelList.models, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Text("Agent executable changes apply to newly opened assistant panels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .contentShape(Rectangle())
        .onTapGesture { emailFocused = false }
        .frame(width: 480, height: 600)
        .onAppear {
            modelList.load()
            codexList.load()
            providerSetup.refresh()
        }
        .background {
            // Esc closes the Settings window.
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
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
                    .disabled(updater.status == .checking || updater.status == .downloading)
                if let detail = statusDetail { Text(detail).foregroundStyle(.secondary) }
                Spacer()
                if case .available = updater.status {
                    Button("Install") { updater.installPending() }
                }
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
        case .downloading: return "Downloading…"
        case .failed(let message): return message
        }
    }
}

/// Library location and iCloud Drive sync.
struct ICloudSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmMove: MoveTarget?

    enum MoveTarget { case iCloud, local }

    var body: some View {
        Section("iCloud Sync") {
            LabeledContent("Location", value: model.libraryLocationDisplay)
            if model.isInICloudDrive {
                Label("Syncing via iCloud Drive", systemImage: "checkmark.icloud")
                    .foregroundStyle(.green)
                Button("Move Back to This Mac…") { confirmMove = .local }
            } else {
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
            Button("Move", role: .destructive) {
                switch confirmMove {
                case .iCloud: model.moveLibraryToICloudDrive()
                case .local: model.moveLibraryToLocal()
                case nil: break
                }
                confirmMove = nil
            }
            Button("Cancel", role: .cancel) { confirmMove = nil }
        } message: {
            Text(
                "Your library (database and PDFs) will be moved. Quit and reopen "
                    + "Refman afterward to use the new location.")
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
