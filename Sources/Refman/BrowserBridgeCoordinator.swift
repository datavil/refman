import AppKit
import Foundation
import Observation
import RefmanCore
import Security

@MainActor
@Observable
final class BrowserBridgeCoordinator {
    private let repository: LibraryRepository
    private let store: LibraryStore
    private var server: BrowserBridgeServer?
    private var pairingExpiresAt: Date?
    private let token: String

    var pairingCode: String?
    var connectionMessage = "Starting…"
    var onOpen: ((String) -> Void)?

    init(repository: LibraryRepository, store: LibraryStore) {
        self.repository = repository
        self.store = store
        token = BrowserBridgeCredential.loadOrCreate()
    }

    func start() {
        let server = BrowserBridgeServer { [weak self] request in
            guard let self else {
                return BrowserBridgeResponse(statusCode: 500, message: "Refman is unavailable.")
            }
            return await self.handle(request)
        }
        do {
            try server.start()
            self.server = server
            connectionMessage = "Listening on 127.0.0.1:\(BrowserBridgeServer.defaultPort)"
        } catch {
            connectionMessage = "Could not start: \(error.localizedDescription)"
        }
    }

    func createPairingCode() {
        let value = String(Int.random(in: 0...999_999))
        pairingCode = String(repeating: "0", count: 6 - value.count) + value
        pairingExpiresAt = Date().addingTimeInterval(5 * 60)
    }

