import SwiftUI

/// Icons of the collections a document belongs to, capped with a "+N" overflow.
/// Takes plain values: table cells don't reliably inherit the app environment.
struct CollectionIconsCell: View {
    /// Icon symbol and "Parent › Child" path per collection.
    let items: [(icon: String, path: String)]
    private let maxIcons = 3

    var body: some View {
        HStack {
            ForEach(items.prefix(maxIcons), id: \.path) { item in
                Image(systemName: item.icon)
                    .foregroundStyle(.secondary)
                    .help(item.path)
            }
            if items.count > maxIcons {
                Text("+\(items.count - maxIcons)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(items.dropFirst(maxIcons).map(\.path).joined(separator: "\n"))
            }
        }
    }
}
