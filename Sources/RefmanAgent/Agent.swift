import Foundation
import RefManCore

/// refman-agent: an ACP agent that bridges to a local LLM via Ollama, or to
/// Claude via the Claude Code CLI (billed to the user's Claude subscription).
///
/// Speaks ACP (ndjson JSON-RPC on stdio): initialize, session/new,
/// session/prompt with streamed agent_message_chunk updates. When the model
/// requests a tool, the agent forwards it to the client (the RefMan app)
/// as a `refman/toolCall` request — the app owns the library, not the agent.
/// The Claude backend instead injects the open paper's text and annotations
/// into the system prompt up front (no tool round-trips).
///
/// Environment:
///   REFMAN_BACKEND       "ollama" (default) or "claude"
///   REFMAN_OLLAMA_HOST   default http://127.0.0.1:11434
///   REFMAN_OLLAMA_MODEL  default: largest installed model
///   REFMAN_CLAUDE_MODEL  e.g. "sonnet"/"opus"; default: Claude Code's default

let backend = ProcessInfo.processInfo.environment["REFMAN_BACKEND"] ?? "ollama"

let ollamaHost = ProcessInfo.processInfo.environment["REFMAN_OLLAMA_HOST"]
    ?? "http://127.0.0.1:11434"

let systemPrompt = """
    You are RefMan's research assistant, embedded in a reference manager. \
    The user is reading one specific paper — the "currently open paper" — and \
    questions are about THAT paper unless they clearly ask otherwise.

    When the user quotes or asks about a passage, answer it in the context of \
    the currently open paper. Use get_current_document and get_document_text \
    (which default to the open paper) to ground your answer. Do NOT use \
    search_library for this — that tool is only for finding OTHER papers in the \
    library when the user explicitly asks for related or different work. A \
    quoted passage is not a search query.

    Ground every answer in the actual documents; do not invent papers or \
    contents. Be concise.
    """

let toolDefinitions: [[String: Any]] = [
    [
        "type": "function",
        "function": [
            "name": "get_current_document",
            "description": "Metadata of the paper currently open in the reader (title, authors, year, abstract, ids).",
            "parameters": ["type": "object", "properties": [String: Any]()],
        ],
    ],
    [
        "type": "function",
        "function": [
            "name": "get_document_text",
            "description": "Full extracted text of a document's PDF. Omit document_id for the currently open paper.",
            "parameters": [
                "type": "object",
                "properties": ["document_id": ["type": "integer"]],
            ],
        ],
    ],
    [
        "type": "function",
        "function": [
            "name": "search_library",
            "description": "Find OTHER papers in the library by full-text search (titles, authors, abstracts, PDF text). Use only when the user explicitly asks for related or different papers — never to answer questions about the currently open paper or a quoted passage from it.",
            "parameters": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
        ],
    ],
    [
        "type": "function",
        "function": [
            "name": "get_annotations",
            "description": "The user's highlights and notes for a document. Omit document_id for the currently open paper.",
            "parameters": [
                "type": "object",
                "properties": ["document_id": ["type": "integer"]],
            ],
        ],
    ],
    [
        "type": "function",
        "function": [
            "name": "add_tag",
            "description": "Attach a tag to a document. Omit document_id for the currently open paper.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "document_id": ["type": "integer"],
                ],
                "required": ["name"],
            ],
        ],
    ],
]

/// Explicit env override, else the largest model Ollama has installed.
func resolveModel() async -> String {
    if let model = ProcessInfo.processInfo.environment["REFMAN_OLLAMA_MODEL"] {
        return model
    }
    struct Tags: Decodable {
        struct Model: Decodable {
            let name: String
            let size: Int64
        }
        let models: [Model]
    }
    if let url = URL(string: "\(ollamaHost)/api/tags"),
        let (data, _) = try? await URLSession.shared.data(from: url),
        let tags = try? JSONDecoder().decode(Tags.self, from: data),
        let best = tags.models.max(by: { $0.size < $1.size })
    {
        return best.name
    }
    return "llama3.2"
}

// MARK: - Ollama

struct OllamaChunk {
    var content: String
    var toolCalls: [[String: Any]]
    var done: Bool
}

