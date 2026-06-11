import AppKit
import RefManCore
import SwiftUI

@main
struct RefManApp: App {
    @StateObject private var model = AppModel.live()
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue

    init() {
        // Running from `swift run` (no app bundle): become a regular app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var colorScheme: ColorScheme? {
        AppAppearance(rawValue: appearance)?.colorScheme
    }

    var body: some Scene {
        WindowGroup("RefMan") {
            LibraryView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
                .preferredColorScheme(colorScheme)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import PDFs…") { model.importViaPanel() }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Import BibTeX/RIS…") { model.importBibliographyViaPanel() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Export Library as BibTeX…") { model.exportViaPanel(format: .bibtex) }
                Button("Export Library as RIS…") { model.exportViaPanel(format: .ris) }
                Button("Export Library as CSL-JSON…") { model.exportViaPanel(format: .cslJSON) }
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
                .preferredColorScheme(colorScheme)
        }
    }
}
