import Foundation
import RefManCore
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }
    let id = UUID()
    var role: Role
    var text: String
}

/// A one-tap assistant action: a short user-facing `label` and the full
/// instruction (`prompt`) that is sent to the model but kept out of sight.
struct AssistantAction: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let prompt: String
}

/// Built-in prompts behind the quick-action buttons.
enum AssistantPrompts {
    /// Document-level queries shown as chips in the assistant panel.
    static let document: [AssistantAction] = [
        AssistantAction(
            label: "Summarize",
            prompt: """
                Summarize the currently open paper using its full text. Cover the problem it \
                addresses, the approach taken, and the main findings in 2–4 short paragraphs. \
                Be concise and avoid filler.
                """),
        AssistantAction(
            label: "Key points",
            prompt: """
                List the key points and main contributions of the currently open paper as 5–8 \
                concise bullet points, based on its full text.
                """),
        AssistantAction(
            label: "Methods",
            prompt: """
                Explain the methods and experimental setup of the currently open paper, based \
                on its full text. Be specific and concise.
                """),
        AssistantAction(
            label: "Limitations",
            prompt: """
                Identify the main limitations, assumptions, and open questions of the currently \
                open paper, based on its full text. Be concise.
                """),
    ]

    static func summarize(_ passage: String) -> AssistantAction {
        AssistantAction(
            label: "Summarize: \(snippet(passage))",
            prompt: """
                Summarize the following passage from the currently open paper in 1–3 sentences, \
                preserving its key meaning:

                “\(passage)”
                """)
    }

    static func explain(_ passage: String) -> AssistantAction {
        AssistantAction(
            label: "Explain: \(snippet(passage))",
            prompt: """
                Explain the following passage from the currently open paper in clear, simple \
                terms. Define any jargon and add brief context from the paper where helpful:

                “\(passage)”
                """)
    }

    private static func snippet(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 70 ? String(flat.prefix(70)) + "…" : flat
    }
}

/// Drives one ACP session against refman-agent, exposing library tools.
@MainActor
final class AssistantModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isBusy = false
    @Published var started = false

    /// A built-in action waiting for the agent to become ready.
    private var queued: AssistantAction?
    private var client: ACPClient?
    private let documentId: Int64
    private let repository: LibraryRepository

    init(documentId: Int64, repository: LibraryRepository) {
        self.documentId = documentId
        self.repository = repository
    }

    /// Agent from Settings, falling back to the bundled refman-agent
    /// (which sits next to the RefMan binary — both built by SPM).
    private static var agentURL: URL {
        let custom = UserDefaults.standard.string(forKey: SettingsKeys.agentPath) ?? ""
        if !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("refman-agent")
    }

    /// Provider and model overrides for the bundled agent, from Settings.
    private static var agentEnvironment: [String: String] {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: SettingsKeys.llmProvider) ?? "ollama"
        var environment = ["REFMAN_BACKEND": provider]
        if provider == "claude" {
            let model = defaults.string(forKey: SettingsKeys.claudeModel) ?? ""
            if !model.isEmpty { environment["REFMAN_CLAUDE_MODEL"] = model }
        } else {
            let model = defaults.string(forKey: SettingsKeys.ollamaModel) ?? ""
            if !model.isEmpty { environment["REFMAN_OLLAMA_MODEL"] = model }
        }
        return environment
    }

    func startIfNeeded() {
        guard client == nil else { return }
        let repository = self.repository
        let documentId = self.documentId
        // The Claude backend's MCP server opens the library directly.
        var environment = Self.agentEnvironment
        environment["REFMAN_DOCUMENT_ID"] = String(documentId)
        if let dbPath = repository.database.path {
            environment["REFMAN_DB_PATH"] = dbPath
        }
        let client = ACPClient(
            agentURL: Self.agentURL,
            environment: environment
        ) { name, arguments in
            try await Self.handleTool(
                name: name, arguments: arguments,
                repository: repository, currentDocumentId: documentId)
        }
        self.client = client
        isBusy = true
        Task {
            do {
                try await client.start()
                started = true
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: "Hi! Ask me about this paper or your library. I can search, read full text, and see your annotations."
                    ))
            } catch {
                let customAgentPath = UserDefaults.standard.string(forKey: SettingsKeys.agentPath) ?? ""
                let provider = UserDefaults.standard.string(forKey: SettingsKeys.llmProvider) ?? "ollama"
                let hint: String
                if !customAgentPath.isEmpty {
                    hint =
                        "Choose an executable ACP-compatible agent, or switch back to the bundled refman-agent."
                } else if provider == "claude" {
                    hint =
                        "Make sure the Claude Code CLI is installed and logged in (run `claude` in Terminal)."
                } else {
                    hint =
                        "Make sure Ollama is running (`ollama serve`) and a model is pulled (`ollama pull llama3.2`)."
                }
                messages.append(
                    ChatMessage(
                        role: .error,
                        text: "Could not start agent: \(error.localizedDescription)\n\n\(hint)"
                    ))
            }
            isBusy = false
            flushQueue()
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, client != nil, !isBusy else { return }
        input = ""
        submit(display: text, prompt: text)
    }

    /// Runs a built-in action, queueing it until the agent is ready.
    func enqueue(_ action: AssistantAction) {
        queued = action
        flushQueue()
    }

    private func flushQueue() {
        guard let action = queued, started, client != nil, !isBusy else { return }
        queued = nil
        submit(display: action.label, prompt: action.prompt)
    }

    /// Posts `display` as the outgoing message while sending `prompt` to the agent.
    private func submit(display: String, prompt: String) {
        guard let client, !isBusy else { return }
        messages.append(ChatMessage(role: .user, text: display))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isBusy = true

        Task {
            do {
                try await client.prompt(prompt) { chunk in
                    Task { @MainActor in
                        self.messages[index].text += chunk
                    }
                }
            } catch {
                messages[index].role = .error
                messages[index].text = "Error: \(error.localizedDescription)"
            }
            isBusy = false
            flushQueue()
        }
    }

    func shutdown() {
        client?.stop()
        client = nil
    }

    // MARK: - Library tools (called by the agent via refman/toolCall)

    nonisolated static func handleTool(
        name: String, arguments: [String: Any],
        repository: LibraryRepository, currentDocumentId: Int64
    ) async throws -> String {
        // Keep context manageable for small local models.
        try LibraryTools.handle(
            name: name, arguments: arguments,
            repository: repository, currentDocumentId: currentDocumentId,
            textLimit: 24_000)
    }
}

