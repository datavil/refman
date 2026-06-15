import AppKit

/// Vector app icon, drawn at render time so it stays sharp at any size:
/// a black Optima "R" monogram over a yellow highlight stroke on white.
enum AppIcon {
    static var image: NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            draw()
            return true
        }
    }

    private static func draw() {
        // Background squircle.
        let bg = NSBezierPath(
            roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
            xRadius: 184, yRadius: 184)
        NSColor.white.setFill()
        bg.fill()

        // Highlight stroke under the monogram.
        let bar = NSBezierPath(
            roundedRect: NSRect(x: 322, y: 262, width: 380, height: 58),
            xRadius: 29, yRadius: 29)
        NSColor(srgbRed: 1, green: 0.81, blue: 0.20, alpha: 1).setFill()
        bar.fill()

        // "R" in Optima: humanist, gently flared strokes.
        let font = NSFont(name: "Optima-Bold", size: 560)
            ?? NSFont.systemFont(ofSize: 560, weight: .bold)
        let monogram = NSAttributedString(
            string: "R",
            attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = monogram.size()
        monogram.draw(at: NSPoint(x: 512 - size.width / 2, y: 236))
    }
}
