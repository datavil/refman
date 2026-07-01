import Foundation

/// ACP client side: spawns an agent subprocess and drives it over JSON-RPC/ndjson.
///
/// Speaks the Agent Client Protocol core flow (initialize → session/new →
/// session/prompt with streamed session/update notifications), plus one
/// extension: agents may call back into the app with `refman/toolCall`
/// to query the library (search, full text, annotations, tags).
public final class ACPClient: @unchecked Sendable {
    public typealias ToolHandler =
        (_ name: String, _ arguments: [String: Any]) async throws -> String

    public enum ACPError: Error, LocalizedError {
        case notStarted
        case agentNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .notStarted: return "Agent session not started"
            case .agentNotFound(let path): return "Agent executable not found at \(path)"
            }
        }
    }

    private let agentURL: URL
    private let environment: [String: String]
    private let toolHandler: ToolHandler

    private var process: Process?
    private var peer: JSONRPCPeer?
    private var sessionId: String?
    private let chunkLock = NSLock()
    private var onChunk: ((String) -> Void)?

    public init(
        agentURL: URL,
        environment: [String: String] = [:],
        toolHandler: @escaping ToolHandler
    ) {
        self.agentURL = agentURL
        self.environment = environment
        self.toolHandler = toolHandler
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    public func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
            throw ACPError.agentNotFound(agentURL.path)
        }

        let process = Process()
        process.executableURL = agentURL
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0] = $1 }
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let peer = JSONRPCPeer(
            input: stdout.fileHandleForReading,
            output: stdin.fileHandleForWriting)

        peer.requestHandler = { [weak self] method, params in
            guard let self else { throw JSONRPCPeer.RPCError(code: -32603, message: "gone") }
            switch method {
            case "refman/toolCall":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result = try await self.toolHandler(name, arguments)
                return ["result": result]
            case "session/request_permission":
                // Local agent operating on the local library: auto-allow.
                let options = (params["options"] as? [[String: Any]]) ?? []
                let optionId = options.first?["optionId"] as? String ?? "allow"
                return ["outcome": ["outcome": "selected", "optionId": optionId]]
            default:
                throw JSONRPCPeer.RPCError(code: -32601, message: "unsupported: \(method)")
            }
        }

        peer.notificationHandler = { [weak self] method, params in
            guard method == "session/update", let self else { return }
            guard let update = params["update"] as? [String: Any],
                update["sessionUpdate"] as? String == "agent_message_chunk",
                let content = update["content"] as? [String: Any],
                let text = content["text"] as? String
            else { return }
            self.chunkLock.lock()
            let handler = self.onChunk
            self.chunkLock.unlock()
            handler?(text)
        }

        try process.run()
        peer.start()
        self.process = process
        self.peer = peer

        _ = try await peer.request(
            "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
            ])
        // Neutral, non-git working directory: the home folder (or any repo) makes
        // the agent probe for git, which pops the macOS "install developer tools"
        // dialog on Macs without Command Line Tools installed.
        let cwd = FileManager.default.temporaryDirectory.path
        let session = try await peer.request("session/new", params: ["cwd": cwd, "mcpServers": []])
        sessionId = (session as? [String: Any])?["sessionId"] as? String
    }

    /// Sends one user turn; `onChunk` receives streamed text. Returns the stop reason.
    @discardableResult
    public func prompt(_ text: String, onChunk: @escaping (String) -> Void) async throws -> String {
        guard let peer, let sessionId else { throw ACPError.notStarted }
        setChunkHandler(onChunk)
        defer { setChunkHandler(nil) }
        let result = try await peer.request(
            "session/prompt",
            params: [
                "sessionId": sessionId,
                "prompt": [["type": "text", "text": text]],
            ])
        return (result as? [String: Any])?["stopReason"] as? String ?? "end_turn"
    }

    private func setChunkHandler(_ handler: ((String) -> Void)?) {
        chunkLock.lock()
        onChunk = handler
        chunkLock.unlock()
    }

    public func stop() {
        peer?.stop()
        process?.terminate()
        process = nil
        peer = nil
        sessionId = nil
    }

    deinit {
        process?.terminate()
    }
}
