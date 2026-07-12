import Foundation
@preconcurrency import Network

public final class BrowserBridgeServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 23_119
    // A 100 MB PDF expands to roughly 133 MB when base64-encoded in JSON.
    public static let maximumBodySize = 140 * 1_024 * 1_024

    private let queue = DispatchQueue(label: "app.refman.browser-bridge")
    private let handler: @Sendable (BrowserBridgeRequest) async -> BrowserBridgeResponse
    private var listener: NWListener?

    public init(
        handler: @escaping @Sendable (BrowserBridgeRequest) async -> BrowserBridgeResponse
    ) {
        self.handler = handler
    }

    public func start(port: UInt16 = defaultPort) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let content { next.append(content) }
            if next.count > Self.maximumBodySize + 16 * 1_024 {
                self.send(.init(statusCode: 413, message: "Request is too large."), on: connection)
                return
            }
            if let request = Self.parse(next) {
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
            } else if isComplete || error != nil {
                self.send(.init(statusCode: 400, message: "Malformed request."), on: connection)
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    private static func parse(_ data: Data) -> BrowserBridgeRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
            let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maximumBodySize else { return nil }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return BrowserBridgeRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }

    private func send(_ response: BrowserBridgeResponse, on connection: NWConnection) {
        let body = response.statusCode == 204 ? Data() : response.body
        let reason: String
        switch response.statusCode {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        default: reason = "Internal Server Error"
        }
        let head = """
            HTTP/1.1 \(response.statusCode) \(reason)\r
            Content-Type: application/json; charset=utf-8\r
            Content-Length: \(body.count)\r
            Access-Control-Allow-Origin: *\r
            Access-Control-Allow-Headers: Authorization, Content-Type\r
            Access-Control-Allow-Methods: GET, POST, OPTIONS\r
            Connection: close\r
            \r

            """
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
