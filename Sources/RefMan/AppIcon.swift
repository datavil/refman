import AppKit

/// Vector app icon, drawn at render time so it stays sharp at any size:
/// a serif "R" monogram over a yellow highlight stroke on deep indigo.
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
        NSGradient(
            starting: NSColor(srgbRed: 0.29, green: 0.25, blue: 0.66, alpha: 1),
            ending: NSColor(srgbRed: 0.15, green: 0.12, blue: 0.36, alpha: 1)
        )?.draw(in: bg, angle: -70)

        // Highlight stroke under the monogram.
        let bar = NSBezierPath(
            roundedRect: NSRect(x: 322, y: 262, width: 380, height: 58),
            xRadius: 29, yRadius: 29)
        NSColor(srgbRed: 1, green: 0.81, blue: 0.20, alpha: 1).setFill()
        bar.fill()

        // Serif "R".
        let descriptor = NSFont.systemFont(ofSize: 560, weight: .medium)
            .fontDescriptor.withDesign(.serif)
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: 560) }
            ?? NSFont(name: "Georgia", size: 560)!
        let monogram = NSAttributedString(
            string: "R",
            attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = monogram.size()
        monogram.draw(at: NSPoint(x: 512 - size.width / 2, y: 236))
    }
}