    private func handle(_ request: BrowserBridgeRequest) async -> BrowserBridgeResponse {
        guard allowedOrigin(request.headers["origin"]) else {
            return .init(statusCode: 403, message: "This origin is not allowed.")
        }
        if request.method == "OPTIONS" {
            return .init(statusCode: 204, message: "")
        }
        if request.method == "GET", request.path == "/v1/status" {
            return .init(statusCode: 200, value: BrowserBridgeStatusResponse())
        }
        if request.method == "POST", request.path == "/v1/pair" {
            return pair(request)
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return .init(statusCode: 401, message: "Pair the extension with Refman.")
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/collections"):
                let collections = try repository.allCollections().compactMap { collection in
                    collection.id.map { BrowserBridgeCollection(id: $0, name: collection.name) }
                }
                return .init(statusCode: 200, value: collections)
            case ("POST", "/v1/import/identifier"):
                return try await importIdentifier(request.body)
            case ("POST", "/v1/import/metadata"):
                return try importMetadata(request.body)
            case ("POST", "/v1/import/pdf"):
                return try await importPDF(request.body)
            case ("POST", let path) where path.hasPrefix("/v1/documents/") && path.hasSuffix("/open"):
                let uuid = path
                    .dropFirst("/v1/documents/".count)
                    .dropLast("/open".count)
                guard try repository.document(uuid: String(uuid)) != nil else {
                    return .init(statusCode: 404, message: "Reference not found.")
                }
                onOpen?(String(uuid))
                return .init(statusCode: 200, message: "Opened in Refman.")
            default:
                return .init(statusCode: 404, message: "Unknown endpoint.")
            }
        } catch {
            return .init(statusCode: 500, message: error.localizedDescription)
        }
    }

    private func pair(_ request: BrowserBridgeRequest) -> BrowserBridgeResponse {
        guard let value = try? JSONDecoder().decode(BrowserPairRequest.self, from: request.body),
            value.code == pairingCode,
            let pairingExpiresAt,
            pairingExpiresAt > Date()
        else {
            return .init(statusCode: 401, message: "The pairing code is invalid or expired.")
        }
        pairingCode = nil
        self.pairingExpiresAt = nil
        return .init(statusCode: 200, value: BrowserPairResponse(token: token))
    }

    private func importIdentifier(_ data: Data) async throws -> BrowserBridgeResponse {
        let request = try JSONDecoder().decode(BrowserIdentifierImport.self, from: data)
        let pipeline = makePipeline()
        switch try await pipeline.importIdentifier(request.identifier) {
        case .added(let details):
            let saved = try finish(details, sourceURL: request.sourceURL, collectionId: request.collectionId)
            return importResponse(.added, details: saved, message: "Saved to Refman.")
        case .duplicate(let details):
            try add(details, to: request.collectionId)
            return importResponse(.duplicate, details: details, message: "Already in your library.")
        case .notFound:
            return .init(statusCode: 400, value: BrowserImportResponse(
                status: .failed, message: "Refman could not resolve this identifier."))
        case .unrecognized:
            return .init(statusCode: 400, value: BrowserImportResponse(
                status: .failed, message: "The page does not contain a supported identifier."))
        }
    }

    private func importMetadata(_ data: Data) throws -> BrowserBridgeResponse {
        let request = try JSONDecoder().decode(BrowserMetadataImport.self, from: data)
        let metadata = request.metadata
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, URL(string: metadata.url) != nil else {
            return .init(statusCode: 400, value: BrowserImportResponse(
                status: .failed, message: "The extracted page metadata is incomplete."))
        }
        if let doi = metadata.doi,
            let existing = try repository.document(doi: doi),
            let id = existing.id,
            let details = try repository.document(id: id)
        {
            try add(details, to: request.collectionId)
            return importResponse(.duplicate, details: details, message: "Already in your library.")
        }
        let document = Document(
            title: title,
            abstract: metadata.abstract,
            year: metadata.year,
            venue: metadata.venue,
            doi: metadata.doi,
            arxivId: metadata.arxivId,
            url: metadata.url)
        let authors = metadata.authors.map { Author(given: $0.given, family: $0.family) }
        let details = try repository.insert(document, authors: authors)
        try add(details, to: request.collectionId)
        return importResponse(.added, details: details, message: "Saved to Refman.")
    }

    private func importPDF(_ data: Data) async throws -> BrowserBridgeResponse {
        let request = try JSONDecoder().decode(BrowserPDFImport.self, from: data)
        guard let pdf = Data(base64Encoded: request.pdfBase64), pdf.starts(with: Data("%PDF".utf8)) else {
            return .init(statusCode: 400, value: BrowserImportResponse(
                status: .failed, message: "The downloaded file is not a PDF."))
        }
        let safeName = URL(fileURLWithPath: request.fileName).lastPathComponent
        let temporaryURL = URL.temporaryDirectory
            .appending(path: "refman-browser-\(UUID().uuidString)-\(safeName)")
        try pdf.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        switch try await makePipeline().importPDF(at: temporaryURL) {
        case .imported(let result):
            var details = result.details
            if let metadata = request.metadata {
                details = try apply(metadata, to: details)
            }
            let saved = try finish(
                details, sourceURL: request.sourceURL, collectionId: request.collectionId)
            return importResponse(.added, details: saved, message: "PDF saved to Refman.")
        case .duplicate(let details):
            try add(details, to: request.collectionId)
            return importResponse(.duplicate, details: details, message: "This PDF is already saved.")
        case .inTrash:
            return .init(statusCode: 409, value: BrowserImportResponse(
                status: .failed, message: "This PDF is currently in Refman’s Trash."))
        }
    }

    private func apply(
        _ metadata: BrowserPageMetadata, to details: DocumentDetails
    ) throws -> DocumentDetails {
        var document = details.document
        if !metadata.title.isEmpty { document.title = metadata.title }
        document.abstract = metadata.abstract ?? document.abstract
        document.year = metadata.year ?? document.year
        document.venue = metadata.venue ?? document.venue
        document.doi = metadata.doi ?? document.doi
        document.arxivId = metadata.arxivId ?? document.arxivId
        let authors = metadata.authors.isEmpty
            ? nil
            : metadata.authors.map { Author(given: $0.given, family: $0.family) }
        return try repository.update(document, authors: authors)
    }

    private func finish(
        _ details: DocumentDetails, sourceURL: String, collectionId: Int64?
    ) throws -> DocumentDetails {
        var document = details.document
        document.url = sourceURL
        let updated = try repository.update(document)
        try add(updated, to: collectionId)
        return updated
    }

    private func add(_ details: DocumentDetails, to collectionId: Int64?) throws {
        guard let collectionId, let documentId = details.document.id else { return }
        try repository.add(documentId: documentId, toCollection: collectionId)
    }

    private func importResponse(
        _ status: BrowserBridgeStatus, details: DocumentDetails, message: String
    ) -> BrowserBridgeResponse {
        .init(statusCode: 200, value: BrowserImportResponse(
            status: status,
            documentUUID: details.document.uuid,
            title: details.document.title,
            message: message))
    }

    private func makePipeline() -> ImportPipeline {
        let email = UserDefaults.standard.string(forKey: SettingsKeys.contactEmail) ?? ""
        return ImportPipeline(
            repository: repository,
            store: store,
            crossRef: CrossRefClient(mailto: email.isEmpty ? nil : email),
            pdfFetcher: PDFFetcher(mailto: email))
    }

    private func allowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        return origin.hasPrefix("chrome-extension://")
    }
}

private enum BrowserBridgeCredential {
    private static let key = "browserBridgeToken"

    static func loadOrCreate() -> String {
        let defaults = UserDefaults.standard
        if let token = defaults.string(forKey: key), !token.isEmpty {
            return token
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        let token = Data(bytes).base64EncodedString()
        defaults.set(token, forKey: key)
        return token
    }
}
