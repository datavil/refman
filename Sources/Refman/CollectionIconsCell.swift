import SwiftUI

/// Icon of the first collection a document belongs to; the tooltip lists all.
/// Takes plain values: table cells don't reliably inherit the app environment.
struct CollectionIconsCell: View {
    /// Icon symbol and "Parent › Child" path per collection.
    let items: [(icon: String, path: String)]

    var body: some View {
        if let first = items.first {
            Image(systemName: first.icon)
                .foregroundStyle(.secondary)
                .help(items.map(\.path).joined(separator: "\n"))
        }
    }
}
