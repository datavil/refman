import Foundation
import Testing

@testable import Refman
@testable import RefmanCore

@Suite(.serialized)
struct AppModelTests {
    private func makeModel() throws -> (model: AppModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RefmanAppModelTests-" + UUID().uuidString)
        let store = try LibraryStore(rootURL: root.appending(path: "Storage"))
        let repository = try LibraryRepository(AppDatabase.inMemory())
        return (AppModel(repository: repository, store: store), root)
    }

    @Test func reloadSearchesOnlyTheSelectedCollection() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let included = try model.repository.insert(Document(title: "Scoped needle"))
        _ = try model.repository.insert(Document(title: "Outside needle"))
        let collection = try model.repository.createCollection(name: "Selected")
        try model.repository.add(documentId: included.id, toCollection: collection.id!)

        model.sidebarSelection = .collection(collection.id!)
        model.searchText = "needle"
        model.reload()

        #expect(model.documents.map(\.id) == [included.id])
    }

    @Test func trashAndRestoreUpdateVisibleState() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let details = try model.repository.insert(Document(title: "Recoverable"))
        model.reload()
        model.delete(documentIds: [details.id])

        #expect(model.documents.isEmpty)
        #expect(model.statusMessage == "Moved to Trash")

        model.sidebarSelection = .trash
        model.reload()
        #expect(model.documents.map(\.id) == [details.id])

        model.restoreFromTrash(id: details.id)
        #expect(model.documents.isEmpty)
        #expect(model.statusMessage == "Restored from Trash")

        model.sidebarSelection = .all
        model.reload()
        #expect(model.documents.map(\.id) == [details.id])
    }

    @Test func importSummaryReportsEveryOutcome() {
        let outcomes = [
            ImportOutcome(name: "one.pdf", status: .imported),
            ImportOutcome(name: "two.pdf", status: .imported),
            ImportOutcome(name: "duplicate.pdf", status: .duplicate),
            ImportOutcome(name: "broken.pdf", status: .failed),
        ]

        #expect(
            AppModel.importSummary(for: outcomes)
                == "Imported 2, 1 duplicate skipped, 1 failed")
    }
}
