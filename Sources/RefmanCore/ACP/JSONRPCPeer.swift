import Foundation

/// Bidirectional JSON-RPC 2.0 over newline-delimited JSON, as used by the
/// Agent Client Protocol (ACP). Both the app (client) and refman-agent use this.
public final class JSONRPCPeer: @unchecked Sendable {
    public struct RPCError: Error, LocalizedError {
        public let code: Int
        public let message: String

        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }

        public var errorDescription: String? { "JSON-RPC error \(code): \(message)" }
    }

    /// Handles an incoming request; returns the `result` payload.
    public var requestHandler: ((_ method: String, _ params: [String: Any]) async throws -> Any)?
    /// Handles an incoming notification.
    public var notificationHandler: ((_ method: String, _ params: [String: Any]) -> Void)?
    /// Called once when the input stream closes.
    public var onClose: (() -> Void)?

    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var readTask: Task<Void, Never>?

    public init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    public func start() {
        readTask = Task.detached { [weak self] in
            guard let input = self?.input else { return }
            do {
                for try await line in input.bytes.lines {
                    guard let self else { return }
                    self.handle(line: line)
                }
            } catch {
                // input closed
            }
            self?.failAllPending(RPCError(code: -32000, message: "connection closed"))
            self?.onClose?()
        }
    }

    public func stop() {
        readTask?.cancel()
        failAllPending(RPCError(code: -32000, message: "stopped"))
    }

    // MARK: - Outgoing

    public func request(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            let id = nextId
            nextId += 1
            return id
        }()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    public func notify(_ method: String, params: [String: Any] = [:]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    // MARK: - Incoming

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        guard let handler = self.requestHandler else {
                            throw RPCError(code: -32601, message: "no handler")
                        }
                        let result = try await handler(method, params)
                        self.send(["jsonrpc": "2.0", "id": id, "result": result])
                    } catch let error as RPCError {
                        self.send([
                            "jsonrpc": "2.0", "id": id,
                            "error": ["code": error.code, "message": error.message],
                        ])
                    } catch {
                        self.send([
                            "jsonrpc": "2.0", "id": id,
                            "error": ["code": -32603, "message": "\(error)"],
                        ])
                    }
                }
            } else {
                notificationHandler?(method, params)
            }
            return
        }

        // Response
        guard let id = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue else {
            return
        }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(
                throwing: RPCError(
                    code: error["code"] as? Int ?? -32603,
                    message: error["message"] as? String ?? "unknown error"))
        } else {
            continuation.resume(returning: message["result"] ?? NSNull())
        }
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try? output.write(contentsOf: data)
    }

    private func failAllPending(_ error: Error) {
        lock.lock()
        let continuations = pending.values
        pending.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
