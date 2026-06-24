import AppKit
import SwiftUI

/// Assistant-related settings, shown in their own window opened from the sidebar.
/// The agent executable, model provider, and per-provider model choice live here.
struct AISettingsView: View {
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.light.rawValue
    @AppStorage(SettingsKeys.agentPath) private var agentPath = ""
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = "ollama"
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = ""
    @AppStorage(SettingsKeys.openaiModel) private var openaiModel = ""

    @StateObject private var modelList = OllamaModelList()
    @StateObject private var codexList = CodexModelList()
    @StateObject private var providerSetup = ProviderSetupModel()

    var body: some View {
        Form {
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
        .frame(width: 480, height: 600)
        .onAppear {
            modelList.load()
            codexList.load()
            providerSetup.refresh()
        }
        .background {
            // Esc closes the window.
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }
}
