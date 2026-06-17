import AppKit

/// Vector app icon, drawn at render time so it stays sharp at any size:
/// a small node-and-edges graph in near-black on an off-white squircle.
enum AppIcon {
    static var image: NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            draw()
            return true
        }
    }

    /// When launched with `--export-icon <path>`, writes a 1024×1024 PNG of the
    /// icon and exits. Lets the build script bake an `.icns` from this single
    /// source of truth rather than maintaining a separate image asset.
    static func exportIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--export-icon"), idx + 1 < args.count else { return }
        let path = args[idx + 1]
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("export-icon: render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("export-icon: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Transparent logo mark in the dark ink color, for light backgrounds.
    static var mark: NSImage { markImage(tint: ink) }

    /// White logo mark, for dark backgrounds.
    static var markWhite: NSImage { markImage(tint: .white) }

    /// Transparent logo mark: just the node-and-edges graph, no squircle —
    /// for placing the brand on existing backgrounds (e.g. the sidebar header).
    private static func markImage(tint: NSColor) -> NSImage {
        let side: CGFloat = 64
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // Fit the graph (centred on ~(104,104) in group space, content
            // radius ~72) into the image with a hair of padding.
            let scale = (side / 2 - side * 0.04) / 72
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: side)
            transform.scaleX(by: 1, yBy: -1)
            transform.translateX(by: side / 2, yBy: side / 2)
            transform.scaleX(by: scale, yBy: scale)
            transform.translateX(by: -104, yBy: -104)
            transform.concat()
            drawGraph(tint: tint)
            return true
        }
    }

    private static let ink = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1)

    private static func draw() {
        // Background squircle, inset to the standard macOS icon grid so it
        // matches the size of neighbouring Dock icons (~10% padding).
        let bg = NSBezierPath(
            roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
            xRadius: 184, yRadius: 184)
        NSColor(srgbRed: 0.984, green: 0.984, blue: 0.976, alpha: 1).setFill()
        bg.fill()

        // Hairline border.
        let border = NSBezierPath(
            roundedRect: NSRect(x: 100.5, y: 100.5, width: 823, height: 823),
            xRadius: 184, yRadius: 184)
        ink.withAlphaComponent(0.10).setStroke()
        border.lineWidth = 1
        border.stroke()

        // Map the SVG group space (a 200x200 box centred on the node)
        // onto the flipped icon canvas.
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: 1024)
        transform.scaleX(by: 1, yBy: -1)
        transform.translateX(by: 512, yBy: 512)
        transform.scaleX(by: 5.12, yBy: 5.12)
        transform.translateX(by: -100, yBy: -100)
        transform.concat()

        drawGraph()
    }

    /// The node-and-edges graph in group space (a 200x200 box around the hub).
    private static func drawGraph(tint: NSColor = ink) {
        let center = NSPoint(x: 100, y: 100)
        let spokes = [NSPoint(x: 62, y: 62), NSPoint(x: 146, y: 74), NSPoint(x: 78, y: 146)]

        // Edges from the centre to each spoke.
        tint.setStroke()
        for spoke in spokes {
            let edge = NSBezierPath()
            edge.move(to: center)
            edge.line(to: spoke)
            edge.lineWidth = 7
            edge.lineCapStyle = .round
            edge.stroke()
        }

        // Nodes: a larger hub, smaller spoke ends.
        tint.setFill()
        dot(at: center, radius: 16)
        for spoke in spokes { dot(at: spoke, radius: 10) }
    }

    private static func dot(at point: NSPoint, radius: CGFloat) {
        NSBezierPath(ovalIn: NSRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2)).fill()
    }
}
