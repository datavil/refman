import RefmanCore
import SwiftUI

struct DocumentRowView: View {
    let details: DocumentDetails

    var body: some View {
        VStack(alignment: .leading) {
            Text(details.document.title)
                .bold()
                .lineLimit(2)

            if !details.authorsText.isEmpty {
                Text(details.authorsText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                if let year = details.document.year {
                    Text(year, format: .number.grouping(.never))
                }
                if let venue = details.document.venue, !venue.isEmpty {
                    Text(venue)
                }
                if details.document.fileHash != nil {
                    Image(systemName: "doc.richtext")
                        .accessibilityLabel("Has PDF")
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}
