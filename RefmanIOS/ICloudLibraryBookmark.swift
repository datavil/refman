import Foundation

enum ICloudLibraryBookmark {
    private static let defaultsKey = "iCloudLibraryBookmark"

    static var hasSavedBookmark: Bool {
        UserDefaults.standard.data(forKey: defaultsKey) != nil
    }

    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func resolve() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
