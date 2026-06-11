import Foundation
import RefManCore
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }
    let id = UUID()
    var role: Role
    var text: String
}

/// Drives one ACP session against refman-agent, exposing library tools.
@MainActor
final class AssistantModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isBusy = false
    @Published var started = false

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

    /// Model override for the bundled Ollama bridge, from Settings.
    private static var agentEnvironment: [String: String] {
        let model = UserDefaults.standard.string(forKey: SettingsKeys.ollamaModel) ?? ""
        return model.isEmpty ? [:] : ["REFMAN_OLLAMA_MODEL": model]
    }

    func startIfNeeded() {
        guard client == nil else { return }
        let repository = self.repository
        let documentId = self.documentId
        let client = ACPClient(
            agentURL: Self.agentURL,
            environment: Self.agentEnvironment
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
                messages.append(
                    ChatMessage(
                        role: .error,
                        text: "Could not start agent: \(error.localizedDescription)\n\nMake sure Ollama is running (`ollama serve`) and a model is pulled (`ollama pull llama3.2`)."
                    ))
            }
            isBusy = false
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client, !isBusy else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isBusy = true

        Task {
            do {
                try await client.prompt(text) { chunk in
                    Task { @MainActor in
                        self.messages[index].text += chunk
                    }
                }
            } catch {
                messages[index].role = .error
                messages[index].text = "Error: \(error.localizedDescription)"
            }
            isBusy = false
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
        func targetId() -> Int64 {
            (arguments["document_id"] as? NSNumber)?.int64Value ?? currentDocumentId
        }

        switch name {
        case "get_current_document":
            guard let details = try repository.document(id: currentDocumentId) else {
                return "No document is open."
            }
            return describe(details)

        case "get_document_text":
            let id = targetId()
            guard let text = try repository.fullText(documentId: id), !text.isEmpty else {
                return "No extracted text for document \(id)."
            }
            // Keep context manageable for small local models.
            return String(text.prefix(24_000))

        case "search_library":
            let query = arguments["query"] as? String ?? ""
            let results = try repository.search(query)
            guard !results.isEmpty else { return "No matches for ‘\(query)’." }
            return results.prefix(10).map(describe).joined(separator: "\n---\n")

        case "get_annotations":
            let id = targetId()
            let annotations = try repository.annotations(documentId: id)
            guard !annotations.isEmpty else { return "No annotations on document \(id)." }
            return annotations.map { a in
                var line = "p.\(a.pageIndex + 1) [\(a.kind.rawValue)]"
                if let t = a.selectedText, !t.isEmpty { line += " “\(t)”" }
                if let n = a.noteText, !n.isEmpty { line += " — note: \(n)" }
                return line
            }.joined(separator: "\n")

        case "add_tag":
            guard let tagName = arguments["name"] as? String, !tagName.isEmpty else {
                return "Missing tag name."
            }
            let id = targetId()
            _ = try repository.addTag(tagName, toDocument: id)
            return "Tagged document \(id) with ‘\(tagName)’."

        default:
            return "Unknown tool: \(name)"
        }
    }

    nonisolated private static func describe(_ details: DocumentDetails) -> String {
        let d = details.document
        var lines = ["id: \(d.id ?? -1)", "title: \(d.title)"]
        if !details.authorsText.isEmpty { lines.append("authors: \(details.authorsText)") }
        if let year = d.year { lines.append("year: \(year)") }
        if let venue = d.venue { lines.append("venue: \(venue)") }
        if let doi = d.doi { lines.append("doi: \(doi)") }
        if let abstract = d.abstract { lines.append("abstract: \(abstract.prefix(600))") }
        return lines.joined(separator: "\n")
    }
}

struct AssistantPanel: View {
    @EnvironmentObject var model: AppModel
    let documentId: Int64
    /// Pre-fills the input (e.g. “Ask AI” on a PDF selection); consumed once.
    @Binding var pendingQuestion: String?

    @StateObject private var assistant: AssistantModelBox = AssistantModelBox()

    init(documentId: Int64, pendingQuestion: Binding<String?> = .constant(nil)) {
        self.documentId = documentId
        self._pendingQuestion = pendingQuestion
    }

    var body: some View {
        VStack(spacing: 0) {
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
            HStack {
                TextField(
                    "Ask about this paper…",
                    text: Binding(
                        get: { assistant.model?.input ?? "" },
                        set: { assistant.model?.input = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { assistant.model?.send() }
                if assistant.model?.isBusy == true {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        assistant.model?.send()
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
            consumePendingQuestion()
        }
        .onChange(of: pendingQuestion) { consumePendingQuestion() }
        .onDisappear {
            assistant.model?.shutdown()
        }
    }

    private func consumePendingQuestion() {
        guard let question = pendingQuestion, let assistantModel = assistant.model else { return }
        assistantModel.input = question
        pendingQuestion = nil
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
