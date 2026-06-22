import AppKit
import RefmanCore
import SwiftUI

@main
struct RefmanApp: App {
    @StateObject private var model = AppModel.live()
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.light.rawValue

    init() {
        // CI smoke check: confirm packaged resources resolve, then exit.
        if CommandLine.arguments.contains("--check-resources") {
            let ok = LibraryView.verifyResources()
            FileHandle.standardError.write(
                Data((ok ? "resources OK\n" : "resources MISSING\n").utf8))
            exit(ok ? 0 : 1)
        }
        // Build-time icon export: render the icon and exit before any UI setup.
        AppIcon.exportIfRequested()
        // The Gemini provider was removed (Google ended free CLI login); migrate
        // any stale selection back to a working provider.
        if UserDefaults.standard.string(forKey: SettingsKeys.llmProvider) == "gemini" {
            UserDefaults.standard.set("ollama", forKey: SettingsKeys.llmProvider)
        }
        // Running from `swift run` (no app bundle): become a regular app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.applicationIconImage = AppIcon.image
    }

    private var colorScheme: ColorScheme? {
        AppAppearance(rawValue: appearance)?.colorScheme
    }

    var body: some Scene {
        WindowGroup("Refman") {
            LibraryView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updater.check(userInitiated: true) }
            }
            CommandGroup(after: .newItem) {
                Button("New Reference…") { model.requestAdd() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Import PDFs…") { model.importViaPanel() }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Import BibTeX/RIS…") { model.importBibliographyViaPanel() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Import from Folder…") { model.importFromFolderViaPanel() }
                Divider()
                Button("Export Library with PDFs…") {
                    model.exportBundleViaPanel(collectionId: nil)
                }
                Button("Export Library as BibTeX…") { model.exportViaPanel(format: .bibtex) }
                Button("Export Library as RIS…") { model.exportViaPanel(format: .ris) }
                Button("Export Library as CSL-JSON…") { model.exportViaPanel(format: .cslJSON) }
            }
            CommandGroup(after: .toolbar) {
                Button("Quick Open…") { model.requestPalette() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                Button("Reset Layout to Default") { LayoutReset.run() }
            }
            CommandMenu("Library") {
                Button("Move to Trash") { model.delete(documentIds: Array(model.selectedDocumentIds)) }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedDocumentIds.isEmpty)
                Button("Empty Trash") { model.emptyTrash() }
                Divider()
                Button("Back Up Library…") { model.backupViaPanel() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Reader", id: "reader", for: Int64.self) { $documentId in
            if let documentId {
                ReaderView(documentId: documentId)
                    .environmentObject(model)
                    .frame(minWidth: 900, minHeight: 600)
                    .preferredColorScheme(colorScheme)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(colorScheme)
        }
    }
}