struct AssistantPanel: View {
    @EnvironmentObject var model: AppModel
    let documentId: Int64
    /// Passage quoted via “Ask AI” on a PDF selection; shown above the input
    /// and prepended to the next message.
    @Binding var pendingQuote: String?
    /// Built-in action triggered from a note in the sidebar; auto-sent on arrival.
    @Binding var pendingAction: AssistantAction?

    @StateObject private var assistant: AssistantModelBox = AssistantModelBox()
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = "ollama"
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = ""

    init(
        documentId: Int64,
        pendingQuote: Binding<String?> = .constant(nil),
        pendingAction: Binding<AssistantAction?> = .constant(nil)
    ) {
        self.documentId = documentId
        self._pendingQuote = pendingQuote
        self._pendingAction = pendingAction
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("AI", systemImage: "sparkles")
                    .font(.headline)
                AssistantProviderPicker(selection: $llmProvider, label: "Agent", compact: true)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(assistant.model?.messages ?? []) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: assistant.model?.messages.last?.text) {
                    if let last = assistant.model?.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AssistantPrompts.document) { action in
                        Button(action.label) {
                            assistant.model?.enqueue(action)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .disabled(assistant.model?.isBusy ?? true)
            if let quote = pendingQuote {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.secondary)
                    Text(quote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        pendingQuote = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove quote")
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            HStack {
                TextField(
                    pendingQuote == nil ? "Ask about this paper…" : "Ask about this passage…",
                    text: Binding(
                        get: { assistant.model?.input ?? "" },
                        set: { assistant.model?.input = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { sendMessage() }
                if assistant.model?.isBusy == true {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .onAppear {
            if assistant.model == nil {
                assistant.model = AssistantModel(
                    documentId: documentId, repository: model.repository)
                assistant.bind()
            }
            assistant.model?.startIfNeeded()
            consumePendingAction()
        }
        .onChange(of: pendingAction?.id) {
            consumePendingAction()
        }
        .onChange(of: llmProvider) {
            restartAssistant()
        }
        .onChange(of: ollamaModel) {
            restartAssistant()
        }
        .onChange(of: claudeModel) {
            restartAssistant()
        }
        .onDisappear {
            assistant.model?.shutdown()
        }
    }

    private func restartAssistant() {
        assistant.model?.shutdown()
        assistant.model = AssistantModel(
            documentId: documentId, repository: model.repository)
        assistant.model?.startIfNeeded()
    }

    /// Hands a sidebar-triggered action to the model, then clears it.
    private func consumePendingAction() {
        guard let action = pendingAction, let model = assistant.model else { return }
        pendingAction = nil
        model.enqueue(action)
    }

    /// Folds the quoted passage (if any) into the outgoing message.
    private func sendMessage() {
        guard let assistantModel = assistant.model, !assistantModel.isBusy else { return }
        if let quote = pendingQuote {
            let typed = assistantModel.input.trimmingCharacters(in: .whitespacesAndNewlines)
            let ask = typed.isEmpty ? "Explain this passage." : typed
            assistantModel.input =
                "In the currently open paper, regarding this passage:\n\n“\(quote)”\n\n\(ask)"
            pendingQuote = nil
        }
        assistantModel.send()
    }
}

/// Holds the AssistantModel (created lazily once we have the environment).
@MainActor
final class AssistantModelBox: ObservableObject {
    var model: AssistantModel? {
        didSet { bind() }
    }
    private var cancellable: Any?

    func bind() {
        guard let model else { return }
        cancellable = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

import Combine

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 30) }
            Text(LocalizedStringKey(message.text.isEmpty ? "…" : message.text))
                .textSelection(.enabled)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background)
                )
            if message.role != .user { Spacer(minLength: 30) }
        }
    }

    private var background: AnyShapeStyle {
        switch message.role {
        case .user: return AnyShapeStyle(.blue.opacity(0.18))
        case .assistant: return AnyShapeStyle(.quaternary)
        case .error: return AnyShapeStyle(.red.opacity(0.15))
        }
    }
}
