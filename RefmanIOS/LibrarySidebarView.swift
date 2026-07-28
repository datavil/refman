import SwiftUI

struct LibrarySidebarView: View {
    @Bindable var model: IPadAppModel
    @Binding var isSelectingICloudLibrary: Bool

    var body: some View {
        List(
            selection: Binding<LibrarySection?>(
                get: { model.section },
                set: { selection in
                    if let selection {
                        model.section = selection
                    }
                })
        ) {
            Section("Library") {
                Label("All References", systemImage: "books.vertical")
                    .tag(LibrarySection.all)
                Label("Recently Added", systemImage: "clock")
                    .tag(LibrarySection.recent)
                Label("Currently Reading", systemImage: "book.pages")
                    .tag(LibrarySection.reading)
                Label("Uncategorized", systemImage: "tray")
                    .tag(LibrarySection.uncategorized)
                Label("Trash", systemImage: "trash")
                    .tag(LibrarySection.trash)
            }

            Section {
                if model.isUsingICloudDrive {
                    Label("iCloud Drive Library", systemImage: "checkmark.icloud")
                    Button("Choose Another Folder", systemImage: "folder.badge.gearshape") {
                        isSelectingICloudLibrary = true
                    }
                    Button("Use Local iPad Library", systemImage: "ipad") {
                        model.useLocalLibrary()
                    }
                } else {
                    Button("Connect iCloud Library", systemImage: "icloud") {
                        isSelectingICloudLibrary = true
                    }
                }
            } header: {
                Text("Library Location")
            } footer: {
                if model.isUsingICloudDrive {
                    Text("Keep Refman open on only one device at a time.")
                } else {
                    Text("Choose the Refman folder in iCloud Drive once.")
                }
            }

            if !model.collections.isEmpty {
                Section("Collections") {
                    ForEach(model.collections, id: \.id) { collection in
                        Label(collection.name, systemImage: collection.icon ?? "folder")
                            .tag(LibrarySection.collection(collection.id ?? -1))
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        Label(tag.name, systemImage: "tag")
                            .tag(LibrarySection.tag(tag.id ?? -1))
                    }
                }
            }
        }
        .navigationTitle("Refman")
        .disabled(model.isImporting || model.isSwitchingLibrary)
        .onChange(of: model.section) { _, _ in
            model.reload()
        }
    }
}
