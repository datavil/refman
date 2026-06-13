import AppKit
import SwiftUI

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
    static let llmProvider = "llmProvider"  // "ollama" | "claude"
    static let ollamaModel = "ollamaModel"
    static let claudeModel = "claudeModel"
    static let highlightPalette = "highlightPalette"
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

struct SettingsView: View {
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingsKeys.agentPath) private var agentPath = ""
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = "ollama"
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = ""

    @StateObject private var modelList = OllamaModelList()

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
                        Picker("Model", selection: $claudeModel) {
                            Text("Default").tag("")
                            Text("Sonnet").tag("sonnet")
                            Text("Opus").tag("opus")
                            Text("Haiku").tag("haiku")
                        }
                        Text(
                            "Uses the Claude Code CLI signed in with your Claude "
                                + "subscription — no API key, no per-token billing. Install with "
                                + "`npm install -g @anthropic-ai/claude-code` and run `claude` once to log in."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Ollama Model") {
                        if modelList.models.isEmpty {
                            HStack {
                                TextField(
                                    "Model", text: $ollamaModel,
                                    prompt: Text("largest installed (auto)"))
                                if modelList.loadFailed {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .help("Could not reach Ollama — is `ollama serve` running?")
                                }
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
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { modelList.load() }
    }
}

struct AssistantProviderPicker: View {
    @Binding var selection: String

    var label = "Provider"
    var compact = false

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Local (Ollama)").tag("ollama")
            Text(compact ? "Claude" : "Claude (subscription)").tag("claude")
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
