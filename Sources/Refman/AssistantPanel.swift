import Foundation
import RefmanCore
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
    /// When set, the assistant's reply is stored in this insight field.
    var saves: DocumentInsight?
}

/// Built-in prompts behind the quick-action buttons.
enum AssistantPrompts {
    /// Document-level queries shown as chips in the assistant panel.
    static let document: [AssistantAction] = [
        AssistantAction(
            label: "Summarize",
            prompt: """
                Summarize the currently open paper using its full text in 2–4 short paragraphs: \
                the problem, the approach, and the main findings. State the substance directly. \
                Do NOT use narrative framing such as "the paper addresses", "the authors/they \
                developed", "this study shows", "we propose". Write the actual problem, method, \
                and results, not a description of the paper describing them. Be concise and \
                avoid filler.
                """,
            saves: .summary),
        AssistantAction(
            label: "Key points",
            prompt: """
                List the key points and main contributions of the currently open paper as 5–8 \
                concise bullet points, based on its full text. State each point directly as a \
                fact or result. Do NOT use narrative framing such as "the paper", "the \
                authors/they", "this study", "we" — write the substance itself, not a \
                description of the paper.
                """,
            saves: .keyPoints),
        AssistantAction(
            label: "Methods",
            prompt: """
                Explain the methods and experimental setup of the currently open paper, based \
                on its full text. State the substance directly, without narrative framing like \
                "the paper" or "the authors". Be specific and concise.
                """,
            saves: .methods),
        AssistantAction(
            label: "Limitations",
            prompt: """
                Identify the main limitations, assumptions, and open questions of the currently \
                open paper, based on its full text. State each directly, without narrative \
                framing like "the paper" or "the authors". Be concise.
                """,
            saves: .limitations),
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

/// Collects streamed chunks from the agent's reading thread, safely.
final class ChunkAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock()
        buffer += chunk
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
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

    /// The provider the live client is bound to, and the stashed conversation
    /// for every other provider — so switching agents never loses a chat.
    private var provider = AssistantModel.currentProvider()
    private var conversations: [String: [ChatMessage]] = [:]

    /// Called after a generated insight is stored, so the UI can refresh.
    var onInsightSaved: (() -> Void)?

    init(documentId: Int64, repository: LibraryRepository) {
        self.documentId = documentId
        self.repository = repository
    }

    private static func currentProvider() -> String {
        UserDefaults.standard.string(forKey: SettingsKeys.llmProvider) ?? "ollama"
    }

    /// Agent from Settings, falling back to the bundled refman-agent
    /// (which sits next to the Refman binary — both built by SPM).
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
        } else if provider == "openai" {
            let model = defaults.string(forKey: SettingsKeys.openaiModel) ?? ""
            if !model.isEmpty { environment["REFMAN_OPENAI_MODEL"] = model }
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
                // Greet only on a fresh conversation, not when restoring one.
                if messages.isEmpty {
                    messages.append(
                        ChatMessage(
                            role: .assistant,
                            text: "Hi! Ask me about this paper or your library. I can search, read full text, and see your annotations."
                        ))
                }
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
                } else if provider == "openai" {
                    hint =
                        "Make sure the Codex CLI is installed and signed in (run `codex login` in Terminal)."
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
        submit(display: action.label, prompt: action.prompt, saves: action.saves)
    }

