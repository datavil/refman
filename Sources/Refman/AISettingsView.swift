import AppKit
import RefmanCore
import SwiftUI

/// Assistant-related settings, shown in their own window opened from the sidebar.
/// Split into a tab for the model provider/agent and one for the preset prompts.
struct AISettingsView: View {
    var body: some View {
        // `Tab` (macOS 15+) is unavailable at this deployment target (macOS 14),
        // so the older `tabItem()` API is used here.
        TabView {
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "cpu") }
            PromptsSettingsView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
        }
        .frame(width: 480, height: 600)
        .background {
            // Esc closes the window.
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }
}

/// The agent executable, model provider, and per-provider model choice.
struct ModelsSettingsView: View {
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.light.rawValue
    @AppStorage(SettingsKeys.agentPath) private var agentPath = ""
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = "ollama"
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = ""
    @AppStorage(SettingsKeys.openaiModel) private var openaiModel = ""

    @StateObject private var modelList = OllamaModelList()
    @StateObject private var codexList = CodexModelList()
    @StateObject private var providerSetup = ProviderSetupModel()

    @State private var showAdvanced = false

    /// A curated local model offered for one-click install.
    private let suggestedModel = "gemma4:12b-mlx"

    var body: some View {
        Form {
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
                                    Text(name == suggestedModel ? "\(name) (suggested)" : name)
                                        .tag(name)
                                }
                            }
                        }
                        if !modelList.models.contains(suggestedModel) {
                            SuggestedModelRow(name: suggestedModel, setup: providerSetup) {
                                modelList.load()
                                ollamaModel = suggestedModel
                            }
                        }
                    }
                }
            }

            Section {
                Toggle("Use a custom agent", isOn: $showAdvanced)
            }

            if showAdvanced {
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

                Section {
                    Text("Agent executable changes apply to newly opened assistant panels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !agentPath.isEmpty { showAdvanced = true }
            modelList.load()
            codexList.load()
            providerSetup.refresh()
        }
    }
}

/// One editable preset prompt: its override key, section title, and default text.
private struct PromptEntry: Identifiable {
    let key: String
    let label: String
    let defaultText: String
    var id: String { key }
}

/// Lets the user view and edit the built-in prompt behind each AI action — the
/// document insights (Summarize, Key Points, Methods, Limitations) and the
/// collection summary. Edits are held locally and committed on Save. An override
/// matching the default (or blank) is cleared, so untouched prompts keep
/// receiving improved defaults from app updates.
struct PromptsSettingsView: View {
    @State private var drafts: [String: String] = [:]

    private let entries: [PromptEntry] =
        AssistantPrompts.defaultDocument.compactMap { action in
            action.saves.map {
                PromptEntry(key: $0.rawValue, label: action.label, defaultText: action.prompt)
            }
        } + [
            PromptEntry(
                key: AssistantPrompts.collectionSummaryKey,
                label: "Collection Summary",
                defaultText: AssistantPrompts.defaultCollectionSummary)
        ]

    var body: some View {
        Form {
            ForEach(entries) { entry in
                Section(entry.label) {
                    TextEditor(text: binding(for: entry.key))
                        .font(.body)
                        .frame(minHeight: 110)
                    HStack {
                        Spacer()
                        Button("Reset to Default", systemImage: "arrow.uturn.backward") {
                            drafts[entry.key] = entry.defaultText
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((drafts[entry.key] ?? "") == entry.defaultText)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
            .padding()
            .background(.bar)
        }
        .onAppear(perform: load)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { drafts[key] = $0 })
    }

    /// Currently-saved prompt for an entry: the override if any, else the default.
    private func saved(_ entry: PromptEntry) -> String {
        let key = SettingsKeys.promptOverride(forInsight: entry.key)
        let override = UserDefaults.standard.string(forKey: key) ?? ""
        return override.isEmpty ? entry.defaultText : override
    }

    private var isDirty: Bool {
        entries.contains { (drafts[$0.key] ?? "") != saved($0) }
    }

    private func load() {
        for entry in entries {
            drafts[entry.key] = saved(entry)
        }
    }

    private func save() {
        for entry in entries {
            let key = SettingsKeys.promptOverride(forInsight: entry.key)
            let text = (drafts[entry.key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == entry.defaultText {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(text, forKey: key)
            }
        }
        load()  // normalize drafts (trimmed / cleared) so the view is no longer dirty
    }
}

/// A one-click install row for a suggested Ollama model, shown when that model
/// isn't already installed. Runs `ollama pull` and selects it when done.
struct SuggestedModelRow: View {
    let name: String
    @ObservedObject var setup: ProviderSetupModel
    let onInstalled: @MainActor () -> Void

    var body: some View {
        let pulling = setup.pullingModel == name
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested: \(name)")
                    Text("Download this local model to get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !pulling {
                    Button("Install", systemImage: "arrow.down.circle") {
                        setup.pullOllamaModel(name, then: onInstalled)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if pulling {
                if let fraction = setup.pullFraction {
                    ProgressView(value: fraction) {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                if let status = setup.pullStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
