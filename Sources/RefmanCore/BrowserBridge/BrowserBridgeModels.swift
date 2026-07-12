import Foundation

public enum BrowserBridgeStatus: String, Codable, Sendable {
    case added
    case duplicate
    case failed
}

public struct BrowserBridgeCollection: Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct BrowserBridgeAuthor: Codable, Equatable, Sendable {
    public let given: String
    public let family: String

    public init(given: String = "", family: String) {
        self.given = given
        self.family = family
    }
}

public struct BrowserPageMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let authors: [BrowserBridgeAuthor]
    public let abstract: String?
    public let year: Int?
    public let venue: String?
    public let doi: String?
    public let arxivId: String?
    public let url: String

    public init(
        title: String,
        authors: [BrowserBridgeAuthor] = [],
        abstract: String? = nil,
        year: Int? = nil,
        venue: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        url: String
    ) {
        self.title = title
        self.authors = authors
        self.abstract = abstract
        self.year = year
        self.venue = venue
        self.doi = doi
        self.arxivId = arxivId
        self.url = url
    }
}

public struct BrowserIdentifierImport: Codable, Sendable {
    public let identifier: String
    public let sourceURL: String
    public let collectionId: Int64?

    public init(identifier: String, sourceURL: String, collectionId: Int64? = nil) {
        self.identifier = identifier
        self.sourceURL = sourceURL
        self.collectionId = collectionId
    }
}

public struct BrowserMetadataImport: Codable, Sendable {
    public let metadata: BrowserPageMetadata
    public let collectionId: Int64?

    public init(metadata: BrowserPageMetadata, collectionId: Int64? = nil) {
        self.metadata = metadata
        self.collectionId = collectionId
    }
}

public struct BrowserPDFImport: Codable, Sendable {
    public let pdfBase64: String
    public let fileName: String
    public let sourceURL: String
    public let metadata: BrowserPageMetadata?
    public let collectionId: Int64?

    public init(
        pdfBase64: String, fileName: String, sourceURL: String,
        metadata: BrowserPageMetadata? = nil, collectionId: Int64? = nil
    ) {
        self.pdfBase64 = pdfBase64
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.metadata = metadata
        self.collectionId = collectionId
    }
}

public struct BrowserPairRequest: Codable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

public struct BrowserPairResponse: Codable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public struct BrowserImportResponse: Codable, Equatable, Sendable {
    public let status: BrowserBridgeStatus
    public let documentUUID: String?
    public let title: String?
    public let message: String

    public init(
        status: BrowserBridgeStatus,
        documentUUID: String? = nil,
        title: String? = nil,
        message: String
    ) {
        self.status = status
        self.documentUUID = documentUUID
        self.title = title
        self.message = message
    }
}

public struct BrowserBridgeRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct BrowserBridgeResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init<T: Encodable>(statusCode: Int, value: T) {
        self.statusCode = statusCode
        self.body = (try? JSONEncoder().encode(value)) ?? Data(#"{"error":"Encoding failed"}"#.utf8)
    }

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.body = (try? JSONEncoder().encode(["message": message])) ?? Data()
    }
}

public struct BrowserBridgeStatusResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let appName: String

    public init(protocolVersion: Int = 1, appName: String = "Refman") {
        self.protocolVersion = protocolVersion
        self.appName = appName
    }
}