    /// Posts `display` as the outgoing message while sending `prompt` to the agent.
    /// When `saves` is set, the completed reply is stored in that insight field.
    private func submit(display: String, prompt: String, saves: DocumentInsight? = nil) {
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
                if let saves {
                    let text = messages[index].text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        try? repository.setInsight(saves, documentId: documentId, text: text)
                        onInsightSaved?()
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
        started = false
    }

    /// Re-reads the provider/model from Settings and rebinds the agent. When the
    /// provider changes, the current conversation is stashed and the new
    /// provider's stored conversation (if any) is restored, so switching agents
    /// never loses a chat.
    func applySettingsChange() {
        guard !isBusy else { return }
        let newProvider = AssistantModel.currentProvider()
        if newProvider != provider {
            conversations[provider] = messages
            provider = newProvider
            messages = conversations[newProvider] ?? []
        }
        shutdown()
        startIfNeeded()
    }

    /// Clears the current agent's chat and resets its session.
    func clearChat() {
        guard !isBusy else { return }
        messages = []
        conversations[provider] = []
        shutdown()
        startIfNeeded()
    }

    /// Runs one prompt against the document headlessly (no chat UI) and returns
    /// the generated text. Used by the library's AI insight commands.
    static func generateText(prompt: String, documentId: Int64, repository: LibraryRepository)
        async throws -> String
    {
        var environment = agentEnvironment
        environment["REFMAN_DOCUMENT_ID"] = String(documentId)
        if let dbPath = repository.database.path {
            environment["REFMAN_DB_PATH"] = dbPath
        }
        let client = ACPClient(agentURL: agentURL, environment: environment) { name, arguments in
            try await handleTool(
                name: name, arguments: arguments,
                repository: repository, currentDocumentId: documentId)
        }
        defer { client.stop() }
        try await client.start()

        let accumulator = ChunkAccumulator()
        _ = try await client.prompt(prompt) { accumulator.append($0) }
        return accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    @State private var showClearConfirm = false
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = "ollama"
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = ""
    @AppStorage(SettingsKeys.openaiModel) private var openaiModel = ""

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
                HStack {
                    Label("AI", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Button {
                        showClearConfirm = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear this agent's chat")
                    .disabled(
                        (assistant.model?.messages.isEmpty ?? true)
                            || (assistant.model?.isBusy ?? true))
                    .confirmationDialog(
                        "Clear this chat?", isPresented: $showClearConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Chat", role: .destructive) {
                            assistant.model?.clearChat()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently removes the current agent's conversation.")
                    }
                }
                AssistantProviderPicker(selection: $llmProvider, label: "Agent", compact: true)
                    .controlSize(.small)
                    .disabled(assistant.model?.isBusy ?? false)
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
                assistant.model?.onInsightSaved = { [weak model] in model?.reload() }
                assistant.bind()
            }
            assistant.model?.startIfNeeded()
            consumePendingAction()
        }
        .onChange(of: pendingAction?.id) {
            consumePendingAction()
        }
        .onChange(of: llmProvider) {
            assistant.model?.applySettingsChange()
        }
        .onChange(of: ollamaModel) {
            assistant.model?.applySettingsChange()
        }
        .onChange(of: claudeModel) {
            assistant.model?.applySettingsChange()
        }
        .onChange(of: openaiModel) {
            assistant.model?.applySettingsChange()
        }
        .onDisappear {
            assistant.model?.shutdown()
        }
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
            content
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background)
                )
            if message.role != .user { Spacer(minLength: 30) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.text.isEmpty {
            // Placeholder until the agent starts streaming a reply.
            ProgressView().controlSize(.small)
        } else if message.role == .error {
            Text(message.text).textSelection(.enabled)
        } else {
            MarkdownText(text: message.text).textSelection(.enabled)
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

/// Renders a useful subset of Markdown (headings, bullet/numbered lists, fenced
/// code, and inline emphasis). SwiftUI's `Text` only handles inline Markdown, so
/// block-level constructs are split out here and styled per block.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(marker: String, text: String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                row(for: block)
            }
        }
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit()
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }

    /// Parses inline Markdown (bold, italic, code, links) for one block.
    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: toggle on ``` and capture lines verbatim.
            if trimmed.hasPrefix("```") {
                if code == nil {
                    flushParagraph()
                    code = []
                } else {
                    blocks.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.0, text: heading.1))
            } else if let bullet = bullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(bullet))
            } else if let numbered = numbered(trimmed) {
                flushParagraph()
                blocks.append(.numbered(marker: numbered.0, text: numbered.1))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ s: String) -> (Int, String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1
            idx = s.index(after: idx)
        }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(2))
        }
        return nil
    }

    private static func numbered(_ s: String) -> (String, String)? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        var rest = s[digits.endIndex...]
        guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return ("\(digits).", String(rest.dropFirst()))
    }
}
