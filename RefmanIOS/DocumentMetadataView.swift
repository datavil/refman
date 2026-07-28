import RefmanCore
import SwiftUI

struct DocumentMetadataView: View {
    let details: DocumentDetails

    var body: some View {
        Form {
            Section("Reference") {
                Text(details.document.title)
                    .bold()
                if !details.authorsText.isEmpty {
                    LabeledContent("Authors", value: details.authorsText)
                }
                if let year = details.document.year {
                    LabeledContent("Year") {
                        Text(year, format: .number.grouping(.never))
                    }
                }
                if let venue = details.document.venue, !venue.isEmpty {
                    LabeledContent("Venue", value: venue)
                }
                if let doi = details.document.doi, !doi.isEmpty {
                    LabeledContent("DOI", value: doi)
                }
                if let arxivID = details.document.arxivId, !arxivID.isEmpty {
                    LabeledContent("arXiv", value: arxivID)
                }
            }

            if let abstract = details.document.abstract, !abstract.isEmpty {
                Section("Abstract") {
                    Text(abstract)
                        .textSelection(.enabled)
                }
            }

            if !details.tags.isEmpty {
                Section("Tags") {
                    Text(details.tags.map(\.name).joined(separator: ", "))
                }
            }

            if let urlString = details.document.url,
                let url = URL(string: urlString)
            {
                Section {
                    Link("Open Publication Website", destination: url)
                }
            }
        }
        .navigationTitle("Document Details")
    }
}
