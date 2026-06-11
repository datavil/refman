import Foundation
import RefManCore

/// refman-agent: an ACP agent that bridges to a local LLM via Ollama.
///
/// Speaks ACP (ndjson JSON-RPC on stdio): initialize, session/new,
/// session/prompt with streamed agent_message_chunk updates. When the model
/// requests a tool, the agent forwards it to the client (the RefMan app)
/// as a `refman/toolCall` request — the app owns the library, not the agent.
///
/// Environment:
///   REFMAN_OLLAMA_HOST   default http://127.0.0.1:11434
///   REFMAN_OLLAMA_MODEL  default: largest installed model

let ollamaHost = ProcessInfo.processInfo.environment["REFMAN_OLLAMA_HOST"]
    ?? "http://127.0.0.1:11434"

let systemPrompt = """
    You are RefMan's research assistant, embedded in a reference manager. \
    You help with the user's paper library: summarizing papers, answering \
    questions about their content, finding related work, and organizing. \
    Use the provided tools to ground every answer in the user's actual \
    library; do not invent papers or contents. Be concise.
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
            "description": "Full-text search over the user's library (titles, authors, abstracts, PDF text). Returns matching documents with ids.",
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

// MARK: - Session state

final class AgentState: @unchecked Sendable {
    private var histories: [String: [[String: Any]]] = [:]
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
}

// MARK: - Entry point

@main
struct Agent {
    static func main() async throws {
        let model = await resolveModel()
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

            var messages = state.history(for: sessionId)
            messages.append(["role": "user", "content": userText])

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
