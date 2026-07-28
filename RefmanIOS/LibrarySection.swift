import Foundation
import RefmanCore

enum LibrarySection: Hashable {
    case all
    case recent
    case reading
    case uncategorized
    case trash
    case collection(Int64)
    case tag(Int64)

    var searchScope: LibrarySearchScope {
        switch self {
        case .all:
            .all
        case .recent:
            .recent(
                since: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        case .reading:
            .reading
        case .uncategorized:
            .uncategorized
        case .trash:
            .trash
        case .collection(let id):
            .collection(id)
        case .tag(let id):
            .tag(id)
        }
    }
}
