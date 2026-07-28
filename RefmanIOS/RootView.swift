import Observation
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: IPadAppModel
    @State private var isImporting = false
    @State private var isSelectingICloudLibrary = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                model: model,
                isSelectingICloudLibrary: $isSelectingICloudLibrary)
        } content: {
            DocumentListView(model: model, isFileImporterPresented: $isImporting)
        } detail: {
            DocumentDetailView(model: model)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importPDFs(at: urls)
            case .failure(let error):
                model.statusMessage = "Could not access the selected PDF: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $isSelectingICloudLibrary,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let root = urls.first {
                    Task {
                        await model.connectICloudLibrary(at: root)
                    }
                }
            case .failure(let error):
                model.statusMessage =
                    "Could not access the iCloud library: \(error.localizedDescription)"
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reload()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isSwitchingLibrary {
                ProgressView("Opening the iCloud library…")
                    .padding()
                    .glassEffect()
            } else if model.isImporting {
                ProgressView(
                    "Importing \(model.importProgress) PDF\(model.importProgress == 1 ? "" : "s")…")
                    .padding()
                    .glassEffect()
            } else if let statusMessage = model.statusMessage {
                HStack {
                    Text(statusMessage)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") {
                        model.statusMessage = nil
                    }
                    .labelStyle(.iconOnly)
                }
                .padding()
                .glassEffect()
            }
        }
    }
}
