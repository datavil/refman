import AppKit
import SwiftUI

struct MainWindowMarker: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("refman-main-library")

    func makeNSView(context: Context) -> NSView {
        MarkerView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.identifier = Self.identifier
    }

    private final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = MainWindowMarker.identifier
        }
    }
}
