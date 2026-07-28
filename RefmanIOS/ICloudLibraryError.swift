import Foundation

enum ICloudLibraryError: LocalizedError {
    case missingDatabase

    var errorDescription: String? {
        switch self {
        case .missingDatabase:
            "Select the Refman folder that contains library.sqlite."
        }
    }
}