func ollamaChat(
    model: String,
    messages: [[String: Any]],
    onChunk: (OllamaChunk) -> Void
) async throws {
    var request = URLRequest(url: URL(string: "\(ollamaHost)/api/chat")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model,
        "messages": messages,
        "tools": toolDefinitions,
        "stream": true,
    ])

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(
            domain: "refman-agent", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Ollama request failed — is `ollama serve` running and model '\(model)' pulled?"
            ])
    }
    for try await line in bytes.lines {
        guard let data = line.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { continue }
        let message = object["message"] as? [String: Any] ?? [:]
        onChunk(
            OllamaChunk(
                content: message["content"] as? String ?? "",
                toolCalls: message["tool_calls"] as? [[String: Any]] ?? [],
                done: object["done"] as? Bool ?? false
            ))
    }
}

// MARK: - Claude Code backend (subscription-billed, no API key)

let claudeModel = ProcessInfo.processInfo.environment["REFMAN_CLAUDE_MODEL"] ?? ""

/// Locate the Claude Code CLI; GUI-spawned processes get a minimal PATH.
func resolveClaudeBinary() -> String? {
    let home = NSHomeDirectory()
    let candidates = [
        "\(home)/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(home)/.local/bin/claude",
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    // Last resort: ask the user's login shell.
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
    probe.arguments = ["-lc", "command -v claude"]
    let pipe = Pipe()
    probe.standardInput = FileHandle.nullDevice
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    guard (try? probe.run()) != nil else { return nil }
    probe.waitUntilExit()
    let out = String(
        data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? nil : out
}

/// Inline MCP config handing Claude Code the library tools, served by this
/// same binary in `--mcp` mode straight from the database.
func mcpConfigJSON() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard let dbPath = env["REFMAN_DB_PATH"], let docId = env["REFMAN_DOCUMENT_ID"] else {
        return nil
    }
    var exe = CommandLine.arguments[0]
    if !exe.hasPrefix("/") {
        exe = FileManager.default.currentDirectoryPath + "/" + exe
    }
    let config: [String: Any] = [
        "mcpServers": [
            "refman": [
                "command": exe,
                "args": ["--mcp"],
                "env": ["REFMAN_DB_PATH": dbPath, "REFMAN_DOCUMENT_ID": docId],
            ]
        ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// One turn against `claude -p`, streaming text deltas. Returns the Claude
/// session id so the next turn can `--resume` it (each run issues a new id).
/// Mutable parse state for the line reader (mutated only on the readability
/// queue, which is serial, so no extra locking is needed).
final class ClaudeParse {
    var buffer = Data()
    var sessionId: String?
    var resultError: String?
    var streamedText = false
    var finalText = ""
}

func claudeChat(
    binary: String,
    prompt: String,
    systemPrompt: String?,
    resume: String?,
    onText: @escaping (String) -> Void
) async throws -> String? {
    var args = [
        "-p", prompt,
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
    ]
    if let systemPrompt { args += ["--append-system-prompt", systemPrompt] }
    if let resume { args += ["--resume", resume] }
    if !claudeModel.isEmpty { args += ["--model", claudeModel] }
    if let mcpConfig = mcpConfigJSON() {
        args += [
            "--mcp-config", mcpConfig,
            "--strict-mcp-config",
            "--allowedTools", "mcp__refman",
        ]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = args
    // Neutral cwd so Claude Code doesn't pick up some project's context.
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    // Without this, claude inherits the agent's stdin — the ACP pipe from
    // the app — and `-p` blocks forever waiting for EOF on it.
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    if let errPath = ProcessInfo.processInfo.environment["REFMAN_CLAUDE_STDERR"],
        FileManager.default.createFile(atPath: errPath, contents: nil),
        let errHandle = FileHandle(forWritingAtPath: errPath)
    {
        process.standardError = errHandle
    } else {
        process.standardError = FileHandle.nullDevice
    }
    let debugLog = ProcessInfo.processInfo.environment["REFMAN_CLAUDE_DEBUG"].flatMap {
        FileHandle(forWritingAtPath: $0)
    }
    let state = ClaudeParse()

    @Sendable func parse(_ lineData: Data) {
        debugLog?.write(lineData + Data([0x0A]))
        guard let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
        else { return }
        if let id = object["session_id"] as? String { state.sessionId = id }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_delta",
                let delta = event["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String
            {
                state.streamedText = true
                onText(text)
            } else if event["type"] as? String == "content_block_start",
                let block = event["content_block"] as? [String: Any],
                let toolName = block["name"] as? String
            {
                // Same tool marker the Ollama path shows.
                onText("\n*[\(toolName.replacingOccurrences(of: "mcp__refman__", with: ""))]*\n")
            }
        case "assistant":
            // Final text of an assistant turn; the per-token stream above is
            // best-effort, so keep this as the source of truth for a fallback.
            if let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            {
                let text = content
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
                if !text.isEmpty { state.finalText = text }
            }
        case "result":
            if object["is_error"] as? Bool == true {
                state.resultError = object["result"] as? String ?? "Claude returned an error."
            } else if let text = object["result"] as? String, !text.isEmpty {
                state.finalText = text
            }
        default:
            break
        }
    }

    try process.run()

    // Read stdout via a readability handler rather than FileHandle.bytes.lines,
    // which can stall when iterated from the JSON-RPC handler's task.
    let handle = stdout.fileHandleForReading
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {  // EOF: claude closed stdout
                fh.readabilityHandler = nil
                if !state.buffer.isEmpty {
                    parse(state.buffer)
                    state.buffer.removeAll()
                }
                continuation.resume()
                return
            }
            state.buffer.append(chunk)
            while let nl = state.buffer.firstIndex(of: 0x0A) {
                let lineData = state.buffer.subdata(in: state.buffer.startIndex..<nl)
                state.buffer.removeSubrange(state.buffer.startIndex...nl)
                if !lineData.isEmpty { parse(lineData) }
            }
        }
    }
    process.waitUntilExit()

    let sessionId = state.sessionId
    let resultError = state.resultError
    // If the token stream produced no visible answer (it's best-effort and can
    // be skipped for short/cached turns), emit the final text so the user
    // doesn't get an empty bubble.
    if !state.streamedText, !state.finalText.isEmpty {
        onText(state.finalText)
    }
    if let resultError {
        throw NSError(
            domain: "refman-agent", code: 3,
            userInfo: [NSLocalizedDescriptionKey: resultError])
    }
    if process.terminationStatus != 0 {
        throw NSError(
            domain: "refman-agent", code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Claude Code exited with status \(process.terminationStatus) — run `claude` in Terminal to check it is installed and logged in."
            ])
    }
    return sessionId
}

// MARK: - Session state

final class AgentState: @unchecked Sendable {
    private var histories: [String: [[String: Any]]] = [:]
    /// ACP session id → Claude Code session id, for --resume.
    private var claudeSessions: [String: String] = [:]
    private let lock = NSLock()

    func history(for session: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return histories[session] ?? [["role": "system", "content": systemPrompt]]
    }

    func setHistory(_ messages: [[String: Any]], for session: String) {
        lock.lock()
        defer { lock.unlock() }
        histories[session] = messages
    }

    func claudeSession(for session: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return claudeSessions[session]
    }

    func setClaudeSession(_ id: String, for session: String) {
        lock.lock()
        defer { lock.unlock() }
        claudeSessions[session] = id
    }
}

// MARK: - Entry point

@main
struct Agent {
    static func main() async throws {
        if CommandLine.arguments.contains("--mcp") {
            try await runMCPServer()
            return
        }
        let model = backend == "claude" ? "" : await resolveModel()
        let state = AgentState()
        let peer = JSONRPCPeer(input: .standardInput, output: .standardOutput)

        peer.requestHandler = { method, params in
            try await handle(
                method: method, params: params, model: model, state: state, peer: peer)
        }
        peer.start()

        // Park forever; all work happens on the peer's tasks.
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// MCP stdio server exposing the library tools to Claude Code, reading
    /// the database directly (the app passes its path and the open document).
    static func runMCPServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dbPath = env["REFMAN_DB_PATH"],
            let documentId = Int64(env["REFMAN_DOCUMENT_ID"] ?? "")
        else {
            FileHandle.standardError.write(
                Data("refman-agent --mcp: REFMAN_DB_PATH and REFMAN_DOCUMENT_ID required\n".utf8))
            exit(1)
        }
        let database = try AppDatabase.openShared(at: URL(fileURLWithPath: dbPath))
        let repository = LibraryRepository(database)

        // MCP wants bare {name, description, inputSchema}; reuse the
        // OpenAI-shaped definitions used for Ollama.
        let tools: [[String: Any]] = toolDefinitions.compactMap { def in
            guard let function = def["function"] as? [String: Any] else { return nil }
            return [
                "name": function["name"] ?? "",
                "description": function["description"] ?? "",
                "inputSchema": function["parameters"] ?? ["type": "object"],
            ]
        }

        let peer = JSONRPCPeer(input: .standardInput, output: .standardOutput)
        peer.requestHandler = { method, params in
            switch method {
            case "initialize":
                return [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "refman", "version": "1.0"],
                ]
            case "tools/list":
                return ["tools": tools]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do {
                    let result = try LibraryTools.handle(
                        name: name, arguments: arguments,
                        repository: repository, currentDocumentId: documentId,
                        textLimit: 120_000)
                    return ["content": [["type": "text", "text": result]]]
                } catch {
                    return [
                        "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                        "isError": true,
                    ]
                }
            case "ping":
                return [String: Any]()
            default:
                throw JSONRPCPeer.RPCError(code: -32601, message: "method not found: \(method)")
            }
        }
        // Exit with the client; otherwise one server lingers per claude run.
        // The pause lets in-flight handlers flush their responses first.
        peer.onClose = {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
        }
        peer.start()
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    static func handle(
        method: String, params: [String: Any],
        model: String, state: AgentState, peer: JSONRPCPeer
    ) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": 1,
                "agentCapabilities": ["loadSession": false],
                "authMethods": [],
            ]

        case "session/new":
            let sessionId = UUID().uuidString
            state.setHistory(
                [["role": "system", "content": systemPrompt]], for: sessionId)
            return ["sessionId": sessionId]

        case "session/prompt":
            guard let sessionId = params["sessionId"] as? String else {
                throw JSONRPCPeer.RPCError(code: -32602, message: "missing sessionId")
            }
            let blocks = params["prompt"] as? [[String: Any]] ?? []
            let userText = blocks
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")

            func emit(_ text: String) {
                peer.notify(
                    "session/update",
                    params: [
                        "sessionId": sessionId,
                        "update": [
                            "sessionUpdate": "agent_message_chunk",
                            "content": ["type": "text", "text": text],
                        ],
                    ])
            }

            if backend == "claude" {
                guard let binary = resolveClaudeBinary() else {
                    throw JSONRPCPeer.RPCError(
                        code: -32000,
                        message:
                            "Claude Code CLI not found — install it (`npm install -g @anthropic-ai/claude-code`) and run `claude` once to log in.")
                }
                // --resume does not carry --append-system-prompt over, so
                // pass the (tool-aware) system prompt on every turn.
                let claudeId = try await claudeChat(
                    binary: binary, prompt: userText,
                    systemPrompt: systemPrompt,
                    resume: state.claudeSession(for: sessionId),
                    onText: emit)
                if let claudeId {
                    state.setClaudeSession(claudeId, for: sessionId)
                }
                return ["stopReason": "end_turn"]
            }

            var messages = state.history(for: sessionId)
            messages.append(["role": "user", "content": userText])

            // Tool loop: stream content; on tool calls, ask the client, append
            // results, and call the model again. Cap rounds defensively.
            for _ in 0..<8 {
                var assistantText = ""
                var pendingToolCalls: [[String: Any]] = []

                try await ollamaChat(model: model, messages: messages) { chunk in
                    if !chunk.content.isEmpty {
                        assistantText += chunk.content
                        emit(chunk.content)
                    }
                    pendingToolCalls.append(contentsOf: chunk.toolCalls)
                }

                var assistantMessage: [String: Any] = [
                    "role": "assistant", "content": assistantText,
                ]
                if !pendingToolCalls.isEmpty {
                    assistantMessage["tool_calls"] = pendingToolCalls
                }
                messages.append(assistantMessage)

                if pendingToolCalls.isEmpty { break }

                for call in pendingToolCalls {
                    let function = call["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    let arguments = function["arguments"] as? [String: Any] ?? [:]

                    emit("\n*[\(name)]*\n")

                    let resultText: String
                    do {
                        let response = try await peer.request(
                            "refman/toolCall",
                            params: ["name": name, "arguments": arguments])
                        resultText = (response as? [String: Any])?["result"] as? String ?? ""
                    } catch {
                        resultText = "Tool error: \(error.localizedDescription)"
                    }
                    messages.append(
                        ["role": "tool", "tool_name": name, "content": resultText])
                }
            }

            state.setHistory(messages, for: sessionId)
            return ["stopReason": "end_turn"]

        case "session/cancel":
            return [:] as [String: Any]

        default:
            throw JSONRPCPeer.RPCError(code: -32601, message: "method not found: \(method)")
        }
    }
}
